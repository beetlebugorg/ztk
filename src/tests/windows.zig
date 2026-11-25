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
    _ = ClientToScreen(o.hwnd, &pt);
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

extern "user32" fn ClientToScreen(hwnd: w32.HWND, p: *w32.POINT) callconv(.winapi) w32.BOOL;

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
