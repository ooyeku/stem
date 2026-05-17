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
};
