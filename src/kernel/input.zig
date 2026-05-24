//! Per-mode input dispatch.
//!
//! Each mode's key-event handler lives in its own file under
//! `kernel/input/`. This module aggregates them so the main
//! dispatch table in core.zig becomes:
//!
//!     .file_picker => try input.file_picker.handle(self, key),
//!     .visual      => try input.visual.handle(self, key),
//!     ... etc.
//!
//! Each handler is a top-level `pub fn handle(core: anytype,
//! key: vaxis.Key) !bool` returning whether the key was
//! consumed (mirrors the old `handle*Input` contract).
//!
//! See `docs/refactor-plan.md` step 5 for the rationale and the
//! extraction pattern.

pub const file_picker = @import("input/file_picker.zig");
pub const buffer_picker = @import("input/buffer_picker.zig");
pub const go_to_line = @import("input/go_to_line.zig");
pub const symbol_picker = @import("input/symbol_picker.zig");
pub const command_palette = @import("input/command_palette.zig");
pub const visual_search = @import("input/visual_search.zig");
pub const file_explorer = @import("input/file_explorer.zig");
pub const terminal = @import("input/terminal.zig");
pub const workspace_symbol_picker = @import("input/workspace_symbol_picker.zig");
pub const save_as = @import("input/save_as.zig");
pub const view = @import("input/view.zig");
pub const insert = @import("input/insert.zig");
pub const visual = @import("input/visual.zig");
pub const global_search = @import("input/global_search.zig");
pub const select = @import("input/select.zig");
