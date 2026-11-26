//! Fonts and font descriptions. `Fonts` holds the faces that the program
//! adds, and a cache of `Font` values, one for each face, size, and
//! scale. Stage 1 has two faces from the package (Regular and Bold). A
//! weight of 600 or more selects Bold. Each family name selects one of
//! them. With a text engine of the system (`system.zig`, DirectWrite on
//! Windows), `get` opens a face of the system for the description, and
//! the methods of `Font` ask the system for its glyphs and metrics.
//! `parseTk` reads the font values of Tk.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const num = @import("../num.zig");
const ttf = @import("ttf.zig");
const system_mod = @import("system.zig");
pub const System = system_mod.System;

pub const FontDesc = struct {
    family: []const u8 = "system-ui",
    /// Logical pixels.
    size: f32 = 13,
    /// 100 to 900.
    weight: u16 = 400,
    italic: bool = false,
};

/// Logical pixels, rounded up.
pub const Metrics = struct { ascent: i32, descent: i32, line_height: i32 };

pub const Font = struct {
    /// The TrueType face. A font of the system keeps the first face here,
    /// and each method asks the system.
    face: *const ttf.Face,
    /// The text engine of the system and its face, for a font of the system.
    system: ?System = null,
    sys_face: u32 = 0,
    /// Logical pixels.
    size: f32,
    /// Device pixels for each logical pixel.
    scale: f32,
    /// A cache of the glyphs of the ASCII characters. 0xffff is "not read yet".
    ascii: [128]u16 = @splat(0xffff),
    /// A direct-mapped cache of kerning pairs.
    kern_cache: [256]KernEntry = @splat(.{}),

    const KernEntry = struct { key: u32 = 0xffff_ffff, value: i16 = 0 };

    pub fn glyph(f: *Font, cp: u21) u16 {
        if (cp < 128) {
            if (f.ascii[cp] == 0xffff) f.ascii[cp] = f.glyphOf(cp);
            return f.ascii[cp];
        }
        return f.glyphOf(cp);
    }

    /// The kerning of a pair in font units.
    pub fn kern(f: *Font, left: u16, right: u16) i16 {
        const key = (@as(u32, left) << 16) | right;
        const slot = &f.kern_cache[(key *% 2654435761) >> 24];
        if (slot.key == key) return slot.value;
        const v: i16 = if (f.system) |s| std.math.cast(i16, s.kern(f.sys_face, left, right)) orelse 0 else f.face.kerning(left, right);
        slot.* = .{ .key = key, .value = v };
        return v;
    }

    fn glyphOf(f: *const Font, cp: u21) u16 {
        if (f.system) |s| return s.glyph(f.sys_face, cp);
        return f.face.glyphIndex(cp);
    }

    /// The advance of a glyph in font units.
    pub fn advance(f: *const Font, gid: u16) i32 {
        if (f.system) |s| return s.advance(f.sys_face, gid);
        return f.face.advance(gid);
    }

    /// The vertical metrics of the face, in font units.
    pub fn faceMetrics(f: *const Font) system_mod.FaceMetrics {
        if (f.system) |s| return s.metrics(f.sys_face);
        return .{ .units_per_em = f.face.units_per_em, .ascent = f.face.ascent, .descent = f.face.descent, .line_gap = f.face.line_gap };
    }

    /// Device pixels for each font unit.
    pub fn unitScale(f: *const Font) f32 {
        return f.size * f.scale / @as(f32, @floatFromInt(f.faceMetrics().units_per_em));
    }
};

const FontKey = struct { face: u8, size: u32, scale: u32, sys: u32 = 0 };

pub const Fonts = struct {
    gpa: std.mem.Allocator,
    faces: std.ArrayListUnmanaged(*ttf.Face) = .empty,
    /// The text engine of the system, when the platform gives one.
    system: ?System = null,
    cache: std.AutoHashMapUnmanaged(FontKey, *Font) = .empty,
    /// The cache of `measure`.
    widths: std.StringHashMapUnmanaged(i32) = .empty,

    const regular = @embedFile("inter_regular");
    const bold = @embedFile("inter_bold");

    pub fn init(gpa: std.mem.Allocator) !Fonts {
        var f: Fonts = .{ .gpa = gpa };
        errdefer f.deinit();
        try f.add(regular);
        try f.add(bold);
        return f;
    }

    pub fn deinit(f: *Fonts) void {
        var it = f.cache.valueIterator();
        while (it.next()) |v| f.gpa.destroy(v.*);
        f.cache.deinit(f.gpa);
        for (f.faces.items) |face| f.gpa.destroy(face);
        f.faces.deinit(f.gpa);
        f.clearWidths();
        f.widths.deinit(f.gpa);
    }

    pub fn clearWidths(f: *Fonts) void {
        var it = f.widths.keyIterator();
        while (it.next()) |k| f.gpa.free(k.*);
        f.widths.clearRetainingCapacity();
    }

    /// Adds a font from memory. The bytes must stay valid.
    pub fn add(f: *Fonts, data: []const u8) !void {
        const face = try f.gpa.create(ttf.Face);
        errdefer f.gpa.destroy(face);
        face.* = try ttf.Face.init(data);
        try f.faces.append(f.gpa, face);
    }

    /// The font for a description at a scale. The result is cached and
    /// stays valid until `deinit`.
    pub fn get(f: *Fonts, desc: FontDesc, scale: f32) !*Font {
        const want_bold = desc.weight >= 600;
        var idx: usize = if (want_bold and f.faces.items.len > 1) 1 else 0;
        if (idx >= f.faces.items.len) idx = 0;
        if (f.faces.items.len == 0) return error.NoFont;
        // The size can come from a script, and the scale from a backend.
        const size = num.clampF(desc.size, 0, num.max_font_size);
        const safe_scale = if (std.math.isNan(scale)) 1 else std.math.clamp(scale, 0.25, 16);
        // A face of the system, when the system has one for the description.
        const sys_face: ?u32 = if (f.system) |s| s.open(.{ .family = desc.family, .size = size, .weight = desc.weight, .italic = desc.italic }) else null;
        const key: FontKey = if (sys_face) |id| .{ .face = 255, .size = @bitCast(size), .scale = @bitCast(safe_scale), .sys = id } else .{ .face = @intCast(idx), .size = @bitCast(size), .scale = @bitCast(safe_scale) };
        if (f.cache.get(key)) |font| return font;
        const font = try f.gpa.create(Font);
        errdefer f.gpa.destroy(font);
        font.* = .{ .face = f.faces.items[idx], .size = size, .scale = safe_scale, .system = if (sys_face != null) f.system else null, .sys_face = sys_face orelse 0 };
        try f.cache.put(f.gpa, key, font);
        return font;
    }

    pub fn metrics(font: *const Font) Metrics {
        const m = font.faceMetrics();
        const upem: f32 = @floatFromInt(m.units_per_em);
        const asc = num.pxCeil(@as(f32, @floatFromInt(m.ascent)) * font.size / upem);
        const desc = num.pxCeil(-@as(f32, @floatFromInt(m.descent)) * font.size / upem);
        const gap = num.pxCeil(@as(f32, @floatFromInt(m.line_gap)) * font.size / upem);
        return .{ .ascent = asc, .descent = desc, .line_height = num.add(num.add(asc, desc), gap) };
    }

    /// Parses a font value of Tk: "Helvetica 12 bold", {Liberation Sans} 10,
    /// "TkDefaultFont". A positive size is points. A negative size is pixels.
    /// The family text points into `text` or `base`.
    pub fn parseTk(text: []const u8, base: FontDesc, scaling: f64) ?FontDesc {
        var words: [16][]const u8 = undefined;
        var n: usize = 0;
        var i: usize = 0;
        const t = std.mem.trim(u8, text, " \t\n");
        if (t.len == 0) return null;
        while (i < t.len) {
            while (i < t.len and std.ascii.isWhitespace(t[i])) i += 1;
            if (i >= t.len) break;
            if (n == words.len) return null;
            if (t[i] == '{') {
                const close = std.mem.indexOfScalarPos(u8, t, i + 1, '}') orelse return null;
                words[n] = t[i + 1 .. close];
                i = close + 1;
            } else {
                const start = i;
                while (i < t.len and !std.ascii.isWhitespace(t[i])) i += 1;
                words[n] = t[start..i];
            }
            n += 1;
        }
        if (n == 0) return null;
        const named = [_][]const u8{ "TkDefaultFont", "TkTextFont", "TkFixedFont", "TkMenuFont", "TkHeadingFont" };
        for (named, 0..) |nm, k| if (n == 1 and std.mem.eql(u8, words[0], nm)) {
            var d = base;
            if (k == 2) d.family = "monospace";
            return d;
        };
        var d = base;
        d.family = words[0];
        if (n >= 2) {
            const sz = std.fmt.parseFloat(f64, words[1]) catch return null;
            if (!std.math.isFinite(sz) or @abs(sz) > 10000) return null;
            d.size = @floatCast(if (sz >= 0) sz * scaling else -sz);
            d.weight = 400;
            d.italic = false;
        }
        for (words[@min(n, 2)..n]) |w| {
            if (std.mem.eql(u8, w, "bold")) d.weight = 700 else if (std.mem.eql(u8, w, "italic")) d.italic = true else if (std.mem.eql(u8, w, "normal") or std.mem.eql(u8, w, "roman") or std.mem.eql(u8, w, "underline") or std.mem.eql(u8, w, "overstrike")) {} else return null;
        }
        return d;
    }
};
