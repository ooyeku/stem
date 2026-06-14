const std = @import("std");
const vigil_api = @import("vigil_adapters.zig");
const vigil = vigil_api.raw;
const telemetry = @import("telemetry.zig");
const vigil_supervision = @import("vigil_supervision.zig");

pub const EditorInboxes = struct {
    main: *vigil.Inbox,
    core: *vigil.Inbox,
};

pub const StemRuntime = struct {
    allocator: std.mem.Allocator,
    vigil_runtime: vigil.Runtime,
    event_broker: vigil.pubsub.PubSubBroker,
    plugin_supervisor: vigil_supervision.ComponentSupervisor,
    lsp_supervisor: vigil_supervision.ComponentSupervisor,
    telemetry_initialized: bool = false,

    pub const HealthSnapshot = struct {
        vigil_major: u32,
        vigil_minor: u32,
        vigil_patch: u32,
        telemetry_initialized: bool,
        plugin_supervisor: vigil_supervision.Snapshot,
        lsp_supervisor: vigil_supervision.Snapshot,
    };

    pub fn init(allocator: std.mem.Allocator) !StemRuntime {
        var vigil_runtime = try vigil_api.runtime(allocator, .{});
        errdefer vigil_runtime.deinit();

        var event_broker = vigil.pubsub.PubSubBroker.init(allocator);
        errdefer event_broker.deinit();

        const telemetry_initialized = blk: {
            telemetry.init(allocator) catch break :blk false;
            break :blk true;
        };

        var plugin_supervisor = vigil_supervision.ComponentSupervisor.init(allocator, &vigil_runtime, .plugins);
        errdefer plugin_supervisor.deinit();

        var lsp_supervisor = vigil_supervision.ComponentSupervisor.init(allocator, &vigil_runtime, .lsp);
        errdefer lsp_supervisor.deinit();

        return .{
            .allocator = allocator,
            .vigil_runtime = vigil_runtime,
            .event_broker = event_broker,
            .plugin_supervisor = plugin_supervisor,
            .lsp_supervisor = lsp_supervisor,
            .telemetry_initialized = telemetry_initialized,
        };
    }

    pub fn attachEventBroker(self: *StemRuntime) void {
        self.plugin_supervisor.setEventBroker(&self.event_broker);
        self.lsp_supervisor.setEventBroker(&self.event_broker);
    }

    pub fn deinit(self: *StemRuntime) void {
        self.lsp_supervisor.deinit();
        self.plugin_supervisor.deinit();
        self.event_broker.deinit();
        if (self.telemetry_initialized) {
            telemetry.deinit();
            self.telemetry_initialized = false;
        }
        self.vigil_runtime.deinit();
    }

    pub fn createEditorInboxes(self: *StemRuntime) !EditorInboxes {
        const main_inbox = try vigil_api.createInbox(&self.vigil_runtime);
        errdefer main_inbox.close();

        const core_inbox = try vigil_api.createInbox(&self.vigil_runtime);
        return .{
            .main = main_inbox,
            .core = core_inbox,
        };
    }

    pub fn healthSnapshot(self: *StemRuntime) HealthSnapshot {
        const version = vigil.getVersion();
        return .{
            .vigil_major = version.major,
            .vigil_minor = version.minor,
            .vigil_patch = version.patch,
            .telemetry_initialized = self.telemetry_initialized,
            .plugin_supervisor = self.plugin_supervisor.snapshot(),
            .lsp_supervisor = self.lsp_supervisor.snapshot(),
        };
    }

    pub fn publish(self: *StemRuntime, topic: []const u8, payload: []const u8) !vigil.PublishResult {
        return try self.event_broker.publish(topic, payload);
    }
};

test "StemRuntime owns Vigil runtime inboxes and pubsub broker" {
    var runtime = try StemRuntime.init(std.testing.allocator);
    runtime.attachEventBroker();
    defer runtime.deinit();

    const version = vigil.getVersion();
    try std.testing.expectEqual(@as(u32, 2), version.major);
    try std.testing.expect(@hasDecl(vigil, "Runtime"));
    try std.testing.expect(!@hasDecl(vigil, "createMailbox"));
    try std.testing.expect(!@hasDecl(vigil, "global_registry"));

    const inboxes = try runtime.createEditorInboxes();
    defer inboxes.core.close();
    defer inboxes.main.close();

    try inboxes.core.send("core");
    var msg = try inboxes.core.recv();
    defer msg.deinit();
    try std.testing.expectEqualStrings("core", msg.payload.?);
}

test "StemRuntime pubsub broker fans out editor topics" {
    var runtime = try StemRuntime.init(std.testing.allocator);
    runtime.attachEventBroker();
    defer runtime.deinit();

    var inbox = try runtime.vigil_runtime.inbox(.{ .capacity = 4 });
    defer inbox.close();

    var subscriber = vigil.pubsub.Subscriber.init(std.testing.allocator, inbox);
    defer subscriber.deinit();
    try subscriber.subscribe(&[_][]const u8{"editor.buffer.changed"});
    try runtime.event_broker.subscribe(&subscriber);

    _ = try runtime.publish("editor.buffer.changed", "main.zig");

    var msg = try inbox.recv();
    defer msg.deinit();
    try std.testing.expectEqualStrings("main.zig", msg.payload.?);
}

test "StemRuntime health snapshot includes Vigil version and supervisors" {
    var runtime = try StemRuntime.init(std.testing.allocator);
    runtime.attachEventBroker();
    defer runtime.deinit();

    runtime.plugin_supervisor.recordCrash("git");
    runtime.lsp_supervisor.recordRestartScheduled("zig", 0, 1);

    const snapshot = runtime.healthSnapshot();
    try std.testing.expectEqual(@as(u32, 2), snapshot.vigil_major);
    try std.testing.expect(snapshot.telemetry_initialized);
    try std.testing.expectEqual(@as(u64, 1), snapshot.plugin_supervisor.crashes);
    try std.testing.expectEqual(@as(u64, 1), snapshot.lsp_supervisor.restarts_scheduled);
}
