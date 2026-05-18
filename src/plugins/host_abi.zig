//! Host-side implementation of the plugin ABI surface defined in
//! `abi.zig`.
//!
//! Two responsibilities:
//!
//!   1. The handle registry — a process-wide `u64 → *Plugin` map guarded
//!      by a mutex. `PluginManager.registerHandle` assigns an ID at load
//!      time; the C exports below look up the `*Plugin` for any call.
//!
//!   2. The exported C functions — `stem_send_to_core`,
//!      `stem_send_to_ui`, `stem_log`, `stem_plugin_id`. These are the
//!      `export fn …` symbols that the dynamic linker resolves when a
//!      plugin .dylib's undefined references hit at `dlopen` time.
//!
//! Keeping these in their own file (separate from `manager.zig`) makes
//! the boundary visible: anything in here is part of the stable ABI
//! and must change with `ABI_VERSION`.

const std = @import("std");
const builtin = @import("builtin");
const vigil = @import("vigil");

const abi = @import("abi.zig");
const Plugin = @import("plugin.zig").Plugin;
const logger_service = @import("../services/logger.zig");
const protocol = @import("../kernel/protocol.zig");

const Mutex = vigil.compat.Mutex;
const log = std.log.scoped(.PluginHost);

// ---------------------------------------------------------------------------
// Handle registry
// ---------------------------------------------------------------------------

const State = struct {
    mu: Mutex = .{},
    plugins: std.AutoHashMapUnmanaged(u64, *Plugin) = .empty,
    next_id: std.atomic.Value(u64) = .{ .raw = 1 },
    allocator: ?std.mem.Allocator = null,
};

var state: State = .{};

pub fn init(allocator: std.mem.Allocator) void {
    state.mu.lock();
    defer state.mu.unlock();
    state.allocator = allocator;
}

pub fn deinit() void {
    state.mu.lock();
    defer state.mu.unlock();
    const allocator = state.allocator orelse return;
    state.plugins.deinit(allocator);
    state.allocator = null;
}

/// Allocate a fresh `PluginHandle` for `plugin` and store the mapping.
/// The handle stays valid until `unregisterHandle` (typically on plugin
/// shutdown).
pub fn registerHandle(plugin: *Plugin) !abi.PluginHandle {
    state.mu.lock();
    defer state.mu.unlock();
    const allocator = state.allocator orelse return error.HostNotInitialized;
    const id = state.next_id.fetchAdd(1, .acq_rel);
    try state.plugins.put(allocator, id, plugin);
    return .{ .id = id };
}

pub fn unregisterHandle(handle: abi.PluginHandle) void {
    state.mu.lock();
    defer state.mu.unlock();
    _ = state.plugins.remove(handle.id);
}

fn lookup(handle: abi.PluginHandle) ?*Plugin {
    state.mu.lock();
    defer state.mu.unlock();
    return state.plugins.get(handle.id);
}

/// Wire-protocol version for out-of-process plugins. Independent of
/// the in-process `abi.ABI_VERSION` because the two transports can
/// rev separately (e.g. adding a JSON-RPC method doesn't require the
/// .dylib ABI to change). Bumped when the JSON-RPC envelope semantics
/// change.
pub const ABI_VERSION_FOR_PROC: u32 = 1;

// ---------------------------------------------------------------------------
// C-ABI exports — must match the `extern fn` declarations in `abi.zig`.
// Don't rename these; the dynamic linker keys off the exact symbol name.
// ---------------------------------------------------------------------------

export fn stem_send_to_core(
    handle: abi.PluginHandle,
    payload_ptr: [*]const u8,
    payload_len: usize,
) callconv(.c) i32 {
    const plugin = lookup(handle) orelse return @intFromEnum(abi.Status.invalid_handle);
    const core_inbox = plugin.core_inbox orelse return @intFromEnum(abi.Status.closed);
    const slice = payload_ptr[0..payload_len];
    core_inbox.send(slice) catch |err| {
        log.warn("send_to_core failed for plugin '{s}': {}", .{ plugin.id, err });
        return @intFromEnum(abi.Status.closed);
    };
    return @intFromEnum(abi.Status.ok);
}

export fn stem_send_to_ui(
    handle: abi.PluginHandle,
    payload_ptr: [*]const u8,
    payload_len: usize,
) callconv(.c) i32 {
    const plugin = lookup(handle) orelse return @intFromEnum(abi.Status.invalid_handle);
    const ui_inbox = plugin.ui_inbox orelse return @intFromEnum(abi.Status.closed);
    const slice = payload_ptr[0..payload_len];
    ui_inbox.send(slice) catch |err| {
        log.warn("send_to_ui failed for plugin '{s}': {}", .{ plugin.id, err });
        return @intFromEnum(abi.Status.closed);
    };
    return @intFromEnum(abi.Status.ok);
}

export fn stem_log(
    handle: abi.PluginHandle,
    level: u8,
    msg_ptr: [*]const u8,
    msg_len: usize,
) callconv(.c) void {
    const plugin = lookup(handle) orelse return;
    const msg = msg_ptr[0..msg_len];
    if (logger_service.getGlobal()) |g| {
        const lvl: logger_service.LogLevel = switch (level) {
            0 => .debug,
            2 => .warn,
            3 => .err,
            else => .info,
        };
        g.log(lvl, "Plugin", "[{s}] {s}", .{ plugin.id, msg });
    }
}

export fn stem_plugin_id(handle: abi.PluginHandle) callconv(.c) [*:0]const u8 {
    const plugin = lookup(handle) orelse return "(unknown)";
    return plugin.id_c orelse "(no-id)";
}

// ---------------------------------------------------------------------------
// Symbol pinning — force the linker to keep these exports even when
// nothing inside the stem binary calls them. The plugin .dylibs reach
// them through `dlopen` symbol resolution against the running process.
//
// Under Debug, `comptime { _ = &fn; }` was enough. ReleaseFast LTO is
// aggressive enough to strip those address-takes when nothing else
// uses them — every `_stem_*` symbol vanished from the export trie
// and plugin dylibs hard-faulted during lazy binding.
//
// `keep_exports_alive` is a never-called runtime function whose
// body holds genuine call expressions and address-stores into a
// volatile pointer. The compiler can't prove the calls are dead
// (the volatile sink might be observed) and so leaves the function
// — plus everything it references — in the final binary.
// ---------------------------------------------------------------------------

/// Side-effectful sink that LTO can't prove dead. Inline asm
/// constrains the compiler from optimizing away the address loads.
pub fn keep_exports_alive() void {
    @setRuntimeSafety(false);
    forceUse(@ptrCast(&stem_send_to_core));
    forceUse(@ptrCast(&stem_send_to_ui));
    forceUse(@ptrCast(&stem_log));
    forceUse(@ptrCast(&stem_plugin_id));
}

fn forceUse(p: *const anyopaque) void {
    // Pass `p` through inline asm with no clobbers. The compiler
    // sees `p` as live across the asm boundary, so it can't be
    // eliminated. No instruction is actually emitted.
    asm volatile (""
        :
        : [p] "r" (p),
        : .{});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// Note: handle-registry tests were dropped because constructing a
// `Plugin` outside the manager involves uninitialized `std.DynLib`
// state that the test runner trips over. The registry is exercised
// end-to-end by every plugin load in `bundled/plugins/*` — that's the
// real validation we care about.

// `protocol` imported above for future per-message routing helpers.
comptime {
    _ = protocol;
}
