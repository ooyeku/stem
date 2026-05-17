const std = @import("std");

const log = std.log.scoped(.EditCommands);

pub const EditCommands = struct {
    pub fn cmdEditUndo(core: anytype) anyerror!void {
        const s = core.state();

        core.history_manager.flushTransaction(.{ .row = s.cursor_row, .col = s.cursor_col });

        if (core.history_manager.undo()) |txn| {
            defer {
                var t = txn;
                t.deinit(core.allocator);
            }

            var i = txn.actions.items.len;
            while (i > 0) {
                i -= 1;
                const action = txn.actions.items[i];
                switch (action) {
                    .insert => |ins| {
                        s.buffer.delete(ins.pos, ins.text.len) catch |err| {
                            log.warn("Undo: failed to reverse insert at pos={d} len={d}: {}", .{ ins.pos, ins.text.len, err });
                        };
                    },
                    .delete => |del| {
                        s.buffer.insert(del.pos, del.text) catch |err| {
                            log.warn("Undo: failed to reverse delete at pos={d} len={d}: {}", .{ del.pos, del.text.len, err });
                        };
                    },
                }
            }

            s.cursor_row = txn.cursor_before.row;
            s.cursor_col = txn.cursor_before.col;
            s.modified = true;

            try core.sendLspDocChanged();
            try core.sendUpdate();
        }
    }

    pub fn cmdEditRedo(core: anytype) anyerror!void {
        const s = core.state();

        if (core.history_manager.redo()) |txn| {
            defer {
                var t = txn;
                t.deinit(core.allocator);
            }

            for (txn.actions.items) |action| {
                switch (action) {
                    .insert => |ins| {
                        s.buffer.insert(ins.pos, ins.text) catch |err| {
                            log.warn("Redo: failed to re-apply insert at pos={d} len={d}: {}", .{ ins.pos, ins.text.len, err });
                        };
                    },
                    .delete => |del| {
                        s.buffer.delete(del.pos, del.text.len) catch |err| {
                            log.warn("Redo: failed to re-apply delete at pos={d} len={d}: {}", .{ del.pos, del.text.len, err });
                        };
                    },
                }
            }

            s.cursor_row = txn.cursor_after.row;
            s.cursor_col = txn.cursor_after.col;
            s.modified = true;

            try core.sendLspDocChanged();
            try core.sendUpdate();
        }
    }

    pub fn cmdEditCopy(core: anytype) anyerror!void {
        const text = try core.getSelectionText() orelse return;
        defer core.allocator.free(text);

        core.clipboard.clearRetainingCapacity();
        try core.clipboard.appendSlice(core.allocator, text);

        var line_count: usize = 1;
        for (text) |c| {
            if (c == '\n') line_count += 1;
        }

        core.status_message = if (line_count == 1) "Copied 1 line" else if (line_count < 10) "Copied lines" else "Copied selection";
        core.status_message_expires = std.Io.Clock.real.now(core.io).toMilliseconds() + 2000;

        if (core.mode == .visual or core.mode == .visual_search) {
            core.state().selection_anchor = null;
            core.mode = .select;
        }

        try core.sendUpdate();
    }

    pub fn cmdEditCut(core: anytype) anyerror!void {
        const s = core.state();

        const text = try core.getSelectionText() orelse return;
        defer core.allocator.free(text);

        core.clipboard.clearRetainingCapacity();
        try core.clipboard.appendSlice(core.allocator, text);

        var line_count: usize = 1;
        for (text) |c| {
            if (c == '\n') line_count += 1;
        }

        core.status_message = if (line_count == 1) "Cut 1 line" else if (line_count < 10) "Cut lines" else "Cut selection";
        core.status_message_expires = std.Io.Clock.real.now(core.io).toMilliseconds() + 2000;

        const anchor = s.selection_anchor orelse return;
        var start_row: usize = undefined;
        var start_col: usize = undefined;
        var end_row: usize = undefined;
        var end_col: usize = undefined;

        if (anchor.row < s.cursor_row or (anchor.row == s.cursor_row and anchor.col <= s.cursor_col)) {
            start_row = anchor.row;
            start_col = anchor.col;
            end_row = s.cursor_row;
            end_col = s.cursor_col;
        } else {
            start_row = s.cursor_row;
            start_col = s.cursor_col;
            end_row = anchor.row;
            end_col = anchor.col;
        }

        const start_off = s.getOffsetFor(start_row, start_col);
        const end_off = s.getOffsetFor(end_row, end_col);
        try core.deleteRangeWithHistory(start_off, end_off);

        s.selection_anchor = null;
        if (core.mode == .visual or core.mode == .visual_search) {
            core.mode = .select;
        }

        try core.sendLspDocChanged();
        try core.sendUpdate();
    }

    pub fn cmdEditPaste(core: anytype) anyerror!void {
        if (core.clipboard.items.len == 0) return;

        try core.insertTextWithHistory(core.clipboard.items);

        try core.sendLspDocChanged();
        try core.sendUpdate();
    }

    pub fn cmdEditDeleteLine(core: anytype) anyerror!void {
        const s = core.state();
        try s.deleteLine(s.cursor_row);
        const total = s.buffer.lineCount();
        if (s.cursor_row >= total and total > 0) {
            s.cursor_row = total - 1;
        }
        try core.sendLspDocChanged();
        try core.sendUpdate();
    }

    pub fn cmdEditDuplicateLine(core: anytype) anyerror!void {
        const s = core.state();
        try s.duplicateLine(s.cursor_row);
        try core.sendLspDocChanged();
        try core.sendUpdate();
    }

    pub fn cmdEditMoveLineUp(core: anytype) anyerror!void {
        const s = core.state();
        if (s.cursor_row > 0) {
            try s.swapAdjacentLines(s.cursor_row, s.cursor_row - 1);
            s.cursor_row -= 1;
            try core.sendLspDocChanged();
            try core.sendUpdate();
        }
    }

    pub fn cmdEditMoveLineDown(core: anytype) anyerror!void {
        const s = core.state();
        const total_lines = s.buffer.lineCount();
        if (s.cursor_row + 1 < total_lines) {
            try s.swapAdjacentLines(s.cursor_row, s.cursor_row + 1);
            s.cursor_row += 1;
            try core.sendLspDocChanged();
            try core.sendUpdate();
        }
    }

    pub fn cmdEditJoinLines(core: anytype) anyerror!void {
        const s = core.state();
        try s.joinLines(s.cursor_row);
        try core.sendLspDocChanged();
        try core.sendUpdate();
    }

    pub fn cmdEditInsertDateTime(core: anytype) anyerror!void {
        const timestamp = std.Io.Clock.real.now(core.io).toSeconds();
        const epoch_secs: std.time.epoch.EpochSeconds = .{ .secs = @intCast(timestamp) };
        const day_seconds = epoch_secs.getDaySeconds();
        const year_day = epoch_secs.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();

        const text = try std.fmt.allocPrint(core.allocator, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
            year_day.year,
            @intFromEnum(month_day.month),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        });
        defer core.allocator.free(text);

        try core.insertTextWithHistory(text);

        try core.sendLspDocChanged();
        try core.sendUpdate();
    }
};
