//! Tests of photo images on the screen: a photo goes in the image page of
//! the atlas, the scene has one image quad for it, and the CPU renderer
//! draws its pixels, at the size of the photo and stretched.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const testing_h = @import("../testing.zig");
const Harness = testing_h.Harness;
const scene_mod = @import("../scene.zig");
const cpu = @import("../render/cpu.zig");
const Atlas = @import("../text/atlas.zig").Atlas;
const Image = @import("../render/renderer.zig").Image;
const t = std.testing;

fn pixel(img: Image, x: usize, y: usize) [4]u8 {
    return img.pixels[(y * img.width + x) * 4 ..][0..4].*;
}

test "label-photo" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("wm geometry . 60x40");
    // A photo of 4 by 2 pixels: red, green, blue, and white, then black,
    // and a clear pixel.
    _ = try h.eval(
        \\image create photo dot -width 4 -height 2
        \\dot put {{#ff0000 #00ff00 #0000ff #ffffff} {#000000 #000000 #000000 #000000}}
        \\ttk::label .l -image dot -padding 0
        \\place .l -x 10 -y 10
    );
    try h.update();
    const scene = h.app.lastScene();
    var images: usize = 0;
    for (scene.quads.items) |q| {
        if (q.kind == @backingInt(scene_mod.Kind.image)) images += 1;
    }
    try t.expectEqual(@as(usize, 1), images);
    const img = h.head.image(h.win).?;
    try t.expectEqual([4]u8{ 255, 0, 0, 255 }, pixel(img, 10, 10));
    try t.expectEqual([4]u8{ 0, 255, 0, 255 }, pixel(img, 11, 10));
    try t.expectEqual([4]u8{ 0, 0, 255, 255 }, pixel(img, 12, 10));
    try t.expectEqual([4]u8{ 255, 255, 255, 255 }, pixel(img, 13, 10));
    try t.expectEqual([4]u8{ 0, 0, 0, 255 }, pixel(img, 10, 11));
    try testing_h.expectGolden("label-photo", img, .{});
    try testing_h.expectScene("label-photo", scene);
}

test "photo: an image quad stretched to twice its size" {
    var atlas = Atlas.init(t.allocator);
    defer atlas.deinit();
    // A 2 by 1 image: red and clear blue.
    const px = [_]u8{ 255, 0, 0, 255, 0, 0, 255, 0 };
    const uv = (try atlas.image(1, 2, 1, &px)).?;
    var scene: scene_mod.Scene = .{};
    defer scene.deinit(t.allocator);
    scene.reset(8, 4);
    scene.clear = .{ 1, 1, 1, 1 };
    var b = scene_mod.Builder.init(t.allocator, &scene, 2);
    try b.image(.{ .x = 0, .y = 0, .w = 2, .h = 1 }, uv, 1);
    var out: Image = .{ .width = 8, .height = 4, .pixels = try t.allocator.alloc(u8, 8 * 4 * 4) };
    defer t.allocator.free(out.pixels);
    cpu.render(&scene, &atlas, &out);
    // The left pixel is red, the pixel past the middle is a mix, and the
    // right pixel shows the white clear color through the clear texel.
    try t.expectEqual([4]u8{ 255, 0, 0, 255 }, pixel(out, 0, 0));
    const mid = pixel(out, 2, 0);
    try t.expect(mid[0] > 128 and mid[0] < 255 and mid[1] > 0);
    try t.expectEqual([4]u8{ 255, 255, 255, 255 }, pixel(out, 3, 0));
    // Below the image the clear color stays.
    try t.expectEqual([4]u8{ 255, 255, 255, 255 }, pixel(out, 0, 2));
}
