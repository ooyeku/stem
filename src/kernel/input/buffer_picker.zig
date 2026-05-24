//! Input dispatch for `.buffer_picker` mode. Numeric prefix
//! input (typed digit accumulator) is supported for quick
//! buffer-N selection — Enter without a digit confirms the
//! currently-highlighted picker entry instead.

const std = @import("std");
const vaxis = @import("vaxis");

pub fn handle(core: anytype, key: vaxis.Key) !bool {
    if (key.codepoint >= '0' and key.codepoint <= '9') {
        try core.buffer_picker_number_input.append(core.allocator, @intCast(key.codepoint));
        return true;
    }

    if (key.matches(vaxis.Key.backspace, .{})) {
        if (core.buffer_picker_number_input.items.len > 0) {
            _ = core.buffer_picker_number_input.pop();
            return true;
        }
        return false;
    }

    if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
        core.buffer_picker_number_input.clearRetainingCapacity();
        core.buffer_manager.pickerMoveUp();
        return true;
    }
    if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
        core.buffer_picker_number_input.clearRetainingCapacity();
        core.buffer_manager.pickerMoveDown();
        return true;
    }

    if (key.matches(vaxis.Key.enter, .{})) {
        if (core.buffer_picker_number_input.items.len > 0) {
            const num_str = core.buffer_picker_number_input.items;
            const buf_num = std.fmt.parseInt(usize, num_str, 10) catch 0;
            core.buffer_picker_number_input.clearRetainingCapacity();

            if (buf_num > 0 and buf_num <= core.buffer_manager.buffers.items.len) {
                core.buffer_manager.switchTo(buf_num - 1);
                core.notifyBufferSwitched();
                core.refreshSyntaxForCurrentBuffer();
                if (core.split_manager) |*sm| {
                    sm.setFocusedBuffer(core.buffer_manager.active_index);
                }
            }
        } else {
            core.buffer_manager.pickerSelect();
            core.notifyBufferSwitched();
            core.refreshSyntaxForCurrentBuffer();
            if (core.split_manager) |*sm| {
                sm.setFocusedBuffer(core.buffer_manager.active_index);
            }
        }
        core.mode = .select;
        return true;
    }

    return false;
}
