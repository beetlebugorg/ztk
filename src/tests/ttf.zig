//! Tests of the font parser on small fonts that this file builds byte by
//! byte from the OpenType specification. Each expected value is a number
//! that the test states, so no expected value comes from the parser.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ttf = @import("../text/ttf.zig");
const Watchdog = @import("../testing.zig").Watchdog;
const t = std.testing;
const gpa = t.allocator;

const Bytes = std.ArrayList(u8);

fn w16(b: *Bytes, v: u16) !void {
    try b.append(gpa, @intCast(v >> 8));
    try b.append(gpa, @intCast(v & 0xff));
}

fn wi16(b: *Bytes, v: i16) !void {
    try w16(b, @bitCast(v));
}

fn w32(b: *Bytes, v: u32) !void {
    try w16(b, @intCast(v >> 16));
    try w16(b, @intCast(v & 0xffff));
}

/// Expects `error.BadFont`. A result that has an outline is freed first:
/// the report of a leak in a Debug build takes minutes on this binary.
fn expectBadOutline(f: *const ttf.Face, glyph: u16) !void {
    if (f.outline(t.allocator, glyph)) |o| {
        o.deinit(t.allocator);
        return error.TestExpectedError;
    } else |e| try t.expectEqual(error.BadFont, e);
}

const Metric = struct { advance: u16, lsb: i16 };

/// A font of the given glyphs. The units per em are 1000, the ascent 800, and the descent -200.
fn buildFont(glyphs: []const []const u8, metrics: []const Metric, cmap: []const u8) ![]u8 {
    return buildFontGpos(glyphs, metrics, cmap, null);
}

fn buildFontGpos(glyphs: []const []const u8, metrics: []const Metric, cmap: []const u8, gpos: ?[]const u8) ![]u8 {
    var head: Bytes = .empty;
    defer head.deinit(gpa);
    try head.appendNTimes(gpa, 0, 54);
    head.items[18] = 0x03; // 1000 units per em
    head.items[19] = 0xe8;
    head.items[51] = 1; // long loca
    var hhea: Bytes = .empty;
    defer hhea.deinit(gpa);
    try hhea.appendNTimes(gpa, 0, 36);
    std.mem.writeInt(i16, hhea.items[4..6], 800, .big);
    std.mem.writeInt(i16, hhea.items[6..8], -200, .big);
    std.mem.writeInt(u16, hhea.items[34..36], @intCast(metrics.len), .big);
    var maxp: Bytes = .empty;
    defer maxp.deinit(gpa);
    try w32(&maxp, 0x00010000);
    try w16(&maxp, @intCast(glyphs.len));
    var hmtx: Bytes = .empty;
    defer hmtx.deinit(gpa);
    for (metrics) |m| {
        try w16(&hmtx, m.advance);
        try wi16(&hmtx, m.lsb);
    }
    var loca: Bytes = .empty;
    defer loca.deinit(gpa);
    var glyf: Bytes = .empty;
    defer glyf.deinit(gpa);
    for (glyphs) |g| {
        try w32(&loca, @intCast(glyf.items.len));
        try glyf.appendSlice(gpa, g);
    }
    try w32(&loca, @intCast(glyf.items.len));
    const tables = [_]struct { tag: *const [4]u8, data: []const u8 }{
        // A font without GPOS has an empty table with another tag in this slot.
        .{ .tag = if (gpos != null) "GPOS" else "zero", .data = gpos orelse &.{} },
        .{ .tag = "cmap", .data = cmap },
        .{ .tag = "glyf", .data = glyf.items },
        .{ .tag = "head", .data = head.items },
        .{ .tag = "hhea", .data = hhea.items },
        .{ .tag = "hmtx", .data = hmtx.items },
        .{ .tag = "loca", .data = loca.items },
        .{ .tag = "maxp", .data = maxp.items },
    };
    var out: Bytes = .empty;
    errdefer out.deinit(gpa);
    try w32(&out, 0x00010000);
    try w16(&out, tables.len);
    try out.appendNTimes(gpa, 0, 6);
    var at: u32 = 12 + 16 * tables.len;
    for (tables) |tb| {
        try out.appendSlice(gpa, tb.tag);
        try w32(&out, 0);
        try w32(&out, at);
        try w32(&out, @intCast(tb.data.len));
        at += @intCast(tb.data.len);
    }
    for (tables) |tb| try out.appendSlice(gpa, tb.data);
    return out.toOwnedSlice(gpa);
}

/// A cmap with one format 4 subtable of platform 3, encoding 1.
fn cmap4(segments: []const [4]u16, glyph_array: []const u16) ![]u8 {
    var b: Bytes = .empty;
    errdefer b.deinit(gpa);
    try w16(&b, 0);
    try w16(&b, 1);
    try w16(&b, 3);
    try w16(&b, 1);
    try w32(&b, 12);
    const n: u16 = @intCast(segments.len);
    try w16(&b, 4);
    try w16(&b, 16 + 8 * n + 2 * @as(u16, @intCast(glyph_array.len)));
    try w16(&b, 0);
    try w16(&b, n * 2);
    try w16(&b, 0);
    try w16(&b, 0);
    try w16(&b, 0);
    for (segments) |s| try w16(&b, s[1]); // end codes
    try w16(&b, 0);
    for (segments) |s| try w16(&b, s[0]); // start codes
    for (segments) |s| try w16(&b, s[2]); // deltas
    for (segments) |s| try w16(&b, s[3]); // range offsets
    for (glyph_array) |g| try w16(&b, g);
    return b.toOwnedSlice(gpa);
}

/// A cmap with one format 12 subtable of platform 3, encoding 10.
fn cmap12(groups: []const [3]u32) ![]u8 {
    var b: Bytes = .empty;
    errdefer b.deinit(gpa);
    try w16(&b, 0);
    try w16(&b, 1);
    try w16(&b, 3);
    try w16(&b, 10);
    try w32(&b, 12);
    try w16(&b, 12);
    try w16(&b, 0);
    try w32(&b, @intCast(16 + 12 * groups.len));
    try w32(&b, 0);
    try w32(&b, @intCast(groups.len));
    for (groups) |g| for (g) |v| try w32(&b, v);
    return b.toOwnedSlice(gpa);
}

/// A triangle: (100,0) on, (300,0) on, (200,400) off. The x minimum is 100.
const triangle = [_]u8{
    0, 1, 0, 100, 0, 0, 1, 44, 1, 144, // one contour, x 100 to 300, y 0 to 400
    0, 2, // the last point
    0, 0, // no instructions
    0x01, 0x01, 0x00, // flags: words
    0, 100, 0, 200, 0xff, 0x9c, // x deltas: 100, 200, -100
    0, 0, 0, 0, 1, 144, // y deltas: 0, 0, 400
};

fn composite(x_min: i16, records: []const u8) ![]u8 {
    var b: Bytes = .empty;
    errdefer b.deinit(gpa);
    try wi16(&b, -1);
    try wi16(&b, x_min);
    try b.appendNTimes(gpa, 0, 6);
    try b.appendSlice(gpa, records);
    return b.toOwnedSlice(gpa);
}

const plain_metrics = [_]Metric{ .{ .advance = 500, .lsb = 0 }, .{ .advance = 500, .lsb = 100 }, .{ .advance = 1000, .lsb = 0 } };

fn expectPoints(want: []const [2]f32, got: []const ttf.Point) !void {
    try t.expectEqual(want.len, got.len);
    for (want, got) |w, g| {
        try t.expectEqual(w[0], g.x);
        try t.expectEqual(w[1], g.y);
    }
}

fn fontWith(records: []const u8, x_min: i16) ![]u8 {
    const cm = try cmap4(&.{.{ 0xffff, 0xffff, 1, 0 }}, &.{});
    defer gpa.free(cm);
    const comp = try composite(x_min, records);
    defer gpa.free(comp);
    return buildFont(&.{ &.{}, &triangle, comp }, &plain_metrics, cm);
}

test "ttf build: a simple glyph has the exact points" {
    const data = try fontWith(&.{ 0, 0, 0, 1, 0, 0 }, 0);
    defer gpa.free(data);
    const f = try ttf.Face.init(data);
    const o = try f.outline(gpa, 1);
    defer o.deinit(gpa);
    try expectPoints(&.{ .{ 100, 0 }, .{ 300, 0 }, .{ 200, 400 } }, o.points);
    try t.expect(o.points[0].on_curve and o.points[1].on_curve and !o.points[2].on_curve);
    try t.expectEqualSlices(u16, &.{2}, o.contour_ends);
}

test "ttf build: a repeated flag and short deltas" {
    const glyph = [_]u8{
        0, 1, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 3, // four points
        0, 0,
        0x01 | 0x02 | 0x10 | 0x04 | 0x20 | 0x08, 3, // one flag, three more points
        10, 20, 30, 40, // x deltas
        1, 2, 3, 4, // y deltas
    };
    const cm = try cmap4(&.{.{ 0xffff, 0xffff, 1, 0 }}, &.{});
    defer gpa.free(cm);
    const data = try buildFont(&.{ &.{}, &glyph }, plain_metrics[0..2], cm);
    defer gpa.free(data);
    const f = try ttf.Face.init(data);
    const o = try f.outline(gpa, 1);
    defer o.deinit(gpa);
    try expectPoints(&.{ .{ 10, 1 }, .{ 30, 3 }, .{ 60, 6 }, .{ 100, 10 } }, o.points);
}

test "ttf build: a flag run past the last point is BadFont" {
    const glyph = [_]u8{ 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0x37 | 0x08, 200, 1, 1, 1, 1 };
    const cm = try cmap4(&.{.{ 0xffff, 0xffff, 1, 0 }}, &.{});
    defer gpa.free(cm);
    const data = try buildFont(&.{ &.{}, &glyph }, plain_metrics[0..2], cm);
    defer gpa.free(data);
    const f = try ttf.Face.init(data);
    try expectBadOutline(&f, 1);
}

test "ttf build: an offset in words, a scale, and an offset in bytes" {
    const records = [_]u8{
        0x00, 0x23, 0, 1, 0x01, 0x2c, 0xff, 0xce, // words, xy, more: glyph 1 at (300, -50)
        0x00, 0x0a, 0, 1, 10, 0xec, 0x20, 0x00, // bytes, xy, scale 0.5: glyph 1 at (10, -20)
    };
    const data = try fontWith(&records, 0);
    defer gpa.free(data);
    const f = try ttf.Face.init(data);
    const o = try f.outline(gpa, 2);
    defer o.deinit(gpa);
    try expectPoints(&.{ .{ 400, -50 }, .{ 600, -50 }, .{ 500, 350 }, .{ 60, -20 }, .{ 160, -20 }, .{ 110, 180 } }, o.points);
    try t.expectEqualSlices(u16, &.{ 2, 5 }, o.contour_ends);
}

test "ttf build: point matching counts the phantom points of the composite" {
    // Component 2: its point 0 goes to number 4, the advance point of the
    // composite after 3 real points. The advance point is at x = 0 - 0 + 1000.
    const records = [_]u8{ 0x00, 0x22, 0, 1, 0, 0, 0x00, 0x00, 0, 1, 4, 0 };
    const data = try fontWith(&records, 0);
    defer gpa.free(data);
    const f = try ttf.Face.init(data);
    const o = try f.outline(gpa, 2);
    defer o.deinit(gpa);
    try expectPoints(&.{ .{ 100, 0 }, .{ 300, 0 }, .{ 200, 400 }, .{ 1000, 0 }, .{ 1200, 0 }, .{ 1100, 400 } }, o.points);
}

test "ttf build: point matching counts the phantom points of the component" {
    // The advance point of glyph 1 is number 4: x = 100 - 100 + 500 = 500.
    // It goes to point 0 of the glyph so far, at x = 100, so the shift is -400.
    const records = [_]u8{ 0x00, 0x22, 0, 1, 0, 0, 0x00, 0x00, 0, 1, 0, 4 };
    const data = try fontWith(&records, 0);
    defer gpa.free(data);
    const f = try ttf.Face.init(data);
    const o = try f.outline(gpa, 2);
    defer o.deinit(gpa);
    try expectPoints(&.{ .{ 100, 0 }, .{ 300, 0 }, .{ 200, 400 }, .{ -300, 0 }, .{ -100, 0 }, .{ -200, 400 } }, o.points);
}

test "ttf build: a point number past the phantom points is BadFont" {
    for ([_][2]u8{ .{ 7, 0 }, .{ 0, 7 } }) |pair| {
        const records = [_]u8{ 0x00, 0x22, 0, 1, 0, 0, 0x00, 0x00, 0, 1, pair[0], pair[1] };
        const data = try fontWith(&records, 0);
        defer gpa.free(data);
        const f = try ttf.Face.init(data);
        try expectBadOutline(&f, 2);
    }
}

test "ttf build: a cut record and a glyph that contains itself fail quickly" {
    var dog: Watchdog = undefined;
    try dog.start(10_000);
    defer dog.stop();
    // The flag asks for one more record, and the data ends.
    const cut = [_]u8{ 0x00, 0x23, 0, 1, 0, 0, 0, 0 };
    const data = try fontWith(&cut, 0);
    defer gpa.free(data);
    const f = try ttf.Face.init(data);
    try expectBadOutline(&f, 2);
    // Glyph 2 names itself twice in each level.
    const cycle = [_]u8{ 0x00, 0x23, 0, 2, 0, 0, 0, 0, 0x00, 0x03, 0, 2, 0, 0, 0, 0 };
    const data2 = try fontWith(&cycle, 0);
    defer gpa.free(data2);
    const f2 = try ttf.Face.init(data2);
    try expectBadOutline(&f2, 2);
}

test "ttf build: cmap format 4 with a delta, a range, and an empty slot" {
    // The range offset of segment 1 is 4: the distance from its word to the
    // glyph array, across the words of segments 1 and 2.
    const cm = try cmap4(&.{
        .{ 0x41, 0x43, 0xffc0, 0 }, // A to C give 1 to 3
        .{ 0x61, 0x62, 1, 4 }, // a gives 5 + 1, b has glyph 0
        .{ 0xffff, 0xffff, 1, 0 },
    }, &.{ 5, 0 });
    defer gpa.free(cm);
    const glyphs: [8][]const u8 = @splat(&.{});
    const data = try buildFont(&glyphs, plain_metrics[0..1], cm);
    defer gpa.free(data);
    const f = try ttf.Face.init(data);
    try t.expectEqual(@as(u16, 1), f.glyphIndex('A'));
    try t.expectEqual(@as(u16, 3), f.glyphIndex('C'));
    try t.expectEqual(@as(u16, 0), f.glyphIndex('D'));
    try t.expectEqual(@as(u16, 6), f.glyphIndex('a'));
    try t.expectEqual(@as(u16, 0), f.glyphIndex('b'));
    try t.expectEqual(@as(u16, 0), f.glyphIndex(0x10041));
}

test "ttf build: cmap format 12 ids above 65535 give glyph 0" {
    const cm = try cmap12(&.{
        .{ 0x1f600, 0x1f601, 4 },
        .{ 0x20000, 0x20001, 0xffff },
        .{ 0x30000, 0x30000, 0x10003 },
    });
    defer gpa.free(cm);
    const glyphs: [8][]const u8 = @splat(&.{});
    const data = try buildFont(&glyphs, plain_metrics[0..1], cm);
    defer gpa.free(data);
    const f = try ttf.Face.init(data);
    try t.expectEqual(@as(u16, 4), f.glyphIndex(0x1f600));
    try t.expectEqual(@as(u16, 5), f.glyphIndex(0x1f601));
    // Id 65535 is past the glyph count. The next id is 65536, and a cut to 16 bits gives 0.
    try t.expectEqual(@as(u16, 0), f.glyphIndex(0x20000));
    try t.expectEqual(@as(u16, 0), f.glyphIndex(0x20001));
    // 0x10003 cut to 16 bits is the valid glyph 3.
    try t.expectEqual(@as(u16, 0), f.glyphIndex(0x30000));
}

test "ttf build: a GPOS with huge nested counts ends quickly and has no kerning" {
    var dog: Watchdog = undefined;
    try dog.start(10_000);
    defer dog.stop();
    // 4000 scripts share one language system. It lists 4000 features, and
    // each is one kern feature that lists 4000 lookups: 6.4e10 steps with no limit.
    const n: u16 = 4000;
    var g: Bytes = .empty;
    defer g.deinit(gpa);
    const script_list: u16 = 10;
    const script_table: u16 = 2 + 6 * n;
    const lang: u16 = script_table + 4;
    const features_at: u32 = script_list + @as(u32, lang) + 6 + 2 * @as(u32, n);
    try w32(&g, 0x00010000);
    try w16(&g, script_list);
    try w16(&g, @intCast(features_at));
    try w16(&g, @intCast(features_at + 8 + 2 + 2 * @as(u32, n)));
    try w16(&g, n);
    for (0..n) |_| {
        try g.appendSlice(gpa, "DFLT");
        try w16(&g, script_table);
    }
    try w16(&g, 4); // the default language system, from the script table
    try w16(&g, 0);
    try w16(&g, 0);
    try w16(&g, 0xffff);
    try w16(&g, n);
    for (0..n) |_| try w16(&g, 0);
    // The feature list has one record, and each language entry names it.
    try w16(&g, 1);
    try g.appendSlice(gpa, "kern");
    try w16(&g, 8);
    try w16(&g, 0);
    try w16(&g, n);
    for (0..n) |_| try w16(&g, 0);
    try w16(&g, 0); // an empty lookup list
    const cm = try cmap4(&.{.{ 0xffff, 0xffff, 1, 0 }}, &.{});
    defer gpa.free(cm);
    const data = try buildFontGpos(&.{ &.{}, &triangle }, plain_metrics[0..2], cm, g.items);
    defer gpa.free(data);
    const f = try ttf.Face.init(data);
    try t.expectEqual(@as(u8, 0), f.kern_count);
}
