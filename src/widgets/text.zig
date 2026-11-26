//! The class `text`: lines of text with marks. The buffer and the marks
//! are in `src/text_widget/buffer.zig`, and the index forms of `text.n`
//! are in `src/text_widget/index.zig`.
//!
//! This file has the options of `wish` 8.6.16 and the subcommands for
//! the buffer: `compare`, `count`, `delete`, `get`, `index`, `insert`,
//! `mark`, and `replace`. An insert at `end` goes before the last
//! newline, and a delete keeps the last newline: a range to `end` ends
//! at the last newline and starts one character earlier when it starts
//! a line, as `text.n` gives.
//!
//! The paint draws the lines from the top line of the view in the font
//! of the widget, with no wrap, and the caret at the mark `insert` while
//! the widget has the focus. `@x,y` maps a point to the line that
//! covers its y and to the character that covers its x.
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
const App = @import("../app.zig").App;
const buffer = @import("../text_widget/buffer.zig");
const index = @import("../text_widget/index.zig");
const tags_mod = @import("../text_widget/tags.zig");
const texttag = @import("texttag.zig");
const bind = @import("../bind.zig");
const style_mod = @import("../style.zig");
const font_mod = @import("../text/font.zig");
const Spec = options.Spec;
const Widget = widget.Widget;
const Value = ztcl.Value;
const Pos = buffer.Pos;

const state_words = [_][]const u8{ "disabled", "normal" };
const wrap_words = [_][]const u8{ "char", "none", "word" };
const tabstyle_words = [_][]const u8{ "tabular", "wordprocessor" };
const unfocussed_words = [_][]const u8{ "hollow", "none", "solid" };

/// The options of `wish` 8.6.16 for `text`, in its order.
pub const specs = [_]Spec{
    .{ .name = "-autoseparators", .db_name = "autoSeparators", .db_class = "AutoSeparators", .type = .boolean, .default = "1" },
    .{ .name = "-background", .db_name = "background", .db_class = "Background", .type = .color, .default = "#ffffff", .from_style = true, .style_prop = .background },
    .{ .name = "-bd", .type = .synonym, .target = "-borderwidth" },
    .{ .name = "-bg", .type = .synonym, .target = "-background" },
    .{ .name = "-blockcursor", .db_name = "blockCursor", .db_class = "BlockCursor", .type = .boolean, .default = "0" },
    .{ .name = "-borderwidth", .db_name = "borderWidth", .db_class = "BorderWidth", .type = .pixels, .default = "1", .from_style = true, .style_prop = .border_width },
    .{ .name = "-cursor", .db_name = "cursor", .db_class = "Cursor", .type = .string, .default = "xterm", .allow_empty = true },
    .{ .name = "-endline", .type = .int, .allow_empty = true },
    .{ .name = "-exportselection", .db_name = "exportSelection", .db_class = "ExportSelection", .type = .boolean, .default = "1" },
    .{ .name = "-fg", .type = .synonym, .target = "-foreground" },
    .{ .name = "-font", .db_name = "font", .db_class = "Font", .type = .font, .default = "TkFixedFont" },
    .{ .name = "-foreground", .db_name = "foreground", .db_class = "Foreground", .type = .color, .default = "#000000", .from_style = true },
    .{ .name = "-height", .db_name = "height", .db_class = "Height", .type = .int, .default = "24" },
    .{ .name = "-highlightbackground", .db_name = "highlightBackground", .db_class = "HighlightBackground", .type = .color, .default = "#d9d9d9" },
    .{ .name = "-highlightcolor", .db_name = "highlightColor", .db_class = "HighlightColor", .type = .color, .default = "#000000" },
    .{ .name = "-highlightthickness", .db_name = "highlightThickness", .db_class = "HighlightThickness", .type = .pixels, .default = "1" },
    .{ .name = "-inactiveselectbackground", .db_name = "inactiveSelectBackground", .db_class = "Foreground", .type = .color, .default = "#c3c3c3", .allow_empty = true },
    .{ .name = "-insertbackground", .db_name = "insertBackground", .db_class = "Foreground", .type = .color, .default = "#000000" },
    .{ .name = "-insertborderwidth", .db_name = "insertBorderWidth", .db_class = "BorderWidth", .type = .pixels, .default = "0" },
    .{ .name = "-insertofftime", .db_name = "insertOffTime", .db_class = "OffTime", .type = .int, .default = "300" },
    .{ .name = "-insertontime", .db_name = "insertOnTime", .db_class = "OnTime", .type = .int, .default = "600" },
    .{ .name = "-insertunfocussed", .db_name = "insertUnfocussed", .db_class = "InsertUnfocussed", .type = .word, .default = "none", .words = &unfocussed_words },
    .{ .name = "-insertwidth", .db_name = "insertWidth", .db_class = "InsertWidth", .type = .pixels, .default = "2" },
    .{ .name = "-maxundo", .db_name = "maxUndo", .db_class = "MaxUndo", .type = .int, .default = "0" },
    .{ .name = "-padx", .db_name = "padX", .db_class = "Pad", .type = .pixels, .default = "1" },
    .{ .name = "-pady", .db_name = "padY", .db_class = "Pad", .type = .pixels, .default = "1" },
    .{ .name = "-relief", .db_name = "relief", .db_class = "Relief", .type = .relief, .default = "sunken", .from_style = true },
    .{ .name = "-selectbackground", .db_name = "selectBackground", .db_class = "Foreground", .type = .color, .default = "#c3c3c3" },
    .{ .name = "-selectborderwidth", .db_name = "selectBorderWidth", .db_class = "BorderWidth", .type = .pixels, .default = "0" },
    .{ .name = "-selectforeground", .db_name = "selectForeground", .db_class = "Background", .type = .color, .default = "#000000" },
    .{ .name = "-setgrid", .db_name = "setGrid", .db_class = "SetGrid", .type = .boolean, .default = "0" },
    .{ .name = "-spacing1", .db_name = "spacing1", .db_class = "Spacing", .type = .pixels, .default = "0" },
    .{ .name = "-spacing2", .db_name = "spacing2", .db_class = "Spacing", .type = .pixels, .default = "0" },
    .{ .name = "-spacing3", .db_name = "spacing3", .db_class = "Spacing", .type = .pixels, .default = "0" },
    .{ .name = "-startline", .type = .int, .allow_empty = true },
    .{ .name = "-state", .db_name = "state", .db_class = "State", .type = .state, .default = "normal", .words = &state_words },
    .{ .name = "-tabs", .db_name = "tabs", .db_class = "Tabs", .type = .string, .allow_empty = true },
    .{ .name = "-tabstyle", .db_name = "tabStyle", .db_class = "TabStyle", .type = .word, .default = "tabular", .words = &tabstyle_words },
    .{ .name = "-takefocus", .db_name = "takeFocus", .db_class = "TakeFocus", .type = .string, .allow_empty = true },
    .{ .name = "-undo", .db_name = "undo", .db_class = "Undo", .type = .boolean, .default = "0" },
    .{ .name = "-width", .db_name = "width", .db_class = "Width", .type = .int, .default = "80" },
    .{ .name = "-wrap", .db_name = "wrap", .db_class = "Wrap", .type = .word, .default = "char", .words = &wrap_words },
    .{ .name = "-xscrollcommand", .db_name = "xScrollCommand", .db_class = "ScrollCommand", .type = .script, .allow_empty = true },
    .{ .name = "-yscrollcommand", .db_name = "yScrollCommand", .db_class = "ScrollCommand", .type = .script, .allow_empty = true },
};

pub const class: widget.Class = .{
    .command = "text",
    .tk_class = "Text",
    .role = "text area",
    .focusable = true,
    .specs = &specs,
    .init = init,
    .deinit = deinit,
    .configured = configured,
    .measure = measure,
    .paint = paintText,
    .event = texttag.tagEvent,
    .subcommand = subcommand,
    .bad_option_list = "bbox, cget, compare, configure, count, debug, delete, dlineinfo, dump, edit, get, image, index, insert, mark, peer, pendingsync, replace, scan, search, see, sync, tag, window, xview, or yview",
};

pub const Data = struct {
    buf: buffer.Buffer,
    bindings: bind.Table,
    /// The line at the top of the view.
    top: u32 = 0,
    /// The pointer is in the widget, and the tags of `current`.
    pointer_in: bool = false,
    cur_tags: std.ArrayListUnmanaged([]u8) = .empty,
    sel_anim: paint.PartAnim = .{},
};

pub fn data(w: *const Widget) *Data {
    return @ptrCast(@alignCast(w.data.?));
}

fn init(w: *Widget) anyerror!void {
    const d = try w.app.gpa.create(Data);
    errdefer w.app.gpa.destroy(d);
    d.* = .{ .buf = try buffer.Buffer.init(w.app.gpa), .bindings = bind.Table.init(w.app.gpa) };
    w.data = d;
    _ = try d.buf.tags.ensure(w.app.gpa, "sel");
    try syncSel(w);
}

/// Shows the selection options of the widget in the options of `sel`.
fn syncSel(w: *Widget) !void {
    const d = data(w);
    const sel = d.buf.tags.find("sel").?;
    const T = tags_mod.Opt;
    const pairs = [_]struct { T, []const u8 }{
        .{ .background, "-selectbackground" },
        .{ .foreground, "-selectforeground" },
        .{ .borderwidth, "-selectborderwidth" },
    };
    inline for (pairs) |pr| {
        const slot = options.get(w, pr[1]);
        if (slot.set) {
            const gpa = w.app.gpa;
            const i = @intFromEnum(pr[0]);
            gpa.free(sel.text[i]);
            sel.text[i] = try gpa.dupe(u8, slot.text);
            sel.value[i] = switch (slot.value) {
                .color => |c| .{ .color = c },
                .pixels => |x| .{ .pixels = x },
                else => .none,
            };
        } else if (!sel.isSet(pr[0])) {
            const spec = specs[options.index(w, pr[1])];
            try texttag.showOnly(w, sel, pr[0], spec.default);
        }
    }
    if (sel.text[@intFromEnum(T.relief)].len == 0) try texttag.showOnly(w, sel, .relief, "raised");
}

fn configured(w: *Widget, changed_opts: []const usize) ztcl.Error!void {
    _ = changed_opts;
    syncSel(w) catch return error.OutOfMemory;
}

fn deinit(w: *Widget) void {
    const d = data(w);
    d.buf.deinit();
    d.bindings.deinit();
    for (d.cur_tags.items) |n| w.app.gpa.free(n);
    d.cur_tags.deinit(w.app.gpa);
    w.app.gpa.destroy(d);
    w.data = null;
}

fn int(w: *const Widget, comptime name: []const u8) i32 {
    const v = options.get(w, name).value;
    const x: i64 = if (v == .int) v.int else if (v == .pixels) v.pixels else 0;
    return @intCast(std.math.clamp(x, -(1 << 20), 1 << 20));
}

fn disabled(w: *const Widget) bool {
    const v = options.get(w, "-state").value;
    return v == .word and v.word == 0;
}

fn repaint(w: *Widget) void {
    w.invalidate(.{ .style = false, .measure = false, .layout = false, .paint = true });
}

// ---- Geometry ----

fn content(w: *Widget) geom.Rect {
    const ins = paint.insets(&w.style);
    const px = int(w, "-padx");
    const py = int(w, "-pady");
    return .{ .x = ins.left + px, .y = ins.top + py, .w = @max(w.geom.w - ins.horizontal() - 2 * px, 0), .h = @max(w.geom.h - ins.vertical() - 2 * py, 0) };
}

fn lineH(w: *Widget) i32 {
    return @max(paint.lineHeight(w.app, w.style.font), 1);
}

fn measure(w: *Widget) geom.Size {
    w.app.ensureStyle(w);
    const ins = paint.insets(&w.style);
    const cw = std.math.clamp(int(w, "-width"), 0, 1 << 14) * paint.zeroWidth(w.app, w.style.font);
    const ch = std.math.clamp(int(w, "-height"), 0, 1 << 14) * lineH(w);
    return .{ .w = num.add(cw, ins.horizontal() + 2 * int(w, "-padx")), .h = num.add(ch, ins.vertical() + 2 * int(w, "-pady")) };
}

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

/// A run of one line: characters `c0` to `c1` and bytes `b0` to `b1`, at
/// `x` with the width `w`.
pub const Seg = struct { c0: u32, c1: u32, b0: usize, b1: usize, x: i32, w: i32, attrs: Attrs, ascent: i32 };

pub const LineLayout = struct { h: i32, ascent: i32, segs: []Seg };

/// The colors of the part `::selection`, for `sel` with no colors of its own.
fn selColors(w: *Widget) [2]?geom.Color {
    const d = data(w);
    if (!w.state.focus) {
        const inact = options.get(w, "-inactiveselectbackground");
        if (inact.set) return .{ if (inact.value == .color) inact.value.color else null, null };
    }
    const ss = paint.partStyle(w, "selection", &d.sel_anim).style;
    return .{ ss.background, ss.color };
}

fn applyTag(w: *Widget, at: *Attrs, tag: *const tags_mod.Tag, sel_colors: [2]?geom.Color) void {
    const T = tags_mod.Opt;
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
        if (font_mod.Fonts.parseTk(tag.text[@intFromEnum(T.font)], w.style.font, w.app.scaling)) |f| at.font = f;
    }
    if (tag.get(T.underline) == .boolean) at.underline = tag.get(T.underline).boolean;
    if (tag.get(T.overstrike) == .boolean) at.overstrike = tag.get(T.overstrike).boolean;
    if (tag.get(T.underlinefg) == .color) at.underline_fg = tag.get(T.underlinefg).color;
    if (tag.get(T.overstrikefg) == .color) at.overstrike_fg = tag.get(T.overstrikefg).color;
    if (tag.get(T.offset) == .pixels) at.offset = tag.get(T.offset).pixels;
    if (tag.get(T.elide) == .boolean) at.elide = tag.get(T.elide).boolean;
}

/// Splits a line into runs at the edges of the tags, and measures them.
pub fn layoutLine(w: *Widget, line: u32, a: std.mem.Allocator) !LineLayout {
    w.app.ensureStyle(w);
    const d = data(w);
    const app = w.app;
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
    var segs: std.ArrayList(Seg) = .empty;
    const base = paint.fontMetrics(app, w.style.font);
    var asc: i32 = base.ascent;
    var desc: i32 = base.line_height - base.ascent;
    var x: i32 = 0;
    var b0: usize = 0;
    var prev: u32 = 0;
    for (edges.items[1..]) |e| {
        if (e <= prev) continue;
        const c0 = prev;
        prev = e;
        var at: Attrs = .{ .font = w.style.font };
        for (order) |tag| if (tag.has(.{ .line = line, .ch = c0 })) applyTag(w, &at, tag, sel_colors);
        const b1 = if (e >= n) s.len else b0 + buffer.byteOf(s[b0..], e - c0);
        const m = paint.fontMetrics(app, at.font);
        const width = if (at.elide) 0 else paint.textSize(app, s[b0..b1], at.font).w;
        if (!at.elide) {
            asc = @max(asc, m.ascent - at.offset);
            desc = @max(desc, m.line_height - m.ascent + at.offset);
        }
        try segs.append(a, .{ .c0 = c0, .c1 = e, .b0 = b0, .b1 = b1, .x = x, .w = width, .attrs = at, .ascent = m.ascent });
        x += width;
        b0 = b1;
    }
    return .{ .h = @max(asc + desc, 1), .ascent = asc, .segs = segs.items };
}

/// The x offset of a character in its line, from the left of the text.
fn charX(w: *Widget, p: Pos) i32 {
    var sf = std.heap.stackFallback(4096, w.app.gpa);
    var arena = std.heap.ArenaAllocator.init(sf.get());
    defer arena.deinit();
    const lay = layoutLine(w, p.line, arena.allocator()) catch return 0;
    return xInLayout(w, lay, p);
}

fn xInLayout(w: *Widget, lay: LineLayout, p: Pos) i32 {
    const s = data(w).buf.lineText(p.line);
    for (lay.segs) |sg| {
        if (p.ch >= sg.c1 and sg.c1 != sg.c0) continue;
        if (sg.attrs.elide) return sg.x;
        const off = buffer.byteOf(s[sg.b0..sg.b1], p.ch - sg.c0);
        return sg.x + paint.textSize(w.app, s[sg.b0 .. sg.b0 + off], sg.attrs.font).w;
    }
    return if (lay.segs.len > 0) lay.segs[lay.segs.len - 1].x + lay.segs[lay.segs.len - 1].w else 0;
}

/// The line at a y offset of the content, from the top line, and the y
/// of the top of that line.
fn lineAtY(w: *Widget, y: i64, a: std.mem.Allocator) !struct { line: u32, y: i32 } {
    const d = data(w);
    var line = d.top;
    var top: i32 = 0;
    while (line + 1 < d.buf.lineCount()) : (line += 1) {
        const h = (try layoutLine(w, line, a)).h;
        if (y < top + h) break;
        top += h;
    }
    return .{ .line = line, .y = top };
}

/// The position nearest to a point of the widget.
pub fn nearestChar(w: *Widget, x: i64, y: i64) Pos {
    w.app.ensureStyle(w);
    const d = data(w);
    const c = content(w);
    var sf = std.heap.stackFallback(4096, w.app.gpa);
    var arena = std.heap.ArenaAllocator.init(sf.get());
    defer arena.deinit();
    const a = arena.allocator();
    if (y < c.y) {
        return .{ .line = d.top, .ch = charAtX(w, d.top, x - c.x, a) };
    }
    const at = lineAtY(w, y - c.y, a) catch return .{ .line = d.top };
    return .{ .line = at.line, .ch = charAtX(w, at.line, x - c.x, a) };
}

fn charAtX(w: *Widget, line: u32, rx: i64, a: std.mem.Allocator) u32 {
    const d = data(w);
    const lay = layoutLine(w, line, a) catch return 0;
    const s = d.buf.lineText(line);
    for (lay.segs) |sg| {
        if (sg.attrs.elide) continue;
        if (rx >= sg.x + sg.w) continue;
        // The character that covers the x offset, as `text.n` gives for `@x,y`.
        var ch = sg.c0;
        while (ch < sg.c1) : (ch += 1) {
            const off = buffer.byteOf(s[sg.b0..sg.b1], ch - sg.c0 + 1);
            const nx = sg.x + paint.textSize(w.app, s[sg.b0 .. sg.b0 + off], sg.attrs.font).w;
            if (rx < nx) return ch;
        }
        return sg.c1;
    }
    return d.buf.lineChars(line);
}

/// The tags or their options changed.
pub fn tagsChanged(w: *Widget) void {
    repaint(w);
}

/// Removes a deleted tag from the tags of `current`.
pub fn forgetTag(w: *Widget, name: []const u8) void {
    const d = data(w);
    var k: usize = 0;
    while (k < d.cur_tags.items.len) {
        if (std.mem.eql(u8, d.cur_tags.items[k], name)) {
            w.app.gpa.free(d.cur_tags.orderedRemove(k));
        } else k += 1;
    }
}

// ---- Indexes ----

const Lookup = struct {
    w: *Widget,
    /// The tag of the last `tag.first` or `tag.last` with no characters.
    tag: []const u8 = "",
};

fn named(ptr: *anyopaque, name: []const u8) index.Error!?Pos {
    const lk: *Lookup = @ptrCast(@alignCast(ptr));
    const d = data(lk.w);
    if (d.buf.getMark(name)) |m| return m.pos;
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
    const tail = name[dot + 1 ..];
    if (!std.mem.eql(u8, tail, "first") and !std.mem.eql(u8, tail, "last")) return null;
    const tag = d.buf.tags.find(name[0..dot]) orelse return null;
    if (tag.ranges.items.len == 0) {
        lk.tag = tag.name;
        return error.NoTag;
    }
    const r = tag.ranges.items;
    return if (tail[0] == 'f') r[0].a else r[r.len - 1].z;
}

fn atPoint(ptr: *anyopaque, x: i64, y: i64) Pos {
    const lk: *Lookup = @ptrCast(@alignCast(ptr));
    return nearestChar(lk.w, x, y);
}

/// The position of an index, or the message of `wish`.
pub fn getIndex(w: *Widget, it: *ztcl.Interp, v: Value) ztcl.Error!Pos {
    const s = try it.str(v);
    var lk: Lookup = .{ .w = w };
    const c: index.Ctx = .{ .buf = &data(w).buf, .ptr = &lk, .named = named, .at = atPoint };
    return index.parse(c, s) catch |e| switch (e) {
        error.BadIndex => it.fail("bad text index \"{s}\"", .{s}),
        error.NoTag => it.fail("text doesn't contain any characters tagged with \"{s}\"", .{lk.tag}),
    };
}

fn posValue(it: *ztcl.Interp, p: Pos) ztcl.Error!Value {
    var b: [32]u8 = undefined;
    return .{ .str = try it.alloc().dupe(u8, index.format(&b, p)) };
}

// ---- Edits ----

/// Inserts the chars arguments of `insert` and `replace` at a position.
fn insertChars(w: *Widget, at: Pos, args: []const Value, it: *ztcl.Interp) ztcl.Error!void {
    const d = data(w);
    var p = at;
    if (p.line >= d.buf.lineCount()) p = d.buf.last();
    const gpa = w.app.gpa;
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        const s = try it.str(args[i]);
        if (s.len == 0) continue;
        const from = p;
        p = d.buf.insert(p, s) catch return error.OutOfMemory;
        // With a tag list, the new text has the tags of the list only.
        if (i + 1 < args.len) {
            const names = try it.list(args[i + 1]);
            for (d.buf.tags.order.items) |tag| try tag.remove(gpa, from, p);
            for (names) |n| {
                const tag = try d.buf.tags.ensure(gpa, try it.str(n));
                try tag.add(gpa, from, p);
            }
        }
    }
    changed(w);
}

/// Deletes a range with the rule of `text.n` for the last newline.
fn deleteRange(w: *Widget, a0: Pos, z0: Pos) void {
    const d = data(w);
    var a = a0;
    var z = z0;
    if (!a.lt(z)) return;
    if (z.line >= d.buf.lineCount()) {
        z = d.buf.last();
        if (a.ch == 0 and a.line > 0 and a.line < d.buf.lineCount()) a = d.buf.backward(a, 1);
        if (a.line >= d.buf.lineCount()) a = z;
    }
    d.buf.delete(a, z);
}

fn changed(w: *Widget) void {
    const d = data(w);
    if (d.top >= d.buf.lineCount()) d.top = d.buf.lineCount() - 1;
    repaint(w);
}

const Range = struct { a: Pos, z: Pos };

fn rangeLess(_: void, x: Range, y: Range) bool {
    return x.a.lt(y.a);
}

fn cmdDelete(w: *Widget, it: *ztcl.Interp, argv: []const Value) ztcl.Error!Value {
    if (argv.len < 3) return it.fail("wrong # args: should be \"{s} delete index1 ?index2 ...?\"", .{w.path});
    const d = data(w);
    const a = it.alloc();
    var ranges: std.ArrayList(Range) = .empty;
    var i: usize = 2;
    while (i < argv.len) : (i += 2) {
        const p = try getIndex(w, it, argv[i]);
        const z = if (i + 1 < argv.len) try getIndex(w, it, argv[i + 1]) else d.buf.forward(p, 1);
        if (p.lt(z)) try ranges.append(a, .{ .a = p, .z = z });
    }
    if (disabled(w)) return Value.empty;
    std.mem.sort(Range, ranges.items, {}, rangeLess);
    // Merge the ranges that overlap, then delete from the last range, so
    // that the positions of the earlier ranges stay valid.
    var merged: std.ArrayList(Range) = .empty;
    for (ranges.items) |r| {
        if (merged.items.len > 0 and !merged.items[merged.items.len - 1].z.lt(r.a)) {
            const m = &merged.items[merged.items.len - 1];
            if (m.z.lt(r.z)) m.z = r.z;
        } else try merged.append(a, r);
    }
    var k = merged.items.len;
    while (k > 0) {
        k -= 1;
        deleteRange(w, merged.items[k].a, merged.items[k].z);
    }
    changed(w);
    return Value.empty;
}

// ---- Subcommands ----

pub fn prefix(word: []const u8, full: []const u8) bool {
    return word.len > 0 and word.len <= full.len and std.mem.eql(u8, word, full[0..word.len]);
}

/// The unique entry of `names` that starts with `word`, or null.
pub fn unique(names: []const []const u8, word: []const u8) ?usize {
    var found: ?usize = null;
    for (names, 0..) |n, i| {
        if (std.mem.eql(u8, n, word)) return i;
        if (prefix(word, n)) {
            if (found != null) return null;
            found = i;
        }
    }
    return found;
}

const count_names = [_][]const u8{ "-chars", "-displaychars", "-displayindices", "-displaylines", "-indices", "-lines", "-update", "-xpixels", "-ypixels" };

fn countOne(w: *Widget, which: usize, p: Pos, z: Pos) i64 {
    const d = data(w);
    switch (which) {
        0, 1, 2, 4 => {
            if (z.lt(p)) return -@as(i64, @intCast(d.buf.charsBetween(z, p)));
            return @intCast(d.buf.charsBetween(p, z));
        },
        3, 5 => return @as(i64, z.line) - @as(i64, p.line),
        7 => return @as(i64, charX(w, z)) - charX(w, p),
        8 => {
            w.app.ensureStyle(w);
            return (@as(i64, z.line) - @as(i64, p.line)) * lineH(w);
        },
        else => return 0,
    }
}

fn cmdCount(w: *Widget, it: *ztcl.Interp, argv: []const Value) ztcl.Error!Value {
    if (argv.len < 4) return it.fail("wrong # args: should be \"{s} count ?-option value ...? index1 index2\"", .{w.path});
    const a = it.alloc();
    const p = try getIndex(w, it, argv[argv.len - 2]);
    const z = try getIndex(w, it, argv[argv.len - 1]);
    var out: std.ArrayList(Value) = .empty;
    for (argv[2 .. argv.len - 2]) |o| {
        const s = try it.str(o);
        const which = unique(&count_names, s) orelse return it.fail("bad option \"{s}\" must be -chars, -displaychars, -displayindices, -displaylines, -indices, -lines, -update, -xpixels, or -ypixels", .{s});
        if (which == 6) continue;
        try out.append(a, .{ .int = countOne(w, which, p, z) });
    }
    if (out.items.len == 0) return .{ .int = countOne(w, 0, p, z) };
    if (out.items.len == 1) return out.items[0];
    return try ztcl.value.newList(a, out.items);
}

fn cmdGet(w: *Widget, it: *ztcl.Interp, argv: []const Value) ztcl.Error!Value {
    const d = data(w);
    const a = it.alloc();
    var i: usize = 2;
    while (i + 1 < argv.len) {
        const s = try it.str(argv[i]);
        if (std.mem.eql(u8, s, "--")) {
            i += 1;
            break;
        }
        if (s.len > 1 and prefix(s, "-displaychars")) {
            i += 1;
            continue;
        }
        break;
    }
    if (i >= argv.len) return it.fail("wrong # args: should be \"{s} get ?-displaychars? ?--? index1 ?index2 ...?\"", .{w.path});
    var parts: std.ArrayList(Value) = .empty;
    while (i < argv.len) : (i += 2) {
        const p = try getIndex(w, it, argv[i]);
        const z = if (i + 1 < argv.len) try getIndex(w, it, argv[i + 1]) else d.buf.forward(p, 1);
        var out: std.ArrayList(u8) = .empty;
        if (p.lt(z)) try d.buf.get(p, z, &out, a);
        try parts.append(a, .{ .str = out.items });
    }
    if (parts.items.len == 1) return parts.items[0];
    return try ztcl.value.newList(a, parts.items);
}

const mark_names = [_][]const u8{ "gravity", "names", "next", "previous", "set", "unset" };

fn cmdMark(w: *Widget, it: *ztcl.Interp, argv: []const Value) ztcl.Error!Value {
    const d = data(w);
    const a = it.alloc();
    if (argv.len < 3) return it.fail("wrong # args: should be \"{s} mark option ?arg ...?\"", .{w.path});
    const sub = try it.str(argv[2]);
    const which = unique(&mark_names, sub) orelse return it.fail("bad mark option \"{s}\": must be gravity, names, next, previous, set, or unset", .{sub});
    switch (which) {
        0 => {
            if (argv.len != 4 and argv.len != 5) return it.fail("wrong # args: should be \"{s} mark gravity markName ?gravity?\"", .{w.path});
            const name = try it.str(argv[3]);
            const m = d.buf.marks.getPtr(name) orelse return it.fail("there is no mark named \"{s}\"", .{name});
            if (argv.len == 4) return .{ .str = if (m.gravity == .left) "left" else "right" };
            const g = try it.str(argv[4]);
            if (prefix(g, "left")) m.gravity = .left else if (prefix(g, "right")) m.gravity = .right else return it.fail("bad mark gravity \"{s}\": must be left or right", .{g});
            return Value.empty;
        },
        1 => {
            if (argv.len != 3) return it.fail("wrong # args: should be \"{s} mark names\"", .{w.path});
            var out: std.ArrayList(Value) = .empty;
            for (d.buf.marks.keys()) |k| try out.append(a, .{ .str = try a.dupe(u8, k) });
            return try ztcl.value.newList(a, out.items);
        },
        2, 3 => {
            const word = if (which == 2) "next" else "previous";
            if (argv.len != 4) return it.fail("wrong # args: should be \"{s} mark {s} index\"", .{ w.path, word });
            const s = try it.str(argv[3]);
            const from = d.buf.getMark(s);
            const p = if (from) |m| m.pos else try getIndex(w, it, argv[3]);
            const found = if (which == 2) d.buf.nextMark(p, from) else d.buf.prevMark(p, from);
            return if (found) |n| .{ .str = try a.dupe(u8, n) } else Value.empty;
        },
        4 => {
            if (argv.len != 5) return it.fail("wrong # args: should be \"{s} mark set markName index\"", .{w.path});
            const name = try it.str(argv[3]);
            var p = try getIndex(w, it, argv[4]);
            // The mark `insert` stays before the last newline.
            if (std.mem.eql(u8, name, "insert") and p.line >= d.buf.lineCount()) p = d.buf.last();
            d.buf.setMark(name, p, null) catch return it.fail("out of memory", .{});
            if (std.mem.eql(u8, name, "insert")) repaint(w);
            return Value.empty;
        },
        else => {
            for (argv[3..]) |v| d.buf.unsetMark(try it.str(v));
            return Value.empty;
        },
    }
}

fn subcommand(w: *Widget, it: *ztcl.Interp, argv: []const Value) ztcl.Error!?Value {
    const sub = try it.str(argv[1]);
    const eq = std.mem.eql;
    if (eq(u8, sub, "index")) {
        if (argv.len != 3) return it.fail("wrong # args: should be \"{s} index index\"", .{w.path});
        return try posValue(it, try getIndex(w, it, argv[2]));
    }
    if (eq(u8, sub, "compare")) {
        if (argv.len != 5) return it.fail("wrong # args: should be \"{s} compare index1 op index2\"", .{w.path});
        const p = try getIndex(w, it, argv[2]);
        const z = try getIndex(w, it, argv[4]);
        const op = try it.str(argv[3]);
        const o = p.order(z);
        const r = if (eq(u8, op, "<")) o == .lt else if (eq(u8, op, "<=")) o != .gt else if (eq(u8, op, "==")) o == .eq else if (eq(u8, op, ">=")) o != .lt else if (eq(u8, op, ">")) o == .gt else if (eq(u8, op, "!=")) o != .eq else return it.fail("bad comparison operator \"{s}\": must be <, <=, ==, >=, >, or !=", .{op});
        return .{ .int = @intFromBool(r) };
    }
    if (eq(u8, sub, "count")) return try cmdCount(w, it, argv);
    if (eq(u8, sub, "delete")) return try cmdDelete(w, it, argv);
    if (eq(u8, sub, "get")) return try cmdGet(w, it, argv);
    if (eq(u8, sub, "insert")) {
        if (argv.len < 4) return it.fail("wrong # args: should be \"{s} insert index chars ?tagList chars tagList ...?\"", .{w.path});
        const p = try getIndex(w, it, argv[2]);
        if (disabled(w)) return Value.empty;
        try insertChars(w, p, argv[3..], it);
        return Value.empty;
    }
    if (eq(u8, sub, "mark")) return try cmdMark(w, it, argv);
    if (eq(u8, sub, "tag")) return try texttag.cmdTag(w, it, argv);
    if (eq(u8, sub, "replace")) {
        if (argv.len < 5) return it.fail("wrong # args: should be \"{s} replace index1 index2 chars ?tagList chars tagList ...?\"", .{w.path});
        const p = try getIndex(w, it, argv[2]);
        const z = try getIndex(w, it, argv[3]);
        if (z.lt(p)) return it.fail("index \"{s}\" before \"{s}\" in the text", .{ try it.str(argv[3]), try it.str(argv[2]) });
        if (disabled(w)) return Value.empty;
        deleteRange(w, p, z);
        try insertChars(w, data(w).buf.clamp(p), argv[4..], it);
        return Value.empty;
    }
    const later = [_][]const u8{ "bbox", "debug", "dlineinfo", "dump", "edit", "image", "peer", "pendingsync", "scan", "search", "see", "sync", "window", "xview", "yview" };
    for (later) |n| if (eq(u8, sub, n)) return it.fail("the text subcommand \"{s}\" is not in ztk yet", .{n});
    return null;
}

// ---- Paint ----

fn optColor(w: *const Widget, comptime name: []const u8) ?geom.Color {
    const s = options.get(w, name);
    return if (s.set and s.value == .color) s.value.color else null;
}

fn paintText(w: *Widget, b: *scene.Builder) anyerror!void {
    const app = w.app;
    const st = anim.shown(app, w);
    try paint.box(w, b, st);
    const d = data(w);
    const c = content(w);
    if (c.w <= 0 or c.h <= 0) return;
    b.pushClip(c);
    defer b.popClip();
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const ins = d.buf.getMark("insert").?.pos;
    const show_caret = w.state.focus and !disabled(w);
    var line = d.top;
    var y = c.y;
    while (line < d.buf.lineCount() and y < c.y + c.h) : (line += 1) {
        const lay = try layoutLine(w, line, a);
        const s = d.buf.lineText(line);
        const base_y = y + lay.ascent;
        for (lay.segs) |sg| {
            if (sg.attrs.elide or sg.c0 == sg.c1) continue;
            const x = c.x + sg.x;
            if (x > c.x + c.w) break;
            if (sg.attrs.bg) |bg| try b.box(.{ .x = x, .y = y, .w = sg.w, .h = lay.h }, .{ .fill = bg });
            const fg = sg.attrs.fg orelse st.color;
            const by = base_y + sg.attrs.offset * -1;
            try paint.textAt(app, b, x, by, s[sg.b0..sg.b1], sg.attrs.font, fg);
            if (sg.attrs.underline) try b.box(.{ .x = x, .y = by + 1, .w = sg.w, .h = 1 }, .{ .fill = sg.attrs.underline_fg orelse fg });
            if (sg.attrs.overstrike) try b.box(.{ .x = x, .y = by - @divTrunc(sg.ascent * 3, 10), .w = sg.w, .h = 1 }, .{ .fill = sg.attrs.overstrike_fg orelse fg });
        }
        if (show_caret and ins.line == line) {
            const cx = c.x + xInLayout(w, lay, ins);
            const color = optColor(w, "-insertbackground") orelse st.caret_color;
            try b.box(.{ .x = cx, .y = y, .w = @max(int(w, "-insertwidth"), 1), .h = lay.h }, .{ .fill = color });
        }
        y += lay.h;
    }
}

pub fn register(app: *App) !void {
    try app.it.register("text", widget.classCommand(&class));
    try app.classes.put(app.gpa, "text", &class);
}
