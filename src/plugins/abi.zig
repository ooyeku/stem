//! Stable C-ABI boundary between stem and plugins.
//!
//! This is the **only** file plugins are allowed to depend on for cross-
//! boundary types. Every public type here is `extern`. Every function is
//! `callconv(.c)`. No `std.mem.Allocator`, no `std.AutoHashMapUnmanaged`,
//! no `vigil.Inbox`, no Zig slices crossing the boundary as struct fields.
//!
//! Background — why this exists:
//!
//! Up through v2 of the plugin ABI, stem passed a `*PluginContext`
//! across the .dylib boundary. `PluginContext` was a regular Zig struct
//! whose fields included `std.mem.Allocator`, an unmanaged hashmap, a
//! `vigil.compat.Mutex`, and (in v2) a `RequestTracker`. Zig's struct
//! layout is **not stable across translation units that differ in their
//! dependency graphs**. Stem compiled `PluginContext` as part of its main
//! module; each plugin compiled the same source file as part of the SDK
//! module. The two compilations occasionally agreed on layout — and
//! occasionally disagreed by ~16 bytes — producing silent segfaults the
//! moment a plugin read `ctx.to_core`.
//!
//! v3 fixes this by construction:
//!
//!   - Plugin receives a `PluginHandle` (an extern struct wrapping a u64).
//!   - All cross-boundary types are `extern struct` or primitives.
//!   - All cross-boundary functions are `extern "c" fn ... callconv(.c)`.
//!   - Everything else — Vigil inboxes, allocators, message routing — is
//!     a host-side detail keyed off the handle. The plugin can't see them.
//!
//! The wire protocol (`protocol.PluginMessage`) still crosses the
//! boundary as a byte buffer. Each side runs its own copy of the encode/
//! decode function; the bytes are stable because the encoders write
//! fixed layouts manually.

const std = @import("std");

/// Plugin ABI version. Bump and update the changelog when ANY symbol
/// signature in this file changes, OR when the wire protocol's stable
/// envelope changes. Plugin manager rejects plugins whose stamped
/// version doesn't match.
///
/// Changelog:
///   1 → 2: PluginMessage gained `correlation_id: u64` on the wire.
///   2 → 3: Full ABI overhaul. Plugins receive a `PluginHandle` (u64)
///          instead of a `*PluginContext`. Everything crosses via either
///          (a) C-ABI host accessors, or (b) wire-encoded bytes. No Zig
///          structs cross by pointer. Permanently fixes the v1/v2 ABI-
///          drift segfaults.
pub const ABI_VERSION: u32 = 3;

/// Opaque identifier for a plugin instance. The host maps `id` to its
/// internal `*Plugin` in a registry guarded by a mutex; plugins must
/// only treat the value as opaque and pass it back to host functions.
///
/// `extern struct` wrapping a u64 (rather than a bare u64) so future
/// versions can add fields with predictable padding behaviour, while
/// today's layout is the same as the underlying integer.
pub const PluginHandle = extern struct {
    id: u64,
};

/// Capability bitfield. Used by the plugin loader to enable / restrict
/// host services. Kept as discrete bools for readability rather than a
/// packed integer.
pub const Capabilities = extern struct {
    provides_commands: bool = false,
    provides_lsp: bool = false,
    provides_syntax: bool = false,
    extends_ui: bool = false,
    handles_files: bool = false,
    _reserved: [3]u8 = .{ 0, 0, 0 },
};

/// Severity for `stem_log`. Mirrors the existing logger levels.
pub const LogLevel = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,
};

/// Status codes returned by host accessors. Plugins should check for
/// `.ok`; everything else means the call had no effect.
pub const Status = enum(i32) {
    ok = 0,
    invalid_handle = -1,
    closed = -2,
    out_of_memory = -3,
    invalid_payload = -4,
    not_found = -5,
};

/// The single `extern struct` plugins must expose via `plugin_entry`.
///
/// All function pointers use `callconv(.c)`, take a `PluginHandle`, and
/// receive byte buffers (not Zig slices) for any payload.
///
///   - `activate`: called once after load, before any messages are
///     delivered. Plugin sets up its world. Return 0 = ok, non-zero =
///     load failure.
///   - `handle_message`: called for every inbound message (commands,
///     events, request replies). `msg_bytes` is the wire-encoded
///     `protocol.PluginMessage`. Plugin must decode it and dispatch.
///   - `deactivate`: called once on shutdown / unload. Plugin frees
///     its resources. Best-effort: host may force-unload if the plugin
///     misbehaves.
pub const PluginInterface = extern struct {
    /// Must equal `ABI_VERSION` of the host. Mismatch → load rejected.
    version: u32 = ABI_VERSION,
    /// Null-terminated, statically owned. Read once, never freed.
    name: [*:0]const u8,
    description: [*:0]const u8,
    activate: ?*const fn (PluginHandle) callconv(.c) i32 = null,
    handle_message: ?*const fn (PluginHandle, msg_ptr: [*]const u8, msg_len: usize) callconv(.c) i32 = null,
    deactivate: ?*const fn (PluginHandle) callconv(.c) void = null,
    capabilities: Capabilities = .{},
};

// ---------------------------------------------------------------------------
// Host-exported functions (the "host imports" from the plugin's POV).
//
// Stem's binary defines these with `export fn …`. The dynamic linker
// resolves the plugin's undefined references at `dlopen` time. Plugins
// MUST NOT redefine these.
//
// All functions take the handle first, all sizes are `usize`, and all
// buffers are caller-owned for the duration of the call.
// ---------------------------------------------------------------------------

/// Send a wire-encoded `protocol.PluginMessage` to core. Used by
/// `register_command`, `subscribe_event`, `get_config`, request
/// initiation, etc. — all of which build a `PluginMessage` and ship it.
///
/// Returns a `Status` (cast from i32). The host copies the bytes
/// before returning; the plugin may free / reuse `payload_ptr`
/// immediately after.
pub extern "c" fn stem_send_to_core(
    handle: PluginHandle,
    payload_ptr: [*]const u8,
    payload_len: usize,
) callconv(.c) i32;

/// Same as `stem_send_to_core` but targets the UI thread. Used by
/// notifications, panel renders, etc.
pub extern "c" fn stem_send_to_ui(
    handle: PluginHandle,
    payload_ptr: [*]const u8,
    payload_len: usize,
) callconv(.c) i32;

/// Convenience: log a single line. The host routes this to its own
/// logger so plugin logs share the stem log file. Fire-and-forget;
/// errors are swallowed.
pub extern "c" fn stem_log(
    handle: PluginHandle,
    level: u8,
    msg_ptr: [*]const u8,
    msg_len: usize,
) callconv(.c) void;

/// Returns the plugin's stable ID as a null-terminated string. The
/// pointer is valid for the lifetime of the plugin. Plugins use this
/// to populate the `plugin_id` field of outgoing `PluginMessage`s.
pub extern "c" fn stem_plugin_id(handle: PluginHandle) callconv(.c) [*:0]const u8;
