const std = @import("std");

pub const ScopeOptions = struct {
    before: usize = 3,
    after: usize = 3,
};

pub fn run(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8, query: []const u8, options: ScopeOptions) !void {
    _ = allocator;

    const cwd = std.Io.Dir.cwd();
    const file = cwd.openFile(io, file_path, .{}) catch |err| {
        if (cwd.realPathFileAlloc(io, ".", std.heap.page_allocator)) |cwd_path| {
            defer std.heap.page_allocator.free(cwd_path);
            std.debug.print("Error: Could not open file '{s}': {}\n", .{ file_path, err });
            std.debug.print("Current directory: {s}\n", .{cwd_path});
            std.debug.print("Tip: Check if the file path is correct (typo in 'src' vs 'scr'?)\n", .{});
        } else |_| {
            std.debug.print("Error: Could not open file '{s}': {}\n", .{ file_path, err });
        }
        return err;
    };
    defer file.close(io);

    const size = try file.length(io);
    if (size > 100 * 1024 * 1024) {
        std.debug.print("File too large (>100MB)\n", .{});
        return;
    }

    const buf = try std.heap.page_allocator.alloc(u8, @intCast(size));
    defer std.heap.page_allocator.free(buf);
    const read_n = try file.readPositionalAll(io, buf, 0);
    const content = buf[0..read_n];

    var lines = std.ArrayListUnmanaged([]const u8).empty;
    defer lines.deinit(std.heap.page_allocator);

    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        try lines.append(std.heap.page_allocator, line);
    }

    if (lines.items.len == 0) {
        return;
    }

    var matches = std.ArrayListUnmanaged(usize).empty;
    defer matches.deinit(std.heap.page_allocator);

    for (lines.items, 0..) |line, line_no| {
        if (std.mem.indexOf(u8, line, query)) |_| {
            try matches.append(std.heap.page_allocator, line_no);
        }
    }

    if (matches.items.len == 0) {
        std.debug.print("No matches found for '{s}' in '{s}'\n", .{ query, file_path });
        return;
    }

    var last_printed: ?usize = null;

    for (matches.items) |match_line| {
        const context_start = if (match_line >= options.before) match_line - options.before else 0;
        const context_end = @min(match_line + options.after + 1, lines.items.len);

        if (last_printed) |last| {
            if (context_start <= last + 1) {
                for (last + 1..context_end) |line_no| {
                    const prefix = if (line_no == match_line) ">" else " ";
                    std.debug.print("{s}{d:4}: {s}\n", .{ prefix, line_no + 1, lines.items[line_no] });
                }
                last_printed = context_end - 1;
                continue;
            } else {
                std.debug.print("---\n", .{});
            }
        }

        for (context_start..match_line) |line_no| {
            std.debug.print(" {d:4}: {s}\n", .{ line_no + 1, lines.items[line_no] });
        }

        std.debug.print(">{d:4}: {s}\n", .{ match_line + 1, lines.items[match_line] });

        for (match_line + 1..context_end) |line_no| {
            std.debug.print(" {d:4}: {s}\n", .{ line_no + 1, lines.items[line_no] });
        }

        last_printed = context_end - 1;
    }

    const plural = if (matches.items.len == 1) "" else "es";
    std.debug.print("\nFound {d} match{s} in '{s}'\n", .{ matches.items.len, plural, file_path });
}
