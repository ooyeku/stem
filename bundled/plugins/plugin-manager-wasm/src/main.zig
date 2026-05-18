//! Plugin manager (wasm runtime).
//!
//! Four commands:
//!
//!   - `plugin-manager.stats`     — render `stem plugin list` in a buffer.
//!   - `plugin-manager.reload_all` — unload + reload every installed plugin
//!                                   without restarting the editor.
//!   - `plugin.load`              — show CLI install hint (wasm has no
//!                                   string-prompt host import yet, so an
//!                                   interactive load flow isn't possible
//!                                   from inside a sandboxed plugin).
//!   - `plugin.unload`            — show CLI remove hint.
//!
//! `reload_all` walks the `stem plugin list` output, parses plugin
//! names out of indented entry lines, and calls `stem_unload_plugin` +
//! `stem_load_plugin` on each. It is intentionally idempotent: a
//! failed unload (e.g. plugin wasn't actually running) doesn't block
//! the subsequent load, and load failures are surfaced in the result
//! buffer rather than aborting the sweep.

const std = @import("std");

extern "env" fn stem_log(level: i32, msg_ptr: [*]const u8, msg_len: i32) void;
extern "env" fn stem_register_command(
    id_ptr: [*]const u8,
    id_len: i32,
    title_ptr: [*]const u8,
    title_len: i32,
    desc_ptr: [*]const u8,
    desc_len: i32,
) void;
extern "env" fn stem_open_buffer(
    name_ptr: [*]const u8,
    name_len: i32,
    content_ptr: [*]const u8,
    content_len: i32,
) void;
extern "env" fn stem_spawn_capture(
    cmd_ptr: [*]const u8,
    cmd_len: i32,
    out_ptr: [*]u8,
    out_max: i32,
) i32;
extern "env" fn stem_load_plugin(name_ptr: [*]const u8, name_len: i32) i32;
extern "env" fn stem_unload_plugin(name_ptr: [*]const u8, name_len: i32) i32;

var scratch: [64 * 1024]u8 = undefined;
var report_buf: [16 * 1024]u8 = undefined;
var report_len: usize = 0;

// Host-dispatch scratch region — see echo-wasm for the protocol.
var stem_scratch: [4096]u8 = undefined;
export fn __stem_scratch_addr() i32 {
    return @intCast(@intFromPtr(&stem_scratch));
}
export fn __stem_scratch_size() i32 {
    return @intCast(stem_scratch.len);
}

const CMD_STATS = "plugin-manager.stats";
const CMD_RELOAD = "plugin-manager.reload_all";
const CMD_LOAD = "plugin.load";
const CMD_UNLOAD = "plugin.unload";

const Cmd = struct { id: []const u8, title: []const u8, desc: []const u8 };
const COMMANDS = [_]Cmd{
    .{ .id = CMD_STATS, .title = "[Plugin Manager] Show Stats", .desc = "Display the installed plugin list" },
    .{ .id = CMD_RELOAD, .title = "[Plugin Manager] Reload All", .desc = "Unload and reload every installed plugin" },
    .{ .id = CMD_LOAD, .title = "[Plugin] Load", .desc = "Reminder: install plugins via `stem plugin install <path>`" },
    .{ .id = CMD_UNLOAD, .title = "[Plugin] Unload", .desc = "Reminder: remove plugins via `stem plugin remove <name>`" },
};

const LOAD_HINT =
    \\Plugin loading is now managed through the `stem plugin` CLI:
    \\
    \\    stem plugin install <path-to-plugin-dir>
    \\    stem plugin list
    \\    stem plugin remove <name>
    \\    stem plugin test <path>
    \\
    \\To pick up a freshly-installed plugin without restarting stem,
    \\run the `[Plugin Manager] Reload All` command.
;

const UNLOAD_HINT =
    \\Plugin removal:
    \\
    \\    stem plugin remove <name>
    \\
    \\Then run `[Plugin Manager] Reload All` to drop the running
    \\instance, or restart stem.
;

export fn activate() void {
    inline for (COMMANDS) |c| {
        stem_register_command(
            c.id.ptr,
            c.id.len,
            c.title.ptr,
            c.title.len,
            c.desc.ptr,
            c.desc.len,
        );
    }
    const ready = "plugin_manager plugin (wasm): ready";
    stem_log(1, ready.ptr, ready.len);
}

export fn handle_command(id_ptr: [*]const u8, id_len: i32) void {
    const id = id_ptr[0..@intCast(id_len)];

    if (std.mem.eql(u8, id, CMD_STATS)) {
        runStats();
        return;
    }
    if (std.mem.eql(u8, id, CMD_RELOAD)) {
        runReloadAll();
        return;
    }
    if (std.mem.eql(u8, id, CMD_LOAD)) {
        stem_open_buffer(
            "[Plugin Load]".ptr,
            "[Plugin Load]".len,
            LOAD_HINT.ptr,
            LOAD_HINT.len,
        );
        return;
    }
    if (std.mem.eql(u8, id, CMD_UNLOAD)) {
        stem_open_buffer(
            "[Plugin Unload]".ptr,
            "[Plugin Unload]".len,
            UNLOAD_HINT.ptr,
            UNLOAD_HINT.len,
        );
        return;
    }
}

fn runStats() void {
    const written = stem_spawn_capture(
        "stem plugin list".ptr,
        "stem plugin list".len,
        &scratch,
        @intCast(scratch.len),
    );
    if (written <= 0) {
        const fallback = "Run `stem plugin list` from your shell to see installed plugins.";
        stem_open_buffer(
            "[Plugin Manager]".ptr,
            "[Plugin Manager]".len,
            fallback.ptr,
            @intCast(fallback.len),
        );
        return;
    }
    stem_open_buffer(
        "[Plugin Manager]".ptr,
        "[Plugin Manager]".len,
        &scratch,
        written,
    );
}

/// Walk `stem plugin list`, pull out each plugin name, then unload +
/// reload it. Failures are recorded but don't stop the sweep.
fn runReloadAll() void {
    const written = stem_spawn_capture(
        "stem plugin list".ptr,
        "stem plugin list".len,
        &scratch,
        @intCast(scratch.len),
    );
    if (written <= 0) {
        const msg = "reload_all: could not run `stem plugin list` (spawn permission missing or stem not on PATH).";
        stem_open_buffer(
            "[Plugin Reload]".ptr,
            "[Plugin Reload]".len,
            msg.ptr,
            @intCast(msg.len),
        );
        return;
    }

    report_len = 0;
    appendReport("Reloading installed plugins...\n\n");

    var total: u32 = 0;
    var ok: u32 = 0;
    var failed: u32 = 0;

    var it = std.mem.splitScalar(u8, scratch[0..@intCast(written)], '\n');
    while (it.next()) |line| {
        const name = parsePluginName(line) orelse continue;
        // Skip self — unloading ourselves mid-call would crash the host.
        if (std.mem.eql(u8, name, "plugin_manager")) {
            appendReport("  · plugin_manager (skipped — self)\n");
            continue;
        }
        total += 1;
        // Unload result is informational; many plugins may not be
        // running yet, in which case unload returns a non-zero error
        // code which we ignore.
        _ = stem_unload_plugin(name.ptr, @intCast(name.len));
        const load_rc = stem_load_plugin(name.ptr, @intCast(name.len));
        if (load_rc == 0) {
            ok += 1;
            appendReport("  ✓ ");
            appendReport(name);
            appendReport("\n");
        } else {
            failed += 1;
            appendReport("  ✗ ");
            appendReport(name);
            appendReport(" (load failed)\n");
        }
    }

    var tail_buf: [128]u8 = undefined;
    const tail = std.fmt.bufPrint(
        &tail_buf,
        "\nReloaded {d}/{d}; {d} failed.\n",
        .{ ok, total, failed },
    ) catch "\n(done)\n";
    appendReport(tail);

    stem_open_buffer(
        "[Plugin Reload]".ptr,
        "[Plugin Reload]".len,
        &report_buf,
        @intCast(report_len),
    );
}

/// `stem plugin list` emits entry lines like:
///
///     "  echo-wasm                0.5.0  (wasm)"
///
/// Two leading spaces, then the plugin name (no whitespace), then
/// version + `(runtime)`. Description lines use four leading spaces
/// and don't have the `(runtime)` token, which is how we tell them
/// apart from entry lines.
fn parsePluginName(line: []const u8) ?[]const u8 {
    if (line.len < 3) return null;
    if (line[0] != ' ' or line[1] != ' ') return null;
    if (line[2] == ' ') return null; // description line (4-space indent)
    // Must look like an entry line — `(` somewhere on it for the
    // runtime tag.
    if (std.mem.indexOfScalar(u8, line, '(') == null) return null;
    const rest = line[2..];
    const end = std.mem.indexOfAny(u8, rest, " \t") orelse return null;
    if (end == 0) return null;
    return rest[0..end];
}

fn appendReport(s: []const u8) void {
    const remaining = report_buf.len - report_len;
    const n = @min(s.len, remaining);
    @memcpy(report_buf[report_len .. report_len + n], s[0..n]);
    report_len += n;
}
