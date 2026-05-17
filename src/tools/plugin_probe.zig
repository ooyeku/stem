//! Stand-alone harness for debugging plugin init crashes.
//!
//! Builds a minimal PluginContext, dlopens a plugin, calls `init`, prints
//! whatever happens. Lets us localize plugin segfaults without booting
//! vaxis / the full editor.
//!
//! Build separately via `zig build plugin-probe` then run with a path:
//!   ./zig-out/bin/plugin-probe ~/.stem/plugins/libgit.dylib

const std = @import("std");
const vigil = @import("vigil");
const stem = @import("stem");

const interface = stem.interface;
const context = stem.context;
const crash_isolation = stem.crash_isolation;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    _ = io;

    // In Zig 0.16, env-var derived argv comes from `std.process.Init` or
    // similar; for the probe a fixed argv via env is simplest.
    const c_getenv = struct {
        extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
    };
    const raw = c_getenv.getenv("STEM_PROBE_PATH") orelse {
        std.debug.print("usage: STEM_PROBE_PATH=<path/to/libfoo.dylib> plugin-probe\n", .{});
        return;
    };
    const path = std.mem.span(raw);
    std.debug.print("probe: opening {s}\n", .{path});

    var lib = std.DynLib.open(path) catch |err| {
        std.debug.print("probe: dlopen failed: {}\n", .{err});
        return;
    };
    defer lib.close();

    const plugin_iface = lib.lookup(*const interface.PluginInterface, "plugin_entry") orelse {
        std.debug.print("probe: missing plugin_entry symbol\n", .{});
        return;
    };

    std.debug.print(
        "probe: plugin version={d} name={s} init?={}\n",
        .{ plugin_iface.version, std.mem.span(plugin_iface.name), plugin_iface.init != null },
    );
    std.debug.print(
        "probe: stem sees sizeof(PluginContext)={d}\n",
        .{@sizeOf(context.PluginContext)},
    );

    if (plugin_iface.init) |init_fn| {
        const inbox = try vigil.inbox(allocator);
        defer inbox.close();
        const core_inbox = try vigil.inbox(allocator);
        defer core_inbox.close();
        const ui_inbox = try vigil.inbox(allocator);
        defer ui_inbox.close();

        var ctx = context.PluginContext.init(allocator, "probe", inbox, core_inbox, ui_inbox, allocator);
        defer ctx.deinit();

        std.debug.print("probe: ctx@{*}\n", .{&ctx});
        std.debug.print("probe: ctx.allocator.vtable={*} ptr={*}\n", .{ ctx.allocator.vtable, ctx.allocator.ptr });
        std.debug.print("probe: ctx.to_core={*}\n", .{ctx.to_core});

        const opaque_ctx: *anyopaque = @ptrCast(&ctx);
        std.debug.print("probe: about to call init_fn(opaque_ctx={*})\n", .{opaque_ctx});

        // Replicate stem's worker-thread setup: install crash isolation
        // signal handler and call init via the same runIsolated wrapper.
        const installed = crash_isolation.install();
        std.debug.print("probe: crash_isolation.install -> {}\n", .{installed});

        const InitCall = struct {
            fn run(call_ctx: *anyopaque, fn_ptr: *const fn (*anyopaque) i32, rc_out: *i32) void {
                rc_out.* = fn_ptr(call_ctx);
            }
        };
        var rc: i32 = 0;
        const res = crash_isolation.runIsolated(.{ opaque_ctx, init_fn, &rc }, InitCall.run);
        std.debug.print("probe: runIsolated -> {} (rc={d}, lastSignal={d})\n", .{ res, rc, crash_isolation.lastCrashSignal() });
    }
}
