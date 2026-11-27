//! From a backend `Event` to widget events. The pointer goes to the
//! widget under it. A press gives that widget the pointer until all
//! buttons are up, so `Motion` and `ButtonRelease` go to it. The state
//! bits `hover` and `pressed` follow the pointer. Several `motion` events
//! in a row for one window collapse to the last one. Each other event is
//! kept in order, so no key or button event is lost when a frame is slow.
//! The holder of the pointer is valid only while the backend reports a
//! button down. A motion or a press with no button down ends a hold whose
//! release never came.
//! `event generate` builds a widget event and delivers it at once.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const num = @import("base/num.zig");
const ztcl = @import("ztcl");
const bind = @import("bind.zig");
const grab = @import("grab.zig");
const event = @import("base/event.zig");
const keysym = @import("base/keysym.zig");
const widget_mod = @import("widget.zig");
const App = @import("app.zig").App;
const Widget = widget_mod.Widget;
const Cursor = @import("platform/platform.zig").Cursor;
const options = @import("options.zig");
const WidgetEvent = bind.WidgetEvent;
const Value = ztcl.Value;

/// The click that the count follows.
const Click = struct { button: u8 = 0, x: i32 = 0, y: i32 = 0, time_ms: u32 = 0, count: u8 = 0 };

pub const State = struct {
    /// The widget that has the hover bit.
    hover: ?*Widget = null,
    /// The widget that holds the pointer during a press.
    grab: ?*Widget = null,
    click: Click = .{},
    serial: u32 = 0,
    /// The pointer shape that the backend shows. Null before the first motion.
    cursor: ?Cursor = null,
    /// The window of that shape.
    cursor_win: ?*const anyopaque = null,
    /// The last position of the pointer, in the coordinates of its toplevel.
    pointer: struct { x: i32 = 0, y: i32 = 0 } = .{},

    /// A widget that is deleted must not stay in the state.
    pub fn forget(s: *State, w: *const Widget) void {
        if (s.hover == w) s.hover = null;
        if (s.grab == w) s.grab = null;
    }
};

/// The widget at a point of a toplevel: the top mapped widget that has it.
pub fn widgetAt(top: *Widget, x: i32, y: i32) *Widget {
    // The row of a drawn menu bar is the menu widget of the bar.
    if (@import("widgets/menudraw.zig").barAt(top, x, y)) |m| return m;
    var cur = top;
    var px = x;
    var py = y;
    while (true) {
        // A deep tree can have a sum of offsets beyond `i32`.
        if (cur != top) {
            px -|= cur.geom.x;
            py -|= cur.geom.y;
        }
        var found: ?*Widget = null;
        var i = cur.children.items.len;
        while (i > 0) {
            i -= 1;
            const c = cur.children.items[i];
            // A child toplevel is a window of its own.
            if (!c.mapped or c.isToplevel()) continue;
            if (px >= c.geom.x and py >= c.geom.y and px < c.geom.x +| c.geom.w and py < c.geom.y +| c.geom.h) {
                found = c;
                break;
            }
        }
        cur = found orelse return cur;
    }
}

fn rootOrigin(w: *const Widget) struct { x: i32, y: i32 } {
    var x: i32 = 0;
    var y: i32 = 0;
    var p: ?*const Widget = w;
    while (p) |n| : (p = n.parent) {
        if (n.parent == null or n.isToplevel()) break;
        x +|= n.geom.x;
        y +|= n.geom.y;
    }
    return .{ .x = x, .y = y };
}

pub fn nextSerial(app: *App) u32 {
    app.dispatch.serial += 1;
    return app.dispatch.serial;
}

fn setHover(app: *App, w: *Widget, on: bool) void {
    if (w.state.hover == on) return;
    w.state.hover = on;
    w.invalidate(.{ .style = true, .measure = false, .layout = false, .paint = true });
    _ = app;
}

fn setPressed(w: *Widget, on: bool) void {
    if (w.state.pressed == on) return;
    w.state.pressed = on;
    w.invalidate(.{ .style = true, .measure = false, .layout = false, .paint = true });
}

fn pointerEvent(app: *App, t: bind.EventType, w: *Widget, x: f32, y: f32, mods: event.Mods, time_ms: u32) WidgetEvent {
    const o = rootOrigin(w);
    const ix: i32 = num.pxFloor(x);
    const iy: i32 = num.pxFloor(y);
    app.dispatch.pointer = .{ .x = ix, .y = iy };
    return .{
        .type = t,
        .widget = w,
        .x = num.px(@as(i64, ix) - o.x),
        .y = num.px(@as(i64, iy) - o.y),
        .root_x = ix,
        .root_y = iy,
        .mods = mods,
        .time_ms = time_ms,
        .serial = nextSerial(app),
    };
}

/// Moves the hover to `under`: Leave for the old widget, Enter for the new one.
fn updateHover(app: *App, under: ?*Widget, x: f32, y: f32, mods: event.Mods, time_ms: u32) void {
    const d = &app.dispatch;
    if (d.hover == under) return;
    grab.hover(app, under);
    if (d.hover) |old| {
        d.hover = null;
        setHover(app, old, false);
        var ev = pointerEvent(app, .leave, old, x, y, mods, time_ms);
        bind.deliver(app, &ev);
    }
    if (under) |nw| {
        if (!nw.alive()) return;
        d.hover = nw;
        setHover(app, nw, true);
        var ev = pointerEvent(app, .enter, nw, x, y, mods, time_ms);
        bind.deliver(app, &ev);
    }
}

fn clickCount(app: *App, button: u8, x: i32, y: i32, time_ms: u32) u8 {
    const c = &app.dispatch.click;
    const dx = @abs(x - c.x);
    const dy = @abs(y - c.y);
    const near = c.button == button and dx <= 5 and dy <= 5 and time_ms >= c.time_ms and time_ms - c.time_ms <= 500;
    const count: u8 = if (near and c.count < 4) c.count + 1 else if (near) 4 else 1;
    c.* = .{ .button = button, .x = x, .y = y, .time_ms = time_ms, .count = count };
    return count;
}

fn buttonsDown(m: event.Mods) bool {
    return m.button1 or m.button2 or m.button3 or m.button4 or m.button5;
}

/// Ends a hold of the pointer whose button release never arrived.
fn dropStaleGrab(app: *App, mods: event.Mods) void {
    if (buttonsDown(mods)) return;
    const g = app.dispatch.grab orelse return;
    app.dispatch.grab = null;
    if (g.alive()) setPressed(g, false);
}

/// The pointer shape over a widget: the shape of the part under the
/// pointer from the class, then the first `-cursor` option that is set
/// on the widget or an ancestor, as in Tk, and else the `cursor` style of
/// the widget.
pub fn cursorOf(w: *const Widget) Cursor {
    if (w.class.cursor) |f| if (f(w)) |shape| return shape;
    var cur: ?*const Widget = w;
    while (cur) |c| : (cur = c.parent) {
        const slot = options.maybe(c, "-cursor") orelse continue;
        const name = switch (slot.value) {
            .text => |s| s,
            else => slot.text,
        };
        if (name.len > 0) if (Cursor.fromTk(name)) |shape| return shape;
    }
    return Cursor.fromCss(w.style.cursor);
}

/// Gives the backend the shape of the widget that holds or has the pointer, when it changed.
fn syncCursor(app: *App, root: *Widget) void {
    const d = &app.dispatch;
    const shape: Cursor = if (d.grab orelse d.hover) |w| (if (w.alive()) cursorOf(w) else .default) else .default;
    const win = app.winOf(root) orelse return;
    if (d.cursor) |c| if (c == shape and d.cursor_win == @as(*const anyopaque, win)) return;
    d.cursor = shape;
    d.cursor_win = win;
    app.platform.setCursor(win, shape);
}

/// Turns one backend event of the window of "." into widget events and delivers them.
pub fn handle(app: *App, ev: event.Event) void {
    const root = app.root orelse return;
    handleIn(app, ev, root);
}

/// Turns one backend event of the window of a toplevel into widget events and delivers them.
pub fn handleIn(app: *App, ev: event.Event, root: *Widget) void {
    const d = &app.dispatch;
    defer if (ev == .motion or ev == .leave) syncCursor(app, root);
    switch (ev) {
        .motion => |m| {
            dropStaleGrab(app, m.mods);
            if (d.grab) |g| {
                if (!g.alive()) {
                    d.grab = null;
                } else {
                    const under = grab.redirect(app, widgetAt(root, num.pxFloor(m.x), num.pxFloor(m.y)));
                    // The grabbing widget gets Leave and Enter, and no other widget does.
                    if ((under == g) != g.state.hover) {
                        if (under == g) {
                            d.hover = g;
                            setHover(app, g, true);
                            setPressed(g, m.mods.button1);
                            var e1 = pointerEvent(app, .enter, g, m.x, m.y, m.mods, m.time_ms);
                            bind.deliver(app, &e1);
                        } else {
                            if (d.hover == g) d.hover = null;
                            setHover(app, g, false);
                            setPressed(g, false);
                            var e1 = pointerEvent(app, .leave, g, m.x, m.y, m.mods, m.time_ms);
                            bind.deliver(app, &e1);
                        }
                    }
                    if (!g.alive()) return;
                    var e2 = pointerEvent(app, .motion, g, m.x, m.y, m.mods, m.time_ms);
                    bind.deliver(app, &e2);
                    return;
                }
            }
            const under = grab.redirect(app, widgetAt(root, num.pxFloor(m.x), num.pxFloor(m.y)));
            updateHover(app, under, m.x, m.y, m.mods, m.time_ms);
            if (!under.alive()) return;
            var e = pointerEvent(app, .motion, under, m.x, m.y, m.mods, m.time_ms);
            bind.deliver(app, &e);
        },
        .button => |b| {
            if (b.pressed) {
                grab.press(app);
                // The mods have the buttons that were down before this press.
                dropStaleGrab(app, b.mods);
                const under = grab.redirect(app, widgetAt(root, num.pxFloor(b.x), num.pxFloor(b.y)));
                if (d.grab == null) updateHover(app, under, b.x, b.y, b.mods, b.time_ms);
                const target = d.grab orelse under;
                if (!target.alive()) return;
                if (d.grab == null) d.grab = target;
                if (b.button == 1 and !target.state.pressed) {
                    target.state.pressed = true;
                    target.invalidate(.{ .style = true, .measure = false, .layout = false, .paint = true });
                }
                var e = pointerEvent(app, .button_press, target, b.x, b.y, b.mods, b.time_ms);
                e.button = b.button;
                e.count = clickCount(app, b.button, e.root_x, e.root_y, b.time_ms);
                bind.deliver(app, &e);
            } else {
                const target = d.grab orelse grab.redirect(app, widgetAt(root, num.pxFloor(b.x), num.pxFloor(b.y)));
                if (target.alive()) {
                    var e = pointerEvent(app, .button_release, target, b.x, b.y, b.mods, b.time_ms);
                    e.button = b.button;
                    e.count = d.click.count;
                    if (b.button == 1 and target.state.pressed) {
                        target.state.pressed = false;
                        target.invalidate(.{ .style = true, .measure = false, .layout = false, .paint = true });
                    }
                    bind.deliver(app, &e);
                }
                // The event mods have the buttons that were down before the event.
                var rest = b.mods;
                switch (b.button) {
                    1 => rest.button1 = false,
                    2 => rest.button2 = false,
                    3 => rest.button3 = false,
                    4 => rest.button4 = false,
                    5 => rest.button5 = false,
                    else => {},
                }
                if (!buttonsDown(rest)) {
                    d.grab = null;
                    const under = grab.redirect(app, widgetAt(root, num.pxFloor(b.x), num.pxFloor(b.y)));
                    updateHover(app, under, b.x, b.y, rest, b.time_ms);
                }
            }
        },
        .scroll => |sc| {
            // A wheel event goes to the widget under the pointer, or to the grab.
            const target = d.grab orelse grab.redirect(app, widgetAt(root, num.pxFloor(sc.x), num.pxFloor(sc.y)));
            if (!target.alive()) return;
            // A vertical step and a horizontal step are two events. A
            // horizontal step is Shift with the wheel, as in Tk 8.7.
            const steps = [2]f32{ sc.dy, sc.dx };
            for (steps, 0..) |s, i| {
                if (s == 0 or !target.alive()) continue;
                var e = pointerEvent(app, .mouse_wheel, target, sc.x, sc.y, sc.mods, sc.time_ms);
                if (i == 1) e.mods.shift = true;
                e.delta = -s * 120;
                bind.deliver(app, &e);
            }
        },
        .leave => {
            if (d.grab != null) return;
            updateHover(app, null, 0, 0, .{}, 0);
        },
        .key => |k| {
            const target = app.keyTarget() orelse root;
            var e: WidgetEvent = .{
                .type = if (k.pressed) .key_press else .key_release,
                .widget = target,
                .keysym = k.keysym,
                .keycode = k.keycode,
                .text = k.text[0..k.text_len],
                .mods = k.mods,
                .time_ms = k.time_ms,
                .serial = nextSerial(app),
            };
            bind.deliver(app, &e);
        },
        .commit => |c| {
            // Each character of the text is a press and a release of its
            // keysym, as typed keys give, so the bindings of the entry insert it.
            @import("textinput.zig").setPreedit(app, "", 0);
            var it = std.unicode.Utf8View.init(c.text) catch return;
            var cps = it.iterator();
            while (cps.nextCodepointSlice()) |s| {
                const cp = std.unicode.utf8Decode(s) catch continue;
                var k: event.Event = .{ .key = .{ .window = c.window, .keysym = keysym.fromCodepoint(cp), .keycode = 0, .pressed = true, .repeat = false, .mods = .{}, .time_ms = 0 } };
                @memcpy(k.key.text[0..s.len], s);
                k.key.text_len = @intCast(s.len);
                handleIn(app, k, root);
                k.key.pressed = false;
                k.key.text_len = 0;
                handleIn(app, k, root);
            }
        },
        .preedit => |p| @import("textinput.zig").setPreedit(app, p.text, p.caret),
        else => {},
    }
}

/// Drops each `motion` event at or after `start` that another `motion`
/// event of the same window follows with no other event between them.
pub fn collapse(list: *std.ArrayListUnmanaged(event.Event), start: usize) void {
    var out: usize = start;
    var i: usize = start;
    while (i < list.items.len) : (i += 1) {
        const cur = list.items[i];
        if (cur == .motion and i + 1 < list.items.len) {
            const next = list.items[i + 1];
            if (next == .motion and next.motion.window == cur.motion.window) continue;
        }
        list.items[out] = cur;
        out += 1;
    }
    list.shrinkRetainingCapacity(out);
}

// ---- event generate ----

const gen_options = [_][]const u8{ "-when", "-above", "-borderwidth", "-button", "-count", "-data", "-delta", "-detail", "-focus", "-height", "-keycode", "-keysym", "-mode", "-override", "-place", "-root", "-rootx", "-rooty", "-sendevent", "-serial", "-state", "-subwindow", "-time", "-warp", "-width", "-window", "-x", "-y" };
const gen_list = "-when, -above, -borderwidth, -button, -count, -data, -delta, -detail, -focus, -height, -keycode, -keysym, -mode, -override, -place, -root, -rootx, -rooty, -sendevent, -serial, -state, -subwindow, -time, -warp, -width, -window, -x, or -y";

fn genOption(name: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (gen_options) |o| {
        if (std.mem.eql(u8, o, name)) return o;
        if (std.mem.startsWith(u8, o, name)) {
            if (found != null) return null;
            found = o;
        }
    }
    return found;
}

/// `event add|delete|info`: the sequences of the virtual events. A
/// sequence is one event pattern, as in `bind`.
fn virtualCmd(app: *App, it: *ztcl.Interp, sub: []const u8, args: []const Value) ztcl.Error!Value {
    const gpa = app.gpa;
    const a = it.alloc();
    const list = &app.virtual_events;
    if (std.mem.eql(u8, sub, "info")) {
        if (args.len > 1) return it.wrongArgs("event info ?<<virtual>>?");
        var out: std.ArrayListUnmanaged(Value) = .empty;
        if (args.len == 0) {
            for (list.items) |d| {
                var seen = false;
                for (out.items) |v| if (std.mem.eql(u8, v.str[2 .. v.str.len - 2], d.name)) {
                    seen = true;
                };
                if (!seen) try out.append(a, .{ .str = try std.fmt.allocPrint(a, "<<{s}>>", .{d.name}) });
            }
        } else {
            const name = try virtualName(it, try it.str(args[0]));
            for (list.items) |d| if (std.mem.eql(u8, d.name, name)) try out.append(a, .{ .str = try a.dupe(u8, d.text) });
        }
        return ztcl.value.wrapList(a, out.items);
    }
    if (args.len < 1) return it.fail("wrong # args: should be \"event {s} virtual ?sequence ...?\"", .{sub});
    const name = try virtualName(it, try it.str(args[0]));
    if (std.mem.eql(u8, sub, "delete")) {
        var k: usize = 0;
        while (k < list.items.len) {
            const d = list.items[k];
            var hit = std.mem.eql(u8, d.name, name);
            if (hit and args.len > 1) {
                hit = false;
                for (args[1..]) |v| {
                    var buf: [128]u8 = undefined;
                    const text = bind.formatPattern(try bind.parsePattern(it, try it.str(v)), &buf);
                    if (std.mem.eql(u8, text, d.text)) hit = true;
                }
            }
            if (hit) {
                bind.freeVirtual(gpa, d);
                _ = list.orderedRemove(k);
            } else k += 1;
        }
        return Value.empty;
    }
    if (args.len < 2) return it.wrongArgs("event add <<virtual>> sequence ?sequence ...?");
    for (args[1..]) |v| {
        // `event info` gives each sequence in the form of `bind`, as in wish: <1> is <Button-1>.
        const pat = try bind.parsePattern(it, try it.str(v));
        var buf: [128]u8 = undefined;
        const text = bind.formatPattern(pat, &buf);
        if (pat.type == .virtual) return it.fail("virtual event not allowed in definition of another virtual event", .{});
        var dup = false;
        for (list.items) |d| if (std.mem.eql(u8, d.name, name) and std.mem.eql(u8, d.text, text)) {
            dup = true;
        };
        if (dup) continue;
        const n = try gpa.dupe(u8, name);
        errdefer gpa.free(n);
        const t = try gpa.dupe(u8, text);
        errdefer gpa.free(t);
        var p = pat;
        p.virtual = "";
        try list.append(gpa, .{ .name = n, .pattern = p, .text = t });
    }
    return Value.empty;
}

fn virtualName(it: *ztcl.Interp, text: []const u8) ztcl.Error![]const u8 {
    if (text.len < 5 or !std.mem.startsWith(u8, text, "<<") or !std.mem.endsWith(u8, text, ">>"))
        return it.fail("virtual event \"{s}\" is badly formed", .{text});
    return text[2 .. text.len - 2];
}

/// `event option ?arg ...?`: generate, and the virtual events of
/// `virtualCmd`.
pub fn cmdEvent(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    app.enter();
    defer app.leave();
    if (argv.len < 2) return it.wrongArgs("event option ?arg1 arg2 ...?");
    const sub = try it.str(argv[1]);
    if (std.mem.eql(u8, sub, "add") or std.mem.eql(u8, sub, "delete") or std.mem.eql(u8, sub, "info")) {
        return virtualCmd(app, it, sub, argv[2..]);
    }
    if (!std.mem.eql(u8, sub, "generate")) return it.fail("bad option \"{s}\": must be add, delete, generate, or info", .{sub});
    if (argv.len < 4) return it.fail("wrong # args: should be \"event generate window event ?-option value ...?\"", .{});
    const path = try it.str(argv[2]);
    const w = app.lookup(path) orelse return it.fail("bad window path name \"{s}\"", .{path});
    // `wish` delivers no event to a widget that is being deleted.
    if (!w.alive()) return Value.empty;
    const ptext = try it.str(argv[3]);
    const pat = bind.parsePattern(it, ptext) catch |e| {
        if (e == error.TclError) {
            const msg = try it.str(it.result);
            if (std.mem.startsWith(u8, msg, "event sequences are not supported")) return it.fail("only one event specification allowed", .{});
        }
        return e;
    };
    if (pat.count > 1) return it.fail("Double, Triple, or Quadruple modifier not allowed", .{});
    var ev: WidgetEvent = .{ .type = pat.type, .widget = w, .mods = pat.mods, .virtual = pat.virtual, .serial = nextSerial(app) };
    if (pat.type == .key_press or pat.type == .key_release) ev.keysym = pat.detail;
    if (pat.type == .button_press or pat.type == .button_release) ev.button = std.math.cast(u8, pat.detail) orelse 0;
    var state_bits: ?u16 = null;
    var i: usize = 4;
    while (i < argv.len) : (i += 1) {
        const name = try it.str(argv[i]);
        const opt = genOption(name) orelse return it.fail("bad option \"{s}\": must be " ++ gen_list, .{name});
        if (i + 1 >= argv.len) return it.fail("value for \"{s}\" missing", .{name});
        i += 1;
        const val = try it.str(argv[i]);
        if (std.mem.eql(u8, opt, "-x")) {
            ev.x = num.px(try it.int(argv[i]));
        } else if (std.mem.eql(u8, opt, "-y")) {
            ev.y = num.px(try it.int(argv[i]));
        } else if (std.mem.eql(u8, opt, "-rootx")) {
            ev.root_x = num.px(try it.int(argv[i]));
        } else if (std.mem.eql(u8, opt, "-rooty")) {
            ev.root_y = num.px(try it.int(argv[i]));
        } else if (std.mem.eql(u8, opt, "-button")) {
            ev.button = @intCast(std.math.clamp(try it.int(argv[i]), 0, 255));
        } else if (std.mem.eql(u8, opt, "-keycode")) {
            ev.keycode = @intCast(std.math.clamp(try it.int(argv[i]), 0, 1 << 30));
        } else if (std.mem.eql(u8, opt, "-keysym")) {
            ev.keysym = keysym.fromName(val) orelse blk: {
                if (val.len > 0) {
                    const view = std.unicode.Utf8View.init(val) catch break :blk 0;
                    var cps = view.iterator();
                    if (cps.nextCodepoint()) |cp| break :blk keysym.fromCodepoint(cp);
                }
                break :blk 0;
            };
        } else if (std.mem.eql(u8, opt, "-state")) {
            state_bits = @intCast(std.math.clamp(try it.int(argv[i]), 0, 0xffff));
        } else if (std.mem.eql(u8, opt, "-time")) {
            ev.time_ms = @intCast(std.math.clamp(try it.int(argv[i]), 0, std.math.maxInt(u32)));
        } else if (std.mem.eql(u8, opt, "-data")) {
            ev.data = try it.alloc().dupe(u8, val);
        } else if (std.mem.eql(u8, opt, "-delta")) {
            ev.delta = @floatCast(std.fmt.parseFloat(f64, val) catch return it.fail("expected integer but got \"{s}\"", .{val}));
        } else if (std.mem.eql(u8, opt, "-width")) {
            ev.width = num.px(try it.int(argv[i]));
        } else if (std.mem.eql(u8, opt, "-height")) {
            ev.height = num.px(try it.int(argv[i]));
        } else if (std.mem.eql(u8, opt, "-when")) {
            if (!std.mem.eql(u8, val, "now")) {
                if (std.mem.eql(u8, val, "head") or std.mem.eql(u8, val, "mark") or std.mem.eql(u8, val, "tail")) {
                    return it.fail("event generate option \"-when {s}\" is not supported in this stage", .{val});
                }
                return it.fail("bad -when value \"{s}\": must be now, head, mark, or tail", .{val});
            }
        } else {
            return it.fail("event generate option \"{s}\" is not supported in this stage", .{opt});
        }
    }
    if (state_bits) |s| {
        const given: event.Mods = @bitCast(s);
        ev.mods = @bitCast(@as(u16, @bitCast(given)) | @as(u16, @bitCast(ev.mods)));
    }
    if ((ev.type == .key_press or ev.type == .key_release) and ev.keysym >= 0x20 and ev.keysym < 0x7f) {
        const ch = try it.alloc().alloc(u8, 1);
        ch[0] = @intCast(ev.keysym);
        ev.text = ch;
    }
    if (ev.type == .button_press or ev.type == .button_release or ev.type == .key_press or ev.type == .key_release) {
        ev.count = if (ev.type == .button_press) clickCount(app, ev.button, ev.x, ev.y, ev.time_ms) else app.dispatch.click.count;
        if (ev.count == 0) ev.count = 1;
    }
    bind.deliver(app, &ev);
    return Value.empty;
}
