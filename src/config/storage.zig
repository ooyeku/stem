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
    workspace_root: []const u8,
    session_file: []const u8,
    instance_lock_file: []const u8,
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

        const workspace_root = try getWorkspaceRootForInitialPaths(allocator, io, &.{});
        const session_file = try getWorkspaceSessionPathForRoot(allocator, sessions_dir, workspace_root);
        const instance_lock_file = try std.fmt.allocPrint(allocator, "{s}.lock", .{session_file});

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
            .workspace_root = workspace_root,
            .session_file = session_file,
            .instance_lock_file = instance_lock_file,
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
        self.allocator.free(self.workspace_root);
        self.allocator.free(self.session_file);
        self.allocator.free(self.instance_lock_file);
    }

    pub fn getSessionPath(self: *StorageManager) []const u8 {
        return self.session_file;
    }

    pub fn getInstanceLockPath(self: *StorageManager) []const u8 {
        return self.instance_lock_file;
    }

    pub fn getWorkspaceRoot(self: *StorageManager) []const u8 {
        return self.workspace_root;
    }

    pub fn setEditorWorkspaceFromInitialPaths(self: *StorageManager, initial_paths: []const []const u8) !void {
        const workspace_root = try getWorkspaceRootForInitialPaths(self.allocator, self.io, initial_paths);
        errdefer self.allocator.free(workspace_root);

        const session_file = try getWorkspaceSessionPathForRoot(self.allocator, self.sessions_dir, workspace_root);
        errdefer self.allocator.free(session_file);

        const instance_lock_file = try std.fmt.allocPrint(self.allocator, "{s}.lock", .{session_file});
        errdefer self.allocator.free(instance_lock_file);

        self.allocator.free(self.workspace_root);
        self.allocator.free(self.session_file);
        self.allocator.free(self.instance_lock_file);

        self.workspace_root = workspace_root;
        self.session_file = session_file;
        self.instance_lock_file = instance_lock_file;
    }

    pub fn acquireWorkspaceLock(self: *StorageManager) !WorkspaceInstanceLock {
        return WorkspaceInstanceLock.acquire(self.allocator, self.io, self.instance_lock_file, self.workspace_root);
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
        // Use the cross-platform helper so Windows hits
        // GetEnvironmentVariableW instead of the broken
        // `getPosix → GlobalBlock.view()` path.
        if (try platform.getEnv(allocator, environ_block, "HOME")) |home| {
            return home;
        }
        if (builtin.os.tag == .windows) {
            if (try platform.getEnv(allocator, environ_block, "USERPROFILE")) |up| {
                return up;
            }
        }
        return error.HomeDirNotFound;
    }

    fn getWorkspaceRootForInitialPaths(
        allocator: std.mem.Allocator,
        io: std.Io,
        initial_paths: []const []const u8,
    ) ![]u8 {
        if (initial_paths.len == 0) {
            return getCwdWorkspaceRoot(allocator, io);
        }
        return getWorkspaceRootForPath(allocator, io, initial_paths[0]);
    }

    fn getCwdWorkspaceRoot(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
        const cwd = std.Io.Dir.cwd();
        const cwd_path = realPathInDirAllocPlain(allocator, io, cwd, ".") catch |err| {
            std.debug.print("Warning: Could not get CWD: {}, using default session\n", .{err});
            return allocator.dupe(u8, "unknown");
        };
        return cwd_path;
    }

    fn getWorkspaceRootForPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
        const canonical = canonicalizePath(allocator, io, path) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => try allocator.dupe(u8, path),
        };
        errdefer allocator.free(canonical);

        if (isDirectory(io, canonical)) {
            return canonical;
        }

        const parent = std.fs.path.dirname(canonical) orelse canonical;
        const root = try allocator.dupe(u8, parent);
        allocator.free(canonical);
        return root;
    }

    fn canonicalizePath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
        if (std.fs.path.isAbsolute(path)) {
            return realPathAbsoluteAllocPlain(allocator, io, path) catch |err| switch (err) {
                error.FileNotFound => try std.fs.path.resolve(allocator, &.{path}),
                else => err,
            };
        }

        const cwd_path = try getCwdWorkspaceRoot(allocator, io);
        defer allocator.free(cwd_path);
        const resolved = try std.fs.path.resolve(allocator, &.{ cwd_path, path });
        errdefer allocator.free(resolved);
        return realPathAbsoluteAllocPlain(allocator, io, resolved) catch |err| switch (err) {
            error.FileNotFound => resolved,
            else => err,
        };
    }

    fn realPathInDirAllocPlain(
        allocator: std.mem.Allocator,
        io: std.Io,
        dir: std.Io.Dir,
        sub_path: []const u8,
    ) ![]u8 {
        const z = try dir.realPathFileAlloc(io, sub_path, allocator);
        defer allocator.free(z);
        return allocator.dupe(u8, z);
    }

    fn realPathAbsoluteAllocPlain(
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
    ) ![]u8 {
        const z = try std.Io.Dir.realPathFileAbsoluteAlloc(io, path, allocator);
        defer allocator.free(z);
        return allocator.dupe(u8, z);
    }

    fn isDirectory(io: std.Io, path: []const u8) bool {
        var dir = std.Io.Dir.openDirAbsolute(io, path, .{}) catch return false;
        dir.close(io);
        return true;
    }

    fn getWorkspaceSessionPathForRoot(
        allocator: std.mem.Allocator,
        sessions_dir: []const u8,
        workspace_root: []const u8,
    ) ![]const u8 {
        var hasher = std.hash.Fnv1a_64.init();
        hasher.update(workspace_root);
        const hash = hasher.final();

        var filename_buf: [32]u8 = undefined;
        const filename = std.fmt.bufPrint(&filename_buf, "{x:0>16}.json", .{hash}) catch "default.json";

        return std.fs.path.join(allocator, &.{ sessions_dir, filename });
    }

    fn getWorkspaceSessionPathForInitialPaths(
        allocator: std.mem.Allocator,
        io: std.Io,
        sessions_dir: []const u8,
        initial_paths: []const []const u8,
    ) ![]const u8 {
        const root = try getWorkspaceRootForInitialPaths(allocator, io, initial_paths);
        defer allocator.free(root);
        return getWorkspaceSessionPathForRoot(allocator, sessions_dir, root);
    }
};

pub const WorkspaceInstanceLock = struct {
    io: std.Io,
    file: std.Io.File,

    /// Holds the workspace's editor-instance lock for the lifetime of the
    /// process. The OS releases the lock on crash, so stale `.lock` files do
    /// not block future launches.
    pub fn acquire(
        allocator: std.mem.Allocator,
        io: std.Io,
        lock_path: []const u8,
        workspace_path: []const u8,
    ) !WorkspaceInstanceLock {
        const file = std.Io.Dir.createFileAbsolute(io, lock_path, .{
            .read = true,
            .truncate = false,
            .lock = .exclusive,
            .lock_nonblocking = true,
        }) catch |err| switch (err) {
            error.WouldBlock => return error.AlreadyRunning,
            else => return err,
        };
        errdefer file.close(io);

        const metadata = try std.fmt.allocPrint(allocator, "pid={d}\nworkspace={s}\n", .{
            platform.getProcessId(),
            workspace_path,
        });
        defer allocator.free(metadata);

        try file.setLength(io, 0);
        try file.writePositionalAll(io, metadata, 0);

        return .{
            .io = io,
            .file = file,
        };
    }

    pub fn deinit(self: *WorkspaceInstanceLock) void {
        self.file.unlock(self.io);
        self.file.close(self.io);
    }
};

test "WorkspaceInstanceLock refuses a second holder for the same workspace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    var io_ctx = std.Io.Threaded.init(allocator, .{});
    defer io_ctx.deinit();
    const io = io_ctx.io();

    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const lock_path = try std.fs.path.join(allocator, &.{ root, "workspace.lock" });
    defer allocator.free(lock_path);

    var first = try WorkspaceInstanceLock.acquire(allocator, io, lock_path, root);
    defer first.deinit();

    try std.testing.expectError(
        error.AlreadyRunning,
        WorkspaceInstanceLock.acquire(allocator, io, lock_path, root),
    );
}

test "workspace session identity follows explicit directory targets" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    var io_ctx = std.Io.Threaded.init(allocator, .{});
    defer io_ctx.deinit();
    const io = io_ctx.io();

    try tmp.dir.createDir(io, "one", .default_dir);
    try tmp.dir.createDir(io, "two", .default_dir);

    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const one = try std.fs.path.join(allocator, &.{ root, "one" });
    defer allocator.free(one);
    const two = try std.fs.path.join(allocator, &.{ root, "two" });
    defer allocator.free(two);

    const sessions_dir = try std.fs.path.join(allocator, &.{ root, "sessions" });
    defer allocator.free(sessions_dir);

    const cwd_session = try StorageManager.getWorkspaceSessionPathForInitialPaths(allocator, io, sessions_dir, &.{});
    defer allocator.free(cwd_session);
    const one_session = try StorageManager.getWorkspaceSessionPathForInitialPaths(allocator, io, sessions_dir, &.{one});
    defer allocator.free(one_session);
    const two_session = try StorageManager.getWorkspaceSessionPathForInitialPaths(allocator, io, sessions_dir, &.{two});
    defer allocator.free(two_session);

    try std.testing.expect(!std.mem.eql(u8, cwd_session, one_session));
    try std.testing.expect(!std.mem.eql(u8, one_session, two_session));
}
