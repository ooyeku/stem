//! Input dispatch for `.workspace_symbol_picker` mode — Space l
//! S. Async picker: query keystrokes trigger debounced
//! `workspace/symbol` LSP requests; selection jumps across
//! files, recording a jump-list breadcrumb first.

const std = @import("std");
const vaxis = @import("vaxis");

const log = std.log.scoped(.WorkspaceSymbol);

pub fn handle(core: anytype, key: vaxis.Key) !bool {
    if (key.matches(vaxis.Key.up, .{}) or key.matches('p', .{ .ctrl = true })) {
        if (core.workspace_symbol_selected > 0) core.workspace_symbol_selected -= 1;
        return true;
    }
    if (key.matches(vaxis.Key.down, .{}) or key.matches('n', .{ .ctrl = true })) {
        if (core.workspace_symbol_results.items.len > 0 and
            core.workspace_symbol_selected + 1 < core.workspace_symbol_results.items.len)
        {
            core.workspace_symbol_selected += 1;
        }
        return true;
    }
    if (key.matches(vaxis.Key.enter, .{})) {
        if (core.workspace_symbol_selected < core.workspace_symbol_results.items.len) {
            const sym = core.workspace_symbol_results.items[core.workspace_symbol_selected];
            // Record where we came from so Space, can take the
            // user straight back.
            const s = core.state();
            if (s.file_path) |path| {
                core.jump_list.recordJump(path, s.cursor_row, s.cursor_col) catch |err| {
                    log.debug("recordJump failed for {s}: {s}", .{ path, @errorName(err) });
                };
            }
            _ = core.buffer_manager.openFile(sym.file_path) catch |err| {
                log.warn("Open file from workspace symbol failed: {}", .{err});
                core.mode = core.previous_mode;
                return true;
            };
            const new_state = core.state();
            new_state.cursor_row = sym.line;
            new_state.cursor_col = sym.col;
            new_state.preferred_col = null;
            // Centre the line so the symbol isn't pinned to the top edge.
            const visible_rows: usize = if (core.win_size.rows > 2) core.win_size.rows - 2 else 1;
            const half = visible_rows / 2;
            new_state.scroll_offset = if (new_state.cursor_row >= half) new_state.cursor_row - half else 0;
        }
        core.mode = core.previous_mode;
        core.workspace_symbol_query.clearRetainingCapacity();
        return true;
    }
    if (key.matches(vaxis.Key.backspace, .{})) {
        if (core.workspace_symbol_query.items.len > 0) {
            _ = core.workspace_symbol_query.pop();
            try core.dispatchWorkspaceSymbolQuery();
        }
        return true;
    }
    if (key.text) |text| {
        try core.workspace_symbol_query.appendSlice(core.allocator, text);
        try core.dispatchWorkspaceSymbolQuery();
        return true;
    }
    return false;
}
