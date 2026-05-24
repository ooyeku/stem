//! CLI dispatcher for the `stem` binary.
//!
//! One pass over argv decides:
//!   - "this is a subcommand, run it and exit"   → `.handled`
//!   - "these are paths, launch the editor"      → `.run_editor`
//!
//! Subcommands are bare verbs (`find`, `vfind`, `scope`, `config`, `logs`,
//! `lsp`, `help`, `version`). Any unrecognized first arg is treated as a
//! path to open. Long-form flag aliases (`--find`, `--vfind`, `--scope`)
//! are accepted for backwards compatibility and silently routed to the
//! matching subcommand.
//!
//! The help text is generated from `command_specs` below; keep that table
//! as the single source of truth for surface area.

const std = @import("std");
const builtin = @import("builtin");

const platform = @import("kernel/platform.zig");
const search_tool = @import("tools/search.zig");
const vfind_tool = @import("tools/vfind.zig");
const scope_tool = @import("tools/scope.zig");
const plugin_cli = @import("tools/plugin_cli.zig");
const StorageManager = @import("config/storage.zig").StorageManager;
const LSPManager = @import("services/lsp_manager.zig").LSPManager;
const installer_mod = @import("services/lsp/installer.zig");
const Installer = installer_mod.Installer;
const config_mod = @import("config");

pub const Action = union(enum) {
    /// Caller should proceed to launch the editor with these paths.
    /// Caller owns the slice and each entry (allocated with `ctx.allocator`).
    run_editor: [][]const u8,
    /// Subcommand ran and produced its output; caller should exit.
    handled,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// argv including argv[0].
    args: []const [:0]const u8,
    storage: *StorageManager,
    environ_block: std.process.Environ.Block,
};

/// Entry point. Returns either `.run_editor` (caller launches the TUI) or
/// `.handled` (subcommand already produced output; caller should exit).
pub fn dispatch(ctx: Context) !Action {
    if (ctx.args.len <= 1) {
        return Action{ .run_editor = try emptyPaths(ctx.allocator) };
    }

    const first = ctx.args[1];

    // Global flags that short-circuit, regardless of subcommand context.
    if (isHelpFlag(first)) {
        try printHelp(ctx.io);
        return .handled;
    }
    if (isVersionFlag(first)) {
        try printVersion(ctx.io);
        return .handled;
    }

    // Bare-verb dispatch. Old `--`-prefixed aliases route to the same path.
    const verb = resolveVerb(first);
    if (verb) |v| {
        return dispatchVerb(ctx, v);
    }

    // Not a verb — every non-flag arg is a path to open.
    return Action{ .run_editor = try collectPaths(ctx) };
}

// ---------------------------------------------------------------------------
// Verbs
// ---------------------------------------------------------------------------

const Verb = enum {
    find,
    vfind,
    scope,
    config,
    logs,
    lsp,
    plugin,
    doctor,
    help,
    version,
};

fn resolveVerb(arg: [:0]const u8) ?Verb {
    const table = .{
        .{ "find", Verb.find },     .{ "--find", Verb.find },     .{ "-f", Verb.find },
        .{ "vfind", Verb.vfind },   .{ "--vfind", Verb.vfind },   .{ "scope", Verb.scope },
        .{ "--scope", Verb.scope }, .{ "config", Verb.config },   .{ "logs", Verb.logs },
        .{ "log", Verb.logs },      .{ "lsp", Verb.lsp },         .{ "help", Verb.help },
        .{ "plugin", Verb.plugin }, .{ "plugins", Verb.plugin },  .{ "doctor", Verb.doctor },
        .{ "check", Verb.doctor },  .{ "version", Verb.version },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, arg, entry[0])) return entry[1];
    }
    return null;
}

fn dispatchVerb(ctx: Context, verb: Verb) !Action {
    // Per-subcommand help: `stem <verb> --help` or `stem <verb> -h`.
    if (ctx.args.len >= 3 and isHelpFlag(ctx.args[2])) {
        try printVerbHelp(ctx.io, verb);
        return .handled;
    }

    switch (verb) {
        .help => try printHelp(ctx.io),
        .version => try printVersion(ctx.io),
        .find => try runSearch(ctx, .grep),
        .vfind => try runSearch(ctx, .visual),
        .scope => try runScope(ctx),
        .config => try runConfig(ctx),
        .logs => try runLogs(ctx),
        .lsp => try runLsp(ctx),
        .plugin => try runPlugin(ctx),
        .doctor => try runDoctor(ctx),
    }
    return .handled;
}

// ---------------------------------------------------------------------------
// Path collection (editor launch path)
// ---------------------------------------------------------------------------

fn emptyPaths(allocator: std.mem.Allocator) ![][]const u8 {
    return try allocator.alloc([]const u8, 0);
}

fn collectPaths(ctx: Context) ![][]const u8 {
    var out = std.ArrayListUnmanaged([]const u8).empty;
    errdefer {
        for (out.items) |p| ctx.allocator.free(p);
        out.deinit(ctx.allocator);
    }

    var i: usize = 1;
    while (i < ctx.args.len) : (i += 1) {
        const a = ctx.args[i];
        // Skip unknown flags rather than treat them as paths — quietly
        // accepted for forward-compat with future editor-only flags.
        if (std.mem.startsWith(u8, a, "-")) continue;

        const resolved = resolveFilePath(ctx.allocator, ctx.io, a) catch |err| {
            errPrint(ctx.io, "error: cannot resolve path '{s}': {s}\n", .{ a, @errorName(err) });
            continue;
        };
        try out.append(ctx.allocator, resolved);
    }

    return try out.toOwnedSlice(ctx.allocator);
}

fn resolveFilePath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.isAbsolute(path)) {
        return allocator.dupe(u8, path);
    }
    return cwd.realPathFileAlloc(io, path, allocator) catch |err| {
        if (err == error.FileNotFound) {
            // File doesn't exist yet — pass through the relative path so
            // the editor can create-on-open.
            const cwd_path = try cwd.realPathFileAlloc(io, ".", allocator);
            defer allocator.free(cwd_path);
            return std.fs.path.resolve(allocator, &.{ cwd_path, path });
        }
        return err;
    };
}

// ---------------------------------------------------------------------------
// `find` / `vfind`
// ---------------------------------------------------------------------------

const SearchMode = enum { grep, visual };

const SearchArgs = struct {
    query: []const u8,
    paths: []const []const u8,
    extensions: []const []const u8,
    excludes: []const []const u8,
    base_dir: ?[]const u8,
    before: usize,
    after: usize,
};

fn runSearch(ctx: Context, mode: SearchMode) !void {
    var parsed = parseSearchArgs(ctx, .needs_query) catch |err| switch (err) {
        error.MissingQuery => {
            const name = if (mode == .grep) "find" else "vfind";
            errPrint(ctx.io, "error: 'stem {s}' requires a query.\nusage: stem {s} <query> [-i] [-p PATH] [-e EXT] [-x EXCLUDE]\n", .{ name, name });
            return;
        },
        else => return err,
    };
    defer parsed.deinit(ctx.allocator);

    const options = search_tool.SearchOptions{
        .paths = parsed.paths,
        .extensions = parsed.extensions,
        .excludes = parsed.excludes,
        .base_dir = parsed.base_dir,
        .case = parsed.case,
        .color_override = parsed.color_override,
        .pretty_override = parsed.pretty_override,
    };

    switch (mode) {
        .grep => try search_tool.run(ctx.allocator, ctx.io, parsed.query, options),
        .visual => try vfind_tool.run(ctx.allocator, ctx.io, parsed.query, options),
    }
}

// ---------------------------------------------------------------------------
// `scope <file> <query>`
// ---------------------------------------------------------------------------

fn runScope(ctx: Context) !void {
    // Positional layout: stem scope <file> <query> [flags]
    var file_path: ?[]const u8 = null;
    var query: ?[]const u8 = null;
    var before_lines: usize = 3;
    var after_lines: usize = 3;
    var case: search_tool.Case = .smart;
    var color_override: ?bool = null;

    var i: usize = 2;
    while (i < ctx.args.len) : (i += 1) {
        const a = ctx.args[i];
        if (std.mem.eql(u8, a, "--before") or std.mem.eql(u8, a, "-B")) {
            i += 1;
            if (i >= ctx.args.len) {
                errPrint(ctx.io, "error: --before requires a number.\n", .{});
                return;
            }
            before_lines = std.fmt.parseInt(usize, ctx.args[i], 10) catch {
                errPrint(ctx.io, "error: --before must be a positive integer.\n", .{});
                return;
            };
        } else if (std.mem.eql(u8, a, "--after") or std.mem.eql(u8, a, "-A")) {
            i += 1;
            if (i >= ctx.args.len) {
                errPrint(ctx.io, "error: --after requires a number.\n", .{});
                return;
            }
            after_lines = std.fmt.parseInt(usize, ctx.args[i], 10) catch {
                errPrint(ctx.io, "error: --after must be a positive integer.\n", .{});
                return;
            };
        } else if (std.mem.eql(u8, a, "-i") or std.mem.eql(u8, a, "--ignore-case")) {
            case = .insensitive;
        } else if (std.mem.eql(u8, a, "-s") or std.mem.eql(u8, a, "--case-sensitive")) {
            case = .sensitive;
        } else if (std.mem.eql(u8, a, "--color")) {
            color_override = true;
        } else if (std.mem.eql(u8, a, "--no-color")) {
            color_override = false;
        } else if (std.mem.startsWith(u8, a, "-")) {
            errPrint(ctx.io, "error: unknown flag '{s}' for scope.\n", .{a});
            return;
        } else if (file_path == null) {
            file_path = a;
        } else if (query == null) {
            query = a;
        } else {
            errPrint(ctx.io, "error: 'scope' takes <file> <query>; got extra arg '{s}'.\n", .{a});
            return;
        }
    }

    if (file_path == null) {
        errPrint(ctx.io, "error: 'stem scope' requires a file path.\nusage: stem scope <file> <query> [-B N] [-A N] [-i]\n", .{});
        return;
    }
    if (query == null) {
        errPrint(ctx.io, "error: 'stem scope' requires a query.\nusage: stem scope <file> <query> [-B N] [-A N] [-i]\n", .{});
        return;
    }

    // `scope_tool.run` reports its own errors to stderr before returning
    // them; we swallow the propagation here so main doesn't dump a stack
    // trace on top of the friendly message.
    scope_tool.run(ctx.allocator, ctx.io, file_path.?, query.?, .{
        .before = before_lines,
        .after = after_lines,
        .case = case,
        .color_override = color_override,
    }) catch {};
}

// ---------------------------------------------------------------------------
// Shared search-arg parsing
// ---------------------------------------------------------------------------

const QueryReq = enum { needs_query, optional_query };

const ParsedSearch = struct {
    query: []const u8,
    paths: []const []const u8,
    extensions: []const []const u8,
    excludes: []const []const u8,
    base_dir: ?[]const u8,
    case: search_tool.Case = .smart,
    color_override: ?bool = null,
    pretty_override: ?bool = null,
    // Track which slices we own so deinit frees the right things.
    owns_extensions: bool,

    pub fn deinit(self: *ParsedSearch, allocator: std.mem.Allocator) void {
        for (self.paths) |p| allocator.free(p);
        allocator.free(self.paths);
        if (self.owns_extensions) {
            for (self.extensions) |e| allocator.free(e);
            allocator.free(self.extensions);
        } else {
            allocator.free(self.extensions);
        }
        allocator.free(self.excludes);
        if (self.base_dir) |bd| allocator.free(bd);
    }
};

fn parseSearchArgs(ctx: Context, req: QueryReq) !ParsedSearch {
    _ = req;
    var query: ?[]const u8 = null;
    var case: search_tool.Case = .smart;
    var color_override: ?bool = null;
    var pretty_override: ?bool = null;
    var raw_paths = std.ArrayListUnmanaged([]const u8).empty;
    defer raw_paths.deinit(ctx.allocator);
    var extensions = std.ArrayListUnmanaged([]const u8).empty;
    defer extensions.deinit(ctx.allocator);
    var excludes = std.ArrayListUnmanaged([]const u8).empty;
    defer excludes.deinit(ctx.allocator);

    var i: usize = 2; // skip argv[0] and the verb
    while (i < ctx.args.len) : (i += 1) {
        const a = ctx.args[i];
        if (std.mem.eql(u8, a, "--path") or std.mem.eql(u8, a, "-p")) {
            i += 1;
            if (i >= ctx.args.len) return error.MissingFlagValue;
            try raw_paths.append(ctx.allocator, ctx.args[i]);
        } else if (std.mem.eql(u8, a, "--ext") or std.mem.eql(u8, a, "-e")) {
            i += 1;
            if (i >= ctx.args.len) return error.MissingFlagValue;
            try extensions.append(ctx.allocator, ctx.args[i]);
        } else if (std.mem.eql(u8, a, "--exclude") or std.mem.eql(u8, a, "-x")) {
            i += 1;
            if (i >= ctx.args.len) return error.MissingFlagValue;
            try excludes.append(ctx.allocator, ctx.args[i]);
        } else if (std.mem.eql(u8, a, "-i") or std.mem.eql(u8, a, "--ignore-case")) {
            case = .insensitive;
        } else if (std.mem.eql(u8, a, "-s") or std.mem.eql(u8, a, "--case-sensitive")) {
            case = .sensitive;
        } else if (std.mem.eql(u8, a, "--color")) {
            color_override = true;
        } else if (std.mem.eql(u8, a, "--no-color")) {
            color_override = false;
        } else if (std.mem.eql(u8, a, "--pretty")) {
            pretty_override = true;
        } else if (std.mem.eql(u8, a, "--no-pretty") or std.mem.eql(u8, a, "--compact")) {
            pretty_override = false;
        } else if (std.mem.startsWith(u8, a, "-")) {
            errPrint(ctx.io, "warning: ignoring unknown flag '{s}'\n", .{a});
        } else if (query == null) {
            query = a;
        } else {
            // Extra positionals after the query are treated as path
            // restrictions, matching `rg <pattern> <path>...` ergonomics.
            try raw_paths.append(ctx.allocator, a);
        }
    }

    if (query == null) return error.MissingQuery;

    // Resolve --path entries relative to cwd. Mostly preserved from the
    // legacy implementation; the gnarliness comes from supporting search
    // paths outside cwd (`-p ../sibling`).
    var resolved_paths = std.ArrayListUnmanaged([]const u8).empty;
    errdefer {
        for (resolved_paths.items) |p| ctx.allocator.free(p);
        resolved_paths.deinit(ctx.allocator);
    }
    var base_dir: ?[]const u8 = null;
    const cwd = std.Io.Dir.cwd();
    const cwd_path = try cwd.realPathFileAlloc(ctx.io, ".", ctx.allocator);
    defer ctx.allocator.free(cwd_path);

    for (raw_paths.items) |path_arg| {
        const abs = cwd.realPathFileAlloc(ctx.io, path_arg, ctx.allocator) catch {
            try appendDupe(ctx.allocator, &resolved_paths, path_arg);
            continue;
        };
        defer ctx.allocator.free(abs);
        if (std.mem.startsWith(u8, abs, cwd_path)) {
            if (abs.len == cwd_path.len) {
                try appendDupe(ctx.allocator, &resolved_paths, "");
            } else if (abs.len > cwd_path.len and abs[cwd_path.len] == '/') {
                try appendDupe(ctx.allocator, &resolved_paths, abs[cwd_path.len + 1 ..]);
            } else {
                try appendDupe(ctx.allocator, &resolved_paths, path_arg);
            }
        } else {
            // Out-of-cwd path: rebase the walk at the common ancestor and
            // store relative path. Mirrors prior behaviour.
            var common_len: usize = 0;
            const min_len = @min(cwd_path.len, abs.len);
            while (common_len < min_len and cwd_path[common_len] == abs[common_len]) {
                common_len += 1;
            }
            var last_slash: usize = 0;
            for (0..common_len) |j| {
                if (cwd_path[j] == '/') last_slash = j;
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
                            while (pos < cwd_remaining.len and cwd_remaining[pos] != '/') pos += 1;
                            depth += 1;
                            if (pos < cwd_remaining.len) pos += 1;
                        }
                    }
                    var base_rel: std.Io.Writer.Allocating = .init(ctx.allocator);
                    defer base_rel.deinit();
                    for (0..depth) |_| try base_rel.writer.print("../", .{});
                    base_dir = try base_rel.toOwnedSlice();
                }
                if (abs.len > last_slash + 1) {
                    try appendDupe(ctx.allocator, &resolved_paths, abs[last_slash + 1 ..]);
                } else {
                    try appendDupe(ctx.allocator, &resolved_paths, "");
                }
            } else {
                try appendDupe(ctx.allocator, &resolved_paths, path_arg);
            }
        }
    }

    // Extensions: no implicit default. Empty list = match all (this matches
    // ripgrep's behaviour and avoids the previous surprise of `--find foo`
    // silently filtering to `.zig` only).
    var owns_extensions = false;
    const final_extensions: []const []const u8 = blk: {
        if (extensions.items.len == 0) {
            break :blk try ctx.allocator.alloc([]const u8, 0);
        }
        const out = try ctx.allocator.alloc([]const u8, extensions.items.len);
        var idx: usize = 0;
        errdefer {
            // Free anything we've duped so far if a later dupe OOMs.
            var k: usize = 0;
            while (k < idx) : (k += 1) ctx.allocator.free(out[k]);
            ctx.allocator.free(out);
        }
        while (idx < extensions.items.len) : (idx += 1) {
            out[idx] = try ctx.allocator.dupe(u8, extensions.items[idx]);
        }
        owns_extensions = true;
        break :blk out;
    };
    errdefer if (owns_extensions) {
        for (final_extensions) |e| ctx.allocator.free(e);
        ctx.allocator.free(final_extensions);
    } else ctx.allocator.free(final_extensions);

    // Outer slice for excludes only — its strings borrow from argv.
    const excludes_owned = try ctx.allocator.dupe([]const u8, excludes.items);
    errdefer ctx.allocator.free(excludes_owned);

    const paths_owned = try resolved_paths.toOwnedSlice(ctx.allocator);
    // No errdefer needed past this point: it's the last fallible step.

    return .{
        .query = query.?,
        .paths = paths_owned,
        .extensions = final_extensions,
        .excludes = excludes_owned,
        .base_dir = base_dir,
        .case = case,
        .color_override = color_override,
        .pretty_override = pretty_override,
        .owns_extensions = owns_extensions,
    };
}

/// Dupe `s` and append onto `list`, freeing the dupe on append failure.
fn appendDupe(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged([]const u8),
    s: []const u8,
) !void {
    const owned = try allocator.dupe(u8, s);
    errdefer allocator.free(owned);
    try list.append(allocator, owned);
}

// ---------------------------------------------------------------------------
// `config`
// ---------------------------------------------------------------------------

fn runConfig(ctx: Context) !void {
    if (ctx.args.len < 3) {
        try printVerbHelp(ctx.io, .config);
        return;
    }

    const action = ctx.args[2];
    if (std.mem.eql(u8, action, "list") or std.mem.eql(u8, action, "get")) {
        // `list` and bare `get` both dump everything; `get <key>` is one value.
        if (std.mem.eql(u8, action, "get") and ctx.args.len >= 4) {
            const key = ctx.args[3];
            if (try ctx.storage.config.getByPath(key, ctx.allocator)) |val| {
                defer ctx.allocator.free(val);
                try outPrint(ctx.io, "{s}\n", .{val});
            } else {
                errPrint(ctx.io, "key not found: {s}\n", .{key});
            }
            return;
        }
        var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
        defer aw.deinit();
        try ctx.storage.config.writeConfig(&aw.writer);
        try outPrint(ctx.io, "{s}", .{aw.written()});
        return;
    }

    if (std.mem.eql(u8, action, "set")) {
        if (ctx.args.len < 5) {
            errPrint(ctx.io, "usage: stem config set <key> <value>\n", .{});
            return;
        }
        const key = ctx.args[3];
        const val = ctx.args[4];
        if (try ctx.storage.config.setByPath(key, val, ctx.allocator)) {
            try ctx.storage.save();
            errPrint(ctx.io, "set {s} = {s}\n", .{ key, val });
        } else {
            errPrint(ctx.io, "failed to set {s} (unknown key or wrong type)\n", .{key});
        }
        return;
    }

    if (std.mem.eql(u8, action, "unset")) {
        if (ctx.args.len < 4) {
            errPrint(ctx.io, "usage: stem config unset <key>\n", .{});
            return;
        }
        const key = ctx.args[3];
        if (ctx.storage.config.unsetByPath(key)) {
            try ctx.storage.save();
            errPrint(ctx.io, "reset {s} to default\n", .{key});
        } else {
            errPrint(ctx.io, "unknown key: {s}\n", .{key});
        }
        return;
    }

    errPrint(ctx.io, "unknown config action: {s}\n", .{action});
    try printVerbHelp(ctx.io, .config);
}

// ---------------------------------------------------------------------------
// `logs`
// ---------------------------------------------------------------------------

fn runLogs(ctx: Context) !void {
    // Default subverb is `view`. Accept legacy `--clear` for backwards compat.
    var sub: enum { view, clear } = .view;
    if (ctx.args.len >= 3) {
        const s = ctx.args[2];
        if (std.mem.eql(u8, s, "clear") or std.mem.eql(u8, s, "--clear")) {
            sub = .clear;
        } else if (std.mem.eql(u8, s, "view")) {
            sub = .view;
        } else {
            errPrint(ctx.io, "error: unknown logs sub-verb '{s}'. Try `view` or `clear`.\n", .{s});
            return;
        }
    }

    var dir = std.Io.Dir.openDirAbsolute(ctx.io, ctx.storage.logs_dir, .{ .iterate = true }) catch |err| {
        errPrint(ctx.io, "failed to open logs directory: {s}\n", .{@errorName(err)});
        return;
    };
    defer dir.close(ctx.io);

    switch (sub) {
        .clear => {
            var iter = dir.iterate();
            var cleared: usize = 0;
            while (iter.next(ctx.io)) |maybe_entry| {
                const entry = maybe_entry orelse break;
                if (entry.kind != .file) continue;
                if (!(std.mem.startsWith(u8, entry.name, "stem-") and std.mem.endsWith(u8, entry.name, ".log")) and
                    !std.mem.eql(u8, entry.name, "stem.log")) continue;
                if (dir.deleteFile(ctx.io, entry.name)) {
                    cleared += 1;
                } else |err| {
                    errPrint(ctx.io, "could not delete {s}: {s}\n", .{ entry.name, @errorName(err) });
                }
            } else |err| {
                errPrint(ctx.io, "error iterating logs: {s}\n", .{@errorName(err)});
            }
            errPrint(ctx.io, "cleared {d} log file(s)\n", .{cleared});
        },
        .view => {
            var found_any = false;
            var iter = dir.iterate();
            while (iter.next(ctx.io) catch null) |entry| {
                if (entry.kind != .file) continue;
                const is_log = (std.mem.startsWith(u8, entry.name, "stem-") and std.mem.endsWith(u8, entry.name, ".log")) or
                    std.mem.eql(u8, entry.name, "stem.log");
                if (!is_log) continue;
                found_any = true;
                const file = dir.openFile(ctx.io, entry.name, .{}) catch continue;
                defer file.close(ctx.io);
                const len = file.length(ctx.io) catch 0;
                if (len == 0) continue;
                const content = ctx.allocator.alloc(u8, @intCast(len)) catch continue;
                defer ctx.allocator.free(content);
                const n = file.readPositionalAll(ctx.io, content, 0) catch 0;
                try outPrint(ctx.io, "{s}", .{content[0..n]});
            }
            if (!found_any) errPrint(ctx.io, "no log files in {s}\n", .{ctx.storage.logs_dir});
        },
    }
}

// ---------------------------------------------------------------------------
// `lsp`
// ---------------------------------------------------------------------------

/// One entry of the LSP server registry — shared by `lsp install`,
/// `lsp list`, and the help text so they never drift apart. `keys`
/// holds every alias the user can type on the CLI (`python`, `py`,
/// `cpp`, `c++`, …). `path_only` servers (clangd, sourcekit-lsp) skip
/// auto-install and report `not on PATH` instead.
const LspEntry = struct {
    /// Short, lowercase alias used in error messages and `lsp list`.
    display: []const u8,
    /// Aliases accepted on the `stem lsp install <name>` CLI.
    keys: []const []const u8,
    /// Executable name to look for on PATH (or under ~/.stem/lsp/)
    /// when probing whether this server is reachable. `null` means
    /// the server isn't a standalone binary (e.g. R's languageserver
    /// runs via `R -e 'languageserver::run()'`) — `stem doctor` skips
    /// the probe in that case.
    binary: ?[]const u8 = null,
    ensure: *const fn (*Installer, bool) anyerror![]const u8,
    path_only: bool = false,
    /// One-line note shown to the user before this server tries to
    /// install (e.g. external runtime requirement).
    hint: []const u8 = "",
};

const lsp_entries = [_]LspEntry{
    .{ .display = "pyright (python)", .keys = &.{ "python", "py" }, .binary = "pyright-langserver", .ensure = Installer.ensurePyright, .hint = "needs node on PATH" },
    .{ .display = "typescript-language-server", .keys = &.{ "typescript", "ts", "javascript", "js" }, .binary = "typescript-language-server", .ensure = Installer.ensureTypeScriptLS, .hint = "needs node on PATH" },
    .{ .display = "gopls (go)", .keys = &.{"go"}, .binary = "gopls", .ensure = Installer.ensureGopls, .hint = "needs go on PATH" },
    .{ .display = "rust-analyzer", .keys = &.{ "rust", "rs" }, .binary = "rust-analyzer", .ensure = Installer.ensureRustAnalyzer },
    .{ .display = "clangd (c/c++)", .keys = &.{ "cpp", "c", "c++" }, .binary = "clangd", .ensure = Installer.ensureClangd, .path_only = true, .hint = "ships with LLVM/Xcode — install via your OS package manager" },
    .{ .display = "ruby-lsp", .keys = &.{"ruby"}, .binary = "ruby-lsp", .ensure = Installer.ensureRubyLsp, .hint = "needs ruby + gem on PATH" },
    .{ .display = "omnisharp (c#)", .keys = &.{ "csharp", "c#" }, .binary = "OmniSharp", .ensure = Installer.ensureOmniSharp },
    .{ .display = "jdtls (java)", .keys = &.{"java"}, .binary = "jdtls", .ensure = Installer.ensureJdtls, .hint = "needs java on PATH at runtime" },
    .{ .display = "bash-language-server", .keys = &.{ "bash", "sh" }, .binary = "bash-language-server", .ensure = Installer.ensureBashLanguageServer, .hint = "needs node on PATH" },
    .{ .display = "lua-language-server", .keys = &.{"lua"}, .binary = "lua-language-server", .ensure = Installer.ensureLuaLanguageServer },
    .{ .display = "sourcekit-lsp (swift)", .keys = &.{"swift"}, .binary = "sourcekit-lsp", .ensure = Installer.ensureSourcekitLsp, .path_only = true, .hint = "ships with the Swift toolchain (Xcode CLT on macOS)" },
    // R's language server runs inside the R process — no standalone binary.
    .{ .display = "languageserver (r)", .keys = &.{"r"}, .binary = null, .ensure = Installer.ensureRLanguageServer, .hint = "needs R on PATH; installs the R 'languageserver' package" },
    .{ .display = "vscode-css-language-server", .keys = &.{"css"}, .binary = "vscode-css-language-server", .ensure = Installer.ensureCssLanguageServer, .hint = "needs node on PATH; shares install with html + json" },
    .{ .display = "vscode-html-language-server", .keys = &.{"html"}, .binary = "vscode-html-language-server", .ensure = Installer.ensureHtmlLanguageServer, .hint = "needs node on PATH; shares install with css + json" },
    .{ .display = "vscode-json-language-server", .keys = &.{"json"}, .binary = "vscode-json-language-server", .ensure = Installer.ensureJsonLanguageServer, .hint = "needs node on PATH; shares install with css + html" },
    .{ .display = "intelephense (php)", .keys = &.{"php"}, .binary = "intelephense", .ensure = Installer.ensureIntelephense, .hint = "needs node on PATH" },
    .{ .display = "perlnavigator (perl)", .keys = &.{"perl"}, .binary = "perlnavigator", .ensure = Installer.ensurePerlNavigator, .hint = "needs node on PATH" },
    .{ .display = "dart language-server", .keys = &.{"dart"}, .binary = "dart", .ensure = Installer.ensureDartLanguageServer, .path_only = true, .hint = "ships with the Dart SDK (https://dart.dev/get-dart)" },
    .{ .display = "elixir-ls", .keys = &.{"elixir"}, .binary = "elixir-ls", .ensure = Installer.ensureElixirLs, .path_only = true, .hint = "install via brew or https://github.com/elixir-lsp/elixir-ls/releases" },
    .{ .display = "erlang_ls", .keys = &.{"erlang"}, .binary = "erlang_ls", .ensure = Installer.ensureErlangLs, .path_only = true, .hint = "install via rebar3 from https://github.com/erlang-ls/erlang_ls" },
    .{ .display = "haskell-language-server", .keys = &.{"haskell"}, .binary = "haskell-language-server-wrapper", .ensure = Installer.ensureHaskellLanguageServer, .path_only = true, .hint = "install via `ghcup install hls`" },
    .{ .display = "kotlin-language-server", .keys = &.{"kotlin"}, .binary = "kotlin-language-server", .ensure = Installer.ensureKotlinLanguageServer, .path_only = true, .hint = "install via brew or https://github.com/fwcd/kotlin-language-server" },
    .{ .display = "ocamllsp", .keys = &.{"ocaml"}, .binary = "ocamllsp", .ensure = Installer.ensureOcamlLsp, .path_only = true, .hint = "install via `opam install ocaml-lsp-server`" },
    .{ .display = "metals (scala)", .keys = &.{"scala"}, .binary = "metals", .ensure = Installer.ensureMetals, .path_only = true, .hint = "install via `coursier install metals`" },
};

fn matchLspKey(entry: LspEntry, want: []const u8) bool {
    for (entry.keys) |k| {
        if (std.mem.eql(u8, k, want)) return true;
    }
    return false;
}

fn runLsp(ctx: Context) !void {
    if (ctx.args.len < 3) {
        try printVerbHelp(ctx.io, .lsp);
        return;
    }
    const sub = ctx.args[2];
    if (std.mem.eql(u8, sub, "install")) {
        if (ctx.args.len < 4) {
            errPrint(ctx.io, "usage: stem lsp install <language|all>\n", .{});
            return;
        }
        try runLspInstall(ctx, ctx.args[3]);
        return;
    }
    if (std.mem.eql(u8, sub, "list") or std.mem.eql(u8, sub, "status")) {
        try listLspStatus(ctx);
        return;
    }
    errPrint(ctx.io, "unknown lsp sub-verb: {s}\n", .{sub});
    try printVerbHelp(ctx.io, .lsp);
}

fn runLspInstall(ctx: Context, want: []const u8) !void {
    // Build the work list — either every server, or just those whose
    // keys match the user's argument.
    var todo: std.ArrayListUnmanaged(LspEntry) = .empty;
    defer todo.deinit(ctx.allocator);
    if (std.mem.eql(u8, want, "all")) {
        try todo.appendSlice(ctx.allocator, &lsp_entries);
    } else {
        for (lsp_entries) |e| {
            if (matchLspKey(e, want)) try todo.append(ctx.allocator, e);
        }
        if (todo.items.len == 0) {
            errPrint(ctx.io, "unknown language: '{s}'. Try:\n", .{want});
            for (lsp_entries) |e| errPrint(ctx.io, "  {s}\n", .{e.keys[0]});
            errPrint(ctx.io, "  all\n", .{});
            return;
        }
    }

    // Stderr is unbuffered in this binary — each `errPrint` lands
    // immediately, which is what we want for the live progress feel.
    // Wrap stderr in a Writer so the Installer can stream its own
    // milestones inline with our per-server headers.
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writerStreaming(ctx.io, &stderr_buf);
    const w = &stderr_writer.interface;

    var installer = Installer.init(ctx.allocator, ctx.io, ctx.environ_block);
    installer.progress = w;

    var ok: usize = 0;
    var failed: usize = 0;
    for (todo.items) |entry| {
        errPrint(ctx.io, "\n→ {s}\n", .{entry.display});
        if (entry.hint.len > 0) errPrint(ctx.io, "    ({s})\n", .{entry.hint});

        const result = entry.ensure(&installer, !entry.path_only);
        if (result) |path| {
            defer ctx.allocator.free(path);
            // Flush any inline progress so the ✓ line lands after,
            // not interleaved with, the last installer note.
            w.flush() catch {};
            errPrint(ctx.io, "  \xe2\x9c\x93 {s}\n", .{path});
            ok += 1;
        } else |err| {
            w.flush() catch {};
            errPrint(ctx.io, "  \xe2\x9c\x97 failed: {s}\n", .{@errorName(err)});
            failed += 1;
        }
    }

    errPrint(ctx.io, "\n{d} installed, {d} failed.\n", .{ ok, failed });
}

fn listLspStatus(ctx: Context) !void {
    var installer = Installer.init(ctx.allocator, ctx.io, ctx.environ_block);
    try outPrint(ctx.io, "Language servers:\n", .{});
    for (lsp_entries) |entry| {
        const path = entry.ensure(&installer, false) catch {
            try outPrint(ctx.io, "  {s:<32} not installed\n", .{entry.display});
            continue;
        };
        defer ctx.allocator.free(path);
        try outPrint(ctx.io, "  {s:<32} {s}\n", .{ entry.display, path });
    }
    try outPrint(ctx.io, "\nInstall with: stem lsp install <name|all>\n", .{});
}

// ---------------------------------------------------------------------------
// `plugin`
// ---------------------------------------------------------------------------

fn runPlugin(ctx: Context) !void {
    if (ctx.args.len < 3) {
        try printVerbHelp(ctx.io, .plugin);
        return;
    }
    const sub = ctx.args[2];

    // Buffered stdout + stderr so subcommand output stays grouped and
    // doesn't interleave with random log lines.
    const out_file = std.Io.File.stdout();
    const err_file = std.Io.File.stderr();
    var out_buf: [8192]u8 = undefined;
    var err_buf: [4096]u8 = undefined;
    var out_writer = out_file.writerStreaming(ctx.io, &out_buf);
    var err_writer = err_file.writerStreaming(ctx.io, &err_buf);
    defer out_writer.interface.flush() catch {};
    defer err_writer.interface.flush() catch {};

    plugin_cli.run(.{
        .allocator = ctx.allocator,
        .io = ctx.io,
        .environ_block = ctx.environ_block,
        .sub = sub,
        .sub_args = if (ctx.args.len > 3) ctx.args[3..] else &.{},
        .out = &out_writer.interface,
        .err = &err_writer.interface,
    }) catch |err| {
        errPrint(ctx.io, "stem plugin {s}: {s}\n", .{ sub, @errorName(err) });
    };
}

// ---------------------------------------------------------------------------
// `doctor`
// ---------------------------------------------------------------------------
//
// `stem doctor` probes the environment for the things stem cares
// about and prints a ✓/✗ table. Read-only — never mutates state.
// Useful as the very first thing to run when something feels off, and
// as the suggested follow-up in error messages elsewhere.

const DoctorStatus = enum { ok, warn, fail, info };

fn doctorRow(io: std.Io, status: DoctorStatus, name: []const u8, comptime fmt: []const u8, args: anytype) !void {
    const symbol: []const u8 = switch (status) {
        .ok => "\u{2713}", // ✓
        .warn => "\u{26a0}", // ⚠
        .fail => "\u{2717}", // ✗
        .info => "\u{2022}", // •
    };
    try outPrint(io, "  {s} {s}: ", .{ symbol, name });
    try outPrint(io, fmt, args);
    try outPrint(io, "\n", .{});
}

fn runDoctor(ctx: Context) !void {
    try outPrint(ctx.io, "stem doctor — environment & install check\n\n", .{});

    // Stem version itself.
    try doctorRow(ctx.io, .info, "stem", "{s} ({s})", .{ config_mod.version, config_mod.git_hash });

    // Zig: not required at runtime (we're already running), but useful
    // to flag for source-build users.
    if (installer_mod.findOnSystem(ctx.allocator, ctx.io, "zig", ctx.environ_block)) |path| {
        defer ctx.allocator.free(path);
        try doctorRow(ctx.io, .ok, "zig on PATH", "{s}", .{path});
    } else {
        try doctorRow(ctx.io, .warn, "zig on PATH", "not found — needed for `zig build` and source installs", .{});
    }

    try outPrint(ctx.io, "\nTerminal capabilities\n", .{});

    // 24-bit colour detection: COLORTERM=truecolor|24bit is the
    // standard signal. We don't try anything fancy beyond that.
    // Use platform.getEnv (cross-OS) instead of env.getPosix —
    // the latter doesn't compile on Windows in Zig 0.16.
    if (try platform.getEnv(ctx.allocator, ctx.environ_block, "COLORTERM")) |ct| {
        defer ctx.allocator.free(ct);
        if (std.mem.eql(u8, ct, "truecolor") or std.mem.eql(u8, ct, "24bit")) {
            try doctorRow(ctx.io, .ok, "24-bit colour", "COLORTERM={s}", .{ct});
        } else {
            try doctorRow(ctx.io, .warn, "24-bit colour", "COLORTERM={s} — themes may look muted; try `export COLORTERM=truecolor`", .{ct});
        }
    } else {
        try doctorRow(ctx.io, .warn, "24-bit colour", "COLORTERM unset — themes may look muted; try `export COLORTERM=truecolor`", .{});
    }

    if (try platform.getEnv(ctx.allocator, ctx.environ_block, "TERM")) |term| {
        defer ctx.allocator.free(term);
        try doctorRow(ctx.io, .info, "TERM", "{s}", .{term});
    } else {
        try doctorRow(ctx.io, .warn, "TERM", "unset — stem expects a sane terminfo entry", .{});
    }

    try outPrint(ctx.io, "\nStem directories\n", .{});

    try doctorDir(ctx, "config dir", ctx.storage.config_dir);
    try doctorDir(ctx, "plugins dir", ctx.storage.plugins_dir);
    try doctorDir(ctx, "logs dir", ctx.storage.logs_dir);
    try doctorDir(ctx, "lsp dir", ctx.storage.lsp_dir);

    // Bundled / user plugins.
    try outPrint(ctx.io, "\nPlugins (~/.stem/plugins)\n", .{});
    try doctorPluginList(ctx);

    try outPrint(ctx.io, "\nLanguage servers\n", .{});
    try doctorLspServers(ctx);

    try outPrint(ctx.io, "\nAll done. For details on any single LSP, run `stem lsp list`.\n", .{});
}

fn doctorDir(ctx: Context, label: []const u8, path: []const u8) !void {
    if (std.Io.Dir.accessAbsolute(ctx.io, path, .{})) |_| {
        try doctorRow(ctx.io, .ok, label, "{s}", .{path});
    } else |err| {
        if (err == error.FileNotFound) {
            try doctorRow(ctx.io, .warn, label, "{s} — not present (created on first use)", .{path});
        } else {
            try doctorRow(ctx.io, .fail, label, "{s}: {s}", .{ path, @errorName(err) });
        }
    }
}

fn doctorPluginList(ctx: Context) !void {
    var dir = std.Io.Dir.openDirAbsolute(ctx.io, ctx.storage.plugins_dir, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            try doctorRow(ctx.io, .info, "installed", "(none yet)", .{});
            return;
        }
        try doctorRow(ctx.io, .fail, "scan", "{s}", .{@errorName(err)});
        return;
    };
    defer dir.close(ctx.io);

    var it = dir.iterate();
    var count: usize = 0;
    while (it.next(ctx.io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        count += 1;
        const manifest_path = try std.fs.path.join(ctx.allocator, &.{ ctx.storage.plugins_dir, entry.name, "plugin.json" });
        defer ctx.allocator.free(manifest_path);
        if (std.Io.Dir.accessAbsolute(ctx.io, manifest_path, .{})) |_| {
            try doctorRow(ctx.io, .ok, entry.name, "{s}", .{manifest_path});
        } else |_| {
            try doctorRow(ctx.io, .warn, entry.name, "no plugin.json — stem will skip this directory", .{});
        }
    }
    if (count == 0) {
        try doctorRow(ctx.io, .info, "installed", "(none yet)", .{});
    }
}

fn doctorLspServers(ctx: Context) !void {
    // Walk the same `lsp_entries` table the `stem lsp` subcommand uses
    // so the doctor and `lsp list` never disagree. For each entry,
    // probe the *binary* name (not the language alias) so `gopls (go)`
    // doesn't get falsely greenlit by finding `go` itself on PATH.
    var any_found = false;
    for (lsp_entries) |entry| {
        const bin = entry.binary orelse {
            // No standalone binary (R's languageserver). Report
            // informationally rather than probing.
            try doctorRow(ctx.io, .info, entry.display, "no standalone binary — {s}", .{entry.hint});
            continue;
        };

        // Probe PATH and well-known toolchain dirs first.
        if (installer_mod.findOnSystem(ctx.allocator, ctx.io, bin, ctx.environ_block)) |path| {
            defer ctx.allocator.free(path);
            try doctorRow(ctx.io, .ok, entry.display, "{s}", .{path});
            any_found = true;
            continue;
        }

        // Fall back to stem's per-user install location.
        const stem_path = std.fs.path.join(ctx.allocator, &.{ ctx.storage.lsp_dir, bin, bin }) catch null;
        if (stem_path) |p| {
            defer ctx.allocator.free(p);
            if (std.Io.Dir.accessAbsolute(ctx.io, p, .{})) |_| {
                try doctorRow(ctx.io, .ok, entry.display, "{s} (installed by stem)", .{p});
                any_found = true;
                continue;
            } else |_| {}
        }

        const hint = if (entry.hint.len > 0) entry.hint else "run `stem lsp install`";
        try doctorRow(ctx.io, .info, entry.display, "not installed — {s}", .{hint});
    }
    if (!any_found) {
        try outPrint(ctx.io, "\n  (no external servers yet. Install one with `stem lsp install <name>`.)\n", .{});
    }
}

// ---------------------------------------------------------------------------
// Help / version
// ---------------------------------------------------------------------------

fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}

fn isVersionFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version");
}

fn printVersion(io: std.Io) !void {
    try outPrint(io, "stem {s} ({s})\n", .{ config_mod.version, config_mod.git_hash });
}

const VerbSpec = struct {
    verb: Verb,
    name: []const u8,
    summary: []const u8,
    detail: []const u8,
};

const verb_specs = [_]VerbSpec{
    .{
        .verb = .find,
        .name = "find <query>",
        .summary = "Search file contents (grep-like)",
        .detail =
        \\Usage: stem find <query> [flags]
        \\
        \\Flags:
        \\  -p, --path <dir>      Restrict to this path (repeatable)
        \\  -e, --ext <ext>       Filter by file extension (repeatable; default: all)
        \\  -x, --exclude <pat>   Skip paths containing this substring (repeatable)
        ,
    },
    .{
        .verb = .vfind,
        .name = "vfind <query>",
        .summary = "Interactive search results",
        .detail =
        \\Usage: stem vfind <query> [flags]
        \\
        \\Same flags as `find`. Opens an interactive picker over matches.
        ,
    },
    .{
        .verb = .scope,
        .name = "scope <file> <query>",
        .summary = "Search within a single file with context",
        .detail =
        \\Usage: stem scope <file> <query> [-B N] [-A N]
        \\
        \\Flags:
        \\  -B, --before <n>      Show N lines of context before each match (default: 3)
        \\  -A, --after  <n>      Show N lines of context after each match  (default: 3)
        ,
    },
    .{
        .verb = .config,
        .name = "config <action>",
        .summary = "Read or modify configuration",
        .detail =
        \\Usage: stem config <list|get|set|unset> [args]
        \\
        \\  list                  Print the whole config
        \\  get [key]             Print one value, or all if no key
        \\  set <key> <value>     Update one key
        \\  unset <key>           Reset one key to its default
        ,
    },
    .{
        .verb = .logs,
        .name = "logs [view|clear]",
        .summary = "Inspect or wipe editor logs",
        .detail =
        \\Usage: stem logs [view|clear]
        \\
        \\  view (default)        Print every log file
        \\  clear                 Delete every log file
        ,
    },
    .{
        .verb = .lsp,
        .name = "lsp <action>",
        .summary = "Install or list language servers",
        .detail =
        \\Usage: stem lsp <install|list> [args]
        \\
        \\  install <lang|all>    Install a language server. Supported:
        \\                        python, typescript, go, rust, cpp,
        \\                        ruby, csharp, java, all
        \\  list                  Show installed-server status
        ,
    },
    .{
        .verb = .plugin,
        .name = "plugin <action>",
        .summary = "Manage installed plugins",
        .detail =
        \\Usage: stem plugin <list|info|inspect|install|remove|test> [args]
        \\
        \\  list                  List installed plugins
        \\  info <name>           Show a plugin's manifest
        \\  inspect [name]        Capability inspector: manifest, permissions,
        \\                        restart policy, artifact sanity. Omit name to
        \\                        report on every installed plugin.
        \\  install <path>        Copy a plugin directory into ~/.stem/plugins
        \\  remove <name>         Delete an installed plugin
        \\  test <path>           Hermetic smoke test (manifest + entry artifact;
        \\                        for wasm plugins, runs `activate` against
        \\                        mocked host imports and reports registered
        \\                        commands).
        ,
    },
    .{
        .verb = .doctor,
        .name = "doctor",
        .summary = "Environment & install check",
        .detail =
        \\Usage: stem doctor
        \\
        \\Probes the host environment for the things stem needs:
        \\  - 24-bit colour support in the terminal
        \\  - ~/.stem directory layout (config, logs, plugins, lsp)
        \\  - Installed plugins (with manifest sanity)
        \\  - Each supported LSP server's presence on PATH
        \\
        \\Read-only; never modifies anything.
        ,
    },
    .{
        .verb = .help,
        .name = "help",
        .summary = "Show this help",
        .detail = "Usage: stem help [topic]\n",
    },
    .{
        .verb = .version,
        .name = "version",
        .summary = "Print version",
        .detail = "Usage: stem version\n",
    },
};

fn verbSpec(v: Verb) VerbSpec {
    for (verb_specs) |s| if (s.verb == v) return s;
    unreachable;
}

fn printVerbHelp(io: std.Io, v: Verb) !void {
    try outPrint(io, "{s}\n", .{verbSpec(v).detail});
}

fn printHelp(io: std.Io) !void {
    const stdout_is_tty = isTty(std.Io.File.stdout(), io);
    const c = ansi(stdout_is_tty);

    try outPrint(io,
        \\
        \\   {s}STEM EDITOR{s}   {s}Modal terminal editor{s}
        \\
        \\   {s}USAGE{s}
        \\       stem [paths...]                 Open files / directory in the editor
        \\       stem <command> [args...]        Run a CLI command
        \\       stem -h | --help                Show this help
        \\       stem -V | --version             Print version
        \\
        \\   {s}COMMANDS{s}
        \\
    , .{
        c.bold_cyan, c.reset, c.italic, c.reset,
        c.bold,      c.reset, c.bold,   c.reset,
    });

    for (verb_specs) |s| {
        try outPrint(io, "       {s}{s:<22}{s}  {s}\n", .{ c.green, s.name, c.reset, s.summary });
    }

    try outPrint(io,
        \\
        \\   {s}EXAMPLES{s}
        \\       stem                            Empty buffer
        \\       stem src/main.zig               Open one file
        \\       stem ./src                      Open a directory recursively
        \\       stem find TODO                  Grep "TODO" in the project
        \\       stem find foo -e zig -e py      Limit to .zig and .py files
        \\       stem vfind needle               Interactive results
        \\       stem scope src/cli.zig dispatch Context lines around `dispatch`
        \\       stem config set ui.theme dark
        \\       stem lsp install rust
        \\
        \\   Run `stem <command> --help` for command-specific options.
        \\
    , .{ c.bold, c.reset });
}

const Ansi = struct {
    reset: []const u8,
    bold: []const u8,
    italic: []const u8,
    bold_cyan: []const u8,
    green: []const u8,
};

fn ansi(enabled: bool) Ansi {
    return if (enabled) .{
        .reset = "\x1b[0m",
        .bold = "\x1b[1m",
        .italic = "\x1b[3m",
        .bold_cyan = "\x1b[1;36m",
        .green = "\x1b[32m",
    } else .{
        .reset = "",
        .bold = "",
        .italic = "",
        .bold_cyan = "",
        .green = "",
    };
}

// ---------------------------------------------------------------------------
// Output helpers
// ---------------------------------------------------------------------------

fn isTty(file: std.Io.File, io: std.Io) bool {
    return file.isTty(io) catch false;
}

fn outPrint(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const fbs = std.fmt.bufPrint(&buf, fmt, args) catch {
        // Falls back to heap if the output doesn't fit in the stack buffer.
        const big = try std.fmt.allocPrint(std.heap.page_allocator, fmt, args);
        defer std.heap.page_allocator.free(big);
        try std.Io.File.stdout().writeStreamingAll(io, big);
        return;
    };
    try std.Io.File.stdout().writeStreamingAll(io, fbs);
}

fn errPrint(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.Io.File.stderr().writeStreamingAll(io, s) catch {};
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "resolveVerb: bare, alias, and short forms" {
    try std.testing.expectEqual(@as(?Verb, .find), resolveVerb("find"));
    try std.testing.expectEqual(@as(?Verb, .find), resolveVerb("--find"));
    try std.testing.expectEqual(@as(?Verb, .find), resolveVerb("-f"));
    try std.testing.expectEqual(@as(?Verb, .vfind), resolveVerb("vfind"));
    try std.testing.expectEqual(@as(?Verb, .vfind), resolveVerb("--vfind"));
    try std.testing.expectEqual(@as(?Verb, .scope), resolveVerb("scope"));
    try std.testing.expectEqual(@as(?Verb, .scope), resolveVerb("--scope"));
    try std.testing.expectEqual(@as(?Verb, .config), resolveVerb("config"));
    try std.testing.expectEqual(@as(?Verb, .logs), resolveVerb("logs"));
    try std.testing.expectEqual(@as(?Verb, .logs), resolveVerb("log"));
    try std.testing.expectEqual(@as(?Verb, .lsp), resolveVerb("lsp"));
    try std.testing.expectEqual(@as(?Verb, .help), resolveVerb("help"));
    try std.testing.expectEqual(@as(?Verb, .version), resolveVerb("version"));

    try std.testing.expectEqual(@as(?Verb, null), resolveVerb("not-a-verb"));
    try std.testing.expectEqual(@as(?Verb, null), resolveVerb("src/main.zig"));
    try std.testing.expectEqual(@as(?Verb, null), resolveVerb("--open")); // dropped
}

test "isHelpFlag / isVersionFlag" {
    try std.testing.expect(isHelpFlag("-h"));
    try std.testing.expect(isHelpFlag("--help"));
    try std.testing.expect(!isHelpFlag("help"));
    try std.testing.expect(isVersionFlag("-V"));
    try std.testing.expect(isVersionFlag("--version"));
    try std.testing.expect(!isVersionFlag("version"));
}

test "every Verb has a spec" {
    inline for (@typeInfo(Verb).@"enum".fields) |f| {
        const v: Verb = @enumFromInt(f.value);
        _ = verbSpec(v); // would `unreachable` if missing
    }
}
