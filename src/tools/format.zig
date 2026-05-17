//! Output formatter for the search-style CLI tools (`find`, `vfind`,
//! `scope`).
//!
//! Wraps stdout in a streaming `std.Io.Writer` with a stack-resident buffer
//! so a long match list doesn't fan out into one write() per line. The
//! caller drives it imperatively (`header(...)`, `match(...)`, `summary(...)`)
//! and the formatter handles TTY detection, color enable/disable, padding,
//! and the highlight inside the match text.

const std = @import("std");
const builtin = @import("builtin");

pub const Color = struct {
    reset: []const u8 = "",
    bold: []const u8 = "",
    dim: []const u8 = "",
    italic: []const u8 = "",
    fg_red: []const u8 = "",
    fg_green: []const u8 = "",
    fg_yellow: []const u8 = "",
    fg_blue: []const u8 = "",
    fg_magenta: []const u8 = "",
    fg_cyan: []const u8 = "",
    fg_gray: []const u8 = "",
    bg_match: []const u8 = "",
};

pub const ansi_color: Color = .{
    .reset = "\x1b[0m",
    .bold = "\x1b[1m",
    .dim = "\x1b[2m",
    .italic = "\x1b[3m",
    .fg_red = "\x1b[31m",
    .fg_green = "\x1b[32m",
    .fg_yellow = "\x1b[33m",
    .fg_blue = "\x1b[34m",
    .fg_magenta = "\x1b[35m",
    .fg_cyan = "\x1b[36m",
    .fg_gray = "\x1b[90m",
    // 256-color background: 235 = very dark gray; works on most terminals.
    .bg_match = "\x1b[48;5;236m\x1b[1;33m",
};
pub const no_color: Color = .{};

/// Decide whether to emit ANSI codes. Honours NO_COLOR (the standard
/// opt-out) and falls back to a TTY check. CLI flags can override.
pub fn decideColor(io: std.Io, file: std.Io.File, environ: std.process.Environ) bool {
    var env_iter = environ.iterator(.{});
    while (env_iter.next()) |entry| {
        if (std.mem.eql(u8, entry.key, "NO_COLOR")) {
            if (entry.value.len > 0) return false;
        }
    }
    return file.isTty(io) catch false;
}

pub const Output = struct {
    file_writer: std.Io.File.Writer,
    buffer: [16 * 1024]u8 = undefined,
    color: Color,
    /// When true, emit each match as `path:line:col:text` on its own line
    /// (grep-compatible). When false, emit the grouped TUI-style layout.
    compact: bool = false,

    /// Two-step init so `buffer`'s address (which the writer stores) is
    /// stable for the writer's lifetime. Caller does:
    ///     var out: format.Output = undefined;
    ///     out.init(io, .{ .use_color = true });
    pub const InitOptions = struct {
        use_color: bool,
        compact: bool,
    };

    pub fn init(self: *Output, io: std.Io, opts: InitOptions) void {
        self.color = if (opts.use_color) ansi_color else no_color;
        self.compact = opts.compact;
        self.file_writer = std.Io.File.stdout().writerStreaming(io, &self.buffer);
    }

    fn w(self: *Output) *std.Io.Writer {
        return &self.file_writer.interface;
    }

    pub fn flush(self: *Output) !void {
        try self.w().flush();
    }

    pub fn raw(self: *Output, bytes: []const u8) !void {
        try self.w().writeAll(bytes);
    }

    pub fn print(self: *Output, comptime fmt: []const u8, args: anytype) !void {
        try self.w().print(fmt, args);
    }

    /// File header. Pretty mode prints the path in bold cyan with a leading
    /// blank line; compact mode emits nothing (the path is repeated on
    /// each match line instead, which is what `grep`/`rg` do when piping).
    pub fn fileHeader(self: *Output, path: []const u8) !void {
        if (self.compact) return;
        const c = &self.color;
        try self.w().print("\n{s}{s}{s}{s}\n", .{ c.bold, c.fg_cyan, path, c.reset });
    }

    /// One match line with highlighted hits.
    ///
    /// In pretty mode `line_num_width` is used to right-align line numbers
    /// across the file's matches. In compact mode it's ignored and the line
    /// is emitted as `path:line:col:text` (grep-compatible).
    pub fn matchLine(
        self: *Output,
        path: []const u8,
        line: usize,
        col: usize,
        text: []const u8,
        hits: []const Hit,
        line_num_width: usize,
    ) !void {
        const c = &self.color;
        if (self.compact) {
            try self.w().print("{s}{s}{s}:{s}{d}{s}:{s}{d}{s}:", .{
                c.fg_cyan,   path, c.reset,
                c.fg_green,  line, c.reset,
                c.fg_yellow, col,  c.reset,
            });
            try writeHighlighted(self.w(), text, hits, c);
            try self.w().writeAll("\n");
            return;
        }
        // Pretty: line:col prefix, right-aligned, in dim green.
        try self.w().print("{s}", .{c.fg_green});
        try writePaddedNum(self.w(), line, line_num_width);
        try self.w().print(":{d:<3}{s}  ", .{ col, c.reset });
        try writeHighlighted(self.w(), text, hits, c);
        try self.w().writeAll("\n");
    }

    /// Plain context line for `scope`.
    pub fn contextLine(
        self: *Output,
        line: usize,
        text: []const u8,
        line_num_width: usize,
    ) !void {
        const c = &self.color;
        try self.w().print("{s}", .{c.fg_gray});
        try writePaddedNum(self.w(), line, line_num_width);
        // Six spaces matches the width of `:{col:<3}  ` used by matchLine
        // so context lines column-align with match lines.
        try self.w().print("{s}      {s}{s}{s}\n", .{ c.reset, c.fg_gray, text, c.reset });
    }

    pub fn gap(self: *Output) !void {
        const c = &self.color;
        try self.w().print("{s}  ⋯{s}\n", .{ c.fg_gray, c.reset });
    }

    pub fn summary(
        self: *Output,
        matches: usize,
        files: usize,
        duration_ms: f64,
    ) !void {
        // Compact mode is meant for piping into other tools — a trailing
        // summary line would corrupt the data stream.
        if (self.compact) return;
        const c = &self.color;
        if (matches == 0) {
            try self.w().print("\n{s}No matches.{s} ({d:.2}ms)\n", .{ c.dim, c.reset, duration_ms });
        } else if (files > 0) {
            try self.w().print(
                "\n{s}{d}{s} match{s} in {s}{d}{s} file{s} {s}({d:.2}ms){s}\n",
                .{
                    c.bold,                         matches,                     c.reset,
                    if (matches == 1) "" else "es", c.bold,                      files,
                    c.reset,                        if (files == 1) "" else "s", c.dim,
                    duration_ms,                    c.reset,
                },
            );
        } else {
            try self.w().print(
                "\n{s}{d}{s} match{s} {s}({d:.2}ms){s}\n",
                .{
                    c.bold,                         matches, c.reset,
                    if (matches == 1) "" else "es", c.dim,   duration_ms,
                    c.reset,
                },
            );
        }
    }

    pub fn errMsg(self: *Output, comptime fmt: []const u8, args: anytype) !void {
        const c = &self.color;
        try self.w().print("{s}error:{s} ", .{ c.fg_red, c.reset });
        try self.w().print(fmt, args);
        try self.w().writeAll("\n");
    }

    pub fn info(self: *Output, comptime fmt: []const u8, args: anytype) !void {
        const c = &self.color;
        try self.w().print("{s}", .{c.fg_gray});
        try self.w().print(fmt, args);
        try self.w().print("{s}\n", .{c.reset});
    }
};

/// A `Hit` records the byte span of one query occurrence within a line so
/// the formatter can highlight every instance, not just the first.
pub const Hit = struct {
    start: usize,
    len: usize,
};

fn writePaddedNum(w: *std.Io.Writer, n: usize, width: usize) !void {
    var buf: [32]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{d}", .{n});
    if (s.len < width) {
        const pad_count = width - s.len;
        var pad_buf: [32]u8 = undefined;
        const cap = @min(pad_count, pad_buf.len);
        @memset(pad_buf[0..cap], ' ');
        try w.writeAll(pad_buf[0..cap]);
    }
    try w.writeAll(s);
}

fn writeHighlighted(w: *std.Io.Writer, text: []const u8, hits: []const Hit, c: *const Color) !void {
    // Strip a trailing \r (Windows line endings) so it doesn't render as a
    // literal control char in the terminal.
    var trimmed = text;
    if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '\r') trimmed = trimmed[0 .. trimmed.len - 1];

    var cursor: usize = 0;
    for (hits) |h| {
        if (h.start >= trimmed.len) break;
        const end = @min(h.start + h.len, trimmed.len);
        if (h.start > cursor) try w.writeAll(trimmed[cursor..h.start]);
        try w.writeAll(c.bg_match);
        try w.writeAll(trimmed[h.start..end]);
        try w.writeAll(c.reset);
        cursor = end;
    }
    if (cursor < trimmed.len) try w.writeAll(trimmed[cursor..]);
}

test "writePaddedNum: pads with spaces" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writePaddedNum(&w, 7, 4);
    try std.testing.expectEqualStrings("   7", w.buffered());
}

test "writePaddedNum: no-pad when wide enough" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writePaddedNum(&w, 1234, 2);
    try std.testing.expectEqualStrings("1234", w.buffered());
}

test "writeHighlighted: no hits prints plain text" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeHighlighted(&w, "hello world", &.{}, &no_color);
    try std.testing.expectEqualStrings("hello world", w.buffered());
}

test "writeHighlighted: hits round-trip with no-color" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const hits = [_]Hit{ .{ .start = 0, .len = 5 }, .{ .start = 6, .len = 5 } };
    try writeHighlighted(&w, "hello world", &hits, &no_color);
    // Without color codes, output is identical to the input.
    try std.testing.expectEqualStrings("hello world", w.buffered());
}

test "writeHighlighted: trims trailing \\r" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeHighlighted(&w, "abc\r", &.{}, &no_color);
    try std.testing.expectEqualStrings("abc", w.buffered());
}

test "writeHighlighted: out-of-range hit is skipped" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const hits = [_]Hit{.{ .start = 100, .len = 5 }};
    try writeHighlighted(&w, "abc", &hits, &no_color);
    try std.testing.expectEqualStrings("abc", w.buffered());
}
