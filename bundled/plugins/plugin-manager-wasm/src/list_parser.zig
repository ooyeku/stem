const std = @import("std");

/// `stem plugin list` emits entry lines like:
///
///     "  echo                   v0.2.0    [wasm]"
///
/// Two leading spaces, then the plugin name (no whitespace), then
/// version + `[runtime]`. Older builds used `(runtime)`. Description
/// lines use four leading spaces
/// and don't have the `(runtime)` token, which is how we tell them
/// apart from entry lines.
pub fn parsePluginName(line: []const u8) ?[]const u8 {
    if (line.len < 3) return null;
    if (line[0] != ' ' or line[1] != ' ') return null;
    if (line[2] == ' ') return null;
    if (std.mem.indexOfAny(u8, line, "([") == null) return null;
    const rest = line[2..];
    const end = std.mem.indexOfAny(u8, rest, " \t") orelse return null;
    if (end == 0) return null;
    return rest[0..end];
}

test "parsePluginName accepts current plugin list runtime brackets" {
    try std.testing.expectEqualStrings(
        "plugin_manager",
        parsePluginName("  plugin_manager         v0.6.0    [wasm]").?,
    );
}

test "parsePluginName ignores plugin list description lines" {
    try std.testing.expect(parsePluginName("    Plugin operator dashboard.") == null);
}
