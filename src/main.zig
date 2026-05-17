const std = @import("std");
const vaxis = @import("vaxis");
const vigil = @import("vigil");
const EditorState = @import("core/state.zig").EditorState;
const protocol = @import("kernel/protocol.zig");
const Core = @import("kernel/core.zig").Core;
const search = @import("tools/search.zig");
const vfind = @import("tools/vfind.zig");
const scope = @import("tools/scope.zig");
const StorageManager = @import("config/storage.zig").StorageManager;
const help = @import("ui/help.zig");
const logger = @import("services/logger.zig");
const config = @import("config");

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logger.stdLogBridge,
};

/// Set by SIGINT / SIGTERM handlers. Polled by a monitor thread that wakes
/// the main loop with a `.quit` message so we exit via the same teardown
/// path the user would get from in-editor quit (Ctrl-C inside vaxis).
/// Module-level because signal handlers can't carry context. Async-signal
/// safe: only an atomic store happens in the handler itself.
var shutdown_requested: std.atomic.Value(bool) = .{ .raw = false };

fn handleShutdownSignal(_: std.c.SIG) callconv(.c) void {
    shutdown_requested.store(true, .release);
}

fn installShutdownSignals() !void {
    if (@import("builtin").os.tag == .windows) return; // POSIX-only for now.
    const sa: std.posix.Sigaction = .{
        .handler = .{ .handler = handleShutdownSignal },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART,
    };
    std.posix.sigaction(.INT, &sa, null);
    std.posix.sigaction(.TERM, &sa, null);
    std.posix.sigaction(.HUP, &sa, null);
}

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded = std.Io.Threaded.init(allocator, .{
        .argv0 = .init(.{ .vector = init.args.vector }),
        .environ = .{ .block = init.environ.block },
    });
    defer threaded.deinit();
    const io = threaded.io();

    var storage = try StorageManager.init(allocator, io, init.environ.block);
    defer storage.deinit();

    const log_level: logger.LogLevel = switch (storage.config.logging.level) {
        .debug => .debug,
        .info => .info,
        .warn => .warn,
        .err => .err,
    };

    try logger.init(allocator, io, storage.logs_dir, log_level);
    defer logger.deinit();
    var app = try vigil.app(allocator);
    defer app.shutdown();
    var inbox_gpa = std.heap.DebugAllocator(.{}).init;
    const inbox_allocator = inbox_gpa.allocator();
    var main_inbox = try vigil.inbox(inbox_allocator);
    var core_inbox = try vigil.inbox(inbox_allocator);

    const CoreContext = struct {
        core: Core,
        inbox: *vigil.Inbox,
    };

    // Collect args into a slice for ergonomic indexing/iteration below.
    var args_list = std.ArrayListUnmanaged([:0]const u8).empty;
    defer args_list.deinit(allocator);
    {
        var args_it = try std.process.Args.Iterator.initAllocator(init.args, allocator);
        defer args_it.deinit();
        while (args_it.next()) |a| {
            try args_list.append(allocator, try allocator.dupeZ(u8, a));
        }
    }
    const args = args_list.items;
    defer {
        for (args) |a| allocator.free(a);
    }
    var initial_files_to_open = std.ArrayListUnmanaged([]const u8).empty;
    defer {
        for (initial_files_to_open.items) |f| allocator.free(f);
        initial_files_to_open.deinit(allocator);
    }

    // Subcommand dispatch (config / logs / lsp) runs *before* file-arg
    // resolution so that `stem config set foo bar` doesn't try to resolve `set`
    // / `foo` / `bar` as paths and print stderr noise.
    const has_subcommand = args.len > 1 and
        (std.mem.eql(u8, args[1], "config") or
            std.mem.eql(u8, args[1], "logs") or
            std.mem.eql(u8, args[1], "lsp"));

    var skip_next = false;
    if (!has_subcommand) {
        for (args[1..], 1..) |arg, idx| {
            if (skip_next) {
                skip_next = false;
                continue;
            }
            if (std.mem.eql(u8, arg, "--open") or std.mem.eql(u8, arg, "-o")) {
                if (idx + 1 < args.len) {
                    const file_arg = args[idx + 1];
                    const resolved = resolveFilePath(allocator, io, file_arg) catch |err| blk: {
                        std.debug.print("Error: Cannot resolve path '{s}': {}\n", .{ file_arg, err });
                        break :blk null;
                    };
                    if (resolved) |path| {
                        try initial_files_to_open.append(allocator, path);
                    }
                    skip_next = true;
                }
                continue;
            }

            if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
                std.debug.print("stem {s} ({s})\n", .{ config.version, config.git_hash });
                return;
            }
            if (std.mem.startsWith(u8, arg, "-")) continue;
            if (std.mem.eql(u8, arg, "find")) {
                std.debug.print("Did you mean --find? 'find' cannot be opened as a file.\n", .{});
                return;
            } else if (std.mem.eql(u8, arg, "vfind")) {
                std.debug.print("Did you mean --vfind? 'vfind' cannot be opened as a file.\n", .{});
                return;
            } else if (std.mem.eql(u8, arg, "scope")) {
                std.debug.print("Did you mean --scope? 'scope' cannot be opened as a file.\n", .{});
                return;
            } else if (std.mem.eql(u8, arg, "help")) {
                std.debug.print("{s}\n", .{help.ansi_help_text});
                return;
            }

            const resolved = resolveFilePath(allocator, io, arg) catch |err| blk: {
                std.debug.print("Error: Cannot resolve path '{s}': {}\n", .{ arg, err });
                break :blk null;
            };

            if (resolved) |path| {
                try initial_files_to_open.append(allocator, path);
            }
        }
    }

    if (args.len > 1) {
        if (std.mem.eql(u8, args[1], "config")) {
            if (args.len < 3) {
                std.debug.print("Usage: stem config <get|set> [key] [value]\n", .{});
                return;
            }

            const action = args[2];
            if (std.mem.eql(u8, action, "get")) {
                if (args.len < 4) {
                    var aw: std.Io.Writer.Allocating = .init(allocator);
                    defer aw.deinit();
                    try storage.config.writeConfig(&aw.writer);
                    std.debug.print("{s}\n", .{aw.written()});
                    return;
                }

                const path = args[3];
                if (try storage.config.getByPath(path, allocator)) |val| {
                    std.debug.print("{s}\n", .{val});
                } else {
                    std.debug.print("Key not found: {s}\n", .{path});
                }
                return;
            } else if (std.mem.eql(u8, action, "list")) {
                var aw: std.Io.Writer.Allocating = .init(allocator);
                defer aw.deinit();
                try storage.config.writeConfig(&aw.writer);
                std.debug.print("{s}\n", .{aw.written()});
                return;
            } else if (std.mem.eql(u8, action, "set")) {
                if (args.len < 5) {
                    std.debug.print("Usage: stem config set <key> <value>\n", .{});
                    return;
                }
                const path = args[3];
                const val = args[4];

                if (try storage.config.setByPath(path, val, allocator)) {
                    try storage.save();
                    std.debug.print("Updated {s} to {s}\n", .{ path, val });
                } else {
                    std.debug.print("Failed to set {s}. Check key validity or types.\n", .{path});
                }
                return;
            } else if (std.mem.eql(u8, action, "unset")) {
                if (args.len < 4) {
                    std.debug.print("Usage: stem config unset <key>\n", .{});
                    return;
                }
                const path = args[3];
                if (storage.config.unsetByPath(path)) {
                    try storage.save();
                    std.debug.print("Reset {s} to default.\n", .{path});
                } else {
                    std.debug.print("Unknown key: {s}\n", .{path});
                }
                return;
            }
            return;
        }
        if (std.mem.eql(u8, args[1], "logs")) {
            if (args.len > 2 and std.mem.eql(u8, args[2], "--clear")) {
                var dir = std.Io.Dir.openDirAbsolute(io, storage.logs_dir, .{ .iterate = true }) catch |err| {
                    std.debug.print("Failed to open logs directory: {}\n", .{err});
                    return;
                };
                defer dir.close(io);

                var iter = dir.iterate();
                var cleared_count: usize = 0;
                while (iter.next(io)) |maybe_entry| {
                    const entry = maybe_entry orelse break;
                    if (entry.kind == .file and std.mem.startsWith(u8, entry.name, "stem-") and std.mem.endsWith(u8, entry.name, ".log")) {
                        if (dir.deleteFile(io, entry.name)) {
                            cleared_count += 1;
                        } else |err| {
                            std.debug.print("Could not delete {s}: {}\n", .{ entry.name, err });
                        }
                    }
                } else |err| {
                    std.debug.print("Error iterating logs: {}\n", .{err});
                }
                if (dir.deleteFile(io, "stem.log")) {
                    cleared_count += 1;
                } else |_| {}
                std.debug.print("Cleared {d} log file(s).\n", .{cleared_count});
            } else {
                var dir = std.Io.Dir.openDirAbsolute(io, storage.logs_dir, .{ .iterate = true }) catch |err| {
                    std.debug.print("Failed to open logs directory: {}\n", .{err});
                    return;
                };
                defer dir.close(io);

                var found_any = false;
                var iter = dir.iterate();
                while (iter.next(io) catch null) |entry| {
                    const is_instance_log = entry.kind == .file and
                        std.mem.startsWith(u8, entry.name, "stem-") and
                        std.mem.endsWith(u8, entry.name, ".log");
                    const is_legacy_log = entry.kind == .file and std.mem.eql(u8, entry.name, "stem.log");

                    if (is_instance_log or is_legacy_log) {
                        found_any = true;
                        const file = dir.openFile(io, entry.name, .{}) catch continue;
                        defer file.close(io);

                        const file_len = file.length(io) catch 0;
                        if (file_len > 0) {
                            const content = allocator.alloc(u8, @intCast(file_len)) catch continue;
                            defer allocator.free(content);
                            const n = file.readPositionalAll(io, content, 0) catch 0;
                            std.debug.print("{s}", .{content[0..n]});
                        }
                    }
                }
                if (!found_any) {
                    std.debug.print("No log files found.\n", .{});
                }
            }
            return;
        }
        if (std.mem.eql(u8, args[1], "lsp")) {
            if (args.len < 4 or !std.mem.eql(u8, args[2], "install")) {
                std.debug.print(
                    \\Usage: stem lsp install <language>
                    \\  language: python | typescript | go | rust | all
                    \\
                , .{});
                return;
            }
            const LSPManager = @import("services/lsp_manager.zig").LSPManager;
            var mgr = LSPManager.init(allocator, io, init.environ.block);
            defer mgr.deinit();
            mgr.installLanguageServer(args[3]) catch |err| {
                std.debug.print("LSP install failed: {}\n", .{err});
                return;
            };
            std.debug.print("Done.\n", .{});
            return;
        }
        var paths = std.ArrayListUnmanaged([]const u8).empty;
        defer paths.deinit(allocator);
        var extensions = std.ArrayListUnmanaged([]const u8).empty;
        defer extensions.deinit(allocator);
        var excludes = std.ArrayListUnmanaged([]const u8).empty;
        defer excludes.deinit(allocator);

        var command: ?[]const u8 = null;
        var query: ?[]const u8 = null;
        var file_path: ?[]const u8 = null;
        var open_file_path: ?[]const u8 = null;
        var before_lines: ?usize = null;
        var after_lines: ?usize = null;
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--find") or std.mem.eql(u8, arg, "--vfind")) {
                command = arg;
                if (i + 1 < args.len) {
                    query = args[i + 1];
                    i += 1;
                }
            } else if (std.mem.eql(u8, arg, "--scope")) {
                command = arg;
                if (i + 1 < args.len) {
                    file_path = args[i + 1];
                    if (i + 2 < args.len) {
                        query = args[i + 2];
                        i += 2;
                    } else {
                        i += 1;
                    }
                }
            } else if (std.mem.eql(u8, arg, "--before") or std.mem.eql(u8, arg, "-B")) {
                if (i + 1 < args.len) {
                    before_lines = try std.fmt.parseInt(usize, args[i + 1], 10);
                    i += 1;
                }
            } else if (std.mem.eql(u8, arg, "--after") or std.mem.eql(u8, arg, "-A")) {
                if (i + 1 < args.len) {
                    after_lines = try std.fmt.parseInt(usize, args[i + 1], 10);
                    i += 1;
                }
            } else if (std.mem.eql(u8, arg, "--path") or std.mem.eql(u8, arg, "-p")) {
                if (i + 1 < args.len) {
                    try paths.append(allocator, args[i + 1]);
                    i += 1;
                }
            } else if (std.mem.eql(u8, arg, "--ext") or std.mem.eql(u8, arg, "-e")) {
                if (i + 1 < args.len) {
                    try extensions.append(allocator, args[i + 1]);
                    i += 1;
                }
            } else if (std.mem.eql(u8, arg, "--exclude") or std.mem.eql(u8, arg, "-x")) {
                if (i + 1 < args.len) {
                    try excludes.append(allocator, args[i + 1]);
                    i += 1;
                }
            } else if (std.mem.eql(u8, arg, "--open") or std.mem.eql(u8, arg, "-o")) {
                if (i + 1 < args.len) {
                    open_file_path = args[i + 1];
                    i += 1;
                }
            } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                std.debug.print("{s}\n", .{help.ansi_help_text});
                return;
            }
        }
        var resolved_paths = std.ArrayListUnmanaged([]const u8).empty;
        defer resolved_paths.deinit(allocator);
        var base_dir: ?[]const u8 = null;
        const cwd = std.Io.Dir.cwd();
        const cwd_path = try cwd.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(cwd_path);
        for (paths.items) |path_arg| {
            const resolved = try cwd.realPathFileAlloc(io, path_arg, allocator);
            defer allocator.free(resolved);
            if (std.mem.startsWith(u8, resolved, cwd_path)) {
                if (resolved.len == cwd_path.len) {
                    try resolved_paths.append(allocator, try allocator.dupe(u8, ""));
                } else if (resolved.len > cwd_path.len and resolved[cwd_path.len] == '/') {
                    const relative = resolved[cwd_path.len + 1 ..];
                    try resolved_paths.append(allocator, try allocator.dupe(u8, relative));
                } else {
                    try resolved_paths.append(allocator, try allocator.dupe(u8, path_arg));
                }
            } else {
                var common_len: usize = 0;
                const min_len = @min(cwd_path.len, resolved.len);
                while (common_len < min_len and cwd_path[common_len] == resolved[common_len]) {
                    common_len += 1;
                }
                var last_slash: usize = 0;
                for (0..common_len) |j| {
                    if (cwd_path[j] == '/') {
                        last_slash = j;
                    }
                }
                if (last_slash > 0) {
                    if (base_dir == null) {
                        const cwd_remaining = cwd_path[last_slash + 1 ..];
                        var depth: usize = 0;
                        var pos: usize = 0;
                        while (pos < cwd_remaining.len) {
                            if (cwd_remaining[pos] == '/') {
                                depth += 1;
                                pos += 1;
                            } else {
                                while (pos < cwd_remaining.len and cwd_remaining[pos] != '/') {
                                    pos += 1;
                                }
                                depth += 1;
                                if (pos < cwd_remaining.len) {
                                    pos += 1;
                                }
                            }
                        }
                        var base_rel: std.Io.Writer.Allocating = .init(allocator);
                        defer base_rel.deinit();
                        for (0..depth) |_| {
                            try base_rel.writer.print("../", .{});
                        }
                        base_dir = try base_rel.toOwnedSlice();
                    }
                    if (resolved.len > last_slash + 1) {
                        const relative = resolved[last_slash + 1 ..];
                        try resolved_paths.append(allocator, try allocator.dupe(u8, relative));
                    } else {
                        try resolved_paths.append(allocator, try allocator.dupe(u8, ""));
                    }
                } else {
                    try resolved_paths.append(allocator, try allocator.dupe(u8, path_arg));
                }
            }
        }
        const final_base_dir = base_dir;
        var final_extensions: []const []const u8 = undefined;
        var needs_ext_cleanup = false;
        if (extensions.items.len == 0) {
            const default_ext = try allocator.dupe(u8, "zig");
            var ext_array = try allocator.alloc([]const u8, 1);
            ext_array[0] = default_ext;
            final_extensions = ext_array;
            needs_ext_cleanup = true;
        } else {
            final_extensions = try extensions.toOwnedSlice(allocator);
        }
        defer if (needs_ext_cleanup) {
            allocator.free(final_extensions[0]);
            allocator.free(final_extensions);
        } else {
            allocator.free(final_extensions);
        };
        const search_options = search.SearchOptions{
            .paths = try resolved_paths.toOwnedSlice(allocator),
            .extensions = final_extensions,
            .excludes = try excludes.toOwnedSlice(allocator),
            .base_dir = final_base_dir,
        };
        defer {
            for (search_options.paths) |p| {
                allocator.free(p);
            }
            allocator.free(search_options.paths);
            allocator.free(search_options.excludes);
            if (search_options.base_dir) |bd| {
                allocator.free(bd);
            }
        }
        if (command) |cmd| {
            if (std.mem.eql(u8, cmd, "--scope")) {
                if (file_path) |fp| {
                    if (query) |q| {
                        const scope_options = scope.ScopeOptions{
                            .before = before_lines orelse 3,
                            .after = after_lines orelse 3,
                        };
                        try scope.run(allocator, io, fp, q, scope_options);
                        return;
                    } else {
                        std.debug.print("Error: --scope requires a query\n", .{});
                        return;
                    }
                } else {
                    std.debug.print("Error: --scope requires a file path\n", .{});
                    return;
                }
            } else if (query) |q| {
                if (std.mem.eql(u8, cmd, "--find")) {
                    try search.run(allocator, io, q, search_options);
                    return;
                } else if (std.mem.eql(u8, cmd, "--vfind")) {
                    try vfind.run(allocator, io, q, search_options);
                    return;
                }
            }
        }
    }
    // Build env map for vaxis. TODO(zig-0.16): forward init.environ_map once
    // main() takes Init instead of Init.Minimal.
    var vaxis_env_map = try std.process.Environ.createMap(init.environ, allocator);
    defer vaxis_env_map.deinit();
    var vx = try vaxis.init(io, allocator, &vaxis_env_map, .{});
    const tty_buffer = try allocator.alloc(u8, 4096);
    defer allocator.free(tty_buffer);
    var tty = try vaxis.Tty.init(io, tty_buffer);
    defer tty.deinit();
    defer vx.deinit(allocator, tty.writer());
    var loop: vaxis.Loop(vaxis.Event) = .init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();
    // Without this, vaxis only emits the initial winsize event and never
    // sees subsequent SIGWINCHes, so the editor's snapshot stays sized for
    // whatever the terminal was when stem launched. With it, every host
    // resize re-emits a winsize event and our `.resize` handler propagates
    // it into core.win_size.
    try loop.installResizeHandler();

    // Graceful signal handling: when the user `kill`s stem (SIGTERM) or
    // hits Ctrl-C in a way that doesn't route through vaxis (SIGINT from a
    // background tty operation), we want the same clean teardown we'd do
    // on Ctrl-C in the editor — exit alt-screen, deinit core (LSP, scan
    // workers, syntax worker), restore the terminal. Without this, those
    // signals kill stem mid-render and leave the terminal scrambled and
    // LSP children orphaned.
    installShutdownSignals() catch |err| {
        std.log.warn("Failed to install signal handlers: {}", .{err});
    };
    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), std.Io.Duration.fromSeconds(1));
    vx.caps.sgr_pixels = false;
    try vx.setMouseMode(tty.writer(), true);
    var core_ctx = CoreContext{
        .core = try Core.init(allocator, io, init.environ.block, main_inbox, &storage, initial_files_to_open.items),
        .inbox = core_inbox,
    };
    defer core_ctx.core.deinit();
    // The LSP supervisor stores a pointer to the manager, so we can only
    // start it after `core_ctx.core` is in its final memory location.
    try core_ctx.core.lsp_manager.startSupervisor();

    // Spawn the background tree-sitter parse worker. After this, edits and
    // buffer switches submit parses asynchronously instead of blocking the
    // core thread on the parser.
    core_ctx.core.syntax_manager.startParseWorker(io) catch |err| {
        std.log.warn("Failed to start syntax parse worker: {}", .{err});
    };
    const Runner = struct {
        fn run(ctx: *CoreContext) void {
            ctx.core.run(ctx.inbox) catch |err| {
                if (err != error.UserQuit) {
                    std.debug.print("Core crashed: {}\n", .{err});
                }
            };
        }
    };
    const core_thread = try std.Thread.spawn(.{}, Runner.run, .{&core_ctx});
    defer core_thread.join();
    const InputThread = struct {
        loop: *vaxis.Loop(vaxis.Event),
        inbox: *vigil.Inbox,
        allocator: std.mem.Allocator,
        fn run(self: @This()) !void {
            while (true) {
                const event = self.loop.nextEvent() catch break;
                var msg: protocol.Message = undefined;
                switch (event) {
                    .key_press => |key| {
                        msg = .{ .input = key };
                    },
                    .mouse => |mouse| {
                        msg = .{ .mouse = mouse };
                    },
                    .winsize => |ws| {
                        msg = .{ .resize = ws };
                    },
                    .focus_in => {
                        msg = .{ .focus = true };
                    },
                    .focus_out => {
                        msg = .{ .focus = false };
                    },
                    else => continue,
                }
                const bytes = msg.encode(self.allocator) catch continue;
                defer self.allocator.free(bytes);
                self.inbox.send(bytes) catch break;
            }
        }
    };
    const input_thread = try std.Thread.spawn(.{}, InputThread.run, .{InputThread{
        .loop = &loop,
        .inbox = main_inbox,
        .allocator = inbox_allocator,
    }});
    defer input_thread.detach();

    const HeartbeatThread = struct {
        inbox: *vigil.Inbox,
        allocator: std.mem.Allocator,
        io: std.Io,
        fn run(self: @This()) !void {
            while (true) {
                std.Io.sleep(self.io, .fromMilliseconds(100), .awake) catch break;
                var tick_msg: protocol.Message = .tick;
                const bytes = tick_msg.encode(self.allocator) catch continue;
                defer self.allocator.free(bytes);
                self.inbox.send(bytes) catch break;
            }
        }
    };
    const heartbeat_thread = try std.Thread.spawn(.{}, HeartbeatThread.run, .{HeartbeatThread{
        .inbox = core_inbox,
        .allocator = inbox_allocator,
        .io = io,
    }});
    heartbeat_thread.detach();

    // Signal monitor: polls the `shutdown_requested` flag set by the
    // SIGINT/SIGTERM/SIGHUP handler. When set, injects a `.quit` into
    // `main_inbox` so the UI loop wakes and runs the normal teardown
    // path. This is what makes `kill -TERM <pid>` exit stem cleanly.
    const SignalMonitor = struct {
        inbox: *vigil.Inbox,
        allocator: std.mem.Allocator,
        io: std.Io,
        fn run(self: @This()) void {
            while (true) {
                std.Io.sleep(self.io, .fromMilliseconds(200), .awake) catch return;
                if (shutdown_requested.load(.acquire)) {
                    const msg = (protocol.Message{ .quit = {} }).encode(self.allocator) catch return;
                    defer self.allocator.free(msg);
                    self.inbox.send(msg) catch {};
                    return;
                }
            }
        }
    };
    const signal_monitor_thread = try std.Thread.spawn(.{}, SignalMonitor.run, .{SignalMonitor{
        .inbox = main_inbox,
        .allocator = inbox_allocator,
        .io = io,
    }});
    signal_monitor_thread.detach();
    const View = @import("ui/view.zig").View;
    var view = View.init(allocator);
    var loop_arena = std.heap.ArenaAllocator.init(allocator);
    defer loop_arena.deinit();
    var snapshot_arena = std.heap.ArenaAllocator.init(allocator);
    defer snapshot_arena.deinit();
    var last_snapshot: ?*protocol.RenderSnapshot = null;
    var last_arena: ?*std.heap.ArenaAllocator = null;
    var last_arena_pool: ?*@import("kernel/arena_pool.zig").ArenaPool = null;
    while (true) {
        const msg = main_inbox.recv() catch break;
        defer msg.deinit();
        if (msg.payload) |payload| {
            const decoded = protocol.Message.decode(payload) catch |err| {
                std.debug.print("UI failed to decode msg: {}\n", .{err});
                continue;
            };
            switch (decoded) {
                .input => |key| {
                    if (key.matches('c', .{ .ctrl = true })) {
                        const quit_bytes = (protocol.Message{ .quit = {} }).encode(allocator) catch break;
                        defer allocator.free(quit_bytes);
                        core_inbox.send(quit_bytes) catch {};
                        break;
                    }
                    const fwd_bytes = (protocol.Message{ .input = key }).encode(allocator) catch continue;
                    defer allocator.free(fwd_bytes);
                    core_inbox.send(fwd_bytes) catch {};
                },
                .mouse => |mouse| {
                    const fwd_bytes = (protocol.Message{ .mouse = mouse }).encode(allocator) catch continue;
                    defer allocator.free(fwd_bytes);
                    core_inbox.send(fwd_bytes) catch {};
                },
                .resize => |ws| {
                    try vx.resize(allocator, tty.writer(), ws);

                    const resize_bytes = (protocol.Message{ .resize = ws }).encode(allocator) catch continue;
                    defer allocator.free(resize_bytes);
                    core_inbox.send(resize_bytes) catch {};

                    if (last_snapshot) |snap| {
                        try view.draw(&vx, snap, loop_arena.allocator());
                        try vx.render(tty.writer());
                    }
                    _ = loop_arena.reset(.retain_capacity);
                },
                .render_update => |update| {
                    // Hand the previous frame's arena back to the pool — pages
                    // are kept and reused on the next acquire().
                    if (last_arena) |arena| {
                        if (last_arena_pool) |pool| pool.release(arena);
                    }

                    const snapshot_ptr: *protocol.RenderSnapshot = @ptrFromInt(update.snapshot_ptr);
                    const arena_ptr: *std.heap.ArenaAllocator = @ptrFromInt(update.arena_ptr);
                    const pool_ptr: *@import("kernel/arena_pool.zig").ArenaPool = @ptrFromInt(update.pool_ptr);

                    last_snapshot = snapshot_ptr;
                    last_arena = arena_ptr;
                    last_arena_pool = pool_ptr;

                    try view.draw(&vx, snapshot_ptr, loop_arena.allocator());
                    try vx.render(tty.writer());
                    _ = loop_arena.reset(.retain_capacity);
                },
                .command => |cmd| {
                    if (cmd == .quit) {
                        break;
                    }
                },
                .quit => break,
                .focus => |focused| {
                    if (focused) {
                        try vx.setMouseMode(tty.writer(), true);
                    }
                },
                else => {},
            }
        }
    }
    vx.setMouseMode(tty.writer(), false) catch {};
    vx.exitAltScreen(tty.writer()) catch {};
    std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
    main_inbox.closed.store(true, .release);
    core_inbox.closed.store(true, .release);
    if (last_arena) |arena| {
        if (last_arena_pool) |pool| pool.release(arena);
    }
    while (true) {
        if (main_inbox.mailbox.receive()) |msg| {
            if (msg.payload) |payload| {
                if (protocol.Message.decode(payload) catch null) |decoded| {
                    if (decoded == .render_update) {
                        const update = decoded.render_update;
                        const arena_ptr: *std.heap.ArenaAllocator = @ptrFromInt(update.arena_ptr);
                        const pool_ptr: *@import("kernel/arena_pool.zig").ArenaPool = @ptrFromInt(update.pool_ptr);
                        pool_ptr.release(arena_ptr);
                    }
                }
            }
            msg.deinit();
        } else |_| {
            break;
        }
    }
    while (true) {
        if (core_inbox.mailbox.receive()) |msg| {
            msg.deinit();
        } else |_| {
            break;
        }
    }
}

fn resolvePath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    const resolved_path = if (std.fs.path.isAbsolute(path))
        allocator.dupe(u8, path) catch {
            std.debug.print("Memory error\n", .{});
            return error.MemoryError;
        }
    else
        cwd.realPathFileAlloc(io, path, allocator) catch {
            std.debug.print("Error: Cannot find file '{s}'\n", .{path});
            return error.FileNotFound;
        };
    return resolved_path;
}

fn resolveFilePath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.isAbsolute(path)) {
        return allocator.dupe(u8, path);
    }

    return cwd.realPathFileAlloc(io, path, allocator) catch |err| {
        if (err == error.FileNotFound) {
            const cwd_path = try cwd.realPathFileAlloc(io, ".", allocator);
            defer allocator.free(cwd_path);
            return std.fs.path.resolve(allocator, &.{ cwd_path, path });
        }
        return err;
    };
}
