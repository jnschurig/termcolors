const std = @import("std");
const output = @import("../output.zig");
const palette = @import("../palette.zig");

const Context = output.Context;
const write = output.write;
const writeColor = output.writeColor;

fn makePalette(allocator: std.mem.Allocator) !palette.Palette {
    const idx = try allocator.alloc(?palette.Color, 16);
    for (idx, 0..) |*slot, i| {
        slot.* = .{ .r = @intCast(i * 16), .g = @intCast(i * 8), .b = @intCast(255 - i * 16) };
    }
    idx[3] = null;
    return .{
        .indexed = idx,
        .foreground = .{ .r = 0xc5, .g = 0xc8, .b = 0xc6 },
        .background = .{ .r = 0x1d, .g = 0x1f, .b = 0x21 },
        .cursor = null,
        .selection_background = .{ .r = 0x37, .g = 0x3b, .b = 0x41 },
        .selection_foreground = .{ .r = 0xc5, .g = 0xc8, .b = 0xc6 },
    };
}

test "json output contains schema and known values" {
    const allocator = std.testing.allocator;
    const pal = try makePalette(allocator);
    defer allocator.free(pal.indexed);
    const ctx = Context{
        .palette = pal,
        .queried_at = "2026-05-14T12:34:56Z",
        .unsupported = &.{"cursor"},
    };
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try write(&aw.writer, ctx, .{});
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"schema_version\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"notation\": \"hex\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"#c5c8c6\"") != null); // foreground
    try std.testing.expect(std.mem.indexOf(u8, out, "\"unsupported\": [\"cursor\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"multiplexer\": null") != null);
}

test "json includes aliases when requested" {
    const allocator = std.testing.allocator;
    const pal = try makePalette(allocator);
    defer allocator.free(pal.indexed);
    const ctx = Context{ .palette = pal, .queried_at = "t" };
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try write(&aw.writer, ctx, .{ .include_aliases = true });
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\"aliases\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\"bright_white\": 15") != null);
}

test "env output formats indexed and special" {
    const allocator = std.testing.allocator;
    const pal = try makePalette(allocator);
    defer allocator.free(pal.indexed);
    const ctx = Context{ .palette = pal, .queried_at = "t" };
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try write(&aw.writer, ctx, .{ .format = .env });
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "ANSI_0=#0000ff") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "ANSI_3=\n") != null); // null slot empty
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "ANSI_FG=#c5c8c6") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "ANSI_CURSOR=\n") != null);
}

test "flat output preserves position with blank lines" {
    const allocator = std.testing.allocator;
    const pal = try makePalette(allocator);
    defer allocator.free(pal.indexed);
    const ctx = Context{ .palette = pal, .queried_at = "t" };
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try write(&aw.writer, ctx, .{ .format = .flat });
    var lines = std.mem.splitScalar(u8, aw.written(), '\n');
    var count: usize = 0;
    while (lines.next()) |_| count += 1;
    // 16 indexed + 6 special + 1 meta.source (theme omitted when null) + trailing empty = 24
    try std.testing.expectEqual(@as(usize, 24), count);
}

test "json output emits meta.source and null meta.theme by default" {
    const allocator = std.testing.allocator;
    const pal = try makePalette(allocator);
    defer allocator.free(pal.indexed);
    const ctx = Context{ .palette = pal, .queried_at = "t" };
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try write(&aw.writer, ctx, .{});
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"source\": \"osc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"theme\": null") != null);
}

test "json output emits non-null theme when set" {
    const allocator = std.testing.allocator;
    const pal = try makePalette(allocator);
    defer allocator.free(pal.indexed);
    const ctx = Context{
        .palette = pal,
        .queried_at = "t",
        .source = "ghostty",
        .theme = "GruvboxDarkHard",
    };
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try write(&aw.writer, ctx, .{});
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"source\": \"ghostty\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"theme\": \"GruvboxDarkHard\"") != null);
}

test "env output emits META_SOURCE and skips META_THEME when null" {
    const allocator = std.testing.allocator;
    const pal = try makePalette(allocator);
    defer allocator.free(pal.indexed);
    const ctx = Context{ .palette = pal, .queried_at = "t" };
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try write(&aw.writer, ctx, .{ .format = .env });
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "META_SOURCE=osc\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "META_THEME=") == null);
}

test "env output emits META_THEME when set" {
    const allocator = std.testing.allocator;
    const pal = try makePalette(allocator);
    defer allocator.free(pal.indexed);
    const ctx = Context{
        .palette = pal,
        .queried_at = "t",
        .source = "ghostty",
        .theme = "Dracula",
    };
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try write(&aw.writer, ctx, .{ .format = .env });
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "META_SOURCE=ghostty\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "META_THEME=Dracula\n") != null);
}

test "env output quotes shell-unsafe theme names" {
    const allocator = std.testing.allocator;
    const pal = try makePalette(allocator);
    defer allocator.free(pal.indexed);
    const cases = [_]struct { theme: []const u8, want: []const u8 }{
        .{ .theme = "Merino Dark", .want = "META_THEME='Merino Dark'\n" },
        .{ .theme = "x; touch /tmp/pwned", .want = "META_THEME='x; touch /tmp/pwned'\n" },
        .{ .theme = "$(id)`id`", .want = "META_THEME='$(id)`id`'\n" },
        .{ .theme = "it's", .want = "META_THEME='it'\\''s'\n" },
        .{ .theme = "light:A,dark:B", .want = "META_THEME=light:A,dark:B\n" },
    };
    for (cases) |case| {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        try write(&aw.writer, .{ .palette = pal, .queried_at = "t", .theme = case.theme }, .{ .format = .env });
        try std.testing.expect(std.mem.endsWith(u8, aw.written(), case.want));
    }
}

test "env output quotes functional color notations, leaves hex bare" {
    const allocator = std.testing.allocator;
    const pal = try makePalette(allocator);
    defer allocator.free(pal.indexed);
    const ctx = Context{ .palette = pal, .queried_at = "t" };
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try write(&aw.writer, ctx, .{ .format = .env, .notation = .rgb, .include_aliases = true });
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "ANSI_0='rgb(0 0 255)'\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ANSI_FG='rgb(197 200 198)'\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ANSI_BLACK='rgb(0 0 255)'\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ANSI_3=\n") != null);
}

test "json output escapes theme names" {
    const allocator = std.testing.allocator;
    const pal = try makePalette(allocator);
    defer allocator.free(pal.indexed);
    const theme = "a\",\"injected\":\"yes\\\n";
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try write(&aw.writer, .{ .palette = pal, .queried_at = "t", .theme = theme }, .{});

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, aw.written(), .{});
    defer parsed.deinit();
    const meta = parsed.value.object.get("meta").?.object;
    try std.testing.expectEqualStrings(theme, meta.get("theme").?.string);
    try std.testing.expect(meta.get("injected") == null);
}

test "flat output keeps a theme name on one line" {
    const allocator = std.testing.allocator;
    const pal = try makePalette(allocator);
    defer allocator.free(pal.indexed);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try write(&aw.writer, .{ .palette = pal, .queried_at = "t", .theme = "a\nmeta.source=evil" }, .{ .format = .flat });
    try std.testing.expect(std.mem.endsWith(u8, aw.written(), "meta.source=osc\nmeta.theme=a meta.source=evil\n"));
}

test "rgb notation" {
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeColor(&w, .{ .r = 29, .g = 31, .b = 33 }, .rgb);
    try std.testing.expectEqualStrings("rgb(29 31 33)", w.buffered());
}
