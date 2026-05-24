//! Modal pickers: references + diagnostics.
//!
//! Both follow the same shape — capture trigger position when
//! opening, list-and-select interface, Enter jumps (recording a
//! jump-list breadcrumb), Esc restores the trigger position.
//!
//! State fields stay on `Core` (they're small + accessed by the
//! snapshot builder in `sendUpdate`); only the *behaviour* moves
//! here. Functions take `anytype` for `core` to dodge the circular
//! import with `core.zig` — same pattern the `commands/*.zig`
//! modules use.

const std = @import("std");
const vaxis = @import("vaxis");

const protocol = @import("protocol.zig");
const Buffer = @import("buffer_manager.zig").Buffer;
const LSPManager = @import("../services/lsp_manager.zig").LSPManager;

const log = std.log.scoped(.Pickers);

pub const ReferencesPicker = struct {
    /// Populate the picker from the LSP result and switch to
    /// `.references_picker` mode. Snapshots the trigger location
    /// into `references_picker_origin` so Esc returns the cursor
    /// home.
    pub fn open(core: anytype, refs: []LSPManager.Location) !void {
        // Free any prior entries — caller's result may be smaller.
        for (core.references_picker_entries.items) |*entry| entry.deinit(core.allocator);
        core.references_picker_entries.clearRetainingCapacity();

        try core.references_picker_entries.ensureTotalCapacity(core.allocator, refs.len);
        for (refs) |r| {
            const full = try core.allocator.dupe(u8, r.file_path);
            errdefer core.allocator.free(full);
            const display = try core.allocator.dupe(u8, std.fs.path.basename(r.file_path));
            errdefer core.allocator.free(display);

            // Pull a trimmed source preview from disk; same logic
            // the old text-buffer build used, just per-entry.
            const snippet = readSnippet(core, r.file_path, r.line) catch
                try core.allocator.dupe(u8, "(unable to read)");

            try core.references_picker_entries.append(core.allocator, .{
                .full_path = full,
                .display_path = display,
                .line = r.line,
                .col = r.col,
                .snippet = snippet,
            });
        }

        core.references_picker_selected = 0;
        core.references_picker_scroll_offset = 0;
        core.references_picker_origin = captureCurrentLocationAsOpenedFrom(core);
        core.previous_mode = core.mode;
        core.mode = .references_picker;
    }

    /// Best-effort snippet read — opens the file, scans to the
    /// target line, trims and length-caps. Returns an owned slice;
    /// caller frees with `core.allocator`.
    fn readSnippet(core: anytype, file_path: []const u8, target_line: u32) ![]u8 {
        const content = std.Io.Dir.cwd().readFileAlloc(
            core.io,
            file_path,
            core.allocator,
            .limited(10 * 1024 * 1024),
        ) catch return error.SnippetUnavailable;
        defer core.allocator.free(content);

        var line_num: u32 = 0;
        var line_start: usize = 0;
        for (content, 0..) |ch, idx| {
            if (line_num == target_line) {
                var line_end = idx;
                while (line_end < content.len and content[line_end] != '\n') : (line_end += 1) {}
                const line_content = std.mem.trim(u8, content[line_start..line_end], " \t");
                const max_len: usize = 120;
                const take = if (line_content.len > max_len) line_content[0..max_len] else line_content;
                return try core.allocator.dupe(u8, take);
            }
            if (ch == '\n') {
                line_num += 1;
                line_start = idx + 1;
            }
        }
        return error.SnippetUnavailable;
    }

    /// Esc out of the picker — restore the trigger position (if
    /// the origin buffer is still present and current) and switch
    /// back to Select mode.
    pub fn close(core: anytype) void {
        if (core.references_picker_origin) |of| {
            if (core.buffer_manager.indexOfId(of.buffer_id)) |i| {
                core.buffer_manager.active_index = i;
                const s = &core.buffer_manager.buffers.items[i].state;
                s.cursor_row = of.row;
                s.cursor_col = of.col;
                s.preferred_col = null;
                const visible_rows: usize = if (core.win_size.rows > 2) core.win_size.rows - 2 else 1;
                const half = visible_rows / 2;
                s.scroll_offset = if (s.cursor_row >= half) s.cursor_row - half else 0;
                // Push restored state down to the focused pane so
                // split-mode users actually see the cursor / scroll
                // move. The buffer manager is now correct; without
                // this the pane keeps its picker-time state and the
                // restore is invisible.
                core.syncPaneToState();
            }
        }
        core.references_picker_origin = null;
        core.mode = .select;
    }

    /// Key dispatch for `.references_picker`. j/k move; Enter
    /// opens the entry (records a jump); Esc dismisses + restores
    /// trigger position.
    pub fn handleInput(core: anytype, key: vaxis.Key) !bool {
        if (key.matches(vaxis.Key.escape, .{})) {
            close(core);
            return true;
        }
        if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
            if (core.references_picker_selected > 0) core.references_picker_selected -= 1;
            return true;
        }
        if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
            if (core.references_picker_selected + 1 < core.references_picker_entries.items.len) {
                core.references_picker_selected += 1;
            }
            return true;
        }
        if (key.matches('g', .{})) {
            core.references_picker_selected = 0;
            return true;
        }
        if (key.matches('G', .{ .shift = true })) {
            if (core.references_picker_entries.items.len > 0) {
                core.references_picker_selected = core.references_picker_entries.items.len - 1;
            }
            return true;
        }
        if (key.matches(vaxis.Key.enter, .{})) {
            const idx = core.references_picker_selected;
            if (idx >= core.references_picker_entries.items.len) return true;
            const entry = core.references_picker_entries.items[idx];

            // Record the trigger location into the jump_list so
            // the user can Ctrl+O back even after this picker
            // closes. (Open stamped origin already; this is the
            // complementary jump_list breadcrumb.)
            if (core.references_picker_origin) |of| {
                if (core.buffer_manager.indexOfId(of.buffer_id)) |i| {
                    if (core.buffer_manager.buffers.items[i].file_path) |p| {
                        core.jump_list.recordJump(p, of.row, of.col) catch |err| {
                            log.debug("references picker jump_list record failed: {}", .{err});
                        };
                    }
                }
            }

            try core.openFileByPath(entry.full_path);
            const new_state = core.state();
            new_state.cursor_row = entry.line;
            new_state.cursor_col = entry.col;
            new_state.preferred_col = null;
            const visible_rows: usize = if (core.win_size.rows > 2) core.win_size.rows - 2 else 1;
            const half = visible_rows / 2;
            new_state.scroll_offset = if (new_state.cursor_row >= half) new_state.cursor_row - half else 0;
            // Push the new state to the focused pane so the cursor
            // and scroll actually appear there (split-mode fix).
            core.syncPaneToState();

            // Picker has done its job; close (without restoring
            // origin — the user explicitly went somewhere).
            core.references_picker_origin = null;
            core.mode = .select;
            return true;
        }
        return false;
    }
};

pub const DiagnosticsPicker = struct {
    /// Open the picker — the diagnostic list itself lives in the
    /// LSP server's per-URI cache (fetched fresh by sendUpdate),
    /// so Core just tracks the selected index, scroll offset, and
    /// trigger origin.
    pub fn open(core: anytype) void {
        // Only meaningful when the current buffer has a file path
        // — diagnostics are keyed by URI. Toast and bail otherwise.
        const s = core.state();
        if (s.file_path == null) {
            core.setStatusLiteralLeveled(.warning, "No diagnostics for unsaved buffer", 1500);
            return;
        }
        core.diagnostics_picker_selected = 0;
        core.diagnostics_picker_scroll_offset = 0;
        core.diagnostics_picker_origin = captureCurrentLocationAsOpenedFrom(core);
        core.previous_mode = core.mode;
        core.mode = .diagnostics_picker;
    }

    pub fn close(core: anytype) void {
        if (core.diagnostics_picker_origin) |of| {
            if (core.buffer_manager.indexOfId(of.buffer_id)) |i| {
                core.buffer_manager.active_index = i;
                const s = &core.buffer_manager.buffers.items[i].state;
                s.cursor_row = of.row;
                s.cursor_col = of.col;
                s.preferred_col = null;
                const visible_rows: usize = if (core.win_size.rows > 2) core.win_size.rows - 2 else 1;
                const half = visible_rows / 2;
                s.scroll_offset = if (s.cursor_row >= half) s.cursor_row - half else 0;
                // Push restored state to the focused pane — see
                // ReferencesPicker.close for the same fix rationale.
                core.syncPaneToState();
            }
        }
        core.diagnostics_picker_origin = null;
        core.mode = .select;
    }

    pub fn handleInput(core: anytype, key: vaxis.Key) !bool {
        if (key.matches(vaxis.Key.escape, .{})) {
            close(core);
            return true;
        }
        // The diagnostic count is derived from the LSP cache at
        // render time, but for input dispatch we need a stable
        // count *now*. Re-fetch — cheap, just a HashMap probe.
        const diag_count = countDiagnostics(core);
        if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
            if (core.diagnostics_picker_selected > 0) core.diagnostics_picker_selected -= 1;
            return true;
        }
        if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
            if (core.diagnostics_picker_selected + 1 < diag_count) {
                core.diagnostics_picker_selected += 1;
            }
            return true;
        }
        if (key.matches('g', .{})) {
            core.diagnostics_picker_selected = 0;
            return true;
        }
        if (key.matches('G', .{ .shift = true })) {
            if (diag_count > 0) core.diagnostics_picker_selected = diag_count - 1;
            return true;
        }
        if (key.matches(vaxis.Key.enter, .{})) {
            // Apply the jump in the trigger buffer (the diagnostic
            // is keyed to the current file). We don't openFileByPath
            // — diagnostics never cross files.
            if (core.diagnostics_picker_origin) |of| {
                if (core.buffer_manager.indexOfId(of.buffer_id)) |i| {
                    core.buffer_manager.active_index = i;
                    const target = diagnosticAt(core, core.diagnostics_picker_selected) orelse return true;
                    const s = &core.buffer_manager.buffers.items[i].state;
                    // Record the trigger origin in jump_list first.
                    if (core.buffer_manager.buffers.items[i].file_path) |p| {
                        core.jump_list.recordJump(p, of.row, of.col) catch |err| {
                            log.debug("diagnostics picker jump_list record failed: {}", .{err});
                        };
                    }
                    s.cursor_row = target.start_line;
                    s.cursor_col = target.start_col;
                    s.preferred_col = null;
                    const visible_rows: usize = if (core.win_size.rows > 2) core.win_size.rows - 2 else 1;
                    const half = visible_rows / 2;
                    s.scroll_offset = if (s.cursor_row >= half) s.cursor_row - half else 0;
                    // Push the cursor + scroll down to the focused
                    // pane so split-mode users actually see the jump.
                    core.syncPaneToState();
                }
            }
            core.diagnostics_picker_origin = null;
            core.mode = .select;
            return true;
        }
        return false;
    }

    /// Count diagnostics for the active buffer's file. Returns 0
    /// for unsaved buffers and on LSP fetch failure.
    pub fn countDiagnostics(core: anytype) usize {
        const s = core.state();
        const path = s.file_path orelse return 0;
        const diags = core.lsp_manager.getDiagnosticsForFile(core.allocator, path) catch return 0;
        defer LSPManager.freeDiagnostics(core.allocator, diags);
        return diags.len;
    }

    /// Snapshot of a single diagnostic at sorted-list index `idx`
    /// (sorted by line then col, matching the picker's render
    /// order). Returns null on out-of-range or LSP miss.
    pub fn diagnosticAt(core: anytype, idx: usize) ?protocol.DiagnosticSnapshot {
        const s = core.state();
        const path = s.file_path orelse return null;
        const diags = core.lsp_manager.getDiagnosticsForFile(core.allocator, path) catch return null;
        defer LSPManager.freeDiagnostics(core.allocator, diags);

        std.mem.sort(LSPManager.Diagnostic, diags, {}, struct {
            fn lt(_: void, a: LSPManager.Diagnostic, b: LSPManager.Diagnostic) bool {
                if (a.start_line != b.start_line) return a.start_line < b.start_line;
                return a.start_col < b.start_col;
            }
        }.lt);
        if (idx >= diags.len) return null;
        const d = diags[idx];
        return .{
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
            .message = "",
        };
    }
};

/// Capture the current cursor location as `Buffer.OpenedFrom` —
/// shared by both pickers when stamping their `*_origin` field.
/// Returns null when the active buffer has no file (the picker
/// would have nothing meaningful to restore to anyway).
pub fn captureCurrentLocationAsOpenedFrom(core: anytype) ?Buffer.OpenedFrom {
    const s = core.state();
    if (s.file_path == null) return null;
    return .{
        .buffer_id = core.buffer_manager.getActive().id,
        .row = s.cursor_row,
        .col = s.cursor_col,
    };
}
