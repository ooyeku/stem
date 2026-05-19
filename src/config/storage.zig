const std = @import("std");
const builtin = @import("builtin");
const Config = @import("schema.zig").Config;
const platform = @import("../kernel/platform.zig");

pub const StorageManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    home_dir: []const u8,
    config_dir: []const u8,
    plugins_dir: []const u8,
    logs_dir: []const u8,
    lsp_dir: []const u8,
    sessions_dir: []const u8,
    config_file: []const u8,
    session_file: []const u8,
    config: Config,
    config_arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, environ_block: std.process.Environ.Block) !StorageManager {
        const home = try getHomeDir(allocator, environ_block);

        const config_dir = try std.fs.path.join(allocator, &.{ home, ".stem" });
        const plugins_dir = try std.fs.path.join(allocator, &.{ config_dir, "plugins" });
        const logs_dir = try std.fs.path.join(allocator, &.{ config_dir, "logs" });
        const lsp_dir = try std.fs.path.join(allocator, &.{ config_dir, "lsp" });
        const sessions_dir = try std.fs.path.join(allocator, &.{ config_dir, "sessions" });
        const config_file = try std.fs.path.join(allocator, &.{ config_dir, "config.json" });

        const session_file = try getWorkspaceSessionPath(allocator, io, sessions_dir);

        try ensureDir(io, config_dir);
        try ensureDir(io, plugins_dir);
        try ensureDir(io, logs_dir);
        try ensureDir(io, lsp_dir);
        try ensureDir(io, sessions_dir);

        const file = std.Io.Dir.createFileAbsolute(io, config_file, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => null,
            else => return err,
        };

        if (file) |f| {
            defer f.close(io);

            const default_config = Config{};
            var aw: std.Io.Writer.Allocating = .init(allocator);
            defer aw.deinit();
            try default_config.writeConfig(&aw.writer);
            try f.writePositionalAll(io, aw.written(), 0);
        }

        var config_arena = std.heap.ArenaAllocator.init(allocator);
        const arena = config_arena.allocator();
        var config = Config{};

        if (std.Io.Dir.openFileAbsolute(io, config_file, .{})) |opened_file| {
            defer opened_file.close(io);
            const file_len = opened_file.length(io) catch 0;
            if (file_len > 0 and file_len <= 1024 * 1024) {
                const content = allocator.alloc(u8, @intCast(file_len)) catch null;
                if (content) |buf| {
                    defer allocator.free(buf);
                    const read_n = opened_file.readPositionalAll(io, buf, 0) catch 0;
                    if (read_n == buf.len) {
                        if (std.json.parseFromSlice(Config, arena, buf, .{
                            .ignore_unknown_fields = true,
                            .allocate = .alloc_always,
                        })) |p| {
                            config = p.value;
                        } else |err| {
                            std.debug.print("Failed to parse config: {}\nUsing defaults.\n", .{err});
                        }
                    } else {
                        std.debug.print("Config file short-read ({d}/{d} bytes); using defaults.\n", .{ read_n, buf.len });
                    }
                }
            }
        } else |err| {
            std.debug.print("Failed to open config file: {}\n", .{err});
        }

        return StorageManager{
            .allocator = allocator,
            .io = io,
            .home_dir = home,
            .config_dir = config_dir,
            .plugins_dir = plugins_dir,
            .logs_dir = logs_dir,
            .lsp_dir = lsp_dir,
            .sessions_dir = sessions_dir,
            .config_file = config_file,
            .session_file = session_file,
            .config = config,
            .config_arena = config_arena,
        };
    }

    pub fn save(self: *StorageManager) !void {
        // Atomic write: serialize to a temp file in the same dir, then rename.
        // Avoids both half-written files (if we crash mid-write) and races with
        // a concurrently-reading process.
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp.{d}", .{
            self.config_file,
            platform.getProcessId(),
        });
        defer self.allocator.free(tmp_path);

        {
            const file = try std.Io.Dir.createFileAbsolute(self.io, tmp_path, .{ .truncate = true });
            defer file.close(self.io);

            var aw: std.Io.Writer.Allocating = .init(self.allocator);
            defer aw.deinit();
            try self.config.writeConfig(&aw.writer);
            try file.writePositionalAll(self.io, aw.written(), 0);
        }

        std.Io.Dir.renameAbsolute(tmp_path, self.config_file, self.io) catch |err| {
            std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};
            return err;
        };
    }

    pub fn deinit(self: *StorageManager) void {
        self.config_arena.deinit();
        self.allocator.free(self.home_dir);
        self.allocator.free(self.config_dir);
        self.allocator.free(self.plugins_dir);
        self.allocator.free(self.logs_dir);
        self.allocator.free(self.lsp_dir);
        self.allocator.free(self.sessions_dir);
        self.allocator.free(self.config_file);
        self.allocator.free(self.session_file);
    }

    pub fn getSessionPath(self: *StorageManager) []const u8 {
        return self.session_file;
    }

    /// Crash-recovery snapshot path. Sibling of the workspace's
    /// session file with a `.recover` suffix so a clean shutdown and
    /// an in-progress recovery can coexist without colliding. The
    /// recovery file exists only while stem is running — written
    /// periodically and on every save, cleared on clean quit. Its
    /// presence at startup means the previous run crashed.
    ///
    /// Caller must free the returned slice.
    pub fn getRecoveryPath(self: *StorageManager) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}.recover", .{self.session_file});
    }

    fn ensureDir(io: std.Io, path: []const u8) !void {
        std.Io.Dir.createDirAbsolute(io, path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    fn getHomeDir(allocator: std.mem.Allocator, environ_block: std.process.Environ.Block) ![]const u8 {
        const env: std.process.Environ = .{ .block = environ_block };
        if (env.getPosix("HOME")) |home| {
            return allocator.dupe(u8, home);
        }
        if (builtin.os.tag == .windows) {
            if (env.getPosix("USERPROFILE")) |up| {
                return allocator.dupe(u8, up);
            }
        }
        return error.HomeDirNotFound;
    }

    fn getWorkspaceSessionPath(allocator: std.mem.Allocator, io: std.Io, sessions_dir: []const u8) ![]const u8 {
        const cwd = std.Io.Dir.cwd();
        const cwd_path = cwd.realPathFileAlloc(io, ".", allocator) catch |err| {
            std.debug.print("Warning: Could not get CWD: {}, using default session\n", .{err});
            return std.fs.path.join(allocator, &.{ sessions_dir, "default.json" });
        };
        defer allocator.free(cwd_path);

        var hasher = std.hash.Fnv1a_64.init();
        hasher.update(cwd_path);
        const hash = hasher.final();

        var filename_buf: [32]u8 = undefined;
        const filename = std.fmt.bufPrint(&filename_buf, "{x:0>16}.json", .{hash}) catch "default.json";

        return std.fs.path.join(allocator, &.{ sessions_dir, filename });
    }
};
