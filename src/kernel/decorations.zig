const std = @import("std");

pub const DecorationKind = enum {
    search_match,
    search_current,
    matching_bracket,

    git_added,
    git_modified,
    git_deleted,

    error_squiggle,
    warning_squiggle,
    info_squiggle,
    hint_squiggle,

    ghost_text,
    highlight,
    bookmark,

    word_highlight,
    semantic_highlight,

    build_error,
    build_warning,
    build_note,

    diff_added_line,
    diff_deleted_line,
    diff_changed_line,

    pub fn toColor(self: DecorationKind) struct { fg: ?u24, bg: ?u24 } {
        return switch (self) {
            .search_match => .{ .fg = null, .bg = 0x3B3B00 },
            .search_current => .{ .fg = null, .bg = 0x5A5A00 },
            .matching_bracket => .{ .fg = null, .bg = 0x264F78 },
            .git_added => .{ .fg = 0x00FF00, .bg = null },
            .git_modified => .{ .fg = 0xFFFF00, .bg = null },
            .git_deleted => .{ .fg = 0xFF0000, .bg = null },
            .error_squiggle => .{ .fg = 0xFF6B6B, .bg = null },
            .warning_squiggle => .{ .fg = 0xFFD93D, .bg = null },
            .info_squiggle => .{ .fg = 0x6BCB77, .bg = null },
            .hint_squiggle => .{ .fg = 0x888888, .bg = null },
            .ghost_text => .{ .fg = 0x666666, .bg = null },
            .highlight => .{ .fg = null, .bg = 0x4A4A4A },
            .bookmark => .{ .fg = 0x00BFFF, .bg = null },
            .word_highlight => .{ .fg = null, .bg = 0x3A3A3A },
            .semantic_highlight => .{ .fg = null, .bg = null },
            .build_error => .{ .fg = 0xFF4444, .bg = 0x3D1A1A },
            .build_warning => .{ .fg = 0xFFAA00, .bg = 0x3D3D1A },
            .build_note => .{ .fg = 0x44AAFF, .bg = 0x1A2A3D },
            .diff_added_line => .{ .fg = 0xAAFFAA, .bg = 0x1A3D1A },
            .diff_deleted_line => .{ .fg = 0xFFAAAA, .bg = 0x3D1A1A },
            .diff_changed_line => .{ .fg = 0xFFFFAA, .bg = 0x3D3D1A },
        };
    }

    pub fn isGutterDecoration(self: DecorationKind) bool {
        return switch (self) {
            .git_added, .git_modified, .git_deleted, .bookmark => true,
            .build_error, .build_warning, .build_note => true,
            else => false,
        };
    }
};

pub const Range = struct {
    start_row: usize,
    start_col: usize,
    end_row: usize,
    end_col: usize,

    pub fn contains(self: Range, row: usize, col: usize) bool {
        if (row < self.start_row or row > self.end_row) return false;
        if (row == self.start_row and col < self.start_col) return false;
        if (row == self.end_row and col >= self.end_col) return false;
        return true;
    }

    pub fn overlapsLine(self: Range, line: usize) bool {
        return line >= self.start_row and line <= self.end_row;
    }

    pub fn overlaps(self: Range, other: Range) bool {
        if (self.end_row < other.start_row) return false;
        if (other.end_row < self.start_row) return false;
        if (self.end_row == other.start_row and self.end_col <= other.start_col) return false;
        if (other.end_row == self.start_row and other.end_col <= self.start_col) return false;
        return true;
    }

    pub fn singleLine(row: usize, start_col: usize, end_col: usize) Range {
        return Range{
            .start_row = row,
            .start_col = start_col,
            .end_row = row,
            .end_col = end_col,
        };
    }

    pub fn fullLine(row: usize) Range {
        return Range{
            .start_row = row,
            .start_col = 0,
            .end_row = row,
            .end_col = std.math.maxInt(usize),
        };
    }
};

pub const Decoration = struct {
    id: u64,
    range: Range,
    kind: DecorationKind,
    priority: u8,
    tooltip: ?[]const u8,
    source: ?[]const u8,
};

pub const DecorationSnapshot = struct {
    id: u64,
    range: Range,
    kind: DecorationKind,
    priority: u8,
};

pub const DecorationManager = struct {
    allocator: std.mem.Allocator,
    decorations: std.ArrayListUnmanaged(Decoration),
    next_id: u64,

    pub fn init(allocator: std.mem.Allocator) DecorationManager {
        return DecorationManager{
            .allocator = allocator,
            .decorations = .empty,
            .next_id = 1,
        };
    }

    pub fn deinit(self: *DecorationManager) void {
        for (self.decorations.items) |dec| {
            if (dec.tooltip) |t| self.allocator.free(t);
            if (dec.source) |s| self.allocator.free(s);
        }
        self.decorations.deinit(self.allocator);
    }

    pub fn add(
        self: *DecorationManager,
        range: Range,
        kind: DecorationKind,
        priority: u8,
        tooltip: ?[]const u8,
        source: ?[]const u8,
    ) !u64 {
        const id = self.next_id;
        self.next_id += 1;

        const tooltip_copy = if (tooltip) |t| try self.allocator.dupe(u8, t) else null;
        errdefer if (tooltip_copy) |t| self.allocator.free(t);

        const source_copy = if (source) |s| try self.allocator.dupe(u8, s) else null;
        errdefer if (source_copy) |s| self.allocator.free(s);

        try self.decorations.append(self.allocator, Decoration{
            .id = id,
            .range = range,
            .kind = kind,
            .priority = priority,
            .tooltip = tooltip_copy,
            .source = source_copy,
        });

        return id;
    }

    pub fn remove(self: *DecorationManager, id: u64) void {
        var i: usize = 0;
        while (i < self.decorations.items.len) {
            const dec = self.decorations.items[i];
            if (dec.id == id) {
                if (dec.tooltip) |t| self.allocator.free(t);
                if (dec.source) |s| self.allocator.free(s);
                _ = self.decorations.orderedRemove(i);
                return;
            }
            i += 1;
        }
    }

    pub fn removeByKind(self: *DecorationManager, kind: DecorationKind) void {
        var i: usize = 0;
        while (i < self.decorations.items.len) {
            const dec = self.decorations.items[i];
            if (dec.kind == kind) {
                if (dec.tooltip) |t| self.allocator.free(t);
                if (dec.source) |s| self.allocator.free(s);
                _ = self.decorations.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    pub fn removeBySource(self: *DecorationManager, source: []const u8) void {
        var i: usize = 0;
        while (i < self.decorations.items.len) {
            const dec = self.decorations.items[i];
            if (dec.source) |s| {
                if (std.mem.eql(u8, s, source)) {
                    if (dec.tooltip) |t| self.allocator.free(t);
                    self.allocator.free(s);
                    _ = self.decorations.orderedRemove(i);
                    continue;
                }
            }
            i += 1;
        }
    }

    pub fn getForLine(self: *DecorationManager, line: usize, allocator: std.mem.Allocator) ![]DecorationSnapshot {
        var results = std.ArrayListUnmanaged(DecorationSnapshot).empty;
        errdefer results.deinit(allocator);

        for (self.decorations.items) |dec| {
            if (dec.range.overlapsLine(line)) {
                try results.append(allocator, .{
                    .id = dec.id,
                    .range = dec.range,
                    .kind = dec.kind,
                    .priority = dec.priority,
                });
            }
        }

        std.sort.block(DecorationSnapshot, results.items, {}, struct {
            fn cmp(_: void, a: DecorationSnapshot, b: DecorationSnapshot) bool {
                return a.priority > b.priority;
            }
        }.cmp);

        return results.toOwnedSlice(allocator);
    }

    pub fn getForRange(self: *DecorationManager, range: Range, allocator: std.mem.Allocator) ![]DecorationSnapshot {
        var results = std.ArrayListUnmanaged(DecorationSnapshot).empty;
        errdefer results.deinit(allocator);

        for (self.decorations.items) |dec| {
            if (dec.range.overlaps(range)) {
                try results.append(allocator, .{
                    .id = dec.id,
                    .range = dec.range,
                    .kind = dec.kind,
                    .priority = dec.priority,
                });
            }
        }

        return results.toOwnedSlice(allocator);
    }

    pub fn getForVisibleLines(
        self: *DecorationManager,
        start_line: usize,
        end_line: usize,
        allocator: std.mem.Allocator,
    ) ![]DecorationSnapshot {
        const range = Range{
            .start_row = start_line,
            .start_col = 0,
            .end_row = end_line,
            .end_col = std.math.maxInt(usize),
        };
        return self.getForRange(range, allocator);
    }

    pub fn clearAll(self: *DecorationManager) void {
        for (self.decorations.items) |dec| {
            if (dec.tooltip) |t| self.allocator.free(t);
            if (dec.source) |s| self.allocator.free(s);
        }
        self.decorations.clearRetainingCapacity();
    }

    pub fn count(self: *DecorationManager) usize {
        return self.decorations.items.len;
    }

    pub fn addSearchMatches(self: *DecorationManager, matches: []const Range, current_idx: ?usize) !void {
        self.removeByKind(.search_match);
        self.removeByKind(.search_current);

        for (matches, 0..) |range, i| {
            const kind: DecorationKind = if (current_idx != null and i == current_idx.?)
                .search_current
            else
                .search_match;

            _ = try self.add(range, kind, 100, null, "search");
        }
    }

    pub fn setCurrentSearchMatch(self: *DecorationManager, idx: usize) void {
        var match_count: usize = 0;
        for (self.decorations.items) |*dec| {
            if (dec.kind == .search_match or dec.kind == .search_current) {
                dec.kind = if (match_count == idx) .search_current else .search_match;
                match_count += 1;
            }
        }
    }

    pub fn addDiffDecorations(
        self: *DecorationManager,
        buffer_id: u32,
        added_lines: []const usize,
        deleted_lines: []const usize,
        changed_lines: []const usize,
    ) !void {
        _ = buffer_id;

        for (added_lines) |line| {
            _ = try self.add(
                Range.fullLine(line),
                .diff_added_line,
                50,
                null,
                "diff",
            );
        }

        for (deleted_lines) |line| {
            _ = try self.add(
                Range.fullLine(line),
                .diff_deleted_line,
                50,
                null,
                "diff",
            );
        }

        for (changed_lines) |line| {
            _ = try self.add(
                Range.fullLine(line),
                .diff_changed_line,
                50,
                null,
                "diff",
            );
        }
    }

    pub fn clearDiffDecorations(self: *DecorationManager) void {
        self.removeBySource("diff");
    }
};

test "decoration manager basic operations" {
    const allocator = std.testing.allocator;
    var dm = DecorationManager.init(allocator);
    defer dm.deinit();

    const id = try dm.add(
        Range.singleLine(5, 10, 20),
        .search_match,
        100,
        "Match 1 of 5",
        "search",
    );

    try std.testing.expectEqual(@as(usize, 1), dm.count());

    const line_decs = try dm.getForLine(5, allocator);
    defer allocator.free(line_decs);
    try std.testing.expectEqual(@as(usize, 1), line_decs.len);

    const empty_decs = try dm.getForLine(10, allocator);
    defer allocator.free(empty_decs);
    try std.testing.expectEqual(@as(usize, 0), empty_decs.len);

    dm.remove(id);
    try std.testing.expectEqual(@as(usize, 0), dm.count());
}

test "decoration range overlap detection" {
    const r1 = Range{ .start_row = 5, .start_col = 0, .end_row = 10, .end_col = 0 };
    const r2 = Range{ .start_row = 8, .start_col = 0, .end_row = 15, .end_col = 0 };
    const r3 = Range{ .start_row = 20, .start_col = 0, .end_row = 25, .end_col = 0 };

    try std.testing.expect(r1.overlaps(r2));
    try std.testing.expect(!r1.overlaps(r3));
    try std.testing.expect(r1.overlapsLine(7));
    try std.testing.expect(!r1.overlapsLine(15));
}

test "decoration range contains point" {
    const r = Range.singleLine(5, 10, 20);

    try std.testing.expect(r.contains(5, 10));
    try std.testing.expect(r.contains(5, 15));
    try std.testing.expect(!r.contains(5, 20));
    try std.testing.expect(!r.contains(5, 5));
    try std.testing.expect(!r.contains(4, 15));
    try std.testing.expect(!r.contains(6, 15));
}

test "decoration range multiline contains" {
    const r = Range{ .start_row = 5, .start_col = 10, .end_row = 7, .end_col = 15 };

    try std.testing.expect(r.contains(5, 10));
    try std.testing.expect(r.contains(5, 20));
    try std.testing.expect(r.contains(6, 0));
    try std.testing.expect(r.contains(6, 100));
    try std.testing.expect(r.contains(7, 0));
    try std.testing.expect(!r.contains(7, 15));
    try std.testing.expect(!r.contains(8, 0));
}

test "decoration range overlaps same line" {
    const r1 = Range.singleLine(5, 0, 10);
    const r2 = Range.singleLine(5, 5, 15);
    const r3 = Range.singleLine(5, 10, 20);
    const r4 = Range.singleLine(5, 20, 30);

    try std.testing.expect(r1.overlaps(r2));
    try std.testing.expect(!r1.overlaps(r3));
    try std.testing.expect(!r1.overlaps(r4));
}

test "decoration range overlaps multiline" {
    const r1 = Range{ .start_row = 5, .start_col = 0, .end_row = 7, .end_col = 10 };
    const r2 = Range{ .start_row = 6, .start_col = 0, .end_row = 8, .end_col = 10 };
    const r3 = Range{ .start_row = 8, .start_col = 0, .end_row = 10, .end_col = 10 };

    try std.testing.expect(r1.overlaps(r2));
    try std.testing.expect(!r1.overlaps(r3));
}

test "decoration manager multiple decorations same line" {
    const allocator = std.testing.allocator;
    var dm = DecorationManager.init(allocator);
    defer dm.deinit();

    _ = try dm.add(Range.singleLine(5, 0, 10), .search_match, 100, null, null);
    _ = try dm.add(Range.singleLine(5, 15, 25), .error_squiggle, 200, null, null);
    _ = try dm.add(Range.singleLine(5, 30, 40), .highlight, 50, null, null);

    const decs = try dm.getForLine(5, allocator);
    defer allocator.free(decs);

    try std.testing.expectEqual(@as(usize, 3), decs.len);
    try std.testing.expectEqual(@as(usize, 3), dm.count());
}

test "decoration manager remove by source" {
    const allocator = std.testing.allocator;
    var dm = DecorationManager.init(allocator);
    defer dm.deinit();

    _ = try dm.add(Range.singleLine(5, 0, 10), .search_match, 100, null, "search");
    _ = try dm.add(Range.singleLine(6, 0, 10), .search_match, 100, null, "search");
    _ = try dm.add(Range.singleLine(7, 0, 10), .error_squiggle, 100, null, "lsp");

    try std.testing.expectEqual(@as(usize, 3), dm.count());

    dm.removeBySource("search");

    try std.testing.expectEqual(@as(usize, 1), dm.count());
}

test "decoration manager remove by kind" {
    const allocator = std.testing.allocator;
    var dm = DecorationManager.init(allocator);
    defer dm.deinit();

    _ = try dm.add(Range.singleLine(5, 0, 10), .search_match, 100, null, null);
    _ = try dm.add(Range.singleLine(6, 0, 10), .search_match, 100, null, null);
    _ = try dm.add(Range.singleLine(7, 0, 10), .error_squiggle, 100, null, null);

    try std.testing.expectEqual(@as(usize, 3), dm.count());

    dm.removeByKind(.search_match);

    try std.testing.expectEqual(@as(usize, 1), dm.count());
}

test "decoration manager clear all" {
    const allocator = std.testing.allocator;
    var dm = DecorationManager.init(allocator);
    defer dm.deinit();

    _ = try dm.add(Range.singleLine(5, 0, 10), .search_match, 100, null, null);
    _ = try dm.add(Range.singleLine(6, 0, 10), .error_squiggle, 100, null, null);
    _ = try dm.add(Range.singleLine(7, 0, 10), .highlight, 100, null, null);

    try std.testing.expectEqual(@as(usize, 3), dm.count());

    dm.clearAll();

    try std.testing.expectEqual(@as(usize, 0), dm.count());
}

test "decoration manager get for range" {
    const allocator = std.testing.allocator;
    var dm = DecorationManager.init(allocator);
    defer dm.deinit();

    const id = try dm.add(Range.singleLine(5, 0, 10), .search_match, 100, "tooltip", "search");

    const range = Range{ .start_row = 0, .start_col = 0, .end_row = 10, .end_col = 0 };
    const snapshot = try dm.getForRange(range, allocator);
    defer allocator.free(snapshot);

    try std.testing.expectEqual(@as(usize, 1), snapshot.len);
    try std.testing.expectEqual(id, snapshot[0].id);
    try std.testing.expectEqual(DecorationKind.search_match, snapshot[0].kind);
}

test "decoration manager remove by ID" {
    const allocator = std.testing.allocator;
    var dm = DecorationManager.init(allocator);
    defer dm.deinit();

    const id = try dm.add(Range.singleLine(5, 0, 10), .search_match, 100, "tooltip", null);

    try std.testing.expectEqual(@as(usize, 1), dm.count());

    dm.remove(id);
    try std.testing.expectEqual(@as(usize, 0), dm.count());

    dm.remove(id);
    try std.testing.expectEqual(@as(usize, 0), dm.count());
}

test "decoration kind color mapping" {
    const search_color = DecorationKind.search_match.toColor();
    try std.testing.expect(search_color.bg != null);

    const error_color = DecorationKind.error_squiggle.toColor();
    try std.testing.expect(error_color.fg != null);
}

test "decoration kind gutter detection" {
    try std.testing.expect(DecorationKind.git_added.isGutterDecoration());
    try std.testing.expect(DecorationKind.git_modified.isGutterDecoration());
    try std.testing.expect(DecorationKind.bookmark.isGutterDecoration());

    try std.testing.expect(!DecorationKind.search_match.isGutterDecoration());
    try std.testing.expect(!DecorationKind.error_squiggle.isGutterDecoration());
}

test "decoration manager empty state" {
    const allocator = std.testing.allocator;
    var dm = DecorationManager.init(allocator);
    defer dm.deinit();

    try std.testing.expectEqual(@as(usize, 0), dm.count());

    const decs = try dm.getForLine(0, allocator);
    defer allocator.free(decs);
    try std.testing.expectEqual(@as(usize, 0), decs.len);

    const range = Range{ .start_row = 0, .start_col = 0, .end_row = 10, .end_col = 0 };
    const range_decs = try dm.getForRange(range, allocator);
    defer allocator.free(range_decs);
    try std.testing.expectEqual(@as(usize, 0), range_decs.len);
}

test "decoration manager remove nonexistent ID" {
    const allocator = std.testing.allocator;
    var dm = DecorationManager.init(allocator);
    defer dm.deinit();

    dm.remove(999);
    try std.testing.expectEqual(@as(usize, 0), dm.count());
}

test "decoration range singleLine helper" {
    const r = Range.singleLine(10, 5, 15);

    try std.testing.expectEqual(@as(usize, 10), r.start_row);
    try std.testing.expectEqual(@as(usize, 5), r.start_col);
    try std.testing.expectEqual(@as(usize, 10), r.end_row);
    try std.testing.expectEqual(@as(usize, 15), r.end_col);
}

test "decoration manager priority ordering" {
    const allocator = std.testing.allocator;
    var dm = DecorationManager.init(allocator);
    defer dm.deinit();

    _ = try dm.add(Range.singleLine(5, 0, 10), .search_match, 50, null, null);
    _ = try dm.add(Range.singleLine(5, 0, 10), .error_squiggle, 200, null, null);
    _ = try dm.add(Range.singleLine(5, 0, 10), .highlight, 10, null, null);

    const decs = try dm.getForLine(5, allocator);
    defer allocator.free(decs);

    try std.testing.expectEqual(@as(usize, 3), decs.len);
}

test "decoration manager with tooltip" {
    const allocator = std.testing.allocator;
    var dm = DecorationManager.init(allocator);
    defer dm.deinit();

    _ = try dm.add(Range.singleLine(5, 0, 10), .error_squiggle, 100, "This is an error", "lsp");

    try std.testing.expectEqual(@as(usize, 1), dm.count());

    const decs = try dm.getForLine(5, allocator);
    defer allocator.free(decs);

    try std.testing.expectEqual(@as(usize, 1), decs.len);
    try std.testing.expectEqual(DecorationKind.error_squiggle, decs[0].kind);
}

test "decoration manager addSearchMatches" {
    const allocator = std.testing.allocator;
    var dm = DecorationManager.init(allocator);
    defer dm.deinit();

    const matches = [_]Range{
        Range.singleLine(1, 0, 5),
        Range.singleLine(3, 10, 15),
        Range.singleLine(5, 20, 25),
    };

    try dm.addSearchMatches(&matches, 1);

    try std.testing.expectEqual(@as(usize, 3), dm.count());

    const decs = try dm.getForLine(3, allocator);
    defer allocator.free(decs);

    try std.testing.expectEqual(@as(usize, 1), decs.len);
    try std.testing.expectEqual(DecorationKind.search_current, decs[0].kind);
}

test "decoration manager setCurrentSearchMatch" {
    const allocator = std.testing.allocator;
    var dm = DecorationManager.init(allocator);
    defer dm.deinit();

    const matches = [_]Range{
        Range.singleLine(1, 0, 5),
        Range.singleLine(3, 10, 15),
    };

    try dm.addSearchMatches(&matches, 0);

    dm.setCurrentSearchMatch(1);

    const decs = try dm.getForLine(3, allocator);
    defer allocator.free(decs);

    try std.testing.expectEqual(@as(usize, 1), decs.len);
    try std.testing.expectEqual(DecorationKind.search_current, decs[0].kind);
}

test "decoration manager getForVisibleLines" {
    const allocator = std.testing.allocator;
    var dm = DecorationManager.init(allocator);
    defer dm.deinit();

    _ = try dm.add(Range.singleLine(5, 0, 10), .search_match, 100, null, null);
    _ = try dm.add(Range.singleLine(10, 0, 10), .error_squiggle, 100, null, null);
    _ = try dm.add(Range.singleLine(15, 0, 10), .highlight, 100, null, null);

    const decs = try dm.getForVisibleLines(5, 10, allocator);
    defer allocator.free(decs);

    try std.testing.expectEqual(@as(usize, 2), decs.len);
}
