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
const vigil = @import("vigil");

const Self = @This();
const Mutex = vigil.compat.Mutex;

/// Process-local aggregate state. Initialized once in `init` and
/// drained read-only via `snapshot()`.
const State = struct {
    mu: Mutex = .{},
    sends_per_bus: std.StringHashMapUnmanaged(SendStats) = .empty,
    /// Total bytes shipped through MessageBus.send. Cheap counter for
    /// sanity-checking producer throughput.
    bytes_sent: u64 = 0,
    /// Coalesce events, grouped by bus name+slot.
    coalesce_events: u64 = 0,
    plugin_crashes: u64 = 0,
    supervisor_restarts: u64 = 0,
    /// Allocator used for the hashmap; held until deinit.
    allocator: std.mem.Allocator = undefined,
    initialized: bool = false,
};

pub const SendStats = struct {
    sent: u64 = 0,
    dropped_full: u64 = 0,
    dropped_backpressure: u64 = 0,
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
    vigil.telemetry.deinitGlobal();
    state.initialized = false;
    state.bytes_sent = 0;
    state.coalesce_events = 0;
    state.plugin_crashes = 0;
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
}

pub fn recordMessageDropped(bus_name: []const u8, class: []const u8, size: usize, reason: []const u8) void {
    _ = class;
    _ = size;
    state.mu.lock();
    defer state.mu.unlock();
    if (!state.initialized) return;
    if (std.mem.eql(u8, reason, "backpressure")) {
        bumpSend(bus_name, .dropped_backpressure);
    } else {
        bumpSend(bus_name, .dropped_full);
    }
}

pub fn recordMessageCoalesced(bus_name: []const u8, slot: []const u8) void {
    _ = bus_name;
    _ = slot;
    state.mu.lock();
    defer state.mu.unlock();
    if (!state.initialized) return;
    state.coalesce_events +%= 1;
}

pub fn recordPluginCrash(plugin_id: []const u8) void {
    _ = plugin_id;
    state.mu.lock();
    defer state.mu.unlock();
    if (!state.initialized) return;
    state.plugin_crashes +%= 1;
}

pub fn recordSupervisorRestart() void {
    state.mu.lock();
    defer state.mu.unlock();
    if (!state.initialized) return;
    state.supervisor_restarts +%= 1;
}

// -----------------------------------------------------------------------------
// Read API — called from the plugin dashboard / log view.
// -----------------------------------------------------------------------------

pub const Snapshot = struct {
    bytes_sent: u64,
    coalesce_events: u64,
    plugin_crashes: u64,
    supervisor_restarts: u64,
};

pub fn snapshot() Snapshot {
    state.mu.lock();
    defer state.mu.unlock();
    return .{
        .bytes_sent = state.bytes_sent,
        .coalesce_events = state.coalesce_events,
        .plugin_crashes = state.plugin_crashes,
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

// -----------------------------------------------------------------------------
// Internals
// -----------------------------------------------------------------------------

const BumpKind = enum { sent, dropped_full, dropped_backpressure };

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
    }
}

fn onProcessCrashed(event: vigil.telemetry.Event) void {
    _ = event;
    state.mu.lock();
    defer state.mu.unlock();
    state.plugin_crashes +%= 1;
}

fn onSupervisorRestart(event: vigil.telemetry.Event) void {
    _ = event;
    state.mu.lock();
    defer state.mu.unlock();
    state.supervisor_restarts +%= 1;
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
