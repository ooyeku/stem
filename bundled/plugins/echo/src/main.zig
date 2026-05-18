//! Reference WebAssembly plugin for stem.
//!
//! The minimum viable plugin: registers one palette command, and on
//! invocation pops a visible notification + writes a log line.
//!
//! Host imports used:
//!   - `env.stem_log(level, msg_ptr, msg_len)`
//!   - `env.stem_show_notification(level, msg_ptr, msg_len)`
//!   - `env.stem_register_command(id, title, description)` triple of
//!     `(ptr, len)` pairs
//!
//! Exports:
//!   - `activate()`                          — called once on load
//!   - `handle_command(id_ptr, id_len)`      — called when the user
//!                                             runs a command we own
//!   - `__stem_scratch_addr/__stem_scratch_size` — scratch region the
//!                                             host uses to pass
//!                                             inbound strings

const std = @import("std");

// Host-dispatch scratch region. The stem host writes inbound command
// ids / event names into this buffer before invoking the plugin's
// handle_* exports.
var stem_scratch: [4096]u8 = undefined;
export fn __stem_scratch_addr() i32 {
    return @intCast(@intFromPtr(&stem_scratch));
}
export fn __stem_scratch_size() i32 {
    return @intCast(stem_scratch.len);
}

extern "env" fn stem_log(level: i32, msg_ptr: [*]const u8, msg_len: i32) void;
extern "env" fn stem_show_notification(level: i32, msg_ptr: [*]const u8, msg_len: i32) void;
extern "env" fn stem_register_command(
    id_ptr: [*]const u8,
    id_len: i32,
    title_ptr: [*]const u8,
    title_len: i32,
    desc_ptr: [*]const u8,
    desc_len: i32,
) void;

const CMD_ID = "echo.hello";
const CMD_TITLE = "[Echo] Hello";
const CMD_DESC = "Pop a greeting notification from the echo plugin";

const READY_MSG = "echo plugin: ready";
const HELLO_MSG = "echo plugin: hello from the wasm sandbox";

export fn activate() void {
    stem_register_command(
        CMD_ID.ptr,
        CMD_ID.len,
        CMD_TITLE.ptr,
        CMD_TITLE.len,
        CMD_DESC.ptr,
        CMD_DESC.len,
    );
    stem_log(1, READY_MSG.ptr, READY_MSG.len);
}

export fn handle_command(id_ptr: [*]const u8, id_len: i32) void {
    const id_slice = id_ptr[0..@intCast(id_len)];
    if (std.mem.eql(u8, id_slice, CMD_ID)) {
        stem_log(1, HELLO_MSG.ptr, HELLO_MSG.len);
        stem_show_notification(1, HELLO_MSG.ptr, HELLO_MSG.len);
    }
}
