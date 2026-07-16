//! Commands that interact with cross-cutting subsystems (logs, jobs, plugins).
//! Each takes `core: anytype` to avoid circular imports with kernel/core.zig.

const std = @import("std");
const protocol = @import("../protocol.zig");
const logger_service = @import("../../services/logger.zig");
const telemetry = @import("../../services/telemetry.zig");
const LSPManager = @import("../../services/lsp_manager.zig").LSPManager;
const project_tasks = @import("../project_tasks.zig");
const runtime_watchdog = @import("../runtime_watchdog.zig");
const JobProgress = @import("../jobs.zig").JobProgress;

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

    pub fn cmdShowControlCenter(core: anytype) anyerror!void {
        const body = try renderControlCenterBuffer(core);
        defer core.allocator.free(body);
        try core.openVirtualBuffer("[CONTROL CENTER]", body);
        core.mode = .view;
        try core.sendUpdate();
    }

    pub fn cmdStemHeal(core: anytype) anyerror!void {
        const body = try renderHealingBuffer(core);
        defer core.allocator.free(body);
        try core.openVirtualBuffer("[HEAL]", body);
        core.mode = .view;
        try core.sendUpdate();
    }

    pub fn cmdShowProjectBrain(core: anytype) anyerror!void {
        const body = try renderProjectBrainBuffer(core);
        defer core.allocator.free(body);
        try core.openVirtualBuffer("[PROJECT BRAIN]", body);
        core.mode = .view;
        try core.sendUpdate();
    }

    pub fn cmdProjectTasks(core: anytype) anyerror!void {
        const body = try renderProjectTasksBuffer(core);
        defer core.allocator.free(body);
        try core.openVirtualBuffer("[TASKS]", body);
        core.mode = .view;
        try core.sendUpdate();
    }

    pub fn cmdTaskRunBuild(core: anytype) anyerror!void {
        try runDetectedTask(core, .build);
    }

    pub fn cmdTaskRunTest(core: anytype) anyerror!void {
        try runDetectedTask(core, .@"test");
    }

    pub fn cmdTaskRun(core: anytype) anyerror!void {
        try runDetectedTask(core, .run);
    }

    pub fn cmdTaskRunDev(core: anytype) anyerror!void {
        try runDetectedTask(core, .dev);
    }

    pub fn cmdTaskRunLint(core: anytype) anyerror!void {
        try runDetectedTask(core, .lint);
    }

    pub fn cmdTaskRunFormat(core: anytype) anyerror!void {
        try runDetectedTask(core, .format);
    }

    pub fn cmdTaskRerunLast(core: anytype) anyerror!void {
        const last = core.task_history.last() orelse {
            var aw: std.Io.Writer.Allocating = .init(core.allocator);
            defer aw.deinit();

            try writeNoLastTaskMessage(&aw.writer);
            try core.openVirtualBuffer("[TASK OUTPUT]", aw.written());
            core.mode = .view;
            try core.sendUpdate();
            return;
        };

        try startProjectTask(core, last.root, &last.task);
    }

    pub fn writeNoLastTaskMessage(w: anytype) !void {
        try w.writeAll(
            \\# Task Output
            \\
            \\No project task has been run in this Stem session.
            \\
            \\Run `task.list` to inspect detected tasks, `task.run_build` to run a build task, or `task.run_test` to run a test task.
            \\
        );
    }

    pub fn cmdTaskOutput(core: anytype) anyerror!void {
        var summary = try core.job_manager.snapshot(core.allocator);
        defer summary.deinit(core.allocator);

        var i: usize = summary.jobs.len;
        while (i > 0) {
            i -= 1;
            const job = summary.jobs[i];
            if (!std.mem.startsWith(u8, job.name, "Task: ")) continue;
            if (job.result_output) |output| {
                try core.openVirtualBuffer("[TASK OUTPUT]", output);
                core.mode = .view;
                try core.sendUpdate();
                return;
            }
            var aw: std.Io.Writer.Allocating = .init(core.allocator);
            defer aw.deinit();
            const w = &aw.writer;
            try w.writeAll("# Task Output\n\n");
            if (!job.status.isTerminal()) {
                try w.print("{s} is still running.\n\nRun `task.output` again after it finishes.\n", .{job.name});
            } else {
                try w.print("{s} finished with status `{s}` but did not retain output.\n", .{ job.name, jobStatusLabel(job.status) });
            }
            try core.openVirtualBuffer("[TASK OUTPUT]", aw.written());
            core.mode = .view;
            try core.sendUpdate();
            return;
        }

        var aw: std.Io.Writer.Allocating = .init(core.allocator);
        defer aw.deinit();
        try aw.writer.writeAll(
            \\# Task Output
            \\
            \\No task output available.
            \\
            \\Run `task.run_build`, `task.run_test`, or another `task.run_*` command first.
            \\
        );
        try core.openVirtualBuffer("[TASK OUTPUT]", aw.written());
        core.mode = .view;
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
        const timeline = try telemetry.snapshotTimeline(allocator);
        defer telemetry.freeTimelineSnapshot(allocator, timeline);

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
                \\- Runtime: {s}
                \\- Registered services: {d}
                \\- Shutdown hooks: {d}
                \\- Shutdown started: {s}
                \\- Timeline events retained: {d}
                \\- Vigil event timeline: {s}
                \\- Plugin supervisor: {d} crashes, {d} restarts scheduled
                \\- LSP supervisor: {d} crashes, {d} restarts scheduled
                \\
            , .{
                runtime_health.vigil_major,
                runtime_health.vigil_minor,
                runtime_health.vigil_patch,
                if (runtime_health.telemetry_initialized) "initialized" else "disabled",
                if (runtime_health.runtime_running) "running" else "stopped",
                runtime_health.registered_services,
                runtime_health.shutdown_hooks,
                if (runtime_health.shutdown_started) "yes" else "no",
                timeline.len,
                if (runtime_health.timeline_enabled) "enabled" else "disabled",
                runtime_health.plugin_supervisor.crashes,
                runtime_health.plugin_supervisor.restarts_scheduled,
                runtime_health.lsp_supervisor.crashes,
                runtime_health.lsp_supervisor.restarts_scheduled,
            });
            if (runtime_health.timers) |timer_stats| {
                try w.print(
                    "- Timer service: {d} pending, {d} fired, {d} cancelled\n",
                    .{ timer_stats.pending, timer_stats.fired, timer_stats.cancelled },
                );
            }
            if (runtime_health.alerts.total() > 0) {
                try w.print(
                    "- Alerts: {d} dead-lettered, {d} poison, {d} circuits opened, {d} restarts, {d} crashes\n",
                    .{
                        runtime_health.alerts.dead_lettered,
                        runtime_health.alerts.poison_detected,
                        runtime_health.alerts.circuits_opened,
                        runtime_health.alerts.supervisor_restarts,
                        runtime_health.alerts.component_crashes,
                    },
                );
            } else {
                try w.writeAll("- Alerts: none\n");
            }
            // Multi-instance cluster presence (STEM_CLUSTER), when enabled.
            if (runtime.clusterSnapshot(allocator) catch null) |cluster_opt| {
                var cluster = cluster_opt;
                defer cluster.deinit();
                try w.print(
                    "\n### Cluster ({d} local, {d} remote names)\n\n",
                    .{ cluster.local_names, cluster.cached_remote_names },
                );
                if (cluster.peers.len == 0) {
                    try w.writeAll("- No peers configured\n");
                }
                for (cluster.peers) |peer| {
                    try w.print("- {s}:{d} — {s}, {d} reconnects, {d} consecutive failures\n", .{
                        peer.address,
                        peer.port,
                        if (peer.is_alive) "alive" else "unreachable",
                        peer.reconnects,
                        peer.consecutive_failures,
                    });
                }
            }

            // Dead-letter queues: what the runtime shunted aside instead of
            // delivering, per editor inbox. Empty queues stay silent.
            inline for (.{ .ui, .core }) |service| {
                if (runtime.resolveService(service)) |mailbox| dead_blk: {
                    var dead = mailbox.snapshotDeadLetters(allocator) catch break :dead_blk;
                    defer dead.deinit();
                    if (dead.entries.len > 0) {
                        try w.print("\n### Dead letters ({s})\n\n", .{@tagName(service)});
                        const shown = @min(dead.entries.len, 10);
                        for (dead.entries[0..shown]) |entry| {
                            const payload_len = if (entry.message.payload) |p| p.len else 0;
                            try w.print("- #{d}: {s}, from {s}, {d} bytes{s}\n", .{
                                entry.id,
                                @tagName(entry.reason),
                                entry.message.sender,
                                payload_len,
                                if (entry.poisoned) " (poisoned)" else "",
                            });
                        }
                        if (dead.entries.len > shown) {
                            try w.print("- … {d} more\n", .{dead.entries.len - shown});
                        }
                    }
                }
            }
            if (runtime.debugDump(allocator)) |dump| {
                defer allocator.free(dump);
                try w.print("\n### Vigil runtime dump\n\n```\n{s}```\n", .{dump});
            } else |_| {}
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
            \\- LSP crashes (since startup): {d}
            \\- Supervisor restarts: {d}
            \\
            \\## Per-bus
            \\
            \\
        , .{ snap.bytes_sent, snap.coalesce_events, snap.plugin_crashes, snap.lsp_crashes, snap.supervisor_restarts });

        const per_bus = try telemetry.snapshotPerBus(allocator);
        defer {
            for (per_bus) |b| allocator.free(b.bus_name);
            allocator.free(per_bus);
        }

        if (per_bus.len == 0) {
            try w.writeAll("- _No traffic yet._\n");
        } else {
            try w.writeAll("| Bus | Sent | Dropped (full) | Dropped (backpressure) | Dropped (rate limit) |\n");
            try w.writeAll("|---|---:|---:|---:|---:|\n");
            for (per_bus) |b| {
                try w.print(
                    "| `{s}` | {d} | {d} | {d} | {d} |\n",
                    .{
                        b.bus_name,
                        b.stats.sent,
                        b.stats.dropped_full,
                        b.stats.dropped_backpressure,
                        b.stats.dropped_rate_limited,
                    },
                );
            }
        }

        try w.writeAll(
            \\
            \\## Recent Runtime Events
            \\
        );
        if (timeline.len == 0) {
            try w.writeAll("- _No events yet._\n");
        } else {
            const start = if (timeline.len > 12) timeline.len - 12 else 0;
            for (timeline[start..]) |entry| {
                try w.print(
                    "- `{s}` `{s}`: {s}\n",
                    .{ timelineKindLabel(entry.kind), entry.name, entry.detail },
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
            \\- `dropped (rate limit)`: Vigil token bucket throttled a noisy producer.
            \\- `coalesce events`: renders or ticks superseded by a newer one
            \\  in the same slot. Higher = more redundant work avoided.
            \\
        );

        return aw.toOwnedSlice();
    }

    fn renderControlCenterBuffer(core: anytype) ![]u8 {
        const allocator = core.allocator;
        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        const w = &aw.writer;

        const message_bus = telemetry.snapshot();
        const bus_drops = try busDropTotals(allocator);
        const plugin_health = core.plugin_manager.healthSnapshot();
        var lsp_health = try core.lsp_manager.healthSnapshot(allocator);
        defer lsp_health.deinit(allocator);
        var index_health = try core.search_index.healthSnapshot(allocator);
        defer index_health.deinit(allocator);
        var job_summary = try core.job_manager.snapshot(allocator);
        defer job_summary.deinit(allocator);
        const buffers = bufferCounts(core);
        const diagnostics = try diagnosticCounts(core, allocator);
        const task_count = detectedTaskCount(core, allocator);

        const runtime_label = blk: {
            if (core.runtime_services) |runtime| {
                break :blk if (runtime.healthSnapshot().runtime_running) "running" else "stopped";
            }
            break :blk "not attached";
        };

        const attention = lsp_health.unhealthy_servers +
            diagnostics.errors +
            job_summary.failed +
            (if (index_health.at_capacity) @as(usize, 1) else 0);

        const active = core.buffer_manager.getActive();
        const ws = core.workspace_manager.getBufferWorkspace(active.id);
        const workspace_name = if (ws) |workspace|
            workspace.name
        else
            core.workspace_manager.getActiveWorkspaceName() orelse "No workspace";
        const workspace_root = if (ws) |workspace|
            workspace.root_path
        else
            core.workspace_manager.getActiveRootPath() orelse "-";

        try w.print(
            \\# Stem Control Center
            \\
            \\Status: {s}
            \\Workspace: {s}
            \\Root: {s}
            \\
            \\## Runtime
            \\
            \\- Runtime: {s}
            \\- Commands: {d}
            \\- Buffers: {d} open, {d} file-backed, {d} virtual, {d} dirty, {d} large-file
            \\- Build status: {s}
            \\- Terminal: {s}
            \\
        , .{
            if (attention == 0) "healthy" else "needs attention",
            workspace_name,
            workspace_root,
            runtime_label,
            core.command_registry.commands.count(),
            buffers.total,
            buffers.file_backed,
            buffers.virtual,
            buffers.dirty,
            buffers.large,
            buildStatusLabel(core.build_status),
            if (core.terminal_running) "running" else "idle",
        });

        try w.print(
            \\## Project Brain
            \\
            \\- Indexed paths: {d}/{d}
            \\- Index state: {s}
            \\- Index root: {s}
            \\- At capacity: {s}
            \\
        , .{
            index_health.path_count,
            index_health.max_paths,
            indexStateLabel(index_health.indexing, index_health.fresh),
            index_health.root orelse "-",
            yesNo(index_health.at_capacity),
        });

        try w.print(
            \\## Language Intelligence
            \\
            \\- LSP servers: {d} running, {d} ready, {d} unhealthy, {d} initializing
            \\- Open LSP documents: {d}
            \\- Pending LSP changes: {d}
            \\- Diagnostics: {d} errors, {d} warnings, {d} info, {d} hints
            \\- Lifecycle: {d} crashes, {d} restarts scheduled
            \\
        , .{
            lsp_health.running_servers,
            lsp_health.healthy_servers,
            lsp_health.unhealthy_servers,
            lsp_health.initializing_servers,
            lsp_health.open_documents,
            lsp_health.pending_changes,
            diagnostics.errors,
            diagnostics.warnings,
            diagnostics.info,
            diagnostics.hints,
            lsp_health.lifecycle.crashes,
            lsp_health.lifecycle.restarts_scheduled,
        });

        try w.print(
            \\## Work
            \\
            \\- Jobs: {d} active, {d} total, {d} failed, {d} completed, {d} cancelled
            \\- Detected project tasks: {d}
            \\- Message bus: {d} bytes shipped, {d} coalesced updates
            \\- Drops: {d} full, {d} backpressure, {d} rate-limited
            \\
        , .{
            job_summary.active(),
            job_summary.total,
            job_summary.failed,
            job_summary.completed,
            job_summary.cancelled,
            task_count,
            message_bus.bytes_sent,
            message_bus.coalesce_events,
            bus_drops.full,
            bus_drops.backpressure,
            bus_drops.rate_limited,
        });

        try w.print(
            \\## Plugins
            \\
            \\- Loaded: {d} ({d} wasm, {d} exec)
            \\- Vigil broker: {s}
            \\- Lifecycle supervisor: {s}
            \\- Pending restarts: {d}
            \\- Crashes: {d}
            \\
        , .{
            plugin_health.loaded_plugins,
            plugin_health.wasm_plugins,
            plugin_health.process_plugins,
            if (plugin_health.vigil_broker_attached) "attached" else "missing",
            if (plugin_health.vigil_supervisor_attached) "attached" else "missing",
            plugin_health.pending_restarts,
            plugin_health.lifecycle.crashes,
        });

        var recommendations = std.ArrayListUnmanaged(runtime_watchdog.HealingRecommendation).empty;
        defer recommendations.deinit(allocator);
        try runtime_watchdog.appendRecommendations(.{
            .lsp_unhealthy_servers = lsp_health.unhealthy_servers,
            .plugin_crashes = plugin_health.lifecycle.crashes,
            .plugin_pending_restarts = plugin_health.pending_restarts,
            .bus_drops_full = bus_drops.full,
            .bus_drops_backpressure = bus_drops.backpressure,
            .bus_drops_rate_limited = bus_drops.rate_limited,
            .failed_jobs = job_summary.failed,
            .index_at_capacity = index_health.at_capacity,
            .has_last_task = core.task_history.last() != null,
        }, &recommendations, allocator);
        if (diagnostics.errors > 0) {
            try recommendations.append(allocator, .{
                .severity = .warning,
                .title = "Diagnostics",
                .detail = "LSP diagnostics contain errors in the current workspace.",
                .command = "lsp.diagnostics",
            });
        }
        try writeHealingRecommendations(w, recommendations.items);

        try w.writeAll(
            \\
            \\## Jump To
            \\
            \\- `stem.heal`: focused runtime recovery recommendations
            \\- `stats.show`: raw Vigil/message-bus telemetry
            \\- `project.brain`: workspace index, languages, and LSP coverage
            \\- `task.list`: detected project build/test/run commands
            \\- `task.run_build` / `task.run_test` / `task.run`: run preferred project tasks as jobs
            \\- `lsp.status`: per-language LSP server state
            \\- `plugin.inspect`: plugin manifests, permissions, and live state
            \\- `job.list`: active background jobs
            \\- `view.logs`: in-session logs
            \\
        );

        return aw.toOwnedSlice();
    }

    fn renderHealingBuffer(core: anytype) ![]u8 {
        const allocator = core.allocator;
        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        const w = &aw.writer;

        const input = try buildHealingInput(core, allocator);
        var recommendations = std.ArrayListUnmanaged(runtime_watchdog.HealingRecommendation).empty;
        defer recommendations.deinit(allocator);
        try runtime_watchdog.appendRecommendations(input, &recommendations, allocator);

        const timeline = try telemetry.snapshotTimeline(allocator);
        defer telemetry.freeTimelineSnapshot(allocator, timeline);

        try w.writeAll(
            \\# Stem Heal
            \\
            \\Vigil-backed recovery guidance for runtime health issues.
            \\
        );
        try writeHealingRecommendations(w, recommendations.items);

        try w.print(
            \\
            \\## Runtime Context
            \\
            \\- LSP unhealthy servers: {d}
            \\- Plugin crashes: {d}
            \\- Plugin pending restarts: {d}
            \\- Message bus drops: {d} full, {d} backpressure, {d} rate-limited
            \\- Failed jobs: {d}
            \\- Project index at capacity: {s}
            \\
        , .{
            input.lsp_unhealthy_servers,
            input.plugin_crashes,
            input.plugin_pending_restarts,
            input.bus_drops_full,
            input.bus_drops_backpressure,
            input.bus_drops_rate_limited,
            input.failed_jobs,
            yesNo(input.index_at_capacity),
        });

        try w.writeAll(
            \\
            \\## Recent Runtime Events
            \\
        );
        if (timeline.len == 0) {
            try w.writeAll("- _No events yet._\n");
        } else {
            const start = if (timeline.len > 8) timeline.len - 8 else 0;
            for (timeline[start..]) |entry| {
                try w.print("- `{s}` `{s}`: {s}\n", .{ timelineKindLabel(entry.kind), entry.name, entry.detail });
            }
        }

        return aw.toOwnedSlice();
    }

    pub fn writeHealingRecommendations(
        w: anytype,
        recommendations: []const runtime_watchdog.HealingRecommendation,
    ) !void {
        try w.writeAll(
            \\## Recommended Actions
            \\
        );
        if (recommendations.len == 0) {
            try w.writeAll("- No urgent runtime issues detected.\n");
            return;
        }

        try w.writeAll("| Severity | Issue | Action | Details |\n");
        try w.writeAll("|---|---|---|---|\n");
        for (recommendations) |rec| {
            try w.print("| {s} | {s} | `{s}`", .{
                healingSeverityLabel(rec.severity),
                rec.title,
                rec.command,
            });
            if (rec.alternate_command) |alternate| {
                try w.print(" / `{s}`", .{alternate});
            }
            try w.print(" | {s} |\n", .{rec.detail});
        }
    }

    fn renderProjectBrainBuffer(core: anytype) ![]u8 {
        const allocator = core.allocator;
        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        const w = &aw.writer;

        var index_health = try core.search_index.healthSnapshot(allocator);
        defer index_health.deinit(allocator);
        var lsp_health = try core.lsp_manager.healthSnapshot(allocator);
        defer lsp_health.deinit(allocator);
        const diagnostics = try diagnosticCounts(core, allocator);
        const active = core.buffer_manager.getActive();
        const ws = core.workspace_manager.getBufferWorkspace(active.id);

        try w.writeAll("# Project Brain\n\n");
        if (ws) |workspace| {
            try w.print(
                \\## Workspace
                \\
                \\- Name: {s}
                \\- Root: {s}
                \\- build.zig: {s}
                \\- build.zig.zon: {s}
                \\
            , .{
                workspace.name,
                workspace.root_path,
                workspace.build_zig_path,
                yesNo(workspace.has_zon),
            });
        } else {
            try w.writeAll(
                \\## Workspace
                \\
                \\- No Zig workspace is attached to the active buffer.
                \\
            );
        }

        try w.print(
            \\## Index
            \\
            \\- State: {s}
            \\- Root: {s}
            \\- Paths: {d}/{d}
            \\- Capacity reached: {s}
            \\
        , .{
            indexStateLabel(index_health.indexing, index_health.fresh),
            index_health.root orelse "-",
            index_health.path_count,
            index_health.max_paths,
            yesNo(index_health.at_capacity),
        });

        try writeOpenLanguageTable(core, w);

        try w.print(
            \\
            \\## LSP Coverage
            \\
            \\- Servers: {d} running, {d} ready, {d} unhealthy, {d} initializing
            \\- Open documents: {d}
            \\- Pending changes: {d}
            \\- Diagnostics: {d} errors, {d} warnings, {d} info, {d} hints
            \\
        , .{
            lsp_health.running_servers,
            lsp_health.healthy_servers,
            lsp_health.unhealthy_servers,
            lsp_health.initializing_servers,
            lsp_health.open_documents,
            lsp_health.pending_changes,
            diagnostics.errors,
            diagnostics.warnings,
            diagnostics.info,
            diagnostics.hints,
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

        try writeProjectTaskTable(core, allocator, w);

        try w.writeAll(
            \\
            \\## Useful Commands
            \\
            \\- `lsp.prewarm`: start servers for detected workspace languages
            \\- `task.list`: show detected project tasks
            \\- `task.run_build` / `task.run_test` / `task.run`: run preferred detected tasks
            \\- `task.output`: reopen the latest retained task output
            \\- `lsp.workspace_symbols`: search symbols across the workspace
            \\- `search.find_in_buffer`: search within the active buffer
            \\- `stats.show`: inspect runtime/message bus pressure
            \\
        );

        return aw.toOwnedSlice();
    }

    fn renderProjectTasksBuffer(core: anytype) ![]u8 {
        const allocator = core.allocator;
        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        const w = &aw.writer;

        const root = projectTaskRoot(core);
        var tasks = try project_tasks.detectProjectTasks(allocator, core.io, root);
        defer tasks.deinit(allocator);

        try w.print(
            \\# Project Tasks
            \\
            \\Root: {s}
            \\Detected: {d}
            \\
        , .{ root, tasks.tasks.len });

        if (tasks.tasks.len == 0) {
            try w.writeAll(
                \\No project tasks detected.
                \\
                \\Stem currently detects tasks from `build.zig`, `Cargo.toml`, `go.mod`,
                \\Python project markers, `package.json` scripts, and common Make targets.
                \\
            );
            return aw.toOwnedSlice();
        }

        try w.writeAll("| ID | Kind | Command | Source |\n");
        try w.writeAll("|---|---|---|---|\n");
        for (tasks.tasks) |task| {
            try w.print("| `{s}` | {s} | `{s}` | {s} |\n", .{
                task.id,
                task.kind.label(),
                task.command,
                task.source,
            });
        }

        try w.writeAll(
            \\
            \\## Notes
            \\
            \\- Commands are shown exactly as Stem would run them from the root above.
            \\- `task.run_build`: run the preferred build task in the background.
            \\- `task.run_test`: run the preferred test task in the background.
            \\- `task.run`: run the preferred run/start task in the background.
            \\- `task.run_dev` / `task.run_lint` / `task.run_format`: run matching project tasks.
            \\- `task.output`: reopen the most recent retained task output.
            \\
        );

        return aw.toOwnedSlice();
    }

    const TaskRunContext = struct {
        allocator: std.mem.Allocator,
        environ_block: std.process.Environ.Block,
        root: []const u8,
        task: project_tasks.ProjectTask,

        fn deinit(self: *TaskRunContext) void {
            self.allocator.free(self.root);
            self.task.deinit(self.allocator);
        }
    };

    fn lspStateLabel(running: bool, healthy: bool, initialized: bool) []const u8 {
        if (!running) return "stopped";
        if (!healthy) return "unhealthy";
        if (!initialized) return "initializing";
        return "ready";
    }

    fn timelineKindLabel(kind: telemetry.TimelineKind) []const u8 {
        return switch (kind) {
            .runtime => "runtime",
            .shutdown => "shutdown",
            .message => "message",
            .flow_control => "flow",
            .plugin => "plugin",
            .lsp => "lsp",
            .supervisor => "supervisor",
        };
    }

    const BufferCounts = struct {
        total: usize = 0,
        file_backed: usize = 0,
        virtual: usize = 0,
        dirty: usize = 0,
        large: usize = 0,
    };

    const DiagnosticCounts = struct {
        errors: usize = 0,
        warnings: usize = 0,
        info: usize = 0,
        hints: usize = 0,
    };

    const BusDropTotals = struct {
        full: u64 = 0,
        backpressure: u64 = 0,
        rate_limited: u64 = 0,
    };

    fn buildHealingInput(core: anytype, allocator: std.mem.Allocator) !runtime_watchdog.HealthInput {
        const plugin_health = core.plugin_manager.healthSnapshot();
        var lsp_health = try core.lsp_manager.healthSnapshot(allocator);
        defer lsp_health.deinit(allocator);
        var index_health = try core.search_index.healthSnapshot(allocator);
        defer index_health.deinit(allocator);
        var job_summary = try core.job_manager.snapshot(allocator);
        defer job_summary.deinit(allocator);
        const bus_drops = try busDropTotals(allocator);

        return .{
            .lsp_unhealthy_servers = lsp_health.unhealthy_servers,
            .plugin_crashes = plugin_health.lifecycle.crashes,
            .plugin_pending_restarts = plugin_health.pending_restarts,
            .bus_drops_full = bus_drops.full,
            .bus_drops_backpressure = bus_drops.backpressure,
            .bus_drops_rate_limited = bus_drops.rate_limited,
            .failed_jobs = job_summary.failed,
            .index_at_capacity = index_health.at_capacity,
            .has_last_task = core.task_history.last() != null,
        };
    }

    fn healingSeverityLabel(severity: runtime_watchdog.Severity) []const u8 {
        return switch (severity) {
            .info => "info",
            .warning => "warning",
            .err => "error",
        };
    }

    fn bufferCounts(core: anytype) BufferCounts {
        var counts = BufferCounts{};
        counts.total = core.buffer_manager.buffers.items.len;
        for (core.buffer_manager.buffers.items) |buf| {
            if (buf.file_path == null) {
                counts.virtual += 1;
            } else {
                counts.file_backed += 1;
            }
            if (buf.state.modified) counts.dirty += 1;
            if (buf.is_large) counts.large += 1;
        }
        return counts;
    }

    fn diagnosticCounts(core: anytype, allocator: std.mem.Allocator) !DiagnosticCounts {
        const diagnostics = core.lsp_manager.getDiagnostics(allocator) catch return .{};
        defer LSPManager.freeDiagnostics(allocator, diagnostics);

        var counts = DiagnosticCounts{};
        for (diagnostics) |diag| {
            switch (diag.severity) {
                .err => counts.errors += 1,
                .warning => counts.warnings += 1,
                .info => counts.info += 1,
                .hint => counts.hints += 1,
            }
        }
        return counts;
    }

    fn busDropTotals(allocator: std.mem.Allocator) !BusDropTotals {
        const per_bus = try telemetry.snapshotPerBus(allocator);
        defer {
            for (per_bus) |b| allocator.free(b.bus_name);
            allocator.free(per_bus);
        }

        var totals = BusDropTotals{};
        for (per_bus) |b| {
            totals.full += b.stats.dropped_full;
            totals.backpressure += b.stats.dropped_backpressure;
            totals.rate_limited += b.stats.dropped_rate_limited;
        }
        return totals;
    }

    fn projectTaskRoot(core: anytype) []const u8 {
        const active = core.buffer_manager.getActive();
        if (core.workspace_manager.getBufferWorkspace(active.id)) |ws| return ws.root_path;
        if (core.workspace_manager.getActiveRootPath()) |root| return root;
        return core.file_manager.cwd;
    }

    fn detectedTaskCount(core: anytype, allocator: std.mem.Allocator) usize {
        var tasks = project_tasks.detectProjectTasks(allocator, core.io, projectTaskRoot(core)) catch return 0;
        defer tasks.deinit(allocator);
        return tasks.tasks.len;
    }

    fn runDetectedTask(core: anytype, kind: project_tasks.TaskKind) !void {
        const allocator = core.allocator;
        const root = projectTaskRoot(core);
        var tasks = try project_tasks.detectProjectTasks(allocator, core.io, root);
        defer tasks.deinit(allocator);

        const task = tasks.findFirstByKind(kind) orelse {
            const body = try std.fmt.allocPrint(allocator,
                \\# Task Output
                \\
                \\No {s} task was detected for:
                \\
                \\{s}
                \\
                \\Run `task.list` to inspect detected tasks.
                \\
            , .{ kind.label(), root });
            defer allocator.free(body);
            try core.openVirtualBuffer("[TASK OUTPUT]", body);
            core.mode = .view;
            try core.sendUpdate();
            return;
        };

        try startProjectTask(core, root, task);
    }

    fn startProjectTask(core: anytype, root: []const u8, task: *const project_tasks.ProjectTask) !void {
        const allocator = core.allocator;
        const job_name = try std.fmt.allocPrint(allocator, "Task: {s}", .{task.label});
        defer allocator.free(job_name);

        const ctx = try makeTaskRunContext(allocator, core.environ_block, root, task);
        const id = core.job_manager.spawn(job_name, runProjectTaskJob, ctx) catch |err| {
            ctx.deinit();
            allocator.destroy(ctx);
            return err;
        };
        core.task_history.record(root, task.*) catch {};

        const body = try std.fmt.allocPrint(allocator,
            \\# Task Output
            \\
            \\Started background task #{d}.
            \\
            \\- Task: {s}
            \\- ID: `{s}`
            \\- Command: `{s}`
            \\- Root: {s}
            \\
            \\Open `job.list` to monitor status, `task.output` to reopen the retained output after completion, or `task.rerun_last` to launch it again.
            \\
        , .{ id, task.label, task.id, task.command, root });
        defer allocator.free(body);

        try core.openVirtualBuffer("[TASK OUTPUT]", body);
        core.mode = .view;
        try core.sendUpdate();
    }

    fn makeTaskRunContext(
        allocator: std.mem.Allocator,
        environ_block: std.process.Environ.Block,
        root: []const u8,
        task: *const project_tasks.ProjectTask,
    ) !*TaskRunContext {
        const ctx = try allocator.create(TaskRunContext);
        errdefer allocator.destroy(ctx);

        const root_copy = try allocator.dupe(u8, root);
        errdefer allocator.free(root_copy);
        const task_id = try allocator.dupe(u8, task.id);
        errdefer allocator.free(task_id);
        const label = try allocator.dupe(u8, task.label);
        errdefer allocator.free(label);
        const command = try allocator.dupe(u8, task.command);
        errdefer allocator.free(command);
        const source = try allocator.dupe(u8, task.source);
        errdefer allocator.free(source);

        ctx.* = .{
            .allocator = allocator,
            .environ_block = environ_block,
            .root = root_copy,
            .task = .{
                .id = task_id,
                .label = label,
                .command = command,
                .kind = task.kind,
                .source = source,
                .priority = task.priority,
            },
        };
        return ctx;
    }

    fn runProjectTaskJob(ctx_ptr: *anyopaque, progress: *JobProgress, allocator: std.mem.Allocator) anyerror![]const u8 {
        const ctx: *TaskRunContext = @ptrCast(@alignCast(ctx_ptr));
        defer {
            ctx.deinit();
            ctx.allocator.destroy(ctx);
        }

        progress.update(5, "Starting project task...");
        if (progress.isCancelled()) return error.Cancelled;

        var threaded = std.Io.Threaded.init(ctx.allocator, .{
            .environ = .{ .block = ctx.environ_block },
        });
        defer threaded.deinit();

        var result = try project_tasks.runTaskSync(allocator, threaded.io(), ctx.task, ctx.root);
        defer result.deinit(allocator);

        progress.update(100, null);
        if (!result.success) progress.markFailed();
        return try project_tasks.formatRunResult(allocator, &result);
    }

    fn writeProjectTaskTable(core: anytype, allocator: std.mem.Allocator, w: anytype) !void {
        var tasks = try project_tasks.detectProjectTasks(allocator, core.io, projectTaskRoot(core));
        defer tasks.deinit(allocator);

        try w.writeAll(
            \\
            \\## Project Tasks
            \\
        );
        if (tasks.tasks.len == 0) {
            try w.writeAll("- No project tasks detected.\n");
            return;
        }

        try w.writeAll("| ID | Kind | Command | Source |\n");
        try w.writeAll("|---|---|---|---|\n");
        for (tasks.tasks) |task| {
            try w.print("| `{s}` | {s} | `{s}` | {s} |\n", .{
                task.id,
                task.kind.label(),
                task.command,
                task.source,
            });
        }
    }

    fn writeOpenLanguageTable(core: anytype, w: anytype) !void {
        var langs = std.StringHashMapUnmanaged(usize).empty;
        defer langs.deinit(core.allocator);

        for (core.buffer_manager.buffers.items) |buf| {
            const path = buf.file_path orelse continue;
            const lang = LSPManager.getLangFromPath(path) orelse continue;
            const gop = try langs.getOrPut(core.allocator, lang);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }

        try w.writeAll(
            \\
            \\## Open Languages
            \\
        );
        if (langs.count() == 0) {
            try w.writeAll("- No LSP-backed file types are open.\n");
            return;
        }

        try w.writeAll("| Language | Open buffers |\n");
        try w.writeAll("|---|---:|\n");
        var it = langs.iterator();
        while (it.next()) |entry| {
            try w.print("| `{s}` | {d} |\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }

    fn yesNo(value: bool) []const u8 {
        return if (value) "yes" else "no";
    }

    fn indexStateLabel(indexing: bool, fresh: bool) []const u8 {
        if (indexing) return "indexing";
        if (fresh) return "fresh";
        return "warming";
    }

    fn buildStatusLabel(status: anytype) []const u8 {
        return switch (status) {
            .idle => "idle",
            .building => "building",
            .success => "success",
            .failed => "failed",
        };
    }

    pub fn cmdJobList(core: anytype) anyerror!void {
        var summary = try core.job_manager.snapshot(core.allocator);
        defer summary.deinit(core.allocator);

        var text = std.ArrayListUnmanaged(u8).empty;
        defer text.deinit(core.allocator);

        try text.appendSlice(core.allocator, "# Background Jobs\n\n");
        const summary_line = try std.fmt.allocPrint(
            core.allocator,
            "- Active: {d}\n- Total retained: {d}\n- Completed: {d}\n- Failed: {d}\n- Cancelled: {d}\n\n",
            .{
                summary.active(),
                summary.total,
                summary.completed,
                summary.failed,
                summary.cancelled,
            },
        );
        defer core.allocator.free(summary_line);
        try text.appendSlice(core.allocator, summary_line);

        if (summary.jobs.len == 0) {
            try text.appendSlice(core.allocator, "No jobs have run in this session.\n");
        } else {
            try text.appendSlice(core.allocator, "| ID | Status | Progress | Job |\n");
            try text.appendSlice(core.allocator, "|---:|---|---:|---|\n");
            for (summary.jobs) |job| {
                const line = try std.fmt.allocPrint(core.allocator, "| {d} | {s} | {d}% | {s} |\n", .{
                    job.id,
                    jobStatusLabel(job.status),
                    job.progress,
                    job.name,
                });
                defer core.allocator.free(line);
                try text.appendSlice(core.allocator, line);
            }
        }

        try core.openVirtualBuffer("[Jobs]", text.items);
        core.mode = .view;
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

    fn jobStatusLabel(status: @import("../jobs.zig").JobStatus) []const u8 {
        return switch (status) {
            .pending => "pending",
            .running => "running",
            .completed => "completed",
            .failed => "failed",
            .cancelled => "cancelled",
        };
    }
};

test "task rerun no-history message suggests task commands" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try SystemCommands.writeNoLastTaskMessage(&aw.writer);
    const text = aw.written();

    try std.testing.expect(std.mem.indexOf(u8, text, "No project task has been run") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "task.list") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "task.run_test") != null);
}

test "healing recommendations render command names" {
    var list = std.ArrayListUnmanaged(runtime_watchdog.HealingRecommendation).empty;
    defer list.deinit(std.testing.allocator);
    try runtime_watchdog.appendRecommendations(.{
        .lsp_unhealthy_servers = 1,
        .failed_jobs = 1,
        .has_last_task = true,
    }, &list, std.testing.allocator);

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try SystemCommands.writeHealingRecommendations(&aw.writer, list.items);
    const text = aw.written();

    try std.testing.expect(std.mem.indexOf(u8, text, "lsp.status") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "job.list") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "task.rerun_last") != null);
}
