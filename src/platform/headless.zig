//! The headless backend. It keeps windows, a clock, and an event queue
//! in memory. A test moves the clock and adds input with the control
//! functions. The pointer state (position and buttons) lives here, so
//! each event has the position and the button bits as X11 gives them.
//! The mods of an event have the buttons that were down before the event.
//! `poll` gives the queued events, and then one `frame` event for each
//! window that asked for a frame.
//!
//! The backend has popup surfaces and native menus for the tests. A popup
//! is a window with its `Popup` options in its record. The screen of a
//! popup is the toplevel window at the root of its chain, at 0,0. A popup
//! that ends past the screen on the side of its anchor flips to the other
//! side when it fits there, and then slides into the screen. The native menus
//! are off until a test sets `native_menus`. Then each menu call adds one
//! line of text to `menu_log`. `menuAction` calls the menu handler of the
//! core or queues a `menu` event, and `appCommand` queues an `app_command`.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const geom = @import("../geom.zig");
const event = @import("../event.zig");
const keysym = @import("../keysym.zig");
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

/// What the render thread owns for one window: its copy of the atlas and the image.
const Surface = struct {
    host: *Headless,
    atlas: Atlas,
    image: ?Image = null,
    popup: bool = false,
};

const WinRec = struct { win: *Window, frame_wanted: bool = false, surface: *Surface, popup: ?plat.Popup = null };

pub const Headless = struct {
    gpa: std.mem.Allocator,
    now_us: i64 = 0,
    queue: std.ArrayListUnmanaged(Event) = .empty,
    windows: std.ArrayListUnmanaged(WinRec) = .empty,
    px: f32 = 0,
    py: f32 = 0,
    buttons: u8 = 0,
    mods: Mods = .{},
    /// Counts of calls, for the tests.
    frames_requested: u32 = 0,
    frames_drawn: u32 = 0,
    /// Counts the atlas patches that the draws applied, so a page knows when to upload the atlas again.
    patches_applied: u32 = 0,
    /// True: `draw` counts the frame and skips the CPU draw, for the benchmark.
    skip_draw: bool = false,
    /// True: a popup draws with the CPU also with `skip_draw`. The web page
    /// shows the image of a popup in a 2D canvas.
    draw_popups: bool = false,
    /// Milliseconds that a draw waits before it reads the surface. A test uses it
    /// to hold the render thread inside a draw.
    draw_delay_ms: u32 = 0,
    /// Counts the draws that started, for a test of a frame in flight.
    draws_started: std.atomic.Value(u32) = .init(0),
    /// The last pointer shape that the core set, and the count of the calls.
    cursor: ?plat.Cursor = null,
    cursor_calls: u32 = 0,
    /// The text of the last `clipboardSet`, and a text that a test puts on the
    /// clipboard in the place of another program. A set clears `clip_foreign`.
    clip_set: std.ArrayListUnmanaged(u8) = .empty,
    clip_foreign: ?[]const u8 = null,
    /// The last call of `textInput`, and the count of the calls.
    ime_on: bool = false,
    ime_rect: geom.Rect = .{},
    ime_calls: u32 = 0,
    /// The appearance of the system that a test sets. Null: light, with no accent.
    system: ?plat.Appearance = null,
    /// The trays: the last call of `traySet` for each, and the count of the ids.
    trays: std.ArrayListUnmanaged(TrayRec) = .empty,
    tray_next: u32 = 1,
    /// The file dialog: the paths that the next dialog gives (null: a cancel),
    /// the filter that it gives, and the options of the last call.
    dialog_answer: ?[]const []const u8 = null,
    dialog_filter: ?u32 = null,
    dialog_kind: ?plat.FileDialog.Kind = null,
    dialog_title: std.ArrayListUnmanaged(u8) = .empty,
    dialog_filters: usize = 0,
    dialog_multiple: bool = false,
    dialog_ext: [16]u8 = @splat(0),
    /// The last state of `taskbarSet`, and the count and the last kind of
    /// `attention`.
    taskbar: plat.Taskbar = .{},
    attentions: u32 = 0,
    attention_critical: bool = false,
    /// The texts of the input method events in the queue, freed at the next `poll`.
    ime_texts: std.ArrayListUnmanaged([]u8) = .empty,
    ime_texts_old: std.ArrayListUnmanaged([]u8) = .empty,
    /// True: the platform of the backend has native menus. A test sets it before `platform`.
    native_menus: bool = false,
    /// True: the platform of the backend has popup surfaces. The web build
    /// clears it before `platform`, because its page draws one canvas.
    popups: bool = true,
    /// The screen of the popups in the coordinates of the window of ".".
    /// Null: that window. The web build sets the viewport of the page.
    screen: ?geom.Rect = null,
    /// One line for each menu call, for example "set 3 [command Open Ctrl+O]".
    menu_log: std.ArrayListUnmanaged(u8) = .empty,
    /// The handler of the core for `opening` and `select`, from `setMenuHandler`.
    menu_handler: ?plat.MenuHandler = null,

    pub fn init(gpa: std.mem.Allocator) !*Headless {
        const h = try gpa.create(Headless);
        h.* = .{ .gpa = gpa };
        return h;
    }

    pub fn platform(h: *Headless) Platform {
        return .{ .ptr = h, .vtable = &vtable, .thread_safe_draw = true, .native_menus = h.native_menus, .popups = h.popups };
    }

    pub fn deinit(h: *Headless) void {
        for (h.windows.items) |r| {
            freeSurface(h, r.surface);
            h.gpa.destroy(r.win);
        }
        h.windows.deinit(h.gpa);
        h.queue.deinit(h.gpa);
        h.clip_set.deinit(h.gpa);
        for (h.trays.items) |*r| r.tooltip.deinit(h.gpa);
        h.trays.deinit(h.gpa);
        h.dialog_title.deinit(h.gpa);
        h.freeTexts(&h.ime_texts);
        h.freeTexts(&h.ime_texts_old);
        h.ime_texts.deinit(h.gpa);
        h.ime_texts_old.deinit(h.gpa);
        h.menu_log.deinit(h.gpa);
        h.gpa.destroy(h);
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
        .setTimeUs = vSetTime,
        .setCursor = vSetCursor,
        .clipboardSet = vClipboardSet,
        .clipboardGet = vClipboardGet,
        .textInput = vTextInput,
        .appearance = vAppearance,
        .fileDialog = vFileDialog,
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
        .taskbarSet = vTaskbarSet,
        .attention = vAttention,
    };

    pub const TrayRec = struct { id: plat.TrayId, width: u32 = 0, template: bool = false, tooltip: std.ArrayListUnmanaged(u8) = .empty, menu: plat.MenuId = 0 };

    fn vTrayCreate(ptr: *anyopaque, _: *Window, icon: plat.TrayIcon, template: bool, _: []const u8) plat.TrayId {
        const h = self(ptr);
        const id = h.tray_next;
        h.trays.append(h.gpa, .{ .id = id, .width = icon.width, .template = template }) catch return 0;
        h.tray_next += 1;
        return id;
    }

    fn vTraySet(ptr: *anyopaque, id: plat.TrayId, icon: plat.TrayIcon, template: bool, tooltip: []const u8, m: plat.MenuId) void {
        const h = self(ptr);
        const r = h.tray(id) orelse return;
        r.width = icon.width;
        r.template = template;
        r.menu = m;
        r.tooltip.clearRetainingCapacity();
        r.tooltip.appendSlice(h.gpa, tooltip) catch {};
    }

    fn vTrayDrop(ptr: *anyopaque, id: plat.TrayId) void {
        const h = self(ptr);
        for (h.trays.items, 0..) |*r, i| if (r.id == id) {
            r.tooltip.deinit(h.gpa);
            _ = h.trays.orderedRemove(i);
            return;
        };
    }

    /// The record of a tray, or null after its drop.
    fn vTaskbarSet(ptr: *anyopaque, _: *Window, state: plat.Taskbar) void {
        self(ptr).taskbar = state;
    }

    fn vAttention(ptr: *anyopaque, _: *Window, critical: bool) void {
        const h = self(ptr);
        h.attentions += 1;
        h.attention_critical = critical;
    }

    pub fn tray(h: *Headless, id: plat.TrayId) ?*TrayRec {
        for (h.trays.items) |*r| if (r.id == id) return r;
        return null;
    }

    /// Queues an action of the user on a tray.
    pub fn trayAction(h: *Headless, w: *Window, id: plat.TrayId, action: event.TrayAction) void {
        h.push(.{ .tray = .{ .window = w, .id = id, .action = action } });
    }

    fn vSetMenuHandler(ptr: *anyopaque, mh: plat.MenuHandler) void {
        self(ptr).menu_handler = mh;
    }

    fn logf(h: *Headless, comptime fmt: []const u8, args: anytype) void {
        h.menu_log.print(h.gpa, fmt, args) catch {};
    }

    fn logEntry(h: *Headless, e: *const plat.MenuEntry) void {
        h.logf(" [{s}", .{@tagName(e.kind)});
        if (e.label.len > 0) h.logf(" {s}", .{e.label});
        if (e.accelerator.len > 0) h.logf(" {s}", .{e.accelerator});
        if (e.underline >= 0) h.logf(" u{d}", .{e.underline});
        if (!e.enabled) h.logf(" disabled", .{});
        if (e.selected) h.logf(" on", .{});
        if (e.submenu != 0) h.logf(" ->{d}", .{e.submenu});
        if (e.column_break) h.logf(" break", .{});
        h.logf("]", .{});
    }

    fn vMenuSet(ptr: *anyopaque, m: *const plat.Menu) void {
        const h = self(ptr);
        h.logf("set {d}", .{m.id});
        if (m.title.len > 0) h.logf(" \"{s}\"", .{m.title});
        if (m.role != .none) h.logf(" role={s}", .{@tagName(m.role)});
        for (m.entries) |*e| h.logEntry(e);
        h.logf("\n", .{});
    }

    fn vMenuEntrySet(ptr: *anyopaque, id: plat.MenuId, index: u32, e: *const plat.MenuEntry) void {
        const h = self(ptr);
        h.logf("entry {d} {d}", .{ id, index });
        h.logEntry(e);
        h.logf("\n", .{});
    }

    fn vMenuDrop(ptr: *anyopaque, id: plat.MenuId) void {
        self(ptr).logf("drop {d}\n", .{id});
    }

    fn vSetMenuBar(ptr: *anyopaque, w: *Window, id: plat.MenuId) void {
        const h = self(ptr);
        h.logf("bar {d} {d}\n", .{ h.indexOf(w), id });
    }

    fn vPostMenu(ptr: *anyopaque, w: *Window, id: plat.MenuId, at: geom.Point, entry: i32) void {
        const h = self(ptr);
        h.logf("post {d} {d} {d} {d} {d}\n", .{ h.indexOf(w), id, at.x, at.y, entry });
    }

    fn vUnpostMenu(ptr: *anyopaque, id: plat.MenuId) void {
        self(ptr).logf("unpost {d}\n", .{id});
    }

    /// The index of a window in the list of windows, or -1.
    fn indexOf(h: *Headless, w: *Window) i64 {
        for (h.windows.items, 0..) |r, k| if (r.win == w) return @intCast(k);
        return -1;
    }

    /// Queues a command of the application menu with no window.
    pub fn appCommand(h: *Headless, cmd: event.AppCommand) void {
        h.queue.append(h.gpa, .{ .app_command = .{ .command = cmd } }) catch {};
    }

    /// The place of a window in the coordinates of the toplevel window at
    /// the root of its popup chain.
    pub fn absPos(h: *Headless, w: *const Window) geom.Point {
        for (h.windows.items) |r| if (r.win == w) {
            const p = r.popup orelse return .{};
            const o = h.absPos(p.parent);
            return .{ .x = o.x + w.pos.x, .y = o.y + w.pos.y };
        };
        return .{};
    }

    /// The screen of a popup chain in the coordinates of its root window:
    /// `screen`, or else the root window.
    fn screenOf(h: *Headless, w: *const Window) geom.Rect {
        for (h.windows.items) |r| if (r.win == w) {
            const p = r.popup orelse break;
            return h.screenOf(p.parent);
        };
        return h.screen orelse .{ .w = w.size.w, .h = w.size.h };
    }

    /// The place of a new popup in its parent: at its anchor, flipped
    /// and slid into the screen.
    fn place(h: *Headless, p: plat.Popup, surface: geom.Size) geom.Point {
        const mg = p.margin;
        const size: geom.Size = .{ .w = surface.w - mg.left - mg.right, .h = surface.h - mg.top - mg.bottom };
        const a = p.anchor;
        const o = p.offset;
        var x: i32 = undefined;
        var y: i32 = undefined;
        switch (p.side) {
            .below => {
                x = a.x + o.x;
                y = a.y + a.h + o.y;
            },
            .above => {
                x = a.x + o.x;
                y = a.y - size.h + o.y;
            },
            .right => {
                x = a.x + a.w + o.x;
                y = a.y + o.y;
            },
            .left => {
                x = a.x - size.w + o.x;
                y = a.y + o.y;
            },
        }
        const base = h.absPos(p.parent);
        const scr = h.screenOf(p.parent);
        const x0 = scr.x;
        const y0 = scr.y;
        const x1 = scr.x + scr.w;
        const y1 = scr.y + scr.h;
        // The flip mirrors the gap between the popup and the anchor.
        switch (p.side) {
            .below => if (base.y + y + size.h > y1) {
                const fy = a.y - (y - (a.y + a.h)) - size.h;
                if (base.y + fy >= y0) y = fy;
            },
            .above => if (base.y + y < y0) {
                const fy = a.y + a.h + (a.y - (y + size.h));
                if (base.y + fy + size.h <= y1) y = fy;
            },
            .right => if (base.x + x + size.w > x1) {
                const fx = a.x - (x - (a.x + a.w)) - size.w;
                if (base.x + fx >= x0) x = fx;
            },
            .left => if (base.x + x < x0) {
                const fx = a.x + a.w + (a.x - (x + size.w));
                if (base.x + fx + size.w <= x1) x = fx;
            },
        }
        x = std.math.clamp(base.x + x, x0, @max(x1 - size.w, x0)) - base.x;
        y = std.math.clamp(base.y + y, y0, @max(y1 - size.h, y0)) - base.y;
        return .{ .x = x - mg.left, .y = y - mg.top };
    }

    /// The image of a toplevel window with the images of its popups over
    /// it, at their places, as a screen shows them. The caller frees the pixels.
    pub fn composite(h: *Headless, gpa: std.mem.Allocator, w: *Window) !?Image {
        const base = h.image(w) orelse return null;
        const out: Image = .{ .width = base.width, .height = base.height, .pixels = try gpa.dupe(u8, base.pixels) };
        for (h.windows.items) |r| {
            if (r.popup == null or r.win == w) continue;
            const img = r.surface.image orelse continue;
            var root = r.win;
            while (h.popupOf(root)) |p| root = p.parent;
            if (root != w) continue;
            const o = h.absPos(r.win);
            const ox: i64 = @intFromFloat(@round(@as(f32, @floatFromInt(o.x)) * w.scale));
            const oy: i64 = @intFromFloat(@round(@as(f32, @floatFromInt(o.y)) * w.scale));
            var y: u32 = 0;
            while (y < img.height) : (y += 1) {
                const dy = oy + y;
                if (dy < 0 or dy >= out.height) continue;
                var x: u32 = 0;
                while (x < img.width) : (x += 1) {
                    const dx = ox + x;
                    if (dx < 0 or dx >= out.width) continue;
                    // Source over with the premultiplied alpha of the popup.
                    const s = img.pixels[(@as(usize, y) * img.width + x) * 4 ..][0..4];
                    const d = out.pixels[(@as(usize, @intCast(dy)) * out.width + @as(usize, @intCast(dx))) * 4 ..][0..4];
                    const ia: u32 = 255 - s[3];
                    for (0..4) |i| d[i] = @intCast(@min(255, @as(u32, s[i]) + (@as(u32, d[i]) * ia + 127) / 255));
                }
            }
        }
        return out;
    }

    /// The `Popup` options of a window, or null for a toplevel window.
    pub fn popupOf(h: *Headless, w: *Window) ?plat.Popup {
        for (h.windows.items) |r| if (r.win == w) return r.popup;
        return null;
    }

    /// Gives a user action in a native menu to the core, as a native
    /// backend does: `opening` and `select` go to the menu handler at once
    /// when the core set one, and the other actions are queued.
    pub fn menuAction(h: *Headless, w: *Window, id: plat.MenuId, entry: i32, action: event.MenuAction) void {
        if (action == .opening or action == .select) if (h.menu_handler) |mh| return mh.call(mh.ctx, id, entry, action);
        h.menuEvent(w, id, entry, action);
    }

    /// Queues a `menu` event, as a user action in a native menu gives it.
    pub fn menuEvent(h: *Headless, w: *Window, id: plat.MenuId, entry: i32, action: event.MenuAction) void {
        h.queue.append(h.gpa, .{ .menu = .{ .window = w, .menu = id, .entry = entry, .action = action } }) catch {};
    }

    fn vAppearance(ptr: *anyopaque) plat.Appearance {
        return self(ptr).system orelse .{ .dark = false };
    }

    /// Records the options of a dialog and gives the answer of the test.
    fn vFileDialog(ptr: *anyopaque, gpa: std.mem.Allocator, opts: *const plat.FileDialog) ?plat.FileDialogResult {
        const h = self(ptr);
        h.dialog_kind = opts.kind;
        h.dialog_title.clearRetainingCapacity();
        h.dialog_title.appendSlice(h.gpa, opts.title) catch {};
        h.dialog_filters = opts.filters.len;
        h.dialog_multiple = opts.multiple;
        h.dialog_ext = @splat(0);
        @memcpy(h.dialog_ext[0..@min(opts.default_ext.len, 16)], opts.default_ext[0..@min(opts.default_ext.len, 16)]);
        const answer = h.dialog_answer orelse return null;
        const paths = gpa.alloc([]u8, answer.len) catch return null;
        for (answer, paths) |s, *p| p.* = gpa.dupe(u8, s) catch return null;
        return .{ .paths = paths, .filter = h.dialog_filter };
    }

    /// Sets the appearance of the system and queues the event of the change.
    pub fn setAppearance(h: *Headless, w: *Window, a: plat.Appearance) void {
        h.system = a;
        h.push(.{ .appearance = .{ .window = w } });
    }

    fn vTextInput(ptr: *anyopaque, _: *Window, on: bool, rect: geom.Rect) void {
        const h = self(ptr);
        h.ime_on = on;
        h.ime_rect = rect;
        h.ime_calls += 1;
    }

    fn freeTexts(h: *Headless, list: *std.ArrayListUnmanaged([]u8)) void {
        for (list.items) |s| h.gpa.free(s);
        list.clearRetainingCapacity();
    }

    /// Queues a `preedit` event as an input method gives it.
    pub fn imePreedit(h: *Headless, w: *Window, text: []const u8, caret: u32) !void {
        const s = try h.gpa.dupe(u8, text);
        try h.ime_texts.append(h.gpa, s);
        h.push(.{ .preedit = .{ .window = w, .text = s, .caret = caret } });
    }

    /// Queues a `commit` event as an input method gives it.
    pub fn imeCommit(h: *Headless, w: *Window, text: []const u8) !void {
        const s = try h.gpa.dupe(u8, text);
        try h.ime_texts.append(h.gpa, s);
        h.push(.{ .commit = .{ .window = w, .text = s } });
    }

    fn vClipboardSet(ptr: *anyopaque, _: []const u8, data: []const u8) void {
        const h = self(ptr);
        h.clip_set.clearRetainingCapacity();
        h.clip_set.appendSlice(h.gpa, data) catch {};
        h.clip_foreign = null;
    }

    fn vClipboardGet(ptr: *anyopaque, gpa: std.mem.Allocator, _: []const u8) ?[]u8 {
        const text = self(ptr).clip_foreign orelse return null;
        return gpa.dupe(u8, text) catch null;
    }

    fn vSetCursor(ptr: *anyopaque, _: *Window, shape: plat.Cursor) void {
        const h = self(ptr);
        h.cursor = shape;
        h.cursor_calls += 1;
    }

    fn vSetTime(ptr: *anyopaque, us: i64) void {
        self(ptr).now_us = us;
    }

    fn self(ptr: *anyopaque) *Headless {
        return @ptrCast(@alignCast(ptr));
    }

    fn vDeinit(ptr: *anyopaque) void {
        self(ptr).deinit();
    }

    fn vCreateWindow(ptr: *anyopaque, opts: plat.WindowOptions) anyerror!*Window {
        const h = self(ptr);
        const w = try h.gpa.create(Window);
        errdefer h.gpa.destroy(w);
        w.* = .{ .size = opts.size };
        if (opts.popup) |p| {
            w.scale = p.parent.scale;
            w.pos = h.place(p, opts.size);
        }
        const surf = try h.gpa.create(Surface);
        errdefer h.gpa.destroy(surf);
        surf.* = .{ .host = h, .atlas = Atlas.init(h.gpa), .popup = opts.popup != null };
        try h.windows.append(h.gpa, .{ .win = w, .surface = surf, .popup = opts.popup });
        return w;
    }

    fn vDestroyWindow(ptr: *anyopaque, w: *Window) void {
        const h = self(ptr);
        var i: usize = 0;
        while (i < h.queue.items.len) {
            if (h.queue.items[i].window() == w) _ = h.queue.orderedRemove(i) else i += 1;
        }
        for (h.windows.items, 0..) |r, k| if (r.win == w) {
            freeSurface(h, r.surface);
            _ = h.windows.orderedRemove(k);
            break;
        };
        h.gpa.destroy(w);
    }

    fn vSetTitle(_: *anyopaque, _: *Window, _: []const u8) void {}

    fn vRequestSize(ptr: *anyopaque, w: *Window, size: geom.Size) void {
        self(ptr).resize(w, size);
    }

    fn vSetMinSize(_: *anyopaque, _: *Window, _: geom.Size) void {}

    fn vRequestFrame(ptr: *anyopaque, w: *Window) void {
        const h = self(ptr);
        h.frames_requested += 1;
        for (h.windows.items) |*r| if (r.win == w) {
            r.frame_wanted = true;
        };
    }

    fn pending(h: *const Headless) bool {
        if (h.queue.items.len > 0) return true;
        for (h.windows.items) |r| if (r.frame_wanted) return true;
        return false;
    }

    fn vWait(ptr: *anyopaque, timeout_us: ?i64) void {
        const h = self(ptr);
        if (h.pending()) return;
        if (timeout_us) |t| h.now_us += @max(t, 0);
    }

    fn vPoll(ptr: *anyopaque, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(Event)) anyerror!void {
        const h = self(ptr);
        // The texts of the last poll are done. The texts of this poll stay until the next one.
        h.freeTexts(&h.ime_texts_old);
        std.mem.swap(std.ArrayListUnmanaged([]u8), &h.ime_texts, &h.ime_texts_old);
        try out.appendSlice(gpa, h.queue.items);
        h.queue.clearRetainingCapacity();
        for (h.windows.items) |*r| if (r.frame_wanted) {
            r.frame_wanted = false;
            try out.append(gpa, .{ .frame = .{ .window = r.win, .time_us = h.now_us } });
        };
    }

    fn vNowUs(ptr: *anyopaque) i64 {
        return self(ptr).now_us;
    }

    fn freeSurface(h: *Headless, surf: *Surface) void {
        if (surf.image) |im| h.gpa.free(im.pixels);
        surf.atlas.deinit();
        h.gpa.destroy(surf);
    }

    /// The target of a window. It runs on the render thread: it applies the
    /// atlas patches to its own copy of the page and draws with the CPU renderer.
    fn vTarget(ptr: *anyopaque, w: *Window) Target {
        const h = self(ptr);
        for (h.windows.items) |r| if (r.win == w) return .{ .ctx = r.surface, .draw = drawFrame };
        unreachable;
    }

    fn drawFrame(ctx: *anyopaque, frame: *const Frame) anyerror!void {
        const surf: *Surface = @ptrCast(@alignCast(ctx));
        const h = surf.host;
        _ = h.draws_started.fetchAdd(1, .release);
        if (h.draw_delay_ms > 0) {
            @import("../sys/host.zig").sleepUs(@as(i64, h.draw_delay_ms) * 1000);
        }
        for (frame.patches.items) |p| try surf.atlas.applyPatch(p);
        h.patches_applied +%= @intCast(frame.patches.items.len);
        if (h.skip_draw and !(surf.popup and h.draw_popups)) {
            h.frames_drawn += 1;
            return;
        }
        const scene = &frame.scene;
        const need = @as(usize, scene.width) * scene.height * 4;
        if (surf.image == null or surf.image.?.pixels.len != need or surf.image.?.width != scene.width) {
            if (surf.image) |im| h.gpa.free(im.pixels);
            surf.image = null;
            surf.image = .{ .width = scene.width, .height = scene.height, .pixels = try h.gpa.alloc(u8, need) };
        }
        cpu.render(scene, &surf.atlas, &surf.image.?);
        h.frames_drawn += 1;
    }

    /// The last image drawn to the window.
    /// The atlas page of the surface of a window, as the render target has it.
    pub fn atlasPage(h: *Headless, w: *Window) ?[]const u8 {
        for (h.windows.items) |r| if (r.win == w) return r.surface.atlas.page();
        return null;
    }

    pub fn image(h: *Headless, w: *Window) ?Image {
        for (h.windows.items) |r| if (r.win == w) return r.surface.image;
        return null;
    }

    // ---- test controls ----

    fn push(h: *Headless, e: Event) void {
        h.queue.append(h.gpa, e) catch @panic("out of memory in the headless queue");
    }

    fn timeMs(h: *const Headless) u32 {
        return @truncate(@as(u64, @intCast(@max(h.now_us, 0))) / 1000);
    }

    fn currentMods(h: *const Headless) Mods {
        var m = h.mods;
        m.button1 = h.buttons & 1 != 0;
        m.button2 = h.buttons & 2 != 0;
        m.button3 = h.buttons & 4 != 0;
        m.button4 = h.buttons & 8 != 0;
        m.button5 = h.buttons & 16 != 0;
        return m;
    }

    /// Moves the clock.
    pub fn advance(h: *Headless, ms: i64) void {
        h.now_us += ms * 1000;
    }

    pub fn pointerMove(h: *Headless, w: *Window, x: f32, y: f32) void {
        h.px = x;
        h.py = y;
        h.push(.{ .motion = .{ .window = w, .x = x, .y = y, .mods = h.currentMods(), .time_ms = h.timeMs() } });
        w.feedPointer(x, y);
    }

    pub fn pointerButton(h: *Headless, w: *Window, button: u8, pressed: bool) void {
        const before = h.currentMods();
        h.push(.{ .button = .{ .window = w, .button = button, .pressed = pressed, .x = h.px, .y = h.py, .mods = before, .time_ms = h.timeMs() } });
        if (button >= 1 and button <= 5) {
            const bit: u8 = @as(u8, 1) << @intCast(button - 1);
            if (pressed) h.buttons |= bit else h.buttons &= ~bit;
        }
    }

    /// Moves the pointer, presses button 1, and releases it.
    pub fn click(h: *Headless, w: *Window, x: f32, y: f32) void {
        h.pointerMove(w, x, y);
        h.pointerButton(w, 1, true);
        h.pointerButton(w, 1, false);
    }

    /// A wheel or touchpad scroll at the pointer, in wheel steps: 1 is one
    /// step down (dy) or right (dx).
    pub fn pointerScroll(h: *Headless, w: *Window, dx: f32, dy: f32) void {
        h.push(.{ .scroll = .{ .window = w, .dx = dx, .dy = dy, .x = h.px, .y = h.py, .mods = h.currentMods(), .time_ms = h.timeMs() } });
    }

    pub fn pointerLeave(h: *Headless, w: *Window) void {
        h.push(.{ .leave = .{ .window = w } });
    }

    fn pushKey(h: *Headless, w: *Window, sym: u32, pressed: bool, text: []const u8, mods: Mods) void {
        var k: Event = .{ .key = .{
            .window = w,
            .keysym = sym,
            .keycode = sym,
            .pressed = pressed,
            .repeat = false,
            .mods = mods,
            .time_ms = h.timeMs(),
        } };
        const n = @min(text.len, k.key.text.len);
        @memcpy(k.key.text[0..n], text[0..n]);
        k.key.text_len = @intCast(n);
        h.push(k);
    }

    /// A key event by key symbol name. A printable key with no control
    /// or alt modifier gives its text.
    pub fn key(h: *Headless, w: *Window, name: []const u8, pressed: bool) !void {
        const sym = keysym.fromName(name) orelse return error.UnknownKeysym;
        const m = h.currentMods();
        var buf: [4]u8 = undefined;
        var text: []const u8 = "";
        if (pressed and sym >= 0x20 and sym < 0x7f and !m.control and !m.mod1) {
            buf[0] = @intCast(sym);
            text = buf[0..1];
        }
        h.pushKey(w, sym, pressed, text, m);
    }

    /// A key down and a key up.
    pub fn press(h: *Headless, w: *Window, name: []const u8) !void {
        try h.key(w, name, true);
        try h.key(w, name, false);
    }

    /// A press and a release for each character, with its key symbol and
    /// its UTF-8. A capital letter has the shift modifier.
    pub fn typeText(h: *Headless, w: *Window, utf8: []const u8) !void {
        var it = (try std.unicode.Utf8View.init(utf8)).iterator();
        while (it.nextCodepointSlice()) |s| {
            const cp = try std.unicode.utf8Decode(s);
            var m = h.currentMods();
            if (cp >= 'A' and cp <= 'Z') m.shift = true;
            const sym = keysym.fromCodepoint(cp);
            h.pushKey(w, sym, true, s, m);
            h.pushKey(w, sym, false, "", m);
        }
    }

    pub fn setMods(h: *Headless, mods: Mods) void {
        h.mods = mods;
    }

    pub fn resize(h: *Headless, w: *Window, size: geom.Size) void {
        w.size = size;
        h.push(.{ .resize = .{ .window = w, .size = size } });
    }

    pub fn setScale(h: *Headless, w: *Window, scale: f32) void {
        w.scale = scale;
        h.push(.{ .scale = .{ .window = w, .scale = scale } });
    }

    pub fn setFocused(h: *Headless, w: *Window, focused: bool) void {
        h.push(.{ .focus = .{ .window = w, .focused = focused } });
    }

    pub fn close(h: *Headless, w: *Window) void {
        h.push(.{ .close = .{ .window = w } });
    }
};
