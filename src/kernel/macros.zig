//! Transactional macro record & replay.
//!
//! Recording taps the core message loop: every `.input` key that
//! reaches the editor while recording is cloned into the active slot
//! ('a'–'z'), so a macro captures exactly what the bus delivered —
//! mode changes, palette flows, leader chords, everything. The
//! macro-control keys themselves (`q`, `@`, the slot letter) are
//! consumed before the tap and never recorded.
//!
//! Replay injects the recorded messages through a core-internal
//! queue that the message loop drains BEFORE its inbox — so a replay
//! executes atomically with respect to live input (a user keystroke
//! cannot land in the middle of a replay), needs no bus round-trip,
//! and is bracketed synchronously:
//!   - `onReplayBegin` (called when the replay is queued) flushes the
//!     pending undo transaction and remembers the undo-stack depth.
//!   - Failures during replay (a command that errors) are noted via
//!     `noteFailure`; the remaining queued keys are abandoned.
//!   - `onReplayEnd` (called when the queue drains) merges every
//!     transaction the replay pushed into ONE — the whole macro is a
//!     single undo group. On failure it rolls the buffer back to the
//!     pre-replay state and clears the redo stack, so a half-applied
//!     macro cannot exist.
//!
//! Keys (Select mode): `q` + slot letter starts recording, `q` stops,
//! `[count] @` + slot letter replays. Replay of an empty slot and
//! replay-while-recording are rejected with a status toast.

const std = @import("std");
const vaxis = @import("vaxis");
const protocol = @import("protocol.zig");
const logger = @import("../services/logger.zig");
const log = logger.scoped("Macros");

pub const SLOT_COUNT: usize = 26;

/// Owned clone of a `vaxis.Key` — the original's `text` slice points
/// at the terminal input buffer and dies with the message.
pub const StoredKey = struct {
    codepoint: u21,
    shift: bool,
    alt: bool,
    ctrl: bool,
    super: bool,
    text: ?[]u8,

    pub fn fromKey(allocator: std.mem.Allocator, key: vaxis.Key) !StoredKey {
        return .{
            .codepoint = @intCast(key.codepoint),
            .shift = key.mods.shift,
            .alt = key.mods.alt,
            .ctrl = key.mods.ctrl,
            .super = key.mods.super,
            .text = if (key.text) |t| try allocator.dupe(u8, t) else null,
        };
    }

    pub fn toKey(self: StoredKey) vaxis.Key {
        return .{
            .codepoint = self.codepoint,
            .mods = .{
                .shift = self.shift,
                .alt = self.alt,
                .ctrl = self.ctrl,
                .super = self.super,
            },
            .text = self.text,
        };
    }

    pub fn deinit(self: *StoredKey, allocator: std.mem.Allocator) void {
        if (self.text) |t| allocator.free(t);
    }
};

const Slot = std.ArrayListUnmanaged(StoredKey);

pub const MacroSystem = struct {
    allocator: std.mem.Allocator,
    slots: [SLOT_COUNT]?Slot = @splat(null),

    /// Slot currently recording into, if any.
    recording_slot: ?u8 = null,
    /// Waiting for the slot letter after `q` (record) or `@` (replay).
    pending: enum { none, record_slot, replay_slot } = .none,
    /// Count captured from `core.nav_repeat_count` when `@` was
    /// pressed, applied to the queued replay.
    pending_count: u32 = 1,
    /// Most recently recorded slot — `macro.replay_last` target.
    last_recorded: ?u8 = null,

    /// Replay bracket state, mutated only on the core thread.
    replay_active: bool = false,
    replay_failed: ?[]const u8 = null,
    replay_undo_base: usize = 0,
    /// Encoded `.input` protocol messages awaiting injection, oldest
    /// first. Drained by the core loop ahead of its inbox.
    replay_queue: std.ArrayListUnmanaged([]u8) = .empty,
    replay_pos: usize = 0,

    pub fn init(allocator: std.mem.Allocator) MacroSystem {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MacroSystem) void {
        for (&self.slots) |*maybe_slot| {
            if (maybe_slot.*) |*slot| {
                for (slot.items) |*k| k.deinit(self.allocator);
                slot.deinit(self.allocator);
            }
            maybe_slot.* = null;
        }
        self.clearReplayQueue();
        self.replay_queue.deinit(self.allocator);
    }

    fn clearReplayQueue(self: *MacroSystem) void {
        for (self.replay_queue.items) |bytes| self.allocator.free(bytes);
        self.replay_queue.clearRetainingCapacity();
        self.replay_pos = 0;
    }

    fn slotIndex(letter: u8) ?usize {
        if (letter < 'a' or letter > 'z') return null;
        return letter - 'a';
    }

    pub fn isRecording(self: *const MacroSystem) bool {
        return self.recording_slot != null;
    }

    /// Core-loop hook, called at the top of `.input` handling. Returns
    /// true when the key was a macro-control key and must not be
    /// processed (or recorded) further. Only intercepts in Select mode
    /// with no leader chord pending; replayed keys pass through
    /// untouched so a macro can't recursively re-arm the intercept.
    pub fn interceptKey(self: *MacroSystem, core: anytype, key: vaxis.Key) bool {
        if (self.replay_active) return false;

        switch (self.pending) {
            .record_slot => {
                self.pending = .none;
                if (key.codepoint < 128 and slotIndex(@truncate(key.codepoint)) != null) {
                    self.startRecording(core, @truncate(key.codepoint));
                } else {
                    core.setStatus("Macro: cancelled (want a-z)", .{}, 2000);
                }
                return true;
            },
            .replay_slot => {
                self.pending = .none;
                const count = self.pending_count;
                if (key.codepoint < 128 and slotIndex(@truncate(key.codepoint)) != null) {
                    self.queueReplay(core, @truncate(key.codepoint), count);
                } else {
                    core.setStatus("Macro: cancelled (want a-z)", .{}, 2000);
                }
                return true;
            },
            .none => {},
        }

        if (core.mode != .select or core.leader_pending) return false;
        if (key.mods.shift or key.mods.alt or key.mods.ctrl or key.mods.super) return false;

        if (key.codepoint == 'q') {
            if (self.recording_slot != null) {
                self.stopRecording(core);
            } else {
                self.pending = .record_slot;
                core.setStatus("Macro: record into register a-z...", .{}, 2500);
            }
            return true;
        }
        if (key.codepoint == '@') {
            if (self.recording_slot != null) {
                core.setStatus("Macro: cannot replay while recording", .{}, 2500);
                return true;
            }
            self.pending = .replay_slot;
            self.pending_count = if (core.nav_repeat_count > 0) @intCast(core.nav_repeat_count) else 1;
            core.nav_repeat_count = 0;
            core.setStatus("Macro: replay register a-z...", .{}, 2500);
            return true;
        }
        return false;
    }

    fn startRecording(self: *MacroSystem, core: anytype, letter: u8) void {
        const idx = slotIndex(letter).?;
        // Recording over a slot replaces it.
        if (self.slots[idx]) |*slot| {
            for (slot.items) |*k| k.deinit(self.allocator);
            slot.deinit(self.allocator);
        }
        self.slots[idx] = .empty;
        self.recording_slot = letter;
        core.setStatus("Macro: recording @{c} (q to stop)", .{letter}, 3000);
        log.info("macro record start: @{c}", .{letter});
    }

    fn stopRecording(self: *MacroSystem, core: anytype) void {
        const letter = self.recording_slot orelse return;
        self.recording_slot = null;
        self.last_recorded = letter;
        const n = if (self.slots[slotIndex(letter).?]) |slot| slot.items.len else 0;
        core.setStatus("Macro: recorded @{c} ({d} keys)", .{ letter, n }, 2500);
        log.info("macro record stop: @{c} ({d} keys)", .{ letter, n });
    }

    /// Tap for every `.input` key that passed the intercept. Failing
    /// to clone a key aborts the recording rather than persisting a
    /// macro with a silent hole in the middle.
    pub fn tapKey(self: *MacroSystem, core: anytype, key: vaxis.Key) void {
        const letter = self.recording_slot orelse return;
        const idx = slotIndex(letter).?;
        const stored = StoredKey.fromKey(self.allocator, key) catch {
            self.recording_slot = null;
            if (self.slots[idx]) |*slot| {
                for (slot.items) |*k| k.deinit(self.allocator);
                slot.deinit(self.allocator);
                self.slots[idx] = null;
            }
            core.setStatus("Macro: recording aborted (out of memory)", .{}, 3000);
            return;
        };
        var owned = stored;
        self.slots[idx].?.append(self.allocator, owned) catch {
            owned.deinit(self.allocator);
            self.recording_slot = null;
            core.setStatus("Macro: recording aborted (out of memory)", .{}, 3000);
        };
    }

    /// Stage `count` replays of a slot on the internal injection queue
    /// and open the transactional bracket. The core loop drains the
    /// queue ahead of its inbox, so the replay executes atomically with
    /// respect to live input.
    pub fn queueReplay(self: *MacroSystem, core: anytype, letter: u8, count: u32) void {
        const idx = slotIndex(letter) orelse return;
        const slot = self.slots[idx] orelse {
            core.setStatus("Macro: register @{c} is empty", .{letter}, 2000);
            return;
        };
        if (slot.items.len == 0) {
            core.setStatus("Macro: register @{c} is empty", .{letter}, 2000);
            return;
        }
        if (self.replay_active) return; // no nested replays

        self.clearReplayQueue();
        const total = slot.items.len * count;
        self.replay_queue.ensureTotalCapacity(self.allocator, total) catch {
            core.setStatus("Macro: replay failed (out of memory)", .{}, 3000);
            return;
        };
        var rep: u32 = 0;
        while (rep < count) : (rep += 1) {
            for (slot.items) |stored| {
                const bytes = (protocol.Message{ .input = stored.toKey() }).encode(self.allocator) catch {
                    self.clearReplayQueue();
                    core.setStatus("Macro: replay failed (out of memory)", .{}, 3000);
                    return;
                };
                self.replay_queue.appendAssumeCapacity(bytes);
            }
        }
        self.onReplayBegin(core);
        log.info("macro replay staged: @{c} x{d} ({d} keys)", .{ letter, count, total });
    }

    /// Core-loop injection point: the next encoded message to process
    /// in place of an inbox receive, or null when no replay is in
    /// flight (or the current one just finished / failed). Caller owns
    /// nothing — the returned slice stays owned by the queue and is
    /// valid until the next call.
    pub fn takeReplayMessage(self: *MacroSystem, core: anytype) ?[]const u8 {
        if (!self.replay_active) return null;
        // A noted failure abandons the rest of the replay — executing
        // keys past a failed step is exactly the half-applied state
        // the transaction exists to prevent.
        if (self.replay_failed != null or self.replay_pos >= self.replay_queue.items.len) {
            self.onReplayEnd(core);
            self.clearReplayQueue();
            return null;
        }
        const bytes = self.replay_queue.items[self.replay_pos];
        self.replay_pos += 1;
        return bytes;
    }

    /// Open the transactional bracket.
    pub fn onReplayBegin(self: *MacroSystem, core: anytype) void {
        const s = core.state();
        core.history_manager.flushTransaction(.{ .row = s.cursor_row, .col = s.cursor_col });
        self.replay_undo_base = core.history_manager.undo_stack.items.len;
        self.replay_failed = null;
        self.replay_active = true;
        log.info("macro replay bracket open (undo base {d})", .{self.replay_undo_base});
    }

    /// Record a failure that happened while a replay bracket is open.
    /// Called from the command-execution catch sites.
    pub fn noteFailure(self: *MacroSystem, err: anyerror) void {
        if (!self.replay_active) return;
        if (self.replay_failed == null) self.replay_failed = @errorName(err);
    }

    /// `macro_replay_end` handler: close the bracket — merge into one
    /// undo group on success, roll back on failure.
    pub fn onReplayEnd(self: *MacroSystem, core: anytype) void {
        if (!self.replay_active) return;
        self.replay_active = false;

        const s = core.state();
        core.history_manager.flushTransaction(.{ .row = s.cursor_row, .col = s.cursor_col });

        if (self.replay_failed) |err_name| {
            // All-or-nothing: unwind every transaction the replay
            // pushed, then drop the redo entries the unwinding
            // produced — "redo half a failed macro" must not exist.
            var guard: usize = 0;
            while (core.history_manager.undo_stack.items.len > self.replay_undo_base and guard < 10_000) : (guard += 1) {
                core.applyUndoOnce() catch |undo_err| {
                    log.warn("macro rollback undo failed: {s}", .{@errorName(undo_err)});
                    break;
                };
            }
            core.history_manager.clearRedo();
            core.setStatusError("Macro replay failed ({s}) — rolled back", .{err_name}, 4000);
            log.warn("macro replay failed: {s}; rolled back to depth {d}", .{ err_name, self.replay_undo_base });
        } else {
            core.history_manager.mergeSince(self.replay_undo_base);
            core.setStatus("Macro replayed (one undo group)", .{}, 2500);
            log.info("macro replay bracket closed clean (depth {d} -> {d})", .{
                self.replay_undo_base,
                core.history_manager.undo_stack.items.len,
            });
        }
    }
};

// ---------------------------------------------------------------------------
// Tests — MacroSystem state machine with a minimal fake core.
// ---------------------------------------------------------------------------

const TestIo = @import("../test_utils.zig").TestIo;
const HistoryManager = @import("history.zig").HistoryManager;

const FakeState = struct { cursor_row: usize = 0, cursor_col: usize = 0 };

const FakeCore = struct {
    mode: protocol.Mode = .select,
    leader_pending: bool = false,
    nav_repeat_count: usize = 0,
    history_manager: HistoryManager,
    fake_state: FakeState = .{},
    last_status: [128]u8 = @splat(0),

    fn state(self: *FakeCore) *FakeState {
        return &self.fake_state;
    }
    fn setStatus(self: *FakeCore, comptime fmt: []const u8, args: anytype, duration_ms: i64) void {
        _ = duration_ms;
        const msg = std.fmt.bufPrint(&self.last_status, fmt, args) catch return;
        _ = msg;
    }
    fn setStatusError(self: *FakeCore, comptime fmt: []const u8, args: anytype, duration_ms: i64) void {
        self.setStatus(fmt, args, duration_ms);
    }
    fn applyUndoOnce(self: *FakeCore) !void {
        // History-only rollback: pop the transaction without a real
        // buffer to apply it to.
        if (self.history_manager.undo()) |txn| {
            var t = txn;
            t.deinit(self.history_manager.allocator);
        }
    }
};

fn plainKey(cp: u21) vaxis.Key {
    return .{ .codepoint = cp, .mods = .{} };
}

test "macro record: q captures slot, keys are stored, q stops" {
    const a = std.testing.allocator;
    var io_ctx = TestIo.init(a);
    defer io_ctx.deinit();
    var core: FakeCore = .{ .history_manager = HistoryManager.init(a, io_ctx.io()) };
    defer core.history_manager.deinit();

    var ms = MacroSystem.init(a);
    defer ms.deinit();

    try std.testing.expect(ms.interceptKey(&core, plainKey('q'))); // arm
    try std.testing.expect(ms.interceptKey(&core, plainKey('m'))); // slot
    try std.testing.expect(ms.isRecording());

    // Normal keys are not intercepted while recording; the tap stores them.
    try std.testing.expect(!ms.interceptKey(&core, plainKey('x')));
    ms.tapKey(&core, plainKey('x'));
    ms.tapKey(&core, .{ .codepoint = 'y', .mods = .{}, .text = "y" });

    try std.testing.expect(ms.interceptKey(&core, plainKey('q'))); // stop
    try std.testing.expect(!ms.isRecording());

    const slot = ms.slots['m' - 'a'].?;
    try std.testing.expectEqual(@as(usize, 2), slot.items.len);
    try std.testing.expectEqual(@as(u21, 'x'), slot.items[0].codepoint);
    try std.testing.expectEqualStrings("y", slot.items[1].text.?);
}

test "macro replay: count prefix stages keys atomically, bracket opens" {
    const a = std.testing.allocator;
    var io_ctx = TestIo.init(a);
    defer io_ctx.deinit();
    var core: FakeCore = .{ .history_manager = HistoryManager.init(a, io_ctx.io()) };
    defer core.history_manager.deinit();

    var ms = MacroSystem.init(a);
    defer ms.deinit();

    // Record two keys into @b.
    _ = ms.interceptKey(&core, plainKey('q'));
    _ = ms.interceptKey(&core, plainKey('b'));
    ms.tapKey(&core, plainKey('x'));
    ms.tapKey(&core, plainKey('z'));
    _ = ms.interceptKey(&core, plainKey('q'));

    // 3@b -> 6 staged key messages, bracket open.
    core.nav_repeat_count = 3;
    try std.testing.expect(ms.interceptKey(&core, plainKey('@')));
    try std.testing.expectEqual(@as(usize, 0), core.nav_repeat_count);
    try std.testing.expect(ms.interceptKey(&core, plainKey('b')));
    try std.testing.expectEqual(@as(usize, 6), ms.replay_queue.items.len);
    try std.testing.expect(ms.replay_active);

    // Drain like the core loop does: 6 injected messages, each a
    // decodable .input, then the bracket closes.
    var seen: usize = 0;
    while (ms.takeReplayMessage(&core)) |bytes| {
        const decoded = try protocol.Message.decode(bytes);
        try std.testing.expect(decoded == .input);
        seen += 1;
    }
    try std.testing.expectEqual(@as(usize, 6), seen);
    try std.testing.expect(!ms.replay_active);
    try std.testing.expectEqual(@as(usize, 0), ms.replay_queue.items.len);
}

test "macro replay: empty register refuses without staging anything" {
    const a = std.testing.allocator;
    var io_ctx = TestIo.init(a);
    defer io_ctx.deinit();
    var core: FakeCore = .{ .history_manager = HistoryManager.init(a, io_ctx.io()) };
    defer core.history_manager.deinit();

    var ms = MacroSystem.init(a);
    defer ms.deinit();

    _ = ms.interceptKey(&core, plainKey('@'));
    _ = ms.interceptKey(&core, plainKey('z'));
    try std.testing.expectEqual(@as(usize, 0), ms.replay_queue.items.len);
    try std.testing.expect(!ms.replay_active);
}

test "transactional bracket: success merges to one undo group" {
    const a = std.testing.allocator;
    var io_ctx = TestIo.init(a);
    defer io_ctx.deinit();
    var core: FakeCore = .{ .history_manager = HistoryManager.init(a, io_ctx.io()) };
    defer core.history_manager.deinit();

    var ms = MacroSystem.init(a);
    defer ms.deinit();

    ms.onReplayBegin(&core);
    // Simulate three edits landing as three transactions.
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        core.history_manager.beginTransaction(.{ .row = 0, .col = i });
        try core.history_manager.recordInsert(i, "x");
        core.history_manager.commitTransaction(.{ .row = 0, .col = i + 1 });
        core.history_manager.last_action_time = 0; // defeat time-grouping
    }
    ms.onReplayEnd(&core);

    // One merged transaction holding all three actions.
    try std.testing.expectEqual(@as(usize, 1), core.history_manager.undo_stack.items.len);
    try std.testing.expectEqual(
        @as(usize, 3),
        core.history_manager.undo_stack.items[0].actions.items.len,
    );
}

test "transactional bracket: noted failure marks state for rollback" {
    const a = std.testing.allocator;
    var io_ctx = TestIo.init(a);
    defer io_ctx.deinit();
    var core: FakeCore = .{ .history_manager = HistoryManager.init(a, io_ctx.io()) };
    defer core.history_manager.deinit();

    var ms = MacroSystem.init(a);
    defer ms.deinit();

    // A pre-existing edit that must survive the rollback untouched.
    core.history_manager.beginTransaction(.{ .row = 0, .col = 0 });
    try core.history_manager.recordInsert(0, "keep");
    core.history_manager.commitTransaction(.{ .row = 0, .col = 4 });
    core.history_manager.last_action_time = 0;

    ms.onReplayBegin(&core);
    try std.testing.expect(ms.replay_active);

    // Replay lands two transactions, then a command fails.
    var i: usize = 0;
    while (i < 2) : (i += 1) {
        core.history_manager.beginTransaction(.{ .row = 0, .col = i });
        try core.history_manager.recordInsert(i, "x");
        core.history_manager.commitTransaction(.{ .row = 0, .col = i + 1 });
        core.history_manager.last_action_time = 0;
    }
    ms.noteFailure(error.CommandFailed);
    ms.noteFailure(error.LaterError); // first failure wins
    try std.testing.expectEqualStrings("CommandFailed", ms.replay_failed.?);

    ms.onReplayEnd(&core);

    // Rolled back to the pre-replay depth: the "keep" edit survives,
    // the replay's transactions are gone, and no redo entries let a
    // half-applied macro be resurrected.
    try std.testing.expect(!ms.replay_active);
    try std.testing.expectEqual(@as(usize, 1), core.history_manager.undo_stack.items.len);
    try std.testing.expectEqual(@as(usize, 0), core.history_manager.redoCount());
}
