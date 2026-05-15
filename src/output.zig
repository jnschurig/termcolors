const std = @import("std");
const cli = @import("cli.zig");
const palette = @import("palette.zig");
const convert = @import("convert.zig");

pub const SCHEMA_VERSION: u32 = 1;

pub const Multiplexer = enum {
    none,
    tmux,
    screen,

    fn jsonName(self: Multiplexer) ?[]const u8 {
        return switch (self) {
            .none => null,
            .tmux => "tmux",
            .screen => "screen",
        };
    }
};

pub const Context = struct {
    palette: palette.Palette,
    /// Slot names that the terminal failed to respond to within the timeout.
    /// Encoded into `meta.unsupported` verbatim.
    unsupported: []const []const u8 = &.{},
    /// RFC 3339 timestamp string; output.zig does not generate it, callers do.
    queried_at: []const u8,
    multiplexer: Multiplexer = .none,
};

const ALIAS_NAMES = [_][]const u8{
    "black",        "red",            "green",        "yellow",
    "blue",         "magenta",        "cyan",         "white",
    "bright_black", "bright_red",     "bright_green", "bright_yellow",
    "bright_blue",  "bright_magenta", "bright_cyan",  "bright_white",
};

const SPECIAL_NAMES = [_][]const u8{
    "foreground",           "background",           "cursor",
    "selection_background", "selection_foreground",
};

pub fn write(
    writer: anytype,
    ctx: Context,
    opts: cli.Options,
) !void {
    switch (opts.format) {
        .json => try writeJson(writer, ctx, opts),
        .env => try writeEnv(writer, ctx, opts),
        .flat => try writeFlat(writer, ctx, opts),
    }
}

// ----- color rendering -----

/// Writes a single color in the chosen notation. Caller is responsible for any
/// surrounding quoting (JSON strings) or trailing newline (env/flat).
pub fn writeColor(writer: anytype, color: palette.Color, notation: cli.Notation) !void {
    switch (notation) {
        .hex => try writer.print("#{x:0>2}{x:0>2}{x:0>2}", .{ color.r, color.g, color.b }),
        .rgb => try writer.print("rgb({d} {d} {d})", .{ color.r, color.g, color.b }),
        .hsl => {
            const v = convert.toHsl(color);
            try writer.print("hsl({d:.0} {d:.0}% {d:.0}%)", .{ v.h, v.s * 100, v.l * 100 });
        },
        .oklch => {
            const v = convert.toOklch(color);
            try writer.print("oklch({d:.1}% {d:.3} {d:.0})", .{ v.l * 100, v.c, v.h });
        },
    }
}

// ----- JSON -----

fn writeJson(writer: anytype, ctx: Context, opts: cli.Options) !void {
    try writer.writeAll("{\n  \"palette\": [");
    for (ctx.palette.indexed, 0..) |maybe, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("\n    ");
        if (maybe) |c| {
            try writer.writeByte('"');
            try writeColor(writer, c, opts.notation);
            try writer.writeByte('"');
        } else {
            try writer.writeAll("null");
        }
    }
    try writer.writeAll("\n  ],\n  \"special\": {");

    const specials = [_]struct { name: []const u8, val: ?palette.Color, slot: cli.Slot }{
        .{ .name = "foreground", .val = ctx.palette.foreground, .slot = .fg },
        .{ .name = "background", .val = ctx.palette.background, .slot = .bg },
        .{ .name = "cursor", .val = ctx.palette.cursor, .slot = .cursor },
        .{ .name = "selection_background", .val = ctx.palette.selection_background, .slot = .selection_bg },
        .{ .name = "selection_foreground", .val = ctx.palette.selection_foreground, .slot = .selection_fg },
    };
    var first = true;
    for (specials) |s| {
        if (!slotRequested(opts.only, s.slot)) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try writer.print("\n    \"{s}\": ", .{s.name});
        if (s.val) |c| {
            try writer.writeByte('"');
            try writeColor(writer, c, opts.notation);
            try writer.writeByte('"');
        } else {
            try writer.writeAll("null");
        }
    }
    try writer.writeAll("\n  },\n");

    if (opts.include_aliases) {
        try writer.writeAll("  \"aliases\": {\n");
        for (ALIAS_NAMES, 0..) |name, i| {
            try writer.print("    \"{s}\": {d}{s}\n", .{
                name,
                i,
                if (i == ALIAS_NAMES.len - 1) "" else ",",
            });
        }
        try writer.writeAll("  },\n");
    }

    try writer.writeAll("  \"meta\": {\n");
    try writer.print("    \"schema_version\": {d},\n", .{SCHEMA_VERSION});
    try writer.print("    \"notation\": \"{s}\",\n", .{@tagName(opts.notation)});
    try writer.print("    \"queried_at\": \"{s}\",\n", .{ctx.queried_at});
    try writer.writeAll("    \"unsupported\": [");
    for (ctx.unsupported, 0..) |u, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print("\"{s}\"", .{u});
    }
    try writer.writeAll("],\n");
    if (ctx.multiplexer.jsonName()) |m| {
        try writer.print("    \"multiplexer\": \"{s}\"\n", .{m});
    } else {
        try writer.writeAll("    \"multiplexer\": null\n");
    }
    try writer.writeAll("  }\n}\n");
}

// ----- env -----

fn writeEnv(writer: anytype, ctx: Context, opts: cli.Options) !void {
    for (ctx.palette.indexed, 0..) |maybe, i| {
        if (!slotRequested(opts.only, .{ .palette_index = @intCast(i) })) continue;
        try writer.print("ANSI_{d}=", .{i});
        if (maybe) |c| try writeColor(writer, c, opts.notation);
        try writer.writeByte('\n');
    }
    try writeEnvSpecial(writer, "FG", ctx.palette.foreground, .fg, opts);
    try writeEnvSpecial(writer, "BG", ctx.palette.background, .bg, opts);
    try writeEnvSpecial(writer, "CURSOR", ctx.palette.cursor, .cursor, opts);
    try writeEnvSpecial(writer, "SELECTION_BG", ctx.palette.selection_background, .selection_bg, opts);
    try writeEnvSpecial(writer, "SELECTION_FG", ctx.palette.selection_foreground, .selection_fg, opts);

    if (opts.include_aliases) {
        for (ALIAS_NAMES, 0..) |name, i| {
            if (i >= ctx.palette.indexed.len) break;
            const upper = std.ascii.allocUpperString(std.heap.page_allocator, name) catch continue;
            defer std.heap.page_allocator.free(upper);
            try writer.print("ANSI_{s}=", .{upper});
            if (ctx.palette.indexed[i]) |c| try writeColor(writer, c, opts.notation);
            try writer.writeByte('\n');
        }
    }
}

fn writeEnvSpecial(
    writer: anytype,
    suffix: []const u8,
    val: ?palette.Color,
    slot: cli.Slot,
    opts: cli.Options,
) !void {
    if (!slotRequested(opts.only, slot)) return;
    try writer.print("ANSI_{s}=", .{suffix});
    if (val) |c| try writeColor(writer, c, opts.notation);
    try writer.writeByte('\n');
}

// ----- flat -----

fn writeFlat(writer: anytype, ctx: Context, opts: cli.Options) !void {
    for (ctx.palette.indexed, 0..) |maybe, i| {
        if (!slotRequested(opts.only, .{ .palette_index = @intCast(i) })) {
            try writer.writeByte('\n');
            continue;
        }
        if (maybe) |c| try writeColor(writer, c, opts.notation);
        try writer.writeByte('\n');
    }
    const ordered = [_]struct { val: ?palette.Color, slot: cli.Slot }{
        .{ .val = ctx.palette.foreground, .slot = .fg },
        .{ .val = ctx.palette.background, .slot = .bg },
        .{ .val = ctx.palette.cursor, .slot = .cursor },
        .{ .val = ctx.palette.selection_background, .slot = .selection_bg },
        .{ .val = ctx.palette.selection_foreground, .slot = .selection_fg },
    };
    for (ordered) |s| {
        if (slotRequested(opts.only, s.slot)) {
            if (s.val) |c| try writeColor(writer, c, opts.notation);
        }
        try writer.writeByte('\n');
    }
    _ = SPECIAL_NAMES;
}

// ----- shared -----

fn slotRequested(only: ?[]cli.Slot, slot: cli.Slot) bool {
    const list = only orelse return true;
    for (list) |s| if (slotEql(s, slot)) return true;
    return false;
}

fn slotEql(a: cli.Slot, b: cli.Slot) bool {
    return switch (a) {
        .palette_index => |ai| switch (b) {
            .palette_index => |bi| ai == bi,
            else => false,
        },
        else => std.meta.activeTag(a) == std.meta.activeTag(b),
    };
}

// ===== tests =====

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
    // 16 indexed + 5 special + trailing empty after final newline = 22
    try std.testing.expectEqual(@as(usize, 22), count);
}

test "rgb notation" {
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeColor(&w, .{ .r = 29, .g = 31, .b = 33 }, .rgb);
    try std.testing.expectEqualStrings("rgb(29 31 33)", w.buffered());
}
