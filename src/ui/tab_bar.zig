const std = @import("std");
const vaxis = @import("vaxis");
const protocol = @import("../kernel/protocol.zig");
const theme = @import("theme.zig");

pub const TabBar = struct {
    pub fn draw(
        win: vaxis.Window,
        buffers: []const protocol.BufferInfo,
        active_index: usize,
        allocator: std.mem.Allocator,
    ) !void {
        const bg_style = theme.styles.tab_bar.background;
        const active_style = theme.styles.tab_bar.active;
        const inactive_style = theme.styles.tab_bar.inactive;
        const modified_style = theme.styles.tab_bar.modified;
        const scroll_indicator_style = theme.styles.tab_bar.scroll_indicator;

        for (0..win.width) |i| {
            _ = win.printSegment(.{ .text = " ", .style = bg_style }, .{ .col_offset = @intCast(i) });
        }

        const context_tabs: usize = 2;
        var scroll_start: usize = 0;

        if (active_index > context_tabs) {
            scroll_start = active_index - context_tabs;
        }

        var col: u16 = 0;
        if (scroll_start > 0) {
            _ = win.printSegment(.{ .text = "◀ ", .style = scroll_indicator_style }, .{ .col_offset = col });
            col += 2;
        } else {
            col = 1;
        }

        var cut_off_end = false;

        for (buffers[scroll_start..], scroll_start..) |buf, i| {
            const is_active = i == active_index;
            const style = if (is_active) active_style else inactive_style;

            if (i > scroll_start) {
                _ = win.printSegment(.{ .text = " │ ", .style = bg_style }, .{ .col_offset = col });
                col += 3;
            }

            const num_str = try std.fmt.allocPrint(allocator, "{d}:", .{i + 1});
            const num_style: vaxis.Cell.Style = if (is_active)
                theme.styles.tab_bar.number_active
            else
                theme.styles.tab_bar.number_inactive;
            _ = win.printSegment(.{ .text = num_str, .style = num_style }, .{ .col_offset = col });
            col += @as(u16, @intCast(num_str.len));

            if (buf.modified) {
                _ = win.printSegment(.{ .text = "● ", .style = modified_style }, .{ .col_offset = col });
                col += 2;
            }

            const name = buf.name;
            _ = win.printSegment(.{ .text = name, .style = style }, .{ .col_offset = col });
            col +|= @as(u16, @intCast(@min(name.len, std.math.maxInt(u16))));

            if (col >= win.width -| 5) {
                if (i + 1 < buffers.len) {
                    cut_off_end = true;
                }
                break;
            }
        }

        if (cut_off_end) {
            const right_pos = win.width -| 2;
            _ = win.printSegment(.{ .text = " ▶", .style = scroll_indicator_style }, .{ .col_offset = right_pos });
        }
    }
};
