//! Reference WebAssembly plugin for stem (Phase 2 ABI).
//!
//! Built with: `zig build-exe -O ReleaseSmall \
//!     -target wasm32-freestanding -fno-entry \
//!     --export=activate --export=handle_command \
//!     bundled/plugins/echo-wasm/src/main.zig`
//!
//! Imports two symbols from the host:
//!   - `env.stem_log(level: i32, msg_ptr: i32, msg_len: i32)`
//!   - `env.stem_register_command(id_ptr, id_len, title_ptr, title_len, desc_ptr, desc_len)`
//!
//! Exports:
//!   - `activate()` — called once on load; we use it to register one
//!     command via `stem_register_command`.
//!   - `handle_command(id_ptr: i32, id_len: i32)` — called by host
//!     when the user runs a command we registered.

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

const CMD_ID = "echo-wasm.hello";
const CMD_TITLE = "[Echo-WASM] Hello";
const CMD_DESC = "Log a greeting from the wasm echo plugin";

const READY_MSG = "echo-wasm plugin: ready (from inside the wasm sandbox)";
const HELLO_MSG = "echo-wasm plugin: hello from a wasm-sandboxed plugin";

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
    }
}
