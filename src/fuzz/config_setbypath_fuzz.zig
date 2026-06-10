//! Fuzz `Config.setByPath` — the comptime-reflection driven config setter
//! has many edge cases (paths with empty segments, leading/trailing dots,
//! types that don't match, etc.). Catches: panics in the reflection logic.

const std = @import("std");
const Config = @import("stem").schema.Config;

const FuzzContext = struct {
    allocator: std.mem.Allocator,
};

fn fuzzSetByPath(ctx: FuzzContext, input: []const u8) anyerror!void {
    if (input.len < 2) return;

    // Split input into a path (up to first NUL or `=`) and value.
    var split: usize = 0;
    while (split < input.len and input[split] != 0 and input[split] != '=') : (split += 1) {}
    const path = input[0..split];
    const value = if (split + 1 < input.len) input[split + 1 ..] else "";

    if (!std.unicode.utf8ValidateSlice(path) or !std.unicode.utf8ValidateSlice(value)) return;
    if (path.len > 128 or value.len > 256) return;

    // setByPath dupes any new `[]const u8` field value via the passed
    // allocator; the Config struct itself doesn't own these strings (a
    // known schema limitation, see todo.md). Use an arena to absorb that
    // so the fuzz test doesn't false-flag a real leak.
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();

    var cfg = Config{};
    // The function must return either an error or a boolean. Must not panic.
    _ = cfg.setByPath(path, value, arena.allocator()) catch return;
    _ = cfg.unsetByPath(path);
}

test "fuzz: setByPath corpus" {
    const ctx = FuzzContext{ .allocator = std.testing.allocator };
    const corpus = [_][]const u8{
        "=",
        ".=",
        "..=",
        "editor=8", // struct-not-leaf
        "editor.tab_size=8",
        "editor.tab_size=", // empty value
        "editor.tab_size=not-a-number",
        "editor.insert_spaces=maybe",
        "editor.line_numbers=unknown_enum",
        "editor.line_numbers=absolute",
        "theme=dracula",
        "theme=",
        "..editor.tab_size=8", // weird path
        "editor..tab_size=8",
        "editor.tab_size.extra=8",
        ".=value",
    };
    for (corpus) |s| try fuzzSetByPath(ctx, s);
}
