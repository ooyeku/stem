# Command Palette Task MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add in-memory command recency, last-task rerun, and concise failed-task summaries.

**Architecture:** Create `command_history.zig` and `task_history.zig` as small owned helpers on `Core`. Keep command scoring in the existing registry by adding an optional score boost hook, and keep task execution in `SystemCommands` by refactoring the existing detected-task runner into a reusable starter.

**Tech Stack:** Zig 0.16, Stem kernel modules, existing `CommandRegistry`, `ProjectTask`, `JobManager`, and virtual buffer workflows.

---

### Task 1: Command History Helper

**Files:**
- Create: `src/kernel/command_history.zig`
- Modify: `src/root.zig`

- [x] **Step 1: Write the failing tests**

Create `src/kernel/command_history.zig` with tests first:

```zig
const std = @import("std");

test "command history records most recent first and deduplicates" {
    var history = CommandHistory.init(std.testing.allocator, 4);
    defer history.deinit();

    try history.record("file.open");
    try history.record("task.list");
    try history.record("file.open");

    try std.testing.expectEqual(@as(usize, 2), history.ids.items.len);
    try std.testing.expectEqualStrings("file.open", history.ids.items[0]);
    try std.testing.expectEqualStrings("task.list", history.ids.items[1]);
    try std.testing.expectEqual(@as(?usize, 0), history.rank("file.open"));
    try std.testing.expectEqual(@as(?usize, 1), history.rank("task.list"));
}

test "command history respects max entries" {
    var history = CommandHistory.init(std.testing.allocator, 2);
    defer history.deinit();

    try history.record("one");
    try history.record("two");
    try history.record("three");

    try std.testing.expectEqual(@as(usize, 2), history.ids.items.len);
    try std.testing.expectEqualStrings("three", history.ids.items[0]);
    try std.testing.expectEqualStrings("two", history.ids.items[1]);
    try std.testing.expectEqual(@as(?usize, null), history.rank("one"));
}

test "command history boost favors newer commands" {
    var history = CommandHistory.init(std.testing.allocator, 8);
    defer history.deinit();

    try history.record("older");
    try history.record("newer");

    try std.testing.expect(history.scoreBoost("newer") > history.scoreBoost("older"));
    try std.testing.expectEqual(@as(i64, 0), history.scoreBoost("missing"));
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `zig build test`

Expected: fail because `CommandHistory` is not defined.

- [x] **Step 3: Write minimal implementation**

Implement these exact public methods:

```zig
pub const CommandHistory = struct {
    allocator: std.mem.Allocator,
    max_entries: usize,
    ids: std.ArrayListUnmanaged([]u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, max_entries: usize) CommandHistory;
    pub fn deinit(self: *CommandHistory) void;
    pub fn record(self: *CommandHistory, id: []const u8) !void;
    pub fn rank(self: *const CommandHistory, id: []const u8) ?usize;
    pub fn scoreBoost(self: *const CommandHistory, id: []const u8) i64;
};
```

`record` removes an existing ID, inserts a fresh owned copy at index 0, and trims entries beyond `max_entries`.

Also import the module in `src/root.zig` test block:

```zig
_ = @import("kernel/command_history.zig");
```

- [x] **Step 4: Run test to verify it passes**

Run: `zig build test`

Expected: pass for command history tests.

### Task 2: Recency-Aware Command Search

**Files:**
- Modify: `src/kernel/command.zig`

- [x] **Step 1: Write the failing tests**

Add tests to `src/kernel/command.zig`:

```zig
test "CommandRegistry searchWithBoost ranks boosted empty-query commands first" {
    var registry = CommandRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const test_fn = struct {
        fn testFunc(ctx: *anyopaque, context: ?*const anyopaque) anyerror!void {
            _ = ctx;
            _ = context;
        }
    }.testFunc;

    try registry.register("alpha", "Alpha", "First", test_fn, null);
    try registry.register("beta", "Beta", "Second", test_fn, null);

    const Boost = struct {
        fn score(_: ?*const anyopaque, id: []const u8) i64 {
            return if (std.mem.eql(u8, id, "beta")) 25 else 0;
        }
    };

    var results = std.ArrayListUnmanaged(Command).empty;
    defer results.deinit(std.testing.allocator);
    try registry.searchWithBoost("", &results, std.testing.allocator, null, Boost.score);

    try std.testing.expectEqualStrings("beta", results.items[0].id);
}

test "CommandRegistry searchWithBoost applies small recency boost to matches" {
    var registry = CommandRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const test_fn = struct {
        fn testFunc(ctx: *anyopaque, context: ?*const anyopaque) anyerror!void {
            _ = ctx;
            _ = context;
        }
    }.testFunc;

    try registry.register("task.alpha", "Task Alpha", "Run alpha", test_fn, null);
    try registry.register("task.beta", "Task Beta", "Run beta", test_fn, null);

    const Boost = struct {
        fn score(_: ?*const anyopaque, id: []const u8) i64 {
            return if (std.mem.eql(u8, id, "task.beta")) 25 else 0;
        }
    };

    var results = std.ArrayListUnmanaged(Command).empty;
    defer results.deinit(std.testing.allocator);
    try registry.searchWithBoost("task", &results, std.testing.allocator, null, Boost.score);

    try std.testing.expectEqualStrings("task.beta", results.items[0].id);
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `zig build test`

Expected: fail because `searchWithBoost` does not exist.

- [x] **Step 3: Write minimal implementation**

Add:

```zig
pub const ScoreBoostFn = *const fn (ctx: ?*const anyopaque, id: []const u8) i64;

pub fn search(self: *CommandRegistry, query: []const u8, out_results: *std.ArrayListUnmanaged(Command), allocator: std.mem.Allocator) !void {
    try self.searchWithBoost(query, out_results, allocator, null, null);
}

pub fn searchWithBoost(
    self: *CommandRegistry,
    query: []const u8,
    out_results: *std.ArrayListUnmanaged(Command),
    allocator: std.mem.Allocator,
    boost_ctx: ?*const anyopaque,
    boost_fn: ?ScoreBoostFn,
) !void;
```

Inside `searchWithBoost`, move the existing `search` body into this function.
For every command that would have been appended to `matches`, compute
`const boost = if (boost_fn) |f| f(boost_ctx, cmd.id) else 0;` and store
`.score = final_score + boost`. The existing `search` function becomes a
wrapper that calls `searchWithBoost(query, out_results, allocator, null, null)`.

- [x] **Step 4: Run test to verify it passes**

Run: `zig build test`

Expected: pass.

### Task 3: Wire Command History Into Core And Palette Execution

**Files:**
- Modify: `src/kernel/core.zig`
- Modify: `src/kernel/input/command_palette.zig`

- [x] **Step 1: Write the failing test**

Add a small unit test to `src/kernel/command_history.zig` that proves the boost context can be called through a static adapter:

```zig
test "command history boost adapter returns history score" {
    var history = CommandHistory.init(std.testing.allocator, 8);
    defer history.deinit();
    try history.record("recent");

    try std.testing.expect(CommandHistory.scoreBoostAdapter(&history, "recent") > 0);
    try std.testing.expectEqual(@as(i64, 0), CommandHistory.scoreBoostAdapter(&history, "missing"));
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `zig build test`

Expected: fail because `scoreBoostAdapter` does not exist.

- [x] **Step 3: Implement wiring**

Add to `CommandHistory`:

```zig
pub fn scoreBoostAdapter(ctx: ?*const anyopaque, id: []const u8) i64 {
    const self: *const CommandHistory = @ptrCast(@alignCast(ctx.?));
    return self.scoreBoost(id);
}
```

In `Core`:

- import `CommandHistory`
- add `command_history: CommandHistory`
- initialize with `CommandHistory.init(allocator, 32)`
- deinit it
- change `updateCommandSearch` to call `self.command_registry.searchWithBoost(self.command_palette_input.items, &self.command_palette_results, self.allocator, &self.command_history, CommandHistory.scoreBoostAdapter)`

In `command_palette.handle`, before executing the selected command:

```zig
core.command_history.record(cmd.id) catch |err| {
    log.warn("failed to record command history for '{s}': {s}", .{ cmd.id, @errorName(err) });
};
```

- [x] **Step 4: Run test to verify it passes**

Run: `zig build test`

Expected: pass.

### Task 4: Task History Helper

**Files:**
- Create: `src/kernel/task_history.zig`
- Modify: `src/root.zig`

- [x] **Step 1: Write the failing tests**

Create tests in `src/kernel/task_history.zig`:

```zig
const std = @import("std");
const project_tasks = @import("project_tasks.zig");

test "task history records owned last task snapshot" {
    var history = TaskHistory.init(std.testing.allocator);
    defer history.deinit();

    const task = project_tasks.ProjectTask{
        .id = "zig.test",
        .label = "Zig: Test",
        .command = "zig build test",
        .kind = .@"test",
        .source = "build.zig",
        .priority = 11,
    };

    try history.record("/tmp/project", task);
    const last = history.last().?;

    try std.testing.expectEqualStrings("/tmp/project", last.root);
    try std.testing.expectEqualStrings("zig.test", last.task.id);
    try std.testing.expectEqualStrings("zig build test", last.task.command);
}

test "task history replacement frees old snapshot and stores new one" {
    var history = TaskHistory.init(std.testing.allocator);
    defer history.deinit();

    const first = project_tasks.ProjectTask{ .id = "one", .label = "One", .command = "echo one", .kind = .custom, .source = "test", .priority = 1 };
    const second = project_tasks.ProjectTask{ .id = "two", .label = "Two", .command = "echo two", .kind = .custom, .source = "test", .priority = 2 };

    try history.record("/tmp/one", first);
    try history.record("/tmp/two", second);

    const last = history.last().?;
    try std.testing.expectEqualStrings("/tmp/two", last.root);
    try std.testing.expectEqualStrings("two", last.task.id);
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `zig build test`

Expected: fail because `TaskHistory` is not defined.

- [x] **Step 3: Write minimal implementation**

Implement `TaskHistory` with owned `LastTaskSnapshot`:

```zig
pub const LastTaskSnapshot = struct {
    root: []u8,
    task: project_tasks.ProjectTask,
    pub fn deinit(self: *LastTaskSnapshot, allocator: std.mem.Allocator) void;
};

pub const TaskHistory = struct {
    allocator: std.mem.Allocator,
    last_task: ?LastTaskSnapshot = null,
    pub fn init(allocator: std.mem.Allocator) TaskHistory;
    pub fn deinit(self: *TaskHistory) void;
    pub fn record(self: *TaskHistory, root: []const u8, task: project_tasks.ProjectTask) !void;
    pub fn last(self: *const TaskHistory) ?*const LastTaskSnapshot;
};
```

Also import it in `src/root.zig`.

- [x] **Step 4: Run test to verify it passes**

Run: `zig build test`

Expected: pass.

### Task 5: Rerun Last Project Task

**Files:**
- Modify: `src/kernel/core.zig`
- Modify: `src/kernel/commands/system_commands.zig`
- Modify: `README.md`

- [x] **Step 1: Write the failing tests**

Add helper tests in `src/kernel/commands/system_commands.zig`:

```zig
test "task rerun no-history message suggests task commands" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try SystemCommands.writeNoLastTaskMessage(&aw.writer);
    const text = aw.written();

    try std.testing.expect(std.mem.indexOf(u8, text, "No project task has been run") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "task.list") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "task.run_test") != null);
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `zig build test`

Expected: fail because `writeNoLastTaskMessage` does not exist.

- [x] **Step 3: Implement rerun wiring**

In `Core`:

- import `TaskHistory`
- add `task_history: TaskHistory`
- initialize/deinit it
- register `task.rerun_last` with title `Tasks: Rerun Last`

In `SystemCommands`:

- add `cmdTaskRerunLast`
- add public testable `writeNoLastTaskMessage`
- refactor `runDetectedTask` to call `startProjectTask(core, root, task)`
- `startProjectTask` records task history after the job starts:

```zig
core.task_history.record(root, task.*) catch {};
```

- `cmdTaskRerunLast` uses `core.task_history.last()` and calls `startProjectTask` with the saved root/task.

In `README.md`, mention `task.rerun_last` near the task commands.

- [x] **Step 4: Run test to verify it passes**

Run: `zig build test`

Expected: pass.

### Task 6: Failed Task Summary

**Files:**
- Modify: `src/kernel/project_tasks.zig`

- [x] **Step 1: Write the failing tests**

Add tests:

```zig
test "formatRunResult includes stderr failure summary" {
    const result = TaskRunResult{
        .task_id = "test.fail",
        .label = "Fail",
        .command = "false",
        .cwd = "/tmp/project",
        .stdout = "",
        .stderr = "first error\nsecond error\nthird error\n",
        .success = false,
        .exit_code = 2,
        .duration_ms = 5,
    };

    const text = try formatRunResult(std.testing.allocator, &result);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "## Failure Summary") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Exit code: 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "first error") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "task.list") != null);
}

test "formatRunResult summarizes stdout tail when stderr is empty" {
    const result = TaskRunResult{
        .task_id = "test.fail",
        .label = "Fail",
        .command = "false",
        .cwd = "/tmp/project",
        .stdout = "line one\nline two\n",
        .stderr = "",
        .success = false,
        .exit_code = 1,
        .duration_ms = 5,
    };

    const text = try formatRunResult(std.testing.allocator, &result);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "stdout") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "line two") != null);
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `zig build test`

Expected: fail because failure summary is absent.

- [x] **Step 3: Implement failure summary**

Add `writeFailureSummary` called from `formatRunResult` before full stdout/stderr blocks when `!result.success`. Cap snippets to five non-empty lines.

- [x] **Step 4: Run test to verify it passes**

Run: `zig build test`

Expected: pass.

### Task 7: Final Verification And Commit

**Files:**
- All touched files

- [x] **Step 1: Format**

Run: `zig fmt src/root.zig src/kernel/command.zig src/kernel/command_history.zig src/kernel/core.zig src/kernel/input/command_palette.zig src/kernel/task_history.zig src/kernel/commands/system_commands.zig src/kernel/project_tasks.zig`

Expected: no formatting errors.

- [x] **Step 2: Test**

Run: `zig build test`

Expected: all tests pass.

- [x] **Step 3: Inspect diff**

Run: `git diff --stat && git diff --name-only`

Expected: feature files and docs only. Keep unrelated `src/main.zig` unstaged unless explicitly requested.

- [x] **Step 4: Commit**

Stage only feature and plan files:

```bash
git add README.md docs/superpowers/plans/2026-06-21-command-palette-task-mvp.md src/root.zig src/kernel/command.zig src/kernel/command_history.zig src/kernel/core.zig src/kernel/input/command_palette.zig src/kernel/task_history.zig src/kernel/commands/system_commands.zig src/kernel/project_tasks.zig
git commit -m "feat: polish command palette and tasks"
```

Expected: commit succeeds on `main`.
