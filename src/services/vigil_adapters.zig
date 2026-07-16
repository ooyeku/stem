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

pub fn createInbox(runtime_ref: *Runtime) !*Inbox {
    return runtime_ref.inbox(.{});
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
    try std.testing.expectEqual(ApiSurface.runtime, classify("runtime"));
    try std.testing.expectEqual(ApiSurface.compatibility, classify("mutex"));
}
