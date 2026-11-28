//! The spinbox class: an entry with two buttons that step the value
//! through a range (`-from`, `-to`, `-increment`) or a list (`-values`).
//! The text, the editing, the validation, and the class bindings are
//! those of the entry (`entry.zig`), with the flag `spin` in the data of
//! the entry. This file has the options, the buttons, `invoke`, and the
//! repeat of a held button. As in Tk, a press on a button invokes it
//! when the button is released, or after `-repeatdelay` and then each
//! `-repeatinterval` while it is held.
//!
//! `ttk::spinbox` (in `ttk/range.zig`) uses this code with the flag `ttk`
//! of its class. A change of `-values`, `-from`, or `-to` keeps its text,
//! `set` needs a value, and `<<Increment>>` and `<<Decrement>>` step it.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const geom = @import("../base/geom.zig");
const widget = @import("../widget.zig");
const options = @import("../options.zig");
const paint = @import("../paint.zig");
const scene = @import("../scene.zig");
const path = @import("../path.zig");
const style_mod = @import("../style.zig");
const entry = @import("entry.zig");
const App = @import("../app.zig").App;
const Spec = options.Spec;
const Widget = widget.Widget;
const Value = ztcl.Value;
const Elem = entry.Elem;

const state_words = [_][]const u8{ "disabled", "normal", "readonly" };

/// The options of `wish` 8.6.16 in its order, then the additions of ztk.
pub const specs = [_]Spec{
    .{ .name = "-activebackground", .db_name = "activeBackground", .db_class = "Background", .type = .color, .default = "#ececec" },
    .{ .name = "-background", .db_name = "background", .db_class = "Background", .type = .color, .default = "#ffffff", .from_style = true, .style_prop = .background },
    .{ .name = "-bd", .type = .synonym, .target = "-borderwidth" },
    .{ .name = "-bg", .type = .synonym, .target = "-background" },
    .{ .name = "-borderwidth", .db_name = "borderWidth", .db_class = "BorderWidth", .type = .pixels, .default = "1", .from_style = true, .style_prop = .border_width },
    .{ .name = "-buttonbackground", .db_name = "buttonBackground", .db_class = "Background", .type = .color, .default = "#d9d9d9" },
    .{ .name = "-buttoncursor", .db_name = "buttonCursor", .db_class = "Cursor", .type = .string, .allow_empty = true },
    .{ .name = "-buttondownrelief", .db_name = "buttonDownRelief", .db_class = "Relief", .type = .relief, .default = "raised" },
    .{ .name = "-buttonuprelief", .db_name = "buttonUpRelief", .db_class = "Relief", .type = .relief, .default = "raised" },
    .{ .name = "-command", .db_name = "command", .db_class = "Command", .type = .script, .allow_empty = true },
    .{ .name = "-cursor", .db_name = "cursor", .db_class = "Cursor", .type = .cursor, .default = "xterm", .allow_empty = true },
    .{ .name = "-disabledbackground", .db_name = "disabledBackground", .db_class = "DisabledBackground", .type = .color, .default = "#d9d9d9" },
    .{ .name = "-disabledforeground", .db_name = "disabledForeground", .db_class = "DisabledForeground", .type = .color, .default = "#a3a3a3" },
    .{ .name = "-exportselection", .db_name = "exportSelection", .db_class = "ExportSelection", .type = .boolean, .default = "1" },
    .{ .name = "-fg", .type = .synonym, .target = "-foreground" },
    .{ .name = "-font", .db_name = "font", .db_class = "Font", .type = .font, .default = "TkTextFont" },
    .{ .name = "-foreground", .db_name = "foreground", .db_class = "Foreground", .type = .color, .default = "#000000", .from_style = true },
    .{ .name = "-format", .db_name = "format", .db_class = "Format", .type = .string, .allow_empty = true },
    .{ .name = "-from", .db_name = "from", .db_class = "From", .type = .double, .default = "0" },
    .{ .name = "-highlightbackground", .db_name = "highlightBackground", .db_class = "HighlightBackground", .type = .color, .default = "#d9d9d9" },
    .{ .name = "-highlightcolor", .db_name = "highlightColor", .db_class = "HighlightColor", .type = .color, .default = "#000000" },
    .{ .name = "-highlightthickness", .db_name = "highlightThickness", .db_class = "HighlightThickness", .type = .pixels, .default = "1" },
    .{ .name = "-increment", .db_name = "increment", .db_class = "Increment", .type = .double, .default = "1" },
    .{ .name = "-insertbackground", .db_name = "insertBackground", .db_class = "Foreground", .type = .color, .default = "#000000" },
    .{ .name = "-insertborderwidth", .db_name = "insertBorderWidth", .db_class = "BorderWidth", .type = .pixels, .default = "0" },
    .{ .name = "-insertofftime", .db_name = "insertOffTime", .db_class = "OffTime", .type = .int, .default = "300" },
    .{ .name = "-insertontime", .db_name = "insertOnTime", .db_class = "OnTime", .type = .int, .default = "600" },
    .{ .name = "-insertwidth", .db_name = "insertWidth", .db_class = "InsertWidth", .type = .pixels, .default = "2" },
    .{ .name = "-invalidcommand", .db_name = "invalidCommand", .db_class = "InvalidCommand", .type = .script, .allow_empty = true },
    .{ .name = "-invcmd", .type = .synonym, .target = "-invalidcommand" },
    .{ .name = "-justify", .db_name = "justify", .db_class = "Justify", .type = .justify, .default = "left" },
    .{ .name = "-relief", .db_name = "relief", .db_class = "Relief", .type = .relief, .default = "sunken", .from_style = true },
    .{ .name = "-readonlybackground", .db_name = "readonlyBackground", .db_class = "ReadonlyBackground", .type = .color, .default = "#d9d9d9" },
    .{ .name = "-repeatdelay", .db_name = "repeatDelay", .db_class = "RepeatDelay", .type = .int, .default = "400" },
    .{ .name = "-repeatinterval", .db_name = "repeatInterval", .db_class = "RepeatInterval", .type = .int, .default = "100" },
    .{ .name = "-selectbackground", .db_name = "selectBackground", .db_class = "Foreground", .type = .color, .default = "#c3c3c3" },
    .{ .name = "-selectborderwidth", .db_name = "selectBorderWidth", .db_class = "BorderWidth", .type = .pixels, .default = "0" },
    .{ .name = "-selectforeground", .db_name = "selectForeground", .db_class = "Background", .type = .color, .default = "#000000" },
    .{ .name = "-state", .db_name = "state", .db_class = "State", .type = .state, .default = "normal", .words = &state_words },
    .{ .name = "-takefocus", .db_name = "takeFocus", .db_class = "TakeFocus", .type = .string, .allow_empty = true },
    .{ .name = "-textvariable", .db_name = "textVariable", .db_class = "Variable", .type = .variable, .allow_empty = true },
    .{ .name = "-to", .db_name = "to", .db_class = "To", .type = .double, .default = "0" },
    .{ .name = "-validate", .db_name = "validate", .db_class = "Validate", .type = .word, .default = "none", .words = &entry.validate_words },
    .{ .name = "-validatecommand", .db_name = "validateCommand", .db_class = "ValidateCommand", .type = .script, .allow_empty = true },
    .{ .name = "-values", .db_name = "values", .db_class = "Values", .type = .string, .allow_empty = true },
    .{ .name = "-vcmd", .type = .synonym, .target = "-validatecommand" },
    .{ .name = "-width", .db_name = "width", .db_class = "Width", .type = .int, .default = "20" },
    .{ .name = "-wrap", .db_name = "wrap", .db_class = "Wrap", .type = .boolean, .default = "0" },
    .{ .name = "-xscrollcommand", .db_name = "xScrollCommand", .db_class = "ScrollCommand", .type = .script, .allow_empty = true },
} ++ entry.addition_specs;

pub const class: widget.Class = .{
    .command = "spinbox",
    .tk_class = "Spinbox",
    .role = "spin button",
    .focusable = true,
    .specs = &specs,
    .init = init,
    .deinit = entry.deinit,
    .configured = configured,
    .teardown = entry.teardown,
    .retrace = entry.retrace,
    .trace_command = "ztk::priv::entry_var",
    .traced_var = tracedVar,
    .measure = entry.measure,
    .paint = entry.class.paint,
    .subcommand = subcommand,
    .bad_option_list = "bbox, cget, configure, delete, get, icursor, identify, index, insert, invoke, scan, selection, set, validate, or xview",
};

fn tracedVar(w: *const Widget) []const u8 {
    return entry.dataOf(w).var_name;
}

fn init(w: *Widget) anyerror!void {
    try entry.init(w);
    entry.dataOf(w).spin = true;
}

fn dbl(w: *const Widget, comptime name: []const u8) f64 {
    const v = options.get(w, name).value;
    return if (v == .double) v.double else 0;
}

fn values(w: *Widget) ztcl.Error![]const Value {
    const s = options.get(w, "-values");
    if (s.text.len == 0) return &.{};
    return w.app.it.list(.{ .str = s.text });
}

/// True for a format of `%<width>.<precision>` and one of `f`, `e`, `E`, `g`, or `G`, as Tk checks it.
fn validFormat(f: []const u8) bool {
    if (f.len < 2 or f[0] != '%' or f.len > 24) return false;
    var i: usize = 1;
    while (i < f.len and std.ascii.isDigit(f[i])) i += 1;
    if (i < f.len and f[i] == '.') {
        i += 1;
        while (i < f.len and std.ascii.isDigit(f[i])) i += 1;
    }
    return i + 1 == f.len and std.mem.indexOfScalar(u8, "feEgG", f[i]) != null;
}

/// The format of a value with no `-format`: `ComputeFormat` of Tk, from
/// the largest end of the range and the increment.
fn autoFormat(w: *const Widget, buf: []u8) []const u8 {
    var max_v = @max(@abs(dbl(w, "-from")), @abs(dbl(w, "-to")));
    if (max_v == 0) max_v = 1;
    const most: i32 = @intFromFloat(@floor(std.math.log10(max_v)));
    const incr = @abs(dbl(w, "-increment"));
    const least: i32 = if (incr > 1e-300) @intFromFloat(@floor(std.math.log10(incr))) else 0;
    const digits = @max(most - least + 1, 1);
    var e_digits = digits + 4;
    if (digits > 1) e_digits += 1;
    const after = @max(digits - most - 1, 0);
    var f_digits = if (most >= 0) most + after else after;
    if (after > 0) f_digits += 1;
    if (most < 0) f_digits += 1;
    if (f_digits <= e_digits) return std.fmt.bufPrint(buf, "%.{d}f", .{after}) catch "%f";
    return std.fmt.bufPrint(buf, "%.{d}e", .{digits - 1}) catch "%e";
}

/// The text of a value, with `format` of the interpreter.
fn formatValue(w: *Widget, v: f64) ztcl.Error![]const u8 {
    const it = w.app.it;
    var buf: [32]u8 = undefined;
    const user = options.get(w, "-format").text;
    const f = if (user.len > 0) user else autoFormat(w, &buf);
    const r = try it.callWords(&.{ .{ .str = "format" }, .{ .str = try it.alloc().dupe(u8, f) }, .{ .double = v } });
    return it.alloc().dupe(u8, try it.str(r));
}

/// The number at the start of a text, as `sscanf("%lf")`, or null.
fn scanDouble(text: []const u8) ?f64 {
    const s = std.mem.trimStart(u8, text, " \t\n\r");
    var n = s.len;
    while (n > 0) : (n -= 1) {
        if (std.fmt.parseFloat(f64, s[0..n])) |v| {
            if (!std.math.isNan(v)) return v;
        } else |_| {}
    }
    return null;
}

fn configured(w: *Widget, changed: []const usize) ztcl.Error!void {
    try entry.configured(w, changed);
    if (w.life == .dead) return;
    const it = w.app.it;
    const d = entry.dataOf(w);
    var range = false;
    var vals = false;
    for (changed) |i| {
        const name = w.class.specs[i].name;
        if (std.mem.eql(u8, name, "-from") or std.mem.eql(u8, name, "-to")) range = true;
        if (std.mem.eql(u8, name, "-values")) vals = true;
        if (std.mem.eql(u8, name, "-format")) {
            const f = w.opts[i].text;
            if (f.len > 0 and !validFormat(f)) {
                const bad = try it.alloc().dupe(u8, f);
                const old = try it.alloc().dupe(u8, d.format[0..d.format_len]);
                try options.setOne(w, it, i, old, widget.Dirty.none);
                return it.fail("bad spinbox format specifier \"{s}\"", .{bad});
            }
            // A valid format is at most 24 bytes.
            @memcpy(d.format[0..f.len], f);
            d.format_len = f.len;
        }
    }
    const old_from = d.from;
    const old_to = d.to;
    const from = dbl(w, "-from");
    const to = dbl(w, "-to");
    if (w.class.ttk) {
        d.from = from;
        d.to = to;
        return;
    }
    if (range and from > to) {
        const a = it.alloc();
        for ([_][]const u8{ "-from", "-to" }, [_]f64{ old_from, old_to }) |name, v| {
            for (w.class.specs, 0..) |s, i| if (std.mem.eql(u8, s.name, name)) {
                try options.setOne(w, it, i, try options.formatDouble(a, v), widget.Dirty.none);
            };
        }
        return it.fail("-to value must be greater than -from value", .{});
    }
    d.from = from;
    d.to = to;
    const list = try values(w);
    if (vals and list.len > 0) {
        d.e_index = 0;
        entry.valueChanged(w, try it.str(list[0]));
    } else if (list.len == 0 and from != to and (from != old_from or to != old_to)) {
        // A text that is not a number becomes `-from`. A number goes into the range.
        var v = scanDouble(d.edit.text()) orelse from;
        v = std.math.clamp(v, from, to);
        entry.valueChanged(w, try formatValue(w, v));
    }
}

/// `invoke`: steps the value up or down and runs `-command` with `%d` up or down.
pub fn invoke(w: *Widget, elem: Elem) ztcl.Error!void {
    if (elem != .buttonup and elem != .buttondown) return;
    if (w.state.disabled) return;
    const d = entry.dataOf(w);
    const it = w.app.it;
    const up = elem == .buttonup;
    const wrap = options.get(w, "-wrap").value == .boolean and options.get(w, "-wrap").value.boolean;
    const list = try values(w);
    if (list.len > 0) {
        const n = list.len;
        // The index of the shown text when the list has it, else the last index.
        for (list, 0..) |v, k| if (std.mem.eql(u8, try it.str(v), d.edit.text())) {
            d.e_index = k;
            break;
        };
        var i: usize = undefined;
        if (up) {
            i = if (d.e_index + 1 >= n) (if (wrap) 0 else n - 1) else d.e_index + 1;
        } else {
            i = if (d.e_index == 0) (if (wrap) n - 1 else 0) else @min(d.e_index - 1, n - 1);
        }
        d.e_index = i;
        entry.valueChanged(w, try it.str(list[i]));
    } else if (d.from != d.to) {
        const incr = dbl(w, "-increment");
        var v: f64 = d.from;
        if (scanDouble(d.edit.text())) |x| {
            v = if (up) x + incr else x - incr;
            if (up) {
                if (v > d.to) v = if (wrap) d.from else d.to else if (v < d.from) v = d.from;
            } else {
                if (v < d.from) v = if (wrap) d.to else d.from else if (v > d.to) v = d.to;
            }
        }
        entry.valueChanged(w, try formatValue(w, v));
    }
    if (w.life == .dead) return;
    const cmd = options.get(w, "-command");
    if (cmd.text.len > 0 and w.class.ttk) {
        w.app.callback(cmd.text);
    } else if (cmd.text.len > 0) {
        const script = try entry.expand(w, it.alloc(), cmd.text, if (up) "up" else "down", "", 0, .button);
        w.app.callback(script);
    }
}

const elem_list = "none, buttondown, or buttonup";

fn parseElem(it: *ztcl.Interp, text: []const u8, comptime what: []const u8) ztcl.Error!Elem {
    const names = [_]Elem{ .none, .buttondown, .buttonup };
    var found: ?Elem = null;
    for (names) |e| {
        const n = @tagName(e);
        if (std.mem.eql(u8, n, text)) return e;
        if (text.len > 0 and std.mem.startsWith(u8, n, text)) {
            if (found != null) return it.fail("ambiguous " ++ what ++ " \"{s}\": must be " ++ elem_list, .{text});
            found = e;
        }
    }
    return found orelse it.fail("bad " ++ what ++ " \"{s}\": must be " ++ elem_list, .{text});
}

pub fn selectionElement(w: *Widget, it: *ztcl.Interp, argv: []const Value) ztcl.Error!Value {
    const d = entry.dataOf(w);
    if (argv.len == 3) return .{ .str = @tagName(d.sel_elem) };
    if (argv.len != 4) return it.fail("wrong # args: should be \"{s} selection element ?elemName?\"", .{w.path});
    d.sel_elem = try parseElem(it, try it.str(argv[3]), "selection element");
    entry.changed(w);
    return Value.empty;
}

fn identifyAt(w: *Widget, x: i32, y: i32) Elem {
    if (x < 0 or y < 0 or x >= w.geom.w or y >= w.geom.h) return .none;
    w.app.ensureStyle(w);
    const ar = entry.areas(w, &w.style);
    for ([_]?geom.Rect{ ar.up, ar.down }, [_]Elem{ .buttonup, .buttondown }) |r, e| {
        const q = r orelse continue;
        if (x >= q.x and x < q.x + q.w and y >= q.y and y < q.y + q.h) return e;
    }
    return .entry;
}

fn subcommand(w: *Widget, it: *ztcl.Interp, argv: []const Value) ztcl.Error!?Value {
    const sub = try it.str(argv[1]);
    const d = entry.dataOf(w);
    if (std.mem.eql(u8, sub, "invoke")) {
        if (argv.len != 3) return it.fail("wrong # args: should be \"{s} invoke elemName\"", .{w.path});
        try invoke(w, try parseElem(it, try it.str(argv[2]), "element"));
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "set") and w.class.ttk) {
        if (argv.len != 3) return it.fail("wrong # args: should be \"{s} set value\"", .{w.path});
        entry.valueChanged(w, try it.alloc().dupe(u8, try it.str(argv[2])));
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "set")) {
        if (argv.len != 2 and argv.len != 3) return it.fail("wrong # args: should be \"{s} set ?string?\"", .{w.path});
        if (argv.len == 3) entry.valueChanged(w, try it.alloc().dupe(u8, try it.str(argv[2])));
        if (w.life == .dead) return Value.empty;
        return .{ .str = try it.alloc().dupe(u8, d.edit.text()) };
    }
    if (std.mem.eql(u8, sub, "identify")) {
        if (argv.len != 4) return it.fail("wrong # args: should be \"{s} identify x y\"", .{w.path});
        const x: i32 = @intCast(std.math.clamp(try it.int(argv[2]), -1000000, 1000000));
        const y: i32 = @intCast(std.math.clamp(try it.int(argv[3]), -1000000, 1000000));
        const e = identifyAt(w, x, y);
        if (w.class.ttk) return .{ .str = switch (e) {
            .none => "",
            .buttonup => "uparrow",
            .buttondown => "downarrow",
            else => "textarea",
        } };
        return .{ .str = if (e == .none) "" else @tagName(e) };
    }
    return entry.subcommand(w, it, argv);
}

// ---- The buttons ----

/// The width of the column of the buttons.
pub fn buttonWidth(app: *App, st: *const style_mod.Style) i32 {
    return @max(@divTrunc(paint.lineHeight(app, st.font) * 5, 4), 14);
}

pub fn paintButtons(w: *Widget, b: *scene.Builder, ar: entry.Areas) !void {
    const d = entry.dataOf(w);
    const gpa = w.app.gpa;
    for ([_]?geom.Rect{ ar.up, ar.down }, [_]Elem{ .buttonup, .buttondown }) |r0, e| {
        const r = r0 orelse continue;
        const up = e == .buttonup;
        const st = entry.partStyleAs(w, if (up) "buttonup" else "buttondown", if (up) &d.up else &d.down, d.hover == e, d.sel_elem == e);
        const inner: geom.Rect = .{ .x = r.x + 2, .y = r.y + 2, .w = @max(r.w - 4, 0), .h = @max(r.h - 3, 0) };
        try paint.styledBox(b, inner, &st);
        // A chevron that points up or down.
        const cx = @as(f32, @floatFromInt(r.x)) + @as(f32, @floatFromInt(r.w)) / 2;
        const cy = @as(f32, @floatFromInt(r.y)) + @as(f32, @floatFromInt(r.h)) / 2 + (if (up) @as(f32, 0.5) else -0.5);
        const s = std.math.clamp(@as(f32, @floatFromInt(@min(r.w, r.h * 2))) * 0.16, 2.5, 6);
        const dy: f32 = if (up) s / 2 else -s / 2;
        var sh: path.Shape = .{};
        defer sh.deinit(gpa);
        try sh.stroke(gpa, &.{ .{ .x = cx - s, .y = cy + dy }, .{ .x = cx, .y = cy - dy }, .{ .x = cx + s, .y = cy + dy } }, 1.5, true);
        try paint.fillShape(b, &sh, st.color, st.opacity);
    }
}

// ---- The pointer and the repeat ----

fn cancelRepeat(w: *Widget) void {
    const d = entry.dataOf(w);
    if (d.repeat) |id| _ = w.app.loop.cancel(id);
    d.repeat = null;
}

fn armRepeat(w: *Widget, comptime option: []const u8) void {
    cancelRepeat(w);
    if (!w.alive()) return;
    const v = options.get(w, option).value;
    const ms = if (v == .int) v.int else 0;
    if (ms <= 0) return;
    entry.dataOf(w).repeat = w.app.loop.addNative(ms *| 1000, repeatFire, w) catch null;
}

fn repeatFire(ctx: ?*anyopaque) void {
    const w: *Widget = @ptrCast(@alignCast(ctx.?));
    const d = entry.dataOf(w);
    d.repeat = null;
    if (d.pressed == .none) return;
    if (!d.outside) {
        invoke(w, d.pressed) catch |e| w.app.backgroundError(e);
        if (w.life == .dead) return;
        d.repeated += 1;
    }
    armRepeat(w, "-repeatinterval");
}

/// The pointer on a spinbox: a press on a button, a drag in and out of
/// it, and the release. It gives false for a press on the text.
pub fn pointer(w: *Widget, press: bool, drag: bool, release: bool, x: i32, y: i32) ztcl.Error!bool {
    const d = entry.dataOf(w);
    const at = identifyAt(w, x, y);
    if (press) {
        if (at != .buttonup and at != .buttondown) return false;
        if (w.state.disabled) return true;
        d.pressed = at;
        d.sel_elem = at;
        d.repeated = 0;
        d.outside = false;
        armRepeat(w, "-repeatdelay");
        entry.changed(w);
        return true;
    }
    if (d.pressed == .none) return false;
    if (drag) {
        const out = at != d.pressed;
        if (out != d.outside) {
            d.outside = out;
            d.sel_elem = if (out) .none else d.pressed;
            entry.changed(w);
        }
        return true;
    }
    if (!release) return false;
    cancelRepeat(w);
    const elem = d.pressed;
    d.pressed = .none;
    if (d.repeated == 0) try invoke(w, elem);
    if (w.life == .dead) return true;
    d.sel_elem = .none;
    entry.changed(w);
    return true;
}

pub fn register(app: *App) !void {
    const it = app.it;
    try it.register("spinbox", widget.classCommand(&class));
    try app.classes.put(app.gpa, "spinbox", &class);
    try entry.bindClass(app, "Spinbox");
    _ = try it.eval(
        \\bind Spinbox <Key-Up> {%W invoke buttonup}
        \\bind Spinbox <Key-Down> {%W invoke buttondown}
        \\bind Spinbox <<PrevLine>> {%W invoke buttonup}
        \\bind Spinbox <<NextLine>> {%W invoke buttondown}
    );
}
