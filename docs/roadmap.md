# Roadmap

Stem's identity is fixed: **the editor that supervises its own
subsystems, restarts what crashes, and can show you exactly what its
runtime is doing.** Every roadmap item below was screened against that
positioning. Features earn a slot by making stem more dependable, more
observable, or more recoverable — not by chasing feature-count parity
with editors that have a twenty-year head start.

The plan closes stem's known gaps against mature terminal editors
(registers, system clipboard, macros, format robustness, plugin
authoring, battle-testing), each implemented *the stem way*: durable,
supervised, and inspectable. Items have moved between releases and
say so where they did — a roadmap that quietly rewrites its own
history is the same kind of dishonest instrument as a counter that
can't report a drop.

---

## 0.13.0 — Dependable Everyday

Theme: the things you touch a hundred times a day become trustworthy,
and the reliability wave built on vigil 2.3.0 ships.

### Ships the vigil 2.3.0 reliability wave

Already landed on main, headlining this release:

- Per-language LSP circuit breakers with jittered backoff and
  automatic half-open recovery probes
- Watchdog self-healing for the syntax parse worker and workspace
  index walker
- Dead-letter inspection, poison-message hooks, and the telemetry-fed
  "check-engine light"
- Session recovery snapshots through vigil's checkpoint pipeline:
  background-written, atomic, version-stamped, skipped when unchanged
- Precise LSP debounce via the runtime timer service
- Plugin event flow control (a slow plugin can no longer stall the
  cursor)
- Opt-in multi-instance presence (`STEM_CLUSTER`)

### Session format: replace the hand-rolled parser

Slipped to 0.14.0, where it shipped — see that release below.

### System clipboard that works everywhere (OSC-52)

Did not ship. Tracked as
[#1](https://github.com/ooyeku/stem/issues/1) and rescheduled — see
0.15.0's deferral note, which batches it with the terminal
compatibility matrix since both need capability detection.

### Named registers with durable storage

Did not ship. Tracked as
[#3](https://github.com/ooyeku/stem/issues/3) and picked up in 0.15.0
below, where it also makes 0.14.0's macros durable.

---

## 0.14.0 — Deterministic Editing

Theme: repeatable operations and provable behavior.

### Ships: the plugin runtime becomes a metered, observable library

Landed on the 0.14.0 branch:

- The wasm interpreter is extracted into its own library,
  [wick](https://github.com/ooyeku/wick) — stem's first
  general-purpose spin-off (after vigil), now a pinned dependency
- Every plugin call runs under an instruction fuel budget: a runaway
  plugin fails one bounded call with `OutOfFuel` instead of hanging
  the editor
- Per-plugin call/trap/fuel stats in the plugin dashboard and control
  center; plugin traps feed the check-engine light alongside dead
  letters and open circuits

### Ships: a session format that survives its own filenames

Carried over from 0.13.0. The hand-rolled parser scanned for field
markers, so a path containing `"`, `\`, or `}` truncated or dropped
the record it lived in — on the exact session file stem writes for a
workspace holding `quote"file.zig` and `brace}file.zig`, the old
parser recovered one usable buffer out of three.

- Parsing and serialization now go through `std.json`, so paths are
  escaped and decoded properly and control characters are legal
- Out-of-range numbers saturate instead of wrapping (a long enough
  digit run used to panic a safe build)
- A path that isn't valid UTF-8 costs that one buffer, not the whole
  session file; malformed split layouts are dropped the same way
- Round-trip tests cover quotes, braces, newlines, control bytes,
  emoji, and a split layout replayed back through `SplitManager`

*Positioning check: this **is** the identity — crash recovery that
cannot be trusted is worse than none.*

### Ships: macros with transactional record and replay

The largest remaining modal-editing gap, closed. Stem's macros ride
the message bus, which makes them better than a keystroke tape:

- Record command streams (not raw keys), replayable with counts
  (`q` to record, `[N] @` to replay)
- **Transactional replay**: a macro applies as one undo group; a
  replay that errors mid-way rolls back instead of leaving a
  half-applied mess
- Macros live in per-session `a`–`z` registers; durable cross-restart
  storage arrives with the named-register work (issue #3)
- Replay progress and failures surfaced in the status bar

*Positioning check: aligned — "all-or-nothing replay" is a reliability
claim no incumbent macro system makes.*

### Did not ship: the "provable behavior" half

0.14.0 was themed *repeatable operations and provable behavior*. It
shipped the repeatable half. Recorded here rather than quietly rolled
forward, because the gap is the reason 0.15.0 looks the way it does:

- **Deterministic simulation testing.** Vigil ships a deterministic
  toolkit (`SimulatedClock`, `SimulatedTimerService`, `FaultInjector`)
  and stem still uses one corner of it — a single test exercising
  vigil's own timer service. Stem's debounce, backoff, breaker, and
  watchdog logic remains untested against a simulated clock.
- **Fuzz corpus expansion.** A wasm-loader target landed; the session
  format, LSP framing, and plugin manifests did not.
- **Unicode robustness pass** and the **terminal compatibility
  matrix** ([#5](https://github.com/ooyeku/stem/issues/5)) — not
  started.

All four carry into 0.15.0.

---

## 0.15.0 — Proven Under Fire

Theme: verification you can trust. Not the runtime's honesty about
itself — that shipped — but stem's honesty about *stem*.

The motivating discovery came during 0.14.0's release cleanup. Zig only
runs tests from files reachable from a test root, so a module can carry
a full suite that never executes and nothing complains. Nine modules
were in that state, `split_manager` — window splits — among them. Wiring
them back in didn't just surface failures; it surfaced test doubles that
had drifted out of sync with the interfaces they stand in for,
assertions that asserted the opposite of real behavior, and a
leak-checking helper that could only pass for code that allocated
nothing.

That is the same failure as the dishonest drop counter in the
[architecture notes](architecture.md) — a number that couldn't report
the thing it claimed to measure. Stem tells that story as a success.
This release applies the lesson to stem's own verification.

### Trustworthy test wiring

- A build step that walks `src/`, finds every file containing a `test`
  block, and fails the build when one isn't reachable from a test root.
  Cheap, mechanical, and it permanently closes the hole above.
- Audit the surviving test doubles against the interfaces they double;
  the drift found so far was caught by accident, not by design.

*Positioning check: aligned — "N tests pass" has to be a claim, not a
number.*

### Deterministic simulation testing (carried from 0.14.0)

- Debounce, backoff, breaker, and watchdog logic tested against
  `SimulatedClock` — no sleeps, no flakes
- Fault-injection tests for the LSP lifecycle: scripted crash storms
  must open breakers, recover on schedule, and never lose a queued
  `didOpen`

This is foundational for the next item: chaos runs can't gate merges
while the tests underneath them are timing-dependent.

### Chaos CI as a merge gate

- Fault-injection runs — killed LSPs, wedged plugins, full queues,
  clock jumps — built on the simulation harness above
- Fuzz corpus extended to the session format (now `std.json`, so the
  round-trip is property-testable), LSP framing, and plugin manifests
- Soak testing: multi-hour sessions under memory and file-descriptor
  tracking, with the runtime cockpit's own metrics as the oracle

### Named registers with a yank ring

The largest remaining modal-editing gap
([#3](https://github.com/ooyeku/stem/issues/3)), and it completes what
0.14.0 started: macros currently live in per-session registers, so
durable registers are what make "record a macro, crash, replay it"
true.

- Vim-style named registers (`"a`–`"z`, append with `"A`–`"Z`) plus a
  numbered yank ring
- Persisted per project through the checkpoint pipeline, under the same
  recovery guarantees as sessions
- Register picker in the command palette — inspect before you paste

*Positioning check: aligned — durable editor state under the recovery
guarantees the rest of stem already makes.*

### Deferred out of this release

Judgment calls worth stating, not silent omissions:

- **Plugin host v1 / API stability contract.** Freezing the manifest
  and SDK surface for the 1.x line is the right destination, but the
  plugin ABI changed shape in 0.14.0 (entry points are now
  signature-checked at resolve time). Freeze after chaos CI has
  stressed the host, not before.
- **A curated plugin index.** Needs an ecosystem that doesn't exist
  yet.
- **OSC-52 clipboard** ([#1](https://github.com/ooyeku/stem/issues/1))
  and the **terminal compatibility matrix**
  ([#5](https://github.com/ooyeku/stem/issues/5)). Both need terminal
  capability detection; batching them into one cycle avoids building
  that twice. Ship them together, here if there's room and in 0.16.0
  otherwise.
- **Cluster follow-through.** `STEM_CLUSTER` presence shipped in
  0.13.0 and the payoff — shared registers across local instances —
  stays gated on telemetry showing the transport is dependable. No
  such evidence yet.

### If the schedule tightens

Cut the registers and ship a purely-hardening release. For a project
that sells reliability, the wiring guard plus chaos CI is a defensible
0.15.0 on its own.

---

## Screened out

Items considered for this roadmap and rejected as off-identity:

- **Plugin-count parity** with Neovim/Helix — unwinnable and
  undifferentiated; replaced by the plugin host reliability contract.
- **GenServer-based service refactor** — evaluated against vigil
  2.3.0; rejected because its message loop poll-sleeps at 1 ms and its
  mailbox hard-codes a 5 s TTL that could silently expire queued LSP
  commands. Re-evaluate when upstream vigil offers configurable
  mailboxes and a parked receive (tracked in
  `src/services/lsp/supervisor.zig`).
- **A dedicated render inbox** on the throughput runtime profile —
  rejected: each editor thread blocks on one inbox, and the UI inbox
  needs priority queues so a critical quit overtakes queued frames
  (documented in `src/services/vigil_adapters.zig`).

---

*This roadmap is a statement of intent, not a contract. Items may move
between releases; the identity they serve does not.*
