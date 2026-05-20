const std = @import("std");
const vaxis = @import("vaxis");
const builtin = @import("builtin");

const is_mac = builtin.os.tag == .macos;

pub const cmd_mod: vaxis.Key.Modifiers = if (is_mac) .{ .super = true } else .{ .ctrl = true };

pub const Keys = struct {
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

    pub const leader = ' ';

    pub const action_palette = 'a';
    pub const action_help = 'w';
    pub const action_jobs = 'j';
    /// Toggle the which-key popup. Replaces the earlier "Double Space"
    /// trigger so the chord follows the same `<leader> <letter>` shape
    /// as every other binding.
    pub const action_which_key = '?';

    pub const action_buffer = 'b';
    pub const action_next = 'n';
    pub const action_prev = 'p';
    pub const action_close = 'k';

    pub const action_open = 'f';
    pub const action_save = 's';
    pub const action_quit = 'q';

    pub const action_undo = 'u';
    pub const action_redo = 'r';
    pub const action_copy = 'c';
    pub const action_cut = 'x';
    pub const action_paste = 'v';

    pub const action_lsp_definition = 'g';
    pub const action_lsp_references = 'l';
    pub const action_lsp_hover = 'h';
    pub const action_lsp_rename = 'm';
    pub const action_lsp_diagnostics = 'd';
    pub const action_document_symbols = 'o';
    pub const action_workspace_symbols = 'O';

    pub const action_jump_back = ',';
    pub const action_jump_forward = '.';

    pub const action_split_horizontal = '-';
    pub const action_split_vertical = '`';

    pub const action_global_search = '/';
    pub const action_toggle_option = 'e';

    pub const action_git_diff = 'D';

    pub const mode_insert = 'i';
    pub const mode_view = 'V';
    pub const mode_terminal = 't';

    pub const search_next = 'n';
    pub const search_prev = 'N';

    pub const nav_left = 'h';
    pub const nav_down = 'j';
    pub const nav_up = 'k';
    pub const nav_right = 'l';
};
