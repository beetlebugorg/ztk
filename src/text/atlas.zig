//! The glyph atlas: one page of 1024 by 1024 coverage bytes. A shelf
//! packer puts the glyph images in rows with one texel of space between
//! images. The key of an image is the font, the glyph, and the
//! quarter-pixel x offset. A full page gives `error.AtlasFull`. The
//! `generation` counts up at each change of the page, so a GPU renderer
//! knows when to upload it again.
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
    /// Counts the takes that gave patches, so `takePatchesFor` knows when
    /// another surface took the patches of a change.
    takes: u32 = 0,

    pub fn init(gpa: std.mem.Allocator) Atlas {
        return .{ .gpa = gpa };
    }

    pub fn deinit(a: *Atlas) void {
        a.map.deinit(a.gpa);
        a.pending.deinit(a.gpa);
        a.gpa.free(a.pixels);
    }

    /// The image of a glyph. `sub` is the quarter-pixel x offset, 0..3.
    pub fn get(a: *Atlas, font: *Font, glyph: u16, sub: u2) !AtlasGlyph {
        const key: Key = .{ .font = font, .glyph = glyph, .sub = sub };
        if (a.map.get(key)) |g| return g;
        const o = try font.face.outline(a.gpa, glyph);
        defer o.deinit(a.gpa);
        const bm = try raster.rasterize(a.gpa, o, font.unitScale(), @as(f32, @floatFromInt(sub)) * 0.25);
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
        if (a.pending.items.len > 0) a.takes +%= 1;
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
            a.takes +%= 1;
        } else {
            try a.takePatches(gpa, out);
        }
        seen.* = a.takes;
    }

    /// Copies the bytes of a patch into the page. The render thread uses it on its own copy.
    pub fn applyPatch(a: *Atlas, p: AtlasPatch) !void {
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
