//! The view of a `text` widget: the heights of the lines, the scroll
//! offsets, the paint, and the subcommands that need the layout
//! (`bbox`, `dlineinfo`, `see`, `xview`, `yview`, and `@x,y`).
//!
//! The view keeps the height of each line of the text in pixels, and
//! the sums of the heights before each line. A line that the paint or a
//! subcommand did not lay out has an estimate: the line height of the
//! font times the count of display lines that its characters fill at
//! the width of the "0" character. A layout replaces the estimate with
//! the height, and the sums are made again before the next use. An edit
//! sets the lines that it changed back to estimates, so a key in a
//! buffer of 10,000 lines lays out only the lines in the window.
//!
//! `yview` gives the fractions of the sum of the heights, so the view
//! scrolls by pixels, and the offsets ease as the views of `scroll.zig`
//! do. The paint finds the first line in the window with a binary search
//! of the sums, and lays out and draws only the lines in the window.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const num = @import("../num.zig");
const geom = @import("../geom.zig");
const widget = @import("../widget.zig");
const options = @import("../options.zig");
const paint = @import("../paint.zig");
const scene = @import("../scene.zig");
const anim = @import("../anim.zig");
const scroll = @import("../scroll.zig");
const buffer = @import("../text_widget/buffer.zig");
const text = @import("text.zig");
const tl = @import("textlayout.zig");
const textembed = @import("textembed.zig");
const label = @import("label.zig");
const Widget = widget.Widget;
const Value = ztcl.Value;
const Pos = buffer.Pos;

/// The heights of the lines and their sums.
pub const Heights = struct {
    /// The height of each line, or -1 for an estimate.
    h: std.ArrayListUnmanaged(i32) = .empty,
    /// The sum of the heights before each line, and the total at the end.
    ys: std.ArrayListUnmanaged(i64) = .empty,
    dirty: bool = true,
    /// The content width of the heights. A new width clears them.
    width: i32 = -1,
    /// The widest line that a layout measured.
    max_w: i32 = 0,

    pub fn deinit(hs: *Heights, gpa: std.mem.Allocator) void {
        hs.h.deinit(gpa);
        hs.ys.deinit(gpa);
    }
};

/// The measures for the estimates: the line height and the count of
/// characters of the width of "0" in a display line, or 0 with no wrap.
const Est = struct { lh: i32, per: i32 };

fn estMeasures(w: *Widget, avail: i32) Est {
    const lh = text.lineH(w);
    const wv = options.get(w, "-wrap").value;
    if (wv == .word and wv.word == 1) return .{ .lh = lh, .per = 0 };
    const zero = @max(paint.zeroWidth(w.app, w.style.font), 1);
    return .{ .lh = lh, .per = @max(@divTrunc(avail, zero), 1) };
}

fn estimate(w: *Widget, line: u32, m: Est) i32 {
    if (m.per == 0) return m.lh;
    const n: i32 = @intCast(@min(text.data(w).buf.lineChars(line), 1 << 24));
    return m.lh * @max(@divTrunc(n + m.per - 1, m.per), 1);
}

/// Replaces `old` lines from `first` with `new` lines of estimates.
pub fn noteEdit(w: *Widget, first: u32, old: u32, new: u32) void {
    const d = text.data(w);
    const gpa = w.app.gpa;
    var hs = &d.view;
    if (hs.h.items.len < first + old) {
        hs.h.clearRetainingCapacity();
        hs.dirty = true;
        return;
    }
    const fill = gpa.alloc(i32, new) catch {
        hs.h.clearRetainingCapacity();
        hs.dirty = true;
        return;
    };
    defer gpa.free(fill);
    @memset(fill, -1);
    hs.h.replaceRange(gpa, first, old, fill) catch hs.h.clearRetainingCapacity();
    hs.dirty = true;
}

/// Makes the heights match the lines and the width.
fn ensureSize(w: *Widget) void {
    const d = text.data(w);
    const hs = &d.view;
    const gpa = w.app.gpa;
    const n = d.buf.lineCount();
    const avail = text.content(w).w;
    if (hs.width != avail or hs.h.items.len != n) {
        hs.h.resize(gpa, n) catch return;
        @memset(hs.h.items, -1);
        hs.width = avail;
        hs.max_w = 0;
        hs.dirty = true;
    }
}

/// Makes the heights match the lines and the width, and the sums.
fn ensure(w: *Widget) void {
    ensureSize(w);
    const d = text.data(w);
    const hs = &d.view;
    if (!hs.dirty) return;
    const n = d.buf.lineCount();
    hs.ys.resize(w.app.gpa, n + 1) catch return;
    const m = estMeasures(w, hs.width);
    var y: i64 = 0;
    for (hs.h.items, 0..) |h, i| {
        hs.ys.items[i] = y;
        y += if (h >= 0) h else estimate(w, @intCast(i), m);
    }
    hs.ys.items[n] = y;
    hs.dirty = false;
}

/// The y of the top of a line from the top of the text.
pub fn lineY(w: *Widget, line: u32) i64 {
    ensure(w);
    const ys = text.data(w).view.ys.items;
    if (ys.len == 0) return 0;
    return ys[@min(line, ys.len - 1)];
}

fn total(w: *Widget) i64 {
    ensure(w);
    const ys = text.data(w).view.ys.items;
    return if (ys.len == 0) 0 else ys[ys.len - 1];
}

/// The line that covers the y offset `y` from the top of the text.
fn lineAt(w: *Widget, y: i64) u32 {
    ensure(w);
    const d = text.data(w);
    const ys = d.view.ys.items;
    const n = d.buf.lineCount();
    if (ys.len == 0 or n == 0) return 0;
    var lo: usize = 0;
    var hi: usize = n;
    while (hi - lo > 1) {
        const mid = (lo + hi) / 2;
        if (ys[mid] <= y) lo = mid else hi = mid;
    }
    return @intCast(lo);
}

/// The layout of a line. It records the height of the line.
pub fn layoutLine(w: *Widget, line: u32, a: std.mem.Allocator) !tl.Para {
    const d = text.data(w);
    ensureSize(w);
    const hs = &d.view;
    const p = try tl.layout(w, line, hs.width, a);
    if (line < hs.h.items.len and hs.h.items[line] != p.h) {
        const old = if (hs.h.items[line] >= 0) hs.h.items[line] else estimate(w, line, estMeasures(w, hs.width));
        hs.h.items[line] = p.h;
        // The sums after the line move by the change of its height.
        if (!hs.dirty and old != p.h and hs.ys.items.len == hs.h.items.len + 1) {
            for (hs.ys.items[line + 1 ..]) |*y| y.* += p.h - old;
        }
    }
    d.view.max_w = @max(d.view.max_w, p.w);
    return p;
}

/// Sets the sizes of the views from the heights and the window.
pub fn sync(w: *Widget) void {
    const d = text.data(w);
    const c = text.content(w);
    d.vy.setSize(@floatFromInt(total(w)), @floatFromInt(c.h));
    const wv = options.get(w, "-wrap").value;
    const none = wv == .word and wv.word == 1;
    d.vx.setSize(@floatFromInt(if (none) @max(d.view.max_w, c.w) else c.w), @floatFromInt(c.w));
}

fn report(w: *Widget) void {
    const d = text.data(w);
    scroll.report(w, &d.vx, "-xscrollcommand");
    scroll.report(w, &d.vy, "-yscrollcommand");
}

/// A point of a position in the window: the display line and the x.
const Place = struct { line_y: i64, dl: tl.DLine, x: i32 };

fn place(w: *Widget, p: Pos, a: std.mem.Allocator) ?Place {
    const d = text.data(w);
    if (p.line >= d.buf.lineCount()) return null;
    const para = layoutLine(w, p.line, a) catch return null;
    const dl = para.lines[tl.lineOf(para, p.ch)];
    return .{ .line_y = lineY(w, p.line), .dl = dl, .x = tl.xOf(w, dl, p.line, p.ch, a) };
}

/// The position that covers a point of the widget.
pub fn nearest(w: *Widget, x: i64, y: i64) Pos {
    w.app.ensureStyle(w);
    const d = text.data(w);
    const c = text.content(w);
    var arena = std.heap.ArenaAllocator.init(w.app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const yoff: i64 = @intFromFloat(@round(d.vy.pos));
    const xoff: i64 = @intFromFloat(@round(d.vx.pos));
    // A point outside the content counts as the nearest point of the content.
    const cy = std.math.clamp(y, c.y, c.y + @max(c.h, 1) - 1);
    const ty = std.math.clamp(cy - c.y + yoff, 0, @max(total(w) - 1, 0));
    const line = lineAt(w, ty);
    const para = layoutLine(w, line, a) catch return .{ .line = line };
    const top = lineY(w, line);
    var k: usize = 0;
    while (k + 1 < para.lines.len and ty >= top + para.lines[k].y + para.lines[k].h) k += 1;
    return .{ .line = line, .ch = tl.charAtX(w, para.lines[k], line, x - c.x + xoff, a) };
}

/// The x offset of a position in its display line.
pub fn xOf(w: *Widget, p: Pos) i32 {
    var arena = std.heap.ArenaAllocator.init(w.app.gpa);
    defer arena.deinit();
    const pl = place(w, p, arena.allocator()) orelse return 0;
    return pl.x;
}

/// The count of display lines from `p` to `z`.
pub fn displayLines(w: *Widget, p: Pos, z: Pos) i64 {
    if (z.lt(p)) return -displayLines(w, z, p);
    var arena = std.heap.ArenaAllocator.init(w.app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const d = text.data(w);
    var n: i64 = 0;
    var line = p.line;
    while (line <= z.line and line < d.buf.lineCount()) : (line += 1) {
        const para = layoutLine(w, line, a) catch return n;
        const from = if (line == p.line) tl.lineOf(para, p.ch) else 0;
        const to = if (line == z.line) tl.lineOf(para, z.ch) else para.lines.len;
        n += @as(i64, @intCast(to)) - @as(i64, @intCast(from));
        _ = arena.reset(.retain_capacity);
    }
    return n;
}

// ---- Subcommands ----

fn steps(w: *Widget, axis: u1) scroll.Steps {
    const c = text.content(w);
    if (axis == 0) {
        const zero: f64 = @floatFromInt(@max(paint.zeroWidth(w.app, w.style.font), 1));
        return .{ .unit = zero, .page = @floatFromInt(@max(c.w - 2 * @as(i32, @intFromFloat(zero)), 1)) };
    }
    const lh: f64 = @floatFromInt(text.lineH(w));
    return .{ .unit = lh, .page = @max(@as(f64, @floatFromInt(c.h)) - 2 * lh, lh) };
}

pub fn cmdView(w: *Widget, it: *ztcl.Interp, argv: []const Value, axis: u1) ztcl.Error!Value {
    w.app.ensureStyle(w);
    sync(w);
    const d = text.data(w);
    const v = if (axis == 0) &d.vx else &d.vy;
    const word = if (axis == 0) "xview" else "yview";
    if (argv.len == 2) return try scroll.fractionsValue(it.alloc(), v.fractions());
    const op = try it.str(argv[2]);
    const eq = std.mem.eql;
    if (eq(u8, op, "moveto") and (axis == 0 or argv.len != 3)) {
        _ = try scroll.command(w, it, argv, v, steps(w, axis), false);
        text.repaintView(w);
        report(w);
        return Value.empty;
    }
    if (eq(u8, op, "scroll")) {
        if (argv.len != 5) return it.fail("wrong # args: should be \"{s} {s} scroll number units|pages|pixels\"", .{ w.path, word });
        const t = try it.str(argv[3]);
        // ztk accepts a fraction of a unit, for a touchpad.
        const n = std.fmt.parseFloat(f64, std.mem.trim(u8, t, " ")) catch return it.fail("expected integer but got \"{s}\"", .{t});
        if (!std.math.isFinite(n)) return it.fail("expected integer but got \"{s}\"", .{t});
        const what = try it.str(argv[4]);
        const st = steps(w, axis);
        const delta = if (text.prefix(what, "units")) n * st.unit else if (text.prefix(what, "pages")) n * st.page else if (text.prefix(what, "pixels")) n else return it.fail("bad argument \"{s}\": must be units, pages, or pixels", .{what});
        v.scrollBy(w, delta, n != @trunc(n));
        text.repaintView(w);
        report(w);
        return Value.empty;
    }
    if (axis == 0) return it.fail("bad option \"{s}\": must be moveto or scroll", .{op});
    const pick = eq(u8, op, "-pickplace");
    if ((pick and argv.len != 4) or (!pick and argv.len != 3)) return it.fail("wrong # args: should be \"{s} yview -pickplace lineNum|index\"", .{w.path});
    // `yview lineNum` puts the line with the number (from 0) at the top,
    // `yview index` puts the line of the index at the top, and
    // `-pickplace` scrolls as `see` does.
    const arg = argv[argv.len - 1];
    const s = try it.str(arg);
    var p: Pos = undefined;
    if (std.fmt.parseInt(i64, s, 10)) |n| {
        p = .{ .line = @intCast(std.math.clamp(n, 0, d.buf.lineCount() - 1)) };
    } else |_| {
        p = try text.getIndex(w, it, arg);
        if (p.line >= d.buf.lineCount()) p = d.buf.last();
    }
    if (pick) {
        see(w, p);
        report(w);
        return Value.empty;
    }
    var arena = std.heap.ArenaAllocator.init(w.app.gpa);
    defer arena.deinit();
    const pl = place(w, p, arena.allocator()) orelse return Value.empty;
    v.moveTo(w, v.clampPos(@floatFromInt(pl.line_y + pl.dl.y)), scroll.step_us);
    text.repaintView(w);
    report(w);
    return Value.empty;
}

/// The y of the top of the display line of a position, from the top of
/// the text.
pub fn yOf(w: *Widget, p: Pos) i64 {
    const d = text.data(w);
    if (p.line >= d.buf.lineCount()) return total(w);
    var arena = std.heap.ArenaAllocator.init(w.app.gpa);
    defer arena.deinit();
    const pl = place(w, p, arena.allocator()) orelse return 0;
    return pl.line_y + pl.dl.y;
}

/// Scrolls so that a position shows: by the least move when it is near
/// the window, and to the middle of the window when it is far.
pub fn see(w: *Widget, p0: Pos) void {
    w.app.ensureStyle(w);
    const d = text.data(w);
    var p = p0;
    if (p.line >= d.buf.lineCount()) p = d.buf.last();
    var arena = std.heap.ArenaAllocator.init(w.app.gpa);
    defer arena.deinit();
    const pl = place(w, p, arena.allocator()) orelse return;
    sync(w);
    const c = text.content(w);
    const top = pl.line_y + pl.dl.y;
    const bot = top + pl.dl.h;
    const pos: i64 = @intFromFloat(@round(d.vy.pos));
    const ch: i64 = c.h;
    var to: ?i64 = null;
    if (top < pos) {
        to = if (pos - top > @divTrunc(ch, 3)) top - @divTrunc(ch - pl.dl.h, 2) else top;
    } else if (bot > pos + ch) {
        to = if (bot - (pos + ch) > @divTrunc(ch, 3)) top - @divTrunc(ch - pl.dl.h, 2) else bot - ch;
    }
    if (to) |t| d.vy.moveTo(w, d.vy.clampPos(@floatFromInt(t)), scroll.step_us);
    const xpos: i64 = @intFromFloat(@round(d.vx.pos));
    if (pl.x < xpos) {
        d.vx.moveTo(w, d.vx.clampPos(@floatFromInt(pl.x)), scroll.step_us);
    } else if (pl.x + 2 > xpos + c.w) {
        d.vx.moveTo(w, d.vx.clampPos(@floatFromInt(pl.x + 2 - c.w)), scroll.step_us);
    }
    text.repaintView(w);
}

fn intsValue(a: std.mem.Allocator, xs: []const i64) !Value {
    const vals = try a.alloc(Value, xs.len);
    for (xs, vals) |x, *v| v.* = .{ .int = x };
    return try ztcl.value.wrapList(a, vals);
}

/// `bbox index` (`line` false) and `dlineinfo index` (`line` true).
pub fn cmdBox(w: *Widget, it: *ztcl.Interp, p: Pos, line: bool) ztcl.Error!Value {
    w.app.ensureStyle(w);
    const d = text.data(w);
    if (p.line >= d.buf.lineCount()) return Value.empty;
    var arena = std.heap.ArenaAllocator.init(w.app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const pl = place(w, p, a) orelse return Value.empty;
    sync(w);
    const c = text.content(w);
    const yoff: i64 = @intFromFloat(@round(d.vy.pos));
    const xoff: i64 = @intFromFloat(@round(d.vx.pos));
    const top = c.y + pl.line_y + pl.dl.y - yoff;
    if (top + pl.dl.h <= c.y or top >= c.y + c.h) return Value.empty;
    if (line) {
        return try intsValue(it.alloc(), &.{ c.x + pl.dl.x - xoff, top, pl.dl.w, pl.dl.h, pl.dl.ascent });
    }
    // An embed gives the box of its window or image.
    if (textembed.at(w, p)) |e| for (pl.dl.pieces) |pc| if (pc.emb == e) {
        const r = textembed.box(w, e, pl.dl, pc);
        return try intsValue(it.alloc(), &.{ c.x + r.x - xoff, top + r.y, r.w, r.h });
    };
    const next = tl.xOf(w, pl.dl, p.line, p.ch + 1, a);
    const cw: i64 = if (p.ch >= d.buf.lineChars(p.line)) @max(c.w - (pl.x - xoff), 0) else @max(next - pl.x, 0);
    const x = c.x + pl.x - xoff;
    if (x >= c.x + c.w or x + cw <= c.x) return Value.empty;
    return try intsValue(it.alloc(), &.{ x, top, cw, pl.dl.h });
}

// ---- Paint ----

fn optColor(w: *const Widget, comptime name: []const u8) ?geom.Color {
    const s = options.get(w, name);
    return if (s.set and s.value == .color) s.value.color else null;
}

pub fn paintText(w: *Widget, b: *scene.Builder) anyerror!void {
    const app = w.app;
    const st = anim.shown(app, w);
    try paint.box(w, b, st);
    const d = text.data(w);
    const c = text.content(w);
    sync(w);
    if (c.w <= 0 or c.h <= 0) {
        report(w);
        return;
    }
    if (d.vy.moving or d.vx.moving) {
        // The lines in the window differ at the start and at the end of a
        // smooth scroll, so the UI thread paints each frame of it.
        if (app.part_move != .blocked) app.part_move = .mixed;
    }

    const first_quad = b.scene.quads.items.len;
    b.pushClip(c);
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const yoff = d.vy.shown(w);
    const xoff: i32 = num.pxRound(d.vx.shown(w));
    const ins = d.buf.getMark("insert").?.pos;
    const show_caret = w.state.focus and !text.disabled(w) and d.caret_on;
    var line = lineAt(w, @intFromFloat(@max(@floor(yoff), 0)));
    var y: i32 = c.y + num.pxRound(@as(f64, @floatFromInt(lineY(w, line))) - yoff);
    while (line < d.buf.lineCount() and y < c.y + c.h) : (line += 1) {
        const para = try layoutLine(w, line, a);
        const s = d.buf.lineText(line);
        for (para.lines) |dl| {
            const top = y + dl.y;
            if (top + dl.h <= c.y) continue;
            if (top >= c.y + c.h) break;
            const base_y = top + dl.ascent;
            for (dl.pieces) |pc| {
                if (pc.attrs.elide or pc.c0 == pc.c1) continue;
                const x = c.x + pc.x - xoff;
                if (x > c.x + c.w) break;
                if (x + pc.w < c.x) continue;
                if (pc.attrs.bg) |bg| try b.box(.{ .x = x, .y = top, .w = pc.w, .h = dl.h }, .{ .fill = bg });
                if (pc.tab) continue;
                if (pc.emb) |e| {
                    if (e.kind == .image) if (app.images.find(e.image)) |ph| {
                        const r = textembed.box(w, e, dl, pc);
                        try label.drawPhoto(b, &w.app.atlas, ph, c.x + r.x - xoff, top + r.y, 1);
                    };
                    continue;
                }
                const fg = pc.attrs.fg orelse st.color;
                const by = base_y - pc.attrs.offset;
                try paint.textAt(app, b, x, by, s[pc.b0..pc.b1], pc.attrs.font, fg);
                if (pc.attrs.underline) try b.box(.{ .x = x, .y = by + 1, .w = pc.w, .h = 1 }, .{ .fill = pc.attrs.underline_fg orelse fg });
                if (pc.attrs.overstrike) try b.box(.{ .x = x, .y = by - @divTrunc(pc.ascent * 3, 10), .w = pc.w, .h = 1 }, .{ .fill = pc.attrs.overstrike_fg orelse fg });
            }
        }
        if (show_caret and ins.line == line) {
            const dl = para.lines[tl.lineOf(para, ins.ch)];
            const cx = c.x + tl.xOf(w, dl, line, ins.ch, a) - xoff;
            const color = optColor(w, "-insertbackground") orelse st.caret_color;
            try b.box(.{ .x = cx, .y = y + dl.y, .w = @max(text.int(w, "-insertwidth"), 1), .h = dl.h }, .{ .fill = color });
        }
        // The text of an input method shows at the caret, underlined.
        const ti = &app.text_input;
        if (ins.line == line and ti.preedit_widget == w and ti.preedit.items.len > 0) {
            const dl = para.lines[tl.lineOf(para, ins.ch)];
            const cx = c.x + tl.xOf(w, dl, line, ins.ch, a) - xoff;
            const pw = paint.textSize(app, ti.preedit.items, w.style.font).w;
            try b.box(.{ .x = cx, .y = y + dl.y, .w = pw, .h = dl.h }, .{ .fill = st.background });
            try paint.textAt(app, b, cx, y + dl.y + dl.ascent, ti.preedit.items, w.style.font, st.color);
            try b.box(.{ .x = cx, .y = y + dl.y + dl.ascent + 2, .w = pw, .h = 1 }, .{ .fill = st.color });
        }
        y += para.h;
        _ = arena.reset(.retain_capacity);
    }
    b.popClip();
    // The layout of the lines in the window can change their heights.
    sync(w);
    // The embedded windows go to the boxes of this layout and of the
    // shown view: the heights of the lines above them can change in it.
    if (textembed.windowCount(w) > 0) textembed.arrangeAt(w, true);
    report(w);
    try scroll.paintDrag(w, b, &d.vx, first_quad, 0);
    try scroll.paintDrag(w, b, &d.vy, first_quad, 1);
}

// ---- Moves by display lines ----

/// The start (`end` false) or the end of the display line of a position.
pub fn displayEdge(w: *Widget, p: Pos, end: bool) Pos {
    const d = text.data(w);
    if (p.line >= d.buf.lineCount()) return p;
    var arena = std.heap.ArenaAllocator.init(w.app.gpa);
    defer arena.deinit();
    const para = layoutLine(w, p.line, arena.allocator()) catch return p;
    const k = tl.lineOf(para, p.ch);
    const dl = para.lines[k];
    if (!end) return .{ .line = p.line, .ch = dl.c0 };
    // The end of a wrapped display line is before its last character,
    // so the caret stays on that display line.
    const last = k + 1 < para.lines.len;
    return .{ .line = p.line, .ch = if (last and dl.c1 > dl.c0) dl.c1 - 1 else dl.c1 };
}

/// The position `n` display lines above (n < 0) or below a position, at
/// the x offset `goal`.
pub fn moveLines(w: *Widget, p: Pos, n: i32, goal: i32) Pos {
    const d = text.data(w);
    var arena = std.heap.ArenaAllocator.init(w.app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var line = @min(p.line, d.buf.lineCount() - 1);
    var para = layoutLine(w, line, a) catch return p;
    var k: i64 = @intCast(tl.lineOf(para, if (p.line >= d.buf.lineCount()) d.buf.lineChars(line) else p.ch));
    var left = n;
    while (left != 0) {
        if (left < 0) {
            if (k > 0) {
                k -= 1;
            } else if (line > 0) {
                line -= 1;
                para = layoutLine(w, line, a) catch return p;
                k = @as(i64, @intCast(para.lines.len)) - 1;
            } else break;
            left += 1;
        } else {
            if (k + 1 < para.lines.len) {
                k += 1;
            } else if (line + 1 < d.buf.lineCount()) {
                line += 1;
                para = layoutLine(w, line, a) catch return p;
                k = 0;
            } else break;
            left -= 1;
        }
    }
    const dl = para.lines[@intCast(k)];
    var ch = tl.charAtX(w, dl, line, goal, a);
    // The end of a wrapped display line is before its last character.
    if (@as(usize, @intCast(k)) + 1 < para.lines.len and ch >= dl.c1 and dl.c1 > dl.c0) ch = dl.c1 - 1;
    return .{ .line = line, .ch = ch };
}

/// The count of display lines that fill the window.
pub fn pageLines(w: *Widget) i32 {
    const c = text.content(w);
    return @max(@divTrunc(c.h, text.lineH(w)) - 1, 1);
}
