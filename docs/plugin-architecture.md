# Plugin Architecture

## Current state: Phase 0 (shipped)

**ABI version 3.** Plugins talk to stem through a small C-ABI boundary
defined in [src/plugins/abi.zig](../src/plugins/abi.zig). The boundary
permanently eliminates the struct-layout-drift segfaults that bit v1/v2.

The contract:

```
              Plugin (.dylib)                 Host (stem binary)
              ----------------                ------------------
  ┌────────────────────────────────┐
  │  export const plugin_entry:    │     ──dlopen──► resolves to
  │      PluginInterface = …;      │                 stem's `stem_*`
  │                                │                 exported fns
  │  Plugin receives:              │
  │  - PluginHandle (extern u64)   │
  │  - msg byte buffers            │
  │                                │
  │  Plugin calls:                 │
  │  - stem_send_to_core(h, …)     │  ◄──┐
  │  - stem_send_to_ui(h, …)       │     ├─ all C-ABI; no Zig
  │  - stem_log(h, …)              │     │  structs cross
  │  - stem_plugin_id(h)           │  ◄──┘
  └────────────────────────────────┘
```

Three lifecycle hooks: `activate(handle)`, `handle_message(handle, ptr, len)`,
`deactivate(handle)`. All take the handle by value; nothing else crosses.

Reading list:

- [src/plugins/abi.zig](../src/plugins/abi.zig) — the boundary spec.
- [src/plugins/host_abi.zig](../src/plugins/host_abi.zig) — host-side
  handle registry and `stem_*` exports.
- [src/sdk/api.zig](../src/sdk/api.zig) — plugin SDK (the Zig API
  authors actually use; thin wrappers over the C ABI).
- [bundled/plugins/git/src/main.zig](../bundled/plugins/git/src/main.zig)
  — reference plugin written against v3.

## Roadmap

### Phase 1: out-of-process plugins (next)

Goal: plugins that need OS access (spawn processes, walk worktrees,
talk to the network) live in their own executable and speak JSON-RPC
to stem over stdio. Same wire schema as wasm plugins (phase 2). The
git plugin is the natural first migration.

Pieces to build:

1. **`src/plugins/schema.zig`** — single source-of-truth catalog of
   every host capability + every plugin event. JSON-Schema-shaped Zig
   data; both the wire encode/decode and the manifest validator
   generate from it.
2. **`src/plugins/process_loader.zig`** — spawn an executable plugin,
   pipe JSON-RPC requests/responses over its stdin/stdout, route
   notifications into the existing PluginManager event bus. Reuses the
   `vigil.supervisor` pattern from the LSP supervisor.
3. **`plugin.toml`** manifests — declare commands, keybinds, event
   subscriptions, capabilities (`spawn`, `filesystem`, …), and the
   plugin runtime (`dylib | exec | wasm`).
4. **Git plugin migration** — same Zig source, different build target
   (exe instead of dylib). Validates the schema + IPC layer.

Estimated effort: 5–7 days.

### Phase 2: WebAssembly plugins (shipped)

WASM plugins run inside stem's own pure-Zig interpreter — no
transitive C deps, no subprocess. Sandboxed by default, single-file
distribution, any-language source.

Shipped pieces:

1. **Pure-Zig WASM interpreter** — `src/plugins/wasm/interpreter.zig`.
   Handles the wasm 1.0 core subset stem plugins need: module decode
   (type/import/function/memory/global/export/start/code/data
   sections), linear memory with grow, globals, block/loop/if/else
   control flow, br/br_if/br_table, full i32 + i64 ALU, memory
   loads/stores with sign extension, drop/select, host imports.
   Unsupported opcodes (floats, SIMD, tables, refs) abort with
   `error.UnsupportedOp` rather than silently miscompile.
2. **Host imports** in `src/plugins/wasm/loader.zig`:
   `env.stem_log`, `env.stem_register_command`,
   `env.stem_show_notification`. Same surface area as Phase 1
   JSON-RPC, but with `(ptr, len)` pointer pairs into wasm linear
   memory instead of JSON envelopes.
3. **Build pipeline** — `build.zig` adds a `wasm32-freestanding`
   target for the canary plugin. The output `.wasm` is installed
   alongside the dylibs and `stem-echo`.
4. **Canary plugin** — `bundled/plugins/echo-wasm/`. Imports the host
   surface, exports `activate` (which registers a command) and
   `handle_command` (which logs a greeting when the command fires).
   `tryLoadPluginDir` dispatches `runtime: "wasm"` manifests to the
   wasm loader; cleanup mirrors the dylib + process paths.

End-to-end integration test (`zig build test`) loads the built
`.wasm`, drives `activate` and `handle_command`, and asserts the host
callbacks fired.

### Phase 3: polish + deprecate (shipped)

Shipped pieces:

1. **Manifest-driven palette** — `loadProcessPluginFromManifest` and
   `loadWasmPluginFromManifest` walk `m.commands` and register each
   one in the command palette BEFORE the plugin starts. Commands stay
   visible even if `activate` traps later, and runtime self-registers
   for the same id are deduped silently.
2. **Permissions enforcement** — manifest `permissions` are duped into
   `PluginManager.plugin_permissions` at load time. The first
   enforcement point is `plugin/subscribeEvent`: process plugins that
   try to subscribe to an event not listed in their manifest (or not
   covered by a trailing `*` glob) get a soft denial with an audit log
   line. The same `permissionAllows()` helper is the hook for future
   spawn / filesystem checks.
3. **`stem plugin` CLI** — `src/tools/plugin_cli.zig`:
   - `stem plugin list` — every installed plugin with version + runtime.
   - `stem plugin info <name>` — pretty-prints the manifest.
   - `stem plugin install <path>` — copies a plugin dir into
     `~/.stem/plugins`. Refuses to overwrite (use `remove` first).
   - `stem plugin remove <name>` — deletes the install dir.
   - `stem plugin test <path>` — hermetic smoke test. For wasm,
     decodes the module, runs `activate` against mocked host imports
     (capturing `stem_register_command` and `stem_log` calls), and
     reports which manifest-declared commands weren't re-registered.
     For exec/dylib it verifies the entry artifact exists and the
     symbol/binary is loadable.
4. **Deprecation warning** — flat `.dylib` loads via `loadPlugin()`
   now log a one-shot warning pointing operators at the manifest-dir
   layout. Loading still works (no behavioral change), but the
   warning surfaces in `stem logs` so it's visible in audits.

Open follow-ups (intentionally deferred):

- `stem plugin install <url>` — needs an HTTP client + checksum check.
- Process plugin event-subscription wiring (`broadcastEvent` -> the
  process plugin map) — once that lands, subscribed events will
  actually deliver, gated by the permission check above.
- `stem plugin test` for exec plugins — spawn the child with mocked
  stdio rather than just checking that the binary exists.

### Phase 4: registry / marketplace

1. **Plugin registry** (start with a JSON in the repo, graduate to a
   hosted index).
2. **Signed plugins** (sigstore-style) so users can trust binaries.
3. **Auto-update** with version pinning.

Estimated effort: ongoing.

## Design principles (apply to every phase)

1. **No Zig structs cross the plugin boundary.** Lessons from v1/v2:
   the moment a non-`extern` Zig type has a field whose layout depends
   on transitive imports, two compilations of the same source can
   disagree by bytes. Stick to `extern struct` for boundary types and
   schema-versioned bytes for everything else.

2. **One inbound channel, one outbound channel.** The plugin sees
   exactly one entry point (`handle_message`) and exactly one outbound
   primitive (`stem_send_to_*`). Every feature (commands, events,
   request/reply) is built on top of that pair. Adding a new
   capability is a schema change, not a new C symbol.

3. **Request/reply uses correlation IDs.** No global single-slot
   callbacks. Multiple concurrent requests of the same kind must
   coexist. Already implemented via
   [src/kernel/request_reply.zig](../src/kernel/request_reply.zig).

4. **Capabilities are declared up front.** Plugins announce required
   permissions in their manifest. The host enforces. No "plugin can
   silently do anything" surprises.

5. **Crash isolation lives at the runtime boundary.** v3 keeps the
   signal-handler trick for .dylib plugins as a backstop, but WASM
   plugins (phase 2) get real isolation by construction — a trap is
   caught by the wasm runtime, not by `siglongjmp`.

## Concrete files added in Phase 0

| File | Purpose |
|---|---|
| `src/plugins/abi.zig` | Boundary types + `extern fn` host imports. The only file plugins are allowed to depend on for boundary types. |
| `src/plugins/host_abi.zig` | Host handle registry + `export fn stem_*` implementations. |
| `src/plugins/interface.zig` | Slim re-export shim — kept for backwards-source-compatibility. |
| `src/plugins/context.zig` | Compatibility shim for host-side code that still passes a `PluginContext` value around. **Plugins do NOT see this type.** |
| `src/sdk/api.zig` | Rewritten plugin SDK. Thin Zig wrappers over the C ABI. Manages per-plugin command/event registries and the request tracker. |
| `src/stem_plugin.zig` | Public `@import("stem")` surface for plugin authors. |
| `src/tools/plugin_probe.zig` | CLI tool: `STEM_PROBE_PATH=…/lib.dylib plugin-probe`. Prints the plugin's stamped ABI version and capabilities. |
