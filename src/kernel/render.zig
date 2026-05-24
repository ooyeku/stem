//! Render snapshot builder. Owns the per-frame work of turning
//! Core's mutable editor state into the immutable
//! `protocol.RenderSnapshot` that the UI thread reads.
//!
//! Threading: the snapshot is built on the Core thread; the
//! arena it lives in is handed to the UI via `arena_pool` and
//! released back when the UI finishes the frame. Nothing here
//! holds Core locks across the channel — the snapshot is
//! self-contained.
//!
//! Layout:
//!   - `buildAndSend` is the single entry point Core calls each
//!     frame. It mirrors the old `Core.sendUpdate` body
//!     verbatim, accepting `core: anytype` so it can reach the
//!     hundreds of fields without having to thread each one
//!     through a parameter list. The handler runs through:
//!       1. Soft 60 Hz frame cap
//!       2. Scroll-state aging
//!       3. Search-decoration refresh
//!       4. Arena acquire + visible-row computation
//!       5. Mode-specific slice duplication (terminal, pickers,
//!          inputs, results)
//!       6. Syntax highlights (LSP-first, tree-sitter fallback,
//!          bracket coloring)
//!       7. Per-pane snapshots in split mode
//!       8. Diagnostics fetch + sort
//!       9. RenderSnapshot construct + encode + bus send
//!
//!   - `visualRowOfCursor` / `wrappedRowsForLine` are the pure
//!     helpers used by step 4. They take no Core state — just
//!     EditorState + viewport metrics — so they live here as
//!     file-level functions.

const std = @import("std");

const protocol = @import("protocol.zig");
const logger_service = @import("../services/logger.zig");
const LSPManager = @import("../services/lsp_manager.zig").LSPManager;
const SyntaxManager = @import("../syntax/manager.zig").SyntaxManager;
const hover_doc_mod = @import("../services/hover_doc.zig");
const EditorState = @import("../core/state.zig").EditorState;

const log = std.log.scoped(.Render);

pub fn buildAndSend(core: anytype) !void {
    @import("../services/thread_name.zig").markStep("send:enter");
    const now = std.Io.Clock.real.now(core.io).toMilliseconds();

    // Soft frame-rate cap. A snapshot built <16 ms ago is still
    // in the bus (or just consumed); building another one now
    // produces a frame the user can't perceive and the bus would
    // coalesce anyway (see main.zig render_update drain). Mark
    // need-to-render so the tick handler catches up and bail.
    // Critical UX paths (mode change, file open) still feel
    // instant because the previous render was, by definition,
    // <16 ms old.
    if (core.last_render_time > 0 and now - core.last_render_time < core.min_render_interval_ms) {
        core.needs_render = true;
        @import("../services/thread_name.zig").markStep("send:throttled");
        return;
    }
    core.last_render_time = now;
    core.needs_render = false;

    if (core.scroll_in_progress and core.last_scroll_time > 0) {
        if (now - core.last_scroll_time > core.scroll_timeout_ms) {
            core.scroll_in_progress = false;
        }
    }

    // Re-scan search decorations against the current buffer if a
    // search is still active. Without this, edits that shift text
    // leave the post-prompt highlights pointing at stale byte
    // ranges. The scan is bounded to ~100 visible lines and cheap.
    if (core.last_search_query.items.len > 0 and core.search_input.items.len == 0) {
        core.updateSearchDecorations() catch |err| {
            log.debug("search decoration refresh failed: {}", .{err});
        };
    }

    defer core.scroll_in_progress = false;

    core.version += 1;

    // Pool the arena across frames so we don't bounce pages in and out
    // of the process at the render cadence.
    const arena = try core.arena_pool.acquire();
    errdefer core.arena_pool.release(arena);
    const alloc = arena.allocator();

    if (core.mode == .buffer_picker) {
        const picker_visible_rows = if (core.win_size.rows > 5) core.win_size.rows - 5 else 1;
        if (core.buffer_manager.picker_selected < core.buffer_manager.picker_scroll_offset) {
            core.buffer_manager.picker_scroll_offset = core.buffer_manager.picker_selected;
        } else if (core.buffer_manager.picker_selected >= core.buffer_manager.picker_scroll_offset + picker_visible_rows) {
            core.buffer_manager.picker_scroll_offset = core.buffer_manager.picker_selected - picker_visible_rows + 1;
        }
    }

    const s = core.state();

    var visible_rows: usize = if (core.win_size.rows > 2) core.win_size.rows - 2 else 1;
    if (core.split_manager) |*sm| {
        if (sm.getAllPaneBounds(alloc, .{
            .cols = core.win_size.cols,
            .rows = core.win_size.rows,
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

    // Wrap-aware adjustment: long lines that soft-wrap to multiple
    // visual rows can push the cursor's *visual* position out of
    // the viewport even when its logical row is technically in
    // range. Walk the lines from `scroll_offset` to `cursor_row`,
    // summing wrapped row counts, and advance `scroll_offset` if
    // the cursor's visual position would land below the visible
    // area. The text width here approximates what the renderer
    // uses; it's exact for an unsplit window and a conservative
    // overestimate for splits, which only ever scrolls a hair too
    // far — preferable to leaving the cursor invisible.
    {
        const total_lines = s.buffer.lineCount();
        const gutter_digits: usize = if (total_lines > 0)
            std.math.log10_int(total_lines) + 1
        else
            1;
        const gutter_width = gutter_digits + 1;
        const text_width: usize = if (core.win_size.cols > gutter_width)
            core.win_size.cols - gutter_width
        else
            1;
        const tab_size: usize = core.storage.config.editor.tab_size;

        // Find a `scroll_offset` such that the cursor's visual
        // row (relative to the top of the viewport) is < visible_rows.
        // Cap the loop so a pathological line can't spin here.
        var guard: usize = 0;
        while (guard < 64) : (guard += 1) {
            const visual_row = visualRowOfCursor(
                s,
                s.scroll_offset,
                s.cursor_row,
                s.cursor_col,
                text_width,
                tab_size,
                core.allocator,
            ) catch break;
            if (visual_row < visible_rows) break;
            if (s.scroll_offset >= s.cursor_row) break;
            s.scroll_offset += 1;
        }
    }

    if (core.split_manager) |*sm| {
        if (sm.sync_scroll) {
            sm.setAllPanesScrollOffset(s.scroll_offset);
        }
    }

    core.syncStateToPane();

    @import("../services/thread_name.zig").markStep("send:visible_lines");
    const visible_lines = try s.buffer.getVisibleLines(alloc, s.scroll_offset, visible_rows + 5);

    @import("../services/thread_name.zig").markStep("send:terminal_slices");
    const terminal_input_slice = if (core.terminal_input.items.len > 0)
        try alloc.dupe(u8, core.terminal_input.items)
    else
        null;

    const terminal_output_slice = if (core.terminal_output.items.len > 0)
        try alloc.dupe(u8, core.terminal_output.items)
    else
        null;

    const save_as_input_slice = if (core.mode == .save_as_mode) try alloc.dupe(u8, core.save_as_input.items) else null;
    const search_input_slice = if (core.mode == .visual_search) try alloc.dupe(u8, core.search_input.items) else null;
    const command_palette_query_slice = if (core.mode == .command_palette) try alloc.dupe(u8, core.command_palette_input.items) else null;
    const go_to_line_input_slice = if (core.mode == .go_to_line) try alloc.dupe(u8, core.go_to_line_input.items) else null;
    const symbol_picker_query_slice = if (core.mode == .symbol_picker) try alloc.dupe(u8, core.symbol_picker_query.items) else null;
    const workspace_symbol_query_slice = if (core.mode == .workspace_symbol_picker) try alloc.dupe(u8, core.workspace_symbol_query.items) else null;

    @import("../services/thread_name.zig").markStep("send:logs");
    var logs_slice: ?[]const protocol.LogEntry = null;
    if (core.mode == .log_view) {
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

    @import("../services/thread_name.zig").markStep("send:cmd_palette");
    var command_palette_results: ?[]const protocol.CommandEntry = null;
    if (core.mode == .command_palette) {
        const entries = try alloc.alloc(protocol.CommandEntry, core.command_palette_results.items.len);
        for (core.command_palette_results.items, 0..) |cmd, i| {
            entries[i] = .{ .id = try alloc.dupe(u8, cmd.id), .title = try alloc.dupe(u8, cmd.title), .description = try alloc.dupe(u8, cmd.description) };
        }
        command_palette_results = entries;
    }

    @import("../services/thread_name.zig").markStep("send:file_picker");
    var picker_entries: ?[]const protocol.DirEntry = null;
    var file_picker_cwd: ?[]const u8 = null;
    if (core.mode == .file_picker or core.mode == .terminal) {
        file_picker_cwd = try alloc.dupe(u8, core.file_manager.cwd);
        if (core.mode == .file_picker and core.file_manager.entries.items.len > 0) {
            const entries = try alloc.alloc(protocol.DirEntry, core.file_manager.entries.items.len);
            for (core.file_manager.entries.items, 0..) |entry, i| {
                entries[i] = .{ .name = try alloc.dupe(u8, entry.name), .is_dir = entry.is_dir };
            }
            picker_entries = entries;
        }
    }

    var explorer_entries: ?[]const protocol.ExplorerEntry = null;
    var explorer_cwd: ?[]const u8 = null;
    var explorer_selected: usize = 0;
    var explorer_scroll: usize = 0;
    if (core.mode == .file_explorer) {
        if (core.file_explorer) |*fx| {
            explorer_cwd = try alloc.dupe(u8, fx.root);
            explorer_entries = try fx.snapshot(alloc);
            explorer_selected = fx.selected;
            explorer_scroll = fx.scroll_offset;
        }
    }

    // Mirror the references picker entries into the per-frame
    // arena so the renderer doesn't have to hold the core
    // allocator's slices across the message boundary.
    var refs_snap: ?[]const protocol.ReferenceEntry = null;
    var refs_sym_snap: ?[]const u8 = null;
    if (core.mode == .references_picker and core.references_picker_entries.items.len > 0) {
        const out = try alloc.alloc(protocol.ReferenceEntry, core.references_picker_entries.items.len);
        for (core.references_picker_entries.items, 0..) |e, i| {
            out[i] = .{
                .full_path = try alloc.dupe(u8, e.full_path),
                .display_path = try alloc.dupe(u8, e.display_path),
                .line = e.line,
                .col = e.col,
                .snippet = try alloc.dupe(u8, e.snippet),
            };
        }
        refs_snap = out;
        if (core.references_symbol_name) |sym| {
            refs_sym_snap = try alloc.dupe(u8, sym);
        }
    }

    // Diagnostics picker: fetch + sort + dupe message strings
    // into the arena.
    var diag_picker_snap: ?[]const protocol.DiagnosticPickerEntry = null;
    if (core.mode == .diagnostics_picker) {
        const ds = core.state();
        if (ds.file_path) |path| {
            if (core.lsp_manager.getDiagnosticsForFile(core.allocator, path)) |diags| {
                defer LSPManager.freeDiagnostics(core.allocator, diags);
                std.mem.sort(LSPManager.Diagnostic, diags, {}, struct {
                    fn lt(_: void, a: LSPManager.Diagnostic, b: LSPManager.Diagnostic) bool {
                        if (a.start_line != b.start_line) return a.start_line < b.start_line;
                        return a.start_col < b.start_col;
                    }
                }.lt);
                const out = try alloc.alloc(protocol.DiagnosticPickerEntry, diags.len);
                for (diags, 0..) |d, i| {
                    out[i] = .{
                        .line = d.start_line,
                        .col = d.start_col,
                        .severity = switch (d.severity) {
                            .err => .err,
                            .warning => .warning,
                            .info => .info,
                            .hint => .hint,
                        },
                        .message = try alloc.dupe(u8, d.message),
                    };
                }
                diag_picker_snap = out;
            } else |_| {}
        }
    }

    @import("../services/thread_name.zig").markStep("send:buffer_infos");
    const buffer_infos = try alloc.alloc(protocol.BufferInfo, core.buffer_manager.buffers.items.len);
    for (core.buffer_manager.buffers.items, 0..) |buf, i| {
        buffer_infos[i] = .{
            .id = buf.id,
            .name = try alloc.dupe(u8, buf.name),
            .modified = buf.state.modified,
            .is_active = i == core.buffer_manager.active_index,
            .is_large = buf.is_large,
        };
    }

    @import("../services/thread_name.zig").markStep("send:syntax_setup");
    var syntax_tokens: ?[]const protocol.SyntaxToken = null;

    // Inlay hints: throttled refresh request. The LSP returns
    // the entire file's hints, so we don't re-fire per-scroll
    // — once every 500 ms is enough to track edits and buffer
    // switches without flooding the server.
    if (core.storage.config.editor.inlay_hints and !core.activeBufferIsLarge()) blk_inlay: {
        const path = s.file_path orelse break :blk_inlay;
        if (LSPManager.getLangFromPath(path) == null) break :blk_inlay;
        const now_ms = std.Io.Clock.real.now(core.io).toMilliseconds();
        if (now_ms - core.last_inlay_request_ms >= 500) {
            core.last_inlay_request_ms = now_ms;
            const start_line: u32 = @intCast(s.scroll_offset);
            const end_line: u32 = @intCast(s.scroll_offset + visible_rows + 5);
            core.lsp_manager.requestInlayHint(path, start_line, end_line) catch |err| {
                log.debug("requestInlayHint failed for {s}: {s}", .{ path, @errorName(err) });
            };
        }
    }

    var lang = SyntaxManager.Language.unknown;
    if (s.file_path) |path| {
        lang = SyntaxManager.Language.fromFilename(path);
    } else {
        lang = SyntaxManager.Language.fromFilename(core.buffer_manager.getActive().name);
    }

    // Large-file mode short-circuit: skip tree-sitter, brackets, LSP
    // tokens entirely. The buffer renders as plain text so editing a
    // 5 MB log stays responsive. `is_large` is set once at open and
    // sticky for the buffer's lifetime, so this branch is a single
    // pointer dereference.
    const is_large_active = core.activeBufferIsLarge();
    if (lang != .unknown and !is_large_active) {
        // Materialize the active buffer's content exactly once for
        // every consumer below (parse submit, markdown highlight,
        // bracket finder). Previously each consumer called
        // `s.buffer.toString` independently — 3-4x rope flatten on a
        // 50k-line file per render frame. The arena owns this slice
        // so we don't free it explicitly.
        @import("../services/thread_name.zig").markStep("send:buffer_tostring");
        const active_content_opt: ?[]const u8 = s.buffer.toString(alloc) catch null;

        // Snapshot under the tree lock — without this, reading
        // `current_lang`/`current_resource_id`/`tree` races with
        // the parse worker that swaps them in under the same lock.
        const syn_state = core.syntax_manager.stateSnapshot();
        const active_buffer_id = core.buffer_manager.getActive().id;
        const buffer_changed = (syn_state.resource_id != active_buffer_id);

        // Buffer switch: park the outgoing tree + try to
        // restore a previously-parked tree for the incoming
        // buffer. If the parked tree's content_len matches
        // current content, it slots in instantly — no flash of
        // unhighlighted text waiting on the async parse. If
        // stale or absent, the tree is cleared and the normal
        // submitParse path below populates it.
        if (buffer_changed and syn_state.lang == lang) {
            const cur_len: usize = if (active_content_opt) |c| c.len else 0;
            core.syntax_manager.setActiveBuffer(active_buffer_id, lang, cur_len);
        }

        if (!core.scroll_in_progress) {
            const needs_reparse = (syn_state.lang != lang) or
                buffer_changed or
                (!syn_state.has_tree);

            if (needs_reparse) {
                if (syn_state.lang != lang) {
                    core.syntax_manager.setLanguageEnum(lang) catch |err| {
                        log.warn("Failed to set syntax language to {}: {}", .{ lang, err });
                    };
                }
                // Async — render proceeds with whatever tree we
                // currently have (possibly the parked one we
                // just restored, possibly none), and re-fires
                // once the worker installs the new tree.
                if (active_content_opt) |content| {
                    core.syntax_manager.submitParse(content, active_buffer_id) catch |err| {
                        log.debug("Syntax reparse submit failed for active buffer: {}", .{err});
                    };
                }
            }
        } else {
            if (!syn_state.has_tree or syn_state.lang != lang) {
                if (syn_state.lang != lang) {
                    core.syntax_manager.setLanguageEnum(lang) catch |err| {
                        log.warn("Failed to set syntax language to {}: {}", .{ lang, err });
                    };
                }
                if (active_content_opt) |content| {
                    core.syntax_manager.submitParse(content, active_buffer_id) catch |err| {
                        log.debug("Syntax parse submit during scroll failed: {}", .{err});
                    };
                }
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
            @import("../services/thread_name.zig").markStep("send:lsp_tokens");
            if (core.lsp_manager.copyVisibleTokens(alloc, s.file_path.?, s.scroll_offset, s.scroll_offset + visible_rows + 5)) |tokens| {
                syntax_tokens = tokens;
            } else |_| {
                syntax_tokens = null;
            }
        }

        // Highlights and bracket coloring always run, scroll or not.
        // The previous `if (!scroll_in_progress)` guard left the visible
        // region with only LSP tokens during scroll, which produced a
        // flash of unhighlighted text whenever LSP wasn't ready (cold
        // start, no LSP for the language, just-revealed lines). The
        // tree-sitter highlight is bounded to the visible range and is
        // microseconds; brackets are cached per buffer-version (see
        // `findBrackets`) so scroll is cheap.
        if (syntax_tokens == null or syntax_tokens.?.len == 0) {
            if (lang == .markdown) {
                @import("../services/thread_name.zig").markStep("send:highlight_md");
                if (active_content_opt) |content| {
                    syntax_tokens = core.syntax_manager.highlightMarkdown(alloc, content, s.scroll_offset, s.scroll_offset + visible_rows + 5) catch null;
                }
            } else {
                @import("../services/thread_name.zig").markStep("send:highlight_ts");
                syntax_tokens = core.syntax_manager.highlight(alloc, s.scroll_offset, s.scroll_offset + visible_rows + 5) catch null;
            }
        }

        if (lang != .markdown and lang != .unknown) {
            @import("../services/thread_name.zig").markStep("send:brackets");
            if (active_content_opt) |content| {
                if (core.syntax_manager.findBrackets(alloc, content, s.scroll_offset, s.scroll_offset + visible_rows + 5)) |bracket_tokens| {
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
            }
        }
    }

    @import("../services/thread_name.zig").markStep("send:symbol_picker");
    var symbol_picker_results: ?[]const protocol.SymbolEntry = null;
    if (core.mode == .symbol_picker) {
        const entries = try alloc.alloc(protocol.SymbolEntry, core.symbol_picker_results.items.len);
        for (core.symbol_picker_results.items, 0..) |sym, i| {
            entries[i] = .{ .name = try alloc.dupe(u8, sym.name), .kind = try alloc.dupe(u8, sym.kind), .line = sym.line };
        }
        symbol_picker_results = entries;
    }

    @import("../services/thread_name.zig").markStep("send:workspace_symbols");
    var workspace_symbol_results: ?[]const protocol.WorkspaceSymbolEntry = null;
    if (core.mode == .workspace_symbol_picker) {
        const entries = try alloc.alloc(protocol.WorkspaceSymbolEntry, core.workspace_symbol_results.items.len);
        for (core.workspace_symbol_results.items, 0..) |sym, i| {
            entries[i] = .{
                .name = try alloc.dupe(u8, sym.name),
                .kind = try alloc.dupe(u8, sym.kind),
                .file_path = try alloc.dupe(u8, sym.file_path),
                .line = sym.line,
                .col = sym.col,
            };
        }
        workspace_symbol_results = entries;
    }

    @import("../services/thread_name.zig").markStep("send:completion");
    var completion_items: ?[]const protocol.CompletionEntry = null;
    if (core.completion_active and core.filtered_completion_items.items.len > 0) {
        const entries = try alloc.alloc(protocol.CompletionEntry, core.filtered_completion_items.items.len);
        for (core.filtered_completion_items.items, 0..) |item, i| {
            entries[i] = .{
                .label = try alloc.dupe(u8, item.label),
                .kind = try alloc.dupe(u8, item.kind_icon),
                .detail = if (item.detail) |d| try alloc.dupe(u8, d) else "",
                .kind_category = item.kind_category,
            };
        }
        completion_items = entries;
    }

    @import("../services/thread_name.zig").markStep("send:hover");
    var hover_content: ?[]const u8 = null;
    if (core.hover_content) |h| hover_content = try alloc.dupe(u8, h);

    var hover_document_slot: ?hover_doc_mod.HoverDocument = null;
    if (core.hover_doc) |doc| {
        hover_document_slot = doc.clone(alloc) catch null;
    }

    const hover_loading = blk: {
        if (!core.hover_pending) break :blk false;
        const t_now = std.Io.Clock.real.now(core.io).toMilliseconds();
        break :blk (t_now - core.hover_request_sent_ms) >= core.hover_loading_grace_ms;
    };

    // Which-key: only visible when the user has explicitly asked
    // for it (Space twice). Never time-triggered — the auto-popup
    // hid the active editor line on small terminals.
    const which_key_visible = core.leader_pending and core.leader_help_requested;

    var file_path_slice: ?[]const u8 = null;
    if (s.file_path) |p| file_path_slice = try alloc.dupe(u8, p);

    @import("../services/thread_name.zig").markStep("send:panes");
    var pane_snapshots: []const protocol.PaneSnapshot = &.{};
    var split_enabled = false;
    var focused_pane_id: u32 = 0;

    if (core.split_manager) |*sm| {
        const content_rows = if (core.win_size.rows > 1) core.win_size.rows - 1 else 1;
        const params = protocol.RenderParams{ .rows = content_rows, .cols = core.win_size.cols };
        var bounds_list = try sm.getAllPaneBounds(alloc, params);
        defer bounds_list.deinit(alloc);
        const bounds = bounds_list.items;
        if (bounds.len > 0) {
            split_enabled = true;
            focused_pane_id = sm.getFocusedPaneId();

            const panes = try alloc.alloc(protocol.PaneSnapshot, bounds.len);
            for (bounds, 0..) |b, i| {
                if (b.pane.buffer_index >= core.buffer_manager.buffers.items.len) continue;
                const pane_buffer = &core.buffer_manager.buffers.items[b.pane.buffer_index];
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

                const pane_is_large = core.bufferIsLargeAt(b.pane.buffer_index);
                if (pane_lang != .unknown and !pane_is_large) {
                    // One toString per pane, shared by parse-submit
                    // and markdown-highlight (same rationale as the
                    // active-buffer block above).
                    const pane_content_opt: ?[]const u8 = p_state.buffer.toString(alloc) catch null;

                    if (!core.scroll_in_progress) {
                        const pane_buffer_id = pane_buffer.id;
                        const pane_syn = core.syntax_manager.stateSnapshot();
                        if (pane_syn.lang != pane_lang or pane_syn.resource_id != pane_buffer_id) {
                            if (pane_syn.lang != pane_lang) {
                                core.syntax_manager.setLanguageEnum(pane_lang) catch |err| {
                                    log.warn("Failed to set pane syntax language to {}: {}", .{ pane_lang, err });
                                };
                            }
                            if (pane_content_opt) |content| {
                                core.syntax_manager.submitParse(content, pane_buffer_id) catch |err| {
                                    log.debug("Pane syntax parse submit failed: {}", .{err});
                                };
                            }
                        }
                    }

                    const use_lsp = if (p_state.file_path != null) switch (pane_lang) {
                        .zig, .c, .cpp, .rust, .go, .python, .javascript, .typescript, .tsx, .java, .ruby, .csharp => true,
                        else => false,
                    } else false;
                    if (use_lsp) {
                        if (core.lsp_manager.copyVisibleTokens(alloc, p_state.file_path.?, pane_scroll, pane_scroll + safe_pane_rows + 5)) |tokens| {
                            pane_tokens = tokens;
                        } else |_| {
                            pane_tokens = null;
                        }
                    }

                    if (pane_tokens == null or pane_tokens.?.len == 0) {
                        if (pane_lang == .markdown) {
                            if (pane_content_opt) |content| {
                                pane_tokens = core.syntax_manager.highlightMarkdown(alloc, content, pane_scroll, pane_scroll + safe_pane_rows + 5) catch null;
                            }
                        } else {
                            pane_tokens = core.syntax_manager.highlight(alloc, pane_scroll, pane_scroll + safe_pane_rows + 5) catch null;
                        }
                    }
                }

                panes[i] = .{
                    .id = b.pane.id,
                    .buffer_index = b.pane.buffer_index,
                    .is_focused = b.pane.id == focused_pane_id,
                    .x = @as(f32, @floatFromInt(b.x)) / @as(f32, @floatFromInt(core.win_size.cols)),
                    .y = @as(f32, @floatFromInt(b.y)) / @as(f32, @floatFromInt(content_rows)),
                    .width = @as(f32, @floatFromInt(b.width)) / @as(f32, @floatFromInt(core.win_size.cols)),
                    .height = @as(f32, @floatFromInt(b.height)) / @as(f32, @floatFromInt(content_rows)),
                    .cursor_row = pane_cursor_row,
                    .cursor_col = pane_cursor_col,
                    .scroll_offset = pane_scroll,
                    .selection_anchor_row = pane_sel_row,
                    .selection_anchor_col = pane_sel_col,
                    .visible_lines = pane_lines,
                    .syntax_tokens = pane_tokens,
                    .total_lines = p_state.buffer.lineCount(),
                    .diff_highlights = if (core.diff_highlights.items.len > 0)
                        try alloc.dupe(protocol.DiffLineHighlight, core.diff_highlights.items)
                    else
                        null,
                };
            }
            pane_snapshots = panes;
        }
    }

    // Fetch + sort diagnostics once for the active buffer. The
    // snapshot fields below need (a) a sorted protocol-shaped list
    // and (b) error / warning counts. Previously each was a
    // separate `getDiagnosticsForFile` call, each acquiring the
    // diagnostics mutex and walking the per-URI map — 3x the work
    // for no reason. Drains to one call here.
    @import("../services/thread_name.zig").markStep("send:diagnostics");
    var diagnostics_snap: ?[]const protocol.DiagnosticSnapshot = null;
    var diagnostics_err_count: u32 = 0;
    var diagnostics_warn_count: u32 = 0;
    if (s.file_path) |dpath| {
        if (core.lsp_manager.getDiagnosticsForFile(alloc, dpath)) |diags| {
            if (diags.len > 0) {
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
                    switch (d.severity) {
                        .err => diagnostics_err_count += 1,
                        .warning => diagnostics_warn_count += 1,
                        else => {},
                    }
                }
                diagnostics_snap = out;
            }
        } else |_| {}
    }

    @import("../services/thread_name.zig").markStep("send:snapshot_create");
    const snapshot = try alloc.create(protocol.RenderSnapshot);
    snapshot.* = .{
        .visible_lines = visible_lines,
        .first_visible_line = s.scroll_offset,
        .total_lines = s.buffer.lineCount(),
        .cursor_row = s.cursor_row,
        .cursor_col = s.cursor_col,
        .nav_repeat_count = core.nav_repeat_count,
        .selection_anchor_row = if (s.selection_anchor) |a| a.row else null,
        .selection_anchor_col = if (s.selection_anchor) |a| a.col else null,
        .scroll_offset = s.scroll_offset,
        .version = core.version,
        .mode = core.mode,
        .terminal_output = terminal_output_slice,
        .terminal_input = terminal_input_slice,
        .terminal_cwd = if (core.terminal_cwd) |cwd| try alloc.dupe(u8, cwd) else null,
        .terminal_scroll_offset = core.terminal_scroll_offset,
        .terminal_running = core.terminal_running,
        .file_path = file_path_slice,
        .file_modified = s.modified,
        .buffers = buffer_infos,
        .active_buffer_index = core.buffer_manager.active_index,
        .buffer_picker_selected = core.buffer_manager.picker_selected,
        .file_picker_cwd = file_picker_cwd,
        .file_picker_entries = picker_entries,
        .references_entries = refs_snap,
        .references_selected = core.references_picker_selected,
        .references_scroll_offset = core.references_picker_scroll_offset,
        .references_symbol = refs_sym_snap,
        .diagnostics_entries = diag_picker_snap,
        .diagnostics_picker_selected = core.diagnostics_picker_selected,
        .diagnostics_picker_scroll_offset = core.diagnostics_picker_scroll_offset,
        .file_explorer_cwd = explorer_cwd,
        .file_explorer_entries = explorer_entries,
        .file_explorer_selected = explorer_selected,
        .file_explorer_scroll_offset = explorer_scroll,
        .file_picker_selected = core.file_manager.selected_index,
        .buffer_picker_scroll_offset = core.buffer_manager.picker_scroll_offset,
        .buffer_picker_number_input = if (core.mode == .buffer_picker and core.buffer_picker_number_input.items.len > 0)
            try alloc.dupe(u8, core.buffer_picker_number_input.items)
        else
            null,
        .save_as_input = save_as_input_slice,
        .search_input = search_input_slice,
        .search_direction_forward = (core.search_direction == .forward),
        .search_match_count = core.search_match_count,
        .search_match_index = core.search_match_index,
        .command_palette_query = command_palette_query_slice,
        .command_palette_results = command_palette_results,
        .command_palette_selected = core.command_palette_selected,
        .syntax_tokens = syntax_tokens,
        .hover_content = hover_content,
        .hover_document = hover_document_slot,
        .hover_anchor_row = core.hover_anchor_row,
        .hover_anchor_col = core.hover_anchor_col,
        .hover_scroll_offset = core.hover_scroll_offset,
        .hover_sticky = core.hover_sticky,
        .hover_loading = hover_loading,
        .which_key_visible = which_key_visible,
        .leader_chord = core.leader_chord,
        .leader_pending = core.leader_pending,
        .go_to_line_input = go_to_line_input_slice,
        .symbol_picker_query = symbol_picker_query_slice,
        .workspace_symbol_query = workspace_symbol_query_slice,
        .workspace_symbol_results = workspace_symbol_results,
        .workspace_symbol_selected = core.workspace_symbol_selected,
        .workspace_symbol_pending = core.workspace_symbol_pending,
        .symbol_picker_results = symbol_picker_results,
        .symbol_picker_selected = core.symbol_picker_selected,
        .completion_active = core.completion_active,
        .completion_items = completion_items,
        .completion_selected = core.completion_selected,
        .signature_help_label = if (core.signature_help) |sh| try alloc.dupe(u8, sh.label) else null,
        .signature_help_active_parameter = if (core.signature_help) |sh| sh.active_parameter else 0,
        .signature_help_parameters = if (core.signature_help) |sh| blk: {
            const out = try alloc.alloc([]const u8, sh.parameters.len);
            for (sh.parameters, 0..) |p, i| out[i] = try alloc.dupe(u8, p);
            break :blk out;
        } else null,
        .inlay_hints = blk_ih: {
            if (!core.storage.config.editor.inlay_hints) break :blk_ih null;
            if (core.activeBufferIsLarge()) break :blk_ih null;
            const path = s.file_path orelse break :blk_ih null;
            const hints = core.lsp_manager.copyInlayHints(alloc, path) catch break :blk_ih null;
            if (hints.len == 0) break :blk_ih null;
            // Filter to the visible range — there's no point
            // shipping hints the renderer will discard.
            var out: std.ArrayListUnmanaged(protocol.InlayHintSnapshot) = .empty;
            errdefer out.deinit(alloc);
            const first: u32 = @intCast(s.scroll_offset);
            const last: u32 = @intCast(s.scroll_offset + visible_rows + 5);
            for (hints) |h| {
                if (h.line < first or h.line >= last) continue;
                try out.append(alloc, .{
                    .line = h.line,
                    .col = h.col,
                    .label = h.label,
                    .kind = h.kind,
                    .padding_left = h.padding_left,
                    .padding_right = h.padding_right,
                });
            }
            break :blk_ih try out.toOwnedSlice(alloc);
        },
        .split_enabled = split_enabled,
        .panes = pane_snapshots,
        .focused_pane_id = focused_pane_id,
        .plugin_count = core.plugin_manager.wasm_plugins.count() + core.plugin_manager.process_plugins.count(),
        .plugin_status_items = try core.plugin_manager.snapshotStatusItems(alloc),
        .plugin_panels = try core.plugin_manager.snapshotPanels(alloc),
        .lsp_status = try core.lsp_manager.getActiveServerStatus(alloc),
        .logs = logs_slice,
        .editor_config = .{
            .tab_size = core.storage.config.editor.tab_size,
            .insert_spaces = core.storage.config.editor.insert_spaces,
            .line_numbers = switch (core.storage.config.editor.line_numbers) {
                .absolute => .absolute,
                .relative => .relative,
                .none => .none,
            },
            .wrap = core.storage.config.editor.wrap,
            .show_status_bar = core.storage.config.ui.show_status_bar,
            .cursor_line = core.storage.config.editor.cursor_line,
            .inline_diagnostics = core.storage.config.editor.inline_diagnostics,
            .inlay_hints = core.storage.config.editor.inlay_hints,
        },
        .global_search_query = if (core.global_search_query.items.len > 0)
            try alloc.dupe(u8, core.global_search_query.items)
        else
            null,
        .global_search_replace = if (core.global_search_replace.items.len > 0)
            try alloc.dupe(u8, core.global_search_replace.items)
        else
            null,
        .global_search_results = blk: {
            if (core.global_search_results.items.len == 0) {
                // Send an allocated empty slice so the view can tell
                // "search ran, no matches" from "no search yet". The
                // latter is signalled by `global_search_ran = false`.
                break :blk try alloc.alloc(protocol.GlobalSearchFileGroup, 0);
            }
            const results = try alloc.alloc(protocol.GlobalSearchFileGroup, core.global_search_results.items.len);
            for (core.global_search_results.items, 0..) |group, i| {
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
            for (core.global_search_results.items) |group| {
                count += group.matches.len;
            }
            break :blk count;
        },
        .global_search_total_files = core.global_search_results.items.len,
        .global_search_selected_file = core.global_search_selected_file,
        .global_search_selected_match = core.global_search_selected_match,
        .global_search_focus_replace = core.global_search_focus_replace,
        .global_search_options = core.global_search_options,
        .global_search_ran = core.global_search_ran,
        .git_branch = blk_g: {
            core.refreshGitBranchIfStale();
            if (core.git_branch) |b| break :blk_g try alloc.dupe(u8, b);
            break :blk_g null;
        },
        .active_job_count = @intCast(core.job_manager.activeCount()),
        .diff_highlight_lines = if (core.diff_highlights.items.len > 0)
            try alloc.dupe(protocol.DiffLineHighlight, core.diff_highlights.items)
        else
            null,
        .diagnostics = diagnostics_snap,
        .diagnostic_error_count = diagnostics_err_count,
        .diagnostic_warning_count = diagnostics_warn_count,
        .status_message = blk: {
            const current_time = std.Io.Clock.real.now(core.io).toMilliseconds();
            if (core.status_message != null and current_time < core.status_message_expires) {
                break :blk core.status_message;
            } else {
                core.status_message = null;
                break :blk null;
            }
        },
        .status_message_level = core.status_message_level,
    };

    @import("../services/thread_name.zig").markStep("send:encode");
    var msg = protocol.Message{ .render_update = .{
        .snapshot_ptr = @intFromPtr(snapshot),
        .arena_ptr = @intFromPtr(arena),
        .pool_ptr = @intFromPtr(&core.arena_pool),
    } };

    const bytes = try msg.encode(core.allocator);
    defer core.allocator.free(bytes);
    // Renders coalesce: only the freshest snapshot matters. The
    // `version` field (bumped above) is the slot identity so the
    // bus can tell when it's actually replacing an earlier frame.
    @import("../services/thread_name.zig").markStep("send:bus_send");
    try core.ui_bus.sendCoalesced(.render, bytes, core.version);
    @import("../services/thread_name.zig").markStep("send:done");
}

fn visualRowOfCursor(
    s: *EditorState,
    top_row: usize,
    cursor_row: usize,
    cursor_col: usize,
    text_width: usize,
    tab_size: usize,
    allocator: std.mem.Allocator,
) !usize {
    if (text_width == 0 or cursor_row < top_row) return 0;
    var visual: usize = 0;
    var row: usize = top_row;
    while (row < cursor_row) : (row += 1) {
        visual += wrappedRowsForLine(s, row, text_width, tab_size, allocator);
    }
    // Cursor row: count rows up to `cursor_col` characters in.
    const line = s.getLineContent(cursor_row) catch return visual;
    defer allocator.free(line);
    var col_used: usize = 0;
    var byte_idx: usize = 0;
    var char_idx: usize = 0;
    var extra_rows: usize = 0;
    while (byte_idx < line.len and char_idx < cursor_col) {
        const len = std.unicode.utf8ByteSequenceLength(line[byte_idx]) catch 1;
        if (byte_idx + len > line.len) break;
        const cw: usize = if (line[byte_idx] == '\t') tab_size else 1;
        if (col_used + cw > text_width) {
            extra_rows += 1;
            col_used = 0;
        }
        col_used += cw;
        byte_idx += len;
        char_idx += 1;
    }
    return visual + extra_rows;
}

fn wrappedRowsForLine(
    s: *EditorState,
    row: usize,
    text_width: usize,
    tab_size: usize,
    allocator: std.mem.Allocator,
) usize {
    if (text_width == 0) return 1;
    const line = s.getLineContent(row) catch return 1;
    defer allocator.free(line);
    var rows: usize = 1;
    var col_used: usize = 0;
    var byte_idx: usize = 0;
    while (byte_idx < line.len) {
        const len = std.unicode.utf8ByteSequenceLength(line[byte_idx]) catch 1;
        if (byte_idx + len > line.len) break;
        const cw: usize = if (line[byte_idx] == '\t') tab_size else 1;
        if (col_used + cw > text_width) {
            rows += 1;
            col_used = 0;
        }
        col_used += cw;
        byte_idx += len;
    }
    return rows;
}
