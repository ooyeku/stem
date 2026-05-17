//! `stem find` / `stem vfind`: project-wide grep.
//!
//! Walks the working directory, scans every plaintext file under the
//! configured filters, and prints matches in a grouped, color-aware
//! format with line and column numbers.
//!
//! Robustness:
//!   - Uses the caller-supplied allocator everywhere so leaks are caught
//!     by `std.testing.allocator` / the editor's DebugAllocator.
//!   - Skips binary files (NUL byte heuristic) so a `find foo` over a
//!     repo with vendored binaries doesn't dump junk to the terminal.
//!   - Caps per-file size at 10 MiB.
//!   - Buffers output through a single 16 KiB stdout writer instead of
//!     one syscall per match.

const std = @import("std");
const format = @import("format.zig");

const Hit = format.Hit;

pub const Case = enum {
    /// Case-sensitive iff the query has an uppercase letter.
    smart,
    sensitive,
    insensitive,
};

pub const SearchOptions = struct {
    paths: []const []const u8,
    extensions: []const []const u8,
    excludes: []const []const u8,
    base_dir: ?[]const u8 = null,
    case: Case = .smart,
    /// Force color on/off. `null` ⇒ auto (TTY + NO_COLOR).
    color_override: ?bool = null,
    /// Force pretty/compact output. `null` ⇒ auto (pretty in TTY, compact in pipe).
    pretty_override: ?bool = null,
    /// Largest file we'll grep through.
    max_file_size: usize = 10 * 1024 * 1024,
    /// Stop after this many matches in a single file. `null` ⇒ unlimited.
    max_matches_per_file: ?usize = null,

    pub fn shouldIncludePath(self: SearchOptions, file_path: []const u8) bool {
        const sep = std.fs.path.sep;
        for (self.excludes) |exclude| {
            if (std.mem.indexOf(u8, file_path, exclude) != null) return false;
        }

        if (self.paths.len > 0) {
            for (self.paths) |path_prefix| {
                var normalized_prefix = path_prefix;
                if (normalized_prefix.len > 0 and
                    (normalized_prefix[normalized_prefix.len - 1] == '/' or
                        normalized_prefix[normalized_prefix.len - 1] == sep))
                {
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
        if (self.extensions.len == 0) return true;
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

/// Find every byte-offset where `needle` occurs in `haystack`. Caller
/// owns the returned slice (allocator-managed). Empty result on no match.
pub fn findAll(
    allocator: std.mem.Allocator,
    haystack: []const u8,
    needle: []const u8,
    case_insensitive: bool,
) ![]Hit {
    if (needle.len == 0 or haystack.len < needle.len) return allocator.alloc(Hit, 0);

    var hits: std.ArrayListUnmanaged(Hit) = .empty;
    errdefer hits.deinit(allocator);

    if (!case_insensitive) {
        var search_start: usize = 0;
        while (search_start <= haystack.len - needle.len) {
            if (std.mem.indexOf(u8, haystack[search_start..], needle)) |rel| {
                const at = search_start + rel;
                try hits.append(allocator, .{ .start = at, .len = needle.len });
                // Advance one byte past start to find overlapping hits too.
                search_start = at + 1;
            } else break;
        }
    } else {
        // Manual case-insensitive scan; the ASCII fast path covers our use.
        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) {
                try hits.append(allocator, .{ .start = i, .len = needle.len });
            }
        }
    }

    return hits.toOwnedSlice(allocator);
}

pub fn caseInsensitiveActive(case: Case, query: []const u8) bool {
    return switch (case) {
        .sensitive => false,
        .insensitive => true,
        .smart => for (query) |c| {
            if (std.ascii.isUpper(c)) break false;
        } else true,
    };
}

/// Heuristic: a NUL byte in the first 8 KiB ⇒ treat as binary and skip.
fn looksBinary(bytes: []const u8) bool {
    const window = bytes[0..@min(8 * 1024, bytes.len)];
    return std.mem.indexOfScalar(u8, window, 0) != null;
}

const FileMatch = struct {
    /// Owned: file path relative to walk root.
    path: []const u8,
    /// Owned: raw content (so we can hand back substrings cheaply).
    content: []u8,
    /// Owned: one entry per match.
    matches: []const LineMatch,
    /// Largest line number across `matches`, for column alignment.
    max_line: usize,
};

const LineMatch = struct {
    line: usize, // 1-based
    col: usize, // 1-based byte column within the line
    text_offset: usize, // byte offset into `content` where the line starts
    text_len: usize,
    hits: []const Hit, // borrowed: owned by `FileMatch.hits_pool`
};

const Aggregated = struct {
    /// Allocator that owns everything reachable from `files`.
    allocator: std.mem.Allocator,
    files: []FileMatch,
    total_matches: usize,

    fn deinit(self: *Aggregated) void {
        for (self.files) |f| {
            self.allocator.free(f.path);
            self.allocator.free(f.content);
            for (f.matches) |m| self.allocator.free(m.hits);
            self.allocator.free(f.matches);
        }
        self.allocator.free(self.files);
    }
};

/// Directories we skip by default — VCS metadata, build artifacts, vendored
/// dependencies. Each entry is matched as a substring `/<name>/` against the
/// padded relative path, so it boundary-anchors correctly.
const default_excludes = [_][]const u8{
    "/.git/",         "/.hg/",         "/.svn/",
    "/node_modules/", "/zig-out/",     "/zig-cache/",
    "/.zig-cache/",   "/zig-pkg/",     "/target/",
    "/build/",        "/dist/",        "/.venv/",
    "/venv/",         "/__pycache__/", "/.next/",
    "/.cache/",       "/vendor/",      "/.idea/",
    "/.vscode/",      "/coverage/",
};

fn isDefaultExcluded(path: []const u8) bool {
    // Pad so we match boundary-anchored substrings like "/.git/" even at
    // the start of a relative path.
    var buf: [512]u8 = undefined;
    if (path.len + 2 > buf.len) {
        // Fall back to raw indexOf if the path is unusually long.
        for (default_excludes) |x| {
            if (std.mem.indexOf(u8, path, x) != null) return true;
            // Also catch the case where the prefix is at offset 0.
            if (x.len > 1 and std.mem.startsWith(u8, path, x[1..])) return true;
        }
        return false;
    }
    buf[0] = '/';
    @memcpy(buf[1 .. 1 + path.len], path);
    buf[1 + path.len] = '/';
    const padded = buf[0 .. path.len + 2];
    for (default_excludes) |x| {
        if (std.mem.indexOf(u8, padded, x) != null) return true;
    }
    return false;
}

fn scanFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    rel_path: []const u8,
    query: []const u8,
    options: SearchOptions,
) !?FileMatch {
    var file = dir.openFile(io, rel_path, .{}) catch return null;
    defer file.close(io);

    const size = file.length(io) catch return null;
    if (size == 0 or size > options.max_file_size) return null;

    var content = allocator.alloc(u8, @intCast(size)) catch return null;
    errdefer allocator.free(content);
    const read_n = file.readPositionalAll(io, content, 0) catch {
        allocator.free(content);
        return null;
    };
    if (read_n < content.len) content = try allocator.realloc(content, read_n);

    if (looksBinary(content)) {
        allocator.free(content);
        return null;
    }

    const insensitive = caseInsensitiveActive(options.case, query);

    var matches: std.ArrayListUnmanaged(LineMatch) = .empty;
    errdefer {
        for (matches.items) |m| allocator.free(m.hits);
        matches.deinit(allocator);
    }

    var line_no: usize = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    var max_line: usize = 0;
    while (i <= content.len) : (i += 1) {
        const at_eol = (i == content.len) or content[i] == '\n';
        if (!at_eol) continue;

        line_no += 1;
        const line_end = i;
        var line_text = content[line_start..line_end];
        if (line_text.len > 0 and line_text[line_text.len - 1] == '\r') {
            line_text = line_text[0 .. line_text.len - 1];
        }

        const hits = try findAll(allocator, line_text, query, insensitive);
        if (hits.len == 0) {
            allocator.free(hits);
        } else {
            // If append fails, free hits before propagating so the per-file
            // errdefer (which walks already-appended matches) doesn't see
            // a half-published entry.
            errdefer allocator.free(hits);
            try matches.append(allocator, .{
                .line = line_no,
                .col = hits[0].start + 1,
                .text_offset = line_start,
                .text_len = line_text.len,
                .hits = hits,
            });
            max_line = line_no;
            if (options.max_matches_per_file) |cap| {
                if (matches.items.len >= cap) break;
            }
        }

        line_start = i + 1;
    }

    if (matches.items.len == 0) {
        allocator.free(content);
        return null;
    }

    const matches_owned = try matches.toOwnedSlice(allocator);
    errdefer {
        for (matches_owned) |m| allocator.free(m.hits);
        allocator.free(matches_owned);
    }
    const path_owned = try allocator.dupe(u8, rel_path);
    return FileMatch{
        .path = path_owned,
        .content = content,
        .matches = matches_owned,
        .max_line = max_line,
    };
}

fn lessThanFileMatch(_: void, a: FileMatch, b: FileMatch) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

fn collectMatches(
    allocator: std.mem.Allocator,
    io: std.Io,
    query: []const u8,
    options: SearchOptions,
) !Aggregated {
    var results: std.ArrayListUnmanaged(FileMatch) = .empty;
    errdefer {
        for (results.items) |f| {
            allocator.free(f.path);
            allocator.free(f.content);
            for (f.matches) |m| allocator.free(m.hits);
            allocator.free(f.matches);
        }
        results.deinit(allocator);
    }

    var total_matches: usize = 0;
    const cwd = std.Io.Dir.cwd();
    const walk_dir = if (options.base_dir) |base| base else ".";
    var dir = try cwd.openDir(io, walk_dir, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (isDefaultExcluded(entry.path)) continue;
        if (!options.matchesExtension(entry.path)) continue;
        if (!options.shouldIncludePath(entry.path)) continue;

        if (try scanFile(allocator, io, dir, entry.path, query, options)) |fm| {
            total_matches += fm.matches.len;
            try results.append(allocator, fm);
        }
    }

    const files = try results.toOwnedSlice(allocator);
    std.mem.sort(FileMatch, files, {}, lessThanFileMatch);

    return .{
        .allocator = allocator,
        .files = files,
        .total_matches = total_matches,
    };
}

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    query: []const u8,
    options: SearchOptions,
) !void {
    const start_ns = std.Io.Clock.awake.now(io).toNanoseconds();

    var aggregated = try collectMatches(allocator, io, query, options);
    defer aggregated.deinit();

    const elapsed_ns = std.Io.Clock.awake.now(io).toNanoseconds() - start_ns;
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) /
        @as(f64, @floatFromInt(std.time.ns_per_ms));

    const tty = std.Io.File.stdout().isTty(io) catch false;
    const use_color = options.color_override orelse tty;
    const pretty = options.pretty_override orelse tty;

    var out: format.Output = undefined;
    out.init(io, .{ .use_color = use_color, .compact = !pretty });
    defer out.flush() catch {};

    for (aggregated.files) |f| {
        try out.fileHeader(f.path);
        const width = if (f.max_line == 0) 1 else std.math.log10_int(f.max_line) + 1;
        for (f.matches) |m| {
            const line_text = f.content[m.text_offset .. m.text_offset + m.text_len];
            try out.matchLine(f.path, m.line, m.col, line_text, m.hits, width);
        }
    }

    try out.summary(aggregated.total_matches, aggregated.files.len, elapsed_ms);
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "findAll: multiple occurrences" {
    const a = std.testing.allocator;
    const hits = try findAll(a, "foo foo foo", "foo", false);
    defer a.free(hits);
    try std.testing.expectEqual(@as(usize, 3), hits.len);
    try std.testing.expectEqual(@as(usize, 0), hits[0].start);
    try std.testing.expectEqual(@as(usize, 4), hits[1].start);
    try std.testing.expectEqual(@as(usize, 8), hits[2].start);
}

test "findAll: overlapping hits" {
    const a = std.testing.allocator;
    const hits = try findAll(a, "aaaa", "aa", false);
    defer a.free(hits);
    try std.testing.expectEqual(@as(usize, 3), hits.len);
}

test "findAll: case-insensitive" {
    const a = std.testing.allocator;
    const hits = try findAll(a, "Foo BAR foo", "foo", true);
    defer a.free(hits);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
}

test "findAll: empty needle returns empty" {
    const a = std.testing.allocator;
    const hits = try findAll(a, "anything", "", false);
    defer a.free(hits);
    try std.testing.expectEqual(@as(usize, 0), hits.len);
}

test "caseInsensitiveActive: smart" {
    try std.testing.expect(caseInsensitiveActive(.smart, "foo"));
    try std.testing.expect(!caseInsensitiveActive(.smart, "Foo"));
    try std.testing.expect(caseInsensitiveActive(.insensitive, "Foo"));
    try std.testing.expect(!caseInsensitiveActive(.sensitive, "foo"));
}

test "looksBinary: NUL detected" {
    try std.testing.expect(looksBinary(&[_]u8{ 'a', 0, 'b' }));
    try std.testing.expect(!looksBinary("hello world"));
}

test "isDefaultExcluded" {
    try std.testing.expect(isDefaultExcluded(".git/HEAD"));
    try std.testing.expect(isDefaultExcluded("src/node_modules/foo/bar.js"));
    try std.testing.expect(isDefaultExcluded("zig-out/bin/stem"));
    try std.testing.expect(!isDefaultExcluded("src/main.zig"));
    try std.testing.expect(!isDefaultExcluded("README.md"));
}

test "SearchOptions.matchesExtension: dot and dotless ext forms" {
    const opts: SearchOptions = .{
        .paths = &.{},
        .extensions = &.{ ".zig", "py" },
        .excludes = &.{},
    };
    try std.testing.expect(opts.matchesExtension("main.zig"));
    try std.testing.expect(opts.matchesExtension("/a/b/main.zig"));
    try std.testing.expect(opts.matchesExtension("/a/b/main.PY"));
    try std.testing.expect(opts.matchesExtension("script.py"));
    try std.testing.expect(!opts.matchesExtension("script.pyc"));
    try std.testing.expect(!opts.matchesExtension("noext"));
    try std.testing.expect(!opts.matchesExtension(""));
}

test "SearchOptions.matchesExtension: empty filter matches all" {
    const opts: SearchOptions = .{
        .paths = &.{},
        .extensions = &.{},
        .excludes = &.{},
    };
    try std.testing.expect(opts.matchesExtension("main.zig"));
    try std.testing.expect(opts.matchesExtension("README"));
    try std.testing.expect(opts.matchesExtension(""));
}

test "SearchOptions.matchesExtension: extension as substring isn't a match" {
    const opts: SearchOptions = .{
        .paths = &.{},
        .extensions = &.{"js"},
        .excludes = &.{},
    };
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
    try std.testing.expect(opts.shouldIncludePath("src"));
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

test "collectMatches end-to-end: finds matches and cleans up" {
    const a = std.testing.allocator;
    // Run against this very file, search for a token that must exist.
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // The `findAll` symbol is unique in this file and any caller of it; we
    // search the repo root which works whether tests are invoked from the
    // crate root or a subdir thanks to the relative-path semantics.
    const opts: SearchOptions = .{
        .paths = &.{"src/tools"},
        .extensions = &.{"zig"},
        .excludes = &.{},
        .case = .sensitive,
        .max_matches_per_file = 16,
        .color_override = false,
    };
    var agg = try collectMatches(a, io, "findAll", opts);
    defer agg.deinit();
    // Must find at least one match (this file).
    try std.testing.expect(agg.total_matches > 0);
}
