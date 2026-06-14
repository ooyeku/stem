// Sibling test file for lsp_manager.zig.
//
// Convention: most modules in this codebase keep their tests inline as
// `test "..."` blocks in the same file. This one is the exception — it
// pulls in transport mocks (Transport.MemPipe) and TestIo helpers that
// would bloat the production module, and exercises LSPManager through
// its public API rather than internal helpers, so co-locating buys
// nothing. New tests for LSPManager belong here.

const std = @import("std");
const LSPManager = @import("lsp_manager.zig").LSPManager;
const LSPServer = @import("lsp/server.zig").LSPServer;
const Transport = @import("../lsp/transport.zig");
const TestIo = @import("../test_utils.zig").TestIo;
const vigil_api = @import("vigil_adapters.zig");
const vigil_supervision = @import("vigil_supervision.zig");

fn mockRunFn(allocator: std.mem.Allocator, input_pipe: *Transport.MemPipe, output_pipe: *Transport.MemPipe) void {
    _ = allocator;
    _ = input_pipe;
    _ = output_pipe;
}

test "LSPManager: init and deinit" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var manager = LSPManager.init(allocator, io, .empty);
    defer manager.deinit();
}

test "LSPManager: language detection from path" {
    try std.testing.expectEqualStrings("zig", LSPManager.getLangFromPath("/foo/bar.zig").?);
    try std.testing.expectEqualStrings("python", LSPManager.getLangFromPath("/foo/bar.py").?);
    try std.testing.expectEqualStrings("rust", LSPManager.getLangFromPath("/foo/bar.rs").?);
    try std.testing.expectEqualStrings("go", LSPManager.getLangFromPath("/foo/bar.go").?);
    try std.testing.expectEqualStrings("typescript", LSPManager.getLangFromPath("/foo/bar.ts").?);
    try std.testing.expectEqualStrings("typescript", LSPManager.getLangFromPath("/foo/bar.tsx").?);
    try std.testing.expectEqualStrings("javascript", LSPManager.getLangFromPath("/foo/bar.js").?);
    try std.testing.expect(LSPManager.getLangFromPath("/foo/bar.txt") == null);
}

test "LSPManager: routing by file path with mock servers" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var manager = LSPManager.init(allocator, io, .empty);
    defer manager.deinit();

    var zig_server = try LSPServer.init(allocator, io, "zig");
    errdefer zig_server.deinit();
    try manager.servers.put("zig", zig_server);

    var python_server = try LSPServer.init(allocator, io, "python");
    errdefer python_server.deinit();
    try manager.servers.put("python", python_server);

    try std.testing.expect(manager.servers.get("zig") != null);
    try std.testing.expect(manager.servers.get("python") != null);
    try std.testing.expect(manager.servers.get("rust") == null);

    try manager.requestHover("/tmp/foo.zig", 1, 1);
    try manager.requestHover("/tmp/foo.py", 1, 1);
    try manager.requestHover("/tmp/foo.txt", 1, 1);

    try std.testing.expect(manager.popHoverResult() == null);
}

test "LSPManager: document tracking" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var manager = LSPManager.init(allocator, io, .empty);
    defer manager.deinit();

    var zig_server = try LSPServer.init(allocator, io, "zig");
    errdefer zig_server.deinit();
    try manager.servers.put("zig", zig_server);

    try std.testing.expect(manager.open_documents.count() == 0);
}

test "LSPManager: stop missing server is safe" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var manager = LSPManager.init(allocator, io, .empty);
    defer manager.deinit();

    manager.stopServerLang("nonexistent");
    manager.stopServer();
}

test "LSPManager: health snapshot reports server and supervisor state" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var manager = LSPManager.init(allocator, io, .empty);
    defer manager.deinit();

    var runtime = try vigil_api.runtime(allocator, .{});
    defer runtime.deinit();
    var supervisor = vigil_supervision.ComponentSupervisor.init(allocator, &runtime, .lsp);
    defer supervisor.deinit();
    manager.setVigilSupervisor(&supervisor);

    var zig_server = try LSPServer.init(allocator, io, "zig");
    errdefer zig_server.deinit();
    zig_server.server_running.store(true, .release);
    zig_server.server_healthy.store(false, .release);
    try manager.servers.put("zig", zig_server);
    manager.recordLspRestartScheduledForTest("zig", 0, 1);

    var snapshot = try manager.healthSnapshot(allocator);
    defer snapshot.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), snapshot.servers.len);
    try std.testing.expectEqual(@as(usize, 1), snapshot.running_servers);
    try std.testing.expectEqual(@as(usize, 1), snapshot.unhealthy_servers);
    try std.testing.expectEqual(@as(u64, 1), snapshot.lifecycle.crashes);
    try std.testing.expectEqual(@as(u64, 1), snapshot.lifecycle.restarts_scheduled);
    try std.testing.expectEqualStrings("zig", snapshot.servers[0].lang);
    try std.testing.expect(snapshot.servers[0].running);
    try std.testing.expect(!snapshot.servers[0].healthy);
}
