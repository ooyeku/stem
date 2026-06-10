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
    const Marker = struct {
        idx: usize,
        kind: Diagnostic.DiagnosticKind,
        len: usize,
    };
    const marker: Marker = blk: {
        if (std.mem.indexOf(u8, line, ": error:")) |idx| break :blk .{ .idx = idx, .kind = Diagnostic.DiagnosticKind.@"error", .len = ": error:".len };
        if (std.mem.indexOf(u8, line, ": warning:")) |idx| break :blk .{ .idx = idx, .kind = Diagnostic.DiagnosticKind.warning, .len = ": warning:".len };
        if (std.mem.indexOf(u8, line, ": note:")) |idx| break :blk .{ .idx = idx, .kind = Diagnostic.DiagnosticKind.note, .len = ": note:".len };
        return null;
    };

    const prefix = line[0..marker.idx];
    const col_sep = std.mem.lastIndexOfScalar(u8, prefix, ':') orelse return null;
    const line_sep = std.mem.lastIndexOfScalar(u8, prefix[0..col_sep], ':') orelse return null;

    const file_path = prefix[0..line_sep];
    const line_str = prefix[line_sep + 1 .. col_sep];
    const col_str = prefix[col_sep + 1 ..];
    if (file_path.len == 0 or line_str.len == 0 or col_str.len == 0) return null;

    const line_num = std.fmt.parseInt(u32, line_str, 10) catch return null;
    const col_num = std.fmt.parseInt(u32, col_str, 10) catch return null;
    const message = std.mem.trimStart(u8, line[marker.idx + marker.len ..], " ");

    return Diagnostic{
        .file_path = allocator.dupe(u8, file_path) catch return null,
        .line = line_num,
        .column = col_num,
        .kind = marker.kind,
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
        const err_msg = try std.fmt.allocPrint(allocator, "Failed to run {s}: {}", .{ command.displayName(), err });
        errdefer allocator.free(err_msg);
        const stdout = try allocator.dupe(u8, "");
        errdefer allocator.free(stdout);
        const diagnostics = try allocator.alloc(Diagnostic, 0);
        return BuildOutput{
            .success = false,
            .stdout = stdout,
            .stderr = err_msg,
            .exit_code = 1,
            .diagnostics = diagnostics,
            .duration_ms = std.Io.Clock.real.now(io).toMilliseconds() - start_time,
        };
    };
    errdefer allocator.free(result.stdout);
    errdefer allocator.free(result.stderr);

    const success = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    const exit_code: u8 = switch (result.term) {
        .exited => |code| @intCast(@min(code, std.math.maxInt(u8))),
        else => 255,
    };

    const diagnostics = try parseZigDiagnostics(result.stderr, allocator);

    return BuildOutput{
        .success = success,
        .stdout = result.stdout,
        .stderr = result.stderr,
        .exit_code = exit_code,
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

test "parse zig diagnostics with Windows drive paths" {
    const allocator = std.testing.allocator;

    const diagnostics = try parseZigDiagnostics(
        "C:\\proj\\src\\main.zig:12:3: error: expected expression\n",
        allocator,
    );
    defer {
        for (diagnostics) |*d| {
            var diag = d.*;
            diag.deinit(allocator);
        }
        allocator.free(diagnostics);
    }

    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqualStrings("C:\\proj\\src\\main.zig", diagnostics[0].file_path);
    try std.testing.expectEqual(@as(u32, 12), diagnostics[0].line);
    try std.testing.expectEqual(@as(u32, 3), diagnostics[0].column);
    try std.testing.expectEqualStrings("expected expression", diagnostics[0].message);
}
