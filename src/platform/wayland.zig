//! The Wayland backend. It connects to the compositor of WAYLAND_DISPLAY
//! with its own client of the wire protocol (`wl/wire.zig`), so it links
//! no library and runs in a static program. It makes one xdg toplevel and
//! turns the events of the compositor into `Event` values. The pointer,
//! the keyboard (with the key map of the compositor, read by `wl/xkb.zig`),
//! the close request, the fractional scale, the focus, the clipboard, and
//! the text of an input method all become events.
//!
//! The main window renders with Vulkan when the compositor lists linear
//! XBGR8888 in `zwp_linux_dmabuf_v1` (version 3) and the device exports
//! dma-bufs. The Vulkan renderer draws into a ring of 3 exported linear
//! images, and each one is a `wl_buffer` from `create_immed`. A draw waits
//! for the queue, so the buffer is complete at the commit. A scene with the
//! hash of the last scene commits no buffer. Without the GPU path, or after
//! a failed Vulkan draw, the CPU renderer draws into a `wl_shm` buffer, and
//! stderr gets the cause once (`ztk: the CPU renderer: ...`). The CPU path
//! reports only the rows that changed as damage, and a draw with no
//! changed row commits no buffer. Each buffer has the scene size in device
//! pixels, and the scale goes to the compositor through `wp_viewporter`
//! (fractional scale) or `wl_surface.set_buffer_scale`. Key repeat runs inside the backend: `wait` and
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
//! text-input-unstable-v3, and linux-dmabuf-v1 (docs/references/wayland.md).
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const linux = std.os.linux;
const geom = @import("../base/geom.zig");
const event = @import("../base/event.zig");
const plat = @import("platform.zig");
const wire = @import("wl/wire.zig");
const dbus = @import("dbus.zig");
const portal = @import("portal.zig");
const sni = @import("sni.zig");
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
const Scene = @import("../scene.zig").Scene;
const vk_on = @import("build_options").vulkan;
const vulkan = if (vk_on) @import("../render/vulkan.zig") else @import("../render/vulkan_off.zig");

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
    const dmabuf: u16 = 31;
    const dmabuf_params: u16 = 32;
    const icon_mgr: u16 = 33;
    const icon: u16 = 34;
};

const shm_argb8888: u32 = 0;
const shm_xrgb8888: u32 = 1;

/// The MIME types of UTF-8 text on the clipboard, best first.
const text_types = [_][]const u8{ "text/plain;charset=utf-8", "UTF8_STRING", "text/plain", "STRING", "TEXT" };

/// A buffer of the GPU path: an exported Vulkan image and its `wl_buffer`.
const GpuBuf = if (vk_on) struct {
    target: *vulkan.Target,
    buffer: u32,
    width: u32,
    height: u32,
    busy: bool = false,
} else void;

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
const Offer = struct { id: u32, text_type: ?usize = null, uris: bool = false };

pub const Options = struct {
    /// XDG_RUNTIME_DIR and WAYLAND_DISPLAY.
    runtime_dir: ?[]const u8 = null,
    display: ?[]const u8 = null,
    /// ZTK_NO_INPUT_THREAD=1: the pointer stays on the queue of the UI thread.
    no_input_thread: bool = false,
    /// ZTK_WAYLAND_DEBUG=1: each event goes to stderr as its interface number, object, and opcode.
    debug: bool = false,
    /// ZTK_RENDERER: cpu, vulkan, or auto.
    renderer: Renderer = .auto,
    /// DBUS_SESSION_BUS_ADDRESS, for the portals. Null: `unix:path=` the
    /// file `bus` in the runtime folder.
    bus_address: ?[]const u8 = null,
    /// The app id of the toplevel. A compositor finds the `.desktop` file
    /// of this name. A bundled app has the name of its program file.
    app_id: []const u8 = "ztk",
};

/// The renderer of the main window. `auto` uses Vulkan when the device and
/// the compositor share dma-bufs, and else the CPU renderer. `vulkan` makes
/// `init` fail without the GPU path.
pub const Renderer = enum { auto, cpu, vulkan };

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
    dmabuf: u32 = 0,
    /// The global of `xdg-toplevel-icon-v1`, or 0 when the compositor has none.
    icon_mgr: u32 = 0,
    /// The icon of the toplevel and its buffers, which live until the next icon.
    icon: u32 = 0,
    icon_bufs: std.ArrayListUnmanaged(*Buf) = .empty,
    /// The compositor lists XBGR8888 with the linear modifier.
    dmabuf_linear: bool = false,
    /// The GPU path of the main window, with a ring of 3 buffers.
    gpu: if (vk_on) ?*vulkan.Vulkan else void = if (vk_on) null else {},
    gbufs: [3]?*GpuBuf = .{ null, null, null },
    /// A hash of the last scene that the GPU path drew, to skip a frame with no change.
    scene_hash: u64 = 0,
    /// The session bus, for the portals: opened at the first dialog.
    bus: ?*dbus.Conn = null,
    bus_failed: bool = false,
    /// The setting for less motion of the portal, read once, and then
    /// from its `SettingChanged` signals.
    less_motion: ?bool = null,
    motion_read: bool = false,
    /// The tray icons (StatusNotifierItem), after the first `trayCreate`.
    tray: ?sni.Tray = null,
    /// True while a portal call waits on the bus: the poll leaves the bus alone.
    bus_wait: bool = false,
    /// The state of `wm attributes` that the backend sent.
    win_state: plat.WindowState = .{},
    /// The version of `wl_data_device_manager`.
    data_version: u32 = 0,
    /// The kinds of drops that the main window accepts, and the drag of
    /// another app over it: its offer, the MIME type, and the data of the
    /// last drop, which lives until the next poll.
    drop_types: plat.DropTypes = .{},
    drag_offer: u32 = 0,
    drag_mime: ?[]const u8 = null,
    drop_data: []u8 = &.{},
    /// A drag out of a window (`ztk::dnd drag`): its data source, the
    /// data as a `text/uri-list` and as text, and the answer of the target.
    out_source: u32 = 0,
    out_uris: []u8 = &.{},
    out_text: []const u8 = "",
    out_action: u32 = 0,
    out_done: bool = false,
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
        try w.startGpu();
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
        w.dropIcon();
        w.icon_bufs.deinit(w.gpa);
        if (vk_on) if (w.gpu) |v| {
            for (w.gbufs) |b| if (b) |gb| w.freeGpuBuf(v, gb);
            v.deinit();
        };
        if (w.dmabuf != 0) w.destroy(w.dmabuf, 0);
        if (w.tray) |*t| t.deinit();
        if (w.bus) |b| b.deinit();
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
        w.gpa.free(w.drop_data);
        w.offers.deinit(w.gpa);
        w.ime_preedit.deinit(w.gpa);
        w.ime_commit.deinit(w.gpa);
        for (&w.ime_out) |*o| o.deinit(w.gpa);
        w.events.deinit(w.gpa);
        w.pops.deinit(w.gpa);
        w.gpa.destroy(w);
    }

    pub fn platform(w: *Wayland) Platform {
        return .{ .ptr = w, .vtable = if (w.portalFiles()) &vtable_portal else &vtable, .live = true, .popups = true };
    }

    const vtable: Platform.VTable = .{
        .deinit = vDeinit,
        .createWindow = vCreateWindow,
        .destroyWindow = vDestroyWindow,
        .setTitle = vSetTitle,
        .setIcon = vSetIcon,
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
        .setWindowState = vSetWindowState,
        .reducedMotion = vReducedMotion,
        .dropTypes = vDropTypes,
        .dragStart = vDragStart,
        .trayCreate = vTrayCreate,
        .traySet = vTraySet,
        .trayDrop = vTrayDrop,
    };

    /// With a file chooser portal: `tk_getOpenFile` and the others use it.
    /// Without one, the core draws the file dialogs.
    const vtable_portal: Platform.VTable = blk: {
        var v = vtable;
        v.fileDialog = vFileDialog;
        break :blk v;
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
            .{ .fd = -1, .events = linux.POLL.IN, .revents = 0 },
        };
        // The session bus, when the backend reads its SettingChanged signals.
        if ((w.motion_read or w.tray != null) and !w.bus_wait) if (w.bus) |b| {
            pfd[2].fd = b.fd;
        };
        const r = linux.poll(&pfd, 3, ms);
        if (@as(isize, @bitCast(r)) <= 0) return false;
        drainFd(w.wake_ui[0]);
        if (pfd[2].fd >= 0 and pfd[2].revents != 0) w.onBus();
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
            I.dmabuf => if (e.op == 1) {
                const format = a.uint();
                const hi = a.uint();
                const lo = a.uint();
                if (format == vulkan.drm_format_xbgr8888 and (@as(u64, hi) << 32 | lo) == vulkan.drm_mod_linear) w.dmabuf_linear = true;
            },
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
            w.data_version = @min(version, 3);
            w.data_mgr = try w.bind(name, i, I.data_mgr, w.data_version, 0);
            w.makeDevices();
        } else if (std.mem.eql(u8, i, "zwp_linux_dmabuf_v1") and version >= 3) {
            // Version 3 sends the modifiers as events. Version 4 moves them to a feedback table.
            w.dmabuf = try w.bind(name, i, I.dmabuf, 3, 0);
        } else if (std.mem.eql(u8, i, "xdg_toplevel_icon_manager_v1")) {
            w.icon_mgr = try w.bind(name, i, I.icon_mgr, 1, 0);
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
        w.req(w.toplevel, 3, .{wire.Str{ .s = w.opts.app_id }});
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

    /// The icon of the toplevel with `xdg-toplevel-icon-v1`: one `wl_shm`
    /// buffer of ARGB8888 for each photo. The protocol needs a square
    /// buffer, so a photo that is not square goes in the middle of a clear
    /// square. The icon applies at the next commit of the surface. A
    /// compositor without the protocol shows the icon of the `.desktop`
    /// file of the app id.
    fn vSetIcon(ptr: *anyopaque, win: *Window, icons: []const plat.TrayIcon, _: bool) void {
        const w = self(ptr);
        if (w.icon_mgr == 0 or w.toplevel == 0 or popOf(win) != null) return;
        w.dropIcon();
        w.icon = w.new(I.icon, .main, 0) catch return;
        w.req(w.icon_mgr, 1, .{w.icon});
        for (icons) |ic| {
            const side = @max(ic.width, ic.height);
            if (side == 0) continue;
            const b = w.makeBuf(side, side, shm_argb8888) catch continue;
            w.icon_bufs.append(w.gpa, b) catch {
                w.freeBuf(b);
                continue;
            };
            fillIcon(b.data, side, ic);
            w.req(w.icon, 2, .{ b.buffer, @as(i32, 1) });
        }
        w.req(w.icon_mgr, 2, .{ w.toplevel, w.icon });
        vRequestFrame(ptr, win);
        w.flush();
    }

    /// Copies a photo into a square buffer of `side` pixels: premultiplied
    /// alpha in the byte order B, G, R, A of ARGB8888, with the photo in
    /// the middle.
    fn fillIcon(data: []u8, side: u32, ic: plat.TrayIcon) void {
        @memset(data, 0);
        const ox = (side - ic.width) / 2;
        const oy = (side - ic.height) / 2;
        for (0..ic.height) |y| for (0..ic.width) |x| {
            const s = ic.pixels[(y * ic.width + x) * 4 ..][0..4];
            const d = data[((y + oy) * side + x + ox) * 4 ..][0..4];
            const a: u32 = s[3];
            d[0] = @intCast((@as(u32, s[2]) * a + 127) / 255);
            d[1] = @intCast((@as(u32, s[1]) * a + 127) / 255);
            d[2] = @intCast((@as(u32, s[0]) * a + 127) / 255);
            d[3] = s[3];
        };
    }

    /// Destroys the icon object and then its buffers, as the protocol
    /// needs the buffers while the icon exists.
    fn dropIcon(w: *Wayland) void {
        w.destroy(w.icon, 0);
        w.icon = 0;
        for (w.icon_bufs.items) |b| w.freeBuf(b);
        w.icon_bufs.clearRetainingCapacity();
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
        // The data of the last drop lived until this poll.
        if (w.events.items.len == 0) {
            w.gpa.free(w.drop_data);
            w.drop_data = &.{};
        }
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
        // A seat that loses its pointer or its keyboard makes the object
        // inert. Release it, so that a new device gets a new object.
        if (caps & 1 == 0 and w.pointer != 0) {
            if (w.cursor_device != 0) w.destroy(w.cursor_device, 0);
            w.cursor_device = 0;
            // Request 1 of wl_pointer (version 3) is release.
            w.destroy(w.pointer, 1);
            w.pointer = 0;
            w.lock.lock();
            w.buttons = 0;
            w.lock.unlock();
        }
        if (caps & 2 == 0 and w.keyboard != 0) {
            w.destroy(w.keyboard, 0);
            w.keyboard = 0;
            w.repeat_key = null;
        }
        if (caps & 1 != 0 and w.pointer == 0) {
            w.pointer = w.new(I.pointer, .main, 0) catch return;
            w.req(w.seat, 0, .{w.pointer});
            if (w.cursor_mgr != 0) {
                w.cursor_device = w.new(I.cursor_dev, .main, 0) catch 0;
                w.req(w.cursor_mgr, 1, .{ w.cursor_device, w.pointer });
            }
            if (w.input_thread != null) w.conn.setQueue(w.pointer, .input) else w.startInput();
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
            1 => w.onDragEnter(a),
            3 => if (w.drag_offer != 0) {
                _ = a.uint();
                const x = a.fixed();
                const y = a.fixed();
                if (w.window) |win| w.push(.{ .drop = .{ .window = win, .phase = .over, .x = x, .y = y } });
            },
            // The offer of a drag ends with leave or drop.
            2 => {
                if (w.drag_offer != 0) if (w.window) |win| w.push(.{ .drop = .{ .window = win, .phase = .leave } });
                w.drag_offer = 0;
                w.dropOffers(null);
            },
            4 => {
                if (w.drag_offer != 0) w.onDrop();
                w.drag_offer = 0;
                w.dropOffers(null);
            },
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

    // ---- Drops from other apps ----

    fn vDropTypes(ptr: *anyopaque, win: *Window, types: plat.DropTypes) void {
        const w = self(ptr);
        if (popOf(win) != null) return;
        w.drop_types = types;
    }

    /// A drag enters a surface: accept a MIME type of the kinds of the main
    /// window, or none.
    fn onDragEnter(w: *Wayland, a: *wire.Args) void {
        const serial = a.uint();
        const surface = a.uint();
        const x = a.fixed();
        const y = a.fixed();
        const id = a.uint();
        w.drag_offer = 0;
        w.drag_mime = null;
        if (id == 0) return;
        const offer = for (w.offers.items) |o| {
            if (o.id == id) break o;
        } else return;
        const win = w.window orelse return;
        if (surface == w.surface) {
            if (w.drop_types.files and offer.uris) {
                w.drag_mime = "text/uri-list";
            } else if (w.drop_types.text) if (offer.text_type) |rank| {
                w.drag_mime = text_types[rank];
            };
        }
        w.req(id, 0, .{ serial, wire.Str{ .s = w.drag_mime } });
        if (w.drag_mime == null) return;
        // Version 3: the action is copy.
        if (w.data_version >= 3) w.req(id, 4, .{ @as(u32, 1), @as(u32, 1) });
        w.flush();
        w.drag_offer = id;
        w.push(.{ .drop = .{ .window = win, .phase = .enter, .x = x, .y = y } });
    }

    /// Reads the data of a drop through a pipe and gives the drop event.
    fn onDrop(w: *Wayland) void {
        const win = w.window orelse return;
        const mime = w.drag_mime orelse return;
        var fds: [2]i32 = .{ -1, -1 };
        if (@as(isize, @bitCast(linux.pipe2(&fds, .{ .CLOEXEC = true }))) < 0) return;
        defer _ = linux.close(fds[0]);
        // The send closes the write end after the flush.
        if (w.out_source == 0) {
            w.req(w.drag_offer, 1, .{ wire.Str{ .s = mime }, wire.Fd{ .fd = fds[1] } });
            w.flush();
        }
        var data: std.ArrayListUnmanaged(u8) = .empty;
        defer data.deinit(w.gpa);
        var buf: [4096]u8 = undefined;
        // A drop of a drag of this app: this thread is the source, so the
        // data cannot come through the pipe.
        if (w.out_source != 0) {
            _ = linux.close(fds[1]);
            data.appendSlice(w.gpa, if (std.mem.eql(u8, mime, "text/uri-list")) w.out_uris else w.out_text) catch return;
        } else while (data.items.len < 64 << 20) {
            var pfd = [1]linux.pollfd{.{ .fd = fds[0], .events = linux.POLL.IN, .revents = 0 }};
            if (@as(isize, @bitCast(linux.poll(&pfd, 1, 2000))) <= 0) break;
            const rc = linux.read(fds[0], &buf, buf.len);
            if (@as(isize, @bitCast(rc)) <= 0) break;
            data.appendSlice(w.gpa, buf[0..rc]) catch break;
        }
        if (w.data_version >= 3) w.req(w.drag_offer, 3, .{});
        w.gpa.free(w.drop_data);
        w.drop_data = &.{};
        const files = std.mem.eql(u8, mime, "text/uri-list");
        w.drop_data = (if (files) uriListPaths(w.gpa, data.items) else w.gpa.dupe(u8, data.items)) catch return;
        w.push(.{ .drop = .{ .window = win, .phase = .drop, .files = if (files) w.drop_data else "", .text = if (files) "" else w.drop_data } });
    }

    // ---- Drags out of a window ----

    /// Runs a drag of files or text to its end. The drag needs the serial of
    /// the press that holds the pointer, so a script starts it from a
    /// binding of a button motion.
    fn vDragStart(ptr: *anyopaque, win: *Window, d: plat.DragData) plat.DragAction {
        const w = self(ptr);
        // Version 3 has the actions and the end of a drop.
        if (w.data_device == 0 or w.data_version < 3 or w.out_source != 0) return .none;
        const serial = @atomicLoad(u32, &w.press_serial, .acquire);
        const surface = if (popOf(win)) |p| p.surface else w.surface;
        if (serial == 0 or surface == 0) return .none;
        var uris: std.ArrayListUnmanaged(u8) = .empty;
        for (d.files) |f| {
            portal.appendFileUri(w.gpa, &uris, f) catch return .none;
            uris.appendSlice(w.gpa, "\r\n") catch return .none;
        }
        w.out_uris = uris.toOwnedSlice(w.gpa) catch return .none;
        w.out_text = d.text;
        w.out_action = 0;
        w.out_done = false;
        defer {
            w.gpa.free(w.out_uris);
            w.out_uris = &.{};
            w.out_text = "";
        }
        // Event 1 (send) has a file descriptor.
        const src = w.new(I.data_source, .main, 2) catch return .none;
        w.out_source = src;
        w.req(w.data_mgr, 0, .{src});
        if (d.files.len > 0) w.req(src, 0, .{wire.Str{ .s = "text/uri-list" }});
        if (d.text.len > 0) for (text_types) |t| w.req(src, 0, .{wire.Str{ .s = t }});
        // Request 2: set_actions, copy (1) and move (2).
        w.req(src, 2, .{@as(u32, if (d.allow_move) 3 else 1)});
        // Request 0 of wl_data_device: start_drag(source, origin, icon, serial).
        w.req(w.data_device, 0, .{ src, surface, @as(u32, 0), serial });
        w.flush();
        while (!w.out_done) {
            w.dispatchMain();
            if (w.out_done) break;
            _ = w.readWait(100) catch break;
        }
        w.destroy(src, 1);
        w.out_source = 0;
        // The compositor keeps the release of the button for the drag: the
        // window gets it here, so that the core has no held button.
        w.lock.lock();
        const held = w.buttons;
        w.buttons = 0;
        w.lock.unlock();
        for (0..3) |i| if (held & (@as(u8, 1) << @intCast(i)) != 0) {
            w.push(.{ .button = .{ .window = win, .button = @intCast(i + 1), .pressed = false, .x = w.px, .y = w.py, .mods = w.currentMods(), .time_ms = timeMs() } });
        };
        return switch (w.out_action) {
            1 => .copy,
            2 => .move,
            else => .none,
        };
    }

    /// The events of the source of a drag out of a window.
    fn onDragSource(w: *Wayland, op: u16, a: *wire.Args) void {
        switch (op) {
            1 => {
                const mime = a.string() orelse "";
                const fd = a.fd();
                if (fd < 0) return;
                defer _ = linux.close(fd);
                const data = if (std.mem.eql(u8, mime, "text/uri-list")) w.out_uris else w.out_text;
                var off: usize = 0;
                while (off < data.len) {
                    const rc = linux.write(fd, data[off..].ptr, data.len - off);
                    if (@as(isize, @bitCast(rc)) <= 0) break;
                    off += rc;
                }
            },
            // cancelled: no target took the drop. wlroots also sends it
            // after dnd_finished, when the drag ends.
            2 => {
                if (!w.out_done) w.out_action = 0;
                w.out_done = true;
            },
            // dnd_finished: the target read the data.
            4 => w.out_done = true,
            // action: the action that the compositor chose.
            5 => w.out_action = a.uint(),
            else => {},
        }
    }

    /// The paths of the `file://` URIs of a `text/uri-list`, separated by 0.
    /// The lines end with CR LF, and a line that starts with `#` is a comment.
    fn uriListPaths(gpa: std.mem.Allocator, list: []const u8) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(gpa);
        var it = std.mem.tokenizeAny(u8, list, "\r\n");
        while (it.next()) |line| {
            if (line[0] == '#') continue;
            const p = try portal.uriPath(gpa, line) orelse continue;
            defer gpa.free(p);
            if (out.items.len > 0) try out.append(gpa, 0);
            try out.appendSlice(gpa, p);
        }
        return out.toOwnedSlice(gpa);
    }

    /// Destroys the offers that wait, except one.
    fn dropOffers(w: *Wayland, keep: ?u32) void {
        for (w.offers.items) |o| if (keep == null or o.id != keep.?) w.destroyOffer(o.id);
        w.offers.clearRetainingCapacity();
    }

    fn onOfferType(w: *Wayland, id: u32, mime: []const u8) void {
        if (std.mem.eql(u8, mime, "text/uri-list")) {
            for (w.offers.items) |*o| if (o.id == id) {
                o.uris = true;
            };
            return;
        }
        const rank = for (text_types, 0..) |t, i| {
            if (std.mem.eql(u8, t, mime)) break i;
        } else return;
        for (w.offers.items) |*o| if (o.id == id) {
            if (o.text_type == null or rank < o.text_type.?) o.text_type = rank;
        };
    }

    fn onSource(w: *Wayland, id: u32, op: u16, a: *wire.Args) void {
        if (id == w.out_source) return w.onDragSource(op, a);
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
        if (vk_on) for (w.gbufs) |b| if (b) |gb| if (gb.buffer == id) {
            @atomicStore(bool, &gb.busy, false, .release);
            return;
        };
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
        if (vk_on) if (w.gpu) |v| {
            if (w.drawGpu(v, win, scene)) return else |e| w.stopGpu(e);
        };
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
        @atomicStore(bool, &buf.busy, true, .release);
        w.commit(win, buf.buffer, cur.width, cur.height, damage);
    }

    /// Attaches a buffer to the main surface with its scale and damage, and
    /// commits it. No damage range means the whole buffer.
    fn commit(w: *Wayland, win: *Window, buffer: u32, width: u32, height: u32, damage: []const renderer.RowRange) void {
        const surface = w.surface;
        // The scale: a viewport for the fractional scale, or the integer buffer scale.
        if (w.viewport != 0) {
            w.req(w.viewport, 2, .{ win.size.w, win.size.h });
        } else if (w.compositor_version >= 3) {
            w.req(surface, 8, .{@as(i32, @intCast(w.int_scale))});
        }
        w.req(surface, 1, .{ buffer, @as(i32, 0), @as(i32, 0) });
        if (damage.len == 0) {
            w.req(surface, 9, .{ @as(i32, 0), @as(i32, 0), @as(i32, @intCast(width)), @as(i32, @intCast(height)) });
        } else for (damage) |d| {
            w.req(surface, 9, .{ @as(i32, 0), @as(i32, @intCast(d.first)), @as(i32, @intCast(width)), @as(i32, @intCast(d.last - d.first)) });
        }
        w.req(surface, 6, .{});
        w.frames_committed += 1;
        w.flush();
    }

    // ---- The portals ----

    /// The session bus, opened once. A failure prints its cause once.
    fn sessionBus(w: *Wayland) ?*dbus.Conn {
        if (w.bus) |b| return b;
        if (w.bus_failed) return null;
        var buf: [300]u8 = undefined;
        const addr = w.opts.bus_address orelse blk: {
            const dir = w.opts.runtime_dir orelse "";
            break :blk std.fmt.bufPrint(&buf, "unix:path={s}/bus", .{dir}) catch "";
        };
        w.bus = dbus.Conn.connect(w.gpa, addr) catch |e| {
            w.bus_failed = true;
            std.debug.print("ztk: no session bus, so ztk draws the file dialogs: {s}\n", .{@errorName(e)});
            return null;
        };
        return w.bus;
    }

    /// Whether the session bus has the desktop portal, running or activatable.
    fn portalFiles(w: *Wayland) bool {
        const bus = w.sessionBus() orelse return false;
        return hasName(w.gpa, bus, "NameHasOwner", "org.freedesktop.portal.Desktop") or hasName(w.gpa, bus, "ListActivatableNames", "org.freedesktop.portal.Desktop");
    }

    fn hasName(gpa: std.mem.Allocator, bus: *dbus.Conn, member: []const u8, name: []const u8) bool {
        var b: dbus.Writer = .{ .gpa = gpa };
        defer b.deinit();
        const ask = std.mem.eql(u8, member, "NameHasOwner");
        if (ask) b.string(name);
        const reply = bus.call(.{ .destination = "org.freedesktop.DBus", .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus", .member = member, .signature = if (ask) "s" else "", .body = b.bytes() catch return false }, 2000) catch return false;
        defer reply.deinit(gpa);
        var r = reply.reader();
        if (ask) return r.boolean() catch false;
        const end = r.beginArray(4) catch return false;
        while (r.pos < end) {
            const n = r.string() catch return false;
            if (std.mem.eql(u8, n, name)) return true;
        }
        return false;
    }

    /// Reads one message of the session bus, and the signals that waited.
    /// A change of the setting for less motion gives an appearance event.
    fn onBus(w: *Wayland) void {
        const bus = w.bus orelse return;
        if (bus.read(100)) |m| {
            if (m.type == .signal) bus.pending.append(w.gpa, m) catch m.deinit(w.gpa) else bus.other(m);
        } else |e| {
            if (e != error.Timeout) {
                bus.deinit();
                w.bus = null;
                return;
            }
        }
        if (w.tray) |*t| w.onTray(bus, t);
        var k: usize = 0;
        while (k < bus.pending.items.len) {
            const m = bus.pending.items[k];
            if (!std.mem.eql(u8, m.member, "SettingChanged")) {
                k += 1;
                continue;
            }
            _ = bus.pending.orderedRemove(k);
            defer m.deinit(w.gpa);
            if (portal.motionChange(m.body)) |v| if (w.less_motion != v) {
                w.less_motion = v;
                if (w.window) |win| w.push(.{ .appearance = .{ .window = win } });
            };
        }
    }

    // ---- Tray icons ----

    fn vTrayCreate(ptr: *anyopaque, _: *Window, icon: plat.TrayIcon, _: bool, tooltip: []const u8) plat.TrayId {
        const w = self(ptr);
        const bus = w.sessionBus() orelse return 0;
        if (w.tray == null) {
            w.tray = .{ .gpa = w.gpa, .app_id = w.opts.app_id };
            bus.objects = .{ .ctx = &w.tray.?, .call = sni.Tray.handle };
            bus.addMatch(sni.watcher_rule) catch {};
        }
        return w.tray.?.create(bus, linux.getpid(), icon, tooltip);
    }

    fn vTraySet(ptr: *anyopaque, id: plat.TrayId, icon: plat.TrayIcon, _: bool, tooltip: []const u8, _: plat.MenuId) void {
        const w = self(ptr);
        const bus = w.bus orelse return;
        if (w.tray) |*t| t.set(bus, id, icon, tooltip);
    }

    fn vTrayDrop(ptr: *anyopaque, id: plat.TrayId) void {
        const w = self(ptr);
        const bus = w.bus orelse return;
        if (w.tray) |*t| t.drop(bus, id);
    }

    /// After a read of the bus: registers the icons with a new watcher,
    /// and gives the actions of the host as `tray` events.
    fn onTray(w: *Wayland, bus: *dbus.Conn, t: *sni.Tray) void {
        var k: usize = 0;
        while (k < bus.pending.items.len) {
            const m = bus.pending.items[k];
            if (!std.mem.eql(u8, m.member, "NameOwnerChanged")) {
                k += 1;
                continue;
            }
            _ = bus.pending.orderedRemove(k);
            defer m.deinit(w.gpa);
            if (sni.watcherCame(&m)) t.registerAll(bus);
        }
        const win = w.window orelse {
            t.actions.clearRetainingCapacity();
            return;
        };
        for (t.actions.items) |a| w.push(.{ .tray = .{ .window = win, .id = a.id, .action = a.action } });
        t.actions.clearRetainingCapacity();
    }

    fn vReducedMotion(ptr: *anyopaque) bool {
        const w = self(ptr);
        if (!w.motion_read) {
            w.motion_read = true;
            if (w.sessionBus()) |bus| {
                w.less_motion = portal.reducedMotion(w.gpa, bus);
                bus.addMatch(portal.setting_rule) catch {};
            }
        }
        return w.less_motion orelse false;
    }

    /// Full screen with `xdg_toplevel.set_fullscreen` on the output of the
    /// compositor's choice. Wayland has no request for topmost, so the
    /// backend keeps that value only.
    fn vSetWindowState(ptr: *anyopaque, win: *Window, s: plat.WindowState) void {
        const w = self(ptr);
        if (popOf(win) != null or w.toplevel == 0) return;
        if (s.fullscreen != w.win_state.fullscreen) {
            if (s.fullscreen) w.req(w.toplevel, 11, .{@as(u32, 0)}) else w.req(w.toplevel, 12, .{});
            w.flush();
        }
        w.win_state = s;
    }

    /// Reads the events of the compositor while a portal dialog is open,
    /// so the window answers the pings of `xdg_wm_base`.
    fn idleDispatch(ctx: *anyopaque) void {
        const w: *Wayland = @ptrCast(@alignCast(ctx));
        _ = w.readWait(0) catch {};
        w.dispatchMain();
    }

    fn vFileDialog(ptr: *anyopaque, gpa: std.mem.Allocator, opts: *const plat.FileDialog) ?plat.FileDialogResult {
        const w = self(ptr);
        const bus = w.sessionBus() orelse return null;
        w.bus_wait = true;
        defer w.bus_wait = false;
        return portal.fileDialog(gpa, bus, opts, "", .{ .ctx = w, .run = idleDispatch }) catch |e| {
            std.debug.print("ztk: the file chooser portal failed: {s}\n", .{@errorName(e)});
            if (e == error.Disconnected or e == error.BadMessage) {
                bus.deinit();
                w.bus = null;
            }
            return null;
        };
    }

    // ---- Drawing with Vulkan into dma-bufs ----

    /// Prints the cause of the CPU path once to stderr.
    fn cpuNote(comptime fmt: []const u8, args: anytype) void {
        std.debug.print("ztk: the CPU renderer: " ++ fmt ++ "\n", args);
    }

    /// Opens Vulkan for the main window when the compositor accepts linear
    /// dma-bufs. Else the window uses the CPU renderer and stderr gets the cause.
    fn startGpu(w: *Wayland) !void {
        if (w.opts.renderer == .cpu) return;
        if (!vk_on) {
            cpuNote("{s}", .{vulkan.reason()});
        } else if (w.dmabuf == 0) {
            cpuNote("the compositor has no zwp_linux_dmabuf_v1 version 3", .{});
        } else if (!w.dmabuf_linear) {
            cpuNote("the compositor lists no linear XBGR8888 dma-buf", .{});
        } else if (vulkan.Vulkan.init(w.gpa, .{})) |v| {
            if (!v.canExport()) {
                cpuNote("{s} has no dma-buf export", .{v.deviceName()});
            } else if (v.createExported(16, 16)) |probe| {
                // A device can list the extensions and still fail to allocate the memory.
                v.destroyTarget(probe);
                w.gpu = v;
                return;
            } else |e| {
                if (e == error.NoExport) cpuNote("{s}", .{vulkan.reason()}) else cpuNote("Vulkan: {s}", .{@errorName(e)});
            }
            v.deinit();
        } else |e| {
            const r = vulkan.reason();
            if (r.len > 0) cpuNote("Vulkan: {s}: {s}", .{ @errorName(e), r }) else cpuNote("Vulkan: {s}", .{@errorName(e)});
        }
        if (w.opts.renderer == .vulkan) return error.NoGpu;
    }

    /// Stops the GPU path after a failed draw. The next frames use the CPU renderer.
    fn stopGpu(w: *Wayland, e: anyerror) void {
        if (!vk_on) return;
        const v = w.gpu orelse return;
        cpuNote("a Vulkan draw failed: {s}", .{@errorName(e)});
        for (&w.gbufs) |*b| if (b.*) |gb| {
            w.freeGpuBuf(v, gb);
            b.* = null;
        };
        v.deinit();
        w.gpu = null;
        // The CPU path draws the whole next frame.
        if (w.prev) |p| w.gpa.free(p.pixels);
        w.prev = null;
    }

    fn freeGpuBuf(w: *Wayland, v: *vulkan.Vulkan, b: *GpuBuf) void {
        w.destroy(b.buffer, 0);
        v.destroyTarget(b.target);
        w.gpa.destroy(b);
    }

    /// An exported image and a `wl_buffer` of it from `zwp_linux_buffer_params_v1`.
    fn makeGpuBuf(w: *Wayland, v: *vulkan.Vulkan, width: u32, height: u32) !*GpuBuf {
        const t = try v.createExported(width, height);
        errdefer v.destroyTarget(t);
        const b = try w.gpa.create(GpuBuf);
        errdefer w.gpa.destroy(b);
        // The send closes its descriptor after the flush, and the target keeps its own.
        const dup = linux.dup(t.fd);
        if (@as(isize, @bitCast(dup)) < 0) return error.DupFailed;
        const params = try w.new(I.dmabuf_params, .main, 0);
        w.req(w.dmabuf, 1, .{params});
        const mod = vulkan.drm_mod_linear;
        w.req(params, 1, .{ wire.Fd{ .fd = @intCast(dup) }, @as(u32, 0), t.offset, t.stride, @as(u32, @truncate(mod >> 32)), @as(u32, @truncate(mod)) });
        const buffer = try w.new(I.buffer, .main, 0);
        w.req(params, 3, .{ buffer, @as(i32, @intCast(width)), @as(i32, @intCast(height)), vulkan.drm_format_xbgr8888, @as(u32, 0) });
        w.destroy(params, 0);
        b.* = .{ .target = t, .buffer = buffer, .width = width, .height = height };
        return b;
    }

    /// A buffer of the ring that the compositor released, of the size of the frame.
    fn gpuBufferFor(w: *Wayland, v: *vulkan.Vulkan, width: u32, height: u32) !*GpuBuf {
        var spins: u32 = 0;
        while (true) : (spins += 1) {
            for (&w.gbufs) |*slot| if (slot.*) |b| {
                if (@atomicLoad(bool, &b.busy, .acquire)) continue;
                if (b.width == width and b.height == height) return b;
                w.freeGpuBuf(v, b);
                slot.* = null;
            };
            for (&w.gbufs) |*slot| if (slot.* == null) {
                slot.* = try w.makeGpuBuf(v, width, height);
                return slot.*.?;
            };
            // Each buffer is busy: wait for a release.
            if (spins == 100) return error.NoFreeBuffer;
            try w.roundtrip();
        }
    }

    fn sceneHash(scene: *const Scene, atlas: *const Atlas) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.sliceAsBytes(scene.quads.items));
        h.update(std.mem.asBytes(&scene.clear));
        h.update(std.mem.asBytes(&[4]u32{ scene.width, scene.height, atlas.generation, atlas.images.generation }));
        return h.final();
    }

    /// Draws one frame with Vulkan into a dma-buf and commits it. A scene
    /// that equals the last one commits no buffer.
    fn drawGpu(w: *Wayland, v: *vulkan.Vulkan, win: *Window, scene: *const Scene) !void {
        const h = sceneHash(scene, &w.atlas);
        if (h == w.scene_hash) return;
        const b = try w.gpuBufferFor(v, scene.width, scene.height);
        v.setTarget(b.target);
        try v.draw(scene, &w.atlas);
        w.scene_hash = h;
        @atomicStore(bool, &b.busy, true, .release);
        w.commit(win, b.buffer, scene.width, scene.height, &.{});
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

test "wayland: a uri-list gives the paths of its file URIs" {
    const t = std.testing;
    const got = try Wayland.uriListPaths(t.allocator, "# a comment\r\nfile:///tmp/a%20b.txt\r\nhttps://x.org/y\r\nfile:///srv/c\r\n");
    defer t.allocator.free(got);
    try t.expectEqualStrings("/tmp/a b.txt\x00/srv/c", got);
}
