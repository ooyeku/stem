//! Git integration plugin (v3 ABI).
//!
//! Migrated from v2:
//!   - `init(ctx: *PluginContext)` → `activate(handle: PluginHandle)`
//!   - All allocations use `std.heap.page_allocator` (the SDK no longer
//!     hands plugins a host allocator). For long-lived state we keep
//!     a single allocator constant at the top of the file.
//!   - The previous keybinding handler is dropped — no v3 hook for it
//!     yet (TODO: route through the same `handle_message` channel).

const std = @import("std");
const stem = @import("stem");

const A = std.heap.page_allocator;

var active_buffer_name: ?[]u8 = null;
var status_item_created: bool = false;
var toggle_row: usize = 0;

const GitRunOptions = struct {
    argv: []const []const u8,
    cwd: std.process.Child.Cwd = .{ .path = "." },
};

fn runGit(allocator: std.mem.Allocator, opts: GitRunOptions) !std.process.RunResult {
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    return std.process.run(allocator, io, .{ .argv = opts.argv, .cwd = opts.cwd });
}

fn activate(handle: stem.PluginHandle) callconv(.c) i32 {
    stem.bind(handle);

    stem.registerCommand(handle, "git.status", "[Git] Status", "Show repository status", cmdGitStatus) catch return -1;
    stem.registerCommand(handle, "git.diff", "[Git] Diff", "Show changes in current file", cmdGitDiff) catch {};
    stem.registerCommand(handle, "git.diff_staged", "[Git] Diff Staged", "Show staged changes", cmdGitDiffStaged) catch {};

    stem.subscribeEvent(handle, .buffer_switched, onBufferSwitched) catch {
        stem.log(handle, "Failed to subscribe to buffer_switched", .{});
    };

    updateStatus(handle);
    stem.requestEditorState(handle, onInitState) catch {};
    return 0;
}

fn deactivate(handle: stem.PluginHandle) callconv(.c) void {
    const old = active_buffer_name;
    active_buffer_name = null;
    if (old) |n| A.free(n);
    if (status_item_created) stem.destroyStatusItem(handle, "git.branch") catch {};
    stem.unbind();
}

fn handleMessage(handle: stem.PluginHandle, ptr: [*]const u8, len: usize) callconv(.c) i32 {
    return stem.dispatch(handle, ptr, len);
}

fn onBufferSwitched(handle: stem.PluginHandle, data: []const u8) void {
    const old = active_buffer_name;
    if (data.len > 0 and !std.mem.startsWith(u8, data, "[") and !std.mem.startsWith(u8, data, "untitled")) {
        active_buffer_name = A.dupe(u8, data) catch null;
    } else {
        active_buffer_name = null;
    }
    if (old) |n| A.free(n);
    updateStatus(handle);
}

fn onInitState(handle: stem.PluginHandle, state: stem.EditorStateView) void {
    if (state.file_path) |path| {
        const old = active_buffer_name;
        active_buffer_name = A.dupe(u8, path) catch null;
        if (old) |n| A.free(n);
        updateStatus(handle);
    }
}

fn updateStatus(handle: stem.PluginHandle) void {
    const branch_res = runGit(A, .{ .argv = &.{ "git", "branch", "--show-current" } }) catch return;
    defer {
        A.free(branch_res.stdout);
        A.free(branch_res.stderr);
    }
    if (branch_res.term.exited != 0) return;

    const branch = std.mem.trim(u8, branch_res.stdout, "\n \t");
    if (branch.len == 0) return;

    const status_res = runGit(A, .{ .argv = &.{ "git", "status", "--porcelain" } }) catch return;
    defer {
        A.free(status_res.stdout);
        A.free(status_res.stderr);
    }
    const dirty_mark: []const u8 = if (status_res.stdout.len > 0) "*" else "";

    const text = std.fmt.allocPrint(A, "Git: {s}{s}", .{ branch, dirty_mark }) catch return;
    defer A.free(text);

    if (!status_item_created) {
        stem.createStatusItem(handle, "git.branch", text, .right, 10) catch {
            stem.log(handle, "Failed to create status item", .{});
            return;
        };
        status_item_created = true;
    } else {
        stem.updateStatusItem(handle, "git.branch", text) catch {};
    }
    stem.emitEvent(handle, "git.updated", branch) catch {};
}

fn cmdGitStatus(handle: stem.PluginHandle) void {
    const result = runGit(A, .{ .argv = &.{ "git", "status", "--porcelain" } }) catch {
        stem.showError(handle, "Failed to execute git status") catch {};
        return;
    };
    defer {
        A.free(result.stdout);
        A.free(result.stderr);
    }
    if (result.term.exited != 0) {
        stem.showError(handle, "git status command failed") catch {};
        return;
    }

    const branch_res = runGit(A, .{ .argv = &.{ "git", "branch", "--show-current" } }) catch null;
    defer if (branch_res) |res| {
        A.free(res.stdout);
        A.free(res.stderr);
    };

    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(A);

    text.appendSlice(A, "# Git Status\n\n") catch return;
    if (branch_res) |res| {
        const branch = std.mem.trim(u8, res.stdout, "\n \t");
        const line = std.fmt.allocPrint(A, "## Branch: {s}\n\n", .{branch}) catch return;
        defer A.free(line);
        text.appendSlice(A, line) catch return;
    }

    var staged: std.ArrayListUnmanaged([]const u8) = .empty;
    defer staged.deinit(A);
    var unstaged: std.ArrayListUnmanaged([]const u8) = .empty;
    defer unstaged.deinit(A);
    var untracked: std.ArrayListUnmanaged([]const u8) = .empty;
    defer untracked.deinit(A);

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len < 3) continue;
        const index_status = line[0];
        const work_status = line[1];
        const path = line[3..];
        if (index_status != ' ' and index_status != '?') {
            const entry = std.fmt.allocPrint(A, "- `{c}` {s}", .{ index_status, path }) catch continue;
            staged.append(A, entry) catch {};
        }
        if (work_status != ' ' and work_status != '?') {
            const entry = std.fmt.allocPrint(A, "- `{c}` {s}", .{ work_status, path }) catch continue;
            unstaged.append(A, entry) catch {};
        }
        if (index_status == '?' and work_status == '?') {
            const entry = std.fmt.allocPrint(A, "- `?` {s}", .{path}) catch continue;
            untracked.append(A, entry) catch {};
        }
    }
    defer {
        for (staged.items) |s| A.free(s);
        for (unstaged.items) |s| A.free(s);
        for (untracked.items) |s| A.free(s);
    }

    if (staged.items.len > 0) {
        text.appendSlice(A, "### Changes to be committed\n") catch return;
        for (staged.items) |item| {
            text.appendSlice(A, item) catch return;
            text.appendSlice(A, "\n") catch return;
        }
        text.appendSlice(A, "\n") catch return;
    }
    if (unstaged.items.len > 0) {
        text.appendSlice(A, "### Changes not staged for commit\n") catch return;
        for (unstaged.items) |item| {
            text.appendSlice(A, item) catch return;
            text.appendSlice(A, "\n") catch return;
        }
        text.appendSlice(A, "\n") catch return;
    }
    if (untracked.items.len > 0) {
        text.appendSlice(A, "### Untracked files\n") catch return;
        for (untracked.items) |item| {
            text.appendSlice(A, item) catch return;
            text.appendSlice(A, "\n") catch return;
        }
        text.appendSlice(A, "\n") catch return;
    }
    if (staged.items.len == 0 and unstaged.items.len == 0 and untracked.items.len == 0) {
        text.appendSlice(A, "- No changes.\n") catch return;
    }
    text.appendSlice(A, "\n## Commands\n\n- `q`: Close\n") catch return;

    stem.openBuffer(handle, "[Git Status]", text.items) catch {};
    updateStatus(handle);
}

fn cmdGitDiff(handle: stem.PluginHandle) void {
    visualDiff(handle, false);
}
fn cmdGitDiffStaged(handle: stem.PluginHandle) void {
    visualDiff(handle, true);
}

fn visualDiff(handle: stem.PluginHandle, staged: bool) void {
    const diff_args: []const []const u8 = if (staged) &.{ "git", "diff", "--cached" } else &.{ "git", "diff" };
    const diff_res = runGit(A, .{ .argv = diff_args }) catch {
        stem.showError(handle, "Failed to run git diff") catch {};
        return;
    };
    defer {
        A.free(diff_res.stdout);
        A.free(diff_res.stderr);
    }

    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(A);
    if (staged) {
        text.appendSlice(A, "# Git Diff (Staged)\n\n") catch return;
    } else {
        text.appendSlice(A, "# Git Diff\n\n") catch return;
    }

    if (diff_res.stdout.len == 0) {
        text.appendSlice(A, if (staged) "No staged changes.\n" else "No unstaged changes.\n") catch return;
    } else {
        var lines = std.mem.splitScalar(u8, diff_res.stdout, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) {
                text.appendSlice(A, "\n") catch return;
                continue;
            }
            const prefix: []const u8 = if (std.mem.startsWith(u8, line, "diff --git"))
                "## "
            else if (std.mem.startsWith(u8, line, "@@"))
                "### "
            else
                "";
            text.appendSlice(A, prefix) catch return;
            text.appendSlice(A, line) catch return;
            text.appendSlice(A, "\n") catch return;
        }
    }
    text.appendSlice(A, "\n## Commands\n\n- `q`: Close\n") catch return;
    const name: []const u8 = if (staged) "[Git Diff Staged]" else "[Git Diff]";
    stem.openBuffer(handle, name, text.items) catch {};
}

pub export const plugin_entry = stem.createPlugin(.{
    .name = "git",
    .description = "Git integration for Stem",
    .activate = activate,
    .deactivate = deactivate,
    .handle_message = handleMessage,
});
