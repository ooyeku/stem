const std = @import("std");
const vigil_api = @import("../vigil_adapters.zig");
const Transport = @import("../../lsp/transport.zig");
const platform = @import("../../kernel/platform.zig");
const installer_mod = @import("installer.zig");
const host_command = @import("host_command.zig");

const log = std.log.scoped(.LSPExternal);
const Mutex = vigil_api.Mutex;

/// Heap-allocated watchdog state for force-killing a stuck LSP child. The
/// PID is captured as an integer (cheap, safe to copy across threads), so
/// the watch doesn't reference the `Child` struct after `runExternalServer`
/// returns. Owned by the watchdog thread, freed via `defer` there.
/// True when `s` looks like a bare program name (no path separators)
/// that needs OS PATH resolution to spawn.
fn isBareName(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (c == '/' or c == '\\') return false;
    return true;
}

// ---------------------------------------------------------------------------
// Live-child registry.
//
// Every `runExternalServer` call registers the spawned child's PID
// here; deregisters on natural exit. On stem's quit path, the editor
// calls `requestGlobalShutdown` which SIGKILLs every entry in one
// sweep — far quicker than the per-server graceful-shutdown handshake
// the supervisor runs by default.
// ---------------------------------------------------------------------------

const LiveRegistry = struct {
    mu: Mutex = .{},
    pids: std.ArrayListUnmanaged(platform.Pid) = .empty,
    shutdown_requested: std.atomic.Value(bool) = .{ .raw = false },
};

var live: LiveRegistry = .{};

/// Returns true iff the pid was registered. Returns false when a
/// global shutdown is already in flight — in that case the caller
/// should SIGKILL the child immediately, because the shutdown sweep
/// has already passed over the (then-empty) registry and won't come
/// back.
fn registerLiveChild(pid: platform.Pid) bool {
    live.mu.lock();
    defer live.mu.unlock();
    if (live.shutdown_requested.load(.acquire)) return false;
    live.pids.append(std.heap.page_allocator, pid) catch return false;
    return true;
}

fn unregisterLiveChild(pid: platform.Pid) void {
    live.mu.lock();
    defer live.mu.unlock();
    for (live.pids.items, 0..) |p, i| {
        if (p == pid) {
            _ = live.pids.swapRemove(i);
            return;
        }
    }
}

/// Returns true after `requestGlobalShutdown` has been called. The
/// runner threads use this to abort their `child.wait` without
/// touching child state any further.
pub fn isGlobalShutdownRequested() bool {
    return live.shutdown_requested.load(.acquire);
}

/// Force-terminate every live LSP child. Non-blocking — once SIGKILL
/// fires, the kernel reaps the processes and pumps/joins everywhere
/// else become wait-free. Safe to call multiple times.
pub fn requestGlobalShutdown() void {
    live.shutdown_requested.store(true, .release);
    live.mu.lock();
    const pids = live.pids.toOwnedSlice(std.heap.page_allocator) catch {
        live.mu.unlock();
        return;
    };
    live.mu.unlock();
    defer std.heap.page_allocator.free(pids);
    for (pids) |pid| {
        platform.killProcessTreeForce(pid);
    }
    log.info("requestGlobalShutdown: killed {d} LSP child(ren)", .{pids.len});
}

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

    // If `args[0]` is a bare program name (no path separator) and the
    // child would inherit a bare PATH from a GUI-launched stem, the
    // OS lookup will fail before we ever see stdout. Resolve the
    // interpreter ourselves against the same toolchain dirs we
    // search for LSP binaries (brew, opam, ghcup, cargo, etc.) and
    // substitute an absolute path. If resolution fails, fall through
    // — let the OS try its own PATH lookup with the bare name and
    // surface its error.
    var resolved_buf: [256][]const u8 = undefined;
    var resolved_slice: []const []const u8 = args;
    var resolved_owned: ?[]u8 = null;
    defer if (resolved_owned) |s| allocator.free(s);

    if (args.len > 0 and args.len <= resolved_buf.len and isBareName(args[0])) {
        if (installer_mod.findOnSystem(allocator, io, args[0], environ_block)) |abs| {
            log.info("resolved interpreter '{s}' -> '{s}'", .{ args[0], abs });
            resolved_owned = abs;
            resolved_buf[0] = abs;
            for (args[1..], 1..) |a, i| resolved_buf[i] = a;
            resolved_slice = resolved_buf[0..args.len];
        } else {
            // Bail loud-and-fast instead of letting `std.process.spawn`
            // return `FileNotFound` and then having `is_initialized`
            // wait its full 30 s timeout. The error message names the
            // missing interpreter so the user knows exactly what to
            // install — most commonly `node` for the npm-based servers
            // (Pyright, typescript-language-server, vscode-css/html/
            // json, intelephense, bash-language-server, perlnavigator)
            // or `java` for jdtls.
            log.err(
                "interpreter '{s}' not found on PATH or in any known toolchain dir (brew, opam, ghcup, cargo, sdkman, asdf, …). Install it and restart stem. Hint: `brew install {s}` on macOS.",
                .{ args[0], args[0] },
            );
            // Close output_pipe so the LSPServer reader thread sees
            // EOF and wakes the init waiter — otherwise the start()
            // path sits in its 30 s timeout for nothing.
            output_pipe.close();
            return error.InterpreterNotFound;
        }
    }

    const host_path = try host_command.hostPathFromCurrentExe(allocator, io, environ_block, null);
    defer allocator.free(host_path);

    const host_args = try host_command.externalArgv(allocator, host_path, "external", resolved_slice);
    defer allocator.free(host_args);

    return try runHostProcess(allocator, input_pipe, output_pipe, host_args, environ_block);
}

pub fn runEmbeddedZlsHost(
    allocator: std.mem.Allocator,
    input_pipe: *Transport.MemPipe,
    output_pipe: *Transport.MemPipe,
    environ_block: std.process.Environ.Block,
) !void {
    var threaded = std.Io.Threaded.init(allocator, .{
        .environ = .{ .block = environ_block },
    });
    defer threaded.deinit();
    const io = threaded.io();

    const alias = try host_command.aliasBasename(allocator, "zig");
    defer allocator.free(alias);
    const host_path = try host_command.hostPathFromCurrentExe(allocator, io, environ_block, alias);
    defer allocator.free(host_path);

    const host_args = try host_command.embeddedZlsArgv(allocator, host_path);
    defer allocator.free(host_args);

    return try runHostProcess(allocator, input_pipe, output_pipe, host_args, environ_block);
}

fn runHostProcess(
    allocator: std.mem.Allocator,
    input_pipe: *Transport.MemPipe,
    output_pipe: *Transport.MemPipe,
    argv: []const []const u8,
    environ_block: std.process.Environ.Block,
) !void {
    var threaded = std.Io.Threaded.init(allocator, .{
        .environ = .{ .block = environ_block },
    });
    defer threaded.deinit();
    const io = threaded.io();

    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = platform.childProcessGroupForSpawn(),
    }) catch |err| {
        log.err("spawn '{s}' failed: {} — closing pipes so init can bail fast", .{ argv[0], err });
        output_pipe.close();
        return err;
    };

    // Register the PID so `requestGlobalShutdown` can SIGKILL it
    // during stem's quit path. Capture the pid now — `child.id` is
    // cleared by `child.wait` and `child.kill`, so the defer would
    // see `null` if we don't snapshot it first. If registration fails
    // because shutdown is already underway, kill the child here so
    // we don't leak a process the sweep already missed.
    const captured_pid: ?platform.Pid = child.id;
    var registered = false;
    if (captured_pid) |pid| {
        registered = registerLiveChild(pid);
        if (!registered) {
            // Pid is `*anyopaque` (HANDLE) on Windows — `{d}` is
            // invalid for a pointer, so use the platform-neutral
            // pidToDisplay helper that prints either the integer
            // PID (POSIX) or the handle's address (Windows).
            log.info("LSP child {d} spawned during shutdown; killing immediately", .{platform.pidToDisplay(pid)});
            platform.killProcessTreeForce(pid);
            _ = child.wait(io) catch {};
            output_pipe.close();
            return error.ShutdownInProgress;
        }
    }
    defer if (registered) {
        if (captured_pid) |pid| unregisterLiveChild(pid);
    };
    // If anything after the spawn fails before we reach `child.wait` below,
    // we'd otherwise leak a child process (zombie) and its three pipes. Kill
    // and reap so the caller can give up cleanly. Note: this errdefer also
    // fires if a thread-spawn fails — in which case any threads we already
    // spawned (writer_thread) will see EOF on the pipe and exit on their
    // own, since the child's pipes close when it's killed.
    errdefer {
        if (captured_pid) |pid| platform.killProcessTreeForce(pid) else child.kill(io);
        _ = child.wait(io) catch {};
    }

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
    // If we error out before reaching `cancelled = true` below, tell the
    // watchdog to bail rather than waiting forever for pump_done.
    errdefer if (watch) |w| w.cancelled.store(true, .release);

    const host_stdin = child.stdin.?;
    child.stdin = null;

    const writer_thread = try std.Thread.spawn(.{}, pumpInput, .{ input_pipe, host_stdin, environ_block, watch });
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
    @import("../thread_name.zig").set("stem-lsp-watch");
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
    platform.killProcessTree(watch.pid);
}

fn pumpInput(pipe: *Transport.MemPipe, child_stdin: std.Io.File, environ_block: std.process.Environ.Block, watch: ?*KillWatch) void {
    @import("../thread_name.zig").set("stem-lsp-in");
    // Pump runs in its own std.Thread.spawn worker; needs its own Threaded io.
    // Forward the parent's environ block.
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .{ .block = environ_block },
    });
    defer threaded.deinit();
    const io = threaded.io();
    defer child_stdin.close(io);
    // Signal the watchdog when this pump exits (regardless of cause). The
    // watchdog uses this as its "child should be exiting now" cue.
    defer if (watch) |w| w.pump_done.store(true, .release);

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = pipe.read(&buf) catch break;
        if (n == 0) break;

        child_stdin.writeStreamingAll(io, buf[0..n]) catch break;
    }
}

fn pumpOutput(child_stdout: std.Io.File, pipe: *Transport.MemPipe, environ_block: std.process.Environ.Block) void {
    @import("../thread_name.zig").set("stem-lsp-out");
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
    @import("../thread_name.zig").set("stem-lsp-err");
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
