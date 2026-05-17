const std = @import("std");
const vaxis = @import("vaxis");
const theme = @import("theme.zig");

const Colors = theme.styles.help;

pub const HelpView = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) HelpView {
        return .{ .allocator = allocator };
    }

    pub fn draw(
        self: *HelpView,
        win: vaxis.Window,
        lines: []const []const u8,
        scroll_offset: usize,
    ) !void {
        _ = self;

        const visible_height = win.height;
        var row: u16 = 0;

        _ = scroll_offset;

        for (lines) |line| {
            if (row >= visible_height) break;

            const trimmed = std.mem.trim(u8, line, " \t");

            if (std.mem.startsWith(u8, trimmed, "# ")) {
                renderLine(win, row, trimmed[2..], Colors.title);
            } else if (std.mem.startsWith(u8, trimmed, "### ")) {
                _ = win.printSegment(.{ .text = "  ", .style = Colors.separator }, .{ .row_offset = row });
                renderLineAt(win, row, 2, trimmed[4..], Colors.h3);
            } else if (std.mem.startsWith(u8, trimmed, "## ")) {
                const header_text = trimmed[3..];
                if (row > 0 and row + 1 < visible_height) {
                    for (0..win.width) |col| {
                        _ = win.printSegment(.{ .text = "─", .style = Colors.separator }, .{
                            .row_offset = row,
                            .col_offset = @intCast(col),
                        });
                    }
                    row += 1;
                }
                if (row >= visible_height) break;
                renderLine(win, row, header_text, Colors.h1);
            } else if (std.mem.startsWith(u8, trimmed, "- `")) {
                renderKeyBindingLine(win, row, trimmed);
            } else if (std.mem.startsWith(u8, trimmed, "- ")) {
                _ = win.printSegment(.{ .text = "  •", .style = Colors.bullet }, .{ .row_offset = row });
                renderLineAt(win, row, 4, trimmed[2..], Colors.desc);
            } else if (std.mem.startsWith(u8, trimmed, "Use ")) {
                _ = win.printSegment(.{ .text = "  ", .style = Colors.desc }, .{ .row_offset = row });
                renderLineAt(win, row, 2, trimmed, Colors.desc);
            } else if (trimmed.len == 0) {} else if (trimmed.len > 0 and trimmed[0] == '+' and !std.mem.startsWith(u8, trimmed, "+++") and !std.mem.startsWith(u8, trimmed, "+--")) {
                renderLine(win, row, trimmed, Colors.diff_add);
            } else if (trimmed.len > 0 and trimmed[0] == '-' and !std.mem.startsWith(u8, trimmed, "---") and !std.mem.startsWith(u8, trimmed, "->>")) {
                renderLine(win, row, trimmed, Colors.diff_remove);
            } else if (std.mem.startsWith(u8, trimmed, "@@")) {
                renderLine(win, row, trimmed, Colors.diff_hunk);
            } else if (std.mem.startsWith(u8, trimmed, "diff --git") or
                std.mem.startsWith(u8, trimmed, "index ") or
                std.mem.startsWith(u8, trimmed, "---") or
                std.mem.startsWith(u8, trimmed, "+++"))
            {
                renderLine(win, row, trimmed, Colors.diff_file);
            } else if (std.mem.startsWith(u8, trimmed, "+--") or std.mem.startsWith(u8, trimmed, "|")) {
                renderLine(win, row, trimmed, Colors.diff_hunk);
            } else if (std.mem.startsWith(u8, trimmed, "Symbol:") or std.mem.startsWith(u8, trimmed, "->")) {
                renderLine(win, row, trimmed, Colors.title);
            } else if (std.mem.startsWith(u8, trimmed, "[") and std.mem.endsWith(u8, trimmed, "]")) {
                renderLine(win, row, trimmed, Colors.diff_file);
            } else if (std.mem.startsWith(u8, trimmed, "Ln ") or std.mem.startsWith(u8, trimmed, "   Ln ")) {
                renderLine(win, row, trimmed, Colors.key);
            } else if (std.mem.startsWith(u8, trimmed, "Found ")) {
                renderLine(win, row, trimmed, Colors.h3);
            } else {
                renderLine(win, row, trimmed, Colors.desc);
            }

            row += 1;
        }
    }

    fn renderLine(win: vaxis.Window, row: u16, text: []const u8, style: vaxis.Cell.Style) void {
        _ = win.printSegment(.{ .text = text, .style = style }, .{ .row_offset = row });
    }

    fn renderLineAt(win: vaxis.Window, row: u16, col: u16, text: []const u8, style: vaxis.Cell.Style) void {
        _ = win.printSegment(.{ .text = text, .style = style }, .{ .row_offset = row, .col_offset = col });
    }

    fn renderKeyBindingLine(win: vaxis.Window, row: u16, line: []const u8) void {
        var col: u16 = 2;

        _ = win.printSegment(.{ .text = "•", .style = Colors.bullet }, .{ .row_offset = row, .col_offset = col });
        col += 2;

        const rest = line[2..];
        if (std.mem.indexOf(u8, rest, "`")) |first_tick| {
            const after_first = rest[first_tick + 1 ..];
            if (std.mem.indexOf(u8, after_first, "`")) |second_tick| {
                const key_text = after_first[0..second_tick];
                const description = after_first[second_tick + 1 ..];

                _ = win.printSegment(.{ .text = "[", .style = Colors.key }, .{ .row_offset = row, .col_offset = col });
                col += 1;
                _ = win.printSegment(.{ .text = key_text, .style = Colors.key }, .{ .row_offset = row, .col_offset = col });
                col += @intCast(key_text.len);
                _ = win.printSegment(.{ .text = "]", .style = Colors.key }, .{ .row_offset = row, .col_offset = col });
                col += 1;

                const trimmed_desc = std.mem.trim(u8, description, " :");
                if (trimmed_desc.len > 0) {
                    _ = win.printSegment(.{ .text = " ", .style = Colors.desc }, .{ .row_offset = row, .col_offset = col });
                    col += 1;
                    _ = win.printSegment(.{ .text = trimmed_desc, .style = Colors.desc }, .{ .row_offset = row, .col_offset = col });
                }
            }
        }
    }
};
