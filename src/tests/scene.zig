//! Tests of the scene, the CPU renderer, PNG, and the golden images.
//! The golden files are in tests/golden/. Each scene is 200 by 120
//! logical pixels. A tolerance of zero applies to all of them.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const geom = @import("../base/geom.zig");
const scene_mod = @import("../scene.zig");
const r = @import("../render/renderer.zig");
const cpu = @import("../render/cpu.zig");
const png = @import("../base/png.zig");
const testing_h = @import("../testing.zig");
const Scene = scene_mod.Scene;
const Builder = scene_mod.Builder;
const Quad = scene_mod.Quad;
const t = std.testing;

fn c(rgb: u24, a: u8) geom.Color {
    return .{ .r = @truncate(rgb >> 16), .g = @truncate(rgb >> 8), .b = @truncate(rgb), .a = a };
}

fn newImage(gpa: std.mem.Allocator, w: u32, h: u32) !r.Image {
    return .{ .width = w, .height = h, .pixels = try gpa.alloc(u8, @as(usize, w) * h * 4) };
}

fn px(img: r.Image, x: u32, y: u32) [4]u8 {
    return img.pixels[(y * img.width + x) * 4 ..][0..4].*;
}

test "scene: roundedDistance" {
    const rect = [4]f32{ 0, 0, 10, 10 };
    const none = [4]f32{ 0, 0, 0, 0 };
    try t.expectEqual(@as(f32, -5), r.roundedDistance(5, 5, rect, none));
    try t.expectEqual(@as(f32, 0), r.roundedDistance(0, 5, rect, none));
    try t.expectEqual(@as(f32, 0), r.roundedDistance(10, 5, rect, none));
    const round = [4]f32{ 5, 5, 5, 5 };
    // At the corner point of the bounding box the distance is positive.
    try t.expect(r.roundedDistance(0.1, 0.1, rect, round) > 0);
    // A radius larger than half the side is limited.
    try t.expectEqual(r.roundedDistance(5, 5, rect, round), r.roundedDistance(5, 5, rect, .{ 99, 99, 99, 99 }));
}

test "cpu: an opaque box covers exactly its pixels" {
    var s: Scene = .{};
    defer s.deinit(t.allocator);
    s.reset(10, 10);
    var b = Builder.init(t.allocator, &s, 1);
    try b.box(.{ .x = 2, .y = 2, .w = 4, .h = 4 }, .{ .fill = c(0xff0000, 255) });
    const img = try newImage(t.allocator, 10, 10);
    defer t.allocator.free(img.pixels);
    var out = img;
    cpu.render(&s, null, &out);
    var red: u32 = 0;
    for (0..10) |y| for (0..10) |x| {
        const p = px(img, @intCast(x), @intCast(y));
        const inside = x >= 2 and x < 6 and y >= 2 and y < 6;
        if (inside) {
            try t.expectEqual([4]u8{ 255, 0, 0, 255 }, p);
            red += 1;
        } else try t.expectEqual([4]u8{ 255, 255, 255, 255 }, p);
    };
    try t.expectEqual(@as(u32, 16), red);
}

test "cpu: a half transparent black box on white gives 128" {
    var s: Scene = .{};
    defer s.deinit(t.allocator);
    s.reset(4, 4);
    // The alpha is exactly 0.5: 255 * 0.5 = 127.5 rounds to 128.
    var q: Quad = undefined;
    q = std.mem.zeroes(Quad);
    q.rect = .{ 0, 0, 4, 4 };
    q.clip = .{ 0, 0, 4, 4 };
    q.fill = .{ 0, 0, 0, 0.5 };
    q.fill2 = q.fill;
    q.params = .{ 0, 0, 0, 1 };
    try s.quads.append(t.allocator, q);
    var img = try newImage(t.allocator, 4, 4);
    defer t.allocator.free(img.pixels);
    cpu.render(&s, null, &img);
    try t.expectEqual([4]u8{ 128, 128, 128, 255 }, px(img, 1, 1));
}

test "cpu: a clip cuts a box in half" {
    var s: Scene = .{};
    defer s.deinit(t.allocator);
    s.reset(10, 10);
    var b = Builder.init(t.allocator, &s, 1);
    b.pushClip(.{ .x = 0, .y = 0, .w = 5, .h = 10 });
    try b.box(.{ .x = 2, .y = 0, .w = 6, .h = 10 }, .{ .fill = c(0x000000, 255) });
    b.popClip();
    var img = try newImage(t.allocator, 10, 10);
    defer t.allocator.free(img.pixels);
    cpu.render(&s, null, &img);
    try t.expectEqual([4]u8{ 0, 0, 0, 255 }, px(img, 4, 3));
    try t.expectEqual([4]u8{ 255, 255, 255, 255 }, px(img, 5, 3));
    try t.expectEqual([4]u8{ 255, 255, 255, 255 }, px(img, 1, 3));
}

test "cpu: the builder rounds edges, borders, and skips invisible boxes" {
    var s: Scene = .{};
    defer s.deinit(t.allocator);
    s.reset(100, 100);
    var b = Builder.init(t.allocator, &s, 1.25);
    try b.box(.{ .x = 1, .y = 1, .w = 3, .h = 3 }, .{ .fill = c(0, 255), .border = .{ 0.4, 0, 0, 0 } });
    try t.expectEqual(@as(usize, 1), s.quads.items.len);
    const q = s.quads.items[0];
    // 1 * 1.25 = 1.25 rounds to 1. 4 * 1.25 = 5.
    try t.expectEqual([4]f32{ 1, 1, 4, 4 }, q.rect);
    // A border of 0.4 pixels shows as 1 device pixel.
    try t.expectEqual(@as(f32, 1), q.border[0]);
    try b.box(.{ .x = 0, .y = 0, .w = 5, .h = 5 }, .{});
    try t.expectEqual(@as(usize, 1), s.quads.items.len);
}

test "png: encode and decode round trip" {
    const img = try newImage(t.allocator, 64, 64);
    defer t.allocator.free(img.pixels);
    for (img.pixels, 0..) |*p, i| p.* = @truncate((i * 7) ^ (i >> 3));
    const bytes = try png.encode(t.allocator, img);
    defer t.allocator.free(bytes);
    const back = try png.decode(t.allocator, bytes);
    defer t.allocator.free(back.pixels);
    try t.expectEqual(@as(u32, 64), back.width);
    try t.expectEqualSlices(u8, img.pixels, back.pixels);
}

test "png: decode a file from another program" {
    // Made with the Python standard library (zlib and struct): a 2 by 2
    // image with filter types 1, 2 for the two rows.
    const bytes = [_]u8{
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x08, 0x06, 0x00, 0x00, 0x00, 0x72, 0xb6, 0x0d,
        0x24, 0x00, 0x00, 0x00, 0x17, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0xe4, 0x12, 0x91, 0xfb,
        0x2f, 0x27, 0x27, 0xc7, 0xc0, 0x64, 0x63, 0x63, 0xc3, 0x00, 0xc2, 0x00, 0x1d, 0x14, 0x03, 0x01,
        0x40, 0xa7, 0x40, 0x0b, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
    };
    const img = try png.decode(t.allocator, &bytes);
    defer t.allocator.free(img.pixels);
    try t.expectEqual([_]u8{ 10, 20, 30, 255, 40, 50, 60, 255, 70, 80, 90, 255, 100, 110, 120, 255 }, img.pixels[0..16].*);
}

test "png: decode refuses bad input" {
    try t.expectError(error.NotPng, png.decode(t.allocator, "not a png file"));
    const img = try newImage(t.allocator, 2, 2);
    defer t.allocator.free(img.pixels);
    @memset(img.pixels, 7);
    const bytes = try png.encode(t.allocator, img);
    defer t.allocator.free(bytes);
    const bad = try t.allocator.dupe(u8, bytes);
    defer t.allocator.free(bad);
    bad[20] ^= 1;
    try t.expectError(error.BadCrc, png.decode(t.allocator, bad));
    try t.expectError(error.Truncated, png.decode(t.allocator, bytes[0 .. bytes.len - 20]));
}

test "scene: changedRows" {
    const a = try newImage(t.allocator, 4, 12);
    defer t.allocator.free(a.pixels);
    var b = try newImage(t.allocator, 4, 12);
    defer t.allocator.free(b.pixels);
    @memset(a.pixels, 0);
    @memset(b.pixels, 0);
    var out: [8]r.RowRange = undefined;
    try t.expectEqual(@as(usize, 0), r.changedRows(a, b, &out).len);
    for ([_]usize{ 3, 4, 9 }) |row| b.pixels[row * 16 + 5] = 1;
    const got = r.changedRows(a, b, &out);
    try t.expectEqual(@as(usize, 2), got.len);
    try t.expectEqual(r.RowRange{ .first = 3, .last = 5 }, got[0]);
    try t.expectEqual(r.RowRange{ .first = 9, .last = 10 }, got[1]);
    var two: [2]r.RowRange = undefined;
    for ([_]usize{ 0, 2, 4, 6 }) |row| b.pixels[row * 16] = 1;
    const few = r.changedRows(a, b, &two);
    try t.expectEqual(@as(usize, 2), few.len);
    try t.expectEqual(r.RowRange{ .first = 0, .last = 1 }, few[0]);
    try t.expectEqual(r.RowRange{ .first = 2, .last = 10 }, few[1]);
}

// ---- golden scenes ----

pub const names = [_][]const u8{ "box-plain", "box-radius", "box-border", "box-gradient", "box-shadow", "box-clip" };

pub fn build(gpa: std.mem.Allocator, s: *Scene, which: usize, scale: f32) !void {
    s.reset(@intFromFloat(200 * scale), @intFromFloat(120 * scale));
    var b = Builder.init(gpa, s, scale);
    switch (which) {
        0 => try b.box(.{ .x = 20, .y = 20, .w = 80, .h = 50 }, .{ .fill = c(0x3366cc, 255) }),
        1 => {
            try b.box(.{ .x = 10, .y = 10, .w = 80, .h = 50 }, .{ .fill = c(0x3366cc, 255), .radii = .{ 8, 8, 8, 8 } });
            try b.box(.{ .x = 110, .y = 10, .w = 80, .h = 50 }, .{ .fill = c(0xcc6633, 255), .radii = .{ 4, 16, 28, 0 } });
            try b.box(.{ .x = 10, .y = 70, .w = 40, .h = 40 }, .{ .fill = c(0x339966, 255), .radii = .{ 20, 20, 20, 20 } });
        },
        2 => {
            try b.box(.{ .x = 10, .y = 10, .w = 80, .h = 50 }, .{ .fill = c(0xe8f0ff, 255), .border = .{ 1, 1, 1, 1 }, .border_color = c(0x224488, 255), .radii = .{ 6, 6, 6, 6 } });
            try b.box(.{ .x = 110, .y = 10, .w = 80, .h = 50 }, .{ .fill = c(0xe8f0ff, 255), .border = .{ 3, 3, 3, 3 }, .border_color = c(0x224488, 255), .radii = .{ 6, 6, 6, 6 } });
            try b.box(.{ .x = 10, .y = 70, .w = 80, .h = 40 }, .{ .fill = c(0xffffff, 255), .border = .{ 1, 3, 1, 3 }, .border_color = c(0x884422, 255) });
        },
        3 => {
            try b.box(.{ .x = 10, .y = 10, .w = 80, .h = 100 }, .{ .fill = c(0xffffff, 255), .fill2 = c(0x2244aa, 255), .gradient_angle_deg = 180 });
            try b.box(.{ .x = 110, .y = 10, .w = 80, .h = 100 }, .{ .fill = c(0xff0000, 255), .fill2 = c(0xffff00, 255), .gradient_angle_deg = 90, .radii = .{ 10, 10, 10, 10 } });
        },
        4 => {
            try b.shadow(.{ .x = 50, .y = 30, .w = 100, .h = 60 }, .{ 8, 8, 8, 8 }, .{ .dy = 4, .blur = 12, .color = c(0x000000, 128) });
            try b.box(.{ .x = 50, .y = 30, .w = 100, .h = 60 }, .{ .fill = c(0xffffff, 255), .radii = .{ 8, 8, 8, 8 }, .border = .{ 1, 1, 1, 1 }, .border_color = c(0xcccccc, 255) });
        },
        5 => {
            b.pushClip(.{ .x = 20, .y = 20, .w = 100, .h = 60 });
            try b.box(.{ .x = 10, .y = 10, .w = 60, .h = 40 }, .{ .fill = c(0x3366cc, 255), .radii = .{ 8, 8, 8, 8 } });
            try b.box(.{ .x = 90, .y = 50, .w = 60, .h = 60 }, .{ .fill = c(0xcc6633, 255), .radii = .{ 30, 30, 30, 30 } });
            try b.box(.{ .x = 40, .y = 30, .w = 40, .h = 40 }, .{ .fill = c(0x339966, 200), .border = .{ 2, 2, 2, 2 }, .border_color = c(0x000000, 255) });
            b.popClip();
        },
        else => unreachable,
    }
}

fn goldenCase(which: usize, scale: f32, suffix: []const u8) !void {
    var s: Scene = .{};
    defer s.deinit(t.allocator);
    try build(t.allocator, &s, which, scale);
    var img = try newImage(t.allocator, s.width, s.height);
    defer t.allocator.free(img.pixels);
    cpu.render(&s, null, &img);
    var nbuf: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&nbuf, "{s}{s}", .{ names[which], suffix });
    try testing_h.expectGolden(name, img, .{});
    try testing_h.expectScene(name, &s);
}

test "scene: golden box-plain at scale 1 and 2" {
    try goldenCase(0, 1, "");
    try goldenCase(0, 2, "@2");
}
test "scene: golden box-radius" {
    try goldenCase(1, 1, "");
}
test "scene: golden box-border" {
    try goldenCase(2, 1, "");
}
test "scene: golden box-gradient" {
    try goldenCase(3, 1, "");
}
test "scene: golden box-shadow" {
    try goldenCase(4, 1, "");
}
test "scene: golden box-clip" {
    try goldenCase(5, 1, "");
}

test "scene: expectGolden fails on a changed pixel and writes the extra files" {
    // In update mode expectGolden would write the changed image over the golden file.
    if (t.environ.contains(t.allocator, "ZTK_UPDATE_GOLDEN") catch false) return error.SkipZigTest;
    var s: Scene = .{};
    defer s.deinit(t.allocator);
    try build(t.allocator, &s, 0, 1);
    var img = try newImage(t.allocator, s.width, s.height);
    defer t.allocator.free(img.pixels);
    cpu.render(&s, null, &img);
    img.pixels[(5 * img.width + 5) * 4] ^= 0x10;
    try t.expectError(error.GoldenMismatch, testing_h.expectGolden("box-plain", img, .{}));
    const build_options = @import("build_options");
    var buf: [512]u8 = undefined;
    for ([_][]const u8{ ".actual.png", ".diff.png" }) |suffix| {
        const path = try std.fmt.bufPrint(&buf, "{s}/tests/golden/box-plain{s}", .{ build_options.repo_root, suffix });
        try std.Io.Dir.cwd().deleteFile(t.io, path);
    }
    // A tolerance of one level in each channel does not accept 16.
    try t.expectError(error.GoldenMismatch, testing_h.expectGolden("box-plain", img, .{ .max_level = 8 }));
    for ([_][]const u8{ ".actual.png", ".diff.png" }) |suffix| {
        const path = try std.fmt.bufPrint(&buf, "{s}/tests/golden/box-plain{s}", .{ build_options.repo_root, suffix });
        try std.Io.Dir.cwd().deleteFile(t.io, path);
    }
}

test "cpu: headless draw gives an image" {
    var h: testing_h.Harness = undefined;
    try h.init();
    defer h.deinit();
    var s: Scene = .{};
    defer s.deinit(t.allocator);
    s.reset(20, 20);
    var b = Builder.init(t.allocator, &s, 1);
    try b.box(.{ .x = 0, .y = 0, .w = 20, .h = 20 }, .{ .fill = c(0x00ff00, 255) });
    const target = h.head.platform().target(h.win);
    const frame: scene_mod.Frame = .{ .scene = s };
    try target.draw(target.ctx, &frame);
    try t.expectEqual(@as(u32, 1), h.head.frames_drawn);
    const im = h.head.image(h.win).?;
    try t.expectEqual([4]u8{ 0, 255, 0, 255 }, px(im, 3, 3));
}

test "cpu-speed: 10000 boxes of 100 by 30 in 1920 by 1080" {
    var s: Scene = .{};
    defer s.deinit(t.allocator);
    s.reset(1920, 1080);
    var b = Builder.init(t.allocator, &s, 1);
    var i: i32 = 0;
    while (i < 10000) : (i += 1) {
        const x = @mod(i * 37, 1820);
        const y = @mod(i * 53, 1050);
        try b.box(.{ .x = x, .y = y, .w = 100, .h = 30 }, .{ .fill = c(@intCast(@mod(i * 7919, 0xffffff)), 255), .radii = .{ 4, 4, 4, 4 }, .border = .{ 1, 1, 1, 1 }, .border_color = c(0x333333, 255) });
    }
    var img = try newImage(t.allocator, 1920, 1080);
    defer t.allocator.free(img.pixels);
    const t0 = std.Io.Clock.awake.now(t.io);
    cpu.render(&s, null, &img);
    const ns = t0.untilNow(t.io, .awake).toNanoseconds();
    std.debug.print("cpu-speed: {d:.1} ms ({s})\n", .{ @as(f64, @floatFromInt(ns)) / 1e6, @tagName(@import("builtin").mode) });
}
