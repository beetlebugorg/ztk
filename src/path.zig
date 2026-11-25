//! Shapes that the quad form has no kind for: polygons, strokes, and
//! ellipses. A shape is a list of closed contours in device pixels. The
//! rasterizer samples each pixel of the bounding box at 4 by 4 points.
//! A point is in the shape when one contour has it by the nonzero winding
//! rule, and gives a coverage from 0 to 16 for
//! each pixel. Each run of pixels with the same coverage in a row is one
//! box quad with the color at that alpha, so the scene keeps one quad
//! form and the CPU and GPU renderers need no new kind. Section D4 of the
//! plan has the reason. A stroke is the union of one quad for each
//! segment and a disc at each joint.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const geom = @import("geom.zig");
const scene = @import("scene.zig");

pub const Pt = struct { x: f32, y: f32 };

/// A shape: the points of its contours, and the end index of each contour.
pub const Shape = struct {
    pts: std.ArrayListUnmanaged(Pt) = .empty,
    ends: std.ArrayListUnmanaged(u32) = .empty,

    pub fn deinit(s: *Shape, gpa: std.mem.Allocator) void {
        s.pts.deinit(gpa);
        s.ends.deinit(gpa);
    }

    pub fn contour(s: *Shape, gpa: std.mem.Allocator, pts: []const Pt) !void {
        if (pts.len < 3) return;
        try s.pts.appendSlice(gpa, pts);
        try s.ends.append(gpa, @intCast(s.pts.items.len));
    }

    /// An ellipse as a polygon with enough points for its size.
    pub fn ellipse(s: *Shape, gpa: std.mem.Allocator, cx: f32, cy: f32, rx: f32, ry: f32) !void {
        const r = @max(@abs(rx), @abs(ry));
        const n: usize = std.math.clamp(@as(usize, @intFromFloat(@ceil(r * 1.5))) + 8, 12, 720);
        for (0..n) |i| {
            const a = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n)) * std.math.tau;
            try s.pts.append(gpa, .{ .x = cx + rx * @cos(a), .y = cy + ry * @sin(a) });
        }
        try s.ends.append(gpa, @intCast(s.pts.items.len));
    }

    /// A line of width `wd` through the points, with round joints and ends when `round` is set.
    pub fn stroke(s: *Shape, gpa: std.mem.Allocator, pts: []const Pt, wd: f32, round: bool) !void {
        const h = wd / 2;
        for (pts[0..pts.len -| 1], 1..) |p, i| {
            const q = pts[i];
            const dx = q.x - p.x;
            const dy = q.y - p.y;
            const len = @sqrt(dx * dx + dy * dy);
            if (len == 0) continue;
            const nx = -dy / len * h;
            const ny = dx / len * h;
            try s.contour(gpa, &.{ .{ .x = p.x + nx, .y = p.y + ny }, .{ .x = q.x + nx, .y = q.y + ny }, .{ .x = q.x - nx, .y = q.y - ny }, .{ .x = p.x - nx, .y = p.y - ny } });
        }
        if (round) for (pts) |p| try s.ellipse(gpa, p.x, p.y, h, h);
    }
};

/// True when a point is inside the shape: inside one of its contours
/// with the nonzero rule. The shape is the union of its contours, so the
/// pieces of a stroke do not cancel where they overlap.
fn inside(s: *const Shape, x: f32, y: f32) bool {
    var start: u32 = 0;
    for (s.ends.items) |end| {
        const c = s.pts.items[start..end];
        start = end;
        var wn: i32 = 0;
        for (c, 0..) |a, i| {
            const b = c[(i + 1) % c.len];
            if (a.y <= y) {
                if (b.y > y and (b.x - a.x) * (y - a.y) - (x - a.x) * (b.y - a.y) > 0) wn += 1;
            } else if (b.y <= y and (b.x - a.x) * (y - a.y) - (x - a.x) * (b.y - a.y) < 0) wn -= 1;
        }
        if (wn != 0) return true;
    }
    return false;
}

/// The coverage rows of a shape inside a clip, as box quads. The points
/// are device pixels. `color` is the color at full coverage.
pub fn fill(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(scene.Quad), s: *const Shape, clip: [4]f32, color: [4]f32, opacity: f32) !void {
    if (s.pts.items.len < 3 or color[3] == 0) return;
    var x0: f32 = std.math.inf(f32);
    var y0: f32 = std.math.inf(f32);
    var x1: f32 = -std.math.inf(f32);
    var y1: f32 = -std.math.inf(f32);
    for (s.pts.items) |p| {
        x0 = @min(x0, p.x);
        y0 = @min(y0, p.y);
        x1 = @max(x1, p.x);
        y1 = @max(y1, p.y);
    }
    const cx0 = @max(@floor(x0), clip[0]);
    const cy0 = @max(@floor(y0), clip[1]);
    const cx1 = @min(@ceil(x1), clip[0] + clip[2]);
    const cy1 = @min(@ceil(y1), clip[1] + clip[3]);
    if (cx1 <= cx0 or cy1 <= cy0) return;
    // A limit for a very large shape: 4096 by 4096 device pixels.
    const ix0: i32 = @intFromFloat(cx0);
    const iy0: i32 = @intFromFloat(cy0);
    const ix1: i32 = @min(@as(i32, @intFromFloat(cx1)), ix0 + 4096);
    const iy1: i32 = @min(@as(i32, @intFromFloat(cy1)), iy0 + 4096);
    var y = iy0;
    while (y < iy1) : (y += 1) {
        var run_start = ix0;
        var run_cov: u8 = 255;
        var x = ix0;
        while (x <= ix1) : (x += 1) {
            var cov: u8 = 0;
            if (x < ix1) {
                const fx: f32 = @floatFromInt(x);
                const fy: f32 = @floatFromInt(y);
                var sy: u8 = 0;
                while (sy < 4) : (sy += 1) {
                    var sx: u8 = 0;
                    while (sx < 4) : (sx += 1) {
                        const px = fx + (@as(f32, @floatFromInt(sx)) + 0.5) / 4;
                        const py = fy + (@as(f32, @floatFromInt(sy)) + 0.5) / 4;
                        if (inside(s, px, py)) cov += 1;
                    }
                }
            }
            if (x == ix1 or cov != run_cov) {
                if (run_cov != 255 and run_cov > 0 and x > run_start) {
                    var c = color;
                    c[3] *= @as(f32, @floatFromInt(run_cov)) / 16;
                    try out.append(gpa, .{
                        .rect = .{ @floatFromInt(run_start), @floatFromInt(y), @floatFromInt(x - run_start), 1 },
                        .clip = clip,
                        .radii = .{ 0, 0, 0, 0 },
                        .border = .{ 0, 0, 0, 0 },
                        .fill = c,
                        .fill2 = c,
                        .border_color = .{ 0, 0, 0, 0 },
                        .uv = .{ 0, 0, 0, 0 },
                        .params = .{ 0, 0, 0, opacity },
                        .kind = @intFromEnum(scene.Kind.box),
                    });
                }
                run_start = x;
                run_cov = cov;
            }
        }
    }
}

const testing = std.testing;

test "path: a square covers its pixels in full and its edge in part" {
    var s: Shape = .{};
    defer s.deinit(testing.allocator);
    try s.contour(testing.allocator, &.{ .{ .x = 1, .y = 1 }, .{ .x = 5, .y = 1 }, .{ .x = 5, .y = 4.5 }, .{ .x = 1, .y = 4.5 } });
    var q: std.ArrayListUnmanaged(scene.Quad) = .empty;
    defer q.deinit(testing.allocator);
    try fill(testing.allocator, &q, &s, .{ 0, 0, 10, 10 }, .{ 1, 0, 0, 1 }, 1);
    // Rows 1, 2, 3 are full; row 4 is half.
    try testing.expectEqual(@as(usize, 4), q.items.len);
    try testing.expectEqual(@as(f32, 4), q.items[0].rect[2]);
    try testing.expectEqual(@as(f32, 1), q.items[0].fill[3]);
    try testing.expectEqual(@as(f32, 0.5), q.items[3].fill[3]);
}

test "path: two contours that overlap with opposite turns are a union" {
    var s: Shape = .{};
    defer s.deinit(testing.allocator);
    try s.contour(testing.allocator, &.{ .{ .x = 0, .y = 0 }, .{ .x = 9, .y = 0 }, .{ .x = 9, .y = 9 }, .{ .x = 0, .y = 9 } });
    try s.contour(testing.allocator, &.{ .{ .x = 3, .y = 3 }, .{ .x = 3, .y = 6 }, .{ .x = 6, .y = 6 }, .{ .x = 6, .y = 3 } });
    try testing.expect(inside(&s, 4.5, 4.5));
    try testing.expect(inside(&s, 1.5, 4.5));
    try testing.expect(!inside(&s, 9.5, 4.5));
}
