# Vigil Self-Healing Actions And Watchdog Toasts Design

## Goal

Turn Stem's existing Vigil runtime health data into actionable recovery guidance and quiet, timely status toasts. The first version favors manual recovery over automatic restarts so users stay in control while Stem becomes better at explaining what went wrong and what to do next.

## Scope

This design covers:

- A small health recommendation layer that converts runtime snapshots into self-healing actions.
- A `stem.heal` command that opens a focused recovery buffer.
- Control Center integration that shows the same recommended actions.
- Watchdog toasts for newly detected runtime trouble.

This design does not add automatic recovery, persisted incident history, or plugin event subscriptions. Those can build on the same recommendation layer later.

## User Experience

When Stem detects runtime issues, it should surface concise guidance:

- If an LSP server becomes unhealthy, show a warning toast and recommend `lsp.restart` or `lsp.status`.
- If plugin lifecycle health shows crashes or pending restarts, recommend `plugin.inspect`.
- If a background job failed, recommend `job.list`, `task.output`, and `task.rerun_last` when task history exists.
- If message bus drops increase, recommend `stats.show`.
- If the project index is at capacity, recommend `project.brain`.

The new `stem.heal` command opens `[HEAL]`, a virtual markdown report with sections for current issues, recommended commands, and recent Vigil/runtime context. Control Center keeps its existing broader overview but reuses the same recommendation text so there is only one source of truth.

Watchdog toasts should be sparse and actionable. They trigger only when a watched counter or health state crosses from normal to problematic, not on every tick. Example messages:

- `LSP health: 1 server unhealthy - run lsp.status`
- `Plugin health: crash recorded - run plugin.inspect`
- `Message bus pressure: drops detected - run stats.show`
- `Job failed - run job.list`

## Architecture

Add a new module, `src/kernel/runtime_watchdog.zig`, with two small responsibilities:

- Build `HealingRecommendation` values from snapshots.
- Track the previous `WatchdogSnapshot` and produce deduplicated `WatchdogToast` values when health worsens.

The module should not depend on `Core`. It should accept plain value inputs:

- telemetry snapshot and per-bus drop totals
- plugin health summary
- LSP health summary
- job summary
- search index health summary
- task-history availability

`Core` owns one `RuntimeWatchdog` instance and calls it from the tick path after routine maintenance. If the watchdog returns a toast, Core routes it through existing status-message APIs. The watchdog stores only the last observed counters/state and the last toast key/timestamp needed to avoid noisy repeats.

`SystemCommands` gets:

- `cmdStemHeal` to render `[HEAL]`
- a reusable `renderHealingBuffer`
- a helper used by Control Center to render recommendations

`registerCommands` adds:

- `stem.heal` - "Stem: Heal Runtime"

## Recommendation Model

Each recommendation has:

- severity: `info`, `warning`, or `error`
- title: short human label
- detail: one sentence explaining the condition
- command: primary command to run
- optional alternate command

The first version renders commands as text in virtual buffers. It does not implement clickable actions or automatic command execution.

## Watchdog Rules

The watchdog compares the previous and current snapshots:

- LSP unhealthy count increases from zero to nonzero: warning toast.
- Plugin crash count increases: warning toast.
- Pending plugin restarts increases from zero to nonzero: info toast.
- Any bus drop total increases from zero to nonzero: warning toast.
- Failed job count increases: warning toast.
- Index-at-capacity changes from false to true: warning toast.

Each toast key should be throttled so the same issue cannot spam the status bar during fast ticks.

## Error Handling

Health rendering is best-effort. If a snapshot fails to allocate, `stem.heal` should still open with the sections it can render, or return the allocation error if no buffer can be built. Watchdog tick handling should never fail the editor loop; snapshot errors simply suppress that tick's toast.

## Testing

Unit tests should cover:

- recommendation generation for each issue type
- no recommendations when all snapshots are healthy
- watchdog emits a toast only on transition/increase
- watchdog suppresses repeated toast keys inside the throttle window
- `stem.heal` output includes the expected command names for representative issues

Integration tests are not required for v1 because the behavior is composed from existing snapshot APIs and virtual-buffer rendering.
