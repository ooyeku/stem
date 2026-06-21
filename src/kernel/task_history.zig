const std = @import("std");
const project_tasks = @import("project_tasks.zig");

pub const LastTaskSnapshot = struct {
    root: []u8,
    task: project_tasks.ProjectTask,

    pub fn deinit(self: *LastTaskSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.root);
        self.task.deinit(allocator);
    }
};

pub const TaskHistory = struct {
    allocator: std.mem.Allocator,
    last_task: ?LastTaskSnapshot = null,

    pub fn init(allocator: std.mem.Allocator) TaskHistory {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TaskHistory) void {
        self.clear();
    }

    pub fn record(self: *TaskHistory, root: []const u8, task: project_tasks.ProjectTask) !void {
        const root_copy = try self.allocator.dupe(u8, root);
        errdefer self.allocator.free(root_copy);
        const id = try self.allocator.dupe(u8, task.id);
        errdefer self.allocator.free(id);
        const label = try self.allocator.dupe(u8, task.label);
        errdefer self.allocator.free(label);
        const command = try self.allocator.dupe(u8, task.command);
        errdefer self.allocator.free(command);
        const source = try self.allocator.dupe(u8, task.source);
        errdefer self.allocator.free(source);

        self.clear();
        self.last_task = .{
            .root = root_copy,
            .task = .{
                .id = id,
                .label = label,
                .command = command,
                .kind = task.kind,
                .source = source,
                .priority = task.priority,
            },
        };
    }

    pub fn last(self: *const TaskHistory) ?*const LastTaskSnapshot {
        if (self.last_task) |*snapshot| return snapshot;
        return null;
    }

    fn clear(self: *TaskHistory) void {
        if (self.last_task) |*snapshot| {
            snapshot.deinit(self.allocator);
            self.last_task = null;
        }
    }
};

test "task history records owned last task snapshot" {
    var history = TaskHistory.init(std.testing.allocator);
    defer history.deinit();

    const task = project_tasks.ProjectTask{
        .id = "zig.test",
        .label = "Zig: Test",
        .command = "zig build test",
        .kind = .@"test",
        .source = "build.zig",
        .priority = 11,
    };

    try history.record("/tmp/project", task);
    const last = history.last().?;

    try std.testing.expectEqualStrings("/tmp/project", last.root);
    try std.testing.expectEqualStrings("zig.test", last.task.id);
    try std.testing.expectEqualStrings("zig build test", last.task.command);
}

test "task history replacement frees old snapshot and stores new one" {
    var history = TaskHistory.init(std.testing.allocator);
    defer history.deinit();

    const first = project_tasks.ProjectTask{
        .id = "one",
        .label = "One",
        .command = "echo one",
        .kind = .custom,
        .source = "test",
        .priority = 1,
    };
    const second = project_tasks.ProjectTask{
        .id = "two",
        .label = "Two",
        .command = "echo two",
        .kind = .custom,
        .source = "test",
        .priority = 2,
    };

    try history.record("/tmp/one", first);
    try history.record("/tmp/two", second);

    const last = history.last().?;
    try std.testing.expectEqualStrings("/tmp/two", last.root);
    try std.testing.expectEqualStrings("two", last.task.id);
}
