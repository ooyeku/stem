//! Regression corpus for the hand-rolled WebAssembly decoder.
//! `interpreter.decode` parses untrusted plugin `.wasm` bytes into a
//! `Module` — every bundled and user-installed plugin flows through it,
//! so a malformed module must yield a typed error, never a panic, an
//! out-of-bounds read, or a leak.
//!
//! Like the other fuzz files wired into `zig build test`
//! (`lsp_json_fuzz`, `config_setbypath_fuzz`), this runs a fixed,
//! curated corpus rather than the coverage-guided fuzzer: the
//! `std.testing.fuzz` driver is only available under `zig build fuzz`,
//! whose harness is separately broken on Zig 0.16 (the older fuzz files
//! use the pre-`Smith` signature). Keeping this deterministic means it
//! can't flake CI — a live-fuzz entry point can be added when the
//! harness is repaired.
//!
//! The corpus pins the malformed shapes that already surfaced real
//! decoder bugs (a forged element count and an overflowing LEB128), so
//! they can't regress. Each input is run raw and behind a valid header.
//!
//! Out of scope: `instantiate` / `invoke` execution semantics.

const std = @import("std");
const interp = @import("../plugins/wasm/interpreter.zig");

/// `\0asm` magic + little-endian version 1 — the 8-byte preamble
/// `decode` requires before it will look at any section.
const wasm_header = [_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 };

/// Decode `bytes`, and if it parses, touch the public surface and free
/// it. Any decode error is acceptable; a panic / OOB / leak is not.
fn tryDecode(allocator: std.mem.Allocator, bytes: []const u8) void {
    var module = interp.decode(allocator, bytes) catch return;
    defer module.deinit();
    // Use the decoded module so a successful parse isn't dead code.
    _ = module.findExport("main", .func);
    _ = module.findExport("memory", .memory);
}

/// Run both framings of `bytes` through the decoder: raw (exercises the
/// magic / version gate) and behind a valid header (reaches the section
/// and LEB128 decoders).
fn exercise(allocator: std.mem.Allocator, bytes: []const u8) void {
    tryDecode(allocator, bytes);
    const framed = std.mem.concat(allocator, u8, &.{ &wasm_header, bytes }) catch return;
    defer allocator.free(framed);
    tryDecode(allocator, framed);
}

test "wasm decode: fixed corpus never panics or leaks" {
    const a = std.testing.allocator;
    const corpus = [_][]const u8{
        "",
        "\x00asm", // too short (< 8 bytes)
        &wasm_header, // valid, section-less module
        // Wrong version in an otherwise valid header.
        &[_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x02, 0x00, 0x00, 0x00 },
        // Valid header + a section header whose declared size (255)
        // runs past the end of the buffer -> InvalidSection.
        &[_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0xFF, 0x01 },
        // Type section claiming a 0xFFFFFFFF-entry count (LEB128) with
        // no bytes behind it -> must error on the count bound, not
        // attempt the multi-gigabyte allocation.
        &[_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F },
        // Section size as an overflowing 5-byte LEB128 (bits past bit
        // 31) -> must error, not trip the left-shift safety check.
        &[_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F },
        "not a wasm module at all, just text",
    };
    for (corpus) |bytes| exercise(a, bytes);
}

test "wasm decode: forged section element count is rejected without a huge allocation" {
    // Type section claiming ~4.3 billion entries (LEB128 0xFFFFFFFF)
    // with nothing behind it. The decoder must reject it on the count
    // bound rather than attempt the alloc that would OOM-kill the host
    // (it crashed a memory-constrained CI runner before the bound).
    const malformed = [_]u8{
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, // \0asm v1
        0x01, 0x05, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F, // type section, count = 0xFFFFFFFF
    };
    try std.testing.expectError(error.InvalidSection, interp.decode(std.testing.allocator, &malformed));
}

test "wasm decode: overflowing LEB128 length is rejected, not a shift panic" {
    // A 5-byte LEB128 with bits past bit 31 (here a section size). The
    // decoder must return a typed error rather than trip the u32 left-
    // shift safety check, which would abort the process on a hostile
    // `.wasm`.
    const malformed = [_]u8{
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, // \0asm v1
        0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F, // custom section, size LEB overflows u32
    };
    try std.testing.expectError(error.InvalidModule, interp.decode(std.testing.allocator, &malformed));
}
