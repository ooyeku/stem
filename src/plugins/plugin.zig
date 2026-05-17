const std = @import("std");
const vigil = @import("vigil");
const interface = @import("interface.zig");
const context = @import("context.zig");
const MessageBus = @import("../kernel/message_bus.zig").MessageBus;

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
    /// Max crashes within `window_ms` before the supervisor gives up.
    max_restarts_in_window: u32 = 3,
    window_ms: i64 = 60_000,
    /// Delay before the next restart attempt, in milliseconds. Linear
    /// backoff: attempt N waits `restart_backoff_ms * N`.
    restart_backoff_ms: i64 = 250,
};

pub const Plugin = struct {
    id: []const u8,
    path: []const u8,

    lib: std.DynLib,

    interface: interface.PluginInterface,

    thread: ?std.Thread = null,
    inbox: ?*vigil.Inbox = null,
    /// Bus for the plugin manager to send TO this plugin's inbox. Built
    /// once when the plugin is loaded; lifetime tied to `inbox`.
    bus: ?MessageBus = null,
    ctx: ?*context.PluginContext = null,

    /// Restart bookkeeping. The crashed plugin's worker thread sets
    /// `restart_requested` when its policy allows another attempt; the
    /// manager's tick handler observes the flag and performs the actual
    /// reload (the manager owns DynLib/inbox/ctx lifetimes that the
    /// dead worker can't safely touch).
    restart_policy: RestartPolicy = .{},
    crash_history: CrashHistory = .{},
    restart_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Earliest wall-clock ms at which we'd retry — populated when
    /// `restart_requested` is set so the backoff is honored.
    next_restart_after_ms: i64 = 0,

    state: PluginState = .unloaded,
    load_time: i64 = 0,

    pub const PluginState = enum {
        unloaded,
        loading,
        loaded,
        running,
        unloading,
        failed,
    };

    pub fn deinit(self: *Plugin, allocator: std.mem.Allocator) void {
        if (self.state == .running) {
            self.state = .unloading;
        }

        if (self.inbox) |ib| {
            ib.close();
        }

        if (self.thread) |thread| {
            thread.join();
        }

        if (self.ctx) |c| {
            if (self.interface.deinit) |deinit_fn| {
                const opaque_ctx: *anyopaque = @ptrCast(c);
                deinit_fn(opaque_ctx);
            }
            c.deinit();
            allocator.destroy(c);
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
    // Window 5000ms ending at now=10000: only the entries at 10000 and
    // (10000 - 5000 ≤ t) so 10000 itself. The 1500 / 1000 entries
    // are >5000ms old.
    try std.testing.expectEqual(@as(u32, 1), h.recentCount(10_000, 5_000));
    // Wider window picks them all up.
    try std.testing.expectEqual(@as(u32, 3), h.recentCount(10_000, 10_000));
}

test "CrashHistory: ring buffer wraps" {
    var h: CrashHistory = .{};
    h.record(1);
    h.record(2);
    h.record(3);
    h.record(4);
    h.record(5); // overwrites slot 0 (the `1`)
    // The four most-recent timestamps are 2,3,4,5 — all <= 5 within a
    // 4-unit window from now=5.
    try std.testing.expectEqual(@as(u32, 4), h.recentCount(5, 4));
}
