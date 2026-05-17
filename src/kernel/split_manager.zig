const std = @import("std");
const protocol = @import("protocol.zig");

const test_utils = @import("../test_utils.zig");
const MemoryTestUtils = test_utils.MemoryTestUtils;
const PerformanceTestUtils = test_utils.PerformanceTestUtils;

pub const SplitDirection = enum {
    horizontal,
    vertical,
};

pub const Pane = struct {
    id: u32,
    buffer_index: usize,
    scroll_offset: usize,
    cursor_row: usize,
    cursor_col: usize,
    selection_anchor_row: ?usize,
    selection_anchor_col: ?usize,

    pub fn init(id: u32, buffer_index: usize) Pane {
        return .{
            .id = id,
            .buffer_index = buffer_index,
            .scroll_offset = 0,
            .cursor_row = 0,
            .cursor_col = 0,
            .selection_anchor_row = null,
            .selection_anchor_col = null,
        };
    }
};

pub const SplitNode = union(enum) {
    container: Container,
    pane: Pane,
};

pub const Container = struct {
    direction: SplitDirection,
    split_ratio: f32,
    first: *SplitNode,
    second: *SplitNode,
};

pub const SplitManager = struct {
    allocator: std.mem.Allocator,
    root: *SplitNode,
    focused_pane_id: u32,
    next_pane_id: u32,
    sync_scroll: bool = false,

    pub fn init(allocator: std.mem.Allocator, initial_buffer_index: usize) !SplitManager {
        const root = try allocator.create(SplitNode);
        root.* = .{ .pane = Pane.init(1, initial_buffer_index) };

        return .{
            .allocator = allocator,
            .root = root,
            .focused_pane_id = 1,
            .next_pane_id = 2,
            .sync_scroll = false,
        };
    }

    pub fn deinit(self: *SplitManager) void {
        self.freeNode(self.root);
    }

    fn freeNode(self: *SplitManager, node: *SplitNode) void {
        switch (node.*) {
            .container => |c| {
                self.freeNode(c.first);
                self.freeNode(c.second);
            },
            .pane => {},
        }
        self.allocator.destroy(node);
    }

    pub fn getFocusedPane(self: *SplitManager) *Pane {
        return self.findPaneById(self.root, self.focused_pane_id) orelse {
            return self.getFirstPane(self.root);
        };
    }

    fn findPaneById(self: *SplitManager, node: *SplitNode, id: u32) ?*Pane {
        _ = self;
        return findPaneByIdStatic(node, id);
    }

    fn findPaneByIdStatic(node: *SplitNode, id: u32) ?*Pane {
        switch (node.*) {
            .container => |c| {
                if (findPaneByIdStatic(c.first, id)) |p| return p;
                if (findPaneByIdStatic(c.second, id)) |p| return p;
                return null;
            },
            .pane => |*p| {
                if (p.id == id) return p;
                return null;
            },
        }
    }

    fn getFirstPane(self: *SplitManager, node: *SplitNode) *Pane {
        _ = self;
        return getFirstPaneStatic(node);
    }

    fn getFirstPaneStatic(node: *SplitNode) *Pane {
        switch (node.*) {
            .container => |c| return getFirstPaneStatic(c.first),
            .pane => |*p| return p,
        }
    }

    pub fn splitVertical(self: *SplitManager, buffer_index: usize) !void {
        try self.splitPane(.vertical, buffer_index);
    }

    pub fn splitHorizontal(self: *SplitManager, buffer_index: usize) !void {
        try self.splitPane(.horizontal, buffer_index);
    }

    pub fn setAllPanesScrollOffset(self: *SplitManager, scroll_offset: usize) void {
        self.setScrollOnNode(self.root, scroll_offset);
    }

    fn setScrollOnNode(self: *SplitManager, node: *SplitNode, scroll_offset: usize) void {
        switch (node.*) {
            .container => |c| {
                self.setScrollOnNode(c.first, scroll_offset);
                self.setScrollOnNode(c.second, scroll_offset);
            },
            .pane => |*p| {
                p.scroll_offset = scroll_offset;
            },
        }
    }

    pub fn onBufferClosed(self: *SplitManager, removed_index: usize, new_len: usize) void {
        self.updateBufferIndices(self.root, removed_index, new_len);
    }

    fn updateBufferIndices(self: *SplitManager, node: *SplitNode, removed_index: usize, new_len: usize) void {
        switch (node.*) {
            .container => |c| {
                self.updateBufferIndices(c.first, removed_index, new_len);
                self.updateBufferIndices(c.second, removed_index, new_len);
            },
            .pane => |*p| {
                if (p.buffer_index == removed_index) {
                    if (new_len > 0) {
                        p.buffer_index = @min(removed_index, new_len - 1);
                    } else {
                        p.buffer_index = 0;
                    }
                    p.selection_anchor_row = null;
                    p.selection_anchor_col = null;
                    p.cursor_row = 0;
                    p.cursor_col = 0;
                    p.scroll_offset = 0;
                } else if (p.buffer_index > removed_index) {
                    p.buffer_index -= 1;
                }
            },
        }
    }

    pub fn onCloseOthers(self: *SplitManager) void {
        self.updateBufferIndicesToZero(self.root);
    }

    fn updateBufferIndicesToZero(self: *SplitManager, node: *SplitNode) void {
        switch (node.*) {
            .container => |c| {
                self.updateBufferIndicesToZero(c.first);
                self.updateBufferIndicesToZero(c.second);
            },
            .pane => |*p| {
                p.buffer_index = 0;
            },
        }
    }

    fn splitPane(self: *SplitManager, direction: SplitDirection, buffer_index: usize) !void {
        const parent_info = self.findParentOf(self.focused_pane_id);
        const target_node = parent_info.node orelse return;

        const new_pane_id = self.next_pane_id;
        self.next_pane_id += 1;

        const new_pane_node = try self.allocator.create(SplitNode);
        new_pane_node.* = .{ .pane = Pane.init(new_pane_id, buffer_index) };
        errdefer self.allocator.destroy(new_pane_node);

        const old_pane_node = try self.allocator.create(SplitNode);
        old_pane_node.* = target_node.*;

        target_node.* = .{
            .container = .{
                .direction = direction,
                .split_ratio = 0.5,
                .first = old_pane_node,
                .second = new_pane_node,
            },
        };

        self.focused_pane_id = new_pane_id;
    }

    const ParentInfo = struct {
        parent: ?*SplitNode,
        node: ?*SplitNode,
        is_first_child: bool,
    };

    fn findParentOf(self: *SplitManager, pane_id: u32) ParentInfo {
        return self.findParentOfRecursive(self.root, null, false, pane_id);
    }

    fn findParentOfRecursive(self: *SplitManager, node: *SplitNode, parent: ?*SplitNode, is_first: bool, pane_id: u32) ParentInfo {
        _ = self;
        return findParentOfRecursiveStatic(node, parent, is_first, pane_id);
    }

    fn findParentOfRecursiveStatic(node: *SplitNode, parent: ?*SplitNode, is_first: bool, pane_id: u32) ParentInfo {
        switch (node.*) {
            .container => |c| {
                const first_result = findParentOfRecursiveStatic(c.first, node, true, pane_id);
                if (first_result.node != null) return first_result;
                return findParentOfRecursiveStatic(c.second, node, false, pane_id);
            },
            .pane => |p| {
                if (p.id == pane_id) {
                    return .{ .parent = parent, .node = node, .is_first_child = is_first };
                }
                return .{ .parent = null, .node = null, .is_first_child = false };
            },
        }
    }

    pub fn closePane(self: *SplitManager) void {
        const log = std.log.scoped(.split_manager);
        log.info("closePane called, focused_pane_id={}", .{self.focused_pane_id});

        const parent_info = self.findParentOf(self.focused_pane_id);
        const parent = parent_info.parent orelse {
            log.info("No parent found, can't close root pane", .{});
            return;
        };

        log.info("Found parent, is_first_child={}", .{parent_info.is_first_child});

        switch (parent.*) {
            .container => |c| {
                const sibling = if (parent_info.is_first_child) c.second else c.first;
                const old_node = if (parent_info.is_first_child) c.first else c.second;

                const sibling_id = switch (sibling.*) {
                    .pane => |p| p.id,
                    .container => 0,
                };
                log.info("Sibling is pane/container, sibling_id={}", .{sibling_id});

                const sibling_copy = sibling.*;
                parent.* = sibling_copy;

                self.allocator.destroy(old_node);
                self.allocator.destroy(sibling);

                self.focused_pane_id = getFirstPaneStatic(parent).id;
                log.info("After close: new focused_pane_id={}", .{self.focused_pane_id});
            },
            .pane => {
                log.info("Parent is a pane (not a container), doing nothing", .{});
            },
        }
    }

    pub fn hasSplits(self: *SplitManager) bool {
        return switch (self.root.*) {
            .container => true,
            .pane => false,
        };
    }

    pub fn getAllPaneBounds(self: *SplitManager, allocator: std.mem.Allocator, params: protocol.RenderParams) !std.ArrayListUnmanaged(protocol.PaneBound) {
        var list = std.ArrayListUnmanaged(protocol.PaneBound).empty;
        errdefer list.deinit(allocator);

        try self.collectPaneBounds(self.root, &list, allocator, 0, 0, params.cols, params.rows);
        return list;
    }

    fn collectPaneBounds(self: *SplitManager, node: *SplitNode, list: *std.ArrayListUnmanaged(protocol.PaneBound), allocator: std.mem.Allocator, x: usize, y: usize, w: usize, h: usize) !void {
        switch (node.*) {
            .container => |c| {
                if (c.direction == .vertical) {
                    const h1 = @as(usize, @intFromFloat(@as(f32, @floatFromInt(h)) * c.split_ratio));
                    const h2 = h - h1;
                    try self.collectPaneBounds(c.first, list, allocator, x, y, w, h1);
                    try self.collectPaneBounds(c.second, list, allocator, x, y + h1, w, h2);
                } else {
                    const w1 = @as(usize, @intFromFloat(@as(f32, @floatFromInt(w)) * c.split_ratio));
                    const w2 = w - w1;
                    try self.collectPaneBounds(c.first, list, allocator, x, y, w1, h);
                    try self.collectPaneBounds(c.second, list, allocator, x + w1, y, w2, h);
                }
            },
            .pane => |p| {
                try list.append(allocator, .{
                    .pane = .{ .id = p.id, .buffer_index = p.buffer_index },
                    .x = x,
                    .y = y,
                    .width = w,
                    .height = h,
                });
            },
        }
    }

    pub fn focusLeft(self: *SplitManager) void {
        self.focusInDirection(.left);
    }

    pub fn focusRight(self: *SplitManager) void {
        self.focusInDirection(.right);
    }

    pub fn focusUp(self: *SplitManager) void {
        self.focusInDirection(.up);
    }

    pub fn focusDown(self: *SplitManager) void {
        self.focusInDirection(.down);
    }

    const Direction = enum { left, right, up, down };

    fn focusInDirection(self: *SplitManager, dir: Direction) void {
        const allocator = self.allocator;
        const params = protocol.RenderParams{ .rows = 1000, .cols = 1000 };
        var bounds = self.getAllPaneBounds(allocator, params) catch return;
        defer bounds.deinit(self.allocator);

        var current: ?protocol.PaneBound = null;
        for (bounds.items) |b| {
            if (b.pane.id == self.focused_pane_id) {
                current = b;
                break;
            }
        }

        const curr = current orelse return;
        var best_candidate: ?protocol.PaneBound = null;
        var best_dist: f32 = std.math.floatMax(f32);
        const cx = @as(f32, @floatFromInt(curr.x)) + @as(f32, @floatFromInt(curr.width)) / 2.0;
        const cy = @as(f32, @floatFromInt(curr.y)) + @as(f32, @floatFromInt(curr.height)) / 2.0;

        for (bounds.items) |b| {
            if (b.pane.id == self.focused_pane_id) continue;

            const bx = @as(f32, @floatFromInt(b.x)) + @as(f32, @floatFromInt(b.width)) / 2.0;
            const by = @as(f32, @floatFromInt(b.y)) + @as(f32, @floatFromInt(b.height)) / 2.0;

            const is_valid = switch (dir) {
                .left => bx < cx and @abs(cy - by) < @as(f32, @floatFromInt(curr.height)) / 1.5,
                .right => bx > cx and @abs(cy - by) < @as(f32, @floatFromInt(curr.height)) / 1.5,
                .up => by < cy and @abs(cx - bx) < @as(f32, @floatFromInt(curr.width)) / 1.5,
                .down => by > cy and @abs(cx - bx) < @as(f32, @floatFromInt(curr.width)) / 1.5,
            };

            if (is_valid) {
                const dx = bx - cx;
                const dy = by - cy;
                const dist = dx * dx + dy * dy;
                if (dist < best_dist) {
                    best_dist = dist;
                    best_candidate = b;
                }
            }
        }

        if (best_candidate) |b| {
            self.focused_pane_id = b.pane.id;
        }
    }

    pub fn swapLeft(self: *SplitManager) void {
        self.swapInDirection(.left);
    }

    pub fn swapRight(self: *SplitManager) void {
        self.swapInDirection(.right);
    }

    pub fn swapUp(self: *SplitManager) void {
        self.swapInDirection(.up);
    }

    pub fn swapDown(self: *SplitManager) void {
        self.swapInDirection(.down);
    }

    fn swapInDirection(self: *SplitManager, dir: Direction) void {
        const allocator = self.allocator;
        const params = protocol.RenderParams{ .rows = 1000, .cols = 1000 };
        var bounds_list = self.getAllPaneBounds(allocator, params) catch return;
        defer bounds_list.deinit(self.allocator);

        if (bounds_list.items.len <= 1) return;

        var current: ?*Pane = null;
        var current_bounds: ?protocol.PaneBound = null;
        for (bounds_list.items) |b| {
            if (b.pane.id == self.focused_pane_id) {
                current = self.getPaneById(b.pane.id);
                current_bounds = b;
                break;
            }
        }
        const curr = current orelse return;
        const curr_b = current_bounds orelse return;

        var target: ?*Pane = null;
        var best_dist: f32 = std.math.floatMax(f32);

        const cx = @as(f32, @floatFromInt(curr_b.x)) + @as(f32, @floatFromInt(curr_b.width)) / 2.0;
        const cy = @as(f32, @floatFromInt(curr_b.y)) + @as(f32, @floatFromInt(curr_b.height)) / 2.0;

        for (bounds_list.items) |b| {
            if (b.pane.id == self.focused_pane_id) continue;

            const bx = @as(f32, @floatFromInt(b.x)) + @as(f32, @floatFromInt(b.width)) / 2.0;
            const by = @as(f32, @floatFromInt(b.y)) + @as(f32, @floatFromInt(b.height)) / 2.0;

            const is_valid = switch (dir) {
                .left => bx < cx and @abs(cy - by) < @as(f32, @floatFromInt(curr_b.height)) / 1.5,
                .right => bx > cx and @abs(cy - by) < @as(f32, @floatFromInt(curr_b.height)) / 1.5,
                .up => by < cy and @abs(cx - bx) < @as(f32, @floatFromInt(curr_b.width)) / 1.5,
                .down => by > cy and @abs(cx - bx) < @as(f32, @floatFromInt(curr_b.width)) / 1.5,
            };

            if (is_valid) {
                const dx = bx - cx;
                const dy = by - cy;
                const dist = dx * dx + dy * dy;
                if (dist < best_dist) {
                    best_dist = dist;
                    target = self.getPaneById(b.pane.id);
                }
            }
        }

        if (target) |t| {
            const temp_buf = curr.buffer_index;
            const temp_row = curr.cursor_row;
            const temp_col = curr.cursor_col;
            const temp_scroll = curr.scroll_offset;
            const temp_sel_row = curr.selection_anchor_row;
            const temp_sel_col = curr.selection_anchor_col;

            curr.buffer_index = t.buffer_index;
            curr.cursor_row = t.cursor_row;
            curr.cursor_col = t.cursor_col;
            curr.scroll_offset = t.scroll_offset;
            curr.selection_anchor_row = t.selection_anchor_row;
            curr.selection_anchor_col = t.selection_anchor_col;

            t.buffer_index = temp_buf;
            t.cursor_row = temp_row;
            t.cursor_col = temp_col;
            t.scroll_offset = temp_scroll;
            t.selection_anchor_row = temp_sel_row;
            t.selection_anchor_col = temp_sel_col;

            self.focused_pane_id = t.id;
        }
    }

    pub fn getPaneById(self: *SplitManager, id: u32) ?*Pane {
        return self.findPaneRecursive(self.root, id);
    }

    fn findPaneRecursive(self: *SplitManager, node: *SplitNode, id: u32) ?*Pane {
        switch (node.*) {
            .container => |c| {
                if (self.findPaneRecursive(c.first, id)) |p| return p;
                return self.findPaneRecursive(c.second, id);
            },
            .pane => |*p| {
                if (p.id == id) return p;
                return null;
            },
        }
    }

    pub fn setFocusedBuffer(self: *SplitManager, buffer_index: usize) void {
        const pane = self.getFocusedPane();
        pane.buffer_index = buffer_index;
    }

    pub fn getFocusedPaneId(self: *SplitManager) u32 {
        return self.focused_pane_id;
    }

    pub fn resizeSplit(self: *SplitManager, pane_id: u32, new_ratio: f32) !void {
        const parent_info = self.findParentOf(pane_id);
        const parent = parent_info.parent orelse return error.NotResizable;

        switch (parent.*) {
            .container => |*c| {
                c.split_ratio = std.math.clamp(new_ratio, 0.1, 0.9);
            },
            .pane => return error.NotResizable,
        }
    }

    pub fn adjustSplitRatio(self: *SplitManager, pane_id: u32, delta: f32) !void {
        const parent_info = self.findParentOf(pane_id);
        const parent = parent_info.parent orelse return error.NotResizable;

        switch (parent.*) {
            .container => |*c| {
                const new_ratio = std.math.clamp(c.split_ratio + delta, 0.1, 0.9);
                c.split_ratio = new_ratio;
            },
            .pane => return error.NotResizable,
        }
    }

    pub fn validateTree(self: *SplitManager) void {
        if (std.debug.runtime_safety) {
            var id_set = std.AutoHashMap(u32, void).init(self.allocator);
            defer id_set.deinit();

            self.validateNode(self.root, &id_set) catch {};
            std.debug.assert(id_set.contains(self.focused_pane_id));
        }
    }

    fn validateNode(self: *SplitManager, node: *SplitNode, id_set: *std.AutoHashMap(u32, void)) !void {
        switch (node.*) {
            .container => |c| {
                std.debug.assert(c.split_ratio >= 0.1 and c.split_ratio <= 0.9);
                try self.validateNode(c.first, id_set);
                try self.validateNode(c.second, id_set);
            },
            .pane => |p| {
                const result = try id_set.getOrPut(p.id);
                std.debug.assert(!result.found_existing);
            },
        }
    }

    pub const PaneIterator = struct {
        stack: std.ArrayList(*SplitNode),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, root: *SplitNode) !PaneIterator {
            var stack = std.ArrayList(*SplitNode).empty;
            try stack.append(allocator, root);
            return .{ .stack = stack, .allocator = allocator };
        }

        pub fn deinit(self: *PaneIterator) void {
            self.stack.deinit(self.allocator);
        }

        pub fn next(self: *PaneIterator) ?*Pane {
            while (self.stack.popOrNull()) |node| {
                switch (node.*) {
                    .container => |c| {
                        self.stack.append(self.allocator, c.second) catch return null;
                        self.stack.append(self.allocator, c.first) catch return null;
                    },
                    .pane => |*p| return p,
                }
            }
            return null;
        }

        pub fn count(self: *PaneIterator) usize {
            var n: usize = 0;
            var copy_stack = self.stack.clone(self.allocator) catch return 0;
            defer copy_stack.deinit(self.allocator);

            while (copy_stack.popOrNull()) |node| {
                switch (node.*) {
                    .container => |c| {
                        copy_stack.append(self.allocator, c.second) catch return n;
                        copy_stack.append(self.allocator, c.first) catch return n;
                    },
                    .pane => n += 1,
                }
            }
            return n;
        }
    };

    pub fn iteratePanes(self: *SplitManager) !PaneIterator {
        return PaneIterator.init(self.allocator, self.root);
    }

    pub fn countPanes(self: *SplitManager) usize {
        return self.countPanesRecursive(self.root);
    }

    fn countPanesRecursive(self: *SplitManager, node: *SplitNode) usize {
        switch (node.*) {
            .container => |c| {
                return self.countPanesRecursive(c.first) + self.countPanesRecursive(c.second);
            },
            .pane => return 1,
        }
    }

    pub fn toJson(self: *SplitManager, allocator: std.mem.Allocator) ![]const u8 {
        var json = std.ArrayListUnmanaged(u8).empty;
        errdefer json.deinit(allocator);

        try json.appendSlice(allocator, "{\"focused\":");
        try appendInt(allocator, &json, self.focused_pane_id);
        try json.appendSlice(allocator, ",\"next_id\":");
        try appendInt(allocator, &json, self.next_pane_id);
        try json.appendSlice(allocator, ",\"root\":");
        try self.serializeNode(allocator, &json, self.root);
        try json.append(allocator, '}');

        return json.toOwnedSlice(allocator);
    }

    fn serializeNode(self: *SplitManager, allocator: std.mem.Allocator, json: *std.ArrayListUnmanaged(u8), node: *SplitNode) !void {
        _ = self;
        switch (node.*) {
            .container => |c| {
                try json.appendSlice(allocator, "{\"type\":\"container\",\"dir\":\"");
                try json.appendSlice(allocator, if (c.direction == .horizontal) "h" else "v");
                try json.appendSlice(allocator, "\",\"ratio\":");
                const ratio_int = @as(usize, @intFromFloat(c.split_ratio * 100.0));
                try appendInt(allocator, json, ratio_int);
                try json.appendSlice(allocator, ",\"first\":");
                try serializeNodeStatic(allocator, json, c.first);
                try json.appendSlice(allocator, ",\"second\":");
                try serializeNodeStatic(allocator, json, c.second);
                try json.append(allocator, '}');
            },
            .pane => |p| {
                try json.appendSlice(allocator, "{\"type\":\"pane\",\"id\":");
                try appendInt(allocator, json, p.id);
                try json.appendSlice(allocator, ",\"buf\":");
                try appendInt(allocator, json, p.buffer_index);
                try json.appendSlice(allocator, ",\"row\":");
                try appendInt(allocator, json, p.cursor_row);
                try json.appendSlice(allocator, ",\"col\":");
                try appendInt(allocator, json, p.cursor_col);
                try json.appendSlice(allocator, ",\"scroll\":");
                try appendInt(allocator, json, p.scroll_offset);
                try json.append(allocator, '}');
            },
        }
    }

    fn serializeNodeStatic(allocator: std.mem.Allocator, json: *std.ArrayListUnmanaged(u8), node: *SplitNode) !void {
        switch (node.*) {
            .container => |c| {
                try json.appendSlice(allocator, "{\"type\":\"container\",\"dir\":\"");
                try json.appendSlice(allocator, if (c.direction == .horizontal) "h" else "v");
                try json.appendSlice(allocator, "\",\"ratio\":");
                const ratio_int = @as(usize, @intFromFloat(c.split_ratio * 100.0));
                try appendInt(allocator, json, ratio_int);
                try json.appendSlice(allocator, ",\"first\":");
                try serializeNodeStatic(allocator, json, c.first);
                try json.appendSlice(allocator, ",\"second\":");
                try serializeNodeStatic(allocator, json, c.second);
                try json.append(allocator, '}');
            },
            .pane => |p| {
                try json.appendSlice(allocator, "{\"type\":\"pane\",\"id\":");
                try appendInt(allocator, json, p.id);
                try json.appendSlice(allocator, ",\"buf\":");
                try appendInt(allocator, json, p.buffer_index);
                try json.appendSlice(allocator, ",\"row\":");
                try appendInt(allocator, json, p.cursor_row);
                try json.appendSlice(allocator, ",\"col\":");
                try appendInt(allocator, json, p.cursor_col);
                try json.appendSlice(allocator, ",\"scroll\":");
                try appendInt(allocator, json, p.scroll_offset);
                try json.append(allocator, '}');
            },
        }
    }

    pub fn initFromJson(allocator: std.mem.Allocator, json: []const u8) !SplitManager {
        var focused: u32 = 1;
        if (std.mem.indexOf(u8, json, "\"focused\":")) |pos| {
            // Saturate corrupted/oversize values into u32 max instead of panicking.
            const n = parseNumber(json, pos + 10);
            focused = if (n > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(n);
        }

        var next_id: u32 = 2;
        if (std.mem.indexOf(u8, json, "\"next_id\":")) |pos| {
            const n = parseNumber(json, pos + 10);
            next_id = if (n > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(n);
        }

        const root_start = std.mem.indexOf(u8, json, "\"root\":") orelse return error.InvalidFormat;
        const root_json = json[root_start + 7 ..];

        const root = try parseNode(allocator, root_json, 0);

        return .{
            .allocator = allocator,
            .root = root,
            .focused_pane_id = focused,
            .next_pane_id = next_id,
            .sync_scroll = false,
        };
    }

    /// Recursion-depth-capped parse. A pathologically nested session file
    /// (corrupted or hand-edited) cannot blow the stack.
    fn parseNode(allocator: std.mem.Allocator, json: []const u8, depth: u8) !*SplitNode {
        const max_depth: u8 = 32;
        if (depth > max_depth) return error.InvalidFormat;

        const node = try allocator.create(SplitNode);
        errdefer allocator.destroy(node);

        if (std.mem.indexOf(u8, json, "\"type\":\"container\"")) |_| {
            var direction: SplitDirection = .horizontal;
            if (std.mem.indexOf(u8, json, "\"dir\":\"v\"")) |_| {
                direction = .vertical;
            }

            var ratio: f32 = 0.5;
            if (std.mem.indexOf(u8, json, "\"ratio\":")) |pos| {
                const ratio_int = parseNumber(json, pos + 8);
                ratio = @as(f32, @floatFromInt(ratio_int)) / 100.0;
            }

            const first_pos = std.mem.indexOf(u8, json, "\"first\":") orelse return error.InvalidFormat;
            const first_json = json[first_pos + 8 ..];
            const first_end = findMatchingBrace(first_json) orelse return error.InvalidFormat;
            const first = try parseNode(allocator, first_json[0 .. first_end + 1], depth + 1);
            errdefer allocator.destroy(first);

            const second_search_start = first_pos + 8 + first_end + 1;
            const remaining = json[second_search_start..];
            const second_pos = std.mem.indexOf(u8, remaining, "\"second\":") orelse return error.InvalidFormat;
            const second_json = remaining[second_pos + 9 ..];
            const second = try parseNode(allocator, second_json, depth + 1);

            node.* = .{
                .container = .{
                    .direction = direction,
                    .split_ratio = ratio,
                    .first = first,
                    .second = second,
                },
            };
        } else if (std.mem.indexOf(u8, json, "\"type\":\"pane\"")) |_| {
            var id: u32 = 1;
            if (std.mem.indexOf(u8, json, "\"id\":")) |pos| {
                const n = parseNumber(json, pos + 5);
                id = if (n > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(n);
            }

            var buf: usize = 0;
            if (std.mem.indexOf(u8, json, "\"buf\":")) |pos| {
                buf = parseNumber(json, pos + 6);
            }

            var row: usize = 0;
            if (std.mem.indexOf(u8, json, "\"row\":")) |pos| {
                row = parseNumber(json, pos + 6);
            }

            var col: usize = 0;
            if (std.mem.indexOf(u8, json, "\"col\":")) |pos| {
                col = parseNumber(json, pos + 6);
            }

            var scroll: usize = 0;
            if (std.mem.indexOf(u8, json, "\"scroll\":")) |pos| {
                scroll = parseNumber(json, pos + 9);
            }

            node.* = .{
                .pane = .{
                    .id = id,
                    .buffer_index = buf,
                    .cursor_row = row,
                    .cursor_col = col,
                    .scroll_offset = scroll,
                    .selection_anchor_row = null,
                    .selection_anchor_col = null,
                },
            };
        } else {
            return error.InvalidFormat;
        }

        return node;
    }

    /// Parse a base-10 digit run starting at `start`. Saturates at usize max
    /// instead of wrapping — a corrupted session file with an enormous number
    /// must not crash the editor at startup.
    fn parseNumber(json: []const u8, start: usize) usize {
        var i = start;
        var num: usize = 0;
        while (i < json.len and json[i] >= '0' and json[i] <= '9') {
            const digit: usize = json[i] - '0';
            // Saturating multiply-add.
            num = std.math.mul(usize, num, 10) catch {
                return std.math.maxInt(usize);
            };
            num = std.math.add(usize, num, digit) catch {
                return std.math.maxInt(usize);
            };
            i += 1;
        }
        return num;
    }

    fn findMatchingBrace(json: []const u8) ?usize {
        if (json.len == 0 or json[0] != '{') return null;
        var depth: usize = 0;
        for (json, 0..) |c, i| {
            if (c == '{') depth += 1;
            if (c == '}') {
                depth -= 1;
                if (depth == 0) return i;
            }
        }
        return null;
    }
};

fn appendInt(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8), n: anytype) !void {
    var buf: [20]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, "{}", .{n}) catch unreachable;
    try list.appendSlice(allocator, str);
}

test "pane initialization" {
    const pane = Pane.init(1, 0);
    try std.testing.expectEqual(@as(u32, 1), pane.id);
    try std.testing.expectEqual(@as(usize, 0), pane.buffer_index);
    try std.testing.expectEqual(@as(usize, 0), pane.scroll_offset);
    try std.testing.expectEqual(@as(usize, 0), pane.cursor_row);
    try std.testing.expectEqual(@as(usize, 0), pane.cursor_col);
    try std.testing.expect(pane.selection_anchor_row == null);
    try std.testing.expect(pane.selection_anchor_col == null);
}

test "pane with different buffer index" {
    const pane = Pane.init(5, 3);
    try std.testing.expectEqual(@as(u32, 5), pane.id);
    try std.testing.expectEqual(@as(usize, 3), pane.buffer_index);
}

test "split direction enum" {
    const h: SplitDirection = .horizontal;
    const v: SplitDirection = .vertical;
    try std.testing.expect(h != v);
}

test "split manager initialization" {
    const allocator = std.testing.allocator;
    var sm = try SplitManager.init(allocator, 0);
    defer sm.deinit();

    try std.testing.expectEqual(@as(u32, 1), sm.focused_pane_id);
    try std.testing.expectEqual(@as(u32, 2), sm.next_pane_id);
    try std.testing.expect(!sm.hasSplits());
}

test "split manager initialization different buffer" {
    const allocator = std.testing.allocator;
    var sm = try SplitManager.init(allocator, 5);
    defer sm.deinit();

    const pane = sm.getFocusedPane();
    try std.testing.expectEqual(@as(usize, 5), pane.buffer_index);
}

test "split manager get focused pane" {
    const allocator = std.testing.allocator;
    var sm = try SplitManager.init(allocator, 0);
    defer sm.deinit();

    const pane = sm.getFocusedPane();
    try std.testing.expectEqual(@as(u32, 1), pane.id);
    try std.testing.expectEqual(@as(usize, 0), pane.buffer_index);
}

test "split manager get focused pane id" {
    const allocator = std.testing.allocator;
    var sm = try SplitManager.init(allocator, 0);
    defer sm.deinit();

    try std.testing.expectEqual(@as(u32, 1), sm.getFocusedPaneId());
}

test "split manager has splits initially false" {
    const allocator = std.testing.allocator;
    var sm = try SplitManager.init(allocator, 0);
    defer sm.deinit();

    try std.testing.expect(!sm.hasSplits());
}

test "split manager horizontal split" {
    const allocator = std.testing.allocator;
    var sm = try SplitManager.init(allocator, 0);
    defer sm.deinit();

    try sm.splitHorizontal(1);

    try std.testing.expect(sm.hasSplits());
    try std.testing.expectEqual(@as(u32, 2), sm.focused_pane_id);
    try std.testing.expectEqual(@as(u32, 3), sm.next_pane_id);
}

test "split manager vertical split" {
    const allocator = std.testing.allocator;
    var sm = try SplitManager.init(allocator, 0);
    defer sm.deinit();

    try sm.splitVertical(1);

    try std.testing.expect(sm.hasSplits());
    try std.testing.expectEqual(@as(u32, 2), sm.focused_pane_id);
}

test "split manager multiple splits" {
    const allocator = std.testing.allocator;
    var sm = try SplitManager.init(allocator, 0);
    defer sm.deinit();

    try sm.splitHorizontal(1);
    try sm.splitVertical(2);

    try std.testing.expect(sm.hasSplits());
    try std.testing.expectEqual(@as(u32, 3), sm.focused_pane_id);
    try std.testing.expectEqual(@as(u32, 4), sm.next_pane_id);
}

test "split manager get all pane bounds single pane" {
    const allocator = std.testing.allocator;
    var sm = try SplitManager.init(allocator, 0);
    defer sm.deinit();

    const params = protocol.RenderParams{ .rows = 24, .cols = 80 };
    var bounds = try sm.getAllPaneBounds(allocator, params);
    defer bounds.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), bounds.items.len);
    try std.testing.expectEqual(@as(usize, 0), bounds.items[0].x);
    try std.testing.expectEqual(@as(usize, 0), bounds.items[0].y);
    try std.testing.expectEqual(@as(usize, 80), bounds.items[0].width);
    try std.testing.expectEqual(@as(usize, 24), bounds.items[0].height);
}

test "split manager get all pane bounds horizontal split" {
    const allocator = std.testing.allocator;
    var sm = try SplitManager.init(allocator, 0);
    defer sm.deinit();

    try sm.splitHorizontal(1);

    const params = protocol.RenderParams{ .rows = 24, .cols = 80 };
    var bounds = try sm.getAllPaneBounds(allocator, params);
    defer bounds.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), bounds.items.len);

    try std.testing.expectEqual(@as(usize, 0), bounds.items[0].x);
    try std.testing.expectEqual(@as(usize, 40), bounds.items[0].width);
    try std.testing.expectEqual(@as(usize, 24), bounds.items[0].height);

    try std.testing.expectEqual(@as(usize, 40), bounds.items[1].x);
    try std.testing.expectEqual(@as(usize, 40), bounds.items[1].width);
}

test "split manager get all pane bounds vertical split" {
    const allocator = std.testing.allocator;
    var sm = try SplitManager.init(allocator, 0);
    defer sm.deinit();

    try sm.splitVertical(1);

    const params = protocol.RenderParams{ .rows = 24, .cols = 80 };
    var bounds = try sm.getAllPaneBounds(allocator, params);
    defer bounds.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), bounds.items.len);

    try std.testing.expectEqual(@as(usize, 0), bounds.items[0].y);
    try std.testing.expectEqual(@as(usize, 12), bounds.items[0].height);
    try std.testing.expectEqual(@as(usize, 80), bounds.items[0].width);

    try std.testing.expectEqual(@as(usize, 12), bounds.items[1].y);
    try std.testing.expectEqual(@as(usize, 12), bounds.items[1].height);
}

test "split manager set focused buffer" {
    const allocator = std.testing.allocator;
    var sm = try SplitManager.init(allocator, 0);
    defer sm.deinit();

    sm.setFocusedBuffer(5);

    const pane = sm.getFocusedPane();
    try std.testing.expectEqual(@as(usize, 5), pane.buffer_index);
}

test "split manager close pane single pane no effect" {
    const allocator = std.testing.allocator;
    var sm = try SplitManager.init(allocator, 0);
    defer sm.deinit();

    sm.closePane();

    try std.testing.expect(!sm.hasSplits());
    try std.testing.expectEqual(@as(u32, 1), sm.focused_pane_id);
}

test "split manager close pane after split" {
    const allocator = std.testing.allocator;
    var sm = try SplitManager.init(allocator, 0);
    defer sm.deinit();

    try sm.splitHorizontal(1);
    try std.testing.expect(sm.hasSplits());
    try std.testing.expectEqual(@as(u32, 2), sm.focused_pane_id);

    sm.closePane();

    try std.testing.expect(!sm.hasSplits());
    try std.testing.expectEqual(@as(u32, 1), sm.focused_pane_id);
}

test "split manager focus navigation horizontal" {
    const allocator = std.testing.allocator;
    var sm = try SplitManager.init(allocator, 0);
    defer sm.deinit();

    try sm.splitHorizontal(1);
    try std.testing.expectEqual(@as(u32, 2), sm.focused_pane_id);

    sm.focusLeft();
    try std.testing.expectEqual(@as(u32, 1), sm.focused_pane_id);

    sm.focusRight();
    try std.testing.expectEqual(@as(u32, 2), sm.focused_pane_id);
}

test "split manager focus navigation vertical" {
    const allocator = std.testing.allocator;
    var sm = try SplitManager.init(allocator, 0);
    defer sm.deinit();

    try sm.splitVertical(1);
    try std.testing.expectEqual(@as(u32, 2), sm.focused_pane_id);

    sm.focusUp();
    try std.testing.expectEqual(@as(u32, 1), sm.focused_pane_id);

    sm.focusDown();
    try std.testing.expectEqual(@as(u32, 2), sm.focused_pane_id);
}

test "split manager focus no change single pane" {
    const allocator = std.testing.allocator;
    var sm = try SplitManager.init(allocator, 0);
    defer sm.deinit();

    sm.focusLeft();
    try std.testing.expectEqual(@as(u32, 1), sm.focused_pane_id);

    sm.focusRight();
    try std.testing.expectEqual(@as(u32, 1), sm.focused_pane_id);

    sm.focusUp();
    try std.testing.expectEqual(@as(u32, 1), sm.focused_pane_id);

    sm.focusDown();
    try std.testing.expectEqual(@as(u32, 1), sm.focused_pane_id);
}

test "split manager swap horizontal" {
    const allocator = std.testing.allocator;
    var sm = try SplitManager.init(allocator, 0);
    defer sm.deinit();

    try sm.splitHorizontal(1);

    sm.swapLeft();

    const pane = sm.getFocusedPane();
    try std.testing.expectEqual(@as(usize, 0), pane.buffer_index);
}

test "split manager swap vertical" {
    const allocator = std.testing.allocator;
    var sm = try SplitManager.init(allocator, 0);
    defer sm.deinit();

    try sm.splitVertical(1);

    sm.swapUp();

    const pane = sm.getFocusedPane();
    try std.testing.expectEqual(@as(usize, 0), pane.buffer_index);
}

test "split manager swap no effect single pane" {
    const allocator = std.testing.allocator;
    var sm = try SplitManager.init(allocator, 0);
    defer sm.deinit();

    sm.swapLeft();
    sm.swapRight();
    sm.swapUp();
    sm.swapDown();

    const pane = sm.getFocusedPane();
    try std.testing.expectEqual(@as(usize, 0), pane.buffer_index);
}

test "split manager focus invalid direction no change" {
    const allocator = std.testing.allocator;
    var sm = try SplitManager.init(allocator, 0);
    defer sm.deinit();

    try sm.splitHorizontal(1);

    sm.focusRight();
    try std.testing.expectEqual(@as(u32, 2), sm.focused_pane_id);

    sm.focusLeft();
    sm.focusLeft();
    try std.testing.expectEqual(@as(u32, 1), sm.focused_pane_id);
}

test "split manager pane cursor state independence" {
    const allocator = std.testing.allocator;
    var sm = try SplitManager.init(allocator, 0);
    defer sm.deinit();

    try sm.splitHorizontal(1);

    const pane2 = sm.getFocusedPane();
    pane2.cursor_row = 10;
    pane2.cursor_col = 5;

    sm.focusLeft();
    const pane1 = sm.getFocusedPane();
    try std.testing.expectEqual(@as(usize, 0), pane1.cursor_row);
    try std.testing.expectEqual(@as(usize, 0), pane1.cursor_col);

    sm.focusRight();
    const pane2_again = sm.getFocusedPane();
    try std.testing.expectEqual(@as(usize, 10), pane2_again.cursor_row);
    try std.testing.expectEqual(@as(usize, 5), pane2_again.cursor_col);
}

test "split manager pane scroll offset independence" {
    const allocator = std.testing.allocator;
    var sm = try SplitManager.init(allocator, 0);
    defer sm.deinit();

    try sm.splitVertical(1);

    const pane2 = sm.getFocusedPane();
    pane2.scroll_offset = 100;

    sm.focusUp();
    const pane1 = sm.getFocusedPane();
    try std.testing.expectEqual(@as(usize, 0), pane1.scroll_offset);
}

test "split manager selection state per pane" {
    const allocator = std.testing.allocator;
    var sm = try SplitManager.init(allocator, 0);
    defer sm.deinit();

    try sm.splitHorizontal(1);

    const pane2 = sm.getFocusedPane();
    pane2.selection_anchor_row = 5;
    pane2.selection_anchor_col = 10;

    sm.focusLeft();
    const pane1 = sm.getFocusedPane();
    try std.testing.expect(pane1.selection_anchor_row == null);
    try std.testing.expect(pane1.selection_anchor_col == null);

    sm.focusRight();
    const pane2_again = sm.getFocusedPane();
    try std.testing.expectEqual(@as(usize, 5), pane2_again.selection_anchor_row.?);
    try std.testing.expectEqual(@as(usize, 10), pane2_again.selection_anchor_col.?);
}

test "split manager deep nesting" {
    const allocator = std.testing.allocator;
    var sm = try SplitManager.init(allocator, 0);
    defer sm.deinit();

    try sm.splitHorizontal(1);
    try sm.splitVertical(2);
    try sm.splitHorizontal(3);

    try std.testing.expect(sm.hasSplits());
    try std.testing.expectEqual(@as(u32, 4), sm.focused_pane_id);

    const bounds = try sm.getAllPaneBounds(allocator);
    defer allocator.free(bounds);

    try std.testing.expectEqual(@as(usize, 4), bounds.len);
}

test "split manager pane bounds sum to full area" {
    const allocator = std.testing.allocator;
    var sm = try SplitManager.init(allocator, 0);
    defer sm.deinit();

    try sm.splitHorizontal(1);
    try sm.splitVertical(2);

    const bounds = try sm.getAllPaneBounds(allocator);
    defer allocator.free(bounds);

    var total_area: f32 = 0;
    for (bounds) |b| {
        total_area += b.width * b.height;
    }

    try std.testing.expectApproxEqAbs(@as(f32, 1.0), total_area, 0.001);
}

test "SplitManager memory cleanup on deinit" {
    try MemoryTestUtils.testNoLeaks(std.testing.allocator, testSplitManagerMemoryCleanup);
}

fn testSplitManagerMemoryCleanup(allocator: std.mem.Allocator) !void {
    var sm = try SplitManager.init(allocator, 0);
    defer sm.deinit();

    try sm.splitHorizontal(1);
    try sm.splitVertical(2);
    try sm.splitHorizontal(3);

    const bounds = try sm.getAllPaneBounds(allocator);
    defer allocator.free(bounds);
    try std.testing.expect(bounds.len > 1);
}

test "SplitManager pane state preservation" {
    const allocator = std.testing.allocator;
    var sm = try SplitManager.init(allocator, 0);
    defer sm.deinit();

    var pane = sm.getFocusedPane();
    pane.cursor_row = 10;
    pane.cursor_col = 5;
    pane.scroll_offset = 20;
    pane.selection_anchor_row = 8;
    pane.selection_anchor_col = 2;

    try sm.splitHorizontal(1);
    sm.focusRight();

    const pane2 = sm.getFocusedPane();
    try std.testing.expectEqual(@as(usize, 0), pane2.cursor_row);
    try std.testing.expectEqual(@as(usize, 0), pane2.cursor_col);
    try std.testing.expectEqual(@as(usize, 0), pane2.scroll_offset);
    try std.testing.expect(pane2.selection_anchor_row == null);

    sm.focusLeft();
    pane = sm.getFocusedPane();
    try std.testing.expectEqual(@as(usize, 10), pane.cursor_row);
    try std.testing.expectEqual(@as(usize, 5), pane.cursor_col);
    try std.testing.expectEqual(@as(usize, 20), pane.scroll_offset);
    try std.testing.expectEqual(@as(usize, 8), pane.selection_anchor_row.?);
    try std.testing.expectEqual(@as(usize, 2), pane.selection_anchor_col.?);
}

test "SplitManager performance with many panes" {
    const allocator = std.testing.allocator;
    var sm = try SplitManager.init(allocator, 0);
    defer sm.deinit();

    for (0..10) |i| {
        if (i % 2 == 0) {
            try sm.splitHorizontal(i + 1);
        } else {
            try sm.splitVertical(i + 1);
        }
    }

    const bounds = try sm.getAllPaneBounds(allocator);
    defer allocator.free(bounds);
    try std.testing.expect(bounds.len > 5);

    try PerformanceTestUtils.expectPerformance(SplitManager.focusRight, .{&sm}, 50_000);

    try PerformanceTestUtils.expectPerformance(SplitManager.getAllPaneBounds, .{ &sm, allocator }, 500_000);
}

test "SplitManager bounds calculation performance" {
    const allocator = std.testing.allocator;
    var sm = try SplitManager.init(allocator, 0);
    defer sm.deinit();

    try sm.splitHorizontal(1);
    try sm.splitVertical(2);
    try sm.splitHorizontal(3);
    try sm.splitVertical(4);

    try PerformanceTestUtils.expectPerformance(SplitManager.getAllPaneBounds, .{ &sm, allocator }, 200_000);
}

test "SplitManager complex nested layout" {
    const allocator = std.testing.allocator;
    var sm = try SplitManager.init(allocator, 0);
    defer sm.deinit();

    try sm.splitHorizontal(1);
    sm.focusLeft();
    try sm.splitVertical(2);
    sm.focusRight();
    try sm.splitVertical(3);

    try std.testing.expect(sm.hasSplits());

    const bounds = try sm.getAllPaneBounds(allocator);
    defer allocator.free(bounds);

    try std.testing.expectEqual(@as(usize, 4), bounds.len);

    for (bounds) |b| {
        try std.testing.expect(b.width > 0);
        try std.testing.expect(b.height > 0);
        try std.testing.expect(b.x >= 0 and b.x <= 1);
        try std.testing.expect(b.y >= 0 and b.y <= 1);
    }
}

test "SplitManager asymmetric split ratios" {
    const allocator = std.testing.allocator;
    var sm = try SplitManager.init(allocator, 0);
    defer sm.deinit();

    try sm.splitHorizontal(1);

    if (sm.root.* == .container) {
        sm.root.container.split_ratio = 0.3;
    }

    const bounds = try sm.getAllPaneBounds(allocator);
    defer allocator.free(bounds);

    try std.testing.expectEqual(@as(usize, 2), bounds.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), bounds[0].width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), bounds[1].width, 0.01);
}

test "SplitManager focus boundary conditions" {
    const allocator = std.testing.allocator;
    var sm = try SplitManager.init(allocator, 0);
    defer sm.deinit();

    const original_focus = sm.focused_pane_id;
    sm.focusLeft();
    try std.testing.expectEqual(original_focus, sm.focused_pane_id);
    sm.focusRight();
    try std.testing.expectEqual(original_focus, sm.focused_pane_id);
    sm.focusUp();
    try std.testing.expectEqual(original_focus, sm.focused_pane_id);
    sm.focusDown();
    try std.testing.expectEqual(original_focus, sm.focused_pane_id);

    try sm.splitHorizontal(1);
    const new_focus = sm.focused_pane_id;

    sm.focusUp();
    try std.testing.expectEqual(new_focus, sm.focused_pane_id);
    sm.focusDown();
    try std.testing.expectEqual(new_focus, sm.focused_pane_id);

    sm.focusLeft();
    try std.testing.expect(sm.focused_pane_id != new_focus);
    sm.focusRight();
    try std.testing.expectEqual(new_focus, sm.focused_pane_id);
}

test "SplitManager swap operations" {
    const allocator = std.testing.allocator;
    var sm = try SplitManager.init(allocator, 0);
    defer sm.deinit();

    try sm.splitHorizontal(1);
    var pane1 = sm.getFocusedPane();
    const original_buffer_1 = pane1.buffer_index;

    sm.focusLeft();
    const pane2 = sm.getFocusedPane();
    const original_buffer_2 = pane2.buffer_index;

    sm.swapRight();
    try std.testing.expectEqual(original_buffer_2, pane2.buffer_index);
    sm.focusRight();
    pane1 = sm.getFocusedPane();
    try std.testing.expectEqual(original_buffer_1, pane1.buffer_index);
}

test "SplitManager close complex layout" {
    const allocator = std.testing.allocator;
    var sm = try SplitManager.init(allocator, 0);
    defer sm.deinit();

    try sm.splitHorizontal(1);
    sm.focusLeft();
    try sm.splitVertical(2);

    try std.testing.expect(sm.hasSplits());
    const bounds_before = try sm.getAllPaneBounds(allocator);
    defer allocator.free(bounds_before);
    try std.testing.expectEqual(@as(usize, 3), bounds_before.len);

    sm.closePane();

    try std.testing.expect(sm.hasSplits());
    const bounds_after = try sm.getAllPaneBounds(allocator);
    defer allocator.free(bounds_after);
    try std.testing.expectEqual(@as(usize, 2), bounds_after.len);
}

test "SplitManager pane ID uniqueness" {
    const allocator = std.testing.allocator;
    var sm = try SplitManager.init(allocator, 0);
    defer sm.deinit();

    try sm.splitHorizontal(1);
    try sm.splitVertical(2);
    try sm.splitHorizontal(3);
    try sm.splitVertical(4);

    var ids = std.AutoHashMap(u32, void).init(allocator);
    defer ids.deinit();

    const bounds = try sm.getAllPaneBounds(allocator);
    defer allocator.free(bounds);

    for (bounds) |b| {
        if (ids.contains(b.pane_id)) {
            std.debug.print("Duplicate pane ID found: {}\n", .{b.pane_id});
            return error.DuplicatePaneID;
        }
        try ids.put(b.pane_id, {});
    }
}

test "SplitManager buffer assignment" {
    const allocator = std.testing.allocator;
    var sm = try SplitManager.init(allocator, 5);
    defer sm.deinit();

    var pane = sm.getFocusedPane();
    try std.testing.expectEqual(@as(usize, 5), pane.buffer_index);

    try sm.splitHorizontal(10);
    pane = sm.getFocusedPane();
    try std.testing.expectEqual(@as(usize, 10), pane.buffer_index);

    sm.setFocusedBuffer(15);
    pane = sm.getFocusedPane();
    try std.testing.expectEqual(@as(usize, 15), pane.buffer_index);

    sm.focusLeft();
    pane = sm.getFocusedPane();
    try std.testing.expectEqual(@as(usize, 5), pane.buffer_index);
}

test "SplitManager recursive bounds calculation" {
    const allocator = std.testing.allocator;
    var sm = try SplitManager.init(allocator, 0);
    defer sm.deinit();

    try sm.splitHorizontal(1);
    sm.focusLeft();
    try sm.splitVertical(2);
    sm.focusUp();
    try sm.splitHorizontal(3);
    sm.focusLeft();
    try sm.splitVertical(4);

    const bounds = try sm.getAllPaneBounds(allocator);
    defer allocator.free(bounds);

    try std.testing.expectEqual(@as(usize, 5), bounds.len);

    var total_area: f32 = 0;
    for (bounds) |b| {
        try std.testing.expect(b.width > 0 and b.width <= 1);
        try std.testing.expect(b.height > 0 and b.height <= 1);
        try std.testing.expect(b.x >= 0 and b.x + b.width <= 1);
        try std.testing.expect(b.y >= 0 and b.y + b.height <= 1);
        total_area += b.width * b.height;
    }

    try std.testing.expectApproxEqAbs(@as(f32, 1.0), total_area, 0.001);
}

test "SplitManager tree traversal edge cases" {
    const allocator = std.testing.allocator;
    var sm = try SplitManager.init(allocator, 0);
    defer sm.deinit();

    sm.focusLeft();
    sm.focusRight();
    sm.focusUp();
    sm.focusDown();

    try std.testing.expect(sm.getFocusedPaneId() > 0);
}

test "SplitManager split ratio bounds" {
    const allocator = std.testing.allocator;
    var sm = try SplitManager.init(allocator, 0);
    defer sm.deinit();

    try sm.splitHorizontal(1);

    if (sm.root.* == .container) {
        sm.root.container.split_ratio = 0.01;
        var bounds = try sm.getAllPaneBounds(allocator);
        defer allocator.free(bounds);
        try std.testing.expect(bounds[0].width > 0.009);

        sm.root.container.split_ratio = 0.99;
        bounds = try sm.getAllPaneBounds(allocator);
        defer allocator.free(bounds);
        try std.testing.expect(bounds[1].width > 0.009);
    }
}

test "SplitManager integration with pane state changes" {
    const allocator = std.testing.allocator;
    var sm = try SplitManager.init(allocator, 0);
    defer sm.deinit();

    try sm.splitHorizontal(1);

    sm.focusLeft();
    var pane1 = sm.getFocusedPane();
    pane1.cursor_row = 5;
    pane1.cursor_col = 10;

    sm.focusRight();
    const pane2 = sm.getFocusedPane();
    pane2.cursor_row = 15;
    pane2.cursor_col = 25;

    sm.focusLeft();
    pane1 = sm.getFocusedPane();
    try std.testing.expectEqual(@as(usize, 5), pane1.cursor_row);
    try std.testing.expectEqual(@as(usize, 10), pane1.cursor_col);

    sm.focusRight();
    pane2 = sm.getFocusedPane();
    try std.testing.expectEqual(@as(usize, 15), pane2.cursor_row);
    try std.testing.expectEqual(@as(usize, 25), pane2.cursor_col);
}

test "SplitManager pane lifecycle" {
    const allocator = std.testing.allocator;
    var sm = try SplitManager.init(allocator, 0);
    defer sm.deinit();

    const initial_pane_id = sm.getFocusedPaneId();

    for (0..5) |_| {
        try sm.splitHorizontal(0);
        const new_pane_id = sm.getFocusedPaneId();
        try std.testing.expect(new_pane_id != initial_pane_id);

        sm.closePane();
        try std.testing.expectEqual(initial_pane_id, sm.getFocusedPaneId());
    }
}

test "SplitManager splitPane memory leak on error" {
    const allocator = std.testing.allocator;
    var failing_allocator = std.testing.FailingAllocator.init(allocator, 3);

    var sm = try SplitManager.init(failing_allocator.allocator(), 0);
    defer sm.deinit();

    try std.testing.expectError(error.OutOfMemory, sm.splitHorizontal(1));
}

test "SplitManager getAllPaneBounds memory leak on error" {
    const allocator = std.testing.allocator;
    var sm = try SplitManager.init(allocator, 0);
    defer sm.deinit();

    for (0..19) |_| {
        try sm.splitHorizontal(1);
    }

    var failing_allocator = std.testing.FailingAllocator.init(allocator, 2);

    try std.testing.expectError(error.OutOfMemory, sm.getAllPaneBounds(failing_allocator.allocator()));
}

test "swap panes" {
    const allocator = std.testing.allocator;
    var sm = try SplitManager.init(allocator, 1);
    defer sm.deinit();

    try sm.splitHorizontal(2);
    sm.focusLeft();
    try std.testing.expectEqual(@as(u32, 1), sm.focused_pane_id);

    sm.swapRight();
}

test "split manager toJson single pane" {
    const allocator = std.testing.allocator;
    var sm = try SplitManager.init(allocator, 0);
    defer sm.deinit();

    const json = try sm.toJson(allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"focused\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"pane\"") != null);
}

test "split manager toJson with splits" {
    const allocator = std.testing.allocator;
    var sm = try SplitManager.init(allocator, 0);
    defer sm.deinit();

    try sm.splitHorizontal(1);

    const json = try sm.toJson(allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"container\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"dir\":\"h\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ratio\":50") != null);
}

test "split manager initFromJson single pane" {
    const allocator = std.testing.allocator;
    const json = "{\"focused\":1,\"next_id\":2,\"root\":{\"type\":\"pane\",\"id\":1,\"buf\":0,\"row\":5,\"col\":10,\"scroll\":3}}";

    var sm = try SplitManager.initFromJson(allocator, json);
    defer sm.deinit();

    try std.testing.expectEqual(@as(u32, 1), sm.focused_pane_id);
    try std.testing.expectEqual(@as(u32, 2), sm.next_pane_id);
    try std.testing.expect(!sm.hasSplits());

    const pane = sm.getFocusedPane();
    try std.testing.expectEqual(@as(usize, 0), pane.buffer_index);
    try std.testing.expectEqual(@as(usize, 5), pane.cursor_row);
    try std.testing.expectEqual(@as(usize, 10), pane.cursor_col);
    try std.testing.expectEqual(@as(usize, 3), pane.scroll_offset);
}

test "split manager serialization round trip" {
    const allocator = std.testing.allocator;

    var sm1 = try SplitManager.init(allocator, 0);
    try sm1.splitHorizontal(1);
    try sm1.splitVertical(2);
    sm1.focused_pane_id = 2;

    const json = try sm1.toJson(allocator);
    defer allocator.free(json);

    var sm2 = try SplitManager.initFromJson(allocator, json);
    defer sm2.deinit();

    try std.testing.expectEqual(sm1.focused_pane_id, sm2.focused_pane_id);
    try std.testing.expectEqual(sm1.next_pane_id, sm2.next_pane_id);
    try std.testing.expect(sm2.hasSplits());
    try std.testing.expectEqual(sm1.countPanes(), sm2.countPanes());

    sm1.deinit();
}
