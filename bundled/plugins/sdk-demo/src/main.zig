//! SDK demo plugin.
//!
//! This plugin intentionally touches most stable wasm host APIs through
//! `bundled/plugins/sdk/stem.zig` so plugin authors have a compact
//! example to copy from.

const std = @import("std");
const stem = @import("stem");

const CMD_REPORT = "sdk-demo.report";
const CMD_INSPECT = "sdk-demo.inspect_buffer";
const CMD_PANEL = "sdk-demo.toggle_panel";

const STATUS_ID = "sdk_demo.status";
const PANEL_ID = "sdk_demo.panel";

const COMMANDS = [_]stem.Command{
    .{
        .id = CMD_REPORT,
        .title = "[SDK Demo] Report",
        .description = "Open a report built with the Stem plugin SDK",
    },
    .{
        .id = CMD_INSPECT,
        .title = "[SDK Demo] Inspect Buffer",
        .description = "Summarize the active buffer through the SDK host API",
    },
    .{
        .id = CMD_PANEL,
        .title = "[SDK Demo] Toggle Panel",
        .description = "Toggle a sample plugin panel",
    },
};

var scratch: [256 * 1024]u8 = undefined;
var rendered: [320 * 1024]u8 = undefined;
var rendered_len: usize = 0;
var panel_visible = false;

export fn activate() void {
    stem.registerCommands(COMMANDS);
    _ = stem.subscribeEvent("buffer.switched");
    _ = stem.subscribeEvent("file.saved");

    const activations = stem.storageReadU32("activations", 0) +| 1;
    stem.storageWriteU32("activations", activations);
    updateStatus("ready");
    stem.log(.info, "sdk_demo plugin: ready");
}

export fn deactivate() void {
    stem.clearStatusItem(STATUS_ID);
    stem.clearPanel(PANEL_ID);
}

export fn handle_command(id_ptr: [*]const u8, id_len: i32) void {
    const id = stem.fromRaw(id_ptr, id_len);
    if (std.mem.eql(u8, id, CMD_REPORT)) {
        openSdkReport();
    } else if (std.mem.eql(u8, id, CMD_INSPECT)) {
        inspectActiveBuffer();
    } else if (std.mem.eql(u8, id, CMD_PANEL)) {
        togglePanel();
    }
}

export fn handle_event(
    topic_ptr: [*]const u8,
    topic_len: i32,
    data_ptr: [*]const u8,
    data_len: i32,
) void {
    const topic = stem.fromRaw(topic_ptr, topic_len);
    const data = stem.fromRaw(data_ptr, data_len);
    _ = data;

    const events = stem.storageReadU32("events", 0) +| 1;
    stem.storageWriteU32("events", events);

    var buf: [96]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "SDK: {s} ({d})", .{ topic, events }) catch "SDK: event";
    stem.setStatusItem(STATUS_ID, text, .right, 9);
}

fn openSdkReport() void {
    const opens = stem.storageReadU32("reports", 0) +| 1;
    stem.storageWriteU32("reports", opens);

    rendered_len = 0;
    append("# SDK Demo\n\n");
    append("- Source: bundled/plugins/sdk-demo/src/main.zig\n");
    append("- SDK: bundled/plugins/sdk/stem.zig\n");
    appendFmt("- Activations: {d}\n", .{stem.storageReadU32("activations", 0)});
    appendFmt("- Reports opened: {d}\n", .{opens});
    appendFmt("- Events observed: {d}\n\n", .{stem.storageReadU32("events", 0)});

    append("## Host Plugin Dashboard\n\n");
    const n = stem.pluginDashboardReport(&scratch);
    if (n > 0) {
        append(scratch[0..@intCast(n)]);
    } else {
        append("Dashboard report unavailable.\n");
    }

    stem.openBuffer("[SDK Demo]", rendered[0..rendered_len]);
}

fn inspectActiveBuffer() void {
    rendered_len = 0;
    append("# Active Buffer\n\n");

    var path_buf: [1024]u8 = undefined;
    const path_n = stem.activeBufferPath(&path_buf);
    if (path_n > 0) {
        append("- Path: ");
        append(path_buf[0..@intCast(path_n)]);
        append("\n");
    } else {
        append("- Path: unavailable\n");
    }

    const content_n = stem.activeBufferContent(&scratch);
    if (content_n > 0) {
        const content = scratch[0..@intCast(content_n)];
        const lines = std.mem.count(u8, content, "\n") + 1;
        appendFmt("- Bytes: {d}\n", .{content.len});
        appendFmt("- Lines: {d}\n\n", .{lines});
        append("## Preview\n\n```text\n");
        append(content[0..@min(content.len, 4096)]);
        if (content.len > 4096) append("\n... truncated ...\n");
        append("\n```\n");
    } else {
        append("- Content: unavailable\n");
    }

    stem.openBuffer("[SDK Demo Buffer]", rendered[0..rendered_len]);
}

fn togglePanel() void {
    if (panel_visible) {
        panel_visible = false;
        stem.clearPanel(PANEL_ID);
        updateStatus("panel off");
        return;
    }

    rendered_len = 0;
    append("SDK Demo Panel\n\n");
    append("This panel is owned by a wasm plugin using the SDK.\n\n");
    appendFmt("activations: {d}\n", .{stem.storageReadU32("activations", 0)});
    appendFmt("events:      {d}\n", .{stem.storageReadU32("events", 0)});
    appendFmt("reports:     {d}\n", .{stem.storageReadU32("reports", 0)});

    panel_visible = true;
    stem.setPanel(PANEL_ID, "SDK Demo", rendered[0..rendered_len], .right, 24);
    updateStatus("panel on");
}

fn updateStatus(state: []const u8) void {
    var buf: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "SDK: {s}", .{state}) catch "SDK";
    stem.setStatusItem(STATUS_ID, text, .right, 9);
}

fn append(s: []const u8) void {
    const remaining = rendered.len - rendered_len;
    const n = @min(s.len, remaining);
    @memcpy(rendered[rendered_len .. rendered_len + n], s[0..n]);
    rendered_len += n;
}

fn appendFmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    append(text);
}
