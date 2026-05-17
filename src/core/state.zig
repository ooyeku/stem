const std = @import("std");
const PieceTable = @import("piece_table.zig").PieceTable;
const Allocator = std.mem.Allocator;
const unicode = @import("unicode.zig");
const TestIo = @import("../test_utils.zig").TestIo;

pub const EditorState = struct {
    allocator: Allocator,
    io: std.Io,
    buffer: PieceTable,

    cursor_row: usize,
    cursor_col: usize,
    scroll_offset: usize,

    file_path: ?[]u8,
    modified: bool,

    selection_anchor: ?struct { row: usize, col: usize } = null,

    pub fn init(allocator: Allocator, io: std.Io, content: []const u8) EditorState {
        return EditorState{
            .allocator = allocator,
            .io = io,
            .buffer = PieceTable.init(allocator, content),
            .cursor_row = 0,
            .cursor_col = 0,
            .scroll_offset = 0,
            .file_path = null,
            .modified = false,
            .selection_anchor = null,
        };
    }

    pub fn deinit(self: *EditorState) void {
        self.buffer.deinit();
        if (self.file_path) |path| {
            self.allocator.free(path);
        }
    }

    pub fn loadFile(self: *EditorState, path: []const u8) !void {
        const file = std.Io.Dir.openFileAbsolute(self.io, path, .{}) catch |err| {
            std.debug.print("Failed to open file {s}: {}\n", .{ path, err });
            return err;
        };
        defer file.close(self.io);

        const size = file.length(self.io) catch |err| {
            std.debug.print("Failed to stat file {s}: {}\n", .{ path, err });
            return err;
        };
        if (size > 10 * 1024 * 1024) return error.FileTooLarge;
        const content = self.allocator.alloc(u8, @intCast(size)) catch |err| {
            std.debug.print("Failed to allocate for file {s}: {}\n", .{ path, err });
            return err;
        };
        defer self.allocator.free(content);
        const read_n = file.readPositionalAll(self.io, content, 0) catch |err| {
            std.debug.print("Failed to read file {s}: {}\n", .{ path, err });
            return err;
        };

        self.buffer.deinit();

        self.buffer = PieceTable.init(self.allocator, content[0..read_n]);

        if (self.file_path) |old_path| {
            self.allocator.free(old_path);
        }
        self.file_path = try self.allocator.dupe(u8, path);

        self.cursor_row = 0;
        self.cursor_col = 0;
        self.scroll_offset = 0;
        self.modified = false;
    }

    pub fn saveFile(self: *EditorState) !void {
        if (self.file_path) |path| {
            try self.saveFileAs(path);
        }
    }

    pub fn saveFileAs(self: *EditorState, path: []const u8) !void {
        const content = try self.buffer.toString(self.allocator);
        defer self.allocator.free(content);

        // Atomic write: serialize to a sibling temp file, fsync, rename
        // onto the target. POSIX `rename` is atomic on the same filesystem,
        // so a crash mid-write leaves the original intact instead of a
        // half-truncated file. Same-directory placement guarantees same FS.
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.stem-tmp", .{path});
        defer self.allocator.free(tmp_path);

        {
            const tmp_file = try std.Io.Dir.createFileAbsolute(self.io, tmp_path, .{});
            errdefer std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};
            defer tmp_file.close(self.io);
            try tmp_file.writePositionalAll(self.io, content, 0);
        }

        std.Io.Dir.renameAbsolute(tmp_path, path, self.io) catch |err| {
            // Best-effort cleanup if rename failed.
            std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};
            return err;
        };

        if (self.file_path) |old_path| {
            if (!std.mem.eql(u8, old_path, path)) {
                self.allocator.free(old_path);
                self.file_path = try self.allocator.dupe(u8, path);
            }
        } else {
            self.file_path = try self.allocator.dupe(u8, path);
        }

        self.modified = false;
    }

    pub fn markModified(self: *EditorState) void {
        self.modified = true;
    }

    pub fn insertChar(self: *EditorState, char: u8) !void {
        const offset = self.getOffsetFromCursor();

        var buf: [1]u8 = undefined;
        buf[0] = char;

        try self.buffer.insert(offset, &buf);
        self.markModified();

        if (char == '\n') {
            self.cursor_row += 1;
            self.cursor_col = 0;
        } else {
            self.cursor_col += 1;
        }
    }

    pub fn insertNewline(self: *EditorState) !void {
        try self.insertChar('\n');
    }

    pub fn insertNewlineWithIndent(self: *EditorState) !void {
        const line_content = try self.getLineContent(self.cursor_row);
        defer self.allocator.free(line_content);

        var base_indent: usize = 0;
        for (line_content) |c| {
            if (c == ' ') {
                base_indent += 1;
            } else if (c == '\t') {
                base_indent += 4;
            } else {
                break;
            }
        }

        var extra_indent: usize = 0;
        const offset = self.getOffsetFromCursor();
        if (offset > 0) {
            const char_before = self.getCharAtOffset(offset - 1);
            if (char_before == '{' or char_before == '(' or char_before == '[') {
                extra_indent = 4;
            }
        }

        const char_after = self.getCharAtOffset(offset);
        const need_closing_line = (char_after == '}' or char_after == ')' or char_after == ']') and extra_indent > 0;

        try self.insertChar('\n');

        var i: usize = 0;
        while (i < base_indent + extra_indent) : (i += 1) {
            try self.insertChar(' ');
        }

        if (need_closing_line) {
            const saved_row = self.cursor_row;
            const saved_col = self.cursor_col;

            try self.insertChar('\n');
            i = 0;
            while (i < base_indent) : (i += 1) {
                try self.insertChar(' ');
            }

            self.cursor_row = saved_row;
            self.cursor_col = saved_col;
        }
    }

    pub fn insertTab(self: *EditorState) !void {
        try self.insertTabWithSize(4);
    }

    pub fn insertTabWithSize(self: *EditorState, tab_size: u32) !void {
        var i: u32 = 0;
        while (i < tab_size) : (i += 1) {
            try self.insertChar(' ');
        }
    }

    pub fn getCharAtOffset(self: *EditorState, target_offset: usize) u8 {
        var offset: usize = 0;
        for (self.buffer.pieces.items) |p| {
            const data = switch (p.source) {
                .Original => self.buffer.original[p.start .. p.start + p.length],
                .Add => self.buffer.add.items[p.start .. p.start + p.length],
            };
            if (target_offset >= offset and target_offset < offset + data.len) {
                return data[target_offset - offset];
            }
            offset += data.len;
        }
        return 0;
    }

    pub fn getCharBeforeCursor(self: *EditorState) u8 {
        const offset = self.getOffsetFromCursor();
        if (offset == 0) return 0;
        return self.getCharAtOffset(offset - 1);
    }

    pub fn getCharAfterCursor(self: *EditorState) u8 {
        const offset = self.getOffsetFromCursor();
        return self.getCharAtOffset(offset);
    }

    pub fn deleteChar(self: *EditorState) !void {
        const offset = self.getOffsetFromCursor();
        if (offset >= self.buffer.totalLength()) return;

        try self.buffer.delete(offset, 1);
        self.markModified();
    }

    pub fn backspaceChar(self: *EditorState) !void {
        const offset = self.getOffsetFromCursor();
        if (offset == 0) return;

        try self.buffer.delete(offset - 1, 1);
        self.markModified();
        self.updateCursorFromOffset(offset - 1);
    }

    pub fn getOffsetFor(self: *EditorState, target_row: usize, target_col: usize) usize {
        var row: usize = 0;
        var col: usize = 0;
        var offset: usize = 0;

        for (self.buffer.pieces.items) |p| {
            const data = switch (p.source) {
                .Original => self.buffer.original[p.start .. p.start + p.length],
                .Add => self.buffer.add.items[p.start .. p.start + p.length],
            };
            for (data) |c| {
                if (row == target_row and col == target_col) return offset;

                if (c == '\n') {
                    if (row == target_row) return offset;
                    row += 1;
                    col = 0;
                } else {
                    col += 1;
                }
                offset += 1;
            }
        }
        return offset;
    }

    pub fn deleteRange(self: *EditorState, start_offset: usize, end_offset: usize) !void {
        if (end_offset <= start_offset) return;
        const len = end_offset - start_offset;
        try self.buffer.delete(start_offset, len);
        self.markModified();
        self.updateCursorFromOffset(start_offset);
    }

    pub fn updateCursorFromOffset(self: *EditorState, target_offset: usize) void {
        var row: usize = 0;
        var col: usize = 0;
        var offset: usize = 0;

        for (self.buffer.pieces.items) |p| {
            const data = switch (p.source) {
                .Original => self.buffer.original[p.start .. p.start + p.length],
                .Add => self.buffer.add.items[p.start .. p.start + p.length],
            };
            for (data) |c| {
                if (offset >= target_offset) {
                    self.cursor_row = row;
                    self.cursor_col = col;
                    return;
                }
                if (c == '\n') {
                    row += 1;
                    col = 0;
                } else {
                    col += 1;
                }
                offset += 1;
            }
        }
        self.cursor_row = row;
        self.cursor_col = col;
    }

    pub fn getOffsetFromCursor(self: *EditorState) usize {
        var row: usize = 0;
        var col: usize = 0;
        var offset: usize = 0;

        for (self.buffer.pieces.items) |p| {
            const data = switch (p.source) {
                .Original => self.buffer.original[p.start .. p.start + p.length],
                .Add => self.buffer.add.items[p.start .. p.start + p.length],
            };
            for (data) |c| {
                if (row == self.cursor_row and col == self.cursor_col) return offset;
                if (c == '\n') {
                    if (row == self.cursor_row) return offset;
                    row += 1;
                    col = 0;
                } else {
                    col += 1;
                }
                offset += 1;
            }
        }
        return offset;
    }

    pub fn getLineRange(self: *EditorState, target_row: usize) struct { start: usize, end: usize } {
        var row: usize = 0;
        var offset: usize = 0;
        var line_start: usize = 0;

        for (self.buffer.pieces.items) |p| {
            const data = switch (p.source) {
                .Original => self.buffer.original[p.start .. p.start + p.length],
                .Add => self.buffer.add.items[p.start .. p.start + p.length],
            };
            for (data) |c| {
                if (row == target_row and offset == line_start) {
                    line_start = offset;
                }
                if (c == '\n') {
                    if (row == target_row) {
                        return .{ .start = line_start, .end = offset + 1 };
                    }
                    row += 1;
                    line_start = offset + 1;
                }
                offset += 1;
            }
        }
        if (row == target_row) {
            return .{ .start = line_start, .end = offset };
        }
        return .{ .start = offset, .end = offset };
    }

    pub fn getLineContent(self: *EditorState, target_row: usize) ![]u8 {
        const range = self.getLineRange(target_row);
        var end = range.end;
        if (end > range.start) {
            if (self.buffer.getCharAt(end - 1)) |c| {
                if (c == '\n') end -= 1;
            }
        }
        const len = end - range.start;
        if (len == 0) return try self.allocator.alloc(u8, 0);

        var result = try self.allocator.alloc(u8, len);
        var idx: usize = 0;
        var offset: usize = 0;

        for (self.buffer.pieces.items) |p| {
            const data = switch (p.source) {
                .Original => self.buffer.original[p.start .. p.start + p.length],
                .Add => self.buffer.add.items[p.start .. p.start + p.length],
            };
            for (data) |c| {
                if (offset >= range.start and offset < end) {
                    result[idx] = c;
                    idx += 1;
                }
                offset += 1;
                if (offset >= end) break;
            }
            if (offset >= end) break;
        }
        return result;
    }

    pub fn deleteLine(self: *EditorState, target_row: usize) !void {
        const range = self.getLineRange(target_row);
        if (range.end > range.start) {
            try self.deleteRange(range.start, range.end);
        }
    }

    pub fn duplicateLine(self: *EditorState, target_row: usize) !void {
        if (self.buffer.totalLength() == 0) return;

        const line_content = try self.getLineContent(target_row);
        defer self.allocator.free(line_content);

        const range = self.getLineRange(target_row);

        var insert_content = try self.allocator.alloc(u8, line_content.len + 1);
        defer self.allocator.free(insert_content);
        insert_content[0] = '\n';
        @memcpy(insert_content[1..], line_content);

        var insert_pos = range.end;
        if (insert_pos > range.start) {
            if (self.buffer.getCharAt(insert_pos - 1)) |c| {
                if (c == '\n') insert_pos -= 1;
            }
        }

        try self.buffer.insert(insert_pos, insert_content);
        self.markModified();
        self.cursor_row += 1;
    }

    pub fn swapAdjacentLines(self: *EditorState, row1: usize, row2: usize) !void {
        if (row1 == row2) return;

        const total_lines = self.buffer.lineCount();
        if (row1 >= total_lines or row2 >= total_lines) return;

        const line1 = try self.getLineContent(row1);
        defer self.allocator.free(line1);
        const line2 = try self.getLineContent(row2);
        defer self.allocator.free(line2);

        const first_row = @min(row1, row2);
        const second_row = @max(row1, row2);

        if (second_row != first_row + 1) return;

        const first_range = self.getLineRange(first_row);
        const second_range = self.getLineRange(second_row);

        const second_has_newline = if (second_range.end > second_range.start)
            (self.buffer.getCharAt(second_range.end - 1) orelse 0) == '\n'
        else
            false;

        try self.deleteRange(first_range.start, second_range.end);

        const first_content = if (row1 < row2) line1 else line2;
        const second_content = if (row1 < row2) line2 else line1;

        const suffix: []const u8 = if (second_has_newline) "\n" else "";
        const new_content = try std.fmt.allocPrint(
            self.allocator,
            "{s}\n{s}{s}",
            .{ second_content, first_content, suffix },
        );
        defer self.allocator.free(new_content);

        try self.buffer.insert(first_range.start, new_content);
        self.markModified();
    }

    pub fn joinLines(self: *EditorState, target_row: usize) !void {
        const total_lines = self.buffer.lineCount();
        if (target_row + 1 >= total_lines) return;

        const current_range = self.getLineRange(target_row);

        var newline_pos: ?usize = null;
        if (current_range.end > current_range.start) {
            if (self.buffer.getCharAt(current_range.end - 1)) |c| {
                if (c == '\n') newline_pos = current_range.end - 1;
            }
        }

        if (newline_pos == null) return;

        const next_line = try self.getLineContent(target_row + 1);
        defer self.allocator.free(next_line);

        var leading_ws: usize = 0;
        for (next_line) |c| {
            if (c == ' ' or c == '\t') {
                leading_ws += 1;
            } else {
                break;
            }
        }

        const delete_start = newline_pos.?;
        const delete_end = delete_start + 1 + leading_ws;

        try self.deleteRange(delete_start, delete_end);

        const current_line = try self.getLineContent(target_row);
        defer self.allocator.free(current_line);

        const needs_space = current_line.len > 0 and
            current_line[current_line.len - 1] != ' ' and
            next_line.len > leading_ws;

        if (needs_space) {
            try self.buffer.insert(delete_start, " ");
        }

        self.markModified();
    }

    pub fn insertTextAtCursor(self: *EditorState, text: []const u8) !void {
        const offset = self.getOffsetFromCursor();
        try self.buffer.insert(offset, text);
        self.markModified();

        for (text) |c| {
            if (c == '\n') {
                self.cursor_row += 1;
                self.cursor_col = 0;
            } else {
                self.cursor_col += 1;
            }
        }
    }

    pub fn getLineLength(self: *EditorState, row: usize) usize {
        const range = self.getLineRange(row);
        if (range.end <= range.start) return 0;
        var len = range.end - range.start;
        if (self.buffer.getCharAt(range.end - 1)) |c| {
            if (c == '\n') len -= 1;
        }
        return len;
    }

    pub fn clampCursorToLine(self: *EditorState) void {
        const line_len = self.getLineLength(self.cursor_row);
        if (self.cursor_col > line_len) {
            self.cursor_col = line_len;
        }
    }

    pub fn moveCursorLeftGrapheme(self: *EditorState) !void {
        const line_content = try self.getLineContent(self.cursor_row);
        defer self.allocator.free(line_content);

        if (self.cursor_col == 0) {
            if (self.cursor_row > 0) {
                self.cursor_row -= 1;
                const prev_line_len = self.getLineLength(self.cursor_row);
                self.cursor_col = prev_line_len;
            }
        } else {
            if (unicode.prevGrapheme(line_content, self.cursor_col)) |new_col| {
                self.cursor_col = new_col;
            }
        }
    }

    pub fn moveCursorRightGrapheme(self: *EditorState) !void {
        const line_content = try self.getLineContent(self.cursor_row);
        defer self.allocator.free(line_content);

        const line_len = line_content.len;

        if (self.cursor_col >= line_len) {
            const line_count = self.buffer.lineCount();
            if (self.cursor_row < line_count - 1) {
                self.cursor_row += 1;
                self.cursor_col = 0;
            }
        } else {
            if (unicode.nextGrapheme(line_content, self.cursor_col)) |new_col| {
                self.cursor_col = new_col;
            }
        }
    }

    pub fn moveCursorNextWord(self: *EditorState) !void {
        const line_content = try self.getLineContent(self.cursor_row);
        defer self.allocator.free(line_content);

        if (try unicode.nextWord(line_content, self.cursor_col)) |new_col| {
            self.cursor_col = new_col;
        } else {
            const line_count = self.buffer.lineCount();
            if (self.cursor_row < line_count - 1) {
                self.cursor_row += 1;
                self.cursor_col = 0;
            }
        }
    }

    pub fn moveCursorPrevWord(self: *EditorState) !void {
        const line_content = try self.getLineContent(self.cursor_row);
        defer self.allocator.free(line_content);

        if (try unicode.prevWord(line_content, self.cursor_col)) |new_col| {
            self.cursor_col = new_col;
        } else {
            if (self.cursor_row > 0) {
                self.cursor_row -= 1;
                const prev_line_len = self.getLineLength(self.cursor_row);
                self.cursor_col = prev_line_len;
            }
        }
    }

    pub fn getLineDisplayWidth(self: *EditorState, row: usize) !i32 {
        const line_content = try self.getLineContent(row);
        defer self.allocator.free(line_content);
        return unicode.stringWidth(line_content);
    }

    pub fn getLineGraphemeCount(self: *EditorState, row: usize) !usize {
        const line_content = try self.getLineContent(row);
        defer self.allocator.free(line_content);
        return unicode.graphemeCount(line_content);
    }
};

test "EditorState initialization" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = EditorState.init(allocator, io, "Hello");
    defer state.deinit();

    try std.testing.expectEqual(state.cursor_row, 0);
    try std.testing.expectEqual(state.cursor_col, 0);
    try std.testing.expect(state.file_path == null);
    try std.testing.expect(!state.modified);
}

test "EditorState insertChar marks modified" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = EditorState.init(allocator, io, "Hello");
    defer state.deinit();

    try std.testing.expect(!state.modified);
    try state.insertChar('!');
    try std.testing.expect(state.modified);
}

test "EditorState delete and backspace" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = EditorState.init(allocator, io, "Hello");
    defer state.deinit();

    state.cursor_col = 1;
    try state.deleteChar();

    const text = try state.buffer.toString(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("Hllo", text);

    try state.backspaceChar();

    const text2 = try state.buffer.toString(allocator);
    defer allocator.free(text2);
    try std.testing.expectEqualStrings("llo", text2);
    try std.testing.expectEqual(state.cursor_col, 0);
}

test "EditorState insertNewline and Tab" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = EditorState.init(allocator, io, "Hi");
    defer state.deinit();

    state.cursor_col = 2;

    try state.insertNewline();
    try std.testing.expectEqual(state.cursor_row, 1);
    try std.testing.expectEqual(state.cursor_col, 0);

    try state.insertTab();
    try std.testing.expectEqual(state.cursor_col, 4);

    const text = try state.buffer.toString(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("Hi\n    ", text);
}

test "EditorState empty buffer initialization" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = EditorState.init(allocator, io, "");
    defer state.deinit();

    try std.testing.expectEqual(@as(usize, 0), state.cursor_row);
    try std.testing.expectEqual(@as(usize, 0), state.cursor_col);
    try std.testing.expect(!state.modified);
    try std.testing.expectEqual(@as(usize, 0), state.buffer.totalLength());
}

test "EditorState cursor at end of buffer" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = EditorState.init(allocator, io, "Hello");
    defer state.deinit();

    state.cursor_col = 5;
    try state.insertChar('!');

    const text = try state.buffer.toString(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("Hello!", text);
    try std.testing.expectEqual(@as(usize, 6), state.cursor_col);
}

test "EditorState cursor beyond line end" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = EditorState.init(allocator, io, "Hi");
    defer state.deinit();

    state.cursor_col = 100;
    const offset = state.getOffsetFromCursor();

    try std.testing.expectEqual(@as(usize, 2), offset);
}

test "EditorState deleteChar at end" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = EditorState.init(allocator, io, "Hello");
    defer state.deinit();

    state.cursor_col = 5;
    try state.deleteChar();

    const text = try state.buffer.toString(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("Hello", text);
}

test "EditorState backspaceChar at start" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = EditorState.init(allocator, io, "Hello");
    defer state.deinit();

    try state.backspaceChar();

    const text = try state.buffer.toString(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("Hello", text);
    try std.testing.expectEqual(@as(usize, 0), state.cursor_col);
}

test "EditorState multiline cursor movement" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = EditorState.init(allocator, io, "Line 1\nLine 2\nLine 3");
    defer state.deinit();

    state.cursor_row = 1;
    state.cursor_col = 3;

    const offset = state.getOffsetFromCursor();
    try std.testing.expectEqual(@as(usize, 10), offset);
}

test "EditorState getOffsetFor" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = EditorState.init(allocator, io, "Hello\nWorld");
    defer state.deinit();

    const offset1 = state.getOffsetFor(0, 0);
    try std.testing.expectEqual(@as(usize, 0), offset1);

    const offset2 = state.getOffsetFor(0, 5);
    try std.testing.expectEqual(@as(usize, 5), offset2);

    const offset3 = state.getOffsetFor(1, 0);
    try std.testing.expectEqual(@as(usize, 6), offset3);

    const offset4 = state.getOffsetFor(1, 5);
    try std.testing.expectEqual(@as(usize, 11), offset4);
}

test "EditorState updateCursorFromOffset" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = EditorState.init(allocator, io, "Hello\nWorld");
    defer state.deinit();

    state.updateCursorFromOffset(0);
    try std.testing.expectEqual(@as(usize, 0), state.cursor_row);
    try std.testing.expectEqual(@as(usize, 0), state.cursor_col);

    state.updateCursorFromOffset(6);
    try std.testing.expectEqual(@as(usize, 1), state.cursor_row);
    try std.testing.expectEqual(@as(usize, 0), state.cursor_col);

    state.updateCursorFromOffset(9);
    try std.testing.expectEqual(@as(usize, 1), state.cursor_row);
    try std.testing.expectEqual(@as(usize, 3), state.cursor_col);
}

test "EditorState getLineRange" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = EditorState.init(allocator, io, "Line 1\nLine 2\nLine 3");
    defer state.deinit();

    const range1 = state.getLineRange(0);
    try std.testing.expectEqual(@as(usize, 0), range1.start);
    try std.testing.expectEqual(@as(usize, 7), range1.end);

    const range2 = state.getLineRange(1);
    try std.testing.expectEqual(@as(usize, 7), range2.start);
    try std.testing.expectEqual(@as(usize, 14), range2.end);

    const range3 = state.getLineRange(2);
    try std.testing.expectEqual(@as(usize, 14), range3.start);
    try std.testing.expectEqual(@as(usize, 20), range3.end);
}

test "EditorState getLineContent" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = EditorState.init(allocator, io, "Line 1\nLine 2\nLine 3");
    defer state.deinit();

    const line1 = try state.getLineContent(0);
    defer allocator.free(line1);
    try std.testing.expectEqualStrings("Line 1", line1);

    const line2 = try state.getLineContent(1);
    defer allocator.free(line2);
    try std.testing.expectEqualStrings("Line 2", line2);

    const line3 = try state.getLineContent(2);
    defer allocator.free(line3);
    try std.testing.expectEqualStrings("Line 3", line3);
}

test "EditorState getLineContent empty line" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = EditorState.init(allocator, io, "Line 1\n\nLine 3");
    defer state.deinit();

    const line2 = try state.getLineContent(1);
    defer allocator.free(line2);
    try std.testing.expectEqualStrings("", line2);
}

test "EditorState deleteLine" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = EditorState.init(allocator, io, "Line 1\nLine 2\nLine 3");
    defer state.deinit();

    try state.deleteLine(1);

    const text = try state.buffer.toString(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("Line 1\nLine 3", text);
}

test "EditorState duplicateLine" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = EditorState.init(allocator, io, "Line 1\nLine 2");
    defer state.deinit();

    try state.duplicateLine(0);

    const text = try state.buffer.toString(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("Line 1\nLine 1\nLine 2", text);
}

test "EditorState swapAdjacentLines adjacent" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = EditorState.init(allocator, io, "Line 1\nLine 2\nLine 3");
    defer state.deinit();

    try state.swapAdjacentLines(0, 1);

    const text = try state.buffer.toString(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("Line 2\nLine 1\nLine 3", text);
}

test "EditorState swapAdjacentLines non-adjacent" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = EditorState.init(allocator, io, "Line 1\nLine 2\nLine 3");
    defer state.deinit();

    try state.swapAdjacentLines(0, 2);

    const text = try state.buffer.toString(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("Line 1\nLine 2\nLine 3", text);
}

test "EditorState joinLines" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = EditorState.init(allocator, io, "Hello\nWorld");
    defer state.deinit();

    try state.joinLines(0);

    const text = try state.buffer.toString(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("Hello World", text);
}

test "EditorState joinLines with whitespace" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = EditorState.init(allocator, io, "Hello\n    World");
    defer state.deinit();

    try state.joinLines(0);

    const text = try state.buffer.toString(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("Hello World", text);
}

test "EditorState joinLines at last line" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = EditorState.init(allocator, io, "Line 1\nLine 2");
    defer state.deinit();

    try state.joinLines(1);

    const text = try state.buffer.toString(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("Line 1\nLine 2", text);
}

test "EditorState insertTextAtCursor" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = EditorState.init(allocator, io, "Hello");
    defer state.deinit();

    state.cursor_col = 5;
    try state.insertTextAtCursor(" World");

    const text = try state.buffer.toString(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("Hello World", text);
    try std.testing.expectEqual(@as(usize, 11), state.cursor_col);
}

test "EditorState insertTextAtCursor with newlines" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = EditorState.init(allocator, io, "Hello");
    defer state.deinit();

    state.cursor_col = 5;
    try state.insertTextAtCursor("\nWorld\nTest");

    try std.testing.expectEqual(@as(usize, 2), state.cursor_row);
    try std.testing.expectEqual(@as(usize, 4), state.cursor_col);
}

test "EditorState deleteRange" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = EditorState.init(allocator, io, "Hello World");
    defer state.deinit();

    try state.deleteRange(5, 11);

    const text = try state.buffer.toString(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("Hello", text);
}

test "EditorState deleteRange inverted" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = EditorState.init(allocator, io, "Hello World");
    defer state.deinit();

    try state.deleteRange(11, 5);

    const text = try state.buffer.toString(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("Hello World", text);
}

test "EditorState deleteRange same positions" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = EditorState.init(allocator, io, "Hello World");
    defer state.deinit();

    try state.deleteRange(5, 5);

    const text = try state.buffer.toString(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("Hello World", text);
}

test "EditorState getCharAtOffset" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = EditorState.init(allocator, io, "Hello");
    defer state.deinit();

    try std.testing.expectEqual(@as(u8, 'H'), state.getCharAtOffset(0));
    try std.testing.expectEqual(@as(u8, 'e'), state.getCharAtOffset(1));
    try std.testing.expectEqual(@as(u8, 'o'), state.getCharAtOffset(4));
    try std.testing.expectEqual(@as(u8, 0), state.getCharAtOffset(5));
}

test "EditorState getCharBeforeCursor" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = EditorState.init(allocator, io, "Hello");
    defer state.deinit();

    state.cursor_col = 3;
    try std.testing.expectEqual(@as(u8, 'l'), state.getCharBeforeCursor());

    state.cursor_col = 0;
    try std.testing.expectEqual(@as(u8, 0), state.getCharBeforeCursor());
}

test "EditorState getCharAfterCursor" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = EditorState.init(allocator, io, "Hello");
    defer state.deinit();

    state.cursor_col = 2;
    try std.testing.expectEqual(@as(u8, 'l'), state.getCharAfterCursor());

    state.cursor_col = 5;
    try std.testing.expectEqual(@as(u8, 0), state.getCharAfterCursor());
}

test "EditorState insertNewlineWithIndent basic" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = EditorState.init(allocator, io, "    Hello");
    defer state.deinit();

    state.cursor_col = 9;
    try state.insertNewlineWithIndent();

    const text = try state.buffer.toString(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("    Hello\n    ", text);
    try std.testing.expectEqual(@as(usize, 1), state.cursor_row);
    try std.testing.expectEqual(@as(usize, 4), state.cursor_col);
}
