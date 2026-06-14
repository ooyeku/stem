const std = @import("std");
const lsp = @import("../../services/lsp_manager.zig");
// `tree_sitter` no longer needed here — node access goes through
// `syntax_manager.nodeAt`, which returns a by-value snapshot.

const log = std.log.scoped(.LspCommands);

pub const LspCommands = struct {
    pub fn cmdLspFormatDocument(core: anytype) anyerror!void {
        const s = core.state();
        if (s.file_path) |path| {
            try core.lsp_manager.requestFormatting(path);
            core.setStatusLiteral("Requested format", 1500);
        } else {
            core.setStatusLiteralLeveled(.info, "Save the buffer first", 1500);
        }
    }

    pub fn cmdLspGoToDefinition(core: anytype) anyerror!void {
        log.info("cmdLspGoToDefinition called", .{});

        try core.ensureLspDocument();

        const s = core.state();
        if (s.file_path) |path| {
            var col = s.cursor_col;

            // `nodeAt` returns by-value so the parse worker can
            // freely install a new tree without leaving us holding
            // a dangling node pointer.
            if (core.syntax_manager.nodeAt(s.cursor_row, s.cursor_col)) |node_snap| {
                col = node_snap.start_col;
                log.info("Snapped cursor to node start: column {d} -> {d}", .{ s.cursor_col, col });
            }

            log.info("Requesting definition for {s} at ({d}, {d})", .{ path, s.cursor_row, col });
            try core.lsp_manager.requestDefinition(path, @intCast(s.cursor_row), @intCast(col));
            core.definition_pending = true;
            core.setStatusLiteral("Looking up definition…", 1500);
        } else {
            log.warn("No file path for go-to-definition", .{});
            core.setStatusLiteralLeveled(.info, "Save the buffer first", 1500);
        }
    }

    pub fn cmdLspShowDiagnostics(core: anytype) anyerror!void {
        const diagnostics = core.lsp_manager.getDiagnostics(core.allocator) catch return;
        defer lsp.LSPManager.freeDiagnostics(core.allocator, diagnostics);

        if (diagnostics.len == 0) {
            try core.buffer_manager.openVirtual("[Diagnostics]", "=== Diagnostics ===\n\nNo errors or warnings found.\n");
            try core.sendUpdate();
            return;
        }

        var text = std.ArrayListUnmanaged(u8).empty;
        defer text.deinit(core.allocator);

        try text.appendSlice(core.allocator, "=== Diagnostics ===\n\n");
        for (diagnostics) |d| {
            const severity_str = switch (d.severity) {
                .err => "ERROR",
                .warning => "WARN",
                .info => "INFO",
                .hint => "HINT",
            };
            const line_text = try std.fmt.allocPrint(core.allocator, "Ln {d}: [{s}] {s}\n", .{
                d.start_line + 1,
                severity_str,
                d.message,
            });
            defer core.allocator.free(line_text);
            try text.appendSlice(core.allocator, line_text);
        }

        try core.buffer_manager.openVirtual("[Diagnostics]", text.items);
        try core.sendUpdate();
    }

    pub fn cmdLspRestartServer(core: anytype) anyerror!void {
        const s = core.state();

        log.info("[LSP RESTART] User requested LSP restart for file: {s}", .{s.file_path orelse "none"});

        core.lsp_manager.stopServer();

        if (s.file_path) |path| {
            const LSPManager = @import("../../services/lsp_manager.zig").LSPManager;
            if (LSPManager.getLangFromPath(path)) |lang| {
                const root_path = std.fs.path.dirname(path);
                try core.lsp_manager.startServer(lang, root_path);

                const content = s.buffer.toString(core.allocator) catch return;
                defer core.allocator.free(content);
                try core.lsp_manager.documentOpened(path, content);
                log.info("[LSP RESTART] {s} server restarted for: {s}", .{ lang, path });
            }
        }
    }

    /// Scan the workspace and start an LSP server for every language
    /// we find — same logic that runs at startup, exposed as a
    /// command so the user can rewarm after a `cd`-style workflow or
    /// after pulling new code that introduces a new language.
    pub fn cmdLspPrewarm(core: anytype) anyerror!void {
        const cwd = std.Io.Dir.cwd().realPathFileAlloc(core.io, ".", core.allocator) catch |err| {
            log.warn("LSP prewarm: cannot resolve cwd: {}", .{err});
            return;
        };
        defer core.allocator.free(cwd);
        const queued = core.lsp_manager.prewarmWorkspaceLanguages(cwd) catch |err| {
            log.warn("LSP prewarm failed: {}", .{err});
            return;
        };
        log.info("[LSP PREWARM] queued {d} new server(s) for {s}", .{ queued, cwd });
    }

    pub fn cmdLspStatus(core: anytype) anyerror!void {
        var snapshot = try core.lsp_manager.healthSnapshot(core.allocator);
        defer snapshot.deinit(core.allocator);

        var aw: std.Io.Writer.Allocating = .init(core.allocator);
        errdefer aw.deinit();
        const w = &aw.writer;

        try w.print(
            \\# LSP Status
            \\
            \\- Servers: {d} running, {d} healthy, {d} unhealthy, {d} initializing
            \\- Open documents: {d}
            \\- Pending changes: {d}
            \\- In-progress starts: {d}
            \\- Restart-tracked languages: {d}
            \\- Vigil lifecycle: {d} crashes, {d} restarts scheduled
            \\
        , .{
            snapshot.running_servers,
            snapshot.healthy_servers,
            snapshot.unhealthy_servers,
            snapshot.initializing_servers,
            snapshot.open_documents,
            snapshot.pending_changes,
            snapshot.in_progress_starts,
            snapshot.restart_tracked_languages,
            snapshot.lifecycle.crashes,
            snapshot.lifecycle.restarts_scheduled,
        });

        if (snapshot.servers.len == 0) {
            try w.writeAll("\nNo LSP servers are registered yet.\n");
        } else {
            try w.writeAll("\n| Language | State | Restarts | Last Restart ms | Root |\n");
            try w.writeAll("|---|---|---:|---:|---|\n");
            for (snapshot.servers) |server| {
                try w.print(
                    "| `{s}` | {s} | {d} | {d} | {s} |\n",
                    .{
                        server.lang,
                        lspStateLabel(server),
                        server.restart_attempts,
                        server.last_restart_attempt_ms,
                        server.root_path orelse "-",
                    },
                );
            }
        }

        const body = try aw.toOwnedSlice();
        defer core.allocator.free(body);
        try core.openVirtualBuffer("[LSP Status]", body);
        try core.sendUpdate();
    }

    pub fn cmdLspHover(core: anytype) anyerror!void {
        try core.ensureLspDocument();

        const s = core.state();
        if (s.file_path) |path| {
            var col = s.cursor_col;
            if (core.syntax_manager.nodeAt(s.cursor_row, s.cursor_col)) |node_snap| {
                col = node_snap.start_col;
            }
            // Anchor on the token, not the (drifting) cursor — the
            // popup stays pinned to the symbol the user asked about.
            core.setHoverAnchor(s.cursor_row, col);
            // Manual hover = sticky. Stays up until Esc; arrow / j /
            // k scroll the body.
            core.setHoverSticky(true);
            core.hover_request_sent_ms = std.Io.Clock.real.now(core.io).toMilliseconds();
            try core.lsp_manager.requestHover(path, @intCast(s.cursor_row), @intCast(col));
            core.hover_pending = true;
        } else {
            core.setStatusLiteralLeveled(.info, "Save the buffer first", 1500);
        }
    }

    pub fn cmdLspFindReferences(core: anytype) anyerror!void {
        try core.ensureLspDocument();

        const s = core.state();
        if (s.file_path) |path| {
            var col = s.cursor_col;
            if (core.syntax_manager.nodeAt(s.cursor_row, s.cursor_col)) |node_snap| {
                col = node_snap.start_col;
                const buffer_content = s.buffer.toString(core.allocator) catch null;
                if (buffer_content) |content| {
                    defer core.allocator.free(content);
                    const start_byte: usize = @intCast(node_snap.start_byte);
                    const end_byte: usize = @intCast(node_snap.end_byte);
                    if (start_byte < content.len and end_byte <= content.len and end_byte > start_byte) {
                        if (core.references_symbol_name) |old| core.allocator.free(old);
                        core.references_symbol_name = core.allocator.dupe(u8, content[start_byte..end_byte]) catch null;
                    }
                }
            }

            if (core.references_source_file) |old| core.allocator.free(old);
            core.references_source_file = core.allocator.dupe(u8, path) catch null;
            core.references_source_line = s.cursor_row;

            try core.lsp_manager.requestReferences(path, @intCast(s.cursor_row), @intCast(col));
            core.references_pending = true;
            core.references_request_sent_ms = std.Io.Clock.real.now(core.io).toMilliseconds();
            core.setStatusLiteral("Looking up references…", 1500);
        } else {
            core.setStatusLiteralLeveled(.info, "Save the buffer first", 1500);
        }
    }

    /// Open the document-symbols picker for the active buffer.
    /// Sends `textDocument/documentSymbol`, polls the result with
    /// a short cap (~500 ms — symbols are typically cached after
    /// the first request), then either populates the picker with
    /// the response or falls back to an empty picker the user can
    /// see "this LSP didn't answer in time."
    ///
    /// Body extracted verbatim from `core.zig`. Mode switch leaves
    /// the picker on screen even when the response missed the
    /// poll window — `updateSymbolSearch` will re-run when the
    /// reply eventually lands.
    pub fn cmdDocumentSymbols(core: anytype) anyerror!void {
        core.recordJumpFromCurrent();

        const s = core.state();
        const file_path = s.file_path orelse return;

        core.lsp_manager.requestDocumentSymbols(file_path) catch |err| {
            log.warn("LSP document symbols request failed for {s}: {}", .{ file_path, err });
        };

        var attempts: u32 = 0;
        while (attempts < 50) : (attempts += 1) {
            if (core.lsp_manager.popDocumentSymbolsResult()) |symbols| {
                defer core.lsp_manager.freeDocumentSymbols(symbols);

                for (core.symbol_picker_all_symbols.items) |entry| {
                    core.allocator.free(entry.name);
                }
                core.symbol_picker_all_symbols.clearRetainingCapacity();
                for (core.symbol_picker_results.items) |entry| {
                    core.allocator.free(entry.name);
                }
                core.symbol_picker_results.clearRetainingCapacity();

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

                    const name_dupe = try core.allocator.dupe(u8, sym.name);
                    try core.symbol_picker_all_symbols.append(core.allocator, .{
                        .name = name_dupe,
                        .kind = kind_str,
                        .line = sym.line,
                    });
                }

                core.previous_mode = core.mode;
                core.mode = .symbol_picker;
                core.symbol_picker_query.clearRetainingCapacity();
                core.symbol_picker_selected = 0;
                try core.updateSymbolSearch();
                try core.sendUpdate();
                return;
            }
            // best-effort: sleep cancellation is fine, loop will check condition again
            std.Io.sleep(core.io, std.Io.Duration.fromMilliseconds(10), .real) catch {};
        }

        core.previous_mode = core.mode;
        core.mode = .symbol_picker;
        core.symbol_picker_query.clearRetainingCapacity();
        core.symbol_picker_selected = 0;
        try core.updateSymbolSearch();
        try core.sendUpdate();
    }

    /// Open the workspace-wide symbols picker. The picker fires a
    /// debounced `workspace/symbol` on each keystroke; the open
    /// command just sets up state and switches mode.
    pub fn cmdWorkspaceSymbols(core: anytype) anyerror!void {
        try core.openWorkspaceSymbolPicker();
    }

    /// `lsp.format_selection` — Space `Space l F`. Sends
    /// `textDocument/rangeFormatting` for the visual selection
    /// (or current line). Falls back to whole-document format
    /// when the LSP isn't ready / language doesn't support range
    /// formatting.
    pub fn cmdLspFormatSelection(core: anytype) anyerror!void {
        if (core.activeBufferIsLarge()) {
            core.setStatusLiteralLeveled(.warning, "Format selection: skipped (large-file mode)", 2000);
            return;
        }
        const s = core.state();
        const path = s.file_path orelse {
            core.setStatusLiteralLeveled(.warning, "Format selection: buffer has no file path", 2000);
            return;
        };

        // Resolve the range: visual selection if present, else the
        // cursor's line. Tracking the in-flight mode here (vs. just
        // reading `selection_anchor`) keeps "no selection" working
        // outside Visual mode without surprising the user.
        var start_line: u32 = @intCast(s.cursor_row);
        var start_col: u32 = 0;
        var end_line: u32 = @intCast(s.cursor_row + 1);
        var end_col: u32 = 0;
        if (s.selection_anchor) |a| {
            const a_row: u32 = @intCast(a.row);
            const c_row: u32 = @intCast(s.cursor_row);
            const a_col: u32 = @intCast(a.col);
            const c_col: u32 = @intCast(s.cursor_col);
            if (a_row < c_row or (a_row == c_row and a_col <= c_col)) {
                start_line = a_row;
                start_col = a_col;
                end_line = c_row;
                end_col = c_col;
            } else {
                start_line = c_row;
                start_col = c_col;
                end_line = a_row;
                end_col = a_col;
            }
            // Empty range (anchor at cursor) — fall through to line-based
            // range below.
            if (start_line == end_line and start_col == end_col) {
                start_col = 0;
                end_line = start_line + 1;
                end_col = 0;
            }
        }

        try core.ensureLspDocument();
        core.lsp_manager.requestRangeFormatting(path, start_line, start_col, end_line, end_col) catch |err| switch (err) {
            error.ServerNotReady, error.ServerNotRunning, error.UnsupportedLanguage => {
                core.setStatusLiteralLeveled(.warning, "Format selection: LSP not ready, falling back to full document", 2000);
                try core.lsp_manager.requestFormatting(path);
            },
            else => return err,
        };
        const applied = try core.waitAndApplyFormatEdits();
        if (applied) {
            core.setStatusLiteralLeveled(.success, "Format selection: applied", 1500);
        } else {
            core.setStatusLiteralLeveled(.info, "Format selection: no changes", 1500);
        }
        try core.sendUpdate();
    }

    /// `lsp.code_action` — Space `.`. Asks the LSP for available
    /// actions at the cursor (or visual selection), waits briefly,
    /// then either applies the single action automatically or
    /// stashes the list and prompts for a digit to pick one.
    pub fn cmdLspCodeAction(core: anytype) anyerror!void {
        if (core.activeBufferIsLarge()) {
            core.setStatusLiteralLeveled(.warning, "Code actions: skipped (large-file mode)", 2000);
            return;
        }
        const s = core.state();
        const path = s.file_path orelse {
            core.setStatusLiteralLeveled(.warning, "Code actions: buffer has no file path", 2000);
            return;
        };

        // Resolve range — visual selection or cursor's char.
        var start_line: u32 = @intCast(s.cursor_row);
        var start_col: u32 = @intCast(s.cursor_col);
        var end_line: u32 = @intCast(s.cursor_row);
        var end_col: u32 = @intCast(s.cursor_col);
        if (s.selection_anchor) |a| {
            const a_row: u32 = @intCast(a.row);
            const a_col: u32 = @intCast(a.col);
            if (a_row < start_line or (a_row == start_line and a_col < start_col)) {
                start_line = a_row;
                start_col = a_col;
            } else {
                end_line = a_row;
                end_col = a_col;
            }
        }

        try core.ensureLspDocument();
        core.lsp_manager.requestCodeAction(path, start_line, start_col, end_line, end_col) catch |err| {
            core.setStatus("Code actions: request failed: {}", .{err}, 2000);
            return;
        };

        // Wait briefly for the response. Up to ~300 ms — code-action
        // round trips are typically much faster on small files; we
        // bail out cleanly if the LSP is slow.
        var attempts: usize = 0;
        var actions: ?[]LspServerNS.CodeAction = null;
        while (attempts < 30) : (attempts += 1) {
            if (core.lsp_manager.popCodeActionResult()) |list| {
                actions = list;
                break;
            }
            std.Io.sleep(core.io, std.Io.Duration.fromMilliseconds(10), .real) catch {};
        }

        const list = actions orelse {
            core.setStatusLiteralLeveled(.info, "Code actions: no response", 2000);
            return;
        };
        if (list.len == 0) {
            core.lsp_manager.freeCodeActions(list);
            core.setStatusLiteralLeveled(.info, "Code actions: none available", 2000);
            return;
        }

        if (list.len == 1) {
            // Single action — just apply.
            defer core.lsp_manager.freeCodeActions(list);
            try core.applyCodeAction(list[0]);
            return;
        }

        // Multiple — stash and prompt. Cap to 9 so a digit selects.
        const visible = @min(list.len, 9);
        if (core.code_action_pending) |old| core.lsp_manager.freeCodeActions(old);
        core.code_action_pending = list;

        var preview: std.ArrayListUnmanaged(u8) = .empty;
        defer preview.deinit(core.allocator);
        try preview.appendSlice(core.allocator, "Code actions: ");
        for (list[0..visible], 0..) |a, i| {
            if (i > 0) try preview.appendSlice(core.allocator, "  ");
            const entry = try std.fmt.allocPrint(core.allocator, "[{d}] {s}", .{ i + 1, a.title });
            defer core.allocator.free(entry);
            try preview.appendSlice(core.allocator, entry);
        }
        if (list.len > visible) try preview.appendSlice(core.allocator, "  …");
        core.setStatus("{s}", .{preview.items}, 8000);
        try core.sendUpdate();
    }
};

fn lspStateLabel(server: lsp.LSPManager.ServerHealth) []const u8 {
    if (!server.running) return "stopped";
    if (!server.healthy) return "unhealthy";
    if (!server.initialized) return "initializing";
    return "ready";
}

const LspServerNS = @import("../../services/lsp/server.zig").LSPServer;
