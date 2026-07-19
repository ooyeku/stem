# Contributing to Stem

Thanks for your interest. Stem is young and moving fast; contributions
of every size are welcome — from a typo fix to a roadmap feature.

## Ground rules

Stem's identity is **reliability**: it supervises its subsystems,
restarts what crashes, and can show you what its runtime is doing.
Contributions are judged against that bar. Concretely:

- Failures must be *observable* — if your code can fail, the failure
  should reach a log, a telemetry counter, or the control center. No
  silent `catch {}` unless the comment explains why silence is correct.
- Long-running work runs *supervised* — new background threads should
  hang off the runtime (see `src/services/vigil_supervision.zig`), not
  free-float.
- Time-dependent logic should be testable without sleeps — vigil's
  `SimulatedClock`/`SimulatedTimerService` are available through
  `src/services/vigil_adapters.zig`.

## Getting started

```bash
git clone https://github.com/ooyeku/stem.git
cd stem
zig build run          # Debug build, launches the editor
zig build test         # Full test suite — must pass
```

Requires **Zig 0.16+** and a C compiler. Everything else is fetched by
the build.

## Making a change

1. Fork and create a feature branch.
2. Make the change. Unit tests live at the bottom of each file; add
   coverage for behavior you add or fix.
3. `zig build && zig build test` must pass.
4. Cross-check at least one other target:
   `zig build -Dtarget=x86_64-linux-gnu`
5. Open a pull request describing *what* and *why*. Small, focused PRs
   review faster than large ones.

## Where to start

The [open issues](https://github.com/ooyeku/stem/issues) include
several scoped small enough to be approachable without deep knowledge
of the codebase.
The [roadmap](docs/roadmap.md) shows where the project is headed;
[docs/architecture.md](docs/architecture.md) explains why it's built
the way it is.

Questions? Open a
[Discussion](https://github.com/ooyeku/stem/discussions) — there are
no stupid questions about a codebase this young.

## Code style

- Follow the surrounding code: naming, comment density, idiom.
- Comments explain *why*, not *what*.
- `zig fmt` before committing.
