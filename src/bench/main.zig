//! Microbenchmark harness for the hot paths behind Stem's editing and
//! rendering responsiveness. Run with:
//!
//!     zig build bench -Doptimize=ReleaseFast
//!
//! This is a regression *tripwire*, not a statistics package: each case
//! prints ns/op and ops/sec so a human — or a diff of two runs — can
//! spot a slowdown. Keep cases synchronous and allocation-honest so the
//! numbers stay comparable run to run. Always build ReleaseFast; Debug
//! numbers are dominated by safety checks and only meaningful relative
//! to other Debug runs.
//!
//! Current coverage is the piece table — the substrate under both
//! editing and the per-frame render path (`getVisibleLines` is called
//! every frame). EditorState motions and syntax highlighting are the
//! obvious next suites; they need an `std.Io` / async parse worker
//! respectively, so they're left as follow-ups rather than bolted on
//! half-working here.

const std = @import("std");
const stem = @import("stem");
const PieceTable = stem.piece_table.PieceTable;

const Result = struct {
    name: []const u8,
    iters: u64,
    ns_total: u64,

    fn perOp(self: Result) u64 {
        return if (self.iters == 0) 0 else self.ns_total / self.iters;
    }

    fn opsPerSec(self: Result) u64 {
        if (self.ns_total == 0) return 0;
        const ops = @as(f64, @floatFromInt(self.iters)) * 1_000_000_000.0 /
            @as(f64, @floatFromInt(self.ns_total));
        return @intFromFloat(ops);
    }
};

fn report(r: Result) void {
    std.debug.print(
        "  {s:<30} {d:>8} iters   {d:>9} ns/op   {d:>14} ops/s\n",
        .{ r.name, r.iters, r.perOp(), r.opsPerSec() },
    );
}

/// Build `line_count` lines of representative source so the buffer is
/// multi-megabyte and multi-piece — the shape that stresses the table.
fn buildSource(alloc: std.mem.Allocator, line_count: usize) ![]u8 {
    const line = "fn process(value: usize) usize { return value * 2 + 1; } // padding\n";
    var buf = try std.ArrayListUnmanaged(u8).initCapacity(alloc, line.len * line_count);
    errdefer buf.deinit(alloc);
    var i: usize = 0;
    while (i < line_count) : (i += 1) buf.appendSliceAssumeCapacity(line);
    return buf.toOwnedSlice(alloc);
}

fn freeLines(alloc: std.mem.Allocator, lines: [][]const u8) void {
    for (lines) |ln| alloc.free(ln);
    alloc.free(lines);
}

/// Monotonic nanosecond reading. `awake` is the elapsed-time clock
/// (excludes system sleep) — the right base for measuring wall time of
/// a tight loop. `std.time.Timer` was removed in the 0.16 Io rework.
fn nowNs(io: std.Io) u64 {
    return @intCast(std.Io.Clock.awake.now(io).toNanoseconds());
}

pub fn main() !void {
    const alloc = std.heap.c_allocator;

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const line_count: usize = 50_000;
    const source = try buildSource(alloc, line_count);
    defer alloc.free(source);

    std.debug.print(
        "stem piece-table benchmarks  ({d} lines, {d:.1} MB)\n",
        .{ line_count, @as(f64, @floatFromInt(source.len)) / (1024.0 * 1024.0) },
    );
    std.debug.print("  (build -Doptimize=ReleaseFast for meaningful numbers)\n\n", .{});

    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rand = prng.random();

    // 1. Construction: init scans the content for line boundaries, so
    //    this is the O(n) cost paid on every file open.
    {
        const iters: u64 = 500;
        const t0 = nowNs(io);
        var i: u64 = 0;
        while (i < iters) : (i += 1) {
            var pt = try PieceTable.init(alloc, source);
            std.mem.doNotOptimizeAway(pt.lineCount());
            pt.deinit();
        }
        report(.{ .name = "init + lineCount (open)", .iters = iters, .ns_total = nowNs(io) - t0 });
    }

    // 2. getVisibleLines: the per-frame render hot path. Extract a
    //    50-row window from a moving scroll position.
    {
        var pt = try PieceTable.init(alloc, source);
        defer pt.deinit();
        const total = pt.lineCount();
        const window: usize = 50;
        const span = if (total > window) total - window else 1;

        const iters: u64 = 50_000;
        const t0 = nowNs(io);
        var i: u64 = 0;
        while (i < iters) : (i += 1) {
            const start = rand.uintLessThan(usize, span);
            const lines = try pt.getVisibleLines(alloc, start, window);
            std.mem.doNotOptimizeAway(lines.len);
            freeLines(alloc, lines);
        }
        report(.{ .name = "getVisibleLines (render)", .iters = iters, .ns_total = nowNs(io) - t0 });
    }

    // 3. insert: scattered single-char inserts, each splitting a piece.
    {
        var pt = try PieceTable.init(alloc, source);
        defer pt.deinit();
        const iters: u64 = 20_000;
        const t0 = nowNs(io);
        var i: u64 = 0;
        while (i < iters) : (i += 1) {
            const off = rand.uintLessThan(usize, pt.totalLength() + 1);
            try pt.insert(off, "x");
        }
        report(.{ .name = "insert (scattered 1ch)", .iters = iters, .ns_total = nowNs(io) - t0 });
    }

    // 4. delete: scattered single-char deletes shrinking the buffer.
    {
        var pt = try PieceTable.init(alloc, source);
        defer pt.deinit();
        const iters: u64 = 20_000;
        const t0 = nowNs(io);
        var i: u64 = 0;
        while (i < iters) : (i += 1) {
            const len = pt.totalLength();
            if (len == 0) break;
            const off = rand.uintLessThan(usize, len);
            pt.delete(off, 1) catch {};
        }
        report(.{ .name = "delete (scattered 1ch)", .iters = iters, .ns_total = nowNs(io) - t0 });
    }

    // 5. toString: full-buffer flatten (used by syntax parse submit).
    {
        var pt = try PieceTable.init(alloc, source);
        defer pt.deinit();
        const iters: u64 = 500;
        const t0 = nowNs(io);
        var i: u64 = 0;
        while (i < iters) : (i += 1) {
            const s = try pt.toString(alloc);
            std.mem.doNotOptimizeAway(s.len);
            alloc.free(s);
        }
        report(.{ .name = "toString (full flatten)", .iters = iters, .ns_total = nowNs(io) - t0 });
    }

    // 6. find: forward search for a needle that occurs on every line.
    {
        var pt = try PieceTable.init(alloc, source);
        defer pt.deinit();
        const iters: u64 = 5_000;
        const t0 = nowNs(io);
        var i: u64 = 0;
        while (i < iters) : (i += 1) {
            const hit = try pt.find("padding", 0);
            std.mem.doNotOptimizeAway(hit);
        }
        report(.{ .name = "find (forward)", .iters = iters, .ns_total = nowNs(io) - t0 });
    }

    std.debug.print("\n", .{});
}
