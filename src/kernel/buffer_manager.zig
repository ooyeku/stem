const std = @import("std");
const EditorState = @import("../core/state.zig").EditorState;
const PieceTable = @import("../core/piece_table.zig").PieceTable;
const protocol = @import("protocol.zig");

const test_utils = @import("../test_utils.zig");
const TestIo = @import("../test_utils.zig").TestIo;
const MemoryTestUtils = test_utils.MemoryTestUtils;
const PerformanceTestUtils = test_utils.PerformanceTestUtils;

pub const Buffer = struct {
    id: u32,
    state: EditorState,
    name: []const u8,
    file_path: ?[]const u8,
    not_loaded: bool = false,
    /// mtime of `file_path` the last time we read or wrote it, in
    /// nanoseconds since the Unix epoch. Used by the external-change
    /// watcher: if the on-disk mtime is newer than this, somebody else
    /// modified the file behind our back. 0 means "not yet stat'd."
    last_disk_mtime_ns: i96 = 0,
    /// "Large-file mode" flag — set at open time when the buffer's
    /// byte size or line count exceeds the configured thresholds. Once
    /// true, callers MUST treat it as sticky for the lifetime of the
    /// buffer: tree-sitter, brackets, LSP and auto-pair are all
    /// skipped. Editing a 5 MB log shouldn't choke the editor.
    is_large: bool = false,
    /// Rendering surface for the buffer. Disk-backed buffers remain
    /// editable text; virtual report buffers may render as polished
    /// presentation views.
    presentation: protocol.BufferPresentation = .text,
    /// True if the user asked to force-load (e.g. by re-trying past
    /// the soft threshold). Lets the status bar distinguish "auto-
    /// degraded" from "user-overrode".
    large_overridden: bool = false,

    /// Where this buffer was opened *from*. Populated by
    /// `openVirtualBuffer` so closing a [References] / [Help] /
    /// [Diagnostics] / [Bookmarks] / [Git Diff] etc. buffer can
    /// jump the caller back to the trigger location instead of
    /// dropping them wherever the next-active buffer last sat.
    /// `null` for buffers opened directly from disk or scratch.
    opened_from: ?OpenedFrom = null,

    pub const OpenedFrom = struct {
        buffer_id: u32,
        row: usize,
        col: usize,
    };

    pub fn isPresentationReadOnly(self: *const Buffer) bool {
        return self.presentation == .markdown_view;
    }

    pub fn deinit(self: *Buffer, allocator: std.mem.Allocator) void {
        self.state.deinit();
        allocator.free(self.name);
        if (self.file_path) |path| {
            allocator.free(path);
        }
    }
};

/// Decision result from `classifyContent`. Carries the human-readable
/// reason so the toast on open can explain why the buffer degraded.
pub const LargeFileDecision = struct {
    is_large: bool,
    /// 0 = "below threshold". Otherwise the offending count
    /// (bytes or lines) so callers can format a message.
    triggered_by_bytes: usize = 0,
    triggered_by_lines: usize = 0,
};

/// Decide whether content should open in large-file mode given the
/// configured thresholds. Lines are counted by scanning '\n' — cheap
/// even at 100MB because it's a single linear pass.
pub fn classifyContent(content: []const u8, threshold_bytes: usize, threshold_lines: usize) LargeFileDecision {
    if (content.len > threshold_bytes) {
        return .{ .is_large = true, .triggered_by_bytes = content.len };
    }
    // Skip the line count if even 1 byte per line would already be under
    // the limit — cheap short-circuit on the common small-file path.
    if (content.len < threshold_lines) return .{ .is_large = false };

    var lines: usize = 1;
    for (content) |b| {
        if (b == '\n') {
            lines += 1;
            if (lines > threshold_lines) {
                return .{ .is_large = true, .triggered_by_lines = lines };
            }
        }
    }
    return .{ .is_large = false };
}

pub fn classifyVirtualPresentation(name: []const u8, content: []const u8) protocol.BufferPresentation {
    if (std.mem.eql(u8, name, "[LOGS]")) return .text;
    if (isGeneratedReportBufferName(name)) return .markdown_view;

    var score: usize = 0;
    var heading_count: usize = 0;
    var list_count: usize = 0;
    var table_count: usize = 0;
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    var scanned: usize = 0;

    while (line_iter.next()) |line| {
        if (scanned >= 96) break;
        scanned += 1;

        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        if (std.mem.startsWith(u8, trimmed, "# ") or
            std.mem.startsWith(u8, trimmed, "## ") or
            std.mem.startsWith(u8, trimmed, "### "))
        {
            heading_count += 1;
            score += 4;
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "diff --git") or
            std.mem.startsWith(u8, trimmed, "@@"))
        {
            score += 4;
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "```")) {
            score += 3;
            continue;
        }

        if (std.mem.eql(u8, trimmed, "---") or
            std.mem.eql(u8, trimmed, "***") or
            std.mem.eql(u8, trimmed, "___"))
        {
            score += 2;
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "- ") or
            std.mem.startsWith(u8, trimmed, "* "))
        {
            list_count += 1;
            score += 1;
            continue;
        }

        if (trimmed.len >= 3 and trimmed[0] == '|' and trimmed[trimmed.len - 1] == '|') {
            table_count += 1;
            score += 2;
            continue;
        }

        if (std.mem.indexOfScalar(u8, trimmed, '`') != null) {
            score += 1;
        }
    }

    if (heading_count > 0) return .markdown_view;
    if (table_count >= 2) return .markdown_view;
    if (list_count >= 3) return .markdown_view;
    return if (score >= 4) .markdown_view else .text;
}

pub fn isGeneratedReportBufferName(name: []const u8) bool {
    const exact = [_][]const u8{
        "[HELP]",
        "[PLUGINS]",
        "[Plugins]",
        "[Plugin Stats]",
        "[Git Status]",
        "[Git Diff]",
        "[Git Diff Staged]",
        "[Plugin Manager]",
        "[Plugin Permissions]",
        "[Plugin Storage]",
        "[Plugin Load]",
        "[Plugin Unload]",
        "[Plugin Reload]",
        "[STATS]",
        "[CONTROL CENTER]",
        "[PROJECT BRAIN]",
        "[TASKS]",
        "[TASK OUTPUT]",
        "[Jobs]",
        "[LSP Status]",
        "[Diagnostics]",
        "[References]",
        "[Bookmarks]",
        "[Recovery Backups]",
        "[Build]",
        "[Zig Build]",
        "[Zig Test]",
        "[Zig Run]",
        "[Error]",
    };

    for (exact) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }

    return false;
}

pub const BufferManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    buffers: std.ArrayListUnmanaged(Buffer),
    active_index: usize,
    next_id: u32,
    untitled_counter: u32,
    picker_selected: usize,
    picker_scroll_offset: usize,
    /// Thresholds copied from `EditorConfig` at construction. Mutable so
    /// `setLargeFileThresholds` can refresh them when the user edits
    /// `~/.stem/config.json`. Defaults match the schema defaults — kept
    /// in sync there.
    large_file_threshold_bytes: usize = 5 * 1024 * 1024,
    large_file_threshold_lines: usize = 50_000,
    large_file_hard_limit_bytes: usize = 100 * 1024 * 1024,

    /// Optional edit hook applied to every `EditorState` this
    /// manager creates. Core sets this once at boot, pointed at a
    /// trampoline that forwards edits into `SyntaxManager.recordEdit`
    /// — without it, tree-sitter falls back to content-match
    /// subtree reuse on the parse worker (still correct, just less
    /// efficient on large files).
    default_edit_hook: ?EditorState.EditHook = null,

    /// Construct a fresh `EditorState` with `default_edit_hook` already
    /// attached. Use this everywhere a buffer's state field is
    /// initialised — keeps the hook plumbing in one place instead of
    /// requiring every construction site to remember the assignment.
    fn newState(self: *BufferManager, initial: []const u8) !EditorState {
        var s = try EditorState.init(self.allocator, self.io, initial);
        s.edit_hook = self.default_edit_hook;
        return s;
    }

    /// Re-attach the current `default_edit_hook` to every existing
    /// buffer's state. Idempotent. Called by Core after wiring its
    /// trampoline so buffers created before the hook was set still
    /// pick it up.
    pub fn refreshEditHooks(self: *BufferManager) void {
        for (self.buffers.items) |*buf| {
            buf.state.edit_hook = self.default_edit_hook;
        }
    }

    pub fn init(allocator: std.mem.Allocator, io: std.Io) BufferManager {
        var mgr = BufferManager{
            .allocator = allocator,
            .io = io,
            .buffers = .empty,
            .active_index = 0,
            .next_id = 1,
            .untitled_counter = 1,
            .picker_selected = 0,
            .picker_scroll_offset = 0,
        };

        _ = mgr.createUntitled() catch null;

        return mgr;
    }

    /// Refresh the size thresholds used by `openFile` /
    /// `loadBufferContent`. Called by `Core` whenever the config is
    /// re-read so the next file open honours the new value.
    pub fn setLargeFileThresholds(self: *BufferManager, threshold_bytes: u32, threshold_lines: u32, hard_limit_bytes: u32) void {
        self.large_file_threshold_bytes = threshold_bytes;
        self.large_file_threshold_lines = threshold_lines;
        // A hard limit smaller than the soft threshold would be a
        // nonsensical configuration — clamp to keep the invariant
        // (soft ≤ hard) so we never reject a file we'd otherwise allow.
        self.large_file_hard_limit_bytes = @max(hard_limit_bytes, threshold_bytes);
    }

    pub fn deinit(self: *BufferManager) void {
        for (self.buffers.items) |*buf| {
            buf.deinit(self.allocator);
        }
        self.buffers.deinit(self.allocator);
    }

    pub fn createUntitled(self: *BufferManager) !*Buffer {
        const name = try std.fmt.allocPrint(self.allocator, "untitled-{d}", .{self.untitled_counter});
        self.untitled_counter += 1;

        const buffer = Buffer{
            .id = self.next_id,
            .state = try self.newState(""),
            .name = name,
            .file_path = null,
        };
        self.next_id += 1;

        try self.buffers.append(self.allocator, buffer);
        self.active_index = self.buffers.items.len - 1;

        return &self.buffers.items[self.active_index];
    }

    pub fn openFile(self: *BufferManager, path: []const u8) !*Buffer {
        for (self.buffers.items, 0..) |*buf, i| {
            if (buf.file_path) |existing_path| {
                if (std.mem.eql(u8, existing_path, path)) {
                    self.active_index = i;
                    return buf;
                }
            }
        }

        const file = try std.Io.Dir.openFileAbsolute(self.io, path, .{});
        defer file.close(self.io);
        const size = try file.length(self.io);
        if (size > self.large_file_hard_limit_bytes) return error.FileTooLarge;
        const content = try self.allocator.alloc(u8, @intCast(size));
        defer self.allocator.free(content);
        // Capture actual bytes read; never trust that we got `size` back.
        // A short read (concurrent truncate, EOF before expected) would
        // otherwise leave trailing uninitialized bytes in `content`.
        const read_n = try file.readPositionalAll(self.io, content, 0);
        const content_slice = content[0..read_n];

        const decision = classifyContent(content_slice, self.large_file_threshold_bytes, self.large_file_threshold_lines);

        const name = try self.allocator.dupe(u8, std.fs.path.basename(path));
        errdefer self.allocator.free(name);
        const file_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(file_path);

        var state = try self.newState(content_slice);
        errdefer state.deinit();
        if (state.file_path) |old| self.allocator.free(old);
        state.file_path = try self.allocator.dupe(u8, path);
        state.modified = false;

        const buffer = Buffer{
            .id = self.next_id,
            .state = state,
            .name = name,
            .file_path = file_path,
            .is_large = decision.is_large,
        };

        try self.buffers.append(self.allocator, buffer);
        self.next_id += 1;
        self.active_index = self.buffers.items.len - 1;

        return &self.buffers.items[self.active_index];
    }

    pub fn openFileLazy(self: *BufferManager, path: []const u8) !*Buffer {
        for (self.buffers.items, 0..) |*buf, i| {
            if (buf.file_path) |existing_path| {
                if (std.mem.eql(u8, existing_path, path)) {
                    self.active_index = i;
                    return buf;
                }
            }
        }

        const name = try self.allocator.dupe(u8, std.fs.path.basename(path));
        errdefer self.allocator.free(name);
        var state = try self.newState("");
        errdefer state.deinit();
        if (state.file_path) |old| self.allocator.free(old);
        state.file_path = try self.allocator.dupe(u8, path);
        state.modified = false;

        const buf_file_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(buf_file_path);

        const buffer = Buffer{
            .id = self.next_id,
            .state = state,
            .name = name,
            .file_path = buf_file_path,
            .not_loaded = true,
        };

        try self.buffers.append(self.allocator, buffer);
        self.next_id += 1;
        self.active_index = self.buffers.items.len - 1;

        return &self.buffers.items[self.active_index];
    }

    /// Same as `openFileLazy` but does NOT change `active_index`. Used by the
    /// background directory scanner so streaming-in buffers don't pull focus
    /// away from whatever the user is looking at. No-op if a buffer for this
    /// path already exists.
    pub fn addFileLazyBackground(self: *BufferManager, path: []const u8) !void {
        for (self.buffers.items) |buf| {
            if (buf.file_path) |existing_path| {
                if (std.mem.eql(u8, existing_path, path)) return;
            }
        }

        const name = try self.allocator.dupe(u8, std.fs.path.basename(path));
        errdefer self.allocator.free(name);
        var state = try self.newState("");
        errdefer state.deinit();
        if (state.file_path) |old| self.allocator.free(old);
        state.file_path = try self.allocator.dupe(u8, path);
        state.modified = false;

        const buffer = Buffer{
            .id = self.next_id,
            .state = state,
            .name = name,
            .file_path = try self.allocator.dupe(u8, path),
            .not_loaded = true,
        };

        try self.buffers.append(self.allocator, buffer);
        self.next_id += 1;
    }

    pub fn loadBufferContent(self: *BufferManager, buffer: *Buffer) !void {
        if (!buffer.not_loaded) return;
        const path = buffer.file_path orelse return;

        const file = try std.Io.Dir.openFileAbsolute(self.io, path, .{});
        defer file.close(self.io);
        const size = try file.length(self.io);
        if (size > self.large_file_hard_limit_bytes) return error.FileTooLarge;
        const content = try self.allocator.alloc(u8, @intCast(size));
        defer self.allocator.free(content);
        const read_n = try file.readPositionalAll(self.io, content, 0);

        const decision = classifyContent(content[0..read_n], self.large_file_threshold_bytes, self.large_file_threshold_lines);

        buffer.state.deinit();
        buffer.state = try self.newState(content[0..read_n]);

        if (buffer.state.file_path) |old| self.allocator.free(old);
        buffer.state.file_path = try self.allocator.dupe(u8, path);
        buffer.state.modified = false;

        // Record mtime so the external-change watcher has a baseline.
        if (file.stat(self.io)) |st| {
            buffer.last_disk_mtime_ns = st.mtime.toNanoseconds();
        } else |_| {}

        buffer.is_large = decision.is_large;
        buffer.not_loaded = false;
    }

    pub fn openVirtual(self: *BufferManager, name: []const u8, content: []const u8) !void {
        const presentation = classifyVirtualPresentation(name, content);
        for (self.buffers.items, 0..) |*buf, i| {
            if (std.mem.eql(u8, buf.name, name)) {
                const cursor_row = buf.state.cursor_row;
                const cursor_col = buf.state.cursor_col;
                const scroll_offset = buf.state.scroll_offset;
                const opened_from = buf.opened_from;

                buf.state.deinit();
                buf.state = try self.newState(content);
                buf.state.modified = false;
                const line_count = buf.state.buffer.lineCount();
                const max_row = if (line_count == 0) 0 else line_count - 1;
                buf.state.cursor_row = @min(cursor_row, max_row);
                buf.state.cursor_col = @min(cursor_col, buf.state.getLineLength(buf.state.cursor_row));
                buf.state.scroll_offset = @min(scroll_offset, max_row);
                buf.presentation = presentation;
                buf.opened_from = opened_from;
                self.active_index = i;
                return;
            }
        }

        const buf_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(buf_name);

        var state = try self.newState(content);
        errdefer state.deinit();
        state.modified = false;

        const buffer = Buffer{
            .id = self.next_id,
            .state = state,
            .name = buf_name,
            .file_path = null,
            .presentation = presentation,
        };

        try self.buffers.append(self.allocator, buffer);
        self.next_id += 1;
        self.active_index = self.buffers.items.len - 1;
    }

    pub fn closeActive(self: *BufferManager) bool {
        // True iff a buffer was actually removed — matches the
        // historical contract: single-buffer "close" resets that
        // buffer to untitled rather than removing it, and returns
        // false so callers know there's still something on screen.
        return self.closeActiveReturningId() != null;
    }

    /// Same as `closeActive` but returns the closed buffer's stable
    /// `id` so callers (Core) can evict matching state from other
    /// subsystems (syntax tree cache, decoration markers, etc.).
    /// Returns null when there was nothing to close (single-buffer
    /// case, which reuses the slot via `resetBufferToUntitled`).
    pub fn closeActiveReturningId(self: *BufferManager) ?u32 {
        if (self.buffers.items.len <= 1) {
            if (self.buffers.items.len == 1) {
                self.resetBufferToUntitled(&self.buffers.items[0]);
            }
            return null;
        }
        const closed_id = self.buffers.items[self.active_index].id;
        var buf = self.buffers.orderedRemove(self.active_index);
        buf.deinit(self.allocator);
        if (self.active_index >= self.buffers.items.len) {
            self.active_index = self.buffers.items.len - 1;
        }
        return closed_id;
    }

    fn resetBufferToUntitled(self: *BufferManager, buf: *Buffer) void {
        // Build the fresh empty state first; if that fails there's no
        // sane way to recover (the old state's allocations are still
        // valid), so leave the buffer as-is.
        var new_state = self.newState("") catch |err| {
            std.log.warn("Failed to allocate empty buffer state during reset: {}", .{err});
            return;
        };
        errdefer new_state.deinit();

        const new_name = std.fmt.allocPrint(self.allocator, "untitled-{d}", .{self.untitled_counter}) catch |err| {
            std.log.warn("Failed to allocate buffer name during reset: {}", .{err});
            buf.state.deinit();
            buf.state = new_state;
            if (buf.file_path) |path| {
                self.allocator.free(path);
                buf.file_path = null;
            }
            return;
        };

        buf.state.deinit();
        buf.state = new_state;
        self.allocator.free(buf.name);
        buf.name = new_name;
        self.untitled_counter += 1;

        if (buf.file_path) |path| {
            self.allocator.free(path);
            buf.file_path = null;
        }
    }

    pub fn closeOthers(self: *BufferManager) void {
        if (self.buffers.items.len <= 1) return;

        const active_buf = self.buffers.orderedRemove(self.active_index);

        for (self.buffers.items) |*buf| {
            buf.deinit(self.allocator);
        }
        self.buffers.clearRetainingCapacity();

        self.buffers.append(self.allocator, active_buf) catch unreachable;
        self.active_index = 0;
    }

    pub fn getActive(self: *BufferManager) *Buffer {
        return &self.buffers.items[self.active_index];
    }

    pub fn switchTo(self: *BufferManager, index: usize) void {
        if (index < self.buffers.items.len) {
            self.active_index = index;
        }
    }

    /// Look up a buffer's current index by its stable `id`.
    /// Returns null when the id no longer matches any buffer
    /// (e.g. it was closed since the caller cached it).
    pub fn indexOfId(self: *const BufferManager, id: u32) ?usize {
        for (self.buffers.items, 0..) |buf, i| {
            if (buf.id == id) return i;
        }
        return null;
    }

    pub fn nextBuffer(self: *BufferManager) void {
        if (self.buffers.items.len > 1) {
            self.active_index = (self.active_index + 1) % self.buffers.items.len;
        }
    }

    pub fn prevBuffer(self: *BufferManager) void {
        if (self.buffers.items.len > 1) {
            if (self.active_index == 0) {
                self.active_index = self.buffers.items.len - 1;
            } else {
                self.active_index -= 1;
            }
        }
    }

    pub fn pickerMoveUp(self: *BufferManager) void {
        if (self.picker_selected > 0) {
            self.picker_selected -= 1;
        }
    }

    pub fn pickerMoveDown(self: *BufferManager) void {
        if (self.picker_selected < self.buffers.items.len - 1) {
            self.picker_selected += 1;
        }
    }

    pub fn pickerSelect(self: *BufferManager) void {
        self.switchTo(self.picker_selected);
    }

    pub fn pickerReset(self: *BufferManager) void {
        self.picker_selected = self.active_index;
        self.picker_scroll_offset = 0;
    }
};

test "buffer manager initialization" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var mgr = BufferManager.init(allocator, io);
    defer mgr.deinit();

    try std.testing.expectEqual(@as(usize, 1), mgr.buffers.items.len);
    try std.testing.expectEqual(@as(usize, 0), mgr.active_index);
    try std.testing.expectEqual(@as(u32, 2), mgr.next_id);
    try std.testing.expectEqual(@as(u32, 2), mgr.untitled_counter);

    const buf = mgr.getActive();
    try std.testing.expect(buf.file_path == null);
    try std.testing.expect(std.mem.startsWith(u8, buf.name, "untitled-"));
}

test "buffer manager create untitled" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var mgr = BufferManager.init(allocator, io);
    defer mgr.deinit();

    const buf2 = try mgr.createUntitled();
    try std.testing.expectEqual(@as(usize, 2), mgr.buffers.items.len);
    try std.testing.expectEqual(@as(usize, 1), mgr.active_index);
    try std.testing.expect(buf2.file_path == null);

    const buf2_name = buf2.name;

    const buf3 = try mgr.createUntitled();
    try std.testing.expectEqual(@as(usize, 3), mgr.buffers.items.len);
    try std.testing.expectEqual(@as(usize, 2), mgr.active_index);

    try std.testing.expect(!std.mem.eql(u8, buf2_name, buf3.name));
}

test "buffer manager unique buffer IDs" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var mgr = BufferManager.init(allocator, io);
    defer mgr.deinit();

    const initial_id = mgr.buffers.items[0].id;
    const buf2 = try mgr.createUntitled();
    const buf2_id = buf2.id;
    const buf3 = try mgr.createUntitled();

    try std.testing.expect(initial_id != buf2_id);
    try std.testing.expect(buf2_id != buf3.id);
    try std.testing.expect(initial_id != buf3.id);
}

test "buffer manager open virtual buffer" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var mgr = BufferManager.init(allocator, io);
    defer mgr.deinit();

    try mgr.openVirtual("test-buffer", "Hello, World!");
    try std.testing.expectEqual(@as(usize, 2), mgr.buffers.items.len);
    try std.testing.expectEqual(@as(usize, 1), mgr.active_index);

    const buf = mgr.getActive();
    try std.testing.expectEqualStrings("test-buffer", buf.name);
    try std.testing.expect(buf.file_path == null);
    try std.testing.expect(!buf.state.modified);
}

test "buffer manager open virtual updates existing" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var mgr = BufferManager.init(allocator, io);
    defer mgr.deinit();

    try mgr.openVirtual("my-buffer", "Initial content");
    try std.testing.expectEqual(@as(usize, 2), mgr.buffers.items.len);

    try mgr.openVirtual("my-buffer", "Updated content");
    try std.testing.expectEqual(@as(usize, 2), mgr.buffers.items.len);

    const buf = mgr.getActive();
    try std.testing.expectEqualStrings("my-buffer", buf.name);
}

test "buffer manager open virtual update preserves viewport state" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var mgr = BufferManager.init(allocator, io);
    defer mgr.deinit();

    try mgr.openVirtual("[STATS]", "line 1\nline 2\nline 3\nline 4\nline 5\n");
    mgr.getActive().state.cursor_row = 3;
    mgr.getActive().state.cursor_col = 2;
    mgr.getActive().state.scroll_offset = 2;

    try mgr.openVirtual("[STATS]", "line 1 updated\nline 2 updated\nline 3 updated\nline 4 updated\nline 5 updated\n");

    const buf = mgr.getActive();
    try std.testing.expectEqualStrings("[STATS]", buf.name);
    try std.testing.expectEqual(@as(usize, 3), buf.state.cursor_row);
    try std.testing.expectEqual(@as(usize, 2), buf.state.cursor_col);
    try std.testing.expectEqual(@as(usize, 2), buf.state.scroll_offset);
}

test "buffer manager marks markdown virtual buffers for presentation rendering" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var mgr = BufferManager.init(allocator, io);
    defer mgr.deinit();

    try mgr.openVirtual("[Plugin Manager]", "# Plugin Manager\n\n- Loaded: 4\n");

    const buf = mgr.getActive();
    try std.testing.expectEqual(.markdown_view, buf.presentation);
    try std.testing.expect(buf.isPresentationReadOnly());
}

test "buffer manager keeps plain virtual buffers as editable-style text presentation" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var mgr = BufferManager.init(allocator, io);
    defer mgr.deinit();

    try mgr.openVirtual("[RAW]", "plain output\nwithout markdown markers\n");

    const buf = mgr.getActive();
    try std.testing.expectEqual(.text, buf.presentation);
    try std.testing.expect(!buf.isPresentationReadOnly());
}

test "buffer manager treats diff virtual buffers as presentation rendering" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var mgr = BufferManager.init(allocator, io);
    defer mgr.deinit();

    try mgr.openVirtual("[Git Diff]", "diff --git a/src/main.zig b/src/main.zig\n@@ -1 +1 @@\n-old\n+new\n");

    const buf = mgr.getActive();
    try std.testing.expectEqual(.markdown_view, buf.presentation);
}

test "buffer manager refreshes virtual presentation on update" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var mgr = BufferManager.init(allocator, io);
    defer mgr.deinit();

    try mgr.openVirtual("[Report]", "plain output\n");
    try std.testing.expectEqual(.text, mgr.getActive().presentation);

    try mgr.openVirtual("[Report]", "# Report\n\n- Ready: yes\n");
    try std.testing.expectEqual(.markdown_view, mgr.getActive().presentation);
}

test "buffer manager marks every known generated report buffer as presentation" {
    const Case = struct {
        name: []const u8,
        content: []const u8,
    };
    const cases = [_]Case{
        .{ .name = "[HELP]", .content = "Stem help text\n\nUse Space for commands.\n" },
        .{ .name = "[PLUGINS]", .content = "Plugin Manager\nLoaded plugins: 4\n" },
        .{ .name = "[Plugins]", .content = "Plugin inspection\nRuntime: wasm\n" },
        .{ .name = "[Git Status]", .content = "On branch main\nStaged: 0   Unstaged: 0   Untracked: 0\nWorking tree clean.\n" },
        .{ .name = "[Git Diff]", .content = "No unstaged changes.\n" },
        .{ .name = "[Git Diff Staged]", .content = "No staged changes.\n" },
        .{ .name = "[Plugin Manager]", .content = "Plugin Manager dashboard unavailable.\n" },
        .{ .name = "[Plugin Permissions]", .content = "Permission dashboard unavailable.\n" },
        .{ .name = "[Plugin Storage]", .content = "plugin_manager storage:\ndashboard.opens: 1\n" },
        .{ .name = "[Plugin Load]", .content = "Plugin loading is managed through the stem plugin CLI.\n" },
        .{ .name = "[Plugin Unload]", .content = "Plugin removal instructions.\n" },
        .{ .name = "[Plugin Reload]", .content = "Reloading installed plugins...\n" },
        .{ .name = "[STATS]", .content = "Vigil\nTelemetry bridge: initialized\n" },
        .{ .name = "[CONTROL CENTER]", .content = "Control Center\nBuild status: idle\n" },
        .{ .name = "[PROJECT BRAIN]", .content = "Project Brain\nWorkspace: stem\n" },
        .{ .name = "[TASKS]", .content = "Project Tasks\nzig.build zig build build.zig\n" },
        .{ .name = "[TASK OUTPUT]", .content = "Task Output\nStarted background task #1.\n" },
        .{ .name = "[Jobs]", .content = "Background Jobs\nActive: 0\n" },
        .{ .name = "[LSP Status]", .content = "LSP Status\nServers: 2 running\n" },
        .{ .name = "[Diagnostics]", .content = "=== Diagnostics ===\n\nLn 4: [WARN] unused local\n" },
        .{ .name = "[References]", .content = "Symbol: WorkerState\nLn 12: pub const WorkerState\n" },
        .{ .name = "[Bookmarks]", .content = "Bookmarks\nSlot  Line   File\n" },
        .{ .name = "[Recovery Backups]", .content = "Recovery backups in /tmp\n(no backups present)\n" },
        .{ .name = "[Build]", .content = "Could not find build.zig in any parent directory.\n" },
        .{ .name = "[Zig Build]", .content = "BUILD SUCCESSFUL\nDuration: 10ms\n" },
        .{ .name = "[Zig Test]", .content = "ALL TESTS PASSED\nDuration: 10ms\n" },
        .{ .name = "[Zig Run]", .content = "RUN COMPLETED\nDuration: 10ms\n" },
        .{ .name = "[Error]", .content = "Reload failed: FileNotFound\n" },
    };

    for (cases) |case| {
        try std.testing.expectEqual(.markdown_view, classifyVirtualPresentation(case.name, case.content));
    }
}

test "buffer manager keeps document-like virtual buffers editable text" {
    try std.testing.expectEqual(.text, classifyVirtualPresentation("[Scratch]", ""));
    try std.testing.expectEqual(.text, classifyVirtualPresentation("Scratch-2", ""));
    try std.testing.expectEqual(.text, classifyVirtualPresentation("[HEAD] main.zig", "const std = @import(\"std\");\n"));
    try std.testing.expectEqual(.text, classifyVirtualPresentation("[Plugin JSON]", "{\"loaded\":true}\n"));
    try std.testing.expectEqual(.text, classifyVirtualPresentation("plain-buffer", "plain output\n"));
}

test "buffer manager switch to buffer" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var mgr = BufferManager.init(allocator, io);
    defer mgr.deinit();

    _ = try mgr.createUntitled();
    _ = try mgr.createUntitled();
    try std.testing.expectEqual(@as(usize, 3), mgr.buffers.items.len);
    try std.testing.expectEqual(@as(usize, 2), mgr.active_index);

    mgr.switchTo(0);
    try std.testing.expectEqual(@as(usize, 0), mgr.active_index);

    mgr.switchTo(1);
    try std.testing.expectEqual(@as(usize, 1), mgr.active_index);

    mgr.switchTo(100);
    try std.testing.expectEqual(@as(usize, 1), mgr.active_index);
}

test "buffer manager next and prev buffer" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var mgr = BufferManager.init(allocator, io);
    defer mgr.deinit();

    _ = try mgr.createUntitled();
    _ = try mgr.createUntitled();

    mgr.prevBuffer();
    try std.testing.expectEqual(@as(usize, 1), mgr.active_index);

    mgr.prevBuffer();
    try std.testing.expectEqual(@as(usize, 0), mgr.active_index);

    mgr.prevBuffer();
    try std.testing.expectEqual(@as(usize, 2), mgr.active_index);

    mgr.nextBuffer();
    try std.testing.expectEqual(@as(usize, 0), mgr.active_index);

    mgr.nextBuffer();
    try std.testing.expectEqual(@as(usize, 1), mgr.active_index);
}

test "buffer manager next prev single buffer" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var mgr = BufferManager.init(allocator, io);
    defer mgr.deinit();

    try std.testing.expectEqual(@as(usize, 1), mgr.buffers.items.len);
    try std.testing.expectEqual(@as(usize, 0), mgr.active_index);

    mgr.nextBuffer();
    try std.testing.expectEqual(@as(usize, 0), mgr.active_index);

    mgr.prevBuffer();
    try std.testing.expectEqual(@as(usize, 0), mgr.active_index);
}

test "buffer manager close active" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var mgr = BufferManager.init(allocator, io);
    defer mgr.deinit();

    _ = try mgr.createUntitled();
    _ = try mgr.createUntitled();
    try std.testing.expectEqual(@as(usize, 3), mgr.buffers.items.len);

    const closed = mgr.closeActive();
    try std.testing.expect(closed);
    try std.testing.expectEqual(@as(usize, 2), mgr.buffers.items.len);
    try std.testing.expectEqual(@as(usize, 1), mgr.active_index);

    const closed2 = mgr.closeActive();
    try std.testing.expect(closed2);
    try std.testing.expectEqual(@as(usize, 1), mgr.buffers.items.len);
    try std.testing.expectEqual(@as(usize, 0), mgr.active_index);
}

test "buffer manager close last buffer clears it" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var mgr = BufferManager.init(allocator, io);
    defer mgr.deinit();

    try std.testing.expectEqual(@as(usize, 1), mgr.buffers.items.len);

    const closed = mgr.closeActive();
    try std.testing.expect(!closed);
    try std.testing.expectEqual(@as(usize, 1), mgr.buffers.items.len);

    const buf = mgr.getActive();
    try std.testing.expect(buf.file_path == null);
    try std.testing.expect(std.mem.startsWith(u8, buf.name, "untitled-"));
}

test "buffer manager close active from middle" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var mgr = BufferManager.init(allocator, io);
    defer mgr.deinit();

    _ = try mgr.createUntitled();
    _ = try mgr.createUntitled();
    _ = try mgr.createUntitled();

    mgr.switchTo(1);
    try std.testing.expectEqual(@as(usize, 1), mgr.active_index);

    _ = mgr.closeActive();
    try std.testing.expectEqual(@as(usize, 3), mgr.buffers.items.len);
    try std.testing.expectEqual(@as(usize, 1), mgr.active_index);
}

test "buffer manager close others" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var mgr = BufferManager.init(allocator, io);
    defer mgr.deinit();

    _ = try mgr.createUntitled();
    try mgr.openVirtual("keep-this", "content");
    _ = try mgr.createUntitled();

    mgr.switchTo(2);
    const active_name = mgr.getActive().name;
    try std.testing.expectEqualStrings("keep-this", active_name);

    mgr.closeOthers();
    try std.testing.expectEqual(@as(usize, 1), mgr.buffers.items.len);
    try std.testing.expectEqual(@as(usize, 0), mgr.active_index);

    const remaining = mgr.getActive();
    try std.testing.expectEqualStrings("keep-this", remaining.name);
}

test "buffer manager close others with single buffer" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var mgr = BufferManager.init(allocator, io);
    defer mgr.deinit();

    try std.testing.expectEqual(@as(usize, 1), mgr.buffers.items.len);

    mgr.closeOthers();
    try std.testing.expectEqual(@as(usize, 1), mgr.buffers.items.len);
}

test "buffer manager get active" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var mgr = BufferManager.init(allocator, io);
    defer mgr.deinit();

    const buf1 = mgr.getActive();
    try std.testing.expectEqual(@as(usize, 0), mgr.active_index);
    const buf1_id = buf1.id;

    _ = try mgr.createUntitled();
    const buf2 = mgr.getActive();

    try std.testing.expect(buf1_id != buf2.id);
}

test "buffer manager picker move up" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var mgr = BufferManager.init(allocator, io);
    defer mgr.deinit();

    _ = try mgr.createUntitled();
    _ = try mgr.createUntitled();

    mgr.picker_selected = 2;

    mgr.pickerMoveUp();
    try std.testing.expectEqual(@as(usize, 1), mgr.picker_selected);

    mgr.pickerMoveUp();
    try std.testing.expectEqual(@as(usize, 0), mgr.picker_selected);

    mgr.pickerMoveUp();
    try std.testing.expectEqual(@as(usize, 0), mgr.picker_selected);
}

test "buffer manager picker move down" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var mgr = BufferManager.init(allocator, io);
    defer mgr.deinit();

    _ = try mgr.createUntitled();
    _ = try mgr.createUntitled();

    mgr.picker_selected = 0;

    mgr.pickerMoveDown();
    try std.testing.expectEqual(@as(usize, 1), mgr.picker_selected);

    mgr.pickerMoveDown();
    try std.testing.expectEqual(@as(usize, 2), mgr.picker_selected);

    mgr.pickerMoveDown();
    try std.testing.expectEqual(@as(usize, 2), mgr.picker_selected);
}

test "buffer manager picker select" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var mgr = BufferManager.init(allocator, io);
    defer mgr.deinit();

    _ = try mgr.createUntitled();
    _ = try mgr.createUntitled();

    mgr.switchTo(0);
    mgr.picker_selected = 2;

    mgr.pickerSelect();
    try std.testing.expectEqual(@as(usize, 2), mgr.active_index);
}

test "buffer manager picker reset" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var mgr = BufferManager.init(allocator, io);
    defer mgr.deinit();

    _ = try mgr.createUntitled();
    _ = try mgr.createUntitled();

    mgr.switchTo(1);
    mgr.picker_selected = 2;
    mgr.picker_scroll_offset = 5;

    mgr.pickerReset();
    try std.testing.expectEqual(@as(usize, 1), mgr.picker_selected);
    try std.testing.expectEqual(@as(usize, 0), mgr.picker_scroll_offset);
}

test "buffer deinit frees memory" {
    const allocator = std.testing.allocator;

    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    const state = try EditorState.init(allocator, io, "test content");
    const name = try allocator.dupe(u8, "test-buffer");
    const path = try allocator.dupe(u8, "/test/path.zig");

    var buffer = Buffer{
        .id = 1,
        .state = state,
        .name = name,
        .file_path = path,
    };

    buffer.deinit(allocator);
}

test "buffer deinit with null file_path" {
    const allocator = std.testing.allocator;

    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    const state = try EditorState.init(allocator, io, "");
    const name = try allocator.dupe(u8, "untitled");

    var buffer = Buffer{
        .id = 1,
        .state = state,
        .name = name,
        .file_path = null,
    };

    buffer.deinit(allocator);
}

test "buffer manager multiple virtual buffers" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var mgr = BufferManager.init(allocator, io);
    defer mgr.deinit();

    try mgr.openVirtual("buffer-a", "Content A");
    try mgr.openVirtual("buffer-b", "Content B");
    try mgr.openVirtual("buffer-c", "Content C");

    try std.testing.expectEqual(@as(usize, 4), mgr.buffers.items.len);

    var found_a = false;
    var found_b = false;
    var found_c = false;

    for (mgr.buffers.items) |buf| {
        if (std.mem.eql(u8, buf.name, "buffer-a")) found_a = true;
        if (std.mem.eql(u8, buf.name, "buffer-b")) found_b = true;
        if (std.mem.eql(u8, buf.name, "buffer-c")) found_c = true;
    }

    try std.testing.expect(found_a);
    try std.testing.expect(found_b);
    try std.testing.expect(found_c);
}

test "buffer manager active index bounds after close" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var mgr = BufferManager.init(allocator, io);
    defer mgr.deinit();

    _ = try mgr.createUntitled();
    _ = try mgr.createUntitled();

    try std.testing.expectEqual(@as(usize, 2), mgr.active_index);

    _ = mgr.closeActive();
    try std.testing.expect(mgr.active_index < mgr.buffers.items.len);

    _ = mgr.closeActive();
    try std.testing.expect(mgr.active_index < mgr.buffers.items.len);
}

fn testBufferManagerMemoryCleanup(allocator: std.mem.Allocator) !void {
    var mgr = BufferManager.init(allocator);
    defer mgr.deinit();

    _ = try mgr.createUntitled();
    _ = try mgr.createUntitled();
    try mgr.openVirtual("test1", "content1");
    try mgr.openVirtual("test2", "content2");

    try std.testing.expectEqual(@as(usize, 5), mgr.buffers.items.len);
}

fn testBufferMemoryCleanup(allocator: std.mem.Allocator) !void {
    var mgr = BufferManager.init(allocator);
    defer mgr.deinit();

    try mgr.openVirtual("test-buffer", "test content");

    const buffer = mgr.getActive();
    try std.testing.expect(buffer.id > 0);
    try std.testing.expectEqualStrings("test-buffer", buffer.name);
}

test "BufferManager performance with many buffers" {
    var io_ctx = TestIo.init(std.testing.allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var mgr = BufferManager.init(std.testing.allocator, io);
    defer mgr.deinit();

    for (0..100) |_| {
        _ = try mgr.createUntitled();
    }

    try std.testing.expectEqual(@as(usize, 101), mgr.buffers.items.len);

    try PerformanceTestUtils.expectPerformance(BufferManager.switchTo, .{ &mgr, 50 }, 100_000);

    try PerformanceTestUtils.expectPerformance(BufferManager.pickerMoveDown, .{&mgr}, 50_000);
}

test "BufferManager buffer creation performance" {
    var io_ctx = TestIo.init(std.testing.allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var mgr = BufferManager.init(std.testing.allocator, io);
    defer mgr.deinit();

    try PerformanceTestUtils.expectPerformance(struct {
        fn createMany(mgr_ptr: *BufferManager) void {
            for (0..50) |_| {
                _ = mgr_ptr.createUntitled() catch {};
            }
        }
    }.createMany, .{&mgr}, 10_000_000);
}

test "BufferManager open virtual with long name" {
    var io_ctx = TestIo.init(std.testing.allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var mgr = BufferManager.init(std.testing.allocator, io);
    defer mgr.deinit();

    const long_name = "very_long_buffer_name_that_is_still_valid";
    try mgr.openVirtual(long_name, "content for long named buffer");

    try std.testing.expectEqual(@as(usize, 2), mgr.buffers.items.len);
    const buffer = mgr.getActive();
    try std.testing.expectEqualStrings(long_name, buffer.name);
}

test "BufferManager open virtual with special characters" {
    var io_ctx = TestIo.init(std.testing.allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var mgr = BufferManager.init(std.testing.allocator, io);
    defer mgr.deinit();

    try mgr.openVirtual("test with spaces", "content");
    try mgr.openVirtual("test-with-dashes", "content");
    try mgr.openVirtual("test_with_underscores", "content");
    try mgr.openVirtual("test/with/slashes", "content");

    try std.testing.expectEqual(@as(usize, 5), mgr.buffers.items.len);

    try std.testing.expect(std.mem.eql(u8, mgr.buffers.items[1].name, "test with spaces"));
    try std.testing.expect(std.mem.eql(u8, mgr.buffers.items[2].name, "test-with-dashes"));
    try std.testing.expect(std.mem.eql(u8, mgr.buffers.items[4].name, "test/with/slashes"));
}

test "BufferManager switch to invalid index" {
    var io_ctx = TestIo.init(std.testing.allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var mgr = BufferManager.init(std.testing.allocator, io);
    defer mgr.deinit();

    const original_active = mgr.active_index;

    mgr.switchTo(999);
    try std.testing.expectEqual(original_active, mgr.active_index);
}

test "BufferManager picker operations with few buffers" {
    var io_ctx = TestIo.init(std.testing.allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var mgr = BufferManager.init(std.testing.allocator, io);
    defer mgr.deinit();

    mgr.pickerReset();
    try std.testing.expectEqual(@as(usize, 0), mgr.picker_selected);

    mgr.pickerMoveDown();
    try std.testing.expectEqual(@as(usize, 0), mgr.picker_selected);

    mgr.pickerMoveUp();
    try std.testing.expectEqual(@as(usize, 0), mgr.picker_selected);
}

test "BufferManager close active with modified buffer" {
    var io_ctx = TestIo.init(std.testing.allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var mgr = BufferManager.init(std.testing.allocator, io);
    defer mgr.deinit();

    const buffer = try mgr.createUntitled();
    buffer.state.modified = true;

    const closed = mgr.closeActive();
    try std.testing.expect(closed);
    try std.testing.expectEqual(@as(usize, 1), mgr.buffers.items.len);
}

test "BufferManager open same buffer name multiple times" {
    var io_ctx = TestIo.init(std.testing.allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var mgr = BufferManager.init(std.testing.allocator, io);
    defer mgr.deinit();

    try mgr.openVirtual("same-buffer", "content1");
    const initial_count = mgr.buffers.items.len;
    try std.testing.expectEqual(@as(usize, 2), initial_count);

    try mgr.openVirtual("same-buffer", "content2");
    try std.testing.expectEqual(@as(usize, 2), mgr.buffers.items.len);

    try mgr.openVirtual("different-buffer", "content3");
    try std.testing.expectEqual(@as(usize, 3), mgr.buffers.items.len);
}

test "BufferManager buffer ID uniqueness" {
    var io_ctx = TestIo.init(std.testing.allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var mgr = BufferManager.init(std.testing.allocator, io);
    defer mgr.deinit();

    var ids = std.AutoHashMap(u32, void).init(std.testing.allocator);
    defer ids.deinit();

    _ = try mgr.createUntitled();
    _ = try mgr.createUntitled();
    try mgr.openVirtual("test1", "content");
    try mgr.openVirtual("test2", "content");

    for (mgr.buffers.items) |buf| {
        if (ids.contains(buf.id)) {
            std.debug.print("Duplicate buffer ID found: {}\n", .{buf.id});
            return error.DuplicateBufferID;
        }
        try ids.put(buf.id, {});
    }
}

test "BufferManager next/prev buffer wrapping" {
    var io_ctx = TestIo.init(std.testing.allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var mgr = BufferManager.init(std.testing.allocator, io);
    defer mgr.deinit();

    _ = try mgr.createUntitled();
    _ = try mgr.createUntitled();

    mgr.nextBuffer();
    try std.testing.expectEqual(@as(usize, 0), mgr.active_index);

    mgr.prevBuffer();
    try std.testing.expectEqual(@as(usize, 2), mgr.active_index);
}

test "BufferManager picker scrolling with many buffers" {
    var io_ctx = TestIo.init(std.testing.allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var mgr = BufferManager.init(std.testing.allocator, io);
    defer mgr.deinit();

    for (0..20) |_| {
        _ = try mgr.createUntitled();
    }

    mgr.pickerReset();
    try std.testing.expectEqual(mgr.active_index, mgr.picker_selected);

    for (0..10) |_| {
        mgr.pickerMoveDown();
    }

    try std.testing.expect(mgr.picker_selected <= mgr.buffers.items.len - 1);

    for (0..5) |_| {
        mgr.pickerMoveUp();
    }

    try std.testing.expect(mgr.picker_selected <= mgr.buffers.items.len - 1);
}

test "BufferManager picker select changes active" {
    var io_ctx = TestIo.init(std.testing.allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var mgr = BufferManager.init(std.testing.allocator, io);
    defer mgr.deinit();

    _ = try mgr.createUntitled();
    _ = try mgr.createUntitled();

    try std.testing.expectEqual(@as(usize, 2), mgr.active_index);

    mgr.pickerReset();
    try std.testing.expectEqual(@as(usize, 2), mgr.picker_selected);

    mgr.picker_selected = 1;

    mgr.pickerSelect();
    try std.testing.expectEqual(@as(usize, 1), mgr.active_index);
}

test "BufferManager close others preserves active" {
    var io_ctx = TestIo.init(std.testing.allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var mgr = BufferManager.init(std.testing.allocator, io);
    defer mgr.deinit();

    _ = try mgr.createUntitled();
    _ = try mgr.createUntitled();
    _ = try mgr.createUntitled();

    mgr.switchTo(1);
    mgr.closeOthers();

    try std.testing.expectEqual(@as(usize, 1), mgr.buffers.items.len);
    try std.testing.expectEqual(@as(usize, 0), mgr.active_index);
    try std.testing.expectEqual(mgr.getActive().id, mgr.buffers.items[0].id);
}

test "BufferManager untitled counter persistence" {
    var io_ctx = TestIo.init(std.testing.allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var mgr = BufferManager.init(std.testing.allocator, io);
    defer mgr.deinit();

    _ = try mgr.createUntitled();
    _ = try mgr.createUntitled();
    _ = try mgr.createUntitled();

    try std.testing.expectEqual(@as(u32, 5), mgr.untitled_counter);

    var names = std.StringHashMap(void).init(std.testing.allocator);
    defer names.deinit();

    for (mgr.buffers.items) |buf| {
        if (names.contains(buf.name)) {
            return error.DuplicateBufferName;
        }
        try names.put(buf.name, {});
    }
}

test "BufferManager handle unicode filenames" {
    var io_ctx = TestIo.init(std.testing.allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var mgr = BufferManager.init(std.testing.allocator, io);
    defer mgr.deinit();

    try mgr.openVirtual("tëst_ünicöde", "content");
    try mgr.openVirtual("файл", "content");
    try mgr.openVirtual("ファイル", "content");

    try std.testing.expectEqual(@as(usize, 4), mgr.buffers.items.len);

    try std.testing.expect(std.mem.eql(u8, mgr.buffers.items[1].name, "tëst_ünicöde"));
    try std.testing.expect(std.mem.eql(u8, mgr.buffers.items[2].name, "файл"));
    try std.testing.expect(std.mem.eql(u8, mgr.buffers.items[3].name, "ファイル"));
}

test "BufferManager handle unicode buffer names" {
    var io_ctx = TestIo.init(std.testing.allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var mgr = BufferManager.init(std.testing.allocator, io);
    defer mgr.deinit();

    const unicode_name = "tëst_ünicöde_файл.txt";
    try mgr.openVirtual(unicode_name, "unicode content");

    const buffer = mgr.getActive();
    try std.testing.expectEqualStrings(unicode_name, buffer.name);
}

test "BufferManager state consistency after operations" {
    var io_ctx = TestIo.init(std.testing.allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var mgr = BufferManager.init(std.testing.allocator, io);
    defer mgr.deinit();

    _ = try mgr.createUntitled();
    _ = try mgr.createUntitled();
    try mgr.openVirtual("test1", "content1");
    try mgr.openVirtual("test2", "content2");

    mgr.switchTo(2);
    _ = mgr.closeActive();
    mgr.nextBuffer();
    mgr.prevBuffer();

    try std.testing.expect(mgr.active_index < mgr.buffers.items.len);
    try std.testing.expect(mgr.picker_selected < mgr.buffers.items.len);

    for (mgr.buffers.items) |buf| {
        try std.testing.expect(buf.id > 0);
        try std.testing.expect(buf.name.len > 0);
    }
}

test "BufferManager integration with modified state" {
    var io_ctx = TestIo.init(std.testing.allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var mgr = BufferManager.init(std.testing.allocator, io);
    defer mgr.deinit();

    var buffer = try mgr.createUntitled();

    buffer.state.modified = true;
    try std.testing.expect(buffer.state.modified);

    var buffer2 = try mgr.createUntitled();
    buffer2.state.modified = false;

    mgr.switchTo(1);
    try std.testing.expect(mgr.getActive().state.modified);

    mgr.switchTo(2);
    try std.testing.expect(!mgr.getActive().state.modified);
}

test "BufferManager preserve editor state on buffer switch" {
    var io_ctx = TestIo.init(std.testing.allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();
    var mgr = BufferManager.init(std.testing.allocator, io);
    defer mgr.deinit();

    mgr.getActive().state.cursor_row = 5;
    mgr.getActive().state.cursor_col = 10;

    var buf1 = try mgr.createUntitled();
    buf1.state.cursor_row = 15;
    buf1.state.cursor_col = 25;

    mgr.switchTo(0);
    try std.testing.expectEqual(@as(usize, 5), mgr.getActive().state.cursor_row);
    try std.testing.expectEqual(@as(usize, 10), mgr.getActive().state.cursor_col);

    mgr.switchTo(1);
    try std.testing.expectEqual(@as(usize, 15), mgr.getActive().state.cursor_row);
    try std.testing.expectEqual(@as(usize, 25), mgr.getActive().state.cursor_col);
}

test "BufferManager.addFileLazyBackground: does not change active_index" {
    var io_ctx = TestIo.init(std.testing.allocator);
    defer io_ctx.deinit();
    var mgr = BufferManager.init(std.testing.allocator, io_ctx.io());
    defer mgr.deinit();

    // Fresh manager starts with one untitled buffer; active_index = 0.
    const initial_active = mgr.active_index;
    const initial_count = mgr.buffers.items.len;

    try mgr.addFileLazyBackground("/fake/a.zig");
    try mgr.addFileLazyBackground("/fake/b.zig");
    try mgr.addFileLazyBackground("/fake/c.zig");

    try std.testing.expectEqual(initial_count + 3, mgr.buffers.items.len);
    // Active index unchanged — this is the whole point of the background
    // variant.
    try std.testing.expectEqual(initial_active, mgr.active_index);
}

test "BufferManager.addFileLazyBackground: is idempotent on duplicate paths" {
    var io_ctx = TestIo.init(std.testing.allocator);
    defer io_ctx.deinit();
    var mgr = BufferManager.init(std.testing.allocator, io_ctx.io());
    defer mgr.deinit();

    const before = mgr.buffers.items.len;
    try mgr.addFileLazyBackground("/fake/main.zig");
    try mgr.addFileLazyBackground("/fake/main.zig");
    try mgr.addFileLazyBackground("/fake/main.zig");
    try std.testing.expectEqual(before + 1, mgr.buffers.items.len);
}

test "BufferManager.addFileLazyBackground: new buffers are marked not_loaded" {
    var io_ctx = TestIo.init(std.testing.allocator);
    defer io_ctx.deinit();
    var mgr = BufferManager.init(std.testing.allocator, io_ctx.io());
    defer mgr.deinit();

    try mgr.addFileLazyBackground("/fake/lazy.zig");
    const added = &mgr.buffers.items[mgr.buffers.items.len - 1];
    try std.testing.expect(added.not_loaded);
    try std.testing.expectEqualStrings("/fake/lazy.zig", added.file_path.?);
}

// ────────────────────────────────────────────────────────────
// Regression tests for the close-and-return-id path (added so
// Core.closeCurrentPaneOrBuffer can evict the closed buffer
// from per-buffer caches like the SyntaxManager's tree cache).
// ────────────────────────────────────────────────────────────

test "closeActiveReturningId returns the closed buffer id" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    var mgr = BufferManager.init(allocator, io_ctx.io());
    defer mgr.deinit();

    // Add a second buffer so close has somewhere to land.
    _ = try mgr.createUntitled();
    const active_id_before = mgr.getActive().id;

    const returned = mgr.closeActiveReturningId();
    try std.testing.expectEqual(@as(?u32, active_id_before), returned);
    try std.testing.expectEqual(@as(usize, 1), mgr.buffers.items.len);
}

test "closeActiveReturningId returns null when single buffer would be reset" {
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    var mgr = BufferManager.init(allocator, io_ctx.io());
    defer mgr.deinit();

    // Single-buffer close path resets to untitled rather than
    // removing, so the id-returning contract says "nothing was
    // removed → null". Without this guarantee Core would
    // dropBuffer(0) on the SyntaxManager, which is a no-op today
    // but would mask real bugs later if id 0 ever became a valid
    // resource.
    try std.testing.expectEqual(@as(usize, 1), mgr.buffers.items.len);
    const returned = mgr.closeActiveReturningId();
    try std.testing.expectEqual(@as(?u32, null), returned);
    try std.testing.expectEqual(@as(usize, 1), mgr.buffers.items.len);
}

test "default_edit_hook is propagated to new buffers" {
    // Without this, a future refactor could break the
    // "every buffer's state.edit_hook is set" invariant that
    // tree-sitter incremental parsing depends on.
    const allocator = std.testing.allocator;
    var io_ctx = TestIo.init(allocator);
    defer io_ctx.deinit();
    var mgr = BufferManager.init(allocator, io_ctx.io());
    defer mgr.deinit();

    // Install a no-op hook.
    const NoopCtx = struct {
        fn call(_: *anyopaque, _: EditorState.EditEvent) void {}
    };
    var noop_ctx: u8 = 0;
    mgr.default_edit_hook = .{
        .ctx = @ptrCast(&noop_ctx),
        .call = NoopCtx.call,
    };
    mgr.refreshEditHooks();

    // The initial untitled buffer should now have the hook.
    try std.testing.expect(mgr.buffers.items[0].state.edit_hook != null);

    // A newly-created buffer should inherit it via newState.
    _ = try mgr.createUntitled();
    try std.testing.expect(mgr.buffers.items[1].state.edit_hook != null);
}
