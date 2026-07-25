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

/// On-disk format version. Bumped only for breaking layout changes;
/// `parseSession` accepts any version it can read field-wise.
pub const format_version = 1;

/// Serialize the session to owned JSON bytes, or null when there are no
/// file-backed buffers worth persisting. Caller frees the returned slice.
/// Shared by the direct file save below and the Vigil checkpoint pipeline.
pub fn serialize(
    allocator: std.mem.Allocator,
    buffers: anytype,
    active_index: usize,
    splits_json: ?[]const u8,
) !?[]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var js: std.json.Stringify = .{ .writer = &aw.writer };

    try js.beginObject();
    try js.objectField("version");
    try js.write(format_version);
    try js.objectField("active");
    try js.write(active_index);
    try js.objectField("buffers");
    try js.beginArray();

    var written: usize = 0;
    for (buffers.items) |buf| {
        const path = buf.file_path orelse continue;
        // JSON strings must be valid UTF-8, but Unix paths are arbitrary
        // bytes. Writing one raw would make the *entire* session file
        // unparseable on the next launch, so drop the single offending
        // buffer instead of losing every buffer along with it.
        if (!std.unicode.utf8ValidateSlice(path)) {
            log.warn("Skipping buffer with non-UTF-8 path during session save", .{});
            continue;
        }
        try js.beginObject();
        try js.objectField("path");
        try js.write(path);
        try js.objectField("row");
        try js.write(buf.state.cursor_row);
        try js.objectField("col");
        try js.write(buf.state.cursor_col);
        try js.objectField("scroll");
        try js.write(buf.state.scroll_offset);
        try js.endObject();
        written += 1;
    }
    try js.endArray();

    if (written == 0) {
        aw.deinit();
        return null;
    }

    if (splits_json) |splits| {
        // Embedded verbatim: this is SplitManager's own format, and
        // re-encoding it here would couple the two. Validate first so a
        // malformed layout can't corrupt the whole file — losing the
        // split layout beats losing the buffer list.
        if (std.json.validate(allocator, splits) catch false) {
            try js.objectField("splits");
            try js.beginWriteRaw();
            try aw.writer.writeAll(splits);
            js.endWriteRaw();
        } else {
            log.warn("Dropping malformed splits JSON from session save", .{});
        }
    }

    try js.endObject();
    return try aw.toOwnedSlice();
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

/// Parse the session document. Uses `std.json` rather than scanning for
/// field markers: paths are arbitrary text, so a path containing `"`,
/// `\`, or `}` used to truncate or corrupt the record it lived in — and
/// for an editor whose promise is "a crash never loses your place", a
/// recovery file that can't survive its own filenames is the worst kind
/// of bug.
///
/// Tolerant by design: unreadable individual buffers are skipped rather
/// than failing the whole restore, and out-of-range numbers saturate
/// instead of overflowing. A document that isn't a JSON object at all is
/// an error — both callers fall back to another snapshot on error.
fn parseSession(allocator: std.mem.Allocator, json: []const u8) !Session {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSessionFormat,
    };
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidSessionFormat;
    const root = parsed.value.object;

    var buffers = std.ArrayListUnmanaged(BufferState).empty;
    errdefer {
        for (buffers.items) |b| {
            if (b.file_path) |p| allocator.free(p);
            allocator.free(b.name);
        }
        buffers.deinit(allocator);
    }

    if (root.get("buffers")) |buffers_value| {
        if (buffers_value == .array) {
            for (buffers_value.array.items) |entry| {
                if (entry != .object) continue;
                const path_value = entry.object.get("path") orelse continue;
                if (path_value != .string or path_value.string.len == 0) continue;

                const path_dup = try allocator.dupe(u8, path_value.string);
                errdefer allocator.free(path_dup);
                const name_dup = try allocator.dupe(u8, std.fs.path.basename(path_dup));
                errdefer allocator.free(name_dup);

                try buffers.append(allocator, .{
                    .file_path = path_dup,
                    .cursor_row = numberField(entry.object, "row"),
                    .cursor_col = numberField(entry.object, "col"),
                    .scroll_offset = numberField(entry.object, "scroll"),
                    .is_virtual = false,
                    .name = name_dup,
                });
            }
        }
    }

    // Re-encode the splits subtree back to text for SplitManager, which
    // owns that format. `ObjectMap` preserves insertion order, so the
    // round-trip is faithful.
    var splits_json: ?[]const u8 = null;
    errdefer if (splits_json) |s| allocator.free(s);
    if (root.get("splits")) |splits_value| {
        if (splits_value == .object) {
            splits_json = try std.json.Stringify.valueAlloc(allocator, splits_value, .{});
        }
    }

    return Session{
        .buffers = try buffers.toOwnedSlice(allocator),
        .active_buffer = if (root.get("active")) |v| numberValue(v) else 0,
        .splits_json = splits_json,
    };
}

fn numberField(obj: std.json.ObjectMap, key: []const u8) usize {
    return if (obj.get(key)) |v| numberValue(v) else 0;
}

/// Coerce a JSON number to `usize`, saturating rather than overflowing.
/// Values too large for `i64` arrive as `.number_string`; the old parser
/// wrapped (or panicked in a safe build) on those.
fn numberValue(v: std.json.Value) usize {
    return switch (v) {
        .integer => |i| if (i <= 0) 0 else std.math.cast(usize, i) orelse std.math.maxInt(usize),
        .number_string => |s| if (s.len > 0 and s[0] == '-')
            0
        else
            std.fmt.parseInt(usize, s, 10) catch std.math.maxInt(usize),
        .float => |f| if (!(f > 0))
            0
        else if (f >= @as(f64, @floatFromInt(std.math.maxInt(usize))))
            std.math.maxInt(usize)
        else
            @intFromFloat(f),
        else => 0,
    };
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
    // A document that isn't a JSON object is rejected rather than
    // silently treated as an empty session; both callers fall back to
    // another snapshot when parsing fails.
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

const TestCursor = struct { cursor_row: usize = 0, cursor_col: usize = 0, scroll_offset: usize = 0 };
const TestBuffer = struct { file_path: ?[]const u8, name: []const u8 = "b", state: TestCursor = .{} };
const TestBufferList = struct { items: []const TestBuffer };

test "paths containing JSON metacharacters survive a round-trip" {
    const allocator = std.testing.allocator;
    // Every one of these corrupted or truncated the record under the old
    // marker-scanning parser: `"` ended the path early, `}` ended the
    // object early, and control characters were emitted unescaped.
    const nasty = [_][]const u8{
        "/tmp/with\"quote.zig",
        "/tmp/with\\backslash.zig",
        "/tmp/with}brace.zig",
        "/tmp/with{brace.zig",
        "/tmp/with\nnewline.zig",
        "/tmp/with\ttab.zig",
        "/tmp/with\x01control.zig",
        "/tmp/with-\u{1F600}-emoji.zig",
        "/tmp/\"path\":\"decoy.zig",
    };
    for (nasty) |path| {
        const buffers = TestBufferList{ .items = &.{
            .{ .file_path = path, .state = .{ .cursor_row = 7, .cursor_col = 3 } },
        } };
        const payload = (try serialize(allocator, buffers, 0, null)).?;
        defer allocator.free(payload);

        const s = try parseBytes(allocator, payload);
        defer freeSession(allocator, s);

        try std.testing.expectEqual(@as(usize, 1), s.buffers.len);
        try std.testing.expectEqualStrings(path, s.buffers[0].file_path.?);
        try std.testing.expectEqual(@as(usize, 7), s.buffers[0].cursor_row);
        try std.testing.expectEqual(@as(usize, 3), s.buffers[0].cursor_col);
    }
}

test "a non-UTF-8 path is dropped instead of poisoning the whole session" {
    const allocator = std.testing.allocator;
    const buffers = TestBufferList{ .items = &.{
        .{ .file_path = "/tmp/good.zig" },
        .{ .file_path = "/tmp/bad-\xff-path.zig" },
        .{ .file_path = "/tmp/also-good.zig" },
    } };
    const payload = (try serialize(allocator, buffers, 0, null)).?;
    defer allocator.free(payload);

    const s = try parseBytes(allocator, payload);
    defer freeSession(allocator, s);

    try std.testing.expectEqual(@as(usize, 2), s.buffers.len);
    try std.testing.expectEqualStrings("/tmp/good.zig", s.buffers[0].file_path.?);
    try std.testing.expectEqualStrings("/tmp/also-good.zig", s.buffers[1].file_path.?);
}

test "out-of-range numbers saturate instead of wrapping" {
    const allocator = std.testing.allocator;
    // The old parser accumulated digits into a usize with no bound, which
    // wraps in ReleaseFast and panics in a safe build.
    const json =
        \\{"version":1,"active":999999999999999999999999,"buffers":[
        \\  {"path":"/a.zig","row":999999999999999999999999,"col":-5,"scroll":3}
        \\]}
    ;
    const s = try parseSession(allocator, json);
    defer freeSession(allocator, s);

    try std.testing.expectEqual(std.math.maxInt(usize), s.active_buffer);
    try std.testing.expectEqual(std.math.maxInt(usize), s.buffers[0].cursor_row);
    try std.testing.expectEqual(@as(usize, 0), s.buffers[0].cursor_col);
    try std.testing.expectEqual(@as(usize, 3), s.buffers[0].scroll_offset);
}

test "splits survive a round-trip with braces inside strings" {
    const allocator = std.testing.allocator;
    // Brace-depth counting over raw bytes mis-terminated the splits object
    // whenever a brace appeared inside a string.
    const splits =
        \\{"focused":1,"next_id":2,"label":"a{b}c","root":{"type":"pane","id":1}}
    ;
    const buffers = TestBufferList{ .items = &.{.{ .file_path = "/a.zig" }} };
    const payload = (try serialize(allocator, buffers, 0, splits)).?;
    defer allocator.free(payload);

    const s = try parseBytes(allocator, payload);
    defer freeSession(allocator, s);

    const got = s.splits_json orelse return error.TestExpectedSplits;
    var reparsed = try std.json.parseFromSlice(std.json.Value, allocator, got, .{});
    defer reparsed.deinit();
    try std.testing.expectEqualStrings("a{b}c", reparsed.value.object.get("label").?.string);
    try std.testing.expectEqual(@as(i64, 1), reparsed.value.object.get("focused").?.integer);
    try std.testing.expect(reparsed.value.object.get("root").? == .object);
}

test "malformed splits are dropped without taking the buffers down" {
    const allocator = std.testing.allocator;
    const buffers = TestBufferList{ .items = &.{.{ .file_path = "/a.zig" }} };
    const payload = (try serialize(allocator, buffers, 0, "{not valid json")).?;
    defer allocator.free(payload);

    const s = try parseBytes(allocator, payload);
    defer freeSession(allocator, s);

    try std.testing.expectEqual(@as(usize, 1), s.buffers.len);
    try std.testing.expectEqual(@as(?[]const u8, null), s.splits_json);
}

test "a real split layout round-trips back into SplitManager" {
    const allocator = std.testing.allocator;
    const SplitManager = @import("split_manager.zig").SplitManager;

    var sm = try SplitManager.init(allocator, 0);
    defer sm.deinit();
    const original = try sm.toJson(allocator);
    defer allocator.free(original);

    const buffers = TestBufferList{ .items = &.{.{ .file_path = "/a.zig" }} };
    const payload = (try serialize(allocator, buffers, 0, original)).?;
    defer allocator.free(payload);

    const s = try parseBytes(allocator, payload);
    defer freeSession(allocator, s);

    // Splits are re-encoded on the way out, so prove the consumer can
    // still read what we hand back.
    var restored = try SplitManager.initFromJson(allocator, s.splits_json.?);
    defer restored.deinit();
    try std.testing.expectEqual(sm.focused_pane_id, restored.focused_pane_id);
    try std.testing.expectEqual(sm.next_pane_id, restored.next_pane_id);
}
