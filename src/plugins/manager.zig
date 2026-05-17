const std = @import("std");
const log = std.log.scoped(.PluginManager);
const vigil = @import("vigil");
const protocol = @import("../kernel/protocol.zig");
const interface = @import("interface.zig");
const context = @import("context.zig");
const Plugin = @import("plugin.zig").Plugin;
const CommandRegistry = @import("../kernel/command.zig").CommandRegistry;
const UIManager = @import("ui_manager.zig").UIManager;
const crash_isolation = @import("crash_isolation.zig");
const MessageBus = @import("../kernel/message_bus.zig").MessageBus;
const telemetry = @import("../services/telemetry.zig");
const host_abi = @import("host_abi.zig");
const manifest_mod = @import("manifest.zig");
const process_loader = @import("process_loader.zig");
const ProcessPlugin = process_loader.ProcessPlugin;
const jsonrpc = @import("jsonrpc.zig");
const logger_service = @import("../services/logger.zig");

pub const PluginManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_block: std.process.Environ.Block,
    plugins: std.StringHashMapUnmanaged(*Plugin),
    /// Out-of-process plugins (Phase 1). Parallel to `plugins` (which
    /// holds in-process .dylib plugins). Event broadcasts and command
    /// routing iterate both maps.
    process_plugins: std.StringHashMapUnmanaged(*ProcessPlugin) = .empty,
    ui_manager: UIManager,

    /// Vigil process group that mirrors `plugins` — used for broadcast
    /// operations (graceful shutdown, group-wide health pings, telemetry
    /// counts). Mutated alongside `plugins` so the two stay in sync.
    plugin_group: ?vigil.ProcessGroup = null,

    core_inbox: ?*vigil.Inbox = null,
    ui_bus: *MessageBus,

    command_registry: *CommandRegistry,

    allocated_contexts: std.ArrayListUnmanaged(*PluginCommandContext),

    event_subscribers: std.AutoHashMapUnmanaged(protocol.PluginEvent, std.ArrayListUnmanaged([]const u8)),

    plugin_configs: std.StringHashMapUnmanaged([]const u8),

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        environ_block: std.process.Environ.Block,
        ui_bus: *MessageBus,
        command_registry: *CommandRegistry,
    ) PluginManager {
        // Install SIGSEGV/SIGBUS handlers as soon as we know we're going
        // to be loading plugins. Idempotent across managers/threads.
        _ = crash_isolation.install();
        // Initialize the host-side plugin handle registry. Required
        // before any plugin is loaded so accessors can look up handles.
        host_abi.init(allocator);
        return .{
            .allocator = allocator,
            .io = io,
            .environ_block = environ_block,
            .plugins = .empty,
            .ui_manager = UIManager.init(allocator),
            .core_inbox = null,
            .ui_bus = ui_bus,
            .command_registry = command_registry,
            .allocated_contexts = .empty,
            .event_subscribers = .empty,
            .plugin_configs = .empty,
        };
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

        // First-run convenience: if ~/.stem/plugins/ doesn't exist or is empty,
        // seed it with the plugins shipped alongside the stem binary.
        self.seedBundledPluginsIfEmpty(plugin_dir) catch |err| {
            log.warn("Could not seed bundled plugins: {}", .{err});
        };

        var dir = std.Io.Dir.openDirAbsolute(self.io, plugin_dir, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) return;
            log.warn("Failed to open plugin dir {s}: {}", .{ plugin_dir, err });
            return;
        };
        defer dir.close(self.io);

        var it = dir.iterate();
        while (it.next(self.io) catch null) |entry| {
            const full_path = try std.fs.path.join(self.allocator, &[_][]const u8{ plugin_dir, entry.name });
            defer self.allocator.free(full_path);

            switch (entry.kind) {
                .file => {
                    // Flat .dylib layout — Phase 0 compatibility.
                    if (!isSharedLib(entry.name)) continue;
                    self.loadPlugin(full_path) catch |err| {
                        log.err("Failed to auto-load plugin {s}: {}", .{ entry.name, err });
                    };
                },
                .directory => {
                    // Plugin-directory layout — Phase 1. Looks for a
                    // manifest at `<dir>/plugin.json`. Skips silently
                    // if the manifest is missing (treat as a stray dir).
                    self.tryLoadPluginDir(full_path) catch |err| {
                        log.warn("Plugin dir {s} failed to load: {s}", .{ entry.name, @errorName(err) });
                    };
                },
                else => continue,
            }
        }
    }

    /// Try to load a plugin from a directory containing a `plugin.json`
    /// manifest. Routes to the appropriate loader based on the
    /// manifest's `runtime` field.
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
            .dylib => {
                const entry_path = try std.fs.path.join(self.allocator, &.{ plugin_dir, m.entry });
                defer self.allocator.free(entry_path);
                try self.loadPlugin(entry_path);
            },
            .exec => {
                try self.loadProcessPluginFromManifest(plugin_dir, &m);
            },
            .wasm => {
                log.warn("Plugin '{s}' requests wasm runtime — Phase 2 not yet shipped", .{m.name});
                return error.RuntimeNotSupported;
            },
        }
    }

    /// Match shared libraries by name. Handles versioned Linux sonames
    /// (`libfoo.so.0`) which `std.fs.path.extension` would report as `.0`.
    pub fn isSharedLib(name: []const u8) bool {
        // A bare extension (".dylib") isn't a real shared library — require
        // at least one character before the dot.
        if (name.len > 6 and std.mem.endsWith(u8, name, ".dylib")) return true;
        if (name.len > 4 and std.mem.endsWith(u8, name, ".dll")) return true;
        if (name.len > 3 and std.mem.endsWith(u8, name, ".so")) return true;
        // `.so.N` or `.so.N.M` (Linux versioned soname).
        if (std.mem.indexOf(u8, name, ".so.")) |idx| {
            const suffix = name[idx + 4 ..];
            if (suffix.len == 0) return false; // empty version is bogus
            for (suffix) |c| {
                if (!(std.ascii.isDigit(c) or c == '.')) return false;
            }
            return true;
        }
        return false;
    }

    /// On first launch, copy bundled plugin libraries from a location near the
    /// stem binary into `plugin_dir`. Looks in (in order): the dir named by the
    /// STEM_BUNDLED_PLUGINS env var, `<exe_dir>/../lib/stem/plugins`,
    /// `<exe_dir>/../lib`. No-op if `plugin_dir` already contains any plugins.
    fn seedBundledPluginsIfEmpty(self: *PluginManager, plugin_dir: []const u8) !void {
        // Bail out if the directory already has any plugin file.
        if (std.Io.Dir.openDirAbsolute(self.io, plugin_dir, .{ .iterate = true })) |d_const| {
            var d = d_const;
            defer d.close(self.io);
            var it = d.iterate();
            while (it.next(self.io) catch null) |entry| {
                if (entry.kind != .file) continue;
                if (isSharedLib(entry.name)) return; // already populated
            }
        } else |err| switch (err) {
            error.FileNotFound => {}, // we'll create it below
            else => return err,
        }

        const env: std.process.Environ = .{ .block = self.environ_block };

        // Build a small list of candidate source directories to copy from.
        var candidates: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (candidates.items) |c| self.allocator.free(c);
            candidates.deinit(self.allocator);
        }

        if (env.getPosix("STEM_BUNDLED_PLUGINS")) |override| {
            try candidates.append(self.allocator, try self.allocator.dupe(u8, override));
        }

        var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (std.process.executableDirPath(self.io, &exe_buf)) |exe_dir_len| {
            const exe_dir = exe_buf[0..exe_dir_len];
            const c1 = try std.fs.path.join(self.allocator, &.{ exe_dir, "..", "lib", "stem", "plugins" });
            try candidates.append(self.allocator, c1);
            const c2 = try std.fs.path.join(self.allocator, &.{ exe_dir, "..", "lib" });
            try candidates.append(self.allocator, c2);
        } else |_| {}

        for (candidates.items) |src_dir| {
            var src = std.Io.Dir.openDirAbsolute(self.io, src_dir, .{ .iterate = true }) catch continue;
            defer src.close(self.io);
            // Found a candidate. Make sure the destination exists.
            std.Io.Dir.cwd().createDirPath(self.io, plugin_dir) catch {};
            var dst = std.Io.Dir.openDirAbsolute(self.io, plugin_dir, .{}) catch continue;
            defer dst.close(self.io);
            var copied: usize = 0;
            var it = src.iterate();
            while (it.next(self.io) catch null) |entry| {
                if (entry.kind != .file) continue;
                if (!isSharedLib(entry.name)) continue;
                src.copyFile(entry.name, dst, entry.name, self.io, .{}) catch |err| {
                    log.warn("Failed to seed plugin {s}: {}", .{ entry.name, err });
                    continue;
                };
                copied += 1;
            }
            if (copied > 0) {
                log.info("Seeded {d} bundled plugin(s) into {s} from {s}", .{ copied, plugin_dir, src_dir });
                return;
            }
        }
    }

    pub fn deinit(self: *PluginManager) void {
        if (self.plugin_group) |*group| {
            group.deinit();
            self.plugin_group = null;
        }

        var it = self.plugins.valueIterator();
        while (it.next()) |plugin_ptr| {
            const plugin = plugin_ptr.*;
            self.cleanupPluginResources(plugin.id);
            plugin.deinit(self.allocator);
            self.allocator.destroy(plugin);
        }
        self.plugins.deinit(self.allocator);
        self.ui_manager.deinit();

        self.allocated_contexts.deinit(self.allocator);

        var event_it = self.event_subscribers.valueIterator();
        while (event_it.next()) |sub_list| {
            for (sub_list.items) |plugin_id| {
                self.allocator.free(plugin_id);
            }
            sub_list.deinit(self.allocator);
        }
        self.event_subscribers.deinit(self.allocator);

        var config_it = self.plugin_configs.iterator();
        while (config_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.plugin_configs.deinit(self.allocator);
    }

    fn cleanupPluginResources(self: *PluginManager, plugin_id: []const u8) void {
        self.ui_manager.cleanupPluginWidgets(plugin_id);

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

        var event_it = self.event_subscribers.valueIterator();
        while (event_it.next()) |sub_list| {
            var j: usize = 0;
            while (j < sub_list.items.len) {
                if (std.mem.eql(u8, sub_list.items[j], plugin_id)) {
                    self.allocator.free(sub_list.items[j]);
                    _ = sub_list.swapRemove(j);
                } else {
                    j += 1;
                }
            }
        }
    }

    pub fn unloadPlugin(self: *PluginManager, plugin_id: []const u8) !void {
        if (self.plugins.fetchRemove(plugin_id)) |kv| {
            const plugin = kv.value;
            self.cleanupPluginResources(plugin.id);
            plugin.deinit(self.allocator);
            self.allocator.destroy(plugin);
            log.info("Unloaded plugin: {s}", .{plugin_id});
        } else {
            return error.PluginNotFound;
        }
    }

    pub fn loadPlugin(self: *PluginManager, plugin_path: []const u8) !void {
        var lib = std.DynLib.open(plugin_path) catch |err| {
            log.err("Failed to load plugin at {s}: {}", .{ plugin_path, err });
            return err;
        };
        errdefer lib.close();

        const plugin_interface = lib.lookup(*const interface.PluginInterface, "plugin_entry") orelse {
            log.err("Plugin at {s} missing 'plugin_entry' symbol", .{plugin_path});
            return error.InvalidPluginInterface;
        };

        if (plugin_interface.version != interface.PLUGIN_VERSION) {
            log.err(
                "Plugin at {s} is ABI v{d}, this stem is v{d}. " ++
                    "Rebuild it (zig build) and refresh ~/.stem/plugins/ — " ++
                    "see src/plugins/interface.zig for the changelog.",
                .{ plugin_path, plugin_interface.version, interface.PLUGIN_VERSION },
            );
            return error.IncompatiblePlugin;
        }

        const id_name = std.mem.span(plugin_interface.name);
        if (self.plugins.contains(id_name)) {
            log.err("Plugin with ID '{s}' already loaded", .{id_name});
            return error.DuplicatePluginId;
        }

        const plugin = try self.allocator.create(Plugin);
        errdefer self.allocator.destroy(plugin);

        const id = try self.allocator.dupe(u8, id_name);
        errdefer self.allocator.free(id);

        // Null-terminated dupe so `stem_plugin_id` can return a C string
        // without re-allocating per call. One alloc, freed in Plugin.deinit.
        const id_c_buf = try self.allocator.alloc(u8, id.len + 1);
        errdefer self.allocator.free(id_c_buf);
        @memcpy(id_c_buf[0..id.len], id);
        id_c_buf[id.len] = 0;

        const path_dupe = try self.allocator.dupe(u8, plugin_path);
        errdefer self.allocator.free(path_dupe);

        plugin.* = .{
            .id = id,
            .id_c = id_c_buf[0..id.len :0].ptr,
            .path = path_dupe,
            .lib = lib,
            .interface = plugin_interface.*,
            .state = .loaded,
            .load_time = std.Io.Clock.real.now(self.io).toSeconds(),
        };

        const inbox = try vigil.inbox(self.allocator);
        errdefer inbox.close();

        plugin.inbox = inbox;
        plugin.core_inbox = self.core_inbox;
        plugin.ui_inbox = self.ui_bus.inbox;

        // v3 ABI: assign a handle and register it BEFORE the worker
        // spawns so the plugin can call host accessors immediately on
        // entry to `activate`.
        plugin.handle = try host_abi.registerHandle(plugin);
        errdefer host_abi.unregisterHandle(plugin.handle);

        const thread = try std.Thread.spawn(.{}, pluginMain, .{plugin});
        plugin.thread = thread;

        // From here on, the plugin is owned by the map and its outer
        // errdefers should not fire. Insert and accept ownership.
        self.plugins.put(self.allocator, plugin.id, plugin) catch |err| {
            // Spawn already kicked off; signal the thread to exit. We don't
            // have a clean shutdown API for "thread that just started"; in
            // practice this branch is essentially never hit (the only way
            // is OOM on a single hashmap entry). Detach so we don't leak
            // the OS thread handle.
            thread.detach();
            return err;
        };

        // Lazily create the process group on first plugin; mirror plugin
        // membership in it. We use this for broadcast operations later.
        if (self.plugin_group == null) {
            self.plugin_group = vigil.ProcessGroup.init(self.allocator, "plugins") catch null;
        }
        if (self.plugin_group) |*group| {
            group.add(plugin.id, inbox) catch |err| {
                log.warn("could not add plugin '{s}' to process group: {}", .{ plugin.id, err });
            };
        }

        log.info("Loaded plugin: {s}", .{plugin.id});
    }

    // -------------------------------------------------------------------
    // Out-of-process plugins (Phase 1).
    //
    // A `ProcessPlugin` is a child process speaking JSON-RPC over
    // stdio. The methods below define the host's RPC surface — what
    // a plugin can call. Plugin-side handlers are simple symmetric
    // functions that translate JSON-RPC calls to/from the same
    // protocol.PluginMessage events the in-process .dylib plugins
    // see, so commands + events flow through one registry regardless
    // of which loader serves them.
    // -------------------------------------------------------------------

    pub fn loadProcessPluginFromManifest(
        self: *PluginManager,
        plugin_dir: []const u8,
        m: *const manifest_mod.Manifest,
    ) !void {
        if (self.process_plugins.contains(m.name)) return error.DuplicatePluginId;

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

        try pp.start();

        try self.process_plugins.put(self.allocator, name_dup, pp);

        // Synchronous `initialize` handshake: tell the plugin which
        // ABI version it's talking to, and its assigned id. Plugins
        // use this to bind any local state before the first command.
        const init_params = try std.fmt.allocPrint(
            self.allocator,
            "{{\"abi_version\":{d},\"plugin_id\":\"{s}\"}}",
            .{ host_abi.ABI_VERSION_FOR_PROC, m.name },
        );
        defer self.allocator.free(init_params);
        try pp.sendNotification("plugin/initialize", init_params);

        log.info("Loaded process plugin: {s} ({s})", .{ m.name, entry_path });
    }

    /// JSON-RPC notification handler — runs on the ProcessPlugin's
    /// reader thread. Routes to the existing in-process plumbing
    /// where possible (so commands appear in the same palette etc.).
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
            // params: { "plugin_id": string, "id": string, "title": string, "description": string }
            self.registerProcessCommand(params) catch |err| {
                log.warn("registerCommand failed: {s}", .{@errorName(err)});
            };
            return;
        }

        if (std.mem.eql(u8, method, "plugin/subscribeEvent")) {
            // params: { "plugin_id": string, "event": string }
            self.subscribeProcessEvent(params) catch {};
            return;
        }

        if (std.mem.eql(u8, method, "editor/showNotification")) {
            // params: { "level": int, "message": string }
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
        params: std.json.Value,
    ) void {
        _ = params;
        const self: *PluginManager = @ptrCast(@alignCast(user_data));
        _ = self;
        log.info("process plugin: request '{s}' id={d} (not yet handled)", .{ method, id });
        // Future: route editor/getState etc. here.
    }

    fn handleProcessExit(user_data: *anyopaque) void {
        _ = user_data;
        log.info("process plugin exited", .{});
        // Future: trigger the same RestartPolicy as in-process plugins.
    }

    fn registerProcessCommand(self: *PluginManager, params: std.json.Value) !void {
        if (params != .object) return error.InvalidParams;
        const obj = params.object;
        const plugin_id = obj.get("plugin_id") orelse return error.InvalidParams;
        const id = obj.get("id") orelse return error.InvalidParams;
        const title = obj.get("title") orelse return error.InvalidParams;
        const description = if (obj.get("description")) |d| d else std.json.Value{ .string = "" };
        if (plugin_id != .string or id != .string or title != .string or description != .string) return error.InvalidParams;

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
        _ = self;
        _ = params;
        // Future: extract `plugin_id` + `event`, add to event_subscribers
        // map. broadcastEvent already iterates subscribers; we'll need a
        // parallel path for the process_plugins map.
    }

    /// Called from the (about-to-exit) worker thread after a crash.
    /// Records the crash time and — if the policy allows it — sets
    /// `restart_requested`. The manager's `tickRestarts` will see the
    /// flag on its next tick and do the actual reload work.
    fn markForRestart(plugin: *Plugin) void {
        const now_ms = vigil.compat.milliTimestamp();
        plugin.crash_history.record(now_ms);
        const recent = plugin.crash_history.recentCount(now_ms, plugin.restart_policy.window_ms);
        if (recent > plugin.restart_policy.max_restarts_in_window) {
            log.warn(
                "Plugin '{s}' exceeded restart budget ({d}/{d}ms); giving up",
                .{ plugin.id, recent, plugin.restart_policy.window_ms },
            );
            return;
        }
        plugin.next_restart_after_ms = now_ms +
            @as(i64, @intCast(recent)) * plugin.restart_policy.restart_backoff_ms;
        plugin.restart_requested.store(true, .release);
    }

    fn pluginMain(plugin: *Plugin) void {
        plugin.state = .running;
        const handle = plugin.handle;

        // Install the SIGSEGV/SIGBUS handler on first use. Idempotent
        // across threads.
        _ = crash_isolation.install();

        // v3: plugin's `activate` takes a PluginHandle (extern u64) and
        // returns i32. No Zig structs cross the boundary.
        if (plugin.interface.activate) |activate_fn| {
            const ActivateCall = struct {
                fn run(h: interface.PluginHandle, fn_ptr: *const fn (interface.PluginHandle) callconv(.c) i32, rc_out: *i32) void {
                    rc_out.* = fn_ptr(h);
                }
            };
            var rc: i32 = 0;
            const res = crash_isolation.runIsolated(.{ handle, activate_fn, &rc }, ActivateCall.run);
            if (res == .crashed) {
                plugin.state = .failed;
                telemetry.recordPluginCrash(plugin.id);
                log.err("Plugin {s} CRASHED during activate (signal={d}); marked dead", .{ plugin.id, crash_isolation.lastCrashSignal() });
                markForRestart(plugin);
                return;
            }
            if (rc != 0) {
                plugin.state = .failed;
                log.err("Plugin {s} activate returned {d}", .{ plugin.id, rc });
                return;
            }
        }

        const inbox = plugin.inbox.?;

        while (plugin.state == .running) {
            const msg = inbox.recv() catch |err| {
                if (err == error.InboxClosed) break;
                continue;
            };
            defer msg.deinit();

            const payload = msg.payload orelse continue;
            // payload is a wire-encoded outer `protocol.Message`. We
            // peek at the tag to find plugin_messages and quit signals;
            // anything else is ignored. For plugin_message we hand the
            // plugin the inner bytes (skipping the outer tag byte) —
            // the plugin's SDK decodes those into a PluginMessage on
            // its own side.
            if (payload.len == 0) continue;
            const tag = payload[0];
            if (tag == protocol.Message.TAG_QUIT) {
                plugin.state = .unloading;
                break;
            }
            if (tag != protocol.Message.TAG_PLUGIN_MSG) continue;
            if (payload.len < 2) continue;

            const inner = payload[1..];
            if (plugin.interface.handle_message) |handler| {
                const HandleCall = struct {
                    fn run(
                        h: interface.PluginHandle,
                        fn_ptr: *const fn (interface.PluginHandle, [*]const u8, usize) callconv(.c) i32,
                        ptr: [*]const u8,
                        len: usize,
                    ) void {
                        _ = fn_ptr(h, ptr, len);
                    }
                };
                const res = crash_isolation.runIsolated(
                    .{ handle, handler, inner.ptr, inner.len },
                    HandleCall.run,
                );
                if (res == .crashed) {
                    plugin.state = .failed;
                    telemetry.recordPluginCrash(plugin.id);
                    log.err("Plugin {s} CRASHED during handle_message (signal={d}); marked dead", .{ plugin.id, crash_isolation.lastCrashSignal() });
                    markForRestart(plugin);
                    break;
                }
            }
        }

        if (plugin.interface.deactivate) |deactivate_fn| {
            const DeactivateCall = struct {
                fn run(h: interface.PluginHandle, fn_ptr: *const fn (interface.PluginHandle) callconv(.c) void) void {
                    fn_ptr(h);
                }
            };
            // Best-effort: if deactivate crashes we can't do anything useful;
            // the plugin is already on its way out.
            _ = crash_isolation.runIsolated(.{ handle, deactivate_fn }, DeactivateCall.run);
        }

        // Release the handle so the registry doesn't grow unbounded
        // across restarts.
        host_abi.unregisterHandle(handle);
    }

    const PluginCommandContext = struct {
        manager: *PluginManager,
        plugin_id: []const u8,
        command_id: []const u8,
        registry_id: []const u8,
        registry_title: []const u8,
        registry_description: []const u8,
    };

    fn executePluginCommand(ctx: *anyopaque, context_ptr: ?*const anyopaque) anyerror!void {
        _ = ctx;
        const cmd_ctx: *const PluginCommandContext = @ptrCast(@alignCast(context_ptr.?));
        const self = cmd_ctx.manager;

        const plugin = self.plugins.get(cmd_ctx.plugin_id) orelse {
            log.warn("Plugin {s} not found for command {s}", .{ cmd_ctx.plugin_id, cmd_ctx.command_id });
            return;
        };

        if (plugin.state != .running) {
            log.warn("Plugin {s} is not running", .{cmd_ctx.plugin_id});
            return;
        }

        const msg = protocol.PluginMessage{
            .plugin_id = cmd_ctx.plugin_id,
            .message_type = .execute_command,
            .payload = .{ .command_execute = cmd_ctx.command_id },
        };

        const encoded = try msg.encode(self.allocator);
        defer self.allocator.free(encoded);

        try plugin.inbox.?.send(encoded);
    }

    // Plugin crash isolation lives in `crash_isolation.zig`. `pluginMain`
    // wraps each call into plugin code (`init` / `handleMessage` /
    // `deinit`) with `crash_isolation.runIsolated`, which uses a per-
    // thread sigsetjmp checkpoint and a SIGSEGV/SIGBUS handler that
    // siglongjmps back. A crashing plugin is marked `.failed` and the
    // editor keeps running. See that file for the caveats (silent memory
    // corruption, leaked locks/allocs after crash).
    pub fn handlePluginMessage(self: *PluginManager, msg: protocol.PluginMessage) !void {
        switch (msg.message_type) {
            .register_command => {
                log.info("PluginManager: Received register_command from {s}", .{msg.plugin_id});
                const payload = msg.payload.command_register;

                // Dupe each field into a local with its own errdefer
                // before assembling the struct. Doing the dupes inline
                // inside the struct literal would leak any earlier
                // successful dupes if a later one OOMs — the errdefer
                // below only fires after `ctx.*` is fully assigned and
                // can't reach the orphaned slices.
                const plugin_id_dupe = try self.allocator.dupe(u8, msg.plugin_id);
                errdefer self.allocator.free(plugin_id_dupe);
                const command_id_dupe = try self.allocator.dupe(u8, payload.id);
                errdefer self.allocator.free(command_id_dupe);
                const registry_id_dupe = try self.allocator.dupe(u8, payload.id);
                errdefer self.allocator.free(registry_id_dupe);
                const registry_title_dupe = try self.allocator.dupe(u8, payload.title);
                errdefer self.allocator.free(registry_title_dupe);
                const registry_description_dupe = try self.allocator.dupe(u8, payload.description);
                errdefer self.allocator.free(registry_description_dupe);

                const ctx = try self.allocator.create(PluginCommandContext);
                errdefer self.allocator.destroy(ctx);
                ctx.* = .{
                    .manager = self,
                    .plugin_id = plugin_id_dupe,
                    .command_id = command_id_dupe,
                    .registry_id = registry_id_dupe,
                    .registry_title = registry_title_dupe,
                    .registry_description = registry_description_dupe,
                };

                self.command_registry.register(
                    ctx.registry_id,
                    ctx.registry_title,
                    ctx.registry_description,
                    executePluginCommand,
                    ctx,
                ) catch |err| {
                    return err;
                };

                try self.allocated_contexts.append(self.allocator, ctx);

                log.info("Plugin {s} registered command: {s}", .{ msg.plugin_id, payload.id });
            },
            .unregister_command => {
                const cmd_id = msg.payload.command_unregister;
                if (self.command_registry.unregister(cmd_id)) {
                    log.info("Plugin {s} unregistered command: {s}", .{ msg.plugin_id, cmd_id });
                }
            },
            .subscribe_event => {
                const event = msg.payload.event_subscribe;
                var entry = self.event_subscribers.getOrPut(self.allocator, event) catch return;
                if (!entry.found_existing) {
                    entry.value_ptr.* = .empty;
                }
                const id_dupe = self.allocator.dupe(u8, msg.plugin_id) catch return;
                entry.value_ptr.append(self.allocator, id_dupe) catch {
                    self.allocator.free(id_dupe);
                    return;
                };
                log.info("Plugin {s} subscribed to event: {s}", .{ msg.plugin_id, @tagName(event) });
            },
            .unsubscribe_event => {
                const event = msg.payload.event_unsubscribe;
                if (self.event_subscribers.getPtr(event)) |sub_list| {
                    var i: usize = 0;
                    while (i < sub_list.items.len) {
                        if (std.mem.eql(u8, sub_list.items[i], msg.plugin_id)) {
                            self.allocator.free(sub_list.items[i]);
                            _ = sub_list.swapRemove(i);
                        } else {
                            i += 1;
                        }
                    }
                }
                log.info("Plugin {s} unsubscribed from event: {s}", .{ msg.plugin_id, @tagName(event) });
            },
            .set_config => {
                const cfg = msg.payload.config_set;
                const composite_key = std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ msg.plugin_id, cfg.key }) catch return;
                errdefer self.allocator.free(composite_key);
                const val_dupe = self.allocator.dupe(u8, cfg.value) catch {
                    self.allocator.free(composite_key);
                    return;
                };
                if (self.plugin_configs.fetchRemove(composite_key)) |old| {
                    self.allocator.free(old.key);
                    self.allocator.free(old.value);
                }
                self.plugin_configs.put(self.allocator, composite_key, val_dupe) catch {
                    self.allocator.free(composite_key);
                    self.allocator.free(val_dupe);
                    return;
                };
                log.info("Plugin {s} set config: {s}", .{ msg.plugin_id, cfg.key });
            },
            .get_config => {
                const key = msg.payload.config_get;
                var buf: [512]u8 = undefined;
                const composite_key = std.fmt.bufPrint(&buf, "{s}:{s}", .{ msg.plugin_id, key }) catch return;
                const value = self.plugin_configs.get(composite_key);

                if (self.plugins.get(msg.plugin_id)) |plugin| {
                    if (plugin.inbox) |inbox| {
                        const response = protocol.PluginMessage{
                            .plugin_id = msg.plugin_id,
                            .message_type = .config_response,
                            .payload = .{ .config_value = .{ .key = key, .value = value } },
                            .correlation_id = msg.correlation_id,
                        };
                        // v3: encode outer wrapper so the worker sees a
                        // protocol.Message it can route to handle_message.
                        const outer = protocol.Message{ .plugin_message = response };
                        const encoded = outer.encode(self.allocator) catch return;
                        defer self.allocator.free(encoded);
                        inbox.send(encoded) catch {};
                    }
                }
            },

            .create_status_item => {
                const payload = msg.payload.status_item_create;
                try self.ui_manager.createStatusItem(
                    msg.plugin_id,
                    payload.id,
                    payload.text,
                    payload.alignment,
                    payload.priority,
                );
            },
            .update_status_item => {
                const payload = msg.payload.status_item_update;
                try self.ui_manager.updateStatusItem(msg.plugin_id, payload.id, payload.text);
            },
            .destroy_status_item => {
                self.ui_manager.destroyStatusItem(msg.plugin_id, msg.payload.status_item_destroy);
            },

            .create_panel => {
                const payload = msg.payload.panel_create;
                try self.ui_manager.createPanel(
                    msg.plugin_id,
                    payload.id,
                    payload.title,
                    payload.position,
                    payload.width_percent,
                );
            },
            .update_panel_content => {
                const payload = msg.payload.panel_content_update;
                try self.ui_manager.updatePanelContent(msg.plugin_id, payload.id, payload.content);
            },
            .destroy_panel => {
                self.ui_manager.destroyPanel(msg.plugin_id, msg.payload.panel_destroy);
            },
            .update_panel_scroll => {
                const payload = msg.payload.panel_scroll_update;
                try self.ui_manager.updatePanelScroll(msg.plugin_id, payload.id, payload.offset);
            },
            .get_plugin_list => {
                var list = try std.ArrayListUnmanaged(protocol.PluginInfo).initCapacity(self.allocator, self.plugins.count());
                defer list.deinit(self.allocator);

                var it = self.plugins.valueIterator();
                while (it.next()) |p_ptr| {
                    const p = p_ptr.*;
                    try list.append(self.allocator, .{
                        .id = p.id,
                        .name = std.mem.span(p.interface.name),
                        .description = std.mem.span(p.interface.description),
                        .uptime_s = @as(u64, @intCast(std.Io.Clock.real.now(self.io).toSeconds() - p.load_time)),
                        .widget_count = self.ui_manager.getPluginWidgetCount(p.id),
                        .is_running = p.state == .running,
                    });
                }

                var serialized: std.Io.Writer.Allocating = .init(self.allocator);
                defer serialized.deinit();
                const writer = &serialized.writer;

                try writer.writeInt(u32, @intCast(list.items.len), .big);
                for (list.items) |info| {
                    try writer.writeInt(u32, @intCast(info.id.len), .big);
                    try writer.writeAll(info.id);
                    try writer.writeInt(u32, @intCast(info.name.len), .big);
                    try writer.writeAll(info.name);
                    try writer.writeInt(u32, @intCast(info.description.len), .big);
                    try writer.writeAll(info.description);
                    try writer.writeInt(u64, info.uptime_s, .big);
                    try writer.writeInt(u32, info.widget_count, .big);
                    try writer.writeByte(if (info.is_running) 1 else 0);
                }

                const response = protocol.PluginMessage{
                    .plugin_id = msg.plugin_id,
                    .message_type = .get_plugin_list_response,
                    .payload = .{ .plugin_list_data = serialized.written() },
                    .correlation_id = msg.correlation_id,
                };

                if (self.plugins.get(msg.plugin_id)) |p| {
                    if (p.inbox) |inbox| {
                        const outer = protocol.Message{ .plugin_message = response };
                        const encoded = try outer.encode(self.allocator);
                        defer self.allocator.free(encoded);
                        inbox.send(encoded) catch {};
                    }
                }
            },
            .emit_event => {
                const event = msg.payload.emit_event;
                var broadcast_data: std.Io.Writer.Allocating = .init(self.allocator);
                defer broadcast_data.deinit();
                const w = &broadcast_data.writer;
                try w.writeInt(u32, @intCast(event.name.len), .big);
                try w.writeAll(event.name);
                try w.writeAll(event.data);

                self.broadcastEvent(.custom_event, broadcast_data.written());
            },
            .load_plugin => {
                const path = msg.payload.plugin_load;
                try self.loadPlugin(path);
            },
            .unload_plugin => {
                const id = msg.payload.plugin_unload;
                try self.unloadPlugin(id);
            },
            .plugin_log => {
                const log_payload = msg.payload.plugin_log;
                const logger = @import("../services/logger.zig");
                if (logger.getGlobal()) |global_log| {
                    const level: logger.LogLevel = switch (log_payload.level) {
                        0 => .debug,
                        1 => .info,
                        2 => .warn,
                        else => .err,
                    };
                    global_log.log(level, "Plugin", "[{s}] {s}", .{ msg.plugin_id, log_payload.message });
                }
            },
            else => {
                log.info("PluginManager received message: {s}", .{@tagName(msg.message_type)});
            },
        }
    }

    // -------------------------------------------------------------------
    // Restart supervision
    //
    // When a plugin crashes (segfaults in init / handleMessage), the
    // worker thread calls `markForRestart` which records the crash time
    // and, if the policy allows it, sets `restart_requested = true`.
    // The manager's `tickRestarts` (driven from core's tick handler)
    // observes the flag and performs the actual reload — joining the
    // dead thread, closing the old library, and calling `loadPlugin`
    // again with the same path. This mirrors Erlang/OTP's "restart
    // intensity" approach: cap N restarts per window, then give up.
    // -------------------------------------------------------------------

    /// Run any pending restarts. Called from the core tick handler.
    /// Bounded work: one restart per call to avoid blocking the tick.
    pub fn tickRestarts(self: *PluginManager) void {
        const now_ms = vigil.compat.milliTimestamp();

        var target_id_buf: [256]u8 = undefined;
        var target_path_buf: [1024]u8 = undefined;
        var target: ?struct { id: []const u8, path: []const u8 } = null;

        var it = self.plugins.valueIterator();
        while (it.next()) |plugin_ptr| {
            const plugin = plugin_ptr.*;
            if (!plugin.restart_requested.load(.acquire)) continue;
            if (now_ms < plugin.next_restart_after_ms) continue;
            if (plugin.id.len > target_id_buf.len or plugin.path.len > target_path_buf.len) continue;
            @memcpy(target_id_buf[0..plugin.id.len], plugin.id);
            @memcpy(target_path_buf[0..plugin.path.len], plugin.path);
            target = .{
                .id = target_id_buf[0..plugin.id.len],
                .path = target_path_buf[0..plugin.path.len],
            };
            // Clear the flag *before* we start work — if the reload itself
            // crashes during init, the new crash will re-set it.
            plugin.restart_requested.store(false, .release);
            break;
        }

        if (target) |t| {
            self.restartOne(t.id, t.path) catch |err| {
                log.err("Plugin '{s}' restart failed: {}", .{ t.id, err });
            };
        }
    }

    fn restartOne(self: *PluginManager, plugin_id: []const u8, plugin_path: []const u8) !void {
        // The worker thread already exited (it returned after recording
        // the crash). We unload the dead plugin and load fresh.
        if (self.plugins.fetchRemove(plugin_id)) |entry| {
            const dead = entry.value;
            // Remove from the process group too so broadcasts skip it
            // until the new instance reinstalls.
            if (self.plugin_group) |*group| {
                _ = group.remove(dead.id);
            }
            self.cleanupPluginResources(dead.id);
            dead.deinit(self.allocator);
            self.allocator.destroy(dead);
        }

        // Stash path before reloading — we need a stable copy since the
        // borrowed slice points at the deinited plugin's storage.
        const path_copy = try self.allocator.dupe(u8, plugin_path);
        defer self.allocator.free(path_copy);

        try self.loadPlugin(path_copy);
        telemetry.recordSupervisorRestart();
        log.info("Plugin '{s}' restarted after crash", .{plugin_id});
    }

    pub fn broadcastEvent(self: *PluginManager, event: protocol.PluginEvent, data: []const u8) void {
        // Also publish to the Vigil global pub/sub broker so anyone
        // (plugin-dashboard, telemetry, future external consumers) can
        // subscribe by topic pattern instead of going through the
        // event_subscribers map. The legacy direct-send loop below is
        // kept so existing plugins keep receiving events on their inbox
        // — the broker is purely additive.
        const topic = pluginEventTopic(event);
        if (vigil.pubsub.getGlobal()) |broker| {
            _ = broker.publish(topic, data) catch |err| {
                log.warn("pubsub publish '{s}' failed: {}", .{ topic, err });
            };
        }

        if (self.event_subscribers.get(event)) |subscribers| {
            for (subscribers.items) |plugin_id| {
                if (self.plugins.get(plugin_id)) |plugin| {
                    if (plugin.state == .running) {
                        if (plugin.inbox) |inbox| {
                            const notif = protocol.PluginMessage{
                                .plugin_id = plugin_id,
                                .message_type = .event_notification,
                                .payload = .{ .event_notification = .{ .event = event, .data = data } },
                            };
                            const outer = protocol.Message{ .plugin_message = notif };
                            const encoded = outer.encode(self.allocator) catch continue;
                            defer self.allocator.free(encoded);
                            inbox.send(encoded) catch {};
                        }
                    }
                }
            }
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
};

test "isSharedLib accepts common extensions" {
    try std.testing.expect(PluginManager.isSharedLib("foo.dylib"));
    try std.testing.expect(PluginManager.isSharedLib("foo.so"));
    try std.testing.expect(PluginManager.isSharedLib("foo.dll"));
}

test "isSharedLib accepts Linux versioned sonames" {
    try std.testing.expect(PluginManager.isSharedLib("libfoo.so.0"));
    try std.testing.expect(PluginManager.isSharedLib("libfoo.so.1.2"));
    try std.testing.expect(PluginManager.isSharedLib("libfoo.so.10.0.5"));
}

test "isSharedLib rejects unrelated names" {
    try std.testing.expect(!PluginManager.isSharedLib("foo.txt"));
    try std.testing.expect(!PluginManager.isSharedLib("foo.gitignore"));
    try std.testing.expect(!PluginManager.isSharedLib("foo.so.bar"));
    try std.testing.expect(!PluginManager.isSharedLib(""));
    try std.testing.expect(!PluginManager.isSharedLib("nodot"));
    try std.testing.expect(!PluginManager.isSharedLib(".dylib")); // bare ext only
    try std.testing.expect(!PluginManager.isSharedLib("foo.so."));
}
