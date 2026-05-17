# Stem Editor - Developer Guide

> A terminal-based modal editor inspired by Vim, built in Zig.

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Systems Reference](#systems-reference)
- [Feature Tracker](#feature-tracker)
- [Known Issues](#known-issues)
- [Roadmap](#roadmap)

---

## Architecture Overview

Stem follows a **message-passing architecture** with three main threads:
1. **Input Thread** - Captures terminal events via vaxis, sends to Core
2. **Core Thread** - Processes all editor logic, sends render snapshots to UI
3. **Heartbeat Thread** - Sends periodic ticks for hover/auto-save features

Communication uses [Vigil](https://github.com/ooyeku/vigil) inboxes with binary-encoded protocol messages.

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│ Input Thread│────▶│    Core     │────▶│  UI Thread  │
│   (vaxis)   │     │  (kernel)   │     │   (view)    │
└─────────────┘     └─────────────┘     └─────────────┘
                          │
                    ┌─────┴─────┐
                    │  Plugins  │
                    │   (dylib) │
                    └───────────┘
```

---

## Systems Reference

### 1. Editor Core

The central orchestrator handling input, commands, modes, and state coordination.

| Subsystem | Description | Files |
|-----------|-------------|-------|
| **Core Engine** | Main event loop, mode switching, input dispatch | `src/kernel/core.zig` |
| **Protocol** | Binary message encoding/decoding between threads | `src/kernel/protocol.zig` |
| **Command Registry** | Named commands registered for palette/keybindings | `src/kernel/command.zig` |
| **Entry Point** | Application bootstrap, thread spawning | `src/main.zig` |

---

### 2. Buffer Management

Handles text storage, editing operations, and multi-buffer workflows.

| Subsystem | Description | Files |
|-----------|-------------|-------|
| **Buffer Manager** | Multi-buffer handling, switching, file I/O | `src/kernel/buffer_manager.zig` |
| **Piece Table** | Efficient text data structure for edits | `src/core/piece_table.zig` |
| **Editor State** | Cursor, selection, scroll, per-buffer state | `src/core/state.zig` |
| **File Manager** | File reading/writing utilities | `src/core/file_manager.zig` |
| **History (Undo/Redo)** | Transactional undo with automatic grouping | `src/kernel/history.zig` |
| **Virtual File System** | URI schemes (file://, git://) abstraction | `src/kernel/vfs.zig` |

---

### 3. UI Rendering

Terminal rendering via vaxis with syntax-highlighted views.

| Subsystem | Description | Files |
|-----------|-------------|-------|
| **Main View** | Window composition, text rendering, highlighting | `src/ui/view.zig` |
| **Status Bar** | Mode indicator, file info, cursor position | `src/ui/status_bar.zig` |
| **Tab Bar** | Buffer tabs with numbers | `src/ui/tab_bar.zig` |
| **File Picker** | Fuzzy file search overlay | `src/ui/file_picker.zig` |
| **Buffer Picker** | Buffer switching overlay | `src/ui/buffer_picker.zig` |
| **Help View** | Markdown rendering for help content | `src/ui/help_view.zig`, `src/ui/help.zig` |

---

### 4. Syntax Highlighting

Tree-sitter based parsing and token generation.

| Subsystem | Description | Files |
|-----------|-------------|-------|
| **Syntax Manager** | Parser lifecycle, language detection | `src/syntax/manager.zig` |
| **Tree-sitter Bindings** | C FFI layer for tree-sitter | `src/syntax/tree_sitter.zig` |
| **Query Files** | Language-specific highlight queries | `src/syntax/queries/*.scm` |

**Supported Languages:** Zig, Python, JavaScript, TypeScript, TSX, JSON, Bash

---

### 5. LSP Integration

Language Server Protocol client for code intelligence.

| Subsystem | Description | Files |
|-----------|-------------|-------|
| **LSP Manager** | Server lifecycle, request routing | `src/services/lsp_manager.zig` |
| **LSP Server** | JSON-RPC communication, protocol handling | `src/services/lsp/server.zig` |
| **External LSP** | Support for external language servers | `src/services/lsp/external.zig` |
| **LSP Installer** | Auto-install of language servers | `src/services/lsp/installer.zig` |
| **Embedded ZLS** | Built-in Zig language server | `src/services/lsp/zls_embedded.zig` |

**Features:** Go-to-definition, hover, references, diagnostics, completions

---

### 6. Plugin System

Dynamic library based plugin architecture.

| Subsystem | Description | Files |
|-----------|-------------|-------|
| **Plugin Manager** | Discovery, loading, lifecycle | `src/plugins/manager.zig` |
| **Plugin Interface** | Plugin interface definitions | `src/plugins/interface.zig` |
| **Plugin Context** | Runtime context passed to plugins | `src/plugins/context.zig` |
| **UI Manager** | Plugin panel rendering | `src/plugins/ui_manager.zig` |
| **Plugin SDK** | High-level Zig API for plugin developers | `src/sdk/api.zig`, `src/yap_plugin.zig` |

**Bundled Plugins:**
- `plugin-manager` - List loaded plugins
- `git` - Git integration
- `markdown-viewer` - Live markdown preview

---

### 7. Configuration

User preferences and keybinding configuration.

| Subsystem | Description | Files |
|-----------|-------------|-------|
| **Config Schema** | Configuration structure, getters/setters | `src/config/schema.zig` |
| **Storage Manager** | Directory creation, config file I/O | `src/config/storage.zig` |
| **Keybindings** | Key definitions, leader key mappings | `src/config/keys.zig` |

**Config Location:** `~/.stem/config.json`

---

### 8. Workspace & Build

Project-aware features and Zig build integration.

| Subsystem | Description | Files |
|-----------|-------------|-------|
| **Workspace Manager** | Project root detection, file tracking | `src/kernel/workspace.zig` |
| **Build Jobs** | Background build execution | `src/kernel/build_jobs.zig` |
| **Job Manager** | Background task orchestration | `src/kernel/jobs.zig` |
| **Decorations** | Build error overlays | `src/kernel/decorations.zig` |

---

### 9. Split Panes

Window splitting and pane management.

| Subsystem | Description | Files |
|-----------|-------------|-------|
| **Split Manager** | Horizontal/vertical splits, focus navigation | `src/kernel/split_manager.zig` |

---

### 10. CLI Tools

Command-line utilities for search and scope.

| Subsystem | Description | Files |
|-----------|-------------|-------|
| **Search** | `--find` grep-like search | `src/tools/search.zig` |
| **Visual Find** | `--vfind` search with result navigation | `src/tools/vfind.zig` |
| **Scope** | `--scope` search within file | `src/tools/scope.zig` |

---

### 11. Services

Shared infrastructure services.

| Subsystem | Description | Files |
|-----------|-------------|-------|
| **Logger** | Unified logging to `~/.stem/logs/stem.log` | `src/services/logger.zig` |
| **Terminal** | Integrated terminal emulation | `src/services/terminal.zig` |

---

## Feature Tracker

### Core Features
- [x] Modal editing (Select, Insert, Visual, View, Terminal)
- [x] Multi-buffer support with tab bar
- [x] Fuzzy file picker
- [x] Command palette with fuzzy search
- [x] Space leader key with chaining
- [x] Transactional undo/redo
- [x] Split panes (horizontal/vertical)
- [x] Clipboard integration (copy/cut/paste)

### LSP Features
- [x] Embedded ZLS for Zig
- [x] External LSP support (TypeScript, Python)
- [x] Go-to-definition with cursor snapping
- [x] Hover information
- [x] Find references
- [x] Diagnostics display
- [x] Auto-completion

### Syntax Highlighting
- [x] Zig
- [x] Python
- [x] JavaScript/TypeScript/TSX
- [x] JSON
- [x] Bash/Shell
- [x] Markdown
- [ ] HTML/CSS
- [ ] Go
- [ ] Rust

### Plugin System
- [x] Dynamic library loading
- [x] Plugin discovery from `~/.stem/plugins/`
- [x] Command registration
- [x] Buffer creation from plugins
- [x] Panel rendering
- [ ] Plugin settings UI
- [ ] Plugin marketplace

---

## Known Issues

| ID | Severity | Description | Status |
|----|----------|-------------|--------|
| #1 | Low | Some terminals may not support all key combinations | Open |
| #2 | Medium | Syntax highlighting can fail on very large files | Open |
| #3 | Low | External LSP servers require manual installation | Open |
| #4 | Low | List Reference command returns poorly structured references |
---

## Roadmap

### v0.1.0 - Foundation ✅
- Basic modal editing
- Multi-buffer support
- Syntax highlighting (Zig)
- Embedded ZLS

### v0.2.0 - Enhanced Experience (Current)
- [ ] More language support (Go, Rust)
- [ ] Improved diagnostics inline display
- [ ] File tree sidebar
- [ ] Better search (regex support)

### v0.3.0 - Collaboration
- [ ] Git integration improvements
- [ ] Diff view
- [ ] Branch switching

### v1.0.0 - Production Ready
- [ ] Stable plugin API
- [ ] Comprehensive documentation
- [ ] Performance optimization
- [ ] Cross-platform testing

---

## Quick Reference

### Build Commands
```bash
zig build              # Debug build
zig build run          # Run in debug mode
zig build -Doptimize=ReleaseFast  # Release build
./install.sh           # Install to /usr/local/bin
```

### Key Directories
| Directory | Purpose |
|-----------|---------|
| `src/kernel/` | Core editor logic |
| `src/ui/` | Rendering and UI components |
| `src/services/` | LSP, logging, terminal |
| `src/syntax/` | Tree-sitter integration |
| `src/plugins/` | Plugin system |
| `src/config/` | Configuration handling |
| `bundled/plugins/` | Built-in plugins |
| `vendor/` | Third-party dependencies |

### User Data
| Path | Purpose |
|------|---------|
| `~/.stem/config.json` | User configuration |
| `~/.stem/plugins/` | User plugins |
| `~/.stem/logs/stem.log` | Application logs |

---

*Last updated: December 2025*
