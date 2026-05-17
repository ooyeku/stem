//! Plugin probe (v3 ABI).
//!
//! Loads a plugin .dylib, looks up `plugin_entry`, and prints its
//! capabilities and ABI version. Used for ad-hoc verification that a
//! plugin was built against the current host. Does NOT call `activate` —
//! that path requires the host's full handle/inbox plumbing, which the
//! editor itself sets up.

const std = @import("std");
const stem = @import("stem");

const interface = stem.interface;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    _ = allocator;

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

    const iface = lib.lookup(*const interface.PluginInterface, "plugin_entry") orelse {
        std.debug.print("probe: missing plugin_entry symbol\n", .{});
        return;
    };

    std.debug.print(
        \\probe: version={d} name={s}
        \\probe: activate?={} deactivate?={} handle_message?={}
        \\probe: capabilities: commands={} lsp={} syntax={} ui={} files={}
        \\
    , .{
        iface.version,
        std.mem.span(iface.name),
        iface.activate != null,
        iface.deactivate != null,
        iface.handle_message != null,
        iface.capabilities.provides_commands,
        iface.capabilities.provides_lsp,
        iface.capabilities.provides_syntax,
        iface.capabilities.extends_ui,
        iface.capabilities.handles_files,
    });

    if (iface.version != stem.ABI_VERSION) {
        std.debug.print("probe: WARNING — plugin ABI v{d} does not match stem ABI v{d}\n", .{ iface.version, stem.ABI_VERSION });
    } else {
        std.debug.print("probe: ABI versions match — plugin should load cleanly\n", .{});
    }
}
