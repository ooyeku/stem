//! Named bookmarks: 26 slots `a..z`, each pointing at a file + cursor
//! position. `mx` sets slot `x`, `'x` jumps to it. Persisted per-project
//! to `~/.stem/cache/bookmarks/<hash>.json` so they survive restart.

const std = @import("std");

pub const Bookmark = struct {
    file_path: []const u8,
    row: usize,
    col: usize,
    /// ms since epoch, used to sort the list view newest-first.
    timestamp: i64,
};

pub const BookmarkStore = struct {
    allocator: std.mem.Allocator,
    /// Index is slot - 'a'. `null` = unset.
    slots: [26]?Bookmark = [_]?Bookmark{null} ** 26,
    /// Absolute path to the persistence file for the current project.
    /// `null` until `attachProject` is called.
    persist_path: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator) BookmarkStore {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *BookmarkStore) void {
        for (&self.slots) |*slot_ptr| {
            if (slot_ptr.*) |*bm| self.allocator.free(bm.file_path);
            slot_ptr.* = null;
        }
        if (self.persist_path) |p| self.allocator.free(p);
        self.persist_path = null;
    }

    fn slotIndex(slot: u8) ?usize {
        if (slot >= 'a' and slot <= 'z') return @intCast(slot - 'a');
        return null;
    }

    pub fn set(
        self: *BookmarkStore,
        slot: u8,
        file_path: []const u8,
        row: usize,
        col: usize,
        now_ms: i64,
    ) !void {
        const idx = slotIndex(slot) orelse return error.InvalidBookmarkSlot;
        if (self.slots[idx]) |*old| self.allocator.free(old.file_path);
        self.slots[idx] = .{
            .file_path = try self.allocator.dupe(u8, file_path),
            .row = row,
            .col = col,
            .timestamp = now_ms,
        };
    }

    pub fn get(self: *BookmarkStore, slot: u8) ?Bookmark {
        const idx = slotIndex(slot) orelse return null;
        return self.slots[idx];
    }

    pub fn remove(self: *BookmarkStore, slot: u8) bool {
        const idx = slotIndex(slot) orelse return false;
        if (self.slots[idx]) |*old| {
            self.allocator.free(old.file_path);
            self.slots[idx] = null;
            return true;
        }
        return false;
    }

    pub fn clearAll(self: *BookmarkStore) void {
        for (&self.slots) |*slot_ptr| {
            if (slot_ptr.*) |*old| self.allocator.free(old.file_path);
            slot_ptr.* = null;
        }
    }

    /// Number of occupied slots.
    pub fn count(self: *BookmarkStore) usize {
        var n: usize = 0;
        for (self.slots) |slot| {
            if (slot != null) n += 1;
        }
        return n;
    }

    /// Bind to a project root. Computes the persistence file path and
    /// best-effort-loads any pre-existing bookmark file. Failing to load
    /// is non-fatal — we just start with an empty store.
    pub fn attachProject(self: *BookmarkStore, io: std.Io, home_dir: []const u8, project_root: []const u8) !void {
        if (self.persist_path) |p| self.allocator.free(p);
        self.persist_path = try buildPersistPath(self.allocator, home_dir, project_root);
        // Pre-create the parent dir so save can blindly write.
        if (std.fs.path.dirname(self.persist_path.?)) |dir_path| {
            std.Io.Dir.cwd().createDirPath(io, dir_path) catch {};
        }
        self.load(io) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    /// Save bookmarks to disk. Atomic: writes to .tmp then renames.
    pub fn save(self: *BookmarkStore, io: std.Io) !void {
        const path = self.persist_path orelse return;

        var json = std.ArrayListUnmanaged(u8).empty;
        defer json.deinit(self.allocator);

        try json.appendSlice(self.allocator, "{\n  \"bookmarks\": [\n");
        var first = true;
        for (self.slots, 0..) |slot, i| {
            if (slot) |bm| {
                if (!first) try json.appendSlice(self.allocator, ",\n");
                first = false;
                const slot_char: u8 = @intCast('a' + i);
                var prefix_buf: [64]u8 = undefined;
                const prefix = try std.fmt.bufPrint(&prefix_buf, "    {{\"slot\": \"{c}\", \"file\": \"", .{slot_char});
                try json.appendSlice(self.allocator, prefix);
                try appendJsonEscaped(self.allocator, &json, bm.file_path);
                var suffix_buf: [128]u8 = undefined;
                const suffix = try std.fmt.bufPrint(&suffix_buf, "\", \"row\": {d}, \"col\": {d}, \"ts\": {d}}}", .{ bm.row, bm.col, bm.timestamp });
                try json.appendSlice(self.allocator, suffix);
            }
        }
        try json.appendSlice(self.allocator, "\n  ]\n}\n");

        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{path});
        defer self.allocator.free(tmp_path);
        {
            var file = try std.Io.Dir.createFileAbsolute(io, tmp_path, .{});
            defer file.close(io);
            try file.writePositionalAll(io, json.items, 0);
        }
        try std.Io.Dir.renameAbsolute(tmp_path, path, io);
    }

    fn appendJsonEscaped(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
        for (s) |c| {
            switch (c) {
                '"' => try out.appendSlice(allocator, "\\\""),
                '\\' => try out.appendSlice(allocator, "\\\\"),
                '\n' => try out.appendSlice(allocator, "\\n"),
                '\r' => try out.appendSlice(allocator, "\\r"),
                '\t' => try out.appendSlice(allocator, "\\t"),
                else => try out.append(allocator, c),
            }
        }
    }

    pub fn load(self: *BookmarkStore, io: std.Io) !void {
        const path = self.persist_path orelse return;
        const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
        defer file.close(io);
        const max_size: usize = 64 * 1024;
        const stat = try file.stat(io);
        const size = @min(stat.size, max_size);
        const bytes = try self.allocator.alloc(u8, @intCast(size));
        defer self.allocator.free(bytes);
        const n = try file.readPositionalAll(io, bytes, 0);
        try self.parseAndPopulate(bytes[0..n]);
    }

    fn parseAndPopulate(self: *BookmarkStore, json_text: []const u8) !void {
        // Minimal hand-rolled parser: we wrote the file, so the shape is
        // fixed. Avoids pulling std.json into the kernel surface.
        var i: usize = 0;
        while (i < json_text.len) {
            // Skip to next `{"slot":` marker.
            const slot_marker = "\"slot\":";
            if (i + slot_marker.len > json_text.len) break;
            if (!std.mem.eql(u8, json_text[i .. i + slot_marker.len], slot_marker)) {
                i += 1;
                continue;
            }
            // Slot value: next quoted char.
            i = std.mem.indexOfScalarPos(u8, json_text, i, '"') orelse break;
            i = std.mem.indexOfScalarPos(u8, json_text, i + 1, '"') orelse break;
            if (i + 2 >= json_text.len) break;
            const slot_char: u8 = json_text[i + 1];

            const file_key = std.mem.indexOfPos(u8, json_text, i, "\"file\":") orelse break;
            i = std.mem.indexOfScalarPos(u8, json_text, file_key + 7, '"') orelse break;
            const file_start = i + 1;
            // Find end quote, handle \" escapes.
            var j = file_start;
            while (j < json_text.len) : (j += 1) {
                if (json_text[j] == '\\' and j + 1 < json_text.len) {
                    j += 1;
                    continue;
                }
                if (json_text[j] == '"') break;
            }
            if (j >= json_text.len) break;
            const file_raw = json_text[file_start..j];
            i = j + 1;

            const row_key = std.mem.indexOfPos(u8, json_text, i, "\"row\":") orelse break;
            const row_start = row_key + 6;
            const row_end = std.mem.indexOfAnyPos(u8, json_text, row_start, ",}") orelse break;
            const row = std.fmt.parseInt(usize, std.mem.trim(u8, json_text[row_start..row_end], " "), 10) catch {
                i = row_end;
                continue;
            };

            const col_key = std.mem.indexOfPos(u8, json_text, row_end, "\"col\":") orelse break;
            const col_start = col_key + 6;
            const col_end = std.mem.indexOfAnyPos(u8, json_text, col_start, ",}") orelse break;
            const col = std.fmt.parseInt(usize, std.mem.trim(u8, json_text[col_start..col_end], " "), 10) catch {
                i = col_end;
                continue;
            };

            const ts_key = std.mem.indexOfPos(u8, json_text, col_end, "\"ts\":") orelse break;
            const ts_start = ts_key + 5;
            const ts_end = std.mem.indexOfAnyPos(u8, json_text, ts_start, ",}") orelse break;
            const ts = std.fmt.parseInt(i64, std.mem.trim(u8, json_text[ts_start..ts_end], " "), 10) catch 0;

            const unescaped = try unescapeJsonString(self.allocator, file_raw);
            defer self.allocator.free(unescaped);
            self.set(slot_char, unescaped, row, col, ts) catch {};
            i = ts_end;
        }
    }

    fn unescapeJsonString(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
        var out = std.ArrayListUnmanaged(u8).empty;
        defer out.deinit(allocator);
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            if (s[i] == '\\' and i + 1 < s.len) {
                switch (s[i + 1]) {
                    'n' => try out.append(allocator, '\n'),
                    't' => try out.append(allocator, '\t'),
                    'r' => try out.append(allocator, '\r'),
                    '"' => try out.append(allocator, '"'),
                    '\\' => try out.append(allocator, '\\'),
                    '/' => try out.append(allocator, '/'),
                    else => {
                        try out.append(allocator, s[i]);
                        try out.append(allocator, s[i + 1]);
                    },
                }
                i += 1;
            } else {
                try out.append(allocator, s[i]);
            }
        }
        return out.toOwnedSlice(allocator);
    }

    fn buildPersistPath(allocator: std.mem.Allocator, home_dir: []const u8, project_root: []const u8) ![]u8 {
        // Stable-ish per-project key: full project path → 64-bit hash → hex.
        // Collisions theoretically possible but practically negligible.
        var h = std.hash.Wyhash.init(0);
        h.update(project_root);
        const digest = h.final();
        return std.fmt.allocPrint(
            allocator,
            "{s}/.stem/cache/bookmarks/{x}.json",
            .{ home_dir, digest },
        );
    }
};

test "bookmark store set/get/remove" {
    const allocator = std.testing.allocator;
    var store = BookmarkStore.init(allocator);
    defer store.deinit();

    try store.set('a', "/foo/bar.zig", 10, 5, 1000);
    const bm = store.get('a').?;
    try std.testing.expectEqual(@as(usize, 10), bm.row);
    try std.testing.expectEqual(@as(usize, 5), bm.col);
    try std.testing.expectEqualStrings("/foo/bar.zig", bm.file_path);
    try std.testing.expect(store.remove('a'));
    try std.testing.expect(store.get('a') == null);
}

test "bookmark store rejects out-of-range slots" {
    const allocator = std.testing.allocator;
    var store = BookmarkStore.init(allocator);
    defer store.deinit();
    try std.testing.expectError(error.InvalidBookmarkSlot, store.set('1', "x", 0, 0, 0));
    try std.testing.expectError(error.InvalidBookmarkSlot, store.set('A', "x", 0, 0, 0));
}

test "bookmark store overwrites existing slot" {
    const allocator = std.testing.allocator;
    var store = BookmarkStore.init(allocator);
    defer store.deinit();
    try store.set('a', "/a", 1, 1, 1);
    try store.set('a', "/b", 2, 2, 2);
    const bm = store.get('a').?;
    try std.testing.expectEqualStrings("/b", bm.file_path);
    try std.testing.expectEqual(@as(usize, 2), bm.row);
}

test "bookmark store clearAll" {
    const allocator = std.testing.allocator;
    var store = BookmarkStore.init(allocator);
    defer store.deinit();
    try store.set('a', "/a", 0, 0, 0);
    try store.set('b', "/b", 0, 0, 0);
    try std.testing.expectEqual(@as(usize, 2), store.count());
    store.clearAll();
    try std.testing.expectEqual(@as(usize, 0), store.count());
}
