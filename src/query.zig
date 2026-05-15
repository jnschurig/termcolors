const std = @import("std");
const posix = std.posix;
const palette = @import("palette.zig");
const parser = @import("parser.zig");

const ESC: u8 = 0x1b;
const BEL: u8 = 0x07;

pub const Kind = enum {
    foreground,
    background,
    cursor,
    selection_bg,
    selection_fg,
    palette_index, // companion .index field disambiguates
};

pub const Request = struct {
    kind: Kind,
    index: u8 = 0,
};

pub const Result = struct {
    /// Palette mutated in place: indexed[], foreground, background, etc.
    /// Slots that didn't receive a reply remain at their pre-call value.
    unsupported_count: usize,
};

/// Writes every requested OSC query to `writer` in a single batch.
pub fn writeQueries(writer: *std.Io.Writer, requests: []const Request) !void {
    for (requests) |req| {
        switch (req.kind) {
            .foreground => try writer.writeAll("\x1b]10;?\x07"),
            .background => try writer.writeAll("\x1b]11;?\x07"),
            .cursor => try writer.writeAll("\x1b]12;?\x07"),
            .selection_bg => try writer.writeAll("\x1b]17;?\x07"),
            .selection_fg => try writer.writeAll("\x1b]19;?\x07"),
            .palette_index => try writer.print("\x1b]4;{d};?\x07", .{req.index}),
        }
    }
}

/// Reads bytes from `fd` with a poll(2)-bounded wait. Each complete OSC reply
/// is fed to `parser.parseReply` and the result merged into `pal`. Stops when
/// every entry in `expected` has been seen or `timeout_ms` elapses without
/// further data.
///
/// `expected` is an opaque token set keyed by `kindToken(kind, index)`. Tokens
/// are removed as replies arrive; tokens that remain at exit are unsupported.
pub fn readReplies(
    allocator: std.mem.Allocator,
    fd: posix.fd_t,
    timeout_ms: u32,
    requests: []const Request,
    pal: *palette.Palette,
) !Result {
    var pending: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer pending.deinit(allocator);
    for (requests) |r| try pending.put(allocator, kindToken(r.kind, r.index), {});

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    var pfd = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
    var scratch: [4096]u8 = undefined;

    const deadline_ms = nowMs() + timeout_ms;
    while (pending.count() > 0) {
        const now = nowMs();
        if (now >= deadline_ms) break;
        const remaining: i32 = @intCast(deadline_ms - now);
        const ready = try posix.poll(&pfd, remaining);
        if (ready == 0) break;
        const n = posix.read(fd, &scratch) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (n == 0) break;
        try buf.appendSlice(allocator, scratch[0..n]);
        try drainBuffer(&buf, &pending, pal);
    }

    return .{ .unsupported_count = pending.count() };
}

fn drainBuffer(
    buf: *std.ArrayListUnmanaged(u8),
    pending: *std.AutoHashMapUnmanaged(u32, void),
    pal: *palette.Palette,
) !void {
    var start: usize = 0;
    while (findReply(buf.items[start..])) |range| {
        const abs_start = start + range.start;
        const abs_end = start + range.end; // inclusive of terminator
        const slice = buf.items[abs_start .. abs_end + 1];
        if (parser.parseReply(slice)) |reply| {
            applyReply(pal, reply);
            _ = pending.remove(replyToken(reply.kind));
        } else |_| {
            // ignore malformed
        }
        start = abs_end + 1;
    }
    if (start > 0) {
        const remaining = buf.items.len - start;
        std.mem.copyForwards(u8, buf.items[0..remaining], buf.items[start..]);
        buf.shrinkRetainingCapacity(remaining);
    }
}

const Range = struct { start: usize, end: usize };

/// Locates the next `ESC ] ... <BEL | ESC \>` in `bytes`. Returns indices
/// inclusive of the opening ESC and the terminator's last byte. Skips garbage
/// bytes before the next ESC.
fn findReply(bytes: []const u8) ?Range {
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 1) {
        if (bytes[i] != ESC or bytes[i + 1] != ']') continue;
        var j = i + 2;
        while (j < bytes.len) : (j += 1) {
            if (bytes[j] == BEL) return .{ .start = i, .end = j };
            if (bytes[j] == ESC and j + 1 < bytes.len and bytes[j + 1] == '\\') {
                return .{ .start = i, .end = j + 1 };
            }
        }
        return null; // OSC begun but not yet terminated
    }
    return null;
}

fn applyReply(pal: *palette.Palette, reply: parser.Reply) void {
    switch (reply.kind) {
        .foreground => pal.foreground = reply.color,
        .background => pal.background = reply.color,
        .cursor => pal.cursor = reply.color,
        .selection_bg => pal.selection_background = reply.color,
        .selection_fg => pal.selection_foreground = reply.color,
        .palette_index => |n| {
            if (n < pal.indexed.len) pal.indexed[n] = reply.color;
        },
    }
}

fn kindToken(kind: Kind, index: u8) u32 {
    return switch (kind) {
        .foreground => 0x10000,
        .background => 0x10001,
        .cursor => 0x10002,
        .selection_bg => 0x10003,
        .selection_fg => 0x10004,
        .palette_index => @as(u32, index),
    };
}

fn replyToken(kind: parser.ReplyKind) u32 {
    return switch (kind) {
        .foreground => 0x10000,
        .background => 0x10001,
        .cursor => 0x10002,
        .selection_bg => 0x10003,
        .selection_fg => 0x10004,
        .palette_index => |n| @as(u32, n),
    };
}

fn nowMs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(@divTrunc(ts.nsec, 1_000_000)));
}

// ===== tests =====

test "writeQueries emits correct OSC sequences" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeQueries(&w, &.{
        .{ .kind = .foreground },
        .{ .kind = .palette_index, .index = 7 },
        .{ .kind = .background },
    });
    try std.testing.expectEqualStrings(
        "\x1b]10;?\x07\x1b]4;7;?\x07\x1b]11;?\x07",
        w.buffered(),
    );
}

test "findReply locates BEL-terminated OSC" {
    const r = findReply("garbage\x1b]10;rgb:00/00/00\x07more").?;
    try std.testing.expectEqual(@as(usize, 7), r.start);
    try std.testing.expectEqual(@as(usize, 24), r.end);
}

test "findReply locates ST-terminated OSC" {
    const r = findReply("\x1b]11;rgb:1d/1f/21\x1b\\").?;
    try std.testing.expectEqual(@as(usize, 0), r.start);
    try std.testing.expectEqual(@as(usize, 18), r.end);
}

test "findReply returns null for incomplete" {
    try std.testing.expect(findReply("\x1b]10;rgb:") == null);
}

test "drainBuffer dispatches replies and trims" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "\x1b]10;rgb:c5c5/c8c8/c6c6\x07\x1b]11;rgb:1d/1f/21\x1b\\trailing");

    var pending: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer pending.deinit(allocator);
    try pending.put(allocator, kindToken(.foreground, 0), {});
    try pending.put(allocator, kindToken(.background, 0), {});

    var indexed = [_]?palette.Color{null} ** 16;
    var pal = palette.Palette{ .indexed = &indexed };
    try drainBuffer(&buf, &pending, &pal);

    try std.testing.expectEqual(@as(u32, 0), pending.count());
    try std.testing.expectEqual(@as(u8, 0xc5), pal.foreground.?.r);
    try std.testing.expectEqual(@as(u8, 0x1d), pal.background.?.r);
    try std.testing.expectEqualStrings("trailing", buf.items);
}
