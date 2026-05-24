//! Leader-chord dispatch table + pane focus / close helpers.
//!
//! After `Space <prefix>` (where prefix ∈ {l, g, w, t}) is
//! detected, the next key is dispatched here. `LeaderDispatch.handle`
//! is the entry point; it's a giant switch over `(prefix, key)`
//! that bridges to the appropriate command module.
//!
//! Pane-focus and close helpers live alongside because they're
//! invoked from both `Space w h/j/k/l` (chord) and from
//! `Space <arrow>` / `Space k` (top-level shortcuts). Keeping them
//! adjacent to the chord switch means new pane operations land in
//! one place.
//!
//! Functions take `anytype` for `core` to dodge the circular
//! import with `core.zig` — same pattern the `commands/*.zig`
//! modules use. The trade-off is no IDE jump-to-defn for `core.*`
//! fields from inside these functions; the upside is that
//! `core.zig` shrinks materially.

const std = @import("std");
const vaxis = @import("vaxis");

const Keys = @import("../config/keys.zig").Keys;
const Buffer = @import("buffer_manager.zig").Buffer;

const LspCommands = @import("commands/lsp_commands.zig").LspCommands;
const GitCommands = @import("commands/git_commands.zig").GitCommands;
const SplitCommands = @import("commands/split_commands.zig").SplitCommands;
const ToggleCommands = @import("commands/toggle_commands.zig").ToggleCommands;

const log = std.log.scoped(.LeaderDispatch);

pub const LeaderDispatch = struct {
    /// Dispatch a key that arrived after a leader chord prefix
    /// (e.g. `Space l <key>`, `Space g <key>`). Unknown keys are
    /// silently ignored so the user can bail without typing Esc.
    pub fn handle(core: anytype, prefix: u8, key: vaxis.Key) !void {
        switch (prefix) {
            Keys.chord_lsp => switch (key.codepoint) {
                Keys.lsp_definition => try LspCommands.cmdLspGoToDefinition(core),
                Keys.lsp_references => try LspCommands.cmdLspFindReferences(core),
                Keys.lsp_hover => try LspCommands.cmdLspHover(core),
                Keys.lsp_code_action => try LspCommands.cmdLspCodeAction(core),
                Keys.lsp_format_buffer => try LspCommands.cmdLspFormatDocument(core),
                Keys.lsp_format_selection => try LspCommands.cmdLspFormatSelection(core),
                Keys.lsp_diagnostics => core.openDiagnosticsPicker(),
                Keys.lsp_document_symbols => try LspCommands.cmdDocumentSymbols(core),
                Keys.lsp_workspace_symbols => try LspCommands.cmdWorkspaceSymbols(core),
                Keys.lsp_toggle_inline_diagnostics => try ToggleCommands.cmdEditorToggleInlineDiagnostics(core),
                Keys.lsp_toggle_inlay_hints => try ToggleCommands.cmdEditorToggleInlayHints(core),
                Keys.lsp_toggle_format_on_save => try ToggleCommands.cmdLspToggleFormatOnSave(core),
                else => {},
            },
            Keys.chord_git => switch (key.codepoint) {
                Keys.git_diff => try GitCommands.cmdGitDiff(core),
                else => {},
            },
            Keys.chord_window => switch (key.codepoint) {
                Keys.win_split_horizontal => try SplitCommands.cmdSplitHorizontal(core),
                Keys.win_split_vertical => try SplitCommands.cmdSplitVertical(core),
                Keys.win_focus_left => focusPaneLeft(core),
                Keys.win_focus_down => focusPaneDown(core),
                Keys.win_focus_up => focusPaneUp(core),
                Keys.win_focus_right => focusPaneRight(core),
                Keys.win_close => closeCurrentPaneOrBuffer(core),
                else => {},
            },
            Keys.chord_toggle => switch (key.codepoint) {
                Keys.toggle_inline_diagnostics => try ToggleCommands.cmdEditorToggleInlineDiagnostics(core),
                Keys.toggle_inlay_hints => try ToggleCommands.cmdEditorToggleInlayHints(core),
                Keys.toggle_format_on_save => try ToggleCommands.cmdLspToggleFormatOnSave(core),
                // Other toggles (line_numbers, wrap, whitespace,
                // cursor_line) don't have command wrappers yet — wire
                // them up here as their setters land in config.
                else => {},
            },
            else => {},
        }
    }

    /// Move pane focus or close the active pane. Extracted from
    /// the leader switch so both the top-level arrow bindings and
    /// the `Space w <hjkl>` chord can share the same code.
    pub fn focusPaneLeft(core: anytype) void {
        if (core.split_manager) |*sm| {
            core.syncStateToPane();
            sm.focusLeft();
            core.syncPaneToState();
            core.ensureLspDocument() catch |err| {
                log.debug("ensureLspDocument failed on pane focus: {}", .{err});
            };
        }
    }
    pub fn focusPaneRight(core: anytype) void {
        if (core.split_manager) |*sm| {
            core.syncStateToPane();
            sm.focusRight();
            core.syncPaneToState();
            core.ensureLspDocument() catch |err| {
                log.debug("ensureLspDocument failed on pane focus: {}", .{err});
            };
        }
    }
    pub fn focusPaneUp(core: anytype) void {
        if (core.split_manager) |*sm| {
            core.syncStateToPane();
            sm.focusUp();
            core.syncPaneToState();
            core.ensureLspDocument() catch |err| {
                log.debug("ensureLspDocument failed on pane focus: {}", .{err});
            };
        }
    }
    pub fn focusPaneDown(core: anytype) void {
        if (core.split_manager) |*sm| {
            core.syncStateToPane();
            sm.focusDown();
            core.syncPaneToState();
            core.ensureLspDocument() catch |err| {
                log.debug("ensureLspDocument failed on pane focus: {}", .{err});
            };
        }
    }
    pub fn closeCurrentPaneOrBuffer(core: anytype) void {
        // Snapshot opened_from off the *current* buffer before we
        // close it — once closed, the Buffer entry is freed and
        // the field is gone. We'll consult it below to restore
        // the trigger cursor on the successor buffer.
        const opened_from: ?Buffer.OpenedFrom = blk: {
            const idx = core.buffer_manager.active_index;
            if (idx >= core.buffer_manager.buffers.items.len) break :blk null;
            break :blk core.buffer_manager.buffers.items[idx].opened_from;
        };

        if (core.split_manager) |*sm| {
            if (sm.hasSplits()) {
                core.syncStateToPane();
                sm.closePane();
                core.syncPaneToState();
                const remaining = sm.getFocusedPane();
                if (remaining.buffer_index < core.buffer_manager.buffers.items.len) {
                    core.buffer_manager.active_index = remaining.buffer_index;
                }
                if (!sm.hasSplits()) {
                    sm.deinit();
                    core.split_manager = null;
                }
            } else {
                const pane = sm.getFocusedPane();
                if (pane.buffer_index < core.buffer_manager.buffers.items.len) {
                    core.buffer_manager.active_index = pane.buffer_index;
                }
                sm.deinit();
                core.split_manager = null;
            }
        } else {
            // Track which id is going away so we can evict its
            // parked syntax tree from the SyntaxManager cache —
            // otherwise closed-but-reopened-from-cwd buffers
            // would keep the cache growing across the session.
            if (core.buffer_manager.closeActiveReturningId()) |closed_id| {
                core.syntax_manager.dropBuffer(closed_id);
            }
        }

        // Pull the successor buffer's content if it's still lazy.
        // Without this the user sees an empty buffer after
        // closing a virtual buffer (or anything else) on top of
        // a buffer that was opened via `Space e` / "open
        // directory" / session restore — all of which mark new
        // buffers `not_loaded = true` and rely on the first
        // switch to call `loadBufferContent`. Every other
        // buffer-switch site goes through
        // `refreshSyntaxForCurrentBuffer`; this one was missed
        // when the close helper was extracted.
        core.refreshSyntaxForCurrentBuffer();

        // If the just-closed buffer had an opened_from snapshot
        // and the successor active buffer is the one we were on
        // when we opened it, jump the cursor back to the trigger
        // location. No-op when buffer ids don't match (e.g. the
        // user moved through several files in between).
        if (opened_from) |of| {
            if (core.buffer_manager.active_index < core.buffer_manager.buffers.items.len) {
                const dst = &core.buffer_manager.buffers.items[core.buffer_manager.active_index];
                if (dst.id == of.buffer_id) {
                    const s = &dst.state;
                    s.cursor_row = of.row;
                    s.cursor_col = of.col;
                    s.preferred_col = null;
                    // Center the restored cursor so the user
                    // doesn't lose visual context.
                    const visible_rows: usize = if (core.win_size.rows > 2) core.win_size.rows - 2 else 1;
                    const half = visible_rows / 2;
                    s.scroll_offset = if (s.cursor_row >= half) s.cursor_row - half else 0;
                }
            }
        }
    }
};
