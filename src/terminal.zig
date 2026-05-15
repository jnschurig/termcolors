const std = @import("std");
const posix = std.posix;

var original_termios: ?posix.termios = null;
var tty_fd: ?posix.fd_t = null;

pub const Error = error{
    NoTty,
    IoctlFailed,
};

pub fn open() !posix.fd_t {
    const fd = posix.openat(posix.AT.FDCWD, "/dev/tty", .{ .ACCMODE = .RDWR }, 0) catch return Error.NoTty;
    tty_fd = fd;
    return fd;
}

pub fn close(fd: posix.fd_t) void {
    _ = std.c.close(fd);
}

pub fn enterRaw(fd: posix.fd_t) !void {
    const current = try posix.tcgetattr(fd);
    original_termios = current;

    var raw = current;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.lflag.ISIG = false;
    raw.iflag.IXON = false;
    raw.iflag.ICRNL = false;
    raw.cc[@intFromEnum(posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;

    try posix.tcsetattr(fd, .FLUSH, raw);
    installSignalHandlers();
}

pub fn restore() void {
    if (original_termios) |t| {
        if (tty_fd) |fd| {
            posix.tcsetattr(fd, .FLUSH, t) catch {};
        }
        original_termios = null;
    }
}

fn handleSignal(sig: posix.SIG) callconv(.c) void {
    restore();
    const act = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(sig, &act, null);
    posix.raise(sig) catch {};
}

fn installSignalHandlers() void {
    const act = posix.Sigaction{
        .handler = .{ .handler = &handleSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &act, null);
    posix.sigaction(posix.SIG.TERM, &act, null);
    posix.sigaction(posix.SIG.HUP, &act, null);
}
