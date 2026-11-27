//! The layout of one line of a `text` widget: the runs of the tags, the
//! display lines of the wrap, the tab stops, the margins, the spacing,
//! and the justification.
//!
//! The runs split the line at the edges of the tags. Each run has the
//! look of its tags (`Attrs`): the options of the tags in the order of
//! their priority, so a higher tag wins. The x offset of each character
//! comes from one shape of its run, so a line costs one shape for each
//! run and no search.
//!
//! The wrap walks the characters with their advances, and it breaks only
//! between grapheme clusters (UAX #29). A character that
//! ends past the right margin starts a new display line: at the
//! character for `-wrap char`, and after the last space of the display
//! line for `-wrap word` (at the character when the display line has no
//! space). A display line has at least one character. A tab advances to
//! the next tab stop: the stops of `-tabs` (of the widget or of the tag
//! at the start of the line), then stops at the last interval, or a stop
//! for each 8 widths of the character "0" with no `-tabs`.
//!
//! The paragraph options (the margins, the spacing, `-justify`, `-wrap`,
//! and `-tabs`) come from the tags of the first character of the line,
//! and else from the widget. `-spacing1` goes above the first display
//! line, `-spacing2` between display lines, and `-spacing3` below the
//! last one.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const geom = @import("../geom.zig");
const options = @import("../options.zig");
const paint = @import("../paint.zig");
const widget = @import("../widget.zig");
const font_mod = @import("../text/font.zig");
const buffer = @import("../text_widget/buffer.zig");
const tags_mod = @import("../text_widget/tags.zig");
const text = @import("text.zig");
const textembed = @import("textembed.zig");
const Widget = widget.Widget;
const Pos = buffer.Pos;
const T = tags_mod.Opt;

/// The look of a run of characters with one set of tags.
pub const Attrs = struct {
    fg: ?geom.Color = null,
    bg: ?geom.Color = null,
    font: font_mod.FontDesc = .{},
    underline: bool = false,
    overstrike: bool = false,
    underline_fg: ?geom.Color = null,
    overstrike_fg: ?geom.Color = null,
    offset: i32 = 0,
    elide: bool = false,
};

/// A piece of a display line: characters `c0` to `c1` and bytes `b0` to
/// `b1`, at `x` from the left of the content, with the width `w`. A tab
/// is a piece of its own with no glyph, and so is the character of an
/// embedded window or image (`emb`).
pub const Piece = struct { c0: u32, c1: u32, b0: usize, b1: usize, x: i32, w: i32, attrs: Attrs, ascent: i32, tab: bool = false, emb: ?*const textembed.Embed = null };

/// A display line: its characters, its top `y` from the top of the line
/// of the text, its height, its baseline, and its pieces.
pub const DLine = struct { c0: u32, c1: u32, y: i32, h: i32, ascent: i32, x: i32, w: i32, pieces: []Piece };

/// A line of the text: its height with the spacing, its width, and its
/// display lines.
pub const Para = struct { h: i32, w: i32, lines: []DLine };

pub const Wrap = enum(u8) { char = 0, none = 1, word = 2 };

const ParaOpts = struct {
    lm1: i32 = 0,
    lm2: i32 = 0,
    rm: i32 = 0,
    sp1: i32 = 0,
    sp2: i32 = 0,
    sp3: i32 = 0,
    justify: u8 = 0,
    wrap: Wrap = .char,
    tabs: []const u8 = "",
};

fn pixelsOf(v: tags_mod.Value) ?i32 {
    return if (v == .pixels) v.pixels else null;
}

fn paraOpts(w: *Widget, line: u32) ParaOpts {
    const d = text.data(w);
    var o: ParaOpts = .{
        .sp1 = text.int(w, "-spacing1"),
        .sp2 = text.int(w, "-spacing2"),
        .sp3 = text.int(w, "-spacing3"),
    };
    const wv = options.get(w, "-wrap").value;
    if (wv == .word) o.wrap = @enumFromInt(wv.word);
    const tabs = options.get(w, "-tabs");
    if (tabs.set) o.tabs = tabs.text;
    const start: Pos = .{ .line = line, .ch = 0 };
    for (d.buf.tags.order.items) |tag| {
        if (!tag.has(start)) continue;
        if (pixelsOf(tag.get(T.lmargin1))) |v| o.lm1 = v;
        if (pixelsOf(tag.get(T.lmargin2))) |v| o.lm2 = v;
        if (pixelsOf(tag.get(T.rmargin))) |v| o.rm = v;
        if (pixelsOf(tag.get(T.spacing1))) |v| o.sp1 = v;
        if (pixelsOf(tag.get(T.spacing2))) |v| o.sp2 = v;
        if (pixelsOf(tag.get(T.spacing3))) |v| o.sp3 = v;
        if (tag.get(T.justify) == .word) o.justify = tag.get(T.justify).word;
        // The words of the tag option `-wrap` are char, none, word, and "".
        if (tag.get(T.wrap) == .word and tag.get(T.wrap).word < 3) o.wrap = @enumFromInt(tag.get(T.wrap).word);
        if (tag.isSet(T.tabs)) o.tabs = tag.text[@intFromEnum(T.tabs)];
    }
    return o;
}

/// The colors of the part `::selection`, for `sel` with no colors of its own.
fn selColors(w: *Widget) [2]?geom.Color {
    const d = text.data(w);
    if (!w.state.focus) {
        const inact = options.get(w, "-inactiveselectbackground");
        if (inact.set) return .{ if (inact.value == .color) inact.value.color else null, null };
    }
    const ss = paint.partStyle(w, "selection", &d.sel_anim).style;
    return .{ ss.background, ss.color };
}

fn applyTag(w: *Widget, at: *Attrs, tag: *const tags_mod.Tag, sel_colors: [2]?geom.Color) void {
    const is_sel = std.mem.eql(u8, tag.name, "sel");
    switch (tag.get(T.background)) {
        .color => |c| at.bg = c,
        else => if (is_sel) if (sel_colors[0]) |c| {
            at.bg = c;
        },
    }
    switch (tag.get(T.foreground)) {
        .color => |c| at.fg = c,
        else => if (is_sel) if (sel_colors[1]) |c| {
            at.fg = c;
        },
    }
    if (tag.isSet(T.font)) {
        if (@import("../fontcmd.zig").parse(w.app, tag.text[@intFromEnum(T.font)], w.style.font)) |f| at.font = f;
    }
    if (tag.get(T.underline) == .boolean) at.underline = tag.get(T.underline).boolean;
    if (tag.get(T.overstrike) == .boolean) at.overstrike = tag.get(T.overstrike).boolean;
    if (tag.get(T.underlinefg) == .color) at.underline_fg = tag.get(T.underlinefg).color;
    if (tag.get(T.overstrikefg) == .color) at.overstrike_fg = tag.get(T.overstrikefg).color;
    if (tag.get(T.offset) == .pixels) at.offset = tag.get(T.offset).pixels;
    if (tag.get(T.elide) == .boolean) at.elide = tag.get(T.elide).boolean;
}

const Run = struct { c0: u32, c1: u32, b0: usize, b1: usize, attrs: Attrs };

/// Splits a line into runs at the edges of its tags.
fn runsOf(w: *Widget, line: u32, a: std.mem.Allocator) ![]Run {
    const d = text.data(w);
    const s = d.buf.lineText(line);
    const n = d.buf.lineChars(line);
    var edges: std.ArrayList(u32) = .empty;
    try edges.append(a, 0);
    const start: Pos = .{ .line = line, .ch = 0 };
    const order = d.buf.tags.order.items;
    for (order) |tag| {
        var k = tag.after(start);
        while (k < tag.ranges.items.len) : (k += 1) {
            const r = tag.ranges.items[k];
            if (r.a.line > line) break;
            if (r.a.line == line) try edges.append(a, r.a.ch);
            if (r.z.line == line) try edges.append(a, r.z.ch);
        }
    }
    try edges.append(a, n);
    std.mem.sort(u32, edges.items, {}, std.sort.asc(u32));
    const sel_colors = selColors(w);
    var runs: std.ArrayList(Run) = .empty;
    var b0: usize = 0;
    var prev: u32 = 0;
    for (edges.items[1..]) |e| {
        if (e <= prev) continue;
        const c0 = prev;
        prev = e;
        var at: Attrs = .{ .font = w.style.font };
        for (order) |tag| if (tag.has(.{ .line = line, .ch = c0 })) applyTag(w, &at, tag, sel_colors);
        const b1 = if (e >= n) s.len else b0 + buffer.byteOf(s[b0..], e - c0);
        try runs.append(a, .{ .c0 = c0, .c1 = e, .b0 = b0, .b1 = b1, .attrs = at });
        b0 = b1;
    }
    return runs.items;
}

/// The attributes of the first character of a line, for the height of
/// an empty line.
fn startAttrs(w: *Widget, line: u32) Attrs {
    const d = text.data(w);
    var at: Attrs = .{ .font = w.style.font };
    const p: Pos = .{ .line = line, .ch = 0 };
    for (d.buf.tags.order.items) |tag| if (tag.has(p)) applyTag(w, &at, tag, .{ null, null });
    return at;
}

/// The next tab stop after `x`, from the left of the content.
fn nextTab(w: *Widget, tabs: []const u8, x: f32) f32 {
    const zero: f32 = @floatFromInt(@max(paint.zeroWidth(w.app, w.style.font), 1));
    var stops: [32]f32 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, tabs, " \t\n");
    while (it.next()) |word| {
        if (options.parsePixels(word, w.app.scaling)) |px| {
            if (n < stops.len) {
                stops[n] = @floatFromInt(px);
                n += 1;
            }
        }
    }
    for (stops[0..n]) |s| if (s > x + 0.5) return s;
    const step: f32 = if (n >= 2) @max(stops[n - 1] - stops[n - 2], 1) else if (n == 1) @max(stops[0], 1) else 8 * zero;
    const base: f32 = if (n > 0) stops[n - 1] else 0;
    const k = @floor((x - base) / step) + 1;
    return base + k * step;
}

/// `inside` is true for a character after the first one of its grapheme
/// cluster: a wrap never goes before it.
const Char = struct { adv: f32, run: u32, space: bool, tab: bool, emb: ?*const textembed.Embed = null, inside: bool = false };

/// Lays out a line of the text for a content width `avail`.
pub fn layout(w: *Widget, line: u32, avail: i32, a: std.mem.Allocator) !Para {
    const app = w.app;
    app.ensureStyle(w);
    const d = text.data(w);
    const o = paraOpts(w, line);
    const runs = try runsOf(w, line, a);
    const s = d.buf.lineText(line);
    const n = d.buf.lineChars(line);
    // The advance of each character, from one shape of each run.
    const chars = try a.alloc(Char, n);
    const byte_of = try a.alloc(usize, n + 1);
    for (runs, 0..) |r, ri| {
        var bi = r.b0;
        var ci = r.c0;
        const xs = if (r.attrs.elide) &[_]f32{} else try paint.charXs(app, a, s[r.b0..r.b1], r.attrs.font);
        while (ci < r.c1) : (ci += 1) {
            const len = std.unicode.utf8ByteSequenceLength(s[bi]) catch 1;
            const k = ci - r.c0;
            const adv: f32 = if (r.attrs.elide) 0 else xs[k + 1] - xs[k];
            chars[ci] = .{ .adv = adv, .run = @intCast(ri), .space = s[bi] == ' ', .tab = s[bi] == '\t' and !r.attrs.elide };
            byte_of[ci] = bi;
            bi = @min(bi + len, r.b1);
        }
    }
    byte_of[n] = s.len;
    // The clusters of UAX #29: each character after the first of its
    // cluster is inside it.
    {
        var bi: usize = 0;
        var ci: usize = 0;
        while (bi < s.len and ci < n) {
            const e = @import("ztcl").text.graphemeEnd(s, bi);
            var first_char = true;
            while (ci < n and byte_of[ci] < e) : (ci += 1) {
                chars[ci].inside = !first_char;
                first_char = false;
            }
            bi = e;
        }
    }
    // The character of an embed has the width of its box.
    for (d.embeds.items) |e| if (e.pos.line == line and e.pos.ch < n) {
        const c = &chars[e.pos.ch];
        c.emb = e;
        c.space = false;
        if (!runs[c.run].attrs.elide) c.adv = @floatFromInt(textembed.contentSize(w, e).w + 2 * e.padx);
    };
    const limit: f32 = @floatFromInt(@max(avail - o.rm, 1));
    var lines: std.ArrayList(DLine) = .empty;
    var d0: u32 = 0;
    var first = true;
    while (true) {
        const margin: f32 = @floatFromInt(if (first) o.lm1 else o.lm2);
        var x = margin;
        var i = d0;
        var brk: ?u32 = null;
        while (i < n) : (i += 1) {
            const c = chars[i];
            const adv = if (c.tab) nextTab(w, o.tabs, x) - x else c.adv;
            if (o.wrap != .none and i > d0 and x + adv > limit + 0.01 and !c.space) {
                brk = i;
                if (o.wrap == .word) {
                    var k = i;
                    while (k > d0 and !chars[k - 1].space) k -= 1;
                    if (k > d0) brk = k;
                }
                // The wrap goes at a cluster boundary: before the cluster,
                // or after it when it is the first of the display line.
                var k = brk.?;
                while (k > d0 and chars[k].inside) k -= 1;
                if (k == d0) {
                    k = brk.?;
                    while (k < n and chars[k].inside) k += 1;
                }
                brk = if (k >= n) null else k;
                break;
            }
            x += adv;
        }
        const d1 = brk orelse n;
        try lines.append(a, try buildLine(w, s, runs, chars, byte_of, o, d0, d1, margin, line, a));
        if (brk == null) break;
        d0 = d1;
        first = false;
    }
    // The vertical places and the justification of the display lines.
    var y: i32 = o.sp1;
    var width: i32 = 0;
    for (lines.items, 0..) |*dl, k| {
        if (k > 0) y += o.sp2;
        dl.y = y;
        y += dl.h;
        const room = @as(i32, @intFromFloat(limit)) - (dl.x + dl.w);
        // The values of `options.Justify`: left, center, right.
        const shift: i32 = switch (o.justify) {
            1 => @max(@divTrunc(room, 2), 0),
            2 => @max(room, 0),
            else => 0,
        };
        if (shift != 0) {
            dl.x += shift;
            for (dl.pieces) |*p| p.x += shift;
        }
        width = @max(width, dl.x + dl.w);
    }
    y += o.sp3;
    return .{ .h = @max(y, 1), .w = width, .lines = lines.items };
}

fn buildLine(w: *Widget, s: []const u8, runs: []const Run, chars: []const Char, byte_of: []const usize, o: ParaOpts, d0: u32, d1: u32, margin: f32, line: u32, a: std.mem.Allocator) !DLine {
    _ = s;
    const app = w.app;
    var pieces: std.ArrayList(Piece) = .empty;
    const base = paint.fontMetrics(app, if (d0 == d1) startAttrs(w, line).font else w.style.font);
    var asc: i32 = base.ascent;
    var desc: i32 = base.line_height - base.ascent;
    // The tallest box of an embed with `top`, `center`, or `bottom`.
    var box_h: i32 = 0;
    var box_align: textembed.Align = .center;
    var x = margin;
    var i = d0;
    while (i < d1) {
        const c = chars[i];
        const r = runs[c.run];
        var j = i + 1;
        if (!c.tab and c.emb == null) {
            while (j < d1 and chars[j].run == c.run and !chars[j].tab and chars[j].emb == null) j += 1;
        }
        var wsum: f32 = 0;
        if (c.tab) {
            wsum = nextTab(w, o.tabs, x) - x;
        } else {
            for (chars[i..j]) |cc| wsum += cc.adv;
        }
        const m = paint.fontMetrics(app, r.attrs.font);
        if (c.emb) |e| {
            if (!r.attrs.elide) {
                const h = textembed.contentSize(w, e).h + 2 * e.pady;
                switch (e.valign) {
                    .baseline => asc = @max(asc, h),
                    else => box_h = @max(box_h, h),
                }
                if (e.valign != .baseline) box_align = e.valign;
            }
        } else if (!r.attrs.elide) {
            asc = @max(asc, m.ascent - r.attrs.offset);
            desc = @max(desc, m.line_height - m.ascent + r.attrs.offset);
        }
        const px: i32 = @intFromFloat(@round(x));
        const pw: i32 = @as(i32, @intFromFloat(@round(x + wsum))) - px;
        try pieces.append(a, .{ .c0 = i, .c1 = j, .b0 = byte_of[i], .b1 = byte_of[j], .x = px, .w = pw, .attrs = r.attrs, .ascent = m.ascent, .tab = c.tab, .emb = c.emb });
        x += wsum;
        i = j;
    }
    // A box that is taller than the text grows the line below it for
    // `top`, above it for `bottom`, and on both sides for `center`.
    const more = box_h - (asc + desc);
    if (more > 0) switch (box_align) {
        .top => desc += more,
        .bottom => asc += more,
        else => {
            asc += @divTrunc(more, 2);
            desc += more - @divTrunc(more, 2);
        },
    };
    const mx: i32 = @intFromFloat(@round(margin));
    return .{ .c0 = d0, .c1 = d1, .y = 0, .h = @max(asc + desc, 1), .ascent = asc, .x = mx, .w = @as(i32, @intFromFloat(@round(x))) - mx, .pieces = pieces.items };
}

/// The display line of a paragraph that has character `ch`. The last
/// display line has the end of the line.
pub fn lineOf(p: Para, ch: u32) usize {
    for (p.lines, 0..) |dl, k| if (ch < dl.c1) return k;
    return p.lines.len - 1;
}

/// The x of character `ch` in a display line, from the left of the content.
pub fn xOf(w: *Widget, dl: DLine, line: u32, ch: u32, a: std.mem.Allocator) i32 {
    const s = text.data(w).buf.lineText(line);
    for (dl.pieces) |p| {
        if (ch >= p.c1) continue;
        if (ch <= p.c0 or p.attrs.elide or p.tab or p.emb != null) return p.x;
        const xs = paint.charXs(w.app, a, s[p.b0..p.b1], p.attrs.font) catch return p.x;
        return p.x + @as(i32, @intFromFloat(@round(xs[ch - p.c0])));
    }
    return dl.x + dl.w;
}

/// The character of a display line that covers the x offset `x`, or the
/// end of the display line.
pub fn charAtX(w: *Widget, dl: DLine, line: u32, x: i64, a: std.mem.Allocator) u32 {
    const s = text.data(w).buf.lineText(line);
    for (dl.pieces) |p| {
        if (p.attrs.elide) continue;
        if (x >= p.x + p.w) continue;
        if (p.tab or p.emb != null or x < p.x) return p.c0;
        const xs = paint.charXs(w.app, a, s[p.b0..p.b1], p.attrs.font) catch return p.c0;
        var k: u32 = 0;
        while (k < p.c1 - p.c0) : (k += 1) {
            if (@as(f32, @floatFromInt(x - p.x)) < xs[k + 1]) return p.c0 + k;
        }
        return p.c1;
    }
    // Past the end: the last character of a wrapped display line, or the
    // end of the line.
    const last = text.data(w).buf.lineChars(line);
    if (dl.c1 < last and dl.c1 > dl.c0) return dl.c1 - 1;
    return dl.c1;
}
