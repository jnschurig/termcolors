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
    /// Free-form advisory shown in meta.notice when set. Used to flag conditions
    /// like "no OSC replies at all" that aren't fatal but explain null output
    /// (e.g. running inside nvim :terminal, or a terminal that ignores OSC 4/10/11).
    notice: ?[]const u8 = null,
    /// Identifier of the source that produced the palette. Always present in
    /// output (the field defaults to "osc" so older call sites compile unchanged).
    /// Future sources extend this open string set; consumers should not strict-enum-check.
    source: []const u8 = "osc",
    /// Optional theme name reported by sources that expose one (e.g. ghostty).
    theme: ?[]const u8 = null,
};

const ALIAS_NAMES = [_][]const u8{
    "black",        "red",            "green",        "yellow",
    "blue",         "magenta",        "cyan",         "white",
    "bright_black", "bright_red",     "bright_green", "bright_yellow",
    "bright_blue",  "bright_magenta", "bright_cyan",  "bright_white",
};

const SPECIAL_NAMES = [_][]const u8{
    "foreground",  "background",           "cursor",
    "cursor_text", "selection_background", "selection_foreground",
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
        .{ .name = "cursor_text", .val = ctx.palette.cursor_text, .slot = .cursor_text },
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
    try writer.print("    \"source\": \"{s}\",\n", .{ctx.source});
    if (ctx.theme) |t| {
        // Theme names come from emulator config / theme files: escape them.
        try writer.writeAll("    \"theme\": ");
        try std.json.Stringify.encodeJsonString(t, .{}, writer);
        try writer.writeAll(",\n");
    } else {
        try writer.writeAll("    \"theme\": null,\n");
    }
    try writer.print("    \"notation\": \"{s}\",\n", .{@tagName(opts.notation)});
    try writer.print("    \"queried_at\": \"{s}\",\n", .{ctx.queried_at});
    try writer.writeAll("    \"unsupported\": [");
    for (ctx.unsupported, 0..) |u, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print("\"{s}\"", .{u});
    }
    try writer.writeAll("],\n");
    if (ctx.multiplexer.jsonName()) |m| {
        try writer.print("    \"multiplexer\": \"{s}\",\n", .{m});
    } else {
        try writer.writeAll("    \"multiplexer\": null,\n");
    }
    if (ctx.notice) |n| {
        try writer.print("    \"notice\": \"{s}\"\n", .{n});
    } else {
        try writer.writeAll("    \"notice\": null\n");
    }
    try writer.writeAll("  }\n}\n");
}

// ----- env -----

fn writeEnv(writer: anytype, ctx: Context, opts: cli.Options) !void {
    for (ctx.palette.indexed, 0..) |maybe, i| {
        if (!slotRequested(opts.only, .{ .palette_index = @intCast(i) })) continue;
        try writer.print("ANSI_{d}=", .{i});
        if (maybe) |c| try writeEnvColor(writer, c, opts.notation);
        try writer.writeByte('\n');
    }
    try writeEnvSpecial(writer, "FG", ctx.palette.foreground, .fg, opts);
    try writeEnvSpecial(writer, "BG", ctx.palette.background, .bg, opts);
    try writeEnvSpecial(writer, "CURSOR", ctx.palette.cursor, .cursor, opts);
    try writeEnvSpecial(writer, "CURSOR_TEXT", ctx.palette.cursor_text, .cursor_text, opts);
    try writeEnvSpecial(writer, "SELECTION_BG", ctx.palette.selection_background, .selection_bg, opts);
    try writeEnvSpecial(writer, "SELECTION_FG", ctx.palette.selection_foreground, .selection_fg, opts);

    if (opts.include_aliases) {
        for (ALIAS_NAMES, 0..) |name, i| {
            if (i >= ctx.palette.indexed.len) break;
            const upper = std.ascii.allocUpperString(std.heap.page_allocator, name) catch continue;
            defer std.heap.page_allocator.free(upper);
            try writer.print("ANSI_{s}=", .{upper});
            if (ctx.palette.indexed[i]) |c| try writeEnvColor(writer, c, opts.notation);
            try writer.writeByte('\n');
        }
    }

    try writer.print("META_SOURCE={s}\n", .{ctx.source});
    if (ctx.theme) |t| {
        try writer.writeAll("META_THEME=");
        try writeShellValue(writer, t);
        try writer.writeByte('\n');
    }
}

/// Bytes that never need quoting on the right-hand side of a shell assignment.
fn isShellSafe(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "_#.,:/@%+-", c) != null;
}

/// Writes `value` so that `eval`/`source` assigns it verbatim: unchanged when
/// every byte is shell-safe (hex colors, simple names), single-quoted
/// otherwise. The env format is documented as shell-sourceable, and theme
/// names are not under our control.
fn writeShellValue(writer: anytype, value: []const u8) !void {
    for (value) |c| {
        if (!isShellSafe(c)) break;
    } else return writer.writeAll(value);

    try writer.writeByte('\'');
    for (value) |c| {
        if (c == '\'') try writer.writeAll("'\\''") else try writer.writeByte(c);
    }
    try writer.writeByte('\'');
}

fn writeEnvColor(writer: anytype, color: palette.Color, notation: cli.Notation) !void {
    var buf: [48]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeColor(&w, color, notation);
    try writeShellValue(writer, w.buffered());
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
    if (val) |c| try writeEnvColor(writer, c, opts.notation);
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
        .{ .val = ctx.palette.cursor_text, .slot = .cursor_text },
        .{ .val = ctx.palette.selection_background, .slot = .selection_bg },
        .{ .val = ctx.palette.selection_foreground, .slot = .selection_fg },
    };
    for (ordered) |s| {
        if (slotRequested(opts.only, s.slot)) {
            if (s.val) |c| try writeColor(writer, c, opts.notation);
        }
        try writer.writeByte('\n');
    }
    try writer.print("meta.source={s}\n", .{ctx.source});
    if (ctx.theme) |t| {
        // Flat is line-oriented: a control byte (newline) in the theme name
        // must not be able to start a new line.
        try writer.writeAll("meta.theme=");
        for (t) |c| try writer.writeByte(if (std.ascii.isControl(c)) ' ' else c);
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
