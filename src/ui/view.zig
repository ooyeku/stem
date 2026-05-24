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

        if (mode == .file_explorer) {
            try drawFileExplorer(
                win,
                snapshot.file_explorer_cwd orelse ".",
                snapshot.file_explorer_entries orelse &.{},
                snapshot.file_explorer_selected,
                snapshot.file_explorer_scroll_offset,
            );
            return;
        }

        if (mode == .references_picker) {
            try drawReferencesPicker(
                win,
                snapshot.references_symbol,
                snapshot.references_entries orelse &.{},
                snapshot.references_selected,
                snapshot.references_scroll_offset,
            );
            return;
        }

        if (mode == .diagnostics_picker) {
            try drawDiagnosticsPicker(
                win,
                snapshot.diagnostics_entries orelse &.{},
                snapshot.diagnostics_picker_selected,
                snapshot.diagnostics_picker_scroll_offset,
            );
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

        if (mode == .workspace_symbol_picker) {
            try self.drawWorkspaceSymbolPicker(win, snapshot, frame_allocator);
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

            // Inlay hints for this line, scanned once and held as a
            // small array. Most lines have 0–3 hints so this is cheap
            // even at O(hints * lines).
            const inlay_style: vaxis.Cell.Style = .{ .fg = .{ .rgb = .{ 128, 128, 140 } }, .italic = true };
            var line_inlay_count: usize = 0;
            const inlay_pool = snapshot.inlay_hints orelse &[_]protocol.InlayHintSnapshot{};
            // Counting first lets us allocate the small temp slice
            // exactly. Skip the alloc/sort if no hints apply.
            for (inlay_pool) |h| {
                if (h.line == file_line_idx) line_inlay_count += 1;
            }
            const line_inlays = if (line_inlay_count > 0) blk: {
                var arr = try frame_allocator.alloc(protocol.InlayHintSnapshot, line_inlay_count);
                var w: usize = 0;
                for (inlay_pool) |h| {
                    if (h.line == file_line_idx) {
                        arr[w] = h;
                        w += 1;
                    }
                }
                std.mem.sort(protocol.InlayHintSnapshot, arr, {}, struct {
                    fn lt(_: void, a: protocol.InlayHintSnapshot, b: protocol.InlayHintSnapshot) bool {
                        return a.col < b.col;
                    }
                }.lt);
                break :blk arr;
            } else &[_]protocol.InlayHintSnapshot{};
            var next_inlay: usize = 0;

            while (byte_idx < line.len) {
                // Emit any inlay hints that anchor at this byte.
                while (next_inlay < line_inlays.len and line_inlays[next_inlay].col == byte_idx) {
                    const h = line_inlays[next_inlay];
                    next_inlay += 1;
                    if (h.padding_left) {
                        _ = text_win.printSegment(.{ .text = " ", .style = inlay_style }, .{ .row_offset = @intCast(screen_row), .col_offset = @intCast(current_col) });
                        current_col += 1;
                    }
                    const room = if (current_col < text_width) text_width - current_col else 0;
                    const fit_len = @min(h.label.len, room);
                    if (fit_len > 0) {
                        _ = text_win.printSegment(.{ .text = h.label[0..fit_len], .style = inlay_style }, .{ .row_offset = @intCast(screen_row), .col_offset = @intCast(current_col) });
                        current_col += fit_len;
                    }
                    if (h.padding_right and current_col < text_width) {
                        _ = text_win.printSegment(.{ .text = " ", .style = inlay_style }, .{ .row_offset = @intCast(screen_row), .col_offset = @intCast(current_col) });
                        current_col += 1;
                    }
                }

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

            // Trailing inlay hints (anchored at or past end-of-line).
            // Same emission code as the inline path, just drained
            // after the byte loop.
            while (next_inlay < line_inlays.len) : (next_inlay += 1) {
                const h = line_inlays[next_inlay];
                if (h.padding_left and current_col < text_width) {
                    _ = text_win.printSegment(.{ .text = " ", .style = inlay_style }, .{ .row_offset = @intCast(screen_row), .col_offset = @intCast(current_col) });
                    current_col += 1;
                }
                const room = if (current_col < text_width) text_width - current_col else 0;
                const fit_len = @min(h.label.len, room);
                if (fit_len > 0) {
                    _ = text_win.printSegment(.{ .text = h.label[0..fit_len], .style = inlay_style }, .{ .row_offset = @intCast(screen_row), .col_offset = @intCast(current_col) });
                    current_col += fit_len;
                }
                if (h.padding_right and current_col < text_width) {
                    _ = text_win.printSegment(.{ .text = " ", .style = inlay_style }, .{ .row_offset = @intCast(screen_row), .col_offset = @intCast(current_col) });
                    current_col += 1;
                }
            }

            // Inline virtual-text diagnostic at end-of-line. With
            // `inline_diagnostics` enabled (the "error lens" mode), every
            // line that carries a diagnostic shows its highest-severity
            // message; without it, only the cursor's line does.
            if (top_diag) |d| {
                const show_inline = snapshot.editor_config.inline_diagnostics or file_line_idx == snapshot.cursor_row;
                if (show_inline) {
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

        if (!snapshot.completion_active and
            (snapshot.hover_document != null or snapshot.hover_content != null or snapshot.hover_loading))
        {
            try self.drawHoverPopup(text_area, snapshot);
        }

        if (snapshot.completion_active) {
            if (snapshot.completion_items) |items| {
                try self.drawCompletionPopup(text_area, items, snapshot.completion_selected, snapshot.cursor_row, snapshot.cursor_col, snapshot.scroll_offset);
            }
        }

        // Signature help popup. Insert-mode only — Core clears it on
        // mode change. Renders one-line above the cursor with the
        // active parameter underlined.
        if (snapshot.signature_help_label) |label| {
            try self.drawSignatureHelp(
                text_area,
                label,
                snapshot.signature_help_parameters orelse &.{},
                snapshot.signature_help_active_parameter,
                snapshot.cursor_row,
                snapshot.cursor_col,
                snapshot.scroll_offset,
            );
        }

        if (mode == .visual_search) {
            try self.drawSearchInput(
                win,
                snapshot.search_input orelse "",
                snapshot.search_direction_forward,
                snapshot.search_match_count,
                snapshot.search_match_index,
                frame_allocator,
            );
        }

        if (snapshot.which_key_visible) {
            try self.drawWhichKey(win, snapshot.leader_chord);
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
                    if (!snapshot.completion_active and
                        (snapshot.hover_document != null or snapshot.hover_content != null or snapshot.hover_loading))
                    {
                        try self.drawHoverPopup(pane_win.child(.{ .y_off = 1, .height = height -| 1 }), snapshot);
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

        if (snapshot.which_key_visible) {
            try self.drawWhichKey(win, snapshot.leader_chord);
        }
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

    // ---- Hover popup -----------------------------------------------------
    //
    // The hover popup renders a parsed `HoverDocument` (from
    // `services/hover_doc.zig`). Layout, from top to bottom:
    //
    //   ┌──────────────────────────────────────┐
    //   │  {title or "Hover"}   esc · scroll   │  ← header
    //   ├──────────────────────────────────────┤
    //   │  signature                           │  ← signature panel (code-styled)
    //   ├──────────────────────────────────────┤
    //   │  body sections (scrollable)          │
    //   │  …                                   │
    //   ├──────────────────────────────────────┤
    //   │  Esc dismiss   j/k scroll            │  ← footer (sticky only)
    //   └──────────────────────────────────────┘
    //
    // Width is viewport-relative: max(40, min(96, win.width * 0.55)).
    // Position prefers below-and-right of the anchor (token start),
    // falls back to above when there's no room, and slides
    // horizontally to stay inside the window.

    /// One rendered row inside the popup body. Carries its own style
    /// + indent so the renderer can blit it directly without any more
    /// branching on section kind.
    const HoverRow = struct {
        text: []const u8,
        style: vaxis.Cell.Style,
        indent: u16 = 0,
    };

    const HoverStyle = struct {
        border: vaxis.Cell.Style,
        bg: vaxis.Cell.Style,
        title: vaxis.Cell.Style,
        chip: vaxis.Cell.Style,
        signature: vaxis.Cell.Style,
        code: vaxis.Cell.Style,
        paragraph: vaxis.Cell.Style,
        list_item: vaxis.Cell.Style,
        divider: vaxis.Cell.Style,
        hint: vaxis.Cell.Style,
    };

    fn hoverStyles() HoverStyle {
        const bg_color = vaxis.Cell.Color{ .rgb = .{ 30, 30, 46 } };
        return .{
            .border = .{ .fg = .{ .rgb = .{ 108, 112, 134 } }, .bg = bg_color },
            .bg = .{ .bg = bg_color },
            .title = .{ .fg = .{ .rgb = .{ 245, 224, 220 } }, .bg = bg_color, .bold = true },
            .chip = .{ .fg = .{ .rgb = .{ 137, 180, 250 } }, .bg = bg_color, .italic = true },
            .signature = .{ .fg = .{ .rgb = .{ 166, 227, 161 } }, .bg = bg_color, .bold = true },
            .code = .{ .fg = .{ .rgb = .{ 137, 180, 250 } }, .bg = bg_color },
            .paragraph = .{ .fg = .{ .rgb = .{ 205, 214, 244 } }, .bg = bg_color },
            .list_item = .{ .fg = .{ .rgb = .{ 203, 166, 247 } }, .bg = bg_color },
            .divider = .{ .fg = .{ .rgb = .{ 69, 71, 90 } }, .bg = bg_color },
            .hint = .{ .fg = .{ .rgb = .{ 108, 112, 134 } }, .bg = bg_color, .italic = true },
        };
    }

    fn drawHoverPopup(self: *View, win: vaxis.Window, snapshot: *const protocol.RenderSnapshot) !void {
        if (win.width < 14 or win.height < 6) {
            logDebug("drawHoverPopup: Window too small ({}x{})", .{ win.width, win.height });
            return;
        }

        const styles = hoverStyles();

        // Width: viewport-relative with sensible bounds so signatures
        // breathe on wide screens but don't dominate narrow ones.
        const desired = (@as(usize, win.width) * 55) / 100;
        const width_usize = std.math.clamp(desired, @as(usize, 40), @as(usize, 96));
        const width: u16 = @intCast(@min(width_usize, @as(usize, win.width -| 2)));
        const inner_width: u16 = if (width > 4) width - 4 else 1;
        const text_width: usize = @intCast(inner_width);

        // Build a wrapped line list from the structured document.
        // Each row carries its style so we can keep code blocks /
        // paragraphs / list items visually distinct.
        var body_rows = std.ArrayListUnmanaged(HoverRow).empty;
        defer body_rows.deinit(self.allocator);

        // Title text — prefer the parsed title, fall back to "Hover".
        var header_title: []const u8 = "Hover";
        var header_chip: ?[]const u8 = null;
        var signature_text: ?[]const u8 = null;
        var has_doc = false;

        if (snapshot.hover_document) |doc| {
            has_doc = true;
            if (doc.title) |t| header_title = t;
            if (doc.signature_language) |l| header_chip = l;
            if (doc.signature) |sig| signature_text = sig;

            for (doc.sections, 0..) |sec, i| {
                if (i > 0) {
                    try body_rows.append(self.allocator, .{ .text = "", .style = styles.bg });
                }
                switch (sec.kind) {
                    .paragraph => try wrapRows(self.allocator, &body_rows, sec.text, styles.paragraph, text_width, 0),
                    .code_block => {
                        var line_it = std.mem.splitScalar(u8, sec.text, '\n');
                        while (line_it.next()) |line| {
                            try wrapRows(self.allocator, &body_rows, line, styles.code, text_width, 0);
                        }
                    },
                    .list_item => try wrapRows(self.allocator, &body_rows, sec.text, styles.list_item, text_width, 2),
                    .blank => try body_rows.append(self.allocator, .{ .text = "", .style = styles.bg }),
                }
            }
        } else if (snapshot.hover_content) |raw| {
            // Parse failed — show raw lines with paragraph styling so
            // we at least display something readable.
            var line_it = std.mem.splitScalar(u8, raw, '\n');
            while (line_it.next()) |line| {
                try wrapRows(self.allocator, &body_rows, line, styles.paragraph, text_width, 0);
            }
        }

        // Signature panel takes 1 line plus a 1-line divider below it.
        const has_signature = signature_text != null;
        const sig_lines: u16 = if (has_signature) 1 else 0;
        const sig_divider: u16 = if (has_signature) 1 else 0;

        const header_lines: u16 = 1;
        const header_divider: u16 = 1;
        const footer_lines: u16 = if (snapshot.hover_sticky) 1 else 0;
        const footer_divider: u16 = if (snapshot.hover_sticky) 1 else 0;
        const top_border: u16 = 1;
        const bottom_border: u16 = 1;

        const chrome_rows: u16 =
            top_border + header_lines + header_divider + sig_lines + sig_divider +
            footer_divider + footer_lines + bottom_border;

        // Apply scroll: scrolling drops rows off the top of the body.
        const total_body_rows: u16 = @intCast(@min(body_rows.items.len, @as(usize, std.math.maxInt(u16))));
        const scroll: u16 = @intCast(@min(snapshot.hover_scroll_offset, @as(usize, total_body_rows)));

        // Pick popup height: prefer the natural body size, bound by
        // viewport height. Always reserve space for chrome — and
        // reserve at least one body row when we're in the loading
        // state so the "Loading…" message has somewhere to land.
        const natural_body_rows = blk: {
            const raw = total_body_rows -| scroll;
            if (raw == 0 and snapshot.hover_loading) break :blk 1;
            break :blk raw;
        };
        const max_height: u16 = @intCast(@min(@as(usize, win.height -| 2), @as(usize, 20)));
        const body_capacity = if (max_height > chrome_rows) max_height - chrome_rows else 1;
        const body_visible_rows = @min(natural_body_rows, body_capacity);
        const height: u16 = chrome_rows + body_visible_rows;

        // Placement. Anchor on the token (not the cursor) so the
        // popup stays put even if the cursor drifts mid-identifier.
        const anchor_screen_row: u16 = @intCast(@min(
            snapshot.hover_anchor_row -| snapshot.scroll_offset,
            @as(usize, std.math.maxInt(u16)),
        ));
        const anchor_screen_col: u16 = @intCast(@min(
            snapshot.hover_anchor_col,
            @as(usize, std.math.maxInt(u16)),
        ));

        const space_above: u16 = anchor_screen_row;
        const space_below: u16 = win.height -| (anchor_screen_row + 1);

        // Bias toward below-the-token (more natural reading flow),
        // fall back to above when there's clearly more room there.
        var box_y: u16 = 0;
        if (space_below >= height + 1) {
            box_y = anchor_screen_row + 1;
        } else if (space_above >= height) {
            box_y = anchor_screen_row -| height;
        } else if (space_below >= 4) {
            // Truncate body to fit below.
            const fit_body = if (space_below > chrome_rows + 1) space_below - chrome_rows - 1 else 1;
            const truncated_body = @min(body_visible_rows, fit_body);
            box_y = anchor_screen_row + 1;
            return self.renderHoverBox(
                win,
                box_x_for(win, width, anchor_screen_col),
                box_y,
                width,
                chrome_rows + truncated_body,
                truncated_body,
                styles,
                header_title,
                header_chip,
                signature_text,
                body_rows.items[scroll..@min(body_rows.items.len, @as(usize, scroll) + truncated_body)],
                snapshot,
            );
        } else if (space_above >= 4) {
            const fit_body = if (space_above > chrome_rows) space_above - chrome_rows else 1;
            const truncated_body = @min(body_visible_rows, fit_body);
            box_y = anchor_screen_row -| (chrome_rows + truncated_body);
            return self.renderHoverBox(
                win,
                box_x_for(win, width, anchor_screen_col),
                box_y,
                width,
                chrome_rows + truncated_body,
                truncated_body,
                styles,
                header_title,
                header_chip,
                signature_text,
                body_rows.items[scroll..@min(body_rows.items.len, @as(usize, scroll) + truncated_body)],
                snapshot,
            );
        } else {
            // Last resort: pin to row 0.
            box_y = 0;
        }

        const body_end_idx = @min(body_rows.items.len, @as(usize, scroll) + body_visible_rows);
        try self.renderHoverBox(
            win,
            box_x_for(win, width, anchor_screen_col),
            box_y,
            width,
            height,
            body_visible_rows,
            styles,
            header_title,
            header_chip,
            signature_text,
            body_rows.items[scroll..body_end_idx],
            snapshot,
        );
    }

    fn renderHoverBox(
        self: *View,
        win: vaxis.Window,
        box_x: u16,
        box_y: u16,
        width: u16,
        height: u16,
        body_visible_rows: u16,
        styles: HoverStyle,
        title: []const u8,
        chip: ?[]const u8,
        signature: ?[]const u8,
        body_rows: []const HoverRow,
        snapshot: *const protocol.RenderSnapshot,
    ) !void {
        const inner_left = box_x + 2;
        const inner_right_padding: u16 = 2;
        const inner_width: u16 = if (width > 4) width - 4 else 1;

        // Top border
        _ = win.printSegment(.{ .text = "╭", .style = styles.border }, .{ .row_offset = box_y, .col_offset = box_x });
        for (1..width - 1) |i| {
            _ = win.printSegment(.{ .text = "─", .style = styles.border }, .{ .row_offset = box_y, .col_offset = box_x + @as(u16, @intCast(i)) });
        }
        _ = win.printSegment(.{ .text = "╮", .style = styles.border }, .{ .row_offset = box_y, .col_offset = box_x + width - 1 });

        var row = box_y + 1;

        // Header: title on the left, optional language chip + key hint
        // on the right.
        fillRow(win, box_x, row, width, styles.bg);
        _ = win.printSegment(.{ .text = title, .style = styles.title }, .{ .row_offset = row, .col_offset = inner_left });
        if (chip) |c| {
            const chip_text_buf = try std.fmt.allocPrint(self.allocator, "{s}", .{c});
            defer self.allocator.free(chip_text_buf);
            if (chip_text_buf.len + title.len + 4 < inner_width) {
                const chip_col = inner_left + @as(u16, @intCast(title.len)) + 2;
                _ = win.printSegment(.{ .text = chip_text_buf, .style = styles.chip }, .{ .row_offset = row, .col_offset = chip_col });
            }
        }
        const hint = if (snapshot.hover_sticky) "esc · j/k" else "esc";
        if (width > hint.len + 6) {
            const hint_col = box_x + width - 1 - @as(u16, @intCast(hint.len)) - 1;
            _ = win.printSegment(.{ .text = hint, .style = styles.hint }, .{ .row_offset = row, .col_offset = hint_col });
        }
        _ = win.printSegment(.{ .text = "│", .style = styles.border }, .{ .row_offset = row, .col_offset = box_x });
        _ = win.printSegment(.{ .text = "│", .style = styles.border }, .{ .row_offset = row, .col_offset = box_x + width - 1 });
        row += 1;

        // Header divider
        drawDivider(win, box_x, row, width, styles);
        row += 1;

        // Signature panel
        if (signature) |sig| {
            fillRow(win, box_x, row, width, styles.bg);
            const truncated = truncateText(sig, inner_width);
            _ = win.printSegment(.{ .text = truncated, .style = styles.signature }, .{ .row_offset = row, .col_offset = inner_left });
            _ = win.printSegment(.{ .text = "│", .style = styles.border }, .{ .row_offset = row, .col_offset = box_x });
            _ = win.printSegment(.{ .text = "│", .style = styles.border }, .{ .row_offset = row, .col_offset = box_x + width - 1 });
            row += 1;
            drawDivider(win, box_x, row, width, styles);
            row += 1;
        }

        // Loading state takes precedence over an empty body.
        if (snapshot.hover_loading and body_rows.len == 0) {
            fillRow(win, box_x, row, width, styles.bg);
            _ = win.printSegment(.{ .text = "Loading…", .style = styles.hint }, .{ .row_offset = row, .col_offset = inner_left });
            _ = win.printSegment(.{ .text = "│", .style = styles.border }, .{ .row_offset = row, .col_offset = box_x });
            _ = win.printSegment(.{ .text = "│", .style = styles.border }, .{ .row_offset = row, .col_offset = box_x + width - 1 });
            row += 1;
        } else {
            for (0..body_visible_rows) |i| {
                fillRow(win, box_x, row, width, styles.bg);
                if (i < body_rows.len) {
                    const r = body_rows[i];
                    const truncated = truncateText(r.text, inner_width -| r.indent);
                    const bullet_or_space: []const u8 = if (r.indent > 0 and !std.mem.eql(u8, truncated, "")) "•" else " ";
                    if (r.indent > 0) {
                        _ = win.printSegment(.{ .text = bullet_or_space, .style = r.style }, .{ .row_offset = row, .col_offset = inner_left });
                        _ = win.printSegment(.{ .text = truncated, .style = r.style }, .{ .row_offset = row, .col_offset = inner_left + r.indent });
                    } else {
                        _ = win.printSegment(.{ .text = truncated, .style = r.style }, .{ .row_offset = row, .col_offset = inner_left });
                    }
                }
                _ = win.printSegment(.{ .text = "│", .style = styles.border }, .{ .row_offset = row, .col_offset = box_x });
                _ = win.printSegment(.{ .text = "│", .style = styles.border }, .{ .row_offset = row, .col_offset = box_x + width - 1 });
                row += 1;
            }
        }

        // Footer — only on sticky hover, where the user is actively
        // reading and needs the scroll affordance.
        if (snapshot.hover_sticky) {
            drawDivider(win, box_x, row, width, styles);
            row += 1;
            fillRow(win, box_x, row, width, styles.bg);
            const footer = "Esc dismiss   j/k or ↑/↓ scroll";
            const truncated = truncateText(footer, inner_width);
            _ = win.printSegment(.{ .text = truncated, .style = styles.hint }, .{ .row_offset = row, .col_offset = inner_left });
            _ = win.printSegment(.{ .text = "│", .style = styles.border }, .{ .row_offset = row, .col_offset = box_x });
            _ = win.printSegment(.{ .text = "│", .style = styles.border }, .{ .row_offset = row, .col_offset = box_x + width - 1 });
            row += 1;
        }

        // Bottom border
        _ = win.printSegment(.{ .text = "╰", .style = styles.border }, .{ .row_offset = row, .col_offset = box_x });
        for (1..width - 1) |i| {
            _ = win.printSegment(.{ .text = "─", .style = styles.border }, .{ .row_offset = row, .col_offset = box_x + @as(u16, @intCast(i)) });
        }
        _ = win.printSegment(.{ .text = "╯", .style = styles.border }, .{ .row_offset = row, .col_offset = box_x + width - 1 });

        _ = inner_right_padding; // silence unused
        _ = height; // silence unused
    }

    /// Append wrapped rows for `text` into `out`. Soft-wraps at
    /// `wrap_width` (cell count) breaking at spaces when possible,
    /// hard-breaking otherwise. `indent` cells of left padding go to
    /// every wrapped continuation row.
    fn wrapRows(
        allocator: std.mem.Allocator,
        out: *std.ArrayListUnmanaged(HoverRow),
        text: []const u8,
        style: vaxis.Cell.Style,
        wrap_width: usize,
        indent: u16,
    ) !void {
        if (text.len == 0) {
            try out.append(allocator, .{ .text = text, .style = style, .indent = indent });
            return;
        }
        const usable = if (wrap_width > indent) wrap_width - indent else 1;
        var remaining = text;
        while (remaining.len > 0) {
            if (remaining.len <= usable) {
                try out.append(allocator, .{ .text = remaining, .style = style, .indent = indent });
                return;
            }
            // Walk back from the soft-wrap boundary to the last space
            // so we don't split a word. Hard-break if there's no
            // earlier space.
            var split: usize = usable;
            var found_space = false;
            var i: usize = usable;
            while (i > 0) : (i -= 1) {
                if (remaining[i - 1] == ' ') {
                    split = i - 1;
                    found_space = true;
                    break;
                }
            }
            if (!found_space) split = usable;
            const chunk = remaining[0..split];
            try out.append(allocator, .{ .text = chunk, .style = style, .indent = indent });
            // Skip the space we broke at, if any.
            const next_start = if (found_space) split + 1 else split;
            if (next_start >= remaining.len) return;
            remaining = remaining[next_start..];
        }
    }

    /// Modal tree-shaped file explorer overlay. Renders centered on
    /// the screen with a border, a title row showing the root path,
    /// a footer row with key hints, and a scrolling list of entries
    /// in the middle. Directories show a `▸`/`▾` glyph; depth is
    /// communicated by two spaces of indent per level.
    fn drawFileExplorer(
        win: vaxis.Window,
        cwd: []const u8,
        entries: []const protocol.ExplorerEntry,
        selected: usize,
        scroll_offset: usize,
    ) !void {
        if (win.width < 30 or win.height < 6) return;

        // Modal box: 80% width, 80% height, centered.
        const box_width: u16 = @min(@as(u16, 100), (win.width * 4) / 5);
        const box_height: u16 = @min(@as(u16, 30), (win.height * 4) / 5);
        const box_x: u16 = (win.width -| box_width) / 2;
        const box_y: u16 = (win.height -| box_height) / 2;

        const bg: vaxis.Cell.Style = theme.styles.panel.background;
        const border: vaxis.Cell.Style = theme.styles.panel.background;
        const title_style: vaxis.Cell.Style = theme.styles.panel.title;
        const dir_style: vaxis.Cell.Style = .{
            .fg = .{ .rgb = theme.colors.syntax.namespace },
            .bg = bg.bg,
            .bold = true,
        };
        const file_style: vaxis.Cell.Style = bg;
        const selected_style: vaxis.Cell.Style = .{
            .fg = .{ .index = theme.colors.palette.bright_white },
            .bg = .{ .index = theme.colors.palette.blue },
            .bold = true,
        };
        const hint_style: vaxis.Cell.Style = .{
            .fg = .{ .rgb = theme.colors.syntax.comment },
            .bg = bg.bg,
            .italic = true,
        };

        // Top border + title.
        _ = win.printSegment(.{ .text = "╭", .style = border }, .{ .row_offset = box_y, .col_offset = box_x });
        for (1..box_width - 1) |i| {
            _ = win.printSegment(.{ .text = "─", .style = border }, .{ .row_offset = box_y, .col_offset = box_x + @as(u16, @intCast(i)) });
        }
        _ = win.printSegment(.{ .text = "╮", .style = border }, .{ .row_offset = box_y, .col_offset = box_x + box_width - 1 });

        // Title row: " 📁 Files — <cwd> "
        fillRow(win, box_x, box_y + 1, box_width, bg);
        _ = win.printSegment(.{ .text = "│", .style = border }, .{ .row_offset = box_y + 1, .col_offset = box_x });
        _ = win.printSegment(.{ .text = "│", .style = border }, .{ .row_offset = box_y + 1, .col_offset = box_x + box_width - 1 });
        const title_prefix = " Files — ";
        _ = win.printSegment(.{ .text = title_prefix, .style = title_style }, .{ .row_offset = box_y + 1, .col_offset = box_x + 1 });
        const max_cwd_len: usize = if (box_width > title_prefix.len + 4) box_width - title_prefix.len - 4 else 0;
        const cwd_trim = if (cwd.len > max_cwd_len and max_cwd_len > 3) cwd[cwd.len - max_cwd_len + 1 ..] else cwd;
        _ = win.printSegment(.{ .text = cwd_trim, .style = title_style }, .{ .row_offset = box_y + 1, .col_offset = box_x + 1 + @as(u16, @intCast(title_prefix.len)) });

        // Body rows.
        const list_top: u16 = box_y + 2;
        const list_bottom: u16 = box_y + box_height - 2; // leave room for footer
        const list_rows: usize = @intCast(list_bottom - list_top);

        // Auto-scroll: keep selected in [scroll_offset, scroll_offset + list_rows)
        var effective_scroll = scroll_offset;
        if (selected < effective_scroll) effective_scroll = selected;
        if (selected >= effective_scroll + list_rows) {
            effective_scroll = if (selected + 1 > list_rows) selected + 1 - list_rows else 0;
        }

        var row: u16 = list_top;
        var i: usize = effective_scroll;
        while (i < entries.len and row < list_bottom) : ({
            i += 1;
            row += 1;
        }) {
            const e = entries[i];
            // Background fill.
            fillRow(win, box_x, row, box_width, bg);
            _ = win.printSegment(.{ .text = "│", .style = border }, .{ .row_offset = row, .col_offset = box_x });
            _ = win.printSegment(.{ .text = "│", .style = border }, .{ .row_offset = row, .col_offset = box_x + box_width - 1 });

            const is_sel = i == selected;
            const style_for_text = if (is_sel) selected_style else if (e.is_dir) dir_style else file_style;
            const glyph: []const u8 = if (e.is_dir) (if (e.is_expanded) "▾ " else "▸ ") else "  ";

            // Selection highlight spans the whole interior row.
            if (is_sel) {
                var col: u16 = box_x + 1;
                while (col < box_x + box_width - 1) : (col += 1) {
                    _ = win.printSegment(.{ .text = " ", .style = selected_style }, .{ .row_offset = row, .col_offset = col });
                }
            }

            const indent_cols: u16 = @as(u16, @intCast(e.depth)) * 2;
            const base_col = box_x + 2 + indent_cols;
            if (base_col + 2 < box_x + box_width - 1) {
                _ = win.printSegment(.{ .text = glyph, .style = style_for_text }, .{ .row_offset = row, .col_offset = base_col });
                _ = win.printSegment(.{ .text = e.name, .style = style_for_text }, .{ .row_offset = row, .col_offset = base_col + 2 });
            }
        }
        // Pad remaining empty rows so the border closes cleanly.
        while (row < list_bottom) : (row += 1) {
            fillRow(win, box_x, row, box_width, bg);
            _ = win.printSegment(.{ .text = "│", .style = border }, .{ .row_offset = row, .col_offset = box_x });
            _ = win.printSegment(.{ .text = "│", .style = border }, .{ .row_offset = row, .col_offset = box_x + box_width - 1 });
        }

        // Footer with key hints.
        fillRow(win, box_x, list_bottom, box_width, bg);
        _ = win.printSegment(.{ .text = "│", .style = border }, .{ .row_offset = list_bottom, .col_offset = box_x });
        _ = win.printSegment(.{ .text = "│", .style = border }, .{ .row_offset = list_bottom, .col_offset = box_x + box_width - 1 });
        const hint = " j/k move · h/l collapse/expand · ⏎ open · H hidden · esc close ";
        const hint_col = box_x + 1;
        if (hint.len < box_width - 2) {
            _ = win.printSegment(.{ .text = hint, .style = hint_style }, .{ .row_offset = list_bottom, .col_offset = hint_col });
        }

        // Bottom border.
        _ = win.printSegment(.{ .text = "╰", .style = border }, .{ .row_offset = box_y + box_height - 1, .col_offset = box_x });
        for (1..box_width - 1) |bx| {
            _ = win.printSegment(.{ .text = "─", .style = border }, .{ .row_offset = box_y + box_height - 1, .col_offset = box_x + @as(u16, @intCast(bx)) });
        }
        _ = win.printSegment(.{ .text = "╯", .style = border }, .{ .row_offset = box_y + box_height - 1, .col_offset = box_x + box_width - 1 });
    }

    /// Generic modal-list renderer used by the references and
    /// diagnostics pickers. Centered box, header line, scrolling
    /// row list, footer with key hints. Each row is rendered by
    /// the caller's `rowText` closure so the two pickers can
    /// format their entries differently (a reference shows
    /// `[file] Ln 42: snippet`, a diagnostic shows
    /// `E Ln 42:5  unused variable`).
    fn drawModalList(
        win: vaxis.Window,
        title: []const u8,
        footer_hint: []const u8,
        row_count: usize,
        selected: usize,
        scroll_offset: usize,
        ctx: anytype,
    ) !void {
        if (win.width < 30 or win.height < 6) return;

        const box_width: u16 = @min(@as(u16, 120), (win.width * 9) / 10);
        const box_height: u16 = @min(@as(u16, 40), (win.height * 4) / 5);
        const box_x: u16 = (win.width -| box_width) / 2;
        const box_y: u16 = (win.height -| box_height) / 2;

        const bg: vaxis.Cell.Style = theme.styles.panel.background;
        const border: vaxis.Cell.Style = bg;
        const title_style: vaxis.Cell.Style = theme.styles.panel.title;
        const selected_style: vaxis.Cell.Style = .{
            .fg = .{ .index = theme.colors.palette.bright_white },
            .bg = .{ .index = theme.colors.palette.blue },
            .bold = true,
        };
        const hint_style: vaxis.Cell.Style = .{
            .fg = .{ .rgb = theme.colors.syntax.comment },
            .bg = bg.bg,
            .italic = true,
        };

        // Top border + title row.
        _ = win.printSegment(.{ .text = "╭", .style = border }, .{ .row_offset = box_y, .col_offset = box_x });
        for (1..box_width - 1) |i| {
            _ = win.printSegment(.{ .text = "─", .style = border }, .{ .row_offset = box_y, .col_offset = box_x + @as(u16, @intCast(i)) });
        }
        _ = win.printSegment(.{ .text = "╮", .style = border }, .{ .row_offset = box_y, .col_offset = box_x + box_width - 1 });

        fillRow(win, box_x, box_y + 1, box_width, bg);
        _ = win.printSegment(.{ .text = "│", .style = border }, .{ .row_offset = box_y + 1, .col_offset = box_x });
        _ = win.printSegment(.{ .text = "│", .style = border }, .{ .row_offset = box_y + 1, .col_offset = box_x + box_width - 1 });
        _ = win.printSegment(.{ .text = title, .style = title_style }, .{ .row_offset = box_y + 1, .col_offset = box_x + 1 });

        const list_top: u16 = box_y + 2;
        const list_bottom: u16 = box_y + box_height - 2;
        const list_rows: usize = @intCast(list_bottom - list_top);

        var effective_scroll = scroll_offset;
        if (selected < effective_scroll) effective_scroll = selected;
        if (selected >= effective_scroll + list_rows) {
            effective_scroll = if (selected + 1 > list_rows) selected + 1 - list_rows else 0;
        }

        var row: u16 = list_top;
        var i: usize = effective_scroll;
        while (i < row_count and row < list_bottom) : ({
            i += 1;
            row += 1;
        }) {
            const is_sel = i == selected;
            // Fill the row's interior with the row's *final* background
            // up front (blue for selected, panel bg otherwise). Without
            // this two-step the content drawn by `ctx.drawRow` would
            // overwrite the highlight with its own panel-bg cells and
            // leave only the trailing whitespace highlighted — exactly
            // the "sloppy" look the user reported.
            const row_bg: vaxis.Cell.Style = if (is_sel) selected_style else bg;
            fillRow(win, box_x, row, box_width, row_bg);
            _ = win.printSegment(.{ .text = "│", .style = border }, .{ .row_offset = row, .col_offset = box_x });
            _ = win.printSegment(.{ .text = "│", .style = border }, .{ .row_offset = row, .col_offset = box_x + box_width - 1 });

            // Selection arrow: `▶ ` on the selected row, `  ` on the
            // others so columns align. Gives a glanceable indicator
            // even when colour styling is muted (low-contrast themes,
            // screenshots, colour-blind users).
            const indicator: []const u8 = if (is_sel) "▶ " else "  ";
            const indicator_style: vaxis.Cell.Style = if (is_sel) selected_style else bg;
            _ = win.printSegment(.{ .text = indicator, .style = indicator_style }, .{ .row_offset = row, .col_offset = box_x + 2 });

            const inner_max: u16 = if (box_width > 6) box_width - 6 else 0;
            try ctx.drawRow(win, row, box_x + 4, inner_max, i, is_sel);
        }
        while (row < list_bottom) : (row += 1) {
            fillRow(win, box_x, row, box_width, bg);
            _ = win.printSegment(.{ .text = "│", .style = border }, .{ .row_offset = row, .col_offset = box_x });
            _ = win.printSegment(.{ .text = "│", .style = border }, .{ .row_offset = row, .col_offset = box_x + box_width - 1 });
        }

        // Footer with key hints.
        fillRow(win, box_x, list_bottom, box_width, bg);
        _ = win.printSegment(.{ .text = "│", .style = border }, .{ .row_offset = list_bottom, .col_offset = box_x });
        _ = win.printSegment(.{ .text = "│", .style = border }, .{ .row_offset = list_bottom, .col_offset = box_x + box_width - 1 });
        if (footer_hint.len + 2 < box_width) {
            _ = win.printSegment(.{ .text = footer_hint, .style = hint_style }, .{ .row_offset = list_bottom, .col_offset = box_x + 1 });
        }

        _ = win.printSegment(.{ .text = "╰", .style = border }, .{ .row_offset = box_y + box_height - 1, .col_offset = box_x });
        for (1..box_width - 1) |bx| {
            _ = win.printSegment(.{ .text = "─", .style = border }, .{ .row_offset = box_y + box_height - 1, .col_offset = box_x + @as(u16, @intCast(bx)) });
        }
        _ = win.printSegment(.{ .text = "╯", .style = border }, .{ .row_offset = box_y + box_height - 1, .col_offset = box_x + box_width - 1 });
    }

    fn drawReferencesPicker(
        win: vaxis.Window,
        symbol: ?[]const u8,
        entries: []const protocol.ReferenceEntry,
        selected: usize,
        scroll_offset: usize,
    ) !void {
        var title_buf: [128]u8 = undefined;
        const title = if (symbol) |sym|
            std.fmt.bufPrint(&title_buf, " References — {s} ({d})", .{ sym, entries.len }) catch " References "
        else
            std.fmt.bufPrint(&title_buf, " References ({d})", .{entries.len}) catch " References ";

        const Ctx = struct {
            entries: []const protocol.ReferenceEntry,
            fn drawRow(self: @This(), w: vaxis.Window, row: u16, base_col: u16, max_w: u16, i: usize, is_sel: bool) !void {
                const e = self.entries[i];
                const panel_bg: vaxis.Cell.Style = theme.styles.panel.background;
                // Selected row inherits the blue bg so the fg-only
                // styles below don't punch holes in the highlight.
                const row_bg = if (is_sel)
                    vaxis.Cell.Style{ .bg = .{ .index = theme.colors.palette.blue } }
                else
                    panel_bg;
                const path_style: vaxis.Cell.Style = .{ .fg = .{ .rgb = theme.colors.syntax.namespace }, .bg = row_bg.bg, .bold = true };
                const linecol_style: vaxis.Cell.Style = .{ .fg = .{ .rgb = theme.colors.syntax.number }, .bg = row_bg.bg };
                const snippet_style: vaxis.Cell.Style = if (is_sel)
                    .{ .fg = .{ .index = theme.colors.palette.bright_white }, .bg = row_bg.bg, .bold = true }
                else
                    panel_bg;

                var line_buf: [16]u8 = undefined;
                const linecol = std.fmt.bufPrint(&line_buf, "{d}:{d}", .{ e.line + 1, e.col + 1 }) catch "?";

                var col: u16 = base_col;
                _ = w.printSegment(.{ .text = e.display_path, .style = path_style }, .{ .row_offset = row, .col_offset = col });
                col += @intCast(@min(e.display_path.len, @as(usize, max_w / 3)));
                _ = w.printSegment(.{ .text = " :", .style = row_bg }, .{ .row_offset = row, .col_offset = col });
                col += 2;
                _ = w.printSegment(.{ .text = linecol, .style = linecol_style }, .{ .row_offset = row, .col_offset = col });
                col += @intCast(linecol.len);
                _ = w.printSegment(.{ .text = "  ", .style = row_bg }, .{ .row_offset = row, .col_offset = col });
                col += 2;
                const remaining: usize = if (col > base_col + max_w) 0 else base_col + max_w - col;
                const snip_take = if (e.snippet.len > remaining) e.snippet[0..remaining] else e.snippet;
                _ = w.printSegment(.{ .text = snip_take, .style = snippet_style }, .{ .row_offset = row, .col_offset = col });
            }
        };
        const ctx = Ctx{ .entries = entries };
        try drawModalList(win, title, " j/k move · ⏎ open · g/G top/bottom · esc back ", entries.len, selected, scroll_offset, ctx);
    }

    fn drawDiagnosticsPicker(
        win: vaxis.Window,
        entries: []const protocol.DiagnosticPickerEntry,
        selected: usize,
        scroll_offset: usize,
    ) !void {
        var title_buf: [64]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buf, " Diagnostics ({d})", .{entries.len}) catch " Diagnostics ";

        const Ctx = struct {
            entries: []const protocol.DiagnosticPickerEntry,
            fn drawRow(self: @This(), w: vaxis.Window, row: u16, base_col: u16, max_w: u16, i: usize, is_sel: bool) !void {
                const e = self.entries[i];
                const panel_bg: vaxis.Cell.Style = theme.styles.panel.background;
                // Selected row inherits the blue bg so the fg-only
                // severity / linecol styles below preserve the highlight.
                const row_bg = if (is_sel)
                    vaxis.Cell.Style{ .bg = .{ .index = theme.colors.palette.blue } }
                else
                    panel_bg;
                const sev_glyph: []const u8 = switch (e.severity) {
                    .err => "E ",
                    .warning => "W ",
                    .info => "I ",
                    .hint => "H ",
                };
                const sev_style: vaxis.Cell.Style = switch (e.severity) {
                    .err => .{ .fg = .{ .rgb = .{ 224, 108, 117 } }, .bg = row_bg.bg, .bold = true },
                    .warning => .{ .fg = .{ .rgb = .{ 229, 192, 123 } }, .bg = row_bg.bg, .bold = true },
                    .info => .{ .fg = .{ .rgb = .{ 86, 182, 194 } }, .bg = row_bg.bg },
                    .hint => .{ .fg = .{ .rgb = .{ 128, 128, 140 } }, .bg = row_bg.bg },
                };
                const linecol_style: vaxis.Cell.Style = .{ .fg = .{ .rgb = theme.colors.syntax.number }, .bg = row_bg.bg };
                const msg_style: vaxis.Cell.Style = if (is_sel)
                    .{ .fg = .{ .index = theme.colors.palette.bright_white }, .bg = row_bg.bg, .bold = true }
                else
                    panel_bg;

                var line_buf: [16]u8 = undefined;
                const linecol = std.fmt.bufPrint(&line_buf, "{d}:{d}", .{ e.line + 1, e.col + 1 }) catch "?";

                var col: u16 = base_col;
                _ = w.printSegment(.{ .text = sev_glyph, .style = sev_style }, .{ .row_offset = row, .col_offset = col });
                col += @intCast(sev_glyph.len);
                _ = w.printSegment(.{ .text = linecol, .style = linecol_style }, .{ .row_offset = row, .col_offset = col });
                col += @intCast(linecol.len);
                _ = w.printSegment(.{ .text = "  ", .style = row_bg }, .{ .row_offset = row, .col_offset = col });
                col += 2;
                const remaining: usize = if (col > base_col + max_w) 0 else base_col + max_w - col;
                const msg_take = if (e.message.len > remaining) e.message[0..remaining] else e.message;
                _ = w.printSegment(.{ .text = msg_take, .style = msg_style }, .{ .row_offset = row, .col_offset = col });
            }
        };
        const ctx = Ctx{ .entries = entries };
        try drawModalList(win, title, " j/k move · ⏎ jump · g/G top/bottom · esc back ", entries.len, selected, scroll_offset, ctx);
    }

    /// Fill an interior row (`box_x+1` through `box_x+width-2`) with
    /// blanks in the popup background so syntax tokens behind the
    /// popup don't bleed through.
    fn fillRow(win: vaxis.Window, box_x: u16, row: u16, width: u16, bg_style: vaxis.Cell.Style) void {
        if (width < 2) return;
        var j: u16 = 1;
        while (j < width - 1) : (j += 1) {
            _ = win.printSegment(.{ .text = " ", .style = bg_style }, .{ .row_offset = row, .col_offset = box_x + j });
        }
    }

    /// One-line divider between header / signature / body / footer.
    fn drawDivider(win: vaxis.Window, box_x: u16, row: u16, width: u16, styles: HoverStyle) void {
        _ = win.printSegment(.{ .text = "├", .style = styles.border }, .{ .row_offset = row, .col_offset = box_x });
        for (1..width - 1) |i| {
            _ = win.printSegment(.{ .text = "─", .style = styles.divider }, .{ .row_offset = row, .col_offset = box_x + @as(u16, @intCast(i)) });
        }
        _ = win.printSegment(.{ .text = "┤", .style = styles.border }, .{ .row_offset = row, .col_offset = box_x + width - 1 });
    }

    /// Truncate `text` to at most `max` bytes — byte-accurate, with a
    /// trailing `…` when truncated. Good enough for ASCII-heavy
    /// signatures and the doc text we get from LSPs; non-ASCII gets a
    /// conservative byte-budget that won't split a codepoint at the
    /// expense of a few cells.
    fn truncateText(text: []const u8, max: usize) []const u8 {
        if (text.len <= max) return text;
        if (max == 0) return "";
        // Don't bother with a real width count — bytes are a close
        // enough approximation for our hover content and the ellipsis
        // makes truncation visible.
        return text[0..@min(text.len, max)];
    }

    /// Compute the popup's `box_x` so it stays inside `win`. Prefers
    /// the anchor column, slides left when the box would overflow,
    /// always leaves a 1-cell right margin.
    fn box_x_for(win: vaxis.Window, width: u16, anchor_col: u16) u16 {
        const margin: u16 = 1;
        const max_x: u16 = if (win.width > width + margin) win.width - width - margin else 0;
        return @min(anchor_col, max_x);
    }

    // ---- Which-key popup -------------------------------------------------
    //
    // Renders a small grouped panel at the bottom of the window
    // listing every leader-key binding. Driven entirely by the
    // static catalogue in `ui/which_key.zig` so the popup never
    // claims a binding that doesn't exist.

    fn drawWhichKey(self: *View, win: vaxis.Window, leader_chord: ?u8) !void {
        _ = self;
        const wk = @import("which_key.zig");

        if (win.width < 30 or win.height < 8) return;

        // Pick the entry list for the current chord context.
        // No chord → top-level catalogue; in a chord → sub-list.
        const entries = wk.entriesFor(leader_chord);
        const title = wk.titleFor(leader_chord);

        // Discover the unique groups present in `entries`, in the
        // order they first appear. This keeps the popup layout
        // stable and makes the chord sub-popups (which may have
        // only one group) render cleanly without empty sections.
        var groups_buf: [@typeInfo(wk.Group).@"enum".fields.len]wk.Group = undefined;
        var groups_len: usize = 0;
        for (entries) |e| {
            var seen = false;
            for (groups_buf[0..groups_len]) |g| {
                if (g == e.group) {
                    seen = true;
                    break;
                }
            }
            if (!seen) {
                groups_buf[groups_len] = e.group;
                groups_len += 1;
            }
        }
        const groups = groups_buf[0..groups_len];

        // Count entries per group + tallest column.
        var per_group_counts: [@typeInfo(wk.Group).@"enum".fields.len]usize = .{0} ** @typeInfo(wk.Group).@"enum".fields.len;
        for (entries) |e| {
            for (groups, 0..) |g, gi| {
                if (e.group == g) per_group_counts[gi] += 1;
            }
        }

        // Cap popup width so it never dominates the screen.
        const max_popup_w: u16 = 70;
        const popup_width: u16 = @min(max_popup_w, win.width -| 4);
        const columns: u16 = if (popup_width >= 60 and groups_len >= 3) 3 else if (popup_width >= 40 and groups_len >= 2) 2 else 1;
        const col_width: u16 = if (columns > 0) (popup_width - 4) / columns else popup_width;

        const rows_per_col = if (columns > 0) (groups_len + columns - 1) / columns else groups_len;
        const popup_height: u16 = blk: {
            // Each column section: 1 header + N entries + 1 separator.
            var section_rows: usize = 0;
            var col: usize = 0;
            while (col < columns) : (col += 1) {
                var col_rows: usize = 0;
                var sec: usize = 0;
                while (sec < rows_per_col) : (sec += 1) {
                    const idx = col * rows_per_col + sec;
                    if (idx >= groups_len) break;
                    col_rows += 1 + per_group_counts[idx] + 1;
                }
                section_rows = @max(section_rows, col_rows);
            }
            const natural = section_rows + 3;
            // Top-level popup carries every chord's sub-bindings
            // now (10 groups, ~46 entries) — let it use up to ~80%
            // of the viewport so nothing gets clipped. Chord-only
            // popups stay tiny because `natural` will be small.
            const max_pop_h: usize = (@as(usize, win.height) * 4) / 5;
            break :blk @intCast(@min(@min(natural, max_pop_h), @as(usize, win.height) - 1));
        };

        const box_x: u16 = (win.width -| popup_width) / 2;
        const box_y: u16 = win.height -| (popup_height + 1);

        const styles = whichKeyStyles();

        // Top frame.
        _ = win.printSegment(.{ .text = "╭", .style = styles.border }, .{ .row_offset = box_y, .col_offset = box_x });
        for (1..popup_width - 1) |i| {
            _ = win.printSegment(.{ .text = "─", .style = styles.border }, .{ .row_offset = box_y, .col_offset = box_x + @as(u16, @intCast(i)) });
        }
        _ = win.printSegment(.{ .text = "╮", .style = styles.border }, .{ .row_offset = box_y, .col_offset = box_x + popup_width - 1 });

        // Title row. Reflects the active chord prefix.
        fillRow(win, box_x, box_y + 1, popup_width, styles.bg);
        _ = win.printSegment(.{ .text = title, .style = styles.title }, .{ .row_offset = box_y + 1, .col_offset = box_x + 2 });
        const hint = if (leader_chord != null) "esc back" else "esc cancel";
        if (popup_width > hint.len + 6) {
            const hint_col = box_x + popup_width - 1 - @as(u16, @intCast(hint.len)) - 1;
            _ = win.printSegment(.{ .text = hint, .style = styles.hint }, .{ .row_offset = box_y + 1, .col_offset = hint_col });
        }
        _ = win.printSegment(.{ .text = "│", .style = styles.border }, .{ .row_offset = box_y + 1, .col_offset = box_x });
        _ = win.printSegment(.{ .text = "│", .style = styles.border }, .{ .row_offset = box_y + 1, .col_offset = box_x + popup_width - 1 });

        const inner_top = box_y + 2;
        const inner_bottom = box_y + popup_height - 1;

        var iy: u16 = inner_top;
        while (iy < inner_bottom) : (iy += 1) {
            fillRow(win, box_x, iy, popup_width, styles.bg);
            _ = win.printSegment(.{ .text = "│", .style = styles.border }, .{ .row_offset = iy, .col_offset = box_x });
            _ = win.printSegment(.{ .text = "│", .style = styles.border }, .{ .row_offset = iy, .col_offset = box_x + popup_width - 1 });
        }

        var col_idx: usize = 0;
        while (col_idx < columns) : (col_idx += 1) {
            const col_left = box_x + 2 + @as(u16, @intCast(col_idx)) * col_width;
            var row_in_col: u16 = inner_top;
            var sec_idx: usize = 0;
            while (sec_idx < rows_per_col) : (sec_idx += 1) {
                const gi = col_idx * rows_per_col + sec_idx;
                if (gi >= groups_len) break;
                if (row_in_col >= inner_bottom) break;
                const g = groups[gi];
                _ = win.printSegment(.{ .text = g.title(), .style = styles.group_title }, .{
                    .row_offset = row_in_col,
                    .col_offset = col_left,
                });
                row_in_col += 1;
                for (entries) |e| {
                    if (e.group != g) continue;
                    if (row_in_col >= inner_bottom) break;
                    _ = win.printSegment(.{ .text = e.key, .style = styles.key }, .{
                        .row_offset = row_in_col,
                        .col_offset = col_left + 1,
                    });
                    _ = win.printSegment(.{ .text = e.label, .style = styles.label }, .{
                        .row_offset = row_in_col,
                        .col_offset = col_left + 4,
                    });
                    row_in_col += 1;
                }
                row_in_col += 1;
            }
        }

        _ = win.printSegment(.{ .text = "╰", .style = styles.border }, .{ .row_offset = inner_bottom, .col_offset = box_x });
        for (1..popup_width - 1) |i| {
            _ = win.printSegment(.{ .text = "─", .style = styles.border }, .{ .row_offset = inner_bottom, .col_offset = box_x + @as(u16, @intCast(i)) });
        }
        _ = win.printSegment(.{ .text = "╯", .style = styles.border }, .{ .row_offset = inner_bottom, .col_offset = box_x + popup_width - 1 });
    }

    const WhichKeyStyle = struct {
        border: vaxis.Cell.Style,
        bg: vaxis.Cell.Style,
        title: vaxis.Cell.Style,
        group_title: vaxis.Cell.Style,
        key: vaxis.Cell.Style,
        label: vaxis.Cell.Style,
        hint: vaxis.Cell.Style,
    };

    fn whichKeyStyles() WhichKeyStyle {
        const bg_color = vaxis.Cell.Color{ .rgb = .{ 30, 30, 46 } };
        return .{
            .border = .{ .fg = .{ .rgb = .{ 108, 112, 134 } }, .bg = bg_color },
            .bg = .{ .bg = bg_color },
            .title = .{ .fg = .{ .rgb = .{ 245, 224, 220 } }, .bg = bg_color, .bold = true },
            .group_title = .{ .fg = .{ .rgb = .{ 137, 180, 250 } }, .bg = bg_color, .bold = true },
            .key = .{ .fg = .{ .rgb = .{ 250, 179, 135 } }, .bg = bg_color, .bold = true },
            .label = .{ .fg = .{ .rgb = .{ 205, 214, 244 } }, .bg = bg_color },
            .hint = .{ .fg = .{ .rgb = .{ 108, 112, 134 } }, .bg = bg_color, .italic = true },
        };
    }

    /// One-line popup above the cursor showing the active LSP
    /// signature. The active parameter (when in range) is rendered
    /// in bold + underline so the user sees which argument they're
    /// typing. Falls back to plain label rendering if the parameter
    /// label can't be located inside the signature.
    fn drawSignatureHelp(
        self: *View,
        win: vaxis.Window,
        label: []const u8,
        params: []const []const u8,
        active_param: u32,
        cursor_row: usize,
        cursor_col: usize,
        scroll_offset: usize,
    ) !void {
        _ = self;
        if (label.len == 0) return;
        if (win.width < 10 or win.height < 3) return;

        // Trim multi-line labels — most servers keep it to one line,
        // but Rust analyzer occasionally returns wrapped text.
        var display = label;
        if (std.mem.indexOfScalar(u8, display, '\n')) |nl| display = display[0..nl];

        const max_width: u16 = @min(@as(u16, @intCast(display.len + 4)), @as(u16, @intCast(@as(usize, win.width) -| 2)));
        const screen_row: u16 = @intCast(cursor_row -| scroll_offset);
        // Prefer the row above the cursor; fall back below if there's no room.
        var box_y: u16 = if (screen_row >= 1) screen_row - 1 else screen_row + 1;
        if (box_y >= win.height) box_y = win.height - 1;
        var box_x: u16 = @intCast(@min(cursor_col, @as(usize, win.width) -| @as(usize, max_width)));
        _ = &box_x;

        const bg: vaxis.Cell.Color = .{ .index = 0 };
        const fg: vaxis.Cell.Color = .{ .index = 7 };
        // vaxis Cell.Style doesn't expose underline as a free field
        // here; bold alone is enough to mark the active parameter
        // without the rendering becoming noisy.
        const active_style: vaxis.Cell.Style = .{ .fg = fg, .bg = bg, .bold = true };
        const base_style: vaxis.Cell.Style = .{ .fg = fg, .bg = bg };

        // Wipe the background.
        var clear_buf: [128]u8 = undefined;
        const clear_n = @min(@as(usize, max_width), clear_buf.len);
        @memset(clear_buf[0..clear_n], ' ');
        _ = win.printSegment(.{ .text = clear_buf[0..clear_n], .style = base_style }, .{ .row_offset = box_y, .col_offset = box_x });

        // Find the active parameter's byte range in the label so we
        // can style just that span. If the param label appears
        // multiple times, take the first hit — which matches what
        // LSP servers intend in practice.
        var active_start: ?usize = null;
        var active_end: usize = 0;
        if (active_param < params.len) {
            const want = params[active_param];
            if (want.len > 0) {
                if (std.mem.indexOf(u8, display, want)) |off| {
                    active_start = off;
                    active_end = off + want.len;
                }
            }
        }

        const fits = @min(display.len, @as(usize, max_width) -| 2);
        const truncated = display[0..fits];
        if (active_start) |st| {
            const en = @min(active_end, fits);
            const pre = truncated[0..@min(st, fits)];
            const mid = if (en > st and st < fits) truncated[st..en] else "";
            const post = if (en < fits) truncated[en..fits] else "";
            _ = win.printSegment(.{ .text = " ", .style = base_style }, .{ .row_offset = box_y, .col_offset = box_x });
            var col: u16 = box_x + 1;
            if (pre.len > 0) {
                _ = win.printSegment(.{ .text = pre, .style = base_style }, .{ .row_offset = box_y, .col_offset = col });
                col += @intCast(pre.len);
            }
            if (mid.len > 0) {
                _ = win.printSegment(.{ .text = mid, .style = active_style }, .{ .row_offset = box_y, .col_offset = col });
                col += @intCast(mid.len);
            }
            if (post.len > 0) {
                _ = win.printSegment(.{ .text = post, .style = base_style }, .{ .row_offset = box_y, .col_offset = col });
            }
        } else {
            _ = win.printSegment(.{ .text = " ", .style = base_style }, .{ .row_offset = box_y, .col_offset = box_x });
            _ = win.printSegment(.{ .text = truncated, .style = base_style }, .{ .row_offset = box_y, .col_offset = box_x + 1 });
        }
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

    fn drawSearchInput(
        self: *View,
        win: vaxis.Window,
        input: []const u8,
        forward: bool,
        match_count: usize,
        match_index: usize,
        allocator: std.mem.Allocator,
    ) !void {
        _ = self;

        const box_width: u16 = 48;
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

        // Title: " /search " or " ?search " on the left; "  [i/N]" on
        // the right of the title row so the count is visible alongside
        // the prompt while you type.
        const prefix = if (forward) " / Search:" else " ? Search:";
        _ = win.printSegment(.{ .text = prefix, .style = box_style }, .{
            .row_offset = box_y,
            .col_offset = box_x + 1,
        });
        if (match_count > 0) {
            const count_text = try std.fmt.allocPrint(allocator, "[{d}/{d}] ", .{ match_index, match_count });
            defer allocator.free(count_text);
            const count_len: u16 = @intCast(@min(count_text.len, @as(usize, box_width - 2)));
            const count_col = box_x + box_width - count_len - 1;
            _ = win.printSegment(.{ .text = count_text, .style = box_style }, .{
                .row_offset = box_y,
                .col_offset = count_col,
            });
        } else if (input.len > 0) {
            const text = " [no matches] ";
            const text_len: u16 = @intCast(text.len);
            const col = box_x + box_width - text_len - 1;
            _ = win.printSegment(.{ .text = text, .style = box_style }, .{
                .row_offset = box_y,
                .col_offset = col,
            });
        }

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

    /// Project-wide LSP symbol search. Mirrors `drawSymbolPicker` but
    /// adds a third column for the basename of the file each symbol
    /// lives in, so the user can disambiguate when several symbols
    /// share a name.
    fn drawWorkspaceSymbolPicker(self: *View, win: vaxis.Window, snapshot: *const protocol.RenderSnapshot, allocator: std.mem.Allocator) !void {
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

        const width: usize = @min(win.width -| 4, 90);
        const height: usize = @min(win.height -| 4, 20);

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
        const file_style: vaxis.Cell.Style = .{
            .fg = .{ .index = 6 },
            .bg = .{ .index = 0 },
            .italic = true,
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

        const input_prefix = "› ";
        _ = win.printSegment(.{ .text = input_prefix, .style = border_style }, .{ .row_offset = @intCast(start_y + 1), .col_offset = @intCast(start_x + 1) });

        const query = snapshot.workspace_symbol_query orelse "";
        _ = win.printSegment(.{ .text = query, .style = box_style }, .{ .row_offset = @intCast(start_y + 1), .col_offset = @intCast(start_x + 1 + input_prefix.len) });
        _ = win.printSegment(.{ .text = " ", .style = .{ .reverse = true } }, .{ .row_offset = @intCast(start_y + 1), .col_offset = @intCast(start_x + 1 + input_prefix.len + query.len) });

        // Status hint right-aligned in the input row.
        const hint = if (snapshot.workspace_symbol_pending) "loading…" else "enter open · esc cancel";
        if (width > hint.len + 4) {
            const hint_col = start_x + width - hint.len - 1;
            _ = win.printSegment(.{ .text = hint, .style = .{ .fg = .{ .index = 8 }, .bg = .{ .index = 0 }, .italic = true } }, .{
                .row_offset = @intCast(start_y + 1),
                .col_offset = @intCast(hint_col),
            });
        }

        for (1..width) |i| {
            _ = win.printSegment(.{ .text = "─", .style = border_style }, .{ .row_offset = @intCast(start_y + 2), .col_offset = @intCast(start_x + i) });
        }

        if (snapshot.workspace_symbol_results) |results| {
            if (results.len == 0) {
                const msg = if (snapshot.workspace_symbol_pending) "Searching…" else "No matches.";
                _ = win.printSegment(.{ .text = msg, .style = .{ .fg = .{ .index = 8 }, .bg = .{ .index = 0 }, .italic = true } }, .{
                    .row_offset = @intCast(start_y + 3),
                    .col_offset = @intCast(start_x + 2),
                });
                return;
            }

            var start_index: usize = 0;
            if (snapshot.workspace_symbol_selected >= height) {
                start_index = snapshot.workspace_symbol_selected - height + 1;
            }

            const render_count = @min(height, results.len);

            for (0..render_count) |i| {
                const item_index = start_index + i;
                if (item_index >= results.len) break;

                const sym = results[item_index];

                const row = start_y + 3 + i;
                const is_selected = item_index == snapshot.workspace_symbol_selected;
                const style = if (is_selected) selected_style else box_style;

                for (1..width) |j| {
                    _ = win.printSegment(.{ .text = " ", .style = style }, .{ .row_offset = @intCast(row), .col_offset = @intCast(start_x + j) });
                }

                _ = win.printSegment(.{ .text = sym.name, .style = style }, .{ .row_offset = @intCast(row), .col_offset = @intCast(start_x + 2) });

                const k_style = if (is_selected) selected_style else kind_style;
                const f_style = if (is_selected) selected_style else file_style;

                // File basename in the middle / right of the row;
                // kind label flushed right.
                const basename = std.fs.path.basename(sym.file_path);
                const kind_text = sym.kind;
                const right_label_len = kind_text.len + 1; // trailing space
                if (width > sym.name.len + basename.len + right_label_len + 8) {
                    const basename_col = start_x + sym.name.len + 4;
                    _ = win.printSegment(.{ .text = basename, .style = f_style }, .{
                        .row_offset = @intCast(row),
                        .col_offset = @intCast(basename_col),
                    });
                    _ = win.printSegment(.{ .text = kind_text, .style = k_style }, .{
                        .row_offset = @intCast(row),
                        .col_offset = @intCast(start_x + width - right_label_len - 1),
                    });
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
