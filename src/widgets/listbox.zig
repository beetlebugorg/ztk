//! The listbox class: a list of text rows with a selection. The rows
//! are an array of items, and each item has its text, its selection
//! flag, and its own colors from `itemconfigure`. The active row and the
//! anchor are indexes into the array. An insert or a delete moves them,
//! and the selection flags move with their items.
//!
//! The rows all have one height: the line of the font and the padding of
//! the part `::item`. The views of `scroll.zig` keep the offsets in
//! logical pixels. `yview` with a whole count of units or with `moveto`
//! puts a row at the top, and a fraction of a unit (a touchpad) scrolls
//! by pixels. The paint draws only the rows in the window.
//!
//! The class bindings call `::ztk::priv::listbox`. It does the selection
//! of the four modes (`single`, `browse`, `multiple`, `extended`) that
//! the manual page of `listbox` gives. A drag in `extended` mode keeps a
//! copy of the selection from its start, so that the rows between the
//! anchor and the pointer change and the other rows go back to that
//! copy. A change by the user sends `<<ListboxSelect>>`.
//!
//! `-listvariable` links the rows to a global list variable. A change
//! of the rows writes the variable, and a write of the variable replaces
//! the texts and keeps the selection of the rows that stay.
//!
//! When the selection is one row and it changes to another row, the
//! selection background eases from the old row to the new row. The
//! paint notes the move, so the render thread moves the background. The
//! parts are `::item`, `::selection`, `::active`, and `::empty` (the
//! text of `-emptytext`).
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
const easing = @import("../easing.zig");
const focus = @import("../focus.zig");
const varlink = @import("../varlink.zig");
const scroll = @import("../scroll.zig");
const style_mod = @import("../style.zig");
const App = @import("../app.zig").App;
const Spec = options.Spec;
const Widget = widget.Widget;
const Value = ztcl.Value;

const state_words = [_][]const u8{ "disabled", "normal" };
const active_words = [_][]const u8{ "dotbox", "none", "underline" };

/// The options of `wish` 8.6.16 for `listbox`, in its order, then the additions of ztk.
pub const specs = [_]Spec{
    .{ .name = "-activestyle", .db_name = "activeStyle", .db_class = "ActiveStyle", .type = .word, .default = "dotbox", .words = &active_words },
    .{ .name = "-background", .db_name = "background", .db_class = "Background", .type = .color, .default = "#ffffff", .from_style = true, .style_prop = .background },
    .{ .name = "-bd", .type = .synonym, .target = "-borderwidth" },
    .{ .name = "-bg", .type = .synonym, .target = "-background" },
    .{ .name = "-borderwidth", .db_name = "borderWidth", .db_class = "BorderWidth", .type = .pixels, .default = "1", .from_style = true, .style_prop = .border_width },
    .{ .name = "-cursor", .db_name = "cursor", .db_class = "Cursor", .type = .string, .allow_empty = true },
    .{ .name = "-disabledforeground", .db_name = "disabledForeground", .db_class = "DisabledForeground", .type = .color, .default = "#a3a3a3" },
    .{ .name = "-exportselection", .db_name = "exportSelection", .db_class = "ExportSelection", .type = .boolean, .default = "1" },
    .{ .name = "-fg", .type = .synonym, .target = "-foreground" },
    .{ .name = "-font", .db_name = "font", .db_class = "Font", .type = .font, .default = "TkDefaultFont" },
    .{ .name = "-foreground", .db_name = "foreground", .db_class = "Foreground", .type = .color, .default = "#000000", .from_style = true },
    .{ .name = "-height", .db_name = "height", .db_class = "Height", .type = .int, .default = "10" },
    .{ .name = "-highlightbackground", .db_name = "highlightBackground", .db_class = "HighlightBackground", .type = .color, .default = "#d9d9d9" },
    .{ .name = "-highlightcolor", .db_name = "highlightColor", .db_class = "HighlightColor", .type = .color, .default = "#000000" },
    .{ .name = "-highlightthickness", .db_name = "highlightThickness", .db_class = "HighlightThickness", .type = .pixels, .default = "1" },
    .{ .name = "-justify", .db_name = "justify", .db_class = "Justify", .type = .justify, .default = "left" },
    .{ .name = "-relief", .db_name = "relief", .db_class = "Relief", .type = .relief, .default = "sunken", .from_style = true },
    .{ .name = "-selectbackground", .db_name = "selectBackground", .db_class = "Foreground", .type = .color, .default = "#c3c3c3" },
    .{ .name = "-selectborderwidth", .db_name = "selectBorderWidth", .db_class = "BorderWidth", .type = .pixels, .default = "0" },
    .{ .name = "-selectforeground", .db_name = "selectForeground", .db_class = "Background", .type = .color, .default = "#000000" },
    .{ .name = "-selectmode", .db_name = "selectMode", .db_class = "SelectMode", .type = .string, .default = "browse" },
    .{ .name = "-setgrid", .db_name = "setGrid", .db_class = "SetGrid", .type = .boolean, .default = "0" },
    .{ .name = "-state", .db_name = "state", .db_class = "State", .type = .state, .default = "normal", .words = &state_words },
    .{ .name = "-takefocus", .db_name = "takeFocus", .db_class = "TakeFocus", .type = .string, .allow_empty = true },
    .{ .name = "-width", .db_name = "width", .db_class = "Width", .type = .int, .default = "20" },
    .{ .name = "-xscrollcommand", .db_name = "xScrollCommand", .db_class = "ScrollCommand", .type = .script, .allow_empty = true },
    .{ .name = "-yscrollcommand", .db_name = "yScrollCommand", .db_class = "ScrollCommand", .type = .script, .allow_empty = true },
    .{ .name = "-listvariable", .db_name = "listVariable", .db_class = "Variable", .type = .variable, .allow_empty = true },
    .{ .name = "-emptytext", .db_name = "emptyText", .db_class = "EmptyText", .type = .string, .allow_empty = true },
};

pub const trace_command = "::ztk::priv::listboxvar";

pub const class: widget.Class = .{
    .command = "listbox",
    .tk_class = "Listbox",
    .role = "listbox",
    .focusable = true,
    .specs = &specs,
    .init = init,
    .deinit = deinit,
    .teardown = teardown,
    .configured = configured,
    .retrace = retrace,
    .trace_command = trace_command,
    .traced_var = tracedVar,
    .measure = measure,
    .paint = paintListbox,
    .subcommand = subcommand,
    .bad_option_list = "activate, bbox, cget, configure, curselection, delete, get, index, insert, itemcget, itemconfigure, nearest, scan, see, selection, size, xview, or yview",
};

/// The names of the item options, in the order of `itemconfigure`.
const item_names = [_][]const u8{ "-background", "-foreground", "-selectbackground", "-selectforeground" };

const ItemOpts = struct {
    text: [4][]u8 = .{ &.{}, &.{}, &.{}, &.{} },
    color: [4]?geom.Color = .{ null, null, null, null },
};

const Item = struct {
    text: []u8,
    sel: bool = false,
    opts: ?*ItemOpts = null,
};

pub const Data = struct {
    items: std.ArrayListUnmanaged(Item) = .empty,
    sel_count: usize = 0,
    active: i64 = 0,
    anchor: i64 = 0,
    vx: scroll.View = .{},
    vy: scroll.View = .{},
    var_name: []u8 = &.{},
    /// True while the listbox writes its variable.
    writing: bool = false,
    /// The widest text, or null when the rows changed.
    max_w: ?i32 = null,
    max_font: @import("../text/font.zig").FontDesc = .{},
    /// The state of a drag: the row of the last motion, or -1, and the
    /// selection at the start of an `extended` drag.
    prev: i64 = -1,
    saved: ?std.ArrayListUnmanaged(usize) = null,
    /// The mark of `scan mark`: the pointer and the offsets.
    mark: [2]i32 = .{ 0, 0 },
    mark_pos: [2]f64 = .{ 0, 0 },
    /// The move of the selection background between rows.
    hl_row: i64 = -1,
    hl_from: f64 = 0,
    hl_start: i64 = 0,
    hl_moving: bool = false,
    item_anim: paint.PartAnim = .{},
    sel_anim: paint.PartAnim = .{},
    active_anim: paint.PartAnim = .{},
};

fn data(w: *const Widget) *Data {
    return @ptrCast(@alignCast(w.data.?));
}

fn tracedVar(w: *const Widget) []const u8 {
    return data(w).var_name;
}

fn init(w: *Widget) anyerror!void {
    const d = try w.app.gpa.create(Data);
    d.* = .{};
    w.data = d;
}

fn freeItem(gpa: std.mem.Allocator, item: *Item) void {
    gpa.free(item.text);
    if (item.opts) |o| {
        for (o.text) |t| gpa.free(t);
        gpa.destroy(o);
    }
}

fn deinit(w: *Widget) void {
    const d = data(w);
    const gpa = w.app.gpa;
    for (d.items.items) |*item| freeItem(gpa, item);
    d.items.deinit(gpa);
    if (d.saved) |*s| s.deinit(gpa);
    gpa.free(d.var_name);
    gpa.destroy(d);
    w.data = null;
}

fn teardown(w: *Widget) void {
    const d = data(w);
    varlink.remove(w, d.var_name, trace_command);
    w.app.gpa.free(d.var_name);
    d.var_name = &.{};
}

fn retrace(w: *Widget) void {
    const d = data(w);
    varlink.remove(w, d.var_name, trace_command);
    varlink.add(w, d.var_name, trace_command) catch {};
}

fn int(w: *const Widget, comptime name: []const u8) i64 {
    const v = options.get(w, name).value;
    return if (v == .int) v.int else if (v == .pixels) v.pixels else 0;
}

fn disabled(w: *const Widget) bool {
    const v = options.get(w, "-state").value;
    return v == .word and v.word == 0;
}

const Mode = enum { single, browse, multiple, extended, other };

fn mode(w: *const Widget) Mode {
    const s = options.get(w, "-selectmode");
    return std.meta.stringToEnum(Mode, if (s.set) s.text else "browse") orelse .other;
}

fn count(w: *const Widget) i64 {
    return @intCast(data(w).items.items.len);
}

fn repaint(w: *Widget) void {
    w.invalidate(.{ .style = false, .measure = false, .layout = false, .paint = true });
}

/// The rows changed: the size, the widest text, and the views.
fn rowsChanged(w: *Widget) void {
    data(w).max_w = null;
    const h = int(w, "-height");
    const wd = int(w, "-width");
    w.invalidate(.{ .style = false, .measure = h <= 0 or wd <= 0, .layout = h <= 0 or wd <= 0, .paint = true });
}

// ---- Geometry ----

fn itemStyle(w: *Widget) style_mod.Style {
    return paint.partStyle(w, "item", &data(w).item_anim).style;
}

fn rowH(w: *Widget) i32 {
    const it = itemStyle(w);
    return @max(paint.lineHeight(w.app, w.style.font) + it.padding.top + it.padding.bottom + 2 * @as(i32, @intCast(int(w, "-selectborderwidth"))), 1);
}

fn content(w: *Widget) geom.Rect {
    const ins = paint.insets(&w.style);
    return .{ .x = ins.left, .y = ins.top, .w = @max(w.geom.w - ins.horizontal(), 0), .h = @max(w.geom.h - ins.vertical(), 0) };
}

fn maxWidth(w: *Widget) i32 {
    const d = data(w);
    if (d.max_w) |m| if (std.meta.eql(d.max_font, w.style.font)) return m;
    var m: i32 = 0;
    for (d.items.items) |item| m = @max(m, paint.textSize(w.app, item.text, w.style.font).w);
    d.max_w = m;
    d.max_font = w.style.font;
    return m;
}

/// The width of the content of the rows, with the padding of `::item`.
fn fullWidth(w: *Widget) i32 {
    const it = itemStyle(w);
    return maxWidth(w) + it.padding.left + it.padding.right;
}

/// Sets the sizes of the views from the rows and the window.
fn sync(w: *Widget) void {
    w.app.ensureStyle(w);
    const d = data(w);
    const c = content(w);
    d.vy.setSize(@floatFromInt(count(w) * rowH(w)), @floatFromInt(c.h));
    d.vx.setSize(@floatFromInt(fullWidth(w)), @floatFromInt(c.w));
}

fn report(w: *Widget) void {
    const d = data(w);
    scroll.report(w, &d.vx, "-xscrollcommand");
    scroll.report(w, &d.vy, "-yscrollcommand");
}

fn measure(w: *Widget) geom.Size {
    w.app.ensureStyle(w);
    const ins = paint.insets(&w.style);
    const it = itemStyle(w);
    var cw: i64 = int(w, "-width");
    cw = if (cw > 0) cw * paint.zeroWidth(w.app, w.style.font) + it.padding.left + it.padding.right else fullWidth(w);
    var rows = int(w, "-height");
    if (rows <= 0) rows = @max(count(w), 1);
    const ch = std.math.clamp(rows, 0, 1 << 16) * rowH(w);
    return .{ .w = num.add(@intCast(std.math.clamp(cw, 0, 1 << 20)), ins.horizontal()), .h = num.add(@intCast(ch), ins.vertical()) };
}

/// The offset of a view now: its offset, or a point of its smooth move.
/// It has no side effect, for the pointer and `nearest`.
fn viewNow(w: *Widget, v: *const scroll.View) f64 {
    if (!v.moving) return v.pos;
    const since = w.app.platform.nowUs() - v.start_us;
    if (since >= v.len_us) return v.pos;
    const p = easing.Timing.ease_out.eval(@as(f32, @floatFromInt(@max(since, 0))) / @as(f32, @floatFromInt(v.len_us)));
    return v.from + (v.pos - v.from) * p;
}

/// The row nearest to the y coordinate of the widget, or -1 for no rows.
fn nearest(w: *Widget, y: i64) i64 {
    sync(w);
    const n = count(w);
    if (n == 0) return -1;
    const c = content(w);
    const rh = rowH(w);
    const yy = std.math.clamp(y, c.y, c.y + @max(c.h, 1) - 1);
    const off = viewNow(w, &data(w).vy);
    const row: i64 = @intFromFloat(@floor((@as(f64, @floatFromInt(yy - c.y)) + off) / @as(f64, @floatFromInt(rh))));
    return std.math.clamp(row, 0, n - 1);
}

// ---- Indexes ----

fn badIndex(it: *ztcl.Interp, t: []const u8) ztcl.Error {
    return it.fail("bad listbox index \"{s}\": must be active, anchor, end, @x,y, or a number", .{t});
}

/// An index of the listbox. `end` is the count of rows with `end_is_size`,
/// and the last row without it.
fn getIndex(w: *Widget, it: *ztcl.Interp, v: Value, end_is_size: bool) ztcl.Error!i64 {
    const d = data(w);
    const t = try it.str(v);
    if (std.mem.eql(u8, t, "active")) return d.active;
    if (std.mem.eql(u8, t, "anchor")) return d.anchor;
    if (std.mem.eql(u8, t, "end")) return if (end_is_size) count(w) else count(w) - 1;
    if (t.len > 0 and t[0] == '@') {
        const comma = std.mem.indexOfScalar(u8, t, ',') orelse return badIndex(it, t);
        _ = std.fmt.parseInt(i64, t[1..comma], 10) catch return badIndex(it, t);
        const y = std.fmt.parseInt(i64, t[comma + 1 ..], 10) catch return badIndex(it, t);
        return nearest(w, y);
    }
    const s = std.mem.trim(u8, t, " \t\n");
    return std.fmt.parseInt(i64, s, 0) catch badIndex(it, t);
}

fn clampRow(w: *const Widget, i: i64) i64 {
    return std.math.clamp(i, 0, @max(count(w) - 1, 0));
}

// ---- The rows and the selection ----

fn setSel(d: *Data, i: usize, on: bool) void {
    const item = &d.items.items[i];
    if (item.sel == on) return;
    item.sel = on;
    if (on) d.sel_count += 1 else d.sel_count -= 1;
}

/// Sets or clears the selection from `a` to `b`, in either order.
fn selectRange(w: *Widget, a: i64, b: i64, on: bool) void {
    const n = count(w);
    if (n == 0) return;
    const lo = std.math.clamp(@min(a, b), 0, n);
    const hi = std.math.clamp(@max(a, b), -1, n - 1);
    var i = lo;
    while (i <= hi) : (i += 1) setSel(data(w), @intCast(i), on);
    repaint(w);
}

fn includes(w: *const Widget, i: i64) bool {
    if (i < 0 or i >= count(w)) return false;
    return data(w).items.items[@intCast(i)].sel;
}

fn insertRows(w: *Widget, at_in: i64, texts: []const []const u8) !void {
    const d = data(w);
    const gpa = w.app.gpa;
    const at: usize = @intCast(std.math.clamp(at_in, 0, count(w)));
    try d.items.ensureUnusedCapacity(gpa, texts.len);
    var made: std.ArrayListUnmanaged(Item) = .empty;
    defer made.deinit(gpa);
    try made.ensureTotalCapacity(gpa, texts.len);
    errdefer for (made.items) |*item| freeItem(gpa, item);
    for (texts) |t| made.appendAssumeCapacity(.{ .text = try gpa.dupe(u8, t) });
    d.items.insertSliceAssumeCapacity(at, made.items);
    made.clearRetainingCapacity();
    const k: i64 = @intCast(texts.len);
    if (d.active >= @as(i64, @intCast(at))) d.active += k;
    if (d.anchor >= @as(i64, @intCast(at))) d.anchor += k;
    d.active = clampRow(w, d.active);
    rowsChanged(w);
}

fn deleteRows(w: *Widget, first_in: i64, last_in: i64) void {
    const d = data(w);
    const n = count(w);
    const first = @max(first_in, 0);
    const last = @min(last_in, n - 1);
    if (first > last) return;
    const gpa = w.app.gpa;
    var i = first;
    while (i <= last) : (i += 1) {
        const item = &d.items.items[@intCast(i)];
        if (item.sel) d.sel_count -= 1;
        freeItem(gpa, item);
    }
    const k = last - first + 1;
    d.items.replaceRangeAssumeCapacity(@intCast(first), @intCast(k), &.{});
    inline for (.{ &d.active, &d.anchor }) |p| {
        if (p.* > last) p.* -= k else if (p.* >= first) p.* = first;
    }
    if (d.active >= count(w) and count(w) > 0) d.active = count(w) - 1;
    rowsChanged(w);
}

/// Writes the rows to `-listvariable`. Its traces can delete the widget.
fn writeVar(w: *Widget) ztcl.Error!void {
    const d = data(w);
    if (d.var_name.len == 0) return;
    const a = w.app.it.alloc();
    var out: std.ArrayList(u8) = .empty;
    for (d.items.items, 0..) |item, i| {
        if (i > 0) try out.append(a, ' ');
        try ztcl.value.appendElement(a, &out, item.text, i == 0);
    }
    d.writing = true;
    defer if (w.alive()) {
        data(w).writing = false;
    };
    try varlink.write(w, d.var_name, out.items);
}

/// Replaces the texts with the elements of the variable. The selection
/// and the colors of the rows that stay are kept.
fn loadVar(w: *Widget, text: []const u8) ztcl.Error!void {
    const it = w.app.it;
    const list = try it.list(.{ .str = text });
    const d = data(w);
    const gpa = w.app.gpa;
    const n = d.items.items.len;
    const keep = @min(n, list.len);
    for (d.items.items[0..keep], 0..) |*item, i| {
        const t = try gpa.dupe(u8, try it.str(list[i]));
        gpa.free(item.text);
        item.text = t;
    }
    if (n > keep) {
        deleteRows(w, @intCast(keep), @intCast(n - 1));
    } else if (list.len > keep) {
        var texts: std.ArrayListUnmanaged([]const u8) = .empty;
        defer texts.deinit(gpa);
        for (list[keep..]) |v| try texts.append(gpa, try it.str(v));
        const act = d.active;
        const anc = d.anchor;
        try insertRows(w, @intCast(keep), texts.items);
        d.active = clampRow(w, act);
        d.anchor = anc;
    }
    rowsChanged(w);
}

fn linkVariable(w: *Widget, name: []const u8) ztcl.Error!void {
    const d = data(w);
    try varlink.rename(w, &d.var_name, name, trace_command);
    if (!w.alive() or d.var_name.len == 0) return;
    if (varlink.read(w, d.var_name)) |t| return loadVar(w, t);
    try writeVar(w);
}

fn configured(w: *Widget, changed: []const usize) ztcl.Error!void {
    for (changed) |i| {
        if (!w.alive()) return;
        const name = w.class.specs[i].name;
        if (std.mem.eql(u8, name, "-listvariable")) {
            try linkVariable(w, w.opts[i].text);
        } else if (std.mem.eql(u8, name, "-state")) {
            w.state.disabled = disabled(w);
        } else if (std.mem.eql(u8, name, "-font")) {
            data(w).max_w = null;
        }
    }
}

/// Sends `<<ListboxSelect>>` for a change by the user.
fn fireSelect(w: *Widget) void {
    if (disabled(w)) return;
    const script = std.fmt.allocPrint(w.app.gpa, "event generate {s} <<ListboxSelect>>", .{w.path}) catch return;
    defer w.app.gpa.free(script);
    w.app.callback(script);
}

/// Scrolls the view so that the row shows. A row far from the window
/// goes to the middle.
fn see(w: *Widget, i_in: i64) void {
    sync(w);
    const n = count(w);
    if (n == 0) return;
    const i = std.math.clamp(i_in, 0, n - 1);
    const d = data(w);
    const rh: f64 = @floatFromInt(rowH(w));
    const vis = @max(@floor(d.vy.visible / rh), 1);
    const top = d.vy.pos / rh;
    const row: f64 = @floatFromInt(i);
    var to = d.vy.pos;
    if (row < @ceil(top)) {
        to = if (@ceil(top) - row <= @floor(vis / 3)) row * rh else (row - @floor(vis / 2)) * rh;
    } else if (row + 1 > top + vis) {
        to = if (row + 1 - (top + vis) <= @floor(vis / 3)) (row + 1) * rh - d.vy.visible else (row - @floor(vis / 2)) * rh;
    } else return;
    d.vy.moveTo(w, to, scroll.step_us);
    report(w);
    repaint(w);
}

fn activate(w: *Widget, i: i64) void {
    if (disabled(w)) return;
    data(w).active = clampRow(w, i);
    repaint(w);
}

// ---- Commands ----

fn subcommand(w: *Widget, it: *ztcl.Interp, argv: []const Value) ztcl.Error!?Value {
    const sub = try it.str(argv[1]);
    const d = data(w);
    const a = it.alloc();
    const n = count(w);
    if (std.mem.eql(u8, sub, "activate")) {
        if (argv.len != 3) return it.fail("wrong # args: should be \"{s} activate index\"", .{w.path});
        activate(w, try getIndex(w, it, argv[2], false));
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "bbox")) {
        if (argv.len != 3) return it.fail("wrong # args: should be \"{s} bbox index\"", .{w.path});
        const i = try getIndex(w, it, argv[2], false);
        if (i < 0 or i >= n) return Value.empty;
        sync(w);
        const c = content(w);
        const rh = rowH(w);
        const y = c.y + @as(i32, @intCast(i)) * rh - num.pxRound(d.vy.pos);
        if (y + rh <= c.y or y >= c.y + c.h) return Value.empty;
        const ist = itemStyle(w);
        const tw = paint.textSize(w.app, d.items.items[@intCast(i)].text, w.style.font).w;
        const x = textX(w, c, ist, tw, num.pxRound(d.vx.pos));
        const sbw: i32 = @intCast(int(w, "-selectborderwidth"));
        return .{ .str = try std.fmt.allocPrint(a, "{d} {d} {d} {d}", .{ x, y + ist.padding.top + sbw, tw, paint.lineHeight(w.app, w.style.font) }) };
    }
    if (std.mem.eql(u8, sub, "curselection")) {
        if (argv.len != 2) return it.fail("wrong # args: should be \"{s} curselection\"", .{w.path});
        var out: std.ArrayList(Value) = .empty;
        for (d.items.items, 0..) |item, i| if (item.sel) try out.append(a, .{ .int = @intCast(i) });
        return try ztcl.value.newList(a, out.items);
    }
    if (std.mem.eql(u8, sub, "delete")) {
        if (argv.len != 3 and argv.len != 4) return it.fail("wrong # args: should be \"{s} delete firstIndex ?lastIndex?\"", .{w.path});
        const first = try getIndex(w, it, argv[2], false);
        const last = if (argv.len == 4) try getIndex(w, it, argv[3], false) else first;
        if (disabled(w)) return Value.empty;
        deleteRows(w, first, last);
        try writeVar(w);
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "get")) {
        if (argv.len != 3 and argv.len != 4) return it.fail("wrong # args: should be \"{s} get firstIndex ?lastIndex?\"", .{w.path});
        const first = try getIndex(w, it, argv[2], false);
        if (argv.len == 3) {
            if (first < 0 or first >= n) return Value.empty;
            return .{ .str = try a.dupe(u8, d.items.items[@intCast(first)].text) };
        }
        const last = @min(try getIndex(w, it, argv[3], false), n - 1);
        var out: std.ArrayList(Value) = .empty;
        var i = @max(first, 0);
        while (i <= last) : (i += 1) try out.append(a, .{ .str = try a.dupe(u8, d.items.items[@intCast(i)].text) });
        return try ztcl.value.newList(a, out.items);
    }
    if (std.mem.eql(u8, sub, "index")) {
        if (argv.len != 3) return it.fail("wrong # args: should be \"{s} index index\"", .{w.path});
        return .{ .int = try getIndex(w, it, argv[2], true) };
    }
    if (std.mem.eql(u8, sub, "insert")) {
        if (argv.len < 3) return it.fail("wrong # args: should be \"{s} insert index ?element ...?\"", .{w.path});
        const at = try getIndex(w, it, argv[2], true);
        if (disabled(w) or argv.len == 3) return Value.empty;
        var texts: std.ArrayList([]const u8) = .empty;
        for (argv[3..]) |v| try texts.append(a, try it.str(v));
        try insertRows(w, at, texts.items);
        try writeVar(w);
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "itemcget")) {
        if (argv.len != 4) return it.fail("wrong # args: should be \"{s} itemcget index option\"", .{w.path});
        const item = try itemAt(w, it, argv[2]);
        const k = try itemOption(it, try it.str(argv[3]));
        return .{ .str = if (item.opts) |o| try a.dupe(u8, o.text[k]) else "" };
    }
    if (std.mem.eql(u8, sub, "itemconfigure")) {
        if (argv.len < 3) return it.fail("wrong # args: should be \"{s} itemconfigure index ?-option? ?value? ?-option value ...?\"", .{w.path});
        const item = try itemAt(w, it, argv[2]);
        return try itemConfigure(w, it, item, argv[3..]);
    }
    if (std.mem.eql(u8, sub, "nearest")) {
        if (argv.len != 3) return it.fail("wrong # args: should be \"{s} nearest y\"", .{w.path});
        return .{ .int = nearest(w, try it.int(argv[2])) };
    }
    if (std.mem.eql(u8, sub, "scan")) {
        if (argv.len != 5) return it.fail("wrong # args: should be \"{s} scan mark|dragto x y\"", .{w.path});
        const op = try it.str(argv[2]);
        const x: i32 = @intCast(std.math.clamp(try it.int(argv[3]), -1 << 24, 1 << 24));
        const y: i32 = @intCast(std.math.clamp(try it.int(argv[4]), -1 << 24, 1 << 24));
        sync(w);
        if (std.mem.eql(u8, op, "mark")) {
            d.mark = .{ x, y };
            d.mark_pos = .{ d.vx.pos, d.vy.pos };
        } else if (std.mem.eql(u8, op, "dragto")) {
            d.vx.jump(d.mark_pos[0] - 10 * @as(f64, @floatFromInt(x - d.mark[0])));
            d.vy.jump(d.mark_pos[1] - 10 * @as(f64, @floatFromInt(y - d.mark[1])));
            report(w);
            repaint(w);
        } else return it.fail("bad option \"{s}\": must be mark or dragto", .{op});
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "see")) {
        if (argv.len != 3) return it.fail("wrong # args: should be \"{s} see index\"", .{w.path});
        see(w, try getIndex(w, it, argv[2], false));
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "selection")) {
        if (argv.len != 4 and argv.len != 5) return it.fail("wrong # args: should be \"{s} selection option index ?index?\"", .{w.path});
        const op = try it.str(argv[2]);
        const first = try getIndex(w, it, argv[3], false);
        if (std.mem.eql(u8, op, "anchor")) {
            if (argv.len != 4) return it.fail("wrong # args: should be \"{s} selection anchor index\"", .{w.path});
            if (!disabled(w)) d.anchor = clampRow(w, first);
            return Value.empty;
        }
        if (std.mem.eql(u8, op, "includes")) {
            if (argv.len != 4) return it.fail("wrong # args: should be \"{s} selection includes index\"", .{w.path});
            return .{ .str = if (includes(w, first)) "1" else "0" };
        }
        const on = std.mem.eql(u8, op, "set");
        if (!on and !std.mem.eql(u8, op, "clear")) return it.fail("bad option \"{s}\": must be anchor, clear, includes, or set", .{op});
        const last = if (argv.len == 5) try getIndex(w, it, argv[4], false) else first;
        if (!disabled(w)) selectRange(w, first, last, on);
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "size")) {
        if (argv.len != 2) return it.fail("wrong # args: should be \"{s} size\"", .{w.path});
        return .{ .int = n };
    }
    if (std.mem.eql(u8, sub, "xview") or std.mem.eql(u8, sub, "yview")) return try view(w, it, argv, sub[0] == 'y');
    return null;
}

fn itemAt(w: *Widget, it: *ztcl.Interp, v: Value) ztcl.Error!*Item {
    const i = try getIndex(w, it, v, false);
    if (i < 0 or i >= count(w)) return it.fail("item number \"{s}\" out of range", .{try it.str(v)});
    return &data(w).items.items[@intCast(i)];
}

/// The index of an item option in `item_names`, with `-bg` and `-fg`.
fn itemOption(it: *ztcl.Interp, name: []const u8) ztcl.Error!usize {
    if (std.mem.eql(u8, name, "-bg")) return 0;
    if (std.mem.eql(u8, name, "-fg")) return 1;
    var found: ?usize = null;
    // A prefix of `-bg` or `-fg` is one more match, as in the option tables of Tk.
    if (std.mem.startsWith(u8, "-bg", name)) found = 0;
    if (std.mem.startsWith(u8, "-fg", name)) {
        if (found != null) return it.fail("unknown option \"{s}\"", .{name});
        found = 1;
    }
    if (name.len > 1) for (item_names, 0..) |o, k| {
        if (std.mem.eql(u8, o, name)) return k;
        if (std.mem.startsWith(u8, o, name)) {
            if (found != null) return it.fail("unknown option \"{s}\"", .{name});
            found = k;
        }
    };
    return found orelse it.fail("unknown option \"{s}\"", .{name});
}

fn itemEntry(a: std.mem.Allocator, item: *const Item, k: usize) !Value {
    const t: []const u8 = if (item.opts) |o| o.text[k] else "";
    return ztcl.value.newList(a, &.{ .{ .str = item_names[k] }, Value.empty, Value.empty, Value.empty, .{ .str = try a.dupe(u8, t) } });
}

fn itemConfigure(w: *Widget, it: *ztcl.Interp, item: *Item, args: []const Value) ztcl.Error!Value {
    const a = it.alloc();
    if (args.len == 0) {
        var out: [6]Value = undefined;
        out[0] = try itemEntry(a, item, 0);
        out[1] = try ztcl.value.newList(a, &.{ .{ .str = "-bg" }, .{ .str = "-background" } });
        out[2] = try ztcl.value.newList(a, &.{ .{ .str = "-fg" }, .{ .str = "-foreground" } });
        out[3] = try itemEntry(a, item, 1);
        out[4] = try itemEntry(a, item, 2);
        out[5] = try itemEntry(a, item, 3);
        return try ztcl.value.newList(a, &out);
    }
    if (args.len == 1) return try itemEntry(a, item, try itemOption(it, try it.str(args[0])));
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        const name = try it.str(args[i]);
        const k = try itemOption(it, name);
        if (i + 1 >= args.len) return it.fail("value for \"{s}\" missing", .{name});
        const t = try it.str(args[i + 1]);
        var c: ?geom.Color = null;
        if (t.len > 0) {
            c = geom.Color.parseTk(t) orelse {
                if (t[0] == '#') return it.fail("invalid color name \"{s}\"", .{t});
                return it.fail("unknown color name \"{s}\"", .{t});
            };
        }
        const gpa = w.app.gpa;
        if (item.opts == null) {
            const o = try gpa.create(ItemOpts);
            o.* = .{};
            item.opts = o;
        }
        const o = item.opts.?;
        const owned = try gpa.dupe(u8, t);
        gpa.free(o.text[k]);
        o.text[k] = owned;
        o.color[k] = c;
    }
    repaint(w);
    return Value.empty;
}

fn steps(w: *Widget, y: bool) scroll.Steps {
    const d = data(w);
    if (y) {
        const rh: f64 = @floatFromInt(rowH(w));
        const rows = @floor(d.vy.visible / rh);
        return .{ .unit = rh, .page = (if (rows > 2) rows - 2 else 1) * rh };
    }
    const unit: f64 = @floatFromInt(@max(paint.zeroWidth(w.app, w.style.font), 1));
    return .{ .unit = unit, .page = @max(d.vx.visible - unit, unit) };
}

fn view(w: *Widget, it: *ztcl.Interp, argv: []const Value, y: bool) ztcl.Error!Value {
    sync(w);
    const d = data(w);
    const v = if (y) &d.vy else &d.vx;
    const st = steps(w, y);
    const r = try scroll.command(w, it, argv, v, st, true);
    if (r == null) {
        // `yview index` puts the row at the top, and `xview index` puts the character at the left.
        const i = try getIndex(w, it, argv[2], false);
        v.moveTo(w, @as(f64, @floatFromInt(@max(i, 0))) * st.unit, scroll.step_us);
    } else if (argv.len > 2 and y) {
        // A whole step and `moveto` put a row at the top.
        const op = try it.str(argv[2]);
        const whole = if (std.mem.eql(u8, op, "scroll")) blk: {
            const f = std.fmt.parseFloat(f64, std.mem.trim(u8, try it.str(argv[3]), " ")) catch 0;
            break :blk f == @trunc(f);
        } else true;
        if (whole) {
            const p = v.clampPos(@floor(v.pos / st.unit + 1e-6) * st.unit);
            if (v.moving) v.pos = p else v.jump(p);
        }
    }
    if (argv.len > 2) {
        report(w);
        repaint(w);
    }
    return r orelse Value.empty;
}

// ---- Paint ----

/// The x of the text of a row with the justification, in widget coordinates.
fn textX(w: *Widget, c: geom.Rect, ist: style_mod.Style, tw: i32, xoff: i32) i32 {
    const inner = @max(c.w, fullWidth(w)) - ist.padding.left - ist.padding.right;
    const j = options.get(w, "-justify").value;
    const shift: i32 = if (j == .justify) switch (j.justify) {
        .left => 0,
        .center => @divTrunc(inner - tw, 2),
        .right => inner - tw,
    } else 0;
    return c.x + ist.padding.left + shift - xoff;
}

/// The single selected row, or null.
fn singleSelected(d: *const Data) ?usize {
    if (d.sel_count != 1) return null;
    for (d.items.items, 0..) |item, i| if (item.sel) return i;
    return null;
}

const move_us: i64 = 180_000;

/// The row where the selection background shows, as a fraction during its move.
fn shownHighlight(w: *Widget) f64 {
    const d = data(w);
    const to: f64 = @floatFromInt(d.hl_row);
    if (!d.hl_moving) return to;
    const app = w.app;
    const since = app.platform.nowUs() - d.hl_start;
    if (since >= move_us) {
        d.hl_moving = false;
        return to;
    }
    if (app.part_end) return to;
    app.anim_more = true;
    const timing = easing.Timing.ease_out;
    const p = timing.eval(@as(f32, @floatFromInt(@max(since, 0))) / @as(f32, @floatFromInt(move_us)));
    app.notePartMove(d.hl_start, .{ .duration_ms = @intCast(@divTrunc(move_us, 1000)), .timing = timing }, p);
    return d.hl_from + (to - d.hl_from) * p;
}

/// Notes a change of the single selected row, to start the move of the background.
fn trackHighlight(w: *Widget) void {
    const d = data(w);
    const s = singleSelected(d) orelse {
        d.hl_row = -1;
        d.hl_moving = false;
        return;
    };
    const row: i64 = @intCast(s);
    if (row == d.hl_row) return;
    if (d.hl_row >= 0 and !anim.reduced(w.app) and !w.app.part_end) {
        d.hl_from = shownHighlight(w);
        d.hl_start = w.app.platform.nowUs();
        d.hl_moving = true;
    }
    d.hl_row = row;
}

fn optColor(w: *const Widget, comptime name: []const u8) ?geom.Color {
    const s = options.get(w, name);
    return if (s.set and s.value == .color) s.value.color else null;
}

fn paintListbox(w: *Widget, b: *scene.Builder) anyerror!void {
    const app = w.app;
    const st = anim.shown(app, w);
    try paint.box(w, b, st);
    sync(w);
    report(w);
    const d = data(w);
    const c = content(w);
    if (c.w <= 0 or c.h <= 0) return;
    const first_quad = b.scene.quads.items.len;
    b.pushClip(c);
    defer b.popClip();
    const ist = itemStyle(w);
    const n = d.items.items.len;
    if (n == 0) {
        const e = options.get(w, "-emptytext");
        if (e.set and e.text.len > 0) {
            const es = app.styles.compute(w, "empty", st, app.env);
            try paint.label(w, b, c, e.text, &es, .center, .center);
        }
        return;
    }
    if (d.vy.moving or d.vx.moving) {
        // The rows in the window differ at the start and at the end of a
        // smooth scroll, so the UI thread paints each frame of it.
        if (app.part_move != .blocked) app.part_move = .mixed;
    }
    const yoff = d.vy.shown(w);
    const xoff = num.pxRound(d.vx.shown(w));
    const rh = rowH(w);
    const frh: f64 = @floatFromInt(rh);
    const first: usize = @intFromFloat(@max(@floor(yoff / frh), 0));
    const top_y = c.y - num.pxRound(yoff - @as(f64, @floatFromInt(first)) * frh);
    const ss = paint.partStyle(w, "selection", &d.sel_anim).style;
    var sel_bg = ss.background;
    var sel_fg = ss.color;
    if (optColor(w, "-selectbackground")) |col| sel_bg = col;
    if (optColor(w, "-selectforeground")) |col| sel_fg = col;
    var text_color = st.color;
    if (w.state.disabled) if (optColor(w, "-disabledforeground")) |col| {
        text_color = col;
    };
    const row_w = @max(c.w, fullWidth(w));
    trackHighlight(w);
    const moving_hl = d.hl_row >= 0 and d.hl_moving;
    var sel_box = ss;
    sel_box.background = sel_bg;
    sel_box.color = sel_fg;
    // The background of the single selected row moves on its own.
    if (moving_hl) {
        const at = shownHighlight(w);
        const y = c.y + num.pxRound(at * frh - yoff);
        const o = d.items.items[@intCast(d.hl_row)].opts;
        var bx = sel_box;
        if (o) |oo| if (oo.color[2]) |col| {
            bx.background = col;
        };
        try paint.styledBox(b, .{ .x = c.x - xoff, .y = y, .w = row_w, .h = rh }, &bx);
    }
    const sbw: i32 = @intCast(int(w, "-selectborderwidth"));
    var k: usize = first;
    var y = top_y;
    while (k < n and y < c.y + c.h) : ({
        k += 1;
        y += rh;
    }) {
        const item = d.items.items[k];
        const row: geom.Rect = .{ .x = c.x - xoff, .y = y, .w = row_w, .h = rh };
        var fg = text_color;
        if (item.opts) |o| {
            if (o.color[0]) |col| try b.box(row, .{ .fill = col, .opacity = st.opacity });
            if (o.color[1]) |col| fg = col;
        }
        if (item.sel) {
            fg = sel_fg;
            if (item.opts) |o| if (o.color[3]) |col| {
                fg = col;
            };
            if (!moving_hl) {
                var bx = sel_box;
                if (item.opts) |o| if (o.color[2]) |col| {
                    bx.background = col;
                };
                try paint.styledBox(b, row, &bx);
            }
        }
        var ts = ist;
        ts.color = fg;
        ts.font = w.style.font;
        const tw = paint.textSize(app, item.text, w.style.font).w;
        const lh = paint.lineHeight(app, w.style.font);
        const tx = textX(w, c, ist, tw, xoff);
        const ty = y + ist.padding.top + sbw;
        try paint.label(w, b, .{ .x = tx, .y = ty, .w = tw, .h = lh }, item.text, &ts, .w, .left);
        if (@as(i64, @intCast(k)) == d.active and w.state.focus) {
            const as = options.get(w, "-activestyle").value;
            const style_word: u8 = if (as == .word) as.word else 0;
            if (style_word == 2) {
                try b.box(.{ .x = tx, .y = ty + lh - 1, .w = tw, .h = 1 }, .{ .fill = fg });
            } else if (style_word == 0) {
                const act = paint.partStyle(w, "active", &d.active_anim).style;
                try paint.styledBox(b, row, &act);
            }
        }
    }
    try scroll.paintDrag(w, b, &d.vx, first_quad, 0);
    try scroll.paintDrag(w, b, &d.vy, first_quad, 1);
}

// ---- Bindings ----

fn savedHas(d: *const Data, i: i64) bool {
    const s = d.saved orelse return false;
    for (s.items) |x| if (@as(i64, @intCast(x)) == i) return true;
    return false;
}

fn saveSelection(w: *Widget, empty: bool) !void {
    const d = data(w);
    const gpa = w.app.gpa;
    if (d.saved) |*s| s.clearRetainingCapacity() else d.saved = .empty;
    if (empty) return;
    for (d.items.items, 0..) |item, i| if (item.sel) try d.saved.?.append(gpa, i);
}

/// A press on a row, or the space key on the active row.
fn beginSelect(w: *Widget, el: i64, take_focus: bool) !void {
    const d = data(w);
    if (mode(w) == .multiple) {
        selectRange(w, el, el, !includes(w, el));
    } else {
        selectRange(w, 0, count(w) - 1, false);
        selectRange(w, el, el, true);
        d.anchor = clampRow(w, el);
        try saveSelection(w, true);
        d.prev = el;
    }
    fireSelect(w);
    if (take_focus and w.alive() and !disabled(w)) focus.set(w.app, w);
}

/// The pointer moves to the row `el` with button 1 down.
fn motion(w: *Widget, el: i64) !void {
    const d = data(w);
    if (el == d.prev) return;
    switch (mode(w)) {
        .browse => {
            selectRange(w, 0, count(w) - 1, false);
            selectRange(w, el, el, true);
            d.prev = el;
            fireSelect(w);
        },
        .extended => {
            if (d.prev < 0) {
                d.prev = el;
                selectRange(w, el, el, true);
            }
            if (d.saved == null) try saveSelection(w, false);
            const anchor = d.anchor;
            const on = includes(w, anchor);
            const lo = @max(@min(@min(anchor, d.prev), el), 0);
            const hi = @min(@max(@max(anchor, d.prev), el), count(w) - 1);
            var i = lo;
            while (i <= hi) : (i += 1) {
                const inside = i >= @min(anchor, el) and i <= @max(anchor, el);
                setSel(d, @intCast(i), if (inside) on else savedHas(d, i));
            }
            d.prev = el;
            repaint(w);
            fireSelect(w);
        },
        else => {},
    }
}

/// Shift with a press: extends the selection from the anchor.
fn beginExtend(w: *Widget, el: i64) !void {
    if (mode(w) == .extended and includes(w, data(w).anchor)) return motion(w, el);
    try beginSelect(w, el, true);
}

/// Control with a press: toggles one row in `extended` mode.
fn beginToggle(w: *Widget, el: i64) !void {
    if (mode(w) != .extended) return;
    const d = data(w);
    try saveSelection(w, false);
    d.prev = el;
    d.anchor = clampRow(w, el);
    selectRange(w, el, el, !includes(w, el));
    fireSelect(w);
}

fn upDown(w: *Widget, amount: i64) !void {
    const d = data(w);
    activate(w, d.active + amount);
    see(w, d.active);
    switch (mode(w)) {
        .browse => {
            selectRange(w, 0, count(w) - 1, false);
            selectRange(w, d.active, d.active, true);
            fireSelect(w);
        },
        .extended => {
            selectRange(w, 0, count(w) - 1, false);
            selectRange(w, d.active, d.active, true);
            d.anchor = d.active;
            d.prev = d.active;
            try saveSelection(w, true);
            fireSelect(w);
        },
        else => {},
    }
}

fn extendUpDown(w: *Widget, amount: i64) !void {
    if (mode(w) != .extended) return;
    const d = data(w);
    if (d.saved == null) {
        selectRange(w, d.active, d.active, true);
        try saveSelection(w, false);
    }
    activate(w, d.active + amount);
    see(w, d.active);
    try motion(w, d.active);
}

fn dataExtend(w: *Widget, el: i64) !void {
    const m = mode(w);
    if (m != .extended and m != .multiple) return;
    activate(w, el);
    see(w, el);
    if (m == .extended and includes(w, data(w).anchor)) try motion(w, data(w).active);
}

/// Escape in `extended` mode: the rows of the last drag go back.
fn cancel(w: *Widget) void {
    if (mode(w) != .extended) return;
    const d = data(w);
    if (d.prev < 0) return;
    const lo = @max(@min(d.anchor, d.prev), 0);
    const hi = @min(@max(d.anchor, d.prev), count(w) - 1);
    var i = lo;
    while (i <= hi) : (i += 1) setSel(d, @intCast(i), savedHas(d, i));
    repaint(w);
    fireSelect(w);
}

fn selectAll(w: *Widget) void {
    const d = data(w);
    switch (mode(w)) {
        .single, .browse => {
            selectRange(w, 0, count(w) - 1, false);
            selectRange(w, d.active, d.active, true);
        },
        else => selectRange(w, 0, count(w) - 1, true),
    }
    fireSelect(w);
}

/// Control-Home and Control-End: the first or the last row is the selection.
fn jumpTo(w: *Widget, el: i64) void {
    activate(w, el);
    see(w, el);
    selectRange(w, 0, count(w) - 1, false);
    selectRange(w, el, el, true);
    fireSelect(w);
}

fn copy(w: *Widget) void {
    const d = data(w);
    if (d.sel_count == 0) return;
    const a = w.app.it.alloc();
    var text: std.ArrayList(u8) = .empty;
    var first = true;
    for (d.items.items) |item| if (item.sel) {
        if (!first) text.append(a, '\n') catch return;
        text.appendSlice(a, item.text) catch return;
        first = false;
    };
    var script: std.ArrayList(u8) = .empty;
    script.appendSlice(a, "clipboard clear; clipboard append -- ") catch return;
    ztcl.value.appendElement(a, &script, text.items, false) catch return;
    w.app.callback(script.items);
}

const Action = enum { press, motion, shift, control, updown, extend, data_extend, jump, cancel, all, none, space, extend_active, copy };

/// `::ztk::priv::listbox action path ?args?`
fn cmdListbox(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    app.enter();
    defer app.leave();
    if (argv.len < 3) return it.wrongArgs("::ztk::priv::listbox action window ?arg ...?");
    const act = std.meta.stringToEnum(Action, try it.str(argv[1])) orelse return it.fail("bad action", .{});
    const w = app.find(try it.str(argv[2])) orelse return Value.empty;
    if (w.class.paint != paintListbox) return Value.empty;
    if (disabled(w) and act != .copy) return Value.empty;
    const d = data(w);
    const arg: ?Value = if (argv.len > 3) argv[3] else null;
    const y: i64 = if (argv.len > 4) try it.int(argv[4]) else 0;
    switch (act) {
        .press => if (argv.len > 4) try beginSelect(w, nearest(w, y), true),
        .motion => if (argv.len > 4) {
            // The pointer above or below the window scrolls one row toward it.
            const c = content(w);
            if (y < c.y or y >= c.y + c.h) {
                sync(w);
                const rh: f64 = @floatFromInt(rowH(w));
                d.vy.jump(d.vy.pos + if (y < c.y) -rh else rh);
                report(w);
                repaint(w);
            }
            try motion(w, nearest(w, y));
        },
        .shift => if (argv.len > 4) try beginExtend(w, nearest(w, y)),
        .control => if (argv.len > 4) try beginToggle(w, nearest(w, y)),
        .updown, .extend => {
            const amount: i64 = if (arg) |v| try it.int(v) else 1;
            if (act == .updown) try upDown(w, amount) else try extendUpDown(w, amount);
        },
        .data_extend, .jump => {
            const el = if (arg) |v| try getIndex(w, it, v, false) else 0;
            if (act == .jump) jumpTo(w, el) else try dataExtend(w, el);
        },
        .cancel => cancel(w),
        .all => selectAll(w),
        .none => if (mode(w) != .browse) {
            selectRange(w, 0, count(w) - 1, false);
            fireSelect(w);
        },
        .space => try beginSelect(w, d.active, false),
        .extend_active => try beginExtend(w, d.active),
        .copy => copy(w),
    }
    return Value.empty;
}

/// `::ztk::priv::listboxvar path`: the list variable of a listbox changed.
fn cmdListboxvar(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    app.enter();
    defer app.leave();
    if (argv.len < 2) return Value.empty;
    const w = app.find(try it.str(argv[1])) orelse return Value.empty;
    if (w.class.paint != paintListbox) return Value.empty;
    const d = data(w);
    if (d.writing) return Value.empty;
    const t = varlink.read(w, d.var_name) orelse return Value.empty;
    try loadVar(w, t);
    return Value.empty;
}

pub fn register(app: *App) !void {
    const it = app.it;
    try it.register("listbox", widget.classCommand(&class));
    try app.classes.put(app.gpa, "listbox", &class);
    try it.register("ztk::priv::listbox", cmdListbox);
    try it.register("ztk::priv::listboxvar", cmdListboxvar);
    // ztk has no `event add`, so the keys of the virtual events of Tk
    // send them with `event generate`.
    _ = try it.eval(
        \\bind Listbox <Button-1> {if {[winfo exists %W]} {::ztk::priv::listbox press %W %x %y}}
        \\bind Listbox <B1-Motion> {::ztk::priv::listbox motion %W %x %y}
        \\bind Listbox <B1-Leave> {::ztk::priv::listbox motion %W %x %y}
        \\bind Listbox <B1-Enter> {# The motion scrolls.}
        \\bind Listbox <ButtonRelease-1> {%W activate @%x,%y}
        \\bind Listbox <Shift-Button-1> {::ztk::priv::listbox shift %W %x %y}
        \\bind Listbox <Control-Button-1> {::ztk::priv::listbox control %W %x %y}
        \\bind Listbox <Double-Button-1> {# No action.}
        \\bind Listbox <Button-2> {%W scan mark %x %y}
        \\bind Listbox <B2-Motion> {%W scan dragto %x %y}
        \\bind Listbox <Button-4> {%W yview scroll -5 units}
        \\bind Listbox <Button-5> {%W yview scroll 5 units}
        \\bind Listbox <Shift-Button-4> {%W xview scroll -10 units}
        \\bind Listbox <Shift-Button-5> {%W xview scroll 10 units}
        \\bind Listbox <MouseWheel> {%W yview scroll [expr {-%D / 40.0}] units}
        \\bind Listbox <Shift-MouseWheel> {%W xview scroll [expr {-%D / 30.0}] units}
        \\bind Listbox <Key-Up> {event generate %W <<PrevLine>>}
        \\bind Listbox <Key-Down> {event generate %W <<NextLine>>}
        \\bind Listbox <Shift-Key-Up> {event generate %W <<SelectPrevLine>>}
        \\bind Listbox <Shift-Key-Down> {event generate %W <<SelectNextLine>>}
        \\bind Listbox <Key-Left> {event generate %W <<PrevChar>>}
        \\bind Listbox <Key-Right> {event generate %W <<NextChar>>}
        \\bind Listbox <Control-Key-Left> {event generate %W <<PrevWord>>}
        \\bind Listbox <Control-Key-Right> {event generate %W <<NextWord>>}
        \\bind Listbox <Key-Home> {event generate %W <<LineStart>>}
        \\bind Listbox <Key-End> {event generate %W <<LineEnd>>}
        \\bind Listbox <Control-Key-slash> {event generate %W <<SelectAll>>}
        \\bind Listbox <Control-Key-backslash> {event generate %W <<SelectNone>>}
        \\bind Listbox <Control-Key-c> {event generate %W <<Copy>>}
        \\bind Listbox <<PrevLine>> {::ztk::priv::listbox updown %W -1}
        \\bind Listbox <<NextLine>> {::ztk::priv::listbox updown %W 1}
        \\bind Listbox <<SelectPrevLine>> {::ztk::priv::listbox extend %W -1}
        \\bind Listbox <<SelectNextLine>> {::ztk::priv::listbox extend %W 1}
        \\bind Listbox <<PrevChar>> {%W xview scroll -1 units}
        \\bind Listbox <<NextChar>> {%W xview scroll 1 units}
        \\bind Listbox <<PrevWord>> {%W xview scroll -1 pages}
        \\bind Listbox <<NextWord>> {%W xview scroll 1 pages}
        \\bind Listbox <<LineStart>> {%W xview moveto 0}
        \\bind Listbox <<LineEnd>> {%W xview moveto 1}
        \\bind Listbox <Key-Prior> {%W yview scroll -1 pages; %W activate @0,0}
        \\bind Listbox <Key-Next> {%W yview scroll 1 pages; %W activate @0,0}
        \\bind Listbox <Control-Key-Prior> {%W xview scroll -1 pages}
        \\bind Listbox <Control-Key-Next> {%W xview scroll 1 pages}
        \\bind Listbox <Control-Key-Home> {::ztk::priv::listbox jump %W 0}
        \\bind Listbox <Control-Key-End> {::ztk::priv::listbox jump %W end}
        \\bind Listbox <Control-Shift-Key-Home> {::ztk::priv::listbox data_extend %W 0}
        \\bind Listbox <Control-Shift-Key-End> {::ztk::priv::listbox data_extend %W end}
        \\bind Listbox <Key-space> {::ztk::priv::listbox space %W}
        \\bind Listbox <Key-Select> {::ztk::priv::listbox space %W}
        \\bind Listbox <<Invoke>> {::ztk::priv::listbox space %W}
        \\bind Listbox <Control-Shift-Key-space> {::ztk::priv::listbox extend_active %W}
        \\bind Listbox <Shift-Key-Select> {::ztk::priv::listbox extend_active %W}
        \\bind Listbox <Key-Escape> {::ztk::priv::listbox cancel %W}
        \\bind Listbox <<SelectAll>> {::ztk::priv::listbox all %W}
        \\bind Listbox <<SelectNone>> {::ztk::priv::listbox none %W}
        \\bind Listbox <<Copy>> {::ztk::priv::listbox copy %W}
    );
}
