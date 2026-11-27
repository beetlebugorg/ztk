//! The edit model of a one-line text field. It keeps the text as UTF-8,
//! and each index counts characters (code points), not bytes. The caret,
//! the selection, and the anchor are character indexes. The model has no
//! widget and no interpreter, so it is a plain data structure with tests.
//! The caret moves, Backspace, and Delete step by extended grapheme
//! clusters (UAX #29), so an accent, a flag, or an emoji with a skin
//! tone is one step. A word is a word segment of UAX #29 with a letter
//! or a number. `ztcl.text` has the segmenters.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const seg = @import("ztcl").text;

pub const Edit = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    /// The count of characters.
    chars: usize = 0,
    caret: usize = 0,
    /// The selection is [sel_first, sel_last). Both 0 and equal: none.
    sel_first: usize = 0,
    sel_last: usize = 0,
    anchor: usize = 0,

    pub const Step = enum { prev_char, next_char, prev_word, next_word, line_start, line_end };

    pub fn init(gpa: std.mem.Allocator) Edit {
        return .{ .gpa = gpa };
    }

    pub fn deinit(e: *Edit) void {
        e.buf.deinit(e.gpa);
    }

    pub fn text(e: *const Edit) []const u8 {
        return e.buf.items;
    }

    pub fn len(e: *const Edit) usize {
        return e.chars;
    }

    fn countChars(s: []const u8) usize {
        var n: usize = 0;
        for (s) |c| {
            if (c & 0xC0 != 0x80) n += 1;
        }
        return n;
    }

    /// The byte offset of a character index. An index past the end gives the length in bytes.
    pub fn byteOf(e: *const Edit, index: usize) usize {
        if (index >= e.chars) return e.buf.items.len;
        var seen: usize = 0;
        for (e.buf.items, 0..) |c, i| {
            if (c & 0xC0 != 0x80) {
                if (seen == index) return i;
                seen += 1;
            }
        }
        return e.buf.items.len;
    }

    /// The character index of a byte offset.
    pub fn charOf(e: *const Edit, byte: usize) usize {
        return countChars(e.buf.items[0..@min(byte, e.buf.items.len)]);
    }

    pub fn setText(e: *Edit, utf8: []const u8) !void {
        e.buf.clearRetainingCapacity();
        try e.buf.appendSlice(e.gpa, utf8);
        e.chars = countChars(utf8);
        e.caret = @min(e.caret, e.chars);
        e.anchor = @min(e.anchor, e.chars);
        e.clearSelection();
    }

    pub fn insert(e: *Edit, index: usize, utf8: []const u8) !void {
        const at = @min(index, e.chars);
        const n = countChars(utf8);
        try e.buf.insertSlice(e.gpa, e.byteOf(at), utf8);
        e.chars += n;
        if (e.caret >= at) e.caret += n;
        if (e.anchor >= at) e.anchor += n;
        if (e.hasSelection()) {
            if (e.sel_first >= at) e.sel_first += n;
            if (e.sel_last > at) e.sel_last += n;
        }
    }

    /// Deletes [first, last).
    pub fn delete(e: *Edit, first: usize, last: usize) void {
        const a = @min(first, e.chars);
        const b = @min(@max(last, a), e.chars);
        if (a == b) return;
        const ba = e.byteOf(a);
        const bb = e.byteOf(b);
        e.buf.replaceRangeAssumeCapacity(ba, bb - ba, &.{});
        e.chars -= b - a;
        e.caret = shrinkIndex(e.caret, a, b);
        e.anchor = shrinkIndex(e.anchor, a, b);
        if (e.hasSelection()) {
            const nf = shrinkIndex(e.sel_first, a, b);
            const nl = shrinkIndex(e.sel_last, a, b);
            if (nf >= nl) e.clearSelection() else {
                e.sel_first = nf;
                e.sel_last = nl;
            }
        }
    }

    fn shrinkIndex(i: usize, a: usize, b: usize) usize {
        if (i >= b) return i - (b - a);
        if (i > a) return a;
        return i;
    }

    pub fn hasSelection(e: *const Edit) bool {
        return e.sel_last > e.sel_first;
    }

    pub fn select(e: *Edit, first: usize, last: usize) void {
        const a = @min(first, e.chars);
        const b = @min(last, e.chars);
        if (b <= a) {
            e.clearSelection();
            return;
        }
        e.sel_first = a;
        e.sel_last = b;
    }

    pub fn clearSelection(e: *Edit) void {
        e.sel_first = 0;
        e.sel_last = 0;
    }

    /// Moves the caret. With `extend`, the selection goes from the anchor
    /// to the new caret. Without it, the selection clears and the anchor
    /// follows the caret.
    pub fn moveTo(e: *Edit, index: usize, extend: bool) void {
        const to = @min(index, e.chars);
        if (extend) {
            e.select(@min(e.anchor, to), @max(e.anchor, to));
        } else {
            e.clearSelection();
            e.anchor = to;
        }
        e.caret = to;
    }

    /// The character index of the cluster boundary after `index`.
    pub fn nextCluster(e: *const Edit, index: usize) usize {
        if (index >= e.chars) return e.chars;
        const b = e.byteOf(index);
        return e.charOf(seg.graphemeEnd(e.buf.items, b));
    }

    /// The character index of the cluster boundary before `index`.
    pub fn prevCluster(e: *const Edit, index: usize) usize {
        if (index == 0) return 0;
        const b = e.byteOf(@min(index, e.chars));
        return e.charOf(seg.graphemeBefore(e.buf.items, b));
    }

    /// The word segments as character ranges, for the word moves.
    fn words(e: *const Edit, out: *[2]usize, caret: usize, forward: bool) usize {
        var w: seg.Words = .{ .s = e.buf.items };
        var at: usize = 0;
        var best: usize = if (forward) e.chars else 0;
        while (w.next()) |part| {
            const a = at;
            at += countChars(part);
            if (!seg.wordLike(part)) continue;
            if (forward and at > caret) {
                best = at;
                out.* = .{ a, at };
                break;
            }
            if (!forward and a < caret) {
                best = a;
                out.* = .{ a, at };
            }
        }
        return best;
    }

    pub fn target(e: *const Edit, step: Step) usize {
        var r: [2]usize = undefined;
        switch (step) {
            .prev_char => return e.prevCluster(e.caret),
            .next_char => return e.nextCluster(e.caret),
            .line_start => return 0,
            .line_end => return e.chars,
            .prev_word => return e.words(&r, e.caret, false),
            .next_word => return e.words(&r, e.caret, true),
        }
    }

    /// Replaces the selection, or inserts at the caret.
    pub fn typeText(e: *Edit, utf8: []const u8) !void {
        if (e.hasSelection()) {
            const first = e.sel_first;
            e.delete(e.sel_first, e.sel_last);
            e.caret = first;
        }
        try e.insert(e.caret, utf8);
        e.anchor = e.caret;
    }

    /// Deletes the selection, or the character before the caret.
    pub fn backspace(e: *Edit) void {
        if (e.hasSelection()) {
            const first = e.sel_first;
            e.delete(e.sel_first, e.sel_last);
            e.caret = first;
        } else if (e.caret > 0) {
            e.delete(e.prevCluster(e.caret), e.caret);
        }
        e.anchor = e.caret;
    }

    pub fn deleteForward(e: *Edit) void {
        if (e.hasSelection()) {
            const first = e.sel_first;
            e.delete(e.sel_first, e.sel_last);
            e.caret = first;
        } else {
            e.delete(e.caret, e.nextCluster(e.caret));
        }
        e.anchor = e.caret;
    }

    /// The word segment of UAX #29 that has the character at `index`:
    /// [first, last). A double click selects it.
    pub fn wordAt(e: *const Edit, index: usize) [2]usize {
        if (e.chars == 0) return .{ 0, 0 };
        const at = @min(index, e.chars - 1);
        const r = seg.wordAt(e.buf.items, e.byteOf(at));
        return .{ e.charOf(r[0]), e.charOf(r[1]) };
    }
};

const t = std.testing;

test "edit: insert and the byte offset of a character" {
    var e = Edit.init(t.allocator);
    defer e.deinit();
    try e.insert(0, "héllo");
    try t.expectEqual(@as(usize, 5), e.len());
    try t.expectEqual(@as(usize, 3), e.byteOf(2));
}

test "edit: delete a range" {
    var e = Edit.init(t.allocator);
    defer e.deinit();
    try e.setText("hello");
    e.delete(1, 3);
    try t.expectEqualStrings("hlo", e.text());
}

test "edit: typeText replaces the selection" {
    var e = Edit.init(t.allocator);
    defer e.deinit();
    try e.setText("hello");
    e.select(1, 4);
    try e.typeText("X");
    try t.expectEqualStrings("hXo", e.text());
    try t.expect(!e.hasSelection());
    try t.expectEqual(@as(usize, 2), e.caret);
}

test "edit: backspace at the start and after a two-byte character" {
    var e = Edit.init(t.allocator);
    defer e.deinit();
    try e.setText("é");
    e.backspace();
    try t.expectEqualStrings("é", e.text());
    e.caret = 1;
    e.backspace();
    try t.expectEqualStrings("", e.text());
}

test "edit: word steps" {
    var e = Edit.init(t.allocator);
    defer e.deinit();
    try e.setText("foo bar");
    e.caret = 7;
    try t.expectEqual(@as(usize, 4), e.target(.prev_word));
    e.caret = 0;
    try t.expectEqual(@as(usize, 3), e.target(.next_word));
}

test "edit: moveTo extends the selection from the anchor" {
    var e = Edit.init(t.allocator);
    defer e.deinit();
    try e.setText("hello");
    e.caret = 1;
    e.anchor = 1;
    e.moveTo(3, true);
    try t.expectEqual(@as(usize, 1), e.sel_first);
    try t.expectEqual(@as(usize, 3), e.sel_last);
    e.moveTo(0, true);
    try t.expectEqual(@as(usize, 0), e.sel_first);
    try t.expectEqual(@as(usize, 1), e.sel_last);
}

test "edit: wordAt and setText clamp" {
    var e = Edit.init(t.allocator);
    defer e.deinit();
    try e.setText("foo bar baz");
    const w = e.wordAt(5);
    try t.expectEqual(@as(usize, 4), w[0]);
    try t.expectEqual(@as(usize, 7), w[1]);
    e.caret = 9;
    try e.setText("ab");
    try t.expectEqual(@as(usize, 2), e.caret);
}

test "edit: the caret, Backspace, and Delete step by grapheme clusters" {
    var e = Edit.init(t.allocator);
    defer e.deinit();
    // e + U+0301, a flag, and a thumb with a skin tone: 3 clusters of 6 characters.
    try e.setText("e\u{301}\u{1F1FA}\u{1F1F8}\u{1F44D}\u{1F3FD}");
    e.moveTo(0, false);
    e.moveTo(e.target(.next_char), false);
    try t.expectEqual(@as(usize, 2), e.caret);
    e.moveTo(e.target(.next_char), false);
    try t.expectEqual(@as(usize, 4), e.caret);
    e.moveTo(e.target(.line_end), false);
    e.moveTo(e.target(.prev_char), false);
    try t.expectEqual(@as(usize, 4), e.caret);
    e.moveTo(6, false);
    e.backspace();
    try t.expectEqual(@as(usize, 4), e.len());
    e.moveTo(0, false);
    e.deleteForward();
    try t.expectEqualStrings("\u{1F1FA}\u{1F1F8}", e.text());
}

test "edit: words of UAX #29" {
    var e = Edit.init(t.allocator);
    defer e.deinit();
    try e.setText("can't stop, 3.14");
    try t.expectEqual([2]usize{ 0, 5 }, e.wordAt(2));
    try t.expectEqual([2]usize{ 12, 16 }, e.wordAt(13));
    e.moveTo(0, false);
    try t.expectEqual(@as(usize, 5), e.target(.next_word));
    e.moveTo(16, false);
    try t.expectEqual(@as(usize, 12), e.target(.prev_word));
}
