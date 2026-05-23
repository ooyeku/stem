const std = @import("std");
const vaxis = @import("vaxis");
const protocol = @import("../kernel/protocol.zig");
const config = @import("config");
const theme = @import("theme.zig");
const safe = @import("../kernel/safe.zig");

/// Saturating cast to u16 — caps at 65535 so a long status string can't
/// overflow the renderer's column-offset arithmetic.
inline fn u16Sat(n: usize) u16 {
    return safe.saturatingCast(u16, n);
}

pub const StatusBar = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) StatusBar {
        return .{ .allocator = allocator };
    }

    fn getFileType(file_path: ?[]const u8) []const u8 {
        if (file_path) |path| {
            const ext = std.fs.path.extension(path);
            if (std.mem.eql(u8, ext, ".zig")) return "Zig";
            if (std.mem.eql(u8, ext, ".rs")) return "Rust";
            if (std.mem.eql(u8, ext, ".go")) return "Go";
            if (std.mem.eql(u8, ext, ".py")) return "Python";
            if (std.mem.eql(u8, ext, ".js")) return "JavaScript";
            if (std.mem.eql(u8, ext, ".ts")) return "TypeScript";
            if (std.mem.eql(u8, ext, ".c")) return "C";
            if (std.mem.eql(u8, ext, ".cpp") or std.mem.eql(u8, ext, ".cc")) return "C++";
            if (std.mem.eql(u8, ext, ".h") or std.mem.eql(u8, ext, ".hpp")) return "Header";
            if (std.mem.eql(u8, ext, ".java")) return "Java";
            if (std.mem.eql(u8, ext, ".rb")) return "Ruby";
            if (std.mem.eql(u8, ext, ".md")) return "Markdown";
            if (std.mem.eql(u8, ext, ".json")) return "JSON";
            if (std.mem.eql(u8, ext, ".yaml") or std.mem.eql(u8, ext, ".yml")) return "YAML";
            if (std.mem.eql(u8, ext, ".toml")) return "TOML";
            if (std.mem.eql(u8, ext, ".html")) return "HTML";
            if (std.mem.eql(u8, ext, ".css")) return "CSS";
            if (std.mem.eql(u8, ext, ".sh")) return "Shell";
            if (std.mem.eql(u8, ext, ".txt")) return "Text";
            if (ext.len > 1) return ext[1..];
            return "Plain";
        }
        return "Scratch";
    }

    pub fn draw(
        self: *StatusBar,
        win: vaxis.Window,
        snapshot: *const protocol.RenderSnapshot,
        allocator: std.mem.Allocator,
    ) !void {
        _ = self;

        const mode = snapshot.mode;

        const base_style = theme.styles.status_bar.base;

        const mode_style: vaxis.Cell.Style = switch (mode) {
            .select => theme.styles.mode.select,
            .insert => theme.styles.mode.insert,
            .visual => theme.styles.mode.visual,
            .view => theme.styles.mode.view,
            .terminal => theme.styles.mode.terminal,
            .file_picker => theme.styles.mode.file_picker,
            .buffer_picker => theme.styles.mode.buffer_picker,
            .save_as_mode => theme.styles.mode.save_as,
            .visual_search => theme.styles.mode.visual_search,
            .command_palette => theme.styles.mode.command_palette,
            .go_to_line => theme.styles.mode.go_to_line,
            .symbol_picker => theme.styles.mode.symbol_picker,
            .workspace_symbol_picker => theme.styles.mode.symbol_picker,
            .log_view => theme.styles.mode.log_view,
            .global_search => theme.styles.mode.global_search,
        };

        const mode_text = switch (mode) {
            .select => " SELECT ",
            .insert => " INSERT ",
            .visual => " VISUAL ",
            .view => " VIEW ",
            .terminal => " TERMINAL ",
            .file_picker => " OPEN ",
            .buffer_picker => " BUFFERS ",
            .save_as_mode => " SAVE AS ",
            .visual_search => " SEARCH ",
            .command_palette => " CMD ",
            .go_to_line => " GOTO ",
            .symbol_picker => " SYMBOL ",
            .workspace_symbol_picker => " W-SYMBOL ",
            .log_view => " LOGS ",
            .global_search => " SEARCH ",
        };

        for (0..win.width) |i| {
            _ = win.printSegment(.{ .text = " ", .style = base_style }, .{ .col_offset = @intCast(i) });
        }

        _ = win.printSegment(.{ .text = mode_text, .style = mode_style }, .{ .col_offset = 0 });

        const mode_text_len: u16 = @intCast(mode_text.len);
        var left_offset: u16 = mode_text_len + 1;

        if (snapshot.nav_repeat_count > 0) {
            const prefix_text = try std.fmt.allocPrint(allocator, " {d} ", .{snapshot.nav_repeat_count});
            defer allocator.free(prefix_text);

            _ = win.printSegment(.{ .text = prefix_text, .style = theme.styles.status_bar.prefix }, .{ .col_offset = left_offset });
            left_offset += u16Sat(prefix_text.len);
        }

        if (mode == .terminal) {
            const prompt = " $ ";
            _ = win.printSegment(.{ .text = prompt, .style = base_style }, .{ .col_offset = left_offset });
            left_offset += @intCast(prompt.len);
            if (snapshot.terminal_input) |input| {
                _ = win.printSegment(.{ .text = input, .style = base_style }, .{ .col_offset = left_offset });
                left_offset += u16Sat(input.len);
            }
        } else {
            const file_indicator = if (snapshot.file_modified) "[+] " else "";
            if (file_indicator.len > 0) {
                _ = win.printSegment(.{ .text = file_indicator, .style = theme.styles.status_bar.modified }, .{ .col_offset = left_offset });
                left_offset += u16Sat(file_indicator.len);
            }

            // Large-file mode badge — tells the user why tree-sitter,
            // brackets, and LSP feedback are silent. Rendered before the
            // path so it's the first thing the eye lands on.
            const active_is_large: bool = blk: {
                if (snapshot.active_buffer_index < snapshot.buffers.len) {
                    break :blk snapshot.buffers[snapshot.active_buffer_index].is_large;
                }
                break :blk false;
            };
            if (active_is_large) {
                const large_badge = "[LARGE] ";
                _ = win.printSegment(.{
                    .text = large_badge,
                    .style = .{ .fg = .{ .index = 11 }, .bold = true }, // bright yellow
                }, .{ .col_offset = left_offset });
                left_offset += u16Sat(large_badge.len);
            }

            const full_path = snapshot.file_path orelse "[untitled]";
            const max_path_width: usize = @min(full_path.len, @as(usize, win.width / 2));
            const display_path = if (full_path.len > max_path_width)
                full_path[full_path.len - max_path_width ..]
            else
                full_path;

            _ = win.printSegment(.{ .text = display_path, .style = base_style }, .{ .col_offset = left_offset });
            left_offset += u16Sat(display_path.len);

            if (snapshot.status_message) |msg| {
                // Per-level icon + colour. We use a small palette of
                // terminal-index colours rather than full RGB so the
                // toasts read correctly on themes where the default
                // background is something other than black.
                const icon: []const u8 = switch (snapshot.status_message_level) {
                    .success => "✓",
                    .info => "•",
                    .warning => "⚠",
                    .err => "✗",
                };
                const fg_index: u8 = switch (snapshot.status_message_level) {
                    .success => 10, // bright green
                    .info => 12, // bright blue
                    .warning => 11, // bright yellow
                    .err => 9, // bright red
                };
                const status_style: vaxis.Cell.Style = .{
                    .fg = .{ .index = fg_index },
                    .bg = .{ .index = 0 },
                    .bold = true,
                };
                const padded_msg = try std.fmt.allocPrint(allocator, "  {s} {s}", .{ icon, msg });
                _ = win.printSegment(.{ .text = padded_msg, .style = status_style }, .{ .col_offset = left_offset });
                left_offset += u16Sat(padded_msg.len);
            }
        }

        if (snapshot.plugin_status_items.len > 0) {
            for (snapshot.plugin_status_items) |item| {
                if (item.alignment == .left) {
                    left_offset += 1;
                    if (left_offset >= win.width) break;
                    _ = win.printSegment(.{ .text = item.text, .style = base_style }, .{ .col_offset = left_offset });
                    left_offset += u16Sat(item.text.len);
                }
            }
        }

        // Diagnostic counts (inline after the path / status_message).
        if (snapshot.diagnostic_error_count > 0 or snapshot.diagnostic_warning_count > 0) {
            left_offset += 1;
            if (snapshot.diagnostic_error_count > 0) {
                const err_text = try std.fmt.allocPrint(allocator, " E:{d}", .{snapshot.diagnostic_error_count});
                const err_style: vaxis.Cell.Style = .{
                    .fg = .{ .rgb = .{ 224, 108, 117 } },
                    .bg = base_style.bg,
                    .bold = true,
                };
                _ = win.printSegment(.{ .text = err_text, .style = err_style }, .{ .col_offset = left_offset });
                left_offset += u16Sat(err_text.len);
            }
            if (snapshot.diagnostic_warning_count > 0) {
                const warn_text = try std.fmt.allocPrint(allocator, " W:{d}", .{snapshot.diagnostic_warning_count});
                const warn_style: vaxis.Cell.Style = .{
                    .fg = .{ .rgb = .{ 229, 192, 123 } },
                    .bg = base_style.bg,
                    .bold = true,
                };
                _ = win.printSegment(.{ .text = warn_text, .style = warn_style }, .{ .col_offset = left_offset });
                left_offset += u16Sat(warn_text.len);
            }
        }

        // Right-side widgets, assembled into one string.
        const file_type = getFileType(snapshot.file_path);
        const encoding = "UTF-8";
        const line_ending = "LF";

        const version = config.version;
        const plugin_indicator = if (snapshot.plugin_count > 0)
            try std.fmt.allocPrint(allocator, "Plugins:{d} | ", .{snapshot.plugin_count})
        else
            "";

        const lsp_indicator = if (snapshot.lsp_status) |s|
            try std.fmt.allocPrint(allocator, "LSP:{s} | ", .{s})
        else
            "";

        const git_indicator = if (snapshot.git_branch) |b|
            try std.fmt.allocPrint(allocator, "{s} | ", .{b})
        else
            "";

        // Animated spinner when background jobs are running. Frame derived
        // from snapshot.version so it advances naturally with each render.
        const spinner_frames = [_][]const u8{ "|", "/", "-", "\\" };
        const job_indicator = if (snapshot.active_job_count > 0)
            try std.fmt.allocPrint(allocator, "{s} {d} jobs | ", .{
                spinner_frames[@intCast(snapshot.version % spinner_frames.len)],
                snapshot.active_job_count,
            })
        else
            "";

        const indent_text = if (snapshot.editor_config.insert_spaces)
            try std.fmt.allocPrint(allocator, "Spaces:{d}", .{snapshot.editor_config.tab_size})
        else
            try std.fmt.allocPrint(allocator, "Tab:{d}", .{snapshot.editor_config.tab_size});

        const right_text = try std.fmt.allocPrint(
            allocator,
            "{s}{s}{s}{s}{s} | {s} | {s} | {s} | Ln {d}, Col {d} | Stem v{s}",
            .{ job_indicator, plugin_indicator, lsp_indicator, git_indicator, file_type, indent_text, encoding, line_ending, snapshot.cursor_row + 1, snapshot.cursor_col + 1, version },
        );

        const info_style = theme.styles.status_bar.info;

        var right_pos: u16 = win.width;
        if (right_text.len < win.width) {
            right_pos = win.width - @as(u16, @intCast(right_text.len)) - 1;
            _ = win.printSegment(.{ .text = right_text, .style = info_style }, .{ .col_offset = right_pos });
        }

        if (snapshot.plugin_status_items.len > 0) {
            var i: usize = snapshot.plugin_status_items.len;
            while (i > 0) {
                i -= 1;
                const item = snapshot.plugin_status_items[i];
                if (item.alignment == .right) {
                    const w: u16 = u16Sat(item.text.len);
                    const sep = " | ";
                    const sep_w: u16 = 3;

                    if (right_pos > w + sep_w + 1) {
                        right_pos -= (w + sep_w);
                        _ = win.printSegment(.{ .text = item.text, .style = base_style }, .{ .col_offset = right_pos });
                        _ = win.printSegment(.{ .text = sep, .style = info_style }, .{ .col_offset = right_pos + w });
                    }
                }
            }
        }
    }
};
