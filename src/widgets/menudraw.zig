//! The drawn menus: a posted menu that the core paints, for a backend
//! without native menus. The posted menus form a chain. The first menu
//! of the chain is `App.menu_root`. Each menu with an open cascade has
//! the index of that entry in `Data.cascade`, and the menu of the entry
//! is the next menu of the chain.
//!
//! The toplevel of a menu paints the chain over its widgets, after the
//! list of a combobox (`paintPosted`). Each menu is a box with a round
//! corner and a shadow (the style of the class `Menu`), with one row for
//! each entry (parts `::item`, `::item-active`, `::separator`,
//! `::accelerator`, and `::indicator`). A menu that does not fit in the
//! window moves left or up into it. A cascade opens on the right of its
//! entry, or on the left when the window has no room on the right.
//!
//! A menu opens with a fade and a slide of 6 logical pixels in 150 ms, as
//! the list of a combobox. The two paints at the ends of the move go to
//! the render thread as a frame animation. An unpost ends the chain at
//! once, as Tk does, and the menus of the chain fade out in 150 ms
//! (`Fade`): the frame paints them from their last state.
//!
//! While a chain is posted, the first menu holds the grab, so each
//! pointer event of the window goes to the bindings of the class `Menu`
//! with the coordinates of the window (`%X %Y`). The keys go to the first
//! menu too (`keyTarget`). `::ztk::priv::menu` finds the menu and the
//! entry under the pointer, and handles the keys of Tk: `Up`, `Down`,
//! `Left`, `Right`, `Return`, `space`, `Escape`, and the letter of
//! `-underline`.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const num = @import("../num.zig");
const geom = @import("../geom.zig");
const widget = @import("../widget.zig");
const paint = @import("../paint.zig");
const scene = @import("../scene.zig");
const path = @import("../path.zig");
const anim = @import("../anim.zig");
const easing = @import("../easing.zig");
const loop_mod = @import("../loop.zig");
const style_mod = @import("../style.zig");
const menu = @import("menu.zig");
const options = @import("../options.zig");
const App = @import("../app.zig").App;
const Widget = widget.Widget;
const Value = ztcl.Value;
const Style = style_mod.Style;

const move_dur_us: i64 = 150_000;
const slide: f32 = 6;
/// The longest chain of cascades.
const max_depth = 16;
/// The gap between a menu and the edge of the window.
const edge: i32 = 4;

/// The styles of the parts of a menu.
const Parts = struct {
    box: Style,
    item: Style,
    active: Style,
    sep: Style,
    accel: Style,
    ind: Style,

    fn of(w: *Widget) Parts {
        const app = w.app;
        app.ensureStyle(w);
        return .{
            .box = w.style,
            .item = app.styles.compute(w, "item", &w.style, app.env),
            .active = app.styles.compute(w, "item-active", &w.style, app.env),
            .sep = app.styles.compute(w, "separator", &w.style, app.env),
            .accel = app.styles.compute(w, "accelerator", &w.style, app.env),
            .ind = app.styles.compute(w, "indicator", &w.style, app.env),
        };
    }
};

/// The columns of a menu: the indicator, the label, the accelerator, and the arrow of a cascade.
const Cols = struct { ind: i32, label: i32, accel: i32, arrow: i32 };

fn columns(w: *Widget, ps: *const Parts) Cols {
    const app = w.app;
    var c: Cols = .{ .ind = 0, .label = 0, .accel = 0, .arrow = 0 };
    const line = paint.lineHeight(app, ps.item.font);
    for (menu.data(w).entries.items) |*en| {
        switch (en.kind) {
            .separator, .tearoff => continue,
            .checkbutton, .radiobutton => c.ind = line,
            .cascade => c.arrow = @divTrunc(line * 3, 4),
            .command => {},
        }
        c.label = @max(c.label, paint.textSize(app, en.get(.label), ps.item.font).w);
        const acc = en.get(.accelerator);
        if (acc.len > 0) c.accel = @max(c.accel, paint.textSize(app, acc, ps.accel.font).w + line);
    }
    return c;
}

/// The size of a posted menu in logical pixels.
pub fn size(w: *Widget) geom.Size {
    const ps = Parts.of(w);
    const c = columns(w, &ps);
    const box = paint.insets(&ps.box);
    const item = paint.insets(&ps.item);
    const n: i64 = @intCast(menu.data(w).entries.items.len);
    const h = menu.yOf(w, n) + box.bottom;
    const wd = box.horizontal() + item.horizontal() + c.ind + c.label + c.accel + c.arrow;
    return .{ .w = @max(wd, 80), .h = @max(h, box.vertical()) };
}

/// The toplevel that shows the chain.
fn shownTop(w: *Widget) *Widget {
    if (w.app.menu_top) |t| if (t.alive()) return t;
    return w.toplevel();
}

/// The box of a posted menu in the coordinates of the window of its
/// toplevel. The box of a menu bar is its row.
pub fn rect(w: *Widget) geom.Rect {
    const d = menu.data(w);
    const top = shownTop(w);
    if (d.is_bar) return .{ .x = 0, .y = 0, .w = top.geom.w, .h = barHeight(w) };
    const sz = size(w);
    var r: geom.Rect = .{ .x = d.post_at.x, .y = d.post_at.y, .w = sz.w, .h = sz.h };
    if (r.x + r.w > top.geom.w - edge) r.x = top.geom.w - edge - r.w;
    if (r.y + r.h > top.geom.h - edge) r.y = top.geom.h - edge - r.h;
    r.x = @max(r.x, edge);
    r.y = @max(r.y, edge);
    return r;
}

/// The menu of the open cascade of a menu, or null.
pub fn cascadeOf(w: *Widget) ?*Widget {
    const d = menu.data(w);
    if (d.cascade < 0 or d.cascade >= d.entries.items.len) return null;
    const en = &d.entries.items[@intCast(d.cascade)];
    const sub = w.app.find(en.get(.menu)) orelse return null;
    if (sub.class != &menu.class or sub == w or !menu.data(sub).posted) return null;
    return sub;
}

/// The posted chain from `App.menu_root`, in the order of the cascades.
fn chain(app: *App, out: *[max_depth]*Widget) []*Widget {
    var n: usize = 0;
    var m = app.menu_root;
    while (m) |x| : (m = cascadeOf(x)) {
        if (n == max_depth or !x.alive()) break;
        // A cascade can name a menu that is already in the chain.
        for (out[0..n]) |y| if (y == x) return out[0..n];
        out[n] = x;
        n += 1;
    }
    return out[0..n];
}

fn repaint(w: *Widget) void {
    if (w.alive()) w.toplevel().invalidate(.{ .style = false, .measure = false, .layout = false, .paint = true });
}

/// Posts a menu as the first menu of the chain. It unposts the old chain.
pub fn post(w: *Widget) void {
    const app = w.app;
    if (app.menu_root) |r| if (r != w) unpostAll(app);
    clearFade(app);
    const d = menu.data(w);
    d.open_us = app.platform.nowUs();
    d.cascade = -1;
    app.menu_root = w;
    app.menu_top = w.toplevel();
    app.grab = .{ .widget = w, .global = false };
    repaint(w);
}

/// Opens the cascade of an entry, or closes the open cascade when the
/// entry is not a usable cascade entry.
pub fn postCascade(w: *Widget, index: i64) ztcl.Error!void {
    const app = w.app;
    const d = menu.data(w);
    if (!d.posted) return;
    var sub: ?*Widget = null;
    if (index >= 0 and index < d.entries.items.len) {
        const en = &d.entries.items[@intCast(index)];
        if (en.kind == .cascade and en.usable()) {
            if (app.find(en.get(.menu))) |m| if (m.class == &menu.class and m != w) {
                sub = m;
            };
        }
    }
    if (sub != null and d.cascade == index and cascadeOf(w) == sub) return;
    if (cascadeOf(w)) |old| unpostChain(old);
    d.cascade = -1;
    const m = sub orelse {
        repaint(w);
        return;
    };
    try menu.runPostCommand(m);
    if (!w.alive() or !m.alive()) return;
    const r = rect(w);
    const sz = size(m);
    const md = menu.data(m);
    const pad = paint.insets(&m.style).top;
    var x = r.x + r.w - 2;
    if (x + sz.w > shownTop(w).geom.w - edge) x = r.x - sz.w + 2;
    md.post_at = .{ .x = x, .y = r.y + menu.yOf(w, index) - pad };
    // A cascade of a menu bar opens below its entry.
    if (d.is_bar) md.post_at = .{ .x = barX(w, index), .y = r.h };
    md.posted = true;
    md.active = -1;
    md.cascade = -1;
    md.open_us = app.platform.nowUs();
    d.cascade = index;
    repaint(w);
}

/// Unposts a menu and its open cascades.
fn unpostChain(w: *Widget) void {
    var list: [max_depth]*Widget = undefined;
    var n: usize = 0;
    var m: ?*Widget = w;
    while (m) |x| : (m = cascadeOf(x)) {
        if (n == max_depth) break;
        for (list[0..n]) |y| if (y == x) break;
        list[n] = x;
        n += 1;
    }
    for (list[0..n]) |x| {
        const d = menu.data(x);
        d.posted = false;
        d.active = -1;
        d.cascade = -1;
        repaint(x);
    }
}

/// Unposts one menu. When it is the first menu of the chain, the chain closes and the grab ends.
pub fn unpost(w: *Widget) void {
    const app = w.app;
    if (app.menu_root == w) return unpostAll(app);
    // A cascade in the chain: its parent menu loses the open cascade.
    var list: [max_depth]*Widget = undefined;
    for (chain(app, &list)) |x| if (cascadeOf(x) == w) {
        menu.data(x).cascade = -1;
    };
    unpostChain(w);
}

/// A menu of a closed chain during its close move.
const Ghost = struct { w: *Widget, r: geom.Rect, active: i64 };

/// The menus of the last closed chain. They fade out in 150 ms, and a native timer removes them.
pub const Fade = struct {
    items: [max_depth]Ghost = undefined,
    n: usize = 0,
    start_us: i64 = 0,
    top: ?*Widget = null,
    timer: ?loop_mod.TimerId = null,
};

/// Removes the closing menus at once.
fn clearFade(app: *App) void {
    const f = &app.menu_fade;
    if (f.timer) |id| _ = app.loop.cancel(id);
    // Each toplevel paints again: `f.top` can be gone, so the code does not read it.
    if (f.n > 0) {
        const dirty: widget.Dirty = .{ .style = false, .measure = false, .layout = false, .paint = true };
        if (app.root) |r| r.invalidate(dirty);
        for (app.tops.items) |t| if (t.alive()) t.invalidate(dirty);
    }
    f.* = .{};
}

fn fadeDone(ctx: ?*anyopaque) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    app.menu_fade.timer = null;
    clearFade(app);
}

/// Starts the close move of the posted chain.
fn startFade(app: *App) void {
    clearFade(app);
    if (anim.reduced(app)) return;
    const f = &app.menu_fade;
    var list: [max_depth]*Widget = undefined;
    for (chain(app, &list)) |w| {
        const d = menu.data(w);
        if (d.is_bar) continue;
        f.items[f.n] = .{ .w = w, .r = rect(w), .active = d.active };
        f.n += 1;
    }
    if (f.n == 0) return;
    f.top = if (app.menu_top) |t| t else f.items[0].w.toplevel();
    f.start_us = app.platform.nowUs();
    f.timer = app.loop.addNative(move_dur_us, fadeDone, app) catch null;
    if (f.timer == null) f.* = .{};
}

/// Unposts the chain and ends the grab.
pub fn unpostAll(app: *App) void {
    if (app.menu_root == null) return;
    startFade(app);
    const r = app.menu_root orelse return;
    app.menu_root = null;
    app.menu_top = null;
    if (app.menu_button) |b| {
        app.menu_button = null;
        repaint(b);
    }
    if (app.grab.widget == r) app.grab.widget = null;
    if (r.alive()) unpostChain(r);
}

/// Removes a menu that is going away from the chain.
pub fn forget(w: *Widget) void {
    const app = w.app;
    const f = &app.menu_fade;
    for (f.items[0..f.n]) |g| if (g.w == w) {
        clearFade(app);
        break;
    };
    if (app.menu_button == w) app.menu_button = null;
    if (app.menu_root == w) {
        app.menu_root = null;
        app.menu_top = null;
        app.menu_button = null;
        if (app.grab.widget == w) app.grab.widget = null;
        return;
    }
    var list: [max_depth]*Widget = undefined;
    for (chain(app, &list)) |x| if (cascadeOf(x) == w) {
        menu.data(x).cascade = -1;
    };
}

// ---- The menu bar ----

/// The drawn menu bar of a toplevel: the menu of its `-menu`, or null.
pub fn barOf(top: *Widget) ?*Widget {
    const app = top.app;
    if (app.platform.hasNativeMenus() or !top.class.is_toplevel) return null;
    const name = options.get(top, "-menu").text;
    if (name.len == 0) return null;
    const m = app.find(name) orelse return null;
    if (m.class != &menu.class) return null;
    menu.data(m).is_bar = true;
    return m;
}

const BarParts = struct {
    row: Style,
    item: Style,
    active: Style,

    fn of(w: *Widget) BarParts {
        const app = w.app;
        app.ensureStyle(w);
        return .{
            .row = app.styles.compute(w, "bar", &w.style, app.env),
            .item = app.styles.compute(w, "bar-item", &w.style, app.env),
            .active = app.styles.compute(w, "bar-item-active", &w.style, app.env),
        };
    }
};

/// The height of the row of a menu bar.
pub fn barHeight(w: *Widget) i32 {
    const ps = BarParts.of(w);
    return paint.lineHeight(w.app, ps.item.font) + paint.insets(&ps.item).vertical() + paint.insets(&ps.row).vertical();
}

fn barWidth(w: *Widget, ps: *const BarParts, en: *const menu.Entry) i32 {
    if (en.kind == .separator or en.kind == .tearoff) return 0;
    return paint.textSize(w.app, en.get(.label), ps.item.font).w + paint.insets(&ps.item).horizontal();
}

/// The left edge of an entry of a menu bar.
pub fn barX(w: *Widget, index: i64) i32 {
    const ps = BarParts.of(w);
    var x = paint.insets(&ps.row).left;
    for (menu.data(w).entries.items, 0..) |*en, i| {
        if (i == index) break;
        x += barWidth(w, &ps, en);
    }
    return x;
}

fn barEntryAt(w: *Widget, x: i32) i64 {
    const ps = BarParts.of(w);
    var left = paint.insets(&ps.row).left;
    for (menu.data(w).entries.items, 0..) |*en, i| {
        const wd = barWidth(w, &ps, en);
        if (x >= left and x < left + wd) return @intCast(i);
        left += wd;
    }
    return -1;
}

/// The extra top inset of a toplevel with a drawn menu bar: the height of the row.
pub fn barInsets(top: *Widget) geom.Insets {
    const m = barOf(top) orelse return .{};
    return .{ .top = barHeight(m) };
}

/// The menu bar at a point of the window of a toplevel, or null.
pub fn barAt(top: *Widget, x: i32, y: i32) ?*Widget {
    const m = barOf(top) orelse return null;
    if (x < 0 or y < 0 or x >= top.geom.w or y >= barHeight(m)) return null;
    return m;
}

/// Paints the menu bar row of a toplevel.
pub fn paintBar(app: *App, top: *Widget, b: *scene.Builder) !void {
    const w = barOf(top) orelse return;
    const ps = BarParts.of(w);
    const h = barHeight(w);
    try paint.styledBox(b, .{ .x = 0, .y = 0, .w = top.geom.w, .h = h }, &ps.row);
    const ins = paint.insets(&ps.row);
    const d = menu.data(w);
    const open = app.menu_root == w;
    var x = ins.left;
    for (d.entries.items, 0..) |*en, i| {
        const wd = barWidth(w, &ps, en);
        if (wd == 0) continue;
        defer x += wd;
        const on = open and i == d.active;
        var st = if (on) ps.active else ps.item;
        if (std.mem.eql(u8, en.get(.state), "disabled")) st.color.a = @intFromFloat(@as(f32, @floatFromInt(st.color.a)) * 0.45);
        const r: geom.Rect = .{ .x = x, .y = ins.top, .w = wd, .h = h - ins.vertical() };
        if (on) try paint.styledBox(b, r, &st);
        const inner = r.inset(paint.insets(&st));
        try paint.label(w, b, inner, en.get(.label), &st, .w, .left);
        try paintUnderline(w, b, inner, en, &st);
    }
}

/// Starts the traversal of a menu bar: the bar holds the grab and the
/// cascade of the entry opens.
fn startBar(w: *Widget, top: *Widget, index: i64) ztcl.Error!void {
    const app = w.app;
    if (app.menu_root) |r| if (r != w) unpostAll(app);
    const d = menu.data(w);
    d.posted = true;
    d.cascade = -1;
    app.menu_root = w;
    app.menu_top = top;
    app.grab = .{ .widget = w, .global = false };
    try barSelect(w, index);
}

/// Activates an entry of the bar of the chain and opens its cascade with its first entry active.
fn barSelect(w: *Widget, index: i64) ztcl.Error!void {
    select(w, index);
    try postCascade(w, menu.data(w).active);
    repaint(w);
    if (w.app.menu_top) |t| t.invalidate(.{ .style = false, .measure = false, .layout = false, .paint = true });
}

/// The next usable entry of a bar from the active entry, in the direction `step`.
fn barStep(w: *Widget, step: i64) ztcl.Error!void {
    const d = menu.data(w);
    const from = if (d.active < 0) 0 else d.active + step;
    const i = firstUsable(w, from, step);
    try barSelect(w, i);
    if (cascadeOf(w)) |sub| select(sub, firstUsable(sub, 0, 1));
}

// ---- Painting ----

/// The progress of the open move at a time: 0 is hidden and 1 is open.
pub fn openness(d: *const menu.Data, now: i64) f32 {
    return progress(d.open_us, now);
}

const hl_dur_us: i64 = 120_000;

/// The top of the highlight of the active entry in the coordinates of the menu, at a time.
fn highlightY(w: *Widget, now: i64) i32 {
    const d = menu.data(w);
    const to = menu.yOf(w, d.active);
    if (d.hl_us == 0 or now - d.hl_us >= hl_dur_us) return to;
    const t = easing.Timing.ease_out.eval(@as(f32, @floatFromInt(now - d.hl_us)) / @as(f32, @floatFromInt(hl_dur_us)));
    const y = @as(f32, @floatFromInt(d.hl_from)) + (@as(f32, @floatFromInt(to - d.hl_from))) * t;
    return @intFromFloat(@round(y));
}

/// The eased progress of a move that started at `start_us`.
fn progress(start_us: i64, now: i64) f32 {
    const t = std.math.clamp(@as(f32, @floatFromInt(now - start_us)) / @as(f32, @floatFromInt(move_dur_us)), 0, 1);
    return easing.Timing.ease_out.eval(t);
}

/// A style with its opacity and the alpha of its text scaled by `p`.
/// The alpha of the text stays 1 or more, so the paint at `p` 0 has the quads of the paint at 1.
fn faded(st: Style, p: f32) Style {
    var s = st;
    s.opacity *= p;
    const a: f32 = @floatFromInt(st.color.a);
    s.color.a = @intFromFloat(@max(@round(a * p), @min(a, 1)));
    return s;
}

fn paintMenu(w: *Widget, b: *scene.Builder, r0: geom.Rect, p: f32, active_entry: i64) !void {
    const app = w.app;
    const d = menu.data(w);
    const raw = Parts.of(w);
    const c = columns(w, &raw);
    const dy = num.pxRound(@as(f64, (1 - p) * -slide));
    var r = r0;
    r.y += dy;
    const box = faded(raw.box, p);
    try paint.styledBox(b, r, &box);
    const item = faded(raw.item, p);
    const active = faded(raw.active, p);
    const sep = faded(raw.sep, p);
    const ins = paint.insets(&raw.box);
    const m = menu.metrics(w);
    // The highlight of the active entry: at its eased place during a move between entries.
    if (active_entry >= 0 and active_entry == d.active and active_entry < d.entries.items.len) {
        const now = if (app.anim_frame) |fr| fr.time_us else app.platform.nowUs();
        const hy = highlightY(w, now);
        if (d.hl_us != 0 and now - d.hl_us < hl_dur_us) app.anim_more = true;
        try paint.styledBox(b, .{ .x = r.x + ins.left, .y = r.y + hy, .w = r.w - ins.horizontal(), .h = m.row }, &active);
    } else if (active_entry >= 0 and active_entry < d.entries.items.len) {
        try paint.styledBox(b, .{ .x = r.x + ins.left, .y = r.y + menu.yOf(w, active_entry), .w = r.w - ins.horizontal(), .h = m.row }, &active);
    }
    var y = r.y + ins.top;
    for (d.entries.items, 0..) |*en, i| {
        const h: i32 = switch (en.kind) {
            .separator => m.sep,
            .tearoff => m.tear,
            else => m.row,
        };
        defer y += h;
        const row: geom.Rect = .{ .x = r.x + ins.left, .y = y, .w = r.w - ins.horizontal(), .h = h };
        if (en.kind == .separator or en.kind == .tearoff) {
            const line: geom.Rect = .{ .x = row.x + 4, .y = row.y + @divTrunc(h, 2), .w = row.w - 8, .h = 1 };
            try paint.styledBox(b, line, &sep);
            continue;
        }
        const on = i == active_entry;
        const disabled = std.mem.eql(u8, en.get(.state), "disabled");
        var st = if (on) active else item;
        if (disabled) st.color.a = @intFromFloat(@as(f32, @floatFromInt(st.color.a)) * 0.45);
        const inner = row.inset(paint.insets(&raw.item));
        var x = inner.x;
        if (c.ind > 0) {
            if (menu.selected(w, en)) try paintIndicator(app, b, .{ .x = x, .y = inner.y, .w = c.ind, .h = inner.h }, en.kind, st.color, st.opacity);
            x += c.ind;
        }
        const text = en.get(.label);
        try paint.label(w, b, .{ .x = x, .y = inner.y, .w = c.label, .h = inner.h }, text, &st, .w, .left);
        try paintUnderline(w, b, .{ .x = x, .y = inner.y, .w = c.label, .h = inner.h }, en, &st);
        const acc = en.get(.accelerator);
        if (acc.len > 0) {
            var ast = faded(raw.accel, p);
            if (on) ast.color = st.color;
            if (disabled) ast.color.a = st.color.a;
            const ar: geom.Rect = .{ .x = inner.x + inner.w - c.arrow - c.accel, .y = inner.y, .w = c.accel, .h = inner.h };
            try paint.label(w, b, ar, acc, &ast, .e, .right);
        }
        if (en.kind == .cascade) {
            const k = std.math.clamp(@as(f32, @floatFromInt(inner.h)) * 0.16, 2.5, 4);
            const cx = @as(f32, @floatFromInt(inner.x + inner.w)) - k - 1;
            const cy = @as(f32, @floatFromInt(inner.y)) + @as(f32, @floatFromInt(inner.h)) / 2;
            var sh: path.Shape = .{};
            defer sh.deinit(app.gpa);
            try sh.stroke(app.gpa, &.{ .{ .x = cx - k / 2, .y = cy - k }, .{ .x = cx + k / 2, .y = cy }, .{ .x = cx - k / 2, .y = cy + k } }, 1.5, true);
            try paint.fillShape(b, &sh, st.color, st.opacity);
        }
    }
}

/// The mark of a check entry or the dot of a radio entry.
fn paintIndicator(app: *App, b: *scene.Builder, r: geom.Rect, kind: menu.Kind, color: geom.Color, opacity: f32) !void {
    const cx = @as(f32, @floatFromInt(r.x)) + @as(f32, @floatFromInt(r.w)) / 2 - 2;
    const cy = @as(f32, @floatFromInt(r.y)) + @as(f32, @floatFromInt(r.h)) / 2;
    var sh: path.Shape = .{};
    defer sh.deinit(app.gpa);
    if (kind == .radiobutton) {
        try sh.ellipse(app.gpa, cx, cy, 3, 3);
    } else {
        try sh.stroke(app.gpa, &.{ .{ .x = cx - 4, .y = cy }, .{ .x = cx - 1.5, .y = cy + 3 }, .{ .x = cx + 4, .y = cy - 3.5 } }, 1.5, true);
    }
    try paint.fillShape(b, &sh, color, opacity);
}

/// A line under the letter of `-underline`.
fn paintUnderline(w: *Widget, b: *scene.Builder, r: geom.Rect, en: *const menu.Entry, st: *const Style) !void {
    const app = w.app;
    const text = en.get(.label);
    const u = std.fmt.parseInt(i64, en.get(.underline), 0) catch return;
    const at = byteOfChar(text, u) orelse return;
    const len = std.unicode.utf8ByteSequenceLength(text[at]) catch return;
    if (at + len > text.len) return;
    const before = paint.textSize(app, text[0..at], st.font).w;
    const cw = paint.textSize(app, text[at .. at + len], st.font).w;
    const line = paint.lineHeight(app, st.font);
    const y = r.y + @divTrunc(r.h + line, 2) - 1;
    const ln: Style = .{ .background = st.color, .opacity = st.opacity };
    try paint.styledBox(b, .{ .x = r.x + before, .y = y, .w = @max(cw, 1), .h = 1 }, &ln);
}

/// The byte offset of the character at index `i`, or null.
fn byteOfChar(text: []const u8, i: i64) ?usize {
    if (i < 0) return null;
    var view = std.unicode.Utf8View.init(text) catch return null;
    var it = view.iterator();
    var k: i64 = 0;
    var at: usize = 0;
    while (it.nextCodepointSlice()) |cs| : (k += 1) {
        if (k == i) return at;
        at += cs.len;
    }
    return null;
}

/// Paints the posted chain of the toplevel `top`, over its widgets.
pub fn paintPosted(app: *App, top: *Widget, b: *scene.Builder) !void {
    const f = &app.menu_fade;
    if (f.top == top) for (f.items[0..f.n]) |g| {
        if (g.w.alive()) try paintMove(app, g.w, b, g.r, g.active, f.start_us, true);
    };
    var list: [max_depth]*Widget = undefined;
    for (chain(app, &list)) |w| {
        if (shownTop(w) != top or menu.data(w).is_bar) continue;
        try paintOne(app, w, b);
    }
}

fn paintOne(app: *App, w: *Widget, b: *scene.Builder) !void {
    const d = menu.data(w);
    return paintMove(app, w, b, rect(w), d.active, d.open_us, false);
}

/// Paints a menu at the point `start_us` of its open move, or of its close move when `closing` is set.
fn paintMove(app: *App, w: *Widget, b: *scene.Builder, r: geom.Rect, active_entry: i64, start_us: i64, closing: bool) !void {
    const now = if (app.anim_frame) |fr| fr.time_us else app.platform.nowUs();
    const reduced = anim.reduced(app);
    const t = progress(start_us, now);
    const p: f32 = if (reduced) 1 else if (closing) 1 - t else t;
    const quads = &b.scene.quads;
    const at = quads.items.len;
    try paintMenu(w, b, r, p, active_entry);
    const moving = now - start_us < move_dur_us and !reduced;
    if (!moving) return;
    const fr = app.anim_frame orelse {
        app.anim_more = true;
        return;
    };
    const n = quads.items.len - at;
    try paintMenu(w, b, r, 0, active_entry);
    try paintMenu(w, b, r, 1, active_entry);
    if (quads.items.len - at != 3 * n or n == 0) {
        quads.shrinkRetainingCapacity(at + n);
        app.anim_more = true;
        return;
    }
    const gpa = app.gpa;
    const mark = fr.anim_quads.items.len;
    try fr.anim_quads.appendSlice(gpa, quads.items[at + n .. at + 3 * n]);
    quads.shrinkRetainingCapacity(at + n);
    const off_at = fr.anim_offsets.items.len;
    try fr.anim_offsets.appendSlice(gpa, &.{ 0, 1 });
    try fr.anims.append(gpa, .{ .first = @intCast(at), .count = @intCast(n), .from = @intCast(mark), .stops = 2, .offsets = @intCast(off_at), .start_us = start_us, .delay_us = 0, .len_us = move_dur_us, .timing = easing.Timing.ease_out, .direction = if (closing) .reverse else .normal });
}

// ---- Input ----

/// The deepest menu of the chain at a point of the window, and the entry there.
const Hit = struct { menu: *Widget, entry: i64 };

fn hitTest(app: *App, x: i32, y: i32) ?Hit {
    var list: [max_depth]*Widget = undefined;
    const ws = chain(app, &list);
    var i = ws.len;
    while (i > 0) {
        i -= 1;
        const w = ws[i];
        const r = rect(w);
        if (x < r.x or x >= r.x + r.w or y < r.y or y >= r.y + r.h) continue;
        if (menu.data(w).is_bar) return .{ .menu = w, .entry = barEntryAt(w, x) };
        return .{ .menu = w, .entry = menu.entryAtY(w, y - r.y) };
    }
    return null;
}

/// The last menu of the chain: the menu of the keys.
fn deepest(app: *App) ?*Widget {
    var list: [max_depth]*Widget = undefined;
    const ws = chain(app, &list);
    if (ws.len == 0) return null;
    return ws[ws.len - 1];
}

/// Sets the active entry and sends `<<MenuSelect>>` when it changed.
fn select(w: *Widget, index: i64) void {
    const d = menu.data(w);
    const before = d.active;
    const now = w.app.platform.nowUs();
    const from = if (before >= 0) highlightY(w, now) else 0;
    menu.activate(w, index);
    if (d.active == before) return;
    // The highlight eases from its shown place when it moves from one entry to another.
    d.hl_from = from;
    d.hl_us = if (before >= 0 and d.active >= 0 and !anim.reduced(w.app)) now else 0;
    repaint(w);
    menu.selectEvent(w);
}

/// Invokes an entry of a posted menu: a cascade opens, and another entry
/// unposts the chain and then runs as `invoke` does.
fn choose(w: *Widget, index: i64) ztcl.Error!void {
    const app = w.app;
    const d = menu.data(w);
    if (index < 0 or index >= d.entries.items.len) return;
    const en = &d.entries.items[@intCast(index)];
    if (!en.usable()) return;
    if (en.kind == .cascade) {
        try postCascade(w, index);
        if (cascadeOf(w)) |sub| select(sub, firstUsable(sub, 0, 1));
        return;
    }
    unpostAll(app);
    _ = try menu.invoke(w, index);
}

/// The next usable entry from `from` in the direction `step`, with a wrap, or -1.
fn firstUsable(w: *Widget, from: i64, step: i64) i64 {
    const items = menu.data(w).entries.items;
    const n: i64 = @intCast(items.len);
    if (n == 0) return -1;
    var i = @mod(from, n);
    var k: i64 = 0;
    while (k < n) : (k += 1) {
        if (items[@intCast(i)].usable()) return i;
        i = @mod(i + step, n);
    }
    return -1;
}

const Action = enum { motion, press, release, up, down, left, right, @"return", escape, char, bar, alt };

/// The first toplevel whose drawn menu bar is `w`, or null.
fn topWithBar(app: *App, w: *Widget) ?*Widget {
    if (app.root) |r| if (barOf(r) == w) return r;
    for (app.tops.items) |t| if (t.alive() and barOf(t) == w) return t;
    return null;
}

/// The bar of the chain when `w` is the bar or the cascade that the bar opened, or null.
fn barBelow(app: *App, w: *Widget) ?*Widget {
    const r = app.menu_root orelse return null;
    if (!menu.data(r).is_bar) return null;
    if (w == r or cascadeOf(r) == w) return r;
    return null;
}

/// `F10` opens the first cascade of the menu bar of the toplevel of a
/// widget, and `Alt` with a letter opens the cascade with that `-underline` letter.
fn barKey(app: *App, it: *ztcl.Interp, act: Action, argv: []const Value) ztcl.Error!Value {
    const w = app.find(try it.str(argv[2])) orelse return Value.empty;
    const top = w.toplevel();
    const bar = barOf(top) orelse return Value.empty;
    if (app.menu_root == bar) {
        unpostAll(app);
        return .{ .int = 1 };
    }
    var index: i64 = firstUsable(bar, 0, 1);
    if (act == .alt) {
        if (argv.len < 4) return Value.empty;
        index = underlineIndex(bar, try it.str(argv[3])) orelse return .{ .int = 0 };
    }
    if (index < 0) return .{ .int = 0 };
    try startBar(bar, top, index);
    if (cascadeOf(bar)) |sub| select(sub, firstUsable(sub, 0, 1));
    return .{ .int = 1 };
}

/// `::ztk::priv::menu action window ?arg ...?`: the class bindings of `Menu` for a drawn menu.
fn cmdMenu(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    app.enter();
    defer app.leave();
    if (argv.len < 3) return it.wrongArgs("::ztk::priv::menu action window ?arg ...?");
    const act = std.meta.stringToEnum(Action, try it.str(argv[1])) orelse return it.fail("bad action", .{});
    if (act == .bar or act == .alt) return barKey(app, it, act, argv);
    if (app.menu_root == null) {
        // A press on a menu bar starts its traversal.
        if (act != .press or argv.len < 5) return Value.empty;
        const w = app.find(try it.str(argv[2])) orelse return Value.empty;
        if (w.class != &menu.class) return Value.empty;
        const top = topWithBar(app, w) orelse return Value.empty;
        const x: i32 = @intCast(std.math.clamp(try it.int(argv[3]), -1 << 24, 1 << 24));
        try startBar(w, top, barEntryAt(w, x));
        return Value.empty;
    }
    switch (act) {
        .motion, .press, .release => {
            if (argv.len < 5) return it.wrongArgs("::ztk::priv::menu action window x y");
            const x: i32 = @intCast(std.math.clamp(try it.int(argv[3]), -1 << 24, 1 << 24));
            const y: i32 = @intCast(std.math.clamp(try it.int(argv[4]), -1 << 24, 1 << 24));
            const hit = hitTest(app, x, y);
            switch (act) {
                .motion => {
                    const h = hit orelse return Value.empty;
                    if (menu.data(h.menu).is_bar) {
                        if (h.entry >= 0 and h.entry != menu.data(h.menu).active) try barSelect(h.menu, h.entry);
                        return Value.empty;
                    }
                    // A pointer over a menu with an open cascade, off its entries, keeps the cascade.
                    if (h.entry < 0 and cascadeOf(h.menu) != null) return Value.empty;
                    select(h.menu, h.entry);
                    try postCascade(h.menu, menu.data(h.menu).active);
                },
                .press => {
                    const h = hit orelse {
                        unpostAll(app);
                        return Value.empty;
                    };
                    // A press on the open entry of the bar closes the chain.
                    if (!menu.data(h.menu).is_bar) return Value.empty;
                    if (h.entry < 0 or h.entry == menu.data(h.menu).active) unpostAll(app) else try barSelect(h.menu, h.entry);
                },
                .release => {
                    const h = hit orelse return Value.empty;
                    if (h.entry < 0 or menu.data(h.menu).is_bar) return Value.empty;
                    try choose(h.menu, h.entry);
                },
                else => unreachable,
            }
        },
        .up, .down => {
            const w = deepest(app) orelse return Value.empty;
            const d = menu.data(w);
            const step: i64 = if (act == .down) 1 else -1;
            const from = if (d.active < 0) (if (act == .down) @as(i64, 0) else -1) else d.active + step;
            select(w, firstUsable(w, from, step));
        },
        .right => {
            const w = deepest(app) orelse return Value.empty;
            const d = menu.data(w);
            if (!d.is_bar and d.active >= 0 and d.entries.items[@intCast(d.active)].kind == .cascade) {
                try choose(w, d.active);
            } else if (barBelow(app, w)) |bar| try barStep(bar, 1);
        },
        .left => {
            const w = deepest(app) orelse return Value.empty;
            if (barBelow(app, w)) |bar| {
                try barStep(bar, -1);
            } else if (w != app.menu_root) unpost(w);
        },
        .@"return" => {
            const w = deepest(app) orelse return Value.empty;
            try choose(w, menu.data(w).active);
        },
        .escape => {
            const w = deepest(app) orelse return Value.empty;
            if (w == app.menu_root or barBelow(app, w) != null) unpostAll(app) else unpost(w);
        },
        .bar, .alt => unreachable,
        .char => {
            if (argv.len < 4) return Value.empty;
            const ch = try it.str(argv[3]);
            if (ch.len == 0) return Value.empty;
            const w = deepest(app) orelse return Value.empty;
            const i = underlineIndex(w, ch) orelse return Value.empty;
            select(w, i);
            try choose(w, i);
        },
    }
    return Value.empty;
}

/// The first usable entry whose `-underline` letter is `ch`, without case, or null.
fn underlineIndex(w: *Widget, ch: []const u8) ?i64 {
    for (menu.data(w).entries.items, 0..) |*en, i| {
        if (!en.usable()) continue;
        const text = en.get(.label);
        const u = std.fmt.parseInt(i64, en.get(.underline), 0) catch continue;
        const at = byteOfChar(text, u) orelse continue;
        const len = std.unicode.utf8ByteSequenceLength(text[at]) catch continue;
        if (at + len > text.len or len != ch.len) continue;
        if (std.ascii.eqlIgnoreCase(text[at .. at + len], ch)) return @intCast(i);
    }
    return null;
}

pub fn register(app: *App) !void {
    try app.it.register("ztk::priv::menu", cmdMenu);
    _ = try app.it.eval(
        \\bind Menu <Motion> {::ztk::priv::menu motion %W %X %Y}
        \\bind Menu <ButtonPress> {::ztk::priv::menu press %W %X %Y}
        \\bind Menu <ButtonRelease> {::ztk::priv::menu release %W %X %Y}
        \\bind Menu <Key-Up> {::ztk::priv::menu up %W}
        \\bind Menu <Key-Down> {::ztk::priv::menu down %W}
        \\bind Menu <Key-Left> {::ztk::priv::menu left %W}
        \\bind Menu <Key-Right> {::ztk::priv::menu right %W}
        \\bind Menu <Key-Return> {::ztk::priv::menu return %W}
        \\bind Menu <Key-space> {::ztk::priv::menu return %W}
        \\bind Menu <Key-Escape> {::ztk::priv::menu escape %W}
        \\bind Menu <KeyPress> {::ztk::priv::menu char %W %A}
        \\bind all <Key-F10> {::ztk::priv::menu bar %W}
        \\bind all <Alt-KeyPress> {::ztk::priv::menu alt %W %A}
    );
}
