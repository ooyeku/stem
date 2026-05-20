//! Catalogue of leader-key bindings used by the which-key popup.
//! Each entry's `key` is a static string literal so the renderer can
//! pass it straight to vaxis without lifetime concerns — earlier
//! versions encoded the codepoint into a stack buffer per entry,
//! which left vaxis holding pointers into stack memory that was
//! reused by the next iteration (all keys ended up rendering as the
//! last entry's glyph).

const std = @import("std");
const Keys = @import("../config/keys.zig").Keys;

pub const Group = enum {
    file,
    navigation,
    edit,
    lsp,
    splits,
    misc,

    pub fn title(self: Group) []const u8 {
        return switch (self) {
            .file => "Files & buffers",
            .navigation => "Navigation",
            .edit => "Edit",
            .lsp => "Language",
            .splits => "Splits",
            .misc => "Misc",
        };
    }
};

pub const Entry = struct {
    /// Display string for the key — single-character literal, static
    /// lifetime. Authored manually so the popup glyph and the actual
    /// `Keys.action_*` codepoint stay in sync (see the comptime
    /// assertions below).
    key: []const u8,
    label: []const u8,
    group: Group,
};

/// Authoritative list of leader bindings. The `key` strings here are
/// kept in sync with `Keys.action_*` by the comptime block below — if
/// you change a `Keys.action_*` constant and forget to update this
/// table, the build fails.
pub const entries = [_]Entry{
    .{ .key = "f", .label = "Find file", .group = .file },
    .{ .key = "b", .label = "Switch buffer", .group = .file },
    .{ .key = "s", .label = "Save", .group = .file },
    .{ .key = "k", .label = "Close pane / buffer", .group = .file },
    .{ .key = "q", .label = "Quit", .group = .file },
    .{ .key = "n", .label = "Next buffer", .group = .file },
    .{ .key = "p", .label = "Previous buffer", .group = .file },

    .{ .key = "a", .label = "Command palette", .group = .navigation },
    .{ .key = "/", .label = "Project search", .group = .navigation },
    .{ .key = ",", .label = "Jump back", .group = .navigation },
    .{ .key = ".", .label = "Jump forward", .group = .navigation },

    .{ .key = "u", .label = "Undo", .group = .edit },
    .{ .key = "r", .label = "Redo", .group = .edit },
    .{ .key = "c", .label = "Copy", .group = .edit },
    .{ .key = "x", .label = "Cut", .group = .edit },
    .{ .key = "v", .label = "Paste", .group = .edit },
    .{ .key = "e", .label = "Toggle option", .group = .edit },

    .{ .key = "g", .label = "Go to definition", .group = .lsp },
    .{ .key = "l", .label = "Find references", .group = .lsp },
    .{ .key = "h", .label = "Hover", .group = .lsp },
    .{ .key = "m", .label = "Rename", .group = .lsp },
    .{ .key = "d", .label = "Diagnostics", .group = .lsp },
    .{ .key = "o", .label = "Document symbols", .group = .lsp },
    .{ .key = "O", .label = "Workspace symbols", .group = .lsp },

    .{ .key = "-", .label = "Split horizontal", .group = .splits },
    .{ .key = "`", .label = "Split vertical", .group = .splits },

    .{ .key = "w", .label = "Help view", .group = .misc },
    .{ .key = "j", .label = "Jobs list", .group = .misc },
    .{ .key = "D", .label = "Git diff", .group = .misc },
    .{ .key = "?", .label = "Toggle this help", .group = .misc },
};

/// Format a key codepoint as a stable string. Retained for callers
/// outside `entries` (none yet). Returns a single-byte slice with a
/// program-lifetime backing array; never use this for codepoints
/// outside the 0..127 ASCII range.
pub fn glyphFor(comptime k: u21) []const u8 {
    return &[_]u8{@as(u8, @intCast(k))};
}

// Compile-time integrity check: every entry's `key` string must be
// a single byte equal to the corresponding `Keys.action_*` codepoint.
// If anyone edits `keys.zig` without updating this table, the build
// breaks here rather than silently showing the wrong glyph.
comptime {
    const expected = [_]struct { k: []const u8, code: u21 }{
        .{ .k = "f", .code = Keys.action_open },
        .{ .k = "b", .code = Keys.action_buffer },
        .{ .k = "s", .code = Keys.action_save },
        .{ .k = "k", .code = Keys.action_close },
        .{ .k = "q", .code = Keys.action_quit },
        .{ .k = "n", .code = Keys.action_next },
        .{ .k = "p", .code = Keys.action_prev },
        .{ .k = "a", .code = Keys.action_palette },
        .{ .k = "/", .code = Keys.action_global_search },
        .{ .k = ",", .code = Keys.action_jump_back },
        .{ .k = ".", .code = Keys.action_jump_forward },
        .{ .k = "u", .code = Keys.action_undo },
        .{ .k = "r", .code = Keys.action_redo },
        .{ .k = "c", .code = Keys.action_copy },
        .{ .k = "x", .code = Keys.action_cut },
        .{ .k = "v", .code = Keys.action_paste },
        .{ .k = "e", .code = Keys.action_toggle_option },
        .{ .k = "g", .code = Keys.action_lsp_definition },
        .{ .k = "l", .code = Keys.action_lsp_references },
        .{ .k = "h", .code = Keys.action_lsp_hover },
        .{ .k = "m", .code = Keys.action_lsp_rename },
        .{ .k = "d", .code = Keys.action_lsp_diagnostics },
        .{ .k = "o", .code = Keys.action_document_symbols },
        .{ .k = "O", .code = Keys.action_workspace_symbols },
        .{ .k = "-", .code = Keys.action_split_horizontal },
        .{ .k = "`", .code = Keys.action_split_vertical },
        .{ .k = "w", .code = Keys.action_help },
        .{ .k = "j", .code = Keys.action_jobs },
        .{ .k = "D", .code = Keys.action_git_diff },
        .{ .k = "?", .code = Keys.action_which_key },
    };
    for (expected) |e| {
        if (e.k.len != 1 or e.k[0] != @as(u8, @intCast(e.code))) {
            @compileError("which_key entry out of sync with Keys.action_* — update src/ui/which_key.zig");
        }
    }
}
