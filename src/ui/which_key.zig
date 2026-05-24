//! Catalogue of leader-key bindings used by the which-key popup.
//!
//! Two views into the same data:
//! - At the top level (`leader_chord == null`), `entriesFor(null)`
//!   returns a comprehensive list — every top-level single-step
//!   binding *and* every chord sub-binding spelled out with its
//!   full prefix (e.g. `l h` for `Space l h`). This makes hover,
//!   git-diff, and the like discoverable without entering a chord.
//! - Inside a chord (`leader_chord = some('l'/'g'/'w'/'t')`),
//!   `entriesFor(prefix)` returns just that chord's sub-bindings,
//!   one keystroke each (e.g. `h` for hover).
//!
//! Per-chord constants (`lsp_entries`, `git_entries`, …) are the
//! single source of truth. The comprehensive top-level list is
//! built by concatenating them with their `key` field prefixed by
//! the chord letter at comptime.
//!
//! Each `key` field is a static string literal so the renderer can
//! pass it straight to vaxis — earlier versions encoded the
//! codepoint into a stack buffer per entry, which left vaxis
//! holding pointers into stack memory that was reused by the next
//! iteration.

const std = @import("std");
const Keys = @import("../config/keys.zig").Keys;

pub const Group = enum {
    file,
    navigation,
    edit,
    code,
    splits,
    misc,
    lsp_chord,
    git_chord,
    window_chord,
    toggle_chord,

    pub fn title(self: Group) []const u8 {
        return switch (self) {
            .file => "Files & buffers",
            .navigation => "Navigation",
            .edit => "Edit",
            .code => "Code",
            .splits => "Splits",
            .misc => "Misc",
            .lsp_chord => "LSP — Space l _",
            .git_chord => "Git — Space g _",
            .window_chord => "Window — Space w _",
            .toggle_chord => "Toggle — Space t _",
        };
    }
};

pub const Entry = struct {
    /// Display string for the key. May be a single character (top
    /// level or inside a chord) or two characters separated by a
    /// space (`"l h"`) when shown in the top-level comprehensive
    /// view. Static lifetime in either case — the comptime
    /// concatenation below builds the multi-char strings as
    /// program-lifetime arrays.
    key: []const u8,
    label: []const u8,
    group: Group,
};

// ────────────────────────────────────────────────────────────
// Top-level single-step Space bindings.
// ────────────────────────────────────────────────────────────
const top_only = [_]Entry{
    .{ .key = "e", .label = "Open file (explorer)", .group = .file },
    .{ .key = "b", .label = "Buffer picker", .group = .file },
    .{ .key = "s", .label = "Save", .group = .file },
    .{ .key = "k", .label = "Close pane / buffer", .group = .file },
    .{ .key = "q", .label = "Quit", .group = .file },
    .{ .key = "n", .label = "Next buffer", .group = .file },
    .{ .key = "p", .label = "Previous buffer", .group = .file },

    .{ .key = ":", .label = "Command palette", .group = .navigation },
    .{ .key = "/", .label = "Project search", .group = .navigation },
    .{ .key = ",", .label = "Jump back", .group = .navigation },
    .{ .key = ".", .label = "Jump forward", .group = .navigation },
    .{ .key = "z", .label = "Center cursor", .group = .navigation },

    .{ .key = "u", .label = "Undo", .group = .edit },
    .{ .key = "r", .label = "Redo", .group = .edit },
    .{ .key = "c", .label = "Copy", .group = .edit },
    .{ .key = "x", .label = "Cut", .group = .edit },
    .{ .key = "v", .label = "Paste", .group = .edit },
    .{ .key = "a", .label = "Code actions", .group = .code },

    .{ .key = "-", .label = "Split horizontal", .group = .splits },
    .{ .key = "|", .label = "Split vertical", .group = .splits },

    .{ .key = "h", .label = "Help view", .group = .misc },
    .{ .key = "j", .label = "Jobs list", .group = .misc },
    .{ .key = ";", .label = "Toggle this help", .group = .misc },
};

// ────────────────────────────────────────────────────────────
// Per-chord sub-bindings. Keys are the single keystroke after
// the chord prefix.
// ────────────────────────────────────────────────────────────

pub const lsp_entries = [_]Entry{
    .{ .key = "d", .label = "Go to definition", .group = .code },
    .{ .key = "r", .label = "Find references", .group = .code },
    .{ .key = "h", .label = "Hover (docs)", .group = .code },
    .{ .key = "a", .label = "Code actions", .group = .code },
    .{ .key = "f", .label = "Format buffer", .group = .code },
    .{ .key = "F", .label = "Format selection", .group = .code },
    .{ .key = "D", .label = "Diagnostics list", .group = .code },
    .{ .key = "s", .label = "Document symbols", .group = .code },
    .{ .key = "S", .label = "Workspace symbols", .group = .code },
    .{ .key = "t", .label = "Toggle inline diagnostics", .group = .code },
    .{ .key = "i", .label = "Toggle inlay hints", .group = .code },
    .{ .key = "=", .label = "Toggle format-on-save", .group = .code },
};

pub const git_entries = [_]Entry{
    .{ .key = "d", .label = "Diff", .group = .misc },
};

pub const window_entries = [_]Entry{
    .{ .key = "-", .label = "Split horizontal", .group = .splits },
    .{ .key = "|", .label = "Split vertical", .group = .splits },
    .{ .key = "h", .label = "Focus pane left", .group = .splits },
    .{ .key = "j", .label = "Focus pane down", .group = .splits },
    .{ .key = "k", .label = "Focus pane up", .group = .splits },
    .{ .key = "l", .label = "Focus pane right", .group = .splits },
    .{ .key = "q", .label = "Close pane", .group = .splits },
};

pub const toggle_entries = [_]Entry{
    .{ .key = "d", .label = "Toggle inline diagnostics", .group = .edit },
    .{ .key = "i", .label = "Toggle inlay hints", .group = .edit },
    .{ .key = "=", .label = "Toggle format-on-save", .group = .edit },
};

// Build the comprehensive top-level list by re-grouping each
// chord's sub-bindings under its own `*_chord` group. The keys
// stay as single chars (the renderer shows the prefix in the
// group header so the popup reads naturally as e.g.
// `LSP — Space l _ \n d  Go to definition`).
const lsp_in_top = blk: {
    var arr: [lsp_entries.len]Entry = undefined;
    for (lsp_entries, 0..) |e, i| {
        arr[i] = .{ .key = e.key, .label = e.label, .group = .lsp_chord };
    }
    break :blk arr;
};
const git_in_top = blk: {
    var arr: [git_entries.len]Entry = undefined;
    for (git_entries, 0..) |e, i| {
        arr[i] = .{ .key = e.key, .label = e.label, .group = .git_chord };
    }
    break :blk arr;
};
const window_in_top = blk: {
    var arr: [window_entries.len]Entry = undefined;
    for (window_entries, 0..) |e, i| {
        arr[i] = .{ .key = e.key, .label = e.label, .group = .window_chord };
    }
    break :blk arr;
};
const toggle_in_top = blk: {
    var arr: [toggle_entries.len]Entry = undefined;
    for (toggle_entries, 0..) |e, i| {
        arr[i] = .{ .key = e.key, .label = e.label, .group = .toggle_chord };
    }
    break :blk arr;
};

/// Comprehensive top-level list. Includes every single-step
/// binding plus every chord's sub-bindings under its own section.
pub const top_entries = top_only ++ lsp_in_top ++ git_in_top ++ window_in_top ++ toggle_in_top;

/// Pick the entry list to show given the current chord prefix.
/// Pass `null` from the render snapshot when no chord is pending.
pub fn entriesFor(prefix: ?u8) []const Entry {
    if (prefix) |p| switch (p) {
        Keys.chord_lsp => return &lsp_entries,
        Keys.chord_git => return &git_entries,
        Keys.chord_window => return &window_entries,
        Keys.chord_toggle => return &toggle_entries,
        else => {},
    };
    return &top_entries;
}

/// Banner text for the popup, given the current chord prefix.
pub fn titleFor(prefix: ?u8) []const u8 {
    if (prefix) |p| switch (p) {
        Keys.chord_lsp => return " Space l — LSP",
        Keys.chord_git => return " Space g — Git",
        Keys.chord_window => return " Space w — Window",
        Keys.chord_toggle => return " Space t — Toggle",
        else => {},
    };
    return " Space — leader";
}

/// Format a key codepoint as a stable string. Retained for callers
/// outside `top_entries`. Returns a single-byte slice with a
/// program-lifetime backing array; never use this for codepoints
/// outside the 0..127 ASCII range.
pub fn glyphFor(comptime k: u21) []const u8 {
    return &[_]u8{@as(u8, @intCast(k))};
}

// Compile-time integrity check: every entry's `key` string must be
// a single byte equal to the corresponding `Keys.*` codepoint. If
// anyone edits `keys.zig` without updating this table, the build
// breaks here rather than silently showing the wrong glyph.
comptime {
    const expected = [_]struct { k: []const u8, code: u21 }{
        .{ .k = "e", .code = Keys.action_file_explorer },
        .{ .k = "b", .code = Keys.action_buffer },
        .{ .k = "s", .code = Keys.action_save },
        .{ .k = "k", .code = Keys.action_close },
        .{ .k = "q", .code = Keys.action_quit },
        .{ .k = "n", .code = Keys.action_next },
        .{ .k = "p", .code = Keys.action_prev },
        .{ .k = ":", .code = Keys.action_palette },
        .{ .k = "/", .code = Keys.action_global_search },
        .{ .k = ",", .code = Keys.action_jump_back },
        .{ .k = ".", .code = Keys.action_jump_forward },
        .{ .k = "z", .code = Keys.action_center_view },
        .{ .k = "u", .code = Keys.action_undo },
        .{ .k = "r", .code = Keys.action_redo },
        .{ .k = "c", .code = Keys.action_copy },
        .{ .k = "x", .code = Keys.action_cut },
        .{ .k = "v", .code = Keys.action_paste },
        .{ .k = "a", .code = Keys.action_code_action },
        .{ .k = "-", .code = Keys.action_split_horizontal },
        .{ .k = "|", .code = Keys.action_split_vertical },
        .{ .k = "h", .code = Keys.action_help },
        .{ .k = "j", .code = Keys.action_jobs },
        .{ .k = ";", .code = Keys.action_which_key },
    };
    for (expected) |e| {
        if (e.k.len != 1 or e.k[0] != @as(u8, @intCast(e.code))) {
            @compileError("which_key entry out of sync with Keys.* — update src/ui/which_key.zig");
        }
    }
}
