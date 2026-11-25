//! The headless backend. It keeps windows, a clock, and an event queue
//! in memory. A test moves the clock and adds input with the control
//! functions. The pointer state (position and buttons) lives here, so
//! each event has the position and the button bits as X11 gives them.
//! The mods of an event have the buttons that were down before the event.
//! `poll` gives the queued events, and then one `frame` event for each
//! window that asked for a frame.
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
};

const WinRec = struct { win: *Window, frame_wanted: bool = false, surface: *Surface };

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
    /// The texts of the input method events in the queue, freed at the next `poll`.
    ime_texts: std.ArrayListUnmanaged([]u8) = .empty,
    ime_texts_old: std.ArrayListUnmanaged([]u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) !*Headless {
        const h = try gpa.create(Headless);
        h.* = .{ .gpa = gpa };
        return h;
    }

    pub fn platform(h: *Headless) Platform {
        return .{ .ptr = h, .vtable = &vtable, .thread_safe_draw = true };
    }

    pub fn deinit(h: *Headless) void {
        for (h.windows.items) |r| {
            freeSurface(h, r.surface);
            h.gpa.destroy(r.win);
        }
        h.windows.deinit(h.gpa);
        h.queue.deinit(h.gpa);
        h.clip_set.deinit(h.gpa);
        h.freeTexts(&h.ime_texts);
        h.freeTexts(&h.ime_texts_old);
        h.ime_texts.deinit(h.gpa);
        h.ime_texts_old.deinit(h.gpa);
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
    };

    fn vAppearance(ptr: *anyopaque) plat.Appearance {
        return self(ptr).system orelse .{ .dark = false };
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
        const surf = try h.gpa.create(Surface);
        errdefer h.gpa.destroy(surf);
        surf.* = .{ .host = h, .atlas = Atlas.init(h.gpa) };
        try h.windows.append(h.gpa, .{ .win = w, .surface = surf });
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
        if (h.skip_draw) {
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
