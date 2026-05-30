const std = @import("std");
const vaxis = @import("vaxis");
const builtin = @import("builtin");
const platform = @import("../kernel/platform.zig");

pub const RGB = struct { u8, u8, u8 };

// Runtime truecolor capability flag. Set by `detectTruecolor()` once
// at startup. Default chosen so the binary still produces usable
// (16-colour) output if detection is never called.
//
// Why this exists: most syntax/decoration colours are 24-bit RGB,
// which is fine on every modern terminal *except* the classic Windows
// conhost (cmd.exe in the legacy console host). conhost silently
// drops 24-bit SGR codes, leaving the buffer text rendered with the
// terminal default foreground — exactly the "status bar is colourful,
// buffer is flat" symptom that prompted this. Index/palette colours
// (16-colour) work everywhere including legacy conhost.
pub var truecolor_enabled: bool = builtin.os.tag != .windows;

/// Probe the environment for truecolor support and set
/// `truecolor_enabled` accordingly. Call once at startup, before any
/// rendering happens. The heuristic, in order:
///   1. COLORTERM == "truecolor" / "24bit"           → yes
///   2. WT_SESSION is set (Microsoft Windows Terminal) → yes
///   3. TERM_PROGRAM != Apple_Terminal* (iTerm, ghostty, vscode,
///      WezTerm, alacritty, etc.)                    → yes
///   4. Otherwise default to platform tradition: yes on POSIX, no on
///      Windows (covers classic conhost / cmd.exe).
///
/// "Apple_Terminal*" is excluded because macOS Terminal.app is
/// 256-colour only, not truecolor — falls through to step 4.
pub fn detectTruecolor(
    allocator: std.mem.Allocator,
    environ_block: std.process.Environ.Block,
) void {
    if (platform.getEnv(allocator, environ_block, "COLORTERM") catch null) |val| {
        defer allocator.free(val);
        if (std.mem.eql(u8, val, "truecolor") or std.mem.eql(u8, val, "24bit")) {
            truecolor_enabled = true;
            return;
        }
    }

    if (platform.getEnv(allocator, environ_block, "WT_SESSION") catch null) |val| {
        defer allocator.free(val);
        truecolor_enabled = true;
        return;
    }

    if (platform.getEnv(allocator, environ_block, "TERM_PROGRAM") catch null) |val| {
        defer allocator.free(val);
        if (!std.mem.startsWith(u8, val, "Apple_Terminal")) {
            truecolor_enabled = true;
            return;
        }
    }

    truecolor_enabled = builtin.os.tag != .windows;
}

/// Return a vaxis color that uses 24-bit RGB if the terminal can
/// render it, otherwise the supplied 16-colour palette index fallback.
/// Centralising the choice here means each call site stays a one-liner
/// instead of branching on `truecolor_enabled` everywhere.
pub fn fg(rgb_color: RGB, palette_index: u8) vaxis.Cell.Color {
    return if (truecolor_enabled)
        .{ .rgb = .{ rgb_color[0], rgb_color[1], rgb_color[2] } }
    else
        .{ .index = palette_index };
}

pub const colors = struct {
    pub const syntax = struct {
        pub const keyword: RGB = .{ 203, 166, 247 };
        pub const function: RGB = .{ 137, 180, 250 };
        pub const variable: RGB = .{ 243, 139, 168 };
        pub const parameter: RGB = .{ 235, 160, 172 };
        pub const property: RGB = .{ 137, 220, 235 };
        pub const type_name: RGB = .{ 249, 226, 175 };
        pub const string: RGB = .{ 166, 227, 161 };
        pub const number: RGB = .{ 250, 179, 135 };
        pub const comment: RGB = .{ 108, 112, 134 };
        pub const operator: RGB = .{ 148, 226, 213 };
        pub const builtin: RGB = .{ 245, 194, 231 };
        pub const namespace: RGB = .{ 180, 190, 254 };
        pub const other: RGB = .{ 205, 214, 244 };
    };

    pub const diff = struct {
        pub const add: RGB = .{ 152, 195, 121 };
        pub const remove: RGB = .{ 224, 108, 117 };
        pub const hunk: RGB = .{ 86, 182, 194 };
        pub const file: RGB = .{ 229, 192, 123 };
    };

    pub const brackets = struct {
        pub const level_1: RGB = .{ 224, 108, 117 };
        pub const level_2: RGB = .{ 209, 154, 102 };
        pub const level_3: RGB = .{ 229, 192, 123 };
        pub const level_4: RGB = .{ 152, 195, 121 };
        pub const level_5: RGB = .{ 86, 182, 194 };
        pub const level_6: RGB = .{ 198, 120, 221 };
        pub const scope: RGB = .{ 255, 215, 0 };
    };

    pub const log = struct {
        pub const timestamp: u8 = 14;
        pub const scope: u8 = 13;
        pub const info: u8 = 10;
        pub const warn: u8 = 11;
        pub const err: u8 = 9;
        pub const debug: u8 = 8;
        pub const message: u8 = 15;
    };

    pub const palette = struct {
        pub const black: u8 = 0;
        pub const red: u8 = 1;
        pub const green: u8 = 2;
        pub const yellow: u8 = 3;
        pub const blue: u8 = 4;
        pub const magenta: u8 = 5;
        pub const cyan: u8 = 6;
        pub const white: u8 = 7;
        pub const bright_black: u8 = 8;
        pub const bright_red: u8 = 9;
        pub const bright_green: u8 = 10;
        pub const bright_yellow: u8 = 11;
        pub const bright_blue: u8 = 12;
        pub const bright_magenta: u8 = 13;
        pub const bright_cyan: u8 = 14;
        pub const bright_white: u8 = 15;
    };
};

pub const styles = struct {
    pub const mode = struct {
        pub const select: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.bright_white },
            .bg = .{ .index = colors.palette.magenta },
        };
        pub const insert: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.black },
            .bg = .{ .index = colors.palette.green },
        };
        pub const visual: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.black },
            .bg = .{ .index = colors.palette.yellow },
        };
        pub const view: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.bright_white },
            .bg = .{ .index = colors.palette.blue },
        };
        pub const terminal: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.black },
            .bg = .{ .index = colors.palette.yellow },
        };
        pub const file_picker: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.bright_white },
            .bg = .{ .index = colors.palette.cyan },
        };
        pub const buffer_picker: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.bright_white },
            .bg = .{ .index = colors.palette.cyan },
        };
        pub const save_as: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.bright_white },
            .bg = .{ .index = colors.palette.cyan },
        };
        pub const visual_search: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.black },
            .bg = .{ .index = colors.palette.yellow },
        };
        pub const command_palette: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.bright_white },
            .bg = .{ .index = colors.palette.blue },
        };
        pub const go_to_line: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.bright_white },
            .bg = .{ .index = colors.palette.magenta },
        };
        pub const symbol_picker: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.bright_white },
            .bg = .{ .index = colors.palette.magenta },
        };
        pub const log_view: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.bright_white },
            .bg = .{ .index = colors.palette.blue },
        };
        pub const global_search: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.black },
            .bg = .{ .index = colors.palette.yellow },
        };
    };

    pub const status_bar = struct {
        pub const base: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.black },
            .bg = .{ .index = colors.palette.white },
        };
        pub const info: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.bright_black },
            .bg = .{ .index = colors.palette.white },
        };
        pub const modified: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.red },
            .bg = .{ .index = colors.palette.white },
            .bold = true,
        };
        pub const prefix: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.black },
            .bg = .{ .index = colors.palette.bright_yellow },
            .bold = true,
        };
    };

    pub const tab_bar = struct {
        pub const background: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.white },
            .bg = .{ .index = colors.palette.black },
        };
        pub const active: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.black },
            .bg = .{ .index = colors.palette.white },
            .bold = true,
        };
        pub const inactive: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.bright_black },
            .bg = .{ .index = colors.palette.black },
        };
        pub const modified: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.yellow },
            .bg = .{ .index = colors.palette.black },
        };
        pub const scroll_indicator: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.cyan },
            .bg = .{ .index = colors.palette.black },
        };
        pub const number_active: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.black },
            .bg = .{ .index = colors.palette.white },
            .bold = true,
        };
        pub const number_inactive: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.cyan },
            .bg = .{ .index = colors.palette.black },
        };
    };

    pub const picker = struct {
        pub const overlay: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.white },
            .bg = .{ .index = colors.palette.black },
        };
        pub const header: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.black },
            .bg = .{ .index = colors.palette.cyan },
            .bold = true,
        };
        pub const normal: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.white },
            .bg = .{ .index = colors.palette.black },
        };
        pub const selected: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.black },
            .bg = .{ .index = colors.palette.blue },
            .bold = true,
        };
        pub const selected_white: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.black },
            .bg = .{ .index = colors.palette.white },
        };
        pub const directory: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.blue },
            .bg = .{ .index = colors.palette.black },
        };
        pub const directory_selected: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.blue },
            .bg = .{ .index = colors.palette.white },
        };
        pub const active_marker: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.green },
            .bg = .{ .index = colors.palette.black },
        };
        pub const number: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.cyan },
            .bg = .{ .index = colors.palette.black },
        };
        pub const input: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.black },
            .bg = .{ .index = colors.palette.yellow },
            .bold = true,
        };
        pub const footer: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.bright_black },
            .bg = .{ .index = colors.palette.black },
        };
        pub const scrollbar: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.bright_black },
        };
        pub const scrollbar_thumb: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.white },
            .reverse = true,
        };
    };

    pub const editor = struct {
        pub const line_number: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.bright_black },
        };
        pub const default: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.white },
            .bg = .{ .index = colors.palette.black },
        };
        pub const cursor_line: vaxis.Cell.Style = .{
            .bg = .{ .rgb = .{ 49, 50, 68 } },
        };
    };

    pub const panel = struct {
        pub const background: vaxis.Cell.Style = .{
            .bg = .{ .index = colors.palette.black },
            .fg = .{ .index = colors.palette.white },
        };
        pub const title: vaxis.Cell.Style = .{
            .bold = true,
            .bg = .{ .index = colors.palette.blue },
            .fg = .{ .index = colors.palette.bright_white },
        };
    };

    pub const split = struct {
        pub const header_focused: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.black },
            .bg = .{ .index = colors.palette.blue },
        };
        pub const header_unfocused: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.white },
            .bg = .{ .index = colors.palette.bright_black },
        };
        pub const content: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.white },
            .bg = .{ .index = colors.palette.black },
        };
    };

    pub const help = struct {
        pub const title: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.blue },
            .bold = true,
        };
        pub const h1: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.cyan },
            .bold = true,
        };
        pub const h2: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.magenta },
            .bold = true,
        };
        pub const h3: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.yellow },
            .bold = true,
        };
        pub const key: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.green },
            .bold = true,
        };
        pub const desc: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.white },
        };
        pub const bullet: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.yellow },
        };
        pub const command: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.cyan },
        };
        pub const separator: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.bright_black },
        };
        pub const diff_add: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.bright_green },
            .bg = .{ .index = colors.palette.black },
            .bold = true,
        };
        pub const diff_remove: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.bright_red },
            .bg = .{ .index = colors.palette.black },
            .bold = true,
        };
        pub const diff_hunk: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.bright_cyan },
            .bg = .{ .index = colors.palette.black },
            .bold = true,
        };
        pub const diff_file: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.bright_yellow },
            .bg = .{ .index = colors.palette.black },
            .bold = true,
        };
    };

    pub const popup = struct {
        pub const border: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.bright_black },
            .bg = .{ .index = colors.palette.black },
        };
        pub const title: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.blue },
            .bg = .{ .index = colors.palette.black },
        };
        pub const code: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.cyan },
            .bg = .{ .index = colors.palette.black },
        };
        pub const doc: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.white },
            .bg = .{ .index = colors.palette.black },
        };
        pub const dim: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.bright_black },
            .bg = .{ .index = colors.palette.black },
        };
    };

    pub const completion = struct {
        pub const background: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.white },
            .bg = .{ .index = colors.palette.black },
        };
        pub const selected: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.black },
            .bg = .{ .index = colors.palette.cyan },
            .bold = true,
        };
        pub const selected_alt: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.black },
            .bg = .{ .index = colors.palette.white },
        };
        pub const kind: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.bright_yellow },
            .bg = .{ .index = colors.palette.black },
        };
        pub const detail: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.bright_black },
            .bg = .{ .index = colors.palette.black },
        };
    };

    pub const terminal = struct {
        pub const output_bg: vaxis.Cell.Style = .{
            .bg = .{ .index = colors.palette.black },
        };
        pub const scroll: vaxis.Cell.Style = .{
            .bg = .{ .index = colors.palette.bright_black },
        };
    };

    pub const overlay = struct {
        pub const background: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.bright_black },
            .bg = .{ .index = colors.palette.black },
        };
        pub const label: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.blue },
            .bg = .{ .index = colors.palette.black },
        };
        pub const input: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.white },
            .bg = .{ .index = colors.palette.black },
        };
        pub const input_bg: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.black },
            .bg = .{ .index = colors.palette.bright_black },
        };
        pub const match_highlight: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.bright_yellow },
            .bg = .{ .index = colors.palette.black },
        };
    };

    pub const global_search = struct {
        pub const border: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.yellow },
            .bg = .{ .index = colors.palette.black },
        };
        pub const option_on: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.black },
            .bg = .{ .index = colors.palette.yellow },
            .bold = true,
        };
        pub const option_off: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.bright_black },
            .bg = .{ .index = colors.palette.black },
        };
        pub const file_header: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.blue },
            .bg = .{ .index = colors.palette.black },
            .bold = true,
        };
        pub const match_line: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.white },
            .bg = .{ .index = colors.palette.black },
        };
        pub const match_highlight: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.yellow },
            .bg = .{ .index = colors.palette.black },
            .bold = true,
        };
        pub const line_number: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.bright_black },
            .bg = .{ .index = colors.palette.black },
        };
        pub const selected: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.black },
            .bg = .{ .index = colors.palette.yellow },
            .bold = true,
        };
        pub const stats: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.green },
            .bg = .{ .index = colors.palette.black },
        };
        pub const input_label: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.yellow },
            .bg = .{ .index = colors.palette.black },
        };
        pub const replace_label: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.magenta },
            .bg = .{ .index = colors.palette.black },
        };
    };

    pub const command_palette = struct {
        pub const overlay: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.white },
            .bg = .{ .index = colors.palette.black },
        };
        pub const border: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.blue },
            .bg = .{ .index = colors.palette.black },
        };
        pub const title: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.bright_white },
            .bg = .{ .index = colors.palette.blue },
            .bold = true,
        };
        pub const input: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.white },
            .bg = .{ .index = colors.palette.black },
        };
        pub const input_prefix: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.cyan },
            .bg = .{ .index = colors.palette.black },
        };
        pub const item: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.white },
            .bg = .{ .index = colors.palette.black },
        };
        pub const item_selected: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.black },
            .bg = .{ .index = colors.palette.blue },
            .bold = true,
        };
        pub const keybinding: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.bright_black },
            .bg = .{ .index = colors.palette.black },
        };
        pub const keybinding_selected: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.bright_black },
            .bg = .{ .index = colors.palette.blue },
        };
        pub const footer: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.bright_black },
            .bg = .{ .index = colors.palette.black },
        };
        pub const scrollbar: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.bright_black },
        };
        pub const scrollbar_thumb: vaxis.Cell.Style = .{
            .fg = .{ .index = colors.palette.white },
        };
    };
};

pub fn rgb(color: RGB) vaxis.Color {
    return .{ .rgb = color };
}

pub fn indexed(idx: u8) vaxis.Color {
    return .{ .index = idx };
}
