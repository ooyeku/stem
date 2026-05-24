//! Input dispatch for `.visual_search` mode — the incremental
//! in-buffer search prompt (`/` or `?`). Every keystroke updates
//! decorations and jumps the cursor to the closest match.

const std = @import("std");
const vaxis = @import("vaxis");

const log = std.log.scoped(.VisualSearch);

pub fn handle(core: anytype, key: vaxis.Key) !bool {
    if (key.matches(vaxis.Key.enter, .{})) {
        if (core.search_input.items.len > 0) {
            core.last_search_query.clearRetainingCapacity();
            core.last_search_query.appendSlice(core.allocator, core.search_input.items) catch |err| {
                log.warn("Failed to persist last search query: {}", .{err});
            };
            // Cursor is already on the live-previewed match; just
            // exit the prompt and keep it where it is.
            core.mode = core.previous_mode;
            if (core.mode == .select) {
                const s = core.state();
                s.selection_anchor = null;
            }
            core.search_input.clearRetainingCapacity();
        } else {
            core.mode = core.previous_mode;
            core.decoration_manager.removeBySource("search");
        }
        return true;
    } else if (key.matches(vaxis.Key.escape, .{})) {
        // Revert cursor to its pre-search location so a cancelled
        // search doesn't leave the user stranded mid-preview.
        const s = core.state();
        s.cursor_row = core.search_origin_row;
        s.cursor_col = core.search_origin_col;
        s.preferred_col = null;
        core.mode = core.previous_mode;
        core.search_input.clearRetainingCapacity();
        core.decoration_manager.removeBySource("search");
        core.search_match_count = 0;
        core.search_match_index = 0;
        return true;
    } else if (key.matches(vaxis.Key.backspace, .{})) {
        if (core.search_input.items.len > 0) {
            _ = core.search_input.pop();
            try core.updateSearchDecorations();
            core.jumpToIncrementalMatch();
            return true;
        }
    } else if (key.text) |text| {
        try core.search_input.appendSlice(core.allocator, text);
        try core.updateSearchDecorations();
        core.jumpToIncrementalMatch();
        return true;
    }
    return false;
}
