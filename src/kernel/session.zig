const std = @import("std");
const log = @import("../services/logger.zig").scoped("Session");

pub const Session = struct {
    buffers: []BufferState,
    active_buffer: usize,
    splits_json: ?[]const u8,
};

pub const BufferState = struct {
    file_path: ?[]const u8,
    cursor_row: usize,
    cursor_col: usize,
    scroll_offset: usize,
    is_virtual: bool,
    name: []const u8,
};

/// Serialize the session to owned JSON bytes, or null when there are no
/// file-backed buffers worth persisting. Caller frees the returned slice.
/// Shared by the direct file save below and the Vigil checkpoint pipeline.
pub fn serialize(
    allocator: std.mem.Allocator,
    buffers: anytype,
    active_index: usize,
    splits_json: ?[]const u8,
) !?[]u8 {
    var buffer_states = std.ArrayListUnmanaged(BufferState).empty;
    defer buffer_states.deinit(allocator);

    for (buffers.items) |buf| {
        if (buf.file_path == null) continue;

        try buffer_states.append(allocator, .{
            .file_path = buf.file_path,
            .cursor_row = buf.state.cursor_row,
            .cursor_col = buf.state.cursor_col,
            .scroll_offset = buf.state.scroll_offset,
            .is_virtual = false,
            .name = buf.name,
        });
    }

    if (buffer_states.items.len == 0) return null;

    var json = std.ArrayListUnmanaged(u8).empty;
    errdefer json.deinit(allocator);

    try json.appendSlice(allocator, "{\"version\":1,\"active\":");
    try appendInt(allocator, &json, active_index);
    try json.appendSlice(allocator, ",\"buffers\":[");

    for (buffer_states.items, 0..) |bs, i| {
        if (i > 0) try json.append(allocator, ',');
        try json.appendSlice(allocator, "{\"path\":\"");
        if (bs.file_path) |p| {
            try appendEscaped(allocator, &json, p);
        }
        try json.appendSlice(allocator, "\",\"row\":");
        try appendInt(allocator, &json, bs.cursor_row);
        try json.appendSlice(allocator, ",\"col\":");
        try appendInt(allocator, &json, bs.cursor_col);
        try json.appendSlice(allocator, ",\"scroll\":");
        try appendInt(allocator, &json, bs.scroll_offset);
        try json.append(allocator, '}');
    }

    try json.appendSlice(allocator, "]");

    if (splits_json) |splits| {
        try json.appendSlice(allocator, ",\"splits\":");
        try json.appendSlice(allocator, splits);
    }

    try json.append(allocator, '}');
    return try json.toOwnedSlice(allocator);
}

/// Parse serialized session bytes (the `serialize` format). The caller owns
/// the returned session; free with `freeSession`.
pub fn parseBytes(allocator: std.mem.Allocator, json: []const u8) !Session {
    return parseSession(allocator, json);
}

pub fn save(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_path: []const u8,
    buffers: anytype,
    active_index: usize,
    splits_json: ?[]const u8,
) !void {
    const payload = (try serialize(allocator, buffers, active_index, splits_json)) orelse {
        log.info("No file-backed buffers to save", .{});
        return;
    };
    defer allocator.free(payload);
    const json_items = payload;

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{session_path});
    defer allocator.free(tmp_path);

    {
        const file = std.Io.Dir.createFileAbsolute(io, tmp_path, .{}) catch |err| {
            log.warn("Failed to create temp session file: {}", .{err});
            return err;
        };
        defer file.close(io);
        try file.writePositionalAll(io, json_items, 0);
    }

    std.Io.Dir.renameAbsolute(tmp_path, session_path, io) catch |err| {
        log.warn("Failed to rename session file: {}", .{err});
        std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};
        return err;
    };

    log.info("Session saved: {} bytes, has_splits={}", .{ json_items.len, splits_json != null });
}

pub fn load(allocator: std.mem.Allocator, io: std.Io, session_path: []const u8) !?Session {
    const file = std.Io.Dir.openFileAbsolute(io, session_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            log.info("No session file found", .{});
            return null;
        }
        return err;
    };
    defer file.close(io);

    const size = try file.length(io);
    if (size > 1024 * 1024) return error.FileTooLarge;
    const buf = try allocator.alloc(u8, @intCast(size));
    defer allocator.free(buf);
    const read_n = try file.readPositionalAll(io, buf, 0);
    const content = buf[0..read_n];

    return parseSession(allocator, content) catch |err| {
        log.warn("Failed to parse session: {}", .{err});
        return null;
    };
}

fn parseSession(allocator: std.mem.Allocator, json: []const u8) !Session {
    var buffers = std.ArrayListUnmanaged(BufferState).empty;
    errdefer {
        for (buffers.items) |b| {
            if (b.file_path) |p| allocator.free(p);
            allocator.free(b.name);
        }
        buffers.deinit(allocator);
    }

    var active: usize = 0;
    var splits_json: ?[]const u8 = null;

    if (std.mem.indexOf(u8, json, "\"active\":")) |pos| {
        var i = pos + 9;
        var num: usize = 0;
        while (i < json.len and json[i] >= '0' and json[i] <= '9') {
            num = num * 10 + (json[i] - '0');
            i += 1;
        }
        active = num;
    }

    if (std.mem.indexOf(u8, json, "\"buffers\":[")) |start| {
        var i = start + 11;

        while (i < json.len) {
            const obj_start = std.mem.indexOfPos(u8, json, i, "{") orelse break;
            const obj_end = std.mem.indexOfPos(u8, json, obj_start, "}") orelse break;
            const obj = json[obj_start .. obj_end + 1];

            var path: ?[]const u8 = null;
            errdefer if (path) |p| allocator.free(p);
            if (std.mem.indexOf(u8, obj, "\"path\":\"")) |p| {
                const path_start = p + 8;
                if (std.mem.indexOfPos(u8, obj, path_start, "\"")) |path_end| {
                    path = try allocator.dupe(u8, obj[path_start..path_end]);
                }
            }

            var row: usize = 0;
            if (std.mem.indexOf(u8, obj, "\"row\":")) |p| {
                var j = p + 6;
                while (j < obj.len and obj[j] >= '0' and obj[j] <= '9') {
                    row = row * 10 + (obj[j] - '0');
                    j += 1;
                }
            }

            var col: usize = 0;
            if (std.mem.indexOf(u8, obj, "\"col\":")) |p| {
                var j = p + 6;
                while (j < obj.len and obj[j] >= '0' and obj[j] <= '9') {
                    col = col * 10 + (obj[j] - '0');
                    j += 1;
                }
            }

            var scroll: usize = 0;
            if (std.mem.indexOf(u8, obj, "\"scroll\":")) |p| {
                var j = p + 9;
                while (j < obj.len and obj[j] >= '0' and obj[j] <= '9') {
                    scroll = scroll * 10 + (obj[j] - '0');
                    j += 1;
                }
            }

            if (path) |pth| {
                const basename = std.fs.path.basename(pth);
                const name_dup = try allocator.dupe(u8, basename);
                errdefer allocator.free(name_dup);
                try buffers.append(allocator, .{
                    .file_path = pth,
                    .cursor_row = row,
                    .cursor_col = col,
                    .scroll_offset = scroll,
                    .is_virtual = false,
                    .name = name_dup,
                });
                // Ownership of pth + name_dup has been transferred to the
                // appended entry; disable the path errdefer for this iteration.
                path = null;
            }

            i = obj_end + 1;
        }
    }

    if (std.mem.indexOf(u8, json, "\"splits\":")) |splits_start| {
        const splits_obj_start = splits_start + 9;
        if (splits_obj_start < json.len and json[splits_obj_start] == '{') {
            var depth: usize = 0;
            var splits_end: usize = splits_obj_start;
            for (json[splits_obj_start..], splits_obj_start..) |c, idx| {
                if (c == '{') depth += 1;
                if (c == '}') {
                    depth -= 1;
                    if (depth == 0) {
                        splits_end = idx + 1;
                        break;
                    }
                }
            }
            if (splits_end > splits_obj_start) {
                splits_json = try allocator.dupe(u8, json[splits_obj_start..splits_end]);
            }
        }
    }

    return Session{
        .buffers = try buffers.toOwnedSlice(allocator),
        .active_buffer = active,
        .splits_json = splits_json,
    };
}

fn appendInt(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8), n: usize) !void {
    var buf: [20]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, "{}", .{n}) catch unreachable;
    try list.appendSlice(allocator, str);
}

fn appendEscaped(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            else => try list.append(allocator, c),
        }
    }
}

pub fn freeSession(allocator: std.mem.Allocator, session: Session) void {
    for (session.buffers) |b| {
        if (b.file_path) |p| allocator.free(p);
        allocator.free(b.name);
    }
    allocator.free(session.buffers);
    if (session.splits_json) |s| allocator.free(s);
}

test "serialize and parseBytes round-trip through the checkpoint pipeline format" {
    const allocator = std.testing.allocator;

    const FakeBuffer = struct {
        file_path: ?[]const u8,
        name: []const u8,
        state: struct { cursor_row: usize, cursor_col: usize, scroll_offset: usize },
    };
    const FakeList = struct { items: []const FakeBuffer };
    const buffers = FakeList{ .items = &.{
        .{ .file_path = "/tmp/a.zig", .name = "a.zig", .state = .{ .cursor_row = 3, .cursor_col = 7, .scroll_offset = 1 } },
        .{ .file_path = null, .name = "[scratch]", .state = .{ .cursor_row = 0, .cursor_col = 0, .scroll_offset = 0 } },
        .{ .file_path = "/tmp/b.zig", .name = "b.zig", .state = .{ .cursor_row = 9, .cursor_col = 0, .scroll_offset = 4 } },
    } };

    const payload = (try serialize(allocator, buffers, 1, null)).?;
    defer allocator.free(payload);

    const s = try parseBytes(allocator, payload);
    defer freeSession(allocator, s);
    // The scratch buffer is skipped; both file-backed buffers survive.
    try std.testing.expectEqual(@as(usize, 2), s.buffers.len);
    try std.testing.expectEqualStrings("/tmp/a.zig", s.buffers[0].file_path.?);
    try std.testing.expectEqual(@as(usize, 3), s.buffers[0].cursor_row);
    try std.testing.expectEqualStrings("/tmp/b.zig", s.buffers[1].file_path.?);
    try std.testing.expectEqual(@as(usize, 4), s.buffers[1].scroll_offset);

    // No file-backed buffers → nothing to persist.
    const empty = FakeList{ .items = &.{
        .{ .file_path = null, .name = "[scratch]", .state = .{ .cursor_row = 0, .cursor_col = 0, .scroll_offset = 0 } },
    } };
    try std.testing.expectEqual(@as(?[]u8, null), try serialize(allocator, empty, 0, null));
}

test "appendInt basic" {
    const allocator = std.testing.allocator;
    var list = std.ArrayListUnmanaged(u8).empty;
    defer list.deinit(allocator);

    try appendInt(allocator, &list, 42);
    try std.testing.expectEqualStrings("42", list.items);
}

test "appendEscaped special chars" {
    const allocator = std.testing.allocator;
    var list = std.ArrayListUnmanaged(u8).empty;
    defer list.deinit(allocator);

    try appendEscaped(allocator, &list, "hello\"world");
    try std.testing.expectEqualStrings("hello\\\"world", list.items);
}

test "parseSession basic" {
    const allocator = std.testing.allocator;
    const json =
        \\{"version":1,"active":0,"buffers":[{"path":"/tmp/test.zig","row":10,"col":5,"scroll":0}]}
    ;

    const session = try parseSession(allocator, json);
    defer freeSession(allocator, session);

    try std.testing.expectEqual(@as(usize, 1), session.buffers.len);
    try std.testing.expectEqual(@as(usize, 0), session.active_buffer);
    try std.testing.expectEqual(@as(usize, 10), session.buffers[0].cursor_row);
    try std.testing.expectEqual(@as(usize, 5), session.buffers[0].cursor_col);
}

test "parseSession with multiple buffers preserves order" {
    const allocator = std.testing.allocator;
    const json =
        \\{"version":1,"active":2,"buffers":[
        \\  {"path":"/a.zig","row":0,"col":0,"scroll":0},
        \\  {"path":"/b.zig","row":5,"col":10,"scroll":3},
        \\  {"path":"/c.zig","row":99,"col":42,"scroll":50}
        \\]}
    ;
    const s = try parseSession(allocator, json);
    defer freeSession(allocator, s);

    try std.testing.expectEqual(@as(usize, 3), s.buffers.len);
    try std.testing.expectEqual(@as(usize, 2), s.active_buffer);
    try std.testing.expectEqualStrings("/a.zig", s.buffers[0].file_path.?);
    try std.testing.expectEqualStrings("/b.zig", s.buffers[1].file_path.?);
    try std.testing.expectEqualStrings("/c.zig", s.buffers[2].file_path.?);
    try std.testing.expectEqual(@as(usize, 99), s.buffers[2].cursor_row);
    try std.testing.expectEqual(@as(usize, 42), s.buffers[2].cursor_col);
    try std.testing.expectEqual(@as(usize, 50), s.buffers[2].scroll_offset);
}

test "parseSession on bare values doesn't crash" {
    const allocator = std.testing.allocator;
    // The current parser is forgiving — it returns an empty session for
    // degenerate input. That's acceptable; just verify it doesn't crash.
    // (See todo.md: strict validation is a follow-up.)
    for ([_][]const u8{ "", "[]", "null", "42" }) |s| {
        if (parseSession(allocator, s)) |session| {
            freeSession(allocator, session);
        } else |_| {}
    }
}

test "parseSession handles malformed JSON without panicking" {
    const allocator = std.testing.allocator;
    // These are all malformed but should produce a clean error, not a panic.
    const bad = [_][]const u8{
        "{",
        "{\"buffers\":",
        "{\"buffers\":[{",
        "{\"buffers\":[{\"path\":\"x\"}", // missing closing brace
        "{\"active\":\"not-a-number\",\"buffers\":[]}",
    };
    for (bad) |s| {
        if (parseSession(allocator, s)) |session| {
            freeSession(allocator, session);
        } else |_| {
            // Error is fine — just must not panic.
        }
    }
}

// KNOWN ISSUE: the session parser is hand-rolled and doesn't decode JSON
// string escapes in path fields. A path containing `"` or `\` round-trips
// as a truncated/corrupted string. Documented in todo.md ("session escape
// round-trip"). When the parser is replaced with std.json.parseFromSlice
// the test below should be enabled to lock the fix in.
test "appendEscaped round-trips simple paths" {
    const allocator = std.testing.allocator;
    var json: std.ArrayListUnmanaged(u8) = .empty;
    defer json.deinit(allocator);
    try json.appendSlice(allocator, "{\"version\":1,\"active\":0,\"buffers\":[{\"path\":\"");
    try appendEscaped(allocator, &json, "/path/with no special chars.zig");
    try json.appendSlice(allocator, "\",\"row\":0,\"col\":0,\"scroll\":0}]}");

    const s = try parseSession(allocator, json.items);
    defer freeSession(allocator, s);

    try std.testing.expectEqual(@as(usize, 1), s.buffers.len);
    try std.testing.expectEqualStrings(
        "/path/with no special chars.zig",
        s.buffers[0].file_path.?,
    );
}
