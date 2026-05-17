const std = @import("std");
const Transport = @import("../../lsp/transport.zig");
const platform = @import("../../kernel/platform.zig");

const log = std.log.scoped(.LSPExternal);

/// Heap-allocated watchdog state for force-killing a stuck LSP child. The
/// PID is captured as an integer (cheap, safe to copy across threads), so
/// the watch doesn't reference the `Child` struct after `runExternalServer`
/// returns. Owned by the watchdog thread, freed via `defer` there.
const KillWatch = struct {
    pid: platform.Pid,
    /// Set by `pumpInput` when its read loop exits — usually because our
    /// side closed `to_server`, which is the LSP-stop signal.
    pump_done: std.atomic.Value(bool) = .{ .raw = false },
    /// Set by the main flow when `child.wait` returns naturally. Tells the
    /// watch to exit without sending a kill.
    cancelled: std.atomic.Value(bool) = .{ .raw = false },
};

pub fn runExternalServer(
    allocator: std.mem.Allocator,
    input_pipe: *Transport.MemPipe,
    output_pipe: *Transport.MemPipe,
    _: []const u8,
    args: []const []const u8,
    environ_block: std.process.Environ.Block,
) !void {
    // Each LSP pump runs in its own std.Thread.spawn worker, so it legitimately
    // needs its own Threaded io. Forward the parent's environ block so the
    // child process sees the same env (PATH, etc.) as the editor.
    var threaded = std.Io.Threaded.init(allocator, .{
        .environ = .{ .block = environ_block },
    });
    defer threaded.deinit();
    const io = threaded.io();

    var child = try std.process.spawn(io, .{
        .argv = args,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    // Spawn a kill-watchdog: if our input pump exits (our side closed the
    // pipe — i.e. stem is stopping this server) and the child still hasn't
    // exited 3 s later, fire SIGINT at it. Without this, a misbehaving LSP
    // child that ignores `exit` keeps the child.wait() below hanging forever.
    const watch: ?*KillWatch = blk: {
        const w = allocator.create(KillWatch) catch break :blk null;
        w.* = .{ .pid = child.id.? };
        const t = std.Thread.spawn(.{}, killWatchRun, .{ w, io, allocator }) catch {
            allocator.destroy(w);
            break :blk null;
        };
        t.detach();
        break :blk w;
    };

    const writer_thread = try std.Thread.spawn(.{}, pumpInput, .{ input_pipe, child.stdin.?, environ_block, watch });
    const reader_thread = try std.Thread.spawn(.{}, pumpOutput, .{ child.stdout.?, output_pipe, environ_block });
    var stderr_thread: ?std.Thread = null;
    if (child.stderr) |stderr| {
        stderr_thread = std.Thread.spawn(.{}, pumpStderr, .{ stderr, environ_block }) catch null;
    }

    _ = child.wait(io) catch |err| {
        log.warn("External LSP child wait failed: {}", .{err});
    };

    // Child exited (either naturally or because the watchdog killed it).
    // Tell the watchdog to stop polling. It'll free itself on exit.
    if (watch) |w| w.cancelled.store(true, .release);

    // wait() returns once the process exits, which closes its stdio. The pumps
    // will see EOF / write error and exit on their own; join so we don't return
    // with live references to `child`.
    writer_thread.join();
    reader_thread.join();
    if (stderr_thread) |t| t.join();
}

fn killWatchRun(watch: *KillWatch, io: std.Io, allocator: std.mem.Allocator) void {
    defer allocator.destroy(watch);

    // Phase 1: wait for the input pump to signal "shutdown started," or
    // bail out if `cancelled` is set (child exited naturally first).
    const poll_step_ms: i64 = 50;
    while (!watch.pump_done.load(.acquire)) {
        if (watch.cancelled.load(.acquire)) return;
        std.Io.sleep(io, .fromMilliseconds(poll_step_ms), .awake) catch return;
    }

    // Phase 2: pump finished. Grace period for the child to exit cleanly.
    const grace_ms: i64 = 3000;
    var waited: i64 = 0;
    while (waited < grace_ms) {
        if (watch.cancelled.load(.acquire)) return;
        std.Io.sleep(io, .fromMilliseconds(poll_step_ms), .awake) catch return;
        waited += poll_step_ms;
    }

    // Phase 3: still alive after the grace period — force kill.
    if (watch.cancelled.load(.acquire)) return;
    log.warn("LSP child PID {} ignored exit notification; sending SIGINT", .{watch.pid});
    platform.killProcess(watch.pid);
}

fn pumpInput(pipe: *Transport.MemPipe, child_stdin: std.Io.File, environ_block: std.process.Environ.Block, watch: ?*KillWatch) void {
    // Signal the watchdog when this pump exits (regardless of cause). The
    // watchdog uses this as its "child should be exiting now" cue.
    defer if (watch) |w| w.pump_done.store(true, .release);

    // Pump runs in its own std.Thread.spawn worker; needs its own Threaded io.
    // Forward the parent's environ block.
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .{ .block = environ_block },
    });
    defer threaded.deinit();
    const io = threaded.io();

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = pipe.read(&buf) catch break;
        if (n == 0) break;

        child_stdin.writeStreamingAll(io, buf[0..n]) catch break;
    }
}

fn pumpOutput(child_stdout: std.Io.File, pipe: *Transport.MemPipe, environ_block: std.process.Environ.Block) void {
    // Pump runs in its own std.Thread.spawn worker; needs its own Threaded io.
    // Forward the parent's environ block.
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .{ .block = environ_block },
    });
    defer threaded.deinit();
    const io = threaded.io();

    var buf: [4096]u8 = undefined;
    while (true) {
        var iovec = [_][]u8{&buf};
        const n = child_stdout.readStreaming(io, &iovec) catch break;
        if (n == 0) break;

        _ = pipe.write(buf[0..n]) catch break;
    }
}

fn pumpStderr(child_stderr: std.Io.File, environ_block: std.process.Environ.Block) void {
    // Pump runs in its own std.Thread.spawn worker; needs its own Threaded io.
    // Forward the parent's environ block.
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .{ .block = environ_block },
    });
    defer threaded.deinit();
    const io = threaded.io();

    var buf: [4096]u8 = undefined;
    while (true) {
        var iovec = [_][]u8{&buf};
        const n = child_stderr.readStreaming(io, &iovec) catch break;
        if (n == 0) break;

        log.info("[LSP STDERR] {s}", .{buf[0..n]});
    }
}
