const std = @import("std");
const vigil = @import("vigil");
const interface = @import("interface.zig");
const context = @import("context.zig");

pub const Plugin = struct {
    id: []const u8,
    path: []const u8,

    lib: std.DynLib,

    interface: interface.PluginInterface,

    thread: ?std.Thread = null,
    inbox: ?*vigil.Inbox = null,
    ctx: ?*context.PluginContext = null,

    state: PluginState = .unloaded,
    load_time: i64 = 0,

    pub const PluginState = enum {
        unloaded,
        loading,
        loaded,
        running,
        unloading,
        failed,
    };

    pub fn deinit(self: *Plugin, allocator: std.mem.Allocator) void {
        if (self.state == .running) {
            self.state = .unloading;
        }

        if (self.inbox) |ib| {
            ib.close();
        }

        if (self.thread) |thread| {
            thread.join();
        }

        if (self.ctx) |c| {
            if (self.interface.deinit) |deinit_fn| {
                const opaque_ctx: *anyopaque = @ptrCast(c);
                deinit_fn(opaque_ctx);
            }
            c.deinit();
            allocator.destroy(c);
        }

        allocator.free(self.id);
        allocator.free(self.path);
        self.lib.close();
    }
};
