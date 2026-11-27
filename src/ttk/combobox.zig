//! `ttk::combobox`: a `ttk::entry` with a drop-down list of `-values`.
//! The entry code (`widgets/entry.zig`) has the text, the editing, and
//! an arrow on the right (the flag `combo` of its data). This file has
//! `current` and `set`, and the drop-down list.
//!
//! The list is a popover that the toplevel paints over its widgets after
//! them (part `::popdown`, with the rows in parts `::item` and
//! `::item-active`). It shows below the combobox, or above it when the
//! window has no room below. While the list is open, the combobox holds
//! the grab, so each pointer event of the window goes to its bindings.
//! During the grab the coordinates of a pointer event are those of the
//! combobox, and `::ztk::priv::combo` finds the row under the pointer. The list opens and closes with a fade and
//! a slide of 6 logical pixels. The two paints at the ends of the move go
//! to the render thread as a frame animation. A close keeps the list in
//! the frame until the end of its move, and a native timer removes it.
//! Only one list is open in the program at a time.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const num = @import("../base/num.zig");
const geom = @import("../base/geom.zig");
const widget = @import("../widget.zig");
const options = @import("../options.zig");
const paint = @import("../paint.zig");
const scene = @import("../scene.zig");
const path = @import("../path.zig");
const anim = @import("../anim.zig");
const easing = @import("../base/easing.zig");
const loop_mod = @import("../loop.zig");
const style_mod = @import("../style.zig");
const ttk = @import("widgets.zig");
const entry = @import("../widgets/entry.zig");
const App = @import("../app.zig").App;
const Spec = options.Spec;
const Widget = widget.Widget;
const Value = ztcl.Value;
const s = ttk.s;

/// The open list of the program.
pub const Popdown = struct {
    widget: ?*Widget = null,
    /// The highlighted row, or -1.
    active: i32 = -1,
    /// The first row that shows.
    top: i32 = 0,
    /// The start of the open or the close move.
    move_us: i64 = 0,
    closing: bool = false,
    timer: ?loop_mod.TimerId = null,
    /// A press opened the list and the button is still down.
    drag: bool = false,
};

const move_dur_us: i64 = 150_000;
const slide: f32 = 6;

const specs = options.withHidden(&([_]Spec{
    s("-height", "height", "Height", .string, "10"),
    s("-postcommand", "postCommand", "PostCommand", .script, ""),
    s("-values", "values", "Values", .string, ""),
} ++ ttk.entry_common ++ entry.addition_specs), &entry.specs);

const subs = [_][]const u8{ "bbox", "cget", "configure", "current", "delete", "get", "icursor", "identify", "index", "insert", "instate", "selection", "state", "set", "validate", "xview" };

const base: widget.Class = blk: {
    var c = entry.class;
    c.role = "combo box";
    c.init = init;
    c.teardown = teardown;
    c.subcommand = subcommand;
    break :blk c;
};

pub const class = ttk.derive(base, "ttk::combobox", "TCombobox", specs, &subs, "");

fn init(w: *Widget) anyerror!void {
    try entry.init(w);
    entry.dataOf(w).combo = true;
}

fn teardown(w: *Widget) void {
    const pd = &w.app.popdown;
    if (pd.widget == w) clear(w.app);
    entry.teardown(w);
}

fn values(w: *Widget) ztcl.Error![]const Value {
    const t = options.get(w, "-values").text;
    if (t.len == 0) return &.{};
    return w.app.it.list(.{ .str = t });
}

/// The index of the text in `-values`, or -1.
fn currentIndex(w: *Widget) ztcl.Error!i64 {
    const it = w.app.it;
    const text = entry.dataOf(w).edit.text();
    for (try values(w), 0..) |v, i| if (std.mem.eql(u8, try it.str(v), text)) return @intCast(i);
    return -1;
}

fn subcommand(w: *Widget, it: *ztcl.Interp, argv: []const Value) ztcl.Error!?Value {
    const sub = try it.str(argv[1]);
    if (std.mem.eql(u8, sub, "current")) {
        if (argv.len > 3) return it.fail("wrong # args: should be \"{s} current ?newIndex?\"", .{w.path});
        if (argv.len == 2) return .{ .int = try currentIndex(w) };
        const list = try values(w);
        const t = try it.str(argv[2]);
        const i: i64 = if (std.mem.eql(u8, t, "end")) @as(i64, @intCast(list.len)) - 1 else std.fmt.parseInt(i64, std.mem.trim(u8, t, " "), 0) catch return it.fail("Incorrect index {s}", .{t});
        if (i < 0 or i >= list.len) return it.fail("Index {s} out of range", .{t});
        entry.valueChanged(w, try it.alloc().dupe(u8, try it.str(list[@intCast(i)])));
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "set")) {
        if (argv.len != 3) return it.fail("wrong # args: should be \"{s} set value\"", .{w.path});
        entry.valueChanged(w, try it.alloc().dupe(u8, try it.str(argv[2])));
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "identify")) {
        const x = try it.int(argv[2]);
        const y = try it.int(argv[3]);
        if (x < 0 or y < 0 or x >= w.geom.w or y >= w.geom.h) return Value.empty;
        w.app.ensureStyle(w);
        const ar = entry.areas(w, &w.style);
        if (ar.arrow) |r| if (x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h) return .{ .str = "downarrow" };
        return .{ .str = "textarea" };
    }
    return entry.subcommand(w, it, argv);
}

// ---- The arrow ----

/// Paints the arrow of a combobox: a chevron that points down, or up
/// while the list is open.
pub fn paintArrow(w: *Widget, b: *scene.Builder, r: geom.Rect, slot: *paint.PartAnim) !void {
    const d = entry.dataOf(w);
    const open = w.app.popdown.widget == w and !w.app.popdown.closing;
    const st = entry.partStyleAs(w, "arrow", slot, d.hover == .buttondown, open);
    const inner: geom.Rect = .{ .x = r.x + 2, .y = r.y + 2, .w = @max(r.w - 4, 0), .h = @max(r.h - 4, 0) };
    try paint.styledBox(b, inner, &st);
    const cx = @as(f32, @floatFromInt(r.x)) + @as(f32, @floatFromInt(r.w)) / 2;
    const cy = @as(f32, @floatFromInt(r.y)) + @as(f32, @floatFromInt(r.h)) / 2;
    const k = std.math.clamp(@as(f32, @floatFromInt(@min(r.w, r.h))) * 0.16, 2.5, 5);
    const dy: f32 = if (open) -k / 2 else k / 2;
    var sh: path.Shape = .{};
    defer sh.deinit(w.app.gpa);
    try sh.stroke(w.app.gpa, &.{ .{ .x = cx - k, .y = cy - dy }, .{ .x = cx, .y = cy + dy }, .{ .x = cx + k, .y = cy - dy } }, 1.5, true);
    try paint.fillShape(b, &sh, st.color, st.opacity);
}

// ---- The list ----

const Geo = struct {
    /// The box of the list, in the coordinates of the combobox.
    box: geom.Rect,
    row_h: i32,
    rows: i32,
    pad: i32,
    above: bool,
};

/// The offset of a widget in its toplevel.
fn offsetIn(w: *Widget) geom.Point {
    var p: geom.Point = .{};
    var n: ?*Widget = w;
    while (n) |x| : (n = x.parent) {
        if (x.class.is_toplevel) break;
        p.x +|= x.geom.x;
        p.y +|= x.geom.y;
    }
    return p;
}

fn rowsWanted(w: *Widget, count: usize) i32 {
    const h = std.fmt.parseInt(i32, options.get(w, "-height").text, 0) catch 10;
    const limit: i32 = if (h > 0) h else 10;
    return @min(limit, @as(i32, @intCast(@min(count, 10000))));
}

fn geo(w: *Widget, count: usize) Geo {
    const app = w.app;
    app.ensureStyle(w);
    const st = app.styles.compute(w, "popdown", &w.style, app.env);
    const item = app.styles.compute(w, "item", &w.style, app.env);
    const ins = paint.insets(&st);
    const item_ins = paint.insets(&item);
    const row_h = paint.lineHeight(app, item.font) + item_ins.vertical();
    const rows = rowsWanted(w, count);
    const h = rows * row_h + ins.vertical();
    const top = w.toplevel();
    const off = offsetIn(w);
    const gap: i32 = 4;
    var y = w.geom.h + gap;
    var above = false;
    if (off.y + y + h > top.geom.h - gap and off.y - gap - h >= gap) {
        y = -gap - h;
        above = true;
    }
    const bw = @max(w.geom.w, 60);
    const x = std.math.clamp(0, -off.x + gap, @max(top.geom.w - off.x - bw - gap, -off.x + gap));
    return .{ .box = .{ .x = x, .y = y, .w = bw, .h = h }, .row_h = row_h, .rows = rows, .pad = ins.top, .above = above };
}

/// The row at a point in the coordinates of the combobox, or null.
fn rowAt(g: Geo, top: i32, count: usize, x: i32, y: i32) ?i32 {
    const r = g.box;
    if (x < r.x or x >= r.x + r.w or y < r.y + g.pad or g.row_h <= 0) return null;
    const k = @divFloor(y - r.y - g.pad, g.row_h);
    if (k < 0 or k >= g.rows) return null;
    const i = top + k;
    if (i >= count) return null;
    return i;
}

fn inBox(g: Geo, x: i32, y: i32) bool {
    const r = g.box;
    return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
}

fn repaint(w: *Widget) void {
    if (!w.alive()) return;
    w.toplevel().invalidate(.{ .style = false, .measure = false, .layout = false, .paint = true });
    entry.changed(w);
}

/// Keeps the active row in the shown rows.
fn reveal(pd: *Popdown, rows: i32, count: usize) void {
    const n: i32 = @intCast(@min(count, 10000));
    if (pd.active >= 0) {
        if (pd.active < pd.top) pd.top = pd.active;
        if (pd.active >= pd.top + rows) pd.top = pd.active - rows + 1;
    }
    pd.top = std.math.clamp(pd.top, 0, @max(n - rows, 0));
}

fn post(w: *Widget) ztcl.Error!void {
    const app = w.app;
    if (w.state.disabled) return;
    const cmd = options.get(w, "-postcommand");
    if (cmd.text.len > 0) app.callback(cmd.text);
    if (!w.alive()) return;
    const count = (try values(w)).len;
    if (count == 0) return;
    const pd = &app.popdown;
    const now = app.platform.nowUs();
    // An open during a close of the same list starts from the shown point.
    var start = now;
    if (pd.widget == w and pd.closing) start = now - (move_dur_us - @min(now - pd.move_us, move_dur_us));
    clear(app);
    const cur = try currentIndex(w);
    pd.* = .{ .widget = w, .active = @intCast(cur), .move_us = start };
    reveal(pd, rowsWanted(w, count), count);
    app.grab = .{ .widget = w, .global = false };
    w.state.pressed = true;
    w.invalidate(.{ .style = true, .measure = false, .layout = false, .paint = true });
    repaint(w);
}

/// Starts the close move of the open list.
fn unpost(app: *App) void {
    const pd = &app.popdown;
    const w = pd.widget orelse return;
    if (pd.closing) return;
    if (app.grab.widget == w) app.grab.widget = null;
    w.state.pressed = false;
    w.invalidate(.{ .style = true, .measure = false, .layout = false, .paint = true });
    if (anim.reduced(app)) {
        clear(app);
        repaint(w);
        return;
    }
    // A close that starts during the open move starts from the shown point.
    const now = app.platform.nowUs();
    const since = @min(now - pd.move_us, move_dur_us);
    pd.move_us = now - (move_dur_us - since);
    pd.closing = true;
    pd.drag = false;
    pd.timer = app.loop.addNative(move_dur_us - (now - pd.move_us), finish, app) catch null;
    repaint(w);
}

fn finish(ctx: ?*anyopaque) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    const pd = &app.popdown;
    pd.timer = null;
    if (!pd.closing) return;
    const w = pd.widget orelse return;
    clear(app);
    repaint(w);
}

/// Removes the list at once.
fn clear(app: *App) void {
    const pd = &app.popdown;
    if (pd.timer) |id| _ = app.loop.cancel(id);
    if (pd.widget) |w| {
        if (app.grab.widget == w) app.grab.widget = null;
        w.state.pressed = false;
        if (w.alive()) w.toplevel().invalidate(.{ .style = false, .measure = false, .layout = false, .paint = true });
    }
    pd.* = .{};
}

/// Sets the text from a row, closes the list, and sends `<<ComboboxSelected>>`.
fn select(w: *Widget, row: i32) ztcl.Error!void {
    const it = w.app.it;
    const list = try values(w);
    if (row < 0 or row >= list.len) return;
    entry.valueChanged(w, try it.alloc().dupe(u8, try it.str(list[@intCast(row)])));
    if (!w.alive()) return;
    unpost(w.app);
    const script = try std.fmt.allocPrint(w.app.gpa, "{s} selection range 0 end; {s} icursor end; event generate {s} <<ComboboxSelected>>", .{ w.path, w.path, w.path });
    defer w.app.gpa.free(script);
    w.app.callback(script);
}

/// The progress of the open move at a time: 0 is hidden and 1 is open.
pub fn openness(pd: *const Popdown, now: i64) f32 {
    const t = std.math.clamp(@as(f32, @floatFromInt(now - pd.move_us)) / @as(f32, @floatFromInt(move_dur_us)), 0, 1);
    // A close plays the open move backward, as the direction `reverse` of CSS.
    return easing.Timing.ease_out.eval(if (pd.closing) 1 - t else t);
}

/// Paints the list with the openness `p`.
fn paintList(w: *Widget, b: *scene.Builder, g: Geo, list: []const Value, p: f32) !void {
    const app = w.app;
    const pd = &app.popdown;
    const off = offsetIn(w);
    const dy = num.pxRound(@as(f64, (1 - p) * slide * @as(f32, if (g.above) 1 else -1)));
    var box = app.styles.compute(w, "popdown", &w.style, app.env);
    box.opacity *= p;
    var r = g.box;
    r.x += off.x;
    r.y += off.y + dy;
    try paint.styledBox(b, r, &box);
    var item = app.styles.compute(w, "item", &w.style, app.env);
    var active = app.styles.compute(w, "item-active", &w.style, app.env);
    item.opacity *= p;
    active.opacity *= p;
    const ins = paint.insets(&box);
    var k: i32 = 0;
    while (k < g.rows) : (k += 1) {
        const i = pd.top + k;
        if (i >= list.len) break;
        const row: geom.Rect = .{ .x = r.x + ins.left, .y = r.y + ins.top + k * g.row_h, .w = r.w - ins.horizontal(), .h = g.row_h };
        const st = if (i == pd.active) &active else &item;
        if (i == pd.active) try paint.styledBox(b, row, st);
        try paint.label(w, b, row.inset(paint.insets(st)), try app.it.str(list[@intCast(i)]), st, .w, .left);
    }
}

/// Paints the open list of the toplevel `top`, over its widgets.
pub fn paintPopdown(app: *App, top: *Widget, b: *scene.Builder) !void {
    const pd = &app.popdown;
    const w = pd.widget orelse return;
    if (!w.alive() or w.toplevel() != top) return;
    const list = try values(w);
    if (list.len == 0) return;
    const g = geo(w, list.len);
    const now = if (app.anim_frame) |fr| fr.time_us else app.platform.nowUs();
    const p = if (anim.reduced(app)) (if (pd.closing) @as(f32, 0) else 1) else openness(pd, now);
    const quads = &b.scene.quads;
    const at = quads.items.len;
    try paintList(w, b, g, list, p);
    const moving = now - pd.move_us < move_dur_us and !anim.reduced(app);
    if (!moving) return;
    const fr = app.anim_frame orelse {
        app.anim_more = true;
        return;
    };
    const n = quads.items.len - at;
    try paintList(w, b, g, list, 0);
    try paintList(w, b, g, list, 1);
    if (quads.items.len - at != 3 * n or n == 0) {
        quads.shrinkRetainingCapacity(at + n);
        app.anim_more = true;
        return;
    }
    const gpa = app.gpa;
    const mark = fr.anim_quads.items.len;
    try fr.anim_quads.appendSlice(gpa, quads.items[at + n .. at + 3 * n]);
    quads.shrinkRetainingCapacity(at + n);
    const off_at = fr.anim_offsets.items.len;
    try fr.anim_offsets.appendSlice(gpa, &.{ 0, 1 });
    try fr.anims.append(gpa, .{ .first = @intCast(at), .count = @intCast(n), .from = @intCast(mark), .stops = 2, .offsets = @intCast(off_at), .start_us = pd.move_us, .delay_us = 0, .len_us = move_dur_us, .timing = easing.Timing.ease_out, .direction = if (pd.closing) .reverse else .normal });
}

// ---- Input ----

const Action = enum { press, motion, release, wheel, down, up, @"return", escape };

/// `::ztk::priv::combo action path ?X Y?`. It gives 1 when the list
/// used the event, so the binding of the entry does not run.
fn cmdCombo(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    app.enter();
    defer app.leave();
    if (argv.len < 3) return it.wrongArgs("::ztk::priv::combo action window ?x y?");
    const act = std.meta.stringToEnum(Action, try it.str(argv[1])) orelse return it.fail("bad action", .{});
    const w = app.find(try it.str(argv[2])) orelse return .{ .int = 0 };
    if (w.class != &class) return .{ .int = 0 };
    const pd = &app.popdown;
    const open = pd.widget == w and !pd.closing;
    const count = if (open or act == .press or act == .down) (try values(w)).len else 0;
    switch (act) {
        .press, .motion, .release => {
            if (argv.len < 5) return .{ .int = 0 };
            const x: i32 = @intCast(std.math.clamp(try it.int(argv[3]), -1 << 24, 1 << 24));
            const y: i32 = @intCast(std.math.clamp(try it.int(argv[4]), -1 << 24, 1 << 24));
            const in_widget = x >= 0 and y >= 0 and x < w.geom.w and y < w.geom.h;
            if (act == .press) {
                if (open) {
                    const g = geo(w, count);
                    if (rowAt(g, pd.top, count, x, y)) |row| {
                        try select(w, row);
                        return .{ .int = 1 };
                    }
                    if (inBox(g, x, y)) return .{ .int = 1 };
                    unpost(app);
                    // A press on the text of an editable combobox also places the caret.
                    return .{ .int = @intFromBool(!in_widget or onArrow(w, x, y) or w.state.readonly) };
                }
                if (w.state.disabled or !in_widget) return .{ .int = 0 };
                if (onArrow(w, x, y) or w.state.readonly) {
                    try post(w);
                    if (app.popdown.widget == w) app.popdown.drag = true;
                    return .{ .int = 1 };
                }
                return .{ .int = 0 };
            }
            if (!open) return .{ .int = 0 };
            const g = geo(w, count);
            const row = rowAt(g, pd.top, count, x, y);
            if (act == .motion) {
                if (row) |r| if (r != pd.active) {
                    pd.active = r;
                    repaint(w);
                };
                return .{ .int = 1 };
            }
            // A release on a row after a press that opened the list selects the row.
            const was_drag = pd.drag;
            pd.drag = false;
            if (was_drag) if (row) |r| try select(w, r);
            return .{ .int = 1 };
        },
        .wheel => {
            if (!open or argv.len < 4) return .{ .int = 0 };
            const delta = try it.int(argv[3]);
            const g = geo(w, count);
            const steps: i32 = @intCast(std.math.clamp(-@divTrunc(delta, 120), -100, 100));
            const n: i32 = @intCast(@min(count, 10000));
            pd.top = std.math.clamp(pd.top + (if (steps == 0) (if (delta > 0) @as(i32, -1) else 1) else steps), 0, @max(n - g.rows, 0));
            repaint(w);
            return .{ .int = 1 };
        },
        .down, .up => {
            if (!open) {
                if (act == .down and !w.state.disabled) try post(w);
                return .{ .int = 1 };
            }
            const n: i32 = @intCast(@min(count, 10000));
            pd.active = std.math.clamp(pd.active + (if (act == .down) @as(i32, 1) else -1), 0, n - 1);
            reveal(pd, rowsWanted(w, count), count);
            repaint(w);
            return .{ .int = 1 };
        },
        .@"return" => {
            if (!open) return .{ .int = 0 };
            if (pd.active >= 0) try select(w, pd.active) else unpost(app);
            return .{ .int = 1 };
        },
        .escape => {
            if (!open) return .{ .int = 0 };
            unpost(app);
            return .{ .int = 1 };
        },
    }
}

fn onArrow(w: *Widget, x: i32, y: i32) bool {
    w.app.ensureStyle(w);
    const r = entry.areas(w, &w.style).arrow orelse return false;
    return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
}

pub fn register(app: *App) !void {
    const it = app.it;
    try it.register(class.command, widget.classCommand(&class));
    try app.classes.put(app.gpa, class.command, &class);
    try it.register("ztk::priv::combo", cmdCombo);
    try entry.bindClass(app, "TCombobox");
    // The list goes first: the binding of the entry runs when the list did not use the event.
    _ = try it.eval(
        \\foreach {ttk_event ttk_act ttk_args} {<Button-1> press {%x %y} <B1-Motion> motion {%x %y} <Motion> motion {%x %y} <ButtonRelease-1> release {%x %y} <MouseWheel> wheel %D} {
        \\    bind TCombobox $ttk_event "if {!\[::ztk::priv::combo $ttk_act %W $ttk_args\]} {\n[bind TCombobox $ttk_event]\n}"
        \\}
        \\unset ttk_event ttk_act ttk_args
        \\bind TCombobox <Key-Down> {::ztk::priv::combo down %W}
        \\bind TCombobox <Key-Up> {::ztk::priv::combo up %W}
        \\bind TCombobox <Key-Return> {::ztk::priv::combo return %W}
        \\bind TCombobox <Key-Escape> {::ztk::priv::combo escape %W}
    );
}
