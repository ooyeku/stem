# Command Palette And Project Task MVP Design

Date: 2026-06-21

## Goal

Improve two everyday Stem workflows without expanding the scope into persistence,
task pinning, or large UI redesigns:

- Make the command palette prefer commands the user recently executed.
- Make project tasks easier to rerun and easier to diagnose when they fail.

This is an in-memory MVP. State resets when Stem exits.

## Non-Goals

- Persist command or task history across restarts.
- Add pinned or favorite tasks.
- Add a new task picker UI.
- Add clickable diagnostics or source jumps from task output.
- Change the plugin command registration contract.

## Approach

Use small dedicated modules owned by `Core` rather than storing all behavior
directly in `Core`.

- `command_history.zig` records executed command IDs and provides a recency score.
- `task_history.zig` records the last started project task and exposes a rerun
  snapshot.
- Existing command palette and task command modules consume those helpers.

This keeps the MVP testable and keeps the door open for persisted history later.

## Command Palette Behavior

When a command executes from the palette, Stem records its command ID. The history
keeps a bounded most-recent-first list and deduplicates command IDs by moving a
repeated command to the front.

Palette search keeps the existing fuzzy registry behavior, then applies a small
recency boost to matching commands. Empty palette search should show recent
commands first, followed by the rest of the registry results in normal order.

The MVP does not add input-history recall because the current palette already
uses `Ctrl+P` and `Ctrl+N` for selection movement, and cross-terminal `Alt+Up` /
`Alt+Down` reliability needs separate validation.

## Project Task Behavior

When Stem starts a detected project task, it records a copy of:

- task ID
- label
- command
- kind
- root
- source
- priority

Add a palette command:

- `task.rerun_last`: rerun the exact recorded task from its recorded root.

If no task has been started in this Stem session, `task.rerun_last` opens a
`[TASK OUTPUT]` virtual buffer explaining that there is no last task yet and
suggesting `task.list`, `task.run_build`, and `task.run_test`.

If the recorded task can no longer be constructed, the command opens a readable
error buffer rather than failing silently. The MVP should prefer the recorded
command snapshot over redetecting by ID, so deleted or changed project files do
not prevent rerunning the previous command.

## Task Output Failure Summary

`formatRunResult` gains a compact failure section when `success == false`:

- status and exit code
- first useful stderr lines, capped to a small number of lines
- stdout tail if stderr is empty
- a short next-actions list: `task.output`, `job.list`, and `task.list`

The existing full stdout and stderr fenced blocks remain below the summary.

## Data Flow

Command palette:

1. User opens palette.
2. `CommandRegistry.search` returns matching commands.
3. `command_history` reorders or boosts the result list.
4. User executes a command.
5. Palette records the command ID in `command_history` before invoking it.

Project tasks:

1. User runs `task.run_*`.
2. Detection chooses the preferred task by kind.
3. `task_history` records a snapshot.
4. Job manager starts the task.
5. `task.rerun_last` uses the snapshot to start the same command again.

## Error Handling

- Command history allocation failures should not prevent command execution.
- Missing task history should produce a clear virtual buffer.
- Task rerun uses the recorded command; it does not fail just because detection
  changed.
- Failed task execution still produces retained output.

## Testing

Add focused tests for:

- command history deduplication and bounded recency order
- recency-aware command ordering with empty and non-empty search inputs
- task history snapshot ownership and replacement
- `task.rerun_last` no-history message
- task failure summary with stderr, stdout-only, and no-output failures

Run:

- `zig fmt` on touched Zig files
- `zig build test`

## Acceptance Criteria

- Recently executed palette commands rank above otherwise equivalent commands.
- Empty command palette search starts with recent commands.
- `task.rerun_last` appears in the command palette and reruns the last started
  project task in the current Stem session.
- Failed task output includes a concise failure summary while preserving full
  stdout and stderr.
- Existing task commands and plugin commands continue to work.
