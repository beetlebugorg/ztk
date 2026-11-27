//! The Wayland backend. It connects to the compositor of WAYLAND_DISPLAY
//! with its own client of the wire protocol (`wl/wire.zig`), so it links
//! no library and runs in a static program. It makes one xdg toplevel and
//! turns the events of the compositor into `Event` values. The pointer,
//! the keyboard (with the key map of the compositor, read by `wl/xkb.zig`),
//! the close request, the fractional scale, the focus, the clipboard, and
//! the text of an input method all become events. The CPU renderer draws
//! into a `wl_shm` buffer. The buffer has the scene size in device
//! pixels, and the scale goes to the compositor through `wp_viewporter`
//! (fractional scale) or `wl_surface.set_buffer_scale`. A draw reports
//! only the rows that changed as damage, and a draw with no changed row
//! commits no buffer. Key repeat runs inside the backend: `wait` and
//! `poll` use the time of the next repeat.
//!
//! The pointer has its own event queue and an input thread that reads
//! it, so the pointer positions reach the render thread while the UI
//! thread is busy (a drag that the render thread moves). The input
//! thread puts the pointer events in the same list as the other events,
//! under a lock. Each thread that reads the socket wakes the other one
//! through a pipe, because the events that one thread reads can belong to
//! the queue of the other.
//!
//! A window with `WindowOptions.popup` is an `xdg_popup` (`Pop`). An
//! `xdg_positioner` places the box of the popup: the window geometry of
//! the popup leaves out the margin of the shadow. The compositor flips
//! and slides the box, and the configure of the popup gives its place in
//! the window geometry of the parent, which the backend turns into
//! `Window.pos`. A popup with a grab uses the serial of the last press.
//! The pointer events go to the window of the surface under the pointer.
//! The keys stay on the main window, and the core gives them to the
//! posted menu. The surface of a popup has premultiplied alpha
//! (ARGB8888) and its own copy of the atlas.
//!
//! The requests and events come from the protocol XML files: wayland.xml,
//! xdg-shell, xdg-decoration, viewporter, fractional-scale, cursor-shape,
//! and text-input-unstable-v3 (docs/references/wayland.md).
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const linux = std.os.linux;
const geom = @import("../geom.zig");
const event = @import("../event.zig");
const plat = @import("platform.zig");
const wire = @import("wl/wire.zig");
const xkb = @import("wl/xkb.zig");
const host = @import("../sys/host.zig");
const Event = event.Event;
const Mods = event.Mods;
const Window = plat.Window;
const Platform = plat.Platform;
const Frame = @import("../scene.zig").Frame;
const Target = @import("../render/thread.zig").Target;
const Atlas = @import("../text/atlas.zig").Atlas;
const cpu = @import("../render/cpu.zig");
const Image = @import("../render/renderer.zig").Image;
const renderer = @import("../render/renderer.zig");

/// The interface numbers of the objects, for the dispatch of their events.
const I = struct {
    const registry: u16 = 1;
    const sync_cb: u16 = 2;
    const compositor: u16 = 3;
    const shm: u16 = 4;
    const shm_pool: u16 = 5;
    const buffer: u16 = 6;
    const surface: u16 = 7;
    const seat: u16 = 8;
    const pointer: u16 = 9;
    const keyboard: u16 = 10;
    const wm_base: u16 = 11;
    const positioner: u16 = 12;
    const xdg_surface: u16 = 13;
    const toplevel: u16 = 14;
    const popup: u16 = 15;
    const viewporter: u16 = 16;
    const viewport: u16 = 17;
    const frac_mgr: u16 = 18;
    const frac: u16 = 19;
    const deco_mgr: u16 = 20;
    const deco: u16 = 21;
    const cursor_mgr: u16 = 22;
    const cursor_dev: u16 = 23;
    const frame_cb: u16 = 24;
    const data_mgr: u16 = 25;
    const data_device: u16 = 26;
    const data_offer: u16 = 27;
    const data_source: u16 = 28;
    const ti_mgr: u16 = 29;
    const text_input: u16 = 30;
};

const shm_argb8888: u32 = 0;
const shm_xrgb8888: u32 = 1;

/// The MIME types of UTF-8 text on the clipboard, best first.
const text_types = [_][]const u8{ "text/plain;charset=utf-8", "UTF8_STRING", "text/plain", "STRING", "TEXT" };

const Buf = struct {
    buffer: u32 = 0,
    data: []align(4096) u8 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    busy: bool = false,
    owner: *Wayland,
};

/// One popup surface.
const Pop = struct {
    owner: *Wayland,
    win: *Window,
    surface: u32,
    xdg_surface: u32,
    popup: u32,
    viewport: u32 = 0,
    /// The margin of the surface around the window geometry, and the margin of the parent.
    margin: geom.Insets,
    parent_margin: geom.Insets,
    configured: bool = false,
    frame_cb: u32 = 0,
    bufs: [3]?*Buf = .{ null, null, null },
    atlas: Atlas,
};

/// An offer of data from another client: its MIME type of text, if any.
const Offer = struct { id: u32, text_type: ?usize = null };

pub const Options = struct {
    /// XDG_RUNTIME_DIR and WAYLAND_DISPLAY.
    runtime_dir: ?[]const u8 = null,
    display: ?[]const u8 = null,
    /// ZTK_NO_INPUT_THREAD=1: the pointer stays on the queue of the UI thread.
    no_input_thread: bool = false,
    /// ZTK_WAYLAND_DEBUG=1: each event goes to stderr as its interface number, object, and opcode.
    debug: bool = false,
};

pub const Wayland = struct {
    gpa: std.mem.Allocator,
    conn: *wire.Conn,
    opts: Options,
    registry: u32 = 0,
    compositor: u32 = 0,
    compositor_version: u32 = 0,
    wm_base: u32 = 0,
    seat: u32 = 0,
    shm: u32 = 0,
    viewporter: u32 = 0,
    fractional_mgr: u32 = 0,
    decoration_mgr: u32 = 0,
    cursor_mgr: u32 = 0,
    data_mgr: u32 = 0,
    ti_mgr: u32 = 0,
    pointer: u32 = 0,
    keyboard: u32 = 0,
    cursor_device: u32 = 0,
    data_device: u32 = 0,
    text_input: u32 = 0,
    surface: u32 = 0,
    xdg_surface: u32 = 0,
    toplevel: u32 = 0,
    viewport: u32 = 0,
    fractional: u32 = 0,
    window: ?*Window = null,
    configured: bool = false,
    frame_cb: u32 = 0,
    /// The callback of the last `wl_display.sync`, and true after its `done`.
    sync_cb: u32 = 0,
    sync_done: bool = false,
    scale120: u32 = 120,
    int_scale: u32 = 1,
    events: std.ArrayListUnmanaged(Event) = .empty,
    bufs: [2]?*Buf = .{ null, null },
    prev: ?Image = null,
    px: f32 = 0,
    py: f32 = 0,
    buttons: u8 = 0,
    mods: Mods = .{},
    keymap: ?xkb.Keymap = null,
    mod_mask: u32 = 0,
    group: u32 = 0,
    repeat_rate: i32 = 25,
    repeat_delay: i32 = 600,
    repeat_key: ?u32 = null,
    repeat_at_us: i64 = 0,
    last_serial: u32 = 0,
    pointer_serial: u32 = 0,
    /// The shape of the pointer over the main window.
    cursor: plat.Cursor = .default,
    /// The popup surfaces, under `lock`, because the input thread reads them.
    pops: std.ArrayListUnmanaged(*Pop) = .empty,
    /// The window of the surface under the pointer, under `lock`.
    ptr_win: ?*Window = null,
    /// The serial of the last press of a key or a button, for the grab of a popup.
    press_serial: u32 = 0,
    /// The image that `draw` last made, for the tests.
    last_image: ?Image = null,
    frames_committed: u32 = 0,
    /// The atlas page that the draw reads. Patches fill it.
    atlas: Atlas,
    /// The lock of `events`, `mods`, and `buttons`, which the input thread also uses.
    lock: SpinLock = .{},
    input_thread: ?std.Thread = null,
    input_quit: std.atomic.Value(bool) = .init(false),
    /// Pipes that wake the UI thread and the input thread: read end, write end.
    wake_ui: [2]i32 = .{ -1, -1 },
    wake_input: [2]i32 = .{ -1, -1 },
    /// The offers of the data device, and the offer of the selection.
    offers: std.ArrayListUnmanaged(Offer) = .empty,
    selection: ?Offer = null,
    /// The source of our selection and its text, while it is the selection.
    source: u32 = 0,
    source_text: []u8 = &.{},
    /// The text of an input method, waiting for `done`, and the copies for the events.
    ime_preedit: std.ArrayListUnmanaged(u8) = .empty,
    ime_caret: u32 = 0,
    ime_commit: std.ArrayListUnmanaged(u8) = .empty,
    ime_has_preedit: bool = false,
    ime_has_commit: bool = false,
    ime_out: [2]std.ArrayListUnmanaged(u8) = .{ .empty, .empty },

    pub fn init(gpa: std.mem.Allocator, opts: Options) !*Wayland {
        const conn = wire.Conn.connect(gpa, opts.runtime_dir, opts.display) catch return error.NoWaylandDisplay;
        const w = gpa.create(Wayland) catch |e| {
            conn.deinit();
            return e;
        };
        w.* = .{ .gpa = gpa, .conn = conn, .opts = opts, .atlas = Atlas.init(gpa) };
        errdefer w.deinit();
        w.registry = try w.new(I.registry, .main, 0);
        try w.conn.send(1, 1, .{w.registry});
        try w.roundtrip();
        if (w.compositor == 0 or w.wm_base == 0 or w.shm == 0) return error.MissingGlobals;
        try w.roundtrip();
        return w;
    }

    pub fn deinit(w: *Wayland) void {
        if (w.input_thread) |t| {
            w.input_quit.store(true, .release);
            wakeFd(w.wake_input[1]);
            t.join();
            w.input_thread = null;
        }
        for ([_]i32{ w.wake_ui[0], w.wake_ui[1], w.wake_input[0], w.wake_input[1] }) |fd| if (fd >= 0) {
            _ = linux.close(fd);
        };
        for (w.bufs) |b| if (b) |buf| freeBuf(w, buf);
        w.atlas.deinit();
        if (w.prev) |p| w.gpa.free(p.pixels);
        if (w.last_image) |p| w.gpa.free(p.pixels);
        if (w.keymap) |*k| k.deinit();
        if (w.text_input != 0) w.destroy(w.text_input, 0);
        if (w.data_device != 0) w.destroy(w.data_device, 2);
        if (w.source != 0) w.destroy(w.source, 1);
        for (w.offers.items) |o| w.destroyOffer(o.id);
        if (w.selection) |o| w.destroyOffer(o.id);
        if (w.cursor_device != 0) w.destroy(w.cursor_device, 0);
        if (w.keyboard != 0) w.destroy(w.keyboard, 0);
        if (w.pointer != 0) w.destroy(w.pointer, 1);
        if (w.fractional != 0) w.destroy(w.fractional, 0);
        if (w.viewport != 0) w.destroy(w.viewport, 0);
        if (w.toplevel != 0) w.destroy(w.toplevel, 0);
        if (w.xdg_surface != 0) w.destroy(w.xdg_surface, 0);
        if (w.surface != 0) w.destroy(w.surface, 0);
        w.conn.deinit();
        w.gpa.free(w.source_text);
        w.offers.deinit(w.gpa);
        w.ime_preedit.deinit(w.gpa);
        w.ime_commit.deinit(w.gpa);
        for (&w.ime_out) |*o| o.deinit(w.gpa);
        w.events.deinit(w.gpa);
        w.pops.deinit(w.gpa);
        w.gpa.destroy(w);
    }

    pub fn platform(w: *Wayland) Platform {
        return .{ .ptr = w, .vtable = &vtable, .live = true, .popups = true };
    }

    const vtable: Platform.VTable = .{
        .deinit = vDeinit,
        .createWindow = vCreateWindow,
        .destroyWindow = vDestroyWindow,
        .setTitle = vSetTitle,
        .requestSize = vRequestSize,
        .setMinSize = vSetMinSize,
        .requestFrame = vRequestFrame,
        .wait = vWait,
        .poll = vPoll,
        .nowUs = vNowUs,
        .target = vTarget,
        .setCursor = vSetCursor,
        .clipboardSet = vClipboardSet,
        .clipboardGet = vClipboardGet,
        .textInput = vTextInput,
    };

    fn self(ptr: *anyopaque) *Wayland {
        return @ptrCast(@alignCast(ptr));
    }

    fn push(w: *Wayland, e: Event) void {
        w.lock.lock();
        w.events.append(w.gpa, e) catch {};
        w.lock.unlock();
        if (on_input_thread) wakeFd(w.wake_ui[1]);
    }

    // ---- Requests ----

    fn new(w: *Wayland, iface: u16, queue: wire.Queue, fd_events: u32) !u32 {
        return w.conn.newObject(iface, queue, fd_events);
    }

    /// Sends a request. A failed send marks the connection as lost, and the next read reports it.
    fn req(w: *Wayland, id: u32, op: u16, args: anytype) void {
        if (id == 0) return;
        w.conn.send(id, op, args) catch {};
    }

    /// Sends the destructor request of an object and forgets its id.
    fn destroy(w: *Wayland, id: u32, op: u16) void {
        if (id == 0) return;
        w.req(id, op, .{});
        w.conn.destroyed(id);
    }

    fn flush(w: *Wayland) void {
        w.conn.flush() catch {};
    }

    /// Sends `wl_display.sync` and reads events until its callback is done.
    fn roundtrip(w: *Wayland) !void {
        const cb = try w.new(I.sync_cb, .main, 0);
        w.sync_cb = cb;
        w.sync_done = false;
        try w.conn.send(1, 0, .{cb});
        try w.conn.flush();
        var waits: u32 = 0;
        while (true) {
            w.dispatchMain();
            if (w.sync_done) return;
            if (waits >= 50) return error.WaylandTimeout;
            if (!try w.readWait(100)) waits += 1;
        }
    }

    /// Waits up to `ms` (-1: no limit) for the socket or the wake pipe, and
    /// reads the socket. It returns true when the socket was readable.
    fn readWait(w: *Wayland, ms: i32) !bool {
        var pfd = [_]linux.pollfd{
            .{ .fd = w.conn.fd, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = w.wake_ui[0], .events = linux.POLL.IN, .revents = 0 },
        };
        const n: usize = if (w.wake_ui[0] >= 0) 2 else 1;
        const r = linux.poll(&pfd, n, ms);
        if (@as(isize, @bitCast(r)) <= 0) return false;
        drainFd(w.wake_ui[0]);
        if (pfd[0].revents & (linux.POLL.IN | linux.POLL.HUP | linux.POLL.ERR) == 0) return false;
        const got = try w.conn.read();
        if (got & 2 != 0) w.wakeInput();
        return true;
    }

    fn dispatchMain(w: *Wayland) void {
        while (w.conn.next(.main)) |e| {
            w.handle(e);
            w.conn.release(e);
        }
    }

    // ---- The input thread ----

    threadlocal var on_input_thread: bool = false;

    const SpinLock = struct {
        held: std.atomic.Value(bool) = .init(false),
        fn lock(l: *SpinLock) void {
            while (l.held.swap(true, .acquire)) std.atomic.spinLoopHint();
        }
        fn unlock(l: *SpinLock) void {
            l.held.store(false, .release);
        }
    };

    fn wakeFd(fd: i32) void {
        if (fd < 0) return;
        const one = [1]u8{1};
        _ = linux.write(fd, &one, 1);
    }

    fn drainFd(fd: i32) void {
        if (fd < 0) return;
        var buf: [64]u8 = undefined;
        while (true) {
            const rc = linux.read(fd, &buf, buf.len);
            if (@as(isize, @bitCast(rc)) <= 0) return;
        }
    }

    fn makePipe() [2]i32 {
        var fds: [2]i32 = .{ -1, -1 };
        const rc = linux.pipe2(&fds, .{ .NONBLOCK = true, .CLOEXEC = true });
        if (@as(isize, @bitCast(rc)) < 0) return .{ -1, -1 };
        return fds;
    }

    /// Moves the pointer to its own queue and starts the input thread. With
    /// no pipe, no thread, or `no_input_thread`, the pointer stays on the queue of the UI thread.
    fn startInput(w: *Wayland) void {
        if (w.opts.no_input_thread) return;
        w.wake_ui = makePipe();
        w.wake_input = makePipe();
        if (w.wake_ui[0] < 0 or w.wake_input[0] < 0) return;
        w.conn.setQueue(w.pointer, .input);
        w.input_thread = std.Thread.spawn(.{}, inputLoop, .{w}) catch blk: {
            w.conn.setQueue(w.pointer, .main);
            break :blk null;
        };
    }

    fn inputLoop(w: *Wayland) void {
        on_input_thread = true;
        while (!w.input_quit.load(.acquire)) {
            w.dispatchInput();
            w.flush();
            var pfd = [_]linux.pollfd{
                .{ .fd = w.conn.fd, .events = linux.POLL.IN, .revents = 0 },
                .{ .fd = w.wake_input[0], .events = linux.POLL.IN, .revents = 0 },
            };
            const r = linux.poll(&pfd, 2, -1);
            if (@as(isize, @bitCast(r)) > 0 and pfd[0].revents & (linux.POLL.HUP | linux.POLL.ERR) != 0) return;
            if (@as(isize, @bitCast(r)) > 0 and pfd[0].revents & linux.POLL.IN != 0) {
                const got = w.conn.read() catch return;
                // The events of the UI queue that this thread read.
                if (got & 1 != 0) wakeFd(w.wake_ui[1]);
            }
            drainFd(w.wake_input[0]);
        }
    }

    fn dispatchInput(w: *Wayland) void {
        while (w.conn.next(.input)) |e| {
            w.handle(e);
            w.conn.release(e);
        }
    }

    /// After a read by the UI thread: the pointer events that it read wait in the queue of the input thread.
    fn wakeInput(w: *Wayland) void {
        if (w.input_thread != null) wakeFd(w.wake_input[1]);
    }

    // ---- The dispatch of events ----

    fn handle(w: *Wayland, e: wire.Event) void {
        if (w.opts.debug) std.debug.print("wayland: event iface {d} object {d} op {d} ({d} bytes, {d} fds)\n", .{ e.iface, e.id, e.op, e.data.len, e.nfds });
        var a = e.args();
        switch (e.iface) {
            I.registry => if (e.op == 0) {
                const name = a.uint();
                const iface = a.string() orelse return;
                const version = a.uint();
                w.onGlobal(name, iface, version) catch {};
            },
            I.sync_cb => if (e.id == w.sync_cb) {
                w.sync_done = true;
                w.conn.destroyed(e.id);
            },
            I.wm_base => if (e.op == 0) {
                w.req(w.wm_base, 3, .{a.uint()});
                w.flush();
            },
            I.xdg_surface => {
                const serial = a.uint();
                w.req(e.id, 4, .{serial});
                if (w.popById(e.id, .xdg_surface)) |p| {
                    if (p.configured) return;
                    p.configured = true;
                    w.push(.{ .frame = .{ .window = p.win, .time_us = nowUs() } });
                } else if (!w.configured) {
                    w.configured = true;
                    // The first frame needs no callback.
                    if (w.window) |win| w.push(.{ .frame = .{ .window = win, .time_us = nowUs() } });
                }
            },
            I.toplevel => switch (e.op) {
                0 => {
                    const width = a.int();
                    const height = a.int();
                    const win = w.window orelse return;
                    if (width > 0 and height > 0 and (win.size.w != width or win.size.h != height)) {
                        win.size = .{ .w = width, .h = height };
                        w.push(.{ .resize = .{ .window = win, .size = win.size } });
                    }
                },
                1 => if (w.window) |win| w.push(.{ .close = .{ .window = win } }),
                else => {},
            },
            I.popup => if (w.popById(e.id, .popup)) |p| switch (e.op) {
                0 => {
                    const x = a.int();
                    const y = a.int();
                    // The place of the window geometry in the window geometry of the parent.
                    const pos: geom.Point = .{ .x = x - p.margin.left + p.parent_margin.left, .y = y - p.margin.top + p.parent_margin.top };
                    if (pos.x == p.win.pos.x and pos.y == p.win.pos.y) return;
                    p.win.pos = pos;
                    if (p.configured) w.push(.{ .resize = .{ .window = p.win, .size = p.win.size } });
                },
                1 => w.push(.{ .close = .{ .window = p.win } }),
                else => {},
            },
            I.frac => if (e.op == 0) w.setScale(a.uint()),
            I.surface => if (e.op == 2 and e.id == w.surface) {
                // The integer scale counts only without the fractional scale.
                if (w.fractional != 0) return;
                w.int_scale = @intCast(std.math.clamp(a.int(), 1, 16));
                w.setScale(w.int_scale * 120);
            },
            I.frame_cb => {
                const time_ms = a.uint();
                w.conn.destroyed(e.id);
                if (e.id == w.frame_cb) {
                    w.frame_cb = 0;
                    if (w.window) |win| w.push(.{ .frame = .{ .window = win, .time_us = @as(i64, time_ms) * 1000 } });
                } else if (w.popById(e.id, .frame_cb)) |p| {
                    p.frame_cb = 0;
                    w.push(.{ .frame = .{ .window = p.win, .time_us = @as(i64, time_ms) * 1000 } });
                }
            },
            I.buffer => if (e.op == 0) w.onRelease(e.id),
            I.seat => if (e.op == 0) w.onCapabilities(a.uint()),
            I.pointer => w.onPointer(e.op, &a),
            I.keyboard => w.onKeyboard(e.op, &a),
            I.data_device => w.onDataDevice(e.op, &a),
            I.data_offer => if (e.op == 0) w.onOfferType(e.id, a.string() orelse return),
            I.data_source => w.onSource(e.id, e.op, &a),
            I.text_input => w.onTextInput(e.op, &a),
            else => {},
        }
    }

    // ---- The registry ----

    fn bind(w: *Wayland, name: u32, iface_name: []const u8, iface: u16, version: u32, fd_events: u32) !u32 {
        const id = try w.new(iface, .main, fd_events);
        try w.conn.send(w.registry, 0, .{ name, wire.Str{ .s = iface_name }, version, id });
        return id;
    }

    fn onGlobal(w: *Wayland, name: u32, i: []const u8, version: u32) !void {
        if (std.mem.eql(u8, i, "wl_compositor")) {
            w.compositor_version = @min(version, 6);
            w.compositor = try w.bind(name, i, I.compositor, w.compositor_version, 0);
        } else if (std.mem.eql(u8, i, "xdg_wm_base")) {
            w.wm_base = try w.bind(name, i, I.wm_base, @min(version, 2), 0);
        } else if (std.mem.eql(u8, i, "wl_seat") and w.seat == 0) {
            w.seat = try w.bind(name, i, I.seat, @min(version, 5), 0);
            w.makeDevices();
        } else if (std.mem.eql(u8, i, "wl_shm")) {
            w.shm = try w.bind(name, i, I.shm, 1, 0);
        } else if (std.mem.eql(u8, i, "wp_viewporter")) {
            w.viewporter = try w.bind(name, i, I.viewporter, 1, 0);
        } else if (std.mem.eql(u8, i, "wp_fractional_scale_manager_v1")) {
            w.fractional_mgr = try w.bind(name, i, I.frac_mgr, 1, 0);
        } else if (std.mem.eql(u8, i, "zxdg_decoration_manager_v1")) {
            w.decoration_mgr = try w.bind(name, i, I.deco_mgr, 1, 0);
        } else if (std.mem.eql(u8, i, "wp_cursor_shape_manager_v1")) {
            w.cursor_mgr = try w.bind(name, i, I.cursor_mgr, 1, 0);
        } else if (std.mem.eql(u8, i, "wl_data_device_manager")) {
            w.data_mgr = try w.bind(name, i, I.data_mgr, @min(version, 3), 0);
            w.makeDevices();
        } else if (std.mem.eql(u8, i, "zwp_text_input_manager_v3")) {
            w.ti_mgr = try w.bind(name, i, I.ti_mgr, 1, 0);
            w.makeDevices();
        }
    }

    /// The objects of the seat that need a second global: the data device and the text input.
    fn makeDevices(w: *Wayland) void {
        if (w.seat == 0) return;
        if (w.data_mgr != 0 and w.data_device == 0) {
            w.data_device = w.new(I.data_device, .main, 0) catch 0;
            // Event 0 (data_offer) makes a wl_data_offer.
            w.conn.setCreates(w.data_device, 0, I.data_offer);
            w.req(w.data_mgr, 1, .{ w.data_device, w.seat });
        }
        if (w.ti_mgr != 0 and w.text_input == 0) {
            w.text_input = w.new(I.text_input, .main, 0) catch 0;
            w.req(w.ti_mgr, 1, .{ w.text_input, w.seat });
        }
    }

    // ---- The window ----

    fn setScale(w: *Wayland, s120: u32) void {
        if (w.scale120 == s120 or s120 == 0) return;
        w.scale120 = s120;
        if (w.window) |win| {
            win.scale = @as(f32, @floatFromInt(s120)) / 120.0;
            w.push(.{ .scale = .{ .window = win, .scale = win.scale } });
        }
    }

    fn vCreateWindow(ptr: *anyopaque, opts: plat.WindowOptions) anyerror!*Window {
        const w = self(ptr);
        if (opts.popup) |p| return w.createPopup(opts.size, p);
        if (w.window != null) return error.OnlyOneWindow;
        const win = try w.gpa.create(Window);
        win.* = .{ .size = opts.size };
        w.window = win;
        w.surface = try w.new(I.surface, .main, 0);
        w.req(w.compositor, 0, .{w.surface});
        w.xdg_surface = try w.new(I.xdg_surface, .main, 0);
        w.req(w.wm_base, 2, .{ w.xdg_surface, w.surface });
        w.toplevel = try w.new(I.toplevel, .main, 0);
        w.req(w.xdg_surface, 1, .{w.toplevel});
        w.req(w.toplevel, 3, .{wire.Str{ .s = "ztk" }});
        if (opts.title.len > 0) vSetTitle(ptr, win, opts.title) else w.req(w.toplevel, 2, .{wire.Str{ .s = "ztk" }});
        if (w.decoration_mgr != 0) {
            const dec = try w.new(I.deco, .main, 0);
            w.req(w.decoration_mgr, 1, .{ dec, w.toplevel });
            // Mode 2 is server_side.
            w.req(dec, 1, .{@as(u32, 2)});
        }
        if (w.fractional_mgr != 0 and w.viewporter != 0) {
            w.fractional = try w.new(I.frac, .main, 0);
            w.req(w.fractional_mgr, 1, .{ w.fractional, w.surface });
            w.viewport = try w.new(I.viewport, .main, 0);
            w.req(w.viewporter, 1, .{ w.viewport, w.surface });
        }
        w.req(w.surface, 6, .{});
        // Wait for the first configure.
        try w.roundtrip();
        var spins: u32 = 0;
        while (!w.configured and spins < 50) : (spins += 1) try w.roundtrip();
        win.scale = @as(f32, @floatFromInt(w.scale120)) / 120.0;
        return win;
    }

    fn vDestroyWindow(ptr: *anyopaque, win: *Window) void {
        const w = self(ptr);
        if (popOf(win)) |p| return w.destroyPopup(p);
        w.lock.lock();
        if (w.window == win) w.window = null;
        w.lock.unlock();
        w.gpa.destroy(win);
    }

    fn vDeinit(ptr: *anyopaque) void {
        self(ptr).deinit();
    }

    fn vSetTitle(ptr: *anyopaque, _: *Window, title: []const u8) void {
        const w = self(ptr);
        // A string of the protocol has no zero byte, and the title has a limit of 255 bytes.
        var end: usize = @min(title.len, 255);
        if (std.mem.indexOfScalar(u8, title[0..end], 0)) |z| end = z;
        while (end > 0 and end < title.len and title[end] & 0xc0 == 0x80) end -= 1;
        w.req(w.toplevel, 2, .{wire.Str{ .s = title[0..end] }});
        w.flush();
    }

    fn vRequestSize(ptr: *anyopaque, win: *Window, size: geom.Size) void {
        const w = self(ptr);
        if (win.size.w == size.w and win.size.h == size.h) return;
        win.size = size;
        if (popOf(win)) |p| {
            const m = p.margin;
            w.req(p.xdg_surface, 3, .{ m.left, m.top, @max(size.w - m.left - m.right, 1), @max(size.h - m.top - m.bottom, 1) });
        }
        w.push(.{ .resize = .{ .window = win, .size = size } });
    }

    fn vSetMinSize(ptr: *anyopaque, _: *Window, size: geom.Size) void {
        const w = self(ptr);
        w.req(w.toplevel, 8, .{ size.w, size.h });
    }

    fn vNowUs(_: *anyopaque) i64 {
        return nowUs();
    }

    fn nowUs() i64 {
        var ts: linux.timespec = undefined;
        _ = linux.clock_gettime(.MONOTONIC, &ts);
        return @as(i64, ts.sec) * 1_000_000 + @divFloor(@as(i64, ts.nsec), 1000);
    }

    // ---- Frames ----

    fn vRequestFrame(ptr: *anyopaque, win: *Window) void {
        const w = self(ptr);
        if (popOf(win)) |p| {
            if (p.frame_cb != 0 or !p.configured) return;
            p.frame_cb = w.new(I.frame_cb, .main, 0) catch return;
            w.req(p.surface, 3, .{p.frame_cb});
            w.req(p.surface, 6, .{});
            w.flush();
            return;
        }
        if (w.frame_cb != 0 or !w.configured or w.surface == 0) return;
        w.frame_cb = w.new(I.frame_cb, .main, 0) catch return;
        w.req(w.surface, 3, .{w.frame_cb});
        w.req(w.surface, 6, .{});
        w.flush();
    }

    // ---- The wait and the poll ----

    fn vWait(ptr: *anyopaque, timeout_us: ?i64) void {
        const w = self(ptr);
        w.dispatchMain();
        w.lock.lock();
        const pending = w.events.items.len > 0;
        w.lock.unlock();
        if (pending) return;
        var limit = timeout_us;
        if (w.repeat_key != null) {
            const left = @max(w.repeat_at_us - nowUs(), 0);
            limit = if (limit) |l| @min(l, left) else left;
        }
        w.flush();
        const ms: i32 = if (limit) |l| @intCast(@min(@divFloor(l +| 999, 1000), std.math.maxInt(i32))) else -1;
        _ = w.readWait(ms) catch w.lost();
        w.dispatchMain();
    }

    /// The connection is gone: the window gets a close event, once.
    fn lost(w: *Wayland) void {
        if (w.window) |win| w.push(.{ .close = .{ .window = win } });
        w.lock.lock();
        w.window = null;
        w.lock.unlock();
    }

    fn vPoll(ptr: *anyopaque, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(Event)) anyerror!void {
        const w = self(ptr);
        w.flush();
        // A read that does not block gets events that wait on the socket.
        _ = w.readWait(0) catch w.lost();
        w.dispatchMain();
        w.runRepeat();
        w.lock.lock();
        defer w.lock.unlock();
        try out.appendSlice(gpa, w.events.items);
        w.events.clearRetainingCapacity();
    }

    fn runRepeat(w: *Wayland) void {
        const key = w.repeat_key orelse return;
        const now = nowUs();
        if (now < w.repeat_at_us or w.repeat_rate <= 0) return;
        w.pushKey(key, true, true);
        w.repeat_at_us += @divFloor(1_000_000, @as(i64, w.repeat_rate));
        if (w.repeat_at_us < now) w.repeat_at_us = now;
    }

    // ---- The seat ----

    fn onCapabilities(w: *Wayland, caps: u32) void {
        if (caps & 1 != 0 and w.pointer == 0) {
            w.pointer = w.new(I.pointer, .main, 0) catch return;
            w.req(w.seat, 0, .{w.pointer});
            if (w.cursor_mgr != 0) {
                w.cursor_device = w.new(I.cursor_dev, .main, 0) catch 0;
                w.req(w.cursor_mgr, 1, .{ w.cursor_device, w.pointer });
            }
            w.startInput();
        }
        if (caps & 2 != 0 and w.keyboard == 0) {
            // Event 0 (keymap) has a file descriptor.
            w.keyboard = w.new(I.keyboard, .main, 1) catch return;
            w.req(w.seat, 1, .{w.keyboard});
        }
    }

    fn timeMs() u32 {
        return @truncate(@as(u64, @intCast(@divFloor(nowUs(), 1000))));
    }

    fn currentMods(w: *Wayland) Mods {
        w.lock.lock();
        defer w.lock.unlock();
        var m = w.mods;
        m.button1 = w.buttons & 1 != 0;
        m.button2 = w.buttons & 2 != 0;
        m.button3 = w.buttons & 4 != 0;
        return m;
    }

    fn onPointer(w: *Wayland, op: u16, a: *wire.Args) void {
        switch (op) {
            0 => {
                const serial = a.uint();
                const surf = a.uint();
                w.lock.lock();
                w.ptr_win = w.window;
                for (w.pops.items) |p| if (p.surface == surf) {
                    w.ptr_win = p.win;
                };
                w.lock.unlock();
                w.px = a.fixed();
                w.py = a.fixed();
                w.pointer_serial = serial;
                w.applyCursor(if (surf == w.surface) w.cursor else .default);
                w.motion();
            },
            1 => {
                w.lock.lock();
                const win = w.ptr_win orelse w.window;
                w.ptr_win = null;
                w.lock.unlock();
                if (win) |x| w.push(.{ .leave = .{ .window = x } });
            },
            2 => {
                _ = a.uint();
                w.px = a.fixed();
                w.py = a.fixed();
                w.motion();
            },
            3 => {
                const serial = a.uint();
                _ = a.uint();
                const code = a.uint();
                const state = a.uint();
                const button: u8 = switch (code) {
                    0x110 => 1,
                    0x112 => 2,
                    0x111 => 3,
                    else => return,
                };
                const pressed = state == 1;
                if (pressed) @atomicStore(u32, &w.press_serial, serial, .release);
                const before = w.currentMods();
                if (w.pointerWindow()) |win| w.push(.{ .button = .{ .window = win, .button = button, .pressed = pressed, .x = w.px, .y = w.py, .mods = before, .time_ms = timeMs() } });
                const bit: u8 = @as(u8, 1) << @intCast(button - 1);
                w.lock.lock();
                if (pressed) w.buttons |= bit else w.buttons &= ~bit;
                w.lock.unlock();
            },
            4 => {
                _ = a.uint();
                const axis = a.uint();
                // A wheel step is 10 pixels on the axis. The event counts steps.
                const v = a.fixed() / 10;
                if (w.pointerWindow()) |win| w.push(.{ .scroll = .{
                    .window = win,
                    .dx = if (axis == 1) v else 0,
                    .dy = if (axis == 0) v else 0,
                    .x = w.px,
                    .y = w.py,
                    .mods = w.currentMods(),
                    .time_ms = timeMs(),
                } });
            },
            else => {},
        }
    }

    /// A motion event, and the position for the render thread. The lock keeps
    /// the window alive while the render thread gets the position.
    fn motion(w: *Wayland) void {
        const m = w.currentMods();
        w.lock.lock();
        const win = w.ptr_win orelse w.window;
        if (win) |x| if (x == w.window) x.feedPointer(w.px, w.py);
        w.lock.unlock();
        if (win) |x| w.push(.{ .motion = .{ .window = x, .x = w.px, .y = w.py, .mods = m, .time_ms = timeMs() } });
    }

    fn pointerWindow(w: *Wayland) ?*Window {
        w.lock.lock();
        defer w.lock.unlock();
        return w.ptr_win orelse w.window;
    }

    // ---- The pointer shape ----

    fn shapeNumber(c: plat.Cursor) u32 {
        return switch (c) {
            .default => 1,
            .help => 3,
            .pointer => 4,
            .progress => 5,
            .wait => 6,
            .crosshair => 8,
            .text => 9,
            .move => 13,
            .not_allowed => 15,
            .grab => 16,
            .grabbing => 17,
            .ew_resize => 26,
            .ns_resize => 27,
            .nesw_resize => 28,
            .nwse_resize => 29,
        };
    }

    fn applyCursor(w: *Wayland, c: plat.Cursor) void {
        if (w.cursor_device == 0 or w.pointer_serial == 0) return;
        w.req(w.cursor_device, 1, .{ w.pointer_serial, shapeNumber(c) });
        w.flush();
    }

    fn vSetCursor(ptr: *anyopaque, win: *Window, shape: plat.Cursor) void {
        const w = self(ptr);
        if (win != w.window or w.cursor == shape) return;
        w.cursor = shape;
        if (w.pointerWindow() == win) w.applyCursor(shape);
    }

    // ---- The keyboard ----

    fn onKeyboard(w: *Wayland, op: u16, a: *wire.Args) void {
        switch (op) {
            0 => {
                const format = a.uint();
                const fd = a.fd();
                const size = a.uint();
                defer if (fd >= 0) {
                    _ = linux.close(fd);
                };
                // Format 1 is xkb_v1.
                if (format != 1 or fd < 0 or size == 0) return;
                const rc = linux.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
                if (@as(isize, @bitCast(rc)) < 0) return;
                const map: [*]const u8 = @ptrFromInt(rc);
                defer _ = linux.munmap(map, size);
                const src = std.mem.sliceTo(map[0..size], 0);
                const km = xkb.Keymap.parse(w.gpa, src) catch |err| {
                    if (w.opts.debug) std.debug.print("wayland: the key map: {s}\n", .{@errorName(err)});
                    return;
                };
                if (w.keymap) |*k| k.deinit();
                w.keymap = km;
            },
            1 => {
                // The grab of a popup moves the keyboard to the popup, and the keys stay on the main window.
                if (w.pops.items.len > 0) return;
                if (w.window) |win| w.push(.{ .focus = .{ .window = win, .focused = true } });
            },
            2 => {
                w.repeat_key = null;
                if (w.pops.items.len > 0) return;
                if (w.window) |win| w.push(.{ .focus = .{ .window = win, .focused = false } });
            },
            3 => {
                const serial = a.uint();
                _ = a.uint();
                const key = a.uint();
                const pressed = a.uint() == 1;
                w.last_serial = serial;
                if (pressed) @atomicStore(u32, &w.press_serial, serial, .release);
                w.pushKey(key, pressed, false);
                if (pressed) {
                    // A key that has repeat starts the repeat. A modifier key has none.
                    const has_repeat = if (w.keymap) |*km| km.repeats(key + 8) else false;
                    if (has_repeat) {
                        w.repeat_key = key;
                        w.repeat_at_us = nowUs() + @as(i64, w.repeat_delay) * 1000;
                    }
                } else if (w.repeat_key == key) w.repeat_key = null;
            },
            4 => {
                _ = a.uint();
                const depressed = a.uint();
                const latched = a.uint();
                const locked = a.uint();
                w.group = a.uint();
                w.mod_mask = depressed | latched | locked;
                const km = if (w.keymap) |*k| k else return;
                const eff = km.effective(w.mod_mask);
                w.lock.lock();
                defer w.lock.unlock();
                w.mods = .{
                    .shift = eff & 1 != 0,
                    .lock = eff & 2 != 0,
                    .control = eff & 4 != 0,
                    .mod1 = eff & 8 != 0,
                    .mod4 = eff & 64 != 0,
                };
            },
            5 => {
                w.repeat_rate = a.int();
                w.repeat_delay = a.int();
            },
            else => {},
        }
    }

    fn pushKey(w: *Wayland, key: u32, pressed: bool, repeat: bool) void {
        const km = if (w.keymap) |*k| k else return;
        const win = w.window orelse return;
        const code = key + 8;
        const sym = km.symbol(code, w.mod_mask, w.group);
        const mods = w.currentMods();
        var e: Event = .{ .key = .{
            .window = win,
            .keysym = sym,
            .keycode = code,
            .pressed = pressed,
            .repeat = repeat,
            .mods = mods,
            .time_ms = timeMs(),
        } };
        if (pressed) {
            var buf: [8]u8 = undefined;
            const t = xkb.text(sym, mods.control, mods.mod1, &buf);
            @memcpy(e.key.text[0..t.len], t);
            e.key.text_len = @intCast(t.len);
        }
        w.push(e);
    }

    // ---- The clipboard ----

    fn destroyOffer(w: *Wayland, id: u32) void {
        // Request 2 of wl_data_offer is destroy.
        w.req(id, 2, .{});
        w.conn.forget(id);
    }

    fn onDataDevice(w: *Wayland, op: u16, a: *wire.Args) void {
        switch (op) {
            0 => {
                const id = a.uint();
                w.offers.append(w.gpa, .{ .id = id }) catch w.destroyOffer(id);
            },
            // The offer of a drag ends with leave or drop: the drop of files is not part of this backend.
            2, 4 => w.dropOffers(null),
            5 => {
                const id = a.uint();
                if (w.selection) |s| if (s.id != id) w.destroyOffer(s.id);
                w.selection = null;
                for (w.offers.items) |o| if (o.id == id) {
                    w.selection = o;
                };
                w.dropOffers(id);
            },
            else => {},
        }
    }

    /// Destroys the offers that wait, except one.
    fn dropOffers(w: *Wayland, keep: ?u32) void {
        for (w.offers.items) |o| if (keep == null or o.id != keep.?) w.destroyOffer(o.id);
        w.offers.clearRetainingCapacity();
    }

    fn onOfferType(w: *Wayland, id: u32, mime: []const u8) void {
        const rank = for (text_types, 0..) |t, i| {
            if (std.mem.eql(u8, t, mime)) break i;
        } else return;
        for (w.offers.items) |*o| if (o.id == id) {
            if (o.text_type == null or rank < o.text_type.?) o.text_type = rank;
        };
    }

    fn onSource(w: *Wayland, id: u32, op: u16, a: *wire.Args) void {
        switch (op) {
            1 => {
                _ = a.string();
                const fd = a.fd();
                if (fd < 0) return;
                defer _ = linux.close(fd);
                var off: usize = 0;
                while (off < w.source_text.len) {
                    const rc = linux.write(fd, w.source_text[off..].ptr, w.source_text.len - off);
                    if (@as(isize, @bitCast(rc)) <= 0) break;
                    off += rc;
                }
            },
            2 => {
                w.destroy(id, 1);
                if (w.source == id) w.source = 0;
            },
            else => {},
        }
    }

    fn vClipboardSet(ptr: *anyopaque, typ: []const u8, data: []const u8) void {
        const w = self(ptr);
        if (!std.mem.eql(u8, typ, "STRING") or w.data_device == 0) return;
        const copy = w.gpa.dupe(u8, data) catch return;
        w.gpa.free(w.source_text);
        w.source_text = copy;
        if (w.source != 0) w.destroy(w.source, 1);
        // Event 1 (send) has a file descriptor.
        w.source = w.new(I.data_source, .main, 2) catch return;
        w.req(w.data_mgr, 0, .{w.source});
        for (text_types) |t| w.req(w.source, 0, .{wire.Str{ .s = t }});
        const serial = @max(w.last_serial, @atomicLoad(u32, &w.press_serial, .acquire));
        w.req(w.data_device, 1, .{ w.source, serial });
        w.flush();
    }

    fn vClipboardGet(ptr: *anyopaque, gpa: std.mem.Allocator, typ: []const u8) ?[]u8 {
        const w = self(ptr);
        if (!std.mem.eql(u8, typ, "STRING")) return null;
        w.dispatchMain();
        // The selection of this client: the core has the data.
        if (w.source != 0) return null;
        const offer = w.selection orelse return null;
        const rank = offer.text_type orelse return null;
        var fds: [2]i32 = .{ -1, -1 };
        if (@as(isize, @bitCast(linux.pipe2(&fds, .{ .CLOEXEC = true }))) < 0) return null;
        defer _ = linux.close(fds[0]);
        // The send closes the write end after the flush.
        w.req(offer.id, 1, .{ wire.Str{ .s = text_types[rank] }, wire.Fd{ .fd = fds[1] } });
        w.flush();
        var out: std.ArrayListUnmanaged(u8) = .empty;
        var buf: [4096]u8 = undefined;
        while (out.items.len < 64 << 20) {
            var pfd = [1]linux.pollfd{.{ .fd = fds[0], .events = linux.POLL.IN, .revents = 0 }};
            if (@as(isize, @bitCast(linux.poll(&pfd, 1, 1000))) <= 0) break;
            const rc = linux.read(fds[0], &buf, buf.len);
            if (@as(isize, @bitCast(rc)) <= 0) break;
            out.appendSlice(gpa, buf[0..rc]) catch break;
        }
        return out.toOwnedSlice(gpa) catch null;
    }

    // ---- The text of an input method ----

    fn vTextInput(ptr: *anyopaque, win: *Window, on: bool, rect: geom.Rect) void {
        const w = self(ptr);
        if (w.text_input == 0 or win != w.window) return;
        if (on) {
            w.req(w.text_input, 1, .{});
            w.req(w.text_input, 6, .{ rect.x, rect.y, @max(rect.w, 1), @max(rect.h, 1) });
        } else w.req(w.text_input, 2, .{});
        w.req(w.text_input, 7, .{});
        w.flush();
    }

    fn onTextInput(w: *Wayland, op: u16, a: *wire.Args) void {
        switch (op) {
            2 => {
                const t = a.string() orelse "";
                const begin = a.int();
                w.ime_preedit.clearRetainingCapacity();
                w.ime_preedit.appendSlice(w.gpa, t) catch {};
                w.ime_caret = if (begin >= 0) @intCast(@min(begin, @as(i32, @intCast(t.len)))) else @intCast(t.len);
                w.ime_has_preedit = true;
            },
            3 => {
                const t = a.string() orelse "";
                w.ime_commit.appendSlice(w.gpa, t) catch {};
                w.ime_has_commit = true;
            },
            5 => {
                const win = w.window orelse return;
                // The texts of the events stay in `ime_out` until the next `done`.
                if (w.ime_has_commit) {
                    w.ime_out[1].clearRetainingCapacity();
                    w.ime_out[1].appendSlice(w.gpa, w.ime_commit.items) catch {};
                    w.push(.{ .commit = .{ .window = win, .text = w.ime_out[1].items } });
                }
                // A done with no preedit string ends the composition.
                w.ime_out[0].clearRetainingCapacity();
                if (w.ime_has_preedit) w.ime_out[0].appendSlice(w.gpa, w.ime_preedit.items) catch {};
                w.push(.{ .preedit = .{ .window = win, .text = w.ime_out[0].items, .caret = if (w.ime_has_preedit) w.ime_caret else 0 } });
                w.ime_commit.clearRetainingCapacity();
                w.ime_preedit.clearRetainingCapacity();
                w.ime_has_commit = false;
                w.ime_has_preedit = false;
            },
            else => {},
        }
    }

    // ---- Drawing with the CPU renderer into shared memory ----

    fn onRelease(w: *Wayland, id: u32) void {
        for (w.bufs) |b| if (b) |buf| if (buf.buffer == id) {
            @atomicStore(bool, &buf.busy, false, .release);
            return;
        };
        w.lock.lock();
        defer w.lock.unlock();
        for (w.pops.items) |p| for (p.bufs) |b| if (b) |buf| if (buf.buffer == id) {
            @atomicStore(bool, &buf.busy, false, .release);
            return;
        };
    }

    fn freeBuf(w: *Wayland, b: *Buf) void {
        w.destroy(b.buffer, 0);
        if (b.data.len > 0) _ = linux.munmap(b.data.ptr, b.data.len);
        w.gpa.destroy(b);
    }

    fn makeBuf(w: *Wayland, width: u32, height: u32, format: u32) !*Buf {
        const size: usize = @as(usize, width) * height * 4;
        const rc = linux.memfd_create("ztk-shm", linux.MFD.CLOEXEC);
        if (@as(isize, @bitCast(rc)) < 0) return error.ShmFailed;
        const fd: i32 = @intCast(rc);
        if (@as(isize, @bitCast(linux.ftruncate(fd, @intCast(size)))) < 0) {
            _ = linux.close(fd);
            return error.ShmFailed;
        }
        const map = linux.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
        if (@as(isize, @bitCast(map)) < 0) {
            _ = linux.close(fd);
            return error.ShmFailed;
        }
        const b = try w.gpa.create(Buf);
        b.* = .{ .owner = w, .width = width, .height = height, .data = @as([*]align(4096) u8, @ptrFromInt(map))[0..size] };
        const pool = try w.new(I.shm_pool, .main, 0);
        // The send closes the descriptor after the flush.
        w.req(w.shm, 0, .{ pool, wire.Fd{ .fd = fd }, @as(i32, @intCast(size)) });
        b.buffer = try w.new(I.buffer, .main, 0);
        w.req(pool, 0, .{ b.buffer, @as(i32, 0), @as(i32, @intCast(width)), @as(i32, @intCast(height)), @as(i32, @intCast(width * 4)), format });
        w.destroy(pool, 1);
        return b;
    }

    fn freeBufferFor(w: *Wayland, bufs: *[2]?*Buf, width: u32, height: u32, format: u32) !*Buf {
        for (bufs) |*slot| {
            if (slot.*) |b| {
                if (@atomicLoad(bool, &b.busy, .acquire)) continue;
                if (b.width == width and b.height == height) return b;
                freeBuf(w, b);
                slot.* = null;
            }
        }
        for (bufs) |*slot| if (slot.* == null) {
            slot.* = try w.makeBuf(width, height, format);
            return slot.*.?;
        };
        // Both buffers are busy: wait for a release.
        var spins: u32 = 0;
        while (spins < 100) : (spins += 1) {
            try w.roundtrip();
            for (bufs) |*slot| if (slot.*) |b| if (!@atomicLoad(bool, &b.busy, .acquire)) {
                if (b.width == width and b.height == height) return b;
                freeBuf(w, b);
                slot.* = try w.makeBuf(width, height, format);
                return slot.*.?;
            };
        }
        return error.NoFreeBuffer;
    }

    fn vTarget(ptr: *anyopaque, win: *Window) Target {
        if (popOf(win)) |p| return .{ .ctx = p, .draw = drawPopup };
        return .{ .ctx = self(ptr), .draw = drawFrame };
    }

    /// Draws one frame into a shared memory buffer. The draw reads the
    /// events of the UI queue (in `roundtrip`), so this target runs in
    /// `inline_draw` mode.
    fn drawFrame(ctx: *anyopaque, frame: *const Frame) anyerror!void {
        const w: *Wayland = @ptrCast(@alignCast(ctx));
        const win = w.window orelse return;
        for (frame.patches.items) |p| try w.atlas.applyPatch(p);
        const scene = &frame.scene;
        const surface = w.surface;
        if (surface == 0) return;
        const need = @as(usize, scene.width) * scene.height * 4;
        const img = try w.gpa.alloc(u8, need);
        errdefer w.gpa.free(img);
        var cur: Image = .{ .width = scene.width, .height = scene.height, .pixels = img };
        cpu.render(scene, &w.atlas, &cur);
        // The rows that changed since the last frame are the damage.
        var ranges: [16]renderer.RowRange = undefined;
        var damage: []const renderer.RowRange = &.{};
        const same_size = if (w.prev) |p| p.width == cur.width and p.height == cur.height else false;
        if (same_size) {
            damage = renderer.changedRows(w.prev.?, cur, &ranges);
            if (damage.len == 0) {
                w.gpa.free(img);
                return;
            }
        }
        const buf = try w.freeBufferFor(&w.bufs, cur.width, cur.height, shm_xrgb8888);
        // RGBA to XRGB8888 (bytes B, G, R, X).
        var i: usize = 0;
        while (i < need) : (i += 4) {
            buf.data[i] = cur.pixels[i + 2];
            buf.data[i + 1] = cur.pixels[i + 1];
            buf.data[i + 2] = cur.pixels[i];
            buf.data[i + 3] = 255;
        }
        if (w.prev) |p| w.gpa.free(p.pixels);
        w.prev = cur;
        w.last_image = null;
        // The scale: a viewport for the fractional scale, or the integer buffer scale.
        if (w.viewport != 0) {
            w.req(w.viewport, 2, .{ win.size.w, win.size.h });
        } else if (w.compositor_version >= 3) {
            w.req(surface, 8, .{@as(i32, @intCast(w.int_scale))});
        }
        w.req(surface, 1, .{ buf.buffer, @as(i32, 0), @as(i32, 0) });
        if (damage.len == 0) {
            w.req(surface, 9, .{ @as(i32, 0), @as(i32, 0), @as(i32, @intCast(cur.width)), @as(i32, @intCast(cur.height)) });
        } else for (damage) |d| {
            w.req(surface, 9, .{ @as(i32, 0), @as(i32, @intCast(d.first)), @as(i32, @intCast(cur.width)), @as(i32, @intCast(d.last - d.first)) });
        }
        @atomicStore(bool, &buf.busy, true, .release);
        w.req(surface, 6, .{});
        w.frames_committed += 1;
        w.flush();
    }

    // ---- Popups ----

    fn popOf(win: *const Window) ?*Pop {
        return @ptrCast(@alignCast(win.impl orelse return null));
    }

    const PopField = enum { xdg_surface, popup, frame_cb };

    fn popById(w: *Wayland, id: u32, field: PopField) ?*Pop {
        w.lock.lock();
        defer w.lock.unlock();
        for (w.pops.items) |p| {
            const v = switch (field) {
                .xdg_surface => p.xdg_surface,
                .popup => p.popup,
                .frame_cb => p.frame_cb,
            };
            if (v == id) return p;
        }
        return null;
    }

    fn createPopup(w: *Wayland, size: geom.Size, opt: plat.Popup) !*Window {
        var parent_xdg = w.xdg_surface;
        if (parent_xdg == 0) return error.NoParent;
        var pm: geom.Insets = .{};
        if (popOf(opt.parent)) |pp| {
            parent_xdg = pp.xdg_surface;
            pm = pp.margin;
        } else if (opt.parent != w.window) return error.NoParent;
        const m = opt.margin;
        const bw = @max(size.w - m.left - m.right, 1);
        const bh = @max(size.h - m.top - m.bottom, 1);
        const win = try w.gpa.create(Window);
        errdefer w.gpa.destroy(win);
        win.* = .{ .size = size, .scale = @as(f32, @floatFromInt(w.scale120)) / 120.0 };
        const p = try w.gpa.create(Pop);
        errdefer w.gpa.destroy(p);
        const pos = try w.new(I.positioner, .main, 0);
        w.req(w.wm_base, 1, .{pos});
        w.req(pos, 1, .{ bw, bh });
        const a = opt.anchor;
        w.req(pos, 2, .{ a.x - pm.left, a.y - pm.top, @max(a.w, 1), @max(a.h, 1) });
        // Anchors and gravities: top_left 5, bottom_left 6, top_right 7, bottom_right 8.
        // Adjustments: slide_x 1, slide_y 2, flip_x 4, flip_y 8.
        const anchor: u32, const gravity: u32, const adjust: u32 = switch (opt.side) {
            .below => .{ 6, 8, 8 | 1 | 2 },
            .above => .{ 5, 7, 8 | 1 | 2 },
            .right => .{ 7, 8, 4 | 1 | 2 },
            .left => .{ 5, 6, 4 | 1 | 2 },
        };
        w.req(pos, 3, .{anchor});
        w.req(pos, 4, .{gravity});
        w.req(pos, 5, .{adjust});
        w.req(pos, 6, .{ opt.offset.x, opt.offset.y });
        const surface = try w.new(I.surface, .main, 0);
        w.req(w.compositor, 0, .{surface});
        const xs = try w.new(I.xdg_surface, .main, 0);
        w.req(w.wm_base, 2, .{ xs, surface });
        const xp = try w.new(I.popup, .main, 0);
        w.req(xs, 2, .{ xp, parent_xdg, pos });
        w.destroy(pos, 0);
        p.* = .{ .owner = w, .win = win, .surface = surface, .xdg_surface = xs, .popup = xp, .margin = m, .parent_margin = pm, .atlas = Atlas.init(w.gpa) };
        // The place before the configure: the box below or right of the anchor.
        win.pos = switch (opt.side) {
            .below, .left => .{ .x = a.x + opt.offset.x - m.left, .y = a.y + a.h + opt.offset.y - m.top },
            .right, .above => .{ .x = a.x + a.w + opt.offset.x - m.left, .y = a.y + opt.offset.y - m.top },
        };
        win.impl = p;
        w.req(xs, 3, .{ m.left, m.top, bw, bh });
        const serial = @atomicLoad(u32, &w.press_serial, .acquire);
        if (opt.grab and serial != 0 and w.seat != 0) w.req(xp, 1, .{ w.seat, serial });
        if (w.viewporter != 0) {
            p.viewport = try w.new(I.viewport, .main, 0);
            w.req(w.viewporter, 1, .{ p.viewport, surface });
        }
        w.lock.lock();
        w.pops.append(w.gpa, p) catch {
            w.lock.unlock();
            w.freePopup(p);
            return error.OutOfMemory;
        };
        w.lock.unlock();
        w.req(surface, 6, .{});
        var spins: u32 = 0;
        while (!p.configured and spins < 50) : (spins += 1) try w.roundtrip();
        return win;
    }

    fn freePopup(w: *Wayland, p: *Pop) void {
        if (p.frame_cb != 0) w.conn.destroyed(p.frame_cb);
        w.destroy(p.viewport, 0);
        w.destroy(p.popup, 0);
        w.destroy(p.xdg_surface, 0);
        w.destroy(p.surface, 0);
        for (p.bufs) |b| if (b) |buf| freeBuf(w, buf);
        p.atlas.deinit();
        const win = p.win;
        w.gpa.destroy(p);
        w.gpa.destroy(win);
        w.flush();
    }

    fn destroyPopup(w: *Wayland, p: *Pop) void {
        w.lock.lock();
        for (w.pops.items, 0..) |x, i| if (x == p) {
            _ = w.pops.orderedRemove(i);
            break;
        };
        if (w.ptr_win == p.win) w.ptr_win = null;
        // The queued events of the popup go away with it.
        var i: usize = 0;
        while (i < w.events.items.len) {
            if (w.events.items[i].window() == p.win) _ = w.events.orderedRemove(i) else i += 1;
        }
        w.lock.unlock();
        w.freePopup(p);
    }

    /// A buffer of a popup that the compositor released. The render thread
    /// draws a popup, and the UI thread reads the release events. So the
    /// draw waits up to 100 ms for a release, and does no roundtrip.
    fn popBuffer(w: *Wayland, p: *Pop, width: u32, height: u32) !*Buf {
        var tries: u32 = 0;
        while (tries < 100) : (tries += 1) {
            for (&p.bufs) |*slot| {
                if (slot.*) |b| {
                    if (@atomicLoad(bool, &b.busy, .acquire)) continue;
                    if (b.width == width and b.height == height) return b;
                    freeBuf(w, b);
                    slot.* = null;
                }
                slot.* = try w.makeBuf(width, height, shm_argb8888);
                return slot.*.?;
            }
            host.sleepUs(1000);
        }
        return error.NoFreeBuffer;
    }

    /// Draws one frame of a popup into a shared memory buffer with premultiplied alpha.
    fn drawPopup(ctx: *anyopaque, frame: *const Frame) anyerror!void {
        const p: *Pop = @ptrCast(@alignCast(ctx));
        const w = p.owner;
        for (frame.patches.items) |pa| try p.atlas.applyPatch(pa);
        if (!p.configured) return;
        const scene = &frame.scene;
        const need = @as(usize, scene.width) * scene.height * 4;
        const img = try w.gpa.alloc(u8, need);
        defer w.gpa.free(img);
        var cur: Image = .{ .width = scene.width, .height = scene.height, .pixels = img };
        cpu.render(scene, &p.atlas, &cur);
        const buf = try w.popBuffer(p, cur.width, cur.height);
        // RGBA to ARGB8888 (bytes B, G, R, A).
        var i: usize = 0;
        while (i < need) : (i += 4) {
            buf.data[i] = img[i + 2];
            buf.data[i + 1] = img[i + 1];
            buf.data[i + 2] = img[i];
            buf.data[i + 3] = img[i + 3];
        }
        if (p.viewport != 0) {
            w.req(p.viewport, 2, .{ p.win.size.w, p.win.size.h });
        } else if (w.compositor_version >= 3) {
            w.req(p.surface, 8, .{@as(i32, @intCast(w.int_scale))});
        }
        w.req(p.surface, 1, .{ buf.buffer, @as(i32, 0), @as(i32, 0) });
        w.req(p.surface, 9, .{ @as(i32, 0), @as(i32, 0), @as(i32, @intCast(cur.width)), @as(i32, @intCast(cur.height)) });
        @atomicStore(bool, &buf.busy, true, .release);
        w.req(p.surface, 6, .{});
        w.flush();
    }
};

test {
    _ = wire;
    _ = xkb;
}
