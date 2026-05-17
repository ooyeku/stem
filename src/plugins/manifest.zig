//! Plugin manifest parser.
//!
//! Manifest file format: `plugin.json` (sibling of the plugin binary,
//! inside the plugin's directory). Switched from the TOML draft for
//! Phase 1 because `std.json` makes this a ~50-line parser instead of
//! a TOML implementation. A future TOML reader can be additive: try
//! `plugin.toml` first, fall back to `plugin.json`.
//!
//! Example:
//!
//! ```json
//! {
//!   "name": "git",
//!   "version": "0.3.0",
//!   "description": "Git integration",
//!   "runtime": "exec",
//!   "entry": "stem-git",
//!   "permissions": {
//!     "spawn": ["git"],
//!     "filesystem": ["read:."],
//!     "events": ["buffer.*", "file.saved"]
//!   },
//!   "commands": [
//!     {"id": "git.status", "title": "[Git] Status", "description": "Show status"}
//!   ]
//! }
//! ```
//!
//! Plugin manager reads this BEFORE loading the binary so commands +
//! keybinds populate the palette at startup, and so the permissions
//! checker (Phase 3) can deny capability requests not declared here.

const std = @import("std");

pub const Runtime = enum {
    /// In-process dynamic library (Phase 0).
    dylib,
    /// Separate executable speaking JSON-RPC over stdio (Phase 1).
    exec,
    /// WebAssembly module loaded into stem's wasm runtime (Phase 2).
    wasm,

    pub fn fromString(s: []const u8) ?Runtime {
        if (std.mem.eql(u8, s, "dylib")) return .dylib;
        if (std.mem.eql(u8, s, "exec")) return .exec;
        if (std.mem.eql(u8, s, "wasm")) return .wasm;
        return null;
    }
};

pub const Permissions = struct {
    spawn_allowlist: []const []const u8 = &.{},
    filesystem: []const []const u8 = &.{},
    events: []const []const u8 = &.{},
};

pub const CommandDecl = struct {
    id: []const u8,
    title: []const u8,
    description: []const u8 = "",
    keybinding: ?[]const u8 = null,
};

pub const Manifest = struct {
    arena: std.heap.ArenaAllocator,
    name: []const u8,
    version: []const u8,
    description: []const u8 = "",
    runtime: Runtime,
    /// Path is interpreted relative to the manifest's directory.
    entry: []const u8,
    permissions: Permissions = .{},
    commands: []const CommandDecl = &.{},

    pub fn deinit(self: *Manifest) void {
        self.arena.deinit();
    }
};

pub fn parse(allocator: std.mem.Allocator, json_bytes: []const u8) !Manifest {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, aa, json_bytes, .{});
    // We keep `parsed` alive in the arena; freed wholesale when the
    // manifest is deinit'd.

    if (parsed.value != .object) return error.InvalidManifest;
    const root = parsed.value.object;

    const name = try takeString(root, "name");
    const version = try takeString(root, "version");
    const runtime_str = try takeString(root, "runtime");
    const entry = try takeString(root, "entry");

    const runtime = Runtime.fromString(runtime_str) orelse return error.InvalidRuntime;

    var manifest: Manifest = .{
        .arena = arena,
        .name = try aa.dupe(u8, name),
        .version = try aa.dupe(u8, version),
        .runtime = runtime,
        .entry = try aa.dupe(u8, entry),
    };

    if (root.get("description")) |v| {
        if (v != .string) return error.InvalidManifest;
        manifest.description = try aa.dupe(u8, v.string);
    }

    if (root.get("permissions")) |perms_val| {
        if (perms_val != .object) return error.InvalidManifest;
        const p = perms_val.object;
        manifest.permissions = .{
            .spawn_allowlist = try takeStringArray(aa, p, "spawn"),
            .filesystem = try takeStringArray(aa, p, "filesystem"),
            .events = try takeStringArray(aa, p, "events"),
        };
    }

    if (root.get("commands")) |cmds_val| {
        if (cmds_val != .array) return error.InvalidManifest;
        const cmds = cmds_val.array.items;
        var out = try aa.alloc(CommandDecl, cmds.len);
        for (cmds, 0..) |item, i| {
            if (item != .object) return error.InvalidManifest;
            const co = item.object;
            const id = try takeString(co, "id");
            const title = try takeString(co, "title");
            out[i] = .{
                .id = try aa.dupe(u8, id),
                .title = try aa.dupe(u8, title),
                .description = if (co.get("description")) |d|
                    if (d == .string) try aa.dupe(u8, d.string) else return error.InvalidManifest
                else
                    "",
                .keybinding = if (co.get("keybinding")) |k|
                    if (k == .string) try aa.dupe(u8, k.string) else return error.InvalidManifest
                else
                    null,
            };
        }
        manifest.commands = out;
    }

    return manifest;
}

fn takeString(obj: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const v = obj.get(key) orelse return error.InvalidManifest;
    if (v != .string) return error.InvalidManifest;
    return v.string;
}

fn takeStringArray(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
) ![]const []const u8 {
    const v = obj.get(key) orelse return &.{};
    if (v != .array) return error.InvalidManifest;
    const items = v.array.items;
    var out = try allocator.alloc([]const u8, items.len);
    for (items, 0..) |item, i| {
        if (item != .string) return error.InvalidManifest;
        out[i] = try allocator.dupe(u8, item.string);
    }
    return out;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parse: minimal manifest" {
    const a = std.testing.allocator;
    var m = try parse(a,
        \\{
        \\  "name": "echo",
        \\  "version": "0.1.0",
        \\  "runtime": "exec",
        \\  "entry": "stem-echo"
        \\}
    );
    defer m.deinit();
    try std.testing.expectEqualStrings("echo", m.name);
    try std.testing.expectEqualStrings("0.1.0", m.version);
    try std.testing.expectEqual(Runtime.exec, m.runtime);
    try std.testing.expectEqualStrings("stem-echo", m.entry);
}

test "parse: full manifest with permissions + commands" {
    const a = std.testing.allocator;
    var m = try parse(a,
        \\{
        \\  "name": "git",
        \\  "version": "0.3.0",
        \\  "description": "Git integration",
        \\  "runtime": "exec",
        \\  "entry": "stem-git",
        \\  "permissions": {
        \\    "spawn": ["git"],
        \\    "filesystem": ["read:."],
        \\    "events": ["buffer.*"]
        \\  },
        \\  "commands": [
        \\    {"id": "git.status", "title": "[Git] Status", "description": "Show status", "keybinding": "Space g s"},
        \\    {"id": "git.diff", "title": "[Git] Diff"}
        \\  ]
        \\}
    );
    defer m.deinit();
    try std.testing.expectEqual(@as(usize, 1), m.permissions.spawn_allowlist.len);
    try std.testing.expectEqualStrings("git", m.permissions.spawn_allowlist[0]);
    try std.testing.expectEqual(@as(usize, 2), m.commands.len);
    try std.testing.expectEqualStrings("git.status", m.commands[0].id);
    try std.testing.expectEqualStrings("Space g s", m.commands[0].keybinding.?);
    try std.testing.expectEqual(@as(?[]const u8, null), m.commands[1].keybinding);
}

test "parse: rejects unknown runtime" {
    const a = std.testing.allocator;
    const result = parse(a,
        \\{"name":"x","version":"0","runtime":"lua","entry":"foo"}
    );
    try std.testing.expectError(error.InvalidRuntime, result);
}

test "parse: rejects missing required field" {
    const a = std.testing.allocator;
    const result = parse(a,
        \\{"version":"0","runtime":"exec","entry":"foo"}
    );
    try std.testing.expectError(error.InvalidManifest, result);
}
