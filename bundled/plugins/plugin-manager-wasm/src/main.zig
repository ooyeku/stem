//! Plugin manager (wasm runtime).
//!
//! Seven commands:
//!
//!   - `plugin-manager.stats`     — render the structured host
//!                                   plugin dashboard in a buffer.
//!   - `plugin-manager.json`      — open the dashboard JSON payload.
//!   - `plugin-manager.permissions` — focus the dashboard on grants
//!                                     and capability denials.
//!   - `plugin-manager.storage`   — check persistent storage health.
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
const stem = @import("stem");
const list_parser = @import("list_parser.zig");

var scratch: [256 * 1024]u8 = undefined;
var report_buf: [256 * 1024]u8 = undefined;
var report_len: usize = 0;

const CMD_STATS = "plugin-manager.stats";
const CMD_JSON = "plugin-manager.json";
const CMD_PERMISSIONS = "plugin-manager.permissions";
const CMD_STORAGE = "plugin-manager.storage";
const CMD_RELOAD = "plugin-manager.reload_all";
const CMD_LOAD = "plugin.load";
const CMD_UNLOAD = "plugin.unload";

const COMMANDS = [_]stem.Command{
    .{ .id = CMD_STATS, .title = "[Plugin Manager] Dashboard", .description = "Display plugin health, commands, permissions, widgets, and denials" },
    .{ .id = CMD_JSON, .title = "[Plugin Manager] Raw JSON", .description = "Open the structured plugin dashboard JSON" },
    .{ .id = CMD_PERMISSIONS, .title = "[Plugin Manager] Permissions", .description = "Review permission grants and capability denials" },
    .{ .id = CMD_STORAGE, .title = "[Plugin Manager] Storage", .description = "Check plugin-manager persistent storage health" },
    .{ .id = CMD_RELOAD, .title = "[Plugin Manager] Reload All", .description = "Unload and reload every installed plugin" },
    .{ .id = CMD_LOAD, .title = "[Plugin] Load", .description = "Reminder: install plugins via `stem plugin install <path>`" },
    .{ .id = CMD_UNLOAD, .title = "[Plugin] Unload", .description = "Reminder: remove plugins via `stem plugin remove <name>`" },
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
    stem.registerCommands(COMMANDS);
    stem.log(.info, "plugin_manager plugin (wasm): ready");
}

export fn handle_command(id_ptr: [*]const u8, id_len: i32) void {
    const id = stem.fromRaw(id_ptr, id_len);

    if (std.mem.eql(u8, id, CMD_STATS)) {
        runStats();
        return;
    }
    if (std.mem.eql(u8, id, CMD_JSON)) {
        runJson();
        return;
    }
    if (std.mem.eql(u8, id, CMD_PERMISSIONS)) {
        runPermissions();
        return;
    }
    if (std.mem.eql(u8, id, CMD_STORAGE)) {
        runStorage();
        return;
    }
    if (std.mem.eql(u8, id, CMD_RELOAD)) {
        runReloadAll();
        return;
    }
    if (std.mem.eql(u8, id, CMD_LOAD)) {
        stem.openBuffer("[Plugin Load]", LOAD_HINT);
        return;
    }
    if (std.mem.eql(u8, id, CMD_UNLOAD)) {
        stem.openBuffer("[Plugin Unload]", UNLOAD_HINT);
        return;
    }
}

fn runStats() void {
    const written = stem.pluginDashboardReport(&scratch);
    if (written <= 0) {
        const fallback = "Plugin dashboard unavailable from host. Run `stem plugin list` from your shell to see installed plugins.";
        stem.openBuffer("[Plugin Manager]", fallback);
        return;
    }

    const opens = incrementDashboardOpenCount();
    report_len = 0;
    appendReport("# Plugin Manager v2\n\n");
    appendReport("Actions: Dashboard, Permissions, Storage, Raw JSON, Reload All.\n\n");
    appendReport(scratch[0..@intCast(written)]);
    appendReport("\n---\n");
    var tail: [96]u8 = undefined;
    const tail_msg = std.fmt.bufPrint(&tail, "Dashboard opened {d} time(s) by plugin_manager.\n", .{opens}) catch "";
    appendReport(tail_msg);

    stem.openBuffer("[Plugin Manager]", report_buf[0..report_len]);
}

fn incrementDashboardOpenCount() u32 {
    const current = stem.storageReadU32("dashboard.opens", 0);
    const next = current +| 1;
    stem.storageWriteU32("dashboard.opens", next);
    return next;
}

fn runJson() void {
    const written = stem.pluginDashboardJson(&scratch);
    if (written <= 0) {
        const fallback = "{}\n";
        stem.openBuffer("[Plugin JSON]", fallback);
        return;
    }
    stem.openBuffer("[Plugin JSON]", scratch[0..@intCast(written)]);
}

fn runPermissions() void {
    const written = stem.pluginDashboardReport(&scratch);
    report_len = 0;
    appendReport("# Plugin Permissions\n\n");
    appendReport("This view focuses on manifest grants and capability denials.\n\n");
    if (written > 0) {
        appendReport(scratch[0..@intCast(written)]);
    } else {
        appendReport("Permission dashboard unavailable.\n");
    }
    stem.openBuffer("[Plugin Permissions]", report_buf[0..report_len]);
}

fn runStorage() void {
    report_len = 0;
    const storage_opens = stem.storageReadU32("storage.opens", 0) +| 1;
    stem.storageWriteU32("storage.opens", storage_opens);

    appendReport("# Plugin Storage\n\n");
    appendReport("Persistent plugin storage is scoped by plugin id and key.\n\n");
    appendReport("plugin_manager storage:\n");
    appendReportInt("dashboard.opens", stem.storageReadU32("dashboard.opens", 0));
    appendReportInt("storage.opens", storage_opens);
    appendReport("\nUse `stem cache status` from your shell to inspect cache sizes.\n");
    stem.openBuffer("[Plugin Storage]", report_buf[0..report_len]);
}

/// Walk `stem plugin list`, pull out each plugin name, then unload +
/// reload it. Failures are recorded but don't stop the sweep.
fn runReloadAll() void {
    const written = stem.spawnCapture("stem plugin list", &scratch);
    if (written <= 0) {
        const msg = "reload_all: could not run `stem plugin list` (spawn permission missing or stem not on PATH).";
        stem.openBuffer("[Plugin Reload]", msg);
        return;
    }

    report_len = 0;
    appendReport("Reloading installed plugins...\n\n");

    var total: u32 = 0;
    var ok: u32 = 0;
    var failed: u32 = 0;

    var it = std.mem.splitScalar(u8, scratch[0..@intCast(written)], '\n');
    while (it.next()) |line| {
        const name = list_parser.parsePluginName(line) orelse continue;
        // Skip self — unloading ourselves mid-call would crash the host.
        if (std.mem.eql(u8, name, "plugin_manager")) {
            appendReport("  · plugin_manager (skipped — self)\n");
            continue;
        }
        total += 1;
        // Unload result is informational; many plugins may not be
        // running yet, in which case unload returns a non-zero error
        // code which we ignore.
        _ = stem.unloadPlugin(name);
        const load_rc = stem.loadPlugin(name);
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

    stem.openBuffer("[Plugin Reload]", report_buf[0..report_len]);
}

fn appendReport(s: []const u8) void {
    const remaining = report_buf.len - report_len;
    const n = @min(s.len, remaining);
    @memcpy(report_buf[report_len .. report_len + n], s[0..n]);
    report_len += n;
}

fn appendReportInt(label: []const u8, value: u32) void {
    var buf: [128]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "- {s}: {d}\n", .{ label, value }) catch return;
    appendReport(line);
}
