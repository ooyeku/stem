const std = @import("std");
const logger_service = @import("../../services/logger.zig");
const log = logger_service.scoped("GitCommands");
const protocol = @import("../protocol.zig");

fn childExitCode(term: std.process.Child.Term) i32 {
    return switch (term) {
        .exited => |code| @intCast(code),
        .signal => |sig| -@as(i32, @intCast(@intFromEnum(sig))),
        else => -999,
    };
}

pub const GitCommands = struct {
    pub fn cmdGitDiff(core: anytype) anyerror!void {
        core.decoration_manager.clearDiffDecorations();

        const file_path = core.state().file_path orelse {
            log.info("Git diff: No file path for current buffer", .{});
            return;
        };

        const current_content = core.state().buffer.toString(core.allocator) catch {
            log.warn("Git diff: Failed to get current buffer content", .{});
            return;
        };
        defer core.allocator.free(current_content);

        const head_content = getGitHeadContent(core.allocator, core.io, file_path) catch |err| {
            if (err == error.GitCommandFailed) {
                log.info("Git diff: File not tracked in git or no HEAD version exists", .{});
            } else {
                log.warn("Git diff: Failed to get HEAD version: {}", .{err});
            }
            core.leader_pending = false;
            return;
        };
        defer core.allocator.free(head_content);

        if (head_content.len == 0) {
            log.info("Git diff: File has no changes from HEAD", .{});
            core.leader_pending = false;
            return;
        }

        var added_lines = std.ArrayListUnmanaged(usize).empty;
        defer added_lines.deinit(core.allocator);
        var changed_lines = std.ArrayListUnmanaged(usize).empty;
        defer changed_lines.deinit(core.allocator);

        try computeLineDiff(core.allocator, current_content, head_content, &added_lines, &changed_lines);

        const basename = std.fs.path.basename(file_path);

        var name_buf: [256]u8 = undefined;
        const head_name = std.fmt.bufPrint(&name_buf, "[HEAD] {s}", .{basename}) catch "[HEAD]";

        const current_buf_index = core.buffer_manager.active_index;

        try core.ensureSplitManager();
        if (core.split_manager) |*sm| {
            try sm.splitHorizontal(current_buf_index);
        }

        try core.buffer_manager.openVirtual(head_name, head_content);
        const head_buf_index = core.buffer_manager.active_index;

        if (core.split_manager) |*sm| {
            const focused_pane = sm.getFocusedPane();
            focused_pane.buffer_index = head_buf_index;
        }

        core.diff_highlights.clearRetainingCapacity();

        for (added_lines.items) |line| {
            try core.diff_highlights.append(core.allocator, .{
                .line = line,
                .kind = .added,
            });
        }

        for (changed_lines.items) |line| {
            try core.diff_highlights.append(core.allocator, .{
                .line = line,
                .kind = .changed,
            });
        }

        if (core.split_manager) |*sm| {
            sm.sync_scroll = true;
        }

        core.leader_pending = false;

        const change_count = added_lines.items.len + changed_lines.items.len;
        log.info("Git diff: {s} - {} changes highlighted", .{ basename, change_count });
        try core.sendUpdate();
    }

    pub fn computeLineDiff(
        allocator: std.mem.Allocator,
        current_content: []const u8,
        head_content: []const u8,
        added_lines: *std.ArrayListUnmanaged(usize),
        changed_lines: *std.ArrayListUnmanaged(usize),
    ) !void {
        var current_lines = std.ArrayListUnmanaged([]const u8).empty;
        defer current_lines.deinit(allocator);
        var head_lines = std.ArrayListUnmanaged([]const u8).empty;
        defer head_lines.deinit(allocator);

        var current_iter = std.mem.splitScalar(u8, current_content, '\n');
        while (current_iter.next()) |line| {
            try current_lines.append(allocator, line);
        }

        var head_iter = std.mem.splitScalar(u8, head_content, '\n');
        while (head_iter.next()) |line| {
            try head_lines.append(allocator, line);
        }

        const max_lines = @max(current_lines.items.len, head_lines.items.len);

        for (0..max_lines) |i| {
            if (i >= current_lines.items.len) {
                continue;
            }

            const current_line = current_lines.items[i];

            if (i >= head_lines.items.len) {
                try added_lines.append(allocator, i);
            } else {
                const head_line = head_lines.items[i];
                if (!std.mem.eql(u8, current_line, head_line)) {
                    try changed_lines.append(allocator, i);
                }
            }
        }
    }

    pub fn getGitHeadContent(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8) ![]u8 {
        const dir = std.fs.path.dirname(file_path) orelse ".";

        const cwd = try allocator.dupe(u8, dir);
        defer allocator.free(cwd);

        const root_result = std.process.run(allocator, io, .{
            .argv = &.{ "git", "rev-parse", "--show-toplevel" },
            .cwd = .{ .path = cwd },
        }) catch |err| {
            log.debug("Git rev-parse failed: {}", .{err});
            return error.GitCommandFailed;
        };
        defer allocator.free(root_result.stderr);

        if (childExitCode(root_result.term) != 0) {
            allocator.free(root_result.stdout);
            log.debug("Not in a git repository", .{});
            return error.GitCommandFailed;
        }

        const git_root_raw = root_result.stdout;
        defer allocator.free(git_root_raw);

        var git_root_len = git_root_raw.len;
        if (git_root_len > 0 and git_root_raw[git_root_len - 1] == '\n') {
            git_root_len -= 1;
        }
        const git_root = git_root_raw[0..git_root_len];

        var relative_path: []const u8 = file_path;
        if (std.mem.startsWith(u8, file_path, git_root)) {
            relative_path = file_path[git_root_len..];
            if (relative_path.len > 0 and relative_path[0] == '/') {
                relative_path = relative_path[1..];
            }
        }

        var cmd_buf: [512]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "HEAD:{s}", .{relative_path}) catch return error.PathTooLong;

        const show_cwd = try allocator.dupe(u8, git_root);
        defer allocator.free(show_cwd);

        const result = std.process.run(allocator, io, .{
            .argv = &.{ "git", "show", cmd },
            .cwd = .{ .path = show_cwd },
        }) catch |err| {
            log.debug("Git show failed: {}", .{err});
            return error.GitCommandFailed;
        };

        const show_exit_code = childExitCode(result.term);
        if (show_exit_code != 0) {
            allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            log.debug("Git show exited with {}: {s}", .{ show_exit_code, result.stderr });
            return error.GitCommandFailed;
        }

        allocator.free(result.stderr);
        return result.stdout;
    }
};
