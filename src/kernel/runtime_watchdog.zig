const std = @import("std");

pub const Severity = enum { info, warning, err };

pub const HealthInput = struct {
    lsp_unhealthy_servers: usize = 0,
    plugin_crashes: u64 = 0,
    plugin_pending_restarts: usize = 0,
    bus_drops_full: u64 = 0,
    bus_drops_backpressure: u64 = 0,
    bus_drops_rate_limited: u64 = 0,
    failed_jobs: usize = 0,
    index_at_capacity: bool = false,
    has_last_task: bool = false,
    /// Total Vigil runtime alerts (dead letters, poison messages, circuit
    /// opens, supervisor restarts, component crashes) since startup.
    runtime_alerts: u64 = 0,
};

pub const HealingRecommendation = struct {
    severity: Severity,
    title: []const u8,
    detail: []const u8,
    command: []const u8,
    alternate_command: ?[]const u8 = null,
};

pub const ToastKey = enum {
    lsp_unhealthy,
    plugin_crash,
    plugin_restart,
    bus_drops,
    job_failed,
    index_capacity,
    runtime_degraded,
};

pub const WatchdogToast = struct {
    key: ToastKey,
    severity: Severity,
    message: []const u8,
};

pub const RuntimeWatchdog = struct {
    previous: ?HealthInput = null,
    last_toast_key: ?ToastKey = null,
    last_toast_ms: i64 = 0,
    throttle_ms: i64 = 5000,

    pub fn observe(self: *RuntimeWatchdog, input: HealthInput, now_ms: i64) ?WatchdogToast {
        const prev = self.previous;
        defer self.previous = input;

        if (prev == null) return null;
        const toast = detectToast(prev.?, input) orelse return null;
        if (!self.canEmit(toast.key, now_ms)) return null;

        self.last_toast_key = toast.key;
        self.last_toast_ms = now_ms;
        return toast;
    }

    fn canEmit(self: *const RuntimeWatchdog, key: ToastKey, now_ms: i64) bool {
        if (self.last_toast_key) |last_key| {
            if (last_key == key and now_ms - self.last_toast_ms < self.throttle_ms) return false;
        }
        return true;
    }
};

pub fn appendRecommendations(
    input: HealthInput,
    out: *std.ArrayListUnmanaged(HealingRecommendation),
    allocator: std.mem.Allocator,
) !void {
    if (input.lsp_unhealthy_servers > 0) {
        try out.append(allocator, .{
            .severity = .warning,
            .title = "LSP health",
            .detail = "One or more language servers are unhealthy.",
            .command = "lsp.status",
            .alternate_command = "lsp.restart",
        });
    }

    if (input.plugin_crashes > 0 or input.plugin_pending_restarts > 0) {
        try out.append(allocator, .{
            .severity = .warning,
            .title = "Plugin lifecycle",
            .detail = "Plugin crashes or pending restarts were detected.",
            .command = "plugin.inspect",
        });
    }

    if (input.bus_drops_full > 0 or input.bus_drops_backpressure > 0 or input.bus_drops_rate_limited > 0) {
        try out.append(allocator, .{
            .severity = .warning,
            .title = "Message bus pressure",
            .detail = "The Vigil-backed message bus dropped or throttled updates.",
            .command = "stats.show",
        });
    }

    if (input.failed_jobs > 0) {
        try out.append(allocator, .{
            .severity = .err,
            .title = "Failed jobs",
            .detail = "A background job failed and may have retained output.",
            .command = "job.list",
            .alternate_command = if (input.has_last_task) "task.rerun_last" else "task.output",
        });
    }

    if (input.index_at_capacity) {
        try out.append(allocator, .{
            .severity = .warning,
            .title = "Project index capacity",
            .detail = "The workspace index reached its safety cap.",
            .command = "project.brain",
        });
    }

    if (input.runtime_alerts > 0) {
        try out.append(allocator, .{
            .severity = .warning,
            .title = "Runtime alerts",
            .detail = "Vigil reported dead-lettered messages, crashes, or open circuits.",
            .command = "stem.control_center",
            .alternate_command = "stem.heal",
        });
    }
}

fn detectToast(prev: HealthInput, input: HealthInput) ?WatchdogToast {
    if (input.lsp_unhealthy_servers > 0 and prev.lsp_unhealthy_servers == 0) {
        return .{
            .key = .lsp_unhealthy,
            .severity = .warning,
            .message = "LSP health: server unhealthy - run lsp.status",
        };
    }
    if (input.lsp_unhealthy_servers > 0 and prev.lsp_unhealthy_servers > 0) {
        return .{
            .key = .lsp_unhealthy,
            .severity = .warning,
            .message = "LSP health: server unhealthy - run lsp.status",
        };
    }
    if (input.plugin_crashes > prev.plugin_crashes) {
        return .{
            .key = .plugin_crash,
            .severity = .warning,
            .message = "Plugin health: crash recorded - run plugin.inspect",
        };
    }
    if (input.plugin_pending_restarts > 0 and prev.plugin_pending_restarts == 0) {
        return .{
            .key = .plugin_restart,
            .severity = .info,
            .message = "Plugin health: restart pending - run plugin.inspect",
        };
    }
    if (totalDrops(input) > 0 and totalDrops(prev) == 0) {
        return .{
            .key = .bus_drops,
            .severity = .warning,
            .message = "Message bus pressure: drops detected - run stats.show",
        };
    }
    if (input.failed_jobs > prev.failed_jobs) {
        return .{
            .key = .job_failed,
            .severity = .warning,
            .message = "Job failed - run job.list",
        };
    }
    if (input.index_at_capacity and !prev.index_at_capacity) {
        return .{
            .key = .index_capacity,
            .severity = .warning,
            .message = "Project index reached capacity - run project.brain",
        };
    }
    if (input.runtime_alerts > prev.runtime_alerts) {
        return .{
            .key = .runtime_degraded,
            .severity = .warning,
            .message = "Runtime degraded: messaging alerts - run stem.control_center",
        };
    }
    return null;
}

fn totalDrops(input: HealthInput) u64 {
    return input.bus_drops_full + input.bus_drops_backpressure + input.bus_drops_rate_limited;
}

fn expectCommand(list: *const std.ArrayListUnmanaged(HealingRecommendation), command: []const u8) !void {
    for (list.items) |item| {
        if (std.mem.eql(u8, item.command, command)) return;
    }
    return error.MissingCommand;
}

fn expectAlternate(list: *const std.ArrayListUnmanaged(HealingRecommendation), command: []const u8) !void {
    for (list.items) |item| {
        if (item.alternate_command) |alternate| {
            if (std.mem.eql(u8, alternate, command)) return;
        }
    }
    return error.MissingCommand;
}

test "recommendations are empty for healthy input" {
    var list = std.ArrayListUnmanaged(HealingRecommendation).empty;
    defer list.deinit(std.testing.allocator);

    try appendRecommendations(.{}, &list, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), list.items.len);
}

test "recommendations include lsp plugin bus job index actions" {
    var list = std.ArrayListUnmanaged(HealingRecommendation).empty;
    defer list.deinit(std.testing.allocator);

    try appendRecommendations(.{
        .lsp_unhealthy_servers = 1,
        .plugin_crashes = 1,
        .plugin_pending_restarts = 1,
        .bus_drops_full = 1,
        .failed_jobs = 1,
        .index_at_capacity = true,
        .has_last_task = true,
    }, &list, std.testing.allocator);

    try expectCommand(&list, "lsp.status");
    try expectCommand(&list, "plugin.inspect");
    try expectCommand(&list, "stats.show");
    try expectCommand(&list, "job.list");
    try expectCommand(&list, "project.brain");
    try expectAlternate(&list, "task.rerun_last");
}

test "watchdog emits only on health worsening and throttles repeats" {
    var watcher = RuntimeWatchdog{};

    try std.testing.expect(watcher.observe(.{}, 1000) == null);
    const first = watcher.observe(.{ .lsp_unhealthy_servers = 1 }, 2000) orelse return error.MissingToast;
    try std.testing.expectEqual(ToastKey.lsp_unhealthy, first.key);
    try std.testing.expect(watcher.observe(.{}, 2500) == null);
    try std.testing.expect(watcher.observe(.{ .lsp_unhealthy_servers = 1 }, 3000) == null);
    const second = watcher.observe(.{ .lsp_unhealthy_servers = 1 }, 8000) orelse return error.MissingToast;
    try std.testing.expectEqual(ToastKey.lsp_unhealthy, second.key);
}
