//! Commands that interact with cross-cutting subsystems (logs, jobs, plugins).
//! Each takes `core: anytype` to avoid circular imports with kernel/core.zig.

const std = @import("std");
const protocol = @import("../protocol.zig");
const logger_service = @import("../../services/logger.zig");
const telemetry = @import("../../services/telemetry.zig");

pub const SystemCommands = struct {
    pub fn cmdModeInsert(core: anytype) anyerror!void {
        core.mode = .insert;
        try core.sendUpdate();
    }
    pub fn cmdModeVisual(core: anytype) anyerror!void {
        core.mode = .visual;
        try core.sendUpdate();
    }
    pub fn cmdModeTerminal(core: anytype) anyerror!void {
        core.mode = .terminal;
        try core.sendUpdate();
    }
    pub fn cmdModeSelect(core: anytype) anyerror!void {
        core.mode = .select;
        // Signature-help is Insert-mode only; clear when we leave.
        // Idempotent — safe to call when no popup is showing.
        core.dismissSignatureHelp();
        try core.sendUpdate();
    }
    pub fn cmdShowHelp(core: anytype) anyerror!void {
        const Help = @import("../../ui/help.zig");
        try core.openVirtualBuffer("[HELP]", Help.help_text);
    }

    pub fn cmdShowPlugins(core: anytype) anyerror!void {
        var text = std.ArrayListUnmanaged(u8).empty;
        defer text.deinit(core.allocator);
        try text.appendSlice(core.allocator, "# Plugin Manager\n\n");

        const buffer_id = core.buffer_manager.buffers.items[core.buffer_manager.active_index].id;
        const ws = core.workspace_manager.getBufferWorkspace(buffer_id);
        const ws_name = if (ws) |w| w.name else "No Workspace";

        const info = try std.fmt.allocPrint(core.allocator, "- `Workspace`: {s}\n", .{ws_name});
        defer core.allocator.free(info);
        try text.appendSlice(core.allocator, info);

        const wasm_count = core.plugin_manager.wasm_plugins.count();
        const proc_count = core.plugin_manager.process_plugins.count();
        const total = wasm_count + proc_count;
        const count_line = try std.fmt.allocPrint(core.allocator, "- `Loaded Plugins`: {d} ({d} wasm, {d} exec)\n\n", .{ total, wasm_count, proc_count });
        defer core.allocator.free(count_line);
        try text.appendSlice(core.allocator, count_line);

        const health = core.plugin_manager.healthSnapshot();
        const health_line = try std.fmt.allocPrint(
            core.allocator,
            "- `Vigil Broker`: {s}\n- `Lifecycle Supervisor`: {s}\n- `Crashes`: {d}\n- `Restarts Scheduled`: {d}\n- `Event Subscribers`: {d}\n- `Pending Restarts`: {d}\n\n",
            .{
                if (health.vigil_broker_attached) "attached" else "missing",
                if (health.vigil_supervisor_attached) "attached" else "missing",
                health.lifecycle.crashes,
                health.lifecycle.restarts_scheduled,
                health.event_subscribers,
                health.pending_restarts,
            },
        );
        defer core.allocator.free(health_line);
        try text.appendSlice(core.allocator, health_line);

        try text.appendSlice(core.allocator, "## Installed Plugins\n\n");

        if (total == 0) {
            try text.appendSlice(core.allocator, "- No plugins loaded.\n");
            try text.appendSlice(core.allocator, "- Plugins live as directories under `~/.stem/plugins/`.\n");
        } else {
            var idx: usize = 1;
            var w_it = core.plugin_manager.wasm_plugins.valueIterator();
            while (w_it.next()) |wp_ptr| {
                const wp = wp_ptr.*;
                const line = try std.fmt.allocPrint(core.allocator, "### {d}. {s}\n- `Runtime`: wasm\n\n", .{ idx, wp.plugin_id });
                defer core.allocator.free(line);
                try text.appendSlice(core.allocator, line);
                idx += 1;
            }
            var p_it = core.plugin_manager.process_plugins.valueIterator();
            while (p_it.next()) |pp_ptr| {
                const pp = pp_ptr.*;
                const line = try std.fmt.allocPrint(core.allocator, "### {d}. {s}\n- `Runtime`: exec\n- `Entry`: {s}\n\n", .{ idx, pp.name, pp.entry });
                defer core.allocator.free(line);
                try text.appendSlice(core.allocator, line);
                idx += 1;
            }
        }

        try text.appendSlice(core.allocator,
            \\## Instructions
            \\
            \\- `Install`: Run `stem plugin install <path>` or copy a plugin
            \\  directory into `~/.stem/plugins/<name>/`.
            \\- `Restart`: Restart stem to load new plugins.
            \\- `q`: Close this buffer.
            \\
        );

        try core.openVirtualBuffer("[PLUGINS]", text.items);
    }

    /// Render the live message-bus telemetry snapshot into the `[STATS]`
    /// virtual buffer. Refreshable via `refreshStatsBufferIfOpen` from
    /// the core tick handler so the numbers tick up while the buffer
    /// is the active view.
    pub fn cmdShowStats(core: anytype) anyerror!void {
        const body = try renderStatsBuffer(core);
        defer core.allocator.free(body);
        try core.openVirtualBuffer("[STATS]", body);
        try core.sendUpdate();
    }

    /// If the active buffer is `[STATS]`, re-render its contents in
    /// place so it acts as a live monitor.
    pub fn refreshStatsBufferIfOpen(core: anytype) void {
        const idx = core.buffer_manager.active_index;
        if (idx >= core.buffer_manager.buffers.items.len) return;
        const buf = &core.buffer_manager.buffers.items[idx];
        if (!std.mem.eql(u8, buf.name, "[STATS]")) return;

        const body = renderStatsBuffer(core) catch return;
        defer core.allocator.free(body);
        // openVirtual replaces the existing buffer's content when the
        // name matches, so we route through it for a clean refresh.
        core.buffer_manager.openVirtual("[STATS]", body) catch {};
    }

    fn renderStatsBuffer(core: anytype) ![]u8 {
        const allocator = core.allocator;
        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        const w = &aw.writer;

        const snap = telemetry.snapshot();
        const plugin_health = core.plugin_manager.healthSnapshot();
        var lsp_health = try core.lsp_manager.healthSnapshot(allocator);
        defer lsp_health.deinit(allocator);

        try w.print(
            \\# stem — Runtime Health
            \\
            \\Live snapshot of the Vigil-backed runtime messaging layer.
            \\Refreshes on each tick while this buffer is the active view.
            \\
            \\## Vigil
            \\
        , .{});

        if (core.runtime_services) |runtime| {
            const runtime_health = runtime.healthSnapshot();
            try w.print(
                \\- API version: {d}.{d}.{d}
                \\- Telemetry bridge: {s}
                \\- Plugin supervisor: {d} crashes, {d} restarts scheduled
                \\- LSP supervisor: {d} crashes, {d} restarts scheduled
                \\
            , .{
                runtime_health.vigil_major,
                runtime_health.vigil_minor,
                runtime_health.vigil_patch,
                if (runtime_health.telemetry_initialized) "initialized" else "disabled",
                runtime_health.plugin_supervisor.crashes,
                runtime_health.plugin_supervisor.restarts_scheduled,
                runtime_health.lsp_supervisor.crashes,
                runtime_health.lsp_supervisor.restarts_scheduled,
            });
        } else {
            try w.writeAll("- Runtime services are not attached.\n");
        }

        try w.print(
            \\
            \\## Global
            \\
            \\- Bytes shipped through MessageBus: {d}
            \\- Coalesce events (renders/ticks superseded): {d}
            \\- Plugin crashes (since startup): {d}
            \\- Supervisor restarts: {d}
            \\
            \\## Per-bus
            \\
            \\
        , .{ snap.bytes_sent, snap.coalesce_events, snap.plugin_crashes, snap.supervisor_restarts });

        const per_bus = try telemetry.snapshotPerBus(allocator);
        defer {
            for (per_bus) |b| allocator.free(b.bus_name);
            allocator.free(per_bus);
        }

        if (per_bus.len == 0) {
            try w.writeAll("- _No traffic yet._\n");
        } else {
            try w.writeAll("| Bus | Sent | Dropped (full) | Dropped (backpressure) |\n");
            try w.writeAll("|---|---:|---:|---:|\n");
            for (per_bus) |b| {
                try w.print(
                    "| `{s}` | {d} | {d} | {d} |\n",
                    .{ b.bus_name, b.stats.sent, b.stats.dropped_full, b.stats.dropped_backpressure },
                );
            }
        }

        try w.print(
            \\
            \\## Plugins
            \\
            \\- Loaded: {d} ({d} wasm, {d} exec)
            \\- Vigil broker: {s}
            \\- Lifecycle supervisor: {s}
            \\- Pending exits: {d}
            \\- Pending restarts: {d}
            \\- Event subscribers: {d}
            \\- Registered plugin keybindings: {d}
            \\
        , .{
            plugin_health.loaded_plugins,
            plugin_health.wasm_plugins,
            plugin_health.process_plugins,
            if (plugin_health.vigil_broker_attached) "attached" else "missing",
            if (plugin_health.vigil_supervisor_attached) "attached" else "missing",
            plugin_health.pending_exits,
            plugin_health.pending_restarts,
            plugin_health.event_subscribers,
            plugin_health.keybindings,
        });

        try w.print(
            \\
            \\## LSP
            \\
            \\- Servers: {d} running, {d} healthy, {d} unhealthy, {d} initializing
            \\- Open documents: {d}
            \\- Pending changes: {d}
            \\- In-progress starts: {d}
            \\- Restart-tracked languages: {d}
            \\- Lifecycle: {d} crashes, {d} restarts scheduled
            \\
        , .{
            lsp_health.running_servers,
            lsp_health.healthy_servers,
            lsp_health.unhealthy_servers,
            lsp_health.initializing_servers,
            lsp_health.open_documents,
            lsp_health.pending_changes,
            lsp_health.in_progress_starts,
            lsp_health.restart_tracked_languages,
            lsp_health.lifecycle.crashes,
            lsp_health.lifecycle.restarts_scheduled,
        });

        if (lsp_health.servers.len > 0) {
            try w.writeAll("\n| Language | State | Restarts | Root |\n");
            try w.writeAll("|---|---|---:|---|\n");
            for (lsp_health.servers) |server| {
                try w.print(
                    "| `{s}` | {s} | {d} | {s} |\n",
                    .{
                        server.lang,
                        lspStateLabel(server.running, server.healthy, server.initialized),
                        server.restart_attempts,
                        server.root_path orelse "-",
                    },
                );
            }
        }

        try w.writeAll(
            \\
            \\## How to read this
            \\
            \\- `sent`: messages that landed in the destination's priority queue.
            \\- `dropped (full)`: mailbox at capacity. Indicates a stuck consumer.
            \\- `dropped (backpressure)`: bulk/background producer outpacing consumer.
            \\  Common during heavy terminal output or scan results — desired.
            \\- `coalesce events`: renders or ticks superseded by a newer one
            \\  in the same slot. Higher = more redundant work avoided.
            \\
        );

        return aw.toOwnedSlice();
    }

    fn lspStateLabel(running: bool, healthy: bool, initialized: bool) []const u8 {
        if (!running) return "stopped";
        if (!healthy) return "unhealthy";
        if (!initialized) return "initializing";
        return "ready";
    }

    pub fn cmdJobList(core: anytype) anyerror!void {
        const active_jobs = try core.job_manager.getActiveJobs(core.allocator);
        defer core.allocator.free(active_jobs);

        var text = std.ArrayListUnmanaged(u8).empty;
        defer text.deinit(core.allocator);

        try text.appendSlice(core.allocator, "=== Background Jobs ===\n\n");

        if (active_jobs.len == 0) {
            try text.appendSlice(core.allocator, "No active jobs.\n");
        } else {
            for (active_jobs, 0..) |job, i| {
                const status_str = switch (job.status.load(.acquire)) {
                    .pending => "Pending",
                    .running => "Running",
                    .completed => "Completed",
                    .failed => "Failed",
                    .cancelled => "Cancelled",
                };
                const line = try std.fmt.allocPrint(core.allocator, "{d}. [{s}] {s} ({d}%)\n", .{
                    i + 1,
                    status_str,
                    job.name,
                    job.progress,
                });
                defer core.allocator.free(line);
                try text.appendSlice(core.allocator, line);
            }
        }

        try core.openVirtualBuffer("[Jobs]", text.items);
        try core.sendUpdate();
    }

    pub fn cmdViewLogs(core: anytype) anyerror!void {
        const logs = blk: {
            if (logger_service.getGlobal()) |l| {
                break :blk l.getEntries(core.allocator) catch &[_]protocol.LogEntry{};
            }
            break :blk &[_]protocol.LogEntry{};
        };
        defer {
            for (logs) |l| {
                core.allocator.free(l.scope);
                core.allocator.free(l.message);
            }
            core.allocator.free(logs);
        }

        var aw: std.Io.Writer.Allocating = .init(core.allocator);
        defer aw.deinit();

        try aw.writer.writeAll("TIMESTAMP LEVEL SCOPE               MESSAGE\n");

        for (logs) |entry| {
            const ct_offset_seconds: i64 = -6 * 3600;
            const adjusted_ts = entry.timestamp + ct_offset_seconds;
            const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(adjusted_ts) };
            const day_seconds = epoch_seconds.getDaySeconds();

            var time_buf: [32]u8 = undefined;
            const time_str = try std.fmt.bufPrint(&time_buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{
                day_seconds.getHoursIntoDay(),
                day_seconds.getMinutesIntoHour(),
                day_seconds.getSecondsIntoMinute(),
            });

            const level_str = switch (entry.level) {
                0 => "DEBUG",
                1 => "INFO ",
                2 => "WARN ",
                3 => "ERROR",
                else => "UNK  ",
            };

            const scope_width = 20;
            var scope_buf: [20]u8 = undefined;
            @memset(&scope_buf, ' ');
            const len = @min(entry.scope.len, scope_width);
            @memcpy(scope_buf[0..len], entry.scope[0..len]);

            try aw.writer.print("{s} {s} {s} {s}\n", .{ time_str, level_str, scope_buf[0..scope_width], entry.message });
        }

        try core.openVirtualBuffer("[LOGS]", aw.written());
        core.mode = .view;
        try core.sendUpdate();
    }

    pub fn cmdClearLogs(core: anytype) anyerror!void {
        if (logger_service.getGlobal()) |l| {
            l.clear();
        }
        try core.sendUpdate();
    }
};
