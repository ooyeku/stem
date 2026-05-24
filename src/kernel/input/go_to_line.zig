//! Input dispatch for `.go_to_line` mode — the modal prompt
//! after Space-typed-line-number commands. Accumulates digits
//! into `go_to_line_input` and jumps the cursor on Enter.

const std = @import("std");
const vaxis = @import("vaxis");

pub fn handle(core: anytype, key: vaxis.Key) !bool {
    if (key.matches(vaxis.Key.enter, .{})) {
        if (core.go_to_line_input.items.len > 0) {
            const line_str = core.go_to_line_input.items;
            const line_num = std.fmt.parseInt(usize, line_str, 10) catch {
                core.mode = core.previous_mode;
                core.go_to_line_input.clearRetainingCapacity();
                return true;
            };

            const s = core.state();
            const total_lines = s.buffer.lineCount();

            if (line_num > 0) {
                s.cursor_row = @min(line_num - 1, if (total_lines > 0) total_lines - 1 else 0);
            } else {
                s.cursor_row = 0;
            }
            s.cursor_col = 0;
            core.mode = core.previous_mode;
            core.go_to_line_input.clearRetainingCapacity();
        }
        return true;
    } else if (key.matches(vaxis.Key.backspace, .{})) {
        if (core.go_to_line_input.items.len > 0) {
            _ = core.go_to_line_input.pop();
            return true;
        }
    } else if (key.text) |text| {
        try core.go_to_line_input.appendSlice(core.allocator, text);
        return true;
    }
    return false;
}
