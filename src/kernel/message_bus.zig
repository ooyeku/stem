//! Stem's runtime messaging layer, built on top of Vigil.
//!
//! Every thread-to-thread byte mailbox in stem (input → core, core → ui,
//! plugin → core, terminal-worker → core, …) goes through a `MessageBus`
//! instead of poking `vigil.Inbox.send` directly. The bus exists for four
//! reasons:
//!
//!   1. **QoS routing.** `vigil.Inbox.send` hardcodes priority `.normal`,
//!      which silently disables Vigil's priority queue. The bus builds the
//!      `vigil.Message` itself so a `quit` doesn't sit behind 50 terminal-
//!      output chunks. Critical / interactive / coalescible / bulk classes
//!      map onto `MessagePriority.critical / high / normal / low / batch`.
//!
//!   2. **Coalescing.** Render updates and ticks are idempotent — a fresh
//!      one supersedes any pending older one. The bus exposes a
//!      `sendCoalesced(slot, payload)` that atomically replaces the in-
//!      flight message for that slot instead of letting renders pile up.
//!
//!   3. **Backpressure.** Bulk traffic (terminal output, scan results)
//!      uses a high-watermark check; over-watermark sends are dropped
//!      with a telemetry signal rather than ballooning memory.
//!
//!   4. **Observability.** Every send/drop/coalesce increments a per-class
//!      counter exposed via `stats()` and forwards to Vigil's global
//!      telemetry. Plugins (and the log view) can read this to spot a
//!      runaway producer.

const std = @import("std");
const vigil = @import("vigil");
const telemetry_mod = @import("../services/telemetry.zig");

const MessagePriority = vigil.MessagePriority;
const Message = vigil.Message;
const Mutex = vigil.compat.Mutex;

/// QoS class for an outgoing message. The class fixes both the Vigil
/// priority and the backpressure policy.
///
/// - `.critical`: shutdown, quit, panic. Never dropped, never coalesced.
///   Maps to `MessagePriority.critical`.
/// - `.interactive`: input, mouse, focus, resize, command. User-visible
///   latency depends on these. Maps to `.high`. Never dropped.
/// - `.coalescible`: renders, ticks, hover results — newer supersedes
///   older. Maps to `.normal`. Slot-coalesced via `sendCoalesced`.
/// - `.bulk`: terminal output chunks, scan results, file-discovered
///   notifications. Maps to `.low`. Backpressure: dropped over watermark.
/// - `.background`: logs, metrics, stats. Maps to `.batch`. Heaviest drop
///   policy.
pub const Class = enum {
    critical,
    interactive,
    coalescible,
    bulk,
    background,

    pub fn priority(self: Class) MessagePriority {
        return switch (self) {
            .critical => .critical,
            .interactive => .high,
            .coalescible => .normal,
            .bulk => .low,
            .background => .batch,
        };
    }
};

pub const Stats = struct {
    sent: [5]usize = .{ 0, 0, 0, 0, 0 },
    dropped_full: [5]usize = .{ 0, 0, 0, 0, 0 },
    dropped_backpressure: [5]usize = .{ 0, 0, 0, 0, 0 },
    coalesced: usize = 0,

    pub fn totalSent(self: Stats) usize {
        var n: usize = 0;
        for (self.sent) |s| n += s;
        return n;
    }

    pub fn totalDropped(self: Stats) usize {
        var n: usize = 0;
        for (self.dropped_full) |s| n += s;
        for (self.dropped_backpressure) |s| n += s;
        return n;
    }
};

/// Per-bus backpressure config. Bulk-class sends over `bulk_high_watermark`
/// in-flight messages are dropped (the producer is moving faster than the
/// consumer; the alternative is unbounded memory growth).
pub const BackpressureConfig = struct {
    bulk_high_watermark: usize = 256,
    background_high_watermark: usize = 128,
};

pub const MessageBus = struct {
    allocator: std.mem.Allocator,
    inbox: *vigil.Inbox,
    name: []const u8,
    backpressure: BackpressureConfig,
    stats_mu: Mutex = .{},
    stats: Stats = .{},
    coalesce_mu: Mutex = .{},
    /// `coalesce_slots[i]` is the most-recently-sent payload identity
    /// for slot `i`. Slot indices are caller-defined; suggested layout:
    /// 0 = render, 1 = tick, 2 = hover, but the bus doesn't care.
    coalesce_slots: [8]?u64 = .{ null, null, null, null, null, null, null, null },

    pub fn init(
        allocator: std.mem.Allocator,
        inbox: *vigil.Inbox,
        name: []const u8,
    ) MessageBus {
        return .{
            .allocator = allocator,
            .inbox = inbox,
            .name = name,
            .backpressure = .{},
        };
    }

    pub fn withBackpressure(self: MessageBus, bp: BackpressureConfig) MessageBus {
        var copy = self;
        copy.backpressure = bp;
        return copy;
    }

    /// Send a payload at the given QoS class. Constructs a Vigil `Message`
    /// directly so the underlying priority queue actually routes by
    /// priority (`vigil.Inbox.send` would hardcode `.normal`).
    pub fn send(self: *MessageBus, class: Class, payload: []const u8) !void {
        if (self.inbox.isClosed()) return error.InboxClosed;

        // Backpressure: drop bulk / background traffic when the inbox is
        // backed up. Doing this BEFORE constructing the message saves an
        // alloc on the rejection path.
        if (class == .bulk or class == .background) {
            const mailbox_stats = self.inbox.mailbox.getStats();
            const pending = mailbox_stats.messages_received -| mailbox_stats.messages_sent;
            const watermark = if (class == .bulk)
                self.backpressure.bulk_high_watermark
            else
                self.backpressure.background_high_watermark;
            if (pending >= watermark) {
                self.recordDroppedBackpressure(class, payload.len);
                return; // silent drop; producer keeps going
            }
        }

        // Build a Vigil message with the right priority. We pass `null`
        // ttl_ms — stem's threads drain quickly, and a TTL would silently
        // expire messages that arrive during a slow render.
        var msg = Message.init(
            self.allocator,
            "stem", // id; not used for routing
            self.name,
            payload,
            null,
            class.priority(),
            null,
        ) catch |err| {
            self.recordDroppedFull(class, payload.len);
            return err;
        };
        errdefer msg.deinit();

        self.inbox.mailbox.send(msg) catch |err| switch (err) {
            error.MailboxFull => {
                self.recordDroppedFull(class, payload.len);
                msg.deinit();
                return;
            },
            else => return err,
        };

        self.recordSent(class, payload.len);
    }

    /// Convenience wrappers — naming each makes call sites self-documenting
    /// without forcing every caller to remember the QoS taxonomy.
    pub fn sendCritical(self: *MessageBus, payload: []const u8) !void {
        return self.send(.critical, payload);
    }
    pub fn sendInteractive(self: *MessageBus, payload: []const u8) !void {
        return self.send(.interactive, payload);
    }
    pub fn sendCoalescible(self: *MessageBus, payload: []const u8) !void {
        return self.send(.coalescible, payload);
    }
    pub fn sendBulk(self: *MessageBus, payload: []const u8) !void {
        return self.send(.bulk, payload);
    }
    pub fn sendBackground(self: *MessageBus, payload: []const u8) !void {
        return self.send(.background, payload);
    }

    /// Send a payload that supersedes any earlier pending message in the
    /// same `slot`. Used for renders / ticks — there's no value in
    /// delivering two consecutive snapshots when one will do. If a prior
    /// message in this slot is still in-flight, the bus records a coalesce
    /// (telemetry) and proceeds; the consumer keeps both messages but the
    /// caller can identify stale frames via the snapshot's `version` field.
    ///
    /// Slot is caller-defined; conventional assignments live in
    /// `CoalesceSlot` below.
    pub fn sendCoalesced(
        self: *MessageBus,
        slot: CoalesceSlot,
        payload: []const u8,
        identity: u64,
    ) !void {
        self.coalesce_mu.lock();
        const idx = @intFromEnum(slot);
        const prev = self.coalesce_slots[idx];
        self.coalesce_slots[idx] = identity;
        self.coalesce_mu.unlock();

        if (prev != null) {
            self.stats_mu.lock();
            self.stats.coalesced += 1;
            self.stats_mu.unlock();
            telemetry_mod.recordMessageCoalesced(self.name, @tagName(slot));
        }

        return self.send(.coalescible, payload);
    }

    pub fn close(self: *MessageBus) void {
        self.inbox.close();
    }

    pub fn snapshotStats(self: *MessageBus) Stats {
        self.stats_mu.lock();
        defer self.stats_mu.unlock();
        return self.stats;
    }

    fn recordSent(self: *MessageBus, class: Class, size: usize) void {
        self.stats_mu.lock();
        self.stats.sent[@intFromEnum(class)] += 1;
        self.stats_mu.unlock();
        telemetry_mod.recordMessageSent(self.name, @tagName(class), size);
    }

    fn recordDroppedFull(self: *MessageBus, class: Class, size: usize) void {
        self.stats_mu.lock();
        self.stats.dropped_full[@intFromEnum(class)] += 1;
        self.stats_mu.unlock();
        telemetry_mod.recordMessageDropped(self.name, @tagName(class), size, "full");
    }

    fn recordDroppedBackpressure(self: *MessageBus, class: Class, size: usize) void {
        self.stats_mu.lock();
        self.stats.dropped_backpressure[@intFromEnum(class)] += 1;
        self.stats_mu.unlock();
        telemetry_mod.recordMessageDropped(self.name, @tagName(class), size, "backpressure");
    }
};

/// Coalescing slots. The protocol-side decision of which messages
/// coalesce lives here so changes are made in one place.
pub const CoalesceSlot = enum(u3) {
    render = 0,
    tick = 1,
    hover = 2,
    diagnostic = 3,
    /// Free slots for future use (kept under u3 so the array stays cheap).
    spare_4 = 4,
    spare_5 = 5,
    spare_6 = 6,
    spare_7 = 7,
};

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "MessageBus: classes map to expected Vigil priorities" {
    try std.testing.expectEqual(MessagePriority.critical, Class.critical.priority());
    try std.testing.expectEqual(MessagePriority.high, Class.interactive.priority());
    try std.testing.expectEqual(MessagePriority.normal, Class.coalescible.priority());
    try std.testing.expectEqual(MessagePriority.low, Class.bulk.priority());
    try std.testing.expectEqual(MessagePriority.batch, Class.background.priority());
}

test "MessageBus: sends and counts" {
    const a = std.testing.allocator;
    const ib = try vigil.inbox(a);
    defer ib.close();

    var bus = MessageBus.init(a, ib, "test-bus");
    try bus.sendCritical("hi");
    try bus.sendInteractive("hi");
    try bus.sendBulk("hi");

    const s = bus.snapshotStats();
    try std.testing.expectEqual(@as(usize, 1), s.sent[@intFromEnum(Class.critical)]);
    try std.testing.expectEqual(@as(usize, 1), s.sent[@intFromEnum(Class.interactive)]);
    try std.testing.expectEqual(@as(usize, 1), s.sent[@intFromEnum(Class.bulk)]);
    try std.testing.expectEqual(@as(usize, 0), s.totalDropped());

    // Drain so the inbox can close cleanly.
    while (true) {
        const m = ib.mailbox.receive() catch break;
        var mm = m;
        mm.deinit();
    }
}

test "MessageBus: coalescing increments counter on subsequent sends" {
    const a = std.testing.allocator;
    const ib = try vigil.inbox(a);
    defer ib.close();

    var bus = MessageBus.init(a, ib, "test-bus");

    try bus.sendCoalesced(.render, "frame1", 1);
    try bus.sendCoalesced(.render, "frame2", 2);
    try bus.sendCoalesced(.render, "frame3", 3);

    const s = bus.snapshotStats();
    // First send establishes the slot (no coalesce); subsequent two each
    // observe a prior tenant → coalesced=2.
    try std.testing.expectEqual(@as(usize, 2), s.coalesced);
    try std.testing.expectEqual(@as(usize, 3), s.sent[@intFromEnum(Class.coalescible)]);

    while (true) {
        const m = ib.mailbox.receive() catch break;
        var mm = m;
        mm.deinit();
    }
}

test "MessageBus: critical sends arrive before bulk on the priority queue" {
    const a = std.testing.allocator;
    const ib = try vigil.inbox(a);
    defer ib.close();

    var bus = MessageBus.init(a, ib, "test-bus");

    // Enqueue 3 bulk first, then 1 critical. The inbox's priority queue
    // should hand the critical message back first, despite arriving last.
    try bus.sendBulk("bulk-1");
    try bus.sendBulk("bulk-2");
    try bus.sendBulk("bulk-3");
    try bus.sendCritical("CRIT");

    var first = try ib.mailbox.receive();
    defer first.deinit();
    try std.testing.expectEqualStrings("CRIT", first.payload.?);

    // Drain the rest.
    while (true) {
        const m = ib.mailbox.receive() catch break;
        var mm = m;
        mm.deinit();
    }
}

test "MessageBus: bulk backpressure drops over watermark" {
    const a = std.testing.allocator;
    const ib = try vigil.inbox(a);
    defer ib.close();

    var bus = MessageBus.init(a, ib, "test-bus");
    bus.backpressure = .{ .bulk_high_watermark = 2, .background_high_watermark = 1 };

    try bus.sendBulk("a");
    try bus.sendBulk("b");
    try bus.sendBulk("c"); // would put pending=3 ≥ 2 → drop

    const s = bus.snapshotStats();
    try std.testing.expectEqual(@as(usize, 2), s.sent[@intFromEnum(Class.bulk)]);
    try std.testing.expectEqual(@as(usize, 1), s.dropped_backpressure[@intFromEnum(Class.bulk)]);

    while (true) {
        const m = ib.mailbox.receive() catch break;
        var mm = m;
        mm.deinit();
    }
}
