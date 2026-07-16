const std = @import("std");
const vigil = @import("vigil");

pub const raw = vigil;

pub const Runtime = vigil.Runtime;
pub const RuntimeOptions = vigil.RuntimeOptions;
pub const Inbox = vigil.Inbox;
pub const Message = vigil.Message;
pub const MessagePriority = vigil.MessagePriority;
pub const PublishResult = vigil.PublishResult;
pub const PubSubBroker = vigil.pubsub.PubSubBroker;
pub const Subscriber = vigil.pubsub.Subscriber;
pub const Supervisor = vigil.Supervisor;
pub const Mutex = vigil.compat.Mutex;
pub const TimerService = vigil.TimerService;
pub const DeadLetterNotice = vigil.DeadLetterNotice;
pub const DeadLetterSnapshot = vigil.DeadLetterSnapshot;
pub const CircuitBreaker = vigil.CircuitBreaker;
pub const CircuitBreakerConfig = vigil.CircuitBreakerConfig;
pub const BackoffPolicy = vigil.BackoffPolicy;
pub const RetryPolicy = vigil.RetryPolicy;
pub const executePolicy = vigil.executePolicy;

/// Deterministic test doubles (SimulatedClock, fillInbox, drainInbox, ...).
pub const testing = vigil.testing;

pub const ApiSurface = enum {
    runtime,
    message,
    pubsub,
    supervisor,
    telemetry,
    compatibility,
    unknown,
};

pub fn runtime(allocator: std.mem.Allocator, options: RuntimeOptions) !Runtime {
    return vigil.runtime(allocator, options);
}

/// Editor inbox capacity. Matches the pre-2.3.0 default; the MessageBus
/// layers its own per-class watermarks and rate limits below this.
const editor_inbox_capacity: usize = 100;

pub fn createInbox(runtime_ref: *Runtime) !*Inbox {
    // `.balanced` keeps the priority queues the MessageBus class taxonomy
    // depends on and dead-letter retention, but drops the 30s default TTL:
    // stem's threads drain quickly, and a TTL would silently expire messages
    // queued behind a slow render. With no TTLs, receives skip expiry
    // bookkeeping entirely.
    //
    // `.throughput` was evaluated for a dedicated render lane and rejected:
    // each editor thread blocks on ONE inbox (Vigil has no multi-inbox
    // select), so renders must share the UI inbox — and that inbox needs
    // priority queues so a critical `.quit` overtakes queued frames.
    return runtime_ref.inboxWithProfile(.balanced, editor_inbox_capacity);
}

/// The runtime-owned timer service (one scheduler thread for all timers).
pub fn timerService(runtime_ref: *Runtime) !*TimerService {
    return runtime_ref.timers();
}

pub fn standaloneInboxForTest(allocator: std.mem.Allocator) !*Inbox {
    return vigil.inbox(allocator);
}

pub fn sleep(ns: u64) void {
    vigil.compat.sleep(ns);
}

pub fn milliTimestamp() i64 {
    return vigil.compat.milliTimestamp();
}

pub fn vigilVersionMajor() u32 {
    return vigil.getVersion().major;
}

pub fn hasRuntimeApi() bool {
    return @hasDecl(vigil, "Runtime") and @hasDecl(vigil, "runtime");
}

pub fn hasRemovedMailboxApi() bool {
    return @hasDecl(vigil, "createMailbox") or @hasDecl(vigil, "global_registry");
}

/// Batched front-end for a blocking receive loop.
///
/// `next()` behaves like `Inbox.recv()` — blocks when the inbox is empty,
/// returns messages in priority order — but under bursts it pulls up to
/// `batch_size` messages with one mailbox lock and hands them out from a
/// local buffer, instead of paying a lock per message. Call `deinit()` when
/// leaving the loop so messages still sitting in the buffer are released.
///
/// Not thread-safe; one receiver per consuming thread.
pub const BatchReceiver = struct {
    pub const batch_size = 16;

    inbox: *Inbox,
    buffer: [batch_size]Message = undefined,
    count: usize = 0,
    index: usize = 0,

    pub fn init(inbox: *Inbox) BatchReceiver {
        return .{ .inbox = inbox };
    }

    /// Return the next message, blocking when none is queued. The caller
    /// owns the returned message and must `deinit()` it.
    pub fn next(self: *BatchReceiver) !Message {
        if (self.index < self.count) {
            const msg = self.buffer[self.index];
            self.index += 1;
            return msg;
        }
        self.count = 0;
        self.index = 0;
        const n = try self.inbox.recvBatch(&self.buffer);
        if (n == 0) {
            // Empty inbox: park on the condition until a send arrives.
            return self.inbox.recv();
        }
        self.count = n;
        self.index = 1;
        return self.buffer[0];
    }

    /// Release messages that were batched in but never handed out.
    pub fn deinit(self: *BatchReceiver) void {
        while (self.index < self.count) : (self.index += 1) {
            self.buffer[self.index].deinit();
        }
        self.count = 0;
    }
};

pub fn classify(name: []const u8) ApiSurface {
    if (std.mem.eql(u8, name, "runtime") or std.mem.eql(u8, name, "inbox")) return .runtime;
    if (std.mem.eql(u8, name, "message") or std.mem.eql(u8, name, "priority")) return .message;
    if (std.mem.eql(u8, name, "pubsub") or std.mem.eql(u8, name, "topic")) return .pubsub;
    if (std.mem.eql(u8, name, "supervisor") or std.mem.eql(u8, name, "restart")) return .supervisor;
    if (std.mem.eql(u8, name, "telemetry") or std.mem.eql(u8, name, "metric")) return .telemetry;
    if (std.mem.eql(u8, name, "mutex") or std.mem.eql(u8, name, "sleep") or std.mem.eql(u8, name, "timestamp")) return .compatibility;
    return .unknown;
}

test "Vigil adapter documents the v2 surface Stem uses" {
    try std.testing.expectEqual(@as(u32, 2), vigilVersionMajor());
    try std.testing.expect(hasRuntimeApi());
    try std.testing.expect(!hasRemovedMailboxApi());
    try std.testing.expect(@hasDecl(vigil, "TimerService"));
    try std.testing.expect(@hasDecl(vigil, "RuntimeProfile"));
    try std.testing.expectEqual(ApiSurface.runtime, classify("runtime"));
    try std.testing.expectEqual(ApiSurface.compatibility, classify("mutex"));
}

test "BatchReceiver hands out batched sends in order" {
    const a = std.testing.allocator;
    const ib = try standaloneInboxForTest(a);
    defer ib.close();

    _ = try ib.sendBatch(&.{ "a", "b", "c" });

    var receiver = BatchReceiver.init(ib);
    defer receiver.deinit();
    for ([_][]const u8{ "a", "b", "c" }) |expected| {
        var msg = try receiver.next();
        defer msg.deinit();
        try std.testing.expectEqualStrings(expected, msg.payload.?);
    }
}

test "BatchReceiver deinit releases messages left in its buffer" {
    const a = std.testing.allocator;
    const ib = try standaloneInboxForTest(a);
    defer ib.close();

    _ = try ib.sendBatch(&.{ "a", "b", "c" });

    // One next() batches all three; the leak check verifies deinit()
    // releases the two never handed out.
    var receiver = BatchReceiver.init(ib);
    defer receiver.deinit();
    var msg = try receiver.next();
    defer msg.deinit();
    try std.testing.expectEqualStrings("a", msg.payload.?);
}

test "SimulatedTimerService fires intervals deterministically" {
    // Documents the deterministic-timer pattern for stem code that hangs
    // periodic work off the Vigil timer service (see main.zig heartbeat).
    const Counter = struct {
        var fired: u32 = 0;
        fn tick() void {
            fired += 1;
        }
    };
    Counter.fired = 0;

    var clock = testing.SimulatedClock.init(0);
    var timers = testing.SimulatedTimerService.init(std.testing.allocator, &clock);
    defer timers.deinit();

    const id = try timers.setInterval(100, Counter.tick);
    try std.testing.expectEqual(@as(usize, 3), timers.advance(350));
    try std.testing.expectEqual(@as(u32, 3), Counter.fired);
    try std.testing.expect(timers.cancel(id));
    try std.testing.expectEqual(@as(usize, 0), timers.advance(1000));
}
