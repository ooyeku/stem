//! Input dispatch for `.save_as_mode` — the filename prompt
//! after `file.save_as`. Accumulates characters into
//! `save_as_input`; Enter saves to the resolved path (cwd-relative
//! when not absolute) and spins up an LSP for the new file's
//! language if applicable.

const std = @import("std");
const vaxis = @import("vaxis");

const LSPManager = @import("../../services/lsp_manager.zig").LSPManager;

const log = std.log.scoped(.SaveAs);

pub fn handle(core: anytype, key: vaxis.Key) !bool {
    if (key.matches(vaxis.Key.enter, .{})) {
        if (core.save_as_input.items.len > 0) {
            const filename = try core.allocator.dupe(u8, core.save_as_input.items);
            defer core.allocator.free(filename);

            const full_path = if (std.fs.path.isAbsolute(filename))
                try core.allocator.dupe(u8, filename)
            else
                try std.fs.path.join(core.allocator, &.{ core.file_manager.cwd, filename });
            defer core.allocator.free(full_path);

            try core.state().saveFileAs(full_path);

            const active_buf = core.buffer_manager.getActive();
            core.allocator.free(active_buf.name);
            active_buf.name = try core.allocator.dupe(u8, std.fs.path.basename(full_path));
            if (active_buf.file_path) |old| core.allocator.free(old);
            active_buf.file_path = try core.allocator.dupe(u8, full_path);

            // Save-as: spin up the LSP for the new file's language if
            // there is one. Skipped when the buffer is in large-file
            // mode (same reason as everywhere else: no point indexing
            // a 5 MB log).
            if (!core.activeBufferIsLarge()) {
                if (LSPManager.getLangFromPath(full_path)) |lang_id| {
                    const project_root = try core.findProjectRoot(full_path);
                    defer if (project_root) |p| core.allocator.free(p);

                    const root = if (project_root) |p| p else core.file_manager.cwd;
                    try core.lsp_manager.startServer(lang_id, root);

                    const content = try core.state().buffer.toString(core.allocator);
                    defer core.allocator.free(content);
                    core.lsp_manager.documentOpened(full_path, content) catch |err| {
                        log.warn("LSP document sync failed in save-as '{s}': {}", .{ full_path, err });
                    };
                    core.lsp_doc_version = 1;
                }
            }

            core.mode = .select;
            core.save_as_input.clearRetainingCapacity();
        }
        return true;
    } else if (key.matches(vaxis.Key.backspace, .{})) {
        if (core.save_as_input.items.len > 0) {
            _ = core.save_as_input.pop();
            return true;
        }
    } else if (key.text) |text| {
        try core.save_as_input.appendSlice(core.allocator, text);
        return true;
    }
    return false;
}
