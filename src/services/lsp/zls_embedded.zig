const std = @import("std");
const zls = @import("zls");
const Transport = @import("../../lsp/transport.zig");

const log = std.log.scoped(.ZLS);

pub fn runEmbeddedZLS(
    allocator: std.mem.Allocator,
    input_pipe: *Transport.MemPipe,
    output_pipe: *Transport.MemPipe,
    environ_block: std.process.Environ.Block,
) void {
    // Run an independent Threaded io for this LSP thread but reuse the parent's
    // environment block so ZLS sees ZIG_LIB_DIR / ZIG_GLOBAL_CACHE / PATH.
    var threaded = std.Io.Threaded.init(allocator, .{
        .environ = .{ .block = environ_block },
    });
    defer threaded.deinit();
    const io = threaded.io();

    var environ_map = std.process.Environ.createMap(.{ .block = environ_block }, allocator) catch std.process.Environ.Map.init(allocator);
    defer environ_map.deinit();

    var config_manager = zls.configuration.Manager.init(io, allocator, &environ_map) catch return;
    defer config_manager.deinit();

    var frontend_config: zls.configuration.UnresolvedConfig = .{};
    frontend_config.enable_build_on_save = false;
    config_manager.setConfiguration(.frontend, &frontend_config) catch |err| {
        log.warn("ZLS frontend configuration failed: {}", .{err});
    };

    var embedded_transport = Transport.EmbeddedTransport.init(input_pipe, output_pipe);

    var server = zls.Server.create(.{
        .io = io,
        .allocator = allocator,
        .transport = &embedded_transport.transport,
        .config_manager = &config_manager,
    }) catch {
        return;
    };
    defer server.destroy();

    server.loop() catch |err| {
        log.warn("Embedded ZLS loop exited with error: {}", .{err});
    };
}
