//! Parsed hover content. Bridges the raw LSP markdown response and
//! the hover popup renderer so the popup can lay out a proper visual
//! hierarchy (signature on top, divider, sections below) instead of
//! emitting one stream of un-styled text.
//!
//! The parser is intentionally minimal — it recognises block-level
//! markdown structure (fenced code, blank-separated paragraphs,
//! bullet lists) and inline links, ignores everything else. Hover
//! responses are short; a full CommonMark engine would be overkill.

const std = @import("std");

pub const SectionKind = enum {
    paragraph,
    code_block,
    list_item,
    blank,
};

pub const Section = struct {
    kind: SectionKind,
    /// Owned. For `code_block`, the inside-the-fence text (no fence
    /// markers). For `paragraph` / `list_item`, the visible text
    /// (markdown link syntax already normalised down to the visible
    /// label).
    text: []const u8,
    /// Owned, set only for `code_block`. Language tag after the
    /// opening fence — `zig`, `typescript`, etc.
    language: ?[]const u8 = null,
};

pub const HoverDocument = struct {
    allocator: std.mem.Allocator,

    /// Symbol name extracted heuristically — e.g. when hover content
    /// contains a "Go to [Symbol](file:///…)" link, "Symbol" lands
    /// here. Used as the popup title. Owned.
    title: ?[]u8 = null,

    /// Primary signature. The first fenced code block in the raw
    /// markdown — typically the type signature LSPs put at the top.
    /// Owned.
    signature: ?[]u8 = null,
    /// Owned. Language tag from the signature's opening fence.
    signature_language: ?[]u8 = null,

    /// Everything else, in source order. Cleaned up: fences removed,
    /// inline `[text](url)` collapsed to `text`, leading list markers
    /// stripped.
    sections: []Section,

    pub fn empty(allocator: std.mem.Allocator) HoverDocument {
        return .{ .allocator = allocator, .sections = &.{} };
    }

    pub fn deinit(self: *HoverDocument) void {
        const a = self.allocator;
        if (self.title) |t| a.free(t);
        if (self.signature) |s| a.free(s);
        if (self.signature_language) |s| a.free(s);
        for (self.sections) |sec| {
            a.free(sec.text);
            if (sec.language) |l| a.free(l);
        }
        a.free(self.sections);
        self.* = .{ .allocator = a, .sections = &.{} };
    }

    /// Deep-copy into `dest_allocator`. Used to dupe the parsed
    /// document into a per-frame render arena.
    pub fn clone(self: HoverDocument, dest_allocator: std.mem.Allocator) !HoverDocument {
        var out = HoverDocument.empty(dest_allocator);
        errdefer out.deinit();
        if (self.title) |t| out.title = try dest_allocator.dupe(u8, t);
        if (self.signature) |s| out.signature = try dest_allocator.dupe(u8, s);
        if (self.signature_language) |s| out.signature_language = try dest_allocator.dupe(u8, s);

        const dst = try dest_allocator.alloc(Section, self.sections.len);
        var filled: usize = 0;
        errdefer {
            for (dst[0..filled]) |sec| {
                dest_allocator.free(sec.text);
                if (sec.language) |l| dest_allocator.free(l);
            }
            dest_allocator.free(dst);
        }
        for (self.sections, 0..) |sec, i| {
            const lang_dup: ?[]u8 = if (sec.language) |l| try dest_allocator.dupe(u8, l) else null;
            errdefer if (lang_dup) |l| dest_allocator.free(l);
            const text_dup = try dest_allocator.dupe(u8, sec.text);
            dst[i] = .{
                .kind = sec.kind,
                .text = text_dup,
                .language = lang_dup,
            };
            filled += 1;
        }
        out.sections = dst;
        return out;
    }

    /// Total renderable line count if laid out at `wrap_width` cells
    /// (excluding the signature panel and chrome — caller adds those).
    pub fn sectionLineCount(self: HoverDocument, wrap_width: usize) usize {
        if (wrap_width == 0) return self.sections.len;
        var total: usize = 0;
        for (self.sections) |sec| {
            switch (sec.kind) {
                .blank => total += 1,
                .code_block => total += countWrappedLines(sec.text, wrap_width),
                .paragraph, .list_item => total += countWrappedLines(sec.text, wrap_width),
            }
        }
        return total;
    }
};

/// Parse a markdown hover payload into a `HoverDocument`. Recognises:
///   - Fenced code blocks (```lang … ```)
///   - Blank-line-separated paragraphs
///   - Leading `- ` / `* ` / `+ ` list markers
///   - Inline links `[text](url)` (URL stripped, label kept)
///
/// Anything else is treated as paragraph text.
pub fn parse(allocator: std.mem.Allocator, markdown: []const u8) !HoverDocument {
    var doc = HoverDocument.empty(allocator);
    errdefer doc.deinit();

    var sections = std.ArrayListUnmanaged(Section).empty;
    errdefer {
        for (sections.items) |sec| {
            allocator.free(sec.text);
            if (sec.language) |l| allocator.free(l);
        }
        sections.deinit(allocator);
    }

    var paragraph_buf = std.ArrayListUnmanaged(u8).empty;
    defer paragraph_buf.deinit(allocator);

    var in_code = false;
    var code_buf = std.ArrayListUnmanaged(u8).empty;
    defer code_buf.deinit(allocator);
    var code_lang: ?[]u8 = null;
    errdefer if (code_lang) |l| allocator.free(l);

    var first_code_consumed = false;

    var it = std.mem.splitScalar(u8, markdown, '\n');
    while (it.next()) |raw_line| {
        const line = trimTrailingCR(raw_line);
        const trimmed = std.mem.trimStart(u8, line, " \t");

        if (std.mem.startsWith(u8, trimmed, "```")) {
            if (in_code) {
                // Close fence: emit signature or section.
                const code_text = try allocator.dupe(u8, std.mem.trim(u8, code_buf.items, "\n"));
                errdefer allocator.free(code_text);
                if (!first_code_consumed) {
                    doc.signature = code_text;
                    doc.signature_language = code_lang;
                    code_lang = null;
                    first_code_consumed = true;
                } else {
                    try sections.append(allocator, .{
                        .kind = .code_block,
                        .text = code_text,
                        .language = code_lang,
                    });
                    code_lang = null;
                }
                code_buf.clearRetainingCapacity();
                in_code = false;
            } else {
                try flushParagraph(allocator, &paragraph_buf, &sections);
                in_code = true;
                const lang_text = std.mem.trim(u8, trimmed[3..], " \t");
                if (lang_text.len > 0) {
                    code_lang = try allocator.dupe(u8, lang_text);
                }
            }
            continue;
        }

        if (in_code) {
            if (code_buf.items.len > 0) try code_buf.append(allocator, '\n');
            try code_buf.appendSlice(allocator, line);
            continue;
        }

        if (trimmed.len == 0) {
            try flushParagraph(allocator, &paragraph_buf, &sections);
            continue;
        }

        if (isListBullet(trimmed)) {
            try flushParagraph(allocator, &paragraph_buf, &sections);
            const bullet_body = stripBullet(trimmed);
            const stripped = try stripInlineLinks(allocator, bullet_body);
            try sections.append(allocator, .{
                .kind = .list_item,
                .text = stripped,
            });
            continue;
        }

        // Title heuristic: a line of the form `# Foo` becomes the
        // document title if we don't already have one.
        if (std.mem.startsWith(u8, trimmed, "#") and doc.title == null) {
            const after = std.mem.trimStart(u8, trimmed, "# ");
            if (after.len > 0) {
                try flushParagraph(allocator, &paragraph_buf, &sections);
                doc.title = try allocator.dupe(u8, after);
                continue;
            }
        }

        // Regular paragraph line — join with spaces.
        if (paragraph_buf.items.len > 0) try paragraph_buf.append(allocator, ' ');
        try paragraph_buf.appendSlice(allocator, trimmed);
    }

    if (in_code) {
        // Unterminated fence: salvage whatever's in code_buf as a code
        // block / signature so we don't lose the content.
        const code_text = try allocator.dupe(u8, std.mem.trim(u8, code_buf.items, "\n"));
        errdefer allocator.free(code_text);
        if (!first_code_consumed) {
            doc.signature = code_text;
            doc.signature_language = code_lang;
            code_lang = null;
        } else {
            try sections.append(allocator, .{
                .kind = .code_block,
                .text = code_text,
                .language = code_lang,
            });
            code_lang = null;
        }
    }
    try flushParagraph(allocator, &paragraph_buf, &sections);

    // Heuristic title fallback: scan sections for a "Go to [Symbol]" link.
    if (doc.title == null) {
        for (sections.items) |sec| {
            if (sec.kind != .paragraph) continue;
            if (extractGoToLink(sec.text)) |name| {
                doc.title = try allocator.dupe(u8, name);
                break;
            }
        }
    }

    doc.sections = try sections.toOwnedSlice(allocator);
    return doc;
}

fn trimTrailingCR(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

fn isListBullet(s: []const u8) bool {
    if (s.len < 2) return false;
    if ((s[0] == '-' or s[0] == '*' or s[0] == '+') and s[1] == ' ') return true;
    return false;
}

fn stripBullet(s: []const u8) []const u8 {
    return s[2..];
}

fn flushParagraph(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    out: *std.ArrayListUnmanaged(Section),
) !void {
    if (buf.items.len == 0) return;
    const text = std.mem.trim(u8, buf.items, " \t\r\n");
    if (text.len > 0) {
        const stripped = try stripInlineLinks(allocator, text);
        try out.append(allocator, .{ .kind = .paragraph, .text = stripped });
    }
    buf.clearRetainingCapacity();
}

/// Collapse `[label](url)` to `label` so the URL doesn't show up in
/// the popup (we can't click it from the terminal anyway). Other
/// markdown syntax is left as-is.
fn stripInlineLinks(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '[') {
            // Find matching `](`
            if (std.mem.indexOfScalarPos(u8, text, i + 1, ']')) |close_label| {
                if (close_label + 1 < text.len and text[close_label + 1] == '(') {
                    // Find closing `)`
                    if (std.mem.indexOfScalarPos(u8, text, close_label + 2, ')')) |close_url| {
                        try out.appendSlice(allocator, text[i + 1 .. close_label]);
                        i = close_url + 1;
                        continue;
                    }
                }
            }
        }
        try out.append(allocator, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

/// Try to extract a symbol name from "Go to [Symbol](url)" prose
/// that ZLS emits at the bottom of hover responses. The link has
/// already been collapsed by `stripInlineLinks`, so we look for the
/// "Go to " prefix and grab the word that follows.
fn extractGoToLink(paragraph: []const u8) ?[]const u8 {
    const prefix = "Go to ";
    const idx = std.mem.indexOf(u8, paragraph, prefix) orelse return null;
    const rest = paragraph[idx + prefix.len ..];
    if (rest.len == 0) return null;
    var end: usize = 0;
    while (end < rest.len) : (end += 1) {
        const c = rest[end];
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '_' or c == '.';
        if (!ok) break;
    }
    if (end == 0) return null;
    return rest[0..end];
}

fn countWrappedLines(text: []const u8, wrap_width: usize) usize {
    if (wrap_width == 0) return 0;
    var rows: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0) {
            rows += 1;
            continue;
        }
        rows += (line.len + wrap_width - 1) / wrap_width;
    }
    return rows;
}

// -- tests ----------------------------------------------------------

const testing = std.testing;

test "parse: single fenced code block becomes signature" {
    const md =
        \\```zig
        \\fn run(self: *Sieve) void
        \\```
    ;
    var doc = try parse(testing.allocator, md);
    defer doc.deinit();

    try testing.expect(doc.signature != null);
    try testing.expectEqualStrings("fn run(self: *Sieve) void", doc.signature.?);
    try testing.expect(doc.signature_language != null);
    try testing.expectEqualStrings("zig", doc.signature_language.?);
    try testing.expectEqual(@as(usize, 0), doc.sections.len);
}

test "parse: two code blocks — first is signature, second is section" {
    const md =
        \\```zig
        \\fn run(self: *Sieve) void
        \\```
        \\
        \\```zig
        \\(fn (*Sieve) void)
        \\```
    ;
    var doc = try parse(testing.allocator, md);
    defer doc.deinit();

    try testing.expectEqualStrings("fn run(self: *Sieve) void", doc.signature.?);
    try testing.expectEqual(@as(usize, 1), doc.sections.len);
    try testing.expectEqual(SectionKind.code_block, doc.sections[0].kind);
    try testing.expectEqualStrings("(fn (*Sieve) void)", doc.sections[0].text);
}

test "parse: inline links collapse to label" {
    const md =
        \\Go to [Sieve](file:///foo/bar.zig#L5)
    ;
    var doc = try parse(testing.allocator, md);
    defer doc.deinit();

    try testing.expectEqual(@as(usize, 1), doc.sections.len);
    try testing.expectEqualStrings("Go to Sieve", doc.sections[0].text);
    // Heuristic title extraction.
    try testing.expectEqualStrings("Sieve", doc.title.?);
}

test "parse: list items strip leading bullet" {
    const md =
        \\Parameters:
        \\- first
        \\- second item with text
        \\- third
    ;
    var doc = try parse(testing.allocator, md);
    defer doc.deinit();

    try testing.expectEqual(@as(usize, 4), doc.sections.len);
    try testing.expectEqualStrings("Parameters:", doc.sections[0].text);
    try testing.expectEqual(SectionKind.list_item, doc.sections[1].kind);
    try testing.expectEqualStrings("first", doc.sections[1].text);
    try testing.expectEqualStrings("second item with text", doc.sections[2].text);
    try testing.expectEqualStrings("third", doc.sections[3].text);
}

test "parse: heading marks document title" {
    const md =
        \\# Allocator
        \\
        \\```zig
        \\const Allocator = struct { ... }
        \\```
    ;
    var doc = try parse(testing.allocator, md);
    defer doc.deinit();

    try testing.expectEqualStrings("Allocator", doc.title.?);
    try testing.expect(doc.signature != null);
}

test "parse: paragraphs joined with spaces, separated by blanks" {
    const md =
        \\First paragraph
        \\continues onto a second line.
        \\
        \\Second paragraph here.
    ;
    var doc = try parse(testing.allocator, md);
    defer doc.deinit();

    try testing.expectEqual(@as(usize, 2), doc.sections.len);
    try testing.expectEqualStrings("First paragraph continues onto a second line.", doc.sections[0].text);
    try testing.expectEqualStrings("Second paragraph here.", doc.sections[1].text);
}

test "parse: unterminated fence is recovered as signature" {
    const md =
        \\```zig
        \\fn run() void
    ;
    var doc = try parse(testing.allocator, md);
    defer doc.deinit();

    try testing.expectEqualStrings("fn run() void", doc.signature.?);
}

test "clone: deep copy survives original deinit" {
    const md =
        \\```zig
        \\fn run() void
        \\```
        \\
        \\Some docs here.
    ;
    var src = try parse(testing.allocator, md);

    var dst = try src.clone(testing.allocator);
    defer dst.deinit();

    src.deinit();

    try testing.expectEqualStrings("fn run() void", dst.signature.?);
    try testing.expectEqual(@as(usize, 1), dst.sections.len);
    try testing.expectEqualStrings("Some docs here.", dst.sections[0].text);
}
