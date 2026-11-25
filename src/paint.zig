//! Painting helpers for the widget classes. `box` adds the shadow, the
//! background, the border, and the focus outline of a widget from its
//! computed style. `label` adds lines of text in a rectangle with an
//! anchor and a justification. A line is positioned by its measured width
//! at the scale 1, so the layout does not depend on the scale of the
//! window. `textSize` gives the size of lines of text for `measure`.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const num = @import("num.zig");
const geom = @import("geom.zig");
const scene = @import("scene.zig");
const options = @import("options.zig");
const style_mod = @import("style.zig");
const font_mod = @import("text/font.zig");
const shape = @import("text/shape.zig");
const widget_mod = @import("widget.zig");
const App = @import("app.zig").App;
const Widget = widget_mod.Widget;
const Style = style_mod.Style;

fn ceilPx(v: f32) i32 {
    return num.pxCeil(@max(v, 0));
}

/// The border and the padding as insets, rounded up to whole pixels.
pub fn insets(style: *const Style) geom.Insets {
    return .{
        .top = ceilPx(style.border_width[0]) + style.padding.top,
        .right = ceilPx(style.border_width[1]) + style.padding.right,
        .bottom = ceilPx(style.border_width[2]) + style.padding.bottom,
        .left = ceilPx(style.border_width[3]) + style.padding.left,
    };
}

/// The space inside the border and the padding.
pub fn contentRect(w: *const Widget, style: *const Style) geom.Rect {
    const r: geom.Rect = .{ .x = 0, .y = 0, .w = w.geom.w, .h = w.geom.h };
    return r.inset(insets(style));
}

/// How far the shadow and the outline reach outside the box, in whole pixels.
pub fn overflow(style: *const Style) i32 {
    var n: f32 = 0;
    if (style.outline_width > 0 and style.outline_color.a > 0) n = @max(n, style.outline_offset + style.outline_width);
    if (style.shadow) |sh| {
        if (sh.color.a > 0) n = @max(n, @max(@abs(sh.dx), @abs(sh.dy)) + sh.blur + @max(sh.spread, 0));
    }
    return ceilPx(n);
}

/// The corner radii in logical pixels. A negative number is a percentage of the smaller side.
fn radii(w: *const Widget, style: *const Style) [4]f32 {
    var out: [4]f32 = undefined;
    const side: f32 = @floatFromInt(@min(w.geom.w, w.geom.h));
    for (style.radius, 0..) |r, i| out[i] = if (r < 0) side * (-r) / 100 else r;
    return out;
}

/// The light and the dark shade of a 3D border on a background, as
/// `TkpGetShadows` of Tk on X11 computes them.
pub fn shades(bg: geom.Color) [2]geom.Color {
    const r: u32 = bg.r;
    const g: u32 = bg.g;
    const bl: u32 = bg.b;
    if (r * r / 2 + g * g + bl * bl * 28 / 100 < 255 * 255 / 20) {
        // A very dark background: Tk mixes toward white for both shades.
        return .{
            .{ .r = @intCast((255 + 3 * r) / 4), .g = @intCast((255 + 3 * g) / 4), .b = @intCast((255 + 3 * bl) / 4), .a = 255 },
            .{ .r = @intCast((255 + r) / 2), .g = @intCast((255 + g) / 2), .b = @intCast((255 + bl) / 2), .a = 255 },
        };
    }
    const light = struct {
        fn f(c: u32) u8 {
            return @intCast(@min(255, @max(c * 14 / 10, (255 + c) / 2)));
        }
    }.f;
    return .{
        .{ .r = light(r), .g = light(g), .b = light(bl), .a = 255 },
        .{ .r = @intCast(r * 60 / 100), .g = @intCast(g * 60 / 100), .b = @intCast(bl * 60 / 100), .a = 255 },
    };
}

/// The fill and the border of a box. A relief other than `solid` with
/// square corners draws the border as four strips in two shades.
fn fillAndBorder(b: *scene.Builder, r: geom.Rect, style: *const Style, rad: [4]f32) !void {
    const bw = style.border_width;
    const square = rad[0] == 0 and rad[1] == 0 and rad[2] == 0 and rad[3] == 0;
    if (style.relief == .solid or !square or (bw[0] <= 0 and bw[1] <= 0 and bw[2] <= 0 and bw[3] <= 0)) {
        try b.box(r, .{ .fill = style.background, .fill2 = style.background2, .gradient_angle_deg = style.gradient_angle_deg, .border = bw, .border_color = style.border_color, .radii = rad, .opacity = style.opacity });
        return;
    }
    try b.box(r, .{ .fill = style.background, .fill2 = style.background2, .gradient_angle_deg = style.gradient_angle_deg, .radii = rad, .opacity = style.opacity });
    // The shades come from the border color, as Tk computes them from the color of the 3D border.
    const base = if (style.border_color.a > 0) style.border_color else style.background;
    const sh = shades(base);
    const t = ceilPx(bw[0]);
    const ri = ceilPx(bw[1]);
    const bo = ceilPx(bw[2]);
    const le = ceilPx(bw[3]);
    switch (style.relief) {
        .raised => try bevel(b, r, .{ t, ri, bo, le }, sh[0], sh[1], style.opacity),
        .sunken => try bevel(b, r, .{ t, ri, bo, le }, sh[1], sh[0], style.opacity),
        .groove, .ridge => {
            const outer: [4]i32 = .{ @divTrunc(t + 1, 2), @divTrunc(ri + 1, 2), @divTrunc(bo + 1, 2), @divTrunc(le + 1, 2) };
            const a = if (style.relief == .groove) sh[1] else sh[0];
            const c = if (style.relief == .groove) sh[0] else sh[1];
            try bevel(b, r, outer, a, c, style.opacity);
            const inner: geom.Rect = .{ .x = r.x + outer[3], .y = r.y + outer[0], .w = r.w - outer[1] - outer[3], .h = r.h - outer[0] - outer[2] };
            try bevel(b, inner, .{ t - outer[0], ri - outer[1], bo - outer[2], le - outer[3] }, c, a, style.opacity);
        },
        .solid => {},
    }
}

/// Four strips: the top and the left in `tl`, the bottom and the right in `br`.
fn bevel(b: *scene.Builder, r: geom.Rect, w: [4]i32, tl: geom.Color, br: geom.Color, opacity: f32) !void {
    const o = opacity;
    if (w[0] > 0) try b.box(.{ .x = r.x, .y = r.y, .w = r.w, .h = w[0] }, .{ .fill = tl, .opacity = o });
    if (w[3] > 0) try b.box(.{ .x = r.x, .y = r.y + w[0], .w = w[3], .h = r.h - w[0] }, .{ .fill = tl, .opacity = o });
    if (w[2] > 0) try b.box(.{ .x = r.x + w[3], .y = r.y + r.h - w[2], .w = r.w - w[3], .h = w[2] }, .{ .fill = br, .opacity = o });
    if (w[1] > 0) try b.box(.{ .x = r.x + r.w - w[1], .y = r.y + w[0], .w = w[1], .h = r.h - w[0] - w[2] }, .{ .fill = br, .opacity = o });
}

/// Adds the shadow, the background, the border, and the focus outline.
pub fn box(w: *const Widget, b: *scene.Builder, style: *const Style) !void {
    const r: geom.Rect = .{ .x = 0, .y = 0, .w = w.geom.w, .h = w.geom.h };
    const rad = radii(w, style);
    if (style.shadow) |sh| try b.shadow(r, rad, sh);
    try fillAndBorder(b, r, style, rad);
    if (style.outline_width > 0 and style.outline_color.a > 0) {
        const grow: i32 = ceilPx(style.outline_offset + style.outline_width);
        const orad = @as(f32, @floatFromInt(grow));
        var rr: [4]f32 = undefined;
        for (rad, 0..) |v, i| rr[i] = v + orad;
        const ow = style.outline_width;
        try b.box(.{ .x = -grow, .y = -grow, .w = r.w + 2 * grow, .h = r.h + 2 * grow }, .{
            .border = .{ ow, ow, ow, ow },
            .border_color = style.outline_color,
            .radii = rr,
            .opacity = style.opacity,
        });
    }
}

/// The font at the scale 1, for measures that do not depend on the window.
fn measureFont(app: *App, desc: font_mod.FontDesc) ?*font_mod.Font {
    return app.fonts.get(desc, 1) catch null;
}

/// The size of lines of text in a font. A newline starts a new line.
pub fn textSize(app: *App, text: []const u8, desc: font_mod.FontDesc) geom.Size {
    const font = measureFont(app, desc) orelse return .{};
    const m = font_mod.Fonts.metrics(font);
    var width: i32 = 0;
    var lines: i64 = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        width = @max(width, shape.measure(&app.fonts, font, line));
        lines += 1;
    }
    return .{ .w = width, .h = num.px(@as(i64, lines) * m.line_height) };
}

/// The width of the character "0", for the option `-width` of text widgets.
pub fn zeroWidth(app: *App, desc: font_mod.FontDesc) i32 {
    const font = measureFont(app, desc) orelse return 0;
    return shape.measure(&app.fonts, font, "0");
}

pub fn lineHeight(app: *App, desc: font_mod.FontDesc) i32 {
    const font = measureFont(app, desc) orelse return 0;
    return font_mod.Fonts.metrics(font).line_height;
}

/// Draws lines of text in a rectangle with an anchor and a justification.
pub fn label(w: *const Widget, b: *scene.Builder, r: geom.Rect, text: []const u8, style: *const Style, anchor: options.Anchor, justify: options.Justify) !void {
    const app = w.app;
    if (text.len == 0 or r.w <= 0 or r.h <= 0) return;
    const win_scale: f32 = b.scale;
    const mfont = measureFont(app, style.font) orelse return;
    const pfont = try app.fonts.get(style.font, win_scale);
    const m = font_mod.Fonts.metrics(mfont);
    const size = textSize(app, text, style.font);
    var bx: i32 = r.x;
    var by: i32 = r.y;
    switch (anchor) {
        .n, .center, .s => bx += @divTrunc(r.w - size.w, 2),
        .ne, .e, .se => bx += r.w - size.w,
        .nw, .w, .sw => {},
    }
    switch (anchor) {
        .w, .center, .e => by += @divTrunc(r.h - size.h, 2),
        .sw, .s, .se => by += r.h - size.h,
        .nw, .n, .ne => {},
    }
    var i: i32 = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| : (i += 1) {
        if (line.len == 0) continue;
        const lw = shape.measure(&app.fonts, mfont, line);
        const lx = bx + switch (justify) {
            .left => 0,
            .center => @divTrunc(size.w - lw, 2),
            .right => size.w - lw,
        };
        var run = try shape.shape(app.gpa, pfont, line);
        defer run.deinit(app.gpa);
        try b.text(&app.atlas, &run, lx, by + i * m.line_height + m.ascent, style.color);
    }
}

const path = @import("path.zig");
const anim = @import("anim.zig");

/// Fills a shape whose points are logical pixels from the origin of the
/// builder. The points change to device pixels in place.
pub fn fillShape(b: *scene.Builder, s: *path.Shape, color: geom.Color, opacity: f32) !void {
    if (b.failed) return error.NestingTooDeep;
    for (s.pts.items) |*p| {
        p.x = (p.x + @as(f32, @floatFromInt(b.off.x))) * b.scale;
        p.y = (p.y + @as(f32, @floatFromInt(b.off.y))) * b.scale;
    }
    const c = [4]f32{
        @as(f32, @floatFromInt(color.r)) / 255,
        @as(f32, @floatFromInt(color.g)) / 255,
        @as(f32, @floatFromInt(color.b)) / 255,
        @as(f32, @floatFromInt(color.a)) / 255,
    };
    try path.fill(b.gpa, &b.scene.quads, s, b.clip, c, opacity);
}

/// A box in a rectangle with a style: the shadow, the fill, the border,
/// and the outline, as `box` draws them for a widget.
pub fn styledBox(b: *scene.Builder, r: geom.Rect, style: *const Style) !void {
    var rad: [4]f32 = undefined;
    const side: f32 = @floatFromInt(@min(r.w, r.h));
    for (style.radius, 0..) |v, i| rad[i] = if (v < 0) side * (-v) / 100 else v;
    if (style.shadow) |sh| try b.shadow(r, rad, sh);
    try fillAndBorder(b, r, style, rad);
    if (style.outline_width > 0 and style.outline_color.a > 0) {
        const grow: i32 = ceilPx(style.outline_offset + style.outline_width);
        var rr: [4]f32 = undefined;
        for (rad, 0..) |v, i| rr[i] = v + @as(f32, @floatFromInt(grow));
        const ow = style.outline_width;
        try b.box(.{ .x = r.x - grow, .y = r.y - grow, .w = r.w + 2 * grow, .h = r.h + 2 * grow }, .{ .border = .{ ow, ow, ow, ow }, .border_color = style.outline_color, .radii = rr, .opacity = style.opacity });
    }
}

/// The animation state of one part of a widget (for example
/// `::indicator`). A class keeps one in its data for each part.
pub const PartAnim = struct {
    from: Style = .{},
    to: Style = .{},
    start_us: i64 = 0,
    valid: bool = false,
    /// The computed style of the part, and the facts it came from: the
    /// state bits, the style generation, and the style of the widget.
    cache: ?struct { target: Style, state: u16, gen: u32, base: Style, classes: usize } = null,
};

/// The shown style of a part and the progress of its move. When the
/// computed style of the part changes, the part moves from the shown
/// style to the new one with the longest timing of the `transition` of
/// the part. A running move asks for the next frame.
pub fn partStyle(w: *Widget, part: []const u8, slot: *PartAnim) struct { style: Style, t: f32 } {
    const app = w.app;
    const bits: u16 = @bitCast(w.state);
    const hit = if (slot.cache) |c| c.state == bits and c.gen == app.styles.generation and c.classes == w.classes.items.len and c.base.eql(&w.style) else false;
    if (!hit) slot.cache = .{ .target = app.styles.compute(w, part, &w.style, app.env), .state = bits, .gen = app.styles.generation, .base = w.style, .classes = w.classes.items.len };
    const target = slot.cache.?.target;
    const now = app.platform.nowUs();
    var spec: style_mod.TransSpec = .{};
    for (target.transition.props) |p| if (p.active() and p.totalUs() > spec.totalUs()) {
        spec = p;
    };
    if (!slot.valid or anim.reduced(app) or !spec.active()) {
        // A part with no change is at the end of its move: its start is long ago.
        slot.from = target;
        slot.to = target;
        slot.start_us = now - (1 << 40);
        slot.valid = true;
        return .{ .style = target, .t = 1 };
    }
    if (!target.eql(&slot.to)) {
        const p_old = spec.progress(now - slot.start_us);
        slot.from = anim.mix(&slot.from, &slot.to, p_old);
        slot.to = target;
        slot.start_us = now;
    }
    const since = now - slot.start_us;
    if (since >= spec.totalUs() or app.part_end) return .{ .style = slot.to, .t = 1 };
    app.anim_more = true;
    const p = spec.progress(since);
    app.notePartMove(slot.start_us, spec, p);
    return .{ .style = anim.mix(&slot.from, &slot.to, p), .t = p };
}

/// Breaks text into lines no wider than `max_w` logical pixels, at spaces.
/// A newline always breaks. A word that is wider than `max_w` stays on
/// its own line. The lines are slices of `text`.
pub fn wrapLines(app: *App, a: std.mem.Allocator, text: []const u8, desc: font_mod.FontDesc, max_w: i32) ![]const []const u8 {
    const font = measureFont(app, desc) orelse return &.{};
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var paras = std.mem.splitScalar(u8, text, '\n');
    while (paras.next()) |para| {
        // Each line is the longest run of whole words that fits.
        var line_start: usize = 0;
        var line_end: usize = 0;
        var pos: usize = 0;
        while (pos < para.len) {
            while (pos < para.len and para[pos] == ' ') pos += 1;
            if (pos >= para.len) break;
            const ws = pos;
            while (pos < para.len and para[pos] != ' ') pos += 1;
            const we = pos;
            if (line_end > line_start and shape.measure(&app.fonts, font, para[line_start..we]) > max_w) {
                try out.append(a, para[line_start..line_end]);
                line_start = ws;
            } else if (line_end == line_start) line_start = ws;
            line_end = we;
        }
        try out.append(a, para[line_start..line_end]);
    }
    return out.items;
}

/// The size of wrapped lines.
pub fn linesSize(app: *App, lines: []const []const u8, desc: font_mod.FontDesc) geom.Size {
    const font = measureFont(app, desc) orelse return .{};
    var w: i32 = 0;
    for (lines) |l| w = @max(w, shape.measure(&app.fonts, font, l));
    return .{ .w = w, .h = num.px(@as(i64, @intCast(lines.len)) * font_mod.Fonts.metrics(font).line_height) };
}
