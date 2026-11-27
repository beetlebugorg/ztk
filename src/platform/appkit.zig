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
//! application event, which ends the wait.
//!
//! The view gives the keys, the pointer, and the scroll wheel.
//! `mackeys.zig` maps the key codes and the modifier flags. A tracking
//! area of the view gives the motion with no button down, the leave, and
//! the cursor updates. Each pointer position also goes to the render
//! thread with `Window.feedPointer`.
//!
//! While the core has text input on, a key goes through
//! `interpretKeyEvents:`, and the view adopts `NSTextInputClient`.
//! `macime.zig` decides whether an answer of the input method is a
//! `preedit`, a `commit`, or the key event as before. A text of an event
//! lives until the `poll` after the one that gives the event.
//!
//! `appearance` gives the dark mode of `NSApp.effectiveAppearance` and
//! `NSColor.controlAccentColor` in sRGB. An observer of the key path
//! `effectiveAppearance` and of `NSSystemColorsDidChangeNotification`
//! gives an `appearance` event when either changes. The scale of a window
//! comes from `windowDidChangeBackingProperties:`.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const objc = @import("../sys/objc.zig");
const coretext = @import("coretext.zig");
const geom = @import("../base/geom.zig");
const event = @import("../base/event.zig");
const plat = @import("platform.zig");
const loop = @import("../loop.zig");
const metal = @import("../render/metal.zig");
const Event = event.Event;
const Window = plat.Window;
const Platform = plat.Platform;
const Frame = @import("../scene.zig").Frame;
const Target = @import("../render/thread.zig").Target;
const Atlas = @import("../text/atlas.zig").Atlas;
const mackeys = @import("mackeys.zig");
const Pasteboard = @import("pasteboard.zig").Pasteboard;
const Ime = @import("macime.zig").Ime;
const nsmenu = @import("nsmenu.zig");
const macdock = @import("macdock.zig");
const mactray = @import("mactray.zig");
const macdialog = @import("macdialog.zig");
const macdrag = @import("macdrag.zig");
const Id = objc.Id;
const Sel = objc.Sel;
const Class = objc.Class;

const NSPoint = extern struct { x: f64, y: f64 };
const NSSize = extern struct { w: f64, h: f64 };
const NSRect = extern struct { origin: NSPoint, size: NSSize };
const NSRange = extern struct { location: usize, length: usize };
const not_found: usize = std.math.maxInt(isize);

extern "c" fn pthread_main_np() c_int;
extern "Foundation" const NSDefaultRunLoopMode: Id;
extern "Foundation" const NSRunLoopCommonModes: Id;
extern "AppKit" const NSAppearanceNameAqua: Id;
extern "AppKit" const NSAppearanceNameDarkAqua: Id;
extern "AppKit" const NSSystemColorsDidChangeNotification: Id;
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
    /// The shape of the pointer over the view, an `NSCursor`.
    cursor: plat.Cursor = .default,
    /// The keysym of each key code that is down, so a release has the
    /// keysym of its press.
    down_syms: [128]u32 = @splat(0),
    /// The input method: on for a text widget with the focus, the box of
    /// the widget in logical pixels, and the composition.
    ime_on: bool = false,
    ime_rect: geom.Rect = .{},
    ime: Ime = .{},
    /// The menu bar of the window (`toplevel -menu`), or 0.
    bar: plat.MenuId = 0,
    /// The kinds of data that the window accepts from drags (ztk#62).
    drop_types: plat.DropTypes = .{},
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
    /// The windows that are open, for the events of the whole program.
    wins: std.ArrayListUnmanaged(*Win) = .empty,
    /// The observer of the appearance, an object of a class made at run time.
    /// The frame at once of a window in a live resize (`setLiveResize`).
    live_resize: ?plat.LiveResize = null,
    /// The text engine of the system, made at the first use.
    coretext: ?*coretext.CoreText = null,
    observer: ?Id = null,
    /// The clipboard: the general pasteboard.
    clip: Pasteboard,
    /// The texts of the events of the last poll, and of the events since.
    texts_given: std.ArrayListUnmanaged([]u8) = .empty,
    texts_new: std.ArrayListUnmanaged([]u8) = .empty,
    /// The native menus, and the windows of their events: the window of a
    /// post while it is open, and the key window for the bar.
    menus: *nsmenu.Menus = undefined,
    post_win: ?*Win = null,
    key_win: ?*Win = null,
    /// The Dock icon: its badge, its progress bar, and a request for attention.
    dock: macdock.Dock = .{},
    /// The delegate of NSApp, for the menu of the Dock icon, and that menu.
    app_delegate: ?Id = null,
    dock_menu: plat.MenuId = 0,
    /// The status items of the menu bar.
    trays: *mactray.Trays = undefined,

    pub fn init(gpa: std.mem.Allocator) !*AppKit {
        // AppKit makes windows only on the main thread.
        if (pthread_main_np() == 0) return error.NotMainThread;
        const pool = objc.Pool.push();
        defer pool.pop();
        const app = objc.call(fn (Class, Sel) callconv(.c) Id, objc.class("NSApplication") orelse return error.NoAppKit, "sharedApplication", .{});
        _ = objc.call(fn (Id, Sel, isize) callconv(.c) bool, app, "setActivationPolicy:", .{activation_regular});
        objc.call(fn (Id, Sel) callconv(.c) void, app, "finishLaunching", .{});
        const a = try gpa.create(AppKit);
        errdefer gpa.destroy(a);
        a.* = .{ .gpa = gpa, .app = app, .view_class = viewClass(), .delegate_class = delegateClass(), .clip = Pasteboard.general() };
        a.observe();
        a.menus = try nsmenu.Menus.init(gpa, .{ .ctx = a, .menu = menuEvent, .command = appCommand, .key = menuKey });
        a.menus.show(0);
        errdefer a.menus.deinit();
        a.trays = try mactray.Trays.init(gpa, .{ .ctx = a, .action = trayAction });
        return a;
    }

    pub fn deinit(a: *AppKit) void {
        if (a.coretext) |c| c.deinit();
        a.freeTexts(&a.texts_given);
        a.freeTexts(&a.texts_new);
        a.texts_given.deinit(a.gpa);
        a.texts_new.deinit(a.gpa);
        if (a.observer) |o| {
            const key = objc.nsString("effectiveAppearance");
            defer objc.release(key);
            objc.call(fn (Id, Sel, Id, Id) callconv(.c) void, a.app, "removeObserver:forKeyPath:", .{ o, key });
            send(notificationCenter(), "removeObserver:", .{o});
            objc.setData(o, null);
            objc.release(o);
        }
        a.wins.deinit(a.gpa);
        a.trays.deinit();
        a.dock.deinit();
        if (a.app_delegate) |d| {
            send(a.app, "setDelegate:", .{@as(?Id, null)});
            objc.setData(d, null);
            objc.release(d);
        }
        a.menus.deinit();
        a.events.deinit(a.gpa);
        a.gpa.destroy(a);
    }

    pub fn platform(a: *AppKit) Platform {
        return .{ .ptr = a, .vtable = &vtable, .live = true, .thread_safe_draw = true, .native_menus = true };
    }

    const vtable: Platform.VTable = .{
        .deinit = vDeinit,
        .textSystem = vTextSystem,
        .nativeLook = vNativeLook,
        .setLiveResize = vSetLiveResize,
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
        .appearance = vAppearance,
        .reducedMotion = vReducedMotion,
        .setWindowState = vSetWindowState,
        .dropTypes = vDropTypes,
        .clipboardSet = vClipboardSet,
        .clipboardGet = vClipboardGet,
        .textInput = vTextInput,
        .menuSet = vMenuSet,
        .menuEntrySet = vMenuEntrySet,
        .menuDrop = vMenuDrop,
        .setMenuBar = vSetMenuBar,
        .postMenu = vPostMenu,
        .unpostMenu = vUnpostMenu,
        .setMenuHandler = vSetMenuHandler,
        .taskbarSet = vTaskbarSet,
        .attention = vAttention,
        .macDockMenu = vDockMenu,
        .macTabbing = vTabbing,
        .trayCreate = vTrayCreate,
        .traySet = vTraySet,
        .setIcon = vSetIcon,
        .trayDrop = vTrayDrop,
        .fileDialog = vFileDialog,
        .messageBox = vMessageBox,
        .colorDialog = vColorDialog,
        .dragStart = vDragStart,
    };

    // ---- The tray ----

    fn vTrayCreate(ptr: *anyopaque, win: *Window, icon: plat.TrayIcon, template: bool, tooltip: []const u8) plat.TrayId {
        return self(ptr).trays.create(winOf(win), icon, template, tooltip);
    }

    /// `wm iconphoto`: the icon of the Dock, as Tk's Aqua port does, since
    /// a window of macOS has no icon of its own. An app bundle with an icon
    /// (CFBundleIconFile or CFBundleIconName) keeps it.
    fn vSetIcon(_: *anyopaque, _: *Window, icons: []const plat.TrayIcon, _: bool) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const bundle = objc.call(fn (Class, Sel) callconv(.c) Id, objc.class("NSBundle").?, "mainBundle", .{});
        for ([_][]const u8{ "CFBundleIconFile", "CFBundleIconName" }) |k| {
            const key = objc.nsString(k);
            defer objc.release(key);
            if (objc.call(fn (Id, Sel, Id) callconv(.c) ?Id, bundle, "objectForInfoDictionaryKey:", .{key}) != null) return;
        }
        const img = mactray.dockImageOf(icons) orelse return;
        defer objc.release(img);
        const app = objc.call(fn (Class, Sel) callconv(.c) Id, objc.class("NSApplication").?, "sharedApplication", .{});
        objc.call(fn (Id, Sel, Id) callconv(.c) void, app, "setApplicationIconImage:", .{img});
    }

    fn vTraySet(ptr: *anyopaque, id: plat.TrayId, icon: plat.TrayIcon, template: bool, tooltip: []const u8, menu: plat.MenuId) void {
        const a = self(ptr);
        const ns: ?Id = if (a.menus.menus.get(menu)) |m| m.ns else null;
        a.trays.set(id, icon, template, tooltip, ns);
    }

    fn vTrayDrop(ptr: *anyopaque, id: plat.TrayId) void {
        self(ptr).trays.drop(id);
    }

    fn trayAction(ctx: *anyopaque, owner: *anyopaque, id: plat.TrayId, action: event.TrayAction) void {
        const w: *Win = @ptrCast(@alignCast(owner));
        self(ctx).push(.{ .tray = .{ .window = &w.window, .id = id, .action = action } });
    }

    // ---- The Dock ----

    fn vTaskbarSet(ptr: *anyopaque, _: *Window, state: plat.Taskbar) void {
        self(ptr).dock.set(state);
    }

    fn vAttention(ptr: *anyopaque, _: *Window, critical: bool) void {
        self(ptr).dock.setAttention(critical);
    }

    // ---- The direct APIs of macOS ----

    /// The menu of the Dock icon. NSApp asks its delegate with
    /// `applicationDockMenu:` each time the Dock shows the menu.
    fn vDockMenu(ptr: *anyopaque, id: plat.MenuId) void {
        const a = self(ptr);
        a.dock_menu = id;
        if (a.app_delegate == null) {
            const d = objc.new(appDelegateClass());
            objc.setData(d, a);
            a.app_delegate = d;
            send(a.app, "setDelegate:", .{d});
        }
    }

    fn onDockMenu(delegate: Id, _: Sel, _: Id) callconv(.c) ?Id {
        const a: *AppKit = @ptrCast(@alignCast(objc.getData(delegate) orelse return null));
        const m = a.menus.menus.get(a.dock_menu) orelse return null;
        return m.ns;
    }

    fn appDelegateClass() Class {
        if (objc.class("ZtkAppDelegate")) |c| return c;
        const b = objc.ClassBuilder.begin("NSObject", "ZtkAppDelegate").?;
        _ = b.protocol("NSApplicationDelegate");
        b.method("applicationDockMenu:", @ptrCast(&onDockMenu), "@@:@");
        return b.finish();
    }

    /// NSWindowTabbingModeAutomatic, Preferred, and Disallowed are 0, 1, and 2.
    fn vTabbing(_: *anyopaque, win: *Window, mode: plat.Tabbing, group: []const u8) void {
        const w = winOf(win);
        send(w.ns_window, "setTabbingMode:", .{@as(isize, @backingInt(mode))});
        const g = objc.nsString(group);
        defer objc.release(g);
        send(w.ns_window, "setTabbingIdentifier:", .{g});
    }

    // ---- The native menus ----

    fn vMenuSet(ptr: *anyopaque, menu: *const plat.Menu) void {
        self(ptr).menus.set(menu);
    }

    fn vMenuEntrySet(ptr: *anyopaque, id: plat.MenuId, index: u32, entry: *const plat.MenuEntry) void {
        self(ptr).menus.entrySet(id, index, entry);
    }

    fn vMenuDrop(ptr: *anyopaque, id: plat.MenuId) void {
        self(ptr).menus.drop(id);
    }

    fn vSetMenuBar(ptr: *anyopaque, win: *Window, id: plat.MenuId) void {
        const a = self(ptr);
        const w = winOf(win);
        w.bar = id;
        if (a.key_win == w) a.menus.show(id);
    }

    fn vPostMenu(ptr: *anyopaque, win: *Window, id: plat.MenuId, at: geom.Point, entry: i32) void {
        const a = self(ptr);
        const w = winOf(win);
        const before = a.post_win;
        a.post_win = w;
        defer a.post_win = before;
        // The view is flipped, so the point is in the view as the core gives it.
        a.menus.post(w.view, id, .{ .x = at.x, .y = at.y }, entry);
    }

    fn vUnpostMenu(ptr: *anyopaque, id: plat.MenuId) void {
        self(ptr).menus.unpost(id);
    }

    fn vSetMenuHandler(ptr: *anyopaque, h: plat.MenuHandler) void {
        self(ptr).menus.handler = h;
    }

    /// A `menu` event, for the window of the post or the key window.
    fn menuEvent(ctx: *anyopaque, id: plat.MenuId, entry: i32, action: event.MenuAction) void {
        const a = self(ctx);
        // A menu of a tray can open with no key window, in an app that
        // lives in the menu bar.
        const w = a.post_win orelse a.key_win orelse (if (a.wins.items.len > 0) a.wins.items[0] else return);
        a.push(.{ .menu = .{ .window = &w.window, .menu = id, .entry = entry, .action = action } });
    }

    fn appCommand(ctx: *anyopaque, command: event.AppCommand) void {
        self(ctx).push(.{ .app_command = .{ .command = command } });
    }

    /// A key equivalent chose an item: the key goes to the key window as
    /// a key that no menu took.
    fn menuKey(ctx: *anyopaque, ev: Id) void {
        const w = self(ctx).key_win orelse return;
        send(w.view, "keyDown:", .{ev});
    }

    fn vDragStart(ptr: *anyopaque, win: *Window, d: plat.DragData) plat.DragAction {
        const a = self(ptr);
        return macdrag.run(a.gpa, a.app, winOf(win).view, d);
    }

    fn vFileDialog(_: *anyopaque, gpa: std.mem.Allocator, opts: *const plat.FileDialog) ?plat.FileDialogResult {
        const parent: ?Id = if (opts.parent) |win| winOf(win).ns_window else null;
        return macdialog.run(gpa, opts, parent);
    }

    fn vMessageBox(_: *anyopaque, opts: *const plat.MessageBox) ?plat.MessageBox.Button {
        const parent: ?Id = if (opts.parent) |win| winOf(win).ns_window else null;
        return macdialog.messageBox(opts, parent);
    }

    fn vColorDialog(_: *anyopaque, _: std.mem.Allocator, opts: *const plat.ColorDialog) ?@import("../base/geom.zig").Color {
        return macdialog.colorDialog(opts);
    }

    fn vClipboardSet(ptr: *anyopaque, typ: []const u8, data: []const u8) void {
        self(ptr).clip.set(typ, data);
    }

    fn vClipboardGet(ptr: *anyopaque, gpa: std.mem.Allocator, typ: []const u8) ?[]u8 {
        return self(ptr).clip.get(gpa, typ);
    }

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
        _ = objc.call(fn (Id, Sel, Id) callconv(.c) bool, ns_window, "makeFirstResponder:", .{view});
        addTracking(view);

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
        a.wins.append(a.gpa, w) catch {};
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
        if (a.key_win == w) {
            a.key_win = null;
            a.menus.show(0);
        }
        if (a.post_win == w) a.post_win = null;
        a.trays.dropOwner(w);
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
        w.ime.deinit(a.gpa);
        a.gpa.destroy(w);
        a.windows -|= 1;
        for (a.wins.items, 0..) |x, k| if (x == w) {
            _ = a.wins.swapRemove(k);
            break;
        };
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

    fn vSetLiveResize(ptr: *anyopaque, hook: plat.LiveResize) void {
        self(ptr).live_resize = hook;
    }

    /// The Aqua sheet of the modern theme (themes/aqua-macos.css).
    fn vNativeLook(_: *anyopaque) ?[]const u8 {
        return "macos";
    }

    fn vTextSystem(ptr: *anyopaque) ?@import("../text/system.zig").System {
        const a = self(ptr);
        if (a.coretext == null) a.coretext = coretext.CoreText.init(a.gpa);
        const c = a.coretext orelse return null;
        return c.backend();
    }

    fn vPoll(ptr: *anyopaque, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(Event)) anyerror!void {
        const a = self(ptr);
        // The texts of the events that the last poll gave are no longer in use.
        a.freeTexts(&a.texts_given);
        std.mem.swap(std.ArrayListUnmanaged([]u8), &a.texts_given, &a.texts_new);
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

    // ---- Input ----

    fn addTracking(view: Id) void {
        // mouseEnteredAndExited, mouseMoved, cursorUpdate, activeAlways (the
        // hover of a window that is not the key window, as on the other
        // systems), and inVisibleRect, so the area follows the size of the view.
        const options: usize = 0x01 | 0x02 | 0x04 | 0x80 | 0x200;
        const alloc = objc.call(fn (Class, Sel) callconv(.c) Id, objc.class("NSTrackingArea").?, "alloc", .{});
        const zero = NSRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .w = 0, .h = 0 } };
        const area = objc.call(fn (Id, Sel, NSRect, usize, Id, ?Id) callconv(.c) Id, alloc, "initWithRect:options:owner:userInfo:", .{ zero, options, view, null });
        send(view, "addTrackingArea:", .{area});
        objc.release(area);
    }

    fn timeMs(ev: Id) u32 {
        const s = objc.call(fn (Id, Sel) callconv(.c) f64, ev, "timestamp", .{});
        return @truncate(@as(u64, @intFromFloat(@max(s, 0) * 1000)));
    }

    fn flagsOf(ev: Id) u64 {
        return objc.call(fn (Id, Sel) callconv(.c) u64, ev, "modifierFlags", .{});
    }

    fn pressedButtons() u64 {
        return objc.call(fn (Class, Sel) callconv(.c) u64, objc.class("NSEvent").?, "pressedMouseButtons", .{});
    }

    /// The position of a mouse event in the view, in logical pixels from
    /// the top left (the view is flipped).
    fn pointIn(w: *Win, ev: Id) NSPoint {
        const p = objc.call(fn (Id, Sel) callconv(.c) NSPoint, ev, "locationInWindow", .{});
        return objc.call(fn (Id, Sel, NSPoint, ?Id) callconv(.c) NSPoint, w.view, "convertPoint:fromView:", .{ p, null });
    }

    fn keyEvent(w: *Win, ev: Id, pressed: bool) void {
        const code = objc.call(fn (Id, Sel) callconv(.c) u16, ev, "keyCode", .{});
        const flags = flagsOf(ev);
        const m = mackeys.mods(flags, pressedButtons());
        const slot: ?*u32 = if (code < w.down_syms.len) &w.down_syms[code] else null;
        if (!pressed) {
            const sym = if (slot) |sl| sl.* else 0;
            if (slot) |sl| sl.* = 0;
            const s = if (sym != 0) sym else mackeys.special(code) orelse return;
            w.owner.push(.{ .key = .{ .window = &w.window, .keysym = s, .keycode = code, .pressed = false, .repeat = false, .mods = m, .time_ms = timeMs(ev) } });
            return;
        }
        const plain = textOf(objc.call(fn (Id, Sel) callconv(.c) ?Id, ev, "charactersIgnoringModifiers", .{}));
        const typed = textOf(objc.call(fn (Id, Sel) callconv(.c) ?Id, ev, "characters", .{}));
        var e: Event = .{ .key = .{ .window = &w.window, .keysym = 0, .keycode = code, .pressed = true, .repeat = objc.call(fn (Id, Sel) callconv(.c) bool, ev, "isARepeat", .{}), .mods = m, .time_ms = timeMs(ev) } };
        const r = mackeys.press(code, plain, typed, flags, &e.key.text) orelse return;
        e.key.keysym = r.sym;
        e.key.text_len = r.len;
        if (slot) |sl| sl.* = r.sym;
        w.owner.push(e);
    }

    fn textOf(str: ?Id) []const u8 {
        return objc.utf8(str orelse return "");
    }

    /// A modifier key: a press when its flag is now set, else a release.
    fn flagsEvent(w: *Win, ev: Id) void {
        const code = objc.call(fn (Id, Sel) callconv(.c) u16, ev, "keyCode", .{});
        const sym = mackeys.modifierKey(code) orelse return;
        const flags = flagsOf(ev);
        const pressed = flags & mackeys.modifierFlag(code) != 0;
        // The state before the key, as X11 gives it: the flag of a press is not in it yet.
        const before = if (pressed) flags & ~mackeys.modifierFlag(code) else flags | mackeys.modifierFlag(code);
        w.owner.push(.{ .key = .{ .window = &w.window, .keysym = sym, .keycode = code, .pressed = pressed, .repeat = false, .mods = mackeys.mods(before, pressedButtons()), .time_ms = timeMs(ev) } });
    }

    fn buttonEvent(w: *Win, ev: Id, pressed: bool) void {
        const number = objc.call(fn (Id, Sel) callconv(.c) isize, ev, "buttonNumber", .{});
        const b = mackeys.button(number) orelse return;
        const p = pointIn(w, ev);
        const x: f32 = @floatCast(p.x);
        const y: f32 = @floatCast(p.y);
        w.window.feedPointer(x, y);
        // The state before the event, as X11 gives it: a press is not in it yet.
        var buttons = pressedButtons();
        const bit: u64 = switch (number) {
            0 => 1,
            1 => 2,
            2 => 4,
            else => 0,
        };
        buttons = if (pressed) buttons & ~bit else buttons | bit;
        w.owner.push(.{ .button = .{ .window = &w.window, .button = b, .pressed = pressed, .x = x, .y = y, .mods = mackeys.mods(flagsOf(ev), buttons), .time_ms = timeMs(ev) } });
    }

    fn motionEvent(w: *Win, ev: Id) void {
        const p = pointIn(w, ev);
        const x: f32 = @floatCast(p.x);
        const y: f32 = @floatCast(p.y);
        w.window.feedPointer(x, y);
        w.owner.push(.{ .motion = .{ .window = &w.window, .x = x, .y = y, .mods = mackeys.mods(flagsOf(ev), pressedButtons()), .time_ms = timeMs(ev) } });
    }

    /// A trackpad gives precise deltas in points, and a mouse wheel gives
    /// lines. The event counts steps of 10 points, as the Wayland backend
    /// does, and a line is one step. AppKit gives a positive delta for a
    /// scroll toward the top, and the event a positive delta toward the bottom.
    fn scrollEvent(w: *Win, ev: Id) void {
        const precise = objc.call(fn (Id, Sel) callconv(.c) bool, ev, "hasPreciseScrollingDeltas", .{});
        var dx = objc.call(fn (Id, Sel) callconv(.c) f64, ev, "scrollingDeltaX", .{});
        var dy = objc.call(fn (Id, Sel) callconv(.c) f64, ev, "scrollingDeltaY", .{});
        if (precise) {
            dx /= 10;
            dy /= 10;
        }
        if (dx == 0 and dy == 0) return;
        const p = pointIn(w, ev);
        w.owner.push(.{ .scroll = .{ .window = &w.window, .dx = @floatCast(-dx), .dy = @floatCast(-dy), .x = @floatCast(p.x), .y = @floatCast(p.y), .mods = mackeys.mods(flagsOf(ev), pressedButtons()), .time_ms = timeMs(ev) } });
    }

    fn vSetCursor(_: *anyopaque, win: *Window, shape: plat.Cursor) void {
        const w = winOf(win);
        if (w.cursor == shape) return;
        w.cursor = shape;
        // The shape changes now when the pointer is over the view, and at
        // the next cursor update otherwise.
        const p = objc.call(fn (Id, Sel) callconv(.c) NSPoint, w.ns_window, "mouseLocationOutsideOfEventStream", .{});
        const v = objc.call(fn (Id, Sel, NSPoint, ?Id) callconv(.c) NSPoint, w.view, "convertPoint:fromView:", .{ p, null });
        const b = objc.callStruct(NSRect, w.view, "bounds");
        if (v.x >= 0 and v.y >= 0 and v.x < b.size.w and v.y < b.size.h) send(nsCursor(shape), "set", .{});
    }

    /// The `NSCursor` of a shape. AppKit has no wait, progress, move, or
    /// help cursor, so those are the arrow. The diagonal resize shapes need
    /// macOS 15.
    fn nsCursor(shape: plat.Cursor) Id {
        const cls = objc.class("NSCursor").?;
        const name: [*:0]const u8 = switch (shape) {
            .pointer => "pointingHandCursor",
            .text => "IBeamCursor",
            .crosshair => "crosshairCursor",
            .not_allowed => "operationNotAllowedCursor",
            .grab => "openHandCursor",
            .grabbing, .move => "closedHandCursor",
            .ew_resize => "resizeLeftRightCursor",
            .ns_resize => "resizeUpDownCursor",
            .nwse_resize, .nesw_resize => return diagonal(cls, shape) orelse arrow(cls),
            else => "arrowCursor",
        };
        return objc.call(fn (Class, Sel) callconv(.c) Id, cls, name, .{});
    }

    fn arrow(cls: Class) Id {
        return objc.call(fn (Class, Sel) callconv(.c) Id, cls, "arrowCursor", .{});
    }

    /// `frameResizeCursorFromPosition:inDirections:` of macOS 15. The
    /// position is a corner of `NSCursorFrameResizePosition`: top (1) with
    /// left (2) or right (8). The directions are inward and outward (3).
    fn diagonal(cls: Class, shape: plat.Cursor) ?Id {
        const s = objc.sel("frameResizeCursorFromPosition:inDirections:");
        const meta: Id = @ptrCast(cls);
        if (!objc.call(fn (Id, Sel, Sel) callconv(.c) bool, meta, "respondsToSelector:", .{s})) return null;
        const position: usize = if (shape == .nwse_resize) 1 | 2 else 1 | 8;
        return objc.call(fn (Class, Sel, usize, usize) callconv(.c) ?Id, cls, "frameResizeCursorFromPosition:inDirections:", .{ position, 3 });
    }

    // ---- The input method ----

    fn freeTexts(a: *AppKit, list: *std.ArrayListUnmanaged([]u8)) void {
        for (list.items) |x| a.gpa.free(x);
        list.clearRetainingCapacity();
    }

    fn keepText(a: *AppKit, text: []const u8) ?[]const u8 {
        const copy = a.gpa.dupe(u8, text) catch return null;
        a.texts_new.append(a.gpa, copy) catch {
            a.gpa.free(copy);
            return null;
        };
        return copy;
    }

    fn apply(w: *Win, act: Ime.Action) void {
        const a = w.owner;
        switch (act) {
            .none => {},
            .preedit => |p| if (a.keepText(p.text)) |x| a.push(.{ .preedit = .{ .window = &w.window, .text = x, .caret = p.caret } }),
            .commit => |c| if (a.keepText(c)) |x| a.push(.{ .commit = .{ .window = &w.window, .text = x } }),
        }
    }

    fn vTextInput(_: *anyopaque, win: *Window, on: bool, rect: geom.Rect) void {
        const w = winOf(win);
        w.ime_rect = rect;
        if (on == w.ime_on) {
            if (on) if (inputContext(w.view)) |ctx| send(ctx, "invalidateCharacterCoordinates", .{});
            return;
        }
        w.ime_on = on;
        if (!on) {
            if (inputContext(w.view)) |ctx| send(ctx, "discardMarkedText", .{});
            apply(w, w.ime.discard());
        }
    }

    fn inputContext(view: Id) ?Id {
        return objc.call(fn (Id, Sel) callconv(.c) ?Id, view, "inputContext", .{});
    }

    /// The text of an `NSString` or an `NSAttributedString`.
    fn plainString(obj: Id) Id {
        const attributed = objc.class("NSAttributedString").?;
        if (objc.call(fn (Id, Sel, Class) callconv(.c) bool, obj, "isKindOfClass:", .{attributed}))
            return objc.call(fn (Id, Sel) callconv(.c) Id, obj, "string", .{});
        return obj;
    }

    fn onHasMarked(view: Id, _: Sel) callconv(.c) bool {
        const w = dataOf(view) orelse return false;
        return w.ime.hasMarked();
    }

    fn onMarkedRange(view: Id, _: Sel) callconv(.c) NSRange {
        const w = dataOf(view) orelse return .{ .location = not_found, .length = 0 };
        if (!w.ime.hasMarked()) return .{ .location = not_found, .length = 0 };
        const s = objc.nsString(w.ime.marked.items);
        defer objc.release(s);
        return .{ .location = 0, .length = objc.call(fn (Id, Sel) callconv(.c) usize, s, "length", .{}) };
    }

    fn onSelectedRange(_: Id, _: Sel) callconv(.c) NSRange {
        // The text of the widget stays in the core, so the input method
        // sees an empty selection.
        return .{ .location = not_found, .length = 0 };
    }

    fn onSetMarked(view: Id, _: Sel, text: Id, selected: NSRange, _: NSRange) callconv(.c) void {
        const w = dataOf(view) orelse return;
        const str = plainString(text);
        apply(w, w.ime.setMarked(w.owner.gpa, objc.utf8(str), selected.location));
    }

    fn onUnmark(view: Id, _: Sel) callconv(.c) void {
        const w = dataOf(view) orelse return;
        apply(w, w.ime.unmark());
    }

    fn onInsert(view: Id, _: Sel, text: Id, _: NSRange) callconv(.c) void {
        const w = dataOf(view) orelse return;
        const str = plainString(text);
        apply(w, w.ime.insert(objc.utf8(str)));
    }

    fn onCommand(view: Id, _: Sel, _: Sel) callconv(.c) void {
        if (dataOf(view)) |w| w.ime.command();
    }

    fn onValidAttributes(_: Id, _: Sel) callconv(.c) Id {
        return objc.call(fn (Class, Sel) callconv(.c) Id, objc.class("NSArray").?, "array", .{});
    }

    fn onAttributedSubstring(_: Id, _: Sel, _: NSRange, _: ?*NSRange) callconv(.c) ?Id {
        return null;
    }

    fn onCharacterIndex(_: Id, _: Sel, _: NSPoint) callconv(.c) usize {
        return not_found;
    }

    /// The box of the text widget in screen coordinates, so the candidate
    /// window of the input method opens below it.
    fn onFirstRect(view: Id, _: Sel, _: NSRange, actual: ?*NSRange) callconv(.c) NSRect {
        if (actual) |r| r.* = .{ .location = not_found, .length = 0 };
        const w = dataOf(view) orelse return .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .w = 0, .h = 0 } };
        const r = w.ime_rect;
        // The view is flipped: the bottom left of the box has the larger y.
        const bottom_left = NSPoint{ .x = @floatFromInt(r.x), .y = @floatFromInt(r.y + r.h) };
        const in_window = objc.call(fn (Id, Sel, NSPoint, ?Id) callconv(.c) NSPoint, view, "convertPoint:toView:", .{ bottom_left, null });
        const on_screen = objc.call(fn (Id, Sel, NSPoint) callconv(.c) NSPoint, w.ns_window, "convertPointToScreen:", .{in_window});
        return .{ .origin = on_screen, .size = .{ .w = @floatFromInt(r.w), .h = @floatFromInt(r.h) } };
    }

    // ---- The appearance ----

    fn notificationCenter() Id {
        return objc.call(fn (Class, Sel) callconv(.c) Id, objc.class("NSNotificationCenter").?, "defaultCenter", .{});
    }

    fn observe(a: *AppKit) void {
        const cls = observerClass();
        const o = objc.new(cls);
        objc.setData(o, a);
        const key = objc.nsString("effectiveAppearance");
        defer objc.release(key);
        // Options 0 and a null context: the observer reads the new value itself.
        objc.call(fn (Id, Sel, Id, Id, usize, ?*anyopaque) callconv(.c) void, a.app, "addObserver:forKeyPath:options:context:", .{ o, key, 0, null });
        objc.call(fn (Id, Sel, Id, Sel, Id, ?Id) callconv(.c) void, notificationCenter(), "addObserver:selector:name:object:", .{ o, objc.sel("ztkColors:"), NSSystemColorsDidChangeNotification, null });
        // A change of Reduce motion in the settings of Accessibility is an
        // `appearance` event too: the core reads `reducedMotion` again.
        const ws = objc.call(fn (Class, Sel) callconv(.c) Id, objc.class("NSWorkspace").?, "sharedWorkspace", .{});
        const wsc = objc.call(fn (Id, Sel) callconv(.c) Id, ws, "notificationCenter", .{});
        const name = objc.nsString("NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification");
        defer objc.release(name);
        objc.call(fn (Id, Sel, Id, Sel, Id, ?Id) callconv(.c) void, wsc, "addObserver:selector:name:object:", .{ o, objc.sel("ztkColors:"), name, null });
        a.observer = o;
    }

    /// One `appearance` event for the program. The core reads the
    /// appearance again for each window, so the event names the first one.
    fn appearanceChanged(a: *AppKit) void {
        if (a.wins.items.len == 0) return;
        for (a.events.items) |e| if (e == .appearance) return;
        a.push(.{ .appearance = .{ .window = &a.wins.items[0].window } });
    }

    /// The setting Reduce motion of Accessibility.
    fn vReducedMotion(_: *anyopaque) bool {
        const ws = objc.call(fn (Class, Sel) callconv(.c) Id, objc.class("NSWorkspace").?, "sharedWorkspace", .{});
        return objc.call(fn (Id, Sel) callconv(.c) bool, ws, "accessibilityDisplayShouldReduceMotion", .{});
    }

    /// `wm attributes -fullscreen` and `-topmost`. Full screen is the full
    /// screen of macOS, a space of its own with an animation, which
    /// `toggleFullScreen:` starts only when the state differs. Topmost is
    /// the floating level of panels.
    fn vSetWindowState(_: *anyopaque, win: *Window, st: plat.WindowState) void {
        const w = winOf(win);
        const full_mask: usize = 1 << 14; // NSWindowStyleMaskFullScreen
        const mask = objc.call(fn (Id, Sel) callconv(.c) usize, w.ns_window, "styleMask", .{});
        if ((mask & full_mask != 0) != st.fullscreen)
            objc.call(fn (Id, Sel, ?Id) callconv(.c) void, w.ns_window, "toggleFullScreen:", .{null});
        // NSFloatingWindowLevel 3, NSNormalWindowLevel 0.
        objc.call(fn (Id, Sel, isize) callconv(.c) void, w.ns_window, "setLevel:", .{@as(isize, if (st.topmost) 3 else 0)});
    }

    // ---- The drops of other apps (ztk#62) ----

    const type_file_url = "public.file-url";
    const type_text = "public.utf8-plain-text";

    /// Registers the view for the pasteboard types of `types`, or for
    /// none, which stops the drops.
    fn vDropTypes(_: *anyopaque, win: *Window, types: plat.DropTypes) void {
        const w = winOf(win);
        w.drop_types = types;
        const pool = objc.Pool.push();
        defer pool.pop();
        send(w.view, "unregisterDraggedTypes", .{});
        if (!types.any()) return;
        const arr = objc.call(fn (Class, Sel) callconv(.c) Id, objc.class("NSMutableArray").?, "array", .{});
        if (types.files) objc.call(fn (Id, Sel, Id) callconv(.c) void, arr, "addObject:", .{nsTemp(type_file_url)});
        if (types.text) objc.call(fn (Id, Sel, Id) callconv(.c) void, arr, "addObject:", .{nsTemp(type_text)});
        objc.call(fn (Id, Sel, Id) callconv(.c) void, w.view, "registerForDraggedTypes:", .{arr});
    }

    fn nsTemp(text: []const u8) Id {
        return objc.call(fn (Id, Sel) callconv(.c) Id, objc.nsString(text), "autorelease", .{});
    }

    /// The point of a drag in the view, in logical pixels from the top left.
    fn dragPoint(w: *Win, info: Id) NSPoint {
        const loc = objc.call(fn (Id, Sel) callconv(.c) NSPoint, info, "draggingLocation", .{});
        return objc.call(fn (Id, Sel, NSPoint, ?Id) callconv(.c) NSPoint, w.view, "convertPoint:fromView:", .{ loc, null });
    }

    /// True when the pasteboard of the drag has a kind that the window takes.
    fn dragWanted(w: *Win, info: Id) bool {
        const pb = objc.call(fn (Id, Sel) callconv(.c) Id, info, "draggingPasteboard", .{});
        const types = objc.call(fn (Id, Sel) callconv(.c) ?Id, pb, "types", .{}) orelse return false;
        const has = struct {
            fn of(list: Id, name: []const u8) bool {
                return objc.call(fn (Id, Sel, Id) callconv(.c) bool, list, "containsObject:", .{nsTemp(name)});
            }
        };
        return (w.drop_types.files and has.of(types, type_file_url)) or (w.drop_types.text and has.of(types, type_text));
    }

    /// NSDragOperationCopy, or NSDragOperationNone.
    fn dragPhase(view: Id, info: Id, phase: event.DropPhase) usize {
        const w = dataOf(view) orelse return 0;
        const pool = objc.Pool.push();
        defer pool.pop();
        if (!dragWanted(w, info)) return 0;
        const p = dragPoint(w, info);
        w.owner.push(.{ .drop = .{ .window = &w.window, .phase = phase, .x = @floatCast(p.x), .y = @floatCast(p.y) } });
        return 1;
    }

    fn onDragEnter(view: Id, _: Sel, info: Id) callconv(.c) usize {
        return dragPhase(view, info, .enter);
    }

    fn onDragUpdate(view: Id, _: Sel, info: Id) callconv(.c) usize {
        return dragPhase(view, info, .over);
    }

    fn onDragExit(view: Id, _: Sel, _: ?Id) callconv(.c) void {
        const w = dataOf(view) orelse return;
        w.owner.push(.{ .drop = .{ .window = &w.window, .phase = .leave } });
    }

    fn onDragPrepare(view: Id, _: Sel, info: Id) callconv(.c) bool {
        const w = dataOf(view) orelse return false;
        return dragWanted(w, info);
    }

    /// The drop: the file URLs as host paths separated by 0, or the text.
    fn onDragPerform(view: Id, _: Sel, info: Id) callconv(.c) bool {
        const w = dataOf(view) orelse return false;
        const pool = objc.Pool.push();
        defer pool.pop();
        const a = w.owner;
        const pb = objc.call(fn (Id, Sel) callconv(.c) Id, info, "draggingPasteboard", .{});
        var files: std.ArrayList(u8) = .empty;
        defer files.deinit(a.gpa);
        if (w.drop_types.files) {
            const classes = [1]Id{@ptrCast(objc.class("NSURL").?)};
            const arr = objc.call(fn (Class, Sel, [*]const Id, usize) callconv(.c) Id, objc.class("NSArray").?, "arrayWithObjects:count:", .{ &classes, 1 });
            const yes_num = objc.call(fn (Class, Sel, bool) callconv(.c) Id, objc.class("NSNumber").?, "numberWithBool:", .{true});
            const keys = [1]Id{nsTemp("NSPasteboardURLReadingFileURLsOnlyKey")};
            const vals = [1]Id{yes_num};
            const dict = objc.call(fn (Class, Sel, [*]const Id, [*]const Id, usize) callconv(.c) Id, objc.class("NSDictionary").?, "dictionaryWithObjects:forKeys:count:", .{ &vals, &keys, 1 });
            if (objc.call(fn (Id, Sel, Id, Id) callconv(.c) ?Id, pb, "readObjectsForClasses:options:", .{ arr, dict })) |urls| {
                const n = objc.call(fn (Id, Sel) callconv(.c) usize, urls, "count", .{});
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const url = objc.call(fn (Id, Sel, usize) callconv(.c) Id, urls, "objectAtIndex:", .{i});
                    const path = objc.call(fn (Id, Sel) callconv(.c) ?Id, url, "path", .{}) orelse continue;
                    if (files.items.len > 0) files.append(a.gpa, 0) catch return false;
                    files.appendSlice(a.gpa, objc.utf8(path)) catch return false;
                }
            }
        }
        var text: []const u8 = "";
        if (files.items.len == 0 and w.drop_types.text) {
            if (objc.call(fn (Id, Sel, Id) callconv(.c) ?Id, pb, "stringForType:", .{nsTemp(type_text)})) |str| text = objc.utf8(str);
        }
        if (files.items.len == 0 and text.len == 0) return false;
        const f = if (files.items.len > 0) a.keepText(files.items) orelse return false else "";
        const t = if (text.len > 0) a.keepText(text) orelse return false else "";
        const p = dragPoint(w, info);
        a.push(.{ .drop = .{ .window = &w.window, .phase = .drop, .x = @floatCast(p.x), .y = @floatCast(p.y), .files = f, .text = t } });
        return true;
    }

    fn vAppearance(ptr: *anyopaque) plat.Appearance {
        const a = self(ptr);
        const pool = objc.Pool.push();
        defer pool.pop();
        const appearance = objc.call(fn (Id, Sel) callconv(.c) ?Id, a.app, "effectiveAppearance", .{});
        var dark = false;
        if (appearance) |ap| {
            const pair = [2]Id{ NSAppearanceNameAqua, NSAppearanceNameDarkAqua };
            const list = objc.call(fn (Class, Sel, [*]const Id, usize) callconv(.c) Id, objc.class("NSArray").?, "arrayWithObjects:count:", .{ &pair, 2 });
            if (objc.call(fn (Id, Sel, Id) callconv(.c) ?Id, ap, "bestMatchFromAppearancesWithNames:", .{list})) |best|
                dark = objc.call(fn (Id, Sel, Id) callconv(.c) bool, best, "isEqualToString:", .{NSAppearanceNameDarkAqua});
        }
        return .{ .dark = dark, .accent = accentColor(appearance) };
    }

    /// `controlAccentColor` in sRGB. It is a dynamic color, so it resolves
    /// with the appearance of the program as the current drawing appearance.
    fn accentColor(appearance: ?Id) ?geom.Color {
        const cls = objc.class("NSAppearance").?;
        const saved = objc.call(fn (Class, Sel) callconv(.c) ?Id, cls, "currentAppearance", .{});
        if (appearance) |ap| objc.call(fn (Class, Sel, ?Id) callconv(.c) void, cls, "setCurrentAppearance:", .{ap});
        defer objc.call(fn (Class, Sel, ?Id) callconv(.c) void, cls, "setCurrentAppearance:", .{saved});
        const accent = objc.call(fn (Class, Sel) callconv(.c) ?Id, objc.class("NSColor").?, "controlAccentColor", .{}) orelse return null;
        const srgb = objc.call(fn (Class, Sel) callconv(.c) Id, objc.class("NSColorSpace").?, "sRGBColorSpace", .{});
        const c = objc.call(fn (Id, Sel, Id) callconv(.c) ?Id, accent, "colorUsingColorSpace:", .{srgb}) orelse return null;
        var r: f64 = 0;
        var g: f64 = 0;
        var b: f64 = 0;
        var al: f64 = 0;
        objc.call(fn (Id, Sel, *f64, *f64, *f64, *f64) callconv(.c) void, c, "getRed:green:blue:alpha:", .{ &r, &g, &b, &al });
        return colorOf(r, g, b);
    }

    fn onAppearance(obj: Id, _: Sel, _: ?Id, _: ?Id, _: ?Id, _: ?*anyopaque) callconv(.c) void {
        const a: *AppKit = @ptrCast(@alignCast(objc.getData(obj) orelse return));
        a.appearanceChanged();
    }

    fn onColors(obj: Id, _: Sel, _: ?Id) callconv(.c) void {
        const a: *AppKit = @ptrCast(@alignCast(objc.getData(obj) orelse return));
        a.appearanceChanged();
    }

    fn observerClass() Class {
        if (objc.class("ZtkAppearanceObserver")) |c| return c;
        const b = objc.ClassBuilder.begin("NSObject", "ZtkAppearanceObserver").?;
        // The key, the object, the change dictionary, and the context.
        b.method("observeValueForKeyPath:ofObject:change:context:", @ptrCast(&onAppearance), "v@:@@@^v");
        b.method("ztkColors:", @ptrCast(&onColors), "v@:@");
        return b.finish();
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
        // "v@:@": no result and one object, the NSEvent.
        b.method("keyDown:", @ptrCast(&onKeyDown), "v@:@");
        b.method("keyUp:", @ptrCast(&onKeyUp), "v@:@");
        b.method("flagsChanged:", @ptrCast(&onFlags), "v@:@");
        for ([_][*:0]const u8{ "mouseDown:", "rightMouseDown:", "otherMouseDown:" }) |n| b.method(n, @ptrCast(&onDown), "v@:@");
        for ([_][*:0]const u8{ "mouseUp:", "rightMouseUp:", "otherMouseUp:" }) |n| b.method(n, @ptrCast(&onUp), "v@:@");
        for ([_][*:0]const u8{ "mouseMoved:", "mouseDragged:", "rightMouseDragged:", "otherMouseDragged:", "mouseEntered:" }) |n| b.method(n, @ptrCast(&onMotion), "v@:@");
        b.method("mouseExited:", @ptrCast(&onExit), "v@:@");
        b.method("scrollWheel:", @ptrCast(&onScroll), "v@:@");
        b.method("cursorUpdate:", @ptrCast(&onCursorUpdate), "v@:@");
        // NSTextInputClient. "{_NSRange=QQ}" is an NSRange, and
        // "{CGRect={CGPoint=dd}{CGSize=dd}}" an NSRect.
        _ = b.protocol("NSTextInputClient");
        b.method("hasMarkedText", @ptrCast(&onHasMarked), "c@:");
        b.method("markedRange", @ptrCast(&onMarkedRange), "{_NSRange=QQ}@:");
        b.method("selectedRange", @ptrCast(&onSelectedRange), "{_NSRange=QQ}@:");
        b.method("setMarkedText:selectedRange:replacementRange:", @ptrCast(&onSetMarked), "v@:@{_NSRange=QQ}{_NSRange=QQ}");
        b.method("unmarkText", @ptrCast(&onUnmark), "v@:");
        b.method("insertText:replacementRange:", @ptrCast(&onInsert), "v@:@{_NSRange=QQ}");
        b.method("doCommandBySelector:", @ptrCast(&onCommand), "v@::");
        b.method("validAttributesForMarkedText", @ptrCast(&onValidAttributes), "@@:");
        b.method("attributedSubstringForProposedRange:actualRange:", @ptrCast(&onAttributedSubstring), "@@:{_NSRange=QQ}^{_NSRange=QQ}");
        b.method("characterIndexForPoint:", @ptrCast(&onCharacterIndex), "Q@:{CGPoint=dd}");
        b.method("firstRectForCharacterRange:actualRange:", @ptrCast(&onFirstRect), "{CGRect={CGPoint=dd}{CGSize=dd}}@:{_NSRange=QQ}^{_NSRange=QQ}");
        // The first click on a window that is not the key window also goes to the view.
        b.method("acceptsFirstMouse:", @ptrCast(&yesFor), "c@:@");
        // NSDraggingDestination: the drags of other apps (ztk#62).
        b.method("draggingEntered:", @ptrCast(&onDragEnter), "Q@:@");
        b.method("draggingUpdated:", @ptrCast(&onDragUpdate), "Q@:@");
        b.method("draggingExited:", @ptrCast(&onDragExit), "v@:@");
        b.method("prepareForDragOperation:", @ptrCast(&onDragPrepare), "c@:@");
        b.method("performDragOperation:", @ptrCast(&onDragPerform), "c@:@");
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

    fn yesFor(_: Id, _: Sel, _: ?Id) callconv(.c) bool {
        return true;
    }

    fn onKeyDown(view: Id, _: Sel, ev: Id) callconv(.c) void {
        const w = dataOf(view) orelse return;
        // A key with Command or Control runs a binding and skips the input method.
        if (!w.ime_on or flagsOf(ev) & (mackeys.flag_command | mackeys.flag_control) != 0) return keyEvent(w, ev, true);
        w.ime.beginKey();
        const list = objc.call(fn (Class, Sel, Id) callconv(.c) Id, objc.class("NSArray").?, "arrayWithObject:", .{ev});
        send(view, "interpretKeyEvents:", .{list});
        if (w.ime.endKey()) keyEvent(w, ev, true);
    }

    fn onKeyUp(view: Id, _: Sel, ev: Id) callconv(.c) void {
        if (dataOf(view)) |w| keyEvent(w, ev, false);
    }

    fn onFlags(view: Id, _: Sel, ev: Id) callconv(.c) void {
        if (dataOf(view)) |w| flagsEvent(w, ev);
    }

    fn onDown(view: Id, _: Sel, ev: Id) callconv(.c) void {
        if (dataOf(view)) |w| buttonEvent(w, ev, true);
    }

    fn onUp(view: Id, _: Sel, ev: Id) callconv(.c) void {
        if (dataOf(view)) |w| buttonEvent(w, ev, false);
    }

    fn onMotion(view: Id, _: Sel, ev: Id) callconv(.c) void {
        if (dataOf(view)) |w| motionEvent(w, ev);
    }

    fn onExit(view: Id, _: Sel, _: Id) callconv(.c) void {
        if (dataOf(view)) |w| w.owner.push(.{ .leave = .{ .window = &w.window } });
    }

    fn onScroll(view: Id, _: Sel, ev: Id) callconv(.c) void {
        if (dataOf(view)) |w| scrollEvent(w, ev);
    }

    fn onCursorUpdate(view: Id, _: Sel, _: Id) callconv(.c) void {
        if (dataOf(view)) |w| send(nsCursor(w.cursor), "set", .{});
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
        // While the user drags the edge, AppKit runs its own loop and the
        // loop of ztk waits: the content draws here, at each new size, or
        // the old image stays at the top left until the mouse goes up.
        if (w.owner.live_resize) |hook| {
            if (objc.call(fn (Id, Sel) callconv(.c) bool, w.ns_window, "inLiveResize", .{}))
                hook.call(hook.ctx, &w.window, size);
        }
    }

    fn onBecomeKey(delegate: Id, _: Sel, _: Id) callconv(.c) void {
        const w = dataOf(delegate) orelse return;
        w.owner.key_win = w;
        w.owner.menus.show(w.bar);
        w.owner.push(.{ .focus = .{ .window = &w.window, .focused = true } });
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
    const fields = @typeInfo(@TypeOf(args)).@"struct".field_types;
    switch (fields.len) {
        0 => objc.call(fn (Id, Sel) callconv(.c) void, target, selector, args),
        1 => objc.call(fn (Id, Sel, fields[0]) callconv(.c) void, target, selector, args),
        else => @compileError("send has at most one argument; use objc.call for more"),
    }
}

/// An sRGB color from components from 0 to 1, rounded to 8 bits.
fn colorOf(r: f64, g: f64, b: f64) geom.Color {
    return .{ .r = channel(r), .g = channel(g), .b = channel(b) };
}

fn channel(v: f64) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}

test "appkit: the components of an NSColor become an 8-bit color" {
    // The blue accent of macOS in sRGB.
    const c = colorOf(0.0, 0.478, 1.0);
    try std.testing.expectEqual(@as(u8, 0), c.r);
    try std.testing.expectEqual(@as(u8, 122), c.g);
    try std.testing.expectEqual(@as(u8, 255), c.b);
    // An extended sRGB component past 1 stays in the range.
    try std.testing.expectEqual(@as(u8, 255), colorOf(1.2, -0.1, 0.5).r);
    try std.testing.expectEqual(@as(u8, 0), colorOf(1.2, -0.1, 0.5).g);
}
