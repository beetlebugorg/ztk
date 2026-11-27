//! A look at the text of DirectWrite: the type ramp of Fluent as ztk lays
//! it out with the system backend, written to .zig-cache/dwrite-look.png
//! when ZTK_DWRITE_LOOK is set.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const t = std.testing;
const font_mod = @import("../text/font.zig");
const shape = @import("../text/shape.zig");
const dwrite = @import("../platform/dwrite.zig");

test "dwrite look: the type ramp of Fluent" {
    // A look for a person, so it runs only on request.
    if (!(t.environ.contains(t.allocator, "ZTK_DWRITE_LOOK") catch false)) return error.SkipZigTest;
    const d = dwrite.DWrite.init(t.allocator) orelse return error.SkipZigTest;
    defer d.deinit();
    var fonts = try font_mod.Fonts.init(t.allocator);
    defer fonts.deinit();
    fonts.system = d.backend();
    const w: u32 = 560;
    const h: u32 = 260;
    const px = try t.allocator.alloc(u8, w * h * 4);
    defer t.allocator.free(px);
    @memset(px, 0xff);
    const lines = [_]struct { size: f32, weight: u16, text: []const u8 }{
        .{ .size = 12, .weight = 400, .text = "Caption 12: The quick brown fox jumps over the lazy dog" },
        .{ .size = 14, .weight = 400, .text = "Body 14: The quick brown fox jumps over the lazy dog" },
        .{ .size = 14, .weight = 600, .text = "Body Strong 14: AVATAR Wave, office" },
        .{ .size = 20, .weight = 600, .text = "Subtitle 20: Settings" },
        .{ .size = 28, .weight = 600, .text = "Title 28: Bluetooth & devices" },
    };
    var y: i32 = 8;
    for (lines) |l| {
        const font = try fonts.get(.{ .family = "system-ui", .size = l.size, .weight = l.weight }, 1);
        const m = font_mod.Fonts.metrics(font);
        y += m.ascent;
        var run = try shape.shape(t.allocator, font, l.text);
        defer run.deinit(t.allocator);
        for (run.glyphs) |g| {
            const fx = 10 + g.x;
            const ix = @floor(fx);
            const sub: f32 = @floor((fx - ix) * 4) / 4;
            const bm = try fonts.system.?.raster(t.allocator, font.sys_face, g.id, font.size, sub);
            defer bm.deinit(t.allocator);
            var r: u32 = 0;
            while (r < bm.height) : (r += 1) {
                var c: u32 = 0;
                while (c < bm.width) : (c += 1) {
                    const X = @as(i32, @intFromFloat(ix)) + bm.left + @as(i32, @intCast(c));
                    const Y = y + bm.top + @as(i32, @intCast(r));
                    if (X < 0 or Y < 0 or X >= w or Y >= h) continue;
                    const a = bm.pixels[r * bm.width + c];
                    const i = (@as(usize, @intCast(Y)) * w + @as(usize, @intCast(X))) * 4;
                    const v: u8 = 255 - @min(255, @as(u16, 255 - px[i]) + a);
                    px[i] = v;
                    px[i + 1] = v;
                    px[i + 2] = v;
                }
            }
        }
        y += -m.descent + 12;
    }
    const png = try @import("../base/png.zig").encode(t.allocator, .{ .width = w, .height = h, .pixels = px });
    defer t.allocator.free(png);
    try std.Io.Dir.cwd().writeFile(t.io, .{ .sub_path = ".zig-cache/dwrite-look.png", .data = png });
}
