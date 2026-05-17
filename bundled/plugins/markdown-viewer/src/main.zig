//! Markdown Viewer plugin (v3 ABI).

const std = @import("std");
const stem = @import("stem");

const A = std.heap.page_allocator;

var preview_map: std.StringHashMapUnmanaged(u32) = .empty;
var status_item_created = false;
var panel_active = false;
var tracked_buffer_name: ?[]u8 = null;
var pending_original_id: u32 = 0;
var pending_preview_name: []const u8 = "";

fn activate(handle: stem.PluginHandle) callconv(.c) i32 {
    stem.bind(handle);

    stem.registerCommand(handle, "markdown.preview", "[Markdown] Preview", "Render current markdown file", cmdPreview) catch return -1;
    stem.registerCommand(handle, "markdown.edit", "[Markdown] Edit", "Switch back to Edit mode", cmdEdit) catch return -1;
    stem.registerCommand(handle, "markdown.toggle_panel", "[Markdown] Toggle Preview Panel", "Toggle side panel preview", cmdTogglePanel) catch return -1;

    stem.subscribeEvent(handle, .buffer_switched, onBufferSwitched) catch {};
    stem.subscribeEvent(handle, .buffer_changed, onBufferChanged) catch {};
    stem.subscribeEvent(handle, .cursor_moved, onCursorMoved) catch {};

    stem.createStatusItem(handle, "markdown.mode", "", .right, 50) catch {};
    status_item_created = true;
    return 0;
}

fn deactivate(handle: stem.PluginHandle) callconv(.c) void {
    if (status_item_created) stem.destroyStatusItem(handle, "markdown.mode") catch {};

    var it = preview_map.keyIterator();
    while (it.next()) |key| A.free(key.*);
    preview_map.deinit(A);
    preview_map = .empty;

    if (tracked_buffer_name) |n| A.free(n);
    tracked_buffer_name = null;
    stem.unbind();
}

fn handleMessage(handle: stem.PluginHandle, ptr: [*]const u8, len: usize) callconv(.c) i32 {
    return stem.dispatch(handle, ptr, len);
}

fn onBufferSwitched(handle: stem.PluginHandle, data: []const u8) void {
    const is_preview = preview_map.contains(data);
    const text: []const u8 = if (is_preview) "Markdown: Preview" else "";
    stem.updateStatusItem(handle, "markdown.mode", text) catch {};
}

fn cmdPreview(handle: stem.PluginHandle) void {
    stem.requestEditorState(handle, onStateForPreview) catch {};
}

fn onStateForPreview(handle: stem.PluginHandle, state: stem.EditorStateView) void {
    pending_original_id = state.buffer_id;
    if (state.file_path) |p| {
        const basename = std.fs.path.basename(p);
        pending_preview_name = std.fmt.allocPrint(A, "[Preview] {s}", .{basename}) catch "Preview";
    } else {
        pending_preview_name = std.fmt.allocPrint(A, "[Preview] {s}", .{state.buffer_name}) catch "Preview";
    }
    stem.getBufferContent(handle, onContentForPreview) catch {};
}

fn onContentForPreview(handle: stem.PluginHandle, _: u32, content: []const u8) void {
    if (content.len == 0) return;
    const rendered = renderMarkdown(A, content) catch return;
    defer A.free(rendered);
    stem.openBuffer(handle, pending_preview_name, rendered) catch return;

    const gop = preview_map.getOrPut(A, pending_preview_name) catch return;
    gop.value_ptr.* = pending_original_id;
    if (gop.found_existing) A.free(pending_preview_name);
}

fn cmdEdit(handle: stem.PluginHandle) void {
    stem.requestEditorState(handle, onStateForEdit) catch {};
}

fn onStateForEdit(handle: stem.PluginHandle, state: stem.EditorStateView) void {
    if (preview_map.get(state.buffer_name)) |original_id| {
        stem.switchBuffer(handle, original_id) catch {};
    } else {
        stem.showInfo(handle, "Not in a Preview buffer") catch {};
    }
}

fn onBufferChanged(handle: stem.PluginHandle, data: []const u8) void {
    if (!panel_active) return;
    if (tracked_buffer_name) |tracked| {
        if (std.mem.eql(u8, tracked, data)) stem.getBufferContent(handle, onContentForPanel) catch {};
    }
}

fn onCursorMoved(handle: stem.PluginHandle, _: []const u8) void {
    if (panel_active) stem.requestEditorState(handle, onStateForScroll) catch {};
}

fn onStateForScroll(handle: stem.PluginHandle, state: stem.EditorStateView) void {
    if (tracked_buffer_name) |tracked| if (!std.mem.eql(u8, tracked, state.buffer_name)) return;
    const offset: u32 = if (state.cursor_row > 5) @intCast(state.cursor_row - 5) else 0;
    stem.updatePanelScroll(handle, "markdown.preview_panel", offset) catch {};
}

fn cmdTogglePanel(handle: stem.PluginHandle) void {
    if (panel_active) {
        stem.destroyPanel(handle, "markdown.preview_panel") catch {};
        panel_active = false;
        if (tracked_buffer_name) |n| A.free(n);
        tracked_buffer_name = null;
    } else {
        stem.requestEditorState(handle, onStateForPanel) catch {};
    }
}

fn onStateForPanel(handle: stem.PluginHandle, state: stem.EditorStateView) void {
    if (tracked_buffer_name) |n| A.free(n);
    tracked_buffer_name = A.dupe(u8, state.buffer_name) catch return;
    stem.createPanel(handle, "markdown.preview_panel", "Markdown Preview", .right, 40) catch return;
    panel_active = true;
    stem.getBufferContent(handle, onContentForPanel) catch {};
}

fn onContentForPanel(handle: stem.PluginHandle, _: u32, content: []const u8) void {
    if (!panel_active) return;
    const lines = renderMarkdownLines(A, content) catch return;
    defer {
        for (lines) |line| A.free(line);
        A.free(lines);
    }
    stem.updatePanelContent(handle, "markdown.preview_panel", lines) catch {};
}

fn renderMarkdownLines(alloc: std.mem.Allocator, input: []const u8) ![][]const u8 {
    var output: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (output.items) |item| alloc.free(item);
        output.deinit(alloc);
    }
    var in_code_block = false;
    var it = std.mem.splitScalar(u8, input, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "```")) {
            in_code_block = !in_code_block;
            try output.append(alloc, try alloc.dupe(u8, line));
            continue;
        }
        if (in_code_block) {
            try output.append(alloc, try alloc.dupe(u8, line));
            continue;
        }
        const trimmed = std.mem.trim(u8, line, " \t\r");
        const rendered_line: []u8 = if (std.mem.startsWith(u8, trimmed, "- ") or std.mem.startsWith(u8, trimmed, "* "))
            try std.fmt.allocPrint(alloc, "  • {s}", .{trimmed[2..]})
        else
            try alloc.dupe(u8, line);
        try output.append(alloc, rendered_line);
    }
    return output.toOwnedSlice(alloc);
}

fn renderMarkdown(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    const lines = try renderMarkdownLines(alloc, input);
    defer {
        for (lines) |line| alloc.free(line);
        alloc.free(lines);
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (lines) |line| {
        try out.appendSlice(alloc, line);
        try out.append(alloc, '\n');
    }
    return out.toOwnedSlice(alloc);
}

pub export const plugin_entry = stem.createPlugin(.{
    .name = "markdown_viewer",
    .description = "Markdown Preview Plugin",
    .activate = activate,
    .deactivate = deactivate,
    .handle_message = handleMessage,
});
