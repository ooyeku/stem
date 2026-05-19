# Stem

A modal text editor for the terminal. Built in Zig, with tree-sitter
syntax highlighting and built-in LSP integration for 20+ languages.

Stem aims to keep modal editing approachable: Vim-style modes, a Space
leader, and a discoverable command palette. ZLS is embedded so Zig
works with no setup; other language servers install on request via
`stem lsp install`.

![Version](https://img.shields.io/badge/version-0.4.0-blue)
![Zig](https://img.shields.io/badge/zig-0.16%2B-orange)
![Platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20Linux-green)
![License](https://img.shields.io/badge/license-MIT-brightgreen)

## Install

### Prebuilt binary (macOS / Linux)

Download the install script, review it, and run it:

```bash
curl -fsSLO https://raw.githubusercontent.com/ooyeku/stem/main/scripts/install.sh
less install.sh                  # review what it does
sh install.sh                    # run it once you're satisfied
```

The script downloads the latest release archive for your platform,
verifies its SHA-256 against the published `.sha256`, and installs
`stem` to `/usr/local/bin` (or `~/.local/bin` if `/usr/local` isn't
writable).

Pin a specific release with `STEM_VERSION` and the install prefix
with `STEM_PREFIX`:

```bash
STEM_VERSION=v0.4.0 STEM_PREFIX=$HOME/.local sh install.sh
```

### From source

Requires **Zig 0.16+** and a C compiler. All other dependencies
(tree-sitter, language grammars, ZLS) are fetched by `zig build`.

```bash
git clone https://github.com/ooyeku/stem.git
cd stem
zig build run
```

To build and install system-wide from source:

```bash
./install.sh                  # builds ReleaseFast and installs
./install.sh --prefix ~/.local
```

### Uninstall

```bash
./uninstall.sh             # remove the binary and bundled plugins
./uninstall.sh --purge     # also remove ~/.stem (config, logs, LSP cache)
```

## Features

- Modal editing — Select, Insert, Visual, View, and Terminal modes
- Multi-buffer workflow with a tab bar
- Horizontal and vertical split panes
- Transactional undo/redo with cursor restoration
- Fuzzy file picker, buffer picker, and command palette
- Project-wide search (`Space /`) with replace
- Tree-sitter syntax highlighting for 29 languages
- LSP integration for 23 external language servers plus embedded ZLS
  for Zig
- Integrated terminal mode
- Manifest-driven plugin system with wasm and exec runtimes
- Auto-completion, hover docs, go-to-definition, references,
  diagnostics, and document symbols (via LSP)
- Session restore with crash-recovery snapshots
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

stem --help                # all options
stem --version             # version info
```

## Key bindings

Stem leans on a Space leader and a discoverable command palette
(`Space a`) for most actions. The bindings below cover everyday
editing; everything else is reachable through the palette.

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
| `Home` / `End` | Start / end of line |
| `PageUp` / `PageDown` | Scroll one page |
| `[` / `]` | Previous / next buffer (Cmd+Shift on macOS) |

### Save / open / quit

On macOS use `Cmd`, on Linux/Windows use `Ctrl`:

| Key | Action |
|-----|--------|
| `Cmd/Ctrl+S` | Save current buffer |
| `Cmd/Ctrl+O` | Open file picker |
| `Cmd/Ctrl+W` | Close active buffer |
| `Cmd/Ctrl+Q` | Quit |

### Space leader

| Key | Action |
|-----|--------|
| `Space a` | Command palette |
| `Space f` | File picker (fuzzy) |
| `Space b` | Buffer picker |
| `Space /` | Project-wide search & replace |
| `Space s` | Save |
| `Space q` | Quit |
| `Space k` | Close current pane / buffer |
| `Space w` | Help view |
| `Space n` / `Space p` | Next / previous buffer |
| `Space u` / `Space r` | Undo / redo |
| `Space c` / `Space x` / `Space v` | Copy / cut / paste |
| `Space -` / `` Space ` `` | Horizontal / vertical split |
| `Space ←/→/↑/↓` | Focus split pane in that direction |
| `Space g` | LSP go-to-definition |
| `Space l` | LSP find references |
| `Space h` | LSP hover |
| `Space d` | LSP diagnostics |
| `Space m` | LSP rename |
| `Space o` | Document symbols |
| `Space ,` / `Space .` | Jump back / forward |
| `Space j` | Background jobs list |
| `Space D` | Git diff (via bundled git plugin) |
| `Space Esc` | Cancel the leader |

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
```

Or edit `~/.stem/config.json` directly:

```json
{
  "editor": {
    "tab_size": 4,
    "insert_spaces": true,
    "line_numbers": "relative",
    "wrap_lines": false,
    "highlight_current_line": true
  },
  "ui": {
    "show_status_bar": true,
    "show_tab_bar": true,
    "theme": "default"
  },
  "logging": {
    "level": "info"
  }
}
```

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
├── tools/             # CLI tools (find, vfind, scope, plugin)
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
| `plugin_manager` | wasm | Plugin dashboard and reload commands |

See the [Plugin Development Guide](docs/plugin-design.md) to write
your own and [Plugin Architecture](docs/plugin-architecture.md) for
host internals.

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

- [Developer Guide](docs/dev-guide.md) — architecture and module map
- [Plugin Design](docs/plugin-design.md) — writing plugins
- [Plugin Architecture](docs/plugin-architecture.md) — host internals
- [stem.md](docs/stem.md) — long-form reference

## License

[MIT License](LICENSE)

## Acknowledgments

- Modal-editing ideas from [Vim](https://www.vim.org/),
  [Kakoune](https://kakoune.org/), and [Helix](https://helix-editor.com/)
- Built with [Zig](https://ziglang.org/)
- Syntax highlighting powered by
  [tree-sitter](https://tree-sitter.github.io/)
