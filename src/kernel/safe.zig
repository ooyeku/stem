//! Bounded-cast and validation helpers used at trust boundaries (protocol
//! decode, LSP message parsing, untrusted plugin inputs, etc.). Centralized
//! so we can keep the conversion patterns audited and consistent.
//!
//! The goal: never panic on adversarial / malformed input. Every helper here
//! either returns an error or saturates — none panic.

const std = @import("std");

/// Lossless cast from a wider integer type to a narrower one. Returns null
/// if the value doesn't fit.
pub fn cast(comptime T: type, value: anytype) ?T {
    return std.math.cast(T, value);
}

/// Saturating cast. Returns the closest representable value of `T`.
pub fn saturatingCast(comptime T: type, value: anytype) T {
    return std.math.lossyCast(T, value);
}

/// Safer `@enumFromInt`: returns null if the value doesn't correspond to a
/// declared enum tag. Walks the enum's tag list at comptime.
pub fn intToEnum(comptime E: type, value: anytype) ?E {
    inline for (@typeInfo(E).@"enum".fields) |f| {
        if (value == f.value) return @field(E, f.name);
    }
    return null;
}

/// Convert a Unicode scalar from a wire value. Returns null if `value` is
/// not a valid Unicode code point (out of range or in the surrogate band).
pub fn intToCodepoint(value: u32) ?u21 {
    if (value > 0x10FFFF) return null;
    if (value >= 0xD800 and value <= 0xDFFF) return null;
    return @intCast(value);
}

/// Convert any std.json.Value variant to a u32 if representable. Used by
/// LSP message handlers — JSON-RPC numbers can arrive as either int or
/// float, and adversarial servers may send NaN, inf, negative, or huge
/// values.
pub fn jsonToU32(v: std.json.Value) ?u32 {
    return switch (v) {
        .integer => |iv| if (iv < 0 or iv > std.math.maxInt(u32)) null else @intCast(iv),
        .float => |fv| blk: {
            if (!std.math.isFinite(fv)) break :blk null;
            if (fv < 0 or fv > @as(f64, std.math.maxInt(u32))) break :blk null;
            break :blk @intFromFloat(fv);
        },
        else => null,
    };
}

test "cast lossless" {
    try std.testing.expectEqual(@as(?u8, 200), cast(u8, @as(u32, 200)));
    try std.testing.expectEqual(@as(?u8, null), cast(u8, @as(u32, 300)));
    try std.testing.expectEqual(@as(?u16, null), cast(u16, @as(i32, -1)));
}

test "saturatingCast clamps" {
    try std.testing.expectEqual(@as(u8, 255), saturatingCast(u8, @as(u32, 1000)));
    try std.testing.expectEqual(@as(u8, 0), saturatingCast(u8, @as(i32, -5)));
    try std.testing.expectEqual(@as(u16, 65535), saturatingCast(u16, @as(usize, std.math.maxInt(usize))));
}

test "intToEnum rejects out-of-range" {
    const E = enum(u8) { a = 0, b = 1, c = 2 };
    try std.testing.expectEqual(E.b, intToEnum(E, @as(u8, 1)).?);
    try std.testing.expectEqual(@as(?E, null), intToEnum(E, @as(u8, 99)));
}

test "intToCodepoint validates" {
    try std.testing.expectEqual(@as(?u21, 'A'), intToCodepoint('A'));
    try std.testing.expectEqual(@as(?u21, null), intToCodepoint(0x110000));
    try std.testing.expectEqual(@as(?u21, null), intToCodepoint(0xD800));
}

test "jsonToU32 rejects NaN/inf/negative/oversize" {
    try std.testing.expectEqual(@as(?u32, 5), jsonToU32(.{ .integer = 5 }));
    try std.testing.expectEqual(@as(?u32, null), jsonToU32(.{ .integer = -1 }));
    try std.testing.expectEqual(@as(?u32, null), jsonToU32(.{ .integer = 5_000_000_000 }));
    try std.testing.expectEqual(@as(?u32, 7), jsonToU32(.{ .float = 7.0 }));
    try std.testing.expectEqual(@as(?u32, null), jsonToU32(.{ .float = std.math.nan(f64) }));
    try std.testing.expectEqual(@as(?u32, null), jsonToU32(.{ .float = std.math.inf(f64) }));
    try std.testing.expectEqual(@as(?u32, null), jsonToU32(.{ .float = -1.0 }));
    try std.testing.expectEqual(@as(?u32, null), jsonToU32(.{ .string = "5" }));
}
