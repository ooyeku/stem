const std = @import("std");
const vigil = @import("vigil");
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

    pub fn init(allocator: std.mem.Allocator) !StemRuntime {
        var vigil_runtime = try vigil.runtime(allocator, .{});
        errdefer vigil_runtime.deinit();

        var event_broker = vigil.pubsub.PubSubBroker.init(allocator);
        errdefer event_broker.deinit();

        const telemetry_initialized = blk: {
            telemetry.init(allocator) catch break :blk false;
            break :blk true;
        };

        var plugin_supervisor = vigil_supervision.ComponentSupervisor.init(allocator, &vigil_runtime, .plugins);
        errdefer plugin_supervisor.deinit();
        plugin_supervisor.setEventBroker(&event_broker);

        var lsp_supervisor = vigil_supervision.ComponentSupervisor.init(allocator, &vigil_runtime, .lsp);
        errdefer lsp_supervisor.deinit();
        lsp_supervisor.setEventBroker(&event_broker);

        return .{
            .allocator = allocator,
            .vigil_runtime = vigil_runtime,
            .event_broker = event_broker,
            .plugin_supervisor = plugin_supervisor,
            .lsp_supervisor = lsp_supervisor,
            .telemetry_initialized = telemetry_initialized,
        };
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
        const main_inbox = try self.vigil_runtime.inbox(.{});
        errdefer main_inbox.close();

        const core_inbox = try self.vigil_runtime.inbox(.{});
        return .{
            .main = main_inbox,
            .core = core_inbox,
        };
    }

    pub fn publish(self: *StemRuntime, topic: []const u8, payload: []const u8) !vigil.PublishResult {
        return try self.event_broker.publish(topic, payload);
    }
};

test "StemRuntime owns Vigil runtime inboxes and pubsub broker" {
    var runtime = try StemRuntime.init(std.testing.allocator);
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
