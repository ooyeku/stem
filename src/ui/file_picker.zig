const std = @import("std");
const vaxis = @import("vaxis");
const protocol = @import("../kernel/protocol.zig");
const theme = @import("theme.zig");

pub const FilePicker = struct {
    pub fn draw(
        win: vaxis.Window,
        cwd: []const u8,
        entries: []const protocol.DirEntry,
        selected: usize,
        allocator: std.mem.Allocator,
    ) !void {
        const cp = theme.styles.command_palette;

        for (0..win.height) |row| {
            for (0..win.width) |col| {
                _ = win.printSegment(.{ .text = " ", .style = cp.overlay }, .{
                    .row_offset = @intCast(row),
                    .col_offset = @intCast(col),
                });
            }
        }

        if (win.width < 12 or win.height < 8) return;

        const width: usize = @min(win.width -| 4, 80);
        const height: usize = @min(win.height -| 6, 25);

        const start_x: usize = (win.width - width) / 2;
        const start_y: usize = @max((win.height - height) / 3, 2);

        for (1..width) |i| {
            _ = win.printSegment(.{ .text = "─", .style = cp.border }, .{ .row_offset = @intCast(start_y), .col_offset = @intCast(start_x + i) });
            _ = win.printSegment(.{ .text = "─", .style = cp.border }, .{ .row_offset = @intCast(start_y + height + 2), .col_offset = @intCast(start_x + i) });
        }
        for (1..height + 3) |i| {
            _ = win.printSegment(.{ .text = "│", .style = cp.border }, .{ .row_offset = @intCast(start_y + i), .col_offset = @intCast(start_x) });
            _ = win.printSegment(.{ .text = "│", .style = cp.border }, .{ .row_offset = @intCast(start_y + i), .col_offset = @intCast(start_x + width) });
        }
        _ = win.printSegment(.{ .text = "╭", .style = cp.border }, .{ .row_offset = @intCast(start_y), .col_offset = @intCast(start_x) });
        _ = win.printSegment(.{ .text = "╮", .style = cp.border }, .{ .row_offset = @intCast(start_y), .col_offset = @intCast(start_x + width) });
        _ = win.printSegment(.{ .text = "╰", .style = cp.border }, .{ .row_offset = @intCast(start_y + height + 2), .col_offset = @intCast(start_x) });
        _ = win.printSegment(.{ .text = "╯", .style = cp.border }, .{ .row_offset = @intCast(start_y + height + 2), .col_offset = @intCast(start_x + width) });

        for (1..width) |i| {
            _ = win.printSegment(.{ .text = " ", .style = cp.title }, .{ .row_offset = @intCast(start_y + 1), .col_offset = @intCast(start_x + i) });
        }
        _ = win.printSegment(.{ .text = " Open File ", .style = cp.title }, .{ .row_offset = @intCast(start_y + 1), .col_offset = @intCast(start_x + 2) });

        const max_cwd_len = if (width > 20) width - 20 else 10;
        const display_cwd = if (cwd.len > max_cwd_len) cwd[cwd.len - max_cwd_len ..] else cwd;
        const cwd_text = try std.fmt.allocPrint(allocator, " {s} ", .{display_cwd});
        if (width > cwd_text.len + 15) {
            _ = win.printSegment(.{ .text = cwd_text, .style = cp.title }, .{ .row_offset = @intCast(start_y + 1), .col_offset = @intCast(start_x + width - cwd_text.len - 1) });
        }

        for (1..width) |i| {
            _ = win.printSegment(.{ .text = "─", .style = cp.border }, .{ .row_offset = @intCast(start_y + 2), .col_offset = @intCast(start_x + i) });
        }

        const visible_rows = height -| 1;
        const start_idx = if (visible_rows > 0 and selected >= visible_rows) selected - visible_rows + 1 else 0;

        var row_offset: usize = 3;
        var idx = start_idx;
        while (idx < entries.len and row_offset < height + 2) : ({
            idx += 1;
            row_offset += 1;
        }) {
            const entry = entries[idx];
            const is_selected = idx == selected;

            const style = if (is_selected) cp.item_selected else cp.item;

            for (1..width) |j| {
                _ = win.printSegment(.{ .text = " ", .style = style }, .{
                    .row_offset = @intCast(start_y + row_offset),
                    .col_offset = @intCast(start_x + j),
                });
            }

            const prefix: []const u8 = if (entry.is_dir) "[D] " else "    ";
            const line_text = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, entry.name });

            const dir_style = if (is_selected)
                cp.item_selected
            else
                theme.styles.picker.directory;

            const final_style = if (entry.is_dir) dir_style else style;

            _ = win.printSegment(.{ .text = line_text, .style = final_style }, .{
                .row_offset = @intCast(start_y + row_offset),
                .col_offset = @intCast(start_x + 3),
            });
        }

        if (entries.len > visible_rows) {
            const scroll_track_height = visible_rows;
            const thumb_size = @max(1, (visible_rows * visible_rows) / entries.len);
            const thumb_pos = if (entries.len > 0) (start_idx * scroll_track_height) / entries.len else 0;

            for (0..scroll_track_height) |i| {
                const is_thumb = i >= thumb_pos and i < thumb_pos + thumb_size;
                const scroll_char: []const u8 = if (is_thumb) "█" else "░";
                const scroll_style = if (is_thumb) cp.scrollbar_thumb else cp.scrollbar;
                _ = win.printSegment(.{ .text = scroll_char, .style = scroll_style }, .{
                    .row_offset = @intCast(start_y + 3 + i),
                    .col_offset = @intCast(start_x + width - 1),
                });
            }
        }

        const footer_row = start_y + height + 2;
        const hints = " ↑↓ Navigate  Enter Open  ^O Open Dir  ⌫ Parent  Esc Cancel ";
        _ = win.printSegment(.{ .text = hints, .style = cp.footer }, .{
            .row_offset = @intCast(footer_row),
            .col_offset = @intCast(start_x + 2),
        });
    }
};
