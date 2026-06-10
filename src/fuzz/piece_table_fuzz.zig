const std = @import("std");
const stem = @import("stem");
const PieceTable = stem.piece_table.PieceTable;

const FuzzContext = struct {
    allocator: std.mem.Allocator,
};

fn fuzzBytes(smith: *std.testing.Smith, buf: *[512]u8) []const u8 {
    const len: usize = @intCast(smith.slice(buf));
    return buf[0..len];
}

fn fuzzRandomInserts(ctx: FuzzContext, input: []const u8) anyerror!void {
    if (input.len < 2) return;

    var pt = try PieceTable.init(ctx.allocator, "");
    defer pt.deinit();

    const offset_seed = input[0];
    const insert_data = input[1..];

    const current_len = pt.totalLength();
    const insert_offset = if (current_len == 0)
        0
    else
        @as(usize, offset_seed) % (current_len + 1);

    try pt.insert(insert_offset, insert_data);

    const expected_len = current_len + insert_data.len;
    try std.testing.expectEqual(expected_len, pt.totalLength());
}

fn fuzzRandomDeletes(ctx: FuzzContext, input: []const u8) anyerror!void {
    if (input.len < 3) return;

    const offset_seed = input[0];
    const len_seed = input[1];
    const initial_content = input[2..];

    var pt = try PieceTable.init(ctx.allocator, initial_content);
    defer pt.deinit();

    const total = pt.totalLength();
    if (total == 0) return;

    const delete_offset = @as(usize, offset_seed) % total;
    const max_delete_len = total - delete_offset;
    const delete_len = if (max_delete_len == 0)
        0
    else
        (@as(usize, len_seed) % max_delete_len) + 1;

    pt.delete(delete_offset, delete_len) catch |err| {
        if (err != error.OutOfMemory) return err;
    };

    const expected_len = total - delete_len;
    try std.testing.expectEqual(expected_len, pt.totalLength());
}

fn fuzzInterleavedOps(ctx: FuzzContext, input: []const u8) anyerror!void {
    if (input.len < 4) return;

    var pt = try PieceTable.init(ctx.allocator, "initial");
    defer pt.deinit();

    var i: usize = 0;
    while (i + 3 < input.len) : (i += 4) {
        const op_type = input[i] & 1;
        const offset_seed = input[i + 1];
        const len_seed = input[i + 2];
        const char_seed = input[i + 3];

        const total = pt.totalLength();

        if (op_type == 0 and total < 10_000) {
            const offset = if (total == 0) 0 else @as(usize, offset_seed) % (total + 1);
            const insert_len = (@as(usize, len_seed) % 10) + 1;
            const char: u8 = if (char_seed >= 32 and char_seed < 127) char_seed else 'x';

            var buf: [10]u8 = undefined;
            @memset(buf[0..insert_len], char);
            pt.insert(offset, buf[0..insert_len]) catch {};
        } else if (total > 0) {
            const offset = @as(usize, offset_seed) % total;
            const max_len = total - offset;
            const del_len = if (max_len == 0) 0 else (@as(usize, len_seed) % @min(max_len, 10)) + 1;
            pt.delete(offset, del_len) catch {};
        }
    }

    const content = pt.toString(ctx.allocator) catch return;
    defer ctx.allocator.free(content);
}

fn fuzzEdgeOffsets(ctx: FuzzContext, input: []const u8) anyerror!void {
    var pt = try PieceTable.init(ctx.allocator, input);
    defer pt.deinit();

    pt.insert(0, "X") catch {};
    pt.insert(pt.totalLength(), "Y") catch {};
    if (pt.totalLength() > 1) {
        pt.insert(pt.totalLength() / 2, "Z") catch {};
    }

    if (pt.totalLength() > 0) {
        pt.delete(0, 1) catch {};
    }
    if (pt.totalLength() > 0) {
        pt.delete(pt.totalLength() - 1, 1) catch {};
    }
}

fn fuzzRandomInsertsSmith(ctx: FuzzContext, smith: *std.testing.Smith) anyerror!void {
    var buf: [512]u8 = undefined;
    try fuzzRandomInserts(ctx, fuzzBytes(smith, &buf));
}

fn fuzzRandomDeletesSmith(ctx: FuzzContext, smith: *std.testing.Smith) anyerror!void {
    var buf: [512]u8 = undefined;
    try fuzzRandomDeletes(ctx, fuzzBytes(smith, &buf));
}

fn fuzzInterleavedOpsSmith(ctx: FuzzContext, smith: *std.testing.Smith) anyerror!void {
    var buf: [512]u8 = undefined;
    try fuzzInterleavedOps(ctx, fuzzBytes(smith, &buf));
}

fn fuzzEdgeOffsetsSmith(ctx: FuzzContext, smith: *std.testing.Smith) anyerror!void {
    var buf: [512]u8 = undefined;
    try fuzzEdgeOffsets(ctx, fuzzBytes(smith, &buf));
}

test "fuzz: PieceTable random insertions" {
    const ctx = FuzzContext{ .allocator = std.testing.allocator };
    try std.testing.fuzz(ctx, fuzzRandomInsertsSmith, .{});
}

test "fuzz: PieceTable random deletions" {
    const ctx = FuzzContext{ .allocator = std.testing.allocator };
    try std.testing.fuzz(ctx, fuzzRandomDeletesSmith, .{});
}

test "fuzz: PieceTable interleaved operations" {
    const ctx = FuzzContext{ .allocator = std.testing.allocator };
    try std.testing.fuzz(ctx, fuzzInterleavedOpsSmith, .{});
}

test "fuzz: PieceTable edge offsets" {
    const ctx = FuzzContext{ .allocator = std.testing.allocator };
    try std.testing.fuzz(ctx, fuzzEdgeOffsetsSmith, .{});
}
