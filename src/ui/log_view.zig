const std = @import("std");
const vaxis = @import("vaxis");
const protocol = @import("../kernel/protocol.zig");
const theme = @import("theme.zig");

pub const LogView = struct {
    pub fn drawBuffer(win: vaxis.Window, lines: []const []const u8) !void {
        const header_style = vaxis.Style{ .bold = true, .reverse = true };

        for (0..win.width) |c| {
            _ = win.printSegment(.{ .text = " ", .style = header_style }, .{ .row_offset = 0, .col_offset = @intCast(c) });
        }

        var header_seg = [_]vaxis.Segment{
            .{ .text = "TIME     ", .style = header_style },
            .{ .text = "LEVEL ", .style = header_style },
            .{ .text = "SCOPE               ", .style = header_style },
            .{ .text = " MESSAGE", .style = header_style },
        };
        _ = win.print(&header_seg, .{ .row_offset = 0 });

        if (lines.len == 0) {
            const msg = "No logs available.";
            _ = win.printSegment(.{ .text = msg, .style = .{} }, .{ .row_offset = 2, .col_offset = 2 });
            return;
        }

        var row: u16 = 1;
        const start_row: usize = if (lines.len > 0 and std.mem.startsWith(u8, lines[0], "TIMESTAMP")) 1 else 0;

        for (lines[start_row..]) |line| {
            if (row >= win.height) break;
            if (line.len == 0) {
                row += 1;
                continue;
            }

            if (line.len >= 8) {
                _ = win.printSegment(.{ .text = line[0..8], .style = .{ .fg = .{ .index = theme.colors.log.timestamp } } }, .{ .row_offset = row, .col_offset = 0 });
            }

            if (line.len >= 14) {
                const level_slice = line[9..14];
                var level_style: vaxis.Style = .{ .bold = true };

                if (std.mem.startsWith(u8, level_slice, "INFO")) {
                    level_style.fg = .{ .index = theme.colors.log.info };
                } else if (std.mem.startsWith(u8, level_slice, "WARN")) {
                    level_style.fg = .{ .index = theme.colors.log.warn };
                } else if (std.mem.startsWith(u8, level_slice, "ERROR")) {
                    level_style.fg = .{ .index = theme.colors.log.err };
                } else if (std.mem.startsWith(u8, level_slice, "DEBUG")) {
                    level_style.fg = .{ .index = theme.colors.log.debug };
                }

                _ = win.printSegment(.{ .text = level_slice, .style = level_style }, .{ .row_offset = row, .col_offset = 9 });
            }

            if (line.len >= 35) {
                _ = win.printSegment(.{ .text = line[15..35], .style = .{ .fg = .{ .index = theme.colors.log.scope } } }, .{ .row_offset = row, .col_offset = 15 });

                if (line.len > 36) {
                    const msg = line[36..];
                    const max_len = if (win.width > 36) win.width - 36 else 10;
                    const display_len = @min(msg.len, max_len);
                    _ = win.printSegment(.{ .text = msg[0..display_len], .style = .{ .fg = .{ .index = theme.colors.log.message } } }, .{ .row_offset = row, .col_offset = 36 });
                }
            } else if (line.len > 15) {
                _ = win.printSegment(.{ .text = line[15..], .style = .{ .fg = .{ .index = theme.colors.log.message } } }, .{ .row_offset = row, .col_offset = 15 });
            }

            row += 1;
        }
    }
};
