const std = @import("std");
const interface = @import("interface.zig");
const context = @import("context.zig");
const protocol = @import("../kernel/protocol.zig");

pub const PluginConfig = struct {
    name: [:0]const u8,
    description: [:0]const u8,
    init: ?*const fn (ctx: *context.PluginContext) i32 = null,
    deinit: ?*const fn (ctx: *context.PluginContext) void = null,
    handleMessage: ?*const fn (ctx: *context.PluginContext, msg: *const protocol.PluginMessage) i32 = null,
};

pub fn createPlugin(comptime config: PluginConfig) interface.PluginInterface {
    return .{
        .name = config.name,
        .description = config.description,
        .init = if (config.init) |f| @ptrCast(f) else null,
        .deinit = if (config.deinit) |f| @ptrCast(f) else null,
        .handleMessage = if (config.handleMessage) |f| @ptrCast(f) else null,
        .capabilities = .{},
    };
}
