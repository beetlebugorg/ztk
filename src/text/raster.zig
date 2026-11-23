//! The glyph rasterizer. It turns an outline into an 8-bit coverage image
//! with the signed area method. Each line segment of the flattened
//! outline adds to an accumulation buffer: in each pixel row the segment
//! crosses, each pixel cell gets the signed vertical extent of the part
//! of the segment in that cell, split between the cell and the cell on its
//! right by the mean x position of that part. A running sum along each
//! row then gives the signed area to the left of each pixel boundary,
//! and the coverage is the absolute value of the sum, limited to 1.
//! That is the non-zero winding rule for outlines with no overlap and
//! the usual result for glyphs. No hinting and no gamma change apply.
//! Quadratic curves split into at most 32 segments with an error under
//! 0.1 device pixels. The y axis of a font goes up, and the image has
//! rows from the top.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ttf = @import("ttf.zig");

pub const Bitmap = struct {
    width: u32,
    height: u32,
    /// The place of the left column from the glyph origin, in pixels.
    left: i32,
    /// The place of the top row from the baseline, in pixels. It is
    /// negative above the baseline.
    top: i32,
    pixels: []u8,

    pub fn deinit(b: Bitmap, gpa: std.mem.Allocator) void {
        gpa.free(b.pixels);
    }
};

const Pt = struct { x: f32, y: f32 };

const Acc = struct {
    w: usize,
    h: usize,
    a: []f32,

    /// Adds `dy` (signed) at column position x within row y.
    fn cell(acc: *Acc, y: usize, i: i64, dy: f32, frac: f32) void {
        if (i < 0) {
            acc.a[y * acc.w] += dy;
            return;
        }
        const c: usize = @intCast(i);
        if (c >= acc.w) return;
        acc.a[y * acc.w + c] += dy * (1 - frac);
        if (c + 1 < acc.w) acc.a[y * acc.w + c + 1] += dy * frac;
    }

    /// One piece of a segment inside one pixel row.
    fn piece(acc: *Acc, y: usize, xa: f32, xb: f32, dy: f32) void {
        const x0 = @min(xa, xb);
        const x1 = @max(xa, xb);
        const ci0: i64 = @intFromFloat(@floor(x0));
        const ci1: i64 = @intFromFloat(@floor(x1));
        if (ci0 == ci1 or x1 - x0 < 1e-6) {
            const xm = (x0 + x1) * 0.5;
            acc.cell(y, ci0, dy, xm - @floor(xm));
            return;
        }
        var i = ci0;
        while (i <= ci1) : (i += 1) {
            const lo = @max(x0, @as(f32, @floatFromInt(i)));
            const hi = @min(x1, @as(f32, @floatFromInt(i + 1)));
            if (hi <= lo) continue;
            const part = dy * (hi - lo) / (x1 - x0);
            const xm = (lo + hi) * 0.5;
            acc.cell(y, i, part, xm - @as(f32, @floatFromInt(i)));
        }
    }

    fn line(acc: *Acc, p0: Pt, p1: Pt) void {
        if (p0.y == p1.y) return;
        const dir: f32 = if (p0.y < p1.y) 1 else -1;
        const a = if (p0.y < p1.y) p0 else p1;
        const b = if (p0.y < p1.y) p1 else p0;
        const slope = (b.x - a.x) / (b.y - a.y);
        const y_start = @max(a.y, 0);
        const y_end = @min(b.y, @as(f32, @floatFromInt(acc.h)));
        if (y_end <= y_start) return;
        var row: usize = @intFromFloat(@floor(y_start));
        while (@as(f32, @floatFromInt(row)) < y_end and row < acc.h) : (row += 1) {
            const top = @max(y_start, @as(f32, @floatFromInt(row)));
            const bot = @min(y_end, @as(f32, @floatFromInt(row + 1)));
            if (bot <= top) continue;
            const xa = a.x + (top - a.y) * slope;
            const xb = a.x + (bot - a.y) * slope;
            acc.piece(row, xa, xb, dir * (bot - top));
        }
    }
};

fn flatten(acc: *Acc, p0: Pt, c: Pt, p1: Pt) void {
    const ddx = p0.x - 2 * c.x + p1.x;
    const ddy = p0.y - 2 * c.y + p1.y;
    const dd = @sqrt(ddx * ddx + ddy * ddy);
    const n_f = @ceil(@sqrt(dd / 0.4));
    const n: u32 = @intFromFloat(std.math.clamp(n_f, 1, 32));
    var prev = p0;
    var i: u32 = 1;
    while (i <= n) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
        const mt = 1 - t;
        const cur = Pt{
            .x = mt * mt * p0.x + 2 * mt * t * c.x + t * t * p1.x,
            .y = mt * mt * p0.y + 2 * mt * t * c.y + t * t * p1.y,
        };
        acc.line(prev, cur);
        prev = cur;
    }
}

fn mid(a: Pt, b: Pt) Pt {
    return .{ .x = (a.x + b.x) * 0.5, .y = (a.y + b.y) * 0.5 };
}

/// Makes the coverage image of an outline at a scale (device pixels for
/// each font unit), moved right by `sub_x` of a pixel (0 to 0.75).
pub fn rasterize(gpa: std.mem.Allocator, o: ttf.Outline, scale: f32, sub_x: f32) !Bitmap {
    if (o.points.len == 0) return .{ .width = 0, .height = 0, .left = 0, .top = 0, .pixels = &.{} };
    var min_x: f32 = std.math.floatMax(f32);
    var min_y: f32 = std.math.floatMax(f32);
    var max_x: f32 = -std.math.floatMax(f32);
    var max_y: f32 = -std.math.floatMax(f32);
    for (o.points) |p| {
        const x = p.x * scale + sub_x;
        const y = -p.y * scale;
        min_x = @min(min_x, x);
        max_x = @max(max_x, x);
        min_y = @min(min_y, y);
        max_y = @max(max_y, y);
    }
    // A comparison with NaN is false, so a bad outline also stops here.
    const limit: f32 = 1 << 24;
    if (!(@abs(min_x) < limit and @abs(max_x) < limit and @abs(min_y) < limit and @abs(max_y) < limit)) return error.GlyphTooLarge;
    const left: i32 = @intFromFloat(@floor(min_x));
    const top: i32 = @intFromFloat(@floor(min_y));
    const right: i32 = @intFromFloat(@ceil(max_x));
    const bottom: i32 = @intFromFloat(@ceil(max_y));
    const w: usize = @intCast(@max(right - left, 1));
    const h: usize = @intCast(@max(bottom - top, 1));
    if (w > 4096 or h > 4096) return error.GlyphTooLarge;
    const acc_buf = try gpa.alloc(f32, w * h);
    defer gpa.free(acc_buf);
    @memset(acc_buf, 0);
    var acc: Acc = .{ .w = w, .h = h, .a = acc_buf };
    const ox: f32 = @floatFromInt(left);
    const oy: f32 = @floatFromInt(top);

    var start: usize = 0;
    for (o.contour_ends) |end_u| {
        const end: usize = end_u;
        if (end < start or end >= o.points.len) return error.BadOutline;
        const pts = o.points[start .. end + 1];
        start = end + 1;
        if (pts.len < 2) continue;
        const tp = struct {
            fn at(p: ttf.Point, scale_: f32, sx: f32, ox_: f32, oy_: f32) Pt {
                return .{ .x = p.x * scale_ + sx - ox_, .y = -p.y * scale_ - oy_ };
            }
        }.at;
        // Find the start: an on-curve point, or the middle of two off-curve points.
        var first_idx: usize = 0;
        var first: Pt = undefined;
        var have_on = false;
        for (pts, 0..) |p, i| if (p.on_curve) {
            first_idx = i;
            first = tp(p, scale, sub_x, ox, oy);
            have_on = true;
            break;
        };
        var first_off_start = false;
        if (!have_on) {
            first = mid(tp(pts[0], scale, sub_x, ox, oy), tp(pts[pts.len - 1], scale, sub_x, ox, oy));
            first_off_start = true;
        }
        var cur = first;
        var pending: ?Pt = null;
        const n = pts.len;
        var k: usize = 0;
        const count = if (first_off_start) n else n - 1;
        while (k < count) : (k += 1) {
            const idx = if (first_off_start) k else (first_idx + 1 + k) % n;
            const p = tp(pts[idx], scale, sub_x, ox, oy);
            if (pts[idx].on_curve) {
                if (pending) |c| {
                    flatten(&acc, cur, c, p);
                    pending = null;
                } else acc.line(cur, p);
                cur = p;
            } else {
                if (pending) |c| {
                    const m = mid(c, p);
                    flatten(&acc, cur, c, m);
                    cur = m;
                }
                pending = p;
            }
        }
        // Close the contour back to the first point.
        if (pending) |c| flatten(&acc, cur, c, first) else acc.line(cur, first);
    }

    const pixels = try gpa.alloc(u8, w * h);
    var y: usize = 0;
    while (y < h) : (y += 1) {
        var sum: f32 = 0;
        var x: usize = 0;
        while (x < w) : (x += 1) {
            sum += acc_buf[y * w + x];
            const cov = std.math.clamp(@abs(sum), 0, 1);
            pixels[y * w + x] = @intFromFloat(@round(cov * 255));
        }
    }
    return .{ .width = @intCast(w), .height = @intCast(h), .left = left, .top = top, .pixels = pixels };
}
