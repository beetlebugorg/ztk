//! The AppKit backend of macOS. Each ztk window is an `NSWindow` with a
//! content view of a class that the backend makes at run time. The view
//! hosts a `CAMetalLayer`, and the render thread of the window draws into
//! its drawables with a Metal renderer of its own. A window delegate, also
//! made at run time, turns the close button, a resize, a scale change, and
//! the key window into events. The frame clock is the display link of the
//! view (macOS 14 and later), or a timer at 60 Hz on an older system. The
//! link runs only between a `requestFrame` and the `frame` event that
//! answers it.
//!
//! AppKit runs on the main thread, so the UI thread of ztk is the main
//! thread. `wait` gets the next `NSEvent` with a time limit and sends it
//! to the application, so the window frame and the menus of AppKit work.
//! A callback that adds an event while `wait` blocks posts an empty
//! application event, which ends the wait. Keys, the pointer, and the
//! scroll wheel come in a later PR of docs/dev/macos.md.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const objc = @import("../sys/objc.zig");
const geom = @import("../geom.zig");
const event = @import("../event.zig");
const plat = @import("platform.zig");
const loop = @import("../loop.zig");
const metal = @import("../render/metal.zig");
const Event = event.Event;
const Window = plat.Window;
const Platform = plat.Platform;
const Frame = @import("../scene.zig").Frame;
const Target = @import("../render/thread.zig").Target;
const Atlas = @import("../text/atlas.zig").Atlas;
const Id = objc.Id;
const Sel = objc.Sel;
const Class = objc.Class;

const NSPoint = extern struct { x: f64, y: f64 };
const NSSize = extern struct { w: f64, h: f64 };
const NSRect = extern struct { origin: NSPoint, size: NSSize };

extern "c" fn pthread_main_np() c_int;
extern "Foundation" const NSDefaultRunLoopMode: Id;
extern "Foundation" const NSRunLoopCommonModes: Id;
extern "CoreGraphics" const kCGColorSpaceSRGB: *const anyopaque;
extern "CoreGraphics" fn CGColorSpaceCreateWithName(name: *const anyopaque) ?*anyopaque;
extern "CoreGraphics" fn CGColorSpaceRelease(space: *anyopaque) void;

// NSWindowStyleMask: titled, closable, miniaturizable, resizable.
const style_mask: usize = 1 | 2 | 4 | 8;
const backing_buffered: usize = 2;
const activation_regular: isize = 0;
const event_mask_any: u64 = std.math.maxInt(u64);
const event_application_defined: usize = 15;

/// The state of one window. `window` is the ztk window that the core sees,
/// and its `impl` points back here.
pub const Win = struct {
    owner: *AppKit,
    window: Window,
    ns_window: Id,
    view: Id,
    delegate: Id,
    layer: Id,
    /// The display link, or the timer of a system with no display link.
    link: ?Id = null,
    timer: ?Id = null,
    frame_wanted: bool = false,
    renderer: *metal.Metal,
    /// The atlas page that the draws read. The patches of each frame fill it.
    atlas: Atlas,
};

pub const AppKit = struct {
    gpa: std.mem.Allocator,
    app: Id,
    view_class: Class,
    delegate_class: Class,
    events: std.ArrayListUnmanaged(Event) = .empty,
    /// True while `wait` blocks in `nextEventMatchingMask`.
    waiting: bool = false,
    /// True when an empty event to end the wait is posted and not yet taken.
    woken: bool = false,
    windows: u32 = 0,

    pub fn init(gpa: std.mem.Allocator) !*AppKit {
        // AppKit makes windows only on the main thread.
        if (pthread_main_np() == 0) return error.NotMainThread;
        const pool = objc.Pool.push();
        defer pool.pop();
        const app = objc.call(fn (Class, Sel) callconv(.c) Id, objc.class("NSApplication") orelse return error.NoAppKit, "sharedApplication", .{});
        _ = objc.call(fn (Id, Sel, isize) callconv(.c) bool, app, "setActivationPolicy:", .{activation_regular});
        objc.call(fn (Id, Sel) callconv(.c) void, app, "finishLaunching", .{});
        const a = try gpa.create(AppKit);
        a.* = .{ .gpa = gpa, .app = app, .view_class = viewClass(), .delegate_class = delegateClass() };
        return a;
    }

    pub fn deinit(a: *AppKit) void {
        a.events.deinit(a.gpa);
        a.gpa.destroy(a);
    }

    pub fn platform(a: *AppKit) Platform {
        return .{ .ptr = a, .vtable = &vtable, .live = true, .thread_safe_draw = true };
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

    fn self(ptr: *anyopaque) *AppKit {
        return @ptrCast(@alignCast(ptr));
    }

    /// Adds an event. During a wait, an empty application event ends it.
    fn push(a: *AppKit, e: Event) void {
        a.events.append(a.gpa, e) catch return;
        if (a.waiting and !a.woken) {
            a.woken = true;
            postWake(a.app);
        }
    }

    // ---- Windows ----

    fn vCreateWindow(ptr: *anyopaque, opts: plat.WindowOptions) anyerror!*Window {
        const a = self(ptr);
        const pool = objc.Pool.push();
        defer pool.pop();
        const renderer = try metal.Metal.init(a.gpa, .{});
        errdefer renderer.deinit();
        const w = try a.gpa.create(Win);
        errdefer a.gpa.destroy(w);

        const rect = NSRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .w = @floatFromInt(opts.size.w), .h = @floatFromInt(opts.size.h) } };
        const alloc = objc.call(fn (Class, Sel) callconv(.c) Id, objc.class("NSWindow").?, "alloc", .{});
        const ns_window = objc.call(fn (Id, Sel, NSRect, usize, usize, bool) callconv(.c) Id, alloc, "initWithContentRect:styleMask:backing:defer:", .{ rect, style_mask, backing_buffered, false });
        // The backend releases the window itself, in destroyWindow.
        send(ns_window, "setReleasedWhenClosed:", .{false});

        const view_alloc = objc.call(fn (Class, Sel) callconv(.c) Id, a.view_class, "alloc", .{});
        const view = objc.call(fn (Id, Sel, NSRect) callconv(.c) Id, view_alloc, "initWithFrame:", .{rect});
        const layer = objc.new(objc.class("CAMetalLayer").?);
        send(layer, "setDevice:", .{renderer.device});
        send(layer, "setPixelFormat:", .{@as(usize, metal.pixel_bgra8)});
        send(layer, "setFramebufferOnly:", .{true});
        send(layer, "setOpaque:", .{true});
        if (CGColorSpaceCreateWithName(kCGColorSpaceSRGB)) |space| {
            send(layer, "setColorspace:", .{space});
            CGColorSpaceRelease(space);
        }
        // During a live resize the old image stays at the top left until a
        // new frame arrives, and is not stretched.
        const gravity = objc.nsString("topLeft");
        defer objc.release(gravity);
        send(layer, "setContentsGravity:", .{gravity});
        // A layer-hosting view: the layer first, then wantsLayer.
        send(view, "setLayer:", .{layer});
        send(view, "setWantsLayer:", .{true});
        send(ns_window, "setContentView:", .{view});

        const delegate = objc.new(a.delegate_class);
        send(ns_window, "setDelegate:", .{delegate});

        w.* = .{
            .owner = a,
            .window = .{ .size = opts.size },
            .ns_window = ns_window,
            .view = view,
            .delegate = delegate,
            .layer = layer,
            .renderer = renderer,
            .atlas = Atlas.init(a.gpa),
        };
        w.window.impl = w;
        objc.setData(view, w);
        objc.setData(delegate, w);
        w.window.scale = @floatCast(objc.call(fn (Id, Sel) callconv(.c) f64, ns_window, "backingScaleFactor", .{}));
        send(layer, "setContentsScale:", .{@as(f64, w.window.scale)});
        startClock(w);

        vSetTitle(ptr, &w.window, if (opts.title.len > 0) opts.title else "ztk");
        send(ns_window, "center", .{});
        send(ns_window, "makeKeyAndOrderFront:", .{@as(?Id, null)});
        send(a.app, "activateIgnoringOtherApps:", .{true});
        a.windows += 1;
        // The first frame needs no clock tick.
        a.push(.{ .frame = .{ .window = &w.window, .time_us = nowUs() } });
        return &w.window;
    }

    fn vDestroyWindow(ptr: *anyopaque, win: *Window) void {
        const a = self(ptr);
        const w = winOf(win);
        const pool = objc.Pool.push();
        defer pool.pop();
        // No event of the window stays in the queue.
        var i: usize = 0;
        while (i < a.events.items.len) {
            if (a.events.items[i].window() == win) _ = a.events.orderedRemove(i) else i += 1;
        }
        if (w.link) |l| {
            send(l, "invalidate", .{});
            objc.release(l);
        }
        if (w.timer) |t| {
            send(t, "invalidate", .{});
            objc.release(t);
        }
        objc.setData(w.view, null);
        objc.setData(w.delegate, null);
        send(w.ns_window, "setDelegate:", .{@as(?Id, null)});
        send(w.ns_window, "close", .{});
        objc.release(w.ns_window);
        objc.release(w.delegate);
        objc.release(w.view);
        objc.release(w.layer);
        w.renderer.deinit();
        w.atlas.deinit();
        a.gpa.destroy(w);
        a.windows -|= 1;
    }

    fn vDeinit(ptr: *anyopaque) void {
        self(ptr).deinit();
    }

    fn vSetTitle(_: *anyopaque, win: *Window, title: []const u8) void {
        const w = winOf(win);
        const s = objc.nsString(title);
        defer objc.release(s);
        send(w.ns_window, "setTitle:", .{s});
    }

    fn vRequestSize(_: *anyopaque, win: *Window, size: geom.Size) void {
        const w = winOf(win);
        // The window delegate answers with windowDidResize: and a resize event.
        send(w.ns_window, "setContentSize:", .{NSSize{ .w = @floatFromInt(size.w), .h = @floatFromInt(size.h) }});
    }

    fn vSetMinSize(_: *anyopaque, win: *Window, size: geom.Size) void {
        const w = winOf(win);
        send(w.ns_window, "setContentMinSize:", .{NSSize{ .w = @floatFromInt(size.w), .h = @floatFromInt(size.h) }});
    }

    fn vNowUs(_: *anyopaque) i64 {
        return nowUs();
    }

    fn nowUs() i64 {
        return loop.system_clock.now(null);
    }

    // ---- The frame clock ----

    fn startClock(w: *Win) void {
        if (objc.call(fn (Id, Sel, Sel) callconv(.c) bool, w.view, "respondsToSelector:", .{objc.sel("displayLinkWithTarget:selector:")})) {
            const link = objc.call(fn (Id, Sel, Id, Sel) callconv(.c) Id, w.view, "displayLinkWithTarget:selector:", .{ w.view, objc.sel("ztkTick:") });
            _ = objc.call(fn (Id, Sel) callconv(.c) Id, link, "retain", .{});
            send(link, "setPaused:", .{true});
            const run_loop = objc.call(fn (Class, Sel) callconv(.c) Id, objc.class("NSRunLoop").?, "mainRunLoop", .{});
            objc.call(fn (Id, Sel, Id, Id) callconv(.c) void, link, "addToRunLoop:forMode:", .{ run_loop, NSRunLoopCommonModes });
            w.link = link;
        }
    }

    fn vRequestFrame(_: *anyopaque, win: *Window) void {
        const w = winOf(win);
        if (w.frame_wanted) return;
        w.frame_wanted = true;
        if (w.link) |l| {
            send(l, "setPaused:", .{false});
        } else if (w.timer == null) {
            const t = objc.call(fn (Class, Sel, f64, Id, Sel, ?Id, bool) callconv(.c) Id, objc.class("NSTimer").?, "scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:", .{ 1.0 / 60.0, w.view, objc.sel("ztkTick:"), null, false });
            w.timer = objc.call(fn (Id, Sel) callconv(.c) Id, t, "retain", .{});
        }
    }

    fn tick(w: *Win) void {
        if (w.timer) |t| {
            objc.release(t);
            w.timer = null;
        }
        if (!w.frame_wanted) return;
        w.frame_wanted = false;
        if (w.link) |l| send(l, "setPaused:", .{true});
        w.owner.push(.{ .frame = .{ .window = &w.window, .time_us = nowUs() } });
    }

    // ---- The wait and the poll ----

    fn vWait(ptr: *anyopaque, timeout_us: ?i64) void {
        const a = self(ptr);
        if (a.events.items.len > 0) return;
        const pool = objc.Pool.push();
        defer pool.pop();
        const date_class = objc.class("NSDate").?;
        const until = if (timeout_us) |us|
            objc.call(fn (Class, Sel, f64) callconv(.c) Id, date_class, "dateWithTimeIntervalSinceNow:", .{@as(f64, @floatFromInt(@max(us, 0))) / 1e6})
        else
            objc.call(fn (Class, Sel) callconv(.c) Id, date_class, "distantFuture", .{});
        a.waiting = true;
        const ev = nextEvent(a.app, until);
        a.waiting = false;
        if (ev) |e| a.dispatch(e);
    }

    fn vPoll(ptr: *anyopaque, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(Event)) anyerror!void {
        const a = self(ptr);
        const pool = objc.Pool.push();
        defer pool.pop();
        const past = objc.call(fn (Class, Sel) callconv(.c) Id, objc.class("NSDate").?, "distantPast", .{});
        // The events that wait now, and no more, so a busy stream of events
        // cannot keep the UI thread here.
        var n: u32 = 0;
        while (n < 256) : (n += 1) {
            const ev = nextEvent(a.app, past) orelse break;
            a.dispatch(ev);
        }
        try out.appendSlice(gpa, a.events.items);
        a.events.clearRetainingCapacity();
    }

    fn nextEvent(app: Id, until: Id) ?Id {
        return objc.call(fn (Id, Sel, u64, Id, Id, bool) callconv(.c) ?Id, app, "nextEventMatchingMask:untilDate:inMode:dequeue:", .{ event_mask_any, until, NSDefaultRunLoopMode, true });
    }

    fn dispatch(a: *AppKit, ev: Id) void {
        const kind = objc.call(fn (Id, Sel) callconv(.c) usize, ev, "type", .{});
        if (kind == event_application_defined) {
            // The empty event of `push`.
            a.woken = false;
            return;
        }
        send(a.app, "sendEvent:", .{ev});
    }

    fn postWake(app: Id) void {
        const ev = objc.call(fn (Class, Sel, usize, NSPoint, usize, f64, isize, ?Id, i16, isize, isize) callconv(.c) ?Id, objc.class("NSEvent").?, "otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:", .{ event_application_defined, NSPoint{ .x = 0, .y = 0 }, 0, 0, 0, null, 0, 0, 0 }) orelse return;
        objc.call(fn (Id, Sel, Id, bool) callconv(.c) void, app, "postEvent:atStart:", .{ ev, false });
    }

    // ---- Drawing ----

    fn vTarget(_: *anyopaque, win: *Window) Target {
        return .{ .ctx = winOf(win), .draw = drawFrame };
    }

    /// Draws one frame on the render thread of the window. Metal and the
    /// drawables of a `CAMetalLayer` work from any thread.
    fn drawFrame(ctx: *anyopaque, frame: *const Frame) anyerror!void {
        const w: *Win = @ptrCast(@alignCast(ctx));
        for (frame.patches.items) |p| try w.atlas.applyPatch(p);
        try w.renderer.drawLayer(w.layer, &frame.scene, &w.atlas);
    }

    // ---- The classes made at run time ----

    fn winOf(win: *Window) *Win {
        return @ptrCast(@alignCast(win.impl.?));
    }

    fn dataOf(obj: Id) ?*Win {
        return @ptrCast(@alignCast(objc.getData(obj) orelse return null));
    }

    fn viewClass() Class {
        if (objc.class("ZtkView")) |c| return c;
        const b = objc.ClassBuilder.begin("NSView", "ZtkView").?;
        // "c@:": a BOOL result and no argument.
        b.method("isFlipped", @ptrCast(&yes), "c@:");
        b.method("acceptsFirstResponder", @ptrCast(&yes), "c@:");
        b.method("ztkTick:", @ptrCast(&onTick), "v@:@");
        return b.finish();
    }

    fn delegateClass() Class {
        if (objc.class("ZtkWindowDelegate")) |c| return c;
        const b = objc.ClassBuilder.begin("NSObject", "ZtkWindowDelegate").?;
        b.method("windowShouldClose:", @ptrCast(&onShouldClose), "c@:@");
        b.method("windowDidResize:", @ptrCast(&onResize), "v@:@");
        b.method("windowDidBecomeKey:", @ptrCast(&onBecomeKey), "v@:@");
        b.method("windowDidResignKey:", @ptrCast(&onResignKey), "v@:@");
        b.method("windowDidChangeBackingProperties:", @ptrCast(&onBacking), "v@:@");
        return b.finish();
    }

    fn yes(_: Id, _: Sel) callconv(.c) bool {
        return true;
    }

    fn onTick(view: Id, _: Sel, _: Id) callconv(.c) void {
        if (dataOf(view)) |w| tick(w);
    }

    fn onShouldClose(delegate: Id, _: Sel, _: Id) callconv(.c) bool {
        // The core decides: WM_DELETE_WINDOW, or destroyWindow.
        if (dataOf(delegate)) |w| w.owner.push(.{ .close = .{ .window = &w.window } });
        return false;
    }

    fn onResize(delegate: Id, _: Sel, _: Id) callconv(.c) void {
        const w = dataOf(delegate) orelse return;
        const bounds = objc.callStruct(NSRect, w.view, "bounds");
        const size = geom.Size{ .w = @intFromFloat(@round(bounds.size.w)), .h = @intFromFloat(@round(bounds.size.h)) };
        if (size.w == w.window.size.w and size.h == w.window.size.h) return;
        w.window.size = size;
        w.owner.push(.{ .resize = .{ .window = &w.window, .size = size } });
    }

    fn onBecomeKey(delegate: Id, _: Sel, _: Id) callconv(.c) void {
        if (dataOf(delegate)) |w| w.owner.push(.{ .focus = .{ .window = &w.window, .focused = true } });
    }

    fn onResignKey(delegate: Id, _: Sel, _: Id) callconv(.c) void {
        if (dataOf(delegate)) |w| w.owner.push(.{ .focus = .{ .window = &w.window, .focused = false } });
    }

    fn onBacking(delegate: Id, _: Sel, _: Id) callconv(.c) void {
        const w = dataOf(delegate) orelse return;
        const scale: f32 = @floatCast(objc.call(fn (Id, Sel) callconv(.c) f64, w.ns_window, "backingScaleFactor", .{}));
        if (scale == w.window.scale) return;
        w.window.scale = scale;
        send(w.layer, "setContentsScale:", .{@as(f64, scale)});
        w.owner.push(.{ .scale = .{ .window = &w.window, .scale = scale } });
    }
};

/// Sends a message with no result and at most one argument.
fn send(target: Id, selector: [*:0]const u8, args: anytype) void {
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
    switch (fields.len) {
        0 => objc.call(fn (Id, Sel) callconv(.c) void, target, selector, args),
        1 => objc.call(fn (Id, Sel, fields[0].type) callconv(.c) void, target, selector, args),
        else => @compileError("send has at most one argument; use objc.call for more"),
    }
}
