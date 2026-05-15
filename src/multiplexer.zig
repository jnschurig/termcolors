const std = @import("std");

pub const Kind = enum { none, tmux, screen };

pub fn detect() Kind {
    if (std.c.getenv("TMUX") != null) return .tmux;
    if (std.c.getenv("STY") != null) return .screen;
    return .none;
}

/// Wrap a raw OSC query in the active multiplexer's passthrough envelope.
/// Caller frees the returned slice.
pub fn wrap(allocator: std.mem.Allocator, kind: Kind, raw: []const u8) ![]u8 {
    return switch (kind) {
        .none => allocator.dupe(u8, raw),
        .tmux => wrapTmux(allocator, raw),
        .screen => wrapScreen(allocator, raw),
    };
}

fn wrapTmux(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    // tmux passthrough: ESC Ptmux; ESC <raw with each ESC doubled> ESC \
    _ = allocator;
    _ = raw;
    return error.Unimplemented;
}

fn wrapScreen(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    _ = allocator;
    _ = raw;
    return error.Unimplemented;
}
