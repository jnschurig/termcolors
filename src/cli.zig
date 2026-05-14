const std = @import("std");

pub const Format = enum {
    json,
    env,
    flat,

    pub fn fromStr(s: []const u8) ?Format {
        return std.meta.stringToEnum(Format, s);
    }
};

pub const Notation = enum {
    hex,
    rgb,
    hsl,
    oklch,

    pub fn fromStr(s: []const u8) ?Notation {
        return std.meta.stringToEnum(Notation, s);
    }
};

pub const Slot = union(enum) {
    fg,
    bg,
    cursor,
    selection_bg,
    selection_fg,
    palette_index: u8,
};

pub const Options = struct {
    format: Format = .json,
    notation: Notation = .hex,
    /// Owned by the caller's allocator when non-null.
    only: ?[]Slot = null,
    include_aliases: bool = false,
    include_256: bool = false,
    timeout_ms: u32 = 200,
    no_multiplexer_wrap: bool = false,
    /// True if `--help` was requested. main() should print usage and exit 0.
    help: bool = false,

    pub fn deinit(self: *Options, allocator: std.mem.Allocator) void {
        if (self.only) |only| allocator.free(only);
        self.only = null;
    }
};

pub const ParseError = error{
    UnknownFlag,
    MissingValue,
    InvalidValue,
    OutOfMemory,
};

const TIMEOUT_MIN: u32 = 25;
const TIMEOUT_MAX: u32 = 5000;

/// `args` is the full argv slice (args[0] is the program name and is skipped).
pub fn parse(allocator: std.mem.Allocator, args: []const []const u8) ParseError!Options {
    var opts = Options{};
    errdefer opts.deinit(allocator);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            opts.help = true;
        } else if (std.mem.eql(u8, a, "--include-aliases")) {
            opts.include_aliases = true;
        } else if (std.mem.eql(u8, a, "--include-256")) {
            opts.include_256 = true;
        } else if (std.mem.eql(u8, a, "--no-multiplexer-wrap")) {
            opts.no_multiplexer_wrap = true;
        } else if (matchValue(a, "--format")) |raw| {
            const v = try valueOrNext(raw, args, &i);
            opts.format = Format.fromStr(v) orelse return ParseError.InvalidValue;
        } else if (matchValue(a, "--color")) |raw| {
            const v = try valueOrNext(raw, args, &i);
            opts.notation = Notation.fromStr(v) orelse return ParseError.InvalidValue;
        } else if (matchValue(a, "--timeout-ms")) |raw| {
            const v = try valueOrNext(raw, args, &i);
            const n = std.fmt.parseInt(u32, v, 10) catch return ParseError.InvalidValue;
            opts.timeout_ms = std.math.clamp(n, TIMEOUT_MIN, TIMEOUT_MAX);
        } else if (matchValue(a, "--only")) |raw| {
            const v = try valueOrNext(raw, args, &i);
            opts.only = try parseOnly(allocator, v);
        } else {
            return ParseError.UnknownFlag;
        }
    }
    return opts;
}

/// If `arg` is exactly `flag` returns null (value comes from next argv).
/// If `arg` is `flag=value` returns the value slice.
/// Otherwise returns no match (the caller's `if (matchValue)` fails to enter).
fn matchValue(arg: []const u8, flag: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, arg, flag)) return arg[0..0];
    if (arg.len > flag.len + 1 and std.mem.startsWith(u8, arg, flag) and arg[flag.len] == '=') {
        return arg[flag.len + 1 ..];
    }
    return null;
}

fn valueOrNext(inline_val: []const u8, args: []const []const u8, i: *usize) ParseError![]const u8 {
    if (inline_val.len > 0) return inline_val;
    if (i.* + 1 >= args.len) return ParseError.MissingValue;
    i.* += 1;
    return args[i.*];
}

fn parseOnly(allocator: std.mem.Allocator, csv: []const u8) ParseError![]Slot {
    var list: std.ArrayListUnmanaged(Slot) = .empty;
    errdefer list.deinit(allocator);

    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |raw| {
        const tok = std.mem.trim(u8, raw, " \t");
        if (tok.len == 0) continue;
        const slot: Slot = if (std.mem.eql(u8, tok, "fg"))
            .fg
        else if (std.mem.eql(u8, tok, "bg"))
            .bg
        else if (std.mem.eql(u8, tok, "cursor"))
            .cursor
        else if (std.mem.eql(u8, tok, "selection_bg"))
            .selection_bg
        else if (std.mem.eql(u8, tok, "selection_fg"))
            .selection_fg
        else slot: {
            const n = std.fmt.parseInt(u8, tok, 10) catch return ParseError.InvalidValue;
            break :slot .{ .palette_index = n };
        };
        try list.append(allocator, slot);
    }
    return list.toOwnedSlice(allocator);
}

test "defaults" {
    var opts = try parse(std.testing.allocator, &.{"termcolors"});
    defer opts.deinit(std.testing.allocator);
    try std.testing.expectEqual(Format.json, opts.format);
    try std.testing.expectEqual(Notation.hex, opts.notation);
    try std.testing.expectEqual(@as(u32, 200), opts.timeout_ms);
    try std.testing.expectEqual(false, opts.include_aliases);
}

test "format and notation" {
    var opts = try parse(std.testing.allocator, &.{ "x", "--format", "env", "--color=oklch" });
    defer opts.deinit(std.testing.allocator);
    try std.testing.expectEqual(Format.env, opts.format);
    try std.testing.expectEqual(Notation.oklch, opts.notation);
}

test "timeout clamps" {
    {
        var opts = try parse(std.testing.allocator, &.{ "x", "--timeout-ms", "1" });
        defer opts.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u32, 25), opts.timeout_ms);
    }
    {
        var opts = try parse(std.testing.allocator, &.{ "x", "--timeout-ms", "99999" });
        defer opts.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u32, 5000), opts.timeout_ms);
    }
}

test "only mixes names and indices" {
    var opts = try parse(std.testing.allocator, &.{ "x", "--only", "fg,bg,0,7,15" });
    defer opts.deinit(std.testing.allocator);
    const only = opts.only.?;
    try std.testing.expectEqual(@as(usize, 5), only.len);
    try std.testing.expectEqual(Slot.fg, only[0]);
    try std.testing.expectEqual(@as(u8, 0), only[2].palette_index);
    try std.testing.expectEqual(@as(u8, 15), only[4].palette_index);
}

test "unknown flag" {
    try std.testing.expectError(ParseError.UnknownFlag, parse(std.testing.allocator, &.{ "x", "--bogus" }));
}

test "missing value" {
    try std.testing.expectError(ParseError.MissingValue, parse(std.testing.allocator, &.{ "x", "--format" }));
}

test "invalid format" {
    try std.testing.expectError(ParseError.InvalidValue, parse(std.testing.allocator, &.{ "x", "--format", "yaml" }));
}
