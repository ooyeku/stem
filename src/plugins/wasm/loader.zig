//! WebAssembly plugin loader.
//!
//! Manages the lifecycle of a wasm plugin:
//!   1. Read the `.wasm` file pointed at by the manifest's `entry`.
//!   2. Decode it with our pure-Zig interpreter.
//!   3. Bind the `env.stem_*` host imports.
//!   4. Instantiate the module (runs no code).
//!   5. Call the exported `activate` function — plugin uses it to
//!      register commands by calling back into `env.stem_register_command`.
//!   6. Whenever a registered command fires, host calls the exported
//!      `handle_command(id_ptr, id_len)` function.
//!   7. On shutdown, call `deactivate` if exported.
//!
//! The wasm plugin's import schema mirrors the JSON-RPC method names
//! exec plugins use, but with pointer+length arguments instead of JSON
//! envelopes. Each host import marshals linear-memory bytes into Zig
//! slices, then routes to the same subsystems (command registry,
//! logger, etc.) the exec plugins use.

const std = @import("std");
const vigil = @import("vigil");
const log = std.log.scoped(.WasmPlugin);

const interp = @import("interpreter.zig");
const Mutex = vigil.compat.Mutex;

/// Caller-supplied hooks. Mirror `process_loader.Callbacks` so the
/// PluginManager can register either runtime through one code path.
pub const Callbacks = struct {
    user_data: *anyopaque,
    /// Plugin called `stem_log(level, msg)`.
    on_log: *const fn (user_data: *anyopaque, plugin_id: []const u8, level: u8, message: []const u8) void,
    /// Plugin called `stem_register_command(id, title, description)`.
    on_register_command: *const fn (user_data: *anyopaque, plugin_id: []const u8, id: []const u8, title: []const u8, description: []const u8) void,
    /// Plugin called `stem_show_notification(level, msg)`.
    on_show_notification: *const fn (user_data: *anyopaque, plugin_id: []const u8, level: u8, message: []const u8) void,
    /// Plugin called `stem_open_buffer(name, content)`. Host should
    /// surface the content in a new virtual buffer.
    on_open_buffer: *const fn (user_data: *anyopaque, plugin_id: []const u8, name: []const u8, content: []const u8) void,
    /// Plugin called `stem_spawn_capture(cmd, out_buf)`. Host parses
    /// the command line, enforces manifest spawn permissions, runs
    /// the process synchronously, and writes captured stdout into
    /// `out_buf`. Returns the byte count, or negative on denial /
    /// error.
    ///   -1: spawn permission denied
    ///   -2: argv empty / malformed
    ///   -3: child failed to spawn (e.g. ENOENT)
    ///   -4: timed out
    ///   -5: child exited with non-zero status (stdout still written)
    on_spawn_capture: *const fn (user_data: *anyopaque, plugin_id: []const u8, opts: SpawnOpts, out_buf: []u8) i32,
    /// Plugin called `stem_subscribe_event(topic)`. Host checks the
    /// manifest's `permissions.events` allowlist and on success
    /// records the plugin in its `event_subscribers` map; subsequent
    /// `broadcastEvent` calls dispatch to the plugin's `handle_event`
    /// export. Returns 0 on success, non-zero on denial.
    on_subscribe_event: *const fn (user_data: *anyopaque, plugin_id: []const u8, topic: []const u8) i32,
    /// Plugin called `stem_read_file(path, out_buf)`. Permission
    /// gated on `permissions.filesystem` entries (prefix `read:`).
    /// Returns bytes written, or negative on denial / failure.
    on_read_file: *const fn (user_data: *anyopaque, plugin_id: []const u8, path: []const u8, out_buf: []u8) i32,
    /// Plugin called `stem_write_file(path, content)`. Permission
    /// gated on `permissions.filesystem` entries (prefix `write:`).
    /// Returns 0 on success, negative on denial / failure.
    on_write_file: *const fn (user_data: *anyopaque, plugin_id: []const u8, path: []const u8, content: []const u8) i32,
    /// Plugin called `stem_set_status_item(id, text, alignment, priority)`.
    /// Adds or updates a status-bar widget owned by the plugin.
    on_set_status_item: *const fn (user_data: *anyopaque, plugin_id: []const u8, id: []const u8, text: []const u8, alignment: u8, priority: i8) void,
    /// Plugin called `stem_clear_status_item(id)`.
    on_clear_status_item: *const fn (user_data: *anyopaque, plugin_id: []const u8, id: []const u8) void,
    /// Plugin called `stem_set_panel(id, title, content, position, width_percent)`.
    /// `content` is the raw panel body (NL-separated lines accepted).
    on_set_panel: *const fn (user_data: *anyopaque, plugin_id: []const u8, id: []const u8, title: []const u8, content: []const u8, position: u8, width_percent: u8) void,
    /// Plugin called `stem_clear_panel(id)`.
    on_clear_panel: *const fn (user_data: *anyopaque, plugin_id: []const u8, id: []const u8) void,
    /// Plugin called `stem_get_buffer_content(out_buf)`. Host copies
    /// the active buffer's text into `out_buf` (truncating as
    /// needed) and returns the byte count, or negative on error.
    on_get_buffer_content: *const fn (user_data: *anyopaque, plugin_id: []const u8, out_buf: []u8) i32,
    /// Plugin called `stem_get_buffer_path(out_buf)`. Host writes the
    /// active buffer's file path (or its virtual name) and returns
    /// the byte count.
    on_get_buffer_path: *const fn (user_data: *anyopaque, plugin_id: []const u8, out_buf: []u8) i32,
    /// Plugin called `stem_load_plugin(name)`. Routes to
    /// `PluginManager.loadPluginByName`.
    on_load_plugin: *const fn (user_data: *anyopaque, plugin_id: []const u8, name: []const u8) i32,
    /// Plugin called `stem_unload_plugin(name)`.
    on_unload_plugin: *const fn (user_data: *anyopaque, plugin_id: []const u8, name: []const u8) i32,
};

pub const State = enum { loaded, activated, deactivated, failed };

/// Options for `stem_spawn_capture` — a forward-compatible shape so we
/// can extend the wasm host import without churning every call site.
pub const SpawnOpts = struct {
    /// Single command line; tokenized on whitespace.
    cmd: []const u8,
    /// Working directory; null inherits the editor's cwd.
    cwd: ?[]const u8 = null,
    /// Hard wall-clock cap in milliseconds. 0 = no limit.
    timeout_ms: u32 = 0,
    /// If true, write captured stderr after stdout (separated by a
    /// single NUL byte) into `out_buf` so plugins can show both.
    include_stderr: bool = false,
};

pub const WasmPlugin = struct {
    allocator: std.mem.Allocator,
    /// Plugin id — duped, owned.
    plugin_id: []const u8,
    /// Decoded module. Owned.
    module: interp.Module,
    /// Live instance. Owned.
    instance: interp.Instance,
    callbacks: Callbacks,
    state: State = .loaded,
    /// Mutex guarding `instance` invocations. Plugins are not
    /// re-entrant; the host serializes calls.
    invoke_mu: Mutex = .{},

    pub fn deinit(self: *WasmPlugin) void {
        // Best-effort: call `deactivate` if it exists and we haven't
        // already failed.
        if (self.state == .activated) {
            if (self.module.findExport("deactivate", .func)) |idx| {
                var results: [4]u64 = undefined;
                _ = interp.invoke(&self.instance, idx, &.{}, results[0..0]) catch {};
            }
        }
        self.instance.deinit();
        self.module.deinit();
        self.allocator.free(self.plugin_id);
    }

    /// Read a NUL-or-length-paired wasm linear-memory string into a
    /// host slice. Caller does NOT own — the returned slice is a view
    /// into the wasm instance memory and is invalidated by the next
    /// `memory.grow`.
    fn readWasmStr(self: *WasmPlugin, ptr: u32, len: u32) ![]const u8 {
        return self.instance.slice(ptr, len);
    }

    /// Invoke the plugin's exported `activate` function.
    pub fn activate(self: *WasmPlugin) !void {
        const idx = self.module.findExport("activate", .func) orelse {
            log.warn("plugin '{s}' missing 'activate' export", .{self.plugin_id});
            self.state = .failed;
            return error.MissingExport;
        };
        self.invoke_mu.lock();
        defer self.invoke_mu.unlock();
        var results: [4]u64 = undefined;
        const ft = self.instance.funcType(idx) orelse return error.InvalidModule;
        const rc = interp.invoke(&self.instance, idx, &.{}, results[0..ft.results.len]) catch |err| {
            log.err("plugin '{s}' activate trapped: {s}", .{ self.plugin_id, @errorName(err) });
            self.state = .failed;
            return err;
        };
        _ = rc;
        if (ft.results.len > 0 and results[0] != 0) {
            log.warn("plugin '{s}' activate returned {d}", .{ self.plugin_id, results[0] });
        }
        self.state = .activated;
    }

    /// Invoke the plugin's `handle_command(id_ptr, id_len)` export.
    /// Copies the command id into the plugin's `__stem_scratch`
    /// region.
    pub fn dispatchCommand(self: *WasmPlugin, command_id: []const u8) !void {
        const idx = self.module.findExport("handle_command", .func) orelse return error.MissingExport;
        self.invoke_mu.lock();
        defer self.invoke_mu.unlock();

        const scratch = try self.scratchSlice();
        if (command_id.len > scratch.len) return error.ScratchTooSmall;
        @memcpy(scratch[0..command_id.len], command_id);
        const scratch_ptr = self.scratchPtr() catch unreachable;

        var results: [4]u64 = undefined;
        _ = interp.invoke(
            &self.instance,
            idx,
            &.{ @as(u64, scratch_ptr), @as(u64, command_id.len) },
            results[0..0],
        ) catch |err| {
            log.err("plugin '{s}' handle_command trapped: {s}", .{ self.plugin_id, @errorName(err) });
            return err;
        };
    }

    /// Invoke the plugin's optional `handle_event(topic_ptr, topic_len,
    /// data_ptr, data_len)` export. Silently no-ops if the plugin
    /// doesn't export the function (most plugins ignore events).
    pub fn dispatchEvent(self: *WasmPlugin, topic: []const u8, data: []const u8) !void {
        const idx = self.module.findExport("handle_event", .func) orelse return;
        self.invoke_mu.lock();
        defer self.invoke_mu.unlock();

        const scratch = try self.scratchSlice();
        const total = topic.len + data.len;
        if (total > scratch.len) return error.ScratchTooSmall;
        @memcpy(scratch[0..topic.len], topic);
        @memcpy(scratch[topic.len..total], data);
        const scratch_ptr = self.scratchPtr() catch unreachable;
        const topic_ptr = scratch_ptr;
        const data_ptr = scratch_ptr + @as(u32, @intCast(topic.len));

        var results: [4]u64 = undefined;
        _ = interp.invoke(
            &self.instance,
            idx,
            &.{
                @as(u64, topic_ptr),
                @as(u64, @intCast(topic.len)),
                @as(u64, data_ptr),
                @as(u64, @intCast(data.len)),
            },
            results[0..0],
        ) catch |err| {
            log.err("plugin '{s}' handle_event trapped: {s}", .{ self.plugin_id, @errorName(err) });
            return err;
        };
    }

    /// Resolve the plugin's host-dispatch scratch region. Plugins
    /// MUST export a `__stem_scratch_addr() -> i32` function that
    /// returns the address of a dedicated buffer in linear memory.
    /// They MAY also export `__stem_scratch_size() -> i32` returning
    /// the buffer's length; if absent we default to 4 KiB. Linker-
    /// assigned global addresses can't be propagated as `const`
    /// values at Zig comptime, so we use a function call instead.
    fn scratchPtr(self: *WasmPlugin) !u32 {
        const idx = self.module.findExport("__stem_scratch_addr", .func) orelse {
            log.warn("plugin '{s}' missing __stem_scratch_addr export", .{self.plugin_id});
            return error.MissingScratch;
        };
        var results: [1]u64 = undefined;
        _ = try interp.invoke(&self.instance, idx, &.{}, &results);
        return @truncate(results[0]);
    }

    fn scratchSize(self: *WasmPlugin) u32 {
        const idx = self.module.findExport("__stem_scratch_size", .func) orelse return 4 * 1024;
        var results: [1]u64 = undefined;
        _ = interp.invoke(&self.instance, idx, &.{}, &results) catch return 4 * 1024;
        return @truncate(results[0]);
    }

    fn scratchSlice(self: *WasmPlugin) ![]u8 {
        const ptr = try self.scratchPtr();
        const len = self.scratchSize();
        if (@as(u64, ptr) + len > self.instance.memory.len) return error.OutOfBounds;
        return self.instance.memory[ptr .. ptr + len];
    }
};

/// Load + instantiate a wasm plugin from an absolute path. Caller
/// takes ownership of the returned `*WasmPlugin`. The plugin's id is
/// duplicated from `plugin_id` so the caller can free the original.
pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    plugin_id: []const u8,
    wasm_path: []const u8,
    callbacks: Callbacks,
) !*WasmPlugin {
    const file = try std.Io.Dir.openFileAbsolute(io, wasm_path, .{});
    defer file.close(io);
    const size = try file.length(io);
    if (size > 16 * 1024 * 1024) return error.InvalidModule;
    const bytes = try allocator.alloc(u8, @intCast(size));
    defer allocator.free(bytes);
    _ = try file.readPositionalAll(io, bytes, 0);

    var module = try interp.decode(allocator, bytes);
    errdefer module.deinit();

    const wp = try allocator.create(WasmPlugin);
    errdefer allocator.destroy(wp);

    const id_dup = try allocator.dupe(u8, plugin_id);
    errdefer allocator.free(id_dup);

    // We need to thread the WasmPlugin* into host imports. The
    // interpreter's HostFn gets `*Instance`, which has a `user_data`
    // slot — we set it to the WasmPlugin pointer.
    wp.* = .{
        .allocator = allocator,
        .plugin_id = id_dup,
        .module = module,
        .instance = undefined, // filled below
        .callbacks = callbacks,
    };

    const host_imports = [_]interp.HostImport{
        .{ .module_name = "env", .field_name = "stem_log", .func = hostStemLog },
        .{ .module_name = "env", .field_name = "stem_register_command", .func = hostStemRegisterCommand },
        .{ .module_name = "env", .field_name = "stem_show_notification", .func = hostStemShowNotification },
        .{ .module_name = "env", .field_name = "stem_open_buffer", .func = hostStemOpenBuffer },
        .{ .module_name = "env", .field_name = "stem_spawn_capture", .func = hostStemSpawnCapture },
        .{ .module_name = "env", .field_name = "stem_spawn_capture2", .func = hostStemSpawnCapture2 },
        .{ .module_name = "env", .field_name = "stem_subscribe_event", .func = hostStemSubscribeEvent },
        .{ .module_name = "env", .field_name = "stem_read_file", .func = hostStemReadFile },
        .{ .module_name = "env", .field_name = "stem_write_file", .func = hostStemWriteFile },
        .{ .module_name = "env", .field_name = "stem_set_status_item", .func = hostStemSetStatusItem },
        .{ .module_name = "env", .field_name = "stem_clear_status_item", .func = hostStemClearStatusItem },
        .{ .module_name = "env", .field_name = "stem_set_panel", .func = hostStemSetPanel },
        .{ .module_name = "env", .field_name = "stem_clear_panel", .func = hostStemClearPanel },
        .{ .module_name = "env", .field_name = "stem_get_buffer_content", .func = hostStemGetBufferContent },
        .{ .module_name = "env", .field_name = "stem_get_buffer_path", .func = hostStemGetBufferPath },
        .{ .module_name = "env", .field_name = "stem_load_plugin", .func = hostStemLoadPlugin },
        .{ .module_name = "env", .field_name = "stem_unload_plugin", .func = hostStemUnloadPlugin },
    };

    wp.instance = try interp.instantiate(allocator, &wp.module, &host_imports, @ptrCast(wp));
    return wp;
}

// ---------------------------------------------------------------------------
// Host import implementations
// ---------------------------------------------------------------------------

fn pluginFromInstance(instance: *interp.Instance) *WasmPlugin {
    return @ptrCast(@alignCast(instance.user_data.?));
}

/// env.stem_log(level: i32, msg_ptr: i32, msg_len: i32) -> ()
fn hostStemLog(instance: *interp.Instance, args: []const u64, _: *u64) interp.Error!void {
    if (args.len < 3) return error.UnknownImport;
    const wp = pluginFromInstance(instance);
    const level: u8 = @truncate(args[0]);
    const ptr: u32 = @truncate(args[1]);
    const len: u32 = @truncate(args[2]);
    const msg = instance.slice(ptr, len) catch return;
    wp.callbacks.on_log(wp.callbacks.user_data, wp.plugin_id, level, msg);
}

/// env.stem_register_command(id_ptr, id_len, title_ptr, title_len, desc_ptr, desc_len) -> ()
fn hostStemRegisterCommand(instance: *interp.Instance, args: []const u64, _: *u64) interp.Error!void {
    if (args.len < 6) return error.UnknownImport;
    const wp = pluginFromInstance(instance);
    const id = instance.slice(@truncate(args[0]), @truncate(args[1])) catch return;
    const title = instance.slice(@truncate(args[2]), @truncate(args[3])) catch return;
    const desc = instance.slice(@truncate(args[4]), @truncate(args[5])) catch return;
    wp.callbacks.on_register_command(wp.callbacks.user_data, wp.plugin_id, id, title, desc);
}

/// env.stem_show_notification(level: i32, msg_ptr: i32, msg_len: i32) -> ()
fn hostStemShowNotification(instance: *interp.Instance, args: []const u64, _: *u64) interp.Error!void {
    if (args.len < 3) return error.UnknownImport;
    const wp = pluginFromInstance(instance);
    const level: u8 = @truncate(args[0]);
    const ptr: u32 = @truncate(args[1]);
    const len: u32 = @truncate(args[2]);
    const msg = instance.slice(ptr, len) catch return;
    wp.callbacks.on_show_notification(wp.callbacks.user_data, wp.plugin_id, level, msg);
}

/// env.stem_open_buffer(name_ptr, name_len, content_ptr, content_len) -> ()
fn hostStemOpenBuffer(instance: *interp.Instance, args: []const u64, _: *u64) interp.Error!void {
    if (args.len < 4) return error.UnknownImport;
    const wp = pluginFromInstance(instance);
    const name = instance.slice(@truncate(args[0]), @truncate(args[1])) catch return;
    const content = instance.slice(@truncate(args[2]), @truncate(args[3])) catch return;
    wp.callbacks.on_open_buffer(wp.callbacks.user_data, wp.plugin_id, name, content);
}

/// env.stem_spawn_capture(cmd_ptr, cmd_len, out_ptr, out_max) -> i32
///
/// Default shape: run `cmd` with no timeout / cwd override and
/// capture only stdout. Returns bytes written, or negative on error
/// (see SpawnOpts doc on Callbacks).
fn hostStemSpawnCapture(instance: *interp.Instance, args: []const u64, result: *u64) interp.Error!void {
    if (args.len < 4) return error.UnknownImport;
    const wp = pluginFromInstance(instance);
    const cmd = instance.slice(@truncate(args[0]), @truncate(args[1])) catch {
        result.* = @as(u64, @bitCast(@as(i64, -3)));
        return;
    };
    const out_buf = instance.slice(@truncate(args[2]), @truncate(args[3])) catch {
        result.* = @as(u64, @bitCast(@as(i64, -3)));
        return;
    };
    const rc = wp.callbacks.on_spawn_capture(
        wp.callbacks.user_data,
        wp.plugin_id,
        .{ .cmd = cmd },
        out_buf,
    );
    result.* = @as(u64, @bitCast(@as(i64, rc)));
}

/// env.stem_spawn_capture2(cmd, cwd, timeout_ms, include_stderr, out_ptr, out_max) -> i32
///
/// Richer entry point: per-call cwd override, wall-clock timeout in
/// milliseconds (0 = none), and an `include_stderr` flag that
/// appends captured stderr after stdout (separated by a single NUL
/// byte). All other args mirror `stem_spawn_capture`.
fn hostStemSpawnCapture2(instance: *interp.Instance, args: []const u64, result: *u64) interp.Error!void {
    if (args.len < 8) return error.UnknownImport;
    const wp = pluginFromInstance(instance);
    const cmd = instance.slice(@truncate(args[0]), @truncate(args[1])) catch {
        result.* = @as(u64, @bitCast(@as(i64, -3)));
        return;
    };
    const cwd_ptr: u32 = @truncate(args[2]);
    const cwd_len: u32 = @truncate(args[3]);
    const cwd: ?[]const u8 = if (cwd_len == 0) null else (instance.slice(cwd_ptr, cwd_len) catch null);
    const timeout_ms: u32 = @truncate(args[4]);
    const include_stderr = args[5] != 0;
    const out_buf = instance.slice(@truncate(args[6]), @truncate(args[7])) catch {
        result.* = @as(u64, @bitCast(@as(i64, -3)));
        return;
    };
    const rc = wp.callbacks.on_spawn_capture(
        wp.callbacks.user_data,
        wp.plugin_id,
        .{ .cmd = cmd, .cwd = cwd, .timeout_ms = timeout_ms, .include_stderr = include_stderr },
        out_buf,
    );
    result.* = @as(u64, @bitCast(@as(i64, rc)));
}

/// env.stem_subscribe_event(topic_ptr, topic_len) -> i32
fn hostStemSubscribeEvent(instance: *interp.Instance, args: []const u64, result: *u64) interp.Error!void {
    if (args.len < 2) return error.UnknownImport;
    const wp = pluginFromInstance(instance);
    const topic = instance.slice(@truncate(args[0]), @truncate(args[1])) catch {
        result.* = @as(u64, @bitCast(@as(i64, -1)));
        return;
    };
    const rc = wp.callbacks.on_subscribe_event(wp.callbacks.user_data, wp.plugin_id, topic);
    result.* = @as(u64, @bitCast(@as(i64, rc)));
}

/// env.stem_read_file(path_ptr, path_len, out_ptr, out_max) -> i32
fn hostStemReadFile(instance: *interp.Instance, args: []const u64, result: *u64) interp.Error!void {
    if (args.len < 4) return error.UnknownImport;
    const wp = pluginFromInstance(instance);
    const path = instance.slice(@truncate(args[0]), @truncate(args[1])) catch {
        result.* = @as(u64, @bitCast(@as(i64, -1)));
        return;
    };
    const out_buf = instance.slice(@truncate(args[2]), @truncate(args[3])) catch {
        result.* = @as(u64, @bitCast(@as(i64, -1)));
        return;
    };
    const rc = wp.callbacks.on_read_file(wp.callbacks.user_data, wp.plugin_id, path, out_buf);
    result.* = @as(u64, @bitCast(@as(i64, rc)));
}

/// env.stem_write_file(path_ptr, path_len, content_ptr, content_len) -> i32
fn hostStemWriteFile(instance: *interp.Instance, args: []const u64, result: *u64) interp.Error!void {
    if (args.len < 4) return error.UnknownImport;
    const wp = pluginFromInstance(instance);
    const path = instance.slice(@truncate(args[0]), @truncate(args[1])) catch {
        result.* = @as(u64, @bitCast(@as(i64, -1)));
        return;
    };
    const content = instance.slice(@truncate(args[2]), @truncate(args[3])) catch {
        result.* = @as(u64, @bitCast(@as(i64, -1)));
        return;
    };
    const rc = wp.callbacks.on_write_file(wp.callbacks.user_data, wp.plugin_id, path, content);
    result.* = @as(u64, @bitCast(@as(i64, rc)));
}

/// env.stem_set_status_item(id_ptr, id_len, text_ptr, text_len, alignment, priority) -> ()
fn hostStemSetStatusItem(instance: *interp.Instance, args: []const u64, _: *u64) interp.Error!void {
    if (args.len < 6) return error.UnknownImport;
    const wp = pluginFromInstance(instance);
    const id = instance.slice(@truncate(args[0]), @truncate(args[1])) catch return;
    const text = instance.slice(@truncate(args[2]), @truncate(args[3])) catch return;
    const alignment: u8 = @truncate(args[4]);
    const priority: i8 = @bitCast(@as(u8, @truncate(args[5])));
    wp.callbacks.on_set_status_item(wp.callbacks.user_data, wp.plugin_id, id, text, alignment, priority);
}

/// env.stem_clear_status_item(id_ptr, id_len) -> ()
fn hostStemClearStatusItem(instance: *interp.Instance, args: []const u64, _: *u64) interp.Error!void {
    if (args.len < 2) return error.UnknownImport;
    const wp = pluginFromInstance(instance);
    const id = instance.slice(@truncate(args[0]), @truncate(args[1])) catch return;
    wp.callbacks.on_clear_status_item(wp.callbacks.user_data, wp.plugin_id, id);
}

/// env.stem_set_panel(id_ptr, id_len, title_ptr, title_len, content_ptr, content_len, position, width_percent) -> ()
fn hostStemSetPanel(instance: *interp.Instance, args: []const u64, _: *u64) interp.Error!void {
    if (args.len < 8) return error.UnknownImport;
    const wp = pluginFromInstance(instance);
    const id = instance.slice(@truncate(args[0]), @truncate(args[1])) catch return;
    const title = instance.slice(@truncate(args[2]), @truncate(args[3])) catch return;
    const content = instance.slice(@truncate(args[4]), @truncate(args[5])) catch return;
    const position: u8 = @truncate(args[6]);
    const width_percent: u8 = @truncate(args[7]);
    wp.callbacks.on_set_panel(wp.callbacks.user_data, wp.plugin_id, id, title, content, position, width_percent);
}

/// env.stem_clear_panel(id_ptr, id_len) -> ()
fn hostStemClearPanel(instance: *interp.Instance, args: []const u64, _: *u64) interp.Error!void {
    if (args.len < 2) return error.UnknownImport;
    const wp = pluginFromInstance(instance);
    const id = instance.slice(@truncate(args[0]), @truncate(args[1])) catch return;
    wp.callbacks.on_clear_panel(wp.callbacks.user_data, wp.plugin_id, id);
}

/// env.stem_get_buffer_content(out_ptr, out_max) -> i32
fn hostStemGetBufferContent(instance: *interp.Instance, args: []const u64, result: *u64) interp.Error!void {
    if (args.len < 2) return error.UnknownImport;
    const wp = pluginFromInstance(instance);
    const out_buf = instance.slice(@truncate(args[0]), @truncate(args[1])) catch {
        result.* = @as(u64, @bitCast(@as(i64, -1)));
        return;
    };
    const n = wp.callbacks.on_get_buffer_content(wp.callbacks.user_data, wp.plugin_id, out_buf);
    result.* = @as(u64, @bitCast(@as(i64, n)));
}

/// env.stem_get_buffer_path(out_ptr, out_max) -> i32
fn hostStemGetBufferPath(instance: *interp.Instance, args: []const u64, result: *u64) interp.Error!void {
    if (args.len < 2) return error.UnknownImport;
    const wp = pluginFromInstance(instance);
    const out_buf = instance.slice(@truncate(args[0]), @truncate(args[1])) catch {
        result.* = @as(u64, @bitCast(@as(i64, -1)));
        return;
    };
    const n = wp.callbacks.on_get_buffer_path(wp.callbacks.user_data, wp.plugin_id, out_buf);
    result.* = @as(u64, @bitCast(@as(i64, n)));
}

/// env.stem_load_plugin(name_ptr, name_len) -> i32
fn hostStemLoadPlugin(instance: *interp.Instance, args: []const u64, result: *u64) interp.Error!void {
    if (args.len < 2) return error.UnknownImport;
    const wp = pluginFromInstance(instance);
    const name = instance.slice(@truncate(args[0]), @truncate(args[1])) catch {
        result.* = @as(u64, @bitCast(@as(i64, -1)));
        return;
    };
    const rc = wp.callbacks.on_load_plugin(wp.callbacks.user_data, wp.plugin_id, name);
    result.* = @as(u64, @bitCast(@as(i64, rc)));
}

/// env.stem_unload_plugin(name_ptr, name_len) -> i32
fn hostStemUnloadPlugin(instance: *interp.Instance, args: []const u64, result: *u64) interp.Error!void {
    if (args.len < 2) return error.UnknownImport;
    const wp = pluginFromInstance(instance);
    const name = instance.slice(@truncate(args[0]), @truncate(args[1])) catch {
        result.* = @as(u64, @bitCast(@as(i64, -1)));
        return;
    };
    const rc = wp.callbacks.on_unload_plugin(wp.callbacks.user_data, wp.plugin_id, name);
    result.* = @as(u64, @bitCast(@as(i64, rc)));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestState = struct {
    allocator: std.mem.Allocator,
    logs: std.ArrayListUnmanaged([]u8) = .empty,
    commands: std.ArrayListUnmanaged([]u8) = .empty,

    fn onLog(ud: *anyopaque, _: []const u8, _: u8, msg: []const u8) void {
        const self: *TestState = @ptrCast(@alignCast(ud));
        const dup = self.allocator.dupe(u8, msg) catch return;
        self.logs.append(self.allocator, dup) catch self.allocator.free(dup);
    }
    fn onReg(ud: *anyopaque, _: []const u8, id: []const u8, _: []const u8, _: []const u8) void {
        const self: *TestState = @ptrCast(@alignCast(ud));
        const dup = self.allocator.dupe(u8, id) catch return;
        self.commands.append(self.allocator, dup) catch self.allocator.free(dup);
    }
    fn onNote(_: *anyopaque, _: []const u8, _: u8, _: []const u8) void {}
    fn onOpenBuf(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8) void {}
    fn onSpawn(_: *anyopaque, _: []const u8, _: SpawnOpts, _: []u8) i32 {
        return -3;
    }
    fn onSubEv(_: *anyopaque, _: []const u8, _: []const u8) i32 {
        return -1;
    }
    fn onReadFile(_: *anyopaque, _: []const u8, _: []const u8, _: []u8) i32 {
        return -1;
    }
    fn onWriteFile(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8) i32 {
        return -1;
    }
    fn onSetSI(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8, _: u8, _: i8) void {}
    fn onClearSI(_: *anyopaque, _: []const u8, _: []const u8) void {}
    fn onSetPanel(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8, _: []const u8, _: u8, _: u8) void {}
    fn onClearPanel(_: *anyopaque, _: []const u8, _: []const u8) void {}
    fn onGetBufContent(_: *anyopaque, _: []const u8, _: []u8) i32 {
        return -1;
    }
    fn onGetBufPath(_: *anyopaque, _: []const u8, _: []u8) i32 {
        return -1;
    }
    fn onLoadPlugin(_: *anyopaque, _: []const u8, _: []const u8) i32 {
        return -1;
    }
    fn onUnloadPlugin(_: *anyopaque, _: []const u8, _: []const u8) i32 {
        return -1;
    }
    fn deinit(self: *TestState) void {
        for (self.logs.items) |s| self.allocator.free(s);
        for (self.commands.items) |s| self.allocator.free(s);
        self.logs.deinit(self.allocator);
        self.commands.deinit(self.allocator);
    }
};

test "decode: integrate through loader path" {
    // Just exercise the interpreter through the loader's `decode` call
    // path — actual file I/O is covered by the integration test below.
    const a = std.testing.allocator;
    const bytes = [_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 };
    var m = try interp.decode(a, &bytes);
    defer m.deinit();
    try std.testing.expect(m.types.len == 0);
}

// End-to-end: when the build has produced `zig-out/bin/echo.wasm`,
// load it, run `activate`, and confirm the host callbacks fired.
// Skipped silently when the artifact isn't present.
test "load + activate + dispatchCommand against the built echo.wasm" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Tests run from the repo root. realPathFileAlloc returns an absolute path.
    const abs_path = std.Io.Dir.cwd().realPathFileAlloc(io, "zig-out/bin/echo.wasm", a) catch return error.SkipZigTest;
    defer a.free(abs_path);

    var ts: TestState = .{ .allocator = a };
    defer ts.deinit();
    const cbs: Callbacks = .{
        .user_data = @ptrCast(&ts),
        .on_log = TestState.onLog,
        .on_register_command = TestState.onReg,
        .on_show_notification = TestState.onNote,
        .on_open_buffer = TestState.onOpenBuf,
        .on_spawn_capture = TestState.onSpawn,
        .on_subscribe_event = TestState.onSubEv,
        .on_read_file = TestState.onReadFile,
        .on_write_file = TestState.onWriteFile,
        .on_set_status_item = TestState.onSetSI,
        .on_clear_status_item = TestState.onClearSI,
        .on_set_panel = TestState.onSetPanel,
        .on_clear_panel = TestState.onClearPanel,
        .on_get_buffer_content = TestState.onGetBufContent,
        .on_get_buffer_path = TestState.onGetBufPath,
        .on_load_plugin = TestState.onLoadPlugin,
        .on_unload_plugin = TestState.onUnloadPlugin,
    };

    const wp = try load(a, io, "echo", abs_path, cbs);
    defer {
        wp.deinit();
        a.destroy(wp);
    }
    try wp.activate();
    try std.testing.expect(ts.commands.items.len == 1);
    try std.testing.expectEqualStrings("echo.hello", ts.commands.items[0]);
    try wp.dispatchCommand("echo.hello");
    // After both calls we should have at least one log (the "ready" log
    // from activate) plus one from handle_command.
    try std.testing.expect(ts.logs.items.len >= 2);
}
