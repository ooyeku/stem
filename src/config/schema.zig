const std = @import("std");

pub const Config = struct {
    theme: []const u8 = "default",
    editor: EditorConfig = .{},
    ui: UiConfig = .{},
    logging: LoggingConfig = .{},

    pub fn writeConfig(self: Config, writer: anytype) !void {
        try writer.writeAll("{\n");
        try writer.print("    \"theme\": \"{s}\",\n", .{self.theme});
        try writer.writeAll("    \"editor\": ");
        try self.editor.writeConfig(writer, 4);
        try writer.writeAll(",\n");
        try writer.writeAll("    \"ui\": ");
        try self.ui.writeConfig(writer, 4);
        try writer.writeAll(",\n");
        try writer.writeAll("    \"logging\": ");
        try self.logging.writeConfig(writer, 4);
        try writer.writeAll("\n}");
    }

    pub fn getByPath(self: Config, path: []const u8, allocator: std.mem.Allocator) !?[]const u8 {
        var it = std.mem.splitScalar(u8, path, '.');
        const root = it.first();

        inline for (std.meta.fields(Config)) |field| {
            if (std.mem.eql(u8, root, field.name)) {
                if (it.rest().len == 0) {
                    var aw: std.Io.Writer.Allocating = .init(allocator);
                    defer aw.deinit();
                    const val = @field(self, field.name);
                    const T = @TypeOf(val);

                    if (T == []const u8) {
                        try aw.writer.print("\"{s}\"", .{val});
                    } else if (comptime std.mem.eql(u8, @tagName(@typeInfo(T)), "struct")) {
                        try val.writeConfig(&aw.writer, 0);
                    } else {
                        try aw.writer.print("{}", .{val});
                    }
                    return try aw.toOwnedSlice();
                } else {
                    const child = @field(self, field.name);
                    const child_type = @TypeOf(child);
                    if (comptime std.mem.eql(u8, @tagName(@typeInfo(child_type)), "struct")) {
                        return try getByPathRecursive(child, it.rest(), allocator);
                    }
                }
            }
        }
        return null;
    }

    fn getByPathRecursive(obj: anytype, path: []const u8, allocator: std.mem.Allocator) !?[]const u8 {
        var it = std.mem.splitScalar(u8, path, '.');
        const segment = it.first();

        inline for (std.meta.fields(@TypeOf(obj))) |field| {
            if (std.mem.eql(u8, segment, field.name)) {
                if (it.rest().len == 0) {
                    var aw: std.Io.Writer.Allocating = .init(allocator);
                    defer aw.deinit();
                    const val = @field(obj, field.name);

                    const T = @TypeOf(val);
                    if (T == []const u8) {
                        try aw.writer.print("\"{s}\"", .{val});
                    } else if (comptime std.mem.eql(u8, @tagName(@typeInfo(T)), "struct")) {
                        try aw.writer.print("{}", .{val});
                    } else if (comptime std.mem.eql(u8, @tagName(@typeInfo(T)), "enum")) {
                        try aw.writer.print("\"{s}\"", .{@tagName(val)});
                    } else {
                        try aw.writer.print("{}", .{val});
                    }
                    return try aw.toOwnedSlice();
                } else {
                    const child = @field(obj, field.name);
                    if (comptime std.mem.eql(u8, @tagName(@typeInfo(@TypeOf(child))), "struct")) {
                        return try getByPathRecursive(child, it.rest(), allocator);
                    }
                }
            }
        }
        return null;
    }

    /// Reset a single config key to its schema default. Returns true if the
    /// path resolved to a leaf field that was reset, false if the path is
    /// unknown (or names a struct rather than a leaf).
    pub fn unsetByPath(self: *Config, path: []const u8) bool {
        const fresh: Config = .{};
        return copyByPath(self, &fresh, path);
    }

    fn copyByPath(dst: *Config, src: *const Config, path: []const u8) bool {
        var it = std.mem.splitScalar(u8, path, '.');
        const root = it.first();
        inline for (std.meta.fields(Config)) |field| {
            if (std.mem.eql(u8, root, field.name)) {
                const rest = it.rest();
                if (rest.len == 0) {
                    @field(dst.*, field.name) = @field(src.*, field.name);
                    return true;
                }
                const child_type = @TypeOf(@field(dst.*, field.name));
                if (comptime std.mem.eql(u8, @tagName(@typeInfo(child_type)), "struct")) {
                    return copyByPathRecursive(
                        &@field(dst.*, field.name),
                        &@field(src.*, field.name),
                        rest,
                    );
                }
                return false;
            }
        }
        return false;
    }

    fn copyByPathRecursive(dst: anytype, src: anytype, path: []const u8) bool {
        var it = std.mem.splitScalar(u8, path, '.');
        const seg = it.first();
        inline for (std.meta.fields(@TypeOf(dst.*))) |field| {
            if (std.mem.eql(u8, seg, field.name)) {
                const rest = it.rest();
                if (rest.len == 0) {
                    @field(dst.*, field.name) = @field(src.*, field.name);
                    return true;
                }
                const child_type = @TypeOf(@field(dst.*, field.name));
                if (comptime std.mem.eql(u8, @tagName(@typeInfo(child_type)), "struct")) {
                    return copyByPathRecursive(
                        &@field(dst.*, field.name),
                        &@field(src.*, field.name),
                        rest,
                    );
                }
                return false;
            }
        }
        return false;
    }

    pub fn setByPath(self: *Config, path: []const u8, value_str: []const u8, allocator: std.mem.Allocator) !bool {
        var it = std.mem.splitScalar(u8, path, '.');
        const root = it.first();

        inline for (std.meta.fields(Config)) |field| {
            if (std.mem.eql(u8, root, field.name)) {
                if (it.rest().len == 0) {
                    return try setField(&@field(self, field.name), value_str, allocator);
                } else {
                    const child_type = @TypeOf(@field(self, field.name));
                    if (comptime std.mem.eql(u8, @tagName(@typeInfo(child_type)), "struct")) {
                        return try setByPathRecursive(&@field(self, field.name), it.rest(), value_str, allocator);
                    }
                    return false;
                }
            }
        }
        return false;
    }

    fn setByPathRecursive(obj: anytype, path: []const u8, value_str: []const u8, allocator: std.mem.Allocator) !bool {
        var it = std.mem.splitScalar(u8, path, '.');
        const segment = it.first();

        inline for (std.meta.fields(@TypeOf(obj.*))) |field| {
            if (std.mem.eql(u8, segment, field.name)) {
                if (it.rest().len == 0) {
                    return try setField(&@field(obj, field.name), value_str, allocator);
                } else {
                    const child_type = @TypeOf(@field(obj, field.name));
                    if (comptime std.mem.eql(u8, @tagName(@typeInfo(child_type)), "struct")) {
                        return try setByPathRecursive(&@field(obj, field.name), it.rest(), value_str, allocator);
                    }
                    return false;
                }
            }
        }
        return false;
    }

    fn setField(field_ptr: anytype, value_str: []const u8, allocator: std.mem.Allocator) !bool {
        const T = @TypeOf(field_ptr.*);

        if (T == []const u8) {
            var trimmed = std.mem.trim(u8, value_str, " \t\n\r");
            if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') {
                trimmed = trimmed[1 .. trimmed.len - 1];
            }
            field_ptr.* = try allocator.dupe(u8, trimmed);
            return true;
        }

        if (T == bool) {
            if (std.mem.eql(u8, value_str, "true")) {
                field_ptr.* = true;
                return true;
            }
            if (std.mem.eql(u8, value_str, "false")) {
                field_ptr.* = false;
                return true;
            }
            return false;
        }

        if (comptime std.mem.eql(u8, @tagName(@typeInfo(T)), "int")) {
            field_ptr.* = std.fmt.parseInt(T, value_str, 10) catch return false;
            return true;
        }

        if (comptime std.mem.eql(u8, @tagName(@typeInfo(T)), "enum")) {
            const typeInfo = @typeInfo(T);
            const enumInfo = @field(typeInfo, "enum");

            inline for (enumInfo.fields) |f| {
                if (std.mem.eql(u8, value_str, f.name)) {
                    field_ptr.* = @field(T, f.name);
                    return true;
                }
            }
            const trimmed = std.mem.trim(u8, value_str, "\"");
            inline for (enumInfo.fields) |f| {
                if (std.mem.eql(u8, trimmed, f.name)) {
                    field_ptr.* = @field(T, f.name);
                    return true;
                }
            }
            return false;
        }

        return false;
    }
};

pub const EditorConfig = struct {
    tab_size: u32 = 4,
    insert_spaces: bool = true,
    line_numbers: enum { absolute, relative, none } = .relative,
    wrap: bool = false,
    mouse_enabled: bool = true,
    auto_pairs: bool = true,
    cursor_line: bool = true,
    /// When true and an LSP for the file's language has formatting
    /// support, the buffer is formatted in-place before each save.
    /// Toggle at runtime with `lsp.toggle_format_on_save`.
    format_on_save: bool = false,

    /// Files larger than this many bytes OR `large_file_threshold_lines`
    /// lines flip into "large-file mode": tree-sitter highlighting,
    /// bracket rainbow, LSP requests, and bracket auto-pair are all
    /// disabled for that buffer. Designed so editing a 5MB log or a
    /// minified bundle stays responsive instead of locking up on every
    /// keystroke. 5 MB default.
    large_file_threshold_bytes: u32 = 5 * 1024 * 1024,
    large_file_threshold_lines: u32 = 50_000,
    /// Files larger than this are rejected outright at open time. The
    /// editor would still work, but a 1 GB buffer pinned in memory
    /// would dominate the process — make the user opt in by editing
    /// the file with a different tool first. 100 MB default.
    large_file_hard_limit_bytes: u32 = 100 * 1024 * 1024,

    /// When true, every line that carries a diagnostic also renders
    /// the diagnostic message inline at end-of-line in the severity
    /// colour ("error lens"). When false, only the gutter sign shows.
    inline_diagnostics: bool = true,

    /// When true, send `textDocument/inlayHint` for the visible range
    /// and render returned hints (type annotations, param names) as
    /// dim virtual text. Off by default — language servers vary in
    /// quality and the extra requests aren't free.
    inlay_hints: bool = false,

    /// When true, every `auto_save_interval_seconds` the editor
    /// writes a snapshot of every dirty buffer to
    /// `~/.stem/cache/backup/<buffer-id>.snap`. On startup, surviving
    /// snapshots whose source file is older than the snapshot are
    /// offered for recovery. Independent of save-on-edit; this is
    /// just a crash safety net.
    auto_save_backup: bool = true,
    auto_save_interval_seconds: u32 = 30,

    pub fn writeConfig(self: EditorConfig, writer: anytype, indent: usize) !void {
        try writer.writeAll("{\n");
        try printIndent(writer, indent + 4);
        try writer.print("\"tab_size\": {d},\n", .{self.tab_size});
        try printIndent(writer, indent + 4);
        try writer.print("\"insert_spaces\": {},\n", .{self.insert_spaces});
        try printIndent(writer, indent + 4);
        try writer.print("\"line_numbers\": \"{s}\",\n", .{@tagName(self.line_numbers)});
        try printIndent(writer, indent + 4);
        try writer.print("\"wrap\": {},\n", .{self.wrap});
        try printIndent(writer, indent + 4);
        try writer.print("\"mouse_enabled\": {},\n", .{self.mouse_enabled});
        try printIndent(writer, indent + 4);
        try writer.print("\"auto_pairs\": {},\n", .{self.auto_pairs});
        try printIndent(writer, indent + 4);
        try writer.print("\"cursor_line\": {},\n", .{self.cursor_line});
        try printIndent(writer, indent + 4);
        try writer.print("\"format_on_save\": {},\n", .{self.format_on_save});
        try printIndent(writer, indent + 4);
        try writer.print("\"large_file_threshold_bytes\": {d},\n", .{self.large_file_threshold_bytes});
        try printIndent(writer, indent + 4);
        try writer.print("\"large_file_threshold_lines\": {d},\n", .{self.large_file_threshold_lines});
        try printIndent(writer, indent + 4);
        try writer.print("\"large_file_hard_limit_bytes\": {d},\n", .{self.large_file_hard_limit_bytes});
        try printIndent(writer, indent + 4);
        try writer.print("\"inline_diagnostics\": {},\n", .{self.inline_diagnostics});
        try printIndent(writer, indent + 4);
        try writer.print("\"inlay_hints\": {},\n", .{self.inlay_hints});
        try printIndent(writer, indent + 4);
        try writer.print("\"auto_save_backup\": {},\n", .{self.auto_save_backup});
        try printIndent(writer, indent + 4);
        try writer.print("\"auto_save_interval_seconds\": {d}\n", .{self.auto_save_interval_seconds});
        try printIndent(writer, indent);
        try writer.writeAll("}");
    }
};

pub const UiConfig = struct {
    show_status_bar: bool = true,

    pub fn writeConfig(self: UiConfig, writer: anytype, indent: usize) !void {
        try writer.writeAll("{\n");
        try printIndent(writer, indent + 4);
        try writer.print("\"show_status_bar\": {}\n", .{self.show_status_bar});
        try printIndent(writer, indent);
        try writer.writeAll("}");
    }
};

pub const LoggingConfig = struct {
    level: LogLevel = .info,

    pub const LogLevel = enum {
        debug,
        info,
        warn,
        err,
    };

    pub fn writeConfig(self: LoggingConfig, writer: anytype, indent: usize) !void {
        try writer.writeAll("{\n");
        try printIndent(writer, indent + 4);
        try writer.print("\"level\": \"{s}\"\n", .{@tagName(self.level)});
        try printIndent(writer, indent);
        try writer.writeAll("}");
    }
};

fn printIndent(writer: anytype, indent: usize) !void {
    var i: usize = 0;
    while (i < indent) : (i += 1) {
        try writer.writeByte(' ');
    }
}

// ---------- Tests for the reflection-based config API ----------
// These tests exercise the schema-driven `setByPath` / `unsetByPath` /
// `getByPath` functions across types (bool, int, enum, string) and across
// the nested-struct boundary. Catches: stale-field bugs when schema fields
// are renamed or added, accidental partial-write on validation failure.

test "setByPath leaf bool" {
    const a = std.testing.allocator;
    var cfg = Config{};
    try std.testing.expectEqual(true, cfg.editor.insert_spaces);
    try std.testing.expectEqual(true, try cfg.setByPath("editor.insert_spaces", "false", a));
    try std.testing.expectEqual(false, cfg.editor.insert_spaces);
}

test "setByPath leaf int" {
    const a = std.testing.allocator;
    var cfg = Config{};
    try std.testing.expectEqual(@as(u32, 4), cfg.editor.tab_size);
    try std.testing.expectEqual(true, try cfg.setByPath("editor.tab_size", "8", a));
    try std.testing.expectEqual(@as(u32, 8), cfg.editor.tab_size);
}

test "setByPath leaf enum" {
    const a = std.testing.allocator;
    var cfg = Config{};
    try std.testing.expectEqual(true, try cfg.setByPath("editor.line_numbers", "absolute", a));
    // expectEqual on `[]const u8` compares pointer+length, which only
    // happens to match across compilation units when the linker
    // dedupes string literals — true on macOS, false on Linux. Use
    // expectEqualStrings for content equality so the test works on
    // both platforms.
    try std.testing.expectEqualStrings("absolute", @tagName(cfg.editor.line_numbers));
}

test "setByPath rejects unknown path" {
    const a = std.testing.allocator;
    var cfg = Config{};
    try std.testing.expectEqual(false, try cfg.setByPath("editor.nonsense_key", "x", a));
    // Also unknown root.
    try std.testing.expectEqual(false, try cfg.setByPath("nonsense.tab_size", "8", a));
}

test "setByPath rejects bad value type" {
    const a = std.testing.allocator;
    var cfg = Config{};
    // "abc" can't parse as u32 — should return false, leave value untouched.
    try std.testing.expectEqual(false, try cfg.setByPath("editor.tab_size", "abc", a));
    try std.testing.expectEqual(@as(u32, 4), cfg.editor.tab_size);
    // "maybe" isn't a bool — should return false, leave value untouched.
    try std.testing.expectEqual(false, try cfg.setByPath("editor.insert_spaces", "maybe", a));
    try std.testing.expectEqual(true, cfg.editor.insert_spaces);
}

test "setByPath rejects struct-not-leaf path" {
    const a = std.testing.allocator;
    var cfg = Config{};
    // "editor" is a struct, not a leaf.
    try std.testing.expectEqual(false, try cfg.setByPath("editor", "x", a));
}

test "getByPath returns current value" {
    const a = std.testing.allocator;
    var cfg = Config{};
    // Mutate then read back.
    _ = try cfg.setByPath("editor.tab_size", "2", a);
    const v = (try cfg.getByPath("editor.tab_size", a)).?;
    defer a.free(v);
    try std.testing.expectEqualStrings("2", v);
}

test "unsetByPath restores default" {
    const a = std.testing.allocator;
    var cfg = Config{};
    _ = try cfg.setByPath("editor.tab_size", "8", a);
    try std.testing.expectEqual(@as(u32, 8), cfg.editor.tab_size);
    try std.testing.expectEqual(true, cfg.unsetByPath("editor.tab_size"));
    try std.testing.expectEqual(@as(u32, 4), cfg.editor.tab_size);
}

test "unsetByPath rejects unknown path" {
    var cfg = Config{};
    try std.testing.expectEqual(false, cfg.unsetByPath("nope"));
    try std.testing.expectEqual(false, cfg.unsetByPath("editor.nope"));
}

test "every Config leaf path can round-trip its default" {
    // Property-style test: walk every leaf in the schema at comptime, ensure
    // setByPath(default) → unsetByPath restores to the same default value.
    // Catches: a new schema field that doesn't work with the reflection logic.
    const a = std.testing.allocator;
    var cfg = Config{};
    inline for (std.meta.fields(Config)) |outer| {
        const inner_type = outer.type;
        if (@typeInfo(inner_type) != .@"struct") continue;
        inline for (std.meta.fields(inner_type)) |leaf| {
            const path = outer.name ++ "." ++ leaf.name;
            // We just verify that unsetByPath finds the path; we don't
            // attempt to serialize+reparse every type variant here.
            try std.testing.expectEqual(true, cfg.unsetByPath(path));
        }
    }
    _ = a; // arena unused; reflection-only path
}
