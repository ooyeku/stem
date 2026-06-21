const std = @import("std");

const log = std.log.scoped(.EditCommands);

pub const EditCommands = struct {
    /// Count newlines in `text` to report "N lines" feedback for
    /// clipboard / paste / line operations.
    fn lineCountIn(text: []const u8) usize {
        var count: usize = 1;
        for (text) |c| {
            if (c == '\n') count += 1;
        }
        return count;
    }

    pub fn cmdEditUndo(core: anytype) anyerror!void {
        if (core.rejectReadOnlyPresentationEdit()) return;
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
                        s.deleteRangeAtOffset(ins.pos, ins.pos + ins.text.len) catch |err| {
                            log.warn("Undo: failed to reverse insert at pos={d} len={d}: {}", .{ ins.pos, ins.text.len, err });
                        };
                    },
                    .delete => |del| {
                        s.insertTextAtOffset(del.pos, del.text) catch |err| {
                            log.warn("Undo: failed to reverse delete at pos={d} len={d}: {}", .{ del.pos, del.text.len, err });
                        };
                    },
                }
            }

            s.cursor_row = txn.cursor_before.row;
            s.cursor_col = txn.cursor_before.col;
            s.preferred_col = null;
            s.modified = true;

            core.setStatusLiteral("Undo", 1500);
            try core.sendLspDocChanged();
            try core.sendUpdate();
        } else {
            core.setStatusLiteralLeveled(.info, "Nothing to undo", 1500);
            try core.sendUpdate();
        }
    }

    pub fn cmdEditRedo(core: anytype) anyerror!void {
        if (core.rejectReadOnlyPresentationEdit()) return;
        const s = core.state();

        if (core.history_manager.redo()) |txn| {
            defer {
                var t = txn;
                t.deinit(core.allocator);
            }

            for (txn.actions.items) |action| {
                switch (action) {
                    .insert => |ins| {
                        s.insertTextAtOffset(ins.pos, ins.text) catch |err| {
                            log.warn("Redo: failed to re-apply insert at pos={d} len={d}: {}", .{ ins.pos, ins.text.len, err });
                        };
                    },
                    .delete => |del| {
                        s.deleteRangeAtOffset(del.pos, del.pos + del.text.len) catch |err| {
                            log.warn("Redo: failed to re-apply delete at pos={d} len={d}: {}", .{ del.pos, del.text.len, err });
                        };
                    },
                }
            }

            s.cursor_row = txn.cursor_after.row;
            s.cursor_col = txn.cursor_after.col;
            s.preferred_col = null;
            s.modified = true;

            core.setStatusLiteral("Redo", 1500);
            try core.sendLspDocChanged();
            try core.sendUpdate();
        } else {
            core.setStatusLiteralLeveled(.info, "Nothing to redo", 1500);
            try core.sendUpdate();
        }
    }

    pub fn cmdEditCopy(core: anytype) anyerror!void {
        const text = try core.getSelectionText() orelse {
            core.setStatusLiteralLeveled(.warning, "Nothing selected to copy", 1500);
            try core.sendUpdate();
            return;
        };
        defer core.allocator.free(text);

        core.clipboard.clearRetainingCapacity();
        try core.clipboard.appendSlice(core.allocator, text);

        const lines = lineCountIn(text);
        if (lines == 1) {
            core.setStatus("Copied {d} char{s}", .{ text.len, if (text.len == 1) "" else "s" }, 2000);
        } else {
            core.setStatus("Copied {d} lines ({d} chars)", .{ lines, text.len }, 2000);
        }

        if (core.mode == .visual or core.mode == .visual_search) {
            core.state().selection_anchor = null;
            core.mode = .select;
        }

        try core.sendUpdate();
    }

    pub fn cmdEditCut(core: anytype) anyerror!void {
        if (core.rejectReadOnlyPresentationEdit()) return;
        const s = core.state();

        const text = try core.getSelectionText() orelse {
            core.setStatusLiteralLeveled(.warning, "Nothing selected to cut", 1500);
            try core.sendUpdate();
            return;
        };
        defer core.allocator.free(text);

        core.clipboard.clearRetainingCapacity();
        try core.clipboard.appendSlice(core.allocator, text);

        const lines = lineCountIn(text);
        if (lines == 1) {
            core.setStatus("Cut {d} char{s}", .{ text.len, if (text.len == 1) "" else "s" }, 2000);
        } else {
            core.setStatus("Cut {d} lines ({d} chars)", .{ lines, text.len }, 2000);
        }

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
        if (core.rejectReadOnlyPresentationEdit()) return;
        if (core.clipboard.items.len == 0) {
            core.setStatusLiteralLeveled(.warning, "Clipboard is empty", 1500);
            try core.sendUpdate();
            return;
        }

        const len = core.clipboard.items.len;
        const lines = lineCountIn(core.clipboard.items);

        try core.insertTextWithHistory(core.clipboard.items);

        if (lines == 1) {
            core.setStatus("Pasted {d} char{s}", .{ len, if (len == 1) "" else "s" }, 1500);
        } else {
            core.setStatus("Pasted {d} lines", .{lines}, 1500);
        }

        try core.sendLspDocChanged();
        try core.sendUpdate();
    }

    pub fn cmdEditDeleteLine(core: anytype) anyerror!void {
        if (core.rejectReadOnlyPresentationEdit()) return;
        const s = core.state();
        try s.deleteLine(s.cursor_row);
        const total = s.buffer.lineCount();
        if (s.cursor_row >= total and total > 0) {
            s.cursor_row = total - 1;
        }
        core.setStatusLiteral("Deleted line", 1500);
        try core.sendLspDocChanged();
        try core.sendUpdate();
    }

    pub fn cmdEditDuplicateLine(core: anytype) anyerror!void {
        if (core.rejectReadOnlyPresentationEdit()) return;
        const s = core.state();
        try s.duplicateLine(s.cursor_row);
        core.setStatusLiteral("Duplicated line", 1500);
        try core.sendLspDocChanged();
        try core.sendUpdate();
    }

    pub fn cmdEditMoveLineUp(core: anytype) anyerror!void {
        if (core.rejectReadOnlyPresentationEdit()) return;
        const s = core.state();
        if (s.cursor_row > 0) {
            try s.swapAdjacentLines(s.cursor_row, s.cursor_row - 1);
            s.cursor_row -= 1;
            core.setStatusLiteral("Moved line up", 1200);
            try core.sendLspDocChanged();
            try core.sendUpdate();
        } else {
            core.setStatusLiteralLeveled(.info, "Already at top", 1200);
            try core.sendUpdate();
        }
    }

    pub fn cmdEditMoveLineDown(core: anytype) anyerror!void {
        if (core.rejectReadOnlyPresentationEdit()) return;
        const s = core.state();
        const total_lines = s.buffer.lineCount();
        if (s.cursor_row + 1 < total_lines) {
            try s.swapAdjacentLines(s.cursor_row, s.cursor_row + 1);
            s.cursor_row += 1;
            core.setStatusLiteral("Moved line down", 1200);
            try core.sendLspDocChanged();
            try core.sendUpdate();
        } else {
            core.setStatusLiteralLeveled(.info, "Already at bottom", 1200);
            try core.sendUpdate();
        }
    }

    pub fn cmdEditJoinLines(core: anytype) anyerror!void {
        if (core.rejectReadOnlyPresentationEdit()) return;
        const s = core.state();
        try s.joinLines(s.cursor_row);
        core.setStatusLiteral("Joined line", 1200);
        try core.sendLspDocChanged();
        try core.sendUpdate();
    }

    pub fn cmdEditInsertDateTime(core: anytype) anyerror!void {
        if (core.rejectReadOnlyPresentationEdit()) return;
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

        core.setStatusLiteral("Inserted timestamp", 1500);
        try core.sendLspDocChanged();
        try core.sendUpdate();
    }
};

test "delete line command rejects read-only presentation buffers before mutating" {
    const EditorState = @import("../../core/state.zig").EditorState;
    const TestIo = @import("../../test_utils.zig").TestIo;

    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();

    var state_value = try EditorState.init(allocator, io_ctx.io(), "alpha\nbeta\n");
    defer state_value.deinit();

    const FakeCore = struct {
        state_ptr: *EditorState,
        rejected: bool = false,
        sent_lsp: bool = false,
        sent_update: bool = false,

        pub fn state(self: *@This()) *EditorState {
            return self.state_ptr;
        }

        pub fn rejectReadOnlyPresentationEdit(self: *@This()) bool {
            self.rejected = true;
            return true;
        }

        pub fn setStatusLiteral(_: *@This(), _: []const u8, _: u64) void {}

        pub fn sendLspDocChanged(self: *@This()) !void {
            self.sent_lsp = true;
        }

        pub fn sendUpdate(self: *@This()) !void {
            self.sent_update = true;
        }
    };

    var core = FakeCore{ .state_ptr = &state_value };
    try EditCommands.cmdEditDeleteLine(&core);

    const content = try state_value.buffer.toString(allocator);
    defer allocator.free(content);
    try std.testing.expect(core.rejected);
    try std.testing.expect(!core.sent_lsp);
    try std.testing.expect(!core.sent_update);
    try std.testing.expectEqualStrings("alpha\nbeta\n", content);
}
