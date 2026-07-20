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
//!     A WebAssembly module executed by the wick interpreter
//!     (github.com/ooyeku/wick) and bound to a small set of
//!     `env.stem_*` host imports. See `wasm/loader.zig`.
//!   * **exec** — `~/.stem/plugins/<name>/{plugin.json, <entry>}`.
//!     A child process speaking JSON-RPC 2.0 over stdio with LSP
//!     framing. See `process_loader.zig`. Nothing bundled uses this
//!     path today; it's available for third-party plugins.

const std = @import("std");
const log = std.log.scoped(.PluginManager);
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
const event_topics = @import("../services/event_topics.zig");
const vigil_api = @import("../services/vigil_adapters.zig");
const vigil_supervision = @import("../services/vigil_supervision.zig");

/// Wire-protocol version handed to exec plugins on `plugin/initialize`.
/// Bumped only when the JSON-RPC envelope semantics change.
const PROC_ABI_VERSION: u32 = 1;

pub const PluginManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_block: std.process.Environ.Block,

    /// Guards every mutable field on the manager. Process plugin reader
    /// threads call into the manager off the main loop (notifications,
    /// request forwarding, exit reporting), so map mutations and
    /// permission lookups must be serialised. Core's main thread takes
    /// the same lock when it mutates plugin state on tick / load /
    /// unload, which gives both sides a single ordering.
    state_mu: vigil_api.Mutex = .{},

    /// Plugins whose reader thread observed EOF/error. Populated from
    /// the reader thread (off-loop); drained by core on tick via
    /// `drainPendingExits`. The strings are owned copies — freed after
    /// the unload completes. This is what keeps `on_exit` from
    /// destroying the very plugin still unwinding its callback stack.
    pending_exits: std.ArrayListUnmanaged([]u8) = .empty,

    /// Per-plugin restart policy lifted from each manifest at load
    /// time. The manifest's arena is freed right after parsing, so
    /// we copy. Looked up by `drainPendingExits` to decide whether
    /// a crashed plugin should respawn.
    restart_policies: std.StringHashMapUnmanaged(manifest_mod.Restart) = .empty,

    /// Backoff state for crashed-and-being-restarted plugins. Wiped
    /// for a plugin once it survives long enough to be considered
    /// healthy (currently: when it's still alive at the next drain
    /// after restart). Keys are owned dupes of plugin names.
    restart_state: std.StringHashMapUnmanaged(RestartState) = .empty,

    /// Plugins waiting to be respawned by `drainPendingRestarts`.
    /// Pending list rather than spawning inline so the restart runs
    /// on the main loop, after the deinit of the previous instance
    /// has fully unwound.
    pending_restarts: std.ArrayListUnmanaged(PendingRestart) = .empty,

    /// Out-of-process plugins.
    process_plugins: std.StringHashMapUnmanaged(*ProcessPlugin) = .empty,
    /// WebAssembly plugins.
    wasm_plugins: std.StringHashMapUnmanaged(*WasmPlugin) = .empty,

    /// `correlation_id → plugin name` for in-flight process plugin
    /// requests. Lets `replyToProcessPlugin` route a reply back to the
    /// exact plugin that asked, rather than broadcasting to every
    /// running exec plugin. Populated when a process plugin's reader
    /// thread forwards a request to core's inbox; drained when the
    /// reply (or error) is dispatched back.
    pending_requests: std.AutoHashMapUnmanaged(u64, []u8) = .empty,

    core_inbox: ?*vigil_api.Inbox = null,
    event_broker: ?*vigil_api.PubSubBroker = null,
    lifecycle_supervisor: ?*vigil_supervision.ComponentSupervisor = null,
    ui_bus: *MessageBus,

    command_registry: *CommandRegistry,

    /// Owned `PluginCommandContext`s registered with `command_registry`.
    /// Freed in `deinit`.
    allocated_contexts: std.ArrayListUnmanaged(*PluginCommandContext) = .empty,

    /// Per-plugin permission grants, lifted from the manifest at load
    /// time. Host accessors consult this table before granting
    /// capability requests (event subscription, spawn, filesystem).
    plugin_permissions: std.StringHashMapUnmanaged(StoredPermissions) = .empty,
    /// Capability denials keyed by `<plugin>:<capability>:<target>`.
    /// This is the plugin audit trail surfaced in the dashboard.
    capability_denials: std.StringHashMapUnmanaged(StoredCapabilityDenial) = .empty,

    /// Map of editor event → list of plugins subscribed to it.
    /// Populated by `plugin/subscribeEvent` (exec) and
    /// `stem_subscribe_event` (wasm); drained on plugin unload.
    event_subscribers: std.AutoHashMapUnmanaged(protocol.PluginEvent, std.ArrayListUnmanaged(EventSub)) = .empty,
    /// Flow control for high-frequency event fanout. Delivery is synchronous
    /// on the calling (core) thread, so a held arrow key with a slow plugin
    /// subscribed to cursor events would otherwise stall the editor. Vigil's
    /// lock-free GCRA limiter caps deliveries; only drop-safe events
    /// (`cursor_moved` — positional, latest-wins) are ever throttled.
    cursor_event_limiter: vigil_api.raw.RateLimiter,
    events_rate_limited: std.atomic.Value(u64) = .init(0),

    /// Plugin status-bar widgets, keyed by `"<plugin_id>:<item_id>"`.
    status_items: std.StringHashMapUnmanaged(StoredStatusItem) = .empty,
    /// Plugin side panels, keyed by `"<plugin_id>:<panel_id>"`.
    panels: std.StringHashMapUnmanaged(StoredPanel) = .empty,
    /// Manifest-declared keybinding sequences. Key is the
    /// space-separated key sequence (e.g. `"Space g s"`); value is the
    /// command id to execute. The core input handler consults this
    /// after its own leader chord chain when `leader_pending` is set.
    plugin_keybindings: std.StringHashMapUnmanaged(PluginKeybinding) = .empty,

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

    pub const RestartState = struct {
        attempts: u8 = 0,
        last_attempt_ms: i64 = 0,
    };

    pub const PendingRestart = struct {
        /// Owned dupe of the plugin name.
        name: []u8,
        due_ms: i64,
    };

    pub const HealthSnapshot = struct {
        loaded_plugins: usize = 0,
        process_plugins: usize = 0,
        wasm_plugins: usize = 0,
        pending_exits: usize = 0,
        pending_restarts: usize = 0,
        pending_requests: usize = 0,
        restart_policies: usize = 0,
        event_subscribers: usize = 0,
        status_items: usize = 0,
        panels: usize = 0,
        keybindings: usize = 0,
        /// Cursor events dropped by the fanout rate limiter.
        events_rate_limited: u64 = 0,
        vigil_broker_attached: bool = false,
        vigil_supervisor_attached: bool = false,
        lifecycle: vigil_supervision.Snapshot = .{},
    };

    const PluginKeybinding = struct {
        command_id: []u8,
        plugin_id: []u8,

        fn deinit(self: PluginKeybinding, allocator: std.mem.Allocator) void {
            allocator.free(self.command_id);
            allocator.free(self.plugin_id);
        }
    };

    /// Backoff schedule: 1 s, 5 s, 30 s, then give up. Index is the
    /// attempt count (0 = first restart). Returning null means we've
    /// exhausted retries; the plugin stays down until the user
    /// reloads explicitly.
    fn restartDelayMs(attempts: u8) ?i64 {
        return switch (attempts) {
            0 => 1_000,
            1 => 5_000,
            2 => 30_000,
            else => null,
        };
    }

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
            // Runtime init: the GCRA limiter samples the monotonic clock.
            .cursor_event_limiter = vigil_api.raw.RateLimiter.initBurst(30, 60),
        };
    }

    pub fn setVigilServices(
        self: *PluginManager,
        event_broker: *vigil_api.PubSubBroker,
        lifecycle_supervisor: *vigil_supervision.ComponentSupervisor,
    ) void {
        self.event_broker = event_broker;
        self.lifecycle_supervisor = lifecycle_supervisor;
    }

    pub fn healthSnapshot(self: *PluginManager) HealthSnapshot {
        self.state_mu.lock();
        var snapshot = HealthSnapshot{
            .process_plugins = self.process_plugins.count(),
            .wasm_plugins = self.wasm_plugins.count(),
            .pending_exits = self.pending_exits.items.len,
            .pending_restarts = self.pending_restarts.items.len,
            .pending_requests = self.pending_requests.count(),
            .restart_policies = self.restart_policies.count(),
            .status_items = self.status_items.count(),
            .panels = self.panels.count(),
            .keybindings = self.plugin_keybindings.count(),
            .vigil_broker_attached = self.event_broker != null,
            .vigil_supervisor_attached = self.lifecycle_supervisor != null,
            .events_rate_limited = self.events_rate_limited.load(.monotonic),
        };
        snapshot.loaded_plugins = snapshot.process_plugins + snapshot.wasm_plugins;

        var ev_it = self.event_subscribers.valueIterator();
        while (ev_it.next()) |subs| {
            snapshot.event_subscribers += subs.items.len;
        }
        const supervisor = self.lifecycle_supervisor;
        self.state_mu.unlock();

        if (supervisor) |s| {
            snapshot.lifecycle = s.snapshot();
        }
        return snapshot;
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
            entry.value_ptr.*.deinit(self.allocator);
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

        var denial_it = self.capability_denials.iterator();
        while (denial_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.capability_denials.deinit(self.allocator);

        for (self.pending_exits.items) |name| self.allocator.free(name);
        self.pending_exits.deinit(self.allocator);

        var pr_it = self.pending_requests.iterator();
        while (pr_it.next()) |entry| self.allocator.free(entry.value_ptr.*);
        self.pending_requests.deinit(self.allocator);

        var pol_it = self.restart_policies.iterator();
        while (pol_it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.restart_policies.deinit(self.allocator);

        var rs_it = self.restart_state.iterator();
        while (rs_it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.restart_state.deinit(self.allocator);

        for (self.pending_restarts.items) |pr| self.allocator.free(pr.name);
        self.pending_restarts.deinit(self.allocator);
    }

    pub fn loadUserPlugins(self: *PluginManager) !void {
        // Walk every configured plugin root in priority order. The
        // first occurrence of a plugin name wins, so `~/.stem/plugins`
        // (per-user) shadows the system path, which shadows anything
        // injected via `STEM_PLUGIN_PATH`. That keeps `stem plugin
        // install <path>` (which lands in `~/.stem/plugins`) doing
        // what its UX implies: overriding the bundled copy.
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer {
            var it = seen.keyIterator();
            while (it.next()) |k| self.allocator.free(k.*);
            seen.deinit(self.allocator);
        }

        var roots = try self.collectPluginRoots();
        defer {
            for (roots.items) |p| self.allocator.free(p);
            roots.deinit(self.allocator);
        }

        for (roots.items) |root| {
            try self.loadFromRoot(root, &seen);
        }
    }

    /// Ordered list of directories to scan for plugins. Each entry is
    /// an owned absolute path; caller frees.
    fn collectPluginRoots(self: *PluginManager) !std.ArrayListUnmanaged([]u8) {
        // Cross-platform env access (env.getPosix is POSIX-only in
        // Zig 0.16; we route through platform.getEnv instead).
        const platform = @import("../kernel/platform.zig");
        var out: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (out.items) |p| self.allocator.free(p);
            out.deinit(self.allocator);
        }

        // 1. Per-user dir under HOME (or USERPROFILE on Windows).
        const home_owned: ?[]u8 = (try platform.getEnv(self.allocator, self.environ_block, "HOME")) orelse
            (try platform.getEnv(self.allocator, self.environ_block, "USERPROFILE"));
        defer if (home_owned) |h| self.allocator.free(h);
        if (home_owned) |home| {
            const user_dir = try std.fs.path.join(self.allocator, &.{ home, ".stem", "plugins" });
            try out.append(self.allocator, user_dir);
        } else {
            log.warn("Could not determine HOME — skipping ~/.stem/plugins", .{});
        }

        // 2. Common system install dirs. `install.sh` writes to
        // `~/.local/lib/stem/plugins` (no /usr/local access) or
        // `/usr/local/lib/stem/plugins`; the Nix derivation lands in
        // `<store>/lib/stem/plugins`; `install.ps1` writes to
        // `%LOCALAPPDATA%\Programs\stem\lib\stem\plugins`. We can't
        // ask the binary where it lives in Zig 0.16, so we just probe
        // the well-known paths and silently skip anything that
        // doesn't exist.
        if (home_owned) |home| {
            const local_dir = try std.fs.path.join(self.allocator, &.{ home, ".local", "lib", "stem", "plugins" });
            try out.append(self.allocator, local_dir);
        }
        if (@import("builtin").os.tag == .windows) {
            // Per-user install (no admin) — what install.ps1 uses by default.
            if (try platform.getEnv(self.allocator, self.environ_block, "LOCALAPPDATA")) |lad| {
                defer self.allocator.free(lad);
                const dir = try std.fs.path.join(self.allocator, &.{ lad, "Programs", "stem", "lib", "stem", "plugins" });
                try out.append(self.allocator, dir);
            }
            // System-wide install (admin) — Program Files.
            if (try platform.getEnv(self.allocator, self.environ_block, "ProgramFiles")) |pf| {
                defer self.allocator.free(pf);
                const dir = try std.fs.path.join(self.allocator, &.{ pf, "stem", "lib", "stem", "plugins" });
                try out.append(self.allocator, dir);
            }
        } else {
            const system_dirs = [_][]const u8{
                "/usr/local/lib/stem/plugins",
                "/usr/lib/stem/plugins",
                "/opt/stem/plugins",
            };
            for (system_dirs) |sd| {
                const dup = try self.allocator.dupe(u8, sd);
                try out.append(self.allocator, dup);
            }
        }

        // 3. Anything on `STEM_PLUGIN_PATH`. Split on `:` on POSIX,
        // `;` on Windows. Empty segments are ignored.
        const sep: u8 = if (@import("builtin").os.tag == .windows) ';' else ':';
        if (try platform.getEnv(self.allocator, self.environ_block, "STEM_PLUGIN_PATH")) |raw_owned| {
            defer self.allocator.free(raw_owned);
            const raw = raw_owned;
            var it = std.mem.tokenizeScalar(u8, raw, sep);
            while (it.next()) |seg| {
                if (seg.len == 0) continue;
                const dup = try self.allocator.dupe(u8, seg);
                try out.append(self.allocator, dup);
            }
        }

        return out;
    }

    fn loadFromRoot(
        self: *PluginManager,
        root: []const u8,
        seen: *std.StringHashMapUnmanaged(void),
    ) !void {
        var dir = std.Io.Dir.openDirAbsolute(self.io, root, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) return;
            log.warn("Failed to open plugin dir {s}: {}", .{ root, err });
            return;
        };
        defer dir.close(self.io);

        var it = dir.iterate();
        while (it.next(self.io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            if (seen.contains(entry.name)) {
                log.debug("plugin '{s}' already loaded from a higher-priority root; skipping {s}", .{ entry.name, root });
                continue;
            }
            const full_path = try std.fs.path.join(self.allocator, &.{ root, entry.name });
            defer self.allocator.free(full_path);
            self.tryLoadPluginDir(full_path) catch |err| {
                log.warn("Plugin dir {s} failed to load: {s}", .{ entry.name, @errorName(err) });
                continue;
            };
            const dup = try self.allocator.dupe(u8, entry.name);
            seen.put(self.allocator, dup, {}) catch {
                self.allocator.free(dup);
            };
        }
    }

    /// Resolve a plugin name into its `~/.stem/plugins/<name>/` dir
    /// and (re)load it via `tryLoadPluginDir`. Used by the runtime
    /// `:plugin.reload` command and the `load_plugin` plugin message.
    pub fn loadPluginByName(self: *PluginManager, name: []const u8) !void {
        const platform = @import("../kernel/platform.zig");
        const home = (try platform.getEnv(self.allocator, self.environ_block, "HOME")) orelse
            (try platform.getEnv(self.allocator, self.environ_block, "USERPROFILE")) orelse
            return error.NoHome;
        defer self.allocator.free(home);
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
            self.dropRestartPolicy(name);
            log.info("Unloaded wasm plugin: {s}", .{name});
            return;
        }
        if (self.process_plugins.fetchRemove(name)) |kv| {
            self.cleanupPluginResources(kv.value.name);
            kv.value.deinit();
            self.allocator.destroy(kv.value);
            self.dropStoredPermissions(name);
            self.dropRestartPolicy(name);
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

    fn dropRestartPolicy(self: *PluginManager, plugin_id: []const u8) void {
        if (self.restart_policies.fetchRemove(plugin_id)) |kv| {
            self.allocator.free(kv.key);
        }
        if (self.restart_state.fetchRemove(plugin_id)) |kv| {
            self.allocator.free(kv.key);
        }
        var i: usize = 0;
        while (i < self.pending_restarts.items.len) {
            if (std.mem.eql(u8, self.pending_restarts.items[i].name, plugin_id)) {
                self.allocator.free(self.pending_restarts.items[i].name);
                _ = self.pending_restarts.swapRemove(i);
            } else {
                i += 1;
            }
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
        const read_n = try file.readPositionalAll(self.io, bytes, 0);

        var m = try manifest_mod.parse(self.allocator, bytes[0..read_n]);
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

        var manifest_resources_installed = false;
        errdefer if (manifest_resources_installed) {
            self.cleanupPluginResources(m.name);
            self.dropStoredPermissions(m.name);
            self.dropRestartPolicy(m.name);
        };

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
        try self.installRestartPolicy(m.name, m.restart);
        manifest_resources_installed = true;

        try pp.start();

        var inserted_in_map = false;
        errdefer if (inserted_in_map) {
            _ = self.process_plugins.fetchRemove(m.name);
        };
        try self.process_plugins.put(self.allocator, name_dup, pp);
        inserted_in_map = true;
        // Successful load — reset any prior crash backoff for this plugin.
        self.clearRestartState(m.name);

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

        manifest_resources_installed = false;
        inserted_in_map = false;
        log.info("Loaded process plugin: {s} ({s})", .{ m.name, entry_path });
    }

    /// JSON-RPC notification handler — runs on the ProcessPlugin's
    /// reader thread. Mutations to manager state (command registry,
    /// event subscribers, status items, panels) all happen inside this
    /// call, so we serialise the whole dispatch under `state_mu`. The
    /// lock is short-lived: every branch is O(1) or O(N small) work.
    fn handleProcessNotification(
        user_data: *anyopaque,
        plugin_id: []const u8,
        method: []const u8,
        params: std.json.Value,
    ) void {
        _ = plugin_id;
        const self: *PluginManager = @ptrCast(@alignCast(user_data));
        self.state_mu.lock();
        defer self.state_mu.unlock();

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
        plugin_id: []const u8,
        id: u64,
        method: []const u8,
        _: std.json.Value,
    ) void {
        const self: *PluginManager = @ptrCast(@alignCast(user_data));
        // Forward the request onto core's inbox as a PluginMessage
        // carrying the JSON-RPC id in `correlation_id`; core handles
        // it on its own thread and calls `replyToProcessPlugin` once
        // it has the answer. Record `(id → plugin_id)` here so the
        // reply lands on the exact plugin that asked.
        const core_inbox = self.core_inbox orelse {
            self.replyProcessPluginByName(plugin_id, id, null, -32603, "core inbox unavailable");
            return;
        };
        const which: protocol.PluginMessage.PluginMessageType = blk: {
            if (std.mem.eql(u8, method, "editor/getState")) break :blk .get_state;
            if (std.mem.eql(u8, method, "editor/getBufferContent")) break :blk .get_buffer_content;
            if (std.mem.eql(u8, method, "editor/getPluginList")) break :blk .get_plugin_list;
            self.replyProcessPluginByName(plugin_id, id, null, -32601, "Method not found");
            return;
        };
        if (!self.recordPendingRequest(id, plugin_id)) {
            self.replyProcessPluginByName(plugin_id, id, null, -32603, "request tracking failed");
            return;
        }
        const pm = protocol.PluginMessage{
            .plugin_id = plugin_id,
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
            if (self.takePendingRequest(id)) |stale| self.allocator.free(stale);
            self.replyProcessPluginByName(plugin_id, id, null, -32603, "encode failed");
            return;
        };
        defer self.allocator.free(encoded);
        core_inbox.send(encoded) catch {
            if (self.takePendingRequest(id)) |stale| self.allocator.free(stale);
            self.replyProcessPluginByName(plugin_id, id, null, -32603, "core inbox closed");
        };
    }

    /// Record an in-flight `(correlation_id → plugin_id)` mapping
    /// under the state lock. Returns `false` if allocation fails so
    /// the caller can surface an error reply immediately rather than
    /// silently drop the reply when it arrives.
    fn recordPendingRequest(self: *PluginManager, id: u64, plugin_id: []const u8) bool {
        self.state_mu.lock();
        defer self.state_mu.unlock();
        const copy = self.allocator.dupe(u8, plugin_id) catch return false;
        self.pending_requests.put(self.allocator, id, copy) catch {
            self.allocator.free(copy);
            return false;
        };
        return true;
    }

    fn takePendingRequest(self: *PluginManager, id: u64) ?[]u8 {
        self.state_mu.lock();
        defer self.state_mu.unlock();
        if (self.pending_requests.fetchRemove(id)) |kv| return kv.value;
        return null;
    }

    /// Dispatch a JSON-RPC reply built by core back to the originating
    /// process plugin. Looks up the plugin by name (saved when the
    /// request was forwarded); if the plugin has since been unloaded
    /// or crashed the reply is silently dropped — better than waking
    /// every other plugin with a stale correlation id.
    pub fn replyToProcessPlugin(
        self: *PluginManager,
        correlation_id: u64,
        result_json: []const u8,
    ) void {
        const plugin_name_opt = self.takePendingRequest(correlation_id);
        const plugin_name = plugin_name_opt orelse {
            log.warn("dropping reply for unknown correlation_id={d}", .{correlation_id});
            return;
        };
        defer self.allocator.free(plugin_name);

        self.state_mu.lock();
        const pp_opt = self.process_plugins.get(plugin_name);
        self.state_mu.unlock();
        const pp = pp_opt orelse {
            log.warn("dropping reply id={d}: plugin '{s}' is gone", .{ correlation_id, plugin_name });
            return;
        };
        pp.sendReply(correlation_id, result_json) catch |err| {
            log.warn("reply to '{s}' id={d} failed: {s}", .{ plugin_name, correlation_id, @errorName(err) });
        };
    }

    /// Send a JSON-RPC error to a specific process plugin. If the
    /// correlation id was already recorded (`takePendingRequest`
    /// returned a name) the caller passes it as `recorded_name`;
    /// otherwise we fall back to the `plugin_id` argument the request
    /// handler observed.
    fn replyProcessPluginByName(
        self: *PluginManager,
        plugin_id: []const u8,
        correlation_id: u64,
        recorded_name: ?[]u8,
        code: i32,
        message: []const u8,
    ) void {
        defer if (recorded_name) |n| self.allocator.free(n);

        self.state_mu.lock();
        const pp_opt = self.process_plugins.get(plugin_id);
        self.state_mu.unlock();
        if (pp_opt) |pp| {
            pp.sendError(correlation_id, code, message) catch {};
        }
        log.warn("process plugin '{s}' request id={d} error {d}: {s}", .{ plugin_id, correlation_id, code, message });
    }

    fn handleProcessExit(user_data: *anyopaque, plugin_id: []const u8) void {
        // Runs on the ProcessPlugin's reader thread when the child
        // closes stdout. We MUST NOT call `unloadPlugin` here —
        // doing so would destroy the very `ProcessPlugin` whose
        // reader thread is still unwinding through this callback,
        // and the manager's maps may be in use on the main loop.
        // Instead, hand the name to `pending_exits` for the main
        // loop to drain on its next tick via `drainPendingExits`.
        const self: *PluginManager = @ptrCast(@alignCast(user_data));

        self.state_mu.lock();
        const copy = self.allocator.dupe(u8, plugin_id) catch {
            self.state_mu.unlock();
            return;
        };
        self.pending_exits.append(self.allocator, copy) catch {
            self.allocator.free(copy);
            self.state_mu.unlock();
            return;
        };
        self.state_mu.unlock();

        // Wake core so it drains promptly. The render flag is set in
        // `drainPendingExits` once the work actually runs.
        if (self.core_inbox) |inbox| {
            const tick_bytes = (protocol.Message{ .tick = {} }).encode(self.allocator) catch return;
            defer self.allocator.free(tick_bytes);
            inbox.send(tick_bytes) catch {};
        }
    }

    /// Drain any process plugins flagged by their reader thread.
    /// Called by core on tick, on the main loop, so it's safe to
    /// destroy the plugin and tear down its commands/widgets here.
    /// Returns the number of plugins actually unloaded — non-zero
    /// means the UI should re-render to drop stale palette entries.
    pub fn drainPendingExits(self: *PluginManager) usize {
        // Move the pending list out under the lock, then process
        // outside it so the unload path (which also takes the lock
        // via the public API) doesn't deadlock against itself.
        self.state_mu.lock();
        const names = self.pending_exits.toOwnedSlice(self.allocator) catch &[_][]u8{};
        self.state_mu.unlock();
        defer self.allocator.free(names);

        for (names) |name| {
            telemetry.recordPluginCrash(name);
            if (self.lifecycle_supervisor) |supervisor| {
                supervisor.recordCrash(name);
            }
            const policy: manifest_mod.Restart = blk: {
                self.state_mu.lock();
                defer self.state_mu.unlock();
                break :blk self.restart_policies.get(name) orelse .never;
            };
            self.unloadPlugin(name) catch |err| {
                log.warn("unload of failed process plugin '{s}' failed: {s}", .{ name, @errorName(err) });
            };
            switch (policy) {
                .never => {
                    log.warn("process plugin '{s}' exited; resources pruned (no restart — manifest opted out)", .{name});
                    self.allocator.free(name);
                },
                .on_crash, .always => {
                    self.scheduleRestart(name) catch |err| {
                        log.warn("schedule restart for '{s}' failed: {s}; resources pruned", .{ name, @errorName(err) });
                        self.allocator.free(name);
                    };
                },
            }
        }
        return names.len;
    }

    /// Insert (or refresh) the backoff entry for a crashed plugin and
    /// append it to `pending_restarts`. Ownership of `name_owned`
    /// transfers to the manager — either into the pending list (if
    /// queued) or freed immediately (if we've exhausted retries).
    fn scheduleRestart(self: *PluginManager, name_owned: []u8) !void {
        // Snapshot a stable handle for the post-unlock inbox poke so
        // we never call into another subsystem with `state_mu` held.
        var inbox_snapshot: ?*vigil_api.Inbox = null;
        var restart_delay_ms: i64 = 0;
        var restart_attempt: u32 = 0;

        {
            self.state_mu.lock();
            defer self.state_mu.unlock();

            // Look up the existing backoff state, or initialise a fresh
            // one. Cloning the key into a separate string for the
            // restart_state map keeps lifetimes straight: the pending
            // list owns its `name`, and restart_state owns its key.
            const gop = try self.restart_state.getOrPut(self.allocator, name_owned);
            if (!gop.found_existing) {
                const key_dup = try self.allocator.dupe(u8, name_owned);
                gop.key_ptr.* = key_dup;
                gop.value_ptr.* = .{};
            }

            const delay = restartDelayMs(gop.value_ptr.attempts) orelse {
                log.warn("process plugin '{s}' crashed too many times; giving up (re-load manually with `:Plugin Manager Reload All`)", .{name_owned});
                // Drop the give-up entry so the bookkeeping doesn't
                // hang around until manager deinit. The next manual
                // reload will start fresh.
                if (self.restart_state.fetchRemove(name_owned)) |kv| {
                    self.allocator.free(kv.key);
                }
                self.allocator.free(name_owned);
                return;
            };

            gop.value_ptr.attempts += 1;
            gop.value_ptr.last_attempt_ms = std.Io.Clock.real.now(self.io).toMilliseconds();
            const due = gop.value_ptr.last_attempt_ms + delay;
            restart_delay_ms = delay;
            restart_attempt = gop.value_ptr.attempts;

            log.info("process plugin '{s}' crashed; restart scheduled in {d}ms (attempt {d})", .{
                name_owned, delay, gop.value_ptr.attempts,
            });
            try self.pending_restarts.append(self.allocator, .{ .name = name_owned, .due_ms = due });

            inbox_snapshot = self.core_inbox;
        }

        if (self.lifecycle_supervisor) |supervisor| {
            supervisor.recordRestartScheduled(name_owned, restart_delay_ms, restart_attempt);
        }

        // Wake core promptly so it ticks soon and notices the pending
        // restart — otherwise the restart only fires when something
        // unrelated wakes the loop. Run *outside* `state_mu` so we
        // never block the lock on inbox-side bookkeeping.
        if (inbox_snapshot) |inbox| {
            const tick_bytes = (protocol.Message{ .tick = {} }).encode(self.allocator) catch return;
            defer self.allocator.free(tick_bytes);
            inbox.send(tick_bytes) catch {};
        }
    }

    /// Try to respawn any plugins whose backoff window has elapsed.
    /// Called by core on tick. Same pattern as `drainPendingExits`:
    /// move under the lock, process outside it.
    pub fn drainPendingRestarts(self: *PluginManager) usize {
        const now = std.Io.Clock.real.now(self.io).toMilliseconds();
        self.state_mu.lock();

        // Pre-reserve both partitions for the worst case (everything
        // ready OR everything still pending). If reservation fails
        // we'd otherwise be forced into a silent-drop fallback where
        // `name` allocations leak; better to bail out and leave the
        // queue intact so the next tick retries.
        const total = self.pending_restarts.items.len;
        var ready: std.ArrayListUnmanaged(PendingRestart) = .empty;
        ready.ensureTotalCapacity(self.allocator, total) catch {
            self.state_mu.unlock();
            return 0;
        };
        errdefer ready.deinit(self.allocator);

        var still_pending: std.ArrayListUnmanaged(PendingRestart) = .empty;
        still_pending.ensureTotalCapacity(self.allocator, total) catch {
            ready.deinit(self.allocator);
            self.state_mu.unlock();
            return 0;
        };

        for (self.pending_restarts.items) |pr| {
            if (pr.due_ms <= now) {
                ready.appendAssumeCapacity(pr);
            } else {
                still_pending.appendAssumeCapacity(pr);
            }
        }
        self.pending_restarts.deinit(self.allocator);
        self.pending_restarts = still_pending;
        self.state_mu.unlock();
        defer ready.deinit(self.allocator);

        for (ready.items) |pr| {
            defer self.allocator.free(pr.name);
            self.loadPluginByName(pr.name) catch |err| {
                log.warn("auto-restart of '{s}' failed: {s}", .{ pr.name, @errorName(err) });
                continue;
            };
            log.info("process plugin '{s}' auto-restarted", .{pr.name});
        }
        return ready.items.len;
    }

    /// Snapshot of a plugin's live state, returned by
    /// `liveStateOf`. All fields are by-value or borrow into the
    /// manager's storage — caller must not free.
    pub const LiveState = struct {
        loaded: bool,
        runtime: enum { wasm, process, none },
        restart_policy: manifest_mod.Restart,
        restart_attempts: u8,
        last_attempt_ms: i64,
        pending_restart_due_ms: ?i64,
        spawn_allowlist: []const []const u8,
        events: []const []const u8,
        filesystem: []const []const u8,
        manage_plugins: bool,
    };

    /// Best-effort read of the live state for `plugin_id`. Holds
    /// `state_mu` for the duration so the snapshot is internally
    /// consistent, but the strings remain owned by the manager —
    /// callers should consume them before releasing the lock (or
    /// dupe).
    pub fn liveStateOf(self: *PluginManager, plugin_id: []const u8) LiveState {
        self.state_mu.lock();
        defer self.state_mu.unlock();

        const runtime: @TypeOf(@as(LiveState, undefined).runtime) = if (self.process_plugins.contains(plugin_id))
            .process
        else if (self.wasm_plugins.contains(plugin_id))
            .wasm
        else
            .none;

        const policy = self.restart_policies.get(plugin_id) orelse .never;

        var attempts: u8 = 0;
        var last_ms: i64 = 0;
        if (self.restart_state.get(plugin_id)) |st| {
            attempts = st.attempts;
            last_ms = st.last_attempt_ms;
        }

        var pending_due: ?i64 = null;
        for (self.pending_restarts.items) |pr| {
            if (std.mem.eql(u8, pr.name, plugin_id)) {
                pending_due = pr.due_ms;
                break;
            }
        }

        var spawn_allow: []const []const u8 = &.{};
        var events_list: []const []const u8 = &.{};
        var fs_list: []const []const u8 = &.{};
        var has_manage = false;
        if (self.plugin_permissions.get(plugin_id)) |perms| {
            spawn_allow = perms.spawn_allowlist;
            events_list = perms.events;
            fs_list = perms.filesystem;
            has_manage = perms.manage_plugins;
        }

        return .{
            .loaded = runtime != .none,
            .runtime = runtime,
            .restart_policy = policy,
            .restart_attempts = attempts,
            .last_attempt_ms = last_ms,
            .pending_restart_due_ms = pending_due,
            .spawn_allowlist = spawn_allow,
            .events = events_list,
            .filesystem = fs_list,
            .manage_plugins = has_manage,
        };
    }

    /// Names of every plugin currently in either runtime map. Caller
    /// owns the outer slice; the inner strings borrow into the
    /// manager.
    pub fn loadedPluginNames(self: *PluginManager, allocator: std.mem.Allocator) ![][]const u8 {
        self.state_mu.lock();
        defer self.state_mu.unlock();
        var out = std.ArrayListUnmanaged([]const u8).empty;
        errdefer out.deinit(allocator);
        var p_it = self.process_plugins.keyIterator();
        while (p_it.next()) |k| try out.append(allocator, k.*);
        var w_it = self.wasm_plugins.keyIterator();
        while (w_it.next()) |k| try out.append(allocator, k.*);
        return out.toOwnedSlice(allocator);
    }

    /// Clear the backoff counter for a plugin that's been running
    /// cleanly. Called from the load path once a plugin enters its
    /// running state via `tryLoadPluginDir` — a successful load
    /// after a crash means we should forgive the previous attempts.
    fn clearRestartState(self: *PluginManager, plugin_id: []const u8) void {
        self.state_mu.lock();
        defer self.state_mu.unlock();
        if (self.restart_state.fetchRemove(plugin_id)) |kv| {
            self.allocator.free(kv.key);
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
        return event_topics.eventFromTopic(topic);
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
        /// Tell the editor that something a plugin owns needs to be
        /// redrawn (status item / panel / palette refresh). Without
        /// this, the synthetic tick we send wakes the loop but
        /// `Core.tick` will not actually call `sendUpdate()` because
        /// `needs_render` is still false.
        request_render: ?*const fn (user_data: *anyopaque) void = null,
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
        manage_plugins: bool = false,

        fn deinit(self: *StoredPermissions, allocator: std.mem.Allocator) void {
            for (self.spawn_allowlist) |s| allocator.free(s);
            for (self.filesystem) |s| allocator.free(s);
            for (self.events) |s| allocator.free(s);
            allocator.free(self.spawn_allowlist);
            allocator.free(self.filesystem);
            allocator.free(self.events);
        }
    };

    const StoredCapabilityDenial = struct {
        plugin_id: []u8,
        capability: CapabilityKind,
        target: []u8,
        count: u32 = 1,

        fn deinit(self: *StoredCapabilityDenial, allocator: std.mem.Allocator) void {
            allocator.free(self.plugin_id);
            allocator.free(self.target);
        }
    };

    pub fn recordCapabilityDenied(
        self: *PluginManager,
        plugin_id: []const u8,
        capability: CapabilityKind,
        target: []const u8,
    ) void {
        self.state_mu.lock();
        defer self.state_mu.unlock();
        self.recordCapabilityDeniedLocked(plugin_id, capability, target);
    }

    fn recordCapabilityDeniedLocked(
        self: *PluginManager,
        plugin_id: []const u8,
        capability: CapabilityKind,
        target: []const u8,
    ) void {
        const key = std.fmt.allocPrint(
            self.allocator,
            "{s}:{s}:{s}",
            .{ plugin_id, @tagName(capability), target },
        ) catch return;
        if (self.capability_denials.getPtr(key)) |existing| {
            self.allocator.free(key);
            existing.count +|= 1;
            return;
        }

        const plugin_copy = self.allocator.dupe(u8, plugin_id) catch {
            self.allocator.free(key);
            return;
        };
        const target_copy = self.allocator.dupe(u8, target) catch {
            self.allocator.free(plugin_copy);
            self.allocator.free(key);
            return;
        };
        const stored: StoredCapabilityDenial = .{
            .plugin_id = plugin_copy,
            .capability = capability,
            .target = target_copy,
        };
        self.capability_denials.put(self.allocator, key, stored) catch {
            var tmp = stored;
            tmp.deinit(self.allocator);
            self.allocator.free(key);
        };
    }

    pub fn dashboardJson(self: *PluginManager, allocator: std.mem.Allocator) ![]u8 {
        self.state_mu.lock();
        defer self.state_mu.unlock();

        const names = try self.collectDashboardPluginNames(allocator);
        defer allocator.free(names);

        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        const w = &aw.writer;

        try w.writeAll("{\"plugins\":[");
        for (names, 0..) |name, i| {
            if (i > 0) try w.writeByte(',');
            try self.writeDashboardPluginJson(w, name);
        }
        try w.writeAll("],\"summary\":{");
        try w.print("\"loaded\":{d},", .{self.process_plugins.count() + self.wasm_plugins.count()});
        try w.print("\"commands\":{d},", .{self.allocated_contexts.items.len});
        try w.print("\"keybindings\":{d},", .{self.plugin_keybindings.count()});
        try w.print("\"status_items\":{d},", .{self.status_items.count()});
        try w.print("\"panels\":{d},", .{self.panels.count()});
        try w.print("\"denials\":{d}", .{self.capability_denials.count()});
        try w.writeAll("}}");
        return aw.toOwnedSlice();
    }

    pub fn dashboardReport(self: *PluginManager, allocator: std.mem.Allocator) ![]u8 {
        self.state_mu.lock();
        defer self.state_mu.unlock();

        const names = try self.collectDashboardPluginNames(allocator);
        defer allocator.free(names);

        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        const w = &aw.writer;

        try w.writeAll("# Plugin Dashboard\n\n");
        try w.print("- Loaded: {d} ({d} wasm, {d} exec)\n", .{
            self.process_plugins.count() + self.wasm_plugins.count(),
            self.wasm_plugins.count(),
            self.process_plugins.count(),
        });
        try w.print("- Widgets: {d} status items, {d} panels\n", .{ self.status_items.count(), self.panels.count() });
        try w.print("- Commands: {d}, keybindings: {d}\n", .{ self.allocated_contexts.items.len, self.plugin_keybindings.count() });
        try w.print("- Capability denials: {d}\n\n", .{self.capability_denials.count()});

        if (names.len == 0) {
            try w.writeAll("No plugins are known to this Stem session.\n");
            return aw.toOwnedSlice();
        }

        for (names) |name| {
            const runtime = self.dashboardRuntime(name);
            const policy = self.restart_policies.get(name) orelse .never;
            try w.print("## {s}\n", .{name});
            try w.print("- Runtime: {s}\n", .{runtime});
            try w.print("- Restart: {s}\n", .{@tagName(policy)});
            try w.print("- Commands: {d}, keybindings: {d}\n", .{
                self.countCommandsFor(name),
                self.countKeybindingsFor(name),
            });
            try w.print("- Widgets: {d} status, {d} panels\n", .{
                self.countStatusItemsFor(name),
                self.countPanelsFor(name),
            });
            try w.print("- Subscriptions: {d}\n", .{self.countSubscriptionsFor(name)});
            if (self.wasm_plugins.get(name)) |wp| {
                try w.print("- Calls: {d} ({d} trapped), fuel max {d} / {d} budget\n", .{
                    wp.stats.calls,
                    wp.stats.traps,
                    wp.stats.max_fuel_used,
                    wasm_loader.CALL_FUEL_BUDGET,
                });
                if (wp.stats.last_error) |e| {
                    try w.print("- Last error: {s}\n", .{e});
                }
            }

            if (self.plugin_permissions.get(name)) |perms| {
                try w.writeAll("- Permissions: ");
                try self.writePermissionListText(w, "spawn", perms.spawn_allowlist);
                try w.writeAll("; ");
                try self.writePermissionListText(w, "events", perms.events);
                try w.writeAll("; ");
                try self.writePermissionListText(w, "filesystem", perms.filesystem);
                if (perms.manage_plugins) try w.writeAll("; manage_plugins");
                try w.writeByte('\n');
            } else {
                try w.writeAll("- Permissions: none recorded\n");
            }

            const denial_count = self.countDenialsFor(name);
            if (denial_count > 0) {
                try w.writeAll("- Recent denials:\n");
                var it = self.capability_denials.valueIterator();
                while (it.next()) |d| {
                    if (!std.mem.eql(u8, d.plugin_id, name)) continue;
                    try w.print("  - denied {s} {s} ({d}x)\n", .{
                        @tagName(d.capability),
                        d.target,
                        d.count,
                    });
                }
            }
            try w.writeByte('\n');
        }

        return aw.toOwnedSlice();
    }

    fn writeDashboardPluginJson(self: *PluginManager, w: *std.Io.Writer, name: []const u8) !void {
        const runtime = self.dashboardRuntime(name);
        const policy = self.restart_policies.get(name) orelse .never;

        try w.writeByte('{');
        try jsonrpc.writeJsonStringKey(w, "name");
        try jsonrpc.writeJsonString(w, name);
        try w.writeByte(',');
        try jsonrpc.writeJsonStringKey(w, "runtime");
        try jsonrpc.writeJsonString(w, runtime);
        try w.writeByte(',');
        try jsonrpc.writeJsonStringKey(w, "restart_policy");
        try jsonrpc.writeJsonString(w, @tagName(policy));
        try w.writeByte(',');
        try w.print("\"commands\":{d},", .{self.countCommandsFor(name)});
        try w.print("\"keybindings\":{d},", .{self.countKeybindingsFor(name)});
        try w.print("\"status_items\":{d},", .{self.countStatusItemsFor(name)});
        try w.print("\"panels\":{d},", .{self.countPanelsFor(name)});
        try w.print("\"subscriptions\":{d},", .{self.countSubscriptionsFor(name)});
        try w.print("\"denials\":{d},", .{self.countDenialsFor(name)});
        // Wasm runtime cost/failure stats (exec plugins have no
        // interpreter, so the block is null for them).
        if (self.wasm_plugins.get(name)) |wp| {
            try w.writeAll("\"calls\":{");
            try w.print("\"total\":{d},\"traps\":{d},", .{ wp.stats.calls, wp.stats.traps });
            try w.print("\"fuel_last\":{d},\"fuel_max\":{d},", .{ wp.stats.last_fuel_used, wp.stats.max_fuel_used });
            try w.print("\"fuel_budget\":{d},", .{wasm_loader.CALL_FUEL_BUDGET});
            try jsonrpc.writeJsonStringKey(w, "last_error");
            if (wp.stats.last_error) |e| {
                try jsonrpc.writeJsonString(w, e);
            } else {
                try w.writeAll("null");
            }
            try w.writeAll("},");
        } else {
            try w.writeAll("\"calls\":null,");
        }
        try w.writeAll("\"permissions\":{");
        if (self.plugin_permissions.get(name)) |perms| {
            try w.writeAll("\"spawn\":");
            try writeStringArrayJson(w, perms.spawn_allowlist);
            try w.writeAll(",\"events\":");
            try writeStringArrayJson(w, perms.events);
            try w.writeAll(",\"filesystem\":");
            try writeStringArrayJson(w, perms.filesystem);
            try w.print(",\"manage_plugins\":{}", .{perms.manage_plugins});
        } else {
            try w.writeAll("\"spawn\":[],\"events\":[],\"filesystem\":[],\"manage_plugins\":false");
        }
        try w.writeAll("}}");
    }

    fn writeStringArrayJson(w: *std.Io.Writer, xs: []const []const u8) !void {
        try w.writeByte('[');
        for (xs, 0..) |x, i| {
            if (i > 0) try w.writeByte(',');
            try jsonrpc.writeJsonString(w, x);
        }
        try w.writeByte(']');
    }

    fn writePermissionListText(
        self: *PluginManager,
        w: *std.Io.Writer,
        label: []const u8,
        xs: []const []const u8,
    ) !void {
        _ = self;
        try w.print("{s}: ", .{label});
        if (xs.len == 0) {
            try w.writeAll("-");
            return;
        }
        for (xs, 0..) |x, i| {
            if (i > 0) try w.writeAll(", ");
            try w.writeAll(x);
        }
    }

    fn collectDashboardPluginNames(self: *PluginManager, allocator: std.mem.Allocator) ![][]const u8 {
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer out.deinit(allocator);

        var perm_it = self.plugin_permissions.keyIterator();
        while (perm_it.next()) |name| try appendUniqueName(allocator, &out, name.*);
        var process_it = self.process_plugins.keyIterator();
        while (process_it.next()) |name| try appendUniqueName(allocator, &out, name.*);
        var wasm_it = self.wasm_plugins.keyIterator();
        while (wasm_it.next()) |name| try appendUniqueName(allocator, &out, name.*);
        var denial_it = self.capability_denials.valueIterator();
        while (denial_it.next()) |d| try appendUniqueName(allocator, &out, d.plugin_id);
        for (self.allocated_contexts.items) |ctx| {
            try appendUniqueName(allocator, &out, ctx.plugin_id);
        }
        var kb_it = self.plugin_keybindings.valueIterator();
        while (kb_it.next()) |binding| try appendUniqueName(allocator, &out, binding.plugin_id);

        return out.toOwnedSlice(allocator);
    }

    fn appendUniqueName(
        allocator: std.mem.Allocator,
        out: *std.ArrayListUnmanaged([]const u8),
        name: []const u8,
    ) !void {
        for (out.items) |existing| {
            if (std.mem.eql(u8, existing, name)) return;
        }
        try out.append(allocator, name);
    }

    fn dashboardRuntime(self: *PluginManager, plugin_id: []const u8) []const u8 {
        if (self.wasm_plugins.contains(plugin_id)) return "wasm";
        if (self.process_plugins.contains(plugin_id)) return "exec";
        return "none";
    }

    fn countStatusItemsFor(self: *PluginManager, plugin_id: []const u8) usize {
        var n: usize = 0;
        var it = self.status_items.valueIterator();
        while (it.next()) |item| {
            if (std.mem.eql(u8, item.plugin_id, plugin_id)) n += 1;
        }
        return n;
    }

    fn countPanelsFor(self: *PluginManager, plugin_id: []const u8) usize {
        var n: usize = 0;
        var it = self.panels.valueIterator();
        while (it.next()) |panel| {
            if (std.mem.eql(u8, panel.plugin_id, plugin_id)) n += 1;
        }
        return n;
    }

    fn countSubscriptionsFor(self: *PluginManager, plugin_id: []const u8) usize {
        var n: usize = 0;
        var it = self.event_subscribers.valueIterator();
        while (it.next()) |subs| {
            for (subs.items) |sub| {
                if (std.mem.eql(u8, sub.plugin_id, plugin_id)) n += 1;
            }
        }
        return n;
    }

    fn countCommandsFor(self: *PluginManager, plugin_id: []const u8) usize {
        var n: usize = 0;
        for (self.allocated_contexts.items) |ctx| {
            if (std.mem.eql(u8, ctx.plugin_id, plugin_id)) n += 1;
        }
        return n;
    }

    fn countKeybindingsFor(self: *PluginManager, plugin_id: []const u8) usize {
        var n: usize = 0;
        var it = self.plugin_keybindings.valueIterator();
        while (it.next()) |binding| {
            if (std.mem.eql(u8, binding.plugin_id, plugin_id)) n += 1;
        }
        return n;
    }

    fn countDenialsFor(self: *PluginManager, plugin_id: []const u8) usize {
        var n: usize = 0;
        var it = self.capability_denials.valueIterator();
        while (it.next()) |denial| {
            if (std.mem.eql(u8, denial.plugin_id, plugin_id)) n += 1;
        }
        return n;
    }

    pub fn isSafeStorageKey(key: []const u8) bool {
        if (key.len == 0) return false;
        if (key[0] == '/') return false;
        if (std.mem.indexOfScalar(u8, key, '\\') != null) return false;
        if (pathHasParentRef(key)) return false;
        var it = std.mem.splitScalar(u8, key, '/');
        while (it.next()) |component| {
            if (component.len == 0) return false;
        }
        return true;
    }

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
        stored.manage_plugins = perms.manage_plugins;
        try self.plugin_permissions.put(self.allocator, key, stored);
    }

    /// Record the manifest's restart policy so the exit handler can
    /// consult it without re-parsing the manifest. Replaces any prior
    /// policy on reload.
    fn installRestartPolicy(
        self: *PluginManager,
        plugin_id: []const u8,
        policy: manifest_mod.Restart,
    ) !void {
        if (self.restart_policies.fetchRemove(plugin_id)) |kv| {
            self.allocator.free(kv.key);
        }
        const key = try self.allocator.dupe(u8, plugin_id);
        errdefer self.allocator.free(key);
        try self.restart_policies.put(self.allocator, key, policy);
    }

    /// True iff the plugin was granted the `manage_plugins` capability
    /// in its manifest. Wasm load/unload host imports gate on this.
    fn canManagePlugins(self: *PluginManager, plugin_id: []const u8) bool {
        self.state_mu.lock();
        defer self.state_mu.unlock();
        const stored = self.plugin_permissions.get(plugin_id) orelse return false;
        return stored.manage_plugins;
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

    pub const CapabilityKind = enum { event, spawn, filesystem, manage_plugins };
    const FilePermissionOp = enum { read, write };

    fn permissionAllowsOrRecordDenied(
        self: *PluginManager,
        plugin_id: []const u8,
        kind: CapabilityKind,
        item: []const u8,
    ) bool {
        self.state_mu.lock();
        defer self.state_mu.unlock();
        if (self.permissionAllows(plugin_id, kind, item)) return true;
        self.recordCapabilityDeniedLocked(plugin_id, kind, item);
        return false;
    }

    fn filesystemAllowsOrRecordDenied(
        self: *PluginManager,
        plugin_id: []const u8,
        op: FilePermissionOp,
        path: []const u8,
    ) bool {
        self.state_mu.lock();
        defer self.state_mu.unlock();
        if (self.filesystemAllows(plugin_id, op, path)) return true;
        self.recordCapabilityDeniedLocked(plugin_id, .filesystem, path);
        return false;
    }

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
        if (kind == .manage_plugins) return stored.manage_plugins and std.mem.eql(u8, item, "manage_plugins");
        const list: []const []const u8 = switch (kind) {
            .event => stored.events,
            .spawn => stored.spawn_allowlist,
            .filesystem => stored.filesystem,
            .manage_plugins => unreachable,
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
        const binding = self.plugin_keybindings.get(seq) orelse return null;
        return binding.command_id;
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
            const plugin_dup = try self.allocator.dupe(u8, plugin_id);
            errdefer self.allocator.free(plugin_dup);
            // Replace any prior binding to keep the latest plugin to
            // claim a sequence as the winner — easier to reason about
            // than silent conflicts.
            if (self.plugin_keybindings.fetchRemove(seq_dup)) |kv| {
                self.allocator.free(kv.key);
                kv.value.deinit(self.allocator);
            }
            try self.plugin_keybindings.put(self.allocator, seq_dup, .{
                .command_id = cmd_dup,
                .plugin_id = plugin_dup,
            });
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

        var manifest_resources_installed = false;
        errdefer if (manifest_resources_installed) {
            self.cleanupPluginResources(m.name);
            self.dropStoredPermissions(m.name);
            self.dropRestartPolicy(m.name);
        };

        // Manifest-driven registration. Eagerly publish each declared
        // command before activate runs so the palette stays populated
        // even if activate later traps.
        for (m.commands) |cmd| {
            self.registerManifestCommand(m.name, .wasm, cmd) catch |err| {
                log.warn("manifest commands for '{s}': {s}", .{ m.name, @errorName(err) });
            };
        }
        try self.installPluginPermissions(m.name, m.permissions);
        try self.installRestartPolicy(m.name, m.restart);
        manifest_resources_installed = true;

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
                .on_get_plugin_dashboard_json = onWasmGetPluginDashboardJson,
                .on_get_plugin_dashboard_report = onWasmGetPluginDashboardReport,
                .on_storage_read = onWasmStorageRead,
                .on_storage_write = onWasmStorageWrite,
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

        manifest_resources_installed = false;
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

        if (!self.permissionAllowsOrRecordDenied(plugin_id, .spawn, program)) {
            log.warn(
                "wasm plugin '{s}' attempted unauthorized spawn: {s}",
                .{ plugin_id, program },
            );
            return -1;
        }

        const spawn_result = self.spawnCapture(argv.items, opts.cwd, opts.timeout_ms) catch |err| {
            log.warn("wasm spawn for '{s}' failed: {s}", .{ plugin_id, @errorName(err) });
            return -3;
        };
        defer self.allocator.free(spawn_result.stdout);
        defer self.allocator.free(spawn_result.stderr);

        if (spawn_result.timed_out) {
            log.warn(
                "wasm spawn for '{s}' (cmd='{s}') exceeded {d}ms — killed",
                .{ plugin_id, opts.cmd, opts.timeout_ms },
            );
            return -4;
        }

        // Write stdout, optionally followed by stderr (NUL-separated).
        var written: usize = 0;
        const n = @min(spawn_result.stdout.len, out_buf.len);
        @memcpy(out_buf[0..n], spawn_result.stdout[0..n]);
        written += n;
        if (opts.include_stderr and written < out_buf.len) {
            // Separator.
            out_buf[written] = 0;
            written += 1;
            const remaining = out_buf.len - written;
            const m = @min(spawn_result.stderr.len, remaining);
            @memcpy(out_buf[written..][0..m], spawn_result.stderr[0..m]);
            written += m;
        }

        // Surface non-zero exit codes so plugins can distinguish "ran
        // but failed" from "stdout was empty". We still return the
        // bytes written; the negative code is purely informational.
        return switch (spawn_result.term) {
            .exited => |code| if (code == 0) @intCast(written) else -5,
            else => -5,
        };
    }

    const SpawnCaptureResult = struct {
        stdout: []u8,
        stderr: []u8,
        term: std.process.Child.Term,
        timed_out: bool,
    };

    /// Run a child with stdout/stderr piped, enforcing `timeout_ms`
    /// if non-zero. A watchdog thread kills the process if it doesn't
    /// exit in time. We drain stdout then stderr; a misbehaving child
    /// that writes >1 MiB to stderr while we're reading stdout will
    /// eventually block — but only after the kill window, which puts
    /// it on the watchdog's path.
    fn spawnCapture(
        self: *PluginManager,
        argv: []const []const u8,
        cwd: ?[]const u8,
        timeout_ms: u32,
    ) !SpawnCaptureResult {
        const child_cwd: std.process.Child.Cwd = if (cwd) |c| .{ .path = c } else .inherit;
        var child = try std.process.spawn(self.io, .{
            .argv = argv,
            .cwd = child_cwd,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
        });

        const Watchdog = struct {
            io: std.Io,
            child_ptr: *std.process.Child,
            timeout_ms: u32,
            done: std.atomic.Value(bool) = .{ .raw = false },
            fired: std.atomic.Value(bool) = .{ .raw = false },

            fn run(ctx: *@This()) void {
                @import("../services/thread_name.zig").set("stem-plug-wd");
                const step_ms: u32 = 25;
                var elapsed: u32 = 0;
                while (elapsed < ctx.timeout_ms) {
                    if (ctx.done.load(.acquire)) return;
                    vigil_api.sleep(step_ms * std.time.ns_per_ms);
                    elapsed += step_ms;
                }
                if (ctx.done.load(.acquire)) return;
                ctx.fired.store(true, .release);
                ctx.child_ptr.kill(ctx.io);
            }
        };

        var wd: Watchdog = .{
            .io = self.io,
            .child_ptr = &child,
            .timeout_ms = timeout_ms,
        };
        var wd_thread: ?std.Thread = null;
        if (timeout_ms > 0) {
            wd_thread = std.Thread.spawn(.{}, Watchdog.run, .{&wd}) catch null;
        }

        // Capped to avoid runaway children exhausting RAM via a
        // stuck spawn; mirrors the previous behaviour of
        // `std.process.run` (which had its own internal cap).
        const max_capture: usize = 1024 * 1024;
        const stdout_bytes = readAllCapped(self.io, child.stdout, self.allocator, max_capture) catch try self.allocator.alloc(u8, 0);
        const stderr_bytes = readAllCapped(self.io, child.stderr, self.allocator, max_capture) catch try self.allocator.alloc(u8, 0);

        const term = child.wait(self.io) catch std.process.Child.Term{ .unknown = 0 };

        // Signal the watchdog that the child is done, then join. If
        // the watchdog never fired the loop will pick up `done=true`
        // and return promptly.
        wd.done.store(true, .release);
        if (wd_thread) |t| t.join();

        return .{
            .stdout = stdout_bytes,
            .stderr = stderr_bytes,
            .term = term,
            .timed_out = wd.fired.load(.acquire),
        };
    }

    fn readAllCapped(
        io: std.Io,
        file_opt: ?std.Io.File,
        allocator: std.mem.Allocator,
        cap: usize,
    ) ![]u8 {
        const file = file_opt orelse return try allocator.alloc(u8, 0);
        var buf: [4096]u8 = undefined;
        var reader = file.readerStreaming(io, &buf);
        const r = &reader.interface;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        var chunk: [4096]u8 = undefined;
        while (true) {
            const remaining = if (out.items.len >= cap) 0 else cap - out.items.len;
            if (remaining == 0) break;
            const slice_len = @min(chunk.len, remaining);
            const n = r.readSliceShort(chunk[0..slice_len]) catch break;
            if (n == 0) break;
            try out.appendSlice(allocator, chunk[0..n]);
        }
        return out.toOwnedSlice(allocator);
    }

    fn onWasmSubscribeEvent(
        user_data: *anyopaque,
        plugin_id: []const u8,
        topic: []const u8,
    ) i32 {
        const self: *PluginManager = @ptrCast(@alignCast(user_data));
        const event = eventFromTopic(topic) orelse {
            log.warn("wasm plugin '{s}' subscribed to unknown event '{s}'", .{ plugin_id, topic });
            return -2;
        };
        {
            self.state_mu.lock();
            defer self.state_mu.unlock();
            if (!self.permissionAllows(plugin_id, .event, topic)) {
                self.recordCapabilityDeniedLocked(plugin_id, .event, topic);
                log.warn(
                    "wasm plugin '{s}' lacks event permission for '{s}'",
                    .{ plugin_id, topic },
                );
                return -1;
            }
            self.addEventSubscription(event, .wasm, plugin_id) catch return -3;
        }
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
        if (!self.filesystemAllowsOrRecordDenied(plugin_id, .read, path)) {
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
        const read_n = file.readPositionalAll(self.io, out_buf[0..@intCast(cap)], 0) catch return -2;
        return @intCast(read_n);
    }

    fn onWasmWriteFile(
        user_data: *anyopaque,
        plugin_id: []const u8,
        path: []const u8,
        content: []const u8,
    ) i32 {
        const self: *PluginManager = @ptrCast(@alignCast(user_data));
        if (!self.filesystemAllowsOrRecordDenied(plugin_id, .write, path)) {
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
        self.state_mu.lock();
        self.upsertStatusItem(plugin_id, id, text, alignment, priority) catch |err| {
            self.state_mu.unlock();
            log.warn("wasm plugin '{s}' set_status_item failed: {s}", .{ plugin_id, @errorName(err) });
            return;
        };
        self.state_mu.unlock();
        self.requestUiRefresh();
    }

    fn onWasmClearStatusItem(
        user_data: *anyopaque,
        plugin_id: []const u8,
        id: []const u8,
    ) void {
        const self: *PluginManager = @ptrCast(@alignCast(user_data));
        self.state_mu.lock();
        self.removeStatusItem(plugin_id, id);
        self.state_mu.unlock();
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
        self.state_mu.lock();
        self.upsertPanel(plugin_id, id, title, content, position, width_percent) catch |err| {
            self.state_mu.unlock();
            log.warn("wasm plugin '{s}' set_panel failed: {s}", .{ plugin_id, @errorName(err) });
            return;
        };
        self.state_mu.unlock();
        self.requestUiRefresh();
    }

    fn onWasmClearPanel(
        user_data: *anyopaque,
        plugin_id: []const u8,
        id: []const u8,
    ) void {
        const self: *PluginManager = @ptrCast(@alignCast(user_data));
        self.state_mu.lock();
        self.removePanel(plugin_id, id);
        self.state_mu.unlock();
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

    fn onWasmGetPluginDashboardJson(
        user_data: *anyopaque,
        plugin_id: []const u8,
        out_buf: []u8,
    ) i32 {
        _ = plugin_id;
        const self: *PluginManager = @ptrCast(@alignCast(user_data));
        const json = self.dashboardJson(self.allocator) catch return -2;
        defer self.allocator.free(json);
        return copyToPluginBuffer(json, out_buf);
    }

    fn onWasmGetPluginDashboardReport(
        user_data: *anyopaque,
        plugin_id: []const u8,
        out_buf: []u8,
    ) i32 {
        _ = plugin_id;
        const self: *PluginManager = @ptrCast(@alignCast(user_data));
        const report = self.dashboardReport(self.allocator) catch return -2;
        defer self.allocator.free(report);
        return copyToPluginBuffer(report, out_buf);
    }

    fn onWasmStorageRead(
        user_data: *anyopaque,
        plugin_id: []const u8,
        key: []const u8,
        out_buf: []u8,
    ) i32 {
        const self: *PluginManager = @ptrCast(@alignCast(user_data));
        const path = self.pluginStoragePath(plugin_id, key) catch {
            self.recordCapabilityDenied(plugin_id, .filesystem, key);
            return -1;
        };
        defer self.allocator.free(path);

        const file = std.Io.Dir.openFileAbsolute(self.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return 0,
            else => return -2,
        };
        defer file.close(self.io);

        const len = file.length(self.io) catch return -2;
        const read_len: usize = @intCast(@min(@as(u64, @intCast(out_buf.len)), len));
        const read_n = file.readPositionalAll(self.io, out_buf[0..read_len], 0) catch return -2;
        return @intCast(read_n);
    }

    fn onWasmStorageWrite(
        user_data: *anyopaque,
        plugin_id: []const u8,
        key: []const u8,
        content: []const u8,
    ) i32 {
        const self: *PluginManager = @ptrCast(@alignCast(user_data));
        const path = self.pluginStoragePath(plugin_id, key) catch {
            self.recordCapabilityDenied(plugin_id, .filesystem, key);
            return -1;
        };
        defer self.allocator.free(path);

        if (std.fs.path.dirname(path)) |dir| {
            std.Io.Dir.cwd().createDirPath(self.io, dir) catch return -2;
        }
        const file = std.Io.Dir.createFileAbsolute(self.io, path, .{ .truncate = true }) catch return -2;
        defer file.close(self.io);
        file.writeStreamingAll(self.io, content) catch return -2;
        return 0;
    }

    fn copyToPluginBuffer(content: []const u8, out_buf: []u8) i32 {
        const n = @min(content.len, out_buf.len);
        @memcpy(out_buf[0..n], content[0..n]);
        return @intCast(n);
    }

    fn pluginStoragePath(self: *PluginManager, plugin_id: []const u8, key: []const u8) ![]u8 {
        if (!isSafeStorageKey(key)) return error.InvalidStorageKey;
        if (!isSafeStorageKey(plugin_id)) return error.InvalidStorageKey;
        const platform = @import("../kernel/platform.zig");
        const home = (try platform.getEnv(self.allocator, self.environ_block, "HOME")) orelse
            (try platform.getEnv(self.allocator, self.environ_block, "USERPROFILE")) orelse
            return error.NoHome;
        defer self.allocator.free(home);
        const root = try std.fs.path.join(self.allocator, &.{ home, ".stem", "plugin-data", plugin_id });
        defer self.allocator.free(root);
        return std.fs.path.join(self.allocator, &.{ root, key });
    }

    fn onWasmLoadPlugin(
        user_data: *anyopaque,
        plugin_id: []const u8,
        name: []const u8,
    ) i32 {
        const self: *PluginManager = @ptrCast(@alignCast(user_data));
        if (!self.canManagePlugins(plugin_id)) {
            self.recordCapabilityDenied(plugin_id, .manage_plugins, "manage_plugins");
            log.warn(
                "wasm plugin '{s}' attempted stem_load_plugin('{s}') without `manage_plugins` permission",
                .{ plugin_id, name },
            );
            return -1;
        }
        self.loadPluginByName(name) catch |err| {
            log.warn("stem_load_plugin('{s}') failed: {s}", .{ name, @errorName(err) });
            return -2;
        };
        return 0;
    }

    fn onWasmUnloadPlugin(
        user_data: *anyopaque,
        plugin_id: []const u8,
        name: []const u8,
    ) i32 {
        const self: *PluginManager = @ptrCast(@alignCast(user_data));
        if (!self.canManagePlugins(plugin_id)) {
            self.recordCapabilityDenied(plugin_id, .manage_plugins, "manage_plugins");
            log.warn(
                "wasm plugin '{s}' attempted stem_unload_plugin('{s}') without `manage_plugins` permission",
                .{ plugin_id, name },
            );
            return -1;
        }
        // Forbid self-unload outright: the host would destroy the
        // very WasmPlugin whose instance is still on the call stack
        // (we're inside one of its host imports), so the wasm-side
        // return-from-call would jump back into freed memory. Plugins
        // that want to "reload self" should call load on a sibling
        // (like plugin_manager.reload_all does).
        if (std.mem.eql(u8, name, plugin_id)) {
            log.warn(
                "wasm plugin '{s}' attempted to unload itself — denied",
                .{plugin_id},
            );
            return -3;
        }
        self.unloadPlugin(name) catch |err| {
            log.warn("stem_unload_plugin('{s}') failed: {s}", .{ name, @errorName(err) });
            return -2;
        };
        return 0;
    }

    /// After a widget mutation, mark the editor dirty AND wake its
    /// event loop. The dirty flag is what makes `Core.tick` actually
    /// run `sendUpdate()` — without it the synthetic tick would wake
    /// the loop only to fall through (`needs_render` is false). The
    /// `request_render` hook runs synchronously on whichever thread
    /// called us, so it must just flip a flag (no locks, no I/O).
    fn requestUiRefresh(self: *PluginManager) void {
        if (self.host_hooks.request_render) |fn_ptr| {
            if (self.host_hooks.user_data) |ud| fn_ptr(ud);
        }
        const core_inbox = self.core_inbox orelse return;
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
        op: FilePermissionOp,
        path: []const u8,
    ) bool {
        const stored = self.plugin_permissions.get(plugin_id) orelse return false;
        const prefix: []const u8 = switch (op) {
            .read => "read:",
            .write => "write:",
        };
        return filesystemListAllows(stored.filesystem, prefix, path);
    }

    /// Pure filesystem-permission decision, split out from
    /// `filesystemAllows` so the traversal guard and glob matching are
    /// unit-testable without standing up a live PluginManager.
    ///
    /// Denies outright any path containing a `..` component. Grants
    /// glob-match the *raw* request string, so a `read:src/*` grant
    /// would otherwise allow `src/../../etc/passwd` — the glob sees the
    /// `src/` prefix and passes, then the host resolves the `..` and
    /// reads outside the intended scope. Rejecting parent refs closes
    /// that class without touching the filesystem (write targets may
    /// not exist yet). Symlink-based escapes are out of scope; defending
    /// those needs realpath resolution at access time.
    fn filesystemListAllows(filesystem: []const []const u8, prefix: []const u8, path: []const u8) bool {
        if (pathHasParentRef(path)) return false;
        for (filesystem) |entry| {
            if (!std.mem.startsWith(u8, entry, prefix)) continue;
            const pattern = entry[prefix.len..];
            if (matchesPermissionEntry(pattern, path)) return true;
        }
        return false;
    }

    /// True if `path` has a `..` path component under either separator.
    /// A filename that merely *contains* ".." (e.g. `a..b`) is fine —
    /// only a whole component counts.
    fn pathHasParentRef(path: []const u8) bool {
        var it = std.mem.splitAny(u8, path, "/\\");
        while (it.next()) |comp| {
            if (std.mem.eql(u8, comp, "..")) return true;
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
        wp.dispatchCommand(cmd_ctx.command_id) catch |err| {
            // Contained failure: count it toward the check-engine
            // light and stamp the runtime timeline so the control
            // center can show what trapped, when, and on which
            // command. The error still propagates so the invoker
            // can toast the user.
            @import("../services/runtime.zig").RuntimeAlerts.recordPluginTrap();
            telemetry.recordTimeline(.plugin, wp.plugin_id, @errorName(err));
            return err;
        };
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
        var stale: std.ArrayListUnmanaged([]const u8) = .empty;
        defer stale.deinit(self.allocator);
        var it = self.plugin_keybindings.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.*.plugin_id, plugin_id)) {
                stale.append(self.allocator, entry.key_ptr.*) catch break;
            }
        }
        for (stale.items) |k| {
            if (self.plugin_keybindings.fetchRemove(k)) |kv| {
                self.allocator.free(kv.key);
                kv.value.deinit(self.allocator);
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
        // Throttle drop-safe high-frequency events before doing any fanout
        // work. Cursor events are positional snapshots, so a dropped one is
        // superseded by the next allowed one; a plugin may briefly see a
        // stale position at the very end of a fast burst.
        if (event == .cursor_moved and !self.cursor_event_limiter.allow()) {
            _ = self.events_rate_limited.fetchAdd(1, .monotonic);
            return;
        }

        const topic = pluginEventTopic(event);
        const editor_topic = event_topics.editorEventTopic(event);

        self.publishEventTopic(topic, data);
        self.publishEventTopic(editor_topic, data);

        const subs = self.event_subscribers.get(event) orelse return;
        for (subs.items) |sub| {
            switch (sub.runtime) {
                .exec => self.deliverExecEvent(sub.plugin_id, topic, data),
                .wasm => self.deliverWasmEvent(sub.plugin_id, topic, data),
            }
        }
    }

    fn publishEventTopic(self: *PluginManager, topic: []const u8, data: []const u8) void {
        // Vigil 2.2 removed the global pub/sub broker; publishing requires the
        // runtime-owned broker attached via setVigilServices.
        const broker = self.event_broker orelse return;
        _ = broker.publish(topic, data) catch |err| {
            log.warn("pubsub publish '{s}' failed: {}", .{ topic, err });
        };
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
            @import("../services/runtime.zig").RuntimeAlerts.recordPluginTrap();
            telemetry.recordTimeline(.plugin, plugin_id, @errorName(err));
        };
    }

    /// Stable topic names so external subscribers don't have to know
    /// the `protocol.PluginEvent` enum integer.
    fn pluginEventTopic(event: protocol.PluginEvent) []const u8 {
        return event_topics.pluginEventTopic(event);
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

test "filesystemListAllows: exact and glob grants gate per-op" {
    const grants = [_][]const u8{ "read:src/*", "write:out.txt" };
    try std.testing.expect(PluginManager.filesystemListAllows(&grants, "read:", "src/main.zig"));
    try std.testing.expect(!PluginManager.filesystemListAllows(&grants, "read:", "lib/x.zig"));
    try std.testing.expect(PluginManager.filesystemListAllows(&grants, "write:", "out.txt"));
    // A read grant must not satisfy a write op, and vice-versa.
    try std.testing.expect(!PluginManager.filesystemListAllows(&grants, "write:", "src/main.zig"));
    try std.testing.expect(!PluginManager.filesystemListAllows(&grants, "read:", "out.txt"));
    // No grant at all => deny.
    try std.testing.expect(!PluginManager.filesystemListAllows(&.{}, "read:", "src/main.zig"));
}

test "broadcastEvent publishes legacy and editor topics through owned broker" {
    const allocator = std.testing.allocator;
    var io_ctx = @import("../test_utils.zig").TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();

    const ui_inbox = try vigil_api.standaloneInboxForTest(allocator);
    defer ui_inbox.close();
    var ui_bus = MessageBus.init(allocator, ui_inbox, "test-ui");

    var registry = CommandRegistry.init(allocator);
    defer registry.deinit();

    var manager = PluginManager.init(allocator, io, .empty, &ui_bus, &registry);
    defer manager.deinit();

    var runtime = try vigil_api.runtime(allocator, .{});
    defer runtime.deinit();
    var broker = vigil_api.PubSubBroker.init(allocator);
    defer broker.deinit();
    var supervisor = vigil_supervision.ComponentSupervisor.init(allocator, &runtime, .plugins);
    defer supervisor.deinit();
    supervisor.setEventBroker(&broker);
    manager.setVigilServices(&broker, &supervisor);

    const legacy_inbox = try runtime.inbox(.{ .capacity = 4 });
    defer legacy_inbox.close();
    var legacy_sub = vigil_api.Subscriber.init(allocator, legacy_inbox);
    defer legacy_sub.deinit();
    try legacy_sub.subscribe(&[_][]const u8{"buffer.changed"});
    try broker.subscribe(&legacy_sub);

    const editor_inbox = try runtime.inbox(.{ .capacity = 4 });
    defer editor_inbox.close();
    var editor_sub = vigil_api.Subscriber.init(allocator, editor_inbox);
    defer editor_sub.deinit();
    try editor_sub.subscribe(&[_][]const u8{"editor.buffer.changed"});
    try broker.subscribe(&editor_sub);

    manager.broadcastEvent(.buffer_changed, "main.zig");

    var legacy_msg = try legacy_inbox.recv();
    defer legacy_msg.deinit();
    try std.testing.expectEqualStrings("main.zig", legacy_msg.payload.?);

    var editor_msg = try editor_inbox.recv();
    defer editor_msg.deinit();
    try std.testing.expectEqualStrings("main.zig", editor_msg.payload.?);
}

test "PluginManager health snapshot reports Vigil lifecycle wiring" {
    const allocator = std.testing.allocator;
    var io_ctx = @import("../test_utils.zig").TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();

    const ui_inbox = try vigil_api.standaloneInboxForTest(allocator);
    defer ui_inbox.close();
    var ui_bus = MessageBus.init(allocator, ui_inbox, "test-ui");

    var registry = CommandRegistry.init(allocator);
    defer registry.deinit();

    var manager = PluginManager.init(allocator, io, .empty, &ui_bus, &registry);
    defer manager.deinit();

    var runtime = try vigil_api.runtime(allocator, .{});
    defer runtime.deinit();
    var broker = vigil_api.PubSubBroker.init(allocator);
    defer broker.deinit();
    var supervisor = vigil_supervision.ComponentSupervisor.init(allocator, &runtime, .plugins);
    defer supervisor.deinit();
    supervisor.setEventBroker(&broker);
    manager.setVigilServices(&broker, &supervisor);

    supervisor.recordCrash("git");
    supervisor.recordRestartScheduled("git", 1000, 1);

    const snapshot = manager.healthSnapshot();
    try std.testing.expect(snapshot.vigil_broker_attached);
    try std.testing.expect(snapshot.vigil_supervisor_attached);
    try std.testing.expectEqual(@as(usize, 0), snapshot.loaded_plugins);
    try std.testing.expectEqual(@as(u64, 1), snapshot.lifecycle.crashes);
    try std.testing.expectEqual(@as(u64, 1), snapshot.lifecycle.restarts_scheduled);
}

test "filesystemListAllows: rejects parent-dir traversal even when the glob would match" {
    const scoped = [_][]const u8{"read:src/*"};
    try std.testing.expect(!PluginManager.filesystemListAllows(&scoped, "read:", "src/../../etc/passwd"));
    try std.testing.expect(!PluginManager.filesystemListAllows(&scoped, "read:", "src/../secret"));
    // Windows separator is covered too.
    try std.testing.expect(!PluginManager.filesystemListAllows(&scoped, "read:", "src\\..\\..\\secret"));
    // A wildcard-everything grant still cannot be turned into traversal.
    const wild = [_][]const u8{"read:*"};
    try std.testing.expect(!PluginManager.filesystemListAllows(&wild, "read:", "../../etc/passwd"));
    // ...but a clean path under the same wildcard is still allowed.
    try std.testing.expect(PluginManager.filesystemListAllows(&wild, "read:", "src/deep/main.zig"));
}

test "pathHasParentRef: flags only whole `..` components" {
    try std.testing.expect(PluginManager.pathHasParentRef(".."));
    try std.testing.expect(PluginManager.pathHasParentRef("a/../b"));
    try std.testing.expect(PluginManager.pathHasParentRef("a\\..\\b"));
    try std.testing.expect(PluginManager.pathHasParentRef("../x"));
    try std.testing.expect(!PluginManager.pathHasParentRef("a/b/c"));
    // A name that merely contains ".." is not a parent ref.
    try std.testing.expect(!PluginManager.pathHasParentRef("a..b"));
    try std.testing.expect(!PluginManager.pathHasParentRef("..foo/bar"));
}

test "PluginManager dashboard report surfaces permissions widgets and denials" {
    const allocator = std.testing.allocator;
    var io_ctx = @import("../test_utils.zig").TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();

    const ui_inbox = try vigil_api.standaloneInboxForTest(allocator);
    defer ui_inbox.close();
    var ui_bus = MessageBus.init(allocator, ui_inbox, "test-ui");

    var registry = CommandRegistry.init(allocator);
    defer registry.deinit();

    var manager = PluginManager.init(allocator, io, .empty, &ui_bus, &registry);
    defer manager.deinit();

    try manager.installPluginPermissions("git", .{
        .spawn_allowlist = &.{"git"},
        .events = &.{ "buffer.*", "file.saved" },
        .filesystem = &.{"read:."},
    });
    try manager.installRestartPolicy("git", .on_crash);
    try manager.registerManifestCommand("git", .wasm, .{
        .id = "git.status",
        .title = "[Git] Status",
        .description = "Show repository status",
        .keybinding = "Space g s",
    });
    defer manager.cleanupPluginResources("git");
    try manager.upsertStatusItem("git", "branch", "Git: main*", 2, 10);
    try manager.upsertPanel("git", "summary", "Git", "dirty files: 2", 1, 30);
    manager.recordCapabilityDenied("git", .spawn, "curl");

    const json = try manager.dashboardJson(allocator);
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"git\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"runtime\":\"none\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"restart_policy\":\"on_crash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"commands\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"keybindings\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"status_items\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"panels\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"denials\":1") != null);

    const report = try manager.dashboardReport(allocator);
    defer allocator.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, "Plugin Dashboard") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "git") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "Commands: 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "keybindings: 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "spawn: git") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "denied spawn curl") != null);
}

test "PluginManager storage keys reject traversal" {
    try std.testing.expect(PluginManager.isSafeStorageKey("settings.json"));
    try std.testing.expect(PluginManager.isSafeStorageKey("cache/state-v1"));
    try std.testing.expect(!PluginManager.isSafeStorageKey("../settings.json"));
    try std.testing.expect(!PluginManager.isSafeStorageKey("cache/../../secret"));
    try std.testing.expect(!PluginManager.isSafeStorageKey("/absolute"));
    try std.testing.expect(!PluginManager.isSafeStorageKey("nested\\windows"));
}
