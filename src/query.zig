const std = @import("std");
const posix = std.posix;
const palette = @import("palette.zig");
const parser = @import("parser.zig");

const ESC: u8 = 0x1b;
const BEL: u8 = 0x07;

/// Cap on buffered bytes that have not parsed into a reply. A complete
/// 256-slot reply set is under 8 KiB, so anything beyond this is a flood
/// (e.g. an OSC that never terminates), and is dropped rather than grown.
pub const MAX_PENDING_BYTES = 64 * 1024;

/// When the env var `TERMCOLORS_DEBUG_OSC` is set to any non-empty value at
/// program start, the read loops emit per-iteration diagnostics to stderr.
/// Tracks why the loop exits / how data is flowing, for terminal-specific
/// bug hunts.
var debug_osc_checked: bool = false;
var debug_osc_enabled: bool = false;

fn debugEnabled() bool {
    if (!debug_osc_checked) {
        if (std.c.getenv("TERMCOLORS_DEBUG_OSC")) |p| {
            // Any non-empty value enables debug output.
            debug_osc_enabled = p[0] != 0;
        }
        debug_osc_checked = true;
    }
    return debug_osc_enabled;
}

fn dbg(comptime fmt: []const u8, args: anytype) void {
    if (debugEnabled()) std.debug.print("[osc-debug] " ++ fmt ++ "\n", args);
}

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

/// Reads bytes from `fd` directly, relying on the terminal's VMIN=0/VTIME=2
/// setting (configured in `terminal.enterRaw`) to bound each `read()` call.
/// Each `read` blocks up to ~200 ms and returns whatever bytes are available
/// (possibly zero). Loops until every entry in `requests` has been matched by
/// a reply, or `timeout_ms` elapses.
///
/// We deliberately do NOT use `poll(2)`: on macOS, `poll` returns POLLNVAL for
/// `/dev/tty` even though the fd is fully functional for read/write. The
/// VMIN/VTIME-driven blocking-read strategy side-steps that platform quirk
/// and works equivalently on Linux.
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

    var scratch: [4096]u8 = undefined;

    dbg("readReplies start: fd={d} timeout_ms={d} pending={d}", .{ fd, timeout_ms, pending.count() });
    const deadline_ms = nowMs() + timeout_ms;
    var iter: u32 = 0;
    while (pending.count() > 0) {
        iter += 1;
        if (nowMs() >= deadline_ms) {
            dbg("deadline elapsed at iter {d}; pending={d}", .{ iter, pending.count() });
            break;
        }
        const n = posix.read(fd, &scratch) catch |err| switch (err) {
            error.WouldBlock => {
                dbg("iter {d}: read=WouldBlock; sleeping 2ms", .{iter});
                sleepMs(2);
                continue;
            },
            else => return err,
        };
        if (n == 0) {
            // VMIN=0/VTIME=2: read waited ~200 ms with no bytes. Keep
            // looping until the overall deadline expires.
            dbg("iter {d}: read=0 (VTIME timeout, no data)", .{iter});
            continue;
        }
        dbg("iter {d}: read={d} bytes", .{ iter, n });
        try buf.appendSlice(allocator, scratch[0..n]);
        const before_pending = pending.count();
        try drainBuffer(&buf, &pending, pal);
        if (pending.count() != before_pending) {
            dbg("iter {d}: pending {d} -> {d}", .{ iter, before_pending, pending.count() });
        }
    }

    dbg("readReplies done: pending={d}", .{pending.count()});
    return .{ .unsupported_count = pending.count() };
}

/// Read and discard any in-flight bytes still on the wire after the main
/// read loop has finished. Any well-formed OSC replies recovered are applied
/// to `pal`; everything else is silently consumed.
///
/// Why this exists: some terminals (notably kitty) buffer their OSC replies
/// and emit them later than callers expect. If those bytes arrive after we
/// restore the TTY to canonical mode, they leak into the user's shell prompt.
/// Calling `drainTail` before restoration eats them.
///
/// `total_ms` is an overall budget; the function returns when either the
/// budget expires OR the inter-byte quiet window (about a third of `total_ms`)
/// elapses with no new data.
pub fn drainTail(
    allocator: std.mem.Allocator,
    fd: posix.fd_t,
    total_ms: u32,
    pal: *palette.Palette,
) !void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    var scratch: [4096]u8 = undefined;
    var pending: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer pending.deinit(allocator);

    const deadline_ms = nowMs() + total_ms;
    var consecutive_empty: u8 = 0;
    while (true) {
        if (nowMs() >= deadline_ms) return;
        const n = posix.read(fd, &scratch) catch |err| switch (err) {
            error.WouldBlock => {
                sleepMs(2);
                continue;
            },
            else => return,
        };
        if (n == 0) {
            // Each read is a VTIME-bounded ~200 ms wait. Two empties in a row
            // means the terminal has stopped sending for at least 400 ms,
            // which is plenty of "quiet" — exit early.
            consecutive_empty += 1;
            if (consecutive_empty >= 2) return;
            continue;
        }
        consecutive_empty = 0;
        try buf.appendSlice(allocator, scratch[0..n]);
        try drainBuffer(&buf, &pending, pal);
    }
}

pub fn drainBuffer(
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
    if (buf.items.len > MAX_PENDING_BYTES) buf.clearRetainingCapacity();
}

const Range = struct { start: usize, end: usize };

/// Locates the next `ESC ] ... <BEL | ESC \>` in `bytes`. Returns indices
/// inclusive of the opening ESC and the terminator's last byte. Skips garbage
/// bytes before the next ESC.
pub fn findReply(bytes: []const u8) ?Range {
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

pub fn kindToken(kind: Kind, index: u8) u32 {
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

fn sleepMs(ms: u32) void {
    var req: std.c.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
    _ = std.c.nanosleep(&req, null);
}

fn nowMs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(@divTrunc(ts.nsec, 1_000_000)));
}
