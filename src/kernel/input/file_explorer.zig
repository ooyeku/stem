//! Input dispatch for `.file_explorer` mode — the tree-view
//! file opener (Space e). Vim-style navigation (j/k/g/G, h/l
//! to collapse/expand), Enter to open, H to toggle hidden.

const std = @import("std");
const vaxis = @import("vaxis");

pub fn handle(core: anytype, key: vaxis.Key) !bool {
    const fx = if (core.file_explorer) |*v| v else return false;

    // Esc dismisses the explorer back to whatever mode opened it.
    if (key.matches(vaxis.Key.escape, .{})) {
        core.mode = core.previous_mode;
        return true;
    }
    if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
        fx.moveUp();
        return true;
    }
    if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
        fx.moveDown();
        return true;
    }
    if (key.matches('g', .{})) {
        fx.moveTop();
        return true;
    }
    if (key.matches('G', .{ .shift = true })) {
        fx.moveBottom();
        return true;
    }
    if (key.matches(vaxis.Key.right, .{}) or key.matches('l', .{})) {
        _ = try fx.expand();
        return true;
    }
    if (key.matches(vaxis.Key.left, .{}) or key.matches('h', .{})) {
        _ = try fx.collapseOrAscend();
        return true;
    }
    if (key.matches('H', .{ .shift = true })) {
        try fx.toggleHidden();
        return true;
    }
    if (key.matches('r', .{ .ctrl = true })) {
        try fx.rebuild();
        return true;
    }
    if (key.matches(vaxis.Key.enter, .{}) or key.matches(vaxis.Key.space, .{})) {
        if (try fx.activate()) |opened| {
            defer core.allocator.free(opened);
            try core.openFileByPath(opened);
            core.mode = .select;
        }
        return true;
    }
    return false;
}
