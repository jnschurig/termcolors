const std = @import("std");
const cli = @import("cli.zig");
const config = @import("config.zig");
const palette = @import("palette.zig");
const output = @import("output.zig");
const osc_source = @import("sources/osc.zig");
const ghostty_source = @import("sources/ghostty.zig");

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
            var result = ghostty_source.acquire(gpa, io, opts, e.binary) catch |err| {
                emitGhosttyError(err);
                return 4;
            };
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
                if (ghostty_source.acquire(gpa, io, opts, e.binary)) |ghostty_result_val| {
                    var ghostty_result = ghostty_result_val;
                    defer ghostty_result.deinit(gpa);
                    const ctx = output.Context{
                        .palette = ghostty_result.palette,
                        .queried_at = ts,
                        .source = e.name,
                        .theme = ghostty_result.theme,
                    };
                    return try writeOutput(gpa, io, ctx, opts);
                } else |_| {
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
}
