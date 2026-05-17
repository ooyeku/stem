const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("../kernel/protocol.zig");
const platform = @import("../kernel/platform.zig");

pub const LogLevel = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,

    pub fn toString(self: LogLevel) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
    }

    pub fn fromString(s: []const u8) ?LogLevel {
        if (std.mem.eql(u8, s, "debug")) return .debug;
        if (std.mem.eql(u8, s, "info")) return .info;
        if (std.mem.eql(u8, s, "warn")) return .warn;
        if (std.mem.eql(u8, s, "err")) return .err;
        if (std.mem.eql(u8, s, "error")) return .err;
        return null;
    }
};

pub const Logger = struct {
    io: std.Io,
    file: ?std.Io.File,
    file_offset: u64,
    level: LogLevel,
    mutex: std.Io.Mutex,
    allocator: std.mem.Allocator,
    buffer: LogBuffer,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, io: std.Io, logs_dir: []const u8, level: LogLevel) !Self {
        // Best-effort rotation: cap the logs directory at MAX_LOG_FILES files
        // by deleting the oldest matching files. Avoids unbounded disk growth
        // over long-lived installs.
        rotateLogs(io, logs_dir, allocator, 10) catch {};

        const pid = platform.getProcessId();
        var filename_buf: [64]u8 = undefined;
        const filename = std.fmt.bufPrint(&filename_buf, "stem-{d}.log", .{pid}) catch "stem.log";
        const log_path = try std.fs.path.join(allocator, &.{ logs_dir, filename });
        defer allocator.free(log_path);

        const file = std.Io.Dir.createFileAbsolute(io, log_path, .{
            .truncate = false,
        }) catch |e| {
            std.debug.print("Warning: Could not create log file {s}: {}\n", .{ log_path, e });
            return Self{
                .io = io,
                .file = null,
                .file_offset = 0,
                .level = level,
                .mutex = .init,
                .allocator = allocator,
                .buffer = try LogBuffer.init(allocator, 1000),
            };
        };

        const offset = file.length(io) catch 0;

        return Self{
            .io = io,
            .file = file,
            .file_offset = offset,
            .level = level,
            .mutex = .init,
            .allocator = allocator,
            .buffer = try LogBuffer.init(allocator, 1000),
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.file) |f| {
            f.close(self.io);
        }
        self.buffer.deinit();
    }

    pub fn setLevel(self: *Self, level: LogLevel) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.level = level;
    }

    pub fn log(
        self: *Self,
        level: LogLevel,
        comptime scope: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        if (@intFromEnum(level) < @intFromEnum(self.level)) {
            return;
        }

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const file = self.file orelse return;

        const ct_offset_hours: i64 = -6;
        const ct_offset_seconds: i64 = ct_offset_hours * 3600;
        const timestamp = std.Io.Clock.real.now(self.io).toSeconds() + ct_offset_seconds;
        const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(timestamp) };
        const day_seconds = epoch_seconds.getDaySeconds();
        const epoch_day = epoch_seconds.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();

        var buf: [4096]u8 = undefined;
        var fbw: std.Io.Writer = .fixed(&buf);

        fbw.print("[{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}] [{s}] [{s}] ", .{
            year_day.year,
            @intFromEnum(month_day.month),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
            level.toString(),
            scope,
        }) catch return;

        fbw.print(fmt ++ "\n", args) catch return;

        const written = fbw.buffered();
        // Only advance the file offset if the write actually succeeded.
        // Otherwise subsequent writes would leave a hole / write past EOF,
        // corrupting the log file for the rest of the session.
        if (file.writePositionalAll(self.io, written, self.file_offset)) {
            self.file_offset += written.len;
        } else |_| {}

        var msg_buf: [4096]u8 = undefined;
        var msg_fbw: std.Io.Writer = .fixed(&msg_buf);
        msg_fbw.print(fmt, args) catch return;

        // best-effort: in-memory ring buffer push; cannot recursively log a logger failure
        self.buffer.push(timestamp, level, scope, msg_fbw.buffered()) catch {};
    }

    pub fn clear(self: *Self) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.buffer.clear();

        if (self.file) |f| {
            // best-effort: truncating the log file; failure leaves stale data, not a runtime error
            f.setLength(self.io, 0) catch {};
            self.file_offset = 0;
        }
    }

    pub fn getEntries(self: *Self, result_allocator: std.mem.Allocator) ![]LogEntry {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.buffer.getEntries(result_allocator);
    }
};

/// Trim the logs directory to at most `keep` files matching `stem-*.log`,
/// deleting the oldest by mtime first. Best-effort; failures are silent so
/// startup is never blocked by a hostile logs directory.
fn rotateLogs(io: std.Io, logs_dir: []const u8, allocator: std.mem.Allocator, keep: usize) !void {
    var dir = std.Io.Dir.openDirAbsolute(io, logs_dir, .{ .iterate = true }) catch return;
    defer dir.close(io);

    const Entry = struct {
        name: []const u8,
        mtime: i96,
    };
    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    defer {
        for (entries.items) |e| allocator.free(e.name);
        entries.deinit(allocator);
    }

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "stem-")) continue;
        if (!std.mem.endsWith(u8, entry.name, ".log")) continue;

        const stat = dir.statFile(io, entry.name, .{}) catch continue;
        const name_dup = allocator.dupe(u8, entry.name) catch continue;
        entries.append(allocator, .{ .name = name_dup, .mtime = stat.mtime.toNanoseconds() }) catch {
            allocator.free(name_dup);
            continue;
        };
    }

    if (entries.items.len <= keep) return;

    // Sort newest-first so we can drop the tail.
    std.mem.sort(Entry, entries.items, {}, struct {
        fn newerFirst(_: void, a: Entry, b: Entry) bool {
            return a.mtime > b.mtime;
        }
    }.newerFirst);

    for (entries.items[keep..]) |e| {
        dir.deleteFile(io, e.name) catch {};
    }
}

var global_logger: ?*Logger = null;
var global_allocator: ?std.mem.Allocator = null;

pub fn init(allocator: std.mem.Allocator, io: std.Io, logs_dir: []const u8, level: LogLevel) !void {
    if (global_logger != null) {
        return;
    }

    const logger = try allocator.create(Logger);
    logger.* = try Logger.init(allocator, io, logs_dir, level);
    global_logger = logger;
    global_allocator = allocator;
}

pub fn deinit() void {
    if (global_logger) |logger| {
        logger.deinit();
        if (global_allocator) |alloc| {
            alloc.destroy(logger);
        }
    }
    global_logger = null;
    global_allocator = null;
}

pub fn setLevel(level: LogLevel) void {
    if (global_logger) |logger| {
        logger.setLevel(level);
    }
}

pub fn getGlobal() ?*Logger {
    return global_logger;
}

pub fn stdLogBridge(
    comptime level: std.log.Level,
    comptime scope_tag: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const logger = global_logger orelse return;

    const our_level: LogLevel = switch (level) {
        .debug => .debug,
        .info => .info,
        .warn => .warn,
        .err => .err,
    };

    const scope_name = @tagName(scope_tag);
    logger.log(our_level, scope_name, format, args);
}

pub fn scoped(comptime scope: []const u8) type {
    return struct {
        pub fn debug(comptime fmt: []const u8, args: anytype) void {
            if (global_logger) |logger| {
                logger.log(.debug, scope, fmt, args);
            }
        }

        pub fn info(comptime fmt: []const u8, args: anytype) void {
            if (global_logger) |logger| {
                logger.log(.info, scope, fmt, args);
            }
        }

        pub fn warn(comptime fmt: []const u8, args: anytype) void {
            if (global_logger) |logger| {
                logger.log(.warn, scope, fmt, args);
            }
        }

        pub fn err(comptime fmt: []const u8, args: anytype) void {
            if (global_logger) |logger| {
                logger.log(.err, scope, fmt, args);
            }
        }
    };
}

pub const LogEntry = protocol.LogEntry;

const LogBuffer = struct {
    entries: []LogEntry,
    capacity: usize,
    head: usize,
    count: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !LogBuffer {
        return .{
            .entries = try allocator.alloc(LogEntry, capacity),
            .capacity = capacity,
            .head = 0,
            .count = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LogBuffer) void {
        for (0..self.count) |i| {
            const idx = if (self.count < self.capacity)
                i
            else
                (self.head + i) % self.capacity;
            self.allocator.free(self.entries[idx].scope);
            self.allocator.free(self.entries[idx].message);
        }
        self.allocator.free(self.entries);
    }

    pub fn push(self: *LogBuffer, timestamp: i64, level: LogLevel, scope: []const u8, message: []const u8) !void {
        if (self.count == self.capacity) {
            const old_entry = self.entries[self.head];
            self.allocator.free(old_entry.scope);
            self.allocator.free(old_entry.message);
        }

        const entry = LogEntry{
            .timestamp = timestamp,
            .level = @intFromEnum(level),
            .scope = try self.allocator.dupe(u8, scope),
            .message = try self.allocator.dupe(u8, message),
        };

        self.entries[self.head] = entry;
        self.head = (self.head + 1) % self.capacity;
        if (self.count < self.capacity) {
            self.count += 1;
        }
    }

    pub fn clear(self: *LogBuffer) void {
        for (0..self.count) |i| {
            const idx = if (self.count < self.capacity)
                i
            else
                (self.head + i) % self.capacity;
            self.allocator.free(self.entries[idx].scope);
            self.allocator.free(self.entries[idx].message);
        }
        self.count = 0;
        self.head = 0;
    }

    pub fn getEntries(self: *LogBuffer, allocator: std.mem.Allocator) ![]LogEntry {
        const result = try allocator.alloc(LogEntry, self.count);
        var res_idx: usize = 0;

        var idx = if (self.count < self.capacity) 0 else self.head;

        for (0..self.count) |_| {
            const entry = self.entries[idx];
            result[res_idx] = LogEntry{
                .timestamp = entry.timestamp,
                .level = entry.level,
                .scope = try allocator.dupe(u8, entry.scope),
                .message = try allocator.dupe(u8, entry.message),
            };
            idx = (idx + 1) % self.capacity;
            res_idx += 1;
        }
        return result;
    }
};

pub const core = scoped("Core");
pub const buffer_manager = scoped("BufferManager");
pub const split_manager = scoped("SplitManager");
pub const plugin_manager = scoped("PluginManager");
pub const ui_manager = scoped("UIManager");
pub const lsp_manager = scoped("LSPManager");
pub const syntax_manager = scoped("SyntaxManager");
pub const storage = scoped("Storage");
pub const vfs = scoped("VFS");
pub const lsp = scoped("LSP");
