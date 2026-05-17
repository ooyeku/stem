# Stem

A modern, approachable modal text editor for the terminal. Built with Zig, powered by tree-sitter for syntax highlighting, and featuring built-in LSP support.

Stem aims to enable "flow state" editing while being more approachable than Vim/Neovim/Helix. It combines the efficiency of modal editing with modern IDE features like intelligent code completion, go-to-definition, and real-time diagnostics.

![Version](https://img.shields.io/badge/version-0.6.0--dev-blue)
![Zig](https://img.shields.io/badge/zig-0.16.x-orange)
![Platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20Linux-green)
![License](https://img.shields.io/badge/license-MIT-brightgreen)

## Quick Start

### Install a prebuilt binary (macOS / Linux)

```bash
curl -fsSL https://raw.githubusercontent.com/ooyeku/stem/main/scripts/install.sh | sh
```

This downloads the latest release archive for your platform and installs `stem`
to `/usr/local/bin` (or `~/.local/bin` if you can't write to `/usr/local`).

### Or build from source

Requires **Zig 0.16+** and a C compiler. No other setup step — all
dependencies (tree-sitter, language grammars) are fetched by `zig build`.

```bash
git clone https://github.com/ooyeku/stem.git
cd stem
zig build run
```

To install system-wide from source:

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

### Core Editing
- **Modal editing** — Select, Insert, Visual, View, and Terminal modes
- **Multi-buffer support** — Work with multiple files via tab bar
- **Split panes** — Horizontal and vertical splits for side-by-side editing
- **Transactional undo/redo** — Never lose your changes
- **Fuzzy file picker** — Instant search across your project

### Language Intelligence
- **Syntax highlighting** — Tree-sitter powered highlighting for 10+ languages
- **LSP integration** — Go-to-definition, hover docs, diagnostics
- **Embedded ZLS** — Zig works out of the box, zero configuration
- **Optional LSP servers** for Python, JS/TS, Go, Rust (installed on request — see below)

### Supported Languages
| Language | Syntax Highlighting | LSP Support |
|----------|:------------------:|:-----------:|
| Zig | Yes | Yes (embedded ZLS) |
| Python | Yes | Yes (Pyright) |
| JavaScript | Yes | Yes (tsserver) |
| TypeScript | Yes | Yes (tsserver) |
| Go | Yes | Yes (gopls) |
| Rust | Yes | Yes (rust-analyzer) |
| JSON | Yes | - |
| Bash/Shell | Yes | - |
| HTML | Yes | - |
| CSS | Yes | - |

### Additional Features
- **Command palette** (`Space a`) — Quick access to all commands
- **Plugin system** — Extend functionality with dynamic plugins
- **Integrated terminal** — Run commands without leaving the editor
- **Git integration** — View file status and changes (via plugin)

## Usage

```bash
stem                       # empty buffer
stem myfile.zig            # open a file
stem file1.zig file2.zig   # open multiple files
stem ./src                 # open a directory (recursively finds files)

# CLI tools
stem --find "pattern"      # grep-like text search
stem --vfind "pattern"     # interactive visual search
stem --scope file.zig fn   # search within a specific file
stem --help                # all options
```

### Language servers

Language servers are installed on request (not at startup). ZLS is bundled —
nothing to install for Zig.

```bash
stem lsp install python        # Pyright
stem lsp install typescript    # tsserver (also handles JavaScript)
stem lsp install go            # gopls (requires Go on PATH)
stem lsp install rust          # rust-analyzer
stem lsp install all           # install every supported server
```

## Key Bindings

### Mode Switching
| Key | Action |
|-----|--------|
| `i` | Enter Insert mode |
| `v` | Enter Visual mode |
| `Esc` | Return to Select mode |
| `:` | Enter command mode |

### Navigation (Select Mode)
| Key | Action |
|-----|--------|
| `h` `j` `k` `l` | Move left/down/up/right |
| `w` / `b` | Jump word forward/backward |
| `0` / `$` | Start/end of line |
| `gg` / `G` | First/last line of file |
| `Ctrl+d` / `Ctrl+u` | Half-page down/up |
| `{` / `}` | Jump paragraph up/down |

### Editing
| Key | Action |
|-----|--------|
| `d` | Delete selection/line |
| `y` | Yank (copy) |
| `p` | Paste |
| `u` | Undo |
| `Ctrl+r` | Redo |
| `>>` / `<<` | Indent/unindent |

### Leader Commands (`Space` + key)
| Key | Action |
|-----|--------|
| `a` | Open command palette |
| `f` | File picker (fuzzy search) |
| `b` | Buffer picker |
| `s` | Save current file |
| `w` | Save and close buffer |
| `q` | Quit |
| `\|` | Split vertically |
| `-` | Split horizontally |
| `h` `j` `k` `l` | Focus split left/down/up/right |

### LSP Commands
| Key | Action |
|-----|--------|
| `K` | Show hover documentation |
| `gd` | Go to definition |
| `gr` | Find all references |

### Window Management
| Key | Action |
|-----|--------|
| `Ctrl+w h/j/k/l` | Move focus between splits |
| `Ctrl+w q` | Close current split |
| `gt` / `gT` | Next/previous tab |

## Configuration

Configuration is stored in `~/.stem/`:

```
~/.stem/
├── config.json     # User settings
├── plugins/        # Installed plugins (auto-seeded from bundled plugins on first run)
├── lsp/            # Language servers installed via `stem lsp install`
└── logs/           # Debug logs (stem-*.log)
```

Edit via CLI:
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

## Platform Support

| Platform | Status | Notes |
|----------|--------|-------|
| macOS (ARM64) | Full | Primary development platform |
| macOS (x86_64) | Full | Tested |
| Linux (x86_64) | Full | All features work |
| Linux (ARM64) | Full | Tested on Raspberry Pi |
| Windows | Experimental | No integrated terminal |

## Building from source

### Debug build (faster compile, slower runtime)
```bash
zig build
```

### Release build
```bash
zig build -Doptimize=ReleaseFast
```

### Run tests
```bash
zig build test
```

### Cross-compilation
```bash
zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseFast
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseFast    # experimental
```

| Option | Description |
|--------|-------------|
| `-Doptimize=ReleaseFast` | Optimized build |
| `-Doptimize=ReleaseSafe` | Optimized with safety checks |
| `-Doptimize=ReleaseSmall` | Optimized for size |

## Architecture

Stem is built with a modular architecture:

```
src/
├── main.zig           # Entry point and CLI handling
├── kernel/            # Core editor engine (event loop, state management)
├── core/              # Buffer management, text operations
├── ui/                # Terminal rendering, views
├── syntax/            # Tree-sitter integration, highlighting
├── services/          # LSP, logging, background tasks
├── config/            # Configuration management
└── tools/             # CLI tools (find, vfind, scope)
```

### Dependencies

All dependencies are fetched by Zig's package manager — see [build.zig.zon](build.zig.zon).

**Zig packages:**
- [libvaxis](https://github.com/rockorager/libvaxis) — Terminal UI
- [vigil](https://github.com/ooyeku/vigil) — Message passing
- [zls](https://github.com/zigtools/zls) — Embedded Zig LSP
- [lsp-kit](https://github.com/zigtools/lsp-kit) — LSP protocol types
- [uucode](https://github.com/jacobsandlund/uucode) — Unicode handling
- [tree-sitter](https://github.com/tree-sitter/tree-sitter) plus grammars for Zig, Python, JS/TS, JSON, Bash, Go, HTML, CSS, Rust

## Plugins

Bundled plugins ship with `stem` and are auto-copied to `~/.stem/plugins/` on
first launch:

| Plugin | Description |
|--------|-------------|
| `plugin-manager` | List and manage installed plugins |
| `git` | Git status, blame, and diff integration |
| `markdown-viewer` | Live markdown preview |

See the [Plugin Development Guide](docs/plugin-design.md) to build your own.

## Troubleshooting

**LSP doesn't work for a language.** Run `stem lsp install <language>` and check
`stem logs`. Increase verbosity with `stem config set logging.level debug`.

**Colors look wrong.** Make sure your terminal supports 24-bit color:
`export COLORTERM=truecolor`.

**`./install.sh` says "no write access to /usr/local".** Either re-run with
`--prefix $HOME/.local` (no sudo needed), or grant sudo access.

## Contributing

1. Fork the repository
2. Create a feature branch
3. `zig build` and `zig build test`
4. Cross-check: `zig build -Dtarget=x86_64-linux-gnu`
5. Submit a pull request

## Documentation

- [Developer Guide](docs/dev-guide.md) — architecture and internals
- [Plugin Design](docs/plugin-design.md) — creating plugins

## License

[MIT License](LICENSE)

## Acknowledgments

- Modal editing concepts from [Vim](https://www.vim.org/), [Kakoune](https://kakoune.org/), and [Helix](https://helix-editor.com/)
- Built with [Zig](https://ziglang.org/)
- Syntax highlighting powered by [tree-sitter](https://tree-sitter.github.io/)
