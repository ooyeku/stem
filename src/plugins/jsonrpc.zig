//! JSON-RPC 2.0 framing and envelope helpers for out-of-process plugins.
//!
//! Wire format mirrors LSP: each message is preceded by an HTTP-style
//! header block, terminated by `\r\n\r\n`. The only required header is
//! `Content-Length: <bytes>`. The body is one JSON-RPC 2.0 object.
//!
//!   Content-Length: 92\r\n\r\n
//!   {"jsonrpc":"2.0","id":1,"method":"plugin/registerCommand","params":{"id":"git.status",...}}
//!
//! Why LSP framing: it's the lingua franca for editor protocols,
//! plugin authors writing in other languages already have parsers,
//! and stem already handles it on the LSP side. One framing, two
//! consumers.
//!
//! Why JSON-RPC 2.0: out-of-process plugins are language-agnostic by
//! design — someone can write a plugin in Rust, Go, Python, or Bun
//! and have it work. JSON is the lowest-friction encoding for that.

const std = @import("std");

pub const Error = error{
    InvalidFrame,
    InvalidContentLength,
    UnexpectedEof,
    InvalidJson,
} || std.mem.Allocator.Error || std.Io.Reader.Error || std.Io.Writer.Error;

/// Read one JSON-RPC frame from a reader. Returns the body bytes;
/// caller owns and must `allocator.free` them.
pub fn readFrame(allocator: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    // Header parse: read until \r\n\r\n.
    var header_buf: [512]u8 = undefined;
    var header_len: usize = 0;

    while (true) {
        if (header_len >= header_buf.len) return error.InvalidFrame;
        const byte = reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => return if (header_len == 0) error.UnexpectedEof else error.InvalidFrame,
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

    var content_length: ?usize = null;
    var lines = std.mem.splitSequence(u8, header_buf[0..header_len], "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const colon = std.mem.indexOfScalar(u8, line, ':').? + 1;
            const value = std.mem.trim(u8, line[colon..], " \t");
            content_length = std.fmt.parseInt(usize, value, 10) catch return error.InvalidContentLength;
        }
    }

    const length = content_length orelse return error.InvalidContentLength;
    if (length > 16 * 1024 * 1024) return error.InvalidFrame; // 16 MiB cap

    const body = try allocator.alloc(u8, length);
    errdefer allocator.free(body);
    reader.readSliceAll(body) catch |err| switch (err) {
        error.EndOfStream => return error.UnexpectedEof,
        else => return err,
    };
    return body;
}

/// Write one JSON-RPC frame to a writer.
pub fn writeFrame(writer: *std.Io.Writer, body: []const u8) !void {
    var header_buf: [64]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf, "Content-Length: {d}\r\n\r\n", .{body.len});
    try writer.writeAll(header);
    try writer.writeAll(body);
}

// ---------------------------------------------------------------------------
// JSON-RPC 2.0 envelope helpers.
//
// We don't define a Zig struct for the envelope — different message
// shapes (request vs notification vs reply vs error) make it awkward
// in Zig. Instead we build/parse `std.json.Value` directly and use the
// helpers below to enforce conformance.
// ---------------------------------------------------------------------------

pub const Envelope = struct {
    /// "2.0"
    jsonrpc: []const u8,
    /// Present on requests + replies. Notifications have no id.
    id: ?std.json.Value = null,
    /// Present on requests + notifications.
    method: ?[]const u8 = null,
    /// Present on requests + notifications.
    params: ?std.json.Value = null,
    /// Present on success replies.
    result: ?std.json.Value = null,
    /// Present on error replies.
    err: ?ErrorBody = null,

    pub fn isRequest(self: Envelope) bool {
        return self.method != null and self.id != null;
    }
    pub fn isNotification(self: Envelope) bool {
        return self.method != null and self.id == null;
    }
    pub fn isReply(self: Envelope) bool {
        return self.method == null and self.id != null;
    }

    pub const ErrorBody = struct {
        code: i32,
        message: []const u8,
        data: ?std.json.Value = null,
    };
};

/// Parse a body into a typed `Envelope`. The returned envelope's
/// string/array fields borrow from `parsed.value`'s arena, so the
/// caller must keep `parsed` alive until done.
pub fn parseEnvelope(parsed_value: std.json.Value) !Envelope {
    if (parsed_value != .object) return error.InvalidJson;
    const obj = parsed_value.object;

    var env: Envelope = .{ .jsonrpc = "" };

    if (obj.get("jsonrpc")) |v| {
        if (v != .string) return error.InvalidJson;
        env.jsonrpc = v.string;
    } else return error.InvalidJson;

    if (obj.get("id")) |v| env.id = v;
    if (obj.get("method")) |v| {
        if (v != .string) return error.InvalidJson;
        env.method = v.string;
    }
    if (obj.get("params")) |v| env.params = v;
    if (obj.get("result")) |v| env.result = v;
    if (obj.get("error")) |v| {
        if (v != .object) return error.InvalidJson;
        const ev = v.object;
        const code_v = ev.get("code") orelse return error.InvalidJson;
        const msg_v = ev.get("message") orelse return error.InvalidJson;
        if (code_v != .integer) return error.InvalidJson;
        if (msg_v != .string) return error.InvalidJson;
        env.err = .{
            .code = @intCast(code_v.integer),
            .message = msg_v.string,
            .data = ev.get("data"),
        };
    }

    return env;
}

/// Build a request body. Caller owns the returned slice. `method` is
/// emitted verbatim — callers are responsible for using a method name
/// composed of safe characters (letters, digits, `/`, `.`, `_`,
/// `-`); arbitrary user-supplied input belongs in `params_json`,
/// which the caller assembled via the safe writers below.
pub fn buildRequest(
    allocator: std.mem.Allocator,
    id: u64,
    method: []const u8,
    params_json: []const u8,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try w.print("{d}", .{id});
    try w.writeAll(",\"method\":");
    try writeJsonString(w, method);
    try w.writeAll(",\"params\":");
    try w.writeAll(params_json);
    try w.writeAll("}");
    return aw.toOwnedSlice();
}

pub fn buildNotification(
    allocator: std.mem.Allocator,
    method: []const u8,
    params_json: []const u8,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"method\":");
    try writeJsonString(w, method);
    try w.writeAll(",\"params\":");
    try w.writeAll(params_json);
    try w.writeAll("}");
    return aw.toOwnedSlice();
}

pub fn buildReply(
    allocator: std.mem.Allocator,
    id: u64,
    result_json: []const u8,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":", .{id});
    try w.writeAll(result_json);
    try w.writeAll("}");
    return aw.toOwnedSlice();
}

pub fn buildError(
    allocator: std.mem.Allocator,
    id: u64,
    code: i32,
    message: []const u8,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":{d},\"message\":", .{ id, code });
    try writeJsonString(w, message);
    try w.writeAll("}}");
    return aw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Safe JSON string encoding.
//
// `allocPrint("...\"{s}\"...")` was fine when the only strings we
// shipped were trusted internal identifiers, but plugins now route
// arbitrary user-controlled text (file contents, error messages,
// event payloads). These helpers escape per RFC 8259 section 7 so a
// stray `"` or `\n` doesn't corrupt the envelope.
// ---------------------------------------------------------------------------

/// Write `s` to `w` wrapped in JSON-string delimiters with proper
/// escaping. Suitable for writing values, not bare keys (use
/// `writeJsonStringKey` for keys to get the trailing `:`).
pub fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x08 => try w.writeAll("\\b"),
            0x0c => try w.writeAll("\\f"),
            0...0x07, 0x0b, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

/// Write a JSON object key (escaped string followed by `:`).
pub fn writeJsonStringKey(w: anytype, key: []const u8) !void {
    try writeJsonString(w, key);
    try w.writeByte(':');
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "writeFrame produces Content-Length header" {
    var buf: [256]u8 = undefined;
    var fixed: std.Io.Writer = .fixed(&buf);
    try writeFrame(&fixed, "hello");
    try std.testing.expectEqualStrings("Content-Length: 5\r\n\r\nhello", fixed.buffered());
}

test "readFrame parses what writeFrame writes" {
    const a = std.testing.allocator;
    var out: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    try writeFrame(&w, "{\"x\":1}");
    const wire = w.buffered();

    var r: std.Io.Reader = .fixed(wire);
    const body = try readFrame(a, &r);
    defer a.free(body);
    try std.testing.expectEqualStrings("{\"x\":1}", body);
}

test "readFrame rejects oversized" {
    const a = std.testing.allocator;
    var r: std.Io.Reader = .fixed("Content-Length: 99999999\r\n\r\n");
    try std.testing.expectError(error.InvalidFrame, readFrame(a, &r));
}

test "parseEnvelope: request" {
    const a = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        a,
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"editor/getState\",\"params\":{}}",
        .{},
    );
    defer parsed.deinit();
    const env = try parseEnvelope(parsed.value);
    try std.testing.expect(env.isRequest());
    try std.testing.expectEqualStrings("editor/getState", env.method.?);
}

test "parseEnvelope: notification" {
    const a = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        a,
        "{\"jsonrpc\":\"2.0\",\"method\":\"plugin/log\",\"params\":{\"level\":1,\"message\":\"hi\"}}",
        .{},
    );
    defer parsed.deinit();
    const env = try parseEnvelope(parsed.value);
    try std.testing.expect(env.isNotification());
    try std.testing.expectEqualStrings("plugin/log", env.method.?);
}

test "parseEnvelope: reply" {
    const a = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        a,
        "{\"jsonrpc\":\"2.0\",\"id\":42,\"result\":{\"ok\":true}}",
        .{},
    );
    defer parsed.deinit();
    const env = try parseEnvelope(parsed.value);
    try std.testing.expect(env.isReply());
    try std.testing.expectEqual(@as(i64, 42), env.id.?.integer);
}

test "parseEnvelope: error reply" {
    const a = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        a,
        "{\"jsonrpc\":\"2.0\",\"id\":42,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}",
        .{},
    );
    defer parsed.deinit();
    const env = try parseEnvelope(parsed.value);
    try std.testing.expect(env.isReply());
    try std.testing.expect(env.err != null);
    try std.testing.expectEqual(@as(i32, -32601), env.err.?.code);
}
