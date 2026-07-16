const std = @import("std");
const protocol = @import("../kernel/protocol.zig");

pub const LifecycleTopic = enum {
    plugin_crashed,
    plugin_restart_scheduled,
    lsp_crashed,
    lsp_restart_scheduled,
    worker_crashed,
    worker_restart_scheduled,
};

/// Stable topic names declared by plugin manifests and delivered to plugin
/// event subscribers.
pub fn pluginEventTopic(event: protocol.PluginEvent) []const u8 {
    return switch (event) {
        .buffer_changed => "buffer.changed",
        .cursor_moved => "cursor.moved",
        .mode_changed => "mode.changed",
        .file_saved => "file.saved",
        .file_opened => "file.opened",
        .buffer_switched => "buffer.switched",
        .custom_event => "custom",
    };
}

/// Namespaced pub/sub topic for editor events. These are additive to the
/// manifest-facing topics above, so external observers can subscribe to
/// `editor.#` without colliding with plugin permission names.
pub fn editorEventTopic(event: protocol.PluginEvent) []const u8 {
    return switch (event) {
        .buffer_changed => "editor.buffer.changed",
        .cursor_moved => "editor.cursor.moved",
        .mode_changed => "editor.mode.changed",
        .file_saved => "editor.file.saved",
        .file_opened => "editor.file.opened",
        .buffer_switched => "editor.buffer.switched",
        .custom_event => "editor.custom",
    };
}

pub fn eventFromTopic(topic: []const u8) ?protocol.PluginEvent {
    const map = .{
        .{ "buffer.changed", "editor.buffer.changed", protocol.PluginEvent.buffer_changed },
        .{ "cursor.moved", "editor.cursor.moved", protocol.PluginEvent.cursor_moved },
        .{ "mode.changed", "editor.mode.changed", protocol.PluginEvent.mode_changed },
        .{ "file.saved", "editor.file.saved", protocol.PluginEvent.file_saved },
        .{ "file.opened", "editor.file.opened", protocol.PluginEvent.file_opened },
        .{ "buffer.switched", "editor.buffer.switched", protocol.PluginEvent.buffer_switched },
        .{ "custom", "editor.custom", protocol.PluginEvent.custom_event },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, topic, entry[0]) or std.mem.eql(u8, topic, entry[1])) return entry[2];
    }
    return null;
}

pub fn lifecycleTopic(topic: LifecycleTopic) []const u8 {
    return switch (topic) {
        .plugin_crashed => "runtime.plugin.crashed",
        .plugin_restart_scheduled => "runtime.plugin.restart_scheduled",
        .lsp_crashed => "runtime.lsp.crashed",
        .lsp_restart_scheduled => "runtime.lsp.restart_scheduled",
        .worker_crashed => "runtime.worker.crashed",
        .worker_restart_scheduled => "runtime.worker.restart_scheduled",
    };
}

test "event topics expose legacy and namespaced plugin event topics" {
    try std.testing.expectEqualStrings("buffer.changed", pluginEventTopic(.buffer_changed));
    try std.testing.expectEqualStrings("editor.buffer.changed", editorEventTopic(.buffer_changed));
    try std.testing.expectEqual(protocol.PluginEvent.buffer_changed, eventFromTopic("buffer.changed").?);
    try std.testing.expectEqual(protocol.PluginEvent.buffer_changed, eventFromTopic("editor.buffer.changed").?);
}

test "event topics expose lifecycle topics for supervisors" {
    try std.testing.expectEqualStrings("runtime.plugin.crashed", lifecycleTopic(.plugin_crashed));
    try std.testing.expectEqualStrings("runtime.plugin.restart_scheduled", lifecycleTopic(.plugin_restart_scheduled));
    try std.testing.expectEqualStrings("runtime.lsp.restart_scheduled", lifecycleTopic(.lsp_restart_scheduled));
}
