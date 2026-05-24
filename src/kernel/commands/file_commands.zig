const std = @import("std");

pub const FileCommands = struct {
    pub fn cmdFileSave(core: anytype) anyerror!void {
        try core.saveCurrentFile();
    }

    pub fn cmdFileSaveAs(core: anytype) anyerror!void {
        core.previous_mode = core.mode;
        core.mode = .save_as_mode;
        core.save_as_input.clearRetainingCapacity();
    }

    pub fn cmdFileOpen(core: anytype) anyerror!void {
        // The redundant fuzzy/list picker was retired; the file
        // explorer is now the single entry point for "open a file".
        try core.openFileExplorer();
    }

    pub fn cmdFileNew(core: anytype) anyerror!void {
        _ = try core.buffer_manager.openVirtual("[Scratch]", "");
        core.setStatusLiteral("New scratch buffer", 1500);
    }

    pub fn cmdFileReload(core: anytype) anyerror!void {
        const s = core.state();
        if (s.file_path) |path| {
            const path_dupe = try core.allocator.dupe(u8, path);
            defer core.allocator.free(path_dupe);

            // Pre-reload bookkeeping: stale multi-cursors reference
            // the OLD buffer's coordinate space — keeping them past
            // a reload silently corrupts edits at non-existent rows.
            // Clear them now; the user can re-add as needed.
            core.clearMultiCursors();

            s.loadFile(path_dupe) catch |err| {
                const err_msg = switch (err) {
                    error.FileNotFound => try std.fmt.allocPrint(core.allocator,
                        \\╔══════════════════════════════════════════════════════════════╗
                        \\║  ✗ FILE NOT FOUND                                            ║
                        \\╚══════════════════════════════════════════════════════════════╝
                        \\
                        \\The file no longer exists on disk:
                        \\  {s}
                        \\
                        \\The file may have been deleted or moved.
                        \\Use 'File: Save As' to save to a new location.
                    , .{path_dupe}),
                    error.AccessDenied => try std.fmt.allocPrint(core.allocator,
                        \\╔══════════════════════════════════════════════════════════════╗
                        \\║  ✗ ACCESS DENIED                                             ║
                        \\╚══════════════════════════════════════════════════════════════╝
                        \\
                        \\Cannot read file:
                        \\  {s}
                        \\
                        \\Check file permissions.
                    , .{path_dupe}),
                    else => try std.fmt.allocPrint(core.allocator,
                        \\╔══════════════════════════════════════════════════════════════╗
                        \\║  ✗ RELOAD FAILED                                             ║
                        \\╚══════════════════════════════════════════════════════════════╝
                        \\
                        \\
                        \\Could not reload file:
                        \\  {s}
                        \\
                        \\Error: {}
                    , .{ path_dupe, err }),
                };
                defer core.allocator.free(err_msg);
                try core.buffer_manager.openVirtual("[Error]", err_msg);
                core.mode = .view;
                core.setStatusLiteral("Reload failed (see [Error] buffer)", 2500);
                try core.sendUpdate();
                return;
            };
            // Post-reload bookkeeping: re-run syntax/LSP wiring so
            // tree-sitter picks up the new content and the LSP gets a
            // fresh didChange. Without this, tree-sitter highlights
            // and diagnostics are stale relative to disk until the
            // next edit kicks the parser.
            core.refreshSyntaxForCurrentBuffer();

            const basename = std.fs.path.basename(path_dupe);
            core.setStatus("Reloaded {s}", .{basename}, 1500);
            try core.sendUpdate();
        }
    }

    pub fn cmdSystemQuit(core: anytype) anyerror!void {
        try core.sendQuitToUI();
    }
};
