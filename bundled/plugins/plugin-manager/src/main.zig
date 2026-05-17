//! Plugin Manager — provides the `[Plugin Dashboard]` virtual buffer,
//! exposes load/unload command stubs, and listens for inter-plugin
//! `git.updated` events to demonstrate the pub/sub bus.
//!
//! Migrated to plugin SDK v3:
//!   - `activate(handle)` replaces `init(ctx)`.
//!   - The `handle` (u64) is the only thing crossing the ABI boundary.
//!   - `handle_message` re-uses the SDK's `dispatch` helper.

const std = @import("std");
const stem = @import("stem");

fn activate(handle: stem.PluginHandle) callconv(.c) i32 {
    stem.bind(handle);

    stem.registerCommand(handle, "plugin-manager.stats", "[Plugin Manager] Show Stats", "Display plugin system statistics", cmdShowStats) catch return -1;
    stem.registerCommand(handle, "plugin.load", "[Plugin] Load", "Load a plugin from path", cmdLoadPlugin) catch return -1;
    stem.registerCommand(handle, "plugin.unload", "[Plugin] Unload", "Unload a plugin by ID", cmdUnloadPlugin) catch return -1;
    stem.subscribeCustomEvent(handle, "git.updated", onGitUpdated) catch return -1;
    return 0;
}

fn deactivate(handle: stem.PluginHandle) callconv(.c) void {
    _ = handle;
    stem.unbind();
}

fn handleMessage(handle: stem.PluginHandle, ptr: [*]const u8, len: usize) callconv(.c) i32 {
    return stem.dispatch(handle, ptr, len);
}

fn onGitUpdated(handle: stem.PluginHandle, data: []const u8) void {
    stem.log(handle, "Received inter-plugin event 'git.updated' with branch: {s}", .{data});
}

fn cmdShowStats(handle: stem.PluginHandle) void {
    stem.requestPluginList(handle, onPluginListReceived) catch |err| {
        stem.log(handle, "Failed to request plugin list: {s}", .{@errorName(err)});
    };
}

fn onPluginListReceived(handle: stem.PluginHandle, data: []const u8) void {
    const alloc = std.heap.page_allocator;
    const plugins = stem.decodePluginList(alloc, data) catch |err| {
        stem.log(handle, "Failed to decode plugin list: {s}", .{@errorName(err)});
        return;
    };
    defer alloc.free(plugins);

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    const w = &aw.writer;
    w.writeAll("# Plugin Manager Dashboard\n\n") catch {};
    w.writeAll("Real-time information about all loaded plugins.\n\n") catch {};
    w.writeAll("| ID | Name | Status | Uptime | Widgets | Description |\n") catch {};
    w.writeAll("| :--- | :--- | :--- | :--- | :--- | :--- |\n") catch {};
    for (plugins) |p| {
        const status = if (p.is_running) "**Running**" else "Stopped";
        const uptime_buf = std.fmt.allocPrint(alloc, "{d}s", .{p.uptime_s}) catch "?";
        defer if (uptime_buf.len > 1) alloc.free(uptime_buf);
        w.print("| `{s}` | {s} | {s} | {s} | {d} | {s} |\n", .{
            p.id, p.name, status, uptime_buf, p.widget_count, p.description,
        }) catch {};
    }
    w.writeAll("\n## Usage\n") catch {};
    w.writeAll("- `plugin-manager.stats`: Refresh this dashboard\n") catch {};
    w.writeAll("- `plugin.load <path>`: Load a plugin\n") catch {};
    w.writeAll("- `plugin.unload <id>`: Unload a plugin\n") catch {};
    w.writeAll("- `q`: Close this dashboard\n") catch {};
    stem.openBuffer(handle, "[Plugin Dashboard]", aw.written()) catch {};
}

fn cmdLoadPlugin(handle: stem.PluginHandle) void {
    stem.log(handle, "Plugin loading via path is enabled. Use the command palette to provide arguments.", .{});
}

fn cmdUnloadPlugin(handle: stem.PluginHandle) void {
    stem.log(handle, "Plugin unloading via ID is enabled. Use the command palette to provide arguments.", .{});
}

pub export const plugin_entry = stem.createPlugin(.{
    .name = "plugin_manager",
    .description = "Core plugin for managing and displaying loaded plugins",
    .activate = activate,
    .deactivate = deactivate,
    .handle_message = handleMessage,
});
