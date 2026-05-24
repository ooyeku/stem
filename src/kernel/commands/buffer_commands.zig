const std = @import("std");

pub const BufferCommands = struct {
    pub fn cmdBufferSwitch(core: anytype) anyerror!void {
        core.previous_mode = core.mode;
        core.mode = .buffer_picker;
        core.buffer_manager.pickerReset();
    }

    pub fn cmdBufferNew(core: anytype) anyerror!void {
        _ = try core.buffer_manager.createUntitled();
        if (core.split_manager) |*sm| {
            sm.setFocusedBuffer(core.buffer_manager.active_index);
        }
        try core.ensureLspDocument();
        try core.sendUpdate();
        core.notifyBufferSwitched();
    }

    pub fn cmdBufferNext(core: anytype) anyerror!void {
        core.buffer_manager.nextBuffer();
        if (core.split_manager) |*sm| {
            sm.setFocusedBuffer(core.buffer_manager.active_index);
        }
        try core.ensureLspDocument();
        core.notifyBufferSwitched();
    }

    pub fn cmdBufferPrev(core: anytype) anyerror!void {
        core.buffer_manager.prevBuffer();
        if (core.split_manager) |*sm| {
            sm.setFocusedBuffer(core.buffer_manager.active_index);
        }
        try core.ensureLspDocument();
        core.notifyBufferSwitched();
    }

    pub fn cmdBufferClose(core: anytype) anyerror!void {
        const removed_index = core.buffer_manager.active_index;
        const closed = core.buffer_manager.closeActive();

        if (closed) {
            if (core.split_manager) |*sm| {
                const new_len = core.buffer_manager.buffers.items.len;
                sm.onBufferClosed(removed_index, new_len);
            }
        }
    }

    pub fn cmdBufferCloseOthers(core: anytype) anyerror!void {
        core.buffer_manager.closeOthers();
        if (core.split_manager) |*sm| {
            sm.onCloseOthers();
        }
    }

    pub fn cmdBufferNewScratch(core: anytype) anyerror!void {
        core.buffer_manager.untitled_counter += 1;
        const name = try std.fmt.allocPrint(core.allocator, "Scratch-{d}", .{core.buffer_manager.untitled_counter});
        defer core.allocator.free(name);

        try core.buffer_manager.openVirtual(name, "");
        core.mode = .insert;
        try core.sendUpdate();
    }

    /// `buffer.restore_backups` — opens a `[Recovery Backups]`
    /// virtual buffer listing every `.bak` in `~/.stem/recover/`
    /// alongside the original path (from each `.bak`'s `.path`
    /// sidecar) and size/mtime. Read-only summary; restoring is a
    /// shell `cat <backup>` step.
    pub fn cmdBufferRestoreBackups(core: anytype) anyerror!void {
        const std_local = @import("std");

        const home_dir = core.homeDir() catch |err| {
            core.setStatusLeveled(.err, "Cannot resolve $HOME: {}", .{err}, 3000);
            return;
        };
        defer core.allocator.free(home_dir);

        const recover_dir = try std_local.fs.path.join(core.allocator, &.{ home_dir, ".stem", "recover" });
        defer core.allocator.free(recover_dir);

        var aw: std_local.Io.Writer.Allocating = .init(core.allocator);
        defer aw.deinit();
        const w = &aw.writer;

        try w.print("Recovery backups in {s}\n", .{recover_dir});
        try w.writeAll("(Each `.bak` is an autosave of a buffer that was dirty when stem last ran.\n");
        try w.writeAll(" To restore: open the original file, then paste from the backup, or use\n");
        try w.writeAll(" `cat <backup>` from a shell. Backups are deleted on next clean exit.)\n\n");

        var dir = std_local.Io.Dir.openDirAbsolute(core.io, recover_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => {
                try w.writeAll("(no backup directory yet — nothing to recover)\n");
                try core.buffer_manager.openVirtual("[Recovery Backups]", aw.written());
                try core.sendUpdate();
                return;
            },
            else => return err,
        };
        defer dir.close(core.io);

        var any = false;
        var iter = dir.iterate();
        while (try iter.next(core.io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std_local.mem.endsWith(u8, entry.name, ".bak")) continue;
            any = true;

            const bak_path = try std_local.fs.path.join(core.allocator, &.{ recover_dir, entry.name });
            defer core.allocator.free(bak_path);
            const sidecar = try std_local.fmt.allocPrint(core.allocator, "{s}.path", .{bak_path});
            defer core.allocator.free(sidecar);

            var original: ?[]u8 = null;
            defer if (original) |o| core.allocator.free(o);
            if (std_local.Io.Dir.openFileAbsolute(core.io, sidecar, .{})) |sf| {
                defer sf.close(core.io);
                const len = sf.length(core.io) catch 0;
                if (len > 0 and len < 4096) {
                    const buf = core.allocator.alloc(u8, @intCast(len)) catch null;
                    if (buf) |b| {
                        const n = sf.readPositionalAll(core.io, b, 0) catch 0;
                        original = b[0..n];
                    }
                }
            } else |_| {}

            const bak_file = std_local.Io.Dir.openFileAbsolute(core.io, bak_path, .{}) catch continue;
            defer bak_file.close(core.io);
            const bak_stat = bak_file.stat(core.io) catch continue;
            const bak_size = bak_file.length(core.io) catch 0;

            const orig = original orelse "(unknown — .path sidecar missing)";
            try w.print("  {s}\n    backup: {s} ({d} bytes, mtime_ns={d})\n\n", .{
                orig,
                bak_path,
                bak_size,
                bak_stat.mtime.toNanoseconds(),
            });
        }
        if (!any) try w.writeAll("(no backups present)\n");

        try core.buffer_manager.openVirtual("[Recovery Backups]", aw.written());
        try core.sendUpdate();
    }
};
