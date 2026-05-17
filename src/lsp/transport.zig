const std = @import("std");
const zls = @import("zls");
const lsp = zls.lsp;

pub const TransportType = enum { Embedded, Stdio };

pub const LSPTransport = struct {
    read_fn: *const fn (ctx: *anyopaque, buffer: []u8) anyerror!usize,
    write_fn: *const fn (ctx: *anyopaque, data: []const u8) anyerror!usize,
    context: *anyopaque,

    pub fn read(self: LSPTransport, buffer: []u8) !usize {
        return self.read_fn(self.context, buffer);
    }

    pub fn write(self: LSPTransport, data: []const u8) !usize {
        return self.write_fn(self.context, data);
    }
};

pub const EmbeddedTransport = struct {
    transport: lsp.Transport,
    input_pipe: *MemPipe,
    output_pipe: *MemPipe,
    read_buffer: [4096]u8 = undefined,
    read_pos: usize = 0,
    read_len: usize = 0,

    const vtable: lsp.Transport.VTable = .{
        .readJsonMessage = readJsonMessage,
        .writeJsonMessage = writeJsonMessage,
    };

    pub fn init(input_pipe: *MemPipe, output_pipe: *MemPipe) EmbeddedTransport {
        return .{
            .transport = .{ .vtable = &vtable },
            .input_pipe = input_pipe,
            .output_pipe = output_pipe,
        };
    }

    fn readByte(self: *EmbeddedTransport) !u8 {
        if (self.read_pos >= self.read_len) {
            self.read_len = try self.input_pipe.read(&self.read_buffer);
            self.read_pos = 0;
            if (self.read_len == 0) return error.EndOfStream;
        }
        const byte = self.read_buffer[self.read_pos];
        self.read_pos += 1;
        return byte;
    }

    fn readExact(self: *EmbeddedTransport, dest: []u8) !void {
        var written: usize = 0;
        while (written < dest.len) {
            if (self.read_pos < self.read_len) {
                const available = self.read_len - self.read_pos;
                const to_copy = @min(available, dest.len - written);
                @memcpy(dest[written .. written + to_copy], self.read_buffer[self.read_pos .. self.read_pos + to_copy]);
                self.read_pos += to_copy;
                written += to_copy;
            } else {
                self.read_len = try self.input_pipe.read(&self.read_buffer);
                self.read_pos = 0;
                if (self.read_len == 0) return error.EndOfStream;
            }
        }
    }

    fn readJsonMessage(transport_ptr: *lsp.Transport, io: std.Io, allocator: std.mem.Allocator) lsp.Transport.ReadError![]u8 {
        _ = io;
        const self: *EmbeddedTransport = @fieldParentPtr("transport", transport_ptr);

        var header_buf: [256]u8 = undefined;
        var header_len: usize = 0;
        var content_length: ?usize = null;

        while (true) {
            const byte = self.readByte() catch |err| {
                return if (err == error.EndOfStream) error.EndOfStream else error.Unexpected;
            };
            if (header_len >= header_buf.len) return error.OversizedHeaderField;
            header_buf[header_len] = byte;
            header_len += 1;

            if (header_len >= 4 and
                header_buf[header_len - 4] == '\r' and
                header_buf[header_len - 3] == '\n' and
                header_buf[header_len - 2] == '\r' and
                header_buf[header_len - 1] == '\n')
            {
                break;
            }
        }

        const header_str = header_buf[0..header_len];
        var lines = std.mem.splitSequence(u8, header_str, "\r\n");
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
                const value_start = std.mem.indexOf(u8, line, ":").? + 1;
                const value = std.mem.trim(u8, line[value_start..], " ");
                content_length = std.fmt.parseInt(usize, value, 10) catch return error.InvalidContentLength;
            }
        }

        const length = content_length orelse return error.MissingContentLength;

        const body = allocator.alloc(u8, length) catch return error.OutOfMemory;
        errdefer allocator.free(body);

        self.readExact(body) catch |err| {
            return if (err == error.EndOfStream) error.EndOfStream else error.Unexpected;
        };

        return body;
    }

    fn writeJsonMessage(transport_ptr: *lsp.Transport, io: std.Io, json_message: []const u8) lsp.Transport.WriteError!void {
        _ = io;
        const self: *EmbeddedTransport = @fieldParentPtr("transport", transport_ptr);

        var header_buf: [64]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "Content-Length: {d}\r\n\r\n", .{json_message.len}) catch unreachable;

        _ = self.output_pipe.write(header) catch |err| switch (err) {
            error.BrokenPipe => return,
            else => return error.Unexpected,
        };

        _ = self.output_pipe.write(json_message) catch |err| switch (err) {
            error.BrokenPipe => return,
            else => return error.Unexpected,
        };
    }
};

pub const MemPipe = struct {
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    buffer: std.ArrayListUnmanaged(u8) = .empty,
    allocator: std.mem.Allocator,
    io: std.Io,
    closed: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) MemPipe {
        return .{
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn deinit(self: *MemPipe) void {
        self.buffer.deinit(self.allocator);
    }

    pub fn read(self: *MemPipe, dest: []u8) !usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        while (self.buffer.items.len == 0) {
            if (self.closed) return 0;
            self.cond.waitUncancelable(self.io, &self.mutex);
        }

        const count = @min(dest.len, self.buffer.items.len);
        @memcpy(dest[0..count], self.buffer.items[0..count]);

        self.buffer.replaceRange(self.allocator, 0, count, &[_]u8{}) catch unreachable;

        return count;
    }

    pub fn write(self: *MemPipe, data: []const u8) !usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.closed) return error.BrokenPipe;

        self.buffer.appendSlice(self.allocator, data) catch return error.OutOfMemory;
        self.cond.signal(self.io);
        return data.len;
    }

    pub fn close(self: *MemPipe) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.closed = true;
        self.cond.broadcast(self.io);
    }
};

// ---------- MemPipe tests ----------

test "MemPipe write then read returns same bytes" {
    const a = std.testing.allocator;
    const TestIo = @import("../test_utils.zig").TestIo;
    var io_ctx = TestIo.init(a);
    defer io_ctx.deinit();

    var pipe = MemPipe.init(a, io_ctx.io());
    defer pipe.deinit();

    _ = try pipe.write("hello");
    var buf: [16]u8 = undefined;
    const n = try pipe.read(&buf);
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqualStrings("hello", buf[0..n]);
}

test "MemPipe partial reads consume buffer in order" {
    const a = std.testing.allocator;
    const TestIo = @import("../test_utils.zig").TestIo;
    var io_ctx = TestIo.init(a);
    defer io_ctx.deinit();

    var pipe = MemPipe.init(a, io_ctx.io());
    defer pipe.deinit();

    _ = try pipe.write("abcdefghij"); // 10 bytes
    var buf: [4]u8 = undefined;
    const n1 = try pipe.read(&buf);
    try std.testing.expectEqual(@as(usize, 4), n1);
    try std.testing.expectEqualStrings("abcd", buf[0..n1]);
    const n2 = try pipe.read(&buf);
    try std.testing.expectEqualStrings("efgh", buf[0..n2]);
    const n3 = try pipe.read(&buf);
    try std.testing.expectEqualStrings("ij", buf[0..n3]);
}

test "MemPipe write after close returns BrokenPipe" {
    const a = std.testing.allocator;
    const TestIo = @import("../test_utils.zig").TestIo;
    var io_ctx = TestIo.init(a);
    defer io_ctx.deinit();

    var pipe = MemPipe.init(a, io_ctx.io());
    defer pipe.deinit();

    pipe.close();
    try std.testing.expectError(error.BrokenPipe, pipe.write("x"));
}

test "MemPipe read on closed-empty returns 0 (EOF)" {
    const a = std.testing.allocator;
    const TestIo = @import("../test_utils.zig").TestIo;
    var io_ctx = TestIo.init(a);
    defer io_ctx.deinit();

    var pipe = MemPipe.init(a, io_ctx.io());
    defer pipe.deinit();

    pipe.close();
    var buf: [4]u8 = undefined;
    const n = try pipe.read(&buf);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "MemPipe drains buffered data after close" {
    const a = std.testing.allocator;
    const TestIo = @import("../test_utils.zig").TestIo;
    var io_ctx = TestIo.init(a);
    defer io_ctx.deinit();

    var pipe = MemPipe.init(a, io_ctx.io());
    defer pipe.deinit();

    _ = try pipe.write("residual");
    pipe.close();
    // Even after close, pending bytes should be readable.
    var buf: [16]u8 = undefined;
    const n = try pipe.read(&buf);
    try std.testing.expectEqual(@as(usize, 8), n);
    try std.testing.expectEqualStrings("residual", buf[0..n]);
    // Next read returns EOF.
    const n2 = try pipe.read(&buf);
    try std.testing.expectEqual(@as(usize, 0), n2);
}
