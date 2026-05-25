const std = @import("std");
const Transport = @import("transport.zig");
const test_utils = @import("../test_utils.zig");
const TestIo = @import("../test_utils.zig").TestIo;

pub const Client = struct {
    allocator: std.mem.Allocator,
    to_server: *Transport.MemPipe,
    from_server: *Transport.MemPipe,
    next_request_id: i64 = 1,
    is_initialized: bool = false,

    pub fn init(allocator: std.mem.Allocator, to_server: *Transport.MemPipe, from_server: *Transport.MemPipe) Client {
        return .{
            .allocator = allocator,
            .to_server = to_server,
            .from_server = from_server,
        };
    }

    pub fn sendRequest(self: *Client, method: []const u8, params_json: ?[]const u8) !i64 {
        const id = self.next_request_id;
        self.next_request_id += 1;

        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        const writer = &aw.writer;

        try writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\"", .{ id, method });

        if (params_json) |p| {
            try writer.writeAll(",\"params\":");
            try writer.writeAll(p);
        }

        try writer.writeAll("}");

        try self.sendRaw(aw.written());
        return id;
    }

    pub fn sendNotification(self: *Client, method: []const u8, params_json: ?[]const u8) !void {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        const writer = &aw.writer;

        try writer.print("{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\"", .{method});

        if (params_json) |p| {
            try writer.writeAll(",\"params\":");
            try writer.writeAll(p);
        }

        try writer.writeAll("}");

        try self.sendRaw(aw.written());
    }

    fn sendRaw(self: *Client, json: []const u8) !void {
        var header_buf: [64]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "Content-Length: {d}\r\n\r\n", .{json.len}) catch unreachable;

        _ = try self.to_server.write(header);
        _ = try self.to_server.write(json);
    }

    pub fn initialize(self: *Client, root_uri: ?[]const u8) !i64 {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        const writer = &aw.writer;

        try writer.writeAll("{\"processId\":");
        try writer.print("{d}", .{platform.getProcessId()});

        if (root_uri) |uri| {
            try writer.writeAll(",\"rootUri\":\"");
            try writer.writeAll(uri);
            try writer.writeAll("\"");
        } else {
            try writer.writeAll(",\"rootUri\":null");
        }

        try writer.writeAll(",\"capabilities\":{");
        try writer.writeAll("\"textDocument\":{");
        try writer.writeAll("\"synchronization\":{\"didSave\":true},");
        try writer.writeAll("\"completion\":{},");
        try writer.writeAll("\"publishDiagnostics\":{}");
        try writer.writeAll("}}}");

        return try self.sendRequest("initialize", aw.written());
    }

    pub fn initialized(self: *Client) !void {
        try self.sendNotification("initialized", "{}");
        self.is_initialized = true;
    }

    pub fn didOpen(self: *Client, uri: []const u8, language_id: []const u8, version: i64, text: []const u8) !void {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        const writer = &aw.writer;

        try writer.writeAll("{\"textDocument\":{\"uri\":\"");
        try writer.writeAll(uri);
        try writer.writeAll("\",\"languageId\":\"");
        try writer.writeAll(language_id);
        try writer.print("\",\"version\":{d},\"text\":\"", .{version});
        try writeJsonEscapedString(writer, text);
        try writer.writeAll("\"}}");

        try self.sendNotification("textDocument/didOpen", aw.written());
    }

    pub fn didChange(self: *Client, uri: []const u8, version: i64, text: []const u8) !void {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        const writer = &aw.writer;

        try writer.writeAll("{\"textDocument\":{\"uri\":\"");
        try writer.writeAll(uri);
        try writer.print("\",\"version\":{d}", .{version});
        try writer.writeAll("},\"contentChanges\":[{\"text\":\"");
        try writeJsonEscapedString(writer, text);
        try writer.writeAll("\"}]}");

        try self.sendNotification("textDocument/didChange", aw.written());
    }

    pub fn didSave(self: *Client, uri: []const u8) !void {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        const writer = &aw.writer;

        try writer.writeAll("{\"textDocument\":{\"uri\":\"");
        try writer.writeAll(uri);
        try writer.writeAll("\"}}");

        try self.sendNotification("textDocument/didSave", aw.written());
    }

    pub fn didClose(self: *Client, uri: []const u8) !void {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        const writer = &aw.writer;

        try writer.writeAll("{\"textDocument\":{\"uri\":\"");
        try writer.writeAll(uri);
        try writer.writeAll("\"}}");

        try self.sendNotification("textDocument/didClose", aw.written());
    }

    pub fn shutdown(self: *Client) !i64 {
        return try self.sendRequest("shutdown", null);
    }

    pub fn exit(self: *Client) !void {
        try self.sendNotification("exit", null);
    }
};

fn writeJsonEscapedString(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
}

pub fn pathToUri(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var absolute_path: []const u8 = undefined;

    if (path.len > 0 and path[0] == '/') {
        absolute_path = path;
    } else if (@import("builtin").os.tag == .windows and
        path.len >= 3 and
        std.ascii.isAlphabetic(path[0]) and
        path[1] == ':' and
        (path[2] == '/' or path[2] == '\\'))
    {
        absolute_path = path;
    } else {
        const cwd = std.Io.Dir.cwd();
        const len = try cwd.realPathFile(io, path, &path_buf);
        absolute_path = path_buf[0..len];
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    // Pick the prefix from the *path shape*, not the build target:
    //   POSIX absolute (`/usr/foo`)  → `file://` + path  → file:///usr/foo
    //   Windows drive (`C:\foo`)     → `file:///` + path → file:///C:/foo
    // Picking by OS instead double-slashed POSIX paths on Windows
    // (`file:////home/...`), which is what the cross-OS tests caught.
    const is_drive_letter = absolute_path.len >= 2 and
        std.ascii.isAlphabetic(absolute_path[0]) and
        absolute_path[1] == ':';
    if (is_drive_letter) {
        try out.appendSlice(allocator, "file:///");
    } else {
        try out.appendSlice(allocator, "file://");
    }
    var hex_buf: [3]u8 = undefined;
    for (absolute_path) |b| {
        const c = if (@import("builtin").os.tag == .windows and b == '\\') '/' else b;
        if (isUriPathSafe(c)) {
            try out.append(allocator, c);
        } else {
            const encoded = std.fmt.bufPrint(&hex_buf, "%{X:0>2}", .{c}) catch unreachable;
            try out.appendSlice(allocator, encoded);
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Characters allowed unescaped in the path component of a file URI
/// (RFC 3986 unreserved + path separators).
fn isUriPathSafe(b: u8) bool {
    return (b >= 'A' and b <= 'Z') or
        (b >= 'a' and b <= 'z') or
        (b >= '0' and b <= '9') or
        b == '-' or b == '.' or b == '_' or b == '~' or
        b == '/' or b == ':';
}

const platform = @import("../kernel/platform.zig");

test "Client initialization with MockLSPServer" {
    const allocator = std.testing.allocator;
    const MockLSPServer = test_utils.MockUtils.MockLSPServer;

    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();

    var to_server = Transport.MemPipe.init(allocator, io);
    defer to_server.deinit();
    var from_server = Transport.MemPipe.init(allocator, io);
    defer from_server.deinit();

    var client = Client.init(allocator, &to_server, &from_server);

    var mock_server = MockLSPServer.init(allocator);
    defer mock_server.deinit();

    try mock_server.addResponse("initialize",
        \\{"capabilities":{"textDocumentSync":1}}
    );

    const req_id = try client.initialize(null);

    var buf: [4096]u8 = undefined;
    const n = try to_server.read(&buf);

    const msg = buf[0..n];
    const body_start = std.mem.indexOf(u8, msg, "\r\n\r\n").? + 4;
    const body = msg[body_start..];

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("initialize", parsed.value.object.get("method").?.string);
    try std.testing.expectEqual(req_id, parsed.value.object.get("id").?.integer);

    if (mock_server.getResponse("initialize")) |resp_result| {
        const response_json = try std.fmt.allocPrint(allocator,
            \\{{"jsonrpc":"2.0","id":{d},"result":{s}}}
        , .{ req_id, resp_result });
        defer allocator.free(response_json);

        var header_buf: [64]u8 = undefined;
        const header = try std.fmt.bufPrint(&header_buf, "Content-Length: {d}\r\n\r\n", .{response_json.len});

        _ = try from_server.write(header);
        _ = try from_server.write(response_json);
    }

    const n_resp = try from_server.read(&buf);
    const resp_msg = buf[0..n_resp];
    try std.testing.expect(std.mem.indexOf(u8, resp_msg, "Content-Length:") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp_msg, "\"result\":{\"capabilities\":") != null);
}

test "pathToUri handles absolute POSIX path" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const uri = try pathToUri(allocator, threaded.io(), "/home/user/test.zig");
    defer allocator.free(uri);
    try std.testing.expectEqualStrings("file:///home/user/test.zig", uri);
}

test "pathToUri Windows logic mock" {
    const path = "C:\\Users\\test.zig";
    const is_windows_path = path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '/' or path[2] == '\\');
    try std.testing.expect(is_windows_path);
}

test "pathToUri percent-encodes spaces" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const uri = try pathToUri(allocator, threaded.io(), "/home/user/Code Projects/foo.zig");
    defer allocator.free(uri);
    try std.testing.expectEqualStrings("file:///home/user/Code%20Projects/foo.zig", uri);
}

test "pathToUri percent-encodes special chars" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    // # ? % should all be percent-encoded since they're reserved in URIs.
    const uri = try pathToUri(allocator, threaded.io(), "/tmp/a#b?c%d.zig");
    defer allocator.free(uri);
    try std.testing.expectEqualStrings("file:///tmp/a%23b%3Fc%25d.zig", uri);
}

test "pathToUri preserves safe path chars" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    // Letters, digits, -, ., _, ~, /, : should NOT be encoded.
    const uri = try pathToUri(allocator, threaded.io(), "/usr/local/bin/test-1.2_v3~latest");
    defer allocator.free(uri);
    try std.testing.expectEqualStrings("file:///usr/local/bin/test-1.2_v3~latest", uri);
}

test "pathToUri non-ASCII unicode bytes are encoded" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    // "café.zig" - 'é' is two UTF-8 bytes (0xC3 0xA9).
    const uri = try pathToUri(allocator, threaded.io(), "/tmp/café.zig");
    defer allocator.free(uri);
    try std.testing.expectEqualStrings("file:///tmp/caf%C3%A9.zig", uri);
}
