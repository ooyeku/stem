const std = @import("std");
const vigil_api = @import("vigil_adapters.zig");
const vigil = vigil_api.raw;
const telemetry = @import("telemetry.zig");
const vigil_supervision = @import("vigil_supervision.zig");

pub const EditorInboxes = struct {
    main: *vigil.Inbox,
    core: *vigil.Inbox,
};

/// Live counters fed by Vigil telemetry handlers — the runtime's "check
/// engine light". Module-level atomics because telemetry handlers are
/// context-free function pointers; handlers fire from arbitrary threads.
pub const RuntimeAlerts = struct {
    var dead_lettered: std.atomic.Value(u64) = .init(0);
    var poison_detected: std.atomic.Value(u64) = .init(0);
    var circuits_opened: std.atomic.Value(u64) = .init(0);
    var supervisor_restarts: std.atomic.Value(u64) = .init(0);
    var component_crashes: std.atomic.Value(u64) = .init(0);
    /// Millisecond wall-clock of the most recent alert, 0 when none.
    var last_alert_ms: std.atomic.Value(i64) = .init(0);

    pub const Snapshot = struct {
        dead_lettered: u64,
        poison_detected: u64,
        circuits_opened: u64,
        supervisor_restarts: u64,
        component_crashes: u64,
        last_alert_ms: i64,

        pub fn total(self: Snapshot) u64 {
            return self.dead_lettered + self.poison_detected +
                self.circuits_opened + self.supervisor_restarts +
                self.component_crashes;
        }
    };

    pub fn snapshot() Snapshot {
        return .{
            .dead_lettered = dead_lettered.load(.monotonic),
            .poison_detected = poison_detected.load(.monotonic),
            .circuits_opened = circuits_opened.load(.monotonic),
            .supervisor_restarts = supervisor_restarts.load(.monotonic),
            .component_crashes = component_crashes.load(.monotonic),
            .last_alert_ms = last_alert_ms.load(.monotonic),
        };
    }

    /// True when an alert fired within the trailing window — drives the
    /// statusline indicator so it decays instead of latching forever.
    pub fn recentlyDegraded(window_ms: i64) bool {
        const last = last_alert_ms.load(.monotonic);
        if (last == 0) return false;
        return vigil.compat.milliTimestamp() - last <= window_ms;
    }

    /// Test hook: reset all counters.
    pub fn reset() void {
        dead_lettered.store(0, .monotonic);
        poison_detected.store(0, .monotonic);
        circuits_opened.store(0, .monotonic);
        supervisor_restarts.store(0, .monotonic);
        component_crashes.store(0, .monotonic);
        last_alert_ms.store(0, .monotonic);
    }

    fn bump(counter: *std.atomic.Value(u64)) void {
        _ = counter.fetchAdd(1, .monotonic);
        last_alert_ms.store(vigil.compat.milliTimestamp(), .monotonic);
    }

    fn onDeadLetter(event: vigil.telemetry.Event) void {
        _ = event;
        bump(&dead_lettered);
    }

    fn onPoison(event: vigil.telemetry.Event) void {
        _ = event;
        bump(&poison_detected);
    }

    fn onCircuitOpened(event: vigil.telemetry.Event) void {
        _ = event;
        bump(&circuits_opened);
    }

    fn onSupervisorRestart(event: vigil.telemetry.Event) void {
        _ = event;
        bump(&supervisor_restarts);
    }

    fn onProcessCrashed(event: vigil.telemetry.Event) void {
        _ = event;
        bump(&component_crashes);
    }

    /// Register handlers on both emitters stem uses: the runtime emitter
    /// (inbox dead-letter/poison lifecycle) and the global emitter
    /// (ComponentSupervisor crash/restart, circuit breakers). Registration
    /// failures are nonfatal — the light just stays dark.
    fn attach(emitter: *vigil.telemetry.TelemetryEmitter) void {
        emitter.on(.message_dead_lettered, onDeadLetter) catch {};
        emitter.on(.poison_message_detected, onPoison) catch {};
        if (vigil.telemetry.getGlobal()) |global| {
            global.on(.circuit_opened, onCircuitOpened) catch {};
            global.on(.supervisor_restart, onSupervisorRestart) catch {};
            global.on(.process_crashed, onProcessCrashed) catch {};
        }
    }
};

pub const Service = enum {
    ui,
    core,

    pub fn name(self: Service) []const u8 {
        return switch (self) {
            .ui => "stem.ui",
            .core => "stem.core",
        };
    }
};

pub const ShutdownCallback = *const fn (ctx: *anyopaque) void;

const ShutdownHook = struct {
    name: []const u8,
    context: *anyopaque,
    callback: ShutdownCallback,
};

pub const StemRuntime = struct {
    allocator: std.mem.Allocator,
    vigil_runtime: vigil.Runtime,
    event_broker: vigil.pubsub.PubSubBroker,
    plugin_supervisor: vigil_supervision.ComponentSupervisor,
    lsp_supervisor: vigil_supervision.ComponentSupervisor,
    worker_supervisor: vigil_supervision.ComponentSupervisor,
    /// Multi-instance presence (opt-in via STEM_CLUSTER): a Vigil
    /// distributed registry that advertises this instance to local peers
    /// and tracks their health. Null unless explicitly enabled.
    distributed: ?*vigil.DistributedRegistry = null,
    /// Owned backing storage for peer "host:port" strings and the slice
    /// array handed to the registry config.
    cluster_peers: ?[][]const u8 = null,
    service_mu: vigil_api.Mutex = .{},
    registered_services: std.StringHashMapUnmanaged(void) = .empty,
    shutdown_mu: vigil_api.Mutex = .{},
    shutdown_hooks: std.ArrayListUnmanaged(ShutdownHook) = .empty,
    shutdown_started: bool = false,
    telemetry_initialized: bool = false,

    pub const HealthSnapshot = struct {
        vigil_major: u32,
        vigil_minor: u32,
        vigil_patch: u32,
        telemetry_initialized: bool,
        runtime_running: bool,
        registered_services: usize,
        shutdown_hooks: usize,
        shutdown_started: bool,
        timeline_enabled: bool,
        /// Timer-service counters; null until the first timer is scheduled.
        timers: ?vigil.TimerServiceSnapshot,
        /// Check-engine-light counters fed by telemetry handlers.
        alerts: RuntimeAlerts.Snapshot,
        /// Whether multi-instance presence (STEM_CLUSTER) is active.
        cluster_enabled: bool,
        plugin_supervisor: vigil_supervision.Snapshot,
        lsp_supervisor: vigil_supervision.Snapshot,
        worker_supervisor: vigil_supervision.Snapshot,
    };

    pub fn init(allocator: std.mem.Allocator) !StemRuntime {
        var vigil_runtime = try vigil_api.runtime(allocator, .{});
        errdefer vigil_runtime.deinit();

        var event_broker = vigil.pubsub.PubSubBroker.init(allocator);
        errdefer event_broker.deinit();

        const telemetry_initialized = blk: {
            telemetry.init(allocator) catch break :blk false;
            break :blk true;
        };

        var plugin_supervisor = vigil_supervision.ComponentSupervisor.init(allocator, &vigil_runtime, .plugins);
        errdefer plugin_supervisor.deinit();

        var lsp_supervisor = vigil_supervision.ComponentSupervisor.init(allocator, &vigil_runtime, .lsp);
        errdefer lsp_supervisor.deinit();

        var worker_supervisor = vigil_supervision.ComponentSupervisor.init(allocator, &vigil_runtime, .workers);
        errdefer worker_supervisor.deinit();

        return .{
            .allocator = allocator,
            .vigil_runtime = vigil_runtime,
            .event_broker = event_broker,
            .plugin_supervisor = plugin_supervisor,
            .lsp_supervisor = lsp_supervisor,
            .worker_supervisor = worker_supervisor,
            .telemetry_initialized = telemetry_initialized,
        };
    }

    /// Number of recent Vigil telemetry events retained for debugging.
    const timeline_capacity: usize = 256;

    /// Post-placement wiring: called once `self` is at its final address
    /// (`init` returns by value, so pointers into `self` can only be handed
    /// out afterwards).
    pub fn attachEventBroker(self: *StemRuntime) void {
        self.plugin_supervisor.setEventBroker(&self.event_broker);
        self.lsp_supervisor.setEventBroker(&self.event_broker);
        self.worker_supervisor.setEventBroker(&self.event_broker);
        // Bounded ring of recent runtime telemetry events (dead letters,
        // lifecycle transitions). Feeds `debugDump()`; failure to allocate
        // it just means dumps omit the timeline tail.
        self.vigil_runtime.enableTimeline(timeline_capacity) catch {};
        RuntimeAlerts.attach(&self.vigil_runtime.telemetry_emitter);
    }

    /// Human-readable Vigil runtime state: health, registered mailboxes,
    /// and the tail of the event timeline. Caller owns the returned slice.
    pub fn debugDump(self: *StemRuntime, allocator: std.mem.Allocator) ![]u8 {
        return self.vigil_runtime.debugDump(allocator);
    }

    /// Opt-in multi-instance presence. Reads `STEM_CLUSTER` in the form
    /// `<listen_port>[,host:port,...]` — e.g. `9101,127.0.0.1:9102` — and
    /// starts a distributed registry advertising this instance under
    /// `stem.<pid>`. Silently a no-op when the variable is unset; failures
    /// (port in use, bad spec) are logged and leave the editor untouched.
    pub fn enableClusterFromEnv(self: *StemRuntime) void {
        if (@import("builtin").os.tag == .windows) return;
        const spec_z = std.c.getenv("STEM_CLUSTER") orelse return;
        const spec = std.mem.span(spec_z);
        self.enableClusterFromSpec(spec) catch |err| {
            std.log.warn("STEM_CLUSTER='{s}' rejected: {}", .{ spec, err });
        };
    }

    fn enableClusterFromSpec(self: *StemRuntime, spec: []const u8) !void {
        if (self.distributed != null) return;

        var it = std.mem.splitScalar(u8, spec, ',');
        const port_str = std.mem.trim(u8, it.next() orelse return error.InvalidClusterSpec, " ");
        const listen_port = try std.fmt.parseInt(u16, port_str, 10);

        var peers: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (peers.items) |p| self.allocator.free(p);
            peers.deinit(self.allocator);
        }
        while (it.next()) |peer| {
            const trimmed = std.mem.trim(u8, peer, " ");
            if (trimmed.len == 0) continue;
            const owned = try self.allocator.dupe(u8, trimmed);
            errdefer self.allocator.free(owned);
            try peers.append(self.allocator, owned);
        }
        const peer_slices = try peers.toOwnedSlice(self.allocator);
        errdefer {
            for (peer_slices) |p| self.allocator.free(p);
            self.allocator.free(peer_slices);
        }

        const registry = try self.allocator.create(vigil.DistributedRegistry);
        errdefer self.allocator.destroy(registry);
        registry.* = try vigil.DistributedRegistry.init(self.allocator, .{
            .cluster_nodes = peer_slices,
            .listen_port = listen_port,
        });
        errdefer registry.deinit();
        try registry.startSync();

        self.distributed = registry;
        self.cluster_peers = peer_slices;
        telemetry.recordTimeline(.runtime, "cluster", "enabled");
    }

    /// Owned snapshot of cluster peer health, or null when clustering is
    /// off. Caller calls `deinit()` on the returned snapshot.
    pub fn clusterSnapshot(self: *StemRuntime, allocator: std.mem.Allocator) !?vigil.DistributedRegistrySnapshot {
        const registry = self.distributed orelse return null;
        return try registry.snapshot(allocator);
    }

    fn deinitCluster(self: *StemRuntime) void {
        if (self.distributed) |registry| {
            registry.deinit();
            self.allocator.destroy(registry);
            self.distributed = null;
        }
        if (self.cluster_peers) |peers| {
            for (peers) |p| self.allocator.free(p);
            self.allocator.free(peers);
            self.cluster_peers = null;
        }
    }

    pub fn deinit(self: *StemRuntime) void {
        self.shutdown();
        self.deinitCluster();
        self.worker_supervisor.deinit();
        self.lsp_supervisor.deinit();
        self.plugin_supervisor.deinit();
        self.event_broker.deinit();
        if (self.telemetry_initialized) {
            telemetry.deinit();
            self.telemetry_initialized = false;
        }
        self.clearShutdownHooks();
        self.clearRegisteredServices();
        self.vigil_runtime.deinit();
    }

    pub fn createEditorInboxes(self: *StemRuntime) !EditorInboxes {
        const main_inbox = try vigil_api.createInbox(&self.vigil_runtime);
        errdefer main_inbox.close();
        try self.registerServiceInbox(.ui, main_inbox);
        errdefer self.unregisterService(.ui);

        const core_inbox = try vigil_api.createInbox(&self.vigil_runtime);
        errdefer core_inbox.close();
        try self.registerServiceInbox(.core, core_inbox);

        // When clustering is on, advertise this instance to peers under a
        // pid-qualified name. Presence only for now — peers can see and
        // health-check each other; no cross-instance messaging yet.
        if (self.distributed) |registry| {
            var name_buf: [64]u8 = undefined;
            const pid: i64 = if (@import("builtin").os.tag == .windows)
                0
            else
                @intCast(std.c.getpid());
            if (std.fmt.bufPrint(&name_buf, "stem.instance.{d}", .{pid})) |name| {
                registry.register(name, core_inbox.mailbox, .global) catch |err| {
                    std.log.warn("cluster registration failed: {}", .{err});
                };
            } else |_| {}
        }

        return .{
            .main = main_inbox,
            .core = core_inbox,
        };
    }

    pub fn healthSnapshot(self: *StemRuntime) HealthSnapshot {
        const version = vigil.getVersion();
        self.service_mu.lock();
        const service_count = self.registered_services.count();
        self.service_mu.unlock();

        self.shutdown_mu.lock();
        const hook_count = self.shutdown_hooks.items.len;
        const shutdown_started = self.shutdown_started;
        self.shutdown_mu.unlock();

        return .{
            .vigil_major = version.major,
            .vigil_minor = version.minor,
            .vigil_patch = version.patch,
            .telemetry_initialized = self.telemetry_initialized,
            .runtime_running = self.vigil_runtime.isRunning(),
            .registered_services = service_count,
            .shutdown_hooks = hook_count,
            .shutdown_started = shutdown_started,
            .timeline_enabled = self.vigil_runtime.timeline != null,
            .timers = if (self.vigil_runtime.timer_svc) |svc| svc.snapshot() else null,
            .alerts = RuntimeAlerts.snapshot(),
            .cluster_enabled = self.distributed != null,
            .plugin_supervisor = self.plugin_supervisor.snapshot(),
            .lsp_supervisor = self.lsp_supervisor.snapshot(),
            .worker_supervisor = self.worker_supervisor.snapshot(),
        };
    }

    pub fn publish(self: *StemRuntime, topic: []const u8, payload: []const u8) !vigil.PublishResult {
        return try self.event_broker.publish(topic, payload);
    }

    pub fn registerServiceInbox(self: *StemRuntime, service: Service, inbox: *vigil.Inbox) !void {
        const name = service.name();
        self.service_mu.lock();
        defer self.service_mu.unlock();
        if (self.registered_services.contains(name)) return error.AlreadyRegistered;

        try self.vigil_runtime.register(name, inbox.mailbox);
        errdefer self.vigil_runtime.registry.unregister(name);

        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        try self.registered_services.put(self.allocator, name_copy, {});
        telemetry.recordTimeline(.runtime, name, "registered");
    }

    pub fn unregisterService(self: *StemRuntime, service: Service) void {
        const name = service.name();
        self.service_mu.lock();
        defer self.service_mu.unlock();
        self.vigil_runtime.registry.unregister(name);
        if (self.registered_services.fetchRemove(name)) |entry| {
            self.allocator.free(entry.key);
        }
        telemetry.recordTimeline(.runtime, name, "unregistered");
    }

    pub fn resolveService(self: *StemRuntime, service: Service) ?*vigil.ProcessMailbox {
        return self.vigil_runtime.whereis(service.name());
    }

    pub fn addShutdownHook(
        self: *StemRuntime,
        name: []const u8,
        context: *anyopaque,
        callback: ShutdownCallback,
    ) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);

        self.shutdown_mu.lock();
        defer self.shutdown_mu.unlock();
        try self.shutdown_hooks.append(self.allocator, .{
            .name = name_copy,
            .context = context,
            .callback = callback,
        });
        telemetry.recordTimeline(.runtime, name, "shutdown_hook_registered");
    }

    pub fn shutdown(self: *StemRuntime) void {
        self.shutdown_mu.lock();
        if (self.shutdown_started) {
            self.shutdown_mu.unlock();
            return;
        }
        self.shutdown_started = true;
        const hooks = self.allocator.alloc(ShutdownHook, self.shutdown_hooks.items.len) catch {
            self.shutdown_mu.unlock();
            self.vigil_runtime.shutdown();
            return;
        };
        @memcpy(hooks, self.shutdown_hooks.items);
        self.shutdown_mu.unlock();
        defer self.allocator.free(hooks);

        telemetry.recordTimeline(.shutdown, "runtime", "begin");
        var i = hooks.len;
        while (i > 0) {
            i -= 1;
            telemetry.recordTimeline(.shutdown, hooks[i].name, "run");
            hooks[i].callback(hooks[i].context);
        }
        self.vigil_runtime.shutdown();
        telemetry.recordTimeline(.shutdown, "runtime", "complete");
    }

    fn clearRegisteredServices(self: *StemRuntime) void {
        self.service_mu.lock();
        defer self.service_mu.unlock();
        var it = self.registered_services.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.registered_services.deinit(self.allocator);
        self.registered_services = .empty;
    }

    fn clearShutdownHooks(self: *StemRuntime) void {
        self.shutdown_mu.lock();
        defer self.shutdown_mu.unlock();
        for (self.shutdown_hooks.items) |hook| {
            self.allocator.free(hook.name);
        }
        self.shutdown_hooks.deinit(self.allocator);
        self.shutdown_hooks = .empty;
    }
};

test "StemRuntime owns Vigil runtime inboxes and pubsub broker" {
    var runtime = try StemRuntime.init(std.testing.allocator);
    runtime.attachEventBroker();
    defer runtime.deinit();

    const version = vigil.getVersion();
    try std.testing.expectEqual(@as(u32, 2), version.major);
    try std.testing.expect(@hasDecl(vigil, "Runtime"));
    try std.testing.expect(!@hasDecl(vigil, "createMailbox"));
    try std.testing.expect(!@hasDecl(vigil, "global_registry"));

    const inboxes = try runtime.createEditorInboxes();
    defer inboxes.core.close();
    defer inboxes.main.close();

    try inboxes.core.send("core");
    var msg = try inboxes.core.recv();
    defer msg.deinit();
    try std.testing.expectEqualStrings("core", msg.payload.?);
}

test "StemRuntime pubsub broker fans out editor topics" {
    var runtime = try StemRuntime.init(std.testing.allocator);
    runtime.attachEventBroker();
    defer runtime.deinit();

    var inbox = try runtime.vigil_runtime.inbox(.{ .capacity = 4 });
    defer inbox.close();

    var subscriber = vigil.pubsub.Subscriber.init(std.testing.allocator, inbox);
    defer subscriber.deinit();
    try subscriber.subscribe(&[_][]const u8{"editor.buffer.changed"});
    try runtime.event_broker.subscribe(&subscriber);

    _ = try runtime.publish("editor.buffer.changed", "main.zig");

    var msg = try inbox.recv();
    defer msg.deinit();
    try std.testing.expectEqualStrings("main.zig", msg.payload.?);
}

test "StemRuntime health snapshot includes Vigil version and supervisors" {
    var runtime = try StemRuntime.init(std.testing.allocator);
    runtime.attachEventBroker();
    defer runtime.deinit();

    runtime.plugin_supervisor.recordCrash("git");
    runtime.lsp_supervisor.recordRestartScheduled("zig", 0, 1);

    const snapshot = runtime.healthSnapshot();
    try std.testing.expectEqual(@as(u32, 2), snapshot.vigil_major);
    try std.testing.expect(snapshot.telemetry_initialized);
    try std.testing.expectEqual(@as(u64, 1), snapshot.plugin_supervisor.crashes);
    try std.testing.expectEqual(@as(u64, 1), snapshot.lsp_supervisor.restarts_scheduled);
}

test "RuntimeAlerts counts telemetry events from both emitters" {
    var runtime = try StemRuntime.init(std.testing.allocator);
    runtime.attachEventBroker();
    defer runtime.deinit();

    RuntimeAlerts.reset();
    defer RuntimeAlerts.reset();
    try std.testing.expect(!RuntimeAlerts.recentlyDegraded(60_000));

    // Runtime emitter carries inbox dead-letter lifecycle events.
    runtime.vigil_runtime.telemetry_emitter.emit(.{
        .event_type = .message_dead_lettered,
        .timestamp_ms = vigil_api.milliTimestamp(),
    });
    // The global emitter carries supervisor crash/restart events.
    runtime.plugin_supervisor.recordCrash("git");

    const alerts = RuntimeAlerts.snapshot();
    try std.testing.expectEqual(@as(u64, 1), alerts.dead_lettered);
    try std.testing.expectEqual(@as(u64, 1), alerts.component_crashes);
    try std.testing.expectEqual(@as(u64, 2), alerts.total());
    try std.testing.expect(RuntimeAlerts.recentlyDegraded(60_000));

    const health = runtime.healthSnapshot();
    try std.testing.expectEqual(@as(u64, 2), health.alerts.total());
}

test "StemRuntime cluster presence is off by default and rejects bad specs" {
    var runtime = try StemRuntime.init(std.testing.allocator);
    runtime.attachEventBroker();
    defer runtime.deinit();

    try std.testing.expect(runtime.distributed == null);
    try std.testing.expect(!runtime.healthSnapshot().cluster_enabled);
    try std.testing.expectEqual(
        @as(?vigil.DistributedRegistrySnapshot, null),
        try runtime.clusterSnapshot(std.testing.allocator),
    );

    // Malformed specs must fail without leaving partial state behind.
    try std.testing.expectError(error.InvalidCharacter, runtime.enableClusterFromSpec("not-a-port"));
    try std.testing.expectError(error.InvalidNodeFormat, runtime.enableClusterFromSpec("9101,bad-peer-no-colon"));
    try std.testing.expect(runtime.distributed == null);
}

test "StemRuntime cluster spec starts presence with a listener" {
    var runtime = try StemRuntime.init(std.testing.allocator);
    runtime.attachEventBroker();
    defer runtime.deinit();

    // Obscure fixed port; no peers. If another process owns the port the
    // enable fails cleanly — assert only that state stays consistent.
    runtime.enableClusterFromSpec("39217") catch |err| {
        std.debug.print("cluster listener unavailable in this environment: {}\n", .{err});
        try std.testing.expect(runtime.distributed == null);
        return;
    };
    try std.testing.expect(runtime.distributed != null);
    try std.testing.expect(runtime.healthSnapshot().cluster_enabled);

    var snapshot = (try runtime.clusterSnapshot(std.testing.allocator)).?;
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 0), snapshot.peers.len);

    const inboxes = try runtime.createEditorInboxes();
    defer inboxes.core.close();
    defer inboxes.main.close();

    var after = (try runtime.clusterSnapshot(std.testing.allocator)).?;
    defer after.deinit();
    try std.testing.expect(after.local_names >= 1);
}

test "StemRuntime debug toolkit exposes timeline and dump" {
    var runtime = try StemRuntime.init(std.testing.allocator);
    runtime.attachEventBroker();
    defer runtime.deinit();

    var snapshot = runtime.healthSnapshot();
    try std.testing.expect(snapshot.timeline_enabled);
    try std.testing.expect(snapshot.timers == null);

    // Scheduling work lazily starts the runtime timer service, and the
    // health snapshot picks it up.
    const timers = try runtime.vigil_runtime.timers();
    const Noop = struct {
        fn tick() void {}
    };
    const id = try timers.setInterval(60_000, Noop.tick);
    defer _ = timers.cancel(id);
    snapshot = runtime.healthSnapshot();
    try std.testing.expect(snapshot.timers != null);
    try std.testing.expectEqual(@as(usize, 1), snapshot.timers.?.pending);

    const dump = try runtime.debugDump(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expect(std.mem.indexOf(u8, dump, "vigil runtime dump") != null);
}

test "StemRuntime registers editor inboxes in Vigil registry" {
    var runtime = try StemRuntime.init(std.testing.allocator);
    runtime.attachEventBroker();
    defer runtime.deinit();

    const inboxes = try runtime.createEditorInboxes();
    defer inboxes.core.close();
    defer inboxes.main.close();

    try std.testing.expect(runtime.resolveService(.ui) == inboxes.main.mailbox);
    try std.testing.expect(runtime.resolveService(.core) == inboxes.core.mailbox);

    const snapshot = runtime.healthSnapshot();
    try std.testing.expectEqual(@as(usize, 2), snapshot.registered_services);
}

test "StemRuntime shutdown hooks run once and stop Vigil runtime" {
    var runtime = try StemRuntime.init(std.testing.allocator);
    runtime.attachEventBroker();
    defer runtime.deinit();

    const HookState = struct {
        calls: u32 = 0,

        fn run(ctx: *anyopaque) void {
            const state: *@This() = @ptrCast(@alignCast(ctx));
            state.calls += 1;
        }
    };

    var state = HookState{};
    try runtime.addShutdownHook("test.hook", @ptrCast(&state), HookState.run);

    runtime.shutdown();
    runtime.shutdown();

    try std.testing.expectEqual(@as(u32, 1), state.calls);
    try std.testing.expect(!runtime.vigil_runtime.isRunning());

    const snapshot = runtime.healthSnapshot();
    try std.testing.expect(snapshot.shutdown_started);
    try std.testing.expectEqual(@as(usize, 1), snapshot.shutdown_hooks);
}
