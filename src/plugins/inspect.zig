//! Plugin capability inspector. Renders a human-readable report
//! covering every installed plugin's manifest, declared permissions,
//! restart policy, and live runtime state.
//!
//! Used by both the editor (`Plugin: Inspect` palette command opens
//! the report in a virtual `[Plugins]` buffer) and the CLI
//! (`stem plugin inspect`).

const std = @import("std");

const manifest_mod = @import("manifest.zig");
const PluginManager = @import("manager.zig").PluginManager;

/// Render the inspection report for every plugin directory under
/// `~/.stem/plugins/`. If `manager` is non-null, live runtime state
/// is mixed in; otherwise the report is manifest-only (useful for
/// the CLI, which doesn't have a running manager).
pub fn writeReport(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_block: std.process.Environ.Block,
    manager: ?*PluginManager,
    out: *std.Io.Writer,
) !void {
    // Cross-platform env access — env.getPosix is POSIX-only in Zig 0.16.
    const platform = @import("../kernel/platform.zig");
    const home_owned = (try platform.getEnv(allocator, environ_block, "HOME")) orelse
        (try platform.getEnv(allocator, environ_block, "USERPROFILE")) orelse
        return error.NoHome;
    defer allocator.free(home_owned);
    const plugins_root = try std.fs.path.join(allocator, &.{ home_owned, ".stem", "plugins" });
    defer allocator.free(plugins_root);

    try out.print("=== Stem Plugin Inspector ===\n", .{});
    try out.print("Root: {s}\n\n", .{plugins_root});

    var dir = std.Io.Dir.openDirAbsolute(io, plugins_root, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            try out.print("No plugins installed yet.\n", .{});
            try out.print("Install one with `stem plugin install <path>`.\n", .{});
            return;
        }
        return err;
    };
    defer dir.close(io);

    var any = false;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        any = true;
        try writeOne(allocator, io, plugins_root, entry.name, manager, out);
        try out.print("\n", .{});
    }
    if (!any) {
        try out.print("No plugins installed yet.\n", .{});
    }
}

/// Render a single plugin's inspection. Public so the CLI can drive a
/// per-name `stem plugin inspect <name>` workflow.
pub fn writeOne(
    allocator: std.mem.Allocator,
    io: std.Io,
    plugins_root: []const u8,
    name: []const u8,
    manager: ?*PluginManager,
    out: *std.Io.Writer,
) !void {
    const plugin_dir = try std.fs.path.join(allocator, &.{ plugins_root, name });
    defer allocator.free(plugin_dir);

    var manifest = readManifest(allocator, io, plugin_dir) catch |err| {
        try out.print("┌─ {s}\n", .{name});
        try out.print("│  ✗ could not read manifest: {s}\n", .{@errorName(err)});
        try out.print("│  (path: {s}/plugin.json)\n", .{plugin_dir});
        return;
    };
    defer manifest.deinit();

    try out.print("┌─ {s} ({s})\n", .{ manifest.name, manifest.version });
    if (manifest.description.len > 0) {
        try out.print("│  {s}\n", .{manifest.description});
    }
    try out.print("│\n", .{});

    // Live state (if a manager is available).
    if (manager) |m| {
        const live = m.liveStateOf(manifest.name);
        const status: []const u8 = if (live.loaded) "loaded" else "not loaded";
        try out.print("│  Runtime:     {s}    Status: {s}\n", .{ @tagName(manifest.runtime), status });
        try out.print("│  Entry:       {s}\n", .{manifest.entry});
        try out.print("│  Restart:     {s}", .{@tagName(live.restart_policy)});
        if (live.restart_attempts > 0) {
            try out.print("    (attempts: {d})", .{live.restart_attempts});
        }
        if (live.pending_restart_due_ms) |due| {
            try out.print("    (next attempt at ms={d})", .{due});
        }
        try out.print("\n", .{});
    } else {
        try out.print("│  Runtime:     {s}\n", .{@tagName(manifest.runtime)});
        try out.print("│  Entry:       {s}\n", .{manifest.entry});
        try out.print("│  Restart:     {s}\n", .{@tagName(manifest.restart)});
    }

    try out.print("│\n", .{});
    try out.print("│  Permissions\n", .{});
    try writePermList(out, "spawn", manifest.permissions.spawn_allowlist);
    try writePermList(out, "events", manifest.permissions.events);
    try writePermList(out, "filesystem", manifest.permissions.filesystem);
    try out.print("│    manage_plugins: {s}\n", .{if (manifest.permissions.manage_plugins) "yes" else "no"});

    if (manifest.commands.len > 0) {
        try out.print("│\n", .{});
        try out.print("│  Commands ({d})\n", .{manifest.commands.len});
        for (manifest.commands) |c| {
            try out.print("│    {s}\n", .{c.id});
            try out.print("│      title: {s}\n", .{c.title});
            if (c.description.len > 0) {
                try out.print("│      desc:  {s}\n", .{c.description});
            }
            if (c.keybinding) |kb| {
                try out.print("│      key:   {s}\n", .{kb});
            }
        }
    }

    // Artifact sanity check — does the entry exist next to the manifest?
    const entry_path = try std.fs.path.join(allocator, &.{ plugin_dir, manifest.entry });
    defer allocator.free(entry_path);
    try out.print("│\n", .{});
    if (std.Io.Dir.openFileAbsolute(io, entry_path, .{})) |f| {
        defer f.close(io);
        const size = f.length(io) catch 0;
        try out.print("│  Artifact:    {s}  ({d} bytes)\n", .{ entry_path, size });
    } else |err| {
        try out.print("│  Artifact:    ✗ MISSING — {s} ({s})\n", .{ entry_path, @errorName(err) });
    }
    try out.print("└─\n", .{});
}

fn writePermList(out: *std.Io.Writer, label: []const u8, items: []const []const u8) !void {
    if (items.len == 0) {
        try out.print("│    {s}: (none)\n", .{label});
        return;
    }
    try out.print("│    {s}:", .{label});
    for (items, 0..) |s, i| {
        if (i > 0) try out.print(",", .{});
        try out.print(" {s}", .{s});
    }
    try out.print("\n", .{});
}

fn readManifest(allocator: std.mem.Allocator, io: std.Io, plugin_dir: []const u8) !manifest_mod.Manifest {
    const manifest_path = try std.fs.path.join(allocator, &.{ plugin_dir, "plugin.json" });
    defer allocator.free(manifest_path);
    const file = try std.Io.Dir.openFileAbsolute(io, manifest_path, .{});
    defer file.close(io);
    const size = try file.length(io);
    if (size > 1 * 1024 * 1024) return error.ManifestTooLarge;
    const bytes = try allocator.alloc(u8, @intCast(size));
    defer allocator.free(bytes);
    const read_n = try file.readPositionalAll(io, bytes, 0);
    return manifest_mod.parse(allocator, bytes[0..read_n]);
}
