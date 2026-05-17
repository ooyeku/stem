//! Compatibility shim retained for the host-side code (PluginManager
//! tests, command registry context, etc.) that still expects a
//! `PluginContext` value.
//!
//! Plugins themselves NEVER see this type in v3 of the ABI — they
//! receive a `PluginHandle` (u64) and call C ABI accessors. See
//! `abi.zig` and `host_abi.zig` for the boundary.

const std = @import("std");
const abi = @import("abi.zig");

/// Host-side context. Holds the handle the plugin sees plus the
/// allocator used for any host-side bookkeeping on behalf of the
/// plugin. The plugin never reads these fields.
pub const PluginContext = struct {
    allocator: std.mem.Allocator,
    plugin_id: []const u8,
    handle: abi.PluginHandle,

    pub fn init(
        allocator: std.mem.Allocator,
        plugin_id: []const u8,
        handle: abi.PluginHandle,
    ) PluginContext {
        return .{
            .allocator = allocator,
            .plugin_id = plugin_id,
            .handle = handle,
        };
    }

    pub fn deinit(self: *PluginContext) void {
        _ = self;
    }
};
