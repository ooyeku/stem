//! Git plugin (wasm runtime, Phase 4 migration).
//!
//! Migrated from the legacy in-process .dylib plugin. The wasm
//! version exposes the same three commands and runs `git` via the
//! host's `stem_spawn_capture` import, which checks the manifest's
//! `permissions.spawn` allowlist before forking.
//!
//! What's lost moving from .dylib → wasm (intentional):
//!   - The live `Git: <branch>` status item. Wasm plugins don't have
//!     an `on_buffer_switched` inbound dispatch yet, so we can't
//!     refresh the indicator. Coming back in Phase 4+ via a wasm
//!     event-dispatch ABI.
//!   - The async `requestEditorState` callback. Not needed by the
//!     three commands anyway.

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

/// Scratch region for capturing `git` stdout. Sized generously so
/// `git diff` on medium-sized changes fits without truncation; if a
/// repo's diff exceeds this, we just show the leading bytes.
var scratch: [256 * 1024]u8 = undefined;

// Host-dispatch scratch region — see echo-wasm for the protocol.
var stem_scratch: [4096]u8 = undefined;
export fn __stem_scratch_addr() i32 {
    return @intCast(@intFromPtr(&stem_scratch));
}
export fn __stem_scratch_size() i32 {
    return @intCast(stem_scratch.len);
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
