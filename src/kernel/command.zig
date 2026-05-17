const std = @import("std");

const test_utils = @import("../test_utils.zig");
const MemoryTestUtils = test_utils.MemoryTestUtils;
const PerformanceTestUtils = test_utils.PerformanceTestUtils;

pub const CommandFn = *const fn (ctx: *anyopaque, context: ?*const anyopaque) anyerror!void;

pub const Command = struct {
    id: []const u8,
    title: []const u8,
    description: []const u8,
    execute: CommandFn,
    context: ?*const anyopaque = null,
};

pub const CommandMatch = struct {
    command: Command,
    score: i64,
};

pub const CommandRegistry = struct {
    allocator: std.mem.Allocator,
    commands: std.StringHashMap(Command),

    pub fn init(allocator: std.mem.Allocator) CommandRegistry {
        return .{
            .allocator = allocator,
            .commands = std.StringHashMap(Command).init(allocator),
        };
    }

    pub fn deinit(self: *CommandRegistry) void {
        self.commands.deinit();
    }

    pub fn execute(self: *CommandRegistry, id: []const u8, ctx: *anyopaque) !void {
        if (self.commands.get(id)) |cmd| {
            try cmd.execute(ctx, cmd.context);
        } else {
            return error.CommandNotFound;
        }
    }

    pub fn register(self: *CommandRegistry, id: []const u8, title: []const u8, desc: []const u8, func: CommandFn, context: ?*const anyopaque) !void {
        const cmd = Command{
            .id = id,
            .title = title,
            .description = desc,
            .execute = func,
            .context = context,
        };
        try self.commands.put(id, cmd);
    }

    pub fn unregister(self: *CommandRegistry, id: []const u8) bool {
        return self.commands.remove(id);
    }

    pub fn search(self: *CommandRegistry, query: []const u8, out_results: *std.ArrayListUnmanaged(Command), allocator: std.mem.Allocator) !void {
        var matches = std.ArrayListUnmanaged(CommandMatch).empty;
        defer matches.deinit(self.allocator);

        var it = self.commands.valueIterator();
        while (it.next()) |cmd| {
            if (query.len == 0) {
                try matches.append(self.allocator, .{ .command = cmd.*, .score = 0 });
                continue;
            }

            const title_score = fuzzyScoreInternal(query, cmd.title);
            const desc_score = fuzzyScoreInternal(query, cmd.description);
            const id_score = fuzzyScoreInternal(query, cmd.id);
            const best_score = @max(title_score, @max(desc_score, id_score));

            if (best_score > 0) {
                const final_score = if (title_score == best_score) best_score + 50 else best_score;
                try matches.append(self.allocator, .{ .command = cmd.*, .score = final_score });
            }
        }

        std.sort.block(CommandMatch, matches.items, {}, compareScores);

        for (matches.items) |match| {
            try out_results.append(allocator, match.command);
        }
    }

    fn compareScores(context: void, a: CommandMatch, b: CommandMatch) bool {
        _ = context;
        return a.score > b.score;
    }

    fn fuzzyScore(query: []const u8, text: []const u8) i64 {
        return fuzzyScoreInternal(query, text);
    }

    pub fn fuzzyScoreForTest(query: []const u8, text: []const u8) i64 {
        return fuzzyScoreInternal(query, text);
    }

    fn fuzzyScoreInternal(query: []const u8, text: []const u8) i64 {
        if (query.len == 0) return 0;
        if (text.len == 0) return 0;
        if (containsSubstringInternal(text, query)) {
            return @as(i64, @intCast(100 + query.len * 10));
        }
        var score: i64 = 0;
        var q_idx: usize = 0;
        var last_match_idx: ?usize = null;
        var consecutive_bonus: i64 = 0;

        for (text, 0..) |t_byte, t_idx| {
            if (q_idx >= query.len) break;

            const q_char = std.ascii.toLower(query[q_idx]);
            const t_char = std.ascii.toLower(t_byte);

            if (q_char == t_char) {
                score += 10;

                if (last_match_idx) |last| {
                    if (t_idx == last + 1) {
                        consecutive_bonus += 5;
                    }
                }

                if (t_idx == 0 or text[t_idx - 1] == ' ' or text[t_idx - 1] == ':' or text[t_idx - 1] == '_' or text[t_idx - 1] == '.') {
                    score += 15;
                }

                if (t_idx > 0 and t_byte >= 'A' and t_byte <= 'Z') {
                    score += 10;
                }

                last_match_idx = t_idx;
                q_idx += 1;
            }
        }

        if (q_idx >= query.len) {
            return score + consecutive_bonus;
        }

        if (matchesInitialsInternal(query, text)) {
            return @as(i64, @intCast(50 + query.len * 5));
        }

        return 0;
    }

    fn containsSubstring(text: []const u8, query: []const u8) bool {
        return containsSubstringInternal(text, query);
    }

    pub fn containsSubstringForTest(text: []const u8, query: []const u8) bool {
        return containsSubstringInternal(text, query);
    }

    fn containsSubstringInternal(text: []const u8, query: []const u8) bool {
        if (query.len > text.len) return false;

        var i: usize = 0;
        while (i <= text.len - query.len) : (i += 1) {
            var matches = true;
            for (query, 0..) |q_char, j| {
                if (std.ascii.toLower(text[i + j]) != std.ascii.toLower(q_char)) {
                    matches = false;
                    break;
                }
            }
            if (matches) return true;
        }
        return false;
    }

    fn matchesInitials(query: []const u8, text: []const u8) bool {
        return matchesInitialsInternal(query, text);
    }

    pub fn matchesInitialsForTest(query: []const u8, text: []const u8) bool {
        return matchesInitialsInternal(query, text);
    }

    fn matchesInitialsInternal(query: []const u8, text: []const u8) bool {
        var q_idx: usize = 0;
        var at_word_start = true;

        for (text) |t_byte| {
            if (q_idx >= query.len) return true;

            if (t_byte == ' ' or t_byte == ':' or t_byte == '_') {
                at_word_start = true;
                continue;
            }

            if (at_word_start) {
                if (std.ascii.toLower(t_byte) == std.ascii.toLower(query[q_idx])) {
                    q_idx += 1;
                }
            }
            at_word_start = false;
        }

        return q_idx >= query.len;
    }
};

test "CommandRegistry init and deinit" {
    try MemoryTestUtils.testNoLeaks(std.testing.allocator, testCommandRegistryInit);
}

fn testCommandRegistryInit(allocator: std.mem.Allocator) !void {
    var registry = CommandRegistry.init(allocator);
    defer registry.deinit();

    try std.testing.expectEqual(@as(usize, 0), registry.commands.count());
}

test "CommandRegistry register basic command" {
    var registry = CommandRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const test_fn = struct {
        fn testFunc(ctx: *anyopaque, context: ?*const anyopaque) anyerror!void {
            _ = ctx;
            _ = context;
        }
    }.testFunc;

    try registry.register("test.cmd", "Test Command", "A test command", test_fn, null);

    try std.testing.expectEqual(@as(usize, 1), registry.commands.count());

    const cmd = registry.commands.get("test.cmd");
    try std.testing.expect(cmd != null);
    try std.testing.expectEqualStrings("test.cmd", cmd.?.id);
    try std.testing.expectEqualStrings("Test Command", cmd.?.title);
    try std.testing.expectEqualStrings("A test command", cmd.?.description);
}

test "CommandRegistry register multiple commands" {
    var registry = CommandRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const test_fn = struct {
        fn testFunc(ctx: *anyopaque, context: ?*const anyopaque) anyerror!void {
            _ = ctx;
            _ = context;
        }
    }.testFunc;

    try registry.register("cmd1", "Command 1", "First command", test_fn, null);
    try registry.register("cmd2", "Command 2", "Second command", test_fn, null);
    try registry.register("cmd3", "Command 3", "Third command", test_fn, null);

    try std.testing.expectEqual(@as(usize, 3), registry.commands.count());
}

test "CommandRegistry register command with context" {
    var registry = CommandRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const test_fn = struct {
        fn testFunc(ctx: *anyopaque, context: ?*const anyopaque) anyerror!void {
            _ = ctx;
            _ = context;
        }
    }.testFunc;

    var context_data: usize = 42;
    try registry.register("context.cmd", "Context Command", "Command with context", test_fn, &context_data);

    const cmd = registry.commands.get("context.cmd");
    try std.testing.expect(cmd != null);
    try std.testing.expect(cmd.?.context != null);
}

test "fuzzyScore exact substring match" {
    try std.testing.expect(CommandRegistry.containsSubstringForTest("Hello World", "Hello"));
    try std.testing.expect(CommandRegistry.containsSubstringForTest("Hello World", "World"));
    try std.testing.expect(CommandRegistry.containsSubstringForTest("Hello World", "lo Wo"));
    try std.testing.expect(CommandRegistry.containsSubstringForTest("file_manager.zig", "file"));
    try std.testing.expect(!CommandRegistry.containsSubstringForTest("Hello", "World"));
    try std.testing.expect(!CommandRegistry.containsSubstringForTest("Hi", "Hello"));
}

test "fuzzyScore case insensitive substring" {
    try std.testing.expect(CommandRegistry.containsSubstringForTest("Hello World", "hello"));
    try std.testing.expect(CommandRegistry.containsSubstringForTest("FILE_MANAGER", "file"));
    try std.testing.expect(CommandRegistry.containsSubstringForTest("CamelCase", "camel"));
}

test "fuzzyScore subsequence matching" {
    const score1 = CommandRegistry.fuzzyScoreForTest("hw", "Hello World");
    try std.testing.expect(score1 > 0);

    const score2 = CommandRegistry.fuzzyScoreForTest("abc", "aabbcc");
    try std.testing.expect(score2 > 0);

    const score3 = CommandRegistry.fuzzyScoreForTest("xyz", "abc");
    try std.testing.expectEqual(@as(i64, 0), score3);
}

test "fuzzyScore word boundary bonus" {
    const score1 = CommandRegistry.fuzzyScoreForTest("file", "file_manager.zig");
    const score2 = CommandRegistry.fuzzyScoreForTest("file", "my_file_manager");

    try std.testing.expect(score1 > 100);
    try std.testing.expect(score2 > 100);
}

test "fuzzyScore consecutive matches bonus" {
    const score1 = CommandRegistry.fuzzyScoreForTest("abc", "abc");
    const score2 = CommandRegistry.fuzzyScoreForTest("abc", "a_b_c");

    try std.testing.expect(score1 > score2);
}

test "matchesInitials word initials" {
    try std.testing.expect(CommandRegistry.matchesInitialsForTest("gtl", "Go To Line"));
    try std.testing.expect(CommandRegistry.matchesInitialsForTest("fm", "File Manager"));
    try std.testing.expect(CommandRegistry.matchesInitialsForTest("cr", "Command Registry"));
    try std.testing.expect(CommandRegistry.matchesInitialsForTest("hw", "Hello World"));

    try std.testing.expect(!CommandRegistry.matchesInitialsForTest("xyz", "Hello World"));
    try std.testing.expect(!CommandRegistry.matchesInitialsForTest("abc", "x"));
}

test "CommandRegistry search empty query" {
    var registry = CommandRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const test_fn = struct {
        fn testFunc(ctx: *anyopaque, context: ?*const anyopaque) anyerror!void {
            _ = ctx;
            _ = context;
        }
    }.testFunc;

    try registry.register("cmd1", "First Command", "Description 1", test_fn, null);
    try registry.register("cmd2", "Second Command", "Description 2", test_fn, null);

    var results = std.ArrayListUnmanaged(Command).empty;
    defer results.deinit(std.testing.allocator);

    try registry.search("", &results, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), results.items.len);
}

test "CommandRegistry search exact title match" {
    var registry = CommandRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const test_fn = struct {
        fn testFunc(ctx: *anyopaque, context: ?*const anyopaque) anyerror!void {
            _ = ctx;
            _ = context;
        }
    }.testFunc;

    try registry.register("file.save", "File: Save", "Save the current file", test_fn, null);
    try registry.register("file.open", "File: Open", "Open a file", test_fn, null);

    var results = std.ArrayListUnmanaged(Command).empty;
    defer results.deinit(std.testing.allocator);

    try registry.search("File: Save", &results, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqualStrings("file.save", results.items[0].id);
}

test "CommandRegistry search partial match" {
    var registry = CommandRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const test_fn = struct {
        fn testFunc(ctx: *anyopaque, context: ?*const anyopaque) anyerror!void {
            _ = ctx;
            _ = context;
        }
    }.testFunc;

    try registry.register("file.save", "File: Save", "Save the current file", test_fn, null);
    try registry.register("edit.copy", "Edit: Copy", "Copy selection", test_fn, null);

    var results = std.ArrayListUnmanaged(Command).empty;
    defer results.deinit(std.testing.allocator);

    try registry.search("save", &results, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqualStrings("file.save", results.items[0].id);
}

test "CommandRegistry search multiple matches" {
    var registry = CommandRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const test_fn = struct {
        fn testFunc(ctx: *anyopaque, context: ?*const anyopaque) anyerror!void {
            _ = ctx;
            _ = context;
        }
    }.testFunc;

    try registry.register("file.save", "File: Save", "Save the current file", test_fn, null);
    try registry.register("file.open", "File: Open", "Open a file", test_fn, null);
    try registry.register("edit.save", "Edit: Save As", "Save with new name", test_fn, null);

    var results = std.ArrayListUnmanaged(Command).empty;
    defer results.deinit(std.testing.allocator);

    try registry.search("file", &results, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), results.items.len);

    var found_save = false;
    var found_open = false;
    for (results.items) |cmd| {
        if (std.mem.eql(u8, cmd.id, "file.save")) found_save = true;
        if (std.mem.eql(u8, cmd.id, "file.open")) found_open = true;
    }
    try std.testing.expect(found_save);
    try std.testing.expect(found_open);
}

test "CommandRegistry search description match" {
    var registry = CommandRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const test_fn = struct {
        fn testFunc(ctx: *anyopaque, context: ?*const anyopaque) anyerror!void {
            _ = ctx;
            _ = context;
        }
    }.testFunc;

    try registry.register("cmd1", "Command 1", "This has special text", test_fn, null);
    try registry.register("cmd2", "Command 2", "Normal description", test_fn, null);

    var results = std.ArrayListUnmanaged(Command).empty;
    defer results.deinit(std.testing.allocator);

    try registry.search("special", &results, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqualStrings("cmd1", results.items[0].id);
}

test "CommandRegistry search ID match" {
    var registry = CommandRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const test_fn = struct {
        fn testFunc(ctx: *anyopaque, context: ?*const anyopaque) anyerror!void {
            _ = ctx;
            _ = context;
        }
    }.testFunc;

    try registry.register("very.specific.command", "Generic Title", "Generic desc", test_fn, null);

    var results = std.ArrayListUnmanaged(Command).empty;
    defer results.deinit(std.testing.allocator);

    try registry.search("specific", &results, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), results.items.len);
}

test "CommandRegistry search scoring priority" {
    var registry = CommandRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const test_fn = struct {
        fn testFunc(ctx: *anyopaque, context: ?*const anyopaque) anyerror!void {
            _ = ctx;
            _ = context;
        }
    }.testFunc;

    try registry.register("cmd1", "Save File", "Save the current file", test_fn, null);
    try registry.register("cmd2", "Open File", "Save operation for files", test_fn, null);

    var results = std.ArrayListUnmanaged(Command).empty;
    defer results.deinit(std.testing.allocator);

    try registry.search("save", &results, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), results.items.len);
    try std.testing.expectEqualStrings("cmd1", results.items[0].id);
    try std.testing.expectEqualStrings("cmd2", results.items[1].id);
}

test "CommandRegistry search initials matching" {
    var registry = CommandRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const test_fn = struct {
        fn testFunc(ctx: *anyopaque, context: ?*const anyopaque) anyerror!void {
            _ = ctx;
            _ = context;
        }
    }.testFunc;

    try registry.register("go.to.line", "Go To Line", "Jump to specific line", test_fn, null);
    try registry.register("find.replace", "Find and Replace", "Search and replace", test_fn, null);

    var results = std.ArrayListUnmanaged(Command).empty;
    defer results.deinit(std.testing.allocator);

    try registry.search("gtl", &results, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqualStrings("go.to.line", results.items[0].id);
}

test "CommandRegistry register duplicate ID" {
    var registry = CommandRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const test_fn = struct {
        fn testFunc(ctx: *anyopaque, context: ?*const anyopaque) anyerror!void {
            _ = ctx;
            _ = context;
        }
    }.testFunc;

    try registry.register("test.cmd", "Command 1", "First", test_fn, null);
    try registry.register("test.cmd", "Command 2", "Second", test_fn, null);

    try std.testing.expectEqual(@as(usize, 1), registry.commands.count());
    const cmd = registry.commands.get("test.cmd");
    try std.testing.expect(cmd != null);
    try std.testing.expectEqualStrings("Command 2", cmd.?.title);
}

test "CommandRegistry search with no matches" {
    var registry = CommandRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const test_fn = struct {
        fn testFunc(ctx: *anyopaque, context: ?*const anyopaque) anyerror!void {
            _ = ctx;
            _ = context;
        }
    }.testFunc;

    try registry.register("cmd1", "Test Command", "Description", test_fn, null);

    var results = std.ArrayListUnmanaged(Command).empty;
    defer results.deinit(std.testing.allocator);

    try registry.search("nonexistent", &results, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), results.items.len);
}

test "CommandRegistry search with special characters" {
    var registry = CommandRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const test_fn = struct {
        fn testFunc(ctx: *anyopaque, context: ?*const anyopaque) anyerror!void {
            _ = ctx;
            _ = context;
        }
    }.testFunc;

    try registry.register("cmd1", "Command: With: Colons", "Description:with:colons", test_fn, null);

    var results = std.ArrayListUnmanaged(Command).empty;
    defer results.deinit(std.testing.allocator);

    try registry.search("colons", &results, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), results.items.len);
}

test "fuzzyScore empty inputs" {
    try std.testing.expectEqual(@as(i64, 0), CommandRegistry.fuzzyScoreForTest("", "text"));
    try std.testing.expectEqual(@as(i64, 0), CommandRegistry.fuzzyScoreForTest("query", ""));
    try std.testing.expectEqual(@as(i64, 0), CommandRegistry.fuzzyScoreForTest("", ""));
}

test "fuzzyScore very long strings" {
    var long_text = std.ArrayList(u8).empty;
    defer long_text.deinit(std.testing.allocator);

    for (0..10000) |_| {
        try long_text.appendSlice(std.testing.allocator, "Some text content ");
    }

    const score = CommandRegistry.fuzzyScoreForTest("content", long_text.items);
    try std.testing.expect(score > 0);
}

test "CommandRegistry search with many commands" {
    var registry = CommandRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const test_fn = struct {
        fn testFunc(ctx: *anyopaque, context: ?*const anyopaque) anyerror!void {
            _ = ctx;
            _ = context;
        }
    }.testFunc;

    const commands = [_]struct { id: []const u8, title: []const u8 }{
        .{ .id = "cmd0", .title = "Command 0" },
        .{ .id = "cmd1", .title = "Command 1" },
        .{ .id = "cmd2", .title = "Command 2" },
        .{ .id = "cmd3", .title = "Command 3" },
        .{ .id = "cmd4", .title = "Command 4" },
        .{ .id = "cmd5", .title = "Command 5" },
        .{ .id = "cmd6", .title = "Command 6" },
        .{ .id = "cmd7", .title = "Command 7" },
        .{ .id = "cmd8", .title = "Command 8" },
        .{ .id = "cmd9", .title = "Command 9" },
    };

    for (commands) |cmd| {
        try registry.register(cmd.id, cmd.title, "Description", test_fn, null);
    }

    var results = std.ArrayListUnmanaged(Command).empty;
    defer results.deinit(std.testing.allocator);

    try registry.search("Command 5", &results, std.testing.allocator);

    try std.testing.expect(results.items.len > 0);
    try std.testing.expectEqualStrings("cmd5", results.items[0].id);
}

test "CommandRegistry search performance" {
    var registry = CommandRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const test_fn = struct {
        fn testFunc(ctx: *anyopaque, context: ?*const anyopaque) anyerror!void {
            _ = ctx;
            _ = context;
        }
    }.testFunc;

    const commands = [_]struct { id: []const u8, title: []const u8 }{
        .{ .id = "perf_cmd0", .title = "Performance Command 0" },
        .{ .id = "perf_cmd1", .title = "Performance Command 1" },
        .{ .id = "perf_cmd2", .title = "Performance Command 2" },
        .{ .id = "perf_cmd3", .title = "Performance Command 3" },
        .{ .id = "perf_cmd4", .title = "Performance Command 4" },
        .{ .id = "perf_cmd5", .title = "Performance Command 5" },
        .{ .id = "perf_cmd6", .title = "Performance Command 6" },
        .{ .id = "perf_cmd7", .title = "Performance Command 7" },
        .{ .id = "perf_cmd8", .title = "Performance Command 8" },
        .{ .id = "perf_cmd9", .title = "Performance Command 9" },
    };

    for (commands) |cmd| {
        try registry.register(cmd.id, cmd.title, "A description for this command", test_fn, null);
    }

    var results = std.ArrayListUnmanaged(Command).empty;
    defer results.deinit(std.testing.allocator);

    try test_utils.PerformanceTestUtils.expectPerformance(CommandRegistry.search, .{ &registry, "Performance", &results, std.testing.allocator }, 10_000_000);

    try std.testing.expect(results.items.len > 0);
}

test "fuzzyScore performance with long strings" {
    var long_text = std.ArrayList(u8).empty;
    defer long_text.deinit(std.testing.allocator);

    for (0..100000) |_| {
        try long_text.appendSlice(std.testing.allocator, "This is some text content that we search through ");
    }

    try test_utils.PerformanceTestUtils.expectPerformance(CommandRegistry.fuzzyScoreForTest, .{ "content", long_text.items }, 1_000_000);
}

fn testCommandRegistryMemory(allocator: std.mem.Allocator) !void {
    var registry = CommandRegistry.init(allocator);
    defer registry.deinit();

    const test_fn = struct {
        fn testFunc(ctx: *anyopaque, context: ?*const anyopaque) anyerror!void {
            _ = ctx;
            _ = context;
        }
    }.testFunc;

    try registry.register("cmd1", "Command 1", "Description 1", test_fn, null);
    try registry.register("cmd2", "Command 2", "Description 2", test_fn, null);

    var results = std.ArrayListUnmanaged(Command).empty;
    defer results.deinit(allocator);

    try registry.search("Command", &results, allocator);
    try std.testing.expect(results.items.len > 0);
}

test "CommandRegistry search with unicode" {
    var registry = CommandRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const test_fn = struct {
        fn testFunc(ctx: *anyopaque, context: ?*const anyopaque) anyerror!void {
            _ = ctx;
            _ = context;
        }
    }.testFunc;

    try registry.register("unicode.cmd", "Unicöde Command 🌍", "Description with émöji", test_fn, null);

    var results = std.ArrayListUnmanaged(Command).empty;
    defer results.deinit(std.testing.allocator);

    try registry.search("unicode", &results, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), results.items.len);
}

test "fuzzyScore with unicode characters" {
    const score1 = CommandRegistry.fuzzyScoreForTest("émöji", "Description with émöji");
    try std.testing.expect(score1 > 0);

    const score2 = CommandRegistry.fuzzyScoreForTest("🌍", "Unicöde Command 🌍");
    try std.testing.expect(score2 > 0);
}

test "Command execution callback simulation" {
    var registry = CommandRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var execution_count: usize = 0;
    const test_fn = struct {
        fn testFunc(ctx: *anyopaque, context: ?*const anyopaque) anyerror!void {
            _ = ctx;
            const counter = @as(*usize, @ptrCast(@alignCast(@constCast(context.?))));
            counter.* += 1;
        }
    }.testFunc;

    try registry.register("test.cmd", "Test Command", "Executes test", test_fn, &execution_count);

    const cmd = registry.commands.get("test.cmd");
    try std.testing.expect(cmd != null);

    try cmd.?.execute(@as(*anyopaque, @ptrCast(&registry)), cmd.?.context);

    try std.testing.expectEqual(@as(usize, 1), execution_count);
}
