//! The entry class. It edits one line of left-to-right text. The edit
//! model (`src/text/edit.zig`) holds the text, the caret, and the
//! selection. The class bindings on the tag `Entry` call
//! `::ztk::priv::entry`, so each key goes through the dispatch and the
//! bindings. `-textvariable` links the text to a global variable with a
//! script trace and a flag that stops the loop when the entry writes. The
//! entry keeps a scroll offset `left` so that the caret stays inside the
//! content rectangle. The caret blinks with a native timer of the loop,
//! and only while the entry has the focus.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const num = @import("../num.zig");
const ztcl = @import("ztcl");
const geom = @import("../geom.zig");
const widget = @import("../widget.zig");
const anim = @import("../anim.zig");
const options = @import("../options.zig");
const paint = @import("../paint.zig");
const scene = @import("../scene.zig");
const focus = @import("../focus.zig");
const shape = @import("../text/shape.zig");
const font_mod = @import("../text/font.zig");
const edit_mod = @import("../text/edit.zig");
const loop_mod = @import("../loop.zig");
const App = @import("../app.zig").App;
const Spec = options.Spec;
const Widget = widget.Widget;
const Value = ztcl.Value;

const state_words = [_][]const u8{ "disabled", "normal", "readonly" };

/// A subset of the options of `wish`, in the order of `wish`.
pub const specs = [_]Spec{
    .{ .name = "-background", .db_name = "background", .db_class = "Background", .type = .color, .default = "#ffffff", .from_style = true, .style_prop = .background },
    .{ .name = "-bd", .type = .synonym, .target = "-borderwidth" },
    .{ .name = "-bg", .type = .synonym, .target = "-background" },
    .{ .name = "-borderwidth", .db_name = "borderWidth", .db_class = "BorderWidth", .type = .pixels, .default = "1", .from_style = true, .style_prop = .border_width },
    .{ .name = "-cursor", .db_name = "cursor", .db_class = "Cursor", .type = .string, .default = "xterm" },
    .{ .name = "-exportselection", .db_name = "exportSelection", .db_class = "ExportSelection", .type = .boolean, .default = "1" },
    .{ .name = "-fg", .type = .synonym, .target = "-foreground" },
    .{ .name = "-font", .db_name = "font", .db_class = "Font", .type = .font, .default = "TkTextFont" },
    .{ .name = "-foreground", .db_name = "foreground", .db_class = "Foreground", .type = .color, .default = "#000000", .from_style = true },
    .{ .name = "-insertofftime", .db_name = "insertOffTime", .db_class = "OffTime", .type = .int, .default = "300" },
    .{ .name = "-insertontime", .db_name = "insertOnTime", .db_class = "OnTime", .type = .int, .default = "600" },
    .{ .name = "-insertwidth", .db_name = "insertWidth", .db_class = "InsertWidth", .type = .pixels, .default = "2" },
    .{ .name = "-justify", .db_name = "justify", .db_class = "Justify", .type = .justify, .default = "left" },
    .{ .name = "-relief", .db_name = "relief", .db_class = "Relief", .type = .relief, .default = "sunken", .from_style = true },
    .{ .name = "-selectbackground", .db_name = "selectBackground", .db_class = "Foreground", .type = .color, .default = "#c3c3c3" },
    .{ .name = "-selectforeground", .db_name = "selectForeground", .db_class = "Background", .type = .color, .default = "#000000" },
    .{ .name = "-show", .db_name = "show", .db_class = "Show", .type = .string, .allow_empty = true },
    .{ .name = "-state", .db_name = "state", .db_class = "State", .type = .state, .default = "normal", .words = &state_words },
    .{ .name = "-takefocus", .db_name = "takeFocus", .db_class = "TakeFocus", .type = .string, .allow_empty = true },
    .{ .name = "-textvariable", .db_name = "textVariable", .db_class = "Variable", .type = .variable, .allow_empty = true },
    .{ .name = "-width", .db_name = "width", .db_class = "Width", .type = .int, .default = "20" },
};

const subcommand_list = "bbox, cget, configure, delete, get, icursor, index, insert, scan, selection, validate, or xview";

pub const class: widget.Class = .{
    .command = "entry",
    .tk_class = "Entry",
    .focusable = true,
    .specs = &specs,
    .init = init,
    .deinit = deinit,
    .configured = configured,
    .teardown = teardown,
    .retrace = retrace,
    .trace_command = trace_command,
    .traced_var = tracedVar,
    .measure = measure,
    .paint = paintEntry,
    .subcommand = subcommand,
    .bad_option_list = subcommand_list,
};

const Data = struct {
    edit: edit_mod.Edit,
    /// The scroll offset of the text in logical pixels.
    left: i32 = 0,
    caret_on: bool = true,
    timer: ?loop_mod.TimerId = null,
    /// The time of the next blink, in microseconds on the clock of the loop.
    due_us: i64 = 0,
    /// The traced variable, or empty.
    var_name: []u8 = &.{},
    /// True while the entry writes the variable.
    writing: bool = false,
};

const trace_command = "ztk::priv::entry_var";

fn tracedVar(w: *const Widget) []const u8 {
    return dataOf(w).var_name;
}

fn dataOf(w: *const Widget) *Data {
    return @ptrCast(@alignCast(w.data.?));
}

fn init(w: *Widget) anyerror!void {
    const d = try w.app.gpa.create(Data);
    d.* = .{ .edit = edit_mod.Edit.init(w.app.gpa) };
    w.data = d;
}

fn traceWords(w: *const Widget, d: *const Data, verb: []const u8) [6]Value {
    const a = w.app.it.alloc();
    const script = widget.traceScript(a, trace_command, w.path);
    return .{ .{ .str = "trace" }, .{ .str = verb }, .{ .str = "variable" }, .{ .str = d.var_name }, .{ .str = "write" }, .{ .str = script } };
}

fn deinit(w: *Widget) void {
    const gpa = w.app.gpa;
    const d = dataOf(w);
    gpa.free(d.var_name);
    d.edit.deinit();
    gpa.destroy(d);
    w.data = null;
}

/// Removes the timer and the trace when the widget is deleted. A new
/// widget with the same path adds a trace with the same text.
fn teardown(w: *Widget) void {
    const d = dataOf(w);
    cancelTimer(w, d);
    if (d.var_name.len > 0) {
        const words = traceWords(w, d, "remove");
        _ = w.app.callTrace(&words) catch {};
    }
    w.app.gpa.free(d.var_name);
    d.var_name = &.{};
}

fn isNormal(w: *const Widget) bool {
    const st = options.get(w, "-state").value;
    return st == .word and st.word == 1;
}

fn isReadonly(w: *const Widget) bool {
    const st = options.get(w, "-state").value;
    return st == .word and st.word == 2;
}

// ---- The variable ----

fn writeVar(w: *Widget) void {
    const d = dataOf(w);
    if (d.var_name.len == 0) return;
    const it = w.app.it;
    // A write trace can delete the widget and free the name and the text.
    const name = it.alloc().dupe(u8, d.var_name) catch return;
    const value = it.alloc().dupe(u8, d.edit.text()) catch return;
    d.writing = true;
    defer d.writing = false;
    it.setVar(name, .{ .str = value }) catch {};
}

fn readVar(w: *Widget) void {
    const d = dataOf(w);
    const it = w.app.it;
    // A read trace can delete the widget and free the name.
    const name = it.alloc().dupe(u8, d.var_name) catch return;
    const v = (it.getVarOpt(name) catch null) orelse return;
    if (w.life == .dead) return;
    const s = it.str(v) catch return;
    if (std.mem.eql(u8, s, d.edit.text())) return;
    d.edit.setText(s) catch return;
    changed(w);
}

pub fn cmdVar(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    app.enter();
    defer app.leave();
    if (argv.len < 2) return Value.empty;
    const w = app.find(try it.str(argv[1])) orelse return Value.empty;
    if (w.class.measure != measure) return Value.empty;
    if (dataOf(w).writing) return Value.empty;
    readVar(w);
    return Value.empty;
}

/// Adds the trace again after a compact of the interpreter.
fn retrace(w: *Widget) void {
    const d = dataOf(w);
    if (d.var_name.len == 0) return;
    const rm = traceWords(w, d, "remove");
    _ = w.app.callTrace(&rm) catch {};
    const add = traceWords(w, d, "add");
    _ = w.app.callTrace(&add) catch {};
}

fn configured(w: *Widget, changed_list: []const usize) ztcl.Error!void {
    const app = w.app;
    const d = dataOf(w);
    for (changed_list) |i| {
        // A variable trace of an earlier option can delete the widget.
        if (w.life == .dead) return;
        const name = w.class.specs[i].name;
        if (std.mem.eql(u8, name, "-state")) {
            w.state.disabled = w.opts[i].value == .word and w.opts[i].value.word == 0;
            w.state.readonly = isReadonly(w);
            if (!isNormal(w)) cancelTimer(w, d);
        } else if (std.mem.eql(u8, name, "-textvariable")) {
            // Tk reads the variable in the global namespace, whatever the caller is.
            const new_name: []u8 = if (w.opts[i].text.len > 0) try widget.globalVar(app.gpa, w.opts[i].text) else &.{};
            defer if (new_name.len > 0) app.gpa.free(new_name);
            if (std.mem.eql(u8, new_name, d.var_name)) continue;
            if (d.var_name.len > 0) {
                const words = traceWords(w, d, "remove");
                _ = app.callTrace(&words) catch {};
            }
            app.gpa.free(d.var_name);
            d.var_name = &.{};
            if (new_name.len > 0) {
                d.var_name = try app.gpa.dupe(u8, new_name);
                // Each step below can run a trace that deletes the widget.
                const missing = (try app.it.getVarOpt(new_name)) == null;
                if (w.life == .dead) return;
                if (missing) writeVar(w) else readVar(w);
                if (w.life == .dead) return;
                const words = traceWords(w, d, "add");
                _ = try app.callTrace(&words);
            }
        }
    }
}

// ---- Size and paint ----

fn measure(w: *Widget) geom.Size {
    const app = w.app;
    app.ensureStyle(w);
    const st = &w.style;
    const wd = options.get(w, "-width").value;
    var chars: i32 = 20;
    if (wd == .int and wd.int > 0) chars = @intCast(@min(wd.int, 10000));
    const ins = paint.insets(st);
    return .{
        .w = @max(num.add(num.px(@as(i64, chars) * paint.zeroWidth(app, st.font)), ins.horizontal()), st.min_width),
        .h = @max(num.add(paint.lineHeight(app, st.font), ins.vertical()), st.min_height),
    };
}

/// The text that the entry draws: the real text, or the show character repeated.
fn shownText(w: *const Widget, a: std.mem.Allocator) ![]const u8 {
    const d = dataOf(w);
    const show = options.get(w, "-show");
    if (!show.set or show.text.len == 0) return d.edit.text();
    const n = std.unicode.utf8ByteSequenceLength(show.text[0]) catch 1;
    const ch = show.text[0..@min(n, show.text.len)];
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < d.edit.len()) : (i += 1) try out.appendSlice(a, ch);
    return out.toOwnedSlice(a);
}

fn scaleOne(w: *Widget) ?*font_mod.Font {
    return w.app.fonts.get(w.style.font, 1) catch null;
}

/// The byte offset in the shown text of a character index.
fn shownByte(w: *const Widget, shown: []const u8, index: usize) usize {
    const d = dataOf(w);
    if (shown.ptr == d.edit.text().ptr and shown.len == d.edit.text().len) return d.edit.byteOf(index);
    const show = options.get(w, "-show");
    const n = std.unicode.utf8ByteSequenceLength(show.text[0]) catch 1;
    return @min(index * @min(n, show.text.len), shown.len);
}

fn changed(w: *Widget) void {
    w.invalidate(.{ .style = false, .measure = false, .layout = false, .paint = true });
}

fn paintEntry(w: *Widget, b: *scene.Builder) anyerror!void {
    const app = w.app;
    const st = anim.shown(app, w);
    try paint.box(w, b, st);
    const d = dataOf(w);
    const a = app.gpa;
    const content = paint.contentRect(w, st);
    if (content.w <= 0 or content.h <= 0) return;
    const shown = try shownText(w, a);
    defer if (shown.ptr != d.edit.text().ptr) a.free(shown);
    const mfont = scaleOne(w) orelse return;
    const win_scale: f32 = if (app.window) |win| win.scale else 1;
    const pfont = try app.fonts.get(st.font, win_scale);
    const m = font_mod.Fonts.metrics(mfont);
    var run1 = try shape.shape(a, mfont, shown);
    defer run1.deinit(a);
    // Keep the caret inside the content rectangle.
    const insw: i32 = blk: {
        const v = options.get(w, "-insertwidth").value;
        break :blk if (v == .pixels) v.pixels else 2;
    };
    const caret_byte = shownByte(w, shown, d.edit.caret);
    const caret_x = run1.caretX(shown, caret_byte);
    if (run1.width + insw <= content.w) {
        d.left = 0;
    } else {
        if (caret_x - d.left > content.w - insw) d.left = caret_x - content.w + insw;
        if (caret_x - d.left < 0) d.left = caret_x;
        d.left = @max(d.left, 0);
    }
    var run = try shape.shape(a, pfont, shown);
    defer run.deinit(a);
    const base_y = content.y + @divTrunc(content.h - m.line_height, 2) + m.ascent;
    const x0 = content.x - d.left;
    b.pushClip(content);
    defer b.popClip();
    var sel_x0: i32 = 0;
    var sel_x1: i32 = 0;
    const has_sel = d.edit.hasSelection();
    if (has_sel) {
        sel_x0 = x0 + run1.caretX(shown, shownByte(w, shown, d.edit.sel_first));
        sel_x1 = x0 + run1.caretX(shown, shownByte(w, shown, d.edit.sel_last));
        const ss = app.styles.compute(w, "selection", st, app.env);
        var bg = ss.background;
        var fg = ss.color;
        const ob = options.get(w, "-selectbackground");
        const of = options.get(w, "-selectforeground");
        if (ob.set and ob.value == .color) bg = ob.value.color;
        if (of.set and of.value == .color) fg = of.value.color;
        const line_top = base_y - m.ascent;
        try b.box(.{ .x = sel_x0, .y = line_top, .w = sel_x1 - sel_x0, .h = m.line_height }, .{ .fill = bg });
        // The glyphs outside the selection, then the glyphs inside it.
        b.pushClip(.{ .x = content.x, .y = content.y, .w = @max(sel_x0 - content.x, 0), .h = content.h });
        try b.text(&app.atlas, &run, x0, base_y, st.color);
        b.popClip();
        b.pushClip(.{ .x = sel_x1, .y = content.y, .w = @max(content.x + content.w - sel_x1, 0), .h = content.h });
        try b.text(&app.atlas, &run, x0, base_y, st.color);
        b.popClip();
        b.pushClip(.{ .x = sel_x0, .y = content.y, .w = sel_x1 - sel_x0, .h = content.h });
        try b.text(&app.atlas, &run, x0, base_y, fg);
        b.popClip();
    } else {
        try b.text(&app.atlas, &run, x0, base_y, st.color);
    }
    if (w.state.focus and isNormal(w) and d.caret_on) {
        try b.box(.{ .x = x0 + caret_x, .y = base_y - m.ascent, .w = insw, .h = m.line_height }, .{ .fill = st.caret_color });
    }
}

// ---- The caret timer ----

fn cancelTimer(w: *Widget, d: *Data) void {
    if (d.timer) |id| _ = w.app.loop.cancel(id);
    d.timer = null;
}

fn timeOption(w: *const Widget, comptime name: []const u8, default: i64) i64 {
    const v = options.get(w, name).value;
    return if (v == .int) v.int else default;
}

fn blink(ctx: ?*anyopaque) void {
    const w: *Widget = @ptrCast(@alignCast(ctx.?));
    const d = dataOf(w);
    d.timer = null;
    if (!w.state.focus or !isNormal(w)) return;
    d.caret_on = !d.caret_on;
    changed(w);
    // The next blink counts from the time that this one was due, so a late call does not drift.
    armTimer(w, d, d.due_us);
}

fn armTimer(w: *Widget, d: *Data, from_us: ?i64) void {
    cancelTimer(w, d);
    // `teardown` removed the timer of a deleted widget. No new timer starts.
    if (!w.alive() or !w.state.focus or !isNormal(w)) return;
    const off = timeOption(w, "-insertofftime", 300);
    if (off <= 0) return;
    const interval = (if (d.caret_on) timeOption(w, "-insertontime", 600) else off) *| 1000;
    const clock = w.app.loop.clock;
    const now = clock.now(clock.ctx);
    d.due_us = (from_us orelse now) +| interval;
    d.timer = w.app.loop.addNative(@max(d.due_us -| now, 0), blink, w) catch null;
}

/// Shows the caret and starts the on time again.
fn restartCaret(w: *Widget) void {
    const d = dataOf(w);
    d.caret_on = true;
    armTimer(w, d, null);
    changed(w);
}

// ---- Indexes ----

fn indexAtX(w: *Widget, x: i32) usize {
    const d = dataOf(w);
    const a = w.app.gpa;
    w.app.ensureStyle(w);
    const shown = shownText(w, a) catch return d.edit.caret;
    defer if (shown.ptr != d.edit.text().ptr) a.free(shown);
    const mfont = scaleOne(w) orelse return d.edit.caret;
    var run = shape.shape(a, mfont, shown) catch return d.edit.caret;
    defer run.deinit(a);
    const content = paint.contentRect(w, &w.style);
    const byte = run.indexAt(shown, x - content.x + d.left);
    // Convert the byte offset in the shown text to a character index.
    var chars: usize = 0;
    for (shown[0..@min(byte, shown.len)]) |c| {
        if (c & 0xC0 != 0x80) chars += 1;
    }
    return chars;
}

fn parseIndex(w: *Widget, it: *ztcl.Interp, v: Value) ztcl.Error!usize {
    const d = dataOf(w);
    const text = try it.str(v);
    if (std.mem.eql(u8, text, "end")) return d.edit.len();
    if (std.mem.eql(u8, text, "insert")) return d.edit.caret;
    if (std.mem.eql(u8, text, "anchor")) return d.edit.anchor;
    if (std.mem.eql(u8, text, "sel.first") or std.mem.eql(u8, text, "sel.last")) {
        if (!d.edit.hasSelection()) return it.fail("selection isn't in widget {s}", .{w.path});
        return if (text[4] == 'f') d.edit.sel_first else d.edit.sel_last;
    }
    if (text.len > 1 and text[0] == '@') {
        const x = std.fmt.parseInt(i64, text[1..], 10) catch return it.fail("bad entry index \"{s}\"", .{text});
        return indexAtX(w, num.px(x));
    }
    const n = std.fmt.parseInt(i64, text, 0) catch return it.fail("bad entry index \"{s}\"", .{text});
    if (n < 0) return 0;
    return @min(@as(usize, @intCast(n)), d.edit.len());
}

// ---- Widget subcommands ----

const unsupported = [_][]const u8{ "bbox", "scan", "validate", "xview" };

fn subcommand(w: *Widget, it: *ztcl.Interp, argv: []const Value) ztcl.Error!?Value {
    const sub = try it.str(argv[1]);
    const d = dataOf(w);
    const a = it.alloc();
    for (unsupported) |u| if (std.mem.eql(u8, sub, u)) return it.fail("{s} is not supported in this stage", .{u});
    if (std.mem.eql(u8, sub, "get")) {
        if (argv.len != 2) return it.fail("wrong # args: should be \"{s} get\"", .{w.path});
        return .{ .str = try a.dupe(u8, d.edit.text()) };
    }
    if (std.mem.eql(u8, sub, "insert")) {
        if (argv.len != 4) return it.fail("wrong # args: should be \"{s} insert index text\"", .{w.path});
        const index = try parseIndex(w, it, argv[2]);
        if (!isNormal(w)) return Value.empty;
        d.edit.insert(index, try it.str(argv[3])) catch return error.OutOfMemory;
        afterEdit(w);
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "delete")) {
        if (argv.len != 3 and argv.len != 4) return it.fail("wrong # args: should be \"{s} delete firstIndex ?lastIndex?\"", .{w.path});
        const first = try parseIndex(w, it, argv[2]);
        const last = if (argv.len == 4) try parseIndex(w, it, argv[3]) else first + 1;
        if (!isNormal(w)) return Value.empty;
        d.edit.delete(first, last);
        afterEdit(w);
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "icursor")) {
        if (argv.len != 3) return it.fail("wrong # args: should be \"{s} icursor pos\"", .{w.path});
        d.edit.caret = try parseIndex(w, it, argv[2]);
        restartCaret(w);
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "index")) {
        if (argv.len != 3) return it.fail("wrong # args: should be \"{s} index string\"", .{w.path});
        return .{ .int = @intCast(try parseIndex(w, it, argv[2])) };
    }
    if (std.mem.eql(u8, sub, "selection")) return try selection(w, it, argv);
    return null;
}

fn selection(w: *Widget, it: *ztcl.Interp, argv: []const Value) ztcl.Error!Value {
    const d = dataOf(w);
    if (argv.len < 3) return it.fail("wrong # args: should be \"{s} selection option ?index?\"", .{w.path});
    const opt = try it.str(argv[2]);
    if (std.mem.eql(u8, opt, "clear")) {
        d.edit.clearSelection();
        changed(w);
        return Value.empty;
    }
    if (std.mem.eql(u8, opt, "present")) return .{ .int = @intFromBool(d.edit.hasSelection()) };
    if (std.mem.eql(u8, opt, "range")) {
        if (argv.len != 5) return it.fail("wrong # args: should be \"{s} selection range start end\"", .{w.path});
        const a1 = try parseIndex(w, it, argv[3]);
        const b1 = try parseIndex(w, it, argv[4]);
        d.edit.select(a1, b1);
        changed(w);
        return Value.empty;
    }
    if (std.mem.eql(u8, opt, "adjust") or std.mem.eql(u8, opt, "from") or std.mem.eql(u8, opt, "to")) {
        return it.fail("selection {s} is not supported in this stage", .{opt});
    }
    return it.fail("bad selection option \"{s}\": must be adjust, clear, from, present, range, or to", .{opt});
}

fn afterEdit(w: *Widget) void {
    writeVar(w);
    restartCaret(w);
}

// ---- The class bindings ----

const Action = enum { click, drag, word, all, extend, move, backspace, delete, insert, focusin, focusout, nop };

fn printable(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

fn cmdEntry(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    app.enter();
    defer app.leave();
    if (argv.len < 3) return it.wrongArgs("::ztk::priv::entry action window ?arg ...?");
    const act = std.meta.stringToEnum(Action, try it.str(argv[1])) orelse return it.fail("bad action \"{s}\"", .{try it.str(argv[1])});
    const w = app.find(try it.str(argv[2])) orelse return Value.empty;
    if (w.class.measure != measure) return Value.empty;
    const d = dataOf(w);
    const normal = isNormal(w);
    const e = &d.edit;
    switch (act) {
        .focusin => {
            restartCaret(w);
            return Value.empty;
        },
        .focusout => {
            cancelTimer(w, d);
            changed(w);
            return Value.empty;
        },
        .nop => return Value.empty,
        else => {},
    }
    if (act == .click or act == .drag or act == .word or act == .extend) {
        if (argv.len < 4) return it.wrongArgs("::ztk::priv::entry action window x");
        const x: i32 = @intCast(std.math.clamp(try it.int(argv[3]), -100000, 100000));
        const idx = indexAtX(w, x);
        switch (act) {
            .click => {
                if (w.state.disabled) return Value.empty;
                e.moveTo(idx, false);
                if (focus.accepts(w)) focus.set(app, w);
            },
            .drag => if (!w.state.disabled) e.moveTo(idx, true),
            .extend => if (!w.state.disabled) e.moveTo(idx, true),
            .word => {
                const r = e.wordAt(idx);
                e.select(r[0], r[1]);
                e.caret = r[1];
                e.anchor = r[0];
            },
            else => unreachable,
        }
        restartCaret(w);
        return Value.empty;
    }
    switch (act) {
        .all => {
            e.select(0, e.len());
            e.caret = e.len();
        },
        .move => {
            if (argv.len < 5) return it.wrongArgs("::ztk::priv::entry move window step extend");
            const step = std.meta.stringToEnum(edit_mod.Edit.Step, try it.str(argv[3])) orelse return Value.empty;
            const extend = std.mem.eql(u8, try it.str(argv[4]), "1");
            e.moveTo(e.target(step), extend);
        },
        .backspace => if (normal) {
            e.backspace();
            afterEdit(w);
        },
        .delete => if (normal) {
            e.deleteForward();
            afterEdit(w);
        },
        .insert => {
            if (argv.len < 4) return Value.empty;
            const text = try it.str(argv[3]);
            if (normal and printable(text)) {
                e.typeText(text) catch return error.OutOfMemory;
                afterEdit(w);
                return Value.empty;
            }
        },
        else => {},
    }
    restartCaret(w);
    return Value.empty;
}

pub fn register(app: *App) !void {
    const it = app.it;
    try it.register("entry", widget.classCommand(&class));
    try app.classes.put(app.gpa, "entry", &class);
    try it.register("ztk::priv::entry", cmdEntry);
    try it.register("ztk::priv::entry_var", cmdVar);
    _ = try it.eval(
        \\bind Entry <Button-1> {::ztk::priv::entry click %W %x}
        \\bind Entry <B1-Motion> {::ztk::priv::entry drag %W %x}
        \\bind Entry <Double-Button-1> {::ztk::priv::entry word %W %x}
        \\bind Entry <Triple-Button-1> {::ztk::priv::entry all %W}
        \\bind Entry <Shift-Button-1> {::ztk::priv::entry extend %W %x}
        \\bind Entry <Key-Left> {::ztk::priv::entry move %W prev_char 0}
        \\bind Entry <Key-Right> {::ztk::priv::entry move %W next_char 0}
        \\bind Entry <Shift-Key-Left> {::ztk::priv::entry move %W prev_char 1}
        \\bind Entry <Shift-Key-Right> {::ztk::priv::entry move %W next_char 1}
        \\bind Entry <Control-Key-Left> {::ztk::priv::entry move %W prev_word 0}
        \\bind Entry <Control-Key-Right> {::ztk::priv::entry move %W next_word 0}
        \\bind Entry <Key-Home> {::ztk::priv::entry move %W line_start 0}
        \\bind Entry <Key-End> {::ztk::priv::entry move %W line_end 0}
        \\bind Entry <Shift-Key-Home> {::ztk::priv::entry move %W line_start 1}
        \\bind Entry <Shift-Key-End> {::ztk::priv::entry move %W line_end 1}
        \\bind Entry <Key-BackSpace> {::ztk::priv::entry backspace %W}
        \\bind Entry <Key-Delete> {::ztk::priv::entry delete %W}
        \\bind Entry <Control-Key-a> {::ztk::priv::entry move %W line_start 0}
        \\bind Entry <Control-Key-e> {::ztk::priv::entry move %W line_end 0}
        \\bind Entry <Control-Key-slash> {::ztk::priv::entry all %W}
        \\bind Entry <Key> {::ztk::priv::entry insert %W %A}
        \\bind Entry <Control-Key> {# no edit}
        \\bind Entry <Alt-Key> {# no edit}
        \\bind Entry <Key-Return> {# no edit}
        \\bind Entry <Key-Escape> {# no edit}
        \\bind Entry <Key-Tab> {# no edit}
        \\bind Entry <FocusIn> {::ztk::priv::entry focusin %W}
        \\bind Entry <FocusOut> {::ztk::priv::entry focusout %W}
    );
}
