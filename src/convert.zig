const std = @import("std");
const palette = @import("palette.zig");

pub const Hsl = struct { h: f64, s: f64, l: f64 };
pub const Oklch = struct { l: f64, c: f64, h: f64 };

pub fn toHex(c: palette.Color, buf: *[7]u8) []const u8 {
    _ = std.fmt.bufPrint(buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ c.r, c.g, c.b }) catch unreachable;
    return buf[0..];
}

pub fn toHsl(c: palette.Color) Hsl {
    const r = @as(f64, @floatFromInt(c.r)) / 255.0;
    const g = @as(f64, @floatFromInt(c.g)) / 255.0;
    const b = @as(f64, @floatFromInt(c.b)) / 255.0;
    const max = @max(@max(r, g), b);
    const min = @min(@min(r, g), b);
    const l = (max + min) / 2.0;
    if (max == min) return .{ .h = 0, .s = 0, .l = l };
    const d = max - min;
    const s = if (l > 0.5) d / (2.0 - max - min) else d / (max + min);
    var h: f64 = 0;
    if (max == r) {
        h = (g - b) / d + (if (g < b) @as(f64, 6) else 0);
    } else if (max == g) {
        h = (b - r) / d + 2;
    } else {
        h = (r - g) / d + 4;
    }
    return .{ .h = h * 60.0, .s = s, .l = l };
}

/// Linear sRGB → OKLab → OKLCh per Björn Ottosson's published constants.
pub fn toOklch(c: palette.Color) Oklch {
    const lr = srgbToLinear(c.r);
    const lg = srgbToLinear(c.g);
    const lb = srgbToLinear(c.b);

    const l_ = 0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb;
    const m_ = 0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb;
    const s_ = 0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb;

    const l_c = std.math.cbrt(l_);
    const m_c = std.math.cbrt(m_);
    const s_c = std.math.cbrt(s_);

    const ok_l = 0.2104542553 * l_c + 0.7936177850 * m_c - 0.0040720468 * s_c;
    const ok_a = 1.9779984951 * l_c - 2.4285922050 * m_c + 0.4505937099 * s_c;
    const ok_b = 0.0259040371 * l_c + 0.7827717662 * m_c - 0.8086757660 * s_c;

    const chroma = @sqrt(ok_a * ok_a + ok_b * ok_b);
    var hue = std.math.atan2(ok_b, ok_a) * 180.0 / std.math.pi;
    if (hue < 0) hue += 360.0;

    return .{ .l = ok_l, .c = chroma, .h = hue };
}

fn srgbToLinear(v: u8) f64 {
    const x = @as(f64, @floatFromInt(v)) / 255.0;
    return if (x <= 0.04045) x / 12.92 else std.math.pow(f64, (x + 0.055) / 1.055, 2.4);
}

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
