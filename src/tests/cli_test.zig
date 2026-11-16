const std = @import("std");
const cli = @import("../cli.zig");

const Format = cli.Format;
const Notation = cli.Notation;
const parse = cli.parse;
const ParseError = cli.ParseError;
const parseSource = cli.parseSource;
const Slot = cli.Slot;
const Source = cli.Source;

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

test "source accepts rex by name but not by path" {
    var opts = try parse(std.testing.allocator, &.{ "x", "--source", "rex" });
    defer opts.deinit(std.testing.allocator);
    switch (opts.source) {
        .emulator => |e| {
            try std.testing.expectEqualStrings("rex", e.name);
            try std.testing.expect(e.binary == null);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectError(
        ParseError.InvalidValue,
        parse(std.testing.allocator, &.{ "x", "--source", "/usr/local/bin/rex" }),
    );
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
