const std = @import("std");
const vaxis = @import("vaxis");
const uucode = @import("uucode");

pub fn graphemeCount(text: []const u8) usize {
    var iter = vaxis.unicode.GraphemeIterator.init(text);

    var count: usize = 0;
    while (iter.next()) |_| {
        count += 1;
    }
    return count;
}

pub fn nextGrapheme(text: []const u8, current_byte_offset: usize) ?usize {
    if (current_byte_offset >= text.len) return null;

    var iter = vaxis.unicode.GraphemeIterator.init(text[current_byte_offset..]);

    if (iter.next()) |grapheme| {
        return current_byte_offset + grapheme.len;
    }
    return null;
}

pub fn prevGrapheme(text: []const u8, current_byte_offset: usize) ?usize {
    if (current_byte_offset == 0) return null;

    var iter = vaxis.unicode.GraphemeIterator.init(text[0..current_byte_offset]);

    var last_offset: usize = 0;
    var current_offset: usize = 0;

    while (iter.next()) |grapheme| {
        last_offset = current_offset;
        current_offset += grapheme.len;
    }

    return last_offset;
}

/// Classification used to decide word boundaries. Lines mostly follow vim's
/// `w` semantics: runs of word-chars and runs of punctuation/symbol form
/// separate words; whitespace separates words but is not itself a word.
const WordClass = enum { word, punct, space };

fn classifyCodePoint(cp: u21) WordClass {
    // Underscore is conventionally a word character in editors.
    if (cp == '_') return .word;
    return switch (uucode.get(.general_category, cp)) {
        .letter_uppercase,
        .letter_lowercase,
        .letter_titlecase,
        .letter_modifier,
        .letter_other,
        .number_decimal_digit,
        .number_letter,
        .number_other,
        .mark_nonspacing,
        .mark_spacing_combining,
        .mark_enclosing,
        => .word,
        .separator_space,
        .separator_line,
        .separator_paragraph,
        => .space,
        else => .punct,
    };
}

fn classifyAt(text: []const u8, byte_offset: usize) struct { class: WordClass, len: usize } {
    if (byte_offset >= text.len) return .{ .class = .space, .len = 0 };
    const first = text[byte_offset];
    // Fast path for ASCII whitespace
    if (first == '\n' or first == '\r' or first == '\t' or first == ' ') {
        return .{ .class = .space, .len = 1 };
    }
    const cp_len = std.unicode.utf8ByteSequenceLength(first) catch {
        // Treat invalid UTF-8 as a single punctuation byte so we still
        // make forward progress.
        return .{ .class = .punct, .len = 1 };
    };
    if (byte_offset + cp_len > text.len) {
        return .{ .class = .punct, .len = 1 };
    }
    const cp = std.unicode.utf8Decode(text[byte_offset .. byte_offset + cp_len]) catch {
        return .{ .class = .punct, .len = 1 };
    };
    return .{ .class = classifyCodePoint(cp), .len = cp_len };
}

/// Returns the byte offset of the start of the next word after `current_byte_offset`,
/// or null if no more words are reachable. Skips trailing characters of the
/// current run (word or punct) plus any whitespace.
pub fn nextWord(text: []const u8, current_byte_offset: usize) !?usize {
    if (current_byte_offset >= text.len) return null;

    var i = current_byte_offset;
    const start = classifyAt(text, i);
    // If we're standing on whitespace, the "next word" is simply the next
    // non-space run.
    if (start.class != .space) {
        // Skip the rest of the current word/punct run.
        while (i < text.len) {
            const c = classifyAt(text, i);
            if (c.class != start.class) break;
            i += c.len;
        }
    }
    // Skip any whitespace.
    while (i < text.len) {
        const c = classifyAt(text, i);
        if (c.class != .space) break;
        i += c.len;
    }
    if (i == current_byte_offset) return null;
    return i;
}

/// Returns the byte offset of the start of the previous word before `current_byte_offset`,
/// or null if already at offset 0.
pub fn prevWord(text: []const u8, current_byte_offset: usize) !?usize {
    if (current_byte_offset == 0) return null;

    var i = current_byte_offset;
    // Step back to the previous code point and look at its class.
    var prev = prevCodePoint(text, i) orelse return null;
    // Skip trailing whitespace immediately before the cursor.
    while (prev.class == .space) {
        i = prev.start;
        prev = prevCodePoint(text, i) orelse return 0;
    }
    // Skip the contiguous run of the same class.
    const run_class = prev.class;
    while (prev.class == run_class) {
        i = prev.start;
        prev = prevCodePoint(text, i) orelse return 0;
    }
    return i;
}

fn prevCodePoint(text: []const u8, end_byte_offset: usize) ?struct { start: usize, class: WordClass } {
    if (end_byte_offset == 0) return null;
    var i = end_byte_offset - 1;
    // Walk back to the start of the previous UTF-8 sequence.
    while (i > 0 and (text[i] & 0xC0) == 0x80) : (i -= 1) {}
    const info = classifyAt(text, i);
    return .{ .start = i, .class = info.class };
}

pub fn graphemeWidth(text: []const u8) i3 {
    if (text.len == 0) return 0;
    const w = vaxis.gwidth.gwidth(text, .unicode);
    if (w > std.math.maxInt(i3)) return std.math.maxInt(i3);
    return @intCast(w);
}

pub fn stringWidth(text: []const u8) i32 {
    const w = vaxis.gwidth.gwidth(text, .unicode);
    if (w > std.math.maxInt(i32)) return std.math.maxInt(i32);
    return @intCast(w);
}

test "grapheme count with ASCII" {
    const text = "Hello";
    try std.testing.expectEqual(5, graphemeCount(text));
}

test "grapheme count with emoji family" {
    const text = "👨‍👩‍👧‍👦";
    try std.testing.expectEqual(1, graphemeCount(text));
}

test "grapheme count with mixed content" {
    const text = "Hello 👨‍👩‍👧‍👦 World";
    try std.testing.expectEqual(13, graphemeCount(text));
}

test "grapheme count with CJK characters" {
    const text = "中文";
    try std.testing.expectEqual(2, graphemeCount(text));
}

test "grapheme count with flag emoji" {
    const text = "🏴‍☠️";
    try std.testing.expectEqual(1, graphemeCount(text));
}

test "next grapheme with ASCII" {
    const text = "Hello";
    try std.testing.expectEqual(1, nextGrapheme(text, 0));
    try std.testing.expectEqual(2, nextGrapheme(text, 1));
    try std.testing.expectEqual(null, nextGrapheme(text, 5));
}

test "next grapheme with emoji" {
    const text = "A👨‍👩‍👧‍👦B";
    const offset1 = nextGrapheme(text, 0);
    try std.testing.expect(offset1.? == 1);

    const offset2 = nextGrapheme(text, offset1.?);
    try std.testing.expect(offset2.? > offset1.?);

    const offset3 = nextGrapheme(text, offset2.?);
    try std.testing.expect(offset3.? == text.len);
}

test "prev grapheme with ASCII" {
    const text = "Hello";
    try std.testing.expectEqual(4, prevGrapheme(text, 5));
    try std.testing.expectEqual(3, prevGrapheme(text, 4));
    try std.testing.expectEqual(null, prevGrapheme(text, 0));
}

test "prev grapheme with emoji" {
    const text = "A👨‍👩‍👧‍👦B";
    const end = text.len;

    const offset1 = prevGrapheme(text, end);
    try std.testing.expect(offset1.? < end);

    const offset2 = prevGrapheme(text, offset1.?);
    try std.testing.expect(offset2.? < offset1.?);

    const offset3 = prevGrapheme(text, offset2.?);
    try std.testing.expectEqual(0, offset3.?);
}

test "word navigation with spaces" {
    const text = "Hello World";
    const offset1 = try nextWord(text, 0);
    try std.testing.expect(offset1.? > 0);

    var current = offset1.?;
    while (current < text.len) {
        if (try nextWord(text, current)) |next| {
            current = next;
        } else break;
    }
}

test "word navigation backwards" {
    const text = "Hello World";
    const offset1 = try prevWord(text, text.len);
    try std.testing.expect(offset1.? < text.len);

    var current = offset1.?;
    while (current > 0) {
        if (try prevWord(text, current)) |prev| {
            current = prev;
        } else break;
    }
    try std.testing.expectEqual(0, current);
}

test "grapheme width for ASCII" {
    try std.testing.expectEqual(1, graphemeWidth("A"));
}

test "grapheme width for CJK" {
    const width = graphemeWidth("中");
    try std.testing.expectEqual(2, width);
}

test "string width with mixed content" {
    const ascii = "Hello";
    try std.testing.expectEqual(5, stringWidth(ascii));

    const cjk = "中文";
    try std.testing.expectEqual(4, stringWidth(cjk));

    const mixed = "Hi中";
    try std.testing.expectEqual(4, stringWidth(mixed));
}

test "string width with emoji" {
    const emoji = "👨‍👩‍👧‍👦";
    const width = stringWidth(emoji);
    try std.testing.expect(width > 0);
}

test "word navigation splits identifiers from punctuation" {
    const text = "foo, bar";
    // 0..3 = "foo", 3 = ",", 4 = " ", 5..8 = "bar"
    try std.testing.expectEqual(@as(?usize, 3), try nextWord(text, 0)); // "foo" -> ","
    try std.testing.expectEqual(@as(?usize, 5), try nextWord(text, 3)); // "," -> "bar" (skips space)
    try std.testing.expectEqual(@as(?usize, text.len), try nextWord(text, 5)); // "bar" -> EOL
}

test "word navigation treats underscore as word char" {
    const text = "foo_bar baz";
    try std.testing.expectEqual(@as(?usize, 8), try nextWord(text, 0));
}

test "word navigation with CJK" {
    // Each Han ideograph is its own letter; the comma between them is punct.
    const text = "中,文";
    // "中" (3 bytes) -> "," (1 byte)
    try std.testing.expectEqual(@as(?usize, 3), try nextWord(text, 0));
    // "," -> "文"
    try std.testing.expectEqual(@as(?usize, 4), try nextWord(text, 3));
}

test "prev word from end of mixed punctuation" {
    const text = "foo, bar";
    try std.testing.expectEqual(@as(?usize, 5), try prevWord(text, text.len));
    try std.testing.expectEqual(@as(?usize, 3), try prevWord(text, 5));
    try std.testing.expectEqual(@as(?usize, 0), try prevWord(text, 3));
}
