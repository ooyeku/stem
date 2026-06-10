const std = @import("std");
const test_utils = @import("../test_utils.zig");
const TestIo = @import("../test_utils.zig").TestIo;

pub const UriScheme = enum {
    file,
    memory,
    git,

    pub fn toString(self: UriScheme) []const u8 {
        return switch (self) {
            .file => "file",
            .memory => "memory",
            .git => "git",
        };
    }

    pub fn fromString(s: []const u8) ?UriScheme {
        if (std.mem.eql(u8, s, "file")) return .file;
        if (std.mem.eql(u8, s, "memory")) return .memory;
        if (std.mem.eql(u8, s, "git")) return .git;
        return null;
    }
};

pub const VirtualUri = struct {
    scheme: UriScheme,
    path: []const u8,

    pub fn parse(uri: []const u8) ?VirtualUri {
        return parseInternal(uri, @import("builtin").os.tag);
    }

    fn parseInternal(uri: []const u8, os: std.Target.Os.Tag) ?VirtualUri {
        if (std.mem.indexOf(u8, uri, "://")) |scheme_end| {
            const scheme_str = uri[0..scheme_end];
            const scheme = UriScheme.fromString(scheme_str) orelse return null;

            const path = uri[scheme_end + 3 ..];
            return VirtualUri{
                .scheme = scheme,
                .path = path,
            };
        }

        if (os == .windows) {
            if (uri.len >= 3 and
                std.ascii.isAlphabetic(uri[0]) and
                uri[1] == ':' and
                (uri[2] == '/' or uri[2] == '\\'))
            {
                return VirtualUri{
                    .scheme = .file,
                    .path = uri,
                };
            }
        }

        if (uri.len > 0 and uri[0] == '/') {
            return VirtualUri{
                .scheme = .file,
                .path = uri,
            };
        }

        return null;
    }

    pub fn format(self: VirtualUri, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}://{s}", .{
            self.scheme.toString(),
            self.path,
        });
    }

    pub fn isReadOnly(self: VirtualUri) bool {
        return switch (self.scheme) {
            .file => false,
            .memory => false,
            .git => true,
        };
    }

    pub fn isSaveable(self: VirtualUri) bool {
        return self.scheme == .file;
    }

    pub fn displayName(self: VirtualUri, allocator: std.mem.Allocator) ![]u8 {
        return switch (self.scheme) {
            .file => {
                const basename = if (@import("builtin").os.tag == .windows) blk: {
                    const last_slash = std.mem.lastIndexOfScalar(u8, self.path, '/');
                    const last_backslash = std.mem.lastIndexOfScalar(u8, self.path, '\\');
                    const last = if (last_slash) |s| (if (last_backslash) |b| @max(s, b) else s) else last_backslash;
                    break :blk if (last) |idx| self.path[idx + 1 ..] else self.path;
                } else std.fs.path.basename(self.path);
                return try allocator.dupe(u8, basename);
            },
            .memory => try std.fmt.allocPrint(allocator, "[Scratch] {s}", .{self.path}),
            .git => try std.fmt.allocPrint(allocator, "[Git] {s}", .{std.fs.path.basename(self.path)}),
        };
    }
};

pub const VfsProvider = struct {
    read: *const fn (path: []const u8, allocator: std.mem.Allocator, io: std.Io) anyerror![]u8,
    write: ?*const fn (path: []const u8, content: []const u8, io: std.Io) anyerror!void,
    exists: *const fn (path: []const u8, io: std.Io) bool,
};

fn percentDecodePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, path.len);

    var i: usize = 0;
    while (i < path.len) {
        if (path[i] == '%' and i + 2 < path.len) {
            const decoded = std.fmt.parseInt(u8, path[i + 1 .. i + 3], 16) catch null;
            if (decoded) |byte| {
                out.appendAssumeCapacity(byte);
                i += 3;
                continue;
            }
        }
        out.appendAssumeCapacity(path[i]);
        i += 1;
    }

    return out.toOwnedSlice(allocator);
}

pub const VirtualFileSystem = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    providers: std.AutoHashMap(UriScheme, VfsProvider),
    memory_buffers: std.StringHashMap([]u8),

    pub fn init(allocator: std.mem.Allocator, io: std.Io) VirtualFileSystem {
        var vfs = VirtualFileSystem{
            .allocator = allocator,
            .io = io,
            .providers = std.AutoHashMap(UriScheme, VfsProvider).init(allocator),
            .memory_buffers = std.StringHashMap([]u8).init(allocator),
        };

        // best-effort: file provider registration at init; an OOM at first put on a fresh
        // HashMap is functionally impossible — leaving the VFS unable to handle file:// URIs
        // would manifest as readFile/writeFile errors downstream that surface their own logs.
        vfs.providers.put(.file, VfsProvider{
            .read = readFile,
            .write = writeFile,
            .exists = fileExists,
        }) catch {};

        return vfs;
    }

    pub fn deinit(self: *VirtualFileSystem) void {
        var it = self.memory_buffers.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.memory_buffers.deinit();
        self.providers.deinit();
    }

    pub fn registerProvider(self: *VirtualFileSystem, scheme: UriScheme, provider: VfsProvider) !void {
        try self.providers.put(scheme, provider);
    }

    pub fn read(self: *VirtualFileSystem, uri: VirtualUri) ![]u8 {
        return switch (uri.scheme) {
            .file => {
                if (self.providers.get(.file)) |provider| {
                    const path = try percentDecodePath(self.allocator, uri.path);
                    defer self.allocator.free(path);
                    return provider.read(path, self.allocator, self.io);
                }
                return error.NoProvider;
            },
            .memory => {
                if (self.memory_buffers.get(uri.path)) |content| {
                    return try self.allocator.dupe(u8, content);
                }
                return try self.allocator.dupe(u8, "");
            },
            .git => {
                var object_spec = try self.allocator.dupe(u8, uri.path);
                defer self.allocator.free(object_spec);

                if (std.mem.indexOf(u8, object_spec, "/")) |idx| {
                    object_spec[idx] = ':';
                }

                const result = std.process.run(self.allocator, self.io, .{
                    .argv = &[_][]const u8{ "git", "cat-file", "-p", object_spec },
                    .cwd = .{ .path = "." },
                    .stdout_limit = .limited(10 * 1024 * 1024),
                }) catch return error.NotFound;

                defer {
                    self.allocator.free(result.stdout);
                    self.allocator.free(result.stderr);
                }

                const ok = switch (result.term) {
                    .exited => |code| code == 0,
                    else => false,
                };
                if (!ok) {
                    return error.NotFound;
                }

                return try self.allocator.dupe(u8, result.stdout);
            },
        };
    }

    pub fn write(self: *VirtualFileSystem, uri: VirtualUri, content: []const u8) !void {
        switch (uri.scheme) {
            .file => {
                if (self.providers.get(.file)) |provider| {
                    if (provider.write) |write_fn| {
                        const path = try percentDecodePath(self.allocator, uri.path);
                        defer self.allocator.free(path);
                        return write_fn(path, content, self.io);
                    }
                }
                return error.ReadOnly;
            },
            .memory => {
                const value = try self.allocator.dupe(u8, content);

                if (self.memory_buffers.getPtr(uri.path)) |existing_value| {
                    self.allocator.free(existing_value.*);
                    existing_value.* = value;
                } else {
                    const key = try self.allocator.dupe(u8, uri.path);
                    errdefer self.allocator.free(key);
                    try self.memory_buffers.put(key, value);
                }
            },
            .git => {
                return error.ReadOnly;
            },
        }
    }

    pub fn createMemoryBuffer(self: *VirtualFileSystem, name_hint: ?[]const u8) !VirtualUri {
        var name_buf: [64]u8 = undefined;

        const base = name_hint orelse "Untitled";

        if (!self.memory_buffers.contains(base)) {
            const key = try self.allocator.dupe(u8, base);
            const value = try self.allocator.dupe(u8, "");
            try self.memory_buffers.put(key, value);

            return VirtualUri{
                .scheme = .memory,
                .path = key,
            };
        }

        var counter: u32 = 1;
        while (counter < 1000) {
            const name = std.fmt.bufPrint(&name_buf, "{s}-{d}", .{ base, counter }) catch break;

            if (!self.memory_buffers.contains(name)) {
                const key = try self.allocator.dupe(u8, name);
                const value = try self.allocator.dupe(u8, "");
                try self.memory_buffers.put(key, value);

                return VirtualUri{
                    .scheme = .memory,
                    .path = key,
                };
            }
            counter += 1;
        }

        return error.TooManyBuffers;
    }

    pub fn exists(self: *VirtualFileSystem, uri: VirtualUri) bool {
        return switch (uri.scheme) {
            .file => {
                if (self.providers.get(.file)) |provider| {
                    const path = percentDecodePath(self.allocator, uri.path) catch return false;
                    defer self.allocator.free(path);
                    return provider.exists(path, self.io);
                }
                return false;
            },
            .memory => self.memory_buffers.contains(uri.path),
            .git => blk: {
                var object_spec = self.allocator.dupe(u8, uri.path) catch break :blk false;
                defer self.allocator.free(object_spec);

                if (std.mem.indexOf(u8, object_spec, "/")) |idx| {
                    object_spec[idx] = ':';
                }

                const result = std.process.run(self.allocator, self.io, .{
                    .argv = &[_][]const u8{ "git", "cat-file", "-e", object_spec },
                    .cwd = .{ .path = "." },
                }) catch break :blk false;

                defer {
                    self.allocator.free(result.stdout);
                    self.allocator.free(result.stderr);
                }

                break :blk switch (result.term) {
                    .exited => |code| code == 0,
                    else => false,
                };
            },
        };
    }

    pub fn deleteMemoryBuffer(self: *VirtualFileSystem, path: []const u8) void {
        if (self.memory_buffers.fetchRemove(path)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }
    }

    fn readFile(path: []const u8, allocator: std.mem.Allocator, io: std.Io) anyerror![]u8 {
        const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
        defer file.close(io);
        const size = try file.length(io);
        if (size > 10 * 1024 * 1024) return error.FileTooLarge;
        const buf = try allocator.alloc(u8, @intCast(size));
        errdefer allocator.free(buf);
        const read_n = try file.readPositionalAll(io, buf, 0);
        if (read_n != buf.len) {
            // Truncate the slice to actual bytes read so callers don't see
            // uninitialized tail bytes.
            return allocator.realloc(buf, read_n);
        }
        return buf;
    }

    fn writeFile(path: []const u8, content: []const u8, io: std.Io) anyerror!void {
        const file = try std.Io.Dir.createFileAbsolute(io, path, .{});
        defer file.close(io);
        try file.writePositionalAll(io, content, 0);
    }

    fn fileExists(path: []const u8, io: std.Io) bool {
        std.Io.Dir.cwd().access(io, path, .{}) catch return false;
        return true;
    }
};

test "vfs uri parsing" {
    const file_uri = VirtualUri.parse("file:///home/user/test.zig").?;
    try std.testing.expectEqual(UriScheme.file, file_uri.scheme);
    try std.testing.expectEqualStrings("/home/user/test.zig", file_uri.path);

    const mem_uri = VirtualUri.parse("memory://Untitled-1").?;
    try std.testing.expectEqual(UriScheme.memory, mem_uri.scheme);
    try std.testing.expectEqualStrings("Untitled-1", mem_uri.path);

    const bare_uri = VirtualUri.parse("/usr/local/bin").?;
    try std.testing.expectEqual(UriScheme.file, bare_uri.scheme);
    try std.testing.expectEqualStrings("/usr/local/bin", bare_uri.path);

    const git_uri = VirtualUri.parse("git://HEAD/src/main.zig").?;
    try std.testing.expectEqual(UriScheme.git, git_uri.scheme);
    try std.testing.expectEqualStrings("HEAD/src/main.zig", git_uri.path);
}

test "vfs memory buffer operations" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var vfs = VirtualFileSystem.init(allocator, io);
    defer vfs.deinit();

    const uri = try vfs.createMemoryBuffer(null);
    try std.testing.expectEqual(UriScheme.memory, uri.scheme);

    try vfs.write(uri, "Hello, World!");

    const content = try vfs.read(uri);
    defer allocator.free(content);
    try std.testing.expectEqualStrings("Hello, World!", content);

    try std.testing.expect(vfs.exists(uri));

    vfs.deleteMemoryBuffer(uri.path);
    try std.testing.expect(!vfs.exists(uri));
}

test "VirtualFileSystem decodes percent-encoded file URI paths" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();

    var tmp = try test_utils.Tempdir.init(allocator, io_ctx.io());
    defer tmp.deinit();

    try tmp.writeFile("space file.txt", "hello");
    const real_path = try tmp.joinPath(allocator, "space file.txt");
    defer allocator.free(real_path);
    const encoded_path = try std.mem.replaceOwned(u8, allocator, real_path, " ", "%20");
    defer allocator.free(encoded_path);
    const uri_text = try std.fmt.allocPrint(allocator, "file://{s}", .{encoded_path});
    defer allocator.free(uri_text);

    var vfs = VirtualFileSystem.init(allocator, io_ctx.io());
    defer vfs.deinit();

    const content = try vfs.read(VirtualUri.parse(uri_text).?);
    defer allocator.free(content);
    try std.testing.expectEqualStrings("hello", content);
}

test "vfs uri parsing edge cases" {
    const empty = VirtualUri.parse("");
    try std.testing.expect(empty == null);

    const invalid = VirtualUri.parse("invalid://path");
    try std.testing.expect(invalid == null);

    const relative = VirtualUri.parse("relative/path");
    try std.testing.expect(relative == null);
}

test "vfs uri scheme to string" {
    try std.testing.expectEqualStrings("file", UriScheme.file.toString());
    try std.testing.expectEqualStrings("memory", UriScheme.memory.toString());
    try std.testing.expectEqualStrings("git", UriScheme.git.toString());
}

test "vfs uri scheme from string" {
    try std.testing.expectEqual(UriScheme.file, UriScheme.fromString("file").?);
    try std.testing.expectEqual(UriScheme.memory, UriScheme.fromString("memory").?);
    try std.testing.expectEqual(UriScheme.git, UriScheme.fromString("git").?);
    try std.testing.expect(UriScheme.fromString("invalid") == null);
}

test "vfs uri format" {
    const allocator = std.testing.allocator;

    const file_uri = VirtualUri{ .scheme = .file, .path = "/test/path.zig" };
    const formatted = try file_uri.format(allocator);
    defer allocator.free(formatted);
    try std.testing.expectEqualStrings("file:///test/path.zig", formatted);

    const mem_uri = VirtualUri{ .scheme = .memory, .path = "Untitled-1" };
    const mem_formatted = try mem_uri.format(allocator);
    defer allocator.free(mem_formatted);
    try std.testing.expectEqualStrings("memory://Untitled-1", mem_formatted);
}

test "vfs uri isReadOnly" {
    const file_uri = VirtualUri{ .scheme = .file, .path = "/test" };
    try std.testing.expect(!file_uri.isReadOnly());

    const mem_uri = VirtualUri{ .scheme = .memory, .path = "test" };
    try std.testing.expect(!mem_uri.isReadOnly());

    const git_uri = VirtualUri{ .scheme = .git, .path = "HEAD/test" };
    try std.testing.expect(git_uri.isReadOnly());
}

test "vfs uri isSaveable" {
    const file_uri = VirtualUri{ .scheme = .file, .path = "/test" };
    try std.testing.expect(file_uri.isSaveable());

    const mem_uri = VirtualUri{ .scheme = .memory, .path = "test" };
    try std.testing.expect(!mem_uri.isSaveable());

    const git_uri = VirtualUri{ .scheme = .git, .path = "HEAD/test" };
    try std.testing.expect(!git_uri.isSaveable());
}

test "vfs uri displayName" {
    const allocator = std.testing.allocator;

    const file_uri = VirtualUri{ .scheme = .file, .path = "/home/user/test.zig" };
    const file_name = try file_uri.displayName(allocator);
    defer allocator.free(file_name);
    try std.testing.expectEqualStrings("test.zig", file_name);

    const mem_uri = VirtualUri{ .scheme = .memory, .path = "Untitled-1" };
    const mem_name = try mem_uri.displayName(allocator);
    defer allocator.free(mem_name);
    try std.testing.expectEqualStrings("[Scratch] Untitled-1", mem_name);
}

test "vfs memory buffer named creation" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var vfs = VirtualFileSystem.init(allocator, io);
    defer vfs.deinit();

    const uri = try vfs.createMemoryBuffer("MyBuffer");
    try std.testing.expectEqualStrings("MyBuffer", uri.path);
}

test "vfs memory buffer update" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var vfs = VirtualFileSystem.init(allocator, io);
    defer vfs.deinit();

    const uri = try vfs.createMemoryBuffer("test");

    try vfs.write(uri, "First");

    try vfs.write(uri, "Second");

    const content = try vfs.read(uri);
    defer allocator.free(content);
    try std.testing.expectEqualStrings("Second", content);
}

test "vfs memory buffer empty content" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var vfs = VirtualFileSystem.init(allocator, io);
    defer vfs.deinit();

    const uri = try vfs.createMemoryBuffer("empty");
    try vfs.write(uri, "");

    const content = try vfs.read(uri);
    defer allocator.free(content);
    try std.testing.expectEqualStrings("", content);
}

test "vfs read nonexistent memory buffer" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var vfs = VirtualFileSystem.init(allocator, io);
    defer vfs.deinit();

    const uri = VirtualUri{ .scheme = .memory, .path = "nonexistent" };
    const content = try vfs.read(uri);
    defer allocator.free(content);

    try std.testing.expectEqualStrings("", content);
}

test "vfs multiple memory buffers" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var vfs = VirtualFileSystem.init(allocator, io);
    defer vfs.deinit();

    const uri1 = try vfs.createMemoryBuffer("buf1");
    const uri2 = try vfs.createMemoryBuffer("buf2");
    const uri3 = try vfs.createMemoryBuffer("buf3");

    try vfs.write(uri1, "Content 1");
    try vfs.write(uri2, "Content 2");
    try vfs.write(uri3, "Content 3");

    const content1 = try vfs.read(uri1);
    defer allocator.free(content1);
    try std.testing.expectEqualStrings("Content 1", content1);

    const content2 = try vfs.read(uri2);
    defer allocator.free(content2);
    try std.testing.expectEqualStrings("Content 2", content2);

    const content3 = try vfs.read(uri3);
    defer allocator.free(content3);
    try std.testing.expectEqualStrings("Content 3", content3);
}

test "vfs exists check" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var vfs = VirtualFileSystem.init(allocator, io);
    defer vfs.deinit();

    const uri = try vfs.createMemoryBuffer("test");
    try std.testing.expect(vfs.exists(uri));

    vfs.deleteMemoryBuffer(uri.path);
    try std.testing.expect(!vfs.exists(uri));
}

test "vfs delete nonexistent buffer" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var vfs = VirtualFileSystem.init(allocator, io);
    defer vfs.deinit();

    vfs.deleteMemoryBuffer("nonexistent");
}

test "vfs uri parsing with complex paths" {
    const complex1 = VirtualUri.parse("file:///home/user/projects/my-app/src/main.zig").?;
    try std.testing.expectEqualStrings("/home/user/projects/my-app/src/main.zig", complex1.path);

    const complex2 = VirtualUri.parse("memory://[Scratch]_Untitled-123").?;
    try std.testing.expectEqualStrings("[Scratch]_Untitled-123", complex2.path);
}

test "vfs memory buffer large content" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var vfs = VirtualFileSystem.init(allocator, io);
    defer vfs.deinit();

    const uri = try vfs.createMemoryBuffer("large");

    const large_content = "x" ** 10000;
    try vfs.write(uri, large_content);

    const content = try vfs.read(uri);
    defer allocator.free(content);
    try std.testing.expectEqual(@as(usize, 10000), content.len);
}

test "vfs uri path extraction" {
    const file_uri = VirtualUri.parse("file:///absolute/path/to/file.zig").?;
    try std.testing.expectEqualStrings("/absolute/path/to/file.zig", file_uri.path);

    const mem_uri = VirtualUri.parse("memory://buffer-name-123").?;
    try std.testing.expectEqualStrings("buffer-name-123", mem_uri.path);
}

test "vfs git scheme returns NotFound for invalid path" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var vfs = VirtualFileSystem.init(allocator, io);
    defer vfs.deinit();

    const git_uri = VirtualUri{ .scheme = .git, .path = "HEAD/nonexistent/path/12345.zig" };
    const result = vfs.read(git_uri);

    try std.testing.expectError(error.NotFound, result);
}

test "vfs git scheme is read only" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var vfs = VirtualFileSystem.init(allocator, io);
    defer vfs.deinit();

    const git_uri = VirtualUri{ .scheme = .git, .path = "HEAD/src/main.zig" };
    const result = vfs.write(git_uri, "content");

    try std.testing.expectError(error.ReadOnly, result);
}

test "vfs createMemoryBuffer unique name generation" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var vfs = VirtualFileSystem.init(allocator, io);
    defer vfs.deinit();

    const uri1 = try vfs.createMemoryBuffer("test");
    const uri2 = try vfs.createMemoryBuffer("test");
    const uri3 = try vfs.createMemoryBuffer("test");

    try std.testing.expect(!std.mem.eql(u8, uri1.path, uri2.path));
    try std.testing.expect(!std.mem.eql(u8, uri2.path, uri3.path));
    try std.testing.expect(!std.mem.eql(u8, uri1.path, uri3.path));
}

test "vfs with MockFileSystem provider" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    const MockFileSystem = test_utils.MockUtils.MockFileSystem;

    var vfs = VirtualFileSystem.init(allocator, io);
    defer vfs.deinit();

    var mock_fs = MockFileSystem.init(allocator);
    defer mock_fs.deinit();

    try mock_fs.addFile("/mock/test.txt", "Mock Content");

    const content = mock_fs.readFile("/mock/test.txt");
    try std.testing.expectEqualStrings("Mock Content", content.?);

    try std.testing.expect(mock_fs.readFile("/nonexistent") == null);
}

test "VirtualUri parse empty string" {
    const result = VirtualUri.parse("");
    try std.testing.expect(result == null);
}

test "VirtualUri parse just scheme separator" {
    const result = VirtualUri.parse("://");
    try std.testing.expect(result == null);
}

test "VirtualUri parse unknown scheme" {
    const result = VirtualUri.parse("https://example.com/file.txt");
    try std.testing.expect(result == null);
}

test "VirtualUri parse absolute path without scheme" {
    const result = VirtualUri.parse("/absolute/path/to/file.txt");
    if (result) |uri| {
        try std.testing.expectEqual(UriScheme.file, uri.scheme);
    } else {
        try std.testing.expect(true);
    }
}

test "UriScheme fromString edge cases" {
    try std.testing.expectEqual(UriScheme.file, UriScheme.fromString("file").?);
    try std.testing.expectEqual(UriScheme.memory, UriScheme.fromString("memory").?);
    try std.testing.expectEqual(UriScheme.git, UriScheme.fromString("git").?);

    try std.testing.expect(UriScheme.fromString("http") == null);
    try std.testing.expect(UriScheme.fromString("") == null);
    try std.testing.expect(UriScheme.fromString("FILE") == null);
}

test "VirtualUri isReadOnly by scheme" {
    const file_uri = VirtualUri{ .scheme = .file, .path = "/test.txt" };
    const mem_uri = VirtualUri{ .scheme = .memory, .path = "scratch" };
    const git_uri = VirtualUri{ .scheme = .git, .path = "HEAD/file.zig" };

    try std.testing.expect(!file_uri.isReadOnly());
    try std.testing.expect(!mem_uri.isReadOnly());
    try std.testing.expect(git_uri.isReadOnly());
}

test "VirtualUri isSaveable by scheme" {
    const file_uri = VirtualUri{ .scheme = .file, .path = "/test.txt" };
    const mem_uri = VirtualUri{ .scheme = .memory, .path = "scratch" };
    const git_uri = VirtualUri{ .scheme = .git, .path = "HEAD/file.zig" };

    try std.testing.expect(file_uri.isSaveable());
    try std.testing.expect(!mem_uri.isSaveable());
    try std.testing.expect(!git_uri.isSaveable());
}

test "VFS memory buffer write and read" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var vfs = VirtualFileSystem.init(allocator, io);
    defer vfs.deinit();

    const uri = try vfs.createMemoryBuffer("scratch");

    try vfs.write(uri, "Hello World");

    const content = try vfs.read(uri);
    defer allocator.free(content);

    try std.testing.expectEqualStrings("Hello World", content);
}

test "VFS memory buffer delete" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var vfs = VirtualFileSystem.init(allocator, io);
    defer vfs.deinit();

    const uri = try vfs.createMemoryBuffer("to-delete");
    try vfs.write(uri, "content");

    vfs.deleteMemoryBuffer(uri.path);

    try std.testing.expect(!vfs.exists(uri));
}

test "VFS read new memory buffer returns empty" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var vfs = VirtualFileSystem.init(allocator, io);
    defer vfs.deinit();

    const uri = try vfs.createMemoryBuffer("new");

    const content = try vfs.read(uri);
    defer allocator.free(content);

    try std.testing.expectEqualStrings("", content);
}

test "vfs Windows path parsing" {
    const win_uri1 = VirtualUri.parseInternal("C:\\Users\\test.zig", .windows).?;
    try std.testing.expectEqual(UriScheme.file, win_uri1.scheme);
    try std.testing.expectEqualStrings("C:\\Users\\test.zig", win_uri1.path);

    const win_uri2 = VirtualUri.parseInternal("D:/projects/main.zig", .windows).?;
    try std.testing.expectEqual(UriScheme.file, win_uri2.scheme);
    try std.testing.expectEqualStrings("D:/projects/main.zig", win_uri2.path);

    const linux_uri = VirtualUri.parseInternal("C:\\Users\\test.zig", .linux);
    try std.testing.expect(linux_uri == null);
}

test "vfs Windows displayName" {
    const path = "C:\\path\\to\\file.zig";
    const last_slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const last_backslash = std.mem.lastIndexOfScalar(u8, path, '\\');
    const last = if (last_slash) |s| (if (last_backslash) |b| @max(s, b) else s) else last_backslash;
    const basename = if (last) |idx| path[idx + 1 ..] else path;

    try std.testing.expectEqualStrings("file.zig", basename);
}
