//! `grab` and `ztk::tooltip`. A grab keeps the pointer in one widget
//! tree of the program: a pointer event whose widget is outside the tree
//! goes to the grab widget. ztk has local grabs only. `-global` is
//! accepted and gives a local grab, because a program cannot take the
//! pointer of other programs on Wayland. A tooltip is a short text that
//! shows below a widget after the pointer rests on it for 600 ms. It is
//! drawn in the window of the widget, over the other widgets, and fades
//! in. A press or a leave hides it.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const num = @import("num.zig");
const geom = @import("geom.zig");
const widget = @import("widget.zig");
const paint = @import("paint.zig");
const scene = @import("scene.zig");
const anim = @import("anim.zig");
const App = @import("app.zig").App;
const Widget = widget.Widget;
const Value = ztcl.Value;

pub const State = struct {
    widget: ?*Widget = null,
    global: bool = false,
};

/// The widget that gets a pointer event at `w` while a grab is on.
pub fn redirect(app: *App, w: *Widget) *Widget {
    const g = app.grab.widget orelse return w;
    if (!g.alive()) {
        app.grab.widget = null;
        return w;
    }
    var x: ?*Widget = w;
    while (x) |p| : (x = p.parent) if (p == g) return w;
    return g;
}

pub fn forget(app: *App, w: *const Widget) void {
    if (app.grab.widget == w) app.grab.widget = null;
    if (app.tip.widget == w) app.tip.widget = null;
}

fn findWidget(it: *ztcl.Interp, app: *App, path: []const u8) ztcl.Error!*Widget {
    return app.find(path) orelse it.fail("bad window path name \"{s}\"", .{path});
}

/// `grab ?-global? window` and `grab current|release|set|status ...`
pub fn cmdGrab(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    app.enter();
    defer app.leave();
    const usage = "wrong # args: should be \"grab ?-global? window\" or \"grab option ?arg ...?\"";
    if (argv.len < 2) return it.fail(usage, .{});
    const first = try it.str(argv[1]);
    if (first.len > 0 and first[0] == '.') {
        if (argv.len != 2) return it.fail(usage, .{});
        return set(app, try findWidget(it, app, first), false);
    }
    if (std.mem.eql(u8, first, "-global")) {
        if (argv.len != 3) return it.fail(usage, .{});
        return set(app, try findWidget(it, app, try it.str(argv[2])), true);
    }
    const subs = [_][]const u8{ "current", "release", "set", "status" };
    const which = for (subs, 0..) |s, i| {
        if (std.mem.eql(u8, s, first)) break i;
    } else return it.fail("bad option \"{s}\": must be current, release, set, or status", .{first});
    switch (which) {
        0 => {
            if (argv.len > 3) return it.wrongArgs("grab current ?window?");
            const g = app.grab.widget orelse return Value.empty;
            if (argv.len == 3) {
                const w = try findWidget(it, app, try it.str(argv[2]));
                if (w.toplevel() != g.toplevel()) return Value.empty;
            }
            return .{ .str = try it.alloc().dupe(u8, g.path) };
        },
        1 => {
            if (argv.len != 3) return it.wrongArgs("grab release window");
            const w = app.find(try it.str(argv[2])) orelse return Value.empty;
            if (app.grab.widget == w) app.grab.widget = null;
            return Value.empty;
        },
        2 => {
            if (argv.len == 4 and std.mem.eql(u8, try it.str(argv[2]), "-global")) return set(app, try findWidget(it, app, try it.str(argv[3])), true);
            if (argv.len != 3) return it.wrongArgs("grab set ?-global? window");
            return set(app, try findWidget(it, app, try it.str(argv[2])), false);
        },
        3 => {
            if (argv.len != 3) return it.wrongArgs("grab status window");
            const w = try findWidget(it, app, try it.str(argv[2]));
            if (app.grab.widget != w) return .{ .str = "none" };
            return .{ .str = if (app.grab.global) "global" else "local" };
        },
        else => unreachable,
    }
}

fn set(app: *App, w: *Widget, global: bool) Value {
    app.grab = .{ .widget = w, .global = global };
    return Value.empty;
}

// ---- Tooltips ----

pub const Tip = struct {
    /// The widget that the pointer rests on, while its tooltip waits or shows.
    widget: ?*Widget = null,
    shown: bool = false,
    shown_us: i64 = 0,
    /// Counts the hover changes, so an old timer does nothing.
    gen: u64 = 0,
};

pub const delay_us: i64 = 600_000;
const fade_us: i64 = 150_000;

/// The pointer moved to another widget.
pub fn hover(app: *App, w: ?*Widget) void {
    const t = &app.tip;
    if (t.shown) if (t.widget) |old| if (old.alive()) old.toplevel().invalidate(.{ .style = false, .measure = false, .layout = false, .paint = true });
    t.gen +%= 1;
    t.shown = false;
    t.widget = null;
    const nw = w orelse return;
    if (app.tooltips.get(nw.path) == null) return;
    t.widget = nw;
    _ = app.loop.addNative(delay_us, fire, app) catch {};
}

/// A press hides the tooltip.
pub fn press(app: *App) void {
    hover(app, null);
}

fn fire(ctx: ?*anyopaque) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    const t = &app.tip;
    const w = t.widget orelse return;
    if (!w.alive() or app.dispatch.hover != w or t.shown) return;
    t.shown = true;
    t.shown_us = app.platform.nowUs();
    w.toplevel().invalidate(.{ .style = false, .measure = false, .layout = false, .paint = true });
}

/// Paints the tooltip of the toplevel `top`, over its widgets.
pub fn paintTip(app: *App, top: *Widget, b: *scene.Builder) !void {
    const t = &app.tip;
    if (!t.shown) return;
    const w = t.widget orelse return;
    if (!w.alive() or w.toplevel() != top) return;
    const text = app.tooltips.get(w.path) orelse return;
    var st = app.styles.compute(top, "tooltip", &top.style, app.env);
    const since = app.platform.nowUs() - t.shown_us;
    if (since < fade_us and !anim.reduced(app)) {
        st.opacity *= @as(f32, @floatFromInt(since)) / @as(f32, @floatFromInt(fade_us));
        app.anim_more = true;
    }
    const size = paint.textSize(app, text, st.font);
    const ins = paint.insets(&st);
    var x: i32 = 0;
    var y: i32 = 0;
    var p: ?*Widget = w;
    while (p) |n| : (p = n.parent) {
        if (n == top) break;
        x +|= n.geom.x;
        y +|= n.geom.y;
    }
    const bw = size.w + ins.horizontal();
    const bh = size.h + ins.vertical();
    y += w.geom.h + 6;
    // Keep the box in the window.
    x = std.math.clamp(x, 4, @max(top.geom.w - bw - 4, 4));
    if (y + bh > top.geom.h - 4) y = @max(y - w.geom.h - bh - 12, 4);
    const r: geom.Rect = .{ .x = x, .y = y, .w = bw, .h = bh };
    try paint.styledBox(b, r, &st);
    try paint.label(w, b, r.inset(ins), text, &st, .center, .left);
}

/// `ztk::tooltip path ?text?`: sets, reads, or removes (with an empty text) the tooltip of a widget.
pub fn cmdTooltip(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    if (argv.len < 2 or argv.len > 3) return it.wrongArgs("ztk::tooltip window ?text?");
    const w = try findWidget(it, app, try it.str(argv[1]));
    if (argv.len == 2) return .{ .str = try it.alloc().dupe(u8, app.tooltips.get(w.path) orelse "") };
    const text = try it.str(argv[2]);
    if (app.tooltips.fetchRemove(w.path)) |kv| {
        app.gpa.free(kv.key);
        app.gpa.free(kv.value);
    }
    if (text.len > 0) {
        const k = try app.gpa.dupe(u8, w.path);
        errdefer app.gpa.free(k);
        const v = try app.gpa.dupe(u8, text);
        errdefer app.gpa.free(v);
        try app.tooltips.put(app.gpa, k, v);
    }
    return Value.empty;
}

/// Removes the tooltip of a widget that is deleted.
pub fn dropTooltip(app: *App, path: []const u8) void {
    if (app.tooltips.fetchRemove(path)) |kv| {
        app.gpa.free(kv.key);
        app.gpa.free(kv.value);
    }
}

pub fn deinit(app: *App) void {
    var it = app.tooltips.iterator();
    while (it.next()) |e| {
        app.gpa.free(e.key_ptr.*);
        app.gpa.free(e.value_ptr.*);
    }
    app.tooltips.deinit(app.gpa);
}
