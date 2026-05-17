//! Reference out-of-process plugin for stem (Phase 1 ABI).
//!
//! Demonstrates the minimum viable plugin: speaks JSON-RPC 2.0 over
//! stdio with LSP-style framing, registers one command, logs a
//! greeting when that command fires.
//!
//! Wire layout (each direction):
//!
//!   Content-Length: <N>\r\n\r\n
//!   {"jsonrpc":"2.0",...}
//!
//! Methods we issue to the host:
//!   - `plugin/log`             notification — write to stem's log
//!   - `plugin/registerCommand` notification — populate command palette
//!
//! Methods the host issues to us:
//!   - `plugin/initialize`      notification — first message
//!   - `command/execute`        notification — user invoked a command
//!   - `plugin/shutdown`        notification — please exit cleanly

const std = @import("std");

const PLUGIN_ID = "echo";

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const stdin = std.Io.File.stdin();
    const stdout = std.Io.File.stdout();

    var rd_buf: [4096]u8 = undefined;
    var reader = stdin.readerStreaming(io, &rd_buf);
    const r = &reader.interface;

    var wr_buf: [4096]u8 = undefined;
    var writer = stdout.writerStreaming(io, &wr_buf);
    const w = &writer.interface;

    // Self-register our command up front. Host queues notifications
    // until its writer thread drains them; the order on the wire is
    // strictly what we write.
    try sendRegisterCommand(w, allocator, "echo.hello", "[Echo] Hello", "Log a greeting from the echo plugin");
    try sendLog(w, allocator, 1, "echo plugin: ready");

    // Event loop: read JSON-RPC frames, dispatch.
    while (true) {
        const body = readFrame(allocator, r) catch |err| switch (err) {
            error.EndOfStream, error.UnexpectedEof => return,
            else => return err,
        };
        defer allocator.free(body);

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const obj = parsed.value.object;

        const method_v = obj.get("method") orelse continue;
        if (method_v != .string) continue;
        const method = method_v.string;

        if (std.mem.eql(u8, method, "plugin/shutdown")) {
            try sendLog(w, allocator, 1, "echo plugin: shutting down");
            return;
        }

        if (std.mem.eql(u8, method, "plugin/initialize")) {
            try sendLog(w, allocator, 0, "echo plugin: initialized");
            continue;
        }

        if (std.mem.eql(u8, method, "command/execute")) {
            const params = obj.get("params") orelse continue;
            if (params != .object) continue;
            const id_v = params.object.get("id") orelse continue;
            if (id_v != .string) continue;
            if (std.mem.eql(u8, id_v.string, "echo.hello")) {
                try sendLog(w, allocator, 1, "echo plugin: hello from a process plugin");
            }
            continue;
        }
    }
}

// -----------------------------------------------------------------------------
// JSON-RPC framing helpers — kept self-contained so the plugin has no
// runtime dependency on stem's Zig modules.
// -----------------------------------------------------------------------------

fn readFrame(allocator: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    var header_buf: [256]u8 = undefined;
    var header_len: usize = 0;
    while (true) {
        if (header_len >= header_buf.len) return error.InvalidFrame;
        const byte = reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => return error.EndOfStream,
            else => return err,
        };
        header_buf[header_len] = byte;
        header_len += 1;
        if (header_len >= 4 and
            header_buf[header_len - 4] == '\r' and
            header_buf[header_len - 3] == '\n' and
            header_buf[header_len - 2] == '\r' and
            header_buf[header_len - 1] == '\n') break;
    }
    var length: usize = 0;
    var lines = std.mem.splitSequence(u8, header_buf[0..header_len], "\r\n");
    while (lines.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const colon = std.mem.indexOfScalar(u8, line, ':').? + 1;
            const v = std.mem.trim(u8, line[colon..], " \t");
            length = try std.fmt.parseInt(usize, v, 10);
        }
    }
    if (length == 0) return error.InvalidFrame;
    const body = try allocator.alloc(u8, length);
    errdefer allocator.free(body);
    reader.readSliceAll(body) catch return error.UnexpectedEof;
    return body;
}

fn writeFrame(w: *std.Io.Writer, body: []const u8) !void {
    var hdr: [64]u8 = undefined;
    const header = try std.fmt.bufPrint(&hdr, "Content-Length: {d}\r\n\r\n", .{body.len});
    try w.writeAll(header);
    try w.writeAll(body);
    try w.flush();
}

fn sendLog(w: *std.Io.Writer, allocator: std.mem.Allocator, level: u8, msg: []const u8) !void {
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"method\":\"plugin/log\",\"params\":{{\"level\":{d},\"message\":\"{s}\"}}}}",
        .{ level, msg },
    );
    defer allocator.free(body);
    try writeFrame(w, body);
}

fn sendRegisterCommand(
    w: *std.Io.Writer,
    allocator: std.mem.Allocator,
    id: []const u8,
    title: []const u8,
    description: []const u8,
) !void {
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"method\":\"plugin/registerCommand\",\"params\":{{\"plugin_id\":\"{s}\",\"id\":\"{s}\",\"title\":\"{s}\",\"description\":\"{s}\"}}}}",
        .{ PLUGIN_ID, id, title, description },
    );
    defer allocator.free(body);
    try writeFrame(w, body);
}
