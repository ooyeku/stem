//! Input dispatch for `.select` mode — the default modal
//! editing mode. The largest handler in the editor: it owns the
//! leader-chord state machine, all single-key motions, vim-style
//! repeat counts, bookmark/text-object/surround/bracket chords,
//! the plugin keybinding lookup, and the search shortcuts.
//!
//! Layout, in dispatch order:
//!  1. Esc clears all transient chord state.
//!  2. Space-as-bailout: if mid one-shot chord, treat Space as a
//!     fresh leader start.
//!  3. Multi-step chord state machines: text-object, bookmark
//!     set/jump, code-action picker, bracket-prefix (`]`/`[`).
//!  4. Leader-pending block: plugin keybind lookup, digit prefix,
//!     which-key toggle, sub-chord dispatch (`l`, `g`, `w`, `t`),
//!     top-level leader actions.
//!  5. Top-level single-step keys: digit accumulator, save/open/
//!     quit/close shortcuts, mode switches, pane-focus chords,
//!     cursor motions, word/paragraph motions, bracket-match,
//!     vim-style jump-list aliases, search-next/prev, `/`/`?`
//!     incremental search.

const std = @import("std");
const vaxis = @import("vaxis");

const Keys = @import("../../config/keys.zig").Keys;
const Help = @import("../../ui/help.zig");
const LeaderDispatch = @import("../leader_dispatch.zig").LeaderDispatch;
const LspCommands = @import("../commands/lsp_commands.zig").LspCommands;
const SplitCommands = @import("../commands/split_commands.zig").SplitCommands;
const SystemCommands = @import("../commands/system_commands.zig").SystemCommands;
const EditCommands = @import("../commands/edit_commands.zig").EditCommands;
const NavCommands = @import("../commands/nav_commands.zig").NavCommands;

const log = std.log.scoped(.Select);

pub fn handle(core: anytype, key: vaxis.Key) !bool {
    // Esc clears all transient select-mode state — multi-cursors,
    // pending chord prefixes, the nav repeat count — so the user
    // can always bail back to a clean slate.
    if (key.matches(vaxis.Key.escape, .{})) {
        if (core.multi_cursors.items.len > 0) {
            core.clearMultiCursors();
        }
        core.bracket_pending = null;
        core.bookmark_set_pending = false;
        core.bookmark_jump_pending = false;
        core.text_object_state = .none;
        core.nav_repeat_count = 0;
        return true;
    }

    // Space-as-bailout. If the user is mid-chord on a one-shot
    // (bracket prefix `]`/`[`, bookmark `m`/`'`, text-object /
    // surround sequence) and presses Space, treat it as "I gave
    // up on that chord, start a fresh leader." Otherwise the
    // Space would be consumed as the chord's target character
    // and the user would be stuck staring at nothing happening.
    // The leader-handling block below still sees
    // `leader_pending = true` and the second-Space-no-op
    // guard, so a follow-up Space refreshes the toast rather
    // than cancelling.
    if (key.matches(Keys.leader, .{}) and !core.leader_pending) {
        const had_pending = core.bracket_pending != null or
            core.bookmark_set_pending or
            core.bookmark_jump_pending or
            core.text_object_state != .none;
        if (had_pending) {
            core.bracket_pending = null;
            core.bookmark_set_pending = false;
            core.bookmark_jump_pending = false;
            core.text_object_state = .none;
            core.leader_pending = true;
            core.leader_pending_set_ms = std.Io.Clock.real.now(core.io).toMilliseconds();
            core.leader_help_requested = false;
            core.setStatusLiteralLeveled(.info, "Space ; for command help", 1500);
            return true;
        }
    }

    // Text-object chord: `s i <c>` selects inside, `s a <c>` selects
    // around. Each follow-up advances the state machine; any
    // non-matching key cancels.
    switch (core.text_object_state) {
        .none => {},
        .s_seen => {
            core.text_object_state = .none;
            if (key.matches('i', .{})) {
                core.text_object_state = .inside_pending;
                return true;
            }
            if (key.matches('a', .{})) {
                core.text_object_state = .around_pending;
                return true;
            }
            if (key.matches('d', .{})) {
                core.text_object_state = .surround_delete_pending;
                return true;
            }
            if (key.matches('r', .{})) {
                core.text_object_state = .surround_replace_old_pending;
                return true;
            }
            // Cancel; fall through to normal handling.
        },
        .inside_pending, .around_pending => {
            const around = core.text_object_state == .around_pending;
            core.text_object_state = .none;
            if (key.codepoint > 0 and key.codepoint < 0x80) {
                try core.selectTextObject(@intCast(key.codepoint), around);
                return true;
            }
            // Non-ASCII or modified key cancels the chord.
        },
        .surround_delete_pending => {
            core.text_object_state = .none;
            if (key.codepoint > 0 and key.codepoint < 0x80) {
                try core.deleteSurround(@intCast(key.codepoint));
                return true;
            }
        },
        .surround_replace_old_pending => {
            if (key.codepoint > 0 and key.codepoint < 0x80) {
                core.surround_replace_old = @intCast(key.codepoint);
                core.text_object_state = .surround_replace_new_pending;
                return true;
            }
            core.text_object_state = .none;
        },
        .surround_replace_new_pending => {
            const old = core.surround_replace_old;
            core.text_object_state = .none;
            if (key.codepoint > 0 and key.codepoint < 0x80) {
                try core.replaceSurround(old, @intCast(key.codepoint));
                return true;
            }
        },
        .surround_add_pending => {
            // `S <c>` is a visual-mode chord; if we end up here in
            // select mode (mode switched mid-chord), cancel safely.
            core.text_object_state = .none;
        },
    }

    // `m<a-z>` sets the bookmark slot, `'<a-z>` jumps to it. Both
    // are one-shot chords; any non-matching follow-up cancels.
    if (core.bookmark_set_pending) {
        core.bookmark_set_pending = false;
        if (key.codepoint >= 'a' and key.codepoint <= 'z' and !key.mods.ctrl and !key.mods.alt and !key.mods.super) {
            try core.setBookmark(@intCast(key.codepoint));
            return true;
        }
        // Fall through — unknown follow-up dispatches normally.
    }
    if (core.bookmark_jump_pending) {
        core.bookmark_jump_pending = false;
        if (key.codepoint >= 'a' and key.codepoint <= 'z' and !key.mods.ctrl and !key.mods.alt and !key.mods.super) {
            try core.jumpToBookmark(@intCast(key.codepoint));
            return true;
        }
        // Fall through — unknown follow-up dispatches normally.
    }

    // Code-action picker: a digit picks an action; anything else
    // (Esc, letter, navigation) dismisses the pending list.
    if (core.code_action_pending) |list| {
        if (key.codepoint >= '1' and key.codepoint <= '9' and !key.mods.ctrl and !key.mods.alt and !key.mods.super) {
            const idx: usize = @intCast(key.codepoint - '1');
            if (idx < list.len) {
                const chosen = list[idx];
                // Take ownership: clear the slot so the apply
                // callback can't see a half-freed list if it
                // re-enters the dispatcher.
                core.code_action_pending = null;
                defer core.lsp_manager.freeCodeActions(list);
                core.applyCodeAction(chosen) catch |err| {
                    core.setStatus("Code action apply failed: {}", .{err}, 3000);
                };
                return true;
            }
        }
        // Any other key (Esc, letter, etc.) cancels the chord.
        core.lsp_manager.freeCodeActions(list);
        core.code_action_pending = null;
        core.setStatusLiteralLeveled(.info, "Code actions: cancelled", 1000);
        // Fall through — let the key do its normal job.
    }

    // `]d` / `[d` jump to next/previous diagnostic. The bracket prefix
    // is a one-shot — any non-matching follow-up cancels it.
    if (core.bracket_pending) |prefix| {
        core.bracket_pending = null;
        if (key.matches('d', .{})) {
            try core.jumpToDiagnostic(prefix == ']');
            return true;
        }
        // `]g` / `[g` — next/previous git diff hunk in this buffer.
        if (key.matches('g', .{})) {
            try core.jumpToHunk(prefix == ']');
            return true;
        }
        // Tree-sitter AST motions:
        //   `]s` / `[s` — next/previous sibling
        //   `]m` / `[m` — next/previous function or method
        if (key.matches('s', .{})) {
            if (try core.jumpToSibling(prefix == ']')) return true;
            return true;
        }
        if (key.matches('m', .{})) {
            if (try core.jumpToFunction(prefix == ']')) return true;
            return true;
        }
        // Fall through and let the new key be dispatched normally.
    }
    if (key.matches(']', .{}) and !core.leader_pending) {
        core.bracket_pending = ']';
        return true;
    }
    if (key.matches('[', .{}) and !core.leader_pending) {
        core.bracket_pending = '[';
        return true;
    }
    if (core.leader_pending) {
        // Refresh the chord-timeout timestamp on every
        // follow-up key. vim-style `timeoutlen` semantics: the
        // window is "time since last key in the chord", not
        // "time since chord started." Without this, holding
        // `n`/`p` for >2s (rapid buffer cycling via autorepeat)
        // mid-chord triggers the auto-cancel from L4 even
        // though the user is *actively* driving the chord.
        core.leader_pending_set_ms = std.Io.Clock.real.now(core.io).toMilliseconds();

        // Double-Space is a no-op. Without this, a second Space
        // would fall through to the top-level switch's `else`
        // branch (Space doesn't match any action_* codepoint)
        // and silently cancel the chord — exactly the behavior
        // a user does *not* want when they tap Space again
        // because they're not sure the first one registered.
        // Re-fire the toast so they see the chord is still open.
        if (key.matches(Keys.leader, .{})) {
            core.setStatusLiteralLeveled(.info, "Space ; for command help", 1500);
            return true;
        }

        // Plugin keybindings: manifests can declare a
        // chord like `"keybinding": "Space g s"`. We accumulate
        // ASCII keystrokes into `plugin_chord_buf` (after the
        // leader) and consult the manager. Exact match runs the
        // command; prefix match keeps the leader open; otherwise
        // we fall through to the built-in chord switch.
        if (key.codepoint > 0 and key.codepoint < 0x80) {
            const ch: u8 = @intCast(key.codepoint);
            // OOM on chord-buffer append would otherwise let
            // the next dispatch lookup miss the intended
            // plugin keybind silently — log so the user sees
            // *something* in the log when their `Space g s`
            // suddenly stops working.
            core.plugin_chord_buf.append(core.allocator, ch) catch |err| {
                log.warn("plugin chord buffer append failed (chord lookup may misroute): {s}", .{@errorName(err)});
            };
            // Build "Space <buf>" with spaces between chars.
            var seq: std.ArrayListUnmanaged(u8) = .empty;
            defer seq.deinit(core.allocator);
            seq.appendSlice(core.allocator, "Space") catch |err| {
                log.debug("plugin chord seq init failed: {s}", .{@errorName(err)});
            };
            for (core.plugin_chord_buf.items) |c| {
                seq.append(core.allocator, ' ') catch {};
                seq.append(core.allocator, c) catch {};
            }
            if (core.plugin_manager.lookupKeybind(seq.items)) |cmd_id| {
                core.syncPaneToState();
                core.command_registry.execute(cmd_id, core) catch |err| {
                    log.warn("plugin keybind '{s}' exec failed: {s}", .{ cmd_id, @errorName(err) });
                    core.macros.noteFailure(err);
                };
                core.plugin_chord_buf.clearRetainingCapacity();
                core.leader_pending = false;
                return true;
            }
            if (core.plugin_manager.isKeybindPrefix(seq.items)) {
                // Prefix match — keep leader open for the next char.
                return true;
            }
            // No plugin match — drop the chord buffer and fall
            // through to the built-in leader switch below.
            core.plugin_chord_buf.clearRetainingCapacity();
        }

        if (key.codepoint >= '0' and key.codepoint <= '9') {
            try core.leader_number_input.append(core.allocator, @intCast(key.codepoint));

            const num_str = core.leader_number_input.items;
            const buf_num = std.fmt.parseInt(usize, num_str, 10) catch 0;
            const total_buffers = core.buffer_manager.buffers.items.len;

            if (buf_num > 0 and buf_num <= total_buffers) {
                const next_possible = buf_num * 10;
                if (next_possible > total_buffers) {
                    core.leader_number_input.clearRetainingCapacity();
                    core.buffer_manager.switchTo(buf_num - 1);
                    core.refreshSyntaxForCurrentBuffer();
                    if (core.split_manager) |*sm| sm.setFocusedBuffer(core.buffer_manager.active_index);
                    return true;
                }
            }

            return true;
        }

        if (core.leader_number_input.items.len > 0) {
            const num_str = core.leader_number_input.items;
            const buf_num = std.fmt.parseInt(usize, num_str, 10) catch 0;
            core.leader_number_input.clearRetainingCapacity();

            if (buf_num > 0 and buf_num <= core.buffer_manager.buffers.items.len) {
                core.buffer_manager.switchTo(buf_num - 1);
                core.refreshSyntaxForCurrentBuffer();
                if (core.split_manager) |*sm| sm.setFocusedBuffer(core.buffer_manager.active_index);
            }
            return true;
        }

        log.debug("Leader action key: codepoint={d} ('{c}') shift={} chord={?c}", .{ key.codepoint, @as(u8, @intCast(key.codepoint & 0xFF)), key.mods.shift, core.leader_chord });

        // 1. Esc cancels the chord (and any pending sub-chord).
        if (key.matches(vaxis.Key.escape, .{})) {
            core.leader_pending = false;
            core.leader_chord = null;
            core.leader_help_requested = false;
            return true;
        }

        // 2. Which-key popup toggle. Honored even mid-chord so
        //    the user can peek at the sub-bindings of an LSP /
        //    git / window prefix. Three keystroke shapes work:
        //    `;` (unambiguous), `?` (universal convention), and
        //    `/` with shift (some terminals deliver Shift+/ that
        //    way). Does NOT clear leader_pending — the popup is
        //    informational, the chord stays armed.
        if (key.codepoint == Keys.action_which_key or
            key.codepoint == Keys.action_which_key_alt or
            (key.codepoint == '/' and key.mods.shift))
        {
            core.leader_help_requested = !core.leader_help_requested;
            return true;
        }

        // 3. If we're inside a sub-chord (`Space l <key>`), the
        //    incoming key is the sub-action. Dispatch, clear the
        //    sub-chord, but keep leader_pending true so the user
        //    can chain (`Space l d l h` → def then hover).
        if (core.leader_chord) |prefix| {
            try LeaderDispatch.handle(core, prefix, key);
            core.leader_chord = null;
            core.leader_help_requested = false;
            return true;
        }

        // 4. Chord-prefix detection. Enter the sub-state and
        //    wait for the next key. The which-key popup will
        //    auto-update to show this chord's contents.
        if (key.codepoint == Keys.chord_lsp or
            key.codepoint == Keys.chord_git or
            key.codepoint == Keys.chord_window or
            key.codepoint == Keys.chord_toggle)
        {
            core.leader_chord = @intCast(key.codepoint);
            return true;
        }

        // 5. Top-level single-step actions.
        switch (key.codepoint) {
            Keys.action_save => try core.saveCurrentFile(),
            // `Space f` retired. `Space e` is the single
            // entry point for the file explorer; `f` is left
            // unbound (free for a future feature). Cmd/Ctrl+O
            // still works as the global "open" shortcut.
            Keys.action_buffer => {
                core.recordJumpFromCurrent();
                core.previous_mode = core.mode;
                core.mode = .buffer_picker;
                core.buffer_manager.pickerReset();
                core.buffer_picker_number_input.clearRetainingCapacity();
                core.leader_pending = false;
            },
            Keys.action_file_explorer => {
                try core.openFileExplorer();
                core.leader_pending = false;
            },
            Keys.action_quit => return error.UserQuit,
            Keys.action_close => LeaderDispatch.closeCurrentPaneOrBuffer(core),
            Keys.action_next => {
                const s = core.state();
                if (s.file_path) |path| {
                    core.jump_list.recordJump(path, s.cursor_row, s.cursor_col) catch |err| {
                        log.debug("Failed to record jump location: {}", .{err});
                    };
                }
                core.syncStateToPane();
                core.buffer_manager.nextBuffer();
                core.refreshSyntaxForCurrentBuffer();
                if (core.split_manager) |*sm| sm.setFocusedBuffer(core.buffer_manager.active_index);
                core.syncPaneToState();
            },
            Keys.action_prev => {
                const s = core.state();
                if (s.file_path) |path| {
                    core.jump_list.recordJump(path, s.cursor_row, s.cursor_col) catch |err| {
                        log.debug("Failed to record jump location: {}", .{err});
                    };
                }
                core.syncStateToPane();
                core.buffer_manager.prevBuffer();
                core.refreshSyntaxForCurrentBuffer();
                if (core.split_manager) |*sm| sm.setFocusedBuffer(core.buffer_manager.active_index);
                core.syncPaneToState();
            },

            Keys.action_help => {
                try core.openVirtualBuffer("[HELP]", Help.help_text);
                core.leader_pending = false;
            },
            Keys.action_palette, Keys.action_palette_alt => {
                core.previous_mode = core.mode;
                core.mode = .command_palette;
                core.command_palette_input.clearRetainingCapacity();
                try core.updateCommandSearch();
                core.leader_pending = false;
            },
            Keys.action_undo => try EditCommands.cmdEditUndo(core),
            Keys.action_redo => try EditCommands.cmdEditRedo(core),
            Keys.action_jobs => try SystemCommands.cmdJobList(core),
            Keys.action_copy => try EditCommands.cmdEditCopy(core),
            Keys.action_cut => try EditCommands.cmdEditCut(core),
            Keys.action_paste => try EditCommands.cmdEditPaste(core),

            Keys.action_code_action => try LspCommands.cmdLspCodeAction(core),
            Keys.action_center_view => {
                // Center view edits scroll_offset on the buffer
                // state. In split mode the pane has its *own*
                // scroll_offset that masks the buffer's; sync
                // before/after so the scroll is actually visible.
                core.syncStateToPane();
                try NavCommands.cmdNavCenterView(core);
                core.syncPaneToState();
            },
            Keys.action_bookmarks => {
                // Opens the [Bookmarks] view from the leader so
                // users following the `Space <letter>` convention
                // can reach bookmarks without remembering the
                // direct `m<a-z>` chord. Direct chord still works.
                try core.openBookmarksBuffer();
                core.leader_pending = false;
            },

            Keys.action_jump_back => try NavCommands.cmdJumpBack(core),
            Keys.action_jump_forward => try NavCommands.cmdJumpForward(core),

            // Top-level split shortcuts — `Space -` / `Space |`
            // are common enough to deserve a single-step
            // binding alongside the `Space w` chord.
            Keys.action_split_horizontal => try SplitCommands.cmdSplitHorizontal(core),
            Keys.action_split_vertical => try SplitCommands.cmdSplitVertical(core),

            Keys.action_global_search => {
                core.previous_mode = core.mode;
                core.mode = .global_search;
                core.global_search_query.clearRetainingCapacity();
                core.global_search_replace.clearRetainingCapacity();
                core.global_search_selected_file = 0;
                core.global_search_selected_match = 0;
                core.global_search_focus_replace = false;
                core.clearGlobalSearchResults();
                core.global_search_ran = false;
                core.leader_pending = false;
            },

            vaxis.Key.left => {
                LeaderDispatch.focusPaneLeft(core);
                core.leader_pending = false;
            },
            vaxis.Key.right => {
                LeaderDispatch.focusPaneRight(core);
                core.leader_pending = false;
            },
            vaxis.Key.up => {
                LeaderDispatch.focusPaneUp(core);
                core.leader_pending = false;
            },
            vaxis.Key.down => {
                LeaderDispatch.focusPaneDown(core);
                core.leader_pending = false;
            },

            else => {
                // Unknown leader key — bail out of the chord
                // so the user can start fresh without Esc.
                core.leader_pending = false;
                core.leader_help_requested = false;
            },
        }
        return true;
    }

    if (key.codepoint >= '0' and key.codepoint <= '9' and !key.mods.alt and !key.mods.ctrl and !key.mods.super) {
        const digit = key.codepoint - '0';
        if (digit == 0 and core.nav_repeat_count == 0) {
            const s = core.state();
            s.cursor_col = 0;
            return true;
        }
        core.nav_repeat_count = core.nav_repeat_count * 10 + digit;
        return true;
    }

    const count = if (core.nav_repeat_count > 0) core.nav_repeat_count else 1;
    core.nav_repeat_count = 0;

    if (key.matches(Keys.leader, .{})) {
        core.leader_pending = true;
        core.leader_pending_set_ms = std.Io.Clock.real.now(core.io).toMilliseconds();
        core.leader_help_requested = false;
        // Toast the hint so the user knows the chord is open and
        // there's a way to see all the bindings without trial
        // and error. Short enough to never get in the way.
        core.setStatusLiteralLeveled(.info, "Space ; for command help", 1500);
        return true;
    }

    if (key.matches(Keys.save.codepoint, Keys.save.mods)) {
        try core.saveCurrentFile();
        return true;
    }
    if (key.matches(Keys.open.codepoint, Keys.open.mods)) {
        try core.openFileExplorer();
        return true;
    }
    if (key.matches(Keys.quit.codepoint, Keys.quit.mods)) {
        return error.UserQuit;
    }
    if (key.matches(Keys.close_buffer.codepoint, Keys.close_buffer.mods)) {
        log.info("Cmd+W pressed", .{});
        if (core.split_manager) |*sm| {
            log.info("split_manager exists, hasSplits={}", .{sm.hasSplits()});
            log.info("focused_pane_id={}, countPanes={}", .{ sm.getFocusedPaneId(), sm.countPanes() });
            if (sm.hasSplits()) {
                core.syncStateToPane();
                sm.closePane();
                log.info("After closePane: hasSplits={}, countPanes={}", .{ sm.hasSplits(), sm.countPanes() });
                core.syncPaneToState();
                const remaining_pane = sm.getFocusedPane();
                log.info("remaining_pane id={}, buffer_index={}", .{ remaining_pane.id, remaining_pane.buffer_index });
                if (remaining_pane.buffer_index < core.buffer_manager.buffers.items.len) {
                    core.buffer_manager.active_index = remaining_pane.buffer_index;
                    log.info("Set buffer_manager.active_index={}", .{core.buffer_manager.active_index});
                }
                if (!sm.hasSplits()) {
                    log.info("No more splits, deiniting split_manager", .{});
                    sm.deinit();
                    core.split_manager = null;
                }
            } else {
                log.info("hasSplits=false, deiniting", .{});
                const pane = sm.getFocusedPane();
                if (pane.buffer_index < core.buffer_manager.buffers.items.len) {
                    core.buffer_manager.active_index = pane.buffer_index;
                }
                sm.deinit();
                core.split_manager = null;
            }
            log.info("Calling sendUpdate, split_manager null={}", .{core.split_manager == null});
            try core.sendUpdate();
        } else {
            log.info("No split_manager, closing active buffer", .{});
            _ = core.buffer_manager.closeActive();
        }
        return true;
    }
    if (key.matches(Keys.next_buffer.codepoint, Keys.next_buffer.mods)) {
        core.syncStateToPane();
        core.buffer_manager.nextBuffer();
        core.refreshSyntaxForCurrentBuffer();
        if (core.split_manager) |*sm| sm.setFocusedBuffer(core.buffer_manager.active_index);
        core.syncPaneToState();
        return true;
    }
    if (key.matches(Keys.prev_buffer.codepoint, Keys.prev_buffer.mods)) {
        core.syncStateToPane();
        core.buffer_manager.prevBuffer();
        core.refreshSyntaxForCurrentBuffer();
        if (core.split_manager) |*sm| sm.setFocusedBuffer(core.buffer_manager.active_index);
        core.syncPaneToState();
        return true;
    }

    if (key.matches(Keys.mode_view, .{})) {
        core.mode = .view;
        return true;
    }
    if (key.matches(Keys.mode_insert, .{})) {
        if (core.rejectReadOnlyPresentationEdit()) return true;
        core.mode = .insert;
        return true;
    }
    if (key.matches('v', .{})) {
        core.mode = .visual;
        const s = core.state();
        s.selection_anchor = .{ .row = s.cursor_row, .col = s.cursor_col };
        return true;
    }
    // `V` selects the smallest AST node under the cursor — entry
    // point for tree-sitter aware visual editing. `+` / `-` in
    // visual mode then expand or shrink the selection.
    if (key.matches('V', .{})) {
        const s = core.state();
        if (core.syntax_manager.selectCurrentNode(s.cursor_row, s.cursor_col)) |sel| {
            s.selection_anchor = .{ .row = sel.start_line, .col = sel.start_col };
            s.cursor_row = sel.end_line;
            s.cursor_col = sel.end_col;
            core.mode = .visual;
            return true;
        }
        // Fallthrough: no tree, leave to normal handling.
    }
    if (key.matches(Keys.mode_terminal, .{})) {
        core.mode = .terminal;
        core.terminal_input.clearRetainingCapacity();
        return true;
    }

    if (core.split_manager) |*sm| {
        if (key.matches('h', .{ .ctrl = true })) {
            core.syncStateToPane();
            sm.focusLeft();
            core.syncPaneToState();
            core.invalidatePaneHeightCache();
            return true;
        }
        if (key.matches('l', .{ .ctrl = true })) {
            core.syncStateToPane();
            sm.focusRight();
            core.syncPaneToState();
            core.invalidatePaneHeightCache();
            return true;
        }
        if (key.matches('k', .{ .ctrl = true })) {
            core.syncStateToPane();
            sm.focusUp();
            core.syncPaneToState();
            core.invalidatePaneHeightCache();
            return true;
        }
        if (key.matches('j', .{ .ctrl = true })) {
            core.syncStateToPane();
            sm.focusDown();
            core.syncPaneToState();
            core.invalidatePaneHeightCache();
            return true;
        }
    }

    if (key.matches(vaxis.Key.left, .{}) or key.matches(Keys.nav_left, .{})) {
        const s = core.state();
        var i: usize = 0;
        while (i < count) : (i += 1) try s.moveCursorLeftGrapheme();
        return true;
    }
    if (key.matches(vaxis.Key.right, .{}) or key.matches(Keys.nav_right, .{})) {
        const s = core.state();
        var i: usize = 0;
        while (i < count) : (i += 1) try s.moveCursorRightGrapheme();
        return true;
    }
    if (key.matches(vaxis.Key.down, .{}) or key.matches(Keys.nav_down, .{})) {
        core.state().moveCursorDown(count);
        return true;
    }
    if (key.matches(vaxis.Key.up, .{}) or key.matches(Keys.nav_up, .{})) {
        core.state().moveCursorUp(count);
        return true;
    }
    if (key.matches(vaxis.Key.page_down, .{})) {
        core.state().moveCursorDown(20 * count);
        core.scroll_in_progress = true;
        core.last_scroll_time = std.Io.Clock.real.now(core.io).toMilliseconds();
        return true;
    }
    if (key.matches(vaxis.Key.page_up, .{})) {
        core.state().moveCursorUp(20 * count);
        core.scroll_in_progress = true;
        core.last_scroll_time = std.Io.Clock.real.now(core.io).toMilliseconds();
        return true;
    }
    if (key.matches(vaxis.Key.home, .{})) {
        core.state().moveCursorToLineStart();
        return true;
    }
    if (key.matches(vaxis.Key.end, .{})) {
        core.state().moveCursorToLineEnd();
        return true;
    }

    // Bookmark chord triggers. `m` opens the set chord; `'` opens
    // the jump chord. The follow-up letter resolves both.
    if (key.matches('m', .{})) {
        core.bookmark_set_pending = true;
        core.setStatusLiteralLeveled(.info, "Set bookmark: a-z", 2000);
        return true;
    }
    if (key.matches('\'', .{})) {
        core.bookmark_jump_pending = true;
        core.setStatusLiteralLeveled(.info, "Jump to bookmark: a-z", 2000);
        return true;
    }

    // Text-object trigger. `s` starts the chord; `i <c>` / `a <c>`
    // resolve it.
    if (key.matches('s', .{})) {
        core.text_object_state = .s_seen;
        core.setStatusLiteralLeveled(.info, "Select: i<c>=inside, a<c>=around (w W p \" ' ` ( [ { <)", 2500);
        return true;
    }

    // Multi-cursor: add next occurrence of the word under cursor
    // (or current selection in visual mode) as a secondary cursor.
    if (key.matches('d', .{ .ctrl = true })) {
        try core.addNextOccurrence();
        return true;
    }

    // Word motions: vim-style w/b/e for word boundaries (mixing
    // identifier and punctuation runs), W/B for WORD boundaries
    // (whitespace-separated). `e` lands on the last char of a word.
    if (key.matches('w', .{})) {
        const s = core.state();
        var i: usize = 0;
        while (i < count) : (i += 1) try s.moveCursorNextWord();
        return true;
    }
    if (key.matches('b', .{})) {
        const s = core.state();
        var i: usize = 0;
        while (i < count) : (i += 1) try s.moveCursorPrevWord();
        return true;
    }
    if (key.matches('e', .{})) {
        const s = core.state();
        var i: usize = 0;
        while (i < count) : (i += 1) try s.moveCursorNextWordEnd();
        return true;
    }
    if (key.matches('W', .{ .shift = true })) {
        const s = core.state();
        var i: usize = 0;
        while (i < count) : (i += 1) try s.moveCursorNextBigWord();
        return true;
    }
    if (key.matches('B', .{ .shift = true })) {
        const s = core.state();
        var i: usize = 0;
        while (i < count) : (i += 1) try s.moveCursorPrevBigWord();
        return true;
    }

    // Paragraph jumps: `}` next blank-line-separated block, `{` previous.
    if (key.matches('}', .{ .shift = true })) {
        const s = core.state();
        var i: usize = 0;
        while (i < count) : (i += 1) s.moveCursorNextParagraph();
        return true;
    }
    if (key.matches('{', .{ .shift = true })) {
        const s = core.state();
        var i: usize = 0;
        while (i < count) : (i += 1) s.moveCursorPrevParagraph();
        return true;
    }

    if (key.matches('%', .{ .shift = true })) {
        // Bracket jump can travel many lines; record the start
        // so the user can Space , back.
        core.recordJumpFromCurrent();
        try NavCommands.cmdNavMatchBracket(core);
        return true;
    }

    // Vim-convention jump-list aliases. `Ctrl+O` walks back
    // through `jump_list`, `Ctrl+I` walks forward. Equivalent
    // to `Space ,` / `Space .` — present so users with vim/
    // helix muscle memory don't have to relearn the leader.
    if (key.matches('o', .{ .ctrl = true })) {
        try NavCommands.cmdJumpBack(core);
        return true;
    }
    if (key.matches('i', .{ .ctrl = true })) {
        try NavCommands.cmdJumpForward(core);
        return true;
    }

    if (key.matches(Keys.search_next, .{})) {
        if (core.last_search_query.items.len > 0) {
            const s = core.state();
            const query = core.last_search_query.items;
            const start_offset = s.getOffsetFromCursor() + 1;

            if (try s.buffer.find(query, start_offset)) |found_offset| {
                s.updateCursorFromOffset(found_offset);
                s.preferred_col = null;
                core.setStatus("Next match: {s}", .{query}, 1500);
            } else if (try s.buffer.find(query, 0)) |found_offset| {
                s.updateCursorFromOffset(found_offset);
                s.preferred_col = null;
                core.setStatusLeveled(.info, "Search wrapped to top: {s}", .{query}, 1500);
            } else {
                core.setStatusLeveled(.warning, "No match for {s}", .{query}, 1500);
            }
        } else {
            core.setStatusLiteralLeveled(.info, "No previous search", 1500);
        }
        return true;
    }
    if (key.matches(Keys.search_prev, .{})) {
        if (core.last_search_query.items.len > 0) {
            const s = core.state();
            const query = core.last_search_query.items;
            const end_offset = s.getOffsetFromCursor();

            if (try s.buffer.findLast(query, end_offset)) |found_offset| {
                s.updateCursorFromOffset(found_offset);
                s.preferred_col = null;
                core.setStatus("Previous match: {s}", .{query}, 1500);
            } else blk: {
                const len = s.buffer.totalLength();
                if (try s.buffer.findLast(query, len)) |found_offset| {
                    s.updateCursorFromOffset(found_offset);
                    s.preferred_col = null;
                    core.setStatusLeveled(.info, "Search wrapped to bottom: {s}", .{query}, 1500);
                    break :blk;
                }
                core.setStatusLeveled(.warning, "No match for {s}", .{query}, 1500);
            }
        } else {
            core.setStatusLiteralLeveled(.info, "No previous search", 1500);
        }
        return true;
    }

    if (key.matches('/', .{})) {
        try core.enterIncrementalSearch(.select, .forward);
        return true;
    }
    if (key.matches('?', .{ .shift = true })) {
        try core.enterIncrementalSearch(.select, .backward);
        return true;
    }

    return false;
}
