const std = @import("std");
const vaxis = @import("vaxis");
const safe = @import("safe.zig");
const hover_doc = @import("../services/hover_doc.zig");

pub const Mode = enum {
    select,
    insert,
    visual,
    visual_search,
    view,
    terminal,
    file_picker,
    buffer_picker,
    save_as_mode,
    command_palette,
    go_to_line,
    symbol_picker,
    workspace_symbol_picker,
    log_view,
    global_search,
};

pub const DirEntry = struct {
    name: []const u8,
    is_dir: bool,
};

pub const RenderParams = struct {
    rows: usize,
    cols: usize,
};

pub const PaneBound = struct {
    pane: struct {
        id: u32,
        buffer_index: usize,
    },
    x: usize,
    y: usize,
    width: usize,
    height: usize,
};

pub const SyntaxToken = struct {
    line: u32,
    start_col: u32,
    length: u32,
    token_type: TokenType,

    pub const TokenType = enum {
        keyword,
        function,
        variable,
        parameter,
        property,
        type_name,
        string,
        number,
        comment,
        operator,
        builtin,
        namespace,
        other,
        bracket_1,
        bracket_2,
        bracket_3,
        bracket_4,
        bracket_5,
        bracket_6,
        scope_bracket,
    };
};

pub const CommandEntry = struct {
    id: []const u8,
    title: []const u8,
    description: []const u8,
};

pub const SymbolEntry = struct {
    name: []const u8,
    kind: []const u8,
    line: usize,
};

pub const WorkspaceSymbolEntry = struct {
    name: []const u8,
    kind: []const u8,
    /// Absolute path of the file the symbol lives in. Renderer
    /// truncates this to the basename for display.
    file_path: []const u8,
    line: usize,
    col: usize,
};

pub const PluginInfo = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    uptime_s: u64,
    widget_count: u32,
    is_running: bool,
};

pub const BufferInfo = struct {
    id: u32,
    name: []const u8,
    modified: bool,
    is_active: bool,
    /// True when the buffer crossed the configured large-file
    /// thresholds at load time. Tabs render a `[L]` badge so the user
    /// knows tree-sitter / LSP / brackets are intentionally off.
    is_large: bool = false,
};

pub const LogEntry = struct {
    timestamp: i64,
    level: u8,
    scope: []const u8,
    message: []const u8,
};

pub const DiagnosticSeverity = enum(u8) { err, warning, info, hint };

/// Single inlay hint as the renderer sees it. Position is buffer-
/// local (0-based line/col); label is the flattened text, kind is
/// 1 = type, 2 = parameter, null = unspecified.
pub const InlayHintSnapshot = struct {
    line: u32,
    col: u32,
    label: []const u8,
    kind: ?u8 = null,
    padding_left: bool = false,
    padding_right: bool = false,
};

/// Snapshot of an LSP diagnostic for the currently visible buffer. Positions
/// are buffer-local (0-based line/col, same convention as cursor_row/col).
pub const DiagnosticSnapshot = struct {
    start_line: u32,
    start_col: u32,
    end_line: u32,
    end_col: u32,
    severity: DiagnosticSeverity,
    message: []const u8,
};

pub const GlobalSearchMatch = struct {
    line_num: usize,
    line_content: []const u8,
    match_start: usize,
    match_end: usize,
};

pub const GlobalSearchFileGroup = struct {
    file_path: []const u8,
    matches: []const GlobalSearchMatch,
    collapsed: bool,
};

pub const GlobalSearchOptions = struct {
    case_sensitive: bool = false,
    whole_word: bool = false,
    use_regex: bool = false,
};

pub const WidgetID = u64;

pub const StatusAlignment = enum(u8) {
    left = 0,
    center = 1,
    right = 2,
};

pub const StatusItem = struct {
    id: []const u8,
    plugin_id: []const u8,
    text: []const u8,
    alignment: StatusAlignment,
    priority: i8,
    widget_id: WidgetID,
};

pub const PanelPosition = enum(u8) {
    left = 0,
    right = 1,
    bottom = 2,
};

pub const PanelInfo = struct {
    id: []const u8,
    plugin_id: []const u8,
    title: []const u8,
    content: []const []const u8,
    position: PanelPosition,
    width_percent: u8,
    widget_id: WidgetID,
    scroll_offset: u32 = 0,
};

pub const EditorStateView = struct {
    file_path: ?[]const u8,
    file_modified: bool,
    cursor_row: usize,
    cursor_col: usize,
    mode: Mode,
    buffer_id: u32,
    buffer_name: []const u8,
    total_lines: usize,
    selection_start_row: ?usize,
    selection_start_col: ?usize,
    selection_end_row: ?usize,
    selection_end_col: ?usize,
};

pub const PluginEvent = enum(u8) {
    buffer_changed = 0,
    cursor_moved = 1,
    mode_changed = 2,
    file_opened = 3,
    file_saved = 4,
    buffer_switched = 5,
    custom_event = 6,
};

pub const NotificationLevel = enum(u8) {
    info = 0,
    warning = 1,
    err = 2,
};

/// Visual treatment for transient `status_message` toasts. Drives the
/// icon and colour chosen by `status_bar.zig` so a save success and a
/// save failure don't both render as a green ✓.
pub const StatusLevel = enum(u8) {
    info = 0,
    success = 1,
    warning = 2,
    err = 3,
};

pub const CompletionEntry = struct {
    label: []const u8,
    kind: []const u8,
    detail: []const u8,
    /// Category of the completion item, used by the view to pick a color
    /// for the kind glyph. Maps from LSP CompletionItemKind.
    kind_category: KindCategory = .other,

    pub const KindCategory = enum {
        function, // function, method, constructor
        variable, // variable, parameter
        field, // field, property
        type_, // class, interface, struct, enum, type_parameter
        module, // module, namespace, folder
        keyword, // keyword
        value, // value, enumMember, constant
        snippet,
        text,
        other,
    };
};

pub const SplitDirection = enum {
    horizontal,
    vertical,
};

pub const EditorConfigSnapshot = struct {
    tab_size: u32 = 4,
    insert_spaces: bool = true,
    line_numbers: LineNumbersMode = .relative,
    wrap: bool = false,
    show_status_bar: bool = true,
    cursor_line: bool = true,
    /// Mirrors `EditorConfig.inline_diagnostics`. When true the view
    /// renders every line's worst diagnostic at end-of-line, not just
    /// the cursor's line.
    inline_diagnostics: bool = true,
    /// Mirrors `EditorConfig.inlay_hints`. When true the view paints
    /// LSP inlay hints as dim virtual text inline.
    inlay_hints: bool = false,

    pub const LineNumbersMode = enum { absolute, relative, none };
};

pub const PaneSnapshot = struct {
    id: u32,
    buffer_index: usize,
    is_focused: bool,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    cursor_row: usize,
    cursor_col: usize,
    scroll_offset: usize,
    selection_anchor_row: ?usize,
    selection_anchor_col: ?usize,
    visible_lines: []const []const u8,
    syntax_tokens: ?[]const SyntaxToken,
    total_lines: usize,
    diff_highlights: ?[]const DiffLineHighlight = null,
};

pub const DiffLineHighlight = struct {
    line: usize,
    kind: DiffKind,

    pub const DiffKind = enum { added, deleted, changed };
};

pub const RenderSnapshot = struct {
    visible_lines: []const []const u8,
    first_visible_line: usize,
    total_lines: usize,

    cursor_row: usize,
    cursor_col: usize,
    nav_repeat_count: usize = 0,

    selection_anchor_row: ?usize = null,
    selection_anchor_col: ?usize = null,

    scroll_offset: usize,
    version: u64,
    mode: Mode,
    terminal_output: ?[]const u8,
    terminal_input: ?[]const u8,
    terminal_cwd: ?[]const u8 = null,
    terminal_scroll_offset: usize = 0,
    terminal_running: bool = false,

    file_path: ?[]const u8,
    file_modified: bool,

    buffers: []const BufferInfo,
    active_buffer_index: usize,
    buffer_picker_selected: usize,

    file_picker_cwd: ?[]const u8,
    file_picker_entries: ?[]const DirEntry,
    file_picker_selected: usize,
    buffer_picker_scroll_offset: usize,
    buffer_picker_number_input: ?[]const u8 = null,
    save_as_input: ?[]const u8,
    search_input: ?[]const u8,
    /// `/` (forward) or `?` (backward), shown in the search prompt
    /// title so the user knows which direction n/N will step.
    search_direction_forward: bool = true,
    /// Total matches in the current buffer for the live search query
    /// and the 1-based index of the active one (cursor sits on it
    /// during incremental search). 0 / 0 = unknown or no matches.
    search_match_count: usize = 0,
    search_match_index: usize = 0,

    syntax_tokens: ?[]const SyntaxToken = null,

    hover_content: ?[]const u8 = null,
    /// Parsed-and-cloned hover document. Lives in the same arena as
    /// the rest of the snapshot, freed when the snapshot is. Null
    /// when there's no hover (or the parse failed and we fell back
    /// to the raw `hover_content`).
    hover_document: ?hover_doc.HoverDocument = null,
    /// Anchor cell — token start, not the cursor — used by the
    /// renderer to position the popup. Buffer-space coordinates;
    /// view converts to screen.
    hover_anchor_row: usize = 0,
    hover_anchor_col: usize = 0,
    /// Per-section scroll offset for the popup. The signature panel
    /// is never scrolled; only the body sections move.
    hover_scroll_offset: usize = 0,
    /// True for hover triggered by `Space h` (sticky — Esc dismisses,
    /// scroll keys scroll). False for idle-timer auto-hover
    /// (dismissed by any keypress / cursor move).
    hover_sticky: bool = false,
    /// LSP has been asked, no response yet, and enough time has
    /// elapsed that we want to show a "Loading…" affordance. The
    /// 150 ms grace period keeps fast hovers from flickering.
    hover_loading: bool = false,

    /// Which-key panel: surfaces every available leader binding once
    /// the Space leader has been held idle for a short delay. `null`
    /// when the popup isn't currently visible.
    which_key_visible: bool = false,

    command_palette_query: ?[]const u8 = null,
    command_palette_results: ?[]const CommandEntry = null,
    command_palette_selected: usize = 0,

    go_to_line_input: ?[]const u8 = null,

    symbol_picker_query: ?[]const u8 = null,
    symbol_picker_results: ?[]const SymbolEntry = null,
    symbol_picker_selected: usize = 0,

    workspace_symbol_query: ?[]const u8 = null,
    workspace_symbol_results: ?[]const WorkspaceSymbolEntry = null,
    workspace_symbol_selected: usize = 0,
    workspace_symbol_pending: bool = false,

    completion_active: bool = false,
    completion_items: ?[]const CompletionEntry = null,
    completion_selected: usize = 0,

    /// LSP signature-help popup contents. Non-null only when the
    /// signature_help slot in Core holds a parsed response (i.e. the
    /// user just typed `(` or `,` and the server replied). The
    /// renderer drops a one-line overlay above the cursor.
    signature_help_label: ?[]const u8 = null,
    signature_help_active_parameter: u32 = 0,
    /// Slices into `signature_help_label` are *not* duped — the
    /// renderer only needs the param-label list to compute where to
    /// bold/underline. Param labels are owned by the snapshot arena.
    signature_help_parameters: ?[]const []const u8 = null,

    /// Inlay hints for the current viewport — point, label, kind.
    /// Owned by the snapshot arena (cloned in `clone`).
    inlay_hints: ?[]const InlayHintSnapshot = null,

    split_enabled: bool = false,
    panes: []const PaneSnapshot = &.{},
    focused_pane_id: u32 = 0,

    plugin_count: usize = 0,
    plugin_status_items: []const StatusItem = &.{},
    plugin_panels: []const PanelInfo = &.{},

    lsp_status: ?[]const u8 = null,

    logs: ?[]const LogEntry = null,

    editor_config: EditorConfigSnapshot = .{},

    global_search_query: ?[]const u8 = null,
    global_search_replace: ?[]const u8 = null,
    global_search_results: ?[]const GlobalSearchFileGroup = null,
    global_search_total_matches: usize = 0,
    global_search_total_files: usize = 0,
    global_search_selected_file: usize = 0,
    global_search_selected_match: usize = 0,
    global_search_focus_replace: bool = false,
    global_search_options: GlobalSearchOptions = .{},
    global_search_in_progress: bool = false,
    /// True once a search has actually run since the panel was opened. Used
    /// to distinguish the empty initial state from "0 matches".
    global_search_ran: bool = false,

    diff_highlight_lines: ?[]const DiffLineHighlight = null,
    /// Diagnostics for the currently visible buffer, sorted by line.
    diagnostics: ?[]const DiagnosticSnapshot = null,
    diagnostic_error_count: u32 = 0,
    diagnostic_warning_count: u32 = 0,

    /// Current git branch name, if the working dir is in a git repo.
    git_branch: ?[]const u8 = null,
    /// Number of jobs currently running in the JobManager.
    active_job_count: u32 = 0,

    status_message: ?[]const u8 = null,
    status_message_level: StatusLevel = .success,

    pub fn clone(self: RenderSnapshot, allocator: std.mem.Allocator) !RenderSnapshot {
        var new = self;

        const new_lines = try allocator.alloc([]const u8, self.visible_lines.len);
        for (self.visible_lines, 0..) |line, i| {
            new_lines[i] = try allocator.dupe(u8, line);
        }
        new.visible_lines = new_lines;

        if (self.terminal_output) |out| new.terminal_output = try allocator.dupe(u8, out);
        if (self.terminal_input) |in| new.terminal_input = try allocator.dupe(u8, in);
        if (self.terminal_cwd) |cwd| new.terminal_cwd = try allocator.dupe(u8, cwd);
        if (self.diff_highlight_lines) |lines| {
            new.diff_highlight_lines = try allocator.dupe(DiffLineHighlight, lines);
        }

        if (self.file_path) |path| new.file_path = try allocator.dupe(u8, path);

        const new_buffers = try allocator.alloc(BufferInfo, self.buffers.len);
        for (self.buffers, 0..) |buf, i| {
            new_buffers[i] = buf;
            new_buffers[i].name = try allocator.dupe(u8, buf.name);
        }
        new.buffers = new_buffers;

        if (self.file_picker_cwd) |cwd| new.file_picker_cwd = try allocator.dupe(u8, cwd);
        if (self.file_picker_entries) |entries| {
            const new_entries = try allocator.alloc(DirEntry, entries.len);
            for (entries, 0..) |entry, i| {
                new_entries[i] = entry;
                new_entries[i].name = try allocator.dupe(u8, entry.name);
            }
            new.file_picker_entries = new_entries;
        }

        if (self.save_as_input) |input| new.save_as_input = try allocator.dupe(u8, input);
        if (self.search_input) |input| new.search_input = try allocator.dupe(u8, input);
        if (self.buffer_picker_number_input) |input| new.buffer_picker_number_input = try allocator.dupe(u8, input);

        if (self.syntax_tokens) |tokens| {
            new.syntax_tokens = try allocator.dupe(SyntaxToken, tokens);
        }

        if (self.hover_content) |content| {
            new.hover_content = try allocator.dupe(u8, content);
        }

        if (self.hover_document) |doc| {
            new.hover_document = try doc.clone(allocator);
        }

        if (self.command_palette_query) |query| new.command_palette_query = try allocator.dupe(u8, query);
        if (self.command_palette_results) |results| {
            const new_results = try allocator.alloc(CommandEntry, results.len);
            for (results, 0..) |res, i| {
                new_results[i] = res;
                new_results[i].id = try allocator.dupe(u8, res.id);
                new_results[i].title = try allocator.dupe(u8, res.title);
                new_results[i].description = try allocator.dupe(u8, res.description);
            }
            new.command_palette_results = new_results;
        }

        if (self.go_to_line_input) |input| new.go_to_line_input = try allocator.dupe(u8, input);

        if (self.symbol_picker_query) |query| new.symbol_picker_query = try allocator.dupe(u8, query);
        if (self.symbol_picker_results) |results| {
            const new_results = try allocator.alloc(SymbolEntry, results.len);
            for (results, 0..) |res, i| {
                new_results[i] = res;
                new_results[i].name = try allocator.dupe(u8, res.name);
                new_results[i].kind = try allocator.dupe(u8, res.kind);
            }
            new.symbol_picker_results = new_results;
        }

        if (self.workspace_symbol_query) |query| new.workspace_symbol_query = try allocator.dupe(u8, query);
        if (self.workspace_symbol_results) |results| {
            const new_results = try allocator.alloc(WorkspaceSymbolEntry, results.len);
            for (results, 0..) |res, i| {
                new_results[i] = res;
                new_results[i].name = try allocator.dupe(u8, res.name);
                new_results[i].kind = try allocator.dupe(u8, res.kind);
                new_results[i].file_path = try allocator.dupe(u8, res.file_path);
            }
            new.workspace_symbol_results = new_results;
        }

        if (self.completion_items) |items| {
            const new_items = try allocator.alloc(CompletionEntry, items.len);
            for (items, 0..) |item, i| {
                new_items[i] = item;
                new_items[i].label = try allocator.dupe(u8, item.label);
                new_items[i].kind = try allocator.dupe(u8, item.kind);
                new_items[i].detail = try allocator.dupe(u8, item.detail);
            }
            new.completion_items = new_items;
        }

        const new_panes = try allocator.alloc(PaneSnapshot, self.panes.len);
        for (self.panes, 0..) |pane, i| {
            new_panes[i] = pane;
            const pane_lines = try allocator.alloc([]const u8, pane.visible_lines.len);
            for (pane.visible_lines, 0..) |line, j| {
                pane_lines[j] = try allocator.dupe(u8, line);
            }
            new_panes[i].visible_lines = pane_lines;

            if (pane.syntax_tokens) |tokens| {
                new_panes[i].syntax_tokens = try allocator.dupe(SyntaxToken, tokens);
            }

            if (pane.diff_highlights) |highlights| {
                new_panes[i].diff_highlights = try allocator.dupe(DiffLineHighlight, highlights);
            }
        }

        new.panes = new_panes;

        if (self.lsp_status) |status| new.lsp_status = try allocator.dupe(u8, status);

        if (self.logs) |logs| {
            const new_logs = try allocator.alloc(LogEntry, logs.len);
            for (logs, 0..) |log_entry, i| {
                new_logs[i] = log_entry;
                new_logs[i].scope = try allocator.dupe(u8, log_entry.scope);
                new_logs[i].message = try allocator.dupe(u8, log_entry.message);
            }
            new.logs = new_logs;
        }

        if (self.plugin_status_items.len > 0) {
            const new_items = try allocator.alloc(StatusItem, self.plugin_status_items.len);
            for (self.plugin_status_items, 0..) |item, i| {
                new_items[i] = item;
                new_items[i].id = try allocator.dupe(u8, item.id);
                new_items[i].plugin_id = try allocator.dupe(u8, item.plugin_id);
                new_items[i].text = try allocator.dupe(u8, item.text);
            }
            new.plugin_status_items = new_items;
        }

        if (self.plugin_panels.len > 0) {
            const new_panels = try allocator.alloc(PanelInfo, self.plugin_panels.len);
            for (self.plugin_panels, 0..) |panel, i| {
                new_panels[i] = panel;
                new_panels[i].id = try allocator.dupe(u8, panel.id);
                new_panels[i].plugin_id = try allocator.dupe(u8, panel.plugin_id);
                new_panels[i].title = try allocator.dupe(u8, panel.title);
                const new_content = try allocator.alloc([]const u8, panel.content.len);
                for (panel.content, 0..) |line, j| {
                    new_content[j] = try allocator.dupe(u8, line);
                }
                new_panels[i].content = new_content;
            }
            new.plugin_panels = new_panels;
        }

        if (self.global_search_query) |q| new.global_search_query = try allocator.dupe(u8, q);
        if (self.global_search_replace) |r| new.global_search_replace = try allocator.dupe(u8, r);
        if (self.global_search_results) |results| {
            const new_results = try allocator.alloc(GlobalSearchFileGroup, results.len);
            for (results, 0..) |group, i| {
                new_results[i] = group;
                new_results[i].file_path = try allocator.dupe(u8, group.file_path);
                const new_matches = try allocator.alloc(GlobalSearchMatch, group.matches.len);
                for (group.matches, 0..) |match, j| {
                    new_matches[j] = match;
                    new_matches[j].line_content = try allocator.dupe(u8, match.line_content);
                }
                new_results[i].matches = new_matches;
            }
            new.global_search_results = new_results;
        }

        if (self.status_message) |msg| new.status_message = try allocator.dupe(u8, msg);

        return new;
    }
};

pub const TerminalResult = struct {
    output: []const u8,
    exit_code: i32,
    success: bool,
};

pub const RenderUpdateMessage = struct {
    snapshot_ptr: usize,
    arena_ptr: usize,
    /// Pointer to the `ArenaPool` that produced `arena_ptr`. The receiver
    /// returns the arena via `pool.release(arena)` instead of deiniting it.
    pool_ptr: usize,
};

pub const Message = union(enum) {
    input: vaxis.Key,
    mouse: vaxis.Mouse,
    command: Command,
    render_update: RenderUpdateMessage,
    resize: vaxis.Winsize,
    mode_change: Mode,
    terminal_execute: []const u8,
    terminal_output_chunk: []const u8,
    terminal_result: TerminalResult,
    quit,
    tick,
    plugin_message: PluginMessage,
    focus: bool,

    const TAG_INPUT: u8 = 0;
    const TAG_MOUSE: u8 = 1;
    const TAG_COMMAND: u8 = 2;
    const TAG_RENDER_UPDATE: u8 = 3;
    const TAG_RESIZE: u8 = 4;
    const TAG_MODE_CHANGE: u8 = 5;
    const TAG_TERMINAL_EXECUTE: u8 = 6;
    const TAG_TERMINAL_OUTPUT: u8 = 7;
    const TAG_TERMINAL_RESULT: u8 = 8;
    pub const TAG_QUIT: u8 = 9;
    const TAG_TICK: u8 = 10;
    pub const TAG_PLUGIN_MSG: u8 = 11;
    const TAG_FOCUS: u8 = 12;

    pub fn encode(self: Message, allocator: std.mem.Allocator) ![]u8 {
        switch (self) {
            .plugin_message => |pm| {
                return pm.encode(allocator);
            },
            .focus => |f| {
                const buf = try allocator.alloc(u8, 2);
                buf[0] = TAG_FOCUS;
                buf[1] = if (f) 1 else 0;
                return buf;
            },
            .input => |key| {
                const text_len: u8 = if (key.text) |t| @intCast(@min(t.len, 255)) else 0;
                const buf = try allocator.alloc(u8, 7 + text_len);
                buf[0] = TAG_INPUT;
                const cp: u32 = @intCast(key.codepoint);
                buf[1] = @truncate(cp >> 24);
                buf[2] = @truncate(cp >> 16);
                buf[3] = @truncate(cp >> 8);
                buf[4] = @truncate(cp);
                var mods: u8 = 0;
                if (key.mods.shift) mods |= 0x01;
                if (key.mods.alt) mods |= 0x02;
                if (key.mods.ctrl) mods |= 0x04;
                if (key.mods.super) mods |= 0x08;
                buf[5] = mods;
                buf[6] = text_len;
                if (key.text) |t| {
                    @memcpy(buf[7..][0..text_len], t[0..text_len]);
                }
                return buf;
            },
            .mouse => |m| {
                const buf = try allocator.alloc(u8, 8);
                buf[0] = TAG_MOUSE;
                const col_u: u16 = @bitCast(m.col);
                const row_u: u16 = @bitCast(m.row);
                buf[1] = @truncate(col_u >> 8);
                buf[2] = @truncate(col_u);
                buf[3] = @truncate(row_u >> 8);
                buf[4] = @truncate(row_u);
                buf[5] = @intFromEnum(m.button);
                buf[6] = @intFromEnum(m.type);
                var mods: u8 = 0;
                if (m.mods.shift) mods |= 0x01;
                if (m.mods.alt) mods |= 0x02;
                if (m.mods.ctrl) mods |= 0x04;
                buf[7] = mods;
                return buf;
            },
            .command => |cmd| {
                const buf = try allocator.alloc(u8, 2);
                buf[0] = TAG_COMMAND;
                buf[1] = @intFromEnum(cmd);
                return buf;
            },
            .render_update => |ru| {
                const buf = try allocator.alloc(u8, 25);
                buf[0] = TAG_RENDER_UPDATE;
                const sp: u64 = @intCast(ru.snapshot_ptr);
                const ap: u64 = @intCast(ru.arena_ptr);
                const pp: u64 = @intCast(ru.pool_ptr);
                inline for (0..8) |i| {
                    buf[1 + i] = @truncate(sp >> @intCast((7 - i) * 8));
                    buf[9 + i] = @truncate(ap >> @intCast((7 - i) * 8));
                    buf[17 + i] = @truncate(pp >> @intCast((7 - i) * 8));
                }
                return buf;
            },
            .resize => |ws| {
                const buf = try allocator.alloc(u8, 5);
                buf[0] = TAG_RESIZE;
                buf[1] = @truncate(ws.rows >> 8);
                buf[2] = @truncate(ws.rows);
                buf[3] = @truncate(ws.cols >> 8);
                buf[4] = @truncate(ws.cols);
                return buf;
            },
            .mode_change => |mode| {
                const buf = try allocator.alloc(u8, 2);
                buf[0] = TAG_MODE_CHANGE;
                buf[1] = @intFromEnum(mode);
                return buf;
            },
            .terminal_execute => |text| {
                const buf = try allocator.alloc(u8, 5 + text.len);
                buf[0] = TAG_TERMINAL_EXECUTE;
                const len: u32 = @intCast(text.len);
                buf[1] = @truncate(len >> 24);
                buf[2] = @truncate(len >> 16);
                buf[3] = @truncate(len >> 8);
                buf[4] = @truncate(len);
                @memcpy(buf[5..], text);
                return buf;
            },
            .terminal_output_chunk => |text| {
                const buf = try allocator.alloc(u8, 5 + text.len);
                buf[0] = TAG_TERMINAL_OUTPUT;
                const len: u32 = @intCast(text.len);
                buf[1] = @truncate(len >> 24);
                buf[2] = @truncate(len >> 16);
                buf[3] = @truncate(len >> 8);
                buf[4] = @truncate(len);
                @memcpy(buf[5..], text);
                return buf;
            },
            .terminal_result => |tr| {
                const buf = try allocator.alloc(u8, 10 + tr.output.len);
                buf[0] = TAG_TERMINAL_RESULT;
                const ec: u32 = @bitCast(tr.exit_code);
                buf[1] = @truncate(ec >> 24);
                buf[2] = @truncate(ec >> 16);
                buf[3] = @truncate(ec >> 8);
                buf[4] = @truncate(ec);
                buf[5] = if (tr.success) 1 else 0;
                const len: u32 = @intCast(tr.output.len);
                buf[6] = @truncate(len >> 24);
                buf[7] = @truncate(len >> 16);
                buf[8] = @truncate(len >> 8);
                buf[9] = @truncate(len);
                @memcpy(buf[10..], tr.output);
                return buf;
            },
            .quit => {
                const buf = try allocator.alloc(u8, 1);
                buf[0] = TAG_QUIT;
                return buf;
            },
            .tick => {
                const buf = try allocator.alloc(u8, 1);
                buf[0] = TAG_TICK;
                return buf;
            },
        }
    }

    pub fn decode(bytes: []const u8) !Message {
        if (bytes.len == 0) return error.EmptyMessage;

        const tag = bytes[0];
        switch (tag) {
            TAG_INPUT => {
                if (bytes.len < 7) return error.InvalidMessage;
                const cp: u32 = @as(u32, bytes[1]) << 24 | @as(u32, bytes[2]) << 16 | @as(u32, bytes[3]) << 8 | bytes[4];
                const mods_byte = bytes[5];
                const text_len = bytes[6];
                const text: ?[]const u8 = if (text_len > 0 and bytes.len >= 7 + text_len)
                    bytes[7..][0..text_len]
                else
                    null;
                const codepoint = safe.intToCodepoint(cp) orelse return error.InvalidMessage;
                return .{ .input = .{
                    .codepoint = codepoint,
                    .mods = .{
                        .shift = mods_byte & 0x01 != 0,
                        .alt = mods_byte & 0x02 != 0,
                        .ctrl = mods_byte & 0x04 != 0,
                        .super = mods_byte & 0x08 != 0,
                    },
                    .text = text,
                } };
            },
            TAG_MOUSE => {
                if (bytes.len < 8) return error.InvalidMessage;
                const col_u: u16 = @as(u16, bytes[1]) << 8 | bytes[2];
                const row_u: u16 = @as(u16, bytes[3]) << 8 | bytes[4];
                const mods_byte = bytes[7];
                const button = safe.intToEnum(vaxis.Mouse.Button, bytes[5]) orelse return error.InvalidMessage;
                const mouse_type = safe.intToEnum(vaxis.Mouse.Type, bytes[6]) orelse return error.InvalidMessage;
                return .{ .mouse = .{
                    .col = @bitCast(col_u),
                    .row = @bitCast(row_u),
                    .button = button,
                    .type = mouse_type,
                    .mods = .{
                        .shift = mods_byte & 0x01 != 0,
                        .alt = mods_byte & 0x02 != 0,
                        .ctrl = mods_byte & 0x04 != 0,
                    },
                } };
            },
            TAG_COMMAND => {
                if (bytes.len < 2) return error.InvalidMessage;
                const cmd = safe.intToEnum(Command, bytes[1]) orelse return error.InvalidMessage;
                return .{ .command = cmd };
            },
            TAG_RENDER_UPDATE => {
                if (bytes.len < 25) return error.InvalidMessage;
                var sp: u64 = 0;
                var ap: u64 = 0;
                var pp: u64 = 0;
                inline for (0..8) |i| {
                    sp |= @as(u64, bytes[1 + i]) << @intCast((7 - i) * 8);
                    ap |= @as(u64, bytes[9 + i]) << @intCast((7 - i) * 8);
                    pp |= @as(u64, bytes[17 + i]) << @intCast((7 - i) * 8);
                }
                return .{ .render_update = .{
                    .snapshot_ptr = @intCast(sp),
                    .arena_ptr = @intCast(ap),
                    .pool_ptr = @intCast(pp),
                } };
            },
            TAG_RESIZE => {
                if (bytes.len < 5) return error.InvalidMessage;
                return .{ .resize = .{
                    .rows = @as(u16, bytes[1]) << 8 | bytes[2],
                    .cols = @as(u16, bytes[3]) << 8 | bytes[4],
                    .x_pixel = 0,
                    .y_pixel = 0,
                } };
            },
            TAG_MODE_CHANGE => {
                if (bytes.len < 2) return error.InvalidMessage;
                const m = safe.intToEnum(Mode, bytes[1]) orelse return error.InvalidMessage;
                return .{ .mode_change = m };
            },
            TAG_TERMINAL_EXECUTE => {
                if (bytes.len < 5) return error.InvalidMessage;
                const len: u32 = @as(u32, bytes[1]) << 24 | @as(u32, bytes[2]) << 16 | @as(u32, bytes[3]) << 8 | bytes[4];
                if (bytes.len < 5 + len) return error.InvalidMessage;
                return .{ .terminal_execute = bytes[5 .. 5 + len] };
            },
            TAG_TERMINAL_OUTPUT => {
                if (bytes.len < 5) return error.InvalidMessage;
                const len: u32 = @as(u32, bytes[1]) << 24 | @as(u32, bytes[2]) << 16 | @as(u32, bytes[3]) << 8 | bytes[4];
                if (bytes.len < 5 + len) return error.InvalidMessage;
                return .{ .terminal_output_chunk = bytes[5 .. 5 + len] };
            },
            TAG_TERMINAL_RESULT => {
                if (bytes.len < 10) return error.InvalidMessage;
                const ec: u32 = @as(u32, bytes[1]) << 24 | @as(u32, bytes[2]) << 16 | @as(u32, bytes[3]) << 8 | bytes[4];
                const len: u32 = @as(u32, bytes[6]) << 24 | @as(u32, bytes[7]) << 16 | @as(u32, bytes[8]) << 8 | bytes[9];
                if (bytes.len < 10 + len) return error.InvalidMessage;
                return .{ .terminal_result = .{
                    .output = bytes[10 .. 10 + len],
                    .exit_code = @bitCast(ec),
                    .success = bytes[5] != 0,
                } };
            },
            TAG_QUIT => return .quit,
            TAG_TICK => return .tick,
            TAG_PLUGIN_MSG => {
                if (bytes.len < 6) return error.InvalidMessage;
                const id_len = std.mem.readInt(u32, bytes[1..5], .big);
                if (bytes.len < 5 + id_len + 1) return error.InvalidMessage;
                return .{ .plugin_message = try PluginMessage.decode(bytes[1..]) };
            },
            TAG_FOCUS => {
                if (bytes.len < 2) return error.InvalidMessage;
                return .{ .focus = bytes[1] != 0 };
            },
            else => return error.UnknownTag,
        }
    }
};

pub const PluginMessage = struct {
    plugin_id: []const u8,
    message_type: PluginMessageType,
    payload: PluginPayload,
    /// Correlation ID for request/response matching. 0 = uncorrelated
    /// (events, fire-and-forget commands). Set by the SDK on outgoing
    /// requests and echoed back by core on the matching response, so a
    /// plugin can have multiple in-flight requests without their replies
    /// being mis-routed.
    correlation_id: u64 = 0,

    pub const PluginMessageType = enum(u8) {
        register_command = 0,
        unregister_command = 1,
        lsp_request = 2,
        lsp_response = 3,
        syntax_highlight = 4,
        ui_render = 5,
        file_operation = 6,

        custom_message = 7,

        execute_command = 8,

        get_state = 9,
        state_response = 10,

        subscribe_event = 11,
        unsubscribe_event = 12,
        event_notification = 13,

        get_config = 14,
        set_config = 15,
        config_response = 16,

        show_notification = 17,

        open_buffer = 18,
        get_buffer_content = 19,
        switch_buffer = 20,

        buffer_content_response = 21,

        create_status_item = 22,
        update_status_item = 23,
        destroy_status_item = 24,

        create_panel = 25,
        update_panel_content = 26,
        destroy_panel = 27,
        update_panel_scroll = 31,

        create_widget_id = 28,
        destroy_widget_id = 29,
        widget_id_response = 30,

        execute_core_command = 32,

        get_plugin_list = 33,
        get_plugin_list_response = 34,
        load_plugin = 36,
        unload_plugin = 37,

        emit_event = 35,

        plugin_log = 38,
    };

    pub const PluginPayload = union(enum) {
        command_register: CommandEntry,
        command_unregister: []const u8,
        lsp: []const u8,
        custom: []const u8,
        command_execute: []const u8,

        state_request: void,
        state: EditorStateView,

        event_subscribe: PluginEvent,
        event_unsubscribe: PluginEvent,
        event_notification: struct {
            event: PluginEvent,
            data: []const u8,
        },

        config_get: []const u8,
        config_set: struct {
            key: []const u8,
            value: []const u8,
        },
        config_value: struct {
            key: []const u8,
            value: ?[]const u8,
        },

        notification: struct {
            level: NotificationLevel,
            message: []const u8,
        },

        buffer_open: struct {
            name: []const u8,
            content: []const u8,
        },
        buffer_content_request: void,
        buffer_content_response: struct {
            id: u32,
            content: []const u8,
        },
        buffer_switch: u32,

        status_item_create: struct {
            id: []const u8,
            text: []const u8,
            alignment: StatusAlignment,
            priority: i8,
        },
        status_item_update: struct {
            id: []const u8,
            text: []const u8,
        },
        status_item_destroy: []const u8,

        panel_create: struct {
            id: []const u8,
            title: []const u8,
            position: PanelPosition,
            width_percent: u8,
        },
        panel_content_update: struct {
            id: []const u8,
            content: []const u8,
        },
        panel_destroy: []const u8,
        panel_scroll_update: struct {
            id: []const u8,
            offset: u32,
        },

        plugin_list_request: void,
        plugin_list_data: []const u8,

        plugin_load: []const u8,
        plugin_unload: []const u8,

        emit_event: struct {
            name: []const u8,
            data: []const u8,
        },

        plugin_log: struct {
            level: u8,
            message: []const u8,
        },
    };

    pub fn encode(self: PluginMessage, allocator: std.mem.Allocator) ![]u8 {
        const id_len: u32 = @intCast(self.plugin_id.len);

        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        const writer = &aw.writer;
        switch (self.payload) {
            .command_register => |cmd| {
                try writer.writeInt(u32, @intCast(cmd.title.len), .big);
                try writer.writeAll(cmd.title);
                try writer.writeInt(u32, @intCast(cmd.description.len), .big);
                try writer.writeAll(cmd.description);
                try writer.writeInt(u32, @intCast(cmd.id.len), .big);
                try writer.writeAll(cmd.id);
            },
            .command_unregister => |id| {
                try writer.writeAll(id);
            },
            .custom => |data| {
                try writer.writeAll(data);
            },
            .command_execute => |id| {
                try writer.writeAll(id);
            },
            .state_request => {},

            .event_subscribe => |event| {
                try writer.writeByte(@intFromEnum(event));
            },
            .event_unsubscribe => |event| {
                try writer.writeByte(@intFromEnum(event));
            },
            .event_notification => |notif| {
                try writer.writeByte(@intFromEnum(notif.event));
                try writer.writeInt(u32, @intCast(notif.data.len), .big);
                try writer.writeAll(notif.data);
            },
            .config_get => |key| {
                try writer.writeInt(u32, @intCast(key.len), .big);
                try writer.writeAll(key);
            },
            .config_set => |cfg| {
                try writer.writeInt(u32, @intCast(cfg.key.len), .big);
                try writer.writeAll(cfg.key);
                try writer.writeInt(u32, @intCast(cfg.value.len), .big);
                try writer.writeAll(cfg.value);
            },
            .config_value => |cfg| {
                try writer.writeInt(u32, @intCast(cfg.key.len), .big);
                try writer.writeAll(cfg.key);
                if (cfg.value) |v| {
                    try writer.writeByte(1);
                    try writer.writeInt(u32, @intCast(v.len), .big);
                    try writer.writeAll(v);
                } else {
                    try writer.writeByte(0);
                }
            },
            .notification => |notif| {
                try writer.writeByte(@intFromEnum(notif.level));
                try writer.writeInt(u32, @intCast(notif.message.len), .big);
                try writer.writeAll(notif.message);
            },
            .buffer_open => |buf| {
                try writer.writeInt(u32, @intCast(buf.name.len), .big);
                try writer.writeAll(buf.name);
                try writer.writeInt(u32, @intCast(buf.content.len), .big);
                try writer.writeAll(buf.content);
            },
            .buffer_content_request => {},
            .buffer_content_response => |resp| {
                try writer.writeInt(u32, resp.id, .big);
                try writer.writeInt(u32, @intCast(resp.content.len), .big);
                try writer.writeAll(resp.content);
            },
            .buffer_switch => |id| {
                try writer.writeInt(u32, id, .big);
            },
            .lsp => |data| {
                try writer.writeAll(data);
            },
            .state => |st| {
                if (st.file_path) |path| {
                    try writer.writeByte(1);
                    try writer.writeInt(u32, @intCast(path.len), .big);
                    try writer.writeAll(path);
                } else {
                    try writer.writeByte(0);
                }
                try writer.writeByte(if (st.file_modified) 1 else 0);
                try writer.writeInt(u64, @intCast(st.cursor_row), .big);
                try writer.writeInt(u64, @intCast(st.cursor_col), .big);
                try writer.writeByte(@intFromEnum(st.mode));
                try writer.writeInt(u32, st.buffer_id, .big);
                try writer.writeInt(u32, @intCast(st.buffer_name.len), .big);
                try writer.writeAll(st.buffer_name);
                try writer.writeInt(u64, @intCast(st.total_lines), .big);
                if (st.selection_start_row) |val| {
                    try writer.writeByte(1);
                    try writer.writeInt(u64, @intCast(val), .big);
                } else {
                    try writer.writeByte(0);
                }
                if (st.selection_start_col) |val| {
                    try writer.writeByte(1);
                    try writer.writeInt(u64, @intCast(val), .big);
                } else {
                    try writer.writeByte(0);
                }
                if (st.selection_end_row) |val| {
                    try writer.writeByte(1);
                    try writer.writeInt(u64, @intCast(val), .big);
                } else {
                    try writer.writeByte(0);
                }
                if (st.selection_end_col) |val| {
                    try writer.writeByte(1);
                    try writer.writeInt(u64, @intCast(val), .big);
                } else {
                    try writer.writeByte(0);
                }
            },

            .status_item_create => |item| {
                try writer.writeInt(u32, @intCast(item.id.len), .big);
                try writer.writeAll(item.id);
                try writer.writeInt(u32, @intCast(item.text.len), .big);
                try writer.writeAll(item.text);
                try writer.writeByte(@intFromEnum(item.alignment));
                try writer.writeInt(i8, item.priority, .big);
            },
            .status_item_update => |item| {
                try writer.writeInt(u32, @intCast(item.id.len), .big);
                try writer.writeAll(item.id);
                try writer.writeInt(u32, @intCast(item.text.len), .big);
                try writer.writeAll(item.text);
            },
            .status_item_destroy => |id| {
                try writer.writeInt(u32, @intCast(id.len), .big);
                try writer.writeAll(id);
            },

            .panel_create => |panel| {
                try writer.writeInt(u32, @intCast(panel.id.len), .big);
                try writer.writeAll(panel.id);
                try writer.writeInt(u32, @intCast(panel.title.len), .big);
                try writer.writeAll(panel.title);
                try writer.writeByte(@intFromEnum(panel.position));
                try writer.writeByte(panel.width_percent);
            },
            .panel_content_update => |panel| {
                try writer.writeInt(u32, @intCast(panel.id.len), .big);
                try writer.writeAll(panel.id);
                try writer.writeInt(u32, @intCast(panel.content.len), .big);
                try writer.writeAll(panel.content);
            },
            .panel_destroy => |id| {
                try writer.writeInt(u32, @intCast(id.len), .big);
                try writer.writeAll(id);
            },
            .plugin_list_request => {},
            .plugin_list_data => |data| {
                try writer.writeAll(data);
            },
            .plugin_load => |path| {
                try writer.writeInt(u32, @intCast(path.len), .big);
                try writer.writeAll(path);
            },
            .plugin_unload => |id| {
                try writer.writeInt(u32, @intCast(id.len), .big);
                try writer.writeAll(id);
            },
            .emit_event => |event| {
                try writer.writeInt(u32, @intCast(event.name.len), .big);
                try writer.writeAll(event.name);
                try writer.writeInt(u32, @intCast(event.data.len), .big);
                try writer.writeAll(event.data);
            },
            .panel_scroll_update => |scroll| {
                try writer.writeInt(u32, @intCast(scroll.id.len), .big);
                try writer.writeAll(scroll.id);
                try writer.writeInt(u32, scroll.offset, .big);
            },
            .plugin_log => |log_msg| {
                try writer.writeByte(log_msg.level);
                try writer.writeInt(u32, @intCast(log_msg.message.len), .big);
                try writer.writeAll(log_msg.message);
            },
        }
        const payload_slice = aw.written();
        // Wire layout: [tag][id_len:u32][id][type:u8][correlation:u64][payload_len:u32][payload]
        const total_len = 1 + 4 + id_len + 1 + 8 + 4 + payload_slice.len;
        const buf = try allocator.alloc(u8, total_len);

        buf[0] = Message.TAG_PLUGIN_MSG;
        std.mem.writeInt(u32, buf[1..][0..4], id_len, .big);
        @memcpy(buf[5..][0..id_len], self.plugin_id);

        const type_idx = 5 + id_len;
        buf[type_idx] = @intFromEnum(self.message_type);

        const corr_idx = type_idx + 1;
        std.mem.writeInt(u64, buf[corr_idx..][0..8], self.correlation_id, .big);

        const len_idx = corr_idx + 8;
        std.mem.writeInt(u32, buf[len_idx..][0..4], @intCast(payload_slice.len), .big);

        const payload_idx = len_idx + 4;
        if (payload_slice.len > 0) {
            @memcpy(buf[payload_idx..], payload_slice);
        }

        return buf;
    }

    pub fn decode(bytes: []const u8) !PluginMessage {
        if (bytes.len < 4) return error.InvalidMessage;
        const id_len = std.mem.readInt(u32, bytes[0..4], .big);
        // header bytes after id: type(1) + correlation(8) + payload_len(4) = 13
        if (bytes.len < 4 + id_len + 13) return error.InvalidMessage;

        const id = bytes[4..][0..id_len];
        const type_idx = 4 + id_len;
        const msg_type: PluginMessageType = safe.intToEnum(PluginMessageType, bytes[type_idx]) orelse return error.InvalidMessage;

        const corr_idx = type_idx + 1;
        const correlation_id = std.mem.readInt(u64, bytes[corr_idx..][0..8], .big);

        const len_idx = corr_idx + 8;
        const payload_len = std.mem.readInt(u32, bytes[len_idx..][0..4], .big);

        const payload_idx = len_idx + 4;
        if (bytes.len < payload_idx + payload_len) return error.InvalidMessage;

        const payload_data = bytes[payload_idx..][0..payload_len];

        var payload: PluginPayload = undefined;

        switch (msg_type) {
            .register_command => {
                if (payload_data.len < 8) return error.InvalidMessage;
                var offset: usize = 0;

                const title_len = std.mem.readInt(u32, payload_data[offset..][0..4], .big);
                offset += 4;
                if (payload_data.len < offset + title_len) return error.InvalidMessage;
                const title = payload_data[offset..][0..title_len];
                offset += title_len;

                const desc_len = std.mem.readInt(u32, payload_data[offset..][0..4], .big);
                offset += 4;
                if (payload_data.len < offset + desc_len) return error.InvalidMessage;
                const desc = payload_data[offset..][0..desc_len];
                offset += desc_len;

                const cmd_id_len = std.mem.readInt(u32, payload_data[offset..][0..4], .big);
                offset += 4;
                if (payload_data.len < offset + cmd_id_len) return error.InvalidMessage;
                const cmd_id = payload_data[offset..][0..cmd_id_len];

                payload = .{ .command_register = .{
                    .id = cmd_id,
                    .title = title,
                    .description = desc,
                } };
            },
            .custom_message => {
                payload = .{ .custom = payload_data };
            },
            .execute_command => {
                payload = .{ .command_execute = payload_data };
            },
            .get_state => {
                payload = .{ .state_request = {} };
            },
            .state_response => {
                var offset: usize = 0;
                if (payload_data.len < offset + 1) return error.InvalidMessage;
                const has_path = payload_data[offset] == 1;
                offset += 1;
                const file_path: ?[]const u8 = if (has_path) blk: {
                    if (payload_data.len < offset + 4) return error.InvalidMessage;
                    const len = std.mem.readInt(u32, payload_data[offset..][0..4], .big);
                    offset += 4;
                    if (payload_data.len < offset + len) return error.InvalidMessage;
                    const s = payload_data[offset..][0..len];
                    offset += len;
                    break :blk s;
                } else null;

                if (payload_data.len < offset + 1) return error.InvalidMessage;
                const file_modified = payload_data[offset] == 1;
                offset += 1;

                if (payload_data.len < offset + 8) return error.InvalidMessage;
                const cursor_row = std.mem.readInt(u64, payload_data[offset..][0..8], .big);
                offset += 8;

                if (payload_data.len < offset + 8) return error.InvalidMessage;
                const cursor_col = std.mem.readInt(u64, payload_data[offset..][0..8], .big);
                offset += 8;

                if (payload_data.len < offset + 1) return error.InvalidMessage;
                const mode: Mode = safe.intToEnum(Mode, payload_data[offset]) orelse return error.InvalidMessage;
                offset += 1;

                if (payload_data.len < offset + 4) return error.InvalidMessage;
                const buffer_id = std.mem.readInt(u32, payload_data[offset..][0..4], .big);
                offset += 4;

                if (payload_data.len < offset + 4) return error.InvalidMessage;
                const name_len = std.mem.readInt(u32, payload_data[offset..][0..4], .big);
                offset += 4;
                if (payload_data.len < offset + name_len) return error.InvalidMessage;
                const buffer_name = payload_data[offset..][0..name_len];
                offset += name_len;

                if (payload_data.len < offset + 8) return error.InvalidMessage;
                const total_lines = std.mem.readInt(u64, payload_data[offset..][0..8], .big);
                offset += 8;

                const readOptionalUsize = struct {
                    fn read(data: []const u8, off: *usize) !?usize {
                        if (data.len < off.* + 1) return error.InvalidMessage;
                        const has = data[off.*] == 1;
                        off.* += 1;
                        if (has) {
                            if (data.len < off.* + 8) return error.InvalidMessage;
                            const val = std.mem.readInt(u64, data[off.*..][0..8], .big);
                            off.* += 8;
                            return @intCast(val);
                        }
                        return null;
                    }
                }.read;

                const sel_start_row = try readOptionalUsize(payload_data, &offset);
                const sel_start_col = try readOptionalUsize(payload_data, &offset);
                const sel_end_row = try readOptionalUsize(payload_data, &offset);
                const sel_end_col = try readOptionalUsize(payload_data, &offset);

                payload = .{ .state = .{
                    .file_path = file_path,
                    .file_modified = file_modified,
                    .cursor_row = @intCast(cursor_row),
                    .cursor_col = @intCast(cursor_col),
                    .mode = mode,
                    .buffer_id = buffer_id,
                    .buffer_name = buffer_name,
                    .total_lines = @intCast(total_lines),
                    .selection_start_row = sel_start_row,
                    .selection_start_col = sel_start_col,
                    .selection_end_row = sel_end_row,
                    .selection_end_col = sel_end_col,
                } };
            },
            .subscribe_event => {
                if (payload_data.len < 1) return error.InvalidMessage;
                const ev = safe.intToEnum(PluginEvent, payload_data[0]) orelse return error.InvalidMessage;
                payload = .{ .event_subscribe = ev };
            },
            .unsubscribe_event => {
                if (payload_data.len < 1) return error.InvalidMessage;
                const ev = safe.intToEnum(PluginEvent, payload_data[0]) orelse return error.InvalidMessage;
                payload = .{ .event_unsubscribe = ev };
            },
            .event_notification => {
                if (payload_data.len < 5) return error.InvalidMessage;
                const event: PluginEvent = safe.intToEnum(PluginEvent, payload_data[0]) orelse return error.InvalidMessage;
                const data_len = std.mem.readInt(u32, payload_data[1..5], .big);
                if (payload_data.len < 5 + data_len) return error.InvalidMessage;
                payload = .{ .event_notification = .{
                    .event = event,
                    .data = payload_data[5..][0..data_len],
                } };
            },
            .get_config => {
                if (payload_data.len < 4) return error.InvalidMessage;
                const key_len = std.mem.readInt(u32, payload_data[0..4], .big);
                if (payload_data.len < 4 + key_len) return error.InvalidMessage;
                payload = .{ .config_get = payload_data[4..][0..key_len] };
            },
            .set_config => {
                if (payload_data.len < 8) return error.InvalidMessage;
                var offset: usize = 0;
                const key_len = std.mem.readInt(u32, payload_data[offset..][0..4], .big);
                offset += 4;
                if (payload_data.len < offset + key_len + 4) return error.InvalidMessage;
                const key = payload_data[offset..][0..key_len];
                offset += key_len;
                const val_len = std.mem.readInt(u32, payload_data[offset..][0..4], .big);
                offset += 4;
                if (payload_data.len < offset + val_len) return error.InvalidMessage;
                payload = .{ .config_set = .{
                    .key = key,
                    .value = payload_data[offset..][0..val_len],
                } };
            },
            .config_response => {
                if (payload_data.len < 5) return error.InvalidMessage;
                var offset: usize = 0;
                const key_len = std.mem.readInt(u32, payload_data[offset..][0..4], .big);
                offset += 4;
                if (payload_data.len < offset + key_len + 1) return error.InvalidMessage;
                const key = payload_data[offset..][0..key_len];
                offset += key_len;
                const has_val = payload_data[offset] == 1;
                offset += 1;
                const val: ?[]const u8 = if (has_val) blk: {
                    if (payload_data.len < offset + 4) break :blk null;
                    const val_len = std.mem.readInt(u32, payload_data[offset..][0..4], .big);
                    offset += 4;
                    if (payload_data.len < offset + val_len) break :blk null;
                    break :blk payload_data[offset..][0..val_len];
                } else null;
                payload = .{ .config_value = .{ .key = key, .value = val } };
            },
            .show_notification => {
                if (payload_data.len < 5) return error.InvalidMessage;
                const level: NotificationLevel = safe.intToEnum(NotificationLevel, payload_data[0]) orelse return error.InvalidMessage;
                const msg_len = std.mem.readInt(u32, payload_data[1..5], .big);
                if (payload_data.len < 5 + msg_len) return error.InvalidMessage;
                payload = .{ .notification = .{
                    .level = level,
                    .message = payload_data[5..][0..msg_len],
                } };
            },
            .open_buffer => {
                if (payload_data.len < 8) return error.InvalidMessage;
                var offset: usize = 0;
                const name_len = std.mem.readInt(u32, payload_data[offset..][0..4], .big);
                offset += 4;
                if (payload_data.len < offset + name_len + 4) return error.InvalidMessage;
                const name = payload_data[offset..][0..name_len];
                offset += name_len;
                const content_len = std.mem.readInt(u32, payload_data[offset..][0..4], .big);
                offset += 4;
                if (payload_data.len < offset + content_len) return error.InvalidMessage;
                payload = .{ .buffer_open = .{
                    .name = name,
                    .content = payload_data[offset..][0..content_len],
                } };
            },
            .get_buffer_content => {
                payload = .{ .buffer_content_request = {} };
            },
            .switch_buffer => {
                if (payload_data.len < 4) return error.InvalidMessage;
                const buf_id = std.mem.readInt(u32, payload_data[0..4], .big);
                payload = .{ .buffer_switch = buf_id };
            },
            .buffer_content_response => {
                if (payload_data.len < 8) return error.InvalidMessage;
                var offset: usize = 0;
                const buf_id = std.mem.readInt(u32, payload_data[offset..][0..4], .big);
                offset += 4;
                const content_len = std.mem.readInt(u32, payload_data[offset..][0..4], .big);
                offset += 4;
                if (payload_data.len < offset + content_len) return error.InvalidMessage;
                payload = .{ .buffer_content_response = .{
                    .id = buf_id,
                    .content = payload_data[offset..][0..content_len],
                } };
            },

            .create_status_item => {
                if (payload_data.len < 10) return error.InvalidMessage;
                var offset: usize = 0;
                const status_id_len = std.mem.readInt(u32, payload_data[offset..][0..4], .big);
                offset += 4;
                if (payload_data.len < offset + status_id_len) return error.InvalidMessage;
                const item_id = payload_data[offset..][0..status_id_len];
                offset += status_id_len;
                const text_len = std.mem.readInt(u32, payload_data[offset..][0..4], .big);
                offset += 4;
                if (payload_data.len < offset + text_len + 2) return error.InvalidMessage;
                const text = payload_data[offset..][0..text_len];
                offset += text_len;
                const alignment: StatusAlignment = safe.intToEnum(StatusAlignment, payload_data[offset]) orelse return error.InvalidMessage;
                offset += 1;
                const priority: i8 = @bitCast(payload_data[offset]);
                payload = .{ .status_item_create = .{
                    .id = item_id,
                    .text = text,
                    .alignment = alignment,
                    .priority = priority,
                } };
            },
            .update_status_item => {
                if (payload_data.len < 8) return error.InvalidMessage;
                var offset: usize = 0;
                const upd_id_len = std.mem.readInt(u32, payload_data[offset..][0..4], .big);
                offset += 4;
                if (payload_data.len < offset + upd_id_len) return error.InvalidMessage;
                const item_id = payload_data[offset..][0..upd_id_len];
                offset += upd_id_len;
                const text_len = std.mem.readInt(u32, payload_data[offset..][0..4], .big);
                offset += 4;
                if (payload_data.len < offset + text_len) return error.InvalidMessage;
                const text = payload_data[offset..][0..text_len];
                payload = .{ .status_item_update = .{
                    .id = item_id,
                    .text = text,
                } };
            },
            .destroy_status_item => {
                if (payload_data.len < 4) return error.InvalidMessage;
                const del_id_len = std.mem.readInt(u32, payload_data[0..4], .big);
                if (payload_data.len < 4 + del_id_len) return error.InvalidMessage;
                payload = .{ .status_item_destroy = payload_data[4..][0..del_id_len] };
            },

            .create_panel => {
                if (payload_data.len < 10) return error.InvalidMessage;
                var offset: usize = 0;
                const panel_id_len = std.mem.readInt(u32, payload_data[offset..][0..4], .big);
                offset += 4;
                if (payload_data.len < offset + panel_id_len) return error.InvalidMessage;
                const panel_id = payload_data[offset..][0..panel_id_len];
                offset += panel_id_len;
                const title_len = std.mem.readInt(u32, payload_data[offset..][0..4], .big);
                offset += 4;
                if (payload_data.len < offset + title_len + 2) return error.InvalidMessage;
                const title = payload_data[offset..][0..title_len];
                offset += title_len;
                const position = safe.intToEnum(PanelPosition, payload_data[offset]) orelse return error.InvalidMessage;
                offset += 1;
                // Clamp plugin-supplied percent to [0, 100] so the renderer's
                // u16 multiplication can't overflow.
                const width_percent = @min(payload_data[offset], @as(u8, 100));
                payload = .{ .panel_create = .{
                    .id = panel_id,
                    .title = title,
                    .position = position,
                    .width_percent = width_percent,
                } };
            },
            .update_panel_content => {
                if (payload_data.len < 8) return error.InvalidMessage;
                var offset: usize = 0;
                const upd_panel_id_len = std.mem.readInt(u32, payload_data[offset..][0..4], .big);
                offset += 4;
                if (payload_data.len < offset + upd_panel_id_len) return error.InvalidMessage;
                const panel_id = payload_data[offset..][0..upd_panel_id_len];
                offset += upd_panel_id_len;
                const content_len = std.mem.readInt(u32, payload_data[offset..][0..4], .big);
                offset += 4;
                if (payload_data.len < offset + content_len) return error.InvalidMessage;
                const content = payload_data[offset..][0..content_len];

                payload = .{ .panel_content_update = .{
                    .id = panel_id,
                    .content = content,
                } };
            },
            .update_panel_scroll => {
                if (payload_data.len < 8) return error.InvalidMessage;
                var offset: usize = 0;
                const scroll_panel_id_len = std.mem.readInt(u32, payload_data[offset..][0..4], .big);
                offset += 4;
                if (payload_data.len < offset + scroll_panel_id_len) return error.InvalidMessage;
                const p_id = payload_data[offset..][0..scroll_panel_id_len];
                offset += scroll_panel_id_len;

                if (payload_data.len < offset + 4) return error.InvalidMessage;
                const scroll_offset = std.mem.readInt(u32, payload_data[offset..][0..4], .big);

                payload = .{ .panel_scroll_update = .{
                    .id = p_id,
                    .offset = scroll_offset,
                } };
            },
            .destroy_panel => {
                if (payload_data.len < 4) return error.InvalidMessage;
                const del_panel_id_len = std.mem.readInt(u32, payload_data[0..4], .big);
                if (payload_data.len < 4 + del_panel_id_len) return error.InvalidMessage;
                payload = .{ .panel_destroy = payload_data[4..][0..del_panel_id_len] };
            },
            .get_plugin_list => {
                payload = .{ .plugin_list_request = {} };
            },
            .get_plugin_list_response => {
                payload = .{ .plugin_list_data = payload_data };
            },
            .emit_event => {
                if (payload_data.len < 8) return error.InvalidMessage;
                var offset: usize = 0;
                const name_len = std.mem.readInt(u32, payload_data[offset..][0..4], .big);
                offset += 4;
                if (payload_data.len < offset + name_len + 4) return error.InvalidMessage;
                const name = payload_data[offset..][0..name_len];
                offset += name_len;
                const data_len = std.mem.readInt(u32, payload_data[offset..][0..4], .big);
                offset += 4;
                if (payload_data.len < offset + data_len) return error.InvalidMessage;
                const p_data = payload_data[offset..][0..data_len];
                payload = .{ .emit_event = .{ .name = name, .data = p_data } };
            },
            .load_plugin => {
                if (payload_data.len < 4) return error.InvalidMessage;
                const path_len = std.mem.readInt(u32, payload_data[0..4], .big);
                if (payload_data.len < 4 + path_len) return error.InvalidMessage;
                payload = .{ .plugin_load = payload_data[4..][0..path_len] };
            },
            .unload_plugin => {
                if (payload_data.len < 4) return error.InvalidMessage;
                const unload_id_len = std.mem.readInt(u32, payload_data[0..4], .big);
                if (payload_data.len < 4 + unload_id_len) return error.InvalidMessage;
                payload = .{ .plugin_unload = payload_data[4..][0..unload_id_len] };
            },
            .plugin_log => {
                if (payload_data.len < 5) return error.InvalidMessage;
                const level = payload_data[0];
                const msg_len = std.mem.readInt(u32, payload_data[1..5], .big);
                if (payload_data.len < 5 + msg_len) return error.InvalidMessage;
                const message = payload_data[5..][0..msg_len];
                payload = .{ .plugin_log = .{ .level = level, .message = message } };
            },

            else => return error.NotImplemented,
        }

        return PluginMessage{
            .plugin_id = id,
            .message_type = msg_type,
            .payload = payload,
            .correlation_id = correlation_id,
        };
    }
};

pub const Command = enum {
    save,
    open,
    close,
    next_buffer,
    prev_buffer,
    quit,
};

test "mode enum values" {
    try std.testing.expect(@intFromEnum(Mode.select) != @intFromEnum(Mode.insert));
    try std.testing.expect(@intFromEnum(Mode.insert) != @intFromEnum(Mode.visual));
    try std.testing.expect(@intFromEnum(Mode.terminal) != @intFromEnum(Mode.file_picker));

    const mode: Mode = .command_palette;
    const mode_int = @intFromEnum(mode);
    const back: Mode = @enumFromInt(mode_int);
    try std.testing.expectEqual(mode, back);
}

test "command enum values" {
    try std.testing.expect(@intFromEnum(Command.save) != @intFromEnum(Command.open));
    try std.testing.expect(@intFromEnum(Command.close) != @intFromEnum(Command.quit));

    const cmd: Command = .next_buffer;
    const cmd_int = @intFromEnum(cmd);
    const back: Command = @enumFromInt(cmd_int);
    try std.testing.expectEqual(cmd, back);
}

test "plugin event enum values" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(PluginEvent.buffer_changed));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(PluginEvent.cursor_moved));
    try std.testing.expectEqual(@as(u8, 5), @intFromEnum(PluginEvent.buffer_switched));
}

test "notification level enum values" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(NotificationLevel.info));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(NotificationLevel.warning));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(NotificationLevel.err));
}

test "syntax token type enum" {
    const token_type: SyntaxToken.TokenType = .keyword;
    try std.testing.expectEqual(SyntaxToken.TokenType.keyword, token_type);

    try std.testing.expect(@intFromEnum(SyntaxToken.TokenType.keyword) != @intFromEnum(SyntaxToken.TokenType.function));
    try std.testing.expect(@intFromEnum(SyntaxToken.TokenType.string) != @intFromEnum(SyntaxToken.TokenType.number));
}

test "message encode decode quit" {
    const allocator = std.testing.allocator;

    const msg = Message{ .quit = {} };
    const bytes = try msg.encode(allocator);
    defer allocator.free(bytes);

    try std.testing.expectEqual(@as(usize, 1), bytes.len);
    try std.testing.expectEqual(Message.TAG_QUIT, bytes[0]);

    const decoded = try Message.decode(bytes);
    try std.testing.expectEqual(Message.quit, decoded);
}

test "message encode decode tick" {
    const allocator = std.testing.allocator;

    const msg = Message{ .tick = {} };
    const bytes = try msg.encode(allocator);
    defer allocator.free(bytes);

    try std.testing.expectEqual(@as(usize, 1), bytes.len);
    try std.testing.expectEqual(Message.TAG_TICK, bytes[0]);

    const decoded = try Message.decode(bytes);
    try std.testing.expectEqual(Message.tick, decoded);
}

test "message encode decode command" {
    const allocator = std.testing.allocator;

    const msg = Message{ .command = .save };
    const bytes = try msg.encode(allocator);
    defer allocator.free(bytes);

    try std.testing.expectEqual(@as(usize, 2), bytes.len);

    const decoded = try Message.decode(bytes);
    try std.testing.expectEqual(Command.save, decoded.command);
}

test "message encode decode mode_change" {
    const allocator = std.testing.allocator;

    const msg = Message{ .mode_change = .insert };
    const bytes = try msg.encode(allocator);
    defer allocator.free(bytes);

    const decoded = try Message.decode(bytes);
    try std.testing.expectEqual(Mode.insert, decoded.mode_change);
}

test "message encode decode resize" {
    const allocator = std.testing.allocator;

    const msg = Message{ .resize = .{
        .rows = 50,
        .cols = 120,
        .x_pixel = 0,
        .y_pixel = 0,
    } };
    const bytes = try msg.encode(allocator);
    defer allocator.free(bytes);

    try std.testing.expectEqual(@as(usize, 5), bytes.len);

    const decoded = try Message.decode(bytes);
    try std.testing.expectEqual(@as(u16, 50), decoded.resize.rows);
    try std.testing.expectEqual(@as(u16, 120), decoded.resize.cols);
}

test "message encode decode terminal_execute" {
    const allocator = std.testing.allocator;

    const command = "ls -la";
    const msg = Message{ .terminal_execute = command };
    const bytes = try msg.encode(allocator);
    defer allocator.free(bytes);

    const decoded = try Message.decode(bytes);
    try std.testing.expectEqualStrings(command, decoded.terminal_execute);
}

test "message encode decode terminal_output" {
    const allocator = std.testing.allocator;

    const output = "file1.txt\nfile2.txt\n";
    const msg = Message{ .terminal_output_chunk = output };
    const bytes = try msg.encode(allocator);
    defer allocator.free(bytes);

    const decoded = try Message.decode(bytes);
    try std.testing.expectEqualStrings(output, decoded.terminal_output_chunk);
}

test "message encode decode terminal_result" {
    const allocator = std.testing.allocator;

    const msg = Message{ .terminal_result = .{
        .output = "Success output",
        .exit_code = 0,
        .success = true,
    } };
    const bytes = try msg.encode(allocator);
    defer allocator.free(bytes);

    const decoded = try Message.decode(bytes);
    try std.testing.expectEqualStrings("Success output", decoded.terminal_result.output);
    try std.testing.expectEqual(@as(i32, 0), decoded.terminal_result.exit_code);
    try std.testing.expect(decoded.terminal_result.success);
}

test "message encode decode terminal_result failure" {
    const allocator = std.testing.allocator;

    const msg = Message{ .terminal_result = .{
        .output = "Error: command not found",
        .exit_code = 127,
        .success = false,
    } };
    const bytes = try msg.encode(allocator);
    defer allocator.free(bytes);

    const decoded = try Message.decode(bytes);
    try std.testing.expectEqual(@as(i32, 127), decoded.terminal_result.exit_code);
    try std.testing.expect(!decoded.terminal_result.success);
}

test "message encode decode render_update" {
    const allocator = std.testing.allocator;

    const msg = Message{ .render_update = .{
        .snapshot_ptr = 0x12345678,
        .arena_ptr = 0x87654321,
        .pool_ptr = 0xDEADBEEF,
    } };
    const bytes = try msg.encode(allocator);
    defer allocator.free(bytes);

    try std.testing.expectEqual(@as(usize, 25), bytes.len);

    const decoded = try Message.decode(bytes);
    try std.testing.expectEqual(@as(usize, 0x12345678), decoded.render_update.snapshot_ptr);
    try std.testing.expectEqual(@as(usize, 0x87654321), decoded.render_update.arena_ptr);
    try std.testing.expectEqual(@as(usize, 0xDEADBEEF), decoded.render_update.pool_ptr);
}

test "message encode decode input simple" {
    const allocator = std.testing.allocator;

    const msg = Message{ .input = .{
        .codepoint = 'a',
        .mods = .{},
        .text = null,
    } };
    const bytes = try msg.encode(allocator);
    defer allocator.free(bytes);

    const decoded = try Message.decode(bytes);
    try std.testing.expectEqual(@as(u21, 'a'), decoded.input.codepoint);
    try std.testing.expect(!decoded.input.mods.ctrl);
    try std.testing.expect(!decoded.input.mods.shift);
}

test "message encode decode input with modifiers" {
    const allocator = std.testing.allocator;

    const msg = Message{ .input = .{
        .codepoint = 's',
        .mods = .{ .ctrl = true },
        .text = null,
    } };
    const bytes = try msg.encode(allocator);
    defer allocator.free(bytes);

    const decoded = try Message.decode(bytes);
    try std.testing.expectEqual(@as(u21, 's'), decoded.input.codepoint);
    try std.testing.expect(decoded.input.mods.ctrl);
    try std.testing.expect(!decoded.input.mods.shift);
}

test "message encode decode input with text" {
    const allocator = std.testing.allocator;

    const msg = Message{ .input = .{
        .codepoint = 'x',
        .mods = .{},
        .text = "x",
    } };
    const bytes = try msg.encode(allocator);
    defer allocator.free(bytes);

    const decoded = try Message.decode(bytes);
    try std.testing.expectEqual(@as(u21, 'x'), decoded.input.codepoint);
    try std.testing.expect(decoded.input.text != null);
    try std.testing.expectEqualStrings("x", decoded.input.text.?);
}

test "message decode empty returns error" {
    const result = Message.decode(&[_]u8{});
    try std.testing.expectError(error.EmptyMessage, result);
}

test "message decode unknown tag returns error" {
    const result = Message.decode(&[_]u8{255});
    try std.testing.expectError(error.UnknownTag, result);
}

test "message decode invalid input too short" {
    const result = Message.decode(&[_]u8{ Message.TAG_INPUT, 0, 0 });
    try std.testing.expectError(error.InvalidMessage, result);
}

test "message decode invalid command too short" {
    const result = Message.decode(&[_]u8{Message.TAG_COMMAND});
    try std.testing.expectError(error.InvalidMessage, result);
}

test "plugin message encode decode custom" {
    const allocator = std.testing.allocator;

    const pm = PluginMessage{
        .plugin_id = "my-plugin",
        .message_type = .custom_message,
        .payload = .{ .custom = "hello world" },
    };
    const bytes = try pm.encode(allocator);
    defer allocator.free(bytes);

    const decoded = try PluginMessage.decode(bytes[1..]);
    try std.testing.expectEqualStrings("my-plugin", decoded.plugin_id);
    try std.testing.expectEqual(PluginMessage.PluginMessageType.custom_message, decoded.message_type);
    try std.testing.expectEqualStrings("hello world", decoded.payload.custom);
}

test "plugin message encode decode command register" {
    const allocator = std.testing.allocator;

    const pm = PluginMessage{
        .plugin_id = "test-plugin",
        .message_type = .register_command,
        .payload = .{ .command_register = .{
            .id = "my.command",
            .title = "My Command",
            .description = "Does something useful",
        } },
    };
    const bytes = try pm.encode(allocator);
    defer allocator.free(bytes);

    const decoded = try PluginMessage.decode(bytes[1..]);
    try std.testing.expectEqualStrings("test-plugin", decoded.plugin_id);
    try std.testing.expectEqual(PluginMessage.PluginMessageType.register_command, decoded.message_type);
    try std.testing.expectEqualStrings("my.command", decoded.payload.command_register.id);
    try std.testing.expectEqualStrings("My Command", decoded.payload.command_register.title);
    try std.testing.expectEqualStrings("Does something useful", decoded.payload.command_register.description);
}

test "plugin message encode decode get_state" {
    const allocator = std.testing.allocator;

    const pm = PluginMessage{
        .plugin_id = "state-reader",
        .message_type = .get_state,
        .payload = .{ .state_request = {} },
    };
    const bytes = try pm.encode(allocator);
    defer allocator.free(bytes);

    const decoded = try PluginMessage.decode(bytes[1..]);
    try std.testing.expectEqualStrings("state-reader", decoded.plugin_id);
    try std.testing.expectEqual(PluginMessage.PluginMessageType.get_state, decoded.message_type);
}

test "plugin message round-trips correlation_id" {
    const allocator = std.testing.allocator;

    const pm = PluginMessage{
        .plugin_id = "p1",
        .message_type = .get_state,
        .payload = .{ .state_request = {} },
        .correlation_id = 0xDEADBEEF_CAFEBABE,
    };
    const bytes = try pm.encode(allocator);
    defer allocator.free(bytes);

    const decoded = try PluginMessage.decode(bytes[1..]);
    try std.testing.expectEqual(@as(u64, 0xDEADBEEF_CAFEBABE), decoded.correlation_id);
}

test "plugin message default correlation_id is 0" {
    const allocator = std.testing.allocator;

    const pm = PluginMessage{
        .plugin_id = "p1",
        .message_type = .get_state,
        .payload = .{ .state_request = {} },
    };
    const bytes = try pm.encode(allocator);
    defer allocator.free(bytes);

    const decoded = try PluginMessage.decode(bytes[1..]);
    try std.testing.expectEqual(@as(u64, 0), decoded.correlation_id);
}

test "plugin message encode decode event subscribe" {
    const allocator = std.testing.allocator;

    const pm = PluginMessage{
        .plugin_id = "event-handler",
        .message_type = .subscribe_event,
        .payload = .{ .event_subscribe = .buffer_changed },
    };
    const bytes = try pm.encode(allocator);
    defer allocator.free(bytes);

    const decoded = try PluginMessage.decode(bytes[1..]);
    try std.testing.expectEqual(PluginEvent.buffer_changed, decoded.payload.event_subscribe);
}

test "plugin message encode decode notification" {
    const allocator = std.testing.allocator;

    const pm = PluginMessage{
        .plugin_id = "notifier",
        .message_type = .show_notification,
        .payload = .{ .notification = .{
            .level = .warning,
            .message = "Something is wrong!",
        } },
    };
    const bytes = try pm.encode(allocator);
    defer allocator.free(bytes);

    const decoded = try PluginMessage.decode(bytes[1..]);
    try std.testing.expectEqual(NotificationLevel.warning, decoded.payload.notification.level);
    try std.testing.expectEqualStrings("Something is wrong!", decoded.payload.notification.message);
}

test "plugin message encode decode buffer open" {
    const allocator = std.testing.allocator;

    const pm = PluginMessage{
        .plugin_id = "buffer-manager",
        .message_type = .open_buffer,
        .payload = .{ .buffer_open = .{
            .name = "Preview",
            .content = "# Hello World\n\nThis is content.",
        } },
    };
    const bytes = try pm.encode(allocator);
    defer allocator.free(bytes);

    const decoded = try PluginMessage.decode(bytes[1..]);
    try std.testing.expectEqualStrings("Preview", decoded.payload.buffer_open.name);
    try std.testing.expectEqualStrings("# Hello World\n\nThis is content.", decoded.payload.buffer_open.content);
}

test "plugin message encode decode config set" {
    const allocator = std.testing.allocator;

    const pm = PluginMessage{
        .plugin_id = "config-plugin",
        .message_type = .set_config,
        .payload = .{ .config_set = .{
            .key = "theme.name",
            .value = "dark",
        } },
    };
    const bytes = try pm.encode(allocator);
    defer allocator.free(bytes);

    const decoded = try PluginMessage.decode(bytes[1..]);
    try std.testing.expectEqualStrings("theme.name", decoded.payload.config_set.key);
    try std.testing.expectEqualStrings("dark", decoded.payload.config_set.value);
}

test "plugin message encode decode buffer switch" {
    const allocator = std.testing.allocator;

    const pm = PluginMessage{
        .plugin_id = "switcher",
        .message_type = .switch_buffer,
        .payload = .{ .buffer_switch = 42 },
    };
    const bytes = try pm.encode(allocator);
    defer allocator.free(bytes);

    const decoded = try PluginMessage.decode(bytes[1..]);
    try std.testing.expectEqual(@as(u32, 42), decoded.payload.buffer_switch);
}

test "dir entry struct" {
    const entry = DirEntry{
        .name = "src",
        .is_dir = true,
    };
    try std.testing.expect(entry.is_dir);
    try std.testing.expectEqualStrings("src", entry.name);
}

test "buffer info struct" {
    const info = BufferInfo{
        .id = 1,
        .name = "main.zig",
        .modified = true,
        .is_active = false,
    };
    try std.testing.expectEqual(@as(u32, 1), info.id);
    try std.testing.expect(info.modified);
    try std.testing.expect(!info.is_active);
}

test "completion entry struct" {
    const entry = CompletionEntry{
        .label = "println",
        .kind = "function",
        .detail = "fn(...) void",
    };
    try std.testing.expectEqualStrings("println", entry.label);
    try std.testing.expectEqualStrings("function", entry.kind);
}

test "pane snapshot struct" {
    const pane = PaneSnapshot{
        .id = 1,
        .buffer_index = 0,
        .is_focused = true,
        .x = 0.0,
        .y = 0.0,
        .width = 0.5,
        .height = 1.0,
        .cursor_row = 10,
        .cursor_col = 5,
        .scroll_offset = 0,
        .selection_anchor_row = null,
        .selection_anchor_col = null,
        .visible_lines = &.{},
        .syntax_tokens = null,
        .total_lines = 100,
    };
    try std.testing.expect(pane.is_focused);
    try std.testing.expectEqual(@as(f32, 0.5), pane.width);
}

test "syntax token struct" {
    const token = SyntaxToken{
        .line = 10,
        .start_col = 4,
        .length = 8,
        .token_type = .function,
    };
    try std.testing.expectEqual(@as(u32, 10), token.line);
    try std.testing.expectEqual(SyntaxToken.TokenType.function, token.token_type);
}

test "symbol entry struct" {
    const sym = SymbolEntry{
        .name = "main",
        .kind = "function",
        .line = 15,
    };
    try std.testing.expectEqualStrings("main", sym.name);
    try std.testing.expectEqual(@as(usize, 15), sym.line);
}

test "editor state view struct" {
    const view = EditorStateView{
        .file_path = "/home/user/test.zig",
        .file_modified = false,
        .cursor_row = 0,
        .cursor_col = 0,
        .mode = .select,
        .buffer_id = 1,
        .buffer_name = "test.zig",
        .total_lines = 100,
        .selection_start_row = null,
        .selection_start_col = null,
        .selection_end_row = null,
        .selection_end_col = null,
    };
    try std.testing.expect(!view.file_modified);
    try std.testing.expectEqual(Mode.select, view.mode);
}

test "render snapshot clone" {
    const allocator = std.testing.allocator;

    var lines = [_][]const u8{ "line1", "line2", "line3" };
    const buffers = [_]BufferInfo{.{
        .id = 1,
        .name = "test.zig",
        .modified = false,
        .is_active = true,
    }};

    const original = RenderSnapshot{
        .visible_lines = &lines,
        .first_visible_line = 0,
        .total_lines = 3,
        .cursor_row = 0,
        .cursor_col = 0,
        .scroll_offset = 0,
        .version = 1,
        .mode = .select,
        .terminal_output = "output",
        .terminal_input = "input",
        .file_path = "/test/path.zig",
        .file_modified = false,
        .buffers = &buffers,
        .active_buffer_index = 0,
        .buffer_picker_selected = 0,
        .file_picker_cwd = null,
        .file_picker_entries = null,
        .file_picker_selected = 0,
        .buffer_picker_scroll_offset = 0,
        .save_as_input = null,
        .search_input = null,
    };

    const cloned = try original.clone(allocator);

    try std.testing.expectEqual(@as(usize, 3), cloned.visible_lines.len);
    try std.testing.expectEqualStrings("line1", cloned.visible_lines[0]);
    try std.testing.expectEqualStrings("line2", cloned.visible_lines[1]);
    try std.testing.expectEqualStrings("line3", cloned.visible_lines[2]);
    try std.testing.expectEqualStrings("output", cloned.terminal_output.?);
    try std.testing.expectEqualStrings("input", cloned.terminal_input.?);
    try std.testing.expectEqualStrings("/test/path.zig", cloned.file_path.?);
    try std.testing.expectEqual(@as(usize, 1), cloned.buffers.len);
    try std.testing.expectEqualStrings("test.zig", cloned.buffers[0].name);

    for (cloned.visible_lines) |line| {
        allocator.free(line);
    }
    allocator.free(cloned.visible_lines);
    allocator.free(cloned.terminal_output.?);
    allocator.free(cloned.terminal_input.?);
    allocator.free(cloned.file_path.?);
    allocator.free(cloned.buffers[0].name);
    allocator.free(cloned.buffers);
}

test "message all command types encode decode" {
    const allocator = std.testing.allocator;

    const commands = [_]Command{ .save, .open, .close, .next_buffer, .prev_buffer, .quit };

    for (commands) |cmd| {
        const msg = Message{ .command = cmd };
        const bytes = try msg.encode(allocator);
        defer allocator.free(bytes);

        const decoded = try Message.decode(bytes);
        try std.testing.expectEqual(cmd, decoded.command);
    }
}

test "message all modes encode decode" {
    const allocator = std.testing.allocator;

    const modes = [_]Mode{
        .select,       .insert,          .visual,      .visual_search,
        .view,         .terminal,        .file_picker, .buffer_picker,
        .save_as_mode, .command_palette, .go_to_line,  .symbol_picker,
        .workspace_symbol_picker,
    };

    for (modes) |mode| {
        const msg = Message{ .mode_change = mode };
        const bytes = try msg.encode(allocator);
        defer allocator.free(bytes);

        const decoded = try Message.decode(bytes);
        try std.testing.expectEqual(mode, decoded.mode_change);
    }
}
