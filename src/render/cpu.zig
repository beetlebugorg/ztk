//! The CPU renderer. It draws a scene to an RGBA image with the math of
//! renderer.zig. It clears the image, then draws each quad in order with
//! "source over" on 8-bit sRGB values: out = src * a + dst * (1 - a),
//! rounded to the nearest integer. The target is opaque. A pixel outside
//! the clip of a quad gets no color. A pixel in the solid core of a box
//! (farther from each edge than the largest radius and border) skips the
//! distance math. A glyph or image quad draws nothing until task 07.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const num = @import("../num.zig");
const scene_mod = @import("../scene.zig");
const r = @import("renderer.zig");
const Scene = scene_mod.Scene;
const Quad = scene_mod.Quad;
const Image = r.Image;
const Atlas = @import("../text/atlas.zig").Atlas;

inline fn blend(dst: []u8, rgb: [3]f32, a: f32) void {
    // The test is also false for NaN.
    if (!(a > 0)) return;
    const ia = 1 - a;
    inline for (0..3) |i| {
        const d: f32 = @floatFromInt(dst[i]);
        const o = rgb[i] * 255 * a + d * ia;
        dst[i] = @intFromFloat(std.math.clamp(@round(o), 0, 255));
    }
}

fn rgbOf(c: [4]f32) [3]f32 {
    return .{ c[0], c[1], c[2] };
}

fn lerpColor(a: [4]f32, b: [4]f32, t: f32) [4]f32 {
    var o: [4]f32 = undefined;
    inline for (0..4) |i| o[i] = a[i] + (b[i] - a[i]) * t;
    return o;
}

fn sameColor(q: *const Quad) bool {
    return std.mem.eql(f32, &q.fill, &q.fill2);
}

/// Pixel bounds [x0, x1) x [y0, y1) of a quad, with `pad` on each side.
fn bounds(q: *const Quad, pad: f32, img: Image) [4]i32 {
    const x0 = @max(q.rect[0] - pad, q.clip[0], 0);
    const y0 = @max(q.rect[1] - pad, q.clip[1], 0);
    const x1 = @min(q.rect[0] + q.rect[2] + pad, q.clip[0] + q.clip[2], @as(f32, @floatFromInt(img.width)));
    const y1 = @min(q.rect[1] + q.rect[3] + pad, q.clip[1] + q.clip[3], @as(f32, @floatFromInt(img.height)));
    const w: i32 = @intCast(img.width);
    const h: i32 = @intCast(img.height);
    return .{ std.math.clamp(num.pxFloor(x0), 0, w), std.math.clamp(num.pxFloor(y0), 0, h), std.math.clamp(num.pxCeil(x1), 0, w), std.math.clamp(num.pxCeil(y1), 0, h) };
}

/// One pixel of a box on the slow path: the coverage comes from the distance math.
inline fn boxPixel(q: *const Quad, dst: []u8, x: i32, y: i32, flat: bool) void {
    const px = @as(f32, @floatFromInt(x)) + 0.5;
    const py = @as(f32, @floatFromInt(y)) + 0.5;
    const c = r.boxCoverage(q, px, py);
    const opacity = q.params[3];
    if (c.fill > 0) {
        const col = if (flat) q.fill else lerpColor(q.fill, q.fill2, r.gradientT(q, px, py));
        blend(dst, rgbOf(col), col[3] * c.fill * opacity);
    }
    if (c.border > 0) blend(dst, rgbOf(q.border_color), q.border_color[3] * c.border * opacity);
}

/// The rows far from the top and bottom edges ("core rows") have no
/// corner and no horizontal border. A pixel there that is more than one
/// pixel plus the largest border from the side edges has full fill
/// coverage. In the other rows, the pixels farther than one pixel plus
/// the largest radius and border from the side edges share one coverage
/// value, because the distance there depends only on y. Both facts let
/// the renderer skip the distance math for most pixels of a box.
///
/// The clip edges are whole numbers (the Builder rounds them), so each
/// pixel of the bounds has its center in the clip.
fn drawBox(q: *const Quad, img: Image) void {
    const b = bounds(q, 1, img);
    if (b[2] <= b[0] or b[3] <= b[1]) return;
    var maxr: f32 = 0;
    var maxb: f32 = 0;
    for (q.radii) |v| maxr = @max(maxr, v);
    for (q.border) |v| maxb = @max(maxb, v);
    const m = 1 + maxr + maxb;
    const core_y0 = q.rect[1] + m;
    const core_y1 = q.rect[1] + q.rect[3] - m;
    const flat = sameColor(q);
    const opacity = q.params[3];
    const solid = flat and q.fill[3] * opacity >= 1;
    const stride: usize = @as(usize, img.width) * 4;
    const solid_px = [4]u8{
        num.byte(q.fill[0] * 255),
        num.byte(q.fill[1] * 255),
        num.byte(q.fill[2] * 255),
        255,
    };
    const border_px = [4]u8{
        num.byte(q.border_color[0] * 255),
        num.byte(q.border_color[1] * 255),
        num.byte(q.border_color[2] * 255),
        255,
    };
    const left = q.rect[0];
    const right = q.rect[0] + q.rect[2];
    // The pixel columns of the shared spans: [a0, a1) for core rows and [m0, m1) for the others.
    const a0: i32 = std.math.clamp(num.pxCeil(left + 1 + maxb - 0.5), b[0], b[2]);
    const a1: i32 = std.math.clamp(num.pxCeil(right - 1 - maxb - 0.5), a0, b[2]);
    const m0: i32 = std.math.clamp(num.pxCeil(left + m - 0.5), b[0], b[2]);
    const m1: i32 = std.math.clamp(num.pxCeil(right - m - 0.5), m0, b[2]);
    var y = b[1];
    while (y < b[3]) : (y += 1) {
        const py = @as(f32, @floatFromInt(y)) + 0.5;
        const row = img.pixels[@as(usize, @intCast(y)) * stride ..][0..stride];
        const core_row = py >= core_y0 and py < core_y1;
        const s0 = if (core_row) a0 else m0;
        const s1 = if (core_row) a1 else m1;
        var x = b[0];
        while (x < s0) : (x += 1) boxPixel(q, row[@as(usize, @intCast(x)) * 4 ..][0..4], x, y, flat);
        if (s1 > s0) {
            // One coverage for the span.
            const c: r.Coverage = if (core_row)
                .{ .fill = 1, .border = 0 }
            else
                r.boxCoverage(q, @as(f32, @floatFromInt(s0)) + 0.5, py);
            const span = std.mem.bytesAsSlice([4]u8, row[@as(usize, @intCast(s0)) * 4 .. @as(usize, @intCast(s1)) * 4]);
            if (solid and c.fill >= 1) {
                @memset(span, solid_px);
            } else if (c.fill <= 0 and c.border >= 1 and q.border_color[3] * opacity >= 1) {
                @memset(span, border_px);
            } else {
                x = s0;
                while (x < s1) : (x += 1) {
                    const dst = row[@as(usize, @intCast(x)) * 4 ..][0..4];
                    if (c.fill > 0) {
                        const col = if (flat) q.fill else lerpColor(q.fill, q.fill2, r.gradientT(q, @as(f32, @floatFromInt(x)) + 0.5, py));
                        blend(dst, rgbOf(col), col[3] * c.fill * opacity);
                    }
                    if (c.border > 0) blend(dst, rgbOf(q.border_color), q.border_color[3] * c.border * opacity);
                }
            }
        }
        x = s1;
        while (x < b[2]) : (x += 1) boxPixel(q, row[@as(usize, @intCast(x)) * 4 ..][0..4], x, y, flat);
    }
}

fn drawShadow(q: *const Quad, img: Image) void {
    const pad = @max(q.params[2], 1) + 1;
    const b = bounds(q, pad, img);
    if (b[2] <= b[0] or b[3] <= b[1]) return;
    const stride: usize = @as(usize, img.width) * 4;
    var y = b[1];
    while (y < b[3]) : (y += 1) {
        const py = @as(f32, @floatFromInt(y)) + 0.5;
        const row = img.pixels[@as(usize, @intCast(y)) * stride ..][0..stride];
        var x = b[0];
        while (x < b[2]) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const cov = r.shadowCoverage(q, px, py);
            blend(row[@as(usize, @intCast(x)) * 4 ..][0..4], rgbOf(q.fill), q.fill[3] * cov * q.params[3]);
        }
    }
}

/// Draws a glyph quad: the coverage is the texel of the atlas at the
/// pixel. The quad has whole device pixel positions, so no filter applies.
fn drawGlyph(q: *const Quad, atlas: *const Atlas, img: Image) void {
    const page = atlas.page();
    if (page.len == 0) return;
    const b = bounds(q, 0, img);
    const stride: usize = @as(usize, img.width) * 4;
    const ux: i32 = @intFromFloat(q.uv[0]);
    const uy: i32 = @intFromFloat(q.uv[1]);
    const rx = num.pxFloor(q.rect[0]);
    const ry = num.pxFloor(q.rect[1]);
    const color = rgbOf(q.fill);
    var y = b[1];
    while (y < b[3]) : (y += 1) {
        const row = img.pixels[@as(usize, @intCast(y)) * stride ..][0..stride];
        const trow: usize = @intCast((uy + y - ry) * Atlas.page_size);
        var x = b[0];
        while (x < b[2]) : (x += 1) {
            const cov = page[trow + @as(usize, @intCast(ux + x - rx))];
            if (cov == 0) continue;
            blend(row[@as(usize, @intCast(x)) * 4 ..][0..4], color, q.fill[3] * (@as(f32, @floatFromInt(cov)) / 255) * q.params[3]);
        }
    }
}

/// Draws the scene. `atlas` is the glyph atlas, or null for a scene
/// with no glyphs.
pub fn render(scene: *const Scene, atlas_ptr: ?*const anyopaque, out: *Image) void {
    const atlas: ?*const Atlas = if (atlas_ptr) |p| @ptrCast(@alignCast(p)) else null;
    const clear = scene.clear;
    var i: usize = 0;
    while (i < out.pixels.len) : (i += 4) {
        out.pixels[i] = num.byte(clear[0] * 255);
        out.pixels[i + 1] = num.byte(clear[1] * 255);
        out.pixels[i + 2] = num.byte(clear[2] * 255);
        out.pixels[i + 3] = 255;
    }
    for (scene.quads.items) |*q| {
        switch (@as(scene_mod.Kind, @enumFromInt(q.kind))) {
            .box => drawBox(q, out.*),
            .shadow => drawShadow(q, out.*),
            .glyph => if (atlas) |a| drawGlyph(q, a, out.*),
            .image => {},
        }
    }
}
