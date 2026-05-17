//! Plugin API schema (work-in-progress, Phase 1).
//!
//! This module is the **single source of truth** for the wire protocol
//! between stem and out-of-process / WASM plugins. The existing
//! in-process .dylib SDK (Phase 0) uses `protocol.PluginMessage`
//! directly; the wire envelopes here are designed to converge on the
//! same semantics so Phase 2 (WASM) and Phase 3 (process) can share
//! one schema.
//!
//! Design choice: JSON-RPC 2.0 over stdio for process plugins, with
//! identical request/notification names mapped to host imports for
//! WASM plugins. One catalog → two transports.

const std = @import("std");

pub const SCHEMA_VERSION: u32 = 1;

/// Catalog of host capabilities a plugin can call. Each entry maps to
/// a JSON-RPC method name; the WASM transport gets the same name as
/// an import. Phase 1 implementation will codegen Zig bindings from
/// this catalog; today it's prose.
pub const HostMethod = enum {
    // Lifecycle
    plugin_register_command,
    plugin_subscribe_event,
    plugin_unsubscribe_event,
    plugin_emit_event,
    plugin_log,

    // Editor state (request/reply)
    editor_get_state,
    editor_get_buffer_content,
    editor_get_config,
    editor_set_config,
    editor_get_plugin_list,

    // Editor mutations (fire-and-forget)
    editor_open_buffer,
    editor_switch_buffer,
    editor_execute_command,
    editor_show_notification,

    // UI extensions
    ui_create_status_item,
    ui_update_status_item,
    ui_destroy_status_item,
    ui_create_panel,
    ui_update_panel_content,
    ui_update_panel_scroll,
    ui_destroy_panel,

    // Plugin lifecycle (admin)
    plugin_load,
    plugin_unload,

    // OS capabilities (require manifest permissions)
    process_spawn, // permission: spawn:<allowlist>
    fs_read, // permission: filesystem:read:<path>
    fs_write, // permission: filesystem:write:<path>
};

/// Notifications stem sends to plugins (events).
pub const HostNotification = enum {
    buffer_changed,
    buffer_switched,
    cursor_moved,
    mode_changed,
    file_opened,
    file_saved,
    custom_event,
    command_invoked,
    config_changed,
    shutdown,
};

/// JSON-RPC envelope. Process plugins emit/consume this; WASM plugins
/// see the same fields as host import parameters.
pub const Envelope = struct {
    jsonrpc: []const u8 = "2.0",
    /// Present on requests/replies, absent on notifications.
    id: ?u64 = null,
    /// Present on requests/notifications.
    method: ?[]const u8 = null,
    /// Present on requests/notifications.
    params: ?std.json.Value = null,
    /// Present on replies.
    result: ?std.json.Value = null,
    /// Present on error replies.
    @"error": ?ErrorBody = null,

    pub const ErrorBody = struct {
        code: i32,
        message: []const u8,
        data: ?std.json.Value = null,
    };
};

/// Standard JSON-RPC error codes plus stem-specific ones.
pub const ErrorCode = enum(i32) {
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
    internal_error = -32603,
    // stem-specific (-32000 to -32099 reserved for server-defined errors per spec)
    permission_denied = -32000,
    plugin_panicked = -32001,
    request_timed_out = -32002,
    feature_not_yet_implemented = -32003,
};
