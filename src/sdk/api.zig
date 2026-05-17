const std = @import("std");
const context = @import("../plugins/context.zig");
pub const protocol = @import("../kernel/protocol.zig");
const interface = @import("../plugins/interface.zig");
pub const vaxis = @import("vaxis");

pub const PluginContext = context.PluginContext;
pub const PluginMessage = protocol.PluginMessage;

pub const PluginConfig = struct {
    name: [:0]const u8,
    description: [:0]const u8,
    init: ?*const fn (ctx: *PluginContext) i32 = null,
    deinit: ?*const fn (ctx: *PluginContext) void = null,
    handleMessage: ?*const fn (ctx: *PluginContext, msg: *const PluginMessage) i32 = null,
    keybindingHandler: ?*const fn (ctx: *PluginContext, key: *const vaxis.Key) i32 = null,
    provides_commands: bool = false,
    provides_lsp: bool = false,
    provides_syntax: bool = false,
    extends_ui: bool = false,
    handles_files: bool = false,
};

pub fn createPlugin(comptime config: PluginConfig) interface.PluginInterface {
    return .{
        .name = config.name,
        .description = config.description,
        .init = if (config.init) |f| @ptrCast(f) else null,
        .deinit = if (config.deinit) |f| @ptrCast(f) else null,
        .handleMessage = if (config.handleMessage) |f| @ptrCast(f) else null,
        .capabilities = .{
            .provides_commands = config.provides_commands,
            .provides_lsp = config.provides_lsp,
            .provides_syntax = config.provides_syntax,
            .extends_ui = config.extends_ui or (config.keybindingHandler != null),
            .handles_files = config.handles_files,
        },
    };
}

pub fn log(ctx: *PluginContext, comptime fmt: []const u8, args: anytype) void {
    logLevel(ctx, 1, fmt, args);
}

pub fn logDebug(ctx: *PluginContext, comptime fmt: []const u8, args: anytype) void {
    logLevel(ctx, 0, fmt, args);
}

pub fn logWarn(ctx: *PluginContext, comptime fmt: []const u8, args: anytype) void {
    logLevel(ctx, 2, fmt, args);
}

pub fn logError(ctx: *PluginContext, comptime fmt: []const u8, args: anytype) void {
    logLevel(ctx, 3, fmt, args);
}

fn logLevel(ctx: *PluginContext, level: u8, comptime fmt: []const u8, args: anytype) void {
    var msg_buf: [1024]u8 = undefined;
    const message = std.fmt.bufPrint(&msg_buf, fmt, args) catch return;

    const msg = protocol.PluginMessage{
        .plugin_id = ctx.plugin_id,
        .message_type = .plugin_log,
        .payload = .{ .plugin_log = .{ .level = level, .message = message } },
    };

    const encoded = msg.encode(ctx.allocator) catch return;
    defer ctx.allocator.free(encoded);

    ctx.to_core.send(encoded) catch {};
}

var local_registry: std.StringHashMap(*const fn (ctx: *PluginContext) void) = undefined;
var registry_initialized = false;

fn ensureRegistry(allocator: std.mem.Allocator) !void {
    if (!registry_initialized) {
        local_registry = std.StringHashMap(*const fn (ctx: *PluginContext) void).init(allocator);
        registry_initialized = true;
    }
}

pub fn registerCommand(ctx: *PluginContext, id: []const u8, title: []const u8, desc: []const u8, callback: *const fn (ctx: *PluginContext) void) !void {
    try ensureRegistry(ctx.allocator);
    const id_dupe = try ctx.allocator.dupe(u8, id);
    try local_registry.put(id_dupe, callback);

    const msg = protocol.PluginMessage{
        .plugin_id = ctx.plugin_id,
        .message_type = .register_command,
        .payload = .{ .command_register = .{
            .id = id,
            .title = title,
            .description = desc,
        } },
    };
    try ctx.sendToCore(msg);
}

pub fn handleStandardMessages(ctx: *PluginContext, msg: *const PluginMessage) bool {
    switch (msg.message_type) {
        .execute_command => {
            if (registry_initialized) {
                const cmd_id = msg.payload.command_execute;
                if (local_registry.get(cmd_id)) |callback| {
                    callback(ctx);
                    return true;
                } else {
                    log(ctx, "Unknown command: {s}", .{cmd_id});
                }
            }
            return true;
        },
        .state_response => {
            // Encode the EditorStateView so the typed trampoline can read
            // it back. The tracker is type-erased: it only knows about
            // `[]const u8` payloads. We give it the encoded view.
            const stash = ResponseStash{ .state = msg.payload.state };
            _ = ctx.requests.deliver(msg.correlation_id, std.mem.asBytes(&stash));
            return true;
        },
        .event_notification => {
            if (event_registry_initialized) {
                const notif = msg.payload.event_notification;
                if (event_callbacks.get(notif.event)) |callback| {
                    callback(ctx, notif.data);
                }
            }
            return true;
        },
        .config_response => {
            const cfg = msg.payload.config_value;
            const stash = ResponseStash{ .config = .{ .key = cfg.key, .value = cfg.value } };
            _ = ctx.requests.deliver(msg.correlation_id, std.mem.asBytes(&stash));
            return true;
        },
        .buffer_content_response => {
            const resp = msg.payload.buffer_content_response;
            const stash = ResponseStash{ .buffer_content = .{ .id = resp.id, .content = resp.content } };
            _ = ctx.requests.deliver(msg.correlation_id, std.mem.asBytes(&stash));
            return true;
        },
        .get_plugin_list_response => {
            const stash = ResponseStash{ .plugin_list = msg.payload.plugin_list_data };
            _ = ctx.requests.deliver(msg.correlation_id, std.mem.asBytes(&stash));
            return true;
        },
        else => return false,
    }
}

/// Transport for typed replies through the type-erased `RequestTracker`.
/// We stack-allocate one, take its bytes, and the trampoline casts back.
/// All fields borrow from the message buffer that's still alive during
/// `handleStandardMessages` — the trampolines must consume them before
/// returning.
const ResponseStash = union(enum) {
    state: protocol.EditorStateView,
    config: struct { key: []const u8, value: ?[]const u8 },
    buffer_content: struct { id: u32, content: []const u8 },
    plugin_list: []const u8,
};

pub fn deinitSdk(ctx: *PluginContext) void {
    if (registry_initialized) {
        var it = local_registry.keyIterator();
        while (it.next()) |key| {
            ctx.allocator.free(key.*);
        }
        local_registry.deinit();
        registry_initialized = false;
    }
    if (event_registry_initialized) {
        event_callbacks.deinit();
        event_registry_initialized = false;
    }
    if (custom_event_registry_initialized) {
        var it = custom_event_callbacks.keyIterator();
        while (it.next()) |key| {
            ctx.allocator.free(key.*);
        }
        custom_event_callbacks.deinit();
        custom_event_registry_initialized = false;
    }
}

// -----------------------------------------------------------------------------
// Async request/reply via the per-context RequestTracker.
//
// Each `request*` function:
//   1. Registers (ctx, typed_cb, trampoline) with the tracker, getting
//      a unique u64 correlation ID.
//   2. Builds the outgoing PluginMessage with that `correlation_id`.
//   3. Sends it to core.
//
// When core's reply comes back, `handleStandardMessages` calls
// `tracker.deliver(correlation_id, &stash)`. The trampoline then casts
// the stash and calls the original typed callback.
//
// Multiple in-flight requests of the same kind now coexist; replies
// no longer race for a global single-slot callback.
// -----------------------------------------------------------------------------

const StateCallback = *const fn (*PluginContext, protocol.EditorStateView) void;
const ConfigCallback = *const fn (*PluginContext, []const u8, ?[]const u8) void;
const BufferContentCallback = *const fn (*PluginContext, u32, []const u8) void;
const PluginListCallback = *const fn (*PluginContext, []const u8) void;

fn stateTrampoline(user_data: *anyopaque, typed_cb: *anyopaque, payload: []const u8) void {
    const ctx: *PluginContext = @ptrCast(@alignCast(user_data));
    const cb: StateCallback = @ptrCast(@alignCast(typed_cb));
    const stash: *const ResponseStash = @ptrCast(@alignCast(payload.ptr));
    cb(ctx, stash.state);
}

fn configTrampoline(user_data: *anyopaque, typed_cb: *anyopaque, payload: []const u8) void {
    const ctx: *PluginContext = @ptrCast(@alignCast(user_data));
    const cb: ConfigCallback = @ptrCast(@alignCast(typed_cb));
    const stash: *const ResponseStash = @ptrCast(@alignCast(payload.ptr));
    cb(ctx, stash.config.key, stash.config.value);
}

fn bufferContentTrampoline(user_data: *anyopaque, typed_cb: *anyopaque, payload: []const u8) void {
    const ctx: *PluginContext = @ptrCast(@alignCast(user_data));
    const cb: BufferContentCallback = @ptrCast(@alignCast(typed_cb));
    const stash: *const ResponseStash = @ptrCast(@alignCast(payload.ptr));
    cb(ctx, stash.buffer_content.id, stash.buffer_content.content);
}

fn pluginListTrampoline(user_data: *anyopaque, typed_cb: *anyopaque, payload: []const u8) void {
    const ctx: *PluginContext = @ptrCast(@alignCast(user_data));
    const cb: PluginListCallback = @ptrCast(@alignCast(typed_cb));
    const stash: *const ResponseStash = @ptrCast(@alignCast(payload.ptr));
    cb(ctx, stash.plugin_list);
}

pub fn requestEditorState(ctx: *PluginContext, callback: StateCallback) !void {
    const id = try ctx.requests.register(
        @ptrCast(ctx),
        @ptrCast(@constCast(callback)),
        stateTrampoline,
        5_000, // 5 s timeout — core is local so this is generous
    );
    const msg = protocol.PluginMessage{
        .plugin_id = ctx.plugin_id,
        .message_type = .get_state,
        .payload = .{ .state_request = {} },
        .correlation_id = id,
    };
    try ctx.sendToCore(msg);
}

var event_callbacks: std.AutoHashMap(protocol.PluginEvent, *const fn (*PluginContext, []const u8) void) = undefined;
var event_registry_initialized = false;

fn ensureEventRegistry(allocator: std.mem.Allocator) void {
    if (!event_registry_initialized) {
        event_callbacks = std.AutoHashMap(protocol.PluginEvent, *const fn (*PluginContext, []const u8) void).init(allocator);
        event_registry_initialized = true;
    }
}

pub fn subscribeEvent(ctx: *PluginContext, event: protocol.PluginEvent, callback: *const fn (*PluginContext, []const u8) void) !void {
    ensureEventRegistry(ctx.allocator);
    try event_callbacks.put(event, callback);

    const msg = protocol.PluginMessage{
        .plugin_id = ctx.plugin_id,
        .message_type = .subscribe_event,
        .payload = .{ .event_subscribe = event },
    };
    try ctx.sendToCore(msg);
}

pub fn unsubscribeEvent(ctx: *PluginContext, event: protocol.PluginEvent) !void {
    if (event_registry_initialized) {
        _ = event_callbacks.remove(event);
    }

    const msg = protocol.PluginMessage{
        .plugin_id = ctx.plugin_id,
        .message_type = .unsubscribe_event,
        .payload = .{ .event_unsubscribe = event },
    };
    try ctx.sendToCore(msg);
}

var custom_event_callbacks: std.StringHashMap(*const fn (*PluginContext, []const u8) void) = undefined;
var custom_event_registry_initialized = false;

fn ensureCustomEventRegistry(allocator: std.mem.Allocator) !void {
    if (!custom_event_registry_initialized) {
        custom_event_callbacks = std.StringHashMap(*const fn (*PluginContext, []const u8) void).init(allocator);
        custom_event_registry_initialized = true;
    }
}

pub fn emitEvent(ctx: *PluginContext, name: []const u8, data: []const u8) !void {
    const msg = protocol.PluginMessage{
        .plugin_id = ctx.plugin_id,
        .message_type = .emit_event,
        .payload = .{ .emit_event = .{ .name = name, .data = data } },
    };
    try ctx.sendToCore(msg);
}

pub fn subscribeCustomEvent(ctx: *PluginContext, name: []const u8, callback: *const fn (*PluginContext, []const u8) void) !void {
    try ensureCustomEventRegistry(ctx.allocator);
    const name_dupe = try ctx.allocator.dupe(u8, name);
    try custom_event_callbacks.put(name_dupe, callback);

    try subscribeEvent(ctx, .custom_event, handleCustomEventDispatch);
}

fn handleCustomEventDispatch(ctx: *PluginContext, data: []const u8) void {
    if (!custom_event_registry_initialized) return;

    if (data.len < 4) return;
    const name_len = std.mem.readInt(u32, data[0..4], .big);
    if (data.len < 4 + name_len) return;
    const name = data[4..][0..name_len];
    const event_data = data[4 + name_len ..];

    if (custom_event_callbacks.get(name)) |callback| {
        callback(ctx, event_data);
    }
}

pub fn setConfig(ctx: *PluginContext, key: []const u8, value: []const u8) !void {
    const msg = protocol.PluginMessage{
        .plugin_id = ctx.plugin_id,
        .message_type = .set_config,
        .payload = .{ .config_set = .{ .key = key, .value = value } },
    };
    try ctx.sendToCore(msg);
}

pub fn getConfig(ctx: *PluginContext, key: []const u8, callback: ConfigCallback) !void {
    const id = try ctx.requests.register(
        @ptrCast(ctx),
        @ptrCast(@constCast(callback)),
        configTrampoline,
        5_000,
    );
    const msg = protocol.PluginMessage{
        .plugin_id = ctx.plugin_id,
        .message_type = .get_config,
        .payload = .{ .config_get = key },
        .correlation_id = id,
    };
    try ctx.sendToCore(msg);
}

pub fn showNotification(ctx: *PluginContext, level: protocol.NotificationLevel, message: []const u8) !void {
    const msg = protocol.PluginMessage{
        .plugin_id = ctx.plugin_id,
        .message_type = .show_notification,
        .payload = .{ .notification = .{ .level = level, .message = message } },
    };
    try ctx.sendToUI(msg);
}

pub fn showInfo(ctx: *PluginContext, message: []const u8) !void {
    try showNotification(ctx, .info, message);
}

pub fn showWarning(ctx: *PluginContext, message: []const u8) !void {
    try showNotification(ctx, .warning, message);
}

pub fn showError(ctx: *PluginContext, message: []const u8) !void {
    try showNotification(ctx, .err, message);
}

pub fn openBuffer(ctx: *PluginContext, name: []const u8, content: []const u8) !void {
    const msg = protocol.PluginMessage{
        .plugin_id = ctx.plugin_id,
        .message_type = .open_buffer,
        .payload = .{ .buffer_open = .{ .name = name, .content = content } },
    };
    try ctx.sendToCore(msg);
}

pub fn getBufferContent(ctx: *PluginContext, callback: BufferContentCallback) !void {
    const id = try ctx.requests.register(
        @ptrCast(ctx),
        @ptrCast(@constCast(callback)),
        bufferContentTrampoline,
        5_000,
    );
    const msg = protocol.PluginMessage{
        .plugin_id = ctx.plugin_id,
        .message_type = .get_buffer_content,
        .payload = .{ .buffer_content_request = {} },
        .correlation_id = id,
    };
    try ctx.sendToCore(msg);
}

pub fn switchBuffer(ctx: *PluginContext, buffer_id: u32) !void {
    const msg = protocol.PluginMessage{
        .plugin_id = ctx.plugin_id,
        .message_type = .switch_buffer,
        .payload = .{ .buffer_switch = buffer_id },
    };
    try ctx.sendToCore(msg);
}

pub fn requestPluginList(ctx: *PluginContext, callback: PluginListCallback) !void {
    const id = try ctx.requests.register(
        @ptrCast(ctx),
        @ptrCast(@constCast(callback)),
        pluginListTrampoline,
        5_000,
    );
    const msg = protocol.PluginMessage{
        .plugin_id = ctx.plugin_id,
        .message_type = .get_plugin_list,
        .payload = .{ .plugin_list_request = {} },
        .correlation_id = id,
    };
    try ctx.sendToCore(msg);
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

pub fn loadPlugin(ctx: *PluginContext, path: []const u8) !void {
    const msg = protocol.PluginMessage{
        .plugin_id = ctx.plugin_id,
        .message_type = .load_plugin,
        .payload = .{ .plugin_load = path },
    };
    try ctx.sendToCore(msg);
}

pub fn unloadPlugin(ctx: *PluginContext, id: []const u8) !void {
    const msg = protocol.PluginMessage{
        .plugin_id = ctx.plugin_id,
        .message_type = .unload_plugin,
        .payload = .{ .plugin_unload = id },
    };
    try ctx.sendToCore(msg);
}

pub fn createStatusItem(
    ctx: *PluginContext,
    id: []const u8,
    text: []const u8,
    alignment: protocol.StatusAlignment,
    priority: i8,
) !void {
    const msg = protocol.PluginMessage{
        .plugin_id = ctx.plugin_id,
        .message_type = .create_status_item,
        .payload = .{ .status_item_create = .{
            .id = id,
            .text = text,
            .alignment = alignment,
            .priority = priority,
        } },
    };
    try ctx.sendToCore(msg);
}

pub fn updateStatusItem(ctx: *PluginContext, id: []const u8, text: []const u8) !void {
    const msg = protocol.PluginMessage{
        .plugin_id = ctx.plugin_id,
        .message_type = .update_status_item,
        .payload = .{ .status_item_update = .{
            .id = id,
            .text = text,
        } },
    };
    try ctx.sendToCore(msg);
}

pub fn destroyStatusItem(ctx: *PluginContext, id: []const u8) !void {
    const msg = protocol.PluginMessage{
        .plugin_id = ctx.plugin_id,
        .message_type = .destroy_status_item,
        .payload = .{ .status_item_destroy = id },
    };
    try ctx.sendToCore(msg);
}

pub fn createPanel(
    ctx: *PluginContext,
    id: []const u8,
    title: []const u8,
    position: protocol.PanelPosition,
    width_percent: u8,
) !void {
    const msg = protocol.PluginMessage{
        .plugin_id = ctx.plugin_id,
        .message_type = .create_panel,
        .payload = .{ .panel_create = .{
            .id = id,
            .title = title,
            .position = position,
            .width_percent = width_percent,
        } },
    };
    try ctx.sendToCore(msg);
}

pub fn updatePanelContent(
    ctx: *PluginContext,
    id: []const u8,
    content: []const []const u8,
) !void {
    var total_size: usize = 0;
    for (content) |line| {
        total_size += 4 + line.len;
    }

    const serialized = try ctx.allocator.alloc(u8, total_size);
    defer ctx.allocator.free(serialized);

    var offset: usize = 0;
    for (content) |line| {
        std.mem.writeInt(u32, serialized[offset..][0..4], @intCast(line.len), .big);
        offset += 4;
        @memcpy(serialized[offset..][0..line.len], line);
        offset += line.len;
    }

    const msg = protocol.PluginMessage{
        .plugin_id = ctx.plugin_id,
        .message_type = .update_panel_content,
        .payload = .{ .panel_content_update = .{
            .id = id,
            .content = serialized,
        } },
    };
    try ctx.sendToCore(msg);
}

pub fn destroyPanel(ctx: *PluginContext, id: []const u8) !void {
    const msg = protocol.PluginMessage{
        .plugin_id = ctx.plugin_id,
        .message_type = .destroy_panel,
        .payload = .{ .panel_destroy = id },
    };
    try ctx.sendToCore(msg);
}

pub fn updatePanelScroll(ctx: *PluginContext, id: []const u8, offset: u32) !void {
    const msg = protocol.PluginMessage{
        .plugin_id = ctx.plugin_id,
        .message_type = .update_panel_scroll,
        .payload = .{ .panel_scroll_update = .{
            .id = id,
            .offset = offset,
        } },
    };
    try ctx.sendToCore(msg);
}

pub fn executeCoreCommand(ctx: *PluginContext, command_id: []const u8) !void {
    const msg = protocol.PluginMessage{
        .plugin_id = ctx.plugin_id,
        .message_type = .execute_core_command,
        .payload = .{ .command_execute = command_id },
    };
    try ctx.sendToCore(msg);
}
