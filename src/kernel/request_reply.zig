//! Correlation-ID-based async request/reply for stem.
//!
//! Vigil's built-in `request_reply` is synchronous — the caller blocks
//! on a reply mailbox. Exec plugins talk to the host through async
//! JSON-RPC, so requests with replies need correlation IDs that
//! survive arbitrary interleaving. A single-slot callback design would
//! silently break under concurrent requests: a second call would
//! overwrite the first's callback and the first reply would drop on
//! the floor.
//!
//! This module gives stem a per-context `RequestTracker`:
//!
//!   1. Every outgoing request gets a monotonically increasing u64 ID.
//!   2. The tracker maps ID → callback, with a TTL so abandoned
//!      requests don't leak forever.
//!   3. When a reply arrives, the dispatcher looks up its ID and fires
//!      the right callback. Multiple in-flight requests of the same
//!      kind coexist.
//!
//! The tracker is type-erased: the callback is stored as an opaque
//! pointer plus a trampoline. Each SDK request type provides its own
//! trampoline so the protocol decoder stays untouched.

const std = @import("std");
const vigil_api = @import("../services/vigil_adapters.zig");
const Mutex = vigil_api.Mutex;

/// Opaque callback. The trampoline interprets `payload` as the
/// concrete reply type and forwards to the typed callback the caller
/// originally registered.
pub const Trampoline = *const fn (
    user_data: *anyopaque,
    typed_cb: *anyopaque,
    payload: []const u8,
) void;

pub const Pending = struct {
    /// Caller-supplied user data (typically the PluginContext pointer).
    user_data: *anyopaque,
    /// Caller-supplied typed callback, cast to *anyopaque.
    typed_cb: *anyopaque,
    /// Knows how to cast `typed_cb` back and call it with `payload`.
    trampoline: Trampoline,
    /// Wall-clock deadline (ms since epoch). 0 = no timeout.
    deadline_ms: i64,
};

pub const RequestTracker = struct {
    allocator: std.mem.Allocator,
    mu: Mutex = .{},
    next_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(1),
    pending: std.AutoHashMapUnmanaged(u64, Pending) = .empty,

    pub fn init(allocator: std.mem.Allocator) RequestTracker {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *RequestTracker) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.pending.deinit(self.allocator);
    }

    /// Register a pending request and return its correlation ID. The
    /// caller embeds the ID into the outgoing wire message; the
    /// responder echoes it back; the tracker matches the reply.
    pub fn register(
        self: *RequestTracker,
        user_data: *anyopaque,
        typed_cb: *anyopaque,
        trampoline: Trampoline,
        timeout_ms: ?u32,
    ) !u64 {
        const id = self.next_id.fetchAdd(1, .acq_rel);
        const deadline: i64 = if (timeout_ms) |t|
            vigil_api.milliTimestamp() + @as(i64, t)
        else
            0;
        self.mu.lock();
        defer self.mu.unlock();
        try self.pending.put(self.allocator, id, .{
            .user_data = user_data,
            .typed_cb = typed_cb,
            .trampoline = trampoline,
            .deadline_ms = deadline,
        });
        return id;
    }

    /// Try to deliver a reply. Returns true if the correlation ID was
    /// known and the callback fired, false otherwise (e.g. duplicate
    /// reply, or the request already timed out).
    pub fn deliver(self: *RequestTracker, correlation_id: u64, payload: []const u8) bool {
        const entry = blk: {
            self.mu.lock();
            defer self.mu.unlock();
            const kv = self.pending.fetchRemove(correlation_id) orelse return false;
            break :blk kv.value;
        };
        entry.trampoline(entry.user_data, entry.typed_cb, payload);
        return true;
    }

    /// Drop any pending request whose deadline has passed. Returns the
    /// number expired so the caller can log it. Caller may also wish
    /// to invoke the trampoline with an "expired" payload, but that's
    /// orthogonal — keeping `sweep` side-effect-free here.
    pub fn sweepExpired(self: *RequestTracker) usize {
        const now_ms = vigil_api.milliTimestamp();
        self.mu.lock();
        defer self.mu.unlock();
        var expired: usize = 0;
        var it = self.pending.iterator();
        // Two-pass: collect ids, then remove. We can't mutate the map
        // during iteration.
        var to_remove: std.ArrayListUnmanaged(u64) = .empty;
        defer to_remove.deinit(self.allocator);
        while (it.next()) |entry| {
            const dl = entry.value_ptr.deadline_ms;
            if (dl != 0 and dl <= now_ms) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch break;
            }
        }
        for (to_remove.items) |id| {
            _ = self.pending.remove(id);
            expired += 1;
        }
        return expired;
    }

    pub fn pendingCount(self: *RequestTracker) usize {
        self.mu.lock();
        defer self.mu.unlock();
        return self.pending.count();
    }
};

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const TestUser = struct { last_payload: []const u8 = "" };

fn testTrampoline(user_data: *anyopaque, typed_cb: *anyopaque, payload: []const u8) void {
    _ = typed_cb;
    const u: *TestUser = @ptrCast(@alignCast(user_data));
    u.last_payload = payload;
}

test "RequestTracker: register and deliver" {
    var tracker = RequestTracker.init(std.testing.allocator);
    defer tracker.deinit();

    var user: TestUser = .{};
    var dummy_cb: u8 = 0;
    const id = try tracker.register(@ptrCast(&user), @ptrCast(&dummy_cb), testTrampoline, null);
    try std.testing.expectEqual(@as(usize, 1), tracker.pendingCount());

    try std.testing.expect(tracker.deliver(id, "hello"));
    try std.testing.expectEqualStrings("hello", user.last_payload);
    try std.testing.expectEqual(@as(usize, 0), tracker.pendingCount());

    // Second delivery for same id is a no-op.
    try std.testing.expect(!tracker.deliver(id, "ignored"));
}

test "RequestTracker: independent ids" {
    var tracker = RequestTracker.init(std.testing.allocator);
    defer tracker.deinit();

    var usr1: TestUser = .{};
    var usr2: TestUser = .{};
    var cb: u8 = 0;
    const id1 = try tracker.register(@ptrCast(&usr1), @ptrCast(&cb), testTrampoline, null);
    const id2 = try tracker.register(@ptrCast(&usr2), @ptrCast(&cb), testTrampoline, null);
    try std.testing.expect(id1 != id2);

    try std.testing.expect(tracker.deliver(id2, "second"));
    try std.testing.expect(tracker.deliver(id1, "first"));
    try std.testing.expectEqualStrings("first", usr1.last_payload);
    try std.testing.expectEqualStrings("second", usr2.last_payload);
}

test "RequestTracker: timeout sweep" {
    var tracker = RequestTracker.init(std.testing.allocator);
    defer tracker.deinit();

    var u: TestUser = .{};
    var cb: u8 = 0;
    // 1 ms timeout — definitely expired by the time we sweep.
    _ = try tracker.register(@ptrCast(&u), @ptrCast(&cb), testTrampoline, 1);
    vigil_api.sleep(5 * std.time.ns_per_ms);
    const swept = tracker.sweepExpired();
    try std.testing.expectEqual(@as(usize, 1), swept);
    try std.testing.expectEqual(@as(usize, 0), tracker.pendingCount());
}

test "RequestTracker: no timeout means no sweep" {
    var tracker = RequestTracker.init(std.testing.allocator);
    defer tracker.deinit();

    var u: TestUser = .{};
    var cb: u8 = 0;
    _ = try tracker.register(@ptrCast(&u), @ptrCast(&cb), testTrampoline, null);
    vigil_api.sleep(2 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 0), tracker.sweepExpired());
    try std.testing.expectEqual(@as(usize, 1), tracker.pendingCount());
}
