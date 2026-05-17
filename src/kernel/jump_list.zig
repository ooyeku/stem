const std = @import("std");
const TestIo = @import("../test_utils.zig").TestIo;

pub const JumpLocation = struct {
    file_path: []const u8,
    row: usize,
    col: usize,
    timestamp: i64,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8, row: usize, col: usize) !JumpLocation {
        return .{
            .file_path = try allocator.dupe(u8, file_path),
            .row = row,
            .col = col,
            .timestamp = std.Io.Clock.real.now(io).toMilliseconds(),
        };
    }

    pub fn deinit(self: *JumpLocation, allocator: std.mem.Allocator) void {
        allocator.free(self.file_path);
    }

    pub fn eql(self: JumpLocation, other: JumpLocation) bool {
        return self.row == other.row and
            self.col == other.col and
            std.mem.eql(u8, self.file_path, other.file_path);
    }
};

pub const JumpList = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    locations: std.ArrayList(JumpLocation),
    current_index: ?usize,
    max_size: usize,

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator, io: std.Io, max_size: usize) JumpList {
        return .{
            .allocator = alloc,
            .io = io,
            .locations = std.ArrayList(JumpLocation).initCapacity(alloc, 0) catch unreachable,
            .current_index = null,
            .max_size = max_size,
        };
    }

    pub fn deinit(self: *JumpList) void {
        for (self.locations.items) |*loc| {
            loc.deinit(self.allocator);
        }
        self.locations.deinit(self.allocator);
    }

    pub fn recordJump(
        self: *JumpList,
        file_path: []const u8,
        row: usize,
        col: usize,
    ) !void {
        if (self.current_index) |idx| {
            if (idx < self.locations.items.len) {
                const current = self.locations.items[idx];
                if (current.eql(.{
                    .file_path = file_path,
                    .row = row,
                    .col = col,
                    .timestamp = 0,
                })) {
                    return;
                }
            }
        }

        const location = try JumpLocation.init(self.allocator, self.io, file_path, row, col);

        if (self.current_index) |current_idx| {
            var i = current_idx + 1;
            while (i < self.locations.items.len) : (i += 1) {
                self.locations.items[i].deinit(self.allocator);
            }
            self.locations.shrinkRetainingCapacity(current_idx + 1);
        }

        try self.locations.append(self.allocator, location);
        self.current_index = self.locations.items.len - 1;

        if (self.locations.items.len > self.max_size) {
            var oldest = self.locations.orderedRemove(0);
            oldest.deinit(self.allocator);
            if (self.current_index) |*idx| {
                idx.* -= 1;
            }
        }
    }

    pub fn jumpBack(self: *JumpList) ?JumpLocation {
        if (self.locations.items.len == 0) return null;

        const idx = self.current_index orelse {
            self.current_index = self.locations.items.len - 1;
            return if (self.locations.items.len > 0)
                self.locations.items[self.locations.items.len - 1]
            else
                null;
        };

        if (idx == 0) return null;

        self.current_index = idx - 1;
        return self.locations.items[idx - 1];
    }

    pub fn jumpForward(self: *JumpList) ?JumpLocation {
        const idx = self.current_index orelse return null;

        if (idx >= self.locations.items.len - 1) return null;

        self.current_index = idx + 1;
        return self.locations.items[idx + 1];
    }

    pub fn getCurrent(self: *JumpList) ?JumpLocation {
        const idx = self.current_index orelse return null;
        if (idx >= self.locations.items.len) return null;
        return self.locations.items[idx];
    }

    pub fn canJumpBack(self: *JumpList) bool {
        const idx = self.current_index orelse return false;
        return idx > 0;
    }

    pub fn canJumpForward(self: *JumpList) bool {
        const idx = self.current_index orelse return false;
        return idx < self.locations.items.len - 1;
    }

    pub fn size(self: *JumpList) usize {
        return self.locations.items.len;
    }

    pub fn clear(self: *JumpList) void {
        for (self.locations.items) |*loc| {
            loc.deinit(self.allocator);
        }
        self.locations.clearRetainingCapacity();
        self.current_index = null;
    }
};

test "JumpList initialization" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var jl = JumpList.init(allocator, io, 100);
    defer jl.deinit();

    try std.testing.expectEqual(0, jl.size());
    try std.testing.expect(jl.getCurrent() == null);
    try std.testing.expect(!jl.canJumpBack());
    try std.testing.expect(!jl.canJumpForward());
}

test "JumpList record and navigate" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var jl = JumpList.init(allocator, io, 100);
    defer jl.deinit();

    try jl.recordJump("file1.zig", 10, 5);
    try jl.recordJump("file2.zig", 20, 10);
    try jl.recordJump("file3.zig", 30, 15);

    try std.testing.expectEqual(3, jl.size());
    try std.testing.expect(jl.canJumpBack());
    try std.testing.expect(!jl.canJumpForward());

    const loc2 = jl.jumpBack().?;
    try std.testing.expectEqual(20, loc2.row);
    try std.testing.expectEqualStrings("file2.zig", loc2.file_path);
    try std.testing.expect(jl.canJumpForward());

    const loc1 = jl.jumpBack().?;
    try std.testing.expectEqual(10, loc1.row);
    try std.testing.expectEqualStrings("file1.zig", loc1.file_path);
    try std.testing.expect(!jl.canJumpBack());

    const loc2_again = jl.jumpForward().?;
    try std.testing.expectEqual(20, loc2_again.row);

    const loc3 = jl.jumpForward().?;
    try std.testing.expectEqual(30, loc3.row);
    try std.testing.expect(!jl.canJumpForward());
}

test "JumpList doesn't record duplicate locations" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var jl = JumpList.init(allocator, io, 100);
    defer jl.deinit();

    try jl.recordJump("file.zig", 10, 5);
    try jl.recordJump("file.zig", 10, 5);
    try jl.recordJump("file.zig", 10, 5);

    try std.testing.expectEqual(1, jl.size());
}

test "JumpList discards forward history on new jump" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var jl = JumpList.init(allocator, io, 100);
    defer jl.deinit();

    try jl.recordJump("file1.zig", 10, 0);
    try jl.recordJump("file2.zig", 20, 0);
    try jl.recordJump("file3.zig", 30, 0);

    _ = jl.jumpBack();
    _ = jl.jumpBack();

    try std.testing.expectEqual(3, jl.size());

    try jl.recordJump("file4.zig", 40, 0);

    try std.testing.expectEqual(2, jl.size());
    try std.testing.expect(!jl.canJumpForward());
}

test "JumpList enforces max size" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var jl = JumpList.init(allocator, io, 3);
    defer jl.deinit();

    try jl.recordJump("file1.zig", 10, 0);
    try jl.recordJump("file2.zig", 20, 0);
    try jl.recordJump("file3.zig", 30, 0);
    try jl.recordJump("file4.zig", 40, 0);

    try std.testing.expectEqual(3, jl.size());

    _ = jl.jumpBack();
    const oldest = jl.jumpBack().?;
    try std.testing.expectEqualStrings("file2.zig", oldest.file_path);
}

test "JumpList clear" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var jl = JumpList.init(allocator, io, 100);
    defer jl.deinit();

    try jl.recordJump("file1.zig", 10, 0);
    try jl.recordJump("file2.zig", 20, 0);

    jl.clear();

    try std.testing.expectEqual(0, jl.size());
    try std.testing.expect(jl.getCurrent() == null);
}

test "JumpList boundary conditions" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var jl = JumpList.init(allocator, io, 100);
    defer jl.deinit();

    try std.testing.expect(jl.jumpBack() == null);
    try std.testing.expect(jl.jumpForward() == null);

    try jl.recordJump("file.zig", 10, 0);

    try std.testing.expect(jl.jumpBack() == null);
    try std.testing.expect(jl.jumpForward() == null);
}

test "JumpLocation equality" {
    const allocator = std.testing.allocator;

    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var loc1 = try JumpLocation.init(allocator, io, "file.zig", 10, 5);
    defer loc1.deinit(allocator);

    const loc2 = JumpLocation{
        .file_path = "file.zig",
        .row = 10,
        .col = 5,
        .timestamp = 0,
    };

    try std.testing.expect(loc1.eql(loc2));

    const loc3 = JumpLocation{
        .file_path = "file.zig",
        .row = 11,
        .col = 5,
        .timestamp = 0,
    };

    try std.testing.expect(!loc1.eql(loc3));
}
