//! Stem ↔ Vigil telemetry bridge.
//!
//! Vigil exposes a global telemetry emitter; stem subscribes to it and
//! also maintains a process-local rollup so the log view / plugin
//! dashboard can show "messages sent per bus", "messages dropped per
//! reason", "plugin crashes", "supervisor restarts" without scraping
//! individual events.
//!
//! The bridge is also where stem's own infrastructure events
//! (MessageBus sends, coalesces, drops, plugin reloads) are recorded.
//! Keeping all telemetry collection in this one file makes the
//! observability surface easy to audit.

const std = @import("std");
const vigil_api = @import("vigil_adapters.zig");
const vigil = vigil_api.raw;

const Self = @This();
const Mutex = vigil_api.Mutex;

/// Process-local aggregate state. Initialized once in `init` and
/// drained read-only via `snapshot()`.
const State = struct {
    mu: Mutex = .{},
    sends_per_bus: std.StringHashMapUnmanaged(SendStats) = .empty,
    timeline: std.ArrayListUnmanaged(TimelineEntry) = .empty,
    timeline_capacity: usize = 256,
    /// Total bytes shipped through MessageBus.send. Cheap counter for
    /// sanity-checking producer throughput.
    bytes_sent: u64 = 0,
    /// Coalesce events, grouped by bus name+slot.
    coalesce_events: u64 = 0,
    plugin_crashes: u64 = 0,
    lsp_crashes: u64 = 0,
    supervisor_restarts: u64 = 0,
    /// Allocator used for the hashmap; held until deinit.
    allocator: std.mem.Allocator = undefined,
    initialized: bool = false,
};

pub const SendStats = struct {
    sent: u64 = 0,
    dropped_full: u64 = 0,
    dropped_backpressure: u64 = 0,
    dropped_rate_limited: u64 = 0,
};

pub const TimelineKind = enum {
    runtime,
    shutdown,
    message,
    flow_control,
    plugin,
    lsp,
    supervisor,
};

pub const TimelineEntry = struct {
    timestamp_ms: i64,
    kind: TimelineKind,
    name: []const u8,
    detail: []const u8,
};

var state: State = .{};

/// Initialize the bridge and start the global Vigil telemetry emitter.
/// Safe to call multiple times; second call is a no-op.
pub fn init(allocator: std.mem.Allocator) !void {
    state.mu.lock();
    defer state.mu.unlock();
    if (state.initialized) return;

    state.allocator = allocator;
    state.initialized = true;

    // The global emitter is what `MessageBus` and others write into.
    vigil.telemetry.initGlobal(allocator) catch {
        // If telemetry init fails we still want stem to run — local
        // counters are still populated.
        state.initialized = false;
        return;
    };

    // Listen for vigil's own events so plugin / supervisor activity
    // ends up in our rollup too.
    vigil.telemetry.on(.process_crashed, onProcessCrashed) catch {};
    vigil.telemetry.on(.supervisor_restart, onSupervisorRestart) catch {};
}

pub fn deinit() void {
    state.mu.lock();
    defer state.mu.unlock();
    if (!state.initialized) return;
    var it = state.sends_per_bus.iterator();
    while (it.next()) |entry| {
        state.allocator.free(entry.key_ptr.*);
    }
    state.sends_per_bus.deinit(state.allocator);
    state.sends_per_bus = .empty;
    clearTimelineLocked();
    vigil.telemetry.deinitGlobal();
    state.initialized = false;
    state.bytes_sent = 0;
    state.coalesce_events = 0;
    state.plugin_crashes = 0;
    state.lsp_crashes = 0;
    state.supervisor_restarts = 0;
}

// -----------------------------------------------------------------------------
// Record API — called from MessageBus / plugin manager.
// -----------------------------------------------------------------------------

pub fn recordMessageSent(bus_name: []const u8, class: []const u8, size: usize) void {
    _ = class; // class is in the local stats keyed elsewhere; here we roll up
    state.mu.lock();
    defer state.mu.unlock();
    if (!state.initialized) return;
    bumpSend(bus_name, .sent);
    state.bytes_sent +%= size;
    appendTimelineLocked(.message, bus_name, "sent");
}

pub fn recordMessageDropped(bus_name: []const u8, class: []const u8, size: usize, reason: []const u8) void {
    _ = class;
    _ = size;
    state.mu.lock();
    defer state.mu.unlock();
    if (!state.initialized) return;
    if (std.mem.eql(u8, reason, "backpressure")) {
        bumpSend(bus_name, .dropped_backpressure);
        appendTimelineLocked(.flow_control, bus_name, "backpressure");
    } else if (std.mem.eql(u8, reason, "rate_limit")) {
        bumpSend(bus_name, .dropped_rate_limited);
        appendTimelineLocked(.flow_control, bus_name, "rate_limit");
    } else {
        bumpSend(bus_name, .dropped_full);
        appendTimelineLocked(.message, bus_name, "full");
    }
}

pub fn recordMessageCoalesced(bus_name: []const u8, slot: []const u8) void {
    _ = slot;
    state.mu.lock();
    defer state.mu.unlock();
    if (!state.initialized) return;
    state.coalesce_events +%= 1;
    appendTimelineLocked(.message, bus_name, "coalesced");
}

pub fn recordPluginCrash(plugin_id: []const u8) void {
    state.mu.lock();
    defer state.mu.unlock();
    if (!state.initialized) return;
    state.plugin_crashes +%= 1;
    appendTimelineLocked(.plugin, plugin_id, "crashed");
}

pub fn recordLspCrash(lang: []const u8) void {
    state.mu.lock();
    defer state.mu.unlock();
    if (!state.initialized) return;
    state.lsp_crashes +%= 1;
    appendTimelineLocked(.lsp, lang, "crashed");
}

pub fn recordSupervisorRestart() void {
    state.mu.lock();
    defer state.mu.unlock();
    if (!state.initialized) return;
    state.supervisor_restarts +%= 1;
    appendTimelineLocked(.supervisor, "runtime", "restart");
}

pub fn recordTimeline(kind: TimelineKind, name: []const u8, detail: []const u8) void {
    state.mu.lock();
    defer state.mu.unlock();
    if (!state.initialized) return;
    appendTimelineLocked(kind, name, detail);
}

// -----------------------------------------------------------------------------
// Read API — called from the plugin dashboard / log view.
// -----------------------------------------------------------------------------

pub const Snapshot = struct {
    bytes_sent: u64,
    coalesce_events: u64,
    plugin_crashes: u64,
    lsp_crashes: u64,
    supervisor_restarts: u64,
};

pub fn snapshot() Snapshot {
    state.mu.lock();
    defer state.mu.unlock();
    return .{
        .bytes_sent = state.bytes_sent,
        .coalesce_events = state.coalesce_events,
        .plugin_crashes = state.plugin_crashes,
        .lsp_crashes = state.lsp_crashes,
        .supervisor_restarts = state.supervisor_restarts,
    };
}

/// Copy out a snapshot of the per-bus send stats. Caller owns the slice
/// and inner keys; pass the same allocator to free them.
pub fn snapshotPerBus(allocator: std.mem.Allocator) ![]BusSendStats {
    state.mu.lock();
    defer state.mu.unlock();
    if (!state.initialized) return allocator.alloc(BusSendStats, 0);
    var list = std.ArrayListUnmanaged(BusSendStats).empty;
    errdefer {
        for (list.items) |item| allocator.free(item.bus_name);
        list.deinit(allocator);
    }
    var it = state.sends_per_bus.iterator();
    while (it.next()) |entry| {
        const name_dupe = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(name_dupe);
        try list.append(allocator, .{
            .bus_name = name_dupe,
            .stats = entry.value_ptr.*,
        });
    }
    return list.toOwnedSlice(allocator);
}

pub const BusSendStats = struct {
    bus_name: []const u8,
    stats: SendStats,
};

pub fn snapshotTimeline(allocator: std.mem.Allocator) ![]TimelineEntry {
    state.mu.lock();
    defer state.mu.unlock();
    if (!state.initialized) return allocator.alloc(TimelineEntry, 0);

    var list = std.ArrayListUnmanaged(TimelineEntry).empty;
    errdefer {
        for (list.items) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.detail);
        }
        list.deinit(allocator);
    }

    for (state.timeline.items) |entry| {
        const name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name);
        const detail = try allocator.dupe(u8, entry.detail);
        errdefer allocator.free(detail);
        try list.append(allocator, .{
            .timestamp_ms = entry.timestamp_ms,
            .kind = entry.kind,
            .name = name,
            .detail = detail,
        });
    }
    return list.toOwnedSlice(allocator);
}

pub fn freeTimelineSnapshot(allocator: std.mem.Allocator, timeline: []TimelineEntry) void {
    for (timeline) |entry| {
        allocator.free(entry.name);
        allocator.free(entry.detail);
    }
    allocator.free(timeline);
}

// -----------------------------------------------------------------------------
// Internals
// -----------------------------------------------------------------------------

const BumpKind = enum { sent, dropped_full, dropped_backpressure, dropped_rate_limited };

fn bumpSend(bus_name: []const u8, kind: BumpKind) void {
    const gop = state.sends_per_bus.getOrPut(state.allocator, bus_name) catch return;
    if (!gop.found_existing) {
        // Dupe the key — caller's `bus_name` slice may outlive its scope
        // (it's typically a string literal, but we don't bank on it).
        const key_dupe = state.allocator.dupe(u8, bus_name) catch {
            // Remove the half-inserted entry; getOrPut already placed
            // an undefined key/value pair.
            _ = state.sends_per_bus.remove(bus_name);
            return;
        };
        gop.key_ptr.* = key_dupe;
        gop.value_ptr.* = .{};
    }
    switch (kind) {
        .sent => gop.value_ptr.sent +%= 1,
        .dropped_full => gop.value_ptr.dropped_full +%= 1,
        .dropped_backpressure => gop.value_ptr.dropped_backpressure +%= 1,
        .dropped_rate_limited => gop.value_ptr.dropped_rate_limited +%= 1,
    }
}

fn appendTimelineLocked(kind: TimelineKind, name: []const u8, detail: []const u8) void {
    if (state.timeline_capacity == 0) return;

    const name_copy = state.allocator.dupe(u8, name) catch return;
    const detail_copy = state.allocator.dupe(u8, detail) catch {
        state.allocator.free(name_copy);
        return;
    };

    while (state.timeline.items.len >= state.timeline_capacity) {
        const removed = state.timeline.orderedRemove(0);
        state.allocator.free(removed.name);
        state.allocator.free(removed.detail);
    }

    state.timeline.append(state.allocator, .{
        .timestamp_ms = vigil_api.milliTimestamp(),
        .kind = kind,
        .name = name_copy,
        .detail = detail_copy,
    }) catch {
        state.allocator.free(name_copy);
        state.allocator.free(detail_copy);
    };
}

fn clearTimelineLocked() void {
    for (state.timeline.items) |entry| {
        state.allocator.free(entry.name);
        state.allocator.free(entry.detail);
    }
    state.timeline.deinit(state.allocator);
    state.timeline = .empty;
}

fn onProcessCrashed(event: vigil.telemetry.Event) void {
    state.mu.lock();
    defer state.mu.unlock();
    const metadata = event.metadata orelse "process";
    if (std.mem.startsWith(u8, metadata, "lsp:")) {
        const lang = metadata["lsp:".len..];
        state.lsp_crashes +%= 1;
        appendTimelineLocked(.lsp, lang, "crashed");
    } else {
        state.plugin_crashes +%= 1;
        appendTimelineLocked(.plugin, metadata, "crashed");
    }
}

fn onSupervisorRestart(event: vigil.telemetry.Event) void {
    state.mu.lock();
    defer state.mu.unlock();
    state.supervisor_restarts +%= 1;
    appendTimelineLocked(.supervisor, event.metadata orelse "supervisor", "restart");
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "telemetry: init / record / snapshot round-trips" {
    try Self.init(std.testing.allocator);
    defer Self.deinit();

    Self.recordMessageSent("test-bus", "interactive", 32);
    Self.recordMessageSent("test-bus", "interactive", 16);
    Self.recordMessageDropped("test-bus", "bulk", 8, "backpressure");
    Self.recordMessageDropped("other-bus", "bulk", 4, "full");
    Self.recordMessageCoalesced("test-bus", "render");

    const s = Self.snapshot();
    try std.testing.expectEqual(@as(u64, 48), s.bytes_sent);
    try std.testing.expectEqual(@as(u64, 1), s.coalesce_events);

    const per_bus = try Self.snapshotPerBus(std.testing.allocator);
    defer {
        for (per_bus) |b| std.testing.allocator.free(b.bus_name);
        std.testing.allocator.free(per_bus);
    }
    try std.testing.expectEqual(@as(usize, 2), per_bus.len);
}

test "telemetry: silent when not initialized" {
    // No init() call — every record is a no-op, no crash, no allocation.
    Self.recordMessageSent("nothing", "interactive", 4);
    const s = Self.snapshot();
    try std.testing.expectEqual(@as(u64, 0), s.bytes_sent);
}

test "telemetry: init and deinit can repeat" {
    try Self.init(std.testing.allocator);
    Self.recordMessageSent("first", "interactive", 4);
    Self.deinit();

    try Self.init(std.testing.allocator);
    Self.recordMessageSent("second", "interactive", 8);
    const s = Self.snapshot();
    try std.testing.expectEqual(@as(u64, 8), s.bytes_sent);
    Self.deinit();
}

test "telemetry: Vigil process crash metadata separates LSP from plugin crashes" {
    try Self.init(std.testing.allocator);
    defer Self.deinit();

    vigil.telemetry.emit(.{
        .event_type = .process_crashed,
        .timestamp_ms = vigil_api.milliTimestamp(),
        .metadata = "lsp:zig",
    });
    vigil.telemetry.emit(.{
        .event_type = .process_crashed,
        .timestamp_ms = vigil_api.milliTimestamp(),
        .metadata = "git",
    });

    const s = Self.snapshot();
    try std.testing.expectEqual(@as(u64, 1), s.lsp_crashes);
    try std.testing.expectEqual(@as(u64, 1), s.plugin_crashes);
}

test "telemetry: bounded timeline records runtime and flow-control events" {
    try Self.init(std.testing.allocator);
    defer Self.deinit();

    Self.recordTimeline(.runtime, "shutdown", "begin");
    Self.recordMessageDropped("test-bus", "bulk", 8, "rate_limit");

    const timeline = try Self.snapshotTimeline(std.testing.allocator);
    defer Self.freeTimelineSnapshot(std.testing.allocator, timeline);

    try std.testing.expect(timeline.len >= 2);
    try std.testing.expectEqual(TimelineKind.runtime, timeline[0].kind);
    try std.testing.expectEqualStrings("shutdown", timeline[0].name);
    try std.testing.expectEqualStrings("begin", timeline[0].detail);
    try std.testing.expectEqual(TimelineKind.flow_control, timeline[1].kind);
}
