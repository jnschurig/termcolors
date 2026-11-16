const std = @import("std");
const cli = @import("cli.zig");
const config = @import("config.zig");
const palette = @import("palette.zig");
const output = @import("output.zig");
const osc_source = @import("sources/osc.zig");
const ghostty_source = @import("sources/ghostty.zig");
const rex_source = @import("sources/rex.zig");
const terminal = @import("terminal.zig");

/// Restore the TTY before the default panic handler aborts, so a safety
/// check tripping mid-query can't leave the user's terminal in raw mode.
pub const panic = std.debug.FullPanic(panicRestoringTty);

fn panicRestoringTty(msg: []const u8, first_trace_addr: ?usize) noreturn {
    terminal.restore();
    std.debug.defaultPanic(msg, first_trace_addr);
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);

    var opts = cli.parse(gpa, args) catch |err| {
        std.debug.print("argument error: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer opts.deinit(gpa);

    cli.applyEnvFallback(gpa, init.environ_map, &opts) catch |err| switch (err) {
        cli.ParseError.ModeKeywordWhereEmulatorExpected => {
            // The env var carried a mode keyword (auto/osc) where an emulator
            // name was expected. Per requirements, treat as "binary not found"
            // (exit 4) with a friendly diagnostic explaining the likely cause.
            std.debug.print(
                "termcolors: $TERMCOLORS_TERMINAL looks like a --source mode (auto/osc), not an emulator name\n",
                .{},
            );
            return 4;
        },
        cli.ParseError.InvalidValue => {
            std.debug.print(
                "termcolors: $TERMCOLORS_TERMINAL value not recognized (must be a known emulator or absolute path)\n",
                .{},
            );
            return 4;
        },
        else => {
            std.debug.print("argument error: {s}\n", .{@errorName(err)});
            return 1;
        },
    };

    if (opts.help) {
        std.debug.print(
            "usage: termcolors [--format=json|env|flat] [--color=hex|rgb|hsl|oklch] " ++
                "[--only=...] [--timeout-ms=N] [--include-aliases] [--include-256] " ++
                "[--no-multiplexer-wrap] [--source=auto|osc|<emulator>|<abs-path>] " ++
                "[--osc-min-palette=N]\n",
            .{},
        );
        return 0;
    }

    var cfg = config.load(gpa, io, init.environ_map) catch |err| {
        std.debug.print("termcolors: config error: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer cfg.deinit(gpa);

    // Resolve effective fallback (only used in .auto mode).
    const fallback: ?cli.Source.Emulator = blk: {
        if (opts.env_fallback) |ef| switch (ef) {
            .emulator => |e| break :blk e,
            else => {},
        };
        if (cfg.termcolors_source) |cs| switch (cs) {
            .emulator => |e| break :blk e,
            else => {},
        };
        break :blk null;
    };

    var ts_buf: [32]u8 = undefined;
    var now_ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &now_ts);
    const ts = try formatRfc3339Utc(&ts_buf, now_ts.sec);

    switch (opts.source) {
        .osc => {
            var result = osc_source.acquire(gpa, opts) catch |err| switch (err) {
                osc_source.AcquireError.NoTty => {
                    std.debug.print("termcolors: no controlling tty (/dev/tty)\n", .{});
                    return 2;
                },
                osc_source.AcquireError.OutOfMemory => return error.OutOfMemory,
            };
            defer result.deinit(gpa);
            if (result.multiplexer != .none and result.all_replies_missing) {
                std.debug.print(
                    "termcolors: no responses inside multiplexer; enable passthrough (tmux: 'set -g allow-passthrough on')\n",
                    .{},
                );
                return 3;
            }
            const ctx = output.Context{
                .palette = result.palette,
                .unsupported = result.unsupported,
                .queried_at = ts,
                .multiplexer = result.multiplexer,
                .notice = result.notice,
                .source = "osc",
            };
            return try writeOutput(gpa, io, ctx, opts);
        },
        .emulator => |e| {
            var result = acquireEmulator(gpa, io, opts, init.environ_map, e, true) orelse return 4;
            defer result.deinit(gpa);
            const ctx = output.Context{
                .palette = result.palette,
                .queried_at = ts,
                .source = e.name,
                .theme = result.theme,
            };
            return try writeOutput(gpa, io, ctx, opts);
        },
        .auto => {
            // Attempt OSC first.
            var osc_attempt: ?osc_source.Result = osc_source.acquire(gpa, opts) catch |err| switch (err) {
                osc_source.AcquireError.NoTty => null,
                osc_source.AcquireError.OutOfMemory => return error.OutOfMemory,
            };
            defer if (osc_attempt) |*r| r.deinit(gpa);

            const sufficient = if (osc_attempt) |r| oscSufficient(r, opts.osc_min_palette) else false;

            if (sufficient) {
                const r = osc_attempt.?;
                const ctx = output.Context{
                    .palette = r.palette,
                    .unsupported = r.unsupported,
                    .queried_at = ts,
                    .multiplexer = r.multiplexer,
                    .notice = r.notice,
                    .source = "osc",
                };
                return try writeOutput(gpa, io, ctx, opts);
            }

            // Try fallback emulator if configured.
            if (fallback) |e| {
                if (acquireEmulator(gpa, io, opts, init.environ_map, e, false)) |emu_result_val| {
                    var emu_result = emu_result_val;
                    defer emu_result.deinit(gpa);
                    const ctx = output.Context{
                        .palette = emu_result.palette,
                        .queried_at = ts,
                        .source = e.name,
                        .theme = emu_result.theme,
                    };
                    return try writeOutput(gpa, io, ctx, opts);
                } else {
                    // fallback failed; emit a one-line stderr advisory but continue
                    // to whatever the OSC step produced (possibly all-null).
                    std.debug.print("termcolors: fallback source '{s}' failed; using OSC result\n", .{e.name});
                }
            }

            // Use the partial / empty OSC result (or synthesize an all-null
            // palette if OSC failed to even open the TTY).
            if (osc_attempt) |r| {
                if (r.multiplexer != .none and r.all_replies_missing and fallback == null) {
                    std.debug.print(
                        "termcolors: no responses inside multiplexer; enable passthrough (tmux: 'set -g allow-passthrough on')\n",
                        .{},
                    );
                    return 3;
                }
                const ctx = output.Context{
                    .palette = r.palette,
                    .unsupported = r.unsupported,
                    .queried_at = ts,
                    .multiplexer = r.multiplexer,
                    .notice = r.notice,
                    .source = "osc",
                };
                return try writeOutput(gpa, io, ctx, opts);
            } else {
                // No TTY and no successful fallback: emit an all-null palette.
                const palette_len: usize = if (opts.include_256) 256 else 16;
                const indexed = try gpa.alloc(?palette.Color, palette_len);
                defer gpa.free(indexed);
                @memset(indexed, null);
                const pal = palette.Palette{ .indexed = indexed };
                const ctx = output.Context{
                    .palette = pal,
                    .queried_at = ts,
                    .notice = "no controlling tty and no fallback source configured",
                    .source = "osc",
                };
                return try writeOutput(gpa, io, ctx, opts);
            }
        },
    }
}

fn writeOutput(
    gpa: std.mem.Allocator,
    io: std.Io,
    ctx: output.Context,
    opts: cli.Options,
) !u8 {
    _ = gpa;
    const stdout_file = std.Io.File.stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.Writer.init(stdout_file, io, &stdout_buf);
    try output.write(&stdout_writer.interface, ctx, opts);
    try stdout_writer.interface.flush();
    return 0;
}

fn oscSufficient(r: osc_source.Result, min_palette: u8) bool {
    if (r.palette.foreground == null) return false;
    if (r.palette.background == null) return false;
    var filled: u8 = 0;
    const limit: usize = @min(16, r.palette.indexed.len);
    for (r.palette.indexed[0..limit]) |c| if (c != null) {
        filled += 1;
    };
    return filled >= min_palette;
}

/// Common shape of every emulator source's result.
const EmulatorResult = struct {
    palette: palette.Palette,
    theme: ?[]u8,
    indexed_owner: []?palette.Color,

    fn deinit(self: *EmulatorResult, allocator: std.mem.Allocator) void {
        allocator.free(self.indexed_owner);
        if (self.theme) |t| allocator.free(t);
        self.* = undefined;
    }
};

/// Run the emulator source named by `e`. Returns null on failure; when
/// `report` is set, the source-specific diagnostic goes to stderr first.
fn acquireEmulator(
    gpa: std.mem.Allocator,
    io: std.Io,
    opts: cli.Options,
    env_map: *const std.process.Environ.Map,
    e: cli.Source.Emulator,
    report: bool,
) ?EmulatorResult {
    if (std.mem.eql(u8, e.name, "rex")) {
        const r = rex_source.acquire(gpa, io, opts, env_map) catch |err| {
            if (report) emitRexError(err);
            return null;
        };
        return .{ .palette = r.palette, .theme = r.theme, .indexed_owner = r.indexed_owner };
    }
    const r = ghostty_source.acquire(gpa, io, opts, e.binary) catch |err| {
        if (report) emitGhosttyError(err);
        return null;
    };
    return .{ .palette = r.palette, .theme = r.theme, .indexed_owner = r.indexed_owner };
}

fn emitRexError(err: rex_source.AcquireError) void {
    const detail = rex_source.last_detail[0..rex_source.last_detail_len];
    switch (err) {
        rex_source.AcquireError.UnsupportedPlatform => {
            std.debug.print("termcolors: the rex source is only supported on macOS\n", .{});
        },
        rex_source.AcquireError.AppNotFound => {
            std.debug.print("termcolors: Rex app not found: {s}\n", .{detail});
        },
        rex_source.AcquireError.ThemeIdMissing => {
            std.debug.print("termcolors: Rex theme not configured: {s}\n", .{detail});
        },
        rex_source.AcquireError.ThemeNotFound => {
            std.debug.print("termcolors: Rex {s}\n", .{detail});
        },
        rex_source.AcquireError.MalformedThemes => {
            std.debug.print("termcolors: Rex themes file malformed: {s}\n", .{detail});
        },
        rex_source.AcquireError.MalformedCustomThemes => {
            std.debug.print("termcolors: Rex custom themes malformed: {s}\n", .{detail});
        },
        rex_source.AcquireError.OutOfMemory => {
            std.debug.print("termcolors: out of memory\n", .{});
        },
    }
}

fn emitGhosttyError(err: ghostty_source.AcquireError) void {
    switch (err) {
        ghostty_source.AcquireError.BinaryNotFound => {
            std.debug.print("termcolors: 'ghostty' binary not found\n", .{});
        },
        ghostty_source.AcquireError.SubprocessFailed => {
            const line = ghostty_source.last_stderr_first_line[0..ghostty_source.last_stderr_first_line_len];
            if (line.len > 0) {
                std.debug.print("termcolors: ghostty subprocess failed: {s}\n", .{line});
            } else {
                std.debug.print("termcolors: ghostty subprocess failed\n", .{});
            }
        },
        ghostty_source.AcquireError.MalformedOutput => {
            std.debug.print("termcolors: ghostty +show-config output malformed\n", .{});
        },
        ghostty_source.AcquireError.OutOfMemory => {
            std.debug.print("termcolors: out of memory\n", .{});
        },
    }
}

fn formatRfc3339Utc(buf: *[32]u8, epoch_seconds: i64) ![]const u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(epoch_seconds) };
    const day = es.getEpochDay();
    const ymd = day.calculateYearDay();
    const md = ymd.calculateMonthDay();
    const time = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        ymd.year,
        md.month.numeric(),
        md.day_index + 1,
        time.getHoursIntoDay(),
        time.getMinutesIntoHour(),
        time.getSecondsIntoMinute(),
    });
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("sources/osc.zig");
    _ = @import("sources/ghostty.zig");
    _ = @import("sources/rex.zig");
    _ = @import("tests/cli_test.zig");
    _ = @import("tests/config_test.zig");
    _ = @import("tests/convert_test.zig");
    _ = @import("tests/output_test.zig");
    _ = @import("tests/parser_test.zig");
    _ = @import("tests/query_test.zig");
    _ = @import("tests/sources/ghostty_test.zig");
    _ = @import("tests/sources/rex_test.zig");
}
