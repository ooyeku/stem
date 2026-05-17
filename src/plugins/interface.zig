const std = @import("std");
const protocol = @import("../kernel/protocol.zig");

pub const PLUGIN_VERSION: u32 = 1;

pub const PluginInterface = extern struct {
    version: u32 = PLUGIN_VERSION,

    name: [*:0]const u8,
    description: [*:0]const u8,

    init: ?*const fn (context: *anyopaque) i32 = null,
    deinit: ?*const fn (context: *anyopaque) void = null,
    handleMessage: ?*const fn (context: *anyopaque, msg: *const protocol.PluginMessage) i32 = null,

    capabilities: PluginCapabilities = .{},
};

pub const PluginCapabilities = extern struct {
    provides_commands: bool = false,
    provides_lsp: bool = false,
    provides_syntax: bool = false,
    extends_ui: bool = false,
    handles_files: bool = false,
};
