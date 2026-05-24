const std = @import("std");
const vaxis = @import("vaxis");
const builtin = @import("builtin");

const is_mac = builtin.os.tag == .macos;

pub const cmd_mod: vaxis.Key.Modifiers = if (is_mac) .{ .super = true } else .{ .ctrl = true };

pub const Keys = struct {
    // ────────────────────────────────────────────────────────────
    // Modifier-prefixed (Cmd/Ctrl-X) — work in any mode.
    // ────────────────────────────────────────────────────────────
    pub const save = vaxis.Key{ .codepoint = 's', .mods = cmd_mod };
    pub const open = vaxis.Key{ .codepoint = 'o', .mods = cmd_mod };
    pub const quit = vaxis.Key{ .codepoint = 'q', .mods = cmd_mod };
    pub const close_buffer = vaxis.Key{ .codepoint = 'w', .mods = cmd_mod };

    pub const next_buffer = if (is_mac)
        vaxis.Key{ .codepoint = ']', .mods = .{ .super = true, .shift = true } }
    else
        vaxis.Key{ .codepoint = vaxis.Key.tab, .mods = .{ .ctrl = true } };

    pub const prev_buffer = if (is_mac)
        vaxis.Key{ .codepoint = '[', .mods = .{ .super = true, .shift = true } }
    else
        vaxis.Key{ .codepoint = vaxis.Key.tab, .mods = .{ .ctrl = true, .shift = true } };

    // ────────────────────────────────────────────────────────────
    // Leader (Space) and which-key.
    // ────────────────────────────────────────────────────────────
    pub const leader = ' ';
    /// Toggle the which-key popup. Two synonyms are honored:
    /// - `;` — unshifted, no terminal-codepoint ambiguity, works
    ///   everywhere.
    /// - `?` — universal "what can I do" convention; intercepted
    ///   in the leader handler regardless of whether the terminal
    ///   delivers `Shift+/` as codepoint `'?'` or codepoint `'/'`.
    pub const action_which_key = ';';
    pub const action_which_key_alt = '?';

    // ────────────────────────────────────────────────────────────
    // Top-level (single-step) Space bindings.
    // Keep this list for the highest-frequency actions only —
    // anything that grows into a family belongs in a chord group
    // below.
    // ────────────────────────────────────────────────────────────
    pub const action_code_action = 'a'; // Helix convention; "a for action"
    pub const action_buffer = 'b';
    pub const action_copy = 'c';
    pub const action_file_explorer = 'e'; // tree-shaped file opener (single canonical entry point)
    pub const action_help = 'h'; // help view (was: hover; hover moved to Space l h)
    pub const action_jobs = 'j';
    pub const action_close = 'k'; // close pane/buffer
    pub const action_next = 'n'; // next buffer
    pub const action_prev = 'p'; // previous buffer
    pub const action_quit = 'q';
    pub const action_redo = 'r';
    pub const action_save = 's';
    pub const action_undo = 'u';
    pub const action_paste = 'v';
    pub const action_cut = 'x';
    pub const action_center_view = 'z'; // vim zz — center cursor in viewport

    pub const action_jump_back = ',';
    pub const action_jump_forward = '.';

    /// Command palette. `:` is the vim convention; `Space a` used
    /// to do this but is now `action_code_action`.
    pub const action_palette = ':';
    pub const action_global_search = '/';

    // ────────────────────────────────────────────────────────────
    // Chord-prefix keys. After Space-<prefix>, the next key is
    // dispatched through that group's sub-switch.
    // ────────────────────────────────────────────────────────────
    pub const chord_lsp = 'l'; // language-server actions
    pub const chord_git = 'g'; // git plugin entry points
    pub const chord_window = 'w'; // splits and pane focus
    pub const chord_toggle = 't'; // boolean editor toggles

    // ────────────────────────────────────────────────────────────
    // Space l (LSP) sub-bindings.
    // ────────────────────────────────────────────────────────────
    pub const lsp_definition = 'd';
    pub const lsp_references = 'r';
    pub const lsp_hover = 'h';
    pub const lsp_rename = 'R';
    pub const lsp_code_action = 'a'; // alias for top-level Space a
    pub const lsp_format_buffer = 'f';
    pub const lsp_format_selection = 'F';
    pub const lsp_diagnostics = 'D';
    pub const lsp_document_symbols = 's';
    pub const lsp_workspace_symbols = 'S';
    pub const lsp_toggle_inline_diagnostics = 't';
    pub const lsp_toggle_inlay_hints = 'i';
    pub const lsp_toggle_format_on_save = '=';

    // ────────────────────────────────────────────────────────────
    // Space g (Git) sub-bindings.
    // ────────────────────────────────────────────────────────────
    pub const git_diff = 'd';

    // ────────────────────────────────────────────────────────────
    // Space w (Window/split) sub-bindings.
    // ────────────────────────────────────────────────────────────
    pub const win_split_horizontal = '-';
    pub const win_split_vertical = '|';
    pub const win_focus_left = 'h';
    pub const win_focus_down = 'j';
    pub const win_focus_up = 'k';
    pub const win_focus_right = 'l';
    pub const win_close = 'q';
    pub const win_only = 'o'; // close other panes (future)

    // Single-step aliases for the split keys — `Space -` and
    // `Space |` are common enough to deserve a one-step shortcut.
    pub const action_split_horizontal = '-';
    pub const action_split_vertical = '|';

    // ────────────────────────────────────────────────────────────
    // Space t (Toggle) sub-bindings.
    // ────────────────────────────────────────────────────────────
    pub const toggle_line_numbers = 'l';
    pub const toggle_wrap = 'w';
    pub const toggle_whitespace = 's';
    pub const toggle_cursor_line = 'c';
    pub const toggle_inline_diagnostics = 'd';
    pub const toggle_inlay_hints = 'i';
    pub const toggle_format_on_save = '=';

    // ────────────────────────────────────────────────────────────
    // Mode-switching letters (consumed by Select-mode handler, not
    // the leader).
    // ────────────────────────────────────────────────────────────
    pub const mode_insert = 'i';
    pub const mode_view = 'V';
    pub const mode_terminal = 't';

    // ────────────────────────────────────────────────────────────
    // In-buffer search step.
    // ────────────────────────────────────────────────────────────
    pub const search_next = 'n';
    pub const search_prev = 'N';

    // ────────────────────────────────────────────────────────────
    // hjkl navigation (Select / Visual).
    // ────────────────────────────────────────────────────────────
    pub const nav_left = 'h';
    pub const nav_down = 'j';
    pub const nav_up = 'k';
    pub const nav_right = 'l';
};
