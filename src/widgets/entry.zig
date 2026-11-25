//! The entry class. It edits one line of left-to-right text. The edit
//! model (`src/text/edit.zig`) holds the text, the caret, and the
//! selection. The class bindings on the tag `Entry` call
//! `::ztk::priv::entry`, so each key goes through the dispatch and the
//! bindings. `-textvariable` links the text to a global variable with a
//! script trace and a flag that stops the loop when the entry writes. The
//! entry keeps a scroll offset `left` so that the caret stays inside the
//! content rectangle. The caret blinks with a native timer of the loop,
//! and only while the entry has the focus.
//! A change of the text goes through `insertChars`, `deleteChars`, or
//! `setValue`, which follow `EntryInsertChars`, `EntryDeleteChars`, and
//! `EntrySetValue` of Tk with the validation of `-validate`. The class
//! bindings keep an undo history of the changes by the user (ztk). The
//! spinbox (`spinbox.zig`) uses this code with the flag `spin`.
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
const scroll = @import("../scroll.zig");
const path = @import("../path.zig");
const style_mod = @import("../style.zig");
const spinbox = @import("spinbox.zig");
const combobox = @import("../ttk/combobox.zig");
const App = @import("../app.zig").App;
const Spec = options.Spec;
const Widget = widget.Widget;
const Value = ztcl.Value;

const state_words = [_][]const u8{ "disabled", "normal", "readonly" };
pub const validate_words = [_][]const u8{ "all", "key", "focus", "focusin", "focusout", "none" };
pub const Mode = enum(u8) { all, key, focus, focusin, focusout, none };

/// The options of `wish` 8.6.16 in its order, then the additions of ztk.
pub const specs = [_]Spec{
    .{ .name = "-background", .db_name = "background", .db_class = "Background", .type = .color, .default = "#ffffff", .from_style = true, .style_prop = .background },
    .{ .name = "-bd", .type = .synonym, .target = "-borderwidth" },
    .{ .name = "-bg", .type = .synonym, .target = "-background" },
    .{ .name = "-borderwidth", .db_name = "borderWidth", .db_class = "BorderWidth", .type = .pixels, .default = "1", .from_style = true, .style_prop = .border_width },
    .{ .name = "-cursor", .db_name = "cursor", .db_class = "Cursor", .type = .string, .default = "xterm" },
    .{ .name = "-disabledbackground", .db_name = "disabledBackground", .db_class = "DisabledBackground", .type = .color, .default = "#d9d9d9" },
    .{ .name = "-disabledforeground", .db_name = "disabledForeground", .db_class = "DisabledForeground", .type = .color, .default = "#a3a3a3" },
    .{ .name = "-exportselection", .db_name = "exportSelection", .db_class = "ExportSelection", .type = .boolean, .default = "1" },
    .{ .name = "-fg", .type = .synonym, .target = "-foreground" },
    .{ .name = "-font", .db_name = "font", .db_class = "Font", .type = .font, .default = "TkTextFont" },
    .{ .name = "-foreground", .db_name = "foreground", .db_class = "Foreground", .type = .color, .default = "#000000", .from_style = true },
    .{ .name = "-highlightbackground", .db_name = "highlightBackground", .db_class = "HighlightBackground", .type = .color, .default = "#d9d9d9" },
    .{ .name = "-highlightcolor", .db_name = "highlightColor", .db_class = "HighlightColor", .type = .color, .default = "#000000" },
    .{ .name = "-highlightthickness", .db_name = "highlightThickness", .db_class = "HighlightThickness", .type = .pixels, .default = "1" },
    .{ .name = "-insertbackground", .db_name = "insertBackground", .db_class = "Foreground", .type = .color, .default = "#000000" },
    .{ .name = "-insertborderwidth", .db_name = "insertBorderWidth", .db_class = "BorderWidth", .type = .pixels, .default = "0" },
    .{ .name = "-insertofftime", .db_name = "insertOffTime", .db_class = "OffTime", .type = .int, .default = "300" },
    .{ .name = "-insertontime", .db_name = "insertOnTime", .db_class = "OnTime", .type = .int, .default = "600" },
    .{ .name = "-insertwidth", .db_name = "insertWidth", .db_class = "InsertWidth", .type = .pixels, .default = "2" },
    .{ .name = "-invalidcommand", .db_name = "invalidCommand", .db_class = "InvalidCommand", .type = .script, .allow_empty = true },
    .{ .name = "-invcmd", .type = .synonym, .target = "-invalidcommand" },
    .{ .name = "-justify", .db_name = "justify", .db_class = "Justify", .type = .justify, .default = "left" },
    .{ .name = "-readonlybackground", .db_name = "readonlyBackground", .db_class = "ReadonlyBackground", .type = .color, .default = "#d9d9d9" },
    .{ .name = "-relief", .db_name = "relief", .db_class = "Relief", .type = .relief, .default = "sunken", .from_style = true },
    .{ .name = "-selectbackground", .db_name = "selectBackground", .db_class = "Foreground", .type = .color, .default = "#c3c3c3" },
    .{ .name = "-selectborderwidth", .db_name = "selectBorderWidth", .db_class = "BorderWidth", .type = .pixels, .default = "0" },
    .{ .name = "-selectforeground", .db_name = "selectForeground", .db_class = "Background", .type = .color, .default = "#000000" },
    .{ .name = "-show", .db_name = "show", .db_class = "Show", .type = .string, .allow_empty = true },
    .{ .name = "-state", .db_name = "state", .db_class = "State", .type = .state, .default = "normal", .words = &state_words },
    .{ .name = "-takefocus", .db_name = "takeFocus", .db_class = "TakeFocus", .type = .string, .allow_empty = true },
    .{ .name = "-textvariable", .db_name = "textVariable", .db_class = "Variable", .type = .variable, .allow_empty = true },
    .{ .name = "-validate", .db_name = "validate", .db_class = "Validate", .type = .word, .default = "none", .words = &validate_words },
    .{ .name = "-validatecommand", .db_name = "validateCommand", .db_class = "ValidateCommand", .type = .script, .allow_empty = true },
    .{ .name = "-vcmd", .type = .synonym, .target = "-validatecommand" },
    .{ .name = "-width", .db_name = "width", .db_class = "Width", .type = .int, .default = "20" },
    .{ .name = "-xscrollcommand", .db_name = "xScrollCommand", .db_class = "ScrollCommand", .type = .script, .allow_empty = true },
} ++ addition_specs;

/// The options of ztk after the options of Tk, with the names of Tk 8.7.
pub const addition_specs = [_]Spec{
    .{ .name = "-placeholder", .db_name = "placeHolder", .db_class = "PlaceHolder", .type = .string, .allow_empty = true },
    .{ .name = "-placeholderforeground", .db_name = "placeholderForeground", .db_class = "PlaceholderForeground", .type = .color, .default = "#b3b3b3" },
};

const subcommand_list = "bbox, cget, configure, delete, get, icursor, index, insert, scan, selection, validate, or xview";

pub const class: widget.Class = .{
    .command = "entry",
    .tk_class = "Entry",
    .role = "text field",
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

/// A snapshot of the text for undo.
const Snap = struct { text: []u8, caret: usize };

/// An element of a spinbox, for `identify`, `invoke`, and `selection element`.
pub const Elem = enum { none, buttondown, buttonup, entry };

pub const Data = struct {
    edit: edit_mod.Edit,
    /// The scroll offset of the text in logical pixels (`xview`).
    view: scroll.View = .{},
    /// The next paint scrolls the view so that the caret shows.
    see: bool = true,
    caret_on: bool = true,
    timer: ?loop_mod.TimerId = null,
    /// The time of the next blink, in microseconds on the clock of the loop.
    due_us: i64 = 0,
    /// The traced variable, or empty.
    var_name: []u8 = &.{},
    /// True while the entry writes the variable.
    writing: bool = false,
    /// The mode of `-validate`. A validation can set it to `none`.
    mode: Mode = .none,
    /// The flags of the validation in Tk: a validation runs, a value is
    /// set (`EntrySetValue`), and a set stops after its validation.
    validating: bool = false,
    validate_var: bool = false,
    validate_abort: bool = false,
    /// `scan mark`: the x of the mark and the view at the mark.
    scan_x: i32 = 0,
    scan_pos: f64 = 0,
    /// The undo and redo stacks (ztk). The last entry of `undo` is a run
    /// of typed text while `typing` is true.
    undo: std.ArrayListUnmanaged(Snap) = .empty,
    redo: std.ArrayListUnmanaged(Snap) = .empty,
    typing: bool = false,
    /// The fade of the placeholder, and the parts of the search style.
    ph: paint.PartAnim = .{},
    icon: paint.PartAnim = .{},
    clear: paint.PartAnim = .{},
    hover_clear: bool = false,
    /// The spinbox fields.
    spin: bool = false,
    /// A `ttk::combobox`: the entry has a drop-down arrow on the right.
    combo: bool = false,
    arrow: paint.PartAnim = .{},
    /// The index in `-values` of the shown value.
    e_index: usize = 0,
    /// `selection element`: the button that shows as pressed.
    sel_elem: Elem = .none,
    /// The button under the pointer, and the button of a press.
    hover: Elem = .none,
    pressed: Elem = .none,
    /// The pointer left the pressed button during the press.
    outside: bool = false,
    repeated: u32 = 0,
    repeat: ?loop_mod.TimerId = null,
    up: paint.PartAnim = .{},
    down: paint.PartAnim = .{},
    /// The last valid `-format`.
    format: [24]u8 = undefined,
    format_len: usize = 0,
    /// The last valid `-from` and `-to`.
    from: f64 = 0,
    to: f64 = 0,
};

const trace_command = "ztk::priv::entry_var";

fn tracedVar(w: *const Widget) []const u8 {
    return dataOf(w).var_name;
}

pub fn dataOf(w: *const Widget) *Data {
    return @ptrCast(@alignCast(w.data.?));
}

/// True for an entry and a spinbox.
pub fn isEntry(w: *const Widget) bool {
    return w.class.deinit == class.deinit;
}

pub fn init(w: *Widget) anyerror!void {
    const d = try w.app.gpa.create(Data);
    d.* = .{ .edit = edit_mod.Edit.init(w.app.gpa) };
    w.data = d;
}

fn traceWords(w: *const Widget, d: *const Data, verb: []const u8) [6]Value {
    const a = w.app.it.alloc();
    const script = widget.traceScript(a, trace_command, w.path);
    return .{ .{ .str = "trace" }, .{ .str = verb }, .{ .str = "variable" }, .{ .str = d.var_name }, .{ .str = "write" }, .{ .str = script } };
}

fn freeSnaps(gpa: std.mem.Allocator, list: *std.ArrayListUnmanaged(Snap)) void {
    for (list.items) |s| gpa.free(s.text);
    list.clearRetainingCapacity();
}

pub fn deinit(w: *Widget) void {
    const gpa = w.app.gpa;
    const d = dataOf(w);
    gpa.free(d.var_name);
    freeSnaps(gpa, &d.undo);
    freeSnaps(gpa, &d.redo);
    d.undo.deinit(gpa);
    d.redo.deinit(gpa);
    d.edit.deinit();
    gpa.destroy(d);
    w.data = null;
}

/// Removes the timers and the trace when the widget is deleted. A new
/// widget with the same path adds a trace with the same text.
pub fn teardown(w: *Widget) void {
    const d = dataOf(w);
    cancelTimer(w, d);
    if (d.repeat) |id| _ = w.app.loop.cancel(id);
    d.repeat = null;
    if (d.var_name.len > 0) {
        const words = traceWords(w, d, "remove");
        _ = w.app.callTrace(&words) catch {};
    }
    w.app.gpa.free(d.var_name);
    d.var_name = &.{};
}

/// The slot of an option, or null when the class does not have it.
pub fn slot(w: *const Widget, name: []const u8) ?*const options.Slot {
    for (w.class.specs, 0..) |s, i| if (std.mem.eql(u8, s.name, name)) return &w.opts[i];
    return null;
}

fn specIndex(w: *const Widget, name: []const u8) ?usize {
    for (w.class.specs, 0..) |s, i| if (std.mem.eql(u8, s.name, name)) return i;
    return null;
}

/// The color of an option that the script set, or null.
fn setColor(w: *const Widget, name: []const u8) ?geom.Color {
    const s = slot(w, name) orelse return null;
    return if (s.set and s.value == .color) s.value.color else null;
}

fn isNormal(w: *const Widget) bool {
    // A `ttk::entry` reads its state flags, which `state` changes too.
    if (w.class.ttk) return !w.state.disabled and !w.state.readonly;
    const st = options.get(w, "-state").value;
    return st == .word and st.word == 1;
}

fn isReadonly(w: *const Widget) bool {
    if (w.class.ttk) return w.state.readonly and !w.state.disabled;
    const st = options.get(w, "-state").value;
    return st == .word and st.word == 2;
}

pub fn hasClass(w: *const Widget, name: []const u8) bool {
    return w.hasClass(name);
}

// ---- The variable ----

pub fn writeVar(w: *Widget) void {
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
    forgetHistory(w);
    setValue(w, s);
}

pub fn cmdVar(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    app.enter();
    defer app.leave();
    if (argv.len < 2) return Value.empty;
    const w = app.find(try it.str(argv[1])) orelse return Value.empty;
    if (!isEntry(w)) return Value.empty;
    if (dataOf(w).writing) return Value.empty;
    readVar(w);
    return Value.empty;
}

/// Adds the trace again after a compact of the interpreter.
pub fn retrace(w: *Widget) void {
    const d = dataOf(w);
    if (d.var_name.len == 0) return;
    const rm = traceWords(w, d, "remove");
    _ = w.app.callTrace(&rm) catch {};
    const add = traceWords(w, d, "add");
    _ = w.app.callTrace(&add) catch {};
}

pub fn configured(w: *Widget, changed_list: []const usize) ztcl.Error!void {
    const app = w.app;
    const d = dataOf(w);
    for (changed_list) |i| {
        // A variable trace of an earlier option can delete the widget.
        if (w.life == .dead) return;
        const name = w.class.specs[i].name;
        if (std.mem.eql(u8, name, "-state")) {
            if (w.class.ttk) {
                w.state.disabled = std.mem.eql(u8, w.opts[i].text, "disabled");
                w.state.readonly = std.mem.eql(u8, w.opts[i].text, "readonly");
            } else {
                w.state.disabled = w.opts[i].value == .word and w.opts[i].value.word == 0;
                w.state.readonly = isReadonly(w);
            }
            if (!isNormal(w)) cancelTimer(w, d);
        } else if (std.mem.eql(u8, name, "-validate")) {
            d.mode = if (w.opts[i].value == .word) @enumFromInt(w.opts[i].value.word) else .none;
        } else if (std.mem.eql(u8, name, "-placeholder")) {
            syncPlaceholder(w);
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
                // A `ttk` entry does not create a missing variable, as in `wish`.
                if (!missing) readVar(w) else if (!w.class.ttk) writeVar(w);
                if (w.life == .dead) return;
                const words = traceWords(w, d, "add");
                _ = try app.callTrace(&words);
            }
        }
    }
}

// ---- Size, areas, and paint ----

const icon_gap: i32 = 4;

/// The rectangles of an entry: the text, the search mark and the clear
/// button of the `search` style, and the buttons of a spinbox.
pub const Areas = struct {
    content: geom.Rect,
    icon: ?geom.Rect = null,
    clear: ?geom.Rect = null,
    up: ?geom.Rect = null,
    down: ?geom.Rect = null,
    arrow: ?geom.Rect = null,
};

fn ceilPx(v: f32) i32 {
    return @intFromFloat(@ceil(@max(v, 0)));
}

pub fn areas(w: *Widget, st: *const style_mod.Style) Areas {
    const r = paint.contentRect(w, st);
    var out: Areas = .{ .content = r };
    if (dataOf(w).spin) {
        const bw = spinbox.buttonWidth(w.app, st);
        const top = ceilPx(st.border_width[0]);
        const right = ceilPx(st.border_width[1]);
        const h = @max(w.geom.h - top - ceilPx(st.border_width[2]), 0);
        const x = w.geom.w - right - bw;
        const half = @divTrunc(h, 2);
        out.up = .{ .x = x, .y = top, .w = bw, .h = half };
        out.down = .{ .x = x, .y = top + half, .w = bw, .h = h - half };
        out.content.w = @max(@min(out.content.w, x - out.content.x), 0);
    }
    if (dataOf(w).combo) {
        const bw = spinbox.buttonWidth(w.app, st);
        const top = ceilPx(st.border_width[0]);
        const x = w.geom.w - ceilPx(st.border_width[1]) - bw;
        out.arrow = .{ .x = x, .y = top, .w = bw, .h = @max(w.geom.h - top - ceilPx(st.border_width[2]), 0) };
        out.content.w = @max(@min(out.content.w, x - out.content.x), 0);
    }
    if (hasClass(w, "search")) {
        const side = paint.lineHeight(w.app, st.font);
        const y = out.content.y + @divTrunc(out.content.h - side, 2);
        out.icon = .{ .x = out.content.x, .y = y, .w = side, .h = side };
        out.content.x += side + icon_gap;
        out.content.w = @max(out.content.w - 2 * (side + icon_gap), 0);
        out.clear = .{ .x = out.content.x + out.content.w + icon_gap, .y = y, .w = side, .h = side };
    }
    return out;
}

pub fn measure(w: *Widget) geom.Size {
    const app = w.app;
    app.ensureStyle(w);
    const st = &w.style;
    const wd = options.get(w, "-width").value;
    var chars: i32 = 20;
    if (wd == .int and wd.int > 0) chars = @intCast(@min(wd.int, 10000));
    const ins = paint.insets(st);
    var extra: i32 = 0;
    if (dataOf(w).spin or dataOf(w).combo) extra += spinbox.buttonWidth(app, st);
    if (hasClass(w, "search")) extra += 2 * (paint.lineHeight(app, st.font) + icon_gap);
    return .{
        .w = @max(num.add(num.add(num.px(@as(i64, chars) * paint.zeroWidth(app, st.font)), ins.horizontal()), extra), st.min_width),
        .h = @max(num.add(paint.lineHeight(app, st.font), ins.vertical()), st.min_height),
    };
}

/// The text that the entry draws: the real text, or the show character repeated.
fn shownText(w: *const Widget, a: std.mem.Allocator) ![]const u8 {
    const d = dataOf(w);
    const show = slot(w, "-show") orelse return d.edit.text();
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
    const show = slot(w, "-show").?;
    const n = std.unicode.utf8ByteSequenceLength(show.text[0]) catch 1;
    return @min(index * @min(n, show.text.len), shown.len);
}

pub fn changed(w: *Widget) void {
    w.invalidate(.{ .style = false, .measure = false, .layout = false, .paint = true });
}

/// Sets the state bit of `:placeholder-shown` from the text and `-placeholder`.
fn syncPlaceholder(w: *Widget) void {
    const ph = slot(w, "-placeholder") orelse return;
    const shown = ph.text.len > 0 and dataOf(w).edit.len() == 0;
    if (shown == w.state.placeholder) return;
    w.state.placeholder = shown;
    w.invalidate(.{ .style = true, .measure = false, .layout = false, .paint = true });
}

fn withAlpha(c: geom.Color, opacity: f32) geom.Color {
    var out = c;
    out.a = @intFromFloat(@round(@as(f32, @floatFromInt(c.a)) * std.math.clamp(opacity, 0, 1)));
    return out;
}

/// The style of a part, with the hover and pressed bits of that part in
/// place of the bits of the widget.
pub fn partStyleAs(w: *Widget, part: []const u8, slot_anim: *paint.PartAnim, hover: bool, pressed: bool) style_mod.Style {
    const saved = w.state;
    defer w.state = saved;
    w.state.hover = hover;
    w.state.pressed = pressed;
    return paint.partStyle(w, part, slot_anim).style;
}

fn paintEntry(w: *Widget, b: *scene.Builder) anyerror!void {
    const app = w.app;
    const shown_st = anim.shown(app, w);
    var box_st = shown_st.*;
    if (w.state.disabled) {
        if (setColor(w, "-disabledbackground")) |c| box_st.background = c;
        if (setColor(w, "-disabledforeground")) |c| box_st.color = c;
    } else if (w.state.readonly) {
        if (setColor(w, "-readonlybackground")) |c| box_st.background = c;
    }
    const st = &box_st;
    try paint.box(w, b, st);
    const d = dataOf(w);
    const a = app.gpa;
    const ar = areas(w, st);
    if (d.spin) try spinbox.paintButtons(w, b, ar);
    if (ar.arrow) |r| try combobox.paintArrow(w, b, r, &d.arrow);
    if (ar.icon != null) try paintSearch(w, b, ar);
    const content = ar.content;
    if (content.w <= 0 or content.h <= 0) return;
    const shown = try shownText(w, a);
    defer if (shown.ptr != d.edit.text().ptr) a.free(shown);
    const mfont = scaleOne(w) orelse return;
    const win_scale: f32 = b.scale;
    const pfont = try app.fonts.get(st.font, win_scale);
    const m = font_mod.Fonts.metrics(mfont);
    var run1 = try shape.shape(a, mfont, shown);
    defer run1.deinit(a);
    // The view: the text and the caret, in the content rectangle.
    const insw: i32 = blk: {
        const v = options.get(w, "-insertwidth").value;
        break :blk if (v == .pixels) v.pixels else 2;
    };
    const caret_byte = shownByte(w, shown, d.edit.caret);
    const caret_x = run1.caretX(shown, caret_byte);
    d.view.setSize(@floatFromInt(run1.width + insw), @floatFromInt(content.w));
    if (d.see) {
        // Keep the caret inside the content rectangle.
        d.see = false;
        const left: i32 = @intFromFloat(@round(d.view.pos));
        var to = left;
        if (caret_x - to > content.w - insw) to = caret_x - content.w + insw;
        if (caret_x - to < 0) to = caret_x;
        if (to != left) d.view.jump(@floatFromInt(to));
    }
    scroll.report(w, &d.view, "-xscrollcommand");
    const base_y = content.y + @divTrunc(content.h - m.line_height, 2) + m.ascent;
    const x0 = content.x - num.pxRound(d.view.shown(w));
    // The placeholder fades in while the text is empty, and out when it is not.
    if (slot(w, "-placeholder")) |ph| if (ph.text.len > 0) {
        const ps = paint.partStyle(w, "placeholder", &d.ph);
        if ((d.edit.len() == 0 or ps.t < 1) and ps.style.opacity > 0) {
            var prun = try shape.shape(a, pfont, ph.text);
            defer prun.deinit(a);
            const color = setColor(w, "-placeholderforeground") orelse ps.style.color;
            b.pushClip(content);
            defer b.popClip();
            try b.text(&app.atlas, &prun, content.x, base_y, withAlpha(color, ps.style.opacity));
        }
    };
    var run = try shape.shape(a, pfont, shown);
    defer run.deinit(a);
    const first_quad = b.scene.quads.items.len;
    defer scroll.paintDrag(w, b, &d.view, first_quad, 0) catch {};
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
        if (setColor(w, "-selectbackground")) |c| bg = c;
        if (setColor(w, "-selectforeground")) |c| fg = c;
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
        const cc = setColor(w, "-insertbackground") orelse st.caret_color;
        try b.box(.{ .x = x0 + caret_x, .y = base_y - m.ascent, .w = insw, .h = m.line_height }, .{ .fill = cc });
    }
}

/// The search mark (a lens) and the clear button (a cross) of the `search` style.
fn paintSearch(w: *Widget, b: *scene.Builder, ar: Areas) !void {
    const app = w.app;
    const d = dataOf(w);
    var sh: path.Shape = .{};
    defer sh.deinit(app.gpa);
    const ist = paint.partStyle(w, "icon", &d.icon).style;
    const r = ar.icon.?;
    const fx: f32 = @floatFromInt(r.x);
    const fy: f32 = @floatFromInt(r.y);
    const s: f32 = @floatFromInt(r.w);
    const lw = @max(s / 10, 1.25);
    // The ring of the lens as a closed line of short segments, and the handle.
    const cx = fx + s * 0.42;
    const cy = fy + s * 0.42;
    const rad = s * 0.24;
    var pts: [25]path.Pt = undefined;
    for (&pts, 0..) |*p, i| {
        const t = @as(f32, @floatFromInt(i)) / 24 * std.math.tau;
        p.* = .{ .x = cx + rad * @cos(t), .y = cy + rad * @sin(t) };
    }
    try sh.stroke(app.gpa, &pts, lw, true);
    try sh.stroke(app.gpa, &.{ .{ .x = cx + rad * 0.72, .y = cy + rad * 0.72 }, .{ .x = fx + s * 0.8, .y = fy + s * 0.8 } }, lw * 1.2, true);
    try paint.fillShape(b, &sh, ist.color, ist.opacity);
    if (d.edit.len() == 0) return;
    const c = ar.clear.?;
    const cst = partStyleAs(w, "clear", &d.clear, d.hover_clear, false);
    try paint.styledBox(b, c, &cst);
    var x: path.Shape = .{};
    defer x.deinit(app.gpa);
    const qx: f32 = @floatFromInt(c.x);
    const qy: f32 = @floatFromInt(c.y);
    const q: f32 = @floatFromInt(c.w);
    try x.stroke(app.gpa, &.{ .{ .x = qx + q * 0.34, .y = qy + q * 0.34 }, .{ .x = qx + q * 0.66, .y = qy + q * 0.66 } }, lw, true);
    try x.stroke(app.gpa, &.{ .{ .x = qx + q * 0.66, .y = qy + q * 0.34 }, .{ .x = qx + q * 0.34, .y = qy + q * 0.66 } }, lw, true);
    try paint.fillShape(b, &x, cst.color, cst.opacity);
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
    d.see = true;
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
    const content = areas(w, &w.style).content;
    const byte = run.indexAt(shown, x - content.x + num.pxRound(d.view.pos));
    // Convert the byte offset in the shown text to a character index.
    var chars: usize = 0;
    for (shown[0..@min(byte, shown.len)]) |c| {
        if (c & 0xC0 != 0x80) chars += 1;
    }
    return chars;
}

fn kind(w: *const Widget) []const u8 {
    return if (dataOf(w).spin) "spinbox" else "entry";
}

pub fn parseIndex(w: *Widget, it: *ztcl.Interp, v: Value) ztcl.Error!usize {
    const d = dataOf(w);
    const text = try it.str(v);
    if (std.mem.eql(u8, text, "end")) return d.edit.len();
    if (std.mem.eql(u8, text, "insert")) return d.edit.caret;
    if (std.mem.eql(u8, text, "anchor")) return @min(d.edit.anchor, d.edit.len());
    if (std.mem.eql(u8, text, "sel.first") or std.mem.eql(u8, text, "sel.last")) {
        if (!d.edit.hasSelection()) return it.fail("selection isn't in widget {s}", .{w.path});
        return if (text[4] == 'f') d.edit.sel_first else d.edit.sel_last;
    }
    if (text.len > 1 and text[0] == '@') {
        const x = std.fmt.parseInt(i64, text[1..], 10) catch return it.fail("bad {s} index \"{s}\"", .{ kind(w), text });
        return indexAtX(w, num.px(x));
    }
    const n = std.fmt.parseInt(i64, text, 0) catch return it.fail("bad {s} index \"{s}\"", .{ kind(w), text });
    if (n < 0) return 0;
    return @min(@as(usize, @intCast(n)), d.edit.len());
}

// ---- Validation ----

pub const Reason = enum { insert, delete, forced, focusin, focusout, button };
pub const Code = enum { ok, brk, err };

/// Sets `-validate` to `none`, as Tk does after an error or a loop.
fn validateOff(w: *Widget) void {
    const d = dataOf(w);
    d.mode = .none;
    const i = specIndex(w, "-validate") orelse return;
    if (w.opts[i].value == .word and w.opts[i].value.word == @intFromEnum(Mode.none)) return;
    options.setOne(w, w.app.it, i, "none", widget.Dirty.none) catch {};
}

/// Appends a value of a `%` field with backslashes where Tcl needs them
/// (Tk quotes the fields with `TCL_DONT_USE_BRACES`).
fn appendQuoted(a: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    if (s.len == 0) return out.appendSlice(a, "{}");
    for (s, 0..) |c, i| {
        switch (c) {
            '\n' => try out.appendSlice(a, "\\n"),
            '\t' => try out.appendSlice(a, "\\t"),
            '\r' => try out.appendSlice(a, "\\r"),
            0x0b => try out.appendSlice(a, "\\v"),
            0x0c => try out.appendSlice(a, "\\f"),
            ' ', '{', '}', '[', ']', '$', '"', '\\', ';' => {
                try out.append(a, '\\');
                try out.append(a, c);
            },
            '#' => {
                if (i == 0) try out.append(a, '\\');
                try out.append(a, c);
            },
            else => try out.append(a, c),
        }
    }
}

/// The `%` fields of `-validatecommand`, `-invalidcommand`, and the
/// `-command` of a spinbox, as `ExpandPercents` of Tk.
pub fn expand(w: *Widget, a: std.mem.Allocator, script: []const u8, change: []const u8, new: []const u8, index: i64, r: Reason) std.mem.Allocator.Error![]u8 {
    const d = dataOf(w);
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var nb: [24]u8 = undefined;
    while (i < script.len) {
        const c = script[i];
        if (c != '%') {
            try out.append(a, c);
            i += 1;
            continue;
        }
        i += 1;
        var ch: []const u8 = "%";
        if (i < script.len) {
            const n = std.unicode.utf8ByteSequenceLength(script[i]) catch 1;
            ch = script[i..@min(i + n, script.len)];
            i += ch.len;
        }
        const s: []const u8 = if (r == .button) switch (ch[0]) {
            's' => d.edit.text(),
            'd' => change,
            'W' => w.path,
            else => ch,
        } else switch (ch[0]) {
            'd' => if (r == .insert) "1" else if (r == .delete) "0" else "-1",
            'i' => if (r == .insert or r == .delete) std.fmt.bufPrint(&nb, "{d}", .{index}) catch "-1" else "-1",
            'P' => new,
            's' => d.edit.text(),
            'S' => change,
            'v' => validate_words[@intFromEnum(d.mode)],
            'V' => switch (r) {
                .insert, .delete => "key",
                .focusin => "focusin",
                .focusout => "focusout",
                .forced => "forced",
                .button => "all",
            },
            'W' => w.path,
            else => ch,
        };
        try appendQuoted(a, &out, s);
    }
    return out.items;
}

/// Runs a script at the global level and gives its result. An error goes
/// to the background error handler and gives null.
fn evalGlobal(app: *App, script: []const u8) ?[]const u8 {
    const it = app.it;
    const saved_frame = it.frame;
    const saved_ns = it.ns;
    const saved_result = it.result;
    it.frame = &it.global;
    it.ns = "";
    app.enter();
    defer {
        it.frame = saved_frame;
        it.ns = saved_ns;
        it.result = saved_result;
        app.leave();
    }
    const v = it.eval(script) catch |e| {
        app.backgroundError(e);
        return null;
    };
    const s = it.str(v) catch return null;
    return it.alloc().dupe(u8, s) catch null;
}

/// `EntryValidateChange` of Tk: runs `-validatecommand` for a change and
/// `-invalidcommand` when the change is not valid.
pub fn validateChange(w: *Widget, change: []const u8, new: []const u8, index: i64, r: Reason) Code {
    const d = dataOf(w);
    const app = w.app;
    const var_validate = d.validate_var;
    const vcmd = slot(w, "-validatecommand").?;
    if (vcmd.text.len == 0 or d.mode == .none) {
        if (d.validating) d.validate_abort = true;
        return if (var_validate) .err else .ok;
    }
    if (d.validating) {
        validateOff(w);
        return if (var_validate) .err else .ok;
    }
    d.validating = true;
    const a = app.it.alloc();
    var code: Code = .err;
    if (expand(w, a, vcmd.text, change, new, index, r)) |script| {
        if (evalGlobal(app, script)) |res| {
            if (w.life == .dead) return .err;
            if (options.parseBool(res)) |ok| {
                code = if (ok) .ok else .brk;
            } else {
                app.backgroundError(app.it.fail("expected boolean value but got \"{s}\"", .{res}));
            }
        }
    } else |_| {}
    if (w.life == .dead) return .err;
    if (d.mode == .none or (!var_validate and d.validate_var)) code = .err;
    if (code == .err) {
        validateOff(w);
    } else if (code == .brk) {
        if (var_validate) {
            validateOff(w);
        } else if (slot(w, "-invalidcommand")) |inv| if (inv.text.len > 0) {
            if (expand(w, a, inv.text, change, new, index, r)) |script| {
                if (evalGlobal(app, script) == null) {
                    code = .err;
                    if (w.life != .dead) validateOff(w);
                }
            } else |_| {}
        };
    }
    if (w.life == .dead) return .err;
    d.validating = false;
    return code;
}

/// `EntrySetValue` of Tk: a forced validation, then the new text. The
/// text is set also when the validation fails.
pub fn setValue(w: *Widget, value: []const u8) void {
    const d = dataOf(w);
    if (d.validate_var) {
        d.validate_abort = true;
    } else {
        const copy = w.app.it.alloc().dupe(u8, value) catch return;
        d.validate_var = true;
        _ = validateChange(w, "", copy, -1, .forced);
        if (w.life == .dead) return;
        d.validate_var = false;
        return setText(w, copy);
    }
    setText(w, value);
}

fn setText(w: *Widget, value: []const u8) void {
    const d = dataOf(w);
    if (d.validate_abort) {
        d.validate_abort = false;
        return;
    }
    const e = &d.edit;
    const f = e.sel_first;
    const l = e.sel_last;
    const had = e.hasSelection();
    e.setText(value) catch return;
    // Tk keeps the part of the selection inside the new text.
    if (had and f < e.len()) e.select(f, @min(l, e.len()));
    syncPlaceholder(w);
    d.see = true;
    changed(w);
}

/// `EntryValueChanged` of Tk: sets the text and writes the variable.
pub fn valueChanged(w: *Widget, value: []const u8) void {
    setValue(w, value);
    if (w.life == .dead) return;
    writeVar(w);
}

fn mayValidate(d: *const Data, keys: bool) bool {
    return switch (d.mode) {
        .all => true,
        .key => keys,
        else => false,
    };
}

/// `EntryInsertChars` of Tk, with the validation of a key.
pub fn insertChars(w: *Widget, index: usize, text: []const u8) void {
    const d = dataOf(w);
    if (text.len == 0) return;
    const e = &d.edit;
    const at = @min(index, e.len());
    if (mayValidate(d, true)) {
        const a = w.app.it.alloc();
        const b = e.byteOf(at);
        const new = std.mem.concat(a, u8, &.{ e.text()[0..b], text, e.text()[b..] }) catch return;
        if (validateChange(w, text, new, @intCast(at), .insert) != .ok) return;
        if (w.life == .dead) return;
    }
    e.insert(at, text) catch return;
    syncPlaceholder(w);
    writeVar(w);
    if (w.life == .dead) return;
    restartCaret(w);
}

/// `EntryDeleteChars` of Tk: deletes [first, last), with the validation of a key.
pub fn deleteChars(w: *Widget, first: usize, last: usize) void {
    const d = dataOf(w);
    const e = &d.edit;
    const a0 = @min(first, e.len());
    const b0 = @min(@max(last, a0), e.len());
    if (a0 == b0) return;
    if (mayValidate(d, true)) {
        const a = w.app.it.alloc();
        const ba = e.byteOf(a0);
        const bb = e.byteOf(b0);
        const gone = a.dupe(u8, e.text()[ba..bb]) catch return;
        const new = std.mem.concat(a, u8, &.{ e.text()[0..ba], e.text()[bb..] }) catch return;
        if (validateChange(w, gone, new, @intCast(a0), .delete) != .ok) return;
        if (w.life == .dead) return;
    }
    e.delete(a0, b0);
    syncPlaceholder(w);
    writeVar(w);
    if (w.life == .dead) return;
    restartCaret(w);
}

// ---- Undo (ztk) ----

const undo_limit = 100;

fn snap(w: *Widget) ?Snap {
    const d = dataOf(w);
    const t = w.app.gpa.dupe(u8, d.edit.text()) catch return null;
    return .{ .text = t, .caret = d.edit.caret };
}

/// Keeps the text before a change by the user. A run of typed text is one step.
fn record(w: *Widget, typing: bool) void {
    const d = dataOf(w);
    const gpa = w.app.gpa;
    if (typing and d.typing) return;
    d.typing = typing;
    const s = snap(w) orelse return;
    if (d.undo.items.len >= undo_limit) {
        gpa.free(d.undo.items[0].text);
        _ = d.undo.orderedRemove(0);
    }
    d.undo.append(gpa, s) catch gpa.free(s.text);
    freeSnaps(gpa, &d.redo);
}

/// A change by a script ends the history of the user.
fn forgetHistory(w: *Widget) void {
    const d = dataOf(w);
    freeSnaps(w.app.gpa, &d.undo);
    freeSnaps(w.app.gpa, &d.redo);
    d.typing = false;
}

fn undoStep(w: *Widget, redo: bool) void {
    const d = dataOf(w);
    const gpa = w.app.gpa;
    const from = if (redo) &d.redo else &d.undo;
    const to = if (redo) &d.undo else &d.redo;
    const s = from.pop() orelse return;
    defer gpa.free(s.text);
    if (snap(w)) |cur| to.append(gpa, cur) catch gpa.free(cur.text);
    d.typing = false;
    valueChanged(w, s.text);
    if (w.life == .dead) return;
    d.edit.moveTo(s.caret, false);
    restartCaret(w);
}

// ---- Widget subcommands ----

pub fn subcommand(w: *Widget, it: *ztcl.Interp, argv: []const Value) ztcl.Error!?Value {
    const sub = try it.str(argv[1]);
    const d = dataOf(w);
    const a = it.alloc();
    if (std.mem.eql(u8, sub, "xview")) return try xview(w, it, argv);
    if (std.mem.eql(u8, sub, "get")) {
        if (argv.len != 2) return it.fail("wrong # args: should be \"{s} get\"", .{w.path});
        return .{ .str = try a.dupe(u8, d.edit.text()) };
    }
    if (std.mem.eql(u8, sub, "insert")) {
        if (argv.len != 4) return it.fail("wrong # args: should be \"{s} insert index text\"", .{w.path});
        const index = try parseIndex(w, it, argv[2]);
        if (!isNormal(w)) return Value.empty;
        forgetHistory(w);
        insertChars(w, index, try a.dupe(u8, try it.str(argv[3])));
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "delete")) {
        if (argv.len != 3 and argv.len != 4) return it.fail("wrong # args: should be \"{s} delete firstIndex ?lastIndex?\"", .{w.path});
        const first = try parseIndex(w, it, argv[2]);
        const last = if (argv.len == 4) try parseIndex(w, it, argv[3]) else first + 1;
        if (!isNormal(w)) return Value.empty;
        forgetHistory(w);
        deleteChars(w, first, last);
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
    if (std.mem.eql(u8, sub, "bbox")) {
        if (argv.len != 3) return it.fail("wrong # args: should be \"{s} bbox index\"", .{w.path});
        var index = try parseIndex(w, it, argv[2]);
        if (index == d.edit.len() and index > 0) index -= 1;
        w.app.ensureStyle(w);
        syncView(w);
        const content = areas(w, &w.style).content;
        const left = num.pxRound(d.view.pos);
        const x0 = indexX(w, index);
        const x1 = if (index < d.edit.len()) indexX(w, index + 1) else x0;
        const lh = paint.lineHeight(w.app, w.style.font);
        const y = content.y + @divTrunc(content.h - lh, 2);
        return try ztcl.value.newList(a, &.{ .{ .int = content.x + x0 - left }, .{ .int = y }, .{ .int = x1 - x0 }, .{ .int = lh } });
    }
    if (std.mem.eql(u8, sub, "scan")) {
        if (argv.len != 4) return it.fail("wrong # args: should be \"{s} scan mark|dragto x\"", .{w.path});
        const opt = try it.str(argv[2]);
        const x: i32 = @intCast(std.math.clamp(try it.int(argv[3]), -1000000, 1000000));
        if (opt.len > 0 and std.mem.startsWith(u8, "mark", opt)) {
            d.scan_x = x;
            d.scan_pos = d.view.pos;
        } else if (opt.len > 0 and std.mem.startsWith(u8, "dragto", opt)) {
            // Tk moves the view 10 times the distance of the pointer.
            w.app.ensureStyle(w);
            syncView(w);
            d.see = false;
            d.view.jump(d.scan_pos - 10 * @as(f64, @floatFromInt(x - d.scan_x)));
            scroll.report(w, &d.view, "-xscrollcommand");
            changed(w);
        } else return it.fail("bad scan option \"{s}\": must be mark or dragto", .{opt});
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "validate")) {
        if (argv.len != 2) return it.fail("wrong # args: should be \"{s} validate\"", .{w.path});
        // Tk validates in the mode `all` and then gives the mode back.
        const saved = d.mode;
        d.mode = .all;
        const code = validateChange(w, "", try a.dupe(u8, d.edit.text()), -1, .forced);
        if (w.life != .dead and d.mode != .none) d.mode = saved;
        return .{ .int = @intFromBool(code == .ok) };
    }
    return null;
}

fn selection(w: *Widget, it: *ztcl.Interp, argv: []const Value) ztcl.Error!Value {
    const d = dataOf(w);
    if (argv.len < 3) return it.fail("wrong # args: should be \"{s} selection option ?index?\"", .{w.path});
    const opt = try it.str(argv[2]);
    const e = &d.edit;
    const names = if (d.spin) "adjust, clear, element, from, present, range, or to" else "adjust, clear, from, present, range, or to";
    if (std.mem.eql(u8, opt, "present")) {
        if (argv.len != 3) return it.fail("wrong # args: should be \"{s} selection present\"", .{w.path});
        return .{ .int = @intFromBool(e.hasSelection()) };
    }
    if (d.spin and std.mem.eql(u8, opt, "element")) return spinbox.selectionElement(w, it, argv);
    const known = [_][]const u8{ "adjust", "clear", "from", "range", "to" };
    var found = false;
    for (known) |k| if (std.mem.eql(u8, opt, k)) {
        found = true;
    };
    if (!found) return it.fail("bad selection option \"{s}\": must be {s}", .{ opt, names });
    if (std.mem.eql(u8, opt, "clear")) {
        if (argv.len != 3) return it.fail("wrong # args: should be \"{s} selection clear\"", .{w.path});
        if (w.state.disabled) return Value.empty;
        e.clearSelection();
        changed(w);
        return Value.empty;
    }
    if (std.mem.eql(u8, opt, "range")) {
        if (argv.len != 5) return it.fail("wrong # args: should be \"{s} selection range start end\"", .{w.path});
        const a1 = try parseIndex(w, it, argv[3]);
        const b1 = try parseIndex(w, it, argv[4]);
        if (w.state.disabled) return Value.empty;
        e.select(a1, b1);
        changed(w);
        return Value.empty;
    }
    if (argv.len != 4) return it.fail("wrong # args: should be \"{s} selection {s} index\"", .{ w.path, opt });
    const index = try parseIndex(w, it, argv[3]);
    if (w.state.disabled) return Value.empty;
    if (std.mem.eql(u8, opt, "from")) {
        e.anchor = index;
        return Value.empty;
    }
    if (std.mem.eql(u8, opt, "adjust") and e.hasSelection()) {
        // The end of the selection nearer to the index moves, and the other end is the anchor.
        const half1 = (e.sel_first + e.sel_last) / 2;
        const half2 = (e.sel_first + e.sel_last + 1) / 2;
        if (index < half1) e.anchor = e.sel_last else if (index > half2) e.anchor = e.sel_first;
    }
    selectTo(w, index);
    return Value.empty;
}

/// `EntrySelectTo` of Tk: the selection from the anchor to the index.
fn selectTo(w: *Widget, index: usize) void {
    const e = &dataOf(w).edit;
    if (e.anchor > e.len()) e.anchor = e.len();
    if (e.anchor <= index) e.select(e.anchor, index) else e.select(index, e.anchor);
    changed(w);
}

/// `xview ?index?`, `xview moveto f`, and `xview scroll n units|pages`. A
/// unit is the width of "0" and a page is the width of the window.
fn xview(w: *Widget, it: *ztcl.Interp, argv: []const Value) ztcl.Error!Value {
    const d = dataOf(w);
    w.app.ensureStyle(w);
    syncView(w);
    // A view that a script sets stays until the caret moves again.
    d.see = false;
    const content = areas(w, &w.style).content;
    const unit: f64 = @floatFromInt(@max(paint.zeroWidth(w.app, w.style.font), 1));
    const steps: scroll.Steps = .{ .unit = unit, .page = @max(@as(f64, @floatFromInt(content.w)) - unit, unit) };
    if (try scroll.command(w, it, argv, &d.view, steps, true)) |v| {
        if (argv.len > 2) scroll.report(w, &d.view, "-xscrollcommand");
        return v;
    }
    if (argv.len != 3) return it.fail("unknown option \"{s}\": must be moveto or scroll", .{try it.str(argv[2])});
    // `xview index`: the character goes to the left edge.
    const index = try parseIndex(w, it, argv[2]);
    d.view.jump(@floatFromInt(indexX(w, index)));
    scroll.report(w, &d.view, "-xscrollcommand");
    changed(w);
    return Value.empty;
}

/// The x of the character `index` in the text, from its start.
fn indexX(w: *Widget, index: usize) i32 {
    const d = dataOf(w);
    const a = w.app.gpa;
    const shown = shownText(w, a) catch return 0;
    defer if (shown.ptr != d.edit.text().ptr) a.free(shown);
    const mfont = scaleOne(w) orelse return 0;
    var run = shape.shape(a, mfont, shown) catch return 0;
    defer run.deinit(a);
    return run.caretX(shown, shownByte(w, shown, index));
}

/// Gives the view the size of the text and of the window, as the paint does.
fn syncView(w: *Widget) void {
    const d = dataOf(w);
    const a = w.app.gpa;
    const shown = shownText(w, a) catch return;
    defer if (shown.ptr != d.edit.text().ptr) a.free(shown);
    const mfont = scaleOne(w) orelse return;
    var run = shape.shape(a, mfont, shown) catch return;
    defer run.deinit(a);
    const insw: i32 = blk: {
        const v = options.get(w, "-insertwidth").value;
        break :blk if (v == .pixels) v.pixels else 2;
    };
    // Before its first layout the entry has its requested width.
    const ins = paint.insets(&w.style);
    const vis = if (w.mapped) areas(w, &w.style).content.w else measure(w).w - ins.horizontal();
    d.view.setSize(@floatFromInt(run.width + insw), @floatFromInt(@max(vis, 0)));
}

// ---- The class bindings ----

const Action = enum { click, drag, release, motion, leave, word, all, extend, move, backspace, delete, insert, focusin, focusout, cut, copy, paste, clear, selectall, selectnone, undo, redo, nop };

fn printable(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

fn inside(r: ?geom.Rect, x: i32, y: i32) bool {
    const q = r orelse return false;
    return x >= q.x and x < q.x + q.w and y >= q.y and y < q.y + q.h;
}

/// The selected text, as `tk::EntryGetSelection`: the show character for each character of a hidden text.
fn selectedText(w: *Widget, a: std.mem.Allocator) ?[]const u8 {
    const e = &dataOf(w).edit;
    if (!e.hasSelection()) return null;
    const txt = e.text()[e.byteOf(e.sel_first)..e.byteOf(e.sel_last)];
    const show = slot(w, "-show") orelse return txt;
    if (!show.set or show.text.len == 0) return txt;
    const n = std.unicode.utf8ByteSequenceLength(show.text[0]) catch 1;
    const ch = show.text[0..@min(n, show.text.len)];
    var out: std.ArrayList(u8) = .empty;
    for (0..e.sel_last - e.sel_first) |_| out.appendSlice(a, ch) catch return null;
    return out.items;
}

/// Deletes the selection, or the characters [first, last) when there is none.
fn deleteSelOr(w: *Widget, first: usize, last: usize) void {
    const e = &dataOf(w).edit;
    if (e.hasSelection()) deleteChars(w, e.sel_first, e.sel_last) else deleteChars(w, first, last);
}

fn cmdEntry(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    app.enter();
    defer app.leave();
    if (argv.len < 3) return it.wrongArgs("::ztk::priv::entry action window ?arg ...?");
    const act = std.meta.stringToEnum(Action, try it.str(argv[1])) orelse return it.fail("bad action \"{s}\"", .{try it.str(argv[1])});
    const w = app.find(try it.str(argv[2])) orelse return Value.empty;
    if (!isEntry(w)) return Value.empty;
    const d = dataOf(w);
    const normal = isNormal(w);
    const e = &d.edit;
    const a = it.alloc();
    switch (act) {
        .focusin, .focusout => {
            if (act == .focusin) restartCaret(w) else {
                cancelTimer(w, d);
                changed(w);
            }
            const want = switch (d.mode) {
                .all, .focus => true,
                .focusin => act == .focusin,
                .focusout => act == .focusout,
                else => false,
            };
            if (want) _ = validateChange(w, "", try a.dupe(u8, e.text()), -1, if (act == .focusin) .focusin else .focusout);
            return Value.empty;
        },
        .nop => return Value.empty,
        .leave => {
            if (d.hover_clear or d.hover != .none) {
                d.hover_clear = false;
                d.hover = .none;
                changed(w);
            }
            return Value.empty;
        },
        else => {},
    }
    if (act == .click or act == .drag or act == .word or act == .extend or act == .release or act == .motion) {
        if (argv.len < 4) return it.wrongArgs("::ztk::priv::entry action window x ?y?");
        const x: i32 = @intCast(std.math.clamp(try it.int(argv[3]), -100000, 100000));
        const y: i32 = if (argv.len > 4) @intCast(std.math.clamp(try it.int(argv[4]), -100000, 100000)) else 0;
        app.ensureStyle(w);
        const ar = areas(w, &w.style);
        if (act == .motion) {
            const hc = e.len() > 0 and inside(ar.clear, x, y);
            const he: Elem = if (inside(ar.up, x, y)) .buttonup else if (inside(ar.down, x, y) or inside(ar.arrow, x, y)) .buttondown else .none;
            if (hc != d.hover_clear or he != d.hover) {
                d.hover_clear = hc;
                d.hover = he;
                changed(w);
            }
            return Value.empty;
        }
        if (d.spin and try spinbox.pointer(w, act == .click or act == .word, act == .drag, act == .release, x, y)) return Value.empty;
        if (act == .release) return Value.empty;
        if (act == .click and normal and e.len() > 0 and inside(ar.clear, x, y)) {
            record(w, false);
            deleteChars(w, 0, e.len());
            return Value.empty;
        }
        const idx = indexAtX(w, x);
        d.typing = false;
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
        .all, .selectall => {
            e.select(0, e.len());
            e.caret = e.len();
            d.typing = false;
        },
        .selectnone => e.clearSelection(),
        .move => {
            if (argv.len < 5) return it.wrongArgs("::ztk::priv::entry move window step extend");
            const step = std.meta.stringToEnum(edit_mod.Edit.Step, try it.str(argv[3])) orelse return Value.empty;
            const extend = std.mem.eql(u8, try it.str(argv[4]), "1");
            e.moveTo(e.target(step), extend);
            d.typing = false;
        },
        .backspace => if (normal) {
            record(w, false);
            if (e.caret > 0 or e.hasSelection()) deleteSelOr(w, e.caret -| 1, e.caret);
            e.anchor = e.caret;
            return Value.empty;
        },
        .delete => if (normal) {
            record(w, false);
            deleteSelOr(w, e.caret, e.caret + 1);
            e.anchor = e.caret;
            return Value.empty;
        },
        .insert => {
            if (argv.len < 4) return Value.empty;
            const text = try it.str(argv[3]);
            if (normal and printable(text)) {
                record(w, true);
                // `tk::EntryInsert`: typed text replaces a selection that holds the caret.
                if (e.hasSelection() and e.caret >= e.sel_first and e.caret <= e.sel_last) {
                    deleteChars(w, e.sel_first, e.sel_last);
                    if (w.life == .dead) return Value.empty;
                }
                insertChars(w, e.caret, try a.dupe(u8, text));
                if (w.life == .dead) return Value.empty;
                e.anchor = e.caret;
                return Value.empty;
            }
        },
        .copy, .cut => {
            const sel = selectedText(w, a) orelse return Value.empty;
            app.clipboard.clear(app.gpa);
            app.clipboard.append(app.gpa, "STRING", sel) catch return error.OutOfMemory;
            if (act == .cut and normal) {
                record(w, false);
                deleteChars(w, e.sel_first, e.sel_last);
            }
            return Value.empty;
        },
        .paste => {
            const data = app.clipboard.get("STRING") orelse return Value.empty;
            if (!normal) return Value.empty;
            const text = try a.dupe(u8, data);
            record(w, false);
            // The paste of Tk on a windowing system other than x11 replaces the selection.
            if (e.hasSelection()) deleteChars(w, e.sel_first, e.sel_last);
            if (w.life == .dead) return Value.empty;
            insertChars(w, e.caret, text);
            return Value.empty;
        },
        .clear => if (normal and e.hasSelection()) {
            record(w, false);
            deleteChars(w, e.sel_first, e.sel_last);
            return Value.empty;
        },
        .undo, .redo => {
            if (normal) undoStep(w, act == .redo);
            return Value.empty;
        },
        else => {},
    }
    restartCaret(w);
    return Value.empty;
}

/// The class bindings of `Entry`. A spinbox has the same bindings on its class.
const bindings =
    \\bind TAG <Button-1> {::ztk::priv::entry click %W %x %y}
    \\bind TAG <B1-Motion> {::ztk::priv::entry drag %W %x %y}
    \\bind TAG <ButtonRelease-1> {::ztk::priv::entry release %W %x %y}
    \\bind TAG <Motion> {::ztk::priv::entry motion %W %x %y}
    \\bind TAG <Leave> {::ztk::priv::entry leave %W}
    \\bind TAG <Shift-MouseWheel> {%W xview scroll [expr {-%D / 30.0}] units}
    \\bind TAG <Double-Button-1> {::ztk::priv::entry word %W %x %y}
    \\bind TAG <Triple-Button-1> {::ztk::priv::entry all %W}
    \\bind TAG <Shift-Button-1> {::ztk::priv::entry extend %W %x %y}
    \\bind TAG <Key-Left> {::ztk::priv::entry move %W prev_char 0}
    \\bind TAG <Key-Right> {::ztk::priv::entry move %W next_char 0}
    \\bind TAG <Shift-Key-Left> {::ztk::priv::entry move %W prev_char 1}
    \\bind TAG <Shift-Key-Right> {::ztk::priv::entry move %W next_char 1}
    \\bind TAG <Control-Key-Left> {::ztk::priv::entry move %W prev_word 0}
    \\bind TAG <Control-Key-Right> {::ztk::priv::entry move %W next_word 0}
    \\bind TAG <Key-Home> {::ztk::priv::entry move %W line_start 0}
    \\bind TAG <Key-End> {::ztk::priv::entry move %W line_end 0}
    \\bind TAG <Shift-Key-Home> {::ztk::priv::entry move %W line_start 1}
    \\bind TAG <Shift-Key-End> {::ztk::priv::entry move %W line_end 1}
    \\bind TAG <Key-BackSpace> {::ztk::priv::entry backspace %W}
    \\bind TAG <Key-Delete> {::ztk::priv::entry delete %W}
    \\bind TAG <Control-Key-a> {::ztk::priv::entry move %W line_start 0}
    \\bind TAG <Control-Key-e> {::ztk::priv::entry move %W line_end 0}
    \\bind TAG <Control-Key-x> {event generate %W <<Cut>>}
    \\bind TAG <Control-Key-c> {event generate %W <<Copy>>}
    \\bind TAG <Control-Key-v> {event generate %W <<Paste>>}
    \\bind TAG <Control-Key-z> {event generate %W <<Undo>>}
    \\bind TAG <Control-Key-Z> {event generate %W <<Redo>>}
    \\bind TAG <Control-Key-y> {event generate %W <<Redo>>}
    \\bind TAG <Control-Key-slash> {event generate %W <<SelectAll>>}
    \\bind TAG <Control-Key-backslash> {event generate %W <<SelectNone>>}
    \\bind TAG <<Cut>> {::ztk::priv::entry cut %W}
    \\bind TAG <<Copy>> {::ztk::priv::entry copy %W}
    \\bind TAG <<Paste>> {::ztk::priv::entry paste %W}
    \\bind TAG <<Clear>> {::ztk::priv::entry clear %W}
    \\bind TAG <<SelectAll>> {::ztk::priv::entry selectall %W}
    \\bind TAG <<SelectNone>> {::ztk::priv::entry selectnone %W}
    \\bind TAG <<Undo>> {::ztk::priv::entry undo %W}
    \\bind TAG <<Redo>> {::ztk::priv::entry redo %W}
    \\bind TAG <Key> {::ztk::priv::entry insert %W %A}
    \\bind TAG <Control-Key> {# no edit}
    \\bind TAG <Alt-Key> {# no edit}
    \\bind TAG <Key-Return> {# no edit}
    \\bind TAG <Key-Escape> {# no edit}
    \\bind TAG <Key-Tab> {# no edit}
    \\bind TAG <FocusIn> {::ztk::priv::entry focusin %W}
    \\bind TAG <FocusOut> {::ztk::priv::entry focusout %W}
;

/// Adds the class bindings of an entry to the tag.
pub fn bindClass(app: *App, tag: []const u8) !void {
    const script = try std.mem.replaceOwned(u8, app.gpa, bindings, "TAG", tag);
    defer app.gpa.free(script);
    _ = try app.it.eval(script);
}

pub fn register(app: *App) !void {
    const it = app.it;
    try it.register("entry", widget.classCommand(&class));
    try app.classes.put(app.gpa, "entry", &class);
    try it.register("ztk::priv::entry", cmdEntry);
    try it.register("ztk::priv::entry_var", cmdVar);
    try bindClass(app, "Entry");
}
