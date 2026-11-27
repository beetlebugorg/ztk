//! libztk: a shared library with the C API of Tcl 8.6 and the part of
//! the C API of Tk 8.6 that Python's `_tkinter` calls, so a program that
//! links libtcl8.6 and libtk8.6 runs its Tk on ztk with no change
//! (ztk#223).
//!
//! The library has ztcl and ztk in one shared object, `libtcl8.6.so`, so a
//! program gets one ztcl. It exports the Tcl functions with their names
//! and the Tk functions with the prefix `ztk_`. `libtk8.6.so`
//! (`src/libztk_tk.zig`) is a small library that links it and exports
//! the Tk names, so a program that links libztk records both libraries,
//! as with Tcl and Tk, and runs on either.
//!
//! The Tcl slots come from `ztcl.libtcl.exportAll`. The group `first`
//! of this file has the slots that need the loop of ztk: the timer and
//! file handlers, `Tcl_DoOneEvent`, the events of other threads, and
//! `Tcl_DeleteInterp`, which frees the App of the interp before the
//! interp. The group `last` has slots that ztcl does not have yet: a slot
//! of ztcl comes first when it exists.
//!
//! `Tk_Init` makes an App of ztk for the interp, with the backend of the
//! environment: the headless backend with `ZTK_HEADLESS=1`, Wayland with
//! `WAYLAND_DISPLAY`, else X11 with `DISPLAY`. The functions follow the
//! manual pages `Tk_Init.3`, `Tk_MainWin.3`, `DoOneEvent.3`,
//! `CrtTimerHdlr.3`, `CrtFileHdlr.3`, `Notifier.3`, `Thread.3`, and
//! `Tcl_GetBignumFromObj` of `IntObj.3`.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const ztcl = @import("ztcl");
const ztk = @import("ztk");
const lib = ztcl.libtcl;
const Shadow = lib.cext.Shadow;
const c = std.c;
const gpa = std.heap.c_allocator;

pub const std_options: std.Options = .{ .logFn = ztcl.vt.noLog };

/// The spare interp of the channel slots of ztcl, when ztcl has it.
pub fn spareInterp() ?*lib.obj.Interp {
    if (comptime @hasDecl(lib.app, "spare")) return lib.app.spare();
    return null;
}

comptime {
    lib.exportAll(.{first}, .{last});
    // The functions outside the stubs tables of Tcl.
    // The Tk functions have the prefix ztk_ here: libtk8.6 (src/libztk_tk.zig)
    // exports the names of Tk and jumps to them.
    for (tk_names) |nm| @export(&@field(first, nm), .{ .name = "ztk_" ++ nm });
    for (.{ "TclBN_mp_init", "TclBN_mp_clear", "TclBN_mp_read_radix", "TclBN_mp_unsigned_bin_size", "TclBN_mp_ubin_size", "TclBN_mp_to_unsigned_bin_n" }) |nm| {
        @export(&@field(first, nm), .{ .name = nm });
    }
}

/// The functions of Tk that libztk has. src/libztk_tk.zig has the same list.
pub const tk_names = .{ "Tk_Init", "Tk_MainWindow", "Tk_MainLoop", "Tk_CreateWindow", "Tk_GetNumMainWindows", "Tk_FindPhoto", "Tk_PhotoPutBlock", "Tk_PhotoPutZoomedBlock", "Tk_PhotoGetImage", "Tk_PhotoBlank", "Tk_PhotoGetSize", "Tk_PhotoSetSize", "Tk_PhotoExpand" };

const OK: c_int = 0;
const ERROR: c_int = 1;

// The flags of Tcl_DoOneEvent (DoOneEvent.3).
const DONT_WAIT: c_int = 1 << 1;
const WINDOW_EVENTS: c_int = 1 << 2;
const FILE_EVENTS: c_int = 1 << 3;
const TIMER_EVENTS: c_int = 1 << 4;
const IDLE_EVENTS: c_int = 1 << 5;

// The masks of Tcl_CreateFileHandler (CrtFileHdlr.3).
const READABLE: c_int = 1 << 1;
const WRITABLE: c_int = 1 << 2;
const EXCEPTION: c_int = 1 << 3;

extern fn clock_gettime(clk: c.clockid_t, tp: *c.timespec) callconv(.c) c_int;
extern fn fflush(f: ?*anyopaque) callconv(.c) c_int;
extern fn nanosleep(req: *const c.timespec, rem: ?*c.timespec) callconv(.c) c_int;
extern fn pthread_equal(a: c.pthread_t, b: c.pthread_t) callconv(.c) c_int;
extern fn Tcl_SetResult(ip: *Shadow, text: ?[*:0]const u8, free: ?*const anyopaque) callconv(.c) void;
extern fn Tcl_Free(p: ?*anyopaque) callconv(.c) void;
extern fn Tcl_NewStringObj(bytes: [*]const u8, len: c_int) callconv(.c) *anyopaque;
extern fn Tcl_GetStringFromObj(o: *anyopaque, len: ?*c_int) callconv(.c) [*:0]const u8;
extern fn Tcl_CreateObjCommand(ip: *Shadow, name: [*:0]const u8, proc: *const ObjProc, data: ?*anyopaque, del: ?*const DeleteProc) callconv(.c) ?*anyopaque;

const ObjProc = fn (?*anyopaque, *Shadow, c_int, [*]const *anyopaque) callconv(.c) c_int;
const StrProc = fn (?*anyopaque, *Shadow, c_int, [*]const [*:0]const u8) callconv(.c) c_int;
const DeleteProc = fn (?*anyopaque) callconv(.c) void;

/// A command of `Tcl_CreateCommand`: its string function, as an object
/// command whose words become strings.
const StrCmd = struct { proc: *const StrProc, data: ?*anyopaque, del: ?*const DeleteProc };

fn strCmdCall(cd: ?*anyopaque, ip: *Shadow, objc: c_int, objv: [*]const *anyopaque) callconv(.c) c_int {
    const sc: *StrCmd = @ptrCast(@alignCast(cd.?));
    const n: usize = @intCast(objc);
    var small: [16][*:0]const u8 = undefined;
    const argv: [][*:0]const u8 = if (n <= small.len) small[0..n] else gpa.alloc([*:0]const u8, n) catch return ERROR;
    defer if (n > small.len) gpa.free(argv);
    for (0..n) |i| argv[i] = Tcl_GetStringFromObj(objv[i], null);
    return sc.proc(sc.data, ip, objc, argv.ptr);
}

fn strCmdDelete(cd: ?*anyopaque) callconv(.c) void {
    const sc: *StrCmd = @ptrCast(@alignCast(cd.?));
    if (sc.del) |d| d(sc.data);
    gpa.destroy(sc);
}

/// Microseconds on the monotonic clock.
fn nowUs() i64 {
    var ts: c.timespec = undefined;
    _ = clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1_000_000 + @divFloor(@as(i64, ts.nsec), 1000);
}

// ---------------------------------------------------------------------
// The Apps

const Backend = union(enum) {
    headless: *ztk.headless.Headless,
    wayland: if (ztk.wayland_enabled) *ztk.wayland.Wayland else void,
    x11: if (ztk.wayland_enabled) *ztk.x11.X11 else void,

    fn deinit(b: Backend) void {
        switch (b) {
            .headless => |h| h.deinit(),
            .wayland => |w| if (ztk.wayland_enabled) w.deinit(),
            .x11 => |x| if (ztk.wayland_enabled) x.deinit(),
        }
    }
};

const Entry = struct {
    it: *ztcl.Interp,
    app: *ztk.App,
    backend: Backend,
    owner: c.pthread_t,
};

/// The Apps of `Tk_Init`. Each thread uses only its own entries.
var apps: std.ArrayListUnmanaged(Entry) = .empty;
var apps_lock: std.atomic.Mutex = .unlocked;

fn lockApps() void {
    while (!apps_lock.tryLock()) std.atomic.spinLoopHint();
}

fn appOf(it: *ztcl.Interp) ?*ztk.App {
    lockApps();
    defer apps_lock.unlock();
    for (apps.items) |e| if (e.it == it) return e.app;
    return null;
}

fn envStr(name: [*:0]const u8) ?[]const u8 {
    const v = c.getenv(name) orelse return null;
    return std.mem.span(v);
}

/// The `exit` command of ztk. It runs inside a callback of the interp,
/// so it does not delete the interps, as `Tcl_Exit` of libztcl does: it
/// flushes the standard channels of each interp with an App and of C,
/// and ends the process. The exit handlers do not run.
fn exitNow(code: u8) noreturn {
    lockApps();
    const list = apps.items;
    apps_lock.unlock();
    for (list) |e| _ = e.it.eval("foreach c {stdout stderr} {catch {flush $c}}") catch {};
    // `exit` of the C library hangs here when the command runs inside an
    // `update` of a loop of Python (the turtle demos), so the streams of
    // C are flushed and the process ends at once.
    _ = fflush(null);
    std.c._exit(code);
}

/// The class of "." from the name of the application: the name with
/// its first letter in upper case, as `Tk_Init.3` gives it from `argv0`.
fn classOf(buf: []u8, name: []const u8) []const u8 {
    const n = @min(buf.len, name.len);
    @memcpy(buf[0..n], name[0..n]);
    if (n > 0) buf[0] = std.ascii.toUpper(buf[0]);
    return buf[0..n];
}

fn fail(sh: *Shadow, msg: [*:0]const u8) c_int {
    Tcl_SetResult(sh, msg, null);
    return ERROR;
}

fn makeBackend() !Backend {
    if (envStr("ZTK_HEADLESS")) |v| if (std.mem.eql(u8, v, "1")) {
        // The clock of the process, so `after 300` waits 300 ms.
        const h = try ztk.headless.Headless.init(gpa);
        h.real_clock = true;
        return .{ .headless = h };
    };
    if (ztk.wayland_enabled) {
        if (envStr("WAYLAND_DISPLAY") != null) {
            return .{ .wayland = try ztk.wayland.Wayland.init(gpa, .{
                .runtime_dir = envStr("XDG_RUNTIME_DIR"),
                .display = envStr("WAYLAND_DISPLAY"),
                .bus_address = envStr("DBUS_SESSION_BUS_ADDRESS"),
                .renderer = if (envStr("ZTK_RENDERER")) |r| std.meta.stringToEnum(ztk.wayland.Renderer, r) orelse .auto else .auto,
            }) };
        }
        if (envStr("DISPLAY")) |d| {
            var auth_buf: [4096]u8 = undefined;
            const authority = envStr("XAUTHORITY") orelse if (envStr("HOME")) |h| std.fmt.bufPrint(&auth_buf, "{s}/.Xauthority", .{h}) catch null else null;
            return .{ .x11 = try ztk.x11.X11.init(gpa, .{ .display = d, .authority = authority }) };
        }
    }
    return error.NoDisplay;
}

fn platformOf(b: Backend) ztk.platform.Platform {
    return switch (b) {
        .headless => |h| h.platform(),
        .wayland => |w| if (ztk.wayland_enabled) w.platform() else unreachable,
        .x11 => |x| if (ztk.wayland_enabled) x.platform() else unreachable,
    };
}

/// The Io of the render threads and of the file reads of ztk, made at
/// the first `Tk_Init`.
var threaded: std.Io.Threaded = undefined;
var io_made = false;

fn hostIo() std.Io {
    lockApps();
    defer apps_lock.unlock();
    if (!io_made) {
        threaded = .init(gpa, .{});
        io_made = true;
    }
    return threaded.io();
}

fn tkInit(sh: *Shadow) c_int {
    const it = sh.it;
    if (appOf(it) != null) return OK;
    const backend = makeBackend() catch |e| switch (e) {
        error.NoDisplay => return fail(sh, "no display name and no $DISPLAY environment variable"),
        else => return fail(sh, "couldn't connect to display"),
    };
    // The name of the application is the tail of argv0, as in Tk_Init.3.
    var name: []const u8 = "tk";
    if (it.getVarQuiet("::argv0") catch null) |v| {
        const s = it.str(v) catch "tk";
        const tail = std.fs.path.basename(s);
        if (tail.len > 0) name = tail;
    }
    var cbuf: [128]u8 = undefined;
    const app = ztk.App.init(gpa, it, .{
        .platform = platformOf(backend),
        .root_class = classOf(&cbuf, name),
        .app_name = name,
        .on_exit = exitNow,
        .io = hostIo(),
        .render_mode = .threaded,
        .animations = envStr("ZTK_NO_ANIMATION") == null,
    }) catch {
        backend.deinit();
        return fail(sh, "ztk: cannot make the main window");
    };
    lockApps();
    apps.append(gpa, .{ .it = it, .app = app, .backend = backend, .owner = c.pthread_self() }) catch {
        apps_lock.unlock();
        app.deinit();
        backend.deinit();
        return fail(sh, "out of memory");
    };
    apps_lock.unlock();
    const vars = [_][2][]const u8{
        .{ "::tk_version", "8.6" },
        .{ "::tk_patchLevel", "8.6.16" },
        .{ "::tk_library", "" },
        .{ "::tk_strictMotif", "0" },
        // `tk windowingsystem` gives x11 on Linux, as Tk does there, so
        // a program that tests for x11, win32, or aqua takes its X11 path.
        .{ "::ztk::priv::windowingsystem", "x11" },
    };
    for (vars) |kv| it.setVar(kv[0], .{ .str = kv[1] }) catch {};
    // ZTK_SCRIPT=FILE sources FILE at the first idle time of the loop,
    // after the program made its windows, so a test drives a program
    // with no change to the program.
    if (envStr("ZTK_SCRIPT")) |file| {
        var vals = [_]ztcl.Value{ .{ .str = "after" }, .{ .str = "idle" }, .{ .str = "uplevel" }, .{ .str = "#0" }, .{ .str = "source" }, .{ .str = file } };
        if (ztcl.value.newList(it.alloc(), &vals)) |list| {
            if (it.str(list)) |text| {
                _ = it.eval(text) catch {};
            } else |_| {}
        } else |_| {}
    }
    return OK;
}

/// Sets `env(NAME)` for each variable of the environment of the process.
fn fillEnv(it: *ztcl.Interp) void {
    if ((it.getVarQuiet("::env(PATH)") catch null) != null) return;
    var p: [*:null]const ?[*:0]const u8 = @ptrCast(c.environ);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    while (p[0]) |entry| : (p += 1) {
        const e = std.mem.span(entry);
        const eq = std.mem.indexOfScalar(u8, e, '=') orelse continue;
        buf.clearRetainingCapacity();
        buf.print(gpa, "::env({s})", .{e[0..eq]}) catch return;
        const name = it.alloc().dupe(u8, buf.items) catch return;
        const value = it.alloc().dupe(u8, e[eq + 1 ..]) catch return;
        it.setVar(name, .{ .str = value }) catch {};
    }
}

/// Frees the App of `it`, if it has one.
fn dropApp(it: *ztcl.Interp) void {
    lockApps();
    var found: ?Entry = null;
    for (apps.items, 0..) |e, i| {
        if (e.it == it) {
            found = e;
            _ = apps.swapRemove(i);
            break;
        }
    }
    apps_lock.unlock();
    const e = found orelse return;
    e.app.render.flush();
    e.app.deinit();
    e.backend.deinit();
}

// ---------------------------------------------------------------------
// Timer and file handlers

const Proc = *const fn (?*anyopaque) callconv(.c) void;
const FileProc = *const fn (?*anyopaque, c_int) callconv(.c) void;

const Timer = struct { token: usize, due: i64, proc: Proc, data: ?*anyopaque };
const File = struct { fd: c_int, mask: c_int, proc: FileProc, data: ?*anyopaque };

/// The handlers of one thread. A notifier of Tcl is for each thread.
const Notifier = struct {
    timers: std.ArrayListUnmanaged(Timer) = .empty,
    files: std.ArrayListUnmanaged(File) = .empty,
    next_token: usize = 1,
};

threadlocal var notifier: Notifier = .{};

/// Runs the first timer that is due. Gives true when one ran.
fn runTimer() bool {
    const n = &notifier;
    if (n.timers.items.len == 0) return false;
    const now = nowUs();
    var best: ?usize = null;
    for (n.timers.items, 0..) |t, i| {
        if (t.due <= now and (best == null or t.due < n.timers.items[best.?].due)) best = i;
    }
    const i = best orelse return false;
    const t = n.timers.orderedRemove(i);
    t.proc(t.data);
    return true;
}

fn nextTimerUs() ?i64 {
    var best: ?i64 = null;
    for (notifier.timers.items) |t| best = if (best) |b| @min(b, t.due) else t.due;
    const b = best orelse return null;
    return @max(0, b - nowUs());
}

/// Polls the file handlers with `timeout_ms` and runs the handler of
/// the first ready file. Gives true when one ran.
fn runFiles(timeout_ms: c_int) bool {
    const n = &notifier;
    const count = n.files.items.len;
    if (count == 0) return false;
    var fds: [64]c.pollfd = undefined;
    const m = @min(count, fds.len);
    for (n.files.items[0..m], fds[0..m]) |f, *p| {
        var ev: i16 = 0;
        if (f.mask & READABLE != 0) ev |= c.POLL.IN;
        if (f.mask & WRITABLE != 0) ev |= c.POLL.OUT;
        if (f.mask & EXCEPTION != 0) ev |= c.POLL.PRI;
        p.* = .{ .fd = f.fd, .events = ev, .revents = 0 };
    }
    if (c.poll(&fds, @intCast(m), timeout_ms) <= 0) return false;
    for (fds[0..m]) |p| {
        if (p.revents == 0) continue;
        var ready: c_int = 0;
        if (p.revents & (c.POLL.IN | c.POLL.HUP | c.POLL.ERR) != 0) ready |= READABLE;
        if (p.revents & c.POLL.OUT != 0) ready |= WRITABLE;
        if (p.revents & c.POLL.PRI != 0) ready |= EXCEPTION;
        for (n.files.items) |f| {
            if (f.fd != p.fd) continue;
            const r = ready & f.mask;
            if (r != 0) {
                f.proc(f.data, r);
                return true;
            }
        }
    }
    return false;
}

// ---------------------------------------------------------------------
// The events of other threads (Notifier.3)

const Event = extern struct {
    proc: ?*const fn (*Event, c_int) callconv(.c) c_int,
    next: ?*Event,
};

const Queued = struct { owner: c.pthread_t, ev: *Event };

var queue: std.ArrayListUnmanaged(Queued) = .empty;
var queue_lock: std.atomic.Mutex = .unlocked;
/// True after the first queued event: a wait then ends after 20 ms to
/// look at the queue, because the backends have no wake from a thread.
var queue_used = std.atomic.Value(bool).init(false);

fn lockQueue() void {
    while (!queue_lock.tryLock()) std.atomic.spinLoopHint();
}

/// Runs the first queued event of this thread. Gives true when one ran.
fn runQueued(flags: c_int) bool {
    if (!queue_used.load(.acquire)) return false;
    const me = c.pthread_self();
    lockQueue();
    var ev: ?*Event = null;
    for (queue.items, 0..) |q, i| {
        if (pthread_equal(q.owner, me) != 0) {
            ev = q.ev;
            _ = queue.orderedRemove(i);
            break;
        }
    }
    queue_lock.unlock();
    const e = ev orelse return false;
    const proc = e.proc orelse {
        Tcl_Free(e);
        return true;
    };
    // A proc that gives 0 keeps its event: it goes back at the head.
    if (proc(e, flags) != 0) {
        Tcl_Free(e);
    } else {
        lockQueue();
        queue.insert(gpa, 0, .{ .owner = me, .ev = e }) catch {};
        queue_lock.unlock();
        return false;
    }
    return true;
}

// ---------------------------------------------------------------------
// Tcl_DoOneEvent

fn myApps(buf: []*ztk.App) []*ztk.App {
    const me = c.pthread_self();
    lockApps();
    defer apps_lock.unlock();
    var n: usize = 0;
    for (apps.items) |e| {
        if (n == buf.len) break;
        if (pthread_equal(e.owner, me) != 0) {
            buf[n] = e.app;
            n += 1;
        }
    }
    return buf[0..n];
}

fn appPass(app: *ztk.App) bool {
    return app.doOneEvent(false) catch |e| {
        app.backgroundError(e);
        return true;
    };
}

fn doOneEvent(flags_in: c_int) c_int {
    var flags = flags_in;
    if (flags & (WINDOW_EVENTS | FILE_EVENTS | TIMER_EVENTS | IDLE_EVENTS) == 0) flags |= WINDOW_EVENTS | FILE_EVENTS | TIMER_EVENTS | IDLE_EVENTS;
    var abuf: [16]*ztk.App = undefined;
    while (true) {
        if (runQueued(flags)) return 1;
        if (flags & TIMER_EVENTS != 0 and runTimer()) return 1;
        if (flags & FILE_EVENTS != 0 and runFiles(0)) return 1;
        const mine = myApps(&abuf);
        if (flags & (WINDOW_EVENTS | TIMER_EVENTS | IDLE_EVENTS) != 0) {
            for (mine) |app| if (appPass(app)) return 1;
        }
        if (flags & DONT_WAIT != 0) return 0;
        // The wait: until the next timer of the handlers or of an App, or
        // an event of a backend. A file handler or a queue of events of
        // other threads limits the wait to 20 ms.
        var timeout: ?i64 = nextTimerUs();
        var live = false;
        for (mine) |app| {
            if (app.loop.nextTimeoutUs()) |t| timeout = if (timeout) |x| @min(x, t) else t;
            if (app.platform.live) live = true;
        }
        if (notifier.files.items.len > 0 or queue_used.load(.acquire)) timeout = @min(timeout orelse 20_000, 20_000);
        if (mine.len > 0 and ztcl.event.hasWatches(mine[0].it)) timeout = @min(timeout orelse 5000, 5000);
        if (live) {
            mine[0].platform.wait(timeout);
        } else if (notifier.files.items.len > 0) {
            const ms: c_int = if (timeout) |t| @intCast(@min(@divFloor(t + 999, 1000), 20)) else 20;
            if (flags & FILE_EVENTS != 0 and runFiles(ms)) return 1;
        } else {
            // No source of events can end the wait: Tcl blocks for ever,
            // and this sleeps in steps of 100 ms.
            const us: i64 = timeout orelse 100_000;
            var ts: c.timespec = .{ .sec = @intCast(@divFloor(us, 1_000_000)), .nsec = @intCast(@mod(us, 1_000_000) * 1000) };
            _ = nanosleep(&ts, null);
        }
    }
}

// ---------------------------------------------------------------------
// Threads, for a ztcl with no thread slots (Thread.3)

const Time = extern struct { sec: c_long, usec: c_long };

var init_lock: c.pthread_mutex_t = c.PTHREAD_MUTEX_INITIALIZER;

fn mutexOf(m: *?*anyopaque) *c.pthread_mutex_t {
    if (@atomicLoad(?*anyopaque, m, .acquire)) |p| return @ptrCast(@alignCast(p));
    _ = c.pthread_mutex_lock(&init_lock);
    defer _ = c.pthread_mutex_unlock(&init_lock);
    if (m.*) |p| return @ptrCast(@alignCast(p));
    const p = gpa.create(c.pthread_mutex_t) catch @panic("out of memory");
    p.* = c.PTHREAD_MUTEX_INITIALIZER;
    @atomicStore(?*anyopaque, m, p, .release);
    return p;
}

fn condOf(cv: *?*anyopaque) *c.pthread_cond_t {
    if (@atomicLoad(?*anyopaque, cv, .acquire)) |p| return @ptrCast(@alignCast(p));
    _ = c.pthread_mutex_lock(&init_lock);
    defer _ = c.pthread_mutex_unlock(&init_lock);
    if (cv.*) |p| return @ptrCast(@alignCast(p));
    const p = gpa.create(c.pthread_cond_t) catch @panic("out of memory");
    p.* = c.PTHREAD_COND_INITIALIZER;
    @atomicStore(?*anyopaque, cv, p, .release);
    return p;
}

// ---------------------------------------------------------------------
// Bignums: the `mp_int` of tclTomMath.h. The digits here are 64-bit
// limbs of the magnitude, lowest first, in memory of the C heap.

const MpInt = extern struct { used: c_int, alloc: c_int, sign: c_int, dp: ?[*]u64 };
const MP_NEG: c_int = 1;
const MP_VAL: c_int = -3;
const MP_MEM: c_int = -2;

fn mpSet(a: *MpInt, m: std.math.big.int.Const) c_int {
    if (a.dp) |p| c.free(p);
    a.* = .{ .used = 0, .alloc = 0, .sign = 0, .dp = null };
    var n = m.limbs.len;
    while (n > 0 and m.limbs[n - 1] == 0) n -= 1;
    if (n == 0) return OK;
    const p: [*]u64 = @ptrCast(@alignCast(c.malloc(n * 8) orelse return MP_MEM));
    for (0..n) |i| p[i] = m.limbs[i];
    a.* = .{ .used = @intCast(n), .alloc = @intCast(n), .sign = if (m.positive) 0 else MP_NEG, .dp = p };
    return OK;
}

fn mpConst(a: *const MpInt) std.math.big.int.Const {
    if (a.used == 0 or a.dp == null) return .{ .limbs = &.{0}, .positive = true };
    const limbs: []const usize = @ptrCast(a.dp.?[0..@intCast(a.used)]);
    return .{ .limbs = limbs, .positive = a.sign != MP_NEG };
}

fn mpParse(a: *MpInt, text: []const u8, radix: u8) c_int {
    var s = text;
    var neg = false;
    if (s.len > 0 and (s[0] == '-' or s[0] == '+')) {
        neg = s[0] == '-';
        s = s[1..];
    }
    if (s.len == 0) return MP_VAL;
    var m = std.math.big.int.Managed.init(gpa) catch return MP_MEM;
    defer m.deinit();
    m.setString(radix, s) catch return MP_VAL;
    if (neg) m.negate();
    return mpSet(a, m.toConst());
}

fn mpBytes(a: *const MpInt) usize {
    const k = mpConst(a);
    if (k.eqlZero()) return 0;
    return (k.bitCountAbs() + 7) / 8;
}

// ---------------------------------------------------------------------
// Photos (FindPhoto.3)

const image = ztk.image;

/// `Tk_PhotoImageBlock` of FindPhoto.3.
const PhotoBlock = extern struct {
    pixels: ?[*]u8,
    width: c_int,
    height: c_int,
    pitch: c_int,
    pixel_size: c_int,
    offset: [4]c_int,
};

// The composite rules of Tk_PhotoPutBlock.
const COMPOSITE_OVERLAY: c_int = 0;

/// The App that has photo `p`.
fn appOfPhoto(p: *image.Photo) ?*ztk.App {
    lockApps();
    defer apps_lock.unlock();
    for (apps.items) |e| {
        for (e.app.images.list.items) |q| if (q == p) return e.app;
    }
    return null;
}

fn photoOf(h: ?*anyopaque) ?*image.Photo {
    return @ptrCast(@alignCast(h orelse return null));
}

fn putBlock(sh: ?*Shadow, h: ?*anyopaque, b: *const PhotoBlock, x: c_int, y: c_int, w: c_int, hh: c_int, rule: c_int) c_int {
    const p = photoOf(h) orelse return ERROR;
    const app = appOfPhoto(p) orelse return ERROR;
    const px = b.pixels orelse return OK;
    image.putBlock(app, p, .{ .pixels = px, .width = b.width, .height = b.height, .pitch = b.pitch, .pixel_size = b.pixel_size, .offset = b.offset }, x, y, w, hh, rule == COMPOSITE_OVERLAY) catch {
        if (sh) |ip| Tcl_SetResult(ip, "not enough free memory for image buffer", null);
        return ERROR;
    };
    return OK;
}

// ---------------------------------------------------------------------
// The exported groups

/// The slots that come before the slots of ztcl.
const first = struct {
    pub fn Tk_Init(sh: *Shadow) callconv(.c) c_int {
        return tkInit(sh);
    }

    /// The token of ".", or null when the interp has no main window.
    pub fn Tk_MainWindow(sh: *Shadow) callconv(.c) ?*anyopaque {
        const app = appOf(sh.it) orelse {
            Tcl_SetResult(sh, "this isn't a Tk application", null);
            return null;
        };
        const r = app.root orelse {
            Tcl_SetResult(sh, "this isn't a Tk application", null);
            return null;
        };
        return @ptrCast(r);
    }

    /// A new window (CrtWindow.3). With no parent, the token of the main
    /// window of the interp, which `Tk_Init` made. Else a frame, or a
    /// toplevel when `screen` is not null, named `name` in `parent`.
    pub fn Tk_CreateWindow(sh: *Shadow, parent: ?*anyopaque, name: [*:0]const u8, screen: ?[*:0]const u8) callconv(.c) ?*anyopaque {
        const app = appOf(sh.it) orelse return Tk_MainWindow(sh);
        const pw: *ztk.widget.Widget = @ptrCast(@alignCast(parent orelse return Tk_MainWindow(sh)));
        var buf: [1024]u8 = undefined;
        const sep: []const u8 = if (std.mem.eql(u8, pw.path, ".")) "" else ".";
        const path = std.fmt.bufPrint(&buf, "{s}{s}{s}", .{ pw.path, sep, std.mem.span(name) }) catch return null;
        const cmd: []const u8 = if (screen != null) "toplevel" else "frame";
        var vals = [_]ztcl.Value{ .{ .str = cmd }, .{ .str = path } };
        const list = ztcl.value.newList(sh.it.alloc(), &vals) catch return null;
        const text = sh.it.str(list) catch return null;
        _ = sh.it.eval(text) catch {
            Tcl_SetResult(sh, "can't create window", null);
            return null;
        };
        return @ptrCast(app.find(path) orelse return null);
    }

    /// Runs events until no main window is left (MainLoop.3).
    pub fn Tk_MainLoop() callconv(.c) void {
        while (Tk_GetNumMainWindows() > 0) _ = doOneEvent(0);
    }

    /// The count of the main windows of the thread that are not deleted.
    pub fn Tk_GetNumMainWindows() callconv(.c) c_int {
        var abuf: [16]*ztk.App = undefined;
        var n: c_int = 0;
        for (myApps(&abuf)) |app| {
            if (app.root != null) n += 1;
        }
        return n;
    }

    pub fn Tk_FindPhoto(sh: *Shadow, name: [*:0]const u8) callconv(.c) ?*anyopaque {
        const app = appOf(sh.it) orelse return null;
        const p = app.images.find(std.mem.span(name)) orelse return null;
        if (p.bitmap != null) return null;
        return @ptrCast(p);
    }

    pub fn Tk_PhotoPutBlock(sh: ?*Shadow, h: ?*anyopaque, b: *const PhotoBlock, x: c_int, y: c_int, w: c_int, hh: c_int, rule: c_int) callconv(.c) c_int {
        return putBlock(sh, h, b, x, y, w, hh, rule);
    }

    /// The zoom and the subsample are 1 here: a block is put as it is.
    pub fn Tk_PhotoPutZoomedBlock(sh: ?*Shadow, h: ?*anyopaque, b: *const PhotoBlock, x: c_int, y: c_int, w: c_int, hh: c_int, _: c_int, _: c_int, _: c_int, _: c_int, rule: c_int) callconv(.c) c_int {
        return putBlock(sh, h, b, x, y, w, hh, rule);
    }

    /// The pixels of the photo, RGBA, valid until the next change.
    pub fn Tk_PhotoGetImage(h: ?*anyopaque, b: *PhotoBlock) callconv(.c) c_int {
        const p = photoOf(h) orelse return 0;
        b.* = .{ .pixels = if (p.pixels.len > 0) p.pixels.ptr else null, .width = @intCast(p.width), .height = @intCast(p.height), .pitch = @intCast(p.width * 4), .pixel_size = 4, .offset = .{ 0, 1, 2, 3 } };
        return 1;
    }

    pub fn Tk_PhotoBlank(h: ?*anyopaque) callconv(.c) void {
        const p = photoOf(h) orelse return;
        const app = appOfPhoto(p) orelse return;
        image.blank(app, p);
    }

    pub fn Tk_PhotoGetSize(h: ?*anyopaque, w: *c_int, hh: *c_int) callconv(.c) void {
        const p = photoOf(h) orelse return;
        w.* = @intCast(p.width);
        hh.* = @intCast(p.height);
    }

    pub fn Tk_PhotoSetSize(sh: ?*Shadow, h: ?*anyopaque, w: c_int, hh: c_int) callconv(.c) c_int {
        const p = photoOf(h) orelse return ERROR;
        const app = appOfPhoto(p) orelse return ERROR;
        image.setSize(app, p, @intCast(@max(w, 0)), @intCast(@max(hh, 0))) catch {
            if (sh) |ip| Tcl_SetResult(ip, "not enough free memory for image buffer", null);
            return ERROR;
        };
        return OK;
    }

    pub fn Tk_PhotoExpand(sh: ?*Shadow, h: ?*anyopaque, w: c_int, hh: c_int) callconv(.c) c_int {
        const p = photoOf(h) orelse return ERROR;
        const app = appOfPhoto(p) orelse return ERROR;
        image.expand(app, p, @intCast(@max(w, 0)), @intCast(@max(hh, 0))) catch {
            if (sh) |ip| Tcl_SetResult(ip, "not enough free memory for image buffer", null);
            return ERROR;
        };
        return OK;
    }

    /// The interp of ztcl, with the global array `env` of the
    /// environment of the process, as in Tcl (tclvars.n). The interp of
    /// libztcl has no `env` array yet.
    pub fn Tcl_CreateInterp() callconv(.c) ?*Shadow {
        const sh = lib.app.slots.Tcl_CreateInterp() orelse return null;
        fillEnv(sh.it);
        return sh;
    }

    pub fn Tcl_DeleteInterp(sh: *Shadow) callconv(.c) void {
        dropApp(sh.it);
        lib.app.slots.Tcl_DeleteInterp(sh);
    }

    pub fn Tcl_DoOneEvent(flags: c_int) callconv(.c) c_int {
        return doOneEvent(flags);
    }

    pub fn Tcl_CreateTimerHandler(ms: c_int, proc: Proc, data: ?*anyopaque) callconv(.c) ?*anyopaque {
        const n = &notifier;
        const token = n.next_token;
        n.next_token += 1;
        n.timers.append(gpa, .{ .token = token, .due = nowUs() + @as(i64, @max(ms, 0)) * 1000, .proc = proc, .data = data }) catch return null;
        return @ptrFromInt(token);
    }

    pub fn Tcl_DeleteTimerHandler(token: ?*anyopaque) callconv(.c) void {
        const n = &notifier;
        const t = @intFromPtr(token);
        for (n.timers.items, 0..) |x, i| {
            if (x.token == t) {
                _ = n.timers.orderedRemove(i);
                return;
            }
        }
    }

    pub fn Tcl_CreateFileHandler(fd: c_int, mask: c_int, proc: FileProc, data: ?*anyopaque) callconv(.c) void {
        const n = &notifier;
        for (n.files.items) |*f| {
            if (f.fd == fd) {
                f.* = .{ .fd = fd, .mask = mask, .proc = proc, .data = data };
                return;
            }
        }
        n.files.append(gpa, .{ .fd = fd, .mask = mask, .proc = proc, .data = data }) catch {};
    }

    pub fn Tcl_DeleteFileHandler(fd: c_int) callconv(.c) void {
        const n = &notifier;
        for (n.files.items, 0..) |f, i| {
            if (f.fd == fd) {
                _ = n.files.orderedRemove(i);
                return;
            }
        }
    }

    pub fn Tcl_ThreadQueueEvent(owner: ?*anyopaque, ev: *Event, position: c_int) callconv(.c) void {
        const t: c.pthread_t = @ptrCast(@alignCast(owner));
        lockQueue();
        defer queue_lock.unlock();
        // TCL_QUEUE_HEAD is 1. TCL_QUEUE_TAIL (0) and TCL_QUEUE_MARK (2)
        // go at the tail.
        if (position == 1) {
            queue.insert(gpa, 0, .{ .owner = t, .ev = ev }) catch return;
        } else {
            queue.append(gpa, .{ .owner = t, .ev = ev }) catch return;
        }
        queue_used.store(true, .release);
    }

    pub fn Tcl_ThreadAlert(_: ?*anyopaque) callconv(.c) void {}

    pub fn Tcl_QueueEvent(ev: *Event, position: c_int) callconv(.c) void {
        Tcl_ThreadQueueEvent(@ptrCast(c.pthread_self()), ev, position);
    }

    pub fn Tcl_NewBignumObj(a: *MpInt) callconv(.c) *anyopaque {
        const text = mpConst(a).toStringAlloc(gpa, 10, .lower) catch @panic("out of memory");
        defer gpa.free(text);
        TclBN_mp_clear(a);
        return Tcl_NewStringObj(text.ptr, @intCast(text.len));
    }

    pub fn Tcl_GetBignumFromObj(sh: ?*Shadow, o: *anyopaque, a: *MpInt) callconv(.c) c_int {
        var len: c_int = 0;
        const s = Tcl_GetStringFromObj(o, &len);
        const text = std.mem.trim(u8, s[0..@intCast(len)], " \t\n");
        a.* = .{ .used = 0, .alloc = 0, .sign = 0, .dp = null };
        var radix: u8 = 10;
        var digits = text;
        var sign: []const u8 = "";
        if (digits.len > 0 and (digits[0] == '-' or digits[0] == '+')) {
            sign = digits[0..1];
            digits = digits[1..];
        }
        if (digits.len > 2 and digits[0] == '0') switch (digits[1]) {
            'x', 'X' => radix = 16,
            'o', 'O' => radix = 8,
            'b', 'B' => radix = 2,
            else => {},
        };
        if (radix != 10) digits = digits[2..];
        var buf: [4096]u8 = undefined;
        const joined = std.fmt.bufPrint(&buf, "{s}{s}", .{ sign, digits }) catch "";
        if (mpParse(a, joined, radix) == OK) return OK;
        if (sh) |ip| {
            var mbuf: [200]u8 = undefined;
            const msg = std.fmt.bufPrintSentinel(&mbuf, "expected integer but got \"{s}\"", .{text[0..@min(text.len, 100)]}, 0) catch "expected integer";
            Tcl_SetResult(ip, msg, @ptrFromInt(1));
        }
        return ERROR;
    }

    // The bignum functions of the tommath stubs table.
    pub fn TclBN_mp_init(a: *MpInt) callconv(.c) c_int {
        a.* = .{ .used = 0, .alloc = 0, .sign = 0, .dp = null };
        return OK;
    }

    pub fn TclBN_mp_clear(a: *MpInt) callconv(.c) void {
        if (a.dp) |p| c.free(p);
        a.* = .{ .used = 0, .alloc = 0, .sign = 0, .dp = null };
    }

    pub fn TclBN_mp_read_radix(a: *MpInt, s: [*:0]const u8, radix: c_int) callconv(.c) c_int {
        if (radix < 2 or radix > 36) return MP_VAL;
        return mpParse(a, std.mem.span(s), @intCast(radix));
    }

    pub fn TclBN_mp_unsigned_bin_size(a: *const MpInt) callconv(.c) c_int {
        return @intCast(mpBytes(a));
    }

    pub fn TclBN_mp_ubin_size(a: *const MpInt) callconv(.c) usize {
        return mpBytes(a);
    }

    /// The magnitude in big-endian bytes.
    pub fn TclBN_mp_to_unsigned_bin_n(a: *const MpInt, b: [*]u8, outlen: *c_ulong) callconv(.c) c_int {
        const n = mpBytes(a);
        if (outlen.* < n) return MP_VAL;
        const limbs = mpConst(a).limbs;
        for (0..n) |i| {
            const limb = limbs[i / 8];
            b[n - 1 - i] = @truncate(limb >> @intCast((i % 8) * 8));
        }
        outlen.* = n;
        return OK;
    }
};

/// The slots that come after the slots of ztcl: a slot of ztcl with the
/// same name is used when it exists.
const last = struct {
    /// CrtCommand.3, over an object command, for a ztcl with no slot of
    /// its own. Pillow's ImageTk makes its command with it.
    pub fn Tcl_CreateCommand(ip: *Shadow, name: [*:0]const u8, proc: *const StrProc, data: ?*anyopaque, del: ?*const DeleteProc) callconv(.c) ?*anyopaque {
        const sc = gpa.create(StrCmd) catch return null;
        sc.* = .{ .proc = proc, .data = data, .del = del };
        return Tcl_CreateObjCommand(ip, name, &strCmdCall, sc, &strCmdDelete);
    }

    pub fn Tcl_GetCurrentThread() callconv(.c) ?*anyopaque {
        return @ptrCast(c.pthread_self());
    }

    pub fn Tcl_MutexLock(m: *?*anyopaque) callconv(.c) void {
        _ = c.pthread_mutex_lock(mutexOf(m));
    }

    pub fn Tcl_MutexUnlock(m: *?*anyopaque) callconv(.c) void {
        _ = c.pthread_mutex_unlock(mutexOf(m));
    }

    pub fn Tcl_MutexFinalize(m: *?*anyopaque) callconv(.c) void {
        if (m.*) |p| {
            gpa.destroy(@as(*c.pthread_mutex_t, @ptrCast(@alignCast(p))));
            m.* = null;
        }
    }

    pub fn Tcl_ConditionWait(cv: *?*anyopaque, m: *?*anyopaque, t: ?*const Time) callconv(.c) void {
        const cond = condOf(cv);
        const mx = mutexOf(m);
        if (t) |tm| {
            var ts: c.timespec = undefined;
            _ = clock_gettime(.REALTIME, &ts);
            const ns = @as(i64, ts.nsec) + @as(i64, tm.usec) * 1000;
            const abs: c.timespec = .{ .sec = ts.sec + tm.sec + @as(@TypeOf(ts.sec), @intCast(@divFloor(ns, 1_000_000_000))), .nsec = @intCast(@mod(ns, 1_000_000_000)) };
            _ = c.pthread_cond_timedwait(cond, mx, &abs);
        } else {
            _ = c.pthread_cond_wait(cond, mx);
        }
    }

    pub fn Tcl_ConditionNotify(cv: *?*anyopaque) callconv(.c) void {
        _ = c.pthread_cond_broadcast(condOf(cv));
    }

    pub fn Tcl_ConditionFinalize(cv: *?*anyopaque) callconv(.c) void {
        if (cv.*) |p| {
            gpa.destroy(@as(*c.pthread_cond_t, @ptrCast(@alignCast(p))));
            cv.* = null;
        }
    }

    /// A block of `size` bytes for each thread and key, zero at first.
    pub fn Tcl_GetThreadData(key: *?*anyopaque, size: c_int) callconv(.c) ?*anyopaque {
        var k: *c.pthread_key_t = undefined;
        if (@atomicLoad(?*anyopaque, key, .acquire)) |p| {
            k = @ptrCast(@alignCast(p));
        } else {
            _ = c.pthread_mutex_lock(&init_lock);
            if (key.*) |p| {
                k = @ptrCast(@alignCast(p));
            } else {
                k = gpa.create(c.pthread_key_t) catch @panic("out of memory");
                _ = c.pthread_key_create(k, null);
                @atomicStore(?*anyopaque, key, k, .release);
            }
            _ = c.pthread_mutex_unlock(&init_lock);
        }
        if (c.pthread_getspecific(k.*)) |p| return p;
        const p = c.calloc(1, @intCast(@max(size, 1)));
        _ = c.pthread_setspecific(k.*, p);
        return p;
    }
};
