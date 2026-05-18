//! Plugin manager dashboard (wasm runtime, Phase 4 migration).
//!
//! The dylib version requested the live plugin list from core via
//! the request/reply ABI (`requestPluginList`). That async pattern
//! isn't yet plumbed into the wasm runtime, so we instead shell out
//! to the `stem plugin list` CLI — which renders exactly the same
//! information, executes in <50ms on any reasonable install, and
//! has no async machinery.
//!
//! `plugin.load` / `plugin.unload` similarly delegate to the CLI;
//! they're now mostly tutorial commands that show the right
//! invocation.

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

var scratch: [64 * 1024]u8 = undefined;

// Host-dispatch scratch region — see echo-wasm for the protocol.
var stem_scratch: [4096]u8 = undefined;
export fn __stem_scratch_addr() i32 {
    return @intCast(@intFromPtr(&stem_scratch));
}
export fn __stem_scratch_size() i32 {
    return @intCast(stem_scratch.len);
}

const CMD_STATS = "plugin-manager.stats";
const CMD_LOAD = "plugin.load";
const CMD_UNLOAD = "plugin.unload";

const Cmd = struct { id: []const u8, title: []const u8, desc: []const u8 };
const COMMANDS = [_]Cmd{
    .{ .id = CMD_STATS, .title = "[Plugin Manager] Show Stats", .desc = "Display the installed plugin list" },
    .{ .id = CMD_LOAD, .title = "[Plugin] Load", .desc = "Reminder: install plugins via `stem plugin install <path>`" },
    .{ .id = CMD_UNLOAD, .title = "[Plugin] Unload", .desc = "Reminder: remove plugins via `stem plugin remove <name>`" },
};

const LOAD_HINT =
    \\Plugin loading is now managed through the `stem plugin` CLI:
    \\
    \\    stem plugin install <path-to-plugin-dir>
    \\    stem plugin list
    \\    stem plugin remove <name>
    \\    stem plugin test <path>
    \\
    \\See `stem plugin --help` for the full surface.
;

const UNLOAD_HINT =
    \\Plugin removal:
    \\
    \\    stem plugin remove <name>
    \\
    \\Restart stem to drop the running instance.
;

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
    const ready = "plugin_manager plugin (wasm): ready";
    stem_log(1, ready.ptr, ready.len);
}

export fn handle_command(id_ptr: [*]const u8, id_len: i32) void {
    const id = id_ptr[0..@intCast(id_len)];

    if (std.mem.eql(u8, id, CMD_STATS)) {
        const written = stem_spawn_capture(
            "stem plugin list".ptr,
            "stem plugin list".len,
            &scratch,
            @intCast(scratch.len),
        );
        if (written <= 0) {
            const fallback = "Run `stem plugin list` from your shell to see installed plugins.";
            stem_open_buffer(
                "[Plugin Manager]".ptr,
                "[Plugin Manager]".len,
                fallback.ptr,
                @intCast(fallback.len),
            );
            return;
        }
        stem_open_buffer(
            "[Plugin Manager]".ptr,
            "[Plugin Manager]".len,
            &scratch,
            @intCast(@as(usize, @intCast(written))),
        );
        return;
    }

    if (std.mem.eql(u8, id, CMD_LOAD)) {
        stem_open_buffer(
            "[Plugin Load]".ptr,
            "[Plugin Load]".len,
            LOAD_HINT.ptr,
            LOAD_HINT.len,
        );
        return;
    }

    if (std.mem.eql(u8, id, CMD_UNLOAD)) {
        stem_open_buffer(
            "[Plugin Unload]".ptr,
            "[Plugin Unload]".len,
            UNLOAD_HINT.ptr,
            UNLOAD_HINT.len,
        );
        return;
    }
}
