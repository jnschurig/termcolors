const std = @import("std");
const cli = @import("cli.zig");

pub const Config = struct {
    /// Fallback emulator for `--source auto`. Lifetime: owned by the allocator
    /// passed to `parseText` / `load`; freed by `deinit`.
    termcolors_source: ?cli.Source = null,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        if (self.termcolors_source) |*s| s.deinit(allocator);
        self.termcolors_source = null;
    }
};

pub const ParseError = error{
    UnknownKey,
    MissingValue,
    InvalidValue,
    ModeKeywordWhereEmulatorExpected,
    OutOfMemory,
};

/// Parse the textual contents of a config file.
///
/// Format: blank lines, `#`-comments to EOL, `key = value` pairs (whitespace
/// optional around `=`). Values are bare strings without quoting.
///
/// Recognized keys (this cycle):
///   * `termcolors_source` — `cli.parseSource(value, allow_modes=false)`.
pub fn parseText(allocator: std.mem.Allocator, text: []const u8) ParseError!Config {
    var cfg = Config{};
    errdefer cfg.deinit(allocator);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = stripComment(raw_line);
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse return ParseError.MissingValue;
        const key = std.mem.trim(u8, trimmed[0..eq], " \t");
        const value = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
        if (key.len == 0) return ParseError.MissingValue;
        if (value.len == 0) return ParseError.MissingValue;

        if (std.mem.eql(u8, key, "termcolors_source")) {
            var src = cli.parseSource(allocator, value, false) catch |err| switch (err) {
                cli.ParseError.ModeKeywordWhereEmulatorExpected => return ParseError.ModeKeywordWhereEmulatorExpected,
                cli.ParseError.InvalidValue => return ParseError.InvalidValue,
                cli.ParseError.OutOfMemory => return ParseError.OutOfMemory,
                else => return ParseError.InvalidValue,
            };
            errdefer src.deinit(allocator);
            if (cfg.termcolors_source) |*old| old.deinit(allocator);
            cfg.termcolors_source = src;
        } else {
            return ParseError.UnknownKey;
        }
    }

    return cfg;
}

/// Strip `#` comments (handling `\#` escapes is not implemented this cycle —
/// requirements explicitly dropped the escape rule).
fn stripComment(line: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, line, '#')) |i| return line[0..i];
    return line;
}

/// Locate the config file. Returns an allocator-owned absolute path or null if
/// no candidate exists. Resolution order:
///   1. `$XDG_CONFIG_HOME/termcolors/config` (when XDG is set).
///   2. `~/.config/termcolors/config`.
pub fn resolvePath(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
) std.mem.Allocator.Error!?[]u8 {
    if (env_map.get("XDG_CONFIG_HOME")) |xdg| {
        if (xdg.len > 0) {
            const candidate = try std.fs.path.join(allocator, &.{ xdg, "termcolors", "config" });
            if (fileExists(io, candidate)) return candidate;
            allocator.free(candidate);
        }
    }
    if (env_map.get("HOME")) |home| {
        if (home.len > 0) {
            const candidate = try std.fs.path.join(allocator, &.{ home, ".config", "termcolors", "config" });
            if (fileExists(io, candidate)) return candidate;
            allocator.free(candidate);
        }
    }
    return null;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Load the config file (if present). Returns the default `Config{}` when no
/// file is found.
pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
) !Config {
    const path = (try resolvePath(allocator, io, env_map)) orelse return Config{};
    defer allocator.free(path);

    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024));
    defer allocator.free(text);

    return parseText(allocator, text);
}

// ===== tests =====

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
