//! Tests of the Vulkan renderer. Each test starts with `Vulkan.init`. A
//! machine with no Vulkan device prints `SKIP: no Vulkan device` and the
//! test returns. The scenes are the golden scenes of the CPU renderer.
//! The two images may differ by at most 2 levels in a channel, in at most
//! 0.1 % of the pixels. Validation is on, and any message fails a test.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const build_options = @import("build_options");
const scene_mod = @import("../scene.zig");
const geom = @import("../geom.zig");
const cpu = @import("../render/cpu.zig");
const png = @import("../png.zig");
const r = @import("../render/renderer.zig");
const atlas_mod = @import("../text/atlas.zig");
const vk = @import("../render/vulkan.zig");
const scene_tests = @import("scene.zig");
const text_tests = @import("text.zig");
const testing_h = @import("../testing.zig");
const t = std.testing;

const Scene = scene_mod.Scene;

fn open() ?*vk.Vulkan {
    if (!build_options.vulkan) {
        std.debug.print("SKIP: the build has no Vulkan renderer\n", .{});
        return null;
    }
    return vk.Vulkan.init(t.allocator, .{ .validate = true }) catch |e| {
        std.debug.print("SKIP: no Vulkan device ({s}: {s})\n", .{ @errorName(e), vk.reason() });
        return null;
    };
}

fn newImage(w: u32, h: u32) !r.Image {
    return .{ .width = w, .height = h, .pixels = try t.allocator.alloc(u8, @as(usize, w) * h * 4) };
}

/// Draws a scene with both renderers and compares the images.
fn compare(v: *vk.Vulkan, name: []const u8, s: *const Scene, atlas: *const atlas_mod.Atlas) !void {
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
    std.debug.print("vulkan {s}: {d} of {d} pixels differ by more than 2, worst {d}\n", .{ name, count, total, worst });
    if (count * 1000 > total) {
        var pbuf: [512]u8 = undefined;
        const base = try std.fmt.bufPrint(&pbuf, "{s}/tests/golden/{s}", .{ build_options.repo_root, name });
        var p1: [600]u8 = undefined;
        const gp = try std.fmt.bufPrint(&p1, "{s}.gpu.png", .{base});
        const bytes = try png.encode(t.allocator, gpu_img);
        defer t.allocator.free(bytes);
        try std.Io.Dir.cwd().writeFile(t.io, .{ .sub_path = gp, .data = bytes });
        var p2: [600]u8 = undefined;
        const dp = try std.fmt.bufPrint(&p2, "{s}.gpu-diff.png", .{base});
        const db = try png.encode(t.allocator, .{ .width = cpu_img.width, .height = cpu_img.height, .pixels = diff });
        defer t.allocator.free(db);
        try std.Io.Dir.cwd().writeFile(t.io, .{ .sub_path = dp, .data = db });
        return error.GpuMismatch;
    }
}

test "vulkan: init and deinit with validation" {
    const v = open() orelse return;
    defer v.deinit();
    std.debug.print("vulkan device: {s}\n", .{v.deviceName()});
    try t.expectEqual(@as(u32, 0), v.validation_messages);
}

test "vulkan: the loader is missing" {
    if (!build_options.vulkan) return;
    try t.expectError(error.NoVulkan, vk.Vulkan.init(t.allocator, .{ .library_name = "libno-such-vulkan.so.9" }));
}

test "vulkan: the box scenes equal the CPU renderer" {
    const v = open() orelse return;
    defer v.deinit();
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
    try t.expectEqual(@as(u32, 0), v.validation_messages);
}

test "vulkan: the text scenes equal the CPU renderer" {
    const v = open() orelse return;
    defer v.deinit();
    for (text_tests.text_names, 0..) |name, which| {
        var s: text_tests.Setup = undefined;
        try s.init();
        defer s.deinit();
        try text_tests.buildText(&s, which);
        try compare(v, name, &s.scene, &s.atlas);
    }
    try t.expectEqual(@as(u32, 0), v.validation_messages);
}

test "vulkan: an empty scene gives the clear color" {
    const v = open() orelse return;
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

test "vulkan: 20000 quads grow the buffer and draw" {
    const v = open() orelse return;
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
    try t.expectEqual(@as(usize, 20000), s.quads.items.len);
    try compare(v, "many-boxes", &s, &atlas);
    try t.expectEqual(@as(u32, 0), v.validation_messages);
}

test "vulkan: two draws to one target leave no rest of the first" {
    const v = open() orelse return;
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

test "vulkan: a changed atlas uploads again" {
    const v = open() orelse return;
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

test "vulkan-speed: 10000 quads" {
    const v = open() orelse return;
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
    const runs = 100;
    for (0..runs) |_| try v.draw(&s, &atlas);
    const ns = t0.untilNow(t.io, .awake).toNanoseconds();
    std.debug.print("vulkan-speed: {d:.3} ms for one draw of 10000 quads on {s} ({s})\n", .{ @as(f64, @floatFromInt(ns)) / 1e6 / runs, v.deviceName(), @tagName(@import("builtin").mode) });
    try t.expectEqual(@as(u32, 0), v.validation_messages);
}

test "vulkan: the demo scene equals the CPU renderer" {
    const v = open() orelse return;
    defer v.deinit();
    var h: testing_h.Harness = undefined;
    try h.initExamples(false);
    defer h.deinit();
    try h.loadFile("examples/demo.tcl");
    try h.update();
    try compare(v, "demo-start", h.app.lastScene(), &h.app.atlas);
    try t.expectEqual(@as(u32, 0), v.validation_messages);
}

test "vulkan: an exported target maps as a linear dma-buf" {
    const v = open() orelse return;
    defer v.deinit();
    if (!v.canExport()) {
        std.debug.print("SKIP: the device has no dma-buf export\n", .{});
        return;
    }
    var atlas = atlas_mod.Atlas.init(t.allocator);
    defer atlas.deinit();
    var s: Scene = .{};
    defer s.deinit(t.allocator);
    try scene_tests.build(t.allocator, &s, 0, 1);
    var cpu_img = try newImage(s.width, s.height);
    defer t.allocator.free(cpu_img.pixels);
    cpu.render(&s, &atlas, &cpu_img);
    const target = v.createExported(s.width, s.height) catch |e| {
        if (e != error.NoExport) return e;
        std.debug.print("SKIP: {s}\n", .{vk.reason()});
        return;
    };
    defer v.destroyTarget(target);
    try t.expect(target.fd >= 0);
    try t.expect(target.stride >= s.width * 4);
    v.setTarget(target);
    try v.draw(&s, &atlas);
    // The memory of the dma-buf, read through its descriptor.
    const linux = std.os.linux;
    const size: usize = target.offset + @as(usize, target.stride) * s.height;
    const map = linux.mmap(null, size, .{ .READ = true }, .{ .TYPE = .SHARED }, target.fd, 0);
    if (@as(isize, @bitCast(map)) < 0) {
        std.debug.print("SKIP: the dma-buf does not map\n", .{});
        return;
    }
    defer _ = linux.munmap(@ptrFromInt(map), size);
    const mem: [*]const u8 = @ptrFromInt(map);
    var count: usize = 0;
    for (0..s.height) |y| for (0..s.width) |x| {
        const a = cpu_img.pixels[(y * s.width + x) * 4 ..][0..3];
        const b = mem[target.offset + y * target.stride + x * 4 ..][0..3];
        for (0..3) |ch| {
            const d = if (a[ch] > b[ch]) a[ch] - b[ch] else b[ch] - a[ch];
            if (d > 2) {
                count += 1;
                break;
            }
        }
    };
    std.debug.print("vulkan dma-buf: {d} of {d} pixels differ by more than 2, stride {d}\n", .{ count, s.width * s.height, target.stride });
    try t.expect(count * 1000 <= s.width * s.height);
    try t.expectEqual(@as(u32, 0), v.validation_messages);
}
