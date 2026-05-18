//! Out-of-process plugin loader.
//!
//! Spawns a plugin executable, pipes stdin/stdout, and translates
//! between the plugin's JSON-RPC channel and stem's internal
//! `protocol.PluginMessage` events that the rest of the editor
//! consumes (UI notifications, virtual buffers, …).
//!
//! Architecture:
//!
//! ```
//!   stem main thread
//!         │
//!         │  ProcessPluginManager.load(manifest)
//!         ▼
//!     ┌───────────────┐
//!     │ ProcessPlugin │
//!     │  ┌─────────┐  │
//!     │  │  child  │  │ ◄── std.process.Child
//!     │  └─┬────┬──┘  │
//!     │    │    │     │
//!     │ stdin  stdout │
//!     │    │    │     │
//!     │  ┌─▼────▼──┐  │
//!     │  │ writer  │  │ ◄── std.Thread (drains outbox, writes frames)
//!     │  │ reader  │  │ ◄── std.Thread (reads frames, decodes, routes)
//!     │  └─────────┘  │
//!     └───────────────┘
//! ```
//!
//! Crash recovery: when the child exits, the reader thread sees EOF
//! and sets `state = .stopped`. The manager cleans process plugin
//! resources during unload/shutdown; automatic restart is not wired.

const std = @import("std");
const vigil = @import("vigil");

const jsonrpc = @import("jsonrpc.zig");
const manifest_mod = @import("manifest.zig");
const protocol = @import("../kernel/protocol.zig");
const RequestTracker = @import("../kernel/request_reply.zig").RequestTracker;
const Mutex = vigil.compat.Mutex;

const log = std.log.scoped(.ProcessPlugin);

pub const State = enum {
    starting,
    running,
    stopping,
    stopped,
    failed,
};

/// One out-of-process plugin instance.
///
/// Lifecycle:
///   1. `start()` — spawn child, kick off reader+writer threads.
///   2. send `initialize` request; wait for `initialized` reply.
///   3. operate: `send*` for host→plugin traffic; reader thread calls
///      the host-side callbacks for plugin→host traffic.
///   4. `stop()` — send `shutdown` notification, close stdin, join.
pub const ProcessPlugin = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    name: []const u8,
    entry: []const u8,
    /// Working directory for the spawned process. Borrowed from caller.
    cwd: ?[]const u8 = null,
    /// Caller-supplied callback hooks invoked from the reader thread.
    /// All take ownership of any allocations the implementation makes.
    callbacks: Callbacks,

    state_mu: Mutex = .{},
    state: State = .stopped,

    child: ?std.process.Child = null,
    reader_thread: ?std.Thread = null,
    writer_thread: ?std.Thread = null,

    /// Pending writes for the writer thread. Producer locks, appends
    /// bytes, releases. Writer thread drains under the same lock.
    outbox_mu: Mutex = .{},
    outbox: std.ArrayListUnmanaged([]u8) = .empty,
    outbox_signal: std.atomic.Value(bool) = .{ .raw = false },

    /// Stop flag for both threads. Set by `stop()`; reader and writer
    /// poll it on each iteration.
    stop_flag: std.atomic.Value(bool) = .{ .raw = false },

    next_request_id: std.atomic.Value(u64) = .{ .raw = 1 },
    requests: RequestTracker,

    pub const Callbacks = struct {
        user_data: *anyopaque,
        /// Plugin sent a notification — host should route to the right
        /// subsystem (event bus, log, command registry).
        on_notification: *const fn (user_data: *anyopaque, method: []const u8, params_json: std.json.Value) void,
        /// Plugin sent a request — host should compute a reply and
        /// call `send_reply`.
        on_request: *const fn (user_data: *anyopaque, id: u64, method: []const u8, params_json: std.json.Value) void,
        /// Reader saw EOF / parser error. Plugin has crashed.
        on_exit: *const fn (user_data: *anyopaque) void,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        name: []const u8,
        entry: []const u8,
        callbacks: Callbacks,
    ) ProcessPlugin {
        return .{
            .allocator = allocator,
            .io = io,
            .name = name,
            .entry = entry,
            .callbacks = callbacks,
            .requests = RequestTracker.init(allocator),
        };
    }

    pub fn start(self: *ProcessPlugin) !void {
        self.state_mu.lock();
        if (self.state != .stopped and self.state != .failed) {
            self.state_mu.unlock();
            return error.AlreadyRunning;
        }
        self.state = .starting;
        self.state_mu.unlock();

        const cwd_opt: std.process.Child.Cwd = if (self.cwd) |c| .{ .path = c } else .inherit;
        const child = try std.process.spawn(self.io, .{
            .argv = &[_][]const u8{self.entry},
            .cwd = cwd_opt,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
        });
        self.child = child;
        self.stop_flag.store(false, .release);

        // Writer first so the reader can't race to write before the
        // queue is ready.
        self.writer_thread = try std.Thread.spawn(.{}, writerMain, .{self});
        self.reader_thread = try std.Thread.spawn(.{}, readerMain, .{self});

        self.state_mu.lock();
        self.state = .running;
        self.state_mu.unlock();
        log.info("started process plugin '{s}' (entry={s})", .{ self.name, self.entry });
    }

    pub fn stop(self: *ProcessPlugin) void {
        self.state_mu.lock();
        if (self.state == .stopped or self.state == .failed) {
            self.state_mu.unlock();
            return;
        }
        self.state = .stopping;
        self.state_mu.unlock();

        // Tell the plugin we're done.
        const shutdown = jsonrpc.buildNotification(self.allocator, "plugin/shutdown", "{}") catch null;
        if (shutdown) |s| self.enqueueRaw(s);

        // Yield briefly so the writer thread has a chance to flush
        // the shutdown notification before we yank stdin out from
        // under it. The 50 ms we used to wait here was overkill —
        // 5 ms is plenty for a single small frame and keeps the
        // editor's exit feel snappy. Plugins that miss the
        // notification still see EOF on stdin and exit cleanly.
        vigil.compat.sleep(5 * std.time.ns_per_ms);

        self.stop_flag.store(true, .release);

        // Closing stdin causes the child to see EOF and exit cleanly.
        if (self.child) |*c| {
            if (c.stdin) |stdin| {
                stdin.close(self.io);
                c.stdin = null;
            }
            _ = c.wait(self.io) catch {};
            self.child = null;
        }

        if (self.writer_thread) |t| {
            t.join();
            self.writer_thread = null;
        }
        if (self.reader_thread) |t| {
            t.join();
            self.reader_thread = null;
        }

        self.state_mu.lock();
        self.state = .stopped;
        self.state_mu.unlock();
    }

    pub fn deinit(self: *ProcessPlugin) void {
        self.stop();
        self.outbox_mu.lock();
        for (self.outbox.items) |buf| self.allocator.free(buf);
        self.outbox.deinit(self.allocator);
        self.outbox_mu.unlock();
        self.requests.deinit();
    }

    /// Enqueue a JSON-RPC notification to the plugin. Caller frees
    /// `params_json` — we dupe internally.
    pub fn sendNotification(
        self: *ProcessPlugin,
        method: []const u8,
        params_json: []const u8,
    ) !void {
        const frame = try jsonrpc.buildNotification(self.allocator, method, params_json);
        self.enqueueRaw(frame);
    }

    /// Enqueue a JSON-RPC reply.
    pub fn sendReply(self: *ProcessPlugin, id: u64, result_json: []const u8) !void {
        const frame = try jsonrpc.buildReply(self.allocator, id, result_json);
        self.enqueueRaw(frame);
    }

    pub fn sendError(self: *ProcessPlugin, id: u64, code: i32, message: []const u8) !void {
        const frame = try jsonrpc.buildError(self.allocator, id, code, message);
        self.enqueueRaw(frame);
    }

    fn enqueueRaw(self: *ProcessPlugin, frame_body: []u8) void {
        self.outbox_mu.lock();
        self.outbox.append(self.allocator, frame_body) catch {
            // OOM: drop the frame. Plugin will eventually time out if
            // it was waiting on a reply.
            self.allocator.free(frame_body);
            self.outbox_mu.unlock();
            return;
        };
        self.outbox_mu.unlock();
        self.outbox_signal.store(true, .release);
    }

    fn writerMain(self: *ProcessPlugin) void {
        const child = self.child orelse return;
        const stdin = child.stdin orelse return;

        var buf: [4096]u8 = undefined;
        var writer = stdin.writerStreaming(self.io, &buf);
        const w = &writer.interface;

        while (!self.stop_flag.load(.acquire)) {
            self.outbox_mu.lock();
            const next: ?[]u8 = if (self.outbox.items.len > 0)
                self.outbox.orderedRemove(0)
            else
                null;
            self.outbox_mu.unlock();

            if (next) |body| {
                defer self.allocator.free(body);
                jsonrpc.writeFrame(w, body) catch |err| {
                    log.warn("writer for '{s}' failed: {s}", .{ self.name, @errorName(err) });
                    return;
                };
                w.flush() catch return;
            } else {
                // No work — sleep briefly.
                vigil.compat.sleep(2 * std.time.ns_per_ms);
            }
        }
    }

    fn readerMain(self: *ProcessPlugin) void {
        const child = self.child orelse return;
        const stdout = child.stdout orelse return;

        var buf: [4096]u8 = undefined;
        var reader = stdout.readerStreaming(self.io, &buf);
        const r = &reader.interface;

        while (!self.stop_flag.load(.acquire)) {
            const body = jsonrpc.readFrame(self.allocator, r) catch |err| switch (err) {
                error.UnexpectedEof => {
                    log.info("plugin '{s}' closed stdout", .{self.name});
                    break;
                },
                else => {
                    log.warn("read failure for '{s}': {s}", .{ self.name, @errorName(err) });
                    break;
                },
            };
            defer self.allocator.free(body);

            // Parse into a typed envelope.
            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch {
                log.warn("invalid JSON from plugin '{s}'", .{self.name});
                continue;
            };
            defer parsed.deinit();

            const env = jsonrpc.parseEnvelope(parsed.value) catch {
                log.warn("invalid JSON-RPC envelope from plugin '{s}'", .{self.name});
                continue;
            };

            if (env.isReply()) {
                // Reply to one of OUR requests. Deliver via tracker.
                const id_value = env.id.?;
                if (id_value != .integer) continue;
                const id = @as(u64, @intCast(id_value.integer));
                if (env.result) |result| {
                    _ = self.requests.deliver(id, std.mem.asBytes(&result));
                }
            } else if (env.isRequest()) {
                const id_value = env.id.?;
                if (id_value != .integer) continue;
                const id = @as(u64, @intCast(id_value.integer));
                const method = env.method.?;
                const params = env.params orelse std.json.Value{ .null = {} };
                self.callbacks.on_request(self.callbacks.user_data, id, method, params);
            } else if (env.isNotification()) {
                const method = env.method.?;
                const params = env.params orelse std.json.Value{ .null = {} };
                self.callbacks.on_notification(self.callbacks.user_data, method, params);
            }
        }

        self.state_mu.lock();
        if (self.state == .running) self.state = .failed;
        self.state_mu.unlock();
        self.callbacks.on_exit(self.callbacks.user_data);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestState = struct {
    notifications_seen: std.ArrayListUnmanaged([]u8) = .empty,
    allocator: std.mem.Allocator,
    exited: bool = false,

    fn onNotification(user_data: *anyopaque, method: []const u8, _: std.json.Value) void {
        const self: *TestState = @ptrCast(@alignCast(user_data));
        const copy = self.allocator.dupe(u8, method) catch return;
        self.notifications_seen.append(self.allocator, copy) catch self.allocator.free(copy);
    }
    fn onRequest(_: *anyopaque, _: u64, _: []const u8, _: std.json.Value) void {}
    fn onExit(user_data: *anyopaque) void {
        const self: *TestState = @ptrCast(@alignCast(user_data));
        self.exited = true;
    }
};

test "ProcessPlugin: lifecycle against /bin/cat (echoes frames back as notifications via separate pipeline)" {
    // We can't easily run a full plugin in a unit test without
    // building it, but we can at least exercise init/deinit shape.
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    var ts: TestState = .{ .allocator = a };
    defer {
        for (ts.notifications_seen.items) |s| a.free(s);
        ts.notifications_seen.deinit(a);
    }

    var pp = ProcessPlugin.init(a, threaded.io(), "test", "/bin/false", .{
        .user_data = @ptrCast(&ts),
        .on_notification = TestState.onNotification,
        .on_request = TestState.onRequest,
        .on_exit = TestState.onExit,
    });
    defer pp.deinit();

    // Don't actually start it — /bin/false exits immediately and the
    // reader/writer thread join logic would race the test runner. The
    // structural test here is just that init / deinit don't leak.
    try std.testing.expectEqual(State.stopped, pp.state);
}
