const std = @import("std");

pub const SearchOptions = struct {
    paths: []const []const u8,
    extensions: []const []const u8,
    excludes: []const []const u8,
    base_dir: ?[]const u8 = null,

    pub fn shouldIncludePath(self: SearchOptions, file_path: []const u8) bool {
        const sep = std.fs.path.sep;
        for (self.excludes) |exclude| {
            if (std.mem.indexOf(u8, file_path, exclude) != null) {
                return false;
            }
        }

        if (self.paths.len > 0) {
            for (self.paths) |path_prefix| {
                var normalized_prefix = path_prefix;
                if (normalized_prefix.len > 0 and (normalized_prefix[normalized_prefix.len - 1] == '/' or normalized_prefix[normalized_prefix.len - 1] == sep)) {
                    normalized_prefix = normalized_prefix[0 .. normalized_prefix.len - 1];
                }

                if (std.mem.startsWith(u8, file_path, normalized_prefix)) {
                    if (file_path.len == normalized_prefix.len) return true;
                    const c = file_path[normalized_prefix.len];
                    if (c == '/' or c == sep) return true;
                }
            }
            return false;
        }

        return true;
    }

    pub fn matchesExtension(self: SearchOptions, file_path: []const u8) bool {
        for (self.extensions) |ext| {
            if (ext.len > 0 and ext[0] == '.') {
                if (std.ascii.endsWithIgnoreCase(file_path, ext)) return true;
            } else {
                if (file_path.len >= ext.len + 1 and
                    file_path[file_path.len - ext.len - 1] == '.' and
                    std.ascii.eqlIgnoreCase(file_path[file_path.len - ext.len ..], ext))
                {
                    return true;
                }
            }
        }
        return false;
    }
};

test "SearchOptions.matchesExtension: dot and dotless ext forms" {
    const opts: SearchOptions = .{
        .paths = &.{},
        .extensions = &.{ ".zig", "py" }, // both forms
        .excludes = &.{},
    };
    try std.testing.expect(opts.matchesExtension("main.zig"));
    try std.testing.expect(opts.matchesExtension("/a/b/main.zig"));
    try std.testing.expect(opts.matchesExtension("/a/b/main.PY")); // case insensitive
    try std.testing.expect(opts.matchesExtension("script.py"));
    try std.testing.expect(!opts.matchesExtension("script.pyc"));
    try std.testing.expect(!opts.matchesExtension("noext"));
    try std.testing.expect(!opts.matchesExtension(""));
}

test "SearchOptions.matchesExtension: empty filter rejects all" {
    const opts: SearchOptions = .{
        .paths = &.{},
        .extensions = &.{},
        .excludes = &.{},
    };
    try std.testing.expect(!opts.matchesExtension("main.zig"));
}

test "SearchOptions.matchesExtension: extension as substring isn't a match" {
    const opts: SearchOptions = .{
        .paths = &.{},
        .extensions = &.{"js"},
        .excludes = &.{},
    };
    // The "js" should NOT match "main.json" because the char before "js" is
    // 'o' not '.'.
    try std.testing.expect(!opts.matchesExtension("main.json"));
    try std.testing.expect(opts.matchesExtension("main.js"));
}

test "SearchOptions.shouldIncludePath: no path filter accepts all" {
    const opts: SearchOptions = .{
        .paths = &.{},
        .extensions = &.{},
        .excludes = &.{},
    };
    try std.testing.expect(opts.shouldIncludePath("/anywhere/file.zig"));
}

test "SearchOptions.shouldIncludePath: path prefix match respects directory boundary" {
    const opts: SearchOptions = .{
        .paths = &.{"src"},
        .extensions = &.{},
        .excludes = &.{},
    };
    try std.testing.expect(opts.shouldIncludePath("src/main.zig"));
    try std.testing.expect(opts.shouldIncludePath("src/sub/util.zig"));
    try std.testing.expect(opts.shouldIncludePath("src")); // exact dir match
    // A path that starts with "src" but continues with non-separator is NOT
    // inside that dir.
    try std.testing.expect(!opts.shouldIncludePath("srcsibling/main.zig"));
}

test "SearchOptions.shouldIncludePath: trailing slash in filter is tolerated" {
    const opts: SearchOptions = .{
        .paths = &.{"src/"},
        .extensions = &.{},
        .excludes = &.{},
    };
    try std.testing.expect(opts.shouldIncludePath("src/main.zig"));
}

test "SearchOptions.shouldIncludePath: excludes take priority" {
    const opts: SearchOptions = .{
        .paths = &.{"src"},
        .extensions = &.{},
        .excludes = &.{ "node_modules", ".git" },
    };
    try std.testing.expect(opts.shouldIncludePath("src/main.zig"));
    try std.testing.expect(!opts.shouldIncludePath("src/node_modules/x.js"));
    try std.testing.expect(!opts.shouldIncludePath("src/.git/index"));
}

// TODO(zig-0.16): re-introduce parallel search using std.Io.Group.concurrent
// once we have a need; for now we run the search sequentially since
// std.Thread.Pool was removed from the standard library.
pub fn run(unused_allocator: std.mem.Allocator, io: std.Io, query: []const u8, options: SearchOptions) !void {
    _ = unused_allocator;

    const gpa_allocator = std.heap.page_allocator;

    const start_time = std.Io.Clock.awake.now(io).toNanoseconds();
    var total_matches: usize = 0;

    {
        const cwd = std.Io.Dir.cwd();
        const walk_dir = if (options.base_dir) |base| base else ".";
        var dir = try cwd.openDir(io, walk_dir, .{ .iterate = true });
        defer dir.close(io);

        var walker = try dir.walk(gpa_allocator);
        defer walker.deinit();

        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!options.matchesExtension(entry.path)) continue;
            if (!options.shouldIncludePath(entry.path)) continue;

            const file = dir.openFile(io, entry.path, .{}) catch continue;
            defer file.close(io);

            const size = file.length(io) catch continue;
            if (size > 10 * 1024 * 1024) continue;

            const buf = gpa_allocator.alloc(u8, @intCast(size)) catch continue;
            defer gpa_allocator.free(buf);
            const read_n = file.readPositionalAll(io, buf, 0) catch continue;
            const content = buf[0..read_n];

            var local_matches: usize = 0;
            var output: std.Io.Writer.Allocating = .init(gpa_allocator);
            defer output.deinit();

            var line_no: usize = 1;
            var iter = std.mem.splitScalar(u8, content, '\n');
            while (iter.next()) |line| : (line_no += 1) {
                if (std.mem.indexOf(u8, line, query)) |_| {
                    local_matches += 1;
                    const trimmed = std.mem.trim(u8, line, " \t\r");
                    output.writer.print("{s}:{d}: {s}\n", .{ entry.path, line_no, trimmed }) catch {};
                }
            }

            if (local_matches > 0) {
                total_matches += local_matches;
                std.debug.print("{s}", .{output.written()});
            }
        }
    }

    const end_time = std.Io.Clock.awake.now(io).toNanoseconds();
    const duration_ns = end_time - start_time;
    const duration_ms = @as(f64, @floatFromInt(duration_ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms));

    std.debug.print("\nFound {d} matches in {d:.2}ms\n", .{ total_matches, duration_ms });
}
