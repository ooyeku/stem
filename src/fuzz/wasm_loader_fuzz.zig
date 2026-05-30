//! Fuzz the hand-rolled WebAssembly decoder. `interpreter.decode`
//! parses untrusted plugin `.wasm` bytes into a `Module` — every
//! bundled plugin and any user-installed plugin flows through it, so a
//! malformed module must yield a typed error, never a panic, an
//! out-of-bounds read, or a leak.
//!
//! Strategy: feed bytes to `decode` both raw (exercises the magic /
//! version gate, including short and empty slices) and behind a valid
//! `\0asm\1` header (lets the fuzzer reach the section walker and the
//! LEB128 readers, where malformed-length bugs live). On a successful
//! decode we walk the module's public surface and free it.
//! `std.testing.allocator` turns any leak in decode's error paths into
//! a hard failure.
//!
//! Two entry points:
//!   - `std.testing.fuzz` drives the coverage-guided fuzzer under
//!     `zig build --fuzz fuzz`, and runs the seed corpus once under
//!     `zig build test`.
//!   - the fixed-corpus test gives plain regression coverage in CI
//!     without the fuzzer.
//!
//! Out of scope: `instantiate` / `invoke` execution semantics (traps,
//! unbounded loops). A follow-up target should fuzz those with a fuel
//! bound — this one targets the parser, the untrusted-bytes boundary.

const std = @import("std");
const interp = @import("../plugins/wasm/interpreter.zig");

/// `\0asm` magic + little-endian version 1 — the 8-byte preamble
/// `decode` requires before it will look at any section.
const wasm_header = [_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 };

const FuzzContext = struct {
    allocator: std.mem.Allocator,
};

/// Decode `bytes`, and if it parses, touch the public surface and free
/// it. Any decode error is acceptable; a panic / OOB / leak is not.
fn tryDecode(allocator: std.mem.Allocator, bytes: []const u8) void {
    var module = interp.decode(allocator, bytes) catch return;
    defer module.deinit();
    // Use the decoded module so a successful parse isn't dead code.
    _ = module.findExport("main", .func);
    _ = module.findExport("memory", .memory);
}

/// Run both framings of `bytes` through the decoder.
fn exercise(allocator: std.mem.Allocator, bytes: []const u8) void {
    // Raw: most random inputs bounce off the magic / version check,
    // which is itself worth exercising for short and empty slices.
    tryDecode(allocator, bytes);

    // Header-prefixed: skip the gate so the fuzzer spends its budget in
    // the section decoders rather than re-failing the magic check.
    const framed = std.mem.concat(allocator, u8, &.{ &wasm_header, bytes }) catch return;
    defer allocator.free(framed);
    tryDecode(allocator, framed);
}

fn fuzzDecode(ctx: FuzzContext, smith: *std.testing.Smith) anyerror!void {
    var buf: [4096]u8 = undefined;
    const n = smith.slice(&buf);
    exercise(ctx.allocator, buf[0..n]);
}

test "fuzz: wasm decode tolerates arbitrary bytes" {
    const ctx = FuzzContext{ .allocator = std.testing.allocator };
    try std.testing.fuzz(ctx, fuzzDecode, .{ .corpus = &.{
        &wasm_header,
        "not a wasm module",
    } });
}

test "fuzz: wasm decode fixed corpus never panics or leaks" {
    const a = std.testing.allocator;
    // A small corpus that should never crash. `zig build --fuzz fuzz`
    // extends this with random input.
    const corpus = [_][]const u8{
        "",
        "\x00asm", // too short (< 8 bytes)
        &wasm_header, // valid, section-less module
        // Wrong version in an otherwise valid header.
        &[_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x02, 0x00, 0x00, 0x00 },
        // Valid header + a section header whose declared size (255)
        // runs past the end of the buffer -> InvalidSection.
        &[_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0xFF, 0x01 },
        // Type section claiming a 0x0FFFFFFF-entry count (LEB128) with
        // no bytes behind it -> must error, not allocate to death.
        &[_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F },
        "not a wasm module at all, just text",
    };
    for (corpus) |bytes| exercise(a, bytes);
}
