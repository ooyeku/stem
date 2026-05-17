//! Plugin manifest parser (Phase 1 scaffolding).
//!
//! Plugins ship a `plugin.toml` alongside their binary that declares
//! identity, commands, keybindings, event subscriptions, configuration
//! schema, and required OS capabilities. The editor reads the manifest
//! WITHOUT loading the binary so command palette + keybinds populate
//! at startup, and so the permissions checker can deny capability
//! requests the plugin didn't declare.
//!
//! Format example:
//!
//! ```toml
//! [plugin]
//! name = "git"
//! version = "0.3.0"
//! description = "Git integration"
//! runtime = "dylib"          # or "exec" / "wasm"
//! entry = "libgit.dylib"
//!
//! [plugin.permissions]
//! spawn = ["git"]
//! filesystem = ["read:."]
//! events = ["buffer.*", "file.saved"]
//!
//! [[plugin.commands]]
//! id = "git.status"
//! title = "[Git] Status"
//! description = "Show repository status"
//! keybinding = "Space g s"
//!
//! [plugin.config_schema]
//! "git.auto_status" = { type = "bool", default = true }
//! ```
//!
//! Status: stub. Full TOML parser + validator lands with Phase 1.

const std = @import("std");

pub const Runtime = enum {
    /// In-process dynamic library (Phase 0).
    dylib,
    /// Separate executable speaking JSON-RPC over stdio (Phase 1).
    exec,
    /// WebAssembly module loaded into stem's wasm runtime (Phase 2).
    wasm,
};

pub const Permissions = struct {
    /// Executable names the plugin is allowed to spawn. `["*"]` means
    /// "any executable" (use sparingly).
    spawn_allowlist: []const []const u8 = &.{},
    /// Filesystem grants: `read:<path>`, `write:<path>`. `path` is
    /// glob-matched.
    filesystem: []const []const u8 = &.{},
    /// Event topic patterns the plugin can subscribe to. Defaults
    /// to none — must be declared explicitly.
    events: []const []const u8 = &.{},
};

pub const CommandDecl = struct {
    id: []const u8,
    title: []const u8,
    description: []const u8 = "",
    keybinding: ?[]const u8 = null,
};

pub const Manifest = struct {
    name: []const u8,
    version: []const u8,
    description: []const u8 = "",
    runtime: Runtime,
    entry: []const u8,
    permissions: Permissions = .{},
    commands: []const CommandDecl = &.{},
    // `config_schema` is parsed but typed loosely until we add the
    // editor-side config UI (Phase 3).
    config_schema_json: ?[]const u8 = null,
};

pub fn parse(allocator: std.mem.Allocator, toml_bytes: []const u8) !Manifest {
    _ = allocator;
    _ = toml_bytes;
    // TODO(phase-1): vendor a tiny TOML parser or use std.json after
    // converting via a build-time codegen step. For now this is a
    // typed placeholder that the loader can pattern-match against
    // once Phase 1 lands.
    return error.NotYetImplemented;
}
