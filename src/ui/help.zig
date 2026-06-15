/// CLI surface summary shown inside the editor's `:help` view. The
/// authoritative source for CLI behaviour is `src/cli.zig`; this is a
/// lightweight in-editor reference. Run `stem --help` for the full,
/// always-up-to-date listing.
pub const cli_help_text =
    \\# Stem Editor
    \\
    \\Modal terminal editor. Run `stem --help` in a shell for the full CLI.
    \\
    \\## Usage
    \\
    \\- `stem [paths...]`           : Open files or directories
    \\- `stem <command> [args...]`  : Run a subcommand
    \\
    \\## Commands
    \\
    \\- `stem find <query>`         : Grep file contents
    \\- `stem vfind <query>`        : Interactive search picker
    \\- `stem scope <file> <q>`     : Context around matches in one file
    \\- `stem config <action>`      : list / get / set / unset
    \\- `stem logs [view|clear]`    : Inspect or wipe logs
    \\- `stem lsp <install|list>`   : Manage language servers
    \\- `stem help` / `-h`          : Show help
    \\- `stem version` / `-V`       : Print version
    \\
    \\## Search Flags
    \\- `-p, --path <dir>`          : Restrict to path (repeatable)
    \\- `-e, --ext <ext>`           : Filter by extension (repeatable)
    \\- `-x, --exclude <pat>`       : Skip paths containing this substring
    \\- `-B, --before <n>`          : Lines of context before (`scope`)
    \\- `-A, --after  <n>`          : Lines of context after  (`scope`)
    \\
;

pub const help_text = cli_help_text ++
    \\## Modes
    \\
    \\- **Select (Normal)**: The default mode for navigation.
    \\- **Insert**: For typing text. Press `i` to enter. Esc to exit.
    \\- **Visual**: For selecting text. Press `v` to enter. Esc to exit.
    \\- **View**: Read-only mode. Press `V` (Shift+v) to enter.
    \\- **Terminal**: Integrated terminal. Press `t` to open. Esc to exit.
    \\
    \\## Navigation
    \\
    \\- `h`, `j`, `k`, `l` : Move Left, Down, Up, Right
    \\- `Arrow Keys`       : Move cursor
    \\- `[N] + Motion`     : Repeat motion (e.g. `5j` = 5 down)
    \\- `Page Up/Down`     : Scroll by page
    \\- `%`                : Jump to matching bracket (( ) { } [ ] < >)
    \\- `w` / `b` / `e`    : Next / previous / end of word
    \\- `W` / `B`          : Next / previous WORD (whitespace-separated)
    \\- `{` / `}`          : Previous / next paragraph (blank-line-separated)
    \\
    \\## Search
    \\
    \\- `/` (Select / Visual): Incremental forward search with live
    \\                         match preview. `[i/N]` shows position
    \\                         in the prompt header. Smart case: any
    \\                         uppercase in the query → case-sensitive.
    \\- `?` (Select / Visual): Same, but backward.
    \\- `Enter`              : Accept the current match.
    \\- `Esc`                : Cancel; cursor returns to its origin.
    \\- `n` / `N`            : Next / previous match after closing the prompt.
    \\
    \\## Diagnostics & Hunks
    \\
    \\- `]d` / `[d`: Jump to next / previous diagnostic in the buffer.
    \\- `]g` / `[g`: Jump to next / previous git diff hunk.
    \\- `]s` / `[s`: Jump to next / previous AST sibling.
    \\- `]m` / `[m`: Jump to next / previous function-like node.
    \\
    \\## Bookmarks
    \\
    \\26 named slots (a-z), per project, persisted across sessions.
    \\
    \\- `m<a-z>`   : Set bookmark `<x>` at the cursor — must be in a real
    \\               file buffer (not in the [Bookmarks] view itself).
    \\               Example: `ma` sets slot `a`. A toast confirms.
    \\- `'<a-z>`   : Jump to bookmark `<x>` (works across files).
    \\- `Space m`  : Open the [Bookmarks] list.
    \\- Storage: `~/.stem/cache/bookmarks/`.
    \\- Palette: `bookmark.list`, `bookmark.clear_all`.
    \\
    \\## Word-Under-Cursor Highlight
    \\
    \\After ~300ms of cursor stillness on an identifier, every visible
    \\occurrence of that identifier is faintly highlighted. Moving the
    \\cursor clears the highlight immediately. No configuration needed.
    \\
    \\## Text Objects (Select / Visual Mode)
    \\
    \\Text objects let you select a syntactic chunk in one chord rather
    \\than walking edge-to-edge with motions.
    \\
    \\- Select mode: `s i <c>` selects INSIDE `<c>`, `s a <c>` selects AROUND `<c>`.
    \\- Visual mode: `i <c>` and `a <c>` (no `s` prefix needed).
    \\
    \\Objects: `w` word, `W` WORD, `p` paragraph, `"` `'` `` ` `` quotes,
    \\`(` `[` `{` `<` matching pairs (use either bracket character).
    \\
    \\## Surround
    \\
    \\- Visual mode: `S <c>` wraps the active selection with `<c>`.
    \\- Select mode: `s d <c>` deletes the surround pair `<c>` around the cursor.
    \\- Select mode: `s r <old> <new>` replaces the surround.
    \\
    \\Supported chars: `( [ { <` (matching pairs) and `" ' \``.
    \\
    \\## Multi-Cursor
    \\
    \\- `Ctrl+D` adds the next occurrence of the word under the cursor
    \\  (or the active visual selection) as a secondary cursor. Repeat
    \\  to add more.
    \\- Typing in insert mode replicates at every cursor; backspace too.
    \\- `Esc` in select mode clears all secondary cursors.
    \\
    \\## Leader (Space) Bindings
    \\
    \\Stem's leader is `Space`. Most actions are a single key after
    \\Space (e.g. `Space s` to save). Related families that grow over
    \\time live under a chord prefix — `Space l` for LSP, `Space g`
    \\for git, `Space w` for window/splits, `Space t` for toggles.
    \\Press `Space ;` (or `Space ?`) at any time to pop up the which-key
    \\reference; while in a chord the popup shows that chord's bindings.
    \\
    \\### Top-level — files & buffers
    \\
    \\- `Space e`  : Open file (tree-shaped explorer, single entry point)
    \\- `Space b`  : Buffer picker
    \\- `Space s`  : Save
    \\- `Space k`  : Close current pane / buffer
    \\- `Space q`  : Quit
    \\- `Space n`  : Next buffer
    \\- `Space p`  : Previous buffer
    \\- `Space [1-9]` : Quick switch to buffer N
    \\
    \\### Top-level — navigation
    \\
    \\- `Space f`  : Command palette (find any command). Vim alias: `Space :`
    \\- `Space /`  : Project-wide search
    \\- `Space ,`  : Jump back
    \\- `Space .`  : Jump forward
    \\- `Space z`  : Center cursor in viewport (vim zz)
    \\
    \\### Top-level — edit
    \\
    \\- `Space u`  : Undo
    \\- `Space r`  : Redo
    \\- `Space c`  : Copy
    \\- `Space x`  : Cut
    \\- `Space v`  : Paste
    \\- `Space a`  : Code actions (LSP)
    \\
    \\### Top-level — splits & misc
    \\
    \\- `Space -`  : Split horizontal
    \\- `Space |`  : Split vertical
    \\- `Space Arrow` : Focus pane in direction
    \\- `Space h`  : Open this help
    \\- `Space j`  : Background jobs
    \\- `Space ;`  : Toggle which-key popup (also `Space ?`)
    \\
    \\### Space l — LSP submenu
    \\
    \\- `Space l d` : Go to definition
    \\- `Space l r` : Find references
    \\- `Space l h` : Hover (docs)
    \\- `Space l a` : Code actions (alias for `Space a`)
    \\- `Space l f` : Format buffer
    \\- `Space l F` : Format selection
    \\- `Space l D` : Diagnostics list
    \\- `Space l s` : Document symbols
    \\- `Space l S` : Workspace symbols
    \\- `Space l t` : Toggle inline diagnostics
    \\- `Space l i` : Toggle inlay hints
    \\- `Space l =` : Toggle format-on-save
    \\
    \\Signature help auto-pops above the cursor in Insert mode when
    \\you type `(` or `,`. Dismissed by `)`, Esc, or mode change.
    \\
    \\### Space g — Git submenu
    \\
    \\- `Space g d` : Git diff
    \\
    \\### Space w — Window submenu
    \\
    \\- `Space w -` : Horizontal split
    \\- `Space w |` : Vertical split
    \\- `Space w h/j/k/l` : Focus pane left / down / up / right
    \\- `Space w q` : Close pane
    \\
    \\### Space t — Toggle submenu
    \\
    \\- `Space t d` : Toggle inline diagnostics
    \\- `Space t i` : Toggle inlay hints
    \\- `Space t =` : Toggle format-on-save
    \\
    \\## File Explorer (Space e — also `Cmd/Ctrl+O`)
    \\
    \\The single entry point for opening files. Modal, tree-shaped
    \\overlay rooted at the project cwd.
    \\
    \\- `↑/↓` or `j/k`          : Move selection
    \\- `→` or `l`              : Expand directory
    \\- `←` or `h`              : Collapse directory (or jump to parent)
    \\- `g` / `G`               : Top / bottom of list
    \\- `Enter` or `Space`      : Open file (or toggle directory)
    \\- `H`                     : Toggle hidden files (dotfiles)
    \\- `Ctrl+r`                : Rebuild tree (after external changes)
    \\- `Esc`                   : Close explorer
    \\
    \\## Large-File Mode
    \\
    \\Files past `editor.large_file_threshold_bytes` (default 5 MB) or
    \\`editor.large_file_threshold_lines` (default 50k) open with
    \\tree-sitter, brackets, LSP, and auto-pair disabled. The status
    \\bar shows `[LARGE]`. Files past `large_file_hard_limit_bytes`
    \\(default 100 MB) are rejected at open. Re-open after editing
    \\config to re-classify.
    \\
    \\## Auto-Save Backups
    \\
    \\Every 30 s (configurable: `editor.auto_save_interval_seconds`)
    \\stem snapshots every dirty buffer to `~/.stem/recover/<hash>.bak`.
    \\On startup, surviving backups produce a status toast; run
    \\`buffer.restore_backups` to view them. Disable with
    \\`editor.auto_save_backup = false`.
    \\
    \\## Structural (tree-sitter) Motions
    \\
    \\- `V`         (normal): Select the AST node under the cursor
    \\- `+` / `-`   (visual): Expand to parent / shrink to first child
    \\
    \\See "Diagnostics & Hunks" above for `]d`/`[d`, `]g`/`[g`,
    \\`]s`/`[s`, `]m`/`[m`.
    \\
    \\## Quick Buffer Switching
    \\
    \\Buffer tabs are numbered (1, 2, 3...). You can switch quickly:
    \\- `Space 1`: Switch to buffer 1 (instant if <10 buffers)
    \\- `Space 2`: Switch to buffer 2
    \\- `Space 12`: Switch to buffer 12 (multi-digit for 10+ buffers)
    \\
    \\Switching is instant when your input uniquely identifies a buffer.
    \\
    \\In the buffer picker (`Space b`): type a number then Enter to
    \\jump, or use arrow keys / j/k.
    \\
    \\## Undo/Redo
    \\
    \\Transactional undo/redo with automatic grouping:
    \\- Multiple rapid edits are grouped into single undo operations
    \\- `Space u` or `edit.undo` to undo
    \\- `Space r` or `edit.redo` to redo
    \\- Cursor position is restored on undo/redo
    \\
    \\## Scratch Buffers
    \\
    \\Create temporary buffers that aren't saved to disk:
    \\- Command palette: `buffer.new_scratch`
    \\- Great for notes, temporary code, or experiments
    \\- Lost when closed
    \\
    \\## Background Jobs
    \\
    \\- `Space j`: View active background jobs
    \\- `job.list`: View active and recently completed jobs
    \\- `task.list`: View detected project build/test/run commands
    \\- `task.run_build`: Run the preferred detected build task
    \\- `task.run_test`: Run the preferred detected test task
    \\- `task.run`: Run the preferred detected run/start task
    \\- `task.run_dev`, `task.run_lint`, `task.run_format`: Run matching tasks
    \\- `task.output`: Reopen the latest retained project task output
    \\- Status bar shows a spinner when jobs are running
    \\- Jobs include: file indexing, search operations, project tasks, etc.
    \\
    \\## Zig Build Commands
    \\
    \\Stem auto-detects your Zig workspace (build.zig). Use the
    \\command palette (`Space f`) and type "zig" or "build":
    \\
    \\- `Zig: Build`            : Run `zig build`
    \\- `Zig: Test`             : Run `zig build test`
    \\- `Zig: Run`              : Run `zig build run`
    \\- `Zig: Show Build Output`: View last build result
    \\
    \\Build output appears in a dedicated [Build] buffer. Errors are
    \\shown as decorations in source files.
    \\
    \\## Global Shortcuts (modifier-prefixed)
    \\
    \\- `Cmd + s`          : Save
    \\- `Cmd + o`          : Open File
    \\- `Cmd + q`          : Quit
    \\- `Cmd + w`          : Close Buffer
    \\- `Cmd + Shift + ]`  : Next Buffer
    \\- `Cmd + Shift + [`  : Previous Buffer
    \\- `Ctrl + h/j/k/l`   : Focus pane in direction
    \\- `Ctrl + d`         : Add next occurrence (multi-cursor)
    \\- `Ctrl + r`         : Start replace-confirmation walk (in `Space /`)
    \\
    \\## Command Palette Reference
    \\
    \\Press `Space f` to open (or `Space :` if your terminal handles it).
    \\Type to filter; Enter to run.
    \\Highlights of commonly-used commands:
    \\
    \\### File / buffer
    \\- file.save / file.open / file.new / file.save_as
    \\- file.reload / file.quit
    \\- buffer.switch / buffer.new / buffer.next / buffer.prev
    \\- buffer.close / buffer.close_others / buffer.new_scratch
    \\- buffer.restore_backups
    \\
    \\### Navigation
    \\- nav.go_to_line / nav.go_to_symbol
    \\- nav.match_bracket / nav.expand_selection
    \\- nav.top_of_file / nav.bottom_of_file
    \\- nav.center_view (also `Space z`)
    \\- search.find_in_buffer
    \\
    \\### Editing
    \\- edit.undo / edit.redo
    \\- edit.copy / edit.cut / edit.paste
    \\- edit.delete_line / edit.duplicate_line
    \\- edit.move_line_up / edit.move_line_down
    \\- edit.join_lines / edit.insert_datetime
    \\
    \\### LSP
    \\- lsp.format / lsp.format_selection
    \\- lsp.definition / lsp.references / lsp.hover
    \\- lsp.diagnostics / lsp.rename
    \\- lsp.code_action
    \\- lsp.restart
    \\- lsp.toggle_format_on_save
    \\
    \\### Editor toggles
    \\- editor.toggle_inline_diagnostics
    \\- editor.toggle_inlay_hints
    \\
    \\### Bookmarks
    \\- bookmark.list / bookmark.clear_all
    \\
    \\### Split / pane
    \\- split.vertical / split.horizontal
    \\- pane.close / pane.focus_* / pane.swap_*
    \\
    \\### Modes / plugins / help
    \\- mode.insert / mode.visual / mode.terminal / mode.select
    \\- plugin.show
    \\- stem.control_center / project.brain
    \\- stats.show / task.list / task.run_build / task.run_test / task.run / task.output / job.list / view.logs
    \\- help.show
    \\
    \\## Configuration
    \\
    \\Use `stem config` to manage settings:
    \\- `stem config list`            : Show all settings
    \\- `stem config get <key>`       : Get a setting value
    \\- `stem config set <key> <v>`   : Update a setting
    \\
    \\### Available Settings
    \\
    \\- `editor.tab_size`                       : Tab width (default: 4)
    \\- `editor.insert_spaces`                  : Insert spaces instead of tabs
    \\- `editor.line_numbers`                   : absolute / relative / none
    \\- `editor.wrap`                           : Enable word wrapping
    \\- `editor.auto_pairs`                     : Auto-close brackets and quotes
    \\- `editor.cursor_line`                    : Highlight the cursor's line
    \\- `editor.format_on_save`                 : Run LSP formatter before each save
    \\- `editor.inline_diagnostics`             : Render errors at end-of-line (default: true)
    \\- `editor.inlay_hints`                    : LSP type / param hints as virtual text
    \\- `editor.auto_save_backup`               : Periodic dirty-buffer snapshots (default: true)
    \\- `editor.auto_save_interval_seconds`     : Backup cadence (default: 30)
    \\- `editor.large_file_threshold_bytes`     : Disable rich features above this (default: 5 MB)
    \\- `editor.large_file_threshold_lines`     : Disable rich features above this (default: 50000)
    \\- `editor.large_file_hard_limit_bytes`    : Refuse to open files above this (default: 100 MB)
    \\- `ui.show_status_bar`                    : Render the status bar
    \\- `logging.level`                         : Log level (debug/info/warn/err)
    \\
    \\Logs are written to `~/.stem/logs/stem.log`
    \\
    \\## Tips
    \\
    \\- Use `Space f` to fuzzy-find any command. (`Space :` works too on terminals that handle Shift+; cleanly.)
    \\- Use `Space e` (or `Cmd/Ctrl+O`) to open files via the tree explorer.
    \\- `Space ;` (or `Space ?`) toggles which-key — discover bindings on the fly.
    \\- In any chord (`Space l`, `Space g`, ...) which-key shows the sub-bindings.
    \\- Visual Mode (`v`) allows you to select text using navigation keys.
    \\- Terminal Mode (`t`) gives you a full shell inside the editor.
    \\- LSP commands work with the cursor anywhere in an identifier.
    \\
;
