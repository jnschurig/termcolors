//! OSC source: queries the active terminal emulator via OSC escape sequences
//! on /dev/tty. Pure data acquisition — exit-code policy lives in main.

const std = @import("std");
const cli = @import("../cli.zig");
const terminal = @import("../terminal.zig");
const query = @import("../query.zig");
const palette_mod = @import("../palette.zig");
const output = @import("../output.zig");
const multiplexer = @import("../multiplexer.zig");

pub const AcquireError = error{
    NoTty,
    OutOfMemory,
};

pub const Result = struct {
    palette: palette_mod.Palette,
    /// Slot names that the terminal did not reply to.
    unsupported: []const []const u8,
    /// Optional advisory shown in `meta.notice`.
    notice: ?[]const u8,
    multiplexer: output.Multiplexer,
    /// True when no slot responded. Combined with `multiplexer != .none`,
    /// signals the multiplexer-no-passthrough case to the caller.
    all_replies_missing: bool,
    /// Slice ownership: `palette.indexed` and `unsupported` are allocated by
    /// `acquire` via the passed allocator. Caller frees via `deinit`.
    indexed_owner: []?palette_mod.Color,
    unsupported_owner: [][]const u8,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.indexed_owner);
        allocator.free(self.unsupported_owner);
        self.* = undefined;
    }
};

pub fn acquire(gpa: std.mem.Allocator, opts: cli.Options) AcquireError!Result {
    const fd = terminal.open() catch return AcquireError.NoTty;
    defer terminal.close(fd);

    terminal.enterRaw(fd) catch return AcquireError.NoTty;
    defer terminal.restore();

    const palette_len: usize = if (opts.include_256) 256 else 16;
    const indexed = try gpa.alloc(?palette_mod.Color, palette_len);
    errdefer gpa.free(indexed);
    @memset(indexed, null);
    var pal = palette_mod.Palette{ .indexed = indexed };

    const mux = mapMultiplexer(multiplexer.detect());

    var requests: std.ArrayListUnmanaged(query.Request) = .empty;
    defer requests.deinit(gpa);
    for (0..palette_len) |i| {
        requests.append(gpa, .{ .kind = .palette_index, .index = @intCast(i) }) catch return AcquireError.OutOfMemory;
    }
    requests.append(gpa, .{ .kind = .foreground }) catch return AcquireError.OutOfMemory;
    requests.append(gpa, .{ .kind = .background }) catch return AcquireError.OutOfMemory;
    requests.append(gpa, .{ .kind = .cursor }) catch return AcquireError.OutOfMemory;
    requests.append(gpa, .{ .kind = .selection_bg }) catch return AcquireError.OutOfMemory;
    requests.append(gpa, .{ .kind = .selection_fg }) catch return AcquireError.OutOfMemory;

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    query.writeQueries(&aw.writer, requests.items) catch return AcquireError.OutOfMemory;
    {
        const bytes = aw.written();
        var remaining = bytes;
        while (remaining.len > 0) {
            const n = std.c.write(fd, remaining.ptr, remaining.len);
            if (n <= 0) break;
            remaining = remaining[@intCast(n)..];
        }
    }

    _ = query.readReplies(gpa, fd, opts.timeout_ms, requests.items, &pal) catch return AcquireError.OutOfMemory;

    // Drain any in-flight bytes still on the wire. Some terminals (notably
    // kitty) start emitting OSC replies later than our main read loop expects;
    // if those bytes arrive after we restore canonical mode they leak into the
    // user's shell prompt as garbage. We give late replies one more brief
    // window — long enough to consume stragglers, short enough not to hang.
    // Anything we can parse updates `pal`; the rest is silently consumed so it
    // doesn't pollute the next prompt.
    query.drainTail(gpa, fd, 150, &pal) catch {};

    var unsupported: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer unsupported.deinit(gpa);
    if (pal.foreground == null) unsupported.append(gpa, "foreground") catch return AcquireError.OutOfMemory;
    if (pal.background == null) unsupported.append(gpa, "background") catch return AcquireError.OutOfMemory;
    if (pal.cursor == null) unsupported.append(gpa, "cursor") catch return AcquireError.OutOfMemory;
    if (pal.selection_background == null) unsupported.append(gpa, "selection_background") catch return AcquireError.OutOfMemory;
    if (pal.selection_foreground == null) unsupported.append(gpa, "selection_foreground") catch return AcquireError.OutOfMemory;

    var missing_count: usize = 0;
    for (pal.indexed) |c| if (c == null) {
        missing_count += 1;
    };
    if (pal.foreground == null) missing_count += 1;
    if (pal.background == null) missing_count += 1;
    if (pal.cursor == null) missing_count += 1;
    if (pal.selection_background == null) missing_count += 1;
    if (pal.selection_foreground == null) missing_count += 1;
    const all_missing = missing_count == requests.items.len;
    const notice: ?[]const u8 = if (all_missing)
        "no OSC color replies received; terminal may not support color queries (e.g. nvim :terminal)"
    else
        null;

    const unsupported_slice = unsupported.toOwnedSlice(gpa) catch return AcquireError.OutOfMemory;

    return Result{
        .palette = pal,
        .unsupported = unsupported_slice,
        .notice = notice,
        .multiplexer = mux,
        .all_replies_missing = all_missing,
        .indexed_owner = indexed,
        .unsupported_owner = unsupported_slice,
    };
}

fn mapMultiplexer(k: multiplexer.Kind) output.Multiplexer {
    return switch (k) {
        .none => .none,
        .tmux => .tmux,
        .screen => .screen,
    };
}
