//! Text layout for one line of left-to-right text. `shape` decodes the
//! UTF-8, maps each code point to a glyph, and places each glyph at the
//! sum of the advances and the kerning before it. Positions are device
//! pixels and are not rounded per advance. An invalid UTF-8 byte gives
//! the glyph 0 and uses one byte. `measure` caches the widths.
//!
//! The text goes in extended grapheme clusters (UAX #29, `ztcl.text`).
//! Each glyph of a cluster has the byte offset of the cluster start, so
//! the caret stops only at cluster boundaries. A code point of width 0
//! after the first one of a cluster does not move the pen: a combining
//! mark with an advance of 0 stays at the pen (fonts draw such marks to
//! the left of the origin), a mark with an advance is centered on the
//! base, and ZWJ and the variation selectors get no glyph. The layout has
//! no ligatures and no right-to-left text.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const num = @import("../base/num.zig");
const font_mod = @import("font.zig");
const Font = font_mod.Font;
const Fonts = font_mod.Fonts;
const seg = @import("ztcl").text;

/// Device pixels from the line origin.
pub const Glyph = @import("system.zig").Glyph;

pub const Run = struct {
    font: *Font,
    glyphs: []Glyph,
    /// Logical pixels, rounded up.
    width: i32,
    /// The end of the last advance, in device pixels.
    end_x: f32,

    pub fn deinit(r: *Run, gpa: std.mem.Allocator) void {
        gpa.free(r.glyphs);
        r.glyphs = &.{};
    }

    fn logical(r: *const Run, dev: f32) i32 {
        return num.pxRound(dev / r.font.scale);
    }

    /// The x position of the caret before byte `index`, in logical pixels.
    pub fn caretX(r: *const Run, text: []const u8, index: usize) i32 {
        _ = text;
        for (r.glyphs) |g| if (g.cluster >= index) return r.logical(g.x);
        return r.logical(r.end_x);
    }

    /// The byte index of the caret stop nearest to x.
    pub fn indexAt(r: *const Run, text: []const u8, x: i32) usize {
        var best: usize = text.len;
        var best_d: f32 = @abs(r.end_x / r.font.scale - @as(f32, @floatFromInt(x)));
        for (r.glyphs) |g| {
            const d = @abs(g.x / r.font.scale - @as(f32, @floatFromInt(x)));
            if (d < best_d) {
                best_d = d;
                best = g.cluster;
            }
        }
        return best;
    }
};

const Decoded = struct { cp: u21, len: u3, valid: bool };

fn decode(text: []const u8, i: usize) Decoded {
    const len = std.unicode.utf8ByteSequenceLength(text[i]) catch return .{ .cp = 0, .len = 1, .valid = false };
    if (i + len > text.len) return .{ .cp = 0, .len = 1, .valid = false };
    const cp = std.unicode.utf8Decode(text[i..][0..len]) catch return .{ .cp = 0, .len = 1, .valid = false };
    return .{ .cp = cp, .len = @intCast(len), .valid = true };
}

fn ceilWidth(dev: f32, scale: f32) i32 {
    return num.pxCeil(dev / scale - 1e-3);
}

pub fn shape(gpa: std.mem.Allocator, font: *Font, text: []const u8) !Run {
    var glyphs: std.ArrayListUnmanaged(Glyph) = .empty;
    errdefer glyphs.deinit(gpa);
    // A font of the system with a shaper of the system.
    if (font.system) |s| if (s.vtable.shape) |f| {
        const end = try f(s.ctx, gpa, font.sys_face, font.size * font.scale, text, &glyphs);
        const owned = try glyphs.toOwnedSlice(gpa);
        return .{ .font = font, .glyphs = owned, .width = ceilWidth(end, font.scale), .end_x = end };
    };
    try glyphs.ensureTotalCapacityPrecise(gpa, text.len);
    const pen = try layout(font, text, gpa, &glyphs);
    const owned = try glyphs.toOwnedSlice(gpa);
    return .{ .font = font, .glyphs = owned, .width = ceilWidth(pen, font.scale), .end_x = pen };
}

/// True for a code point that has no glyph inside a cluster: ZWJ and the
/// variation selectors.
fn invisible(cp: u21) bool {
    return cp == 0x200D or (cp >= 0xFE00 and cp <= 0xFE0F) or (cp >= 0xE0100 and cp <= 0xE01EF);
}

/// Places the glyphs of `text` with the built-in faces, by clusters, and
/// gives the end of the pen. With no list, it only measures.
fn layout(font: *Font, text: []const u8, gpa: std.mem.Allocator, out: ?*std.ArrayListUnmanaged(Glyph)) !f32 {
    const us = font.unitScale();
    var pen: f32 = 0;
    var prev: ?u16 = null;
    var i: usize = 0;
    while (i < text.len) {
        const end = seg.graphemeEnd(text, i);
        const at = std.math.cast(u32, i) orelse std.math.maxInt(u32);
        var base_x = pen;
        var base_adv: f32 = 0;
        var j = i;
        while (j < end) {
            const d = decode(text, j);
            const gid: u16 = if (d.valid) font.glyph(d.cp) else 0;
            const adv = @as(f32, @floatFromInt(font.advance(gid))) * us;
            if (j > i and d.valid and seg.props(d.cp).width == 0) {
                if (!invisible(d.cp)) {
                    const x = if (adv == 0) pen else base_x + (base_adv - adv) / 2;
                    if (out) |o| try o.append(gpa, .{ .id = gid, .x = x, .y = 0, .cluster = at });
                }
            } else {
                if (prev) |p| pen += @as(f32, @floatFromInt(font.kern(p, gid))) * us;
                base_x = pen;
                base_adv = adv;
                if (out) |o| try o.append(gpa, .{ .id = gid, .x = pen, .y = 0, .cluster = at });
                pen += adv;
                prev = gid;
            }
            j += d.len;
        }
        i = end;
    }
    return pen;
}

/// The width of a line in logical pixels. The result is cached.
pub fn measure(fonts: *Fonts, font: *Font, text: []const u8) i32 {
    if (text.len == 0) return 0;
    var stack: [256]u8 = undefined;
    const gpa = fonts.gpa;
    const key_len = 8 + text.len;
    const heap = if (key_len > stack.len) gpa.alloc(u8, key_len) catch return computeWidth(gpa, font, text) else null;
    defer if (heap) |h| gpa.free(h);
    const key = if (heap) |h| h else stack[0..key_len];
    std.mem.writeInt(u64, key[0..8], @intFromPtr(font), .little);
    @memcpy(key[8..], text);
    if (fonts.widths.get(key)) |w| return w;
    const w = computeWidth(gpa, font, text);
    if (fonts.widths.count() >= 4096) fonts.clearWidths();
    const owned = gpa.dupe(u8, key) catch return w;
    fonts.widths.put(gpa, owned, w) catch gpa.free(owned);
    return w;
}

fn computeWidth(gpa: std.mem.Allocator, font: *Font, text: []const u8) i32 {
    if (font.system) |s| if (s.vtable.shape != null) {
        var run = shape(gpa, font, text) catch return 0;
        defer run.deinit(gpa);
        return run.width;
    };
    const pen = layout(font, text, gpa, null) catch return 0;
    return ceilWidth(pen, font.scale);
}
