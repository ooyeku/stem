//! WebAssembly plugin loader (Phase 2).
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
//! The wasm plugin's import schema is intentionally a narrow mirror of
//! the JSON-RPC method names from Phase 1, but with pointer+length
//! arguments instead of JSON envelopes. Each host import marshals
//! linear-memory bytes into Zig slices, then routes to the same
//! subsystems (command registry, logger, etc.) the process plugins use.

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
};

pub const State = enum { loaded, activated, deactivated, failed };

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

    /// Invoke the plugin's `handle_command(id_ptr: i32, id_len: i32)`
    /// export. We allocate a small scratch region of linear memory
    /// and copy the command id into it.
    pub fn dispatchCommand(self: *WasmPlugin, command_id: []const u8) !void {
        const idx = self.module.findExport("handle_command", .func) orelse return error.MissingExport;
        self.invoke_mu.lock();
        defer self.invoke_mu.unlock();

        // Reserve a small scratch buffer near the top of linear memory.
        // We use a simple "bump" — a global named `__stem_scratch` that
        // the plugin maintains, if present; otherwise we put the bytes
        // at address 16 (well clear of typical wasm data segments).
        var scratch_ptr: u32 = 16;
        if (self.module.findExport("__stem_scratch", .global)) |g_idx| {
            scratch_ptr = @truncate(self.instance.globals[g_idx]);
        }
        if (scratch_ptr + command_id.len > self.instance.memory.len) {
            log.warn("plugin '{s}' memory too small to dispatch command", .{self.plugin_id});
            return error.OutOfBounds;
        }
        @memcpy(self.instance.memory[scratch_ptr .. scratch_ptr + command_id.len], command_id);

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

// End-to-end: when the build has produced `zig-out/bin/echo-wasm.wasm`,
// load it, run `activate`, and confirm the host callbacks fired.
// Skipped silently when the artifact isn't present.
test "load + activate + dispatchCommand against the built echo-wasm.wasm" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Tests run from the repo root. realPathFileAlloc returns an absolute path.
    const abs_path = std.Io.Dir.cwd().realPathFileAlloc(io, "zig-out/bin/echo-wasm.wasm", a) catch return error.SkipZigTest;
    defer a.free(abs_path);

    var ts: TestState = .{ .allocator = a };
    defer ts.deinit();
    const cbs: Callbacks = .{
        .user_data = @ptrCast(&ts),
        .on_log = TestState.onLog,
        .on_register_command = TestState.onReg,
        .on_show_notification = TestState.onNote,
    };

    const wp = try load(a, io, "echo-wasm", abs_path, cbs);
    defer {
        wp.deinit();
        a.destroy(wp);
    }
    try wp.activate();
    try std.testing.expect(ts.commands.items.len == 1);
    try std.testing.expectEqualStrings("echo-wasm.hello", ts.commands.items[0]);
    try wp.dispatchCommand("echo-wasm.hello");
    // After both calls we should have at least one log (the "ready" log
    // from activate) plus one from handle_command.
    try std.testing.expect(ts.logs.items.len >= 2);
}
