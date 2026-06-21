# Stem
 
A modal text editor for the terminal. Built in Zig, with tree-sitter
syntax highlighting and built-in LSP integration for 20+ languages.

Stem aims to keep modal editing approachable: Vim-style modes, a Space
leader, and a discoverable command palette. ZLS is embedded so Zig
works with no setup; other language servers install on request via
`stem lsp install`.

![Zig](https://img.shields.io/badge/zig-0.16%2B-orange)
![Platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20Linux-green)
![License](https://img.shields.io/badge/license-MIT-brightgreen)

## Install

> Prebuilt binaries and one-line install scripts will land with the
> first tagged release. For now, build from source — `zig build` does
> everything end-to-end.

### From source

Requires **Zig 0.16+** and a C compiler. All other dependencies
(tree-sitter, language grammars, ZLS) are fetched by `zig build`.

```bash
git clone https://github.com/ooyeku/stem.git
cd stem
zig build run
```

To build and install:

**macOS / Linux** (bash, zsh, sh):

```bash
./install.sh                  # build ReleaseFast, install, refresh plugins
./install.sh --prefix ~/.local
```

**Windows** (PowerShell 5.1+, no admin needed):

```powershell
.\install.ps1                          # install into %LOCALAPPDATA%\Programs\stem
.\install.ps1 -Prefix C:\tools\stem    # custom prefix
.\install.ps1 -NoPath                  # skip the user-PATH update
```

If PowerShell blocks the script with an execution-policy error,
launch it as `powershell -ExecutionPolicy Bypass -File .\install.ps1`.

Both installers compile from source (`zig build -Doptimize=ReleaseFast`),
copy the binary, install bundled wasm plugins to the system prefix and
refresh the per-user plugin dir at `~/.stem/plugins/`
(`%USERPROFILE%\.stem\plugins\` on Windows), and add the bin dir to PATH
when it isn't already there.

### Uninstall

```bash
./uninstall.sh             # remove the binary and bundled plugins
./uninstall.sh --purge     # also remove ~/.stem (config, logs, LSP cache)
```

```powershell
.\uninstall.ps1            # remove binary, plugins, and PATH entry
.\uninstall.ps1 -Purge     # also remove %APPDATA%\stem + %LOCALAPPDATA%\stem
```

## Features

- Modal editing — Select, Insert, Visual, View, and Terminal modes
- Multi-buffer workflow with a tab bar
- Horizontal and vertical split panes
- Transactional undo/redo with cursor restoration
- Multi-cursor editing (Sublime-style `Ctrl+D` add-next-occurrence)
- Vim-style text objects (`w` `W` `p` `"` `(` `[` `{` …) for select inside / around
- Surround commands: wrap selection, change or delete a pair
- Named bookmarks (`m<a-z>` set, `'<a-z>` jump) persisted per project
- Incremental in-buffer search with `/` and `?`, smart-case, live match count
- Project-wide search (`Space /`) with per-match replace confirmation
- Fuzzy file picker, buffer picker, and command palette
- Tree-sitter syntax highlighting for 29 languages
- LSP integration for 23 external language servers plus embedded ZLS
  for Zig (with optional format-on-save)
- LSP code actions (`Space C`), range format (`Space F`), signature
  help (auto-popup in Insert mode), and inlay hints (opt-in)
- Inline diagnostics ("error lens") rendered at end-of-line
- Word-under-cursor highlight after a short idle
- Integrated terminal mode
- Manifest-driven plugin system with wasm/exec runtimes, a Zig SDK,
  bundled examples, and a plugin-manager dashboard
- Auto-completion, hover docs, go-to-definition, references,
  diagnostics, and document symbols (via LSP)
- Jump to next/previous diagnostic (`]d`/`[d`), git hunk (`]g`/`[g`),
  AST sibling (`]s`/`[s`), function (`]m`/`[m`)
- Session restore with crash-recovery snapshots
- Periodic auto-save backups of dirty buffers in `~/.stem/recover/`,
  surfaced at startup if any survived a crash
- Stem Control Center (`stem.control_center`) for runtime, Vigil,
  project-index, LSP, job, plugin, and message-bus health in one view
- Stem Heal (`stem.heal`) for Vigil-backed runtime recovery
  recommendations and watchdog guidance
- Project Brain (`project.brain`) for workspace index state, open
  languages, diagnostics pressure, and LSP coverage
- Project Tasks (`task.list`) detects common build/test/run commands
  from Zig, Rust, Go, Python, npm, and Make projects; `task.run_build`
  and `task.run_test` execute the preferred detected tasks as retained
  background jobs, with `task.run`, `task.run_dev`, `task.run_lint`,
  and `task.run_format` for matching project scripts; `task.rerun_last`
  launches the most recent project task again
- **Large-file mode**: files past 5 MB / 50k lines auto-degrade —
  tree-sitter, brackets, LSP, and auto-pair disabled so a multi-MB
  log stays responsive. `[LARGE]` badge in the status bar
- Background workspace file index for instant `Find` queries
- CLI search tools (`stem --find`, `--vfind`, `--scope`)

### Language coverage

Syntax highlighting works for:
Zig, Python, JavaScript, TypeScript, TSX, JSON, Bash, Go, HTML, CSS,
Rust, C, C++, Java, Ruby, C#, PHP, Swift, Kotlin, Lua, Dart, Elixir,
Haskell, OCaml, Scala, R, Perl, Erlang, Markdown.

Language servers installable via `stem lsp install <name>`:

| Language | Server | External requirement |
|---|---|---|
| Zig | ZLS (embedded) | — |
| Python | Pyright | Node |
| JavaScript / TypeScript | typescript-language-server | Node |
| Go | gopls | Go |
| Rust | rust-analyzer | — |
| C / C++ | clangd | LLVM / Xcode CLT |
| Ruby | ruby-lsp | Ruby + gem |
| C# | OmniSharp | — |
| Java | jdtls | Java runtime |
| Bash | bash-language-server | Node |
| Lua | lua-language-server | — |
| Swift | sourcekit-lsp | Swift toolchain |
| R | languageserver | R |
| CSS / HTML / JSON | vscode-langservers-extracted | Node |
| PHP | intelephense | Node |
| Perl | perlnavigator | Node |
| Dart | dart language-server | Dart SDK |
| Elixir | elixir-ls | install via brew or releases |
| Erlang | erlang_ls | rebar3 |
| Haskell | haskell-language-server | ghcup |
| Kotlin | kotlin-language-server | brew or releases |
| OCaml | ocaml-lsp-server | opam |
| Scala | metals | coursier |

`stem lsp install all` walks the list and installs every server whose
prerequisites are available.

## Usage

```bash
stem                       # empty buffer
stem myfile.zig            # open a file
stem file1.zig file2.zig   # open multiple files
stem ./src                 # open a directory

# CLI search tools
stem --find "pattern"      # grep-like text search
stem --vfind "pattern"     # interactive visual search
stem --scope file.zig fn   # search within a specific file

# Project/operator tools
stem task list             # detected build/test/run/dev/lint/format tasks
stem task run test         # run the preferred detected test task
stem project inspect       # root, tasks, and cache location
stem project warm          # pre-build the persistent search index
stem logs tail             # latest log tail
stem logs bundle           # write a local debug bundle
stem lsp doctor python     # explain one language server's install state
stem recover list          # session and dirty-buffer recovery artefacts
stem cache status          # cache/plugin/LSP storage sizes

stem --help                # all options
stem --version             # version info
```

## Key bindings

Stem leans on a Space leader and a discoverable command palette
(`Space f`) for most actions. The bindings below cover everyday
editing; everything else is reachable through the palette.

Press `Space ;` (or `Space ?`) at any time to pop up the which-key
reference — it shows every available follow-up key. While in a
chord like `Space l` the popup shows that chord's sub-bindings.

### Modes

| Key | Action |
|-----|--------|
| `i` | Enter Insert mode |
| `v` | Enter Visual mode (selection from cursor) |
| `V` | Visual-select the syntax node under the cursor |
| `t` | Enter Terminal mode |
| `Esc` | Return to Select mode |

### Navigation (Select / Visual)

| Key | Action |
|-----|--------|
| `h` `j` `k` `l` | Move left/down/up/right |
| Arrow keys | Move left/down/up/right |
| `w` `b` `e` | Next / previous / end of word |
| `W` `B` | Next / previous WORD (whitespace-separated) |
| `{` `}` | Previous / next paragraph |
| `Home` / `End` | Start / end of line |
| `PageUp` / `PageDown` | Scroll one page |
| `%` | Jump to matching bracket |
| `[N] motion` | Repeat motion N times (`5j`, `3w`) |
| `[` / `]` | Previous / next buffer (Cmd+Shift on macOS) |
| `]d` / `[d` | Next / previous diagnostic |
| `]g` / `[g` | Next / previous git hunk |
| `]s` / `[s` | Next / previous AST sibling |
| `]m` / `[m` | Next / previous function-like node |

### Search (Select / Visual)

| Key | Action |
|-----|--------|
| `/` | Incremental forward search with live preview + `[i/N]` count |
| `?` | Incremental backward search |
| `n` / `N` | Next / previous match after closing the prompt |
| `Esc` | Cancel search; cursor returns to its starting position |

Search uses smart case: any uppercase character in the query makes
the search case-sensitive; otherwise it's case-insensitive.

### Bookmarks

| Key | Action |
|-----|--------|
| `m<a-z>` | Set bookmark `<x>` at the cursor |
| `'<a-z>` | Jump to bookmark `<x>` (works across files) |

Bookmarks persist per project under `~/.stem/cache/bookmarks/`.
The `bookmark.list` command opens a `[Bookmarks]` overview;
`bookmark.clear_all` removes them.

### Text objects (Select / Visual)

In **select mode**:
- `s i <c>` — select INSIDE `<c>`
- `s a <c>` — select AROUND `<c>`

In **visual mode**, drop the `s` prefix: `i <c>` / `a <c>`.

`<c>` is one of: `w` word, `W` WORD, `p` paragraph, `"` `'` `` ` ``
string literals, `(` `[` `{` `<` matching pairs (use either bracket).

### Surround

| Chord | Action |
|-------|--------|
| `S <c>` (visual) | Wrap the active selection with `<c>` |
| `s d <c>` (select) | Delete the surround pair `<c>` enclosing the cursor |
| `s r <old> <new>` (select) | Replace surround `<old>` with `<new>` |

### Multi-cursor

| Key | Action |
|-----|--------|
| `Ctrl+D` | Add the next occurrence of the word / selection as a secondary cursor |
| `Esc` (select mode) | Clear all secondary cursors |

Typing and backspace replicate at every cursor. Newlines and
line-altering operations collapse back to the primary cursor.

### Save / open / quit

On macOS use `Cmd`, on Linux/Windows use `Ctrl`:

| Key | Action |
|-----|--------|
| `Cmd/Ctrl+S` | Save current buffer |
| `Cmd/Ctrl+O` | Open file picker |
| `Cmd/Ctrl+W` | Close active buffer |
| `Cmd/Ctrl+Q` | Quit |

### Space leader — top level

The highest-frequency actions live as a single key after Space.

| Key | Action |
|-----|--------|
| `Space e` | Open file (tree-shaped explorer — also `Cmd/Ctrl+O`) |
| `Space b` | Buffer picker |
| `Space s` | Save |
| `Space q` | Quit |
| `Space k` | Close current pane / buffer |
| `Space n` / `Space p` | Next / previous buffer |
| `Space [1-9]` | Quick switch to buffer N |
| `Space f` | Command palette (find any command) — `Space :` alias works on terminals that handle Shift+; cleanly |
| `Space /` | Project-wide search & replace |
| `Space ,` / `Space .` | Jump back / forward |
| `Space z` | Center cursor in viewport |
| `Space u` / `Space r` | Undo / redo |
| `Space c` / `Space x` / `Space v` | Copy / cut / paste |
| `Space a` | Code actions (LSP) |
| `Space -` / `Space \|` | Horizontal / vertical split |
| `Space ←/→/↑/↓` | Focus split pane in that direction |
| `Space h` | Help view |
| `Space j` | Background jobs list |
| `Space ;` / `Space ?` | Toggle which-key popup |
| `Space Esc` | Cancel the leader |

### Space leader — chord groups

Related families live under a chord prefix. Tap `Space ;` inside
any chord to see the contents on screen.

#### `Space l` — LSP

| Key | Action |
|-----|--------|
| `Space l d` | Go to definition |
| `Space l r` | Find references |
| `Space l h` | Hover (docs) |
| `Space l a` | Code actions (alias for `Space a`) |
| `Space l f` | Format buffer |
| `Space l F` | Format selection |
| `Space l D` | Diagnostics list |
| `Space l s` | Document symbols |
| `Space l S` | Workspace symbols |
| `Space l t` | Toggle inline diagnostics |
| `Space l i` | Toggle inlay hints |
| `Space l =` | Toggle format-on-save |

Signature help auto-pops above the cursor in Insert mode when you
type `(` or `,`. Dismissed by `)`, Esc, or mode change.

#### `Space g` — Git

| Key | Action |
|-----|--------|
| `Space g d` | Git diff (via bundled git plugin) |

#### `Space w` — Window / splits

| Key | Action |
|-----|--------|
| `Space w -` | Horizontal split |
| `Space w \|` | Vertical split |
| `Space w h/j/k/l` | Focus pane left / down / up / right |
| `Space w q` | Close pane |

#### `Space t` — Toggle

| Key | Action |
|-----|--------|
| `Space t d` | Toggle inline diagnostics |
| `Space t i` | Toggle inlay hints |
| `Space t =` | Toggle format-on-save |

### File explorer (`Space e` — also `Cmd/Ctrl+O`)

The single entry point for opening files. Modal, tree-shaped
overlay rooted at the project root.

| Key | Action |
|-----|--------|
| `↑/↓` or `j/k` | Move selection |
| `→` / `l` | Expand directory |
| `←` / `h` | Collapse directory (or jump to parent) |
| `g` / `G` | Top / bottom of list |
| `Enter` / `Space` | Open file (or toggle directory) |
| `H` | Toggle hidden files |
| `Ctrl+r` | Rebuild tree |
| `Esc` | Close explorer |

### Project-wide search & replace

`Space /` opens the global search panel. Type into the query field;
results populate live across the workspace.

| Key | Action |
|-----|--------|
| `Tab` | Toggle focus between query and replace fields |
| `Enter` | Open the highlighted match |
| `↑` / `↓` | Walk through matches |
| `Ctrl+R` | Start replace-with-confirmation walk |

Inside the replace walk:

| Key | Action |
|-----|--------|
| `y` | Apply replacement at this match, advance |
| `n` | Skip this match, advance |
| `A` | Apply this match and every remaining match silently |
| `q` / `Esc` | Cancel; summary shown in the status bar |

Replacements happen in open buffers (not directly on disk), so you can
undo per-file with `Space u` and only commit by saving.

### Split navigation

| Key | Action |
|-----|--------|
| `Ctrl+h` / `Ctrl+l` | Focus split left / right |
| `Ctrl+j` / `Ctrl+k` | Focus split down / up |

## Configuration

Configuration lives in `~/.stem/`:

```
~/.stem/
├── config.json     # User settings
├── plugins/        # Installed plugins (seeded from bundled on first run)
├── lsp/            # Language servers installed via `stem lsp install`
├── cache/          # Background workspace index, etc.
└── logs/           # Debug logs (stem-*.log)
```

Manage settings from the CLI:

```bash
stem config list
stem config get editor.tab_size
stem config set editor.tab_size 2
stem config reset editor.tab_size
stem config reset --all
```

Or edit `~/.stem/config.json` directly:

```json
{
  "editor": {
    "tab_size": 4,
    "insert_spaces": true,
    "line_numbers": "relative",
    "wrap": false,
    "cursor_line": true,
    "auto_pairs": true,
    "format_on_save": false,
    "inline_diagnostics": true,
    "inlay_hints": false,
    "auto_save_backup": true,
    "auto_save_interval_seconds": 30,
    "large_file_threshold_bytes": 5242880,
    "large_file_threshold_lines": 50000,
    "large_file_hard_limit_bytes": 104857600
  },
  "ui": {
    "show_status_bar": true
  },
  "logging": {
    "level": "info"
  }
}
```

Runtime toggles (via the command palette `Space a`, or `stem config set ...`):

| Setting | Command palette | Effect |
|---------|-----------------|--------|
| `editor.format_on_save` | `lsp.toggle_format_on_save` | Run LSP formatter before each save |
| `editor.inline_diagnostics` | `editor.toggle_inline_diagnostics` | "Error lens" — diagnostic message after every affected line, not just the cursor's |
| `editor.inlay_hints` | `editor.toggle_inlay_hints` | LSP type / param-name hints rendered as dim virtual text |

### Runtime cockpit

The command palette includes `stem.control_center`, a single live
cockpit for Stem's runtime health: Vigil-backed services, message-bus
pressure, open buffers, project index freshness, LSP state, diagnostics,
background jobs, plugins, terminal status, and recommended next actions.
Use `stem.heal` when you want the same Vigil-backed recovery guidance in
a focused, read-only action view; watchdog toasts will point there when
runtime health worsens.

Use `project.brain` when you want a tighter project view: workspace
root, index state, open languages, diagnostics pressure, and per-LSP
coverage. Use `task.list` to see detected project commands from
`build.zig`, `Cargo.toml`, `go.mod`, Python project markers,
`package.json` scripts, and common Make targets. Use `task.run_build`
or `task.run_test` to execute the preferred detected task under Stem's
background job manager; `task.run`, `task.run_dev`, `task.run_lint`,
and `task.run_format` cover run/start, dev, lint, and format tasks. Use
`task.rerun_last` to launch the most recent task again, and `task.output`
to reopen the latest retained stdout/stderr report.
The same detector is available from the shell with `stem task list`,
`stem task run <id|kind>`, and `stem task doctor`.

### Large-file mode

When a buffer exceeds `large_file_threshold_bytes` (default 5 MB)
or `large_file_threshold_lines` (default 50 000), Stem opens it in
**large-file mode**: tree-sitter syntax highlighting, bracket
rainbow, LSP requests, and bracket auto-pair are disabled for
that buffer. The status bar shows a yellow `[LARGE]` badge so the
quiet behaviour isn't mysterious. Files past
`large_file_hard_limit_bytes` (default 100 MB) are rejected at
open time. All three thresholds are per-buffer at open and sticky
for the buffer's life — re-open after `stem config set ...` to
re-classify.

### Auto-save backups

While stem is running, every `auto_save_interval_seconds` (default
30 s) it writes a snapshot of every dirty buffer to
`~/.stem/recover/<hash>.bak` with a `.path` sidecar recording the
original filename. On the next startup, if any backups survived,
the status bar prompts you to run `buffer.restore_backups` to
view them. From a shell, `stem recover list` shows the same artefacts
and `stem recover restore <id>` copies a snapshot back to its recorded
path. Disable with `stem config set editor.auto_save_backup false`.

## Platform support

| Platform | Status | Notes |
|----------|--------|-------|
| macOS (ARM64) | Supported | Primary development target |
| macOS (x86_64) | Supported | |
| Linux (x86_64) | Supported | |
| Linux (ARM64) | Supported | |
| Windows | Experimental | No integrated terminal |

## Building from source

```bash
zig build                                  # Debug
zig build run                              # Debug + run
zig build -Doptimize=ReleaseFast           # Release
zig build test                             # Tests
zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseFast
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseFast    # experimental
```

| Option | Description |
|--------|-------------|
| `-Doptimize=ReleaseFast` | Optimised build |
| `-Doptimize=ReleaseSafe` | Optimised with safety checks |
| `-Doptimize=ReleaseSmall` | Optimised for size |

## Architecture

```
src/
├── main.zig           # Entry point and CLI handling
├── cli.zig            # Subcommand dispatch (config, logs, lsp, plugin)
├── kernel/            # Event loop, buffer manager, sessions, commands
├── core/              # Piece-table buffer, editor state, file I/O
├── ui/                # Terminal rendering (vaxis), pickers, themes
├── syntax/            # Tree-sitter integration and language queries
├── services/          # LSP, logging, terminal, global search
├── lsp/               # LSP protocol client and transport
├── plugins/           # Manifest, wasm interpreter, exec runtime
├── config/            # Config schema, keys, persistent storage
├── tools/             # CLI tools (find, vfind, scope, plugin, operator commands)
└── fuzz/              # Fuzz targets (piece table, state, URIs)
```

### Dependencies

All Zig dependencies are pinned in [build.zig.zon](build.zig.zon):

- [libvaxis](https://github.com/rockorager/libvaxis) — terminal UI
- [vigil](https://github.com/ooyeku/vigil) — actor-style message passing
- [zls](https://github.com/zigtools/zls) — embedded Zig LSP
- [lsp-kit](https://github.com/zigtools/lsp-kit) — LSP protocol types
- [uucode](https://github.com/jacobsandlund/uucode) — Unicode tables
- [tree-sitter](https://github.com/tree-sitter/tree-sitter) plus
  per-language grammars

## Plugins

Bundled plugins are installed into `~/.stem/plugins/<name>/` with a
`plugin.json` manifest. Both wasm modules and child-process exec
plugins are supported.

| Plugin | Runtime | Description |
|--------|---------|-------------|
| `echo` | wasm | Reference plugin: a single command that pops a notification |
| `git` | wasm | Status / diff / staged-diff plus a live branch indicator |
| `plugin_manager` | wasm | SDK-backed dashboard, raw JSON, permissions, storage health, and reload commands |
| `sdk_demo` | wasm | SDK example covering commands, events, status items, panels, active-buffer reads, dashboard data, and plugin storage |

See [docs/plugins.md](docs/plugins.md) for the full author guide
and host internals, including the SDK at
[bundled/plugins/sdk/stem.zig](bundled/plugins/sdk/stem.zig).

## Troubleshooting

**An LSP isn't working for a language.** Run
`stem lsp install <language>` and check `stem logs`. Bump verbosity
with `stem config set logging.level debug`.

**Colours look wrong.** Make sure your terminal advertises 24-bit
colour: `export COLORTERM=truecolor`.

**`./install.sh` says "no write access to /usr/local".** Either
re-run with `--prefix $HOME/.local` (no sudo needed), or grant sudo
access.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make sure `zig build` and `zig build test` pass
4. Cross-check at least one other target:
   `zig build -Dtarget=x86_64-linux-gnu`
5. Open a pull request

## Documentation

- [Plugins](docs/plugins.md) — author guide + host internals
- [stem.md](docs/stem.md) — long-form reference

## License

[MIT License](LICENSE)

## Acknowledgments

- Modal-editing ideas from [Vim](https://www.vim.org/),
  [Kakoune](https://kakoune.org/), and [Helix](https://helix-editor.com/)
- Built with [Zig](https://ziglang.org/)
- Syntax highlighting powered by
  [tree-sitter](https://tree-sitter.github.io/)
