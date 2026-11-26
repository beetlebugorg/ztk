//! The indexes of the `text` widget, as `text.n` gives them: a base and
//! a list of modifiers.
//!
//! The parse first looks up the whole text as a name (a mark, or
//! `tag.first` and `tag.last`). Else the base ends at the first space,
//! `+`, or `-`, and it is `line.char` (the line in the form of `strtol`
//! with base 0, and the char as a number or `end`), `@x,y`, a prefix of
//! `end`, or a name. Each modifier then moves the position:
//!
//! - `+ count ?submodifier? units` and `- count ...`, with the units
//!   `chars`, `indices`, `lines`, or a prefix of them, and the
//!   submodifier `display` or `any`;
//! - `?submodifier? linestart`, `lineend`, `wordstart`, and `wordend`,
//!   with a prefix of 5 letters or more.
//!
//! A line before line 1 gives 1.0, and a line after the last line gives
//! `end`. A move by lines keeps the count of characters of the position,
//! at most the length of the new line. The display forms move by the
//! lines of the text: the widget has no elided text and no wrapped lines
//! in the counts yet.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const buffer = @import("buffer.zig");
const Buffer = buffer.Buffer;
const Pos = buffer.Pos;

pub const Error = error{ BadIndex, NoTag };

/// The lookups of the widget for the parse.
pub const Ctx = struct {
    buf: *const Buffer,
    ptr: *anyopaque,
    /// The position of a name, or null. `error.NoTag` is for a tag with
    /// no characters.
    named: *const fn (ptr: *anyopaque, name: []const u8) Error!?Pos,
    /// The position nearest to a point of the widget.
    at: *const fn (ptr: *anyopaque, x: i64, y: i64) Pos,
};

fn isWordChar(c: u21) bool {
    return c == '_' or (c < 0x80 and std.ascii.isAlphanumeric(@intCast(c))) or c >= 0xC0;
}

fn isBreak(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '+' or c == '-';
}

fn isSpace(c: u8) bool {
    return std.ascii.isWhitespace(c);
}

/// `strtol` with base 0 at the start of `s`: the value and the count of
/// bytes, or null with no digits.
fn strtol(s: []const u8) ?struct { v: i64, n: usize } {
    var i: usize = 0;
    var neg = false;
    if (i < s.len and (s[i] == '-' or s[i] == '+')) {
        neg = s[i] == '-';
        i += 1;
    }
    var base: u8 = 10;
    if (i + 1 < s.len and s[i] == '0' and (s[i + 1] == 'x' or s[i + 1] == 'X') and i + 2 < s.len and std.ascii.isHex(s[i + 2])) {
        base = 16;
        i += 2;
    } else if (i < s.len and s[i] == '0') {
        base = 8;
    }
    const start = i;
    var v: i64 = 0;
    while (i < s.len) : (i += 1) {
        const d = std.fmt.charToDigit(s[i], base) catch break;
        v = std.math.add(i64, std.math.mul(i64, v, base) catch std.math.maxInt(i64), d) catch std.math.maxInt(i64);
    }
    if (i == start) return null;
    return .{ .v = if (neg) -v else v, .n = i };
}

fn prefixOf(wd: []const u8, full: []const u8, min: usize) bool {
    return wd.len >= min and wd.len <= full.len and std.mem.eql(u8, wd, full[0..wd.len]);
}

/// The position of line `line` (from 1) and char `ch`, in the buffer.
pub fn lineChar(buf: *const Buffer, line: i64, ch: ?i64) Pos {
    if (line < 1) return .{};
    if (line > buf.lineCount()) return buf.end();
    const l: u32 = @intCast(line - 1);
    const n = buf.lineChars(l);
    const c: u32 = if (ch) |v| @intCast(std.math.clamp(v, 0, n)) else n;
    return .{ .line = l, .ch = c };
}

pub fn parse(c: Ctx, s: []const u8) Error!Pos {
    if (try c.named(c.ptr, s)) |p| return p;
    const buf = c.buf;
    var p: Pos = undefined;
    var rest: []const u8 = undefined;
    if (s.len > 0 and (std.ascii.isDigit(s[0]) or s[0] == '-')) {
        const l = strtol(s) orelse return error.BadIndex;
        if (l.n >= s.len or s[l.n] != '.') return error.BadIndex;
        const after = s[l.n + 1 ..];
        if (std.mem.startsWith(u8, after, "end")) {
            p = lineChar(buf, l.v, null);
            rest = after[3..];
        } else {
            const ch = strtol(after) orelse return error.BadIndex;
            p = lineChar(buf, l.v, ch.v);
            rest = after[ch.n..];
        }
    } else if (s.len > 0 and s[0] == '@') {
        const x = strtol(s[1..]) orelse return error.BadIndex;
        const comma = 1 + x.n;
        if (comma >= s.len or s[comma] != ',') return error.BadIndex;
        const y = strtol(s[comma + 1 ..]) orelse return error.BadIndex;
        p = c.at(c.ptr, x.v, y.v);
        rest = s[comma + 1 + y.n ..];
    } else {
        var e: usize = 0;
        while (e < s.len and !isBreak(s[e])) e += 1;
        const base = s[0..e];
        if (prefixOf(base, "end", 1)) {
            p = buf.end();
        } else {
            p = (try c.named(c.ptr, base)) orelse return error.BadIndex;
        }
        rest = s[e..];
    }
    if (rest.len > 0 and !isBreak(rest[0])) return error.BadIndex;
    return modifiers(buf, p, rest);
}

/// The next word of `s` from `i`, after spaces: the bytes up to a space,
/// `+`, or `-`.
fn word(s: []const u8, i: *usize) []const u8 {
    while (i.* < s.len and isSpace(s[i.*])) i.* += 1;
    const start = i.*;
    while (i.* < s.len and !isBreak(s[i.*])) i.* += 1;
    return s[start..i.*];
}

fn isSubmodifier(w: []const u8) bool {
    return prefixOf(w, "display", 1) or prefixOf(w, "any", 1);
}

fn modifiers(buf: *const Buffer, start: Pos, s: []const u8) Error!Pos {
    var p = start;
    var i: usize = 0;
    while (true) {
        while (i < s.len and isSpace(s[i])) i += 1;
        if (i >= s.len) return p;
        if (s[i] == '+' or s[i] == '-') {
            const neg = s[i] == '-';
            i += 1;
            while (i < s.len and isSpace(s[i])) i += 1;
            const n = strtol(s[i..]) orelse return error.BadIndex;
            // The count can have its own sign, as in `+-3c`.
            i += n.n;
            var unit = word(s, &i);
            if (isSubmodifier(unit)) unit = word(s, &i) else if (std.mem.startsWith(u8, unit, "display") and unit.len > 7) unit = unit[7..];
            if (unit.len == 0) return error.BadIndex;
            const count: i64 = if (neg) -n.v else n.v;
            if (prefixOf(unit, "chars", 1) or prefixOf(unit, "indices", 1)) {
                p = if (count >= 0) buf.forward(p, @intCast(count)) else buf.backward(p, @abs(count));
            } else if (prefixOf(unit, "lines", 1)) {
                const target = std.math.clamp(@as(i64, p.line) + count, 0, buf.lineCount());
                if (target >= buf.lineCount()) {
                    p = buf.end();
                } else {
                    const l: u32 = @intCast(target);
                    p = .{ .line = l, .ch = @min(p.ch, buf.lineChars(l)) };
                }
            } else return error.BadIndex;
        } else {
            var w = word(s, &i);
            if (isSubmodifier(w)) w = word(s, &i);
            if (prefixOf(w, "linestart", 5)) {
                if (p.line < buf.lineCount()) p.ch = 0;
            } else if (prefixOf(w, "lineend", 5)) {
                if (p.line < buf.lineCount()) p.ch = buf.lineChars(p.line);
            } else if (prefixOf(w, "wordstart", 5)) {
                p = wordStart(buf, p);
            } else if (prefixOf(w, "wordend", 5)) {
                p = wordEnd(buf, p);
            } else return error.BadIndex;
        }
    }
}

/// The start of the word at `p`: the first character of the run of word
/// characters in its line, or `p` at a character of no word.
pub fn wordStart(buf: *const Buffer, p: Pos) Pos {
    if (p.line >= buf.lineCount()) return p;
    if (!isWordChar(buf.charAt(p))) return p;
    var q = p;
    while (q.ch > 0 and isWordChar(buf.charAt(.{ .line = q.line, .ch = q.ch - 1 }))) q.ch -= 1;
    return q;
}

/// The position after the word at `p`, or the next character at a
/// character of no word.
pub fn wordEnd(buf: *const Buffer, p: Pos) Pos {
    if (p.line >= buf.lineCount()) return p;
    if (!isWordChar(buf.charAt(p))) return buf.forward(p, 1);
    var q = p;
    const n = buf.lineChars(q.line);
    while (q.ch < n and isWordChar(buf.charAt(q))) q.ch += 1;
    return q;
}

/// The text of a position: `line.char` with the line from 1.
pub fn format(out: []u8, p: Pos) []const u8 {
    return std.fmt.bufPrint(out, "{d}.{d}", .{ @as(u64, p.line) + 1, p.ch }) catch unreachable;
}

const t = std.testing;

fn noName(_: *anyopaque, _: []const u8) Error!?Pos {
    return null;
}

fn origin(_: *anyopaque, _: i64, _: i64) Pos {
    return .{};
}

test "textw index: the forms and the modifiers of wish" {
    var b = try Buffer.init(t.allocator);
    defer b.deinit();
    _ = try b.insert(.{}, "hello wo_rld\nab\u{e9}cd ef\nx");
    var dummy: u8 = 0;
    const c: Ctx = .{ .buf = &b, .ptr = &dummy, .named = noName, .at = origin };
    // The expected texts are from wish 8.6.16.
    const cases = [_][2][]const u8{
        .{ "end", "4.0" },            .{ "e", "4.0" },                 .{ "0.5", "1.0" },
        .{ "-3.2", "1.0" },           .{ "1.100", "1.12" },            .{ "1.end", "1.12" },
        .{ "9.0", "4.0" },            .{ "2.3+2c", "2.5" },            .{ "2.3 + 2 chars", "2.5" },
        .{ "2.3-10c", "1.6" },        .{ "1.0+5l", "4.0" },            .{ "1.2 linee", "1.12" },
        .{ "1.2 words", "1.0" },      .{ "1.2 worde", "1.5" },         .{ "1.7 wordend", "1.12" },
        .{ "1.8 wordstart", "1.6" },  .{ "2.0 wordend", "2.5" },       .{ "2.5 wordstart", "2.5" },
        .{ "1.end wordstart", "1.12" }, .{ "1.12 wordend", "2.0" },    .{ "1.4 - 2 l", "1.4" },
        .{ "3.0-1l", "2.0" },         .{ "0x2.0", "2.0" },             .{ "1.0++2c", "1.2" },
        .{ "1.2 +3 c", "1.5" },       .{ "1.2 + 3 d c", "1.5" },       .{ "1.2 + 3 any lines", "4.0" },
        .{ "1.0+-3c", "1.0" },        .{ "1.0 + 3 cha", "1.3" },       .{ "1.1+1char", "1.2" },
        .{ "2.3 +2 displaychars", "2.5" }, .{ "1.-3", "1.0" },          .{ "end lineend", "4.0" },
        .{ "1.0 lineend wordstart", "1.12" }, .{ "1.0 +2c lineend", "1.12" }, .{ "2.0-1c", "1.12" },
    };
    var buf: [32]u8 = undefined;
    for (cases) |k| {
        const p = parse(c, k[0]) catch |e| {
            std.debug.print("{s}: {}\n", .{ k[0], e });
            return e;
        };
        try t.expectEqualStrings(k[1], format(&buf, p));
    }
    const bad = [_][]const u8{ "ends", " 1.2", "1.2junk", "1.2 +3", "1.2 + 3c junk", "1.2 +3 dl", "1.2 lin", "+2.0", "2.0x", "", "1.", ".1", "1.0 +", "1.2c", "1.x", "foo", "1.0 + x c", "1.0 +3 x", "1.1 +1charsxx" };
    for (bad) |k| try t.expectError(error.BadIndex, parse(c, k));
}
