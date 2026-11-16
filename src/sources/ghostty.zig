//! Ghostty source: invokes `ghostty +show-config` and parses the resulting
//! `key = value` lines into a Palette. No TTY required.

const std = @import("std");
const palette_mod = @import("../palette.zig");
const cli = @import("../cli.zig");

pub const AcquireError = error{
    BinaryNotFound,
    SubprocessFailed,
    MalformedOutput,
    OutOfMemory,
};

pub const Result = struct {
    palette: palette_mod.Palette,
    /// Theme name, or null when ghostty reports it as empty.
    theme: ?[]u8,
    /// Allocator ownership: caller frees both via `deinit`.
    indexed_owner: []?palette_mod.Color,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.indexed_owner);
        if (self.theme) |t| allocator.free(t);
        self.* = undefined;
    }
};

const STDOUT_MAX_BYTES = 4 * 1024 * 1024;
const STDERR_MAX_BYTES = 64 * 1024;
const TIMEOUT_SECONDS = 10;

/// Captured subprocess diagnostic when ghostty exits non-zero.
pub var last_stderr_first_line: [256]u8 = undefined;
pub var last_stderr_first_line_len: usize = 0;

/// Invoke the ghostty binary and parse its `+show-config` output.
///
/// `binary_override` is the absolute path to use (when the user configured one
/// via `--source <abs-path>` or `<source>_binary` in config). When null, falls
/// back to `ghostty` on `$PATH`.
pub fn acquire(
    gpa: std.mem.Allocator,
    io: std.Io,
    opts: cli.Options,
    binary_override: ?[]const u8,
) AcquireError!Result {
    // Use `+show-config` with no flags: this emits the user's resolved
    // configuration (theme name + the colors that actually apply). Passing
    // `--default=true` would suppress the user's overrides — including
    // `theme`, `cursor-color`, and the resolved selection colors — which is
    // not what callers want.
    const argv = [_][]const u8{
        binary_override orelse "ghostty",
        "+show-config",
    };

    // Bounded: a hung or runaway binary must not hang us or exhaust memory.
    const run_result = std.process.run(gpa, io, .{
        .argv = &argv,
        .stdout_limit = .limited(STDOUT_MAX_BYTES),
        .stderr_limit = .limited(STDERR_MAX_BYTES),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(TIMEOUT_SECONDS), .clock = .awake } },
    }) catch |err| switch (err) {
        error.FileNotFound => return AcquireError.BinaryNotFound,
        error.OutOfMemory => return AcquireError.OutOfMemory,
        else => return AcquireError.SubprocessFailed,
    };
    defer gpa.free(run_result.stdout);
    defer gpa.free(run_result.stderr);

    switch (run_result.term) {
        .exited => |code| if (code != 0) {
            captureStderrFirstLine(run_result.stderr);
            return AcquireError.SubprocessFailed;
        },
        else => {
            captureStderrFirstLine(run_result.stderr);
            return AcquireError.SubprocessFailed;
        },
    }

    return try parseShowConfig(gpa, run_result.stdout, opts.include_256);
}

fn captureStderrFirstLine(stderr: []const u8) void {
    const nl = std.mem.indexOfScalar(u8, stderr, '\n') orelse stderr.len;
    const line = stderr[0..nl];
    const copy_len = @min(line.len, last_stderr_first_line.len);
    // The line is echoed to the user's terminal: neutralize control bytes.
    for (last_stderr_first_line[0..copy_len], line[0..copy_len]) |*dst, c| {
        dst.* = if (std.ascii.isControl(c)) '?' else c;
    }
    last_stderr_first_line_len = copy_len;
}

/// Parse the textual `ghostty +show-config` output.
///
/// Recognized keys:
///   * `palette = N=#RRGGBB` — N in [0, 255]; populated into indices 0..15
///     (or 0..255 when `include_256` is true).
///   * `foreground`, `background`, `cursor-color`, `selection-background`,
///     `selection-foreground` — `#RRGGBB` form; empty value means "not set".
///   * `theme` — bare string; empty means null in the Result.
///
/// Anything else is ignored. The parser is permissive — it does not require
/// every key to be present.
pub fn parseShowConfig(
    gpa: std.mem.Allocator,
    text: []const u8,
    include_256: bool,
) AcquireError!Result {
    const palette_len: usize = if (include_256) 256 else 16;
    const indexed = try gpa.alloc(?palette_mod.Color, palette_len);
    errdefer gpa.free(indexed);
    @memset(indexed, null);
    var pal = palette_mod.Palette{ .indexed = indexed };
    var theme: ?[]u8 = null;
    errdefer if (theme) |t| gpa.free(t);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");

        if (std.mem.eql(u8, key, "palette")) {
            // value form: "N=#RRGGBB"
            if (value.len == 0) continue;
            const inner_eq = std.mem.indexOfScalar(u8, value, '=') orelse return AcquireError.MalformedOutput;
            const idx_str = std.mem.trim(u8, value[0..inner_eq], " \t");
            const hex = std.mem.trim(u8, value[inner_eq + 1 ..], " \t");
            const idx = std.fmt.parseInt(usize, idx_str, 10) catch return AcquireError.MalformedOutput;
            if (idx >= palette_len) continue;
            indexed[idx] = try parseHexColor(hex);
        } else if (std.mem.eql(u8, key, "foreground")) {
            if (value.len > 0) pal.foreground = try parseHexColor(value);
        } else if (std.mem.eql(u8, key, "background")) {
            if (value.len > 0) pal.background = try parseHexColor(value);
        } else if (std.mem.eql(u8, key, "cursor-color")) {
            if (value.len > 0) pal.cursor = try parseHexColor(value);
        } else if (std.mem.eql(u8, key, "cursor-text")) {
            if (value.len > 0) pal.cursor_text = try parseHexColor(value);
        } else if (std.mem.eql(u8, key, "selection-background")) {
            if (value.len > 0) pal.selection_background = try parseHexColor(value);
        } else if (std.mem.eql(u8, key, "selection-foreground")) {
            if (value.len > 0) pal.selection_foreground = try parseHexColor(value);
        } else if (std.mem.eql(u8, key, "theme")) {
            if (value.len > 0) {
                if (theme) |old| gpa.free(old);
                theme = null;
                theme = try gpa.dupe(u8, value);
            }
        }
    }

    return Result{
        .palette = pal,
        .theme = theme,
        .indexed_owner = indexed,
    };
}

fn parseHexColor(s: []const u8) AcquireError!palette_mod.Color {
    const body = if (s.len > 0 and s[0] == '#') s[1..] else s;
    if (body.len != 6) return AcquireError.MalformedOutput;
    const r = std.fmt.parseInt(u8, body[0..2], 16) catch return AcquireError.MalformedOutput;
    const g = std.fmt.parseInt(u8, body[2..4], 16) catch return AcquireError.MalformedOutput;
    const b = std.fmt.parseInt(u8, body[4..6], 16) catch return AcquireError.MalformedOutput;
    return .{ .r = r, .g = g, .b = b };
}

// ===== tests =====

const fixture = @embedFile("fixtures/ghostty-show-config.txt");

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
        last_stderr_first_line[0..last_stderr_first_line_len],
    );
}
