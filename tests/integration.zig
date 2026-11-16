//! Integration tests: spawn the real `termcolors` binary under a pseudo-tty
//! and play the role of a terminal emulator by parsing its OSC color queries
//! and writing fixture replies back. Exercises the full pipeline end-to-end.
//!
//! Why this exists: the OSC I/O layer (terminal raw-mode lifecycle, batched
//! writes, deadline-bounded reads, kitty-style late-reply drain) cannot be
//! covered by pure-module unit tests. Real terminal emulators aren't available
//! on CI runners. A PTY-backed fake responder gives us the next best thing:
//! the binary writes real escape sequences, we feed it canned replies, and we
//! observe its stdout and exit code.
//!
//! Coverage: 4-digit `rgb:` channels, BEL vs ST terminators, missing replies
//! (unsupported slots), all-replies-missing (notice + exit code), interleaved
//! query/reply ordering. Real-emulator quirks (Kitty/iTerm2/Ghostty specifics)
//! are out of scope and stay in the manual release smoke test.

const std = @import("std");
const posix = std.posix;
const build_options = @import("build_options");

const ESC: u8 = 0x1b;
const BEL: u8 = 0x07;

// forkpty is in libutil on Linux, libc on macOS. build.zig links libutil for us.
extern "c" fn forkpty(
    amaster: *c_int,
    name: ?[*]u8,
    termp: ?*const anyopaque,
    winp: ?*const anyopaque,
) c_int;

/// Hex triple in 8-bit-per-channel form. The harness emits 4-digit `rgb:`
/// replies (`xxxx/yyyy/zzzz`) which is the most common real-terminal form;
/// individual tests can override the terminator (BEL vs ST).
pub const RGB = struct { r: u8, g: u8, b: u8 };

pub const Fixture = struct {
    /// indexed[i] = null means "no reply" (terminal does not support that slot).
    indexed: []const ?RGB,
    foreground: ?RGB = null,
    background: ?RGB = null,
    cursor: ?RGB = null,
    selection_bg: ?RGB = null,
    selection_fg: ?RGB = null,
    /// When true, use `ESC \` instead of `BEL` to terminate replies.
    use_st_terminator: bool = false,
};

pub const RunResult = struct {
    exit_code: u8,
    /// All non-OSC bytes the child wrote to stdout/stderr (PTY-mixed).
    output: []u8,

    pub fn deinit(self: *RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
    }
};

/// Spawn the binary under a PTY, respond to its OSC queries from `fixture`,
/// collect stdout, and wait for exit. `extra_env` is appended to a minimal
/// PATH-only environment; pass an empty slice for the default clean env.
pub fn runWithFakeTerminal(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    extra_env: []const []const u8,
    fixture: Fixture,
) !RunResult {
    // Build argv: [exe_path, ...args, null]
    var argv_buf: std.ArrayList(?[*:0]const u8) = .empty;
    defer {
        for (argv_buf.items) |p| if (p) |np| allocator.free(std.mem.span(np));
        argv_buf.deinit(allocator);
    }
    try argv_buf.append(allocator, try allocator.dupeZ(u8, build_options.exe_path));
    for (args) |a| try argv_buf.append(allocator, try allocator.dupeZ(u8, a));
    try argv_buf.append(allocator, null);

    // Build envp: minimal PATH + caller-provided.
    var envp_buf: std.ArrayList(?[*:0]const u8) = .empty;
    defer {
        for (envp_buf.items) |p| if (p) |np| allocator.free(std.mem.span(np));
        envp_buf.deinit(allocator);
    }
    try envp_buf.append(allocator, try allocator.dupeZ(u8, "PATH=/usr/bin:/bin"));
    for (extra_env) |kv| try envp_buf.append(allocator, try allocator.dupeZ(u8, kv));
    try envp_buf.append(allocator, null);

    var master_fd: c_int = -1;
    const pid = forkpty(&master_fd, null, null, null);
    if (pid < 0) return error.ForkPtyFailed;
    if (pid == 0) {
        // Child. Exec the binary with our argv/envp.
        const exe_z: [*:0]const u8 = argv_buf.items[0].?;
        _ = std.c.execve(exe_z, @ptrCast(argv_buf.items.ptr), @ptrCast(envp_buf.items.ptr));
        // execve only returns on failure.
        std.c.exit(127);
    }

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(allocator);

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(master_fd, &buf, buf.len);
        if (n <= 0) break; // child closed slave / EIO on Linux
        try pending.appendSlice(allocator, buf[0..@intCast(n)]);
        try processPending(allocator, master_fd, &pending, &output, fixture);
    }

    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    _ = std.c.close(master_fd);

    const exit_code: u8 = if ((status & 0x7f) == 0)
        @intCast((status >> 8) & 0xff)
    else
        255;

    return .{
        .exit_code = exit_code,
        .output = try output.toOwnedSlice(allocator),
    };
}

/// Walk `pending`, splitting it into OSC queries (which we reply to) and
/// stdout bytes (which we accumulate into `output`). Leaves a trailing partial
/// OSC in `pending` for the next read.
fn processPending(
    allocator: std.mem.Allocator,
    master_fd: c_int,
    pending: *std.ArrayList(u8),
    output: *std.ArrayList(u8),
    fixture: Fixture,
) !void {
    var i: usize = 0;
    while (i < pending.items.len) {
        if (pending.items[i] == ESC and i + 1 < pending.items.len and pending.items[i + 1] == ']') {
            // Scan for terminator.
            var j = i + 2;
            var end: ?usize = null;
            while (j < pending.items.len) : (j += 1) {
                if (pending.items[j] == BEL) {
                    end = j;
                    break;
                }
                if (pending.items[j] == ESC and j + 1 < pending.items.len and pending.items[j + 1] == '\\') {
                    end = j + 1;
                    break;
                }
            }
            if (end) |e| {
                const query = pending.items[i .. e + 1];
                if (try buildReply(allocator, query, fixture)) |reply| {
                    defer allocator.free(reply);
                    var remaining: []const u8 = reply;
                    while (remaining.len > 0) {
                        const w = std.c.write(master_fd, remaining.ptr, remaining.len);
                        if (w <= 0) break;
                        remaining = remaining[@intCast(w)..];
                    }
                }
                i = e + 1;
                continue;
            } else {
                // Partial OSC — keep from `i` onward for next read.
                break;
            }
        }
        try output.append(allocator, pending.items[i]);
        i += 1;
    }
    // Drop consumed prefix.
    const rest = pending.items.len - i;
    if (i > 0) {
        std.mem.copyForwards(u8, pending.items[0..rest], pending.items[i..]);
        pending.shrinkRetainingCapacity(rest);
    }
}

/// Returns an owned reply slice, or null if the fixture says "no reply for
/// this query" (terminal doesn't support that slot).
fn buildReply(allocator: std.mem.Allocator, query: []const u8, fixture: Fixture) !?[]u8 {
    // query is `\x1b] <Ps> ; <Pt> <terminator>`. We only handle `<Pt> == "?"`.
    if (query.len < 5) return null;
    const body_end: usize = if (query[query.len - 1] == BEL) query.len - 1 else query.len - 2;
    const body = query[2..body_end]; // strip ESC ] and terminator
    // Body forms we handle:
    //   "10;?"  "11;?"  "12;?"  "17;?"  "19;?"  "4;N;?"
    if (std.mem.eql(u8, body, "10;?")) return try formatReply(allocator, "10", fixture.foreground, fixture.use_st_terminator);
    if (std.mem.eql(u8, body, "11;?")) return try formatReply(allocator, "11", fixture.background, fixture.use_st_terminator);
    if (std.mem.eql(u8, body, "12;?")) return try formatReply(allocator, "12", fixture.cursor, fixture.use_st_terminator);
    if (std.mem.eql(u8, body, "17;?")) return try formatReply(allocator, "17", fixture.selection_bg, fixture.use_st_terminator);
    if (std.mem.eql(u8, body, "19;?")) return try formatReply(allocator, "19", fixture.selection_fg, fixture.use_st_terminator);
    if (std.mem.startsWith(u8, body, "4;") and std.mem.endsWith(u8, body, ";?")) {
        const num_str = body[2 .. body.len - 2];
        const n = std.fmt.parseInt(usize, num_str, 10) catch return null;
        if (n >= fixture.indexed.len) return null;
        const c = fixture.indexed[n] orelse return null;
        const ps = try std.fmt.allocPrint(allocator, "4;{d}", .{n});
        defer allocator.free(ps);
        return try formatReply(allocator, ps, c, fixture.use_st_terminator);
    }
    return null;
}

fn formatReply(allocator: std.mem.Allocator, ps: []const u8, color: ?RGB, use_st: bool) !?[]u8 {
    const c = color orelse return null;
    const term: []const u8 = if (use_st) "\x1b\\" else "\x07";
    return try std.fmt.allocPrint(
        allocator,
        "\x1b]{s};rgb:{x:0>2}{x:0>2}/{x:0>2}{x:0>2}/{x:0>2}{x:0>2}{s}",
        .{ ps, c.r, c.r, c.g, c.g, c.b, c.b, term },
    );
}

// ===== fixture palettes =====

fn solarized() Fixture {
    // A small but plausible palette: 8 base colors + fg/bg/cursor.
    const idx = struct {
        const data = [_]?RGB{
            .{ .r = 0x07, .g = 0x36, .b = 0x42 }, // 0 base02
            .{ .r = 0xdc, .g = 0x32, .b = 0x2f }, // 1 red
            .{ .r = 0x85, .g = 0x99, .b = 0x00 }, // 2 green
            .{ .r = 0xb5, .g = 0x89, .b = 0x00 }, // 3 yellow
            .{ .r = 0x26, .g = 0x8b, .b = 0xd2 }, // 4 blue
            .{ .r = 0xd3, .g = 0x36, .b = 0x82 }, // 5 magenta
            .{ .r = 0x2a, .g = 0xa1, .b = 0x98 }, // 6 cyan
            .{ .r = 0xee, .g = 0xe8, .b = 0xd5 }, // 7 base2
            null, null, null, null, null, null, null, null, // 8-15: unsupported
        };
    };
    return .{
        .indexed = &idx.data,
        .foreground = .{ .r = 0x83, .g = 0x94, .b = 0x96 },
        .background = .{ .r = 0x00, .g = 0x2b, .b = 0x36 },
        .cursor = .{ .r = 0x83, .g = 0x94, .b = 0x96 },
    };
}

fn emptyPalette() Fixture {
    const idx = struct {
        const data = [_]?RGB{null} ** 16;
    };
    return .{ .indexed = &idx.data };
}

/// What Rex answers in a normal pane: all 16 palette slots plus
/// foreground/background/cursor, and silence on the selection queries.
fn rexLike() Fixture {
    const idx = struct {
        const data = [_]?RGB{
            .{ .r = 0x48, .g = 0x4f, .b = 0x58 },
            .{ .r = 0xff, .g = 0x7b, .b = 0x72 },
            .{ .r = 0x3f, .g = 0xb9, .b = 0x50 },
            .{ .r = 0xd2, .g = 0x99, .b = 0x22 },
            .{ .r = 0x58, .g = 0xa6, .b = 0xff },
            .{ .r = 0xbc, .g = 0x8c, .b = 0xff },
            .{ .r = 0x39, .g = 0xc5, .b = 0xcf },
            .{ .r = 0xb1, .g = 0xba, .b = 0xc4 },
            .{ .r = 0x6e, .g = 0x76, .b = 0x81 },
            .{ .r = 0xff, .g = 0xa1, .b = 0x98 },
            .{ .r = 0x56, .g = 0xd3, .b = 0x64 },
            .{ .r = 0xe3, .g = 0xb3, .b = 0x41 },
            .{ .r = 0x79, .g = 0xc0, .b = 0xff },
            .{ .r = 0xd2, .g = 0xa8, .b = 0xff },
            .{ .r = 0x56, .g = 0xd4, .b = 0xdd },
            .{ .r = 0xff, .g = 0xff, .b = 0xff },
        };
    };
    return .{
        .indexed = &idx.data,
        .foreground = .{ .r = 0xe6, .g = 0xed, .b = 0xf3 },
        .background = .{ .r = 0x0d, .g = 0x11, .b = 0x17 },
        .cursor = .{ .r = 0x2f, .g = 0x81, .b = 0xf7 },
    };
}

// ===== tests =====

test "happy path: flat hex output" {
    const allocator = std.testing.allocator;
    var result = try runWithFakeTerminal(
        allocator,
        &.{ "--source=osc", "--format=flat", "--color=hex" },
        &.{},
        solarized(),
    );
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    // Foreground 0x83/0x94/0x96 should appear.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "#839496") != null);
    // Background 0x00/0x2b/0x36.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "#002b36") != null);
    // Indexed color 1 red 0xdc/0x32/0x2f.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "#dc322f") != null);
}

test "happy path: JSON output is valid and contains palette" {
    const allocator = std.testing.allocator;
    var result = try runWithFakeTerminal(
        allocator,
        &.{ "--source=osc", "--format=json", "--color=hex" },
        &.{},
        solarized(),
    );
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    // Parse it as JSON to verify shape.
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.output, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expect(root.contains("palette"));
    try std.testing.expect(root.contains("meta"));
}

test "ST terminator is accepted" {
    const allocator = std.testing.allocator;
    var fix = solarized();
    fix.use_st_terminator = true;
    var result = try runWithFakeTerminal(
        allocator,
        &.{ "--source=osc", "--format=flat", "--color=hex" },
        &.{},
        fix,
    );
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "#839496") != null);
}

test "missing replies surface as unsupported slots" {
    const allocator = std.testing.allocator;
    // solarized() leaves indexed 8-15 null and selection_bg/fg null.
    var result = try runWithFakeTerminal(
        allocator,
        &.{ "--source=osc", "--format=json", "--color=hex" },
        &.{},
        solarized(),
    );
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.output, .{});
    defer parsed.deinit();
    const meta = parsed.value.object.get("meta").?.object;
    const unsupported = meta.get("unsupported").?.array;
    var saw_sel_bg = false;
    for (unsupported.items) |v| {
        if (std.mem.eql(u8, v.string, "selection_background")) saw_sel_bg = true;
    }
    try std.testing.expect(saw_sel_bg);
}

test "all replies missing produces notice in output" {
    const allocator = std.testing.allocator;
    var result = try runWithFakeTerminal(
        allocator,
        &.{ "--source=osc", "--format=json", "--color=hex" },
        &.{},
        emptyPalette(),
    );
    defer result.deinit(allocator);
    // Exit 0 outside a multiplexer (no TMUX/STY in env); the notice tells the
    // user the terminal isn't responding.
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "no OSC color replies") != null);
}

test "rex-shaped replies: palette/fg/bg/cursor populated, selection unsupported" {
    const allocator = std.testing.allocator;
    var result = try runWithFakeTerminal(
        allocator,
        &.{ "--source=osc", "--format=json", "--color=hex" },
        &.{},
        rexLike(),
    );
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.output, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    const pal = root.get("palette").?.array;
    try std.testing.expectEqual(@as(usize, 16), pal.items.len);
    for (pal.items) |v| try std.testing.expect(v == .string);
    try std.testing.expectEqualStrings("#484f58", pal.items[0].string);
    try std.testing.expectEqualStrings("#ffffff", pal.items[15].string);

    const special = root.get("special").?.object;
    try std.testing.expectEqualStrings("#e6edf3", special.get("foreground").?.string);
    try std.testing.expectEqualStrings("#0d1117", special.get("background").?.string);
    try std.testing.expectEqualStrings("#2f81f7", special.get("cursor").?.string);
    try std.testing.expect(special.get("selection_background").? == .null);
    try std.testing.expect(special.get("selection_foreground").? == .null);

    const meta = root.get("meta").?.object;
    try std.testing.expectEqualStrings("osc", meta.get("source").?.string);
    var saw_sel_bg = false;
    var saw_sel_fg = false;
    for (meta.get("unsupported").?.array.items) |v| {
        if (std.mem.eql(u8, v.string, "selection_background")) saw_sel_bg = true;
        if (std.mem.eql(u8, v.string, "selection_foreground")) saw_sel_fg = true;
    }
    try std.testing.expect(saw_sel_bg and saw_sel_fg);
}
