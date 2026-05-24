const std = @import("std");
const PieceTable = @import("piece_table.zig").PieceTable;
const Allocator = std.mem.Allocator;
const unicode = @import("unicode.zig");
const TestIo = @import("../test_utils.zig").TestIo;

/// Convert a byte offset into a piece-table to a (row, col) pair.
/// Walks the table once; cheap enough to call on each edit's
/// start/end bounds. Returns (last_row, last_col) for offsets past
/// the end — caller has already validated bounds.
fn offsetToRowCol(buf: *const PieceTable, target_offset: usize) struct { row: usize, col: usize } {
    var row: usize = 0;
    var col: usize = 0;
    var offset: usize = 0;
    for (buf.pieces.items) |p| {
        const data = switch (p.source) {
            .Original => buf.original[p.start .. p.start + p.length],
            .Add => buf.add.items[p.start .. p.start + p.length],
        };
        for (data) |c| {
            if (offset >= target_offset) return .{ .row = row, .col = col };
            if (c == '\n') {
                row += 1;
                col = 0;
            } else {
                col += 1;
            }
            offset += 1;
        }
    }
    return .{ .row = row, .col = col };
}

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

    /// Sticky column the cursor would prefer to land on during
    /// vertical motion. Set lazily on the first up/down step in a
    /// chain so bouncing through varying-length lines doesn't lose
    /// the user's place — e.g. cursor at col 400 on a long line,
    /// press Up onto a 5-char line (cursor clamps to col 5), press
    /// Down again, cursor restored to col 400. Cleared by any
    /// deliberate horizontal motion or text edit.
    preferred_col: ?usize = null,

    /// Optional callback fired after every successful insert/delete
    /// primitive with the byte + row/col deltas. Used by Core to
    /// forward edits into `SyntaxManager.recordEdit` so tree-sitter
    /// can do real incremental parsing (subtree reuse against an
    /// ts_tree_edit'd copy). `null` = no-op; tests and other callers
    /// that don't need incremental parsing skip the indirection.
    edit_hook: ?EditHook = null,

    pub const EditEvent = struct {
        start_byte: usize,
        old_end_byte: usize,
        new_end_byte: usize,
        start_row: usize,
        start_col: usize,
        old_end_row: usize,
        old_end_col: usize,
        new_end_row: usize,
        new_end_col: usize,
    };

    pub const EditHook = struct {
        ctx: *anyopaque,
        call: *const fn (ctx: *anyopaque, ev: EditEvent) void,
    };

    /// Fire the edit hook (if installed) with the precomputed event.
    /// Inline so the hook-free path costs a single null check.
    inline fn fireEdit(self: *EditorState, ev: EditEvent) void {
        if (self.edit_hook) |h| h.call(h.ctx, ev);
    }

    pub fn init(allocator: Allocator, io: std.Io, content: []const u8) !EditorState {
        return EditorState{
            .allocator = allocator,
            .io = io,
            .buffer = try PieceTable.init(allocator, content),
            .cursor_row = 0,
            .cursor_col = 0,
            .scroll_offset = 0,
            .file_path = null,
            .modified = false,
            .selection_anchor = null,
            .preferred_col = null,
            .edit_hook = null,
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

        // Dupe new path AND build the new piece table before swapping
        // in / freeing the old path — otherwise an OOM here would leave
        // self.file_path dangling (UAF on next read, double-free in
        // deinit) or leave self.buffer pointing at a deinit'd table.
        const new_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(new_path);
        var new_buffer = try PieceTable.init(self.allocator, content[0..read_n]);
        errdefer new_buffer.deinit();

        self.buffer.deinit();
        self.buffer = new_buffer;

        if (self.file_path) |old_path| {
            self.allocator.free(old_path);
        }
        self.file_path = new_path;

        self.cursor_row = 0;
        self.cursor_col = 0;
        self.scroll_offset = 0;
        self.modified = false;
        self.preferred_col = null;
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
            // fsync before the rename: POSIX `rename` is atomic for
            // the *name*, but doesn't guarantee the file's *content*
            // has hit disk. A crash / power loss between rename and
            // the kernel's writeback would leave a 0-byte file with
            // the new name — the worst possible outcome: looks saved,
            // actually empty. `sync` forces the data + metadata out
            // first so the rename only ever commits a fully-persisted
            // file.
            tmp_file.sync(self.io) catch |err| {
                std.log.warn("fsync of {s} failed: {} — proceeding with rename anyway", .{ tmp_path, err });
            };
        }

        std.Io.Dir.renameAbsolute(tmp_path, path, self.io) catch |err| {
            // Best-effort cleanup if rename failed.
            std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};
            return err;
        };

        // Dupe-then-free pattern: if dupe OOMs we'd otherwise leave
        // self.file_path dangling.
        if (self.file_path) |old_path| {
            if (!std.mem.eql(u8, old_path, path)) {
                const new_path = try self.allocator.dupe(u8, path);
                self.allocator.free(old_path);
                self.file_path = new_path;
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
        const start_row = self.cursor_row;
        const start_col = self.cursor_col;

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
        self.preferred_col = null;

        self.fireEdit(.{
            .start_byte = offset,
            .old_end_byte = offset,
            .new_end_byte = offset + 1,
            .start_row = start_row,
            .start_col = start_col,
            .old_end_row = start_row,
            .old_end_col = start_col,
            .new_end_row = self.cursor_row,
            .new_end_col = self.cursor_col,
        });
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

        // Snapshot the removed byte's row/col before mutation so the
        // edit hook can hand tree-sitter accurate old_end coords.
        const removed = self.getCharAtOffset(offset);
        const start_row = self.cursor_row;
        const start_col = self.cursor_col;
        const old_end_row = if (removed == '\n') start_row + 1 else start_row;
        const old_end_col: usize = if (removed == '\n') 0 else start_col + 1;

        try self.buffer.delete(offset, 1);
        self.markModified();
        self.preferred_col = null;

        self.fireEdit(.{
            .start_byte = offset,
            .old_end_byte = offset + 1,
            .new_end_byte = offset,
            .start_row = start_row,
            .start_col = start_col,
            .old_end_row = old_end_row,
            .old_end_col = old_end_col,
            .new_end_row = start_row,
            .new_end_col = start_col,
        });
    }

    pub fn backspaceChar(self: *EditorState) !void {
        const offset = self.getOffsetFromCursor();
        if (offset == 0) return;

        // The byte at offset-1 is what's about to go away. Snapshot
        // its row/col first so the hook can hand tree-sitter the old
        // span (start = pre-cursor, old_end = cursor, new_end = pre).
        const removed = self.getCharAtOffset(offset - 1);
        const old_end_row = self.cursor_row;
        const old_end_col = self.cursor_col;

        try self.buffer.delete(offset - 1, 1);
        self.markModified();
        self.updateCursorFromOffset(offset - 1);
        self.preferred_col = null;

        _ = removed; // (kept for clarity; we don't currently need to branch on it)
        self.fireEdit(.{
            .start_byte = offset - 1,
            .old_end_byte = offset,
            .new_end_byte = offset - 1,
            .start_row = self.cursor_row,
            .start_col = self.cursor_col,
            .old_end_row = old_end_row,
            .old_end_col = old_end_col,
            .new_end_row = self.cursor_row,
            .new_end_col = self.cursor_col,
        });
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

        // Snapshot start + old_end row/col before mutation.
        const start_rc = offsetToRowCol(&self.buffer, start_offset);
        const old_end_rc = offsetToRowCol(&self.buffer, end_offset);

        try self.buffer.delete(start_offset, len);
        self.markModified();
        self.updateCursorFromOffset(start_offset);
        self.preferred_col = null;

        self.fireEdit(.{
            .start_byte = start_offset,
            .old_end_byte = end_offset,
            .new_end_byte = start_offset,
            .start_row = start_rc.row,
            .start_col = start_rc.col,
            .old_end_row = old_end_rc.row,
            .old_end_col = old_end_rc.col,
            .new_end_row = start_rc.row,
            .new_end_col = start_rc.col,
        });
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
        const start_row = self.cursor_row;
        const start_col = self.cursor_col;

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
        self.preferred_col = null;

        self.fireEdit(.{
            .start_byte = offset,
            .old_end_byte = offset,
            .new_end_byte = offset + text.len,
            .start_row = start_row,
            .start_col = start_col,
            .old_end_row = start_row,
            .old_end_col = start_col,
            .new_end_row = self.cursor_row,
            .new_end_col = self.cursor_col,
        });
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
        self.preferred_col = null;
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
        self.preferred_col = null;
        const line_content = try self.getLineContent(self.cursor_row);
        defer self.allocator.free(line_content);

        const line_len = line_content.len;

        if (self.cursor_col >= line_len) {
            const line_count = self.buffer.lineCount();
            if (line_count > 0 and self.cursor_row + 1 < line_count) {
                self.cursor_row += 1;
                self.cursor_col = 0;
            }
        } else {
            if (unicode.nextGrapheme(line_content, self.cursor_col)) |new_col| {
                self.cursor_col = new_col;
            }
        }
    }

    /// Vertical-motion helpers that honour `preferred_col` so the
    /// cursor doesn't lose its column when stepping through lines
    /// of mixed length. Capture the current column on the first
    /// step of a chain; subsequent steps clamp to the new line's
    /// length but remember the original intent.
    pub fn moveCursorUp(self: *EditorState, n: usize) void {
        if (self.preferred_col == null) self.preferred_col = self.cursor_col;
        self.cursor_row -|= n;
        const line_len = self.getLineLength(self.cursor_row);
        self.cursor_col = @min(self.preferred_col.?, line_len);
    }

    pub fn moveCursorDown(self: *EditorState, n: usize) void {
        if (self.preferred_col == null) self.preferred_col = self.cursor_col;
        const line_count = self.buffer.lineCount();
        const max_row: usize = if (line_count == 0) 0 else line_count - 1;
        self.cursor_row = @min(self.cursor_row + n, max_row);
        const line_len = self.getLineLength(self.cursor_row);
        self.cursor_col = @min(self.preferred_col.?, line_len);
    }

    pub fn moveCursorToLineStart(self: *EditorState) void {
        self.cursor_col = 0;
        self.preferred_col = null;
    }

    pub fn moveCursorToLineEnd(self: *EditorState) void {
        self.cursor_col = self.getLineLength(self.cursor_row);
        self.preferred_col = null;
    }

    pub fn moveCursorNextWord(self: *EditorState) !void {
        self.preferred_col = null;
        const line_content = try self.getLineContent(self.cursor_row);
        defer self.allocator.free(line_content);

        if (try unicode.nextWord(line_content, self.cursor_col)) |new_col| {
            self.cursor_col = new_col;
        } else {
            const line_count = self.buffer.lineCount();
            if (line_count > 0 and self.cursor_row + 1 < line_count) {
                self.cursor_row += 1;
                self.cursor_col = 0;
            }
        }
    }

    pub fn moveCursorPrevWord(self: *EditorState) !void {
        self.preferred_col = null;
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

    /// Vim-style `e`: jump to the last char of the current/next word.
    pub fn moveCursorNextWordEnd(self: *EditorState) !void {
        self.preferred_col = null;
        const line_content = try self.getLineContent(self.cursor_row);
        defer self.allocator.free(line_content);

        if (try unicode.nextWordEnd(line_content, self.cursor_col)) |new_col| {
            self.cursor_col = new_col;
        } else {
            const line_count = self.buffer.lineCount();
            if (line_count > 0 and self.cursor_row + 1 < line_count) {
                self.cursor_row += 1;
                const next_line = try self.getLineContent(self.cursor_row);
                defer self.allocator.free(next_line);
                if (try unicode.nextWordEnd(next_line, 0)) |c| {
                    self.cursor_col = c;
                } else {
                    self.cursor_col = 0;
                }
            }
        }
    }

    /// Vim-style WORD motion (W): whitespace-separated.
    pub fn moveCursorNextBigWord(self: *EditorState) !void {
        self.preferred_col = null;
        const line_content = try self.getLineContent(self.cursor_row);
        defer self.allocator.free(line_content);

        if (try unicode.nextBigWord(line_content, self.cursor_col)) |new_col| {
            self.cursor_col = new_col;
        } else {
            const line_count = self.buffer.lineCount();
            if (line_count > 0 and self.cursor_row + 1 < line_count) {
                self.cursor_row += 1;
                self.cursor_col = 0;
            }
        }
    }

    pub fn moveCursorPrevBigWord(self: *EditorState) !void {
        self.preferred_col = null;
        const line_content = try self.getLineContent(self.cursor_row);
        defer self.allocator.free(line_content);

        if (try unicode.prevBigWord(line_content, self.cursor_col)) |new_col| {
            self.cursor_col = new_col;
        } else {
            if (self.cursor_row > 0) {
                self.cursor_row -= 1;
                self.cursor_col = self.getLineLength(self.cursor_row);
            }
        }
    }

    /// Vim-style `}`: jump to the start of the next paragraph (first
    /// blank line after, then the line after that). Falls back to EOF.
    pub fn moveCursorNextParagraph(self: *EditorState) void {
        self.preferred_col = null;
        const total = self.buffer.lineCount();
        if (total == 0) return;
        var row = self.cursor_row + 1;
        // Skip the current non-blank block.
        while (row < total) : (row += 1) {
            if (self.isLineBlank(row)) break;
        }
        // Skip blank lines to land on the next non-blank line, or EOF.
        while (row < total) : (row += 1) {
            if (!self.isLineBlank(row)) break;
        }
        if (row >= total) row = total - 1;
        self.cursor_row = row;
        self.cursor_col = 0;
    }

    /// Vim-style `{`: jump to the start of the previous paragraph.
    pub fn moveCursorPrevParagraph(self: *EditorState) void {
        self.preferred_col = null;
        if (self.cursor_row == 0) {
            self.cursor_col = 0;
            return;
        }
        var row: usize = self.cursor_row - 1;
        // Skip blank lines immediately above.
        while (row > 0 and self.isLineBlank(row)) : (row -= 1) {}
        // Skip the non-blank block above to find its top.
        while (row > 0 and !self.isLineBlank(row - 1)) : (row -= 1) {}
        self.cursor_row = row;
        self.cursor_col = 0;
    }

    fn isLineBlank(self: *EditorState, row: usize) bool {
        const line = self.getLineContent(row) catch return true;
        defer self.allocator.free(line);
        for (line) |b| {
            if (b != ' ' and b != '\t' and b != '\r') return false;
        }
        return true;
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
    var state = try EditorState.init(allocator, io, "Hello");
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
    var state = try EditorState.init(allocator, io, "Hello");
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
    var state = try EditorState.init(allocator, io, "Hello");
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
    var state = try EditorState.init(allocator, io, "Hi");
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
    var state = try EditorState.init(allocator, io, "");
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
    var state = try EditorState.init(allocator, io, "Hello");
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
    var state = try EditorState.init(allocator, io, "Hi");
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
    var state = try EditorState.init(allocator, io, "Hello");
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
    var state = try EditorState.init(allocator, io, "Hello");
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
    var state = try EditorState.init(allocator, io, "Line 1\nLine 2\nLine 3");
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
    var state = try EditorState.init(allocator, io, "Hello\nWorld");
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
    var state = try EditorState.init(allocator, io, "Hello\nWorld");
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
    var state = try EditorState.init(allocator, io, "Line 1\nLine 2\nLine 3");
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
    var state = try EditorState.init(allocator, io, "Line 1\nLine 2\nLine 3");
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
    var state = try EditorState.init(allocator, io, "Line 1\n\nLine 3");
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
    var state = try EditorState.init(allocator, io, "Line 1\nLine 2\nLine 3");
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
    var state = try EditorState.init(allocator, io, "Line 1\nLine 2");
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
    var state = try EditorState.init(allocator, io, "Line 1\nLine 2\nLine 3");
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
    var state = try EditorState.init(allocator, io, "Line 1\nLine 2\nLine 3");
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
    var state = try EditorState.init(allocator, io, "Hello\nWorld");
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
    var state = try EditorState.init(allocator, io, "Hello\n    World");
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
    var state = try EditorState.init(allocator, io, "Line 1\nLine 2");
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
    var state = try EditorState.init(allocator, io, "Hello");
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
    var state = try EditorState.init(allocator, io, "Hello");
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
    var state = try EditorState.init(allocator, io, "Hello World");
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
    var state = try EditorState.init(allocator, io, "Hello World");
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
    var state = try EditorState.init(allocator, io, "Hello World");
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
    var state = try EditorState.init(allocator, io, "Hello");
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
    var state = try EditorState.init(allocator, io, "Hello");
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
    var state = try EditorState.init(allocator, io, "Hello");
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
    var state = try EditorState.init(allocator, io, "    Hello");
    defer state.deinit();

    state.cursor_col = 9;
    try state.insertNewlineWithIndent();

    const text = try state.buffer.toString(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("    Hello\n    ", text);
    try std.testing.expectEqual(@as(usize, 1), state.cursor_row);
    try std.testing.expectEqual(@as(usize, 4), state.cursor_col);
}

test "moveCursorLeftGrapheme wraps from blank line to previous" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    // Three lines: "hello", "", "world". Cursor on the blank middle line.
    var state = try EditorState.init(allocator, io, "hello\n\nworld");
    defer state.deinit();

    state.cursor_row = 1;
    state.cursor_col = 0;

    try state.moveCursorLeftGrapheme();
    try std.testing.expectEqual(@as(usize, 0), state.cursor_row);
    try std.testing.expectEqual(@as(usize, 5), state.cursor_col);
}

test "moveCursorRightGrapheme wraps from blank line to next" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = try EditorState.init(allocator, io, "hello\n\nworld");
    defer state.deinit();

    state.cursor_row = 1;
    state.cursor_col = 0;

    try state.moveCursorRightGrapheme();
    try std.testing.expectEqual(@as(usize, 2), state.cursor_row);
    try std.testing.expectEqual(@as(usize, 0), state.cursor_col);
}

test "preferred_col survives a trip through a shorter line" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    // Row 0: 20 chars. Row 1: 3 chars. Row 2: 20 chars.
    var state = try EditorState.init(allocator, io, "abcdefghij1234567890\nfoo\nlongerlineofstuff!!");
    defer state.deinit();

    state.cursor_row = 0;
    state.cursor_col = 18;

    // Down onto the short line: column clamps to 3, but preferred is 18.
    state.moveCursorDown(1);
    try std.testing.expectEqual(@as(usize, 1), state.cursor_row);
    try std.testing.expectEqual(@as(usize, 3), state.cursor_col);
    try std.testing.expectEqual(@as(?usize, 18), state.preferred_col);

    // Down again onto a long line: column restored to 18.
    state.moveCursorDown(1);
    try std.testing.expectEqual(@as(usize, 2), state.cursor_row);
    try std.testing.expectEqual(@as(usize, 18), state.cursor_col);
}

test "preferred_col cleared by horizontal motion" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = try EditorState.init(allocator, io, "abcdefghij1234567890\nfoo\nlongerlineofstuff!!");
    defer state.deinit();

    state.cursor_row = 0;
    state.cursor_col = 18;
    state.moveCursorDown(1); // sets preferred_col = 18

    try state.moveCursorLeftGrapheme(); // any horizontal motion clears it
    try std.testing.expectEqual(@as(?usize, null), state.preferred_col);
}

test "preferred_col cleared by edit" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = try EditorState.init(allocator, io, "abcdefghij\nfoo");
    defer state.deinit();

    state.cursor_row = 0;
    state.cursor_col = 8;
    state.moveCursorDown(1); // preferred_col = 8

    try state.insertChar('x');
    try std.testing.expectEqual(@as(?usize, null), state.preferred_col);
}

// ────────────────────────────────────────────────────────────
// Regression tests for the edit-hook plumbing (A1).
// Without these, a future refactor that changes the edit
// primitives could quietly drop the hook calls and tree-sitter
// would silently fall back to non-incremental re-parses.
// ────────────────────────────────────────────────────────────

const TestHookCapture = struct {
    events: std.ArrayListUnmanaged(EditorState.EditEvent) = .empty,
    allocator: std.mem.Allocator,

    fn record(ctx: *anyopaque, ev: EditorState.EditEvent) void {
        const self: *TestHookCapture = @ptrCast(@alignCast(ctx));
        self.events.append(self.allocator, ev) catch {};
    }

    fn deinit(self: *TestHookCapture) void {
        self.events.deinit(self.allocator);
    }
};

test "edit hook fires on insertChar with correct deltas" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();

    var capture = TestHookCapture{ .allocator = allocator };
    defer capture.deinit();

    var state = try EditorState.init(allocator, io_ctx.io(), "hello");
    defer state.deinit();
    state.edit_hook = .{ .ctx = @ptrCast(&capture), .call = TestHookCapture.record };

    state.cursor_row = 0;
    state.cursor_col = 5; // end of "hello"
    try state.insertChar('!');

    try std.testing.expectEqual(@as(usize, 1), capture.events.items.len);
    const ev = capture.events.items[0];
    try std.testing.expectEqual(@as(usize, 5), ev.start_byte);
    try std.testing.expectEqual(@as(usize, 5), ev.old_end_byte);
    try std.testing.expectEqual(@as(usize, 6), ev.new_end_byte);
    try std.testing.expectEqual(@as(usize, 0), ev.start_row);
    try std.testing.expectEqual(@as(usize, 5), ev.start_col);
    try std.testing.expectEqual(@as(usize, 0), ev.new_end_row);
    try std.testing.expectEqual(@as(usize, 6), ev.new_end_col);
}

test "edit hook fires on insertChar('\\n') with row delta" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();

    var capture = TestHookCapture{ .allocator = allocator };
    defer capture.deinit();

    var state = try EditorState.init(allocator, io_ctx.io(), "abc");
    defer state.deinit();
    state.edit_hook = .{ .ctx = @ptrCast(&capture), .call = TestHookCapture.record };

    state.cursor_row = 0;
    state.cursor_col = 3;
    try state.insertChar('\n');

    try std.testing.expectEqual(@as(usize, 1), capture.events.items.len);
    const ev = capture.events.items[0];
    try std.testing.expectEqual(@as(usize, 1), ev.new_end_row);
    try std.testing.expectEqual(@as(usize, 0), ev.new_end_col);
    try std.testing.expectEqual(@as(usize, 3), ev.start_byte);
    try std.testing.expectEqual(@as(usize, 4), ev.new_end_byte);
}

test "edit hook fires on deleteChar and backspaceChar" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();

    var capture = TestHookCapture{ .allocator = allocator };
    defer capture.deinit();

    var state = try EditorState.init(allocator, io_ctx.io(), "abcde");
    defer state.deinit();
    state.edit_hook = .{ .ctx = @ptrCast(&capture), .call = TestHookCapture.record };

    // Forward delete at col 2 → removes 'c'.
    state.cursor_col = 2;
    try state.deleteChar();
    try std.testing.expectEqual(@as(usize, 1), capture.events.items.len);
    {
        const ev = capture.events.items[0];
        try std.testing.expectEqual(@as(usize, 2), ev.start_byte);
        try std.testing.expectEqual(@as(usize, 3), ev.old_end_byte);
        try std.testing.expectEqual(@as(usize, 2), ev.new_end_byte);
    }

    // Backspace at col 2 → removes the new char-at-1 ('b'), cursor lands at col 1.
    try state.backspaceChar();
    try std.testing.expectEqual(@as(usize, 2), capture.events.items.len);
    {
        const ev = capture.events.items[1];
        try std.testing.expectEqual(@as(usize, 1), ev.start_byte);
        try std.testing.expectEqual(@as(usize, 2), ev.old_end_byte);
        try std.testing.expectEqual(@as(usize, 1), ev.new_end_byte);
    }
}

test "edit hook is null-safe (works without installation)" {
    // The hook is optional; the primitive must not crash or
    // dispatch when nothing is installed. Catches the regression
    // where someone refactors the hook plumbing and forgets the
    // null check.
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();

    var state = try EditorState.init(allocator, io_ctx.io(), "x");
    defer state.deinit();
    try std.testing.expect(state.edit_hook == null);

    try state.insertChar('y');
    try state.deleteChar();
    try state.backspaceChar();
    try state.insertTextAtCursor("hello");
    try state.deleteRange(0, 2);
    // If we reach here without crashing, the null-safe path works.
}

test "insertTextAtCursor records the full byte + row delta" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();

    var capture = TestHookCapture{ .allocator = allocator };
    defer capture.deinit();

    var state = try EditorState.init(allocator, io_ctx.io(), "");
    defer state.deinit();
    state.edit_hook = .{ .ctx = @ptrCast(&capture), .call = TestHookCapture.record };

    try state.insertTextAtCursor("ab\ncd");

    try std.testing.expectEqual(@as(usize, 1), capture.events.items.len);
    const ev = capture.events.items[0];
    try std.testing.expectEqual(@as(usize, 0), ev.start_byte);
    try std.testing.expectEqual(@as(usize, 0), ev.old_end_byte);
    try std.testing.expectEqual(@as(usize, 5), ev.new_end_byte);
    try std.testing.expectEqual(@as(usize, 1), ev.new_end_row);
    try std.testing.expectEqual(@as(usize, 2), ev.new_end_col);
}
