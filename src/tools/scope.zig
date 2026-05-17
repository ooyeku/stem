//! `stem scope <file> <query>`: grep a single file with N lines of context.
//!
//! Output groups matches that share context; non-adjacent matches are
//! separated by a ` ⋯ ` divider. Match lines use the same colored
//! `line:col` prefix and inline-highlight as `find`.

const std = @import("std");
const search = @import("search.zig");
const format = @import("format.zig");

const Hit = format.Hit;

pub const ScopeOptions = struct {
    before: usize = 3,
    after: usize = 3,
    case: search.Case = .smart,
    color_override: ?bool = null,
    /// Largest file we'll grep through.
    max_file_size: usize = 100 * 1024 * 1024,
};

const LineMatch = struct {
    line: usize, // 1-based
    col: usize, // 1-based byte column
    hits: []Hit, // owned by `run`'s arena
};

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: []const u8,
    query: []const u8,
    options: ScopeOptions,
) !void {
    const tty = std.Io.File.stdout().isTty(io) catch false;
    const use_color = options.color_override orelse tty;

    var out: format.Output = undefined;
    // `scope` always renders in pretty mode: it exists to show context
    // around matches, which doesn't map cleanly to grep-style output.
    out.init(io, .{ .use_color = use_color, .compact = false });
    defer out.flush() catch {};

    const cwd = std.Io.Dir.cwd();
    const file = cwd.openFile(io, file_path, .{}) catch |err| {
        try out.errMsg("could not open '{s}': {s}", .{ file_path, @errorName(err) });
        return err;
    };
    defer file.close(io);

    const size = file.length(io) catch |err| {
        try out.errMsg("could not stat '{s}': {s}", .{ file_path, @errorName(err) });
        return err;
    };
    if (size > options.max_file_size) {
        try out.errMsg("'{s}' is larger than the {d} MiB limit", .{
            file_path,
            options.max_file_size / (1024 * 1024),
        });
        return;
    }

    const content = try allocator.alloc(u8, @intCast(size));
    defer allocator.free(content);
    const read_n = try file.readPositionalAll(io, content, 0);
    const body = content[0..read_n];

    // Binary-file guard: a NUL byte in the first 8 KiB is a near-certain
    // signal we're looking at non-text. Refuse rather than spew control
    // chars (and possibly the terminal-corrupting subset) at the user.
    {
        const probe = body[0..@min(8 * 1024, body.len)];
        if (std.mem.indexOfScalar(u8, probe, 0) != null) {
            try out.errMsg("'{s}' looks like a binary file (NUL byte in first 8 KiB).", .{file_path});
            return;
        }
    }

    // Index line boundaries once so we can slice random lines later.
    var line_starts: std.ArrayListUnmanaged(usize) = .empty;
    defer line_starts.deinit(allocator);
    try line_starts.append(allocator, 0);
    var k: usize = 0;
    while (k < body.len) : (k += 1) {
        if (body[k] == '\n') try line_starts.append(allocator, k + 1);
    }
    const total_lines = line_starts.items.len;

    const insensitive = search.caseInsensitiveActive(options.case, query);

    var matches: std.ArrayListUnmanaged(LineMatch) = .empty;
    defer {
        for (matches.items) |m| allocator.free(m.hits);
        matches.deinit(allocator);
    }

    for (line_starts.items, 0..) |start, idx| {
        const end = if (idx + 1 < line_starts.items.len)
            // Step back over the '\n' so we don't include it in the slice.
            line_starts.items[idx + 1] - 1
        else
            body.len;
        var line = body[start..end];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];

        const hits = try search.findAll(allocator, line, query, insensitive);
        if (hits.len == 0) {
            allocator.free(hits);
            continue;
        }
        errdefer allocator.free(hits);
        try matches.append(allocator, .{
            .line = idx + 1,
            .col = hits[0].start + 1,
            .hits = hits,
        });
    }

    if (matches.items.len == 0) {
        try out.info("No matches for '{s}' in {s}", .{ query, file_path });
        return;
    }

    try out.fileHeader(file_path);
    const width = std.math.log10_int(total_lines) + 1;

    var last_printed: ?usize = null;
    for (matches.items) |m| {
        const match_idx = m.line - 1;
        const context_start = if (match_idx >= options.before)
            match_idx - options.before
        else
            0;
        const context_end = @min(match_idx + options.after + 1, total_lines);

        // Decide whether to start fresh or continue from the previous block.
        var start_from = context_start;
        if (last_printed) |prev| {
            if (context_start <= prev + 1) {
                start_from = prev + 1;
            } else {
                try out.gap();
                start_from = context_start;
            }
        }

        var j = start_from;
        while (j < context_end) : (j += 1) {
            const line_text = lineSlice(body, line_starts.items, j);
            if (j == match_idx) {
                try out.matchLine(file_path, j + 1, m.col, line_text, m.hits, width);
            } else {
                try out.contextLine(j + 1, line_text, width);
            }
        }

        last_printed = context_end - 1;
    }

    try out.summary(matches.items.len, 0, 0.0);
}

fn lineSlice(body: []const u8, line_starts: []const usize, idx: usize) []const u8 {
    const start = line_starts[idx];
    const end = if (idx + 1 < line_starts.len) line_starts[idx + 1] - 1 else body.len;
    var s = body[start..end];
    if (s.len > 0 and s[s.len - 1] == '\r') s = s[0 .. s.len - 1];
    return s;
}
