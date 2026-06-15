const std = @import("std");
const platform = @import("../../kernel/platform.zig");

pub const default_host_basename = "stem-lsp-host";
pub const env_override_name = "STEM_LSP_HOST";

pub fn hostPathFromExePath(
    allocator: std.mem.Allocator,
    exe_path: []const u8,
    host_basename: []const u8,
) ![]u8 {
    const dir = std.fs.path.dirname(exe_path) orelse ".";
    return try std.fs.path.join(allocator, &.{ dir, host_basename });
}

pub fn hostPathFromCurrentExe(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_block: std.process.Environ.Block,
    preferred_basename: ?[]const u8,
) ![]u8 {
    if (try platform.getEnv(allocator, environ_block, env_override_name)) |override| {
        return override;
    }

    const exe_path = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(exe_path);

    if (preferred_basename) |basename| {
        const candidate = try hostPathFromExePath(allocator, exe_path, basename);
        if (isExecutable(io, candidate)) return candidate;
        allocator.free(candidate);
    }

    return try hostPathFromExePath(allocator, exe_path, default_host_basename);
}

pub fn aliasBasename(allocator: std.mem.Allocator, lang: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "stem-lsp-{s}", .{lang});
}

pub fn externalArgv(
    allocator: std.mem.Allocator,
    host_path: []const u8,
    lang: []const u8,
    server_args: []const []const u8,
) ![]const []const u8 {
    var argv = try allocator.alloc([]const u8, 4 + server_args.len);
    argv[0] = host_path;
    argv[1] = "--lang";
    argv[2] = lang;
    argv[3] = "--";
    @memcpy(argv[4..], server_args);
    return argv;
}

pub fn embeddedZlsArgv(
    allocator: std.mem.Allocator,
    host_path: []const u8,
) ![]const []const u8 {
    var argv = try allocator.alloc([]const u8, 2);
    argv[0] = host_path;
    argv[1] = "--embedded-zls";
    return argv;
}

fn isExecutable(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{ .execute = true }) catch return false;
    return true;
}

test "host path is derived from the running stem binary directory" {
    const actual = try hostPathFromExePath(std.testing.allocator, "/opt/stem/bin/stem", "stem-lsp-host");
    defer std.testing.allocator.free(actual);

    try std.testing.expectEqualStrings("/opt/stem/bin/stem-lsp-host", actual);
}

test "external host argv wraps the real LSP command after separator" {
    const server_args = [_][]const u8{ "node", "/tmp/pyright.js", "--stdio" };
    const argv = try externalArgv(std.testing.allocator, "/opt/stem/bin/stem-lsp-host", "python", &server_args);
    defer std.testing.allocator.free(argv);

    try std.testing.expectEqual(@as(usize, 7), argv.len);
    try std.testing.expectEqualStrings("/opt/stem/bin/stem-lsp-host", argv[0]);
    try std.testing.expectEqualStrings("--lang", argv[1]);
    try std.testing.expectEqualStrings("python", argv[2]);
    try std.testing.expectEqualStrings("--", argv[3]);
    try std.testing.expectEqualStrings("node", argv[4]);
    try std.testing.expectEqualStrings("/tmp/pyright.js", argv[5]);
    try std.testing.expectEqualStrings("--stdio", argv[6]);
}

test "embedded zls host argv advertises the embedded mode" {
    const argv = try embeddedZlsArgv(std.testing.allocator, "/opt/stem/bin/stem-lsp-zig");
    defer std.testing.allocator.free(argv);

    try std.testing.expectEqual(@as(usize, 2), argv.len);
    try std.testing.expectEqualStrings("/opt/stem/bin/stem-lsp-zig", argv[0]);
    try std.testing.expectEqualStrings("--embedded-zls", argv[1]);
}
