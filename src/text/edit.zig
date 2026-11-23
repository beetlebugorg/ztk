//! The edit model of a one-line text field. It keeps the text as UTF-8,
//! and each index counts characters (code points), not bytes. The caret,
//! the selection, and the anchor are character indexes. The model has no
//! widget and no interpreter, so it is a plain data structure with tests.
//! A word is a run of letters, digits, and the underscore.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

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

    fn isWord(c: u21) bool {
        return c == '_' or (c < 128 and std.ascii.isAlphanumeric(@intCast(c))) or c >= 128;
    }

    fn charAt(e: *const Edit, index: usize) u21 {
        const b = e.byteOf(index);
        const s = e.buf.items[b..];
        const n = std.unicode.utf8ByteSequenceLength(s[0]) catch return s[0];
        if (n > s.len) return s[0];
        return std.unicode.utf8Decode(s[0..n]) catch s[0];
    }

    pub fn target(e: *const Edit, step: Step) usize {
        switch (step) {
            .prev_char => return if (e.caret > 0) e.caret - 1 else 0,
            .next_char => return @min(e.caret + 1, e.chars),
            .line_start => return 0,
            .line_end => return e.chars,
            .prev_word => {
                var i = e.caret;
                while (i > 0 and !isWord(e.charAt(i - 1))) i -= 1;
                while (i > 0 and isWord(e.charAt(i - 1))) i -= 1;
                return i;
            },
            .next_word => {
                var i = e.caret;
                while (i < e.chars and !isWord(e.charAt(i))) i += 1;
                while (i < e.chars and isWord(e.charAt(i))) i += 1;
                return i;
            },
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
            e.delete(e.caret - 1, e.caret);
        }
        e.anchor = e.caret;
    }

    pub fn deleteForward(e: *Edit) void {
        if (e.hasSelection()) {
            const first = e.sel_first;
            e.delete(e.sel_first, e.sel_last);
            e.caret = first;
        } else {
            e.delete(e.caret, e.caret + 1);
        }
        e.anchor = e.caret;
    }

    /// The word that has the character at `index`: [first, last).
    pub fn wordAt(e: *const Edit, index: usize) [2]usize {
        if (e.chars == 0) return .{ 0, 0 };
        const at = @min(index, e.chars - 1);
        const word = isWord(e.charAt(at));
        var a = at;
        var b = at + 1;
        while (a > 0 and isWord(e.charAt(a - 1)) == word) a -= 1;
        while (b < e.chars and isWord(e.charAt(b)) == word) b += 1;
        return .{ a, b };
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
