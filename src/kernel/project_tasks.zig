const std = @import("std");

pub const TaskKind = enum {
    build,
    @"test",
    run,
    dev,
    lint,
    format,
    custom,

    pub fn label(self: TaskKind) []const u8 {
        return switch (self) {
            .build => "build",
            .@"test" => "test",
            .run => "run",
            .dev => "dev",
            .lint => "lint",
            .format => "format",
            .custom => "custom",
        };
    }
};

pub const ProjectTask = struct {
    /// Owned by the ProjectTask instance when returned from detectProjectTasks.
    /// Borrowed literals may be used for transient calls to runTaskSync, but
    /// must not be passed to deinit.
    id: []const u8,
    label: []const u8,
    command: []const u8,
    kind: TaskKind,
    source: []const u8,
    priority: u16,

    pub fn deinit(self: *ProjectTask, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.label);
        allocator.free(self.command);
        allocator.free(self.source);
    }
};

pub const TaskRunResult = struct {
    task_id: []const u8,
    label: []const u8,
    command: []const u8,
    cwd: []const u8,
    stdout: []const u8,
    stderr: []const u8,
    success: bool,
    exit_code: i32,
    duration_ms: i64,

    pub fn deinit(self: *TaskRunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.task_id);
        allocator.free(self.label);
        allocator.free(self.command);
        allocator.free(self.cwd);
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub fn runTaskSync(
    allocator: std.mem.Allocator,
    io: std.Io,
    task: ProjectTask,
    cwd: []const u8,
) !TaskRunResult {
    const builtin = @import("builtin");
    const start_time = std.Io.Clock.real.now(io).toMilliseconds();
    const windows_argv = [_][]const u8{ "cmd.exe", "/C", task.command };
    const posix_argv = [_][]const u8{ "/bin/sh", "-c", task.command };
    const argv = if (builtin.os.tag == .windows) windows_argv[0..] else posix_argv[0..];

    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(10 * 1024 * 1024),
        .stderr_limit = .limited(10 * 1024 * 1024),
    }) catch |err| {
        const stderr = try std.fmt.allocPrint(allocator, "Failed to run `{s}`: {}", .{ task.command, err });
        errdefer allocator.free(stderr);
        const stdout = try allocator.dupe(u8, "");
        errdefer allocator.free(stdout);
        const task_id = try allocator.dupe(u8, task.id);
        errdefer allocator.free(task_id);
        const label = try allocator.dupe(u8, task.label);
        errdefer allocator.free(label);
        const command = try allocator.dupe(u8, task.command);
        errdefer allocator.free(command);
        const cwd_copy = try allocator.dupe(u8, cwd);
        errdefer allocator.free(cwd_copy);
        return TaskRunResult{
            .task_id = task_id,
            .label = label,
            .command = command,
            .cwd = cwd_copy,
            .stdout = stdout,
            .stderr = stderr,
            .success = false,
            .exit_code = 1,
            .duration_ms = std.Io.Clock.real.now(io).toMilliseconds() - start_time,
        };
    };
    errdefer allocator.free(result.stdout);
    errdefer allocator.free(result.stderr);

    const success = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    const exit_code: i32 = switch (result.term) {
        .exited => |code| @intCast(code),
        .signal => |sig| -@as(i32, @intCast(@intFromEnum(sig))),
        else => -999,
    };

    const task_id = try allocator.dupe(u8, task.id);
    errdefer allocator.free(task_id);
    const label = try allocator.dupe(u8, task.label);
    errdefer allocator.free(label);
    const command = try allocator.dupe(u8, task.command);
    errdefer allocator.free(command);
    const cwd_copy = try allocator.dupe(u8, cwd);
    errdefer allocator.free(cwd_copy);

    return TaskRunResult{
        .task_id = task_id,
        .label = label,
        .command = command,
        .cwd = cwd_copy,
        .stdout = result.stdout,
        .stderr = result.stderr,
        .success = success,
        .exit_code = exit_code,
        .duration_ms = std.Io.Clock.real.now(io).toMilliseconds() - start_time,
    };
}

pub fn formatRunResult(allocator: std.mem.Allocator, result: *const TaskRunResult) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.print(
        \\# Task Output
        \\
        \\- Task: {s}
        \\- ID: `{s}`
        \\- Command: `{s}`
        \\- Root: {s}
        \\- Status: {s}
        \\- Exit code: {d}
        \\- Duration: {d}ms
        \\
    , .{
        result.label,
        result.task_id,
        result.command,
        result.cwd,
        if (result.success) "success" else "failed",
        result.exit_code,
        result.duration_ms,
    });

    try w.writeAll("## Stdout\n\n```text\n");
    if (result.stdout.len > 0) {
        try w.writeAll(result.stdout);
        if (result.stdout[result.stdout.len - 1] != '\n') try w.writeByte('\n');
    }
    try w.writeAll("```\n\n## Stderr\n\n```text\n");
    if (result.stderr.len > 0) {
        try w.writeAll(result.stderr);
        if (result.stderr[result.stderr.len - 1] != '\n') try w.writeByte('\n');
    }
    try w.writeAll("```\n");

    return aw.toOwnedSlice();
}

pub const ProjectTaskList = struct {
    tasks: []ProjectTask = &.{},

    pub fn deinit(self: *ProjectTaskList, allocator: std.mem.Allocator) void {
        for (self.tasks) |*task| task.deinit(allocator);
        allocator.free(self.tasks);
        self.tasks = &.{};
    }

    pub fn findById(self: *const ProjectTaskList, id: []const u8) ?*const ProjectTask {
        for (self.tasks) |*task| {
            if (std.mem.eql(u8, task.id, id)) return task;
        }
        return null;
    }

    pub fn findFirstByKind(self: *const ProjectTaskList, kind: TaskKind) ?*const ProjectTask {
        var best: ?*const ProjectTask = null;
        for (self.tasks) |*task| {
            if (task.kind != kind) continue;
            if (best == null or task.priority < best.?.priority) best = task;
        }
        return best;
    }
};

const TaskSpec = struct {
    id: []const u8,
    label: []const u8,
    command: []const u8,
    kind: TaskKind,
    source: []const u8,
    priority: u16,
};

pub fn detectProjectTasks(allocator: std.mem.Allocator, io: std.Io, root: []const u8) !ProjectTaskList {
    var out = std.ArrayListUnmanaged(ProjectTask).empty;
    errdefer {
        for (out.items) |*task| task.deinit(allocator);
        out.deinit(allocator);
    }

    if (exists(io, allocator, root, "build.zig")) {
        try addTask(allocator, &out, .{ .id = "zig.build", .label = "Zig: Build", .command = "zig build", .kind = .build, .source = "build.zig", .priority = 10 });
        try addTask(allocator, &out, .{ .id = "zig.test", .label = "Zig: Test", .command = "zig build test", .kind = .@"test", .source = "build.zig", .priority = 11 });
        try addTask(allocator, &out, .{ .id = "zig.run", .label = "Zig: Run", .command = "zig build run", .kind = .run, .source = "build.zig", .priority = 12 });
    }

    if (exists(io, allocator, root, "Cargo.toml")) {
        try addTask(allocator, &out, .{ .id = "cargo.build", .label = "Cargo: Build", .command = "cargo build", .kind = .build, .source = "Cargo.toml", .priority = 20 });
        try addTask(allocator, &out, .{ .id = "cargo.test", .label = "Cargo: Test", .command = "cargo test", .kind = .@"test", .source = "Cargo.toml", .priority = 21 });
        try addTask(allocator, &out, .{ .id = "cargo.run", .label = "Cargo: Run", .command = "cargo run", .kind = .run, .source = "Cargo.toml", .priority = 22 });
    }

    if (exists(io, allocator, root, "go.mod")) {
        try addTask(allocator, &out, .{ .id = "go.test", .label = "Go: Test", .command = "go test ./...", .kind = .@"test", .source = "go.mod", .priority = 30 });
        try addTask(allocator, &out, .{ .id = "go.build", .label = "Go: Build", .command = "go build ./...", .kind = .build, .source = "go.mod", .priority = 31 });
        try addTask(allocator, &out, .{ .id = "go.run", .label = "Go: Run", .command = "go run .", .kind = .run, .source = "go.mod", .priority = 32 });
    }

    if (exists(io, allocator, root, "pyproject.toml") or
        exists(io, allocator, root, "pytest.ini") or
        exists(io, allocator, root, "requirements.txt") or
        exists(io, allocator, root, "setup.py"))
    {
        try addTask(allocator, &out, .{ .id = "python.test", .label = "Python: Test", .command = "python -m pytest", .kind = .@"test", .source = "python", .priority = 40 });
    }

    try addNpmScripts(allocator, io, root, &out);
    try addMakeTargets(allocator, io, root, &out);

    std.sort.block(ProjectTask, out.items, {}, compareTasks);
    return .{ .tasks = try out.toOwnedSlice(allocator) };
}

fn addTask(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(ProjectTask), spec: TaskSpec) !void {
    for (out.items) |task| {
        if (std.mem.eql(u8, task.id, spec.id)) return;
    }

    const id = try allocator.dupe(u8, spec.id);
    errdefer allocator.free(id);
    const label = try allocator.dupe(u8, spec.label);
    errdefer allocator.free(label);
    const command = try allocator.dupe(u8, spec.command);
    errdefer allocator.free(command);
    const source = try allocator.dupe(u8, spec.source);
    errdefer allocator.free(source);

    try out.append(allocator, .{
        .id = id,
        .label = label,
        .command = command,
        .kind = spec.kind,
        .source = source,
        .priority = spec.priority,
    });
}

fn addNpmScripts(allocator: std.mem.Allocator, io: std.Io, root: []const u8, out: *std.ArrayListUnmanaged(ProjectTask)) !void {
    const package_path = try std.fs.path.join(allocator, &.{ root, "package.json" });
    defer allocator.free(package_path);

    const content = std.Io.Dir.cwd().readFileAlloc(io, package_path, allocator, .limited(1024 * 1024)) catch return;
    defer allocator.free(content);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const scripts = parsed.value.object.get("scripts") orelse return;
    if (scripts != .object) return;

    const Script = struct { name: []const u8, kind: TaskKind, priority: u16 };
    const scripts_to_detect = [_]Script{
        .{ .name = "build", .kind = .build, .priority = 50 },
        .{ .name = "test", .kind = .@"test", .priority = 51 },
        .{ .name = "dev", .kind = .dev, .priority = 52 },
        .{ .name = "start", .kind = .run, .priority = 53 },
        .{ .name = "lint", .kind = .lint, .priority = 54 },
        .{ .name = "format", .kind = .format, .priority = 55 },
    };

    for (scripts_to_detect) |script| {
        const value = scripts.object.get(script.name) orelse continue;
        if (value != .string) continue;
        const id = try std.fmt.allocPrint(allocator, "npm.{s}", .{script.name});
        defer allocator.free(id);
        const label = try std.fmt.allocPrint(allocator, "npm: {s}", .{script.name});
        defer allocator.free(label);
        const command = try std.fmt.allocPrint(allocator, "npm run {s}", .{script.name});
        defer allocator.free(command);
        try addTask(allocator, out, .{
            .id = id,
            .label = label,
            .command = command,
            .kind = script.kind,
            .source = "package.json",
            .priority = script.priority,
        });
    }
}

fn addMakeTargets(allocator: std.mem.Allocator, io: std.Io, root: []const u8, out: *std.ArrayListUnmanaged(ProjectTask)) !void {
    const makefile_name = if (exists(io, allocator, root, "Makefile"))
        "Makefile"
    else if (exists(io, allocator, root, "makefile"))
        "makefile"
    else
        return;

    const makefile_path = try std.fs.path.join(allocator, &.{ root, makefile_name });
    defer allocator.free(makefile_path);
    const content = std.Io.Dir.cwd().readFileAlloc(io, makefile_path, allocator, .limited(512 * 1024)) catch return;
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r");
        if (line.len == 0 or line[0] == '#' or line[0] == '.') continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const target = std.mem.trim(u8, line[0..colon], " ");
        if (!isMakeTargetName(target)) continue;
        if (!isCommonTaskName(target)) continue;

        const id = try std.fmt.allocPrint(allocator, "make.{s}", .{target});
        defer allocator.free(id);
        const label = try std.fmt.allocPrint(allocator, "make: {s}", .{target});
        defer allocator.free(label);
        const command = try std.fmt.allocPrint(allocator, "make {s}", .{target});
        defer allocator.free(command);
        try addTask(allocator, out, .{
            .id = id,
            .label = label,
            .command = command,
            .kind = kindFromName(target),
            .source = makefile_name,
            .priority = 60,
        });
    }
}

fn exists(io: std.Io, allocator: std.mem.Allocator, root: []const u8, rel: []const u8) bool {
    const path = std.fs.path.join(allocator, &.{ root, rel }) catch return false;
    defer allocator.free(path);
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

fn compareTasks(_: void, a: ProjectTask, b: ProjectTask) bool {
    if (a.priority != b.priority) return a.priority < b.priority;
    return std.mem.lessThan(u8, a.id, b.id);
}

fn isMakeTargetName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.') continue;
        return false;
    }
    return true;
}

fn isCommonTaskName(name: []const u8) bool {
    const common = [_][]const u8{ "build", "test", "run", "dev", "start", "lint", "format", "install" };
    for (common) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

fn kindFromName(name: []const u8) TaskKind {
    if (std.mem.eql(u8, name, "build")) return .build;
    if (std.mem.eql(u8, name, "test")) return .@"test";
    if (std.mem.eql(u8, name, "run") or std.mem.eql(u8, name, "start")) return .run;
    if (std.mem.eql(u8, name, "dev")) return .dev;
    if (std.mem.eql(u8, name, "lint")) return .lint;
    if (std.mem.eql(u8, name, "format")) return .format;
    return .custom;
}

test "project task detection includes common ecosystem commands" {
    const TestIo = @import("../test_utils.zig").TestIo;
    const Tempdir = @import("../test_utils.zig").Tempdir;
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();

    var tmp = try Tempdir.init(allocator, io_ctx.io());
    defer tmp.deinit();

    try tmp.writeFile("build.zig", "pub fn build(_: *anyopaque) void {}\n");
    try tmp.writeFile("Cargo.toml", "[package]\nname = \"demo\"\n");
    try tmp.writeFile("go.mod", "module demo\n");
    try tmp.writeFile("pyproject.toml", "[project]\nname = \"demo\"\n");
    try tmp.writeFile("package.json",
        \\{"scripts":{"build":"vite build","test":"vitest","dev":"vite","lint":"eslint ."}}
    );

    var tasks = try detectProjectTasks(allocator, io_ctx.io(), tmp.path);
    defer tasks.deinit(allocator);

    try expectTask(&tasks, "zig.build", "zig build");
    try expectTask(&tasks, "zig.test", "zig build test");
    try expectTask(&tasks, "zig.run", "zig build run");
    try expectTask(&tasks, "cargo.test", "cargo test");
    try expectTask(&tasks, "go.test", "go test ./...");
    try expectTask(&tasks, "python.test", "python -m pytest");
    try expectTask(&tasks, "npm.build", "npm run build");
    try expectTask(&tasks, "npm.test", "npm run test");
    try expectTask(&tasks, "npm.dev", "npm run dev");
    try expectTask(&tasks, "npm.lint", "npm run lint");
}

test "project task detection parses make targets and owns task strings" {
    const TestIo = @import("../test_utils.zig").TestIo;
    const Tempdir = @import("../test_utils.zig").Tempdir;
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();

    var tmp = try Tempdir.init(allocator, io_ctx.io());
    defer tmp.deinit();

    try tmp.writeFile("Makefile",
        \\build:
        \\  zig build
        \\test:
        \\  zig build test
        \\.PHONY: build test
    );

    var tasks = try detectProjectTasks(allocator, io_ctx.io(), tmp.path);
    defer tasks.deinit(allocator);

    try expectTask(&tasks, "make.build", "make build");
    try expectTask(&tasks, "make.test", "make test");

    try tmp.writeFile("Makefile", "other:\n  true\n");
    try expectTask(&tasks, "make.build", "make build");
}

test "project task runner captures successful output" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    const task = ProjectTask{
        .id = "custom.echo",
        .label = "Echo",
        .command = "echo stem-task-ok",
        .kind = .custom,
        .source = "test",
        .priority = 1,
    };

    var result = try runTaskSync(std.testing.allocator, threaded.io(), task, ".");
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "stem-task-ok") != null);
    try std.testing.expectEqualStrings("custom.echo", result.task_id);
}

test "project task runner captures failing exit code" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    const command = if (@import("builtin").os.tag == .windows) "exit /b 7" else "exit 7";
    const task = ProjectTask{
        .id = "custom.fail",
        .label = "Fail",
        .command = command,
        .kind = .custom,
        .source = "test",
        .priority = 1,
    };

    var result = try runTaskSync(std.testing.allocator, threaded.io(), task, ".");
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.success);
    try std.testing.expectEqual(@as(i32, 7), result.exit_code);
}

test "project task list finds preferred task by kind" {
    var tasks = [_]ProjectTask{
        .{
            .id = "npm.test",
            .label = "npm: test",
            .command = "npm run test",
            .kind = .@"test",
            .source = "package.json",
            .priority = 51,
        },
        .{
            .id = "zig.build",
            .label = "Zig: Build",
            .command = "zig build",
            .kind = .build,
            .source = "build.zig",
            .priority = 10,
        },
        .{
            .id = "make.build",
            .label = "make: build",
            .command = "make build",
            .kind = .build,
            .source = "Makefile",
            .priority = 60,
        },
    };
    const list = ProjectTaskList{ .tasks = tasks[0..] };

    try std.testing.expectEqualStrings("zig.build", list.findFirstByKind(.build).?.id);
    try std.testing.expectEqualStrings("npm.test", list.findFirstByKind(.@"test").?.id);
    try std.testing.expect(list.findFirstByKind(.run) == null);
}

fn expectTask(tasks: *const ProjectTaskList, id: []const u8, command: []const u8) !void {
    const task = tasks.findById(id) orelse return error.MissingTask;
    try std.testing.expectEqualStrings(command, task.command);
}
