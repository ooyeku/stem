const std = @import("std");
const vaxis = @import("vaxis");
const theme = @import("theme.zig");
const width_utils = @import("width.zig");

const p = theme.colors.palette;

const Styles = struct {
    pub const background: vaxis.Cell.Style = .{
        .fg = .{ .index = p.white },
        .bg = .{ .index = p.black },
    };
    pub const title: vaxis.Cell.Style = .{
        .fg = .{ .index = p.bright_white },
        .bg = .{ .index = p.blue },
        .bold = true,
    };
    pub const title_hint: vaxis.Cell.Style = .{
        .fg = .{ .index = p.bright_cyan },
        .bg = .{ .index = p.blue },
        .bold = true,
    };
    pub const section: vaxis.Cell.Style = .{
        .fg = .{ .index = p.bright_cyan },
        .bg = .{ .index = p.black },
        .bold = true,
    };
    pub const subsection: vaxis.Cell.Style = .{
        .fg = .{ .index = p.bright_yellow },
        .bg = .{ .index = p.black },
        .bold = true,
    };
    pub const label: vaxis.Cell.Style = .{
        .fg = .{ .index = p.cyan },
        .bg = .{ .index = p.black },
        .bold = true,
    };
    pub const value: vaxis.Cell.Style = .{
        .fg = .{ .index = p.bright_white },
        .bg = .{ .index = p.black },
    };
    pub const text: vaxis.Cell.Style = .{
        .fg = .{ .index = p.white },
        .bg = .{ .index = p.black },
    };
    pub const accent: vaxis.Cell.Style = .{
        .fg = .{ .index = p.blue },
        .bg = .{ .index = p.black },
        .bold = true,
    };
    pub const code: vaxis.Cell.Style = .{
        .fg = .{ .index = p.green },
        .bg = .{ .index = p.black },
        .bold = true,
    };
    pub const table_header: vaxis.Cell.Style = .{
        .fg = .{ .index = p.black },
        .bg = .{ .index = p.cyan },
        .bold = true,
    };
    pub const table_cell: vaxis.Cell.Style = .{
        .fg = .{ .index = p.bright_white },
        .bg = .{ .index = p.black },
    };
    pub const table_edge: vaxis.Cell.Style = .{
        .fg = .{ .index = p.bright_black },
        .bg = .{ .index = p.black },
    };
    pub const diff_add: vaxis.Cell.Style = .{
        .fg = .{ .index = p.bright_green },
        .bg = .{ .index = p.black },
        .bold = true,
    };
    pub const diff_remove: vaxis.Cell.Style = .{
        .fg = .{ .index = p.bright_red },
        .bg = .{ .index = p.black },
        .bold = true,
    };
    pub const diff_meta: vaxis.Cell.Style = .{
        .fg = .{ .index = p.bright_yellow },
        .bg = .{ .index = p.black },
        .bold = true,
    };
};

pub const MarkdownView = struct {
    pub fn init(allocator: std.mem.Allocator) MarkdownView {
        _ = allocator;
        return .{};
    }

    pub fn draw(
        self: *MarkdownView,
        win: vaxis.Window,
        lines: []const []const u8,
        scroll_offset: usize,
    ) !void {
        _ = self;
        _ = scroll_offset;
        if (win.width == 0 or win.height == 0) return;

        clear(win);

        var row: u16 = 0;
        var table_row_index: usize = 0;
        var in_fence = false;

        for (lines) |line| {
            if (row >= win.height) break;

            const display_line = trimTrailingCarriageReturn(line);
            const trimmed = std.mem.trim(u8, display_line, " \t");
            if (!isTableLine(trimmed)) table_row_index = 0;

            if (trimmed.len == 0) {
                row += 1;
                continue;
            }

            if (std.mem.startsWith(u8, trimmed, "```")) {
                in_fence = !in_fence;
                drawDivider(win, row, Styles.table_edge);
                row += 1;
                continue;
            }

            if (in_fence) {
                renderInline(win, row, 3, display_line, Styles.code);
                row += 1;
                continue;
            }

            if (std.mem.startsWith(u8, trimmed, "# ")) {
                renderTitle(win, row, trimmed[2..]);
            } else if (std.mem.startsWith(u8, trimmed, "## ")) {
                if (row > 0) drawSoftDivider(win, row);
                renderInline(win, row, 2, trimmed[3..], Styles.section);
            } else if (std.mem.startsWith(u8, trimmed, "### ")) {
                renderInline(win, row, 3, trimmed[4..], Styles.subsection);
            } else if (isDivider(trimmed)) {
                drawDivider(win, row, Styles.table_edge);
            } else if (isTableLine(trimmed)) {
                renderTableRow(win, row, trimmed, table_row_index);
                table_row_index += 1;
            } else if (isDiffMeta(trimmed)) {
                renderInline(win, row, 1, trimmed, Styles.diff_meta);
            } else if (isDiffAdd(trimmed)) {
                renderInline(win, row, 1, trimmed, Styles.diff_add);
            } else if (isDiffRemove(trimmed)) {
                renderInline(win, row, 1, trimmed, Styles.diff_remove);
            } else if (std.mem.startsWith(u8, trimmed, "- ") or std.mem.startsWith(u8, trimmed, "* ")) {
                renderListItem(win, row, trimmed[2..]);
            } else if (looksLikeKeyValue(trimmed)) {
                renderKeyValue(win, row, trimmed, 2);
            } else {
                renderInline(win, row, 2, display_line, Styles.text);
            }

            row += 1;
        }
    }

    fn clear(win: vaxis.Window) void {
        for (0..win.height) |r| {
            for (0..win.width) |c| {
                _ = win.printSegment(.{ .text = " ", .style = Styles.background }, .{
                    .row_offset = @intCast(r),
                    .col_offset = @intCast(c),
                });
            }
        }
    }

    fn renderTitle(win: vaxis.Window, row: u16, text: []const u8) void {
        for (0..win.width) |c| {
            _ = win.printSegment(.{ .text = " ", .style = Styles.title }, .{
                .row_offset = row,
                .col_offset = @intCast(c),
            });
        }
        printAt(win, row, 1, "VIEW", Styles.title_hint);
        printAt(win, row, 8, text, Styles.title);
    }

    fn renderListItem(win: vaxis.Window, row: u16, text: []const u8) void {
        printAt(win, row, 2, ">", Styles.accent);
        if (std.mem.indexOfScalar(u8, text, ':')) |_| {
            renderKeyValue(win, row, text, 4);
        } else {
            renderInline(win, row, 4, text, Styles.text);
        }
    }

    fn renderKeyValue(win: vaxis.Window, row: u16, text: []const u8, start_col: u16) void {
        const colon = std.mem.indexOfScalar(u8, text, ':') orelse {
            renderInline(win, row, start_col, text, Styles.text);
            return;
        };
        const label = std.mem.trim(u8, text[0..colon], " \t");
        const value = std.mem.trim(u8, text[colon + 1 ..], " \t");
        var col = start_col;
        printAt(win, row, col, label, Styles.label);
        col = advance(col, label);
        printAt(win, row, col, ":", Styles.table_edge);
        col += 2;
        renderInline(win, row, col, value, Styles.value);
    }

    fn renderTableRow(win: vaxis.Window, row: u16, line: []const u8, row_index: usize) void {
        if (isTableSeparator(line)) {
            drawSoftDivider(win, row);
            return;
        }

        const style = if (row_index == 0) Styles.table_header else Styles.table_cell;
        var body = line;
        if (body.len > 0 and body[0] == '|') body = body[1..];
        if (body.len > 0 and body[body.len - 1] == '|') body = body[0 .. body.len - 1];

        var col: u16 = 2;
        printAt(win, row, col, "|", Styles.table_edge);
        col += 2;

        var parts = std.mem.splitScalar(u8, body, '|');
        while (parts.next()) |part| {
            if (col >= win.width) break;
            const cell = std.mem.trim(u8, part, " \t");
            renderInline(win, row, col, cell, style);
            col = advance(col, cell);
            if (col + 3 >= win.width) break;
            printAt(win, row, col + 1, "|", Styles.table_edge);
            col += 3;
        }
    }

    fn drawDivider(win: vaxis.Window, row: u16, style: vaxis.Cell.Style) void {
        const start: u16 = 2;
        var col = start;
        while (col < win.width) : (col += 1) {
            _ = win.printSegment(.{ .text = "-", .style = style }, .{
                .row_offset = row,
                .col_offset = col,
            });
        }
    }

    fn drawSoftDivider(win: vaxis.Window, row: u16) void {
        const start: u16 = 2;
        var col = start;
        while (col < win.width) : (col += 1) {
            _ = win.printSegment(.{ .text = ".", .style = Styles.table_edge }, .{
                .row_offset = row,
                .col_offset = col,
            });
        }
    }

    fn renderInline(win: vaxis.Window, row: u16, start_col: u16, text: []const u8, base_style: vaxis.Cell.Style) void {
        var col = start_col;
        var rest = text;
        var code = false;

        while (rest.len > 0) {
            const tick = std.mem.indexOfScalar(u8, rest, '`') orelse {
                printAt(win, row, col, rest, if (code) Styles.code else base_style);
                return;
            };

            if (tick > 0) {
                const segment = rest[0..tick];
                printAt(win, row, col, segment, if (code) Styles.code else base_style);
                col = advance(col, segment);
            }

            code = !code;
            rest = rest[tick + 1 ..];
        }
    }

    fn printAt(win: vaxis.Window, row: u16, col: u16, text: []const u8, style: vaxis.Cell.Style) void {
        if (row >= win.height or col >= win.width or text.len == 0) return;
        _ = win.printSegment(.{ .text = text, .style = style }, .{
            .row_offset = row,
            .col_offset = col,
        });
    }

    fn trimTrailingCarriageReturn(line: []const u8) []const u8 {
        if (line.len == 0 or line[line.len - 1] != '\r') return line;
        return line[0 .. line.len - 1];
    }

    fn advance(col: u16, text: []const u8) u16 {
        const width = width_utils.displayWidth(text, 4);
        return @intCast(@min(@as(usize, std.math.maxInt(u16)), @as(usize, col) + width));
    }

    fn isDivider(line: []const u8) bool {
        return std.mem.eql(u8, line, "---") or
            std.mem.eql(u8, line, "***") or
            std.mem.eql(u8, line, "___");
    }

    fn isTableLine(line: []const u8) bool {
        return line.len >= 3 and line[0] == '|' and line[line.len - 1] == '|';
    }

    fn isTableSeparator(line: []const u8) bool {
        if (!isTableLine(line)) return false;
        for (line) |c| {
            switch (c) {
                '|', '-', ':', ' ' => {},
                else => return false,
            }
        }
        return true;
    }

    fn looksLikeKeyValue(line: []const u8) bool {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return false;
        if (colon == 0 or colon > 36) return false;
        if (std.mem.indexOfAny(u8, line[0..colon], "`[]{}()")) |_| return false;
        return true;
    }

    fn isDiffAdd(line: []const u8) bool {
        return line.len > 0 and line[0] == '+' and
            !std.mem.startsWith(u8, line, "+++") and
            !std.mem.startsWith(u8, line, "+--");
    }

    fn isDiffRemove(line: []const u8) bool {
        return line.len > 0 and line[0] == '-' and
            !std.mem.startsWith(u8, line, "---") and
            !std.mem.startsWith(u8, line, "->>");
    }

    fn isDiffMeta(line: []const u8) bool {
        return std.mem.startsWith(u8, line, "@@") or
            std.mem.startsWith(u8, line, "diff --git") or
            std.mem.startsWith(u8, line, "index ") or
            std.mem.startsWith(u8, line, "--- ") or
            std.mem.startsWith(u8, line, "+++ ");
    }
};
