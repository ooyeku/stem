//! Git plugin (wasm runtime).
//!
//! Three commands plus a live status-bar indicator:
//!
//!   - `git.status`      — parses `git status --porcelain=v1` and
//!                         groups entries by Staged / Unstaged /
//!                         Untracked with a one-line summary.
//!   - `git.diff`        — unified diff of unstaged changes, with a
//!                         small header that names each file.
//!   - `git.diff_staged` — same, but for the index.
//!
//! The status-bar widget refreshes on `buffer.switched`,
//! `buffer.changed`, and `file.saved`.
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

/// Raw stdout from `git diff` / `git status`.
var scratch: [256 * 1024]u8 = undefined;
/// Rendered (post-processing) output we hand to `stem_open_buffer`.
var rendered: [320 * 1024]u8 = undefined;
var rendered_len: usize = 0;
/// Small scratch for branch / dirty checks.
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
    .{ .id = CMD_STATUS, .title = "[Git] Status", .desc = "Show repository status grouped by staged / unstaged / untracked" },
    .{ .id = CMD_DIFF, .title = "[Git] Diff", .desc = "Show unstaged changes (working tree vs. index)" },
    .{ .id = CMD_DIFF_STAGED, .title = "[Git] Diff Staged", .desc = "Show staged changes (index vs. HEAD)" },
};

const STATUS_ITEM_ID = "git.branch";

export fn activate() void {
    inline for (COMMANDS) |c| {
        stem_register_command(c.id.ptr, c.id.len, c.title.ptr, c.title.len, c.desc.ptr, c.desc.len);
    }
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
        runStatus();
    } else if (std.mem.eql(u8, id, CMD_DIFF)) {
        runDiff("git diff", "[Git Diff]", "unstaged");
    } else if (std.mem.eql(u8, id, CMD_DIFF_STAGED)) {
        runDiff("git diff --staged", "[Git Diff Staged]", "staged");
    }
}

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

// ---------------------------------------------------------------------------
// Status bar indicator
// ---------------------------------------------------------------------------

fn refreshBranchStatus() void {
    const branch_written = stem_spawn_capture(
        "git rev-parse --abbrev-ref HEAD".ptr,
        "git rev-parse --abbrev-ref HEAD".len,
        &small_scratch,
        @intCast(small_scratch.len),
    );
    if (branch_written < 0) {
        stem_clear_status_item(STATUS_ITEM_ID.ptr, STATUS_ITEM_ID.len);
        return;
    }
    const raw = small_scratch[0..@intCast(branch_written)];
    const branch = std.mem.trim(u8, raw, " \t\r\n");
    if (branch.len == 0 or std.mem.eql(u8, branch, "HEAD")) {
        stem_clear_status_item(STATUS_ITEM_ID.ptr, STATUS_ITEM_ID.len);
        return;
    }

    const dirty_written = stem_spawn_capture(
        "git status --porcelain".ptr,
        "git status --porcelain".len,
        &scratch,
        @intCast(scratch.len),
    );
    const dirty: []const u8 = if (dirty_written > 0) "*" else "";

    var text_buf: [128]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buf, "Git: {s}{s}", .{ branch, dirty }) catch return;
    stem_set_status_item(STATUS_ITEM_ID.ptr, STATUS_ITEM_ID.len, text.ptr, @intCast(text.len), 2, 10);
}

// ---------------------------------------------------------------------------
// git.status
// ---------------------------------------------------------------------------

/// Run `git status --porcelain` and re-render the output grouped by
/// staged / unstaged / untracked, with a small header summarizing
/// branch + counts. The raw porcelain dump was the previous version,
/// but it's hard to scan: status codes are two-letter prefixes (`MM`,
/// ` D`, `??`) that mash files together. Parsing into sections is a
/// 40-line cost for a much more readable buffer.
fn runStatus() void {
    rendered_len = 0;

    // Header — current branch.
    const branch_written = stem_spawn_capture(
        "git rev-parse --abbrev-ref HEAD".ptr,
        "git rev-parse --abbrev-ref HEAD".len,
        &small_scratch,
        @intCast(small_scratch.len),
    );
    const branch: []const u8 = if (branch_written > 0)
        std.mem.trim(u8, small_scratch[0..@intCast(branch_written)], " \t\r\n")
    else
        "(detached)";

    // Body — porcelain output.
    const written = stem_spawn_capture(
        "git status --porcelain".ptr,
        "git status --porcelain".len,
        &scratch,
        @intCast(scratch.len),
    );
    if (written < 0) {
        showError("[Git Status]", written);
        return;
    }
    const body = scratch[0..@intCast(written)];

    var counts = StatusCounts{};
    countPorcelain(body, &counts);

    var hb: [256]u8 = undefined;
    const header = std.fmt.bufPrint(&hb, "On branch {s}\nStaged: {d}   Unstaged: {d}   Untracked: {d}\n", .{
        branch, counts.staged, counts.unstaged, counts.untracked,
    }) catch "Status:\n";
    appendStr(header);
    appendStr("─────────────────────────────────────────────────────────────────────\n\n");

    if (counts.total() == 0) {
        appendStr("Working tree clean.\n");
    } else {
        if (counts.staged > 0) {
            appendStr("Staged changes\n");
            emitPorcelain(body, .staged);
            appendStr("\n");
        }
        if (counts.unstaged > 0) {
            appendStr("Unstaged changes\n");
            emitPorcelain(body, .unstaged);
            appendStr("\n");
        }
        if (counts.untracked > 0) {
            appendStr("Untracked files\n");
            emitPorcelain(body, .untracked);
            appendStr("\n");
        }
    }

    stem_open_buffer("[Git Status]".ptr, "[Git Status]".len, &rendered, @intCast(rendered_len));
}

const StatusCounts = struct {
    staged: u32 = 0,
    unstaged: u32 = 0,
    untracked: u32 = 0,

    fn total(self: StatusCounts) u32 {
        return self.staged + self.unstaged + self.untracked;
    }
};

const Section = enum { staged, unstaged, untracked };

fn countPorcelain(body: []const u8, counts: *StatusCounts) void {
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        if (line.len < 3) continue;
        if (line[0] == '?' and line[1] == '?') {
            counts.untracked += 1;
            continue;
        }
        if (line[0] != ' ') counts.staged += 1;
        if (line[1] != ' ') counts.unstaged += 1;
    }
}

fn emitPorcelain(body: []const u8, section: Section) void {
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        if (line.len < 3) continue;
        const x = line[0];
        const y = line[1];
        const path = line[3..];
        switch (section) {
            .staged => {
                if (x == '?' or x == ' ') continue;
                emitLine(x, path);
            },
            .unstaged => {
                if (x == '?' or y == ' ') continue;
                emitLine(y, path);
            },
            .untracked => {
                if (x != '?' or y != '?') continue;
                emitLine('?', path);
            },
        }
    }
}

fn emitLine(code: u8, path: []const u8) void {
    const label: []const u8 = switch (code) {
        'M' => "modified ",
        'A' => "added    ",
        'D' => "deleted  ",
        'R' => "renamed  ",
        'C' => "copied   ",
        'U' => "unmerged ",
        '?' => "new      ",
        else => "changed  ",
    };
    appendStr("  ");
    appendStr(label);
    appendStr("  ");
    appendStr(path);
    appendStr("\n");
}

// ---------------------------------------------------------------------------
// git.diff / git.diff_staged
// ---------------------------------------------------------------------------

/// Run a diff command and write its output to a virtual buffer. The
/// previous implementation treated `written == 0` as failure, which
/// triggered a spurious "command failed" buffer whenever the working
/// tree (or index) was clean — those are the cases where git exits 0
/// with empty stdout. Now we distinguish: negative return → real
/// error; zero return → empty diff (clean tree); positive →
/// render with a small header for context.
fn runDiff(cmd: []const u8, buffer_name: []const u8, kind: []const u8) void {
    rendered_len = 0;
    const written = stem_spawn_capture(cmd.ptr, @intCast(cmd.len), &scratch, @intCast(scratch.len));
    if (written < 0) {
        showError(buffer_name, written);
        return;
    }
    if (written == 0) {
        var hb: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&hb, "No {s} changes.\n", .{kind}) catch "(no changes)\n";
        stem_open_buffer(buffer_name.ptr, @intCast(buffer_name.len), msg.ptr, @intCast(msg.len));
        return;
    }

    const body = scratch[0..@intCast(written)];

    // Header: count file diffs (`diff --git ` line count) so the user
    // gets a one-line summary above the raw unified diff.
    var file_count: u32 = 0;
    var hit = std.mem.splitScalar(u8, body, '\n');
    while (hit.next()) |line| {
        if (std.mem.startsWith(u8, line, "diff --git ")) file_count += 1;
    }

    var hb: [128]u8 = undefined;
    const header = std.fmt.bufPrint(&hb, "{s} changes — {d} file(s)\n", .{ kind, file_count }) catch "Diff\n";
    appendStr(header);
    appendStr("─────────────────────────────────────────────────────────────────────\n\n");
    appendStr(body);

    stem_open_buffer(buffer_name.ptr, @intCast(buffer_name.len), &rendered, @intCast(rendered_len));
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Translate `stem_spawn_capture`'s negative return codes into a
/// human-readable buffer. Matches the contract in
/// `src/plugins/manager.zig:onWasmSpawnCapture`:
///   -1 permission denied   -2 bad command    -3 spawn failed
///   -4 timed out           -5 non-zero exit
fn showError(buffer_name: []const u8, code: i32) void {
    const msg: []const u8 = switch (code) {
        -1 => "git: blocked by plugin permissions (manifest is missing `spawn: [\"git\"]`).",
        -2 => "git: empty command.",
        -3 => "git: spawn failed — is `git` on PATH?",
        -4 => "git: command timed out.",
        -5 => "git: command exited non-zero (not a repository? upstream missing?).",
        else => "git: command failed.",
    };
    stem_log(2, msg.ptr, @intCast(msg.len));
    stem_open_buffer(buffer_name.ptr, @intCast(buffer_name.len), msg.ptr, @intCast(msg.len));
}

fn appendStr(s: []const u8) void {
    const remaining = rendered.len - rendered_len;
    if (remaining == 0) return;
    const n = @min(s.len, remaining);
    @memcpy(rendered[rendered_len .. rendered_len + n], s[0..n]);
    rendered_len += n;
}
