const std = @import("std");
const vaxis = @import("vaxis");
const protocol = @import("../kernel/protocol.zig");
const theme = @import("theme.zig");

pub const BufferPicker = struct {
    pub fn draw(
        win: vaxis.Window,
        buffers: []const protocol.BufferInfo,
        selected_index: usize,
        scroll_offset: usize,
        number_input: ?[]const u8,
        allocator: std.mem.Allocator,
    ) !void {
        const overlay_style = theme.styles.picker.overlay;
        const header_style = theme.styles.picker.header;
        const item_style = theme.styles.picker.normal;
        const selected_style = theme.styles.picker.selected;
        const active_marker_style = theme.styles.picker.active_marker;
        const num_style = theme.styles.picker.number;
        const input_style = theme.styles.picker.input;

        for (0..win.height) |row| {
            for (0..win.width) |col| {
                _ = win.printSegment(.{ .text = " ", .style = overlay_style }, .{
                    .row_offset = @intCast(row),
                    .col_offset = @intCast(col),
                });
            }
        }

        if (win.width < 4 or win.height < 2) return;

        const header = " Switch Buffer (Type # or Navigate) ";
        const header_col = (win.width -| @as(u16, @intCast(header.len))) / 2;
        if (win.height > 1) {
            _ = win.printSegment(.{ .text = header, .style = header_style }, .{
                .row_offset = 1,
                .col_offset = header_col,
            });
        }

        if (number_input) |num| {
            if (num.len > 0 and win.height > 2) {
                const input_text = try std.fmt.allocPrint(allocator, " Go to: {s}_ ", .{num});
                const input_col = (win.width -| @as(u16, @intCast(input_text.len))) / 2;
                _ = win.printSegment(.{ .text = input_text, .style = input_style }, .{
                    .row_offset = 2,
                    .col_offset = input_col,
                });
            }
        }

        const list_start: u16 = if (number_input != null and number_input.?.len > 0) 4 else 3;

        const visible_height = pickerVisibleHeight(win.height, list_start);
        const start_index = scroll_offset;
        const end_index = @min(buffers.len, start_index + visible_height);

        for (start_index..end_index) |i| {
            const buf = buffers[i];
            const row = list_start + @as(u16, @intCast(i - start_index));
            if (row >= win.height) break;

            const is_selected = i == selected_index;
            const style = if (is_selected) selected_style else item_style;

            if (win.width > 4) {
                for (2..win.width - 2) |col| {
                    _ = win.printSegment(.{ .text = " ", .style = style }, .{
                        .row_offset = row,
                        .col_offset = @intCast(col),
                    });
                }
            }

            var col: u16 = 4;

            const num_str = try std.fmt.allocPrint(allocator, "{d:>2} ", .{i + 1});
            const actual_num_style: vaxis.Cell.Style = .{
                .fg = if (is_selected) .{ .index = 0 } else num_style.fg,
                .bg = if (is_selected) .{ .index = 4 } else .{ .index = 0 },
                .bold = is_selected,
            };
            _ = win.printSegment(.{ .text = num_str, .style = actual_num_style }, .{
                .row_offset = row,
                .col_offset = col,
            });
            col += @as(u16, @intCast(num_str.len));

            if (buf.is_active) {
                const active_style_adjusted: vaxis.Cell.Style = .{
                    .fg = if (is_selected) .{ .index = 2 } else active_marker_style.fg,
                    .bg = if (is_selected) .{ .index = 4 } else .{ .index = 0 },
                };
                _ = win.printSegment(.{ .text = "> ", .style = active_style_adjusted }, .{
                    .row_offset = row,
                    .col_offset = col,
                });
            }
            col += 2;

            if (buf.modified) {
                const mod_text = try std.fmt.allocPrint(allocator, "[+] {s}", .{buf.name});
                _ = win.printSegment(.{ .text = mod_text, .style = style }, .{
                    .row_offset = row,
                    .col_offset = col,
                });
            } else {
                _ = win.printSegment(.{ .text = buf.name, .style = style }, .{
                    .row_offset = row,
                    .col_offset = col,
                });
            }
        }

        if (visible_height > 0 and buffers.len > visible_height and win.width >= 2) {
            const track_height = visible_height;
            const track_start_row = list_start;

            var thumb_height = (visible_height * track_height) / buffers.len;
            if (thumb_height < 1) thumb_height = 1;

            var thumb_y = (scroll_offset * track_height) / buffers.len;
            if (thumb_y + thumb_height > track_height) {
                thumb_y = track_height - thumb_height;
            }

            const sb_style = theme.styles.picker.scrollbar;
            const thumb_style = theme.styles.picker.scrollbar_thumb;

            for (0..track_height) |i| {
                const r = track_start_row + @as(u16, @intCast(i));
                _ = win.printSegment(.{ .text = "│", .style = sb_style }, .{
                    .row_offset = r,
                    .col_offset = win.width - 2,
                });
            }

            for (0..thumb_height) |i| {
                const r = track_start_row + @as(u16, @intCast(thumb_y + i));
                _ = win.printSegment(.{ .text = " ", .style = thumb_style }, .{
                    .row_offset = r,
                    .col_offset = win.width - 2,
                });
            }
        }

        const footer = " Enter=Select  #=Jump  Backspace=Clear  ESC=Cancel ";
        const footer_col = (win.width -| @as(u16, @intCast(footer.len))) / 2;
        if (win.height >= 2) {
            _ = win.printSegment(.{ .text = footer, .style = header_style }, .{
                .row_offset = win.height - 2,
                .col_offset = footer_col,
            });
        }
    }
};

fn pickerVisibleHeight(win_height: u16, list_start: u16) usize {
    const bottom = win_height -| 2;
    if (bottom <= list_start) return 0;
    return bottom - list_start;
}

test "buffer picker visible height does not underflow in tiny terminals" {
    try std.testing.expectEqual(@as(usize, 0), pickerVisibleHeight(1, 3));
    try std.testing.expectEqual(@as(usize, 0), pickerVisibleHeight(4, 3));
    try std.testing.expectEqual(@as(usize, 5), pickerVisibleHeight(10, 3));
}
