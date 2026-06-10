//! Input dispatch for `.insert` mode — typing, deletion, and
//! the completion popup. Routes printable text through
//! `auto_pair` (skip-balanced-close, wrap-selection,
//! smart-backspace), fires LSP completion on `.`/`@`, opens /
//! updates signature help on `(`/`,`/`)`, and queues an LSP
//! didChange via `markLspDirty` so the debounced sync picks
//! the edit up shortly after the keystroke.
//!
//! Completion-popup interception happens up front: when the
//! popup is showing, Up/Down/Tab/Enter/Esc are consumed by the
//! popup before the normal editing path runs.

const std = @import("std");
const vaxis = @import("vaxis");

const auto_pair = @import("../../core/auto_pair.zig");
const Keys = @import("../../config/keys.zig").Keys;

const log = std.log.scoped(.Insert);

pub fn handle(core: anytype, key: vaxis.Key) !bool {
    if (core.completion_active) {
        if (key.matches(vaxis.Key.up, .{})) {
            if (core.completion_selected > 0) core.completion_selected -= 1;
            return true;
        }
        if (key.matches(vaxis.Key.down, .{})) {
            if (core.filtered_completion_items.items.len > 0) {
                if (core.completion_selected < core.filtered_completion_items.items.len - 1) {
                    core.completion_selected += 1;
                }
            }
            return true;
        }
        if ((key.matches(vaxis.Key.tab, .{}) or key.matches(vaxis.Key.enter, .{})) and core.filtered_completion_items.items.len > 0) {
            try core.confirmCompletion();
            return true;
        }
        if (key.matches(vaxis.Key.escape, .{})) {
            core.dismissCompletion();
            return true;
        }
    }

    if (key.matches(Keys.open.codepoint, Keys.open.mods)) {
        try core.openFileExplorer();
        return true;
    }
    if (key.matches(Keys.save.codepoint, Keys.save.mods)) {
        try core.saveCurrentFile();
        return true;
    }

    const s = core.state();
    if (key.matches(vaxis.Key.left, .{})) {
        try s.moveCursorLeftGrapheme();
    } else if (key.matches(vaxis.Key.right, .{})) {
        try s.moveCursorRightGrapheme();
    } else if (key.matches(vaxis.Key.down, .{})) {
        s.moveCursorDown(1);
    } else if (key.matches(vaxis.Key.up, .{})) {
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
    } else if (key.matches(vaxis.Key.backspace, .{})) {
        const config = auto_pair.AutoPairConfig{
            // Disable auto-pairs in large-file mode so backspace stays
            // a pure 1-char delete (and we don't scan around the cursor
            // for matching brackets on every keystroke in a huge file).
            .enabled = core.storage.config.editor.auto_pairs and !core.activeBufferIsLarge(),
            .smart_deletion = true,
        };

        if (config.enabled and config.smart_deletion) {
            const deleted_pair = try core.smartAutoPairBackspaceWithHistory();
            if (!deleted_pair) {
                try core.backspaceCharWithHistory();
            }
        } else {
            try core.backspaceCharWithHistory();
        }
        try core.updateCompletionFilter();
        core.markLspDirty();
    } else if (key.matches(vaxis.Key.delete, .{})) {
        try core.deleteCharWithHistory();
        try core.updateCompletionFilter();
        core.markLspDirty();
    } else if (key.matches(vaxis.Key.enter, .{})) {
        try core.insertNewlineWithHistory();
        core.markLspDirty();
    } else if (key.matches(vaxis.Key.tab, .{})) {
        try core.insertTabWithHistory(core.storage.config.editor.tab_size);
        core.markLspDirty();
    } else if (key.text) |text| {
        if (text.len == 1) {
            const char = text[0];

            const config = auto_pair.AutoPairConfig{
                .enabled = core.storage.config.editor.auto_pairs and !core.activeBufferIsLarge(),
                .wrap_selection = true,
                .smart_deletion = true,
                .context_aware = false,
            };

            const result = try core.autoPairCharWithHistory(char, config);

            switch (result) {
                .wrapped => {},
                .skipped => {},
                .inserted => {
                    if (config.enabled and auto_pair.isOpeningChar(char) != null) {} else {
                        try core.insertCharWithHistory(char);
                    }
                },
            }

            if (char == '.' or char == '@') {
                try core.triggerCompletion();
            }

            // Signature help: `(` opens, `,` re-fires to update the
            // active-parameter index, `)` dismisses. Cheap fire-and-
            // forget — the tick handler drains the response.
            if (char == '(' or char == ',') {
                core.triggerSignatureHelp() catch |err| {
                    log.debug("triggerSignatureHelp failed: {s}", .{@errorName(err)});
                };
            } else if (char == ')') {
                core.dismissSignatureHelp();
            }

            try core.updateCompletionFilter();
            core.markLspDirty();
        }
    }
    return true;
}
