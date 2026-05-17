const std = @import("std");
const stem = @import("stem");

// Plugin state
var plugin_ctx: ?*stem.PluginContext = null;

fn init(ctx: *stem.PluginContext) i32 {
    plugin_ctx = ctx;

    // Register plugin stats command
    stem.registerCommand(
        ctx,
        "plugin-manager.stats",
        "[Plugin Manager] Show Stats",
        "Display plugin system statistics",
        cmdShowStats,
    ) catch return -1;

    // Register load/unload commands
    stem.registerCommand(
        ctx,
        "plugin.load",
        "[Plugin] Load",
        "Load a plugin from path",
        cmdLoadPlugin,
    ) catch return -1;

    stem.registerCommand(
        ctx,
        "plugin.unload",
        "[Plugin] Unload",
        "Unload a plugin by ID",
        cmdUnloadPlugin,
    ) catch return -1;

    // Subscribe to inter-plugin event
    stem.subscribeCustomEvent(ctx, "git.updated", onGitUpdated) catch return -1;

    return 0;
}

fn onGitUpdated(ctx: *stem.PluginContext, data: []const u8) void {
    stem.log(ctx, "Received inter-plugin event 'git.updated' with branch: {s}", .{data});
}

fn deinit(ctx: *stem.PluginContext) void {
    stem.deinitSdk(ctx);
    plugin_ctx = null;
}

fn handleMessage(ctx: *stem.PluginContext, msg: *const stem.PluginMessage) i32 {
    // Handle standard messages (command execution, etc.)
    if (stem.handleStandardMessages(ctx, msg)) {
        return 0;
    }
    return 0;
}

// Command callback - requests plugin list then shows it
fn cmdShowStats(ctx: *stem.PluginContext) void {
    stem.requestPluginList(ctx, onPluginListReceived) catch |err| {
        stem.log(ctx, "Failed to request plugin list: {s}", .{@errorName(err)});
    };
}

fn onPluginListReceived(ctx: *stem.PluginContext, data: []const u8) void {
    const plugins = stem.decodePluginList(ctx.allocator, data) catch |err| {
        stem.log(ctx, "Failed to decode plugin list: {s}", .{@errorName(err)});
        return;
    };
    defer ctx.allocator.free(plugins);

    // Format content as a Markdown table
    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer aw.deinit();
    const writer = &aw.writer;

    writer.writeAll("# Plugin Manager Dashboard\n\n") catch {};
    writer.writeAll("Real-time information about all loaded plugins.\n\n") catch {};
    writer.writeAll("| ID | Name | Status | Uptime | Widgets | Description |\n") catch {};
    writer.writeAll("| :--- | :--- | :--- | :--- | :--- | :--- |\n") catch {};

    for (plugins) |p| {
        const status = if (p.is_running) "**Running**" else "Stopped";
        const uptime_fmt = if (p.uptime_s < 60)
            std.fmt.allocPrint(ctx.allocator, "{d}s", .{p.uptime_s}) catch "0s"
        else if (p.uptime_s < 3600)
            std.fmt.allocPrint(ctx.allocator, "{d}m {d}s", .{ p.uptime_s / 60, p.uptime_s % 60 }) catch "0s"
        else
            std.fmt.allocPrint(ctx.allocator, "{d}h {d}m", .{ p.uptime_s / 3600, (p.uptime_s % 3600) / 60 }) catch "0s";
        defer if (p.uptime_s >= 0) ctx.allocator.free(uptime_fmt);

        writer.print("| `{s}` | {s} | {s} | {s} | {d} | {s} |\n", .{
            p.id,
            p.name,
            status,
            uptime_fmt,
            p.widget_count,
            p.description,
        }) catch {};
    }

    writer.writeAll("\n## Usage\n") catch {};
    writer.writeAll("- `plugin-manager.stats`: Refresh this dashboard\n") catch {};
    writer.writeAll("- `plugin.load <path>`: Load a plugin\n") catch {};
    writer.writeAll("- `plugin.unload <id>`: Unload a plugin\n") catch {};
    writer.writeAll("- `q`: Close this dashboard\n") catch {};

    stem.openBuffer(ctx, "[Plugin Dashboard]", aw.written()) catch {};
}

// Command callbacks
fn cmdLoadPlugin(ctx: *stem.PluginContext) void {
    stem.log(ctx, "Plugin loading via path is enabled. Use the command palette to provide arguments.", .{});
}

fn cmdUnloadPlugin(ctx: *stem.PluginContext) void {
    stem.log(ctx, "Plugin unloading via ID is enabled. Use the command palette to provide arguments.", .{});
}

// Export the plugin entry point
pub export const plugin_entry = stem.createPlugin(.{
    .name = "plugin_manager",
    .description = "Core plugin for managing and displaying loaded plugins",
    .init = init,
    .deinit = deinit,
    .handleMessage = handleMessage,
});
