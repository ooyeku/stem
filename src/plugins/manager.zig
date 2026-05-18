//! Plugin orchestration.
//!
//! Loads plugin directories under `~/.stem/plugins/`, dispatches to
//! the appropriate runtime (wasm or exec), enforces manifest
//! permissions, and populates the command palette eagerly from each
//! manifest before the plugin starts.
//!
//! The legacy in-process `.dylib` runtime, its `PluginInterface`
//! extern struct, the SIGSEGV crash-isolation shim, and the
//! Plugin-Manager UI surface (status items / panels) were removed in
//! the Phase 4 cleanup. The two surviving runtimes are:
//!
//!   * **exec** — `bundled/plugins/<name>/{plugin.json, stem-<name>}`.
//!     A child process speaking JSON-RPC 2.0 over stdio with LSP
//!     framing. See `process_loader.zig`.
//!   * **wasm** — `bundled/plugins/<name>/{plugin.json, <name>.wasm}`.
//!     A WebAssembly module loaded by the pure-Zig interpreter and
//!     bound to a small set of `env.stem_*` host imports. See
//!     `wasm/{interpreter,loader}.zig`.

const std = @import("std");
const log = std.log.scoped(.PluginManager);
const vigil = @import("vigil");
const protocol = @import("../kernel/protocol.zig");
const CommandRegistry = @import("../kernel/command.zig").CommandRegistry;
const MessageBus = @import("../kernel/message_bus.zig").MessageBus;
const manifest_mod = @import("manifest.zig");
const process_loader = @import("process_loader.zig");
const ProcessPlugin = process_loader.ProcessPlugin;
const wasm_loader = @import("wasm/loader.zig");
const WasmPlugin = wasm_loader.WasmPlugin;
const logger_service = @import("../services/logger.zig");

/// Wire-protocol version handed to exec plugins on `plugin/initialize`.
/// Bumped only when the JSON-RPC envelope semantics change.
const PROC_ABI_VERSION: u32 = 1;

pub const PluginManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_block: std.process.Environ.Block,

    /// Out-of-process plugins.
    process_plugins: std.StringHashMapUnmanaged(*ProcessPlugin) = .empty,
    /// WebAssembly plugins.
    wasm_plugins: std.StringHashMapUnmanaged(*WasmPlugin) = .empty,

    core_inbox: ?*vigil.Inbox = null,
    ui_bus: *MessageBus,

    command_registry: *CommandRegistry,

    /// Owned `PluginCommandContext`s registered with `command_registry`.
    /// Freed in `deinit`.
    allocated_contexts: std.ArrayListUnmanaged(*PluginCommandContext) = .empty,

    /// Per-plugin permission grants, lifted from the manifest at load
    /// time. Host accessors consult this table before granting
    /// capability requests (event subscription, spawn, filesystem).
    plugin_permissions: std.StringHashMapUnmanaged(StoredPermissions) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        environ_block: std.process.Environ.Block,
        ui_bus: *MessageBus,
        command_registry: *CommandRegistry,
    ) PluginManager {
        return .{
            .allocator = allocator,
            .io = io,
            .environ_block = environ_block,
            .ui_bus = ui_bus,
            .command_registry = command_registry,
        };
    }

    pub fn deinit(self: *PluginManager) void {
        // Process plugins — shut down children, then free per-plugin state.
        var p_it = self.process_plugins.valueIterator();
        while (p_it.next()) |pp_ptr| {
            const pp = pp_ptr.*;
            self.cleanupPluginResources(pp.name);
            pp.deinit();
            self.allocator.destroy(pp);
        }
        self.process_plugins.deinit(self.allocator);

        // Wasm plugins — tear down instances + decoded modules.
        var w_it = self.wasm_plugins.valueIterator();
        while (w_it.next()) |wp_ptr| {
            const wp = wp_ptr.*;
            self.cleanupPluginResources(wp.plugin_id);
            wp.deinit();
            self.allocator.destroy(wp);
        }
        self.wasm_plugins.deinit(self.allocator);

        self.allocated_contexts.deinit(self.allocator);

        var perm_it = self.plugin_permissions.iterator();
        while (perm_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.plugin_permissions.deinit(self.allocator);
    }

    pub fn loadUserPlugins(self: *PluginManager) !void {
        const env: std.process.Environ = .{ .block = self.environ_block };

        const home = blk: {
            if (env.getPosix("HOME")) |h| break :blk try self.allocator.dupe(u8, h);
            if (@import("builtin").os.tag == .windows) {
                if (env.getPosix("USERPROFILE")) |up| break :blk try self.allocator.dupe(u8, up);
            }
            log.warn("Could not determine HOME for loading plugins", .{});
            return;
        };
        defer self.allocator.free(home);

        const plugin_dir = try std.fs.path.join(self.allocator, &[_][]const u8{ home, ".stem", "plugins" });
        defer self.allocator.free(plugin_dir);

        var dir = std.Io.Dir.openDirAbsolute(self.io, plugin_dir, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) return;
            log.warn("Failed to open plugin dir {s}: {}", .{ plugin_dir, err });
            return;
        };
        defer dir.close(self.io);

        var it = dir.iterate();
        while (it.next(self.io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            const full_path = try std.fs.path.join(self.allocator, &[_][]const u8{ plugin_dir, entry.name });
            defer self.allocator.free(full_path);
            self.tryLoadPluginDir(full_path) catch |err| {
                log.warn("Plugin dir {s} failed to load: {s}", .{ entry.name, @errorName(err) });
            };
        }
    }

    /// Read `<plugin_dir>/plugin.json` and dispatch to the runtime
    /// declared in the manifest. Silently no-ops if the manifest is
    /// missing (stray directory). Returns an error on the wasm /
    /// exec load path so callers can log.
    pub fn tryLoadPluginDir(self: *PluginManager, plugin_dir: []const u8) !void {
        const manifest_path = try std.fs.path.join(self.allocator, &.{ plugin_dir, "plugin.json" });
        defer self.allocator.free(manifest_path);

        const file = std.Io.Dir.openFileAbsolute(self.io, manifest_path, .{}) catch |err| {
            if (err == error.FileNotFound) return; // not a plugin dir
            return err;
        };
        defer file.close(self.io);

        const size = try file.length(self.io);
        if (size > 1 * 1024 * 1024) return error.ManifestTooLarge;

        const bytes = try self.allocator.alloc(u8, @intCast(size));
        defer self.allocator.free(bytes);
        _ = try file.readPositionalAll(self.io, bytes, 0);

        var m = try manifest_mod.parse(self.allocator, bytes);
        defer m.deinit();

        switch (m.runtime) {
            .exec => try self.loadProcessPluginFromManifest(plugin_dir, &m),
            .wasm => try self.loadWasmPluginFromManifest(plugin_dir, &m),
        }
    }

    // -------------------------------------------------------------------
    // Out-of-process plugins (JSON-RPC over stdio).
    // -------------------------------------------------------------------

    pub fn loadProcessPluginFromManifest(
        self: *PluginManager,
        plugin_dir: []const u8,
        m: *const manifest_mod.Manifest,
    ) !void {
        if (self.process_plugins.contains(m.name)) return error.DuplicatePluginId;
        if (self.wasm_plugins.contains(m.name)) return error.DuplicatePluginId;

        const entry_path = try std.fs.path.join(self.allocator, &.{ plugin_dir, m.entry });
        errdefer self.allocator.free(entry_path);

        const name_dup = try self.allocator.dupe(u8, m.name);
        errdefer self.allocator.free(name_dup);

        const pp = try self.allocator.create(ProcessPlugin);
        errdefer self.allocator.destroy(pp);

        pp.* = ProcessPlugin.init(self.allocator, self.io, name_dup, entry_path, .{
            .user_data = @ptrCast(self),
            .on_notification = handleProcessNotification,
            .on_request = handleProcessRequest,
            .on_exit = handleProcessExit,
        });
        errdefer pp.deinit();

        // Manifest-driven palette registration runs BEFORE the plugin
        // starts so commands remain discoverable even if the child
        // fails to come up. The dispatcher no-ops when the
        // `process_plugins` map doesn't yet hold an entry.
        for (m.commands) |cmd| {
            self.registerManifestCommand(m.name, .exec, cmd) catch |err| {
                log.warn("manifest commands for '{s}': {s}", .{ m.name, @errorName(err) });
            };
        }
        try self.installPluginPermissions(m.name, m.permissions);

        try pp.start();

        try self.process_plugins.put(self.allocator, name_dup, pp);

        // Synchronous `initialize` handshake: tell the plugin which
        // ABI version it's talking to, and its assigned id. Plugins
        // use this to bind any local state before the first command.
        const init_params = try std.fmt.allocPrint(
            self.allocator,
            "{{\"abi_version\":{d},\"plugin_id\":\"{s}\"}}",
            .{ PROC_ABI_VERSION, m.name },
        );
        defer self.allocator.free(init_params);
        try pp.sendNotification("plugin/initialize", init_params);

        log.info("Loaded process plugin: {s} ({s})", .{ m.name, entry_path });
    }

    /// JSON-RPC notification handler — runs on the ProcessPlugin's
    /// reader thread.
    fn handleProcessNotification(
        user_data: *anyopaque,
        method: []const u8,
        params: std.json.Value,
    ) void {
        const self: *PluginManager = @ptrCast(@alignCast(user_data));

        if (std.mem.eql(u8, method, "plugin/log")) {
            // params: { "level": int, "message": string }
            if (params != .object) return;
            const obj = params.object;
            const message = if (obj.get("message")) |v| (if (v == .string) v.string else return) else return;
            const level: u8 = if (obj.get("level")) |v| (if (v == .integer) @intCast(v.integer) else 1) else 1;
            if (logger_service.getGlobal()) |g| {
                const lvl: logger_service.LogLevel = switch (level) {
                    0 => .debug,
                    2 => .warn,
                    3 => .err,
                    else => .info,
                };
                g.log(lvl, "Plugin", "{s}", .{message});
            }
            return;
        }

        if (std.mem.eql(u8, method, "plugin/registerCommand")) {
            self.registerProcessCommand(params) catch |err| {
                log.warn("registerCommand failed: {s}", .{@errorName(err)});
            };
            return;
        }

        if (std.mem.eql(u8, method, "plugin/subscribeEvent")) {
            self.subscribeProcessEvent(params) catch {};
            return;
        }

        if (std.mem.eql(u8, method, "editor/showNotification")) {
            if (params != .object) return;
            const obj = params.object;
            const msg_v = obj.get("message") orelse return;
            if (msg_v != .string) return;
            const level: u8 = if (obj.get("level")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0;
            const nl: protocol.NotificationLevel = switch (level) {
                1 => .warning,
                2 => .err,
                else => .info,
            };
            const pm = protocol.PluginMessage{
                .plugin_id = "process-plugin",
                .message_type = .show_notification,
                .payload = .{ .notification = .{ .level = nl, .message = msg_v.string } },
            };
            const outer = protocol.Message{ .plugin_message = pm };
            const encoded = outer.encode(self.allocator) catch return;
            defer self.allocator.free(encoded);
            if (self.ui_bus.inbox.send(encoded)) |_| {} else |_| {}
            return;
        }

        log.info("process plugin: unhandled notification '{s}'", .{method});
    }

    fn handleProcessRequest(
        user_data: *anyopaque,
        id: u64,
        method: []const u8,
        _: std.json.Value,
    ) void {
        _ = user_data;
        log.info("process plugin: request '{s}' id={d} (not yet handled)", .{ method, id });
    }

    fn handleProcessExit(user_data: *anyopaque) void {
        _ = user_data;
        log.info("process plugin exited", .{});
    }

    fn registerProcessCommand(self: *PluginManager, params: std.json.Value) !void {
        if (params != .object) return error.InvalidParams;
        const obj = params.object;
        const plugin_id = obj.get("plugin_id") orelse return error.InvalidParams;
        const id = obj.get("id") orelse return error.InvalidParams;
        const title = obj.get("title") orelse return error.InvalidParams;
        const description = if (obj.get("description")) |d| d else std.json.Value{ .string = "" };
        if (plugin_id != .string or id != .string or title != .string or description != .string) return error.InvalidParams;

        // Manifest-driven registration already populates the palette,
        // so a runtime self-register for the same id is a no-op.
        if (self.command_registry.commands.contains(id.string)) {
            log.debug("command '{s}' already registered (from manifest) — skipping runtime re-register", .{id.string});
            return;
        }

        const ctx = try self.allocator.create(PluginCommandContext);
        errdefer self.allocator.destroy(ctx);
        const plugin_id_dup = try self.allocator.dupe(u8, plugin_id.string);
        errdefer self.allocator.free(plugin_id_dup);
        const id_dup = try self.allocator.dupe(u8, id.string);
        errdefer self.allocator.free(id_dup);
        const registry_id_dup = try self.allocator.dupe(u8, id.string);
        errdefer self.allocator.free(registry_id_dup);
        const title_dup = try self.allocator.dupe(u8, title.string);
        errdefer self.allocator.free(title_dup);
        const description_dup = try self.allocator.dupe(u8, description.string);
        errdefer self.allocator.free(description_dup);
        ctx.* = .{
            .manager = self,
            .plugin_id = plugin_id_dup,
            .command_id = id_dup,
            .registry_id = registry_id_dup,
            .registry_title = title_dup,
            .registry_description = description_dup,
        };

        try self.command_registry.register(
            ctx.registry_id,
            ctx.registry_title,
            ctx.registry_description,
            executeProcessPluginCommand,
            ctx,
        );
        try self.allocated_contexts.append(self.allocator, ctx);
        log.info("Process plugin '{s}' registered command: {s}", .{ plugin_id.string, id.string });
    }

    /// Dispatch a command back to its owning process plugin.
    fn executeProcessPluginCommand(_: *anyopaque, context_ptr: ?*const anyopaque) anyerror!void {
        const cmd_ctx: *const PluginCommandContext = @ptrCast(@alignCast(context_ptr.?));
        const self = cmd_ctx.manager;
        const pp = self.process_plugins.get(cmd_ctx.plugin_id) orelse return;
        const params = try std.fmt.allocPrint(self.allocator, "{{\"id\":\"{s}\"}}", .{cmd_ctx.command_id});
        defer self.allocator.free(params);
        try pp.sendNotification("command/execute", params);
    }

    fn subscribeProcessEvent(self: *PluginManager, params: std.json.Value) !void {
        if (params != .object) return error.InvalidParams;
        const obj = params.object;
        const plugin_id_v = obj.get("plugin_id") orelse return error.InvalidParams;
        const event_v = obj.get("event") orelse return error.InvalidParams;
        if (plugin_id_v != .string or event_v != .string) return error.InvalidParams;
        if (!self.permissionAllows(plugin_id_v.string, .event, event_v.string)) {
            log.warn(
                "plugin '{s}' attempted to subscribe to '{s}' but lacks the declared permission",
                .{ plugin_id_v.string, event_v.string },
            );
            return;
        }
        log.info("plugin '{s}' subscribed to event '{s}'", .{ plugin_id_v.string, event_v.string });
        // Future: route matching `broadcastEvent` calls into the
        // process plugin's outbox.
    }

    // -------------------------------------------------------------------
    // Manifest-driven palette + permissions.
    // -------------------------------------------------------------------

    pub const PluginRuntimeKind = enum { exec, wasm };

    /// Heap-owned mirror of `manifest_mod.Permissions`. The manifest's
    /// arena is freed right after parsing, so we copy what we need.
    const StoredPermissions = struct {
        spawn_allowlist: [][]const u8 = &.{},
        filesystem: [][]const u8 = &.{},
        events: [][]const u8 = &.{},

        fn deinit(self: *StoredPermissions, allocator: std.mem.Allocator) void {
            for (self.spawn_allowlist) |s| allocator.free(s);
            for (self.filesystem) |s| allocator.free(s);
            for (self.events) |s| allocator.free(s);
            allocator.free(self.spawn_allowlist);
            allocator.free(self.filesystem);
            allocator.free(self.events);
        }
    };

    fn installPluginPermissions(
        self: *PluginManager,
        plugin_id: []const u8,
        perms: manifest_mod.Permissions,
    ) !void {
        if (self.plugin_permissions.fetchRemove(plugin_id)) |kv| {
            self.allocator.free(kv.key);
            var p = kv.value;
            p.deinit(self.allocator);
        }
        const key = try self.allocator.dupe(u8, plugin_id);
        errdefer self.allocator.free(key);
        var stored: StoredPermissions = .{};
        stored.spawn_allowlist = try dupStringList(self.allocator, perms.spawn_allowlist);
        errdefer freeStringList(self.allocator, stored.spawn_allowlist);
        stored.filesystem = try dupStringList(self.allocator, perms.filesystem);
        errdefer freeStringList(self.allocator, stored.filesystem);
        stored.events = try dupStringList(self.allocator, perms.events);
        errdefer freeStringList(self.allocator, stored.events);
        try self.plugin_permissions.put(self.allocator, key, stored);
    }

    fn dupStringList(allocator: std.mem.Allocator, xs: []const []const u8) ![][]const u8 {
        const out = try allocator.alloc([]const u8, xs.len);
        var i: usize = 0;
        errdefer {
            for (out[0..i]) |s| allocator.free(s);
            allocator.free(out);
        }
        while (i < xs.len) : (i += 1) out[i] = try allocator.dupe(u8, xs[i]);
        return out;
    }

    fn freeStringList(allocator: std.mem.Allocator, xs: [][]const u8) void {
        for (xs) |s| allocator.free(s);
        allocator.free(xs);
    }

    pub const CapabilityKind = enum { event, spawn, filesystem };

    /// Returns `true` if `plugin_id` declared a permission allowing
    /// `item` for `kind`. Plugins with no permissions entry get a
    /// strict deny.
    pub fn permissionAllows(
        self: *PluginManager,
        plugin_id: []const u8,
        kind: CapabilityKind,
        item: []const u8,
    ) bool {
        const stored = self.plugin_permissions.get(plugin_id) orelse return false;
        const list: []const []const u8 = switch (kind) {
            .event => stored.events,
            .spawn => stored.spawn_allowlist,
            .filesystem => stored.filesystem,
        };
        for (list) |entry| {
            if (matchesPermissionEntry(entry, item)) return true;
        }
        return false;
    }

    /// Permission entries support a trailing `*` glob (e.g. `buffer.*`);
    /// everything else is exact-match.
    fn matchesPermissionEntry(entry: []const u8, item: []const u8) bool {
        if (entry.len > 0 and entry[entry.len - 1] == '*') {
            const prefix = entry[0 .. entry.len - 1];
            return std.mem.startsWith(u8, item, prefix);
        }
        return std.mem.eql(u8, entry, item);
    }

    /// Register one manifest-declared command in the palette. The
    /// dispatcher routes by runtime kind. Idempotent — a duplicate id
    /// is logged and skipped, since the registry doesn't tolerate
    /// double-inserts.
    fn registerManifestCommand(
        self: *PluginManager,
        plugin_id: []const u8,
        kind: PluginRuntimeKind,
        decl: manifest_mod.CommandDecl,
    ) !void {
        if (self.command_registry.commands.contains(decl.id)) {
            log.debug("command '{s}' already registered — manifest entry skipped", .{decl.id});
            return;
        }
        const ctx = try self.allocator.create(PluginCommandContext);
        errdefer self.allocator.destroy(ctx);
        const pid_dup = try self.allocator.dupe(u8, plugin_id);
        errdefer self.allocator.free(pid_dup);
        const id_dup = try self.allocator.dupe(u8, decl.id);
        errdefer self.allocator.free(id_dup);
        const registry_id_dup = try self.allocator.dupe(u8, decl.id);
        errdefer self.allocator.free(registry_id_dup);
        const title_dup = try self.allocator.dupe(u8, decl.title);
        errdefer self.allocator.free(title_dup);
        const desc_dup = try self.allocator.dupe(u8, decl.description);
        errdefer self.allocator.free(desc_dup);
        ctx.* = .{
            .manager = self,
            .plugin_id = pid_dup,
            .command_id = id_dup,
            .registry_id = registry_id_dup,
            .registry_title = title_dup,
            .registry_description = desc_dup,
        };
        const DispatcherFn = *const fn (*anyopaque, ?*const anyopaque) anyerror!void;
        const dispatcher: DispatcherFn = switch (kind) {
            .exec => &executeProcessPluginCommand,
            .wasm => &executeWasmPluginCommand,
        };
        try self.command_registry.register(
            ctx.registry_id,
            ctx.registry_title,
            ctx.registry_description,
            dispatcher,
            ctx,
        );
        try self.allocated_contexts.append(self.allocator, ctx);
    }

    // -------------------------------------------------------------------
    // WebAssembly plugins.
    // -------------------------------------------------------------------

    pub fn loadWasmPluginFromManifest(
        self: *PluginManager,
        plugin_dir: []const u8,
        m: *const manifest_mod.Manifest,
    ) !void {
        if (self.wasm_plugins.contains(m.name)) return error.DuplicatePluginId;
        if (self.process_plugins.contains(m.name)) return error.DuplicatePluginId;

        const wasm_path = try std.fs.path.join(self.allocator, &.{ plugin_dir, m.entry });
        defer self.allocator.free(wasm_path);

        // Manifest-driven registration. Eagerly publish each declared
        // command before activate runs so the palette stays populated
        // even if activate later traps.
        for (m.commands) |cmd| {
            self.registerManifestCommand(m.name, .wasm, cmd) catch |err| {
                log.warn("manifest commands for '{s}': {s}", .{ m.name, @errorName(err) });
            };
        }
        try self.installPluginPermissions(m.name, m.permissions);

        const wp = wasm_loader.load(
            self.allocator,
            self.io,
            m.name,
            wasm_path,
            .{
                .user_data = @ptrCast(self),
                .on_log = onWasmLog,
                .on_register_command = onWasmRegisterCommand,
                .on_show_notification = onWasmShowNotification,
                .on_open_buffer = onWasmOpenBuffer,
                .on_spawn_capture = onWasmSpawnCapture,
            },
        ) catch |err| {
            log.err("Failed to load wasm plugin '{s}': {s}", .{ m.name, @errorName(err) });
            return err;
        };
        errdefer {
            wp.deinit();
            self.allocator.destroy(wp);
        }

        try self.wasm_plugins.put(self.allocator, wp.plugin_id, wp);

        wp.activate() catch |err| {
            log.warn("wasm plugin '{s}' activate failed: {s}", .{ m.name, @errorName(err) });
        };

        log.info("Loaded wasm plugin: {s} ({s})", .{ m.name, wasm_path });
    }

    fn onWasmLog(user_data: *anyopaque, plugin_id: []const u8, level: u8, message: []const u8) void {
        _ = plugin_id;
        _ = user_data;
        if (logger_service.getGlobal()) |g| {
            const lvl: logger_service.LogLevel = switch (level) {
                0 => .debug,
                2 => .warn,
                3 => .err,
                else => .info,
            };
            g.log(lvl, "Plugin", "{s}", .{message});
        }
    }

    fn onWasmRegisterCommand(
        user_data: *anyopaque,
        plugin_id: []const u8,
        id: []const u8,
        title: []const u8,
        description: []const u8,
    ) void {
        const self: *PluginManager = @ptrCast(@alignCast(user_data));
        self.registerWasmCommand(plugin_id, id, title, description) catch |err| {
            log.warn("wasm registerCommand failed: {s}", .{@errorName(err)});
        };
    }

    fn onWasmShowNotification(
        user_data: *anyopaque,
        plugin_id: []const u8,
        level: u8,
        message: []const u8,
    ) void {
        const self: *PluginManager = @ptrCast(@alignCast(user_data));
        _ = plugin_id;
        const nl: protocol.NotificationLevel = switch (level) {
            1 => .warning,
            2 => .err,
            else => .info,
        };
        const pm = protocol.PluginMessage{
            .plugin_id = "wasm-plugin",
            .message_type = .show_notification,
            .payload = .{ .notification = .{ .level = nl, .message = message } },
        };
        const outer = protocol.Message{ .plugin_message = pm };
        const encoded = outer.encode(self.allocator) catch return;
        defer self.allocator.free(encoded);
        if (self.ui_bus.inbox.send(encoded)) |_| {} else |_| {}
    }

    /// Route a wasm plugin's `stem_open_buffer` call into core's
    /// inbox as a regular `open_buffer` PluginMessage.
    fn onWasmOpenBuffer(
        user_data: *anyopaque,
        plugin_id: []const u8,
        name: []const u8,
        content: []const u8,
    ) void {
        const self: *PluginManager = @ptrCast(@alignCast(user_data));
        const core_inbox = self.core_inbox orelse return;
        const pm = protocol.PluginMessage{
            .plugin_id = plugin_id,
            .message_type = .open_buffer,
            .payload = .{ .buffer_open = .{ .name = name, .content = content } },
        };
        const outer = protocol.Message{ .plugin_message = pm };
        const encoded = outer.encode(self.allocator) catch return;
        defer self.allocator.free(encoded);
        core_inbox.send(encoded) catch |err| {
            log.warn("wasm open_buffer send failed for '{s}': {s}", .{ plugin_id, @errorName(err) });
        };
    }

    /// Handle a wasm plugin's `stem_spawn_capture` request. Tokenizes
    /// the command line, checks manifest spawn permissions, runs the
    /// child synchronously, and writes stdout into the wasm-supplied
    /// linear-memory slice. Returns the byte count, or 0 on denial /
    /// any error (so wasm plugins can treat 0 as a uniform failure
    /// signal).
    fn onWasmSpawnCapture(
        user_data: *anyopaque,
        plugin_id: []const u8,
        cmd: []const u8,
        out_buf: []u8,
    ) u32 {
        const self: *PluginManager = @ptrCast(@alignCast(user_data));

        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(self.allocator);
        var it = std.mem.tokenizeAny(u8, cmd, " \t\r\n");
        while (it.next()) |tok| {
            argv.append(self.allocator, tok) catch return 0;
        }
        if (argv.items.len == 0) return 0;
        const program = argv.items[0];

        if (!self.permissionAllows(plugin_id, .spawn, program)) {
            log.warn(
                "wasm plugin '{s}' attempted unauthorized spawn: {s}",
                .{ plugin_id, program },
            );
            return 0;
        }

        const result = std.process.run(self.allocator, self.io, .{
            .argv = argv.items,
        }) catch |err| {
            log.warn("wasm spawn for '{s}' failed: {s}", .{ plugin_id, @errorName(err) });
            return 0;
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        const n = @min(result.stdout.len, out_buf.len);
        @memcpy(out_buf[0..n], result.stdout[0..n]);
        return @intCast(n);
    }

    fn registerWasmCommand(
        self: *PluginManager,
        plugin_id: []const u8,
        id: []const u8,
        title: []const u8,
        description: []const u8,
    ) !void {
        if (self.command_registry.commands.contains(id)) {
            log.debug("wasm command '{s}' already registered (from manifest) — skipping", .{id});
            return;
        }
        const ctx = try self.allocator.create(PluginCommandContext);
        errdefer self.allocator.destroy(ctx);
        const pid_dup = try self.allocator.dupe(u8, plugin_id);
        errdefer self.allocator.free(pid_dup);
        const id_dup = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(id_dup);
        const registry_id_dup = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(registry_id_dup);
        const title_dup = try self.allocator.dupe(u8, title);
        errdefer self.allocator.free(title_dup);
        const desc_dup = try self.allocator.dupe(u8, description);
        errdefer self.allocator.free(desc_dup);
        ctx.* = .{
            .manager = self,
            .plugin_id = pid_dup,
            .command_id = id_dup,
            .registry_id = registry_id_dup,
            .registry_title = title_dup,
            .registry_description = desc_dup,
        };
        try self.command_registry.register(
            ctx.registry_id,
            ctx.registry_title,
            ctx.registry_description,
            executeWasmPluginCommand,
            ctx,
        );
        try self.allocated_contexts.append(self.allocator, ctx);
        log.info("Wasm plugin '{s}' registered command: {s}", .{ plugin_id, id });
    }

    fn executeWasmPluginCommand(_: *anyopaque, context_ptr: ?*const anyopaque) anyerror!void {
        const cmd_ctx: *const PluginCommandContext = @ptrCast(@alignCast(context_ptr.?));
        const self = cmd_ctx.manager;
        const wp = self.wasm_plugins.get(cmd_ctx.plugin_id) orelse return;
        try wp.dispatchCommand(cmd_ctx.command_id);
    }

    // -------------------------------------------------------------------
    // Resource cleanup
    // -------------------------------------------------------------------

    fn cleanupPluginResources(self: *PluginManager, plugin_id: []const u8) void {
        var i: usize = 0;
        while (i < self.allocated_contexts.items.len) {
            const ctx = self.allocated_contexts.items[i];
            if (std.mem.eql(u8, ctx.plugin_id, plugin_id)) {
                _ = self.command_registry.unregister(ctx.registry_id);
                self.allocator.free(ctx.plugin_id);
                self.allocator.free(ctx.command_id);
                self.allocator.free(ctx.registry_id);
                self.allocator.free(ctx.registry_title);
                self.allocator.free(ctx.registry_description);
                self.allocator.destroy(ctx);
                _ = self.allocated_contexts.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    // -------------------------------------------------------------------
    // Event broadcasting
    // -------------------------------------------------------------------

    /// Publish an editor event to the Vigil pub/sub broker. Plugins
    /// that want to react can subscribe via the broker by topic; the
    /// host doesn't push events directly into plugin inboxes anymore.
    pub fn broadcastEvent(self: *PluginManager, event: protocol.PluginEvent, data: []const u8) void {
        _ = self;
        const topic = pluginEventTopic(event);
        if (vigil.pubsub.getGlobal()) |broker| {
            _ = broker.publish(topic, data) catch |err| {
                log.warn("pubsub publish '{s}' failed: {}", .{ topic, err });
            };
        }
    }

    /// Stable topic names so external subscribers don't have to know
    /// the `protocol.PluginEvent` enum integer.
    fn pluginEventTopic(event: protocol.PluginEvent) []const u8 {
        return switch (event) {
            .buffer_changed => "buffer.changed",
            .cursor_moved => "cursor.moved",
            .mode_changed => "mode.changed",
            .file_saved => "file.saved",
            .file_opened => "file.opened",
            .buffer_switched => "buffer.switched",
            .custom_event => "custom",
        };
    }

    const PluginCommandContext = struct {
        manager: *PluginManager,
        plugin_id: []const u8,
        command_id: []const u8,
        registry_id: []const u8,
        registry_title: []const u8,
        registry_description: []const u8,
    };
};
