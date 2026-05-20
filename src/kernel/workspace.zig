const std = @import("std");
const TestIo = @import("../test_utils.zig").TestIo;

pub const ZigWorkspace = struct {
    root_path: []const u8,
    build_zig_path: []const u8,
    has_zon: bool,
    name: []const u8,

    pub fn deinit(self: *ZigWorkspace, allocator: std.mem.Allocator) void {
        allocator.free(self.root_path);
        allocator.free(self.build_zig_path);
        allocator.free(self.name);
    }

    pub fn clone(self: ZigWorkspace, allocator: std.mem.Allocator) !ZigWorkspace {
        // Allocate each field in order with errdefer cleanup so a
        // mid-clone OOM doesn't leak the earlier dupes. Previous
        // version put the three dupes directly in a struct literal,
        // which evaluates left-to-right but offers no rollback.
        const root_path = try allocator.dupe(u8, self.root_path);
        errdefer allocator.free(root_path);
        const build_zig_path = try allocator.dupe(u8, self.build_zig_path);
        errdefer allocator.free(build_zig_path);
        const name = try allocator.dupe(u8, self.name);
        return ZigWorkspace{
            .root_path = root_path,
            .build_zig_path = build_zig_path,
            .has_zon = self.has_zon,
            .name = name,
        };
    }

    pub fn eql(self: ZigWorkspace, other: ZigWorkspace) bool {
        return std.mem.eql(u8, self.root_path, other.root_path);
    }
};

pub const WorkspaceManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    buffer_workspaces: std.AutoHashMap(u32, ZigWorkspace),
    active_workspace: ?ZigWorkspace,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) WorkspaceManager {
        return WorkspaceManager{
            .allocator = allocator,
            .io = io,
            .buffer_workspaces = std.AutoHashMap(u32, ZigWorkspace).init(allocator),
            .active_workspace = null,
        };
    }

    pub fn deinit(self: *WorkspaceManager) void {
        var it = self.buffer_workspaces.iterator();
        while (it.next()) |entry| {
            var ws = entry.value_ptr.*;
            ws.deinit(self.allocator);
        }
        self.buffer_workspaces.deinit();

        if (self.active_workspace) |*ws| {
            ws.deinit(self.allocator);
        }
    }

    pub fn detectWorkspace(self: *WorkspaceManager, file_path: []const u8) !?ZigWorkspace {
        const dir_path = std.fs.path.dirname(file_path) orelse return null;
        var current_dir = try self.allocator.dupe(u8, dir_path);
        defer self.allocator.free(current_dir);

        while (true) {
            const build_zig = try std.fs.path.join(self.allocator, &.{ current_dir, "build.zig" });
            defer self.allocator.free(build_zig);

            if (std.Io.Dir.cwd().access(self.io, build_zig, .{})) |_| {
                const build_zon = try std.fs.path.join(self.allocator, &.{ current_dir, "build.zig.zon" });
                defer self.allocator.free(build_zon);

                const has_zon = if (std.Io.Dir.cwd().access(self.io, build_zon, .{})) |_| true else |_| false;

                const name = std.fs.path.basename(current_dir);

                return ZigWorkspace{
                    .root_path = try self.allocator.dupe(u8, current_dir),
                    .build_zig_path = try self.allocator.dupe(u8, build_zig),
                    .has_zon = has_zon,
                    .name = try self.allocator.dupe(u8, name),
                };
            } else |_| {}

            const parent = std.fs.path.dirname(current_dir);
            if (parent) |p| {
                if (std.mem.eql(u8, p, current_dir)) break;
                if (p.len == 0) break;

                const new_current = try self.allocator.dupe(u8, p);
                self.allocator.free(current_dir);
                current_dir = new_current;
            } else {
                break;
            }
        }

        return null;
    }

    pub fn registerBuffer(self: *WorkspaceManager, buffer_id: u32, file_path: []const u8) !void {
        if (self.buffer_workspaces.contains(buffer_id)) {
            return;
        }

        if (!std.mem.endsWith(u8, file_path, ".zig")) {
            return;
        }

        if (try self.detectWorkspace(file_path)) |ws| {
            try self.buffer_workspaces.put(buffer_id, ws);
        }
    }

    pub fn unregisterBuffer(self: *WorkspaceManager, buffer_id: u32) void {
        if (self.buffer_workspaces.fetchRemove(buffer_id)) |entry| {
            var ws = entry.value;
            ws.deinit(self.allocator);
        }
    }

    pub fn getBufferWorkspace(self: *WorkspaceManager, buffer_id: u32) ?ZigWorkspace {
        return self.buffer_workspaces.get(buffer_id);
    }

    pub fn setActiveWorkspace(self: *WorkspaceManager, buffer_id: u32) bool {
        const new_ws = self.buffer_workspaces.get(buffer_id);
        const old_ws = self.active_workspace;

        const changed = blk: {
            if (new_ws == null and old_ws == null) break :blk false;
            if (new_ws == null or old_ws == null) break :blk true;
            break :blk !new_ws.?.eql(old_ws.?);
        };

        if (changed) {
            if (self.active_workspace) |*ws| {
                ws.deinit(self.allocator);
                self.active_workspace = null;
            }

            if (new_ws) |ws| {
                self.active_workspace = ws.clone(self.allocator) catch null;
            }
        }

        return changed;
    }

    pub fn getActiveRootPath(self: *WorkspaceManager) ?[]const u8 {
        if (self.active_workspace) |ws| {
            return ws.root_path;
        }
        return null;
    }

    pub fn getActiveWorkspaceName(self: *WorkspaceManager) ?[]const u8 {
        if (self.active_workspace) |ws| {
            return ws.name;
        }
        return null;
    }
};

test "workspace detection" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var wm = WorkspaceManager.init(allocator, io);
    defer wm.deinit();

    try std.testing.expect(wm.active_workspace == null);
}
