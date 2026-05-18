//! Markdown viewer (wasm runtime, Phase 4 migration).
//!
//! The dylib version did three things the wasm runtime can't yet:
//!   1. Hooked `buffer_switched` / `buffer_changed` / `cursor_moved`
//!      events to refresh a status item.
//!   2. Maintained a side panel showing the rendered markdown.
//!   3. Used `requestEditorState` to know the current file path.
//!
//! All three want pieces of the wasm ABI we haven't shipped yet:
//! event dispatch, panel/status-item host imports, async req/reply.
//! For now we register the same three commands and show a
//! help-style buffer; once the wasm side gets event delivery the
//! preview pipeline can be rebuilt without changing manifest IDs or
//! palette entries.

const std = @import("std");

extern "env" fn stem_log(level: i32, msg_ptr: [*]const u8, msg_len: i32) void;
extern "env" fn stem_register_command(
    id_ptr: [*]const u8,
    id_len: i32,
    title_ptr: [*]const u8,
    title_len: i32,
    desc_ptr: [*]const u8,
    desc_len: i32,
) void;
extern "env" fn stem_open_buffer(
    name_ptr: [*]const u8,
    name_len: i32,
    content_ptr: [*]const u8,
    content_len: i32,
) void;
extern "env" fn stem_show_notification(level: i32, msg_ptr: [*]const u8, msg_len: i32) void;

const CMD_PREVIEW = "markdown.preview";
const CMD_EDIT = "markdown.edit";
const CMD_TOGGLE_PANEL = "markdown.toggle_panel";

const Cmd = struct { id: []const u8, title: []const u8, desc: []const u8 };
const COMMANDS = [_]Cmd{
    .{ .id = CMD_PREVIEW, .title = "[Markdown] Preview", .desc = "Render the current markdown file" },
    .{ .id = CMD_EDIT, .title = "[Markdown] Edit", .desc = "Switch back to edit mode" },
    .{ .id = CMD_TOGGLE_PANEL, .title = "[Markdown] Toggle Preview Panel", .desc = "Toggle a side preview panel" },
};

const PREVIEW_HINT =
    \\Markdown preview is being rebuilt on the wasm plugin runtime.
    \\
    \\Until the wasm event/panel ABIs ship, use the file directly —
    \\stem's tree-sitter syntax highlighting already styles markdown
    \\headers, code fences, and inline emphasis. For a rendered
    \\preview, pipe through pandoc / glow in a terminal split.
    \\
    \\This command is intentionally registered so the palette entry
    \\stays stable across the migration. Phase 4+ will restore the
    \\live side-panel preview.
;

const PANEL_HINT =
    \\Side-panel preview is not yet wired in the wasm runtime —
    \\panel/status-item host imports are queued for the next
    \\plugin ABI revision. The palette entry will start working
    \\again automatically once those land; no manifest change
    \\needed.
;

export fn activate() void {
    inline for (COMMANDS) |c| {
        stem_register_command(
            c.id.ptr,
            c.id.len,
            c.title.ptr,
            c.title.len,
            c.desc.ptr,
            c.desc.len,
        );
    }
    const ready = "markdown_viewer plugin (wasm): ready";
    stem_log(1, ready.ptr, ready.len);
}

export fn handle_command(id_ptr: [*]const u8, id_len: i32) void {
    const id = id_ptr[0..@intCast(id_len)];

    if (std.mem.eql(u8, id, CMD_PREVIEW)) {
        stem_open_buffer(
            "[Markdown Preview]".ptr,
            "[Markdown Preview]".len,
            PREVIEW_HINT.ptr,
            PREVIEW_HINT.len,
        );
        return;
    }
    if (std.mem.eql(u8, id, CMD_EDIT)) {
        const msg = "markdown.edit: already in edit mode";
        stem_show_notification(0, msg.ptr, msg.len);
        return;
    }
    if (std.mem.eql(u8, id, CMD_TOGGLE_PANEL)) {
        stem_open_buffer(
            "[Markdown Panel]".ptr,
            "[Markdown Panel]".len,
            PANEL_HINT.ptr,
            PANEL_HINT.len,
        );
        return;
    }
}
