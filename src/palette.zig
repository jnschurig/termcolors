const std = @import("std");

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
};

pub const SpecialSlot = enum {
    foreground,
    background,
    cursor,
    selection_background,
    selection_foreground,
};

pub const Palette = struct {
    indexed: []?Color,
    foreground: ?Color = null,
    background: ?Color = null,
    cursor: ?Color = null,
    selection_background: ?Color = null,
    selection_foreground: ?Color = null,
};
