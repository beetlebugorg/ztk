//! The class bindings of `Text`, the caret blink, and the input method.
//!
//! The bindings call `::ztk::priv::text action window ?args?`. Each
//! action follows the bindings of `text.tcl` of Tk 8.6 as the manual
//! page `text.n` gives them: a click puts the mark `insert` at the
//! character under the pointer and sets the mark `tk::anchor1`, a drag
//! and a click with Shift select from the anchor, a double click selects
//! a word segment of UAX #29, and a triple click selects a line.
//! Backspace and Delete remove one grapheme cluster. The arrow keys move by
//! grapheme clusters (UAX #29) and by display lines, Home and End go to the ends of the
//! display line, and Prior and Next move by the lines of a page. Shift
//! with a move selects from the anchor. A typed character replaces the
//! selection when the mark `insert` is in it.
//!
//! The selection is the tag `sel`. A change of it by the user sends
//! `<<Selection>>`. With `-autoseparators`, a click and a move of the
//! caret by a key add a separator to the undo stack, so a run of typed
//! text at one place is one compound action.
//!
//! The caret blinks with `-insertontime` and `-insertofftime` while the
//! widget has the focus, and it shows at once after each key. The text
//! of an input method shows at the caret with an underline until the
//! method commits it.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const widget = @import("../widget.zig");
const options = @import("../options.zig");
const clipboard = @import("../clipboard.zig");
const App = @import("../app.zig").App;
const buffer = @import("../text_widget/buffer.zig");
const index = @import("../text_widget/index.zig");
const text = @import("text.zig");
const textview = @import("textview.zig");
const Widget = widget.Widget;
const Value = ztcl.Value;
const Pos = buffer.Pos;

const anchor_mark = "tk::anchor1";

const Action = enum { press, drag, shift, double, triple, move, insert, backspace, delete, copy, cut, paste, clear, selectall, selectnone, undo, redo, focusin, focusout, separator };

const Move = enum { left, right, up, down, home, end, wordleft, wordright, docstart, docend, pageup, pagedown };

fn normal(w: *const Widget) bool {
    return !text.disabled(w);
}

fn insertPos(w: *Widget) Pos {
    return text.data(w).buf.getMark("insert").?.pos;
}

fn setInsert(w: *Widget, p0: Pos) void {
    const d = text.data(w);
    var p = p0;
    if (p.line >= d.buf.lineCount()) p = d.buf.last();
    d.buf.setMark("insert", p, null) catch {};
}

fn selTag(w: *Widget) *@import("../text_widget/tags.zig").Tag {
    return text.data(w).buf.tags.find("sel").?;
}

fn selRange(w: *Widget) ?[2]Pos {
    const r = selTag(w).ranges.items;
    if (r.len == 0) return null;
    return .{ r[0].a, r[r.len - 1].z };
}

/// Sets the selection to the characters between two positions.
fn setSel(w: *Widget, a: Pos, z: Pos) void {
    const gpa = w.app.gpa;
    const tag = selTag(w);
    const had = tag.ranges.items.len > 0;
    tag.ranges.clearRetainingCapacity();
    const lo = if (z.lt(a)) z else a;
    const hi = if (z.lt(a)) a else z;
    if (lo.lt(hi)) tag.add(gpa, lo, hi) catch {};
    if (had or tag.ranges.items.len > 0) selectionChanged(w);
    text.tagsChanged(w);
}

/// Queues `<<Selection>>` for a change of the selection.
pub fn selectionChanged(w: *Widget) void {
    const script = std.fmt.allocPrint(w.app.gpa, "if {{[winfo exists {{{s}}}]}} {{event generate {{{s}}} <<Selection>>}}", .{ w.path, w.path }) catch return;
    defer w.app.gpa.free(script);
    _ = w.app.loop.addIdle(script) catch {};
}

fn insideSel(w: *Widget, p: Pos) bool {
    const r = selRange(w) orelse return false;
    return !p.lt(r[0]) and !r[1].lt(p);
}

fn separator(w: *Widget) void {
    const v = options.get(w, "-autoseparators").value;
    if (v == .boolean and v.boolean) text.data(w).undo.separator(w.app.gpa) catch {};
}

fn anchorPos(w: *Widget) Pos {
    const d = text.data(w);
    return if (d.buf.getMark(anchor_mark)) |m| m.pos else insertPos(w);
}

fn setAnchor(w: *Widget, p: Pos) void {
    text.data(w).buf.setMark(anchor_mark, p, .left) catch {};
}

/// The goal x of Up and Down: it stays while the keys repeat.
var goal_widget: ?*Widget = null;
var goal_x: i32 = 0;

fn moved(w: *Widget, p: Pos, select: bool) void {
    if (select) {
        setSel(w, anchorPos(w), p);
    } else {
        if (selTag(w).ranges.items.len > 0) setSel(w, p, p);
        setAnchor(w, p);
    }
    setInsert(w, p);
    textview.see(w, p);
}

fn wordLeft(buf: *const buffer.Buffer, p0: Pos) Pos {
    var p = buf.backward(p0, 1);
    // Skip the characters of no word, then go to the start of the word.
    while (p.lt(p0) and !(p.line == 0 and p.ch == 0)) {
        const c = buf.charAt(p);
        if (c == '_' or (c < 0x80 and std.ascii.isAlphanumeric(@intCast(c))) or c >= 0xC0) break;
        p = buf.backward(p, 1);
    }
    return index.wordStart(buf, p);
}

fn wordRight(buf: *const buffer.Buffer, p0: Pos) Pos {
    var p = p0;
    const end = buf.last();
    while (p.lt(end)) {
        const c = buf.charAt(p);
        if (c == '_' or (c < 0x80 and std.ascii.isAlphanumeric(@intCast(c))) or c >= 0xC0) break;
        p = buf.forward(p, 1);
    }
    return index.wordEnd(buf, p);
}

fn doMove(w: *Widget, how: Move, select: bool) void {
    const d = text.data(w);
    const p = insertPos(w);
    const buf = &d.buf;
    if (how != .up and how != .down and how != .pageup and how != .pagedown) goal_widget = null;
    const np: Pos = switch (how) {
        .left => buf.prevCluster(p),
        .right => blk: {
            const q = buf.nextCluster(p);
            break :blk if (q.line >= buf.lineCount()) buf.last() else q;
        },
        .home => textview.displayEdge(w, p, false),
        .end => textview.displayEdge(w, p, true),
        .wordleft => wordLeft(buf, p),
        .wordright => wordRight(buf, p),
        .docstart => .{},
        .docend => buf.last(),
        .up, .down, .pageup, .pagedown => blk: {
            if (goal_widget != w) {
                goal_widget = w;
                goal_x = textview.xOf(w, p);
            }
            const n: i32 = switch (how) {
                .up => -1,
                .down => 1,
                .pageup => -textview.pageLines(w),
                else => textview.pageLines(w),
            };
            break :blk textview.moveLines(w, p, n, goal_x);
        },
    };
    separator(w);
    moved(w, np, select);
}

fn deleteSel(w: *Widget) bool {
    const r = selRange(w) orelse return false;
    text.deleteText(w, r[0], r[1]);
    selectionChanged(w);
    return true;
}

/// Runs an edit through the command of the widget, for a widget whose
/// command an app wrapped: `path insert insert text` or `path delete`.
fn viaCommand(w: *Widget, words: []const Value) ztcl.Error!void {
    const it = w.app.it;
    const a = it.alloc();
    const all = try a.alloc(Value, words.len + 1);
    all[0] = .{ .str = try a.dupe(u8, w.path) };
    @memcpy(all[1..], words);
    _ = try it.eval(try it.str(try ztcl.value.newList(a, all)));
}

fn insertTyped(w: *Widget, s: []const u8) ztcl.Error!void {
    if (s.len == 0 or !normal(w)) return;
    // A control character of a key with Control has no text to insert.
    if (s.len == 1 and s[0] < 0x20 and s[0] != '\n' and s[0] != '\t') return;
    if (widget.commandWrapped(w)) {
        if (insideSel(w, insertPos(w))) try viaCommand(w, &.{ .{ .str = "delete" }, .{ .str = "sel.first" }, .{ .str = "sel.last" } });
        try viaCommand(w, &.{ .{ .str = "insert" }, .{ .str = "insert" }, .{ .str = s } });
        if (w.alive()) textview.see(w, insertPos(w));
        return;
    }
    const d = text.data(w);
    // A typed text that replaces the selection is one compound action
    // with the delete, as `tk::TextInsert` makes it.
    const compound = insideSel(w, insertPos(w));
    if (compound) {
        separator(w);
        d.compound = true;
        _ = deleteSel(w);
    }
    defer if (compound) {
        d.compound = false;
        separator(w);
    };
    const p = insertPos(w);
    _ = try text.insertText(w, if (p.line >= d.buf.lineCount()) d.buf.last() else p, s);
    text.repaintView(w);
    textview.see(w, insertPos(w));
}

fn cmdText(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    app.enter();
    defer app.leave();
    if (argv.len < 3) return it.wrongArgs("::ztk::priv::text action window ?arg ...?");
    const act = std.meta.stringToEnum(Action, try it.str(argv[1])) orelse return it.fail("bad action \"{s}\"", .{try it.str(argv[1])});
    const w = app.find(try it.str(argv[2])) orelse return Value.empty;
    if (w.class != &text.class) return Value.empty;
    const d = text.data(w);
    const a = it.alloc();
    const xy: [2]i64 = if (argv.len >= 5) .{
        std.fmt.parseInt(i64, try it.str(argv[3]), 10) catch 0,
        std.fmt.parseInt(i64, try it.str(argv[4]), 10) catch 0,
    } else .{ 0, 0 };
    switch (act) {
        .press => {
            const p = text.nearestChar(w, xy[0], xy[1]);
            separator(w);
            if (selTag(w).ranges.items.len > 0) setSel(w, p, p);
            setAnchor(w, p);
            setInsert(w, p);
            _ = try it.eval(try std.fmt.allocPrint(a, "focus {{{s}}}", .{w.path}));
        },
        .drag, .shift => {
            const p = text.nearestChar(w, xy[0], xy[1]);
            setSel(w, anchorPos(w), p);
            setInsert(w, p);
            textview.see(w, p);
        },
        .double => {
            const p = text.nearestChar(w, xy[0], xy[1]);
            const r = d.buf.wordSegment(p);
            const s = r[0];
            var e = r[1];
            if (e.line >= d.buf.lineCount()) e = d.buf.last();
            setAnchor(w, s);
            setSel(w, s, e);
            setInsert(w, e);
        },
        .triple => {
            const p = text.nearestChar(w, xy[0], xy[1]);
            const s: Pos = .{ .line = p.line, .ch = 0 };
            const e = d.buf.forward(.{ .line = p.line, .ch = d.buf.lineChars(p.line) }, 1);
            setAnchor(w, s);
            setSel(w, s, e);
            setInsert(w, if (e.line >= d.buf.lineCount()) d.buf.last() else e);
        },
        .move => {
            if (argv.len != 5) return it.wrongArgs("::ztk::priv::text move window how select");
            const how = std.meta.stringToEnum(Move, try it.str(argv[3])) orelse return Value.empty;
            doMove(w, how, std.mem.eql(u8, try it.str(argv[4]), "1"));
        },
        .insert => {
            if (argv.len != 4) return it.wrongArgs("::ztk::priv::text insert window chars");
            try insertTyped(w, try it.str(argv[3]));
        },
        .backspace, .delete => if (normal(w)) {
            if (widget.commandWrapped(w)) {
                if (insideSel(w, insertPos(w))) {
                    try viaCommand(w, &.{ .{ .str = "delete" }, .{ .str = "sel.first" }, .{ .str = "sel.last" } });
                } else if (act == .backspace) {
                    try viaCommand(w, &.{ .{ .str = "delete" }, .{ .str = "insert-1graphemes" }, .{ .str = "insert" } });
                } else try viaCommand(w, &.{ .{ .str = "delete" }, .{ .str = "insert" }, .{ .str = "insert+1graphemes" } });
                if (w.alive()) textview.see(w, insertPos(w));
                return Value.empty;
            }
            if (insideSel(w, insertPos(w)) and deleteSel(w)) {} else {
                const p = insertPos(w);
                if (act == .backspace) {
                    if (p.line != 0 or p.ch != 0) text.deleteText(w, d.buf.prevCluster(p), p);
                } else text.deleteText(w, p, d.buf.nextCluster(p));
            }
            textview.see(w, insertPos(w));
        },
        .copy, .cut => if (selRange(w)) |r| {
            var out: std.ArrayList(u8) = .empty;
            try d.buf.get(r[0], r[1], &out, a);
            clipboard.setText(app, out.items) catch return error.OutOfMemory;
            if (act == .cut and normal(w)) _ = deleteSel(w);
        },
        .paste => if (normal(w)) {
            const s = (clipboard.read(app, a, "STRING") catch return error.OutOfMemory) orelse return Value.empty;
            separator(w);
            // The paste of Tk on a windowing system other than x11 replaces the selection.
            _ = deleteSel(w);
            try insertTyped(w, s);
            separator(w);
        },
        .clear => if (normal(w)) {
            _ = deleteSel(w);
        },
        .selectall => {
            setSel(w, .{}, d.buf.end());
        },
        .selectnone => {
            setSel(w, .{}, .{});
        },
        .undo, .redo => if (normal(w)) {
            const v = options.get(w, "-undo").value;
            if (v == .boolean and v.boolean) _ = try text.undoStep(w, act == .redo);
        },
        .separator => separator(w),
        .focusin => restartCaret(w),
        .focusout => {
            cancelTimer(w);
            text.repaintView(w);
        },
    }
    if (act != .focusout and w.alive()) restartCaret(w);
    return Value.empty;
}

// ---- The caret timer ----

fn cancelTimer(w: *Widget) void {
    const d = text.data(w);
    if (d.timer) |id| _ = w.app.loop.cancel(id);
    d.timer = null;
}

fn timeOption(w: *const Widget, comptime name: []const u8, default: i64) i64 {
    const v = options.get(w, name).value;
    return if (v == .int) v.int else default;
}

fn blink(ctx: ?*anyopaque) void {
    const w: *Widget = @ptrCast(@alignCast(ctx.?));
    const d = text.data(w);
    d.timer = null;
    if (!w.state.focus or !normal(w)) return;
    d.caret_on = !d.caret_on;
    text.repaintView(w);
    // The next blink counts from the time that this one was due.
    armTimer(w, d.due_us);
}

fn armTimer(w: *Widget, from_us: ?i64) void {
    cancelTimer(w);
    const d = text.data(w);
    if (!w.alive() or !w.state.focus or !normal(w)) return;
    const off = timeOption(w, "-insertofftime", 300);
    if (off <= 0) return;
    const interval = (if (d.caret_on) timeOption(w, "-insertontime", 600) else off) *| 1000;
    const clock = w.app.loop.clock;
    const now = clock.now(clock.ctx);
    d.due_us = (from_us orelse now) +| interval;
    d.timer = w.app.loop.addNative(@max(d.due_us -| now, 0), blink, w) catch null;
}

/// Shows the caret and starts the on time again.
pub fn restartCaret(w: *Widget) void {
    text.data(w).caret_on = true;
    armTimer(w, null);
    text.repaintView(w);
}

pub fn teardown(w: *Widget) void {
    cancelTimer(w);
    if (goal_widget == w) goal_widget = null;
}

const bindings =
    \\bind Text <Button-1> {::ztk::priv::text press %W %x %y}
    \\bind Text <B1-Motion> {::ztk::priv::text drag %W %x %y}
    \\bind Text <Shift-Button-1> {::ztk::priv::text shift %W %x %y}
    \\bind Text <Double-Button-1> {::ztk::priv::text double %W %x %y}
    \\bind Text <Triple-Button-1> {::ztk::priv::text triple %W %x %y}
    \\bind Text <MouseWheel> {%W yview scroll [expr {-%D / 40.0}] units}
    \\bind Text <Shift-MouseWheel> {%W xview scroll [expr {-%D / 30.0}] units}
    \\bind Text <Key-Left> {::ztk::priv::text move %W left 0}
    \\bind Text <Key-Right> {::ztk::priv::text move %W right 0}
    \\bind Text <Key-Up> {::ztk::priv::text move %W up 0}
    \\bind Text <Key-Down> {::ztk::priv::text move %W down 0}
    \\bind Text <Shift-Key-Left> {::ztk::priv::text move %W left 1}
    \\bind Text <Shift-Key-Right> {::ztk::priv::text move %W right 1}
    \\bind Text <Shift-Key-Up> {::ztk::priv::text move %W up 1}
    \\bind Text <Shift-Key-Down> {::ztk::priv::text move %W down 1}
    \\bind Text <Control-Key-Left> {::ztk::priv::text move %W wordleft 0}
    \\bind Text <Control-Key-Right> {::ztk::priv::text move %W wordright 0}
    \\bind Text <Control-Shift-Key-Left> {::ztk::priv::text move %W wordleft 1}
    \\bind Text <Control-Shift-Key-Right> {::ztk::priv::text move %W wordright 1}
    \\bind Text <Key-Home> {::ztk::priv::text move %W home 0}
    \\bind Text <Key-End> {::ztk::priv::text move %W end 0}
    \\bind Text <Shift-Key-Home> {::ztk::priv::text move %W home 1}
    \\bind Text <Shift-Key-End> {::ztk::priv::text move %W end 1}
    \\bind Text <Control-Key-Home> {::ztk::priv::text move %W docstart 0}
    \\bind Text <Control-Key-End> {::ztk::priv::text move %W docend 0}
    \\bind Text <Control-Shift-Key-Home> {::ztk::priv::text move %W docstart 1}
    \\bind Text <Control-Shift-Key-End> {::ztk::priv::text move %W docend 1}
    \\bind Text <Key-Prior> {::ztk::priv::text move %W pageup 0}
    \\bind Text <Key-Next> {::ztk::priv::text move %W pagedown 0}
    \\bind Text <Shift-Key-Prior> {::ztk::priv::text move %W pageup 1}
    \\bind Text <Shift-Key-Next> {::ztk::priv::text move %W pagedown 1}
    \\bind Text <Key-BackSpace> {::ztk::priv::text backspace %W}
    \\bind Text <Key-Delete> {::ztk::priv::text delete %W}
    \\bind Text <Key-Return> {::ztk::priv::text insert %W \n; ::ztk::priv::text separator %W}
    \\bind Text <Key-Tab> {::ztk::priv::text insert %W \t; break}
    \\bind Text <Control-Key-Tab> {focus [tk_focusNext %W]}
    \\bind Text <Control-Shift-Key-Tab> {focus [tk_focusPrev %W]}
    \\bind Text <Control-Key-x> {event generate %W <<Cut>>}
    \\bind Text <Control-Key-c> {event generate %W <<Copy>>}
    \\bind Text <Control-Key-v> {event generate %W <<Paste>>}
    \\bind Text <Control-Key-z> {event generate %W <<Undo>>}
    \\bind Text <Control-Key-Z> {event generate %W <<Redo>>}
    \\bind Text <Control-Key-y> {event generate %W <<Redo>>}
    \\bind Text <Control-Key-a> {::ztk::priv::text move %W home 0}
    \\bind Text <Control-Key-e> {::ztk::priv::text move %W end 0}
    \\bind Text <Control-Key-slash> {event generate %W <<SelectAll>>}
    \\bind Text <Control-Key-backslash> {event generate %W <<SelectNone>>}
    \\bind Text <<Cut>> {::ztk::priv::text cut %W}
    \\bind Text <<Copy>> {::ztk::priv::text copy %W}
    \\bind Text <<Paste>> {::ztk::priv::text paste %W}
    \\bind Text <<Clear>> {::ztk::priv::text clear %W}
    \\bind Text <<SelectAll>> {::ztk::priv::text selectall %W}
    \\bind Text <<SelectNone>> {::ztk::priv::text selectnone %W}
    \\bind Text <<Undo>> {::ztk::priv::text undo %W}
    \\bind Text <<Redo>> {::ztk::priv::text redo %W}
    \\bind Text <Key> {::ztk::priv::text insert %W %A}
    \\bind Text <Control-Key> {# no edit}
    \\bind Text <Alt-Key> {# no edit}
    \\bind Text <Key-Escape> {# no edit}
    \\bind Text <FocusIn> {::ztk::priv::text focusin %W}
    \\bind Text <FocusOut> {::ztk::priv::text focusout %W}
;

pub fn register(app: *App) !void {
    try app.it.register("ztk::priv::text", cmdText);
    _ = try app.it.eval(bindings);
}
