//! Tests of grapheme clusters in the text widgets: the caret moves,
//! Backspace, Delete, the index unit `graphemes`, the double click, the
//! wrap, the cells of `ztk::terminal`, and screenshots of tricky strings
//! in light and dark. The boundaries come from `ztcl.text`, which passes
//! the full GraphemeBreakTest and WordBreakTest files of Unicode 18.0.0.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const seg = @import("ztcl").text;
const testing_h = @import("../testing.zig");
const Harness = testing_h.Harness;
const buffer = @import("../text_widget/buffer.zig");
const edit = @import("../text/edit.zig");
const t = std.testing;

/// Strings with clusters of several code points: a combining accent, a
/// flag, an emoji with a skin tone, a family (ZWJ), a keycap, Hangul
/// jamo, a Devanagari conjunct, and CR LF.
const tricky = [_][]const u8{
    "e\u{301}",
    "\u{1F1FA}\u{1F1F8}\u{1F1EB}\u{1F1F7}",
    "\u{1F44D}\u{1F3FD}",
    "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}",
    "#\u{FE0F}\u{20E3}",
    "\u{1100}\u{1161}\u{11A8}",
    "\u{915}\u{94D}\u{937}\u{93F}",
    "a\r\nb",
    "na\u{303}o \u{2764}\u{FE0F} ok",
};

fn chars(s: []const u8) usize {
    return buffer.countChars(s);
}

/// The character index of each cluster boundary, from `ztcl.text`.
fn bounds(s: []const u8, out: *[64]usize) []usize {
    var n: usize = 0;
    var i: usize = 0;
    out[0] = 0;
    n = 1;
    while (i < s.len) {
        i = seg.graphemeEnd(s, i);
        out[n] = chars(s[0..i]);
        n += 1;
    }
    return out[0..n];
}

test "grapheme: the edit model of entry steps by clusters both ways" {
    for (tricky) |s| {
        var e = edit.Edit.init(t.allocator);
        defer e.deinit();
        try e.setText(s);
        var buf: [64]usize = undefined;
        const b = bounds(s, &buf);
        e.moveTo(0, false);
        for (b[1..]) |want| {
            e.moveTo(e.target(.next_char), false);
            try t.expectEqual(want, e.caret);
        }
        var k = b.len - 1;
        while (k > 0) : (k -= 1) {
            e.moveTo(e.target(.prev_char), false);
            try t.expectEqual(b[k - 1], e.caret);
        }
        // Backspace at the end removes the last cluster whole.
        e.moveTo(e.len(), false);
        e.backspace();
        try t.expectEqual(b[b.len - 2], e.len());
    }
}

test "grapheme: the text buffer steps by clusters" {
    var b = try buffer.Buffer.init(t.allocator);
    defer b.deinit();
    _ = try b.insert(.{}, "x\u{1F44D}\u{1F3FD}e\u{301}\nZ");
    var p: buffer.Pos = .{};
    const want = [_]buffer.Pos{ .{ .ch = 1 }, .{ .ch = 3 }, .{ .ch = 5 }, .{ .line = 1, .ch = 0 }, .{ .line = 1, .ch = 1 } };
    for (want) |w| {
        p = b.nextCluster(p);
        try t.expect(p.eql(w));
    }
    var k: usize = want.len - 1;
    while (k > 0) : (k -= 1) {
        p = b.prevCluster(p);
        try t.expect(p.eql(want[k - 1]));
    }
    const r = b.wordSegment(.{ .ch = 4 });
    try t.expect(r[0].eql(.{ .ch = 3 }) and r[1].eql(.{ .ch = 5 }));
}

test "grapheme: entry keys, Backspace, and Delete" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("entry .e; pack .e; .e insert 0 \"a\\U0001F44D\\U0001F3FDe\\u0301b\"; .e icursor end; update");
    _ = try h.eval("::ztk::priv::entry move .e prev_char 0; ::ztk::priv::entry move .e prev_char 0");
    try t.expectEqualStrings("3", try h.eval(".e index insert"));
    _ = try h.eval("::ztk::priv::entry backspace .e");
    try t.expectEqualStrings("1 4", try h.eval("list [.e index insert] [string length [.e get]]"));
    _ = try h.eval("::ztk::priv::entry delete .e");
    try t.expectEqualStrings("ab", try h.eval(".e get"));
}

test "grapheme: text keys, the unit graphemes, and the double click" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("text .t -width 30 -height 3; pack .t; .t insert 1.0 \"x\\U0001F1FA\\U0001F1F8e\\u0301 can't stop\"; update");
    try t.expectEqualStrings("1.3 1.5 1.1", try h.eval("list [.t index {1.0 + 2 graphemes}] [.t index {1.0+3g}] [.t index {1.5 - 2 graphemes}]"));
    _ = try h.eval(".t mark set insert 1.5; ::ztk::priv::text move .t left 0");
    try t.expectEqualStrings("1.3", try h.eval(".t index insert"));
    _ = try h.eval("::ztk::priv::text backspace .t");
    try t.expectEqualStrings("1.1", try h.eval(".t index insert"));
    _ = try h.eval("::ztk::priv::text delete .t");
    try t.expectEqualStrings("x can't stop", try h.eval(".t get 1.0 1.end"));
    // A double click on "can't" selects the word with its apostrophe.
    const xy = try h.eval("lrange [.t bbox 1.3] 0 1");
    var it = std.mem.tokenizeScalar(u8, xy, ' ');
    const x = it.next().?;
    const y = it.next().?;
    var buf: [128]u8 = undefined;
    _ = try h.eval(try std.fmt.bufPrint(&buf, "::ztk::priv::text double .t {s} {s}", .{ x, y }));
    try t.expectEqualStrings("can't", try h.eval(".t get sel.first sel.last"));
}

test "grapheme: a wrap goes between clusters" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    // A narrow text of marks: each display line starts at a cluster.
    _ = try h.eval("text .t -width 3 -wrap char; pack .t; .t insert 1.0 [string repeat \"e\\u0301\\u0302\" 12]; update");
    const starts = try h.eval("set x0 [lindex [.t bbox 1.0] 0]; set r {}; for {set k 0} {$k < 36} {incr k} {set b [.t bbox 1.$k]; if {$b ne {} && [lindex $b 0] == $x0} {lappend r $k}}; set r");
    var it = std.mem.tokenizeScalar(u8, starts, ' ');
    var n: usize = 0;
    while (it.next()) |c| : (n += 1) {
        const ch = try std.fmt.parseInt(usize, c, 10);
        try t.expectEqual(@as(usize, 0), ch % 3);
    }
    try t.expect(n > 1);
}

fn shot(dark: bool, name: []const u8) !void {
    var h: Harness = undefined;
    try h.initExamples(dark);
    defer h.deinit();
    _ = try h.eval("wm geometry . 360x120; text .t -width 40 -height 3 -font {TkFixedFont 14} -relief flat; pack .t -fill x");
    _ = try h.eval(".t insert end \"Cafe\\u0301 na\\u0303o \\u0915\\u094D\\u0937\\u093F \\u1100\\u1161\\u11A8\\n\\U0001F44D\\U0001F3FD \\U0001F468\\u200D\\U0001F469\\u200D\\U0001F467 \\U0001F1FA\\U0001F1F8 \\u2764\\uFE0F #\\uFE0F\\u20E3\\n\"; entry .e; pack .e -fill x; .e insert 0 \"e\\u0301\\u0323 x\\u0308y\"");
    try h.update();
    try testing_h.expectGolden(name, h.head.image(h.win).?, .{});
}

test "grapheme-shot-light" {
    try shot(false, "grapheme-shot-light");
}

test "grapheme-shot-dark" {
    try shot(true, "grapheme-shot-dark");
}

test "grapheme: ztk::terminal cells hold whole clusters" {
    const vt = @import("ztcl").vt;
    var term = try vt.Term.create(t.allocator, 10, 2, 0);
    defer term.destroy();
    term.write("e\u{301}\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}x");
    var cells: [10]vt.Cell = undefined;
    _ = term.row(0, &cells);
    var b: [32]u8 = undefined;
    try t.expectEqualStrings("e\u{301}", vt.cellText(cells[0], &b, 0));
    try t.expectEqualStrings("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", vt.cellText(cells[1], &b, 0));
    try t.expectEqual(@as(u2, 2), cells[1].width);
    try t.expectEqual(@as(u21, 'x'), cells[3].cp);
    // The cursor column equals the width of ztcl::text.
    try t.expectEqual(@as(usize, 4), seg.width("e\u{301}\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}x", .narrow));
}
