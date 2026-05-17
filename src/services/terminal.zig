const std = @import("std");
const vigil = @import("vigil");
const protocol = @import("../kernel/protocol.zig");
const builtin = @import("builtin");
const platform = @import("../kernel/platform.zig");

const is_windows = builtin.os.tag == .windows;

pub const JobHandle = struct {
    id: u64,
    pid: ?platform.Pid = null,
    cancelled: bool = false,
    cancelled_flag: ?*std.atomic.Value(bool) = null,
    pid_storage: ?*std.atomic.Value(platform.Pid) = null,
    pid_set_flag: ?*std.atomic.Value(bool) = null,
};

pub const TerminalConfig = struct {
    max_output_bytes: usize = 10 * 1024 * 1024,
    timeout_ms: ?u64 = null,
    chunk_size: usize = 4096,
    history_limit: usize = 100,
};

pub const TerminalService = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Parent process environment block. Forwarded to async worker threads so
    /// each spawned worker's Threaded io sees the same env as the editor.
    environ_block: ?std.process.Environ.Block = null,
    config: TerminalConfig,
    next_job_id: u64 = 1,
    current_job: ?JobHandle = null,

    history: std.ArrayListUnmanaged([]const u8) = .empty,
    history_index: ?usize = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) TerminalService {
        return .{
            .allocator = allocator,
            .io = io,
            .config = .{},
        };
    }

    pub fn setEnvironBlock(self: *TerminalService, environ_block: std.process.Environ.Block) void {
        self.environ_block = environ_block;
    }

    pub fn deinit(self: *TerminalService) void {
        for (self.history.items) |cmd| {
            self.allocator.free(cmd);
        }
        self.history.deinit(self.allocator);
    }

    pub fn addToHistory(self: *TerminalService, command: []const u8) !void {
        if (command.len == 0) return;

        if (self.history.items.len > 0) {
            const last = self.history.items[self.history.items.len - 1];
            if (std.mem.eql(u8, last, command)) return;
        }

        while (self.history.items.len >= self.config.history_limit) {
            const old = self.history.orderedRemove(0);
            self.allocator.free(old);
        }

        const cmd_dupe = try self.allocator.dupe(u8, command);
        try self.history.append(self.allocator, cmd_dupe);
        self.history_index = null;
    }

    pub fn historyPrevious(self: *TerminalService) ?[]const u8 {
        if (self.history.items.len == 0) return null;

        if (self.history_index) |idx| {
            if (idx > 0) {
                self.history_index = idx - 1;
            }
        } else {
            self.history_index = self.history.items.len - 1;
        }

        return self.history.items[self.history_index.?];
    }

    pub fn historyNext(self: *TerminalService) ?[]const u8 {
        if (self.history.items.len == 0) return null;

        if (self.history_index) |idx| {
            if (idx < self.history.items.len - 1) {
                self.history_index = idx + 1;
                return self.history.items[self.history_index.?];
            } else {
                self.history_index = null;
                return null;
            }
        }
        return null;
    }

    pub fn resetHistoryNavigation(self: *TerminalService) void {
        self.history_index = null;
    }

    pub fn runSync(self: *TerminalService, command: []const u8, cwd: ?[]const u8) ![]u8 {
        const argv = if (is_windows)
            &[_][]const u8{ "cmd.exe", "/c", command }
        else
            &[_][]const u8{ "/bin/sh", "-c", command };

        const cwd_opt: std.process.Child.Cwd = if (cwd) |dir| .{ .path = dir } else .inherit;

        const result = try std.process.run(self.allocator, self.io, .{
            .argv = argv,
            .cwd = cwd_opt,
            .stdout_limit = .limited(self.config.max_output_bytes),
            .stderr_limit = .limited(self.config.max_output_bytes),
        });
        defer self.allocator.free(result.stderr);

        const exit_code: i32 = switch (result.term) {
            .exited => |code| @as(i32, code),
            .signal => |sig| -@as(i32, @intCast(@intFromEnum(sig))),
            else => -999,
        };

        const exit_info = try std.fmt.allocPrint(
            self.allocator,
            "\n[Exit: {}]\n",
            .{exit_code},
        );
        defer self.allocator.free(exit_info);

        if (result.stderr.len > 0) {
            const combined = try self.allocator.alloc(u8, result.stdout.len + result.stderr.len + exit_info.len);
            @memcpy(combined[0..result.stdout.len], result.stdout);
            @memcpy(combined[result.stdout.len .. result.stdout.len + result.stderr.len], result.stderr);
            @memcpy(combined[result.stdout.len + result.stderr.len ..], exit_info);
            self.allocator.free(result.stdout);
            return combined;
        } else {
            const combined = try self.allocator.alloc(u8, result.stdout.len + exit_info.len);
            @memcpy(combined[0..result.stdout.len], result.stdout);
            @memcpy(combined[result.stdout.len..], exit_info);
            self.allocator.free(result.stdout);
            return combined;
        }
    }

    const AsyncContext = struct {
        allocator: std.mem.Allocator,
        command: []const u8,
        cwd: ?[]const u8,
        inbox: *vigil.Inbox,
        job_id: u64,
        config: TerminalConfig,
        cancelled: *std.atomic.Value(bool),
        child_pid: *std.atomic.Value(platform.Pid),
        pid_set: *std.atomic.Value(bool),
        environ_block: std.process.Environ.Block,
    };

    pub fn runAsync(self: *TerminalService, command: []const u8, cwd: ?[]const u8, inbox: *vigil.Inbox) !JobHandle {
        const job_id = self.next_job_id;
        self.next_job_id += 1;

        const cancelled_flag = try self.allocator.create(std.atomic.Value(bool));
        cancelled_flag.* = std.atomic.Value(bool).init(false);
        errdefer self.allocator.destroy(cancelled_flag);

        const pid_storage = try self.allocator.create(std.atomic.Value(platform.Pid));
        pid_storage.* = std.atomic.Value(platform.Pid).init(0);
        errdefer self.allocator.destroy(pid_storage);

        const pid_set_flag = try self.allocator.create(std.atomic.Value(bool));
        pid_set_flag.* = std.atomic.Value(bool).init(false);
        errdefer self.allocator.destroy(pid_set_flag);

        const handle = JobHandle{
            .id = job_id,
            .pid = null,
            .cancelled = false,
            .cancelled_flag = cancelled_flag,
            .pid_storage = pid_storage,
            .pid_set_flag = pid_set_flag,
        };

        self.current_job = handle;

        const ctx = try self.allocator.create(AsyncContext);
        ctx.* = .{
            .allocator = self.allocator,
            .command = try self.allocator.dupe(u8, command),
            .cwd = if (cwd) |dir| try self.allocator.dupe(u8, dir) else null,
            .inbox = inbox,
            .job_id = job_id,
            .config = self.config,
            .cancelled = cancelled_flag,
            .child_pid = pid_storage,
            .pid_set = pid_set_flag,
            .environ_block = self.environ_block orelse .empty,
        };

        const thread = try std.Thread.spawn(.{}, runAsyncWorker, .{ctx});
        thread.detach();

        return handle;
    }

    fn runAsyncWorker(ctx: *AsyncContext) void {
        defer {
            ctx.allocator.free(ctx.command);
            if (ctx.cwd) |dir| ctx.allocator.free(dir);
            ctx.allocator.destroy(ctx);
        }

        // This worker runs in its own std.Thread.spawn worker, so it needs its
        // own Threaded io. Forward the parent's environ block so the spawned
        // child process sees the same env as the editor.
        var threaded = std.Io.Threaded.init(ctx.allocator, .{
            .environ = .{ .block = ctx.environ_block },
        });
        defer threaded.deinit();
        const io = threaded.io();

        const argv = if (is_windows)
            &[_][]const u8{ "cmd.exe", "/c", ctx.command }
        else
            &[_][]const u8{ "/bin/sh", "-c", ctx.command };

        const cwd_opt: std.process.Child.Cwd = if (ctx.cwd) |dir| .{ .path = dir } else .inherit;

        var child = std.process.spawn(io, .{
            .argv = argv,
            .cwd = cwd_opt,
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch |err| {
            const err_msg = std.fmt.allocPrint(ctx.allocator, "Failed to spawn process: {}\n", .{err}) catch return;
            defer ctx.allocator.free(err_msg);
            // best-effort: parent UI may have already exited; nothing else to do
            sendOutputChunk(ctx.inbox, err_msg, ctx.allocator) catch {};
            sendResult(ctx.inbox, false, 1, ctx.allocator) catch {};
            return;
        };
        defer child.kill(io);

        if (child.id) |id| {
            ctx.child_pid.store(id, .release);
            ctx.pid_set.store(true, .release);
        }

        const stdout = child.stdout orelse return;
        var total_bytes: usize = 0;
        var was_truncated = false;

        var chunk_buf: [4096]u8 = undefined;
        while (!ctx.cancelled.load(.acquire)) {
            var iovec = [_][]u8{&chunk_buf};
            const bytes_read = stdout.readStreaming(io, &iovec) catch break;
            if (bytes_read == 0) break;

            if (total_bytes + bytes_read > ctx.config.max_output_bytes) {
                was_truncated = true;
                const remaining = ctx.config.max_output_bytes - total_bytes;
                if (remaining > 0) {
                    sendOutputChunk(ctx.inbox, chunk_buf[0..remaining], ctx.allocator) catch {};
                }
                sendOutputChunk(ctx.inbox, "\n[Output truncated - exceeded size limit]\n", ctx.allocator) catch {};
                break;
            }

            total_bytes += bytes_read;
            sendOutputChunk(ctx.inbox, chunk_buf[0..bytes_read], ctx.allocator) catch {};
        }

        if (child.stderr) |stderr| {
            var stderr_iterations: usize = 0;
            const max_stderr_iterations: usize = 10000;
            while (!ctx.cancelled.load(.acquire) and stderr_iterations < max_stderr_iterations) {
                var iovec = [_][]u8{&chunk_buf};
                const bytes_read = stderr.readStreaming(io, &iovec) catch break;
                if (bytes_read == 0) break;
                if (!was_truncated and total_bytes + bytes_read <= ctx.config.max_output_bytes) {
                    total_bytes += bytes_read;
                    sendOutputChunk(ctx.inbox, chunk_buf[0..bytes_read], ctx.allocator) catch {};
                }
                stderr_iterations += 1;
            }
        }

        const term = child.wait(io) catch {
            sendResult(ctx.inbox, false, -1, ctx.allocator) catch {};
            return;
        };

        const exit_code: i32 = switch (term) {
            .exited => |code| @as(i32, code),
            .signal => |sig| -@as(i32, @intCast(@intFromEnum(sig))),
            else => -999,
        };

        const exit_msg = std.fmt.allocPrint(ctx.allocator, "\n[Exit: {}]\n", .{exit_code}) catch return;
        defer ctx.allocator.free(exit_msg);
        sendOutputChunk(ctx.inbox, exit_msg, ctx.allocator) catch {};

        sendResult(ctx.inbox, exit_code == 0, exit_code, ctx.allocator) catch {};
    }

    fn sendOutputChunk(inbox: *vigil.Inbox, data: []const u8, allocator: std.mem.Allocator) !void {
        const msg = protocol.Message{ .terminal_output_chunk = data };
        const bytes = try msg.encode(allocator);
        defer allocator.free(bytes);
        try inbox.send(bytes);
    }

    fn sendResult(inbox: *vigil.Inbox, success: bool, exit_code: i32, allocator: std.mem.Allocator) !void {
        const msg = protocol.Message{
            .terminal_result = .{
                .output = "",
                .exit_code = exit_code,
                .success = success,
            },
        };
        const bytes = try msg.encode(allocator);
        defer allocator.free(bytes);
        try inbox.send(bytes);
    }

    pub fn cancelCurrentJob(self: *TerminalService) bool {
        if (self.current_job) |*job| {
            job.cancelled = true;

            if (job.cancelled_flag) |flag| {
                flag.store(true, .release);
            }

            if (job.pid_set_flag) |pid_set| {
                if (pid_set.load(.acquire)) {
                    if (job.pid_storage) |pid_storage| {
                        const pid = pid_storage.load(.acquire);
                        if (pid != 0) {
                            platform.killProcess(pid);
                            return true;
                        }
                    }
                }
            }

            if (job.pid) |pid| {
                platform.killProcess(pid);
                return true;
            }
        }
        return false;
    }

    pub fn isRunning(self: *TerminalService) bool {
        return self.current_job != null and !self.current_job.?.cancelled;
    }

    pub fn clearCurrentJob(self: *TerminalService) void {
        self.current_job = null;
    }

    pub fn run(self: *TerminalService, command: []const u8, inbox: *vigil.Inbox) !void {
        _ = try self.runAsync(command, inbox);
    }
};

test "terminal service history" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ts = TerminalService.init(allocator, io);
    defer ts.deinit();

    try ts.addToHistory("ls");
    try ts.addToHistory("pwd");
    try ts.addToHistory("echo hello");

    try std.testing.expectEqualStrings("echo hello", ts.historyPrevious().?);
    try std.testing.expectEqualStrings("pwd", ts.historyPrevious().?);
    try std.testing.expectEqualStrings("ls", ts.historyPrevious().?);
    try std.testing.expectEqualStrings("ls", ts.historyPrevious().?);

    try std.testing.expectEqualStrings("pwd", ts.historyNext().?);
    try std.testing.expectEqualStrings("echo hello", ts.historyNext().?);
    try std.testing.expect(ts.historyNext() == null);
}

test "terminal service no duplicate history" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ts = TerminalService.init(allocator, io);
    defer ts.deinit();

    try ts.addToHistory("ls");
    try ts.addToHistory("ls");
    try ts.addToHistory("pwd");
    try ts.addToHistory("pwd");

    try std.testing.expectEqual(@as(usize, 2), ts.history.items.len);
}
