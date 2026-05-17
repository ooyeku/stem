const std = @import("std");
const vigil = @import("vigil");
const protocol = @import("../kernel/protocol.zig");
const protocol_msg = @import("../kernel/protocol.zig").Message;

pub const PluginContext = struct {
    allocator: std.mem.Allocator,
    plugin_id: []const u8,

    inbox: *vigil.Inbox,
    to_core: *vigil.Inbox,
    to_ui: *vigil.Inbox,

    storage: std.StringHashMapUnmanaged([]const u8),

    plugin_allocator: std.mem.Allocator,
    message_allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        plugin_id: []const u8,
        inbox: *vigil.Inbox,
        to_core: *vigil.Inbox,
        to_ui: *vigil.Inbox,
        plugin_allocator: std.mem.Allocator,
    ) PluginContext {
        return .{
            .allocator = allocator,
            .plugin_id = plugin_id,
            .inbox = inbox,
            .to_core = to_core,
            .to_ui = to_ui,
            .storage = .{},
            .plugin_allocator = plugin_allocator,
            .message_allocator = allocator,
        };
    }

    pub fn sendToCore(self: *PluginContext, msg: protocol.PluginMessage) !void {
        const wrapper = protocol_msg{ .plugin_message = msg };
        const bytes = try wrapper.encode(self.message_allocator);
        defer self.message_allocator.free(bytes);
        try self.to_core.send(bytes);
    }

    pub fn sendToUI(self: *PluginContext, msg: protocol.PluginMessage) !void {
        const wrapper = protocol_msg{ .plugin_message = msg };
        const bytes = try wrapper.encode(self.message_allocator);
        defer self.message_allocator.free(bytes);
        try self.to_ui.send(bytes);
    }

    pub fn deinit(self: *PluginContext) void {
        self.storage.deinit(self.allocator);
    }
};
