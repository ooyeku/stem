const std = @import("std");
const stem = @import("stem");
const EditorState = stem.state.EditorState;
const TestIo = stem.test_utils.TestIo;

const FuzzContext = struct {
    allocator: std.mem.Allocator,
};

fn fuzzBytes(smith: *std.testing.Smith, buf: *[512]u8) []const u8 {
    const len: usize = @intCast(smith.slice(buf));
    return buf[0..len];
}

fn fuzzCursorPositions(ctx: FuzzContext, input: []const u8) anyerror!void {
    if (input.len < 4) return;

    const content_len = @min(input.len / 2, 100);
    const content = input[0..content_len];
    const ops = input[content_len..];

    var io_ctx = TestIo.init(ctx.allocator);
    defer io_ctx.deinit();

    var state = try EditorState.init(ctx.allocator, io_ctx.io(), content);
    defer state.deinit();

    var i: usize = 0;
    while (i + 1 < ops.len) : (i += 2) {
        const row_seed = ops[i];
        const col_seed = ops[i + 1];

        const line_count = state.buffer.lineCount();
        if (line_count > 0) {
            state.cursor_row = @as(usize, row_seed) % line_count;
            state.cursor_col = @as(usize, col_seed) % 100;

            _ = state.getOffsetFromCursor();
        }
    }
}

fn fuzzCharacterInsertion(ctx: FuzzContext, input: []const u8) anyerror!void {
    var io_ctx = TestIo.init(ctx.allocator);
    defer io_ctx.deinit();

    var state = try EditorState.init(ctx.allocator, io_ctx.io(), "");
    defer state.deinit();

    const max_inserts = @min(input.len, 500);

    for (input[0..max_inserts]) |char| {
        if (char >= 32 and char < 127) {
            state.insertChar(char) catch {};
        } else if (char == '\n') {
            state.insertNewline() catch {};
        }

        const line_count = state.buffer.lineCount();
        if (line_count > 0 and state.cursor_row >= line_count) {
            state.cursor_row = line_count - 1;
        }
    }

    const content = state.buffer.toString(ctx.allocator) catch return;
    defer ctx.allocator.free(content);
}

fn fuzzDeletions(ctx: FuzzContext, input: []const u8) anyerror!void {
    if (input.len < 2) return;

    var io_ctx = TestIo.init(ctx.allocator);
    defer io_ctx.deinit();

    var state = try EditorState.init(ctx.allocator, io_ctx.io(), input);
    defer state.deinit();

    for (input) |op| {
        const total = state.buffer.totalLength();
        if (total == 0) break;

        switch (op % 2) {
            0 => state.deleteChar() catch {},
            1 => {
                const line_count = state.buffer.lineCount();
                if (line_count > 0) {
                    state.cursor_row = @as(usize, op) % line_count;
                }
            },
            else => {},
        }
    }
}

fn fuzzLineCounting(ctx: FuzzContext, input: []const u8) anyerror!void {
    var content_buf: [200]u8 = undefined;
    var content_len: usize = 0;
    for (input) |c| {
        if (content_len >= content_buf.len - 1) break;
        if (c % 5 == 0) {
            content_buf[content_len] = '\n';
        } else {
            content_buf[content_len] = if (c >= 32 and c < 127) c else 'x';
        }
        content_len += 1;
    }

    var io_ctx = TestIo.init(ctx.allocator);
    defer io_ctx.deinit();

    var state = try EditorState.init(ctx.allocator, io_ctx.io(), content_buf[0..content_len]);
    defer state.deinit();

    const line_count = state.buffer.lineCount();
    try std.testing.expect(line_count >= 1);

    for (input) |op| {
        if (line_count > 0) {
            state.cursor_row = @as(usize, op) % line_count;
            _ = state.getOffsetFromCursor();
        }
    }
}

fn fuzzCursorPositionsSmith(ctx: FuzzContext, smith: *std.testing.Smith) anyerror!void {
    var buf: [512]u8 = undefined;
    try fuzzCursorPositions(ctx, fuzzBytes(smith, &buf));
}

fn fuzzCharacterInsertionSmith(ctx: FuzzContext, smith: *std.testing.Smith) anyerror!void {
    var buf: [512]u8 = undefined;
    try fuzzCharacterInsertion(ctx, fuzzBytes(smith, &buf));
}

fn fuzzDeletionsSmith(ctx: FuzzContext, smith: *std.testing.Smith) anyerror!void {
    var buf: [512]u8 = undefined;
    try fuzzDeletions(ctx, fuzzBytes(smith, &buf));
}

fn fuzzLineCountingSmith(ctx: FuzzContext, smith: *std.testing.Smith) anyerror!void {
    var buf: [512]u8 = undefined;
    try fuzzLineCounting(ctx, fuzzBytes(smith, &buf));
}

test "fuzz: EditorState cursor positions" {
    const ctx = FuzzContext{ .allocator = std.testing.allocator };
    try std.testing.fuzz(ctx, fuzzCursorPositionsSmith, .{});
}

test "fuzz: EditorState character insertion" {
    const ctx = FuzzContext{ .allocator = std.testing.allocator };
    try std.testing.fuzz(ctx, fuzzCharacterInsertionSmith, .{});
}

test "fuzz: EditorState deletions" {
    const ctx = FuzzContext{ .allocator = std.testing.allocator };
    try std.testing.fuzz(ctx, fuzzDeletionsSmith, .{});
}

test "fuzz: EditorState line counting" {
    const ctx = FuzzContext{ .allocator = std.testing.allocator };
    try std.testing.fuzz(ctx, fuzzLineCountingSmith, .{});
}
