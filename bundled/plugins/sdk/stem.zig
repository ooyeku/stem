//! Small Zig SDK for Stem WebAssembly plugins.
//!
//! Add this file as a Zig module named `stem`, then import it from a
//! wasm plugin with:
//!
//!     const stem = @import("stem");
//!
//! The SDK keeps the raw `env.stem_*` imports in one place and exports
//! the scratch buffer the host uses for command/event dispatch.

const std = @import("std");

pub const Level = enum(i32) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,
};

pub const Alignment = enum(i32) {
    left = 0,
    center = 1,
    right = 2,
};

pub const PanelPosition = enum(i32) {
    left = 0,
    right = 1,
    bottom = 2,
};

pub const Command = struct {
    id: []const u8,
    title: []const u8,
    description: []const u8 = "",
};

pub const SpawnOptions = struct {
    cmd: []const u8,
    cwd: ?[]const u8 = null,
    timeout_ms: u32 = 0,
    include_stderr: bool = false,
};

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
extern "env" fn stem_spawn_capture2(
    cmd_ptr: [*]const u8,
    cmd_len: i32,
    cwd_ptr: [*]const u8,
    cwd_len: i32,
    timeout_ms: i32,
    include_stderr: i32,
    out_ptr: [*]u8,
    out_max: i32,
) i32;
extern "env" fn stem_subscribe_event(topic_ptr: [*]const u8, topic_len: i32) i32;
extern "env" fn stem_read_file(
    path_ptr: [*]const u8,
    path_len: i32,
    out_ptr: [*]u8,
    out_max: i32,
) i32;
extern "env" fn stem_write_file(
    path_ptr: [*]const u8,
    path_len: i32,
    content_ptr: [*]const u8,
    content_len: i32,
) i32;
extern "env" fn stem_set_status_item(
    id_ptr: [*]const u8,
    id_len: i32,
    text_ptr: [*]const u8,
    text_len: i32,
    alignment: i32,
    priority: i32,
) void;
extern "env" fn stem_clear_status_item(id_ptr: [*]const u8, id_len: i32) void;
extern "env" fn stem_set_panel(
    id_ptr: [*]const u8,
    id_len: i32,
    title_ptr: [*]const u8,
    title_len: i32,
    content_ptr: [*]const u8,
    content_len: i32,
    position: i32,
    width_percent: i32,
) void;
extern "env" fn stem_clear_panel(id_ptr: [*]const u8, id_len: i32) void;
extern "env" fn stem_get_buffer_content(out_ptr: [*]u8, out_max: i32) i32;
extern "env" fn stem_get_buffer_path(out_ptr: [*]u8, out_max: i32) i32;
extern "env" fn stem_get_plugin_dashboard_json(out_ptr: [*]u8, out_max: i32) i32;
extern "env" fn stem_get_plugin_dashboard_report(out_ptr: [*]u8, out_max: i32) i32;
extern "env" fn stem_storage_read(
    key_ptr: [*]const u8,
    key_len: i32,
    out_ptr: [*]u8,
    out_max: i32,
) i32;
extern "env" fn stem_storage_write(
    key_ptr: [*]const u8,
    key_len: i32,
    content_ptr: [*]const u8,
    content_len: i32,
) i32;
extern "env" fn stem_load_plugin(name_ptr: [*]const u8, name_len: i32) i32;
extern "env" fn stem_unload_plugin(name_ptr: [*]const u8, name_len: i32) i32;

pub fn fromRaw(ptr: [*]const u8, len: i32) []const u8 {
    if (len <= 0) return "";
    return ptr[0..@intCast(len)];
}

pub fn log(level: Level, msg: []const u8) void {
    stem_log(@intFromEnum(level), msg.ptr, @intCast(msg.len));
}

pub fn notify(level: Level, msg: []const u8) void {
    stem_show_notification(@intFromEnum(level), msg.ptr, @intCast(msg.len));
}

pub fn registerCommand(command: Command) void {
    stem_register_command(
        command.id.ptr,
        @intCast(command.id.len),
        command.title.ptr,
        @intCast(command.title.len),
        command.description.ptr,
        @intCast(command.description.len),
    );
}

pub fn registerCommands(comptime commands: anytype) void {
    inline for (commands) |command| registerCommand(command);
}

pub fn openBuffer(name: []const u8, content: []const u8) void {
    stem_open_buffer(name.ptr, @intCast(name.len), content.ptr, @intCast(content.len));
}

pub fn spawnCapture(cmd: []const u8, out: []u8) i32 {
    return stem_spawn_capture(cmd.ptr, @intCast(cmd.len), out.ptr, @intCast(out.len));
}

pub fn spawnCaptureEx(opts: SpawnOptions, out: []u8) i32 {
    const cwd = opts.cwd orelse "";
    return stem_spawn_capture2(
        opts.cmd.ptr,
        @intCast(opts.cmd.len),
        cwd.ptr,
        @intCast(cwd.len),
        @intCast(opts.timeout_ms),
        if (opts.include_stderr) 1 else 0,
        out.ptr,
        @intCast(out.len),
    );
}

pub fn subscribeEvent(topic: []const u8) i32 {
    return stem_subscribe_event(topic.ptr, @intCast(topic.len));
}

pub fn readFile(path: []const u8, out: []u8) i32 {
    return stem_read_file(path.ptr, @intCast(path.len), out.ptr, @intCast(out.len));
}

pub fn writeFile(path: []const u8, content: []const u8) i32 {
    return stem_write_file(path.ptr, @intCast(path.len), content.ptr, @intCast(content.len));
}

pub fn setStatusItem(id: []const u8, text: []const u8, alignment: Alignment, priority: i8) void {
    stem_set_status_item(
        id.ptr,
        @intCast(id.len),
        text.ptr,
        @intCast(text.len),
        @intFromEnum(alignment),
        @as(i32, priority),
    );
}

pub fn clearStatusItem(id: []const u8) void {
    stem_clear_status_item(id.ptr, @intCast(id.len));
}

pub fn setPanel(
    id: []const u8,
    title: []const u8,
    content: []const u8,
    position: PanelPosition,
    width_percent: u8,
) void {
    stem_set_panel(
        id.ptr,
        @intCast(id.len),
        title.ptr,
        @intCast(title.len),
        content.ptr,
        @intCast(content.len),
        @intFromEnum(position),
        width_percent,
    );
}

pub fn clearPanel(id: []const u8) void {
    stem_clear_panel(id.ptr, @intCast(id.len));
}

pub fn activeBufferContent(out: []u8) i32 {
    return stem_get_buffer_content(out.ptr, @intCast(out.len));
}

pub fn activeBufferPath(out: []u8) i32 {
    return stem_get_buffer_path(out.ptr, @intCast(out.len));
}

pub fn pluginDashboardJson(out: []u8) i32 {
    return stem_get_plugin_dashboard_json(out.ptr, @intCast(out.len));
}

pub fn pluginDashboardReport(out: []u8) i32 {
    return stem_get_plugin_dashboard_report(out.ptr, @intCast(out.len));
}

pub fn storageRead(key: []const u8, out: []u8) i32 {
    return stem_storage_read(key.ptr, @intCast(key.len), out.ptr, @intCast(out.len));
}

pub fn storageWrite(key: []const u8, content: []const u8) i32 {
    return stem_storage_write(key.ptr, @intCast(key.len), content.ptr, @intCast(content.len));
}

pub fn storageReadU32(key: []const u8, default_value: u32) u32 {
    var buf: [32]u8 = undefined;
    const n = storageRead(key, &buf);
    if (n <= 0) return default_value;
    return std.fmt.parseInt(u32, std.mem.trim(u8, buf[0..@intCast(n)], " \t\r\n"), 10) catch default_value;
}

pub fn storageWriteU32(key: []const u8, value: u32) void {
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return;
    _ = storageWrite(key, text);
}

pub fn loadPlugin(name: []const u8) i32 {
    return stem_load_plugin(name.ptr, @intCast(name.len));
}

pub fn unloadPlugin(name: []const u8) i32 {
    return stem_unload_plugin(name.ptr, @intCast(name.len));
}
