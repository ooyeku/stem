//! Fuzz the LSP JSON message handlers. The reader thread routes JSON-RPC
//! payloads to `handle*Result` / `handleDiagnostics`; any of these could be
//! exercised with a malicious / buggy server response and must not panic.
//!
//! Strategy: parse `input` as JSON (silently bail if invalid), then feed it
//! to each handler that takes a `std.json.Value`. The handlers must either
//! produce a result, return a typed error, or silently ignore — never panic.

const std = @import("std");
const LSPServer = @import("../services/lsp/server.zig").LSPServer;
const TestIo = @import("../test_utils.zig").TestIo;

fn newServer(a: std.mem.Allocator, io: std.Io) !*LSPServer {
    return LSPServer.init(a, io, "fuzz");
}

fn fuzzDiagnostics(ctx: anytype, input: []const u8) anyerror!void {
    if (input.len == 0) return;
    var io_ctx = TestIo.init(ctx.allocator);
    defer io_ctx.deinit();

    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, input, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;

    const server = newServer(ctx.allocator, io_ctx.io()) catch return;
    defer server.deinit();
    // The handler is `!void`. It must not panic; errors are acceptable.
    server.handleDiagnostics(parsed.value) catch {};
}

const FuzzContext = struct {
    allocator: std.mem.Allocator,
};

test "fuzz: LSP diagnostics handler" {
    const ctx = FuzzContext{ .allocator = std.testing.allocator };
    // A small fixed corpus that should never crash. Real fuzzing via
    // `zig build --fuzz fuzz` extends this with random input.
    const corpus = [_][]const u8{
        "{}",
        "[]",
        "null",
        "{\"params\":null}",
        "{\"params\":{}}",
        "{\"params\":{\"diagnostics\":[]}}",
        "{\"params\":{\"uri\":\"file:///x\",\"diagnostics\":[]}}",
        // Garbage shapes — all should be tolerated, not panicked.
        "{\"params\":{\"uri\":42,\"diagnostics\":\"oops\"}}",
        "{\"params\":{\"uri\":\"file:///x\",\"diagnostics\":[{\"severity\":99999999999}]}}",
        "{\"params\":{\"uri\":\"file:///x\",\"diagnostics\":[{\"range\":\"bad\",\"message\":\"m\"}]}}",
        "{\"params\":{\"uri\":\"file:///x\",\"diagnostics\":[{\"range\":{\"start\":{\"line\":-1,\"character\":0},\"end\":{\"line\":0,\"character\":0}},\"message\":\"x\"}]}}",
        "{\"params\":{\"uri\":\"file:///x\",\"diagnostics\":[{\"range\":{\"start\":{\"line\":1e308,\"character\":0},\"end\":{\"line\":0,\"character\":0}},\"message\":\"x\"}]}}",
    };
    for (corpus) |s| try fuzzDiagnostics(ctx, s);
}

test "fuzz: handleHoverResult shape variants" {
    const a = std.testing.allocator;
    var io_ctx = TestIo.init(a);
    defer io_ctx.deinit();

    const server = try newServer(a, io_ctx.io());
    defer server.deinit();

    const corpus = [_][]const u8{
        "null",
        "{}",
        "{\"contents\":null}",
        "{\"contents\":\"\"}",
        "{\"contents\":\"plain string\"}",
        "{\"contents\":[]}",
        "{\"contents\":[\"a\",\"b\"]}",
        "{\"contents\":{\"value\":\"x\"}}",
        "{\"contents\":{\"value\":42}}", // wrong type — should be tolerated
        "{\"contents\":[{\"value\":\"x\"},{\"value\":\"y\"}]}",
    };
    for (corpus) |s| {
        var p = try std.json.parseFromSlice(std.json.Value, a, s, .{});
        defer p.deinit();
        server.handleHoverResult(p.value) catch {};
    }
}

test "fuzz: handleSemanticTokensResult tolerates malformed deltas" {
    const a = std.testing.allocator;
    var io_ctx = TestIo.init(a);
    defer io_ctx.deinit();

    const server = try newServer(a, io_ctx.io());
    defer server.deinit();

    const corpus = [_][]const u8{
        "{}",
        "{\"data\":[]}",
        "{\"data\":[1]}", // not multiple of 5
        "{\"data\":[1,2,3,4]}",
        // Adversarial: huge delta values, malformed types.
        "{\"data\":[4294967295,4294967295,4294967295,4294967295,0]}",
        "{\"data\":[1,2,3,4,5,1,2,3,4,5]}",
        "{\"data\":[\"not\",\"a\",\"number\",0,0]}",
    };
    for (corpus) |s| {
        var p = try std.json.parseFromSlice(std.json.Value, a, s, .{});
        defer p.deinit();
        server.handleSemanticTokensResult(p.value, "file:///x.zig") catch {};
    }
}

test "fuzz: handleCompletionResult tolerates malformed entries" {
    const a = std.testing.allocator;
    var io_ctx = TestIo.init(a);
    defer io_ctx.deinit();

    const server = try newServer(a, io_ctx.io());
    defer server.deinit();

    const corpus = [_][]const u8{
        "null",
        "[]",
        "[{}]", // no label
        "[{\"label\":\"x\"}]", // OK
        "[{\"label\":\"x\",\"kind\":0}]", // out-of-range kind
        "[{\"label\":\"x\",\"kind\":99999}]",
        "[{\"label\":42}]", // wrong type
        "{\"items\":[{\"label\":\"y\",\"kind\":1}]}", // CompletionList shape
        "{\"isIncomplete\":true}",
    };
    for (corpus) |s| {
        var p = try std.json.parseFromSlice(std.json.Value, a, s, .{});
        defer p.deinit();
        server.handleCompletionResult(p.value) catch {};
    }
}
