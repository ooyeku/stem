const std = @import("std");
const vigil = @import("vigil");
const abi = @import("abi.zig");

/// Tracks recent crashes so the restart supervisor can rate-limit
/// restarts. Inspired by Erlang/OTP's "max restarts per period" policy
/// but kept tiny — a 4-deep ring is enough for a sensible cap.
pub const CrashHistory = struct {
    times_ms: [4]i64 = .{ 0, 0, 0, 0 },
    next: u2 = 0,

    pub fn record(self: *CrashHistory, now_ms: i64) void {
        self.times_ms[self.next] = now_ms;
        self.next = self.next +% 1;
    }

    /// Count crashes within the last `window_ms` of `now_ms`.
    pub fn recentCount(self: CrashHistory, now_ms: i64, window_ms: i64) u32 {
        var count: u32 = 0;
        for (self.times_ms) |t| {
            if (t != 0 and now_ms - t <= window_ms) count += 1;
        }
        return count;
    }
};

pub const RestartPolicy = struct {
    max_restarts_in_window: u32 = 3,
    window_ms: i64 = 60_000,
    restart_backoff_ms: i64 = 250,
};

/// Host-side state for one loaded plugin. **None of these fields cross
/// the plugin boundary.** Plugins never see a `*Plugin`; they get a
/// `PluginHandle` (u64), and host accessor functions in `host_abi.zig`
/// look up the `*Plugin` for any operation.
pub const Plugin = struct {
    id: []const u8,
    /// Same as `id` but null-terminated, so `stem_plugin_id` can return
    /// a C string without re-duping per call.
    id_c: ?[*:0]const u8 = null,
    path: []const u8,

    lib: std.DynLib,

    interface: abi.PluginInterface,

    /// Host-assigned. Set in `loadPlugin` and passed to every host
    /// accessor the plugin calls.
    handle: abi.PluginHandle = .{ .id = 0 },

    thread: ?std.Thread = null,
    /// Plugin's own inbox. Host's `pluginMain` drains it and forwards
    /// each message to the plugin via `interface.handle_message`.
    inbox: ?*vigil.Inbox = null,
    /// Routing targets used by host-side `stem_send_to_core` and
    /// `stem_send_to_ui` exports.
    core_inbox: ?*vigil.Inbox = null,
    ui_inbox: ?*vigil.Inbox = null,

    state: PluginState = .unloaded,
    load_time: i64 = 0,

    /// Restart bookkeeping; populated by the worker on crash and read
    /// by `PluginManager.tickRestarts`.
    restart_policy: RestartPolicy = .{},
    crash_history: CrashHistory = .{},
    restart_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    next_restart_after_ms: i64 = 0,

    pub const PluginState = enum {
        unloaded,
        loading,
        loaded,
        running,
        unloading,
        failed,
    };

    pub fn deinit(self: *Plugin, allocator: std.mem.Allocator) void {
        if (self.state == .running) self.state = .unloading;

        if (self.inbox) |ib| ib.close();

        if (self.thread) |thread| thread.join();

        // Best-effort plugin teardown.
        if (self.interface.deactivate) |deactivate_fn| {
            deactivate_fn(self.handle);
        }

        if (self.id_c) |c| {
            // id_c is a null-terminated dupe of id+'\0'; one allocation
            // sized id.len+1. Free with the same length used when alloc'd.
            allocator.free(c[0 .. self.id.len + 1]);
            self.id_c = null;
        }
        allocator.free(self.id);
        allocator.free(self.path);
        self.lib.close();
    }
};

test "CrashHistory.record then recentCount" {
    var h: CrashHistory = .{};
    h.record(1_000);
    h.record(1_500);
    h.record(10_000);
    try std.testing.expectEqual(@as(u32, 1), h.recentCount(10_000, 5_000));
    try std.testing.expectEqual(@as(u32, 3), h.recentCount(10_000, 10_000));
}

test "CrashHistory: ring buffer wraps" {
    var h: CrashHistory = .{};
    h.record(1);
    h.record(2);
    h.record(3);
    h.record(4);
    h.record(5);
    try std.testing.expectEqual(@as(u32, 4), h.recentCount(5, 4));
}
