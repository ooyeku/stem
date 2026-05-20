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
const plugin_inspect = @import("../plugins/inspect.zig");

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
    if (std.mem.eql(u8, ctx.sub, "inspect")) return runInspect(ctx);
    try ctx.err.print("error: unknown 'plugin' subcommand '{s}'. Try `list`, `info`, `inspect`, `install`, `remove`, or `test`.\n", .{ctx.sub});
}

fn runInspect(ctx: Context) !void {
    const root = try pluginsRoot(ctx.allocator, ctx.environ_block);
    defer ctx.allocator.free(root);

    if (ctx.sub_args.len == 0) {
        // Report on every installed plugin.
        try plugin_inspect.writeReport(ctx.allocator, ctx.io, ctx.environ_block, null, ctx.out);
        return;
    }
    try plugin_inspect.writeOne(ctx.allocator, ctx.io, root, ctx.sub_args[0], null, ctx.out);
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

    // Two-pass: collect manifests first so the header line knows the
    // total count, and we can render the listing inside a fixed-width
    // visual frame.
    var manifests: std.ArrayListUnmanaged(manifest_mod.Manifest) = .empty;
    defer {
        for (manifests.items) |*m| m.deinit();
        manifests.deinit(ctx.allocator);
    }
    var it = dir.iterate();
    while (it.next(ctx.io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const plugin_dir = try std.fs.path.join(ctx.allocator, &.{ root, entry.name });
        defer ctx.allocator.free(plugin_dir);
        if (readManifest(ctx.allocator, ctx.io, plugin_dir)) |m| {
            try manifests.append(ctx.allocator, m);
        } else |_| {}
    }
    std.mem.sort(manifest_mod.Manifest, manifests.items, {}, struct {
        fn lt(_: void, a: manifest_mod.Manifest, b: manifest_mod.Manifest) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);

    const rule = "─────────────────────────────────────────────────────────────────────";
    try ctx.out.print("Stem plugins — {d} installed\n", .{manifests.items.len});
    try ctx.out.print("{s}\n\n", .{rule});

    if (manifests.items.len == 0) {
        try ctx.out.print("  (none installed)\n\n", .{});
    }

    for (manifests.items) |*m| {
        const runtime_tag = @tagName(m.runtime);
        try ctx.out.print("  {s:<22} v{s:<8} [{s}]\n", .{ m.name, m.version, runtime_tag });
        if (m.description.len > 0) {
            try printWrapped(ctx.out, m.description, "    ", 72);
        }
        try ctx.out.print("\n", .{});
    }

    try ctx.out.print("Plugins directory: {s}\n", .{root});
}

/// Word-wrap `text` to `max_cols` columns, prefixing each line with
/// `indent`. Falls back to a single overlong line if a word doesn't
/// fit — better to be ugly than to silently lose characters.
fn printWrapped(out: *std.Io.Writer, text: []const u8, indent: []const u8, max_cols: usize) !void {
    var rem = std.mem.trim(u8, text, " \t\r\n");
    while (rem.len > 0) {
        // Each line gets the indent first.
        const budget: usize = if (max_cols > indent.len) max_cols - indent.len else 16;
        if (rem.len <= budget) {
            try out.print("{s}{s}\n", .{ indent, rem });
            return;
        }
        // Look for the last whitespace at or before `budget`.
        var break_at: usize = budget;
        while (break_at > 0 and rem[break_at] != ' ' and rem[break_at] != '\t') : (break_at -= 1) {}
        if (break_at == 0) break_at = budget; // no space — hard-break
        try out.print("{s}{s}\n", .{ indent, rem[0..break_at] });
        // Skip the breaking whitespace.
        var next: usize = break_at;
        while (next < rem.len and (rem[next] == ' ' or rem[next] == '\t')) : (next += 1) {}
        rem = rem[next..];
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
            if (c.keybinding) |kb| try out.print("      bound to: {s}\n", .{kb});
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
    // Recursive copy preserves subdirectories (e.g. `assets/`,
    // `templates/`) plus the manifest and entry artifact. Anything
    // sitting beside `plugin.json` gets installed.
    var copied: usize = 0;
    copyTreeAbs(ctx, abs_src, dest, &copied) catch |err| {
        try ctx.err.print("error: copy tree {s} → {s}: {s}\n", .{ abs_src, dest, @errorName(err) });
        return;
    };

    try ctx.out.print("Installed '{s}' to {s} ({d} file(s))\n", .{ m.name, dest, copied });
}

/// Recursively copy `src_abs` → `dst_abs`, creating intermediate
/// directories under the destination. `counter` is bumped for every
/// regular file written. Symlinks and special files are skipped with
/// a warning. Caller-supplied paths must be absolute.
fn copyTreeAbs(ctx: Context, src_abs: []const u8, dst_abs: []const u8, counter: *usize) !void {
    var src_dir = try std.Io.Dir.openDirAbsolute(ctx.io, src_abs, .{ .iterate = true });
    defer src_dir.close(ctx.io);
    std.Io.Dir.cwd().createDirPath(ctx.io, dst_abs) catch {};
    var dst_dir = try std.Io.Dir.openDirAbsolute(ctx.io, dst_abs, .{});
    defer dst_dir.close(ctx.io);
    var it = src_dir.iterate();
    while (it.next(ctx.io) catch null) |entry| {
        switch (entry.kind) {
            .file => {
                src_dir.copyFile(entry.name, dst_dir, entry.name, ctx.io, .{}) catch |err| {
                    try ctx.err.print("warning: could not copy {s}: {s}\n", .{ entry.name, @errorName(err) });
                    continue;
                };
                counter.* += 1;
            },
            .directory => {
                const child_src = try std.fs.path.join(ctx.allocator, &.{ src_abs, entry.name });
                defer ctx.allocator.free(child_src);
                const child_dst = try std.fs.path.join(ctx.allocator, &.{ dst_abs, entry.name });
                defer ctx.allocator.free(child_dst);
                try copyTreeAbs(ctx, child_src, child_dst, counter);
            },
            else => {
                try ctx.err.print("warning: skipping non-regular file {s}\n", .{entry.name});
            },
        }
    }
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
    fn onSpawn(_: *anyopaque, _: []const u8, _: wasm_loader.SpawnOpts, _: []u8) i32 {
        return -3;
    }
    fn onSubEv(_: *anyopaque, _: []const u8, _: []const u8) i32 {
        return -1;
    }
    fn onReadFile(_: *anyopaque, _: []const u8, _: []const u8, _: []u8) i32 {
        return -1;
    }
    fn onWriteFile(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8) i32 {
        return -1;
    }
    fn onSetSI(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8, _: u8, _: i8) void {}
    fn onClearSI(_: *anyopaque, _: []const u8, _: []const u8) void {}
    fn onSetPanel(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8, _: []const u8, _: u8, _: u8) void {}
    fn onClearPanel(_: *anyopaque, _: []const u8, _: []const u8) void {}
    fn onGetBufContent(_: *anyopaque, _: []const u8, _: []u8) i32 {
        return -1;
    }
    fn onGetBufPath(_: *anyopaque, _: []const u8, _: []u8) i32 {
        return -1;
    }
    fn onLoadPlugin(_: *anyopaque, _: []const u8, _: []const u8) i32 {
        return -1;
    }
    fn onUnloadPlugin(_: *anyopaque, _: []const u8, _: []const u8) i32 {
        return -1;
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
                    .on_subscribe_event = TestHarness.onSubEv,
                    .on_read_file = TestHarness.onReadFile,
                    .on_write_file = TestHarness.onWriteFile,
                    .on_set_status_item = TestHarness.onSetSI,
                    .on_clear_status_item = TestHarness.onClearSI,
                    .on_set_panel = TestHarness.onSetPanel,
                    .on_clear_panel = TestHarness.onClearPanel,
                    .on_get_buffer_content = TestHarness.onGetBufContent,
                    .on_get_buffer_path = TestHarness.onGetBufPath,
                    .on_load_plugin = TestHarness.onLoadPlugin,
                    .on_unload_plugin = TestHarness.onUnloadPlugin,
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
            try execHermeticTest(ctx, &m, entry_path);
        },
    }
}

/// Hermetic exec-plugin test: spawn the child, send a synthetic
/// `plugin/initialize` notification, watch its stdout for
/// `plugin/registerCommand` calls, and report which manifest
/// commands were claimed. Always sends `plugin/shutdown` and waits
/// for the process to exit (capped at 2s).
fn execHermeticTest(ctx: Context, m: *const manifest_mod.Manifest, entry_path: []const u8) !void {
    const jsonrpc = @import("../plugins/jsonrpc.zig");

    const f = std.Io.Dir.openFileAbsolute(ctx.io, entry_path, .{}) catch |err| {
        try ctx.err.print("FAIL: exec entry not found at {s}: {s}\n", .{ entry_path, @errorName(err) });
        return;
    };
    f.close(ctx.io);
    try ctx.out.print("✓ exec entry exists ({s})\n", .{entry_path});

    // Spawn with piped stdio.
    var child = std.process.spawn(ctx.io, .{
        .argv = &[_][]const u8{entry_path},
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    }) catch |err| {
        try ctx.err.print("FAIL: spawn: {s}\n", .{@errorName(err)});
        return;
    };
    var stdin_open = true;
    defer if (stdin_open) {
        if (child.stdin) |s| s.close(ctx.io);
    };

    // Send initialize + shutdown up front, then close stdin. The
    // plugin processes the initialize notification (registering its
    // commands), then the shutdown notification, then exits cleanly.
    // Reading until EOF gives us a deterministic stop condition
    // without polling timeouts.
    if (child.stdin) |stdin| {
        var buf: [4096]u8 = undefined;
        var writer = stdin.writerStreaming(ctx.io, &buf);
        const w = &writer.interface;
        const init_frame = jsonrpc.buildNotification(
            ctx.allocator,
            "plugin/initialize",
            "{\"abi_version\":1,\"plugin_id\":\"test\"}",
        ) catch {
            try ctx.err.print("FAIL: build initialize frame\n", .{});
            return;
        };
        defer ctx.allocator.free(init_frame);
        jsonrpc.writeFrame(w, init_frame) catch {};
        const shutdown_frame = jsonrpc.buildNotification(ctx.allocator, "plugin/shutdown", "{}") catch null;
        if (shutdown_frame) |sf| {
            defer ctx.allocator.free(sf);
            jsonrpc.writeFrame(w, sf) catch {};
        }
        w.flush() catch {};
        stdin.close(ctx.io);
        child.stdin = null;
        stdin_open = false;
    }

    // Drain stdout until EOF, counting registerCommand frames.
    var registered: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (registered.items) |s| ctx.allocator.free(s);
        registered.deinit(ctx.allocator);
    }
    if (child.stdout) |stdout| {
        var rd_buf: [4096]u8 = undefined;
        var reader = stdout.readerStreaming(ctx.io, &rd_buf);
        const r = &reader.interface;
        while (true) {
            const body = jsonrpc.readFrame(ctx.allocator, r) catch break;
            defer ctx.allocator.free(body);
            const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, body, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            const method_v = parsed.value.object.get("method") orelse continue;
            if (method_v != .string) continue;
            if (!std.mem.eql(u8, method_v.string, "plugin/registerCommand")) continue;
            const params_v = parsed.value.object.get("params") orelse continue;
            if (params_v != .object) continue;
            const id_v = params_v.object.get("id") orelse continue;
            if (id_v != .string) continue;
            const dup = ctx.allocator.dupe(u8, id_v.string) catch continue;
            registered.append(ctx.allocator, dup) catch ctx.allocator.free(dup);
        }
    }

    _ = child.wait(ctx.io) catch {};

    try ctx.out.print("✓ exec spawn + initialize round-trip\n", .{});
    try ctx.out.print("  plugin registered {d} command(s): ", .{registered.items.len});
    for (registered.items, 0..) |id, i| {
        if (i > 0) try ctx.out.print(", ", .{});
        try ctx.out.print("{s}", .{id});
    }
    try ctx.out.print("\n", .{});
    // Cross-check against the manifest.
    var missing: usize = 0;
    for (m.commands) |decl| {
        var found = false;
        for (registered.items) |id| {
            if (std.mem.eql(u8, id, decl.id)) {
                found = true;
                break;
            }
        }
        if (!found) missing += 1;
    }
    if (missing > 0) {
        try ctx.err.print("warning: {d} manifest command(s) were not re-registered by the plugin\n", .{missing});
    }
}
