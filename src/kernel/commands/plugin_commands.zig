//! Editor-side commands that operate on the plugin system. These
//! complement the `stem plugin ...` CLI tooling — they're the
//! palette-accessible equivalents.

const std = @import("std");
const manifest_mod = @import("../../plugins/manifest.zig");
const plugin_inspect = @import("../../plugins/inspect.zig");

pub const PluginCommands = struct {
    /// Render an [Plugins] virtual buffer listing every installed
    /// plugin with its live state: runtime, load status, declared
    /// permissions, restart policy, and any pending restart backoff.
    /// Each entry maps directly onto the `liveStateOf` snapshot, so
    /// this view stays accurate after crashes / unloads / reloads.
    pub fn cmdPluginInspect(core: anytype) anyerror!void {
        var buf = std.ArrayListUnmanaged(u8).empty;
        defer buf.deinit(core.allocator);
        var aw = std.Io.Writer.Allocating.fromArrayList(core.allocator, &buf);

        try plugin_inspect.writeReport(
            core.allocator,
            core.io,
            core.environ_block,
            &core.plugin_manager,
            &aw.writer,
        );

        try core.openVirtualBuffer("[Plugins]", aw.written());
        core.setStatusLiteral("Plugin inspection opened", 1500);
    }
};
