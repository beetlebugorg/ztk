//! Tests of the Win32 backend. They run only with `ZTK_TEST_WINDOWS=1`,
//! which CI sets, and print `SKIP:` otherwise. Each window is hidden
//! (`visible = false`), so no window shows on the desktop. The tests send
//! messages to the window procedure with `SendMessageW` and read the
//! events of `poll`. The App tests draw a label with the CPU output and
//! with Direct3D 12 into the swapchain of a hidden window.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const w32 = @import("../platform/win32.zig");
const be = @import("../platform/windows.zig");
const App = @import("../app.zig").App;
const Event = @import("../event.zig").Event;
const host = @import("../sys/host.zig");
const t = std.testing;

fn enabled() bool {
    if (t.environ.contains(t.allocator, "ZTK_TEST_WINDOWS") catch false) return true;
    std.debug.print("SKIP: set ZTK_TEST_WINDOWS=1 to run the Win32 backend tests\n", .{});
    return false;
}

fn pollAll(b: *be.Win32, out: *std.ArrayListUnmanaged(Event)) !void {
    out.clearRetainingCapacity();
    try b.platform().poll(t.allocator, out);
}

fn has(events: []const Event, comptime tag: std.meta.Tag(Event)) ?Event {
    for (events) |e| if (e == tag) return e;
    return null;
}

test "windows: messages become resize, scale, close, and focus events" {
    if (!enabled()) return;
    const b = try be.Win32.init(t.allocator, .{ .visible = false, .renderer = .cpu });
    defer b.deinit();
    const p = b.platform();
    const w = try p.createWindow(.{ .title = "ztk test", .size = .{ .w = 200, .h = 100 } });
    const hwnd = b.hwndOf(w).?;
    var events: std.ArrayListUnmanaged(Event) = .empty;
    defer events.deinit(t.allocator);
    try pollAll(b, &events);

    // The client area has the logical size times the scale.
    var r: w32.RECT = .{};
    _ = w32.GetClientRect(hwnd, &r);
    try t.expectEqual(@as(i32, @intFromFloat(@round(200 * w.scale))), r.right);
    try t.expectEqual(@as(i32, @intFromFloat(@round(100 * w.scale))), r.bottom);

    const pw: u32 = @intFromFloat(@round(400 * w.scale));
    const ph: u32 = @intFromFloat(@round(300 * w.scale));
    _ = w32.SendMessageW(hwnd, w32.WM_SIZE, 0, @intCast((ph << 16) | pw));
    try pollAll(b, &events);
    const rs = has(events.items, .resize) orelse return error.NoResize;
    try t.expectEqual(@as(i32, 400), rs.resize.size.w);
    try t.expectEqual(@as(i32, 300), rs.resize.size.h);

    _ = w32.SendMessageW(hwnd, w32.WM_CLOSE, 0, 0);
    try pollAll(b, &events);
    try t.expect(has(events.items, .close) != null);
    // The window stays after a close request.
    try t.expect(b.hwndOf(w) != null);

    var suggested: w32.RECT = .{ .left = 10, .top = 10, .right = 810, .bottom = 610 };
    _ = w32.SendMessageW(hwnd, w32.WM_DPICHANGED, (192 << 16) | 192, @bitCast(@intFromPtr(&suggested)));
    try pollAll(b, &events);
    const sc = has(events.items, .scale) orelse return error.NoScale;
    try t.expectEqual(@as(f32, 2), sc.scale.scale);
    try t.expectEqual(@as(f32, 2), w.scale);

    _ = w32.SendMessageW(hwnd, w32.WM_SETFOCUS, 0, 0);
    _ = w32.SendMessageW(hwnd, w32.WM_KILLFOCUS, 0, 0);
    try pollAll(b, &events);
    var focus_in = false;
    var focus_out = false;
    for (events.items) |e| if (e == .focus) {
        if (e.focus.focused) focus_in = true else focus_out = true;
    };
    try t.expect(focus_in and focus_out);
}

test "windows: a frame request gives one frame event at the next tick" {
    if (!enabled()) return;
    const b = try be.Win32.init(t.allocator, .{ .visible = false, .renderer = .cpu });
    defer b.deinit();
    const p = b.platform();
    const w = try p.createWindow(.{ .size = .{ .w = 50, .h = 50 } });
    var events: std.ArrayListUnmanaged(Event) = .empty;
    defer events.deinit(t.allocator);
    try pollAll(b, &events);
    const t0 = host.nowUs();
    p.requestFrame(w);
    var frames: u32 = 0;
    while (host.nowUs() - t0 < 200_000 and frames == 0) {
        p.wait(50_000);
        try pollAll(b, &events);
        for (events.items) |e| if (e == .frame) {
            frames += 1;
        };
    }
    try t.expectEqual(@as(u32, 1), frames);
    // A second request after the tick gives one more frame.
    p.requestFrame(w);
    frames = 0;
    const t1 = host.nowUs();
    while (host.nowUs() - t1 < 200_000 and frames == 0) {
        p.wait(50_000);
        try pollAll(b, &events);
        for (events.items) |e| if (e == .frame) {
            frames += 1;
        };
    }
    try t.expectEqual(@as(u32, 1), frames);
}

fn drawLabel(renderer: be.Renderer) !?u32 {
    const b = be.Win32.init(t.allocator, .{ .visible = false, .renderer = renderer }) catch |e| {
        std.debug.print("SKIP: no Win32 backend ({s})\n", .{@errorName(e)});
        return null;
    };
    defer b.deinit();
    var it: ztcl.Interp = undefined;
    try it.init(t.allocator);
    defer it.deinit();
    const app = App.init(t.allocator, &it, .{
        .platform = b.platform(),
        .io = t.io,
        .render_mode = .threaded,
        .animations = false,
    }) catch |e| {
        std.debug.print("SKIP: no window with the {s} output ({s})\n", .{ @tagName(renderer), @errorName(e) });
        return null;
    };
    defer app.deinit();
    _ = try it.eval("label .l -text {Hello from Win32}; pack .l; update");
    app.render.flush();
    std.debug.print("windows: output {s}\n", .{b.outputName(app.window.?)});
    return if (renderer == .cpu) b.cpu_frames.load(.monotonic) else b.gpu_frames.load(.monotonic);
}

test "windows: the App draws a label with the CPU output" {
    if (!enabled()) return;
    const n = try drawLabel(.cpu) orelse return;
    try t.expect(n >= 1);
}

test "windows: the App draws a label with Direct3D 12 into a swapchain" {
    if (!enabled()) return;
    const n = try drawLabel(.d3d12) orelse return;
    try t.expect(n >= 1);
}

fn openHidden(out: *std.ArrayListUnmanaged(Event)) !struct { b: *be.Win32, w: *@import("../platform/platform.zig").Window, hwnd: w32.HWND } {
    const b = try be.Win32.init(t.allocator, .{ .visible = false, .renderer = .cpu });
    errdefer b.deinit();
    const w = try b.platform().createWindow(.{ .size = .{ .w = 200, .h = 100 } });
    try pollAll(b, out);
    return .{ .b = b, .w = w, .hwnd = b.hwndOf(w).? };
}

fn lparamXY(x: u32, y: u32) w32.LPARAM {
    return @intCast((y << 16) | x);
}

test "windows: pointer messages become motion, button, wheel, and leave events" {
    if (!enabled()) return;
    var events: std.ArrayListUnmanaged(Event) = .empty;
    defer events.deinit(t.allocator);
    const o = try openHidden(&events);
    defer o.b.deinit();
    const s = o.w.scale;
    const px: u32 = @intFromFloat(@round(40 * s));
    const py: u32 = @intFromFloat(@round(20 * s));
    _ = w32.SendMessageW(o.hwnd, w32.WM_MOUSEMOVE, 0, lparamXY(px, py));
    try pollAll(o.b, &events);
    const m = has(events.items, .motion) orelse return error.NoMotion;
    try t.expectApproxEqAbs(@as(f32, 40), m.motion.x, 0.5);
    try t.expectApproxEqAbs(@as(f32, 20), m.motion.y, 0.5);

    _ = w32.SendMessageW(o.hwnd, w32.WM_LBUTTONDOWN, 1, lparamXY(px, py));
    _ = w32.SendMessageW(o.hwnd, w32.WM_LBUTTONUP, 0, lparamXY(px, py));
    try pollAll(o.b, &events);
    try t.expectEqual(@as(usize, 2), events.items.len);
    try t.expect(events.items[0].button.pressed and events.items[0].button.button == 1);
    try t.expect(!events.items[0].button.mods.button1);
    // The release has the button that was down before it.
    try t.expect(!events.items[1].button.pressed and events.items[1].button.mods.button1);

    _ = w32.SendMessageW(o.hwnd, w32.WM_RBUTTONDOWN, 2, lparamXY(px, py));
    _ = w32.SendMessageW(o.hwnd, w32.WM_RBUTTONUP, 0, lparamXY(px, py));
    try pollAll(o.b, &events);
    try t.expectEqual(@as(u8, 3), events.items[0].button.button);

    // One step of the wheel away from the user scrolls up.
    var pt: w32.POINT = .{ .x = @intCast(px), .y = @intCast(py) };
    _ = w32.ClientToScreen(o.hwnd, &pt);
    const screen: w32.LPARAM = @intCast((@as(u32, @bitCast(@as(i32, pt.y))) & 0xffff) << 16 | (@as(u32, @bitCast(@as(i32, pt.x))) & 0xffff));
    _ = w32.SendMessageW(o.hwnd, w32.WM_MOUSEWHEEL, 120 << 16, screen);
    try pollAll(o.b, &events);
    const sc = has(events.items, .scroll) orelse return error.NoScroll;
    try t.expectEqual(@as(f32, -1), sc.scroll.dy);
    try t.expectApproxEqAbs(@as(f32, 40), sc.scroll.x, 0.5);

    _ = w32.SendMessageW(o.hwnd, w32.WM_MOUSELEAVE, 0, 0);
    try pollAll(o.b, &events);
    try t.expect(has(events.items, .leave) != null);
}

fn keyLparam(scan: u32, extended: bool, up: bool) w32.LPARAM {
    var v: u32 = 1 | (scan << 16);
    if (extended) v |= 1 << 24;
    if (up) v |= (1 << 30) | (1 << 31);
    return @bitCast(@as(usize, v));
}

test "windows: a key press gets the character that follows it" {
    if (!enabled()) return;
    var events: std.ArrayListUnmanaged(Event) = .empty;
    defer events.deinit(t.allocator);
    const o = try openHidden(&events);
    defer o.b.deinit();

    // TranslateMessage posts WM_CHAR before the dispatch of WM_KEYDOWN. The test posts it the same way.
    _ = w32.PostMessageW(o.hwnd, w32.WM_CHAR, 'a', keyLparam(0x1e, false, false));
    _ = w32.SendMessageW(o.hwnd, w32.WM_KEYDOWN, 'A', keyLparam(0x1e, false, false));
    _ = w32.SendMessageW(o.hwnd, w32.WM_KEYUP, 'A', keyLparam(0x1e, false, true));
    try pollAll(o.b, &events);
    try t.expectEqual(@as(usize, 2), events.items.len);
    const k = events.items[0].key;
    try t.expect(k.pressed);
    try t.expectEqual(@as(u32, 'a'), k.keysym);
    try t.expectEqualStrings("a", k.text[0..k.text_len]);
    try t.expectEqual(@as(u32, 'a'), events.items[1].key.keysym);
    try t.expect(!events.items[1].key.pressed);

    _ = w32.PostMessageW(o.hwnd, w32.WM_CHAR, 13, keyLparam(0x1c, false, false));
    _ = w32.SendMessageW(o.hwnd, w32.WM_KEYDOWN, 0x0D, keyLparam(0x1c, false, false));
    _ = w32.SendMessageW(o.hwnd, w32.WM_KEYDOWN, 0x25, keyLparam(0x4b, true, false));
    try pollAll(o.b, &events);
    try t.expectEqual(@as(u32, 0xff0d), events.items[0].key.keysym);
    try t.expectEqualStrings("\r", events.items[0].key.text[0..events.items[0].key.text_len]);
    try t.expectEqual(@as(u32, 0xff51), events.items[1].key.keysym);
    try t.expectEqual(@as(u8, 0), events.items[1].key.text_len);

    // A character outside the first plane comes as a surrogate pair.
    _ = w32.PostMessageW(o.hwnd, w32.WM_CHAR, 0xD83D, 0);
    _ = w32.PostMessageW(o.hwnd, w32.WM_CHAR, 0xDE00, 0);
    _ = w32.SendMessageW(o.hwnd, w32.WM_KEYDOWN, 0xE7, keyLparam(0, false, false));
    try pollAll(o.b, &events);
    try t.expectEqualStrings("\u{1F600}", events.items[0].key.text[0..events.items[0].key.text_len]);

    // A character with no key message gives a press and a release.
    _ = w32.SendMessageW(o.hwnd, w32.WM_CHAR, 0xE9, 0);
    try pollAll(o.b, &events);
    try t.expectEqual(@as(usize, 2), events.items.len);
    try t.expectEqualStrings("\u{E9}", events.items[0].key.text[0..events.items[0].key.text_len]);
}

test "windows: setCursor loads the shape of the system" {
    if (!enabled()) return;
    var events: std.ArrayListUnmanaged(Event) = .empty;
    defer events.deinit(t.allocator);
    const o = try openHidden(&events);
    defer o.b.deinit();
    o.b.platform().setCursor(o.w, .text);
    try t.expectEqual(w32.LoadCursorW(null, w32.IDC_IBEAM), o.b.cursorHandle(o.w));
    o.b.platform().setCursor(o.w, .ew_resize);
    try t.expectEqual(w32.LoadCursorW(null, w32.IDC_SIZEWE), o.b.cursorHandle(o.w));
}

test "windows: the clipboard of the system round-trips text with CRLF line ends" {
    if (!enabled()) return;
    // The test changes the clipboard of the machine, so it has its own
    // variable. It puts the text that was there back at the end.
    if (!(t.environ.contains(t.allocator, "ZTK_TEST_CLIPBOARD") catch false)) {
        std.debug.print("SKIP: set ZTK_TEST_CLIPBOARD=1 to run the clipboard test\n", .{});
        return;
    }
    // A process with no clipboard access to its window station (a service,
    // or a session with no desktop) gets 0 here, and OpenClipboard fails.
    if (w32.GetClipboardSequenceNumber() == 0) {
        std.debug.print("SKIP: this process has no access to the clipboard\n", .{});
        return;
    }
    var events: std.ArrayListUnmanaged(Event) = .empty;
    defer events.deinit(t.allocator);
    const a = try openHidden(&events);
    defer a.b.deinit();
    const other = try openHidden(&events);
    defer other.b.deinit();
    const pa = a.b.platform();
    const po = other.b.platform();

    const saved = pa.clipboardGet(t.allocator, "STRING");
    defer if (saved) |s| t.allocator.free(s);
    defer pa.clipboardSet("STRING", saved orelse "");

    const text = "line one\nzwei \u{FC} \u{1F600}";
    pa.clipboardSet("STRING", text);
    // The text of the App is the latest, so the store of the App answers.
    try t.expect(pa.clipboardGet(t.allocator, "STRING") == null);
    // A second backend reads it in the place of another program.
    const read = po.clipboardGet(t.allocator, "STRING") orelse return error.NoText;
    defer t.allocator.free(read);
    try t.expectEqualStrings(text, read);

    po.clipboardSet("STRING", "from the other one");
    const back = pa.clipboardGet(t.allocator, "STRING") orelse return error.NoText;
    defer t.allocator.free(back);
    try t.expectEqualStrings("from the other one", back);
}

test "windows: an entry with the focus gets the text store, and a commit inserts text" {
    if (!enabled()) return;
    const b = try be.Win32.init(t.allocator, .{ .visible = false, .renderer = .cpu });
    defer b.deinit();
    var it: ztcl.Interp = undefined;
    try it.init(t.allocator);
    defer it.deinit();
    const app = try App.init(t.allocator, &it, .{ .platform = b.platform(), .io = t.io, .render_mode = .inline_draw, .animations = false });
    defer app.deinit();
    const store = b.storeOf(app.window.?) orelse {
        std.debug.print("SKIP: no TSF in this session\n", .{});
        return;
    };
    _ = try it.eval("entry .e; pack .e; focus -force .e; update");
    const e = app.find(".e").?;
    try t.expectEqual(e.geom.w, store.rect.w);
    // The store gives a commit as it does at the end of a composition.
    store.owner.commit(store.owner.ctx, "\u{65E5}\u{672C}");
    _ = try it.eval("update");
    try t.expectEqualStrings("\u{65E5}\u{672C}", try it.str(try it.eval(".e get")));
}

test "windows: the appearance of the system and its change message" {
    if (!enabled()) return;
    var events: std.ArrayListUnmanaged(Event) = .empty;
    defer events.deinit(t.allocator);
    const o = try openHidden(&events);
    defer o.b.deinit();
    const a = o.b.appearanceNow();
    std.debug.print("windows: dark {}, accent {any}\n", .{ a.dark, a.accent });
    const name = std.unicode.utf8ToUtf16LeStringLiteral("ImmersiveColorSet");
    _ = w32.SendMessageW(o.hwnd, w32.WM_SETTINGCHANGE, 0, @bitCast(@intFromPtr(name)));
    try pollAll(o.b, &events);
    try t.expect(has(events.items, .appearance) != null);
    const other = std.unicode.utf8ToUtf16LeStringLiteral("intl");
    _ = w32.SendMessageW(o.hwnd, w32.WM_SETTINGCHANGE, 0, @bitCast(@intFromPtr(other)));
    try pollAll(o.b, &events);
    try t.expect(has(events.items, .appearance) == null);
}

const plat = @import("../platform/platform.zig");

fn itemText(h: w32.HMENU, pos: u32, buf: []u16) []const u16 {
    var info: w32.MENUITEMINFOW = .{ .fMask = w32.MIIM_STRING, .dwTypeData = @ptrCast(buf.ptr), .cch = @intCast(buf.len) };
    _ = w32.GetMenuItemInfoW(h, pos, 1, &info);
    return buf[0..info.cch];
}

fn itemInfo(h: w32.HMENU, pos: u32) w32.MENUITEMINFOW {
    var info: w32.MENUITEMINFOW = .{ .fMask = w32.MIIM_FTYPE | w32.MIIM_STATE | w32.MIIM_SUBMENU | w32.MIIM_ID };
    _ = w32.GetMenuItemInfoW(h, pos, 1, &info);
    return info;
}

test "windows: a native menu has the entries, the marks, and the cascade" {
    if (!enabled()) return;
    var events: std.ArrayListUnmanaged(Event) = .empty;
    defer events.deinit(t.allocator);
    const o = try openHidden(&events);
    defer o.b.deinit();
    const p = o.b.platform();
    try t.expect(p.hasNativeMenus());
    p.menuSet(&.{ .id = 2, .entries = &.{.{ .label = "Recent" }} });
    p.menuSet(&.{ .id = 1, .title = "File", .entries = &.{
        .{ .label = "Open", .accelerator = "Ctrl+O", .underline = 0 },
        .{ .kind = .separator },
        .{ .kind = .checkbutton, .label = "Wrap", .selected = true },
        .{ .kind = .radiobutton, .label = "Small" },
        .{ .label = "Gone", .enabled = false },
        .{ .kind = .cascade, .label = "More", .submenu = 2 },
    } });
    const h = o.b.menus.handleOf(1).?;
    try t.expectEqual(@as(c_int, 6), w32.GetMenuItemCount(h));
    var buf: [64]u16 = undefined;
    try t.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("&Open\tCtrl+O"), itemText(h, 0, &buf));
    try t.expect(itemInfo(h, 1).fType & w32.MFT_SEPARATOR != 0);
    try t.expect(itemInfo(h, 2).fState & w32.MFS_CHECKED != 0);
    try t.expect(itemInfo(h, 3).fType & w32.MFT_RADIOCHECK != 0);
    try t.expect(itemInfo(h, 4).fState & w32.MFS_GRAYED != 0);
    try t.expectEqual(o.b.menus.handleOf(2), itemInfo(h, 5).hSubMenu);
    // One entry changes in place.
    p.menuEntrySet(1, 2, &.{ .kind = .checkbutton, .label = "Wrap lines", .selected = false });
    try t.expect(itemInfo(h, 2).fState & w32.MFS_CHECKED == 0);
    try t.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("Wrap lines"), itemText(h, 2, &buf));
    p.menuDrop(2);
    try t.expect(o.b.menus.handleOf(2) == null);
}

const Seen = struct {
    p: plat.Platform,
    opened: u32 = 0,
    selected: i32 = -2,

    fn call(ctx: ?*anyopaque, id: plat.MenuId, entry: i32, action: @import("../event.zig").MenuAction) void {
        const s: *Seen = @ptrCast(@alignCast(ctx.?));
        switch (action) {
            .opening => {
                s.opened += 1;
                // The core runs -postcommand here and gives the new entries.
                s.p.menuSet(&.{ .id = id, .entries = &.{ .{ .label = "A" }, .{ .label = "B" }, .{ .label = "C" } } });
            },
            .select => s.selected = entry,
            else => {},
        }
    }
};

test "windows: a menu bar keeps the client size, and the menu messages reach the core" {
    if (!enabled()) return;
    var events: std.ArrayListUnmanaged(Event) = .empty;
    defer events.deinit(t.allocator);
    const o = try openHidden(&events);
    defer o.b.deinit();
    const p = o.b.platform();
    var seen: Seen = .{ .p = p };
    p.setMenuHandler(.{ .ctx = &seen, .call = Seen.call });
    p.menuSet(&.{ .id = 1, .title = "File", .entries = &.{.{ .label = "Open" }} });
    p.menuSet(&.{ .id = 3, .title = "Help", .role = .help, .entries = &.{.{ .label = "About" }} });
    p.menuSet(&.{ .id = 10, .entries = &.{ .{ .kind = .cascade, .label = "File", .underline = 0, .submenu = 1 }, .{ .kind = .cascade, .label = "Help", .submenu = 3 } } });
    p.setMenuBar(o.w, 10);
    const bar = w32.GetMenu(o.hwnd) orelse return error.NoBar;
    try t.expectEqual(@as(c_int, 2), w32.GetMenuItemCount(bar));
    try t.expect(itemInfo(bar, 1).fType & w32.MFT_RIGHTJUSTIFY != 0);
    var r: w32.RECT = .{};
    _ = w32.GetClientRect(o.hwnd, &r);
    try t.expectEqual(@as(i32, @intFromFloat(@round(100 * o.w.scale))), r.bottom);

    const h1 = o.b.menus.handleOf(1).?;
    _ = w32.SendMessageW(o.hwnd, w32.WM_INITMENUPOPUP, @intFromPtr(h1), 0);
    try t.expectEqual(@as(u32, 1), seen.opened);
    // The handler gave three entries before the message returned.
    try t.expectEqual(@as(c_int, 3), w32.GetMenuItemCount(h1));
    // The item of entry 1 has the ID 2.
    _ = w32.SendMessageW(o.hwnd, w32.WM_MENUSELECT, 2, @bitCast(@intFromPtr(h1)));
    try t.expectEqual(@as(i32, 1), seen.selected);
    try pollAll(o.b, &events);
    _ = w32.SendMessageW(o.hwnd, w32.WM_MENUCOMMAND, 2, @bitCast(@intFromPtr(h1)));
    _ = w32.SendMessageW(o.hwnd, w32.WM_UNINITMENUPOPUP, @intFromPtr(h1), 0);
    try pollAll(o.b, &events);
    try t.expectEqual(@as(usize, 2), events.items.len);
    const inv = events.items[0].menu;
    try t.expectEqual(@as(u32, 1), inv.menu);
    try t.expectEqual(@as(i32, 2), inv.entry);
    try t.expect(inv.action == .invoke);
    try t.expect(events.items[1].menu.action == .closed);

    p.setMenuBar(o.w, 0);
    try t.expect(w32.GetMenu(o.hwnd) == null);
}

extern "user32" fn SetTimer(hwnd: ?w32.HWND, id: usize, ms: u32, f: ?*const fn (?w32.HWND, u32, usize, u32) callconv(.winapi) void) callconv(.winapi) usize;
extern "user32" fn KillTimer(hwnd: ?w32.HWND, id: usize) callconv(.winapi) w32.BOOL;

fn endMenu(_: ?w32.HWND, _: u32, _: usize, _: u32) callconv(.winapi) void {
    _ = w32.EndMenu();
}

test "windows: a posted menu runs its loop and returns when the menu ends" {
    if (!enabled()) return;
    var events: std.ArrayListUnmanaged(Event) = .empty;
    defer events.deinit(t.allocator);
    const o = try openHidden(&events);
    defer o.b.deinit();
    const p = o.b.platform();
    p.menuSet(&.{ .id = 1, .entries = &.{ .{ .label = "Cut" }, .{ .label = "Copy" } } });
    // A timer of the thread runs inside the menu loop and ends the menu.
    const timer = SetTimer(null, 0, 100, endMenu);
    defer _ = KillTimer(null, timer);
    const t0 = host.nowUs();
    p.postMenu(o.w, 1, .{ .x = 10, .y = 10 }, -1);
    try t.expect(host.nowUs() - t0 < 2_000_000);
}

fn menuApp(b: *be.Win32, it: *ztcl.Interp) !*App {
    try it.init(t.allocator);
    errdefer it.deinit();
    return App.init(t.allocator, it, .{ .platform = b.platform(), .io = t.io, .render_mode = .inline_draw, .animations = false });
}

test "windows: a Tk menu bar, its cascade, -postcommand, and a command" {
    if (!enabled()) return;
    const b = try be.Win32.init(t.allocator, .{ .visible = false, .renderer = .cpu });
    defer b.deinit();
    var it: ztcl.Interp = undefined;
    const app = try menuApp(b, &it);
    defer it.deinit();
    defer app.deinit();
    _ = try it.eval(
        \\set ::hit 0
        \\set ::posts 0
        \\menu .mb -tearoff 0
        \\menu .mb.file -tearoff 0 -postcommand {incr ::posts; .mb.file add command -label Late}
        \\.mb.file add command -label Open -accelerator Ctrl+O -underline 0 -command {set ::hit 1}
        \\.mb.file add checkbutton -label Wrap -variable ::wrap
        \\.mb add cascade -label File -underline 0 -menu .mb.file
        \\menu .mb.help -tearoff 0
        \\.mb.help add command -label About
        \\.mb add cascade -label Help -menu .mb.help
        \\. configure -menu .mb
        \\update
    );
    const hwnd = b.hwndOf(app.window.?).?;
    const bar = w32.GetMenu(hwnd) orelse return error.NoBar;
    try t.expectEqual(@as(c_int, 2), w32.GetMenuItemCount(bar));
    var buf: [64]u16 = undefined;
    try t.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("&File"), itemText(bar, 0, &buf));
    try t.expect(itemInfo(bar, 1).fType & w32.MFT_RIGHTJUSTIFY != 0);
    const file = itemInfo(bar, 0).hSubMenu orelse return error.NoCascade;
    try t.expectEqual(@as(c_int, 2), w32.GetMenuItemCount(file));
    try t.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("&Open\tCtrl+O"), itemText(file, 0, &buf));

    // The menu loop of Windows: -postcommand runs before the menu shows, and its entry is there.
    _ = w32.SendMessageW(hwnd, w32.WM_INITMENUPOPUP, @intFromPtr(file), 0);
    try t.expectEqualStrings("1", try it.str(try it.eval("set ::posts")));
    try t.expectEqual(@as(c_int, 3), w32.GetMenuItemCount(file));

    // A choice of Open runs its -command.
    _ = w32.SendMessageW(hwnd, w32.WM_MENUCOMMAND, 0, @bitCast(@intFromPtr(file)));
    _ = w32.SendMessageW(hwnd, w32.WM_UNINITMENUPOPUP, @intFromPtr(file), 0);
    _ = try it.eval("update");
    try t.expectEqualStrings("1", try it.str(try it.eval("set ::hit")));

    // A choice of the check entry sets its variable. The core sends the
    // entries again when the menu opens, so the mark shows at the next open.
    _ = w32.SendMessageW(hwnd, w32.WM_MENUCOMMAND, 1, @bitCast(@intFromPtr(file)));
    _ = try it.eval("update");
    try t.expectEqualStrings("1", try it.str(try it.eval("set ::wrap")));
    _ = w32.SendMessageW(hwnd, w32.WM_INITMENUPOPUP, @intFromPtr(file), 0);
    try t.expect(itemInfo(file, 1).fState & w32.MFS_CHECKED != 0);

    _ = try it.eval(". configure -menu {}; update");
    try t.expect(w32.GetMenu(hwnd) == null);
}

test "windows: tk_popup runs the menu loop of Windows and returns" {
    if (!enabled()) return;
    const b = try be.Win32.init(t.allocator, .{ .visible = false, .renderer = .cpu });
    defer b.deinit();
    var it: ztcl.Interp = undefined;
    const app = try menuApp(b, &it);
    defer it.deinit();
    defer app.deinit();
    _ = try it.eval("menu .pop -tearoff 0; .pop add command -label Cut; .pop add command -label Copy; update");
    const timer = SetTimer(null, 0, 100, endMenu);
    defer _ = KillTimer(null, timer);
    const t0 = host.nowUs();
    _ = try it.eval("tk_popup .pop 20 20; update");
    try t.expect(host.nowUs() - t0 < 2_000_000);
}

test "windows: a tray icon in the notification area, its actions, and its menu" {
    if (!enabled()) return;
    // A tray icon shows in the notification area of the desktop, so the
    // test has its own variable, which CI sets (AGENTS.md, rule 12).
    if (!(t.environ.contains(t.allocator, "ZTK_TEST_TRAY") catch false)) {
        std.debug.print("SKIP: set ZTK_TEST_TRAY=1 to run the tray test\n", .{});
        return;
    }
    var events: std.ArrayListUnmanaged(Event) = .empty;
    defer events.deinit(t.allocator);
    const o = try openHidden(&events);
    defer o.b.deinit();
    const p = o.b.platform();
    var px: [16 * 16 * 4]u8 = @splat(0xC0);
    const icon: plat.TrayIcon = .{ .width = 16, .height = 16, .pixels = &px };
    const id = p.trayCreate(o.w, icon, false, "ztk test");
    if (id == 0) {
        std.debug.print("SKIP: the shell of this session has no notification area\n", .{});
        return;
    }
    defer p.trayDrop(id);
    p.menuSet(&.{ .id = 7, .entries = &.{ .{ .label = "Show" }, .{ .label = "Quit" } } });
    p.traySet(id, icon, false, "ztk test", 7);
    try t.expectEqual(@as(?plat.MenuId, 7), o.b.trayMenu(id));
    const lp_click: w32.LPARAM = @intCast((id << 16) | w32.NIN_SELECT);
    _ = w32.SendMessageW(o.hwnd, @import("../platform/wintray.zig").callback_msg, 0, lp_click);
    try pollAll(o.b, &events);
    const ev = has(events.items, .tray) orelse return error.NoTray;
    try t.expectEqual(id, ev.tray.id);
    try t.expect(ev.tray.action == .click);
    // The menu shows in the menu loop, which a timer ends.
    const timer = SetTimer(null, 0, 100, endMenu);
    defer _ = KillTimer(null, timer);
    const lp_menu: w32.LPARAM = @intCast((id << 16) | w32.WM_CONTEXTMENU);
    _ = w32.SendMessageW(o.hwnd, @import("../platform/wintray.zig").callback_msg, (20 << 16) | 20, lp_menu);
    try pollAll(o.b, &events);
    try t.expect(has(events.items, .tray).?.tray.action == .menu);
}

test "windows: the thumbnail buttons keep their slots, and a click gives a thumb event" {
    if (!enabled()) return;
    const tb = @import("../platform/wintaskbar.zig");
    try t.expectEqual(@as(usize, 552), @sizeOf(tb.THUMBBUTTON));
    var events: std.ArrayListUnmanaged(Event) = .empty;
    defer events.deinit(t.allocator);
    const o = try openHidden(&events);
    defer o.b.deinit();
    const p = o.b.platform();
    var px: [16 * 16 * 4]u8 = @splat(0xff);
    p.vtable.winThumbBar.?(p.ptr, o.w, &.{
        .{ .icon = .{ .width = 16, .height = 16, .pixels = &px }, .tooltip = "Play" },
        .{ .icon = .{ .width = 16, .height = 16, .pixels = &px }, .tooltip = "Next", .enabled = false },
    });
    const r = o.b.recOf(o.w).?;
    // A hidden window has no taskbar button, so the shell has not taken
    // the buttons yet; the message of the button adds them.
    try t.expect(!r.thumbs.added);
    try t.expect(r.thumbs.buttons[0].hIcon != null);
    try t.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("Next"), std.mem.sliceTo(&r.thumbs.buttons[1].szTip, 0));
    try t.expectEqual(tb.THBF_DISABLED, r.thumbs.buttons[1].dwFlags);
    try t.expectEqual(tb.THBF_HIDDEN, r.thumbs.buttons[2].dwFlags);
    // WM_COMMAND with THBN_CLICKED for the button 1.
    _ = w32.SendMessageW(o.hwnd, 0x0111, (tb.THBN_CLICKED << 16) | 1, 0);
    try pollAll(o.b, &events);
    try t.expectEqual(@as(u32, 1), has(events.items, .thumb).?.thumb.index);
}

test "windows: a drag out gives the files and the text, and a cancel ends DoDragDrop" {
    if (!enabled()) return;
    const drag = @import("../platform/windrag.zig");
    const drop = @import("../platform/windrop.zig");
    const gpa = t.allocator;
    const o = try drag.DataObject.create(&gpa, .{ .files = &.{ "C:/a/b.txt", "C:/c d.txt" }, .text = "hi" });
    defer _ = o.vtbl.Release(o);
    const files = (try drag.readFormat(gpa, o, drop.CF_HDROP)).?;
    defer gpa.free(files);
    // DROPFILES: pFiles 20 and fWide 1, then the paths with `\`.
    try t.expectEqual(@as(u32, 20), std.mem.readInt(u32, files[0..4], .little));
    try t.expectEqual(@as(u32, 1), std.mem.readInt(u32, files[16..20], .little));
    const want = std.unicode.utf8ToUtf16LeStringLiteral("C:\\a\\b.txt\x00C:\\c d.txt\x00\x00");
    try t.expectEqualSlices(u8, std.mem.sliceAsBytes(want), files[20..]);
    const text = (try drag.readFormat(gpa, o, drop.CF_UNICODETEXT)).?;
    defer gpa.free(text);
    try t.expectEqualSlices(u8, std.mem.sliceAsBytes(std.unicode.utf8ToUtf16LeStringLiteral("hi\x00")), text);
    // CF_TEXT is not a format of the drag.
    var f: drop.FORMATETC = .{ .cfFormat = 1 };
    try t.expect(o.vtbl.QueryGetData(o, &f) < 0);
    var e: ?*anyopaque = null;
    try t.expectEqual(@as(i32, 0), o.vtbl.EnumFormatEtc(o, 1, &e));
    defer @import("../sys/com.zig").release(e.?);
    var got: [4]drop.FORMATETC = undefined;
    var n: u32 = 0;
    _ = @import("../sys/com.zig").call(i32, e.?, 3, .{ @as(u32, 4), &got, &n });
    try t.expectEqual(@as(u32, 2), n);
    // A source that cancels at once: DoDragDrop ends with no drop.
    var src: drag.DropSource = .{ .cancel_now = true };
    try t.expectEqual(@import("../platform/platform.zig").DragAction.none, drag.runWith(&gpa, .{ .text = "x" }, &src));
}

test "windows: a jump list of tasks builds, and the test drops it with no commit" {
    if (!enabled()) return;
    const jump = @import("../platform/winjump.zig");
    // A commit changes the shell state of the user for this program, so
    // the test aborts the list it built.
    const l = jump.build(t.allocator, &.{
        .{ .title = "New window", .args = "--new", .description = "Opens a new window" },
        .{ .title = "Open", .args = "--open", .icon = "C:/Windows/System32/shell32.dll", .icon_index = 3 },
    }) catch |e| {
        std.debug.print("SKIP: no jump list in this session ({s})\n", .{@errorName(e)});
        return;
    };
    try t.expectEqual(@as(usize, 2), l.count);
    l.abort();
}

test "windows: ztk::win::backdrop sets the system backdrop of a hidden window" {
    if (!enabled()) return;
    const ws = @import("../platform/winstate.zig");
    var events: std.ArrayListUnmanaged(Event) = .empty;
    defer events.deinit(t.allocator);
    const o = try openHidden(&events);
    defer o.b.deinit();
    try t.expect(o.b.platform().vtable.winBackdrop != null);
    // Windows 11 22H2 and later have the attribute; an older system gives
    // false.
    if (!ws.setBackdrop(o.hwnd, .mica)) {
        std.debug.print("SKIP: no system backdrop on this Windows\n", .{});
        return;
    }
    try t.expect(ws.setBackdrop(o.hwnd, .acrylic));
    try t.expect(ws.setBackdrop(o.hwnd, .auto));
}

test "windows: the title bar of the system follows the dark scheme of the app" {
    if (!enabled()) return;
    const ws = @import("../platform/winstate.zig");
    var events: std.ArrayListUnmanaged(Event) = .empty;
    defer events.deinit(t.allocator);
    const b = try be.Win32.init(t.allocator, .{ .visible = false, .renderer = .cpu });
    defer b.deinit();
    const p = b.platform();
    const w = try p.createWindow(.{ .size = .{ .w = 200, .h = 100 }, .dark = true });
    try pollAll(b, &events);
    const hwnd = b.hwndOf(w).?;
    // Windows 10 before 20H1 has no such attribute.
    const first = ws.isDark(hwnd) orelse {
        std.debug.print("SKIP: no dark title bar on this Windows\n", .{});
        return;
    };
    try t.expect(first);
    p.setWindowDark(w, false);
    try t.expectEqual(@as(?bool, false), ws.isDark(hwnd));
    p.setWindowDark(w, true);
    try t.expectEqual(@as(?bool, true), ws.isDark(hwnd));
}

test "windows: full screen and topmost of wm attributes change the window and come back" {
    if (!enabled()) return;
    const ws = @import("../platform/winstate.zig");
    const Vis = struct {
        extern "user32" fn IsWindowVisible(h: w32.HWND) callconv(.winapi) i32;
        extern "user32" fn GetWindowRect(h: w32.HWND, r: *w32.RECT) callconv(.winapi) i32;
    };
    var events: std.ArrayListUnmanaged(Event) = .empty;
    defer events.deinit(t.allocator);
    const o = try openHidden(&events);
    defer o.b.deinit();
    const p = o.b.platform();
    try t.expect(p.hasWindowState());
    var before: w32.RECT = .{};
    _ = Vis.GetWindowRect(o.hwnd, &before);
    const style = w32.GetWindowLongPtrW(o.hwnd, ws.GWL_STYLE);

    p.setWindowState(o.w, .{ .fullscreen = true, .topmost = true });
    const fs_style: usize = @bitCast(w32.GetWindowLongPtrW(o.hwnd, ws.GWL_STYLE));
    try t.expect(fs_style & w32.WS_POPUP != 0);
    const ex: usize = @bitCast(w32.GetWindowLongPtrW(o.hwnd, ws.GWL_EXSTYLE));
    try t.expect(ex & ws.WS_EX_TOPMOST != 0);
    var full: w32.RECT = .{};
    _ = Vis.GetWindowRect(o.hwnd, &full);
    try t.expect(full.right - full.left >= before.right - before.left);
    // No call of the state shows the window.
    try t.expectEqual(@as(i32, 0), Vis.IsWindowVisible(o.hwnd));

    p.setWindowState(o.w, .{});
    try t.expectEqual(style, w32.GetWindowLongPtrW(o.hwnd, ws.GWL_STYLE));
    const ex2: usize = @bitCast(w32.GetWindowLongPtrW(o.hwnd, ws.GWL_EXSTYLE));
    try t.expect(ex2 & ws.WS_EX_TOPMOST == 0);
    var after: w32.RECT = .{};
    _ = Vis.GetWindowRect(o.hwnd, &after);
    try t.expectEqual(before, after);
    try t.expectEqual(@as(i32, 0), Vis.IsWindowVisible(o.hwnd));
    // The setting of the system for less motion is a boolean either way.
    _ = p.reducedMotion().?;
}

test "windows: the color dialog and the message box of Windows get their options" {
    if (!enabled()) return;
    const box = @import("../platform/winbox.zig");
    const plat_ = @import("../platform/platform.zig");
    const title = std.unicode.utf8ToUtf16LeStringLiteral("Pick");
    const c = box.colorConfig(&.{ .title = "Pick", .initial = .{ .r = 0x10, .g = 0x20, .b = 0x30 } }, null, title);
    try t.expectEqual(@as(u32, 72), c.lStructSize);
    try t.expectEqual(@as(u32, 0x302010), c.rgbResult);
    try t.expect(c.Flags & box.cc.rgb_init != 0 and c.Flags & box.cc.enable_hook != 0);
    try t.expect(c.lpfnHook != null);
    const back = box.colorOf(0x302010);
    try t.expectEqual(@as(u8, 0x10), back.r);
    try t.expectEqual(@as(u8, 0x30), back.b);

    // yesnocancel with the default no: the second button, and modal to the
    // thread with no owner.
    const q: plat_.MessageBox = .{ .buttons = .yesnocancel, .icon = .question, .default = .no, .message = "Save?", .detail = "It changed." };
    try t.expectEqual(box.mb.yesnocancel | box.mb.icon_question | box.mb.default_button2 | box.mb.task_modal | box.mb.set_foreground, box.boxFlags(&q, false));
    // A default that is not a button of the type gives the first.
    const e: plat_.MessageBox = .{ .buttons = .retrycancel, .icon = .@"error", .default = .yes };
    try t.expectEqual(box.mb.retrycancel | box.mb.icon_error, box.boxFlags(&e, true));
    try t.expectEqual(plat_.MessageBox.Button.no, box.buttonOf(7).?);
    try t.expectEqual(plat_.MessageBox.Button.cancel, box.buttonOf(2).?);
    try t.expect(box.buttonOf(0) == null);
    const text = try box.boxText(t.allocator, &q);
    defer t.allocator.free(text);
    try t.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("Save?\n\nIt changed."), text);

    var events: std.ArrayListUnmanaged(Event) = .empty;
    defer events.deinit(t.allocator);
    const o = try openHidden(&events);
    defer o.b.deinit();
    try t.expect(o.b.platform().hasColorDialog() and o.b.platform().hasMessageBox());
}

test "windows: the file dialogs of Windows get their options" {
    if (!enabled()) return;
    const dlg = @import("../platform/windialog.zig");
    const plat_ = @import("../platform/platform.zig");
    const filters = [_]plat_.FileDialog.Filter{ .{ .name = "Text", .patterns = &.{"*.txt"} }, .{ .name = "All", .patterns = &.{"*"} } };
    var open = dlg.configure(t.allocator, &.{ .kind = .open, .title = "Pick", .initial_file = "notes.txt", .filters = &filters, .multiple = true }) catch |e| {
        std.debug.print("SKIP: no Common Item Dialog in this session ({s})\n", .{@errorName(e)});
        return;
    };
    defer open.deinit();
    const o = try dlg.readBack(&open, t.allocator);
    defer t.allocator.free(o.file_name);
    try t.expect(o.flags & dlg.flag.multiselect != 0);
    try t.expect(o.flags & dlg.flag.file_must_exist != 0);
    try t.expectEqualStrings("notes.txt", o.file_name);

    var save = try dlg.configure(t.allocator, &.{ .kind = .save, .default_ext = "csv", .confirm_overwrite = false });
    defer save.deinit();
    const s = try dlg.readBack(&save, t.allocator);
    defer t.allocator.free(s.file_name);
    try t.expect(s.flags & dlg.flag.overwrite_prompt == 0);

    var folder = try dlg.configure(t.allocator, &.{ .kind = .folder, .initial_dir = "C:/" });
    defer folder.deinit();
    const f = try dlg.readBack(&folder, t.allocator);
    defer t.allocator.free(f.file_name);
    try t.expect(f.flags & dlg.flag.pick_folders != 0);
}

test "windows: the taskbar state of a hidden window goes to ITaskbarList3" {
    if (!enabled()) return;
    var events: std.ArrayListUnmanaged(Event) = .empty;
    defer events.deinit(t.allocator);
    const o = try openHidden(&events);
    defer o.b.deinit();
    const p = o.b.platform();
    try t.expect(p.hasTaskbar());
    // A hidden window has no button, so the shell refuses the calls. The
    // state stays for the message of the button.
    p.taskbarSet(o.w, .{ .progress = .paused, .value = 0.5, .badge = 3 });
    try t.expect(o.b.taskbar.list != null);
    p.taskbarSet(o.w, .{});
    p.attention(o.w, false);
    p.attention(o.w, true);
}

const FakeData = extern struct {
    vtbl: *const [12]*const anyopaque,
};

extern "kernel32" fn GlobalAlloc(flags: u32, size: usize) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalLock(h: *anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalUnlock(h: *anyopaque) callconv(.winapi) i32;

fn fakeStub(_: *FakeData) callconv(.winapi) i32 {
    return @bitCast(@as(u32, 0x80004001)); // E_NOTIMPL
}
fn fakeRef(_: *FakeData) callconv(.winapi) u32 {
    return 1;
}
fn fakeQuery(_: *FakeData, f: *const @import("../platform/windrop.zig").FORMATETC) callconv(.winapi) i32 {
    return if (f.cfFormat == @import("../platform/windrop.zig").CF_HDROP) 0 else 1;
}
/// A DROPFILES of two wide paths, in a new HGLOBAL for each call.
fn fakeGet(_: *FakeData, f: *const @import("../platform/windrop.zig").FORMATETC, m: *@import("../platform/windrop.zig").STGMEDIUM) callconv(.winapi) i32 {
    if (f.cfFormat != @import("../platform/windrop.zig").CF_HDROP) return @bitCast(@as(u32, 0x80040064)); // DV_E_FORMATETC
    const names = std.unicode.utf8ToUtf16LeStringLiteral("C:\\a\\one.txt\x00C:\\two.png\x00\x00");
    const size = 20 + names.len * 2;
    const g = GlobalAlloc(0x2, size) orelse return -1;
    const p: [*]u8 = @ptrCast(GlobalLock(g).?);
    @memset(p[0..20], 0);
    std.mem.writeInt(u32, p[0..4], 20, .little);
    std.mem.writeInt(u32, p[16..20], 1, .little);
    @memcpy(p[20..size], std.mem.sliceAsBytes(names));
    _ = GlobalUnlock(g);
    m.* = .{ .tymed = 1, .data = g };
    return 0;
}

test "windows: a global shortcut registers and its WM_HOTKEY is a hotkey event" {
    if (!enabled()) return;
    var events: std.ArrayListUnmanaged(Event) = .empty;
    defer events.deinit(t.allocator);
    const o = try openHidden(&events);
    defer o.b.deinit();
    const p = o.b.platform();
    // Control-Alt-Shift-F24: a key that no keyboard of a person has.
    const id = p.hotkeyAdd(o.w, .{ .control = true, .mod1 = true, .shift = true }, 0xffd5);
    try t.expect(id != 0);
    // The same shortcut a second time fails.
    try t.expectEqual(@as(u32, 0), p.hotkeyAdd(o.w, .{ .control = true, .mod1 = true, .shift = true }, 0xffd5));
    _ = w32.SendMessageW(o.hwnd, @import("../platform/winhotkey.zig").WM_HOTKEY, id, 0);
    try pollAll(o.b, &events);
    const ev = has(events.items, .hotkey) orelse return error.NoHotkey;
    try t.expectEqual(id, ev.hotkey.id);
    p.hotkeyRemove(id);
    try t.expectEqual(@as(usize, 0), o.b.hotkeys.items.len);
}

test "windows: an OLE drop of files on a window is a drop event" {
    if (!enabled()) return;
    var events: std.ArrayListUnmanaged(Event) = .empty;
    defer events.deinit(t.allocator);
    const o = try openHidden(&events);
    defer o.b.deinit();
    const p = o.b.platform();
    p.dropTypes(o.w, .{ .files = true });
    const target = o.b.recOf(o.w).?.drop orelse return error.NoTarget;
    const stub: *const anyopaque = @ptrCast(&fakeStub);
    const table = [12]*const anyopaque{ stub, @ptrCast(&fakeRef), @ptrCast(&fakeRef), @ptrCast(&fakeGet), stub, @ptrCast(&fakeQuery), stub, stub, stub, stub, stub, stub };
    var data: FakeData = .{ .vtbl = &table };
    var effect: u32 = 7;
    _ = target.vtbl.DragEnter(target, &data, 0, .{ .x = 0, .y = 0 }, &effect);
    try t.expectEqual(@as(u32, 1), effect);
    effect = 7;
    _ = target.vtbl.Drop(target, &data, 0, .{ .x = 0, .y = 0 }, &effect);
    try pollAll(o.b, &events);
    var got: ?Event = null;
    for (events.items) |e| if (e == .drop and e.drop.phase == .drop) {
        got = e;
    };
    const d = (got orelse return error.NoDrop).drop;
    try t.expectEqualStrings("C:/a/one.txt\x00C:/two.png", d.files);
    // A window that accepts only text refuses the files.
    p.dropTypes(o.w, .{ .text = true });
    effect = 7;
    _ = target.vtbl.DragEnter(target, &data, 0, .{ .x = 0, .y = 0 }, &effect);
    try t.expectEqual(@as(u32, 0), effect);
    _ = target.vtbl.DragLeave(target);
    p.dropTypes(o.w, .{});
    try t.expect(o.b.recOf(o.w).?.drop == null);
}
