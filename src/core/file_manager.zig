const std = @import("std");
const TestIo = @import("../test_utils.zig").TestIo;
const Allocator = std.mem.Allocator;

pub const DirEntry = struct {
    name: []const u8,
    is_dir: bool,

    pub fn deinit(self: DirEntry, allocator: Allocator) void {
        allocator.free(self.name);
    }
};

pub const FileManager = struct {
    allocator: Allocator,
    io: std.Io,
    cwd: []u8,
    entries: std.ArrayListUnmanaged(DirEntry),
    selected_index: usize,

    pub fn init(allocator: Allocator, io: std.Io) !FileManager {
        const cwd: []u8 = if (std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator)) |z| blk: {
            // Convert sentinel-terminated slice to plain []u8 so deinit's free matches the alloc.
            defer allocator.free(z);
            break :blk try allocator.dupe(u8, z);
        } else |_| try allocator.dupe(u8, "/");

        return .{
            .allocator = allocator,
            .io = io,
            .cwd = cwd,
            .entries = .empty,
            .selected_index = 0,
        };
    }

    pub fn deinit(self: *FileManager) void {
        self.clearEntries();
        self.allocator.free(self.cwd);
    }

    fn clearEntries(self: *FileManager) void {
        for (self.entries.items) |entry| {
            entry.deinit(self.allocator);
        }
        self.entries.deinit(self.allocator);
        self.entries = .empty;
    }

    pub fn refresh(self: *FileManager) !void {
        self.clearEntries();
        self.selected_index = 0;

        if (!std.mem.eql(u8, self.cwd, "/")) {
            const dotdot = try self.allocator.dupe(u8, "..");
            errdefer self.allocator.free(dotdot);
            try self.entries.append(self.allocator, .{
                .name = dotdot,
                .is_dir = true,
            });
        }

        var dir = std.Io.Dir.openDirAbsolute(self.io, self.cwd, .{ .iterate = true }) catch |err| {
            std.debug.print("Failed to open dir {s}: {}\n", .{ self.cwd, err });
            return;
        };
        defer dir.close(self.io);

        var iter = dir.iterate();
        while (try iter.next(self.io)) |entry| {
            if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
            const name = try self.allocator.dupe(u8, entry.name);
            errdefer self.allocator.free(name);
            try self.entries.append(self.allocator, .{
                .name = name,
                .is_dir = entry.kind == .directory,
            });
        }

        std.mem.sort(DirEntry, self.entries.items, {}, struct {
            fn lessThan(_: void, a: DirEntry, b: DirEntry) bool {
                if (a.is_dir and !b.is_dir) return true;
                if (!a.is_dir and b.is_dir) return false;
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lessThan);
    }

    pub fn setCwd(self: *FileManager, path: []const u8) !void {
        // Dupe first, then swap and free old — otherwise if dupe OOMs,
        // self.cwd would point at freed memory.
        const new_cwd = try self.allocator.dupe(u8, path);
        const old_cwd = self.cwd;
        self.cwd = new_cwd;
        self.allocator.free(old_cwd);
        try self.refresh();
    }

    pub fn moveUp(self: *FileManager) void {
        if (self.selected_index > 0) {
            self.selected_index -= 1;
        }
    }

    pub fn moveDown(self: *FileManager) void {
        if (self.entries.items.len > 0 and self.selected_index < self.entries.items.len - 1) {
            self.selected_index += 1;
        }
    }

    pub fn enter(self: *FileManager) !?[]const u8 {
        if (self.entries.items.len == 0) return null;

        const entry = self.entries.items[self.selected_index];

        if (std.mem.eql(u8, entry.name, "..")) {
            try self.goParent();
            return null;
        }

        const full_path = try std.fs.path.join(self.allocator, &.{ self.cwd, entry.name });

        if (entry.is_dir) {
            self.allocator.free(self.cwd);
            self.cwd = full_path;
            try self.refresh();
            return null;
        } else {
            return full_path;
        }
    }

    pub fn goParent(self: *FileManager) !void {
        const parent = std.fs.path.dirname(self.cwd);
        if (parent) |p| {
            const new_cwd = try self.allocator.dupe(u8, p);
            self.allocator.free(self.cwd);
            self.cwd = new_cwd;
            try self.refresh();
        }
    }

    pub fn getSelectedEntry(self: *FileManager) ?DirEntry {
        if (self.entries.items.len == 0) return null;
        return self.entries.items[self.selected_index];
    }
};

test "FileManager basic operations" {
    const allocator = std.testing.allocator;

    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var fm = try FileManager.init(allocator, io);
    defer fm.deinit();

    try fm.refresh();
    try std.testing.expect(fm.entries.items.len >= 0);
}

test "FileManager initialization" {
    const allocator = std.testing.allocator;

    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var fm = try FileManager.init(allocator, io);
    defer fm.deinit();

    try std.testing.expect(fm.cwd.len > 0);
    try std.testing.expectEqual(@as(usize, 0), fm.selected_index);
    try std.testing.expectEqual(@as(usize, 0), fm.entries.items.len);
}

test "FileManager moveUp and moveDown" {
    const allocator = std.testing.allocator;

    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var fm = try FileManager.init(allocator, io);
    defer fm.deinit();

    try fm.refresh();

    if (fm.entries.items.len > 1) {
        const initial = fm.selected_index;

        fm.moveDown();
        try std.testing.expectEqual(initial + 1, fm.selected_index);

        fm.moveUp();
        try std.testing.expectEqual(initial, fm.selected_index);
    }
}

test "FileManager moveUp at start" {
    const allocator = std.testing.allocator;

    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var fm = try FileManager.init(allocator, io);
    defer fm.deinit();

    try fm.refresh();
    fm.selected_index = 0;

    fm.moveUp();
    try std.testing.expectEqual(@as(usize, 0), fm.selected_index);
}

test "FileManager moveDown at end" {
    const allocator = std.testing.allocator;

    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var fm = try FileManager.init(allocator, io);
    defer fm.deinit();

    try fm.refresh();

    if (fm.entries.items.len > 0) {
        fm.selected_index = fm.entries.items.len - 1;
        const last = fm.selected_index;

        fm.moveDown();
        try std.testing.expectEqual(last, fm.selected_index);
    }
}

test "FileManager getSelectedEntry empty" {
    const allocator = std.testing.allocator;

    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var fm = try FileManager.init(allocator, io);
    defer fm.deinit();

    const entry = fm.getSelectedEntry();
    try std.testing.expect(entry == null);
}

test "FileManager getSelectedEntry valid" {
    const allocator = std.testing.allocator;

    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var fm = try FileManager.init(allocator, io);
    defer fm.deinit();

    try fm.refresh();

    if (fm.entries.items.len > 0) {
        const entry = fm.getSelectedEntry();
        try std.testing.expect(entry != null);
    }
}

test "FileManager goParent" {
    const allocator = std.testing.allocator;

    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var fm = try FileManager.init(allocator, io);
    defer fm.deinit();

    const original_cwd = try allocator.dupe(u8, fm.cwd);
    defer allocator.free(original_cwd);

    try fm.goParent();

    const changed = !std.mem.eql(u8, original_cwd, fm.cwd);
    const is_root = std.mem.eql(u8, fm.cwd, "/");

    try std.testing.expect(changed or is_root);
}

test "FileManager setCwd" {
    const allocator = std.testing.allocator;

    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var fm = try FileManager.init(allocator, io);
    defer fm.deinit();

    try fm.setCwd("/");

    try std.testing.expectEqualStrings("/", fm.cwd);
}

test "FileManager entries sorted" {
    const allocator = std.testing.allocator;

    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var fm = try FileManager.init(allocator, io);
    defer fm.deinit();

    try fm.refresh();

    var seen_file = false;
    for (fm.entries.items) |entry| {
        if (!entry.is_dir) {
            seen_file = true;
        } else if (seen_file) {
            try std.testing.expect(false);
        }
    }
}

test "FileManager enter directory" {
    const allocator = std.testing.allocator;

    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var fm = try FileManager.init(allocator, io);
    defer fm.deinit();

    try fm.refresh();

    var found_dir = false;
    for (fm.entries.items, 0..) |entry, i| {
        if (entry.is_dir) {
            fm.selected_index = i;
            found_dir = true;
            break;
        }
    }

    if (found_dir) {
        const result = try fm.enter();
        try std.testing.expect(result == null);
    }
}

test "FileManager enter file returns path" {
    const allocator = std.testing.allocator;

    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var fm = try FileManager.init(allocator, io);
    defer fm.deinit();

    try fm.refresh();

    var found_file = false;
    for (fm.entries.items, 0..) |entry, i| {
        if (!entry.is_dir) {
            fm.selected_index = i;
            found_file = true;
            break;
        }
    }

    if (found_file) {
        const result = try fm.enter();
        if (result) |path| {
            defer allocator.free(path);
            try std.testing.expect(path.len > 0);
        }
    }
}

test "FileManager enter on empty list" {
    const allocator = std.testing.allocator;

    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var fm = try FileManager.init(allocator, io);
    defer fm.deinit();

    const result = try fm.enter();
    try std.testing.expect(result == null);
}

test "Test written via Stem" {
    const allocator = std.testing.allocator;

    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var fm = try FileManager.init(allocator, io);
    defer fm.deinit();
}

test "FileManager rapid moveUp at top" {
    const allocator = std.testing.allocator;

    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var fm = try FileManager.init(allocator, io);
    defer fm.deinit();

    try fm.refresh();

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        fm.moveUp();
    }

    try std.testing.expectEqual(@as(usize, 0), fm.selected_index);
}

test "FileManager rapid moveDown at bottom" {
    const allocator = std.testing.allocator;

    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var fm = try FileManager.init(allocator, io);
    defer fm.deinit();

    try fm.refresh();

    if (fm.entries.items.len > 0) {
        fm.selected_index = fm.entries.items.len - 1;
        const last = fm.selected_index;

        var i: usize = 0;
        while (i < 100) : (i += 1) {
            fm.moveDown();
        }

        try std.testing.expectEqual(last, fm.selected_index);
    }
}

test "FileManager goParent at root" {
    const allocator = std.testing.allocator;

    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var fm = try FileManager.init(allocator, io);
    defer fm.deinit();

    try fm.setCwd("/");

    const before = fm.cwd;
    try fm.goParent();

    try std.testing.expectEqualStrings("/", fm.cwd);
    _ = before;
}

test "FileManager getSelectedEntry bounds" {
    const allocator = std.testing.allocator;

    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var fm = try FileManager.init(allocator, io);
    defer fm.deinit();

    const entry = fm.getSelectedEntry();
    try std.testing.expect(entry == null);
}

test "FileManager selected_index after refresh" {
    const allocator = std.testing.allocator;

    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var fm = try FileManager.init(allocator, io);
    defer fm.deinit();

    try fm.refresh();

    if (fm.entries.items.len > 2) {
        fm.selected_index = 2;
    }

    try fm.refresh();
    try std.testing.expectEqual(@as(usize, 0), fm.selected_index);
}

test "FileManager enter with parent directory entry" {
    const allocator = std.testing.allocator;

    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var fm = try FileManager.init(allocator, io);
    defer fm.deinit();

    try fm.setCwd("/tmp");
    try fm.refresh();

    for (fm.entries.items, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.name, "..")) {
            fm.selected_index = i;
            break;
        }
    }

    const result = try fm.enter();

    try std.testing.expect(result == null);
}

test "FileManager directories sorted before files" {
    const allocator = std.testing.allocator;

    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var fm = try FileManager.init(allocator, io);
    defer fm.deinit();

    try fm.refresh();

    var seen_file = false;
    for (fm.entries.items) |entry| {
        if (!entry.is_dir) {
            seen_file = true;
        } else if (seen_file and !std.mem.eql(u8, entry.name, "..")) {
            try std.testing.expect(false);
        }
    }
}
