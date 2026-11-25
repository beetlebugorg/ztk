//! The Win32 backend. Each toplevel is a window of one window class. The
//! window procedure turns the messages of a window into `Event` values
//! in the queue of the backend. `wait` blocks in
//! `MsgWaitForMultipleObjectsEx` on the message queue of the thread and
//! the frame timer. `poll` dispatches the messages of the thread and
//! then moves the queue to the caller.
//!
//! The process is per-monitor aware (version 2). The scale of a window
//! is its DPI divided by 96. `WM_DPICHANGED` sets the new scale, gives a
//! `scale` event, and moves the window to the rectangle that the message
//! suggests. The size of a window is its client size divided by the
//! scale, in logical pixels.
//!
//! The frame clock is a high-resolution waitable timer. `requestFrame`
//! arms it for the next tick at 60 frames in each second, and the tick
//! gives one `frame` event for each window that asked for one.
//!
//! The target of a window runs on the render thread. It applies the
//! atlas patches to its own copy of the page. With Direct3D 12, it draws
//! into the swapchain of the window and presents it. Without a device,
//! the CPU renderer draws into an image, and the rows that changed since
//! the last frame go to the window with `SetDIBitsToDevice`.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const w32 = @import("win32.zig");
const geom = @import("../geom.zig");
const event = @import("../event.zig");
const plat = @import("platform.zig");
const host = @import("../sys/host.zig");
const Event = event.Event;
const Window = plat.Window;
const Platform = plat.Platform;
const Frame = @import("../scene.zig").Frame;
const Target = @import("../render/thread.zig").Target;
const Atlas = @import("../text/atlas.zig").Atlas;
const cpu = @import("../render/cpu.zig");
const renderer = @import("../render/renderer.zig");
const Image = renderer.Image;
const d3d12 = @import("../render/d3d12.zig");

pub const Renderer = enum { auto, d3d12, cpu };

pub const Options = struct {
    /// False: the windows stay hidden. The tests use it.
    visible: bool = true,
    renderer: Renderer = .auto,
    /// Use the WARP adapter of Direct3D 12.
    warp: bool = false,
};

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ztk");
const frame_us: i64 = 16_667;
const max_ranges = 16;

/// What the render thread owns for one window.
const Surface = struct {
    host: *Win32,
    hwnd: w32.HWND,
    atlas: Atlas,
    gpu: ?*d3d12.D3D12 = null,
    swap: ?*d3d12.Target = null,
    image: ?Image = null,
    prev: ?Image = null,
    /// Rows in BGRA for `SetDIBitsToDevice`.
    rows: []u8 = &.{},
};

const WinRec = struct {
    win: *Window,
    hwnd: w32.HWND,
    host: *Win32,
    frame_wanted: bool = false,
    surface: *Surface,
};

pub const Win32 = struct {
    gpa: std.mem.Allocator,
    opts: Options,
    inst: ?w32.HINSTANCE,
    queue: std.ArrayListUnmanaged(Event) = .empty,
    windows: std.ArrayListUnmanaged(*WinRec) = .empty,
    timer: w32.HANDLE,
    timer_armed: bool = false,
    last_frame_us: i64 = 0,
    /// Counts of the frames that each output drew, for the tests.
    gpu_frames: std.atomic.Value(u32) = .init(0),
    cpu_frames: std.atomic.Value(u32) = .init(0),

    pub fn init(gpa: std.mem.Allocator, opts: Options) !*Win32 {
        // The call fails when the process already has an awareness. The backend goes on with it.
        _ = w32.SetProcessDpiAwarenessContext(w32.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        const inst = w32.GetModuleHandleW(null);
        const cls: w32.WNDCLASSEXW = .{
            .style = w32.CS_HREDRAW | w32.CS_VREDRAW,
            .lpfnWndProc = wndProc,
            .hInstance = inst,
            .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
            .lpszClassName = class_name,
        };
        // A second backend in the process finds the class registered.
        _ = w32.RegisterClassExW(&cls);
        // A manual reset keeps the tick signaled after the wait, so `poll` sees it.
        const timer = w32.CreateWaitableTimerExW(null, null, w32.CREATE_WAITABLE_TIMER_MANUAL_RESET | w32.CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, w32.TIMER_ALL_ACCESS) orelse return error.NoTimer;
        const b = try gpa.create(Win32);
        b.* = .{ .gpa = gpa, .opts = opts, .inst = inst, .timer = timer };
        return b;
    }

    pub fn deinit(b: *Win32) void {
        while (b.windows.items.len > 0) destroy(b, b.windows.items[b.windows.items.len - 1].win);
        b.windows.deinit(b.gpa);
        b.queue.deinit(b.gpa);
        _ = w32.CloseHandle(b.timer);
        b.gpa.destroy(b);
    }

    pub fn platform(b: *Win32) Platform {
        return .{ .ptr = b, .vtable = &vtable, .live = true, .thread_safe_draw = true };
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

    fn self(ptr: *anyopaque) *Win32 {
        return @ptrCast(@alignCast(ptr));
    }

    fn vDeinit(ptr: *anyopaque) void {
        self(ptr).deinit();
    }

    fn push(b: *Win32, e: Event) void {
        b.queue.append(b.gpa, e) catch {};
    }

    fn recOf(b: *Win32, w: *Window) ?*WinRec {
        for (b.windows.items) |r| if (r.win == w) return r;
        return null;
    }

    fn scaleOf(hwnd: w32.HWND) f32 {
        const dpi = w32.GetDpiForWindow(hwnd);
        return @as(f32, @floatFromInt(if (dpi == 0) w32.USER_DEFAULT_SCREEN_DPI else dpi)) / 96.0;
    }

    /// The outer size of a window with a client area of `size` logical pixels.
    fn outerSize(hwnd: w32.HWND, size: geom.Size, scale: f32) [2]c_int {
        var r: w32.RECT = .{
            .right = @intFromFloat(@round(@as(f32, @floatFromInt(size.w)) * scale)),
            .bottom = @intFromFloat(@round(@as(f32, @floatFromInt(size.h)) * scale)),
        };
        _ = w32.AdjustWindowRectExForDpi(&r, w32.WS_OVERLAPPEDWINDOW, 0, 0, w32.GetDpiForWindow(hwnd));
        return .{ r.right - r.left, r.bottom - r.top };
    }

    fn vCreateWindow(ptr: *anyopaque, opts: plat.WindowOptions) anyerror!*Window {
        const b = self(ptr);
        const title = try std.unicode.utf8ToUtf16LeAllocZ(b.gpa, opts.title);
        defer b.gpa.free(title);
        const hwnd = w32.CreateWindowExW(0, class_name, title, w32.WS_OVERLAPPEDWINDOW, w32.CW_USEDEFAULT, w32.CW_USEDEFAULT, 200, 200, null, null, b.inst, null) orelse return error.NoWindow;
        errdefer _ = w32.DestroyWindow(hwnd);
        const scale = scaleOf(hwnd);
        const w = try b.gpa.create(Window);
        errdefer b.gpa.destroy(w);
        w.* = .{ .size = opts.size, .scale = scale };
        const surf = try b.gpa.create(Surface);
        errdefer b.gpa.destroy(surf);
        surf.* = .{ .host = b, .hwnd = hwnd, .atlas = Atlas.init(b.gpa) };
        if (b.opts.renderer != .cpu) {
            surf.gpu = d3d12.D3D12.init(b.gpa, .{ .warp = b.opts.warp }) catch |e| blk: {
                if (b.opts.renderer == .d3d12) return e;
                break :blk null;
            };
        }
        const rec = try b.gpa.create(WinRec);
        errdefer b.gpa.destroy(rec);
        rec.* = .{ .win = w, .hwnd = hwnd, .host = b, .surface = surf };
        try b.windows.append(b.gpa, rec);
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(rec)));
        const outer = outerSize(hwnd, opts.size, scale);
        _ = w32.SetWindowPos(hwnd, null, 0, 0, outer[0], outer[1], w32.SWP_NOMOVE | w32.SWP_NOZORDER | w32.SWP_NOACTIVATE);
        if (b.opts.visible) _ = w32.ShowWindow(hwnd, w32.SW_SHOW);
        return w;
    }

    fn destroy(b: *Win32, w: *Window) void {
        const rec = b.recOf(w) orelse return;
        var i: usize = 0;
        while (i < b.queue.items.len) {
            if (b.queue.items[i].window() == w) _ = b.queue.orderedRemove(i) else i += 1;
        }
        for (b.windows.items, 0..) |r, k| if (r == rec) {
            _ = b.windows.orderedRemove(k);
            break;
        };
        _ = w32.SetWindowLongPtrW(rec.hwnd, w32.GWLP_USERDATA, 0);
        freeSurface(b, rec.surface);
        _ = w32.DestroyWindow(rec.hwnd);
        b.gpa.destroy(rec);
        b.gpa.destroy(w);
    }

    fn freeSurface(b: *Win32, s: *Surface) void {
        if (s.gpu) |g| {
            if (s.swap) |t| g.destroyTarget(t);
            g.deinit();
        }
        if (s.image) |im| b.gpa.free(im.pixels);
        if (s.prev) |im| b.gpa.free(im.pixels);
        b.gpa.free(s.rows);
        s.atlas.deinit();
        b.gpa.destroy(s);
    }

    fn vDestroyWindow(ptr: *anyopaque, w: *Window) void {
        destroy(self(ptr), w);
    }

    fn vSetTitle(ptr: *anyopaque, w: *Window, title: []const u8) void {
        const b = self(ptr);
        const rec = b.recOf(w) orelse return;
        const t = std.unicode.utf8ToUtf16LeAllocZ(b.gpa, title) catch return;
        defer b.gpa.free(t);
        _ = w32.SetWindowTextW(rec.hwnd, t);
    }

    fn vRequestSize(ptr: *anyopaque, w: *Window, size: geom.Size) void {
        const b = self(ptr);
        const rec = b.recOf(w) orelse return;
        const outer = outerSize(rec.hwnd, size, w.scale);
        // The window procedure gives the `resize` event from WM_SIZE.
        _ = w32.SetWindowPos(rec.hwnd, null, 0, 0, outer[0], outer[1], w32.SWP_NOMOVE | w32.SWP_NOZORDER | w32.SWP_NOACTIVATE);
    }

    fn vSetMinSize(_: *anyopaque, _: *Window, _: geom.Size) void {}

    fn vRequestFrame(ptr: *anyopaque, w: *Window) void {
        const b = self(ptr);
        const rec = b.recOf(w) orelse return;
        rec.frame_wanted = true;
        if (b.timer_armed) return;
        // The tick is one frame time after the last one, and not in the past.
        const wait_us: i64 = @max(b.last_frame_us + frame_us - host.nowUs(), 0);
        const due: i64 = -wait_us * 10;
        if (w32.SetWaitableTimer(b.timer, &due, 0, null, null, 0) != 0) b.timer_armed = true;
    }

    fn vWait(ptr: *anyopaque, timeout_us: ?i64) void {
        const b = self(ptr);
        if (b.queue.items.len > 0) return;
        const ms: w32.DWORD = if (timeout_us) |t| @intCast(@min(@divFloor(@max(t, 0) + 999, 1000), 0x7fffffff)) else w32.INFINITE;
        const handles = [_]w32.HANDLE{b.timer};
        const n: w32.DWORD = if (b.timer_armed) 1 else 0;
        _ = w32.MsgWaitForMultipleObjectsEx(n, &handles, ms, w32.QS_ALLINPUT, w32.MWMO_INPUTAVAILABLE);
    }

    fn vPoll(ptr: *anyopaque, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(Event)) anyerror!void {
        const b = self(ptr);
        var msg: w32.MSG = .{};
        while (w32.PeekMessageW(&msg, null, 0, 0, w32.PM_REMOVE) != 0) {
            _ = w32.TranslateMessage(&msg);
            _ = w32.DispatchMessageW(&msg);
        }
        if (b.timer_armed and w32.WaitForSingleObject(b.timer, 0) == w32.WAIT_OBJECT_0) {
            b.timer_armed = false;
            const now = host.nowUs();
            b.last_frame_us = now;
            for (b.windows.items) |r| if (r.frame_wanted) {
                r.frame_wanted = false;
                b.push(.{ .frame = .{ .window = r.win, .time_us = now } });
            };
        }
        try out.appendSlice(gpa, b.queue.items);
        b.queue.clearRetainingCapacity();
    }

    fn vNowUs(_: *anyopaque) i64 {
        return host.nowUs();
    }

    fn vTarget(ptr: *anyopaque, w: *Window) Target {
        const b = self(ptr);
        const rec = b.recOf(w).?;
        return .{ .ctx = rec.surface, .draw = drawFrame };
    }

    /// The output that draws the frames of a window.
    pub fn outputName(b: *Win32, w: *Window) []const u8 {
        const rec = b.recOf(w) orelse return "none";
        return if (rec.surface.gpu != null) "direct3d12" else "cpu";
    }

    /// The window handle of a window, for the tests.
    pub fn hwndOf(b: *Win32, w: *Window) ?w32.HWND {
        const rec = b.recOf(w) orelse return null;
        return rec.hwnd;
    }

    // ---- The window procedure ----

    fn wndProc(hwnd: w32.HWND, msg: w32.UINT, wp: w32.WPARAM, lp: w32.LPARAM) callconv(.winapi) w32.LRESULT {
        const raw = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
        if (raw == 0) return w32.DefWindowProcW(hwnd, msg, wp, lp);
        const rec: *WinRec = @ptrFromInt(@as(usize, @bitCast(raw)));
        return rec.host.message(rec, msg, wp, lp);
    }

    fn message(b: *Win32, rec: *WinRec, msg: w32.UINT, wp: w32.WPARAM, lp: w32.LPARAM) w32.LRESULT {
        const w = rec.win;
        switch (msg) {
            w32.WM_SIZE => {
                const pw: u16 = @bitCast(w32.loword(lp));
                const ph: u16 = @bitCast(w32.hiword(lp));
                // A minimized window has a client size of 0.
                if (pw == 0 or ph == 0) return 0;
                const size: geom.Size = .{
                    .w = @intFromFloat(@round(@as(f32, @floatFromInt(pw)) / w.scale)),
                    .h = @intFromFloat(@round(@as(f32, @floatFromInt(ph)) / w.scale)),
                };
                if (size.w != w.size.w or size.h != w.size.h) {
                    w.size = size;
                    b.push(.{ .resize = .{ .window = w, .size = size } });
                }
                return 0;
            },
            w32.WM_DPICHANGED => {
                const dpi: u16 = @bitCast(w32.loword(wp));
                w.scale = @as(f32, @floatFromInt(dpi)) / 96.0;
                b.push(.{ .scale = .{ .window = w, .scale = w.scale } });
                const r: *const w32.RECT = @ptrFromInt(@as(usize, @bitCast(lp)));
                _ = w32.SetWindowPos(rec.hwnd, null, r.left, r.top, r.right - r.left, r.bottom - r.top, w32.SWP_NOZORDER | w32.SWP_NOACTIVATE);
                return 0;
            },
            w32.WM_CLOSE => {
                // The App handles the close event, so the window stays.
                b.push(.{ .close = .{ .window = w } });
                return 0;
            },
            w32.WM_SETFOCUS => {
                b.push(.{ .focus = .{ .window = w, .focused = true } });
                return 0;
            },
            w32.WM_KILLFOCUS => {
                b.push(.{ .focus = .{ .window = w, .focused = false } });
                return 0;
            },
            w32.WM_ERASEBKGND => return 1,
            w32.WM_PAINT => {
                // The compositor keeps the last frame, so a paint needs no draw.
                _ = w32.ValidateRect(rec.hwnd, null);
                return 0;
            },
            else => return w32.DefWindowProcW(rec.hwnd, msg, wp, lp),
        }
    }

    // ---- The target, on the render thread ----

    fn drawFrame(ctx: *anyopaque, frame: *const Frame) anyerror!void {
        const s: *Surface = @ptrCast(@alignCast(ctx));
        for (frame.patches.items) |p| try s.atlas.applyPatch(p);
        const scene = &frame.scene;
        if (scene.width == 0 or scene.height == 0) return;
        if (s.gpu) |g| {
            if (s.swap) |t| {
                if (t.width != scene.width or t.height != scene.height) try g.resizeSwapchain(t, scene.width, scene.height);
            } else s.swap = try g.createSwapchain(s.hwnd, scene.width, scene.height);
            g.setTarget(s.swap.?);
            try g.draw(scene, &s.atlas);
            try g.present(s.swap.?);
            _ = s.host.gpu_frames.fetchAdd(1, .monotonic);
            return;
        }
        try drawCpu(s, scene);
        _ = s.host.cpu_frames.fetchAdd(1, .monotonic);
    }

    fn drawCpu(s: *Surface, scene: *const @import("../scene.zig").Scene) !void {
        const gpa = s.host.gpa;
        const need = @as(usize, scene.width) * scene.height * 4;
        const fresh = s.image == null or s.image.?.width != scene.width or s.image.?.height != scene.height;
        if (fresh) {
            if (s.image) |im| gpa.free(im.pixels);
            if (s.prev) |im| gpa.free(im.pixels);
            s.image = null;
            s.prev = null;
            s.image = .{ .width = scene.width, .height = scene.height, .pixels = try gpa.alloc(u8, need) };
            s.prev = .{ .width = scene.width, .height = scene.height, .pixels = try gpa.alloc(u8, need) };
            gpa.free(s.rows);
            s.rows = &.{};
            s.rows = try gpa.alloc(u8, need);
        }
        // The new frame goes into `prev`, and the two swap, so `prev` keeps the last frame.
        std.mem.swap(Image, &s.image.?, &s.prev.?);
        const img = &s.image.?;
        cpu.render(scene, &s.atlas, img);
        var ranges_buf: [max_ranges]renderer.RowRange = undefined;
        const ranges: []const renderer.RowRange = if (fresh)
            &[_]renderer.RowRange{.{ .first = 0, .last = scene.height - 1 }}
        else
            renderer.changedRows(s.prev.?, img.*, &ranges_buf);
        if (ranges.len == 0) return;
        const dc = w32.GetDC(s.hwnd) orelse return;
        defer _ = w32.ReleaseDC(s.hwnd, dc);
        const stride: usize = @as(usize, scene.width) * 4;
        for (ranges) |r| {
            const rows = r.last - r.first + 1;
            const src = img.pixels[r.first * stride ..][0 .. rows * stride];
            const dst = s.rows[0..src.len];
            // SetDIBitsToDevice reads BGRA.
            var i: usize = 0;
            while (i < src.len) : (i += 4) {
                dst[i] = src[i + 2];
                dst[i + 1] = src[i + 1];
                dst[i + 2] = src[i];
                dst[i + 3] = src[i + 3];
            }
            const info: w32.BITMAPINFOHEADER = .{ .biWidth = @intCast(scene.width), .biHeight = -@as(i32, @intCast(rows)) };
            _ = w32.SetDIBitsToDevice(dc, 0, @intCast(r.first), scene.width, rows, 0, 0, 0, rows, dst.ptr, &info, 0);
        }
    }
};
