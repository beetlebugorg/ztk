//! The popup windows of the drawn menus, for a backend with
//! `Platform.popups`. Each menu of the posted chain, except a menu bar,
//! gets one popup window. The first popup has the window of the toplevel
//! as its parent, and each cascade has the popup of its parent menu as
//! its parent, as `xdg_popup` asks for.
//!
//! `sync` compares the chain with the popups from the first menu on. At
//! the first menu with another anchor, it destroys the popups from the
//! last one down to that menu, and makes new popups for the rest of the
//! chain. A popup window has room for the shadow of the box and for the
//! slide of the open move: the margin of the popup, which the backend
//! leaves out of the placement. The anchor of the first menu is the point of
//! the post, or the entry of the menu bar. The anchor of a cascade is the
//! row of its entry in the parent popup. The backend places the popup
//! and gives the place in `Window.pos`. So the box of a menu in the
//! coordinates of the toplevel is the sum of the places of its popup and
//! of each parent popup, plus the margin (`boxOf`).
//!
//! The menus keep the coordinates of the toplevel: an event of a popup
//! window gets the place of the popup added to its position and goes to
//! the toplevel, so the bindings of the class `Menu` and the hit test of
//! `menudraw.zig` see one plane. After each frame of the toplevel, each
//! popup paints its menu with the offset of its place (`paintAll`). At an
//! unpost, the popups of the chain become ghosts for the close move, and
//! the end of the fade destroys them.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const num = @import("../num.zig");
const geom = @import("../geom.zig");
const widget = @import("../widget.zig");
const paint = @import("../paint.zig");
const scene_mod = @import("../scene.zig");
const plat = @import("../platform/platform.zig");
const event = @import("../event.zig");
const render_thread = @import("../render/thread.zig");
const Atlas = @import("../text/atlas.zig").Atlas;
const menu = @import("menu.zig");
const md = @import("menudraw.zig");
const App = @import("../app.zig").App;
const Widget = widget.Widget;
const Window = plat.Window;

const max = md.max_depth;
/// The largest side of a popup surface in device pixels.
const max_side: u32 = 16384;

/// The place and the size that a menu asks of its popup.
const Spec = struct {
    menu: *Widget,
    top: *Widget,
    anchor: geom.Rect,
    side: plat.Popup.Side,
    offset: geom.Point,
    /// The room around the box for its shadow, in logical pixels.
    margin: i32,
    size: geom.Size,

    fn sameAnchor(a: *const Spec, b: *const Spec) bool {
        return a.menu == b.menu and a.top == b.top and a.side == b.side and
            std.meta.eql(a.anchor, b.anchor) and std.meta.eql(a.offset, b.offset) and a.margin == b.margin;
    }
};

pub const Pop = struct {
    spec: Spec,
    win: *Window,
    render: *render_thread.RenderThread,
    /// For a ghost: the place of the window in the toplevel at the start of the close move.
    abs: geom.Point = .{},
    atlas_seen: u32 = Atlas.seen_none,
};

pub const Pops = struct {
    live: [max]Pop = undefined,
    n: usize = 0,
    ghosts: [max]Pop = undefined,
    ng: usize = 0,
};

/// True when the menus of the chain go in popup windows.
pub fn active(app: *App) bool {
    return app.platform.popups and !app.platform.hasNativeMenus();
}

fn shownTop(app: *App, first: *Widget) *Widget {
    if (app.menu_top) |t| if (t.alive()) return t;
    return first.toplevel();
}

fn specOf(app: *App, ch: []const *Widget, j: usize, top: *Widget) Spec {
    const w = ch[j];
    app.ensureStyle(w);
    const m = paint.overflow(&w.style);
    const sz = md.size(w);
    var s: Spec = .{
        .menu = w,
        .top = top,
        .anchor = .{},
        .side = .below,
        .offset = .{},
        .margin = m,
        .size = .{ .w = sz.w + 2 * m, .h = sz.h + 2 * m + md.slide_px },
    };
    if (j == 0) {
        const at = menu.data(w).post_at;
        s.anchor = .{ .x = at.x, .y = at.y };
        return s;
    }
    const p = ch[j - 1];
    const pd = menu.data(p);
    if (pd.is_bar) {
        s.anchor = md.barEntryRect(p, pd.cascade);
        return s;
    }
    app.ensureStyle(p);
    const pm = paint.overflow(&p.style);
    const y0 = menu.yOf(p, pd.cascade);
    const y1 = menu.yOf(p, pd.cascade + 1);
    const pad = paint.insets(&w.style).top;
    s.anchor = .{ .x = pm, .y = pm + md.slide_px + y0, .w = md.size(p).w, .h = @max(y1 - y0, 1) };
    s.side = .right;
    s.offset = .{ .x = -2, .y = -pad };
    return s;
}

/// The place of the live popup `k` in the coordinates of its toplevel.
fn absOf(ps: *const Pops, k: usize) geom.Point {
    var o: geom.Point = .{};
    for (ps.live[0 .. k + 1]) |p| {
        o.x += p.win.pos.x;
        o.y += p.win.pos.y;
    }
    return o;
}

fn destroy(app: *App, p: *Pop) void {
    app.giveRender(p.render);
    app.platform.destroyWindow(p.win);
}

fn create(app: *App, s: Spec, parent: *Window) !Pop {
    const win = try app.platform.createWindow(.{ .size = s.size, .popup = .{
        .parent = parent,
        .anchor = s.anchor,
        .side = s.side,
        .offset = s.offset,
        .margin = .{ .left = s.margin, .right = s.margin, .top = s.margin + md.slide_px, .bottom = s.margin },
    } });
    errdefer app.platform.destroyWindow(win);
    const mode: render_thread.Mode = if (app.render_ready) app.render.mode else .inline_draw;
    const r = try app.takeRender(mode, app.platform.target(win));
    return .{ .spec = s, .win = win, .render = r };
}

/// Makes the popups follow the posted chain.
pub fn sync(app: *App) void {
    if (!active(app)) return;
    if (app.closing) return dropAll(app);
    const ps = &app.menu_pops;
    var list: [max]*Widget = undefined;
    const ch = md.chain(app, &list);
    var want: [max]Spec = undefined;
    var nw: usize = 0;
    if (ch.len > 0) {
        const top = shownTop(app, ch[0]);
        if (top.alive() and app.winOf(top) != null) for (ch, 0..) |w, j| {
            if (menu.data(w).is_bar) continue;
            want[nw] = specOf(app, ch, j, top);
            nw += 1;
        };
    }
    var keep: usize = 0;
    while (keep < ps.n and keep < nw and ps.live[keep].spec.sameAnchor(&want[keep])) keep += 1;
    while (ps.n > keep) {
        ps.n -= 1;
        destroy(app, &ps.live[ps.n]);
    }
    for (ps.live[0..keep], want[0..keep]) |*p, s| {
        if (!std.meta.eql(p.spec.size, s.size)) app.platform.vtable.requestSize(app.platform.ptr, p.win, s.size);
        p.spec = s;
    }
    while (ps.n < nw) {
        const parent = if (ps.n == 0) app.winOf(want[0].top).? else ps.live[ps.n - 1].win;
        ps.live[ps.n] = create(app, want[ps.n], parent) catch |e| return app.frameError(e);
        ps.n += 1;
    }
}

/// The box of a menu with a popup, in the coordinates of its toplevel, or null.
pub fn boxOf(app: *App, w: *const Widget) ?geom.Rect {
    const ps = &app.menu_pops;
    for (ps.live[0..ps.n], 0..) |p, k| if (p.spec.menu == w) {
        const o = absOf(ps, k);
        const m = p.spec.margin;
        return .{ .x = o.x + m, .y = o.y + m + md.slide_px, .w = p.spec.size.w - 2 * m, .h = p.spec.size.h - 2 * m - md.slide_px };
    };
    return null;
}

/// True when the menu has a ghost popup for its close move.
pub fn hasGhost(app: *App, w: *const Widget) bool {
    const ps = &app.menu_pops;
    for (ps.ghosts[0..ps.ng]) |p| if (p.spec.menu == w) return true;
    return false;
}

/// Turns the live popups into ghosts, at the start of the close move.
pub fn toGhosts(app: *App) void {
    dropGhosts(app);
    const ps = &app.menu_pops;
    for (ps.live[0..ps.n], 0..) |p, k| {
        ps.ghosts[k] = p;
        ps.ghosts[k].abs = absOf(ps, k);
    }
    ps.ng = ps.n;
    ps.n = 0;
}

/// Destroys the ghosts, the deepest one first.
pub fn dropGhosts(app: *App) void {
    const ps = &app.menu_pops;
    while (ps.ng > 0) {
        ps.ng -= 1;
        destroy(app, &ps.ghosts[ps.ng]);
    }
}

/// Destroys each popup, at the end of the program.
pub fn dropAll(app: *App) void {
    const ps = &app.menu_pops;
    dropGhosts(app);
    while (ps.n > 0) {
        ps.n -= 1;
        destroy(app, &ps.live[ps.n]);
    }
}

/// Paints the popups of the toplevel `top`, after its frame.
pub fn paintAll(app: *App, top: *Widget) void {
    const ps = &app.menu_pops;
    for (ps.live[0..ps.n], 0..) |*p, k| if (p.spec.top == top) {
        paintPop(app, p, absOf(ps, k), false) catch |e| app.frameError(e);
    };
    for (ps.ghosts[0..ps.ng]) |*p| if (p.spec.top == top) {
        paintPop(app, p, p.abs, true) catch |e| app.frameError(e);
    };
}

fn paintPop(app: *App, p: *Pop, org: geom.Point, ghost: bool) !void {
    const win = p.win;
    const scale = win.scale;
    const dw: u32 = @intCast(std.math.clamp(num.pxRound(@as(f64, @floatFromInt(win.size.w)) * scale), 1, max_side));
    const dh: u32 = @intCast(std.math.clamp(num.pxRound(@as(f64, @floatFromInt(win.size.h)) * scale), 1, max_side));
    const fr = p.render.back();
    fr.reset(app.gpa);
    fr.scene.reset(dw, dh);
    fr.scene.clear = .{ 0, 0, 0, 0 };
    var b = scene_mod.Builder.init(app.gpa, &fr.scene, scale);
    fr.time_us = app.platform.nowUs();
    const saved_frame = app.anim_frame;
    const saved_more = app.anim_more;
    app.anim_frame = fr;
    app.anim_more = false;
    // A part that moves on the UI thread makes the toplevel paint again
    // at the next refresh, and the toplevel paints its popups.
    defer {
        app.anim_frame = saved_frame;
        app.anim_more = saved_more or app.anim_more;
    }
    b.pushOffset(-org.x, -org.y);
    if (ghost) try md.paintGhost(app, p.spec.menu, &b) else try md.paintLive(app, p.spec.menu, &b);
    b.popOffset();
    try app.atlas.takePatchesFor(app.gpa, &fr.patches, &p.atlas_seen);
    p.render.submit();
}

/// An event of a popup window with the window of the toplevel and the
/// position in the coordinates of the toplevel.
fn retarget(ev: event.Event, win: *Window, o: geom.Point) event.Event {
    var e = ev;
    const ox: f32 = @floatFromInt(o.x);
    const oy: f32 = @floatFromInt(o.y);
    switch (e) {
        .motion => |*m| {
            m.window = win;
            m.x += ox;
            m.y += oy;
        },
        .button => |*m| {
            m.window = win;
            m.x += ox;
            m.y += oy;
        },
        .scroll => |*m| {
            m.window = win;
            m.x += ox;
            m.y += oy;
        },
        .leave => |*m| m.window = win,
        .key => |*m| m.window = win,
        .preedit => |*m| m.window = win,
        .commit => |*m| m.window = win,
        else => {},
    }
    return e;
}

/// Handles an event of a popup window. Gives false for an event of another window.
pub fn handleEvent(app: *App, ev: event.Event) bool {
    const ps = &app.menu_pops;
    if (ps.n == 0 and ps.ng == 0) return false;
    const win = ev.window() orelse return false;
    for (ps.ghosts[0..ps.ng]) |*p| if (p.win == win) {
        if (ev == .frame) paintPop(app, p, p.abs, true) catch |e| app.frameError(e);
        return true;
    };
    const k = for (ps.live[0..ps.n], 0..) |p, i| {
        if (p.win == win) break i;
    } else return false;
    const p = &ps.live[k];
    const top = p.spec.top;
    switch (ev) {
        .frame => paintPop(app, p, absOf(ps, k), false) catch |e| app.frameError(e),
        // The system dismissed the popup, for example after a press outside each window of the program.
        .close => md.unpostAll(app),
        // A flip or a slide moved the popup: the toplevel paints the popups again.
        .resize, .scale => if (top.alive()) top.invalidate(.{ .style = false, .measure = false, .layout = false, .paint = true }),
        .motion, .button, .scroll, .leave, .key, .preedit, .commit => {
            if (!top.alive()) return true;
            const tw = app.winOf(top) orelse return true;
            @import("../dispatch.zig").handleIn(app, retarget(ev, tw, absOf(ps, k)), top);
        },
        else => {},
    }
    return true;
}
