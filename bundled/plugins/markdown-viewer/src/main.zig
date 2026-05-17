const std = @import("std");
const stem = @import("stem");

// State: Mapping from Preview Buffer Name -> Original Buffer ID
var preview_map: std.StringHashMap(u32) = undefined;
var map_initialized = false;
var status_item_created = false;

// Panel State
var panel_active = false;
var tracked_buffer_name: ?[]u8 = null;

// Allocator for the plugin
var allocator: std.mem.Allocator = undefined;

fn init(ctx: *stem.PluginContext) i32 {
    allocator = ctx.allocator;

    if (!map_initialized) {
        preview_map = std.StringHashMap(u32).init(allocator);
        map_initialized = true;
    }

    // Register commands
    stem.registerCommand(
        ctx,
        "markdown.preview",
        "[Markdown] Preview",
        "Render current markdown file in Display mode",
        cmdPreview,
    ) catch {
        return -1;
    };

    stem.registerCommand(
        ctx,
        "markdown.edit",
        "[Markdown] Edit",
        "Switch back to Edit mode",
        cmdEdit,
    ) catch {
        return -1;
    };

    // Subscribe to buffer switch
    stem.subscribeEvent(ctx, .buffer_switched, onBufferSwitched) catch {
        stem.log(ctx, "Failed to subscribe to buffer_switched", .{});
    };

    // Subscribe to buffer change for live preview
    stem.subscribeEvent(ctx, .buffer_changed, onBufferChanged) catch {};

    // Subscribe to cursor move for scroll sync
    stem.subscribeEvent(ctx, .cursor_moved, onCursorMoved) catch {};

    // Register toggle panel command
    stem.registerCommand(
        ctx,
        "markdown.toggle_panel",
        "[Markdown] Toggle Preview Panel",
        "Toggle side panel preview",
        cmdTogglePanel,
    ) catch {
        return -1;
    };

    // Create status item (initially hidden)
    stem.createStatusItem(ctx, "markdown.mode", "", .right, 50) catch {};
    status_item_created = true;

    return 0;
}

fn deinit(ctx: *stem.PluginContext) void {
    if (status_item_created) {
        stem.destroyStatusItem(ctx, "markdown.mode") catch {};
    }
    stem.deinitSdk(ctx);
    if (map_initialized) {
        var it = preview_map.keyIterator();
        while (it.next()) |key| {
            allocator.free(key.*);
        }
        preview_map.deinit();
        map_initialized = false;
    }
}

fn handleMessage(ctx: *stem.PluginContext, msg: *const stem.PluginMessage) i32 {
    if (stem.handleStandardMessages(ctx, msg)) {
        return 0;
    }
    return 0;
}

fn onBufferSwitched(ctx: *stem.PluginContext, data: []const u8) void {
    const is_preview = preview_map.contains(data);
    const text = if (is_preview) "Markdown: Preview" else "";
    stem.updateStatusItem(ctx, "markdown.mode", text) catch {};
}

// Global context for callbacks (since they can't capture)
var plugin_context: ?*stem.PluginContext = null;

fn cmdPreview(ctx: *stem.PluginContext) void {
    plugin_context = ctx;
    // 1. Get current state to know file name and ID
    stem.requestEditorState(ctx, onStateForPreview) catch {};
}

fn onStateForPreview(ctx: *stem.PluginContext, state: stem.EditorStateView) void {
    // Check if file is markdown
    var is_markdown = false;
    if (state.file_path) |path| {
        if (std.mem.endsWith(u8, path, ".md")) {
            is_markdown = true;
        }
    }

    // Allow previewing untitled buffers too if they look like markdown?
    // For now strict check on extension or if manually invoked.
    // Let's assume user knows what they are doing if they invoked the command.

    // Store original ID to use in the content callback
    // We can't pass userdata to callback, so we need a global or stash it in the context?
    // Plugin context is consistent. We can use a global slot given single-threadedness.
    pending_original_id = state.buffer_id;
    if (state.file_path) |p| {
        // extract basename
        const basename = std.fs.path.basename(p);
        // format preview name: [Preview] filename.md
        const name = std.fmt.allocPrint(allocator, "[Preview] {s}", .{basename}) catch "Preview";
        pending_preview_name = name;
    } else {
        const name = std.fmt.allocPrint(allocator, "[Preview] {s}", .{state.buffer_name}) catch "Preview";
        pending_preview_name = name;
    }

    // 2. Get content
    stem.getBufferContent(ctx, onContentForPreview) catch {};
}

var pending_original_id: u32 = 0;
var pending_preview_name: []const u8 = "";

fn onContentForPreview(ctx: *stem.PluginContext, id: u32, content: []const u8) void {
    _ = id;

    // Handle empty content edge case
    if (content.len == 0) {
        return;
    }

    // 3. Render content
    const rendered = renderMarkdown(allocator, content) catch {
        return;
    };

    // 4. Open preview buffer
    stem.openBuffer(ctx, pending_preview_name, rendered) catch {
        allocator.free(rendered); // Free on error
        return;
    };

    // Free the rendered content after openBuffer has encoded and sent the message
    allocator.free(rendered);

    // 5. Store mapping: Preview Name -> Original ID
    const res = preview_map.getOrPut(pending_preview_name) catch return;
    if (res.found_existing) {
        res.value_ptr.* = pending_original_id;
        allocator.free(pending_preview_name);
    } else {
        res.value_ptr.* = pending_original_id;
    }
}

fn cmdEdit(ctx: *stem.PluginContext) void {
    // 1. Get current state to know buffer name
    stem.requestEditorState(ctx, onStateForEdit) catch {};
}

fn onStateForEdit(ctx: *stem.PluginContext, state: stem.EditorStateView) void {
    // Check if current buffer name is in our preview map
    if (preview_map.get(state.buffer_name)) |original_id| {
        // Switch back
        stem.switchBuffer(ctx, original_id) catch {};
    } else {
        stem.showInfo(ctx, "Not in a Preview buffer") catch {};
    }
}

// Simple Markdown Renderer
// Strips common markdown syntax to pretend to be "Display" mode

fn onBufferChanged(ctx: *stem.PluginContext, data: []const u8) void {
    // data is buffer_name
    if (!panel_active) return;

    // Check if changed buffer is the one we are tracking
    if (tracked_buffer_name) |tracked| {
        if (std.mem.eql(u8, tracked, data)) {
            // Refresh panel content
            stem.getBufferContent(ctx, onContentForPanel) catch {};
        }
    }
}

fn onCursorMoved(ctx: *stem.PluginContext, data: []const u8) void {
    _ = data;
    if (panel_active) {
        stem.requestEditorState(ctx, onStateForScroll) catch {};
    }
}

fn onStateForScroll(ctx: *stem.PluginContext, state: stem.EditorStateView) void {
    // Check if we are in the tracked buffer
    if (tracked_buffer_name) |tracked| {
        if (!std.mem.eql(u8, tracked, state.buffer_name)) return;
    }

    // Simple scroll sync
    const offset = if (state.cursor_row > 5) @as(u32, @intCast(state.cursor_row - 5)) else 0;
    stem.updatePanelScroll(ctx, "markdown.preview_panel", offset) catch {};
}

fn cmdTogglePanel(ctx: *stem.PluginContext) void {
    if (panel_active) {
        stem.destroyPanel(ctx, "markdown.preview_panel") catch {};
        panel_active = false;
        if (tracked_buffer_name) |n| allocator.free(n);
        tracked_buffer_name = null;
    } else {
        // Start tracking current buffer
        stem.requestEditorState(ctx, onStateForPanel) catch {};
    }
}

fn onStateForPanel(ctx: *stem.PluginContext, state: stem.EditorStateView) void {
    if (tracked_buffer_name) |n| allocator.free(n);
    tracked_buffer_name = allocator.dupe(u8, state.buffer_name) catch return;

    stem.createPanel(ctx, "markdown.preview_panel", "Markdown Preview", .right, 40) catch return;
    panel_active = true;

    // Initial content load
    stem.getBufferContent(ctx, onContentForPanel) catch {};
}

fn onContentForPanel(ctx: *stem.PluginContext, id: u32, content: []const u8) void {
    _ = id;
    if (!panel_active) return;

    const lines = renderMarkdownLines(allocator, content) catch return;
    defer {
        for (lines) |line| allocator.free(line);
        allocator.free(lines);
    }

    stem.updatePanelContent(ctx, "markdown.preview_panel", lines) catch {};
}

// Refactored Renderer to return enhanced lines
fn renderMarkdownLines(alloc: std.mem.Allocator, input: []const u8) ![][]const u8 {
    var output = std.ArrayListUnmanaged([]const u8).empty;
    errdefer {
        for (output.items) |item| alloc.free(item);
        output.deinit(alloc);
    }

    var in_code_block = false;
    var it = std.mem.splitScalar(u8, input, '\n');

    while (it.next()) |line| {
        // Handle code blocks - preserve them fully!
        if (std.mem.startsWith(u8, line, "```")) {
            in_code_block = !in_code_block;
            try output.append(alloc, try alloc.dupe(u8, line));
            continue;
        }

        if (in_code_block) {
            // Indent code content for better readability?
            // Or just keep as is for correct copying. Let's keep as is.
            try output.append(alloc, try alloc.dupe(u8, line));
            continue;
        }

        const trimmed = std.mem.trim(u8, line, " \t\r");
        var rendered_line: []u8 = undefined;

        if (std.mem.startsWith(u8, trimmed, "#")) {
            // Keep headers as is for highlighting, maybe ensures space?
            rendered_line = try alloc.dupe(u8, line);
        } else if (std.mem.startsWith(u8, trimmed, "- ") or std.mem.startsWith(u8, trimmed, "* ")) {
            // Beautify lists: "- item" -> "  • item"
            // We need to keep the content after the marker
            const content = trimmed[2..];
            rendered_line = try std.fmt.allocPrint(alloc, "  • {s}", .{content});
        } else if (std.mem.startsWith(u8, trimmed, ">")) {
            // Blockquotes - keep as is for highlighting
            rendered_line = try alloc.dupe(u8, line);
        } else if (std.mem.startsWith(u8, trimmed, "---") or std.mem.startsWith(u8, trimmed, "***")) {
            // Horizontal rules
            rendered_line = try alloc.dupe(u8, line);
        } else {
            // Normal text - preserve syntax markers (*, _, `) so highlighting works!
            // Do NOT strip them.
            rendered_line = try alloc.dupe(u8, line);
        }
        try output.append(alloc, rendered_line);
    }

    return output.toOwnedSlice(alloc);
}

// Keep old renderMarkdown for the preview buffer command
fn renderMarkdown(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    // ... (logic from before, or wrap renderMarkdownLines)
    const lines = try renderMarkdownLines(alloc, input);
    defer {
        for (lines) |line| alloc.free(line);
        alloc.free(lines);
    }

    var output = std.ArrayListUnmanaged(u8).empty;
    for (lines) |line| {
        try output.appendSlice(alloc, line);
        try output.append(alloc, '\n');
    }
    return output.toOwnedSlice(alloc);
}

pub export const plugin_entry = stem.createPlugin(.{
    .name = "markdown_viewer",
    .description = "Markdown Preview Plugin",
    .init = init,
    .deinit = deinit,
    .handleMessage = handleMessage,
});
