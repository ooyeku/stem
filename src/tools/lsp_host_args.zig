const std = @import("std");

pub const External = struct {
    lang: []const u8,
    argv: []const []const u8,
};

pub const Mode = union(enum) {
    embedded_zls,
    external: External,
};

pub fn parse(args: []const []const u8) !Mode {
    if (args.len < 2) return error.MissingMode;

    if (std.mem.eql(u8, args[1], "--embedded-zls")) {
        return .embedded_zls;
    }

    var lang: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--lang")) {
            i += 1;
            if (i >= args.len) return error.MissingLanguage;
            lang = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            const server_argv = args[i + 1 ..];
            if (server_argv.len == 0) return error.MissingServerCommand;
            return .{ .external = .{
                .lang = lang orelse "unknown",
                .argv = server_argv,
            } };
        }
        return error.UnknownArgument;
    }

    return error.MissingServerCommand;
}

test "parse embedded zls mode" {
    const mode = try parse(&.{ "stem-lsp-zig", "--embedded-zls" });
    try std.testing.expectEqual(Mode.embedded_zls, mode);
}

test "parse external mode with language and server argv" {
    const mode = try parse(&.{ "stem-lsp-host", "--lang", "python", "--", "node", "pyright.js", "--stdio" });
    switch (mode) {
        .external => |external| {
            try std.testing.expectEqualStrings("python", external.lang);
            try std.testing.expectEqual(@as(usize, 3), external.argv.len);
            try std.testing.expectEqualStrings("node", external.argv[0]);
            try std.testing.expectEqualStrings("pyright.js", external.argv[1]);
            try std.testing.expectEqualStrings("--stdio", external.argv[2]);
        },
        else => return error.ExpectedExternalMode,
    }
}

test "external mode requires command after separator" {
    try std.testing.expectError(error.MissingServerCommand, parse(&.{ "stem-lsp-host", "--lang", "python", "--" }));
}
