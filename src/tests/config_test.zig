const std = @import("std");
const config = @import("../config.zig");

const ParseError = config.ParseError;
const parseText = config.parseText;

test "empty file yields default config" {
    var cfg = try parseText(std.testing.allocator, "");
    defer cfg.deinit(std.testing.allocator);
    try std.testing.expect(cfg.termcolors_source == null);
}

test "comments and blank lines ignored" {
    const text =
        \\# this is a comment
        \\
        \\   # indented comment
        \\
    ;
    var cfg = try parseText(std.testing.allocator, text);
    defer cfg.deinit(std.testing.allocator);
    try std.testing.expect(cfg.termcolors_source == null);
}

test "termcolors_source with known name" {
    var cfg = try parseText(std.testing.allocator, "termcolors_source = ghostty\n");
    defer cfg.deinit(std.testing.allocator);
    switch (cfg.termcolors_source.?) {
        .emulator => |e| {
            try std.testing.expectEqualStrings("ghostty", e.name);
            try std.testing.expect(e.binary == null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "termcolors_source = rex" {
    var cfg = try parseText(std.testing.allocator, "termcolors_source = rex\n");
    defer cfg.deinit(std.testing.allocator);
    switch (cfg.termcolors_source.?) {
        .emulator => |e| try std.testing.expectEqualStrings("rex", e.name),
        else => return error.TestUnexpectedResult,
    }
}

test "termcolors_source with absolute path" {
    var cfg = try parseText(std.testing.allocator, "termcolors_source=/opt/homebrew/bin/ghostty\n");
    defer cfg.deinit(std.testing.allocator);
    switch (cfg.termcolors_source.?) {
        .emulator => |e| {
            try std.testing.expectEqualStrings("ghostty", e.name);
            try std.testing.expectEqualStrings("/opt/homebrew/bin/ghostty", e.binary.?);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "trailing inline comment stripped" {
    var cfg = try parseText(std.testing.allocator, "termcolors_source = ghostty # use ghostty\n");
    defer cfg.deinit(std.testing.allocator);
    try std.testing.expect(cfg.termcolors_source != null);
}

test "unknown key errors" {
    try std.testing.expectError(
        ParseError.UnknownKey,
        parseText(std.testing.allocator, "fallback = ghostty\n"),
    );
}

test "unknown source name errors" {
    try std.testing.expectError(
        ParseError.InvalidValue,
        parseText(std.testing.allocator, "termcolors_source = kitty\n"),
    );
}

test "mode keyword in config errors" {
    try std.testing.expectError(
        ParseError.ModeKeywordWhereEmulatorExpected,
        parseText(std.testing.allocator, "termcolors_source = osc\n"),
    );
}

test "missing value errors" {
    try std.testing.expectError(
        ParseError.MissingValue,
        parseText(std.testing.allocator, "termcolors_source =\n"),
    );
}
