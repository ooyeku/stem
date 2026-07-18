const std = @import("std");
const vigil_api = @import("vigil_adapters.zig");
const vigil = vigil_api.raw;
const event_topics = @import("event_topics.zig");

pub const ComponentKind = enum {
    plugins,
    lsp,
    /// In-process background workers (syntax parser, search indexer).
    workers,
};

pub const Snapshot = struct {
    crashes: u64 = 0,
    restarts_scheduled: u64 = 0,
};

pub const ComponentSupervisor = struct {
    allocator: std.mem.Allocator,
    kind: ComponentKind,
    supervisor: vigil.Supervisor,
    event_broker: ?*vigil.pubsub.PubSubBroker = null,
    /// Injected runtime emitter for crash/restart events (Vigil 3.0 has no
    /// global emitter). Not owned; must outlive this supervisor.
    telemetry_emitter: ?*vigil.telemetry.TelemetryEmitter = null,
    stats_mu: vigil_api.Mutex = .{},
    stats: Snapshot = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        runtime: *vigil.Runtime,
        kind: ComponentKind,
    ) ComponentSupervisor {
        var builder = runtime.supervisor()
            .strategy(.one_for_one)
            .maxRestarts(5)
            .maxSeconds(60);
        builder = builder.withTelemetry(true);
        return .{
            .allocator = allocator,
            .kind = kind,
            .supervisor = builder.build(),
        };
    }

    pub fn deinit(self: *ComponentSupervisor) void {
        self.supervisor.deinit();
    }

    pub fn setEventBroker(self: *ComponentSupervisor, broker: *vigil.pubsub.PubSubBroker) void {
        self.event_broker = broker;
    }

    pub fn setTelemetryEmitter(self: *ComponentSupervisor, emitter: *vigil.telemetry.TelemetryEmitter) void {
        self.telemetry_emitter = emitter;
    }

    fn emitTelemetry(self: *ComponentSupervisor, event: vigil.telemetry.Event) void {
        const emitter = self.telemetry_emitter orelse return;
        emitter.emit(event);
    }

    pub fn recordCrash(self: *ComponentSupervisor, component_id: []const u8) void {
        self.stats_mu.lock();
        self.stats.crashes +%= 1;
        self.stats_mu.unlock();

        var metadata_owned = false;
        const metadata = switch (self.kind) {
            .plugins => component_id,
            .workers => blk: {
                const m = std.fmt.allocPrint(self.allocator, "worker:{s}", .{component_id}) catch break :blk component_id;
                metadata_owned = true;
                break :blk m;
            },
            .lsp => blk: {
                const m = std.fmt.allocPrint(self.allocator, "lsp:{s}", .{component_id}) catch break :blk component_id;
                metadata_owned = true;
                break :blk m;
            },
        };
        defer if (metadata_owned) self.allocator.free(metadata);

        self.emitTelemetry(.{
            .event_type = .process_crashed,
            .timestamp_ms = vigil_api.milliTimestamp(),
            .metadata = metadata,
        });

        const topic = switch (self.kind) {
            .plugins => event_topics.lifecycleTopic(.plugin_crashed),
            .lsp => event_topics.lifecycleTopic(.lsp_crashed),
            .workers => event_topics.lifecycleTopic(.worker_crashed),
        };
        self.publish(topic, component_id);
    }

    pub fn recordRestartScheduled(
        self: *ComponentSupervisor,
        component_id: []const u8,
        delay_ms: i64,
        attempt: u32,
    ) void {
        _ = delay_ms;
        _ = attempt;

        self.stats_mu.lock();
        self.stats.restarts_scheduled +%= 1;
        self.stats_mu.unlock();

        self.emitTelemetry(.{
            .event_type = .supervisor_restart,
            .timestamp_ms = vigil_api.milliTimestamp(),
            .metadata = component_id,
        });

        const topic = switch (self.kind) {
            .plugins => event_topics.lifecycleTopic(.plugin_restart_scheduled),
            .lsp => event_topics.lifecycleTopic(.lsp_restart_scheduled),
            .workers => event_topics.lifecycleTopic(.worker_restart_scheduled),
        };
        self.publish(topic, component_id);
    }

    pub fn snapshot(self: *ComponentSupervisor) Snapshot {
        self.stats_mu.lock();
        defer self.stats_mu.unlock();
        return self.stats;
    }

    fn publish(self: *ComponentSupervisor, topic: []const u8, payload: []const u8) void {
        if (self.event_broker) |broker| {
            _ = broker.publish(topic, payload) catch {};
        }
    }
};

test "ComponentSupervisor is backed by a Vigil supervisor and telemetry" {
    var runtime = try vigil.runtime(std.testing.allocator, .{});
    defer runtime.deinit();

    var supervisor = ComponentSupervisor.init(std.testing.allocator, &runtime, .plugins);
    defer supervisor.deinit();
    supervisor.setTelemetryEmitter(&runtime.telemetry_emitter);

    try std.testing.expect(supervisor.supervisor.options.enable_telemetry);
    try std.testing.expectEqual(vigil.RestartStrategy.one_for_one, supervisor.supervisor.options.strategy);

    supervisor.recordCrash("git");
    supervisor.recordRestartScheduled("git", 1000, 1);

    const snapshot = supervisor.snapshot();
    try std.testing.expectEqual(@as(u64, 1), snapshot.crashes);
    try std.testing.expectEqual(@as(u64, 1), snapshot.restarts_scheduled);
}
