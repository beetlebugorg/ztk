//! Checks of the widgets of a toplevel after a frame. They find text that
//! does not fit its widget, a text color with too little contrast on its
//! background, a widget that sticks out of the window, and a widget with
//! text and no size. The contrast is the WCAG 2 ratio of relative
//! luminance. The check of clipped text compares the measured text size
//! with the content rectangle of the widget, because the scene has no
//! link from a glyph to its widget.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const geom = @import("base/geom.zig");
const paint = @import("paint.zig");
const widget_mod = @import("widget.zig");
const anim = @import("anim.zig");
const label = @import("widgets/label.zig");
const Widget = widget_mod.Widget;

pub const Problem = struct {
    path: []const u8,
    kind: enum { text_clipped, low_contrast, outside_window, zero_size },
    detail: []const u8,
};

pub const Options = struct {
    /// The lowest contrast ratio of a text color on its background.
    min_contrast: f32 = 4.5,
    /// Classes whose text can be clipped on purpose (a scrolled entry).
    clip_ok: []const []const u8 = &.{"Entry"},
};

fn channel(v: u8) f32 {
    const c = @as(f32, @floatFromInt(v)) / 255.0;
    return if (c <= 0.03928) c / 12.92 else std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
}

fn luminance(c: geom.Color) f32 {
    return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

/// The contrast ratio of two opaque sRGB colors, from 1 to 21.
pub fn contrast(a: geom.Color, b: geom.Color) f32 {
    const la = luminance(a);
    const lb = luminance(b);
    const hi = @max(la, lb);
    const lo = @min(la, lb);
    return (hi + 0.05) / (lo + 0.05);
}

/// The text of a widget, or an empty string for a class with no text.
fn textOf(w: *const Widget) []const u8 {
    if (w.class.measure != label.measure and !std.mem.eql(u8, w.tk_class, "Entry")) return "";
    if (std.mem.eql(u8, w.tk_class, "Entry")) return "x";
    return label.text(w);
}

fn inList(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

/// The nearest opaque background at or above a widget.
fn backgroundBehind(w: *const Widget, which: u2) geom.Color {
    var x: ?*const Widget = w;
    while (x) |p| : (x = p.parent) {
        const st = anim.shown(p.app, p);
        if (st.background.a == 255) {
            if (which == 1) if (st.background2) |b2| if (b2.a == 255) return b2;
            return st.background;
        }
    }
    return .{ .r = 255, .g = 255, .b = 255 };
}

fn add(gpa: std.mem.Allocator, list: *std.ArrayList(Problem), w: *const Widget, kind: @TypeOf(@as(Problem, undefined).kind), comptime fmt: []const u8, args: anytype) !void {
    const detail = try std.fmt.allocPrint(gpa, fmt, args);
    errdefer gpa.free(detail);
    try list.append(gpa, .{ .path = try gpa.dupe(u8, w.path), .kind = kind, .detail = detail });
}

/// `clip` is the visible rectangle of the parent, in the coordinates of the toplevel.
fn check(gpa: std.mem.Allocator, list: *std.ArrayList(Problem), w: *Widget, top: *const Widget, opts: Options, ox: i32, oy: i32, clip: geom.Rect) !void {
    if (!w.mapped) return;
    const text = textOf(w);
    const st = anim.shown(w.app, w);
    // The box inside the toplevel.
    if (w != top and (ox < 0 or oy < 0 or ox + w.geom.w > top.geom.w or oy + w.geom.h > top.geom.h)) {
        try add(gpa, list, w, .outside_window, "box {d},{d} {d}x{d} in a window of {d}x{d}", .{ ox, oy, w.geom.w, w.geom.h, top.geom.w, top.geom.h });
    }
    if (text.len > 0) {
        if (w.geom.w == 0 or w.geom.h == 0) try add(gpa, list, w, .zero_size, "size {d}x{d}", .{ w.geom.w, w.geom.h });
        if (!inList(opts.clip_ok, w.tk_class)) {
            const size = paint.textSize(w.app, text, st.font);
            const r = paint.contentRect(w, st);
            if (size.w > r.w or size.h > r.h) try add(gpa, list, w, .text_clipped, "text {d}x{d} in {d}x{d}", .{ size.w, size.h, r.w, r.h });
            // A parent that cuts the widget cuts its text.
            const box: geom.Rect = .{ .x = ox, .y = oy, .w = w.geom.w, .h = w.geom.h };
            const seen = box.intersect(clip);
            if (seen.w < box.w or seen.h < box.h) try add(gpa, list, w, .text_clipped, "the parent shows {d}x{d} of {d}x{d}", .{ seen.w, seen.h, box.w, box.h });
        }
        const need: f32 = if (w.state.disabled) 3.0 else opts.min_contrast;
        var worst: f32 = 100;
        for ([_]u2{ 0, 1 }) |k| worst = @min(worst, contrast(st.color, backgroundBehind(w, k)));
        if (worst < need) try add(gpa, list, w, .low_contrast, "contrast {d:.1}, need {d:.1}", .{ worst, need });
    }
    const own: geom.Rect = (geom.Rect{ .x = ox, .y = oy, .w = w.geom.w, .h = w.geom.h }).intersect(clip);
    for (w.children.items) |c| try check(gpa, list, c, top, opts, ox + c.geom.x, oy + c.geom.y, own);
}

/// Checks the widgets of a toplevel after a frame. The caller owns the list
/// and the strings of each problem.
pub fn run(gpa: std.mem.Allocator, top: *Widget, opts: Options) ![]Problem {
    var list: std.ArrayList(Problem) = .empty;
    errdefer free(gpa, list.items);
    errdefer list.deinit(gpa);
    try check(gpa, &list, top, top, opts, 0, 0, .{ .x = 0, .y = 0, .w = top.geom.w, .h = top.geom.h });
    return list.toOwnedSlice(gpa);
}

pub fn free(gpa: std.mem.Allocator, problems: []Problem) void {
    for (problems) |p| {
        gpa.free(p.path);
        gpa.free(p.detail);
    }
}

test "checks: contrast" {
    const black: geom.Color = .{ .r = 0, .g = 0, .b = 0 };
    const white: geom.Color = .{ .r = 255, .g = 255, .b = 255 };
    try std.testing.expectApproxEqAbs(@as(f32, 21), contrast(black, white), 0.01);
    try std.testing.expectEqual(@as(f32, 1), contrast(white, white));
}
