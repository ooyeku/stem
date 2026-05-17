const std = @import("std");
const stem = @import("stem");

var plugin_ctx: ?*stem.PluginContext = null;
var active_buffer_name: ?[]u8 = null;
var toggle_row: usize = 0;
var status_item_created: bool = false;

// TODO(zig-0.16): plumb io down from kernel into PluginContext so plugins don't
// have to construct their own Threaded.
const GitRunOptions = struct {
    argv: []const []const u8,
    cwd: std.process.Child.Cwd = .{ .path = "." },
};

fn runGit(allocator: std.mem.Allocator, opts: GitRunOptions) !std.process.RunResult {
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    return std.process.run(allocator, io, .{
        .argv = opts.argv,
        .cwd = opts.cwd,
    });
}

/// Exported so the editor can verify the plugin and stem agree on
/// `@sizeOf(stem.PluginContext)`. A mismatch would mean the two TUs
/// have different layouts → silent miscompile → init segfault.
export fn stem_plugin_context_sizeof() usize {
    return @sizeOf(stem.PluginContext);
}

fn init(ctx: *stem.PluginContext) i32 {
    plugin_ctx = ctx;

    // Register Git commands
    stem.registerCommand(
        ctx,
        "git.status",
        "[Git] Status",
        "Show repository status",
        cmdGitStatus,
    ) catch {
        return -1;
    };
    stem.registerCommand(
        ctx,
        "git.diff",
        "[Git] Diff",
        "Show changes in current file",
        cmdGitDiff,
    ) catch {};
    stem.registerCommand(
        ctx,
        "git.diff_staged",
        "[Git] Diff Staged",
        "Show staged changes in current file",
        cmdGitDiffStaged,
    ) catch {};

    // Subscribe to buffer switch events to track active buffer
    stem.subscribeEvent(ctx, .buffer_switched, onBufferSwitched) catch {
        stem.log(ctx, "Failed to subscribe to buffer_switched", .{});
    };

    // Initial status update
    updateStatus(ctx);

    // Request initial state to get active buffer
    stem.requestEditorState(ctx, onInitState) catch {};

    return 0;
}

fn deinit(ctx: *stem.PluginContext) void {
    // Take ownership and null before freeing to prevent double-free from concurrent events
    const name_to_free = active_buffer_name;
    active_buffer_name = null;
    if (name_to_free) |n| ctx.allocator.free(n);
    if (status_item_created) {
        stem.destroyStatusItem(ctx, "git.branch") catch {};
    }
    stem.deinitSdk(ctx);
    plugin_ctx = null;
}

fn handleMessage(ctx: *stem.PluginContext, msg: *const stem.PluginMessage) i32 {
    // Standard SDK handler handles callbacks and events
    if (stem.handleStandardMessages(ctx, msg)) {
        return 0;
    }
    return 0;
}

fn onBufferSwitched(ctx: *stem.PluginContext, data: []const u8) void {
    // Only track real file paths (not buffer names like 'untitled-1')
    const old_name = active_buffer_name;
    if (data.len > 0 and !std.mem.startsWith(u8, data, "[") and !std.mem.startsWith(u8, data, "untitled")) {
        active_buffer_name = ctx.allocator.dupe(u8, data) catch null;
    } else {
        active_buffer_name = null;
    }
    // Free old after setting new to avoid issues
    if (old_name) |n| ctx.allocator.free(n);
    updateStatus(ctx);
}

fn onInitState(ctx: *stem.PluginContext, state: stem.EditorStateView) void {
    // Only set active_buffer_name if we have a real file path
    if (state.file_path) |path| {
        const old_name = active_buffer_name;
        active_buffer_name = ctx.allocator.dupe(u8, path) catch null;
        if (old_name) |n| ctx.allocator.free(n);
        updateStatus(ctx);
    }
}

fn updateStatus(ctx: *stem.PluginContext) void {
    const allocator = ctx.allocator;

    // Get branch
    const branch_res = runGit(allocator, .{
        .argv = &[_][]const u8{ "git", "branch", "--show-current" },
    }) catch return; // Fail silently
    defer {
        allocator.free(branch_res.stdout);
        allocator.free(branch_res.stderr);
    }

    if (branch_res.term.exited != 0) return; // Not a git repo?

    const branch = std.mem.trim(u8, branch_res.stdout, "\n \t");
    if (branch.len == 0) return;

    // Check dirty state (porcelain)
    const status_res = runGit(allocator, .{
        .argv = &[_][]const u8{ "git", "status", "--porcelain" },
    }) catch return;
    defer {
        allocator.free(status_res.stdout);
        allocator.free(status_res.stderr);
    }

    const is_dirty = status_res.stdout.len > 0;
    const dirty_mark = if (is_dirty) "*" else "";

    const text = std.fmt.allocPrint(allocator, "Git: {s}{s}", .{ branch, dirty_mark }) catch return;
    defer allocator.free(text);

    if (!status_item_created) {
        stem.createStatusItem(ctx, "git.branch", text, .right, 10) catch {
            stem.log(ctx, "Failed to create status item", .{});
            return;
        };
        status_item_created = true;
    } else {
        stem.updateStatusItem(ctx, "git.branch", text) catch {};
    }

    // Emit inter-plugin event
    stem.emitEvent(ctx, "git.updated", branch) catch {};
}

fn keyHandler(ctx: *stem.PluginContext, key: *const stem.vaxis.Key) i32 {
    // Check if we are in [Git Status] buffer
    const name = active_buffer_name orelse return 0;
    if (!std.mem.eql(u8, name, "[Git Status]")) return 0;

    if (key.matches(stem.vaxis.Key.enter, .{})) {
        // Toggle stage
        // We need cursor row. Request state.
        stem.requestEditorState(ctx, onStateForToggle) catch {};
        return 1; // Handled
    }
    return 0;
}

fn onStateForToggle(ctx: *stem.PluginContext, state: stem.protocol.EditorStateView) void {
    toggle_row = state.cursor_row;
    stem.getBufferContent(ctx, onContentForToggle) catch {};
}

fn onContentForToggle(ctx: *stem.PluginContext, id: u32, content: []const u8) void {
    _ = id;
    // Parse content at toggle_row
    var it = std.mem.splitScalar(u8, content, '\n');
    var i: usize = 0;
    while (it.next()) |line| {
        if (i == toggle_row) {
            parseAndToggle(ctx, line);
            break;
        }
        i += 1;
    }
}

fn parseAndToggle(ctx: *stem.PluginContext, line: []const u8) void {
    // Expected format: "- `X` path/to/file"
    // X can be ' ', '?', 'M', 'A', 'D', etc.
    // Length check: "- `X` ".len = 6
    if (line.len < 6) return;

    // Check if it's a file line
    if (!std.mem.startsWith(u8, line, "- `")) return;

    const status_char = line[3];
    _ = status_char;
    // Path starts at index 6
    const path = line[6..];
    _ = path;

    const allocator = ctx.allocator;
    _ = allocator;
}

fn onContentForToggleV2(ctx: *stem.PluginContext, id: u32, content: []const u8) void {
    _ = id;
    var it = std.mem.splitScalar(u8, content, '\n');
    var i: usize = 0;

    var current_section: enum { None, Staged, Unstaged, Untracked } = .None;

    const allocator = ctx.allocator;

    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "### Changes to be committed")) {
            current_section = .Staged;
        } else if (std.mem.startsWith(u8, line, "### Changes not staged")) {
            current_section = .Unstaged;
        } else if (std.mem.startsWith(u8, line, "### Untracked files")) {
            current_section = .Untracked;
        }

        if (i == toggle_row) {
            // Found the line and section
            if (line.len < 6 or !std.mem.startsWith(u8, line, "- `")) break;
            const path = line[6..];

            // Execute git command
            const args = switch (current_section) {
                .Staged => &[_][]const u8{ "git", "reset", "HEAD", path }, // Unstage
                .Unstaged, .Untracked => &[_][]const u8{ "git", "add", path }, // Stage
                .None => return, // Unknown line
            };

            // Run command
            const res = runGit(allocator, .{
                .argv = args,
            }) catch {
                stem.showError(ctx, "Git command failed") catch {};
                return;
            };
            defer {
                allocator.free(res.stdout);
                allocator.free(res.stderr);
            }

            // Refresh status
            cmdGitStatus(ctx);
            break;
        }
        i += 1;
    }
}

fn cmdGitStatus(ctx: *stem.PluginContext) void {
    const allocator = ctx.allocator;

    // Run git status --porcelain for easy parsing
    const result = runGit(allocator, .{
        .argv = &[_][]const u8{ "git", "status", "--porcelain" },
    }) catch {
        stem.showError(ctx, "Failed to execute git status") catch {};
        return;
    };

    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    if (result.term.exited != 0) {
        stem.showError(ctx, "git status command failed") catch {};
        return;
    }

    // Get current branch
    const branch_res = runGit(allocator, .{
        .argv = &[_][]const u8{ "git", "branch", "--show-current" },
    }) catch null;
    defer if (branch_res) |res| {
        allocator.free(res.stdout);
        allocator.free(res.stderr);
    };

    var text = std.ArrayListUnmanaged(u8).empty;
    defer text.deinit(allocator);

    // 1. Header and Branch Info
    text.appendSlice(allocator, "# Git Status\n\n") catch return;

    if (branch_res) |res| {
        const branch = std.mem.trim(u8, res.stdout, "\n \t");
        const branch_line = std.fmt.allocPrint(allocator, "## Branch: {s}\n\n", .{branch}) catch return;
        defer allocator.free(branch_line);
        text.appendSlice(allocator, branch_line) catch return;
    }

    // 2. Parse status lines
    var staged = std.ArrayListUnmanaged([]const u8).empty;
    defer staged.deinit(allocator);
    var unstaged = std.ArrayListUnmanaged([]const u8).empty;
    defer unstaged.deinit(allocator);
    var untracked = std.ArrayListUnmanaged([]const u8).empty;
    defer untracked.deinit(allocator);

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len < 3) continue;

        const index_status = line[0];
        const work_status = line[1];
        const path = line[3..];

        // Staged checks
        if (index_status != ' ' and index_status != '?') {
            const entry = std.fmt.allocPrint(allocator, "- `{c}` {s}", .{ index_status, path }) catch continue;
            staged.append(allocator, entry) catch {};
        }

        // Unstaged checks
        if (work_status != ' ' and work_status != '?') {
            const entry = std.fmt.allocPrint(allocator, "- `{c}` {s}", .{ work_status, path }) catch continue;
            unstaged.append(allocator, entry) catch {};
        }

        // Untracked checks
        if (index_status == '?' and work_status == '?') {
            const entry = std.fmt.allocPrint(allocator, "- `?` {s}", .{path}) catch continue;
            untracked.append(allocator, entry) catch {};
        }
    }
    defer {
        for (staged.items) |s| allocator.free(s);
        for (unstaged.items) |s| allocator.free(s);
        for (untracked.items) |s| allocator.free(s);
    }

    // 3. Build Markdown Output using Headers for colors
    // HelpView uses: # (Blue), ## (Cyan), ### (Yellow)

    if (staged.items.len > 0) {
        text.appendSlice(allocator, "### Changes to be committed\n") catch return;
        for (staged.items) |item| {
            text.appendSlice(allocator, item) catch return;
            text.appendSlice(allocator, "\n") catch return;
        }
        text.appendSlice(allocator, "\n") catch return;
    }

    if (unstaged.items.len > 0) {
        text.appendSlice(allocator, "### Changes not staged for commit\n") catch return;
        for (unstaged.items) |item| {
            text.appendSlice(allocator, item) catch return;
            text.appendSlice(allocator, "\n") catch return;
        }
        text.appendSlice(allocator, "\n") catch return;
    }

    if (untracked.items.len > 0) {
        text.appendSlice(allocator, "### Untracked files\n") catch return;
        for (untracked.items) |item| {
            text.appendSlice(allocator, item) catch return;
            text.appendSlice(allocator, "\n") catch return;
        }
        text.appendSlice(allocator, "\n") catch return;
    }

    if (staged.items.len == 0 and unstaged.items.len == 0 and untracked.items.len == 0) {
        text.appendSlice(allocator, "- No changes.\n") catch return;
    }

    text.appendSlice(allocator, "\n## Commands\n\n- `Enter`: Stage/Unstage\n- `q`: Close\n") catch return;

    // Open buffer with [Git Status] name to trigger HelpView rendering
    stem.openBuffer(ctx, "[Git Status]", text.items) catch {};
    updateStatus(ctx);
}

fn cmdGitDiff(ctx: *stem.PluginContext) void {
    visualDiff(ctx, false);
}

fn cmdGitDiffStaged(ctx: *stem.PluginContext) void {
    visualDiff(ctx, true);
}

fn visualDiff(ctx: *stem.PluginContext, staged: bool) void {
    const allocator = ctx.allocator;

    // Run git diff for the entire repo (similar to how git status works)
    const diff_args = if (staged)
        &[_][]const u8{ "git", "diff", "--cached" }
    else
        &[_][]const u8{ "git", "diff" };

    const diff_res = runGit(allocator, .{
        .argv = diff_args,
    }) catch {
        stem.showError(ctx, "Failed to run git diff command") catch {};
        return;
    };
    defer {
        allocator.free(diff_res.stdout);
        allocator.free(diff_res.stderr);
    }

    if (diff_res.term.exited != 0) {
        stem.showError(ctx, "git diff command failed") catch {};
        return;
    }

    // Build the diff output buffer
    var text = std.ArrayListUnmanaged(u8).empty;
    defer text.deinit(allocator);

    // Header
    if (staged) {
        text.appendSlice(allocator, "# Git Diff (Staged)\n\n") catch return;
    } else {
        text.appendSlice(allocator, "# Git Diff\n\n") catch return;
    }

    // Check if there are any changes
    if (diff_res.stdout.len == 0) {
        if (staged) {
            text.appendSlice(allocator, "No staged changes.\n") catch return;
        } else {
            text.appendSlice(allocator, "No unstaged changes.\n") catch return;
        }
    } else {
        // Show the diff output with line coloring hints
        // Parse diff lines and format them
        var lines = std.mem.splitScalar(u8, diff_res.stdout, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) {
                text.appendSlice(allocator, "\n") catch return;
                continue;
            }

            // Format lines based on their type
            if (std.mem.startsWith(u8, line, "diff --git")) {
                text.appendSlice(allocator, "## ") catch return;
                text.appendSlice(allocator, line) catch return;
                text.appendSlice(allocator, "\n") catch return;
            } else if (std.mem.startsWith(u8, line, "@@")) {
                text.appendSlice(allocator, "### ") catch return;
                text.appendSlice(allocator, line) catch return;
                text.appendSlice(allocator, "\n") catch return;
            } else if (line[0] == '+' and !std.mem.startsWith(u8, line, "+++")) {
                // Added line - mark with +
                text.appendSlice(allocator, line) catch return;
                text.appendSlice(allocator, "\n") catch return;
            } else if (line[0] == '-' and !std.mem.startsWith(u8, line, "---")) {
                // Removed line - mark with -
                text.appendSlice(allocator, line) catch return;
                text.appendSlice(allocator, "\n") catch return;
            } else {
                text.appendSlice(allocator, line) catch return;
                text.appendSlice(allocator, "\n") catch return;
            }
        }
    }

    text.appendSlice(allocator, "\n## Commands\n\n- `q`: Close\n") catch return;

    // Open buffer with [Git Diff] name - same pattern as [Git Status]
    const buffer_name = if (staged) "[Git Diff Staged]" else "[Git Diff]";
    stem.openBuffer(ctx, buffer_name, text.items) catch {};
}

pub export const plugin_entry = stem.createPlugin(.{
    .name = "git",
    .description = "Git integration for Stem",
    .init = init,
    .deinit = deinit,
    .handleMessage = handleMessage,
    .keybindingHandler = keyHandler,
});
