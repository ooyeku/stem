const std = @import("std");
const build_jobs = @import("../build_jobs.zig");
const decorations = @import("../decorations.zig");
const DecorationKind = decorations.DecorationKind;
const Range = decorations.Range;

const log = std.log.scoped(.BuildCommands);

pub const BuildCommands = struct {
    pub fn cmdBuildRun(core: anytype) anyerror!void {
        try runBuildCommand(core, .run);
    }

    pub fn cmdBuildTest(core: anytype) anyerror!void {
        try runBuildCommand(core, .@"test");
    }

    pub fn cmdBuildOnly(core: anytype) anyerror!void {
        try runBuildCommand(core, .build_only);
    }

    pub fn cmdBuildOutput(core: anytype) anyerror!void {
        for (core.buffer_manager.buffers.items, 0..) |buf, i| {
            if (std.mem.eql(u8, buf.name, "[Zig Build]") or
                std.mem.eql(u8, buf.name, "[Zig Test]") or
                std.mem.eql(u8, buf.name, "[Zig Run]"))
            {
                core.buffer_manager.switchTo(i);
                core.mode = .view;
                try core.sendUpdate();
                return;
            }
        }

        try core.buffer_manager.openVirtual("[Zig Build]",
            \\No build output available.
            \\
            \\Use Command Palette (Space+P) and type "zig":
            \\- Zig: Build  - Run 'zig build'
            \\- Zig: Test   - Run 'zig build test'
        );
        try core.sendUpdate();
    }

    fn runBuildCommand(core: anytype, command: build_jobs.BuildCommand) !void {
        const buffer = core.buffer_manager.getActive();
        var workspace = core.workspace_manager.getBufferWorkspace(buffer.id);

        if (workspace == null) {
            if (buffer.file_path) |path| {
                if (try core.workspace_manager.detectWorkspace(path)) |ws| {
                    try core.workspace_manager.buffer_workspaces.put(buffer.id, ws);
                    workspace = core.workspace_manager.getBufferWorkspace(buffer.id);
                }
            }
        }

        const ws = workspace orelse {
            try core.buffer_manager.openVirtual("[Build]",
                \\╔══════════════════════════════════════════════════════════════╗
                \\║  ✗ NOT IN A ZIG PROJECT                                      ║
                \\╚══════════════════════════════════════════════════════════════╝
                \\
                \\Could not find build.zig in any parent directory.
                \\Make sure you are editing a file inside a Zig project.
            );
            return;
        };

        core.build_status = .building;

        const buffer_name: []const u8 = switch (command) {
            .@"test" => "[Zig Test]",
            .build_only => "[Zig Build]",
            .run => "[Zig Run]",
        };

        const action_text: []const u8 = switch (command) {
            .@"test" => "TESTING",
            .build_only => "BUILDING",
            .run => "RUNNING",
        };

        const header = try std.fmt.allocPrint(core.allocator,
            \\╔══════════════════════════════════════════════════════════════╗
            \\║  ⟳ {s}: {s}
            \\╚══════════════════════════════════════════════════════════════╝
            \\
            \\Workspace: {s}
            \\Command: {s}
            \\
            \\Please wait...
        , .{ action_text, ws.name, ws.root_path, command.displayName() });
        defer core.allocator.free(header);

        try core.buffer_manager.openVirtual(buffer_name, header);
        try core.sendUpdate();

        var output = build_jobs.runBuild(ws.root_path, command, core.allocator, core.io) catch |err| {
            core.build_status = .failed;
            const err_msg = try std.fmt.allocPrint(core.allocator,
                \\╔══════════════════════════════════════════════════════════════╗
                \\║  ✗ FAILED TO START                                           ║
                \\╚══════════════════════════════════════════════════════════════╝
                \\
                \\Error: {}
            , .{err});
            defer core.allocator.free(err_msg);
            try closeAndReopenBuffer(core, buffer_name, err_msg);
            return;
        };
        defer output.deinit(core.allocator);

        core.build_status = if (output.success) .success else .failed;

        const formatted = try formatBuildResult(core.allocator, &output, command);
        defer core.allocator.free(formatted);

        try closeAndReopenBuffer(core, buffer_name, formatted);

        core.decoration_manager.removeBySource("build");
        for (output.diagnostics) |diag| {
            for (core.buffer_manager.buffers.items) |buf| {
                if (buf.file_path) |path| {
                    if (std.mem.endsWith(u8, path, diag.file_path) or
                        std.mem.eql(u8, path, diag.file_path))
                    {
                        const kind: DecorationKind = switch (diag.kind) {
                            .@"error" => .build_error,
                            .warning => .build_warning,
                            .note => .build_note,
                        };

                        // best-effort: dropping a single build decoration on OOM only affects one warning marker
                        _ = core.decoration_manager.add(
                            Range.singleLine(diag.line - 1, 0, 1000),
                            kind,
                            200,
                            diag.message,
                            "build",
                        ) catch {};
                        break;
                    }
                }
            }
        }

        core.mode = .view;
        try core.sendUpdate();
    }

    fn closeAndReopenBuffer(core: anytype, name: []const u8, content: []const u8) !void {
        for (core.buffer_manager.buffers.items, 0..) |buf, i| {
            if (std.mem.eql(u8, buf.name, name)) {
                core.buffer_manager.switchTo(i);
                const closed = core.buffer_manager.closeActive();
                if (closed) {
                    if (core.split_manager) |*sm| {
                        sm.onBufferClosed(i, core.buffer_manager.buffers.items.len);
                    }
                }
                break;
            }
        }
        try core.buffer_manager.openVirtual(name, content);
    }

    fn formatBuildResult(allocator: std.mem.Allocator, output: *const build_jobs.BuildOutput, command: build_jobs.BuildCommand) ![]u8 {
        var result: std.Io.Writer.Allocating = .init(allocator);
        errdefer result.deinit();

        const writer = &result.writer;

        if (output.success) {
            switch (command) {
                .@"test" => {
                    try writer.writeAll("╔══════════════════════════════════════════════════════════════╗\n");
                    try writer.writeAll("║  ✓ ALL TESTS PASSED                                          ║\n");
                    try writer.writeAll("╚══════════════════════════════════════════════════════════════╝\n\n");
                },
                .build_only => {
                    try writer.writeAll("╔══════════════════════════════════════════════════════════════╗\n");
                    try writer.writeAll("║  ✓ BUILD SUCCESSFUL                                          ║\n");
                    try writer.writeAll("╚══════════════════════════════════════════════════════════════╝\n\n");
                },
                .run => {
                    try writer.writeAll("╔══════════════════════════════════════════════════════════════╗\n");
                    try writer.writeAll("║  ✓ RUN COMPLETED                                             ║\n");
                    try writer.writeAll("╚══════════════════════════════════════════════════════════════╝\n\n");
                },
            }
        } else {
            switch (command) {
                .@"test" => {
                    try writer.writeAll("╔══════════════════════════════════════════════════════════════╗\n");
                    try writer.writeAll("║  ✗ TESTS FAILED                                              ║\n");
                    try writer.writeAll("╚══════════════════════════════════════════════════════════════╝\n\n");
                },
                .build_only => {
                    try writer.writeAll("╔══════════════════════════════════════════════════════════════╗\n");
                    try writer.writeAll("║  ✗ BUILD FAILED                                              ║\n");
                    try writer.writeAll("╚══════════════════════════════════════════════════════════════╝\n\n");
                },
                .run => {
                    try writer.writeAll("╔══════════════════════════════════════════════════════════════╗\n");
                    try writer.writeAll("║  ✗ RUN FAILED                                                ║\n");
                    try writer.writeAll("╚══════════════════════════════════════════════════════════════╝\n\n");
                },
            }
        }

        try writer.print("Duration: {d}ms\n\n", .{output.duration_ms});

        if (output.diagnostics.len > 0) {
            var error_count: usize = 0;
            var warning_count: usize = 0;
            for (output.diagnostics) |diag| {
                switch (diag.kind) {
                    .@"error" => error_count += 1,
                    .warning => warning_count += 1,
                    .note => {},
                }
            }
            try writer.print("Diagnostics: {d} error(s), {d} warning(s)\n", .{ error_count, warning_count });
            try writer.writeAll("─────────────────────────────────────────────────────────────────\n\n");

            for (output.diagnostics) |diag| {
                const symbol = switch (diag.kind) {
                    .@"error" => "✗",
                    .warning => "⚠",
                    .note => "ℹ",
                };
                try writer.print("{s} {s}:{d}:{d}: {s}\n  {s}\n\n", .{
                    symbol,
                    diag.file_path,
                    diag.line,
                    diag.column,
                    diag.kind.toString(),
                    diag.message,
                });
            }
        }

        if (output.stdout.len > 0) {
            try writer.writeAll("─────────────────── Output ───────────────────────────────────────\n");
            try writer.writeAll(output.stdout);
            if (!std.mem.endsWith(u8, output.stdout, "\n")) {
                try writer.writeByte('\n');
            }
        }

        if (output.stderr.len > 0) {
            if (!output.success) {
                try writer.writeAll("─────────────────── Errors ───────────────────────────────────────\n");
            } else {
                try writer.writeAll("─────────────────── Stderr ───────────────────────────────────────\n");
            }
            try writer.writeAll(output.stderr);
            if (!std.mem.endsWith(u8, output.stderr, "\n")) {
                try writer.writeByte('\n');
            }
        }

        return result.toOwnedSlice();
    }
};
