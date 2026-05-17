//! Terminal-process subsystem for `stem`'s integrated `:` terminal pane.
//! Functions here take `core: anytype` so they can stay decoupled from the
//! Core struct while still reading/writing its terminal_* fields.
//!
//! Extracted from `kernel/core.zig` to make the terminal logic discoverable
//! as a unit. Callers are in `kernel/core.zig`'s input/render paths.

const std = @import("std");

pub fn executeTerminalCommand(core: anytype) !void {
    const command = core.terminal_input.items;
    if (command.len == 0) return;
    if (core.terminal_running) return;

    if (core.terminal_cwd == null) {
        core.terminal_cwd = try core.allocator.dupe(u8, core.file_manager.cwd);
    }
    const cwd = core.terminal_cwd.?;

    try core.terminal_service.addToHistory(command);

    core.terminal_output.clearRetainingCapacity();
    core.terminal_scroll_offset = 0;

    try core.terminal_output.appendSlice(core.allocator, "\x1b[1;34m[");
    try core.terminal_output.appendSlice(core.allocator, cwd);
    try core.terminal_output.appendSlice(core.allocator, "]\x1b[0m $ ");
    try core.terminal_output.appendSlice(core.allocator, command);
    try core.terminal_output.appendSlice(core.allocator, "\n");

    scrollToTerminalBottom(core);

    const trimmed = std.mem.trim(u8, command, " \t");
    if (std.mem.startsWith(u8, trimmed, "cd ") or std.mem.eql(u8, trimmed, "cd")) {
        try handleCdCommand(core, trimmed);
        core.terminal_input.clearRetainingCapacity();
        return;
    }

    const inbox = core.core_inbox orelse {
        const output = core.terminal_service.runSync(command, cwd) catch |err| {
            const err_msg = std.fmt.allocPrint(core.allocator, "Error: {}\n", .{err}) catch return;
            defer core.allocator.free(err_msg);
            try core.terminal_output.appendSlice(core.allocator, err_msg);
            core.terminal_input.clearRetainingCapacity();
            return;
        };
        defer core.allocator.free(output);
        try core.terminal_output.appendSlice(core.allocator, output);
        core.terminal_input.clearRetainingCapacity();
        return;
    };

    core.terminal_running = true;
    _ = core.terminal_service.runAsync(command, cwd, inbox) catch |err| {
        const err_msg = std.fmt.allocPrint(core.allocator, "Error starting command: {}\n", .{err}) catch return;
        defer core.allocator.free(err_msg);
        try core.terminal_output.appendSlice(core.allocator, err_msg);
        core.terminal_running = false;
    };

    core.terminal_input.clearRetainingCapacity();
    core.terminal_saved_input.clearRetainingCapacity();
}

pub fn handleCdCommand(core: anytype, command: []const u8) !void {
    const cwd = core.terminal_cwd.?;

    var target: []const u8 = undefined;
    if (std.mem.eql(u8, command, "cd")) {
        target = "";
    } else {
        target = std.mem.trim(u8, command[3..], " \t\"'");
    }

    var new_path: []const u8 = undefined;
    var needs_free = false;

    const env: std.process.Environ = .{ .block = core.environ_block };
    const home_env: ?[]const u8 = blk: {
        if (@import("builtin").os.tag == .windows) {
            if (env.getPosix("USERPROFILE")) |p| break :blk p;
            if (env.getPosix("HOME")) |p| break :blk p;
            break :blk null;
        }
        if (env.getPosix("HOME")) |p| break :blk p;
        break :blk null;
    };

    if (target.len == 0 or std.mem.eql(u8, target, "~")) {
        new_path = (home_env orelse (if (@import("builtin").os.tag == .windows) "C:\\" else "/"));
    } else if (std.mem.startsWith(u8, target, "~/")) {
        const home = (home_env orelse (if (@import("builtin").os.tag == .windows) "C:\\" else "/"));
        new_path = std.fs.path.join(core.allocator, &.{ home, target[2..] }) catch {
            try core.terminal_output.appendSlice(core.allocator, "cd: failed to resolve path\n");
            return;
        };
        needs_free = true;
    } else if (std.mem.eql(u8, target, "-")) {
        if (core.terminal_old_cwd) |old| {
            new_path = old;
        } else {
            try core.terminal_output.appendSlice(core.allocator, "cd: OLDPWD not set\n");
            return;
        }
    } else if (std.fs.path.isAbsolute(target)) {
        new_path = target;
    } else {
        new_path = std.fs.path.join(core.allocator, &.{ cwd, target }) catch {
            try core.terminal_output.appendSlice(core.allocator, "cd: failed to resolve path\n");
            return;
        };
        needs_free = true;
    }
    defer if (needs_free) core.allocator.free(new_path);

    var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_path_len = std.Io.Dir.cwd().realPathFile(core.io, new_path, &real_path_buf) catch {
        try core.terminal_output.appendSlice(core.allocator, "cd: ");
        try core.terminal_output.appendSlice(core.allocator, target);
        try core.terminal_output.appendSlice(core.allocator, ": No such file or directory\n");
        return;
    };
    const real_path = real_path_buf[0..real_path_len];

    var dir = std.Io.Dir.cwd().openDir(core.io, real_path, .{}) catch {
        try core.terminal_output.appendSlice(core.allocator, "cd: ");
        try core.terminal_output.appendSlice(core.allocator, target);
        try core.terminal_output.appendSlice(core.allocator, ": Not a directory\n");
        return;
    };
    dir.close(core.io);

    if (core.terminal_cwd) |old| {
        if (core.terminal_old_cwd) |prev| core.allocator.free(prev);
        core.terminal_old_cwd = old;
    }
    core.terminal_cwd = try core.allocator.dupe(u8, real_path);
}

pub fn isTerminalAtBottom(core: anytype) bool {
    var total_lines: usize = 0;
    for (core.terminal_output.items) |c| {
        if (c == '\n') total_lines += 1;
    }
    if (core.terminal_output.items.len > 0 and core.terminal_output.items[core.terminal_output.items.len - 1] != '\n') {
        total_lines += 1;
    }

    const visible_height = if (core.win_size.rows > 2) core.win_size.rows - 2 else 1;
    const bottom_offset = if (total_lines > visible_height) total_lines - visible_height else 0;
    return core.terminal_scroll_offset >= bottom_offset;
}

pub fn scrollToTerminalBottom(core: anytype) void {
    var total_lines: usize = 0;
    for (core.terminal_output.items) |c| {
        if (c == '\n') total_lines += 1;
    }
    if (core.terminal_output.items.len > 0 and core.terminal_output.items[core.terminal_output.items.len - 1] != '\n') {
        total_lines += 1;
    }

    const visible_height = if (core.win_size.rows > 2) core.win_size.rows - 2 else 1;
    if (total_lines > visible_height) {
        core.terminal_scroll_offset = total_lines - visible_height;
    } else {
        core.terminal_scroll_offset = 0;
    }
}

pub fn capTerminalOutputLines(core: anytype, max_lines: usize) void {
    var line_count: usize = 0;
    for (core.terminal_output.items) |c| {
        if (c == '\n') line_count += 1;
    }

    if (line_count <= max_lines) return;

    const lines_to_remove = line_count - max_lines;
    var removed: usize = 0;
    var cut_pos: usize = 0;

    for (core.terminal_output.items, 0..) |c, i| {
        if (c == '\n') {
            removed += 1;
            if (removed >= lines_to_remove) {
                cut_pos = i + 1;
                break;
            }
        }
    }

    if (cut_pos > 0 and cut_pos < core.terminal_output.items.len) {
        const remaining = core.terminal_output.items.len - cut_pos;
        std.mem.copyForwards(u8, core.terminal_output.items[0..remaining], core.terminal_output.items[cut_pos..]);
        core.terminal_output.items.len = remaining;

        if (core.terminal_scroll_offset >= lines_to_remove) {
            core.terminal_scroll_offset -= lines_to_remove;
        } else {
            core.terminal_scroll_offset = 0;
        }
    }
}

pub fn completeTerminalInput(core: anytype) !void {
    if (core.terminal_input.items.len == 0) return;

    var last_word_start: usize = core.terminal_input.items.len;
    while (last_word_start > 0) : (last_word_start -= 1) {
        const c = core.terminal_input.items[last_word_start - 1];
        if (c == ' ' or c == '"' or c == '\'') break;
    }

    const full_partial = core.terminal_input.items[last_word_start..];
    if (full_partial.len == 0) return;

    const last_slash = std.mem.lastIndexOfScalar(u8, full_partial, '/');
    const dir_part = if (last_slash) |idx| full_partial[0 .. idx + 1] else "";
    const partial = if (last_slash) |idx| full_partial[idx + 1 ..] else full_partial;

    var search_path_joined: []const u8 = undefined;
    if (dir_part.len > 0) {
        search_path_joined = std.fs.path.join(core.allocator, &.{ core.file_manager.cwd, dir_part }) catch core.file_manager.cwd;
    } else {
        search_path_joined = core.file_manager.cwd;
    }
    defer if (dir_part.len > 0 and !std.mem.eql(u8, search_path_joined, core.file_manager.cwd)) core.allocator.free(search_path_joined);

    var dir = std.Io.Dir.cwd().openDir(core.io, search_path_joined, .{ .iterate = true }) catch return;
    defer dir.close(core.io);

    var iter = dir.iterate();
    var best_match: ?[]const u8 = null;
    var match_count: usize = 0;

    while (try iter.next(core.io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, partial)) {
            if (best_match) |bm| {
                var common_len: usize = 0;
                while (common_len < bm.len and common_len < entry.name.len and bm[common_len] == entry.name[common_len]) : (common_len += 1) {}
                const new_bm = core.allocator.dupe(u8, bm[0..common_len]) catch bm;
                if (new_bm.ptr != bm.ptr) core.allocator.free(bm);
                best_match = new_bm;
            } else {
                best_match = core.allocator.dupe(u8, entry.name) catch null;
            }
            match_count += 1;
        }
    }

    if (best_match) |bm| {
        defer core.allocator.free(bm);
        if (bm.len > partial.len) {
            try core.terminal_input.appendSlice(core.allocator, bm[partial.len..]);

            if (match_count == 1) {
                var stat_dir = dir.openDir(core.io, bm, .{}) catch null;
                if (stat_dir) |*sd| {
                    sd.close(core.io);
                    try core.terminal_input.append(core.allocator, '/');
                } else {
                    try core.terminal_input.append(core.allocator, ' ');
                }
            }
        } else if (match_count == 1) {
            const last_char = core.terminal_input.items[core.terminal_input.items.len - 1];
            if (last_char != '/' and last_char != ' ') {
                var stat_dir = dir.openDir(core.io, bm, .{}) catch null;
                if (stat_dir) |*sd| {
                    sd.close(core.io);
                    try core.terminal_input.append(core.allocator, '/');
                } else {
                    try core.terminal_input.append(core.allocator, ' ');
                }
            }
        }
    }
}
