//! A small pool of `std.heap.ArenaAllocator` that reuses backing pages across
//! render frames. The Core thread `acquire()`s an arena, builds a render
//! snapshot into it, and ships the pointer to the UI. The UI `release()`s the
//! arena once it's done with the snapshot (when the *next* snapshot arrives).
//!
//! Without the pool, each frame allocates and frees a fresh arena, which means
//! pages bounce in and out of the process at the render cadence. The pool
//! keeps a small free list, capped so a slow UI consumer can't grow memory
//! without bound.

const std = @import("std");

pub const ArenaPool = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    free_list: std.ArrayListUnmanaged(*std.heap.ArenaAllocator) = .empty,
    /// Hard cap to avoid runaway growth if UI lags. Beyond this, released
    /// arenas are deinit'd instead of pooled.
    cap: usize = 4,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) ArenaPool {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *ArenaPool) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.free_list.items) |a| {
            a.deinit();
            self.allocator.destroy(a);
        }
        self.free_list.deinit(self.allocator);
    }

    pub fn acquire(self: *ArenaPool) !*std.heap.ArenaAllocator {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.free_list.pop()) |a| {
            _ = a.reset(.retain_capacity);
            return a;
        }
        const a = try self.allocator.create(std.heap.ArenaAllocator);
        a.* = std.heap.ArenaAllocator.init(self.allocator);
        return a;
    }

    pub fn release(self: *ArenaPool, arena: *std.heap.ArenaAllocator) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.free_list.items.len < self.cap) {
            self.free_list.append(self.allocator, arena) catch {
                arena.deinit();
                self.allocator.destroy(arena);
            };
            return;
        }
        arena.deinit();
        self.allocator.destroy(arena);
    }
};

const test_utils = @import("../test_utils.zig");

test "ArenaPool: acquire returns a usable arena and release reuses it" {
    var io_ctx = test_utils.TestIo.init(std.testing.allocator);
    defer io_ctx.deinit();
    var pool = ArenaPool.init(std.testing.allocator, io_ctx.io());
    defer pool.deinit();

    const a1 = try pool.acquire();
    // Use the arena for an alloc to confirm it's wired up.
    const buf = try a1.allocator().alloc(u8, 16);
    @memset(buf, 0xab);
    try std.testing.expectEqual(@as(u8, 0xab), buf[0]);

    pool.release(a1);
    try std.testing.expectEqual(@as(usize, 1), pool.free_list.items.len);

    const a2 = try pool.acquire();
    try std.testing.expectEqual(@as(usize, 0), pool.free_list.items.len);
    // Acquired arena should be the same recycled one.
    try std.testing.expectEqual(@intFromPtr(a1), @intFromPtr(a2));
    pool.release(a2);
}

test "ArenaPool: respects cap by dropping overflow" {
    var io_ctx = test_utils.TestIo.init(std.testing.allocator);
    defer io_ctx.deinit();
    var pool = ArenaPool.init(std.testing.allocator, io_ctx.io());
    pool.cap = 2;
    defer pool.deinit();

    const a1 = try pool.acquire();
    const a2 = try pool.acquire();
    const a3 = try pool.acquire();

    pool.release(a1);
    pool.release(a2);
    // Third release would exceed cap; arena should be freed instead of pooled.
    pool.release(a3);
    try std.testing.expectEqual(@as(usize, 2), pool.free_list.items.len);
}

test "ArenaPool: reset retains capacity between acquires" {
    var io_ctx = test_utils.TestIo.init(std.testing.allocator);
    defer io_ctx.deinit();
    var pool = ArenaPool.init(std.testing.allocator, io_ctx.io());
    defer pool.deinit();

    const a = try pool.acquire();
    _ = try a.allocator().alloc(u8, 1024);
    pool.release(a);

    const a2 = try pool.acquire();
    // Same arena, but `acquire` calls reset(.retain_capacity) so allocations
    // from the prior frame are reclaimable. Allocating again should succeed
    // and ideally hit the retained pages — we just verify it works.
    _ = try a2.allocator().alloc(u8, 1024);
    pool.release(a2);
}

test "ArenaPool: deinit frees all pooled arenas" {
    // This test is mainly about leak detection — std.testing.allocator
    // will fail the test if anything was leaked.
    var io_ctx = test_utils.TestIo.init(std.testing.allocator);
    defer io_ctx.deinit();
    var pool = ArenaPool.init(std.testing.allocator, io_ctx.io());

    var arenas: [4]*std.heap.ArenaAllocator = undefined;
    for (&arenas) |*slot| slot.* = try pool.acquire();
    for (arenas) |a| pool.release(a);
    try std.testing.expectEqual(@as(usize, 4), pool.free_list.items.len);

    pool.deinit();
}
