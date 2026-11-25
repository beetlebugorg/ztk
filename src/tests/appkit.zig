//! Tests of the AppKit backend. A test that opens a window runs only with
//! ZTK_TEST_WINDOWS=1, which CI sets, because rule 12 of AGENTS.md keeps
//! windows off the live desktop session of a development machine. Without
//! it, or off the main thread, the test prints a `SKIP:` line and returns.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const appkit = @import("../platform/appkit.zig");
const objc = @import("../sys/objc.zig");
const event = @import("../event.zig");
const plat = @import("../platform/platform.zig");
const scene_tests = @import("scene.zig");
const Frame = @import("../scene.zig").Frame;
const t = std.testing;

extern "c" fn pthread_main_np() c_int;

fn windowsAllowed() bool {
    const v = std.c.getenv("ZTK_TEST_WINDOWS") orelse {
        std.debug.print("SKIP: appkit windows need ZTK_TEST_WINDOWS=1\n", .{});
        return false;
    };
    if (v[0] != '1') return false;
    if (pthread_main_np() == 0) {
        std.debug.print("SKIP: appkit windows need the main thread\n", .{});
        return false;
    }
    return true;
}

const NSPoint = extern struct { x: f64, y: f64 };

fn windowNumber(ns_window: objc.Id) isize {
    return objc.call(fn (objc.Id, objc.Sel) callconv(.c) isize, ns_window, "windowNumber", .{});
}

/// Sends an `NSEvent` key of `kind` (10 keyDown, 11 keyUp) to the window.
fn sendKey(ns_window: objc.Id, kind: usize, chars: []const u8, plain: []const u8, code: u16, flags: u64) void {
    const c = objc.nsString(chars);
    defer objc.release(c);
    const pl = objc.nsString(plain);
    defer objc.release(pl);
    const ev = objc.call(fn (objc.Class, objc.Sel, usize, NSPoint, u64, f64, isize, ?objc.Id, objc.Id, objc.Id, bool, u16) callconv(.c) objc.Id, objc.class("NSEvent").?, "keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:", .{ kind, NSPoint{ .x = 0, .y = 0 }, flags, 0, windowNumber(ns_window), null, c, pl, false, code });
    objc.call(fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void, ns_window, "sendEvent:", .{ev});
}

/// Sends a mouse `NSEvent` of `kind` (1 left down, 2 left up) at a point
/// of the window, from the bottom left.
fn sendMouse(ns_window: objc.Id, kind: usize, x: f64, y: f64) void {
    const ev = objc.call(fn (objc.Class, objc.Sel, usize, NSPoint, u64, f64, isize, ?objc.Id, isize, isize, f32) callconv(.c) objc.Id, objc.class("NSEvent").?, "mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:", .{ kind, NSPoint{ .x = x, .y = y }, 0, 0, windowNumber(ns_window), null, 0, 1, 1 });
    objc.call(fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void, ns_window, "sendEvent:", .{ev});
}

/// Polls until an event of kind `tag` comes, for at most two seconds.
fn waitFor(p: plat.Platform, tag: std.meta.Tag(event.Event)) !event.Event {
    var list: std.ArrayListUnmanaged(event.Event) = .empty;
    defer list.deinit(t.allocator);
    const end = p.nowUs() + 2_000_000;
    while (p.nowUs() < end) {
        p.wait(50_000);
        list.clearRetainingCapacity();
        try p.poll(t.allocator, &list);
        for (list.items) |e| if (e == tag) return e;
    }
    std.debug.print("appkit: no {s} event in two seconds\n", .{@tagName(tag)});
    return error.NoEvent;
}

test "appkit: a window draws with Metal and gives frame, resize, and close events" {
    if (!windowsAllowed()) return;
    const a = try appkit.AppKit.init(t.allocator);
    const p = a.platform();
    defer p.vtable.deinit(p.ptr);
    const win = try p.createWindow(.{ .title = "ztk test", .size = .{ .w = 320, .h = 200 } });
    var destroyed = false;
    defer if (!destroyed) p.destroyWindow(win);
    try t.expect(win.scale >= 1);

    // The first frame comes with no request.
    _ = try waitFor(p, .frame);

    // One draw of a scene of the size of the window in device pixels.
    var f: Frame = .{};
    defer f.scene.deinit(t.allocator);
    try scene_tests.build(t.allocator, &f.scene, 0, win.scale);
    f.scene.width = @intFromFloat(@round(@as(f32, @floatFromInt(win.size.w)) * win.scale));
    f.scene.height = @intFromFloat(@round(@as(f32, @floatFromInt(win.size.h)) * win.scale));
    const target = p.target(win);
    try target.draw(target.ctx, &f);

    // The display link answers a request with one frame event.
    p.requestFrame(win);
    _ = try waitFor(p, .frame);

    p.vtable.requestSize(p.ptr, win, .{ .w = 400, .h = 300 });
    const r = try waitFor(p, .resize);
    try t.expectEqual(@as(i32, 400), r.resize.size.w);
    try t.expectEqual(@as(i32, 300), r.resize.size.h);
    try target.draw(target.ctx, &f);

    const w: *appkit.Win = @ptrCast(@alignCast(win.impl.?));

    // A key that the window gets goes through the view and the key map:
    // the key code of A, with Shift, gives the keysym and the text "A".
    sendKey(w.ns_window, 10, "A", "A", 0x00, 1 << 17);
    const k = try waitFor(p, .key);
    try t.expectEqual(@as(u32, 'A'), k.key.keysym);
    try t.expect(k.key.pressed and k.key.mods.shift);
    try t.expectEqualStrings("A", k.key.text[0..k.key.text_len]);
    // Command-c gives the keysym c, Mod1, and no text.
    sendKey(w.ns_window, 10, "c", "c", 0x08, 1 << 20);
    const cmd = try waitFor(p, .key);
    try t.expectEqual(@as(u32, 'c'), cmd.key.keysym);
    try t.expect(cmd.key.mods.mod1);
    try t.expectEqual(@as(u8, 0), cmd.key.text_len);

    // A click 20 points from the left and 30 from the top of the content.
    sendMouse(w.ns_window, 1, 20, 300 - 30);
    const b = try waitFor(p, .button);
    try t.expectEqual(@as(u8, 1), b.button.button);
    try t.expect(b.button.pressed);
    try t.expectApproxEqAbs(@as(f32, 20), b.button.x, 0.5);
    try t.expectApproxEqAbs(@as(f32, 30), b.button.y, 0.5);
    sendMouse(w.ns_window, 2, 20, 300 - 30);
    _ = try waitFor(p, .button);

    // The close button asks the core, and the window stays.
    objc.call(fn (objc.Id, objc.Sel, ?objc.Id) callconv(.c) void, w.ns_window, "performClose:", .{null});
    _ = try waitFor(p, .close);

    p.destroyWindow(win);
    destroyed = true;
}
