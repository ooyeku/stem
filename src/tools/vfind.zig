const std = @import("std");
const search = @import("search.zig");

// TODO(zig-0.16): re-introduce parallel walking once we wire up
// std.Io.Group.concurrent. For now we share search.zig's single-threaded
// implementation.
pub fn run(allocator: std.mem.Allocator, io: std.Io, query: []const u8, options: search.SearchOptions) !void {
    try search.run(allocator, io, query, options);
}
