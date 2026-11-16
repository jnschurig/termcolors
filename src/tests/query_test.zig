const std = @import("std");
const query = @import("../query.zig");
const palette = @import("../palette.zig");

const BEL: u8 = 0x07;
const drainBuffer = query.drainBuffer;
const findReply = query.findReply;
const kindToken = query.kindToken;
const MAX_PENDING_BYTES = query.MAX_PENDING_BYTES;
const writeQueries = query.writeQueries;

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

    var indexed: [16]?palette.Color = @splat(null);
    var pal = palette.Palette{ .indexed = &indexed };
    try drainBuffer(&buf, &pending, &pal);

    try std.testing.expectEqual(@as(u32, 0), pending.count());
    try std.testing.expectEqual(@as(u8, 0xc5), pal.foreground.?.r);
    try std.testing.expectEqual(@as(u8, 0x1d), pal.background.?.r);
    try std.testing.expectEqualStrings("trailing", buf.items);
}

test "drainBuffer drops an unterminated flood instead of growing" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    var pending: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer pending.deinit(allocator);
    var indexed: [16]?palette.Color = @splat(null);
    var pal = palette.Palette{ .indexed = &indexed };

    try buf.appendSlice(allocator, "\x1b]10;");
    try buf.appendNTimes(allocator, 'A', MAX_PENDING_BYTES);
    try drainBuffer(&buf, &pending, &pal);
    try std.testing.expectEqual(@as(usize, 0), buf.items.len);

    // A well-formed reply after the flood still parses.
    try buf.appendSlice(allocator, "\x1b]11;rgb:1d/1f/21\x07");
    try drainBuffer(&buf, &pending, &pal);
    try std.testing.expectEqual(@as(u8, 0x1d), pal.background.?.r);
}
