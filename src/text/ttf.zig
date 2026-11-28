//! The TrueType font parser. It reads these tables:
//! head, hhea, maxp, hmtx, name, cmap (formats 4 and 12), loca, glyf
//! (simple and composite glyphs), and the pair adjustment lookups of the
//! `kern` feature in GPOS (formats 1 and 2, also inside extension
//! lookups), and the mark-to-base and mark-to-mark lookups of GPOS
//! (format 1, at most 16 subtables). All numbers in the file are big-endian. Each read checks
//! its offset against the length of the data, so a bad or cut font
//! gives `error.BadFont` and never a read outside the data. The limits
//! are 16 384 points for one glyph, 64 kerning subtables, and 8 levels
//! of composite glyphs. A font with CFF outlines or variation tables
//! gives `error.Unsupported`.
//! The source is the OpenType specification (see docs/references/rendering.md).
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

pub const Point = struct { x: f32, y: f32, on_curve: bool };

pub const Outline = struct {
    points: []const Point,
    /// The index of the last point of each contour.
    contour_ends: []const u16,

    pub fn deinit(o: Outline, gpa: std.mem.Allocator) void {
        gpa.free(o.points);
        gpa.free(o.contour_ends);
    }
};

const max_points = 16384;
const max_kern = 64;
const max_depth = 8;
const max_components = 64;
/// The most steps of the walk over the GPOS lists. Three nested counts of
/// 16 bits are a font input, so the walk needs a limit of its own.
const max_kern_steps = 1 << 16;

const Err = error{BadFont};
const GlyphError = error{ BadFont, OutOfMemory };

fn be16(d: []const u8, o: usize) Err!u16 {
    if (o > d.len or d.len - o < 2) return error.BadFont;
    return std.mem.readInt(u16, d[o..][0..2], .big);
}

fn be16s(d: []const u8, o: usize) Err!i16 {
    return @bitCast(try be16(d, o));
}

fn be32(d: []const u8, o: usize) Err!u32 {
    if (o > d.len or d.len - o < 4) return error.BadFont;
    return std.mem.readInt(u32, d[o..][0..4], .big);
}

fn u8at(d: []const u8, o: usize) Err!u8 {
    if (o >= d.len) return error.BadFont;
    return d[o];
}

// ---- composite glyph records ----

const comp_words: u16 = 0x0001;
const comp_xy_values: u16 = 0x0002;
const comp_round_xy: u16 = 0x0004;
const comp_one_scale: u16 = 0x0008;
const comp_more: u16 = 0x0020;
const comp_xy_scale: u16 = 0x0040;
const comp_two_by_two: u16 = 0x0080;
const comp_scaled_offset: u16 = 0x0800;
const comp_unscaled_offset: u16 = 0x1000;

/// A 2 by 2 matrix. A point (x, y) goes to (xx * x + yx * y, xy * x + yy * y).
const Matrix = struct {
    xx: f32 = 1,
    xy: f32 = 0,
    yx: f32 = 0,
    yy: f32 = 1,

    fn applyVector(m: Matrix, v: [2]f32) [2]f32 {
        return .{ m.xx * v[0] + m.yx * v[1], m.xy * v[0] + m.yy * v[1] };
    }

    fn apply(m: Matrix, p: Point) Point {
        const v = m.applyVector(.{ p.x, p.y });
        return .{ .x = v[0], .y = v[1], .on_curve = p.on_curve };
    }
};

/// One component record.
const Component = struct {
    flags: u16,
    glyph: u16,
    arg1: i32,
    arg2: i32,
    map: Matrix,
};

// ---- simple glyph flags (OpenType, glyf table) ----

const flag_on_curve: u8 = 0x01;
const flag_x_short: u8 = 0x02;
const flag_y_short: u8 = 0x04;
const flag_repeat: u8 = 0x08;
const flag_x_same_or_positive: u8 = 0x10;
const flag_y_same_or_positive: u8 = 0x20;

/// Expands the run-length coded flags into `out`. A repeat count says how
/// many more points have the flag. A run past the last point is an error.
/// Returns the offset of the byte after the flags.
fn expandFlags(d: []const u8, first: usize, out: []u8) Err!usize {
    var at = first;
    var filled: usize = 0;
    while (filled < out.len) {
        const flag = try u8at(d, at);
        at += 1;
        var run: usize = 1;
        if (flag & flag_repeat != 0) {
            run += try u8at(d, at);
            at += 1;
        }
        if (run > out.len - filled) return error.BadFont;
        @memset(out[filled..][0..run], flag);
        filled += run;
    }
    return at;
}

/// One coordinate axis of a simple glyph: its two flag bits.
const Axis = struct { short: u8, same_or_positive: u8 };

/// Reads one delta of a coordinate. Returns the delta and moves `at`.
fn readDelta(d: []const u8, at: *usize, flag: u8, axis: Axis) Err!i32 {
    const marked = flag & axis.same_or_positive != 0;
    if (flag & axis.short != 0) {
        const size: i32 = try u8at(d, at.*);
        at.* += 1;
        return if (marked) size else -size;
    }
    if (marked) return 0;
    const delta = try be16s(d, at.*);
    at.* += 2;
    return delta;
}

// ---- cmap format 4 (OpenType, cmap table) ----

/// The parallel arrays of a format 4 subtable.
const SegmentMap = struct {
    table: []const u8,
    segments: usize,

    const end_codes = 14;

    fn of(table: []const u8) Err!SegmentMap {
        return .{ .table = table, .segments = (try be16(table, 6)) / 2 };
    }

    fn endCode(m: SegmentMap, i: usize) Err!u16 {
        return be16(m.table, end_codes + 2 * i);
    }

    fn startCode(m: SegmentMap, i: usize) Err!u16 {
        // A reserved word follows the array of end codes.
        return be16(m.table, end_codes + 2 * m.segments + 2 + 2 * i);
    }

    fn idDelta(m: SegmentMap, i: usize) Err!u16 {
        return be16(m.table, end_codes + 4 * m.segments + 2 + 2 * i);
    }

    /// The position of the idRangeOffset word of a segment.
    fn rangeWord(m: SegmentMap, i: usize) usize {
        return end_codes + 6 * m.segments + 2 + 2 * i;
    }

    /// The first segment whose end code is at least `code`.
    fn segmentOf(m: SegmentMap, code: u16) Err!?usize {
        var low: usize = 0;
        var count = m.segments;
        while (count > 0) {
            const half = count / 2;
            if ((try m.endCode(low + half)) < code) {
                low += half + 1;
                count -= half + 1;
            } else count = half;
        }
        return if (low < m.segments) low else null;
    }

    /// The glyph of a character code. All sums are modulo 65536.
    fn glyph(m: SegmentMap, code: u16) Err!u16 {
        const seg = (try m.segmentOf(code)) orelse return 0;
        const first = try m.startCode(seg);
        if (code < first) return 0;
        const delta = try m.idDelta(seg);
        const word = m.rangeWord(seg);
        const range = try be16(m.table, word);
        if (range == 0) return code +% delta;
        // The offset counts from the idRangeOffset word itself.
        const stored = try be16(m.table, word + range + 2 * @as(usize, code - first));
        return if (stored == 0) 0 else stored +% delta;
    }
};

/// A read position in the glyph data. Each read checks the length.
const Cursor = struct {
    d: []const u8,
    pos: usize,

    fn take16(c: *Cursor) Err!u16 {
        const v = try be16(c.d, c.pos);
        c.pos += 2;
        return v;
    }

    fn takeF2dot14(c: *Cursor) Err!f32 {
        const v: i16 = @bitCast(try c.take16());
        return @as(f32, @floatFromInt(v)) / 16384.0;
    }

    fn component(c: *Cursor) Err!Component {
        const flags = try c.take16();
        const glyph = try c.take16();
        var a1: i32 = undefined;
        var a2: i32 = undefined;
        const signed = flags & comp_xy_values != 0;
        if (flags & comp_words != 0) {
            const x = try c.take16();
            const y = try c.take16();
            a1 = if (signed) @as(i32, @as(i16, @bitCast(x))) else @as(i32, x);
            a2 = if (signed) @as(i32, @as(i16, @bitCast(y))) else @as(i32, y);
        } else {
            const x = try u8at(c.d, c.pos);
            const y = try u8at(c.d, c.pos + 1);
            c.pos += 2;
            a1 = if (signed) @as(i32, @as(i8, @bitCast(x))) else @as(i32, x);
            a2 = if (signed) @as(i32, @as(i8, @bitCast(y))) else @as(i32, y);
        }
        var m: Matrix = .{};
        if (flags & comp_one_scale != 0) {
            const s = try c.takeF2dot14();
            m = .{ .xx = s, .yy = s };
        } else if (flags & comp_xy_scale != 0) {
            m.xx = try c.takeF2dot14();
            m.yy = try c.takeF2dot14();
        } else if (flags & comp_two_by_two != 0) {
            m.xx = try c.takeF2dot14();
            m.xy = try c.takeF2dot14();
            m.yx = try c.takeF2dot14();
            m.yy = try c.takeF2dot14();
        }
        return .{ .flags = flags, .glyph = glyph, .arg1 = a1, .arg2 = a2, .map = m };
    }
};

const KernSub = struct { off: u32, lookup: u16 };

/// The point with a number: a real point, or one of the four phantom
/// points that follow the real points. A phantom point of a component
/// gets the transform of the component.
fn pointOrPhantom(real: []const Point, phantoms: *const [4]Point, number: usize, map: Matrix) Err!Point {
    if (number < real.len) return real[number];
    const extra = number - real.len;
    if (extra >= phantoms.len) return error.BadFont;
    return map.apply(phantoms[extra]);
}

pub const Face = struct {
    data: []const u8,
    units_per_em: u16,
    ascent: i16,
    descent: i16,
    line_gap: i16,
    glyph_count: u16,
    num_hmetrics: u16,
    loca_long: bool,
    hmtx: []const u8,
    loca: []const u8,
    glyf: []const u8,
    cmap: []const u8,
    cmap_format: u16,
    gpos: []const u8,
    kern: [max_kern]KernSub = undefined,
    kern_count: u8 = 0,
    marks: [max_marks]MarkSub = undefined,
    mark_count: u8 = 0,
    family_buf: [64]u8 = undefined,
    family_len: u8 = 0,

    fn table(data: []const u8, tag: *const [4]u8) Err!?[]const u8 {
        const n = try be16(data, 4);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const rec = 12 + i * 16;
            if (rec + 16 > data.len) return error.BadFont;
            if (std.mem.eql(u8, data[rec..][0..4], tag)) {
                const off = try be32(data, rec + 8);
                const len = try be32(data, rec + 12);
                if (@as(u64, off) + len > data.len) return error.BadFont;
                return data[off..][0..len];
            }
        }
        return null;
    }

    /// Reads the tables. `data` must stay valid as long as the Face.
    pub fn init(data: []const u8) error{ BadFont, Unsupported }!Face {
        if (data.len < 12) return error.BadFont;
        const version = try be32(data, 0);
        if (version == 0x4f54544f or version == 0x74746366) return error.Unsupported; // OTTO, ttcf
        if (version != 0x00010000 and version != 0x74727565) return error.BadFont;
        if ((try table(data, "fvar")) != null) return error.Unsupported;
        const head = (try table(data, "head")) orelse return error.BadFont;
        const hhea = (try table(data, "hhea")) orelse return error.BadFont;
        const maxp = (try table(data, "maxp")) orelse return error.BadFont;
        const hmtx = (try table(data, "hmtx")) orelse return error.BadFont;
        const cmap = (try table(data, "cmap")) orelse return error.BadFont;
        const loca = (try table(data, "loca")) orelse return error.BadFont;
        const glyf = (try table(data, "glyf")) orelse {
            if ((try table(data, "CFF ")) != null) return error.Unsupported;
            return error.BadFont;
        };
        var f: Face = .{
            .data = data,
            .units_per_em = try be16(head, 18),
            .ascent = try be16s(hhea, 4),
            .descent = try be16s(hhea, 6),
            .line_gap = try be16s(hhea, 8),
            .glyph_count = try be16(maxp, 4),
            .num_hmetrics = try be16(hhea, 34),
            .loca_long = (try be16s(head, 50)) != 0,
            .hmtx = hmtx,
            .loca = loca,
            .glyf = glyf,
            .cmap = &.{},
            .cmap_format = 0,
            .gpos = &.{},
        };
        if (f.units_per_em < 16 or f.units_per_em > 16384) return error.BadFont;
        if (f.num_hmetrics == 0 or @as(usize, f.num_hmetrics) * 4 > hmtx.len) return error.BadFont;
        const loca_entries = @as(usize, f.glyph_count) + 1;
        if (loca_entries * (if (f.loca_long) @as(usize, 4) else 2) > loca.len) return error.BadFont;
        try f.chooseCmap(cmap);
        if (try table(data, "GPOS")) |g| {
            f.gpos = g;
            f.findKern() catch {
                // A bad GPOS table means no kerning, not a bad font.
                f.kern_count = 0;
            };
            f.findMarks() catch {
                // The marks then get the centered place.
                f.mark_count = 0;
            };
        }
        if (try table(data, "name")) |n| f.readFamily(n) catch {
            f.family_len = 0;
        };
        return f;
    }

    fn chooseCmap(f: *Face, cmap: []const u8) Err!void {
        const n = try be16(cmap, 2);
        var best: u8 = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const rec = 4 + i * 8;
            const platform = try be16(cmap, rec);
            const encoding = try be16(cmap, rec + 2);
            const off = try be32(cmap, rec + 4);
            const format = be16(cmap, off) catch continue;
            const score: u8 = if (format == 12 and platform == 3 and encoding == 10) 4 else if (format == 12 and platform == 0) 3 else if (format == 4 and platform == 3 and encoding == 1) 2 else if (format == 4 and platform == 0) 1 else 0;
            if (score > best) {
                best = score;
                f.cmap = cmap[off..];
                f.cmap_format = format;
            }
        }
        if (best == 0) return error.BadFont;
    }

    /// The glyph of a code point, or 0.
    pub fn glyphIndex(f: *const Face, codepoint: u21) u16 {
        const g = f.lookupGlyph(codepoint) catch return 0;
        return if (g >= f.glyph_count) 0 else @intCast(g);
    }

    /// The glyph id of the table. A format 12 id can be above 65535.
    fn lookupGlyph(f: *const Face, cp: u21) Err!u32 {
        const c = f.cmap;
        if (f.cmap_format == 12) {
            const groups = try be32(c, 12);
            var lo: usize = 0;
            var hi: usize = groups;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const rec = 16 + mid * 12;
                const start = try be32(c, rec);
                const end = try be32(c, rec + 4);
                if (cp < start) {
                    hi = mid;
                } else if (cp > end) {
                    lo = mid + 1;
                } else {
                    const g: u64 = try be32(c, rec + 8);
                    return std.math.cast(u32, g + (cp - start)) orelse 0;
                }
            }
            return 0;
        }
        const code = std.math.cast(u16, cp) orelse return 0;
        return try (try SegmentMap.of(c)).glyph(code);
    }

    pub fn advance(f: *const Face, glyph: u16) u16 {
        const i: usize = if (glyph < f.num_hmetrics) glyph else f.num_hmetrics - 1;
        return be16(f.hmtx, i * 4) catch 0;
    }

    // ---- GPOS mark attachment ----

    /// The most mark subtables that a face keeps.
    const max_marks = 16;

    /// A mark-to-base subtable (lookup type 4) or a mark-to-mark
    /// subtable (lookup type 6), by its offset in GPOS.
    const MarkSub = struct { off: u32, to_mark: bool };

    /// Collects the mark subtables of each lookup, also inside extension
    /// lookups. Fonts use these lookup types only for the features `mark`
    /// and `mkmk`, which apply to each script, so the walk reads no
    /// script list and no feature list.
    fn findMarks(f: *Face) Err!void {
        const g = f.gpos;
        const lookup_list: usize = try be16(g, 8);
        const count = try be16(g, lookup_list);
        var steps: u32 = 0;
        var li: usize = 0;
        while (li < count) : (li += 1) {
            try countStep(&steps);
            const lo: usize = lookup_list + try be16(g, lookup_list + 2 + li * 2);
            const ltype = try be16(g, lo);
            const nsub = try be16(g, lo + 4);
            var k: usize = 0;
            while (k < nsub) : (k += 1) {
                try countStep(&steps);
                var sub: usize = lo + try be16(g, lo + 6 + k * 2);
                var t = ltype;
                if (t == 9) {
                    t = try be16(g, sub + 2);
                    sub += try be32(g, sub + 4);
                }
                if (t != 4 and t != 6) continue;
                if (try be16(g, sub) != 1) continue;
                if (f.mark_count == max_marks) return;
                f.marks[f.mark_count] = .{ .off = std.math.cast(u32, sub) orelse return error.BadFont, .to_mark = t == 6 };
                f.mark_count += 1;
            }
        }
    }

    /// The x and y of an anchor table, in font units.
    fn anchorAt(g: []const u8, off: usize) Err![2]i32 {
        return .{ try be16s(g, off + 2), try be16s(g, off + 4) };
    }

    /// The offset of one subtable for the pair, or null. The two lookup
    /// types have one layout: the coverage of the mark, the coverage of
    /// the base, the count of mark classes, the array of the marks (a
    /// class and an anchor each), and the array of the bases (one anchor
    /// for each class).
    fn markAdjust(g: []const u8, sub: usize, base: u16, mark: u16) Err!?[2]i32 {
        const mi = (try coverageIndex(g, sub + try be16(g, sub + 2), mark)) orelse return null;
        const bi = (try coverageIndex(g, sub + try be16(g, sub + 4), base)) orelse return null;
        const classes: usize = try be16(g, sub + 6);
        const mark_array: usize = sub + try be16(g, sub + 8);
        const base_array: usize = sub + try be16(g, sub + 10);
        if (mi >= try be16(g, mark_array) or bi >= try be16(g, base_array)) return error.BadFont;
        const class: usize = try be16(g, mark_array + 2 + mi * 4);
        if (class >= classes) return error.BadFont;
        const mark_anchor = try anchorAt(g, mark_array + try be16(g, mark_array + 4 + mi * 4));
        const base_off: usize = try be16(g, base_array + 2 + (bi * classes + class) * 2);
        // A base with no anchor for this class.
        if (base_off == 0) return null;
        const base_anchor = try anchorAt(g, base_array + base_off);
        return .{ base_anchor[0] - mark_anchor[0], base_anchor[1] - mark_anchor[1] };
    }

    /// The place of the origin of the glyph `mark` from the origin of the
    /// glyph `base`, in font units with y up, from the anchors of GPOS:
    /// the anchor of the mark goes on the anchor of the base. With
    /// `to_mark`, `base` is a mark too (a mark on a mark). Null when the
    /// face has no anchors for the pair.
    pub fn markOffset(f: *const Face, base: u16, mark: u16, to_mark: bool) ?[2]i32 {
        for (f.marks[0..f.mark_count]) |ms| {
            if (ms.to_mark != to_mark) continue;
            const r = markAdjust(f.gpos, ms.off, base, mark) catch continue;
            if (r) |v| return v;
        }
        return null;
    }

    // ---- GPOS kerning ----

    fn findKern(f: *Face) Err!void {
        const g = f.gpos;
        // Each offset is a usize, so a sum of two offsets of the file cannot overflow.
        const script_list: usize = try be16(g, 4);
        const feature_list: usize = try be16(g, 6);
        const lookup_list: usize = try be16(g, 8);
        // Collect the lookup indexes of the kern features of the DFLT and latn scripts.
        var lookups: [max_kern]u16 = undefined;
        var nl: usize = 0;
        var steps: u32 = 0;
        const nscripts = try be16(g, script_list);
        var si: usize = 0;
        while (si < nscripts) : (si += 1) {
            try countStep(&steps);
            const rec = script_list + 2 + si * 6;
            if (rec + 6 > g.len) return error.BadFont;
            const tag = g[rec..][0..4];
            if (!std.mem.eql(u8, tag, "DFLT") and !std.mem.eql(u8, tag, "latn")) continue;
            const script: usize = script_list + try be16(g, rec + 4);
            const lang_off: usize = try be16(g, script);
            if (lang_off == 0) continue;
            const lang: usize = script + lang_off;
            const req = try be16(g, lang + 2);
            const nfeat = try be16(g, lang + 4);
            var fi: usize = 0;
            while (fi < @as(usize, nfeat) + 1) : (fi += 1) {
                try countStep(&steps);
                const idx: u16 = if (fi == nfeat) req else try be16(g, lang + 6 + fi * 2);
                if (idx == 0xffff) continue;
                const frec = feature_list + 2 + @as(usize, idx) * 6;
                if (frec + 6 > g.len) return error.BadFont;
                if (!std.mem.eql(u8, g[frec..][0..4], "kern")) continue;
                const feat: usize = feature_list + try be16(g, frec + 4);
                const nli = try be16(g, feat + 2);
                var li: usize = 0;
                while (li < nli) : (li += 1) {
                    try countStep(&steps);
                    const lidx = try be16(g, feat + 4 + li * 2);
                    var dup = false;
                    for (lookups[0..nl]) |x| if (x == lidx) {
                        dup = true;
                    };
                    if (!dup and nl < lookups.len) {
                        lookups[nl] = lidx;
                        nl += 1;
                    }
                }
            }
        }
        std.mem.sort(u16, lookups[0..nl], {}, std.sort.asc(u16));
        for (lookups[0..nl]) |lidx| {
            const lo: usize = lookup_list + try be16(g, lookup_list + 2 + @as(usize, lidx) * 2);
            const ltype = try be16(g, lo);
            const nsub = try be16(g, lo + 4);
            var k: usize = 0;
            while (k < nsub) : (k += 1) {
                try countStep(&steps);
                var sub: usize = lo + try be16(g, lo + 6 + k * 2);
                var t = ltype;
                if (t == 9) {
                    t = try be16(g, sub + 2);
                    sub += try be32(g, sub + 4);
                }
                if (t != 2) continue;
                if (f.kern_count == max_kern) return;
                f.kern[f.kern_count] = .{ .off = std.math.cast(u32, sub) orelse return error.BadFont, .lookup = lidx };
                f.kern_count += 1;
            }
        }
    }

    fn countStep(steps: *u32) Err!void {
        steps.* += 1;
        if (steps.* > max_kern_steps) return error.BadFont;
    }

    fn coverageIndex(g: []const u8, off: usize, glyph: u16) Err!?usize {
        const format = try be16(g, off);
        const count = try be16(g, off + 2);
        if (format == 1) {
            var lo: usize = 0;
            var hi: usize = count;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const v = try be16(g, off + 4 + mid * 2);
                if (v == glyph) return mid;
                if (v < glyph) lo = mid + 1 else hi = mid;
            }
            return null;
        }
        if (format == 2) {
            var lo: usize = 0;
            var hi: usize = count;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const rec = off + 4 + mid * 6;
                const start = try be16(g, rec);
                const end = try be16(g, rec + 2);
                if (glyph < start) {
                    hi = mid;
                } else if (glyph > end) {
                    lo = mid + 1;
                } else return @as(usize, try be16(g, rec + 4)) + (glyph - start);
            }
            return null;
        }
        return error.BadFont;
    }

    fn classOf(g: []const u8, off: usize, glyph: u16) Err!u16 {
        const format = try be16(g, off);
        if (format == 1) {
            const start = try be16(g, off + 2);
            const count = try be16(g, off + 4);
            if (glyph < start or glyph - start >= count) return 0;
            return be16(g, off + 6 + @as(usize, glyph - start) * 2);
        }
        if (format == 2) {
            const count = try be16(g, off + 2);
            var lo: usize = 0;
            var hi: usize = count;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const rec = off + 4 + mid * 6;
                const start = try be16(g, rec);
                const end = try be16(g, rec + 2);
                if (glyph < start) {
                    hi = mid;
                } else if (glyph > end) {
                    lo = mid + 1;
                } else return be16(g, rec + 4);
            }
            return 0;
        }
        return error.BadFont;
    }

    fn valueSize(fmt: u16) usize {
        return @as(usize, @popCount(fmt)) * 2;
    }

    /// The x advance in a value record, or 0.
    fn xAdvance(g: []const u8, off: usize, fmt: u16) Err!i16 {
        if (fmt & 4 == 0) return 0;
        const idx = @popCount(fmt & 3);
        return be16s(g, off + @as(usize, idx) * 2);
    }

    /// The result of one pair subtable: null when it does not match the pair.
    fn pairAdjust(g: []const u8, sub: usize, left: u16, right: u16) Err!?i16 {
        const format = try be16(g, sub);
        const cov = sub + try be16(g, sub + 2);
        const idx = (try coverageIndex(g, cov, left)) orelse return null;
        const fmt1 = try be16(g, sub + 4);
        const fmt2 = try be16(g, sub + 6);
        const s1 = valueSize(fmt1);
        const s2 = valueSize(fmt2);
        if (format == 1) {
            const npairs = try be16(g, sub + 8);
            if (idx >= npairs) return error.BadFont;
            const set = sub + try be16(g, sub + 10 + idx * 2);
            const count = try be16(g, set);
            const rec_size = 2 + s1 + s2;
            var lo: usize = 0;
            var hi: usize = count;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const rec = set + 2 + mid * rec_size;
                const second = try be16(g, rec);
                if (second == right) return try xAdvance(g, rec + 2, fmt1);
                if (second < right) lo = mid + 1 else hi = mid;
            }
            return null;
        }
        if (format == 2) {
            const cd1 = sub + try be16(g, sub + 8);
            const cd2 = sub + try be16(g, sub + 10);
            const n1 = try be16(g, sub + 12);
            const n2 = try be16(g, sub + 14);
            const c1 = try classOf(g, cd1, left);
            const c2 = try classOf(g, cd2, right);
            if (c1 >= n1 or c2 >= n2) return error.BadFont;
            const rec = sub + 16 + (@as(usize, c1) * n2 + c2) * (s1 + s2);
            return try xAdvance(g, rec, fmt1);
        }
        return error.BadFont;
    }

    /// The kerning between two glyphs, from the GPOS table. In each lookup
    /// the first subtable that matches the pair decides. The lookups add.
    pub fn kerning(f: *const Face, left: u16, right: u16) i16 {
        var total: i32 = 0;
        var done_lookup: ?u16 = null;
        for (f.kern[0..f.kern_count]) |ks| {
            if (done_lookup != null and done_lookup.? == ks.lookup) continue;
            const r = pairAdjust(f.gpos, ks.off, left, right) catch continue;
            if (r) |v| {
                total += v;
                done_lookup = ks.lookup;
            }
        }
        return @intCast(std.math.clamp(total, std.math.minInt(i16), std.math.maxInt(i16)));
    }

    // ---- outlines ----

    pub fn glyphData(f: *const Face, glyph: u16) Err![]const u8 {
        if (glyph >= f.glyph_count) return error.BadFont;
        const a: usize, const b: usize = if (f.loca_long)
            .{ try be32(f.loca, @as(usize, glyph) * 4), try be32(f.loca, @as(usize, glyph) * 4 + 4) }
        else
            .{ @as(usize, try be16(f.loca, @as(usize, glyph) * 2)) * 2, @as(usize, try be16(f.loca, @as(usize, glyph) * 2 + 2)) * 2 };
        if (b < a) return error.BadFont;
        if (b > f.glyf.len) return error.BadFont;
        return f.glyf[a..b];
    }

    /// The outline of a glyph, with composite glyphs resolved.
    pub fn outline(f: *const Face, gpa: std.mem.Allocator, glyph: u16) !Outline {
        var pts: std.ArrayListUnmanaged(Point) = .empty;
        errdefer pts.deinit(gpa);
        var ends: std.ArrayListUnmanaged(u16) = .empty;
        errdefer ends.deinit(gpa);
        var budget: usize = max_components;
        try f.loadGlyph(gpa, glyph, 0, &pts, &ends, &budget);
        const p = try pts.toOwnedSlice(gpa);
        errdefer gpa.free(p);
        const e = try ends.toOwnedSlice(gpa);
        return .{ .points = p, .contour_ends = e };
    }

    fn loadGlyph(f: *const Face, gpa: std.mem.Allocator, glyph: u16, depth: u8, pts: *std.ArrayListUnmanaged(Point), ends: *std.ArrayListUnmanaged(u16), budget: *usize) GlyphError!void {
        const d = try f.glyphData(glyph);
        if (d.len == 0) return;
        const n = try be16s(d, 0);
        if (n >= 0) return f.loadSimple(gpa, d, @intCast(n), pts, ends);
        if (depth >= max_depth) return error.BadFont;
        return f.loadComposite(gpa, glyph, d, depth, pts, ends, budget);
    }

    /// The four phantom points of a glyph: the origin, the advance, the
    /// top, and the bottom. The horizontal pair comes from `hmtx` and the
    /// x minimum of the glyph header. This parser reads no `vmtx`, so the
    /// vertical pair is the ascent and the descent of `hhea`.
    fn phantomPoints(f: *const Face, glyph: u16, d: []const u8) [4]Point {
        const x_min: i32 = if (d.len >= 10) be16s(d, 2) catch 0 else 0;
        const metrics = @as(usize, f.num_hmetrics);
        const lsb_at = if (glyph < metrics) @as(usize, glyph) * 4 + 2 else metrics * 4 + (@as(usize, glyph) - metrics) * 2;
        const lsb: i32 = be16s(f.hmtx, lsb_at) catch 0;
        const origin = x_min - lsb;
        const advance_x = origin + f.advance(glyph);
        return .{
            .{ .x = @floatFromInt(origin), .y = 0, .on_curve = true },
            .{ .x = @floatFromInt(advance_x), .y = 0, .on_curve = true },
            .{ .x = 0, .y = @floatFromInt(f.ascent), .on_curve = true },
            .{ .x = 0, .y = @floatFromInt(f.descent), .on_curve = true },
        };
    }

    /// Adds the components of a composite glyph. The records start at byte 10
    /// of the glyph data. Each record has flags, a glyph index, two arguments,
    /// and an optional scale. The transform acts on the points of the component,
    /// and then the offset moves them (OpenType, glyf table, composite glyph description).
    fn loadComposite(f: *const Face, gpa: std.mem.Allocator, glyph: u16, d: []const u8, depth: u8, pts: *std.ArrayListUnmanaged(Point), ends: *std.ArrayListUnmanaged(u16), budget: *usize) GlyphError!void {
        const first_point = pts.items.len;
        var cur: Cursor = .{ .d = d, .pos = 10 };
        while (true) {
            if (budget.* == 0) return error.BadFont;
            budget.* -= 1;
            const rec = try cur.component();
            const start = pts.items.len;
            try f.loadGlyph(gpa, rec.glyph, depth + 1, pts, ends, budget);
            const added = pts.items[start..];
            for (added) |*p| p.* = rec.map.apply(p.*);
            var shift: [2]f32 = .{ 0, 0 };
            if (rec.flags & comp_xy_values != 0) {
                shift = .{ @floatFromInt(rec.arg1), @floatFromInt(rec.arg2) };
                // The offset follows the transform only when the font asks for it.
                if (rec.flags & comp_scaled_offset != 0 and rec.flags & comp_unscaled_offset == 0) {
                    shift = rec.map.applyVector(shift);
                }
                if (rec.flags & comp_round_xy != 0) shift = .{ @round(shift[0]), @round(shift[1]) };
            } else {
                // Two point numbers: the point of the glyph so far and the point
                // of the new component. The component moves so that they meet.
                // The numbers after the real points name the four phantom points.
                const base_points = pts.items[first_point..start];
                const base_phantoms = f.phantomPoints(glyph, d);
                const child_phantoms = f.phantomPoints(rec.glyph, try f.glyphData(rec.glyph));
                const base_number: usize = @intCast(rec.arg1);
                const child_number: usize = @intCast(rec.arg2);
                const anchor = try pointOrPhantom(base_points, &base_phantoms, base_number, .{});
                const moved = try pointOrPhantom(added, &child_phantoms, child_number, rec.map);
                shift = .{ anchor.x - moved.x, anchor.y - moved.y };
            }
            for (added) |*p| {
                p.x += shift[0];
                p.y += shift[1];
            }
            if (rec.flags & comp_more == 0) break;
        }
    }

    fn loadSimple(f: *const Face, gpa: std.mem.Allocator, d: []const u8, ncont: usize, pts: *std.ArrayListUnmanaged(Point), ends: *std.ArrayListUnmanaged(u16)) !void {
        _ = f;
        if (ncont == 0) return;
        const pos: usize = 10;
        const base: usize = pts.items.len;
        var prev_end: i32 = -1;
        var last: usize = 0;
        var i: usize = 0;
        while (i < ncont) : (i += 1) {
            const e = try be16(d, pos + i * 2);
            if (@as(i32, e) <= prev_end) return error.BadFont;
            prev_end = e;
            last = e;
        }
        const npts = last + 1;
        if (npts > max_points or base + npts > max_points) return error.BadFont;
        const ins_len = try be16(d, pos + ncont * 2);
        const flags = try gpa.alloc(u8, npts);
        defer gpa.free(flags);
        var at = try expandFlags(d, pos + ncont * 2 + 2 + ins_len, flags);
        try pts.ensureUnusedCapacity(gpa, npts);
        try ends.ensureUnusedCapacity(gpa, ncont);
        const start_len = pts.items.len;
        const x_axis: Axis = .{ .short = flag_x_short, .same_or_positive = flag_x_same_or_positive };
        const y_axis: Axis = .{ .short = flag_y_short, .same_or_positive = flag_y_same_or_positive };
        var x: i32 = 0;
        for (flags) |flag| {
            x += try readDelta(d, &at, flag, x_axis);
            pts.appendAssumeCapacity(.{ .x = @floatFromInt(x), .y = 0, .on_curve = flag & flag_on_curve != 0 });
        }
        var y: i32 = 0;
        for (flags, pts.items[start_len..]) |flag, *point| {
            y += try readDelta(d, &at, flag, y_axis);
            point.y = @floatFromInt(y);
        }
        i = 0;
        while (i < ncont) : (i += 1) {
            ends.appendAssumeCapacity(@intCast(base + try be16(d, pos + i * 2)));
        }
    }

    // ---- names ----

    fn readFamily(f: *Face, n: []const u8) Err!void {
        const count = try be16(n, 2);
        const str_off = try be16(n, 4);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const rec = 6 + i * 12;
            const platform = try be16(n, rec);
            const name_id = try be16(n, rec + 6);
            if (name_id != 1) continue;
            const len = try be16(n, rec + 8);
            const off = @as(usize, str_off) + try be16(n, rec + 10);
            if (off + len > n.len) return error.BadFont;
            const s = n[off..][0..len];
            var out: usize = 0;
            if (platform == 3 or platform == 0) {
                var j: usize = 0;
                while (j + 1 < s.len and out < f.family_buf.len) : (j += 2) {
                    f.family_buf[out] = if (s[j] == 0 and s[j + 1] < 0x80) s[j + 1] else '?';
                    out += 1;
                }
            } else {
                for (s) |c| {
                    if (out == f.family_buf.len) break;
                    f.family_buf[out] = c;
                    out += 1;
                }
            }
            f.family_len = @intCast(out);
            return;
        }
    }

    /// The family name from the name table.
    pub fn family(f: *const Face) []const u8 {
        return f.family_buf[0..f.family_len];
    }
};
