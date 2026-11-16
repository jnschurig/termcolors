const std = @import("std");
const ghostty = @import("../../sources/ghostty.zig");

const AcquireError = ghostty.AcquireError;
const captureStderrFirstLine = ghostty.captureStderrFirstLine;
const parseShowConfig = ghostty.parseShowConfig;

const fixture = @embedFile("../fixtures/ghostty-show-config.txt");

test "parses fixture: 16 palette entries populated" {
    var result = try parseShowConfig(std.testing.allocator, fixture, false);
    defer result.deinit(std.testing.allocator);
    var populated: usize = 0;
    for (result.palette.indexed) |c| {
        if (c != null) populated += 1;
    }
    try std.testing.expectEqual(@as(usize, 16), result.palette.indexed.len);
    try std.testing.expectEqual(@as(usize, 16), populated);
}

test "parses fixture: foreground, background, and special colors present" {
    var result = try parseShowConfig(std.testing.allocator, fixture, false);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.palette.foreground != null);
    try std.testing.expect(result.palette.background != null);
    try std.testing.expect(result.palette.cursor != null);
    try std.testing.expect(result.palette.cursor_text != null);
    try std.testing.expect(result.palette.selection_background != null);
    try std.testing.expect(result.palette.selection_foreground != null);
}

test "parses fixture: theme name captured" {
    var result = try parseShowConfig(std.testing.allocator, fixture, false);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Dracula", result.theme.?);
}

test "theme with non-empty value is captured" {
    const text =
        \\theme = GruvboxDarkHard
        \\foreground = #ebdbb2
        \\background = #1d2021
        \\palette = 0=#1d2021
    ;
    var result = try parseShowConfig(std.testing.allocator, text, false);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("GruvboxDarkHard", result.theme.?);
}

test "missing cursor-color leaves cursor null" {
    const text =
        \\foreground = #ffffff
        \\background = #000000
    ;
    var result = try parseShowConfig(std.testing.allocator, text, false);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.palette.cursor == null);
}

test "malformed palette line errors" {
    const text = "palette = 0\n";
    try std.testing.expectError(
        AcquireError.MalformedOutput,
        parseShowConfig(std.testing.allocator, text, false),
    );
}

test "garbage lines ignored" {
    const text =
        \\something-else = value
        \\# a comment line
        \\
        \\palette = 0=#112233
    ;
    var result = try parseShowConfig(std.testing.allocator, text, false);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0x11), result.palette.indexed[0].?.r);
}

test "hex without leading # is accepted" {
    const text = "foreground = aabbcc\n";
    var result = try parseShowConfig(std.testing.allocator, text, false);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0xaa), result.palette.foreground.?.r);
}

test "repeated theme lines: last wins, no leak" {
    const text = "theme = First\ntheme = Second\n";
    var result = try parseShowConfig(std.testing.allocator, text, false);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Second", result.theme.?);
}

test "captured stderr line has control bytes neutralized" {
    captureStderrFirstLine("bad \x1b]0;title\x07 thing\nsecond line");
    try std.testing.expectEqualStrings(
        "bad ?]0;title? thing",
        ghostty.last_stderr_first_line[0..ghostty.last_stderr_first_line_len],
    );
}
