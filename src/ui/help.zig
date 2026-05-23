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
    \\- `Arrow Keys`       : Move Cursor
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
    \\- `m<a-z>`   : Set bookmark slot `<x>` at the cursor.
    \\- `'<a-z>`   : Jump to bookmark `<x>` (works across files).
    \\- Bookmarks persist per-project under `~/.stem/cache/bookmarks/`.
    \\- Command: `bookmark.list` opens a `[Bookmarks]` buffer; `bookmark.clear_all` removes them all.
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
    \\- Typing in insert mode replicates at every cursor; backspace
    \\  too. Newlines and structural commands fall back to the primary
    \\  cursor.
    \\- `Esc` in select mode clears all secondary cursors.
    \\
    \\## Commands (Leader Key: Space)
    \\
    \\- `Space + a`: Open Command Palette / Actions
    \\- `Space + f`: Open File Picker
    \\- `Space + b`: Open Buffer Picker (Switch Tabs)
    \\- `Space + [1-9]`: Quick switch to buffer by number
    \\- `Space + s`: Save File
    \\- `Space + q`: Quit Editor
    \\- `Space + k`: Close (Kill) Current Buffer
    \\- `Space + n`: Next Buffer
    \\- `Space + p`: Previous Buffer
    \\- `Space + w`: Open this Help (Wiki/What)
    \\- `Space + u`: Undo last change
    \\- `Space + r`: Redo last undone change
    \\- `Space + j`: Show background jobs
    \\- `Space + c`: Copy selected text
    \\- `Space + x`: Cut selected text
    \\- `Space + v`: Paste clipboard contents
    \\
    \\## File Picker
    \\
    \\- `↑/↓` or `j/k`          : Navigate files
    \\- `Enter` on file         : Open file
    \\- `Enter` on directory    : Navigate into directory
    \\- `Shift+Enter` / `^O`    : Open ALL files in directory (recursive)
    \\- `Backspace`             : Go to parent directory
    \\- `Esc`                   : Cancel file picker
    \\
    \\Note: `^O` (or Shift+Enter) skips hidden files and common dirs (.git, node_modules)
    \\
    \\## LSP Commands (Space + Key)
    \\
    \\- `Space + g`: Go to Definition
    \\- `Space + l`: Find References (List/Lookup)
    \\- `Space + h`: Show Hover Info
    \\- `Space + d`: Show Diagnostics
    \\
    \\## Structural (tree-sitter) Motions
    \\
    \\- `V`         (normal): Select the AST node under the cursor
    \\- `+` / `-`   (visual): Expand to parent / shrink to first child
    \\
    \\See "Diagnostics & Hunks" above for `]d`/`[d`, `]g`/`[g`,
    \\`]s`/`[s`, `]m`/`[m`.
    \\
    \\## Copy & Paste
    \\
    \\- Visual Mode (`v`): Select text with hjkl or arrow keys
    \\- `y` (in visual mode): Yank (copy) selection
    \\- `x` (in visual mode): Cut selection
    \\- `Space + o` (any mode): Paste from clipboard
    \\
    \\## Quick Buffer Switching
    \\
    \\Buffer tabs are numbered (1, 2, 3...). You can switch quickly:
    \\- `Space + 1`: Switch to buffer 1 (instant if <10 buffers)
    \\- `Space + 2`: Switch to buffer 2
    \\- `Space + 12`: Switch to buffer 12 (multi-digit for 10+ buffers)
    \\
    \\Switching is instant when your input uniquely identifies a buffer.
    \\
    \\In Buffer Picker (`Space + b`):
    \\- Type a number then Enter to jump to that buffer
    \\- Or use arrow keys / j/k to navigate
    \\
    \\## Undo/Redo
    \\
    \\Stem supports transactional undo/redo with automatic grouping:
    \\- Multiple rapid edits are grouped into single undo operations
    \\- `Space + u` or `edit.undo` to undo
    \\- `Space + r` or `edit.redo` to redo
    \\- Cursor position is restored on undo/redo
    \\
    \\## Scratch Buffers
    \\
    \\Create temporary buffers that aren't saved to disk:
    \\- Use Command Palette: `buffer.new_scratch`
    \\- Great for notes, temporary code, or experiments
    \\- Buffer will be lost when closed
    \\
    \\## Background Jobs
    \\
    \\Long-running operations run in the background:
    \\- `Space + j`: View active background jobs
    \\- Status bar shows spinner when jobs are running
    \\- Jobs include: file indexing, search operations, etc.
    \\
    \\## Zig Build Commands
    \\
    \\Stem automatically detects your Zig workspace (build.zig).
    \\Use Command Palette (`Space + P`) and type "zig" or "build":
    \\
    \\- `Zig: Build`  : Run `zig build`
    \\- `Zig: Test`   : Run `zig build test`
    \\- `Zig: Show Build Output` : View last build result
    \\
    \\Build output appears in a dedicated [Build] buffer.
    \\Errors are shown as decorations in source files.
    \\
    \\## Global Shortcuts
    \\
    \\- `Cmd + s`          : Save
    \\- `Cmd + o`          : Open File
    \\- `Cmd + q`          : Quit
    \\- `Cmd + w`          : Close Buffer
    \\- `Cmd + Shift + ]`  : Next Buffer
    \\- `Cmd + Shift + [`  : Previous Buffer
    \\
    \\## Split/Pane Management
    \\
    \\- `Space + -` : Horizontal Split (side-by-side)
    \\- `Space + \`` : Vertical Split (top/bottom)
    \\- `Space + Arrow` : Focus pane in direction (when in splits)
    \\- `Ctrl + h` : Focus Left Pane
    \\- `Ctrl + l` : Focus Right Pane
    \\- `Ctrl + k` : Focus Upper Pane
    \\- `Ctrl + j` : Focus Lower Pane
    \\
    \\Use Command Palette (`Space + P`) for:
    \\- Pane: Close / Focus / Swap
    \\
    \\## Command Palette Commands
    \\
    \\### File Management
    \\- file.save       : Save current file
    \\- file.open       : Open file picker
    \\- file.new        : Create new buffer
    \\- file.save_as    : Save file as...
    \\- file.reload     : Reload from disk
    \\- file.quit       : Quit editor
    \\
    \\### Buffer Management
    \\- buffer.switch   : Open buffer picker
    \\- buffer.new      : Create new untitled buffer
    \\- buffer.next     : Go to next buffer
    \\- buffer.prev     : Go to previous buffer (Space+p)
    \\- buffer.close    : Close current buffer (Space+k)
    \\- buffer.close_others : Close all others
    \\- buffer.new_scratch : Create scratch buffer
    \\
    \\### Navigation
    \\- nav.go_to_line  : Jump to line number
    \\- nav.go_to_symbol: Find symbols in file
    \\- nav.match_bracket: Jump to matching bracket (%)
    \\- nav.expand_selection: Expand to syntax boundary
    \\- nav.top_of_file : Go to start
    \\- nav.bottom_of_file: Go to end
    \\- nav.center_view : Center cursor
    \\- search.find_in_buffer: Search in file
    \\
    \\### Editing
    \\- edit.undo          : Undo last change
    \\- edit.redo          : Redo last undone
    \\- edit.copy          : Copy selection (Space+c)
    \\- edit.cut           : Cut selection (Space+x)
    \\- edit.paste         : Paste from clipboard (Space+v)
    \\- edit.delete_line   : Delete current line
    \\- edit.duplicate_line: Copy line below
    \\- edit.move_line_up  : Swap line up
    \\- edit.move_line_down: Swap line down
    \\- edit.join_lines    : Merge with next line
    \\- edit.insert_datetime: Insert timestamp
    \\
    \\### LSP (Zig Files)
    \\- lsp.format               : Format document
    \\- lsp.definition           : Go to definition
    \\- lsp.references           : Find references
    \\- lsp.hover                : Show hover info
    \\- lsp.diagnostics          : Show errors/warnings
    \\- lsp.restart              : Restart ZLS
    \\- lsp.toggle_format_on_save: Toggle automatic format on every save
    \\
    \\### Bookmarks
    \\- bookmark.list      : Open the [Bookmarks] buffer
    \\- bookmark.clear_all : Remove every bookmark for this project
    \\
    \\### Split/Pane
    \\- split.vertical  : Split top/bottom
    \\- split.horizontal: Split left/right
    \\- pane.close      : Close current pane
    \\- pane.focus_*    : Navigate panes
    \\- pane.swap_*     : Swap pane contents
    \\
    \\### Background Jobs
    \\- job.list        : View active jobs
    \\
    \\### Modes
    \\- mode.insert     : Switch to insert mode
    \\- mode.visual     : Switch to visual mode
    \\- mode.terminal   : Switch to terminal mode
    \\- mode.select     : Switch to select mode
    \\
    \\### Plugins
    \\- plugin.show     : List loaded plugins
    \\
    \\### Help
    \\- help.show       : Show this help
    \\
    \\## Configuration
    \\
    \\Use `stem config` to manage settings:
    \\- `stem config list`          : Show all settings
    \\- `stem config get <key>`     : Get a setting value
    \\- `stem config set <key> <v>` : Update a setting
    \\
    \\### Available Settings
    \\- `editor.tab_size`       : Tab width (default: 4)
    \\- `editor.insert_spaces`  : Insert spaces instead of tabs
    \\- `editor.line_numbers`   : absolute / relative / none
    \\- `editor.wrap`           : Enable word wrapping
    \\- `editor.auto_pairs`     : Auto-close brackets and quotes
    \\- `editor.cursor_line`    : Highlight the cursor's line
    \\- `editor.format_on_save` : Run LSP formatter before each save
    \\- `ui.show_status_bar`    : Render the status bar
    \\- `logging.level`         : Log level (debug/info/warn/err)
    \\
    \\Logs are written to `~/.stem/logs/stem.log`
    \\
    \\## Tips
    \\
    \\- Use `Space + a` to quickly access any command.
    \\- Use `Space + f` to quickly find files in your project.
    \\- Visual Mode (`v`) allows you to select text using navigation keys.
    \\- Terminal Mode (`t`) gives you a full shell inside the editor.
    \\- Undo groups rapid typing into single operations for natural undo.
    \\- LSP commands work with cursor anywhere in an identifier.
    \\
;
