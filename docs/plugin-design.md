# Building Stem Plugins

This guide covers how to build plugins for stem. For host-side
internals, see [Plugin Architecture](plugin-architecture.md).

## Overview

Stem plugins are manifest-driven extensions loaded from
`~/.stem/plugins/<name>/`. Two runtimes are supported:

| Runtime | Artifact | Isolation | Best for |
|---|---|---|---|
| `wasm` | `<name>.wasm` | Stem's pure-Zig wasm interpreter | Small, sandboxed commands that call narrow host imports |
| `exec` | Executable binary | Child process over stdio | Plugins that need their own runtime, dependencies, or language ecosystem |

Both runtimes share:

- `plugin.json` metadata and command declarations
- Permission declarations for host capabilities
- Command palette registration through `PluginManager`
- Restart policy on crash (exec runtime)
- Cleanup of registered commands and permission records on unload

## Directory layout

Each plugin lives in its own directory:

```text
my-plugin/
├── plugin.json
└── my-plugin.wasm        # runtime: "wasm"
```

or:

```text
my-plugin/
├── plugin.json
└── stem-my-plugin        # runtime: "exec"
```

Bundled examples live under [`bundled/plugins/`](../bundled/plugins/).

## Manifest

Every plugin must provide `plugin.json`:

```json
{
  "name": "my_plugin",
  "version": "0.1.0",
  "description": "Example stem plugin",
  "runtime": "wasm",
  "entry": "my-plugin.wasm",
  "restart": "on_crash",
  "permissions": {
    "spawn": ["git"],
    "events": ["buffer.*"],
    "filesystem": ["read:."]
  },
  "commands": [
    {
      "id": "my_plugin.hello",
      "title": "[My Plugin] Hello",
      "description": "Log a greeting"
    }
  ]
}
```

### Fields

| Field | Required | Notes |
|---|---|---|
| `name` | yes | Stable plugin id. Must be unique across loaded plugins. |
| `version` | yes | Plugin version shown by `stem plugin list/info`. |
| `description` | yes | Human-readable summary. |
| `runtime` | yes | `wasm` or `exec`. |
| `entry` | yes | Artifact path relative to the plugin directory. |
| `restart` | no | `never` (default), `on_crash`, or `always`. Applies to exec plugins; ignored for wasm. |
| `permissions` | no | Capability allowlists. Missing permissions default to deny. |
| `commands` | no | Commands registered into the palette before runtime activation. |

Manifest command registration is the primary path. Runtime
registration is useful for conditional commands and dedupes against
manifest-declared ids.

## Permissions

Permissions are declared in the manifest and enforced by the host
where the corresponding capability is wired:

| Permission | Status | Description |
|---|---|---|
| `spawn` | enforced for wasm | Allowlist of executable names accepted by `stem_spawn_capture`. |
| `events` | checked on subscribe | Validates requested event topics; broadcast delivery is still pending. |
| `filesystem` | declared only | Reserved for future file-access gates. |
| `manage_plugins` | enforced for wasm | Required to call `stem_load_plugin` / `stem_unload_plugin`. |

Entries can end with `*` for prefix matches (`buffer.*`).

## Restart policy

For exec plugins, the optional `restart` field controls what happens
when the child process exits:

- `never` (default) — the plugin stays down until the user reloads.
- `on_crash` — re-spawn with a 1 s → 5 s → 30 s backoff. After three
  failures the plugin gives up and the user must reload manually.
- `always` — same as `on_crash` today; reserved for future
  "restart even on clean exit" semantics.

A successful re-load clears the backoff counter.

## Wasm plugins

Wasm plugins are compiled as `wasm32-freestanding` executables with
no entry point. They export lifecycle functions and import a narrow
host surface from the `env` namespace.

### Host imports

| Import | Purpose |
|---|---|
| `stem_log(level, ptr, len)` | Write to stem's log. |
| `stem_register_command(id, title, desc)` | Register a runtime command. |
| `stem_show_notification(level, ptr, len)` | Host callback exists; visible UI presentation is still being wired. |
| `stem_open_buffer(name, content)` | Open a virtual buffer in the editor. |
| `stem_spawn_capture(cmd, out_buf, out_max)` | Run an allow-listed process and copy stdout into wasm memory. |
| `stem_load_plugin(name)` / `stem_unload_plugin(name)` | Plugin management (requires `manage_plugins`). |

### Exports

| Export | Called when |
|---|---|
| `activate()` | Plugin load. |
| `handle_command(id_ptr, id_len)` | A command owned by the plugin is invoked. |
| `deactivate()` | Optional best-effort shutdown hook. |

### Minimal example

```zig
const std = @import("std");

extern "env" fn stem_log(level: i32, ptr: [*]const u8, len: i32) void;
extern "env" fn stem_register_command(
    id_ptr: [*]const u8,
    id_len: i32,
    title_ptr: [*]const u8,
    title_len: i32,
    desc_ptr: [*]const u8,
    desc_len: i32,
) void;

const CMD_ID = "my_plugin.hello";
const TITLE = "[My Plugin] Hello";
const DESC = "Log a greeting";

export fn activate() void {
    stem_register_command(CMD_ID.ptr, CMD_ID.len, TITLE.ptr, TITLE.len, DESC.ptr, DESC.len);
}

export fn handle_command(id_ptr: [*]const u8, id_len: i32) void {
    const id = id_ptr[0..@intCast(id_len)];
    if (std.mem.eql(u8, id, CMD_ID)) {
        const msg = "hello from wasm";
        stem_log(1, msg.ptr, msg.len);
    }
}
```

The bundled `echo`, `git`, and `plugin_manager` plugins are the
current references.

## Exec plugins

Exec plugins are ordinary executables. Stem spawns the process and
uses JSON-RPC 2.0 over stdio with LSP-style framing:

```text
Content-Length: <bytes>\r\n
\r\n
{"jsonrpc":"2.0","method":"plugin/log","params":{"level":1,"message":"ready"}}
```

Host → plugin notifications:

| Method | Purpose |
|---|---|
| `plugin/initialize` | First message after spawn. |
| `command/execute` | User invoked a command owned by the plugin. |
| `plugin/shutdown` | Request a clean exit. |

Plugin → host notifications:

| Method | Purpose |
|---|---|
| `plugin/log` | Write a log line. |
| `plugin/registerCommand` | Register a runtime command. |
| `plugin/subscribeEvent` | Subscribe to an event topic; permission is checked, broadcast delivery is still pending. |
| `editor/showNotification` | Host accepts the message; visible UI presentation is still being wired. |

If your exec plugin sets `"restart": "on_crash"`, the host will
re-spawn it with backoff after an unexpected exit.

## Plugin CLI

Use the built-in CLI for local operator workflows:

```bash
stem plugin list
stem plugin info <name>
stem plugin install <path>
stem plugin remove <name>
stem plugin test <path>
```

`stem plugin test` validates the manifest and entry artifact. For
wasm plugins it also decodes the module and runs `activate()` against
mocked host imports.

## Bundled plugins

| Name | Runtime | Commands |
|---|---|---|
| `echo` | wasm | `echo.hello` |
| `git` | wasm | `git.status`, `git.diff`, `git.diff_staged` |
| `plugin_manager` | wasm | `plugin-manager.stats`, `plugin-manager.reload_all`, `plugin.load`, `plugin.unload` |

## Current limitations

- Broadcast event delivery into plugins is not complete. Subscription
  permission is checked, but the host doesn't yet bridge events to
  exec or wasm runtimes.
- Notification callbacks exist in both runtimes, but the main UI loop
  still needs to render them as in-editor toasts.
- Panel and status-item UI extension APIs are not yet exposed as host
  imports.
- `filesystem` permissions are stored but not enforced.
- Remote plugin install, signing, and auto-update are future registry
  work.
