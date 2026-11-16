const std = @import("std");
const posix = std.posix;

var original_termios: ?posix.termios = null;
var tty_fd: ?posix.fd_t = null;

pub const Error = error{
    NoTty,
    IoctlFailed,
};

pub fn open() !posix.fd_t {
    const fd = posix.openat(posix.AT.FDCWD, "/dev/tty", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0) catch return Error.NoTty;
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
    // VMIN=0 + VTIME=N makes `read` block up to N×100 ms and return whatever
    // bytes are available (possibly 0). We rely on this for deadline-bounded
    // reads in `query.zig` because macOS `poll()` returns POLLNVAL on
    // `/dev/tty` and can't be used to wait for data.
    //
    // VTIME=2 = 200 ms per read call. The outer read loop uses the overall
    // `--timeout-ms` budget to decide when to stop.
    raw.cc[@backingInt(posix.V.MIN)] = 0;
    raw.cc[@backingInt(posix.V.TIME)] = 2;

    // Handlers go in before raw mode so there is no window where a signal
    // can kill us with the TTY left raw.
    installSignalHandlers();
    try posix.tcsetattr(fd, .FLUSH, raw);
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
    posix.sigaction(posix.SIG.QUIT, &act, null);
}
