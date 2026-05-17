const std = @import("std");
const protocol = @import("../kernel/protocol.zig");

/// Plugin ABI version. Bump this when the wire format between stem and
/// plugins changes — the manager refuses to load a plugin whose stamped
/// version doesn't match, so users get a clean "version mismatch" error
/// instead of mystery silent failures.
///
/// Changelog:
///   1 → 2: PluginMessage gained a `correlation_id: u64` field between
///          `message_type` and `payload_len` on the wire. Plugins built
///          against v1 send messages that the v2 core decodes as garbage.
pub const PLUGIN_VERSION: u32 = 2;

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
