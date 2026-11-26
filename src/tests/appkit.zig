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

    // With the input method on, a plain key still comes as a key with its text.
    p.textInput(win, true, .{ .x = 10, .y = 10, .w = 200, .h = 24 });
    sendKey(w.ns_window, 10, "a", "a", 0x00, 0);
    const typed = try waitFor(p, .key);
    try t.expectEqual(@as(u32, 'a'), typed.key.keysym);
    try t.expectEqualStrings("a", typed.key.text[0..typed.key.text_len]);
    // The answers of an input method: marked text, then the final text.
    const Range = extern struct { location: usize, length: usize };
    const marked = objc.nsString("ni");
    defer objc.release(marked);
    objc.call(fn (objc.Id, objc.Sel, objc.Id, Range, Range) callconv(.c) void, w.view, "setMarkedText:selectedRange:replacementRange:", .{ marked, Range{ .location = 2, .length = 0 }, Range{ .location = std.math.maxInt(isize), .length = 0 } });
    const pre = try waitFor(p, .preedit);
    try t.expectEqualStrings("ni", pre.preedit.text);
    try t.expectEqual(@as(u32, 2), pre.preedit.caret);
    const final = objc.nsString("你");
    defer objc.release(final);
    objc.call(fn (objc.Id, objc.Sel, objc.Id, Range) callconv(.c) void, w.view, "insertText:replacementRange:", .{ final, Range{ .location = std.math.maxInt(isize), .length = 0 } });
    const done = try waitFor(p, .commit);
    try t.expectEqualStrings("你", done.commit.text);
    p.textInput(win, false, .{});

    // The appearance: the program goes dark, the observer gives an
    // appearance event, and the dark mode reads true. Only this program
    // changes, so the test leaves the system setting alone.
    const get = p.vtable.appearance.?;
    try t.expect(get(p.ptr).accent != null);
    const look = struct {
        fn named(name: []const u8) !objc.Id {
            const n = objc.nsString(name);
            defer objc.release(n);
            return objc.call(fn (objc.Class, objc.Sel, objc.Id) callconv(.c) ?objc.Id, objc.class("NSAppearance").?, "appearanceNamed:", .{n}) orelse error.NoAppearance;
        }
    };
    const setLook = struct {
        fn set(app: objc.Id, ap: ?objc.Id) void {
            objc.call(fn (objc.Id, objc.Sel, ?objc.Id) callconv(.c) void, app, "setAppearance:", .{ap});
        }
    }.set;
    // Light first: the runner can be dark already, and a change is what
    // gives the event.
    setLook(a.app, try look.named("NSAppearanceNameAqua"));
    _ = waitFor(p, .appearance) catch {};
    try t.expect(!get(p.ptr).dark);
    setLook(a.app, try look.named("NSAppearanceNameDarkAqua"));
    _ = try waitFor(p, .appearance);
    try t.expect(get(p.ptr).dark);
    setLook(a.app, null);

    // The close button asks the core, and the window stays.
    objc.call(fn (objc.Id, objc.Sel, ?objc.Id) callconv(.c) void, w.ns_window, "performClose:", .{null});
    _ = try waitFor(p, .close);

    p.destroyWindow(win);
    destroyed = true;
}

extern "Foundation" const NSDefaultRunLoopMode: objc.Id;
extern "Foundation" const NSRunLoopCommonModes: objc.Id;

/// Posts `ev` and removes it from the queue, so it is the current event of
/// `NSApp`, as for an event that the run loop gives.
fn makeCurrent(app: objc.Id, ev: objc.Id) void {
    objc.call(fn (objc.Id, objc.Sel, objc.Id, bool) callconv(.c) void, app, "postEvent:atStart:", .{ ev, true });
    const past = objc.call(fn (objc.Class, objc.Sel) callconv(.c) objc.Id, objc.class("NSDate").?, "distantPast", .{});
    _ = objc.call(fn (objc.Id, objc.Sel, u64, objc.Id, objc.Id, bool) callconv(.c) ?objc.Id, app, "nextEventMatchingMask:untilDate:inMode:dequeue:", .{ std.math.maxInt(u64), past, NSDefaultRunLoopMode, true });
}

/// An application-defined event, the current event of a click on an item.
fn otherEvent() objc.Id {
    return objc.call(fn (objc.Class, objc.Sel, usize, NSPoint, usize, f64, isize, ?objc.Id, i16, isize, isize) callconv(.c) objc.Id, objc.class("NSEvent").?, "otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:", .{ 15, NSPoint{ .x = 0, .y = 0 }, 0, 0, 0, null, 0, 0, 0 });
}

/// The events of one poll after a short wait.
fn pollAll(p: plat.Platform, list: *std.ArrayListUnmanaged(event.Event)) !void {
    list.clearRetainingCapacity();
    p.wait(50_000);
    try p.poll(t.allocator, list);
}

/// Polls until a `menu` event with `action` comes, for at most two
/// seconds. A menu also gives `opening` and `select` events.
fn waitMenu(p: plat.Platform, action: event.MenuAction) !event.Event {
    const end = p.nowUs() + 2_000_000;
    while (p.nowUs() < end) {
        const e = try waitFor(p, .menu);
        if (e.menu.action == action) return e;
    }
    return error.NoEvent;
}

/// Sends the action of an item to its target, as AppKit does at the end
/// of a click. On the CI runner, where the app is not active, an item of
/// the menu bar gave no invoke through `performActionForItemAtIndex:`.
fn choose(app: objc.Id, menu: objc.Id, index: isize) bool {
    const item = objc.call(fn (objc.Id, objc.Sel, isize) callconv(.c) objc.Id, menu, "itemAtIndex:", .{index});
    const action = objc.call(fn (objc.Id, objc.Sel) callconv(.c) ?objc.Sel, item, "action", .{});
    const target = objc.call(fn (objc.Id, objc.Sel) callconv(.c) ?objc.Id, item, "target", .{});
    return objc.call(fn (objc.Id, objc.Sel, ?objc.Sel, ?objc.Id, objc.Id) callconv(.c) bool, app, "sendAction:to:from:", .{ action, target, item });
}

const HandlerLog = struct {
    calls: u32 = 0,
    last: event.MenuAction = .closed,
    fn call(ctx: ?*anyopaque, _: plat.MenuId, _: i32, action: event.MenuAction) void {
        const l: *HandlerLog = @ptrCast(@alignCast(ctx.?));
        l.calls += 1;
        l.last = action;
    }
};

test "appkit: native menus in the menu bar and as a popup" {
    if (!windowsAllowed()) return;
    const a = try appkit.AppKit.init(t.allocator);
    const p = a.platform();
    defer p.vtable.deinit(p.ptr);
    try t.expect(p.hasNativeMenus());
    const win = try p.createWindow(.{ .title = "ztk menus", .size = .{ .w = 320, .h = 200 } });
    defer p.destroyWindow(win);
    _ = try waitFor(p, .frame);
    const w: *appkit.Win = @ptrCast(@alignCast(win.impl.?));
    const app = a.app;
    const mainMenu = struct {
        fn get(ns_app: objc.Id) objc.Id {
            return objc.call(fn (objc.Id, objc.Sel) callconv(.c) objc.Id, ns_app, "mainMenu", .{});
        }
    }.get;
    // The window becomes key, as after a click on it.
    objc.call(fn (objc.Id, objc.Sel, ?objc.Id) callconv(.c) void, w.delegate, "windowDidBecomeKey:", .{null});
    _ = try waitFor(p, .focus);

    // A File menu in the bar of the window.
    p.menuSet(&.{ .id = 2, .entries = &.{
        .{ .label = "Open…", .accelerator = "Command-O" },
        .{ .label = "Wrap", .kind = .checkbutton },
    } });
    p.menuSet(&.{ .id = 1, .entries = &.{.{ .label = "File", .kind = .cascade, .submenu = 2 }} });
    p.setMenuBar(win, 1);
    const bar = a.menus.menus.get(1).?.ns;
    const file = a.menus.menus.get(2).?.ns;
    try t.expect(mainMenu(app) == bar);
    try t.expectEqual(@as(isize, 2), objc.call(fn (objc.Id, objc.Sel) callconv(.c) isize, bar, "numberOfItems", .{}));

    var list: std.ArrayListUnmanaged(event.Event) = .empty;
    defer list.deinit(t.allocator);

    // A click on an item gives an `invoke` of the window.
    makeCurrent(app, otherEvent());
    try t.expect(choose(app, file, 1));
    const inv = try waitMenu(p, .invoke);
    try t.expect(inv.menu.window == win);
    try t.expectEqual(@as(u32, 2), inv.menu.menu);
    try t.expectEqual(@as(i32, 1), inv.menu.entry);
    try t.expectEqual(event.MenuAction.invoke, inv.menu.action);

    // Command-O matches the key equivalent of Open, and the core gets the
    // key in place of an `invoke`, as a binding of Tk asks.
    const c = objc.nsString("o");
    defer objc.release(c);
    const cmd: u64 = 1 << 20;
    const key = objc.call(fn (objc.Class, objc.Sel, usize, NSPoint, u64, f64, isize, ?objc.Id, objc.Id, objc.Id, bool, u16) callconv(.c) objc.Id, objc.class("NSEvent").?, "keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:", .{ 10, NSPoint{ .x = 0, .y = 0 }, cmd, 0, windowNumber(w.ns_window), null, c, c, false, 31 });
    makeCurrent(app, key);
    try t.expect(objc.call(fn (objc.Id, objc.Sel, objc.Id) callconv(.c) bool, bar, "performKeyEquivalent:", .{key}));
    try pollAll(p, &list);
    var got_key = false;
    for (list.items) |e| switch (e) {
        .key => |k| if (k.pressed and k.keysym == 'o') {
            got_key = true;
        },
        .menu => |m| if (m.action == .invoke) return error.MenuFromKey,
        else => {},
    };
    try t.expect(got_key);

    // A menu that opens calls the handler of the core at once.
    var log: HandlerLog = .{};
    p.setMenuHandler(.{ .ctx = &log, .call = HandlerLog.call });
    makeCurrent(app, otherEvent());
    objc.call(fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void, a.menus.target, "menuNeedsUpdate:", .{file});
    try t.expectEqual(@as(u32, 1), log.calls);
    try t.expectEqual(event.MenuAction.opening, log.last);

    // A popup runs until it closes: here a timer cancels it.
    const modes = objc.call(fn (objc.Class, objc.Sel, objc.Id) callconv(.c) objc.Id, objc.class("NSArray").?, "arrayWithObject:", .{NSRunLoopCommonModes});
    objc.call(fn (objc.Id, objc.Sel, objc.Sel, ?objc.Id, f64, objc.Id) callconv(.c) void, file, "performSelector:withObject:afterDelay:inModes:", .{ objc.sel("cancelTracking"), null, 0.3, modes });
    p.postMenu(win, 2, .{ .x = 20, .y = 20 }, 0);
    const closed = try waitMenu(p, .closed);
    try t.expect(closed.menu.window == win);
    try t.expectEqual(event.MenuAction.closed, closed.menu.action);

    // Quit of the application menu is an application command.
    const app_menu = a.menus.app_menu;
    const n = objc.call(fn (objc.Id, objc.Sel) callconv(.c) isize, app_menu, "numberOfItems", .{});
    makeCurrent(app, otherEvent());
    try t.expect(choose(app, app_menu, n - 1));
    const quit = try waitFor(p, .app_command);
    try t.expectEqual(event.AppCommand.quit, quit.app_command.command);

    // With no bar, the default bar shows.
    p.setMenuBar(win, 0);
    try t.expect(mainMenu(app) != bar);
    p.menuDrop(1);
    p.menuDrop(2);
}
