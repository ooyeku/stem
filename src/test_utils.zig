//! Shared test helpers and fixtures.
//!
//! Test architecture conventions used across the codebase:
//!
//! 1. **Inline tests** live next to the code they exercise (`test "..." { ... }`
//!    blocks at the bottom of each module). This is the default — use it
//!    unless the test file would dwarf the module.
//!
//! 2. **`*_test.zig` files** are for cross-module integration tests that
//!    would mix concerns or require infrastructure too heavy for inline.
//!    Example: `services/lsp_manager_test.zig`.
//!
//! 3. **Fixtures** live in this file under a struct namespace
//!    (`TestIo`, `Tempdir`, `ProjectFixture`, etc.). Each fixture owns its
//!    own cleanup via `defer fixture.deinit()`.
//!
//! 4. **Tests must run with `std.testing.allocator`** so leaks fail the
//!    test. Don't reach for `std.heap.page_allocator` to "work around"
//!    issues — that's hiding a real leak.
//!
//! 5. **Tests must not touch the user's filesystem, network, or env.**
//!    Use `Tempdir` / `ProjectFixture` / `MockFileSystem` for filesystem,
//!    and `MockLSPServer` for any LSP interaction. CI must be reproducible.
//!
//! 6. **Async / threaded tests** need a `TestIo` for the mutex/condvar
//!    primitives. Spin-wait helpers like `waitUntil` make threading tests
//!    deterministic — never use bare `sleep`.

const std = @import("std");
const PieceTable = @import("core/piece_table.zig").PieceTable;
const EditorState = @import("core/state.zig").EditorState;

/// Per-test Threaded IO. Use:
///   var io_ctx = TestIo.init(std.testing.allocator);
///   defer io_ctx.deinit();
///   const io = io_ctx.io();
/// Pass `allocator` explicitly for tests that need a non-testing allocator.
pub const TestIo = struct {
    threaded: std.Io.Threaded,

    pub fn init(allocator: std.mem.Allocator) TestIo {
        return .{ .threaded = std.Io.Threaded.init(allocator, .{}) };
    }

    pub fn deinit(self: *TestIo) void {
        self.threaded.deinit();
    }

    pub fn io(self: *TestIo) std.Io {
        return self.threaded.io();
    }
};

/// RAII-style temporary directory. Creates a unique directory under the
/// system temp root, returns its absolute path, and recursively deletes
/// it on `deinit`. Tests that touch the filesystem should always go
/// through this — never write to `/tmp` or the cwd directly.
///
/// Usage:
///   var tmp = try Tempdir.init(std.testing.allocator);
///   defer tmp.deinit();
///   try tmp.writeFile("hello.txt", "hi");
///   const path = try tmp.joinPath(std.testing.allocator, "hello.txt");
///   defer std.testing.allocator.free(path);
pub const Tempdir = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []u8,

    /// Atomic counter for unique tempdir names within a test process.
    var tempdir_seq: std.atomic.Value(u64) = .{ .raw = 0 };

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Tempdir {
        // Pick a platform-appropriate tmp root. POSIX: $TMPDIR or /tmp.
        // Windows: %TEMP% or %TMP%. The fallback chain matches what
        // most language runtimes (CPython's tempfile, Go's os.TempDir,
        // Rust's env::temp_dir) settle on.
        const tmp_root = try pickTmpRoot(allocator);
        defer allocator.free(tmp_root);

        const seq = tempdir_seq.fetchAdd(1, .monotonic);
        const tag: u32 = @intCast(@as(usize, @bitCast(@intFromPtr(&tempdir_seq))) & 0xffffffff);

        const leaf = try std.fmt.allocPrint(allocator, "stem-test-{x}-{x}", .{ tag, seq });
        defer allocator.free(leaf);

        const path = try std.fs.path.join(allocator, &.{ tmp_root, leaf });
        errdefer allocator.free(path);

        try std.Io.Dir.createDirAbsolute(io, path, .default_dir);
        return .{ .allocator = allocator, .io = io, .path = path };
    }

    /// Returns an allocator-owned path to the OS tmp root.
    /// Caller is responsible for freeing.
    fn pickTmpRoot(allocator: std.mem.Allocator) ![]u8 {
        const builtin = @import("builtin");
        // Zig 0.16 dropped the cross-platform `std.process.getEnvVarOwned`
        // helper. `std.process.Environ.Block.global` is Windows-only
        // (POSIX uses `PosixBlock` which has no global sentinel). Plain
        // libc `getenv` works on every libc-linked OS we care about
        // (Windows includes MSVC libc, macOS / Linux glibc / musl all
        // provide it), so use that and dupe the result.
        const get = struct {
            fn lookup(gpa: std.mem.Allocator, key: [:0]const u8) ?[]u8 {
                const raw = std.c.getenv(key.ptr) orelse return null;
                const slice = std.mem.span(raw);
                if (slice.len == 0) return null;
                return gpa.dupe(u8, slice) catch null;
            }
        }.lookup;

        if (builtin.os.tag == .windows) {
            if (get(allocator, "TEMP")) |v| return v;
            if (get(allocator, "TMP")) |v| return v;
            // Last-resort fallback: per-user local app data temp dir.
            if (get(allocator, "LOCALAPPDATA")) |v| {
                defer allocator.free(v);
                return std.fs.path.join(allocator, &.{ v, "Temp" });
            }
            return allocator.dupe(u8, "C:\\Windows\\Temp");
        }
        if (get(allocator, "TMPDIR")) |v| return v;
        return allocator.dupe(u8, "/tmp");
    }

    pub fn deinit(self: *Tempdir) void {
        // Best-effort recursive remove; tests should clean up after
        // themselves but a leftover sub-file shouldn't fail the test.
        std.Io.Dir.cwd().deleteTree(self.io, self.path) catch {};
        self.allocator.free(self.path);
    }

    pub fn writeFile(self: *Tempdir, rel_path: []const u8, content: []const u8) !void {
        const full = try std.fs.path.join(self.allocator, &.{ self.path, rel_path });
        defer self.allocator.free(full);

        if (std.fs.path.dirname(full)) |dir| {
            std.Io.Dir.createDirAbsolute(self.io, dir, .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
        var file = try std.Io.Dir.createFileAbsolute(self.io, full, .{});
        defer file.close(self.io);
        try file.writeStreamingAll(self.io, content);
    }

    pub fn makeDir(self: *Tempdir, rel_path: []const u8) !void {
        const full = try std.fs.path.join(self.allocator, &.{ self.path, rel_path });
        defer self.allocator.free(full);
        std.Io.Dir.createDirAbsolute(self.io, full, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    pub fn joinPath(self: *const Tempdir, allocator: std.mem.Allocator, rel_path: []const u8) ![]u8 {
        return std.fs.path.join(allocator, &.{ self.path, rel_path });
    }

    pub fn fileExists(self: *const Tempdir, rel_path: []const u8) bool {
        const full = std.fs.path.join(self.allocator, &.{ self.path, rel_path }) catch return false;
        defer self.allocator.free(full);
        std.Io.Dir.accessAbsolute(self.io, full, .{}) catch return false;
        return true;
    }
};

/// Builds a fake project tree on disk. Pass a slice of `File{ path, content }`
/// records and it materializes them under a `Tempdir`, including any
/// intermediate directories. Used by directory-scan / project-root
/// detection / global-search tests.
pub const ProjectFixture = struct {
    tmp: Tempdir,

    pub const File = struct {
        rel_path: []const u8,
        content: []const u8 = "",
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, files: []const File) !ProjectFixture {
        var tmp = try Tempdir.init(allocator, io);
        errdefer tmp.deinit();
        for (files) |f| try tmp.writeFile(f.rel_path, f.content);
        return .{ .tmp = tmp };
    }

    pub fn deinit(self: *ProjectFixture) void {
        self.tmp.deinit();
    }

    pub fn root(self: *const ProjectFixture) []const u8 {
        return self.tmp.path;
    }
};

/// Poll a predicate until it returns true or `timeout_ms` elapses. Used
/// for threading tests where you need to wait for a worker to finish
/// without burning CPU or trusting an arbitrary `sleep`.
///
/// Returns true on success, false on timeout. Pass `allocator` only if
/// the predicate needs one; otherwise `{}` and a `fn(void) bool`.
pub fn waitUntil(io: std.Io, timeout_ms: u64, ctx: anytype, predicate: fn (@TypeOf(ctx)) bool) bool {
    // Bounded retry with 5 ms steps. Not wall-clock-accurate but good
    // enough for test serialization — the underlying signal fires in ms.
    const step_ms: i64 = 5;
    const max_iters = (timeout_ms + @as(u64, @intCast(step_ms)) - 1) / @as(u64, @intCast(step_ms)) + 1;
    var i: u64 = 0;
    while (i < max_iters) : (i += 1) {
        if (predicate(ctx)) return true;
        std.Io.sleep(io, .fromMilliseconds(step_ms), .awake) catch return predicate(ctx);
    }
    return predicate(ctx);
}

pub const PieceTableTestUtils = struct {
    pub fn createTestBuffer(allocator: std.mem.Allocator, content: []const u8) !PieceTable {
        return try PieceTable.init(allocator, content);
    }

    pub fn createEmptyBuffer(allocator: std.mem.Allocator) !PieceTable {
        return try PieceTable.init(allocator, "");
    }

    pub fn expectContent(pt: *PieceTable, expected: []const u8) !void {
        const actual = try pt.toString(std.testing.allocator);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(expected, actual);
    }

    pub fn createLargeBuffer(allocator: std.mem.Allocator, size: usize) !PieceTable {
        var content = try allocator.alloc(u8, size);
        defer allocator.free(content);

        for (0..size) |i| {
            content[i] = @intCast('A' + (i % 26));
        }

        return try PieceTable.init(allocator, content);
    }
};

pub const EditorStateTestUtils = struct {
    pub fn createTestState(allocator: std.mem.Allocator, io: std.Io, content: []const u8) !EditorState {
        return try EditorState.init(allocator, io, content);
    }

    pub fn createEmptyState(allocator: std.mem.Allocator, io: std.Io) !EditorState {
        return try EditorState.init(allocator, io, "");
    }

    pub fn setCursor(state: *EditorState, row: usize, col: usize) void {
        state.cursor_row = row;
        state.cursor_col = col;
    }

    pub fn expectCursor(state: *EditorState, expected_row: usize, expected_col: usize) !void {
        try std.testing.expectEqual(expected_row, state.cursor_row);
        try std.testing.expectEqual(expected_col, state.cursor_col);
    }
};

pub const MemoryTestUtils = struct {
    pub const AllocationTracker = struct {
        allocator: std.mem.Allocator,
        allocations: std.ArrayListUnmanaged(*anyopaque) = .empty,

        pub fn init(allocator: std.mem.Allocator) AllocationTracker {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *AllocationTracker) void {
            self.allocations.deinit(self.allocator);
        }

        pub fn track(self: *AllocationTracker, ptr: *anyopaque) !void {
            try self.allocations.append(self.allocator, ptr);
        }

        /// Drop a pointer from the live set. Without this every tracked
        /// allocation looked like a leak, so `testNoLeaks` could only pass
        /// for a function that allocated nothing at all.
        pub fn untrack(self: *AllocationTracker, ptr: *anyopaque) void {
            for (self.allocations.items, 0..) |candidate, i| {
                if (candidate == ptr) {
                    _ = self.allocations.swapRemove(i);
                    return;
                }
            }
        }

        pub fn verifyClean(self: *AllocationTracker) !void {
            if (self.allocations.items.len > 0) {
                std.debug.print("Memory leak detected: {} unfreed allocations\n", .{self.allocations.items.len});
                return error.MemoryLeak;
            }
        }
    };

    pub fn testNoLeaks(allocator: std.mem.Allocator, comptime testFn: fn (std.mem.Allocator) anyerror!void) !void {
        var tracker = AllocationTracker.init(allocator);
        defer tracker.deinit();

        var tracking_allocator = TrackingAllocator.init(allocator, &tracker);

        try testFn(tracking_allocator.allocator());

        try tracker.verifyClean();
    }

    pub const TrackingAllocator = struct {
        parent_allocator: std.mem.Allocator,
        tracker: *AllocationTracker,

        pub fn init(parent: std.mem.Allocator, tracker: *AllocationTracker) TrackingAllocator {
            return .{
                .parent_allocator = parent,
                .tracker = tracker,
            };
        }

        pub fn allocator(self: *TrackingAllocator) std.mem.Allocator {
            return .{
                .ptr = self,
                .vtable = &.{
                    .alloc = alloc,
                    .resize = resize,
                    .remap = std.mem.Allocator.noRemap,
                    .free = free,
                },
            };
        }

        fn alloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
            const result = self.parent_allocator.rawAlloc(len, ptr_align, ret_addr);
            if (result) |ptr| {
                self.tracker.track(ptr) catch {};
            }
            return result;
        }

        fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
            const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
            return self.parent_allocator.rawResize(buf, buf_align, new_len, ret_addr);
        }

        fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
            const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
            self.tracker.untrack(buf.ptr);
            self.parent_allocator.rawFree(buf, buf_align, ret_addr);
        }
    };
};

pub const PerformanceTestUtils = struct {
    pub fn expectPerformance(comptime func: anytype, args: anytype, max_nanos: u64) !void {
        var io_ctx = TestIo.init(std.testing.allocator);
        defer io_ctx.deinit();
        const io = io_ctx.io();
        const start = std.Io.Clock.awake.now(io);
        const ReturnType = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
        if (@typeInfo(ReturnType) == .error_union) {
            _ = try @call(.auto, func, args);
        } else {
            _ = @call(.auto, func, args);
        }
        const end = std.Io.Clock.awake.now(io);
        const duration_ns: i96 = end.nanoseconds - start.nanoseconds;
        const duration: u64 = if (duration_ns < 0) 0 else @intCast(duration_ns);

        if (duration > max_nanos) {
            std.debug.print("Performance test failed: {}ns > {}ns\n", .{ duration, max_nanos });
            return error.PerformanceTestFailed;
        }
    }

    pub fn benchmark(comptime func: anytype, args: anytype, runs: usize) !struct { avg_time: u64, min_time: u64, max_time: u64 } {
        var io_ctx = TestIo.init(std.testing.allocator);
        defer io_ctx.deinit();
        const io = io_ctx.io();
        var total_time: u64 = 0;
        var min_time: u64 = std.math.maxInt(u64);
        var max_time: u64 = 0;

        for (0..runs) |_| {
            const start = std.Io.Clock.awake.now(io);
            _ = try @call(.auto, func, args);
            const end = std.Io.Clock.awake.now(io);
            const duration_ns: i96 = end.nanoseconds - start.nanoseconds;
            const duration: u64 = if (duration_ns < 0) 0 else @intCast(duration_ns);

            total_time += duration;
            min_time = @min(min_time, duration);
            max_time = @max(max_time, duration);
        }

        return .{
            .avg_time = total_time / runs,
            .min_time = min_time,
            .max_time = max_time,
        };
    }
};

pub const StringTestUtils = struct {
    pub fn createUtf8TestString(allocator: std.mem.Allocator) ![]const u8 {
        return try std.fmt.allocPrint(allocator,
            \\Hello World 🌍
            \\Multi-byte: éñü
            \\Combining: á
            \\Control: \n\t\r
            \\Numbers: 12345
            \\Symbols: !@#$%^&*()
        , .{});
    }

    pub fn expectEqualStrings(expected: []const u8, actual: []const u8) !void {
        if (!std.mem.eql(u8, expected, actual)) {
            const min_len = @min(expected.len, actual.len);
            var diff_pos: usize = 0;
            while (diff_pos < min_len and expected[diff_pos] == actual[diff_pos]) {
                diff_pos += 1;
            }

            std.debug.print("String mismatch at position {}:\n", .{diff_pos});
            std.debug.print("Expected: '{s}'\n", .{expected});
            std.debug.print("Actual:   '{s}'\n", .{actual});

            if (diff_pos < expected.len and diff_pos < actual.len) {
                std.debug.print("Diff: expected 0x{x}, got 0x{x}\n", .{ expected[diff_pos], actual[diff_pos] });
            }

            return error.StringMismatch;
        }
    }

    pub fn randomString(allocator: std.mem.Allocator, prng: *std.Random.DefaultPrng, length: usize) ![]u8 {
        var result = try allocator.alloc(u8, length);
        for (0..length) |i| {
            result[i] = @intCast(' ' + prng.random().intRangeAtMost(u8, 0, 94));
        }
        return result;
    }
};

pub const MockUtils = struct {
    pub const MockLSPServer = struct {
        allocator: std.mem.Allocator,
        responses: std.StringHashMap([]const u8),
        received_messages: std.ArrayListUnmanaged([]const u8),

        pub fn init(allocator: std.mem.Allocator) MockLSPServer {
            return .{
                .allocator = allocator,
                .responses = std.StringHashMap([]const u8).init(allocator),
                .received_messages = .empty,
            };
        }

        pub fn deinit(self: *MockLSPServer) void {
            var it = self.responses.valueIterator();
            while (it.next()) |response| {
                self.allocator.free(response.*);
            }
            self.responses.deinit();

            for (self.received_messages.items) |msg| {
                self.allocator.free(msg);
            }
            self.received_messages.deinit(self.allocator);
        }

        pub fn addResponse(self: *MockLSPServer, method: []const u8, response: []const u8) !void {
            const owned_response = try self.allocator.dupe(u8, response);
            try self.responses.put(method, owned_response);
        }

        pub fn getResponse(self: *MockLSPServer, method: []const u8) ?[]const u8 {
            return self.responses.get(method);
        }
    };

    pub const MockFileSystem = struct {
        allocator: std.mem.Allocator,
        files: std.StringHashMap([]const u8),

        pub fn init(allocator: std.mem.Allocator) MockFileSystem {
            return .{
                .allocator = allocator,
                .files = std.StringHashMap([]const u8).init(allocator),
            };
        }

        pub fn deinit(self: *MockFileSystem) void {
            var it = self.files.valueIterator();
            while (it.next()) |content| {
                self.allocator.free(content.*);
            }
            self.files.deinit();
        }

        pub fn addFile(self: *MockFileSystem, path: []const u8, content: []const u8) !void {
            const owned_content = try self.allocator.dupe(u8, content);
            try self.files.put(path, owned_content);
        }

        pub fn readFile(self: *MockFileSystem, path: []const u8) ?[]const u8 {
            return self.files.get(path);
        }
    };
};

pub const expect = std.testing.expect;
pub const expectEqual = std.testing.expectEqual;
pub const expectEqualStrings = std.testing.expectEqualStrings;
pub const expectError = std.testing.expectError;

// ---------------------------------------------------------------------
// Self-tests for the fixtures themselves. If these break, every other
// test that depends on the fixture is suspect.
// ---------------------------------------------------------------------

test "Tempdir: creates and removes" {
    var io_ctx = TestIo.init(std.testing.allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();

    var tmp = try Tempdir.init(std.testing.allocator, io);
    const saved_path = try std.testing.allocator.dupe(u8, tmp.path);
    defer std.testing.allocator.free(saved_path);

    // Directory exists after init.
    try std.Io.Dir.accessAbsolute(io, tmp.path, .{});

    tmp.deinit();

    // And is gone after deinit.
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io, saved_path, .{}));
}

test "Tempdir: writeFile + fileExists + joinPath" {
    var io_ctx = TestIo.init(std.testing.allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();

    var tmp = try Tempdir.init(std.testing.allocator, io);
    defer tmp.deinit();

    try tmp.writeFile("hello.txt", "world");
    try std.testing.expect(tmp.fileExists("hello.txt"));
    try std.testing.expect(!tmp.fileExists("missing.txt"));

    const path = try tmp.joinPath(std.testing.allocator, "hello.txt");
    defer std.testing.allocator.free(path);
    // Assert via basename rather than `endsWith(.., "/hello.txt")`
    // so the test passes on Windows where joinPath uses `\`.
    try std.testing.expectEqualStrings("hello.txt", std.fs.path.basename(path));

    const content = try std.Io.Dir.cwd().readFileAlloc(io, path, std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("world", content);
}

test "ProjectFixture: builds nested tree" {
    var io_ctx = TestIo.init(std.testing.allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();

    var fx = try ProjectFixture.init(std.testing.allocator, io, &.{
        .{ .rel_path = "build.zig", .content = "// build" },
        .{ .rel_path = "src/main.zig", .content = "fn main() {}" },
        .{ .rel_path = "src/lib/util.zig", .content = "fn util() {}" },
    });
    defer fx.deinit();

    try std.testing.expect(fx.tmp.fileExists("build.zig"));
    try std.testing.expect(fx.tmp.fileExists("src/main.zig"));
    try std.testing.expect(fx.tmp.fileExists("src/lib/util.zig"));
}

test "waitUntil: returns true when predicate succeeds" {
    var io_ctx = TestIo.init(std.testing.allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();

    const Ctx = struct {
        counter: *u32,
        fn pred(self: @This()) bool {
            self.counter.* += 1;
            return self.counter.* >= 3;
        }
    };
    var n: u32 = 0;
    const ok = waitUntil(io, 1000, Ctx{ .counter = &n }, Ctx.pred);
    try std.testing.expect(ok);
    try std.testing.expect(n >= 3);
}

test "waitUntil: returns false on timeout" {
    var io_ctx = TestIo.init(std.testing.allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();

    const Ctx = struct {
        fn pred(_: @This()) bool {
            return false;
        }
    };
    const ok = waitUntil(io, 50, Ctx{}, Ctx.pred);
    try std.testing.expect(!ok);
}
