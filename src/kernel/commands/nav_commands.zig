const std = @import("std");

pub const NavCommands = struct {
    pub fn cmdNavGoToLine(core: anytype) anyerror!void {
        core.previous_mode = core.mode;
        core.mode = .go_to_line;
        core.go_to_line_input.clearRetainingCapacity();
        try core.sendUpdate();
    }

    pub fn cmdNavGoToSymbol(core: anytype) anyerror!void {
        core.previous_mode = core.mode;
        core.mode = .symbol_picker;
        core.symbol_picker_query.clearRetainingCapacity();
        core.symbol_picker_selected = 0;

        for (core.symbol_picker_results.items) |entry| {
            core.allocator.free(entry.name);
        }
        core.symbol_picker_results.clearRetainingCapacity();
        for (core.symbol_picker_all_symbols.items) |entry| {
            core.allocator.free(entry.name);
        }
        core.symbol_picker_all_symbols.clearRetainingCapacity();

        const s = core.state();
        const content = s.buffer.toString(core.allocator) catch return;
        defer core.allocator.free(content);

        const symbols = core.syntax_manager.getSymbols(core.allocator, content) catch return;
        defer core.allocator.free(symbols);

        for (symbols) |sym| {
            const name_dupe = core.allocator.dupe(u8, sym.name) catch continue;
            try core.symbol_picker_all_symbols.append(core.allocator, .{
                .name = name_dupe,
                .kind = sym.kind,
                .line = sym.line,
            });
            const name_dupe2 = core.allocator.dupe(u8, sym.name) catch continue;
            try core.symbol_picker_results.append(core.allocator, .{
                .name = name_dupe2,
                .kind = sym.kind,
                .line = sym.line,
            });
        }

        try core.sendUpdate();
    }

    pub fn cmdNavTopOfFile(core: anytype) anyerror!void {
        const s = core.state();
        s.cursor_row = 0;
        s.cursor_col = 0;
        s.scroll_offset = 0;
        try core.sendUpdate();
    }

    pub fn cmdNavBottomOfFile(core: anytype) anyerror!void {
        const s = core.state();
        const total_lines = s.buffer.lineCount();
        if (total_lines > 0) {
            s.cursor_row = total_lines - 1;
            s.cursor_col = 0;
        }
        try core.sendUpdate();
    }

    pub fn cmdNavCenterView(core: anytype) anyerror!void {
        const s = core.state();
        const visible_rows: usize = if (core.win_size.rows > 2) core.win_size.rows - 2 else 1;
        const half = visible_rows / 2;

        if (s.cursor_row >= half) {
            s.scroll_offset = s.cursor_row - half;
        } else {
            s.scroll_offset = 0;
        }
        try core.sendUpdate();
    }

    pub fn cmdSearchFindInBuffer(core: anytype) anyerror!void {
        core.previous_mode = .select;
        core.mode = .visual_search;
        core.search_input.clearRetainingCapacity();
        try core.sendUpdate();
    }

    pub fn cmdNavExpandSelection(core: anytype) anyerror!void {
        const s = core.state();

        const start_line: usize = if (s.selection_anchor) |a| @min(a.row, s.cursor_row) else s.cursor_row;
        const start_col: usize = if (s.selection_anchor) |a| @min(a.col, s.cursor_col) else s.cursor_col;
        const end_line: usize = if (s.selection_anchor) |a| @max(a.row, s.cursor_row) else s.cursor_row;
        const end_col: usize = if (s.selection_anchor) |a| @max(a.col, s.cursor_col) else s.cursor_col;

        const expanded = core.syntax_manager.expandSelection(start_line, start_col, end_line, end_col);

        if (core.mode != .visual) {
            core.mode = .visual;
        }

        s.selection_anchor = .{ .row = expanded.start_line, .col = expanded.start_col };
        s.cursor_row = expanded.end_line;
        s.cursor_col = expanded.end_col;

        try core.sendUpdate();
    }

    pub fn cmdNavMatchBracket(core: anytype) anyerror!void {
        const s = core.state();
        const line = s.getLineContent(s.cursor_row) catch return;
        defer core.allocator.free(line);

        if (s.cursor_col >= line.len) return;
        const char = line[s.cursor_col];

        const pairs = [_][2]u8{ .{ '(', ')' }, .{ '{', '}' }, .{ '[', ']' }, .{ '<', '>' } };

        for (pairs) |pair| {
            if (char == pair[0]) {
                if (findMatchingBracket(core, s, s.cursor_row, s.cursor_col, pair[0], pair[1], true)) |pos| {
                    s.cursor_row = pos[0];
                    s.cursor_col = pos[1];
                }
                try core.sendUpdate();
                return;
            } else if (char == pair[1]) {
                if (findMatchingBracket(core, s, s.cursor_row, s.cursor_col, pair[0], pair[1], false)) |pos| {
                    s.cursor_row = pos[0];
                    s.cursor_col = pos[1];
                }
                try core.sendUpdate();
                return;
            }
        }
    }

    fn findMatchingBracket(
        core: anytype,
        s: anytype,
        start_row: usize,
        start_col: usize,
        open: u8,
        close: u8,
        forward: bool,
    ) ?[2]usize {
        const total_lines = s.buffer.lineCount();
        if (total_lines == 0) return null;

        var depth: i32 = 0;
        var row = start_row;
        var first_line = true;

        if (forward) {
            while (row < total_lines) {
                const line = s.getLineContent(row) catch return null;
                defer core.allocator.free(line);

                const start_col_in_line: usize = if (first_line) start_col else 0;
                first_line = false;

                var col = start_col_in_line;
                while (col < line.len) {
                    const c = line[col];
                    if (c == open) {
                        depth += 1;
                    } else if (c == close) {
                        depth -= 1;
                        if (depth == 0) {
                            return .{ row, col };
                        }
                    }
                    col += 1;
                }
                row += 1;
            }
        } else {
            var signed_row: i64 = @intCast(start_row);
            while (signed_row >= 0) {
                const urow: usize = @intCast(signed_row);
                const line = s.getLineContent(urow) catch return null;
                defer core.allocator.free(line);

                const end_col: usize = if (first_line) start_col + 1 else line.len;
                first_line = false;

                var col: i64 = @intCast(@min(end_col, line.len));
                while (col > 0) {
                    col -= 1;
                    const ucol: usize = @intCast(col);
                    const c = line[ucol];
                    if (c == close) {
                        depth += 1;
                    } else if (c == open) {
                        depth -= 1;
                        if (depth == 0) {
                            return .{ urow, ucol };
                        }
                    }
                }
                signed_row -= 1;
            }
        }
        return null;
    }
};
