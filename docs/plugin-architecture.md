# Plugin Architecture

Stem has two plugin runtimes. Both load from `~/.stem/plugins/<name>/`
and share the same manifest (`plugin.json`), permission model, and
palette integration.

| Runtime | Source             | Loaded by                              | Isolation        | Permission status |
| ------- | ------------------ | -------------------------------------- | ---------------- | ----------------- |
| `wasm`  | `<name>.wasm`      | pure-Zig interpreter in stem's process | wasm sandbox     | `spawn` enforced |
| `exec`  | executable binary  | child process, stdin/stdout            | OS process       | event subscription checked |

The legacy in-process `.dylib` runtime — with its `PluginInterface`
extern struct, host-exported `_stem_*` symbols, SIGSEGV crash-isolation
shim, and request/reply SDK — was removed in the Phase 4 cleanup.
`PluginManager` in [src/plugins/manager.zig](../src/plugins/manager.zig)
now only orchestrates wasm and exec plugins.

## Manifest

Every plugin directory contains a `plugin.json`:

```json
{
  "name": "git",
  "version": "0.4.0",
  "description": "Git integration",
  "runtime": "wasm",
  "entry": "git-wasm.wasm",
  "permissions": {
    "spawn": ["git"],
    "filesystem": ["read:."],
    "events": ["buffer.*"]
  },
  "commands": [
    {"id": "git.status", "title": "[Git] Status", "description": "Show repository status"}
  ]
}
```

`PluginManager.tryLoadPluginDir` reads the manifest, eagerly registers
every declared command into the command palette (so commands stay
discoverable even if the plugin later fails to start), stashes the
permissions, then hands off to the runtime-specific loader.

## wasm runtime

Plugin source is a wasm32-freestanding Zig executable that imports a
small `env.*` surface from the host:

| Host import | Signature | Purpose |
| --- | --- | --- |
| `stem_log` | `(level: i32, ptr, len)` | route a line to stem's logger |
| `stem_register_command` | `(id, title, desc)` | add a command at runtime (manifest registration is the primary path; this is for runtime-conditional commands) |
| `stem_show_notification` | `(level, ptr, len)` | callback is accepted; visible UI presentation is pending |
| `stem_open_buffer` | `(name, content)` | open a virtual buffer |
| `stem_spawn_capture` | `(cmd, out_buf) → i32` | run a child process synchronously; gated by `permissions.spawn` |

Plugin exports:

| Export | Called when | Notes |
| --- | --- | --- |
| `activate()` | once at load | typically calls `stem_register_command` for any runtime-conditional commands |
| `handle_command(id_ptr, id_len)` | command palette invocation | manifest-declared commands route here |
| `deactivate()` (optional) | shutdown / unload | best-effort |

The host's pure-Zig interpreter lives in
[src/plugins/wasm/interpreter.zig](../src/plugins/wasm/interpreter.zig).
Loader / lifecycle in
[src/plugins/wasm/loader.zig](../src/plugins/wasm/loader.zig).

## exec runtime

A plugin is a separate executable; the host spawns it as a child
process and frames JSON-RPC 2.0 messages over stdio (LSP-style
`Content-Length:` framing). The host issues `plugin/initialize` on
spawn and `command/execute` when a command fires; plugins call
`plugin/log`, `plugin/registerCommand`, `plugin/subscribeEvent`, and
`editor/showNotification`. Event subscriptions and notifications are
accepted by the host today, but event delivery and visible notification
rendering are still follow-up work.

See [src/plugins/process_loader.zig](../src/plugins/process_loader.zig)
and [src/plugins/jsonrpc.zig](../src/plugins/jsonrpc.zig).

## Permissions

`permissions` in the manifest declares the capabilities a plugin is
allowed to use. Today the enforced ones are:

- **`spawn`** — allowlist of program names that `stem_spawn_capture`
  (wasm) may invoke. wasm plugins outside the list get an empty
  return so they can surface a clean error.
- **`events`** — allowlist of `protocol.PluginEvent` topic names a
  plugin may subscribe to. The permission check is wired for exec
  plugins; actual broadcast delivery into plugins is still pending.
- **`filesystem`** — declared and stashed, not yet enforced.

Entries support a trailing `*` glob (`buffer.*`). Plugins with no
`permissions` entry default to deny.

## Operator surface

The `stem plugin` CLI subcommand lives in
[src/tools/plugin_cli.zig](../src/tools/plugin_cli.zig):

- `stem plugin list` — installed plugins with version + runtime.
- `stem plugin info <name>` — pretty-print the manifest.
- `stem plugin install <path>` — copy a plugin directory into
  `~/.stem/plugins`.
- `stem plugin remove <name>` — delete an install.
- `stem plugin test <path>` — hermetic smoke test (manifest +
  artifact; for wasm, runs `activate` against mocked host imports
  and reports registered commands).

## Bundled plugins

| Name | Runtime | What it does |
| --- | --- | --- |
| `echo` | exec | reference JSON-RPC plugin (`echo.hello` logs a greeting) |
| `echo-wasm` | wasm | reference wasm plugin (`echo-wasm.hello` logs a greeting) |
| `git` | wasm | `git.status`, `git.diff`, `git.diff_staged` via `stem_spawn_capture` |
| `markdown_viewer` | wasm | `markdown.preview/edit/toggle_panel` (preview rebuild pending wasm event ABI) |
| `plugin_manager` | wasm | dashboard via `stem plugin list` shell-out + load/unload hints |

`install.sh` copies each directory to both `<prefix>/lib/stem/plugins/<name>/`
and `~/.stem/plugins/<name>/`, codesigns the installed `stem` binary
(necessary on macOS so the adhoc signature survives the `cp`), and
sweeps any leftover `*.dylib` / `*.so` / `*.dll` files out of the
per-user dir.

## Design principles

1. **No Zig structs cross the plugin boundary.** Wasm plugins talk
   to the host through C-ABI host imports operating on linear-memory
   `(ptr, len)` pairs. Exec plugins talk through JSON-RPC envelopes.
2. **Manifest is the source of truth for the palette.** Commands are
   registered eagerly from `plugin.json` before the plugin starts;
   runtime self-registration dedupes against this.
3. **Permissions declared up front.** A plugin without `spawn: ["git"]`
   in its manifest can't run `git`. The check happens in the host
   `stem_spawn_capture` callback in
   [src/plugins/manager.zig](../src/plugins/manager.zig).
4. **Isolation by construction, not by signal handler.** Wasm
   plugins are sandboxed by the interpreter; a real fault traps
   inside the interpreter without unwinding through stem. Exec
   plugins are isolated by the OS process boundary. There's no
   SIGSEGV-handler safety net to second-guess.

## Follow-ups

- Wasm event dispatch (`buffer_switched`, `cursor_moved`, …) so
  markdown-viewer's live preview can come back.
- Wasm panel / status-item host imports.
- Process plugin event subscription delivery (the permission check
  lands today but the broadcast → process-plugin route is a stub).
- Spawn checksum verification + `stem plugin install <url>` for
  remote plugins.
- A real plugin registry / index.
