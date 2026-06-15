const std = @import("std");
const args_mod = @import("tools/lsp_host_args.zig");
const Transport = @import("lsp/transport.zig");
const zls_embedded = @import("services/lsp/zls_embedded.zig");
const platform = @import("kernel/platform.zig");

const log = std.log.scoped(.LSPHost);

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded = std.Io.Threaded.init(allocator, .{
        .argv0 = .init(.{ .vector = init.args.vector }),
        .environ = .{ .block = init.environ.block },
    });
    defer threaded.deinit();
    const io = threaded.io();

    var args_list = std.ArrayListUnmanaged([]const u8).empty;
    defer {
        for (args_list.items) |arg| allocator.free(arg);
        args_list.deinit(allocator);
    }

    var args_it = try std.process.Args.Iterator.initAllocator(init.args, allocator);
    defer args_it.deinit();
    while (args_it.next()) |arg| {
        try args_list.append(allocator, try allocator.dupe(u8, arg));
    }

    const mode = args_mod.parse(args_list.items) catch |err| {
        log.err("invalid stem-lsp-host arguments: {}", .{err});
        return err;
    };

    switch (mode) {
        .embedded_zls => try runEmbeddedZls(allocator, io, init.environ.block),
        .external => |external| try runExternal(io, external.argv, init.environ.block),
    }
}

const FilePump = struct {
    input: std.Io.File,
    output: std.Io.File,
    environ_block: std.process.Environ.Block,
    close_output: bool = false,
    done: std.atomic.Value(bool) = .{ .raw = false },

    fn run(self: *@This()) void {
        var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{
            .environ = .{ .block = self.environ_block },
        });
        defer threaded.deinit();
        const io = threaded.io();

        defer {
            if (self.close_output) self.output.close(io);
            self.done.store(true, .release);
        }

        var buf: [8192]u8 = undefined;
        while (true) {
            var iovec = [_][]u8{&buf};
            const n = self.input.readStreaming(io, &iovec) catch break;
            if (n == 0) break;
            self.output.writeStreamingAll(io, buf[0..n]) catch break;
        }
    }
};

const FileToPipePump = struct {
    input: std.Io.File,
    output: *Transport.MemPipe,
    environ_block: std.process.Environ.Block,
    done: std.atomic.Value(bool) = .{ .raw = false },

    fn run(self: *@This()) void {
        var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{
            .environ = .{ .block = self.environ_block },
        });
        defer threaded.deinit();
        const io = threaded.io();

        defer {
            self.output.close();
            self.done.store(true, .release);
        }

        var buf: [8192]u8 = undefined;
        while (true) {
            var iovec = [_][]u8{&buf};
            const n = self.input.readStreaming(io, &iovec) catch break;
            if (n == 0) break;
            _ = self.output.write(buf[0..n]) catch break;
        }
    }
};

const PipeToFilePump = struct {
    input: *Transport.MemPipe,
    output: std.Io.File,
    environ_block: std.process.Environ.Block,
    done: std.atomic.Value(bool) = .{ .raw = false },

    fn run(self: *@This()) void {
        var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{
            .environ = .{ .block = self.environ_block },
        });
        defer threaded.deinit();
        const io = threaded.io();

        defer self.done.store(true, .release);

        var buf: [8192]u8 = undefined;
        while (true) {
            const n = self.input.read(&buf) catch break;
            if (n == 0) break;
            self.output.writeStreamingAll(io, buf[0..n]) catch break;
        }
    }
};

const ChildWatch = struct {
    pid: platform.Pid,
    environ_block: std.process.Environ.Block,
    input_done: *std.atomic.Value(bool),
    child_done: std.atomic.Value(bool) = .{ .raw = false },

    fn run(self: *@This()) void {
        var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{
            .environ = .{ .block = self.environ_block },
        });
        defer threaded.deinit();
        const io = threaded.io();

        const poll_ms: u32 = 25;
        while (!self.input_done.load(.acquire)) {
            if (self.child_done.load(.acquire)) return;
            std.Io.sleep(io, .fromMilliseconds(poll_ms), .awake) catch return;
        }

        var waited_ms: u32 = 0;
        while (waited_ms < 3000) : (waited_ms += poll_ms) {
            if (self.child_done.load(.acquire)) return;
            std.Io.sleep(io, .fromMilliseconds(poll_ms), .awake) catch return;
        }

        if (!self.child_done.load(.acquire)) {
            platform.killProcessTree(self.pid);
        }
    }
};

fn runExternal(io: std.Io, server_argv: []const []const u8, environ_block: std.process.Environ.Block) !void {
    if (server_argv.len == 0) return error.MissingServerCommand;

    var child = try std.process.spawn(io, .{
        .argv = server_argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
        .pgid = platform.childProcessGroupForSpawn(),
    });
    errdefer {
        if (child.id) |pid| platform.killProcessTreeForce(pid) else child.kill(io);
        _ = child.wait(io) catch {};
    }

    const server_stdin = child.stdin.?;
    child.stdin = null;

    var input_pump = FilePump{
        .input = std.Io.File.stdin(),
        .output = server_stdin,
        .environ_block = environ_block,
        .close_output = true,
    };
    var output_pump = FilePump{
        .input = child.stdout.?,
        .output = std.Io.File.stdout(),
        .environ_block = environ_block,
    };
    var watch = ChildWatch{
        .pid = child.id.?,
        .environ_block = environ_block,
        .input_done = &input_pump.done,
    };

    const input_thread = try std.Thread.spawn(.{}, FilePump.run, .{&input_pump});
    const output_thread = try std.Thread.spawn(.{}, FilePump.run, .{&output_pump});
    const watch_thread = try std.Thread.spawn(.{}, ChildWatch.run, .{&watch});

    const term = child.wait(io) catch std.process.Child.Term{ .unknown = 0 };
    watch.child_done.store(true, .release);
    watch_thread.join();
    output_thread.join();
    if (input_pump.done.load(.acquire)) {
        input_thread.join();
    } else {
        input_thread.detach();
    }

    switch (term) {
        .exited => |code| std.process.exit(@intCast(@min(code, 255))),
        else => std.process.exit(1),
    }
}

fn runEmbeddedZls(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_block: std.process.Environ.Block,
) !void {
    var to_zls = Transport.MemPipe.init(allocator, io);
    defer to_zls.deinit();
    var from_zls = Transport.MemPipe.init(allocator, io);
    defer from_zls.deinit();

    var input_pump = FileToPipePump{
        .input = std.Io.File.stdin(),
        .output = &to_zls,
        .environ_block = environ_block,
    };
    var output_pump = PipeToFilePump{
        .input = &from_zls,
        .output = std.Io.File.stdout(),
        .environ_block = environ_block,
    };

    const input_thread = try std.Thread.spawn(.{}, FileToPipePump.run, .{&input_pump});
    const output_thread = try std.Thread.spawn(.{}, PipeToFilePump.run, .{&output_pump});
    const zls_thread = try std.Thread.spawn(.{}, zls_embedded.runEmbeddedZLS, .{
        allocator,
        &to_zls,
        &from_zls,
        environ_block,
    });

    zls_thread.join();
    from_zls.close();
    output_thread.join();
    if (input_pump.done.load(.acquire)) {
        input_thread.join();
    } else {
        input_thread.detach();
    }
}
