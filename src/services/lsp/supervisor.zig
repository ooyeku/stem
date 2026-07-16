//! Background command queue for LSP lifecycle work.
//!
//! Every operation that can block — start/stop/restart of an LSP server, the
//! initial `didOpen` for a newly opened file — runs on a single dedicated
//! worker thread instead of the UI thread. Result: opening a file or
//! switching projects never freezes the editor, even if the server takes
//! tens of seconds to initialize.
//!
//! The supervisor is intentionally dumb: it owns a FIFO queue and a worker
//! thread, and dispatches each dequeued command to a caller-supplied handler.
//! Knowledge of `LSPManager`, `LSPServer`, etc. lives in the handler — that
//! keeps this module re-usable and avoids a circular import.
//!
//! Vigil's `GenServer` was evaluated (v2.3.0) as a replacement and rejected:
//! its message loop poll-sleeps at 1 ms when idle (this queue parks on a
//! condvar — zero wakeups), its mailbox hard-codes a 5 s default TTL that
//! would silently expire commands queued behind a slow server start (losing
//! e.g. a user's `didOpen`), and typed commands would need pointer-in-payload
//! encoding plus a side-band dedup registry. Re-evaluate if GenServer gains
//! configurable mailbox options and a parked receive.

const std = @import("std");
const log = std.log.scoped(.LSPSupervisor);

/// Caller-allocated, supervisor-frees: the worker takes ownership of every
/// `[]u8` in here and frees it after the command runs (success or failure).
pub const Command = union(enum) {
    /// Start a server for `lang` rooted at `root` (or no root if null).
    start_server: struct { lang: []u8, root: ?[]u8 },

    /// Stop the running server for `lang`. No-op if none.
    stop_server: []u8,

    /// Restart the running server for `lang` with the given root. Replaces an
    /// existing server even if it's healthy — used when the workspace root
    /// changed in a way that we can't represent via `workspaceFolders`.
    restart_server: struct { lang: []u8, root: ?[]u8 },

    /// Ensure a server for `lang` is running with `root`, then send the
    /// `didOpen` for `file_path`/`content`. If the server isn't running, it
    /// is started first and the `didOpen` waits until init completes.
    ensure_and_open: struct {
        lang: []u8,
        root: ?[]u8,
        file_path: []u8,
        content: []u8,
    },

    /// Send `workspace/didChangeWorkspaceFolders` to add `root` to the server
    /// for `lang`. Used in place of restart when an open file's project root
    /// differs from the server's current root.
    add_workspace_folder: struct { lang: []u8, root: []u8 },

    /// Send a textDocument request (hover, completion, definition, ...)
    /// that the user issued while the server wasn't ready yet. Runs after
    /// any preceding `ensure_and_open` in the queue, so by the time it
    /// executes the document is guaranteed to be open on the server. The
    /// response comes back through the normal reader thread → result mutex
    /// → tick-loop pop path.
    deferred_request: struct {
        lang: []u8,
        file_path: []u8,
        kind: DeferredKind,
        line: u32,
        col: u32,
    },

    pub const DeferredKind = enum {
        hover,
        completion,
        formatting,
        definition,
        references,
        document_symbols,
    };

    pub fn deinit(cmd: *Command, allocator: std.mem.Allocator) void {
        switch (cmd.*) {
            .start_server => |c| {
                allocator.free(c.lang);
                if (c.root) |r| allocator.free(r);
            },
            .stop_server => |lang| allocator.free(lang),
            .restart_server => |c| {
                allocator.free(c.lang);
                if (c.root) |r| allocator.free(r);
            },
            .ensure_and_open => |c| {
                allocator.free(c.lang);
                if (c.root) |r| allocator.free(r);
                allocator.free(c.file_path);
                allocator.free(c.content);
            },
            .add_workspace_folder => |c| {
                allocator.free(c.lang);
                allocator.free(c.root);
            },
            .deferred_request => |c| {
                allocator.free(c.lang);
                allocator.free(c.file_path);
            },
        }
    }
};

pub const Handlers = struct {
    /// Called from the worker thread to execute the given command. The
    /// supervisor frees the command's owned strings after `execute` returns,
    /// so the handler must dupe anything it wants to keep.
    execute: *const fn (ctx: *anyopaque, cmd: Command) void,
};

/// Join `t` with a deadline. If it doesn't terminate within `timeout_ms`,
/// the helper that's joining it is detached and we return false; the
/// caller should NOT try to free anything the target thread still touches.
/// At process-exit time the OS reaps the leaked memory immediately, so the
/// leak is bounded.
///
/// Allocates a small heap object that outlives the call when we time out
/// (the spawned helper thread keeps writing to it until the target finally
/// joins). On success that object is freed before returning.
pub fn joinTimeout(allocator: std.mem.Allocator, io: std.Io, t: std.Thread, timeout_ms: i64) bool {
    const Done = struct {
        flag: std.atomic.Value(bool) = .{ .raw = false },
    };
    const done = allocator.create(Done) catch return false;
    done.* = .{};

    const Helper = struct {
        fn run(target: std.Thread, d: *Done) void {
            @import("../thread_name.zig").set("stem-lsp-shut");
            var owned = target;
            owned.join();
            d.flag.store(true, .release);
        }
    };
    var helper = std.Thread.spawn(.{}, Helper.run, .{ t, done }) catch {
        allocator.destroy(done);
        return false;
    };
    helper.detach();

    const start = std.Io.Clock.real.now(io).toMilliseconds();
    while (!done.flag.load(.acquire)) {
        const elapsed = std.Io.Clock.real.now(io).toMilliseconds() - start;
        if (elapsed >= timeout_ms) {
            // Leak `done` — the helper is still writing to it.
            return false;
        }
        std.Io.sleep(io, .fromMilliseconds(20), .awake) catch return false;
    }
    allocator.destroy(done);
    return true;
}

pub const LSPSupervisor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    ctx: *anyopaque,
    handlers: Handlers,

    queue: std.ArrayListUnmanaged(Command) = .empty,
    queue_mutex: std.Io.Mutex = .init,
    queue_cond: std.Io.Condition = .init,

    worker: ?std.Thread = null,
    shutdown_flag: std.atomic.Value(bool) = .{ .raw = false },

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        ctx: *anyopaque,
        handlers: Handlers,
    ) LSPSupervisor {
        return .{
            .allocator = allocator,
            .io = io,
            .ctx = ctx,
            .handlers = handlers,
        };
    }

    pub fn start(self: *LSPSupervisor) !void {
        if (self.worker != null) return;
        self.shutdown_flag.store(false, .release);
        self.worker = try std.Thread.spawn(.{}, workerMain, .{self});
    }

    /// Signal the worker to drain the queue and exit, then join. Idempotent
    /// and safe to call even if `start` was never invoked. Frees any
    /// commands left in the queue at exit so we don't leak.
    ///
    /// The join is bounded at 3 s — if the worker is stuck inside a
    /// long-running command (e.g. `LSPServer.start` waiting on init), we
    /// detach instead of hanging the editor. The manager is expected to
    /// have set its global-shutdown flag first, so most in-flight commands
    /// will themselves return early.
    pub fn shutdown(self: *LSPSupervisor) void {
        self.shutdown_flag.store(true, .release);
        if (self.worker) |w| {
            self.queue_mutex.lockUncancelable(self.io);
            self.queue_cond.broadcast(self.io);
            self.queue_mutex.unlock(self.io);

            if (!joinTimeout(self.allocator, self.io, w, 3000)) {
                std.log.warn("LSP supervisor worker did not exit in 3s; detaching", .{});
                // Don't touch self.queue from this thread — the worker may
                // still be reading it. Bail out without freeing.
                self.worker = null;
                return;
            }
            self.worker = null;
        }

        self.queue_mutex.lockUncancelable(self.io);
        for (self.queue.items) |*cmd| cmd.deinit(self.allocator);
        self.queue.deinit(self.allocator);
        self.queue = .empty;
        self.queue_mutex.unlock(self.io);
    }

    /// Append `cmd` to the worker's queue. `cmd`'s owned strings transfer to
    /// the supervisor. If the supervisor has already shut down, the command
    /// is freed immediately and `error.SupervisorShutdown` is returned.
    pub fn enqueue(self: *LSPSupervisor, cmd: Command) !void {
        var owned = cmd;
        if (self.shutdown_flag.load(.acquire)) {
            owned.deinit(self.allocator);
            return error.SupervisorShutdown;
        }
        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);
        self.queue.append(self.allocator, owned) catch |err| {
            owned.deinit(self.allocator);
            return err;
        };
        self.queue_cond.signal(self.io);
    }

    /// Best-effort: don't enqueue a `stop_server` if there's already one
    /// queued for this lang, etc. Cheap O(n) scan; the queue is tiny.
    pub fn enqueueDedup(self: *LSPSupervisor, cmd: Command) !void {
        var owned = cmd;
        if (self.shutdown_flag.load(.acquire)) {
            owned.deinit(self.allocator);
            return error.SupervisorShutdown;
        }
        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);

        for (self.queue.items) |existing| {
            if (sameCommand(existing, owned)) {
                owned.deinit(self.allocator);
                return;
            }
        }
        self.queue.append(self.allocator, owned) catch |err| {
            owned.deinit(self.allocator);
            return err;
        };
        self.queue_cond.signal(self.io);
    }

    fn sameCommand(a: Command, b: Command) bool {
        return switch (a) {
            .start_server => |ac| switch (b) {
                .start_server => |bc| std.mem.eql(u8, ac.lang, bc.lang),
                else => false,
            },
            .stop_server => |al| switch (b) {
                .stop_server => |bl| std.mem.eql(u8, al, bl),
                else => false,
            },
            .restart_server => |ac| switch (b) {
                .restart_server => |bc| std.mem.eql(u8, ac.lang, bc.lang),
                else => false,
            },
            // ensure_and_open intentionally never dedups: every file open is
            // a distinct event the user expects to land.
            .ensure_and_open => false,
            .add_workspace_folder => |ac| switch (b) {
                .add_workspace_folder => |bc| std.mem.eql(u8, ac.lang, bc.lang) and std.mem.eql(u8, ac.root, bc.root),
                else => false,
            },
            // Deferred requests are per-keystroke and intentionally never
            // dedup — the user's last hover/completion position is what
            // matters, but we can't tell which is "last" from inside the
            // queue, so all queued ones run.
            .deferred_request => false,
        };
    }

    fn workerMain(self: *LSPSupervisor) void {
        @import("../thread_name.zig").set("stem-lsp-sup");
        log.info("worker thread started", .{});
        defer log.info("worker thread exited", .{});

        while (true) {
            self.queue_mutex.lockUncancelable(self.io);
            while (self.queue.items.len == 0 and !self.shutdown_flag.load(.acquire)) {
                self.queue_cond.waitUncancelable(self.io, &self.queue_mutex);
            }
            if (self.queue.items.len == 0 and self.shutdown_flag.load(.acquire)) {
                self.queue_mutex.unlock(self.io);
                return;
            }
            // FIFO: pop from the front.
            var cmd = self.queue.orderedRemove(0);
            self.queue_mutex.unlock(self.io);

            // Execute outside the queue lock so handlers can enqueue more.
            self.handlers.execute(self.ctx, cmd);
            cmd.deinit(self.allocator);
        }
    }
};

test "supervisor: Command.deinit frees every variant cleanly" {
    // No worker thread — exercise just the Command.deinit path so leaks in
    // any new variant are caught.
    const alloc = std.testing.allocator;

    {
        var cmd: Command = .{ .start_server = .{
            .lang = try alloc.dupe(u8, "zig"),
            .root = try alloc.dupe(u8, "/tmp/proj"),
        } };
        cmd.deinit(alloc);
    }
    {
        var cmd: Command = .{ .stop_server = try alloc.dupe(u8, "zig") };
        cmd.deinit(alloc);
    }
    {
        var cmd: Command = .{ .restart_server = .{
            .lang = try alloc.dupe(u8, "go"),
            .root = null,
        } };
        cmd.deinit(alloc);
    }
    {
        var cmd: Command = .{ .ensure_and_open = .{
            .lang = try alloc.dupe(u8, "zig"),
            .root = null,
            .file_path = try alloc.dupe(u8, "/tmp/proj/main.zig"),
            .content = try alloc.dupe(u8, "fn main() {}"),
        } };
        cmd.deinit(alloc);
    }
    {
        var cmd: Command = .{ .add_workspace_folder = .{
            .lang = try alloc.dupe(u8, "zig"),
            .root = try alloc.dupe(u8, "/tmp/other"),
        } };
        cmd.deinit(alloc);
    }
    {
        var cmd: Command = .{ .deferred_request = .{
            .lang = try alloc.dupe(u8, "zig"),
            .file_path = try alloc.dupe(u8, "/tmp/p.zig"),
            .kind = .hover,
            .line = 0,
            .col = 0,
        } };
        cmd.deinit(alloc);
    }
}

// Integration tests below spin up a real supervisor worker. They use a
// simple counter context so we can assert worker behaviour deterministically.
const test_utils = @import("../../test_utils.zig");

const TestExecCtx = struct {
    seen_langs: std.ArrayListUnmanaged([]u8) = .empty,
    mutex: std.Io.Mutex = .init,
    io: std.Io,

    fn handle(ptr: *anyopaque, cmd: Command) void {
        const self: *TestExecCtx = @ptrCast(@alignCast(ptr));
        // Stash the lang from whichever variant the command carried.
        const lang_src: []const u8 = switch (cmd) {
            .start_server => |c| c.lang,
            .stop_server => |l| l,
            .restart_server => |c| c.lang,
            .ensure_and_open => |c| c.lang,
            .add_workspace_folder => |c| c.lang,
            .deferred_request => |c| c.lang,
        };
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const dup = std.testing.allocator.dupe(u8, lang_src) catch return;
        self.seen_langs.append(std.testing.allocator, dup) catch {
            std.testing.allocator.free(dup);
        };
    }

    fn count(self: *TestExecCtx) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.seen_langs.items.len;
    }

    fn deinit(self: *TestExecCtx) void {
        for (self.seen_langs.items) |l| std.testing.allocator.free(l);
        self.seen_langs.deinit(std.testing.allocator);
    }
};

fn ctxCount(ctx: *TestExecCtx) bool {
    _ = ctx;
    return true;
}

test "supervisor: worker processes commands in FIFO order" {
    var io_ctx = test_utils.TestIo.init(std.testing.allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();

    var exec_ctx = TestExecCtx{ .io = io };
    defer exec_ctx.deinit();

    var sup = LSPSupervisor.init(
        std.testing.allocator,
        io,
        @ptrCast(&exec_ctx),
        .{ .execute = TestExecCtx.handle },
    );
    try sup.start();
    defer sup.shutdown();

    // Enqueue three distinct stop commands.
    const langs = [_][]const u8{ "zig", "python", "rust" };
    for (langs) |l| {
        try sup.enqueue(.{ .stop_server = try std.testing.allocator.dupe(u8, l) });
    }

    // Wait for all three to be processed.
    const Wait = struct {
        c: *TestExecCtx,
        fn pred(s: @This()) bool {
            return s.c.count() >= 3;
        }
    };
    const done = test_utils.waitUntil(io, 1000, Wait{ .c = &exec_ctx }, Wait.pred);
    try std.testing.expect(done);

    // First-in == first-out.
    try std.testing.expectEqualStrings("zig", exec_ctx.seen_langs.items[0]);
    try std.testing.expectEqualStrings("python", exec_ctx.seen_langs.items[1]);
    try std.testing.expectEqualStrings("rust", exec_ctx.seen_langs.items[2]);
}

test "supervisor: enqueueDedup collapses same-lang stops" {
    var io_ctx = test_utils.TestIo.init(std.testing.allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();

    var exec_ctx = TestExecCtx{ .io = io };
    defer exec_ctx.deinit();

    var sup = LSPSupervisor.init(
        std.testing.allocator,
        io,
        @ptrCast(&exec_ctx),
        .{ .execute = TestExecCtx.handle },
    );
    // Don't start the worker — we want to inspect the queue directly without
    // the worker draining it.
    defer sup.shutdown();

    // Three same-lang stops should dedup down to one.
    for (0..3) |_| {
        try sup.enqueueDedup(.{
            .stop_server = try std.testing.allocator.dupe(u8, "zig"),
        });
    }
    // A different lang adds a second entry.
    try sup.enqueueDedup(.{
        .stop_server = try std.testing.allocator.dupe(u8, "python"),
    });

    sup.queue_mutex.lockUncancelable(io);
    const total = sup.queue.items.len;
    sup.queue_mutex.unlock(io);
    try std.testing.expectEqual(@as(usize, 2), total);
}

test "supervisor: shutdown drains remaining queue items" {
    var io_ctx = test_utils.TestIo.init(std.testing.allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();

    var exec_ctx = TestExecCtx{ .io = io };
    defer exec_ctx.deinit();

    var sup = LSPSupervisor.init(
        std.testing.allocator,
        io,
        @ptrCast(&exec_ctx),
        .{ .execute = TestExecCtx.handle },
    );
    // No worker started; queue commands then shutdown. shutdown must free
    // every left-over command without leaking.
    for (0..5) |_| {
        try sup.enqueue(.{
            .stop_server = try std.testing.allocator.dupe(u8, "zig"),
        });
    }
    sup.shutdown();
}

test "supervisor: enqueue after shutdown returns error and frees the command" {
    var io_ctx = test_utils.TestIo.init(std.testing.allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();

    var exec_ctx = TestExecCtx{ .io = io };
    defer exec_ctx.deinit();

    var sup = LSPSupervisor.init(
        std.testing.allocator,
        io,
        @ptrCast(&exec_ctx),
        .{ .execute = TestExecCtx.handle },
    );
    sup.shutdown_flag.store(true, .release);

    const lang = try std.testing.allocator.dupe(u8, "zig");
    try std.testing.expectError(error.SupervisorShutdown, sup.enqueue(.{ .stop_server = lang }));
    // ^ the supervisor must have freed `lang` itself. Allocator leak check
    // at test exit will fail otherwise.

    // Cleanup (shutdown is idempotent).
    sup.shutdown();
}
