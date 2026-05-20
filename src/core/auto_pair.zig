const std = @import("std");
const EditorState = @import("state.zig").EditorState;
const TestIo = @import("../test_utils.zig").TestIo;

pub const AutoPairConfig = struct {
    enabled: bool = true,
    wrap_selection: bool = true,
    smart_deletion: bool = true,
    context_aware: bool = false,
};

pub const Pair = struct {
    open: u8,
    close: u8,

    pub fn init(open: u8, close: u8) Pair {
        return .{ .open = open, .close = close };
    }
};

pub const STANDARD_PAIRS = [_]Pair{
    Pair.init('(', ')'),
    Pair.init('{', '}'),
    Pair.init('[', ']'),
    Pair.init('"', '"'),
    Pair.init('\'', '\''),
};

pub fn isOpeningChar(char: u8) ?Pair {
    for (STANDARD_PAIRS) |pair| {
        if (char == pair.open) return pair;
    }
    return null;
}

pub fn isClosingChar(char: u8) ?Pair {
    for (STANDARD_PAIRS) |pair| {
        if (char == pair.close) return pair;
    }
    return null;
}

pub fn getSelectionRange(state: *EditorState) ?struct { start: usize, end: usize } {
    const anchor = state.selection_anchor orelse return null;

    const cursor_offset = state.getOffsetFromCursor();
    const anchor_offset = state.getOffsetFor(anchor.row, anchor.col);

    if (cursor_offset == anchor_offset) return null;

    return if (cursor_offset > anchor_offset)
        .{ .start = anchor_offset, .end = cursor_offset }
    else
        .{ .start = cursor_offset, .end = anchor_offset };
}

pub fn getSelectedText(state: *EditorState, allocator: std.mem.Allocator) !?[]u8 {
    const range = getSelectionRange(state) orelse return null;

    const content = try state.buffer.toString(allocator);
    defer allocator.free(content);

    if (range.end > content.len) return null;

    return try allocator.dupe(u8, content[range.start..range.end]);
}

pub fn wrapSelection(state: *EditorState, open: u8, close: u8) !bool {
    const range = getSelectionRange(state) orelse return false;

    try state.buffer.insert(range.end, &[_]u8{close});

    try state.buffer.insert(range.start, &[_]u8{open});

    state.updateCursorFromOffset(range.end + 2);

    state.selection_anchor = null;
    state.markModified();

    return true;
}

pub fn isBetweenEmptyPair(state: *EditorState, pair: Pair) bool {
    const char_before = state.getCharBeforeCursor();
    const char_after = state.getCharAfterCursor();

    return char_before == pair.open and char_after == pair.close;
}

pub fn smartBackspace(state: *EditorState) !bool {
    const char_before = state.getCharBeforeCursor();
    const char_after = state.getCharAfterCursor();

    for (STANDARD_PAIRS) |pair| {
        if (char_before == pair.open and char_after == pair.close) {
            const offset = state.getOffsetFromCursor();
            if (offset > 0) {
                try state.buffer.delete(offset, 1);
                try state.buffer.delete(offset - 1, 1);
                state.updateCursorFromOffset(offset - 1);
                state.markModified();
                return true;
            }
        }
    }

    return false;
}

pub fn shouldSkipClosingChar(state: *EditorState, char: u8) bool {
    const char_after = state.getCharAfterCursor();

    if (char_after != char) return false;

    if (isClosingChar(char)) |_| {
        return true;
    }

    return false;
}

pub fn handleCharInput(
    state: *EditorState,
    char: u8,
    config: AutoPairConfig,
) !enum { inserted, skipped, wrapped } {
    if (!config.enabled) return .inserted;

    if (shouldSkipClosingChar(state, char)) {
        try state.moveCursorRightGrapheme();
        return .skipped;
    }

    if (isOpeningChar(char)) |pair| {
        if (config.wrap_selection and state.selection_anchor != null) {
            _ = try wrapSelection(state, pair.open, pair.close);
            return .wrapped;
        }

        try state.insertChar(pair.open);
        try state.insertChar(pair.close);
        if (state.cursor_col > 0) {
            try state.moveCursorLeftGrapheme();
        }
        state.markModified();
        return .inserted;
    }

    return .inserted;
}

test "isOpeningChar identifies opening brackets" {
    try std.testing.expect(isOpeningChar('(') != null);
    try std.testing.expect(isOpeningChar('{') != null);
    try std.testing.expect(isOpeningChar('[') != null);
    try std.testing.expect(isOpeningChar('"') != null);
    try std.testing.expect(isOpeningChar('\'') != null);
    try std.testing.expect(isOpeningChar('a') == null);
}

test "isClosingChar identifies closing brackets" {
    try std.testing.expect(isClosingChar(')') != null);
    try std.testing.expect(isClosingChar('}') != null);
    try std.testing.expect(isClosingChar(']') != null);
    try std.testing.expect(isClosingChar('"') != null);
    try std.testing.expect(isClosingChar('\'') != null);
    try std.testing.expect(isClosingChar('a') == null);
}

test "getSelectionRange with no selection" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = try EditorState.init(allocator, io, "Hello World");
    defer state.deinit();

    const range = getSelectionRange(&state);
    try std.testing.expect(range == null);
}

test "getSelectionRange with forward selection" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = try EditorState.init(allocator, io, "Hello World");
    defer state.deinit();

    state.selection_anchor = .{ .row = 0, .col = 0 };
    state.cursor_col = 5;

    const range = getSelectionRange(&state).?;
    try std.testing.expectEqual(0, range.start);
    try std.testing.expectEqual(5, range.end);
}

test "getSelectionRange with backward selection" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = try EditorState.init(allocator, io, "Hello World");
    defer state.deinit();

    state.cursor_col = 0;
    state.selection_anchor = .{ .row = 0, .col = 5 };

    const range = getSelectionRange(&state).?;
    try std.testing.expectEqual(0, range.start);
    try std.testing.expectEqual(5, range.end);
}

test "wrapSelection wraps text in parentheses" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = try EditorState.init(allocator, io, "Hello");
    defer state.deinit();

    state.selection_anchor = .{ .row = 0, .col = 0 };
    state.cursor_col = 5;

    const wrapped = try wrapSelection(&state, '(', ')');
    try std.testing.expect(wrapped);

    const result = try state.buffer.toString(allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("(Hello)", result);

    try std.testing.expect(state.selection_anchor == null);
}

test "wrapSelection with quotes" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = try EditorState.init(allocator, io, "text");
    defer state.deinit();

    state.selection_anchor = .{ .row = 0, .col = 0 };
    state.cursor_col = 4;

    _ = try wrapSelection(&state, '"', '"');

    const result = try state.buffer.toString(allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("\"text\"", result);
}

test "isBetweenEmptyPair detects empty brackets" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = try EditorState.init(allocator, io, "()");
    defer state.deinit();

    state.cursor_col = 1;

    const pair = Pair.init('(', ')');
    try std.testing.expect(isBetweenEmptyPair(&state, pair));
}

test "isBetweenEmptyPair returns false when not between pair" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = try EditorState.init(allocator, io, "( )");
    defer state.deinit();

    state.cursor_col = 1;

    const pair = Pair.init('(', ')');
    try std.testing.expect(!isBetweenEmptyPair(&state, pair));
}

test "smartBackspace deletes matching pair" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = try EditorState.init(allocator, io, "()");
    defer state.deinit();

    state.cursor_col = 1;

    const deleted = try smartBackspace(&state);
    try std.testing.expect(deleted);

    const result = try state.buffer.toString(allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "smartBackspace doesn't delete when not between pair" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = try EditorState.init(allocator, io, "ab");
    defer state.deinit();

    state.cursor_col = 1;

    const deleted = try smartBackspace(&state);
    try std.testing.expect(!deleted);
}

test "smartBackspace with quotes" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = try EditorState.init(allocator, io, "\"\"");
    defer state.deinit();

    state.cursor_col = 1;

    _ = try smartBackspace(&state);

    const result = try state.buffer.toString(allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "shouldSkipClosingChar detects skip condition" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = try EditorState.init(allocator, io, "()");
    defer state.deinit();

    state.cursor_col = 1;

    try std.testing.expect(shouldSkipClosingChar(&state, ')'));
    try std.testing.expect(!shouldSkipClosingChar(&state, '('));
}

test "handleCharInput wraps selection" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = try EditorState.init(allocator, io, "Hello");
    defer state.deinit();

    state.selection_anchor = .{ .row = 0, .col = 0 };
    state.cursor_col = 5;

    const config = AutoPairConfig{};
    const result = try handleCharInput(&state, '(', config);

    try std.testing.expectEqual(.wrapped, result);

    const text = try state.buffer.toString(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("(Hello)", text);
}

test "handleCharInput skips closing char" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = try EditorState.init(allocator, io, "()");
    defer state.deinit();

    state.cursor_col = 1;

    const config = AutoPairConfig{};
    const result = try handleCharInput(&state, ')', config);

    try std.testing.expectEqual(.skipped, result);
    try std.testing.expectEqual(2, state.cursor_col);
}

test "handleCharInput inserts pair" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = try EditorState.init(allocator, io, "");
    defer state.deinit();

    const config = AutoPairConfig{};
    _ = try handleCharInput(&state, '(', config);

    const text = try state.buffer.toString(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("()", text);
    try std.testing.expectEqual(1, state.cursor_col);
}

test "handleCharInput with disabled config" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var state = try EditorState.init(allocator, io, "");
    defer state.deinit();

    const config = AutoPairConfig{ .enabled = false };
    const result = try handleCharInput(&state, '(', config);

    try std.testing.expectEqual(.inserted, result);
}
