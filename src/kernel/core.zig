const std = @import("std");
const logger_service = @import("../services/logger.zig");
const log = logger_service.scoped("Core");
const vaxis = @import("vaxis");
const vigil = @import("vigil");
const EditorState = @import("../core/state.zig").EditorState;
const FileManager = @import("../core/file_manager.zig").FileManager;
const auto_pair = @import("../core/auto_pair.zig");
const Keys = @import("../config/keys.zig").Keys;
const BufferManager = @import("buffer_manager.zig").BufferManager;
const JumpList = @import("jump_list.zig").JumpList;
const protocol = @import("protocol.zig");
const LSPManager = @import("../services/lsp_manager.zig").LSPManager;
const filetype = @import("filetype.zig");
const SyntaxManager = @import("../syntax/manager.zig").SyntaxManager;
const Help = @import("../ui/help.zig");
const TerminalService = @import("../services/terminal.zig").TerminalService;
const StorageManager = @import("../config/storage.zig").StorageManager;
const CommandRegistry = @import("command.zig").CommandRegistry;
const Command = @import("command.zig").Command;
const SplitManager = @import("split_manager.zig").SplitManager;
const SplitNode = @import("split_manager.zig").SplitNode;
const HistoryManager = @import("history.zig").HistoryManager;
const DecorationManager = @import("decorations.zig").DecorationManager;
const DecorationKind = @import("decorations.zig").DecorationKind;
const Range = @import("decorations.zig").Range;
const JobManager = @import("jobs.zig").JobManager;
const WorkspaceManager = @import("workspace.zig").WorkspaceManager;
const build_jobs = @import("build_jobs.zig");
const PluginManager = @import("../plugins/manager.zig").PluginManager;
const session = @import("session.zig");
const global_search = @import("../services/global_search.zig");
const ArenaPool = @import("arena_pool.zig").ArenaPool;
const terminal_proc = @import("terminal_proc.zig");
const GitCommands = @import("commands/git_commands.zig").GitCommands;
const BuildCommands = @import("commands/build_commands.zig").BuildCommands;
const LspCommands = @import("commands/lsp_commands.zig").LspCommands;
const SplitCommands = @import("commands/split_commands.zig").SplitCommands;
const SystemCommands = @import("commands/system_commands.zig").SystemCommands;
const EditCommands = @import("commands/edit_commands.zig").EditCommands;
const NavCommands = @import("commands/nav_commands.zig").NavCommands;
const BufferCommands = @import("commands/buffer_commands.zig").BufferCommands;
const FileCommands = @import("commands/file_commands.zig").FileCommands;

pub const CompletionDisplayItem = struct {
    label: []const u8,
    kind_icon: []const u8,
    detail: ?[]const u8,
    kind_category: protocol.CompletionEntry.KindCategory = .other,
};

/// Comptime adapter that wraps a `fn(*Core) anyerror!void` (or any function
/// whose first parameter accepts a `*Core` via `anytype`) into the
/// `CommandRegistry` callback shape `fn(*anyopaque, ?*const anyopaque) anyerror!void`.
/// Used by `registerCommands` to register module-level command functions
/// directly, without ~50 trivial wrappers in core.zig.
fn Wrap(comptime f: anytype) type {
    return struct {
        fn run(ctx: *anyopaque, context: ?*const anyopaque) anyerror!void {
            _ = context;
            const self: *Core = @ptrCast(@alignCast(ctx));
            try f(self);
        }
    };
}

pub const Core = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Parent process environment block, captured once at startup in main.zig
    /// and threaded through to anything that needs $HOME / $PATH / etc. so we
    /// don't read std.c.environ directly (which is racy under threading and
    /// unavailable on some Windows targets).
    environ_block: std.process.Environ.Block,
    /// Pool of arenas used for building render snapshots. The Core acquires
    /// one per `sendUpdate`; the UI returns it via `release` when the next
    /// snapshot arrives. Avoids per-frame mmap churn.
    arena_pool: ArenaPool,
    storage: *StorageManager,
    buffer_manager: BufferManager,
    /// Bus used by Core to send to the UI thread (renders, quit, etc.).
    /// Replaces a raw `*vigil.Inbox`; gives us priority routing,
    /// render-coalescing, and stats.
    ui_bus: *@import("message_bus.zig").MessageBus,
    core_inbox: ?*vigil.Inbox = null,
    /// Bus for sending TO Core's own inbox (used by terminal workers,
    /// plugin manager forwards, etc.). Set in `run()`.
    core_bus: ?*@import("message_bus.zig").MessageBus = null,
    version: u64 = 0,
    mode: protocol.Mode = .select,
    previous_mode: protocol.Mode = .select,
    file_manager: FileManager,
    terminal_input: std.ArrayListUnmanaged(u8),
    terminal_service: TerminalService,
    terminal_output: std.ArrayListUnmanaged(u8) = .empty,
    terminal_scroll_offset: usize = 0,
    terminal_running: bool = false,
    terminal_saved_input: std.ArrayListUnmanaged(u8) = .empty,
    terminal_cwd: ?[]const u8 = null,
    terminal_old_cwd: ?[]const u8 = null,
    leader_pending: bool,
    /// One of `[` or `]` pressed, awaiting target key (e.g. `d` for
    /// diagnostic). null = no bracket-prefix pending.
    bracket_pending: ?u8 = null,
    win_size: vaxis.Winsize = .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 },
    save_as_input: std.ArrayListUnmanaged(u8) = .empty,
    search_input: std.ArrayListUnmanaged(u8) = .empty,
    last_search_query: std.ArrayListUnmanaged(u8) = .empty,
    lsp_manager: LSPManager,
    lsp_doc_version: i64 = 1,
    syntax_manager: SyntaxManager,
    command_registry: *CommandRegistry,
    command_palette_input: std.ArrayListUnmanaged(u8) = .empty,
    command_palette_results: std.ArrayListUnmanaged(Command) = .empty,
    command_palette_selected: usize = 0,
    last_cursor_move_time: i64 = 0,
    hover_content: ?[]u8 = null,
    hover_pending: bool = false,
    definition_pending: bool = false,
    needs_render: bool = true,
    last_render_time: i64 = 0,
    min_render_interval_ms: i64 = 3,
    lsp_dirty: bool = false,
    lsp_debounce_deadline: i64 = 0,
    lsp_debounce_ms: i64 = 100,
    references_pending: bool = false,
    references_symbol_name: ?[]u8 = null,
    references_source_file: ?[]u8 = null,
    references_source_line: usize = 0,
    completion_pending: bool = false,
    completion_active: bool = false,
    completion_items: std.ArrayListUnmanaged(CompletionDisplayItem) = .empty,
    filtered_completion_items: std.ArrayListUnmanaged(CompletionDisplayItem) = .empty,
    completion_selected: usize = 0,
    completion_prefix_start: usize = 0,
    go_to_line_input: std.ArrayListUnmanaged(u8) = .empty,
    symbol_picker_query: std.ArrayListUnmanaged(u8) = .empty,
    symbol_picker_results: std.ArrayListUnmanaged(protocol.SymbolEntry) = .empty,
    symbol_picker_all_symbols: std.ArrayListUnmanaged(protocol.SymbolEntry) = .empty,
    symbol_picker_selected: usize = 0,
    global_search_query: std.ArrayListUnmanaged(u8) = .empty,
    global_search_replace: std.ArrayListUnmanaged(u8) = .empty,
    global_search_results: std.ArrayListUnmanaged(protocol.GlobalSearchFileGroup) = .empty,
    global_search_selected_file: usize = 0,
    global_search_selected_match: usize = 0,
    global_search_focus_replace: bool = false,
    global_search_options: protocol.GlobalSearchOptions = .{},
    /// True once at least one search has actually run, so the UI can show
    /// "No matches" instead of the initial "Type to search…" placeholder.
    global_search_ran: bool = false,
    split_manager: ?SplitManager = null,
    leader_number_input: std.ArrayListUnmanaged(u8) = .empty,
    buffer_picker_number_input: std.ArrayListUnmanaged(u8) = .empty,
    history_manager: HistoryManager,
    jump_list: JumpList,
    decoration_manager: DecorationManager,
    job_manager: JobManager,
    workspace_manager: WorkspaceManager,
    current_build_job: ?u64 = null,
    build_status: enum { idle, building, success, failed } = .idle,
    diff_highlights: std.ArrayListUnmanaged(protocol.DiffLineHighlight) = .empty,

    /// Cached git branch for the status bar. Refreshed lazily — the snapshot
    /// builder calls `refreshGitBranch()` if the cache is stale.
    git_branch: ?[]u8 = null,
    git_branch_refreshed_ms: i64 = 0,
    plugin_manager: PluginManager,
    mouse_pressed: bool = false,
    mouse_press_row: usize = 0,
    mouse_press_col: usize = 0,
    initial_files: []const []const u8 = &.{},
    clipboard: std.ArrayListUnmanaged(u8) = .empty,
    last_cursor_row: usize = 0,
    last_cursor_col: usize = 0,
    nav_repeat_count: usize = 0,
    last_buffer_switch_time: i64 = 0,
    buffer_switch_debounce_ms: i64 = 100,
    pending_lsp_refresh_path: ?[]const u8 = null,
    last_scroll_time: i64 = 0,
    scroll_throttle_ms: i64 = 16,
    cached_focused_pane_height: ?usize = null,
    scroll_in_progress: bool = false,
    scroll_timeout_ms: i64 = 200,
    status_message: ?[]const u8 = null,
    status_message_expires: i64 = 0,
    /// Scratch buffer for `status_message` slices that need to outlive the
    /// stack frame that built them (e.g. "Skipped N unsupported files"
    /// after a directory open). Fixed-size; messages truncate if longer.
    skip_status_buf: [128]u8 = undefined,

    /// Wall-clock ms of last autosave sweep. Set by `maybeAutosave`.
    last_autosave_ms: i64 = 0,
    /// How often to write recovery copies of dirty buffers. 30 s is a
    /// reasonable compromise — frequent enough that you won't lose much
    /// work, rare enough that the writes don't show up in profiles.
    autosave_interval_ms: i64 = 30_000,

    /// Wall-clock ms of last external-change check. Set by `maybeCheckExternalChange`.
    last_extwatch_ms: i64 = 0,
    /// How often to stat the active buffer's file for external changes.
    /// 2 s is responsive without spamming the filesystem.
    extwatch_interval_ms: i64 = 2_000,

    /// Pending file paths discovered by background directory-scan workers.
    /// Drained on every tick by the core thread, which calls
    /// `BufferManager.addFileLazyBackground` for each. The mutex protects
    /// both the queue and `scan_skipped_count`.
    scan_paths: std.ArrayListUnmanaged([]u8) = .empty,
    scan_paths_mutex: std.Io.Mutex = .init,
    scan_skipped_count: usize = 0,
    /// Set when shutting down so workers can bail out of their recursion
    /// quickly instead of finishing a multi-thousand-file walk.
    scan_shutdown: std.atomic.Value(bool) = .{ .raw = false },
    /// Counts active scan workers; bumped on spawn, decremented on exit.
    /// `deinit` waits briefly for this to reach zero.
    scan_workers_running: std.atomic.Value(u32) = .{ .raw = 0 },

    pub fn init(allocator: std.mem.Allocator, io: std.Io, environ_block: std.process.Environ.Block, ui_bus: *@import("message_bus.zig").MessageBus, storage: *StorageManager, initial_files: []const []const u8) !Core {
        var initial_terminal_output = std.ArrayListUnmanaged(u8).empty;
        try initial_terminal_output.appendSlice(allocator, "Terminal Ready\n");
        errdefer initial_terminal_output.deinit(allocator);
        var syntax_mgr = try SyntaxManager.init(allocator);
        errdefer syntax_mgr.deinit();

        const cmd_reg = try allocator.create(CommandRegistry);
        errdefer allocator.destroy(cmd_reg);
        cmd_reg.* = CommandRegistry.init(allocator);

        var core = Core{
            .allocator = allocator,
            .io = io,
            .environ_block = environ_block,
            .arena_pool = ArenaPool.init(allocator, io),
            .storage = storage,
            .buffer_manager = BufferManager.init(allocator, io),
            .ui_bus = ui_bus,
            .file_manager = try FileManager.init(allocator, io),
            .terminal_input = .empty,
            .terminal_output = initial_terminal_output,
            .version = 0,
            .leader_pending = false,
            .lsp_manager = LSPManager.init(allocator, io, environ_block),
            .syntax_manager = syntax_mgr,
            .last_cursor_move_time = std.Io.Clock.real.now(io).toMilliseconds(),
            .terminal_service = blk: {
                var ts = TerminalService.init(allocator, io);
                ts.setEnvironBlock(environ_block);
                break :blk ts;
            },
            .command_registry = cmd_reg,
            .command_palette_results = .empty,
            .history_manager = HistoryManager.init(allocator, io),
            .jump_list = JumpList.init(allocator, io, 100),
            .decoration_manager = DecorationManager.init(allocator),
            .job_manager = JobManager.init(allocator, io),
            .workspace_manager = WorkspaceManager.init(allocator, io),
            .plugin_manager = undefined,
            .initial_files = initial_files,
        };

        core.plugin_manager = PluginManager.init(allocator, io, environ_block, ui_bus, core.command_registry);
        return core;
    }

    pub fn deinit(self: *Core) void {
        // Tell scan workers to bail and wait briefly for them to exit. They
        // hold references to `self.allocator` and `scan_paths`, so we can't
        // free the queue until they're done.
        self.waitForScanWorkers();
        self.scan_paths_mutex.lockUncancelable(self.io);
        for (self.scan_paths.items) |p| self.allocator.free(p);
        self.scan_paths.deinit(self.allocator);
        self.scan_paths_mutex.unlock(self.io);

        self.arena_pool.deinit();
        self.buffer_manager.deinit();
        self.file_manager.deinit();
        self.terminal_input.deinit(self.allocator);
        self.terminal_output.deinit(self.allocator);
        self.terminal_saved_input.deinit(self.allocator);
        if (self.terminal_cwd) |cwd| self.allocator.free(cwd);
        if (self.terminal_old_cwd) |cwd| self.allocator.free(cwd);
        if (self.git_branch) |b| self.allocator.free(b);
        self.terminal_service.deinit();
        self.save_as_input.deinit(self.allocator);
        self.search_input.deinit(self.allocator);
        self.last_search_query.deinit(self.allocator);
        self.lsp_manager.deinit();
        if (self.references_symbol_name) |name| self.allocator.free(name);
        if (self.references_source_file) |path| self.allocator.free(path);
        self.syntax_manager.deinit();

        self.plugin_manager.deinit();

        self.command_registry.deinit();
        self.allocator.destroy(self.command_registry);
        self.command_palette_input.deinit(self.allocator);
        self.command_palette_results.deinit(self.allocator);
        self.go_to_line_input.deinit(self.allocator);
        self.symbol_picker_query.deinit(self.allocator);
        for (self.symbol_picker_results.items) |entry| {
            self.allocator.free(entry.name);
        }
        self.symbol_picker_results.deinit(self.allocator);
        for (self.symbol_picker_all_symbols.items) |entry| {
            self.allocator.free(entry.name);
        }
        self.symbol_picker_all_symbols.deinit(self.allocator);

        self.dismissCompletion();
        self.completion_items.deinit(self.allocator);
        self.filtered_completion_items.deinit(self.allocator);

        if (self.split_manager) |*sm| {
            sm.deinit();
        }

        self.leader_number_input.deinit(self.allocator);
        self.buffer_picker_number_input.deinit(self.allocator);

        self.history_manager.deinit();
        self.jump_list.deinit();
        self.decoration_manager.deinit();
        self.job_manager.deinit();
        self.workspace_manager.deinit();
        self.clipboard.deinit(self.allocator);

        if (self.pending_lsp_refresh_path) |path| {
            self.allocator.free(path);
        }
    }

    pub fn state(self: *Core) *EditorState {
        if (self.split_manager) |*sm| {
            const pane = sm.getFocusedPane();
            if (pane.buffer_index < self.buffer_manager.buffers.items.len) {
                return &self.buffer_manager.buffers.items[pane.buffer_index].state;
            }
        }
        return &self.buffer_manager.getActive().state;
    }

    pub fn ensureSplitManager(self: *Core) !void {
        if (self.split_manager == null) {
            self.split_manager = try SplitManager.init(self.allocator, self.buffer_manager.active_index);
            if (self.split_manager) |*sm| {
                const pane = sm.getFocusedPane();
                if (pane.buffer_index < self.buffer_manager.buffers.items.len) {
                    const s = &self.buffer_manager.buffers.items[pane.buffer_index].state;
                    pane.cursor_row = s.cursor_row;
                    pane.cursor_col = s.cursor_col;
                    pane.scroll_offset = s.scroll_offset;
                    if (s.selection_anchor) |a| {
                        pane.selection_anchor_row = a.row;
                        pane.selection_anchor_col = a.col;
                    }
                }
            }
        }
    }

    pub fn openVirtualBuffer(self: *Core, name: []const u8, content: []const u8) !void {
        try self.buffer_manager.openVirtual(name, content);
        if (self.split_manager) |*sm| {
            sm.setFocusedBuffer(self.buffer_manager.active_index);
        }
    }

    pub fn syncPaneToState(self: *Core) void {
        if (self.split_manager) |*sm| {
            const pane = sm.getFocusedPane();
            if (pane.buffer_index >= self.buffer_manager.buffers.items.len) return;
            const s = &self.buffer_manager.buffers.items[pane.buffer_index].state;
            s.cursor_row = pane.cursor_row;
            s.cursor_col = pane.cursor_col;
            s.scroll_offset = pane.scroll_offset;
            if (pane.selection_anchor_row) |r| {
                if (pane.selection_anchor_col) |c| {
                    s.selection_anchor = .{ .row = r, .col = c };
                }
            } else {
                s.selection_anchor = null;
            }
        }
    }

    pub fn syncStateToPane(self: *Core) void {
        if (self.split_manager) |*sm| {
            const pane = sm.getFocusedPane();
            if (pane.buffer_index >= self.buffer_manager.buffers.items.len) return;
            const s = &self.buffer_manager.buffers.items[pane.buffer_index].state;
            pane.cursor_row = s.cursor_row;
            pane.cursor_col = s.cursor_col;
            pane.scroll_offset = s.scroll_offset;
            if (s.selection_anchor) |a| {
                pane.selection_anchor_row = a.row;
                pane.selection_anchor_col = a.col;
            } else {
                pane.selection_anchor_row = null;
                pane.selection_anchor_col = null;
            }
        }
    }

    pub fn getFocusedPaneHeight(self: *Core) usize {
        if (self.split_manager == null) {
            return if (self.win_size.rows > 2) self.win_size.rows - 2 else 1;
        }

        if (self.cached_focused_pane_height) |h| {
            return h;
        }

        const sm = &self.split_manager.?;
        const content_rows = if (self.win_size.rows > 1) self.win_size.rows - 1 else 1;
        const params = protocol.RenderParams{ .rows = content_rows, .cols = self.win_size.cols };
        var bounds = sm.getAllPaneBounds(self.allocator, params) catch null;
        if (bounds) |*b| {
            defer b.deinit(self.allocator);
            for (b.items) |pane_bound| {
                if (pane_bound.pane.id == sm.focused_pane_id) {
                    const height = if (pane_bound.height > 2) pane_bound.height - 1 else 1;
                    self.cached_focused_pane_height = height;
                    return height;
                }
            }
        }

        const fallback = if (self.win_size.rows > 2) self.win_size.rows - 2 else 1;
        self.cached_focused_pane_height = fallback;
        return fallback;
    }

    pub fn invalidatePaneHeightCache(self: *Core) void {
        self.cached_focused_pane_height = null;
    }

    fn insertCharWithHistory(self: *Core, char: u8) !void {
        const s = self.state();
        const offset = s.getOffsetFromCursor();
        self.history_manager.beginTransaction(.{ .row = s.cursor_row, .col = s.cursor_col });
        try s.insertChar(char);
        var char_buf: [1]u8 = .{char};
        try self.history_manager.recordInsert(offset, &char_buf);
        self.history_manager.commitTransaction(.{ .row = s.cursor_row, .col = s.cursor_col });
    }

    pub fn insertTextWithHistory(self: *Core, text: []const u8) !void {
        const s = self.state();
        const offset = s.getOffsetFromCursor();
        self.history_manager.beginTransaction(.{ .row = s.cursor_row, .col = s.cursor_col });
        try s.insertTextAtCursor(text);
        try self.history_manager.recordInsert(offset, text);
        self.history_manager.commitTransaction(.{ .row = s.cursor_row, .col = s.cursor_col });
    }

    fn deleteCharWithHistory(self: *Core) !void {
        const s = self.state();
        const offset = s.getOffsetFromCursor();
        if (offset >= s.buffer.totalLength()) return;
        const deleted_char = s.buffer.getCharAt(offset) orelse return;
        var char_buf: [1]u8 = .{deleted_char};
        self.history_manager.beginTransaction(.{ .row = s.cursor_row, .col = s.cursor_col });
        try self.history_manager.recordDelete(offset, &char_buf);
        try s.deleteChar();
        self.history_manager.commitTransaction(.{ .row = s.cursor_row, .col = s.cursor_col });
    }

    fn backspaceCharWithHistory(self: *Core) !void {
        const s = self.state();
        const offset = s.getOffsetFromCursor();
        if (offset == 0) return;
        const deleted_char = s.buffer.getCharAt(offset - 1) orelse return;
        var char_buf: [1]u8 = .{deleted_char};
        self.history_manager.beginTransaction(.{ .row = s.cursor_row, .col = s.cursor_col });
        try self.history_manager.recordDelete(offset - 1, &char_buf);
        try s.backspaceChar();
        self.history_manager.commitTransaction(.{ .row = s.cursor_row, .col = s.cursor_col });
    }

    pub fn deleteRangeWithHistory(self: *Core, start_offset: usize, end_offset: usize) !void {
        if (end_offset <= start_offset) return;
        const s = self.state();
        const len = end_offset - start_offset;
        var deleted_text = try self.allocator.alloc(u8, len);
        defer self.allocator.free(deleted_text);

        var idx: usize = 0;
        var offset: usize = 0;
        for (s.buffer.pieces.items) |p| {
            const data = switch (p.source) {
                .Original => s.buffer.original[p.start .. p.start + p.length],
                .Add => s.buffer.add.items[p.start .. p.start + p.length],
            };
            for (data) |c| {
                if (offset >= start_offset and offset < end_offset) {
                    deleted_text[idx] = c;
                    idx += 1;
                }
                offset += 1;
                if (offset >= end_offset) break;
            }
            if (offset >= end_offset) break;
        }

        self.history_manager.beginTransaction(.{ .row = s.cursor_row, .col = s.cursor_col });
        try self.history_manager.recordDelete(start_offset, deleted_text);
        try s.deleteRange(start_offset, end_offset);
        self.history_manager.commitTransaction(.{ .row = s.cursor_row, .col = s.cursor_col });
    }

    pub fn getSelectionText(self: *Core) !?[]u8 {
        const s = self.state();
        const anchor = s.selection_anchor orelse return null;

        var start_row: usize = undefined;
        var start_col: usize = undefined;
        var end_row: usize = undefined;
        var end_col: usize = undefined;

        if (anchor.row < s.cursor_row or (anchor.row == s.cursor_row and anchor.col <= s.cursor_col)) {
            start_row = anchor.row;
            start_col = anchor.col;
            end_row = s.cursor_row;
            end_col = s.cursor_col;
        } else {
            start_row = s.cursor_row;
            start_col = s.cursor_col;
            end_row = anchor.row;
            end_col = anchor.col;
        }

        const start_off = s.getOffsetFor(start_row, start_col);
        const end_off = s.getOffsetFor(end_row, end_col);

        if (end_off <= start_off) return null;

        const len = end_off - start_off;
        var result = try self.allocator.alloc(u8, len);
        errdefer self.allocator.free(result);

        var idx: usize = 0;
        var offset: usize = 0;
        for (s.buffer.pieces.items) |p| {
            const data = switch (p.source) {
                .Original => s.buffer.original[p.start .. p.start + p.length],
                .Add => s.buffer.add.items[p.start .. p.start + p.length],
            };
            for (data) |c| {
                if (offset >= start_off and offset < end_off) {
                    result[idx] = c;
                    idx += 1;
                }
                offset += 1;
                if (offset >= end_off) break;
            }
            if (offset >= end_off) break;
        }

        return result;
    }

    fn cmdDocumentSymbols(ctx: *anyopaque, context: ?*const anyopaque) anyerror!void {
        _ = context;
        const self: *Core = @ptrCast(@alignCast(ctx));

        const s = self.state();
        const file_path = s.file_path orelse return;

        self.lsp_manager.requestDocumentSymbols(file_path) catch |err| {
            log.warn("LSP document symbols request failed for {s}: {}", .{ file_path, err });
        };

        var attempts: u32 = 0;
        while (attempts < 50) : (attempts += 1) {
            if (self.lsp_manager.popDocumentSymbolsResult()) |symbols| {
                defer self.lsp_manager.freeDocumentSymbols(symbols);

                for (self.symbol_picker_all_symbols.items) |entry| {
                    self.allocator.free(entry.name);
                }
                self.symbol_picker_all_symbols.clearRetainingCapacity();
                for (self.symbol_picker_results.items) |entry| {
                    self.allocator.free(entry.name);
                }
                self.symbol_picker_results.clearRetainingCapacity();

                for (symbols) |sym| {
                    const kind_str = switch (sym.kind) {
                        .file => "file",
                        .module => "module",
                        .namespace => "namespace",
                        .package => "package",
                        .class => "class",
                        .method => "method",
                        .property => "property",
                        .field => "field",
                        .constructor => "constructor",
                        .enumType => "enum",
                        .interface => "interface",
                        .function => "function",
                        .variable => "variable",
                        .constant => "constant",
                        .string => "string",
                        .number => "number",
                        .boolean => "boolean",
                        .array => "array",
                        .object => "object",
                        .key => "key",
                        .null_type => "null",
                        .enumMember => "enumMember",
                        .struct_type => "struct",
                        .event => "event",
                        .operator => "operator",
                        .type_parameter => "typeParameter",
                    };

                    const name_dupe = try self.allocator.dupe(u8, sym.name);
                    try self.symbol_picker_all_symbols.append(self.allocator, .{
                        .name = name_dupe,
                        .kind = kind_str,
                        .line = sym.line,
                    });
                }

                self.previous_mode = self.mode;
                self.mode = .symbol_picker;
                self.symbol_picker_query.clearRetainingCapacity();
                self.symbol_picker_selected = 0;
                try self.updateSymbolSearch();
                try self.sendUpdate();
                return;
            }
            // best-effort: sleep cancellation is fine, loop will check condition again
            std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(10), .real) catch {};
        }

        self.previous_mode = self.mode;
        self.mode = .symbol_picker;
        self.symbol_picker_query.clearRetainingCapacity();
        self.symbol_picker_selected = 0;
        try self.updateSymbolSearch();
        try self.sendUpdate();
    }

    fn cmdJumpBack(ctx: *anyopaque, context: ?*const anyopaque) anyerror!void {
        _ = context;
        const self: *Core = @ptrCast(@alignCast(ctx));

        if (self.jump_list.jumpBack()) |location| {
            const s = self.state();
            const current_file = s.file_path orelse "";

            if (!std.mem.eql(u8, current_file, location.file_path)) {
                _ = try self.buffer_manager.openFile(location.file_path);
                self.refreshSyntaxForCurrentBuffer();
            }

            const new_state = self.state();
            new_state.cursor_row = location.row;
            new_state.cursor_col = location.col;

            const visible_rows: usize = if (self.win_size.rows > 2) self.win_size.rows - 2 else 1;
            const half = visible_rows / 2;
            if (new_state.cursor_row >= half) {
                new_state.scroll_offset = new_state.cursor_row - half;
            } else {
                new_state.scroll_offset = 0;
            }

            try self.sendUpdate();
        }
    }

    fn cmdJumpForward(ctx: *anyopaque, context: ?*const anyopaque) anyerror!void {
        _ = context;
        const self: *Core = @ptrCast(@alignCast(ctx));

        if (self.jump_list.jumpForward()) |location| {
            const s = self.state();
            const current_file = s.file_path orelse "";

            if (!std.mem.eql(u8, current_file, location.file_path)) {
                _ = try self.buffer_manager.openFile(location.file_path);
                self.refreshSyntaxForCurrentBuffer();
            }

            const new_state = self.state();
            new_state.cursor_row = location.row;
            new_state.cursor_col = location.col;

            const visible_rows: usize = if (self.win_size.rows > 2) self.win_size.rows - 2 else 1;
            const half = visible_rows / 2;
            if (new_state.cursor_row >= half) {
                new_state.scroll_offset = new_state.cursor_row - half;
            } else {
                new_state.scroll_offset = 0;
            }

            try self.sendUpdate();
        }
    }

    pub fn registerCommands(self: *Core) !void {
        const R = self.command_registry;

        try R.register("file.save", "File: Save", "Save the current file", Wrap(FileCommands.cmdFileSave).run, null);
        try R.register("file.open", "File: Open", "Open a file", Wrap(FileCommands.cmdFileOpen).run, null);
        try R.register("file.new", "File: New", "Create new scratchpad", Wrap(FileCommands.cmdFileNew).run, null);
        try R.register("file.quit", "File: Quit", "Quit the editor", Wrap(FileCommands.cmdSystemQuit).run, null);
        try R.register("file.reload", "File: Reload from Disk", "Reload current file", Wrap(FileCommands.cmdFileReload).run, null);
        try R.register("file.save_as", "File: Save As", "Save file as...", Wrap(FileCommands.cmdFileSaveAs).run, null);

        try R.register("buffer.switch", "Buffer: Switch", "Open buffer picker (Space+b)", Wrap(BufferCommands.cmdBufferSwitch).run, null);
        try R.register("buffer.new", "Buffer: New", "Create a new untitled buffer", Wrap(BufferCommands.cmdBufferNew).run, null);
        try R.register("buffer.next", "Buffer: Next", "Switch to next buffer (Space+n)", Wrap(BufferCommands.cmdBufferNext).run, null);
        try R.register("buffer.prev", "Buffer: Previous", "Go to previous buffer", Wrap(BufferCommands.cmdBufferPrev).run, null);
        try R.register("buffer.close", "Buffer: Close", "Close the active buffer", Wrap(BufferCommands.cmdBufferClose).run, null);
        try R.register("buffer.close_others", "Buffer: Close Others", "Close all buffers except active", Wrap(BufferCommands.cmdBufferCloseOthers).run, null);
        try R.register("buffer.new_scratch", "Buffer: New Scratch", "Create a new scratch buffer (not saved to disk)", Wrap(BufferCommands.cmdBufferNewScratch).run, null);

        try R.register("edit.delete_line", "Edit: Delete Line", "Remove the current line", Wrap(EditCommands.cmdEditDeleteLine).run, null);
        try R.register("edit.duplicate_line", "Edit: Duplicate Line", "Copy current line and insert below", Wrap(EditCommands.cmdEditDuplicateLine).run, null);
        try R.register("edit.move_line_up", "Edit: Move Line Up", "Swap current line with above", Wrap(EditCommands.cmdEditMoveLineUp).run, null);
        try R.register("edit.move_line_down", "Edit: Move Line Down", "Swap current line with below", Wrap(EditCommands.cmdEditMoveLineDown).run, null);
        try R.register("edit.join_lines", "Edit: Join Lines", "Merge current line with next", Wrap(EditCommands.cmdEditJoinLines).run, null);
        try R.register("edit.insert_datetime", "Edit: Insert Date/Time", "Insert current timestamp", Wrap(EditCommands.cmdEditInsertDateTime).run, null);
        try R.register("edit.undo", "Edit: Undo", "Undo the last change (Space+u)", Wrap(EditCommands.cmdEditUndo).run, null);
        try R.register("edit.redo", "Edit: Redo", "Redo the last undone change (Space+r)", Wrap(EditCommands.cmdEditRedo).run, null);
        try R.register("edit.copy", "Edit: Copy", "Copy selected text (Space+c)", Wrap(EditCommands.cmdEditCopy).run, null);
        try R.register("edit.cut", "Edit: Cut", "Cut selected text (Space+x)", Wrap(EditCommands.cmdEditCut).run, null);
        try R.register("edit.paste", "Edit: Paste", "Paste clipboard contents (Space+v)", Wrap(EditCommands.cmdEditPaste).run, null);

        try R.register("nav.go_to_line", "Nav: Go to Line", "Jump to a specific line number", Wrap(NavCommands.cmdNavGoToLine).run, null);
        try R.register("nav.go_to_symbol", "Nav: Go to Symbol (File)", "Fuzzy find functions/structs in file", Wrap(NavCommands.cmdNavGoToSymbol).run, null);
        try R.register("nav.top_of_file", "Nav: Top of File", "Move cursor to start of buffer", Wrap(NavCommands.cmdNavTopOfFile).run, null);
        try R.register("nav.bottom_of_file", "Nav: Bottom of File", "Move cursor to end of buffer", Wrap(NavCommands.cmdNavBottomOfFile).run, null);
        try R.register("nav.center_view", "Nav: Center View", "Scroll so cursor is centered", Wrap(NavCommands.cmdNavCenterView).run, null);
        try R.register("nav.expand_selection", "Nav: Expand Selection", "Expand selection to syntax boundary (Ctrl+Shift+Up)", Wrap(NavCommands.cmdNavExpandSelection).run, null);
        try R.register("nav.match_bracket", "Nav: Match Bracket", "Jump to matching (), {}, [], or <> (%)", Wrap(NavCommands.cmdNavMatchBracket).run, null);
        try R.register("search.find_in_buffer", "Search: Find in Buffer", "Search within current file", Wrap(NavCommands.cmdSearchFindInBuffer).run, null);

        try R.register("lsp.format", "LSP: Format Document", "Format the entire file using zls", Wrap(LspCommands.cmdLspFormatDocument).run, null);
        try R.register("lsp.definition", "LSP: Go to Definition", "Jump to symbol definition", Wrap(LspCommands.cmdLspGoToDefinition).run, null);
        try R.register("lsp.diagnostics", "LSP: Show Diagnostics", "List all errors/warnings for current file", Wrap(LspCommands.cmdLspShowDiagnostics).run, null);
        try R.register("lsp.restart", "LSP: Restart Server", "Force restart the embedded zls instance", Wrap(LspCommands.cmdLspRestartServer).run, null);
        try R.register("lsp.hover", "LSP: Hover", "Trigger hover information for symbol under cursor", Wrap(LspCommands.cmdLspHover).run, null);
        try R.register("lsp.references", "LSP: Find References", "Find all references to symbol under cursor", Wrap(LspCommands.cmdLspFindReferences).run, null);

        try R.register("mode.insert", "Mode: Insert", "Switch to insert mode", Wrap(SystemCommands.cmdModeInsert).run, null);
        try R.register("mode.visual", "Mode: Visual", "Switch to visual mode", Wrap(SystemCommands.cmdModeVisual).run, null);
        try R.register("mode.terminal", "Mode: Terminal", "Switch to terminal mode", Wrap(SystemCommands.cmdModeTerminal).run, null);
        try R.register("mode.select", "Mode: Select", "Switch to select mode", Wrap(SystemCommands.cmdModeSelect).run, null);

        try R.register("help.show", "Help: Show", "Show editor help", Wrap(SystemCommands.cmdShowHelp).run, null);
        try R.register("plugin.show", "[Plugin Manager] List Plugins", "Show loaded plugins", Wrap(SystemCommands.cmdShowPlugins).run, null);
        try R.register("stats.show", "Stats: Message Bus", "Live view of stem's Vigil-backed message bus stats", Wrap(SystemCommands.cmdShowStats).run, null);
        try R.register("job.list", "Jobs: List Active", "Show all active background jobs (Space+j)", Wrap(SystemCommands.cmdJobList).run, null);
        try R.register("view.logs", "View: Logs", "Open log viewer", Wrap(SystemCommands.cmdViewLogs).run, null);
        try R.register("view.clear_logs", "View: Clear Logs", "Clear all logs", Wrap(SystemCommands.cmdClearLogs).run, null);

        try R.register("split.vertical", "Split: Vertical", "Split pane vertically (top/bottom)", Wrap(SplitCommands.cmdSplitVertical).run, null);
        try R.register("split.horizontal", "Split: Horizontal", "Split pane horizontally (left/right)", Wrap(SplitCommands.cmdSplitHorizontal).run, null);
        try R.register("pane.close", "Pane: Close", "Close current pane", Wrap(SplitCommands.cmdPaneClose).run, null);
        try R.register("pane.focus_left", "Pane: Focus Left", "Move focus to left pane", Wrap(SplitCommands.cmdPaneFocusLeft).run, null);
        try R.register("pane.focus_right", "Pane: Focus Right", "Move focus to right pane", Wrap(SplitCommands.cmdPaneFocusRight).run, null);
        try R.register("pane.focus_up", "Pane: Focus Up", "Move focus to upper pane", Wrap(SplitCommands.cmdPaneFocusUp).run, null);
        try R.register("pane.focus_down", "Pane: Focus Down", "Move focus to lower pane", Wrap(SplitCommands.cmdPaneFocusDown).run, null);
        try R.register("pane.swap_left", "Pane: Swap Left", "Swap content with left pane", Wrap(SplitCommands.cmdPaneSwapLeft).run, null);
        try R.register("pane.swap_right", "Pane: Swap Right", "Swap content with right pane", Wrap(SplitCommands.cmdPaneSwapRight).run, null);
        try R.register("pane.swap_up", "Pane: Swap Up", "Swap content with upper pane", Wrap(SplitCommands.cmdPaneSwapUp).run, null);
        try R.register("pane.swap_down", "Pane: Swap Down", "Swap content with lower pane", Wrap(SplitCommands.cmdPaneSwapDown).run, null);

        try R.register("build.test", "Zig: Test", "Run 'zig build test' for current workspace", Wrap(BuildCommands.cmdBuildTest).run, null);
        try R.register("build.build", "Zig: Build", "Run 'zig build' for current workspace", Wrap(BuildCommands.cmdBuildOnly).run, null);
        try R.register("build.output", "Zig: Show Build Output", "Show the last build output", Wrap(BuildCommands.cmdBuildOutput).run, null);
    }

    pub fn run(self: *Core, bus: *@import("message_bus.zig").MessageBus) !void {
        // Language servers are installed on-demand via `stem lsp install <name>`,
        // not eagerly at startup. ZLS is bundled and needs no install.
        const inbox = bus.inbox;
        self.core_inbox = inbox;
        self.core_bus = bus;
        self.plugin_manager.core_inbox = inbox;
        try self.registerCommands();

        self.plugin_manager.loadUserPlugins() catch |err| {
            std.log.err("Failed to load user plugins: {}", .{err});
        };

        if (self.initial_files.len > 0) {
            for (self.initial_files) |path| {
                var is_dir = false;
                if (std.Io.Dir.openDirAbsolute(self.io, path, .{})) |d| {
                    var dir = d;
                    dir.close(self.io);
                    is_dir = true;
                } else |_| {}

                if (is_dir) {
                    self.openAllFilesInDirectory(path) catch |err| {
                        std.log.err("Failed to open directory '{s}': {}", .{ path, err });
                    };
                } else {
                    const opened_buffer = self.buffer_manager.openFileLazy(path) catch |err| {
                        std.log.err("Failed to open initial file '{s}': {}", .{ path, err });
                        continue;
                    };
                    // best-effort: workspace tracking is auxiliary; buffer is still usable if this fails
                    self.workspace_manager.registerBuffer(opened_buffer.id, path) catch {};
                }
            }
            self.refreshSyntaxForCurrentBuffer();
        } else {
            self.restoreSession();
        }

        // Pre-spawn LSP servers for languages we already see in the buffer
        // list. This warms them up so the first hover/completion request is
        // instant instead of waiting on a cold init. Runs purely off-thread
        // via the supervisor; nothing blocks the UI here.
        self.prespawnLSPs() catch |err| {
            std.log.warn("LSP prespawn failed: {}", .{err});
        };

        // Eagerly send `didOpen` for the active buffer so the LSP is aware
        // of the document the user is about to edit. This queues through
        // the supervisor (FIFO), so it runs right after the matching
        // `start_server` from prespawn finishes — by the time the user
        // hovers/completes, the doc is already known to the server.
        self.eagerlyOpenActiveBuffer();

        try self.sendUpdate();
        while (true) {
            const msg = inbox.recv() catch |err| {
                if (err == error.InboxClosed) return;
                return err;
            };
            defer msg.deinit();

            if (msg.payload) |payload| {
                const decoded = protocol.Message.decode(payload) catch |err| {
                    log.warn("Failed to decode msg: {}", .{err});
                    continue;
                };

                switch (decoded) {
                    .focus => {},
                    .plugin_message => |pm| {
                        if (pm.message_type == .open_buffer) {
                            const buf = pm.payload.buffer_open;
                            self.buffer_manager.openVirtual(buf.name, buf.content) catch |err| {
                                std.log.err("Failed to open plugin buffer: {}", .{err});
                                continue;
                            };
                            if (self.split_manager) |*sm| {
                                sm.setFocusedBuffer(self.buffer_manager.active_index);
                            }
                            self.sendUpdate() catch |err| {
                                log.warn("Failed to send UI update after plugin buffer change: {}", .{err});
                            };
                        } else if (pm.message_type == .get_state) {
                            const active_buf = self.buffer_manager.getActive();
                            const state_view = protocol.EditorStateView{
                                .buffer_id = active_buf.id,
                                .buffer_name = active_buf.name,
                                .file_path = active_buf.file_path,
                                .cursor_row = active_buf.state.cursor_row,
                                .cursor_col = active_buf.state.cursor_col,
                                .mode = self.mode,
                                .file_modified = active_buf.state.modified,
                                .total_lines = active_buf.state.buffer.lineCount(),
                                .selection_start_row = null,
                                .selection_start_col = null,
                                .selection_end_row = null,
                                .selection_end_col = null,
                            };

                            const resp = protocol.PluginMessage{
                                .plugin_id = pm.plugin_id,
                                .message_type = .state_response,
                                .payload = .{ .state = state_view },
                                // Echo back so the SDK's RequestTracker
                                // can match this reply to the originating
                                // `requestEditorState` call.
                                .correlation_id = pm.correlation_id,
                            };

                            if (self.plugin_manager.plugins.get(pm.plugin_id)) |plugin| {
                                if (plugin.bus) |*plugin_bus| {
                                    const encoded = resp.encode(self.allocator) catch continue;
                                    defer self.allocator.free(encoded);
                                    // Request/reply → interactive priority.
                                    plugin_bus.sendInteractive(encoded) catch {};
                                }
                            }
                        } else if (pm.message_type == .get_buffer_content) {
                            const active_buf = self.buffer_manager.getActive();
                            const content = active_buf.state.buffer.toString(self.allocator) catch "";
                            defer self.allocator.free(content);

                            const resp = protocol.PluginMessage{
                                .plugin_id = pm.plugin_id,
                                .message_type = .buffer_content_response,
                                .payload = .{ .buffer_content_response = .{ .id = active_buf.id, .content = content } },
                                .correlation_id = pm.correlation_id,
                            };
                            if (self.plugin_manager.plugins.get(pm.plugin_id)) |plugin| {
                                if (plugin.bus) |*plugin_bus| {
                                    const encoded = resp.encode(self.allocator) catch continue;
                                    defer self.allocator.free(encoded);
                                    // Request/reply → interactive priority.
                                    plugin_bus.sendInteractive(encoded) catch {};
                                }
                            }
                        } else if (pm.message_type == .switch_buffer) {
                            const target_id = pm.payload.buffer_switch;
                            for (self.buffer_manager.buffers.items, 0..) |b, i| {
                                if (b.id == target_id) {
                                    self.buffer_manager.switchTo(i);
                                    self.refreshSyntaxForCurrentBuffer();
                                    if (self.split_manager) |*sm| {
                                        sm.setFocusedBuffer(self.buffer_manager.active_index);
                                    }
                                    self.sendUpdate() catch |err| {
                                        log.warn("Failed to send UI update after switch buffer: {}", .{err});
                                    };
                                    break;
                                }
                            }
                        } else if (pm.message_type == .execute_core_command) {
                            const cmd_id = pm.payload.command_execute;
                            self.syncPaneToState();
                            self.command_registry.execute(cmd_id, self) catch |err| {
                                log.err("Failed to execute core command '{s}' from plugin: {}", .{ cmd_id, err });
                            };
                        } else {
                            self.plugin_manager.handlePluginMessage(pm) catch |err| {
                                std.log.err("Error handling plugin message: {}", .{err});
                            };
                        }
                    },
                    .tick => {
                        // Drain any paths discovered by background directory
                        // scanners into the buffer list. Bounded per tick.
                        self.drainScanPaths();

                        // Restart crashed plugins under the per-plugin
                        // RestartPolicy. Bounded: at most one reload per
                        // tick so a flapping plugin can't monopolize core.
                        self.plugin_manager.tickRestarts();

                        // If the user is currently looking at the [STATS]
                        // dashboard, refresh its content so the counters
                        // tick up live.
                        SystemCommands.refreshStatsBufferIfOpen(self);

                        // Periodically write recovery copies of any modified
                        // buffers so an OS crash / power loss / segfault
                        // doesn't take unsaved work with it.
                        self.maybeAutosave();

                        // Periodically check whether the active buffer's
                        // file changed on disk under us — common when a
                        // formatter or git checkout rewrites the file.
                        self.maybeCheckExternalChange();

                        // If the async tree-sitter parse worker just
                        // finished a parse, the new tree is sitting in
                        // SyntaxManager but the screen still shows whatever
                        // we drew before parse completed. Request a render
                        // so highlighting actually appears.
                        if (self.syntax_manager.tree_updated.swap(false, .acquire)) {
                            self.requestRender();
                        }

                        if (self.hover_pending) {
                            if (self.lsp_manager.popHoverResult()) |content| {
                                self.hover_pending = false;
                                if (self.hover_content) |old| self.allocator.free(old);
                                self.hover_content = content;
                                self.requestRender();
                            }
                        }

                        if (self.definition_pending) {
                            if (self.lsp_manager.popDefinitionResult()) |location| {
                                self.definition_pending = false;
                                defer self.allocator.free(location.file_path);

                                const s = self.state();
                                const current_path = s.file_path orelse "";

                                if (current_path.len > 0) {
                                    self.jump_list.recordJump(current_path, s.cursor_row, s.cursor_col) catch |err| {
                                        log.debug("Failed to record jump location: {}", .{err});
                                    };
                                }

                                if (!std.mem.eql(u8, current_path, location.file_path)) {
                                    _ = self.buffer_manager.openFile(location.file_path) catch |err| {
                                        log.err("Failed to open definition file: {}", .{err});
                                        continue;
                                    };
                                    const new_state = self.state();
                                    if (new_state.file_path) |path| {
                                        const content = new_state.buffer.toString(self.allocator) catch continue;
                                        defer self.allocator.free(content);
                                        self.lsp_manager.documentOpened(path, content) catch |err| {
                                            log.warn("LSP document sync failed for '{s}': {}", .{ path, err });
                                        };
                                    }
                                }

                                const target_state = self.state();
                                target_state.cursor_row = location.line;
                                target_state.cursor_col = location.col;

                                const visible_rows: usize = if (self.win_size.rows > 2) self.win_size.rows - 2 else 1;
                                const half = visible_rows / 2;
                                if (target_state.cursor_row >= half) {
                                    target_state.scroll_offset = target_state.cursor_row - half;
                                } else {
                                    target_state.scroll_offset = 0;
                                }
                                self.requestRender();
                            }
                        }

                        if (self.references_pending) {
                            if (self.lsp_manager.popReferencesResult()) |refs| {
                                self.references_pending = false;
                                defer self.lsp_manager.freeReferences(refs);

                                if (refs.len > 0) {
                                    var text = std.ArrayListUnmanaged(u8).empty;
                                    defer text.deinit(self.allocator);

                                    try text.appendSlice(self.allocator,
                                        \\+------------------------------------------------------------------+
                                        \\|  SYMBOL REFERENCES                                               |
                                        \\+------------------------------------------------------------------+
                                        \\
                                        \\
                                    );

                                    if (self.references_symbol_name) |sym_name| {
                                        const sym_line = try std.fmt.allocPrint(self.allocator, "Symbol: {s}\n", .{sym_name});
                                        defer self.allocator.free(sym_line);
                                        try text.appendSlice(self.allocator, sym_line);
                                    }
                                    if (self.references_source_file) |src| {
                                        const src_line = try std.fmt.allocPrint(self.allocator, "  -> Defined at: {s}:{d}\n\n", .{
                                            std.fs.path.basename(src),
                                            self.references_source_line + 1,
                                        });
                                        defer self.allocator.free(src_line);
                                        try text.appendSlice(self.allocator, src_line);
                                    }

                                    var file_count: usize = 0;
                                    var last_file: ?[]const u8 = null;
                                    for (refs) |r| {
                                        if (last_file == null or !std.mem.eql(u8, last_file.?, r.file_path)) {
                                            file_count += 1;
                                            last_file = r.file_path;
                                        }
                                    }

                                    const summary = try std.fmt.allocPrint(self.allocator, "-------------------------------------------------------------------\nFound {d} reference(s) in {d} file(s):\n\n", .{ refs.len, file_count });
                                    defer self.allocator.free(summary);
                                    try text.appendSlice(self.allocator, summary);

                                    var current_file: ?[]const u8 = null;
                                    for (refs) |r| {
                                        if (current_file == null or !std.mem.eql(u8, current_file.?, r.file_path)) {
                                            if (current_file != null) {
                                                try text.appendSlice(self.allocator, "\n");
                                            }
                                            const file_header = try std.fmt.allocPrint(self.allocator, "[{s}]\n", .{
                                                std.fs.path.basename(r.file_path),
                                            });
                                            defer self.allocator.free(file_header);
                                            try text.appendSlice(self.allocator, file_header);
                                            current_file = r.file_path;
                                        }

                                        var snippet: []const u8 = "";
                                        var snippet_allocated = false;
                                        if (std.Io.Dir.openFileAbsolute(self.io, r.file_path, .{})) |file| {
                                            defer file.close(self.io);
                                            const content = std.Io.Dir.cwd().readFileAlloc(self.io, r.file_path, self.allocator, .limited(10 * 1024 * 1024)) catch null;
                                            if (content) |c| {
                                                defer self.allocator.free(c);
                                                var line_num: u32 = 0;
                                                var line_start: usize = 0;
                                                for (c, 0..) |ch, idx| {
                                                    if (line_num == r.line) {
                                                        var line_end = idx;
                                                        while (line_end < c.len and c[line_end] != '\n') : (line_end += 1) {}
                                                        const line_content = std.mem.trim(u8, c[line_start..line_end], " \t");
                                                        const max_len: usize = 60;
                                                        if (line_content.len > max_len) {
                                                            snippet = self.allocator.dupe(u8, line_content[0..max_len]) catch "";
                                                        } else {
                                                            snippet = self.allocator.dupe(u8, line_content) catch "";
                                                        }
                                                        snippet_allocated = snippet.len > 0;
                                                        break;
                                                    }
                                                    if (ch == '\n') {
                                                        line_num += 1;
                                                        line_start = idx + 1;
                                                    }
                                                }
                                            }
                                        } else |_| {}

                                        defer if (snippet_allocated) self.allocator.free(snippet);

                                        const ref_line = try std.fmt.allocPrint(self.allocator, "   Ln {d}: {s}\n", .{
                                            r.line + 1,
                                            if (snippet.len > 0) snippet else "(unable to read)",
                                        });
                                        defer self.allocator.free(ref_line);
                                        try text.appendSlice(self.allocator, ref_line);
                                    }

                                    try self.openVirtualBuffer("[References]", text.items);
                                    try self.sendUpdate();
                                } else {
                                    const sym = self.references_symbol_name orelse "symbol";
                                    const no_refs_msg = try std.fmt.allocPrint(self.allocator, "+------------------------------------------------------------------+\n|  SYMBOL REFERENCES                                               |\n+------------------------------------------------------------------+\n\nNo references found for: {s}\n", .{sym});
                                    defer self.allocator.free(no_refs_msg);
                                    try self.openVirtualBuffer("[References]", no_refs_msg);
                                    self.requestRender();
                                }
                            }
                        }

                        if (self.completion_pending) {
                            if (self.lsp_manager.popCompletionResult()) |items| {
                                self.completion_pending = false;
                                defer self.lsp_manager.freeCompletionItems(items);
                                self.dismissCompletion();

                                if (items.len > 0) {
                                    self.completion_active = true;
                                    self.completion_selected = 0;

                                    for (items) |item| {
                                        const icon = switch (item.kind) {
                                            .function, .method, .constructor => "󰊕",
                                            .variable, .field, .property => "󰫧",
                                            .class, .interface, .struct_type => "󰆧",
                                            .module, .folder => "",
                                            .keyword => "󰌆",
                                            .value, .enumMember, .enumValue => "",
                                            .snippet => "",
                                            .text => "",
                                            else => "",
                                        };
                                        const category: protocol.CompletionEntry.KindCategory = switch (item.kind) {
                                            .function, .method, .constructor => .function,
                                            .variable => .variable,
                                            .field, .property => .field,
                                            .class, .interface, .struct_type, .type_parameter => .type_,
                                            .module, .folder => .module,
                                            .keyword => .keyword,
                                            .value, .enumMember, .enumValue, .constant => .value,
                                            .snippet => .snippet,
                                            .text => .text,
                                            else => .other,
                                        };
                                        const detail_copy = if (item.detail) |d| try self.allocator.dupe(u8, d) else null;
                                        try self.completion_items.append(self.allocator, .{
                                            .label = try self.allocator.dupe(u8, item.label),
                                            .kind_icon = icon,
                                            .detail = detail_copy,
                                            .kind_category = category,
                                        });
                                    }
                                    try self.updateCompletionFilter();
                                }
                                self.requestRender();
                            }
                        }

                        if (self.needs_render) {
                            const now = std.Io.Clock.real.now(self.io).toMilliseconds();
                            const time_since_render = now - self.last_render_time;
                            if (time_since_render >= self.min_render_interval_ms) {
                                self.needs_render = false;
                                self.last_render_time = now;
                                try self.sendUpdate();
                            }
                        }

                        const s = self.state();
                        if (s.cursor_row != self.last_cursor_row or s.cursor_col != self.last_cursor_col) {
                            self.last_cursor_row = s.cursor_row;
                            self.last_cursor_col = s.cursor_col;

                            self.plugin_manager.broadcastEvent(.cursor_moved, self.buffer_manager.getActive().name);
                        }

                        self.processDebouncedLspUpdate();
                    },
                    .input => |key| {
                        self.last_cursor_move_time = std.Io.Clock.real.now(self.io).toMilliseconds();
                        if (self.hover_content) |c| {
                            self.allocator.free(c);
                            self.hover_content = null;
                            self.hover_pending = false;
                            try self.sendUpdate();
                        }

                        if (key.matches(vaxis.Key.escape, .{})) {
                            if (self.mode == .file_picker or self.mode == .buffer_picker or self.mode == .log_view) {
                                self.mode = self.previous_mode;
                                try self.sendUpdate();
                                continue;
                            } else if (self.mode == .command_palette) {
                                self.mode = self.previous_mode;
                                self.command_palette_input.clearRetainingCapacity();
                                try self.sendUpdate();
                                continue;
                            } else if (self.mode == .visual_search) {
                                self.mode = .visual;
                                self.search_input.clearRetainingCapacity();
                                try self.sendUpdate();
                                continue;
                            } else if (self.mode == .go_to_line) {
                                self.mode = self.previous_mode;
                                self.go_to_line_input.clearRetainingCapacity();
                                try self.sendUpdate();
                                continue;
                            } else if (self.mode == .symbol_picker) {
                                self.mode = self.previous_mode;
                                self.symbol_picker_query.clearRetainingCapacity();
                                try self.sendUpdate();
                                continue;
                            } else if (self.mode != .select) {
                                if (self.mode == .terminal) {
                                    self.terminal_input.clearRetainingCapacity();
                                    self.terminal_output.clearRetainingCapacity();
                                }
                                self.mode = .select;
                                try self.sendUpdate();
                            }
                            continue;
                        }

                        switch (self.mode) {
                            .log_view => {},
                            .select => {
                                const result = self.handleSelectInput(key) catch |err| {
                                    if (err == error.UserQuit) {
                                        // best-effort: shutting down anyway; UI may have already exited
                                        self.sendQuitToUI() catch {};
                                        return;
                                    }
                                    return err;
                                };
                                if (result) {
                                    try self.sendUpdate();
                                }
                            },
                            .visual => {
                                if (try self.handleVisualInput(key)) {
                                    try self.sendUpdate();
                                }
                            },
                            .insert => {
                                if (try self.handleInsertInput(key)) {
                                    try self.sendUpdate();
                                }
                            },
                            .view => {
                                if (try self.handleViewInput(key)) {
                                    try self.sendUpdate();
                                }
                            },
                            .terminal => {
                                try self.handleTerminalInput(key);
                                try self.sendUpdate();
                            },
                            .file_picker => {
                                if (try self.handleFilePickerInput(key)) {
                                    try self.sendUpdate();
                                }
                            },
                            .buffer_picker => {
                                if (try self.handleBufferPickerInput(key)) {
                                    try self.sendUpdate();
                                }
                            },
                            .save_as_mode => {
                                if (try self.handleSaveAsInput(key)) {
                                    try self.sendUpdate();
                                }
                            },
                            .visual_search => {
                                if (try self.handleVisualSearchInput(key)) {
                                    try self.sendUpdate();
                                }
                            },
                            .command_palette => {
                                if (try self.handleCommandPaletteInput(key)) {
                                    try self.sendUpdate();
                                }
                            },
                            .go_to_line => {
                                if (try self.handleGoToLineInput(key)) {
                                    try self.sendUpdate();
                                }
                            },
                            .symbol_picker => {
                                if (try self.handleSymbolPickerInput(key)) {
                                    try self.sendUpdate();
                                }
                            },
                            .global_search => {
                                if (try self.handleGlobalSearchInput(key)) {
                                    try self.sendUpdate();
                                }
                            },
                        }
                    },

                    .mouse => |mouse| {
                        if (self.mode == .terminal) {
                            if (mouse.button == .wheel_up) {
                                const scroll_amount: usize = 3;
                                if (self.terminal_scroll_offset >= scroll_amount) {
                                    self.terminal_scroll_offset -= scroll_amount;
                                } else {
                                    self.terminal_scroll_offset = 0;
                                }
                                try self.sendUpdate();
                                continue;
                            } else if (mouse.button == .wheel_down) {
                                self.terminal_scroll_offset += 3;
                                try self.sendUpdate();
                                continue;
                            }
                            continue;
                        }

                        if (mouse.button == .wheel_up) {
                            const s = self.state();
                            const scroll_amount: usize = 3;
                            if (s.scroll_offset > 0) {
                                s.scroll_offset -|= scroll_amount;
                                const height = if (self.win_size.rows > 2) self.win_size.rows - 2 else 1;
                                if (height > 0) {
                                    const max_visible = s.scroll_offset + height - 1;
                                    if (s.cursor_row > max_visible) {
                                        s.cursor_row = max_visible;
                                    }
                                }
                                self.scroll_in_progress = true;
                                self.last_scroll_time = std.Io.Clock.real.now(self.io).toMilliseconds();
                                try self.sendUpdate();
                            }
                            continue;
                        } else if (mouse.button == .wheel_down) {
                            const s = self.state();
                            const scroll_amount: usize = 3;
                            const line_count = s.buffer.lineCount();
                            const visible_height = if (self.win_size.rows > 2) self.win_size.rows - 2 else 1;
                            const max_scroll = if (line_count > visible_height) line_count - visible_height else 0;
                            if (s.scroll_offset < max_scroll) {
                                s.scroll_offset = @min(s.scroll_offset + scroll_amount, max_scroll);
                                if (s.cursor_row < s.scroll_offset) {
                                    s.cursor_row = s.scroll_offset;
                                }
                            }
                            self.scroll_in_progress = true;
                            self.last_scroll_time = std.Io.Clock.real.now(self.io).toMilliseconds();
                            try self.sendUpdate();
                            continue;
                        }

                        self.dismissCompletion();

                        var active_row = mouse.row;
                        var active_col = mouse.col;

                        if (self.split_manager) |*sm| {
                            const content_rows = if (self.win_size.rows > 1) self.win_size.rows - 1 else 1;
                            const params = protocol.RenderParams{ .rows = content_rows, .cols = self.win_size.cols };
                            var bounds = sm.getAllPaneBounds(self.allocator, params) catch |err| {
                                log.err("Failed to get split bounds: {}", .{err});
                                continue;
                            };
                            defer bounds.deinit(self.allocator);

                            var clicked_pane: ?protocol.PaneBound = null;
                            for (bounds.items) |b| {
                                if (mouse.row >= b.y and mouse.row < b.y + b.height and
                                    mouse.col >= b.x and mouse.col < b.x + b.width)
                                {
                                    clicked_pane = b;
                                    break;
                                }
                            }

                            if (clicked_pane) |pane_bound| {
                                if (pane_bound.pane.id != sm.focused_pane_id) {
                                    self.syncStateToPane();
                                    sm.focused_pane_id = pane_bound.pane.id;
                                    self.buffer_manager.switchTo(pane_bound.pane.buffer_index);
                                    self.refreshSyntaxForCurrentBuffer();
                                    self.syncPaneToState();
                                }

                                if (mouse.row > pane_bound.y) {
                                    active_row = @intCast(@as(usize, @intCast(mouse.row)) - (pane_bound.y + 1));
                                    active_col = @intCast(@as(usize, @intCast(mouse.col)) - (pane_bound.x));
                                } else {
                                    continue;
                                }
                            } else {
                                continue;
                            }
                        } else {
                            if (mouse.row == 0 or mouse.row >= self.win_size.rows - 1) {
                                continue;
                            }
                            active_row = mouse.row - 1;
                        }

                        const s = self.state();
                        const total_lines = s.buffer.lineCount();
                        const digits = if (total_lines > 0) std.math.log10_int(total_lines) + 1 else 1;
                        const gutter_width = digits + 1;

                        const mouse_col_usize = @as(usize, @intCast(active_col));
                        const in_text_area = mouse_col_usize >= gutter_width;

                        if (mouse.type == .press and mouse.button == .left) {
                            if (in_text_area) {
                                const target_row = @as(usize, @intCast(active_row)) + s.scroll_offset;
                                const target_col = mouse_col_usize - gutter_width;

                                if (target_row < total_lines) {
                                    self.mouse_pressed = true;
                                    self.mouse_press_row = target_row;
                                    self.mouse_press_col = target_col;

                                    s.cursor_row = target_row;
                                    s.cursor_col = target_col;

                                    s.selection_anchor = null;
                                    if (self.mode == .visual) {
                                        self.mode = .select;
                                    }

                                    try self.sendUpdate();
                                }
                            } else {
                                const target_row = @as(usize, @intCast(active_row)) + s.scroll_offset;
                                if (target_row < total_lines) {
                                    self.mouse_pressed = true;
                                    self.mouse_press_row = target_row;
                                    self.mouse_press_col = 0;

                                    s.cursor_row = target_row;
                                    s.cursor_col = 0;
                                    s.selection_anchor = null;
                                    if (self.mode == .visual) {
                                        self.mode = .select;
                                    }

                                    try self.sendUpdate();
                                }
                            }
                        } else if (mouse.type == .drag and mouse.button == .left) {
                            if (in_text_area and self.mouse_pressed) {
                                const target_row = @as(usize, @intCast(active_row)) + s.scroll_offset;
                                const target_col = mouse_col_usize - gutter_width;

                                if (target_row < total_lines) {
                                    if (self.mode != .visual) {
                                        self.mode = .visual;
                                        s.selection_anchor = .{ .row = self.mouse_press_row, .col = self.mouse_press_col };
                                    }

                                    s.cursor_row = target_row;
                                    s.cursor_col = target_col;

                                    try self.sendUpdate();
                                }
                            }
                        } else if (mouse.type == .release and mouse.button == .left) {
                            if (self.mouse_pressed) {
                                self.mouse_pressed = false;
                            }
                        }
                    },
                    .command => |cmd| {
                        switch (cmd) {
                            .save => try self.saveCurrentFile(),
                            .open => try self.openFilePicker(),
                            .close => {
                                const removed_index = self.buffer_manager.active_index;
                                const closed = self.buffer_manager.closeActive();
                                if (closed) {
                                    if (self.split_manager) |*sm| {
                                        sm.onBufferClosed(removed_index, self.buffer_manager.buffers.items.len);
                                    }
                                }
                            },
                            .next_buffer => {
                                self.syncStateToPane();
                                self.buffer_manager.nextBuffer();
                                self.refreshSyntaxForCurrentBuffer();
                                if (self.split_manager) |*sm| sm.setFocusedBuffer(self.buffer_manager.active_index);
                                self.syncPaneToState();
                            },
                            .prev_buffer => {
                                self.syncStateToPane();
                                self.buffer_manager.prevBuffer();
                                self.refreshSyntaxForCurrentBuffer();
                                if (self.split_manager) |*sm| sm.setFocusedBuffer(self.buffer_manager.active_index);
                                self.syncPaneToState();
                            },

                            .quit => return,
                        }
                        try self.sendUpdate();
                    },
                    .quit => return,
                    .render_update => {},
                    .resize => |size| {
                        self.win_size = size;
                        self.invalidatePaneHeightCache();
                        try self.sendUpdate();
                    },
                    .mode_change => |new_mode| {
                        self.mode = new_mode;
                        try self.sendUpdate();
                    },
                    .terminal_execute => {},
                    .terminal_output_chunk => |chunk| {
                        const max_output = 10 * 1024 * 1024;
                        if (self.terminal_output.items.len + chunk.len <= max_output) {
                            const was_at_bottom = terminal_proc.isTerminalAtBottom(self);
                            try self.terminal_output.appendSlice(self.allocator, chunk);

                            terminal_proc.capTerminalOutputLines(self, 1000);

                            if (was_at_bottom) {
                                terminal_proc.scrollToTerminalBottom(self);
                            }
                        }
                        try self.sendUpdate();
                    },
                    .terminal_result => |res| {
                        self.terminal_running = false;
                        self.terminal_service.clearCurrentJob();

                        if (res.output.len == 0) {} else {
                            try self.terminal_output.appendSlice(self.allocator, res.output);
                        }
                        try self.sendUpdate();
                    },
                }
            }
        }
    }

    fn handleSelectInput(self: *Core, key: vaxis.Key) !bool {
        // `]d` / `[d` jump to next/previous diagnostic. The bracket prefix
        // is a one-shot — any non-matching follow-up cancels it.
        if (self.bracket_pending) |prefix| {
            self.bracket_pending = null;
            if (key.matches('d', .{})) {
                try self.jumpToDiagnostic(prefix == ']');
                return true;
            }
            // Tree-sitter AST motions:
            //   `]s` / `[s` — next/previous sibling
            //   `]m` / `[m` — next/previous function or method
            if (key.matches('s', .{})) {
                if (try self.jumpToSibling(prefix == ']')) return true;
                return true;
            }
            if (key.matches('m', .{})) {
                if (try self.jumpToFunction(prefix == ']')) return true;
                return true;
            }
            // Fall through and let the new key be dispatched normally.
        }
        if (key.matches(']', .{}) and !self.leader_pending) {
            self.bracket_pending = ']';
            return true;
        }
        if (key.matches('[', .{}) and !self.leader_pending) {
            self.bracket_pending = '[';
            return true;
        }
        if (self.leader_pending) {
            if (key.codepoint >= '0' and key.codepoint <= '9') {
                try self.leader_number_input.append(self.allocator, @intCast(key.codepoint));

                const num_str = self.leader_number_input.items;
                const buf_num = std.fmt.parseInt(usize, num_str, 10) catch 0;
                const total_buffers = self.buffer_manager.buffers.items.len;

                if (buf_num > 0 and buf_num <= total_buffers) {
                    const next_possible = buf_num * 10;
                    if (next_possible > total_buffers) {
                        self.leader_number_input.clearRetainingCapacity();
                        self.buffer_manager.switchTo(buf_num - 1);
                        self.refreshSyntaxForCurrentBuffer();
                        if (self.split_manager) |*sm| sm.setFocusedBuffer(self.buffer_manager.active_index);
                        return true;
                    }
                }

                return true;
            }

            if (self.leader_number_input.items.len > 0) {
                const num_str = self.leader_number_input.items;
                const buf_num = std.fmt.parseInt(usize, num_str, 10) catch 0;
                self.leader_number_input.clearRetainingCapacity();

                if (buf_num > 0 and buf_num <= self.buffer_manager.buffers.items.len) {
                    self.buffer_manager.switchTo(buf_num - 1);
                    self.refreshSyntaxForCurrentBuffer();
                    if (self.split_manager) |*sm| sm.setFocusedBuffer(self.buffer_manager.active_index);
                }
                return true;
            }

            log.debug("Leader action key: codepoint={d} ('{c}') shift={}", .{ key.codepoint, @as(u8, @intCast(key.codepoint & 0xFF)), key.mods.shift });
            switch (key.codepoint) {
                Keys.action_save => try self.saveCurrentFile(),
                Keys.action_open => {
                    try self.openFilePicker();
                    self.leader_pending = false;
                },
                Keys.action_buffer => {
                    self.previous_mode = self.mode;
                    self.mode = .buffer_picker;
                    self.buffer_manager.pickerReset();
                    self.buffer_picker_number_input.clearRetainingCapacity();
                    self.leader_pending = false;
                },
                Keys.action_quit => return error.UserQuit,
                Keys.action_close => {
                    if (self.split_manager) |*sm| {
                        if (sm.hasSplits()) {
                            self.syncStateToPane();
                            sm.closePane();
                            self.syncPaneToState();
                            const remaining_pane = sm.getFocusedPane();
                            if (remaining_pane.buffer_index < self.buffer_manager.buffers.items.len) {
                                self.buffer_manager.active_index = remaining_pane.buffer_index;
                            }
                            if (!sm.hasSplits()) {
                                sm.deinit();
                                self.split_manager = null;
                            }
                        } else {
                            const pane = sm.getFocusedPane();
                            if (pane.buffer_index < self.buffer_manager.buffers.items.len) {
                                self.buffer_manager.active_index = pane.buffer_index;
                            }
                            sm.deinit();
                            self.split_manager = null;
                        }
                    } else {
                        _ = self.buffer_manager.closeActive();
                    }
                },
                Keys.action_next => {
                    const s = self.state();
                    if (s.file_path) |path| {
                        self.jump_list.recordJump(path, s.cursor_row, s.cursor_col) catch |err| {
                            log.debug("Failed to record jump location: {}", .{err});
                        };
                    }

                    self.syncStateToPane();
                    self.buffer_manager.nextBuffer();
                    self.refreshSyntaxForCurrentBuffer();
                    if (self.split_manager) |*sm| sm.setFocusedBuffer(self.buffer_manager.active_index);
                    self.syncPaneToState();
                },
                Keys.action_prev => {
                    const s = self.state();
                    if (s.file_path) |path| {
                        self.jump_list.recordJump(path, s.cursor_row, s.cursor_col) catch |err| {
                            log.debug("Failed to record jump location: {}", .{err});
                        };
                    }

                    self.syncStateToPane();
                    self.buffer_manager.prevBuffer();
                    self.refreshSyntaxForCurrentBuffer();
                    if (self.split_manager) |*sm| sm.setFocusedBuffer(self.buffer_manager.active_index);
                    self.syncPaneToState();
                },

                Keys.action_help => {
                    try self.openVirtualBuffer("[HELP]", Help.help_text);
                    self.leader_pending = false;
                },
                Keys.action_palette, ':' => {
                    self.previous_mode = self.mode;
                    self.mode = .command_palette;
                    self.command_palette_input.clearRetainingCapacity();
                    self.command_palette_results.clearRetainingCapacity();
                    try self.command_registry.search("", &self.command_palette_results, self.allocator);
                    self.command_palette_selected = 0;
                    self.leader_pending = false;
                },
                Keys.action_undo => try EditCommands.cmdEditUndo(self),
                Keys.action_redo => try EditCommands.cmdEditRedo(self),
                Keys.action_jobs => try SystemCommands.cmdJobList(self),
                Keys.action_copy => try EditCommands.cmdEditCopy(self),
                Keys.action_cut => try EditCommands.cmdEditCut(self),
                Keys.action_paste => try EditCommands.cmdEditPaste(self),

                Keys.action_lsp_definition => try LspCommands.cmdLspGoToDefinition(self),
                Keys.action_lsp_references => try LspCommands.cmdLspFindReferences(self),
                Keys.action_lsp_hover => try LspCommands.cmdLspHover(self),
                Keys.action_lsp_diagnostics => try LspCommands.cmdLspShowDiagnostics(self),
                Keys.action_document_symbols => try cmdDocumentSymbols(self, null),

                Keys.action_jump_back => try cmdJumpBack(self, null),
                Keys.action_jump_forward => try cmdJumpForward(self, null),

                Keys.action_split_horizontal => try SplitCommands.cmdSplitHorizontal(self),
                Keys.action_split_vertical => try SplitCommands.cmdSplitVertical(self),

                Keys.action_global_search => {
                    self.previous_mode = self.mode;
                    self.mode = .global_search;
                    self.global_search_query.clearRetainingCapacity();
                    self.global_search_replace.clearRetainingCapacity();
                    self.global_search_selected_file = 0;
                    self.global_search_selected_match = 0;
                    self.global_search_focus_replace = false;
                    self.clearGlobalSearchResults();
                    self.global_search_ran = false;
                    self.leader_pending = false;
                },

                Keys.action_git_diff => try GitCommands.cmdGitDiff(self),

                vaxis.Key.left => {
                    if (self.split_manager) |*sm| {
                        self.syncStateToPane();
                        sm.focusLeft();
                        self.syncPaneToState();
                        self.ensureLspDocument() catch |err| {
                            log.debug("ensureLspDocument failed on pane focus: {}", .{err});
                        };
                    }
                    self.leader_pending = false;
                },
                vaxis.Key.right => {
                    if (self.split_manager) |*sm| {
                        self.syncStateToPane();
                        sm.focusRight();
                        self.syncPaneToState();
                        self.ensureLspDocument() catch |err| {
                            log.debug("ensureLspDocument failed on pane focus: {}", .{err});
                        };
                    }
                    self.leader_pending = false;
                },
                vaxis.Key.up => {
                    if (self.split_manager) |*sm| {
                        self.syncStateToPane();
                        sm.focusUp();
                        self.syncPaneToState();
                        self.ensureLspDocument() catch |err| {
                            log.debug("ensureLspDocument failed on pane focus: {}", .{err});
                        };
                    }
                    self.leader_pending = false;
                },
                vaxis.Key.down => {
                    if (self.split_manager) |*sm| {
                        self.syncStateToPane();
                        sm.focusDown();
                        self.syncPaneToState();
                        self.ensureLspDocument() catch |err| {
                            log.debug("ensureLspDocument failed on pane focus: {}", .{err});
                        };
                    }
                    self.leader_pending = false;
                },

                vaxis.Key.escape => {
                    self.leader_pending = false;
                },

                Keys.leader => {},

                else => {
                    self.leader_pending = false;
                },
            }
            return true;
        }

        if (key.codepoint >= '0' and key.codepoint <= '9' and !key.mods.alt and !key.mods.ctrl and !key.mods.super) {
            const digit = key.codepoint - '0';
            if (digit == 0 and self.nav_repeat_count == 0) {
                const s = self.state();
                s.cursor_col = 0;
                return true;
            }
            self.nav_repeat_count = self.nav_repeat_count * 10 + digit;
            return true;
        }

        const count = if (self.nav_repeat_count > 0) self.nav_repeat_count else 1;
        self.nav_repeat_count = 0;

        if (key.matches(Keys.leader, .{})) {
            self.leader_pending = true;
            return true;
        }

        if (key.matches(Keys.save.codepoint, Keys.save.mods)) {
            try self.saveCurrentFile();
            return true;
        }
        if (key.matches(Keys.open.codepoint, Keys.open.mods)) {
            try self.openFilePicker();
            return true;
        }
        if (key.matches(Keys.quit.codepoint, Keys.quit.mods)) {
            return error.UserQuit;
        }
        if (key.matches(Keys.close_buffer.codepoint, Keys.close_buffer.mods)) {
            log.info("Cmd+W pressed", .{});
            if (self.split_manager) |*sm| {
                log.info("split_manager exists, hasSplits={}", .{sm.hasSplits()});
                log.info("focused_pane_id={}, countPanes={}", .{ sm.getFocusedPaneId(), sm.countPanes() });
                if (sm.hasSplits()) {
                    self.syncStateToPane();
                    sm.closePane();
                    log.info("After closePane: hasSplits={}, countPanes={}", .{ sm.hasSplits(), sm.countPanes() });
                    self.syncPaneToState();
                    const remaining_pane = sm.getFocusedPane();
                    log.info("remaining_pane id={}, buffer_index={}", .{ remaining_pane.id, remaining_pane.buffer_index });
                    if (remaining_pane.buffer_index < self.buffer_manager.buffers.items.len) {
                        self.buffer_manager.active_index = remaining_pane.buffer_index;
                        log.info("Set buffer_manager.active_index={}", .{self.buffer_manager.active_index});
                    }
                    if (!sm.hasSplits()) {
                        log.info("No more splits, deiniting split_manager", .{});
                        sm.deinit();
                        self.split_manager = null;
                    }
                } else {
                    log.info("hasSplits=false, deiniting", .{});
                    const pane = sm.getFocusedPane();
                    if (pane.buffer_index < self.buffer_manager.buffers.items.len) {
                        self.buffer_manager.active_index = pane.buffer_index;
                    }
                    sm.deinit();
                    self.split_manager = null;
                }
                log.info("Calling sendUpdate, split_manager null={}", .{self.split_manager == null});
                try self.sendUpdate();
            } else {
                log.info("No split_manager, closing active buffer", .{});
                _ = self.buffer_manager.closeActive();
            }
            return true;
        }
        if (key.matches(Keys.next_buffer.codepoint, Keys.next_buffer.mods)) {
            self.syncStateToPane();
            self.buffer_manager.nextBuffer();
            self.refreshSyntaxForCurrentBuffer();
            if (self.split_manager) |*sm| sm.setFocusedBuffer(self.buffer_manager.active_index);
            self.syncPaneToState();
            return true;
        }
        if (key.matches(Keys.prev_buffer.codepoint, Keys.prev_buffer.mods)) {
            self.syncStateToPane();
            self.buffer_manager.prevBuffer();
            self.refreshSyntaxForCurrentBuffer();
            if (self.split_manager) |*sm| sm.setFocusedBuffer(self.buffer_manager.active_index);
            self.syncPaneToState();
            return true;
        }

        if (key.matches(Keys.mode_view, .{})) {
            self.mode = .view;
            return true;
        }
        if (key.matches(Keys.mode_insert, .{})) {
            self.mode = .insert;
            return true;
        }
        if (key.matches('v', .{})) {
            self.mode = .visual;
            const s = self.state();
            s.selection_anchor = .{ .row = s.cursor_row, .col = s.cursor_col };
            return true;
        }
        // `V` selects the smallest AST node under the cursor — entry
        // point for tree-sitter aware visual editing. `+` / `-` in
        // visual mode then expand or shrink the selection.
        if (key.matches('V', .{})) {
            const s = self.state();
            if (self.syntax_manager.selectCurrentNode(s.cursor_row, s.cursor_col)) |sel| {
                s.selection_anchor = .{ .row = sel.start_line, .col = sel.start_col };
                s.cursor_row = sel.end_line;
                s.cursor_col = sel.end_col;
                self.mode = .visual;
                return true;
            }
            // Fallthrough: no tree, leave to normal handling.
        }
        if (key.matches(Keys.mode_terminal, .{})) {
            self.mode = .terminal;
            self.terminal_input.clearRetainingCapacity();
            return true;
        }

        if (self.split_manager) |*sm| {
            if (key.matches('h', .{ .ctrl = true })) {
                self.syncStateToPane();
                sm.focusLeft();
                self.syncPaneToState();
                self.invalidatePaneHeightCache();
                return true;
            }
            if (key.matches('l', .{ .ctrl = true })) {
                self.syncStateToPane();
                sm.focusRight();
                self.syncPaneToState();
                self.invalidatePaneHeightCache();
                return true;
            }
            if (key.matches('k', .{ .ctrl = true })) {
                self.syncStateToPane();
                sm.focusUp();
                self.syncPaneToState();
                self.invalidatePaneHeightCache();
                return true;
            }
            if (key.matches('j', .{ .ctrl = true })) {
                self.syncStateToPane();
                sm.focusDown();
                self.syncPaneToState();
                self.invalidatePaneHeightCache();
                return true;
            }
        }

        if (key.matches(vaxis.Key.left, .{}) or key.matches(Keys.nav_left, .{})) {
            const s = self.state();
            s.cursor_col -|= count;
            return true;
        }
        if (key.matches(vaxis.Key.right, .{}) or key.matches(Keys.nav_right, .{})) {
            const s = self.state();
            s.cursor_col += count;
            s.clampCursorToLine();
            return true;
        }
        if (key.matches(vaxis.Key.down, .{}) or key.matches(Keys.nav_down, .{})) {
            const s = self.state();
            s.cursor_row += count;
            s.clampCursorToLine();
            return true;
        }
        if (key.matches(vaxis.Key.up, .{}) or key.matches(Keys.nav_up, .{})) {
            const s = self.state();
            s.cursor_row -|= count;
            s.clampCursorToLine();
            return true;
        }
        if (key.matches(vaxis.Key.page_down, .{})) {
            const s = self.state();
            s.cursor_row += 20 * count;
            s.clampCursorToLine();
            self.scroll_in_progress = true;
            self.last_scroll_time = std.Io.Clock.real.now(self.io).toMilliseconds();
            return true;
        }
        if (key.matches(vaxis.Key.page_up, .{})) {
            const s = self.state();
            s.cursor_row -|= 20 * count;
            s.clampCursorToLine();
            self.scroll_in_progress = true;
            self.last_scroll_time = std.Io.Clock.real.now(self.io).toMilliseconds();
            return true;
        }
        if (key.matches(vaxis.Key.home, .{})) {
            self.state().cursor_col = 0;
            return true;
        }
        if (key.matches(vaxis.Key.end, .{})) {
            const s = self.state();
            s.cursor_col = std.math.maxInt(usize);
            s.clampCursorToLine();
            return true;
        }

        if (key.matches('%', .{ .shift = true })) {
            try NavCommands.cmdNavMatchBracket(self);
            return true;
        }

        if (key.matches(Keys.search_next, .{})) {
            if (self.last_search_query.items.len > 0) {
                const s = self.state();
                const query = self.last_search_query.items;
                const start_offset = s.getOffsetFromCursor() + 1;

                if (try s.buffer.find(query, start_offset)) |found_offset| {
                    s.updateCursorFromOffset(found_offset);
                } else {
                    if (try s.buffer.find(query, 0)) |found_offset| {
                        s.updateCursorFromOffset(found_offset);
                        log.info("Search wrapped around to beginning", .{});
                    }
                }
            }
            return true;
        }
        if (key.matches(Keys.search_prev, .{})) {
            if (self.last_search_query.items.len > 0) {
                const s = self.state();
                const query = self.last_search_query.items;
                const end_offset = s.getOffsetFromCursor();

                if (try s.buffer.findLast(query, end_offset)) |found_offset| {
                    s.updateCursorFromOffset(found_offset);
                } else {
                    const len = s.buffer.totalLength();
                    if (try s.buffer.findLast(query, len)) |found_offset| {
                        s.updateCursorFromOffset(found_offset);
                    }
                }
            }
            return true;
        }

        if (key.matches('/', .{})) {
            self.previous_mode = .select;
            self.mode = .visual_search;
            self.search_input.clearRetainingCapacity();
            return true;
        }

        return false;
    }

    fn handleVisualInput(self: *Core, key: vaxis.Key) !bool {
        if (key.matches(vaxis.Key.delete, .{}) or key.matches(vaxis.Key.backspace, .{})) {
            const s = self.state();

            var start_row: usize = s.cursor_row;
            var start_col: usize = s.cursor_col;
            var end_row: usize = s.cursor_row;
            var end_col: usize = s.cursor_col;

            if (s.selection_anchor) |anchor| {
                if (anchor.row < s.cursor_row or (anchor.row == s.cursor_row and anchor.col <= s.cursor_col)) {
                    start_row = anchor.row;
                    start_col = anchor.col;
                    end_row = s.cursor_row;
                    end_col = s.cursor_col;
                } else {
                    start_row = s.cursor_row;
                    start_col = s.cursor_col;
                    end_row = anchor.row;
                    end_col = anchor.col;
                }
            }

            const start_off = s.getOffsetFor(start_row, start_col);
            const end_off = s.getOffsetFor(end_row, end_col);
            try s.deleteRange(start_off, end_off);

            s.selection_anchor = null;
            self.mode = .select;
            try self.sendLspDocChanged();
            try self.sendUpdate();
            return true;
        }

        if (key.matches('/', .{})) {
            self.previous_mode = .visual;
            self.mode = .visual_search;
            self.search_input.clearRetainingCapacity();
            return true;
        }

        // Structural expand / shrink. `+` grows the selection to the
        // enclosing AST node; `-` walks back to the first named child.
        if (key.matches('+', .{}) or key.matches('=', .{})) {
            try self.adjustSelectionStructural(.expand);
            return true;
        }
        if (key.matches('-', .{})) {
            try self.adjustSelectionStructural(.shrink);
            return true;
        }

        if (key.matches('y', .{})) {
            try EditCommands.cmdEditCopy(self);
            return true;
        }

        if (key.matches('x', .{})) {
            try EditCommands.cmdEditCut(self);
            return true;
        }

        if (key.matches(vaxis.Key.escape, .{}) or key.matches('v', .{})) {
            self.mode = .select;
            self.state().selection_anchor = null;
            self.nav_repeat_count = 0;
            return true;
        }

        if (key.codepoint >= '0' and key.codepoint <= '9' and !key.mods.alt and !key.mods.ctrl and !key.mods.super) {
            const digit = key.codepoint - '0';
            if (digit == 0 and self.nav_repeat_count == 0) {
                const s = self.state();
                s.cursor_col = 0;
                return true;
            }
            self.nav_repeat_count = self.nav_repeat_count * 10 + digit;
            return true;
        }

        const count = if (self.nav_repeat_count > 0) self.nav_repeat_count else 1;
        self.nav_repeat_count = 0;

        const s = self.state();
        if (key.matches(vaxis.Key.left, .{}) or key.matches('h', .{})) {
            s.cursor_col -|= count;
            return true;
        }
        if (key.matches(vaxis.Key.right, .{}) or key.matches('l', .{})) {
            s.cursor_col += count;
            s.clampCursorToLine();
            return true;
        }
        if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
            s.cursor_row += count;
            s.clampCursorToLine();
            return true;
        }
        if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
            s.cursor_row -|= count;
            s.clampCursorToLine();
            return true;
        }
        if (key.matches(vaxis.Key.page_down, .{})) {
            s.cursor_row += 20 * count;
            s.clampCursorToLine();
            self.scroll_in_progress = true;
            self.last_scroll_time = std.Io.Clock.real.now(self.io).toMilliseconds();
            return true;
        }
        if (key.matches(vaxis.Key.page_up, .{})) {
            s.cursor_row -|= 20 * count;
            s.clampCursorToLine();
            self.scroll_in_progress = true;
            self.last_scroll_time = std.Io.Clock.real.now(self.io).toMilliseconds();
            return true;
        }
        if (key.matches(vaxis.Key.home, .{})) {
            s.cursor_col = 0;
            return true;
        }
        if (key.matches(vaxis.Key.end, .{})) {
            s.cursor_col = std.math.maxInt(usize);
            s.clampCursorToLine();
            return true;
        }

        return false;
    }

    fn handleVisualSearchInput(self: *Core, key: vaxis.Key) !bool {
        if (key.matches(vaxis.Key.enter, .{})) {
            if (self.search_input.items.len > 0) {
                self.last_search_query.clearRetainingCapacity();
                self.last_search_query.appendSlice(self.allocator, self.search_input.items) catch |err| {
                    log.warn("Failed to persist last search query: {}", .{err});
                };

                const query = self.search_input.items;
                const s = self.state();

                const start_offset = s.getOffsetFromCursor();
                if (try s.buffer.find(query, start_offset)) |found_offset| {
                    s.updateCursorFromOffset(found_offset);

                    self.mode = self.previous_mode;
                    if (self.mode == .select) {
                        s.selection_anchor = null;
                    }
                    self.search_input.clearRetainingCapacity();
                } else {
                    self.mode = self.previous_mode;
                    self.search_input.clearRetainingCapacity();
                }
                return true;
            } else {
                self.mode = self.previous_mode;
                self.decoration_manager.removeBySource("search");
                return true;
            }
        } else if (key.matches(vaxis.Key.escape, .{})) {
            self.mode = self.previous_mode;
            self.search_input.clearRetainingCapacity();
            self.decoration_manager.removeBySource("search");
            return true;
        } else if (key.matches(vaxis.Key.backspace, .{})) {
            if (self.search_input.items.len > 0) {
                _ = self.search_input.pop();
                try self.updateSearchDecorations();
                return true;
            }
        } else if (key.text) |text| {
            try self.search_input.appendSlice(self.allocator, text);
            try self.updateSearchDecorations();
            return true;
        }
        return false;
    }

    fn updateSearchDecorations(self: *Core) !void {
        self.decoration_manager.removeBySource("search");

        const query = self.search_input.items;
        if (query.len == 0) return;

        const s = self.state();
        const total_lines = s.buffer.lineCount();
        if (total_lines == 0) return;

        var matches = std.ArrayListUnmanaged(Range).empty;
        defer matches.deinit(self.allocator);

        const visible_start = s.scroll_offset;
        const visible_end = @min(visible_start + 100, total_lines);

        var line_num: usize = visible_start;
        while (line_num < visible_end) : (line_num += 1) {
            const line = s.getLineContent(line_num) catch continue;
            defer self.allocator.free(line);

            var col: usize = 0;
            while (col + query.len <= line.len) {
                var match = true;
                for (0..query.len) |j| {
                    if (std.ascii.toLower(line[col + j]) != std.ascii.toLower(query[j])) {
                        match = false;
                        break;
                    }
                }
                if (match) {
                    try matches.append(self.allocator, Range.singleLine(line_num, col, col + query.len));
                    col += query.len;
                } else {
                    col += 1;
                }
            }
        }

        var current_idx: ?usize = null;
        const cursor_row = s.cursor_row;
        const cursor_col = s.cursor_col;
        for (matches.items, 0..) |range, i| {
            if (range.start_row == cursor_row and cursor_col >= range.start_col and cursor_col < range.end_col) {
                current_idx = i;
                break;
            }
        }

        try self.decoration_manager.addSearchMatches(matches.items, current_idx);
    }

    fn handleInsertInput(self: *Core, key: vaxis.Key) !bool {
        if (self.completion_active) {
            if (key.matches(vaxis.Key.up, .{})) {
                if (self.completion_selected > 0) self.completion_selected -= 1;
                return true;
            }
            if (key.matches(vaxis.Key.down, .{})) {
                if (self.filtered_completion_items.items.len > 0) {
                    if (self.completion_selected < self.filtered_completion_items.items.len - 1) {
                        self.completion_selected += 1;
                    }
                }
                return true;
            }
            if ((key.matches(vaxis.Key.tab, .{}) or key.matches(vaxis.Key.enter, .{})) and self.filtered_completion_items.items.len > 0) {
                try self.confirmCompletion();
                return true;
            }
            if (key.matches(vaxis.Key.escape, .{})) {
                self.dismissCompletion();
                return true;
            }
        }

        if (key.matches(Keys.open.codepoint, Keys.open.mods)) {
            try self.openFilePicker();
            return true;
        }
        if (key.matches(Keys.save.codepoint, Keys.save.mods)) {
            try self.saveCurrentFile();
            return true;
        }

        const s = self.state();
        if (key.matches(vaxis.Key.left, .{})) {
            if (s.cursor_col > 0) s.cursor_col -= 1;
        } else if (key.matches(vaxis.Key.right, .{})) {
            s.cursor_col += 1;
        } else if (key.matches(vaxis.Key.down, .{})) {
            s.cursor_row += 1;
        } else if (key.matches(vaxis.Key.up, .{})) {
            if (s.cursor_row > 0) s.cursor_row -= 1;
        } else if (key.matches(vaxis.Key.page_down, .{})) {
            s.cursor_row += 20;
            self.scroll_in_progress = true;
            self.last_scroll_time = std.Io.Clock.real.now(self.io).toMilliseconds();
        } else if (key.matches(vaxis.Key.page_up, .{})) {
            if (s.cursor_row >= 20) {
                s.cursor_row -= 20;
            } else {
                s.cursor_row = 0;
            }
            self.scroll_in_progress = true;
            self.last_scroll_time = std.Io.Clock.real.now(self.io).toMilliseconds();
        } else if (key.matches(vaxis.Key.home, .{})) {
            s.cursor_col = 0;
        } else if (key.matches(vaxis.Key.end, .{})) {
            s.cursor_col = std.math.maxInt(usize);
        } else if (key.matches(vaxis.Key.backspace, .{})) {
            const config = auto_pair.AutoPairConfig{
                .enabled = self.storage.config.editor.auto_pairs,
                .smart_deletion = true,
            };

            if (config.enabled and config.smart_deletion) {
                const deleted_pair = try auto_pair.smartBackspace(s);
                if (!deleted_pair) {
                    try self.backspaceCharWithHistory();
                }
            } else {
                try self.backspaceCharWithHistory();
            }
            try self.updateCompletionFilter();
            self.markLspDirty();
        } else if (key.matches(vaxis.Key.delete, .{})) {
            try self.deleteCharWithHistory();
            try self.updateCompletionFilter();
            self.markLspDirty();
        } else if (key.matches(vaxis.Key.enter, .{})) {
            if (s.file_path) |path| {
                if (std.mem.endsWith(u8, path, ".zig")) {
                    try s.insertNewlineWithIndent();
                } else {
                    try s.insertNewline();
                }
            } else {
                try s.insertNewline();
            }
            self.markLspDirty();
        } else if (key.matches(vaxis.Key.tab, .{})) {
            try s.insertTabWithSize(self.storage.config.editor.tab_size);
            self.markLspDirty();
        } else if (key.text) |text| {
            if (text.len == 1) {
                const char = text[0];

                const config = auto_pair.AutoPairConfig{
                    .enabled = self.storage.config.editor.auto_pairs,
                    .wrap_selection = true,
                    .smart_deletion = true,
                    .context_aware = false,
                };

                const result = try auto_pair.handleCharInput(s, char, config);

                switch (result) {
                    .wrapped => {},
                    .skipped => {},
                    .inserted => {
                        if (auto_pair.isOpeningChar(char)) |_| {} else {
                            try self.insertCharWithHistory(char);
                        }
                    },
                }

                if (char == '.' or char == '@') {
                    try self.triggerCompletion();
                }

                try self.updateCompletionFilter();
                self.markLspDirty();
            }
        }
        return true;
    }

    fn triggerCompletion(self: *Core) !void {
        const s = self.state();
        const path = s.file_path orelse return;

        // Route through the canonical LSP language detector — autocomplete
        // is no longer Zig-only. Any language LSPManager can serve is
        // eligible; languages without a running server return gracefully
        // in the dispatcher.
        if (LSPManager.getLangFromPath(path) == null) return;

        try self.ensureLspDocument();
        try self.lsp_manager.requestCompletion(path, @intCast(s.cursor_row), @intCast(s.cursor_col));
        self.completion_pending = true;
        self.completion_prefix_start = s.cursor_col;
    }

    fn dismissCompletion(self: *Core) void {
        self.completion_active = false;
        self.completion_pending = false;
        for (self.completion_items.items) |item| {
            self.allocator.free(item.label);
            if (item.detail) |d| self.allocator.free(d);
        }
        self.completion_items.clearRetainingCapacity();
        self.filtered_completion_items.clearRetainingCapacity();
    }

    fn updateCompletionFilter(self: *Core) !void {
        self.filtered_completion_items.clearRetainingCapacity();
        if (self.completion_items.items.len == 0) return;

        const s = self.state();
        const lines = try s.buffer.getVisibleLines(self.allocator, s.cursor_row, 1);
        defer {
            for (lines) |l| self.allocator.free(l);
            self.allocator.free(lines);
        }
        if (lines.len == 0) return;
        const line_content = lines[0];

        if (self.completion_prefix_start > s.cursor_col) {
            self.dismissCompletion();
            return;
        }

        if (s.cursor_col > line_content.len) {
            self.dismissCompletion();
            return;
        }

        const prefix = line_content[self.completion_prefix_start..s.cursor_col];

        for (self.completion_items.items) |item| {
            if (std.mem.startsWith(u8, item.label, prefix)) {
                try self.filtered_completion_items.append(self.allocator, item);
            }
        }
        self.completion_selected = 0;
    }

    fn confirmCompletion(self: *Core) !void {
        if (!self.completion_active) return;
        if (self.filtered_completion_items.items.len == 0) return;
        if (self.completion_selected >= self.filtered_completion_items.items.len) return;

        const item = self.filtered_completion_items.items[self.completion_selected];

        const s = self.state();
        const prefix_len = s.cursor_col - self.completion_prefix_start;
        if (prefix_len > 0) {
            const start_offset = s.getOffsetFor(s.cursor_row, self.completion_prefix_start);
            try s.buffer.delete(start_offset, prefix_len);
            s.cursor_col = self.completion_prefix_start;
        }

        const insert_offset = s.getOffsetFor(s.cursor_row, s.cursor_col);
        try s.buffer.insert(insert_offset, item.label);
        s.cursor_col += item.label.len;
        s.modified = true;

        try self.sendLspDocChanged();
        self.dismissCompletion();
    }

    fn markLspDirty(self: *Core) void {
        self.lsp_dirty = true;

        self.plugin_manager.broadcastEvent(.buffer_changed, self.buffer_manager.getActive().name);

        self.lsp_debounce_deadline = std.Io.Clock.real.now(self.io).toMilliseconds() + self.lsp_debounce_ms;
    }

    fn processDebouncedLspUpdate(self: *Core) void {
        const now = std.Io.Clock.real.now(self.io).toMilliseconds();

        if (self.lsp_dirty) {
            if (now >= self.lsp_debounce_deadline) {
                self.lsp_dirty = false;
                self.sendLspDocChanged() catch |err| {
                    log.warn("Failed to send debounced LSP doc change: {}", .{err});
                };
            }
        }

        if (self.pending_lsp_refresh_path) |path| {
            if (now - self.last_buffer_switch_time >= self.buffer_switch_debounce_ms) {
                self.ensureLspDocument() catch |err| {
                    log.debug("ensureLspDocument failed: {}", .{err});
                };
                self.allocator.free(path);
                self.pending_lsp_refresh_path = null;
            }
        }
    }

    pub fn sendLspDocChanged(self: *Core) !void {
        const s = self.state();
        if (s.file_path) |path| {
            // Was Zig-only; any language we have an LSP for needs
            // incremental sync so the server's diagnostics / hover /
            // completion stay aligned with the buffer.
            if (LSPManager.getLangFromPath(path) != null) {
                const content = try s.buffer.toString(self.allocator);
                defer self.allocator.free(content);
                self.lsp_doc_version += 1;
                self.lsp_manager.documentChanged(path, content, self.lsp_doc_version) catch |err| {
                    log.debug("LSP document change notification failed: {}", .{err});
                };

                const buf_id = self.buffer_manager.getActive().id;
                self.syntax_manager.parse(content, buf_id) catch |err| {
                    log.debug("Syntax parse failed after edit: {}", .{err});
                };
            }
        }
    }

    fn handleViewInput(self: *Core, key: vaxis.Key) !bool {
        if (self.leader_pending) {
            switch (key.codepoint) {
                Keys.action_save => try self.saveCurrentFile(),
                Keys.action_open => {
                    try self.openFilePicker();
                    self.leader_pending = false;
                },
                Keys.action_buffer => {
                    self.previous_mode = self.mode;
                    self.mode = .buffer_picker;
                    self.buffer_manager.pickerReset();
                    self.buffer_picker_number_input.clearRetainingCapacity();
                    self.leader_pending = false;
                },
                Keys.action_quit => return error.UserQuit,
                Keys.action_close => {
                    if (self.split_manager) |*sm| {
                        if (sm.hasSplits()) {
                            self.syncStateToPane();
                            sm.closePane();
                            self.syncPaneToState();
                            const remaining_pane = sm.getFocusedPane();
                            if (remaining_pane.buffer_index < self.buffer_manager.buffers.items.len) {
                                self.buffer_manager.active_index = remaining_pane.buffer_index;
                            }
                            if (!sm.hasSplits()) {
                                sm.deinit();
                                self.split_manager = null;
                            }
                        } else {
                            const pane = sm.getFocusedPane();
                            if (pane.buffer_index < self.buffer_manager.buffers.items.len) {
                                self.buffer_manager.active_index = pane.buffer_index;
                            }
                            sm.deinit();
                            self.split_manager = null;
                        }
                    } else {
                        _ = self.buffer_manager.closeActive();
                    }
                },
                Keys.action_next => {
                    self.buffer_manager.nextBuffer();
                    self.refreshSyntaxForCurrentBuffer();
                    if (self.split_manager) |*sm| sm.setFocusedBuffer(self.buffer_manager.active_index);
                },
                Keys.action_prev => {
                    self.buffer_manager.prevBuffer();
                    self.refreshSyntaxForCurrentBuffer();
                    if (self.split_manager) |*sm| sm.setFocusedBuffer(self.buffer_manager.active_index);
                },
                Keys.action_help => {
                    try self.openVirtualBuffer("[HELP]", Help.help_text);
                    self.leader_pending = false;
                },
                Keys.action_palette, ':' => {
                    self.previous_mode = self.mode;
                    self.mode = .command_palette;
                    self.command_palette_input.clearRetainingCapacity();
                    self.command_palette_results.clearRetainingCapacity();
                    try self.command_registry.search("", &self.command_palette_results, self.allocator);
                    self.command_palette_selected = 0;
                    self.leader_pending = false;
                },
                Keys.action_undo => try EditCommands.cmdEditUndo(self),
                Keys.action_redo => try EditCommands.cmdEditRedo(self),
                Keys.action_jobs => try SystemCommands.cmdJobList(self),
                Keys.action_copy => try EditCommands.cmdEditCopy(self),
                Keys.action_cut => try EditCommands.cmdEditCut(self),
                Keys.action_paste => try EditCommands.cmdEditPaste(self),

                Keys.action_lsp_definition => try LspCommands.cmdLspGoToDefinition(self),
                Keys.action_lsp_references => try LspCommands.cmdLspFindReferences(self),
                Keys.action_lsp_hover => try LspCommands.cmdLspHover(self),
                Keys.action_lsp_diagnostics => try LspCommands.cmdLspShowDiagnostics(self),

                Keys.action_jump_back => try cmdJumpBack(self, null),
                Keys.action_jump_forward => try cmdJumpForward(self, null),

                vaxis.Key.escape => {
                    self.leader_pending = false;
                },

                Keys.leader => {},

                else => {
                    self.leader_pending = false;
                },
            }
            return true;
        }

        if (key.matches(Keys.leader, .{})) {
            self.leader_pending = true;
            return true;
        }

        if (key.matches(Keys.open.codepoint, Keys.open.mods)) {
            try self.openFilePicker();
            return true;
        }
        if (key.matches(Keys.save.codepoint, Keys.save.mods)) {
            try self.saveCurrentFile();
            return true;
        }

        const s = self.state();
        if (key.matches(vaxis.Key.left, .{}) or key.matches('h', .{})) {
            if (s.cursor_col > 0) s.cursor_col -= 1;
        } else if (key.matches(vaxis.Key.right, .{}) or key.matches('l', .{})) {
            s.cursor_col += 1;
        } else if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
            s.cursor_row += 1;
        } else if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
            if (s.cursor_row > 0) s.cursor_row -= 1;
        } else if (key.matches(vaxis.Key.page_down, .{})) {
            s.cursor_row += 20;
            self.scroll_in_progress = true;
            self.last_scroll_time = std.Io.Clock.real.now(self.io).toMilliseconds();
        } else if (key.matches(vaxis.Key.page_up, .{})) {
            if (s.cursor_row >= 20) {
                s.cursor_row -= 20;
            } else {
                s.cursor_row = 0;
            }
            self.scroll_in_progress = true;
            self.last_scroll_time = std.Io.Clock.real.now(self.io).toMilliseconds();
        } else if (key.matches(vaxis.Key.home, .{})) {
            s.cursor_col = 0;
        } else if (key.matches(vaxis.Key.end, .{})) {
            s.cursor_col = 999;
        }
        return true;
    }

    fn handleTerminalInput(self: *Core, key: vaxis.Key) !void {
        if (key.matches('c', .{ .ctrl = true })) {
            if (self.terminal_running) {
                if (self.terminal_service.cancelCurrentJob()) {
                    try self.terminal_output.appendSlice(self.allocator, "\n^C\n");
                    self.terminal_running = false;
                }
            }
            return;
        }

        if (key.matches(vaxis.Key.enter, .{})) {
            if (self.terminal_input.items.len > 0 and !self.terminal_running) {
                try terminal_proc.executeTerminalCommand(self);
            }
            return;
        }

        if (key.matches(vaxis.Key.up, .{})) {
            if (self.terminal_service.history_index == null and self.terminal_input.items.len > 0) {
                self.terminal_saved_input.clearRetainingCapacity();
                try self.terminal_saved_input.appendSlice(self.allocator, self.terminal_input.items);
            }

            if (self.terminal_service.historyPrevious()) |prev_cmd| {
                self.terminal_input.clearRetainingCapacity();
                try self.terminal_input.appendSlice(self.allocator, prev_cmd);
            }
            return;
        }

        if (key.matches(vaxis.Key.down, .{})) {
            if (self.terminal_service.historyNext()) |next_cmd| {
                self.terminal_input.clearRetainingCapacity();
                try self.terminal_input.appendSlice(self.allocator, next_cmd);
            } else {
                self.terminal_input.clearRetainingCapacity();
                if (self.terminal_saved_input.items.len > 0) {
                    try self.terminal_input.appendSlice(self.allocator, self.terminal_saved_input.items);
                }
            }
            return;
        }

        if (key.matches(vaxis.Key.page_up, .{})) {
            if (self.terminal_scroll_offset >= 10) {
                self.terminal_scroll_offset -= 10;
            } else {
                self.terminal_scroll_offset = 0;
            }
            return;
        }

        if (key.matches(vaxis.Key.page_down, .{})) {
            var total_lines: usize = 0;
            for (self.terminal_output.items) |c| {
                if (c == '\n') total_lines += 1;
            }
            if (self.terminal_output.items.len > 0 and
                self.terminal_output.items[self.terminal_output.items.len - 1] != '\n')
            {
                total_lines += 1;
            }
            const visible_height = if (self.win_size.rows > 2) self.win_size.rows - 2 else 1;
            const max_offset = if (total_lines > visible_height) total_lines - visible_height else 0;
            self.terminal_scroll_offset = @min(self.terminal_scroll_offset + 10, max_offset);
            return;
        }

        if (key.matches(vaxis.Key.tab, .{})) {
            try terminal_proc.completeTerminalInput(self);
            return;
        }

        if (key.matches(vaxis.Key.backspace, .{})) {
            if (self.terminal_input.items.len > 0) {
                _ = self.terminal_input.pop();
                self.terminal_service.resetHistoryNavigation();
            }
            return;
        }

        if (key.text) |text| {
            try self.terminal_input.appendSlice(self.allocator, text);
            self.terminal_service.resetHistoryNavigation();
        }
    }

    fn handleFilePickerInput(self: *Core, key: vaxis.Key) !bool {
        if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
            self.file_manager.moveUp();
            return true;
        }
        if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
            self.file_manager.moveDown();
            return true;
        }
        if (key.matches(vaxis.Key.enter, .{ .shift = true }) or
            key.matches(vaxis.Key.enter, .{ .alt = true }) or
            key.matches('o', .{ .ctrl = true }))
        {
            const selected = self.file_manager.getSelectedEntry();
            if (selected) |entry| {
                if (entry.is_dir) {
                    const dir_path = try std.fs.path.join(self.allocator, &.{ self.file_manager.cwd, entry.name });
                    defer self.allocator.free(dir_path);
                    try self.openAllFilesInDirectory(dir_path);
                    self.mode = .select;
                    return true;
                }
            }
        }
        if (key.matches(vaxis.Key.enter, .{})) {
            if (try self.file_manager.enter()) |file_path| {
                defer self.allocator.free(file_path);
                const opened_buffer = try self.buffer_manager.openFile(file_path);

                try self.workspace_manager.registerBuffer(opened_buffer.id, file_path);

                const lang = SyntaxManager.Language.fromFilename(file_path);

                if (lang == .zig or lang == .python or lang == .javascript or lang == .typescript or lang == .go or lang == .rust) {
                    var project_root_owned: ?[]const u8 = null;
                    defer if (project_root_owned) |p| self.allocator.free(p);

                    const ws_root = if (self.workspace_manager.getBufferWorkspace(opened_buffer.id)) |ws|
                        ws.root_path
                    else blk: {
                        project_root_owned = try self.findProjectRoot(file_path);
                        break :blk if (project_root_owned) |p| p else self.file_manager.cwd;
                    };

                    const lang_id = switch (lang) {
                        .zig => "zig",
                        .python => "python",
                        .javascript => "javascript",
                        .typescript => "typescript",
                        .go => "go",
                        .rust => "rust",
                        else => unreachable,
                    };
                    try self.lsp_manager.startServer(lang_id, ws_root);

                    const content = try self.state().buffer.toString(self.allocator);
                    defer self.allocator.free(content);
                    self.lsp_manager.documentOpened(file_path, content) catch |err| {
                        log.warn("LSP document sync failed after file open '{s}': {}", .{ file_path, err });
                    };
                    self.lsp_doc_version = 1;
                }

                if (lang != .unknown) {
                    self.syntax_manager.setLanguageEnum(lang) catch |err| {
                        log.warn("Syntax manager language set failed for {}: {}", .{ lang, err });
                    };
                    if (self.state().buffer.toString(self.allocator)) |content| {
                        defer self.allocator.free(content);
                        const buf_id = self.buffer_manager.getActive().id;
                        self.syntax_manager.parse(content, buf_id) catch |err| {
                            log.debug("Syntax parse failed after buffer load: {}", .{err});
                        };
                    } else |_| {}
                }

                if (self.split_manager) |*sm| {
                    sm.setFocusedBuffer(self.buffer_manager.active_index);
                }

                self.mode = .select;
            }
            return true;
        }
        if (key.matches(vaxis.Key.backspace, .{})) {
            try self.file_manager.goParent();
            return true;
        }
        return false;
    }

    fn handleBufferPickerInput(self: *Core, key: vaxis.Key) !bool {
        if (key.codepoint >= '0' and key.codepoint <= '9') {
            try self.buffer_picker_number_input.append(self.allocator, @intCast(key.codepoint));
            return true;
        }

        if (key.matches(vaxis.Key.backspace, .{})) {
            if (self.buffer_picker_number_input.items.len > 0) {
                _ = self.buffer_picker_number_input.pop();
                return true;
            }
            return false;
        }

        if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
            self.buffer_picker_number_input.clearRetainingCapacity();
            self.buffer_manager.pickerMoveUp();
            return true;
        }
        if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
            self.buffer_picker_number_input.clearRetainingCapacity();
            self.buffer_manager.pickerMoveDown();
            return true;
        }

        if (key.matches(vaxis.Key.enter, .{})) {
            if (self.buffer_picker_number_input.items.len > 0) {
                const num_str = self.buffer_picker_number_input.items;
                const buf_num = std.fmt.parseInt(usize, num_str, 10) catch 0;
                self.buffer_picker_number_input.clearRetainingCapacity();

                if (buf_num > 0 and buf_num <= self.buffer_manager.buffers.items.len) {
                    self.buffer_manager.switchTo(buf_num - 1);
                    self.notifyBufferSwitched();
                    self.refreshSyntaxForCurrentBuffer();
                    if (self.split_manager) |*sm| {
                        sm.setFocusedBuffer(self.buffer_manager.active_index);
                    }
                }
            } else {
                self.buffer_manager.pickerSelect();
                self.notifyBufferSwitched();
                self.refreshSyntaxForCurrentBuffer();
                if (self.split_manager) |*sm| {
                    sm.setFocusedBuffer(self.buffer_manager.active_index);
                }
            }
            self.mode = .select;
            return true;
        }

        return false;
    }

    fn handleSaveAsInput(self: *Core, key: vaxis.Key) !bool {
        if (key.matches(vaxis.Key.enter, .{})) {
            if (self.save_as_input.items.len > 0) {
                const filename = try self.allocator.dupe(u8, self.save_as_input.items);
                defer self.allocator.free(filename);

                const full_path = if (std.fs.path.isAbsolute(filename))
                    try self.allocator.dupe(u8, filename)
                else
                    try std.fs.path.join(self.allocator, &.{ self.file_manager.cwd, filename });
                defer self.allocator.free(full_path);

                try self.state().saveFileAs(full_path);

                const active_buf = self.buffer_manager.getActive();
                self.allocator.free(active_buf.name);
                active_buf.name = try self.allocator.dupe(u8, std.fs.path.basename(full_path));
                if (active_buf.file_path) |old| self.allocator.free(old);
                active_buf.file_path = try self.allocator.dupe(u8, full_path);

                // Save-as: spin up the LSP for the new file's language if
                // there is one. Was a hand-rolled 5-language ladder; now
                // delegates to the canonical detector.
                if (LSPManager.getLangFromPath(full_path)) |lang_id| {
                    const project_root = try self.findProjectRoot(full_path);
                    defer if (project_root) |p| self.allocator.free(p);

                    const root = if (project_root) |p| p else self.file_manager.cwd;
                    try self.lsp_manager.startServer(lang_id, root);

                    const content = try self.state().buffer.toString(self.allocator);
                    defer self.allocator.free(content);
                    self.lsp_manager.documentOpened(full_path, content) catch |err| {
                        log.warn("LSP document sync failed in save-as '{s}': {}", .{ full_path, err });
                    };
                    self.lsp_doc_version = 1;
                }

                self.mode = .select;
                self.save_as_input.clearRetainingCapacity();
            }
            return true;
        } else if (key.matches(vaxis.Key.backspace, .{})) {
            if (self.save_as_input.items.len > 0) {
                _ = self.save_as_input.pop();
                return true;
            }
        } else if (key.text) |text| {
            try self.save_as_input.appendSlice(self.allocator, text);
            return true;
        }
        return false;
    }

    pub fn openFilePicker(self: *Core) !void {
        self.previous_mode = self.mode;
        self.mode = .file_picker;
        try self.file_manager.refresh();
    }

    /// Opens all files in the given directory recursively. The walk runs on
    /// a background worker thread so the editor remains responsive even on
    /// projects with thousands of files. As paths are discovered, the worker
    /// pushes them onto `scan_paths`; the core thread's tick handler drains
    /// the queue and adds them as lazy buffers without changing the active
    /// buffer.
    pub fn openAllFilesInDirectory(self: *Core, dir_path: []const u8) !void {
        const owned_path = try self.allocator.dupe(u8, dir_path);
        errdefer self.allocator.free(owned_path);

        _ = self.scan_workers_running.fetchAdd(1, .release);
        const t = std.Thread.spawn(.{}, scanWorkerEntry, .{ self, owned_path }) catch |err| {
            _ = self.scan_workers_running.fetchSub(1, .release);
            self.allocator.free(owned_path);
            return err;
        };
        t.detach();
    }

    /// Thread entry: take ownership of `dir_path`, walk it, then signal exit.
    fn scanWorkerEntry(self: *Core, dir_path: []u8) void {
        defer {
            self.allocator.free(dir_path);
            _ = self.scan_workers_running.fetchSub(1, .release);
        }
        self.scanDirectoryRec(dir_path, 0) catch |err| {
            log.warn("Background dir scan failed for '{s}': {}", .{ dir_path, err });
        };
    }

    /// Worker-side recursive walk. Pushes discovered file paths onto
    /// `scan_paths` (under mutex) for the core thread to consume. Caps the
    /// total at `max_files` across the whole scan.
    fn scanDirectoryRec(self: *Core, dir_path: []const u8, depth: u8) !void {
        if (self.scan_shutdown.load(.acquire)) return;

        const max_depth: u8 = 32;
        if (depth > max_depth) return;

        const skip_dirs = [_][]const u8{ ".git", "node_modules", "zig-cache", ".zig-cache", "target", "__pycache__", ".venv", "venv", "build", "dist" };
        const max_files: usize = 1000;

        var dir = std.Io.Dir.openDirAbsolute(self.io, dir_path, .{ .iterate = true }) catch return;
        defer dir.close(self.io);

        var iter = dir.iterate();
        while (iter.next(self.io) catch null) |entry| {
            if (self.scan_shutdown.load(.acquire)) return;

            self.scan_paths_mutex.lockUncancelable(self.io);
            const reached_limit = self.scan_paths.items.len + self.buffer_manager.buffers.items.len >= max_files;
            self.scan_paths_mutex.unlock(self.io);
            if (reached_limit) return;

            if (entry.kind == .sym_link) continue;

            const full_path = std.fs.path.join(self.allocator, &.{ dir_path, entry.name }) catch continue;
            defer self.allocator.free(full_path);

            if (entry.kind == .directory) {
                if (entry.name.len > 0 and entry.name[0] == '.') continue;
                var should_skip = false;
                for (skip_dirs) |skip| {
                    if (std.mem.eql(u8, entry.name, skip)) {
                        should_skip = true;
                        break;
                    }
                }
                if (!should_skip) {
                    self.scanDirectoryRec(full_path, depth + 1) catch {};
                }
            } else if (entry.kind == .file) {
                if (!filetype.isOpenable(full_path)) {
                    self.scan_paths_mutex.lockUncancelable(self.io);
                    self.scan_skipped_count += 1;
                    self.scan_paths_mutex.unlock(self.io);
                    continue;
                }
                const owned = self.allocator.dupe(u8, full_path) catch continue;
                self.scan_paths_mutex.lockUncancelable(self.io);
                self.scan_paths.append(self.allocator, owned) catch {
                    self.allocator.free(owned);
                };
                self.scan_paths_mutex.unlock(self.io);
            }
        }
    }

    /// Drain the worker-discovered paths into the buffer list. Called from
    /// the core thread's tick handler so it's safe to mutate
    /// `buffer_manager`. Bounded per-tick so a giant scan can't monopolize
    /// the main loop.
    fn drainScanPaths(self: *Core) void {
        const max_per_tick: usize = 64;

        self.scan_paths_mutex.lockUncancelable(self.io);
        const take = @min(self.scan_paths.items.len, max_per_tick);
        var batch: [64][]u8 = undefined;
        for (0..take) |i| batch[i] = self.scan_paths.items[i];
        if (take > 0) self.scan_paths.replaceRange(self.allocator, 0, take, &.{}) catch {};
        const skipped = self.scan_skipped_count;
        if (take > 0) self.scan_skipped_count = 0;
        self.scan_paths_mutex.unlock(self.io);

        if (take == 0) return;
        var added_any = false;
        for (batch[0..take]) |p| {
            defer self.allocator.free(p);
            self.buffer_manager.addFileLazyBackground(p) catch |err| {
                log.debug("scan drain: addFileLazyBackground failed for '{s}': {}", .{ p, err });
                continue;
            };
            self.workspace_manager.registerBuffer(0, p) catch {};
            added_any = true;
        }

        if (skipped > 0 and self.status_message == null) {
            const msg = std.fmt.bufPrint(
                &self.skip_status_buf,
                "Skipped {d} unsupported file{s} in scan",
                .{ skipped, if (skipped == 1) "" else "s" },
            ) catch null;
            if (msg) |m| {
                self.status_message = m;
                self.status_message_expires = std.Io.Clock.real.now(self.io).toMilliseconds() + 4000;
            }
        }

        // A new batch of buffers is in the picker; ask the UI to redraw so
        // the file picker (and buffer list) reflect the change.
        if (added_any) self.sendUpdate() catch {};
    }

    /// Block briefly waiting for any in-flight scan workers to exit. Called
    /// from `deinit`. Workers respect `scan_shutdown` and will bail out of
    /// their dir-iterate loop within a couple of `iterate()` returns.
    fn waitForScanWorkers(self: *Core) void {
        self.scan_shutdown.store(true, .release);
        const deadline_ms = std.Io.Clock.real.now(self.io).toMilliseconds() + 2000;
        while (self.scan_workers_running.load(.acquire) > 0) {
            if (std.Io.Clock.real.now(self.io).toMilliseconds() >= deadline_ms) {
                log.warn("scan workers did not exit in 2s; detaching", .{});
                break;
            }
            std.Io.sleep(self.io, .fromMilliseconds(20), .awake) catch break;
        }
    }

    /// For every language we have a buffer open in, queue a `start_server`
    /// command on the LSP supervisor. The supervisor processes them in the
    /// background — the UI doesn't wait. By the time the user navigates to
    /// the file, the server is usually already initialized.
    /// Queue a `documentOpened` for the active buffer if it has a path and a
    /// recognized language. Failures are swallowed because this is a
    /// best-effort warmup — the user's first explicit interaction with the
    /// LSP will retry through `ensureLspDocument`.
    /// If enough time has passed, write a recovery copy of every modified
    /// buffer to `~/.stem/recover/<hash>.bak`. Atomic (temp + rename) so a
    /// crash during the write itself doesn't corrupt the recovery file.
    /// Runs on the core thread so no buffer-mutex is needed; the write
    /// itself is fast for the dirty-buffer size we expect.
    /// Schedule a render for the next tick. Coalesces multiple state
    /// changes within the same tick into a single `sendUpdate` call. Use
    /// this instead of `try sendUpdate()` for non-urgent updates — anything
    /// the user wouldn't notice a 100 ms delay on (LSP results popping in,
    /// status-bar changes, background scans). Reserve direct `sendUpdate`
    /// for events that need immediate redraw (resize, explicit input).
    pub fn requestRender(self: *Core) void {
        self.needs_render = true;
    }

    fn maybeAutosave(self: *Core) void {
        const now = std.Io.Clock.real.now(self.io).toMilliseconds();
        if (now - self.last_autosave_ms < self.autosave_interval_ms) return;
        self.last_autosave_ms = now;

        const home_dir = self.homeDir() catch return;
        defer self.allocator.free(home_dir);

        const recover_dir = std.fs.path.join(self.allocator, &.{ home_dir, ".stem", "recover" }) catch return;
        defer self.allocator.free(recover_dir);

        // Best-effort create — if the dir already exists or we lack
        // permission, autosave silently no-ops for this tick.
        std.Io.Dir.cwd().createDirPath(self.io, recover_dir) catch return;

        for (self.buffer_manager.buffers.items) |*buf| {
            if (!buf.state.modified) continue;
            const path = buf.file_path orelse continue;

            // Hash the path so recovery filenames are short and collision-
            // resistant. Sidecar `.path` file records the original path so
            // the user can match a recovery file back to its source.
            var h = std.hash.Wyhash.init(0);
            h.update(path);
            const hash_u64 = h.final();

            const bak_name = std.fmt.allocPrint(self.allocator, "{x:0>16}.bak", .{hash_u64}) catch continue;
            defer self.allocator.free(bak_name);
            const bak_path = std.fs.path.join(self.allocator, &.{ recover_dir, bak_name }) catch continue;
            defer self.allocator.free(bak_path);

            const content = buf.state.buffer.toString(self.allocator) catch continue;
            defer self.allocator.free(content);

            self.writeRecoveryFile(bak_path, content) catch |err| {
                log.debug("autosave: failed to write {s}: {}", .{ bak_path, err });
                continue;
            };

            // Sidecar with the original file path. Tiny so we don't bother
            // hashing or atomic-writing it.
            const sidecar = std.fmt.allocPrint(self.allocator, "{s}.path", .{bak_path}) catch continue;
            defer self.allocator.free(sidecar);
            var sf = std.Io.Dir.createFileAbsolute(self.io, sidecar, .{}) catch continue;
            defer sf.close(self.io);
            sf.writeStreamingAll(self.io, path) catch {};
        }
    }

    /// Stat the active buffer's file; if its mtime moved forward since we
    /// last touched it, the file was modified externally (formatter, git
    /// checkout, another editor, etc.). Show a status message. Update the
    /// baseline so we don't re-warn for the same change.
    fn maybeCheckExternalChange(self: *Core) void {
        const now = std.Io.Clock.real.now(self.io).toMilliseconds();
        if (now - self.last_extwatch_ms < self.extwatch_interval_ms) return;
        self.last_extwatch_ms = now;

        const buf = self.buffer_manager.getActive();
        const path = buf.file_path orelse return;
        if (buf.last_disk_mtime_ns == 0) return; // never loaded a baseline

        const file = std.Io.Dir.openFileAbsolute(self.io, path, .{}) catch return;
        defer file.close(self.io);
        const st = file.stat(self.io) catch return;
        const cur_ns = st.mtime.toNanoseconds();

        if (cur_ns == buf.last_disk_mtime_ns) return;
        // Update baseline so we don't re-warn on every tick.
        buf.last_disk_mtime_ns = cur_ns;

        const basename = std.fs.path.basename(path);
        const msg = if (buf.state.modified)
            std.fmt.bufPrint(&self.skip_status_buf, "WARNING: '{s}' changed on disk while you have unsaved edits", .{basename}) catch return
        else
            std.fmt.bufPrint(&self.skip_status_buf, "'{s}' changed on disk \u{2014} :e! to reload", .{basename}) catch return;
        self.status_message = msg;
        self.status_message_expires = now + 5_000;
    }

    fn writeRecoveryFile(self: *Core, path: []const u8, content: []const u8) !void {
        // Atomic write: temp + rename so a crash mid-write doesn't leave a
        // truncated recovery file (which would be worse than no recovery).
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{path});
        defer self.allocator.free(tmp_path);

        {
            var tmp_file = try std.Io.Dir.createFileAbsolute(self.io, tmp_path, .{});
            errdefer std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};
            defer tmp_file.close(self.io);
            try tmp_file.writePositionalAll(self.io, content, 0);
        }
        std.Io.Dir.renameAbsolute(tmp_path, path, self.io) catch |err| {
            std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};
            return err;
        };
    }

    fn homeDir(self: *Core) ![]u8 {
        const env: std.process.Environ = .{ .block = self.environ_block };
        if (env.getPosix("HOME")) |h| return self.allocator.dupe(u8, h);
        return error.HomeNotFound;
    }

    fn eagerlyOpenActiveBuffer(self: *Core) void {
        const s = self.state();
        const path = s.file_path orelse return;
        _ = LSPManager.getLangFromPath(path) orelse return;

        const content = s.buffer.toString(self.allocator) catch return;
        defer self.allocator.free(content);
        self.lsp_manager.documentOpened(path, content) catch |err| {
            std.log.warn("[LSP WARMUP] documentOpened failed: {}", .{err});
        };
    }

    fn prespawnLSPs(self: *Core) !void {
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(self.allocator);

        // Build the order: active buffer's lang FIRST (so it starts before
        // anything else), then every other detected language. This matters
        // because the queue is processed in order — the active file's LSP
        // begins initializing before we even queue the others, which start
        // in parallel threads.
        const Spawn = struct { path: []const u8, lang: []const u8 };
        var queue: std.ArrayListUnmanaged(Spawn) = .empty;
        defer queue.deinit(self.allocator);

        const active = self.buffer_manager.getActive();
        if (active.file_path) |p| {
            if (LSPManager.getLangFromPath(p)) |l| {
                try queue.append(self.allocator, .{ .path = p, .lang = l });
                _ = try seen.getOrPut(self.allocator, l);
            }
        }

        for (self.buffer_manager.buffers.items) |buf| {
            const path = buf.file_path orelse continue;
            const lang = LSPManager.getLangFromPath(path) orelse continue;
            const gop = try seen.getOrPut(self.allocator, lang);
            if (gop.found_existing) continue;
            try queue.append(self.allocator, .{ .path = path, .lang = lang });
        }

        for (queue.items) |item| {
            // Use the proper project root (walks up to build.zig / go.mod /
            // pyproject.toml / etc.) so the server's initial indexing covers
            // the whole project. Otherwise ZLS would index just one file's
            // directory and then have to re-scan when the user opens a file
            // from a sibling directory.
            const root = self.lsp_manager.findProjectRoot(item.path, item.lang) catch {
                continue;
            };
            defer self.allocator.free(root);

            std.log.info("[LSP PRESPAWN] queuing start for lang={s} root={s}", .{ item.lang, root });
            self.lsp_manager.startServer(item.lang, root) catch |err| {
                std.log.warn("[LSP PRESPAWN] enqueue failed for {s}: {}", .{ item.lang, err });
            };
        }
    }

    pub fn saveCurrentFile(self: *Core) !void {
        const s = self.state();
        if (s.file_path) |path| {
            if (std.mem.endsWith(u8, path, ".zig")) {
                try self.formatAndSave();
            } else {
                try s.saveFile();
            }
        } else {
            self.previous_mode = self.mode;
            self.mode = .save_as_mode;
            self.save_as_input.clearRetainingCapacity();
        }
    }

    fn formatAndSave(self: *Core) !void {
        const s = self.state();
        const path = s.file_path orelse return;

        try self.ensureLspDocument();
        try self.lsp_manager.requestFormatting(path);

        var attempts: usize = 0;
        while (attempts < 10) : (attempts += 1) {
            if (self.lsp_manager.popFormatResult()) |edits| {
                defer {
                    for (edits) |e| {
                        self.allocator.free(e.new_text);
                    }
                    self.allocator.free(edits);
                }

                const sorted_edits = try self.allocator.alloc(@TypeOf(edits[0]), edits.len);
                defer self.allocator.free(sorted_edits);
                @memcpy(sorted_edits, edits);

                // The LSP spec doesn't require text edits to be sorted, but
                // applying them in reverse order is only correct if they are
                // sorted ascending. tsserver / pyright / rust-analyzer have
                // all been observed returning unsorted edits. Sort by
                // (start_line, start_col) ascending; we then iterate in
                // reverse so earlier edits don't shift later offsets.
                const Edit = @TypeOf(edits[0]);
                std.mem.sort(Edit, sorted_edits, {}, struct {
                    fn lt(_: void, a: Edit, b: Edit) bool {
                        if (a.start_line != b.start_line) return a.start_line < b.start_line;
                        return a.start_col < b.start_col;
                    }
                }.lt);

                var i: usize = sorted_edits.len;
                while (i > 0) {
                    i -= 1;
                    const edit = sorted_edits[i];
                    const start_off = s.getOffsetFor(edit.start_line, edit.start_col);
                    const end_off = s.getOffsetFor(edit.end_line, edit.end_col);

                    if (end_off > start_off) {
                        try s.buffer.delete(start_off, end_off - start_off);
                    }

                    try s.buffer.insert(start_off, edit.new_text);
                }

                break;
            }

            // best-effort: sleep cancellation is fine, loop will check condition again
            std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(10), .real) catch {};
        }

        try s.saveFile();

        self.lsp_manager.documentSaved(path) catch |err| {
            log.warn("LSP save notification failed for '{s}': {}", .{ path, err });
        };
    }

    pub fn sendUpdate(self: *Core) !void {
        const now = std.Io.Clock.real.now(self.io).toMilliseconds();
        self.last_render_time = now;
        self.needs_render = false;

        if (self.scroll_in_progress and self.last_scroll_time > 0) {
            if (now - self.last_scroll_time > self.scroll_timeout_ms) {
                self.scroll_in_progress = false;
            }
        }

        defer self.scroll_in_progress = false;

        self.version += 1;

        // Pool the arena across frames so we don't bounce pages in and out
        // of the process at the render cadence.
        const arena = try self.arena_pool.acquire();
        errdefer self.arena_pool.release(arena);
        const alloc = arena.allocator();

        if (self.mode == .buffer_picker) {
            const picker_visible_rows = if (self.win_size.rows > 5) self.win_size.rows - 5 else 1;
            if (self.buffer_manager.picker_selected < self.buffer_manager.picker_scroll_offset) {
                self.buffer_manager.picker_scroll_offset = self.buffer_manager.picker_selected;
            } else if (self.buffer_manager.picker_selected >= self.buffer_manager.picker_scroll_offset + picker_visible_rows) {
                self.buffer_manager.picker_scroll_offset = self.buffer_manager.picker_selected - picker_visible_rows + 1;
            }
        }

        const s = self.state();

        var visible_rows: usize = if (self.win_size.rows > 2) self.win_size.rows - 2 else 1;
        if (self.split_manager) |*sm| {
            if (sm.getAllPaneBounds(alloc, .{
                .cols = self.win_size.cols,
                .rows = self.win_size.rows,
            })) |bounds| {
                for (bounds.items) |pane_bound| {
                    if (pane_bound.pane.id == sm.focused_pane_id) {
                        visible_rows = if (pane_bound.height > 2) pane_bound.height - 1 else 1;
                        break;
                    }
                }
            } else |_| {}
        }

        if (s.cursor_row < s.scroll_offset) {
            s.scroll_offset = s.cursor_row;
        } else if (s.cursor_row >= s.scroll_offset + visible_rows) {
            s.scroll_offset = s.cursor_row - visible_rows + 1;
        }

        if (self.split_manager) |*sm| {
            if (sm.sync_scroll) {
                sm.setAllPanesScrollOffset(s.scroll_offset);
            }
        }

        self.syncStateToPane();

        const visible_lines = try s.buffer.getVisibleLines(alloc, s.scroll_offset, visible_rows + 5);

        const terminal_input_slice = if (self.terminal_input.items.len > 0)
            try alloc.dupe(u8, self.terminal_input.items)
        else
            null;

        const terminal_output_slice = if (self.terminal_output.items.len > 0)
            try alloc.dupe(u8, self.terminal_output.items)
        else
            null;

        const save_as_input_slice = if (self.mode == .save_as_mode) try alloc.dupe(u8, self.save_as_input.items) else null;
        const search_input_slice = if (self.mode == .visual_search) try alloc.dupe(u8, self.search_input.items) else null;
        const command_palette_query_slice = if (self.mode == .command_palette) try alloc.dupe(u8, self.command_palette_input.items) else null;
        const go_to_line_input_slice = if (self.mode == .go_to_line) try alloc.dupe(u8, self.go_to_line_input.items) else null;
        const symbol_picker_query_slice = if (self.mode == .symbol_picker) try alloc.dupe(u8, self.symbol_picker_query.items) else null;

        var logs_slice: ?[]const protocol.LogEntry = null;
        if (self.mode == .log_view) {
            if (logger_service.getGlobal()) |l| {
                const entries = try l.getEntries(alloc);
                const proto_entries = try alloc.alloc(protocol.LogEntry, entries.len);
                for (entries, 0..) |e, i| {
                    proto_entries[i] = .{
                        .timestamp = e.timestamp,
                        .level = e.level,
                        .scope = e.scope,
                        .message = e.message,
                    };
                }
                logs_slice = proto_entries;
            }
        }

        var command_palette_results: ?[]const protocol.CommandEntry = null;
        if (self.mode == .command_palette) {
            const entries = try alloc.alloc(protocol.CommandEntry, self.command_palette_results.items.len);
            for (self.command_palette_results.items, 0..) |cmd, i| {
                entries[i] = .{ .id = try alloc.dupe(u8, cmd.id), .title = try alloc.dupe(u8, cmd.title), .description = try alloc.dupe(u8, cmd.description) };
            }
            command_palette_results = entries;
        }

        var picker_entries: ?[]const protocol.DirEntry = null;
        var file_picker_cwd: ?[]const u8 = null;
        if (self.mode == .file_picker or self.mode == .terminal) {
            file_picker_cwd = try alloc.dupe(u8, self.file_manager.cwd);
            if (self.mode == .file_picker and self.file_manager.entries.items.len > 0) {
                const entries = try alloc.alloc(protocol.DirEntry, self.file_manager.entries.items.len);
                for (self.file_manager.entries.items, 0..) |entry, i| {
                    entries[i] = .{ .name = try alloc.dupe(u8, entry.name), .is_dir = entry.is_dir };
                }
                picker_entries = entries;
            }
        }

        const buffer_infos = try alloc.alloc(protocol.BufferInfo, self.buffer_manager.buffers.items.len);
        for (self.buffer_manager.buffers.items, 0..) |buf, i| {
            buffer_infos[i] = .{
                .id = buf.id,
                .name = try alloc.dupe(u8, buf.name),
                .modified = buf.state.modified,
                .is_active = i == self.buffer_manager.active_index,
            };
        }

        var syntax_tokens: ?[]const protocol.SyntaxToken = null;

        var lang = SyntaxManager.Language.unknown;
        if (s.file_path) |path| {
            lang = SyntaxManager.Language.fromFilename(path);
        } else {
            lang = SyntaxManager.Language.fromFilename(self.buffer_manager.getActive().name);
        }

        if (lang != .unknown) {
            if (!self.scroll_in_progress) {
                const active_buffer_id = self.buffer_manager.getActive().id;
                const needs_reparse = (self.syntax_manager.current_lang != lang) or
                    (self.syntax_manager.current_resource_id != active_buffer_id) or
                    (self.syntax_manager.tree == null);

                if (needs_reparse) {
                    if (self.syntax_manager.current_lang != lang) {
                        self.syntax_manager.setLanguageEnum(lang) catch |err| {
                            log.warn("Failed to set syntax language to {}: {}", .{ lang, err });
                        };
                    }
                    if (s.buffer.toString(alloc)) |content| {
                        self.syntax_manager.parse(content, active_buffer_id) catch |err| {
                            log.debug("Syntax reparse failed for active buffer: {}", .{err});
                        };
                    } else |_| {}
                }
            } else {
                const active_buffer_id = self.buffer_manager.getActive().id;
                if (self.syntax_manager.tree == null or self.syntax_manager.current_lang != lang) {
                    if (self.syntax_manager.current_lang != lang) {
                        self.syntax_manager.setLanguageEnum(lang) catch |err| {
                            log.warn("Failed to set syntax language to {}: {}", .{ lang, err });
                        };
                    }
                    if (s.buffer.toString(alloc)) |content| {
                        self.syntax_manager.parse(content, active_buffer_id) catch |err| {
                            log.debug("Syntax parse during scroll failed: {}", .{err});
                        };
                    } else |_| {}
                }
            }

            // Use LSP semantic tokens for any language whose LSP is wired.
            // Tree-sitter is still the fallback when no LSP tokens are
            // available yet (cold start, server not installed, etc.).
            const use_lsp = if (s.file_path != null) switch (lang) {
                .zig, .c, .cpp, .rust, .go, .python, .javascript, .typescript, .tsx, .java, .ruby, .csharp => true,
                else => false,
            } else false;

            if (use_lsp) {
                if (self.lsp_manager.copyVisibleTokens(alloc, s.file_path.?, s.scroll_offset, s.scroll_offset + visible_rows + 5)) |tokens| {
                    syntax_tokens = tokens;
                } else |_| {
                    syntax_tokens = null;
                }
            }

            if (!self.scroll_in_progress) {
                if (syntax_tokens == null or syntax_tokens.?.len == 0) {
                    if (lang == .markdown) {
                        if (s.buffer.toString(alloc)) |content| {
                            syntax_tokens = self.syntax_manager.highlightMarkdown(alloc, content, s.scroll_offset, s.scroll_offset + visible_rows + 5) catch null;
                        } else |_| {}
                    } else {
                        syntax_tokens = self.syntax_manager.highlight(alloc, s.scroll_offset, s.scroll_offset + visible_rows + 5) catch null;
                    }
                }

                if (lang != .markdown and lang != .unknown) {
                    if (s.buffer.toString(alloc)) |content| {
                        if (self.syntax_manager.findBrackets(alloc, content, s.scroll_offset, s.scroll_offset + visible_rows + 5)) |bracket_tokens| {
                            if (bracket_tokens.len > 0) {
                                const existing = syntax_tokens orelse &.{};
                                const merged = alloc.alloc(protocol.SyntaxToken, existing.len + bracket_tokens.len) catch null;
                                if (merged) |m| {
                                    @memcpy(m[0..existing.len], existing);
                                    @memcpy(m[existing.len..], bracket_tokens);
                                    syntax_tokens = m;
                                }
                            }
                        } else |_| {}
                    } else |_| {}
                }

                const lsp_count = if (use_lsp and syntax_tokens != null) syntax_tokens.?.len else 0;
                log.debug("sendUpdate: lang={s}, tree={s}, query={s}, tokens={}", .{
                    @tagName(lang),
                    if (self.syntax_manager.tree != null) "valid" else "NULL",
                    if (self.syntax_manager.query != null) "valid" else "NULL",
                    if (syntax_tokens) |t| t.len else 0,
                });
                _ = lsp_count;
            }
        }

        var symbol_picker_results: ?[]const protocol.SymbolEntry = null;
        if (self.mode == .symbol_picker) {
            const entries = try alloc.alloc(protocol.SymbolEntry, self.symbol_picker_results.items.len);
            for (self.symbol_picker_results.items, 0..) |sym, i| {
                entries[i] = .{ .name = try alloc.dupe(u8, sym.name), .kind = try alloc.dupe(u8, sym.kind), .line = sym.line };
            }
            symbol_picker_results = entries;
        }

        var completion_items: ?[]const protocol.CompletionEntry = null;
        if (self.completion_active and self.filtered_completion_items.items.len > 0) {
            const entries = try alloc.alloc(protocol.CompletionEntry, self.filtered_completion_items.items.len);
            for (self.filtered_completion_items.items, 0..) |item, i| {
                entries[i] = .{
                    .label = try alloc.dupe(u8, item.label),
                    .kind = try alloc.dupe(u8, item.kind_icon),
                    .detail = if (item.detail) |d| try alloc.dupe(u8, d) else "",
                    .kind_category = item.kind_category,
                };
            }
            completion_items = entries;
        }

        var hover_content: ?[]const u8 = null;
        if (self.hover_content) |h| hover_content = try alloc.dupe(u8, h);

        var file_path_slice: ?[]const u8 = null;
        if (s.file_path) |p| file_path_slice = try alloc.dupe(u8, p);

        var pane_snapshots: []const protocol.PaneSnapshot = &.{};
        var split_enabled = false;
        var focused_pane_id: u32 = 0;

        if (self.split_manager) |*sm| {
            const content_rows = if (self.win_size.rows > 1) self.win_size.rows - 1 else 1;
            const params = protocol.RenderParams{ .rows = content_rows, .cols = self.win_size.cols };
            var bounds_list = try sm.getAllPaneBounds(alloc, params);
            defer bounds_list.deinit(alloc);
            const bounds = bounds_list.items;
            if (bounds.len > 0) {
                split_enabled = true;
                focused_pane_id = sm.getFocusedPaneId();

                const panes = try alloc.alloc(protocol.PaneSnapshot, bounds.len);
                for (bounds, 0..) |b, i| {
                    if (b.pane.buffer_index >= self.buffer_manager.buffers.items.len) continue;
                    const pane_buffer = &self.buffer_manager.buffers.items[b.pane.buffer_index];
                    const p_state = &pane_buffer.state;

                    const pane_ptr = sm.getPaneById(b.pane.id);
                    const pane_scroll = if (pane_ptr) |p| p.scroll_offset else p_state.scroll_offset;
                    const pane_cursor_row = if (pane_ptr) |p| p.cursor_row else p_state.cursor_row;
                    const pane_cursor_col = if (pane_ptr) |p| p.cursor_col else p_state.cursor_col;
                    const pane_sel_row = if (pane_ptr) |p| p.selection_anchor_row else if (p_state.selection_anchor) |a| a.row else null;
                    const pane_sel_col = if (pane_ptr) |p| p.selection_anchor_col else if (p_state.selection_anchor) |a| a.col else null;

                    const pane_rows: usize = if (b.height > 1) b.height - 1 else 1;
                    const safe_pane_rows = if (pane_rows < 1) 1 else pane_rows;

                    const pane_lines = try p_state.buffer.getVisibleLines(alloc, pane_scroll, safe_pane_rows + 1);

                    var pane_tokens: ?[]const protocol.SyntaxToken = null;

                    var pane_lang = SyntaxManager.Language.unknown;
                    if (p_state.file_path) |path| {
                        pane_lang = SyntaxManager.Language.fromFilename(path);
                    } else {
                        pane_lang = SyntaxManager.Language.fromFilename(pane_buffer.name);
                    }

                    if (pane_lang != .unknown) {
                        if (!self.scroll_in_progress) {
                            const pane_buffer_id = pane_buffer.id;
                            if (self.syntax_manager.current_lang != pane_lang or self.syntax_manager.current_resource_id != pane_buffer_id) {
                                if (self.syntax_manager.current_lang != pane_lang) {
                                    self.syntax_manager.setLanguageEnum(pane_lang) catch |err| {
                                        log.warn("Failed to set pane syntax language to {}: {}", .{ pane_lang, err });
                                    };
                                }
                                if (p_state.buffer.toString(alloc)) |content| {
                                    self.syntax_manager.parse(content, pane_buffer_id) catch |err| {
                                        log.debug("Pane syntax parse failed: {}", .{err});
                                    };
                                } else |_| {}
                            }
                        }

                        const use_lsp = if (p_state.file_path != null) switch (pane_lang) {
                            .zig, .c, .cpp, .rust, .go, .python, .javascript, .typescript, .tsx, .java, .ruby, .csharp => true,
                            else => false,
                        } else false;
                        if (use_lsp) {
                            if (self.lsp_manager.copyVisibleTokens(alloc, p_state.file_path.?, pane_scroll, pane_scroll + safe_pane_rows + 5)) |tokens| {
                                pane_tokens = tokens;
                            } else |_| {
                                pane_tokens = null;
                            }
                        }

                        if (!self.scroll_in_progress) {
                            if (pane_tokens == null or pane_tokens.?.len == 0) {
                                if (pane_lang == .markdown) {
                                    if (p_state.buffer.toString(alloc)) |content| {
                                        pane_tokens = self.syntax_manager.highlightMarkdown(alloc, content, pane_scroll, pane_scroll + safe_pane_rows + 5) catch null;
                                    } else |_| {}
                                } else {
                                    pane_tokens = self.syntax_manager.highlight(alloc, pane_scroll, pane_scroll + safe_pane_rows + 5) catch null;
                                }
                            }
                        }
                    }

                    panes[i] = .{
                        .id = b.pane.id,
                        .buffer_index = b.pane.buffer_index,
                        .is_focused = b.pane.id == focused_pane_id,
                        .x = @as(f32, @floatFromInt(b.x)) / @as(f32, @floatFromInt(self.win_size.cols)),
                        .y = @as(f32, @floatFromInt(b.y)) / @as(f32, @floatFromInt(content_rows)),
                        .width = @as(f32, @floatFromInt(b.width)) / @as(f32, @floatFromInt(self.win_size.cols)),
                        .height = @as(f32, @floatFromInt(b.height)) / @as(f32, @floatFromInt(content_rows)),
                        .cursor_row = pane_cursor_row,
                        .cursor_col = pane_cursor_col,
                        .scroll_offset = pane_scroll,
                        .selection_anchor_row = pane_sel_row,
                        .selection_anchor_col = pane_sel_col,
                        .visible_lines = pane_lines,
                        .syntax_tokens = pane_tokens,
                        .total_lines = p_state.buffer.lineCount(),
                        .diff_highlights = if (self.diff_highlights.items.len > 0)
                            try alloc.dupe(protocol.DiffLineHighlight, self.diff_highlights.items)
                        else
                            null,
                    };
                }
                pane_snapshots = panes;
            }
        }

        const snapshot = try alloc.create(protocol.RenderSnapshot);
        snapshot.* = .{
            .visible_lines = visible_lines,
            .first_visible_line = s.scroll_offset,
            .total_lines = s.buffer.lineCount(),
            .cursor_row = s.cursor_row,
            .cursor_col = s.cursor_col,
            .nav_repeat_count = self.nav_repeat_count,
            .selection_anchor_row = if (s.selection_anchor) |a| a.row else null,
            .selection_anchor_col = if (s.selection_anchor) |a| a.col else null,
            .scroll_offset = s.scroll_offset,
            .version = self.version,
            .mode = self.mode,
            .terminal_output = terminal_output_slice,
            .terminal_input = terminal_input_slice,
            .terminal_cwd = if (self.terminal_cwd) |cwd| try alloc.dupe(u8, cwd) else null,
            .terminal_scroll_offset = self.terminal_scroll_offset,
            .terminal_running = self.terminal_running,
            .file_path = file_path_slice,
            .file_modified = s.modified,
            .buffers = buffer_infos,
            .active_buffer_index = self.buffer_manager.active_index,
            .buffer_picker_selected = self.buffer_manager.picker_selected,
            .file_picker_cwd = file_picker_cwd,
            .file_picker_entries = picker_entries,
            .file_picker_selected = self.file_manager.selected_index,
            .buffer_picker_scroll_offset = self.buffer_manager.picker_scroll_offset,
            .buffer_picker_number_input = if (self.mode == .buffer_picker and self.buffer_picker_number_input.items.len > 0)
                try alloc.dupe(u8, self.buffer_picker_number_input.items)
            else
                null,
            .save_as_input = save_as_input_slice,
            .search_input = search_input_slice,
            .command_palette_query = command_palette_query_slice,
            .command_palette_results = command_palette_results,
            .command_palette_selected = self.command_palette_selected,
            .syntax_tokens = syntax_tokens,
            .hover_content = hover_content,
            .go_to_line_input = go_to_line_input_slice,
            .symbol_picker_query = symbol_picker_query_slice,
            .symbol_picker_results = symbol_picker_results,
            .symbol_picker_selected = self.symbol_picker_selected,
            .completion_active = self.completion_active,
            .completion_items = completion_items,
            .completion_selected = self.completion_selected,
            .split_enabled = split_enabled,
            .panes = pane_snapshots,
            .focused_pane_id = focused_pane_id,
            .plugin_count = self.plugin_manager.plugins.count(),
            .plugin_status_items = try self.plugin_manager.ui_manager.getStatusItems(alloc),
            .plugin_panels = try self.plugin_manager.ui_manager.getPanels(alloc),
            .lsp_status = try self.lsp_manager.getActiveServerStatus(alloc),
            .logs = logs_slice,
            .editor_config = .{
                .tab_size = self.storage.config.editor.tab_size,
                .insert_spaces = self.storage.config.editor.insert_spaces,
                .line_numbers = switch (self.storage.config.editor.line_numbers) {
                    .absolute => .absolute,
                    .relative => .relative,
                    .none => .none,
                },
                .wrap = self.storage.config.editor.wrap,
                .show_status_bar = self.storage.config.ui.show_status_bar,
                .cursor_line = self.storage.config.editor.cursor_line,
            },
            .global_search_query = if (self.global_search_query.items.len > 0)
                try alloc.dupe(u8, self.global_search_query.items)
            else
                null,
            .global_search_replace = if (self.global_search_replace.items.len > 0)
                try alloc.dupe(u8, self.global_search_replace.items)
            else
                null,
            .global_search_results = blk: {
                if (self.global_search_results.items.len == 0) {
                    // Send an allocated empty slice so the view can tell
                    // "search ran, no matches" from "no search yet". The
                    // latter is signalled by `global_search_ran = false`.
                    break :blk try alloc.alloc(protocol.GlobalSearchFileGroup, 0);
                }
                const results = try alloc.alloc(protocol.GlobalSearchFileGroup, self.global_search_results.items.len);
                for (self.global_search_results.items, 0..) |group, i| {
                    const new_matches = try alloc.alloc(protocol.GlobalSearchMatch, group.matches.len);
                    for (group.matches, 0..) |match, j| {
                        new_matches[j] = .{
                            .line_num = match.line_num,
                            .line_content = try alloc.dupe(u8, match.line_content),
                            .match_start = match.match_start,
                            .match_end = match.match_end,
                        };
                    }
                    results[i] = .{
                        .file_path = try alloc.dupe(u8, group.file_path),
                        .matches = new_matches,
                        .collapsed = group.collapsed,
                    };
                }
                break :blk results;
            },
            .global_search_total_matches = blk: {
                var count: usize = 0;
                for (self.global_search_results.items) |group| {
                    count += group.matches.len;
                }
                break :blk count;
            },
            .global_search_total_files = self.global_search_results.items.len,
            .global_search_selected_file = self.global_search_selected_file,
            .global_search_selected_match = self.global_search_selected_match,
            .global_search_focus_replace = self.global_search_focus_replace,
            .global_search_options = self.global_search_options,
            .global_search_ran = self.global_search_ran,
            .git_branch = blk_g: {
                self.refreshGitBranchIfStale();
                if (self.git_branch) |b| break :blk_g try alloc.dupe(u8, b);
                break :blk_g null;
            },
            .active_job_count = @intCast(self.job_manager.activeCount()),
            .diff_highlight_lines = if (self.diff_highlights.items.len > 0)
                try alloc.dupe(protocol.DiffLineHighlight, self.diff_highlights.items)
            else
                null,
            .diagnostics = blk_d: {
                const path = s.file_path orelse break :blk_d null;
                const diags = self.lsp_manager.getDiagnosticsForFile(alloc, path) catch break :blk_d null;
                // diags is owned by alloc (the snapshot arena), so it gets
                // freed automatically when the arena is reset.
                if (diags.len == 0) break :blk_d null;
                std.mem.sort(LSPManager.Diagnostic, diags, {}, struct {
                    fn lt(_: void, a: LSPManager.Diagnostic, b: LSPManager.Diagnostic) bool {
                        if (a.start_line != b.start_line) return a.start_line < b.start_line;
                        return a.start_col < b.start_col;
                    }
                }.lt);
                const out = try alloc.alloc(protocol.DiagnosticSnapshot, diags.len);
                for (diags, 0..) |d, i| {
                    out[i] = .{
                        .start_line = d.start_line,
                        .start_col = d.start_col,
                        .end_line = d.end_line,
                        .end_col = d.end_col,
                        .severity = switch (d.severity) {
                            .err => .err,
                            .warning => .warning,
                            .info => .info,
                            .hint => .hint,
                        },
                        .message = d.message,
                    };
                }
                break :blk_d out;
            },
            .diagnostic_error_count = blk_e: {
                const path = s.file_path orelse break :blk_e 0;
                var c: u32 = 0;
                if (self.lsp_manager.getDiagnosticsForFile(alloc, path)) |diags| {
                    for (diags) |d| if (d.severity == .err) {
                        c += 1;
                    };
                } else |_| {}
                break :blk_e c;
            },
            .diagnostic_warning_count = blk_w: {
                const path = s.file_path orelse break :blk_w 0;
                var c: u32 = 0;
                if (self.lsp_manager.getDiagnosticsForFile(alloc, path)) |diags| {
                    for (diags) |d| if (d.severity == .warning) {
                        c += 1;
                    };
                } else |_| {}
                break :blk_w c;
            },
            .status_message = blk: {
                const current_time = std.Io.Clock.real.now(self.io).toMilliseconds();
                if (self.status_message != null and current_time < self.status_message_expires) {
                    break :blk self.status_message;
                } else {
                    self.status_message = null;
                    break :blk null;
                }
            },
        };

        var msg = protocol.Message{ .render_update = .{
            .snapshot_ptr = @intFromPtr(snapshot),
            .arena_ptr = @intFromPtr(arena),
            .pool_ptr = @intFromPtr(&self.arena_pool),
        } };

        const bytes = try msg.encode(self.allocator);
        defer self.allocator.free(bytes);
        // Renders coalesce: only the freshest snapshot matters. The
        // `version` field (bumped above) is the slot identity so the
        // bus can tell when it's actually replacing an earlier frame.
        try self.ui_bus.sendCoalesced(.render, bytes, self.version);
    }

    fn checkHover(self: *Core) !bool {
        const s = self.state();
        const path = s.file_path orelse return false;

        // Route through the authoritative LSP language detector instead
        // of a hard-coded extension list. Any language LSPManager can
        // serve (zig, python, ts/tsx/jsx, js, rust, go, c/cpp/headers,
        // java, ruby/rake, c#) is hover-eligible; languages without a
        // running server fall through gracefully in the dispatcher.
        if (LSPManager.getLangFromPath(path) == null) return false;

        const node = self.syntax_manager.getNodeAt(s.cursor_row, s.cursor_col) orelse return false;
        const type_str = self.syntax_manager.getNodeType(node);

        // Different grammars name identifier-ish nodes differently
        // (`identifier`, `type_identifier`, `field_identifier`,
        // `scoped_identifier`, `property_identifier`, …). Accept any
        // node whose type contains "identifier", plus the small set of
        // non-`identifier`-named hover targets (builtin/primitive types).
        const is_hoverable =
            std.mem.indexOf(u8, type_str, "identifier") != null or
            std.mem.eql(u8, type_str, "builtin_type") or
            std.mem.eql(u8, type_str, "primitive_type") or
            std.mem.eql(u8, type_str, "type") or
            std.mem.endsWith(u8, type_str, "_name");

        if (!is_hoverable) return false;

        try self.ensureLspDocument();
        self.hover_pending = true;
        try self.lsp_manager.requestHover(path, @intCast(s.cursor_row), @intCast(s.cursor_col));
        return true;
    }

    pub fn ensureLspDocument(self: *Core) !void {
        const s = self.state();
        const path = s.file_path orelse return;
        const lang = LSPManager.getLangFromPath(path) orelse return;
        _ = lang;

        // Non-blocking. `documentOpened` takes the fast path when possible
        // and queues an `ensure_and_open` on the supervisor otherwise.
        // We never block the UI thread waiting for init — request methods
        // like `requestHover` enqueue their own deferred command when the
        // server isn't ready yet, and the response arrives via the normal
        // tick-driven pop/poll path.
        const content = try s.buffer.toString(self.allocator);
        defer self.allocator.free(content);
        try self.lsp_manager.documentOpened(path, content);

        self.lsp_manager.refreshSemanticTokens(path);
    }

    pub fn notifyBufferSwitched(self: *Core) void {
        const buf = self.buffer_manager.getActive();
        const event_data = buf.file_path orelse buf.name;
        self.plugin_manager.broadcastEvent(.buffer_switched, event_data);

        self.refreshSyntaxForCurrentBuffer();

        // Best-effort: queue a `documentOpened` for the new active buffer
        // so the LSP is aware of it by the time the user hovers/completes.
        // Non-blocking (either fast-path send or supervisor enqueue).
        self.eagerlyOpenActiveBuffer();
    }

    fn refreshSyntaxForCurrentBuffer(self: *Core) void {
        const active_buf = self.buffer_manager.getActive();
        self.buffer_manager.loadBufferContent(active_buf) catch |err| {
            log.warn("Failed to load lazy content: {}", .{err});
            return;
        };

        const s = self.state();
        if (s.file_path) |path| {
            const lang = SyntaxManager.Language.fromFilename(path);
            if (lang != .unknown) {
                self.syntax_manager.setLanguageEnum(lang) catch |err| {
                    log.warn("refreshSyntax: setLanguageEnum failed: {}", .{err});
                    return;
                };
                const content = s.buffer.toString(self.allocator) catch |err| {
                    log.warn("refreshSyntax: buffer.toString failed: {}", .{err});
                    return;
                };
                defer self.allocator.free(content);
                const buffer_id = self.buffer_manager.getActive().id;
                // Hand the parse to the background worker so the core thread
                // isn't blocked while tree-sitter chews through a large file.
                // The current `self.tree` (possibly stale) is used by render
                // until the worker swaps the new one in.
                self.syntax_manager.submitParse(content, buffer_id) catch |err| {
                    log.warn("refreshSyntax: submitParse failed: {}", .{err});
                };

                log.debug("refreshSyntax: parsed buffer {} (tree={s}, lang={s})", .{
                    buffer_id,
                    if (self.syntax_manager.tree != null) "valid" else "NULL",
                    @tagName(self.syntax_manager.current_lang),
                });

                const now = std.Io.Clock.real.now(self.io).toMilliseconds();
                self.last_buffer_switch_time = now;

                if (self.pending_lsp_refresh_path) |old| {
                    self.allocator.free(old);
                }
                self.pending_lsp_refresh_path = self.allocator.dupe(u8, path) catch null;
            }
        }
    }

    fn findProjectRoot(self: *Core, start_path: []const u8) !?[]const u8 {
        const dir_path = std.fs.path.dirname(start_path) orelse return null;
        var current_dir = try self.allocator.dupe(u8, dir_path);
        defer self.allocator.free(current_dir);

        while (true) {
            const build_zig = try std.fs.path.join(self.allocator, &.{ current_dir, "build.zig" });
            defer self.allocator.free(build_zig);

            if (std.Io.Dir.cwd().access(self.io, build_zig, .{})) |_| {
                return try self.allocator.dupe(u8, current_dir);
            } else |_| {}

            const build_zon = try std.fs.path.join(self.allocator, &.{ current_dir, "build.zig.zon" });
            defer self.allocator.free(build_zon);

            if (std.Io.Dir.cwd().access(self.io, build_zon, .{})) |_| {
                return try self.allocator.dupe(u8, current_dir);
            } else |_| {}

            const package_json = try std.fs.path.join(self.allocator, &.{ current_dir, "package.json" });
            defer self.allocator.free(package_json);

            if (std.Io.Dir.cwd().access(self.io, package_json, .{})) |_| {
                return try self.allocator.dupe(u8, current_dir);
            } else |_| {}

            const go_mod = try std.fs.path.join(self.allocator, &.{ current_dir, "go.mod" });
            defer self.allocator.free(go_mod);

            if (std.Io.Dir.cwd().access(self.io, go_mod, .{})) |_| {
                return try self.allocator.dupe(u8, current_dir);
            } else |_| {}

            const parent = std.fs.path.dirname(current_dir);
            if (parent) |p| {
                if (std.mem.eql(u8, p, current_dir)) break;
                if (p.len == 0) break;

                const new_current = try self.allocator.dupe(u8, p);
                self.allocator.free(current_dir);
                current_dir = new_current;
            } else {
                break;
            }
        }
        return null;
    }

    pub fn sendQuitToUI(self: *Core) !void {
        const session_path = self.storage.getSessionPath();

        var splits_json: ?[]const u8 = null;
        defer if (splits_json) |s| self.allocator.free(s);

        if (self.split_manager) |*sm| {
            self.syncStateToPane();
            splits_json = sm.toJson(self.allocator) catch null;
        }

        session.save(
            self.allocator,
            self.io,
            session_path,
            self.buffer_manager.buffers,
            self.buffer_manager.active_index,
            splits_json,
        ) catch |err| {
            log.warn("Failed to save session: {}", .{err});
        };

        var msg = protocol.Message{ .command = .quit };
        const bytes = try msg.encode(self.allocator);
        defer self.allocator.free(bytes);
        try self.ui_bus.sendCritical(bytes);
    }

    fn restoreSession(self: *Core) void {
        const session_path = self.storage.getSessionPath();
        const loaded = session.load(self.allocator, self.io, session_path) catch |err| {
            log.warn("Failed to load session: {}", .{err});
            return;
        };

        const sess = loaded orelse return;
        defer session.freeSession(self.allocator, sess);

        if (sess.buffers.len == 0) return;

        log.info("Restoring session: {} buffers, has_splits={}", .{ sess.buffers.len, sess.splits_json != null });

        for (sess.buffers) |buf_state| {
            const path = buf_state.file_path orelse continue;

            if (std.Io.Dir.accessAbsolute(self.io, path, .{})) |_| {
                _ = self.buffer_manager.openFile(path) catch |err| {
                    log.warn("Session: Failed to open '{s}': {}", .{ path, err });
                    continue;
                };

                const buf = self.buffer_manager.getActive();
                buf.state.cursor_row = buf_state.cursor_row;
                buf.state.cursor_col = buf_state.cursor_col;
                buf.state.scroll_offset = buf_state.scroll_offset;

                // best-effort: workspace tracking is auxiliary; buffer is still usable if this fails
                self.workspace_manager.registerBuffer(buf.id, path) catch {};
            } else |_| {
                log.info("Session: File no longer exists: '{s}'", .{path});
            }
        }

        if (sess.active_buffer < self.buffer_manager.buffers.items.len) {
            self.buffer_manager.switchTo(sess.active_buffer);
        }

        if (sess.splits_json) |splits_json| {
            if (self.buffer_manager.buffers.items.len > 0) {
                if (self.split_manager) |*sm| {
                    sm.deinit();
                    self.split_manager = null;
                }

                self.split_manager = SplitManager.initFromJson(self.allocator, splits_json) catch |err| {
                    log.warn("Session: Failed to restore splits: {}", .{err});
                    return;
                };

                if (self.split_manager) |*sm| {
                    const max_buf_idx = self.buffer_manager.buffers.items.len;
                    self.validatePaneBufferIndices(sm, max_buf_idx);

                    self.syncPaneToState();
                }

                log.info("Session: Restored split layout", .{});
            }
        }

        self.refreshSyntaxForCurrentBuffer();
    }

    fn validatePaneBufferIndices(self: *Core, sm: *SplitManager, max_buf_idx: usize) void {
        self.validatePaneBufferIndicesRecursive(sm.root, max_buf_idx);
    }

    fn validatePaneBufferIndicesRecursive(self: *Core, node: *SplitNode, max_buf_idx: usize) void {
        switch (node.*) {
            .container => |c| {
                self.validatePaneBufferIndicesRecursive(c.first, max_buf_idx);
                self.validatePaneBufferIndicesRecursive(c.second, max_buf_idx);
            },
            .pane => |*p| {
                if (p.buffer_index >= max_buf_idx) {
                    p.buffer_index = if (max_buf_idx > 0) max_buf_idx - 1 else 0;
                }
            },
        }
    }

    fn handleCommandPaletteInput(self: *Core, key: vaxis.Key) !bool {
        if (key.matches(vaxis.Key.up, .{}) or key.matches('p', .{ .ctrl = true })) {
            if (self.command_palette_selected > 0) {
                self.command_palette_selected -= 1;
            }
            return true;
        }
        if (key.matches(vaxis.Key.down, .{}) or key.matches('n', .{ .ctrl = true })) {
            if (self.command_palette_results.items.len > 0 and self.command_palette_selected < self.command_palette_results.items.len - 1) {
                self.command_palette_selected += 1;
            }
            return true;
        }
        if (key.matches(vaxis.Key.enter, .{})) {
            if (self.command_palette_results.items.len > 0) {
                const cmd = self.command_palette_results.items[self.command_palette_selected];

                self.mode = self.previous_mode;
                self.command_palette_input.clearRetainingCapacity();

                try cmd.execute(self, cmd.context);
            }
            return true;
        }
        if (key.matches(vaxis.Key.backspace, .{})) {
            if (self.command_palette_input.items.len > 0) {
                _ = self.command_palette_input.pop();
                try self.updateCommandSearch();
                return true;
            }
        }
        if (key.text) |text| {
            try self.command_palette_input.appendSlice(self.allocator, text);
            try self.updateCommandSearch();
            return true;
        }
        return false;
    }

    fn updateCommandSearch(self: *Core) !void {
        self.command_palette_results.clearRetainingCapacity();
        try self.command_registry.search(self.command_palette_input.items, &self.command_palette_results, self.allocator);
        self.command_palette_selected = 0;
    }

    fn handleGoToLineInput(self: *Core, key: vaxis.Key) !bool {
        if (key.matches(vaxis.Key.enter, .{})) {
            if (self.go_to_line_input.items.len > 0) {
                const line_str = self.go_to_line_input.items;
                const line_num = std.fmt.parseInt(usize, line_str, 10) catch {
                    self.mode = self.previous_mode;
                    self.go_to_line_input.clearRetainingCapacity();
                    return true;
                };

                const s = self.state();
                const total_lines = s.buffer.lineCount();

                if (line_num > 0) {
                    s.cursor_row = @min(line_num - 1, if (total_lines > 0) total_lines - 1 else 0);
                } else {
                    s.cursor_row = 0;
                }
                s.cursor_col = 0;
                self.mode = self.previous_mode;
                self.go_to_line_input.clearRetainingCapacity();
            }
            return true;
        } else if (key.matches(vaxis.Key.backspace, .{})) {
            if (self.go_to_line_input.items.len > 0) {
                _ = self.go_to_line_input.pop();
                return true;
            }
        } else if (key.text) |text| {
            try self.go_to_line_input.appendSlice(self.allocator, text);
            return true;
        }
        return false;
    }

    fn handleSymbolPickerInput(self: *Core, key: vaxis.Key) !bool {
        if (key.matches(vaxis.Key.up, .{}) or key.matches('p', .{ .ctrl = true })) {
            if (self.symbol_picker_selected > 0) {
                self.symbol_picker_selected -= 1;
            }
            return true;
        }
        if (key.matches(vaxis.Key.down, .{}) or key.matches('n', .{ .ctrl = true })) {
            if (self.symbol_picker_results.items.len > 0 and self.symbol_picker_selected < self.symbol_picker_results.items.len - 1) {
                self.symbol_picker_selected += 1;
            }
            return true;
        }
        if (key.matches(vaxis.Key.enter, .{})) {
            if (self.symbol_picker_results.items.len > 0 and self.symbol_picker_selected < self.symbol_picker_results.items.len) {
                const sym = self.symbol_picker_results.items[self.symbol_picker_selected];
                const s = self.state();
                s.cursor_row = sym.line;
                s.cursor_col = 0;
            }
            self.mode = self.previous_mode;
            self.symbol_picker_query.clearRetainingCapacity();
            return true;
        }
        if (key.matches(vaxis.Key.backspace, .{})) {
            if (self.symbol_picker_query.items.len > 0) {
                _ = self.symbol_picker_query.pop();
                try self.updateSymbolSearch();
                return true;
            }
        }
        if (key.text) |text| {
            try self.symbol_picker_query.appendSlice(self.allocator, text);
            try self.updateSymbolSearch();
            return true;
        }
        return false;
    }

    fn updateSymbolSearch(self: *Core) !void {
        for (self.symbol_picker_results.items) |entry| {
            self.allocator.free(entry.name);
        }
        self.symbol_picker_results.clearRetainingCapacity();

        const query = self.symbol_picker_query.items;

        for (self.symbol_picker_all_symbols.items) |sym| {
            if (query.len == 0) {
                const name_dupe = try self.allocator.dupe(u8, sym.name);
                try self.symbol_picker_results.append(self.allocator, .{
                    .name = name_dupe,
                    .kind = sym.kind,
                    .line = sym.line,
                });
            } else {
                var match = false;
                if (sym.name.len >= query.len) {
                    for (0..sym.name.len - query.len + 1) |i| {
                        var all_match = true;
                        for (0..query.len) |j| {
                            if (std.ascii.toLower(sym.name[i + j]) != std.ascii.toLower(query[j])) {
                                all_match = false;
                                break;
                            }
                        }
                        if (all_match) {
                            match = true;
                            break;
                        }
                    }
                }
                if (match) {
                    const name_dupe = try self.allocator.dupe(u8, sym.name);
                    try self.symbol_picker_results.append(self.allocator, .{
                        .name = name_dupe,
                        .kind = sym.kind,
                        .line = sym.line,
                    });
                }
            }
        }

        self.symbol_picker_selected = 0;
    }

    fn clearGlobalSearchResults(self: *Core) void {
        for (self.global_search_results.items) |*group| {
            for (group.matches) |match| {
                self.allocator.free(match.line_content);
            }
            self.allocator.free(group.matches);
            self.allocator.free(group.file_path);
        }
        self.global_search_results.clearRetainingCapacity();
    }

    fn handleGlobalSearchInput(self: *Core, key: vaxis.Key) !bool {
        if (key.matches(vaxis.Key.tab, .{})) {
            self.global_search_focus_replace = !self.global_search_focus_replace;
            return true;
        }

        if (key.matches(vaxis.Key.enter, .{})) {
            if (self.global_search_results.items.len > 0) {
                const file_idx = self.global_search_selected_file;
                if (file_idx < self.global_search_results.items.len) {
                    const group = self.global_search_results.items[file_idx];
                    const match_idx = self.global_search_selected_match;
                    if (match_idx < group.matches.len) {
                        const match = group.matches[match_idx];
                        const full_path = try std.Io.Dir.cwd().realPathFileAlloc(self.io, group.file_path, self.allocator);
                        defer self.allocator.free(full_path);
                        try self.openFileAtLine(full_path, match.line_num);
                        self.mode = .select;
                        return true;
                    }
                }
            }
            return true;
        }

        if (key.matches(vaxis.Key.escape, .{})) {
            self.mode = self.previous_mode;
            return true;
        }

        if (key.matches(vaxis.Key.backspace, .{})) {
            if (self.global_search_focus_replace) {
                if (self.global_search_replace.items.len > 0) {
                    _ = self.global_search_replace.pop();
                }
            } else {
                if (self.global_search_query.items.len > 0) {
                    _ = self.global_search_query.pop();
                    try self.performGlobalSearch();
                }
            }
            return true;
        }

        if (key.text) |text| {
            if (self.global_search_focus_replace) {
                try self.global_search_replace.appendSlice(self.allocator, text);
            } else {
                try self.global_search_query.appendSlice(self.allocator, text);
                try self.performGlobalSearch();
            }
            return true;
        }

        if (key.matches(vaxis.Key.up, .{})) {
            if (self.global_search_results.items.len > 0) {
                if (self.global_search_selected_file >= self.global_search_results.items.len) {
                    self.global_search_selected_file = self.global_search_results.items.len - 1;
                }

                if (self.global_search_selected_match > 0) {
                    self.global_search_selected_match -= 1;
                } else if (self.global_search_selected_file > 0) {
                    self.global_search_selected_file -= 1;
                    const prev_group = self.global_search_results.items[self.global_search_selected_file];
                    if (prev_group.matches.len > 0) {
                        self.global_search_selected_match = prev_group.matches.len - 1;
                    } else {
                        self.global_search_selected_match = 0;
                    }
                }
            }
            return true;
        }

        if (key.matches(vaxis.Key.down, .{})) {
            if (self.global_search_results.items.len > 0) {
                if (self.global_search_selected_file >= self.global_search_results.items.len) {
                    self.global_search_selected_file = self.global_search_results.items.len - 1;
                    self.global_search_selected_match = 0;
                    return true;
                }

                const current_group = self.global_search_results.items[self.global_search_selected_file];
                if (current_group.matches.len > 0 and self.global_search_selected_match + 1 < current_group.matches.len) {
                    self.global_search_selected_match += 1;
                } else if (self.global_search_selected_file + 1 < self.global_search_results.items.len) {
                    self.global_search_selected_file += 1;
                    self.global_search_selected_match = 0;
                }
            }
            return true;
        }

        return false;
    }

    fn performGlobalSearch(self: *Core) !void {
        self.clearGlobalSearchResults();
        self.global_search_ran = true;

        const query = self.global_search_query.items;
        if (query.len < 2) return;

        const results = global_search.search(
            self.allocator,
            self.io,
            query,
            ".",
            .{ .search = self.global_search_options },
        ) catch |err| {
            log.warn("Global search failed: {}", .{err});
            return;
        };
        // The service returns an owned slice; we adopt the contents directly.
        try self.global_search_results.ensureTotalCapacity(self.allocator, results.len);
        for (results) |g| self.global_search_results.appendAssumeCapacity(g);
        // Free the outer slice but not the per-group memory (we just moved it).
        if (results.len > 0) self.allocator.free(results);

        self.global_search_selected_file = 0;
        self.global_search_selected_match = 0;
    }

    /// Move the cursor to the next or previous diagnostic in the current
    /// buffer. Wraps at file boundaries. No-op if there are none.
    fn jumpToDiagnostic(self: *Core, forward: bool) !void {
        const s = self.state();
        const path = s.file_path orelse return;
        const diags = self.lsp_manager.getDiagnosticsForFile(self.allocator, path) catch return;
        defer LSPManager.freeDiagnostics(self.allocator, diags);
        if (diags.len == 0) return;

        // Pick the next diagnostic strictly after the cursor (or strictly
        // before, for previous). The list isn't guaranteed sorted, so do a
        // linear scan picking the best match.
        const cur_line: i64 = @intCast(s.cursor_row);
        const cur_col: i64 = @intCast(s.cursor_col);
        var best_idx: ?usize = null;
        for (diags, 0..) |d, i| {
            const dl: i64 = @intCast(d.start_line);
            const dc: i64 = @intCast(d.start_col);
            const after = dl > cur_line or (dl == cur_line and dc > cur_col);
            const matches = if (forward) after else !after and !(dl == cur_line and dc == cur_col);
            if (!matches) continue;
            if (best_idx) |bi| {
                const b = diags[bi];
                const bl: i64 = @intCast(b.start_line);
                const bc: i64 = @intCast(b.start_col);
                const better = if (forward)
                    (dl < bl or (dl == bl and dc < bc))
                else
                    (dl > bl or (dl == bl and dc > bc));
                if (better) best_idx = i;
            } else best_idx = i;
        }
        // Wrap if nothing found in the chosen direction.
        if (best_idx == null) {
            best_idx = 0;
            for (diags, 0..) |d, i| {
                const dl = d.start_line;
                const dc = d.start_col;
                const b = diags[best_idx.?];
                const better = if (forward)
                    (dl < b.start_line or (dl == b.start_line and dc < b.start_col))
                else
                    (dl > b.start_line or (dl == b.start_line and dc > b.start_col));
                if (better) best_idx = i;
            }
        }
        const target = diags[best_idx.?];
        s.cursor_row = target.start_line;
        s.cursor_col = target.start_col;

        const visible_rows: usize = if (self.win_size.rows > 2) self.win_size.rows - 2 else 1;
        const half = visible_rows / 2;
        s.scroll_offset = if (s.cursor_row >= half) s.cursor_row - half else 0;

        try self.sendUpdate();
    }

    /// `]s` / `[s` — move the cursor to the start of the next or
    /// previous named AST sibling. No-op (returns false) if the syntax
    /// tree isn't loaded or the cursor is already at a tree boundary.
    fn jumpToSibling(self: *Core, forward: bool) !bool {
        const s = self.state();
        const target = if (forward)
            self.syntax_manager.nextSiblingPosition(s.cursor_row, s.cursor_col)
        else
            self.syntax_manager.prevSiblingPosition(s.cursor_row, s.cursor_col);
        const pos = target orelse return false;
        s.cursor_row = pos.line;
        s.cursor_col = pos.col;
        self.recenterIfOffscreen();
        try self.sendUpdate();
        return true;
    }

    /// `]m` / `[m` — move to the next or previous function-like
    /// declaration (function, method, constructor, fn_proto, etc.).
    fn jumpToFunction(self: *Core, forward: bool) !bool {
        const s = self.state();
        const SM = @import("../syntax/manager.zig").SyntaxManager;
        const target = self.syntax_manager.findNodeOfKinds(
            s.cursor_row,
            s.cursor_col,
            forward,
            SM.function_kinds,
        );
        const pos = target orelse return false;
        s.cursor_row = pos.line;
        s.cursor_col = pos.col;
        self.recenterIfOffscreen();
        try self.sendUpdate();
        return true;
    }

    const StructuralAdjust = enum { expand, shrink };

    /// Visual-mode `+` / `-` — grow or contract the selection to match
    /// the enclosing AST node (parent) or its first named child.
    fn adjustSelectionStructural(self: *Core, kind: StructuralAdjust) !void {
        const s = self.state();
        const anchor = s.selection_anchor orelse return;

        // Normalize anchor/cursor into (start, end).
        const a_before = anchor.row < s.cursor_row or
            (anchor.row == s.cursor_row and anchor.col <= s.cursor_col);
        const start_row = if (a_before) anchor.row else s.cursor_row;
        const start_col = if (a_before) anchor.col else s.cursor_col;
        const end_row = if (a_before) s.cursor_row else anchor.row;
        const end_col = if (a_before) s.cursor_col else anchor.col;

        const sel = switch (kind) {
            .expand => self.syntax_manager.expandSelection(start_row, start_col, end_row, end_col),
            .shrink => self.syntax_manager.shrinkSelection(start_row, start_col, end_row, end_col),
        };

        s.selection_anchor = .{ .row = sel.start_line, .col = sel.start_col };
        s.cursor_row = sel.end_line;
        s.cursor_col = sel.end_col;
        try self.sendUpdate();
    }

    fn recenterIfOffscreen(self: *Core) void {
        const s = self.state();
        const visible_rows: usize = if (self.win_size.rows > 2) self.win_size.rows - 2 else 1;
        if (s.cursor_row < s.scroll_offset or s.cursor_row >= s.scroll_offset + visible_rows) {
            const half = visible_rows / 2;
            s.scroll_offset = if (s.cursor_row >= half) s.cursor_row - half else 0;
        }
    }

    /// Refresh the cached git branch (at most once every 2 seconds). Runs
    /// `git symbolic-ref --short HEAD` as a subprocess. On a non-git
    /// directory the cache stays null.
    fn refreshGitBranchIfStale(self: *Core) void {
        const now = std.Io.Clock.real.now(self.io).toMilliseconds();
        if (now - self.git_branch_refreshed_ms < 2000) return;
        self.git_branch_refreshed_ms = now;

        const res = std.process.run(self.allocator, self.io, .{
            .argv = &.{ "git", "symbolic-ref", "--short", "HEAD" },
        }) catch return;
        defer {
            self.allocator.free(res.stdout);
            self.allocator.free(res.stderr);
        }
        if (res.term.exited != 0) {
            if (self.git_branch) |b| self.allocator.free(b);
            self.git_branch = null;
            return;
        }
        const trimmed = std.mem.trim(u8, res.stdout, " \t\r\n");
        if (self.git_branch) |b| {
            if (std.mem.eql(u8, b, trimmed)) return;
            self.allocator.free(b);
        }
        self.git_branch = self.allocator.dupe(u8, trimmed) catch null;
    }

    fn openFileAtLine(self: *Core, path: []const u8, line: usize) !void {
        _ = try self.buffer_manager.openFile(path);

        try self.ensureLspDocument();

        const s = self.state();
        if (line > 0) {
            s.cursor_row = line - 1;
            s.cursor_col = 0;
        }
    }
};
