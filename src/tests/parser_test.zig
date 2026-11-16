const std = @import("std");
const parser = @import("../parser.zig");
const palette = @import("../palette.zig");

const BEL: u8 = 0x07;
const ParseError = parser.ParseError;
const parseReply = parser.parseReply;
const ReplyKind = parser.ReplyKind;

test "foreground 4-digit channels with BEL" {
    const bytes = "\x1b]10;rgb:c5c5/c8c8/c6c6\x07";
    const r = try parseReply(bytes);
    try std.testing.expectEqual(ReplyKind.foreground, r.kind);
    try std.testing.expectEqual(@as(u8, 0xc5), r.color.r);
    try std.testing.expectEqual(@as(u8, 0xc8), r.color.g);
    try std.testing.expectEqual(@as(u8, 0xc6), r.color.b);
}

test "background 2-digit channels with ST" {
    const bytes = "\x1b]11;rgb:1d/1f/21\x1b\\";
    const r = try parseReply(bytes);
    try std.testing.expectEqual(ReplyKind.background, r.kind);
    try std.testing.expectEqual(@as(u8, 0x1d), r.color.r);
}

test "palette index 4" {
    const bytes = "\x1b]4;4;rgb:8181/a2a2/bebe\x07";
    const r = try parseReply(bytes);
    try std.testing.expectEqual(@as(u8, 4), r.kind.palette_index);
    try std.testing.expectEqual(@as(u8, 0x81), r.color.r);
}

test "rgba: form discards alpha" {
    const bytes = "\x1b]11;rgba:1d1d/1f1f/2121/ffff\x07";
    const r = try parseReply(bytes);
    try std.testing.expectEqual(@as(u8, 0x1d), r.color.r);
    try std.testing.expectEqual(@as(u8, 0x21), r.color.b);
}

test "1-digit channels" {
    const bytes = "\x1b]10;rgb:f/8/0\x07";
    const r = try parseReply(bytes);
    try std.testing.expectEqual(@as(u8, 0xff), r.color.r);
    try std.testing.expectEqual(@as(u8, 0x88), r.color.g);
    try std.testing.expectEqual(@as(u8, 0x00), r.color.b);
}

test "malformed: no terminator" {
    try std.testing.expectError(ParseError.Malformed, parseReply("\x1b]10;rgb:1d/1f/21"));
}

test "malformed: not OSC" {
    try std.testing.expectError(ParseError.Malformed, parseReply("garbage\x07"));
}

test "unknown osc type" {
    try std.testing.expectError(ParseError.UnknownOsc, parseReply("\x1b]99;rgb:00/00/00\x07"));
}
