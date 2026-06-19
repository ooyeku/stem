const std = @import("std");
const vaxis = @import("vaxis");
const EditorState = @import("core/state.zig").EditorState;
const protocol = @import("kernel/protocol.zig");
const Core = @import("kernel/core.zig").Core;
const StorageManager = @import("config/storage.zig").StorageManager;
const logger = @import("services/logger.zig");
const cli = @import("cli.zig");
const MessageBus = @import("kernel/message_bus.zig").MessageBus;
const StemRuntime = @import("services/runtime.zig").StemRuntime;
const vigil_api = @import("services/vigil_adapters.zig");

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logger.stdLogBridge,
};

/// Set by SIGINT / SIGTERM handlers (POSIX) or the console-control
/// callback (Windows). Polled by a monitor thread that wakes the main
/// loop with a `.quit` message so we exit via the same teardown path
/// the user would get from in-editor quit. Module-level because both
/// signal handlers and the Windows ctrl-handler callback run without
/// caller context. Async-signal safe: only an atomic store happens in
/// the handler itself.
var shutdown_requested: std.atomic.Value(bool) = .{ .raw = false };

fn handleShutdownSignal(_: std.c.SIG) callconv(.c) void {
    shutdown_requested.store(true, .release);
}

/// Windows console-control callback. Called by Windows on Ctrl+C,
/// Ctrl+Break, console-window close, user logoff, or system shutdown.
/// Runs on a Win32-managed thread, NOT the main thread — so we just
/// flag the atomic and return TRUE ("handled"); the SignalMonitor
/// thread observes the flag within ~200 ms and wakes the main loop,
/// which runs the same teardown path POSIX does. For CTRL_CLOSE / -
/// LOGOFF / -SHUTDOWN, Windows enforces a ~5–10 s grace window before
/// it force-terminates the process; our fast-exit deinit (which
/// SIGKILLs every LSP child in parallel and bounds every join) lands
/// well inside that budget.
///
/// Without this handler, Ctrl+C on Windows kills stem instantly and
/// every spawned LSP server becomes an orphan process — there's no
/// SIGCHLD on Windows to reap them, and conhost cleanup is unreliable.
fn handleWindowsCtrl(ctrl_type: u32) callconv(.winapi) c_int {
    // CTRL_C_EVENT=0, CTRL_BREAK_EVENT=1, CTRL_CLOSE_EVENT=2,
    // CTRL_LOGOFF_EVENT=5, CTRL_SHUTDOWN_EVENT=6.
    switch (ctrl_type) {
        0, 1, 2, 5, 6 => {
            shutdown_requested.store(true, .release);
            return 1; // TRUE — handled
        },
        else => return 0, // FALSE — let next handler run
    }
}

fn installShutdownSignals() !void {
    if (@import("builtin").os.tag == .windows) {
        const SetConsoleCtrlHandler = struct {
            extern "kernel32" fn SetConsoleCtrlHandler(
                handler: ?*const fn (u32) callconv(.winapi) c_int,
                add: c_int,
            ) c_int;
        }.SetConsoleCtrlHandler;
        // Returns 0 on failure; we ignore — startup must continue
        // even if Windows refuses to install the handler (e.g.
        // running detached from any console). The user can still
        // exit cleanly via Space+Q in that case.
        _ = SetConsoleCtrlHandler(handleWindowsCtrl, 1);
        return;
    }
    const sa: std.posix.Sigaction = .{
        .handler = .{ .handler = handleShutdownSignal },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART,
    };
    std.posix.sigaction(.INT, &sa, null);
    std.posix.sigaction(.TERM, &sa, null);
    std.posix.sigaction(.HUP, &sa, null);
}

fn isQuitKey(key: vaxis.Key) bool {
    return key.matches('c', .{ .ctrl = true }) or key.codepoint == 0x03;
}

const ShutdownCause = enum {
    ui_requested,
    signal,
};

const ShutdownPlan = struct {
    stop_vaxis_loop: bool,
    join_input_thread: bool,
    exit_process_directly: bool,
};

fn shutdownPlan(cause: ShutdownCause) ShutdownPlan {
    return switch (cause) {
        // The vaxis input reader can be blocked in a raw terminal read even
        // after the UI loop has accepted a quit. Both user-requested quit and
        // signal-driven shutdown restore the terminal, tear down Stem's core
        // work directly, then exit the process instead of waiting on that
        // reader.
        .ui_requested, .signal => .{
            .stop_vaxis_loop = false,
            .join_input_thread = false,
            .exit_process_directly = true,
        },
    };
}

/// Pre-opened crash-log file descriptor. Opened at startup so the signal
/// handler doesn't need to allocate or call `open` (which isn't strictly
/// async-signal-safe). -1 when no log is available.
var crash_log_fd: std.c.fd_t = -1;

/// Dedicated stack for the signal handler. The fault that brought us
/// here may have been a stack overflow — handling it on the same
/// (exhausted) stack just deadlocks or crashes again. POSIX
/// `sigaltstack` swaps to this buffer for the duration of the handler.
var crash_altstack: [64 * 1024]u8 align(16) = undefined;

/// Saved terminal attributes from before vaxis took the tty into raw +
/// alt-screen mode. The crash handler restores these so the user's
/// shell isn't left with broken echo / raw mode after a crash. Set
/// once in `installCrashHandler`; read read-only in the handler.
var saved_termios: std.c.termios = undefined;
var saved_termios_valid: bool = false;

/// Path to the recovery directory (`~/.stem/recover/`). Static buffer
/// + length so the signal handler can write the path without touching
/// the allocator. Set once in `installCrashHandler`.
var recover_dir_buf: [4096]u8 = undefined;
var recover_dir_len: usize = 0;

extern "c" fn backtrace(buffer: [*]usize, size: c_int) c_int;
extern "c" fn backtrace_symbols_fd(buffer: [*]const usize, size: c_int, fd: c_int) void;
extern "c" fn pthread_setname_np(name: [*:0]const u8) c_int;
extern "c" fn pthread_getname_np(thread: ?*anyopaque, name: [*]u8, len: usize) c_int;
extern "c" fn pthread_self() ?*anyopaque;

const thread_name = @import("services/thread_name.zig");
const setThreadName = thread_name.set;

/// Async-signal-safe crash handler. The rules say we shouldn't call
/// most libc functions here, but a few are explicitly allowed
/// (`write`, `raise`, `_exit`), and `backtrace`/`backtrace_symbols_fd`
/// are widely treated as signal-safe in practice. Worst case we die a
/// different way before the dump finishes; that's no worse than the
/// silent SEGV the user is hitting today.
fn handleCrashSignal(sig: std.c.SIG, info: *const std.c.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    const sig_name: []const u8 = switch (sig) {
        std.posix.SIG.SEGV => "SIGSEGV",
        std.posix.SIG.BUS => "SIGBUS",
        std.posix.SIG.ILL => "SIGILL",
        std.posix.SIG.FPE => "SIGFPE",
        std.posix.SIG.ABRT => "SIGABRT",
        else => "signal",
    };

    // Write to both the crash log and stderr (fd 2). The terminal
    // tends to swallow stderr while vaxis is in alt-screen, but the
    // moment we re-raise and die the alt-screen is dropped — leaving
    // anything we wrote to stderr visible on the way out.
    const stderr_fd: std.c.fd_t = 2;

    // Try to pull the thread's name. If a worker set it via
    // setThreadName, we get something readable like "stem-parse";
    // otherwise we fall back to "<unnamed>". This is the single most
    // useful piece of info when the closure was inlined into
    // `entryFn` and the rest of the trace is one symbol.
    var name_buf: [64]u8 = undefined;
    var tname: []const u8 = "<unnamed>";
    if (pthread_getname_np(pthread_self(), &name_buf, name_buf.len) == 0) {
        const z = std.mem.indexOfScalar(u8, &name_buf, 0) orelse name_buf.len;
        if (z > 0) tname = name_buf[0..z];
    }

    const hdr = "\n=== stem crash: ";
    const sep = " on thread '";
    const tail = "' ===\n";
    if (crash_log_fd >= 0) {
        _ = std.c.write(crash_log_fd, hdr.ptr, hdr.len);
        _ = std.c.write(crash_log_fd, sig_name.ptr, sig_name.len);
        _ = std.c.write(crash_log_fd, sep.ptr, sep.len);
        _ = std.c.write(crash_log_fd, tname.ptr, tname.len);
        _ = std.c.write(crash_log_fd, tail.ptr, tail.len);
    }
    _ = std.c.write(stderr_fd, hdr.ptr, hdr.len);
    _ = std.c.write(stderr_fd, sig_name.ptr, sig_name.len);
    _ = std.c.write(stderr_fd, sep.ptr, sep.len);
    _ = std.c.write(stderr_fd, tname.ptr, tname.len);
    _ = std.c.write(stderr_fd, tail.ptr, tail.len);

    // Fault address from siginfo. NULL = null-deref, low values = a
    // small offset from a NULL base pointer (struct field through a
    // null *T), 0x7f… range = heap or stack (likely UAF), high
    // canonical addresses = stack overflow / code corruption.
    //
    // POSIX agrees the address is reachable from siginfo_t, but the
    // *layout* diverges: Linux glibc tucks it inside a tagged
    // `fields` union (`fields.sigfault.addr` for SIGSEGV/SIGBUS/
    // SIGFPE/SIGILL), while macOS/BSD expose `addr` at the top
    // level. Switch on the build target so the wrong-shape field
    // access doesn't fail compilation on the *other* platform.
    {
        var addr_buf: [48]u8 = undefined;
        const addr_val: usize = switch (@import("builtin").os.tag) {
            .linux => @intFromPtr(info.fields.sigfault.addr),
            else => @intFromPtr(info.addr),
        };
        const addr_str = std.fmt.bufPrint(&addr_buf, "fault addr: 0x{x}\n", .{addr_val}) catch "fault addr: ?\n";
        if (crash_log_fd >= 0) _ = std.c.write(crash_log_fd, addr_str.ptr, addr_str.len);
        _ = std.c.write(stderr_fd, addr_str.ptr, addr_str.len);
    }

    // Most recently logged "step" marker. The parse worker (and any
    // other worker that opts in) writes a static string here before
    // each tree-sitter C call; on crash the last one tells us exactly
    // which call was in flight.
    const step = thread_name.last_step.load(.acquire);
    if (step != null) {
        const step_hdr = "last step: ";
        const step_str = std.mem.span(@as([*:0]const u8, @ptrCast(step.?)));
        if (crash_log_fd >= 0) {
            _ = std.c.write(crash_log_fd, step_hdr.ptr, step_hdr.len);
            _ = std.c.write(crash_log_fd, step_str.ptr, step_str.len);
            _ = std.c.write(crash_log_fd, "\n", 1);
        }
        _ = std.c.write(stderr_fd, step_hdr.ptr, step_hdr.len);
        _ = std.c.write(stderr_fd, step_str.ptr, step_str.len);
        _ = std.c.write(stderr_fd, "\n", 1);
    }

    // POSIX backtrace into a small buffer of return addresses, then
    // let libSystem symbolicate to the fd directly. Avoids any
    // allocator / Zig debug-info round-trip from inside the handler.
    var frames: [64]usize = undefined;
    const n = backtrace(&frames, frames.len);
    if (n > 0) {
        if (crash_log_fd >= 0) backtrace_symbols_fd(&frames, n, crash_log_fd);
        backtrace_symbols_fd(&frames, n, stderr_fd);
    } else {
        const msg = "(backtrace returned no frames)\n";
        if (crash_log_fd >= 0) _ = std.c.write(crash_log_fd, msg.ptr, msg.len);
        _ = std.c.write(stderr_fd, msg.ptr, msg.len);
    }

    // Point the user at any unsaved work that the autosave-backup
    // worker (`Core.maybeAutosave`) has staged in ~/.stem/recover/.
    // Without this hint, users assume a crash lost their edits and
    // never discover the recovery picker (`buffer.restore_backups`).
    if (recover_dir_len > 0) {
        const hint_pre = "unsaved work may be recoverable from: ";
        const hint_post = "\nrun `stem` and use `buffer.restore_backups` from the palette\n";
        if (crash_log_fd >= 0) {
            _ = std.c.write(crash_log_fd, hint_pre.ptr, hint_pre.len);
            _ = std.c.write(crash_log_fd, &recover_dir_buf, recover_dir_len);
            _ = std.c.write(crash_log_fd, hint_post.ptr, hint_post.len);
        }
        _ = std.c.write(stderr_fd, hint_pre.ptr, hint_pre.len);
        _ = std.c.write(stderr_fd, &recover_dir_buf, recover_dir_len);
        _ = std.c.write(stderr_fd, hint_post.ptr, hint_post.len);
    }

    // Restore terminal state before re-raising. Vaxis put the tty
    // in raw + alt-screen + bracketed-paste + mouse-tracking mode;
    // if the OS kills us without unwinding through `vaxis.Tty.deinit`
    // (which is async-signal-unsafe to call here), the user lands in
    // a broken shell with no echo and the cursor hidden. Issue the
    // standard reset escapes directly to stdout (fd 1), then
    // `tcsetattr` the saved termios back. All async-signal-safe:
    // `write` and `tcsetattr` are both on POSIX's whitelist.
    const stdout_fd: std.c.fd_t = 1;
    const reset_seq =
        "\x1b[?1049l" ++ // leave alt-screen, return to primary buffer
        "\x1b[?25h" ++ //   show cursor
        "\x1b[?1000l" ++ // disable X10 mouse tracking
        "\x1b[?1002l" ++ // disable button-event mouse tracking
        "\x1b[?1003l" ++ // disable any-event mouse tracking
        "\x1b[?1006l" ++ // disable SGR mouse encoding
        "\x1b[?2004l" ++ // disable bracketed paste
        "\x1b[0m" ++ //    reset SGR attributes
        "\r\n";
    _ = std.c.write(stdout_fd, reset_seq.ptr, reset_seq.len);
    if (saved_termios_valid) {
        _ = std.c.tcsetattr(stdout_fd, .NOW, &saved_termios);
    }

    // SA_RESETHAND already reset the handler to the default; raising
    // the same signal now actually kills us with the usual coredump
    // behaviour, so `zsh` still prints its normal "segmentation fault"
    // line and external tools (lldb, Crash Reporter) see the right
    // exit status.
    _ = std.c.raise(sig);
}

fn installCrashHandler(logs_dir: []const u8, recover_dir: []const u8) !void {
    if (@import("builtin").os.tag == .windows) return;

    // Open (or create) `crash.log` once at startup. Append-mode so
    // multiple crashes in a row stack up. We hold the fd for the
    // process lifetime; the signal handler writes to it without
    // touching higher-level I/O.
    var path_buf: [4096]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/crash.log", .{logs_dir}) catch return;
    const fd = std.c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, @as(std.c.mode_t, 0o644));
    if (fd >= 0) crash_log_fd = fd;

    // Stash the recovery-dir path so the signal handler can point the
    // user at it without doing string formatting (allocator + format
    // calls aren't async-signal-safe).
    if (recover_dir.len > 0 and recover_dir.len <= recover_dir_buf.len) {
        @memcpy(recover_dir_buf[0..recover_dir.len], recover_dir);
        recover_dir_len = recover_dir.len;
    }

    // Snapshot the pre-vaxis termios so the crash handler can put
    // the user's shell back into cooked / echo / canonical mode if
    // we die mid-render. Vaxis owns the tty during normal operation
    // and restores it via its own deinit, but a SEGV bypasses that
    // entirely — without this, the user lands in a non-responsive
    // shell after a crash. Best-effort: if stdin isn't a tty (piped
    // input), skip; the handler will just write reset escapes which
    // is still better than nothing.
    const stdin_fd: std.c.fd_t = 0;
    if (std.c.tcgetattr(stdin_fd, &saved_termios) == 0) {
        saved_termios_valid = true;
    }

    // Drop a startup marker. Lets the user verify the handler is
    // armed without having to crash on purpose. If THIS line doesn't
    // appear in crash.log, the installer didn't run / the path is
    // wrong / the directory isn't writable.
    if (crash_log_fd >= 0) {
        const banner = "\n--- stem launched, crash handler armed ---\n";
        _ = std.c.write(crash_log_fd, banner.ptr, banner.len);
    }

    // Sigaltstack: install a dedicated buffer for the handler so a
    // stack-overflow SEGV still has somewhere to run. Without this,
    // the handler can't execute (the original stack is gone) and the
    // process dies silently.
    const stack: std.posix.stack_t = .{
        .sp = &crash_altstack,
        .size = crash_altstack.len,
        .flags = 0,
    };
    _ = std.c.sigaltstack(&stack, null);

    const sa: std.posix.Sigaction = .{
        .handler = .{ .sigaction = handleCrashSignal },
        .mask = std.posix.sigemptyset(),
        // SIGINFO: handler receives (sig, siginfo_t*, ucontext_t*) so
        //   we can read si_addr.
        // ONSTACK: run on the dedicated alt stack we just installed.
        // RESETHAND: after one delivery the handler is reset to the
        //   default, so the `raise(sig)` below kills the process
        //   with the original behaviour (coredump + zsh message).
        .flags = std.posix.SA.SIGINFO | std.posix.SA.ONSTACK | std.posix.SA.RESETHAND,
    };
    std.posix.sigaction(.SEGV, &sa, null);
    std.posix.sigaction(.BUS, &sa, null);
    std.posix.sigaction(.ILL, &sa, null);
    std.posix.sigaction(.FPE, &sa, null);
    std.posix.sigaction(.ABRT, &sa, null);
}

pub fn main(init: std.process.Init.Minimal) !void {
    setThreadName("stem-main");
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded = std.Io.Threaded.init(allocator, .{
        .argv0 = .init(.{ .vector = init.args.vector }),
        .environ = .{ .block = init.environ.block },
    });
    defer threaded.deinit();
    const io = threaded.io();

    var storage = try StorageManager.init(allocator, io, init.environ.block);
    defer storage.deinit();

    // Collect args before initializing editor-only services. CLI subcommands
    // should stay cheap and avoid terminal/logger teardown paths entirely.
    var args_list = std.ArrayListUnmanaged([:0]const u8).empty;
    defer args_list.deinit(allocator);
    {
        var args_it = try std.process.Args.Iterator.initAllocator(init.args, allocator);
        defer args_it.deinit();
        while (args_it.next()) |a| {
            try args_list.append(allocator, try allocator.dupeZ(u8, a));
        }
    }
    const args = args_list.items;
    defer {
        for (args) |a| allocator.free(a);
    }
    var initial_files_to_open = std.ArrayListUnmanaged([]const u8).empty;
    defer {
        for (initial_files_to_open.items) |f| allocator.free(f);
        initial_files_to_open.deinit(allocator);
    }

    switch (try cli.dispatch(.{
        .allocator = allocator,
        .io = io,
        .args = args,
        .storage = &storage,
        .environ_block = init.environ.block,
    })) {
        .handled => return,
        .run_editor => |paths| {
            try initial_files_to_open.appendSlice(allocator, paths);
            allocator.free(paths);
        },
    }

    try storage.setEditorWorkspaceFromInitialPaths(initial_files_to_open.items);

    var workspace_lock = storage.acquireWorkspaceLock() catch |err| switch (err) {
        error.AlreadyRunning => {
            const stderr = std.Io.File.stderr();
            stderr.writeStreamingAll(io, "stem is already running in this workspace.\n") catch {};
            stderr.writeStreamingAll(io, "Close the existing instance before starting another one here.\n") catch {};
            stderr.writeStreamingAll(io, "Lock: ") catch {};
            stderr.writeStreamingAll(io, storage.getInstanceLockPath()) catch {};
            stderr.writeStreamingAll(io, "\n") catch {};
            std.process.exit(1);
        },
        else => return err,
    };
    defer workspace_lock.deinit();

    const log_level: logger.LogLevel = switch (storage.config.logging.level) {
        .debug => .debug,
        .info => .info,
        .warn => .warn,
        .err => .err,
    };

    try logger.init(allocator, io, storage.logs_dir, log_level);
    defer logger.deinit();

    // Probe the terminal once at startup to decide whether to emit
    // 24-bit RGB or 16-colour palette indices for syntax highlights.
    // Classic Windows conhost (cmd.exe) silently drops 24-bit SGR
    // codes, leaving the buffer text rendered with the terminal
    // default foreground while palette-index UI chrome (status bar,
    // tabs) renders fine. Detection lives in src/ui/theme.zig.
    @import("ui/theme.zig").detectTruecolor(allocator, init.environ.block);

    // Install SIGSEGV / SIGBUS / etc. handlers. Best-effort: writes a
    // backtrace to `~/.stem/logs/crash.log` and re-raises with the
    // default handler so the OS still produces a coredump + zsh still
    // reports the crash. Without this, segfaults vanish into thin air
    // and we have no way to diagnose them.
    // Recover dir is the sibling of logs_dir under ~/.stem/. Built
    // once here so the crash handler doesn't have to derive it from
    // a signal-handler context (no allocator, no fmt).
    const recover_dir = blk: {
        // strip trailing "logs" → "<config>/recover"
        const parent = std.fs.path.dirname(storage.logs_dir) orelse break :blk "";
        break :blk std.fs.path.join(allocator, &.{ parent, "recover" }) catch break :blk "";
    };
    defer if (recover_dir.len > 0) allocator.free(recover_dir);

    installCrashHandler(storage.logs_dir, recover_dir) catch |err| {
        std.log.warn("Failed to install crash handler: {}", .{err});
    };

    // Vigil-backed runtime services. Owns the Vigil Runtime, Stem's
    // process-local telemetry bridge, the editor event broker, and
    // lifecycle supervisors for plugins/LSP.
    var stem_runtime = try StemRuntime.init(allocator);
    stem_runtime.attachEventBroker();
    defer stem_runtime.deinit();

    const inbox_allocator = allocator;
    const runtime_inboxes = try stem_runtime.createEditorInboxes();
    var main_inbox = runtime_inboxes.main;
    var core_inbox = runtime_inboxes.core;

    // Producers send through these buses (priority routing, coalescing,
    // backpressure, telemetry). Consumers still read directly from the
    // underlying inboxes.
    var main_bus = MessageBus.init(inbox_allocator, main_inbox, "to-ui");
    main_bus.configureFlowControl(.{
        .bulk_high_watermark = 512,
        .background_high_watermark = 256,
        .bulk_rate_per_second = 2000,
        .background_rate_per_second = 500,
    });
    var core_bus = MessageBus.init(inbox_allocator, core_inbox, "to-core");
    core_bus.configureFlowControl(.{
        .bulk_high_watermark = 1024,
        .background_high_watermark = 256,
        .bulk_rate_per_second = 4000,
        .background_rate_per_second = 500,
    });

    const EditorShutdownContext = struct {
        main: *vigil_api.Inbox,
        core: *vigil_api.Inbox,

        fn markClosed(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.main.closed.store(true, .release);
            self.core.closed.store(true, .release);
        }
    };
    var editor_shutdown_ctx = EditorShutdownContext{
        .main = main_inbox,
        .core = core_inbox,
    };
    try stem_runtime.addShutdownHook("editor.inboxes.closed", @ptrCast(&editor_shutdown_ctx), EditorShutdownContext.markClosed);

    const CoreContext = struct {
        core: Core,
        bus: *MessageBus,
    };

    // Build env map for vaxis. TODO(zig-0.16): forward init.environ_map once
    // main() takes Init instead of Init.Minimal.
    var vaxis_env_map = try std.process.Environ.createMap(init.environ, allocator);
    defer vaxis_env_map.deinit();
    var vx = try vaxis.init(io, allocator, &vaxis_env_map, .{});
    const tty_buffer = try allocator.alloc(u8, 4096);
    defer allocator.free(tty_buffer);
    var tty = try vaxis.Tty.init(io, tty_buffer);
    defer tty.deinit();
    defer vx.deinit(allocator, tty.writer());
    var loop: vaxis.Loop(vaxis.Event) = .init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();
    // Without this, vaxis only emits the initial winsize event and never
    // sees subsequent SIGWINCHes, so the editor's snapshot stays sized for
    // whatever the terminal was when stem launched. With it, every host
    // resize re-emits a winsize event and our `.resize` handler propagates
    // it into core.win_size.
    try loop.installResizeHandler();

    const TerminalRestoreContext = struct {
        vx: *vaxis.Vaxis,
        tty: *vaxis.Tty,

        fn restore(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.vx.resetState(self.tty.writer()) catch {};
        }
    };
    var terminal_restore_ctx = TerminalRestoreContext{
        .vx = &vx,
        .tty = &tty,
    };
    try stem_runtime.addShutdownHook("terminal.restore", @ptrCast(&terminal_restore_ctx), TerminalRestoreContext.restore);
    defer stem_runtime.shutdown();

    // Graceful signal handling: when the user `kill`s stem (SIGTERM) or
    // hits Ctrl-C in a way that doesn't route through vaxis (SIGINT from a
    // background tty operation), we want the same clean teardown we'd do
    // on Ctrl-C in the editor — exit alt-screen, deinit core (LSP, scan
    // workers, syntax worker), restore the terminal. Without this, those
    // signals kill stem mid-render and leave the terminal scrambled and
    // LSP children orphaned.
    installShutdownSignals() catch |err| {
        std.log.warn("Failed to install signal handlers: {}", .{err});
    };
    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), std.Io.Duration.fromSeconds(1));
    vx.caps.sgr_pixels = false;
    try vx.setMouseMode(tty.writer(), true);
    var core_ctx = CoreContext{
        .core = try Core.init(allocator, io, init.environ.block, &main_bus, &storage, initial_files_to_open.items, &stem_runtime),
        .bus = &core_bus,
    };
    defer core_ctx.core.deinit();
    // The LSP supervisor stores a pointer to the manager, so we can only
    // start it after `core_ctx.core` is in its final memory location.
    try core_ctx.core.lsp_manager.startSupervisor();

    // Spawn the background tree-sitter parse worker. After this, edits and
    // buffer switches submit parses asynchronously instead of blocking the
    // core thread on the parser.
    core_ctx.core.syntax_manager.startParseWorker(io) catch |err| {
        std.log.warn("Failed to start syntax parse worker: {}", .{err});
    };
    const Runner = struct {
        fn run(ctx: *CoreContext) void {
            setThreadName("stem-core");
            ctx.core.run(ctx.bus) catch |err| {
                if (err != error.UserQuit) {
                    std.debug.print("Core crashed: {}\n", .{err});
                }
            };
        }
    };
    const core_thread = try std.Thread.spawn(.{}, Runner.run, .{&core_ctx});
    defer core_thread.join();
    defer stem_runtime.shutdown();
    var app_stop: std.atomic.Value(bool) = .init(false);
    const InputThread = struct {
        loop: *vaxis.Loop(vaxis.Event),
        bus: *MessageBus,
        allocator: std.mem.Allocator,
        stop: *std.atomic.Value(bool),
        fn run(self: @This()) !void {
            setThreadName("stem-input");
            // Monotonic counter for coalesced sends (resize): each event
            // gets a fresh identity so the bus knows the slot was reused.
            var resize_seq: u64 = 0;
            while (!self.stop.load(.acquire)) {
                const event = self.loop.nextEvent() catch break;
                if (self.stop.load(.acquire)) break;
                var msg: protocol.Message = undefined;
                var class: @import("kernel/message_bus.zig").Class = .interactive;
                var is_resize = false;
                switch (event) {
                    .key_press => |key| {
                        msg = .{ .input = key };
                    },
                    .mouse => |mouse| {
                        msg = .{ .mouse = mouse };
                    },
                    .winsize => |ws| {
                        msg = .{ .resize = ws };
                        // Resize is idempotent — the latest wins.
                        is_resize = true;
                        class = .coalescible;
                    },
                    .focus_in => {
                        msg = .{ .focus = true };
                    },
                    .focus_out => {
                        msg = .{ .focus = false };
                    },
                    else => continue,
                }
                const bytes = msg.encode(self.allocator) catch continue;
                defer self.allocator.free(bytes);
                if (is_resize) {
                    resize_seq +%= 1;
                    self.bus.sendCoalesced(.spare_4, bytes, resize_seq) catch break;
                } else {
                    self.bus.send(class, bytes) catch break;
                }
            }
        }
    };
    const input_thread = try std.Thread.spawn(.{}, InputThread.run, .{InputThread{
        .loop = &loop,
        .bus = &main_bus,
        .allocator = inbox_allocator,
        .stop = &app_stop,
    }});

    const HeartbeatThread = struct {
        bus: *MessageBus,
        allocator: std.mem.Allocator,
        io: std.Io,
        stop: *std.atomic.Value(bool),
        fn run(self: @This()) !void {
            setThreadName("stem-heartbeat");
            var tick_seq: u64 = 0;
            while (!self.stop.load(.acquire)) {
                std.Io.sleep(self.io, .fromMilliseconds(100), .awake) catch break;
                if (self.stop.load(.acquire)) break;
                var tick_msg: protocol.Message = .tick;
                const bytes = tick_msg.encode(self.allocator) catch continue;
                defer self.allocator.free(bytes);
                tick_seq +%= 1;
                // Heartbeat is the canonical coalescible message — if
                // core is busy, queueing 20 ticks behind a slow render
                // helps nobody.
                self.bus.sendCoalesced(.tick, bytes, tick_seq) catch break;
            }
        }
    };
    const heartbeat_thread = try std.Thread.spawn(.{}, HeartbeatThread.run, .{HeartbeatThread{
        .bus = &core_bus,
        .allocator = inbox_allocator,
        .io = io,
        .stop = &app_stop,
    }});

    // Signal monitor: polls the `shutdown_requested` flag set by the
    // SIGINT/SIGTERM/SIGHUP handler. When set, injects a `.quit` into
    // `main_inbox` so the UI loop wakes and runs the normal teardown
    // path. This is what makes `kill -TERM <pid>` exit stem cleanly.
    const SignalMonitor = struct {
        bus: *MessageBus,
        allocator: std.mem.Allocator,
        io: std.Io,
        stop: *std.atomic.Value(bool),
        fn run(self: @This()) void {
            setThreadName("stem-sigmon");
            while (!self.stop.load(.acquire)) {
                std.Io.sleep(self.io, .fromMilliseconds(200), .awake) catch {
                    // Signals may interrupt the sleeping thread that is
                    // responsible for observing them. Keep polling instead of
                    // returning before `shutdown_requested` is checked.
                    vigil_api.sleep(10 * std.time.ns_per_ms);
                };
                if (self.stop.load(.acquire)) return;
                if (shutdown_requested.load(.acquire)) {
                    const msg = (protocol.Message{ .quit = {} }).encode(self.allocator) catch return;
                    defer self.allocator.free(msg);
                    // .quit is the textbook critical message: it must
                    // not sit behind queued bulk traffic during shutdown.
                    self.bus.sendCritical(msg) catch {};
                    // Backup wakeup: `Inbox.recv()` polls this flag directly.
                    // Do not call `Inbox.close()` here; that deallocates the
                    // inbox while the UI thread still owns its pointer.
                    self.bus.inbox.closed.store(true, .release);
                    return;
                }
            }
        }
    };
    const signal_monitor_thread = try std.Thread.spawn(.{}, SignalMonitor.run, .{SignalMonitor{
        .bus = &main_bus,
        .allocator = inbox_allocator,
        .io = io,
        .stop = &app_stop,
    }});
    const View = @import("ui/view.zig").View;
    var view = View.init(allocator);
    var loop_arena = std.heap.ArenaAllocator.init(allocator);
    defer loop_arena.deinit();
    var snapshot_arena = std.heap.ArenaAllocator.init(allocator);
    defer snapshot_arena.deinit();
    var last_snapshot: ?*protocol.RenderSnapshot = null;
    var last_arena: ?*std.heap.ArenaAllocator = null;
    var last_arena_pool: ?*@import("kernel/arena_pool.zig").ArenaPool = null;
    while (true) {
        const msg = main_inbox.recv() catch break;
        defer msg.deinit();
        if (msg.payload) |payload| {
            const decoded = protocol.Message.decode(payload) catch |err| {
                std.debug.print("UI failed to decode msg: {}\n", .{err});
                continue;
            };
            switch (decoded) {
                .input => |key| {
                    if (isQuitKey(key)) {
                        const quit_bytes = (protocol.Message{ .quit = {} }).encode(allocator) catch break;
                        defer allocator.free(quit_bytes);
                        core_bus.sendCritical(quit_bytes) catch {};
                        break;
                    }
                    const fwd_bytes = (protocol.Message{ .input = key }).encode(allocator) catch continue;
                    defer allocator.free(fwd_bytes);
                    core_bus.sendInteractive(fwd_bytes) catch {};
                },
                .mouse => |mouse| {
                    const fwd_bytes = (protocol.Message{ .mouse = mouse }).encode(allocator) catch continue;
                    defer allocator.free(fwd_bytes);
                    core_bus.sendInteractive(fwd_bytes) catch {};
                },
                .resize => |ws| {
                    try vx.resize(allocator, tty.writer(), ws);

                    const resize_bytes = (protocol.Message{ .resize = ws }).encode(allocator) catch continue;
                    defer allocator.free(resize_bytes);
                    core_bus.sendInteractive(resize_bytes) catch {};

                    if (last_snapshot) |snap| {
                        try view.draw(&vx, snap, loop_arena.allocator());
                        try vx.render(tty.writer());
                    }
                    _ = loop_arena.reset(.retain_capacity);
                },
                .render_update => |update| {
                    // Hand the previous frame's arena back to the pool — pages
                    // are kept and reused on the next acquire().
                    if (last_arena) |arena| {
                        if (last_arena_pool) |pool| pool.release(arena);
                    }

                    var latest = update;
                    // Drain any newer render_updates queued behind
                    // this one. Non-render messages on the way are
                    // processed inline (`continue` round-trips them
                    // through this switch). For each superseded
                    // render we release its arena so the producer's
                    // pool stays balanced.
                    while (main_inbox.mailbox.receive()) |peek_msg| {
                        if (peek_msg.payload) |peek_payload| {
                            const peek_decoded = protocol.Message.decode(peek_payload) catch {
                                peek_msg.deinit();
                                continue;
                            };
                            if (peek_decoded == .render_update) {
                                const prev_arena: *std.heap.ArenaAllocator = @ptrFromInt(latest.arena_ptr);
                                const prev_pool: *@import("kernel/arena_pool.zig").ArenaPool = @ptrFromInt(latest.pool_ptr);
                                prev_pool.release(prev_arena);
                                latest = peek_decoded.render_update;
                                peek_msg.deinit();
                                continue;
                            }
                            // Non-render message in the lookahead.
                            // The outer-loop scheduling expects to
                            // see these in order, so we deliberately
                            // stop draining and re-handle them on
                            // the next iteration. To avoid losing
                            // the message we already consumed, we
                            // re-send it to ourselves through the
                            // bus — preserves order with anything
                            // still queued.
                            const re_bytes = peek_payload;
                            main_bus.sendInteractive(re_bytes) catch {};
                            peek_msg.deinit();
                            break;
                        }
                        peek_msg.deinit();
                    } else |_| {}

                    const snapshot_ptr: *protocol.RenderSnapshot = @ptrFromInt(latest.snapshot_ptr);
                    const arena_ptr: *std.heap.ArenaAllocator = @ptrFromInt(latest.arena_ptr);
                    const pool_ptr: *@import("kernel/arena_pool.zig").ArenaPool = @ptrFromInt(latest.pool_ptr);

                    last_snapshot = snapshot_ptr;
                    last_arena = arena_ptr;
                    last_arena_pool = pool_ptr;

                    try view.draw(&vx, snapshot_ptr, loop_arena.allocator());
                    try vx.render(tty.writer());
                    _ = loop_arena.reset(.retain_capacity);
                },
                .command => |cmd| {
                    if (cmd == .quit) {
                        break;
                    }
                },
                .quit => break,
                .focus => |focused| {
                    if (focused) {
                        try vx.setMouseMode(tty.writer(), true);
                    }
                },
                else => {},
            }
        }
    }
    const signal_shutdown = shutdown_requested.load(.acquire);
    const plan = shutdownPlan(if (signal_shutdown) .signal else .ui_requested);
    app_stop.store(true, .release);

    // The terminal reader may be blocked in raw input. Do not wait on it
    // unless the shutdown policy explicitly says it is safe.
    if (plan.stop_vaxis_loop) loop.stop();
    if (plan.join_input_thread) input_thread.join();
    heartbeat_thread.join();
    signal_monitor_thread.join();

    vx.setMouseMode(tty.writer(), false) catch {};
    vx.exitAltScreen(tty.writer()) catch {};
    vx.resetState(tty.writer()) catch {};
    std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
    main_inbox.closed.store(true, .release);
    core_inbox.closed.store(true, .release);
    if (last_arena) |arena| {
        if (last_arena_pool) |pool| pool.release(arena);
    }
    while (true) {
        if (main_inbox.mailbox.receive()) |msg| {
            if (msg.payload) |payload| {
                if (protocol.Message.decode(payload) catch null) |decoded| {
                    if (decoded == .render_update) {
                        const update = decoded.render_update;
                        const arena_ptr: *std.heap.ArenaAllocator = @ptrFromInt(update.arena_ptr);
                        const pool_ptr: *@import("kernel/arena_pool.zig").ArenaPool = @ptrFromInt(update.pool_ptr);
                        pool_ptr.release(arena_ptr);
                    }
                }
            }
            msg.deinit();
        } else |_| {
            break;
        }
    }
    while (true) {
        if (core_inbox.mailbox.receive()) |msg| {
            msg.deinit();
        } else |_| {
            break;
        }
    }
    if (plan.exit_process_directly) {
        core_thread.join();
        core_ctx.core.deinit();
        stem_runtime.shutdown();
        std.process.exit(0);
    }
}

test "isQuitKey recognizes normalized and raw Ctrl-C" {
    try std.testing.expect(isQuitKey(.{
        .codepoint = 'c',
        .mods = .{ .ctrl = true },
    }));
    try std.testing.expect(isQuitKey(.{
        .codepoint = 0x03,
    }));
    try std.testing.expect(!isQuitKey(.{
        .codepoint = 'c',
    }));
}

test "UI-requested quit does not wait on terminal input reader" {
    const plan = shutdownPlan(.ui_requested);
    try std.testing.expect(!plan.stop_vaxis_loop);
    try std.testing.expect(!plan.join_input_thread);
    try std.testing.expect(plan.exit_process_directly);
}
