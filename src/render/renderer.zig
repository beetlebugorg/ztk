//! The shared math of the renderers, and the image type. The CPU renderer
//! and the shader of the Vulkan renderer use the same formulas. A pixel
//! has its center at x + 0.5, y + 0.5. The rounded-rectangle distance is
//! negative inside. Coverage is clamp(0.5 - d, 0, 1), which gives one
//! pixel of anti-aliasing. The inner shape of a box is the rectangle
//! minus the four border widths. Each inner radius is the outer radius
//! minus the larger of its two adjacent border widths, and at least 0.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const scene = @import("../scene.zig");
const Quad = scene.Quad;
const Atlas = @import("../text/atlas.zig").Atlas;

pub const Image = struct {
    width: u32,
    height: u32,
    /// RGBA, 8 bits, sRGB, rows from the top.
    pixels: []u8,
};

/// The interface of a renderer. The CPU renderer and the Vulkan renderer
/// both fill it, so a backend does not know which one it has.
pub const Renderer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        deinit: *const fn (ptr: *anyopaque) void,
        /// Draws a scene to the current target.
        draw: *const fn (ptr: *anyopaque, scene: *const scene.Scene, atlas: *const Atlas) anyerror!void,
    };

    pub fn deinit(r: Renderer) void {
        r.vtable.deinit(r.ptr);
    }

    pub fn draw(r: Renderer, s: *const scene.Scene, atlas: *const Atlas) !void {
        return r.vtable.draw(r.ptr, s, atlas);
    }
};

/// The distance from a point to a rounded rectangle. Negative inside.
/// Each radius is limited to half of the smaller side.
pub fn roundedDistance(px: f32, py: f32, rect: [4]f32, radii: [4]f32) f32 {
    const hw = rect[2] * 0.5;
    const hh = rect[3] * 0.5;
    const cx = rect[0] + hw;
    const cy = rect[1] + hh;
    const dx = px - cx;
    const dy = py - cy;
    const limit = @min(hw, hh);
    const idx: usize = if (dy < 0) (if (dx < 0) 0 else 1) else (if (dx < 0) 3 else 2);
    const r = @min(radii[idx], limit);
    const qx = @abs(dx) - hw + r;
    const qy = @abs(dy) - hh + r;
    const mx = @max(qx, 0);
    const my = @max(qy, 0);
    return @min(@max(qx, qy), 0) + @sqrt(mx * mx + my * my) - r;
}

fn clamp01(x: f32) f32 {
    return std.math.clamp(x, 0, 1);
}

/// The coverage of a pixel center for one quad: fill alpha and border alpha.
pub const Coverage = struct { fill: f32, border: f32 };

pub fn boxCoverage(q: *const Quad, px: f32, py: f32) Coverage {
    const outer = clamp01(0.5 - roundedDistance(px, py, q.rect, q.radii));
    const bt = q.border[0];
    const br = q.border[1];
    const bb = q.border[2];
    const bl = q.border[3];
    if (bt == 0 and br == 0 and bb == 0 and bl == 0) return .{ .fill = outer, .border = 0 };
    const inner_rect = [4]f32{ q.rect[0] + bl, q.rect[1] + bt, q.rect[2] - bl - br, q.rect[3] - bt - bb };
    if (inner_rect[2] <= 0 or inner_rect[3] <= 0) return .{ .fill = 0, .border = outer };
    const inner_radii = [4]f32{
        @max(q.radii[0] - @max(bt, bl), 0),
        @max(q.radii[1] - @max(bt, br), 0),
        @max(q.radii[2] - @max(bb, br), 0),
        @max(q.radii[3] - @max(bb, bl), 0),
    };
    const inner = clamp01(0.5 - roundedDistance(px, py, inner_rect, inner_radii));
    return .{ .fill = inner, .border = @max(outer - inner, 0) };
}

/// The coverage of a shadow quad: a smooth step over the blur width.
pub fn shadowCoverage(q: *const Quad, px: f32, py: f32) f32 {
    const d = roundedDistance(px, py, q.rect, q.radii);
    const blur = @max(q.params[2], 1);
    const t = clamp01(0.5 - d / blur);
    return t * t * (3 - 2 * t);
}

/// The position of a pixel along the gradient line, 0 to 1. The line
/// length follows the CSS rule: |w sin a| + |h cos a|.
pub fn gradientT(q: *const Quad, px: f32, py: f32) f32 {
    const dx = q.params[0];
    const dy = q.params[1];
    const len = @abs(q.rect[2] * dx) + @abs(q.rect[3] * dy);
    if (len <= 0) return 0;
    const cx = q.rect[0] + q.rect[2] * 0.5;
    const cy = q.rect[1] + q.rect[3] * 0.5;
    return clamp01(((px - cx) * dx + (py - cy) * dy) / len + 0.5);
}

pub const RowRange = struct { first: u32, last: u32 };

/// The rows that differ between two images of equal size, as ranges in
/// order. `out` gets at most `out.len` ranges. When more ranges exist,
/// the last range covers the rest.
pub fn changedRows(prev: Image, cur: Image, out: []RowRange) []RowRange {
    std.debug.assert(prev.width == cur.width and prev.height == cur.height);
    if (out.len == 0) return out[0..0];
    const stride: usize = @as(usize, cur.width) * 4;
    var n: usize = 0;
    var first: ?u32 = null;
    var last: u32 = 0;
    var y: u32 = 0;
    while (y < cur.height) : (y += 1) {
        const a = prev.pixels[y * stride ..][0..stride];
        const b = cur.pixels[y * stride ..][0..stride];
        if (!std.mem.eql(u8, a, b)) {
            if (first == null) first = y;
            last = y;
        } else if (first) |f| {
            // The last slot stays open and grows to the last changed row.
            if (n + 1 < out.len) {
                out[n] = .{ .first = f, .last = y };
                n += 1;
                first = null;
            }
        }
    }
    if (first) |f| {
        out[n] = .{ .first = f, .last = last + 1 };
        n += 1;
    }
    return out[0..n];
}
