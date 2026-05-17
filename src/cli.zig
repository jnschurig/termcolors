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
    cursor_text,
    selection_bg,
    selection_fg,
    palette_index: u8,
};

/// Names of compiled-in emulator sources. Single source of truth for both
/// `--source` parsing and config-file parsing.
pub const KNOWN_SOURCES = [_][]const u8{"ghostty"};

/// Resolved value for `--source` / `$TERMCOLORS_TERMINAL` / config `termcolors_source`.
pub const Source = union(enum) {
    auto,
    osc,
    emulator: Emulator,

    pub const Emulator = struct {
        /// One of `KNOWN_SOURCES`.
        name: []const u8,
        /// Absolute path explicitly provided by the user; null means look up
        /// `name` on `$PATH`. When non-null, the slice is owned by the caller's
        /// allocator and freed in `deinit`.
        binary: ?[]u8 = null,
    };

    pub fn deinit(self: *Source, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .emulator => |*e| if (e.binary) |b| allocator.free(b),
            else => {},
        }
        self.* = .auto;
    }
};

pub const Options = struct {
    format: Format = .json,
    notation: Notation = .hex,
    /// Owned by the caller's allocator when non-null.
    only: ?[]Slot = null,
    include_aliases: bool = false,
    include_256: bool = false,
    timeout_ms: u32 = 500,
    no_multiplexer_wrap: bool = false,
    /// True if `--help` was requested. main() should print usage and exit 0.
    help: bool = false,
    /// Resolved `--source` value. Default `.auto`.
    source: Source = .auto,
    /// Fallback emulator parsed from `$TERMCOLORS_TERMINAL` for use by the
    /// `auto` algorithm. Only populated when `source == .auto`. The dispatcher
    /// in main consults this before the config-file value.
    env_fallback: ?Source = null,
    /// Minimum filled palette slots (out of 16) for an OSC result to count as
    /// "sufficient" in `auto` mode. Range [1, 16].
    osc_min_palette: u8 = 8,

    pub fn deinit(self: *Options, allocator: std.mem.Allocator) void {
        if (self.only) |only| allocator.free(only);
        self.only = null;
        self.source.deinit(allocator);
        if (self.env_fallback) |*ef| ef.deinit(allocator);
        self.env_fallback = null;
    }
};

pub const ParseError = error{
    UnknownFlag,
    MissingValue,
    InvalidValue,
    /// Used when a setting that must name an emulator was given a mode keyword
    /// (`auto` / `osc`) instead. Caller emits a friendly diagnostic.
    ModeKeywordWhereEmulatorExpected,
    OutOfMemory,
};

const TIMEOUT_MIN: u32 = 25;
const TIMEOUT_MAX: u32 = 5000;
const OSC_MIN_PALETTE_LOW: u8 = 1;
const OSC_MIN_PALETTE_HIGH: u8 = 16;

/// Parse the textual value of `--source` / `$TERMCOLORS_TERMINAL` / config key.
/// Allowed forms:
///   * `auto`, `osc` — mode keywords (returned as `.auto` / `.osc`).
///   * `<name>` — name of a compiled-in emulator (must be in `KNOWN_SOURCES`).
///   * `/abs/path/to/<name>` — absolute path whose basename matches a known source.
///
/// `allow_modes = false` rejects `auto`/`osc` with `ModeKeywordWhereEmulatorExpected`
/// (used for env-var and config-file inputs which only accept emulators).
pub fn parseSource(
    allocator: std.mem.Allocator,
    value: []const u8,
    allow_modes: bool,
) ParseError!Source {
    if (value.len == 0) return ParseError.InvalidValue;
    if (std.mem.eql(u8, value, "auto")) {
        return if (allow_modes) .auto else ParseError.ModeKeywordWhereEmulatorExpected;
    }
    if (std.mem.eql(u8, value, "osc")) {
        return if (allow_modes) .osc else ParseError.ModeKeywordWhereEmulatorExpected;
    }

    // Path form: must be absolute, basename must be a known source.
    if (value[0] == '/') {
        const base = std.fs.path.basename(value);
        if (!isKnownSourceName(base)) return ParseError.InvalidValue;
        const owned = try allocator.dupe(u8, value);
        return .{ .emulator = .{ .name = canonicalSourceName(base), .binary = owned } };
    }

    // Bare name form.
    if (!isKnownSourceName(value)) return ParseError.InvalidValue;
    return .{ .emulator = .{ .name = canonicalSourceName(value), .binary = null } };
}

fn isKnownSourceName(s: []const u8) bool {
    for (KNOWN_SOURCES) |n| if (std.mem.eql(u8, s, n)) return true;
    return false;
}

/// Return the canonical `KNOWN_SOURCES` slice for `s`. Caller has already
/// verified membership via `isKnownSourceName`. Letting both `parseSource`
/// paths point at the same backing storage means `Source.Emulator.name`
/// doesn't need to be allocator-owned.
fn canonicalSourceName(s: []const u8) []const u8 {
    for (KNOWN_SOURCES) |n| if (std.mem.eql(u8, s, n)) return n;
    unreachable;
}

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
        } else if (matchValue(a, "--source")) |raw| {
            const v = try valueOrNext(raw, args, &i);
            opts.source.deinit(allocator);
            opts.source = try parseSource(allocator, v, true);
        } else if (matchValue(a, "--osc-min-palette")) |raw| {
            const v = try valueOrNext(raw, args, &i);
            const n = std.fmt.parseInt(u8, v, 10) catch return ParseError.InvalidValue;
            if (n < OSC_MIN_PALETTE_LOW or n > OSC_MIN_PALETTE_HIGH) return ParseError.InvalidValue;
            opts.osc_min_palette = n;
        } else {
            return ParseError.UnknownFlag;
        }
    }
    return opts;
}

/// Resolve `$TERMCOLORS_TERMINAL` into `Options.env_fallback`. Called by main
/// after `parse`. Only consulted when `opts.source == .auto`; explicit flag
/// wins. Empty / unset → no-op.
pub fn applyEnvFallback(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    opts: *Options,
) ParseError!void {
    if (opts.source != .auto) return;
    const raw = env_map.get("TERMCOLORS_TERMINAL") orelse return;
    if (raw.len == 0) return;
    var src = try parseSource(allocator, raw, false);
    errdefer src.deinit(allocator);
    opts.env_fallback = src;
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
        else if (std.mem.eql(u8, tok, "cursor_text"))
            .cursor_text
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
    try std.testing.expectEqual(@as(u32, 500), opts.timeout_ms);
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

test "source defaults to auto" {
    var opts = try parse(std.testing.allocator, &.{"x"});
    defer opts.deinit(std.testing.allocator);
    try std.testing.expectEqual(Source.auto, opts.source);
}

test "source accepts osc and auto keywords" {
    {
        var opts = try parse(std.testing.allocator, &.{ "x", "--source", "osc" });
        defer opts.deinit(std.testing.allocator);
        try std.testing.expectEqual(Source.osc, opts.source);
    }
    {
        var opts = try parse(std.testing.allocator, &.{ "x", "--source", "auto" });
        defer opts.deinit(std.testing.allocator);
        try std.testing.expectEqual(Source.auto, opts.source);
    }
}

test "source accepts known emulator name" {
    var opts = try parse(std.testing.allocator, &.{ "x", "--source", "ghostty" });
    defer opts.deinit(std.testing.allocator);
    switch (opts.source) {
        .emulator => |e| {
            try std.testing.expectEqualStrings("ghostty", e.name);
            try std.testing.expect(e.binary == null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "source accepts absolute path whose basename matches a known source" {
    var opts = try parse(std.testing.allocator, &.{ "x", "--source", "/opt/homebrew/bin/ghostty" });
    defer opts.deinit(std.testing.allocator);
    switch (opts.source) {
        .emulator => |e| {
            try std.testing.expectEqualStrings("ghostty", e.name);
            try std.testing.expectEqualStrings("/opt/homebrew/bin/ghostty", e.binary.?);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "source rejects unknown name" {
    try std.testing.expectError(
        ParseError.InvalidValue,
        parse(std.testing.allocator, &.{ "x", "--source", "kitty" }),
    );
}

test "source rejects absolute path with unknown basename" {
    try std.testing.expectError(
        ParseError.InvalidValue,
        parse(std.testing.allocator, &.{ "x", "--source", "/usr/bin/zsh" }),
    );
}

test "parseSource rejects mode keywords when allow_modes=false" {
    try std.testing.expectError(
        ParseError.ModeKeywordWhereEmulatorExpected,
        parseSource(std.testing.allocator, "auto", false),
    );
    try std.testing.expectError(
        ParseError.ModeKeywordWhereEmulatorExpected,
        parseSource(std.testing.allocator, "osc", false),
    );
}

test "osc-min-palette accepts range and rejects out-of-bounds" {
    {
        var opts = try parse(std.testing.allocator, &.{ "x", "--osc-min-palette", "12" });
        defer opts.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u8, 12), opts.osc_min_palette);
    }
    try std.testing.expectError(
        ParseError.InvalidValue,
        parse(std.testing.allocator, &.{ "x", "--osc-min-palette", "0" }),
    );
    try std.testing.expectError(
        ParseError.InvalidValue,
        parse(std.testing.allocator, &.{ "x", "--osc-min-palette", "17" }),
    );
}
