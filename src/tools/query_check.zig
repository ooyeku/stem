//! Standalone diagnostic: build with `zig build query-check` to confirm
//! each language's highlight query compiles against the linked
//! tree-sitter grammar. Prints the failing offset + context on miss.

const std = @import("std");
const stem = @import("stem");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const langs = [_][]const u8{
        "zig",   "python", "javascript", "typescript", "tsx",
        "json",  "bash",   "go",         "html",       "css",
        "rust",  "c",      "cpp",        "java",       "ruby",
        "csharp",
        // Tier 2
        "php",   "swift",  "kotlin", "lua",   "dart",
        "elixir", "haskell", "ocaml", "scala", "r",
        "perl",  "erlang",
    };

    var fail_count: usize = 0;
    for (langs) |l| {
        var sm = try stem.syntax_manager.SyntaxManager.init(alloc);
        defer sm.deinit();
        sm.setLanguage(l) catch |err| {
            std.debug.print("FAIL {s}: {}\n", .{ l, err });
            fail_count += 1;
            continue;
        };
        std.debug.print("ok   {s}\n", .{l});
    }
    if (fail_count > 0) std.process.exit(1);
}
