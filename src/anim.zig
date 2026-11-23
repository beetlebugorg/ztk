//! CSS transitions. When the style of a widget changes and the new style
//! has a transition duration, `start` records an animation from the shown
//! style to the new style. `tick` sets the shown style for a time and
//! marks the widget for paint. Only paint properties move: the colors,
//! the opacity, the radius, and the shadow. Properties that change the
//! layout change at once. A change during an animation starts from the
//! shown value. The time comes from the caller, so a test with a manual
//! clock gets exact results.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const num = @import("num.zig");
const geom = @import("geom.zig");
const style_mod = @import("style.zig");
const widget_mod = @import("widget.zig");
const App = @import("app.zig").App;
const Widget = widget_mod.Widget;
const Style = style_mod.Style;

pub const Anim = struct {
    widget: *Widget,
    from: Style,
    to: Style,
    /// The shown style at the last tick.
    cur: Style,
    start_us: i64,
    duration_us: i64,
    linear: bool,
};

/// The timing function `ease` of CSS: cubic-bezier(0.25, 0.1, 0.25, 1).
pub fn ease(t: f32) f32 {
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    // Solve x(s) = t for the curve parameter s by bisection, then return y(s).
    var lo: f32 = 0;
    var hi: f32 = 1;
    var s: f32 = t;
    var i: u32 = 0;
    while (i < 24) : (i += 1) {
        s = (lo + hi) * 0.5;
        const x = bez(0.25, 0.25, s);
        if (x < t) lo = s else hi = s;
    }
    return bez(0.1, 1.0, s);
}

fn bez(p1: f32, p2: f32, s: f32) f32 {
    const u = 1 - s;
    return 3 * u * u * s * p1 + 3 * u * s * s * p2 + s * s * s;
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn lerpByte(a: u8, b: u8, t: f32) u8 {
    const v = lerp(@floatFromInt(a), @floatFromInt(b), t);
    return num.byte(v);
}

fn lerpColor(a: geom.Color, b: geom.Color, t: f32) geom.Color {
    return .{ .r = lerpByte(a.r, b.r, t), .g = lerpByte(a.g, b.g, t), .b = lerpByte(a.b, b.b, t), .a = lerpByte(a.a, b.a, t) };
}

fn lerpOptColor(a: ?geom.Color, b: ?geom.Color, t: f32) ?geom.Color {
    if (a != null and b != null) return lerpColor(a.?, b.?, t);
    return if (t >= 1) b else a;
}

/// The style between two styles at a point t of the eased time.
pub fn mix(from: *const Style, to: *const Style, t: f32) Style {
    var out = to.*;
    out.color = lerpColor(from.color, to.color, t);
    out.background = lerpColor(from.background, to.background, t);
    out.background2 = lerpOptColor(from.background2, to.background2, t);
    out.border_color = lerpColor(from.border_color, to.border_color, t);
    out.outline_color = lerpColor(from.outline_color, to.outline_color, t);
    out.caret_color = lerpColor(from.caret_color, to.caret_color, t);
    out.opacity = lerp(from.opacity, to.opacity, t);
    for (&out.radius, from.radius, to.radius) |*o, a, b| o.* = lerp(a, b, t);
    if (from.shadow != null and to.shadow != null) {
        const a = from.shadow.?;
        const b = to.shadow.?;
        out.shadow = .{ .dx = lerp(a.dx, b.dx, t), .dy = lerp(a.dy, b.dy, t), .blur = lerp(a.blur, b.blur, t), .spread = lerp(a.spread, b.spread, t), .color = lerpColor(a.color, b.color, t) };
    } else out.shadow = if (t >= 1) to.shadow else from.shadow;
    return out;
}

/// True when a property that changes the layout differs. Such a change is not animated.
fn sameLayout(a: *const Style, b: *const Style) bool {
    return std.meta.eql(a.border_width, b.border_width) and std.meta.eql(a.padding, b.padding) and
        std.meta.eql(a.font, b.font) and a.min_width == b.min_width and a.min_height == b.min_height;
}

fn find(app: *App, w: *const Widget) ?usize {
    for (app.anims.items, 0..) |a, i| if (a.widget == w) return i;
    return null;
}

/// Starts or changes the animation of a widget after a style change.
pub fn start(app: *App, w: *Widget, old: *const Style, new: *const Style, now_us: i64) !void {
    if (!app.animations or new.transition.duration_ms == 0 or !sameLayout(old, new)) {
        if (find(app, w)) |i| _ = app.anims.swapRemove(i);
        return;
    }
    // A change during an animation starts from the shown value.
    const from = if (find(app, w)) |i| app.anims.items[i].cur else old.*;
    const a: Anim = .{
        .widget = w,
        .from = from,
        .to = new.*,
        .cur = from,
        .start_us = now_us,
        .duration_us = @as(i64, new.transition.duration_ms) * 1000,
        .linear = new.transition.linear,
    };
    if (find(app, w)) |i| app.anims.items[i] = a else try app.anims.append(app.gpa, a);
}

/// Sets the shown style of each animated widget for a time. Returns true
/// when an animation still runs.
pub fn tick(app: *App, now_us: i64) bool {
    if (app.anims.items.len == 0) return false;
    const same_time = now_us == app.anim_last_us;
    app.anim_last_us = now_us;
    var i: usize = 0;
    while (i < app.anims.items.len) {
        const a = &app.anims.items[i];
        const done = !a.widget.alive() or now_us - a.start_us >= a.duration_us;
        if (!same_time or done) {
            if (done) {
                a.cur = a.to;
            } else {
                const raw: f32 = @floatFromInt(@max(now_us - a.start_us, 0));
                const x = raw / @as(f32, @floatFromInt(a.duration_us));
                a.cur = mix(&a.from, &a.to, if (a.linear) x else ease(x));
            }
            if (a.widget.alive()) a.widget.invalidate(.{ .style = false, .measure = false, .layout = false, .paint = true });
        }
        if (done) {
            _ = app.anims.swapRemove(i);
        } else i += 1;
    }
    return app.anims.items.len > 0;
}

/// The style that the paint uses: the animated one, or `w.style`.
pub fn shown(app: *App, w: *const Widget) *const Style {
    if (app.anims.items.len == 0) return &w.style;
    if (find(app, w)) |i| return &app.anims.items[i].cur;
    return &w.style;
}

/// Forgets the animation of a widget that is deleted.
pub fn forget(app: *App, w: *const Widget) void {
    if (find(app, w)) |i| _ = app.anims.swapRemove(i);
}

const testing = std.testing;

test "anim: ease" {
    try testing.expectEqual(@as(f32, 0), ease(0));
    try testing.expectEqual(@as(f32, 1), ease(1));
    const mid = ease(0.5);
    try testing.expect(mid > 0.78 and mid < 0.82);
}
