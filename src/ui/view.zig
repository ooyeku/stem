const std = @import("std");
const vaxis = @import("vaxis");
const StatusBar = @import("status_bar.zig").StatusBar;
const TabBar = @import("tab_bar.zig").TabBar;
const FilePicker = @import("file_picker.zig").FilePicker;
const BufferPicker = @import("buffer_picker.zig").BufferPicker;
const LogView = @import("log_view.zig").LogView;
const HelpView = @import("help_view.zig").HelpView;
const protocol = @import("../kernel/protocol.zig");
const theme = @import("theme.zig");

const log = std.log.scoped(.ui_view);

fn logError(comptime fmt: []const u8, args: anytype) void {
    log.err(fmt, args);
}

fn logWarn(comptime fmt: []const u8, args: anytype) void {
    log.warn(fmt, args);
}

fn logDebug(comptime fmt: []const u8, args: anytype) void {
    log.debug(fmt, args);
}

pub const TokenIndex = struct {
    allocator: std.mem.Allocator,
    line_tokens: std.AutoHashMapUnmanaged(u32, []protocol.SyntaxToken),

    pub fn init(allocator: std.mem.Allocator) TokenIndex {
        return .{
            .allocator = allocator,
            .line_tokens = .{},
        };
    }

    pub fn deinit(self: *TokenIndex) void {
        var it = self.line_tokens.valueIterator();
        while (it.next()) |tokens| {
            self.allocator.free(tokens.*);
        }
        self.line_tokens.deinit(self.allocator);
    }

    pub fn buildFromTokens(self: *TokenIndex, tokens: []const protocol.SyntaxToken) !void {
        if (tokens.len == 0) return;

        var line_counts = std.AutoHashMapUnmanaged(u32, usize).empty;
        defer line_counts.deinit(self.allocator);

        for (tokens) |token| {
            const entry = try line_counts.getOrPut(self.allocator, token.line);
            if (!entry.found_existing) {
                entry.value_ptr.* = 0;
            }
            entry.value_ptr.* += 1;
        }

        var line_indices = std.AutoHashMapUnmanaged(u32, usize).empty;
        defer line_indices.deinit(self.allocator);

        var count_it = line_counts.iterator();
        while (count_it.next()) |entry| {
            const line = entry.key_ptr.*;
            const count = entry.value_ptr.*;
            const line_tokens_arr = try self.allocator.alloc(protocol.SyntaxToken, count);
            try self.line_tokens.put(self.allocator, line, line_tokens_arr);
            try line_indices.put(self.allocator, line, 0);
        }

        for (tokens) |token| {
            if (self.line_tokens.getPtr(token.line)) |line_arr| {
                if (line_indices.getPtr(token.line)) |idx| {
                    if (idx.* < line_arr.len) {
                        line_arr.*[idx.*] = token;
                        idx.* += 1;
                    }
                }
            }
        }

        var tokens_it = self.line_tokens.valueIterator();
        while (tokens_it.next()) |line_tokens_slice| {
            std.mem.sort(protocol.SyntaxToken, line_tokens_slice.*, {}, struct {
                fn lessThan(_: void, a: protocol.SyntaxToken, b: protocol.SyntaxToken) bool {
                    return a.start_col < b.start_col;
                }
            }.lessThan);
        }
    }

    pub fn getLineTokens(self: TokenIndex, line: u32) ?[]const protocol.SyntaxToken {
        return self.line_tokens.get(line);
    }

    pub fn findTokenAt(self: TokenIndex, line: u32, col: u32) ?protocol.SyntaxToken {
        const line_tokens = self.getLineTokens(line) orelse return null;
        if (line_tokens.len == 0) return null;

        var left: usize = 0;
        var right: usize = line_tokens.len;

        while (left < right) {
            const mid = left + (right - left) / 2;
            const token = line_tokens[mid];

            if (col < token.start_col) {
                right = mid;
            } else if (col >= token.start_col + token.length) {
                left = mid + 1;
            } else {
                return token;
            }
        }

        return null;
    }
};

pub const TokenValidator = struct {
    pub fn filterValid(
        allocator: std.mem.Allocator,
        tokens: []const protocol.SyntaxToken,
        visible_lines: []const []const u8,
        first_visible_line: usize,
    ) ![]protocol.SyntaxToken {
        var valid = std.ArrayListUnmanaged(protocol.SyntaxToken).empty;
        errdefer valid.deinit(allocator);

        const first_line_u32: u32 = @intCast(@min(first_visible_line, std.math.maxInt(u32)));
        const visible_len_u32: u32 = @intCast(@min(visible_lines.len, std.math.maxInt(u32)));

        for (tokens) |token| {
            if (token.line < first_line_u32) continue;
            const relative_line = token.line - first_line_u32;
            if (relative_line >= visible_len_u32) continue;

            const line = visible_lines[@intCast(relative_line)];

            const start_col: usize = @intCast(token.start_col);
            const length: usize = @intCast(token.length);
            if (start_col >= line.len) continue;
            if (length == 0) continue;
            if (start_col + length > line.len) continue;

            try valid.append(allocator, token);
        }

        return valid.toOwnedSlice(allocator);
    }

    pub fn filterCritical(
        allocator: std.mem.Allocator,
        tokens: []const protocol.SyntaxToken,
    ) ![]protocol.SyntaxToken {
        var critical = std.ArrayListUnmanaged(protocol.SyntaxToken).empty;
        errdefer critical.deinit(allocator);

        for (tokens) |token| {
            switch (token.token_type) {
                .keyword, .string, .comment => try critical.append(allocator, token),
                else => {},
            }
        }

        return critical.toOwnedSlice(allocator);
    }
};

pub const HighlightFallback = struct {
    pub const FallbackLevel = enum {
        full,
        validated,
        minimal,
        none,

        pub fn next(self: FallbackLevel) FallbackLevel {
            return switch (self) {
                .full => .validated,
                .validated => .minimal,
                .minimal => .none,
                .none => .none,
            };
        }
    };

    pub const Result = struct {
        index: ?TokenIndex,
        level: FallbackLevel,
    };

    pub fn attemptHighlighting(
        allocator: std.mem.Allocator,
        raw_tokens: ?[]const protocol.SyntaxToken,
        visible_lines: []const []const u8,
        first_visible_line: usize,
    ) Result {
        if (raw_tokens == null or raw_tokens.?.len == 0) {
            return .{ .index = null, .level = .none };
        }
        const tokens = raw_tokens.?;

        const validated = TokenValidator.filterValid(allocator, tokens, visible_lines, first_visible_line) catch {
            const critical = TokenValidator.filterCritical(allocator, tokens) catch {
                return .{ .index = null, .level = .none };
            };
            defer allocator.free(critical);

            var index = TokenIndex.init(allocator);
            index.buildFromTokens(critical) catch {
                index.deinit();
                return .{ .index = null, .level = .none };
            };
            return .{ .index = index, .level = .minimal };
        };
        defer allocator.free(validated);

        if (validated.len == 0) {
            return .{ .index = null, .level = .none };
        }

        var index = TokenIndex.init(allocator);
        index.buildFromTokens(validated) catch {
            index.deinit();
            return .{ .index = null, .level = .none };
        };

        return .{ .index = index, .level = .validated };
    }
};

pub const View = struct {
    allocator: std.mem.Allocator,
    status_bar: StatusBar,
    help_view: HelpView,

    pub fn init(allocator: std.mem.Allocator) View {
        return .{
            .allocator = allocator,
            .status_bar = StatusBar.init(allocator),
            .help_view = HelpView.init(allocator),
        };
    }

    fn styleForTokenType(t: protocol.SyntaxToken.TokenType) vaxis.Cell.Style {
        return switch (t) {
            .keyword => .{ .fg = .{ .rgb = theme.colors.syntax.keyword }, .bold = true },
            .function => .{ .fg = .{ .rgb = theme.colors.syntax.function } },
            .variable => .{ .fg = .{ .rgb = theme.colors.syntax.variable } },
            .parameter => .{ .fg = .{ .rgb = theme.colors.syntax.parameter }, .italic = true },
            .property => .{ .fg = .{ .rgb = theme.colors.syntax.property } },
            .type_name => .{ .fg = .{ .rgb = theme.colors.syntax.type_name } },
            .string => .{ .fg = .{ .rgb = theme.colors.syntax.string } },
            .number => .{ .fg = .{ .rgb = theme.colors.syntax.number } },
            .comment => .{ .fg = .{ .rgb = theme.colors.syntax.comment }, .italic = true },
            .operator => .{ .fg = .{ .rgb = theme.colors.syntax.operator } },
            .builtin => .{ .fg = .{ .rgb = theme.colors.syntax.builtin } },
            .namespace => .{ .fg = .{ .rgb = theme.colors.syntax.namespace } },
            .other => .{ .fg = .{ .rgb = theme.colors.syntax.other } },
            .bracket_1 => .{ .fg = .{ .rgb = theme.colors.brackets.level_1 }, .bold = true },
            .bracket_2 => .{ .fg = .{ .rgb = theme.colors.brackets.level_2 }, .bold = true },
            .bracket_3 => .{ .fg = .{ .rgb = theme.colors.brackets.level_3 }, .bold = true },
            .bracket_4 => .{ .fg = .{ .rgb = theme.colors.brackets.level_4 }, .bold = true },
            .bracket_5 => .{ .fg = .{ .rgb = theme.colors.brackets.level_5 }, .bold = true },
            .bracket_6 => .{ .fg = .{ .rgb = theme.colors.brackets.level_6 }, .bold = true },
            .scope_bracket => .{ .fg = .{ .rgb = theme.colors.brackets.scope }, .bold = true },
        };
    }

    fn drawPanel(self: *View, win: vaxis.Window, panel: protocol.PanelInfo, allocator: std.mem.Allocator) !void {
        _ = self;
        _ = allocator;
        const style = theme.styles.panel.background;
        for (0..win.height) |y| {
            for (0..win.width) |x| {
                _ = win.printSegment(.{ .text = " ", .style = style }, .{ .row_offset = @intCast(y), .col_offset = @intCast(x) });
            }
        }

        const title_style = theme.styles.panel.title;
        for (0..win.width) |x| {
            _ = win.printSegment(.{ .text = " ", .style = title_style }, .{ .row_offset = 0, .col_offset = @intCast(x) });
        }
        _ = win.printSegment(.{ .text = panel.title, .style = title_style }, .{ .row_offset = 0, .col_offset = 1 });

        var current_row: u16 = 1;
        for (panel.content, 0..) |line, i| {
            if (i < panel.scroll_offset) continue;
            if (current_row >= win.height) break;

            _ = win.printSegment(.{ .text = line, .style = style }, .{ .row_offset = current_row, .col_offset = 1 });
            current_row += 1;
        }
    }

    pub fn draw(
        self: *View,
        vx: *vaxis.Vaxis,
        snapshot: *const protocol.RenderSnapshot,
        frame_allocator: std.mem.Allocator,
    ) !void {
        const win = vx.window();

        if (win.width == 0 or win.height == 0) {
            logWarn("draw: Zero window dimensions ({}x{}), skipping render", .{ win.width, win.height });
            return;
        }

        if (snapshot.visible_lines.len > 100000) {
            logError("draw: Suspicious visible_lines length: {}", .{snapshot.visible_lines.len});
            return;
        }

        win.clear();

        const mode = snapshot.mode;

        if (mode == .file_picker) {
            if (snapshot.file_picker_entries) |entries| {
                try FilePicker.draw(
                    win,
                    snapshot.file_picker_cwd orelse ".",
                    entries,
                    snapshot.file_picker_selected,
                    frame_allocator,
                );
            }
            return;
        }

        if (mode == .buffer_picker) {
            try BufferPicker.draw(
                win,
                snapshot.buffers,
                snapshot.buffer_picker_selected,
                snapshot.buffer_picker_scroll_offset,
                snapshot.buffer_picker_number_input,
                frame_allocator,
            );
            return;
        }

        if (mode == .save_as_mode) {
            try self.drawSaveAsInput(win, snapshot.save_as_input orelse "", frame_allocator);
            return;
        }

        if (mode == .command_palette) {
            try self.drawCommandPalette(win, snapshot, frame_allocator);
            return;
        }

        if (mode == .go_to_line) {
            try self.drawGoToLine(win, snapshot, frame_allocator);
            return;
        }

        if (mode == .symbol_picker) {
            try self.drawSymbolPicker(win, snapshot, frame_allocator);
            return;
        }

        if (mode == .global_search) {
            try self.drawGlobalSearch(win, snapshot, frame_allocator);
            return;
        }

        if (snapshot.split_enabled and snapshot.panes.len > 1) {
            try self.drawSplitView(vx, snapshot, frame_allocator);
            return;
        }

        const tab_height: u16 = 1;
        const status_height: u16 = 1;
        const terminal_output_height: u16 = if (mode == .terminal and snapshot.terminal_output != null) 12 else 0;

        // Saturating subtraction so a tiny terminal in terminal mode (where
        // terminal_output_height is 12) doesn't underflow u16 and produce a
        // wraparound height that crashes the renderer.
        if (win.height < tab_height + status_height + terminal_output_height + 1) return;

        const text_height = win.height -| tab_height -| status_height -| terminal_output_height;

        const tab_area = win.child(.{
            .height = tab_height,
        });
        try TabBar.draw(tab_area, snapshot.buffers, snapshot.active_buffer_index, frame_allocator);

        var current_x_off: u16 = 0;
        const current_y_off: u16 = tab_height;
        var current_width: u16 = win.width;
        var current_height: u16 = text_height;

        for (snapshot.plugin_panels) |panel| {
            if (panel.position == .left) {
                const p_width = (win.width * panel.width_percent) / 100;
                const clamped_width = @max(10, @min(p_width, current_width / 2));

                const panel_area = win.child(.{
                    .x_off = current_x_off,
                    .y_off = current_y_off,
                    .width = @intCast(clamped_width),
                    .height = current_height,
                });
                try self.drawPanel(panel_area, panel, frame_allocator);

                current_x_off += @intCast(clamped_width);
                current_width -= @intCast(clamped_width);
            }
        }

        for (snapshot.plugin_panels) |panel| {
            if (panel.position == .right) {
                const p_width = (win.width * panel.width_percent) / 100;
                const clamped_width = @max(10, @min(p_width, current_width / 2));

                const panel_area = win.child(.{
                    .x_off = current_x_off + current_width - @as(u16, @intCast(clamped_width)),
                    .y_off = current_y_off,
                    .width = @intCast(clamped_width),
                    .height = current_height,
                });
                try self.drawPanel(panel_area, panel, frame_allocator);

                current_width -= @intCast(clamped_width);
            }
        }

        for (snapshot.plugin_panels) |panel| {
            if (panel.position == .bottom) {
                const p_height = (text_height * panel.width_percent) / 100;
                const clamped_height = @max(3, @min(p_height, current_height / 2));

                const panel_area = win.child(.{
                    .x_off = current_x_off,
                    .y_off = current_y_off + current_height - @as(u16, @intCast(clamped_height)),
                    .width = current_width,
                    .height = @intCast(clamped_height),
                });
                try self.drawPanel(panel_area, panel, frame_allocator);

                current_height -= @intCast(clamped_height);
            }
        }

        const text_area = win.child(.{
            .x_off = current_x_off,
            .y_off = current_y_off,
            .width = current_width,
            .height = current_height,
        });

        const status_area = win.child(.{
            .y_off = win.height - 1,
            .height = status_height,
        });
        try self.status_bar.draw(status_area, snapshot, frame_allocator);

        if (mode == .terminal and snapshot.terminal_output != null) {
            const terminal_area = win.child(.{
                .y_off = tab_height + text_height,
                .height = terminal_output_height,
            });
            try self.drawTerminalOutput(terminal_area, snapshot);
        }

        const is_help_buffer = blk: {
            if (snapshot.active_buffer_index < snapshot.buffers.len) {
                const buf_name = snapshot.buffers[snapshot.active_buffer_index].name;
                break :blk std.mem.eql(u8, buf_name, "[HELP]") or
                    std.mem.eql(u8, buf_name, "[PLUGINS]") or
                    std.mem.eql(u8, buf_name, "[Plugin Stats]") or
                    std.mem.eql(u8, buf_name, "[Git Status]") or
                    std.mem.eql(u8, buf_name, "[Git Diff]") or
                    std.mem.eql(u8, buf_name, "[Git Diff Staged]") or
                    std.mem.eql(u8, buf_name, "[References]");
            }
            break :blk false;
        };

        if (is_help_buffer) {
            self.help_view.draw(text_area, snapshot.visible_lines, snapshot.scroll_offset) catch {};
            const help_status_area = win.child(.{
                .y_off = win.height - 1,
                .height = status_height,
            });
            try self.status_bar.draw(help_status_area, snapshot, frame_allocator);
            return;
        }

        const is_logs_buffer = blk: {
            if (snapshot.active_buffer_index < snapshot.buffers.len) {
                const buf_name = snapshot.buffers[snapshot.active_buffer_index].name;
                break :blk std.mem.eql(u8, buf_name, "[LOGS]");
            }
            break :blk false;
        };

        if (is_logs_buffer) {
            try LogView.drawBuffer(text_area, snapshot.visible_lines);
            const logs_status_area = win.child(.{
                .y_off = win.height - 1,
                .height = status_height,
            });
            try self.status_bar.draw(logs_status_area, snapshot, frame_allocator);
            return;
        }

        const visible_lines = snapshot.visible_lines;
        const total_lines = snapshot.total_lines;
        const first_line = snapshot.first_visible_line;
        var highlight_result = HighlightFallback.attemptHighlighting(
            frame_allocator,
            snapshot.syntax_tokens,
            visible_lines,
            first_line,
        );
        defer if (highlight_result.index) |*idx| idx.deinit();

        const max_visible_line = first_line + visible_lines.len;
        const display_lines = @max(total_lines, max_visible_line);
        const digits = if (display_lines > 0) std.math.log10_int(display_lines) + 1 else 1;

        const show_line_numbers = snapshot.editor_config.line_numbers != .none;
        const gutter_width: usize = if (show_line_numbers) digits + 1 else 0;

        const text_width = if (text_area.width > gutter_width) text_area.width - @as(u16, @intCast(gutter_width)) else 0;

        const text_win = text_area.child(.{
            .x_off = @intCast(gutter_width),
            .width = text_width,
        });

        const line_num_style = theme.styles.editor.line_number;

        var screen_row: usize = 0;

        for (visible_lines, 0..) |line, i| {
            if (screen_row >= text_area.height) break;

            const file_line_num = first_line + i + 1;
            const file_line_idx: u32 = @intCast(first_line + i);

            // Find the highest-severity diagnostic that starts on this line.
            const top_diag: ?protocol.DiagnosticSnapshot = if (snapshot.diagnostics) |diags| blk: {
                var best: ?protocol.DiagnosticSnapshot = null;
                for (diags) |d| {
                    if (d.start_line != file_line_idx) continue;
                    if (best) |b| {
                        if (@intFromEnum(d.severity) < @intFromEnum(b.severity)) best = d;
                    } else best = d;
                }
                break :blk best;
            } else null;

            if (show_line_numbers) {
                const display_num: usize = switch (snapshot.editor_config.line_numbers) {
                    .absolute => file_line_num,
                    .relative => blk: {
                        const line_idx = first_line + i;
                        if (line_idx == snapshot.cursor_row) {
                            break :blk file_line_num;
                        } else if (line_idx > snapshot.cursor_row) {
                            break :blk line_idx - snapshot.cursor_row;
                        } else {
                            break :blk snapshot.cursor_row - line_idx;
                        }
                    },
                    .none => unreachable,
                };
                const line_num_str = try std.fmt.allocPrint(frame_allocator, "{d}", .{display_num});
                const col_pos = if (gutter_width > line_num_str.len)
                    gutter_width - 1 - line_num_str.len
                else
                    0;

                _ = text_area.printSegment(.{
                    .text = line_num_str,
                    .style = line_num_style,
                }, .{
                    .row_offset = @intCast(screen_row),
                    .col_offset = @intCast(col_pos),
                });
            }

            // Overlay a severity sign in the leftmost gutter column.
            if (top_diag) |d| {
                const sign_text: []const u8 = switch (d.severity) {
                    .err => "E",
                    .warning => "W",
                    .info => "I",
                    .hint => "H",
                };
                const sign_color: vaxis.Cell.Color = switch (d.severity) {
                    .err => .{ .rgb = .{ 224, 108, 117 } },
                    .warning => .{ .rgb = .{ 229, 192, 123 } },
                    .info => .{ .rgb = .{ 86, 182, 194 } },
                    .hint => .{ .rgb = .{ 128, 128, 140 } },
                };
                _ = text_area.printSegment(.{
                    .text = sign_text,
                    .style = .{ .fg = sign_color, .bold = true },
                }, .{
                    .row_offset = @intCast(screen_row),
                    .col_offset = 0,
                });
            }

            var byte_idx: usize = 0;
            var char_idx: usize = 0;
            var current_col: usize = 0;

            while (byte_idx < line.len) {
                const len = std.unicode.utf8ByteSequenceLength(line[byte_idx]) catch 1;

                if (byte_idx + len > line.len) {
                    logWarn("draw: UTF-8 bounds overflow at byte {} (line len {})", .{ byte_idx, line.len });
                    break;
                }

                const char_slice = line[byte_idx .. byte_idx + len];
                var style: vaxis.Cell.Style = .{};
                var char_width: usize = 1;

                if (char_slice[0] == '\t') {
                    char_width = 4;
                }

                if (current_col + char_width > text_width) {
                    screen_row += 1;
                    current_col = 0;
                    if (screen_row >= text_area.height) break;
                }

                if (highlight_result.index) |token_index| {
                    if (token_index.findTokenAt(@intCast(file_line_num - 1), @intCast(byte_idx))) |token| {
                        style = styleForTokenType(token.token_type);
                    }
                }

                if (snapshot.selection_anchor_row) |anchor_row| {
                    if (snapshot.selection_anchor_col) |anchor_col| {
                        var start_row = anchor_row;
                        var start_col = anchor_col;
                        var end_row = snapshot.cursor_row;
                        var end_col = snapshot.cursor_col;

                        if (start_row > end_row or (start_row == end_row and start_col > end_col)) {
                            std.mem.swap(usize, &start_row, &end_row);
                            std.mem.swap(usize, &start_col, &end_col);
                        }

                        const current_row = file_line_num - 1;

                        var in_selection = false;
                        if (current_row > start_row and current_row < end_row) {
                            in_selection = true;
                        } else if (current_row == start_row and current_row == end_row) {
                            if (char_idx >= start_col and char_idx < end_col) in_selection = true;
                        } else if (current_row == start_row) {
                            if (char_idx >= start_col) in_selection = true;
                        } else if (current_row == end_row) {
                            if (char_idx < end_col) in_selection = true;
                        }

                        if (in_selection) style.reverse = true;
                    }
                }

                if (snapshot.editor_config.cursor_line and !style.reverse) {
                    const current_row = file_line_num - 1;
                    if (current_row == snapshot.cursor_row) {
                        style.bg = theme.styles.editor.cursor_line.bg;
                    }
                }

                _ = text_win.printSegment(.{ .text = char_slice, .style = style }, .{ .row_offset = @intCast(screen_row), .col_offset = @intCast(current_col) });

                current_col += char_width;
                byte_idx += len;
                char_idx += 1;
            }

            if (snapshot.selection_anchor_row) |anchor_row| {
                const current_row = file_line_num - 1;
                if (snapshot.selection_anchor_col) |anchor_col| {
                    var start_row = anchor_row;
                    var start_col = anchor_col;
                    var end_row = snapshot.cursor_row;
                    var end_col = snapshot.cursor_col;

                    if (start_row > end_row or (start_row == end_row and start_col > end_col)) {
                        std.mem.swap(usize, &start_row, &end_row);
                        std.mem.swap(usize, &start_col, &end_col);
                    }

                    var eol_selected = false;
                    if (current_row >= start_row and current_row < end_row) {
                        if (current_row > start_row) eol_selected = true;
                        if (current_row == start_row and char_idx >= start_col) eol_selected = true;
                    }

                    if (eol_selected) {
                        _ = text_win.printSegment(.{ .text = " ", .style = .{ .reverse = true } }, .{ .row_offset = @intCast(screen_row), .col_offset = @intCast(current_col) });
                    }
                }
            }

            // Inline virtual-text diagnostic at end-of-line, but only for the
            // line under the cursor — otherwise the whole screen turns into
            // a wall of red.
            if (top_diag) |d| {
                if (file_line_idx == snapshot.cursor_row) {
                    const msg_color: vaxis.Cell.Color = switch (d.severity) {
                        .err => .{ .rgb = .{ 224, 108, 117 } },
                        .warning => .{ .rgb = .{ 229, 192, 123 } },
                        .info => .{ .rgb = .{ 86, 182, 194 } },
                        .hint => .{ .rgb = .{ 128, 128, 140 } },
                    };
                    // Trim the message to a single line; LSP messages can be
                    // multi-line and would wreck the layout.
                    var msg = d.message;
                    if (std.mem.indexOfScalar(u8, msg, '\n')) |nl| msg = msg[0..nl];
                    const remaining_cols = if (current_col + 4 < text_width) text_width - current_col - 4 else 0;
                    if (remaining_cols > 0 and msg.len > 0) {
                        const display = if (msg.len > remaining_cols) msg[0..remaining_cols] else msg;
                        const prefix = " » ";
                        _ = text_win.printSegment(.{
                            .text = prefix,
                            .style = .{ .fg = msg_color, .italic = true },
                        }, .{ .row_offset = @intCast(screen_row), .col_offset = @intCast(current_col) });
                        _ = text_win.printSegment(.{
                            .text = display,
                            .style = .{ .fg = msg_color, .italic = true },
                        }, .{ .row_offset = @intCast(screen_row), .col_offset = @intCast(current_col + prefix.len) });
                    }
                }
            }

            screen_row += 1;
        }

        const cursor_in_view = snapshot.cursor_row >= first_line and snapshot.cursor_row < first_line + visible_lines.len;

        var final_cursor_col: u16 = @intCast(gutter_width);
        var final_cursor_row: u16 = tab_height;

        if (cursor_in_view) {
            const cursor_line_idx = snapshot.cursor_row - first_line;
            const cursor_line = visible_lines[cursor_line_idx];

            var cursor_screen_row: usize = 0;
            for (visible_lines[0..cursor_line_idx]) |prev_line| {
                var prev_col: usize = 0;
                var prev_byte: usize = 0;
                cursor_screen_row += 1;
                while (prev_byte < prev_line.len) {
                    const len = std.unicode.utf8ByteSequenceLength(prev_line[prev_byte]) catch 1;
                    if (prev_byte + len > prev_line.len) break;
                    var char_width: usize = 1;
                    if (prev_line[prev_byte] == '\t') char_width = 4;
                    if (prev_col + char_width > text_width) {
                        cursor_screen_row += 1;
                        prev_col = 0;
                    }
                    prev_col += char_width;
                    prev_byte += len;
                }
            }

            var cursor_screen_col: usize = 0;
            var byte_pos: usize = 0;
            var char_pos: usize = 0;
            while (byte_pos < cursor_line.len and char_pos < snapshot.cursor_col) {
                const len = std.unicode.utf8ByteSequenceLength(cursor_line[byte_pos]) catch 1;
                if (byte_pos + len > cursor_line.len) break;
                var char_width: usize = 1;
                if (cursor_line[byte_pos] == '\t') char_width = 4;
                if (cursor_screen_col + char_width > text_width) {
                    cursor_screen_row += 1;
                    cursor_screen_col = 0;
                }
                cursor_screen_col += char_width;
                byte_pos += len;
                char_pos += 1;
            }

            if (cursor_screen_col >= text_width) {
                cursor_screen_row += 1;
                cursor_screen_col = 0;
            }

            final_cursor_col = @intCast(gutter_width + cursor_screen_col);
            final_cursor_row = @intCast(tab_height + cursor_screen_row);
        }

        if (mode != .terminal) {
            final_cursor_col = @min(final_cursor_col, win.width -| 1);
            final_cursor_row = @min(final_cursor_row, win.height -| 1);
            win.showCursor(final_cursor_col, final_cursor_row);
        }

        self.drawScrollbar(text_area, total_lines, text_area.height, snapshot.scroll_offset);

        if (snapshot.hover_content) |content| {
            try self.drawHoverPopup(text_area, content, snapshot.cursor_row, snapshot.cursor_col, snapshot.scroll_offset);
        }

        if (snapshot.completion_active) {
            if (snapshot.completion_items) |items| {
                try self.drawCompletionPopup(text_area, items, snapshot.completion_selected, snapshot.cursor_row, snapshot.cursor_col, snapshot.scroll_offset);
            }
        }

        if (mode == .visual_search) {
            try self.drawSearchInput(win, snapshot.search_input orelse "", frame_allocator);
        }
    }

    fn drawSplitView(
        self: *View,
        vx: *vaxis.Vaxis,
        snapshot: *const protocol.RenderSnapshot,
        frame_allocator: std.mem.Allocator,
    ) !void {
        const win = vx.window();
        const status_height: u16 = 1;

        if (win.height < status_height + 2) return;

        const content_height = win.height - status_height;

        win.clear();

        for (snapshot.panes) |pane| {
            const x: u16 = @intFromFloat(pane.x * @as(f32, @floatFromInt(win.width)));
            const y: u16 = @intFromFloat(pane.y * @as(f32, @floatFromInt(content_height)));
            var width: u16 = @intFromFloat(pane.width * @as(f32, @floatFromInt(win.width)));
            var height: u16 = @intFromFloat(pane.height * @as(f32, @floatFromInt(content_height)));

            if (x + width < win.width) {
                width = if (width > 1) width - 1 else width;
            }
            if (y + height < content_height) {
                height = if (height > 1) height - 1 else height;
            }

            if (width == 0 or height == 0) continue;

            const pane_win = win.child(.{
                .x_off = x,
                .y_off = y,
                .width = width,
                .height = height,
            });

            if (pane.buffer_index < snapshot.buffers.len) {
                try self.drawPaneContent(pane_win, snapshot, pane, frame_allocator);

                if (pane.is_focused) {
                    if (snapshot.hover_content) |content| {
                        try self.drawHoverPopup(pane_win.child(.{ .y_off = 1, .height = height -| 1 }), content, pane.cursor_row, pane.cursor_col, pane.scroll_offset);
                    }
                }
            }

            if (pane.is_focused) {
                self.drawPaneFocusBorder(pane_win);
            }
        }

        self.drawPaneDividers(win, content_height, snapshot.panes);

        const status_area = win.child(.{
            .y_off = win.height - 1,
            .height = status_height,
        });
        try self.status_bar.draw(status_area, snapshot, frame_allocator);
    }

    fn drawPaneContent(
        self: *View,
        win: vaxis.Window,
        snapshot: *const protocol.RenderSnapshot,
        pane: protocol.PaneSnapshot,
        frame_allocator: std.mem.Allocator,
    ) !void {
        if (win.width == 0 or win.height == 0) return;

        const buf_name = if (pane.buffer_index < snapshot.buffers.len)
            snapshot.buffers[pane.buffer_index].name
        else
            "[Unknown]";

        const header_style = if (pane.is_focused)
            theme.styles.split.header_focused
        else
            theme.styles.split.header_unfocused;

        for (0..win.width) |i| {
            _ = win.printSegment(.{ .text = " ", .style = header_style }, .{ .row_offset = 0, .col_offset = @intCast(i) });
        }
        _ = win.printSegment(.{ .text = buf_name, .style = header_style }, .{ .row_offset = 0, .col_offset = 1 });

        const content_style = theme.styles.editor.default;
        const line_num_style = theme.styles.editor.line_number;

        const total_lines = pane.total_lines;
        const digits = if (total_lines > 0) std.math.log10_int(total_lines) + 1 else 1;
        const show_line_numbers = snapshot.editor_config.line_numbers != .none;
        const gutter_width: u16 = if (show_line_numbers) @intCast(digits + 1) else 0;

        for (1..win.height) |r| {
            for (0..win.width) |c| {
                _ = win.printSegment(.{ .text = " ", .style = content_style }, .{ .row_offset = @intCast(r), .col_offset = @intCast(c) });
            }
        }

        const is_help_buffer = std.mem.eql(u8, buf_name, "[HELP]") or
            std.mem.eql(u8, buf_name, "[PLUGINS]") or
            std.mem.eql(u8, buf_name, "[Plugin Stats]") or
            std.mem.eql(u8, buf_name, "[Git Status]") or
            std.mem.eql(u8, buf_name, "[Git Diff]") or
            std.mem.eql(u8, buf_name, "[Git Diff Staged]");

        const is_logs_buffer = std.mem.eql(u8, buf_name, "[LOGS]");

        const content_area = win.child(.{
            .y_off = 1,
            .height = if (win.height > 1) win.height - 1 else 1,
        });

        if (is_help_buffer and pane.visible_lines.len > 0) {
            self.help_view.draw(content_area, pane.visible_lines, pane.scroll_offset) catch {};
            return;
        }

        if (is_logs_buffer and pane.visible_lines.len > 0) {
            try LogView.drawBuffer(content_area, pane.visible_lines);
            return;
        }

        if (pane.visible_lines.len > 0) {
            var highlight_result = HighlightFallback.attemptHighlighting(
                frame_allocator,
                pane.syntax_tokens,
                pane.visible_lines,
                pane.scroll_offset,
            );
            defer if (highlight_result.index) |*idx| idx.deinit();

            var screen_row: u16 = 1;

            for (pane.visible_lines, 0..) |line, i| {
                if (screen_row >= win.height) break;

                const line_num = pane.scroll_offset + i;
                const file_line_num = line_num + 1;

                if (show_line_numbers) {
                    const display_num: usize = switch (snapshot.editor_config.line_numbers) {
                        .absolute => file_line_num,
                        .relative => blk: {
                            if (line_num == pane.cursor_row) {
                                break :blk file_line_num;
                            } else if (line_num > pane.cursor_row) {
                                break :blk line_num - pane.cursor_row;
                            } else {
                                break :blk pane.cursor_row - line_num;
                            }
                        },
                        .none => unreachable,
                    };
                    const line_num_str = try std.fmt.allocPrint(frame_allocator, "{d}", .{display_num});
                    const col_pos = if (gutter_width > line_num_str.len)
                        gutter_width - 1 - line_num_str.len
                    else
                        0;
                    _ = win.printSegment(.{ .text = line_num_str, .style = line_num_style }, .{
                        .row_offset = screen_row,
                        .col_offset = @intCast(col_pos),
                    });
                }

                const text_width = if (win.width > gutter_width) win.width - gutter_width else 1;
                var col: u16 = gutter_width;
                var current_col: usize = 0;
                var char_idx: usize = 0;
                var byte_idx: usize = 0;
                const current_screen_row = screen_row;

                while (byte_idx < line.len) {
                    if (current_screen_row >= win.height) break;

                    const len = std.unicode.utf8ByteSequenceLength(line[byte_idx]) catch 1;
                    const char_slice = line[byte_idx..@min(byte_idx + len, line.len)];
                    var char_width: usize = 1;

                    if (char_slice[0] == '\t') {
                        char_width = 4;
                    }

                    if (current_col + char_width > text_width) {
                        break;
                    }

                    var style = content_style;

                    if (highlight_result.index) |token_index| {
                        if (token_index.findTokenAt(@intCast(line_num), @intCast(byte_idx))) |token| {
                            style = styleForTokenType(token.token_type);
                        }
                    }

                    if (pane.diff_highlights) |highlights| {
                        for (highlights) |hl| {
                            if (hl.line == line_num) {
                                switch (hl.kind) {
                                    .added => {
                                        style.bg = .{ .rgb = .{ 0x1E, 0x3A, 0x1E } };
                                        style.fg = .{ .rgb = theme.colors.diff.add };
                                    },
                                    .changed => {
                                        style.bg = .{ .rgb = .{ 0x3A, 0x3A, 0x1E } };
                                        style.fg = .{ .rgb = theme.colors.diff.hunk };
                                    },
                                    .deleted => {
                                        style.bg = .{ .rgb = .{ 0x3A, 0x1E, 0x1E } };
                                        style.fg = .{ .rgb = theme.colors.diff.remove };
                                    },
                                }
                                break;
                            }
                        }
                    }

                    if (pane.selection_anchor_row) |anchor_row| {
                        if (pane.selection_anchor_col) |anchor_col| {
                            var start_row = anchor_row;
                            var start_col = anchor_col;
                            var end_row = pane.cursor_row;
                            var end_col = pane.cursor_col;

                            if (start_row > end_row or (start_row == end_row and start_col > end_col)) {
                                std.mem.swap(usize, &start_row, &end_row);
                                std.mem.swap(usize, &start_col, &end_col);
                            }

                            var in_selection = false;
                            if (line_num > start_row and line_num < end_row) {
                                in_selection = true;
                            } else if (line_num == start_row and line_num == end_row) {
                                if (char_idx >= start_col and char_idx < end_col) in_selection = true;
                            } else if (line_num == start_row) {
                                if (char_idx >= start_col) in_selection = true;
                            } else if (line_num == end_row) {
                                if (char_idx < end_col) in_selection = true;
                            }

                            if (in_selection) style.reverse = true;
                        }
                    }

                    if (snapshot.editor_config.cursor_line and !style.reverse and pane.is_focused) {
                        if (line_num == pane.cursor_row) {
                            style.bg = theme.styles.editor.cursor_line.bg;
                        }
                    }

                    if (pane.is_focused and line_num == pane.cursor_row and char_idx == pane.cursor_col) {
                        win.showCursor(col, current_screen_row);
                    }

                    _ = win.printSegment(.{ .text = char_slice, .style = style }, .{
                        .row_offset = current_screen_row,
                        .col_offset = col,
                    });

                    col += 1;
                    current_col += char_width;
                    byte_idx += len;
                    char_idx += 1;
                }

                if (pane.is_focused and line_num == pane.cursor_row and char_idx == pane.cursor_col) {
                    win.showCursor(col, current_screen_row);
                }

                screen_row = current_screen_row + 1;
            }
        }
    }

    fn drawPaneFocusBorder(self: *View, win: vaxis.Window) void {
        _ = self;
        const border_style: vaxis.Cell.Style = .{
            .fg = .{ .index = 4 },
            .bold = true,
        };

        _ = win.printSegment(.{ .text = "▌", .style = border_style }, .{ .row_offset = 0, .col_offset = 0 });
    }

    fn drawPaneDividers(self: *View, win: vaxis.Window, content_height: u16, panes: []const protocol.PaneSnapshot) void {
        _ = self;
        const divider_style: vaxis.Cell.Style = .{
            .fg = .{ .index = 8 },
            .bg = .{ .index = 0 },
        };

        for (panes) |pane| {
            const x_end: u16 = @intFromFloat((pane.x + pane.width) * @as(f32, @floatFromInt(win.width)));
            const y_end: u16 = @intFromFloat((pane.y + pane.height) * @as(f32, @floatFromInt(content_height)));

            if (x_end < win.width and x_end > 0) {
                const y_start: u16 = @intFromFloat(pane.y * @as(f32, @floatFromInt(content_height)));
                var row = y_start;
                while (row < y_end and row < content_height) : (row += 1) {
                    _ = win.printSegment(.{ .text = "│", .style = divider_style }, .{
                        .row_offset = row,
                        .col_offset = x_end - 1,
                    });
                }
            }

            if (y_end < content_height and y_end > 0) {
                const x_start: u16 = @intFromFloat(pane.x * @as(f32, @floatFromInt(win.width)));
                var col = x_start;
                while (col < x_end and col < win.width) : (col += 1) {
                    _ = win.printSegment(.{ .text = "─", .style = divider_style }, .{
                        .row_offset = y_end - 1,
                        .col_offset = col,
                    });
                }
            }
        }
    }

    fn drawScrollbar(self: *View, win: vaxis.Window, total_lines: usize, visible_lines: usize, scroll_offset: usize) void {
        _ = self;
        if (total_lines == 0 or total_lines <= visible_lines) return;

        const track_height = win.height;
        if (track_height == 0) return;

        var thumb_height = (visible_lines * track_height) / total_lines;
        if (thumb_height < 1) thumb_height = 1;

        var thumb_y = (scroll_offset * track_height) / total_lines;

        if (thumb_y + thumb_height > track_height) {
            thumb_y = track_height - thumb_height;
        }

        const style: vaxis.Cell.Style = .{
            .fg = .{ .index = 8 },
        };

        for (0..track_height) |y| {
            _ = win.printSegment(.{ .text = "│", .style = style }, .{ .row_offset = @intCast(y), .col_offset = win.width - 1 });
        }

        const thumb_style: vaxis.Cell.Style = .{
            .fg = .{ .index = 7 },
            .reverse = true,
        };

        for (0..thumb_height) |i| {
            _ = win.printSegment(.{ .text = " ", .style = thumb_style }, .{ .row_offset = @intCast(thumb_y + i), .col_offset = win.width - 1 });
        }
    }

    fn drawTerminalOutput(self: *View, win: vaxis.Window, snapshot: *const protocol.RenderSnapshot) !void {
        const output = snapshot.terminal_output orelse return;
        const scroll_offset = snapshot.terminal_scroll_offset;
        const is_running = snapshot.terminal_running;

        const header_style: vaxis.Cell.Style = .{
            .fg = .{ .index = 0 },
            .bg = .{ .index = 8 },
        };

        for (0..win.width) |i| {
            _ = win.printSegment(.{ .text = " ", .style = header_style }, .{ .col_offset = @intCast(i) });
        }

        if (is_running) {
            _ = win.printSegment(.{
                .text = " Running... ",
                .style = .{
                    .fg = .{ .index = 11 },
                    .bg = .{ .index = 8 },
                },
            }, .{ .col_offset = 1 });
        } else {
            _ = win.printSegment(.{ .text = " Output ", .style = header_style }, .{ .col_offset = 1 });
        }

        var total_lines: usize = 0;
        var line_counter = std.mem.splitScalar(u8, output, '\n');
        while (line_counter.next()) |_| {
            total_lines += 1;
        }
        if (!is_running) total_lines += 1;

        const visible_height = if (win.height > 1) win.height - 1 else 1;
        if (total_lines > visible_height) {
            var scroll_buf: [32]u8 = undefined;
            const scroll_text = std.fmt.bufPrint(&scroll_buf, "[{d}/{d}] ", .{
                @min(scroll_offset + 1, total_lines),
                total_lines,
            }) catch "";

            if (scroll_text.len > 0 and win.width > scroll_text.len + 2) {
                const scroll_col: u16 = @intCast(win.width - scroll_text.len - 1);
                _ = win.printSegment(.{
                    .text = scroll_text,
                    .style = header_style,
                }, .{ .col_offset = scroll_col });
            }
        }

        const output_style: vaxis.Cell.Style = .{
            .fg = .{ .index = 7 },
            .bg = .{ .index = 0 },
        };

        var row: u16 = 1;
        while (row < win.height) : (row += 1) {
            for (0..win.width) |col| {
                _ = win.printSegment(.{ .text = " ", .style = output_style }, .{
                    .row_offset = row,
                    .col_offset = @intCast(col),
                });
            }
        }

        var lines_it = std.mem.splitScalar(u8, output, '\n');
        var line_num: usize = 0;
        row = 1;

        while (lines_it.next()) |line| {
            if (line_num >= scroll_offset) {
                if (row < win.height) {
                    _ = try self.drawAnsiLine(win, line, row, output_style, 1);
                    row += 1;
                } else break;
            }
            line_num += 1;
        }

        if (!is_running and row < win.height) {
            const cwd_style: vaxis.Cell.Style = .{
                .fg = .{ .index = 12 },
                .bg = .{ .index = 0 },
                .bold = true,
            };
            const prompt_style: vaxis.Cell.Style = .{
                .fg = .{ .index = 7 },
                .bg = .{ .index = 0 },
            };
            const input_style: vaxis.Cell.Style = .{
                .fg = .{ .index = 15 },
                .bg = .{ .index = 0 },
            };

            var col: u16 = 1;

            if (snapshot.terminal_cwd) |cwd| {
                _ = win.printSegment(.{ .text = "[", .style = cwd_style }, .{
                    .row_offset = row,
                    .col_offset = col,
                });
                col += 1;

                const max_cwd_len: usize = if (win.width > 30) win.width - 20 else 10;
                const display_cwd = if (cwd.len > max_cwd_len)
                    cwd[cwd.len - max_cwd_len ..]
                else
                    cwd;
                _ = win.printSegment(.{ .text = display_cwd, .style = cwd_style }, .{
                    .row_offset = row,
                    .col_offset = col,
                });
                col += @intCast(display_cwd.len);

                _ = win.printSegment(.{ .text = "]", .style = cwd_style }, .{
                    .row_offset = row,
                    .col_offset = col,
                });
                col += 1;
            }

            _ = win.printSegment(.{ .text = " $ ", .style = prompt_style }, .{
                .row_offset = row,
                .col_offset = col,
            });
            col += 3;

            if (snapshot.terminal_input) |input| {
                if (input.len > 0) {
                    _ = win.printSegment(.{ .text = input, .style = input_style }, .{
                        .row_offset = row,
                        .col_offset = col,
                    });
                    col += @intCast(input.len);
                }
            }

            win.showCursor(col, row);
        }
    }

    fn drawAnsiLine(self: *View, win: vaxis.Window, line: []const u8, row: u16, base_style: vaxis.Cell.Style, start_col: u16) !u16 {
        _ = self;
        var col: u16 = start_col;
        var i: usize = 0;
        var current_style = base_style;

        while (i < line.len) {
            if (line[i] == '\x1b' and i + 1 < line.len and line[i + 1] == '[') {
                i += 2;
                const start = i;
                while (i < line.len and ((line[i] >= '0' and line[i] <= '?') or (line[i] >= ' ' and line[i] <= '/'))) i += 1;
                if (i < line.len) {
                    const final_byte = line[i];
                    i += 1;
                    if (final_byte == 'm') {
                        const params = line[start .. i - 1];
                        current_style = applyAnsiSgr(current_style, params);
                    }
                }
                continue;
            }

            const len = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
            if (i + len <= line.len) {
                const char = line[i .. i + len];
                _ = win.printSegment(.{ .text = char, .style = current_style }, .{
                    .row_offset = row,
                    .col_offset = col,
                });
                col += 1;
                i += len;
            } else {
                i += 1;
            }
            if (col >= win.width) break;
        }
        return col;
    }

    fn applyAnsiSgr(style: vaxis.Cell.Style, params: []const u8) vaxis.Cell.Style {
        var new_style = style;
        var it = std.mem.splitScalar(u8, params, ';');
        var has_params = false;
        while (it.next()) |param_str| {
            if (param_str.len == 0) continue;
            const param = std.fmt.parseInt(u8, param_str, 10) catch continue;
            has_params = true;
            switch (param) {
                0 => {
                    new_style.bold = false;
                    new_style.dim = false;
                    new_style.reverse = false;
                    new_style.fg = .default;
                    new_style.bg = .default;
                },
                1 => new_style.bold = true,
                2 => new_style.dim = true,
                7 => new_style.reverse = true,
                22 => {
                    new_style.bold = false;
                    new_style.dim = false;
                },
                27 => new_style.reverse = false,
                30...37 => new_style.fg = .{ .index = param - 30 },
                39 => new_style.fg = .default,
                40...47 => new_style.bg = .{ .index = param - 40 },
                49 => new_style.bg = .default,
                90...97 => new_style.fg = .{ .index = param - 90 + 8 },
                100...107 => new_style.bg = .{ .index = param - 100 + 8 },
                else => {},
            }
        }

        if (!has_params) {
            new_style.bold = false;
            new_style.dim = false;
            new_style.reverse = false;
            new_style.fg = .default;
            new_style.bg = .default;
        }
        return new_style;
    }

    fn drawSaveAsInput(self: *View, win: vaxis.Window, input: []const u8, allocator: std.mem.Allocator) !void {
        _ = self;
        _ = allocator;

        const overlay_style: vaxis.Cell.Style = .{
            .fg = .{ .index = 7 },
            .bg = .{ .index = 0 },
        };

        for (0..win.height) |row| {
            for (0..win.width) |col| {
                _ = win.printSegment(.{ .text = " ", .style = overlay_style }, .{
                    .row_offset = @intCast(row),
                    .col_offset = @intCast(col),
                });
            }
        }

        const box_width: u16 = 50;
        const box_height: u16 = 3;
        const box_x = (win.width - box_width) / 2;
        const box_y = (win.height - box_height) / 2;

        const box_style: vaxis.Cell.Style = .{
            .fg = .{ .index = 0 },
            .bg = .{ .index = 6 },
        };

        const input_style: vaxis.Cell.Style = .{
            .fg = .{ .index = 0 },
            .bg = .{ .index = 7 },
        };

        for (0..box_height) |i| {
            const row = box_y + @as(u16, @intCast(i));
            for (0..box_width) |j| {
                const col = box_x + @as(u16, @intCast(j));
                _ = win.printSegment(.{ .text = " ", .style = box_style }, .{
                    .row_offset = row,
                    .col_offset = col,
                });
            }
        }

        const title = " Save As: ";
        _ = win.printSegment(.{ .text = title, .style = box_style }, .{
            .row_offset = box_y,
            .col_offset = box_x + 1,
        });

        const input_row = box_y + 1;
        const input_col = box_x + 2;
        const input_width = box_width - 4;

        for (0..input_width) |i| {
            _ = win.printSegment(.{ .text = " ", .style = input_style }, .{
                .row_offset = input_row,
                .col_offset = input_col + @as(u16, @intCast(i)),
            });
        }

        const display_text = if (input.len > input_width)
            input[input.len - input_width ..]
        else
            input;

        _ = win.printSegment(.{ .text = display_text, .style = input_style }, .{
            .row_offset = input_row,
            .col_offset = input_col,
        });

        const cursor_col_pos = input_col + @as(u16, @intCast(@min(display_text.len, input_width - 1)));
        _ = win.printSegment(.{ .text = " ", .style = .{ .reverse = true } }, .{
            .row_offset = input_row,
            .col_offset = cursor_col_pos,
        });
    }

    fn drawHoverPopup(self: *View, win: vaxis.Window, content: []const u8, cursor_row: usize, cursor_col: usize, scroll_offset: usize) !void {
        if (content.len == 0) return;

        if (win.width < 10 or win.height < 5) {
            logDebug("drawHoverPopup: Window too small ({}x{})", .{ win.width, win.height });
            return;
        }

        if (content.len > 50000) {
            logWarn("drawHoverPopup: Content too large ({}), truncating", .{content.len});
            return;
        }

        const screen_row = cursor_row -| scroll_offset;
        const screen_col = cursor_col;

        const border_style: vaxis.Cell.Style = .{
            .fg = .{ .rgb = .{ 108, 112, 134 } },
            .bg = .{ .rgb = .{ 30, 30, 46 } },
        };
        const header_style: vaxis.Cell.Style = .{
            .fg = .{ .rgb = .{ 180, 190, 254 } },
            .bg = .{ .rgb = .{ 30, 30, 46 } },
            .bold = true,
        };
        const code_style: vaxis.Cell.Style = .{
            .fg = .{ .rgb = .{ 137, 180, 250 } },
            .bg = .{ .rgb = .{ 30, 30, 46 } },
        };
        const doc_style: vaxis.Cell.Style = .{
            .fg = .{ .rgb = .{ 205, 214, 244 } },
            .bg = .{ .rgb = .{ 30, 30, 46 } },
        };
        const hint_style: vaxis.Cell.Style = .{
            .fg = .{ .rgb = .{ 88, 91, 112 } },
            .bg = .{ .rgb = .{ 30, 30, 46 } },
        };

        var wrapped_lines = std.ArrayList(vaxis.Segment).initCapacity(self.allocator, 32) catch return;
        defer wrapped_lines.deinit(self.allocator);

        const max_width: u16 = 70;
        const max_height: u16 = 15;
        var content_width: u16 = 0;

        var lines_iter = std.mem.splitScalar(u8, content, '\n');
        var is_first_line = true;
        while (lines_iter.next()) |line| {
            var style = doc_style;

            if (is_first_line or std.mem.startsWith(u8, line, "fn ") or std.mem.startsWith(u8, line, "pub ") or
                std.mem.startsWith(u8, line, "const ") or std.mem.startsWith(u8, line, "var ") or
                std.mem.indexOf(u8, line, "->") != null or std.mem.indexOf(u8, line, ":") != null)
            {
                style = code_style;
            }

            if (line.len == 0) {
                try wrapped_lines.append(self.allocator, .{ .text = "", .style = style });
                continue;
            }

            var remaining = line;
            while (remaining.len > 0) {
                var split_idx = remaining.len;
                if (remaining.len > max_width - 4) {
                    var space_idx: ?usize = null;
                    var i: usize = @min(max_width - 4, remaining.len);
                    while (i > 0) : (i -= 1) {
                        if (remaining[i] == ' ') {
                            space_idx = i;
                            break;
                        }
                    }
                    split_idx = space_idx orelse @min(max_width - 4, remaining.len);
                }

                const segment_text = remaining[0..split_idx];
                try wrapped_lines.append(self.allocator, .{ .text = segment_text, .style = style });
                content_width = @max(content_width, @as(u16, @intCast(segment_text.len)));

                if (split_idx < remaining.len) {
                    const next_start = if (remaining[split_idx] == ' ') split_idx + 1 else split_idx;
                    if (next_start >= remaining.len) break;
                    remaining = remaining[next_start..];
                } else {
                    break;
                }
            }
            is_first_line = false;
        }

        var display_lines_count: u16 = @min(@as(u16, @intCast(wrapped_lines.items.len)), max_height - 3);
        const width: u16 = @max(20, @min(max_width, content_width + 4));
        var height: u16 = display_lines_count + 2;

        // Pick vertical position: prefer the side with more room. If the
        // cursor is in the upper half, render below; otherwise above. Falls
        // back to truncating when nothing fits.
        const cursor_screen_row: u16 = @intCast(@min(screen_row, @as(usize, std.math.maxInt(u16))));
        const space_above: u16 = cursor_screen_row;
        const space_below: u16 = win.height -| (cursor_screen_row + 1);
        const prefer_above = space_above > space_below;

        var box_y: u16 = 0;
        if (prefer_above and space_above >= height) {
            box_y = cursor_screen_row - height;
        } else if (!prefer_above and space_below >= height) {
            box_y = cursor_screen_row + 1;
        } else if (space_below >= 3) {
            // Truncate to fit below.
            display_lines_count = @min(display_lines_count, space_below - 2);
            height = display_lines_count + 2;
            box_y = cursor_screen_row + 1;
        } else if (space_above >= 3) {
            display_lines_count = @min(display_lines_count, space_above - 2);
            height = display_lines_count + 2;
            box_y = cursor_screen_row -| height;
        } else {
            return;
        }

        // Horizontal: keep at cursor col when it fits, else slide left to
        // keep the popup fully inside the window. Leaves a 1-col margin from
        // the right edge so the box doesn't kiss the scrollbar.
        const margin: u16 = 1;
        const max_box_x: u16 = if (win.width > width + margin) win.width - width - margin else 0;
        const box_x: u16 = @intCast(@min(screen_col, @as(usize, max_box_x)));

        _ = win.printSegment(.{ .text = "╭", .style = border_style }, .{ .row_offset = box_y, .col_offset = box_x });
        for (1..width - 1) |i| {
            _ = win.printSegment(.{ .text = "─", .style = border_style }, .{ .row_offset = box_y, .col_offset = box_x + @as(u16, @intCast(i)) });
        }
        _ = win.printSegment(.{ .text = "╮", .style = border_style }, .{ .row_offset = box_y, .col_offset = box_x + width - 1 });

        _ = win.printSegment(.{ .text = "│", .style = border_style }, .{ .row_offset = box_y + 1, .col_offset = box_x });
        for (1..width - 1) |i| {
            _ = win.printSegment(.{ .text = " ", .style = header_style }, .{ .row_offset = box_y + 1, .col_offset = box_x + @as(u16, @intCast(i)) });
        }
        _ = win.printSegment(.{ .text = " Hover", .style = header_style }, .{ .row_offset = box_y + 1, .col_offset = box_x + 1 });
        // Right-aligned hint "esc to dismiss" if there's room.
        const hint = "esc to dismiss ";
        if (width > hint.len + 8) {
            const hint_col = box_x + width - 1 - @as(u16, @intCast(hint.len));
            _ = win.printSegment(.{
                .text = hint,
                .style = .{ .fg = .{ .rgb = .{ 108, 112, 134 } }, .bg = .{ .rgb = .{ 30, 30, 46 } }, .italic = true },
            }, .{ .row_offset = box_y + 1, .col_offset = hint_col });
        }
        _ = win.printSegment(.{ .text = "│", .style = border_style }, .{ .row_offset = box_y + 1, .col_offset = box_x + width - 1 });

        for (0..display_lines_count) |i| {
            const row = box_y + 2 + @as(u16, @intCast(i));
            _ = win.printSegment(.{ .text = "│", .style = border_style }, .{ .row_offset = row, .col_offset = box_x });

            for (1..width - 1) |j| {
                _ = win.printSegment(.{ .text = " ", .style = doc_style }, .{ .row_offset = row, .col_offset = box_x + @as(u16, @intCast(j)) });
            }

            if (i < wrapped_lines.items.len) {
                const seg = wrapped_lines.items[i];
                _ = win.printSegment(.{ .text = seg.text, .style = seg.style }, .{ .row_offset = row, .col_offset = box_x + 2 });
            }

            _ = win.printSegment(.{ .text = "│", .style = border_style }, .{ .row_offset = row, .col_offset = box_x + width - 1 });
        }

        var extra_rows: u16 = 0;
        if (wrapped_lines.items.len > display_lines_count) {
            const more_text = try std.fmt.allocPrint(self.allocator, "↓ +{d} more", .{wrapped_lines.items.len - display_lines_count});
            defer self.allocator.free(more_text);
            const scroll_row = box_y + 2 + display_lines_count;
            _ = win.printSegment(.{ .text = "│", .style = border_style }, .{ .row_offset = scroll_row, .col_offset = box_x });
            for (1..width - 1) |j| {
                _ = win.printSegment(.{ .text = " ", .style = hint_style }, .{ .row_offset = scroll_row, .col_offset = box_x + @as(u16, @intCast(j)) });
            }
            _ = win.printSegment(.{ .text = more_text, .style = hint_style }, .{ .row_offset = scroll_row, .col_offset = box_x + 2 });
            _ = win.printSegment(.{ .text = "│", .style = border_style }, .{ .row_offset = scroll_row, .col_offset = box_x + width - 1 });
            extra_rows = 1;
        }

        const bottom_row = box_y + 2 + display_lines_count + extra_rows;
        _ = win.printSegment(.{ .text = "╰", .style = border_style }, .{ .row_offset = bottom_row, .col_offset = box_x });
        for (1..width - 1) |i| {
            _ = win.printSegment(.{ .text = "─", .style = border_style }, .{ .row_offset = bottom_row, .col_offset = box_x + @as(u16, @intCast(i)) });
        }
        _ = win.printSegment(.{ .text = "╯", .style = border_style }, .{ .row_offset = bottom_row, .col_offset = box_x + width - 1 });
    }

    fn drawCompletionPopup(
        self: *View,
        win: vaxis.Window,
        items: []const protocol.CompletionEntry,
        selected_index: usize,
        cursor_row: usize,
        cursor_col: usize,
        scroll_offset: usize,
    ) !void {
        if (items.len == 0) return;
        if (win.width < 15 or win.height < 5) {
            logDebug("drawCompletionPopup: Window too small ({}x{})", .{ win.width, win.height });
            return;
        }

        const safe_items = if (items.len > 1000) items[0..1000] else items;

        const max_width: u16 = 50;
        const max_visible: u16 = 10;
        const visible_count: u16 = @min(@as(u16, @intCast(safe_items.len)), max_visible);
        const total_height: u16 = visible_count + 3;

        const screen_row = cursor_row -| scroll_offset;
        const screen_col = cursor_col;

        var box_y: u16 = @intCast(screen_row + 1);
        if (box_y + total_height > win.height) {
            box_y = @intCast(screen_row -| total_height);
        }

        var box_x: u16 = @intCast(screen_col);
        if (box_x + max_width > win.width) {
            box_x = win.width -| max_width;
        }

        const border_style: vaxis.Cell.Style = .{
            .fg = .{ .index = 8 },
            .bg = .{ .index = 0 },
        };
        const header_style: vaxis.Cell.Style = .{
            .fg = .{ .index = 4 },
            .bg = .{ .index = 0 },
            .bold = true,
        };
        const bg_style: vaxis.Cell.Style = .{
            .fg = .{ .index = 7 },
            .bg = .{ .index = 0 },
        };
        const selected_style: vaxis.Cell.Style = .{
            .fg = .{ .index = 0 },
            .bg = .{ .index = 6 },
        };
        const scroll_style: vaxis.Cell.Style = .{
            .fg = .{ .index = 4 },
            .bg = .{ .index = 0 },
        };

        var start_index: usize = 0;
        if (selected_index >= max_visible) {
            start_index = selected_index - max_visible + 1;
        }

        _ = win.printSegment(.{ .text = "╭", .style = border_style }, .{ .row_offset = box_y, .col_offset = box_x });
        for (1..max_width - 1) |i| {
            _ = win.printSegment(.{ .text = "─", .style = border_style }, .{ .row_offset = box_y, .col_offset = box_x + @as(u16, @intCast(i)) });
        }
        _ = win.printSegment(.{ .text = "╮", .style = border_style }, .{ .row_offset = box_y, .col_offset = box_x + max_width - 1 });

        const header_row = box_y + 1;
        _ = win.printSegment(.{ .text = "│", .style = border_style }, .{ .row_offset = header_row, .col_offset = box_x });
        for (1..max_width - 1) |i| {
            _ = win.printSegment(.{ .text = " ", .style = header_style }, .{ .row_offset = header_row, .col_offset = box_x + @as(u16, @intCast(i)) });
        }
        const header_text = " Completions ";
        _ = win.printSegment(.{ .text = header_text, .style = header_style }, .{ .row_offset = header_row, .col_offset = box_x + 1 });
        const count_text_buf = std.fmt.allocPrint(self.allocator, "{d}/{d}", .{ selected_index + 1, items.len }) catch "";
        defer if (count_text_buf.len > 0) self.allocator.free(count_text_buf);
        if (count_text_buf.len > 0 and count_text_buf.len < max_width - header_text.len - 3) {
            const count_pos = max_width - @as(u16, @intCast(count_text_buf.len)) - 2;
            _ = win.printSegment(.{ .text = count_text_buf, .style = .{ .fg = .{ .index = 8 }, .bg = .{ .index = 0 } } }, .{ .row_offset = header_row, .col_offset = box_x + count_pos });
        }
        _ = win.printSegment(.{ .text = "│", .style = border_style }, .{ .row_offset = header_row, .col_offset = box_x + max_width - 1 });

        const has_scroll = items.len > max_visible;
        const content_width: u16 = if (has_scroll) max_width - 3 else max_width - 2;

        for (0..visible_count) |i| {
            const item_idx = start_index + i;
            if (item_idx >= items.len) break;

            const item = items[item_idx];
            const is_selected = item_idx == selected_index;
            const row_style = if (is_selected) selected_style else bg_style;
            const row = box_y + 2 + @as(u16, @intCast(i));

            _ = win.printSegment(.{ .text = "│", .style = border_style }, .{ .row_offset = row, .col_offset = box_x });

            for (1..max_width - 1) |j| {
                _ = win.printSegment(.{ .text = " ", .style = row_style }, .{ .row_offset = row, .col_offset = box_x + @as(u16, @intCast(j)) });
            }

            if (item.kind.len > 0) {
                // Color the kind glyph based on category so the user can
                // scan the popup by color before reading labels.
                const kind_fg: vaxis.Cell.Color = switch (item.kind_category) {
                    .function => .{ .rgb = .{ 137, 180, 250 } }, // blue
                    .variable => .{ .rgb = .{ 243, 139, 168 } }, // red
                    .field => .{ .rgb = .{ 137, 220, 235 } }, // cyan
                    .type_ => .{ .rgb = .{ 249, 226, 175 } }, // yellow
                    .module => .{ .rgb = .{ 180, 190, 254 } }, // muted blue
                    .keyword => .{ .rgb = .{ 203, 166, 247 } }, // purple
                    .value => .{ .rgb = .{ 250, 179, 135 } }, // orange
                    .snippet => .{ .rgb = .{ 166, 227, 161 } }, // green
                    .text => .{ .rgb = .{ 205, 214, 244 } }, // muted white
                    .other => .{ .index = 3 },
                };
                const kind_disp_style: vaxis.Cell.Style = if (is_selected)
                    selected_style
                else
                    .{ .fg = kind_fg, .bg = .{ .index = 0 } };
                _ = win.printSegment(.{ .text = item.kind, .style = kind_disp_style }, .{ .row_offset = row, .col_offset = box_x + 2 });
            }

            const label_offset: u16 = if (item.kind.len > 0) @intCast(item.kind.len + 3) else 2;
            if (label_offset < content_width) {
                const max_label_len: usize = @as(usize, content_width - label_offset);
                const label_display = if (item.label.len > max_label_len) item.label[0..max_label_len] else item.label;
                _ = win.printSegment(.{ .text = label_display, .style = row_style }, .{ .row_offset = row, .col_offset = box_x + label_offset });
            }

            if (has_scroll) {
                const scroll_col = box_x + max_width - 2;
                const scroll_range: usize = visible_count;
                const thumb_pos = (i * items.len) / scroll_range;
                const is_thumb = thumb_pos >= start_index and thumb_pos < start_index + visible_count;
                const scroll_char = if (is_thumb and i == (selected_index - start_index)) "█" else "░";
                _ = win.printSegment(.{ .text = scroll_char, .style = scroll_style }, .{ .row_offset = row, .col_offset = scroll_col });
            }

            _ = win.printSegment(.{ .text = "│", .style = border_style }, .{ .row_offset = row, .col_offset = box_x + max_width - 1 });
        }

        const bottom_row = box_y + 2 + visible_count;
        _ = win.printSegment(.{ .text = "╰", .style = border_style }, .{ .row_offset = bottom_row, .col_offset = box_x });
        for (1..max_width - 1) |i| {
            _ = win.printSegment(.{ .text = "─", .style = border_style }, .{ .row_offset = bottom_row, .col_offset = box_x + @as(u16, @intCast(i)) });
        }
        _ = win.printSegment(.{ .text = "╯", .style = border_style }, .{ .row_offset = bottom_row, .col_offset = box_x + max_width - 1 });
    }

    fn drawSearchInput(self: *View, win: vaxis.Window, input: []const u8, allocator: std.mem.Allocator) !void {
        _ = self;
        _ = allocator;

        const box_width: u16 = 40;
        const box_height: u16 = 3;
        const box_x = (win.width - box_width) / 2;
        const box_y = win.height - box_height - 2;

        const box_style: vaxis.Cell.Style = .{
            .fg = .{ .index = 0 },
            .bg = .{ .index = 14 },
        };

        const input_style: vaxis.Cell.Style = .{
            .fg = .{ .index = 0 },
            .bg = .{ .index = 7 },
        };

        for (0..box_height) |i| {
            const row = box_y + @as(u16, @intCast(i));
            for (0..box_width) |j| {
                const col = box_x + @as(u16, @intCast(j));
                _ = win.printSegment(.{ .text = " ", .style = box_style }, .{
                    .row_offset = row,
                    .col_offset = col,
                });
            }
        }

        const title = " Search: ";
        _ = win.printSegment(.{ .text = title, .style = box_style }, .{
            .row_offset = box_y,
            .col_offset = box_x + 1,
        });

        const input_row = box_y + 1;
        const input_col = box_x + 2;
        const input_width = box_width - 4;

        for (0..input_width) |i| {
            _ = win.printSegment(.{ .text = " ", .style = input_style }, .{
                .row_offset = input_row,
                .col_offset = input_col + @as(u16, @intCast(i)),
            });
        }

        const display_text = if (input.len > input_width)
            input[input.len - input_width ..]
        else
            input;

        _ = win.printSegment(.{ .text = display_text, .style = input_style }, .{
            .row_offset = input_row,
            .col_offset = input_col,
        });

        const cursor_col_pos = input_col + @as(u16, @intCast(@min(display_text.len, input_width - 1)));
        _ = win.printSegment(.{ .text = " ", .style = .{ .reverse = true } }, .{
            .row_offset = input_row,
            .col_offset = cursor_col_pos,
        });
    }

    fn drawCommandPalette(self: *View, win: vaxis.Window, snapshot: *const protocol.RenderSnapshot, allocator: std.mem.Allocator) !void {
        _ = self;
        _ = allocator;

        const cp = theme.styles.command_palette;

        for (0..win.height) |row| {
            for (0..win.width) |col| {
                _ = win.printSegment(.{ .text = " ", .style = cp.overlay }, .{
                    .row_offset = @intCast(row),
                    .col_offset = @intCast(col),
                });
            }
        }

        const width: usize = @min(win.width -| 4, 80);
        const height: usize = @min(win.height -| 6, 25);

        const start_x: usize = (win.width - width) / 2;
        const start_y: usize = @max((win.height - height) / 3, 2);

        for (1..width) |i| {
            _ = win.printSegment(.{ .text = "─", .style = cp.border }, .{ .row_offset = @intCast(start_y), .col_offset = @intCast(start_x + i) });
            _ = win.printSegment(.{ .text = "─", .style = cp.border }, .{ .row_offset = @intCast(start_y + height + 3), .col_offset = @intCast(start_x + i) });
        }
        for (1..height + 4) |i| {
            _ = win.printSegment(.{ .text = "│", .style = cp.border }, .{ .row_offset = @intCast(start_y + i), .col_offset = @intCast(start_x) });
            _ = win.printSegment(.{ .text = "│", .style = cp.border }, .{ .row_offset = @intCast(start_y + i), .col_offset = @intCast(start_x + width) });
        }
        _ = win.printSegment(.{ .text = "╭", .style = cp.border }, .{ .row_offset = @intCast(start_y), .col_offset = @intCast(start_x) });
        _ = win.printSegment(.{ .text = "╮", .style = cp.border }, .{ .row_offset = @intCast(start_y), .col_offset = @intCast(start_x + width) });
        _ = win.printSegment(.{ .text = "╰", .style = cp.border }, .{ .row_offset = @intCast(start_y + height + 3), .col_offset = @intCast(start_x) });
        _ = win.printSegment(.{ .text = "╯", .style = cp.border }, .{ .row_offset = @intCast(start_y + height + 3), .col_offset = @intCast(start_x + width) });

        const title = " Command Palette ";
        for (1..width) |i| {
            _ = win.printSegment(.{ .text = " ", .style = cp.title }, .{ .row_offset = @intCast(start_y + 1), .col_offset = @intCast(start_x + i) });
        }
        _ = win.printSegment(.{ .text = title, .style = cp.title }, .{ .row_offset = @intCast(start_y + 1), .col_offset = @intCast(start_x + 2) });

        for (1..width) |i| {
            _ = win.printSegment(.{ .text = "─", .style = cp.border }, .{ .row_offset = @intCast(start_y + 2), .col_offset = @intCast(start_x + i) });
        }

        const input_prefix = "> ";
        _ = win.printSegment(.{ .text = input_prefix, .style = cp.input_prefix }, .{ .row_offset = @intCast(start_y + 3), .col_offset = @intCast(start_x + 2) });

        const query = snapshot.command_palette_query orelse "";
        _ = win.printSegment(.{ .text = query, .style = cp.input }, .{ .row_offset = @intCast(start_y + 3), .col_offset = @intCast(start_x + 2 + input_prefix.len) });

        _ = win.printSegment(.{ .text = " ", .style = .{ .reverse = true } }, .{ .row_offset = @intCast(start_y + 3), .col_offset = @intCast(start_x + 2 + input_prefix.len + query.len) });

        for (1..width) |i| {
            _ = win.printSegment(.{ .text = "─", .style = cp.border }, .{ .row_offset = @intCast(start_y + 4), .col_offset = @intCast(start_x + i) });
        }

        if (snapshot.command_palette_results) |results| {
            const visible_height = height -| 2;
            var start_index: usize = 0;
            if (snapshot.command_palette_selected >= visible_height) {
                start_index = snapshot.command_palette_selected - visible_height + 1;
            }

            const render_count = @min(visible_height, results.len);

            for (0..render_count) |i| {
                const item_index = start_index + i;
                if (item_index >= results.len) break;

                const cmd = results[item_index];
                const row = start_y + 5 + i;
                const is_selected = item_index == snapshot.command_palette_selected;
                const style = if (is_selected) cp.item_selected else cp.item;
                const key_style = if (is_selected) cp.keybinding_selected else cp.keybinding;

                for (1..width) |j| {
                    _ = win.printSegment(.{ .text = " ", .style = style }, .{ .row_offset = @intCast(row), .col_offset = @intCast(start_x + j) });
                }

                _ = win.printSegment(.{ .text = cmd.title, .style = style }, .{ .row_offset = @intCast(row), .col_offset = @intCast(start_x + 3) });

                if (width > cmd.title.len + cmd.description.len + 8) {
                    _ = win.printSegment(.{ .text = cmd.description, .style = key_style }, .{ .row_offset = @intCast(row), .col_offset = @intCast(start_x + width - cmd.description.len - 2) });
                }
            }

            if (results.len > visible_height) {
                const scroll_track_height = visible_height;
                const thumb_size = @max(1, (visible_height * visible_height) / results.len);
                const thumb_pos = (start_index * scroll_track_height) / results.len;

                for (0..scroll_track_height) |i| {
                    const is_thumb = i >= thumb_pos and i < thumb_pos + thumb_size;
                    const scroll_char: []const u8 = if (is_thumb) "█" else "░";
                    const scroll_style = if (is_thumb) cp.scrollbar_thumb else cp.scrollbar;
                    _ = win.printSegment(.{ .text = scroll_char, .style = scroll_style }, .{ .row_offset = @intCast(start_y + 5 + i), .col_offset = @intCast(start_x + width - 1) });
                }
            }
        }

        const footer_row = start_y + height + 3;
        const hints = " ↑↓ Navigate  Enter Execute  Esc Cancel ";
        _ = win.printSegment(.{ .text = hints, .style = cp.footer }, .{ .row_offset = @intCast(footer_row), .col_offset = @intCast(start_x + 2) });
    }

    fn drawGoToLine(self: *View, win: vaxis.Window, snapshot: *const protocol.RenderSnapshot, allocator: std.mem.Allocator) !void {
        _ = self;
        _ = allocator;

        const overlay_style: vaxis.Cell.Style = .{
            .fg = .{ .index = 7 },
            .bg = .{ .index = 0 },
        };

        for (0..win.height) |row| {
            for (0..win.width) |col| {
                _ = win.printSegment(.{ .text = " ", .style = overlay_style }, .{
                    .row_offset = @intCast(row),
                    .col_offset = @intCast(col),
                });
            }
        }

        const box_width: u16 = 35;
        const box_height: u16 = 3;
        const box_x = (win.width - box_width) / 2;
        const box_y = (win.height - box_height) / 2;

        const box_style: vaxis.Cell.Style = .{
            .fg = .{ .index = 0 },
            .bg = .{ .index = 5 },
        };

        const input_style: vaxis.Cell.Style = .{
            .fg = .{ .index = 0 },
            .bg = .{ .index = 7 },
        };

        for (0..box_height) |i| {
            const row = box_y + @as(u16, @intCast(i));
            for (0..box_width) |j| {
                const col = box_x + @as(u16, @intCast(j));
                _ = win.printSegment(.{ .text = " ", .style = box_style }, .{
                    .row_offset = row,
                    .col_offset = col,
                });
            }
        }

        const title = " Go to Line: ";
        _ = win.printSegment(.{ .text = title, .style = box_style }, .{
            .row_offset = box_y,
            .col_offset = box_x + 1,
        });

        const input = snapshot.go_to_line_input orelse "";
        const input_row = box_y + 1;
        const input_col = box_x + 2;
        const input_width = box_width - 4;

        for (0..input_width) |i| {
            _ = win.printSegment(.{ .text = " ", .style = input_style }, .{
                .row_offset = input_row,
                .col_offset = input_col + @as(u16, @intCast(i)),
            });
        }

        const display_input = if (input.len > input_width)
            input[input.len - input_width ..]
        else
            input;

        _ = win.printSegment(.{ .text = display_input, .style = input_style }, .{
            .row_offset = input_row,
            .col_offset = input_col,
        });

        const cursor_col_pos = input_col + @as(u16, @intCast(@min(display_input.len, input_width - 1)));
        _ = win.printSegment(.{ .text = " ", .style = .{ .reverse = true } }, .{
            .row_offset = input_row,
            .col_offset = cursor_col_pos,
        });
    }

    fn drawSymbolPicker(self: *View, win: vaxis.Window, snapshot: *const protocol.RenderSnapshot, allocator: std.mem.Allocator) !void {
        _ = self;
        _ = allocator;

        const overlay_style: vaxis.Cell.Style = .{
            .fg = .{ .index = 7 },
            .bg = .{ .index = 0 },
        };

        for (0..win.height) |row| {
            for (0..win.width) |col| {
                _ = win.printSegment(.{ .text = " ", .style = overlay_style }, .{
                    .row_offset = @intCast(row),
                    .col_offset = @intCast(col),
                });
            }
        }

        const width: usize = @min(win.width -| 4, 60);
        const height: usize = @min(win.height -| 4, 15);

        const start_x: usize = (win.width - width) / 2;
        const start_y: usize = (win.height - height) / 4;

        const box_style: vaxis.Cell.Style = .{
            .fg = .{ .index = 7 },
            .bg = .{ .index = 0 },
        };
        const border_style: vaxis.Cell.Style = .{
            .fg = .{ .index = 5 },
            .bg = .{ .index = 0 },
        };
        const selected_style: vaxis.Cell.Style = .{
            .fg = .{ .index = 0 },
            .bg = .{ .index = 5 },
            .bold = true,
        };
        const kind_style: vaxis.Cell.Style = .{
            .fg = .{ .index = 8 },
            .bg = .{ .index = 0 },
        };

        for (0..width) |i| {
            _ = win.printSegment(.{ .text = "─", .style = border_style }, .{ .row_offset = @intCast(start_y), .col_offset = @intCast(start_x + i) });
            _ = win.printSegment(.{ .text = "─", .style = border_style }, .{ .row_offset = @intCast(start_y + height + 2), .col_offset = @intCast(start_x + i) });
        }
        for (0..height + 3) |i| {
            _ = win.printSegment(.{ .text = "│", .style = border_style }, .{ .row_offset = @intCast(start_y + i), .col_offset = @intCast(start_x) });
            _ = win.printSegment(.{ .text = "│", .style = border_style }, .{ .row_offset = @intCast(start_y + i), .col_offset = @intCast(start_x + width) });
        }
        _ = win.printSegment(.{ .text = "╭", .style = border_style }, .{ .row_offset = @intCast(start_y), .col_offset = @intCast(start_x) });
        _ = win.printSegment(.{ .text = "╮", .style = border_style }, .{ .row_offset = @intCast(start_y), .col_offset = @intCast(start_x + width) });
        _ = win.printSegment(.{ .text = "╰", .style = border_style }, .{ .row_offset = @intCast(start_y + height + 2), .col_offset = @intCast(start_x) });
        _ = win.printSegment(.{ .text = "╯", .style = border_style }, .{ .row_offset = @intCast(start_y + height + 2), .col_offset = @intCast(start_x + width) });

        const input_prefix = "@ ";
        _ = win.printSegment(.{ .text = input_prefix, .style = border_style }, .{ .row_offset = @intCast(start_y + 1), .col_offset = @intCast(start_x + 1) });

        const query = snapshot.symbol_picker_query orelse "";
        _ = win.printSegment(.{ .text = query, .style = box_style }, .{ .row_offset = @intCast(start_y + 1), .col_offset = @intCast(start_x + 1 + input_prefix.len) });

        _ = win.printSegment(.{ .text = " ", .style = .{ .reverse = true } }, .{ .row_offset = @intCast(start_y + 1), .col_offset = @intCast(start_x + 1 + input_prefix.len + query.len) });

        for (1..width) |i| {
            _ = win.printSegment(.{ .text = "─", .style = border_style }, .{ .row_offset = @intCast(start_y + 2), .col_offset = @intCast(start_x + i) });
        }

        if (snapshot.symbol_picker_results) |results| {
            var start_index: usize = 0;
            if (snapshot.symbol_picker_selected >= height) {
                start_index = snapshot.symbol_picker_selected - height + 1;
            }

            const render_count = @min(height, results.len);

            for (0..render_count) |i| {
                const item_index = start_index + i;
                if (item_index >= results.len) break;

                const sym = results[item_index];

                const row = start_y + 3 + i;
                const is_selected = item_index == snapshot.symbol_picker_selected;
                const style = if (is_selected) selected_style else box_style;

                for (1..width) |j| {
                    _ = win.printSegment(.{ .text = " ", .style = style }, .{ .row_offset = @intCast(row), .col_offset = @intCast(start_x + j) });
                }

                _ = win.printSegment(.{ .text = sym.name, .style = style }, .{ .row_offset = @intCast(row), .col_offset = @intCast(start_x + 2) });

                const kind_text = sym.kind;
                if (width > sym.name.len + kind_text.len + 6) {
                    const k_style = if (is_selected) selected_style else kind_style;
                    _ = win.printSegment(.{ .text = kind_text, .style = k_style }, .{ .row_offset = @intCast(row), .col_offset = @intCast(start_x + width - kind_text.len - 2) });
                }
            }
        }
    }

    fn drawGlobalSearch(self: *View, win: vaxis.Window, snapshot: *const protocol.RenderSnapshot, allocator: std.mem.Allocator) !void {
        _ = self;

        const overlay_style: vaxis.Cell.Style = .{
            .fg = .{ .index = 7 },
            .bg = .{ .index = 0 },
        };

        for (0..win.height) |row| {
            for (0..win.width) |col| {
                _ = win.printSegment(.{ .text = " ", .style = overlay_style }, .{
                    .row_offset = @intCast(row),
                    .col_offset = @intCast(col),
                });
            }
        }

        const width: usize = @min(win.width -| 4, 80);
        const height: usize = @min(win.height -| 4, 20);

        const start_x: usize = (win.width - width) / 2;
        const start_y: usize = @max(win.height / 6, 2);

        const box_style: vaxis.Cell.Style = .{
            .fg = .{ .index = 7 },
            .bg = .{ .index = 0 },
        };
        const border_style = theme.styles.global_search.border;
        const selected_style = theme.styles.global_search.selected;
        const file_style = theme.styles.global_search.file_header;
        const line_style = theme.styles.global_search.match_line;
        const line_num_style = theme.styles.global_search.line_number;

        for (0..width) |i| {
            _ = win.printSegment(.{ .text = "─", .style = border_style }, .{ .row_offset = @intCast(start_y), .col_offset = @intCast(start_x + i) });
            _ = win.printSegment(.{ .text = "─", .style = border_style }, .{ .row_offset = @intCast(start_y + height + 4), .col_offset = @intCast(start_x + i) });
        }
        for (0..height + 5) |i| {
            _ = win.printSegment(.{ .text = "│", .style = border_style }, .{ .row_offset = @intCast(start_y + i), .col_offset = @intCast(start_x) });
            _ = win.printSegment(.{ .text = "│", .style = border_style }, .{ .row_offset = @intCast(start_y + i), .col_offset = @intCast(start_x + width) });
        }
        _ = win.printSegment(.{ .text = "╭", .style = border_style }, .{ .row_offset = @intCast(start_y), .col_offset = @intCast(start_x) });
        _ = win.printSegment(.{ .text = "╮", .style = border_style }, .{ .row_offset = @intCast(start_y), .col_offset = @intCast(start_x + width) });
        _ = win.printSegment(.{ .text = "╰", .style = border_style }, .{ .row_offset = @intCast(start_y + height + 4), .col_offset = @intCast(start_x) });
        _ = win.printSegment(.{ .text = "╯", .style = border_style }, .{ .row_offset = @intCast(start_y + height + 4), .col_offset = @intCast(start_x + width) });

        const title = " Global Search ";
        _ = win.printSegment(.{ .text = title, .style = border_style }, .{ .row_offset = @intCast(start_y), .col_offset = @intCast(start_x + 2) });

        const search_label = "> ";
        const search_label_style = if (!snapshot.global_search_focus_replace) theme.styles.global_search.input_label else box_style;
        _ = win.printSegment(.{ .text = search_label, .style = search_label_style }, .{ .row_offset = @intCast(start_y + 1), .col_offset = @intCast(start_x + 1) });

        const query = snapshot.global_search_query orelse "";
        _ = win.printSegment(.{ .text = query, .style = box_style }, .{ .row_offset = @intCast(start_y + 1), .col_offset = @intCast(start_x + 3) });

        if (!snapshot.global_search_focus_replace) {
            _ = win.printSegment(.{ .text = " ", .style = .{ .reverse = true } }, .{ .row_offset = @intCast(start_y + 1), .col_offset = @intCast(start_x + 3 + query.len) });
        }

        const replace_label = "↳ ";
        const replace_label_style = if (snapshot.global_search_focus_replace) theme.styles.global_search.replace_label else box_style;
        _ = win.printSegment(.{ .text = replace_label, .style = replace_label_style }, .{ .row_offset = @intCast(start_y + 2), .col_offset = @intCast(start_x + 1) });

        const replace = snapshot.global_search_replace orelse "";
        _ = win.printSegment(.{ .text = replace, .style = box_style }, .{ .row_offset = @intCast(start_y + 2), .col_offset = @intCast(start_x + 3) });

        if (snapshot.global_search_focus_replace) {
            _ = win.printSegment(.{ .text = " ", .style = .{ .reverse = true } }, .{ .row_offset = @intCast(start_y + 2), .col_offset = @intCast(start_x + 3 + replace.len) });
        }

        for (1..width) |i| {
            _ = win.printSegment(.{ .text = "─", .style = border_style }, .{ .row_offset = @intCast(start_y + 3), .col_offset = @intCast(start_x + i) });
        }

        var stats_buf: [64]u8 = undefined;
        const stats = if (snapshot.global_search_results) |results| blk: {
            if (results.len == 0) {
                break :blk if (snapshot.global_search_ran) "No matches" else "Type to search...";
            }
            break :blk std.fmt.bufPrint(&stats_buf, "{d} matches in {d} files", .{ snapshot.global_search_total_matches, results.len }) catch "...";
        } else "Type to search...";

        _ = win.printSegment(.{ .text = stats, .style = theme.styles.global_search.stats }, .{ .row_offset = @intCast(start_y + 4), .col_offset = @intCast(start_x + 2) });

        if (snapshot.global_search_results) |results| {
            if (results.len == 0) {
                _ = allocator;
                return;
            }

            const visible_rows = height -| 1;

            const safe_selected_file = @min(snapshot.global_search_selected_file, results.len -| 1);

            var total_items: usize = 0;
            var selected_item_idx: usize = 0;
            for (results, 0..) |group, file_idx| {
                if (file_idx == safe_selected_file) {
                    const safe_selected_match = if (group.matches.len > 0)
                        @min(snapshot.global_search_selected_match, group.matches.len - 1)
                    else
                        0;
                    selected_item_idx = total_items + 1 + safe_selected_match;
                }
                total_items += 1;
                total_items += group.matches.len;
            }

            var scroll_offset: usize = 0;
            if (selected_item_idx >= visible_rows) {
                scroll_offset = selected_item_idx - visible_rows + 1;
            }

            var row_offset: usize = 5;
            var item_idx: usize = 0;

            for (results, 0..) |group, file_idx| {
                if (item_idx >= scroll_offset and row_offset < height + 4) {
                    const is_file_selected = file_idx == snapshot.global_search_selected_file;
                    const f_style = if (is_file_selected and snapshot.global_search_selected_match == 0) selected_style else file_style;

                    const max_path_len = width -| 6;
                    const path_display = if (group.file_path.len > max_path_len)
                        group.file_path[group.file_path.len - max_path_len ..]
                    else
                        group.file_path;

                    var file_header_buf: [128]u8 = undefined;
                    const file_header = std.fmt.bufPrint(&file_header_buf, "▼ {s} ({d})", .{ path_display, group.matches.len }) catch path_display;

                    _ = win.printSegment(.{ .text = file_header, .style = f_style }, .{ .row_offset = @intCast(start_y + row_offset), .col_offset = @intCast(start_x + 2) });
                    row_offset += 1;
                } else if (item_idx >= scroll_offset) {
                    row_offset += 1;
                }
                item_idx += 1;

                for (group.matches, 0..) |match, match_idx| {
                    if (item_idx >= scroll_offset and row_offset < height + 4) {
                        const is_file_selected = file_idx == snapshot.global_search_selected_file;
                        const is_match_selected = is_file_selected and match_idx == snapshot.global_search_selected_match;
                        const m_style = if (is_match_selected) selected_style else line_style;

                        var line_num_buf: [8]u8 = undefined;
                        const line_num_str = std.fmt.bufPrint(&line_num_buf, "{d:>4}:", .{match.line_num}) catch "    :";
                        _ = win.printSegment(.{ .text = line_num_str, .style = if (is_match_selected) selected_style else line_num_style }, .{ .row_offset = @intCast(start_y + row_offset), .col_offset = @intCast(start_x + 4) });

                        const max_content_len = width -| 14;
                        const content_display = if (match.line_content.len > max_content_len)
                            match.line_content[0..max_content_len]
                        else
                            match.line_content;

                        _ = win.printSegment(.{ .text = content_display, .style = m_style }, .{ .row_offset = @intCast(start_y + row_offset), .col_offset = @intCast(start_x + 10) });
                        row_offset += 1;
                    } else if (item_idx >= scroll_offset) {
                        row_offset += 1;
                    }
                    item_idx += 1;

                    if (row_offset >= height + 4) break;
                }
                if (row_offset >= height + 4) break;
            }
        }

        const hints = "↑↓ Navigate  Enter Jump  Tab Field  Esc Close";
        const hints_style: vaxis.Cell.Style = .{ .fg = .{ .index = 8 } };
        _ = win.printSegment(.{ .text = hints, .style = hints_style }, .{ .row_offset = @intCast(start_y + height + 4), .col_offset = @intCast(start_x + 2) });

        _ = allocator;
    }
};
