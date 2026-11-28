//! The text console of a Linux virtual terminal (VT), for the direct
//! backend. The backend draws on the framebuffer, so the console must
//! stop its own text output (`KD_GRAPHICS`) and must give it back (the
//! mode that it had) on every way out of the program.
//!
//! `check` runs before the backend opens any device. It fails closed:
//! it refuses to run when the environment names a display server
//! (`WAYLAND_DISPLAY`, `DISPLAY`, or a session type of x11 or wayland),
//! when the program has no VT as its terminal, when that VT is not the
//! active one, and when the console is already in graphics mode (a
//! display server or another program owns it). The terminal comes from
//! the standard input, or from `--tty`. The program never opens a fixed
//! device name.
//!
//! `restoreNow` is the one function that gives the console back. It uses
//! only an atomic and one `ioctl`, so a signal handler and a panic
//! handler can call it. `graphics` installs a handler for each signal
//! whose default action ends the program, and leaves a signal that the
//! program ignores as it is, so an ignored signal cannot restore the text
//! mode while the program draws. The handler stack is set for the main
//! thread only, so a stack overflow restores the console on that thread,
//! and a stack overflow on the render thread does not. SIGTSTP keeps its
//! action, so a stopped program leaves the console in graphics mode until
//! it continues. The handler puts the old
//! action back and sends the signal again to its thread. When an old
//! handler returns, the program ends, because the console is in text
//! mode. The program calls `restoreNow` in the `exit` command and in the
//! panic handler too.
//! SIGKILL cannot be caught, so a program that SIGKILL ends leaves the
//! console in graphics mode until the next program resets it.
//!
//! This file does not own the VT. It does not set `KDSKBMODE`, the
//! termios state, or `VT_SETMODE`, so a VT switch and the keyboard of the
//! console are not handled. `Direct.init` stays off unless the caller
//! sets `unsafe_test_device`.
//! Every system call goes through a `Host`, so a test uses a fake.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const linux = std.os.linux;
const sys = @import("../sys/linux.zig");

/// The calls to the system. `real_host` makes the real ones.
pub const Host = struct {
    ctx: ?*anyopaque = null,
    /// The name of the active VT, such as "tty3".
    activeVt: *const fn (ctx: ?*anyopaque, buf: []u8) ?[]const u8,
    /// The path of the terminal of the standard input, such as "/dev/tty3".
    ownTty: *const fn (ctx: ?*anyopaque, buf: []u8) ?[]const u8,
    open: *const fn (ctx: ?*anyopaque, path: []const u8) ?i32,
    getMode: *const fn (ctx: ?*anyopaque, fd: i32) ?u32,
    setMode: *const fn (ctx: ?*anyopaque, fd: i32, mode: u32) bool,
    close: *const fn (ctx: ?*anyopaque, fd: i32) void,
};

/// The variables of the environment that name a display server.
pub const Session = struct {
    wayland_display: ?[]const u8 = null,
    x_display: ?[]const u8 = null,
    session_type: ?[]const u8 = null,
};

pub const Error = error{
    DisplayServerRunning,
    NoVirtualTerminal,
    NotActiveVt,
    CannotOpenConsole,
    ConsoleInGraphicsMode,
    CannotSetGraphicsMode,
};

fn nonEmpty(v: ?[]const u8) bool {
    return if (v) |s| s.len > 0 else false;
}

/// "tty3" gives 3. Only a name of the form ttyN with N from 1 is a VT.
/// Each character after "tty" must be a digit.
fn vtNumber(name: []const u8) ?u32 {
    if (!std.mem.startsWith(u8, name, "tty") or name.len == 3) return null;
    for (name[3..]) |ch| if (!std.ascii.isDigit(ch)) return null;
    const n = std.fmt.parseInt(u32, name[3..], 10) catch return null;
    return if (n >= 1) n else null;
}

/// The name of a VT from its path. The path must be exactly `/dev/tty<N>`.
fn vtName(path: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, "/dev/")) return null;
    const name = path["/dev/".len..];
    return if (vtNumber(name) != null) name else null;
}

/// Checks that the program can take the console. It gives the path of the VT.
/// The path is in `buf`.
pub fn check(session: Session, host: *const Host, tty_override: ?[]const u8, buf: []u8) Error![]const u8 {
    if (nonEmpty(session.wayland_display) or nonEmpty(session.x_display)) return error.DisplayServerRunning;
    if (session.session_type) |s| {
        if (std.ascii.eqlIgnoreCase(s, "x11") or std.ascii.eqlIgnoreCase(s, "wayland") or std.ascii.eqlIgnoreCase(s, "mir")) return error.DisplayServerRunning;
    }
    const path = tty_override orelse host.ownTty(host.ctx, buf) orelse return error.NoVirtualTerminal;
    const name = vtName(path) orelse return error.NoVirtualTerminal;
    var active_buf: [32]u8 = undefined;
    const active = host.activeVt(host.ctx, &active_buf) orelse return error.NotActiveVt;
    if (!std.mem.eql(u8, std.mem.trim(u8, active, " \n"), name)) return error.NotActiveVt;
    return path;
}

// ---- The state that a signal handler reads ----

var restore_host: ?*const Host = null;
var restore_fd: std.atomic.Value(i32) = .init(-1);
var restore_mode: std.atomic.Value(u32) = .init(0);
/// False in a test: the handler does not end the program.
var end_on_signal: bool = true;

/// Gives the console back. It is safe in a signal handler and a panic handler,
/// and it does nothing when the console is not in graphics mode.
pub fn restoreNow() void {
    const fd = restore_fd.swap(-1, .acq_rel);
    if (fd < 0) return;
    const host = restore_host orelse return;
    _ = host.setMode(host.ctx, fd, restore_mode.load(.acquire));
}

const handled = [_]linux.SIG{ .INT, .TERM, .HUP, .QUIT, .ABRT, .SEGV, .BUS, .FPE, .ILL, .TRAP, .SYS, .PIPE, .ALRM, .VTALRM, .PROF, .USR1, .USR2, .XCPU, .XFSZ, .STKFLT, .IO, .PWR };

/// The actions before `graphics`. The handler puts them back.
var old_actions: [handled.len]linux.Sigaction = undefined;
/// False for a signal that the program ignored before `graphics`.
var installed: [handled.len]bool = @splat(false);
var old_stack: linux.stack_t = undefined;
/// A stack overflow leaves no room on the normal stack for a handler.
var signal_stack: [32 * 1024]u8 align(16) = undefined;

fn onSignal(sig: linux.SIG) callconv(.c) void {
    restoreNow();
    if (!end_on_signal) return;
    for (handled, 0..) |h, i| if (h == sig) {
        _ = linux.sigaction(sig, &old_actions[i], null);
    };
    // NODEFER does not block the signal, so the old action runs at once on this thread.
    _ = linux.tkill(linux.gettid(), sig);
    // An old handler returned. The console is in text mode, so no more drawing can happen.
    linux.exit_group(@intCast(128 + @intFromEnum(sig)));
}

pub const Console = struct {
    host: *const Host = &real_host,
    fd: i32 = -1,
    /// The mode that the console had before `graphics`.
    original: u32 = 0,
    active: bool = false,
    handlers: bool = false,

    /// Checks the session, opens the VT, and reads its mode. It does not change the mode.
    pub fn prepare(c: *Console, session: Session, tty_override: ?[]const u8) Error!void {
        var buf: [64]u8 = undefined;
        const path = try check(session, c.host, tty_override, &buf);
        const fd = c.host.open(c.host.ctx, path) orelse return error.CannotOpenConsole;
        errdefer c.host.close(c.host.ctx, fd);
        const mode = c.host.getMode(c.host.ctx, fd) orelse return error.CannotOpenConsole;
        if (mode == sys.KD_GRAPHICS) return error.ConsoleInGraphicsMode;
        c.fd = fd;
        c.original = mode;
    }

    /// Installs the handlers that restore the console, and stops its text.
    /// The handlers come first, so a signal during the change restores the
    /// mode. On an error the console keeps its mode and no handler stays.
    pub fn graphics(c: *Console) Error!void {
        if (c.fd < 0 or c.active) return;
        restore_host = c.host;
        restore_mode.store(c.original, .release);
        restore_fd.store(c.fd, .release);
        c.installHandlers();
        if (!c.host.setMode(c.host.ctx, c.fd, sys.KD_GRAPHICS)) {
            restore_fd.store(-1, .release);
            c.removeHandlers();
            return error.CannotSetGraphicsMode;
        }
        c.active = true;
    }

    fn installHandlers(c: *Console) void {
        var act: linux.Sigaction = .{
            .handler = .{ .handler = onSignal },
            .mask = linux.sigemptyset(),
            .flags = linux.SA.NODEFER | linux.SA.ONSTACK,
        };
        const stack: linux.stack_t = .{ .sp = &signal_stack, .flags = 0, .size = signal_stack.len };
        _ = linux.sigaltstack(&stack, &old_stack);
        for (handled, 0..) |sig, i| {
            _ = linux.sigaction(sig, null, &old_actions[i]);
            installed[i] = old_actions[i].handler.handler != linux.SIG.IGN;
            if (installed[i]) _ = linux.sigaction(sig, &act, null);
        }
        c.handlers = true;
    }

    fn removeHandlers(c: *Console) void {
        if (!c.handlers) return;
        for (handled, 0..) |sig, i| {
            if (installed[i]) _ = linux.sigaction(sig, &old_actions[i], null);
            installed[i] = false;
        }
        _ = linux.sigaltstack(&old_stack, null);
        c.handlers = false;
    }

    /// Gives the console back and closes it.
    pub fn text(c: *Console) void {
        // The mode goes back first, so a signal in this function finds a restored console.
        if (c.active) restoreNow();
        c.removeHandlers();
        c.active = false;
        if (c.fd >= 0) {
            c.host.close(c.host.ctx, c.fd);
            c.fd = -1;
        }
    }
};

// ---- The real host ----

fn realActive(_: ?*anyopaque, buf: []u8) ?[]const u8 {
    const fd = sys.open("/sys/class/tty/tty0/active", .{ .ACCMODE = .RDONLY }) catch return null;
    defer _ = linux.close(fd);
    const n = std.posix.read(fd, buf) catch return null;
    return buf[0..n];
}

fn realOwnTty(_: ?*anyopaque, buf: []u8) ?[]const u8 {
    const rc = linux.readlink("/proc/self/fd/0", buf.ptr, buf.len);
    const signed: isize = @bitCast(rc);
    if (signed <= 0) return null;
    return buf[0..rc];
}

fn realOpen(_: ?*anyopaque, path: []const u8) ?i32 {
    return sys.open(path, .{ .ACCMODE = .RDWR, .NOCTTY = true, .NOFOLLOW = true }) catch null;
}

fn realGetMode(_: ?*anyopaque, fd: i32) ?u32 {
    var mode: u32 = 0;
    if (linux.ioctl(fd, sys.KDGETMODE, @intFromPtr(&mode)) != 0) return null;
    return mode;
}

fn realSetMode(_: ?*anyopaque, fd: i32, mode: u32) bool {
    return linux.ioctl(fd, sys.KDSETMODE, mode) == 0;
}

fn realClose(_: ?*anyopaque, fd: i32) void {
    _ = linux.close(fd);
}

pub const real_host: Host = .{
    .activeVt = realActive,
    .ownTty = realOwnTty,
    .open = realOpen,
    .getMode = realGetMode,
    .setMode = realSetMode,
    .close = realClose,
};

// ---- Tests. They use a fake host: no test opens a real terminal. ----

const t = std.testing;

const Fake = struct {
    active: []const u8 = "tty3",
    own: ?[]const u8 = "/dev/tty3",
    mode: u32 = sys.KD_TEXT,
    opened: u32 = 0,
    closed: u32 = 0,
    sets: [8]u32 = undefined,
    set_count: usize = 0,
    last_path: [64]u8 = undefined,
    last_len: usize = 0,
    /// True: a change to graphics mode fails.
    refuse_graphics: bool = false,

    fn host(f: *Fake) Host {
        return .{ .ctx = f, .activeVt = fActive, .ownTty = fOwn, .open = fOpen, .getMode = fGet, .setMode = fSet, .close = fClose };
    }
    fn self(ctx: ?*anyopaque) *Fake {
        return @ptrCast(@alignCast(ctx.?));
    }
    fn fActive(ctx: ?*anyopaque, buf: []u8) ?[]const u8 {
        const f = self(ctx);
        @memcpy(buf[0..f.active.len], f.active);
        return buf[0..f.active.len];
    }
    fn fOwn(ctx: ?*anyopaque, buf: []u8) ?[]const u8 {
        const f = self(ctx);
        const o = f.own orelse return null;
        @memcpy(buf[0..o.len], o);
        return buf[0..o.len];
    }
    fn fOpen(ctx: ?*anyopaque, path: []const u8) ?i32 {
        const f = self(ctx);
        f.opened += 1;
        @memcpy(f.last_path[0..path.len], path);
        f.last_len = path.len;
        return 42;
    }
    fn fGet(ctx: ?*anyopaque, _: i32) ?u32 {
        return self(ctx).mode;
    }
    fn fSet(ctx: ?*anyopaque, fd: i32, mode: u32) bool {
        const f = self(ctx);
        std.debug.assert(fd == 42);
        if (mode == sys.KD_GRAPHICS and f.refuse_graphics) return false;
        f.sets[f.set_count] = mode;
        f.set_count += 1;
        f.mode = mode;
        return true;
    }
    fn fClose(ctx: ?*anyopaque, _: i32) void {
        self(ctx).closed += 1;
    }
};

test "console: a free VT that is active is accepted, and its name comes from the standard input" {
    var f: Fake = .{ .active = "tty7\n", .own = "/dev/tty7" };
    const h = f.host();
    var c: Console = .{ .host = &h };
    try c.prepare(.{}, null);
    try t.expectEqualStrings("/dev/tty7", f.last_path[0..f.last_len]);
    try t.expectEqual(@as(usize, 0), f.set_count);
    c.text();
    try t.expectEqual(@as(u32, 1), f.closed);
}

test "console: a display server in the environment stops the backend before any open" {
    var f: Fake = .{};
    const h = f.host();
    var c: Console = .{ .host = &h };
    try t.expectError(error.DisplayServerRunning, c.prepare(.{ .wayland_display = "wayland-1" }, null));
    try t.expectError(error.DisplayServerRunning, c.prepare(.{ .x_display = ":0" }, null));
    try t.expectError(error.DisplayServerRunning, c.prepare(.{ .session_type = "wayland" }, null));
    try t.expectError(error.DisplayServerRunning, c.prepare(.{ .session_type = "x11" }, null));
    try c.prepare(.{ .session_type = "tty", .wayland_display = "" }, null);
    c.text();
    // Only the last call opened the device.
    try t.expectEqual(@as(u32, 1), f.opened);
}

test "console: another active VT, no VT, and a console in graphics mode stop the backend" {
    var f: Fake = .{ .active = "tty2", .own = "/dev/tty3" };
    const h = f.host();
    var c: Console = .{ .host = &h };
    try t.expectError(error.NotActiveVt, c.prepare(.{}, null));
    f.active = "tty3";
    f.own = null;
    try t.expectError(error.NoVirtualTerminal, c.prepare(.{}, null));
    f.own = "/dev/pts/4";
    try t.expectError(error.NoVirtualTerminal, c.prepare(.{}, null));
    f.own = "/dev/tty";
    try t.expectError(error.NoVirtualTerminal, c.prepare(.{}, null));
    f.own = "/dev/tty0";
    try t.expectError(error.NoVirtualTerminal, c.prepare(.{}, null));
    f.own = "/dev/tty3";
    f.mode = sys.KD_GRAPHICS;
    try t.expectError(error.ConsoleInGraphicsMode, c.prepare(.{}, null));
    // The device that the failed call opened is closed again.
    try t.expectEqual(f.opened, f.closed);
    // An override names the VT of another terminal, and the active check still applies.
    f.mode = sys.KD_TEXT;
    f.own = null;
    try c.prepare(.{}, "/dev/tty3");
    c.text();
    try t.expectError(error.NotActiveVt, c.prepare(.{}, "/dev/tty5"));
}

test "console: text gives back the mode that the console had" {
    var f: Fake = .{ .mode = sys.KD_TEXT };
    const h = f.host();
    var c: Console = .{ .host = &h };
    try c.prepare(.{}, null);
    try c.graphics();
    try t.expectEqual(sys.KD_GRAPHICS, f.mode);
    c.text();
    try t.expectEqual(sys.KD_TEXT, f.mode);
    try t.expectEqual(@as(usize, 2), f.set_count);
    // A second call does nothing.
    c.text();
    try t.expectEqual(@as(usize, 2), f.set_count);
    restoreNow();
    try t.expectEqual(@as(usize, 2), f.set_count);
}

test "console: restoreNow works from a panic handler, and SIGTERM and SIGINT restore the console" {
    var f: Fake = .{};
    const h = f.host();
    var c: Console = .{ .host = &h };
    try c.prepare(.{}, null);
    try c.graphics();
    // The path of a panic or of the `exit` command.
    restoreNow();
    try t.expectEqual(sys.KD_TEXT, f.mode);
    c.text();
    // A real signal. The test turns off the end of the program.
    end_on_signal = false;
    defer end_on_signal = true;
    for ([_]linux.SIG{ .TERM, .INT, .HUP, .QUIT, .ABRT, .SEGV, .BUS, .FPE, .ILL, .USR1, .ALRM, .SYS }) |sig| {
        // A signal that the parent ignores stays ignored, and the console
        // gets no handler for it: a shell starts a background job with
        // SIGINT and SIGQUIT ignored, and a test runner can ignore SIGHUP.
        var cur: linux.Sigaction = undefined;
        _ = linux.sigaction(sig, null, &cur);
        if (cur.handler.handler == linux.SIG.IGN) continue;
        var f2: Fake = .{};
        const h2 = f2.host();
        var c2: Console = .{ .host = &h2 };
        try c2.prepare(.{}, null);
        try c2.graphics();
        try t.expectEqual(sys.KD_GRAPHICS, f2.mode);
        try std.posix.raise(sig);
        try t.expectEqual(sys.KD_TEXT, f2.mode);
        c2.text();
    }
}

test "console M-D: a failed KDSETMODE gives an error and leaves no handler" {
    var f: Fake = .{ .refuse_graphics = true };
    const h = f.host();
    var c: Console = .{ .host = &h };
    // A failed check must not leave a handler that points at this stack frame.
    defer c.text();
    try c.prepare(.{}, null);
    try t.expectError(error.CannotSetGraphicsMode, c.graphics());
    try t.expect(!c.active);
    try t.expect(!c.handlers);
    try t.expectEqual(@as(i32, -1), restore_fd.load(.acquire));
    var now: linux.Sigaction = undefined;
    _ = linux.sigaction(.TERM, null, &now);
    try t.expect(now.handler.handler != onSignal);
    c.text();
    try t.expectEqual(@as(usize, 0), f.set_count);
    try t.expectEqual(@as(u32, 1), f.closed);
}

test "console: --tty must be a /dev/tty<N> path" {
    var f: Fake = .{ .active = "tty3" };
    const h = f.host();
    var buf: [64]u8 = undefined;
    for ([_][]const u8{ "/dev/shm/tty3", "/tmp/tty3", "/dev/../dev/tty3", "/dev/tty3/", "/dev/tty+3", "/dev/tty 3", "/dev/tty", "/dev/tty0", "tty3" }) |bad| {
        try t.expectError(error.NoVirtualTerminal, check(.{}, &h, bad, &buf));
    }
    try t.expectEqualStrings("/dev/tty3", try check(.{}, &h, "/dev/tty3", &buf));
    try t.expectEqual(@as(u32, 0), f.opened);
}

test "console: a signal that the program ignores leaves the graphics mode" {
    var old: linux.Sigaction = undefined;
    const ignore: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.IGN }, .mask = linux.sigemptyset(), .flags = 0 };
    _ = linux.sigaction(.USR2, &ignore, &old);
    defer _ = linux.sigaction(.USR2, &old, null);
    var f: Fake = .{};
    const h = f.host();
    var c: Console = .{ .host = &h };
    defer c.text();
    try c.prepare(.{}, null);
    try c.graphics();
    try std.posix.raise(.USR2);
    try t.expectEqual(sys.KD_GRAPHICS, f.mode);
    var now: linux.Sigaction = undefined;
    _ = linux.sigaction(.USR2, null, &now);
    try t.expect(now.handler.handler == linux.SIG.IGN);
}

fn returningHandler(_: linux.SIG) callconv(.c) void {}

test "console: an old handler that returns ends the program in text mode" {
    const pid: i32 = @intCast(@as(isize, @bitCast(linux.fork())));
    if (pid == 0) {
        const own: linux.Sigaction = .{ .handler = .{ .handler = returningHandler }, .mask = linux.sigemptyset(), .flags = 0 };
        _ = linux.sigaction(.USR1, &own, null);
        var f: Fake = .{};
        const h = f.host();
        var c: Console = .{ .host = &h };
        c.prepare(.{}, null) catch linux.exit_group(2);
        c.graphics() catch linux.exit_group(3);
        // The handler ends the program. Reaching the next line is a failure.
        _ = linux.tkill(linux.gettid(), .USR1);
        linux.exit_group(4);
    }
    var raw: i32 = 0;
    _ = linux.waitpid(pid, &raw, 0);
    const status: u32 = @bitCast(raw);
    try t.expect(linux.W.IFEXITED(status));
    try t.expectEqual(@as(u8, 128 + 10), linux.W.EXITSTATUS(status));
}

test "console: text restores the mode before it removes the handlers" {
    const Order = struct {
        var handler_at_restore: ?linux.Sigaction.handler_fn = null;
        var inner: Fake = .{};
        fn set(ctx: ?*anyopaque, fd: i32, mode: u32) bool {
            if (mode == sys.KD_TEXT) {
                var now: linux.Sigaction = undefined;
                _ = linux.sigaction(.TERM, null, &now);
                handler_at_restore = now.handler.handler;
            }
            return Fake.fSet(ctx, fd, mode);
        }
    };
    Order.inner = .{};
    var h = Order.inner.host();
    h.setMode = Order.set;
    var c: Console = .{ .host = &h };
    try c.prepare(.{}, null);
    try c.graphics();
    c.text();
    try t.expect(Order.handler_at_restore == @as(?linux.Sigaction.handler_fn, onSignal));
}
