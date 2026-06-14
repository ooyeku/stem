const std = @import("std");
const vigil = @import("vigil");
const event_topics = @import("event_topics.zig");

pub const ComponentKind = enum {
    plugins,
    lsp,
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
    stats_mu: vigil.compat.Mutex = .{},
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

    pub fn recordCrash(self: *ComponentSupervisor, component_id: []const u8) void {
        self.stats_mu.lock();
        self.stats.crashes +%= 1;
        self.stats_mu.unlock();

        vigil.telemetry.emit(.{
            .event_type = .process_crashed,
            .timestamp_ms = vigil.compat.milliTimestamp(),
            .metadata = component_id,
        });

        const topic = switch (self.kind) {
            .plugins => event_topics.lifecycleTopic(.plugin_crashed),
            .lsp => event_topics.lifecycleTopic(.lsp_crashed),
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

        vigil.telemetry.emit(.{
            .event_type = .supervisor_restart,
            .timestamp_ms = vigil.compat.milliTimestamp(),
            .metadata = component_id,
        });

        const topic = switch (self.kind) {
            .plugins => event_topics.lifecycleTopic(.plugin_restart_scheduled),
            .lsp => event_topics.lifecycleTopic(.lsp_restart_scheduled),
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
    try vigil.telemetry.initGlobal(std.testing.allocator);
    defer vigil.telemetry.deinitGlobal();

    var runtime = try vigil.runtime(std.testing.allocator, .{});
    defer runtime.deinit();

    var supervisor = ComponentSupervisor.init(std.testing.allocator, &runtime, .plugins);
    defer supervisor.deinit();

    try std.testing.expect(supervisor.supervisor.options.enable_telemetry);
    try std.testing.expectEqual(vigil.RestartStrategy.one_for_one, supervisor.supervisor.options.strategy);

    supervisor.recordCrash("git");
    supervisor.recordRestartScheduled("git", 1000, 1);

    const snapshot = supervisor.snapshot();
    try std.testing.expectEqual(@as(u64, 1), snapshot.crashes);
    try std.testing.expectEqual(@as(u64, 1), snapshot.restarts_scheduled);
}
