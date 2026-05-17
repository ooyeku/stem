//! Display-width and grapheme conversion helpers for terminal rendering.
//!
//! stem stores line text as UTF-8 byte slices and treats columns internally
//! as grapheme/byte offsets. Terminals render each glyph at a width that
//! depends on Unicode East Asian Width (wide CJK / fullwidth = 2 columns,
//! everything else = 1) and on whether the codepoint is part of a multi-
//! codepoint grapheme cluster (which renders as a single glyph).
//!
//! Without this helper, the editor assumes every byte renders to one column
//! — wrong for CJK, emoji, ZWJ sequences, fullwidth ASCII, combining marks.
//!
//! Backed by the `uucode` package configured in `build.zig.zon` to expose
//! east_asian_width and grapheme_break tables.

const std = @import("std");
const uucode = @import("uucode");

/// Display width of a single Unicode codepoint, in terminal columns.
/// - 0 for combining marks / zero-width characters
/// - 2 for wide / fullwidth (CJK, most emoji)
/// - 1 for everything else
pub fn codepointWidth(cp: u21) usize {
    // Common ASCII fast path before consulting tables.
    if (cp < 0x20) return 0; // control char; we don't emit these in rendering
    if (cp == 0x7f) return 0;
    if (cp < 0x7f) return 1;

    const eaw = uucode.get(.east_asian_width, cp);
    return switch (eaw) {
        .wide, .fullwidth => 2,
        else => 1,
    };
}

/// Display width of an entire UTF-8 line, counting each grapheme cluster's
/// "primary" codepoint's east-asian width and adding 0 for combining marks.
/// Tab is treated as `tab_stop` columns; pass 0 to ignore tabs.
pub fn displayWidth(line: []const u8, tab_stop: usize) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (c == '\t') {
            // Round up to the next tab stop.
            if (tab_stop > 0) {
                w = ((w / tab_stop) + 1) * tab_stop;
            } else {
                w += 1;
            }
            i += 1;
            continue;
        }
        if (c < 0x80) {
            w += 1;
            i += 1;
            continue;
        }
        const seq_len: usize = if (c < 0xC0) 1 else if (c < 0xE0) 2 else if (c < 0xF0) 3 else 4;
        if (i + seq_len > line.len) {
            // Truncated UTF-8 — treat as 1 column and stop.
            w += 1;
            break;
        }
        const cp = std.unicode.utf8Decode(line[i .. i + seq_len]) catch {
            w += 1;
            i += seq_len;
            continue;
        };
        w += codepointWidth(cp);
        i += seq_len;
    }
    return w;
}

/// Convert a screen column (counting display cells) to a byte offset within
/// `line`. Used by mouse-click translation. If the screen column lands in
/// the middle of a wide glyph, returns the byte offset of its start.
pub fn screenColToByte(line: []const u8, screen_col: usize, tab_stop: usize) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        if (w >= screen_col) return i;
        const c = line[i];
        if (c == '\t') {
            const next = if (tab_stop > 0) ((w / tab_stop) + 1) * tab_stop else w + 1;
            if (next > screen_col) return i;
            w = next;
            i += 1;
            continue;
        }
        if (c < 0x80) {
            w += 1;
            i += 1;
            continue;
        }
        const seq_len: usize = if (c < 0xC0) 1 else if (c < 0xE0) 2 else if (c < 0xF0) 3 else 4;
        if (i + seq_len > line.len) return i;
        const cp = std.unicode.utf8Decode(line[i .. i + seq_len]) catch {
            w += 1;
            i += seq_len;
            continue;
        };
        const cw = codepointWidth(cp);
        if (w + cw > screen_col) return i;
        w += cw;
        i += seq_len;
    }
    return line.len;
}

/// Inverse: convert a byte offset within `line` to a screen column.
pub fn byteToScreenCol(line: []const u8, byte: usize, tab_stop: usize) usize {
    const safe_byte = @min(byte, line.len);
    return displayWidth(line[0..safe_byte], tab_stop);
}

test "displayWidth ASCII" {
    try std.testing.expectEqual(@as(usize, 5), displayWidth("hello", 0));
    try std.testing.expectEqual(@as(usize, 0), displayWidth("", 0));
}

test "displayWidth tabs" {
    try std.testing.expectEqual(@as(usize, 4), displayWidth("\t", 4));
    // 'a' at col 0; tab from col 1 rounds up to next 4-stop = col 4.
    try std.testing.expectEqual(@as(usize, 4), displayWidth("a\t", 4));
    // 'abc' at cols 0..2; tab from col 3 → col 4; 'x' → col 5.
    try std.testing.expectEqual(@as(usize, 5), displayWidth("abc\tx", 4));
}

test "displayWidth wide CJK" {
    // Each Han character is east-asian-width Wide = 2 columns.
    try std.testing.expectEqual(@as(usize, 6), displayWidth("漢字漢", 0));
    // a(1) + 漢(2) + b(1) + 漢(2) = 6
    try std.testing.expectEqual(@as(usize, 6), displayWidth("a漢b漢", 0));
}

test "screenColToByte / byteToScreenCol round trip" {
    const line = "a\t漢bc";
    // a@0 → col 0; tab@1 → cols 1..4; 漢@2..4 → cols 4..6; b@5 → col 6; c@6 → col 7
    try std.testing.expectEqual(@as(usize, 1), screenColToByte(line, 1, 4)); // start of tab
    try std.testing.expectEqual(@as(usize, 2), screenColToByte(line, 4, 4)); // start of 漢
    try std.testing.expectEqual(@as(usize, 5), screenColToByte(line, 6, 4)); // start of b
}

test "codepointWidth: ASCII fast path" {
    try std.testing.expectEqual(@as(usize, 1), codepointWidth('A'));
    try std.testing.expectEqual(@as(usize, 1), codepointWidth(' '));
    try std.testing.expectEqual(@as(usize, 1), codepointWidth('~'));
    // Control characters render as 0 width.
    try std.testing.expectEqual(@as(usize, 0), codepointWidth(0));
    try std.testing.expectEqual(@as(usize, 0), codepointWidth(0x1f));
    try std.testing.expectEqual(@as(usize, 0), codepointWidth(0x7f));
}

test "codepointWidth: wide CJK" {
    try std.testing.expectEqual(@as(usize, 2), codepointWidth(0x6f22)); // 漢
    try std.testing.expectEqual(@as(usize, 2), codepointWidth(0x4e2d)); // 中
}

test "displayWidth: empty and whitespace" {
    try std.testing.expectEqual(@as(usize, 0), displayWidth("", 0));
    try std.testing.expectEqual(@as(usize, 0), displayWidth("", 4));
    try std.testing.expectEqual(@as(usize, 1), displayWidth(" ", 4));
}

test "displayWidth: tab with tab_stop=0 treats tab as 1 col" {
    try std.testing.expectEqual(@as(usize, 1), displayWidth("\t", 0));
    try std.testing.expectEqual(@as(usize, 3), displayWidth("a\tb", 0));
}

test "displayWidth: tab on aligned column advances by full tab_stop" {
    // 'abcd' is at cols 0..3, tab from col 4 should advance to col 8.
    try std.testing.expectEqual(@as(usize, 8), displayWidth("abcd\t", 4));
}

test "displayWidth: invalid utf-8 doesn't crash" {
    // 0xff is not a valid leading UTF-8 byte; helper falls through to its
    // "+1 column" fallback rather than crashing.
    const w = displayWidth("a\xff\xffb", 0);
    try std.testing.expect(w >= 2);
}

test "screenColToByte: past end of line returns line.len" {
    const line = "abc";
    try std.testing.expectEqual(@as(usize, 3), screenColToByte(line, 999, 0));
}

test "byteToScreenCol: byte past end is clamped to line.len" {
    const line = "abc";
    try std.testing.expectEqual(@as(usize, 3), byteToScreenCol(line, 999, 0));
}

test "screenColToByte: column inside a wide glyph returns its start byte" {
    // "漢" is 3 bytes at offset 0, displays at cols 0..1.
    // Asking for col 1 (the second cell of the glyph) should still return
    // byte offset 0 (the start of the glyph).
    const line = "漢x";
    try std.testing.expectEqual(@as(usize, 0), screenColToByte(line, 1, 0));
    // Col 2 is the start of 'x'.
    try std.testing.expectEqual(@as(usize, 3), screenColToByte(line, 2, 0));
}
