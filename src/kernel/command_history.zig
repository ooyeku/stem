const std = @import("std");

pub const CommandHistory = struct {
    allocator: std.mem.Allocator,
    max_entries: usize,
    ids: std.ArrayListUnmanaged([]u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, max_entries: usize) CommandHistory {
        return .{
            .allocator = allocator,
            .max_entries = max_entries,
        };
    }

    pub fn deinit(self: *CommandHistory) void {
        for (self.ids.items) |id| {
            self.allocator.free(id);
        }
        self.ids.deinit(self.allocator);
        self.ids = .empty;
    }

    pub fn record(self: *CommandHistory, id: []const u8) !void {
        if (self.max_entries == 0) return;

        if (self.rank(id)) |idx| {
            const old = self.ids.orderedRemove(idx);
            self.allocator.free(old);
        }

        const owned = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(owned);
        try self.ids.insert(self.allocator, 0, owned);

        while (self.ids.items.len > self.max_entries) {
            const removed = self.ids.orderedRemove(self.ids.items.len - 1);
            self.allocator.free(removed);
        }
    }

    pub fn rank(self: *const CommandHistory, id: []const u8) ?usize {
        for (self.ids.items, 0..) |candidate, idx| {
            if (std.mem.eql(u8, candidate, id)) return idx;
        }
        return null;
    }

    pub fn scoreBoost(self: *const CommandHistory, id: []const u8) i64 {
        const idx = self.rank(id) orelse return 0;
        return @intCast(self.max_entries -| idx);
    }

    pub fn scoreBoostAdapter(ctx: ?*const anyopaque, id: []const u8) i64 {
        const raw = ctx orelse return 0;
        const self: *const CommandHistory = @ptrCast(@alignCast(raw));
        return self.scoreBoost(id);
    }
};

test "command history records most recent first and deduplicates" {
    var history = CommandHistory.init(std.testing.allocator, 4);
    defer history.deinit();

    try history.record("file.open");
    try history.record("task.list");
    try history.record("file.open");

    try std.testing.expectEqual(@as(usize, 2), history.ids.items.len);
    try std.testing.expectEqualStrings("file.open", history.ids.items[0]);
    try std.testing.expectEqualStrings("task.list", history.ids.items[1]);
    try std.testing.expectEqual(@as(?usize, 0), history.rank("file.open"));
    try std.testing.expectEqual(@as(?usize, 1), history.rank("task.list"));
}

test "command history respects max entries" {
    var history = CommandHistory.init(std.testing.allocator, 2);
    defer history.deinit();

    try history.record("one");
    try history.record("two");
    try history.record("three");

    try std.testing.expectEqual(@as(usize, 2), history.ids.items.len);
    try std.testing.expectEqualStrings("three", history.ids.items[0]);
    try std.testing.expectEqualStrings("two", history.ids.items[1]);
    try std.testing.expectEqual(@as(?usize, null), history.rank("one"));
}

test "command history boost favors newer commands" {
    var history = CommandHistory.init(std.testing.allocator, 8);
    defer history.deinit();

    try history.record("older");
    try history.record("newer");

    try std.testing.expect(history.scoreBoost("newer") > history.scoreBoost("older"));
    try std.testing.expectEqual(@as(i64, 0), history.scoreBoost("missing"));
}

test "command history boost adapter returns history score" {
    var history = CommandHistory.init(std.testing.allocator, 8);
    defer history.deinit();
    try history.record("recent");

    try std.testing.expect(CommandHistory.scoreBoostAdapter(&history, "recent") > 0);
    try std.testing.expectEqual(@as(i64, 0), CommandHistory.scoreBoostAdapter(&history, "missing"));
}
