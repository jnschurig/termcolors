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
    cursor_text,
    selection_background,
    selection_foreground,
};

pub const Palette = struct {
    indexed: []?Color,
    foreground: ?Color = null,
    background: ?Color = null,
    cursor: ?Color = null,
    /// Color of text that overlaps the cursor. Populated by emulator sources
    /// that expose it (e.g. ghostty `cursor-text`); OSC has no widely-supported
    /// query for this slot, so it stays null in the OSC source.
    cursor_text: ?Color = null,
    selection_background: ?Color = null,
    selection_foreground: ?Color = null,
};
