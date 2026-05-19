//! Project-wide text search. Walks the current working directory recursively,
//! reads each text file under a size cap, finds substring matches, and returns
//! sorted [`protocol.GlobalSearchFileGroup`] entries. All returned memory is
//! owned by the caller (matched lines and paths are duped from the allocator
//! passed to `search`).

const std = @import("std");
const protocol = @import("../kernel/protocol.zig");

pub const Options = struct {
    /// Match query case-insensitively. Whole-word and regex are not yet
    /// supported; the fields exist in [`protocol.GlobalSearchOptions`] but the
    /// matcher ignores them.
    search: protocol.GlobalSearchOptions = .{},
    /// Hard cap on number of files scanned. Prevents the search from stalling
    /// in monorepos.
    max_files: usize = 5000,
    /// Files larger than this are skipped (likely generated / binary).
    max_file_size: u64 = 1024 * 1024,
    /// Length prefix used for the binary-file NUL sniff.
    binary_sniff_bytes: usize = 8192,
    /// Truncate stored line content to this length.
    max_line_len: usize = 200,
};

/// Run a recursive global search rooted at `root_dir` (a path relative to
/// `cwd` or absolute). Returns owned `[]GlobalSearchFileGroup` sorted by
/// `file_path`. Caller is responsible for freeing via `freeResults`.
pub fn search(
    allocator: std.mem.Allocator,
    io: std.Io,
    query: []const u8,
    root_dir: []const u8,
    options: Options,
) ![]protocol.GlobalSearchFileGroup {
    return searchWithPaths(allocator, io, query, root_dir, options, null);
}

/// Like `search`, but accepts a pre-built relative-path list (from
/// `services/search_index.zig`). When `cached_paths` is non-null we
/// skip the directory walk entirely — first query in a warm session
/// is ~30 ms faster, and on huge workspaces the savings grow with the
/// file count.
pub fn searchWithPaths(
    allocator: std.mem.Allocator,
    io: std.Io,
    query: []const u8,
    root_dir: []const u8,
    options: Options,
    cached_paths: ?[]const []const u8,
) ![]protocol.GlobalSearchFileGroup {
    if (query.len == 0) return &.{};

    const cwd = std.Io.Dir.cwd();
    var root = try cwd.openDir(io, root_dir, .{ .iterate = true });
    defer root.close(io);

    var rel_paths: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (rel_paths.items) |p| allocator.free(p);
        rel_paths.deinit(allocator);
    }

    if (cached_paths) |cp| {
        // Trust the index — copy the path strings into our owned
        // list. The index can hold stale entries (file deleted since
        // index time); the per-file open in phase 2 just skips them.
        try rel_paths.ensureTotalCapacity(allocator, @min(cp.len, options.max_files));
        for (cp) |p| {
            if (rel_paths.items.len >= options.max_files) break;
            rel_paths.appendAssumeCapacity(try allocator.dupe(u8, p));
        }
    } else {
        var walker = try root.walkSelectively(allocator);
        defer walker.deinit();

        // Phase 1 (serial): walk the tree and collect candidate file
        // paths (relative to root_dir). The walk itself can't easily
        // be parallelized — directory iteration is inherently
        // sequential at each level — but it's fast compared to the
        // per-file scan, which is where the wins are.

        while (try walker.next(io)) |entry| {
            if (entry.kind == .directory) {
                if (shouldSkipDir(entry.basename)) continue;
                try walker.enter(io, entry);
                continue;
            }
            if (entry.kind != .file) continue;
            if (rel_paths.items.len >= options.max_files) break;
            try rel_paths.append(allocator, try allocator.dupe(u8, entry.path));
        }
    }

    // Phase 2: parallel per-file scan. Worker count scales with CPU count,
    // capped so we don't oversubscribe on big-core machines. Tiny projects
    // skip the spawn overhead and run inline.
    const cpu_count: usize = std.Thread.getCpuCount() catch 1;
    var worker_count: usize = @min(cpu_count, 8);
    if (rel_paths.items.len < 32) worker_count = 1;
    if (worker_count == 0) worker_count = 1;

    // Per-worker scratch state. Each worker writes to its OWN
    // `local_matches`; main thread merges after they join. Same shared
    // allocator (std.testing/page/gpa are all thread-safe), so we don't
    // need per-thread arenas — just per-thread maps.
    const Worker = struct {
        rel_paths_slice: [][]u8,
        query: []const u8,
        options: Options,
        root: std.Io.Dir,
        allocator: std.mem.Allocator,
        io: std.Io,
        local_matches: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(protocol.GlobalSearchMatch)) = .empty,
    };

    var workers = try allocator.alloc(*Worker, worker_count);
    defer allocator.free(workers);
    var threads = try allocator.alloc(?std.Thread, worker_count);
    defer allocator.free(threads);
    @memset(threads, null);

    const chunk: usize = (rel_paths.items.len + worker_count - 1) / worker_count;
    var spawned: usize = 0;
    for (0..worker_count) |i| {
        const start = i * chunk;
        if (start >= rel_paths.items.len) break;
        const end = @min(start + chunk, rel_paths.items.len);

        const w = try allocator.create(Worker);
        w.* = .{
            .rel_paths_slice = rel_paths.items[start..end],
            .query = query,
            .options = options,
            .root = root,
            .allocator = allocator,
            .io = io,
        };
        workers[i] = w;
        spawned = i + 1;

        if (worker_count == 1) {
            // Inline path — no threads, no contention.
            scanWorkerMain(w);
        } else {
            threads[i] = std.Thread.spawn(.{}, scanWorkerMain, .{w}) catch blk: {
                // Couldn't spawn — fall back to inline.
                scanWorkerMain(w);
                break :blk null;
            };
        }
    }

    for (threads[0..spawned]) |maybe_t| {
        if (maybe_t) |t| t.join();
    }

    // Merge all worker maps into the master map. Each worker's keys are
    // already duped from `rel_paths` strings — transfer ownership directly.
    var file_matches: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(protocol.GlobalSearchMatch)) = .empty;
    defer {
        var it = file_matches.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.items) |m| allocator.free(m.line_content);
            entry.value_ptr.deinit(allocator);
        }
        file_matches.deinit(allocator);
    }

    for (workers[0..spawned]) |w| {
        var it = w.local_matches.iterator();
        while (it.next()) |entry| {
            const gop = try file_matches.getOrPut(allocator, entry.key_ptr.*);
            if (gop.found_existing) {
                // Two workers shouldn't have the same path (we partitioned
                // disjointly), but if it ever happens, free the duplicate
                // key from the second worker.
                allocator.free(entry.key_ptr.*);
                for (entry.value_ptr.items) |m| allocator.free(m.line_content);
                entry.value_ptr.deinit(allocator);
            } else {
                gop.value_ptr.* = entry.value_ptr.*;
            }
        }
        w.local_matches.deinit(allocator);
        allocator.destroy(w);
    }

    // Collect & sort paths.
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer paths.deinit(allocator);
    var key_it = file_matches.keyIterator();
    while (key_it.next()) |k| try paths.append(allocator, k.*);
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    // Transfer ownership of keys + matches into an owned []FileGroup.
    var groups: std.ArrayListUnmanaged(protocol.GlobalSearchFileGroup) = .empty;
    errdefer freeResults(allocator, groups.toOwnedSlice(allocator) catch &.{});
    try groups.ensureTotalCapacity(allocator, paths.items.len);
    for (paths.items) |p| {
        const kv = file_matches.fetchRemove(p).?;
        const matches_owned = kv.value.items;
        const new_matches = try allocator.alloc(protocol.GlobalSearchMatch, matches_owned.len);
        @memcpy(new_matches, matches_owned);
        var mutable_value = kv.value;
        mutable_value.deinit(allocator);
        try groups.append(allocator, .{
            .file_path = kv.key,
            .matches = new_matches,
            .collapsed = false,
        });
    }

    return groups.toOwnedSlice(allocator);
}

fn scanWorkerMain(w: anytype) void {
    for (w.rel_paths_slice) |rel_path| {
        searchFileByRelPath(w.allocator, w.io, w.root, rel_path, w.query, w.options, &w.local_matches) catch |err| {
            std.log.debug("GlobalSearch worker: skipped {s}: {}", .{ rel_path, err });
        };
    }
}

/// Variant of `searchFile` that opens the file by its relative path
/// against a shared `root` Dir handle. The shared Dir handle is safe to
/// use concurrently because each `openFile` call returns an independent
/// handle and Zig's `std.Io.Dir` is documented as read-thread-safe.
fn searchFileByRelPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    rel_path: []const u8,
    query: []const u8,
    options: Options,
    file_matches: *std.StringHashMapUnmanaged(std.ArrayListUnmanaged(protocol.GlobalSearchMatch)),
) !void {
    var file = try root.openFile(io, rel_path, .{});
    defer file.close(io);

    const size = try file.length(io);
    if (size == 0 or size > options.max_file_size) return;

    const buf = try allocator.alloc(u8, @intCast(size));
    defer allocator.free(buf);
    const read_n = try file.readPositionalAll(io, buf, 0);
    const content = buf[0..read_n];

    const sniff_len = @min(content.len, options.binary_sniff_bytes);
    if (std.mem.indexOfScalar(u8, content[0..sniff_len], 0) != null) return;

    var line_num: usize = 1;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i <= content.len) : (i += 1) {
        const at_eof = i == content.len;
        const is_newline = !at_eof and content[i] == '\n';
        if (!at_eof and !is_newline) continue;

        const line = content[line_start..i];
        defer {
            line_start = i + 1;
            line_num += 1;
        }
        if (line.len == 0 or line.len < query.len) continue;

        if (indexOf(line, query, options.search.case_sensitive)) |pos| {
            const gop = try file_matches.getOrPut(allocator, rel_path);
            if (!gop.found_existing) {
                gop.key_ptr.* = try allocator.dupe(u8, rel_path);
                gop.value_ptr.* = .empty;
            }
            const trimmed = std.mem.trim(u8, line, " \t\r");
            const stored = if (trimmed.len > options.max_line_len) trimmed[0..options.max_line_len] else trimmed;
            const dup = try allocator.dupe(u8, stored);
            errdefer allocator.free(dup);
            try gop.value_ptr.append(allocator, .{
                .line_num = line_num,
                .line_content = dup,
                .match_start = pos,
                .match_end = pos + query.len,
            });
        }
    }
}

/// Free the slice returned by `search`.
pub fn freeResults(allocator: std.mem.Allocator, results: []protocol.GlobalSearchFileGroup) void {
    for (results) |group| {
        for (group.matches) |m| allocator.free(m.line_content);
        allocator.free(group.matches);
        allocator.free(group.file_path);
    }
    if (results.len > 0) allocator.free(results);
}

fn shouldSkipDir(basename: []const u8) bool {
    // Skip common build / vcs / vendor dirs. We compare component-wise so
    // names like `foo.gitignore` don't false-match `.git`.
    return std.mem.eql(u8, basename, ".git") or
        std.mem.eql(u8, basename, ".hg") or
        std.mem.eql(u8, basename, ".svn") or
        std.mem.eql(u8, basename, "node_modules") or
        std.mem.eql(u8, basename, "zig-cache") or
        std.mem.eql(u8, basename, ".zig-cache") or
        std.mem.eql(u8, basename, "zig-out") or
        std.mem.eql(u8, basename, "zig-pkg") or
        std.mem.eql(u8, basename, "target") or
        std.mem.eql(u8, basename, "build") or
        std.mem.eql(u8, basename, "dist") or
        std.mem.eql(u8, basename, ".venv") or
        std.mem.eql(u8, basename, "venv") or
        std.mem.eql(u8, basename, "__pycache__");
}

test "global_search finds a match in a small temp directory" {
    const TestIo = @import("../test_utils.zig").TestIo;
    const a = std.testing.allocator;

    var io_ctx = TestIo.init(a);
    defer io_ctx.deinit();
    const io = io_ctx.io();

    // Build a tmp directory under /tmp via std.Io APIs.
    const ts = std.Io.Clock.real.now(io).toMilliseconds();
    const tmp_dir_name = try std.fmt.allocPrint(a, "/tmp/stem-search-test-{d}", .{ts});
    defer a.free(tmp_dir_name);

    try std.Io.Dir.cwd().createDirPath(io, tmp_dir_name);
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir_name) catch {};

    // Write two files into the tmp dir.
    {
        const p = try std.fs.path.join(a, &.{ tmp_dir_name, "hit.zig" });
        defer a.free(p);
        const f = try std.Io.Dir.createFileAbsolute(io, p, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "fn register() void {}\nconst x = 1;\n");
    }
    {
        const p = try std.fs.path.join(a, &.{ tmp_dir_name, "miss.txt" });
        defer a.free(p);
        const f = try std.Io.Dir.createFileAbsolute(io, p, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "unrelated content\n");
    }

    const results = try search(a, io, "register", tmp_dir_name, .{});
    defer freeResults(a, results);

    try std.testing.expect(results.len == 1);
    try std.testing.expect(std.mem.endsWith(u8, results[0].file_path, "hit.zig"));
    try std.testing.expect(results[0].matches.len >= 1);
}

fn indexOf(haystack: []const u8, needle: []const u8, case_sensitive: bool) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    if (case_sensitive) return std.mem.indexOf(u8, haystack, needle);

    const end = haystack.len - needle.len + 1;
    var i: usize = 0;
    while (i < end) : (i += 1) {
        var match = true;
        for (0..needle.len) |j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                match = false;
                break;
            }
        }
        if (match) return i;
    }
    return null;
}

// ---------- Additional global_search tests ----------

test "global_search recurses into subdirs and dedups matches per line" {
    const TestIo = @import("../test_utils.zig").TestIo;
    const a = std.testing.allocator;

    var io_ctx = TestIo.init(a);
    defer io_ctx.deinit();
    const io = io_ctx.io();

    const ts = std.Io.Clock.real.now(io).toMilliseconds();
    const tmp_dir_name = try std.fmt.allocPrint(a, "/tmp/stem-gsearch-test2-{d}", .{ts});
    defer a.free(tmp_dir_name);
    try std.Io.Dir.cwd().createDirPath(io, tmp_dir_name);
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir_name) catch {};

    // Create nested subdir.
    const sub = try std.fs.path.join(a, &.{ tmp_dir_name, "deep", "nested" });
    defer a.free(sub);
    try std.Io.Dir.cwd().createDirPath(io, sub);

    // File at root.
    {
        const p = try std.fs.path.join(a, &.{ tmp_dir_name, "root.zig" });
        defer a.free(p);
        const f = try std.Io.Dir.createFileAbsolute(io, p, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "needle\n");
    }
    // File deep in nested subdir with two needles on different lines.
    {
        const p = try std.fs.path.join(a, &.{ sub, "deep.zig" });
        defer a.free(p);
        const f = try std.Io.Dir.createFileAbsolute(io, p, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "needle line one\nnot match\nneedle again\n");
    }

    const results = try search(a, io, "needle", tmp_dir_name, .{});
    defer freeResults(a, results);

    try std.testing.expectEqual(@as(usize, 2), results.len);
    // Find which entry is which by suffix.
    var root_idx: ?usize = null;
    var deep_idx: ?usize = null;
    for (results, 0..) |g, i| {
        if (std.mem.endsWith(u8, g.file_path, "root.zig")) root_idx = i;
        if (std.mem.endsWith(u8, g.file_path, "deep.zig")) deep_idx = i;
    }
    try std.testing.expect(root_idx != null);
    try std.testing.expect(deep_idx != null);
    try std.testing.expectEqual(@as(usize, 1), results[root_idx.?].matches.len);
    // deep.zig has 2 matching lines.
    try std.testing.expectEqual(@as(usize, 2), results[deep_idx.?].matches.len);
}

test "global_search skips binary files" {
    const TestIo = @import("../test_utils.zig").TestIo;
    const a = std.testing.allocator;

    var io_ctx = TestIo.init(a);
    defer io_ctx.deinit();
    const io = io_ctx.io();

    const ts = std.Io.Clock.real.now(io).toMilliseconds();
    const tmp = try std.fmt.allocPrint(a, "/tmp/stem-gsearch-bin-{d}", .{ts});
    defer a.free(tmp);
    try std.Io.Dir.cwd().createDirPath(io, tmp);
    defer std.Io.Dir.cwd().deleteTree(io, tmp) catch {};

    {
        const p = try std.fs.path.join(a, &.{ tmp, "text.txt" });
        defer a.free(p);
        const f = try std.Io.Dir.createFileAbsolute(io, p, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "find me here\n");
    }
    {
        const p = try std.fs.path.join(a, &.{ tmp, "binary.bin" });
        defer a.free(p);
        const f = try std.Io.Dir.createFileAbsolute(io, p, .{});
        defer f.close(io);
        // NUL byte triggers binary detection.
        try f.writeStreamingAll(io, "find\x00me\n");
    }

    const results = try search(a, io, "find", tmp, .{});
    defer freeResults(a, results);
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expect(std.mem.endsWith(u8, results[0].file_path, "text.txt"));
}

test "global_search skips standard build/vcs dirs" {
    const TestIo = @import("../test_utils.zig").TestIo;
    const a = std.testing.allocator;

    var io_ctx = TestIo.init(a);
    defer io_ctx.deinit();
    const io = io_ctx.io();

    const ts = std.Io.Clock.real.now(io).toMilliseconds();
    const tmp = try std.fmt.allocPrint(a, "/tmp/stem-gsearch-skip-{d}", .{ts});
    defer a.free(tmp);
    try std.Io.Dir.cwd().createDirPath(io, tmp);
    defer std.Io.Dir.cwd().deleteTree(io, tmp) catch {};

    // Create a real file in the project root (should be found).
    {
        const p = try std.fs.path.join(a, &.{ tmp, "real.zig" });
        defer a.free(p);
        const f = try std.Io.Dir.createFileAbsolute(io, p, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "TARGET\n");
    }
    // Create files in skip dirs (should NOT be found).
    for ([_][]const u8{ ".git", "node_modules", "zig-cache" }) |dir| {
        const sub = try std.fs.path.join(a, &.{ tmp, dir });
        defer a.free(sub);
        try std.Io.Dir.cwd().createDirPath(io, sub);
        const fpath = try std.fs.path.join(a, &.{ sub, "ignored.txt" });
        defer a.free(fpath);
        const f = try std.Io.Dir.createFileAbsolute(io, fpath, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "TARGET in ignored\n");
    }

    const results = try search(a, io, "TARGET", tmp, .{});
    defer freeResults(a, results);
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expect(std.mem.endsWith(u8, results[0].file_path, "real.zig"));
}
