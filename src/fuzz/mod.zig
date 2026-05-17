const std = @import("std");

pub const piece_table_fuzz = @import("piece_table_fuzz.zig");
pub const editor_state_fuzz = @import("editor_state_fuzz.zig");
pub const uri_fuzz = @import("uri_fuzz.zig");
pub const lsp_json_fuzz = @import("lsp_json_fuzz.zig");
pub const config_setbypath_fuzz = @import("config_setbypath_fuzz.zig");

test {
    std.testing.refAllDecls(@This());
}
