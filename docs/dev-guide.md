# Stem Developer Guide

A map of the codebase and the moving parts inside it.

## Contents

- [Architecture overview](#architecture-overview)
- [Systems reference](#systems-reference)
- [Languages](#languages)
- [Build, test, run](#build-test-run)
- [Layout reference](#layout-reference)

## Architecture overview

Stem is built around message passing between three long-running threads
plus a heartbeat:

1. **Input thread** — captures terminal events through `vaxis` and posts
   them to the main inbox.
2. **Core thread** — owns the editor state machine. Drains the core
   inbox, runs commands, and posts render snapshots back to the UI.
3. **UI thread (main)** — consumes render snapshots and draws frames
   with `vaxis`.

A 100 ms heartbeat thread ticks the core inbox so timers (hover delay,
debounced LSP updates, recovery snapshots, etc.) can fire without
incoming input. LSP servers run in their own threads (one per
language, plus the embedded ZLS) and exchange JSON-RPC frames over a
zero-copy in-memory pipe.

All inter-thread channels are [`vigil`](https://github.com/ooyeku/vigil)
inboxes carrying binary-encoded protocol messages from
`src/kernel/protocol.zig`.

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│ Input thread│────▶│   Core      │────▶│  UI thread  │
│   (vaxis)   │     │  (kernel)   │     │   (view)    │
└─────────────┘     └──────┬──────┘     └─────────────┘
                           │
                  ┌────────┴────────┐
                  │  LSP threads    │
                  │  Plugin runtime │
                  │  Job manager    │
                  └─────────────────┘
```

## Systems reference

### Editor core

| Subsystem | Description | Files |
|---|---|---|
| Core engine | Event loop, mode switching, leader-chord dispatch | [src/kernel/core.zig](../src/kernel/core.zig) |
| Protocol | Binary message encoding | [src/kernel/protocol.zig](../src/kernel/protocol.zig) |
| Command registry | Named commands with fuzzy palette search | [src/kernel/command.zig](../src/kernel/command.zig) |
| Modular commands | Edit / LSP / split / git / build / nav / system / plugin groups | [src/kernel/commands/](../src/kernel/commands/) |
| Message bus | Coalescing inbox for render snapshots | [src/kernel/message_bus.zig](../src/kernel/message_bus.zig) |
| Request/reply | Synchronous-over-async helpers for cross-thread calls | [src/kernel/request_reply.zig](../src/kernel/request_reply.zig) |
| Arena pool | Per-frame arena reuse for the snapshot path | [src/kernel/arena_pool.zig](../src/kernel/arena_pool.zig) |
| Platform | OS-specific syscalls (process id, signal install) | [src/kernel/platform.zig](../src/kernel/platform.zig) |
| Filetype | Path → language detection used by syntax/LSP | [src/kernel/filetype.zig](../src/kernel/filetype.zig) |
| Safe primitives | Wrappers that promote panics to errors | [src/kernel/safe.zig](../src/kernel/safe.zig) |
| Entry point | Boot sequence, thread spawning, signal handling, panic crash dump | [src/main.zig](../src/main.zig) |

### Buffers and text

| Subsystem | Description | Files |
|---|---|---|
| Buffer manager | Open buffers, switching, file I/O, `opened_from` trigger snapshots, large-file mode | [src/kernel/buffer_manager.zig](../src/kernel/buffer_manager.zig) |
| Piece table | Buffer storage with O(visible) line extraction | [src/core/piece_table.zig](../src/core/piece_table.zig) |
| Editor state | Cursor, selection, scroll, word motions, paragraph jumps, multi-cursor | [src/core/state.zig](../src/core/state.zig) |
| Unicode helpers | Grapheme + word classification used by motions | [src/core/unicode.zig](../src/core/unicode.zig) |
| Auto-pair | Bracket / quote auto-pair on insert | [src/core/auto_pair.zig](../src/core/auto_pair.zig) |
| File manager | File reading / atomic save with fsync | [src/core/file_manager.zig](../src/core/file_manager.zig) |
| File explorer | Modal tree-shaped file opener (Space e) | [src/kernel/file_explorer.zig](../src/kernel/file_explorer.zig) |
| Bookmarks | Per-project `m<a-z>` / `'<a-z>` slot store, persisted under `~/.stem/cache/bookmarks/` | [src/kernel/bookmarks.zig](../src/kernel/bookmarks.zig) |
| Jump list | Back/forward stack used by `Space , / .` and `Ctrl+O / Ctrl+I` | [src/kernel/jump_list.zig](../src/kernel/jump_list.zig) |
| History | Transactional undo / redo with cursor restore | [src/kernel/history.zig](../src/kernel/history.zig) |
| Virtual file system | `file://`, `memory://`, `git://` schemes | [src/kernel/vfs.zig](../src/kernel/vfs.zig) |
| Sessions | Per-workspace session save + crash-recovery snapshot + autosave `.bak` files | [src/kernel/session.zig](../src/kernel/session.zig), [src/config/storage.zig](../src/config/storage.zig) |

### UI

| Subsystem | Description | Files |
|---|---|---|
| Main view | Window composition, line drawing, overlays, picker rendering | [src/ui/view.zig](../src/ui/view.zig) |
| Status bar | Mode indicator, cursor position, branch, large-file badge, jump-list count | [src/ui/status_bar.zig](../src/ui/status_bar.zig) |
| Tab bar | Open buffers with modified marker | [src/ui/tab_bar.zig](../src/ui/tab_bar.zig) |
| File picker | Directory-listing picker (legacy; reachable via palette `file.open`) | [src/ui/file_picker.zig](../src/ui/file_picker.zig) |
| Buffer picker | Buffer switcher overlay | [src/ui/buffer_picker.zig](../src/ui/buffer_picker.zig) |
| Which-key popup | Top-level + chord-aware leader popup | [src/ui/which_key.zig](../src/ui/which_key.zig) |
| Width helpers | Grapheme + ANSI-aware width math used by the renderer | [src/ui/width.zig](../src/ui/width.zig) |
| Help view | Markdown-rendered help | [src/ui/help.zig](../src/ui/help.zig), [src/ui/help_view.zig](../src/ui/help_view.zig) |
| Log view | Live log overlay | [src/ui/log_view.zig](../src/ui/log_view.zig) |
| Theme | One Dark-inspired colour palette | [src/ui/theme.zig](../src/ui/theme.zig) |

### Syntax

| Subsystem | Description | Files |
|---|---|---|
| Syntax manager | Parser lifecycle, language detection, async parses | [src/syntax/manager.zig](../src/syntax/manager.zig) |
| Tree-sitter bindings | C FFI for tree-sitter | [src/syntax/tree_sitter.zig](../src/syntax/tree_sitter.zig) |
| Queries | Highlight queries for each language | [src/syntax/queries/](../src/syntax/queries/) |

Parses run on a background worker; the core thread polls
`tree_updated` on tick and triggers a re-render once a fresh tree is
installed.

### LSP

| Subsystem | Description | Files |
|---|---|---|
| LSP manager | Per-language server lifecycle, request routing, debounced `didChange` | [src/services/lsp_manager.zig](../src/services/lsp_manager.zig) |
| LSP server | Per-server request bookkeeping | [src/services/lsp/server.zig](../src/services/lsp/server.zig) |
| External LSP | Child-process LSP wrapper with global kill registry | [src/services/lsp/external.zig](../src/services/lsp/external.zig) |
| Installer | On-demand server install for 23 languages | [src/services/lsp/installer.zig](../src/services/lsp/installer.zig) |
| Supervisor | Worker that processes serialised LSP commands | [src/services/lsp/supervisor.zig](../src/services/lsp/supervisor.zig) |
| Embedded ZLS | In-process Zig LSP | [src/services/lsp/zls_embedded.zig](../src/services/lsp/zls_embedded.zig) |
| Transport | In-memory pipe used by embedded ZLS | [src/lsp/transport.zig](../src/lsp/transport.zig) |

### Plugins

| Subsystem | Description | Files |
|---|---|---|
| Plugin manager | Manifest discovery, command registration, permission checks, restart policy | [src/plugins/manager.zig](../src/plugins/manager.zig) |
| Manifest | `plugin.json` schema, including restart policy | [src/plugins/manifest.zig](../src/plugins/manifest.zig) |
| Exec runtime | Child-process plugins over JSON-RPC | [src/plugins/process_loader.zig](../src/plugins/process_loader.zig), [src/plugins/jsonrpc.zig](../src/plugins/jsonrpc.zig) |
| Wasm runtime | Pure-Zig interpreter and host imports | [src/plugins/wasm/interpreter.zig](../src/plugins/wasm/interpreter.zig), [src/plugins/wasm/loader.zig](../src/plugins/wasm/loader.zig) |
| Plugin inspect | In-process debug helpers (`stem plugin info`) | [src/plugins/inspect.zig](../src/plugins/inspect.zig) |
| Plugin CLI | `stem plugin list/info/install/remove/test` | [src/tools/plugin_cli.zig](../src/tools/plugin_cli.zig) |

Bundled plugins: `echo`, `git`, and `plugin_manager` — all wasm.

For the full author guide and host internals see [plugins.md](plugins.md).

### Configuration

| Subsystem | Description | Files |
|---|---|---|
| Schema | Config struct, getters / setters | [src/config/schema.zig](../src/config/schema.zig) |
| Storage | Directory creation, atomic JSON writes | [src/config/storage.zig](../src/config/storage.zig) |
| Keybindings | Keymap constants | [src/config/keys.zig](../src/config/keys.zig) |

User data lives under `~/.stem/`: `config.json`, `plugins/`, `lsp/`,
`cache/`, `logs/`.

### Workspace & build

| Subsystem | Description | Files |
|---|---|---|
| Workspace manager | Detects Zig project roots from `build.zig` | [src/kernel/workspace.zig](../src/kernel/workspace.zig) |
| Build jobs | Runs `zig build` / `zig build test` with diagnostic parsing | [src/kernel/build_jobs.zig](../src/kernel/build_jobs.zig) |
| Job manager | Cancellable background tasks | [src/kernel/jobs.zig](../src/kernel/jobs.zig) |
| Decorations | Line-indexed overlays for search, diagnostics, git hunks, word highlight, bookmarks, multi-cursor markers | [src/kernel/decorations.zig](../src/kernel/decorations.zig) |
| Terminal process | PTY/exec backing for `t` terminal mode | [src/kernel/terminal_proc.zig](../src/kernel/terminal_proc.zig) |

### Splits & panes

| Subsystem | Description | Files |
|---|---|---|
| Split manager | Tree-based horizontal/vertical splits with per-pane state | [src/kernel/split_manager.zig](../src/kernel/split_manager.zig) |

### CLI tools

| Subsystem | Description | Files |
|---|---|---|
| Search | `stem --find` (`std.Thread.Pool` work-stealing) | [src/tools/search.zig](../src/tools/search.zig) |
| Visual find | `stem --vfind` (vigil actor model) | [src/tools/vfind.zig](../src/tools/vfind.zig) |
| Scope | `stem --scope` for in-file search | [src/tools/scope.zig](../src/tools/scope.zig) |
| Format | Code formatting subcommand | [src/tools/format.zig](../src/tools/format.zig) |
| Query check | Validate tree-sitter queries | [src/tools/query_check.zig](../src/tools/query_check.zig) |
| Plugin CLI | Plugin lifecycle subcommand | [src/tools/plugin_cli.zig](../src/tools/plugin_cli.zig) |

### Services

| Subsystem | Description | Files |
|---|---|---|
| Logger | File-backed logging at `~/.stem/logs/stem-*.log` | [src/services/logger.zig](../src/services/logger.zig) |
| Terminal | Integrated terminal mode | [src/services/terminal.zig](../src/services/terminal.zig) |
| Hover doc parser | Markdown → structured hover document used by the popup renderer | [src/services/hover_doc.zig](../src/services/hover_doc.zig) |
| Global search | Project-wide grep with parallel workers + replace-with-confirmation walk | [src/services/global_search.zig](../src/services/global_search.zig) |
| Search index | Background workspace file-list cache for `Find` | [src/services/search_index.zig](../src/services/search_index.zig) |
| Telemetry | Lightweight in-process counters | [src/services/telemetry.zig](../src/services/telemetry.zig) |
| Thread name | Setter + step-marker for OS thread labels (used in profiling) | [src/services/thread_name.zig](../src/services/thread_name.zig) |

## Languages

Tree-sitter syntax highlighting is wired up for 29 languages:
Zig, Python, Go, JavaScript, TypeScript, TSX, JSON, Bash, HTML, CSS,
Rust, C, C++, Java, Ruby, C#, PHP, Swift, Kotlin, Lua, Dart, Elixir,
Haskell, OCaml, Scala, R, Perl, Erlang, Markdown.

LSP integration is available for 23 external servers (see the
[README's language table](../README.md#language-coverage)) plus
embedded ZLS for Zig. Servers install on demand:

```bash
stem lsp install <language>     # one server
stem lsp install all            # every server whose prerequisites are met
stem lsp list                   # what's installed
```

## Build, test, run

```bash
zig build                                 # Debug build
zig build run                             # Debug + run
zig build -Doptimize=ReleaseFast          # Release
zig build test                            # Unit tests
zig build fuzz                            # Fuzz suite (macOS)
zig build test --fuzz                     # Fuzz suite (Linux)
./install.sh                              # Build ReleaseFast + install
```

Fuzz targets live in [src/fuzz/](../src/fuzz/) — piece table, editor
state, and URI parsing.

## Layout reference

```
src/
├── main.zig
├── cli.zig                # Subcommand dispatch
├── kernel/                # Core editor logic
│   ├── commands/          # buffer/edit/file/git/lsp/nav/split/system/build/plugin
│   ├── core.zig
│   ├── protocol.zig
│   ├── command.zig
│   ├── arena_pool.zig
│   ├── buffer_manager.zig
│   ├── bookmarks.zig
│   ├── jump_list.zig
│   ├── file_explorer.zig
│   ├── filetype.zig
│   ├── history.zig
│   ├── message_bus.zig
│   ├── platform.zig
│   ├── request_reply.zig
│   ├── safe.zig
│   ├── session.zig
│   ├── split_manager.zig
│   ├── terminal_proc.zig
│   ├── workspace.zig
│   ├── build_jobs.zig
│   ├── jobs.zig
│   ├── decorations.zig
│   └── vfs.zig
├── core/                  # Buffer primitives
│   ├── piece_table.zig
│   ├── state.zig
│   ├── file_manager.zig
│   ├── unicode.zig
│   └── auto_pair.zig
├── ui/                    # Rendering
│   ├── view.zig
│   ├── status_bar.zig
│   ├── tab_bar.zig
│   ├── file_picker.zig
│   ├── buffer_picker.zig
│   ├── which_key.zig
│   ├── width.zig
│   ├── help.zig
│   ├── help_view.zig
│   ├── log_view.zig
│   └── theme.zig
├── syntax/                # Tree-sitter + .scm queries
├── services/              # LSP, logging, search, hover docs, terminal
│   ├── hover_doc.zig
│   ├── thread_name.zig
│   └── lsp/
├── lsp/                   # Protocol client + in-memory transport
├── plugins/               # Wasm + exec runtimes, manifest parser
├── config/                # Schema, keys, storage
├── tools/                 # CLI subcommands
└── fuzz/                  # Fuzz targets
bundled/plugins/           # Wasm artifacts shipped with the binary
docs/                      # This guide and related docs
scripts/                   # Install scripts and shell completions
```

### User data

| Path | Purpose |
|---|---|
| `~/.stem/config.json` | User configuration |
| `~/.stem/plugins/` | Installed plugins |
| `~/.stem/lsp/` | LSP servers installed via `stem lsp install` |
| `~/.stem/cache/` | Search index, etc. |
| `~/.stem/logs/stem-*.log` | Rolling log files |
