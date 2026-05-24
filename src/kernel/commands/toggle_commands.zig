//! Toggle-flavoured editor commands.
//!
//! These flip a single `editor.*` boolean in storage config and
//! announce the new state via the status bar. They were previously
//! inline in `core.zig`; extracted here so adding new toggles
//! doesn't bloat the monolith further. Follow the same `anytype
//! core` convention as the other `commands/*` modules so the
//! `Wrap(...).run` adapter in core.zig wires them into the command
//! registry without per-command trampolines.
//!
//! Adding a new toggle: write a function `cmdXxxToggle(core: anytype) anyerror!void`,
//! flip the config field, call `core.setStatus(...)`, `try core.sendUpdate()`.
//! Then register it in `core.zig`'s `registerCommands` with
//! `Wrap(ToggleCommands.cmdXxxToggle).run`.

pub const ToggleCommands = struct {
    pub fn cmdLspToggleFormatOnSave(core: anytype) anyerror!void {
        core.storage.config.editor.format_on_save = !core.storage.config.editor.format_on_save;
        const tag: []const u8 = if (core.storage.config.editor.format_on_save) "ON" else "OFF";
        core.setStatus("Format-on-save: {s}", .{tag}, 2000);
        try core.sendUpdate();
    }

    pub fn cmdEditorToggleInlineDiagnostics(core: anytype) anyerror!void {
        core.storage.config.editor.inline_diagnostics = !core.storage.config.editor.inline_diagnostics;
        const tag: []const u8 = if (core.storage.config.editor.inline_diagnostics) "ON" else "OFF";
        core.setStatus("Inline diagnostics: {s}", .{tag}, 2000);
        try core.sendUpdate();
    }

    pub fn cmdEditorToggleInlayHints(core: anytype) anyerror!void {
        core.storage.config.editor.inlay_hints = !core.storage.config.editor.inlay_hints;
        const tag: []const u8 = if (core.storage.config.editor.inlay_hints) "ON" else "OFF";
        core.setStatus("Inlay hints: {s}", .{tag}, 2000);
        try core.sendUpdate();
    }
};
