# Roadmap

Stem's identity is fixed: **the editor that supervises its own
subsystems, restarts what crashes, and can show you exactly what its
runtime is doing.** Every roadmap item below was screened against that
positioning. Features earn a slot by making stem more dependable, more
observable, or more recoverable — not by chasing feature-count parity
with editors that have a twenty-year head start.

The plan closes stem's known gaps against mature terminal editors
(registers, system clipboard, macros, format robustness, plugin
authoring, battle-testing) across three releases, but each gap is
implemented *the stem way*: durable, supervised, and inspectable.

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

The session/recovery parser is hand-rolled JSON with a documented
escape-handling bug — a path containing `"` or `\` corrupts on
round-trip. For an editor whose promise is "a crash never loses your
place," recovery-file correctness is not optional.

- Replace the scanner with `std.json` parse/serialize
- Route the format through the checkpoint pipeline's version headers,
  with a migration hook so 0.12-era sessions load transparently
- Property-test the round-trip (fuzzed paths, splits payloads)

*Positioning check: this **is** the identity — crash recovery that
cannot be trusted is worse than none.*

### System clipboard that works everywhere (OSC-52)

Terminal editors live over SSH, inside tmux, on machines without a
display server. Exec-based clipboard bridges (`pbcopy`, `xclip`) fail
exactly where a terminal editor is most needed.

- OSC-52 copy integration with capability detection and graceful
  fallback to the internal clipboard
- `pbcopy`/`wl-copy`/`xclip` bridge as a secondary path when available
- Clipboard state visible in the control center (which backend is
  active, last sync result) — no silent "why didn't that copy?"

*Positioning check: dependable in hostile environments, with the
failure mode observable instead of mysterious.*

### Named registers with durable storage

Stem has a single unnamed clipboard. Mature modal editors have named
registers; stem's version makes them crash-safe.

- Vim-style named registers (`"a`–`"z`, append with `"A`–`"Z`) plus a
  numbered yank ring
- Registers persist per project through the checkpoint pipeline —
  yanked text survives a crash and a restart, which no incumbent offers
- Register picker in the command palette (inspect before you paste)

*Positioning check: aligned — registers become durable editor state
under the same recovery guarantees as sessions.*

---

## 0.14.0 — Deterministic Editing

Theme: repeatable operations and provable behavior.

### Macros: transactional record and replay

The largest remaining modal-editing gap. Stem's macros ride the
message bus, which makes them better than a keystroke tape:

- Record command streams (not raw keys), replayable with counts
- **Transactional replay**: a macro applies as one undo group; a
  replay that errors mid-way rolls back instead of leaving a
  half-applied mess
- Macros stored in registers, so they inherit 0.13's durable storage
- Replay progress and failures surfaced in the status bar

*Positioning check: aligned — "all-or-nothing replay" is a reliability
claim no incumbent macro system makes.*

### Deterministic simulation testing

Vigil ships a deterministic toolkit (`SimulatedClock`,
`SimulatedTimerService`, `FaultInjector`); stem uses only a corner of
it. This release makes time-dependent behavior provable:

- Debounce, backoff, breaker, and watchdog logic tested against the
  simulated clock — no sleeps, no flakes
- Fault-injection tests for the LSP lifecycle: scripted crash storms
  must open breakers, recover on schedule, and never lose a queued
  `didOpen`

### Battle-testing, phase one

- Expand the fuzz corpus beyond piece-table/state/URIs to the session
  format, LSP framing, and plugin manifests
- Unicode robustness pass over cursor motion, rendering width, and
  text objects (grapheme clusters, combining marks, East Asian width)
- Begin a terminal compatibility matrix (kitty, alacritty, wezterm,
  tmux, iTerm2, Terminal.app, Linux console) with documented results

*Positioning check: aligned — a reliability claim obligates proof,
not vibes.*

---

## 0.15.0 — Proven Under Fire

Theme: hardening completed, and the plugin host becomes the most
dependable extension surface in the terminal.

### Plugin host v1: reliability as the ecosystem strategy

Stem cannot out-plugin Neovim by volume. It can be the host where a
plugin crash is a contained, observable, recoverable event — and where
authoring is low-friction:

- **API stability contract**: manifest and SDK surface frozen for the
  1.x line; breaking changes gated behind manifest versions
- `stem plugin new` scaffolding (wasm and exec templates, SDK wired)
- Supervised restart policies exposed per plugin (max restarts,
  backoff, disable-on-poison) with breaker state in the dashboard
- A curated plugin index — small, but every entry vetted to run under
  supervision without dead-lettering

*Positioning check: scrutinized hard. "Grow an ecosystem" chases the
incumbents on their terms and was cut; "the host that never lets a
plugin take the editor down" is the differentiated version of the same
gap.*

### Battle-testing, phase two

- Chaos CI: fault-injection runs (killed LSPs, wedged plugins, full
  queues, clock jumps) as a merge gate, built on the 0.14 simulation
  harness
- Terminal compatibility matrix completed and published in the README
- Soak testing: multi-hour editing sessions under memory-leak and
  file-descriptor tracking, with the runtime cockpit's own metrics as
  the oracle

### Cluster follow-through (stretch)

`STEM_CLUSTER` presence shipped in 0.13. If the foundation proves
stable, the first user-visible payoff: shared registers/clipboard
across local stem instances via the distributed registry.

*Positioning check: aligned, and gated — ships only if presence
telemetry from 0.13–0.14 shows the transport is dependable.*

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
