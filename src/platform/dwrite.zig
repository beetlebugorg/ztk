//! The text engine of Windows for ztk: DirectWrite as a `text/system.zig`
//! backend (step 2 of `docs/dev/native-look.md`).
//!
//! `open` maps a family of ztk to the fonts of the system: `system-ui`
//! (the default of the themes) is Segoe UI Variable with the optical
//! size of the em size (Small below 12 px, Display from 20 px, Text
//! between), as the Fluent type ramp uses it, and Segoe UI where the
//! variable font is absent (Windows 10). `monospace` is Cascadia Mono,
//! then Consolas. The Tk names Helvetica, Courier, and Times are Arial,
//! Courier New, and Times New Roman, as Tk maps them on Windows. Another
//! name is a family of the system, and a missing family falls back to
//! `system-ui`. The system font collection gives the family, its first
//! matching font for the weight and the style gives the face, and each
//! face stays open for the life of the backend.
//!
//! The metrics, the glyph of each code point, the advances, and the
//! kerning pairs (`IDWriteFontFace1`) come from the face in design units.
//! A glyph image comes from `IDWriteFactory2::CreateGlyphRunAnalysis` with
//! the natural symmetric rendering mode and grayscale antialiasing, as
//! WinUI 3 draws text, and the 8-bit alpha texture is the coverage of
//! the atlas. The COM slots are from `dwrite.h`, `dwrite_1.h`, and
//! `dwrite_2.h` of the Windows SDK.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const com = @import("../sys/com.zig");
const system = @import("../text/system.zig");
const FontDesc = @import("../text/font.zig").FontDesc;
const Bitmap = @import("../text/raster.zig").Bitmap;
const GUID = com.GUID;
const HRESULT = com.HRESULT;

extern "dwrite" fn DWriteCreateFactory(kind: u32, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT;

const IID_IDWriteFactory2 = GUID.parse("0439fc60-ca44-4994-8dee-3a9af7b732ec");
const IID_IDWriteFontFace1 = GUID.parse("a71efdb4-9fdb-4838-ad90-cfc3be8c3daf");

// The slots of the methods, after the three of IUnknown.
const factory_system_collection = 3;
const factory2_glyph_run_analysis = 30;
const collection_get_family = 4;
const collection_find_family = 5;
const family_first_matching = 7;
const font_create_face = 13;
const face_get_metrics = 8;
const face_design_glyph_metrics = 10;
const face_glyph_indices = 11;
const face1_kerning = 25;
const face1_has_kerning = 26;
const analysis_bounds = 3;
const analysis_texture = 4;

const rendering_natural_symmetric = 5;
const measuring_natural = 0;
const grid_fit_default = 0;
const antialias_grayscale = 1;
const texture_aliased_1x1 = 0;
const stretch_normal = 5;
const style_normal = 0;
const style_italic = 2;

const FONT_METRICS = extern struct {
    designUnitsPerEm: u16,
    ascent: u16,
    descent: u16,
    lineGap: i16,
    capHeight: u16,
    xHeight: u16,
    underlinePosition: i16,
    underlineThickness: u16,
    strikethroughPosition: i16,
    strikethroughThickness: u16,
};
const GLYPH_METRICS = extern struct {
    leftSideBearing: i32,
    advanceWidth: u32,
    rightSideBearing: i32,
    topSideBearing: i32,
    advanceHeight: u32,
    bottomSideBearing: i32,
    verticalOriginY: i32,
};
const GLYPH_RUN = extern struct {
    fontFace: ?*anyopaque,
    fontEmSize: f32,
    glyphCount: u32,
    glyphIndices: ?[*]const u16,
    glyphAdvances: ?[*]const f32,
    glyphOffsets: ?*const anyopaque,
    isSideways: i32,
    bidiLevel: u32,
};
const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };

comptime {
    std.debug.assert(@sizeOf(FONT_METRICS) == 20);
    std.debug.assert(@sizeOf(GLYPH_METRICS) == 28);
    if (@sizeOf(usize) == 8) std.debug.assert(@sizeOf(GLYPH_RUN) == 48);
}

const Face = struct {
    name: []u8,
    weight: u16,
    italic: bool,
    face: *anyopaque,
    face1: ?*anyopaque,
    kerning: bool,
    metrics: system.FaceMetrics,
};

pub const DWrite = struct {
    gpa: std.mem.Allocator,
    factory: *anyopaque,
    collection: *anyopaque,
    faces: std.ArrayListUnmanaged(Face) = .empty,

    /// A backend on the shared factory of the process, or null when the
    /// system has no DirectWrite 2 (before Windows 8.1).
    pub fn init(gpa: std.mem.Allocator) ?*DWrite {
        var f: ?*anyopaque = null;
        if (DWriteCreateFactory(0, &IID_IDWriteFactory2, &f) < 0) return null;
        const factory = f orelse return null;
        var c: ?*anyopaque = null;
        if (com.call(HRESULT, factory, factory_system_collection, .{ &c, @as(i32, 0) }) < 0 or c == null) {
            com.release(factory);
            return null;
        }
        const d = gpa.create(DWrite) catch {
            com.release(c.?);
            com.release(factory);
            return null;
        };
        d.* = .{ .gpa = gpa, .factory = factory, .collection = c.? };
        return d;
    }

    pub fn deinit(d: *DWrite) void {
        for (d.faces.items) |f| {
            if (f.face1) |x| com.release(x);
            com.release(f.face);
            d.gpa.free(f.name);
        }
        d.faces.deinit(d.gpa);
        com.release(d.collection);
        com.release(d.factory);
        d.gpa.destroy(d);
    }

    pub fn backend(d: *DWrite) system.System {
        return .{ .ctx = d, .vtable = &vtable };
    }

    /// The face of a family, a weight, and a style, opened once.
    fn face(d: *DWrite, name: []const u8, weight: u16, italic: bool) ?u32 {
        for (d.faces.items, 0..) |f, i| {
            if (f.weight == weight and f.italic == italic and std.ascii.eqlIgnoreCase(f.name, name)) return @intCast(i);
        }
        const w = std.unicode.utf8ToUtf16LeAllocZ(d.gpa, name) catch return null;
        defer d.gpa.free(w);
        var index: u32 = 0;
        var exists: i32 = 0;
        if (com.call(HRESULT, d.collection, collection_find_family, .{ w.ptr, &index, &exists }) < 0 or exists == 0) return null;
        var fam: ?*anyopaque = null;
        if (com.call(HRESULT, d.collection, collection_get_family, .{ index, &fam }) < 0) return null;
        defer com.release(fam.?);
        var font: ?*anyopaque = null;
        if (com.call(HRESULT, fam.?, family_first_matching, .{ @as(u32, std.math.clamp(weight, 1, 999)), @as(u32, stretch_normal), @as(u32, if (italic) style_italic else style_normal), &font }) < 0) return null;
        defer com.release(font.?);
        var ff: ?*anyopaque = null;
        if (com.call(HRESULT, font.?, font_create_face, .{&ff}) < 0) return null;
        var m: FONT_METRICS = undefined;
        com.call(void, ff.?, face_get_metrics, .{&m});
        var f1: ?*anyopaque = null;
        _ = com.call(HRESULT, ff.?, 0, .{ &IID_IDWriteFontFace1, &f1 });
        const kerning = if (f1) |x| com.call(i32, x, face1_has_kerning, .{}) != 0 else false;
        const copy = d.gpa.dupe(u8, name) catch {
            if (f1) |x| com.release(x);
            com.release(ff.?);
            return null;
        };
        d.faces.append(d.gpa, .{
            .name = copy,
            .weight = weight,
            .italic = italic,
            .face = ff.?,
            .face1 = f1,
            .kerning = kerning,
            .metrics = .{ .units_per_em = m.designUnitsPerEm, .ascent = m.ascent, .descent = -@as(i32, m.descent), .line_gap = m.lineGap },
        }) catch {
            d.gpa.free(copy);
            if (f1) |x| com.release(x);
            com.release(ff.?);
            return null;
        };
        return @intCast(d.faces.items.len - 1);
    }
};

/// The families of the system for a family of ztk, best first.
pub fn candidates(desc: FontDesc, out: *[3][]const u8) []const []const u8 {
    const fam = desc.family;
    const ui: []const u8 = if (desc.size < 12) "Segoe UI Variable Small" else if (desc.size >= 20) "Segoe UI Variable Display" else "Segoe UI Variable Text";
    if (std.ascii.eqlIgnoreCase(fam, "system-ui") or std.ascii.eqlIgnoreCase(fam, "sans-serif") or fam.len == 0) {
        out.* = .{ ui, "Segoe UI", "Arial" };
    } else if (std.ascii.eqlIgnoreCase(fam, "monospace")) {
        out.* = .{ "Cascadia Mono", "Consolas", "Courier New" };
    } else if (std.ascii.eqlIgnoreCase(fam, "serif") or std.ascii.eqlIgnoreCase(fam, "Times")) {
        out.* = .{ "Times New Roman", ui, "Segoe UI" };
    } else if (std.ascii.eqlIgnoreCase(fam, "Helvetica")) {
        out.* = .{ "Arial", ui, "Segoe UI" };
    } else if (std.ascii.eqlIgnoreCase(fam, "Courier")) {
        out.* = .{ "Courier New", "Consolas", ui };
    } else {
        out.* = .{ fam, ui, "Segoe UI" };
    }
    return out[0..];
}

fn self(ctx: *anyopaque) *DWrite {
    return @ptrCast(@alignCast(ctx));
}

fn vOpen(ctx: *anyopaque, desc: FontDesc) ?u32 {
    const d = self(ctx);
    var buf: [3][]const u8 = undefined;
    for (candidates(desc, &buf)) |name| {
        if (d.face(name, desc.weight, desc.italic)) |id| return id;
    }
    return null;
}

fn vMetrics(ctx: *anyopaque, f: u32) system.FaceMetrics {
    return self(ctx).faces.items[f].metrics;
}

fn vGlyph(ctx: *anyopaque, f: u32, cp: u21) u16 {
    const cp32: u32 = cp;
    var g: u16 = 0;
    _ = com.call(HRESULT, self(ctx).faces.items[f].face, face_glyph_indices, .{ &cp32, @as(u32, 1), &g });
    return g;
}

fn vAdvance(ctx: *anyopaque, f: u32, g: u16) i32 {
    var m: GLYPH_METRICS = undefined;
    if (com.call(HRESULT, self(ctx).faces.items[f].face, face_design_glyph_metrics, .{ &g, @as(u32, 1), &m, @as(i32, 0) }) < 0) return 0;
    return @intCast(m.advanceWidth);
}

fn vKern(ctx: *anyopaque, f: u32, left: u16, right: u16) i32 {
    const rec = self(ctx).faces.items[f];
    if (!rec.kerning) return 0;
    const pair = [2]u16{ left, right };
    var adj = [2]i32{ 0, 0 };
    if (com.call(HRESULT, rec.face1.?, face1_kerning, .{ @as(u32, 2), &pair, &adj }) < 0) return 0;
    return adj[0];
}

fn vRaster(ctx: *anyopaque, gpa: std.mem.Allocator, f: u32, g: u16, em_px: f32, sub_x: f32) anyerror!Bitmap {
    const d = self(ctx);
    const advance: f32 = 0;
    const run: GLYPH_RUN = .{ .fontFace = d.faces.items[f].face, .fontEmSize = em_px, .glyphCount = 1, .glyphIndices = @ptrCast(&g), .glyphAdvances = @ptrCast(&advance), .glyphOffsets = null, .isSideways = 0, .bidiLevel = 0 };
    var an: ?*anyopaque = null;
    if (com.call(HRESULT, d.factory, factory2_glyph_run_analysis, .{ &run, @as(?*const anyopaque, null), @as(u32, rendering_natural_symmetric), @as(u32, measuring_natural), @as(u32, grid_fit_default), @as(u32, antialias_grayscale), sub_x, @as(f32, 0), &an }) < 0 or an == null) return error.GlyphImage;
    defer com.release(an.?);
    var r: RECT = undefined;
    if (com.call(HRESULT, an.?, analysis_bounds, .{ @as(u32, texture_aliased_1x1), &r }) < 0) return error.GlyphImage;
    const w: u32 = if (r.right > r.left) @intCast(r.right - r.left) else 0;
    const h: u32 = if (r.bottom > r.top) @intCast(r.bottom - r.top) else 0;
    const pixels = try gpa.alloc(u8, w * h);
    errdefer gpa.free(pixels);
    if (w > 0 and h > 0) {
        if (com.call(HRESULT, an.?, analysis_texture, .{ @as(u32, texture_aliased_1x1), &r, pixels.ptr, @as(u32, w * h) }) < 0) return error.GlyphImage;
    }
    return .{ .width = w, .height = h, .left = r.left, .top = r.top, .pixels = pixels };
}

const vtable: system.System.VTable = .{
    .open = vOpen,
    .metrics = vMetrics,
    .glyph = vGlyph,
    .advance = vAdvance,
    .kern = vKern,
    .raster = vRaster,
};

test "dwrite: Segoe UI gives metrics, glyphs, advances, and an image of a glyph" {
    const d = DWrite.init(std.testing.allocator) orelse return error.SkipZigTest;
    defer d.deinit();
    const s = d.backend();
    const id = s.open(.{ .family = "system-ui", .size = 14 }) orelse return error.NoFont;
    // The same description gives the same face.
    try std.testing.expectEqual(id, s.open(.{ .family = "system-ui", .size = 14 }).?);
    const m = s.metrics(id);
    try std.testing.expect(m.units_per_em >= 1000 and m.ascent > 0 and m.descent < 0);
    const a = s.glyph(id, 'A');
    try std.testing.expect(a != 0);
    try std.testing.expect(s.advance(id, a) > 0);
    // A bold face has wider glyphs.
    const bold = s.open(.{ .family = "system-ui", .size = 14, .weight = 700 }).?;
    try std.testing.expect(bold != id);
    try std.testing.expect(s.advance(bold, s.glyph(bold, 'W')) >= s.advance(id, s.glyph(id, 'W')));
    const bm = try s.raster(std.testing.allocator, id, a, 28, 0);
    defer bm.deinit(std.testing.allocator);
    try std.testing.expect(bm.width > 8 and bm.height > 12);
    // The glyph stands on the baseline.
    try std.testing.expect(bm.top < 0 and bm.top + @as(i32, @intCast(bm.height)) >= 0);
    var full: usize = 0;
    for (bm.pixels) |p| full += @intFromBool(p == 255);
    try std.testing.expect(full > 0);
    // A space has an advance and no image.
    const sp = try s.raster(std.testing.allocator, id, s.glyph(id, ' '), 28, 0);
    defer sp.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), sp.width);
}

test "dwrite: the families of ztk map to the fonts of Windows" {
    var buf: [3][]const u8 = undefined;
    try std.testing.expectEqualStrings("Segoe UI Variable Text", candidates(.{ .family = "system-ui", .size = 14 }, &buf)[0]);
    try std.testing.expectEqualStrings("Segoe UI Variable Small", candidates(.{ .family = "system-ui", .size = 11 }, &buf)[0]);
    try std.testing.expectEqualStrings("Segoe UI Variable Display", candidates(.{ .family = "system-ui", .size = 28 }, &buf)[0]);
    try std.testing.expectEqualStrings("Cascadia Mono", candidates(.{ .family = "monospace" }, &buf)[0]);
    try std.testing.expectEqualStrings("Arial", candidates(.{ .family = "Helvetica" }, &buf)[0]);
    try std.testing.expectEqualStrings("Georgia", candidates(.{ .family = "Georgia" }, &buf)[0]);
}
