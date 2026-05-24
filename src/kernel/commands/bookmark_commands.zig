//! Bookmark palette commands.
//!
//! The interactive bookmark flow (`m<a-z>` to set, `'<a-z>` to
//! jump) is implemented inside the Select-mode input handler in
//! `core.zig` because it lives entirely in input dispatch state.
//! These palette commands cover the meta-operations: listing
//! every bookmark in a virtual `[Bookmarks]` buffer and wiping
//! the per-project set.
//!
//! Extracted from `core.zig` to keep the monolith shrinking; see
//! `docs/refactor-plan.md` step 1.

const std = @import("std");

const log = std.log.scoped(.BookmarkCommands);

pub const BookmarkCommands = struct {
    pub fn cmdBookmarkList(core: anytype) anyerror!void {
        try core.openBookmarksBuffer();
    }

    pub fn cmdBookmarkClearAll(core: anytype) anyerror!void {
        core.bookmarks.clearAll();
        core.bookmarks.save(core.io) catch |err| {
            log.warn("Failed to persist bookmarks after clearAll: {}", .{err});
        };
        core.setStatusLiteralLeveled(.info, "Bookmarks cleared", 1500);
        try core.sendUpdate();
    }
};
