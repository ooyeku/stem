const std = @import("std");

const log = std.log.scoped(.SplitCommands);

pub const SplitCommands = struct {
    pub fn cmdSplitVertical(core: anytype) anyerror!void {
        try core.ensureSplitManager();
        if (core.split_manager) |*sm| {
            try sm.splitVertical(core.buffer_manager.active_index);
        }
        core.invalidatePaneHeightCache();
        core.setStatusLiteral("Split vertical", 1200);
        try core.sendUpdate();
    }

    pub fn cmdSplitHorizontal(core: anytype) anyerror!void {
        try core.ensureSplitManager();
        if (core.split_manager) |*sm| {
            try sm.splitHorizontal(core.buffer_manager.active_index);
        }
        core.invalidatePaneHeightCache();
        core.setStatusLiteral("Split horizontal", 1200);
        try core.sendUpdate();
    }

    pub fn cmdPaneClose(core: anytype) anyerror!void {
        if (core.split_manager) |*sm| {
            if (sm.hasSplits()) {
                core.syncStateToPane();
                sm.closePane();
                core.syncPaneToState();
                const remaining_pane = sm.getFocusedPane();
                if (remaining_pane.buffer_index < core.buffer_manager.buffers.items.len) {
                    core.buffer_manager.active_index = remaining_pane.buffer_index;
                }

                if (!sm.hasSplits()) {
                    sm.deinit();
                    core.split_manager = null;
                }
                core.setStatusLiteral("Closed pane", 1200);
            } else {
                const pane = sm.getFocusedPane();
                if (pane.buffer_index < core.buffer_manager.buffers.items.len) {
                    core.buffer_manager.active_index = pane.buffer_index;
                }
                sm.deinit();
                core.split_manager = null;
            }
        }
        core.invalidatePaneHeightCache();
        try core.sendUpdate();
    }

    pub fn cmdPaneFocusLeft(core: anytype) anyerror!void {
        if (core.split_manager) |*sm| {
            core.syncStateToPane();
            sm.focusLeft();
            core.syncPaneToState();
            core.invalidatePaneHeightCache();
            core.ensureLspDocument() catch |err| {
                log.debug("ensureLspDocument failed on pane focus: {}", .{err});
            };
        }
        try core.sendUpdate();
    }

    pub fn cmdPaneFocusRight(core: anytype) anyerror!void {
        if (core.split_manager) |*sm| {
            core.syncStateToPane();
            sm.focusRight();
            core.syncPaneToState();
            core.invalidatePaneHeightCache();
            core.ensureLspDocument() catch |err| {
                log.debug("ensureLspDocument failed on pane focus: {}", .{err});
            };
        }
        try core.sendUpdate();
    }

    pub fn cmdPaneFocusUp(core: anytype) anyerror!void {
        if (core.split_manager) |*sm| {
            core.syncStateToPane();
            sm.focusUp();
            core.syncPaneToState();
            core.invalidatePaneHeightCache();
            core.ensureLspDocument() catch |err| {
                log.debug("ensureLspDocument failed on pane focus: {}", .{err});
            };
        }
        try core.sendUpdate();
    }

    pub fn cmdPaneFocusDown(core: anytype) anyerror!void {
        if (core.split_manager) |*sm| {
            core.syncStateToPane();
            sm.focusDown();
            core.syncPaneToState();
            core.invalidatePaneHeightCache();
            core.ensureLspDocument() catch |err| {
                log.debug("ensureLspDocument failed on pane focus: {}", .{err});
            };
        }
        try core.sendUpdate();
    }

    pub fn cmdPaneSwapLeft(core: anytype) anyerror!void {
        if (core.split_manager) |*sm| {
            sm.swapLeft();
        }
        try core.sendUpdate();
    }

    pub fn cmdPaneSwapRight(core: anytype) anyerror!void {
        if (core.split_manager) |*sm| {
            sm.swapRight();
        }
        try core.sendUpdate();
    }

    pub fn cmdPaneSwapUp(core: anytype) anyerror!void {
        if (core.split_manager) |*sm| {
            sm.swapUp();
        }
        try core.sendUpdate();
    }

    pub fn cmdPaneSwapDown(core: anytype) anyerror!void {
        if (core.split_manager) |*sm| {
            sm.swapDown();
        }
        try core.sendUpdate();
    }
};
