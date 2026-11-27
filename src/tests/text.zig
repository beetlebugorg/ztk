//! Tests of the font parser, the rasterizer, the shaper, and the atlas,
//! and the golden images of text. The expected font numbers are the
//! output of tools/font-oracle.py (fontTools 4.67.0) for Inter 4.1.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const geom = @import("../base/geom.zig");
const scene_mod = @import("../scene.zig");
const cpu = @import("../render/cpu.zig");
const testing_h = @import("../testing.zig");
const ttf = @import("../text/ttf.zig");
const raster = @import("../text/raster.zig");
const font_mod = @import("../text/font.zig");
const shape_mod = @import("../text/shape.zig");
const atlas_mod = @import("../text/atlas.zig");
const t = std.testing;
const build_options = @import("build_options");

const regular = @embedFile("inter_regular");
const bold = @embedFile("inter_bold");

fn col(rgb: u24, a: u8) geom.Color {
    return .{ .r = @truncate(rgb >> 16), .g = @truncate(rgb >> 8), .b = @truncate(rgb), .a = a };
}

// ---- ttf ----

test "ttf: head and hhea numbers of both fonts" {
    for ([_][]const u8{ regular, bold }) |data| {
        const f = try ttf.Face.init(data);
        try t.expectEqual(@as(u16, 2048), f.units_per_em);
        try t.expectEqual(@as(i16, 1984), f.ascent);
        try t.expectEqual(@as(i16, -494), f.descent);
        try t.expectEqual(@as(i16, 0), f.line_gap);
        try t.expectEqual(@as(u16, 2937), f.glyph_count);
        try t.expectEqualStrings("Inter", f.family());
    }
}

test "ttf: glyph ids and advances of AVa.1 é€" {
    const f = try ttf.Face.init(regular);
    const want = [_][3]u32{
        .{ 65, 2, 1413 },  .{ 86, 456, 1413 }, .{ 97, 507, 1150 }, .{ 46, 1502, 590 },
        .{ 49, 1342, 833 }, .{ 32, 1777, 576 }, .{ 233, 618, 1194 }, .{ 8364, 1316, 1365 },
    };
    for (want) |w| {
        const g = f.glyphIndex(@intCast(w[0]));
        try t.expectEqual(@as(u16, @intCast(w[1])), g);
        try t.expectEqual(@as(u16, @intCast(w[2])), f.advance(g));
    }
}

test "ttf: contours and points of A B i é" {
    const f = try ttf.Face.init(regular);
    const want = [_][3]u32{ .{ 65, 2, 17 }, .{ 66, 3, 39 }, .{ 105, 2, 16 }, .{ 233, 3, 37 } };
    for (want) |w| {
        const o = try f.outline(t.allocator, f.glyphIndex(@intCast(w[0])));
        defer o.deinit(t.allocator);
        try t.expectEqual(@as(usize, w[1]), o.contour_ends.len);
        try t.expectEqual(@as(usize, w[2]), o.points.len);
    }
}

test "ttf: kerning of AV To LT aa" {
    const f = try ttf.Face.init(regular);
    const pairs = [_]struct { []const u8, i16 }{ .{ "AV", -140 }, .{ "To", -160 }, .{ "LT", -197 }, .{ "aa", 0 } };
    for (pairs) |p| {
        const l = f.glyphIndex(p[0][0]);
        const r = f.glyphIndex(p[0][1]);
        try t.expectEqual(p[1], f.kerning(l, r));
    }
}

test "ttf: a code point with no glyph gives 0" {
    const f = try ttf.Face.init(regular);
    try t.expectEqual(@as(u16, 0), f.glyphIndex(0x10ffff));
    try t.expectEqual(@as(u16, 0), f.glyphIndex(0x378));
}

test "ttf: a font cut at 200 lengths gives BadFont" {
    // The tables up to hmtx end at 361028. A cut before that loses a needed table.
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const len = i * 1700;
        try t.expectError(error.BadFont, ttf.Face.init(regular[0..len]));
    }
}

test "ttf: a font with one changed byte never reads outside the data" {
    const copy = try t.allocator.dupe(u8, regular);
    defer t.allocator.free(copy);
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rnd = prng.random();
    var n: usize = 0;
    while (n < 1000) : (n += 1) {
        // Half of the changes go to the table directory and the small tables.
        const pos = if (n % 2 == 0) rnd.uintLessThan(usize, 600) else rnd.uintLessThan(usize, copy.len);
        const old = copy[pos];
        copy[pos] = rnd.int(u8);
        defer copy[pos] = old;
        const f = ttf.Face.init(copy) catch continue;
        var cp: u21 = 32;
        while (cp < 82) : (cp += 1) {
            const g = f.glyphIndex(cp);
            _ = f.kerning(g, f.glyphIndex(cp + 1));
            _ = f.advance(g);
            if (f.outline(t.allocator, g)) |o| o.deinit(t.allocator) else |_| {}
        }
        // The glyphs near the changed byte of the glyph table.
        var g: u16 = 0;
        while (g < 50) : (g += 1) {
            if (f.outline(t.allocator, g * 40)) |o| o.deinit(t.allocator) else |_| {}
        }
    }
}

test "ttf: no outline of a glyph beyond the count" {
    const f = try ttf.Face.init(regular);
    try expectBadOutline(&f, 60000);
}

// ---- raster ----

fn squareOutline(x0: f32, y0: f32, x1: f32, y1: f32, ccw: bool, pts: *[4]ttf.Point) void {
    if (ccw) {
        pts.* = .{ .{ .x = x0, .y = y0, .on_curve = true }, .{ .x = x1, .y = y0, .on_curve = true }, .{ .x = x1, .y = y1, .on_curve = true }, .{ .x = x0, .y = y1, .on_curve = true } };
    } else {
        pts.* = .{ .{ .x = x0, .y = y0, .on_curve = true }, .{ .x = x0, .y = y1, .on_curve = true }, .{ .x = x1, .y = y1, .on_curve = true }, .{ .x = x1, .y = y0, .on_curve = true } };
    }
}

fn sum(b: raster.Bitmap) u64 {
    var s: u64 = 0;
    for (b.pixels) |p| s += p;
    return s;
}

test "raster: a square gives 100 full pixels" {
    var pts: [4]ttf.Point = undefined;
    squareOutline(0, 0, 10, 10, true, &pts);
    const ends = [_]u16{3};
    const bm = try raster.rasterize(t.allocator, .{ .points = &pts, .contour_ends = &ends }, 1, 0);
    defer bm.deinit(t.allocator);
    try t.expectEqual(@as(u32, 10), bm.width);
    try t.expectEqual(@as(u32, 10), bm.height);
    try t.expectEqual(@as(i32, -10), bm.top);
    for (bm.pixels) |p| try t.expectEqual(@as(u8, 255), p);
}

test "raster: a square moved by half a pixel has half columns" {
    var pts: [4]ttf.Point = undefined;
    squareOutline(0, 0, 10, 10, true, &pts);
    const ends = [_]u16{3};
    const bm = try raster.rasterize(t.allocator, .{ .points = &pts, .contour_ends = &ends }, 1, 0.5);
    defer bm.deinit(t.allocator);
    try t.expectEqual(@as(u32, 11), bm.width);
    for (0..bm.height) |y| {
        try t.expectEqual(@as(u8, 128), bm.pixels[y * bm.width]);
        try t.expectEqual(@as(u8, 255), bm.pixels[y * bm.width + 5]);
        try t.expectEqual(@as(u8, 128), bm.pixels[y * bm.width + 10]);
    }
}

test "raster: a triangle has the area of its outline" {
    const pts = [_]ttf.Point{ .{ .x = 0, .y = 0, .on_curve = true }, .{ .x = 10, .y = 0, .on_curve = true }, .{ .x = 0, .y = 10, .on_curve = true } };
    const ends = [_]u16{2};
    const bm = try raster.rasterize(t.allocator, .{ .points = &pts, .contour_ends = &ends }, 1, 0);
    defer bm.deinit(t.allocator);
    const want: f64 = 50 * 255;
    const got: f64 = @floatFromInt(sum(bm));
    try t.expect(@abs(got - want) / want < 0.01);
}

test "raster: an inner contour with the other direction is a hole" {
    var outer: [4]ttf.Point = undefined;
    var inner: [4]ttf.Point = undefined;
    squareOutline(0, 0, 10, 10, true, &outer);
    squareOutline(3, 3, 7, 7, false, &inner);
    const pts = outer ++ inner;
    const ends = [_]u16{ 3, 7 };
    const bm = try raster.rasterize(t.allocator, .{ .points = &pts, .contour_ends = &ends }, 1, 0);
    defer bm.deinit(t.allocator);
    try t.expectEqual(@as(u8, 0), bm.pixels[5 * bm.width + 5]);
    try t.expectEqual(@as(u8, 255), bm.pixels[1 * bm.width + 1]);
    try t.expectEqual(@as(u64, 84 * 255), sum(bm));
}

/// The signed area of an outline in font units: the chord polygon plus
/// 2/3 of the triangle of each quadratic curve. Used as an independent
/// check of the rasterizer.
fn outlineArea(o: ttf.Outline) f64 {
    var total: f64 = 0;
    var start: usize = 0;
    for (o.contour_ends) |e| {
        const pts = o.points[start .. @as(usize, e) + 1];
        start = @as(usize, e) + 1;
        const n = pts.len;
        // Expand implied on-curve points.
        var buf: [512]ttf.Point = undefined;
        var m: usize = 0;
        for (pts, 0..) |p, i| {
            const next = pts[(i + 1) % n];
            buf[m] = p;
            m += 1;
            if (!p.on_curve and !next.on_curve) {
                buf[m] = .{ .x = (p.x + next.x) / 2, .y = (p.y + next.y) / 2, .on_curve = true };
                m += 1;
            }
        }
        // Rotate so that the first point is on the curve.
        var s: usize = 0;
        while (s < m and !buf[s].on_curve) s += 1;
        var i: usize = 0;
        while (i < m) {
            const a = buf[(s + i) % m];
            const b = buf[(s + i + 1) % m];
            if (b.on_curve) {
                total += (@as(f64, a.x) * b.y - @as(f64, b.x) * a.y) / 2;
                i += 1;
            } else {
                const c = buf[(s + i + 2) % m];
                total += (@as(f64, a.x) * c.y - @as(f64, c.x) * a.y) / 2;
                const tri = ((@as(f64, b.x) - a.x) * (@as(f64, c.y) - a.y) - (@as(f64, c.x) - a.x) * (@as(f64, b.y) - a.y)) / 2;
                total += tri * 2.0 / 3.0;
                i += 2;
            }
        }
    }
    return @abs(total);
}

test "raster: the coverage of o at 64 pixels equals the area of its outline" {
    const f = try ttf.Face.init(regular);
    const o = try f.outline(t.allocator, f.glyphIndex('o'));
    defer o.deinit(t.allocator);
    const scale: f32 = 64.0 / 2048.0;
    const bm = try raster.rasterize(t.allocator, o, scale, 0);
    defer bm.deinit(t.allocator);
    const want = outlineArea(o) * scale * scale * 255;
    const got: f64 = @floatFromInt(sum(bm));
    try t.expect(@abs(got - want) / want < 0.005);
}

test "raster: sub-pixel offsets change the image and keep the sum" {
    const f = try ttf.Face.init(regular);
    const o = try f.outline(t.allocator, f.glyphIndex('a'));
    defer o.deinit(t.allocator);
    const scale: f32 = 13.0 / 2048.0;
    const a = try raster.rasterize(t.allocator, o, scale, 0);
    defer a.deinit(t.allocator);
    const b = try raster.rasterize(t.allocator, o, scale, 0.25);
    defer b.deinit(t.allocator);
    const sa: f64 = @floatFromInt(sum(a));
    const sb: f64 = @floatFromInt(sum(b));
    try t.expect(@abs(sa - sb) / sa < 0.01);
    try t.expect(!std.mem.eql(u8, a.pixels, b.pixels) or a.width != b.width);
}

test "raster: an empty outline gives an empty bitmap" {
    const bm = try raster.rasterize(t.allocator, .{ .points = &.{}, .contour_ends = &.{} }, 1, 0);
    try t.expectEqual(@as(u32, 0), bm.width);
}

// ---- shape and atlas ----

test "shape: metrics of the Regular font at 13 pixels" {
    var fonts = try font_mod.Fonts.init(t.allocator);
    defer fonts.deinit();
    const font = try fonts.get(.{ .size = 13 }, 1);
    const m = font_mod.Fonts.metrics(font);
    try t.expectEqual(@as(i32, 13), m.ascent);
    try t.expectEqual(@as(i32, 4), m.descent);
    try t.expect(m.line_height >= 14 and m.line_height <= 20);
}

test "shape: measure and kerning" {
    var fonts = try font_mod.Fonts.init(t.allocator);
    defer fonts.deinit();
    const big = try fonts.get(.{ .size = 100 }, 1);
    try t.expectEqual(@as(i32, 0), shape_mod.measure(&fonts, big, ""));
    const av = shape_mod.measure(&fonts, big, "AV");
    try t.expect(av < shape_mod.measure(&fonts, big, "A") + shape_mod.measure(&fonts, big, "V"));
    // The cache gives the same value.
    try t.expectEqual(av, shape_mod.measure(&fonts, big, "AV"));
}

test "shape: width at scale 2 is equal to scale 1 or differs by 1" {
    var fonts = try font_mod.Fonts.init(t.allocator);
    defer fonts.deinit();
    const f1 = try fonts.get(.{ .size = 13 }, 1);
    const f2 = try fonts.get(.{ .size = 13 }, 2);
    const a = shape_mod.measure(&fonts, f1, "Hello");
    const b = shape_mod.measure(&fonts, f2, "Hello");
    try t.expect(@abs(a - b) <= 1);
}

test "shape: the right edge of the last glyph is near the width at each scale" {
    var fonts = try font_mod.Fonts.init(t.allocator);
    defer fonts.deinit();
    var atlas = atlas_mod.Atlas.init(t.allocator);
    defer atlas.deinit();
    const text = "Right aligned text 0123456789";
    for ([_]f32{ 1.25, 1.5, 2 }) |scale| {
        const font = try fonts.get(.{ .size = 13 }, scale);
        var run = try shape_mod.shape(t.allocator, font, text);
        defer run.deinit(t.allocator);
        const last = run.glyphs[run.glyphs.len - 1];
        const ag = try atlas.get(font, last.id, 0);
        const edge = (last.x + ag.left + ag.w) / scale;
        const width: f32 = @floatFromInt(run.width);
        try t.expect(edge <= width + 1);
        try t.expect(width - edge <= 2);
    }
}

test "shape: caret positions" {
    var fonts = try font_mod.Fonts.init(t.allocator);
    defer fonts.deinit();
    const font = try fonts.get(.{ .size = 13 }, 1);
    const text = "Hello, w\u{f6}rld";
    var run = try shape_mod.shape(t.allocator, font, text);
    defer run.deinit(t.allocator);
    try t.expectEqual(@as(i32, 0), run.caretX(text, 0));
    const end = run.caretX(text, text.len);
    try t.expect(end == run.width or end == run.width - 1);
    var prev: i32 = -1;
    var i: usize = 0;
    while (i < text.len) {
        const len = try std.unicode.utf8ByteSequenceLength(text[i]);
        const x = run.caretX(text, i);
        try t.expect(x >= prev);
        prev = x;
        try t.expectEqual(i, run.indexAt(text, x));
        i += len;
    }
    try t.expectEqual(text.len, run.indexAt(text, end));
}

test "shape: a two byte character is one glyph with cluster 0" {
    var fonts = try font_mod.Fonts.init(t.allocator);
    defer fonts.deinit();
    const font = try fonts.get(.{ .size = 13 }, 1);
    var run = try shape_mod.shape(t.allocator, font, "\u{e9}");
    defer run.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), run.glyphs.len);
    try t.expectEqual(@as(u32, 0), run.glyphs[0].cluster);
    // An invalid byte gives glyph 0.
    var bad = try shape_mod.shape(t.allocator, font, "a\xffb");
    defer bad.deinit(t.allocator);
    try t.expectEqual(@as(usize, 3), bad.glyphs.len);
    try t.expectEqual(@as(u16, 0), bad.glyphs[1].id);
}

test "shape: 1000 lines leak nothing" {
    var fonts = try font_mod.Fonts.init(t.allocator);
    defer fonts.deinit();
    const font = try fonts.get(.{ .size = 13 }, 1);
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        var run = try shape_mod.shape(t.allocator, font, "The quick brown fox");
        run.deinit(t.allocator);
    }
}

test "atlas: the same key gives the same image and no new generation" {
    var fonts = try font_mod.Fonts.init(t.allocator);
    defer fonts.deinit();
    const font = try fonts.get(.{ .size = 13 }, 1);
    var atlas = atlas_mod.Atlas.init(t.allocator);
    defer atlas.deinit();
    const g = font.face.glyphIndex('a');
    const a = try atlas.get(font, g, 0);
    const gen = atlas.generation;
    const b = try atlas.get(font, g, 0);
    try t.expectEqual(a, b);
    try t.expectEqual(gen, atlas.generation);
    const c = try atlas.get(font, g, 1);
    try t.expect(c.uv[0] != a.uv[0] or c.uv[1] != a.uv[1]);
    try t.expect(atlas.generation > gen);
}

test "shape: parseTk" {
    const base: font_mod.FontDesc = .{};
    const s = 96.0 / 72.0;
    const a = font_mod.Fonts.parseTk("Helvetica 12 bold", base, s).?;
    try t.expectApproxEqAbs(@as(f32, 16), a.size, 0.001);
    try t.expectEqual(@as(u16, 700), a.weight);
    try t.expectEqualStrings("Helvetica", a.family);
    const b = font_mod.Fonts.parseTk("Courier -14", base, s).?;
    try t.expectApproxEqAbs(@as(f32, 14), b.size, 0.001);
    const c = font_mod.Fonts.parseTk("{Liberation Sans} 10", base, s).?;
    try t.expectEqualStrings("Liberation Sans", c.family);
    const d = font_mod.Fonts.parseTk("TkFixedFont", base, s).?;
    try t.expectEqualStrings("monospace", d.family);
    try t.expect(font_mod.Fonts.parseTk("", base, s) == null);
    try t.expect(font_mod.Fonts.parseTk("Arial 12 sparkly", base, s) == null);
}

// ---- golden images ----

pub const Setup = struct {
    fonts: font_mod.Fonts,
    atlas: atlas_mod.Atlas,
    scene: scene_mod.Scene = .{},

    pub fn init(self: *Setup) !void {
        self.* = .{ .fonts = try font_mod.Fonts.init(t.allocator), .atlas = atlas_mod.Atlas.init(t.allocator) };
    }

    pub fn deinit(self: *Setup) void {
        self.scene.deinit(t.allocator);
        self.atlas.deinit();
        self.fonts.deinit();
    }

    pub fn line(self: *Setup, b: *scene_mod.Builder, desc: font_mod.FontDesc, scale: f32, text: []const u8, x: i32, y: i32, color: geom.Color) !void {
        const font = try self.fonts.get(desc, scale);
        var run = try shape_mod.shape(t.allocator, font, text);
        defer run.deinit(t.allocator);
        try b.text(&self.atlas, &run, x, y, color);
    }

    pub fn check(self: *Setup, name: []const u8) !void {
        var img: @import("../render/renderer.zig").Image = .{
            .width = self.scene.width,
            .height = self.scene.height,
            .pixels = try t.allocator.alloc(u8, @as(usize, self.scene.width) * self.scene.height * 4),
        };
        defer t.allocator.free(img.pixels);
        cpu.render(&self.scene, &self.atlas, &img);
        try testing_h.expectGolden(name, img, .{});
        try testing_h.expectScene(name, &self.scene);
    }
};

pub const text_names = [_][]const u8{ "text-sizes", "text-bold", "text-color", "text-scale2", "text-clip", "text-large" };

/// Builds one of the golden text scenes into `s`. The Vulkan tests use it too.
pub fn buildText(s: *Setup, which: usize) !void {
    switch (which) {
        0 => {
            s.scene.reset(260, 120);
            var b = scene_mod.Builder.init(t.allocator, &s.scene, 1);
            var y: i32 = 18;
            for ([_]f32{ 11, 13, 16, 24 }) |size| {
                try s.line(&b, .{ .size = size }, 1, "The quick brown fox", 6, y, col(0, 255));
                y += @as(i32, @intFromFloat(size)) + 6;
            }
        },
        1 => {
            s.scene.reset(200, 120);
            var b = scene_mod.Builder.init(t.allocator, &s.scene, 1);
            try s.line(&b, .{ .size = 16 }, 1, "Regular text AVA To", 8, 30, col(0, 255));
            try s.line(&b, .{ .size = 16, .weight = 700 }, 1, "Bold text AVA To", 8, 62, col(0, 255));
        },
        2 => {
            s.scene.reset(200, 120);
            var b = scene_mod.Builder.init(t.allocator, &s.scene, 1);
            try b.box(.{ .x = 8, .y = 8, .w = 184, .h = 40 }, .{ .fill = col(0x2255aa, 255), .radii = .{ 6, 6, 6, 6 } });
            try s.line(&b, .{ .size = 16, .weight = 700 }, 1, "White on blue", 20, 34, col(0xffffff, 255));
            try s.line(&b, .{ .size = 16 }, 1, "Half alpha text", 20, 80, col(0, 128));
            try s.line(&b, .{ .size = 16 }, 1, "Red text", 20, 104, col(0xcc0000, 255));
        },
        3 => {
            s.scene.reset(400, 240);
            var b = scene_mod.Builder.init(t.allocator, &s.scene, 2);
            try s.line(&b, .{ .size = 13 }, 2, "The quick brown fox", 6, 30, col(0, 255));
            try s.line(&b, .{ .size = 24 }, 2, "Scale 2", 6, 70, col(0, 255));
        },
        4 => {
            s.scene.reset(200, 120);
            var b = scene_mod.Builder.init(t.allocator, &s.scene, 1);
            b.pushClip(.{ .x = 30, .y = 20, .w = 71, .h = 40 });
            try s.line(&b, .{ .size = 24 }, 1, "Clipped text", 10, 50, col(0, 255));
            b.popClip();
        },
        else => {
            s.scene.reset(400, 130);
            var b = scene_mod.Builder.init(t.allocator, &s.scene, 1);
            try s.line(&b, .{ .size = 96 }, 1, "aegR&@", 4, 96, col(0, 255));
        },
    }
}

fn goldenText(which: usize) !void {
    var s: Setup = undefined;
    try s.init();
    defer s.deinit();
    try buildText(&s, which);
    try s.check(text_names[which]);
}

test "text: golden text-sizes" {
    try goldenText(0);
}

test "text: golden text-bold" {
    try goldenText(1);
}

test "text: golden text-color" {
    try goldenText(2);
}

test "text: golden text-scale2" {
    try goldenText(3);
}

test "text: golden text-clip" {
    try goldenText(4);
}

test "text: golden text-large" {
    try goldenText(5);
}

test "text-speed: a glyph image and a shaped line" {
    var fonts = try font_mod.Fonts.init(t.allocator);
    defer fonts.deinit();
    const font = try fonts.get(.{ .size = 13 }, 1);
    const f = font.face;
    const o = try f.outline(t.allocator, f.glyphIndex('a'));
    defer o.deinit(t.allocator);
    const runs: usize = 2000;
    const t0 = std.Io.Clock.awake.now(t.io);
    for (0..runs) |_| {
        const bm = try raster.rasterize(t.allocator, o, font.unitScale(), 0);
        bm.deinit(t.allocator);
    }
    const ns1 = t0.untilNow(t.io, .awake).toNanoseconds();
    const line = "The quick brown fox jumps over the lazy dog, 0123456789 AV";
    const t1 = std.Io.Clock.awake.now(t.io);
    for (0..runs) |_| {
        var run = try shape_mod.shape(std.heap.smp_allocator, font, line);
        run.deinit(std.heap.smp_allocator);
    }
    const ns2 = t1.untilNow(t.io, .awake).toNanoseconds();
    std.debug.print("text-speed: glyph image {d:.1} us, line of {d} characters {d:.1} us ({s})\n", .{
        @as(f64, @floatFromInt(ns1)) / 1000 / runs,
        line.len,
        @as(f64, @floatFromInt(ns2)) / 1000 / runs,
        @tagName(@import("builtin").mode),
    });
}

test "text: the parser equals fontTools on each line of tools/font-oracle.py" {
    var path_buf: [512]u8 = undefined;
    const script = try std.fmt.bufPrint(&path_buf, "{s}/tools/font-oracle.py", .{build_options.repo_root});
    var font_buf: [512]u8 = undefined;
    const font_path = try std.fmt.bufPrint(&font_buf, "{s}/assets/fonts/Inter-Regular.ttf", .{build_options.repo_root});
    const result = std.process.run(t.allocator, t.io, .{ .argv = &.{ "python3", "-I", script, font_path } }) catch {
        std.debug.print("SKIP: no python3\n", .{});
        return;
    };
    defer t.allocator.free(result.stdout);
    defer t.allocator.free(result.stderr);
    if (result.stdout.len == 0) {
        std.debug.print("SKIP: no fontTools\n", .{});
        return;
    }
    const data = @embedFile("inter_regular");
    const face = try ttf.Face.init(data);
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, result.stdout, "\n"), '\n');
    var checked: usize = 0;
    while (lines.next()) |line| {
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        const key = f.next() orelse continue;
        if (std.mem.eql(u8, key, "upem")) {
            try t.expectEqual(try std.fmt.parseInt(u16, f.next().?, 10), face.units_per_em);
        } else if (std.mem.eql(u8, key, "hhea")) {
            try t.expectEqual(try std.fmt.parseInt(i16, f.next().?, 10), face.ascent);
            try t.expectEqual(try std.fmt.parseInt(i16, f.next().?, 10), face.descent);
            try t.expectEqual(try std.fmt.parseInt(i16, f.next().?, 10), face.line_gap);
        } else if (std.mem.eql(u8, key, "char")) {
            const cp = try std.fmt.parseInt(u21, f.next().?, 10);
            const g = face.glyphIndex(cp);
            try t.expectEqual(try std.fmt.parseInt(u16, f.next().?, 10), g);
            try t.expectEqual(try std.fmt.parseInt(u16, f.next().?, 10), face.advance(g));
        } else if (std.mem.eql(u8, key, "outline")) {
            const cp = try std.fmt.parseInt(u21, f.next().?, 10);
            const o = try face.outline(t.allocator, face.glyphIndex(cp));
            defer o.deinit(t.allocator);
            try t.expectEqual(try std.fmt.parseInt(usize, f.next().?, 10), o.contour_ends.len);
            try t.expectEqual(try std.fmt.parseInt(usize, f.next().?, 10), o.points.len);
        } else if (std.mem.eql(u8, key, "kern")) {
            const pair = f.next().?;
            const want = try std.fmt.parseInt(i16, f.next().?, 10);
            try t.expectEqual(want, face.kerning(face.glyphIndex(pair[0]), face.glyphIndex(pair[1])));
        } else continue;
        checked += 1;
    }
    try t.expect(checked >= 15);
}

/// Expects `error.BadFont`. A result that has an outline is freed first:
/// the report of a leak in a Debug build takes minutes on this binary.
fn expectBadOutline(f: *const ttf.Face, glyph: u16) !void {
    if (f.outline(t.allocator, glyph)) |o| {
        o.deinit(t.allocator);
        return error.TestExpectedError;
    } else |e| try t.expectEqual(error.BadFont, e);
}

// ---- composite glyphs ----

/// Writes the records of a composite glyph over the glyph `target` of a copy of the font.
/// The records are plain bytes, built here from the OpenType specification.
fn patchComposite(copy: []u8, f: ttf.Face, target: u16, records: []const u8) !void {
    const slot = try f.glyphData(target);
    try t.expect(slot.len >= 10 + records.len);
    const off = @intFromPtr(slot.ptr) - @intFromPtr(f.data.ptr);
    @memset(copy[off..][0..slot.len], 0);
    copy[off] = 0xff;
    copy[off + 1] = 0xff;
    @memcpy(copy[off + 10 ..][0..records.len], records);
}

fn be(buf: *std.ArrayList(u8), v: u16) !void {
    try buf.append(t.allocator, @intCast(v >> 8));
    try buf.append(t.allocator, @intCast(v & 0xff));
}

test "ttf composite: a two by two matrix, and a scaled offset" {
    const copy = try t.allocator.dupe(u8, regular);
    defer t.allocator.free(copy);
    const f0 = try ttf.Face.init(copy);
    const ga = f0.glyphIndex('A');
    const gb = f0.glyphIndex('B');
    var rec: std.ArrayList(u8) = .empty;
    defer rec.deinit(t.allocator);
    // A turn by 90 degrees: x' = -y, y' = x. The order is xscale, scale01, scale10, yscale.
    try be(&rec, 0x0002 | 0x0080 | 0x0020);
    try be(&rec, ga);
    try rec.append(t.allocator, 0);
    try rec.append(t.allocator, 0);
    try be(&rec, 0);
    try be(&rec, 0x4000);
    try be(&rec, 0xc000);
    try be(&rec, 0);
    // Scale 0.5, offset (100, 40) that follows the scale: (50, 20).
    try be(&rec, 0x0002 | 0x0008 | 0x0800);
    try be(&rec, ga);
    try rec.append(t.allocator, 100);
    try rec.append(t.allocator, 40);
    try be(&rec, 0x2000);
    try patchComposite(copy, f0, gb, rec.items);
    const f = try ttf.Face.init(copy);
    const base = try f.outline(t.allocator, ga);
    defer base.deinit(t.allocator);
    const o = try f.outline(t.allocator, gb);
    defer o.deinit(t.allocator);
    for (base.points, 0..) |p, i| {
        try t.expectEqual(-p.y, o.points[i].x);
        try t.expectEqual(p.x, o.points[i].y);
        try t.expectEqual(p.x * 0.5 + 50, o.points[base.points.len + i].x);
        try t.expectEqual(p.y * 0.5 + 20, o.points[base.points.len + i].y);
    }
}

test "ttf composite: matching points move the component" {
    const copy = try t.allocator.dupe(u8, regular);
    defer t.allocator.free(copy);
    const f0 = try ttf.Face.init(copy);
    const ga = f0.glyphIndex('A');
    const gb = f0.glyphIndex('B');
    var rec: std.ArrayList(u8) = .empty;
    defer rec.deinit(t.allocator);
    try be(&rec, 0x0001 | 0x0002 | 0x0020);
    try be(&rec, ga);
    try be(&rec, 200);
    try be(&rec, 100);
    // Point 2 of the new component goes to point 5 of the glyph so far.
    try be(&rec, 0);
    try be(&rec, ga);
    try rec.append(t.allocator, 5);
    try rec.append(t.allocator, 2);
    try patchComposite(copy, f0, gb, rec.items);
    const f = try ttf.Face.init(copy);
    const base = try f.outline(t.allocator, ga);
    defer base.deinit(t.allocator);
    const o = try f.outline(t.allocator, gb);
    defer o.deinit(t.allocator);
    const parent = o.points[5];
    const child = o.points[base.points.len + 2];
    try t.expectEqual(parent.x, child.x);
    try t.expectEqual(parent.y, child.y);
}

test "ttf composite: a bad point number or a cut record gives BadFont" {
    const copy = try t.allocator.dupe(u8, regular);
    defer t.allocator.free(copy);
    const f0 = try ttf.Face.init(copy);
    const ga = f0.glyphIndex('A');
    const gb = f0.glyphIndex('B');
    var rec: std.ArrayList(u8) = .empty;
    defer rec.deinit(t.allocator);
    try be(&rec, 0x0001 | 0x0002 | 0x0020);
    try be(&rec, ga);
    try be(&rec, 0);
    try be(&rec, 0);
    try be(&rec, 0);
    try be(&rec, ga);
    try rec.append(t.allocator, 200);
    try rec.append(t.allocator, 0);
    try patchComposite(copy, f0, gb, rec.items);
    const f = try ttf.Face.init(copy);
    try expectBadOutline(&f, gb);
    // A record that asks for more components and has no more bytes. The slot is zero after it,
    // so cut the glyph slot by a loca that ends after the first record.
    var cut: std.ArrayList(u8) = .empty;
    defer cut.deinit(t.allocator);
    try be(&cut, 0x0001 | 0x0002 | 0x0020);
    try be(&cut, ga);
    try be(&cut, 0);
    try be(&cut, 0);
    try be(&cut, 0x0001 | 0x0002);
    try patchComposite(copy, f0, gb, cut.items);
    // The second record has flags 3 and reads the zero bytes after it as glyph 0 at (0, 0).
    const f2 = try ttf.Face.init(copy);
    const o2 = try f2.outline(t.allocator, gb);
    defer o2.deinit(t.allocator);
    const a_outline = try f2.outline(t.allocator, ga);
    defer a_outline.deinit(t.allocator);
    const notdef = try f2.outline(t.allocator, 0);
    defer notdef.deinit(t.allocator);
    try t.expectEqual(a_outline.points.len + notdef.points.len, o2.points.len);
}

test "ttf fuzz: changed bytes in GPOS, cmap, loca, and glyf never trap" {
    const copy = try t.allocator.dupe(u8, regular);
    defer t.allocator.free(copy);
    const f0 = try ttf.Face.init(copy);
    var prng = std.Random.DefaultPrng.init(0x6709);
    const rnd = prng.random();
    // The tables to change: the start of GPOS, where its offsets are, the start of cmap and loca,
    // and the glyph data of a composite glyph.
    const gpos_off = @intFromPtr(f0.gpos.ptr) - @intFromPtr(copy.ptr);
    const cmap_off = @intFromPtr(f0.cmap.ptr) - @intFromPtr(copy.ptr);
    const loca_off = @intFromPtr(f0.loca.ptr) - @intFromPtr(copy.ptr);
    const composite = try f0.glyphData(f0.glyphIndex(0xe9));
    const comp_off = @intFromPtr(composite.ptr) - @intFromPtr(copy.ptr);
    const regions = [_]struct { off: usize, len: usize }{
        .{ .off = gpos_off, .len = 96 },
        .{ .off = gpos_off, .len = f0.gpos.len },
        .{ .off = cmap_off, .len = 64 },
        .{ .off = loca_off, .len = 4000 },
        .{ .off = comp_off, .len = composite.len },
    };
    var n: usize = 0;
    while (n < 3000) : (n += 1) {
        const r = regions[n % regions.len];
        const pos = r.off + rnd.uintLessThan(usize, r.len);
        const old = copy[pos];
        // Half of the changes use the values that make an offset sum overflow.
        copy[pos] = if (n % 3 == 0) 0xff else rnd.int(u8);
        defer copy[pos] = old;
        const f = ttf.Face.init(copy) catch continue;
        var cp: u21 = 32;
        while (cp < 127) : (cp += 1) {
            const g = f.glyphIndex(cp);
            _ = f.kerning(g, f.glyphIndex(cp + 1));
            _ = f.advance(g);
        }
        _ = f.kerning(f.glyphIndex('A'), f.glyphIndex('V'));
        _ = f.kerning(f.glyphIndex('T'), f.glyphIndex('o'));
        if (f.outline(t.allocator, f.glyphIndex(0xe9))) |o| o.deinit(t.allocator) else |_| {}
    }
}
