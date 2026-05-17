const std = @import("std");
const log = std.log.scoped(.UIManager);
const protocol = @import("../kernel/protocol.zig");

pub const WidgetMeta = struct {
    plugin_id: []const u8,
    widget_type: []const u8,
    created_at: i64,
};

pub const UIManager = struct {
    allocator: std.mem.Allocator,

    widget_counter: std.atomic.Value(u64),
    widgets: std.AutoHashMapUnmanaged(protocol.WidgetID, WidgetMeta),

    status_items: std.StringHashMapUnmanaged(StatusItemData),

    panels: std.StringHashMapUnmanaged(PanelData),

    const StatusItemData = struct {
        id: []const u8,
        plugin_id: []const u8,
        text: []const u8,
        alignment: protocol.StatusAlignment,
        priority: i8,
        widget_id: protocol.WidgetID,
    };

    const PanelData = struct {
        id: []const u8,
        plugin_id: []const u8,
        title: []const u8,
        content: [][]const u8,
        position: protocol.PanelPosition,
        width_percent: u8,
        widget_id: protocol.WidgetID,
        scroll_offset: u32,
    };

    pub fn init(allocator: std.mem.Allocator) UIManager {
        return .{
            .allocator = allocator,
            .widget_counter = std.atomic.Value(u64).init(0),
            .widgets = .{},
            .status_items = .{},
            .panels = .{},
        };
    }

    pub fn deinit(self: *UIManager) void {
        var widget_it = self.widgets.valueIterator();
        while (widget_it.next()) |meta| {
            self.allocator.free(meta.plugin_id);
            self.allocator.free(meta.widget_type);
        }
        self.widgets.deinit(self.allocator);

        var status_it = self.status_items.iterator();
        while (status_it.next()) |entry| {
            self.freeStatusItemData(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.status_items.deinit(self.allocator);

        var panel_it = self.panels.iterator();
        while (panel_it.next()) |entry| {
            self.freePanelData(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.panels.deinit(self.allocator);
    }

    fn freeStatusItemData(self: *UIManager, data: StatusItemData) void {
        self.allocator.free(data.id);
        self.allocator.free(data.plugin_id);
        self.allocator.free(data.text);
    }

    fn freePanelData(self: *UIManager, data: PanelData) void {
        self.allocator.free(data.id);
        self.allocator.free(data.plugin_id);
        self.allocator.free(data.title);
        for (data.content) |line| {
            self.allocator.free(line);
        }
        if (data.content.len > 0) {
            self.allocator.free(data.content);
        }
    }

    pub fn createWidgetId(
        self: *UIManager,
        plugin_id: []const u8,
        widget_type: []const u8,
    ) !protocol.WidgetID {
        const id = self.widget_counter.fetchAdd(1, .monotonic) + 1;

        const meta = WidgetMeta{
            .plugin_id = try self.allocator.dupe(u8, plugin_id),
            .widget_type = try self.allocator.dupe(u8, widget_type),
            // TODO(zig-0.16): thread io into UIManager to populate this with real time
            .created_at = 0,
        };

        try self.widgets.put(self.allocator, id, meta);
        return id;
    }

    pub fn destroyWidgetId(self: *UIManager, widget_id: protocol.WidgetID) void {
        if (self.widgets.fetchRemove(widget_id)) |kv| {
            self.allocator.free(kv.value.plugin_id);
            self.allocator.free(kv.value.widget_type);
        }
    }

    pub fn cleanupPluginWidgets(self: *UIManager, plugin_id: []const u8) void {
        var status_keys_to_remove = std.ArrayListUnmanaged([]const u8).empty;
        defer status_keys_to_remove.deinit(self.allocator);

        var status_it = self.status_items.iterator();
        while (status_it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.plugin_id, plugin_id)) {
                status_keys_to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (status_keys_to_remove.items) |key| {
            if (self.status_items.fetchRemove(key)) |kv| {
                self.destroyWidgetId(kv.value.widget_id);
                self.freeStatusItemData(kv.value);
                self.allocator.free(kv.key);
            }
        }

        var panel_keys_to_remove = std.ArrayListUnmanaged([]const u8).empty;
        defer panel_keys_to_remove.deinit(self.allocator);

        var panel_it = self.panels.iterator();
        while (panel_it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.plugin_id, plugin_id)) {
                panel_keys_to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (panel_keys_to_remove.items) |key| {
            if (self.panels.fetchRemove(key)) |kv| {
                self.destroyWidgetId(kv.value.widget_id);
                self.freePanelData(kv.value);
                self.allocator.free(kv.key);
            }
        }

        var widget_ids_to_remove = std.ArrayListUnmanaged(protocol.WidgetID).initCapacity(self.allocator, 8) catch return;
        defer widget_ids_to_remove.deinit(self.allocator);

        var widget_it = self.widgets.iterator();
        while (widget_it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.plugin_id, plugin_id)) {
                widget_ids_to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (widget_ids_to_remove.items) |id| {
            if (self.widgets.fetchRemove(id)) |kv| {
                self.allocator.free(kv.value.plugin_id);
                self.allocator.free(kv.value.widget_type);
            }
        }
    }

    pub fn getPluginWidgetCount(self: *const UIManager, plugin_id: []const u8) u32 {
        var count: u32 = 0;
        var it = self.widgets.valueIterator();
        while (it.next()) |meta| {
            if (std.mem.eql(u8, meta.plugin_id, plugin_id)) {
                count += 1;
            }
        }
        return count;
    }

    pub fn createStatusItem(
        self: *UIManager,
        plugin_id: []const u8,
        id: []const u8,
        text: []const u8,
        alignment: protocol.StatusAlignment,
        priority: i8,
    ) !void {
        const key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ plugin_id, id });
        errdefer self.allocator.free(key);

        const widget_id = try self.createWidgetId(plugin_id, "status_item");
        errdefer self.destroyWidgetId(widget_id);

        const id_dupe = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(id_dupe);

        const plugin_id_dupe = try self.allocator.dupe(u8, plugin_id);
        errdefer self.allocator.free(plugin_id_dupe);

        const text_dupe = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(text_dupe);

        const data = StatusItemData{
            .id = id_dupe,
            .plugin_id = plugin_id_dupe,
            .text = text_dupe,
            .alignment = alignment,
            .priority = priority,
            .widget_id = widget_id,
        };

        if (self.status_items.fetchRemove(key)) |old| {
            self.destroyWidgetId(old.value.widget_id);
            self.freeStatusItemData(old.value);
            self.allocator.free(old.key);
        }

        try self.status_items.put(self.allocator, key, data);
        log.info("UIManager: Created status item '{s}' for plugin '{s}'", .{ id, plugin_id });
    }

    pub fn updateStatusItem(self: *UIManager, plugin_id: []const u8, id: []const u8, text: []const u8) !void {
        var buf: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}:{s}", .{ plugin_id, id }) catch return error.IdTooLong;
        if (self.status_items.getPtr(key)) |data| {
            self.allocator.free(data.text);
            data.text = try self.allocator.dupe(u8, text);
            log.debug("UIManager: Updated status item '{s}' for plugin '{s}'", .{ id, plugin_id });
        } else {
            log.warn("UIManager: Status item '{s}' not found for plugin '{s}' update", .{ id, plugin_id });
            return error.ItemNotFound;
        }
    }

    pub fn destroyStatusItem(self: *UIManager, plugin_id: []const u8, id: []const u8) void {
        var buf: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}:{s}", .{ plugin_id, id }) catch return;
        if (self.status_items.fetchRemove(key)) |kv| {
            self.destroyWidgetId(kv.value.widget_id);
            self.freeStatusItemData(kv.value);
            self.allocator.free(kv.key);
            log.info("UIManager: Destroyed status item '{s}' for plugin '{s}'", .{ id, plugin_id });
        }
    }

    pub fn getStatusItems(self: *UIManager, allocator: std.mem.Allocator) ![]protocol.StatusItem {
        var items = std.ArrayListUnmanaged(protocol.StatusItem).empty;
        errdefer items.deinit(allocator);

        var it = self.status_items.valueIterator();
        while (it.next()) |data| {
            try items.append(allocator, .{
                .id = data.id,
                .plugin_id = data.plugin_id,
                .text = data.text,
                .alignment = data.alignment,
                .priority = data.priority,
                .widget_id = data.widget_id,
            });
        }

        std.mem.sort(protocol.StatusItem, items.items, {}, struct {
            fn lessThan(_: void, a: protocol.StatusItem, b: protocol.StatusItem) bool {
                return a.priority < b.priority;
            }
        }.lessThan);

        return items.toOwnedSlice(allocator);
    }

    pub fn createPanel(
        self: *UIManager,
        plugin_id: []const u8,
        id: []const u8,
        title: []const u8,
        position: protocol.PanelPosition,
        width_percent: u8,
    ) !void {
        const key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ plugin_id, id });
        errdefer self.allocator.free(key);

        const clamped_width = @min(@max(width_percent, 10), 50);

        const widget_id = try self.createWidgetId(plugin_id, "panel");
        errdefer self.destroyWidgetId(widget_id);

        const id_dupe = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(id_dupe);

        const plugin_id_dupe = try self.allocator.dupe(u8, plugin_id);
        errdefer self.allocator.free(plugin_id_dupe);

        const title_dupe = try self.allocator.dupe(u8, title);
        errdefer self.allocator.free(title_dupe);

        const data = PanelData{
            .id = id_dupe,
            .plugin_id = plugin_id_dupe,
            .title = title_dupe,
            .content = &.{},
            .position = position,
            .width_percent = clamped_width,
            .widget_id = widget_id,
            .scroll_offset = 0,
        };

        if (self.panels.fetchRemove(key)) |old| {
            self.destroyWidgetId(old.value.widget_id);
            self.freePanelData(old.value);
            self.allocator.free(old.key);
        }

        try self.panels.put(self.allocator, key, data);
        log.info("UIManager: Created panel '{s}' for plugin '{s}'", .{ id, plugin_id });
    }

    pub fn updatePanelContent(self: *UIManager, plugin_id: []const u8, id: []const u8, content: []const u8) !void {
        var buf: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}:{s}", .{ plugin_id, id }) catch return error.IdTooLong;
        if (self.panels.getPtr(key)) |data| {
            for (data.content) |line| {
                self.allocator.free(line);
            }
            if (data.content.len > 0) {
                self.allocator.free(data.content);
            }

            var lines = std.ArrayListUnmanaged([]const u8).empty;
            errdefer {
                for (lines.items) |l| self.allocator.free(l);
                lines.deinit(self.allocator);
            }

            var offset: usize = 0;
            while (offset < content.len) {
                if (content.len < offset + 4) break;
                const len = std.mem.readInt(u32, content[offset..][0..4], .big);
                offset += 4;
                if (content.len < offset + len) break;

                const line_slice = content[offset..][0..len];
                offset += len;

                const duped = try self.allocator.dupe(u8, line_slice);
                try lines.append(self.allocator, duped);
            }

            data.content = try lines.toOwnedSlice(self.allocator);
            log.debug("UIManager: Updated panel '{s}' content for plugin '{s}' ({d} lines)", .{ id, plugin_id, data.content.len });
        } else {
            log.warn("UIManager: Panel '{s}' not found for plugin '{s}' update", .{ id, plugin_id });
            return error.PanelNotFound;
        }
    }

    pub fn updatePanelScroll(self: *UIManager, plugin_id: []const u8, id: []const u8, offset: u32) !void {
        var buf: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}:{s}", .{ plugin_id, id }) catch return error.IdTooLong;
        if (self.panels.getPtr(key)) |data| {
            data.scroll_offset = offset;
        } else {
            return error.PanelNotFound;
        }
    }

    pub fn destroyPanel(self: *UIManager, plugin_id: []const u8, id: []const u8) void {
        var buf: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}:{s}", .{ plugin_id, id }) catch return;
        if (self.panels.fetchRemove(key)) |kv| {
            self.destroyWidgetId(kv.value.widget_id);
            self.freePanelData(kv.value);
            self.allocator.free(kv.key);
            log.info("UIManager: Destroyed panel '{s}' for plugin '{s}'", .{ id, plugin_id });
        }
    }

    pub fn getPanels(self: *UIManager, allocator: std.mem.Allocator) ![]protocol.PanelInfo {
        var items = std.ArrayListUnmanaged(protocol.PanelInfo).empty;
        errdefer items.deinit(allocator);

        var it = self.panels.valueIterator();
        while (it.next()) |data| {
            const new_content = try allocator.alloc([]const u8, data.content.len);
            for (data.content, 0..) |line, j| {
                new_content[j] = try allocator.dupe(u8, line);
            }

            try items.append(allocator, .{
                .id = try allocator.dupe(u8, data.id),
                .plugin_id = try allocator.dupe(u8, data.plugin_id),
                .title = try allocator.dupe(u8, data.title),
                .content = new_content,
                .position = data.position,
                .width_percent = data.width_percent,
                .widget_id = data.widget_id,
                .scroll_offset = data.scroll_offset,
            });
        }

        return items.toOwnedSlice(allocator);
    }

    pub fn freePanels(allocator: std.mem.Allocator, panels: []protocol.PanelInfo) void {
        for (panels) |panel| {
            allocator.free(panel.id);
            allocator.free(panel.plugin_id);
            allocator.free(panel.title);
            for (panel.content) |line| {
                allocator.free(line);
            }
            allocator.free(panel.content);
        }
        allocator.free(panels);
    }

    pub fn getWidgetCount(self: *UIManager) usize {
        return self.widgets.count();
    }

    pub fn getStatusItemCount(self: *UIManager) usize {
        return self.status_items.count();
    }

    pub fn getPanelCount(self: *UIManager) usize {
        return self.panels.count();
    }
};

test "UIManager basic widget ID generation" {
    var manager = UIManager.init(std.testing.allocator);
    defer manager.deinit();

    const id1 = try manager.createWidgetId("test-plugin", "status_item");
    const id2 = try manager.createWidgetId("test-plugin", "panel");

    try std.testing.expect(id1 != id2);
    try std.testing.expectEqual(@as(usize, 2), manager.getWidgetCount());
}

test "UIManager status item lifecycle" {
    var manager = UIManager.init(std.testing.allocator);
    defer manager.deinit();

    try manager.createStatusItem("plugin1", "status1", "Hello", .left, 0);
    try std.testing.expectEqual(@as(usize, 1), manager.getStatusItemCount());

    try manager.updateStatusItem("plugin1", "status1", "Updated");

    const items = try manager.getStatusItems(std.testing.allocator);
    defer std.testing.allocator.free(items);
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("Updated", items[0].text);

    manager.destroyStatusItem("plugin1", "status1");
    try std.testing.expectEqual(@as(usize, 0), manager.getStatusItemCount());
}

test "UIManager isolation" {
    var manager = UIManager.init(std.testing.allocator);
    defer manager.deinit();

    try manager.createStatusItem("plugin1", "shared", "P1", .left, 0);
    try manager.createStatusItem("plugin2", "shared", "P2", .right, 0);

    try std.testing.expectEqual(@as(usize, 2), manager.getStatusItemCount());

    const items = try manager.getStatusItems(std.testing.allocator);
    defer std.testing.allocator.free(items);
    try std.testing.expectEqual(@as(usize, 2), items.len);
}

test "UIManager panel lifecycle" {
    var manager = UIManager.init(std.testing.allocator);
    defer manager.deinit();

    try manager.createPanel("plugin1", "panel1", "Test Panel", .right, 25);
    try std.testing.expectEqual(@as(usize, 1), manager.getPanelCount());

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const cb_writer = &aw.writer;
    const lines = &[_][]const u8{ "Line 1", "Line 2" };
    for (lines) |line| {
        try cb_writer.writeInt(u32, @intCast(line.len), .big);
        try cb_writer.writeAll(line);
    }

    try manager.updatePanelContent("plugin1", "panel1", aw.written());

    const panels = try manager.getPanels(std.testing.allocator);
    defer UIManager.freePanels(std.testing.allocator, panels);
    try std.testing.expectEqual(@as(usize, 1), panels.len);
    try std.testing.expectEqual(@as(usize, 2), panels[0].content.len);

    manager.destroyPanel("plugin1", "panel1");
    try std.testing.expectEqual(@as(usize, 0), manager.getPanelCount());
}

test "UIManager plugin cleanup" {
    var manager = UIManager.init(std.testing.allocator);
    defer manager.deinit();

    try manager.createStatusItem("plugin1", "s1", "P1 Status", .left, 0);
    try manager.createStatusItem("plugin2", "s2", "P2 Status", .right, 0);
    try manager.createPanel("plugin1", "p1", "P1 Panel", .left, 20);

    try std.testing.expectEqual(@as(usize, 2), manager.getStatusItemCount());
    try std.testing.expectEqual(@as(usize, 1), manager.getPanelCount());

    manager.cleanupPluginWidgets("plugin1");

    try std.testing.expectEqual(@as(usize, 1), manager.getStatusItemCount());
    try std.testing.expectEqual(@as(usize, 0), manager.getPanelCount());
}
