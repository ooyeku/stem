# What if an editor was built like Erlang?

*The design rationale behind stem's supervised runtime.*

## The itch

Every long-lived editor session eventually hits a moment where the
editor *feels wrong*. Completions stop arriving. Highlighting freezes
on stale colors. Keystrokes lag for no visible reason. In most
editors, that moment is undiagnosable: the internals are an event loop
with callbacks, state is everywhere, and your options are "restart it"
or "live with it."

Telephone switches solved this problem fifty years ago. Erlang/OTP's
answer — isolate everything into supervised processes, let them crash,
restart them from a known state, and make the whole tree observable —
is why phone networks have nine-nines uptime while your editor
sometimes needs a restart after lunch.

Stem is an experiment in taking that answer literally for a terminal
editor. It's built in Zig on [vigil](https://github.com/ooyeku/vigil),
an OTP-style runtime: supervision trees, priority mailboxes, circuit
breakers, checkpoints, and telemetry — no BEAM required, one static
binary.

## The shape

Stem is two threads talking through mailboxes, with everything else
hanging off supervisors:

```
UI thread ◄──── priority message bus ────► core thread
   │                                          │
   └─ renders frames                          ├─ StemRuntime
                                              │    ├─ plugin supervisor
                                              │    ├─ LSP supervisor
                                              │    ├─ worker supervisor
                                              │    │    ├─ syntax parser
                                              │    │    └─ search indexer
                                              │    ├─ pub/sub broker
                                              │    ├─ timer service
                                              │    └─ checkpoint service
                                              └─ language servers (child processes)
```

The UI thread and core thread never share state — every keystroke,
render frame, and plugin event is a message with a priority class. A
critical `.quit` overtakes a queue of renders. Bulk traffic
(diagnostics floods, background scans) is watermarked and rate-limited
below interactive traffic. When the bus drops something, it counts the
drop and the health view shows it — the bus is not allowed to lie.

## What supervision buys in practice

**Language servers crash.** It's not an if. When one does, stem's
watchdog notices within seconds and schedules a restart with jittered
exponential backoff. If it keeps crashing, a per-language circuit
breaker opens: stem stops burning CPU on a hopeless server and toasts
you instead. Thirty seconds later the breaker half-opens and probes
once — so a server that was broken because of a half-installed binary
recovers *on its own* when the cause clears. No `:LspRestart`, no
restart-the-editor.

**Background workers die silently in most editors.** Stem's syntax
parse worker and workspace indexer run under a worker supervisor: if
one exits, the watchdog respawns it and tells you it did. The
alternative — highlighting silently frozen until you notice hours
later — is what we mean by *undiagnosable*.

**Nothing is allowed to vanish.** A message that can't be delivered
goes to a dead-letter queue with a reason attached. A message that
repeatedly poisons its consumer trips a hook. Both feed a
"check-engine light" in the status bar that points at the control
center, where you can see exactly what was dropped, from where, and
why.

**Crashes lose nothing.** Session state (buffers, cursors, splits)
checkpoints in the background through vigil's checkpoint pipeline —
versioned, atomically written, skipped when unchanged. Dirty buffers
back up every 30 seconds. Kill stem however you like; it comes back
where you were.

## The part that surprised us: honesty finds bugs

Building on a runtime that refuses to hide failures kept catching real
bugs — in stem itself:

- **The dishonest drop counter.** The message bus counted a message as
  "sent" when the mailbox had actually shunted it to dead-letter. The
  stats could never show the drop path firing. Found the day we wrote
  a test that filled a mailbox to capacity.
- **The restart storm.** The semantic-token refresh path could enqueue
  a restart of an unhealthy language server *once per rendered frame*,
  bypassing all backoff. Found while wiring circuit breakers — the
  breaker's counters made the storm visible.
- **The dangling registration.** Upgrading to vigil 3.0, whose
  graceful drain probes every registered mailbox at shutdown,
  instantly segfaulted on registry entries stem had been leaking for
  months. A stricter runtime surfaced a latent bug in one test run.

This is the thesis in miniature: **observability isn't a dashboard you
bolt on, it's a forcing function.** Every counter you add is a claim
your code has to live up to.

## What it costs

Honesty about the trade-offs:

- **Indirection.** A keystroke passes through a mailbox instead of a
  function call. Vigil's 2.3.0 work (ring-buffer mailboxes,
  single-allocation messages, condition-parked receives) got the
  per-message cost low enough that the bus is not the bottleneck — but
  it is a tax, and we pay it for isolation.
- **Two clocks of complexity.** Supervision trees and telemetry are
  code that has to be right. Vigil carries that burden so stem mostly
  wires things together, but "mostly" isn't "entirely."
- **It doesn't fix ecosystems.** No architecture compensates for
  Neovim's plugin count. Stem's bet is different: be the editor whose
  *failure behavior* is a feature.

## Where this goes

The [roadmap](roadmap.md) runs the same thesis forward: named
registers that survive crashes, macros with transactional replay
(all-or-nothing, rolled back on mid-replay failure), chaos testing as
a merge gate, and a plugin host where a plugin crash is a contained,
observable event.

If you've read this far, the ten-second demo: open stem, run
`stem.control_center`, and `kill -9` your language server from another
terminal. Watch the editor notice, back off, recover, and log every
step. That's the whole idea.
