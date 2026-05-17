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

pub const PluginManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_block: std.process.Environ.Block,
    plugins: std.StringHashMapUnmanaged(*Plugin),
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
            if (entry.kind != .file) continue;
            if (!isSharedLib(entry.name)) continue;
            const full_path = try std.fs.path.join(self.allocator, &[_][]const u8{ plugin_dir, entry.name });
            defer self.allocator.free(full_path);
            self.loadPlugin(full_path) catch |err| {
                log.err("Failed to auto-load plugin {s}: {}", .{ entry.name, err });
            };
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

        // ABI version is just an integer — it doesn't catch struct-layout
        // skew. If the plugin and stem disagree on @sizeOf(PluginContext),
        // every field access from the plugin lands on the wrong offset and
        // init segfaults. Refuse to load instead of crashing later.
        if (lib.lookup(*const fn () callconv(.c) usize, "stem_plugin_context_sizeof")) |size_fn| {
            const plugin_size = size_fn();
            const stem_size = @sizeOf(context.PluginContext);
            if (plugin_size != stem_size) {
                log.err(
                    "Plugin at {s} sees PluginContext as {d} bytes, stem sees {d}. " ++
                        "Struct-layout mismatch — rebuild the plugin against this stem.",
                    .{ plugin_path, plugin_size, stem_size },
                );
                return error.IncompatiblePlugin;
            }
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

        const path_dupe = try self.allocator.dupe(u8, plugin_path);
        errdefer self.allocator.free(path_dupe);

        plugin.* = .{
            .id = id,
            .path = path_dupe,
            .lib = lib,
            .interface = plugin_interface.*,
            .state = .loaded,
            .load_time = std.Io.Clock.real.now(self.io).toSeconds(),
        };

        // Allocate inbox + ctx with errdefers so a failure between here and
        // the final `put` doesn't leak them. Without these errdefers, the
        // path_dupe / id / plugin errdefers above would clean up, but the
        // inbox and ctx allocations would silently leak.
        const inbox = try vigil.inbox(self.allocator);
        errdefer inbox.close();

        const ctx = try self.allocator.create(context.PluginContext);
        errdefer self.allocator.destroy(ctx);
        ctx.* = context.PluginContext.init(
            self.allocator,
            plugin.id,
            inbox,
            self.core_inbox.?,
            // Plugins keep a raw Inbox handle for now — the SDK ABI is
            // a separate concern from stem's internal MessageBus layer.
            self.ui_bus.inbox,
            self.allocator,
        );
        plugin.ctx = ctx;
        plugin.inbox = inbox;
        // Per-plugin bus: gives us priority-aware sends + telemetry on
        // every event/response delivered to this plugin. `bus` lives in
        // the Plugin struct so it dies with the plugin.
        plugin.bus = MessageBus.init(self.allocator, inbox, plugin.id);

        // Spawn the worker BEFORE inserting into the registry. If spawn fails
        // we don't want the map to retain a *Plugin whose backing struct will
        // be destroyed by the `errdefer destroy(plugin)` above.
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
        const ctx = plugin.ctx.?;

        // Install the SIGSEGV/SIGBUS handler on first use. Idempotent
        // across threads.
        _ = crash_isolation.install();

        if (plugin.interface.init) |init_fn| {
            const InitCall = struct {
                fn run(call_ctx: *anyopaque, fn_ptr: *const fn (*anyopaque) i32, rc_out: *i32) void {
                    rc_out.* = fn_ptr(call_ctx);
                }
            };
            const opaque_ctx: *anyopaque = @ptrCast(ctx);
            var rc: i32 = 0;
            const res = crash_isolation.runIsolated(.{ opaque_ctx, init_fn, &rc }, InitCall.run);
            if (res == .crashed) {
                plugin.state = .failed;
                telemetry.recordPluginCrash(plugin.id);
                log.err("Plugin {s} CRASHED during init (signal={d}); marked dead", .{ plugin.id, crash_isolation.lastCrashSignal() });
                markForRestart(plugin);
                return;
            }
            if (rc != 0) {
                plugin.state = .failed;
                log.err("Plugin {s} init failed", .{plugin.id});
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

            if (msg.payload) |payload| {
                const decoded = protocol.Message.decode(payload) catch continue;

                switch (decoded) {
                    .plugin_message => |pm| {
                        if (plugin.interface.handleMessage) |handler| {
                            const HandleCall = struct {
                                fn run(call_ctx: *anyopaque, fn_ptr: *const fn (*anyopaque, *const protocol.PluginMessage) i32, msg_ref: *const protocol.PluginMessage) void {
                                    _ = fn_ptr(call_ctx, msg_ref);
                                }
                            };
                            const opaque_ctx: *anyopaque = @ptrCast(ctx);
                            const res = crash_isolation.runIsolated(.{ opaque_ctx, handler, &pm }, HandleCall.run);
                            if (res == .crashed) {
                                plugin.state = .failed;
                                telemetry.recordPluginCrash(plugin.id);
                                log.err("Plugin {s} CRASHED during handleMessage (signal={d}); marked dead", .{ plugin.id, crash_isolation.lastCrashSignal() });
                                markForRestart(plugin);
                                break;
                            }
                        }
                    },
                    .quit => {
                        plugin.state = .unloading;
                        break;
                    },
                    else => {},
                }
            }
        }

        if (plugin.interface.deinit) |deinit_fn| {
            const DeinitCall = struct {
                fn run(call_ctx: *anyopaque, fn_ptr: *const fn (*anyopaque) void) void {
                    fn_ptr(call_ctx);
                }
            };
            const opaque_ctx: *anyopaque = @ptrCast(ctx);
            // Best-effort: if deinit crashes we can't do anything useful;
            // the plugin is already on its way out.
            _ = crash_isolation.runIsolated(.{ opaque_ctx, deinit_fn }, DeinitCall.run);
        }
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
                    if (plugin.bus) |*bus| {
                        const response = protocol.PluginMessage{
                            .plugin_id = msg.plugin_id,
                            .message_type = .config_response,
                            .payload = .{ .config_value = .{ .key = key, .value = value } },
                            .correlation_id = msg.correlation_id,
                        };
                        const encoded = response.encode(self.allocator) catch return;
                        defer self.allocator.free(encoded);
                        // best-effort: plugin inbox may be closed if plugin already shut down.
                        // Reply to a request → interactive class so the plugin
                        // resumes promptly.
                        bus.sendInteractive(encoded) catch {};
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
                    if (p.bus) |*pbus| {
                        const encoded = try response.encode(self.allocator);
                        defer self.allocator.free(encoded);
                        pbus.sendInteractive(encoded) catch {};
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
                        if (plugin.bus) |*bus| {
                            const notif = protocol.PluginMessage{
                                .plugin_id = plugin_id,
                                .message_type = .event_notification,
                                .payload = .{ .event_notification = .{ .event = event, .data = data } },
                            };
                            const encoded = notif.encode(self.allocator) catch continue;
                            defer self.allocator.free(encoded);
                            // best-effort: plugin inbox may be closed if plugin already shut down.
                            // Events are coalescible — a flood of cursor-moved
                            // doesn't need to all land in priority lane.
                            bus.sendCoalescible(encoded) catch {};
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
