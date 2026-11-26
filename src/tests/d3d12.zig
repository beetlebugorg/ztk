//! Tests of the Direct3D 12 renderer. Each test starts with `D3D12.init`.
//! A machine with no Direct3D 12 prints `SKIP:` with the reason, and the
//! test returns. The scenes are the golden scenes of the CPU renderer,
//! and the tolerance is that of the Vulkan tests: at most 2 levels in a
//! channel, in at most 0.1 % of the pixels. The tests draw offscreen and
//! open no window.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const build_options = @import("build_options");
const scene_mod = @import("../scene.zig");
const cpu = @import("../render/cpu.zig");
const png = @import("../png.zig");
const r = @import("../render/renderer.zig");
const atlas_mod = @import("../text/atlas.zig");
const dx = @import("../render/d3d12.zig");
const scene_tests = @import("scene.zig");
const text_tests = @import("text.zig");
const testing_h = @import("../testing.zig");
const t = std.testing;

const Scene = scene_mod.Scene;

fn open(opts: dx.Options) ?*dx.D3D12 {
    return dx.D3D12.init(t.allocator, opts) catch |e| {
        std.debug.print("SKIP: no Direct3D 12 device ({s})\n", .{@errorName(e)});
        return null;
    };
}

fn newImage(w: u32, h: u32) !r.Image {
    return .{ .width = w, .height = h, .pixels = try t.allocator.alloc(u8, @as(usize, w) * h * 4) };
}

/// Draws a scene with both renderers and compares the images.
fn compare(v: *dx.D3D12, name: []const u8, s: *const Scene, atlas: *const atlas_mod.Atlas) !void {
    var cpu_img = try newImage(s.width, s.height);
    defer t.allocator.free(cpu_img.pixels);
    cpu.render(s, atlas, &cpu_img);
    const target = try v.createOffscreen(s.width, s.height);
    defer v.destroyTarget(target);
    v.setTarget(target);
    try v.draw(s, atlas);
    var gpu_img = try newImage(s.width, s.height);
    defer t.allocator.free(gpu_img.pixels);
    try v.readPixels(target, &gpu_img);
    var count: usize = 0;
    var worst: u8 = 0;
    const diff = try t.allocator.alloc(u8, cpu_img.pixels.len);
    defer t.allocator.free(diff);
    var i: usize = 0;
    while (i < cpu_img.pixels.len) : (i += 4) {
        var d: u8 = 0;
        for (0..4) |ch| {
            const a = cpu_img.pixels[i + ch];
            const b = gpu_img.pixels[i + ch];
            d = @max(d, if (a > b) a - b else b - a);
        }
        worst = @max(worst, d);
        if (d > 2) count += 1;
        const px: [4]u8 = if (d > 2) .{ 255, 0, 0, 255 } else .{ 255, 255, 255, 255 };
        @memcpy(diff[i..][0..4], &px);
    }
    const total = cpu_img.pixels.len / 4;
    std.debug.print("d3d12 {s}: {d} of {d} pixels differ by more than 2, worst {d}\n", .{ name, count, total, worst });
    if (count * 1000 > total) {
        var pbuf: [512]u8 = undefined;
        const base = try std.fmt.bufPrint(&pbuf, "{s}/tests/golden/{s}", .{ build_options.repo_root, name });
        var p1: [600]u8 = undefined;
        const gp = try std.fmt.bufPrint(&p1, "{s}.d3d12.png", .{base});
        const bytes = try png.encode(t.allocator, gpu_img);
        defer t.allocator.free(bytes);
        try std.Io.Dir.cwd().writeFile(t.io, .{ .sub_path = gp, .data = bytes });
        var p2: [600]u8 = undefined;
        const dp = try std.fmt.bufPrint(&p2, "{s}.d3d12-diff.png", .{base});
        const db = try png.encode(t.allocator, .{ .width = cpu_img.width, .height = cpu_img.height, .pixels = diff });
        defer t.allocator.free(db);
        try std.Io.Dir.cwd().writeFile(t.io, .{ .sub_path = dp, .data = db });
        return error.GpuMismatch;
    }
}

fn boxScenes(v: *dx.D3D12) !void {
    var atlas = atlas_mod.Atlas.init(t.allocator);
    defer atlas.deinit();
    for (scene_tests.names, 0..) |name, which| {
        var s: Scene = .{};
        defer s.deinit(t.allocator);
        try scene_tests.build(t.allocator, &s, which, 1);
        try compare(v, name, &s, &atlas);
    }
    var s2: Scene = .{};
    defer s2.deinit(t.allocator);
    try scene_tests.build(t.allocator, &s2, 0, 2);
    try compare(v, "box-plain@2", &s2, &atlas);
}

test "d3d12: init and deinit" {
    const v = open(.{ .debug = true }) orelse return;
    defer v.deinit();
    std.debug.print("d3d12 device: {s}, warp: {}, software: {}\n", .{ v.deviceName(), v.warp, v.software });
}

test "d3d12: the box scenes equal the CPU renderer" {
    const v = open(.{}) orelse return;
    defer v.deinit();
    try boxScenes(v);
}

test "d3d12: the box scenes equal the CPU renderer on the WARP adapter" {
    const v = open(.{ .warp = true }) orelse return;
    defer v.deinit();
    try t.expect(v.warp);
    try boxScenes(v);
}

test "d3d12: the text scenes equal the CPU renderer" {
    const v = open(.{}) orelse return;
    defer v.deinit();
    for (text_tests.text_names, 0..) |name, which| {
        var s: text_tests.Setup = undefined;
        try s.init();
        defer s.deinit();
        try text_tests.buildText(&s, which);
        try compare(v, name, &s.scene, &s.atlas);
    }
}

test "d3d12: an empty scene gives the clear color" {
    const v = open(.{}) orelse return;
    defer v.deinit();
    var atlas = atlas_mod.Atlas.init(t.allocator);
    defer atlas.deinit();
    var s: Scene = .{};
    defer s.deinit(t.allocator);
    s.reset(16, 8);
    s.clear = .{ 1, 0, 0.2, 1 };
    const target = try v.createOffscreen(16, 8);
    defer v.destroyTarget(target);
    v.setTarget(target);
    try v.draw(&s, &atlas);
    var img = try newImage(16, 8);
    defer t.allocator.free(img.pixels);
    try v.readPixels(target, &img);
    try t.expectEqualSlices(u8, &.{ 255, 0, 51, 255 }, img.pixels[0..4]);
    try t.expectEqualSlices(u8, &.{ 255, 0, 51, 255 }, img.pixels[img.pixels.len - 4 ..]);
}

test "d3d12: 20,000 quads grow the buffer and draw" {
    const v = open(.{}) orelse return;
    defer v.deinit();
    var atlas = atlas_mod.Atlas.init(t.allocator);
    defer atlas.deinit();
    var s: Scene = .{};
    defer s.deinit(t.allocator);
    s.reset(200, 200);
    var b = scene_mod.Builder.init(t.allocator, &s, 1);
    var i: i32 = 0;
    while (i < 20000) : (i += 1) {
        try b.box(.{ .x = @mod(i, 190), .y = @mod(@divTrunc(i, 190), 190), .w = 8, .h = 8 }, .{ .fill = .{ .r = @intCast(@mod(i, 255)), .g = 80, .b = 160 }, .radii = .{ 2, 2, 2, 2 } });
    }
    try compare(v, "many-boxes", &s, &atlas);
}

test "d3d12: two draws to one target leave no rest of the first" {
    const v = open(.{}) orelse return;
    defer v.deinit();
    var atlas = atlas_mod.Atlas.init(t.allocator);
    defer atlas.deinit();
    var a: Scene = .{};
    defer a.deinit(t.allocator);
    var bscene: Scene = .{};
    defer bscene.deinit(t.allocator);
    a.reset(64, 64);
    bscene.reset(64, 64);
    var ba = scene_mod.Builder.init(t.allocator, &a, 1);
    try ba.box(.{ .x = 0, .y = 0, .w = 64, .h = 64 }, .{ .fill = .{ .r = 255, .g = 0, .b = 0 } });
    const target = try v.createOffscreen(64, 64);
    defer v.destroyTarget(target);
    v.setTarget(target);
    try v.draw(&a, &atlas);
    try v.draw(&bscene, &atlas);
    var img = try newImage(64, 64);
    defer t.allocator.free(img.pixels);
    try v.readPixels(target, &img);
    try t.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, img.pixels[0..4]);
}

test "d3d12: a changed atlas uploads again" {
    const v = open(.{}) orelse return;
    defer v.deinit();
    var s: text_tests.Setup = undefined;
    try s.init();
    defer s.deinit();
    s.scene.reset(120, 40);
    var b = scene_mod.Builder.init(t.allocator, &s.scene, 1);
    try s.line(&b, .{ .size = 16 }, 1, "ab", 4, 24, .{ .r = 0, .g = 0, .b = 0 });
    try compare(v, "atlas-one", &s.scene, &s.atlas);
    // A new glyph changes the atlas page between two draws.
    try s.line(&b, .{ .size = 16 }, 1, "xyz@", 40, 24, .{ .r = 0, .g = 0, .b = 0 });
    try compare(v, "atlas-two", &s.scene, &s.atlas);
}

test "d3d12: the demo scene equals the CPU renderer" {
    const v = open(.{}) orelse return;
    defer v.deinit();
    var h: testing_h.Harness = undefined;
    try h.initExamples(false);
    defer h.deinit();
    try h.loadFile("examples/demo.tcl");
    try h.update();
    try compare(v, "demo-start", h.app.lastScene(), &h.app.atlas);
}

test "d3d12-speed: 10,000 quads" {
    const v = open(.{}) orelse return;
    defer v.deinit();
    var atlas = atlas_mod.Atlas.init(t.allocator);
    defer atlas.deinit();
    var s: Scene = .{};
    defer s.deinit(t.allocator);
    s.reset(1920, 1080);
    var b = scene_mod.Builder.init(t.allocator, &s, 1);
    var i: i32 = 0;
    while (i < 10000) : (i += 1) {
        try b.box(.{ .x = @mod(i * 37, 1800), .y = @mod(i * 53, 1000), .w = 100, .h = 60 }, .{ .fill = .{ .r = 40, .g = @intCast(@mod(i, 200)), .b = 200, .a = 200 }, .radii = .{ 8, 8, 8, 8 } });
    }
    const target = try v.createOffscreen(1920, 1080);
    defer v.destroyTarget(target);
    v.setTarget(target);
    try v.draw(&s, &atlas);
    const t0 = std.Io.Clock.awake.now(t.io);
    // A software adapter needs about 1 second for one draw in Debug, so it draws 3 times.
    const runs: u32 = if (v.software) 3 else 100;
    for (0..runs) |_| try v.draw(&s, &atlas);
    const ns = t0.untilNow(t.io, .awake).toNanoseconds();
    std.debug.print("d3d12-speed: {d:.3} ms for one draw of 10000 quads on {s} ({s})\n", .{ @as(f64, @floatFromInt(ns)) / 1e6 / @as(f64, @floatFromInt(runs)), v.deviceName(), @tagName(@import("builtin").mode) });
}

/// Image quads at the size of the image, scaled up, and with an opacity.
fn imageScene(v: *dx.D3D12) !void {
    var atlas = atlas_mod.Atlas.init(t.allocator);
    defer atlas.deinit();
    // A 6 by 4 image with a color ramp and a ramp of alpha.
    var px: [6 * 4 * 4]u8 = undefined;
    for (0..4) |y| for (0..6) |x| {
        const o = (y * 6 + x) * 4;
        px[o..][0..4].* = .{ @intCast(x * 50), @intCast(y * 80), 200, @intCast(255 - x * 30) };
    };
    const uv = (try atlas.image(1, 6, 4, &px)).?;
    var s: Scene = .{};
    defer s.deinit(t.allocator);
    s.reset(80, 40);
    s.clear = .{ 0.9, 0.9, 0.9, 1 };
    var b = scene_mod.Builder.init(t.allocator, &s, 1);
    try b.image(.{ .x = 2, .y = 2, .w = 6, .h = 4 }, uv, 1);
    try b.image(.{ .x = 12, .y = 2, .w = 18, .h = 12 }, uv, 1);
    try b.image(.{ .x = 40, .y = 2, .w = 30, .h = 30 }, uv, 0.5);
    try compare(v, "image-quads", &s, &atlas);
}

test "d3d12: image quads equal the CPU renderer" {
    const v = open(.{}) orelse return;
    defer v.deinit();
    try imageScene(v);
}

test "d3d12: image quads equal the CPU renderer on the WARP adapter" {
    const v = open(.{ .warp = true }) orelse return;
    defer v.deinit();
    try imageScene(v);
}

test "d3d12: the scene of the label-photo golden equals the CPU renderer" {
    const v = open(.{}) orelse return;
    defer v.deinit();
    var h: testing_h.Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("wm geometry . 60x40");
    _ = try h.eval("image create photo dot -width 4 -height 2; dot put {{#ff0000 #00ff00 #0000ff #ffffff} {#000000 #000000 #000000 #000000}}; ttk::label .l -image dot -padding 0; place .l -x 10 -y 10");
    try h.update();
    try compare(v, "label-photo", h.app.lastScene(), &h.app.atlas);
}
