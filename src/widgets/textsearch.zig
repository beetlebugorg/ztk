//! The subcommands `search` and `dump` of the `text` widget.
//!
//! `search` copies the text from 1.0 to `end` into one string and a table
//! of the byte offset of each line, so a pattern with a newline matches
//! over the end of a line. An exact pattern is a substring search, with
//! ASCII case folding for `-nocase`. A regular expression goes through
//! the regex engine of ztcl with `^` and `$` at each line, and with `.`
//! stopped at a newline unless `-nolinestop` is given. A search with no
//! stop index wraps around the end (or the start, for `-backwards`).
//!
//! `dump` walks the lines of the range. At each position it gives the
//! tags that end there, the tags that start there, and the marks there,
//! and then the text up to the next of these positions or the end of
//! the line, with the newline.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const widget = @import("../widget.zig");
const buffer = @import("../text_widget/buffer.zig");
const index = @import("../text_widget/index.zig");
const text = @import("text.zig");
const Widget = widget.Widget;
const Value = ztcl.Value;
const Pos = buffer.Pos;

const switch_names = [_][]const u8{ "--", "-all", "-backwards", "-count", "-elide", "-exact", "-forwards", "-nocase", "-nolinestop", "-overlap", "-regexp", "-strictlimits" };

/// The text of the buffer as one string, with the byte offset of each line.
const Flat = struct {
    s: []const u8,
    starts: []usize,

    fn make(w: *Widget, a: std.mem.Allocator) !Flat {
        const d = text.data(w);
        var out: std.ArrayList(u8) = .empty;
        try d.buf.get(.{}, d.buf.end(), &out, a);
        const n = d.buf.lineCount();
        const starts = try a.alloc(usize, n + 1);
        var off: usize = 0;
        for (0..n) |l| {
            starts[l] = off;
            off += d.buf.lineText(@intCast(l)).len + 1;
        }
        starts[n] = off;
        return .{ .s = out.items, .starts = starts };
    }

    fn byteOf(f: Flat, w: *Widget, p: Pos) usize {
        const d = text.data(w);
        if (p.line >= d.buf.lineCount()) return f.s.len;
        return f.starts[p.line] + d.buf.byteAt(p);
    }

    fn posOf(f: Flat, b: usize) Pos {
        var lo: usize = 0;
        var hi: usize = f.starts.len - 1;
        if (b >= f.s.len) return .{ .line = @intCast(hi), .ch = 0 };
        while (hi - lo > 1) {
            const mid = (lo + hi) / 2;
            if (f.starts[mid] <= b) lo = mid else hi = mid;
        }
        return .{ .line = @intCast(lo), .ch = buffer.countChars(f.s[f.starts[lo]..b]) };
    }
};

const Match = struct { lo: usize, hi: usize };

/// Each match that starts in `[from, to)`, in the order of the text.
fn allMatches(it: *ztcl.Interp, hay: []const u8, pat: []const u8, re: ?*ztcl.regex.Regex, from: usize, to: usize, overlap: bool, out: *std.ArrayList(Match)) ztcl.Error!void {
    const a = it.alloc();
    if (re) |r| {
        var m = try ztcl.regex.Matcher.init(it, r, hay);
        var at = from;
        while (at <= hay.len and at < to) {
            if (!try m.search(at)) break;
            const lo = m.caps[0].?;
            const hi = m.caps[1].?;
            if (lo >= to) break;
            try out.append(a, .{ .lo = lo, .hi = hi });
            const step = if (overlap or hi == lo) lo + (std.unicode.utf8ByteSequenceLength(hay[@min(lo, hay.len - 1)]) catch 1) else hi;
            at = @max(step, lo + 1);
        }
        return;
    }
    var at = from;
    while (at < to or (pat.len == 0 and at == to and at == from)) {
        const k = std.mem.indexOfPos(u8, hay, at, pat) orelse break;
        if (k >= to and !(pat.len == 0 and k == from)) break;
        try out.append(a, .{ .lo = k, .hi = k + pat.len });
        if (pat.len == 0) break;
        at = if (overlap) k + 1 else k + pat.len;
    }
}

pub fn cmdSearch(w: *Widget, it: *ztcl.Interp, argv: []const Value) ztcl.Error!Value {
    const a = it.alloc();
    var i: usize = 2;
    var all = false;
    var back = false;
    var regexp = false;
    var nocase = false;
    var nolinestop = false;
    var overlap = false;
    var strict = false;
    var count_var: ?[]const u8 = null;
    while (i < argv.len) {
        const s = try it.str(argv[i]);
        if (s.len == 0 or s[0] != '-') break;
        const k = text.unique(&switch_names, s) orelse return it.fail("bad switch \"{s}\": must be --, -all, -backwards, -count, -elide, -exact, -forwards, -nocase, -nolinestop, -overlap, -regexp, or -strictlimits", .{s});
        i += 1;
        switch (k) {
            0 => break,
            1 => all = true,
            2 => back = true,
            3 => {
                if (i >= argv.len) return it.fail("no value given for \"-count\" option", .{});
                count_var = try it.str(argv[i]);
                i += 1;
            },
            5 => regexp = false,
            6 => back = false,
            7 => nocase = true,
            8 => nolinestop = true,
            9 => overlap = true,
            10 => regexp = true,
            11 => strict = true,
            else => {},
        }
    }
    const rest = argv[i..];
    if (rest.len != 2 and rest.len != 3) return it.fail("wrong # args: should be \"{s} search ?switches? pattern index ?stopIndex?\"", .{w.path});
    const pat0 = try it.str(rest[0]);
    const start = try text.getIndex(w, it, rest[1]);
    const stop: ?Pos = if (rest.len == 3) try text.getIndex(w, it, rest[2]) else null;
    const flat = try Flat.make(w, a);
    var hay = flat.s;
    var pat = pat0;
    var re: ?*ztcl.regex.Regex = null;
    if (regexp) {
        re = try ztcl.regex.compile(it, pat0, .{ .nocase = nocase, .linestop = !nolinestop, .lineanchor = true });
    } else if (nocase) {
        hay = try std.ascii.allocLowerString(a, flat.s);
        pat = try std.ascii.allocLowerString(a, pat0);
    }
    const sb = flat.byteOf(w, start);
    var found: std.ArrayList(Match) = .empty;
    if (!back) {
        if (stop) |z| {
            const zb = flat.byteOf(w, z);
            if (sb < zb) try allMatches(it, hay, pat, re, sb, zb, overlap, &found);
            if (strict) {
                var k: usize = 0;
                for (found.items) |m| if (m.hi <= zb) {
                    found.items[k] = m;
                    k += 1;
                };
                found.shrinkRetainingCapacity(k);
            }
        } else {
            try allMatches(it, hay, pat, re, sb, hay.len, overlap, &found);
            if (all or found.items.len == 0) try allMatches(it, hay, pat, re, 0, sb, overlap, &found);
        }
    } else {
        // Backwards: the matches that start before the start index, the
        // last one first.
        const lo_b: usize = if (stop) |z| flat.byteOf(w, z) else 0;
        var before: std.ArrayList(Match) = .empty;
        if (lo_b < sb) try allMatches(it, hay, pat, re, lo_b, sb, overlap, &before);
        std.mem.reverse(Match, before.items);
        try found.appendSlice(a, before.items);
        if (stop == null and (all or found.items.len == 0)) {
            var after: std.ArrayList(Match) = .empty;
            try allMatches(it, hay, pat, re, sb, hay.len, overlap, &after);
            std.mem.reverse(Match, after.items);
            try found.appendSlice(a, after.items);
        }
    }
    // Text after the last newline is not text of the widget.
    var k: usize = 0;
    for (found.items) |m| if (m.lo < flat.s.len) {
        found.items[k] = m;
        k += 1;
    };
    found.shrinkRetainingCapacity(k);
    if (!all and found.items.len > 1) found.shrinkRetainingCapacity(1);
    var idx: std.ArrayList(Value) = .empty;
    var counts: std.ArrayList(Value) = .empty;
    for (found.items) |m| {
        var b: [32]u8 = undefined;
        try idx.append(a, .{ .str = try a.dupe(u8, index.format(&b, flat.posOf(m.lo))) });
        try counts.append(a, .{ .int = buffer.countChars(flat.s[m.lo..@min(m.hi, flat.s.len)]) });
    }
    if (count_var) |v| {
        if (found.items.len > 0) try it.setVar(v, if (all) try ztcl.value.newList(a, counts.items) else counts.items[0]);
    }
    if (found.items.len == 0) return Value.empty;
    if (!all) return idx.items[0];
    return try ztcl.value.newList(a, idx.items);
}

// ---- dump ----

const dump_names = [_][]const u8{ "-all", "-command", "-image", "-mark", "-tag", "-text", "-window" };

pub fn cmdDump(w: *Widget, it: *ztcl.Interp, argv: []const Value) ztcl.Error!Value {
    const d = text.data(w);
    const a = it.alloc();
    var i: usize = 2;
    var want_text = false;
    var want_mark = false;
    var want_tag = false;
    var command: ?[]const u8 = null;
    while (i < argv.len) {
        const s = try it.str(argv[i]);
        if (s.len == 0 or s[0] != '-') break;
        const k = text.unique(&dump_names, s) orelse return it.fail("bad option \"{s}\": must be -all, -command, -image, -mark, -tag, -text, or -window", .{s});
        i += 1;
        switch (k) {
            0 => {
                want_text = true;
                want_mark = true;
                want_tag = true;
            },
            1 => {
                if (i >= argv.len) break;
                command = try it.str(argv[i]);
                i += 1;
            },
            3 => want_mark = true,
            4 => want_tag = true,
            5 => want_text = true,
            else => {},
        }
    }
    const rest = argv[i..];
    if (rest.len != 1 and rest.len != 2) return it.fail("Usage: {s} dump ?-all -image -text -mark -tag -window? ?-command script? index ?index2?", .{w.path});
    if (!want_text and !want_mark and !want_tag) {
        want_text = true;
        want_mark = true;
        want_tag = true;
    }
    const p1 = try text.getIndex(w, it, rest[0]);
    const p2 = if (rest.len == 2) try text.getIndex(w, it, rest[1]) else d.buf.forward(p1, 1);
    var out: std.ArrayList(Value) = .empty;
    var line = p1.line;
    while (line < d.buf.lineCount()) : (line += 1) {
        const ls: Pos = .{ .line = line, .ch = 0 };
        if (!ls.lt(p2) and line != p1.line) break;
        const n = d.buf.lineChars(line);
        // The positions of the line where a tag starts or ends or a mark is.
        var stops: std.ArrayList(u32) = .empty;
        const from: u32 = if (line == p1.line) p1.ch else 0;
        try stops.append(a, from);
        for (d.buf.tags.order.items) |tag| {
            var k = tag.after(ls);
            if (k > 0) k -= 1;
            while (k < tag.ranges.items.len) : (k += 1) {
                const r = tag.ranges.items[k];
                if (r.a.line > line) break;
                if (r.a.line == line and r.a.ch > from) try stops.append(a, r.a.ch);
                if (r.z.line == line and r.z.ch > from) try stops.append(a, r.z.ch);
            }
        }
        for (d.buf.marks.values()) |m| if (m.pos.line == line and m.pos.ch > from) try stops.append(a, m.pos.ch);
        std.mem.sort(u32, stops.items, {}, std.sort.asc(u32));
        var prev: ?u32 = null;
        for (stops.items, 0..) |c, si| {
            if (prev != null and prev.? == c) continue;
            prev = c;
            const p: Pos = .{ .line = line, .ch = c };
            if (!p.lt(p2)) break;
            var b: [32]u8 = undefined;
            const at = try a.dupe(u8, index.format(&b, p));
            if (want_tag) {
                for (d.buf.tags.order.items) |tag| for (tag.ranges.items) |r| if (r.z.eql(p)) {
                    try out.appendSlice(a, &.{ .{ .str = "tagoff" }, .{ .str = tag.name }, .{ .str = at } });
                };
                for (d.buf.tags.order.items) |tag| for (tag.ranges.items) |r| if (r.a.eql(p)) {
                    try out.appendSlice(a, &.{ .{ .str = "tagon" }, .{ .str = tag.name }, .{ .str = at } });
                };
            }
            if (want_mark) {
                // The marks at the position, in their order.
                var after: ?buffer.Mark = null;
                while (d.buf.nextMark(p, after)) |name| {
                    const m = d.buf.getMark(name).?;
                    if (!m.pos.eql(p)) break;
                    try out.appendSlice(a, &.{ .{ .str = "mark" }, .{ .str = try a.dupe(u8, name) }, .{ .str = at } });
                    after = m;
                }
            }
            if (want_text and c <= n) {
                var next: u32 = n + 1;
                for (stops.items[si + 1 ..]) |c2| if (c2 > c) {
                    next = c2;
                    break;
                };
                var e: Pos = if (next > n) .{ .line = line + 1, .ch = 0 } else .{ .line = line, .ch = next };
                if (p2.lt(e)) e = p2;
                if (p.lt(e)) {
                    var t: std.ArrayList(u8) = .empty;
                    try d.buf.get(p, e, &t, a);
                    try out.appendSlice(a, &.{ .{ .str = "text" }, .{ .str = t.items }, .{ .str = at } });
                }
            }
        }
    }
    if (command) |cmd| {
        var k: usize = 0;
        while (k + 3 <= out.items.len) : (k += 3) {
            const words = try ztcl.value.newList(a, out.items[k .. k + 3]);
            const script = try std.fmt.allocPrint(a, "{s} {s}", .{ cmd, try it.str(words) });
            _ = try it.eval(script);
        }
        return Value.empty;
    }
    return try ztcl.value.newList(a, out.items);
}
