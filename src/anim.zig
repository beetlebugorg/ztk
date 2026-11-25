//! Animations of the style. Three kinds exist.
//!
//! - A transition: when the computed style of a widget changes and the
//!   new style has a `transition` for a property that changed, `start`
//!   records the shown style and the new style. Each property moves with
//!   its own duration, delay, and timing function. A change during a move
//!   starts from the shown value.
//! - A keyframe animation: a style with an `animation` name runs the
//!   stops of the `@keyframes` rule of that name. The style of each stop
//!   is the computed style with the declarations of the stop on top.
//! - An option animation (`ztk::animate`) moves a widget option. It is in
//!   `animate.zig`.
//!
//! `tick` sets the shown style for a time and marks the widget for
//! paint. A move of the padding or of a minimum size also writes the
//! value into the style of the widget and marks it for a measure, so the
//! layout follows at each frame. The time comes from the caller, so a
//! test with a manual clock gets exact results.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const num = @import("num.zig");
const geom = @import("geom.zig");
const easing = @import("easing.zig");
const style_mod = @import("style.zig");
const widget_mod = @import("widget.zig");
const App = @import("app.zig").App;
const Widget = widget_mod.Widget;
const Style = style_mod.Style;
const AnimProp = style_mod.AnimProp;
const n_props = style_mod.n_anim_props;

pub const Anim = struct {
    widget: *Widget,
    from: Style,
    to: Style,
    /// The shown style at the last tick.
    cur: Style,
    start_us: i64,
    /// The timing of each property. A property with no timing moves at once.
    spec: style_mod.Transition,
    /// True when the padding or a minimum size moves.
    layout: bool,
};

/// A running keyframe animation.
pub const KeyAnim = struct {
    widget: *Widget,
    spec: style_mod.AnimationSpec,
    start_us: i64,
    /// The offsets and the styles of the stops. Owned.
    offsets: []f32,
    stops: []Style,
    cur: Style,
    /// True after the last iteration.
    done: bool = false,
};

/// The timing function `ease` of CSS.
pub fn ease(t: f32) f32 {
    return easing.Timing.ease.eval(t);
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn lerpI(a: i32, b: i32, t: f32) i32 {
    return num.pxRound(@as(f64, lerp(@floatFromInt(a), @floatFromInt(b), t)));
}

fn lerpByte(a: u8, b: u8, t: f32) u8 {
    return num.byte(lerp(@floatFromInt(a), @floatFromInt(b), t));
}

pub fn lerpColor(a: geom.Color, b: geom.Color, t: f32) geom.Color {
    return .{ .r = lerpByte(a.r, b.r, t), .g = lerpByte(a.g, b.g, t), .b = lerpByte(a.b, b.b, t), .a = lerpByte(a.a, b.a, t) };
}

fn lerpOptColor(a: ?geom.Color, b: ?geom.Color, t: f32) ?geom.Color {
    if (a != null and b != null) return lerpColor(a.?, b.?, t);
    return if (t >= 1) b else a;
}

fn at(v: [n_props]f32, k: AnimProp) f32 {
    return v[@intFromEnum(k)];
}

/// The style between two styles, with one progress for each property.
pub fn mixEach(from: *const Style, to: *const Style, t: [n_props]f32) Style {
    var out = to.*;
    out.color = lerpColor(from.color, to.color, at(t, .color));
    out.background = lerpColor(from.background, to.background, at(t, .background));
    out.background2 = lerpOptColor(from.background2, to.background2, at(t, .background));
    out.border_color = lerpColor(from.border_color, to.border_color, at(t, .border_color));
    out.outline_color = lerpColor(from.outline_color, to.outline_color, at(t, .outline_color));
    out.caret_color = lerpColor(from.caret_color, to.caret_color, at(t, .caret_color));
    out.opacity = lerp(from.opacity, to.opacity, at(t, .opacity));
    for (&out.radius, from.radius, to.radius) |*o, a, b| o.* = lerp(a, b, at(t, .radius));
    const ts = at(t, .shadow);
    if (from.shadow != null or to.shadow != null) {
        // A missing shadow moves from or to a clear shadow of the same shape.
        var a = from.shadow orelse to.shadow.?;
        var b = to.shadow orelse from.shadow.?;
        if (from.shadow == null) a.color.a = 0;
        if (to.shadow == null) b.color.a = 0;
        out.shadow = .{ .dx = lerp(a.dx, b.dx, ts), .dy = lerp(a.dy, b.dy, ts), .blur = lerp(a.blur, b.blur, ts), .spread = lerp(a.spread, b.spread, ts), .color = lerpColor(a.color, b.color, ts) };
        if (ts >= 1) out.shadow = to.shadow;
    }
    const to_ = at(t, .outline);
    out.outline_width = lerp(from.outline_width, to.outline_width, to_);
    out.outline_offset = lerp(from.outline_offset, to.outline_offset, to_);
    const tp = at(t, .padding);
    out.padding = .{ .top = lerpI(from.padding.top, to.padding.top, tp), .right = lerpI(from.padding.right, to.padding.right, tp), .bottom = lerpI(from.padding.bottom, to.padding.bottom, tp), .left = lerpI(from.padding.left, to.padding.left, tp) };
    const tm = at(t, .min_size);
    out.min_width = lerpI(from.min_width, to.min_width, tm);
    out.min_height = lerpI(from.min_height, to.min_height, tm);
    return out;
}

/// The style between two styles with one progress for all properties.
pub fn mix(from: *const Style, to: *const Style, t: f32) Style {
    return mixEach(from, to, [_]f32{t} ** n_props);
}

/// True when a property that no transition moves changes the layout.
fn otherLayout(a: *const Style, b: *const Style) bool {
    return !std.meta.eql(a.border_width, b.border_width) or !std.meta.eql(a.font, b.font);
}

fn layoutMoves(a: *const Style, b: *const Style, spec: *const style_mod.Transition) bool {
    const pad = !std.meta.eql(a.padding, b.padding) and spec.props[@intFromEnum(AnimProp.padding)].active();
    const min = (a.min_width != b.min_width or a.min_height != b.min_height) and spec.props[@intFromEnum(AnimProp.min_size)].active();
    return pad or min;
}

fn find(app: *App, w: *const Widget) ?usize {
    for (app.anims.items, 0..) |a, i| if (a.widget == w) return i;
    return null;
}

fn findKey(app: *App, w: *const Widget) ?usize {
    for (app.key_anims.items, 0..) |a, i| if (a.widget == w) return i;
    return null;
}

/// True when animations show their end state at once: `ZTK_NO_ANIMATION`,
/// the reduced motion setting of the backend, or `ztk::animate reduce 1`.
pub fn reduced(app: *const App) bool {
    return !app.animations or app.reduce_motion;
}

/// The end of a running transition of the widget, or its style.
pub fn target(app: *App, w: *const Widget) *const Style {
    if (find(app, w)) |i| return &app.anims.items[i].to;
    return &w.style;
}

/// The transition of a widget, or null.
pub fn transitionOf(app: *App, w: *const Widget) ?*Anim {
    const i = find(app, w) orelse return null;
    return &app.anims.items[i];
}

/// The keyframe animation of a widget, or null.
pub fn keyOf(app: *App, w: *const Widget) ?*const KeyAnim {
    if (app.key_anims.items.len == 0) return null;
    const i = findKey(app, w) orelse return null;
    return &app.key_anims.items[i];
}

/// Starts or changes the transition of a widget after a style change.
/// The caller has set `w.style` to `new`.
pub fn start(app: *App, w: *Widget, old: *const Style, new: *const Style, now_us: i64) !void {
    if (reduced(app) or !new.transition.any() or otherLayout(old, new)) {
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
        .spec = new.transition,
        .layout = layoutMoves(&from, new, &new.transition),
    };
    if (a.layout) {
        w.style.padding = from.padding;
        w.style.min_width = from.min_width;
        w.style.min_height = from.min_height;
    }
    if (find(app, w)) |i| app.anims.items[i] = a else try app.anims.append(app.gpa, a);
}

/// The progress of each property of a transition at a time.
pub fn progressOf(a: *const Anim, now_us: i64) [n_props]f32 {
    var t: [n_props]f32 = undefined;
    for (&t, a.spec.props) |*slot, sp| slot.* = if (sp.active()) sp.progress(now_us - a.start_us) else 1;
    return t;
}

/// Starts, changes, or ends the keyframe animation of a widget after its
/// style was computed.
pub fn keyframes(app: *App, w: *Widget, now_us: i64) void {
    const spec = w.style.animation;
    if (findKey(app, w)) |i| {
        const k = &app.key_anims.items[i];
        if (std.mem.eql(u8, k.spec.name, spec.name) and std.meta.eql(k.spec, spec)) {
            // The same animation: the stops follow the new computed style.
            rebuildStops(app, w, k) catch {};
            return;
        }
        freeKey(app, i);
    }
    if (spec.name.len == 0 or reduced(app)) return;
    const kf = app.styles.keyframes(spec.name) orelse return;
    if (kf.stops.len == 0) return;
    var k: KeyAnim = .{ .widget = w, .spec = spec, .start_us = now_us, .offsets = &.{}, .stops = &.{}, .cur = w.style };
    rebuildStops(app, w, &k) catch return;
    k.cur = keyStyle(&k, &w.style, now_us).style;
    app.key_anims.append(app.gpa, k) catch {
        app.gpa.free(k.offsets);
        app.gpa.free(k.stops);
    };
}

fn rebuildStops(app: *App, w: *Widget, k: *KeyAnim) !void {
    const kf = app.styles.keyframes(k.spec.name) orelse return;
    if (kf.stops.len == 0) return;
    // A missing `from` or `to` stop is the computed style.
    const first_missing = kf.stops[0].offset > 0;
    const last_missing = kf.stops[kf.stops.len - 1].offset < 1;
    const n = kf.stops.len + @intFromBool(first_missing) + @intFromBool(last_missing);
    const offsets = try app.gpa.alloc(f32, n);
    errdefer app.gpa.free(offsets);
    const stops = try app.gpa.alloc(Style, n);
    const parent: ?*const Style = if (w.parent) |p| &p.style else null;
    var j: usize = 0;
    if (first_missing) {
        offsets[0] = 0;
        stops[0] = w.style;
        j = 1;
    }
    for (kf.stops) |st| {
        offsets[j] = st.offset;
        stops[j] = app.styles.keyframeStyle(w, &w.style, parent, app.env, st.decls);
        j += 1;
    }
    if (last_missing) {
        offsets[j] = 1;
        stops[j] = w.style;
    }
    app.gpa.free(k.offsets);
    app.gpa.free(k.stops);
    k.offsets = offsets;
    k.stops = stops;
}

fn freeKey(app: *App, i: usize) void {
    const k = app.key_anims.swapRemove(i);
    app.gpa.free(k.offsets);
    app.gpa.free(k.stops);
}

pub const KeyResult = struct { style: Style, done: bool };

/// The style of a keyframe animation at a time, and whether it ended.
pub fn keyStyle(k: *const KeyAnim, base: *const Style, now_us: i64) KeyResult {
    const sp = k.spec.spec;
    const len_us: i64 = @max(sp.totalUs() - @as(i64, sp.delay_ms) * 1000, 1);
    const since = now_us - k.start_us - @as(i64, sp.delay_ms) * 1000;
    if (since < 0) {
        const back = k.spec.fill == .backwards or k.spec.fill == .both;
        return .{ .style = if (back) stopAt(k, sp.timing.eval(if (reversedAt(k.spec.direction, 0)) 1 else 0)) else base.*, .done = false };
    }
    const iters: f64 = @as(f64, @floatFromInt(since)) / @as(f64, @floatFromInt(len_us));
    const count: f64 = k.spec.count;
    if (count > 0 and iters >= count) {
        const fwd = k.spec.fill == .forwards or k.spec.fill == .both;
        if (!fwd) return .{ .style = base.*, .done = true };
        // The end of the last iteration.
        const last: u64 = @intFromFloat(@ceil(count) - 1);
        const frac: f32 = @floatCast(count - @floor(count));
        const p: f32 = if (frac == 0) 1 else frac;
        const rev = reversedAt(k.spec.direction, last);
        return .{ .style = stopAt(k, sp.timing.eval(if (rev) 1 - p else p)), .done = true };
    }
    const n: u64 = @intFromFloat(@floor(iters));
    var p: f32 = @floatCast(iters - @floor(iters));
    if (reversedAt(k.spec.direction, n)) p = 1 - p;
    return .{ .style = stopAt(k, sp.timing.eval(p)), .done = false };
}

fn reversedAt(d: style_mod.Direction, iteration: u64) bool {
    return switch (d) {
        .normal => false,
        .reverse => true,
        .alternate => iteration % 2 == 1,
        .alternate_reverse => iteration % 2 == 0,
    };
}

/// The style at a progress, between the two stops around it.
fn stopAt(k: *const KeyAnim, p: f32) Style {
    const offs = k.offsets;
    if (p <= offs[0]) return k.stops[0];
    var i: usize = 1;
    while (i < offs.len) : (i += 1) {
        if (p <= offs[i]) {
            const span = offs[i] - offs[i - 1];
            const t = if (span <= 0) 1 else (p - offs[i - 1]) / span;
            return mix(&k.stops[i - 1], &k.stops[i], t);
        }
    }
    return k.stops[offs.len - 1];
}

/// Sets the shown style of each animated widget for a time. Returns true
/// when an animation still runs.
pub fn tick(app: *App, now_us: i64) bool {
    const same_time = now_us == app.anim_last_us;
    app.anim_last_us = now_us;
    var i: usize = 0;
    while (i < app.anims.items.len) {
        const a = &app.anims.items[i];
        const done = !a.widget.alive() or reduced(app) or now_us - a.start_us >= a.spec.totalUs();
        if (!same_time or done) {
            a.cur = if (done) a.to else mixEach(&a.from, &a.to, progressOf(a, now_us));
            if (a.widget.alive()) {
                if (a.layout) {
                    a.widget.style.padding = a.cur.padding;
                    a.widget.style.min_width = a.cur.min_width;
                    a.widget.style.min_height = a.cur.min_height;
                    a.widget.invalidate(.{ .style = false, .measure = true, .layout = true, .paint = true });
                } else a.widget.invalidate(.{ .style = false, .measure = false, .layout = false, .paint = true });
            }
        }
        if (done) {
            _ = app.anims.swapRemove(i);
        } else i += 1;
    }
    i = 0;
    while (i < app.key_anims.items.len) {
        const k = &app.key_anims.items[i];
        if (!k.widget.alive() or reduced(app)) {
            if (k.widget.alive()) k.widget.invalidate(.{ .style = false, .measure = false, .layout = false, .paint = true });
            freeKey(app, i);
            continue;
        }
        if (!k.done and !same_time) {
            const r = keyStyle(k, &k.widget.style, now_us);
            k.cur = r.style;
            k.done = r.done;
            k.widget.invalidate(.{ .style = false, .measure = false, .layout = false, .paint = true });
        }
        i += 1;
    }
    var running = app.anims.items.len > 0;
    for (app.key_anims.items) |k| {
        if (!k.done) running = true;
    }
    return running;
}

/// The style that the paint uses: a keyframe style, a transition style, or `w.style`.
pub fn shown(app: *App, w: *const Widget) *const Style {
    if (app.paint_override) |o| if (o.widget == w) return o.style;
    if (app.key_anims.items.len > 0) if (findKey(app, w)) |i| {
        const k = &app.key_anims.items[i];
        // A finished animation with no fill shows the computed style.
        if (!k.done or k.spec.fill == .forwards or k.spec.fill == .both) return &k.cur;
    };
    if (app.anims.items.len == 0) return &w.style;
    if (find(app, w)) |i| return &app.anims.items[i].cur;
    return &w.style;
}

/// Forgets the animations of a widget that is deleted.
pub fn forget(app: *App, w: *const Widget) void {
    if (find(app, w)) |i| _ = app.anims.swapRemove(i);
    if (findKey(app, w)) |i| freeKey(app, i);
}

/// Frees the keyframe animations at the end of the App.
pub fn deinit(app: *App) void {
    while (app.key_anims.items.len > 0) freeKey(app, app.key_anims.items.len - 1);
    app.key_anims.deinit(app.gpa);
}

const testing = std.testing;

test "anim: ease" {
    try testing.expectEqual(@as(f32, 0), ease(0));
    try testing.expectEqual(@as(f32, 1), ease(1));
    const mid = ease(0.5);
    try testing.expect(mid > 0.78 and mid < 0.82);
}
