# Vigil Self-Healing Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add manual self-healing recommendations and quiet watchdog toasts backed by Stem's Vigil/runtime health snapshots.

**Architecture:** Create `src/kernel/runtime_watchdog.zig` as a value-only module that turns primitive health counts into recommendations and transition-based toasts. Wire `Core` to poll snapshots periodically on tick, and wire `SystemCommands` to render the shared recommendations in Control Center plus a new `[HEAL]` buffer.

**Tech Stack:** Zig 0.16, Stem `Core`, `SystemCommands`, `CommandRegistry`, Vigil telemetry bridge, existing job/LSP/plugin/index health snapshots.

---

### Task 1: Runtime Watchdog Recommendation Module

**Files:**
- Create: `src/kernel/runtime_watchdog.zig`
- Modify: `src/root.zig`

- [x] **Step 1: Write the failing tests**

Create `src/kernel/runtime_watchdog.zig` with tests for:

```zig
test "recommendations are empty for healthy input" {
    var list = std.ArrayListUnmanaged(HealingRecommendation).empty;
    defer list.deinit(std.testing.allocator);

    try appendRecommendations(.{}, &list, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), list.items.len);
}

test "recommendations include lsp plugin bus job index actions" {
    var list = std.ArrayListUnmanaged(HealingRecommendation).empty;
    defer list.deinit(std.testing.allocator);

    try appendRecommendations(.{
        .lsp_unhealthy_servers = 1,
        .plugin_crashes = 1,
        .plugin_pending_restarts = 1,
        .bus_drops_full = 1,
        .failed_jobs = 1,
        .index_at_capacity = true,
        .has_last_task = true,
    }, &list, std.testing.allocator);

    try expectCommand(&list, "lsp.status");
    try expectCommand(&list, "plugin.inspect");
    try expectCommand(&list, "stats.show");
    try expectCommand(&list, "job.list");
    try expectCommand(&list, "project.brain");
    try expectAlternate(&list, "task.rerun_last");
}

test "watchdog emits only on health worsening and throttles repeats" {
    var watcher = RuntimeWatchdog{};

    try std.testing.expect(watcher.observe(.{}, 1000) == null);
    const first = watcher.observe(.{ .lsp_unhealthy_servers = 1 }, 2000) orelse return error.MissingToast;
    try std.testing.expectEqual(ToastKey.lsp_unhealthy, first.key);
    try std.testing.expect(watcher.observe(.{}, 2500) == null);
    try std.testing.expect(watcher.observe(.{ .lsp_unhealthy_servers = 1 }, 3000) == null);
    const second = watcher.observe(.{ .lsp_unhealthy_servers = 1 }, 8000) orelse return error.MissingToast;
    try std.testing.expectEqual(ToastKey.lsp_unhealthy, second.key);
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `zig build test`

Expected: fail because `HealingRecommendation`, `appendRecommendations`, and `RuntimeWatchdog` are not defined.

- [x] **Step 3: Implement the module**

Define:

```zig
pub const Severity = enum { info, warning, err };

pub const HealthInput = struct {
    lsp_unhealthy_servers: usize = 0,
    plugin_crashes: u64 = 0,
    plugin_pending_restarts: usize = 0,
    bus_drops_full: u64 = 0,
    bus_drops_backpressure: u64 = 0,
    bus_drops_rate_limited: u64 = 0,
    failed_jobs: usize = 0,
    index_at_capacity: bool = false,
    has_last_task: bool = false,
};

pub const HealingRecommendation = struct {
    severity: Severity,
    title: []const u8,
    detail: []const u8,
    command: []const u8,
    alternate_command: ?[]const u8 = null,
};

pub const ToastKey = enum {
    lsp_unhealthy,
    plugin_crash,
    plugin_restart,
    bus_drops,
    job_failed,
    index_capacity,
};

pub const WatchdogToast = struct {
    key: ToastKey,
    severity: Severity,
    message: []const u8,
};

pub const RuntimeWatchdog = struct {
    previous: ?HealthInput = null,
    last_toast_key: ?ToastKey = null,
    last_toast_ms: i64 = 0,
    throttle_ms: i64 = 5000,

    pub fn observe(self: *RuntimeWatchdog, input: HealthInput, now_ms: i64) ?WatchdogToast;
};
```

Add `appendRecommendations(input, out, allocator)` with constant-string recommendations, and test helpers `expectCommand` / `expectAlternate`.

Import the module in `src/root.zig`:

```zig
_ = @import("kernel/runtime_watchdog.zig");
```

- [x] **Step 4: Run test to verify it passes**

Run: `zig build test`

Expected: pass for runtime watchdog tests.

### Task 2: Heal Buffer And Control Center Recommendations

**Files:**
- Modify: `src/kernel/commands/system_commands.zig`
- Modify: `src/kernel/core.zig`

- [x] **Step 1: Write the failing tests**

Add tests in `system_commands.zig` for a pure helper:

```zig
test "healing recommendations render command names" {
    const runtime_watchdog = @import("../runtime_watchdog.zig");
    var list = std.ArrayListUnmanaged(runtime_watchdog.HealingRecommendation).empty;
    defer list.deinit(std.testing.allocator);
    try runtime_watchdog.appendRecommendations(.{
        .lsp_unhealthy_servers = 1,
        .failed_jobs = 1,
        .has_last_task = true,
    }, &list, std.testing.allocator);

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try SystemCommands.writeHealingRecommendations(&aw.writer, list.items);
    const text = aw.written();

    try std.testing.expect(std.mem.indexOf(u8, text, "lsp.status") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "job.list") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "task.rerun_last") != null);
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `zig build test`

Expected: fail because `SystemCommands.writeHealingRecommendations` is missing.

- [x] **Step 3: Implement rendering and command registration**

Add:

```zig
const runtime_watchdog = @import("../runtime_watchdog.zig");
```

Add public command:

```zig
pub fn cmdStemHeal(core: anytype) anyerror!void {
    const body = try renderHealingBuffer(core);
    defer core.allocator.free(body);
    try core.openVirtualBuffer("[HEAL]", body);
    core.mode = .view;
    try core.sendUpdate();
}
```

Add `writeHealingRecommendations(w, recommendations)` that renders `## Recommended Actions` and a command table.

Add `renderHealingBuffer(core)` that builds a `runtime_watchdog.HealthInput` from current snapshots, gathers recommendations, writes `[HEAL]`, and includes recent runtime context.

In `Core.registerCommands`, add:

```zig
try R.register("stem.heal", "Stem: Heal Runtime", "Open recovery actions for runtime health issues", Wrap(SystemCommands.cmdStemHeal).run, null);
```

In `renderControlCenterBuffer`, replace the inline recommended action block with the shared helper.

- [x] **Step 4: Run test to verify it passes**

Run: `zig build test`

Expected: pass.

### Task 3: Watchdog Toasts On Core Tick

**Files:**
- Modify: `src/kernel/core.zig`

- [x] **Step 1: Write the failing test**

Rely on `runtime_watchdog.zig` transition tests from Task 1 for core-free behavior. No Core integration unit test is added because constructing full `Core` is heavyweight and the tick path composes existing snapshot APIs.

- [x] **Step 2: Implement Core fields and polling**

Import:

```zig
const telemetry = @import("../services/telemetry.zig");
const runtime_watchdog = @import("runtime_watchdog.zig");
const RuntimeWatchdog = runtime_watchdog.RuntimeWatchdog;
```

Add fields:

```zig
runtime_watchdog: RuntimeWatchdog = .{},
last_watchdog_check_ms: i64 = 0,
watchdog_check_interval_ms: i64 = 2000,
```

Add `maybeWatchRuntime()` that:

1. returns early until `watchdog_check_interval_ms` elapsed,
2. builds `runtime_watchdog.HealthInput` from telemetry, plugin, LSP, job, and index snapshots,
3. calls `self.runtime_watchdog.observe(input, now_ms)`,
4. maps toast severity to `protocol.StatusLevel`,
5. calls `setStatusLiteralLeveled(level, toast.message, 3500)`.

Call `maybeWatchRuntime()` from the `.tick` branch after `maybeTimeoutLeaderChord()`.

- [x] **Step 3: Run test to verify it passes**

Run: `zig build test`

Expected: pass.

### Task 4: Final Polish And Commit

**Files:**
- Modify: `README.md`
- Modify: touched Zig files
- Modify: this plan file

- [x] **Step 1: Update README**

Mention `stem.heal` near Control Center:

```markdown
- Stem Heal (`stem.heal`) for Vigil-backed runtime recovery recommendations and watchdog guidance
```

- [x] **Step 2: Format**

Run:

```bash
zig fmt src/root.zig src/kernel/core.zig src/kernel/runtime_watchdog.zig src/kernel/commands/system_commands.zig
```

- [x] **Step 3: Test**

Run:

```bash
zig build test
```

Expected: pass.

- [x] **Step 4: Inspect diff**

Run:

```bash
git diff --stat
git diff --name-only
git status --short
```

Confirm unrelated existing changes remain unstaged unless explicitly part of this feature.

- [x] **Step 5: Commit**

Stage only this feature:

```bash
git add README.md docs/superpowers/plans/2026-06-21-vigil-self-healing-actions.md src/root.zig src/kernel/core.zig src/kernel/runtime_watchdog.zig src/kernel/commands/system_commands.zig
git commit -m "feat: add vigil self healing actions"
```
