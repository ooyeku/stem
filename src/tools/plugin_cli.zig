//! `stem plugin <subcommand>` — operator tooling for the plugin system.
//!
//! Subcommands:
//!   - `list`            Show every plugin installed under ~/.stem/plugins.
//!   - `info <name>`     Pretty-print a plugin's manifest.
//!   - `install <path>`  Copy a plugin directory into ~/.stem/plugins.
//!   - `remove <name>`   Delete a plugin directory.
//!   - `test <path>`     Hermetic smoke test: parse the manifest, validate
//!                       the entry artifact, and (for wasm) run `activate`
//!                       against mocked host imports, reporting which
//!                       commands the plugin registers.
//!
//! Hermetic test mode is the most useful piece for plugin authors: they
//! can run `stem plugin test path/to/plugin/` from anywhere and see
//! immediately whether their wasm/manifest combination is well-formed
//! without touching ~/.stem/plugins.

const std = @import("std");

const manifest_mod = @import("../plugins/manifest.zig");
const wasm_loader = @import("../plugins/wasm/loader.zig");
const wasm_interp = @import("../plugins/wasm/interpreter.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_block: std.process.Environ.Block,
    /// `stem plugin <sub> [args...]` — `sub_args` excludes argv[0..2].
    sub: []const u8,
    sub_args: []const [:0]const u8,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
};

pub fn run(ctx: Context) !void {
    if (std.mem.eql(u8, ctx.sub, "list")) return runList(ctx);
    if (std.mem.eql(u8, ctx.sub, "info")) return runInfo(ctx);
    if (std.mem.eql(u8, ctx.sub, "install")) return runInstall(ctx);
    if (std.mem.eql(u8, ctx.sub, "remove")) return runRemove(ctx);
    if (std.mem.eql(u8, ctx.sub, "test")) return runTest(ctx);
    try ctx.err.print("error: unknown 'plugin' subcommand '{s}'. Try `list`, `info`, `install`, `remove`, or `test`.\n", .{ctx.sub});
}

// ---------------------------------------------------------------------------
// Filesystem helpers
// ---------------------------------------------------------------------------

fn pluginsRoot(allocator: std.mem.Allocator, environ_block: std.process.Environ.Block) ![]u8 {
    const env: std.process.Environ = .{ .block = environ_block };
    const home = env.getPosix("HOME") orelse {
        return error.NoHome;
    };
    return std.fs.path.join(allocator, &.{ home, ".stem", "plugins" });
}

/// Resolve `plugin_dir` to an absolute path (cwd-relative paths get
/// expanded). Caller owns the returned slice. Composes with the cwd
/// rather than calling `realPath` so it works for non-existent paths
/// (e.g. fresh install target dirs) and avoids the limited-platform
/// caveats called out on `realPathFile`.
fn absolutize(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    // `realPathFileAlloc(., ".")` is the idiom used elsewhere in stem
    // to materialize the current cwd as an absolute path. It works
    // whether or not the cwd's symlinks have been canonicalized.
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, path });
}

fn readManifest(allocator: std.mem.Allocator, io: std.Io, plugin_dir: []const u8) !manifest_mod.Manifest {
    const abs_dir = try absolutize(allocator, io, plugin_dir);
    defer allocator.free(abs_dir);
    const manifest_path = try std.fs.path.join(allocator, &.{ abs_dir, "plugin.json" });
    defer allocator.free(manifest_path);
    const file = try std.Io.Dir.openFileAbsolute(io, manifest_path, .{});
    defer file.close(io);
    const size = try file.length(io);
    if (size > 1 * 1024 * 1024) return error.ManifestTooLarge;
    const bytes = try allocator.alloc(u8, @intCast(size));
    defer allocator.free(bytes);
    _ = try file.readPositionalAll(io, bytes, 0);
    return manifest_mod.parse(allocator, bytes);
}

// ---------------------------------------------------------------------------
// list
// ---------------------------------------------------------------------------

fn runList(ctx: Context) !void {
    const root = pluginsRoot(ctx.allocator, ctx.environ_block) catch |err| {
        try ctx.err.print("error: could not determine ~/.stem/plugins: {s}\n", .{@errorName(err)});
        return;
    };
    defer ctx.allocator.free(root);

    var dir = std.Io.Dir.openDirAbsolute(ctx.io, root, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            try ctx.err.print("no plugins installed (directory does not exist: {s})\n", .{root});
            return;
        }
        try ctx.err.print("error: cannot open {s}: {s}\n", .{ root, @errorName(err) });
        return;
    };
    defer dir.close(ctx.io);

    try ctx.out.print("Plugins in {s}:\n\n", .{root});

    var it = dir.iterate();
    var count: usize = 0;
    while (it.next(ctx.io) catch null) |entry| {
        switch (entry.kind) {
            .directory => {
                const plugin_dir = try std.fs.path.join(ctx.allocator, &.{ root, entry.name });
                defer ctx.allocator.free(plugin_dir);
                if (readManifest(ctx.allocator, ctx.io, plugin_dir)) |m_const| {
                    var m = m_const;
                    defer m.deinit();
                    try ctx.out.print("  {s:<24} {s}  ({s})\n", .{ m.name, m.version, @tagName(m.runtime) });
                    if (m.description.len > 0) {
                        try ctx.out.print("    {s}\n", .{m.description});
                    }
                    count += 1;
                } else |_| {
                    // Stray directory without manifest — skip silently.
                }
            },
            else => {
                // Files at the top of `~/.stem/plugins/` are stale
                // artifacts from older releases (e.g. leftover .dylib
                // files); `install.sh` sweeps them. Plugins live as
                // directories now.
            },
        }
    }
    if (count == 0) {
        try ctx.out.print("  (none installed)\n", .{});
    }
}

// ---------------------------------------------------------------------------
// info
// ---------------------------------------------------------------------------

fn runInfo(ctx: Context) !void {
    if (ctx.sub_args.len == 0) {
        try ctx.err.print("usage: stem plugin info <name>\n", .{});
        return;
    }
    const name = ctx.sub_args[0];
    const root = try pluginsRoot(ctx.allocator, ctx.environ_block);
    defer ctx.allocator.free(root);
    const plugin_dir = try std.fs.path.join(ctx.allocator, &.{ root, name });
    defer ctx.allocator.free(plugin_dir);

    var m = readManifest(ctx.allocator, ctx.io, plugin_dir) catch |err| {
        try ctx.err.print("error: could not read plugin '{s}': {s}\n", .{ name, @errorName(err) });
        return;
    };
    defer m.deinit();
    try printManifest(ctx.out, &m);
}

fn printManifest(out: *std.Io.Writer, m: *const manifest_mod.Manifest) !void {
    try out.print("name:        {s}\n", .{m.name});
    try out.print("version:     {s}\n", .{m.version});
    try out.print("runtime:     {s}\n", .{@tagName(m.runtime)});
    try out.print("entry:       {s}\n", .{m.entry});
    if (m.description.len > 0) try out.print("description: {s}\n", .{m.description});
    if (m.permissions.spawn_allowlist.len > 0) {
        try out.print("permissions.spawn: ", .{});
        for (m.permissions.spawn_allowlist, 0..) |s, i| {
            if (i > 0) try out.print(", ", .{});
            try out.print("{s}", .{s});
        }
        try out.print("\n", .{});
    }
    if (m.permissions.filesystem.len > 0) {
        try out.print("permissions.fs:    ", .{});
        for (m.permissions.filesystem, 0..) |s, i| {
            if (i > 0) try out.print(", ", .{});
            try out.print("{s}", .{s});
        }
        try out.print("\n", .{});
    }
    if (m.permissions.events.len > 0) {
        try out.print("permissions.events:", .{});
        for (m.permissions.events, 0..) |s, i| {
            if (i > 0) try out.print(",", .{}) else try out.print(" ", .{});
            try out.print(" {s}", .{s});
        }
        try out.print("\n", .{});
    }
    if (m.commands.len > 0) {
        try out.print("commands:\n", .{});
        for (m.commands) |c| {
            try out.print("  {s}  —  {s}\n", .{ c.id, c.title });
            if (c.description.len > 0) try out.print("      {s}\n", .{c.description});
        }
    }
}

// ---------------------------------------------------------------------------
// install
// ---------------------------------------------------------------------------

fn runInstall(ctx: Context) !void {
    if (ctx.sub_args.len == 0) {
        try ctx.err.print("usage: stem plugin install <path>\n", .{});
        return;
    }
    const src = ctx.sub_args[0];

    // Verify source is a real plugin directory.
    var m = readManifest(ctx.allocator, ctx.io, src) catch |err| {
        try ctx.err.print("error: '{s}' does not look like a plugin directory: {s}\n", .{ src, @errorName(err) });
        return;
    };
    defer m.deinit();

    const root = try pluginsRoot(ctx.allocator, ctx.environ_block);
    defer ctx.allocator.free(root);
    std.Io.Dir.cwd().createDirPath(ctx.io, root) catch {};

    const dest = try std.fs.path.join(ctx.allocator, &.{ root, m.name });
    defer ctx.allocator.free(dest);

    // Refuse to overwrite. Operator can `remove` then `install` to upgrade.
    if (std.Io.Dir.openDirAbsolute(ctx.io, dest, .{})) |d_const| {
        var d = d_const;
        d.close(ctx.io);
        try ctx.err.print("error: '{s}' is already installed at {s}. Run `stem plugin remove {s}` first.\n", .{ m.name, dest, m.name });
        return;
    } else |_| {}

    std.Io.Dir.cwd().createDirPath(ctx.io, dest) catch |err| {
        try ctx.err.print("error: could not create {s}: {s}\n", .{ dest, @errorName(err) });
        return;
    };

    const abs_src = absolutize(ctx.allocator, ctx.io, src) catch |err| {
        try ctx.err.print("error: could not resolve {s}: {s}\n", .{ src, @errorName(err) });
        return;
    };
    defer ctx.allocator.free(abs_src);
    var src_dir = std.Io.Dir.openDirAbsolute(ctx.io, abs_src, .{ .iterate = true }) catch |err| {
        try ctx.err.print("error: cannot open source directory {s}: {s}\n", .{ abs_src, @errorName(err) });
        return;
    };
    defer src_dir.close(ctx.io);
    var dst_dir = std.Io.Dir.openDirAbsolute(ctx.io, dest, .{}) catch |err| {
        try ctx.err.print("error: cannot open dest directory {s}: {s}\n", .{ dest, @errorName(err) });
        return;
    };
    defer dst_dir.close(ctx.io);

    var iter = src_dir.iterate();
    var copied: usize = 0;
    while (iter.next(ctx.io) catch null) |entry| {
        if (entry.kind != .file) continue;
        src_dir.copyFile(entry.name, dst_dir, entry.name, ctx.io, .{}) catch |err| {
            try ctx.err.print("warning: could not copy {s}: {s}\n", .{ entry.name, @errorName(err) });
            continue;
        };
        copied += 1;
    }

    try ctx.out.print("Installed '{s}' to {s} ({d} file(s))\n", .{ m.name, dest, copied });
}

// ---------------------------------------------------------------------------
// remove
// ---------------------------------------------------------------------------

fn runRemove(ctx: Context) !void {
    if (ctx.sub_args.len == 0) {
        try ctx.err.print("usage: stem plugin remove <name>\n", .{});
        return;
    }
    const name = ctx.sub_args[0];
    const root = try pluginsRoot(ctx.allocator, ctx.environ_block);
    defer ctx.allocator.free(root);
    const dest = try std.fs.path.join(ctx.allocator, &.{ root, name });
    defer ctx.allocator.free(dest);

    std.Io.Dir.cwd().deleteTree(ctx.io, dest) catch |err| {
        try ctx.err.print("error: could not remove {s}: {s}\n", .{ dest, @errorName(err) });
        return;
    };
    try ctx.out.print("Removed plugin: {s}\n", .{name});
}

// ---------------------------------------------------------------------------
// test (hermetic smoke test)
// ---------------------------------------------------------------------------

const TestHarness = struct {
    allocator: std.mem.Allocator,
    commands: std.ArrayListUnmanaged([]u8) = .empty,
    logs: std.ArrayListUnmanaged([]u8) = .empty,

    fn onLog(ud: *anyopaque, _: []const u8, _: u8, msg: []const u8) void {
        const self: *TestHarness = @ptrCast(@alignCast(ud));
        const dup = self.allocator.dupe(u8, msg) catch return;
        self.logs.append(self.allocator, dup) catch self.allocator.free(dup);
    }
    fn onReg(ud: *anyopaque, _: []const u8, id: []const u8, _: []const u8, _: []const u8) void {
        const self: *TestHarness = @ptrCast(@alignCast(ud));
        const dup = self.allocator.dupe(u8, id) catch return;
        self.commands.append(self.allocator, dup) catch self.allocator.free(dup);
    }
    fn onNote(_: *anyopaque, _: []const u8, _: u8, _: []const u8) void {}
    fn onOpenBuf(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8) void {}
    fn onSpawn(_: *anyopaque, _: []const u8, _: []const u8, _: []u8) u32 {
        return 0;
    }

    fn deinit(self: *TestHarness) void {
        for (self.commands.items) |s| self.allocator.free(s);
        for (self.logs.items) |s| self.allocator.free(s);
        self.commands.deinit(self.allocator);
        self.logs.deinit(self.allocator);
    }
};

fn runTest(ctx: Context) !void {
    if (ctx.sub_args.len == 0) {
        try ctx.err.print("usage: stem plugin test <plugin-dir>\n", .{});
        return;
    }
    const dir_arg = ctx.sub_args[0];

    // Resolve relative-path diagnostics early so the user gets a
    // useful error showing exactly what stem looked for.
    const abs_for_err = absolutize(ctx.allocator, ctx.io, dir_arg) catch null;
    defer if (abs_for_err) |p| ctx.allocator.free(p);

    var m = readManifest(ctx.allocator, ctx.io, dir_arg) catch |err| {
        if (abs_for_err) |p| {
            try ctx.err.print("FAIL: manifest at {s}/plugin.json: {s}\n", .{ p, @errorName(err) });
        } else {
            try ctx.err.print("FAIL: manifest: {s}\n", .{@errorName(err)});
        }
        return;
    };
    defer m.deinit();
    try ctx.out.print("✓ manifest parses\n", .{});
    try ctx.out.print("  name={s} version={s} runtime={s}\n", .{ m.name, m.version, @tagName(m.runtime) });
    try ctx.out.print("  {d} command(s) declared\n", .{m.commands.len});

    // Entry path needs to be absolute for the wasm loader's
    // openFileAbsolute call. Resolve once here.
    const abs_dir = absolutize(ctx.allocator, ctx.io, dir_arg) catch |err| {
        try ctx.err.print("FAIL: could not resolve {s}: {s}\n", .{ dir_arg, @errorName(err) });
        return;
    };
    defer ctx.allocator.free(abs_dir);
    const entry_path = try std.fs.path.join(ctx.allocator, &.{ abs_dir, m.entry });
    defer ctx.allocator.free(entry_path);

    switch (m.runtime) {
        .wasm => {
            var harness: TestHarness = .{ .allocator = ctx.allocator };
            defer harness.deinit();
            const wp = wasm_loader.load(
                ctx.allocator,
                ctx.io,
                m.name,
                entry_path,
                .{
                    .user_data = @ptrCast(&harness),
                    .on_log = TestHarness.onLog,
                    .on_register_command = TestHarness.onReg,
                    .on_show_notification = TestHarness.onNote,
                    .on_open_buffer = TestHarness.onOpenBuf,
                    .on_spawn_capture = TestHarness.onSpawn,
                },
            ) catch |err| {
                try ctx.err.print("FAIL: wasm load: {s}\n", .{@errorName(err)});
                return;
            };
            defer {
                wp.deinit();
                ctx.allocator.destroy(wp);
            }
            try ctx.out.print("✓ wasm module decoded ({d} export(s))\n", .{wp.module.exports.len});
            wp.activate() catch |err| {
                try ctx.err.print("FAIL: activate: {s}\n", .{@errorName(err)});
                return;
            };
            try ctx.out.print("✓ activate ran\n", .{});
            try ctx.out.print("  plugin registered {d} command(s): ", .{harness.commands.items.len});
            for (harness.commands.items, 0..) |id, i| {
                if (i > 0) try ctx.out.print(", ", .{});
                try ctx.out.print("{s}", .{id});
            }
            try ctx.out.print("\n", .{});
            try ctx.out.print("  plugin emitted {d} log line(s)\n", .{harness.logs.items.len});

            // Cross-check: every command declared in the manifest
            // should also have been registered by `activate`. Missing
            // commands are likely a bug in the plugin.
            var missing: usize = 0;
            for (m.commands) |decl| {
                var found = false;
                for (harness.commands.items) |id| {
                    if (std.mem.eql(u8, id, decl.id)) {
                        found = true;
                        break;
                    }
                }
                if (!found) missing += 1;
            }
            if (missing > 0) {
                try ctx.err.print("warning: {d} manifest command(s) were not re-registered by activate (manifest-only path is fine but inconsistent)\n", .{missing});
            }
        },
        .exec => {
            // Verify the entry binary exists. Deeper exec testing
            // would spawn the child with mocked stdio — follow-up.
            const f = std.Io.Dir.openFileAbsolute(ctx.io, entry_path, .{}) catch |err| {
                try ctx.err.print("FAIL: exec entry not found at {s}: {s}\n", .{ entry_path, @errorName(err) });
                return;
            };
            f.close(ctx.io);
            try ctx.out.print("✓ exec entry exists ({s})\n", .{entry_path});
            try ctx.out.print("  (deeper exec testing requires spawning the child — not yet wired)\n", .{});
        },
    }
}
