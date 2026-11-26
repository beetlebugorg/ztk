//! The layout pass. A geometry manager has three functions: `measure`
//! sets the requested size of a container from its content, `arrange`
//! sets the geometry of the content, and `forget` ends the management of
//! one widget. `run` measures bottom-up for each widget with the measure
//! flag, then arranges top-down for each widget with the layout flag. A
//! requested size is at least 1 by 1, as in Tk. `setGeom` is the one
//! place that changes the geometry of a managed widget, so it can flag
//! the widget for its own layout and paint.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const num = @import("num.zig");
const geom = @import("geom.zig");
const widget = @import("widget.zig");
const paint = @import("paint.zig");
const grid = @import("grid.zig");
const pack = @import("pack.zig");
const place = @import("place.zig");
const Widget = widget.Widget;

pub const Manager = struct {
    /// The result of `winfo manager`.
    name: []const u8,
    /// Sets the requested size of the container from its content.
    measure: *const fn (container: *Widget) void,
    /// Sets `geom` and `mapped` of each managed widget of the container.
    arrange: *const fn (container: *Widget) void,
    /// The manager stops managing the widget (it is deleted, or another
    /// manager gets it).
    forget: *const fn (w: *Widget) void,
    /// The container is deleted. The manager frees its data and lets go of
    /// the content that still exists.
    release: *const fn (container: *Widget) void,
    /// True when the container has managed content.
    has_content: ?*const fn (container: *const Widget) bool = null,
    /// True when the content sets the requested size of the container.
    propagates: ?*const fn (container: *const Widget) bool = null,
};

/// The space that the border and the padding of a container take, in
/// whole logical pixels. The content goes inside it.
pub fn insets(c: *Widget) geom.Insets {
    c.app.ensureStyle(c);
    var i = paint.insets(&c.style);
    if (c.class.extra_insets) |f| {
        const e = f(c);
        i.top += e.top;
        i.right += e.right;
        i.bottom += e.bottom;
        i.left += e.left;
    }
    return i;
}

/// Stores the requested size. The size is at least 1 by 1. A manager
/// calls it from `measure`. `run` compares the result with the old size.
pub fn setReq(w: *Widget, size: geom.Size) void {
    w.req = .{ .w = std.math.clamp(size.w, 1, num.max_px), .h = std.math.clamp(size.h, 1, num.max_px) };
}

/// Sets the geometry and the mapped flag of a managed widget. A change
/// flags the widget for layout, so its own content follows, and flags the
/// paint of the toplevel.
pub fn setGeom(w: *Widget, r: geom.Rect, mapped: bool) bool {
    const same = w.geom.x == r.x and w.geom.y == r.y and w.geom.w == r.w and w.geom.h == r.h and w.mapped == mapped;
    if (same) return false;
    w.geom = r;
    w.mapped = mapped;
    w.dirty.layout = true;
    w.toplevel().dirty.paint = true;
    return true;
}

/// `setGeom` for a rectangle in the coordinates of `container`. A widget
/// is placed in its parent, so the offsets of the container and of its
/// ancestors below the parent are added, as for `pack -in` a sibling.
pub fn setGeomIn(container: *const Widget, w: *Widget, r: geom.Rect, mapped: bool) bool {
    var x = r.x;
    var y = r.y;
    var p: ?*const Widget = container;
    const parent = w.parent orelse return setGeom(w, r, mapped);
    while (p) |q| : (p = q.parent) {
        if (q == parent) break;
        x +|= q.geom.x;
        y +|= q.geom.y;
    }
    return setGeom(w, .{ .x = x, .y = y, .w = r.w, .h = r.h }, mapped);
}

/// Sets the mapped flag only.
pub fn setMapped(w: *Widget, mapped: bool) void {
    if (w.mapped == mapped) return;
    w.mapped = mapped;
    w.dirty.layout = true;
    w.toplevel().dirty.paint = true;
}

fn measureNode(w: *Widget) void {
    if (!w.dirty.measure) return;
    for (w.children.items) |c| measureNode(c);
    w.dirty.measure = false;
    const old = w.req;
    var size: geom.Size = .{};
    if (w.class.measure) |f| size = f(w);
    setReq(w, size);
    if (w.container_manager) |m| m.measure(w);
    if (w.req.w != old.w or w.req.h != old.h) {
        w.dirty.layout = true;
        if (w.parent) |p| {
            p.dirty.measure = true;
            p.dirty.layout = true;
        }
    }
}

fn arrangeNode(w: *Widget, changed: *bool) void {
    if (w.dirty.layout) {
        w.dirty.layout = false;
        if (w.container_manager) |m| {
            m.arrange(w);
            w.app.arrange_count += 1;
            changed.* = true;
        }
        if (w.placed.items.len > 0) {
            place.arrange(w);
            changed.* = true;
        }
    }
    for (w.children.items) |c| arrangeNode(c, changed);
}

/// Measures bottom-up and arranges top-down, for the widgets with the
/// measure or layout flag. Returns true when an arrange ran.
pub fn run(top: *Widget) bool {
    measureNode(top);
    var changed = false;
    arrangeNode(top, &changed);
    return changed;
}

/// True when the manager of the container has content in it.
pub fn hasContent(w: *const Widget) bool {
    if (w.container_manager) |m| if (m.has_content) |f| return f(w);
    return false;
}

/// True when the content of the container sets its requested size.
pub fn propagates(w: *const Widget) bool {
    if (!hasContent(w)) return false;
    if (w.container_manager) |m| if (m.propagates) |f| return f(w);
    return true;
}

/// Makes `m` the manager of the content of `c`. Another manager with
/// content in `c` gives the message of `wish`. Another manager with no
/// content lets go of `c` first.
pub fn claim(c: *Widget, m: *const Manager) ztcl.Error!void {
    const old = c.container_manager orelse return;
    if (old == m) return;
    if (hasContent(c)) return c.app.it.fail("cannot use geometry manager {s} inside {s} which already has slaves managed by {s}", .{ m.name, c.path, old.name });
    old.release(c);
}

/// Called when a widget is deleted: the manager forgets the widget, and
/// a container gives up its content.
pub fn destroyed(w: *Widget) void {
    if (w.manager) |m| m.forget(w);
    grid.dropCell(w);
    pack.dropData(w);
    place.dropData(w);
    if (w.container_manager) |m| m.release(w);
    place.releaseContainer(w);
}
