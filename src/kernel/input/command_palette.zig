//! Input dispatch for `.command_palette` mode — Space f /
//! Space :. Standard fuzzy picker shape (up/down/enter/text).
//! Errors from the executed command are caught at the palette
//! boundary so a misbehaving plugin can't take the editor down.

const std = @import("std");
const vaxis = @import("vaxis");

const log = std.log.scoped(.CommandPalette);

pub fn handle(core: anytype, key: vaxis.Key) !bool {
    if (key.matches(vaxis.Key.up, .{}) or key.matches('p', .{ .ctrl = true })) {
        if (core.command_palette_selected > 0) {
            core.command_palette_selected -= 1;
        }
        return true;
    }
    if (key.matches(vaxis.Key.down, .{}) or key.matches('n', .{ .ctrl = true })) {
        if (core.command_palette_results.items.len > 0 and core.command_palette_selected < core.command_palette_results.items.len - 1) {
            core.command_palette_selected += 1;
        }
        return true;
    }
    if (key.matches(vaxis.Key.enter, .{})) {
        if (core.command_palette_results.items.len > 0) {
            const cmd = core.command_palette_results.items[core.command_palette_selected];

            core.mode = core.previous_mode;
            core.command_palette_input.clearRetainingCapacity();

            core.command_history.record(cmd.id) catch |err| {
                log.warn("failed to record command history for '{s}': {s}", .{ cmd.id, @errorName(err) });
            };

            cmd.execute(core, cmd.context) catch |err| {
                log.err("command '{s}' failed: {s}", .{ cmd.id, @errorName(err) });
            };
        }
        return true;
    }
    if (key.matches(vaxis.Key.backspace, .{})) {
        if (core.command_palette_input.items.len > 0) {
            _ = core.command_palette_input.pop();
            try core.updateCommandSearch();
            return true;
        }
    }
    if (key.text) |text| {
        try core.command_palette_input.appendSlice(core.allocator, text);
        try core.updateCommandSearch();
        return true;
    }
    return false;
}
