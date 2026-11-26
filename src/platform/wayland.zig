//! The Wayland backend. It connects to the compositor of WAYLAND_DISPLAY
//! with the C client library, makes one xdg toplevel, and turns the
//! events of the compositor into `Event` values. The pointer, the
//! keyboard (with the key map of `xkbcommon`), the close request, the
//! fractional scale, and the focus all become events. The CPU renderer
//! draws into a `wl_shm` buffer. The buffer has the scene size in device
//! pixels, and the scale goes to the compositor through `wp_viewporter`
//! (fractional scale) or `wl_surface.set_buffer_scale`. A draw reports
//! only the rows that changed as damage, and a draw with no changed row
//! commits no buffer. Key repeat runs inside the backend: `wait` and
//! `poll` use the time of the next repeat. The Vulkan swapchain is not
//! part of this file (see docs/dev/tasks/BLOCKED.md).
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
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const geom = @import("../geom.zig");
const event = @import("../event.zig");
const plat = @import("platform.zig");
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

const c = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("xdg-shell-client-protocol.h");
    @cInclude("xdg-decoration-unstable-v1-client-protocol.h");
    @cInclude("viewporter-client-protocol.h");
    @cInclude("fractional-scale-v1-client-protocol.h");
    @cInclude("cursor-shape-v1-client-protocol.h");
    @cInclude("xkbcommon/xkbcommon.h");
    @cInclude("sys/mman.h");
    @cInclude("sys/syscall.h");
    @cInclude("unistd.h");
    @cInclude("poll.h");
    @cInclude("errno.h");
});

const Buf = struct {
    buffer: ?*c.wl_buffer = null,
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
    surface: *c.wl_surface,
    xdg_surface: *c.xdg_surface,
    popup: *c.xdg_popup,
    viewport: ?*c.wp_viewport = null,
    /// The margin of the surface around the window geometry, and the margin of the parent.
    margin: geom.Insets,
    parent_margin: geom.Insets,
    configured: bool = false,
    frame_cb: ?*c.wl_callback = null,
    bufs: [3]?*Buf = .{ null, null, null },
    atlas: Atlas,
};

pub const Wayland = struct {
    gpa: std.mem.Allocator,
    display: *c.wl_display,
    registry: ?*c.wl_registry = null,
    compositor: ?*c.wl_compositor = null,
    compositor_version: u32 = 0,
    wm_base: ?*c.xdg_wm_base = null,
    seat: ?*c.wl_seat = null,
    shm: ?*c.wl_shm = null,
    viewporter: ?*c.wp_viewporter = null,
    fractional_mgr: ?*c.wp_fractional_scale_manager_v1 = null,
    decoration_mgr: ?*c.zxdg_decoration_manager_v1 = null,
    cursor_mgr: ?*c.wp_cursor_shape_manager_v1 = null,
    pointer: ?*c.wl_pointer = null,
    keyboard: ?*c.wl_keyboard = null,
    cursor_device: ?*c.wp_cursor_shape_device_v1 = null,
    surface: ?*c.wl_surface = null,
    xdg_surface: ?*c.xdg_surface = null,
    toplevel: ?*c.xdg_toplevel = null,
    viewport: ?*c.wp_viewport = null,
    fractional: ?*c.wp_fractional_scale_v1 = null,
    window: ?*Window = null,
    configured: bool = false,
    first_frame_sent: bool = false,
    frame_cb: ?*c.wl_callback = null,
    scale120: u32 = 120,
    int_scale: u32 = 1,
    events: std.ArrayListUnmanaged(Event) = .empty,
    bufs: [2]?*Buf = .{ null, null },
    prev: ?Image = null,
    px: f32 = 0,
    py: f32 = 0,
    buttons: u8 = 0,
    mods: Mods = .{},
    xkb_ctx: ?*c.xkb_context = null,
    xkb_keymap: ?*c.xkb_keymap = null,
    xkb_state: ?*c.xkb_state = null,
    repeat_rate: i32 = 25,
    repeat_delay: i32 = 600,
    repeat_key: ?u32 = null,
    repeat_at_us: i64 = 0,
    last_serial: u32 = 0,
    pointer_serial: u32 = 0,
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
    ptr_queue: ?*c.wl_event_queue = null,
    input_thread: ?std.Thread = null,
    input_quit: std.atomic.Value(bool) = .init(false),
    /// Pipes that wake the UI thread and the input thread: read end, write end.
    wake_ui: [2]i32 = .{ -1, -1 },
    wake_input: [2]i32 = .{ -1, -1 },

    pub fn init(gpa: std.mem.Allocator) !*Wayland {
        const display = c.wl_display_connect(null) orelse return error.NoWaylandDisplay;
        const w = try gpa.create(Wayland);
        w.* = .{ .gpa = gpa, .display = display, .atlas = Atlas.init(gpa) };
        errdefer w.deinit();
        w.registry = c.wl_display_get_registry(display);
        _ = c.wl_registry_add_listener(w.registry, &registry_listener, w);
        if (c.wl_display_roundtrip(display) < 0) return error.WaylandFailed;
        if (w.compositor == null or w.wm_base == null or w.shm == null) return error.MissingGlobals;
        _ = c.xdg_wm_base_add_listener(w.wm_base, &wm_base_listener, w);
        w.xkb_ctx = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS);
        if (c.wl_display_roundtrip(display) < 0) return error.WaylandFailed;
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
            _ = std.os.linux.close(fd);
        };
        for (w.bufs) |b| if (b) |buf| freeBuf(w, buf);
        w.atlas.deinit();
        if (w.prev) |p| w.gpa.free(p.pixels);
        if (w.last_image) |p| w.gpa.free(p.pixels);
        if (w.xkb_state) |s| c.xkb_state_unref(s);
        if (w.xkb_keymap) |k| c.xkb_keymap_unref(k);
        if (w.xkb_ctx) |x| c.xkb_context_unref(x);
        if (w.frame_cb) |cb| c.wl_callback_destroy(cb);
        if (w.cursor_device) |d| c.wp_cursor_shape_device_v1_destroy(d);
        if (w.keyboard) |k| c.wl_keyboard_release(k);
        if (w.pointer) |p| c.wl_pointer_release(p);
        w.pointer = null;
        if (w.ptr_queue) |q| c.wl_event_queue_destroy(q);
        if (w.fractional) |f| c.wp_fractional_scale_v1_destroy(f);
        if (w.viewport) |v| c.wp_viewport_destroy(v);
        if (w.toplevel) |t| c.xdg_toplevel_destroy(t);
        if (w.xdg_surface) |s| c.xdg_surface_destroy(s);
        if (w.surface) |s| c.wl_surface_destroy(s);
        if (w.registry) |r| c.wl_registry_destroy(r);
        _ = c.wl_display_flush(w.display);
        c.wl_display_disconnect(w.display);
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
        _ = std.os.linux.write(fd, &one, 1);
    }

    fn drainFd(fd: i32) void {
        if (fd < 0) return;
        var buf: [64]u8 = undefined;
        while (true) {
            const rc = std.os.linux.read(fd, &buf, buf.len);
            if (@as(isize, @bitCast(rc)) <= 0) return;
        }
    }

    fn makePipe() [2]i32 {
        var fds: [2]i32 = .{ -1, -1 };
        const rc = std.os.linux.pipe2(&fds, .{ .NONBLOCK = true, .CLOEXEC = true });
        if (@as(isize, @bitCast(rc)) < 0) return .{ -1, -1 };
        return fds;
    }

    /// Moves the pointer to its own queue and starts the input thread. With
    /// no pipe, no thread, or ZTK_NO_INPUT_THREAD=1, the pointer stays on the queue of the UI thread.
    fn startInput(w: *Wayland) void {
        // ZTK_NO_INPUT_THREAD=1 keeps the pointer on the queue of the UI thread.
        if (std.c.getenv("ZTK_NO_INPUT_THREAD")) |v| if (v[0] == '1') return;
        const q = c.wl_display_create_queue(w.display) orelse return;
        w.wake_ui = makePipe();
        w.wake_input = makePipe();
        if (w.wake_ui[0] < 0 or w.wake_input[0] < 0) {
            c.wl_event_queue_destroy(q);
            return;
        }
        c.wl_proxy_set_queue(@ptrCast(w.pointer), q);
        w.ptr_queue = q;
        w.input_thread = std.Thread.spawn(.{}, inputLoop, .{w}) catch blk: {
            c.wl_proxy_set_queue(@ptrCast(w.pointer), null);
            c.wl_event_queue_destroy(q);
            w.ptr_queue = null;
            break :blk null;
        };
    }

    fn inputLoop(w: *Wayland) void {
        on_input_thread = true;
        const q = w.ptr_queue.?;
        const fd = c.wl_display_get_fd(w.display);
        while (!w.input_quit.load(.acquire)) {
            while (c.wl_display_prepare_read_queue(w.display, q) != 0) _ = c.wl_display_dispatch_queue_pending(w.display, q);
            _ = c.wl_display_flush(w.display);
            var pfd = [_]std.posix.pollfd{
                .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 },
                .{ .fd = w.wake_input[0], .events = std.posix.POLL.IN, .revents = 0 },
            };
            const r = std.posix.poll(&pfd, -1) catch 0;
            if (r > 0 and pfd[0].revents & std.posix.POLL.IN != 0) {
                _ = c.wl_display_read_events(w.display);
                // The events of the UI queue that this thread read.
                wakeFd(w.wake_ui[1]);
            } else c.wl_display_cancel_read(w.display);
            drainFd(w.wake_input[0]);
            _ = c.wl_display_dispatch_queue_pending(w.display, q);
        }
    }

    /// After a read by the UI thread: the pointer events that it read wait in the queue of the input thread.
    fn wakeInput(w: *Wayland) void {
        if (w.input_thread != null) wakeFd(w.wake_input[1]);
    }

    // ---- The registry ----

    const registry_listener: c.struct_wl_registry_listener = .{ .global = onGlobal, .global_remove = onGlobalRemove };

    fn onGlobal(data: ?*anyopaque, reg: ?*c.wl_registry, name: u32, iface: [*c]const u8, version: u32) callconv(.c) void {
        const w: *Wayland = @ptrCast(@alignCast(data.?));
        const i = std.mem.span(iface);
        if (std.mem.eql(u8, i, "wl_compositor")) {
            w.compositor_version = @min(version, 6);
            w.compositor = @ptrCast(c.wl_registry_bind(reg, name, &c.wl_compositor_interface, w.compositor_version));
        } else if (std.mem.eql(u8, i, "xdg_wm_base")) {
            w.wm_base = @ptrCast(c.wl_registry_bind(reg, name, &c.xdg_wm_base_interface, @min(version, 2)));
        } else if (std.mem.eql(u8, i, "wl_seat")) {
            w.seat = @ptrCast(c.wl_registry_bind(reg, name, &c.wl_seat_interface, @min(version, 5)));
            _ = c.wl_seat_add_listener(w.seat, &seat_listener, w);
        } else if (std.mem.eql(u8, i, "wl_shm")) {
            w.shm = @ptrCast(c.wl_registry_bind(reg, name, &c.wl_shm_interface, 1));
        } else if (std.mem.eql(u8, i, "wp_viewporter")) {
            w.viewporter = @ptrCast(c.wl_registry_bind(reg, name, &c.wp_viewporter_interface, 1));
        } else if (std.mem.eql(u8, i, "wp_fractional_scale_manager_v1")) {
            w.fractional_mgr = @ptrCast(c.wl_registry_bind(reg, name, &c.wp_fractional_scale_manager_v1_interface, 1));
        } else if (std.mem.eql(u8, i, "zxdg_decoration_manager_v1")) {
            w.decoration_mgr = @ptrCast(c.wl_registry_bind(reg, name, &c.zxdg_decoration_manager_v1_interface, 1));
        } else if (std.mem.eql(u8, i, "wp_cursor_shape_manager_v1")) {
            w.cursor_mgr = @ptrCast(c.wl_registry_bind(reg, name, &c.wp_cursor_shape_manager_v1_interface, 1));
        }
    }

    fn onGlobalRemove(_: ?*anyopaque, _: ?*c.wl_registry, _: u32) callconv(.c) void {}

    const wm_base_listener: c.struct_xdg_wm_base_listener = .{ .ping = onPing };

    fn onPing(_: ?*anyopaque, base: ?*c.xdg_wm_base, serial: u32) callconv(.c) void {
        c.xdg_wm_base_pong(base, serial);
    }

    // ---- The window ----

    const xdg_surface_listener: c.struct_xdg_surface_listener = .{ .configure = onSurfaceConfigure };
    const toplevel_listener: c.struct_xdg_toplevel_listener = .{ .configure = onToplevelConfigure, .close = onClose, .configure_bounds = onBounds, .wm_capabilities = onCaps };
    const decoration_listener: c.struct_zxdg_toplevel_decoration_v1_listener = .{ .configure = onDecoration };
    const fractional_listener: c.struct_wp_fractional_scale_v1_listener = .{ .preferred_scale = onPreferredScale };
    const surface_listener: c.struct_wl_surface_listener = .{ .enter = onSurfEnter, .leave = onSurfLeave, .preferred_buffer_scale = onBufferScale, .preferred_buffer_transform = onBufferTransform };

    fn onSurfaceConfigure(data: ?*anyopaque, surf: ?*c.xdg_surface, serial: u32) callconv(.c) void {
        const w: *Wayland = @ptrCast(@alignCast(data.?));
        c.xdg_surface_ack_configure(surf, serial);
        if (!w.configured) {
            w.configured = true;
            // The first frame needs no callback.
            if (w.window) |win| w.push(.{ .frame = .{ .window = win, .time_us = nowUs() } });
        }
    }

    fn onToplevelConfigure(data: ?*anyopaque, _: ?*c.xdg_toplevel, width: i32, height: i32, _: [*c]c.wl_array) callconv(.c) void {
        const w: *Wayland = @ptrCast(@alignCast(data.?));
        const win = w.window orelse return;
        if (width > 0 and height > 0 and (win.size.w != width or win.size.h != height)) {
            win.size = .{ .w = width, .h = height };
            w.push(.{ .resize = .{ .window = win, .size = win.size } });
        }
    }

    fn onBounds(_: ?*anyopaque, _: ?*c.xdg_toplevel, _: i32, _: i32) callconv(.c) void {}
    fn onCaps(_: ?*anyopaque, _: ?*c.xdg_toplevel, _: [*c]c.wl_array) callconv(.c) void {}

    fn onClose(data: ?*anyopaque, _: ?*c.xdg_toplevel) callconv(.c) void {
        const w: *Wayland = @ptrCast(@alignCast(data.?));
        if (w.window) |win| w.push(.{ .close = .{ .window = win } });
    }

    fn onDecoration(_: ?*anyopaque, _: ?*c.zxdg_toplevel_decoration_v1, _: u32) callconv(.c) void {}

    fn setScale(w: *Wayland, s120: u32) void {
        if (w.scale120 == s120) return;
        w.scale120 = s120;
        if (w.window) |win| {
            win.scale = @as(f32, @floatFromInt(s120)) / 120.0;
            w.push(.{ .scale = .{ .window = win, .scale = win.scale } });
        }
    }

    fn onPreferredScale(data: ?*anyopaque, _: ?*c.wp_fractional_scale_v1, scale: u32) callconv(.c) void {
        const w: *Wayland = @ptrCast(@alignCast(data.?));
        w.setScale(scale);
    }

    fn onSurfEnter(_: ?*anyopaque, _: ?*c.wl_surface, _: ?*c.wl_output) callconv(.c) void {}
    fn onSurfLeave(_: ?*anyopaque, _: ?*c.wl_surface, _: ?*c.wl_output) callconv(.c) void {}
    fn onBufferTransform(_: ?*anyopaque, _: ?*c.wl_surface, _: u32) callconv(.c) void {}

    fn onBufferScale(data: ?*anyopaque, _: ?*c.wl_surface, factor: i32) callconv(.c) void {
        const w: *Wayland = @ptrCast(@alignCast(data.?));
        // The integer scale counts only without the fractional scale.
        if (w.fractional != null) return;
        w.int_scale = @intCast(std.math.clamp(factor, 1, 16));
        w.setScale(w.int_scale * 120);
    }

    fn vCreateWindow(ptr: *anyopaque, opts: plat.WindowOptions) anyerror!*Window {
        const w = self(ptr);
        if (opts.popup) |p| return w.createPopup(opts.size, p);
        if (w.window != null) return error.OnlyOneWindow;
        const win = try w.gpa.create(Window);
        win.* = .{ .size = opts.size };
        w.window = win;
        w.surface = c.wl_compositor_create_surface(w.compositor);
        if (w.compositor_version >= 6) _ = c.wl_surface_add_listener(w.surface, &surface_listener, w);
        w.xdg_surface = c.xdg_wm_base_get_xdg_surface(w.wm_base, w.surface);
        _ = c.xdg_surface_add_listener(w.xdg_surface, &xdg_surface_listener, w);
        w.toplevel = c.xdg_surface_get_toplevel(w.xdg_surface);
        _ = c.xdg_toplevel_add_listener(w.toplevel, &toplevel_listener, w);
        c.xdg_toplevel_set_app_id(w.toplevel, "ztk");
        if (opts.title.len > 0) vSetTitle(ptr, win, opts.title) else c.xdg_toplevel_set_title(w.toplevel, "ztk");
        if (w.decoration_mgr) |dm| {
            const dec = c.zxdg_decoration_manager_v1_get_toplevel_decoration(dm, w.toplevel);
            _ = c.zxdg_toplevel_decoration_v1_add_listener(dec, &decoration_listener, w);
            c.zxdg_toplevel_decoration_v1_set_mode(dec, c.ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
        }
        if (w.fractional_mgr != null and w.viewporter != null) {
            w.fractional = c.wp_fractional_scale_manager_v1_get_fractional_scale(w.fractional_mgr, w.surface);
            _ = c.wp_fractional_scale_v1_add_listener(w.fractional, &fractional_listener, w);
            w.viewport = c.wp_viewporter_get_viewport(w.viewporter, w.surface);
        }
        c.wl_surface_commit(w.surface);
        // Wait for the first configure.
        _ = c.wl_display_roundtrip(w.display);
        var spins: u32 = 0;
        while (!w.configured and spins < 50) : (spins += 1) _ = c.wl_display_roundtrip(w.display);
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
        var buf: [256]u8 = undefined;
        const n = @min(title.len, buf.len - 1);
        @memcpy(buf[0..n], title[0..n]);
        buf[n] = 0;
        if (w.toplevel) |t| c.xdg_toplevel_set_title(t, &buf);
    }

    fn vRequestSize(ptr: *anyopaque, win: *Window, size: geom.Size) void {
        const w = self(ptr);
        if (win.size.w == size.w and win.size.h == size.h) return;
        win.size = size;
        if (popOf(win)) |p| {
            const m = p.margin;
            c.xdg_surface_set_window_geometry(p.xdg_surface, m.left, m.top, @max(size.w - m.left - m.right, 1), @max(size.h - m.top - m.bottom, 1));
        }
        w.push(.{ .resize = .{ .window = win, .size = size } });
    }

    fn vSetMinSize(ptr: *anyopaque, _: *Window, size: geom.Size) void {
        const w = self(ptr);
        if (w.toplevel) |t| c.xdg_toplevel_set_min_size(t, size.w, size.h);
    }

    fn vNowUs(_: *anyopaque) i64 {
        return nowUs();
    }

    fn nowUs() i64 {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
        return @as(i64, ts.sec) * 1_000_000 + @divFloor(@as(i64, ts.nsec), 1000);
    }

    // ---- Frames ----

    const frame_listener: c.struct_wl_callback_listener = .{ .done = onFrameDone };

    fn onFrameDone(data: ?*anyopaque, cb: ?*c.wl_callback, time_ms: u32) callconv(.c) void {
        const w: *Wayland = @ptrCast(@alignCast(data.?));
        c.wl_callback_destroy(cb);
        w.frame_cb = null;
        if (w.window) |win| w.push(.{ .frame = .{ .window = win, .time_us = @as(i64, time_ms) * 1000 } });
    }

    fn vRequestFrame(ptr: *anyopaque, win: *Window) void {
        const w = self(ptr);
        if (popOf(win)) |p| {
            if (p.frame_cb != null or !p.configured) return;
            p.frame_cb = c.wl_surface_frame(p.surface);
            _ = c.wl_callback_add_listener(p.frame_cb, &pop_frame_listener, p);
            c.wl_surface_commit(p.surface);
            return;
        }
        if (w.frame_cb != null or !w.configured) return;
        if (w.surface) |s| {
            w.frame_cb = c.wl_surface_frame(s);
            _ = c.wl_callback_add_listener(w.frame_cb, &frame_listener, w);
            c.wl_surface_commit(s);
        }
    }

    // ---- The wait and the poll ----

    fn vWait(ptr: *anyopaque, timeout_us: ?i64) void {
        const w = self(ptr);
        w.lock.lock();
        const pending = w.events.items.len > 0;
        w.lock.unlock();
        if (pending) return;
        var limit = timeout_us;
        if (w.repeat_key != null) {
            const left = @max(w.repeat_at_us - nowUs(), 0);
            limit = if (limit) |l| @min(l, left) else left;
        }
        // The prepare_read protocol: dispatch what is queued, flush, poll, read.
        while (c.wl_display_prepare_read(w.display) != 0) _ = c.wl_display_dispatch_pending(w.display);
        _ = c.wl_display_flush(w.display);
        var pfd = [_]std.posix.pollfd{
            .{ .fd = c.wl_display_get_fd(w.display), .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = w.wake_ui[0], .events = std.posix.POLL.IN, .revents = 0 },
        };
        const ms: i32 = if (limit) |l| @intCast(@min(@divFloor(l +| 999, 1000), std.math.maxInt(i32))) else -1;
        // A pipe of -1 is left out of the poll.
        const n: usize = if (w.wake_ui[0] >= 0) 2 else 1;
        const r = std.posix.poll(pfd[0..n], ms) catch 0;
        if (r > 0 and pfd[0].revents & std.posix.POLL.IN != 0) {
            _ = c.wl_display_read_events(w.display);
            w.wakeInput();
        } else c.wl_display_cancel_read(w.display);
        drainFd(w.wake_ui[0]);
        _ = c.wl_display_dispatch_pending(w.display);
    }

    fn vPoll(ptr: *anyopaque, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(Event)) anyerror!void {
        const w = self(ptr);
        _ = c.wl_display_dispatch_pending(w.display);
        _ = c.wl_display_flush(w.display);
        // A read that does not block gets events that wait on the socket.
        if (c.wl_display_prepare_read(w.display) == 0) {
            var pfd = [_]std.posix.pollfd{.{ .fd = c.wl_display_get_fd(w.display), .events = std.posix.POLL.IN, .revents = 0 }};
            if ((std.posix.poll(&pfd, 0) catch 0) > 0) {
                _ = c.wl_display_read_events(w.display);
                w.wakeInput();
                _ = c.wl_display_dispatch_pending(w.display);
            } else c.wl_display_cancel_read(w.display);
        }
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

    const seat_listener: c.struct_wl_seat_listener = .{ .capabilities = onCapabilities, .name = onSeatName };
    const pointer_listener: c.struct_wl_pointer_listener = .{
        .enter = onPointerEnter,
        .leave = onPointerLeave,
        .motion = onPointerMotion,
        .button = onPointerButton,
        .axis = onPointerAxis,
        .frame = onPointerFrame,
        .axis_source = onAxisSource,
        .axis_stop = onAxisStop,
        .axis_discrete = onAxisDiscrete,
        .axis_value120 = onAxisValue120,
        .axis_relative_direction = onAxisRelative,
    };
    const keyboard_listener: c.struct_wl_keyboard_listener = .{
        .keymap = onKeymap,
        .enter = onKeyEnter,
        .leave = onKeyLeave,
        .key = onKey,
        .modifiers = onModifiers,
        .repeat_info = onRepeatInfo,
    };

    fn onSeatName(_: ?*anyopaque, _: ?*c.wl_seat, _: [*c]const u8) callconv(.c) void {}

    fn onCapabilities(data: ?*anyopaque, seat: ?*c.wl_seat, caps: u32) callconv(.c) void {
        const w: *Wayland = @ptrCast(@alignCast(data.?));
        if (caps & c.WL_SEAT_CAPABILITY_POINTER != 0 and w.pointer == null) {
            w.pointer = c.wl_seat_get_pointer(seat);
            _ = c.wl_pointer_add_listener(w.pointer, &pointer_listener, w);
            if (w.cursor_mgr) |cm| w.cursor_device = c.wp_cursor_shape_manager_v1_get_pointer(cm, w.pointer);
            w.startInput();
        }
        if (caps & c.WL_SEAT_CAPABILITY_KEYBOARD != 0 and w.keyboard == null) {
            w.keyboard = c.wl_seat_get_keyboard(seat);
            _ = c.wl_keyboard_add_listener(w.keyboard, &keyboard_listener, w);
        }
    }

    fn timeMs() u32 {
        return @truncate(@as(u64, @intCast(@divFloor(nowUs(), 1000))));
    }

    fn fixed(v: c.wl_fixed_t) f32 {
        return @floatCast(c.wl_fixed_to_double(v));
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

    fn onPointerEnter(data: ?*anyopaque, ptr: ?*c.wl_pointer, serial: u32, surf: ?*c.wl_surface, sx: c.wl_fixed_t, sy: c.wl_fixed_t) callconv(.c) void {
        const w: *Wayland = @ptrCast(@alignCast(data.?));
        w.lock.lock();
        w.ptr_win = w.window;
        for (w.pops.items) |p| if (p.surface == surf) {
            w.ptr_win = p.win;
        };
        w.lock.unlock();
        w.px = fixed(sx);
        w.py = fixed(sy);
        w.pointer_serial = serial;
        _ = ptr;
        if (w.cursor_device) |d| c.wp_cursor_shape_device_v1_set_shape(d, serial, c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_DEFAULT);
        w.motion();
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

    fn onPointerLeave(data: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: ?*c.wl_surface) callconv(.c) void {
        const w: *Wayland = @ptrCast(@alignCast(data.?));
        w.lock.lock();
        const win = w.ptr_win orelse w.window;
        w.ptr_win = null;
        w.lock.unlock();
        if (win) |x| w.push(.{ .leave = .{ .window = x } });
    }

    fn onPointerMotion(data: ?*anyopaque, _: ?*c.wl_pointer, _: u32, sx: c.wl_fixed_t, sy: c.wl_fixed_t) callconv(.c) void {
        const w: *Wayland = @ptrCast(@alignCast(data.?));
        w.px = fixed(sx);
        w.py = fixed(sy);
        w.motion();
    }

    fn onPointerButton(data: ?*anyopaque, _: ?*c.wl_pointer, serial: u32, _: u32, code: u32, state: u32) callconv(.c) void {
        const w: *Wayland = @ptrCast(@alignCast(data.?));
        const button: u8 = switch (code) {
            0x110 => 1,
            0x112 => 2,
            0x111 => 3,
            else => return,
        };
        const pressed = state == c.WL_POINTER_BUTTON_STATE_PRESSED;
        if (pressed) @atomicStore(u32, &w.press_serial, serial, .release);
        const before = w.currentMods();
        if (w.pointerWindow()) |win| w.push(.{ .button = .{ .window = win, .button = button, .pressed = pressed, .x = w.px, .y = w.py, .mods = before, .time_ms = timeMs() } });
        const bit: u8 = @as(u8, 1) << @intCast(button - 1);
        w.lock.lock();
        if (pressed) w.buttons |= bit else w.buttons &= ~bit;
        w.lock.unlock();
    }

    fn onPointerAxis(data: ?*anyopaque, _: ?*c.wl_pointer, _: u32, axis: u32, value: c.wl_fixed_t) callconv(.c) void {
        const w: *Wayland = @ptrCast(@alignCast(data.?));
        // A wheel step is 10 pixels on the axis. The event counts steps.
        const v = fixed(value) / 10;
        if (w.pointerWindow()) |win| w.push(.{ .scroll = .{
            .window = win,
            .dx = if (axis == c.WL_POINTER_AXIS_HORIZONTAL_SCROLL) v else 0,
            .dy = if (axis == c.WL_POINTER_AXIS_VERTICAL_SCROLL) v else 0,
            .x = w.px,
            .y = w.py,
            .mods = w.currentMods(),
            .time_ms = timeMs(),
        } });
    }

    fn pointerWindow(w: *Wayland) ?*Window {
        w.lock.lock();
        defer w.lock.unlock();
        return w.ptr_win orelse w.window;
    }

    fn onPointerFrame(_: ?*anyopaque, _: ?*c.wl_pointer) callconv(.c) void {}
    fn onAxisSource(_: ?*anyopaque, _: ?*c.wl_pointer, _: u32) callconv(.c) void {}
    fn onAxisStop(_: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: u32) callconv(.c) void {}
    fn onAxisDiscrete(_: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: i32) callconv(.c) void {}
    fn onAxisValue120(_: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: i32) callconv(.c) void {}
    fn onAxisRelative(_: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: u32) callconv(.c) void {}

    fn onKeymap(data: ?*anyopaque, _: ?*c.wl_keyboard, format: u32, fd: i32, size: u32) callconv(.c) void {
        const w: *Wayland = @ptrCast(@alignCast(data.?));
        defer _ = c.close(fd);
        if (format != c.WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) return;
        const map = c.mmap(null, size, c.PROT_READ, c.MAP_PRIVATE, fd, 0);
        if (map == c.MAP_FAILED) return;
        defer _ = c.munmap(map, size);
        const km = c.xkb_keymap_new_from_string(w.xkb_ctx, @ptrCast(map), c.XKB_KEYMAP_FORMAT_TEXT_V1, c.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse return;
        const st = c.xkb_state_new(km) orelse {
            c.xkb_keymap_unref(km);
            return;
        };
        if (w.xkb_state) |s| c.xkb_state_unref(s);
        if (w.xkb_keymap) |k| c.xkb_keymap_unref(k);
        w.xkb_keymap = km;
        w.xkb_state = st;
    }

    fn onKeyEnter(data: ?*anyopaque, _: ?*c.wl_keyboard, _: u32, _: ?*c.wl_surface, _: [*c]c.wl_array) callconv(.c) void {
        const w: *Wayland = @ptrCast(@alignCast(data.?));
        // The grab of a popup moves the keyboard to the popup, and the keys stay on the main window.
        if (w.pops.items.len > 0) return;
        if (w.window) |win| w.push(.{ .focus = .{ .window = win, .focused = true } });
    }

    fn onKeyLeave(data: ?*anyopaque, _: ?*c.wl_keyboard, _: u32, _: ?*c.wl_surface) callconv(.c) void {
        const w: *Wayland = @ptrCast(@alignCast(data.?));
        w.repeat_key = null;
        if (w.pops.items.len > 0) return;
        if (w.window) |win| w.push(.{ .focus = .{ .window = win, .focused = false } });
    }

    fn pushKey(w: *Wayland, key: u32, pressed: bool, repeat: bool) void {
        const st = w.xkb_state orelse return;
        const win = w.window orelse return;
        const code = key + 8;
        const sym = c.xkb_state_key_get_one_sym(st, code);
        var e: Event = .{ .key = .{
            .window = win,
            .keysym = sym,
            .keycode = code,
            .pressed = pressed,
            .repeat = repeat,
            .mods = w.currentMods(),
            .time_ms = timeMs(),
        } };
        if (pressed) {
            var buf: [8]u8 = undefined;
            const n = c.xkb_state_key_get_utf8(st, code, &buf, buf.len);
            if (n > 0 and n < buf.len) {
                const len: usize = @intCast(n);
                @memcpy(e.key.text[0..len], buf[0..len]);
                e.key.text_len = @intCast(len);
            }
        }
        w.push(e);
    }

    fn onKey(data: ?*anyopaque, _: ?*c.wl_keyboard, serial: u32, _: u32, key: u32, state: u32) callconv(.c) void {
        const w: *Wayland = @ptrCast(@alignCast(data.?));
        w.last_serial = serial;
        const pressed = state == c.WL_KEYBOARD_KEY_STATE_PRESSED;
        if (pressed) @atomicStore(u32, &w.press_serial, serial, .release);
        w.pushKey(key, pressed, false);
        const st = w.xkb_state orelse return;
        if (pressed) {
            // A key that has repeat starts the repeat. A modifier key has none.
            const has_repeat = if (w.xkb_keymap) |km| c.xkb_keymap_key_repeats(km, key + 8) != 0 else false;
            if (has_repeat) {
                w.repeat_key = key;
                w.repeat_at_us = nowUs() + @as(i64, w.repeat_delay) * 1000;
            }
        } else if (w.repeat_key == key) w.repeat_key = null;
        _ = st;
    }

    fn modActive(st: *c.xkb_state, name: [*:0]const u8) bool {
        return c.xkb_state_mod_name_is_active(st, name, c.XKB_STATE_MODS_EFFECTIVE) > 0;
    }

    fn onModifiers(data: ?*anyopaque, _: ?*c.wl_keyboard, _: u32, depressed: u32, latched: u32, locked: u32, group: u32) callconv(.c) void {
        const w: *Wayland = @ptrCast(@alignCast(data.?));
        const st = w.xkb_state orelse return;
        _ = c.xkb_state_update_mask(st, depressed, latched, locked, 0, 0, group);
        w.lock.lock();
        defer w.lock.unlock();
        w.mods = .{
            .shift = modActive(st, "Shift"),
            .lock = modActive(st, "Lock"),
            .control = modActive(st, "Control"),
            .mod1 = modActive(st, "Mod1"),
            .mod4 = modActive(st, "Mod4"),
        };
    }

    fn onRepeatInfo(data: ?*anyopaque, _: ?*c.wl_keyboard, rate: i32, delay: i32) callconv(.c) void {
        const w: *Wayland = @ptrCast(@alignCast(data.?));
        w.repeat_rate = rate;
        w.repeat_delay = delay;
    }

    // ---- Drawing with the CPU renderer into shared memory ----

    const buffer_listener: c.struct_wl_buffer_listener = .{ .release = onRelease };

    fn onRelease(data: ?*anyopaque, _: ?*c.wl_buffer) callconv(.c) void {
        const b: *Buf = @ptrCast(@alignCast(data.?));
        @atomicStore(bool, &b.busy, false, .release);
    }

    fn freeBuf(w: *Wayland, b: *Buf) void {
        if (b.buffer) |bf| c.wl_buffer_destroy(bf);
        if (b.data.len > 0) _ = c.munmap(b.data.ptr, b.data.len);
        w.gpa.destroy(b);
    }

    fn makeBuf(w: *Wayland, width: u32, height: u32, format: u32) !*Buf {
        const size: usize = @as(usize, width) * height * 4;
        const fd = std.os.linux.memfd_create("ztk-shm", 0);
        if (@as(isize, @bitCast(fd)) < 0) return error.ShmFailed;
        const ifd: i32 = @intCast(fd);
        defer _ = c.close(ifd);
        if (c.ftruncate(ifd, @intCast(size)) != 0) return error.ShmFailed;
        const map = c.mmap(null, size, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, ifd, 0);
        if (map == c.MAP_FAILED) return error.ShmFailed;
        const b = try w.gpa.create(Buf);
        b.* = .{ .owner = w, .width = width, .height = height, .data = @as([*]align(4096) u8, @ptrCast(@alignCast(map)))[0..size] };
        const pool = c.wl_shm_create_pool(w.shm, ifd, @intCast(size));
        b.buffer = c.wl_shm_pool_create_buffer(pool, 0, @intCast(width), @intCast(height), @intCast(width * 4), format);
        c.wl_shm_pool_destroy(pool);
        _ = c.wl_buffer_add_listener(b.buffer, &buffer_listener, b);
        return b;
    }

    fn freeBufferFor(w: *Wayland, bufs: *[2]?*Buf, width: u32, height: u32, format: u32) !*Buf {
        for (bufs) |*slot| {
            if (slot.*) |b| {
                if (b.busy) continue;
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
            _ = c.wl_display_roundtrip(w.display);
            for (bufs) |*slot| if (slot.*) |b| if (!b.busy) {
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

    /// Draws one frame into a shared memory buffer. The libwayland objects
    /// belong to the UI thread, so this target runs in `inline_draw` mode.
    fn drawFrame(ctx: *anyopaque, frame: *const Frame) anyerror!void {
        const w: *Wayland = @ptrCast(@alignCast(ctx));
        const win = w.window orelse return;
        for (frame.patches.items) |p| try w.atlas.applyPatch(p);
        const scene = &frame.scene;
        const surface = w.surface orelse return;
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
        const buf = try w.freeBufferFor(&w.bufs, cur.width, cur.height, c.WL_SHM_FORMAT_XRGB8888);
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
        if (w.viewport != null) {
            c.wp_viewport_set_destination(w.viewport, win.size.w, win.size.h);
        } else if (w.compositor_version >= 3) {
            c.wl_surface_set_buffer_scale(surface, @intCast(w.int_scale));
        }
        c.wl_surface_attach(surface, buf.buffer, 0, 0);
        if (damage.len == 0) {
            c.wl_surface_damage_buffer(surface, 0, 0, @intCast(cur.width), @intCast(cur.height));
        } else for (damage) |d| {
            c.wl_surface_damage_buffer(surface, 0, @intCast(d.first), @intCast(cur.width), @intCast(d.last - d.first));
        }
        buf.busy = true;
        c.wl_surface_commit(surface);
        w.frames_committed += 1;
        _ = c.wl_display_flush(w.display);
    }

    // ---- Popups ----

    fn popOf(win: *const Window) ?*Pop {
        return @ptrCast(@alignCast(win.impl orelse return null));
    }

    const popup_surface_listener: c.struct_xdg_surface_listener = .{ .configure = onPopSurfaceConfigure };
    const popup_listener: c.struct_xdg_popup_listener = .{ .configure = onPopConfigure, .popup_done = onPopDone, .repositioned = onPopRepositioned };

    fn onPopSurfaceConfigure(data: ?*anyopaque, surf: ?*c.xdg_surface, serial: u32) callconv(.c) void {
        const p: *Pop = @ptrCast(@alignCast(data.?));
        c.xdg_surface_ack_configure(surf, serial);
        if (p.configured) return;
        p.configured = true;
        p.owner.push(.{ .frame = .{ .window = p.win, .time_us = nowUs() } });
    }

    /// The place of the window geometry in the window geometry of the parent.
    fn onPopConfigure(data: ?*anyopaque, _: ?*c.xdg_popup, x: i32, y: i32, _: i32, _: i32) callconv(.c) void {
        const p: *Pop = @ptrCast(@alignCast(data.?));
        const pos: geom.Point = .{ .x = x - p.margin.left + p.parent_margin.left, .y = y - p.margin.top + p.parent_margin.top };
        if (pos.x == p.win.pos.x and pos.y == p.win.pos.y) return;
        p.win.pos = pos;
        if (p.configured) p.owner.push(.{ .resize = .{ .window = p.win, .size = p.win.size } });
    }

    const pop_frame_listener: c.struct_wl_callback_listener = .{ .done = onPopFrame };

    fn onPopFrame(data: ?*anyopaque, cb: ?*c.wl_callback, time_ms: u32) callconv(.c) void {
        const p: *Pop = @ptrCast(@alignCast(data.?));
        c.wl_callback_destroy(cb);
        p.frame_cb = null;
        p.owner.push(.{ .frame = .{ .window = p.win, .time_us = @as(i64, time_ms) * 1000 } });
    }

    fn onPopDone(data: ?*anyopaque, _: ?*c.xdg_popup) callconv(.c) void {
        const p: *Pop = @ptrCast(@alignCast(data.?));
        p.owner.push(.{ .close = .{ .window = p.win } });
    }

    fn onPopRepositioned(_: ?*anyopaque, _: ?*c.xdg_popup, _: u32) callconv(.c) void {}

    fn createPopup(w: *Wayland, size: geom.Size, opt: plat.Popup) !*Window {
        var parent_xdg = w.xdg_surface orelse return error.NoParent;
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
        const pos = c.xdg_wm_base_create_positioner(w.wm_base) orelse return error.WaylandFailed;
        defer c.xdg_positioner_destroy(pos);
        c.xdg_positioner_set_size(pos, bw, bh);
        const a = opt.anchor;
        c.xdg_positioner_set_anchor_rect(pos, a.x - pm.left, a.y - pm.top, @max(a.w, 1), @max(a.h, 1));
        const A = c.XDG_POSITIONER_ANCHOR_TOP_LEFT;
        const G = c.XDG_POSITIONER_GRAVITY_BOTTOM_RIGHT;
        const anchor: u32, const gravity: u32, const adjust: u32 = switch (opt.side) {
            .below => .{ c.XDG_POSITIONER_ANCHOR_BOTTOM_LEFT, G, c.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_FLIP_Y | c.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_X | c.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_Y },
            .above => .{ A, c.XDG_POSITIONER_GRAVITY_TOP_RIGHT, c.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_FLIP_Y | c.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_X | c.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_Y },
            .right => .{ c.XDG_POSITIONER_ANCHOR_TOP_RIGHT, G, c.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_FLIP_X | c.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_X | c.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_Y },
            .left => .{ A, c.XDG_POSITIONER_GRAVITY_BOTTOM_LEFT, c.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_FLIP_X | c.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_X | c.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_Y },
        };
        c.xdg_positioner_set_anchor(pos, anchor);
        c.xdg_positioner_set_gravity(pos, gravity);
        c.xdg_positioner_set_constraint_adjustment(pos, adjust);
        c.xdg_positioner_set_offset(pos, opt.offset.x, opt.offset.y);
        const surface = c.wl_compositor_create_surface(w.compositor) orelse return error.WaylandFailed;
        const xs = c.xdg_wm_base_get_xdg_surface(w.wm_base, surface) orelse return error.WaylandFailed;
        const xp = c.xdg_surface_get_popup(xs, parent_xdg, pos) orelse return error.WaylandFailed;
        p.* = .{ .owner = w, .win = win, .surface = surface, .xdg_surface = xs, .popup = xp, .margin = m, .parent_margin = pm, .atlas = Atlas.init(w.gpa) };
        // The place before the configure: the box below or right of the anchor.
        win.pos = switch (opt.side) {
            .below, .left => .{ .x = a.x + opt.offset.x - m.left, .y = a.y + a.h + opt.offset.y - m.top },
            .right, .above => .{ .x = a.x + a.w + opt.offset.x - m.left, .y = a.y + opt.offset.y - m.top },
        };
        win.impl = p;
        _ = c.xdg_surface_add_listener(xs, &popup_surface_listener, p);
        _ = c.xdg_popup_add_listener(xp, &popup_listener, p);
        c.xdg_surface_set_window_geometry(xs, m.left, m.top, bw, bh);
        const serial = @atomicLoad(u32, &w.press_serial, .acquire);
        if (opt.grab and serial != 0) if (w.seat) |seat| c.xdg_popup_grab(xp, seat, serial);
        if (w.viewporter) |vp| p.viewport = c.wp_viewporter_get_viewport(vp, surface);
        w.lock.lock();
        w.pops.append(w.gpa, p) catch {
            w.lock.unlock();
            w.freePopup(p);
            return error.OutOfMemory;
        };
        w.lock.unlock();
        c.wl_surface_commit(surface);
        var spins: u32 = 0;
        while (!p.configured and spins < 50) : (spins += 1) _ = c.wl_display_roundtrip(w.display);
        return win;
    }

    fn freePopup(w: *Wayland, p: *Pop) void {
        if (p.frame_cb) |cb| c.wl_callback_destroy(cb);
        if (p.viewport) |v| c.wp_viewport_destroy(v);
        c.xdg_popup_destroy(p.popup);
        c.xdg_surface_destroy(p.xdg_surface);
        c.wl_surface_destroy(p.surface);
        for (p.bufs) |b| if (b) |buf| freeBuf(w, buf);
        p.atlas.deinit();
        const win = p.win;
        w.gpa.destroy(p);
        w.gpa.destroy(win);
        _ = c.wl_display_flush(w.display);
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
                slot.* = try w.makeBuf(width, height, c.WL_SHM_FORMAT_ARGB8888);
                return slot.*.?;
            }
            @import("../sys/host.zig").sleepUs(1000);
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
        if (p.viewport) |v| {
            c.wp_viewport_set_destination(v, p.win.size.w, p.win.size.h);
        } else if (w.compositor_version >= 3) {
            c.wl_surface_set_buffer_scale(p.surface, @intCast(w.int_scale));
        }
        c.wl_surface_attach(p.surface, buf.buffer, 0, 0);
        c.wl_surface_damage_buffer(p.surface, 0, 0, @intCast(cur.width), @intCast(cur.height));
        @atomicStore(bool, &buf.busy, true, .release);
        c.wl_surface_commit(p.surface);
        _ = c.wl_display_flush(w.display);
    }
};
