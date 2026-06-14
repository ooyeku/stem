const std = @import("std");
const vigil_api = @import("vigil_adapters.zig");
const vigil = vigil_api.raw;
const telemetry = @import("telemetry.zig");
const vigil_supervision = @import("vigil_supervision.zig");

pub const EditorInboxes = struct {
    main: *vigil.Inbox,
    core: *vigil.Inbox,
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
        plugin_supervisor: vigil_supervision.Snapshot,
        lsp_supervisor: vigil_supervision.Snapshot,
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

        return .{
            .allocator = allocator,
            .vigil_runtime = vigil_runtime,
            .event_broker = event_broker,
            .plugin_supervisor = plugin_supervisor,
            .lsp_supervisor = lsp_supervisor,
            .telemetry_initialized = telemetry_initialized,
        };
    }

    pub fn attachEventBroker(self: *StemRuntime) void {
        self.plugin_supervisor.setEventBroker(&self.event_broker);
        self.lsp_supervisor.setEventBroker(&self.event_broker);
    }

    pub fn deinit(self: *StemRuntime) void {
        self.shutdown();
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
            .plugin_supervisor = self.plugin_supervisor.snapshot(),
            .lsp_supervisor = self.lsp_supervisor.snapshot(),
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
