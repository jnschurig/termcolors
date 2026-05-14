const std = @import("std");
const cli = @import("cli.zig");
const terminal = @import("terminal.zig");
const query = @import("query.zig");
const palette = @import("palette.zig");
const output = @import("output.zig");
const multiplexer = @import("multiplexer.zig");

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var opts = cli.parse(allocator, args) catch |err| {
        std.debug.print("argument error: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer opts.deinit(allocator);

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
    defer std.posix.close(fd);

    try terminal.enterRaw(fd);
    defer terminal.restore();

    const palette_len: usize = if (opts.include_256) 256 else 16;
    const indexed = try allocator.alloc(?palette.Color, palette_len);
    defer allocator.free(indexed);
    @memset(indexed, null);
    var pal = palette.Palette{ .indexed = indexed };

    const mux = mapMultiplexer(multiplexer.detect());

    var requests: std.ArrayListUnmanaged(query.Request) = .empty;
    defer requests.deinit(allocator);
    for (0..palette_len) |i| {
        try requests.append(allocator, .{ .kind = .palette_index, .index = @intCast(i) });
    }
    try requests.append(allocator, .{ .kind = .foreground });
    try requests.append(allocator, .{ .kind = .background });
    try requests.append(allocator, .{ .kind = .cursor });
    try requests.append(allocator, .{ .kind = .selection_bg });
    try requests.append(allocator, .{ .kind = .selection_fg });

    var tty_file = std.fs.File{ .handle = fd };
    try query.writeQueries(tty_file.writer(), requests.items);

    const result = try query.readReplies(allocator, fd, opts.timeout_ms, requests.items, &pal);

    if (mux != .none and result.unsupported_count == requests.items.len) {
        std.debug.print(
            "termcolors: no responses inside multiplexer; enable passthrough (tmux: 'set -g allow-passthrough on')\n",
            .{},
        );
        return 3;
    }

    var unsupported: std.ArrayListUnmanaged([]const u8) = .empty;
    defer unsupported.deinit(allocator);
    if (pal.foreground == null) try unsupported.append(allocator, "foreground");
    if (pal.background == null) try unsupported.append(allocator, "background");
    if (pal.cursor == null) try unsupported.append(allocator, "cursor");
    if (pal.selection_background == null) try unsupported.append(allocator, "selection_background");
    if (pal.selection_foreground == null) try unsupported.append(allocator, "selection_foreground");

    var ts_buf: [32]u8 = undefined;
    const ts = try formatRfc3339Utc(&ts_buf, std.time.timestamp());

    const ctx = output.Context{
        .palette = pal,
        .unsupported = unsupported.items,
        .queried_at = ts,
        .multiplexer = mux,
    };

    const stdout = std.io.getStdOut().writer();
    try output.write(stdout, ctx, opts);

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
