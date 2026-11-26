//! The buffer of the `text` widget: an array of lines, and the marks.
//!
//! Each line is its own byte array in UTF-8, without its newline, with a
//! count of its characters. The text of the buffer is the lines joined
//! with newlines, and a last newline. Line k of the array is line k+1 of
//! a Tk index, and the position after the last newline is `end`: the
//! line `lines.len` at character 0. A position is a line and a count of
//! characters, so `line.char` indexes need no search of the text.
//!
//! An insert splits one line at the position and puts the new lines into
//! the array with one move of the line records. A delete joins the first
//! and the last line of the range and frees the lines between them. So
//! an edit costs the length of the changed lines plus one move of the
//! records of the lines after it, and a key in a buffer of 10,000 lines
//! moves only the records. A line of ASCII text maps a character to a
//! byte with no scan.
//!
//! A mark is a position with a gravity. An insert at a mark moves the
//! mark to the end of the new text when its gravity is right. A delete
//! moves each mark in the range to the start of the range. Each mark has
//! a sequence number, and marks at one position are in the order of
//! their numbers. An edit also moves the ranges of the tags of
//! `tags.zig`.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

/// A position: the line from 0 and the count of characters before it in
/// the line.
pub const Pos = struct {
    line: u32 = 0,
    ch: u32 = 0,

    pub fn order(a: Pos, b: Pos) std.math.Order {
        if (a.line != b.line) return std.math.order(a.line, b.line);
        return std.math.order(a.ch, b.ch);
    }

    pub fn lt(a: Pos, b: Pos) bool {
        return a.order(b) == .lt;
    }

    pub fn eql(a: Pos, b: Pos) bool {
        return a.line == b.line and a.ch == b.ch;
    }
};

pub const Line = struct {
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    chars: u32 = 0,

    fn ascii(l: *const Line) bool {
        return l.bytes.items.len == l.chars;
    }
};

pub const Gravity = enum { left, right };

pub const Mark = struct {
    pos: Pos,
    gravity: Gravity = .right,
    seq: u64 = 0,
};

/// The count of characters in UTF-8 text. A byte that does not start a
/// sequence counts as one character.
pub fn countChars(s: []const u8) u32 {
    var n: u32 = 0;
    for (s) |c| {
        if (c & 0xC0 != 0x80) n += 1;
    }
    return n;
}

/// The byte offset of character `ch` in UTF-8 text, or the length.
pub fn byteOf(s: []const u8, ch: u32) usize {
    var n: u32 = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] & 0xC0 != 0x80) {
            if (n == ch) return i;
            n += 1;
        }
    }
    return s.len;
}

/// The code point at byte `i` of UTF-8 text, or the byte for a bad sequence.
pub fn decodeAt(s: []const u8, i: usize) u21 {
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return s[i];
    if (i + n > s.len) return s[i];
    return std.unicode.utf8Decode(s[i .. i + n]) catch s[i];
}

pub const Buffer = struct {
    gpa: std.mem.Allocator,
    lines: std.ArrayListUnmanaged(Line) = .empty,
    /// The marks in the order of their names: `insert` and `current`
    /// first, then the order of creation.
    marks: std.StringArrayHashMapUnmanaged(Mark) = .empty,
    seq: u64 = 0,
    tags: @import("tags.zig").TagSet = .{},

    pub fn init(gpa: std.mem.Allocator) !Buffer {
        var b: Buffer = .{ .gpa = gpa };
        try b.lines.append(gpa, .{});
        try b.setMark("insert", .{}, null);
        try b.setMark("current", .{}, null);
        return b;
    }

    pub fn deinit(b: *Buffer) void {
        for (b.lines.items) |*l| l.bytes.deinit(b.gpa);
        b.lines.deinit(b.gpa);
        for (b.marks.keys()) |k| b.gpa.free(k);
        b.marks.deinit(b.gpa);
        b.tags.deinit(b.gpa);
    }

    /// The count of lines with text, without the empty line of `end`.
    pub fn lineCount(b: *const Buffer) u32 {
        return @intCast(b.lines.items.len);
    }

    /// The position after the last newline.
    pub fn end(b: *const Buffer) Pos {
        return .{ .line = b.lineCount(), .ch = 0 };
    }

    /// The position of the last newline (`end - 1 chars`).
    pub fn last(b: *const Buffer) Pos {
        const n = b.lineCount() - 1;
        return .{ .line = n, .ch = b.lines.items[n].chars };
    }

    /// The count of characters in a line, without its newline. The line
    /// of `end` has none.
    pub fn lineChars(b: *const Buffer, line: u32) u32 {
        if (line >= b.lineCount()) return 0;
        return b.lines.items[line].chars;
    }

    pub fn lineText(b: *const Buffer, line: u32) []const u8 {
        if (line >= b.lineCount()) return "";
        return b.lines.items[line].bytes.items;
    }

    /// The byte offset of a position in its line.
    pub fn byteAt(b: *const Buffer, p: Pos) usize {
        if (p.line >= b.lineCount()) return 0;
        const l = &b.lines.items[p.line];
        if (l.ascii()) return @min(p.ch, l.chars);
        return byteOf(l.bytes.items, p.ch);
    }

    /// A position in the buffer: the line in range, and the character at
    /// most at the newline of its line.
    pub fn clamp(b: *const Buffer, p: Pos) Pos {
        if (p.line >= b.lineCount()) return b.end();
        return .{ .line = p.line, .ch = @min(p.ch, b.lines.items[p.line].chars) };
    }

    /// The character at a position: a newline at the end of a line, and 0
    /// at `end`.
    pub fn charAt(b: *const Buffer, p: Pos) u21 {
        if (p.line >= b.lineCount()) return 0;
        const l = &b.lines.items[p.line];
        if (p.ch >= l.chars) return '\n';
        const s = l.bytes.items;
        const i = if (l.ascii()) p.ch else byteOf(s, p.ch);
        return decodeAt(s, i);
    }

    /// The position `n` characters after `p`, at most `end`.
    pub fn forward(b: *const Buffer, p: Pos, n: u64) Pos {
        var pos = b.clamp(p);
        var left = n;
        while (left > 0) {
            if (pos.line >= b.lineCount()) return b.end();
            const room: u64 = b.lines.items[pos.line].chars - pos.ch;
            if (left <= room) {
                pos.ch += @intCast(left);
                return pos;
            }
            left -= room + 1;
            const down = pos.line + 1;
            pos = .{ .line = down, .ch = 0 };
        }
        return if (pos.line >= b.lineCount()) b.end() else pos;
    }

    /// The position `n` characters before `p`, at least 1.0.
    pub fn backward(b: *const Buffer, p: Pos, n: u64) Pos {
        var pos = b.clamp(p);
        var left = n;
        while (left > 0) {
            if (left <= pos.ch) {
                pos.ch -= @intCast(left);
                return pos;
            }
            if (pos.line == 0) return .{};
            left -= pos.ch + 1;
            const up = pos.line - 1;
            pos = .{ .line = up, .ch = b.lines.items[up].chars };
        }
        return pos;
    }

    /// The count of characters from `a` to `b`, with `a` before `b`.
    pub fn charsBetween(b: *const Buffer, a: Pos, z: Pos) u64 {
        if (a.line == z.line) return z.ch - a.ch;
        var n: u64 = b.lineChars(a.line) - a.ch + 1;
        var l = a.line + 1;
        while (l < z.line) : (l += 1) n += b.lines.items[l].chars + 1;
        return n + z.ch;
    }

    /// Appends the text from `a` to `z` to `out`.
    pub fn get(b: *const Buffer, a: Pos, z: Pos, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
        var p = a;
        while (p.lt(z)) {
            if (p.line >= b.lineCount()) return;
            const s = b.lines.items[p.line].bytes.items;
            const from = b.byteAt(p);
            if (p.line == z.line) {
                try out.appendSlice(gpa, s[from..b.byteAt(z)]);
                return;
            }
            try out.appendSlice(gpa, s[from..]);
            try out.append(gpa, '\n');
            p = .{ .line = p.line + 1, .ch = 0 };
        }
    }

    /// Inserts text at a position before `end` and gives the position
    /// after the new text. The marks move by their gravity.
    pub fn insert(b: *Buffer, at: Pos, text: []const u8) !Pos {
        const gpa = b.gpa;
        const p = b.clamp(at);
        std.debug.assert(p.line < b.lineCount());
        const nl = std.mem.count(u8, text, "\n");
        const first = &b.lines.items[p.line];
        const split = b.byteAt(p);
        var end_pos: Pos = undefined;
        if (nl == 0) {
            try first.bytes.insertSlice(gpa, split, text);
            const n = countChars(text);
            first.chars += n;
            end_pos = .{ .line = p.line, .ch = p.ch + n };
        } else {
            // The new lines: the pieces after the first newline, and the
            // tail of the split line on the last one.
            var fresh = try gpa.alloc(Line, nl);
            defer gpa.free(fresh);
            var made: usize = 0;
            errdefer for (fresh[0..made]) |*l| l.bytes.deinit(gpa);
            var pieces = std.mem.splitScalar(u8, text, '\n');
            const head = pieces.next().?;
            while (pieces.next()) |piece| : (made += 1) {
                fresh[made] = .{};
                try fresh[made].bytes.appendSlice(gpa, piece);
                fresh[made].chars = countChars(piece);
            }
            const lastl = &fresh[nl - 1];
            const last_ch = lastl.chars;
            const tail = first.bytes.items[split..];
            try lastl.bytes.appendSlice(gpa, tail);
            lastl.chars += countChars(tail);
            try b.lines.insertSlice(gpa, p.line + 1, fresh);
            const f = &b.lines.items[p.line];
            f.bytes.shrinkRetainingCapacity(split);
            try f.bytes.appendSlice(gpa, head);
            f.chars = p.ch + countChars(head);
            end_pos = .{ .line = p.line + @as(u32, @intCast(nl)), .ch = last_ch };
        }
        b.moveMarksInsert(p, end_pos);
        b.tags.onInsert(p, end_pos);
        return end_pos;
    }

    /// Moves the marks for an insert at `p` that ends at `e`.
    fn moveMarksInsert(b: *Buffer, p: Pos, e: Pos) void {
        for (b.marks.values()) |*m| {
            const o = m.pos.order(p);
            if (o == .lt or (o == .eq and m.gravity == .left)) continue;
            m.pos = shiftInsert(m.pos, p, e);
        }
    }

    /// Deletes the text from `a` to `z`, with `z` at most the last
    /// newline. The marks in the range go to `a`.
    pub fn delete(b: *Buffer, a: Pos, z: Pos) void {
        if (!a.lt(z)) return;
        const gpa = b.gpa;
        const fb = b.byteAt(a);
        const zb = b.byteAt(z);
        if (a.line == z.line) {
            const l = &b.lines.items[a.line];
            l.bytes.replaceRangeAssumeCapacity(fb, zb - fb, "");
            l.chars -= z.ch - a.ch;
        } else {
            const zl = &b.lines.items[z.line];
            const tail = zl.bytes.items[zb..];
            const f = &b.lines.items[a.line];
            f.bytes.shrinkRetainingCapacity(fb);
            // A join needs room in the first line. An allocation failure
            // keeps the head and drops the tail, and the lines still match.
            f.bytes.appendSlice(gpa, tail) catch {};
            f.chars = a.ch + countChars(f.bytes.items[fb..]);
            for (b.lines.items[a.line + 1 .. z.line + 1]) |*l| l.bytes.deinit(gpa);
            b.lines.replaceRangeAssumeCapacity(a.line + 1, z.line - a.line, &.{});
        }
        for (b.marks.values()) |*m| m.pos = shiftDelete(m.pos, a, z);
        b.tags.onDelete(a, z);
    }

    pub fn getMark(b: *const Buffer, name: []const u8) ?Mark {
        return b.marks.get(name);
    }

    /// Sets a mark to a position. A new mark has right gravity, or the
    /// gravity given.
    pub fn setMark(b: *Buffer, name: []const u8, p: Pos, gravity: ?Gravity) !void {
        const gop = try b.marks.getOrPut(b.gpa, name);
        if (!gop.found_existing) {
            gop.key_ptr.* = b.gpa.dupe(u8, name) catch |e| {
                b.marks.swapRemoveAt(gop.index);
                return e;
            };
            gop.value_ptr.* = .{ .pos = p };
        }
        b.seq += 1;
        gop.value_ptr.pos = p;
        gop.value_ptr.seq = b.seq;
        if (gravity) |g| gop.value_ptr.gravity = g;
    }

    /// Removes a mark. `insert` and `current` stay.
    pub fn unsetMark(b: *Buffer, name: []const u8) void {
        if (std.mem.eql(u8, name, "insert") or std.mem.eql(u8, name, "current")) return;
        const i = b.marks.getIndex(name) orelse return;
        const key = b.marks.keys()[i];
        b.marks.orderedRemoveAt(i);
        b.gpa.free(key);
    }

    /// The name of the first mark after the mark `after` (by position and
    /// sequence), or the first mark at or after the position `at`.
    pub fn nextMark(b: *const Buffer, at: Pos, after: ?Mark) ?[]const u8 {
        var best: ?usize = null;
        for (b.marks.values(), 0..) |m, i| {
            if (after) |x| {
                if (!markLess(x, m)) continue;
            } else if (m.pos.lt(at)) continue;
            if (best == null or markLess(m, b.marks.values()[best.?])) best = i;
        }
        return if (best) |i| b.marks.keys()[i] else null;
    }

    /// The name of the last mark before the mark `before`, or the last
    /// mark before the position `at`.
    pub fn prevMark(b: *const Buffer, at: Pos, before: ?Mark) ?[]const u8 {
        var best: ?usize = null;
        for (b.marks.values(), 0..) |m, i| {
            if (before) |x| {
                if (!markLess(m, x)) continue;
            } else if (!m.pos.lt(at)) continue;
            if (best == null or markLess(b.marks.values()[best.?], m)) best = i;
        }
        return if (best) |i| b.marks.keys()[i] else null;
    }
};

fn markLess(a: Mark, b: Mark) bool {
    const o = a.pos.order(b.pos);
    return o == .lt or (o == .eq and a.seq < b.seq);
}

/// A position at or after `p` after an insert from `p` to `e`.
pub fn shiftInsert(q: Pos, p: Pos, e: Pos) Pos {
    if (q.line == p.line) return .{ .line = e.line, .ch = e.ch + (q.ch - p.ch) };
    return .{ .line = q.line + (e.line - p.line), .ch = q.ch };
}

/// A position after a delete from `a` to `z`.
pub fn shiftDelete(q: Pos, a: Pos, z: Pos) Pos {
    if (!a.lt(q)) return q;
    if (!z.lt(q)) return a;
    if (q.line == z.line) return .{ .line = a.line, .ch = a.ch + (q.ch - z.ch) };
    return .{ .line = q.line - (z.line - a.line), .ch = q.ch };
}

const t = std.testing;

fn allText(b: *const Buffer) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try b.get(.{}, b.end(), &out, t.allocator);
    return out.toOwnedSlice(t.allocator);
}

test "textw buffer: insert, delete, and the marks" {
    var b = try Buffer.init(t.allocator);
    defer b.deinit();
    const e = try b.insert(.{}, "hello\nw\u{e9}rld\nx");
    try t.expectEqual(Pos{ .line = 2, .ch = 1 }, e);
    try t.expectEqual(@as(u32, 3), b.lineCount());
    try t.expectEqual(@as(u32, 5), b.lineChars(1));
    try t.expectEqual(@as(u21, 0xe9), b.charAt(.{ .line = 1, .ch = 1 }));
    try t.expectEqual(Pos{ .line = 2, .ch = 1 }, b.getMark("insert").?.pos);
    try b.setMark("l", .{ .line = 1, .ch = 2 }, .left);
    try b.setMark("r", .{ .line = 1, .ch = 2 }, null);
    _ = try b.insert(.{ .line = 1, .ch = 2 }, "AB\nC");
    try t.expectEqual(Pos{ .line = 1, .ch = 2 }, b.getMark("l").?.pos);
    try t.expectEqual(Pos{ .line = 2, .ch = 1 }, b.getMark("r").?.pos);
    {
        const s = try allText(&b);
        defer t.allocator.free(s);
        try t.expectEqualStrings("hello\nw\u{e9}AB\nCrld\nx\n", s);
    }
    b.delete(.{ .line = 0, .ch = 3 }, .{ .line = 2, .ch = 1 });
    {
        const s = try allText(&b);
        defer t.allocator.free(s);
        try t.expectEqualStrings("helrld\nx\n", s);
    }
    try t.expectEqual(Pos{ .line = 0, .ch = 3 }, b.getMark("r").?.pos);
    try t.expectEqual(Pos{ .line = 1, .ch = 1 }, b.getMark("insert").?.pos);
    try t.expectEqual(Pos{ .line = 1, .ch = 0 }, b.forward(.{ .line = 0, .ch = 4 }, 3));
    try t.expectEqual(Pos{ .line = 0, .ch = 5 }, b.backward(.{ .line = 1, .ch = 0 }, 2));
    try t.expectEqual(b.end(), b.forward(.{}, 100));
    try t.expectEqual(@as(u64, 9), b.charsBetween(.{}, b.end()));
    try t.expectEqualStrings("l", b.nextMark(.{}, null).?);
    try t.expectEqualStrings("r", b.nextMark(.{}, b.getMark("l").?).?);
}
