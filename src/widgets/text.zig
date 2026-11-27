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
const textview = @import("textview.zig");
const textbind = @import("textbind.zig");
const textsearch = @import("textsearch.zig");
const textembed = @import("textembed.zig");
const undo_mod = @import("../text_widget/undo.zig");
const scroll = @import("../scroll.zig");
const bind = @import("../bind.zig");
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
    .{ .name = "-height", .db_name = "height", .db_class = "Height", .type = .pixels, .default = "24" },
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
    .teardown = textbind.teardown,
    .measure = measure,
    .paint = textview.paintText,
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
    /// The heights of the lines, and the views.
    view: textview.Heights = .{},
    vx: scroll.View = .{},
    vy: scroll.View = .{},
    caret_on: bool = true,
    /// The caret timer: its id and the time that the next blink is due.
    timer: ?u64 = null,
    due_us: i64 = 0,
    /// The undo stacks, the flag of `edit modified`, and a flag that is
    /// true while an undo or a redo edits the text.
    undo: undo_mod.Stack = .{},
    modified: bool = false,
    replaying: bool = false,
    /// True while a typed text replaces the selection, so the delete and
    /// the insert are one compound action.
    compound: bool = false,
    /// The flag of `debug`, and the point and the offsets of `scan mark`.
    debug: bool = false,
    scan_xy: [2]i64 = .{ 0, 0 },
    scan_pos: [2]f64 = .{ 0, 0 },
    /// The embedded windows and images, and the idle call of `-create`.
    embeds: std.ArrayListUnmanaged(*textembed.Embed) = .empty,
    create_idle: ?u64 = null,
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
    textembed.deinit(w);
    d.buf.deinit();
    d.bindings.deinit();
    d.view.deinit(w.app.gpa);
    d.undo.deinit(w.app.gpa);
    scroll.forget(w);
    for (d.cur_tags.items) |n| w.app.gpa.free(n);
    d.cur_tags.deinit(w.app.gpa);
    w.app.gpa.destroy(d);
    w.data = null;
}

pub fn int(w: *const Widget, comptime name: []const u8) i32 {
    const v = options.get(w, name).value;
    const x: i64 = if (v == .int) v.int else if (v == .pixels) v.pixels else 0;
    return @intCast(std.math.clamp(x, -(1 << 20), 1 << 20));
}

pub fn disabled(w: *const Widget) bool {
    const v = options.get(w, "-state").value;
    return v == .word and v.word == 0;
}

fn repaint(w: *Widget) void {
    // The embedded windows move with an edit.
    const lay = data(w).embeds.items.len > 0 and textembed.windowCount(w) > 0;
    w.invalidate(.{ .style = false, .measure = false, .layout = lay, .paint = true });
}

// ---- Geometry ----

pub fn content(w: *Widget) geom.Rect {
    const ins = paint.insets(&w.style);
    const px = int(w, "-padx");
    const py = int(w, "-pady");
    return .{ .x = ins.left + px, .y = ins.top + py, .w = @max(w.geom.w - ins.horizontal() - 2 * px, 0), .h = @max(w.geom.h - ins.vertical() - 2 * py, 0) };
}

pub fn lineH(w: *Widget) i32 {
    return @max(paint.lineHeight(w.app, w.style.font), 1);
}

fn measure(w: *Widget) geom.Size {
    w.app.ensureStyle(w);
    const ins = paint.insets(&w.style);
    const cw = std.math.clamp(int(w, "-width"), 0, 1 << 14) * paint.zeroWidth(w.app, w.style.font);
    const ch = std.math.clamp(int(w, "-height"), 0, 1 << 14) * lineH(w);
    return .{ .w = num.add(cw, ins.horizontal() + 2 * int(w, "-padx")), .h = num.add(ch, ins.vertical() + 2 * int(w, "-pady")) };
}

/// The position that covers a point of the widget.
pub fn nearestChar(w: *Widget, x: i64, y: i64) Pos {
    return textview.nearest(w, x, y);
}

/// The tags or their options changed: the heights of the lines can
/// change.
pub fn tagsChanged(w: *Widget) void {
    data(w).view.width = -1;
    repaint(w);
}

pub fn repaintView(w: *Widget) void {
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
    if (textembed.named(lk.w, name)) |p| return p;
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

fn displayMove(ptr: *anyopaque, op: index.Display, p: Pos, n: i64) Pos {
    const lk: *Lookup = @ptrCast(@alignCast(ptr));
    const w = lk.w;
    w.app.ensureStyle(w);
    const d = data(w);
    return switch (op) {
        .linestart => textview.displayEdge(w, p, false),
        .lineend => textview.displayEdge(w, p, true),
        .lines => blk: {
            if (n == 0) break :blk p;
            const m: i32 = @intCast(std.math.clamp(n, -(1 << 30), 1 << 30));
            // `end` is at x 0 of a display line after the last one.
            if (p.line >= d.buf.lineCount()) {
                if (m > 0) break :blk p;
                const start = textview.displayEdge(w, d.buf.last(), false);
                break :blk if (m == -1) start else clampMove(w, start, m + 1, 0);
            }
            break :blk clampMove(w, p, m, textview.xOf(w, p));
        },
    };
}

/// A move by `m` display lines at the x offset `goal`. A move past the
/// first display line gives 1.0, and a move past the last one gives the
/// end of the last line, as in `wish`.
fn clampMove(w: *Widget, p: Pos, m: i32, goal: i32) Pos {
    const r = textview.moveLines(w, p, m, goal);
    const moved = @abs(textview.displayLines(w, p, r));
    if (moved >= @abs(m)) return r;
    return if (m < 0) .{} else data(w).buf.last();
}

/// The position of an index, or the message of `wish`.
pub fn getIndex(w: *Widget, it: *ztcl.Interp, v: Value) ztcl.Error!Pos {
    const s = try it.str(v);
    var lk: Lookup = .{ .w = w };
    const c: index.Ctx = .{ .buf = &data(w).buf, .ptr = &lk, .named = named, .at = atPoint, .display = displayMove };
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
        p = try insertText(w, p, s);
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
    if (!a.lt(z)) return;
    if (recording(w)) {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(w.app.gpa);
        textembed.getText(w, a, z, &out, w.app.gpa) catch {};
        d.undo.record(w.app.gpa, .delete, a, out.items, autoSep(w), maxUndo(w)) catch {};
    }
    textembed.deleteIn(w, a, z);
    d.buf.delete(a, z);
    textembed.shiftDelete(w, a, z);
    textview.noteEdit(w, a.line, z.line - a.line + 1, 1);
    setModified(w, true);
}

/// Inserts one text at a position before `end`, with the undo record
/// and the flag of `edit modified`, and gives the end of the new text.
pub fn insertText(w: *Widget, p: Pos, s: []const u8) ztcl.Error!Pos {
    const d = data(w);
    if (recording(w)) d.undo.record(w.app.gpa, .insert, p, s, autoSep(w), maxUndo(w)) catch return error.OutOfMemory;
    return insertRaw(w, p, s);
}

/// Inserts a text with no undo record: the edit, the move of the embeds,
/// the heights, and the flag of `edit modified`.
pub fn insertRaw(w: *Widget, p: Pos, s: []const u8) ztcl.Error!Pos {
    const d = data(w);
    const e = d.buf.insert(p, s) catch return error.OutOfMemory;
    textembed.shiftInsert(w, p, e);
    textview.noteEdit(w, p.line, 1, e.line - p.line + 1);
    setModified(w, true);
    return e;
}

/// Deletes from `a` to `z` with the rule for the last newline.
pub fn deleteText(w: *Widget, a: Pos, z: Pos) void {
    deleteRange(w, a, z);
    changed(w);
}

fn recording(w: *Widget) bool {
    const d = data(w);
    const v = options.get(w, "-undo").value;
    return !d.replaying and v == .boolean and v.boolean;
}

fn autoSep(w: *Widget) bool {
    if (data(w).compound) return false;
    const v = options.get(w, "-autoseparators").value;
    return v == .boolean and v.boolean;
}

fn maxUndo(w: *Widget) i64 {
    const v = options.get(w, "-maxundo").value;
    return if (v == .int) v.int else 0;
}

/// Sets the flag of `edit modified`. A change sends `<<Modified>>` as
/// an idle callback.
pub fn setModified(w: *Widget, on: bool) void {
    const d = data(w);
    if (d.modified == on) return;
    d.modified = on;
    const script = std.fmt.allocPrint(w.app.gpa, "if {{[winfo exists {{{s}}}]}} {{event generate {{{s}}} <<Modified>>}}", .{ w.path, w.path }) catch return;
    defer w.app.gpa.free(script);
    _ = w.app.loop.addIdle(script) catch {};
}

/// Applies the last compound action of the undo stack (`redo` false) or
/// of the redo stack, and moves it to the other stack.
pub fn undoStep(w: *Widget, redo: bool) ztcl.Error!bool {
    const d = data(w);
    const gpa = w.app.gpa;
    const from = if (redo) &d.undo.redo else &d.undo.undo;
    const to = if (redo) &d.undo.undo else &d.undo.redo;
    const has = if (redo) d.undo.canRedo() else d.undo.canUndo();
    if (!has) return false;
    const group = undo_mod.Stack.pop(from, gpa) catch return error.OutOfMemory;
    defer gpa.free(group);
    d.replaying = true;
    defer d.replaying = false;
    var at: Pos = .{};
    for (group) |act| {
        const n = buffer.countChars(act.text);
        // The inverse of an insert is a delete, and the inverse of a
        // delete is an insert. A redo applies the action itself.
        const ins = (act.kind == .delete) != redo;
        if (ins) {
            at = try insertText(w, act.pos, act.text);
        } else {
            deleteRange(w, act.pos, d.buf.forward(act.pos, n));
            at = act.pos;
        }
    }
    // The group goes on the other stack in its first order.
    if (to.items.len > 0 and to.items[to.items.len - 1].kind != .sep) to.append(gpa, .{ .kind = .sep }) catch {};
    var k = group.len;
    while (k > 0) {
        k -= 1;
        to.append(gpa, group[k]) catch gpa.free(group[k].text);
    }
    to.append(gpa, .{ .kind = .sep }) catch {};
    d.undo.last = .sep;
    if (at.line >= d.buf.lineCount()) at = d.buf.last();
    d.buf.setMark("insert", at, null) catch {};
    changed(w);
    textview.see(w, at);
    return true;
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

fn cmdScan(w: *Widget, it: *ztcl.Interp, argv: []const Value) ztcl.Error!Value {
    const d = data(w);
    if (argv.len < 5 or argv.len > 6) return it.fail("wrong # args: should be \"{s} scan mark x y\" or \"{s} scan dragto x y ?gain?\"", .{ w.path, w.path });
    const op = try it.str(argv[2]);
    const mark = prefix(op, "mark");
    if (!mark and !prefix(op, "dragto")) return it.fail("bad scan option \"{s}\": must be mark or dragto", .{op});
    if (mark and argv.len != 5) return it.fail("wrong # args: should be \"{s} scan mark x y\" or \"{s} scan dragto x y ?gain?\"", .{ w.path, w.path });
    var xy: [2]i64 = undefined;
    for (0..2) |k| {
        const t = try it.str(argv[3 + k]);
        xy[k] = std.fmt.parseInt(i64, std.mem.trim(u8, t, " "), 0) catch return it.fail("expected integer but got \"{s}\"", .{t});
    }
    if (mark) {
        d.scan_xy = xy;
        d.scan_pos = .{ d.vx.pos, d.vy.pos };
        return Value.empty;
    }
    var gain: i64 = 10;
    if (argv.len == 6) {
        const t = try it.str(argv[5]);
        gain = std.fmt.parseInt(i64, std.mem.trim(u8, t, " "), 0) catch return it.fail("expected integer but got \"{s}\"", .{t});
    }
    // The view moves by the gain times the move of the pointer.
    textview.sync(w);
    const g: f64 = @floatFromInt(gain);
    d.vx.jump(d.vx.clampPos(d.scan_pos[0] - g * @as(f64, @floatFromInt(xy[0] - d.scan_xy[0]))));
    d.vy.jump(d.vy.clampPos(d.scan_pos[1] - g * @as(f64, @floatFromInt(xy[1] - d.scan_xy[1]))));
    repaint(w);
    return Value.empty;
}

const edit_names = [_][]const u8{ "canundo", "canredo", "modified", "redo", "reset", "separator", "undo" };

fn cmdEdit(w: *Widget, it: *ztcl.Interp, argv: []const Value) ztcl.Error!Value {
    const d = data(w);
    const gpa = w.app.gpa;
    if (argv.len < 3) return it.fail("wrong # args: should be \"{s} edit option ?arg ...?\"", .{w.path});
    const sub = try it.str(argv[2]);
    const which = unique(&edit_names, sub) orelse return it.fail("bad edit option \"{s}\": must be canundo, canredo, modified, redo, reset, separator, or undo", .{sub});
    if (which != 2 and argv.len != 3) return it.fail("wrong # args: should be \"{s} edit {s}\"", .{ w.path, edit_names[which] });
    switch (which) {
        0 => return .{ .int = @intFromBool(d.undo.canUndo()) },
        1 => return .{ .int = @intFromBool(d.undo.canRedo()) },
        2 => {
            if (argv.len > 4) return it.fail("wrong # args: should be \"{s} edit modified ?boolean?\"", .{w.path});
            if (argv.len == 3) return .{ .int = @intFromBool(d.modified) };
            const t = try it.str(argv[3]);
            const b = options.parseBool(t) orelse return it.fail("expected boolean value but got \"{s}\"", .{t});
            // A set sends `<<Modified>>` also when the flag keeps its value.
            d.modified = !b;
            setModified(w, b);
            return Value.empty;
        },
        3, 6 => {
            if (!recordingOn(w)) return Value.empty;
            if (!try undoStep(w, which == 3)) return it.fail("nothing to {s}", .{if (which == 3) "redo" else "undo"});
            return Value.empty;
        },
        4 => {
            d.undo.reset(gpa);
            return Value.empty;
        },
        else => {
            d.undo.separator(gpa) catch return error.OutOfMemory;
            return Value.empty;
        },
    }
}

fn recordingOn(w: *Widget) bool {
    const v = options.get(w, "-undo").value;
    return v == .boolean and v.boolean;
}

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
            const lo = if (z.lt(p)) z else p;
            const hi = if (z.lt(p)) p else z;
            var n: i64 = @intCast(d.buf.charsBetween(lo, hi));
            // `-chars` and `-displaychars` leave out the embeds.
            if (which < 2) for (d.embeds.items) |e| {
                if (!e.pos.lt(lo) and e.pos.lt(hi)) n -= 1;
            };
            return if (z.lt(p)) -n else n;
        },
        3 => return textview.displayLines(w, p, z),
        5 => return @as(i64, z.line) - @as(i64, p.line),
        7 => {
            w.app.ensureStyle(w);
            return @as(i64, textview.xOf(w, z)) - textview.xOf(w, p);
        },
        8 => {
            w.app.ensureStyle(w);
            return textview.yOf(w, z) - textview.yOf(w, p);
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
        if (p.lt(z)) try textembed.getText(w, p, z, &out, a);
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
    if (eq(u8, sub, "xview") or eq(u8, sub, "yview")) return try textview.cmdView(w, it, argv, if (sub[0] == 'x') 0 else 1);
    if (eq(u8, sub, "see")) {
        if (argv.len != 3) return it.fail("wrong # args: should be \"{s} see index\"", .{w.path});
        textview.see(w, try getIndex(w, it, argv[2]));
        return Value.empty;
    }
    if (eq(u8, sub, "bbox") or eq(u8, sub, "dlineinfo")) {
        if (argv.len != 3) return it.fail("wrong # args: should be \"{s} {s} index\"", .{ w.path, sub });
        return try textview.cmdBox(w, it, try getIndex(w, it, argv[2]), sub[0] == 'd');
    }
    if (eq(u8, sub, "sync")) return Value.empty;
    if (eq(u8, sub, "edit")) return try cmdEdit(w, it, argv);
    if (eq(u8, sub, "search")) {
        if (argv.len < 4) return it.fail("wrong # args: should be \"{s} search ?switches? pattern index ?stopIndex?\"", .{w.path});
        return try textsearch.cmdSearch(w, it, argv);
    }
    if (eq(u8, sub, "dump")) return try textsearch.cmdDump(w, it, argv);
    if (eq(u8, sub, "debug")) {
        const d = data(w);
        if (argv.len > 3) return it.fail("wrong # args: should be \"{s} debug boolean\"", .{w.path});
        if (argv.len == 2) return .{ .int = @intFromBool(d.debug) };
        const t = try it.str(argv[2]);
        d.debug = options.parseBool(t) orelse return it.fail("expected boolean value but got \"{s}\"", .{t});
        return Value.empty;
    }
    if (eq(u8, sub, "scan")) return try cmdScan(w, it, argv);
    if (eq(u8, sub, "pendingsync")) return .{ .int = 0 };
    if (eq(u8, sub, "window")) return try textembed.cmdEmbed(w, it, argv, .window);
    if (eq(u8, sub, "image")) return try textembed.cmdEmbed(w, it, argv, .image);
    if (eq(u8, sub, "peer")) return try cmdPeer(w, it, argv);
    return null;
}

/// `peer`: `names` gives an empty list, and `create` gives the message
/// of a limit, since ztk has no peers.
fn cmdPeer(w: *Widget, it: *ztcl.Interp, argv: []const Value) ztcl.Error!Value {
    if (argv.len < 3) return it.fail("wrong # args: should be \"{s} peer option ?arg ...?\"", .{w.path});
    const sub = try it.str(argv[2]);
    const which = unique(&.{ "create", "names" }, sub) orelse return it.fail("bad peer option \"{s}\": must be create or names", .{sub});
    if (which == 1) {
        if (argv.len != 3) return it.fail("wrong # args: should be \"{s} peer names\"", .{w.path});
        return Value.empty;
    }
    if (argv.len < 4) return it.fail("wrong # args: should be \"{s} peer create pathName ?-option value ...?\"", .{w.path});
    return it.fail("the text subcommand \"peer create\" is not in ztk", .{});
}

pub fn register(app: *App) !void {
    try app.it.register("text", widget.classCommand(&class));
    try app.classes.put(app.gpa, "text", &class);
    try textbind.register(app);
}
