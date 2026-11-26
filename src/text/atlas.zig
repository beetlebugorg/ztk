//! The glyph atlas: one page of 1024 by 1024 coverage bytes. A shelf
//! packer puts the glyph images in rows with one texel of space between
//! images. The key of an image is the font, the glyph, and the
//! quarter-pixel x offset. A full page gives `error.AtlasFull`. The
//! `generation` counts up at each change of the page, so a GPU renderer
//! knows when to upload it again.
//!
//! A second page, `images`, holds RGBA images (photos, and the control
//! parts that a platform draws) with straight alpha. An image has a
//! border of one texel that repeats its edge, so a filtered sample at
//! the edge stays inside the image. A full image page starts again
//! empty: each image goes in again at its next use.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const font_mod = @import("font.zig");
const raster = @import("raster.zig");
const AtlasPatch = @import("../scene.zig").AtlasPatch;
const Font = font_mod.Font;

pub const AtlasGlyph = struct {
    /// x, y, w, h in texels.
    uv: [4]f32,
    /// The place of the image from the glyph origin, in device pixels.
    left: f32,
    top: f32,
    w: f32,
    h: f32,
};

const Key = struct { font: *const Font, glyph: u16, sub: u2 };

pub const Atlas = struct {
    pub const page_size = 1024;

    gpa: std.mem.Allocator,
    pixels: []u8 = &.{},
    map: std.AutoHashMapUnmanaged(Key, AtlasGlyph) = .empty,
    shelf_y: u32 = 1,
    shelf_h: u32 = 0,
    cursor_x: u32 = 1,
    /// Counts up at each change of the page.
    generation: u32 = 0,
    /// The regions of the page that changed since `takePatches`: x, y, w, h.
    pending: std.ArrayListUnmanaged([4]u32) = .empty,
    /// Counts the takes that gave patches. `takePatchesFor` compares it
    /// with the count of a surface to find the takes of other surfaces.
    takes: u32 = 0,
    images: ImagePage = .{},

    pub fn init(gpa: std.mem.Allocator) Atlas {
        return .{ .gpa = gpa };
    }

    pub fn deinit(a: *Atlas) void {
        a.map.deinit(a.gpa);
        a.pending.deinit(a.gpa);
        a.gpa.free(a.pixels);
        a.images.deinit(a.gpa);
    }

    /// The place of an RGBA image in the image page, in texels: x, y, w,
    /// h. `key` names the image and its version: the same key gives the
    /// same place without a copy. Null for an image larger than the page.
    pub fn image(a: *Atlas, key: u64, width: u32, height: u32, rgba: []const u8) !?[4]f32 {
        return a.images.put(a.gpa, key, width, height, rgba);
    }

    /// 1024 by 1024 texels of RGBA, 4 bytes each, or empty with no image.
    pub fn imagePage(a: *const Atlas) []const u8 {
        return a.images.pixels;
    }

    /// The image of a glyph. `sub` is the quarter-pixel x offset, 0..3.
    pub fn get(a: *Atlas, font: *Font, glyph: u16, sub: u2) !AtlasGlyph {
        const key: Key = .{ .font = font, .glyph = glyph, .sub = sub };
        if (a.map.get(key)) |g| return g;
        const sub_x = @as(f32, @floatFromInt(sub)) * 0.25;
        // A font of the system gets its images from the system.
        const bm = if (font.system) |s| try s.raster(a.gpa, font.sys_face, glyph, font.size * font.scale, sub_x) else blk: {
            const o = try font.face.outline(a.gpa, glyph);
            defer o.deinit(a.gpa);
            break :blk try raster.rasterize(a.gpa, o, font.unitScale(), sub_x);
        };
        defer bm.deinit(a.gpa);
        var entry: AtlasGlyph = .{ .uv = .{ 0, 0, 0, 0 }, .left = @floatFromInt(bm.left), .top = @floatFromInt(bm.top), .w = 0, .h = 0 };
        if (bm.width > 0 and bm.height > 0) {
            if (a.pixels.len == 0) {
                a.pixels = try a.gpa.alloc(u8, page_size * page_size);
                @memset(a.pixels, 0);
            }
            if (a.cursor_x + bm.width + 1 > page_size) {
                a.shelf_y += a.shelf_h + 1;
                a.shelf_h = 0;
                a.cursor_x = 1;
            }
            if (bm.width + 2 > page_size or a.shelf_y + bm.height + 1 > page_size) return error.AtlasFull;
            var y: u32 = 0;
            while (y < bm.height) : (y += 1) {
                const dst = (a.shelf_y + y) * page_size + a.cursor_x;
                @memcpy(a.pixels[dst..][0..bm.width], bm.pixels[y * bm.width ..][0..bm.width]);
            }
            entry.uv = .{ @floatFromInt(a.cursor_x), @floatFromInt(a.shelf_y), @floatFromInt(bm.width), @floatFromInt(bm.height) };
            entry.w = @floatFromInt(bm.width);
            entry.h = @floatFromInt(bm.height);
            try a.pending.append(a.gpa, .{ a.cursor_x, a.shelf_y, bm.width, bm.height });
            a.cursor_x += bm.width + 1;
            a.shelf_h = @max(a.shelf_h, bm.height);
            a.generation += 1;
        }
        try a.map.put(a.gpa, key, entry);
        return entry;
    }

    /// Moves the changed regions into `out`, each with a copy of its bytes.
    /// The bytes belong to `gpa`, and the receiver frees them.
    pub fn takePatches(a: *Atlas, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(AtlasPatch)) !void {
        for (a.pending.items) |r| {
            const bytes = try gpa.alloc(u8, @as(usize, r[2]) * r[3]);
            errdefer gpa.free(bytes);
            var y: u32 = 0;
            while (y < r[3]) : (y += 1) {
                const src = (r[1] + y) * page_size + r[0];
                @memcpy(bytes[y * r[2] ..][0..r[2]], a.pixels[src..][0..r[2]]);
            }
            try out.append(gpa, .{ .x = r[0], .y = r[1], .w = r[2], .h = r[3], .bytes = bytes });
        }
        const had = a.pending.items.len > 0 or a.images.pending.items.len > 0;
        try a.images.takePatches(gpa, out);
        if (had) a.takes +%= 1;
        a.pending.clearRetainingCapacity();
    }

    /// The `seen` of a surface that has none of the page.
    pub const seen_none: u32 = std.math.maxInt(u32);

    /// Takes the patches for one of several surfaces. `seen` is the count
    /// of takes after the last take of the surface. When another surface
    /// took patches since then, the surface gets one patch with each used
    /// row of the page.
    pub fn takePatchesFor(a: *Atlas, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(AtlasPatch), seen: *u32) !void {
        const rows = @min(a.shelf_y + a.shelf_h, page_size);
        if (seen.* != a.takes and a.pixels.len > 0 and rows > 0) {
            const bytes = try gpa.dupe(u8, a.pixels[0 .. @as(usize, rows) * page_size]);
            errdefer gpa.free(bytes);
            try out.append(gpa, .{ .x = 0, .y = 0, .w = page_size, .h = rows, .bytes = bytes });
            a.pending.clearRetainingCapacity();
            try a.images.takeAll(gpa, out);
            a.takes +%= 1;
        } else {
            try a.takePatches(gpa, out);
        }
        seen.* = a.takes;
    }

    /// Copies the bytes of a patch into the page. The render thread uses it on its own copy.
    pub fn applyPatch(a: *Atlas, p: AtlasPatch) !void {
        if (p.rgba) return a.images.apply(a.gpa, p);
        if (a.pixels.len == 0) {
            a.pixels = try a.gpa.alloc(u8, page_size * page_size);
            @memset(a.pixels, 0);
        }
        var y: u32 = 0;
        while (y < p.h) : (y += 1) {
            const dst = (p.y + y) * page_size + p.x;
            @memcpy(a.pixels[dst..][0..p.w], p.bytes[y * p.w ..][0..p.w]);
        }
        a.generation += 1;
    }

    /// 1024 by 1024, one byte of coverage for each texel.
    pub fn page(a: *const Atlas) []const u8 {
        return a.pixels;
    }
};

/// The RGBA page of the atlas, with a shelf packer as the coverage page.
pub const ImagePage = struct {
    pub const page_size = Atlas.page_size;
    pixels: []u8 = &.{},
    map: std.AutoHashMapUnmanaged(u64, [4]f32) = .empty,
    shelf_y: u32 = 0,
    shelf_h: u32 = 0,
    cursor_x: u32 = 0,
    generation: u32 = 0,
    pending: std.ArrayListUnmanaged([4]u32) = .empty,

    fn deinit(p: *ImagePage, gpa: std.mem.Allocator) void {
        p.map.deinit(gpa);
        p.pending.deinit(gpa);
        gpa.free(p.pixels);
    }

    fn ensure(p: *ImagePage, gpa: std.mem.Allocator) !void {
        if (p.pixels.len > 0) return;
        p.pixels = try gpa.alloc(u8, page_size * page_size * 4);
        @memset(p.pixels, 0);
    }

    /// Starts the page again with no image.
    fn empty(p: *ImagePage) void {
        p.map.clearRetainingCapacity();
        p.shelf_y = 0;
        p.shelf_h = 0;
        p.cursor_x = 0;
    }

    fn put(p: *ImagePage, gpa: std.mem.Allocator, key: u64, width: u32, height: u32, rgba: []const u8) !?[4]f32 {
        if (p.map.get(key)) |uv| return uv;
        // The image with its border of one texel on each side.
        const w = width + 2;
        const h = height + 2;
        if (width == 0 or height == 0 or w > page_size or h > page_size or rgba.len < @as(usize, width) * height * 4) return null;
        try p.ensure(gpa);
        if (p.cursor_x + w > page_size) {
            p.shelf_y += p.shelf_h;
            p.shelf_h = 0;
            p.cursor_x = 0;
        }
        if (p.shelf_y + h > page_size) {
            p.empty();
            return p.put(gpa, key, width, height, rgba);
        }
        const x0 = p.cursor_x;
        const y0 = p.shelf_y;
        var y: u32 = 0;
        while (y < h) : (y += 1) {
            const sy = std.math.clamp(@as(i64, y) - 1, 0, height - 1);
            var x: u32 = 0;
            while (x < w) : (x += 1) {
                const sx = std.math.clamp(@as(i64, x) - 1, 0, width - 1);
                const src: usize = @intCast((sy * width + sx) * 4);
                const dst = ((y0 + y) * page_size + x0 + x) * 4;
                @memcpy(p.pixels[dst..][0..4], rgba[src..][0..4]);
            }
        }
        try p.pending.append(gpa, .{ x0, y0, w, h });
        p.cursor_x += w;
        p.shelf_h = @max(p.shelf_h, h);
        p.generation += 1;
        const uv: [4]f32 = .{ @floatFromInt(x0 + 1), @floatFromInt(y0 + 1), @floatFromInt(width), @floatFromInt(height) };
        try p.map.put(gpa, key, uv);
        return uv;
    }

    fn copy(p: *const ImagePage, gpa: std.mem.Allocator, r: [4]u32) !AtlasPatch {
        const row = @as(usize, r[2]) * 4;
        const bytes = try gpa.alloc(u8, row * r[3]);
        var y: u32 = 0;
        while (y < r[3]) : (y += 1) {
            const src = ((r[1] + y) * page_size + r[0]) * 4;
            @memcpy(bytes[y * row ..][0..row], p.pixels[src..][0..row]);
        }
        return .{ .x = r[0], .y = r[1], .w = r[2], .h = r[3], .bytes = bytes, .rgba = true };
    }

    fn takePatches(p: *ImagePage, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(AtlasPatch)) !void {
        for (p.pending.items) |r| {
            const patch = try p.copy(gpa, r);
            out.append(gpa, patch) catch |e| {
                gpa.free(patch.bytes);
                return e;
            };
        }
        p.pending.clearRetainingCapacity();
    }

    /// One patch with each used row, for a surface that missed a take.
    fn takeAll(p: *ImagePage, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(AtlasPatch)) !void {
        p.pending.clearRetainingCapacity();
        const rows = @min(p.shelf_y + p.shelf_h, page_size);
        if (p.pixels.len == 0 or rows == 0) return;
        const patch = try p.copy(gpa, .{ 0, 0, page_size, rows });
        out.append(gpa, patch) catch |e| {
            gpa.free(patch.bytes);
            return e;
        };
    }

    fn apply(p: *ImagePage, gpa: std.mem.Allocator, patch: AtlasPatch) !void {
        try p.ensure(gpa);
        const row = @as(usize, patch.w) * 4;
        var y: u32 = 0;
        while (y < patch.h) : (y += 1) {
            const dst = ((patch.y + y) * page_size + patch.x) * 4;
            @memcpy(p.pixels[dst..][0..row], patch.bytes[y * row ..][0..row]);
        }
        p.generation += 1;
    }
};

test "atlas: an image goes in the image page with a border of its edge" {
    var a = Atlas.init(std.testing.allocator);
    defer a.deinit();
    const px = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 128 };
    const uv = (try a.image(7, 2, 1, &px)).?;
    try std.testing.expectEqual([4]f32{ 1, 1, 2, 1 }, uv);
    // The same key gives the same place.
    try std.testing.expectEqual(uv, (try a.image(7, 2, 1, &px)).?);
    const page = a.imagePage();
    const at = struct {
        fn f(pg: []const u8, x: usize, y: usize) []const u8 {
            return pg[(y * Atlas.page_size + x) * 4 ..][0..4];
        }
    }.f;
    try std.testing.expectEqualSlices(u8, px[0..4], at(page, 1, 1));
    try std.testing.expectEqualSlices(u8, px[4..8], at(page, 2, 1));
    // The border repeats the edge texels.
    try std.testing.expectEqualSlices(u8, px[0..4], at(page, 0, 0));
    try std.testing.expectEqualSlices(u8, px[4..8], at(page, 3, 2));
    // The patch reaches a copy of the atlas, as on the render thread.
    var patches: std.ArrayListUnmanaged(AtlasPatch) = .empty;
    defer {
        for (patches.items) |p| std.testing.allocator.free(p.bytes);
        patches.deinit(std.testing.allocator);
    }
    try a.takePatches(std.testing.allocator, &patches);
    try std.testing.expectEqual(@as(usize, 1), patches.items.len);
    try std.testing.expect(patches.items[0].rgba);
    var copy = Atlas.init(std.testing.allocator);
    defer copy.deinit();
    for (patches.items) |p| try copy.applyPatch(p);
    try std.testing.expectEqualSlices(u8, px[4..8], at(copy.imagePage(), 2, 1));
    // An image larger than the page has no place.
    try std.testing.expect((try a.image(8, Atlas.page_size, 1, &.{})) == null);
}
