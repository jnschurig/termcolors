const std = @import("std");
const cli = @import("cli.zig");
const terminal = @import("terminal.zig");
const query = @import("query.zig");
const palette = @import("palette.zig");
const output = @import("output.zig");
const multiplexer = @import("multiplexer.zig");

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

    if (opts.help) {
        std.debug.print(
            "usage: termcolors [--format=json|env|flat] [--color=hex|rgb|hsl|oklch] " ++
                "[--only=...] [--timeout-ms=N] [--include-aliases] [--include-256] " ++
                "[--no-multiplexer-wrap]\n",
            .{},
        );
        return 0;
    }

    const fd = terminal.open() catch {
        std.debug.print("termcolors: no controlling tty (/dev/tty)\n", .{});
        return 2;
    };
    defer terminal.close(fd);

    try terminal.enterRaw(fd);
    defer terminal.restore();

    const palette_len: usize = if (opts.include_256) 256 else 16;
    const indexed = try gpa.alloc(?palette.Color, palette_len);
    defer gpa.free(indexed);
    @memset(indexed, null);
    var pal = palette.Palette{ .indexed = indexed };

    const mux = mapMultiplexer(multiplexer.detect());

    var requests: std.ArrayListUnmanaged(query.Request) = .empty;
    defer requests.deinit(gpa);
    for (0..palette_len) |i| {
        try requests.append(gpa, .{ .kind = .palette_index, .index = @intCast(i) });
    }
    try requests.append(gpa, .{ .kind = .foreground });
    try requests.append(gpa, .{ .kind = .background });
    try requests.append(gpa, .{ .kind = .cursor });
    try requests.append(gpa, .{ .kind = .selection_bg });
    try requests.append(gpa, .{ .kind = .selection_fg });

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try query.writeQueries(&aw.writer, requests.items);
    {
        const bytes = aw.written();
        var remaining = bytes;
        while (remaining.len > 0) {
            const n = std.c.write(fd, remaining.ptr, remaining.len);
            if (n <= 0) break;
            remaining = remaining[@intCast(n)..];
        }
    }

    const result = try query.readReplies(gpa, fd, opts.timeout_ms, requests.items, &pal);

    if (mux != .none and result.unsupported_count == requests.items.len) {
        std.debug.print(
            "termcolors: no responses inside multiplexer; enable passthrough (tmux: 'set -g allow-passthrough on')\n",
            .{},
        );
        return 3;
    }

    var unsupported: std.ArrayListUnmanaged([]const u8) = .empty;
    defer unsupported.deinit(gpa);
    if (pal.foreground == null) try unsupported.append(gpa, "foreground");
    if (pal.background == null) try unsupported.append(gpa, "background");
    if (pal.cursor == null) try unsupported.append(gpa, "cursor");
    if (pal.selection_background == null) try unsupported.append(gpa, "selection_background");
    if (pal.selection_foreground == null) try unsupported.append(gpa, "selection_foreground");

    var ts_buf: [32]u8 = undefined;
    var now_ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &now_ts);
    const ts = try formatRfc3339Utc(&ts_buf, now_ts.sec);

    const ctx = output.Context{
        .palette = pal,
        .unsupported = unsupported.items,
        .queried_at = ts,
        .multiplexer = mux,
    };

    const stdout_file = std.Io.File.stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.Writer.init(stdout_file, io, &stdout_buf);
    try output.write(&stdout_writer.interface, ctx, opts);
    try stdout_writer.interface.flush();

    return 0;
}

fn mapMultiplexer(k: multiplexer.Kind) output.Multiplexer {
    return switch (k) {
        .none => .none,
        .tmux => .tmux,
        .screen => .screen,
    };
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
}
