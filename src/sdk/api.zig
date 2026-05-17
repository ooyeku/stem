//! Plugin SDK (v3).
//!
//! Plugins write Zig code against this module. Every public function
//! ultimately bottoms out in a C ABI call exported by the stem binary
//! (see `plugins/abi.zig` for the boundary and `plugins/host_abi.zig`
//! for the host implementations).
//!
//! Major changes from v2:
//!
//!   * No `*PluginContext`. Plugins receive a `PluginHandle` (extern
//!     struct wrapping a u64) in `activate` and pass it back to every
//!     SDK call.
//!   * No Zig structs cross the boundary. All payloads are wire-encoded
//!     `PluginMessage` bytes.
//!   * Single inbound entry point: the plugin exports `handle_message`,
//!     which the SDK's `dispatch` helper turns into typed callbacks via
//!     the same correlation-ID `RequestTracker` we built earlier.
//!   * Module-globals (`local_registry`, `event_callbacks`, …) are
//!     organized into one `Sdk` struct, kept simple, and initialized
//!     lazily on first use.

const std = @import("std");

pub const abi = @import("../plugins/abi.zig");
pub const protocol = @import("../kernel/protocol.zig");
pub const interface = @import("../plugins/interface.zig");
pub const vaxis = @import("vaxis");
const RequestTracker = @import("../kernel/request_reply.zig").RequestTracker;

pub const PluginHandle = abi.PluginHandle;
pub const PluginInterface = abi.PluginInterface;
pub const PluginMessage = protocol.PluginMessage;

// ---------------------------------------------------------------------------
// Plugin entry-point builder.
//
// Plugin authors write:
//
//     export const plugin_entry: stem.PluginInterface = stem.createPlugin(.{
//         .name = "git",
//         .description = "Git integration",
//         .activate = onActivate,
//         .deactivate = onDeactivate,
//         .handle_message = onMessage,
//     });
// ---------------------------------------------------------------------------

pub const PluginConfig = struct {
    name: [:0]const u8,
    description: [:0]const u8,
    activate: ?*const fn (PluginHandle) callconv(.c) i32 = null,
    deactivate: ?*const fn (PluginHandle) callconv(.c) void = null,
    handle_message: ?*const fn (PluginHandle, msg_ptr: [*]const u8, msg_len: usize) callconv(.c) i32 = null,
    provides_commands: bool = false,
    provides_lsp: bool = false,
    provides_syntax: bool = false,
    extends_ui: bool = false,
    handles_files: bool = false,
};

pub fn createPlugin(comptime config: PluginConfig) PluginInterface {
    return .{
        .version = abi.ABI_VERSION,
        .name = config.name,
        .description = config.description,
        .activate = config.activate,
        .deactivate = config.deactivate,
        .handle_message = config.handle_message,
        .capabilities = .{
            .provides_commands = config.provides_commands,
            .provides_lsp = config.provides_lsp,
            .provides_syntax = config.provides_syntax,
            .extends_ui = config.extends_ui,
            .handles_files = config.handles_files,
        },
    };
}

// ---------------------------------------------------------------------------
// Per-plugin SDK state.
//
// One instance per loaded plugin in this process. Holds the handle the
// host assigned, the command/event/request callback registries, and an
// allocator scratched for outgoing messages. Kept as a module-global
// because each plugin .dylib is its own translation unit (so each
// plugin gets its own copy of this state — exactly what we want).
// ---------------------------------------------------------------------------

const SdkState = struct {
    /// Set on first `activate`-time call from the plugin's wrapper.
    handle: PluginHandle = .{ .id = 0 },
    /// Allocator for SDK bookkeeping (callback maps, dupe'd command IDs).
    /// Backed by `std.heap.page_allocator` so it has no dependency on
    /// any host-side allocator.
    allocator: std.mem.Allocator = std.heap.page_allocator,
    commands: std.StringHashMapUnmanaged(*const fn (PluginHandle) void) = .empty,
    events: std.AutoHashMapUnmanaged(protocol.PluginEvent, *const fn (PluginHandle, []const u8) void) = .empty,
    custom_events: std.StringHashMapUnmanaged(*const fn (PluginHandle, []const u8) void) = .empty,
    requests: ?RequestTracker = null,
};

var sdk: SdkState = .{};

/// Plugin's `activate` should call this first so subsequent SDK calls
/// know the handle to forward. Most plugin authors will not call it
/// directly — see the `defineActivate` helper below.
pub fn bind(handle: PluginHandle) void {
    sdk.handle = handle;
    if (sdk.requests == null) sdk.requests = RequestTracker.init(sdk.allocator);
}

/// Tear down SDK state on `deactivate`. Frees the callback maps.
pub fn unbind() void {
    var it1 = sdk.commands.keyIterator();
    while (it1.next()) |k| sdk.allocator.free(k.*);
    sdk.commands.deinit(sdk.allocator);
    sdk.commands = .empty;

    sdk.events.deinit(sdk.allocator);
    sdk.events = .empty;

    var it2 = sdk.custom_events.keyIterator();
    while (it2.next()) |k| sdk.allocator.free(k.*);
    sdk.custom_events.deinit(sdk.allocator);
    sdk.custom_events = .empty;

    if (sdk.requests) |*t| t.deinit();
    sdk.requests = null;
}

// ---------------------------------------------------------------------------
// Outbound helpers
// ---------------------------------------------------------------------------

fn sendCore(handle: PluginHandle, pm: PluginMessage) !void {
    const bytes = try pm.encode(sdk.allocator);
    defer sdk.allocator.free(bytes);
    const rc = abi.stem_send_to_core(handle, bytes.ptr, bytes.len);
    if (rc != 0) return error.SendFailed;
}

fn sendUI(handle: PluginHandle, pm: PluginMessage) !void {
    const bytes = try pm.encode(sdk.allocator);
    defer sdk.allocator.free(bytes);
    const rc = abi.stem_send_to_ui(handle, bytes.ptr, bytes.len);
    if (rc != 0) return error.SendFailed;
}

fn pluginIdSlice(handle: PluginHandle) []const u8 {
    return std.mem.span(abi.stem_plugin_id(handle));
}

pub fn log(handle: PluginHandle, comptime fmt: []const u8, args: anytype) void {
    logLevel(handle, @intFromEnum(abi.LogLevel.info), fmt, args);
}
pub fn logDebug(handle: PluginHandle, comptime fmt: []const u8, args: anytype) void {
    logLevel(handle, @intFromEnum(abi.LogLevel.debug), fmt, args);
}
pub fn logWarn(handle: PluginHandle, comptime fmt: []const u8, args: anytype) void {
    logLevel(handle, @intFromEnum(abi.LogLevel.warn), fmt, args);
}
pub fn logError(handle: PluginHandle, comptime fmt: []const u8, args: anytype) void {
    logLevel(handle, @intFromEnum(abi.LogLevel.err), fmt, args);
}
fn logLevel(handle: PluginHandle, level: u8, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    abi.stem_log(handle, level, msg.ptr, msg.len);
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

pub fn registerCommand(
    handle: PluginHandle,
    id: []const u8,
    title: []const u8,
    desc: []const u8,
    callback: *const fn (PluginHandle) void,
) !void {
    const id_dupe = try sdk.allocator.dupe(u8, id);
    errdefer sdk.allocator.free(id_dupe);
    try sdk.commands.put(sdk.allocator, id_dupe, callback);

    try sendCore(handle, .{
        .plugin_id = pluginIdSlice(handle),
        .message_type = .register_command,
        .payload = .{ .command_register = .{
            .id = id,
            .title = title,
            .description = desc,
        } },
    });
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

pub fn subscribeEvent(
    handle: PluginHandle,
    event: protocol.PluginEvent,
    callback: *const fn (PluginHandle, []const u8) void,
) !void {
    try sdk.events.put(sdk.allocator, event, callback);
    try sendCore(handle, .{
        .plugin_id = pluginIdSlice(handle),
        .message_type = .subscribe_event,
        .payload = .{ .event_subscribe = event },
    });
}

pub fn unsubscribeEvent(handle: PluginHandle, event: protocol.PluginEvent) !void {
    _ = sdk.events.remove(event);
    try sendCore(handle, .{
        .plugin_id = pluginIdSlice(handle),
        .message_type = .unsubscribe_event,
        .payload = .{ .event_unsubscribe = event },
    });
}

pub fn emitEvent(handle: PluginHandle, name: []const u8, data: []const u8) !void {
    try sendCore(handle, .{
        .plugin_id = pluginIdSlice(handle),
        .message_type = .emit_event,
        .payload = .{ .emit_event = .{ .name = name, .data = data } },
    });
}

pub fn subscribeCustomEvent(
    handle: PluginHandle,
    name: []const u8,
    callback: *const fn (PluginHandle, []const u8) void,
) !void {
    const name_dupe = try sdk.allocator.dupe(u8, name);
    errdefer sdk.allocator.free(name_dupe);
    try sdk.custom_events.put(sdk.allocator, name_dupe, callback);
    try subscribeEvent(handle, .custom_event, dispatchCustomEvent);
}

fn dispatchCustomEvent(handle: PluginHandle, data: []const u8) void {
    if (data.len < 4) return;
    const name_len = std.mem.readInt(u32, data[0..4], .big);
    if (data.len < 4 + name_len) return;
    const name = data[4..][0..name_len];
    const event_data = data[4 + name_len ..];
    if (sdk.custom_events.get(name)) |cb| cb(handle, event_data);
}

// ---------------------------------------------------------------------------
// Async request/reply (built on the RequestTracker we ship with stem)
// ---------------------------------------------------------------------------

const StateCallback = *const fn (PluginHandle, protocol.EditorStateView) void;
const ConfigCallback = *const fn (PluginHandle, []const u8, ?[]const u8) void;
const BufferContentCallback = *const fn (PluginHandle, u32, []const u8) void;
const PluginListCallback = *const fn (PluginHandle, []const u8) void;

const ReplyStash = union(enum) {
    state: protocol.EditorStateView,
    config: struct { key: []const u8, value: ?[]const u8 },
    buffer_content: struct { id: u32, content: []const u8 },
    plugin_list: []const u8,
};

fn stateTrampoline(user: *anyopaque, typed_cb: *anyopaque, payload: []const u8) void {
    _ = user;
    const cb: StateCallback = @ptrCast(@alignCast(typed_cb));
    const stash: *const ReplyStash = @ptrCast(@alignCast(payload.ptr));
    cb(sdk.handle, stash.state);
}
fn configTrampoline(user: *anyopaque, typed_cb: *anyopaque, payload: []const u8) void {
    _ = user;
    const cb: ConfigCallback = @ptrCast(@alignCast(typed_cb));
    const stash: *const ReplyStash = @ptrCast(@alignCast(payload.ptr));
    cb(sdk.handle, stash.config.key, stash.config.value);
}
fn bufferContentTrampoline(user: *anyopaque, typed_cb: *anyopaque, payload: []const u8) void {
    _ = user;
    const cb: BufferContentCallback = @ptrCast(@alignCast(typed_cb));
    const stash: *const ReplyStash = @ptrCast(@alignCast(payload.ptr));
    cb(sdk.handle, stash.buffer_content.id, stash.buffer_content.content);
}
fn pluginListTrampoline(user: *anyopaque, typed_cb: *anyopaque, payload: []const u8) void {
    _ = user;
    const cb: PluginListCallback = @ptrCast(@alignCast(typed_cb));
    const stash: *const ReplyStash = @ptrCast(@alignCast(payload.ptr));
    cb(sdk.handle, stash.plugin_list);
}

fn registerRequest(typed_cb: anytype, trampoline: anytype) !u64 {
    if (sdk.requests == null) sdk.requests = RequestTracker.init(sdk.allocator);
    return sdk.requests.?.register(
        @ptrCast(&sdk),
        @ptrCast(@constCast(typed_cb)),
        trampoline,
        5_000,
    );
}

pub fn requestEditorState(handle: PluginHandle, callback: StateCallback) !void {
    const id = try registerRequest(callback, stateTrampoline);
    try sendCore(handle, .{
        .plugin_id = pluginIdSlice(handle),
        .message_type = .get_state,
        .payload = .{ .state_request = {} },
        .correlation_id = id,
    });
}

pub fn getConfig(handle: PluginHandle, key: []const u8, callback: ConfigCallback) !void {
    const id = try registerRequest(callback, configTrampoline);
    try sendCore(handle, .{
        .plugin_id = pluginIdSlice(handle),
        .message_type = .get_config,
        .payload = .{ .config_get = key },
        .correlation_id = id,
    });
}

pub fn setConfig(handle: PluginHandle, key: []const u8, value: []const u8) !void {
    try sendCore(handle, .{
        .plugin_id = pluginIdSlice(handle),
        .message_type = .set_config,
        .payload = .{ .config_set = .{ .key = key, .value = value } },
    });
}

pub fn getBufferContent(handle: PluginHandle, callback: BufferContentCallback) !void {
    const id = try registerRequest(callback, bufferContentTrampoline);
    try sendCore(handle, .{
        .plugin_id = pluginIdSlice(handle),
        .message_type = .get_buffer_content,
        .payload = .{ .buffer_content_request = {} },
        .correlation_id = id,
    });
}

pub fn requestPluginList(handle: PluginHandle, callback: PluginListCallback) !void {
    const id = try registerRequest(callback, pluginListTrampoline);
    try sendCore(handle, .{
        .plugin_id = pluginIdSlice(handle),
        .message_type = .get_plugin_list,
        .payload = .{ .plugin_list_request = {} },
        .correlation_id = id,
    });
}

// ---------------------------------------------------------------------------
// Buffers / UI / Status / Panels — fire-and-forget
// ---------------------------------------------------------------------------

pub fn showNotification(handle: PluginHandle, level: protocol.NotificationLevel, message: []const u8) !void {
    try sendUI(handle, .{
        .plugin_id = pluginIdSlice(handle),
        .message_type = .show_notification,
        .payload = .{ .notification = .{ .level = level, .message = message } },
    });
}
pub fn showInfo(handle: PluginHandle, message: []const u8) !void {
    try showNotification(handle, .info, message);
}
pub fn showWarning(handle: PluginHandle, message: []const u8) !void {
    try showNotification(handle, .warning, message);
}
pub fn showError(handle: PluginHandle, message: []const u8) !void {
    try showNotification(handle, .err, message);
}

pub fn openBuffer(handle: PluginHandle, name: []const u8, content: []const u8) !void {
    try sendCore(handle, .{
        .plugin_id = pluginIdSlice(handle),
        .message_type = .open_buffer,
        .payload = .{ .buffer_open = .{ .name = name, .content = content } },
    });
}

pub fn switchBuffer(handle: PluginHandle, buffer_id: u32) !void {
    try sendCore(handle, .{
        .plugin_id = pluginIdSlice(handle),
        .message_type = .switch_buffer,
        .payload = .{ .buffer_switch = buffer_id },
    });
}

pub fn createStatusItem(
    handle: PluginHandle,
    id: []const u8,
    text: []const u8,
    alignment: protocol.StatusAlignment,
    priority: i8,
) !void {
    try sendCore(handle, .{
        .plugin_id = pluginIdSlice(handle),
        .message_type = .create_status_item,
        .payload = .{ .status_item_create = .{ .id = id, .text = text, .alignment = alignment, .priority = priority } },
    });
}

pub fn updateStatusItem(handle: PluginHandle, id: []const u8, text: []const u8) !void {
    try sendCore(handle, .{
        .plugin_id = pluginIdSlice(handle),
        .message_type = .update_status_item,
        .payload = .{ .status_item_update = .{ .id = id, .text = text } },
    });
}

pub fn destroyStatusItem(handle: PluginHandle, id: []const u8) !void {
    try sendCore(handle, .{
        .plugin_id = pluginIdSlice(handle),
        .message_type = .destroy_status_item,
        .payload = .{ .status_item_destroy = id },
    });
}

pub fn createPanel(
    handle: PluginHandle,
    id: []const u8,
    title: []const u8,
    position: protocol.PanelPosition,
    width_percent: u8,
) !void {
    try sendCore(handle, .{
        .plugin_id = pluginIdSlice(handle),
        .message_type = .create_panel,
        .payload = .{ .panel_create = .{ .id = id, .title = title, .position = position, .width_percent = width_percent } },
    });
}

pub fn updatePanelContent(
    handle: PluginHandle,
    id: []const u8,
    content: []const []const u8,
) !void {
    var total: usize = 0;
    for (content) |line| total += 4 + line.len;

    const serialized = try sdk.allocator.alloc(u8, total);
    defer sdk.allocator.free(serialized);
    var off: usize = 0;
    for (content) |line| {
        std.mem.writeInt(u32, serialized[off..][0..4], @intCast(line.len), .big);
        off += 4;
        @memcpy(serialized[off..][0..line.len], line);
        off += line.len;
    }

    try sendCore(handle, .{
        .plugin_id = pluginIdSlice(handle),
        .message_type = .update_panel_content,
        .payload = .{ .panel_content_update = .{ .id = id, .content = serialized } },
    });
}

pub fn destroyPanel(handle: PluginHandle, id: []const u8) !void {
    try sendCore(handle, .{
        .plugin_id = pluginIdSlice(handle),
        .message_type = .destroy_panel,
        .payload = .{ .panel_destroy = id },
    });
}

pub fn updatePanelScroll(handle: PluginHandle, id: []const u8, offset: u32) !void {
    try sendCore(handle, .{
        .plugin_id = pluginIdSlice(handle),
        .message_type = .update_panel_scroll,
        .payload = .{ .panel_scroll_update = .{ .id = id, .offset = offset } },
    });
}

pub fn executeCoreCommand(handle: PluginHandle, command_id: []const u8) !void {
    try sendCore(handle, .{
        .plugin_id = pluginIdSlice(handle),
        .message_type = .execute_core_command,
        .payload = .{ .command_execute = command_id },
    });
}

pub fn loadPlugin(handle: PluginHandle, path: []const u8) !void {
    try sendCore(handle, .{
        .plugin_id = pluginIdSlice(handle),
        .message_type = .load_plugin,
        .payload = .{ .plugin_load = path },
    });
}

pub fn unloadPlugin(handle: PluginHandle, id: []const u8) !void {
    try sendCore(handle, .{
        .plugin_id = pluginIdSlice(handle),
        .message_type = .unload_plugin,
        .payload = .{ .plugin_unload = id },
    });
}

pub fn decodePluginList(allocator: std.mem.Allocator, data: []const u8) ![]protocol.PluginInfo {
    if (data.len < 4) return error.InvalidMessage;
    const list_len = std.mem.readInt(u32, data[0..4], .big);
    var list = try allocator.alloc(protocol.PluginInfo, list_len);
    errdefer allocator.free(list);

    var offset: usize = 4;
    for (0..list_len) |i| {
        if (data.len < offset + 4) return error.InvalidMessage;
        const id_len = std.mem.readInt(u32, data[offset..][0..4], .big);
        offset += 4;
        if (data.len < offset + id_len) return error.InvalidMessage;
        const id = data[offset..][0..id_len];
        offset += id_len;
        if (data.len < offset + 4) return error.InvalidMessage;
        const name_len = std.mem.readInt(u32, data[offset..][0..4], .big);
        offset += 4;
        if (data.len < offset + name_len) return error.InvalidMessage;
        const name = data[offset..][0..name_len];
        offset += name_len;
        if (data.len < offset + 4) return error.InvalidMessage;
        const desc_len = std.mem.readInt(u32, data[offset..][0..4], .big);
        offset += 4;
        if (data.len < offset + desc_len) return error.InvalidMessage;
        const desc = data[offset..][0..desc_len];
        offset += desc_len;
        if (data.len < offset + 8) return error.InvalidMessage;
        const uptime = std.mem.readInt(u64, data[offset..][0..8], .big);
        offset += 8;
        if (data.len < offset + 4) return error.InvalidMessage;
        const widget_count = std.mem.readInt(u32, data[offset..][0..4], .big);
        offset += 4;
        if (data.len < offset + 1) return error.InvalidMessage;
        const is_running = data[offset] == 1;
        offset += 1;

        list[i] = .{
            .id = id,
            .name = name,
            .description = desc,
            .uptime_s = uptime,
            .widget_count = widget_count,
            .is_running = is_running,
        };
    }
    return list;
}

// ---------------------------------------------------------------------------
// Inbound dispatch.
//
// Plugins set this as their `handle_message`:
//
//     export fn on_message(h: PluginHandle, ptr: [*]const u8, len: usize) callconv(.c) i32 {
//         return stem.dispatch(h, ptr, len);
//     }
//
// We decode the PluginMessage, then dispatch to whichever local
// callback registered for it. Returns 0 on success, non-zero on
// "couldn't decode" (the host treats either as fire-and-forget).
// ---------------------------------------------------------------------------

pub fn dispatch(handle: PluginHandle, msg_ptr: [*]const u8, msg_len: usize) callconv(.c) i32 {
    sdk.handle = handle;
    if (sdk.requests == null) sdk.requests = RequestTracker.init(sdk.allocator);

    const bytes = msg_ptr[0..msg_len];
    const pm = PluginMessage.decode(bytes) catch return 1;

    switch (pm.message_type) {
        .execute_command => {
            const cmd_id = pm.payload.command_execute;
            if (sdk.commands.get(cmd_id)) |cb| cb(handle);
        },
        .event_notification => {
            const notif = pm.payload.event_notification;
            if (sdk.events.get(notif.event)) |cb| cb(handle, notif.data);
        },
        .state_response => {
            const stash = ReplyStash{ .state = pm.payload.state };
            _ = sdk.requests.?.deliver(pm.correlation_id, std.mem.asBytes(&stash));
        },
        .config_response => {
            const cfg = pm.payload.config_value;
            const stash = ReplyStash{ .config = .{ .key = cfg.key, .value = cfg.value } };
            _ = sdk.requests.?.deliver(pm.correlation_id, std.mem.asBytes(&stash));
        },
        .buffer_content_response => {
            const resp = pm.payload.buffer_content_response;
            const stash = ReplyStash{ .buffer_content = .{ .id = resp.id, .content = resp.content } };
            _ = sdk.requests.?.deliver(pm.correlation_id, std.mem.asBytes(&stash));
        },
        .get_plugin_list_response => {
            const stash = ReplyStash{ .plugin_list = pm.payload.plugin_list_data };
            _ = sdk.requests.?.deliver(pm.correlation_id, std.mem.asBytes(&stash));
        },
        else => {},
    }
    return 0;
}
