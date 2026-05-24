//! Input dispatch for `.symbol_picker` mode — document-level
//! symbol fuzzy picker (Space l s). Updates a query buffer on
//! every keystroke; up/down moves the highlight; Enter jumps to
//! the symbol's line.

const std = @import("std");
const vaxis = @import("vaxis");

pub fn handle(core: anytype, key: vaxis.Key) !bool {
    if (key.matches(vaxis.Key.up, .{}) or key.matches('p', .{ .ctrl = true })) {
        if (core.symbol_picker_selected > 0) {
            core.symbol_picker_selected -= 1;
        }
        return true;
    }
    if (key.matches(vaxis.Key.down, .{}) or key.matches('n', .{ .ctrl = true })) {
        if (core.symbol_picker_results.items.len > 0 and core.symbol_picker_selected < core.symbol_picker_results.items.len - 1) {
            core.symbol_picker_selected += 1;
        }
        return true;
    }
    if (key.matches(vaxis.Key.enter, .{})) {
        if (core.symbol_picker_results.items.len > 0 and core.symbol_picker_selected < core.symbol_picker_results.items.len) {
            const sym = core.symbol_picker_results.items[core.symbol_picker_selected];
            const s = core.state();
            s.cursor_row = sym.line;
            s.cursor_col = 0;
        }
        core.mode = core.previous_mode;
        core.symbol_picker_query.clearRetainingCapacity();
        return true;
    }
    if (key.matches(vaxis.Key.backspace, .{})) {
        if (core.symbol_picker_query.items.len > 0) {
            _ = core.symbol_picker_query.pop();
            try core.updateSymbolSearch();
            return true;
        }
    }
    if (key.text) |text| {
        try core.symbol_picker_query.appendSlice(core.allocator, text);
        try core.updateSymbolSearch();
        return true;
    }
    return false;
}
