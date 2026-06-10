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
        } else |_| blk: {
            // Last-resort fallback. POSIX has a single global root `/`;
            // Windows has per-drive roots, so the closest equivalent of
            // "I have no idea where I am" is the system drive root. Get
            // there via `std.fs.path.sep_str` so the same code works on
            // both. realPathFile failing in practice means the process
            // has no usable cwd at all, so the user will see further
            // errors immediately — we just need a non-null string here.
            break :blk try allocator.dupe(u8, if (@import("builtin").os.tag == .windows) "C:\\" else "/");
        };

        return .{
            .allocator = allocator,
            .io = io,
            .cwd = cwd,
            .entries = .empty,
            .selected_index = 0,
        };
    }

    /// Are we at a filesystem root? POSIX: cwd == "/". Windows: cwd is
    /// of the shape `<drive>:\` or `<drive>:/` (length 3). Used by
    /// `refresh` to decide whether to surface a `..` entry.
    fn isAtRoot(cwd: []const u8) bool {
        if (std.mem.eql(u8, cwd, "/")) return true;
        if (@import("builtin").os.tag == .windows and
            cwd.len == 3 and
            std.ascii.isAlphabetic(cwd[0]) and
            cwd[1] == ':' and
            (cwd[2] == '\\' or cwd[2] == '/'))
        {
            return true;
        }
        return false;
    }

    pub fn deinit(self: *FileManager) void {
        self.clearEntries();
        self.allocator.free(self.cwd);
    }

    fn clearEntryList(allocator: Allocator, entries: *std.ArrayListUnmanaged(DirEntry)) void {
        for (entries.items) |entry| {
            entry.deinit(allocator);
        }
        entries.deinit(allocator);
        entries.* = .empty;
    }

    fn clearEntries(self: *FileManager) void {
        clearEntryList(self.allocator, &self.entries);
    }

    pub fn refresh(self: *FileManager) !void {
        var dir = try std.Io.Dir.openDirAbsolute(self.io, self.cwd, .{ .iterate = true });
        defer dir.close(self.io);

        var new_entries: std.ArrayListUnmanaged(DirEntry) = .empty;
        errdefer clearEntryList(self.allocator, &new_entries);

        if (!isAtRoot(self.cwd)) {
            const dotdot = try self.allocator.dupe(u8, "..");
            errdefer self.allocator.free(dotdot);
            try new_entries.append(self.allocator, .{
                .name = dotdot,
                .is_dir = true,
            });
        }

        var iter = dir.iterate();
        while (try iter.next(self.io)) |entry| {
            if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
            const name = try self.allocator.dupe(u8, entry.name);
            errdefer self.allocator.free(name);
            try new_entries.append(self.allocator, .{
                .name = name,
                .is_dir = entry.kind == .directory,
            });
        }

        std.mem.sort(DirEntry, new_entries.items, {}, struct {
            fn lessThan(_: void, a: DirEntry, b: DirEntry) bool {
                if (a.is_dir and !b.is_dir) return true;
                if (!a.is_dir and b.is_dir) return false;
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lessThan);

        self.clearEntries();
        self.entries = new_entries;
        self.selected_index = 0;
    }

    fn switchCwdAndRefresh(self: *FileManager, new_cwd: []u8) !void {
        const old_cwd = self.cwd;
        self.cwd = new_cwd;
        self.refresh() catch |err| {
            self.cwd = old_cwd;
            self.allocator.free(new_cwd);
            return err;
        };
        self.allocator.free(old_cwd);
    }

    pub fn setCwd(self: *FileManager, path: []const u8) !void {
        const new_cwd = try self.allocator.dupe(u8, path);
        try self.switchCwdAndRefresh(new_cwd);
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
            try self.switchCwdAndRefresh(full_path);
            return null;
        } else {
            return full_path;
        }
    }

    pub fn goParent(self: *FileManager) !void {
        const parent = std.fs.path.dirname(self.cwd);
        if (parent) |p| {
            const new_cwd = try self.allocator.dupe(u8, p);
            try self.switchCwdAndRefresh(new_cwd);
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

test "FileManager setCwd preserves state when refresh fails" {
    const allocator = std.testing.allocator;

    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var fm = try FileManager.init(allocator, io);
    defer fm.deinit();

    try fm.refresh();
    const original_cwd = try allocator.dupe(u8, fm.cwd);
    defer allocator.free(original_cwd);
    const original_len = fm.entries.items.len;
    const original_selected = fm.selected_index;

    const missing = try std.fs.path.join(allocator, &.{ fm.cwd, "stem-definitely-missing-dir-994777cf" });
    defer allocator.free(missing);

    if (fm.setCwd(missing)) |_| {
        return error.ExpectedSetCwdFailure;
    } else |_| {}

    try std.testing.expectEqualStrings(original_cwd, fm.cwd);
    try std.testing.expectEqual(original_len, fm.entries.items.len);
    try std.testing.expectEqual(original_selected, fm.selected_index);
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

test "FileManager enter preserves cwd when selected directory cannot be refreshed" {
    const allocator = std.testing.allocator;

    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var fm = try FileManager.init(allocator, io);
    defer fm.deinit();

    try fm.refresh();
    const original_cwd = try allocator.dupe(u8, fm.cwd);
    defer allocator.free(original_cwd);

    const bogus_name = try allocator.dupe(u8, "stem-missing-selected-dir-2a77f4c1");
    errdefer allocator.free(bogus_name);
    try fm.entries.append(allocator, .{
        .name = bogus_name,
        .is_dir = true,
    });
    fm.selected_index = fm.entries.items.len - 1;

    if (fm.enter()) |_| {
        return error.ExpectedEnterFailure;
    } else |_| {}

    try std.testing.expectEqualStrings(original_cwd, fm.cwd);
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
