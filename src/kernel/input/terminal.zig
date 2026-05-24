//! Input dispatch for `.terminal` mode — the integrated
//! shell-command terminal. History navigation, scrollback,
//! Ctrl+C cancellation, tab-completion.

const std = @import("std");
const vaxis = @import("vaxis");

const terminal_proc = @import("../terminal_proc.zig");

pub fn handle(core: anytype, key: vaxis.Key) !void {
    if (key.matches('c', .{ .ctrl = true })) {
        if (core.terminal_running) {
            if (core.terminal_service.cancelCurrentJob()) {
                try core.terminal_output.appendSlice(core.allocator, "\n^C\n");
                core.terminal_running = false;
            }
        }
        return;
    }

    if (key.matches(vaxis.Key.enter, .{})) {
        if (core.terminal_input.items.len > 0 and !core.terminal_running) {
            try terminal_proc.executeTerminalCommand(core);
        }
        return;
    }

    if (key.matches(vaxis.Key.up, .{})) {
        if (core.terminal_service.history_index == null and core.terminal_input.items.len > 0) {
            core.terminal_saved_input.clearRetainingCapacity();
            try core.terminal_saved_input.appendSlice(core.allocator, core.terminal_input.items);
        }

        if (core.terminal_service.historyPrevious()) |prev_cmd| {
            core.terminal_input.clearRetainingCapacity();
            try core.terminal_input.appendSlice(core.allocator, prev_cmd);
        }
        return;
    }

    if (key.matches(vaxis.Key.down, .{})) {
        if (core.terminal_service.historyNext()) |next_cmd| {
            core.terminal_input.clearRetainingCapacity();
            try core.terminal_input.appendSlice(core.allocator, next_cmd);
        } else {
            core.terminal_input.clearRetainingCapacity();
            if (core.terminal_saved_input.items.len > 0) {
                try core.terminal_input.appendSlice(core.allocator, core.terminal_saved_input.items);
            }
        }
        return;
    }

    if (key.matches(vaxis.Key.page_up, .{})) {
        if (core.terminal_scroll_offset >= 10) {
            core.terminal_scroll_offset -= 10;
        } else {
            core.terminal_scroll_offset = 0;
        }
        return;
    }

    if (key.matches(vaxis.Key.page_down, .{})) {
        var total_lines: usize = 0;
        for (core.terminal_output.items) |c| {
            if (c == '\n') total_lines += 1;
        }
        if (core.terminal_output.items.len > 0 and
            core.terminal_output.items[core.terminal_output.items.len - 1] != '\n')
        {
            total_lines += 1;
        }
        const visible_height = if (core.win_size.rows > 2) core.win_size.rows - 2 else 1;
        const max_offset = if (total_lines > visible_height) total_lines - visible_height else 0;
        core.terminal_scroll_offset = @min(core.terminal_scroll_offset + 10, max_offset);
        return;
    }

    if (key.matches(vaxis.Key.tab, .{})) {
        try terminal_proc.completeTerminalInput(core);
        return;
    }

    if (key.matches(vaxis.Key.backspace, .{})) {
        if (core.terminal_input.items.len > 0) {
            _ = core.terminal_input.pop();
            core.terminal_service.resetHistoryNavigation();
        }
        return;
    }

    if (key.text) |text| {
        try core.terminal_input.appendSlice(core.allocator, text);
        core.terminal_service.resetHistoryNavigation();
    }
}
