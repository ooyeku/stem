const std = @import("std");
const JobProgress = @import("jobs.zig").JobProgress;

pub const Diagnostic = struct {
    file_path: []const u8,
    line: u32,
    column: u32,
    kind: DiagnosticKind,
    message: []const u8,

    pub const DiagnosticKind = enum {
        @"error",
        warning,
        note,

        pub fn toString(self: DiagnosticKind) []const u8 {
            return switch (self) {
                .@"error" => "error",
                .warning => "warning",
                .note => "note",
            };
        }
    };

    pub fn deinit(self: *Diagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.file_path);
        allocator.free(self.message);
    }
};

pub const BuildOutput = struct {
    success: bool,
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u8,
    diagnostics: []Diagnostic,
    duration_ms: i64,

    pub fn deinit(self: *BuildOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        for (self.diagnostics) |*diag| {
            diag.deinit(allocator);
        }
        allocator.free(self.diagnostics);
    }
};

pub const BuildCommand = enum {
    run,
    @"test",
    build_only,

    pub fn toArgs(self: BuildCommand) []const []const u8 {
        return switch (self) {
            .run => &.{ "zig", "build", "run" },
            .@"test" => &.{ "zig", "build", "test" },
            .build_only => &.{ "zig", "build" },
        };
    }

    pub fn displayName(self: BuildCommand) []const u8 {
        return switch (self) {
            .run => "zig build run",
            .@"test" => "zig build test",
            .build_only => "zig build",
        };
    }
};

pub const BuildJobContext = struct {
    workspace_root: []const u8,
    command: BuildCommand,
    allocator: std.mem.Allocator,
    io: std.Io,
};

pub fn parseZigDiagnostics(output: []const u8, allocator: std.mem.Allocator) ![]Diagnostic {
    var diagnostics = std.ArrayListUnmanaged(Diagnostic).empty;
    errdefer {
        for (diagnostics.items) |*d| d.deinit(allocator);
        diagnostics.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (parseDiagnosticLine(line, allocator)) |diag| {
            try diagnostics.append(allocator, diag);
        }
    }

    return diagnostics.toOwnedSlice(allocator);
}

fn parseDiagnosticLine(line: []const u8, allocator: std.mem.Allocator) ?Diagnostic {
    var colon_count: usize = 0;
    var colon_positions: [4]usize = undefined;

    for (line, 0..) |c, i| {
        if (c == ':') {
            if (colon_count < 4) {
                colon_positions[colon_count] = i;
                colon_count += 1;
            }
        }
    }

    if (colon_count < 4) return null;

    const file_path = line[0..colon_positions[0]];
    const line_str = line[colon_positions[0] + 1 .. colon_positions[1]];
    const col_str = line[colon_positions[1] + 1 .. colon_positions[2]];
    const rest = if (colon_positions[2] + 2 < line.len)
        std.mem.trimStart(u8, line[colon_positions[2] + 2 ..], " ")
    else
        return null;

    const line_num = std.fmt.parseInt(u32, line_str, 10) catch return null;
    const col_num = std.fmt.parseInt(u32, col_str, 10) catch return null;

    const kind: Diagnostic.DiagnosticKind = blk: {
        if (std.mem.startsWith(u8, rest, "error:")) break :blk .@"error";
        if (std.mem.startsWith(u8, rest, "warning:")) break :blk .warning;
        if (std.mem.startsWith(u8, rest, "note:")) break :blk .note;
        return null;
    };

    const kind_str = kind.toString();
    const message_start = kind_str.len + 2;
    const message = if (message_start < rest.len)
        std.mem.trimStart(u8, rest[kind_str.len + 1 ..], " ")
    else
        "";

    return Diagnostic{
        .file_path = allocator.dupe(u8, file_path) catch return null,
        .line = line_num,
        .column = col_num,
        .kind = kind,
        .message = allocator.dupe(u8, message) catch return null,
    };
}

pub fn runBuild(
    workspace_root: []const u8,
    command: BuildCommand,
    allocator: std.mem.Allocator,
    io: std.Io,
) !BuildOutput {
    const start_time = std.Io.Clock.real.now(io).toMilliseconds();

    const result = std.process.run(allocator, io, .{
        .argv = command.toArgs(),
        .cwd = .{ .path = workspace_root },
        .stdout_limit = .limited(10 * 1024 * 1024),
        .stderr_limit = .limited(10 * 1024 * 1024),
    }) catch |err| {
        const err_msg = std.fmt.allocPrint(allocator, "Failed to run {s}: {}", .{ command.displayName(), err }) catch "";
        return BuildOutput{
            .success = false,
            .stdout = try allocator.dupe(u8, ""),
            .stderr = err_msg,
            .exit_code = 1,
            .diagnostics = try allocator.alloc(Diagnostic, 0),
            .duration_ms = std.Io.Clock.real.now(io).toMilliseconds() - start_time,
        };
    };

    const success = result.term.exited == 0;

    const diagnostics = try parseZigDiagnostics(result.stderr, allocator);

    return BuildOutput{
        .success = success,
        .stdout = result.stdout,
        .stderr = result.stderr,
        .exit_code = @intCast(result.term.exited),
        .diagnostics = diagnostics,
        .duration_ms = std.Io.Clock.real.now(io).toMilliseconds() - start_time,
    };
}

pub fn zigBuildRunJob(ctx: *anyopaque, progress: *JobProgress, allocator: std.mem.Allocator) anyerror![]const u8 {
    const build_ctx: *BuildJobContext = @ptrCast(@alignCast(ctx));

    progress.update(10, "Starting zig build run...");

    if (progress.isCancelled()) {
        return error.Cancelled;
    }

    var output = try runBuild(build_ctx.workspace_root, .run, allocator, build_ctx.io);
    defer output.deinit(allocator);

    progress.update(100, null);

    if (output.success) {
        return try std.fmt.allocPrint(allocator, "Build succeeded in {d}ms\n\n{s}", .{
            output.duration_ms,
            output.stdout,
        });
    } else {
        return try std.fmt.allocPrint(allocator, "Build failed in {d}ms\n\n{s}", .{
            output.duration_ms,
            output.stderr,
        });
    }
}

pub fn zigBuildTestJob(ctx: *anyopaque, progress: *JobProgress, allocator: std.mem.Allocator) anyerror![]const u8 {
    const build_ctx: *BuildJobContext = @ptrCast(@alignCast(ctx));

    progress.update(10, "Starting zig build test...");

    if (progress.isCancelled()) {
        return error.Cancelled;
    }

    var output = try runBuild(build_ctx.workspace_root, .@"test", allocator, build_ctx.io);
    defer output.deinit(allocator);

    progress.update(100, null);

    if (output.success) {
        return try std.fmt.allocPrint(allocator, "All tests passed in {d}ms\n\n{s}", .{
            output.duration_ms,
            output.stdout,
        });
    } else {
        return try std.fmt.allocPrint(allocator, "Tests failed in {d}ms\n\n{s}", .{
            output.duration_ms,
            output.stderr,
        });
    }
}

pub fn formatBuildOutput(output: *const BuildOutput, allocator: std.mem.Allocator) ![]u8 {
    var result: std.Io.Writer.Allocating = .init(allocator);
    errdefer result.deinit();

    const writer = &result.writer;

    try writer.writeAll("╔══════════════════════════════════════════════════════════════╗\n");
    if (output.success) {
        try writer.writeAll("║  ✓ BUILD SUCCESSFUL                                          ║\n");
    } else {
        try writer.writeAll("║  ✗ BUILD FAILED                                              ║\n");
    }
    try writer.writeAll("╚══════════════════════════════════════════════════════════════╝\n\n");

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

    if (output.stderr.len > 0 and !output.success) {
        try writer.writeAll("─────────────────── Errors ───────────────────────────────────────\n");
        try writer.writeAll(output.stderr);
        if (!std.mem.endsWith(u8, output.stderr, "\n")) {
            try writer.writeByte('\n');
        }
    }

    return result.toOwnedSlice();
}

test "parse zig diagnostics" {
    const allocator = std.testing.allocator;

    const test_output =
        \\src/main.zig:42:15: error: expected 'const' or 'var'
        \\src/main.zig:43:1: note: previous declaration here
        \\src/lib.zig:10:5: warning: unused variable
    ;

    const diagnostics = try parseZigDiagnostics(test_output, allocator);
    defer {
        for (diagnostics) |*d| {
            var diag = d.*;
            diag.deinit(allocator);
        }
        allocator.free(diagnostics);
    }

    try std.testing.expectEqual(@as(usize, 3), diagnostics.len);
    try std.testing.expectEqualStrings("src/main.zig", diagnostics[0].file_path);
    try std.testing.expectEqual(@as(u32, 42), diagnostics[0].line);
    try std.testing.expectEqual(Diagnostic.DiagnosticKind.@"error", diagnostics[0].kind);
}
