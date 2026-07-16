//! Input dispatch for `.view` mode — the read-only browse mode
//! you flip into for navigation without risking edits. Mirrors
//! the Select-mode leader-chord dispatch but without the
//! mutation-side bindings.

const std = @import("std");
const vaxis = @import("vaxis");

const Keys = @import("../../config/keys.zig").Keys;
const EditorState = @import("../../core/state.zig").EditorState;
const Help = @import("../../ui/help.zig");
const LeaderDispatch = @import("../leader_dispatch.zig").LeaderDispatch;
const LspCommands = @import("../commands/lsp_commands.zig").LspCommands;
const SplitCommands = @import("../commands/split_commands.zig").SplitCommands;
const SystemCommands = @import("../commands/system_commands.zig").SystemCommands;
const EditCommands = @import("../commands/edit_commands.zig").EditCommands;
const NavCommands = @import("../commands/nav_commands.zig").NavCommands;

pub fn handle(core: anytype, key: vaxis.Key) !bool {
    if (core.leader_pending) {
        // Refresh the chord-timeout timestamp on every
        // follow-up key — see the Select-mode handler for the
        // full rationale (vim-style `timeoutlen` semantics).
        core.leader_pending_set_ms = std.Io.Clock.real.now(core.io).toMilliseconds();

        // Double-Space no-op — see Select-mode handler for
        // the full rationale. Stops the user's reflexive
        // "tap again" from cancelling the chord.
        if (key.matches(Keys.leader, .{})) {
            core.setStatusLiteralLeveled(.info, "Space ; for command help", 1500);
            return true;
        }
        // Same preamble as Select-mode leader: Esc, which-key,
        // sub-chord dispatch, chord-prefix detection. View
        // mode is read-only so a couple of single-step bindings
        // (copy, paste, etc.) are omitted from the top-level
        // switch, but the chord groups behave identically.
        if (key.matches(vaxis.Key.escape, .{})) {
            core.leader_pending = false;
            core.leader_chord = null;
            core.leader_help_requested = false;
            return true;
        }
        if (key.codepoint == Keys.action_which_key or
            key.codepoint == Keys.action_which_key_alt or
            (key.codepoint == '/' and key.mods.shift))
        {
            core.leader_help_requested = !core.leader_help_requested;
            return true;
        }
        if (core.leader_chord) |prefix| {
            try LeaderDispatch.handle(core, prefix, key);
            core.leader_chord = null;
            core.leader_help_requested = false;
            return true;
        }
        if (key.codepoint == Keys.chord_lsp or
            key.codepoint == Keys.chord_git or
            key.codepoint == Keys.chord_window or
            key.codepoint == Keys.chord_toggle)
        {
            core.leader_chord = @intCast(key.codepoint);
            return true;
        }

        switch (key.codepoint) {
            Keys.action_save => try core.saveCurrentFile(),
            // `Space f` retired. `Space e` is the single
            // entry point for the file explorer; `f` is left
            // unbound (free for a future feature). Cmd/Ctrl+O
            // still works as the global "open" shortcut.
            Keys.action_buffer => {
                core.recordJumpFromCurrent();
                core.previous_mode = core.mode;
                core.mode = .buffer_picker;
                core.buffer_manager.pickerReset();
                core.buffer_picker_number_input.clearRetainingCapacity();
                core.leader_pending = false;
            },
            Keys.action_file_explorer => {
                try core.openFileExplorer();
                core.leader_pending = false;
            },
            Keys.action_quit => return error.UserQuit,
            Keys.action_close => LeaderDispatch.closeCurrentPaneOrBuffer(core),
            Keys.action_next => {
                core.recordJumpFromCurrent();
                core.buffer_manager.nextBuffer();
                core.refreshSyntaxForCurrentBuffer();
                if (core.split_manager) |*sm| sm.setFocusedBuffer(core.buffer_manager.active_index);
            },
            Keys.action_prev => {
                core.recordJumpFromCurrent();
                core.buffer_manager.prevBuffer();
                core.refreshSyntaxForCurrentBuffer();
                if (core.split_manager) |*sm| sm.setFocusedBuffer(core.buffer_manager.active_index);
            },
            Keys.action_help => {
                try core.openVirtualBuffer("[HELP]", Help.help_text);
                core.leader_pending = false;
            },
            Keys.action_palette, Keys.action_palette_alt => {
                core.previous_mode = core.mode;
                core.mode = .command_palette;
                core.command_palette_input.clearRetainingCapacity();
                try core.updateCommandSearch();
                core.leader_pending = false;
            },
            Keys.action_undo => try EditCommands.cmdEditUndo(core),
            Keys.action_redo => try EditCommands.cmdEditRedo(core),
            Keys.action_jobs => try SystemCommands.cmdJobList(core),
            Keys.action_copy => try EditCommands.cmdEditCopy(core),
            Keys.action_cut => try EditCommands.cmdEditCut(core),
            Keys.action_paste => try EditCommands.cmdEditPaste(core),

            Keys.action_code_action => try LspCommands.cmdLspCodeAction(core),
            Keys.action_center_view => {
                core.syncStateToPane();
                try NavCommands.cmdNavCenterView(core);
                core.syncPaneToState();
            },
            Keys.action_bookmarks => {
                try core.openBookmarksBuffer();
                core.leader_pending = false;
            },

            Keys.action_jump_back => try NavCommands.cmdJumpBack(core),
            Keys.action_jump_forward => try NavCommands.cmdJumpForward(core),

            Keys.action_split_horizontal => try SplitCommands.cmdSplitHorizontal(core),
            Keys.action_split_vertical => try SplitCommands.cmdSplitVertical(core),

            else => {
                core.leader_pending = false;
                core.leader_help_requested = false;
            },
        }
        return true;
    }

    if (key.matches(Keys.leader, .{})) {
        core.leader_pending = true;
        core.leader_pending_set_ms = std.Io.Clock.real.now(core.io).toMilliseconds();
        core.leader_help_requested = false;
        core.setStatusLiteralLeveled(.info, "Space ; for command help", 1500);
        return true;
    }

    if (key.matches(Keys.open.codepoint, Keys.open.mods)) {
        try core.openFileExplorer();
        return true;
    }
    if (key.matches(Keys.save.codepoint, Keys.save.mods)) {
        try core.saveCurrentFile();
        return true;
    }

    if (core.activeBufferIsPresentationReadOnly()) {
        if (handlePresentationViewportScroll(core, key)) return true;
    }

    const s = core.state();
    if (key.matches(vaxis.Key.left, .{}) or key.matches('h', .{})) {
        try s.moveCursorLeftGrapheme();
    } else if (key.matches(vaxis.Key.right, .{}) or key.matches('l', .{})) {
        try s.moveCursorRightGrapheme();
    } else if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
        s.moveCursorDown(1);
    } else if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
        s.moveCursorUp(1);
    } else if (key.matches(vaxis.Key.page_down, .{})) {
        s.moveCursorDown(20);
        core.scroll_in_progress = true;
        core.last_scroll_time = std.Io.Clock.real.now(core.io).toMilliseconds();
    } else if (key.matches(vaxis.Key.page_up, .{})) {
        s.moveCursorUp(20);
        core.scroll_in_progress = true;
        core.last_scroll_time = std.Io.Clock.real.now(core.io).toMilliseconds();
    } else if (key.matches(vaxis.Key.home, .{})) {
        s.moveCursorToLineStart();
    } else if (key.matches(vaxis.Key.end, .{})) {
        s.moveCursorToLineEnd();
    }
    return true;
}

fn handlePresentationViewportScroll(core: anytype, key: vaxis.Key) bool {
    const visible_rows = core.getFocusedPaneHeight();
    if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
        scrollViewportBy(core.state(), visible_rows, 1);
    } else if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
        scrollViewportBy(core.state(), visible_rows, -1);
    } else if (key.matches(vaxis.Key.page_down, .{})) {
        scrollViewportBy(core.state(), visible_rows, @intCast(visible_rows));
    } else if (key.matches(vaxis.Key.page_up, .{})) {
        scrollViewportBy(core.state(), visible_rows, -@as(isize, @intCast(visible_rows)));
    } else if (key.matches(vaxis.Key.home, .{})) {
        scrollViewportTo(core.state(), visible_rows, 0);
    } else if (key.matches(vaxis.Key.end, .{})) {
        const s = core.state();
        const line_count = s.buffer.lineCount();
        const max_scroll = maxViewportScroll(line_count, visible_rows);
        scrollViewportTo(s, visible_rows, max_scroll);
    } else {
        return false;
    }

    core.scroll_in_progress = true;
    core.last_scroll_time = std.Io.Clock.real.now(core.io).toMilliseconds();
    return true;
}

fn scrollViewportBy(state: *EditorState, visible_rows: usize, delta: isize) void {
    const line_count = state.buffer.lineCount();
    const max_scroll = maxViewportScroll(line_count, visible_rows);
    const current = state.scroll_offset;
    const next = if (delta >= 0)
        @min(current + @as(usize, @intCast(delta)), max_scroll)
    else
        current -| @as(usize, @intCast(-delta));

    scrollViewportTo(state, visible_rows, next);
}

fn scrollViewportTo(state: *EditorState, visible_rows: usize, offset: usize) void {
    const safe_visible_rows = @max(visible_rows, 1);
    const line_count = state.buffer.lineCount();
    const max_scroll = maxViewportScroll(line_count, safe_visible_rows);
    state.scroll_offset = @min(offset, max_scroll);

    const max_row = if (line_count == 0) 0 else line_count - 1;
    const viewport_last = @min(max_row, state.scroll_offset + safe_visible_rows - 1);
    if (state.cursor_row < state.scroll_offset) {
        state.cursor_row = state.scroll_offset;
    } else if (state.cursor_row > viewport_last) {
        state.cursor_row = viewport_last;
    }
    state.cursor_col = @min(state.cursor_col, state.getLineLength(state.cursor_row));
    state.preferred_col = null;
}

fn maxViewportScroll(line_count: usize, visible_rows: usize) usize {
    const safe_visible_rows = @max(visible_rows, 1);
    return if (line_count > safe_visible_rows) line_count - safe_visible_rows else 0;
}

test "view viewport scroll moves offset immediately and keeps cursor visible" {
    const TestIo = @import("../../test_utils.zig").TestIo;

    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();

    var state_value = try EditorState.init(allocator, io_ctx.io(),
        \\line 1
        \\line 2
        \\line 3
        \\line 4
        \\line 5
        \\line 6
        \\
    );
    defer state_value.deinit();

    scrollViewportBy(&state_value, 3, 1);

    try std.testing.expectEqual(@as(usize, 1), state_value.scroll_offset);
    try std.testing.expectEqual(@as(usize, 1), state_value.cursor_row);
}

test "view viewport scroll clamps at document edges" {
    const TestIo = @import("../../test_utils.zig").TestIo;

    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();

    var state_value = try EditorState.init(allocator, io_ctx.io(),
        \\line 1
        \\line 2
        \\line 3
        \\line 4
        \\line 5
        \\
    );
    defer state_value.deinit();

    scrollViewportBy(&state_value, 2, 99);
    try std.testing.expectEqual(@as(usize, 3), state_value.scroll_offset);
    try std.testing.expectEqual(@as(usize, 3), state_value.cursor_row);

    scrollViewportBy(&state_value, 2, -99);
    try std.testing.expectEqual(@as(usize, 0), state_value.scroll_offset);
    try std.testing.expectEqual(@as(usize, 1), state_value.cursor_row);
}
