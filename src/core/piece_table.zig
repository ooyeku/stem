const std = @import("std");
const Allocator = std.mem.Allocator;

const test_utils = @import("../test_utils.zig");
const PieceTableTestUtils = test_utils.PieceTableTestUtils;
const MemoryTestUtils = test_utils.MemoryTestUtils;
const PerformanceTestUtils = test_utils.PerformanceTestUtils;
const StringTestUtils = test_utils.StringTestUtils;

pub const BufferSource = enum {
    Original,
    Add,
};

pub const Piece = struct {
    source: BufferSource,
    start: usize,
    length: usize,
    line_count: usize,
    last_line_len: usize,
};

pub const PieceTable = struct {
    original: []const u8,
    owns_original: bool,
    add: std.ArrayListUnmanaged(u8),
    pieces: std.ArrayListUnmanaged(Piece),
    allocator: Allocator,

    cached_total_len: ?usize = null,
    cached_line_count: ?usize = null,

    pub fn init(allocator: Allocator, original_content: []const u8) PieceTable {
        const owned_content = allocator.dupe(u8, original_content) catch {
            return PieceTable{
                .original = &.{},
                .owns_original = false,
                .add = .empty,
                .pieces = .empty,
                .allocator = allocator,
            };
        };

        var pt = PieceTable{
            .original = owned_content,
            .owns_original = true,
            .add = .empty,
            .pieces = .empty,
            .allocator = allocator,
        };

        if (owned_content.len > 0) {
            pt.pieces.append(allocator, .{
                .source = .Original,
                .start = 0,
                .length = owned_content.len,
                .line_count = std.mem.count(u8, owned_content, "\n"),
                .last_line_len = if (std.mem.lastIndexOfScalar(u8, owned_content, '\n')) |idx| owned_content.len - 1 - idx else owned_content.len,
            }) catch {
                // OOM on the single initial piece append: degrade to an empty piece table rather
                // than leave a struct that claims owned content but has no pieces (which would
                // confuse totalLength()/toString()).
                allocator.free(@constCast(owned_content));
                return PieceTable{
                    .original = &.{},
                    .owns_original = false,
                    .add = .empty,
                    .pieces = .empty,
                    .allocator = allocator,
                };
            };
        }

        return pt;
    }

    pub fn deinit(self: *PieceTable) void {
        if (self.owns_original and self.original.len > 0) {
            self.allocator.free(@constCast(self.original));
        }
        self.add.deinit(self.allocator);
        self.pieces.deinit(self.allocator);
    }

    fn invalidateCache(self: *PieceTable) void {
        self.cached_total_len = null;
        self.cached_line_count = null;
    }

    pub fn totalLength(self: *PieceTable) usize {
        if (self.cached_total_len) |len| return len;

        var total: usize = 0;
        for (self.pieces.items) |p| {
            total += p.length;
        }
        self.cached_total_len = total;
        return total;
    }

    pub fn lineCount(self: *PieceTable) usize {
        if (self.cached_line_count) |count| return count;

        var count: usize = 1;
        for (self.pieces.items) |p| {
            count += p.line_count;
        }
        self.cached_line_count = count;
        return count;
    }

    fn getPieceData(self: *PieceTable, p: Piece) []const u8 {
        return switch (p.source) {
            .Original => self.original[p.start .. p.start + p.length],
            .Add => self.add.items[p.start .. p.start + p.length],
        };
    }

    pub fn getCharAt(self: *PieceTable, offset: usize) ?u8 {
        var current_offset: usize = 0;
        for (self.pieces.items) |p| {
            if (offset < current_offset + p.length) {
                const data = self.getPieceData(p);
                return data[offset - current_offset];
            }
            current_offset += p.length;
        }
        return null;
    }

    pub fn iterateContent(self: *PieceTable, context: anytype, callback: fn (@TypeOf(context), usize, u8) bool) void {
        var global_offset: usize = 0;
        for (self.pieces.items) |p| {
            const data = self.getPieceData(p);
            for (data) |c| {
                if (callback(context, global_offset, c)) return;
                global_offset += 1;
            }
        }
    }

    pub fn getVisibleLines(self: *PieceTable, allocator: Allocator, start_line: usize, count: usize) ![][]const u8 {
        var lines = std.ArrayListUnmanaged([]const u8).empty;
        errdefer lines.deinit(allocator);

        var current_line: usize = 0;
        var line_start_offset: usize = 0;
        var global_offset: usize = 0;

        outer: for (self.pieces.items) |p| {
            if (current_line + p.line_count < start_line) {
                current_line += p.line_count;
                global_offset += p.length;
                continue;
            }

            const data = self.getPieceData(p);
            for (data, 0..) |c, i| {
                if (current_line == start_line) {
                    line_start_offset = global_offset + i;
                    break :outer;
                }
                if (c == '\n') {
                    current_line += 1;
                }
            }
            global_offset += p.length;
        }

        if (current_line < start_line) {
            return lines.toOwnedSlice(allocator);
        }

        if (current_line == start_line and start_line > 0 and line_start_offset == 0) {
            line_start_offset = global_offset;
        }

        var collecting = true;
        var line_buffer = std.ArrayListUnmanaged(u8).empty;
        defer line_buffer.deinit(allocator);

        global_offset = 0;
        for (self.pieces.items) |p| {
            if (!collecting) break;
            if (lines.items.len >= count) break;

            const data = self.getPieceData(p);
            for (data) |c| {
                if (global_offset < line_start_offset) {
                    global_offset += 1;
                    continue;
                }

                if (c == '\n') {
                    const line_copy = try allocator.dupe(u8, line_buffer.items);
                    try lines.append(allocator, line_copy);
                    line_buffer.clearRetainingCapacity();

                    if (lines.items.len >= count) {
                        collecting = false;
                        break;
                    }
                } else {
                    try line_buffer.append(allocator, c);
                }
                global_offset += 1;
            }
        }

        if (collecting and lines.items.len < count) {
            const line_copy = try allocator.dupe(u8, line_buffer.items);
            try lines.append(allocator, line_copy);
        }

        return lines.toOwnedSlice(allocator);
    }

    pub fn getLineStartOffset(self: *PieceTable, target_line: usize) usize {
        var current_line: usize = 0;
        var offset: usize = 0;

        for (self.pieces.items) |p| {
            if (target_line <= current_line + p.line_count) {
                const data = self.getPieceData(p);
                for (data) |c| {
                    if (current_line == target_line) return offset;
                    if (c == '\n') current_line += 1;
                    offset += 1;
                }
                if (current_line == target_line) return offset;
            } else {
                current_line += p.line_count;
                offset += p.length;
            }
        }
        return offset;
    }

    pub fn getPositionAtOffset(self: *PieceTable, target_offset: usize) struct { row: usize, col: usize } {
        var row: usize = 0;
        var col: usize = 0;
        var current_offset: usize = 0;

        for (self.pieces.items) |p| {
            if (current_offset + p.length <= target_offset) {
                row += p.line_count;
                if (p.line_count > 0) {
                    col = p.last_line_len;
                } else {
                    col += p.length;
                }
                current_offset += p.length;
                continue;
            }

            const data = self.getPieceData(p);
            const relative_target = target_offset - current_offset;
            const slice = data[0..relative_target];

            for (slice) |c| {
                if (c == '\n') {
                    row += 1;
                    col = 0;
                } else {
                    col += 1;
                }
            }
            return .{ .row = row, .col = col };
        }
        return .{ .row = row, .col = col };
    }

    pub fn getOffsetForPosition(self: *PieceTable, target_row: usize, target_col: usize) usize {
        const start = self.getLineStartOffset(target_row);

        var curr_offset = start;
        var curr_col: usize = 0;

        var piece_found = false;
        var piece_start_global: usize = 0;

        for (self.pieces.items) |p| {
            if (!piece_found) {
                if (piece_start_global + p.length <= start) {
                    piece_start_global += p.length;
                    continue;
                }
                piece_found = true;
            }

            var local_idx: usize = 0;
            if (piece_start_global < start) {
                local_idx = start - piece_start_global;
            }

            const data = self.getPieceData(p);
            for (data[local_idx..]) |c| {
                if (c == '\n') return curr_offset;
                if (curr_col == target_col) return curr_offset;
                curr_col += 1;
                curr_offset += 1;
            }

            piece_start_global += p.length;
        }
        return curr_offset;
    }

    pub fn insert(self: *PieceTable, global_offset: usize, text: []const u8) !void {
        if (text.len == 0) return;
        self.invalidateCache();

        const add_start = self.add.items.len;
        try self.add.appendSlice(self.allocator, text);

        const new_line_count = std.mem.count(u8, text, "\n");
        const new_last_line_len = if (std.mem.lastIndexOfScalar(u8, text, '\n')) |idx| text.len - 1 - idx else text.len;

        const new_piece = Piece{
            .source = .Add,
            .start = add_start,
            .length = text.len,
            .line_count = new_line_count,
            .last_line_len = new_last_line_len,
        };

        var current_offset: usize = 0;
        var piece_idx: usize = 0;

        if (self.pieces.items.len == 0) {
            try self.pieces.append(self.allocator, new_piece);
            return;
        }

        while (piece_idx < self.pieces.items.len) {
            var p = &self.pieces.items[piece_idx];

            if (global_offset >= current_offset and global_offset <= current_offset + p.length) {
                const relative_offset = global_offset - current_offset;

                if (relative_offset == 0) {
                    try self.pieces.insert(self.allocator, piece_idx, new_piece);
                    return;
                }

                if (relative_offset == p.length) {
                    try self.pieces.insert(self.allocator, piece_idx + 1, new_piece);
                    return;
                }

                const full_piece_data = self.getPieceData(p.*);
                const left_lines = std.mem.count(u8, full_piece_data[0..relative_offset], "\n");

                const right_len = p.length - relative_offset;

                const right_slice = full_piece_data[relative_offset..];
                const right_lines = std.mem.count(u8, right_slice, "\n");
                const right_last_len = if (std.mem.lastIndexOfScalar(u8, right_slice, '\n')) |idx| right_slice.len - 1 - idx else right_slice.len;

                const left_slice = full_piece_data[0..relative_offset];
                p.length = relative_offset;
                p.line_count = left_lines;
                p.last_line_len = if (std.mem.lastIndexOfScalar(u8, left_slice, '\n')) |idx| left_slice.len - 1 - idx else left_slice.len;

                const right_piece = Piece{
                    .source = p.source,
                    .start = p.start + relative_offset,
                    .length = right_len,
                    .line_count = right_lines,
                    .last_line_len = right_last_len,
                };

                try self.pieces.insert(self.allocator, piece_idx + 1, right_piece);
                try self.pieces.insert(self.allocator, piece_idx + 1, new_piece);
                return;
            }

            current_offset += p.length;
            piece_idx += 1;
        }
    }

    pub fn delete(self: *PieceTable, global_offset: usize, length: usize) !void {
        if (length == 0) return;
        self.invalidateCache();

        var current_offset: usize = 0;
        var i: usize = 0;

        while (i < self.pieces.items.len) {
            var p = &self.pieces.items[i];
            const original_len = p.length;
            const p_end = current_offset + original_len;

            const del_start = global_offset;
            const del_end = global_offset + length;

            const intersect_start = @max(current_offset, del_start);
            const intersect_end = @min(p_end, del_end);

            if (intersect_start < intersect_end) {
                if (intersect_start == current_offset and intersect_end == p_end) {
                    _ = self.pieces.orderedRemove(i);
                    current_offset += original_len;
                    continue;
                }

                if (intersect_start > current_offset and intersect_end < p_end) {
                    const left_len = intersect_start - current_offset;
                    const right_len = p_end - intersect_end;

                    const full_piece_data = self.getPieceData(p.*);

                    const left_slice = full_piece_data[0..left_len];
                    const left_lines = std.mem.count(u8, left_slice, "\n");
                    const left_last_len = if (std.mem.lastIndexOfScalar(u8, left_slice, '\n')) |idx| left_slice.len - 1 - idx else left_slice.len;

                    const right_start_offset = original_len - right_len;
                    const right_slice = full_piece_data[right_start_offset..];
                    const right_lines = std.mem.count(u8, right_slice, "\n");
                    const right_last_len = if (std.mem.lastIndexOfScalar(u8, right_slice, '\n')) |idx| right_slice.len - 1 - idx else right_slice.len;

                    p.length = left_len;
                    p.line_count = left_lines;
                    p.last_line_len = left_last_len;

                    const right_piece = Piece{
                        .source = p.source,
                        .start = p.start + right_start_offset,
                        .length = right_len,
                        .line_count = right_lines,
                        .last_line_len = right_last_len,
                    };
                    try self.pieces.insert(self.allocator, i + 1, right_piece);

                    i += 2;
                    current_offset += original_len;
                    continue;
                }

                if (intersect_start > current_offset) {
                    const new_len = intersect_start - current_offset;
                    const full_piece_data = self.getPieceData(p.*);
                    const new_slice = full_piece_data[0..new_len];

                    p.length = new_len;
                    p.line_count = std.mem.count(u8, new_slice, "\n");
                    p.last_line_len = if (std.mem.lastIndexOfScalar(u8, new_slice, '\n')) |idx| new_slice.len - 1 - idx else new_slice.len;

                    i += 1;
                    current_offset += original_len;
                    continue;
                }

                if (intersect_end < p_end) {
                    const cut_len = intersect_end - current_offset;

                    p.start += cut_len;
                    p.length -= cut_len;

                    const piece_data = self.getPieceData(p.*);
                    p.line_count = std.mem.count(u8, piece_data, "\n");
                    p.last_line_len = if (std.mem.lastIndexOfScalar(u8, piece_data, '\n')) |idx| piece_data.len - 1 - idx else piece_data.len;

                    i += 1;
                    current_offset += original_len;
                    continue;
                }
            }

            current_offset += original_len;
            i += 1;
        }
    }

    pub fn find(self: *PieceTable, query: []const u8, start_offset: usize) !?usize {
        if (query.len == 0) return null;

        var lps = try self.allocator.alloc(usize, query.len);
        defer self.allocator.free(lps);
        @memset(lps, 0);

        var len: usize = 0;
        var i: usize = 1;
        while (i < query.len) {
            if (query[i] == query[len]) {
                len += 1;
                lps[i] = len;
                i += 1;
            } else {
                if (len != 0) {
                    len = lps[len - 1];
                } else {
                    lps[i] = 0;
                    i += 1;
                }
            }
        }

        var match_idx: usize = 0;
        var current_offset: usize = 0;

        for (self.pieces.items) |p| {
            const data = self.getPieceData(p);

            if (current_offset + p.length <= start_offset) {
                current_offset += p.length;
                continue;
            }

            var start_code_idx: usize = 0;
            if (current_offset < start_offset) {
                start_code_idx = start_offset - current_offset;
            }

            for (data[start_code_idx..], 0..) |c, idx| {
                while (match_idx > 0 and c != query[match_idx]) {
                    match_idx = lps[match_idx - 1];
                }

                if (c == query[match_idx]) {
                    match_idx += 1;
                }

                if (match_idx == query.len) {
                    return (current_offset + start_code_idx + idx) + 1 - query.len;
                }
            }

            current_offset += p.length;
        }

        return null;
    }

    pub fn findLast(self: *PieceTable, query: []const u8, end_offset: usize) !?usize {
        var last_found: ?usize = null;
        var start: usize = 0;

        while (true) {
            if (try self.find(query, start)) |found| {
                if (found >= end_offset) break;
                last_found = found;
                start = found + 1;
            } else {
                break;
            }
        }
        return last_found;
    }

    pub fn toString(self: *PieceTable, allocator: Allocator) ![]u8 {
        var list = std.ArrayListUnmanaged(u8).empty;
        errdefer list.deinit(allocator);

        for (self.pieces.items) |p| {
            try list.appendSlice(allocator, self.getPieceData(p));
        }
        return list.toOwnedSlice(allocator);
    }
};

test "PieceTable basic insert" {
    const allocator = std.testing.allocator;
    var pt = try PieceTableTestUtils.createTestBuffer(allocator, "Hello World");
    defer pt.deinit();

    try pt.insert(6, "Cruel ");

    const result = try pt.toString(allocator);
    defer allocator.free(result);

    try StringTestUtils.expectEqualStrings("Hello Cruel World", result);
}

test "PieceTable getVisibleLines" {
    const allocator = std.testing.allocator;
    const original = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5";

    var pt = PieceTable.init(allocator, original);
    defer pt.deinit();

    const lines = try pt.getVisibleLines(allocator, 1, 2);
    defer {
        for (lines) |line| allocator.free(line);
        allocator.free(lines);
    }

    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("Line 2", lines[0]);
    try std.testing.expectEqualStrings("Line 3", lines[1]);
}

test "PieceTable empty buffer" {
    const allocator = std.testing.allocator;
    var pt = try PieceTableTestUtils.createEmptyBuffer(allocator);
    defer pt.deinit();

    try std.testing.expectEqual(@as(usize, 0), pt.totalLength());
    try std.testing.expectEqual(@as(usize, 1), pt.lineCount());

    const result = try pt.toString(allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "PieceTable insert at start" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "World");
    defer pt.deinit();

    try pt.insert(0, "Hello ");

    const result = try pt.toString(allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello World", result);
}

test "PieceTable insert at end" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "Hello");
    defer pt.deinit();

    try pt.insert(5, " World");

    const result = try pt.toString(allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello World", result);
}

test "PieceTable insert empty string" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "Hello");
    defer pt.deinit();

    try pt.insert(2, "");

    const result = try pt.toString(allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello", result);
}

test "PieceTable multiple inserts" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "Hello");
    defer pt.deinit();

    try pt.insert(5, " World");
    try pt.insert(5, " Cruel");
    try pt.insert(0, "Oh ");

    const result = try pt.toString(allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Oh Hello Cruel World", result);
}

test "PieceTable delete entire buffer" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "Hello World");
    defer pt.deinit();

    try pt.delete(0, 11);

    const result = try pt.toString(allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
    try std.testing.expectEqual(@as(usize, 0), pt.totalLength());
}

test "PieceTable delete from middle" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "Hello World");
    defer pt.deinit();

    try pt.delete(5, 6);

    const result = try pt.toString(allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello", result);
}

test "PieceTable delete at start" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "Hello World");
    defer pt.deinit();

    try pt.delete(0, 6);

    const result = try pt.toString(allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("World", result);
}

test "PieceTable delete at end" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "Hello World");
    defer pt.deinit();

    try pt.delete(5, 6);

    const result = try pt.toString(allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello", result);
}

test "PieceTable delete zero length" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "Hello");
    defer pt.deinit();

    try pt.delete(2, 0);

    const result = try pt.toString(allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello", result);
}

test "PieceTable getCharAt bounds" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "Hello");
    defer pt.deinit();

    try std.testing.expectEqual(@as(u8, 'H'), pt.getCharAt(0).?);
    try std.testing.expectEqual(@as(u8, 'o'), pt.getCharAt(4).?);
    try std.testing.expect(pt.getCharAt(5) == null);
    try std.testing.expect(pt.getCharAt(100) == null);
}

test "PieceTable lineCount with newlines" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "Line 1\nLine 2\nLine 3");
    defer pt.deinit();

    try std.testing.expectEqual(@as(usize, 3), pt.lineCount());

    try pt.insert(20, "\nLine 4");
    try std.testing.expectEqual(@as(usize, 4), pt.lineCount());
}

test "PieceTable lineCount single line no newline" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "Single line");
    defer pt.deinit();

    try std.testing.expectEqual(@as(usize, 1), pt.lineCount());
}

test "PieceTable cache invalidation on insert" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "Hello");
    defer pt.deinit();

    const len1 = pt.totalLength();
    try std.testing.expectEqual(@as(usize, 5), len1);

    try pt.insert(5, " World");
    const len2 = pt.totalLength();
    try std.testing.expectEqual(@as(usize, 11), len2);
}

test "PieceTable cache invalidation on delete" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "Hello World");
    defer pt.deinit();

    const len1 = pt.totalLength();
    try std.testing.expectEqual(@as(usize, 11), len1);

    try pt.delete(5, 6);
    const len2 = pt.totalLength();
    try std.testing.expectEqual(@as(usize, 5), len2);
}

test "PieceTable find simple string" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "Hello World, Hello Universe");
    defer pt.deinit();

    const pos1 = try pt.find("Hello", 0);
    try std.testing.expectEqual(@as(usize, 0), pos1.?);

    const pos2 = try pt.find("World", 0);
    try std.testing.expectEqual(@as(usize, 6), pos2.?);

    const pos3 = try pt.find("Hello", 1);
    try std.testing.expectEqual(@as(usize, 13), pos3.?);
}

test "PieceTable find not found" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "Hello World");
    defer pt.deinit();

    const pos = try pt.find("Goodbye", 0);
    try std.testing.expect(pos == null);
}

test "PieceTable find empty query" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "Hello World");
    defer pt.deinit();

    const pos = try pt.find("", 0);
    try std.testing.expect(pos == null);
}

test "PieceTable findLast" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "Hello World, Hello Universe, Hello");
    defer pt.deinit();

    const pos = try pt.findLast("Hello", 35);
    try std.testing.expectEqual(@as(usize, 29), pos.?);
}

test "PieceTable findLast not found" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "Hello World");
    defer pt.deinit();

    const pos = try pt.findLast("Goodbye", 11);
    try std.testing.expect(pos == null);
}

test "PieceTable getVisibleLines out of bounds" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "Line 1\nLine 2");
    defer pt.deinit();

    const lines = try pt.getVisibleLines(allocator, 10, 5);
    defer allocator.free(lines);

    try std.testing.expectEqual(@as(usize, 0), lines.len);
}

test "PieceTable getVisibleLines empty buffer" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "");
    defer pt.deinit();

    const lines = try pt.getVisibleLines(allocator, 0, 5);
    defer {
        for (lines) |line| allocator.free(line);
        allocator.free(lines);
    }

    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expectEqualStrings("", lines[0]);
}

test "PieceTable Unicode support" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "Hello 世界");
    defer pt.deinit();

    try pt.insert(6, "美丽的");

    const result = try pt.toString(allocator);
    defer allocator.free(result);
    try StringTestUtils.expectEqualStrings("Hello 美丽的世界", result);
}

test "PieceTable UTF-8 string manipulation" {
    const allocator = std.testing.allocator;
    const utf8_content = try StringTestUtils.createUtf8TestString(allocator);
    defer allocator.free(utf8_content);

    var pt = try PieceTableTestUtils.createTestBuffer(allocator, utf8_content);
    defer pt.deinit();

    try PieceTableTestUtils.expectContent(&pt, utf8_content);

    try pt.insert(0, "🚀 Start ");

    const lines = pt.lineCount();
    try std.testing.expect(lines >= 5);
}

test "PieceTable large insert and delete" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "Start");
    defer pt.deinit();

    const large_str = "ABCDEFGHIJKLMNOPQRSTUVWXYZ" ** 100;
    try pt.insert(5, large_str);

    try std.testing.expectEqual(@as(usize, 5 + large_str.len), pt.totalLength());

    try pt.delete(5, large_str.len);

    const result = try pt.toString(allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Start", result);
}

test "PieceTable complex edit sequence" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "The quick brown fox");
    defer pt.deinit();

    try pt.insert(4, "very ");
    try pt.delete(15, 6);
    try pt.insert(15, "red ");

    const result = try pt.toString(allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("The very quick red fox", result);
}

test "PieceTable iterateContent callback" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "ABC");
    defer pt.deinit();

    const Context = struct {
        count: usize = 0,

        fn callback(ctx: *@This(), offset: usize, c: u8) bool {
            _ = offset;
            _ = c;
            ctx.count += 1;
            return false;
        }
    };

    var ctx = Context{};
    pt.iterateContent(&ctx, Context.callback);

    try std.testing.expectEqual(@as(usize, 3), ctx.count);
}

test "PieceTable iterateContent early break" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "ABCDEF");
    defer pt.deinit();

    const Context = struct {
        count: usize = 0,

        fn callback(ctx: *@This(), offset: usize, c: u8) bool {
            _ = offset;
            _ = c;
            ctx.count += 1;
            return ctx.count >= 3;
        }
    };

    var ctx = Context{};
    pt.iterateContent(&ctx, Context.callback);

    try std.testing.expectEqual(@as(usize, 3), ctx.count);
}

test "PieceTable alternating insert and delete" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "Start");
    defer pt.deinit();

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try pt.insert(5, "X");
        try pt.delete(5, 1);
    }

    const result = try pt.toString(allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Start", result);
}

test "PieceTable many small inserts" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "");
    defer pt.deinit();

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try pt.insert(i, "a");
    }

    try std.testing.expectEqual(@as(usize, 100), pt.totalLength());

    const result = try pt.toString(allocator);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 100), result.len);
}

test "PieceTable insert then delete in reverse" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "");
    defer pt.deinit();

    try pt.insert(0, "A");
    try pt.insert(1, "B");
    try pt.insert(2, "C");
    try pt.insert(3, "D");

    try pt.delete(3, 1);
    try pt.delete(2, 1);
    try pt.delete(1, 1);
    try pt.delete(0, 1);

    try std.testing.expectEqual(@as(usize, 0), pt.totalLength());
}

test "PieceTable getVisibleLines with many lines" {
    const allocator = std.testing.allocator;

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const writer = &aw.writer;

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        try writer.print("Line {d}\n", .{i});
    }

    var pt = PieceTable.init(allocator, aw.written());
    defer pt.deinit();

    const lines = try pt.getVisibleLines(allocator, 500, 10);
    defer {
        for (lines) |line| allocator.free(line);
        allocator.free(lines);
    }

    try std.testing.expectEqual(@as(usize, 10), lines.len);
}

test "PieceTable find across piece boundaries" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "Hello");
    defer pt.deinit();

    try pt.insert(2, "XX");

    const pos = try pt.find("HeXXllo", 0);
    try std.testing.expectEqual(@as(usize, 0), pos.?);
}

test "PieceTable multiple deletes creating gaps" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "ABCDEFGHIJ");
    defer pt.deinit();

    try pt.delete(8, 1);
    try pt.delete(6, 1);
    try pt.delete(4, 1);
    try pt.delete(2, 1);
    try pt.delete(0, 1);

    const result = try pt.toString(allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("BDFHJ", result);
}

test "PieceTable insert at every position" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "ABC");
    defer pt.deinit();

    try pt.insert(0, "X");
    try pt.insert(2, "X");
    try pt.insert(4, "X");
    try pt.insert(6, "X");

    const result = try pt.toString(allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("XAXBXCX", result);
}

test "PieceTable cache consistency after edits" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "Line1\nLine2\nLine3");
    defer pt.deinit();

    const initial_lines = pt.lineCount();
    try std.testing.expectEqual(@as(usize, 3), initial_lines);

    try pt.insert(17, "\nLine4");
    try std.testing.expectEqual(@as(usize, 4), pt.lineCount());

    try pt.delete(12, 6);
    try std.testing.expectEqual(@as(usize, 3), pt.lineCount());
}

test "PieceTable find with offset beyond match" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "Hello World Hello");
    defer pt.deinit();

    const pos = try pt.find("Hello", 6);
    try std.testing.expectEqual(@as(usize, 12), pos.?);
}

test "PieceTable delete spanning multiple pieces" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "AAAAA");
    defer pt.deinit();

    try pt.insert(2, "BBB");
    try pt.insert(5, "CCC");

    try pt.delete(1, 8);

    const result = try pt.toString(allocator);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 3), result.len);
}

test "PieceTable empty buffer operations" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "");
    defer pt.deinit();

    try std.testing.expectEqual(@as(usize, 0), pt.totalLength());
    try std.testing.expect(pt.getCharAt(0) == null);

    const lines = try pt.getVisibleLines(allocator, 0, 10);
    defer {
        for (lines) |line| allocator.free(line);
        allocator.free(lines);
    }
    try std.testing.expectEqual(@as(usize, 1), lines.len);
}

test "PieceTable newline handling" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "A\n\nB");
    defer pt.deinit();

    try std.testing.expectEqual(@as(usize, 3), pt.lineCount());

    try pt.insert(2, "X");
    try std.testing.expectEqual(@as(usize, 3), pt.lineCount());

    try pt.insert(3, "\n");
    try std.testing.expectEqual(@as(usize, 4), pt.lineCount());
}

test "PieceTable findLast boundary" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "AAA BBB AAA");
    defer pt.deinit();

    const pos = try pt.findLast("AAA", 11);
    try std.testing.expectEqual(@as(usize, 8), pos.?);

    const pos2 = try pt.findLast("AAA", 8);
    try std.testing.expectEqual(@as(usize, 0), pos2.?);
}

test "PieceTable consecutive edits at same position" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "Start End");
    defer pt.deinit();

    try pt.insert(6, "A");
    try pt.insert(6, "B");
    try pt.insert(6, "C");

    const result = try pt.toString(allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Start CBAEnd", result);
}

test "PieceTable getVisibleLines requesting more than available" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "Line 1\nLine 2\nLine 3");
    defer pt.deinit();

    const lines = try pt.getVisibleLines(allocator, 0, 100);
    defer {
        for (lines) |line| allocator.free(line);
        allocator.free(lines);
    }

    try std.testing.expectEqual(@as(usize, 3), lines.len);
}

test "PieceTable getVisibleLines at exact line boundary" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "Line 1\nLine 2\nLine 3");
    defer pt.deinit();

    const line_count = pt.lineCount();
    const lines = try pt.getVisibleLines(allocator, line_count - 1, 1);
    defer {
        for (lines) |line| allocator.free(line);
        allocator.free(lines);
    }

    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expectEqualStrings("Line 3", lines[0]);
}

test "PieceTable insert beyond buffer length behavior" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "Hello");
    defer pt.deinit();

    try pt.insert(100, " World");

    try std.testing.expectEqual(@as(usize, 5), pt.totalLength());
}

test "PieceTable delete beyond buffer end is safe" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "Hello");
    defer pt.deinit();

    try pt.delete(0, 1000);

    const result = try pt.toString(allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "PieceTable very long single line without newlines" {
    const allocator = std.testing.allocator;

    const long_line = "x" ** 10000;
    var pt = PieceTable.init(allocator, long_line);
    defer pt.deinit();

    try std.testing.expectEqual(@as(usize, 1), pt.lineCount());
    try std.testing.expectEqual(@as(usize, 10000), pt.totalLength());

    try pt.insert(5000, "MIDDLE");
    try std.testing.expectEqual(@as(usize, 10006), pt.totalLength());
    try std.testing.expectEqual(@as(usize, 1), pt.lineCount());
}

test "PieceTable paste large content at end of file" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "Start\n");
    defer pt.deinit();

    const large_paste = "Pasted line\n" ** 100;
    try pt.insert(pt.totalLength(), large_paste);

    try std.testing.expectEqual(@as(usize, 102), pt.lineCount());
}

test "PieceTable rapid typing simulation" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "");
    defer pt.deinit();

    const phrase = "The quick brown fox jumps over the lazy dog.";
    for (phrase, 0..) |c, i| {
        try pt.insert(i, &[_]u8{c});
    }

    const result = try pt.toString(allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(phrase, result);
}

test "PieceTable backspace at position 0 is safe" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "Hello");
    defer pt.deinit();

    try pt.delete(0, 0);

    const result = try pt.toString(allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello", result);
}

test "PieceTable delete single char from empty string" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "");
    defer pt.deinit();

    try pt.delete(0, 1);
    try std.testing.expectEqual(@as(usize, 0), pt.totalLength());
}

test "PieceTable consecutive newlines" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "\n\n\n\n\n");
    defer pt.deinit();

    try std.testing.expectEqual(@as(usize, 6), pt.lineCount());

    try pt.insert(2, "Content");
    try std.testing.expectEqual(@as(usize, 6), pt.lineCount());
}

test "PieceTable trailing newline handling" {
    const allocator = std.testing.allocator;

    var pt_with = PieceTable.init(allocator, "Line1\nLine2\n");
    defer pt_with.deinit();
    try std.testing.expectEqual(@as(usize, 3), pt_with.lineCount());

    var pt_without = PieceTable.init(allocator, "Line1\nLine2");
    defer pt_without.deinit();
    try std.testing.expectEqual(@as(usize, 2), pt_without.lineCount());
}

test "PieceTable position calculations with multi-byte UTF8" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "Hello 🌍 World");
    defer pt.deinit();

    const pos = pt.getPositionAtOffset(11);
    try std.testing.expectEqual(@as(usize, 0), pos.row);

    try pt.insert(11, "Beautiful ");
    const result = try pt.toString(allocator);
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "Beautiful") != null);
}

test "PieceTable getLineStartOffset edge cases" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "Line1\nLine2\nLine3");
    defer pt.deinit();

    try std.testing.expectEqual(@as(usize, 0), pt.getLineStartOffset(0));
    try std.testing.expectEqual(@as(usize, 6), pt.getLineStartOffset(1));
    try std.testing.expectEqual(@as(usize, 12), pt.getLineStartOffset(2));
    const beyond = pt.getLineStartOffset(100);
    try std.testing.expectEqual(@as(usize, 17), beyond);
}

test "PieceTable getOffsetForPosition out of bounds" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "Short\nLine");
    defer pt.deinit();

    const offset = pt.getOffsetForPosition(0, 100);
    try std.testing.expectEqual(@as(usize, 5), offset);
}

// ---------- Property tests ----------
//
// These compare PieceTable behavior against a naive ArrayList-of-bytes model
// across random sequences of insert/delete operations. Catches edge cases
// (zero-length ops, boundary splits, deletions that span pieces) that hand-
// written tests miss.

test "PieceTable property: random insert/delete matches naive model" {
    const allocator = std.testing.allocator;
    const ops = 200;
    const max_initial = 32;
    const max_insert = 16;

    // Seed the RNG deterministically so failures reproduce.
    var prng = std.Random.DefaultPrng.init(0xCAFEBABE_DEADBEEF);
    const rand = prng.random();

    // Random initial content.
    const initial_len = rand.intRangeLessThan(usize, 0, max_initial);
    const initial = try allocator.alloc(u8, initial_len);
    defer allocator.free(initial);
    for (initial) |*b| b.* = rand.intRangeAtMost(u8, 'a', 'z');

    var pt = PieceTable.init(allocator, initial);
    defer pt.deinit();

    var model: std.ArrayListUnmanaged(u8) = .empty;
    defer model.deinit(allocator);
    try model.appendSlice(allocator, initial);

    var op: usize = 0;
    while (op < ops) : (op += 1) {
        const insert_op = rand.boolean() or model.items.len == 0;

        if (insert_op) {
            const offset = rand.intRangeAtMost(usize, 0, model.items.len);
            const ins_len = rand.intRangeAtMost(usize, 0, max_insert);
            const text = try allocator.alloc(u8, ins_len);
            defer allocator.free(text);
            for (text) |*b| b.* = rand.intRangeAtMost(u8, 'A', 'Z');

            try pt.insert(offset, text);
            try model.insertSlice(allocator, offset, text);
        } else {
            const offset = rand.intRangeLessThan(usize, 0, model.items.len);
            const max_del = model.items.len - offset;
            const del_len = rand.intRangeAtMost(usize, 0, max_del);
            try pt.delete(offset, del_len);
            for (0..del_len) |_| _ = model.orderedRemove(offset);
        }

        // Invariant: piece-table content matches the model after every op.
        try std.testing.expectEqual(model.items.len, pt.totalLength());
        const pt_str = try pt.toString(allocator);
        defer allocator.free(pt_str);
        try std.testing.expectEqualSlices(u8, model.items, pt_str);
    }
}

test "PieceTable property: insert then delete back to original" {
    const allocator = std.testing.allocator;
    var pt = PieceTable.init(allocator, "hello");
    defer pt.deinit();

    // Insert "X" at a bunch of positions, then verify deleting them all
    // restores the original content. Positions chosen to exercise several
    // pieces and a tail insert.
    try pt.insert(0, "X");
    try pt.insert(3, "X"); // after "Xhe"
    try pt.insert(6, "X"); // after "XheXll"
    try pt.insert(8, "X"); // after "XheXllXo"

    const s_full = try pt.toString(allocator);
    defer allocator.free(s_full);
    try std.testing.expectEqualStrings("XheXllXoX", s_full);

    // Delete each X in reverse offset order so earlier deletes don't
    // shift later offsets.
    const x_offsets = [_]usize{ 8, 6, 3, 0 };
    for (x_offsets) |off| try pt.delete(off, 1);

    const s_back = try pt.toString(allocator);
    defer allocator.free(s_back);
    try std.testing.expectEqualStrings("hello", s_back);
}
