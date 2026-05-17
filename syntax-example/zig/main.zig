//! Prime sieve. Run with: zig run main.zig

const std = @import("std");

const Sieve = struct {
    limit: usize,
    is_composite: []bool,

    pub fn init(allocator: std.mem.Allocator, limit: usize) !Sieve {
        const buf = try allocator.alloc(bool, limit + 1);
        @memset(buf, false);
        return .{ .limit = limit, .is_composite = buf };
    }

    pub fn deinit(self: *Sieve, allocator: std.mem.Allocator) void {
        allocator.free(self.is_composite);
    }

    pub fn run(self: *Sieve) void {
        var i: usize = 2;
        while (i * i <= self.limit) : (i += 1) {
            if (self.is_composite[i]) continue;
            var j: usize = i * i;
            while (j <= self.limit) : (j += i) self.is_composite[j] = true;
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var sieve = try Sieve.init(alloc, 100);
    defer sieve.deinit(alloc);
    sieve.run();

    var count: usize = 0;
    for (2..sieve.limit + 1) |n| {
        if (!sieve.is_composite[n]) {
            std.debug.print("{d} ", .{n});
            count += 1;
        }
    }
    std.debug.print("\n{d} primes <= {d}\n", .{ count, sieve.limit });
}
