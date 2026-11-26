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
const winkeys = @import("winkeys.zig");
const keysym_mod = @import("../keysym.zig");
const Mods = event.Mods;
const Cursor = plat.Cursor;
const tsf = @import("tsf.zig");
const winmenu = @import("winmenu.zig");
const wintray = @import("wintray.zig");
const windialog = @import("windialog.zig");
const wintaskbar = @import("wintaskbar.zig");
const winrecent = @import("winrecent.zig");

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
    /// The shape over the client area, from `setCursor`.
    cursor: ?w32.HCURSOR = null,
    /// True after `TrackMouseEvent`, until `WM_MOUSELEAVE`.
    tracking: bool = false,
    /// The text store of the input method, when TSF exists.
    store: ?*tsf.Store = null,
    /// The menu bar of the window and the id of its menu.
    bar: ?w32.HMENU = null,
    bar_id: plat.MenuId = 0,
    /// The state of the taskbar button, for the message of the button.
    taskbar: plat.Taskbar = .{},
    /// The buttons that are down, bit 0 for button 1.
    buttons: u8 = 0,
};

pub const Win32 = struct {
    gpa: std.mem.Allocator,
    opts: Options,
    inst: ?w32.HINSTANCE,
    queue: std.ArrayListUnmanaged(Event) = .empty,
    windows: std.ArrayListUnmanaged(*WinRec) = .empty,
    timer: w32.HANDLE,
    timer_armed: bool = false,
    /// The keysym of each key that is down, by scan code with the extended bit, so a release has the keysym of its press.
    down_syms: [512]u32 = @splat(0),
    /// The first half of a surrogate pair of `WM_CHAR`.
    high_surrogate: u16 = 0,
    /// The sequence number of the clipboard after the last `clipboardSet`.
    own_seq: u32 = 0,
    /// The thread manager of TSF, or null with no input method.
    tsf: ?tsf.Tsf = null,
    /// The texts of the input method events, freed one `poll` later.
    ime_texts: std.ArrayListUnmanaged([]u8) = .empty,
    ime_texts_old: std.ArrayListUnmanaged([]u8) = .empty,
    /// The native menus, and the handler of the core for their menu loop.
    menus: winmenu.Menus,
    menu_handler: ?plat.MenuHandler = null,
    /// The icons in the notification area.
    trays: wintray.Trays,
    taskbar: wintaskbar.Taskbar,
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
        b.* = .{ .gpa = gpa, .opts = opts, .inst = inst, .timer = timer, .menus = .{ .gpa = gpa }, .trays = wintray.Trays.init(gpa), .taskbar = wintaskbar.Taskbar.init() };
        b.tsf = tsf.Tsf.init() catch null;
        return b;
    }

    pub fn deinit(b: *Win32) void {
        // An icon goes away with the window that owns it, so the trays go first.
        b.trays.deinit();
        b.taskbar.deinit();
        while (b.windows.items.len > 0) destroy(b, b.windows.items[b.windows.items.len - 1].win);
        b.windows.deinit(b.gpa);
        b.queue.deinit(b.gpa);
        b.menus.deinit();
        if (b.tsf) |*m| m.deinit();
        b.freeTexts(&b.ime_texts);
        b.freeTexts(&b.ime_texts_old);
        b.ime_texts.deinit(b.gpa);
        b.ime_texts_old.deinit(b.gpa);
        _ = w32.CloseHandle(b.timer);
        b.gpa.destroy(b);
    }

    pub fn platform(b: *Win32) Platform {
        return .{ .ptr = b, .vtable = &vtable, .live = true, .thread_safe_draw = true, .native_menus = true };
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
        .appearance = vAppearance,
        .menuSet = vMenuSet,
        .menuEntrySet = vMenuEntrySet,
        .menuDrop = vMenuDrop,
        .setMenuBar = vSetMenuBar,
        .postMenu = vPostMenu,
        .unpostMenu = vUnpostMenu,
        .setMenuHandler = vSetMenuHandler,
        .trayCreate = vTrayCreate,
        .traySet = vTraySet,
        .trayDrop = vTrayDrop,
        .fileDialog = vFileDialog,
        .taskbarSet = vTaskbarSet,
        .attention = vAttention,
        .recentAdd = vRecentAdd,
        .recentClear = vRecentClear,
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
        const has_menu: w32.BOOL = if (w32.GetMenu(hwnd) != null) 1 else 0;
        _ = w32.AdjustWindowRectExForDpi(&r, w32.WS_OVERLAPPEDWINDOW, has_menu, 0, w32.GetDpiForWindow(hwnd));
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
        if (b.tsf) |*m| {
            const store = try tsf.Store.init(b.gpa, .{ .ctx = rec, .preedit = onPreedit, .commit = onCommit });
            if (m.attach(store)) |_| {
                rec.store = store;
            } else |_| store.deinit();
        }
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
        if (rec.store) |s| {
            if (b.tsf) |*m| {
                m.focus(s, rec.hwnd, false);
                m.detach(s);
            }
            s.deinit();
        }
        freeSurface(b, rec.surface);
        // DestroyWindow destroys the menu of a window, and the popups of the bar belong to their records.
        if (rec.bar) |bar| {
            _ = w32.SetMenu(rec.hwnd, null);
            b.menus.dropBar(bar);
        }
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
        // The texts of the events of the last poll are done.
        b.freeTexts(&b.ime_texts_old);
        std.mem.swap(std.ArrayListUnmanaged([]u8), &b.ime_texts, &b.ime_texts_old);
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

    /// The cursor of the client area of a window, for the tests.
    pub fn cursorHandle(b: *Win32, w: *Window) ?w32.HCURSOR {
        const rec = b.recOf(w) orelse return null;
        return rec.cursor;
    }

    /// The window handle of a window, for the tests.
    pub fn hwndOf(b: *Win32, w: *Window) ?w32.HWND {
        const rec = b.recOf(w) orelse return null;
        return rec.hwnd;
    }

    fn vSetCursor(ptr: *anyopaque, w: *Window, shape: Cursor) void {
        const rec = self(ptr).recOf(w) orelse return;
        rec.cursor = w32.LoadCursorW(null, cursorId(shape));
        // The shape shows now when the pointer is over the window, and at the next WM_SETCURSOR otherwise.
        if (rec.tracking) _ = w32.SetCursor(rec.cursor);
    }

    /// The cursor of the system for a shape. Windows has no closed hand,
    /// so `grabbing` is the four arrows of a move.
    fn cursorId(shape: Cursor) usize {
        return switch (shape) {
            .default => w32.IDC_ARROW,
            .pointer, .grab => w32.IDC_HAND,
            .text => w32.IDC_IBEAM,
            .wait => w32.IDC_WAIT,
            .progress => w32.IDC_APPSTARTING,
            .crosshair => w32.IDC_CROSS,
            .move, .grabbing => w32.IDC_SIZEALL,
            .not_allowed => w32.IDC_NO,
            .help => w32.IDC_HELP,
            .ew_resize => w32.IDC_SIZEWE,
            .ns_resize => w32.IDC_SIZENS,
            .nwse_resize => w32.IDC_SIZENWSE,
            .nesw_resize => w32.IDC_SIZENESW,
        };
    }

    // ---- Menus ----

    /// Builds the bar of each window whose bar is the menu `id` again.
    fn rebuildBars(b: *Win32, id: plat.MenuId) void {
        for (b.windows.items) |r| if (r.bar_id == id) b.attachBar(r, id);
    }

    /// Gives a window the bar of a menu, or no bar for 0, and keeps the
    /// client size: the bar goes above the client area.
    fn attachBar(b: *Win32, rec: *WinRec, id: plat.MenuId) void {
        const old = rec.bar;
        // SetMenu gives WM_SIZE with the smaller client area, so the size to keep is the one from before.
        const keep = rec.win.size;
        const bar: ?w32.HMENU = if (id == 0) null else b.menus.makeBar(id) catch null;
        _ = w32.SetMenu(rec.hwnd, bar);
        if (old) |h| b.menus.dropBar(h);
        rec.bar = bar;
        rec.bar_id = if (bar != null) id else 0;
        _ = w32.DrawMenuBar(rec.hwnd);
        const outer = outerSize(rec.hwnd, keep, rec.win.scale);
        _ = w32.SetWindowPos(rec.hwnd, null, 0, 0, outer[0], outer[1], w32.SWP_NOMOVE | w32.SWP_NOZORDER | w32.SWP_NOACTIVATE);
    }

    fn vMenuSet(ptr: *anyopaque, menu: *const plat.Menu) void {
        const b = self(ptr);
        b.menus.set(menu) catch return;
        b.rebuildBars(menu.id);
    }

    fn vMenuEntrySet(ptr: *anyopaque, id: plat.MenuId, index: u32, entry: *const plat.MenuEntry) void {
        const b = self(ptr);
        b.menus.setEntry(id, index, entry) catch return;
        b.rebuildBars(id);
    }

    fn vMenuDrop(ptr: *anyopaque, id: plat.MenuId) void {
        self(ptr).menus.drop(id);
    }

    fn vSetMenuBar(ptr: *anyopaque, w: *Window, id: plat.MenuId) void {
        const b = self(ptr);
        const rec = b.recOf(w) orelse return;
        b.attachBar(rec, id);
    }

    /// Shows a menu at a point of the window. `TrackPopupMenuEx` runs the
    /// menu loop and returns after the menu closed. It cannot put an
    /// entry at the point, so the hint `entry` has no effect.
    fn vPostMenu(ptr: *anyopaque, w: *Window, id: plat.MenuId, at: geom.Point, _: i32) void {
        const b = self(ptr);
        const rec = b.recOf(w) orelse return;
        const h = b.menus.handleOf(id) orelse return;
        var p: w32.POINT = .{
            .x = @intFromFloat(@round(@as(f32, @floatFromInt(at.x)) * w.scale)),
            .y = @intFromFloat(@round(@as(f32, @floatFromInt(at.y)) * w.scale)),
        };
        _ = w32.ClientToScreen(rec.hwnd, &p);
        _ = w32.TrackPopupMenuEx(h, w32.TPM_RIGHTBUTTON, p.x, p.y, rec.hwnd, null);
    }

    fn vUnpostMenu(_: *anyopaque, _: plat.MenuId) void {
        // Windows has one menu loop at a time, and EndMenu ends it.
        _ = w32.EndMenu();
    }

    fn vSetMenuHandler(ptr: *anyopaque, h: plat.MenuHandler) void {
        self(ptr).menu_handler = h;
    }

    /// An `opening` or a `select` in the menu loop: a call of the handler
    /// of the core, or a queued event when the core gave no handler.
    fn menuNow(b: *Win32, rec: *WinRec, id: plat.MenuId, entry: i32, action: event.MenuAction) void {
        if (b.menu_handler) |h| {
            h.call(h.ctx, id, entry, action);
            return;
        }
        b.push(.{ .menu = .{ .window = rec.win, .menu = id, .entry = entry, .action = action } });
    }

    // ---- Tray ----

    fn vTrayCreate(ptr: *anyopaque, w: *Window, icon: plat.TrayIcon, _: bool, tooltip: []const u8) plat.TrayId {
        const b = self(ptr);
        const rec = b.recOf(w) orelse return 0;
        return b.trays.create(rec.hwnd, icon, tooltip);
    }

    // Windows has no template icons, so `template` has no effect.
    fn vTraySet(ptr: *anyopaque, id: plat.TrayId, icon: plat.TrayIcon, _: bool, tooltip: []const u8, menu: plat.MenuId) void {
        self(ptr).trays.set(id, icon, tooltip, menu);
    }

    fn vTrayDrop(ptr: *anyopaque, id: plat.TrayId) void {
        self(ptr).trays.drop(id);
    }

    fn vTaskbarSet(ptr: *anyopaque, w: *Window, state: plat.Taskbar) void {
        const b = self(ptr);
        const rec = b.recOf(w) orelse return;
        rec.taskbar = state;
        b.taskbar.apply(rec.hwnd, state);
    }

    fn vAttention(ptr: *anyopaque, w: *Window, critical: bool) void {
        const rec = self(ptr).recOf(w) orelse return;
        wintaskbar.flash(rec.hwnd, critical);
    }

    fn vRecentAdd(_: *anyopaque, path: []const u8) bool {
        return winrecent.add(path);
    }

    fn vRecentClear(_: *anyopaque) void {
        winrecent.clear();
    }

    /// A message of the shell for a tray: the action in the low word of
    /// `lp`, the id in the high word, and the point of the pointer in `wp`.
    fn trayMessage(b: *Win32, rec: *WinRec, wp: w32.WPARAM, lp: w32.LPARAM) w32.LRESULT {
        const action: u16 = @bitCast(w32.loword(lp));
        const id: plat.TrayId = @as(u16, @bitCast(w32.hiword(lp)));
        const what: event.TrayAction = switch (action) {
            w32.NIN_SELECT, w32.NIN_KEYSELECT => .click,
            w32.WM_LBUTTONDBLCLK => .double,
            w32.WM_CONTEXTMENU => .menu,
            else => return 0,
        };
        b.push(.{ .tray = .{ .window = rec.win, .id = id, .action = what } });
        if (what != .menu) return 0;
        const t = b.trays.find(id) orelse return 0;
        const h = b.menus.handleOf(t.menu) orelse return 0;
        // The documentation of TrackPopupMenu asks for the foreground window
        // before the menu of a tray, and a message after it, so the menu
        // closes on a click outside it.
        _ = w32.SetForegroundWindow(rec.hwnd);
        const x: i32 = w32.loword(wp);
        const y: i32 = w32.hiword(wp);
        _ = w32.TrackPopupMenuEx(h, w32.TPM_RIGHTBUTTON, x, y, rec.hwnd, null);
        _ = w32.PostMessageW(rec.hwnd, w32.WM_NULL, 0, 0);
        return 0;
    }

    /// The tray of an id, for the tests.
    pub fn trayMenu(b: *Win32, id: plat.TrayId) ?plat.MenuId {
        const t = b.trays.find(id) orelse return null;
        return t.menu;
    }

    // ---- File dialogs ----

    fn vFileDialog(ptr: *anyopaque, gpa: std.mem.Allocator, opts: *const plat.FileDialog) ?plat.FileDialogResult {
        const b = self(ptr);
        const owner: ?w32.HWND = if (opts.parent) |p| (if (b.recOf(p)) |r| r.hwnd else null) else null;
        var d = windialog.configure(gpa, opts) catch return null;
        defer d.deinit();
        return windialog.show(&d, gpa, owner);
    }

    // ---- Appearance ----

    /// The dark mode from `AppsUseLightTheme` of the user (0 is dark), and
    /// the accent from `DwmGetColorizationColor`, the color of the window frames.
    fn vAppearance(_: *anyopaque) plat.Appearance {
        var light: u32 = 1;
        var size: u32 = @sizeOf(u32);
        const path = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize");
        const value = std.unicode.utf8ToUtf16LeStringLiteral("AppsUseLightTheme");
        if (w32.RegGetValueW(w32.HKEY_CURRENT_USER, path, value, w32.RRF_RT_REG_DWORD, null, &light, &size) != 0) light = 1;
        var argb: u32 = 0;
        var opaque_blend: w32.BOOL = 0;
        const accent: ?geom.Color = if (w32.DwmGetColorizationColor(&argb, &opaque_blend) >= 0)
            .{ .r = @truncate(argb >> 16), .g = @truncate(argb >> 8), .b = @truncate(argb) }
        else
            null;
        return .{ .dark = light == 0, .accent = accent };
    }

    /// The appearance of the system, for the tests.
    pub fn appearanceNow(b: *Win32) plat.Appearance {
        return vAppearance(b);
    }

    // ---- Input method ----

    fn freeTexts(b: *Win32, list: *std.ArrayListUnmanaged([]u8)) void {
        for (list.items) |s| b.gpa.free(s);
        list.clearRetainingCapacity();
    }

    /// A copy of a text of the store that lives until one `poll` after the next.
    fn keepText(b: *Win32, text: []const u8) ?[]const u8 {
        const s = b.gpa.dupe(u8, text) catch return null;
        b.ime_texts.append(b.gpa, s) catch {
            b.gpa.free(s);
            return null;
        };
        return s;
    }

    fn onPreedit(ctx: *anyopaque, text: []const u8, caret: u32) void {
        const rec: *WinRec = @ptrCast(@alignCast(ctx));
        const s = rec.host.keepText(text) orelse return;
        rec.host.push(.{ .preedit = .{ .window = rec.win, .text = s, .caret = caret } });
    }

    fn onCommit(ctx: *anyopaque, text: []const u8) void {
        const rec: *WinRec = @ptrCast(@alignCast(ctx));
        const s = rec.host.keepText(text) orelse return;
        rec.host.push(.{ .commit = .{ .window = rec.win, .text = s } });
    }

    fn vTextInput(ptr: *anyopaque, w: *Window, on: bool, rect: geom.Rect) void {
        const b = self(ptr);
        const rec = b.recOf(w) orelse return;
        const store = rec.store orelse return;
        if (b.tsf) |*m| {
            store.setRect(rec.hwnd, w.scale, rect);
            m.focus(store, rec.hwnd, on);
        }
    }

    /// The text store of a window, for the tests.
    pub fn storeOf(b: *Win32, w: *Window) ?*tsf.Store {
        const rec = b.recOf(w) orelse return null;
        return rec.store;
    }

    // ---- Clipboard ----

    /// Opens the clipboard for the first window. Another program can hold
    /// it for a moment, so the open tries again for up to 20 ms.
    fn openClipboard(b: *Win32) bool {
        if (b.windows.items.len == 0) return false;
        const hwnd = b.windows.items[0].hwnd;
        for (0..20) |_| {
            if (w32.OpenClipboard(hwnd) != 0) return true;
            host.sleepUs(1000);
        }
        return false;
    }

    fn isText(typ: []const u8) bool {
        return std.mem.eql(u8, typ, "STRING") or std.mem.eql(u8, typ, "UTF8_STRING");
    }

    /// Puts UTF-8 text on the clipboard as `CF_UNICODETEXT`, with each
    /// `\n` as `\r\n`, the line end of Windows text.
    fn vClipboardSet(ptr: *anyopaque, typ: []const u8, data: []const u8) void {
        const b = self(ptr);
        if (!isText(typ)) return;
        const wide = std.unicode.utf8ToUtf16LeAlloc(b.gpa, data) catch return;
        defer b.gpa.free(wide);
        var lines: usize = 0;
        for (wide) |u| {
            if (u == '\n') lines += 1;
        }
        const units = wide.len + lines + 1;
        const mem = w32.GlobalAlloc(w32.GMEM_MOVEABLE, units * 2) orelse return;
        const p: [*]u16 = @ptrCast(@alignCast(w32.GlobalLock(mem) orelse {
            _ = w32.GlobalFree(mem);
            return;
        }));
        var n: usize = 0;
        for (wide) |u| {
            if (u == '\n') {
                p[n] = '\r';
                n += 1;
            }
            p[n] = u;
            n += 1;
        }
        p[n] = 0;
        _ = w32.GlobalUnlock(mem);
        if (!b.openClipboard()) {
            _ = w32.GlobalFree(mem);
            return;
        }
        _ = w32.EmptyClipboard();
        // The clipboard owns the memory after a set that worked.
        if (w32.SetClipboardData(w32.CF_UNICODETEXT, mem) == null) _ = w32.GlobalFree(mem);
        _ = w32.CloseClipboard();
        b.own_seq = w32.GetClipboardSequenceNumber();
    }

    /// The text of the clipboard as UTF-8 with `\n` line ends, or null when
    /// the last set of the App is still the latest change.
    fn vClipboardGet(ptr: *anyopaque, gpa: std.mem.Allocator, typ: []const u8) ?[]u8 {
        const b = self(ptr);
        if (!isText(typ)) return null;
        if (b.own_seq != 0 and w32.GetClipboardSequenceNumber() == b.own_seq) return null;
        if (!b.openClipboard()) return null;
        defer _ = w32.CloseClipboard();
        const mem = w32.GetClipboardData(w32.CF_UNICODETEXT) orelse return null;
        const raw = w32.GlobalLock(mem) orelse return null;
        defer _ = w32.GlobalUnlock(mem);
        const all: [*]const u16 = @ptrCast(@alignCast(raw));
        const cap = w32.GlobalSize(mem) / 2;
        const len = std.mem.indexOfScalar(u16, all[0..cap], 0) orelse cap;
        const text = std.unicode.utf16LeToUtf8Alloc(gpa, all[0..len]) catch return null;
        var n: usize = 0;
        for (text, 0..) |ch, i| {
            if (ch == '\r' and i + 1 < text.len and text[i + 1] == '\n') continue;
            text[n] = ch;
            n += 1;
        }
        if (n == text.len) return text;
        defer gpa.free(text);
        return gpa.dupe(u8, text[0..n]) catch null;
    }

    // ---- Input ----

    /// The position of a pointer message in logical pixels.
    fn logical(w: *const Window, lp: w32.LPARAM) [2]f32 {
        return .{
            @as(f32, @floatFromInt(w32.loword(lp))) / w.scale,
            @as(f32, @floatFromInt(w32.hiword(lp))) / w.scale,
        };
    }

    fn msgTime() u32 {
        return @bitCast(w32.GetMessageTime());
    }

    fn down(vk: c_int) bool {
        return w32.GetKeyState(vk) < 0;
    }

    /// The modifier state when the current message was posted, with the
    /// bits of the X11 state field, and the buttons that are down.
    fn mods(rec: *const WinRec) Mods {
        return .{
            .shift = down(w32.VK_SHIFT),
            .lock = w32.GetKeyState(w32.VK_CAPITAL) & 1 != 0,
            .control = down(w32.VK_CONTROL),
            .mod1 = down(w32.VK_MENU),
            .mod4 = down(w32.VK_LWIN) or down(w32.VK_RWIN),
            .button1 = rec.buttons & 1 != 0,
            .button2 = rec.buttons & 2 != 0,
            .button3 = rec.buttons & 4 != 0,
        };
    }

    /// The button of a message: 1 left, 2 middle, 3 right, as in Tk, and
    /// 8 and 9 for the two side buttons, as X11 numbers them.
    fn buttonOf(msg: w32.UINT, wp: w32.WPARAM) u8 {
        return switch (msg) {
            w32.WM_LBUTTONDOWN, w32.WM_LBUTTONUP => 1,
            w32.WM_MBUTTONDOWN, w32.WM_MBUTTONUP => 2,
            w32.WM_RBUTTONDOWN, w32.WM_RBUTTONUP => 3,
            else => if ((wp >> 16) & 0xffff == 1) 8 else 9,
        };
    }

    fn isHigh(u: u16) bool {
        return u >= 0xD800 and u <= 0xDBFF;
    }

    fn isLow(u: u16) bool {
        return u >= 0xDC00 and u <= 0xDFFF;
    }

    /// Removes the character message that `TranslateMessage` posted for the
    /// key that is in dispatch, and joins a surrogate pair. Null: the key
    /// gives no character.
    /// With `remove` false the character stays in the queue, for the
    /// mnemonics of a menu bar in DefWindowProc.
    fn takeChar(hwnd: w32.HWND, sys: bool, remove: bool) ?u21 {
        const id = if (sys) w32.WM_SYSCHAR else w32.WM_CHAR;
        var m: w32.MSG = .{};
        if (w32.PeekMessageW(&m, hwnd, id, id, if (remove) w32.PM_REMOVE else 0) == 0) return null;
        const first: u16 = @intCast(m.wParam & 0xffff);
        if (!remove) return if (isHigh(first) or isLow(first)) null else first;
        if (!isHigh(first)) return if (isLow(first)) null else first;
        if (w32.PeekMessageW(&m, hwnd, id, id, w32.PM_REMOVE) == 0) return null;
        const second: u16 = @intCast(m.wParam & 0xffff);
        if (!isLow(second)) return null;
        return 0x10000 + ((@as(u21, first) - 0xD800) << 10) + (@as(u21, second) - 0xDC00);
    }

    fn pushKey(b: *Win32, rec: *WinRec, sym: u32, code: u32, pressed: bool, repeat: bool, cp: ?u21) void {
        var e: Event = .{ .key = .{ .window = rec.win, .keysym = sym, .keycode = code, .pressed = pressed, .repeat = repeat, .mods = mods(rec), .time_ms = msgTime() } };
        if (cp) |c| {
            const n = std.unicode.utf8Encode(c, e.key.text[0..4]) catch 0;
            e.key.text_len = @intCast(n);
        }
        b.push(e);
    }

    /// A key message. A press gets its character from the `WM_CHAR` that
    /// follows it, and its keysym from that character, or from the map of
    /// virtual keys for a key with no printable character. A release
    /// has the keysym of its press.
    fn key(b: *Win32, rec: *WinRec, msg: w32.UINT, wp: w32.WPARAM, lp: w32.LPARAM) void {
        const vk: u32 = @intCast(wp & 0xffff);
        const ulp: usize = @bitCast(lp);
        const scan: u32 = @intCast((ulp >> 16) & 0x1ff);
        // VK_PROCESSKEY: the input method has the key.
        if (vk == 0xE5) return;
        const pressed = msg == w32.WM_KEYDOWN or msg == w32.WM_SYSKEYDOWN;
        if (!pressed) {
            const sym = b.down_syms[scan];
            b.down_syms[scan] = 0;
            const s = if (sym != 0) sym else winkeys.keysym(vk, ulp & (1 << 24) != 0, false) orelse return;
            b.pushKey(rec, s, scan, false, false, null);
            return;
        }
        const repeat = (ulp >> 30) & 1 != 0;
        // With a menu bar, an Alt character stays for DefWindowProc, which opens the menu of its mnemonic.
        const keep = msg == w32.WM_SYSKEYDOWN and rec.bar != null;
        const cp = takeChar(rec.hwnd, msg == w32.WM_SYSKEYDOWN, !keep);
        const m = mods(rec);
        var sym: u32 = 0;
        if (cp) |c| if (c >= 0x20 and c != 0x7f and !winkeys.mapFirst(vk)) {
            sym = keysym_mod.fromCodepoint(c);
        };
        if (sym == 0) sym = winkeys.keysym(vk, ulp & (1 << 24) != 0, m.shift != m.lock) orelse 0;
        if (sym == 0 and cp == null) return;
        if (sym == 0) sym = keysym_mod.fromCodepoint(cp.?);
        b.down_syms[scan] = sym;
        b.pushKey(rec, sym, scan, true, repeat, cp);
    }

    /// A character with no key message: a press and a release of its keysym.
    fn charOnly(b: *Win32, rec: *WinRec, unit: u16) void {
        if (isHigh(unit)) {
            b.high_surrogate = unit;
            return;
        }
        var cp: u21 = unit;
        if (isLow(unit)) {
            if (b.high_surrogate == 0) return;
            cp = 0x10000 + ((@as(u21, b.high_surrogate) - 0xD800) << 10) + (@as(u21, unit) - 0xDC00);
        }
        b.high_surrogate = 0;
        const sym = keysym_mod.fromCodepoint(cp);
        b.pushKey(rec, sym, 0, true, false, cp);
        b.pushKey(rec, sym, 0, false, false, null);
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
        if (msg == wintray.callback_msg) return b.trayMessage(rec, wp, lp);
        if (msg == b.taskbar.button_created and msg != 0) {
            b.taskbar.apply(rec.hwnd, rec.taskbar);
            return 0;
        }
        if (msg == b.trays.taskbar_created and msg != 0) {
            b.trays.addAll();
            return 0;
        }
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
            w32.WM_MOUSEMOVE => {
                if (!rec.tracking) {
                    var tme: w32.TRACKMOUSEEVENT = .{ .dwFlags = w32.TME_LEAVE, .hwndTrack = rec.hwnd };
                    if (w32.TrackMouseEvent(&tme) != 0) rec.tracking = true;
                }
                const p = logical(w, lp);
                b.push(.{ .motion = .{ .window = w, .x = p[0], .y = p[1], .mods = mods(rec), .time_ms = msgTime() } });
                w.feedPointer(p[0], p[1]);
                return 0;
            },
            w32.WM_MOUSELEAVE => {
                rec.tracking = false;
                b.push(.{ .leave = .{ .window = w } });
                return 0;
            },
            w32.WM_LBUTTONDOWN, w32.WM_LBUTTONUP, w32.WM_MBUTTONDOWN, w32.WM_MBUTTONUP, w32.WM_RBUTTONDOWN, w32.WM_RBUTTONUP, w32.WM_XBUTTONDOWN, w32.WM_XBUTTONUP => {
                const button = buttonOf(msg, wp);
                const pressed = msg == w32.WM_LBUTTONDOWN or msg == w32.WM_MBUTTONDOWN or msg == w32.WM_RBUTTONDOWN or msg == w32.WM_XBUTTONDOWN;
                const p = logical(w, lp);
                // The mods have the buttons that were down before this event.
                b.push(.{ .button = .{ .window = w, .button = button, .pressed = pressed, .x = p[0], .y = p[1], .mods = mods(rec), .time_ms = msgTime() } });
                if (button <= 5) {
                    const bit: u8 = @as(u8, 1) << @intCast(button - 1);
                    if (pressed) rec.buttons |= bit else rec.buttons &= ~bit;
                }
                // The window keeps the pointer while a button is down, also outside it.
                if (pressed) _ = w32.SetCapture(rec.hwnd) else if (rec.buttons == 0) _ = w32.ReleaseCapture();
                return if (msg == w32.WM_XBUTTONDOWN or msg == w32.WM_XBUTTONUP) 1 else 0;
            },
            w32.WM_MOUSEWHEEL, w32.WM_MOUSEHWHEEL => {
                // The position of a wheel message is on the screen.
                var pt: w32.POINT = .{ .x = w32.loword(lp), .y = w32.hiword(lp) };
                _ = w32.ScreenToClient(rec.hwnd, &pt);
                const steps = @as(f32, @floatFromInt(w32.hiword(wp))) / w32.WHEEL_DELTA;
                // A scroll event counts steps, with down and right positive.
                const vertical = msg == w32.WM_MOUSEWHEEL;
                b.push(.{ .scroll = .{
                    .window = w,
                    .dx = if (vertical) 0 else steps,
                    .dy = if (vertical) -steps else 0,
                    .x = @as(f32, @floatFromInt(pt.x)) / w.scale,
                    .y = @as(f32, @floatFromInt(pt.y)) / w.scale,
                    .mods = mods(rec),
                    .time_ms = msgTime(),
                } });
                return 0;
            },
            w32.WM_KEYDOWN, w32.WM_SYSKEYDOWN, w32.WM_KEYUP, w32.WM_SYSKEYUP => {
                b.key(rec, msg, wp, lp);
                // Alt+F4 goes on to DefWindowProc, which sends WM_CLOSE. Alt and F10
                // alone open the system menu there, so the other keys stop here.
                if ((msg == w32.WM_SYSKEYDOWN or msg == w32.WM_SYSKEYUP) and wp == 0x73) return w32.DefWindowProcW(rec.hwnd, msg, wp, lp);
                // With a menu bar, Alt and F10 go on too, so they open the bar.
                if ((msg == w32.WM_SYSKEYDOWN or msg == w32.WM_SYSKEYUP) and rec.bar != null) return w32.DefWindowProcW(rec.hwnd, msg, wp, lp);
                return 0;
            },
            w32.WM_CHAR, w32.WM_SYSCHAR => {
                // The mnemonic of a menu bar: the key event of the press already went to the core.
                if (msg == w32.WM_SYSCHAR and rec.bar != null) return w32.DefWindowProcW(rec.hwnd, msg, wp, lp);
                // A character with no key message before it, such as one that SendInput gives.
                b.charOnly(rec, @intCast(wp & 0xffff));
                return 0;
            },
            w32.WM_SETCURSOR => {
                if (w32.loword(lp) == w32.HTCLIENT) {
                    _ = w32.SetCursor(rec.cursor orelse w32.LoadCursorW(null, w32.IDC_ARROW));
                    return 1;
                }
                return w32.DefWindowProcW(rec.hwnd, msg, wp, lp);
            },
            w32.WM_SETTINGCHANGE => {
                // The dark mode of the apps changes with the setting "ImmersiveColorSet".
                if (lp != 0) {
                    const name: [*:0]const u16 = @ptrFromInt(@as(usize, @bitCast(lp)));
                    if (std.mem.eql(u16, std.mem.span(name), std.unicode.utf8ToUtf16LeStringLiteral("ImmersiveColorSet"))) b.push(.{ .appearance = .{ .window = w } });
                }
                return w32.DefWindowProcW(rec.hwnd, msg, wp, lp);
            },
            w32.WM_DWMCOLORIZATIONCOLORCHANGED => {
                b.push(.{ .appearance = .{ .window = w } });
                return 0;
            },
            w32.WM_INITMENUPOPUP => {
                // The high word is 1 for the system menu of the window, which ztk does not own.
                if (w32.hiword(lp) != 0) return w32.DefWindowProcW(rec.hwnd, msg, wp, lp);
                const id = b.menus.idOf(wp) orelse return 0;
                b.menuNow(rec, id, -1, .opening);
                return 0;
            },
            w32.WM_MENUSELECT => {
                const flags: u16 = @bitCast(w32.hiword(wp));
                const item: u16 = @bitCast(w32.loword(wp));
                if (lp == 0 or flags & w32.MF_SYSMENU != 0) return w32.DefWindowProcW(rec.hwnd, msg, wp, lp);
                const id = b.menus.idOf(@bitCast(lp)) orelse return 0;
                // A cascade gives its position, and another item its ID, the index plus 1.
                const entry: i32 = if (flags & w32.MF_POPUP != 0) item else @as(i32, item) - 1;
                b.menuNow(rec, id, entry, .select);
                return 0;
            },
            w32.WM_MENUCOMMAND => {
                const id = b.menus.idOf(@bitCast(lp)) orelse return 0;
                b.push(.{ .menu = .{ .window = w, .menu = id, .entry = @intCast(wp), .action = .invoke } });
                return 0;
            },
            w32.WM_UNINITMENUPOPUP => {
                const id = b.menus.idOf(wp) orelse return 0;
                b.push(.{ .menu = .{ .window = w, .menu = id, .entry = -1, .action = .closed } });
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
