//! The paned windows: `panedwindow` and `ttk::panedwindow`. Each one is a
//! widget and the geometry manager of its panes. The panes are in a row
//! (`-orient horizontal`) or a column, with a sash between two panes.
//!
//! `panedwindow`: the size of a pane along the axis is its `-width` or
//! `-height`, else the requested size of its widget, plus its padding. A
//! move of a sash first keeps the shown size of each pane, then grows the
//! pane on one side and shrinks the panes on the other side, the nearest
//! first, down to their `-minsize`. When the widget is larger or smaller
//! than its panes, the panes that `-stretch` allows change: each one in
//! order gets the rest of the difference in proportion to its size among
//! the panes left, rounded toward zero. The sash slot is `-sashwidth` (or
//! `-handlesize` with `-showhandle`, when that is larger) plus two times
//! `-sashpad`. `sash coord` gives the top-left corner of the sash in it.
//!
//! `ttk::panedwindow`: the sashes have positions. A change of the size
//! of the widget adds the difference to the panes in proportion to their
//! `-weight`, rounded toward zero, with the rest on the last weighted
//! pane. `sashpos` puts a sash between its neighbors and pushes them when
//! it must, so each sash keeps room for the ones after it.
//!
//! A press on a sash starts a drag. The panes follow the pointer at each
//! motion, and the render thread moves the sash with the pointer, so the
//! sash follows it while the UI thread is busy. With `-opaqueresize 0` a
//! drag moves the proxy line, and the release moves the sash. The modern
//! theme draws a thin line (part `::sash`), and the sash under the pointer
//! or in a drag fades to the part `::sash-active`.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const num = @import("../num.zig");
const geom = @import("../geom.zig");
const widget = @import("../widget.zig");
const options = @import("../options.zig");
const paint = @import("../paint.zig");
const scene = @import("../scene.zig");
const anim = @import("../anim.zig");
const easing = @import("../easing.zig");
const layout = @import("../layout.zig");
const grid = @import("../grid.zig");
const style_mod = @import("../style.zig");
const ttk_style = @import("../ttk/style.zig");
const ttk_widgets = @import("../ttk/widgets.zig");
const Cursor = @import("../platform/platform.zig").Cursor;
const App = @import("../app.zig").App;
const Spec = options.Spec;
const Widget = widget.Widget;
const Value = ztcl.Value;

const orient_words = [_][]const u8{ "horizontal", "vertical" };

/// The options of `wish` 8.6.16 for `panedwindow`, in its order.
pub const specs = [_]Spec{
    .{ .name = "-background", .db_name = "background", .db_class = "Background", .type = .color, .default = "#d9d9d9", .from_style = true, .style_prop = .background },
    .{ .name = "-bd", .type = .synonym, .target = "-borderwidth" },
    .{ .name = "-bg", .type = .synonym, .target = "-background" },
    .{ .name = "-borderwidth", .db_name = "borderWidth", .db_class = "BorderWidth", .type = .pixels, .default = "1" },
    .{ .name = "-cursor", .db_name = "cursor", .db_class = "Cursor", .type = .string, .allow_empty = true },
    .{ .name = "-handlepad", .db_name = "handlePad", .db_class = "HandlePad", .type = .pixels, .default = "8" },
    .{ .name = "-handlesize", .db_name = "handleSize", .db_class = "HandleSize", .type = .pixels, .default = "8" },
    .{ .name = "-height", .db_name = "height", .db_class = "Height", .type = .pixels, .allow_empty = true },
    .{ .name = "-opaqueresize", .db_name = "opaqueResize", .db_class = "OpaqueResize", .type = .boolean, .default = "1" },
    .{ .name = "-orient", .db_name = "orient", .db_class = "Orient", .type = .word, .default = "horizontal", .words = &orient_words },
    .{ .name = "-proxybackground", .db_name = "proxyBackground", .db_class = "ProxyBackground", .type = .color, .allow_empty = true },
    .{ .name = "-proxyborderwidth", .db_name = "proxyBorderWidth", .db_class = "ProxyBorderWidth", .type = .pixels, .default = "2" },
    .{ .name = "-proxyrelief", .db_name = "proxyRelief", .db_class = "Relief", .type = .relief, .default = "flat" },
    .{ .name = "-relief", .db_name = "relief", .db_class = "Relief", .type = .relief, .default = "flat" },
    .{ .name = "-sashcursor", .db_name = "sashCursor", .db_class = "Cursor", .type = .string, .allow_empty = true },
    .{ .name = "-sashpad", .db_name = "sashPad", .db_class = "SashPad", .type = .pixels, .default = "0" },
    .{ .name = "-sashrelief", .db_name = "sashRelief", .db_class = "Relief", .type = .relief, .default = "flat" },
    .{ .name = "-sashwidth", .db_name = "sashWidth", .db_class = "Width", .type = .pixels, .default = "3" },
    .{ .name = "-showhandle", .db_name = "showHandle", .db_class = "ShowHandle", .type = .boolean, .default = "0" },
    .{ .name = "-width", .db_name = "width", .db_class = "Width", .type = .pixels, .allow_empty = true },
};

const s = ttk_widgets.s;

/// The options of `ttk::panedwindow`, in the order of `wish`.
const ttk_specs = options.withHidden(&[_]Spec{
    .{ .name = "-orient", .db_name = "orient", .db_class = "Orient", .type = .word, .default = "vertical", .words = &orient_words, .create_only = false },
    s("-width", "width", "Width", .pixels, "0"),
    s("-height", "height", "Height", .pixels, "0"),
    ttk_widgets.takefocus_none,
    s("-cursor", "cursor", "Cursor", .string, ""),
    s("-style", "style", "Style", .string, ""),
    .{ .name = "-class", .type = .string, .allow_empty = true, .create_only = true },
}, &specs);

pub const class: widget.Class = .{
    .command = "panedwindow",
    .tk_class = "Panedwindow",
    .role = "group",
    .specs = &specs,
    .init = init,
    .deinit = deinit,
    .configured = configured,
    .measure = measureSelf,
    .paint = paintPaned,
    .subcommand = subcommand,
    .cursor = cursorAt,
};

const ttk_subs = [_][]const u8{ "add", "configure", "cget", "forget", "identify", "insert", "instate", "pane", "panes", "sashpos", "state" };
pub const ttk_class = ttk_widgets.derive(class, "ttk::panedwindow", "TPanedwindow", ttk_specs, &ttk_subs, "*");

const Stretch = enum { always, first, last, middle, never };

const Pane = struct {
    w: *Widget,
    minsize: i32 = 0,
    padx: i32 = 0,
    pady: i32 = 0,
    /// The sides in the order n, e, s, w: bit 0 is n.
    sticky: u4 = 0b1111,
    stretch: Stretch = .last,
    /// `-width` and `-height`, or null. The text is owned.
    width: ?i32 = null,
    height: ?i32 = null,
    width_text: []u8 = &.{},
    height_text: []u8 = &.{},
    hide: bool = false,
    /// `-weight` of `ttk::panedwindow`.
    weight: i64 = 0,
    /// The size along the axis after a sash move, without the padding, or null.
    size: ?i32 = null,
    /// The place of the pane along the axis and its size with the padding, from the last arrange.
    pos: i32 = 0,
    dim: i32 = 0,
    /// The corner of the sash after the pane, and of its handle, from the last arrange.
    sash: [2]i32 = .{ 0, 0 },
    handle: [2]i32 = .{ 0, 0 },
    /// The point of the last `sash mark`.
    mark: [2]i32 = .{ 0, 0 },
};

const Data = struct {
    panes: std.ArrayListUnmanaged(*Pane) = .empty,
    proxy: [2]i32 = .{ 0, 0 },
    proxy_shown: bool = false,
    /// The sash of a drag, and the distance of the pointer from its corner.
    drag: ?usize = null,
    drag_off: i32 = 0,
    /// The sash under the pointer, and the last one, which fades out.
    hot: ?usize = null,
    last_hot: ?usize = null,
    /// The fade of the hot sash: its start and its direction.
    fade_start: i64 = 0,
    fade_in: bool = false,
    fade_from: f32 = 0,
    /// The last arranged size along the axis of a `ttk::panedwindow`.
    last_avail: ?i32 = null,
    sash_part: paint.PartAnim = .{},
};

fn data(w: *const Widget) *Data {
    return @ptrCast(@alignCast(w.data.?));
}

fn init(w: *Widget) anyerror!void {
    const d = try w.app.gpa.create(Data);
    d.* = .{};
    w.data = d;
}

fn freePane(app: *App, p: *Pane) void {
    app.gpa.free(p.width_text);
    app.gpa.free(p.height_text);
    app.gpa.destroy(p);
}

fn deinit(w: *Widget) void {
    const d = data(w);
    for (d.panes.items) |p| freePane(w.app, p);
    d.panes.deinit(w.app.gpa);
    w.app.gpa.destroy(d);
    w.data = null;
}

fn configured(w: *Widget, changed: []const usize) ztcl.Error!void {
    for (changed) |i| {
        const n = w.class.specs[i].name;
        if (std.mem.eql(u8, n, "-orient")) {
            const d = data(w);
            for (d.panes.items) |p| p.size = null;
            d.last_avail = null;
        }
    }
    w.invalidate(.{ .style = false, .measure = true, .layout = true, .paint = true });
}

// ---- Option values ----

fn horizontal(w: *const Widget) bool {
    const v = options.get(w, "-orient").value;
    return v == .word and v.word == 0;
}

fn pix(w: *const Widget, comptime name: []const u8) i32 {
    const v = options.get(w, name).value;
    return if (v == .pixels) v.pixels else 0;
}

fn flag(w: *const Widget, comptime name: []const u8) bool {
    const v = options.get(w, name).value;
    return v == .boolean and v.boolean;
}

fn bw(w: *const Widget) i32 {
    if (w.class.ttk) return 0;
    return @max(pix(w, "-borderwidth"), 0);
}

/// The thickness of a sash of `ttk::panedwindow`, from the default theme of `wish`.
const ttk_sash: i32 = 5;

/// The sash slot, the offset of the sash in it, and the offset of the handle.
const SashGeo = struct { slot: i32, sash_off: i32, handle_off: i32, width: i32, handle: i32 };

fn sashGeo(w: *const Widget) SashGeo {
    if (w.class.ttk) return .{ .slot = ttk_sash, .sash_off = 0, .handle_off = 0, .width = ttk_sash, .handle = 0 };
    const sw: i32 = @max(pix(w, "-sashwidth"), 0);
    const hs: i32 = @max(pix(w, "-handlesize"), 0);
    const pad: i32 = @max(pix(w, "-sashpad"), 0);
    if (flag(w, "-showhandle") and hs > sw) return .{ .slot = hs + 2 * pad, .sash_off = @divTrunc(hs - sw, 2) + pad, .handle_off = pad, .width = sw, .handle = hs };
    return .{ .slot = sw + 2 * pad, .sash_off = pad, .handle_off = @divTrunc(sw - hs, 2) + pad, .width = sw, .handle = hs };
}

/// The size of the pane along the axis with its padding, before a stretch.
fn baseDim(w: *const Widget, p: *const Pane) i32 {
    const hz = horizontal(w);
    if (w.class.ttk) return p.size orelse (if (hz) p.w.req.w else p.w.req.h);
    const content = p.size orelse (if (hz) (p.width orelse p.w.req.w) else (p.height orelse p.w.req.h));
    return content + 2 * (if (hz) p.padx else p.pady);
}

fn crossDim(w: *const Widget, p: *const Pane) i32 {
    if (horizontal(w)) {
        if (w.class.ttk) return p.w.req.h;
        return (p.height orelse p.w.req.h) + 2 * p.pady;
    }
    if (w.class.ttk) return p.w.req.w;
    return (p.width orelse p.w.req.w) + 2 * p.padx;
}

// ---- The geometry manager ----

fn containerData(w: *const Widget) ?*Data {
    if (w.container_manager != &manager) return null;
    return data(w);
}

fn measure(w: *Widget) void {
    layout.setReq(w, reqSize(w));
}

/// The requested size: the panes and the sashes, or `-width` and `-height`.
fn reqSize(w: *Widget) geom.Size {
    const d = data(w);
    const hz = horizontal(w);
    const g = sashGeo(w);
    var along: i32 = 0;
    var cross: i32 = 0;
    var n: i32 = 0;
    for (d.panes.items) |p| {
        if (p.hide) continue;
        // `ttk::panedwindow` asks for the requested sizes, also after a sash move.
        along += if (w.class.ttk) (if (hz) p.w.req.w else p.w.req.h) else baseDim(w, p);
        cross = @max(cross, crossDim(w, p));
        n += 1;
    }
    if (n > 1) along += (n - 1) * g.slot;
    const b = bw(w);
    var size: geom.Size = if (hz) .{ .w = along + 2 * b, .h = cross + 2 * b } else .{ .w = cross + 2 * b, .h = along + 2 * b };
    const ow = options.get(w, "-width");
    const oh = options.get(w, "-height");
    if (ow.value == .pixels and (w.class.ttk and ow.value.pixels > 0 or !w.class.ttk and ow.set and ow.text.len > 0)) size.w = ow.value.pixels;
    if (oh.value == .pixels and (w.class.ttk and oh.value.pixels > 0 or !w.class.ttk and oh.set and oh.text.len > 0)) size.h = oh.value.pixels;
    return size;
}

fn measureSelf(w: *Widget) geom.Size {
    return reqSize(w);
}

fn stretches(st: Stretch, i: usize, first: usize, last: usize) bool {
    return switch (st) {
        .always => true,
        .first => i == first,
        .last => i == last,
        .middle => i > first and i < last,
        .never => false,
    };
}

/// Sets `dim` of each shown pane of a `panedwindow`: its size, changed by the stretch.
fn stretchClassic(w: *Widget, avail: i32) void {
    const d = data(w);
    const g = sashGeo(w);
    var first: ?usize = null;
    var last: usize = 0;
    var total: i32 = 0;
    var n: i32 = 0;
    for (d.panes.items, 0..) |p, i| {
        if (p.hide) continue;
        if (first == null) first = i;
        last = i;
        p.dim = baseDim(w, p);
        total += p.dim;
        n += 1;
    }
    const f = first orelse return;
    if (n > 1) total += (n - 1) * g.slot;
    var reserve: i64 = avail - total;
    if (reserve == 0) return;
    var amount: i64 = 0;
    var count: i64 = 0;
    for (d.panes.items, 0..) |p, i| if (!p.hide and stretches(p.stretch, i, f, last)) {
        amount += p.dim;
        count += 1;
    };
    if (count == 0) return;
    for (d.panes.items, 0..) |p, i| {
        if (p.hide or !stretches(p.stretch, i, f, last)) continue;
        const delta: i64 = if (amount > 0) @divTrunc(reserve * p.dim, amount) else @divTrunc(reserve, count);
        amount -= p.dim;
        count -= 1;
        reserve -= delta;
        p.dim = @intCast(@max(@as(i64, p.dim) + delta, 0));
    }
}

/// Sets `dim` of each pane of a `ttk::panedwindow` from its size and the weights.
fn stretchTtk(w: *Widget, avail: i32) void {
    const d = data(w);
    const panes = d.panes.items;
    if (panes.len == 0) return;
    var total: i32 = @as(i32, @intCast(panes.len - 1)) * ttk_sash;
    var weights: i64 = 0;
    for (panes) |p| {
        p.dim = baseDim(w, p);
        total += p.dim;
        weights += @max(p.weight, 0);
    }
    const delta: i64 = avail - total;
    if (delta == 0) return;
    if (weights == 0) {
        const p = panes[panes.len - 1];
        p.dim = @intCast(@max(@as(i64, p.dim) + delta, 0));
        return;
    }
    // Each weighted pane gets its share, rounded toward zero. The rest goes
    // one pixel at a time to the first weighted panes, or for a smaller
    // widget from the last weighted panes.
    var rest = delta;
    for (panes) |p| if (p.weight > 0) {
        const share = @divTrunc(delta * p.weight, weights);
        rest -= share;
        p.dim = @intCast(@as(i64, p.dim) + share);
    };
    var k: usize = 0;
    while (rest != 0 and k < panes.len) : (k += 1) {
        const p = if (rest > 0) panes[k] else panes[panes.len - 1 - k];
        if (p.weight <= 0) continue;
        p.dim += if (rest > 0) 1 else -1;
        rest += if (rest > 0) -1 else 1;
    }
    for (panes) |p| p.dim = @max(p.dim, 0);
}

fn arrange(w: *Widget) void {
    const d = data(w);
    const hz = horizontal(w);
    const b = bw(w);
    const g = sashGeo(w);
    const avail = @max((if (hz) w.geom.w else w.geom.h) - 2 * b, 0);
    const cross = @max((if (hz) w.geom.h else w.geom.w) - 2 * b, 0);
    if (w.class.ttk) {
        // The first arrange keeps the requested sizes. A later one adds the change of the size.
        if (d.last_avail != null or w.mapped) {
            stretchTtk(w, avail);
        } else {
            for (d.panes.items) |p| p.dim = baseDim(w, p);
        }
        if (w.mapped) d.last_avail = avail;
    } else stretchClassic(w, avail);
    var at = b;
    for (d.panes.items) |p| {
        if (p.hide) {
            layout.setMapped(p.w, false);
            continue;
        }
        p.pos = at;
        const hpad = if (w.class.ttk) 0 else p.padx;
        const vpad = if (w.class.ttk) 0 else p.pady;
        const handle_cross = b + pix(w, "-handlepad");
        if (hz) {
            p.sash = .{ at + p.dim + g.sash_off, b };
            p.handle = .{ at + p.dim + g.handle_off, handle_cross };
        } else {
            p.sash = .{ b, at + p.dim + g.sash_off };
            p.handle = .{ handle_cross, at + p.dim + g.handle_off };
        }
        // The cell of the pane inside its padding.
        var cell: geom.Rect = if (hz)
            .{ .x = at + hpad, .y = b + vpad, .w = p.dim - 2 * hpad, .h = cross - 2 * vpad }
        else
            .{ .x = b + hpad, .y = at + vpad, .w = cross - 2 * hpad, .h = p.dim - 2 * vpad };
        at += p.dim + g.slot;
        // A pane past the end of the widget is cut there.
        const end = b + avail;
        if (hz and cell.x + cell.w > end) cell.w = end - cell.x;
        if (!hz and cell.y + cell.h > end) cell.h = end - cell.y;
        if (cell.w <= 0 or cell.h <= 0) {
            layout.setMapped(p.w, false);
            continue;
        }
        var r = cell;
        if (!w.class.ttk) {
            const rw = p.width orelse p.w.req.w;
            const rh = p.height orelse p.w.req.h;
            const n = p.sticky & 1 != 0;
            const e = p.sticky & 2 != 0;
            const so = p.sticky & 4 != 0;
            const we = p.sticky & 8 != 0;
            if (!(e and we)) {
                r.w = @min(rw, cell.w);
                r.x = if (we) cell.x else if (e) cell.x + cell.w - r.w else cell.x + @divTrunc(cell.w - r.w, 2);
            }
            if (!(n and so)) {
                r.h = @min(rh, cell.h);
                r.y = if (n) cell.y else if (so) cell.y + cell.h - r.h else cell.y + @divTrunc(cell.h - r.h, 2);
            }
        }
        _ = layout.setGeom(p.w, r, w.mapped);
    }
}

fn indexOf(d: *const Data, c: *const Widget) ?usize {
    for (d.panes.items, 0..) |p, i| if (p.w == c) return i;
    return null;
}

fn forgetPane(w: *Widget, i: usize) void {
    const d = data(w);
    const p = d.panes.orderedRemove(i);
    const c = p.w;
    if (c.manager == &manager) {
        c.manager = null;
        c.manager_data = null;
    }
    if (c.alive()) layout.setMapped(c, false);
    freePane(w.app, p);
    if (d.hot) |h| if (h + 1 >= d.panes.items.len) {
        d.hot = null;
    };
    d.drag = null;
    w.invalidate(.{ .style = false, .measure = true, .layout = true, .paint = true });
}

/// The manager forgets a pane widget that is deleted or that another manager takes.
fn forget(c: *Widget) void {
    const w: *Widget = @ptrCast(@alignCast(c.manager_data orelse return));
    c.manager_data = null;
    if (w.data == null) return;
    const i = indexOf(data(w), c) orelse return;
    forgetPane(w, i);
}

fn release(w: *Widget) void {
    if (w.data != null) {
        const d = data(w);
        while (d.panes.items.len > 0) forgetPane(w, d.panes.items.len - 1);
    }
    w.container_manager = null;
    w.container_data = null;
}

fn hasContent(w: *const Widget) bool {
    const d = containerData(w) orelse return false;
    return d.panes.items.len > 0;
}

fn propagates(_: *const Widget) bool {
    return true;
}

pub const manager: layout.Manager = .{ .name = "panedwindow", .measure = measure, .arrange = arrange, .forget = forget, .release = release, .has_content = hasContent, .propagates = propagates };

/// Makes the widget the manager of `c`, at the place `at` of the list.
fn manage(w: *Widget, c: *Widget, at: usize) ztcl.Error!*Pane {
    const it = w.app.it;
    if (w.container_manager != &manager) {
        try layout.claim(w, &manager);
        w.container_manager = &manager;
        w.container_data = w.data;
    }
    if (c.manager) |m| if (m != &manager) m.forget(c);
    const p = try w.app.gpa.create(Pane);
    p.* = .{ .w = c };
    data(w).panes.insert(w.app.gpa, at, p) catch |e| {
        w.app.gpa.destroy(p);
        return e;
    };
    c.manager = &manager;
    c.manager_data = w;
    _ = it;
    w.invalidate(.{ .style = false, .measure = true, .layout = true, .paint = true });
    return p;
}

/// Checks that `c` can be a pane of `w`.
fn checkPane(it: *ztcl.Interp, w: *Widget, c: *Widget) ztcl.Error!void {
    if (w.class.ttk) {
        if (c == w or c.isToplevel() or !grid.isDescendant(w, c.parent.?)) return it.fail("can't add {s} as slave of {s}", .{ c.path, w.path });
        return;
    }
    if (c == w) return it.fail("can't add {s} to itself", .{c.path});
    if (c.isToplevel()) return it.fail("can't add toplevel {s} to {s}", .{ c.path, w.path });
    if (!grid.isDescendant(w, c.parent.?)) return it.fail("can't add {s} to {s}", .{ c.path, w.path });
}

// ---- Sash moves ----

/// Moves sash `i` of a `panedwindow` by `diff` along the axis.
fn moveSash(w: *Widget, i: usize, diff_in: i32) void {
    const d = data(w);
    const hz = horizontal(w);
    // Each shown pane keeps the size that it shows.
    for (d.panes.items) |p| if (!p.hide) {
        p.size = @max(p.dim - 2 * (if (hz) p.padx else p.pady), 0);
    };
    var diff = diff_in;
    if (diff == 0 or i + 1 >= d.panes.items.len) return;
    const panes = d.panes.items;
    // The pane that grows, and the panes that shrink, nearest first.
    if (diff > 0) {
        var room: i32 = 0;
        for (panes[i + 1 ..]) |p| if (!p.hide) {
            room += @max(p.size.? - p.minsize, 0);
        };
        diff = @min(diff, room);
        var left = diff;
        for (panes[i + 1 ..]) |p| {
            if (p.hide or left == 0) continue;
            const take = @min(left, @max(p.size.? - p.minsize, 0));
            p.size = p.size.? - take;
            left -= take;
        }
        var k: usize = i + 1;
        while (k > 0) : (k -= 1) if (!panes[k - 1].hide) {
            panes[k - 1].size = panes[k - 1].size.? + diff;
            break;
        };
    } else {
        var room: i32 = 0;
        for (panes[0 .. i + 1]) |p| if (!p.hide) {
            room += @max(p.size.? - p.minsize, 0);
        };
        diff = -@min(-diff, room);
        var left = -diff;
        var k: usize = i + 1;
        while (k > 0 and left > 0) : (k -= 1) {
            const p = panes[k - 1];
            if (p.hide) continue;
            const take = @min(left, @max(p.size.? - p.minsize, 0));
            p.size = p.size.? - take;
            left -= take;
        }
        for (panes[i + 1 ..]) |p| if (!p.hide) {
            p.size = p.size.? - diff;
            break;
        };
    }
    w.invalidate(.{ .style = false, .measure = true, .layout = true, .paint = true });
}

/// The position of sash `i` along the axis.
fn sashAt(w: *const Widget, i: usize) i32 {
    const p = data(w).panes.items[i];
    return if (horizontal(w)) p.sash[0] else p.sash[1];
}

/// Puts sash `i` at `pos` along the axis.
fn placeSash(w: *Widget, i: usize, pos: i32) i32 {
    if (w.class.ttk) return setSashpos(w, i, pos);
    // The layout of the last change is needed for the shown sizes.
    _ = layout.run(w.toplevel());
    moveSash(w, i, pos - sashAt(w, i));
    _ = layout.run(w.toplevel());
    return sashAt(w, i);
}

/// `sashpos i pos` of a `ttk::panedwindow`: the sash goes between its
/// neighbors, and pushes the sashes on each side that are too near.
fn setSashpos(w: *Widget, i: usize, pos_in: i32) i32 {
    const d = data(w);
    const panes = d.panes.items;
    const n = panes.len;
    const avail = @max(if (horizontal(w)) w.geom.w else w.geom.h, 0);
    const ii: i32 = @intCast(i);
    const after: i32 = @intCast(n - 1 - i);
    const pos = std.math.clamp(pos_in, ii * ttk_sash, @max(avail - after * ttk_sash, ii * ttk_sash));
    // The sash positions now, from the pane sizes.
    var at = std.ArrayListUnmanaged(i32).empty;
    defer at.deinit(w.app.gpa);
    var x: i32 = 0;
    for (panes[0 .. n - 1]) |p| {
        x += p.dim;
        at.append(w.app.gpa, x) catch return pos;
        x += ttk_sash;
    }
    at.items[i] = pos;
    var k = i + 1;
    while (k < n - 1) : (k += 1) at.items[k] = @max(at.items[k], at.items[k - 1] + ttk_sash);
    k = i;
    while (k > 0) : (k -= 1) at.items[k - 1] = @min(at.items[k - 1], at.items[k] - ttk_sash);
    var start: i32 = 0;
    for (panes, 0..) |p, j| {
        const end = if (j + 1 < n) at.items[j] else avail;
        p.size = @max(end - start, 0);
        p.dim = p.size.?;
        start = end + ttk_sash;
    }
    d.last_avail = avail;
    w.invalidate(.{ .style = false, .measure = false, .layout = true, .paint = true });
    return pos;
}

fn ttkSashpos(w: *const Widget, i: usize) i32 {
    const d = data(w);
    // Before the first layout of a shown widget, each sash is at 0, as in `wish`.
    if (d.last_avail == null) return 0;
    var x: i32 = 0;
    for (d.panes.items[0 .. i + 1]) |p| x += p.dim;
    return x + @as(i32, @intCast(i)) * ttk_sash;
}

/// The sash at a point, and whether the point is on its handle.
const Hit = struct { index: usize, handle: bool };

fn hitAt(w: *const Widget, x: i32, y: i32) ?Hit {
    const d = data(w);
    const g = sashGeo(w);
    const hz = horizontal(w);
    if (d.panes.items.len < 2) return null;
    for (d.panes.items[0 .. d.panes.items.len - 1], 0..) |p, i| {
        if (p.hide) continue;
        if (w.class.ttk) {
            const at = ttkSashpos(w, i);
            const v = if (hz) x else y;
            if (v >= at and v < at + ttk_sash) return .{ .index = i, .handle = false };
            continue;
        }
        if (flag(w, "-showhandle") and x >= p.handle[0] and x <= p.handle[0] + g.handle and y >= p.handle[1] and y <= p.handle[1] + g.handle) return .{ .index = i, .handle = true };
        const v = if (hz) x else y;
        const at = if (hz) p.sash[0] else p.sash[1];
        if (v >= at and v <= at + @max(g.width, if (flag(w, "-showhandle")) g.handle else 0)) return .{ .index = i, .handle = false };
    }
    return null;
}

// ---- The pointer shape and the paint ----

fn cursorAt(w: *const Widget) ?Cursor {
    const d = data(w);
    if (d.hot == null and d.drag == null) return null;
    const own = options.maybe(w, "-sashcursor");
    if (own) |slot| if (slot.text.len > 0) if (Cursor.fromTk(slot.text)) |c| return c;
    return if (horizontal(w)) .ew_resize else .ns_resize;
}

const fade_us: i64 = 120_000;

/// The progress of the fade of the hot sash, from 0 to 1.
fn fade(w: *Widget) f32 {
    const d = data(w);
    const app = w.app;
    if (anim.reduced(app)) return if (d.fade_in) 1 else 0;
    const since = app.platform.nowUs() - d.fade_start;
    const lin: f32 = if (since >= fade_us or app.part_end) 1 else @as(f32, @floatFromInt(since)) / @as(f32, @floatFromInt(fade_us));
    if (lin < 1) {
        app.anim_more = true;
        app.notePartMove(d.fade_start, .{ .duration_ms = @intCast(@divTrunc(fade_us, 1000)), .timing = easing.Timing.ease_out }, lin);
    }
    const p = easing.Timing.ease_out.eval(lin);
    return if (d.fade_in) d.fade_from + (1 - d.fade_from) * p else d.fade_from * (1 - p);
}

/// The shown fade of the hot sash, for the tests.
pub fn fadeOf(w: *Widget) f32 {
    return fade(w);
}

fn setHot(w: *Widget, hot: ?usize) void {
    const d = data(w);
    if (std.meta.eql(d.hot, hot)) return;
    const shown = if (d.hot != null) fade(w) else 0;
    if (d.hot != null) d.last_hot = d.hot;
    d.hot = hot;
    d.fade_from = if (hot != null) 0 else shown;
    d.fade_in = hot != null;
    d.fade_start = w.app.platform.nowUs();
    w.invalidate(.{ .style = false, .measure = false, .layout = false, .paint = true });
}

fn sashRect(w: *const Widget, i: usize) geom.Rect {
    const d = data(w);
    const g = sashGeo(w);
    const b = bw(w);
    const hz = horizontal(w);
    const p = d.panes.items[i];
    const at = if (w.class.ttk) ttkSashpos(w, i) else if (hz) p.sash[0] else p.sash[1];
    if (hz) return .{ .x = at, .y = b, .w = g.width, .h = w.geom.h - 2 * b };
    return .{ .x = b, .y = at, .w = w.geom.w - 2 * b, .h = g.width };
}

/// The line in the middle of a sash rectangle.
fn lineOf(r: geom.Rect, hz: bool) geom.Rect {
    if (hz) return .{ .x = r.x + @divTrunc(r.w - 1, 2), .y = r.y, .w = 1, .h = r.h };
    return .{ .x = r.x, .y = r.y + @divTrunc(r.h - 1, 2), .w = r.w, .h = 1 };
}

fn paintPaned(w: *Widget, b: *scene.Builder) anyerror!void {
    const app = w.app;
    const st = anim.shown(app, w);
    try paint.box(w, b, st);
    const d = data(w);
    if (d.panes.items.len < 2) return;
    const hz = horizontal(w);
    const sash = paint.partStyle(w, "sash", &d.sash_part).style;
    const active = app.styles.compute(w, "sash-active", &w.style, app.env);
    const shown_hot = d.drag orelse d.hot;
    const t: f32 = if (d.drag != null) 1 else fade(w);
    // The last hot sash fades out after the pointer leaves it.
    const fading = if (shown_hot == null and t > 0) d.last_hot else shown_hot;
    for (d.panes.items[0 .. d.panes.items.len - 1], 0..) |p, i| {
        if (p.hide) continue;
        var next_shown = false;
        for (d.panes.items[i + 1 ..]) |q| if (!q.hide) {
            next_shown = true;
            break;
        };
        if (!next_shown) break;
        const r = sashRect(w, i);
        const first = b.scene.quads.items.len;
        if (fading != null and fading.? == i and t > 0) {
            const mixed = anim.mix(&sash, &active, t);
            try paint.styledBox(b, r, &mixed);
        } else {
            try paint.styledBox(b, lineOf(r, hz), &sash);
        }
        if (!w.class.ttk and flag(w, "-showhandle")) {
            const g = sashGeo(w);
            try paint.styledBox(b, .{ .x = p.handle[0], .y = p.handle[1], .w = g.handle, .h = g.handle }, &active);
        }
        if (d.drag) |di| if (di == i and opaqueDrag(w)) {
            const at: f32 = @floatFromInt((if (hz) b.off.x + r.x else b.off.y + r.y) + d.drag_off);
            const avail: i32 = if (hz) w.geom.w else w.geom.h;
            const here = if (hz) r.x else r.y;
            try app.addDrag(b, first, if (hz) 0 else 1, false, at, @floatFromInt(-here), @floatFromInt(avail - here));
        };
    }
    if (d.proxy_shown) {
        const g = sashGeo(w);
        const r: geom.Rect = if (hz) .{ .x = d.proxy[0], .y = d.proxy[1], .w = g.width, .h = w.geom.h - 2 * bw(w) } else .{ .x = d.proxy[0], .y = d.proxy[1], .w = w.geom.w - 2 * bw(w), .h = g.width };
        try paint.styledBox(b, r, &active);
    }
}

fn opaqueDrag(w: *const Widget) bool {
    return w.class.ttk or flag(w, "-opaqueresize");
}

// ---- The pane options of `panedwindow` ----

const pane_opts = [_][]const u8{ "-after", "-before", "-height", "-hide", "-minsize", "-padx", "-pady", "-sticky", "-stretch", "-width" };
const stretch_words = [_][]const u8{ "always", "first", "last", "middle", "never" };

fn parseSticky(it: *ztcl.Interp, text: []const u8) ztcl.Error!u4 {
    var v: u4 = 0;
    for (text) |c| switch (c) {
        'n', 'N' => v |= 1,
        'e', 'E' => v |= 2,
        's', 'S' => v |= 4,
        'w', 'W' => v |= 8,
        ' ', ',', '\t' => {},
        else => return it.fail("bad stickyness value \"{s}\": must be a string containing zero or more of n, e, s, and w", .{text}),
    };
    return v;
}

fn stickyText(a: std.mem.Allocator, v: u4) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    if (v & 1 != 0) try out.append(a, 'n');
    if (v & 2 != 0) try out.append(a, 'e');
    if (v & 4 != 0) try out.append(a, 's');
    if (v & 8 != 0) try out.append(a, 'w');
    return out.items;
}

fn parsePix(it: *ztcl.Interp, app: *App, text: []const u8) ztcl.Error!i32 {
    return options.parsePixels(text, app.scaling) orelse it.fail("bad screen distance \"{s}\"", .{text});
}

/// The parsed pane options of one command, before they change a pane.
const PaneOpts = struct {
    after: ?*Widget = null,
    before: ?*Widget = null,
    height: ?[]const u8 = null,
    width: ?[]const u8 = null,
    hide: ?bool = null,
    minsize: ?i32 = null,
    padx: ?i32 = null,
    pady: ?i32 = null,
    sticky: ?u4 = null,
    stretch: ?Stretch = null,
};

fn optIndex(it: *ztcl.Interp, name: []const u8) ztcl.Error!usize {
    for (pane_opts, 0..) |o, i| if (std.mem.eql(u8, o, name)) return i;
    var found: ?usize = null;
    for (pane_opts, 0..) |o, i| if (name.len > 1 and std.mem.startsWith(u8, o, name)) {
        if (found != null) return it.fail("unknown option \"{s}\"", .{name});
        found = i;
    };
    return found orelse it.fail("unknown option \"{s}\"", .{name});
}

fn parsePaneOpts(it: *ztcl.Interp, w: *Widget, args: []const Value) ztcl.Error!PaneOpts {
    const app = w.app;
    var o: PaneOpts = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        const name = try it.str(args[i]);
        const k = try optIndex(it, name);
        if (i + 1 >= args.len) return it.fail("value for \"{s}\" missing", .{name});
        const text = try it.str(args[i + 1]);
        switch (k) {
            0, 1 => {
                const ref: ?*Widget = if (text.len == 0) null else app.find(text) orelse return it.fail("bad window path name \"{s}\"", .{text});
                if (k == 0) o.after = ref else o.before = ref;
            },
            2 => o.height = text,
            3 => o.hide = options.parseBool(text) orelse return it.fail("expected boolean value but got \"{s}\"", .{text}),
            4 => o.minsize = try parsePix(it, app, text),
            5 => o.padx = try parsePix(it, app, text),
            6 => o.pady = try parsePix(it, app, text),
            7 => o.sticky = try parseSticky(it, text),
            8 => o.stretch = std.meta.stringToEnum(Stretch, text) orelse return it.fail("bad stretch \"{s}\": must be always, first, last, middle, or never", .{text}),
            9 => o.width = text,
            else => unreachable,
        }
    }
    if (o.width) |t| if (t.len > 0) {
        _ = try parsePix(it, app, t);
    };
    if (o.height) |t| if (t.len > 0) {
        _ = try parsePix(it, app, t);
    };
    return o;
}

fn setText(app: *App, slot: *[]u8, v: *?i32, text: []const u8) !void {
    const copy = try app.gpa.dupe(u8, text);
    app.gpa.free(slot.*);
    slot.* = copy;
    v.* = if (text.len == 0) null else options.parsePixels(text, app.scaling);
}

fn applyPaneOpts(w: *Widget, p: *Pane, o: PaneOpts) !void {
    const app = w.app;
    if (o.minsize) |v| p.minsize = @max(v, 0);
    if (o.padx) |v| p.padx = @max(v, 0);
    if (o.pady) |v| p.pady = @max(v, 0);
    if (o.sticky) |v| p.sticky = v;
    if (o.stretch) |v| p.stretch = v;
    if (o.hide) |v| p.hide = v;
    if (o.width) |t| {
        try setText(app, &p.width_text, &p.width, t);
        if (horizontal(w)) p.size = null;
    }
    if (o.height) |t| {
        try setText(app, &p.height_text, &p.height, t);
        if (!horizontal(w)) p.size = null;
    }
    w.invalidate(.{ .style = false, .measure = true, .layout = true, .paint = true });
}

/// Moves pane `p` next to `o.after` or `o.before` when one is given.
fn reorder(w: *Widget, p: *Pane, o: PaneOpts) void {
    const ref = o.after orelse o.before orelse return;
    const d = data(w);
    if (ref == p.w) return;
    const ri = indexOf(d, ref) orelse return;
    const pi = indexOf(d, p.w).?;
    _ = d.panes.orderedRemove(pi);
    const ri2 = indexOf(d, ref) orelse ri;
    const at = if (o.after != null) ri2 + 1 else ri2;
    d.panes.insertAssumeCapacity(at, p);
}

fn paneText(a: std.mem.Allocator, p: *const Pane, k: usize) ![]const u8 {
    return switch (k) {
        0, 1 => "",
        2 => p.height_text,
        3 => if (p.hide) "1" else "0",
        4 => try std.fmt.allocPrint(a, "{d}", .{p.minsize}),
        5 => try std.fmt.allocPrint(a, "{d}", .{p.padx}),
        6 => try std.fmt.allocPrint(a, "{d}", .{p.pady}),
        7 => try stickyText(a, p.sticky),
        8 => @tagName(p.stretch),
        9 => p.width_text,
        else => unreachable,
    };
}

fn paneEntry(it: *ztcl.Interp, p: *const Pane, k: usize) ztcl.Error!Value {
    const a = it.alloc();
    const name = pane_opts[k];
    const val = try paneText(a, p, k);
    const dflt: []const u8 = switch (k) {
        3, 4, 5, 6 => "0",
        7 => "nsew",
        8 => "last",
        else => "",
    };
    const db: [2][]const u8 = switch (k) {
        3 => .{ "hide", "Hide" },
        8 => .{ "stretch", "Stretch" },
        else => .{ "", "" },
    };
    const items = [_]Value{ .{ .str = name }, .{ .str = db[0] }, .{ .str = db[1] }, .{ .str = dflt }, .{ .str = val } };
    return ztcl.value.newList(a, &items);
}

fn paneValue(it: *ztcl.Interp, p: *const Pane, k: usize) ztcl.Error!Value {
    return .{ .str = try paneText(it.alloc(), p, k) };
}

// ---- The subcommands ----

const classic_subs = [_][]const u8{ "add", "cget", "configure", "forget", "identify", "panecget", "paneconfigure", "panes", "proxy", "sash" };

fn subcommand(w: *Widget, it: *ztcl.Interp, argv: []const Value) ztcl.Error!?Value {
    if (w.class.ttk) return try ttkSub(w, it, argv);
    const app = w.app;
    const d = data(w);
    const k = try ttk_style.pick(it, try it.str(argv[1]), &classic_subs, "bad command");
    const a = it.alloc();
    switch (k) {
        0 => {
            if (argv.len < 3) return it.fail("wrong # args: should be \"{s} add widget ?widget ...?\"", .{w.path});
            var n: usize = 2;
            while (n < argv.len) : (n += 1) {
                const t = try it.str(argv[n]);
                if (t.len > 0 and t[0] == '-') break;
            }
            const o = try parsePaneOpts(it, w, argv[n..]);
            for (argv[2..n]) |v| {
                const c = app.find(try it.str(v)) orelse return it.fail("bad window path name \"{s}\"", .{try it.str(v)});
                try checkPane(it, w, c);
            }
            var last: ?*Widget = null;
            for (argv[2..n]) |v| {
                const c = app.find(try it.str(v)).?;
                var opts = o;
                // The windows of one command go in order after the first.
                if (last) |l| {
                    opts.after = l;
                    opts.before = null;
                }
                const p = if (indexOf(d, c)) |i| d.panes.items[i] else blk: {
                    const at = d.panes.items.len;
                    break :blk try manage(w, c, at);
                };
                try applyPaneOpts(w, p, opts);
                try d.panes.ensureUnusedCapacity(app.gpa, 1);
                reorder(w, p, opts);
                last = c;
            }
            return Value.empty;
        },
        3 => {
            if (argv.len < 3) return it.fail("wrong # args: should be \"{s} forget widget ?widget ...?\"", .{w.path});
            for (argv[2..]) |v| {
                const c = app.find(try it.str(v)) orelse return it.fail("bad window path name \"{s}\"", .{try it.str(v)});
                if (indexOf(d, c)) |i| forgetPane(w, i);
            }
            return Value.empty;
        },
        4 => {
            if (argv.len != 4) return it.fail("wrong # args: should be \"{s} identify x y\"", .{w.path});
            _ = layout.run(w.toplevel());
            const hit = hitAt(w, @intCast(std.math.clamp(try it.int(argv[2]), -1 << 24, 1 << 24)), @intCast(std.math.clamp(try it.int(argv[3]), -1 << 24, 1 << 24))) orelse return Value.empty;
            const items = [_]Value{ .{ .int = @intCast(hit.index) }, .{ .str = if (hit.handle) "handle" else "sash" } };
            return try ztcl.value.newList(a, &items);
        },
        5 => {
            if (argv.len != 4) return it.fail("wrong # args: should be \"{s} panecget pane option\"", .{w.path});
            const path = try it.str(argv[2]);
            const c = app.find(path) orelse return it.fail("bad window path name \"{s}\"", .{path});
            const i = indexOf(d, c) orelse return it.fail("not managed by this window", .{});
            const name = try it.str(argv[3]);
            const opt = optIndex(it, name) catch return it.fail("not managed by this window", .{});
            return try paneValue(it, d.panes.items[i], opt);
        },
        6 => {
            if (argv.len < 3) return it.fail("wrong # args: should be \"{s} paneconfigure pane ?option? ?value option value ...?\"", .{w.path});
            const path = try it.str(argv[2]);
            const c = app.find(path) orelse return it.fail("bad window path name \"{s}\"", .{path});
            const i = indexOf(d, c) orelse return it.fail("not managed by this window", .{});
            const p = d.panes.items[i];
            if (argv.len == 3) {
                var out: [pane_opts.len]Value = undefined;
                for (&out, 0..) |*slot, j| slot.* = try paneEntry(it, p, j);
                return try ztcl.value.newList(a, &out);
            }
            if (argv.len == 4) return try paneEntry(it, p, try optIndex(it, try it.str(argv[3])));
            const o = try parsePaneOpts(it, w, argv[3..]);
            try applyPaneOpts(w, p, o);
            try d.panes.ensureUnusedCapacity(app.gpa, 1);
            reorder(w, p, o);
            return Value.empty;
        },
        7 => {
            var out: std.ArrayListUnmanaged(Value) = .empty;
            for (d.panes.items) |p| try out.append(a, .{ .str = p.w.path });
            return try ztcl.value.newList(a, out.items);
        },
        8 => return try proxyCmd(w, it, argv),
        9 => return try sashCmd(w, it, argv),
        else => return null,
    }
}

fn coordArg(it: *ztcl.Interp, v: Value) ztcl.Error!i32 {
    return @intCast(std.math.clamp(try it.int(v), -1 << 24, 1 << 24));
}

fn pair(it: *ztcl.Interp, x: i32, y: i32) ztcl.Error!Value {
    const items = [_]Value{ .{ .int = x }, .{ .int = y } };
    return ztcl.value.newList(it.alloc(), &items);
}

fn proxyCmd(w: *Widget, it: *ztcl.Interp, argv: []const Value) ztcl.Error!Value {
    if (argv.len < 3) return it.fail("wrong # args: should be \"{s} proxy option ?arg ...?\"", .{w.path});
    const d = data(w);
    const subs = [_][]const u8{ "coord", "forget", "place" };
    switch (try ttk_style.pick(it, try it.str(argv[2]), &subs, "bad option")) {
        0 => {
            if (argv.len != 3) return it.fail("wrong # args: should be \"{s} proxy coord\"", .{w.path});
            return try pair(it, d.proxy[0], d.proxy[1]);
        },
        1 => {
            if (argv.len != 3) return it.fail("wrong # args: should be \"{s} proxy forget\"", .{w.path});
            d.proxy_shown = false;
        },
        else => {
            if (argv.len != 5) return it.fail("wrong # args: should be \"{s} proxy place x y\"", .{w.path});
            proxyPlace(w, try coordArg(it, argv[3]), try coordArg(it, argv[4]));
        },
    }
    w.invalidate(.{ .style = false, .measure = false, .layout = false, .paint = true });
    return Value.empty;
}

fn proxyPlace(w: *Widget, x: i32, y: i32) void {
    const d = data(w);
    const b = bw(w);
    const sw = sashGeo(w).width;
    if (horizontal(w)) {
        d.proxy = .{ std.math.clamp(x, 0, @max(w.geom.w - sw, 0)), b };
    } else {
        d.proxy = .{ b, std.math.clamp(y, 0, @max(w.geom.h - sw, 0)) };
    }
    d.proxy_shown = true;
    w.invalidate(.{ .style = false, .measure = false, .layout = false, .paint = true });
}

fn sashIndex(w: *Widget, it: *ztcl.Interp, v: Value) ztcl.Error!usize {
    const i = try it.int(v);
    const n = data(w).panes.items.len;
    if (i < 0 or n < 2 or i >= n - 1) return it.fail("invalid sash index", .{});
    return @intCast(i);
}

fn sashCmd(w: *Widget, it: *ztcl.Interp, argv: []const Value) ztcl.Error!Value {
    if (argv.len < 3) return it.fail("wrong # args: should be \"{s} sash option ?arg ...?\"", .{w.path});
    const d = data(w);
    const subs = [_][]const u8{ "coord", "dragto", "mark", "place" };
    const k = try ttk_style.pick(it, try it.str(argv[2]), &subs, "bad option");
    switch (k) {
        0 => {
            if (argv.len != 4) return it.fail("wrong # args: should be \"{s} sash coord index\"", .{w.path});
            const i = try sashIndex(w, it, argv[3]);
            _ = layout.run(w.toplevel());
            const p = d.panes.items[i];
            return try pair(it, p.sash[0], p.sash[1]);
        },
        2 => {
            if (argv.len != 4 and argv.len != 6) return it.fail("wrong # args: should be \"{s} sash mark index ?x y?\"", .{w.path});
            const i = try sashIndex(w, it, argv[3]);
            const p = d.panes.items[i];
            if (argv.len == 4) return try pair(it, p.mark[0], p.mark[1]);
            p.mark = .{ try coordArg(it, argv[4]), try coordArg(it, argv[5]) };
            return Value.empty;
        },
        else => {
            if (argv.len != 6) return it.fail("wrong # args: should be \"{s} sash {s} index x y\"", .{ w.path, subs[k] });
            const i = try sashIndex(w, it, argv[3]);
            const x = try coordArg(it, argv[4]);
            const y = try coordArg(it, argv[5]);
            const p = d.panes.items[i];
            const hz = horizontal(w);
            if (k == 1) {
                const diff = if (hz) x - p.mark[0] else y - p.mark[1];
                _ = layout.run(w.toplevel());
                moveSash(w, i, diff);
                p.mark = .{ x, y };
            } else {
                _ = placeSash(w, i, if (hz) x else y);
            }
            return Value.empty;
        },
    }
}

// ---- The subcommands of `ttk::panedwindow` ----

fn paneArg(w: *Widget, it: *ztcl.Interp, v: Value, insert: bool) ztcl.Error!usize {
    const d = data(w);
    const t = try it.str(v);
    const n = d.panes.items.len;
    if (std.mem.eql(u8, t, "end")) return n;
    if (t.len > 0 and t[0] == '.') {
        const c = w.app.find(t) orelse return it.fail("Invalid slave specification {s}", .{t});
        return indexOf(d, c) orelse it.fail("{s} is not managed by {s}", .{ t, w.path });
    }
    const i = std.fmt.parseInt(i64, t, 10) catch return it.fail("Invalid slave specification {s}", .{t});
    if (i < 0 or i > n or (!insert and i == n)) return it.fail("Slave index {s} out of bounds", .{t});
    return @intCast(i);
}

fn ttkPaneOpts(w: *Widget, it: *ztcl.Interp, p: ?*Pane, args: []const Value) ztcl.Error!?i64 {
    _ = w;
    _ = p;
    var weight: ?i64 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        const name = try it.str(args[i]);
        if (!(name.len > 1 and std.mem.startsWith(u8, "-weight", name))) return it.fail("unknown option \"{s}\"", .{name});
        if (i + 1 >= args.len) return it.fail("value for \"{s}\" missing", .{name});
        weight = try it.int(args[i + 1]);
    }
    return weight;
}

fn ttkSub(w: *Widget, it: *ztcl.Interp, argv: []const Value) ztcl.Error!?Value {
    const app = w.app;
    const d = data(w);
    const name = try it.str(argv[1]);
    const a = it.alloc();
    if (std.mem.eql(u8, name, "add") or std.mem.eql(u8, name, "insert")) {
        const ins = name[0] == 'i';
        const first: usize = if (ins) 3 else 2;
        if (argv.len < first + 1 or (argv.len - first - 1) % 2 != 0) {
            if (ins) return it.fail("wrong # args: should be \"{s} insert index slave ?-option value ...?\"", .{w.path});
            return it.fail("wrong # args: should be \"{s} add window\"", .{w.path});
        }
        const path = try it.str(argv[first]);
        const c = app.find(path) orelse return it.fail("bad window path name \"{s}\"", .{path});
        try checkPane(it, w, c);
        const weight = try ttkPaneOpts(w, it, null, argv[first + 1 ..]);
        if (!ins) {
            if (indexOf(d, c) != null) return it.fail("{s} already added", .{path});
            const p = try manage(w, c, d.panes.items.len);
            if (weight) |v| p.weight = v;
            return Value.empty;
        }
        var at = try paneArg(w, it, argv[2], true);
        if (indexOf(d, c)) |old| {
            const p = d.panes.orderedRemove(old);
            if (at > old) at -= 1;
            d.panes.insertAssumeCapacity(@min(at, d.panes.items.len), p);
            if (weight) |v| p.weight = v;
            w.invalidate(.{ .style = false, .measure = true, .layout = true, .paint = true });
            return Value.empty;
        }
        const p = try manage(w, c, @min(at, d.panes.items.len));
        if (weight) |v| p.weight = v;
        return Value.empty;
    }
    if (std.mem.eql(u8, name, "forget")) {
        if (argv.len != 3) return it.fail("wrong # args: should be \"{s} forget pane\"", .{w.path});
        forgetPane(w, try paneArg(w, it, argv[2], false));
        return Value.empty;
    }
    if (std.mem.eql(u8, name, "pane")) {
        if (argv.len < 3) return it.fail("wrong # args: should be \"{s} pane pane ?-option value ...?\"", .{w.path});
        const p = d.panes.items[try paneArg(w, it, argv[2], false)];
        if (argv.len == 3) {
            const items = [_]Value{ .{ .str = "-weight" }, .{ .int = p.weight } };
            return try ztcl.value.newList(a, &items);
        }
        if (argv.len == 4) {
            _ = try ttkPaneOpts(w, it, p, &.{ argv[3], .{ .str = "0" } });
            return .{ .int = p.weight };
        }
        if (try ttkPaneOpts(w, it, p, argv[3..])) |v| p.weight = v;
        w.invalidate(.{ .style = false, .measure = false, .layout = true, .paint = true });
        return Value.empty;
    }
    if (std.mem.eql(u8, name, "panes")) {
        if (argv.len != 2) return it.fail("wrong # args: should be \"{s} panes \"", .{w.path});
        var out: std.ArrayListUnmanaged(Value) = .empty;
        for (d.panes.items) |p| try out.append(a, .{ .str = p.w.path });
        return try ztcl.value.newList(a, out.items);
    }
    if (std.mem.eql(u8, name, "sashpos")) {
        if (argv.len != 3 and argv.len != 4) return it.fail("wrong # args: should be \"{s} sashpos index ?newpos?\"", .{w.path});
        const i = try it.int(argv[2]);
        if (i < 0 or d.panes.items.len < 2 or i >= d.panes.items.len - 1) return it.fail("sash index {d} out of range", .{i});
        const idx: usize = @intCast(i);
        if (argv.len == 3) return .{ .int = ttkSashpos(w, idx) };
        return .{ .int = setSashpos(w, idx, try coordArg(it, argv[3])) };
    }
    if (std.mem.eql(u8, name, "identify")) {
        if (argv.len != 4 and argv.len != 5) return it.fail("wrong # args: should be \"{s} identify ?what? x y\"", .{w.path});
        var element = false;
        if (argv.len == 5) {
            const what = [_][]const u8{ "element", "sash" };
            element = try ttk_style.pick(it, try it.str(argv[2]), &what, "bad option") == 0;
        }
        const hit = hitAt(w, try coordArg(it, argv[argv.len - 2]), try coordArg(it, argv[argv.len - 1])) orelse return Value.empty;
        if (element) return .{ .str = if (horizontal(w)) "hsash" else "vsash" };
        return .{ .int = @intCast(hit.index) };
    }
    return null;
}

// ---- The bindings ----

const Action = enum { press, motion, release, hover, leave };

/// `::ztk::priv::paned action path ?x y?`
fn cmdPaned(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    app.enter();
    defer app.leave();
    if (argv.len < 3) return it.wrongArgs("::ztk::priv::paned action window ?x y?");
    const act = std.meta.stringToEnum(Action, try it.str(argv[1])) orelse return it.fail("bad action", .{});
    const w = app.find(try it.str(argv[2])) orelse return Value.empty;
    if (w.class.paint != paintPaned) return Value.empty;
    const d = data(w);
    const hz = horizontal(w);
    var x: i32 = 0;
    var y: i32 = 0;
    if (argv.len >= 5) {
        x = try coordArg(it, argv[3]);
        y = try coordArg(it, argv[4]);
    }
    const along = if (hz) x else y;
    switch (act) {
        .press => {
            const hit = hitAt(w, x, y) orelse return Value.empty;
            const i = hit.index;
            const at = if (w.class.ttk) ttkSashpos(w, i) else sashAt(w, i);
            d.drag = i;
            d.drag_off = along - at;
            if (!opaqueDrag(w)) proxyPlace(w, if (hz) at else 0, if (hz) 0 else at);
            setHot(w, i);
        },
        .motion => {
            const i = d.drag orelse {
                setHot(w, if (hitAt(w, x, y)) |h| h.index else null);
                return Value.empty;
            };
            const pos = along - d.drag_off;
            if (opaqueDrag(w)) {
                _ = placeSash(w, i, pos);
            } else proxyPlace(w, if (hz) pos else 0, if (hz) 0 else pos);
        },
        .release => {
            const i = d.drag orelse return Value.empty;
            if (!opaqueDrag(w)) {
                _ = placeSash(w, i, if (hz) d.proxy[0] else d.proxy[1]);
                d.proxy_shown = false;
            }
            d.drag = null;
            setHot(w, if (hitAt(w, x, y)) |h| h.index else null);
            w.invalidate(.{ .style = false, .measure = false, .layout = false, .paint = true });
        },
        .hover => if (d.drag == null) setHot(w, if (hitAt(w, x, y)) |h| h.index else null),
        .leave => if (d.drag == null) setHot(w, null),
    }
    return Value.empty;
}

pub fn register(app: *App) !void {
    const it = app.it;
    try it.register("panedwindow", widget.classCommand(&class));
    try app.classes.put(app.gpa, "panedwindow", &class);
    try it.register("ttk::panedwindow", widget.classCommand(&ttk_class));
    try app.classes.put(app.gpa, "ttk::panedwindow", &ttk_class);
    try it.register("ztk::priv::paned", cmdPaned);
    _ = try it.eval(
        \\foreach ztk_class {Panedwindow TPanedwindow} {
        \\    bind $ztk_class <Button-1> {::ztk::priv::paned press %W %x %y}
        \\    bind $ztk_class <B1-Motion> {::ztk::priv::paned motion %W %x %y}
        \\    bind $ztk_class <ButtonRelease-1> {::ztk::priv::paned release %W %x %y}
        \\    bind $ztk_class <Motion> {::ztk::priv::paned hover %W %x %y}
        \\    bind $ztk_class <Leave> {::ztk::priv::paned leave %W}
        \\}
        \\bind Panedwindow <Button-2> {::ztk::priv::paned press %W %x %y}
        \\bind Panedwindow <B2-Motion> {::ztk::priv::paned motion %W %x %y}
        \\bind Panedwindow <ButtonRelease-2> {::ztk::priv::paned release %W %x %y}
        \\unset ztk_class
    );
}
