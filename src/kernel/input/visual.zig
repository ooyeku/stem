//! Input dispatch for `.visual` mode — selection-extending
//! cursor motion plus the vim-style text-object / surround /
//! structural-AST chord families.
//!
//! Three chord state machines (text_object_state):
//!   - inside_pending  / around_pending → `i <c>` / `a <c>`
//!     extend the selection to the inside / around object.
//!   - surround_add_pending → `S <c>` wraps the selection with
//!     a matching pair.
//!
//! Numbered counts (vim-style: `3w` etc.) accumulate into
//! `nav_repeat_count` until a motion key consumes them.

const std = @import("std");
const vaxis = @import("vaxis");

const EditCommands = @import("../commands/edit_commands.zig").EditCommands;

pub fn handle(core: anytype, key: vaxis.Key) !bool {
    // Text-object chord: in visual mode, `i <c>` / `a <c>` extend
    // the selection to the inside/around of the named object.
    // Matches vim's standard visual-mode bindings.
    switch (core.text_object_state) {
        .inside_pending, .around_pending => {
            const around = core.text_object_state == .around_pending;
            core.text_object_state = .none;
            if (key.codepoint > 0 and key.codepoint < 0x80) {
                try core.selectTextObject(@intCast(key.codepoint), around);
                return true;
            }
        },
        else => {},
    }
    if (key.matches('i', .{})) {
        core.text_object_state = .inside_pending;
        return true;
    }
    if (key.matches('a', .{})) {
        core.text_object_state = .around_pending;
        return true;
    }

    // Surround-add chord: `S <c>` wraps the current selection
    // with the matching pair for <c>. Single delimiter (")` or
    // bracket-style pair (( → ( … )).
    if (core.text_object_state == .none and key.matches('S', .{ .shift = true })) {
        core.text_object_state = .surround_add_pending;
        return true;
    }
    // Multi-cursor: Ctrl+D in visual mode uses the selection as
    // the seed query for next-occurrence search.
    if (key.matches('d', .{ .ctrl = true })) {
        try core.addNextOccurrence();
        return true;
    }
    if (core.text_object_state == .surround_add_pending) {
        core.text_object_state = .none;
        if (key.codepoint > 0 and key.codepoint < 0x80) {
            try core.addSurround(@intCast(key.codepoint));
            return true;
        }
    }

    if (key.matches(vaxis.Key.delete, .{}) or key.matches(vaxis.Key.backspace, .{})) {
        const s = core.state();

        var start_row: usize = s.cursor_row;
        var start_col: usize = s.cursor_col;
        var end_row: usize = s.cursor_row;
        var end_col: usize = s.cursor_col;

        if (s.selection_anchor) |anchor| {
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
        }

        const start_off = s.getOffsetFor(start_row, start_col);
        const end_off = s.getOffsetFor(end_row, end_col);
        try s.deleteRange(start_off, end_off);

        s.selection_anchor = null;
        core.mode = .select;
        // Send LSP didChange immediately, not via the debouncer:
        // a hover / goto-def / signature-help fired right after
        // the delete would otherwise see stale server-side text
        // for up to `lsp_debounce_ms`. The tree-sitter parse
        // inside `sendLspDocChanged` is already async (via
        // `submitParse`), so this is cheap.
        try core.sendLspDocChanged();
        try core.sendUpdate();
        return true;
    }

    if (key.matches('/', .{})) {
        try core.enterIncrementalSearch(.visual, .forward);
        return true;
    }
    if (key.matches('?', .{ .shift = true })) {
        try core.enterIncrementalSearch(.visual, .backward);
        return true;
    }

    // Structural expand / shrink. `+` grows the selection to the
    // enclosing AST node; `-` walks back to the first named child.
    if (key.matches('+', .{}) or key.matches('=', .{})) {
        try core.adjustSelectionStructural(.expand);
        return true;
    }
    if (key.matches('-', .{})) {
        try core.adjustSelectionStructural(.shrink);
        return true;
    }

    if (key.matches('y', .{})) {
        try EditCommands.cmdEditCopy(core);
        return true;
    }

    if (key.matches('x', .{})) {
        try EditCommands.cmdEditCut(core);
        return true;
    }

    if (key.matches(vaxis.Key.escape, .{}) or key.matches('v', .{})) {
        core.mode = .select;
        core.state().selection_anchor = null;
        core.nav_repeat_count = 0;
        return true;
    }

    if (key.codepoint >= '0' and key.codepoint <= '9' and !key.mods.alt and !key.mods.ctrl and !key.mods.super) {
        const digit = key.codepoint - '0';
        if (digit == 0 and core.nav_repeat_count == 0) {
            const s = core.state();
            s.cursor_col = 0;
            return true;
        }
        core.nav_repeat_count = core.nav_repeat_count * 10 + digit;
        return true;
    }

    const count = if (core.nav_repeat_count > 0) core.nav_repeat_count else 1;
    core.nav_repeat_count = 0;

    const s = core.state();
    if (key.matches(vaxis.Key.left, .{}) or key.matches('h', .{})) {
        var i: usize = 0;
        while (i < count) : (i += 1) try s.moveCursorLeftGrapheme();
        return true;
    }
    if (key.matches(vaxis.Key.right, .{}) or key.matches('l', .{})) {
        var i: usize = 0;
        while (i < count) : (i += 1) try s.moveCursorRightGrapheme();
        return true;
    }
    if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
        s.moveCursorDown(count);
        return true;
    }
    if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
        s.moveCursorUp(count);
        return true;
    }
    if (key.matches(vaxis.Key.page_down, .{})) {
        s.moveCursorDown(20 * count);
        core.scroll_in_progress = true;
        core.last_scroll_time = std.Io.Clock.real.now(core.io).toMilliseconds();
        return true;
    }
    if (key.matches(vaxis.Key.page_up, .{})) {
        s.moveCursorUp(20 * count);
        core.scroll_in_progress = true;
        core.last_scroll_time = std.Io.Clock.real.now(core.io).toMilliseconds();
        return true;
    }
    if (key.matches(vaxis.Key.home, .{})) {
        s.moveCursorToLineStart();
        return true;
    }
    if (key.matches(vaxis.Key.end, .{})) {
        s.moveCursorToLineEnd();
        return true;
    }

    // Word + paragraph motions extend the selection.
    if (key.matches('w', .{})) {
        var i: usize = 0;
        while (i < count) : (i += 1) try s.moveCursorNextWord();
        return true;
    }
    if (key.matches('b', .{})) {
        var i: usize = 0;
        while (i < count) : (i += 1) try s.moveCursorPrevWord();
        return true;
    }
    if (key.matches('e', .{})) {
        var i: usize = 0;
        while (i < count) : (i += 1) try s.moveCursorNextWordEnd();
        return true;
    }
    if (key.matches('W', .{ .shift = true })) {
        var i: usize = 0;
        while (i < count) : (i += 1) try s.moveCursorNextBigWord();
        return true;
    }
    if (key.matches('B', .{ .shift = true })) {
        var i: usize = 0;
        while (i < count) : (i += 1) try s.moveCursorPrevBigWord();
        return true;
    }
    if (key.matches('}', .{ .shift = true })) {
        var i: usize = 0;
        while (i < count) : (i += 1) s.moveCursorNextParagraph();
        return true;
    }
    if (key.matches('{', .{ .shift = true })) {
        var i: usize = 0;
        while (i < count) : (i += 1) s.moveCursorPrevParagraph();
        return true;
    }

    return false;
}
