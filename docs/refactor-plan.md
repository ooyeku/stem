# Decomposing `src/kernel/core.zig`

`core.zig` is the largest file in the repo by a wide margin (~9k LOC
as of this writing) and is the slowest single file to recompile.
Every edit anywhere in it forces a rebuild of the whole compilation
unit. The natural decomposition follows existing internal seams —
the file is already organized into clusters of related functions.

This document is the playbook for that decomposition. **It's
intended to be executed incrementally** — pull one module at a time,
build / test / commit between each. The order below is deliberate:
earlier extractions have the fewest dependencies, so doing them
first keeps later moves clean.

## Demonstrator already landed

[`src/kernel/commands/toggle_commands.zig`](../src/kernel/commands/toggle_commands.zig)
extracts the three editor-toggle commands (format-on-save, inline
diagnostics, inlay hints) following the existing
`commands/*_commands.zig` pattern. Trivial precedent — proves the
shape works for inline commands.

## Remaining extractions, in recommended order

### 1. Inline `cmd*` helpers → `commands/`

**Move:** Every remaining `fn cmd*` defined inside `Core` that's
registered via the command registry, into the appropriate
`commands/*_commands.zig` file (or a new one).

**Targets:**
- `cmdBookmarkList`, `cmdBookmarkClearAll` → new
  `commands/bookmark_commands.zig`
- `cmdDocumentSymbols`, `cmdWorkspaceSymbols` → existing
  `commands/lsp_commands.zig`
- `cmdLspFormatSelection`, `cmdLspCodeAction` → existing
  `commands/lsp_commands.zig`
- `cmdJumpBack`, `cmdJumpForward` → existing
  `commands/nav_commands.zig`
- `cmdBufferRestoreBackups` → existing
  `commands/buffer_commands.zig`

**Pattern:** copy the function body, change the signature from
`(ctx: *anyopaque, context: ?*const anyopaque) anyerror!void` to
`(core: anytype) anyerror!void`, replace `const self: *Core =
@ptrCast(@alignCast(ctx));` with direct use of `core`. Then in
`core.zig`'s `registerCommands`, switch from passing the function
directly to passing `Wrap(Namespace.cmdFoo).run`. Also update any
direct call sites in the leader switch (e.g. `try
cmdFoo(self, null);` → `try Namespace.cmdFoo(self);`).

**Estimated cut:** ~600 LOC out of core.zig.

**Risk:** Low. Mechanical. Each function is self-contained, only
touches `core.*` public surface.

### 2. Pickers → `kernel/pickers/`

**Move:** References picker + diagnostics picker. Their state
fields, open/close helpers, input handlers, snapshot population.

**Targets:**
- A new `kernel/pickers/references_picker.zig` holding:
  - `ReferenceEntryOwned` struct
  - State fields: `references_picker_entries`,
    `references_picker_selected`, `references_picker_scroll_offset`,
    `references_picker_origin`
  - `openReferencesPicker`, `closeReferencesPicker`,
    `handleReferencesPickerInput`, `readReferenceSnippet`
- A new `kernel/pickers/diagnostics_picker.zig` holding:
  - State fields: `diagnostics_picker_selected`,
    `diagnostics_picker_scroll_offset`, `diagnostics_picker_origin`
  - `openDiagnosticsPicker`, `closeDiagnosticsPicker`,
    `handleDiagnosticsPickerInput`, `activeDiagnosticCount`,
    `activeDiagnosticAt`

**Pattern:** group the state into a `Picker` substruct that lives
inside `Core`; move methods to operate on a `*Picker` first and a
`*Core` second. Lets each module own its own state shape; `Core`
becomes a container.

```zig
// kernel/pickers/references_picker.zig
pub const ReferencesPicker = struct {
    entries: std.ArrayListUnmanaged(ReferenceEntryOwned) = .empty,
    selected: usize = 0,
    scroll_offset: usize = 0,
    origin: ?Buffer.OpenedFrom = null,

    pub fn open(self: *ReferencesPicker, core: *Core, refs: []LSPManager.Location) !void { ... }
    pub fn close(self: *ReferencesPicker, core: *Core) void { ... }
    pub fn handleInput(self: *ReferencesPicker, core: *Core, key: vaxis.Key) !bool { ... }
};

// core.zig
pub const Core = struct {
    references_picker: ReferencesPicker = .{},
    ...
};
```

**Estimated cut:** ~700 LOC out of core.zig.

**Risk:** Medium. The pickers touch `lsp_manager`, `buffer_manager`,
`jump_list`, `state()`, `sendUpdate`. All public surface, but
verifying nothing regresses requires manual walk through every
picker flow.

### 3. Leader chord dispatch → `kernel/leader_dispatch.zig`

**Move:** `handleLeaderChordKey`, `focusPaneLeft/Right/Up/Down`,
`closeCurrentPaneOrBuffer`, the chord-prefix detection inline in
the two leader switches.

**Pattern:** Top-level functions on `*Core`, no new state. Keeps
the dispatch grammar in one file separately from the input parsing
in `core.zig`.

**Estimated cut:** ~300 LOC out of core.zig.

**Risk:** Low–medium. The chord dispatch fans out to many command
namespaces; lots of imports in the new file but each call is
straightforward.

### 4. Render snapshot builder → `kernel/render.zig`

**Move:** `sendUpdate` and its private helpers
(`buildPaneSnapshots`, the various per-section snapshot loops).
The pane-handling, the LSP-token copy, the diagnostic-count
coalescing — anything that runs once per frame to produce the
`RenderSnapshot`.

**Pattern:** A top-level `pub fn build(self: *Core, alloc:
Allocator) !*RenderSnapshot` in `kernel/render.zig`. Core's
`sendUpdate` becomes a thin wrapper: throttle check → call
`render.build` → post to bus.

**Estimated cut:** ~1,500 LOC out of core.zig. Biggest single
chunk.

**Risk:** Medium. Lots of read access to Core fields. None of it
mutates anything sensitive; the risk is in correctly threading the
arena allocator through the many sub-snapshots.

### 5. Per-mode input handlers → `kernel/input/`

**Move:** `handleSelectInput`, `handleVisualInput`,
`handleInsertInput`, `handleViewInput`, `handleVisualSearchInput`,
`handleFilePickerInput`, `handleFileExplorerInput`,
`handleBufferPickerInput`, `handleCommandPaletteInput`,
`handleGoToLineInput`, `handleSymbolPickerInput`,
`handleWorkspaceSymbolPickerInput`, `handleGlobalSearchInput`.

**Targets:** one file per mode under `kernel/input/<mode>.zig`.
Each exports `pub fn handle(core: *Core, key: vaxis.Key) !bool`.
The main dispatch switch in `core.zig` becomes a one-liner per
mode: `.select => try input.select.handle(self, key)`, etc.

**Pattern:** Similar to picker extraction. Mode-specific state
either stays on `Core` (most cases) or moves into a sub-struct
alongside the handler.

**Estimated cut:** ~3,000 LOC out of core.zig. Largest aggregate
cut but spread across many files.

**Risk:** Medium-high. The handlers reach into nearly every Core
subsystem. Highest risk of subtle regressions because each handler
has many short-circuits and edge cases. Recommend doing one mode
at a time and running the editor manually between each.

## After all five steps

Estimated final `core.zig`: ~2,500 LOC. Just orchestration —
struct definition, `init`/`deinit`, `run` (the main event loop),
plus the small public helpers (`state()`, `setStatus`,
`requestRender`, etc.). Everything else lives behind a clear
import.

**Compile-time benefit:** each per-edit recompile shrinks roughly
in proportion. Zig's incremental compilation already only rebuilds
touched modules, but the unit currently dominates wall time for any
edit anywhere in the file.

**Maintenance benefit:** new contributors find code faster, code
reviews are scoped to one concern, dependency directions become
visible at the import level.

## Anti-goals

- **Don't introduce extra runtime indirection.** Every extraction
  keeps the same call sites and inlining behavior — no vtables, no
  new struct hierarchies that the optimizer has to reason about.
- **Don't change behavior.** Every step is a pure refactor. Tests
  pass before and after. Any behavior change goes in a separate
  commit with its own rationale.
- **Don't pre-split.** Cohesive code belongs in one file. The seams
  above are real seams — clusters of functions that touch the same
  state and nothing else. Don't manufacture seams that don't exist.

## How to land this

Each numbered step is a separate PR. Each PR is its own commit-or-two
sized chunk. Run `zig build && zig build test && zig build
-Dtarget=x86_64-windows-gnu` before pushing.
