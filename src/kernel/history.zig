const std = @import("std");
const logger = @import("../services/logger.zig");
const TestIo = @import("../test_utils.zig").TestIo;
const log = logger.scoped("History");

pub const HistoryAction = union(enum) {
    insert: struct {
        pos: usize,
        text: []const u8,
    },
    delete: struct {
        pos: usize,
        text: []const u8,
    },
};

pub const CursorState = struct {
    row: usize,
    col: usize,
};

pub const Transaction = struct {
    actions: std.ArrayListUnmanaged(HistoryAction),
    cursor_before: CursorState,
    cursor_after: CursorState,
    timestamp: i64,

    pub fn deinit(self: *Transaction, allocator: std.mem.Allocator) void {
        for (self.actions.items) |action| {
            switch (action) {
                .delete => |d| allocator.free(d.text),
                .insert => |i| allocator.free(i.text),
            }
        }
        self.actions.deinit(allocator);
    }

    pub fn clone(self: Transaction, allocator: std.mem.Allocator) !Transaction {
        var new_actions = std.ArrayListUnmanaged(HistoryAction).empty;
        errdefer {
            for (new_actions.items) |action| {
                switch (action) {
                    .delete => |d| allocator.free(d.text),
                    .insert => |i| allocator.free(i.text),
                }
            }
            new_actions.deinit(allocator);
        }

        for (self.actions.items) |action| {
            const dup_text = switch (action) {
                .insert => |i| try allocator.dupe(u8, i.text),
                .delete => |d| try allocator.dupe(u8, d.text),
            };
            errdefer allocator.free(dup_text);
            const cloned: HistoryAction = switch (action) {
                .insert => |i| .{ .insert = .{ .pos = i.pos, .text = dup_text } },
                .delete => |d| .{ .delete = .{ .pos = d.pos, .text = dup_text } },
            };
            try new_actions.append(allocator, cloned);
        }

        return Transaction{
            .actions = new_actions,
            .cursor_before = self.cursor_before,
            .cursor_after = self.cursor_after,
            .timestamp = self.timestamp,
        };
    }
};

pub const HistoryManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    undo_stack: std.ArrayListUnmanaged(Transaction),
    redo_stack: std.ArrayListUnmanaged(Transaction),
    current_transaction: ?Transaction,
    last_action_time: i64,
    grouping_delay_ms: i64,
    max_stack_size: usize,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) HistoryManager {
        return HistoryManager{
            .allocator = allocator,
            .io = io,
            .undo_stack = .empty,
            .redo_stack = .empty,
            .current_transaction = null,
            .last_action_time = 0,
            .grouping_delay_ms = 500,
            .max_stack_size = 1000,
        };
    }

    pub fn deinit(self: *HistoryManager) void {
        for (self.undo_stack.items) |*txn| {
            txn.deinit(self.allocator);
        }
        self.undo_stack.deinit(self.allocator);

        for (self.redo_stack.items) |*txn| {
            txn.deinit(self.allocator);
        }
        self.redo_stack.deinit(self.allocator);

        if (self.current_transaction) |*txn| {
            txn.deinit(self.allocator);
        }
    }

    pub fn beginTransaction(self: *HistoryManager, cursor: CursorState) void {
        const now = std.Io.Clock.real.now(self.io).toMilliseconds();
        const should_group = (now - self.last_action_time) < self.grouping_delay_ms;

        if (self.current_transaction == null or !should_group) {
            if (self.current_transaction) |*txn| {
                if (txn.actions.items.len > 0) {
                    self.pushUndo(txn.*);
                } else {
                    txn.deinit(self.allocator);
                }
            }

            self.current_transaction = Transaction{
                .actions = .empty,
                .cursor_before = cursor,
                .cursor_after = cursor,
                .timestamp = now,
            };
        }

        self.last_action_time = now;
    }

    pub fn recordInsert(self: *HistoryManager, pos: usize, text: []const u8) !void {
        if (self.current_transaction) |*txn| {
            const text_copy = try self.allocator.dupe(u8, text);
            try txn.actions.append(self.allocator, .{
                .insert = .{ .pos = pos, .text = text_copy },
            });
        }
    }

    pub fn recordDelete(self: *HistoryManager, pos: usize, text: []const u8) !void {
        if (self.current_transaction) |*txn| {
            const text_copy = try self.allocator.dupe(u8, text);
            try txn.actions.append(self.allocator, .{
                .delete = .{ .pos = pos, .text = text_copy },
            });
        }
    }

    pub fn commitTransaction(self: *HistoryManager, cursor: CursorState) void {
        if (self.current_transaction) |*txn| {
            txn.cursor_after = cursor;

            if (txn.actions.items.len > 0) {
                self.pushUndo(txn.*);
            } else {
                txn.deinit(self.allocator);
            }
            self.current_transaction = null;
        }
    }

    pub fn flushTransaction(self: *HistoryManager, cursor: CursorState) void {
        self.commitTransaction(cursor);
    }

    fn pushUndo(self: *HistoryManager, txn: Transaction) void {
        while (self.undo_stack.items.len >= self.max_stack_size) {
            var oldest = self.undo_stack.orderedRemove(0);
            oldest.deinit(self.allocator);
        }

        self.undo_stack.append(self.allocator, txn) catch |err| {
            log.err("Failed to push undo transaction: {} - undo history may be incomplete", .{err});
            var owned = txn;
            owned.deinit(self.allocator);
            return;
        };

        for (self.redo_stack.items) |*redo_txn| {
            redo_txn.deinit(self.allocator);
        }
        self.redo_stack.clearRetainingCapacity();
    }

    pub fn undo(self: *HistoryManager) ?Transaction {
        if (self.current_transaction) |*txn| {
            if (txn.actions.items.len > 0) {
                self.pushUndo(txn.*);
            } else {
                txn.deinit(self.allocator);
            }
            self.current_transaction = null;
        }

        if (self.undo_stack.items.len == 0) return null;

        const txn = self.undo_stack.pop() orelse return null;

        var redo_clone = txn.clone(self.allocator) catch return txn;
        self.redo_stack.append(self.allocator, redo_clone) catch |err| {
            log.warn("Failed to save redo state: {} - redo unavailable", .{err});
            redo_clone.deinit(self.allocator);
        };

        return txn;
    }

    pub fn redo(self: *HistoryManager) ?Transaction {
        if (self.redo_stack.items.len == 0) return null;

        const txn = self.redo_stack.pop() orelse return null;

        var undo_clone = txn.clone(self.allocator) catch return txn;
        // Enforce max_stack_size here too — pushUndo does, but it also
        // clears redo, which we must not do mid-redo.
        while (self.undo_stack.items.len >= self.max_stack_size) {
            var oldest = self.undo_stack.orderedRemove(0);
            oldest.deinit(self.allocator);
        }
        self.undo_stack.append(self.allocator, undo_clone) catch |err| {
            log.warn("Failed to save undo state during redo: {}", .{err});
            undo_clone.deinit(self.allocator);
        };

        return txn;
    }

    pub fn canUndo(self: *HistoryManager) bool {
        return self.undo_stack.items.len > 0 or
            (self.current_transaction != null and self.current_transaction.?.actions.items.len > 0);
    }

    pub fn canRedo(self: *HistoryManager) bool {
        return self.redo_stack.items.len > 0;
    }

    pub fn undoCount(self: *HistoryManager) usize {
        var count = self.undo_stack.items.len;
        if (self.current_transaction) |txn| {
            if (txn.actions.items.len > 0) count += 1;
        }
        return count;
    }

    pub fn redoCount(self: *HistoryManager) usize {
        return self.redo_stack.items.len;
    }

    pub fn clear(self: *HistoryManager) void {
        for (self.undo_stack.items) |*txn| {
            txn.deinit(self.allocator);
        }
        self.undo_stack.clearRetainingCapacity();

        for (self.redo_stack.items) |*txn| {
            txn.deinit(self.allocator);
        }
        self.redo_stack.clearRetainingCapacity();

        if (self.current_transaction) |*txn| {
            txn.deinit(self.allocator);
            self.current_transaction = null;
        }
    }
};

test "history manager basic undo/redo" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var hm = HistoryManager.init(allocator, io);
    defer hm.deinit();

    hm.beginTransaction(.{ .row = 0, .col = 0 });
    try hm.recordInsert(0, "hello");
    hm.commitTransaction(.{ .row = 0, .col = 5 });

    try std.testing.expect(hm.canUndo());
    try std.testing.expect(!hm.canRedo());

    if (hm.undo()) |txn| {
        defer {
            var t = txn;
            t.deinit(allocator);
        }
        try std.testing.expectEqual(@as(usize, 1), txn.actions.items.len);
        try std.testing.expectEqual(@as(usize, 0), txn.actions.items[0].insert.pos);
        try std.testing.expectEqual(@as(usize, 5), txn.actions.items[0].insert.text.len);
    }

    try std.testing.expect(!hm.canUndo());
    try std.testing.expect(hm.canRedo());

    if (hm.redo()) |txn| {
        defer {
            var t = txn;
            t.deinit(allocator);
        }
        try std.testing.expectEqual(@as(usize, 1), txn.actions.items.len);
    }

    try std.testing.expect(hm.canUndo());
    try std.testing.expect(!hm.canRedo());
}

test "history manager delete with text preservation" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var hm = HistoryManager.init(allocator, io);
    defer hm.deinit();

    hm.beginTransaction(.{ .row = 0, .col = 5 });
    try hm.recordDelete(5, "world");
    hm.commitTransaction(.{ .row = 0, .col = 5 });

    try std.testing.expect(hm.canUndo());

    if (hm.undo()) |txn| {
        defer {
            var t = txn;
            t.deinit(allocator);
        }
        try std.testing.expectEqual(@as(usize, 1), txn.actions.items.len);
        const action = txn.actions.items[0];
        try std.testing.expectEqualStrings("world", action.delete.text);
    }
}

test "history manager empty state" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var hm = HistoryManager.init(allocator, io);
    defer hm.deinit();

    try std.testing.expect(!hm.canUndo());
    try std.testing.expect(!hm.canRedo());
    try std.testing.expectEqual(@as(usize, 0), hm.undoCount());
    try std.testing.expectEqual(@as(usize, 0), hm.redoCount());
}

test "history manager multiple insert operations" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var hm = HistoryManager.init(allocator, io);
    defer hm.deinit();

    hm.beginTransaction(.{ .row = 0, .col = 0 });
    try hm.recordInsert(0, "Hello");
    hm.commitTransaction(.{ .row = 0, .col = 5 });

    hm.beginTransaction(.{ .row = 0, .col = 5 });
    try hm.recordInsert(5, " World");
    hm.commitTransaction(.{ .row = 0, .col = 11 });

    try std.testing.expectEqual(@as(usize, 2), hm.undoCount());

    if (hm.undo()) |txn| {
        defer {
            var t = txn;
            t.deinit(allocator);
        }
        try std.testing.expectEqual(@as(usize, 5), txn.cursor_before.col);
    }

    try std.testing.expectEqual(@as(usize, 1), hm.undoCount());
    try std.testing.expectEqual(@as(usize, 1), hm.redoCount());
}

test "history manager transaction grouping" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var hm = HistoryManager.init(allocator, io);
    defer hm.deinit();

    hm.beginTransaction(.{ .row = 0, .col = 0 });
    try hm.recordInsert(0, "a");
    hm.commitTransaction(.{ .row = 0, .col = 1 });

    hm.last_action_time = std.Io.Clock.real.now(io).toMilliseconds();

    hm.beginTransaction(.{ .row = 0, .col = 1 });
    try hm.recordInsert(1, "b");
    hm.commitTransaction(.{ .row = 0, .col = 2 });

    const count = hm.undoCount();
    try std.testing.expect(count >= 1);
}

test "history manager redo cleared on new action" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var hm = HistoryManager.init(allocator, io);
    defer hm.deinit();

    hm.beginTransaction(.{ .row = 0, .col = 0 });
    try hm.recordInsert(0, "hello");
    hm.commitTransaction(.{ .row = 0, .col = 5 });

    if (hm.undo()) |txn| {
        var t = txn;
        t.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), hm.redoCount());

    hm.beginTransaction(.{ .row = 0, .col = 0 });
    try hm.recordInsert(0, "new");
    hm.commitTransaction(.{ .row = 0, .col = 3 });

    try std.testing.expectEqual(@as(usize, 0), hm.redoCount());
}

test "history manager multiple deletes" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var hm = HistoryManager.init(allocator, io);
    defer hm.deinit();

    hm.beginTransaction(.{ .row = 0, .col = 5 });
    try hm.recordDelete(5, "World");
    hm.commitTransaction(.{ .row = 0, .col = 5 });

    hm.beginTransaction(.{ .row = 0, .col = 0 });
    try hm.recordDelete(0, "Hello");
    hm.commitTransaction(.{ .row = 0, .col = 0 });

    try std.testing.expectEqual(@as(usize, 2), hm.undoCount());

    if (hm.undo()) |txn| {
        defer {
            var t = txn;
            t.deinit(allocator);
        }
        try std.testing.expectEqualStrings("Hello", txn.actions.items[0].delete.text);
    }

    if (hm.undo()) |txn| {
        defer {
            var t = txn;
            t.deinit(allocator);
        }
        try std.testing.expectEqualStrings("World", txn.actions.items[0].delete.text);
    }

    try std.testing.expect(!hm.canUndo());
}

test "history manager mixed insert and delete" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var hm = HistoryManager.init(allocator, io);
    defer hm.deinit();

    hm.beginTransaction(.{ .row = 0, .col = 0 });
    try hm.recordInsert(0, "hello");
    try hm.recordDelete(5, " old");
    try hm.recordInsert(5, "test");
    hm.commitTransaction(.{ .row = 0, .col = 9 });

    try std.testing.expectEqual(@as(usize, 1), hm.undoCount());

    if (hm.undo()) |txn| {
        defer {
            var t = txn;
            t.deinit(allocator);
        }
        try std.testing.expectEqual(@as(usize, 3), txn.actions.items.len);
    }
}

test "history manager cursor state preservation" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var hm = HistoryManager.init(allocator, io);
    defer hm.deinit();

    hm.beginTransaction(.{ .row = 1, .col = 5 });
    try hm.recordInsert(10, "testing");
    hm.commitTransaction(.{ .row = 1, .col = 12 });

    if (hm.undo()) |txn| {
        defer {
            var t = txn;
            t.deinit(allocator);
        }
        try std.testing.expectEqual(@as(usize, 1), txn.cursor_before.row);
        try std.testing.expectEqual(@as(usize, 5), txn.cursor_before.col);
        try std.testing.expectEqual(@as(usize, 1), txn.cursor_after.row);
        try std.testing.expectEqual(@as(usize, 12), txn.cursor_after.col);
    }
}

test "history manager flush transaction" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var hm = HistoryManager.init(allocator, io);
    defer hm.deinit();

    hm.beginTransaction(.{ .row = 0, .col = 0 });
    try hm.recordInsert(0, "hello");

    try std.testing.expectEqual(@as(usize, 1), hm.undoCount());

    hm.flushTransaction(.{ .row = 0, .col = 5 });

    try std.testing.expectEqual(@as(usize, 1), hm.undoCount());
    try std.testing.expect(hm.current_transaction == null);
}

test "history manager empty transaction not saved" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var hm = HistoryManager.init(allocator, io);
    defer hm.deinit();

    hm.beginTransaction(.{ .row = 0, .col = 0 });
    hm.commitTransaction(.{ .row = 0, .col = 0 });

    try std.testing.expectEqual(@as(usize, 0), hm.undoCount());
}

test "history manager max stack size enforcement" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var hm = HistoryManager.init(allocator, io);
    defer hm.deinit();

    hm.max_stack_size = 3;

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        hm.beginTransaction(.{ .row = 0, .col = @intCast(i) });
        try hm.recordInsert(i, "x");
        hm.commitTransaction(.{ .row = 0, .col = @intCast(i + 1) });
    }

    try std.testing.expectEqual(@as(usize, 3), hm.undoCount());
}

test "history manager clear" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var hm = HistoryManager.init(allocator, io);
    defer hm.deinit();

    hm.beginTransaction(.{ .row = 0, .col = 0 });
    try hm.recordInsert(0, "hello");
    hm.commitTransaction(.{ .row = 0, .col = 5 });

    if (hm.undo()) |txn| {
        var t = txn;
        t.deinit(allocator);
    }

    try std.testing.expect(hm.canRedo());

    hm.clear();

    try std.testing.expect(!hm.canUndo());
    try std.testing.expect(!hm.canRedo());
    try std.testing.expectEqual(@as(usize, 0), hm.undoCount());
    try std.testing.expectEqual(@as(usize, 0), hm.redoCount());
}

test "history manager undo/redo chain" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var hm = HistoryManager.init(allocator, io);
    defer hm.deinit();

    hm.beginTransaction(.{ .row = 0, .col = 0 });
    try hm.recordInsert(0, "a");
    hm.commitTransaction(.{ .row = 0, .col = 1 });

    hm.beginTransaction(.{ .row = 0, .col = 1 });
    try hm.recordInsert(1, "b");
    hm.commitTransaction(.{ .row = 0, .col = 2 });

    hm.beginTransaction(.{ .row = 0, .col = 2 });
    try hm.recordInsert(2, "c");
    hm.commitTransaction(.{ .row = 0, .col = 3 });

    if (hm.undo()) |txn| {
        var t = txn;
        t.deinit(allocator);
    }
    if (hm.undo()) |txn| {
        var t = txn;
        t.deinit(allocator);
    }
    if (hm.undo()) |txn| {
        var t = txn;
        t.deinit(allocator);
    }

    try std.testing.expect(!hm.canUndo());
    try std.testing.expectEqual(@as(usize, 3), hm.redoCount());

    if (hm.redo()) |txn| {
        var t = txn;
        t.deinit(allocator);
    }
    if (hm.redo()) |txn| {
        var t = txn;
        t.deinit(allocator);
    }
    if (hm.redo()) |txn| {
        var t = txn;
        t.deinit(allocator);
    }

    try std.testing.expect(!hm.canRedo());
    try std.testing.expectEqual(@as(usize, 3), hm.undoCount());
}

test "history manager transaction clone" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var hm = HistoryManager.init(allocator, io);
    defer hm.deinit();

    hm.beginTransaction(.{ .row = 0, .col = 0 });
    try hm.recordDelete(0, "test");
    hm.commitTransaction(.{ .row = 0, .col = 0 });

    if (hm.undo()) |txn| {
        defer {
            var t = txn;
            t.deinit(allocator);
        }

        try std.testing.expectEqual(@as(usize, 1), hm.redoCount());
        try std.testing.expectEqualStrings("test", txn.actions.items[0].delete.text);
    }

    if (hm.redo()) |txn| {
        defer {
            var t = txn;
            t.deinit(allocator);
        }
        try std.testing.expectEqualStrings("test", txn.actions.items[0].delete.text);
    }
}

test "history manager undo with nothing to undo" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var hm = HistoryManager.init(allocator, io);
    defer hm.deinit();

    const result = hm.undo();
    try std.testing.expect(result == null);
}

test "history manager redo with nothing to redo" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var hm = HistoryManager.init(allocator, io);
    defer hm.deinit();

    const result = hm.redo();
    try std.testing.expect(result == null);
}

test "history manager rapid undo/redo without commits" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var hm = HistoryManager.init(allocator, io);
    defer hm.deinit();

    hm.beginTransaction(.{ .row = 0, .col = 0 });
    try hm.recordInsert(0, "hello");
    hm.commitTransaction(.{ .row = 0, .col = 5 });

    if (hm.undo()) |txn| {
        var t = txn;
        t.deinit(allocator);
    }

    if (hm.redo()) |txn| {
        var t = txn;
        t.deinit(allocator);
    }

    if (hm.undo()) |txn| {
        var t = txn;
        t.deinit(allocator);
    }

    try std.testing.expect(!hm.canUndo());
    try std.testing.expectEqual(@as(usize, 1), hm.redoCount());
}

test "history manager max stack size enforcement v2" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var hm = HistoryManager.init(allocator, io);
    defer hm.deinit();

    var i: usize = 0;
    while (i < 1050) : (i += 1) {
        hm.beginTransaction(.{ .row = 0, .col = @intCast(i) });
        try hm.recordInsert(@intCast(i), "x");
        hm.commitTransaction(.{ .row = 0, .col = @intCast(i + 1) });
    }

    try std.testing.expect(hm.undoCount() <= hm.max_stack_size);
}

test "history manager commit empty transaction" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var hm = HistoryManager.init(allocator, io);
    defer hm.deinit();

    hm.beginTransaction(.{ .row = 0, .col = 0 });
    hm.commitTransaction(.{ .row = 0, .col = 0 });

    try std.testing.expect(!hm.canUndo());
}

test "history manager new edit clears redo stack" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var hm = HistoryManager.init(allocator, io);
    defer hm.deinit();

    hm.beginTransaction(.{ .row = 0, .col = 0 });
    try hm.recordInsert(0, "first");
    hm.commitTransaction(.{ .row = 0, .col = 5 });

    if (hm.undo()) |txn| {
        var t = txn;
        t.deinit(allocator);
    }

    try std.testing.expect(hm.canRedo());

    hm.beginTransaction(.{ .row = 0, .col = 0 });
    try hm.recordInsert(0, "new");
    hm.commitTransaction(.{ .row = 0, .col = 3 });

    try std.testing.expect(!hm.canRedo());
}

test "history manager flush pending transaction" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var hm = HistoryManager.init(allocator, io);
    defer hm.deinit();

    hm.beginTransaction(.{ .row = 0, .col = 0 });
    try hm.recordInsert(0, "pending");

    try std.testing.expect(hm.current_transaction != null);

    hm.flushTransaction(.{ .row = 0, .col = 7 });

    try std.testing.expect(hm.canUndo());
}

test "history manager clear all history" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var hm = HistoryManager.init(allocator, io);
    defer hm.deinit();

    hm.beginTransaction(.{ .row = 0, .col = 0 });
    try hm.recordInsert(0, "a");
    hm.commitTransaction(.{ .row = 0, .col = 1 });

    hm.beginTransaction(.{ .row = 0, .col = 1 });
    try hm.recordInsert(1, "b");
    hm.commitTransaction(.{ .row = 0, .col = 2 });

    try std.testing.expect(hm.canUndo());

    hm.clear();

    try std.testing.expect(!hm.canUndo());
    try std.testing.expect(!hm.canRedo());
}

test "history manager mixed insert and delete in one transaction" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var hm = HistoryManager.init(allocator, io);
    defer hm.deinit();

    hm.beginTransaction(.{ .row = 0, .col = 5 });
    try hm.recordDelete(5, "World"); // Delete "World"
    try hm.recordInsert(5, "Universe"); // Insert "Universe"
    hm.commitTransaction(.{ .row = 0, .col = 13 });

    try std.testing.expectEqual(@as(usize, 1), hm.undoCount());

    if (hm.undo()) |txn| {
        defer {
            var t = txn;
            t.deinit(allocator);
        }
        try std.testing.expectEqual(@as(usize, 2), txn.actions.items.len);
    }
}

test "history manager undo preserves cursor state" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var hm = HistoryManager.init(allocator, io);
    defer hm.deinit();

    const cursor_before = CursorState{ .row = 0, .col = 0 };
    const cursor_after = CursorState{ .row = 0, .col = 10 };

    hm.beginTransaction(cursor_before);
    try hm.recordInsert(0, "HelloWorld");
    hm.commitTransaction(cursor_after);

    if (hm.undo()) |txn| {
        defer {
            var t = txn;
            t.deinit(allocator);
        }
        try std.testing.expectEqual(cursor_before.row, txn.cursor_before.row);
        try std.testing.expectEqual(cursor_before.col, txn.cursor_before.col);
    }
}
