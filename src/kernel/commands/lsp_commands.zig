const std = @import("std");
const lsp = @import("../../services/lsp_manager.zig");
const ts = @import("../../syntax/tree_sitter.zig");

const log = std.log.scoped(.LspCommands);

pub const LspCommands = struct {
    pub fn cmdLspFormatDocument(core: anytype) anyerror!void {
        const s = core.state();
        if (s.file_path) |path| {
            try core.lsp_manager.requestFormatting(path);
        }
    }

    pub fn cmdLspGoToDefinition(core: anytype) anyerror!void {
        log.info("cmdLspGoToDefinition called", .{});

        try core.ensureLspDocument();

        const s = core.state();
        if (s.file_path) |path| {
            var col = s.cursor_col;

            if (core.syntax_manager.getNodeAt(s.cursor_row, s.cursor_col)) |node| {
                const c = ts.c;
                const start_point = c.ts_node_start_point(node);
                col = start_point.column;
                log.info("Snapped cursor to node start: column {d} -> {d}", .{ s.cursor_col, col });
            }

            log.info("Requesting definition for {s} at ({d}, {d})", .{ path, s.cursor_row, col });
            try core.lsp_manager.requestDefinition(path, @intCast(s.cursor_row), @intCast(col));
            core.definition_pending = true;
        } else {
            log.warn("No file path for go-to-definition", .{});
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

    pub fn cmdLspHover(core: anytype) anyerror!void {
        try core.ensureLspDocument();

        const s = core.state();
        if (s.file_path) |path| {
            var col = s.cursor_col;
            if (core.syntax_manager.getNodeAt(s.cursor_row, s.cursor_col)) |node| {
                const c = ts.c;
                col = c.ts_node_start_point(node).column;
            }
            try core.lsp_manager.requestHover(path, @intCast(s.cursor_row), @intCast(col));
            core.hover_pending = true;
        }
    }

    pub fn cmdLspFindReferences(core: anytype) anyerror!void {
        try core.ensureLspDocument();

        const s = core.state();
        if (s.file_path) |path| {
            var col = s.cursor_col;
            if (core.syntax_manager.getNodeAt(s.cursor_row, s.cursor_col)) |node| {
                const c = ts.c;
                col = c.ts_node_start_point(node).column;
                const byte_range = core.syntax_manager.getNodeByteRange(node);
                const buffer_content = s.buffer.toString(core.allocator) catch null;
                if (buffer_content) |content| {
                    defer core.allocator.free(content);
                    if (byte_range.start < content.len and byte_range.end <= content.len and byte_range.end > byte_range.start) {
                        if (core.references_symbol_name) |old| core.allocator.free(old);
                        core.references_symbol_name = core.allocator.dupe(u8, content[byte_range.start..byte_range.end]) catch null;
                    }
                }
            }

            if (core.references_source_file) |old| core.allocator.free(old);
            core.references_source_file = core.allocator.dupe(u8, path) catch null;
            core.references_source_line = s.cursor_row;

            try core.lsp_manager.requestReferences(path, @intCast(s.cursor_row), @intCast(col));
            core.references_pending = true;
        }
    }
};
