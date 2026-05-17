const std = @import("std");
const stem = @import("stem");
const vfs = stem.vfs;
const VirtualUri = vfs.VirtualUri;
const UriScheme = vfs.UriScheme;

const FuzzContext = struct {
    allocator: std.mem.Allocator,
};

fn fuzzUriParsing(_: FuzzContext, input: []const u8) anyerror!void {
    const result = VirtualUri.parse(input);

    if (result) |uri| {
        try std.testing.expect(uri.path.len <= input.len);

        _ = uri.scheme.toString();

        _ = uri.isReadOnly();
        _ = uri.isSaveable();
    }
}

fn fuzzSchemeVariations(ctx: FuzzContext, input: []const u8) anyerror!void {
    if (input.len < 3) return;

    const schemes = [_][]const u8{ "file://", "memory://", "git://", "://", "" };

    for (schemes) |scheme| {
        const uri_str = std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ scheme, input }) catch continue;
        defer ctx.allocator.free(uri_str);

        const result = VirtualUri.parse(uri_str);
        if (result) |uri| {
            try std.testing.expect(uri.path.len <= uri_str.len);
        }
    }
}

fn fuzzBoundaryInputs(_: FuzzContext, input: []const u8) anyerror!void {
    _ = VirtualUri.parse("");

    if (input.len >= 1) {
        _ = VirtualUri.parse(input[0..1]);
    }

    if (input.len > 10) {
        _ = VirtualUri.parse(input);
    }

    _ = VirtualUri.parse("/");

    _ = VirtualUri.parse("///");
    _ = VirtualUri.parse("://");
    _ = VirtualUri.parse("file:///");
}

fn fuzzSchemeFromString(_: FuzzContext, input: []const u8) anyerror!void {
    const result = UriScheme.fromString(input);

    if (result) |scheme| {
        const str = scheme.toString();
        try std.testing.expect(str.len > 0);
    }
}

fn fuzzUriFormat(ctx: FuzzContext, input: []const u8) anyerror!void {
    const result = VirtualUri.parse(input);

    if (result) |uri| {
        const formatted = uri.format(ctx.allocator) catch return;
        defer ctx.allocator.free(formatted);

        try std.testing.expect(formatted.len > 0);
    }
}

fn fuzzDisplayName(ctx: FuzzContext, input: []const u8) anyerror!void {
    const result = VirtualUri.parse(input);

    if (result) |uri| {
        const name = uri.displayName(ctx.allocator) catch return;
        defer ctx.allocator.free(name);

        try std.testing.expect(name.len > 0);
    }
}

test "fuzz: VirtualUri parsing" {
    const ctx = FuzzContext{ .allocator = std.testing.allocator };
    try std.testing.fuzz(ctx, fuzzUriParsing, .{});
}

test "fuzz: VirtualUri scheme variations" {
    const ctx = FuzzContext{ .allocator = std.testing.allocator };
    try std.testing.fuzz(ctx, fuzzSchemeVariations, .{});
}

test "fuzz: VirtualUri boundary inputs" {
    const ctx = FuzzContext{ .allocator = std.testing.allocator };
    try std.testing.fuzz(ctx, fuzzBoundaryInputs, .{});
}

test "fuzz: UriScheme fromString" {
    const ctx = FuzzContext{ .allocator = std.testing.allocator };
    try std.testing.fuzz(ctx, fuzzSchemeFromString, .{});
}

test "fuzz: VirtualUri format" {
    const ctx = FuzzContext{ .allocator = std.testing.allocator };
    try std.testing.fuzz(ctx, fuzzUriFormat, .{});
}

test "fuzz: VirtualUri displayName" {
    const ctx = FuzzContext{ .allocator = std.testing.allocator };
    try std.testing.fuzz(ctx, fuzzDisplayName, .{});
}
