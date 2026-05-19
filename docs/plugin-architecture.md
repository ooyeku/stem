# Plugin Architecture

Stem supports two plugin runtimes. Both load from
`~/.stem/plugins/<name>/` and share the same manifest (`plugin.json`),
permission model, and palette integration.

| Runtime | Source | Loaded by | Isolation | Permission status |
|---|---|---|---|---|
| `wasm` | `<name>.wasm` | Pure-Zig interpreter in stem's process | Wasm sandbox | `spawn` enforced |
| `exec` | Executable binary | Child process, stdin/stdout JSON-RPC | OS process | event subscription checked |

`PluginManager` in [src/plugins/manager.zig](../src/plugins/manager.zig)
orchestrates both runtimes.

## Manifest

Every plugin directory contains a `plugin.json`:

```json
{
  "name": "git",
  "version": "0.6.0",
  "description": "Git integration",
  "runtime": "wasm",
  "entry": "git-wasm.wasm",
  "restart": "on_crash",
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
every declared command into the palette (so commands stay
discoverable even if the plugin later fails to start), installs the
permissions and restart policy, then hands off to the runtime-specific
loader.

### Restart policy

The optional `restart` field controls how the host reacts when an
exec plugin's child process exits:

| Value | Behaviour |
|---|---|
| `never` (default) | Crash → drop the plugin, log a warning. |
| `on_crash` | Re-spawn after backoff (1 s → 5 s → 30 s, then give up). |
| `always` | Same as `on_crash` today; reserved for "restart on clean exit too" later. |

A successful re-load resets the backoff counter. Restart bookkeeping
lives in `restart_state` / `pending_restarts` in
[src/plugins/manager.zig](../src/plugins/manager.zig); restarts run on
the core loop tick so spawns never originate inside a reader thread
that's still unwinding.

## Wasm runtime

A wasm plugin is a `wasm32-freestanding` Zig executable that imports a
small `env.*` surface from the host:

| Host import | Signature | Purpose |
|---|---|---|
| `stem_log` | `(level: i32, ptr, len)` | Route a line to stem's logger |
| `stem_register_command` | `(id, title, desc)` | Add a command at runtime (manifest registration is the primary path; this covers runtime-conditional commands) |
| `stem_show_notification` | `(level, ptr, len)` | Host accepts the callback; the in-editor toast surface is still being wired |
| `stem_open_buffer` | `(name, content)` | Open a virtual buffer |
| `stem_spawn_capture` | `(cmd, out_buf) → i32` | Run a child process synchronously; gated by `permissions.spawn` |

Exports:

| Export | Called when | Notes |
|---|---|---|
| `activate()` | Once at load | Typically registers runtime-conditional commands |
| `handle_command(id_ptr, id_len)` | Command palette invocation | Manifest-declared commands route here |
| `deactivate()` (optional) | Shutdown / unload | Best-effort |

The pure-Zig interpreter is in
[src/plugins/wasm/interpreter.zig](../src/plugins/wasm/interpreter.zig).
Loader and lifecycle live in
[src/plugins/wasm/loader.zig](../src/plugins/wasm/loader.zig). The
interpreter implements MVP wasm plus the bulk-memory `memory.init` /
`data.drop` opcodes so plugins can ship passive data segments.

## Exec runtime

An exec plugin is a separate executable; the host spawns it as a
child process and frames JSON-RPC 2.0 messages over stdio (LSP-style
`Content-Length:` framing). The host issues `plugin/initialize` on
spawn and `command/execute` when a command fires; plugins call
`plugin/log`, `plugin/registerCommand`, `plugin/subscribeEvent`, and
`editor/showNotification`. Event subscriptions and notifications are
accepted by the host today, but broadcast event delivery into exec
plugins and visible notification rendering are still follow-up work.

See [src/plugins/process_loader.zig](../src/plugins/process_loader.zig)
and [src/plugins/jsonrpc.zig](../src/plugins/jsonrpc.zig).

## Permissions

`permissions` in the manifest declares the capabilities a plugin is
allowed to use:

- **`spawn`** — allowlist of program names that `stem_spawn_capture`
  (wasm) may invoke. Plugins outside the list get an empty return so
  they can surface a clean error.
- **`events`** — allowlist of `protocol.PluginEvent` topic names a
  plugin may subscribe to. Permission is checked on subscribe;
  broadcast delivery into plugins is still pending.
- **`filesystem`** — declared and stashed, not yet enforced.
- **`manage_plugins`** — opt-in capability required to call the
  `stem_load_plugin` / `stem_unload_plugin` host imports.

Entries support a trailing `*` glob (`buffer.*`). Plugins with no
`permissions` entry default to deny.

## Operator surface

The `stem plugin` CLI subcommand lives in
[src/tools/plugin_cli.zig](../src/tools/plugin_cli.zig):

- `stem plugin list` — installed plugins with version + runtime
- `stem plugin info <name>` — pretty-print the manifest
- `stem plugin install <path>` — copy a plugin directory into
  `~/.stem/plugins`
- `stem plugin remove <name>` — delete an install
- `stem plugin test <path>` — hermetic smoke test (manifest +
  artifact; for wasm, runs `activate` against mocked host imports
  and reports registered commands)

## Bundled plugins

| Name | Runtime | What it does |
|---|---|---|
| `echo` | wasm | Reference wasm plugin; `echo.hello` pops a notification |
| `git` | wasm | `git.status`, `git.diff`, `git.diff_staged` via `stem_spawn_capture`; live `Git: <branch>` indicator via event subscriptions |
| `plugin_manager` | wasm | Dashboard (`stem plugin list` shell-out) plus `reload_all` via the load/unload host imports |

`install.sh` copies each directory into
`<prefix>/lib/stem/plugins/<name>/` and `~/.stem/plugins/<name>/`,
re-codesigns the installed `stem` binary on macOS (so the adhoc
signature survives the `cp`), and sweeps any leftover `*.dylib` /
`*.so` / `*.dll` files out of the per-user dir.

## Design principles

1. **No Zig structs cross the plugin boundary.** Wasm plugins talk to
   the host through C-ABI host imports operating on linear-memory
   `(ptr, len)` pairs. Exec plugins talk through JSON-RPC envelopes.
2. **Manifest is the source of truth for the palette.** Commands are
   registered eagerly from `plugin.json` before the plugin starts;
   runtime self-registration dedupes against this.
3. **Permissions declared up front.** A plugin without
   `spawn: ["git"]` in its manifest can't run `git`. The check
   happens in the host `stem_spawn_capture` callback in
   [src/plugins/manager.zig](../src/plugins/manager.zig).
4. **Isolation by construction, not by signal handler.** Wasm plugins
   are sandboxed by the interpreter; a real fault traps inside the
   interpreter without unwinding through stem. Exec plugins are
   isolated by the OS process boundary.

## Follow-ups

- Broadcast event delivery into exec / wasm plugins (the permission
  check lands today; the route into the plugin is the gap).
- Visible notification rendering inside the editor.
- Panel and status-item host imports.
- Signed plugin install + remote `stem plugin install <url>`.
- A plugin registry / index.
