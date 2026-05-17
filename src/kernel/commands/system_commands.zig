//! Commands that interact with cross-cutting subsystems (logs, jobs, plugins).
//! Each takes `core: anytype` to avoid circular imports with kernel/core.zig.

const std = @import("std");
const protocol = @import("../protocol.zig");
const logger_service = @import("../../services/logger.zig");

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

        const plugin_count = core.plugin_manager.plugins.count();
        const count_line = try std.fmt.allocPrint(core.allocator, "- `Loaded Plugins`: {d}\n\n", .{plugin_count});
        defer core.allocator.free(count_line);
        try text.appendSlice(core.allocator, count_line);

        try text.appendSlice(core.allocator, "## Installed Plugins\n\n");

        if (plugin_count == 0) {
            try text.appendSlice(core.allocator, "- No plugins loaded.\n");
            try text.appendSlice(core.allocator, "- Plugins are loaded from: `~/.stem/plugins/`\n");
        } else {
            var it = core.plugin_manager.plugins.valueIterator();
            var idx: usize = 1;
            while (it.next()) |plugin_ptr| {
                const plugin = plugin_ptr.*;
                const p_header = try std.fmt.allocPrint(core.allocator, "### {d}. {s}\n", .{ idx, plugin.id });
                defer core.allocator.free(p_header);
                try text.appendSlice(core.allocator, p_header);

                const line2 = try std.fmt.allocPrint(core.allocator, "- `Path`: {s}\n", .{plugin.path});
                defer core.allocator.free(line2);
                try text.appendSlice(core.allocator, line2);

                const state_str = @tagName(plugin.state);
                const line3 = try std.fmt.allocPrint(core.allocator, "- `Status`: {s}\n\n", .{state_str});
                defer core.allocator.free(line3);
                try text.appendSlice(core.allocator, line3);

                idx += 1;
            }
        }

        try text.appendSlice(core.allocator,
            \\## Instructions
            \\
            \\- `Install`: Copy .dylib/.so/.dll files to `~/.stem/plugins/`
            \\- `Restart`: Restart stem to load new plugins
            \\- `q`: Close this buffer
            \\
        );

        try core.openVirtualBuffer("[PLUGINS]", text.items);
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
