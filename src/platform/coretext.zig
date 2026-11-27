//! The text engine of macOS as a backend of `text/system.zig` (step 3 of
//! the macOS plan of `docs/dev/native-look.md`): the fonts, metrics,
//! shaping, and glyph images of Core Text, so the text of ztk is the text
//! of AppKit.
//!
//! `system-ui` is the system font of AppKit (`systemFontOfSize:weight:`),
//! SF Pro with the optical size of its point size, and `monospace` is SF
//! Mono. A face stays open at the size of its description, so a glyph
//! image at a larger device size (a Retina screen) keeps the optical size
//! of the point size, as AppKit draws it: the image and the shaper scale
//! the drawing, never the font. Glyph images are gray-scale coverage with
//! no font smoothing, as macOS draws text since 10.14.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const objc = @import("../sys/objc.zig");
const system = @import("../text/system.zig");
const FontDesc = @import("../text/font.zig").FontDesc;
const Bitmap = @import("../text/raster.zig").Bitmap;
const Id = objc.Id;
const Sel = objc.Sel;
const Class = objc.Class;

const CGFloat = f64;
const CGPoint = extern struct { x: CGFloat, y: CGFloat };
const CGSize = extern struct { w: CGFloat, h: CGFloat };
const CGRect = extern struct { origin: CGPoint, size: CGSize };
const CFRange = extern struct { location: isize, length: isize };
const CTFont = *anyopaque;
const CGContext = *anyopaque;

extern "CoreText" fn CTFontGetUnitsPerEm(font: CTFont) c_uint;
extern "CoreText" fn CTFontGetSize(font: CTFont) CGFloat;
extern "CoreText" fn CTFontGetAscent(font: CTFont) CGFloat;
extern "CoreText" fn CTFontGetDescent(font: CTFont) CGFloat;
extern "CoreText" fn CTFontGetLeading(font: CTFont) CGFloat;
extern "CoreText" fn CTFontGetGlyphsForCharacters(font: CTFont, chars: [*]const u16, glyphs: [*]u16, count: isize) bool;
extern "CoreText" fn CTFontGetAdvancesForGlyphs(font: CTFont, orientation: u32, glyphs: [*]const u16, advances: ?[*]CGSize, count: isize) f64;
extern "CoreText" fn CTFontGetBoundingRectsForGlyphs(font: CTFont, orientation: u32, glyphs: [*]const u16, rects: ?[*]CGRect, count: isize) CGRect;
extern "CoreText" fn CTFontDrawGlyphs(font: CTFont, glyphs: [*]const u16, positions: [*]const CGPoint, count: usize, ctx: CGContext) void;
extern "CoreText" fn CTLineCreateWithAttributedString(text: Id) ?*anyopaque;
extern "CoreText" fn CTLineGetGlyphRuns(line: *anyopaque) Id;
extern "CoreText" fn CTLineGetTypographicBounds(line: *anyopaque, ascent: ?*CGFloat, descent: ?*CGFloat, leading: ?*CGFloat) f64;
extern "CoreText" fn CTRunGetGlyphCount(run: *anyopaque) isize;
extern "CoreText" fn CTRunGetGlyphs(run: *anyopaque, range: CFRange, out: [*]u16) void;
extern "CoreText" fn CTRunGetPositions(run: *anyopaque, range: CFRange, out: [*]CGPoint) void;
extern "CoreText" fn CTRunGetStringIndices(run: *anyopaque, range: CFRange, out: [*]isize) void;
extern "CoreText" fn CTRunGetAttributes(run: *anyopaque) Id;

extern "CoreGraphics" fn CGColorSpaceCreateDeviceGray() ?*anyopaque;
extern "CoreGraphics" fn CGColorSpaceRelease(space: ?*anyopaque) void;
extern "CoreGraphics" fn CGBitmapContextCreate(data: ?*anyopaque, w: usize, h: usize, bits: usize, row: usize, space: ?*anyopaque, info: u32) ?CGContext;
extern "CoreGraphics" fn CGContextRelease(ctx: CGContext) void;
extern "CoreGraphics" fn CGContextSetGrayFillColor(ctx: CGContext, gray: CGFloat, alpha: CGFloat) void;
extern "CoreGraphics" fn CGContextTranslateCTM(ctx: CGContext, x: CGFloat, y: CGFloat) void;
extern "CoreGraphics" fn CGContextScaleCTM(ctx: CGContext, x: CGFloat, y: CGFloat) void;
extern "CoreGraphics" fn CGContextSetShouldSmoothFonts(ctx: CGContext, on: bool) void;
extern "CoreGraphics" fn CGContextSetAllowsFontSubpixelPositioning(ctx: CGContext, on: bool) void;
extern "CoreGraphics" fn CGContextSetShouldSubpixelPositionFonts(ctx: CGContext, on: bool) void;
extern "CoreGraphics" fn CGContextSetShouldSubpixelQuantizeFonts(ctx: CGContext, on: bool) void;

const Face = struct {
    family: []u8,
    size: f32,
    weight: u16,
    italic: bool,
    /// An NSFont, which is a CTFont, retained.
    font: Id,
    upem: f64,
    metrics: system.FaceMetrics,

    fn ct(f: Face) CTFont {
        return @ptrCast(f.font);
    }

    /// Design units of a length at the size of the face.
    fn units(f: Face, v: f64) i32 {
        return @intFromFloat(@round(v * f.upem / f.size));
    }
};

pub const CoreText = struct {
    gpa: std.mem.Allocator,
    faces: std.ArrayListUnmanaged(Face) = .empty,

    pub fn init(gpa: std.mem.Allocator) ?*CoreText {
        const c = gpa.create(CoreText) catch return null;
        c.* = .{ .gpa = gpa };
        return c;
    }

    pub fn deinit(c: *CoreText) void {
        for (c.faces.items) |f| {
            objc.release(f.font);
            c.gpa.free(f.family);
        }
        c.faces.deinit(c.gpa);
        c.gpa.destroy(c);
    }

    pub fn backend(c: *CoreText) system.System {
        return .{ .ctx = c, .vtable = &vtable };
    }

    fn open(c: *CoreText, desc: FontDesc) ?u32 {
        const size = if (desc.size > 0) desc.size else 13;
        for (c.faces.items, 0..) |f, i| {
            if (f.size == size and f.weight == desc.weight and f.italic == desc.italic and std.ascii.eqlIgnoreCase(f.family, desc.family)) return @intCast(i);
        }
        const font = make(desc.family, size, desc.weight, desc.italic) orelse return null;
        const ctf: CTFont = @ptrCast(font);
        const family = c.gpa.dupe(u8, desc.family) catch {
            objc.release(font);
            return null;
        };
        var f: Face = .{ .family = family, .size = size, .weight = desc.weight, .italic = desc.italic, .font = font, .upem = @floatFromInt(CTFontGetUnitsPerEm(ctf)), .metrics = undefined };
        f.metrics = .{
            .units_per_em = @intCast(@min(CTFontGetUnitsPerEm(ctf), std.math.maxInt(u16))),
            .ascent = f.units(CTFontGetAscent(ctf)),
            .descent = -f.units(CTFontGetDescent(ctf)),
            .line_gap = f.units(CTFontGetLeading(ctf)),
        };
        c.faces.append(c.gpa, f) catch {
            objc.release(font);
            c.gpa.free(family);
            return null;
        };
        return @intCast(c.faces.items.len - 1);
    }
};

/// The NSFontWeight of a CSS weight (the constants of NSFont.h).
fn nsWeight(w: u16) CGFloat {
    return if (w <= 100) -0.8 else if (w <= 200) -0.6 else if (w <= 300) -0.4 else if (w <= 400) 0 else if (w <= 500) 0.23 else if (w <= 600) 0.3 else if (w <= 700) 0.4 else if (w <= 800) 0.56 else 0.62;
}

fn cls(name: [*:0]const u8) Class {
    return objc.class(name).?;
}

/// A retained NSFont for a description, or null.
fn make(family: []const u8, size: f32, weight: u16, italic: bool) ?Id {
    const pool = objc.Pool.push();
    defer pool.pop();
    const sz: CGFloat = size;
    const nsfont = cls("NSFont");
    const ui = family.len == 0 or std.ascii.eqlIgnoreCase(family, "system-ui") or std.ascii.eqlIgnoreCase(family, "sans-serif") or
        std.ascii.eqlIgnoreCase(family, "TkDefaultFont") or std.ascii.eqlIgnoreCase(family, "Helvetica");
    const mono = std.ascii.eqlIgnoreCase(family, "monospace") or std.ascii.eqlIgnoreCase(family, "Courier") or std.ascii.eqlIgnoreCase(family, "TkFixedFont");
    var font: ?Id = null;
    if (ui) {
        font = objc.call(fn (Class, Sel, CGFloat, CGFloat) callconv(.c) ?Id, nsfont, "systemFontOfSize:weight:", .{ sz, nsWeight(weight) });
    } else if (mono) {
        font = objc.call(fn (Class, Sel, CGFloat, CGFloat) callconv(.c) ?Id, nsfont, "monospacedSystemFontOfSize:weight:", .{ sz, nsWeight(weight) });
    } else {
        const name: []const u8 = if (std.ascii.eqlIgnoreCase(family, "serif") or std.ascii.eqlIgnoreCase(family, "Times")) "Times" else family;
        const fam = objc.nsString(name);
        defer objc.release(fam);
        const mgr = objc.call(fn (Class, Sel) callconv(.c) Id, cls("NSFontManager"), "sharedFontManager", .{});
        // The weight scale of NSFontManager: 5 is regular, 9 is bold.
        const w: isize = @intCast(@min(14, 1 + @as(u32, weight) / 100));
        font = objc.call(fn (Id, Sel, Id, usize, isize, CGFloat) callconv(.c) ?Id, mgr, "fontWithFamily:traits:weight:size:", .{ fam, @as(usize, 0), if (weight == 400) 5 else w, sz });
    }
    var f = font orelse return null;
    if (italic) {
        const d = objc.call(fn (Id, Sel) callconv(.c) Id, f, "fontDescriptor", .{});
        // NSFontDescriptorTraitItalic.
        const di = objc.call(fn (Id, Sel, u32) callconv(.c) Id, d, "fontDescriptorWithSymbolicTraits:", .{@as(u32, 1)});
        if (objc.call(fn (Class, Sel, Id, CGFloat) callconv(.c) ?Id, nsfont, "fontWithDescriptor:size:", .{ di, sz })) |x| f = x;
    }
    return objc.call(fn (Id, Sel) callconv(.c) Id, f, "retain", .{});
}

fn self(ctx: *anyopaque) *CoreText {
    return @ptrCast(@alignCast(ctx));
}

fn vOpen(ctx: *anyopaque, desc: FontDesc) ?u32 {
    return self(ctx).open(desc);
}

fn vMetrics(ctx: *anyopaque, f: u32) system.FaceMetrics {
    return self(ctx).faces.items[f].metrics;
}

fn glyphOf(font: CTFont, cp: u21) u16 {
    var units: [2]u16 = undefined;
    var glyphs: [2]u16 = .{ 0, 0 };
    const n: isize = if (cp >= 0x10000) blk: {
        const v = cp - 0x10000;
        units = .{ @intCast(0xD800 + (v >> 10)), @intCast(0xDC00 + (v & 0x3FF)) };
        break :blk 2;
    } else blk: {
        units[0] = @intCast(cp);
        break :blk 1;
    };
    if (!CTFontGetGlyphsForCharacters(font, &units, &glyphs, n)) return 0;
    return glyphs[0];
}

fn vGlyph(ctx: *anyopaque, f: u32, cp: u21) u16 {
    return glyphOf(self(ctx).faces.items[f].ct(), cp);
}

fn vAdvance(ctx: *anyopaque, f: u32, g: u16) i32 {
    const face = self(ctx).faces.items[f];
    var adv: CGSize = undefined;
    _ = CTFontGetAdvancesForGlyphs(face.ct(), 0, @ptrCast(&g), @ptrCast(&adv), 1);
    return face.units(adv.w);
}

/// The shaper of Core Text places the pairs, so there is no kerning of
/// its own.
fn vKern(_: *anyopaque, _: u32, _: u16, _: u16) i32 {
    return 0;
}

fn vRaster(ctx: *anyopaque, gpa: std.mem.Allocator, f: u32, g: u16, em_px: f32, sub_x: f32) anyerror!Bitmap {
    const face = self(ctx).faces.items[f];
    const k: f64 = @as(f64, em_px) / face.size;
    var r: CGRect = undefined;
    _ = CTFontGetBoundingRectsForGlyphs(face.ct(), 0, @ptrCast(&g), @ptrCast(&r), 1);
    if (r.size.w <= 0 or r.size.h <= 0) return .{ .width = 0, .height = 0, .left = 0, .top = 0, .pixels = try gpa.alloc(u8, 0) };
    // The box of the glyph in device pixels, one pixel larger on each side
    // for the edge of the coverage. y goes up from the baseline here.
    const x0: i32 = @intFromFloat(@floor(r.origin.x * k + sub_x) - 1);
    const x1: i32 = @intFromFloat(@ceil((r.origin.x + r.size.w) * k + sub_x) + 1);
    const y0: i32 = @intFromFloat(@floor(r.origin.y * k) - 1);
    const y1: i32 = @intFromFloat(@ceil((r.origin.y + r.size.h) * k) + 1);
    const w: u32 = @intCast(x1 - x0);
    const h: u32 = @intCast(y1 - y0);
    const pixels = try gpa.alloc(u8, w * h);
    errdefer gpa.free(pixels);
    @memset(pixels, 0);
    const space = CGColorSpaceCreateDeviceGray();
    defer CGColorSpaceRelease(space);
    // kCGImageAlphaNone: one byte of gray for each pixel, the first row on top.
    const cg = CGBitmapContextCreate(pixels.ptr, w, h, 8, w, space, 0) orelse return error.GlyphImage;
    defer CGContextRelease(cg);
    CGContextSetShouldSmoothFonts(cg, false);
    CGContextSetAllowsFontSubpixelPositioning(cg, true);
    CGContextSetShouldSubpixelPositionFonts(cg, true);
    CGContextSetShouldSubpixelQuantizeFonts(cg, false);
    CGContextSetGrayFillColor(cg, 1, 1);
    CGContextTranslateCTM(cg, @as(f64, sub_x) - @as(f64, @floatFromInt(x0)), -@as(f64, @floatFromInt(y0)));
    CGContextScaleCTM(cg, k, k);
    const origin: CGPoint = .{ .x = 0, .y = 0 };
    CTFontDrawGlyphs(face.ct(), @ptrCast(&g), @ptrCast(&origin), 1, cg);
    return .{ .width = w, .height = h, .left = x0, .top = -y1, .pixels = pixels };
}

/// Shapes `text` with a CTLine of the face. A run of the line in another
/// font (the cascade of Core Text for a character the face lacks) gives
/// the glyphs of the face for its characters, since a glyph of `out`
/// names no face; the fallback of ztk is above the shaper.
fn vShape(ctx: *anyopaque, gpa: std.mem.Allocator, f: u32, em_px: f32, text: []const u8, out: *std.ArrayListUnmanaged(system.Glyph)) anyerror!f32 {
    const face = self(ctx).faces.items[f];
    const k: f64 = @as(f64, em_px) / face.size;
    // The byte index in `text` of each UTF-16 unit, and the code point.
    var byte_of: std.ArrayListUnmanaged(u32) = .empty;
    defer byte_of.deinit(gpa);
    var cps: std.ArrayListUnmanaged(u21) = .empty;
    defer cps.deinit(gpa);
    var clean: std.ArrayListUnmanaged(u8) = .empty;
    defer clean.deinit(gpa);
    var i: usize = 0;
    while (i < text.len) {
        // A byte that starts no valid sequence is U+FFFD, as in shape.zig.
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const decoded: ?u21 = if (i + len <= text.len) std.unicode.utf8Decode(text[i..][0..len]) catch null else null;
        const cp: u21 = decoded orelse 0xFFFD;
        const step: usize = if (decoded != null) len else 1;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
        try clean.appendSlice(gpa, buf[0..n]);
        const units: usize = if (cp >= 0x10000) 2 else 1;
        for (0..units) |_| {
            try byte_of.append(gpa, @intCast(i));
            try cps.append(gpa, cp);
        }
        i += step;
    }
    if (clean.items.len == 0) return 0;

    const pool = objc.Pool.push();
    defer pool.pop();
    const str = objc.nsString(clean.items);
    defer objc.release(str);
    const key = objc.nsString("NSFont");
    defer objc.release(key);
    const attrs = objc.call(fn (Class, Sel, Id, Id) callconv(.c) Id, cls("NSDictionary"), "dictionaryWithObject:forKey:", .{ face.font, key });
    const raw = objc.call(fn (Class, Sel) callconv(.c) Id, cls("NSAttributedString"), "alloc", .{});
    const astr = objc.call(fn (Id, Sel, Id, Id) callconv(.c) Id, raw, "initWithString:attributes:", .{ str, attrs });
    defer objc.release(astr);
    const line = CTLineCreateWithAttributedString(astr) orelse return error.Shape;
    defer objc.release(@ptrCast(line));

    const runs = CTLineGetGlyphRuns(line);
    const nruns = objc.call(fn (Id, Sel) callconv(.c) usize, runs, "count", .{});
    for (0..nruns) |ri| {
        const run: *anyopaque = @ptrCast(objc.call(fn (Id, Sel, usize) callconv(.c) Id, runs, "objectAtIndex:", .{ri}));
        const n: usize = @intCast(CTRunGetGlyphCount(run));
        if (n == 0) continue;
        const glyphs = try gpa.alloc(u16, n);
        defer gpa.free(glyphs);
        const pos = try gpa.alloc(CGPoint, n);
        defer gpa.free(pos);
        const idx = try gpa.alloc(isize, n);
        defer gpa.free(idx);
        const all: CFRange = .{ .location = 0, .length = 0 };
        CTRunGetGlyphs(run, all, glyphs.ptr);
        CTRunGetPositions(run, all, pos.ptr);
        CTRunGetStringIndices(run, all, idx.ptr);
        const run_font = objc.call(fn (Id, Sel, Id) callconv(.c) ?Id, CTRunGetAttributes(run), "objectForKey:", .{key});
        const same = if (run_font) |rf| objc.call(fn (Id, Sel, Id) callconv(.c) bool, rf, "isEqual:", .{face.font}) else false;
        try out.ensureUnusedCapacity(gpa, n);
        for (glyphs, pos, idx) |gl, p, u| {
            const unit: usize = @intCast(@max(0, @min(u, @as(isize, @intCast(byte_of.items.len - 1)))));
            out.appendAssumeCapacity(.{
                .id = if (same) gl else glyphOf(face.ct(), cps.items[unit]),
                .x = @floatCast(p.x * k),
                .y = @floatCast(-p.y * k),
                .cluster = byte_of.items[unit],
            });
        }
    }
    return @floatCast(CTLineGetTypographicBounds(line, null, null, null) * k);
}

const vtable: system.System.VTable = .{
    .open = vOpen,
    .metrics = vMetrics,
    .glyph = vGlyph,
    .advance = vAdvance,
    .kern = vKern,
    .raster = vRaster,
    .shape = vShape,
};

test "coretext: the system font has the metrics of NSFont" {
    const c = CoreText.init(std.testing.allocator).?;
    defer c.deinit();
    const f = c.open(.{ .family = "system-ui", .size = 13 }).?;
    try std.testing.expectEqual(f, c.open(.{ .family = "system-ui", .size = 13 }).?);
    const m = vMetrics(c, f);
    const face = c.faces.items[f];
    const asc = objc.call(fn (Id, Sel) callconv(.c) CGFloat, face.font, "ascender", .{});
    // The ascent in design units at 13 pt is the ascender of NSFont.
    try std.testing.expectApproxEqAbs(asc, @as(f64, @floatFromInt(m.ascent)) * 13 / @as(f64, @floatFromInt(m.units_per_em)), 0.01);
    try std.testing.expect(m.descent < 0);
    // The bold face is another face.
    try std.testing.expect(c.open(.{ .family = "system-ui", .size = 13, .weight = 700 }).? != f);
}

test "coretext: a glyph image covers the glyph" {
    const gpa = std.testing.allocator;
    const c = CoreText.init(gpa).?;
    defer c.deinit();
    const f = c.open(.{ .family = "system-ui", .size = 13 }).?;
    const g = vGlyph(c, f, 'H');
    try std.testing.expect(g != 0);
    const b = try vRaster(c, gpa, f, g, 26, 0);
    defer b.deinit(gpa);
    // An H of 13 pt at the scale of 2: about 18 pixels high, above the
    // baseline, with full coverage in its stems.
    try std.testing.expect(b.height >= 18 and b.height <= 24);
    try std.testing.expect(b.top < -16);
    var full: usize = 0;
    for (b.pixels) |p| full += @intFromBool(p == 255);
    try std.testing.expect(full > 40);
    // A space has no image.
    const sp = try vRaster(c, gpa, f, vGlyph(c, f, ' '), 26, 0);
    defer sp.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 0), sp.width);
}

test "coretext: the shaper kerns and maps the clusters to bytes" {
    const gpa = std.testing.allocator;
    const c = CoreText.init(gpa).?;
    defer c.deinit();
    const f = c.open(.{ .family = "system-ui", .size = 13 }).?;
    var out: std.ArrayListUnmanaged(system.Glyph) = .empty;
    defer out.deinit(gpa);
    const av = try vShape(c, gpa, f, 26, "AV", &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    const us: f32 = 26.0 / @as(f32, @floatFromInt(vMetrics(c, f).units_per_em));
    const plain = @as(f32, @floatFromInt(vAdvance(c, f, out.items[0].id) + vAdvance(c, f, out.items[1].id))) * us;
    // A and V kern together.
    try std.testing.expect(av < plain - 0.5);
    out.clearRetainingCapacity();
    // é is two bytes, and 😀 is four bytes and two UTF-16 units.
    _ = try vShape(c, gpa, f, 26, "é😀x", &out);
    try std.testing.expectEqual(@as(u32, 0), out.items[0].cluster);
    try std.testing.expectEqual(@as(u32, 6), out.items[out.items.len - 1].cluster);
    // Invalid UTF-8 shapes too.
    out.clearRetainingCapacity();
    _ = try vShape(c, gpa, f, 26, "a\xffb", &out);
    try std.testing.expectEqual(@as(u32, 2), out.items[out.items.len - 1].cluster);
}

test "coretext: the optical size stays at a larger device size" {
    const gpa = std.testing.allocator;
    const c = CoreText.init(gpa).?;
    defer c.deinit();
    // 13 pt at the scale of 2 is 13 pt text (SF Pro Text), not 26 pt text
    // (SF Pro Display): its advances are twice those at the scale of 1.
    const f = c.open(.{ .family = "system-ui", .size = 13 }).?;
    var out: std.ArrayListUnmanaged(system.Glyph) = .empty;
    defer out.deinit(gpa);
    const w1 = try vShape(c, gpa, f, 13, "Settings", &out);
    out.clearRetainingCapacity();
    const w2 = try vShape(c, gpa, f, 26, "Settings", &out);
    try std.testing.expectApproxEqAbs(w1 * 2, w2, 0.01);
    const big = c.open(.{ .family = "system-ui", .size = 26 }).?;
    out.clearRetainingCapacity();
    const wbig = try vShape(c, gpa, big, 26, "Settings", &out);
    try std.testing.expect(@abs(wbig - w2) > 0.5);
}
