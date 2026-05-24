//! Input dispatch for `.file_picker` mode (the legacy fuzzy
//! picker; still reachable via the palette but no longer the
//! primary "open file" UI — that's the file explorer now).

const std = @import("std");
const vaxis = @import("vaxis");

pub fn handle(core: anytype, key: vaxis.Key) !bool {
    if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
        core.file_manager.moveUp();
        return true;
    }
    if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
        core.file_manager.moveDown();
        return true;
    }
    if (key.matches(vaxis.Key.enter, .{ .shift = true }) or
        key.matches(vaxis.Key.enter, .{ .alt = true }) or
        key.matches('o', .{ .ctrl = true }))
    {
        const selected = core.file_manager.getSelectedEntry();
        if (selected) |entry| {
            if (entry.is_dir) {
                const dir_path = try std.fs.path.join(core.allocator, &.{ core.file_manager.cwd, entry.name });
                defer core.allocator.free(dir_path);
                try core.openAllFilesInDirectory(dir_path);
                core.mode = .select;
                return true;
            }
        }
    }
    if (key.matches(vaxis.Key.enter, .{})) {
        if (try core.file_manager.enter()) |file_path| {
            defer core.allocator.free(file_path);
            try core.openFileByPath(file_path);
            core.mode = .select;
        }
        return true;
    }
    if (key.matches(vaxis.Key.backspace, .{})) {
        try core.file_manager.goParent();
        return true;
    }
    return false;
}
