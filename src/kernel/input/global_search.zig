//! Input dispatch for `.global_search` mode — the ripgrep-style
//! cross-project find/replace panel.
//!
//! Two field foci toggled by Tab: a query field that re-runs the
//! search on every change, and a replace field that just stores
//! text until the user kicks off the replace-confirmation walk
//! with Ctrl+R. During the walk, y/n/A/q are intercepted before
//! the normal text path so they don't get typed into either
//! field.

const std = @import("std");
const vaxis = @import("vaxis");

pub fn handle(core: anytype, key: vaxis.Key) !bool {
    // Replace-confirmation flow: intercept y/n/A/q before the
    // normal input path so they don't get typed into the query
    // buffer. Esc bails out cleanly.
    if (core.global_search_replace_active) {
        if (key.matches(vaxis.Key.escape, .{}) or key.matches('q', .{})) {
            try core.finishReplaceConfirm(false);
            return true;
        }
        if (key.matches('y', .{})) {
            try core.replaceConfirmStep(.replace);
            return true;
        }
        if (key.matches('n', .{})) {
            try core.replaceConfirmStep(.skip);
            return true;
        }
        if (key.matches('A', .{ .shift = true })) {
            core.global_search_replace_apply_all = true;
            try core.replaceConfirmStep(.replace);
            return true;
        }
        // Swallow other keys so they don't accidentally edit fields.
        return true;
    }

    // Ctrl+R from global_search starts the replace-confirmation walk.
    if (key.matches('r', .{ .ctrl = true })) {
        try core.startReplaceConfirm();
        return true;
    }

    if (key.matches(vaxis.Key.tab, .{})) {
        core.global_search_focus_replace = !core.global_search_focus_replace;
        return true;
    }

    if (key.matches(vaxis.Key.enter, .{})) {
        if (core.global_search_results.items.len > 0) {
            const file_idx = core.global_search_selected_file;
            if (file_idx < core.global_search_results.items.len) {
                const group = core.global_search_results.items[file_idx];
                const match_idx = core.global_search_selected_match;
                if (match_idx < group.matches.len) {
                    const match = group.matches[match_idx];
                    const full_path = try std.Io.Dir.cwd().realPathFileAlloc(core.io, group.file_path, core.allocator);
                    defer core.allocator.free(full_path);
                    try core.openFileAtLine(full_path, match.line_num);
                    core.mode = .select;
                    return true;
                }
            }
        }
        return true;
    }

    if (key.matches(vaxis.Key.escape, .{})) {
        core.mode = core.previous_mode;
        return true;
    }

    if (key.matches(vaxis.Key.backspace, .{})) {
        if (core.global_search_focus_replace) {
            if (core.global_search_replace.items.len > 0) {
                _ = core.global_search_replace.pop();
            }
        } else {
            if (core.global_search_query.items.len > 0) {
                _ = core.global_search_query.pop();
                try core.performGlobalSearch();
            }
        }
        return true;
    }

    if (key.text) |text| {
        if (core.global_search_focus_replace) {
            try core.global_search_replace.appendSlice(core.allocator, text);
        } else {
            try core.global_search_query.appendSlice(core.allocator, text);
            try core.performGlobalSearch();
        }
        return true;
    }

    if (key.matches(vaxis.Key.up, .{})) {
        if (core.global_search_results.items.len > 0) {
            if (core.global_search_selected_file >= core.global_search_results.items.len) {
                core.global_search_selected_file = core.global_search_results.items.len - 1;
            }

            if (core.global_search_selected_match > 0) {
                core.global_search_selected_match -= 1;
            } else if (core.global_search_selected_file > 0) {
                core.global_search_selected_file -= 1;
                const prev_group = core.global_search_results.items[core.global_search_selected_file];
                if (prev_group.matches.len > 0) {
                    core.global_search_selected_match = prev_group.matches.len - 1;
                } else {
                    core.global_search_selected_match = 0;
                }
            }
        }
        return true;
    }

    if (key.matches(vaxis.Key.down, .{})) {
        if (core.global_search_results.items.len > 0) {
            if (core.global_search_selected_file >= core.global_search_results.items.len) {
                core.global_search_selected_file = core.global_search_results.items.len - 1;
                core.global_search_selected_match = 0;
                return true;
            }

            const current_group = core.global_search_results.items[core.global_search_selected_file];
            if (current_group.matches.len > 0 and core.global_search_selected_match + 1 < current_group.matches.len) {
                core.global_search_selected_match += 1;
            } else if (core.global_search_selected_file + 1 < core.global_search_results.items.len) {
                core.global_search_selected_file += 1;
                core.global_search_selected_match = 0;
            }
        }
        return true;
    }

    return false;
}
