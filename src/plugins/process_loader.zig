//! Out-of-process plugin loader (Phase 1 scaffolding).
//!
//! Plugins that need OS capabilities (the git plugin's `spawn git`,
//! a future "fetch from GitHub" plugin's network access) run as their
//! own executable and speak JSON-RPC 2.0 over stdio. Stem reuses the
//! LSP supervisor pattern: spawn child, pipe stdin/stdout, supervise
//! restarts, deliver notifications.
//!
//! Same wire schema as WASM plugins (Phase 2). The plugin author picks
//! deployment mode via `runtime = "exec"` in `plugin.toml`.
//!
//! Status: stub. Full implementation lands with Phase 1.

const std = @import("std");
const vigil = @import("vigil");
const schema = @import("schema.zig");
const manifest = @import("manifest.zig");

pub const ProcessPlugin = struct {
    name: []const u8,
    /// Path to the executable.
    entry: []const u8,
    /// Spawned child (set by `start`).
    child: ?std.process.Child = null,
    /// Inbox routing replies back to the per-plugin worker.
    inbox: ?*vigil.Inbox = null,

    pub fn start(
        self: *ProcessPlugin,
        allocator: std.mem.Allocator,
        io: std.Io,
    ) !void {
        _ = self;
        _ = allocator;
        _ = io;
        // TODO(phase-1):
        //   1. std.process.Child.init(&[_][]const u8{self.entry}, ...)
        //   2. wire stdin / stdout / stderr to pipes
        //   3. spawn two worker threads: one reading JSON-RPC frames
        //      from child stdout → dispatching into stem; one writing
        //      outgoing requests to child stdin
        //   4. handshake: send `initialize` request with our SCHEMA_VERSION;
        //      wait for plugin's `initialized` reply.
        //   5. on crash, the existing PluginManager.tickRestarts policy
        //      governs restart cadence (we just need to plumb a callback).
        return error.NotYetImplemented;
    }

    pub fn sendNotification(
        self: *ProcessPlugin,
        method: schema.HostNotification,
        params: std.json.Value,
    ) !void {
        _ = self;
        _ = method;
        _ = params;
        return error.NotYetImplemented;
    }

    pub fn sendRequest(
        self: *ProcessPlugin,
        allocator: std.mem.Allocator,
        method: schema.HostMethod,
        params: std.json.Value,
    ) !u64 {
        _ = self;
        _ = allocator;
        _ = method;
        _ = params;
        return error.NotYetImplemented;
    }

    pub fn stop(self: *ProcessPlugin, io: std.Io) void {
        _ = self;
        _ = io;
        // TODO(phase-1): send `shutdown` notification, give the child
        // a grace period, then SIGTERM, then SIGKILL.
    }
};

// Hook into the rest of the test runner so build won't warn on unused module.
test "process_loader: stub returns NotYetImplemented" {
    var pp: ProcessPlugin = .{ .name = "test", .entry = "/usr/bin/false" };
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try std.testing.expectError(error.NotYetImplemented, pp.start(std.testing.allocator, io));
}

comptime {
    _ = manifest;
    _ = schema;
}
