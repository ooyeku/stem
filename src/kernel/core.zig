const std = @import("std");
const platform = @import("platform.zig");
const logger_service = @import("../services/logger.zig");
const log = logger_service.scoped("Core");
const vaxis = @import("vaxis");
const vigil_api = @import("../services/vigil_adapters.zig");
const EditorState = @import("../core/state.zig").EditorState;
const FileManager = @import("../core/file_manager.zig").FileManager;
const auto_pair = @import("../core/auto_pair.zig");
const unicode = @import("../core/unicode.zig");
const Keys = @import("../config/keys.zig").Keys;
const BufferManager = @import("buffer_manager.zig").BufferManager;
const Buffer = @import("buffer_manager.zig").Buffer;
const JumpList = @import("jump_list.zig").JumpList;
const BookmarkStore = @import("bookmarks.zig").BookmarkStore;
const protocol = @import("protocol.zig");
const LSPManager = @import("../services/lsp_manager.zig").LSPManager;
const LspServer = @import("../services/lsp/server.zig").LSPServer;
const lsp_client = @import("../lsp/client.zig");
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
const StemRuntime = @import("../services/runtime.zig").StemRuntime;
const session = @import("session.zig");
const global_search = @import("../services/global_search.zig");
const SearchIndex = @import("../services/search_index.zig").SearchIndex;
const hover_doc_mod = @import("../services/hover_doc.zig");
const ArenaPool = @import("arena_pool.zig").ArenaPool;
const terminal_proc = @import("terminal_proc.zig");
const GitCommands = @import("commands/git_commands.zig").GitCommands;
const BuildCommands = @import("commands/build_commands.zig").BuildCommands;
const LspCommands = @import("commands/lsp_commands.zig").LspCommands;
const SplitCommands = @import("commands/split_commands.zig").SplitCommands;
const SystemCommands = @import("commands/system_commands.zig").SystemCommands;
const EditCommands = @import("commands/edit_commands.zig").EditCommands;
const PluginCommands = @import("commands/plugin_commands.zig").PluginCommands;
const NavCommands = @import("commands/nav_commands.zig").NavCommands;
const BufferCommands = @import("commands/buffer_commands.zig").BufferCommands;
const FileCommands = @import("commands/file_commands.zig").FileCommands;
const ToggleCommands = @import("commands/toggle_commands.zig").ToggleCommands;
const BookmarkCommands = @import("commands/bookmark_commands.zig").BookmarkCommands;
const LeaderDispatch = @import("leader_dispatch.zig").LeaderDispatch;
const render_mod = @import("render.zig");
const pickers = @import("pickers.zig");
const input = @import("input.zig");
const ReferencesPicker = pickers.ReferencesPicker;
const DiagnosticsPicker = pickers.DiagnosticsPicker;

pub const CompletionDisplayItem = struct {
    label: []const u8,
    kind_icon: []const u8,
    detail: ?[]const u8,
    kind_category: protocol.CompletionEntry.KindCategory = .other,
};

fn jsonValueToU32(v: std.json.Value) ?u32 {
    return switch (v) {
        .integer => |iv| if (iv < 0 or iv > std.math.maxInt(u32)) null else @intCast(iv),
        .float => |fv| blk: {
            if (!std.math.isFinite(fv)) break :blk null;
            if (fv < 0 or fv > @as(f64, std.math.maxInt(u32))) break :blk null;
            break :blk @intFromFloat(fv);
        },
        else => null,
    };
}

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

pub fn handleUserQuitInputError(core: anytype, err: anyerror) anyerror!bool {
    if (err != error.UserQuit) return err;
    core.sendQuitToUI() catch {};
    return true;
}

pub const MultiCursor = struct {
    row: usize,
    col: usize,
};

/// Durable backing entry for the references picker — owns its
/// strings via the core allocator. Mirrored to the per-frame arena
/// in `protocol.ReferenceEntry` for the snapshot.
pub const ReferenceEntryOwned = struct {
    full_path: []u8,
    display_path: []u8,
    line: u32,
    col: u32,
    snippet: []u8,

    pub fn deinit(self: *ReferenceEntryOwned, allocator: std.mem.Allocator) void {
        allocator.free(self.full_path);
        allocator.free(self.display_path);
        allocator.free(self.snippet);
    }
};

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
    runtime_services: ?*StemRuntime = null,
    buffer_manager: BufferManager,
    /// Bus used by Core to send to the UI thread (renders, quit, etc.).
    /// Replaces a raw `*vigil.Inbox`; gives us priority routing,
    /// render-coalescing, and stats.
    ui_bus: *@import("message_bus.zig").MessageBus,
    core_inbox: ?*vigil_api.Inbox = null,
    /// Bus for sending TO Core's own inbox (used by terminal workers,
    /// plugin manager forwards, etc.). Set in `run()`.
    core_bus: ?*@import("message_bus.zig").MessageBus = null,
    version: u64 = 0,
    mode: protocol.Mode = .select,
    previous_mode: protocol.Mode = .select,
    file_manager: FileManager,
    /// File-explorer state. Allocated lazily on first
    /// `Space e` so the cwd scan doesn't run for users who
    /// never open the explorer.
    file_explorer: ?@import("file_explorer.zig").FileExplorer = null,
    terminal_input: std.ArrayListUnmanaged(u8),
    terminal_service: TerminalService,
    terminal_output: std.ArrayListUnmanaged(u8) = .empty,
    terminal_scroll_offset: usize = 0,
    terminal_running: bool = false,
    terminal_saved_input: std.ArrayListUnmanaged(u8) = .empty,
    terminal_cwd: ?[]const u8 = null,
    terminal_old_cwd: ?[]const u8 = null,
    leader_pending: bool,
    /// Wall-clock ms when `leader_pending` last went true. Read by
    /// the tick handler to auto-cancel after
    /// `leader_pending_timeout_ms` so a chord left dangling (user
    /// walked away, lost focus mid-chord, etc.) doesn't stay
    /// armed forever and surprise the next keystroke. Refreshed
    /// on every double-Space tap so users actively re-arming the
    /// chord don't get auto-cancelled out from under them.
    leader_pending_set_ms: i64 = 0,
    leader_pending_timeout_ms: i64 = 2000,
    /// In-flight plugin-keybind chord. Reset when a chord matches,
    /// no longer prefixes any binding, or the leader gate closes.
    plugin_chord_buf: std.ArrayListUnmanaged(u8) = .empty,
    /// Native chord-prefix progress. When the user types
    /// `Space <prefix>` where `<prefix>` ∈ {l, g, w, t}, this
    /// captures the prefix byte; the next leader key is then
    /// dispatched through that group's sub-switch
    /// (`handleLeaderChord`). null = no chord prefix pending; the
    /// leader handler then dispatches via the top-level switch.
    /// Cleared whenever the chord completes, is cancelled (Esc),
    /// or the leader chord ends. Tied to `leader_pending` — if
    /// `leader_pending` is false this must be null.
    leader_chord: ?u8 = null,
    /// One of `[` or `]` pressed, awaiting target key (e.g. `d` for
    /// diagnostic). null = no bracket-prefix pending.
    bracket_pending: ?u8 = null,
    /// `m` pressed in select mode, awaiting bookmark slot (a-z). The
    /// slot key then writes `(file, row, col)` into `bookmarks`. Any
    /// other follow-up cancels.
    bookmark_set_pending: bool = false,
    /// `'` pressed in select mode, awaiting bookmark slot to jump to.
    bookmark_jump_pending: bool = false,
    bookmarks: BookmarkStore,

    /// Pending code-action list after `lsp.code_action` fired and
    /// the LSP returned a non-empty list. While set, the next
    /// digit `1..9`/`0` keypress applies the corresponding action;
    /// Esc cancels. Owned by `self.allocator` via `freeCodeActions`.
    code_action_pending: ?[]LspServer.CodeAction = null,

    /// `textDocument/signatureHelp` last response. Populated when
    /// `(` or `,` is typed in Insert mode and the LSP responded;
    /// cleared on Esc, mode change, or another `(` triggering a
    /// fresh request. Renders as a single-line popup above the
    /// cursor.
    signature_help: ?LspServer.SignatureHelp = null,
    /// True between firing a signatureHelp request and either the
    /// response arriving or the user dismissing. Polled by the
    /// tick handler to drain the result without busy-waiting on
    /// the Insert input path.
    signature_help_pending: bool = false,

    /// Wall-clock ms of last `textDocument/inlayHint` request.
    /// Used to throttle: re-fire only when 500 ms have passed
    /// since the previous fire, which keeps inlay updates timely
    /// enough on scroll/edit without spamming the LSP.
    last_inlay_request_ms: i64 = 0,
    /// Text-object / surround chord progress. `s` in select mode
    /// starts the chord:
    ///   `s i <c>`  → select inside <c>
    ///   `s a <c>`  → select around <c>
    ///   `s d <c>`  → delete the surround pair <c> enclosing cursor
    ///   `s r <old> <new>` → replace surround <old> with <new>
    /// In visual mode, `S <c>` wraps the selection with <c>.
    text_object_state: enum {
        none,
        s_seen,
        inside_pending,
        around_pending,
        surround_delete_pending,
        surround_replace_old_pending,
        surround_replace_new_pending,
        surround_add_pending,
    } = .none,
    /// First char captured in `s r <old> <new>`. Held between the two
    /// follow-up keystrokes so the second key can complete the chord.
    surround_replace_old: u8 = 0,

    /// Secondary cursor positions for the active buffer. Empty means
    /// single-cursor mode. Insert and backspace operations in insert
    /// mode replicate at each secondary; line-altering operations and
    /// Esc clear the list. See `addNextOccurrence` for the canonical
    /// entry point.
    multi_cursors: std.ArrayListUnmanaged(MultiCursor) = .empty,
    /// Buffer id the multi_cursors list belongs to. Switching buffers
    /// invalidates the cursors (positions reference a different file).
    multi_cursor_buffer_id: u32 = 0,
    /// The pattern used by `Ctrl+D` to find the next occurrence.
    /// Re-derived each press: from the visual selection if any,
    /// otherwise the word under the primary cursor.
    multi_cursor_query: std.ArrayListUnmanaged(u8) = .empty,
    /// Cache of the identifier currently echoed via `word_highlight`
    /// decorations. Null = no highlight active. Owned by the manager
    /// allocator; freed when replaced or cleared.
    last_word_highlight: ?[]u8 = null,
    /// Minimum idle (ms) before word-under-cursor highlights paint.
    /// Mirrors VS Code's behaviour — wait until the cursor settles so
    /// fast motion doesn't flash repaints.
    word_highlight_idle_ms: i64 = 300,
    win_size: vaxis.Winsize = .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 },
    save_as_input: std.ArrayListUnmanaged(u8) = .empty,
    search_input: std.ArrayListUnmanaged(u8) = .empty,
    last_search_query: std.ArrayListUnmanaged(u8) = .empty,
    /// `/` = forward, `?` = backward. Used by both incremental search
    /// (live cursor jump while typing) and `n`/`N` step navigation.
    search_direction: enum { forward, backward } = .forward,
    /// Cursor position at the moment the search prompt opened. Esc
    /// restores it so a cancelled search doesn't strand the cursor on
    /// a partial-match preview.
    search_origin_row: usize = 0,
    search_origin_col: usize = 0,
    /// Total matches in the whole buffer for the current query, and
    /// the 1-based index of the active match. Both shown in the
    /// status bar as `[i/N]`. Capped — see `max_buffer_search_matches`.
    search_match_count: usize = 0,
    search_match_index: usize = 0,
    /// Pathology guard: stop counting matches past this so a buffer
    /// pasted with thousands of repeated short strings doesn't lock
    /// the editor on every keystroke during search.
    max_buffer_search_matches: usize = 9999,
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
    /// Parsed hover content — owned by Core, lives until the popup
    /// is dismissed or replaced. Avoids re-parsing per frame.
    hover_doc: ?hover_doc_mod.HoverDocument = null,
    /// Cursor cell of the token the hover was requested against;
    /// drives popup placement so the anchor stays stable even if
    /// the cursor drifts mid-identifier.
    hover_anchor_row: usize = 0,
    hover_anchor_col: usize = 0,
    /// Scroll offset (in rendered rows) for the popup body. Reset
    /// to 0 every time a fresh hover lands.
    hover_scroll_offset: usize = 0,
    /// True if the user explicitly invoked hover (Space h); stays
    /// visible until Esc. Auto-hover (idle timer) is false and
    /// dismisses on cursor move / keypress.
    hover_sticky: bool = false,
    /// Wall-clock ms when the in-flight hover request was sent.
    /// `hover_loading` becomes true once the gap exceeds the grace
    /// period so a fast hover doesn't flicker a loading toast.
    hover_request_sent_ms: i64 = 0,
    /// Grace before we show "Loading…" inside the popup so quick
    /// responses (≤ this) don't flash the loader.
    hover_loading_grace_ms: i64 = 150,

    /// Opt-in flag for the which-key popup. Set when the user taps
    /// Space twice in a row (the second tap inside an active leader
    /// chord). Cleared whenever `leader_pending` is cleared. The
    /// popup is never shown on a timer — auto-popup on small
    /// terminals hid the active line, so we wait for explicit intent.
    leader_help_requested: bool = false,
    definition_pending: bool = false,
    needs_render: bool = true,
    last_render_time: i64 = 0,
    /// Minimum gap between two `sendUpdate` snapshots, in ms. Acts as
    /// a soft frame-rate cap — a burst of state changes within this
    /// window is coalesced into one snapshot rather than rebuilding
    /// every time. 16 ms ≈ 60 FPS, which is faster than any user-
    /// noticeable input feedback need (60 wpm typing is ~5 chars/sec
    /// = 200 ms between events). Holds back wasted CPU during fast
    /// scroll, LSP token bursts, and parse-worker tree updates.
    min_render_interval_ms: i64 = 16,
    /// Last time we wrote the crash-recovery snapshot. The tick
    /// handler rewrites every 30 s of activity so a crash can lose
    /// at most that much cursor / scroll position state.
    last_recovery_ms: i64 = 0,
    recovery_interval_ms: i64 = 30_000,
    lsp_dirty: bool = false,
    lsp_debounce_deadline: i64 = 0,
    lsp_debounce_ms: i64 = 100,
    references_pending: bool = false,
    /// Wall-clock ms when the in-flight `textDocument/references`
    /// request was sent. If `references_pending` stays true longer
    /// than `references_timeout_ms`, the tick handler drops the
    /// request and surfaces a "no response" toast.
    references_request_sent_ms: i64 = 0,
    references_timeout_ms: i64 = 3000,
    references_symbol_name: ?[]u8 = null,
    references_source_file: ?[]u8 = null,
    references_source_line: usize = 0,

    /// References-picker backing store. Owned by `self.allocator`;
    /// each entry owns its strings. Replaced wholesale on each new
    /// references request — never appended to incrementally.
    references_picker_entries: std.ArrayListUnmanaged(ReferenceEntryOwned) = .empty,
    references_picker_selected: usize = 0,
    references_picker_scroll_offset: usize = 0,
    /// Where the user was when they pressed `Space l r`. Restored
    /// on Esc out of the picker; null when the picker isn't open.
    references_picker_origin: ?Buffer.OpenedFrom = null,

    /// Diagnostics-picker scratch — index and scroll are kept in
    /// Core because the diagnostic list itself lives in the LSP
    /// server's per-URI cache. Origin is restored on Esc, same
    /// pattern as references.
    diagnostics_picker_selected: usize = 0,
    diagnostics_picker_scroll_offset: usize = 0,
    diagnostics_picker_origin: ?Buffer.OpenedFrom = null,
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

    /// Workspace symbol picker (`Space O`). Server-side fuzzy match
    /// via `workspace/symbol`; we send a fresh request on each query
    /// edit and replace the result list when it lands.
    workspace_symbol_query: std.ArrayListUnmanaged(u8) = .empty,
    workspace_symbol_results: std.ArrayListUnmanaged(protocol.WorkspaceSymbolEntry) = .empty,
    workspace_symbol_selected: usize = 0,
    workspace_symbol_pending: bool = false,
    workspace_symbol_last_request_ms: i64 = 0,
    workspace_symbol_debounce_ms: i64 = 120,
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

    /// Replace-with-confirmation flow state. Triggered by Ctrl+R while
    /// in global_search mode with a non-empty replace field. We snapshot
    /// the query+replace strings at trigger time so subsequent edits to
    /// the input fields don't disturb the walk.
    global_search_replace_active: bool = false,
    /// Set when the user pressed `A`; remaining matches in the walk
    /// apply silently. Resets when the flow ends.
    global_search_replace_apply_all: bool = false,
    global_search_replace_query_snap: std.ArrayListUnmanaged(u8) = .empty,
    global_search_replace_text_snap: std.ArrayListUnmanaged(u8) = .empty,
    global_search_replace_file_idx: usize = 0,
    global_search_replace_match_idx: usize = 0,
    /// Stats reported when the flow ends.
    global_search_replace_count: usize = 0,
    global_search_replace_skipped: usize = 0,
    /// Cumulative column shift on the currently-targeted line caused by
    /// previously-applied replacements. Reset when the line changes.
    global_search_replace_line_delta: i64 = 0,
    /// (file_idx, line) of the last replacement, so we know when to
    /// reset `line_delta`.
    global_search_replace_last_file: usize = std.math.maxInt(usize),
    global_search_replace_last_line: usize = 0,
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
    /// Background workspace file-list index. Eliminates the directory
    /// walk on `:Find` queries (~30 ms saved per query on stem-sized
    /// repos, more on monorepos) and persists across restarts so the
    /// first query in a fresh session is also warm.
    search_index: SearchIndex,
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
    status_message_level: protocol.StatusLevel = .success,
    /// Scratch buffer for `status_message` slices that need to outlive the
    /// stack frame that built them (e.g. "Skipped N unsupported files"
    /// after a directory open). Fixed-size; messages truncate if longer.
    skip_status_buf: [128]u8 = undefined,
    /// Separate buffer for plugin-emitted notifications so they don't
    /// race the `skip_status_buf` writers. Sized larger because plugin
    /// messages can include identifiers / file paths.
    plugin_notification_buf: [512]u8 = undefined,
    /// Buffer for transient action feedback ("Saved foo.zig", "Pasted
    /// 3 lines", etc.). Routed through `setStatus` so any caller gets a
    /// single, consistent place to land. Distinct from the other
    /// buffers so concurrent file-scan / plugin events can't clobber a
    /// fresh action toast (and vice versa).
    action_status_buf: [256]u8 = undefined,

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

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        environ_block: std.process.Environ.Block,
        ui_bus: *@import("message_bus.zig").MessageBus,
        storage: *StorageManager,
        initial_files: []const []const u8,
        runtime_services: ?*StemRuntime,
    ) !Core {
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
            .runtime_services = runtime_services,
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
            .bookmarks = BookmarkStore.init(allocator),
            .decoration_manager = DecorationManager.init(allocator),
            .job_manager = JobManager.init(allocator, io),
            .workspace_manager = WorkspaceManager.init(allocator, io),
            .plugin_manager = undefined,
            .search_index = undefined,
            .initial_files = initial_files,
        };

        core.plugin_manager = PluginManager.init(allocator, io, environ_block, ui_bus, core.command_registry);
        if (runtime_services) |runtime| {
            core.plugin_manager.setVigilServices(&runtime.event_broker, &runtime.plugin_supervisor);
            core.lsp_manager.setVigilSupervisor(&runtime.lsp_supervisor);
        }
        core.search_index = SearchIndex.init(allocator, io, environ_block);

        // Push the user's configured thresholds into the buffer manager
        // so the first `openFile` honours them. Live config changes call
        // `setLargeFileThresholds` again from the config-change handler.
        core.buffer_manager.setLargeFileThresholds(
            storage.config.editor.large_file_threshold_bytes,
            storage.config.editor.large_file_threshold_lines,
            storage.config.editor.large_file_hard_limit_bytes,
        );
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
        if (self.file_explorer) |*fx| fx.deinit();
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
        self.global_search_replace_query_snap.deinit(self.allocator);
        self.global_search_replace_text_snap.deinit(self.allocator);
        self.multi_cursors.deinit(self.allocator);
        self.multi_cursor_query.deinit(self.allocator);
        if (self.code_action_pending) |list| {
            self.lsp_manager.freeCodeActions(list);
            self.code_action_pending = null;
        }
        if (self.signature_help) |sh| {
            self.lsp_manager.freeSignatureHelp(sh);
            self.signature_help = null;
        }
        self.lsp_manager.deinit();
        if (self.references_symbol_name) |name| self.allocator.free(name);
        if (self.references_source_file) |path| self.allocator.free(path);
        for (self.references_picker_entries.items) |*entry| entry.deinit(self.allocator);
        self.references_picker_entries.deinit(self.allocator);
        if (self.hover_content) |c| self.allocator.free(c);
        if (self.hover_doc) |*doc| doc.deinit();
        self.syntax_manager.deinit();

        self.plugin_manager.deinit();
        self.search_index.deinit();

        self.command_registry.deinit();
        self.allocator.destroy(self.command_registry);
        self.command_palette_input.deinit(self.allocator);
        self.command_palette_results.deinit(self.allocator);
        self.go_to_line_input.deinit(self.allocator);
        self.workspace_symbol_query.deinit(self.allocator);
        for (self.workspace_symbol_results.items) |entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.kind);
            self.allocator.free(entry.file_path);
        }
        self.workspace_symbol_results.deinit(self.allocator);

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
        self.plugin_chord_buf.deinit(self.allocator);

        self.history_manager.deinit();
        self.jump_list.deinit();
        self.bookmarks.deinit();
        if (self.last_word_highlight) |w| self.allocator.free(w);
        self.last_word_highlight = null;
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

    /// Whether the active buffer is in "large-file mode" — bypasses
    /// tree-sitter highlighting, bracket rainbow, LSP requests, and
    /// auto-pair so multi-MB files stay responsive. Computed once at
    /// open in `BufferManager.openFile`, sticky for the buffer's life.
    /// Lookup is two pointer dereferences; fine to call per-frame.
    pub fn activeBufferIsLarge(self: *Core) bool {
        if (self.split_manager) |*sm| {
            const pane = sm.getFocusedPane();
            if (pane.buffer_index < self.buffer_manager.buffers.items.len) {
                return self.buffer_manager.buffers.items[pane.buffer_index].is_large;
            }
        }
        return self.buffer_manager.getActive().is_large;
    }

    pub fn activeBufferIsPresentationReadOnly(self: *Core) bool {
        if (self.split_manager) |*sm| {
            const pane = sm.getFocusedPane();
            if (pane.buffer_index < self.buffer_manager.buffers.items.len) {
                return self.buffer_manager.buffers.items[pane.buffer_index].isPresentationReadOnly();
            }
        }
        return self.buffer_manager.getActive().isPresentationReadOnly();
    }

    pub fn rejectReadOnlyPresentationEdit(self: *Core) bool {
        if (!self.activeBufferIsPresentationReadOnly()) return false;
        self.mode = .view;
        self.dismissCompletion();
        self.clearMultiCursors();
        self.setStatusLiteralLeveled(.info, "Presentation views are read-only", 1500);
        return true;
    }

    /// Whether the buffer at `index` is in large-file mode. Used by
    /// pane-render code in `sendUpdate` so each split can be gated
    /// independently of the focused one.
    pub fn bufferIsLargeAt(self: *Core, index: usize) bool {
        if (index >= self.buffer_manager.buffers.items.len) return false;
        return self.buffer_manager.buffers.items[index].is_large;
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
        // Snapshot where we are *before* swapping buffers so the
        // jump_list and the new buffer's `opened_from` field both
        // record the trigger location. Without this, opening
        // [References] / [Help] / etc. leaves no breadcrumb and
        // Space , / Ctrl+O have nothing to walk back to.
        self.recordJumpFromCurrent();
        const from = self.captureCurrentLocation();

        try self.buffer_manager.openVirtual(name, content);
        if (self.split_manager) |*sm| {
            sm.setFocusedBuffer(self.buffer_manager.active_index);
        }

        // Stamp opened_from on the *new* buffer so closing it can
        // restore the trigger position (see closeCurrentPaneOrBuffer).
        if (from) |loc| {
            const idx = self.buffer_manager.active_index;
            if (idx < self.buffer_manager.buffers.items.len) {
                self.buffer_manager.buffers.items[idx].opened_from = .{
                    .buffer_id = loc.buffer_id,
                    .row = loc.row,
                    .col = loc.col,
                };
            }
        }
    }

    /// Record (current file_path, row, col) into the jump_list.
    /// No-op if the active buffer isn't backed by a file (e.g. a
    /// scratch or virtual buffer — those don't have meaningful
    /// breadcrumbs of their own; the trigger location was already
    /// recorded when the virtual buffer was opened).
    pub fn recordJumpFromCurrent(self: *Core) void {
        const s = self.state();
        const path = s.file_path orelse return;
        self.jump_list.recordJump(path, s.cursor_row, s.cursor_col) catch |err| {
            log.debug("recordJumpFromCurrent failed: {}", .{err});
        };
    }

    /// Snapshot the current cursor location for "opened_from"
    /// metadata. Returns null when the active buffer isn't a real
    /// file, in which case we'd have nothing useful to restore to.
    pub fn captureCurrentLocation(self: *Core) ?BufferLocation {
        const s = self.state();
        const path = s.file_path orelse return null;
        return .{
            .buffer_id = self.buffer_manager.getActive().id,
            .file_path = path,
            .row = s.cursor_row,
            .col = s.cursor_col,
        };
    }

    pub const BufferLocation = struct {
        buffer_id: u32,
        /// Borrowed slice — points into the source buffer's
        /// file_path which outlives the snapshot. Don't store these
        /// past the source buffer's lifetime.
        file_path: []const u8,
        row: usize,
        col: usize,
    };

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

    pub fn insertCharWithHistory(self: *Core, char: u8) !void {
        if (self.rejectReadOnlyPresentationEdit()) return;

        const s = self.state();

        // Single-cursor fast path.
        if (self.multi_cursors.items.len == 0) {
            const offset = s.getOffsetFromCursor();
            self.history_manager.beginTransaction(.{ .row = s.cursor_row, .col = s.cursor_col });
            try s.insertChar(char);
            var char_buf: [1]u8 = .{char};
            try self.history_manager.recordInsert(offset, &char_buf);
            self.history_manager.commitTransaction(.{ .row = s.cursor_row, .col = s.cursor_col });
            return;
        }

        // Multi-cursor: newline breaks the simple shift model — bail
        // to single cursor before inserting so we don't desync.
        if (char == '\n') {
            self.clearMultiCursors();
            const offset = s.getOffsetFromCursor();
            self.history_manager.beginTransaction(.{ .row = s.cursor_row, .col = s.cursor_col });
            try s.insertChar(char);
            var char_buf: [1]u8 = .{char};
            try self.history_manager.recordInsert(offset, &char_buf);
            self.history_manager.commitTransaction(.{ .row = s.cursor_row, .col = s.cursor_col });
            return;
        }

        try self.applyMultiCharInsert(char);
    }

    /// Apply a single (non-newline) char insert at the primary cursor
    /// and each secondary cursor, then shift positions to keep the
    /// secondaries pointing at the right column after the line
    /// rewrites. Processed in descending byte-offset order so earlier
    /// inserts don't invalidate later offsets.
    fn applyMultiCharInsert(self: *Core, char: u8) !void {
        const s = self.state();

        // Build the full position list (primary + secondaries) and
        // tag with byte offsets.
        const PosOff = struct { row: usize, col: usize, off: usize, is_primary: bool };
        var all = std.ArrayListUnmanaged(PosOff).empty;
        defer all.deinit(self.allocator);
        try all.append(self.allocator, .{
            .row = s.cursor_row,
            .col = s.cursor_col,
            .off = s.getOffsetFromCursor(),
            .is_primary = true,
        });
        for (self.multi_cursors.items) |mc| {
            try all.append(self.allocator, .{
                .row = mc.row,
                .col = mc.col,
                .off = s.getOffsetFor(mc.row, mc.col),
                .is_primary = false,
            });
        }

        // Descending offset order: safe insert loop.
        std.sort.block(PosOff, all.items, {}, struct {
            fn lt(_: void, a: PosOff, b: PosOff) bool {
                return a.off > b.off;
            }
        }.lt);

        var char_buf: [1]u8 = .{char};
        self.history_manager.beginTransaction(.{ .row = s.cursor_row, .col = s.cursor_col });
        for (all.items) |po| {
            try s.insertTextAtOffset(po.off, &char_buf);
            try self.history_manager.recordInsert(po.off, &char_buf);
        }
        self.history_manager.commitTransaction(.{ .row = s.cursor_row, .col = s.cursor_col });

        // Compute each cursor's new column: self-advance by 1, plus +1
        // for every OTHER cursor that sat at a lower col on the same row
        // (those inserts pushed this cursor's content right).
        for (all.items) |*po| {
            var shift: usize = 1;
            for (all.items) |q| {
                if (q.off == po.off and q.is_primary == po.is_primary) continue;
                if (q.row == po.row and q.col < po.col) shift += 1;
            }
            po.col += shift;
        }

        // Write back: primary into EditorState, secondaries into list.
        self.multi_cursors.clearRetainingCapacity();
        for (all.items) |po| {
            if (po.is_primary) {
                s.cursor_row = po.row;
                s.cursor_col = po.col;
                s.preferred_col = null;
            } else {
                self.multi_cursors.append(self.allocator, .{ .row = po.row, .col = po.col }) catch continue;
            }
        }
        self.refreshMultiCursorDecorations();
    }

    pub fn insertTextWithHistory(self: *Core, text: []const u8) !void {
        if (self.rejectReadOnlyPresentationEdit()) return;

        const s = self.state();
        const offset = s.getOffsetFromCursor();
        self.history_manager.beginTransaction(.{ .row = s.cursor_row, .col = s.cursor_col });
        try s.insertTextAtCursor(text);
        try self.history_manager.recordInsert(offset, text);
        self.history_manager.commitTransaction(.{ .row = s.cursor_row, .col = s.cursor_col });
    }

    fn buildNewlineInsertion(self: *Core) !struct { text: []u8, cursor_after_offset: usize } {
        const s = self.state();
        const offset = s.getOffsetFromCursor();

        var base_indent: usize = 0;
        var extra_indent: usize = 0;
        var need_closing_line = false;

        if (s.file_path) |path| {
            if (std.mem.endsWith(u8, path, ".zig")) {
                const line_content = try s.getLineContent(s.cursor_row);
                defer self.allocator.free(line_content);

                for (line_content) |c| {
                    if (c == ' ') {
                        base_indent += 1;
                    } else if (c == '\t') {
                        base_indent += 4;
                    } else {
                        break;
                    }
                }

                if (offset > 0) {
                    const char_before = s.getCharAtOffset(offset - 1);
                    if (char_before == '{' or char_before == '(' or char_before == '[') {
                        extra_indent = 4;
                    }
                }

                const char_after = s.getCharAtOffset(offset);
                need_closing_line = (char_after == '}' or char_after == ')' or char_after == ']') and extra_indent > 0;
            }
        }

        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(self.allocator);

        try out.append(self.allocator, '\n');
        var i: usize = 0;
        while (i < base_indent + extra_indent) : (i += 1) {
            try out.append(self.allocator, ' ');
        }
        const cursor_after_offset = offset + out.items.len;

        if (need_closing_line) {
            try out.append(self.allocator, '\n');
            i = 0;
            while (i < base_indent) : (i += 1) {
                try out.append(self.allocator, ' ');
            }
        }

        return .{
            .text = try out.toOwnedSlice(self.allocator),
            .cursor_after_offset = cursor_after_offset,
        };
    }

    pub fn insertNewlineWithHistory(self: *Core) !void {
        if (self.rejectReadOnlyPresentationEdit()) return;

        const s = self.state();
        const offset = s.getOffsetFromCursor();
        const insertion = try self.buildNewlineInsertion();
        defer self.allocator.free(insertion.text);

        self.history_manager.beginTransaction(.{ .row = s.cursor_row, .col = s.cursor_col });
        try s.insertTextAtCursor(insertion.text);
        s.updateCursorFromOffset(insertion.cursor_after_offset);
        try self.history_manager.recordInsert(offset, insertion.text);
        self.history_manager.commitTransaction(.{ .row = s.cursor_row, .col = s.cursor_col });
    }

    pub fn insertTabWithHistory(self: *Core, tab_size: u32) !void {
        const count: usize = @intCast(tab_size);
        const spaces = try self.allocator.alloc(u8, count);
        defer self.allocator.free(spaces);
        @memset(spaces, ' ');
        try self.insertTextWithHistory(spaces);
    }

    pub fn smartAutoPairBackspaceWithHistory(self: *Core) !bool {
        if (self.rejectReadOnlyPresentationEdit()) return false;

        const s = self.state();
        const char_before = s.getCharBeforeCursor();
        const char_after = s.getCharAfterCursor();

        for (auto_pair.STANDARD_PAIRS) |pair| {
            if (char_before == pair.open and char_after == pair.close) {
                const offset = s.getOffsetFromCursor();
                if (offset == 0) return false;
                const deleted = [_]u8{ char_before, char_after };
                self.history_manager.beginTransaction(.{ .row = s.cursor_row, .col = s.cursor_col });
                try self.history_manager.recordDelete(offset - 1, &deleted);
                try s.deleteRange(offset - 1, offset + 1);
                self.history_manager.commitTransaction(.{ .row = s.cursor_row, .col = s.cursor_col });
                return true;
            }
        }

        return false;
    }

    pub fn autoPairCharWithHistory(
        self: *Core,
        char: u8,
        config: auto_pair.AutoPairConfig,
    ) !enum { inserted, skipped, wrapped } {
        if (self.rejectReadOnlyPresentationEdit()) return .skipped;

        const s = self.state();
        if (!config.enabled) return .inserted;

        if (auto_pair.shouldSkipClosingChar(s, char)) {
            try s.moveCursorRightGrapheme();
            return .skipped;
        }

        if (auto_pair.isOpeningChar(char)) |pair| {
            if (config.wrap_selection and s.selection_anchor != null) {
                const range = auto_pair.getSelectionRange(s) orelse return .inserted;
                const open_str = [_]u8{pair.open};
                const close_str = [_]u8{pair.close};

                self.history_manager.beginTransaction(.{ .row = s.cursor_row, .col = s.cursor_col });
                try s.insertTextAtOffset(range.end, &close_str);
                try self.history_manager.recordInsert(range.end, &close_str);
                try s.insertTextAtOffset(range.start, &open_str);
                try self.history_manager.recordInsert(range.start, &open_str);
                s.updateCursorFromOffset(range.end + 2);
                s.selection_anchor = null;
                self.history_manager.commitTransaction(.{ .row = s.cursor_row, .col = s.cursor_col });
                return .wrapped;
            }

            const offset = s.getOffsetFromCursor();
            const pair_text = [_]u8{ pair.open, pair.close };
            self.history_manager.beginTransaction(.{ .row = s.cursor_row, .col = s.cursor_col });
            try s.insertTextAtCursor(&pair_text);
            try self.history_manager.recordInsert(offset, &pair_text);
            try s.moveCursorLeftGrapheme();
            self.history_manager.commitTransaction(.{ .row = s.cursor_row, .col = s.cursor_col });
            return .inserted;
        }

        return .inserted;
    }

    pub fn deleteCharWithHistory(self: *Core) !void {
        if (self.rejectReadOnlyPresentationEdit()) return;

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

    pub fn backspaceCharWithHistory(self: *Core) !void {
        if (self.rejectReadOnlyPresentationEdit()) return;

        const s = self.state();

        // Single-cursor fast path.
        if (self.multi_cursors.items.len == 0) {
            const offset = s.getOffsetFromCursor();
            if (offset == 0) return;
            const deleted_char = s.buffer.getCharAt(offset - 1) orelse return;
            var char_buf: [1]u8 = .{deleted_char};
            self.history_manager.beginTransaction(.{ .row = s.cursor_row, .col = s.cursor_col });
            try self.history_manager.recordDelete(offset - 1, &char_buf);
            try s.backspaceChar();
            self.history_manager.commitTransaction(.{ .row = s.cursor_row, .col = s.cursor_col });
            return;
        }

        // Multi-cursor backspace skips cursors at column 0 (line-join
        // semantics would desync the secondaries). Apply in descending
        // offset order so the deletes don't shift earlier offsets.
        const PosOff = struct { row: usize, col: usize, off: usize, is_primary: bool };
        var all = std.ArrayListUnmanaged(PosOff).empty;
        defer all.deinit(self.allocator);
        try all.append(self.allocator, .{
            .row = s.cursor_row,
            .col = s.cursor_col,
            .off = s.getOffsetFromCursor(),
            .is_primary = true,
        });
        for (self.multi_cursors.items) |mc| {
            try all.append(self.allocator, .{
                .row = mc.row,
                .col = mc.col,
                .off = s.getOffsetFor(mc.row, mc.col),
                .is_primary = false,
            });
        }
        std.sort.block(PosOff, all.items, {}, struct {
            fn lt(_: void, a: PosOff, b: PosOff) bool {
                return a.off > b.off;
            }
        }.lt);

        self.history_manager.beginTransaction(.{ .row = s.cursor_row, .col = s.cursor_col });
        var applied: usize = 0;
        for (all.items) |*po| {
            if (po.col == 0) continue; // skip line-join case
            if (po.off == 0) continue;
            const deleted = s.buffer.getCharAt(po.off - 1) orelse continue;
            var char_buf: [1]u8 = .{deleted};
            try self.history_manager.recordDelete(po.off - 1, &char_buf);
            try s.deleteRangeAtOffset(po.off - 1, po.off);
            applied += 1;
        }
        self.history_manager.commitTransaction(.{ .row = s.cursor_row, .col = s.cursor_col });

        // Update positions: each retreats by 1 col, plus -1 for every
        // other cursor that backspaced at a lower col on the same row.
        for (all.items) |*po| {
            if (po.col == 0) continue;
            var shift: usize = 1;
            for (all.items) |q| {
                if (q.off == po.off and q.is_primary == po.is_primary) continue;
                if (q.col == 0) continue;
                if (q.row == po.row and q.col < po.col) shift += 1;
            }
            po.col -|= shift;
        }

        self.multi_cursors.clearRetainingCapacity();
        for (all.items) |po| {
            if (po.is_primary) {
                s.cursor_row = po.row;
                s.cursor_col = po.col;
                s.preferred_col = null;
            } else {
                self.multi_cursors.append(self.allocator, .{ .row = po.row, .col = po.col }) catch continue;
            }
        }
        self.refreshMultiCursorDecorations();
    }

    pub fn deleteRangeWithHistory(self: *Core, start_offset: usize, end_offset: usize) !void {
        if (self.rejectReadOnlyPresentationEdit()) return;
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

    // cmdDocumentSymbols, cmdWorkspaceSymbols → commands/lsp_commands.zig
    // cmdBookmarkList, cmdBookmarkClearAll → commands/bookmark_commands.zig
    // All registered via the Wrap(...).run adapter — see registerCommands.

    // Editor-toggle commands extracted to commands/toggle_commands.zig
    // — see ToggleCommands.cmd* there. Registered via the same
    // Wrap(...).run adapter the other commands/*.zig modules use.

    /// Cheap precondition for format-on-save: do we even have an LSP
    /// class for this file's language? If not, skip the formatter
    /// request entirely so .txt and friends don't pay a 100 ms wait
    /// on every save. We don't check the running server's formatting
    /// capability — `formatAndSave` already times out gracefully if
    /// the server doesn't reply, and falls through to plain save.
    fn canLspFormat(self: *Core, path: []const u8) bool {
        _ = self;
        return LSPManager.getLangFromPath(path) != null;
    }

    /// Pretty-name the LSP symbol kind enum for the picker UI. Same
    /// kinds the document-symbol path uses (file/module/.../method/
    /// .../typeParameter); keep this in sync so the two pickers
    /// display consistently.
    fn symbolKindString(k: LspServer.DocumentSymbol.SymbolKind) []const u8 {
        return switch (k) {
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
    }

    pub fn openWorkspaceSymbolPicker(self: *Core) !void {
        // Jumpable navigation — snapshot the trigger location so
        // Space , can return after picking a symbol.
        self.recordJumpFromCurrent();
        // Reset state, switch mode. The first request goes out empty
        // immediately so the popup has *something* to show; further
        // requests fire as the user types, debounced.
        for (self.workspace_symbol_results.items) |entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.kind);
            self.allocator.free(entry.file_path);
        }
        self.workspace_symbol_results.clearRetainingCapacity();
        self.workspace_symbol_query.clearRetainingCapacity();
        self.workspace_symbol_selected = 0;
        self.workspace_symbol_pending = true;
        self.workspace_symbol_last_request_ms = std.Io.Clock.real.now(self.io).toMilliseconds();

        self.previous_mode = self.mode;
        self.mode = .workspace_symbol_picker;

        // Try to derive a language from the active buffer. If we
        // can't, drop a friendly status toast — workspace symbols
        // need a server.
        const s = self.state();
        if (s.file_path) |path| {
            if (LSPManager.getLangFromPath(path)) |lang| {
                self.lsp_manager.requestWorkspaceSymbol(lang, "") catch |err| {
                    log.warn("workspace symbol request failed: {}", .{err});
                };
            } else {
                self.setStatusLiteralLeveled(.info, "Workspace symbols need an LSP-supported buffer", 2000);
            }
        } else {
            self.setStatusLiteralLeveled(.info, "Open a file in an LSP-supported language first", 2000);
        }
        try self.sendUpdate();
    }

    /// Issue another workspace/symbol request with the current query
    /// after honouring a tiny debounce so typing fast doesn't blast
    /// the server.
    pub fn dispatchWorkspaceSymbolQuery(self: *Core) !void {
        const now = std.Io.Clock.real.now(self.io).toMilliseconds();
        if (now - self.workspace_symbol_last_request_ms < self.workspace_symbol_debounce_ms) return;

        const s = self.state();
        const path = s.file_path orelse return;
        const lang = LSPManager.getLangFromPath(path) orelse return;

        self.workspace_symbol_pending = true;
        self.workspace_symbol_last_request_ms = now;
        self.lsp_manager.requestWorkspaceSymbol(lang, self.workspace_symbol_query.items) catch |err| {
            log.warn("workspace symbol request failed: {}", .{err});
        };
    }

    // cmdJumpBack / cmdJumpForward → commands/nav_commands.zig
    // (NavCommands.cmdJumpBack / .cmdJumpForward)

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
        try R.register("buffer.restore_backups", "Buffer: Restore Backups", "List auto-save backups in ~/.stem/recover/", Wrap(BufferCommands.cmdBufferRestoreBackups).run, null);

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

        try R.register("bookmark.list", "Bookmark: List", "Open the [Bookmarks] buffer", Wrap(BookmarkCommands.cmdBookmarkList).run, null);
        try R.register("bookmark.clear_all", "Bookmark: Clear All", "Remove every set bookmark for this project", Wrap(BookmarkCommands.cmdBookmarkClearAll).run, null);

        try R.register("lsp.format", "LSP: Format Document", "Format the entire file using zls", Wrap(LspCommands.cmdLspFormatDocument).run, null);
        try R.register("lsp.format_selection", "LSP: Format Selection", "Format the visual selection (or current line) via textDocument/rangeFormatting", Wrap(LspCommands.cmdLspFormatSelection).run, null);
        try R.register("lsp.code_action", "LSP: Code Actions", "Show available code actions at the cursor (Space .)", Wrap(LspCommands.cmdLspCodeAction).run, null);
        try R.register("lsp.definition", "LSP: Go to Definition", "Jump to symbol definition", Wrap(LspCommands.cmdLspGoToDefinition).run, null);
        try R.register("lsp.diagnostics", "LSP: Show Diagnostics", "List all errors/warnings for current file", Wrap(LspCommands.cmdLspShowDiagnostics).run, null);
        try R.register("lsp.restart", "LSP: Restart Server", "Force restart the embedded zls instance", Wrap(LspCommands.cmdLspRestartServer).run, null);
        try R.register("lsp.prewarm", "LSP: Prewarm Workspace", "Scan the workspace and start servers for every detected language", Wrap(LspCommands.cmdLspPrewarm).run, null);
        try R.register("lsp.status", "LSP: Status", "Show live LSP server health and restart state", Wrap(LspCommands.cmdLspStatus).run, null);
        try R.register("lsp.hover", "LSP: Hover", "Trigger hover information for symbol under cursor", Wrap(LspCommands.cmdLspHover).run, null);
        try R.register("lsp.references", "LSP: Find References", "Find all references to symbol under cursor", Wrap(LspCommands.cmdLspFindReferences).run, null);
        try R.register("lsp.workspace_symbols", "LSP: Workspace Symbols", "Fuzzy find symbols across the workspace via LSP", Wrap(LspCommands.cmdWorkspaceSymbols).run, null);
        try R.register("lsp.toggle_format_on_save", "LSP: Toggle Format on Save", "Run the LSP formatter automatically before each save", Wrap(ToggleCommands.cmdLspToggleFormatOnSave).run, null);
        try R.register("editor.toggle_inline_diagnostics", "Editor: Toggle Inline Diagnostics", "Show diagnostic messages inline at end-of-line on every affected line (\"error lens\")", Wrap(ToggleCommands.cmdEditorToggleInlineDiagnostics).run, null);
        try R.register("editor.toggle_inlay_hints", "Editor: Toggle Inlay Hints", "Render LSP inlay hints (type annotations, param names) as dim virtual text", Wrap(ToggleCommands.cmdEditorToggleInlayHints).run, null);

        try R.register("mode.insert", "Mode: Insert", "Switch to insert mode", Wrap(SystemCommands.cmdModeInsert).run, null);
        try R.register("mode.visual", "Mode: Visual", "Switch to visual mode", Wrap(SystemCommands.cmdModeVisual).run, null);
        try R.register("mode.terminal", "Mode: Terminal", "Switch to terminal mode", Wrap(SystemCommands.cmdModeTerminal).run, null);
        try R.register("mode.select", "Mode: Select", "Switch to select mode", Wrap(SystemCommands.cmdModeSelect).run, null);

        try R.register("help.show", "Help: Show", "Show editor help", Wrap(SystemCommands.cmdShowHelp).run, null);
        try R.register("plugin.show", "Plugins: List Loaded", "Show plugins currently loaded in the running stem instance", Wrap(SystemCommands.cmdShowPlugins).run, null);
        try R.register("plugin.inspect", "Plugins: Inspect", "Open a capability inspector showing manifest, permissions, restart policy, and live state for every installed plugin", Wrap(PluginCommands.cmdPluginInspect).run, null);
        try R.register("stem.control_center", "Stem: Control Center", "Open a live cockpit for runtime health, project brain, LSPs, jobs, plugins, and message-bus pressure", Wrap(SystemCommands.cmdShowControlCenter).run, null);
        try R.register("project.brain", "Project: Brain", "Show workspace index health, open languages, diagnostics, and LSP coverage", Wrap(SystemCommands.cmdShowProjectBrain).run, null);
        try R.register("stats.show", "Stats: Message Bus", "Live view of stem's Vigil-backed message bus stats", Wrap(SystemCommands.cmdShowStats).run, null);
        try R.register("task.list", "Tasks: List Detected", "Show detected project build/test/run commands for the current workspace", Wrap(SystemCommands.cmdProjectTasks).run, null);
        try R.register("task.run_build", "Tasks: Run Build", "Run the preferred detected build task as a background job", Wrap(SystemCommands.cmdTaskRunBuild).run, null);
        try R.register("task.run_test", "Tasks: Run Test", "Run the preferred detected test task as a background job", Wrap(SystemCommands.cmdTaskRunTest).run, null);
        try R.register("task.run", "Tasks: Run App", "Run the preferred detected run/start task as a background job", Wrap(SystemCommands.cmdTaskRun).run, null);
        try R.register("task.run_dev", "Tasks: Run Dev", "Run the preferred detected dev task as a background job", Wrap(SystemCommands.cmdTaskRunDev).run, null);
        try R.register("task.run_lint", "Tasks: Run Lint", "Run the preferred detected lint task as a background job", Wrap(SystemCommands.cmdTaskRunLint).run, null);
        try R.register("task.run_format", "Tasks: Run Format", "Run the preferred detected format task as a background job", Wrap(SystemCommands.cmdTaskRunFormat).run, null);
        try R.register("task.output", "Tasks: Show Last Output", "Open the retained output from the latest project task job", Wrap(SystemCommands.cmdTaskOutput).run, null);
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
        try R.register("build.run", "Zig: Run", "Run 'zig build run' for current workspace", Wrap(BuildCommands.cmdBuildRun).run, null);
        try R.register("build.output", "Zig: Show Build Output", "Show the last build output", Wrap(BuildCommands.cmdBuildOutput).run, null);
    }

    pub fn run(self: *Core, bus: *@import("message_bus.zig").MessageBus) !void {
        // Language servers are installed on-demand via `stem lsp install <name>`,
        // not eagerly at startup. ZLS is bundled and needs no install.
        const inbox = bus.inbox;
        self.core_inbox = inbox;
        self.core_bus = bus;
        self.plugin_manager.core_inbox = inbox;

        // Install the editor edit-hook now that `self` has a stable
        // address. The trampoline forwards every insert/delete event
        // into `SyntaxManager.recordEdit`, so tree-sitter's next
        // parse can use `ts_tree_edit` against the prior tree and
        // reuse subtrees outside the changed range. Set it on the
        // factory so every buffer created from here on inherits it,
        // and refresh any buffers opened during Core.init.
        self.buffer_manager.default_edit_hook = .{
            .ctx = @ptrCast(self),
            .call = coreEditHookTrampoline,
        };
        self.buffer_manager.refreshEditHooks();
        // Editor hooks so wasm plugins can synchronously read the
        // active buffer's content/path via `stem_get_buffer_*`.
        self.plugin_manager.setHostHooks(.{
            .user_data = @ptrCast(self),
            .get_buffer_content = coreGetBufferContent,
            .get_buffer_path = coreGetBufferPath,
            .request_render = coreRequestRender,
        });
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
                    self.workspace_manager.registerBuffer(opened_buffer.id, path) catch |err| {
                        log.debug("workspace registerBuffer failed for {s}: {s}", .{ path, @errorName(err) });
                    };
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

        // Scan the workspace and start LSPs for every language that
        // appears in the project — not just languages of currently-open
        // buffers. This covers the "user opens stem on a polyglot repo
        // and the first hover on a new language is slow" case: by the
        // time they switch buffers, the relevant server is initializing
        // (or done) in the background.
        if (std.Io.Dir.cwd().realPathFileAlloc(self.io, ".", self.allocator)) |cwd| {
            defer self.allocator.free(cwd);
            _ = self.lsp_manager.prewarmWorkspaceLanguages(cwd) catch |err| {
                std.log.warn("LSP workspace prewarm failed: {}", .{err});
            };
            // Kick off the workspace file-list index. Detached
            // worker; first `:Find` query that arrives within the
            // first ~few hundred ms still pays the walk, but every
            // subsequent query skips it.
            self.search_index.startIndexing(cwd) catch |err| {
                std.log.warn("Search index startup failed: {}", .{err});
            };
            // Bind bookmarks to this project so set/get persists across
            // restarts. Failure here is non-fatal — bookmarks just stay
            // in-memory for the session.
            if (self.homeDir()) |home| {
                defer self.allocator.free(home);
                self.bookmarks.attachProject(self.io, home, cwd) catch |err| {
                    log.warn("Bookmark store attach failed: {}", .{err});
                };
            } else |_| {}
        } else |_| {}

        // Eagerly send `didOpen` for the active buffer so the LSP is aware
        // of the document the user is about to edit. This queues through
        // the supervisor (FIFO), so it runs right after the matching
        // `start_server` from prespawn finishes — by the time the user
        // hovers/completes, the doc is already known to the server.
        self.eagerlyOpenActiveBuffer();

        // Surface any orphaned auto-save backups from a previous crash
        // before the first render so the user notices the toast right
        // away (vs. discovering it deep in a command-palette walk).
        self.surfaceOrphanBackups();

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
                            const reply = protocol.PluginMessage{
                                .plugin_id = pm.plugin_id,
                                .message_type = .state_response,
                                .payload = .{ .state = state_view },
                                .correlation_id = pm.correlation_id,
                            };
                            // Manager-owned JSON encoder will frame and
                            // dispatch via the right process plugin.
                            self.replyPluginRequest(reply) catch |err| log.debug("plugin reply send failed: {s}", .{@errorName(err)});
                        } else if (pm.message_type == .get_buffer_content) {
                            const active_buf = self.buffer_manager.getActive();
                            const content = active_buf.state.buffer.toString(self.allocator) catch "";
                            defer self.allocator.free(content);
                            const reply = protocol.PluginMessage{
                                .plugin_id = pm.plugin_id,
                                .message_type = .buffer_content_response,
                                .payload = .{ .buffer_content_response = .{ .id = active_buf.id, .content = content } },
                                .correlation_id = pm.correlation_id,
                            };
                            self.replyPluginRequest(reply) catch |err| log.debug("plugin reply send failed: {s}", .{@errorName(err)});
                        } else if (pm.message_type == .get_plugin_list) {
                            const reply = protocol.PluginMessage{
                                .plugin_id = pm.plugin_id,
                                .message_type = .get_plugin_list_response,
                                .payload = .{ .plugin_list_data = "" }, // free-form; manager populates the JSON
                                .correlation_id = pm.correlation_id,
                            };
                            self.replyPluginRequest(reply) catch |err| log.debug("plugin reply send failed: {s}", .{@errorName(err)});
                        } else if (pm.message_type == .load_plugin) {
                            const target = pm.payload.plugin_load;
                            self.plugin_manager.loadPluginByName(target) catch |err| {
                                log.warn("plugin '{s}' load failed: {s}", .{ target, @errorName(err) });
                            };
                            self.sendUpdate() catch |err| log.debug("sendUpdate after plugin msg failed: {s}", .{@errorName(err)});
                        } else if (pm.message_type == .unload_plugin) {
                            const target = pm.payload.plugin_unload;
                            self.plugin_manager.unloadPlugin(target) catch |err| {
                                log.warn("plugin '{s}' unload failed: {s}", .{ target, @errorName(err) });
                            };
                            self.sendUpdate() catch |err| log.debug("sendUpdate after plugin msg failed: {s}", .{@errorName(err)});
                        } else if (pm.message_type == .show_notification) {
                            // Plugin notification — fold into the
                            // status bar with a 4-second TTL. Prefix
                            // with `[plugin] ` so the source is
                            // visible.
                            const notif = pm.payload.notification;
                            const tag: []const u8 = switch (notif.level) {
                                .warning => "WARN",
                                .err => "ERR",
                                else => "INFO",
                            };
                            const written = std.fmt.bufPrint(
                                &self.plugin_notification_buf,
                                "[{s}] {s}: {s}",
                                .{ tag, pm.plugin_id, notif.message },
                            ) catch self.plugin_notification_buf[0..0];
                            self.status_message = written;
                            self.status_message_expires =
                                std.Io.Clock.real.now(self.io).toMilliseconds() + 4_000;
                            self.sendUpdate() catch |err| log.debug("sendUpdate after plugin msg failed: {s}", .{@errorName(err)});
                        }
                        // Other PluginMessage variants are unused —
                        // wasm plugins call host imports directly and
                        // exec plugins use JSON-RPC, so command
                        // registration, status items, panels and
                        // event subs all route through those paths
                        // and never reach this dispatch.
                    },
                    .tick => {
                        // Drain any paths discovered by background directory
                        // scanners into the buffer list. Bounded per tick.
                        self.drainScanPaths();

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

                        // Drain any debounced LSP didChange payloads
                        // whose debounce window has elapsed. Without
                        // this drive, the trailing-edge debounce never
                        // fires on a paused user.
                        self.lsp_manager.flushPendingChanges();

                        // Refresh the word-under-cursor highlight. Only
                        // applies after `word_highlight_idle_ms` of
                        // cursor stillness, so fast scrolling doesn't
                        // flash decorations across the viewport.
                        self.maybeRefreshWordHighlight();

                        // Auto-cancel a leader chord that's been sitting
                        // armed past `leader_pending_timeout_ms` —
                        // matches vim's `timeoutlen`. Without this, a
                        // chord left dangling (user walked away mid-
                        // chord, lost focus, hit Space accidentally,
                        // etc.) stays armed and surprises the next
                        // keystroke they make.
                        self.maybeTimeoutLeaderChord();

                        // Hover and which-key are both user-driven —
                        // the auto-hover idle timer used to fire
                        // here, but it stole focus on small terminals
                        // every time the cursor paused over a word.
                        // Hover now only appears via `Space h`.

                        // Drain any in-flight workspace/symbol
                        // response so the picker updates without
                        // waiting for user input.
                        if (self.workspace_symbol_pending) {
                            if (self.lsp_manager.popWorkspaceSymbolsResult()) |syms| {
                                defer self.lsp_manager.freeWorkspaceSymbols(syms);
                                self.workspace_symbol_pending = false;

                                for (self.workspace_symbol_results.items) |entry| {
                                    self.allocator.free(entry.name);
                                    self.allocator.free(entry.kind);
                                    self.allocator.free(entry.file_path);
                                }
                                self.workspace_symbol_results.clearRetainingCapacity();

                                const max_show: usize = 200;
                                for (syms, 0..) |sym, i| {
                                    if (i >= max_show) break;
                                    const kind_str = symbolKindString(sym.kind);
                                    const name_dup = try self.allocator.dupe(u8, sym.name);
                                    const kind_dup = try self.allocator.dupe(u8, kind_str);
                                    const path_dup = try self.allocator.dupe(u8, sym.file_path);
                                    try self.workspace_symbol_results.append(self.allocator, .{
                                        .name = name_dup,
                                        .kind = kind_dup,
                                        .file_path = path_dup,
                                        .line = sym.line,
                                        .col = sym.col,
                                    });
                                }
                                if (self.workspace_symbol_selected >= self.workspace_symbol_results.items.len) {
                                    self.workspace_symbol_selected = 0;
                                }
                                self.requestRender();
                            }
                        }

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
                                const trimmed = std.mem.trim(u8, content, " \t\r\n");
                                if (trimmed.len == 0) {
                                    // Whitespace-only response → treat
                                    // as "no hover here". Free the
                                    // content and stay silent on auto,
                                    // toast on sticky.
                                    self.allocator.free(content);
                                    if (self.hover_sticky) {
                                        self.dismissHover();
                                        self.setStatusLiteralLeveled(.info, "No hover information here", 1500);
                                    } else {
                                        self.dismissHover();
                                    }
                                    self.requestRender();
                                } else {
                                    if (self.hover_content) |old| self.allocator.free(old);
                                    self.hover_content = content;
                                    // Re-parse into the structured form.
                                    // Failures keep the raw text around
                                    // so the popup still has something
                                    // to show.
                                    if (self.hover_doc) |*old| old.deinit();
                                    self.hover_doc = hover_doc_mod.parse(self.allocator, content) catch null;
                                    self.hover_scroll_offset = 0;
                                    self.requestRender();
                                }
                            } else {
                                // Time out hover requests that never get
                                // answered (LSP returned null, server
                                // died, no language support). Without
                                // this, a stuck request leaves a
                                // permanent "Loading…" popup. 3 s is
                                // long enough that a slow server still
                                // works, short enough that the user
                                // doesn't notice the empty state.
                                const elapsed = std.Io.Clock.real.now(self.io).toMilliseconds() - self.hover_request_sent_ms;
                                if (elapsed > 3000) {
                                    self.hover_pending = false;
                                    if (self.hover_sticky and self.hover_content == null and self.hover_doc == null) {
                                        // Sticky request with no
                                        // result: drop the loading
                                        // popup and let the user know.
                                        self.dismissHover();
                                        self.setStatusLiteralLeveled(.info, "No hover information here", 1500);
                                    }
                                    self.requestRender();
                                }
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
                                        // Don't push large buffers to LSP — see
                                        // `ensureLspDocument` for the same gate.
                                        if (!self.activeBufferIsLarge()) {
                                            const content = new_state.buffer.toString(self.allocator) catch continue;
                                            defer self.allocator.free(content);
                                            self.lsp_manager.documentOpened(path, content) catch |err| {
                                                log.warn("LSP document sync failed for '{s}': {}", .{ path, err });
                                            };
                                        }
                                    }
                                }

                                const target_state = self.state();
                                target_state.cursor_row = location.line;
                                target_state.cursor_col = location.col;
                                target_state.preferred_col = null;

                                const visible_rows: usize = if (self.win_size.rows > 2) self.win_size.rows - 2 else 1;
                                const half = visible_rows / 2;
                                if (target_state.cursor_row >= half) {
                                    target_state.scroll_offset = target_state.cursor_row - half;
                                } else {
                                    target_state.scroll_offset = 0;
                                }
                                const dest_name = std.fs.path.basename(location.file_path);
                                self.setStatus("Jumped to {s}:{d}", .{ dest_name, location.line + 1 }, 1500);
                                self.requestRender();
                            }
                        }

                        if (self.references_pending) {
                            if (self.lsp_manager.popReferencesResult()) |refs| {
                                self.references_pending = false;
                                defer self.lsp_manager.freeReferences(refs);

                                if (refs.len > 0) {
                                    ReferencesPicker.open(self, refs) catch |err| {
                                        log.warn("Failed to open references picker: {}", .{err});
                                        self.setStatusLiteralLeveled(.err, "Failed to load references", 2000);
                                    };
                                    self.setStatus("Found {d} reference{s}", .{ refs.len, if (refs.len == 1) "" else "s" }, 2000);
                                    try self.sendUpdate();
                                } else {
                                    self.setStatusLiteralLeveled(.warning, "No references found", 2000);
                                    self.requestRender();
                                }
                            } else {
                                // No response yet — give up after the
                                // timeout. Catches the case where the
                                // LSP doesn't support
                                // textDocument/references for this
                                // language, or the server died
                                // mid-request. Without this the user
                                // sees "Looking up references…" once
                                // and then nothing else, ever.
                                const elapsed = std.Io.Clock.real.now(self.io).toMilliseconds() - self.references_request_sent_ms;
                                if (elapsed > self.references_timeout_ms) {
                                    self.references_pending = false;
                                    self.setStatusLiteralLeveled(.warning, "No response from language server", 2500);
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

                        // Drain signature help responses. Replaces any
                        // current popup; if the server returned a null
                        // (no signature here, e.g. after `)`), the pop
                        // returns null and we keep showing the previous
                        // one until the user dismisses.
                        if (self.signature_help_pending) {
                            if (self.lsp_manager.popSignatureHelpResult()) |sh| {
                                self.signature_help_pending = false;
                                if (self.signature_help) |old| self.lsp_manager.freeSignatureHelp(old);
                                self.signature_help = sh;
                                self.requestRender();
                            }
                        }

                        // Drain any plugins that crashed since the
                        // last tick. Cleanup runs on the main loop so
                        // the dying plugin's reader thread is fully
                        // unwound by the time we destroy its state.
                        if (self.plugin_manager.drainPendingExits() > 0) {
                            self.requestRender();
                        }
                        // Same pattern for crashed plugins whose
                        // backoff window has elapsed — restart on
                        // the main loop so we never spawn from a
                        // reader thread that's still unwinding.
                        if (self.plugin_manager.drainPendingRestarts() > 0) {
                            self.requestRender();
                        }

                        // Periodic crash recovery snapshot. Cheap
                        // (a single session.save), runs at most once
                        // every `recovery_interval_ms` so an idle
                        // editor doesn't churn its disk for nothing.
                        {
                            const rnow = std.Io.Clock.real.now(self.io).toMilliseconds();
                            if (rnow - self.last_recovery_ms >= self.recovery_interval_ms) {
                                self.writeRecoverySnapshot();
                                self.last_recovery_ms = rnow;
                            }
                        }

                        if (self.needs_render) {
                            const now = std.Io.Clock.real.now(self.io).toMilliseconds();
                            const time_since_render = now - self.last_render_time;
                            if (time_since_render >= self.min_render_interval_ms) {
                                // Don't advance `last_render_time` or
                                // clear `needs_render` here — sendUpdate
                                // owns both fields. The bug we hit
                                // before: this branch set
                                // `last_render_time = now`, then
                                // sendUpdate's own throttle saw
                                // ~0 ms elapsed and bailed, so the
                                // tree-update post-buffer-switch
                                // render never actually painted.
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

                        // Hover dispatch runs before mode-specific input.
                        // Two cases:
                        //   - sticky hover (Space h): intercept scroll
                        //     keys + Esc; everything else falls
                        //     through after dismiss.
                        //   - auto hover (idle timer): any keypress
                        //     dismisses and falls through.
                        if (self.hoverVisible()) {
                            if (self.hover_sticky) {
                                if (self.tryHoverScroll(key)) {
                                    try self.sendUpdate();
                                    continue;
                                }
                                if (key.matches(vaxis.Key.escape, .{})) {
                                    self.dismissHover();
                                    try self.sendUpdate();
                                    continue;
                                }
                            }
                            // Auto hover, or sticky hover + non-scroll
                            // non-Esc key: dismiss and let the key fall
                            // through to normal handling.
                            self.dismissHover();
                            try self.sendUpdate();
                        }

                        if (key.matches(vaxis.Key.escape, .{})) {
                            // Cancelling a leader chord is the most
                            // common reason a Select-mode user hits
                            // Esc, but the per-mode dispatch below
                            // early-returns before the leader switch
                            // gets a chance to clear the flag. Catch
                            // it up here so the which-key popup
                            // closes immediately and a future Space
                            // starts fresh.
                            if (self.leader_pending) {
                                self.leader_pending = false;
                                self.leader_help_requested = false;
                                self.leader_number_input.clearRetainingCapacity();
                                self.plugin_chord_buf.clearRetainingCapacity();
                                try self.sendUpdate();
                                continue;
                            }
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
                            } else if (self.mode == .workspace_symbol_picker) {
                                self.mode = self.previous_mode;
                                self.workspace_symbol_query.clearRetainingCapacity();
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
                                const result = input.select.handle(self, key) catch |err| {
                                    _ = try handleUserQuitInputError(self, err);
                                    return;
                                };
                                if (result) {
                                    try self.sendUpdate();
                                }
                            },
                            .visual => {
                                if (try input.visual.handle(self, key)) {
                                    try self.sendUpdate();
                                }
                            },
                            .insert => {
                                if (try input.insert.handle(self, key)) {
                                    try self.sendUpdate();
                                }
                            },
                            .view => {
                                const result = input.view.handle(self, key) catch |err| {
                                    _ = try handleUserQuitInputError(self, err);
                                    return;
                                };
                                if (result) {
                                    try self.sendUpdate();
                                }
                            },
                            .terminal => {
                                try input.terminal.handle(self, key);
                                try self.sendUpdate();
                            },
                            .file_picker => {
                                if (try input.file_picker.handle(self, key)) {
                                    try self.sendUpdate();
                                }
                            },
                            .file_explorer => {
                                if (try input.file_explorer.handle(self, key)) {
                                    try self.sendUpdate();
                                }
                            },
                            .references_picker => {
                                if (try ReferencesPicker.handleInput(self, key)) {
                                    try self.sendUpdate();
                                }
                            },
                            .diagnostics_picker => {
                                if (try DiagnosticsPicker.handleInput(self, key)) {
                                    try self.sendUpdate();
                                }
                            },
                            .buffer_picker => {
                                if (try input.buffer_picker.handle(self, key)) {
                                    try self.sendUpdate();
                                }
                            },
                            .save_as_mode => {
                                if (try input.save_as.handle(self, key)) {
                                    try self.sendUpdate();
                                }
                            },
                            .visual_search => {
                                if (try input.visual_search.handle(self, key)) {
                                    try self.sendUpdate();
                                }
                            },
                            .command_palette => {
                                if (try input.command_palette.handle(self, key)) {
                                    try self.sendUpdate();
                                }
                            },
                            .go_to_line => {
                                if (try input.go_to_line.handle(self, key)) {
                                    try self.sendUpdate();
                                }
                            },
                            .symbol_picker => {
                                if (try input.symbol_picker.handle(self, key)) {
                                    try self.sendUpdate();
                                }
                            },
                            .workspace_symbol_picker => {
                                if (try input.workspace_symbol_picker.handle(self, key)) {
                                    try self.sendUpdate();
                                }
                            },
                            .global_search => {
                                if (try input.global_search.handle(self, key)) {
                                    try self.sendUpdate();
                                }
                            },
                        }
                    },

                    .mouse => |mouse| {
                        // Mouse activity dismisses an auto-hover —
                        // the cursor / anchor is about to change.
                        // Sticky hover survives mouse so the user can
                        // scroll the popup with the wheel later.
                        if (self.hoverVisible() and !self.hover_sticky) {
                            self.dismissHover();
                        }
                        // Anything that isn't a wheel event counts as
                        // a deliberate move — reset the idle timer so
                        // auto-hover doesn't fire immediately after a
                        // click.
                        self.last_cursor_move_time = std.Io.Clock.real.now(self.io).toMilliseconds();

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

                        // Sticky hover claims the scroll wheel — the
                        // user is reading docs; scrolling the buffer
                        // would feel wrong.
                        if (self.hover_sticky and self.hoverVisible()) {
                            if (mouse.button == .wheel_up) {
                                self.hover_scroll_offset -|= 1;
                                try self.sendUpdate();
                                continue;
                            } else if (mouse.button == .wheel_down) {
                                self.hover_scroll_offset +|= 1;
                                try self.sendUpdate();
                                continue;
                            }
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
                                    s.preferred_col = null;

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
                                    s.preferred_col = null;
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
                                    s.preferred_col = null;

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
                            .open => try self.openFileExplorer(),
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
                                self.recordJumpFromCurrent();
                                self.syncStateToPane();
                                self.buffer_manager.nextBuffer();
                                self.refreshSyntaxForCurrentBuffer();
                                if (self.split_manager) |*sm| sm.setFocusedBuffer(self.buffer_manager.active_index);
                                self.syncPaneToState();
                            },
                            .prev_buffer => {
                                self.recordJumpFromCurrent();
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

    // handleSelectInput → kernel/input/select.zig

    pub fn enterIncrementalSearch(self: *Core, prev_mode: protocol.Mode, direction: enum { forward, backward }) !void {
        self.previous_mode = prev_mode;
        self.mode = .visual_search;
        self.search_input.clearRetainingCapacity();
        self.search_direction = if (direction == .forward) .forward else .backward;
        const s = self.state();
        self.search_origin_row = s.cursor_row;
        self.search_origin_col = s.cursor_col;
        self.search_match_count = 0;
        self.search_match_index = 0;
    }

    // handleVisualInput → kernel/input/visual.zig

    // handleVisualSearchInput → kernel/input/visual_search.zig

    /// Move the cursor to the closest match in `search_direction`
    /// starting from `search_origin_*`. Called on every keystroke
    /// during the search prompt so the user can preview where Enter
    /// will land. Wraps at file boundaries.
    pub fn jumpToIncrementalMatch(self: *Core) void {
        const query = self.search_input.items;
        if (query.len == 0) {
            const s = self.state();
            s.cursor_row = self.search_origin_row;
            s.cursor_col = self.search_origin_col;
            self.search_match_count = 0;
            self.search_match_index = 0;
            return;
        }
        const s = self.state();
        const target = self.findMatchSmartCase(query, self.search_origin_row, self.search_origin_col, self.search_direction);
        if (target) |pos| {
            s.cursor_row = pos.row;
            s.cursor_col = pos.col;
            s.preferred_col = null;
            self.recenterIfOffscreen();
            self.updateSearchMatchCounters();
        }
    }

    const MatchPos = struct { row: usize, col: usize };

    /// Smart-case match scan across the whole buffer. Returns the
    /// closest match in the requested direction, wrapping at file
    /// boundaries. Walks per-line so the comparison can be
    /// case-insensitive cheaply. Bounded by `max_buffer_search_matches`
    /// indirectly via line iteration; for the common interactive case
    /// this is well under a millisecond.
    fn findMatchSmartCase(
        self: *Core,
        query: []const u8,
        from_row: usize,
        from_col: usize,
        direction: @TypeOf(self.search_direction),
    ) ?MatchPos {
        const s = self.state();
        const total_lines = s.buffer.lineCount();
        if (total_lines == 0 or query.len == 0) return null;
        const case_sensitive = querySensitive(query);

        switch (direction) {
            .forward => {
                // Pass 1: scan from (from_row, from_col) to EOF.
                var line_num = from_row;
                while (line_num < total_lines) : (line_num += 1) {
                    if (lineMatch(self, line_num, query, case_sensitive, if (line_num == from_row) from_col else 0, .forward)) |col| {
                        return .{ .row = line_num, .col = col };
                    }
                }
                // Pass 2: wrap from BOF to (from_row, from_col).
                line_num = 0;
                while (line_num <= from_row) : (line_num += 1) {
                    const limit = if (line_num == from_row) from_col else std.math.maxInt(usize);
                    if (lineMatchBounded(self, line_num, query, case_sensitive, 0, limit)) |col| {
                        return .{ .row = line_num, .col = col };
                    }
                }
            },
            .backward => {
                // Pass 1: scan from (from_row, from_col) backward to BOF.
                var line_num: isize = @intCast(from_row);
                while (line_num >= 0) : (line_num -= 1) {
                    const ln: usize = @intCast(line_num);
                    const limit: usize = if (ln == from_row) from_col else std.math.maxInt(usize);
                    if (lineMatch(self, ln, query, case_sensitive, limit, .backward)) |col| {
                        return .{ .row = ln, .col = col };
                    }
                }
                // Pass 2: wrap from EOF back to (from_row, from_col).
                line_num = @intCast(total_lines - 1);
                while (line_num >= @as(isize, @intCast(from_row))) : (line_num -= 1) {
                    const ln: usize = @intCast(line_num);
                    const start_col: usize = if (ln == from_row) from_col + 1 else 0;
                    if (lineMatchBounded(self, ln, query, case_sensitive, start_col, std.math.maxInt(usize))) |col| {
                        return .{ .row = ln, .col = col };
                    }
                }
            },
        }
        return null;
    }

    fn lineMatch(
        self: *Core,
        line_num: usize,
        query: []const u8,
        case_sensitive: bool,
        from_col: usize,
        dir: enum { forward, backward },
    ) ?usize {
        const s = self.state();
        const line = s.getLineContent(line_num) catch return null;
        defer self.allocator.free(line);
        if (line.len < query.len) return null;
        switch (dir) {
            .forward => {
                var col = from_col;
                while (col + query.len <= line.len) : (col += 1) {
                    const slice = line[col .. col + query.len];
                    const eq = if (case_sensitive)
                        std.mem.eql(u8, slice, query)
                    else
                        asciiEqlIgnoreCase(slice, query);
                    if (eq) return col;
                }
            },
            .backward => {
                if (line.len < query.len) return null;
                const upper = @min(from_col, line.len - query.len + 1);
                var col: isize = @as(isize, @intCast(upper)) - 1;
                while (col >= 0) : (col -= 1) {
                    const uc: usize = @intCast(col);
                    const slice = line[uc .. uc + query.len];
                    const eq = if (case_sensitive)
                        std.mem.eql(u8, slice, query)
                    else
                        asciiEqlIgnoreCase(slice, query);
                    if (eq) return uc;
                }
            },
        }
        return null;
    }

    fn lineMatchBounded(
        self: *Core,
        line_num: usize,
        query: []const u8,
        case_sensitive: bool,
        from_col: usize,
        upper_col_exclusive: usize,
    ) ?usize {
        const s = self.state();
        const line = s.getLineContent(line_num) catch return null;
        defer self.allocator.free(line);
        if (line.len < query.len) return null;
        const upper = @min(upper_col_exclusive, line.len - query.len + 1);
        var col = from_col;
        var best: ?usize = null;
        while (col < upper) : (col += 1) {
            const slice = line[col .. col + query.len];
            const eq = if (case_sensitive)
                std.mem.eql(u8, slice, query)
            else
                asciiEqlIgnoreCase(slice, query);
            if (eq) best = col;
        }
        return best;
    }

    /// Walk the buffer counting all matches and the index of the one
    /// the cursor currently sits in. Bounded by
    /// `max_buffer_search_matches`. Smart-case: if the query has any
    /// uppercase byte, comparison is case-sensitive; otherwise it's
    /// case-insensitive (mirrors ripgrep / Helix).
    fn updateSearchMatchCounters(self: *Core) void {
        const query = self.search_input.items;
        if (query.len == 0) {
            self.search_match_count = 0;
            self.search_match_index = 0;
            return;
        }
        const s = self.state();
        const case_sensitive = querySensitive(query);

        var total: usize = 0;
        var idx: usize = 0;
        const total_lines = s.buffer.lineCount();
        var line_num: usize = 0;
        while (line_num < total_lines and total < self.max_buffer_search_matches) : (line_num += 1) {
            const line = s.getLineContent(line_num) catch continue;
            defer self.allocator.free(line);
            var col: usize = 0;
            while (col + query.len <= line.len) {
                const eq = if (case_sensitive)
                    std.mem.eql(u8, line[col .. col + query.len], query)
                else
                    asciiEqlIgnoreCase(line[col .. col + query.len], query);
                if (eq) {
                    total += 1;
                    if (line_num == s.cursor_row and col == s.cursor_col) {
                        idx = total;
                    }
                    col += query.len;
                    if (total >= self.max_buffer_search_matches) break;
                } else {
                    col += 1;
                }
            }
        }
        self.search_match_count = total;
        self.search_match_index = idx;
    }

    fn querySensitive(q: []const u8) bool {
        for (q) |b| {
            if (b >= 'A' and b <= 'Z') return true;
        }
        return false;
    }

    fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| {
            if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
        }
        return true;
    }

    pub fn updateSearchDecorations(self: *Core) !void {
        self.decoration_manager.removeBySource("search");

        // While the prompt is open we use the live `search_input`;
        // afterwards (Enter committed) we fall back to
        // `last_search_query` so the highlighted matches re-scan
        // each frame against the *current* buffer state. Without
        // the fallback, deleting or pasting near a match left the
        // old highlight stuck at its pre-edit byte position.
        const query = if (self.search_input.items.len > 0)
            self.search_input.items
        else
            self.last_search_query.items;
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

    // handleInsertInput → kernel/input/insert.zig

    pub fn triggerSignatureHelp(self: *Core) !void {
        if (self.activeBufferIsLarge()) return;
        const s = self.state();
        const path = s.file_path orelse return;
        if (LSPManager.getLangFromPath(path) == null) return;
        try self.ensureLspDocument();
        self.lsp_manager.requestSignatureHelp(path, @intCast(s.cursor_row), @intCast(s.cursor_col)) catch |err| {
            log.debug("signatureHelp request failed: {}", .{err});
            return;
        };
        self.signature_help_pending = true;
    }

    pub fn dismissSignatureHelp(self: *Core) void {
        if (self.signature_help) |sh| self.lsp_manager.freeSignatureHelp(sh);
        self.signature_help = null;
        self.signature_help_pending = false;
    }

    pub fn triggerCompletion(self: *Core) !void {
        // Skip in large-file mode — neither the LSP nor the user wants
        // us shoving multi-MB content into the server every keystroke.
        if (self.activeBufferIsLarge()) return;
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

    pub fn dismissCompletion(self: *Core) void {
        self.completion_active = false;
        self.completion_pending = false;
        for (self.completion_items.items) |item| {
            self.allocator.free(item.label);
            if (item.detail) |d| self.allocator.free(d);
        }
        self.completion_items.clearRetainingCapacity();
        self.filtered_completion_items.clearRetainingCapacity();
    }

    pub fn updateCompletionFilter(self: *Core) !void {
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

    pub fn confirmCompletion(self: *Core) !void {
        if (!self.completion_active) return;
        if (self.rejectReadOnlyPresentationEdit()) return;
        if (self.filtered_completion_items.items.len == 0) return;
        if (self.completion_selected >= self.filtered_completion_items.items.len) return;

        const item = self.filtered_completion_items.items[self.completion_selected];

        const s = self.state();
        const prefix_len = s.cursor_col - self.completion_prefix_start;
        if (prefix_len > 0) {
            const start_offset = s.getOffsetFor(s.cursor_row, self.completion_prefix_start);
            try s.deleteRangeAtOffset(start_offset, start_offset + prefix_len);
            s.cursor_col = self.completion_prefix_start;
        }

        try s.insertTextAtCursor(item.label);

        // Send the didChange immediately. Resolve / signature-help
        // queries that fire right after accept (e.g. on the dot the
        // user types next) need the server to know about the inserted
        // text, not see a 100 ms-stale document. The tree-sitter parse
        // inside `sendLspDocChanged` is already async via `submitParse`.
        self.sendLspDocChanged() catch |err| {
            log.debug("LSP didChange after completion accept failed: {}", .{err});
        };
        self.dismissCompletion();
    }

    pub fn markLspDirty(self: *Core) void {
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
        // Large-file mode: skip LSP didChange and tree-sitter reparse
        // entirely. Both would be expensive per-keystroke and the buffer
        // is rendering as plain text anyway.
        if (self.activeBufferIsLarge()) return;
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

                // Hand the parse to the background worker so we never
                // block typing on tree-sitter even when files get
                // large. The worker flips `syntax_manager.tree_updated`
                // when it installs the new tree; Core polls that flag
                // on tick and triggers a render so the new highlights
                // land within a frame or two of the worker finishing.
                const buf_id = self.buffer_manager.getActive().id;
                self.syntax_manager.submitParse(content, buf_id) catch |err| {
                    log.debug("Syntax parse submit failed after edit: {}", .{err});
                };
            }
        }
    }

    // handleViewInput → kernel/input/view.zig

    // handleTerminalInput → kernel/input/terminal.zig

    // handleFilePickerInput → kernel/input/file_picker.zig

    // handleBufferPickerInput → kernel/input/buffer_picker.zig

    // handleSaveAsInput → kernel/input/save_as.zig

    pub fn openFilePicker(self: *Core) !void {
        self.previous_mode = self.mode;
        self.mode = .file_picker;
        try self.file_manager.refresh();
    }

    /// Open the tree-shaped file explorer rooted at the file
    /// manager's cwd (which tracks the project root). Lazily
    /// constructs the FileExplorer on first call so users who
    /// never open it pay nothing.
    pub fn openFileExplorer(self: *Core) !void {
        // Record current location so Space , can walk back if the
        // user opens a file from the tree and wants to return.
        self.recordJumpFromCurrent();
        const FileExplorerMod = @import("file_explorer.zig").FileExplorer;
        if (self.file_explorer == null) {
            self.file_explorer = try FileExplorerMod.init(
                self.allocator,
                self.io,
                self.file_manager.cwd,
            );
        } else {
            // If the cwd moved since last open, re-root.
            const fx = &self.file_explorer.?;
            if (!std.mem.eql(u8, fx.root, self.file_manager.cwd)) {
                fx.deinit();
                self.file_explorer = try FileExplorerMod.init(
                    self.allocator,
                    self.io,
                    self.file_manager.cwd,
                );
            }
        }
        try self.file_explorer.?.rebuild();
        self.previous_mode = self.mode;
        self.mode = .file_explorer;
    }

    /// Dispatch a key that arrived after a leader chord prefix
    /// (e.g. `Space l <key>`, `Space g <key>`). Unknown keys are
    /// silently ignored so the user can bail without typing Esc.
    // Leader chord dispatch + pane focus / close helpers extracted
    // to leader_dispatch.zig. See LeaderDispatch.handle and
    // LeaderDispatch.focusPaneLeft / .focusPaneRight / .focusPaneUp
    // / .focusPaneDown / .closeCurrentPaneOrBuffer.

    // References + diagnostics picker logic extracted to pickers.zig.
    // See ReferencesPicker.open / .close / .handleInput and
    // DiagnosticsPicker.open / .close / .handleInput. State fields
    // (references_picker_*, diagnostics_picker_*) stay on Core
    // because the snapshot builder in sendUpdate reads them.

    /// Thin re-export so the leader dispatch table (and any other
    /// caller that needs to pop the diagnostics picker without
    /// importing pickers.zig directly) can still write the short
    /// `core.openDiagnosticsPicker()` form. New code should call
    /// `DiagnosticsPicker.open(core)` directly.
    pub fn openDiagnosticsPicker(self: *Core) void {
        DiagnosticsPicker.open(self);
    }

    /// Open a file at `path` into a fresh buffer, wire it into the
    /// workspace, start the LSP for its language if applicable, and
    /// fire an async syntax parse. Shared by the fuzzy file picker
    /// and the file explorer so both code paths get identical
    /// behavior (e.g. large-file mode detection, LSP attach).
    pub fn openFileByPath(self: *Core, file_path: []const u8) !void {
        const opened_buffer = try self.buffer_manager.openFile(file_path);
        try self.workspace_manager.registerBuffer(opened_buffer.id, file_path);
        // openFile() reuses an existing buffer entry by setting
        // active_index when the path is already in the list — and
        // an existing entry may still be `not_loaded` (lazy from a
        // directory open / session restore). Force-load now so the
        // user lands on actual content rather than an empty piece-
        // table. No-op when the buffer was already materialized.
        self.buffer_manager.loadBufferContent(opened_buffer) catch |err| {
            log.warn("loadBufferContent failed for {s}: {}", .{ file_path, err });
        };

        const lang = SyntaxManager.Language.fromFilename(file_path);
        const opened_is_large = opened_buffer.is_large;
        if (opened_is_large) {
            self.setStatusLeveled(.warning, "Opened {s} in large-file mode — LSP, syntax, brackets disabled", .{opened_buffer.name}, 3000);
        }

        if (!opened_is_large and (lang == .zig or lang == .python or lang == .javascript or lang == .typescript or lang == .go or lang == .rust)) {
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

        if (lang != .unknown and !opened_is_large) {
            self.syntax_manager.setLanguageEnum(lang) catch |err| {
                log.warn("Syntax manager language set failed for {}: {}", .{ lang, err });
            };
            if (self.state().buffer.toString(self.allocator)) |content| {
                defer self.allocator.free(content);
                const buf_id = self.buffer_manager.getActive().id;
                self.syntax_manager.submitParse(content, buf_id) catch |err| {
                    log.debug("Syntax parse submit failed after buffer load: {}", .{err});
                };
            } else |_| {}
        }

        if (self.split_manager) |*sm| {
            sm.setFocusedBuffer(self.buffer_manager.active_index);
        }
    }

    /// Key dispatch for the modal file-explorer overlay (Mode
    /// `.file_explorer`). Returns true if the key was consumed.
    // handleFileExplorerInput → kernel/input/file_explorer.zig

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
        @import("../services/thread_name.zig").set("stem-scan");
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
        if (take > 0) self.scan_paths.replaceRange(self.allocator, 0, take, &.{}) catch |err| {
            // OOM trimming the scan queue means we'll re-process
            // these paths on the next tick — duplicate work but no
            // correctness issue. Log so a recurring failure shows.
            log.debug("scan_paths trim failed: {s}", .{@errorName(err)});
        };
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
            self.workspace_manager.registerBuffer(0, p) catch |err| {
                log.debug("scan drain: workspace registerBuffer failed for {s}: {s}", .{ p, @errorName(err) });
            };
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
        if (added_any) self.sendUpdate() catch |err| log.debug("sendUpdate after scan drain failed: {s}", .{@errorName(err)});
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
        // Respect `editor.auto_save_backup` — users can opt out if they
        // dislike the periodic disk writes (eg. on battery / network FS).
        if (!self.storage.config.editor.auto_save_backup) return;

        const now = std.Io.Clock.real.now(self.io).toMilliseconds();
        // Honor `editor.auto_save_interval_seconds` over the hardcoded
        // default; falls back to `autosave_interval_ms` if the configured
        // value is zero (would otherwise mean "every tick" — bad idea).
        const cfg_interval_s: i64 = @intCast(self.storage.config.editor.auto_save_interval_seconds);
        const interval_ms: i64 = if (cfg_interval_s > 0) cfg_interval_s * 1000 else self.autosave_interval_ms;
        if (now - self.last_autosave_ms < interval_ms) return;
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
            sf.writeStreamingAll(self.io, path) catch |err| {
                // Failing to write the sidecar isn't fatal — the
                // .bak still holds the content, just without the
                // path-of-origin annotation the recovery picker
                // surfaces. Log so we know if disk space / perm
                // issues are silently eating it.
                log.debug("autosave sidecar write failed for {s}: {s}", .{ sidecar, @errorName(err) });
            };
        }
    }

    /// Count backups in `~/.stem/recover/` (left over from a previous
    /// crash) and post a status hint. Cheap — opens the dir, walks
    /// `.bak` entries, never reads the payloads.
    fn surfaceOrphanBackups(self: *Core) void {
        const home_dir = self.homeDir() catch return;
        defer self.allocator.free(home_dir);
        const recover_dir = std.fs.path.join(self.allocator, &.{ home_dir, ".stem", "recover" }) catch return;
        defer self.allocator.free(recover_dir);

        var dir = std.Io.Dir.openDirAbsolute(self.io, recover_dir, .{ .iterate = true }) catch return;
        defer dir.close(self.io);
        var iter = dir.iterate();
        var count: usize = 0;
        while (iter.next(self.io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".bak")) continue;
            count += 1;
        }
        if (count == 0) return;
        self.setStatusLeveled(.warning, "{d} recovery backup(s) found — run `buffer.restore_backups` to view", .{count}, 6000);
    }

    /// Open a virtual buffer listing every `.bak` in
    /// `~/.stem/recover/`, with its original path (from the sibling
    /// `.path` file) and an mtime. The user can open the original
    /// via the file picker and reconcile; deleting the backup is a
    /// follow-up command. Read-only buffer; this is a recovery
    /// surface, not an editor.
    // cmdBufferRestoreBackups → commands/buffer_commands.zig
    // (BufferCommands.cmdBufferRestoreBackups)

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
            std.fmt.bufPrint(&self.skip_status_buf, "'{s}' changed on disk \u{2014} run file.reload to refresh", .{basename}) catch return;
        self.status_message = msg;
        self.status_message_expires = now + 5_000;
    }

    /// Repaint the word-under-cursor highlight if the cursor has been
    /// still for `word_highlight_idle_ms`. Idempotent — re-walking on
    /// the same word is a no-op (we cache it). Clears immediately when
    /// Auto-cancel the leader chord if it's been armed past the
    /// configured timeout. Matches vim's `timeoutlen` behavior so
    /// users who tap Space and walk away don't return to a
    /// surprise-armed editor. Also clears `leader_chord` so a
    /// dangling sub-prefix (e.g. `Space l` followed by silence)
    /// doesn't intercept the next keystroke.
    fn maybeTimeoutLeaderChord(self: *Core) void {
        if (!self.leader_pending) return;
        const now = std.Io.Clock.real.now(self.io).toMilliseconds();
        if (now - self.leader_pending_set_ms < self.leader_pending_timeout_ms) return;
        self.leader_pending = false;
        self.leader_chord = null;
        self.leader_help_requested = false;
        self.plugin_chord_buf.clearRetainingCapacity();
        // Request a render so the persistent SPC indicator goes
        // away promptly; otherwise it stays on screen until some
        // other event triggers a frame.
        self.requestRender();
    }

    /// the cursor moves, so the highlight follows intent.
    fn maybeRefreshWordHighlight(self: *Core) void {
        // Skip during modal interactions where highlighting would be
        // visual noise.
        switch (self.mode) {
            .select, .view => {},
            else => {
                self.clearWordHighlight();
                return;
            },
        }

        const now = std.Io.Clock.real.now(self.io).toMilliseconds();
        const idle = now - self.last_cursor_move_time;

        if (idle < self.word_highlight_idle_ms) {
            // Cursor still moving — drop any stale highlight so we
            // don't trail the cursor.
            self.clearWordHighlight();
            return;
        }

        const s = self.state();
        const cur_line = s.getLineContent(s.cursor_row) catch return;
        defer self.allocator.free(cur_line);

        const range = unicode.wordRangeAt(cur_line, s.cursor_col) orelse {
            self.clearWordHighlight();
            return;
        };
        const word = cur_line[range.start..range.end];
        // Don't bother with single-char "words" — too noisy.
        if (word.len < 2) {
            self.clearWordHighlight();
            return;
        }

        // No change since last paint?
        if (self.last_word_highlight) |prev| {
            if (std.mem.eql(u8, prev, word)) return;
        }

        // New word — repaint.
        self.applyWordHighlight(word);
    }

    fn clearWordHighlight(self: *Core) void {
        if (self.last_word_highlight) |w| {
            self.allocator.free(w);
            self.last_word_highlight = null;
            self.decoration_manager.removeBySource("word_highlight");
        }
    }

    fn applyWordHighlight(self: *Core, word: []const u8) void {
        // Replace cached word.
        if (self.last_word_highlight) |w| self.allocator.free(w);
        self.last_word_highlight = self.allocator.dupe(u8, word) catch return;
        self.decoration_manager.removeBySource("word_highlight");

        // Scan only the visible window — decorations outside it would
        // be wasted work and could mark thousands of lines on big files.
        const s = self.state();
        const visible_rows: usize = if (self.win_size.rows > 2) self.win_size.rows - 2 else 1;
        const start = s.scroll_offset;
        const end = @min(s.scroll_offset + visible_rows + 5, s.buffer.lineCount());

        var row: usize = start;
        while (row < end) : (row += 1) {
            const line = s.getLineContent(row) catch continue;
            defer self.allocator.free(line);
            var col: usize = 0;
            while (col + word.len <= line.len) {
                if (std.mem.eql(u8, line[col .. col + word.len], word)) {
                    // Require word boundaries on both sides — don't
                    // highlight `foo` inside `foobar`.
                    const before_ok = col == 0 or !isWordByte(line[col - 1]);
                    const after_ok = col + word.len == line.len or !isWordByte(line[col + word.len]);
                    if (before_ok and after_ok) {
                        _ = self.decoration_manager.add(
                            Range.singleLine(row, col, col + word.len),
                            .word_highlight,
                            50,
                            null,
                            "word_highlight",
                        ) catch {};
                        col += word.len;
                        continue;
                    }
                }
                col += 1;
            }
        }
        // Request a render so the highlight shows up without waiting
        // for the next user input.
        self.needs_render = true;
    }

    fn isWordByte(b: u8) bool {
        return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9') or b == '_' or b >= 0x80;
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

    pub fn homeDir(self: *Core) ![]u8 {
        // platform.getEnv is cross-platform — env.getPosix doesn't
        // compile on Windows in Zig 0.16. Returns an owned slice
        // (no extra dupe needed here).
        if (try platform.getEnv(self.allocator, self.environ_block, "HOME")) |h| return h;
        if (try platform.getEnv(self.allocator, self.environ_block, "USERPROFILE")) |h| return h;
        return error.HomeNotFound;
    }

    fn eagerlyOpenActiveBuffer(self: *Core) void {
        // Don't ship large buffers to the LSP — semantic tokens,
        // diagnostics, and completion would be computed but never
        // rendered (large-file mode draws plain text).
        if (self.activeBufferIsLarge()) return;
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
            const basename = std.fs.path.basename(path);

            // Two paths: format-on-save runs the LSP formatter first
            // (and bails to plain save if the LSP doesn't support
            // formatting for this filetype). The .zig special case
            // honours format-on-save unconditionally to preserve the
            // historical behaviour where ZLS formats every save.
            const is_zig = std.mem.endsWith(u8, path, ".zig");
            const format_first = is_zig or
                (self.storage.config.editor.format_on_save and self.canLspFormat(path));

            // Surface failures in the status bar instead of letting
            // them propagate silently — the user just hit save and
            // deserves to know it didn't take. We still bubble the
            // error up so callers can react.
            if (format_first) {
                self.formatAndSave() catch |err| {
                    self.setStatusError("Save failed for {s}: {s}", .{ basename, @errorName(err) }, 3000);
                    return err;
                };
            } else {
                s.saveFile() catch |err| {
                    self.setStatusError("Save failed for {s}: {s}", .{ basename, @errorName(err) }, 3000);
                    return err;
                };
            }

            // Keep the search index in sync: new files added since
            // the index was built become searchable on save.
            self.search_index.notePathSaved(path);
            // Save is the most natural recovery checkpoint — every
            // user-visible commit of state to disk also commits the
            // session state.
            self.writeRecoverySnapshot();
            self.last_recovery_ms = std.Io.Clock.real.now(self.io).toMilliseconds();

            self.setStatus("Saved {s}", .{basename}, 2000);
        } else {
            self.previous_mode = self.mode;
            self.mode = .save_as_mode;
            self.save_as_input.clearRetainingCapacity();
        }
    }

    /// Show a transient success toast in the status bar. Renders with
    /// a green ✓; for other severities use `setStatusLeveled` /
    /// `setStatusError`.
    pub fn setStatus(
        self: *Core,
        comptime fmt: []const u8,
        args: anytype,
        duration_ms: i64,
    ) void {
        self.setStatusLeveled(.success, fmt, args, duration_ms);
    }

    /// Like `setStatus` but with explicit severity so the renderer can
    /// pick an appropriate icon and colour (✓ green for success, ✗ red
    /// for errors, etc.). The message lands in `action_status_buf`
    /// which keeps the slice stable for the next few frames.
    pub fn setStatusLeveled(
        self: *Core,
        level: protocol.StatusLevel,
        comptime fmt: []const u8,
        args: anytype,
        duration_ms: i64,
    ) void {
        const written = std.fmt.bufPrint(&self.action_status_buf, fmt, args) catch blk: {
            break :blk self.action_status_buf[0..];
        };
        self.status_message = written;
        self.status_message_level = level;
        self.status_message_expires =
            std.Io.Clock.real.now(self.io).toMilliseconds() + duration_ms;
        self.requestRender();
    }

    /// Shortcut for the common error case — `Save failed`, OOM,
    /// permission denied, etc. Renders with a red ✗.
    pub fn setStatusError(
        self: *Core,
        comptime fmt: []const u8,
        args: anytype,
        duration_ms: i64,
    ) void {
        self.setStatusLeveled(.err, fmt, args, duration_ms);
    }

    /// Static-string convenience for any level. Skips the bufPrint and
    /// uses the literal slice directly — safe because the literal lives
    /// for the lifetime of the program.
    pub fn setStatusLiteralLeveled(
        self: *Core,
        level: protocol.StatusLevel,
        msg: []const u8,
        duration_ms: i64,
    ) void {
        self.status_message = msg;
        self.status_message_level = level;
        self.status_message_expires =
            std.Io.Clock.real.now(self.io).toMilliseconds() + duration_ms;
        self.requestRender();
    }

    /// Success-level static literal (most common case).
    pub fn setStatusLiteral(self: *Core, msg: []const u8, duration_ms: i64) void {
        self.setStatusLiteralLeveled(.success, msg, duration_ms);
    }

    fn formatAndSave(self: *Core) !void {
        const s = self.state();
        const path = s.file_path orelse return;

        try self.ensureLspDocument();
        try self.lsp_manager.requestFormatting(path);
        _ = try self.waitAndApplyFormatEdits();
        try s.saveFile();

        self.lsp_manager.documentSaved(path) catch |err| {
            log.warn("LSP save notification failed for '{s}': {}", .{ path, err });
        };
    }

    /// Drain the LSP `format` result slot for up to ~100 ms and apply
    /// the edits to the active buffer in reverse-position order.
    /// Returns whether any edits actually landed. Shared by full-doc
    /// formatting (`formatAndSave`) and range formatting
    /// (`cmdLspFormatSelection`); the response shape is identical so
    /// one path handles both.
    pub fn waitAndApplyFormatEdits(self: *Core) !bool {
        const s = self.state();
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
                        try s.deleteRangeAtOffset(start_off, end_off);
                    }

                    try s.insertTextAtOffset(start_off, edit.new_text);
                }
                return edits.len > 0;
            }
            // best-effort: sleep cancellation is fine, loop will check condition again
            std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(10), .real) catch {};
        }
        return false;
    }

    /// `lsp.format_selection`. Sends `textDocument/rangeFormatting`
    /// for the current visual selection (or, if not in visual mode,
    // cmdLspFormatSelection, cmdLspCodeAction → commands/lsp_commands.zig
    // (LspCommands.cmdLspFormatSelection / .cmdLspCodeAction)

    /// Apply one `CodeAction`. Handles the two shapes we care about:
    /// `WorkspaceEdit.changes` (per-URI TextEdit lists) and
    /// `WorkspaceEdit.documentChanges` (the newer form). Pure
    /// `Command` actions are not executed yet — they require
    /// `workspace/executeCommand` which most servers gate behind a
    /// capability we don't advertise.
    pub fn applyCodeAction(self: *Core, action: LspServer.CodeAction) !void {
        const edit_json = action.edit_json orelse {
            self.setStatus("Code action '{s}': command-only actions not yet supported", .{action.title}, 3000);
            return;
        };
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, edit_json, .{}) catch |err| {
            self.setStatus("Code action: failed to parse edit JSON: {}", .{err}, 3000);
            return;
        };
        defer parsed.deinit();

        const we = parsed.value;
        if (we != .object) return;

        var applied: usize = 0;
        if (we.object.get("changes")) |changes| {
            if (changes == .object) {
                var it = changes.object.iterator();
                while (it.next()) |entry| {
                    const uri = entry.key_ptr.*;
                    if (entry.value_ptr.* != .array) continue;
                    applied += try self.applyTextEditsForUri(uri, entry.value_ptr.array.items);
                }
            }
        } else if (we.object.get("documentChanges")) |dc| {
            if (dc == .array) {
                for (dc.array.items) |op| {
                    if (op != .object) continue;
                    // Only `TextDocumentEdit` shape (has `textDocument` + `edits`).
                    // `CreateFile` / `RenameFile` / `DeleteFile` have `kind` — skip.
                    if (op.object.get("kind")) |k| {
                        if (k == .string) continue;
                    }
                    const td = op.object.get("textDocument") orelse continue;
                    if (td != .object) continue;
                    const uri_val = td.object.get("uri") orelse continue;
                    if (uri_val != .string) continue;
                    const edits = op.object.get("edits") orelse continue;
                    if (edits != .array) continue;
                    applied += try self.applyTextEditsForUri(uri_val.string, edits.array.items);
                }
            }
        }

        self.setStatus("Code action '{s}': {d} edit(s) applied", .{ action.title, applied }, 2500);
        try self.sendUpdate();
    }

    /// Apply a list of `TextEdit` JSON objects to whichever open
    /// buffer matches `uri`. Edits within a single file are sorted
    /// and applied in reverse so earlier offsets stay valid. Returns
    /// the number of edits applied (0 if no buffer matches).
    fn applyTextEditsForUri(self: *Core, uri: []const u8, edits_json: []const std.json.Value) !usize {
        const file_prefix = "file://";
        if (!std.mem.startsWith(u8, uri, file_prefix)) return 0;
        const path = try lsp_client.fileUriToPath(self.allocator, uri);
        defer self.allocator.free(path);

        // Find the buffer.
        var target: ?*@TypeOf(self.buffer_manager.buffers.items[0]) = null;
        for (self.buffer_manager.buffers.items) |*buf| {
            if (buf.file_path) |fp| {
                if (std.mem.eql(u8, fp, path)) {
                    target = buf;
                    break;
                }
            }
        }
        const buf = target orelse return 0;

        // Parse edits into a sortable list.
        const Edit = struct {
            start_line: u32,
            start_col: u32,
            end_line: u32,
            end_col: u32,
            new_text: []const u8,
        };
        var list: std.ArrayListUnmanaged(Edit) = .empty;
        defer list.deinit(self.allocator);
        for (edits_json) |e| {
            if (e != .object) continue;
            const range = e.object.get("range") orelse continue;
            if (range != .object) continue;
            const start = range.object.get("start") orelse continue;
            const end = range.object.get("end") orelse continue;
            if (start != .object or end != .object) continue;
            const sl = start.object.get("line") orelse continue;
            const sc = start.object.get("character") orelse continue;
            const el = end.object.get("line") orelse continue;
            const ec = end.object.get("character") orelse continue;
            const start_line = jsonValueToU32(sl) orelse continue;
            const start_col = jsonValueToU32(sc) orelse continue;
            const end_line = jsonValueToU32(el) orelse continue;
            const end_col = jsonValueToU32(ec) orelse continue;
            const nt = e.object.get("newText") orelse continue;
            if (nt != .string) continue;
            try list.append(self.allocator, .{
                .start_line = start_line,
                .start_col = start_col,
                .end_line = end_line,
                .end_col = end_col,
                .new_text = nt.string,
            });
        }

        std.mem.sort(Edit, list.items, {}, struct {
            fn lt(_: void, a: Edit, b: Edit) bool {
                if (a.start_line != b.start_line) return a.start_line < b.start_line;
                return a.start_col < b.start_col;
            }
        }.lt);

        var i: usize = list.items.len;
        while (i > 0) {
            i -= 1;
            const edit = list.items[i];
            const start_off = buf.state.getOffsetFor(edit.start_line, edit.start_col);
            const end_off = buf.state.getOffsetFor(edit.end_line, edit.end_col);
            if (end_off > start_off) {
                try buf.state.deleteRangeAtOffset(start_off, end_off);
            }
            try buf.state.insertTextAtOffset(start_off, edit.new_text);
        }
        return list.items.len;
    }

    /// Wasm host-hook implementations. These run on whichever thread
    /// invoked the wasm function — currently always core's main
    /// thread, so direct access to `buffer_manager` is safe. If we
    /// ever dispatch wasm work off-thread the manager will need to
    /// route these through `core_inbox` instead.
    fn coreGetBufferContent(user_data: *anyopaque, out_buf: []u8) i32 {
        const self: *Core = @ptrCast(@alignCast(user_data));
        const active = self.buffer_manager.getActive();
        const content = active.state.buffer.toString(self.allocator) catch return -1;
        defer self.allocator.free(content);
        const n = @min(content.len, out_buf.len);
        @memcpy(out_buf[0..n], content[0..n]);
        return @intCast(n);
    }

    fn coreGetBufferPath(user_data: *anyopaque, out_buf: []u8) i32 {
        const self: *Core = @ptrCast(@alignCast(user_data));
        const active = self.buffer_manager.getActive();
        const path = active.file_path orelse active.name;
        const n = @min(path.len, out_buf.len);
        @memcpy(out_buf[0..n], path[0..n]);
        return @intCast(n);
    }

    /// HostHooks.request_render trampoline. May be called from a
    /// plugin reader thread — `needs_render` is a plain bool so the
    /// worst case is a tearing read by the main loop on tick, which
    /// resolves on the next iteration. Good enough; a full atomic
    /// would just push the same single-flip behaviour through a
    /// fence.
    fn coreRequestRender(user_data: *anyopaque) void {
        const self: *Core = @ptrCast(@alignCast(user_data));
        self.requestRender();
    }

    /// Trampoline installed on every buffer's `EditorState.edit_hook`.
    /// Translates the state-layer `EditEvent` into a
    /// `SyntaxManager.EditInfo` and queues it for the next parse
    /// worker run. Lets tree-sitter do real incremental parsing
    /// (`ts_tree_edit` against the prior tree + content-match
    /// subtree reuse on the changed range only) instead of the
    /// content-match-only fallback we get when no edits are
    /// recorded. Cheap — just a struct copy onto a mutex-guarded
    /// list.
    fn coreEditHookTrampoline(ctx: *anyopaque, ev: EditorState.EditEvent) void {
        const self: *Core = @ptrCast(@alignCast(ctx));
        self.syntax_manager.recordEdit(.{
            .start_byte = ev.start_byte,
            .old_end_byte = ev.old_end_byte,
            .new_end_byte = ev.new_end_byte,
            .start_row = ev.start_row,
            .start_col = ev.start_col,
            .old_end_row = ev.old_end_row,
            .old_end_col = ev.old_end_col,
            .new_end_row = ev.new_end_row,
            .new_end_col = ev.new_end_col,
        });
    }

    /// Hand a `PluginMessage` reply back to whichever process plugin
    /// originated the request. Encodes the payload as a JSON result
    /// and routes via `PluginManager.replyToProcessPlugin`.
    fn replyPluginRequest(self: *Core, reply: protocol.PluginMessage) !void {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        const w = &aw.writer;
        const jsonrpc = @import("../plugins/jsonrpc.zig");
        switch (reply.payload) {
            .state => |s| {
                try w.writeByte('{');
                try jsonrpc.writeJsonStringKey(w, "buffer_id");
                try w.print("{d}", .{s.buffer_id});
                try w.writeAll(",");
                try jsonrpc.writeJsonStringKey(w, "buffer_name");
                try jsonrpc.writeJsonString(w, s.buffer_name);
                try w.writeAll(",");
                try jsonrpc.writeJsonStringKey(w, "file_path");
                if (s.file_path) |fp| try jsonrpc.writeJsonString(w, fp) else try w.writeAll("null");
                try w.writeAll(",");
                try jsonrpc.writeJsonStringKey(w, "cursor_row");
                try w.print("{d}", .{s.cursor_row});
                try w.writeAll(",");
                try jsonrpc.writeJsonStringKey(w, "cursor_col");
                try w.print("{d}", .{s.cursor_col});
                try w.writeAll(",");
                try jsonrpc.writeJsonStringKey(w, "mode");
                try jsonrpc.writeJsonString(w, @tagName(s.mode));
                try w.writeAll(",");
                try jsonrpc.writeJsonStringKey(w, "file_modified");
                try w.writeAll(if (s.file_modified) "true" else "false");
                try w.writeAll(",");
                try jsonrpc.writeJsonStringKey(w, "total_lines");
                try w.print("{d}", .{s.total_lines});
                try w.writeByte('}');
            },
            .buffer_content_response => |r| {
                try w.writeByte('{');
                try jsonrpc.writeJsonStringKey(w, "id");
                try w.print("{d}", .{r.id});
                try w.writeAll(",");
                try jsonrpc.writeJsonStringKey(w, "content");
                try jsonrpc.writeJsonString(w, r.content);
                try w.writeByte('}');
            },
            else => {
                if (reply.message_type == .get_plugin_list_response) {
                    // Walk the manager's runtime maps and render a
                    // minimal JSON array of `{name, runtime}`.
                    try w.writeByte('[');
                    var first = true;
                    var w_it = self.plugin_manager.wasm_plugins.valueIterator();
                    while (w_it.next()) |wp_ptr| {
                        if (!first) try w.writeByte(',');
                        first = false;
                        try w.writeByte('{');
                        try jsonrpc.writeJsonStringKey(w, "name");
                        try jsonrpc.writeJsonString(w, wp_ptr.*.plugin_id);
                        try w.writeAll(",");
                        try jsonrpc.writeJsonStringKey(w, "runtime");
                        try jsonrpc.writeJsonString(w, "wasm");
                        try w.writeByte('}');
                    }
                    var p_it = self.plugin_manager.process_plugins.valueIterator();
                    while (p_it.next()) |pp_ptr| {
                        if (!first) try w.writeByte(',');
                        first = false;
                        try w.writeByte('{');
                        try jsonrpc.writeJsonStringKey(w, "name");
                        try jsonrpc.writeJsonString(w, pp_ptr.*.name);
                        try w.writeAll(",");
                        try jsonrpc.writeJsonStringKey(w, "runtime");
                        try jsonrpc.writeJsonString(w, "exec");
                        try w.writeByte('}');
                    }
                    try w.writeByte(']');
                } else {
                    try w.writeAll("null");
                }
            },
        }
        self.plugin_manager.replyToProcessPlugin(reply.correlation_id, aw.written());
    }

    /// Approximate the cursor's visual row inside the viewport,
    /// counting each soft-wrapped continuation as an extra row. Walks
    /// lines from `top_row` up to (and into) `cursor_row`, accumulating
    /// the wrap height contributed by each line.
    // visualRowOfCursor → kernel/render.zig
    // wrappedRowsForLine → kernel/render.zig

    pub fn sendUpdate(self: *Core) !void {
        return render_mod.buildAndSend(self);
    }

    // ---- Hover helpers ---------------------------------------------------

    /// True if the popup is currently rendered (either the parsed
    /// document or the raw fallback).
    pub fn hoverVisible(self: *Core) bool {
        return self.hover_doc != null or self.hover_content != null;
    }

    /// Free both the raw payload and the parsed document, reset
    /// scroll, and clear the in-flight flag.
    pub fn dismissHover(self: *Core) void {
        if (self.hover_content) |c| {
            self.allocator.free(c);
            self.hover_content = null;
        }
        if (self.hover_doc) |*doc| doc.deinit();
        self.hover_doc = null;
        self.hover_scroll_offset = 0;
        self.hover_sticky = false;
        self.hover_pending = false;
    }

    /// Record where to anchor the popup for the next response. Set by
    /// the hover-trigger paths (manual and auto) so the renderer can
    /// pin the popup near the *symbol* even if the cursor drifts.
    pub fn setHoverAnchor(self: *Core, row: usize, col: usize) void {
        self.hover_anchor_row = row;
        self.hover_anchor_col = col;
    }

    /// Mark the hover as "sticky" — survives any non-scroll key until
    /// the user presses Esc.
    pub fn setHoverSticky(self: *Core, sticky: bool) void {
        self.hover_sticky = sticky;
    }

    /// True if `key` should advance / retreat the popup body scroll
    /// while a sticky hover is open. Arrow keys, vim hjkl-style j/k,
    /// PageUp/Down, and Ctrl+u/d all count.
    fn tryHoverScroll(self: *Core, key: vaxis.Key) bool {
        var consumed = true;
        if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
            self.hover_scroll_offset +|= 1;
        } else if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
            self.hover_scroll_offset -|= 1;
        } else if (key.matches(vaxis.Key.page_down, .{}) or key.matches('d', .{ .ctrl = true })) {
            self.hover_scroll_offset +|= 5;
        } else if (key.matches(vaxis.Key.page_up, .{}) or key.matches('u', .{ .ctrl = true })) {
            self.hover_scroll_offset -|= 5;
        } else {
            consumed = false;
        }
        return consumed;
    }

    pub fn ensureLspDocument(self: *Core) !void {
        // Large-file mode never sends documents to the LSP — the
        // semantic tokens, diagnostics, and completion that the server
        // would compute aren't going to be rendered anyway, and the
        // server would have to index the whole thing.
        if (self.activeBufferIsLarge()) return;
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

    pub fn refreshSyntaxForCurrentBuffer(self: *Core) void {
        const active_buf = self.buffer_manager.getActive();
        self.buffer_manager.loadBufferContent(active_buf) catch |err| {
            log.warn("Failed to load lazy content: {}", .{err});
            return;
        };

        // Skip the parse + LSP open entirely in large-file mode.
        if (active_buf.is_large) return;

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

    pub fn findProjectRoot(self: *Core, start_path: []const u8) !?[]const u8 {
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

        // Clean exit — drop the crash recovery snapshot so the next
        // launch knows there's nothing to recover. If this fails we
        // still proceed; worst case the next launch sees a stale
        // recovery and offers it (then overwrites once the user saves).
        if (self.storage.getRecoveryPath()) |rp| {
            defer self.allocator.free(rp);
            std.Io.Dir.cwd().deleteFile(self.io, rp) catch {};
        } else |_| {}

        var msg = protocol.Message{ .command = .quit };
        const bytes = try msg.encode(self.allocator);
        defer self.allocator.free(bytes);
        try self.ui_bus.sendCritical(bytes);
    }

    /// Periodic crash-safety snapshot. Same payload as the clean
    /// session save, but to the recovery file; survives a crash so
    /// the next launch can prompt to restore open buffers + cursors.
    /// Called on every save and from the tick handler on a coarse
    /// (~30 s) timer.
    fn writeRecoverySnapshot(self: *Core) void {
        const rp = self.storage.getRecoveryPath() catch return;
        defer self.allocator.free(rp);

        var splits_json: ?[]const u8 = null;
        defer if (splits_json) |s| self.allocator.free(s);
        if (self.split_manager) |*sm| {
            splits_json = sm.toJson(self.allocator) catch null;
        }

        session.save(
            self.allocator,
            self.io,
            rp,
            self.buffer_manager.buffers,
            self.buffer_manager.active_index,
            splits_json,
        ) catch |err| {
            log.debug("Recovery snapshot write failed: {}", .{err});
        };
    }

    fn restoreSession(self: *Core) void {
        // Prefer a crash-recovery snapshot over the clean-shutdown
        // session file if both exist. The recovery file is only
        // present when the previous run didn't reach `sendQuitToUI`
        // (which deletes it), so its existence is by itself a signal
        // that something went wrong.
        const recover_path = self.storage.getRecoveryPath() catch null;
        defer if (recover_path) |p| self.allocator.free(p);

        var loaded_from_recovery = false;
        const loaded: ?session.Session = blk: {
            if (recover_path) |rp| {
                if (std.Io.Dir.accessAbsolute(self.io, rp, .{})) |_| {
                    if (session.load(self.allocator, self.io, rp)) |sess_opt| {
                        if (sess_opt) |s| {
                            log.warn("Found crash recovery snapshot at {s}; restoring", .{rp});
                            loaded_from_recovery = true;
                            break :blk s;
                        }
                    } else |err| {
                        log.warn("Recovery snapshot parse failed: {}; falling back to clean session", .{err});
                    }
                } else |_| {}
            }
            const session_path = self.storage.getSessionPath();
            break :blk session.load(self.allocator, self.io, session_path) catch |err| {
                log.warn("Failed to load session: {}", .{err});
                return;
            };
        };

        const sess = loaded orelse return;
        defer session.freeSession(self.allocator, sess);
        if (loaded_from_recovery) {
            log.info("Recovered {d} buffers from crash snapshot", .{sess.buffers.len});
            // Consume the snapshot now that we've successfully loaded
            // it. Without this, a launch-then-immediate-crash sequence
            // (before the 30 s periodic rewrite fires) would resurface
            // the same stale recovery on the next launch.
            if (recover_path) |rp| {
                std.Io.Dir.cwd().deleteFile(self.io, rp) catch {};
            }
        }

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
                self.workspace_manager.registerBuffer(buf.id, path) catch |err| {
                    log.debug("workspace registerBuffer failed for {s}: {s}", .{ path, @errorName(err) });
                };
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

    // handleCommandPaletteInput → kernel/input/command_palette.zig

    pub fn updateCommandSearch(self: *Core) !void {
        self.command_palette_results.clearRetainingCapacity();
        try self.command_registry.search(self.command_palette_input.items, &self.command_palette_results, self.allocator);
        self.command_palette_selected = 0;
    }

    // handleGoToLineInput → kernel/input/go_to_line.zig
    // handleSymbolPickerInput → kernel/input/symbol_picker.zig

    // handleWorkspaceSymbolPickerInput → kernel/input/workspace_symbol_picker.zig

    pub fn updateSymbolSearch(self: *Core) !void {
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

    pub fn clearGlobalSearchResults(self: *Core) void {
        for (self.global_search_results.items) |*group| {
            for (group.matches) |match| {
                self.allocator.free(match.line_content);
            }
            self.allocator.free(group.matches);
            self.allocator.free(group.file_path);
        }
        self.global_search_results.clearRetainingCapacity();
    }

    // handleGlobalSearchInput → kernel/input/global_search.zig

    pub const ReplaceStep = enum { replace, skip };

    /// Begin the replace-with-confirmation walk over the current search
    /// results. Snapshots query+replace so subsequent typing into the
    /// fields can't disturb the walk. Pre-conditions: both fields
    /// non-empty AND there's at least one result. Otherwise: status
    /// message, do nothing.
    pub fn startReplaceConfirm(self: *Core) !void {
        if (self.global_search_query.items.len == 0) {
            self.setStatusLiteralLeveled(.warning, "Empty search query", 2000);
            return;
        }
        if (self.global_search_replace.items.len == 0) {
            self.setStatusLiteralLeveled(.warning, "Empty replacement (Tab to focus replace field)", 2500);
            return;
        }
        if (self.global_search_results.items.len == 0) {
            self.setStatusLiteralLeveled(.warning, "No matches to replace", 2000);
            return;
        }

        // Snapshot so concurrent edits to the input fields can't
        // corrupt the walk (e.g. user typing in the replace field
        // between confirmations).
        self.global_search_replace_query_snap.clearRetainingCapacity();
        self.global_search_replace_text_snap.clearRetainingCapacity();
        try self.global_search_replace_query_snap.appendSlice(self.allocator, self.global_search_query.items);
        try self.global_search_replace_text_snap.appendSlice(self.allocator, self.global_search_replace.items);

        self.global_search_replace_active = true;
        self.global_search_replace_apply_all = false;
        self.global_search_replace_file_idx = 0;
        self.global_search_replace_match_idx = 0;
        self.global_search_replace_count = 0;
        self.global_search_replace_skipped = 0;
        self.global_search_replace_line_delta = 0;
        self.global_search_replace_last_file = std.math.maxInt(usize);
        self.global_search_replace_last_line = 0;

        try self.showReplaceConfirmPrompt();
    }

    /// Advance the walk by one step (replace or skip). Triggers the
    /// next prompt, or finishes the flow when there are no more matches.
    pub fn replaceConfirmStep(self: *Core, step: ReplaceStep) !void {
        // Apply (or skip) the current match.
        if (step == .replace) {
            self.applyCurrentReplaceMatch() catch |err| {
                log.warn("Replace failed at file_idx={d} match_idx={d}: {}", .{
                    self.global_search_replace_file_idx,
                    self.global_search_replace_match_idx,
                    err,
                });
            };
        } else {
            self.global_search_replace_skipped += 1;
        }
        // Move to the next match.
        self.advanceReplaceCursor();

        // If "Apply All", consume the remainder. Per-match failures
        // get logged so the user knows when a replace skipped a file
        // (e.g. read-only, vanished between scan and apply).
        if (self.global_search_replace_apply_all) {
            while (self.replaceWalkHasCurrent()) {
                self.applyCurrentReplaceMatch() catch |err| {
                    log.warn("Apply-all: replace failed at file_idx={d} match_idx={d}: {s}", .{
                        self.global_search_replace_file_idx,
                        self.global_search_replace_match_idx,
                        @errorName(err),
                    });
                };
                self.advanceReplaceCursor();
            }
            try self.finishReplaceConfirm(true);
            return;
        }

        if (!self.replaceWalkHasCurrent()) {
            try self.finishReplaceConfirm(true);
            return;
        }
        try self.showReplaceConfirmPrompt();
    }

    fn replaceWalkHasCurrent(self: *Core) bool {
        return self.global_search_replace_file_idx < self.global_search_results.items.len;
    }

    fn advanceReplaceCursor(self: *Core) void {
        if (self.global_search_replace_file_idx >= self.global_search_results.items.len) return;
        const group = self.global_search_results.items[self.global_search_replace_file_idx];
        if (self.global_search_replace_match_idx + 1 < group.matches.len) {
            self.global_search_replace_match_idx += 1;
        } else {
            self.global_search_replace_file_idx += 1;
            self.global_search_replace_match_idx = 0;
        }
    }

    /// Open the active match's file, position the cursor on the match,
    /// and surface the y/n/A/q prompt in the status bar.
    fn showReplaceConfirmPrompt(self: *Core) !void {
        const file_idx = self.global_search_replace_file_idx;
        const group = self.global_search_results.items[file_idx];
        const match = group.matches[self.global_search_replace_match_idx];

        // Open the file and place the cursor at the (delta-adjusted)
        // match column so the user sees what's about to be touched.
        const full_path = std.Io.Dir.cwd().realPathFileAlloc(self.io, group.file_path, self.allocator) catch {
            // File vanished mid-walk — skip it.
            self.global_search_replace_file_idx += 1;
            self.global_search_replace_match_idx = 0;
            if (!self.replaceWalkHasCurrent()) {
                try self.finishReplaceConfirm(true);
                return;
            }
            try self.showReplaceConfirmPrompt();
            return;
        };
        defer self.allocator.free(full_path);
        try self.openFileAtLine(full_path, match.line_num);
        const adjusted_col = self.adjustedMatchCol(file_idx, match);
        const s = self.state();
        s.cursor_col = adjusted_col;
        self.recenterIfOffscreen();

        const total = self.countTotalMatches();
        const done = self.global_search_replace_count + self.global_search_replace_skipped + 1;
        const msg = std.fmt.bufPrint(
            &self.skip_status_buf,
            "Replace? [y]es [n]o [A]ll [q]uit  ({d}/{d})",
            .{ done, total },
        ) catch return;
        self.status_message = msg;
        self.status_message_expires = std.math.maxInt(i64);
        // Stay in global_search mode so our handler keeps seeing keys,
        // but visually the user is now in the buffer.
        self.mode = .global_search;
        try self.sendUpdate();
    }

    fn countTotalMatches(self: *Core) usize {
        var n: usize = 0;
        for (self.global_search_results.items) |g| n += g.matches.len;
        return n;
    }

    /// Translate the search result's original column to the current
    /// column after prior replacements on the same line shifted text.
    fn adjustedMatchCol(self: *Core, file_idx: usize, match: protocol.GlobalSearchMatch) usize {
        if (file_idx == self.global_search_replace_last_file and match.line_num == self.global_search_replace_last_line) {
            const c: i64 = @intCast(match.match_start);
            const adj = c + self.global_search_replace_line_delta;
            if (adj < 0) return 0;
            return @intCast(adj);
        }
        return match.match_start;
    }

    fn applyCurrentReplaceMatch(self: *Core) !void {
        const file_idx = self.global_search_replace_file_idx;
        if (file_idx >= self.global_search_results.items.len) return;
        const group = self.global_search_results.items[file_idx];
        if (self.global_search_replace_match_idx >= group.matches.len) return;
        const match = group.matches[self.global_search_replace_match_idx];

        // Reset the line-delta counter when we move to a different line.
        if (file_idx != self.global_search_replace_last_file or
            match.line_num != self.global_search_replace_last_line)
        {
            self.global_search_replace_line_delta = 0;
            self.global_search_replace_last_file = file_idx;
            self.global_search_replace_last_line = match.line_num;
        }

        const full_path = try std.Io.Dir.cwd().realPathFileAlloc(self.io, group.file_path, self.allocator);
        defer self.allocator.free(full_path);
        try self.openFileAtLine(full_path, match.line_num);

        const s = self.state();
        const start_col = self.adjustedMatchCol(file_idx, match);
        const query = self.global_search_replace_query_snap.items;
        const replacement = self.global_search_replace_text_snap.items;
        const start_off = s.getOffsetFor(match.line_num, start_col);
        const end_off = start_off + query.len;
        try s.deleteRange(start_off, end_off);
        s.cursor_row = match.line_num;
        s.cursor_col = start_col;
        try s.insertTextAtCursor(replacement);

        const delta: i64 = @as(i64, @intCast(replacement.len)) - @as(i64, @intCast(query.len));
        self.global_search_replace_line_delta += delta;
        self.global_search_replace_count += 1;
    }

    pub fn finishReplaceConfirm(self: *Core, completed: bool) !void {
        const replaced = self.global_search_replace_count;
        const skipped = self.global_search_replace_skipped;
        self.global_search_replace_active = false;
        self.global_search_replace_apply_all = false;
        self.global_search_replace_query_snap.clearRetainingCapacity();
        self.global_search_replace_text_snap.clearRetainingCapacity();
        // Return to select mode in whichever buffer we ended up on so
        // the user can immediately review/save.
        self.mode = .select;

        const tag = if (completed) "Replace done" else "Replace cancelled";
        const msg = std.fmt.bufPrint(
            &self.skip_status_buf,
            "{s}: {d} replaced, {d} skipped",
            .{ tag, replaced, skipped },
        ) catch return;
        self.status_message = msg;
        self.status_message_expires = std.Io.Clock.real.now(self.io).toMilliseconds() + 4000;
        try self.sendUpdate();
    }

    pub fn performGlobalSearch(self: *Core) !void {
        self.clearGlobalSearchResults();
        self.global_search_ran = true;

        const query = self.global_search_query.items;
        if (query.len < 2) return;

        // Pull the cached path list from the search index — when it's
        // populated, `global_search` skips the directory walk and goes
        // straight to the parallel scan, shaving the first ~30 ms (and
        // more on big repos) off every query.
        const cached_paths = self.search_index.snapshot(self.allocator) catch null;
        defer if (cached_paths) |cp| {
            for (cp) |p| self.allocator.free(p);
            self.allocator.free(cp);
        };
        const cached_view: ?[]const []const u8 = if (cached_paths) |cp|
            if (cp.len == 0) null else @as([]const []const u8, cp)
        else
            null;

        const results = global_search.searchWithPaths(
            self.allocator,
            self.io,
            query,
            ".",
            .{ .search = self.global_search_options },
            cached_view,
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
    pub fn jumpToDiagnostic(self: *Core, forward: bool) !void {
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

    pub fn setBookmark(self: *Core, slot: u8) !void {
        const s = self.state();
        const path = s.file_path orelse {
            self.setStatusLiteralLeveled(.warning, "Cannot bookmark unsaved buffer", 2000);
            return;
        };
        const now = std.Io.Clock.real.now(self.io).toMilliseconds();
        try self.bookmarks.set(slot, path, s.cursor_row, s.cursor_col, now);
        self.bookmarks.save(self.io) catch |err| {
            log.warn("Failed to persist bookmark: {}", .{err});
        };
        const msg = std.fmt.bufPrint(&self.skip_status_buf, "Bookmark '{c}' set at line {d}", .{ slot, s.cursor_row + 1 }) catch return;
        self.status_message = msg;
        self.status_message_expires = now + 2000;
        try self.sendUpdate();
    }

    pub fn jumpToBookmark(self: *Core, slot: u8) !void {
        const bm = self.bookmarks.get(slot) orelse {
            const msg = std.fmt.bufPrint(&self.skip_status_buf, "Bookmark '{c}' not set", .{slot}) catch return;
            self.status_message = msg;
            self.status_message_expires = std.Io.Clock.real.now(self.io).toMilliseconds() + 1500;
            return;
        };
        // Stat the target path before we attempt to open — if the
        // file was deleted / moved externally, fall through to a
        // useful error instead of letting openFileAtLine fail and
        // dropping the user on an empty buffer (the old behavior).
        const stat_ok = blk: {
            const f = std.Io.Dir.openFileAbsolute(self.io, bm.file_path, .{}) catch break :blk false;
            f.close(self.io);
            break :blk true;
        };
        if (!stat_ok) {
            const msg = std.fmt.bufPrint(
                &self.skip_status_buf,
                "Bookmark '{c}' points at missing file: {s}",
                .{ slot, bm.file_path },
            ) catch return;
            self.status_message = msg;
            self.status_message_level = .warning;
            self.status_message_expires = std.Io.Clock.real.now(self.io).toMilliseconds() + 3000;
            try self.sendUpdate();
            return;
        }
        // Record the current spot in the jump list before we leave, so
        // Space `,` can bring the user back.
        if (self.state().file_path) |cur_path| {
            self.jump_list.recordJump(cur_path, self.state().cursor_row, self.state().cursor_col) catch |err| {
                log.debug("recordJump failed for {s}: {s}", .{ cur_path, @errorName(err) });
            };
        }
        try self.openFileAtLine(bm.file_path, bm.row);
        const s = self.state();
        s.cursor_col = bm.col;
        s.preferred_col = null;
        self.recenterIfOffscreen();
        try self.sendUpdate();
    }

    pub fn openBookmarksBuffer(self: *Core) !void {
        const name = "[Bookmarks]";

        var content = std.ArrayListUnmanaged(u8).empty;
        defer content.deinit(self.allocator);

        try content.appendSlice(self.allocator,
            \\# Bookmarks
            \\
            \\## How to use
            \\
            \\Bookmarks are 26 named slots (a-z) per project. They
            \\persist across stem sessions.
            \\
            \\### To SET a bookmark
            \\  1. Close this [Bookmarks] buffer (`Space k`) — bookmarks
            \\     can only be set in real file-backed buffers, not in
            \\     this virtual view.
            \\  2. In your code, place the cursor where you want the
            \\     bookmark.
            \\  3. Press `m` then a letter (a-z). Example: `ma` sets
            \\     bookmark `a` at the current line. A toast confirms.
            \\
            \\### To JUMP to a bookmark
            \\  Press `'` (apostrophe) then the letter, from anywhere.
            \\  Example: `'a` jumps to bookmark `a`.
            \\
            \\### Other
            \\  - `Space m` re-opens this list any time.
            \\  - Palette `bookmark.clear_all` wipes every slot for
            \\    this project.
            \\
            \\## Current slots
            \\
        );
        if (self.bookmarks.count() == 0) {
            try content.appendSlice(self.allocator, "(none set yet)\n");
        } else {
            try content.appendSlice(self.allocator, "Slot  Line   File\n");
            try content.appendSlice(self.allocator, "----  -----  --------------------------------\n");
            for (self.bookmarks.slots, 0..) |slot, i| {
                if (slot) |bm| {
                    const slot_char: u8 = @intCast('a' + i);
                    const row_str = try std.fmt.allocPrint(self.allocator, " {c}    {d: >5}  {s}\n", .{ slot_char, bm.row + 1, bm.file_path });
                    defer self.allocator.free(row_str);
                    try content.appendSlice(self.allocator, row_str);
                }
            }
        }
        try self.buffer_manager.openVirtual(name, content.items);
        self.refreshSyntaxForCurrentBuffer();
        try self.sendUpdate();
    }

    /// Apply a text-object selection: turn the named object (word,
    /// paragraph, quote-delimited string, bracket pair, …) into a
    /// visual selection rooted at the cursor. `around` includes the
    /// delimiters; `!around` excludes them. Quietly does nothing if
    /// the object isn't found.
    pub fn selectTextObject(self: *Core, ch: u8, around: bool) !void {
        const s = self.state();
        const range = self.findTextObject(ch, around) orelse {
            self.setStatusLiteralLeveled(.warning, "Text object not found", 1200);
            return;
        };
        s.selection_anchor = .{ .row = range.start_row, .col = range.start_col };
        s.cursor_row = range.end_row;
        s.cursor_col = range.end_col;
        self.mode = .visual;
        try self.sendUpdate();
    }

    const TextRange = struct {
        start_row: usize,
        start_col: usize,
        end_row: usize,
        end_col: usize,
    };

    fn findTextObject(self: *Core, ch: u8, around: bool) ?TextRange {
        switch (ch) {
            'w' => return self.textObjectWord(around, false),
            'W' => return self.textObjectWord(around, true),
            'p' => return self.textObjectParagraph(around),
            '"', '\'', '`' => return self.textObjectQuote(ch, around),
            '(', ')', 'b' => return self.textObjectBracket('(', ')', around),
            '[', ']' => return self.textObjectBracket('[', ']', around),
            '{', '}', 'B' => return self.textObjectBracket('{', '}', around),
            '<', '>' => return self.textObjectBracket('<', '>', around),
            else => return null,
        }
    }

    fn textObjectWord(self: *Core, around: bool, big: bool) ?TextRange {
        const s = self.state();
        const line = s.getLineContent(s.cursor_row) catch return null;
        defer self.allocator.free(line);
        if (s.cursor_col >= line.len) return null;

        const inWord = struct {
            fn f(b: u8, is_big: bool) bool {
                return if (is_big) isNonSpaceByte(b) else isWordByte(b);
            }
        }.f;
        if (!inWord(line[s.cursor_col], big)) return null;

        var start = s.cursor_col;
        while (start > 0 and inWord(line[start - 1], big)) : (start -= 1) {}
        var end = s.cursor_col;
        while (end < line.len and inWord(line[end], big)) : (end += 1) {}

        if (around) {
            // Include trailing whitespace; if none, include leading.
            const trailing_end = end;
            var with_trail = end;
            while (with_trail < line.len and (line[with_trail] == ' ' or line[with_trail] == '\t')) : (with_trail += 1) {}
            if (with_trail > trailing_end) {
                end = with_trail;
            } else {
                while (start > 0 and (line[start - 1] == ' ' or line[start - 1] == '\t')) : (start -= 1) {}
            }
        }
        return .{
            .start_row = s.cursor_row,
            .start_col = start,
            .end_row = s.cursor_row,
            .end_col = end,
        };
    }

    fn isNonSpaceByte(b: u8) bool {
        return b != ' ' and b != '\t' and b != '\n' and b != '\r';
    }

    fn textObjectParagraph(self: *Core, around: bool) ?TextRange {
        const s = self.state();
        const total = s.buffer.lineCount();
        if (total == 0) return null;

        // Walk back to the first non-blank line (or top of buffer).
        var start = s.cursor_row;
        while (start > 0 and !self.isLineBlank(start - 1)) : (start -= 1) {}
        var end = s.cursor_row;
        while (end + 1 < total and !self.isLineBlank(end + 1)) : (end += 1) {}
        // `around`: include the trailing blank line(s).
        if (around) {
            while (end + 1 < total and self.isLineBlank(end + 1)) : (end += 1) {}
        }
        const end_line = s.getLineContent(end) catch return null;
        defer self.allocator.free(end_line);
        return .{
            .start_row = start,
            .start_col = 0,
            .end_row = end,
            .end_col = end_line.len,
        };
    }

    fn isLineBlank(self: *Core, row: usize) bool {
        const s = self.state();
        const line = s.getLineContent(row) catch return true;
        defer self.allocator.free(line);
        for (line) |b| {
            if (b != ' ' and b != '\t' and b != '\r') return false;
        }
        return true;
    }

    fn textObjectQuote(self: *Core, q: u8, around: bool) ?TextRange {
        // Quoted-string objects are line-local — multi-line strings
        // are rare in source and the AST query path covers them better.
        const s = self.state();
        const line = s.getLineContent(s.cursor_row) catch return null;
        defer self.allocator.free(line);

        // Find the pair of quotes on this line that brackets the cursor.
        // Handle simple `\q` escapes.
        var opens = std.ArrayListUnmanaged(usize).empty;
        defer opens.deinit(self.allocator);
        var positions = std.ArrayListUnmanaged(usize).empty;
        defer positions.deinit(self.allocator);
        var i: usize = 0;
        while (i < line.len) : (i += 1) {
            if (line[i] == '\\' and i + 1 < line.len) {
                i += 1;
                continue;
            }
            if (line[i] == q) positions.append(self.allocator, i) catch return null;
        }
        if (positions.items.len < 2) return null;

        // Pair them up sequentially: (0,1), (2,3), …
        var p: usize = 0;
        while (p + 1 < positions.items.len) : (p += 2) {
            const a = positions.items[p];
            const b = positions.items[p + 1];
            if (s.cursor_col >= a and s.cursor_col <= b) {
                if (around) {
                    return .{ .start_row = s.cursor_row, .start_col = a, .end_row = s.cursor_row, .end_col = b + 1 };
                } else {
                    return .{ .start_row = s.cursor_row, .start_col = a + 1, .end_row = s.cursor_row, .end_col = b };
                }
            }
        }
        return null;
    }

    fn textObjectBracket(self: *Core, open: u8, close: u8, around: bool) ?TextRange {
        // Walk outward from the cursor to find the enclosing pair. We
        // count depth across line breaks so multi-line braces work.
        const s = self.state();
        const total = s.buffer.lineCount();
        if (total == 0) return null;

        // Find opener: walk backward from cursor, tracking depth.
        var depth: i32 = 0;
        var op_row: ?usize = null;
        var op_col: usize = 0;
        var row: isize = @intCast(s.cursor_row);
        var start_col: isize = @as(isize, @intCast(s.cursor_col)) - 1;
        scan_back: while (row >= 0) {
            const line = s.getLineContent(@intCast(row)) catch break;
            defer self.allocator.free(line);
            const c_start: isize = if (row == @as(isize, @intCast(s.cursor_row))) start_col else @as(isize, @intCast(line.len)) - 1;
            var c = c_start;
            while (c >= 0) : (c -= 1) {
                const b = line[@intCast(c)];
                if (b == close) depth += 1;
                if (b == open) {
                    if (depth == 0) {
                        op_row = @intCast(row);
                        op_col = @intCast(c);
                        break :scan_back;
                    }
                    depth -= 1;
                }
            }
            row -= 1;
            start_col = -1;
        }
        if (op_row == null) return null;

        // Find closer: walk forward from cursor, tracking depth.
        depth = 0;
        var cl_row: ?usize = null;
        var cl_col: usize = 0;
        row = @intCast(s.cursor_row);
        var fwd_start: isize = @intCast(s.cursor_col);
        scan_fwd: while (row < @as(isize, @intCast(total))) {
            const line = s.getLineContent(@intCast(row)) catch break;
            defer self.allocator.free(line);
            var c: isize = if (row == @as(isize, @intCast(s.cursor_row))) fwd_start else 0;
            while (c < @as(isize, @intCast(line.len))) : (c += 1) {
                const b = line[@intCast(c)];
                if (b == open) depth += 1;
                if (b == close) {
                    if (depth == 0) {
                        cl_row = @intCast(row);
                        cl_col = @intCast(c);
                        break :scan_fwd;
                    }
                    depth -= 1;
                }
            }
            row += 1;
            fwd_start = 0;
        }
        if (cl_row == null) return null;

        if (around) {
            return .{ .start_row = op_row.?, .start_col = op_col, .end_row = cl_row.?, .end_col = cl_col + 1 };
        }
        // inside: skip the opener and the closer
        return .{ .start_row = op_row.?, .start_col = op_col + 1, .end_row = cl_row.?, .end_col = cl_col };
    }

    /// Ctrl+D — find the next occurrence of the current selection (or
    /// the word under the cursor if no selection) and add a secondary
    /// cursor there. The primary cursor moves to the new match so the
    /// user immediately sees where they landed. Wraps at file end.
    /// Cleared by Esc or any line-altering command.
    pub fn addNextOccurrence(self: *Core) !void {
        const s = self.state();
        const buf_id = self.buffer_manager.getActive().id;
        // Buffer switched out from under us — drop stale cursors.
        if (self.multi_cursors.items.len > 0 and self.multi_cursor_buffer_id != buf_id) {
            self.clearMultiCursors();
        }

        // Seed: selection text (visual mode) or word under cursor.
        if (self.multi_cursors.items.len == 0) {
            self.multi_cursor_buffer_id = buf_id;
            self.multi_cursor_query.clearRetainingCapacity();

            if (self.mode == .visual and s.selection_anchor != null) {
                const sel = self.normalizedSelection() orelse return;
                const text = try self.copyRangeText(sel);
                defer self.allocator.free(text);
                try self.multi_cursor_query.appendSlice(self.allocator, text);
                // The selection itself becomes the "primary cursor" anchor;
                // we don't add it as a secondary since it's already the
                // primary site.
                s.selection_anchor = null;
                self.mode = .select;
                // Place the primary cursor at the START of the selection
                // for predictable next-search origin.
                s.cursor_row = sel.start_row;
                s.cursor_col = sel.start_col;
            } else {
                const line = s.getLineContent(s.cursor_row) catch return;
                defer self.allocator.free(line);
                const wr = unicode.wordRangeAt(line, s.cursor_col) orelse {
                    self.setStatusLiteralLeveled(.warning, "Place cursor on a word", 1500);
                    return;
                };
                try self.multi_cursor_query.appendSlice(self.allocator, line[wr.start..wr.end]);
                s.cursor_col = wr.start;
            }
        }

        const query = self.multi_cursor_query.items;
        if (query.len == 0) return;

        // Find next occurrence after the current primary cursor.
        const search_from_off = s.getOffsetFor(s.cursor_row, s.cursor_col) + query.len;
        const found = (s.buffer.find(query, search_from_off) catch null) orelse
            (s.buffer.find(query, 0) catch null) orelse {
            self.setStatusLiteralLeveled(.info, "No more matches", 1200);
            return;
        };

        // Bank the primary as a secondary, then move primary to the new match.
        try self.multi_cursors.append(self.allocator, .{
            .row = s.cursor_row,
            .col = s.cursor_col,
        });
        s.updateCursorFromOffset(found);
        s.preferred_col = null;
        self.recenterIfOffscreen();
        self.refreshMultiCursorDecorations();
        const msg = std.fmt.bufPrint(&self.skip_status_buf, "{d} cursors active", .{self.multi_cursors.items.len + 1}) catch return;
        self.status_message = msg;
        self.status_message_expires = std.Io.Clock.real.now(self.io).toMilliseconds() + 1500;
        try self.sendUpdate();
    }

    pub fn clearMultiCursors(self: *Core) void {
        self.multi_cursors.clearRetainingCapacity();
        self.multi_cursor_query.clearRetainingCapacity();
        self.decoration_manager.removeBySource("multi_cursor");
    }

    fn refreshMultiCursorDecorations(self: *Core) void {
        self.decoration_manager.removeBySource("multi_cursor");
        const query_len = self.multi_cursor_query.items.len;
        for (self.multi_cursors.items) |mc| {
            _ = self.decoration_manager.add(
                Range.singleLine(mc.row, mc.col, mc.col + query_len),
                .word_highlight,
                80,
                null,
                "multi_cursor",
            ) catch continue;
        }
    }

    const NormalizedSelection = struct {
        start_row: usize,
        start_col: usize,
        end_row: usize,
        end_col: usize,
    };

    fn normalizedSelection(self: *Core) ?NormalizedSelection {
        const s = self.state();
        const anchor = s.selection_anchor orelse return null;
        var start_row = anchor.row;
        var start_col = anchor.col;
        var end_row = s.cursor_row;
        var end_col = s.cursor_col;
        if (start_row > end_row or (start_row == end_row and start_col > end_col)) {
            std.mem.swap(usize, &start_row, &end_row);
            std.mem.swap(usize, &start_col, &end_col);
        }
        return .{
            .start_row = start_row,
            .start_col = start_col,
            .end_row = end_row,
            .end_col = end_col,
        };
    }

    fn copyRangeText(self: *Core, sel: NormalizedSelection) ![]u8 {
        const s = self.state();
        const start_off = s.getOffsetFor(sel.start_row, sel.start_col);
        const end_off = s.getOffsetFor(sel.end_row, sel.end_col);
        if (end_off <= start_off) return self.allocator.dupe(u8, "");
        const len = end_off - start_off;
        var out = try self.allocator.alloc(u8, len);
        var idx: usize = 0;
        while (idx < len) : (idx += 1) {
            out[idx] = s.buffer.getCharAt(start_off + idx) orelse 0;
        }
        return out;
    }

    fn surroundPair(ch: u8) struct { open: u8, close: u8 } {
        return switch (ch) {
            '(', ')', 'b' => .{ .open = '(', .close = ')' },
            '[', ']' => .{ .open = '[', .close = ']' },
            '{', '}', 'B' => .{ .open = '{', .close = '}' },
            '<', '>' => .{ .open = '<', .close = '>' },
            // Quotes: open and close are the same byte.
            '"' => .{ .open = '"', .close = '"' },
            '\'' => .{ .open = '\'', .close = '\'' },
            '`' => .{ .open = '`', .close = '`' },
            else => .{ .open = ch, .close = ch },
        };
    }

    /// `S <c>` in visual mode: wrap the active selection with the pair
    /// for `<c>`. Single-byte delimiters (`"`, `'`) get the same byte
    /// on both sides; brackets get matched pairs. Cursor lands after
    /// the closer.
    pub fn addSurround(self: *Core, ch: u8) !void {
        if (self.rejectReadOnlyPresentationEdit()) return;
        const s = self.state();
        const anchor = s.selection_anchor orelse {
            self.setStatusLiteralLeveled(.warning, "No selection to surround", 1500);
            return;
        };

        // Normalize so (start, end) is in document order.
        var start_row = anchor.row;
        var start_col = anchor.col;
        var end_row = s.cursor_row;
        var end_col = s.cursor_col;
        if (start_row > end_row or (start_row == end_row and start_col > end_col)) {
            std.mem.swap(usize, &start_row, &end_row);
            std.mem.swap(usize, &start_col, &end_col);
        }

        const pair = surroundPair(ch);
        const end_off = s.getOffsetFor(end_row, end_col);
        const close_str = [_]u8{pair.close};
        try s.insertTextAtOffset(end_off, &close_str);
        const start_off = s.getOffsetFor(start_row, start_col);
        const open_str = [_]u8{pair.open};
        try s.insertTextAtOffset(start_off, &open_str);

        // Drop the selection; place cursor just after the closer.
        s.updateCursorFromOffset(end_off + 2);
        s.selection_anchor = null;
        self.mode = .select;
        try self.sendUpdate();
    }

    /// `s d <c>` in select mode: delete the enclosing pair `<c>`
    /// (e.g. the parens around the cursor). Leaves contents intact.
    pub fn deleteSurround(self: *Core, ch: u8) !void {
        if (self.rejectReadOnlyPresentationEdit()) return;
        const s = self.state();
        const pair = surroundPair(ch);
        const range = if (pair.open == pair.close)
            self.textObjectQuote(pair.open, true)
        else
            self.textObjectBracket(pair.open, pair.close, true);
        const r = range orelse {
            self.setStatusLiteralLeveled(.warning, "No matching surround pair", 1500);
            return;
        };

        // Delete closer FIRST (later in buffer) so the opener's offset
        // remains valid for the second delete.
        const close_off = s.getOffsetFor(r.end_row, r.end_col);
        try s.deleteRangeAtOffset(close_off - 1, close_off);
        const open_off = s.getOffsetFor(r.start_row, r.start_col);
        try s.deleteRangeAtOffset(open_off, open_off + 1);
        try self.sendUpdate();
    }

    /// `s r <old> <new>` in select mode: swap the surrounding `<old>`
    /// pair for `<new>`. Same lookup as deleteSurround, then re-emit.
    pub fn replaceSurround(self: *Core, old_ch: u8, new_ch: u8) !void {
        if (self.rejectReadOnlyPresentationEdit()) return;
        const s = self.state();
        const old_pair = surroundPair(old_ch);
        const new_pair = surroundPair(new_ch);
        const range = if (old_pair.open == old_pair.close)
            self.textObjectQuote(old_pair.open, true)
        else
            self.textObjectBracket(old_pair.open, old_pair.close, true);
        const r = range orelse {
            self.setStatusLiteralLeveled(.warning, "No matching surround pair", 1500);
            return;
        };

        // Replace closer FIRST so the opener offset survives.
        const close_off = s.getOffsetFor(r.end_row, r.end_col);
        try s.deleteRangeAtOffset(close_off - 1, close_off);
        const new_close = [_]u8{new_pair.close};
        try s.insertTextAtOffset(close_off - 1, &new_close);
        const open_off = s.getOffsetFor(r.start_row, r.start_col);
        try s.deleteRangeAtOffset(open_off, open_off + 1);
        const new_open = [_]u8{new_pair.open};
        try s.insertTextAtOffset(open_off, &new_open);
        try self.sendUpdate();
    }

    /// `]g` / `[g` — move the cursor to the start of the next or previous
    /// git diff hunk. Adjacent changed/added/deleted lines form one hunk;
    /// the cursor lands on the hunk's first line. Wraps at file boundaries.
    pub fn jumpToHunk(self: *Core, forward: bool) !void {
        if (self.diff_highlights.items.len == 0) {
            self.setStatusLiteralLeveled(.info, "No git hunks in this buffer", 1500);
            return;
        }
        const s = self.state();

        // Build the sorted list of hunk start lines. A hunk start is any
        // diff line whose immediately-previous line is not itself a diff
        // line. Sorted on insert by `addDiffDecorations`, so a single pass
        // is enough.
        var lines = std.ArrayListUnmanaged(usize).empty;
        defer lines.deinit(self.allocator);
        for (self.diff_highlights.items) |h| try lines.append(self.allocator, h.line);
        std.sort.block(usize, lines.items, {}, std.sort.asc(usize));

        var hunk_starts = std.ArrayListUnmanaged(usize).empty;
        defer hunk_starts.deinit(self.allocator);
        var prev_line: ?usize = null;
        for (lines.items) |line| {
            if (prev_line) |pl| {
                if (line != pl + 1) try hunk_starts.append(self.allocator, line);
            } else {
                try hunk_starts.append(self.allocator, line);
            }
            prev_line = line;
        }
        if (hunk_starts.items.len == 0) return;

        const cur = s.cursor_row;
        var target: ?usize = null;
        if (forward) {
            for (hunk_starts.items) |h| {
                if (h > cur) {
                    target = h;
                    break;
                }
            }
            if (target == null) target = hunk_starts.items[0]; // wrap
        } else {
            var i = hunk_starts.items.len;
            while (i > 0) : (i -= 1) {
                if (hunk_starts.items[i - 1] < cur) {
                    target = hunk_starts.items[i - 1];
                    break;
                }
            }
            if (target == null) target = hunk_starts.items[hunk_starts.items.len - 1]; // wrap
        }
        s.cursor_row = target.?;
        s.cursor_col = 0;
        self.recenterIfOffscreen();
        try self.sendUpdate();
    }

    /// `]s` / `[s` — move the cursor to the start of the next or
    /// previous named AST sibling. No-op (returns false) if the syntax
    /// tree isn't loaded or the cursor is already at a tree boundary.
    pub fn jumpToSibling(self: *Core, forward: bool) !bool {
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
    pub fn jumpToFunction(self: *Core, forward: bool) !bool {
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

    pub const StructuralAdjust = enum { expand, shrink };

    /// Visual-mode `+` / `-` — grow or contract the selection to match
    /// the enclosing AST node (parent) or its first named child.
    pub fn adjustSelectionStructural(self: *Core, kind: StructuralAdjust) !void {
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
    pub fn refreshGitBranchIfStale(self: *Core) void {
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
        const branch_ok = switch (res.term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (!branch_ok) {
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

    pub fn openFileAtLine(self: *Core, path: []const u8, line: usize) !void {
        const opened = try self.buffer_manager.openFile(path);
        // Force-load if we reused an existing lazy buffer entry
        // (same fix as openFileByPath — without this, bookmark
        // jumps to lazy-loaded files land on an empty piece-table).
        self.buffer_manager.loadBufferContent(opened) catch |err| {
            log.warn("loadBufferContent failed for {s}: {}", .{ path, err });
        };

        try self.ensureLspDocument();

        const s = self.state();
        if (line > 0) {
            s.cursor_row = line - 1;
            s.cursor_col = 0;
        }
    }
};
