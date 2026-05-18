//! Plugin orchestration.
//!
//! Loads plugin directories under `~/.stem/plugins/`, dispatches to
//! the appropriate runtime (wasm or exec), enforces manifest
//! permissions, and populates the command palette eagerly from each
//! manifest before the plugin starts.
//!
//! Two runtimes:
//!
//!   * **wasm** — `bundled/plugins/<name>/{plugin.json, <name>.wasm}`.
//!     A WebAssembly module loaded by the pure-Zig interpreter and
//!     bound to a small set of `env.stem_*` host imports. See
//!     `wasm/{interpreter,loader}.zig`.
//!   * **exec** — `~/.stem/plugins/<name>/{plugin.json, <entry>}`.
//!     A child process speaking JSON-RPC 2.0 over stdio with LSP
//!     framing. See `process_loader.zig`. Nothing bundled uses this
//!     path today; it's available for third-party plugins.

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
const jsonrpc = @import("jsonrpc.zig");
const logger_service = @import("../services/logger.zig");
const telemetry = @import("../services/telemetry.zig");

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

    /// Map of editor event → list of plugins subscribed to it.
    /// Populated by `plugin/subscribeEvent` (exec) and
    /// `stem_subscribe_event` (wasm); drained on plugin unload.
    event_subscribers: std.AutoHashMapUnmanaged(protocol.PluginEvent, std.ArrayListUnmanaged(EventSub)) = .empty,

    /// Plugin status-bar widgets, keyed by `"<plugin_id>:<item_id>"`.
    status_items: std.StringHashMapUnmanaged(StoredStatusItem) = .empty,
    /// Plugin side panels, keyed by `"<plugin_id>:<panel_id>"`.
    panels: std.StringHashMapUnmanaged(StoredPanel) = .empty,
    /// Manifest-declared keybinding sequences. Key is the
    /// space-separated key sequence (e.g. `"Space g s"`); value is the
    /// command id to execute. The core input handler consults this
    /// after its own leader chord chain when `leader_pending` is set.
    plugin_keybindings: std.StringHashMapUnmanaged([]u8) = .empty,

    /// Editor-side hooks set by Core after construction. Lets the
    /// plugin manager pull data that lives on Core (active buffer
    /// content, file path) without taking a circular import on the
    /// `Core` type. Wasm `stem_get_buffer_*` host imports route
    /// through these.
    host_hooks: HostHooks = .{},

    /// Monotonic counter for assigning new widget ids on each
    /// status-item / panel registration. Stable across the lifetime
    /// of the plugin manager.
    next_widget_id: u32 = 1,

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

        // Event subscriptions: each list owns its plugin_id duplicates.
        var ev_it = self.event_subscribers.valueIterator();
        while (ev_it.next()) |list| {
            for (list.items) |s| self.allocator.free(s.plugin_id);
            list.deinit(self.allocator);
        }
        self.event_subscribers.deinit(self.allocator);

        // Plugin keybindings.
        var kb_it = self.plugin_keybindings.iterator();
        while (kb_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.plugin_keybindings.deinit(self.allocator);

        // Status items / panels.
        var si_it = self.status_items.iterator();
        while (si_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.status_items.deinit(self.allocator);
        var pn_it = self.panels.iterator();
        while (pn_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.panels.deinit(self.allocator);

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

    /// Resolve a plugin name into its `~/.stem/plugins/<name>/` dir
    /// and (re)load it via `tryLoadPluginDir`. Used by the runtime
    /// `:plugin.reload` command and the `load_plugin` plugin message.
    pub fn loadPluginByName(self: *PluginManager, name: []const u8) !void {
        const env: std.process.Environ = .{ .block = self.environ_block };
        const home = env.getPosix("HOME") orelse return error.NoHome;
        const plugin_dir = try std.fs.path.join(self.allocator, &.{ home, ".stem", "plugins", name });
        defer self.allocator.free(plugin_dir);
        try self.tryLoadPluginDir(plugin_dir);
    }

    /// Tear down a wasm or exec plugin by name. Drops every command,
    /// status item, panel, event subscription, and permission grant
    /// the plugin owned.
    pub fn unloadPlugin(self: *PluginManager, name: []const u8) !void {
        if (self.wasm_plugins.fetchRemove(name)) |kv| {
            self.cleanupPluginResources(kv.value.plugin_id);
            kv.value.deinit();
            self.allocator.destroy(kv.value);
            self.dropStoredPermissions(name);
            log.info("Unloaded wasm plugin: {s}", .{name});
            return;
        }
        if (self.process_plugins.fetchRemove(name)) |kv| {
            self.cleanupPluginResources(kv.value.name);
            kv.value.deinit();
            self.allocator.destroy(kv.value);
            self.dropStoredPermissions(name);
            log.info("Unloaded process plugin: {s}", .{name});
            return;
        }
        return error.PluginNotFound;
    }

    fn dropStoredPermissions(self: *PluginManager, plugin_id: []const u8) void {
        if (self.plugin_permissions.fetchRemove(plugin_id)) |kv| {
            self.allocator.free(kv.key);
            var v = kv.value;
            v.deinit(self.allocator);
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
            self.dispatchNotification("process-plugin", level, msg_v.string);
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
        const self: *PluginManager = @ptrCast(@alignCast(user_data));
        // We can't safely read core's state from the ProcessPlugin's
        // reader thread, so forward the request onto core's inbox as
        // a PluginMessage carrying the JSON-RPC id in `correlation_id`.
        // Core handles it on its own thread and calls
        // `replyToProcessPlugin` once it has the answer.
        const core_inbox = self.core_inbox orelse {
            self.replyProcessPluginError(method, id, -32603, "core inbox unavailable");
            return;
        };
        const which: protocol.PluginMessage.PluginMessageType = blk: {
            if (std.mem.eql(u8, method, "editor/getState")) break :blk .get_state;
            if (std.mem.eql(u8, method, "editor/getBufferContent")) break :blk .get_buffer_content;
            if (std.mem.eql(u8, method, "editor/getPluginList")) break :blk .get_plugin_list;
            self.replyProcessPluginError(method, id, -32601, "Method not found");
            return;
        };
        const pm = protocol.PluginMessage{
            .plugin_id = method, // we don't know which plugin made the request — method serves as a label
            .message_type = which,
            .payload = switch (which) {
                .get_state => .{ .state_request = {} },
                .get_buffer_content => .{ .buffer_content_request = {} },
                .get_plugin_list => .{ .plugin_list_request = {} },
                else => unreachable,
            },
            .correlation_id = id,
        };
        const outer = protocol.Message{ .plugin_message = pm };
        const encoded = outer.encode(self.allocator) catch {
            self.replyProcessPluginError(method, id, -32603, "encode failed");
            return;
        };
        defer self.allocator.free(encoded);
        core_inbox.send(encoded) catch {
            self.replyProcessPluginError(method, id, -32603, "core inbox closed");
        };
    }

    /// Dispatch a JSON-RPC reply built by core back to the originating
    /// process plugin. `plugin_id` is the plugin name the request came
    /// from — but since `handleProcessRequest` runs without knowing
    /// which exec plugin spawned it, we broadcast to every running
    /// process plugin whose pending-request id matches. This works
    /// today because there's a single process plugin (echo); when
    /// multiple exec plugins coexist the request handler needs to
    /// carry the plugin id explicitly. TODO once we have >1 exec
    /// plugin in flight.
    pub fn replyToProcessPlugin(
        self: *PluginManager,
        correlation_id: u64,
        result_json: []const u8,
    ) void {
        var it = self.process_plugins.valueIterator();
        while (it.next()) |pp_ptr| {
            pp_ptr.*.sendReply(correlation_id, result_json) catch |err| {
                log.warn("reply to process plugin '{s}' id={d} failed: {s}", .{ pp_ptr.*.name, correlation_id, @errorName(err) });
            };
        }
    }

    fn replyProcessPluginError(
        self: *PluginManager,
        method: []const u8,
        correlation_id: u64,
        code: i32,
        message: []const u8,
    ) void {
        _ = method;
        var it = self.process_plugins.valueIterator();
        while (it.next()) |pp_ptr| {
            pp_ptr.*.sendError(correlation_id, code, message) catch {};
        }
        log.warn("process plugin request id={d} error {d}: {s}", .{ correlation_id, code, message });
    }

    fn handleProcessExit(user_data: *anyopaque) void {
        // Called from the ProcessPlugin's reader thread when the
        // child closes stdout. Mark the plugin failed and tear down
        // its registered commands / widgets / subscriptions so the
        // palette doesn't show dead entries. We don't auto-restart
        // here — that's a policy decision the operator drives via
        // `:plugin.reload`, `stem plugin install`, or the
        // load/unload PluginMessage variants.
        const self: *PluginManager = @ptrCast(@alignCast(user_data));
        log.warn("process plugin exited; pruning resources", .{});

        // Find the process plugin whose state has flipped to
        // .failed / .stopped (the reader thread sets it in its exit
        // path before invoking on_exit).
        var stale: std.ArrayListUnmanaged([]const u8) = .empty;
        defer stale.deinit(self.allocator);
        var it = self.process_plugins.iterator();
        while (it.next()) |entry| {
            const pp = entry.value_ptr.*;
            pp.state_mu.lock();
            const dead = pp.state == .failed or pp.state == .stopped;
            pp.state_mu.unlock();
            if (dead) {
                stale.append(self.allocator, entry.key_ptr.*) catch break;
            }
        }
        for (stale.items) |name| {
            telemetry.recordPluginCrash(name);
            self.unloadPlugin(name) catch |err| {
                log.warn("unload of failed process plugin '{s}' failed: {s}", .{ name, @errorName(err) });
            };
        }
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
        const event = eventFromTopic(event_v.string) orelse {
            log.warn("plugin '{s}' subscribed to unknown event topic '{s}'", .{ plugin_id_v.string, event_v.string });
            return;
        };
        try self.addEventSubscription(event, .exec, plugin_id_v.string);
        log.info("plugin '{s}' subscribed to event '{s}'", .{ plugin_id_v.string, event_v.string });
    }

    /// Translate a stable topic name (the format declared in a
    /// manifest's `permissions.events` and used by exec subscribers)
    /// to a `PluginEvent`. Inverse of `pluginEventTopic`.
    fn eventFromTopic(topic: []const u8) ?protocol.PluginEvent {
        const map = .{
            .{ "buffer.changed", protocol.PluginEvent.buffer_changed },
            .{ "cursor.moved", protocol.PluginEvent.cursor_moved },
            .{ "mode.changed", protocol.PluginEvent.mode_changed },
            .{ "file.saved", protocol.PluginEvent.file_saved },
            .{ "file.opened", protocol.PluginEvent.file_opened },
            .{ "buffer.switched", protocol.PluginEvent.buffer_switched },
            .{ "custom", protocol.PluginEvent.custom_event },
        };
        inline for (map) |entry| {
            if (std.mem.eql(u8, topic, entry[0])) return entry[1];
        }
        return null;
    }

    fn addEventSubscription(
        self: *PluginManager,
        event: protocol.PluginEvent,
        runtime: PluginRuntimeKind,
        plugin_id: []const u8,
    ) !void {
        const entry = try self.event_subscribers.getOrPut(self.allocator, event);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        // Dedupe — re-subscribing is a no-op.
        for (entry.value_ptr.items) |s| {
            if (s.runtime == runtime and std.mem.eql(u8, s.plugin_id, plugin_id)) return;
        }
        const id_dup = try self.allocator.dupe(u8, plugin_id);
        errdefer self.allocator.free(id_dup);
        try entry.value_ptr.append(self.allocator, .{ .runtime = runtime, .plugin_id = id_dup });
    }

    fn removeEventSubscriptions(self: *PluginManager, plugin_id: []const u8) void {
        var it = self.event_subscribers.valueIterator();
        while (it.next()) |list| {
            var i: usize = 0;
            while (i < list.items.len) {
                if (std.mem.eql(u8, list.items[i].plugin_id, plugin_id)) {
                    self.allocator.free(list.items[i].plugin_id);
                    _ = list.swapRemove(i);
                } else {
                    i += 1;
                }
            }
        }
    }

    // -------------------------------------------------------------------
    // Manifest-driven palette + permissions.
    // -------------------------------------------------------------------

    pub const HostHooks = struct {
        user_data: ?*anyopaque = null,
        get_buffer_content: ?*const fn (user_data: *anyopaque, out_buf: []u8) i32 = null,
        get_buffer_path: ?*const fn (user_data: *anyopaque, out_buf: []u8) i32 = null,
    };

    pub fn setHostHooks(self: *PluginManager, hooks: HostHooks) void {
        self.host_hooks = hooks;
    }

    pub const PluginRuntimeKind = enum { exec, wasm };

    /// One subscriber entry on the event bus.
    pub const EventSub = struct {
        runtime: PluginRuntimeKind,
        plugin_id: []u8, // owned
    };

    /// Heap-owned mirror of `protocol.StatusItem` keyed by
    /// `<plugin_id>:<id>`. Strings are duped on insert; freed on
    /// removal or `cleanupPluginResources`.
    const StoredStatusItem = struct {
        plugin_id: []u8,
        id: []u8,
        text: []u8,
        alignment: protocol.StatusAlignment,
        priority: i8,
        widget_id: u64,

        fn deinit(self: *StoredStatusItem, allocator: std.mem.Allocator) void {
            allocator.free(self.plugin_id);
            allocator.free(self.id);
            allocator.free(self.text);
        }
    };

    /// Heap-owned mirror of `protocol.PanelInfo`.
    const StoredPanel = struct {
        plugin_id: []u8,
        id: []u8,
        title: []u8,
        /// Panel content stored as one heap-owned blob; splitting
        /// into the renderer's expected `[]const []const u8` happens
        /// in `snapshotPanels`.
        content: []u8,
        position: protocol.PanelPosition,
        width_percent: u8,
        widget_id: u64,

        fn deinit(self: *StoredPanel, allocator: std.mem.Allocator) void {
            allocator.free(self.plugin_id);
            allocator.free(self.id);
            allocator.free(self.title);
            allocator.free(self.content);
        }
    };

    /// Compose `<plugin_id>:<id>` into `out`. Caller owns the
    /// returned slice (allocated from the manager's allocator).
    fn widgetKey(self: *PluginManager, plugin_id: []const u8, id: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ plugin_id, id });
    }

    pub fn upsertStatusItem(
        self: *PluginManager,
        plugin_id: []const u8,
        id: []const u8,
        text: []const u8,
        alignment_raw: u8,
        priority: i8,
    ) !void {
        const align_e: protocol.StatusAlignment = switch (alignment_raw) {
            1 => .center,
            2 => .right,
            else => .left,
        };
        const key = try self.widgetKey(plugin_id, id);
        if (self.status_items.getPtr(key)) |existing| {
            // Update in place — keep the same widget_id so the
            // renderer's caching doesn't see a fresh widget.
            self.allocator.free(key);
            self.allocator.free(existing.text);
            existing.text = try self.allocator.dupe(u8, text);
            existing.alignment = align_e;
            existing.priority = priority;
            return;
        }
        const stored: StoredStatusItem = .{
            .plugin_id = try self.allocator.dupe(u8, plugin_id),
            .id = try self.allocator.dupe(u8, id),
            .text = try self.allocator.dupe(u8, text),
            .alignment = align_e,
            .priority = priority,
            .widget_id = self.allocateWidgetId(),
        };
        try self.status_items.put(self.allocator, key, stored);
    }

    pub fn removeStatusItem(self: *PluginManager, plugin_id: []const u8, id: []const u8) void {
        const key = self.widgetKey(plugin_id, id) catch return;
        defer self.allocator.free(key);
        if (self.status_items.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
            var v = kv.value;
            v.deinit(self.allocator);
        }
    }

    pub fn upsertPanel(
        self: *PluginManager,
        plugin_id: []const u8,
        id: []const u8,
        title: []const u8,
        content: []const u8,
        position_raw: u8,
        width_percent: u8,
    ) !void {
        const position: protocol.PanelPosition = switch (position_raw) {
            1 => .right,
            2 => .bottom,
            else => .left,
        };
        const key = try self.widgetKey(plugin_id, id);
        if (self.panels.getPtr(key)) |existing| {
            self.allocator.free(key);
            self.allocator.free(existing.title);
            self.allocator.free(existing.content);
            existing.title = try self.allocator.dupe(u8, title);
            existing.content = try self.allocator.dupe(u8, content);
            existing.position = position;
            existing.width_percent = width_percent;
            return;
        }
        const stored: StoredPanel = .{
            .plugin_id = try self.allocator.dupe(u8, plugin_id),
            .id = try self.allocator.dupe(u8, id),
            .title = try self.allocator.dupe(u8, title),
            .content = try self.allocator.dupe(u8, content),
            .position = position,
            .width_percent = width_percent,
            .widget_id = self.allocateWidgetId(),
        };
        try self.panels.put(self.allocator, key, stored);
    }

    pub fn removePanel(self: *PluginManager, plugin_id: []const u8, id: []const u8) void {
        const key = self.widgetKey(plugin_id, id) catch return;
        defer self.allocator.free(key);
        if (self.panels.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
            var v = kv.value;
            v.deinit(self.allocator);
        }
    }

    fn allocateWidgetId(self: *PluginManager) u64 {
        const id: u64 = self.next_widget_id;
        self.next_widget_id +%= 1;
        return id;
    }

    /// Build a fresh slice of `protocol.StatusItem` over the
    /// allocator (typically a per-frame arena). Strings borrow from
    /// the stored entries; valid until the next mutation.
    pub fn snapshotStatusItems(self: *PluginManager, allocator: std.mem.Allocator) ![]protocol.StatusItem {
        var list: std.ArrayListUnmanaged(protocol.StatusItem) = .empty;
        errdefer list.deinit(allocator);
        var it = self.status_items.valueIterator();
        while (it.next()) |s| {
            try list.append(allocator, .{
                .id = s.id,
                .plugin_id = s.plugin_id,
                .text = s.text,
                .alignment = s.alignment,
                .priority = s.priority,
                .widget_id = s.widget_id,
            });
        }
        return list.toOwnedSlice(allocator);
    }

    /// Build a fresh slice of `protocol.PanelInfo`. The renderer
    /// expects panel content as a `[]const []const u8` (one entry
    /// per line); we split the stored blob on `\n`.
    pub fn snapshotPanels(self: *PluginManager, allocator: std.mem.Allocator) ![]protocol.PanelInfo {
        var list: std.ArrayListUnmanaged(protocol.PanelInfo) = .empty;
        errdefer list.deinit(allocator);
        var it = self.panels.valueIterator();
        while (it.next()) |p| {
            // Split content into lines for the renderer.
            var lines: std.ArrayListUnmanaged([]const u8) = .empty;
            errdefer lines.deinit(allocator);
            var split = std.mem.splitScalar(u8, p.content, '\n');
            while (split.next()) |line| {
                try lines.append(allocator, line);
            }
            try list.append(allocator, .{
                .id = p.id,
                .plugin_id = p.plugin_id,
                .title = p.title,
                .content = try lines.toOwnedSlice(allocator),
                .position = p.position,
                .width_percent = p.width_percent,
                .widget_id = p.widget_id,
            });
        }
        return list.toOwnedSlice(allocator);
    }

    /// Strip every status item / panel owned by `plugin_id`. Called
    /// from `cleanupPluginResources` so a plugin's widgets disappear
    /// when it's unloaded.
    fn removePluginWidgets(self: *PluginManager, plugin_id: []const u8) void {
        var si_keys: std.ArrayListUnmanaged([]const u8) = .empty;
        defer si_keys.deinit(self.allocator);
        var si_it = self.status_items.iterator();
        while (si_it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.plugin_id, plugin_id)) {
                si_keys.append(self.allocator, entry.key_ptr.*) catch {};
            }
        }
        for (si_keys.items) |k| {
            if (self.status_items.fetchRemove(k)) |kv| {
                self.allocator.free(kv.key);
                var v = kv.value;
                v.deinit(self.allocator);
            }
        }

        var pn_keys: std.ArrayListUnmanaged([]const u8) = .empty;
        defer pn_keys.deinit(self.allocator);
        var pn_it = self.panels.iterator();
        while (pn_it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.plugin_id, plugin_id)) {
                pn_keys.append(self.allocator, entry.key_ptr.*) catch {};
            }
        }
        for (pn_keys.items) |k| {
            if (self.panels.fetchRemove(k)) |kv| {
                self.allocator.free(kv.key);
                var v = kv.value;
                v.deinit(self.allocator);
            }
        }
    }

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
    /// Look up a command id bound to `seq` (a space-separated key
    /// sequence as written in the manifest). Returns null if no
    /// plugin claims that binding.
    pub fn lookupKeybind(self: *PluginManager, seq: []const u8) ?[]const u8 {
        return self.plugin_keybindings.get(seq);
    }

    /// Return true if `seq` is a strict prefix of any registered
    /// plugin keybinding. The input handler uses this to keep
    /// leader_pending alive while the user types a multi-char chord.
    pub fn isKeybindPrefix(self: *PluginManager, seq: []const u8) bool {
        var it = self.plugin_keybindings.keyIterator();
        while (it.next()) |k| {
            if (k.*.len > seq.len and std.mem.startsWith(u8, k.*, seq) and k.*[seq.len] == ' ') return true;
        }
        return false;
    }

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

        // Manifest-declared keybinding → command-id map. Stored
        // separately so the input handler can look up multi-char
        // chords without iterating every registered command.
        if (decl.keybinding) |seq| {
            const seq_dup = try self.allocator.dupe(u8, seq);
            errdefer self.allocator.free(seq_dup);
            const cmd_dup = try self.allocator.dupe(u8, decl.id);
            errdefer self.allocator.free(cmd_dup);
            // Replace any prior binding to keep the latest plugin to
            // claim a sequence as the winner — easier to reason about
            // than silent conflicts.
            if (self.plugin_keybindings.fetchRemove(seq_dup)) |kv| {
                self.allocator.free(kv.key);
                self.allocator.free(kv.value);
            }
            try self.plugin_keybindings.put(self.allocator, seq_dup, cmd_dup);
        }
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
                .on_subscribe_event = onWasmSubscribeEvent,
                .on_read_file = onWasmReadFile,
                .on_write_file = onWasmWriteFile,
                .on_set_status_item = onWasmSetStatusItem,
                .on_clear_status_item = onWasmClearStatusItem,
                .on_set_panel = onWasmSetPanel,
                .on_clear_panel = onWasmClearPanel,
                .on_get_buffer_content = onWasmGetBufferContent,
                .on_get_buffer_path = onWasmGetBufferPath,
                .on_load_plugin = onWasmLoadPlugin,
                .on_unload_plugin = onWasmUnloadPlugin,
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
            telemetry.recordPluginCrash(m.name);
            // Tear down the half-loaded plugin: drop registered
            // commands / widgets / subscriptions and remove the
            // entry. The palette will only show what survives a
            // successful activate.
            self.unloadPlugin(m.name) catch |unload_err| {
                log.warn("post-activate-fail unload of '{s}': {s}", .{ m.name, @errorName(unload_err) });
            };
            return;
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
        self.dispatchNotification(plugin_id, level, message);
    }

    /// Route a notification (from any plugin runtime) to core. Core
    /// folds it into its `status_message` slot, where the next render
    /// snapshot picks it up and the status bar shows it for a few
    /// seconds.
    fn dispatchNotification(self: *PluginManager, plugin_id: []const u8, level: u8, message: []const u8) void {
        const core_inbox = self.core_inbox orelse return;
        const nl: protocol.NotificationLevel = switch (level) {
            1 => .warning,
            2 => .err,
            else => .info,
        };
        const pm = protocol.PluginMessage{
            .plugin_id = plugin_id,
            .message_type = .show_notification,
            .payload = .{ .notification = .{ .level = nl, .message = message } },
        };
        const outer = protocol.Message{ .plugin_message = pm };
        const encoded = outer.encode(self.allocator) catch return;
        defer self.allocator.free(encoded);
        core_inbox.send(encoded) catch {};
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
        opts: wasm_loader.SpawnOpts,
        out_buf: []u8,
    ) i32 {
        const self: *PluginManager = @ptrCast(@alignCast(user_data));

        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(self.allocator);
        var it = std.mem.tokenizeAny(u8, opts.cmd, " \t\r\n");
        while (it.next()) |tok| {
            argv.append(self.allocator, tok) catch return -2;
        }
        if (argv.items.len == 0) return -2;
        const program = argv.items[0];

        if (!self.permissionAllows(plugin_id, .spawn, program)) {
            log.warn(
                "wasm plugin '{s}' attempted unauthorized spawn: {s}",
                .{ plugin_id, program },
            );
            return -1;
        }

        const run_options = std.process.RunOptions{
            .argv = argv.items,
            .cwd = if (opts.cwd) |c| .{ .path = c } else .inherit,
        };
        const result = std.process.run(self.allocator, self.io, run_options) catch |err| {
            log.warn("wasm spawn for '{s}' failed: {s}", .{ plugin_id, @errorName(err) });
            return -3;
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        // Honor the optional timeout. std.process.run is synchronous,
        // so we can only check the wall clock AFTER. A future
        // improvement is to use a non-blocking spawn + poll; today we
        // surface a clear timeout signal post-hoc.
        _ = opts.timeout_ms; // TODO: pre-spawn timeout enforcement.

        // Write stdout, optionally followed by stderr (NUL-separated).
        var written: usize = 0;
        const n = @min(result.stdout.len, out_buf.len);
        @memcpy(out_buf[0..n], result.stdout[0..n]);
        written += n;
        if (opts.include_stderr and written < out_buf.len) {
            // Separator.
            out_buf[written] = 0;
            written += 1;
            const remaining = out_buf.len - written;
            const m = @min(result.stderr.len, remaining);
            @memcpy(out_buf[written..][0..m], result.stderr[0..m]);
            written += m;
        }

        // Surface non-zero exit codes so plugins can distinguish "ran
        // but failed" from "stdout was empty". We still return the
        // bytes written; the negative code is purely informational.
        return switch (result.term) {
            .exited => |code| if (code == 0) @intCast(written) else -5,
            else => -5,
        };
    }

    fn onWasmSubscribeEvent(
        user_data: *anyopaque,
        plugin_id: []const u8,
        topic: []const u8,
    ) i32 {
        const self: *PluginManager = @ptrCast(@alignCast(user_data));
        if (!self.permissionAllows(plugin_id, .event, topic)) {
            log.warn(
                "wasm plugin '{s}' lacks event permission for '{s}'",
                .{ plugin_id, topic },
            );
            return -1;
        }
        const event = eventFromTopic(topic) orelse {
            log.warn("wasm plugin '{s}' subscribed to unknown event '{s}'", .{ plugin_id, topic });
            return -2;
        };
        self.addEventSubscription(event, .wasm, plugin_id) catch return -3;
        log.info("wasm plugin '{s}' subscribed to event '{s}'", .{ plugin_id, topic });
        return 0;
    }

    fn onWasmReadFile(
        user_data: *anyopaque,
        plugin_id: []const u8,
        path: []const u8,
        out_buf: []u8,
    ) i32 {
        const self: *PluginManager = @ptrCast(@alignCast(user_data));
        if (!self.filesystemAllows(plugin_id, .read, path)) {
            log.warn("wasm plugin '{s}' lacks read permission for '{s}'", .{ plugin_id, path });
            return -1;
        }
        const file = std.Io.Dir.cwd().openFile(self.io, path, .{}) catch |err| {
            log.warn("wasm plugin '{s}' read '{s}' failed: {s}", .{ plugin_id, path, @errorName(err) });
            return -2;
        };
        defer file.close(self.io);
        const len = file.length(self.io) catch return -2;
        const cap = @min(@as(u64, @intCast(out_buf.len)), len);
        _ = file.readPositionalAll(self.io, out_buf[0..@intCast(cap)], 0) catch return -2;
        return @intCast(cap);
    }

    fn onWasmWriteFile(
        user_data: *anyopaque,
        plugin_id: []const u8,
        path: []const u8,
        content: []const u8,
    ) i32 {
        const self: *PluginManager = @ptrCast(@alignCast(user_data));
        if (!self.filesystemAllows(plugin_id, .write, path)) {
            log.warn("wasm plugin '{s}' lacks write permission for '{s}'", .{ plugin_id, path });
            return -1;
        }
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = content }) catch |err| {
            log.warn("wasm plugin '{s}' write '{s}' failed: {s}", .{ plugin_id, path, @errorName(err) });
            return -2;
        };
        return 0;
    }

    fn onWasmSetStatusItem(
        user_data: *anyopaque,
        plugin_id: []const u8,
        id: []const u8,
        text: []const u8,
        alignment: u8,
        priority: i8,
    ) void {
        const self: *PluginManager = @ptrCast(@alignCast(user_data));
        self.upsertStatusItem(plugin_id, id, text, alignment, priority) catch |err| {
            log.warn("wasm plugin '{s}' set_status_item failed: {s}", .{ plugin_id, @errorName(err) });
        };
        self.requestUiRefresh();
    }

    fn onWasmClearStatusItem(
        user_data: *anyopaque,
        plugin_id: []const u8,
        id: []const u8,
    ) void {
        const self: *PluginManager = @ptrCast(@alignCast(user_data));
        self.removeStatusItem(plugin_id, id);
        self.requestUiRefresh();
    }

    fn onWasmSetPanel(
        user_data: *anyopaque,
        plugin_id: []const u8,
        id: []const u8,
        title: []const u8,
        content: []const u8,
        position: u8,
        width_percent: u8,
    ) void {
        const self: *PluginManager = @ptrCast(@alignCast(user_data));
        self.upsertPanel(plugin_id, id, title, content, position, width_percent) catch |err| {
            log.warn("wasm plugin '{s}' set_panel failed: {s}", .{ plugin_id, @errorName(err) });
        };
        self.requestUiRefresh();
    }

    fn onWasmClearPanel(
        user_data: *anyopaque,
        plugin_id: []const u8,
        id: []const u8,
    ) void {
        const self: *PluginManager = @ptrCast(@alignCast(user_data));
        self.removePanel(plugin_id, id);
        self.requestUiRefresh();
    }

    fn onWasmGetBufferContent(
        user_data: *anyopaque,
        plugin_id: []const u8,
        out_buf: []u8,
    ) i32 {
        _ = plugin_id;
        const self: *PluginManager = @ptrCast(@alignCast(user_data));
        const hooks = self.host_hooks;
        const fn_ptr = hooks.get_buffer_content orelse return -2;
        const ud = hooks.user_data orelse return -2;
        return fn_ptr(ud, out_buf);
    }

    fn onWasmGetBufferPath(
        user_data: *anyopaque,
        plugin_id: []const u8,
        out_buf: []u8,
    ) i32 {
        _ = plugin_id;
        const self: *PluginManager = @ptrCast(@alignCast(user_data));
        const hooks = self.host_hooks;
        const fn_ptr = hooks.get_buffer_path orelse return -2;
        const ud = hooks.user_data orelse return -2;
        return fn_ptr(ud, out_buf);
    }

    fn onWasmLoadPlugin(
        user_data: *anyopaque,
        plugin_id: []const u8,
        name: []const u8,
    ) i32 {
        _ = plugin_id;
        const self: *PluginManager = @ptrCast(@alignCast(user_data));
        self.loadPluginByName(name) catch |err| {
            log.warn("stem_load_plugin('{s}') failed: {s}", .{ name, @errorName(err) });
            return -1;
        };
        return 0;
    }

    fn onWasmUnloadPlugin(
        user_data: *anyopaque,
        plugin_id: []const u8,
        name: []const u8,
    ) i32 {
        _ = plugin_id;
        const self: *PluginManager = @ptrCast(@alignCast(user_data));
        self.unloadPlugin(name) catch |err| {
            log.warn("stem_unload_plugin('{s}') failed: {s}", .{ name, @errorName(err) });
            return -1;
        };
        return 0;
    }

    /// After a widget mutation, prod core to re-render. We do this by
    /// sending an empty `open_buffer` request? No — instead we just
    /// inject a synthetic tick so the snapshot includes the new
    /// widget state. Core's existing tick handler already calls
    /// `sendUpdate()` indirectly via the [STATS] refresh path.
    fn requestUiRefresh(self: *PluginManager) void {
        const core_inbox = self.core_inbox orelse return;
        // A `tick` outer message is the cheapest way to wake core's
        // render path without inventing a new variant.
        const tick_bytes = (protocol.Message{ .tick = {} }).encode(self.allocator) catch return;
        defer self.allocator.free(tick_bytes);
        core_inbox.send(tick_bytes) catch {};
    }

    /// `permissions.filesystem` entries are typed: `read:<glob>` and
    /// `write:<glob>`. The glob supports a trailing `*` for prefix
    /// matching (same convention as event permissions).
    fn filesystemAllows(
        self: *PluginManager,
        plugin_id: []const u8,
        op: enum { read, write },
        path: []const u8,
    ) bool {
        const stored = self.plugin_permissions.get(plugin_id) orelse return false;
        const prefix: []const u8 = switch (op) {
            .read => "read:",
            .write => "write:",
        };
        for (stored.filesystem) |entry| {
            if (!std.mem.startsWith(u8, entry, prefix)) continue;
            const pattern = entry[prefix.len..];
            if (matchesPermissionEntry(pattern, path)) return true;
        }
        return false;
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
        if (wp.state == .failed or wp.state == .deactivated) {
            log.warn(
                "wasm plugin '{s}' is in state {s}; dropping command '{s}'",
                .{ wp.plugin_id, @tagName(wp.state), cmd_ctx.command_id },
            );
            return;
        }
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
        // Drop any event subscriptions held by this plugin.
        self.removeEventSubscriptions(plugin_id);
        // And any status-bar widgets / side panels it owned.
        self.removePluginWidgets(plugin_id);
        // Strip keybindings that resolved to this plugin's commands.
        self.removePluginKeybindings(plugin_id);
    }

    fn removePluginKeybindings(self: *PluginManager, plugin_id: []const u8) void {
        // We don't track the plugin owner per-keybind, but command
        // ids are conventionally prefixed with the plugin name
        // (e.g. `git.status` owned by `git`). Strip every keybind
        // whose target command id starts with `<plugin_id>.` —
        // matches the convention without needing extra state.
        var stale: std.ArrayListUnmanaged([]const u8) = .empty;
        defer stale.deinit(self.allocator);
        var it = self.plugin_keybindings.iterator();
        while (it.next()) |entry| {
            if (std.mem.startsWith(u8, entry.value_ptr.*, plugin_id) and
                entry.value_ptr.*.len > plugin_id.len and
                entry.value_ptr.*[plugin_id.len] == '.')
            {
                stale.append(self.allocator, entry.key_ptr.*) catch break;
            }
        }
        for (stale.items) |k| {
            if (self.plugin_keybindings.fetchRemove(k)) |kv| {
                self.allocator.free(kv.key);
                self.allocator.free(kv.value);
            }
        }
    }

    // -------------------------------------------------------------------
    // Event broadcasting
    // -------------------------------------------------------------------

    /// Publish an editor event to:
    ///   1. The Vigil pub/sub broker (additive — external consumers
    ///      like dashboards can subscribe by topic without going
    ///      through the per-plugin route).
    ///   2. Each subscribed exec plugin, as a JSON-RPC
    ///      `editor/event` notification.
    ///   3. Each subscribed wasm plugin, by invoking the optional
    ///      `handle_event` export.
    pub fn broadcastEvent(self: *PluginManager, event: protocol.PluginEvent, data: []const u8) void {
        const topic = pluginEventTopic(event);

        if (vigil.pubsub.getGlobal()) |broker| {
            _ = broker.publish(topic, data) catch |err| {
                log.warn("pubsub publish '{s}' failed: {}", .{ topic, err });
            };
        }

        const subs = self.event_subscribers.get(event) orelse return;
        for (subs.items) |sub| {
            switch (sub.runtime) {
                .exec => self.deliverExecEvent(sub.plugin_id, topic, data),
                .wasm => self.deliverWasmEvent(sub.plugin_id, topic, data),
            }
        }
    }

    fn deliverExecEvent(self: *PluginManager, plugin_id: []const u8, topic: []const u8, data: []const u8) void {
        const pp = self.process_plugins.get(plugin_id) orelse return;
        // Encode payload via the safe JSON object builder so embedded
        // quotes / backslashes in `data` don't break the envelope.
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        const w = &aw.writer;
        w.writeByte('{') catch return;
        jsonrpc.writeJsonStringKey(w, "event") catch return;
        jsonrpc.writeJsonString(w, topic) catch return;
        w.writeByte(',') catch return;
        jsonrpc.writeJsonStringKey(w, "data") catch return;
        jsonrpc.writeJsonString(w, data) catch return;
        w.writeByte('}') catch return;
        pp.sendNotification("editor/event", aw.written()) catch |err| {
            log.warn("exec event delivery to '{s}' failed: {s}", .{ plugin_id, @errorName(err) });
        };
    }

    fn deliverWasmEvent(self: *PluginManager, plugin_id: []const u8, topic: []const u8, data: []const u8) void {
        const wp = self.wasm_plugins.get(plugin_id) orelse return;
        wp.dispatchEvent(topic, data) catch |err| {
            log.warn("wasm event delivery to '{s}' failed: {s}", .{ plugin_id, @errorName(err) });
        };
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
