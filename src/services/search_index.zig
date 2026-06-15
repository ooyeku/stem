//! Workspace search index.
//!
//! A persistent, in-memory list of the workspace's text-file paths.
//! Eliminates the directory walk on every `:Find` query — once the
//! index is warm, queries skip straight to the parallel scan in
//! `global_search`. Persisted across restarts in
//! `~/.stem/cache/search/<workspace-hash>.lst` (one path per line)
//! so even the *first* query in a new session is warm.
//!
//! Lifecycle:
//!
//!   1. `init(allocator, io, environ_block)` at Core construction time.
//!   2. `startIndexing(root)` once Core knows its workspace cwd.
//!      Spawns a detached worker that does:
//!        a. Try to load `<cache>.lst`. If present and the workspace
//!           root matches, populate the in-memory list immediately
//!           (first query is warm).
//!        b. Walk the workspace from disk, replace the in-memory list
//!           with the fresh result, write it back to the cache file.
//!   3. `notePathSaved(abs_path)` from Core when a buffer is saved —
//!      adds new files to the index without re-walking.
//!   4. `snapshot(allocator)` returns a fresh copy of the path list
//!      for the search to consume.

const std = @import("std");
const builtin = @import("builtin");
const vigil_api = @import("vigil_adapters.zig");

const log = std.log.scoped(.SearchIndex);

pub const SearchIndex = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_block: std.process.Environ.Block,

    mu: vigil_api.Mutex = .{},

    /// Absolute workspace root the cached list is keyed against.
    /// `null` until `startIndexing` is called. Owned by the index.
    root: ?[]u8 = null,

    /// Relative paths from `root`. Each entry is owned.
    paths: std.ArrayListUnmanaged([]u8) = .empty,

    /// Set true once the worker finishes the fresh disk walk. Until
    /// then `snapshot()` may return either an empty list (no cache
    /// hit) or the loaded-from-disk list (cache hit). Both are valid
    /// to feed to `global_search`.
    fresh: std.atomic.Value(bool) = .{ .raw = false },

    /// Set by `deinit` so the worker can abort mid-walk and `deinit`
    /// can wait for it to land instead of detaching into a freed
    /// `self`.
    shutdown_requested: std.atomic.Value(bool) = .{ .raw = false },

    /// Set by the worker while it's running. `deinit` spin-waits on
    /// this clearing so it doesn't return into freed memory.
    worker_running: std.atomic.Value(bool) = .{ .raw = false },

    /// Hard cap on the number of indexed paths. Keeps memory bounded
    /// on accidentally-huge workspaces (think dotfiles repo checked
    /// in alongside node_modules). Matches `global_search.Options.max_files`.
    max_paths: usize = 5000,

    pub const HealthSnapshot = struct {
        root: ?[]u8 = null,
        path_count: usize = 0,
        fresh: bool = false,
        indexing: bool = false,
        max_paths: usize = 0,
        at_capacity: bool = false,

        pub fn deinit(self: *HealthSnapshot, allocator: std.mem.Allocator) void {
            if (self.root) |r| allocator.free(r);
            self.root = null;
        }
    };

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        environ_block: std.process.Environ.Block,
    ) SearchIndex {
        return .{
            .allocator = allocator,
            .io = io,
            .environ_block = environ_block,
        };
    }

    pub fn deinit(self: *SearchIndex) void {
        // Tell the worker to abort, then wait for it to land before
        // we free the struct. Without this the detached worker would
        // keep writing through `self` after we'd freed it.
        self.shutdown_requested.store(true, .release);
        while (self.worker_running.load(.acquire)) {
            std.Thread.yield() catch {};
        }

        self.mu.lock();
        defer self.mu.unlock();
        if (self.root) |r| self.allocator.free(r);
        for (self.paths.items) |p| self.allocator.free(p);
        self.paths.deinit(self.allocator);
    }

    /// Start background indexing for `root` (absolute path). Idempotent
    /// — calling again with the same root is a no-op; with a new root,
    /// resets the index and re-walks.
    pub fn startIndexing(self: *SearchIndex, root_abs: []const u8) !void {
        // Don't start a second worker if one is already running —
        // they'd race on `applyPaths`/`replacePaths`, and shutdown
        // only waits for a single `worker_running` flag.
        if (self.worker_running.load(.acquire)) return;

        self.mu.lock();
        const already_same = if (self.root) |r| std.mem.eql(u8, r, root_abs) else false;
        self.mu.unlock();
        if (already_same) return;

        const root_dup = try self.allocator.dupe(u8, root_abs);
        errdefer self.allocator.free(root_dup);

        self.worker_running.store(true, .release);
        errdefer self.worker_running.store(false, .release);

        // Hand the root over to the worker. The worker frees it
        // after the walk completes.
        const t = try std.Thread.spawn(.{}, indexerWorker, .{ self, root_dup });
        t.detach();
    }

    /// Append a path the user just saved, if it's inside our root and
    /// not already indexed. Cheap — O(N) lookup since we don't keep
    /// a set, but N is bounded at `max_paths` and the cost is paid on
    /// save, not on query.
    /// Append a path the user just saved. Accepts either an absolute
    /// path (typical: editor knows the full file path) or a path
    /// relative to the workspace root (some save call sites pass a
    /// relative form). Anything that doesn't end up inside `root` is
    /// silently dropped.
    pub fn notePathSaved(self: *SearchIndex, path: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        const root = self.root orelse return;

        var rel: []const u8 = undefined;
        if (std.fs.path.isAbsolute(path)) {
            rel = pathInsideRoot(path, root) orelse return;
        } else {
            // Treat as already-relative-to-root. Drop a leading
            // "./" so we don't accidentally store two entries for
            // the same file.
            rel = path;
            if (rel.len >= 2 and rel[0] == '.' and (rel[1] == '/' or rel[1] == '\\')) {
                rel = rel[2..];
            }
        }
        if (rel.len == 0) return;

        for (self.paths.items) |p| {
            if (std.mem.eql(u8, p, rel)) return;
        }
        if (self.paths.items.len >= self.max_paths) return;
        const dup = self.allocator.dupe(u8, rel) catch return;
        self.paths.append(self.allocator, dup) catch {
            self.allocator.free(dup);
        };
    }

    /// Return a fresh copy of the current path list. Caller owns the
    /// outer slice and each entry. Returns an empty slice (not null)
    /// when the index hasn't been populated yet — callers can fall
    /// through to a fresh walk via `global_search.search`.
    pub fn snapshot(self: *SearchIndex, alloc: std.mem.Allocator) ![][]u8 {
        self.mu.lock();
        defer self.mu.unlock();
        const out = try alloc.alloc([]u8, self.paths.items.len);
        var i: usize = 0;
        errdefer {
            for (out[0..i]) |s| alloc.free(s);
            alloc.free(out);
        }
        while (i < self.paths.items.len) : (i += 1) {
            out[i] = try alloc.dupe(u8, self.paths.items[i]);
        }
        return out;
    }

    /// True once the fresh disk walk has finished. Callers can choose
    /// to wait for this if they want guaranteed-up-to-date results.
    pub fn isFresh(self: *SearchIndex) bool {
        return self.fresh.load(.acquire);
    }

    pub fn healthSnapshot(self: *SearchIndex, allocator: std.mem.Allocator) !HealthSnapshot {
        self.mu.lock();
        defer self.mu.unlock();

        const root = if (self.root) |r| try allocator.dupe(u8, r) else null;
        errdefer if (root) |r| allocator.free(r);

        const path_count = self.paths.items.len;
        return .{
            .root = root,
            .path_count = path_count,
            .fresh = self.fresh.load(.acquire),
            .indexing = self.worker_running.load(.acquire),
            .max_paths = self.max_paths,
            .at_capacity = path_count >= self.max_paths,
        };
    }
};

fn isPathSeparator(c: u8) bool {
    return c == '/' or c == '\\';
}

fn pathInsideRoot(abs_path: []const u8, root: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, abs_path, root)) return null;
    if (abs_path.len == root.len) return "";

    if (root.len > 0 and isPathSeparator(root[root.len - 1])) {
        return abs_path[root.len..];
    }

    if (!isPathSeparator(abs_path[root.len])) return null;
    return abs_path[root.len + 1 ..];
}

fn indexerWorker(self: *SearchIndex, root_owned: []u8) void {
    @import("thread_name.zig").set("stem-index");
    defer self.allocator.free(root_owned);

    // Always clear the running flag last — `deinit` spin-waits on it
    // before freeing `self`. Releasing the flag must be the worker's
    // final write through `self`.
    defer self.worker_running.store(false, .release);

    // Phase 1: try the on-disk cache for an instant first-query warm.
    var cache_applied = false;
    if (readCacheFile(self, root_owned)) |cached| {
        defer {
            // `cached` is a slice of independently-duped strings;
            // free each, then the outer slice. (The previous version
            // only freed the outer slice, leaking every path.)
            for (cached) |s| self.allocator.free(s);
            self.allocator.free(cached);
        }
        if (applyPaths(self, root_owned, cached)) {
            cache_applied = true;
            log.info("SearchIndex: loaded {d} paths from cache for {s}", .{ cached.len, root_owned });
        } else |err| {
            log.debug("SearchIndex: cached paths rejected for {s}: {}", .{ root_owned, err });
        }
    } else |err| {
        log.debug("SearchIndex: cache miss for {s} ({})", .{ root_owned, err });
    }

    if (self.shutdown_requested.load(.acquire)) return;

    // Phase 2: fresh walk.
    var walked: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (walked.items) |p| self.allocator.free(p);
        walked.deinit(self.allocator);
    }
    walkWorkspace(self, root_owned, &walked) catch |err| {
        log.warn("SearchIndex: walk failed for {s}: {}", .{ root_owned, err });
        return;
    };

    if (self.shutdown_requested.load(.acquire)) return;

    // Move the freshly walked paths into the index.
    if (!cache_applied) {
        applyPaths(self, root_owned, walked.items) catch return;
    } else {
        replacePaths(self, walked.items) catch return;
    }

    // Persist back to disk for the next stem launch.
    writeCacheFile(self, root_owned, walked.items) catch |err| {
        log.debug("SearchIndex: cache write failed: {}", .{err});
    };

    self.fresh.store(true, .release);
    log.info("SearchIndex: indexed {d} paths under {s}", .{ walked.items.len, root_owned });
}

fn applyPaths(self: *SearchIndex, root_abs: []const u8, paths_src: []const []const u8) !void {
    self.mu.lock();
    defer self.mu.unlock();

    if (self.root == null) {
        self.root = try self.allocator.dupe(u8, root_abs);
    } else if (!std.mem.eql(u8, self.root.?, root_abs)) {
        // Workspace changed mid-flight — drop the new walk.
        return error.RootMismatch;
    }

    // Replace existing paths.
    for (self.paths.items) |p| self.allocator.free(p);
    self.paths.clearRetainingCapacity();
    try self.paths.ensureTotalCapacity(self.allocator, paths_src.len);
    for (paths_src) |p| {
        const dup = try self.allocator.dupe(u8, p);
        self.paths.appendAssumeCapacity(dup);
    }
}

fn replacePaths(self: *SearchIndex, paths_src: []const []const u8) !void {
    self.mu.lock();
    defer self.mu.unlock();
    for (self.paths.items) |p| self.allocator.free(p);
    self.paths.clearRetainingCapacity();
    try self.paths.ensureTotalCapacity(self.allocator, paths_src.len);
    for (paths_src) |p| {
        const dup = try self.allocator.dupe(u8, p);
        self.paths.appendAssumeCapacity(dup);
    }
}

/// Recursive walk, capped at `max_paths`. Mirrors the skip-list used
/// inside `global_search` so the cached list stays consistent with
/// the live walk.
fn walkWorkspace(self: *SearchIndex, root: []const u8, out: *std.ArrayListUnmanaged([]u8)) !void {
    var stack: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (stack.items) |p| self.allocator.free(p);
        stack.deinit(self.allocator);
    }
    try stack.append(self.allocator, try self.allocator.dupe(u8, ""));

    while (stack.pop()) |rel| {
        defer self.allocator.free(rel);
        if (self.shutdown_requested.load(.acquire)) return;
        const abs = try std.fs.path.join(self.allocator, &.{ root, rel });
        defer self.allocator.free(abs);

        var dir = std.Io.Dir.openDirAbsolute(self.io, abs, .{ .iterate = true }) catch continue;
        defer dir.close(self.io);
        var it = dir.iterate();
        while (it.next(self.io) catch null) |entry| {
            if (out.items.len >= self.max_paths) return;
            if (self.shutdown_requested.load(.acquire)) return;
            if (shouldSkip(entry.name)) continue;
            const child_rel = if (rel.len == 0)
                try self.allocator.dupe(u8, entry.name)
            else
                try std.fs.path.join(self.allocator, &.{ rel, entry.name });
            if (entry.kind == .directory) {
                try stack.append(self.allocator, child_rel);
            } else if (entry.kind == .file) {
                try out.append(self.allocator, child_rel);
            } else {
                self.allocator.free(child_rel);
            }
        }
    }
}

fn shouldSkip(name: []const u8) bool {
    const skip = [_][]const u8{
        ".git",          ".hg",         ".svn",
        "node_modules",  "vendor",      "target",
        "build",         "dist",        "out",
        ".zig-cache",    "zig-cache",   "zig-out",
        "zig-pkg",       ".cache",      ".idea",
        ".vscode",       "__pycache__", ".venv",
        "venv",          ".tox",        ".mypy_cache",
        ".pytest_cache", ".next",       ".nuxt",
        ".gradle",       "DerivedData",
    };
    for (skip) |s| {
        if (std.mem.eql(u8, s, name)) return true;
    }
    return false;
}

test "SearchIndex notePathSaved rejects sibling roots with matching prefix" {
    const allocator = std.testing.allocator;
    const TestIo = @import("../test_utils.zig").TestIo;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();

    var index = SearchIndex.init(allocator, io_ctx.io(), .empty);
    defer index.deinit();
    index.root = try allocator.dupe(u8, "/tmp/work");

    index.notePathSaved("/tmp/workspace/file.zig");
    try std.testing.expectEqual(@as(usize, 0), index.paths.items.len);

    index.notePathSaved("/tmp/work/src/main.zig");
    try std.testing.expectEqual(@as(usize, 1), index.paths.items.len);
    try std.testing.expectEqualStrings("src/main.zig", index.paths.items[0]);
}

test "SearchIndex does not skip ordinary dotfiles" {
    try std.testing.expect(!shouldSkip(".env.example"));
    try std.testing.expect(!shouldSkip(".editorconfig"));
    try std.testing.expect(shouldSkip(".git"));
}

test "SearchIndex health snapshot reports root freshness and capacity" {
    const allocator = std.testing.allocator;
    const TestIo = @import("../test_utils.zig").TestIo;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();

    var index = SearchIndex.init(allocator, io_ctx.io(), .empty);
    defer index.deinit();
    index.root = try allocator.dupe(u8, "/tmp/work");
    index.max_paths = 2;
    try index.paths.append(allocator, try allocator.dupe(u8, "src/main.zig"));
    try index.paths.append(allocator, try allocator.dupe(u8, "README.md"));
    index.fresh.store(true, .release);

    var snapshot = try index.healthSnapshot(allocator);
    defer snapshot.deinit(allocator);

    try std.testing.expectEqualStrings("/tmp/work", snapshot.root.?);
    try std.testing.expectEqual(@as(usize, 2), snapshot.path_count);
    try std.testing.expect(snapshot.fresh);
    try std.testing.expect(!snapshot.indexing);
    try std.testing.expect(snapshot.at_capacity);

    allocator.free(index.root.?);
    index.root = try allocator.dupe(u8, "/tmp/other");
    try std.testing.expectEqualStrings("/tmp/work", snapshot.root.?);
}

// ---------------------------------------------------------------------------
// Cache I/O
// ---------------------------------------------------------------------------

fn cachePath(allocator: std.mem.Allocator, environ_block: std.process.Environ.Block, root_abs: []const u8) ![]u8 {
    const platform = @import("../kernel/platform.zig");
    const home = (try platform.getEnv(allocator, environ_block, "HOME")) orelse
        (try platform.getEnv(allocator, environ_block, "USERPROFILE")) orelse
        return error.NoHome;
    defer allocator.free(home);
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(root_abs);
    const h = hasher.final();
    const filename = try std.fmt.allocPrint(allocator, "{x:0>16}.lst", .{h});
    defer allocator.free(filename);
    return std.fs.path.join(allocator, &.{ home, ".stem", "cache", "search", filename });
}

/// Magic header line written at the top of every cache file. Tagged
/// with the absolute workspace root so a Wyhash collision (or a
/// stale file lying around from another workspace) gets rejected
/// instead of returning paths for the wrong tree.
const cache_magic = "stem-search-index v1 root=";

/// Read the on-disk cache file. Returns a heap-allocated slice of
/// independently-duped path strings — caller must free each string
/// *and* the outer slice.
fn readCacheFile(self: *SearchIndex, root_abs: []const u8) ![][]u8 {
    const path = try cachePath(self.allocator, self.environ_block, root_abs);
    defer self.allocator.free(path);

    const file = try std.Io.Dir.openFileAbsolute(self.io, path, .{});
    defer file.close(self.io);
    const size = try file.length(self.io);
    if (size == 0 or size > 16 * 1024 * 1024) return error.UnexpectedSize;
    const bytes = try self.allocator.alloc(u8, @intCast(size));
    defer self.allocator.free(bytes);
    const read_n = try file.readPositionalAll(self.io, bytes, 0);
    if (read_n == 0) return error.UnexpectedSize;

    var it = std.mem.splitScalar(u8, bytes[0..read_n], '\n');
    const header = it.next() orelse return error.MissingHeader;
    if (!std.mem.startsWith(u8, header, cache_magic)) return error.BadHeader;
    const header_root = header[cache_magic.len..];
    if (!std.mem.eql(u8, header_root, root_abs)) return error.RootMismatch;

    var out: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (out.items) |s| self.allocator.free(s);
        out.deinit(self.allocator);
    }
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const dup = try self.allocator.dupe(u8, line);
        try out.append(self.allocator, dup);
    }
    return out.toOwnedSlice(self.allocator);
}

fn writeCacheFile(self: *SearchIndex, root_abs: []const u8, paths: []const []const u8) !void {
    const path = try cachePath(self.allocator, self.environ_block, root_abs);
    defer self.allocator.free(path);

    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.cwd().createDirPath(self.io, dir) catch {};
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(self.allocator);
    try buf.appendSlice(self.allocator, cache_magic);
    try buf.appendSlice(self.allocator, root_abs);
    try buf.append(self.allocator, '\n');
    for (paths) |p| {
        try buf.appendSlice(self.allocator, p);
        try buf.append(self.allocator, '\n');
    }

    // Write to a temp file then rename so a crash mid-write doesn't
    // leave a truncated cache.
    const tmp = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{path});
    defer self.allocator.free(tmp);
    {
        const file = try std.Io.Dir.createFileAbsolute(self.io, tmp, .{});
        defer file.close(self.io);
        try file.writeStreamingAll(self.io, buf.items);
    }
    // Best-effort: if rename fails (e.g., crossing filesystems on
    // some setups), fall back to writing directly.
    std.Io.Dir.renameAbsolute(tmp, path, self.io) catch |err| {
        log.debug("rename {s} -> {s} failed: {}; falling back to direct write", .{ tmp, path, err });
        std.Io.Dir.cwd().deleteFile(self.io, tmp) catch {};
        const file = try std.Io.Dir.createFileAbsolute(self.io, path, .{});
        defer file.close(self.io);
        try file.writeStreamingAll(self.io, buf.items);
    };
}
