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
const debug = @import("debug.zig");
const ztcl = @import("ztcl");
const num = @import("base/num.zig");
const geom = @import("base/geom.zig");
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
    /// The container of a managed widget. It differs from the parent
    /// after `-in`.
    container_of: ?*const fn (w: *const Widget) ?*Widget = null,
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

/// Makes the requested size of a widget current now, as Tk does when a
/// widget is configured: `winfo reqwidth` right after a widget is made
/// gives its size.
pub fn measureNow(w: *Widget) void {
    measureNode(w);
}

fn measureNode(w: *Widget) void {
    if (!w.dirty.measure) return;
    // A widget that is packed `-in` a sibling marks that sibling again
    // when its size changes, so the loop measures the children again.
    var rounds: u8 = 0;
    while (rounds < 8) : (rounds += 1) {
        for (w.children.items) |c| measureNode(c);
        var again = false;
        for (w.children.items) |c| again = again or c.dirty.measure;
        if (!again) break;
    }
    w.dirty.measure = false;
    const old = w.req;
    var size: geom.Size = .{};
    if (w.class.measure) |f| size = f(w);
    // As in Tk, a container with content, with propagation off, and with
    // no size of its own makes no request. It keeps the requested size
    // that it had when the propagation went off.
    if (size.w > 0 or size.h > 0 or !hasContent(w) or propagates(w)) setReq(w, size);
    if (w.container_manager) |m| m.measure(w);
    if (w.req.w != old.w or w.req.h != old.h) {
        w.dirty.layout = true;
        if (w.parent) |p| {
            p.dirty.measure = true;
            p.dirty.layout = true;
        }
        // The container after `-in` can be a deeper widget than the
        // parent: the path from it up to the parent needs a measure.
        if (w.manager) |m| if (m.container_of) |f| if (f(w)) |c| if (c != w.parent) {
            c.dirty.layout = true;
            var x: ?*Widget = c;
            while (x) |y| : (x = y.parent) {
                if (y == w.parent) break;
                y.dirty.measure = true;
            }
        };
    }
}

fn arrangeNode(w: *Widget, changed: *bool) void {
    if (w.dirty.layout) {
        w.dirty.layout = false;
        if (w.container_manager) |m| {
            const before = if (w.app.dbg.trace.mask != 0) debug.boxesBefore(w) else debug.Boxes{};
            m.arrange(w);
            if (w.app.dbg.trace.mask != 0) debug.arranged(w, m.name, before);
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
