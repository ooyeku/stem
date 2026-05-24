//! Tree-shaped, modal file explorer rooted at the project cwd.
//!
//! Opened by `Space e`. Maintains a flat list of visible rows
//! (one row per entry in the expanded subtree) so the renderer
//! is a straight iteration — no tree walk at draw time.
//!
//! The expansion set is a hash set of full paths. Re-walking the
//! tree to rebuild the visible row list happens whenever the user
//! expands, collapses, or asks for a refresh — all O(N) in the
//! visible subtree, never the whole disk.
//!
//! Convention parity with `file_manager.zig` (the fuzzy
//! picker): directories sort first, then alphabetical; hidden
//! files (leading dot) are hidden by default and toggled with
//! `H`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("protocol.zig");

pub const FileExplorer = struct {
    allocator: Allocator,
    io: std.Io,

    /// Root path the explorer is rooted at. Doesn't change as the
    /// user navigates around — collapse/expand walks happen
    /// relative to this. `setRoot` swaps it.
    root: []u8,

    /// Set of full-path strings that are currently expanded
    /// directories. Membership controls whether the walker
    /// descends into a directory when rebuilding the visible
    /// list. Keys are owned by the explorer; freed in deinit and
    /// in `collapse`.
    expanded: std.StringHashMapUnmanaged(void) = .empty,

    /// Flattened visible rows, top-to-bottom. Rebuilt by
    /// `rebuild()` whenever expansion state changes. Each entry
    /// owns its `name` and `path` slices.
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    /// Currently selected row (index into `entries`).
    selected: usize = 0,
    /// First visible row (for scrolling within the explorer
    /// panel). Updated by the input handler to keep `selected`
    /// in view.
    scroll_offset: usize = 0,

    /// When false, entries beginning with `.` are skipped during
    /// rebuild. Toggled by `H` in the input handler.
    show_hidden: bool = false,

    pub const Entry = struct {
        name: []u8,
        path: []u8,
        depth: u16,
        is_dir: bool,
        is_expanded: bool,

        pub fn deinit(self: Entry, allocator: Allocator) void {
            allocator.free(self.name);
            allocator.free(self.path);
        }
    };

    pub fn init(allocator: Allocator, io: std.Io, root: []const u8) !FileExplorer {
        const dup = try allocator.dupe(u8, root);
        return .{
            .allocator = allocator,
            .io = io,
            .root = dup,
        };
    }

    pub fn deinit(self: *FileExplorer) void {
        self.clearEntries();
        var it = self.expanded.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        self.expanded.deinit(self.allocator);
        self.allocator.free(self.root);
    }

    fn clearEntries(self: *FileExplorer) void {
        for (self.entries.items) |e| e.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.entries = .empty;
    }

    /// Walk the tree from `root`, descending into any directory
    /// whose path is in `expanded`. Builds the visible row list.
    /// Errors from individual `openDir` calls are swallowed — a
    /// permission-denied subdirectory just stays unexpanded.
    pub fn rebuild(self: *FileExplorer) !void {
        // Preserve selection across rebuilds by remembering the
        // path under the cursor; restore by exact path match
        // after the walk.
        const prior_path: ?[]u8 = if (self.selected < self.entries.items.len)
            self.allocator.dupe(u8, self.entries.items[self.selected].path) catch null
        else
            null;
        defer if (prior_path) |p| self.allocator.free(p);

        self.clearEntries();
        try self.walkDir(self.root, 0);

        if (prior_path) |p| {
            for (self.entries.items, 0..) |e, i| {
                if (std.mem.eql(u8, e.path, p)) {
                    self.selected = i;
                    return;
                }
            }
        }
        // Path no longer present — clamp.
        if (self.entries.items.len == 0) {
            self.selected = 0;
        } else if (self.selected >= self.entries.items.len) {
            self.selected = self.entries.items.len - 1;
        }
    }

    fn walkDir(self: *FileExplorer, dir_path: []const u8, depth: u16) std.mem.Allocator.Error!void {
        var dir = std.Io.Dir.openDirAbsolute(self.io, dir_path, .{ .iterate = true }) catch return;
        defer dir.close(self.io);

        // Collect entries first so we can sort directories-then-files.
        var local = std.ArrayListUnmanaged(LocalEntry).empty;
        defer {
            for (local.items) |le| self.allocator.free(le.name);
            local.deinit(self.allocator);
        }

        var iter = dir.iterate();
        while (iter.next(self.io) catch null) |entry| {
            if (entry.name.len == 0) continue;
            if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
            if (!self.show_hidden and entry.name[0] == '.') continue;
            const name_dup = try self.allocator.dupe(u8, entry.name);
            try local.append(self.allocator, .{
                .name = name_dup,
                .is_dir = entry.kind == .directory,
            });
        }

        std.mem.sort(LocalEntry, local.items, {}, lessThan);

        for (local.items) |le| {
            const full = try std.fs.path.join(self.allocator, &.{ dir_path, le.name });
            errdefer self.allocator.free(full);
            const is_exp = le.is_dir and self.expanded.contains(full);

            const name_dup = try self.allocator.dupe(u8, le.name);
            errdefer self.allocator.free(name_dup);

            try self.entries.append(self.allocator, .{
                .name = name_dup,
                .path = full,
                .depth = depth,
                .is_dir = le.is_dir,
                .is_expanded = is_exp,
            });

            if (is_exp) try self.walkDir(full, depth + 1);
        }
    }

    const LocalEntry = struct {
        name: []u8,
        is_dir: bool,
    };

    fn lessThan(_: void, a: LocalEntry, b: LocalEntry) bool {
        if (a.is_dir and !b.is_dir) return true;
        if (!a.is_dir and b.is_dir) return false;
        return std.mem.lessThan(u8, a.name, b.name);
    }

    pub fn moveUp(self: *FileExplorer) void {
        if (self.selected > 0) self.selected -= 1;
    }

    pub fn moveDown(self: *FileExplorer) void {
        if (self.entries.items.len == 0) return;
        if (self.selected + 1 < self.entries.items.len) self.selected += 1;
    }

    pub fn moveTop(self: *FileExplorer) void {
        self.selected = 0;
    }

    pub fn moveBottom(self: *FileExplorer) void {
        if (self.entries.items.len > 0) self.selected = self.entries.items.len - 1;
    }

    /// Toggle expansion on the currently-selected directory.
    /// No-op on files. Returns true if the visible list changed
    /// (so the caller knows to rebuild + render).
    pub fn toggleExpand(self: *FileExplorer) !bool {
        if (self.selected >= self.entries.items.len) return false;
        const e = self.entries.items[self.selected];
        if (!e.is_dir) return false;

        if (self.expanded.fetchRemove(e.path)) |kv| {
            self.allocator.free(kv.key);
        } else {
            const key = try self.allocator.dupe(u8, e.path);
            try self.expanded.put(self.allocator, key, {});
        }
        try self.rebuild();
        return true;
    }

    /// Expand if directory and not already expanded; on a file
    /// or already-expanded directory, no-op. Used for `l` / Right.
    pub fn expand(self: *FileExplorer) !bool {
        if (self.selected >= self.entries.items.len) return false;
        const e = self.entries.items[self.selected];
        if (!e.is_dir or e.is_expanded) return false;
        const key = try self.allocator.dupe(u8, e.path);
        try self.expanded.put(self.allocator, key, {});
        try self.rebuild();
        return true;
    }

    /// Collapse the currently-selected directory if expanded; if
    /// the cursor is on a leaf, jump to its containing directory
    /// (and collapse it if expanded). Used for `h` / Left.
    pub fn collapseOrAscend(self: *FileExplorer) !bool {
        if (self.selected >= self.entries.items.len) return false;
        const e = self.entries.items[self.selected];

        if (e.is_dir and e.is_expanded) {
            if (self.expanded.fetchRemove(e.path)) |kv| self.allocator.free(kv.key);
            try self.rebuild();
            return true;
        }

        // Jump to parent. Find a same-or-lower-depth-ancestor
        // above the current row.
        if (e.depth == 0) return false;
        const target_depth: u16 = e.depth - 1;
        var i: usize = self.selected;
        while (i > 0) {
            i -= 1;
            if (self.entries.items[i].depth == target_depth) {
                self.selected = i;
                return true;
            }
        }
        return false;
    }

    /// If the selection is a file, return its path (caller owns).
    /// If it's a directory, toggle expansion and return null.
    pub fn activate(self: *FileExplorer) !?[]u8 {
        if (self.selected >= self.entries.items.len) return null;
        const e = self.entries.items[self.selected];
        if (e.is_dir) {
            _ = try self.toggleExpand();
            return null;
        }
        return try self.allocator.dupe(u8, e.path);
    }

    pub fn toggleHidden(self: *FileExplorer) !void {
        self.show_hidden = !self.show_hidden;
        try self.rebuild();
    }

    /// Snapshot for the render thread. Allocates from `out_allocator`
    /// (typically the per-frame arena), so caller owns nothing
    /// past the frame.
    pub fn snapshot(self: *const FileExplorer, out_allocator: Allocator) ![]protocol.ExplorerEntry {
        const out = try out_allocator.alloc(protocol.ExplorerEntry, self.entries.items.len);
        for (self.entries.items, 0..) |e, i| {
            out[i] = .{
                .name = try out_allocator.dupe(u8, e.name),
                .path = try out_allocator.dupe(u8, e.path),
                .depth = e.depth,
                .is_dir = e.is_dir,
                .is_expanded = e.is_expanded,
            };
        }
        return out;
    }
};

const test_utils = @import("../test_utils.zig");

test "FileExplorer rebuilds on empty dir" {
    const a = std.testing.allocator;
    var test_io = test_utils.TestIo.init(a);
    defer test_io.deinit();
    var tmp = try test_utils.Tempdir.init(a);
    defer tmp.deinit();

    var fx = try FileExplorer.init(a, test_io.io(), tmp.path);
    defer fx.deinit();
    try fx.rebuild();
    try std.testing.expectEqual(@as(usize, 0), fx.entries.items.len);
}

test "FileExplorer lists files and folders, dirs first" {
    const a = std.testing.allocator;
    var test_io = test_utils.TestIo.init(a);
    defer test_io.deinit();
    var tmp = try test_utils.Tempdir.init(a);
    defer tmp.deinit();

    try tmp.writeFile("z_file.txt", "x");
    try tmp.writeFile("a_file.txt", "x");
    try tmp.makeDir("zdir");
    try tmp.makeDir("adir");

    var fx = try FileExplorer.init(a, test_io.io(), tmp.path);
    defer fx.deinit();
    try fx.rebuild();

    try std.testing.expectEqual(@as(usize, 4), fx.entries.items.len);
    // Directories first, alphabetical within group.
    try std.testing.expectEqualStrings("adir", fx.entries.items[0].name);
    try std.testing.expect(fx.entries.items[0].is_dir);
    try std.testing.expectEqualStrings("zdir", fx.entries.items[1].name);
    try std.testing.expect(fx.entries.items[1].is_dir);
    try std.testing.expectEqualStrings("a_file.txt", fx.entries.items[2].name);
    try std.testing.expect(!fx.entries.items[2].is_dir);
    try std.testing.expectEqualStrings("z_file.txt", fx.entries.items[3].name);
}

test "FileExplorer expand walks children" {
    const a = std.testing.allocator;
    var test_io = test_utils.TestIo.init(a);
    defer test_io.deinit();
    var tmp = try test_utils.Tempdir.init(a);
    defer tmp.deinit();

    try tmp.makeDir("sub");
    try tmp.writeFile("sub/child.txt", "y");

    var fx = try FileExplorer.init(a, test_io.io(), tmp.path);
    defer fx.deinit();
    try fx.rebuild();

    try std.testing.expectEqual(@as(usize, 1), fx.entries.items.len);
    try std.testing.expectEqualStrings("sub", fx.entries.items[0].name);

    fx.selected = 0;
    _ = try fx.toggleExpand();
    try std.testing.expectEqual(@as(usize, 2), fx.entries.items.len);
    try std.testing.expectEqualStrings("child.txt", fx.entries.items[1].name);
    try std.testing.expectEqual(@as(u16, 1), fx.entries.items[1].depth);

    // Collapsing returns to a single visible entry.
    fx.selected = 0;
    _ = try fx.toggleExpand();
    try std.testing.expectEqual(@as(usize, 1), fx.entries.items.len);
}
