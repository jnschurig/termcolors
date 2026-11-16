const std = @import("std");
const convert = @import("../convert.zig");

const toHex = convert.toHex;
const toOklch = convert.toOklch;

test "hex round trip" {
    var buf: [7]u8 = undefined;
    const s = toHex(.{ .r = 29, .g = 31, .b = 33 }, &buf);
    try std.testing.expectEqualStrings("#1d1f21", s);
}

test "oklch white" {
    const r = toOklch(.{ .r = 255, .g = 255, .b = 255 });
    try std.testing.expect(r.l > 0.99 and r.l <= 1.0);
    try std.testing.expect(r.c < 0.001);
}
