//! Git plugin (wasm runtime).
//!
//! Exposes three commands (`status`, `diff`, `diff_staged`) that
//! shell out to `git` via `stem_spawn_capture` and render output
//! into a virtual buffer, plus a live `Git: <branch>` status-bar
//! indicator that updates when the user switches buffers or saves a
//! file.
//!
//! Permissions required (declared in plugin.json):
//!   - spawn:  ["git"]
//!   - events: ["buffer.switched", "buffer.changed", "file.saved"]

const std = @import("std");

extern "env" fn stem_log(level: i32, msg_ptr: [*]const u8, msg_len: i32) void;
extern "env" fn stem_register_command(
    id_ptr: [*]const u8,
    id_len: i32,
    title_ptr: [*]const u8,
    title_len: i32,
    desc_ptr: [*]const u8,
    desc_len: i32,
) void;
extern "env" fn stem_open_buffer(
    name_ptr: [*]const u8,
    name_len: i32,
    content_ptr: [*]const u8,
    content_len: i32,
) void;
extern "env" fn stem_spawn_capture(
    cmd_ptr: [*]const u8,
    cmd_len: i32,
    out_ptr: [*]u8,
    out_max: i32,
) i32;
extern "env" fn stem_subscribe_event(topic_ptr: [*]const u8, topic_len: i32) i32;
extern "env" fn stem_set_status_item(
    id_ptr: [*]const u8,
    id_len: i32,
    text_ptr: [*]const u8,
    text_len: i32,
    alignment: i32,
    priority: i32,
) void;
extern "env" fn stem_clear_status_item(id_ptr: [*]const u8, id_len: i32) void;

/// Large scratch for `git diff` output.
var scratch: [256 * 1024]u8 = undefined;
/// Small scratch for branch / status checks.
var small_scratch: [256]u8 = undefined;

// Host-dispatch scratch region.
var stem_scratch_buf: [4096]u8 = undefined;
export fn __stem_scratch_addr() i32 {
    return @intCast(@intFromPtr(&stem_scratch_buf));
}
export fn __stem_scratch_size() i32 {
    return @intCast(stem_scratch_buf.len);
}

const CMD_STATUS = "git.status";
const CMD_DIFF = "git.diff";
const CMD_DIFF_STAGED = "git.diff_staged";

const Cmd = struct {
    id: []const u8,
    title: []const u8,
    desc: []const u8,
};

const COMMANDS = [_]Cmd{
    .{ .id = CMD_STATUS, .title = "[Git] Status", .desc = "Show repository status (git status --porcelain)" },
    .{ .id = CMD_DIFF, .title = "[Git] Diff", .desc = "Show unstaged changes (git diff)" },
    .{ .id = CMD_DIFF_STAGED, .title = "[Git] Diff Staged", .desc = "Show staged changes (git diff --staged)" },
};

const STATUS_ITEM_ID = "git.branch";

export fn activate() void {
    inline for (COMMANDS) |c| {
        stem_register_command(
            c.id.ptr,
            c.id.len,
            c.title.ptr,
            c.title.len,
            c.desc.ptr,
            c.desc.len,
        );
    }
    // Hook the editor's event bus so the branch indicator refreshes
    // when the user switches buffers or saves.
    _ = stem_subscribe_event("buffer.switched".ptr, "buffer.switched".len);
    _ = stem_subscribe_event("buffer.changed".ptr, "buffer.changed".len);
    _ = stem_subscribe_event("file.saved".ptr, "file.saved".len);

    refreshBranchStatus();

    const ready = "git plugin (wasm): ready";
    stem_log(1, ready.ptr, ready.len);
}

export fn handle_command(id_ptr: [*]const u8, id_len: i32) void {
    const id = id_ptr[0..@intCast(id_len)];
    if (std.mem.eql(u8, id, CMD_STATUS)) {
        runAndShow("git status --porcelain", "[Git Status]");
    } else if (std.mem.eql(u8, id, CMD_DIFF)) {
        runAndShow("git diff", "[Git Diff]");
    } else if (std.mem.eql(u8, id, CMD_DIFF_STAGED)) {
        runAndShow("git diff --staged", "[Git Diff Staged]");
    }
}

/// Inbound event dispatch. We refresh the branch indicator on each
/// relevant event — cheap (`git rev-parse` is sub-millisecond) and
/// keeps the UI accurate without polling.
export fn handle_event(topic_ptr: [*]const u8, topic_len: i32, data_ptr: [*]const u8, data_len: i32) void {
    _ = data_ptr;
    _ = data_len;
    const topic = topic_ptr[0..@intCast(topic_len)];
    if (std.mem.eql(u8, topic, "buffer.switched") or
        std.mem.eql(u8, topic, "buffer.changed") or
        std.mem.eql(u8, topic, "file.saved"))
    {
        refreshBranchStatus();
    }
}

/// Re-detect the current branch (and dirty marker) and update the
/// status-bar widget. Clears the widget if we're not inside a repo.
fn refreshBranchStatus() void {
    const branch_written = stem_spawn_capture(
        "git rev-parse --abbrev-ref HEAD".ptr,
        "git rev-parse --abbrev-ref HEAD".len,
        &small_scratch,
        @intCast(small_scratch.len),
    );
    if (branch_written <= 0) {
        stem_clear_status_item(STATUS_ITEM_ID.ptr, STATUS_ITEM_ID.len);
        return;
    }
    const raw = small_scratch[0..@intCast(branch_written)];
    const branch = std.mem.trim(u8, raw, " \t\r\n");
    if (branch.len == 0 or std.mem.eql(u8, branch, "HEAD")) {
        stem_clear_status_item(STATUS_ITEM_ID.ptr, STATUS_ITEM_ID.len);
        return;
    }

    // Dirty marker — a single `*` if `git status --porcelain` returns
    // any output.
    const dirty_written = stem_spawn_capture(
        "git status --porcelain".ptr,
        "git status --porcelain".len,
        &scratch,
        @intCast(scratch.len),
    );
    const dirty: []const u8 = if (dirty_written > 0) "*" else "";

    // Render "Git: <branch>[*]" into a small fixed buffer.
    var text_buf: [128]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buf, "Git: {s}{s}", .{ branch, dirty }) catch return;
    // alignment = 2 (right), priority = 10
    stem_set_status_item(
        STATUS_ITEM_ID.ptr,
        STATUS_ITEM_ID.len,
        text.ptr,
        @intCast(text.len),
        2,
        10,
    );
}

fn runAndShow(cmd: []const u8, buffer_name: []const u8) void {
    const written = stem_spawn_capture(
        cmd.ptr,
        @intCast(cmd.len),
        &scratch,
        @intCast(scratch.len),
    );
    if (written <= 0) {
        const msg = "git: command failed (denied by permissions, or non-zero exit, or git not on PATH)";
        stem_log(2, msg.ptr, msg.len);
        stem_open_buffer(
            buffer_name.ptr,
            @intCast(buffer_name.len),
            msg.ptr,
            @intCast(msg.len),
        );
        return;
    }
    const n: usize = @intCast(written);
    stem_open_buffer(
        buffer_name.ptr,
        @intCast(buffer_name.len),
        &scratch,
        @intCast(n),
    );
}
