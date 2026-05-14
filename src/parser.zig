const std = @import("std");
const palette = @import("palette.zig");

pub const ReplyKind = union(enum) {
    palette_index: u8,
    foreground,
    background,
    cursor,
    selection_bg,
    selection_fg,
};

pub const Reply = struct {
    kind: ReplyKind,
    color: palette.Color,
};

pub const ParseError = error{
    Malformed,
    UnknownOsc,
    TruncatedChannel,
};

const ESC: u8 = 0x1b;
const BEL: u8 = 0x07;

/// Parses a single OSC reply. Accepts these terminator forms:
///   ESC ] <type> ; rgb:RRRR/GGGG/BBBB BEL
///   ESC ] <type> ; rgb:RRRR/GGGG/BBBB ESC \
/// `<type>` is one of `10`, `11`, `12`, `17`, `19`, or `4 ; n`.
/// `rgb:` may also be `rgba:` (alpha channel is parsed and discarded).
/// Channel hex digit counts of 1..=4 are accepted; values are scaled to u8.
pub fn parseReply(bytes: []const u8) ParseError!Reply {
    var s = bytes;
    s = stripTerminator(s) orelse return ParseError.Malformed;
    s = stripPrefix(s, &.{ ESC, ']' }) orelse return ParseError.Malformed;

    // Split into `<type>;rgb:...`. <type> may itself contain a `;` (the `4;n` form),
    // so we have to be smart: scan for the `rgb` / `rgba` marker.
    const marker = findMarker(s) orelse return ParseError.Malformed;
    if (marker.start == 0 or s[marker.start - 1] != ';') return ParseError.Malformed;
    const type_part = s[0 .. marker.start - 1];
    const channels = s[marker.end..];

    const kind = try parseKind(type_part);
    const color = try parseChannels(channels);
    return .{ .kind = kind, .color = color };
}

fn stripTerminator(s: []const u8) ?[]const u8 {
    if (s.len >= 1 and s[s.len - 1] == BEL) return s[0 .. s.len - 1];
    if (s.len >= 2 and s[s.len - 2] == ESC and s[s.len - 1] == '\\') return s[0 .. s.len - 2];
    return null;
}

fn stripPrefix(s: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, s, prefix)) return null;
    return s[prefix.len..];
}

const Marker = struct { start: usize, end: usize };

fn findMarker(s: []const u8) ?Marker {
    if (std.mem.indexOf(u8, s, "rgba:")) |i| return .{ .start = i, .end = i + 5 };
    if (std.mem.indexOf(u8, s, "rgb:")) |i| return .{ .start = i, .end = i + 4 };
    return null;
}

fn parseKind(type_part: []const u8) ParseError!ReplyKind {
    if (std.mem.eql(u8, type_part, "10")) return .foreground;
    if (std.mem.eql(u8, type_part, "11")) return .background;
    if (std.mem.eql(u8, type_part, "12")) return .cursor;
    if (std.mem.eql(u8, type_part, "17")) return .selection_bg;
    if (std.mem.eql(u8, type_part, "19")) return .selection_fg;
    if (std.mem.startsWith(u8, type_part, "4;")) {
        const n = std.fmt.parseInt(u8, type_part[2..], 10) catch return ParseError.Malformed;
        return .{ .palette_index = n };
    }
    return ParseError.UnknownOsc;
}

fn parseChannels(s: []const u8) ParseError!palette.Color {
    var it = std.mem.splitScalar(u8, s, '/');
    const r_s = it.next() orelse return ParseError.Malformed;
    const g_s = it.next() orelse return ParseError.Malformed;
    const b_s = it.next() orelse return ParseError.Malformed;
    // Discard alpha if present (rgba: form).
    _ = it.next();

    return .{
        .r = try parseChannel(r_s),
        .g = try parseChannel(g_s),
        .b = try parseChannel(b_s),
    };
}

fn parseChannel(s: []const u8) ParseError!u8 {
    if (s.len == 0 or s.len > 4) return ParseError.TruncatedChannel;
    var v: u32 = 0;
    for (s) |c| {
        const d = std.fmt.charToDigit(c, 16) catch return ParseError.Malformed;
        v = (v << 4) | d;
    }
    // Scale by replicating the n-digit value into 8 bits. For 2-digit (common), v is already u8.
    // xparsecolor semantics: scale full-range to 0..255 by taking the most significant 8 bits.
    return switch (s.len) {
        1 => @intCast((v << 4) | v),
        2 => @intCast(v),
        3 => @intCast(v >> 4),
        4 => @intCast(v >> 8),
        else => unreachable,
    };
}

// ---- tests ----

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
