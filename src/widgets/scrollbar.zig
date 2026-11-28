//! The scrollbar class. A scrollbar shows the part of a document that a
//! view shows, with the fractions of `set`, and runs `-command` with
//! `moveto fraction` or `scroll number units|pages` when the user moves
//! it. A press on the thumb (the element `slider`) starts a drag, a press
//! on the trough scrolls by one page, button 2 moves the thumb to the
//! pointer, the wheel scrolls by units, and the keys scroll by units, by
//! pages, or to an end. `set` with four integers gives the old protocol
//! of Tk 3: `get` gives the four values, and `-command` gets a unit.
//!
//! The modern theme draws an overlay scrollbar: a thin round thumb (part
//! `::thumb`) on a clear trough (part `::trough`). The thumb shows while
//! the view scrolls (`:scrolling`) and on hover, and fades out after a
//! delay. The modern theme draws no arrows. A move of the thumb by `set`
//! eases from the shown place, and a drag of the thumb follows the
//! pointer on the render thread, with the view that it scrolls.
//!
//! `ttk::scrollbar` (in `ttk/range.zig`) uses this code with the flag
//! `ttk` of its class. It has the two-fraction `set` only, and the
//! element names of `ttk` (`thumb`, `trough`, and the arrows).
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const num = @import("../base/num.zig");
const geom = @import("../base/geom.zig");
const widget = @import("../widget.zig");
const options = @import("../options.zig");
const paint = @import("../paint.zig");
const scene = @import("../scene.zig");
const anim = @import("../anim.zig");
const easing = @import("../base/easing.zig");
const focus = @import("../focus.zig");
const scroll = @import("../scroll.zig");
const loop_mod = @import("../loop.zig");
const App = @import("../app.zig").App;
const Spec = options.Spec;
const Widget = widget.Widget;
const Value = ztcl.Value;

const orient_words = [_][]const u8{ "vertical", "horizontal" };

/// The options of `wish` 8.6.16 for `scrollbar`, in its order.
pub const specs = [_]Spec{
    .{ .name = "-activebackground", .db_name = "activeBackground", .db_class = "Foreground", .type = .color, .default = "#ececec" },
    .{ .name = "-activerelief", .db_name = "activeRelief", .db_class = "Relief", .type = .relief, .default = "raised" },
    .{ .name = "-background", .db_name = "background", .db_class = "Background", .type = .color, .default = "#d9d9d9", .from_style = true, .style_prop = .background },
    .{ .name = "-bd", .type = .synonym, .target = "-borderwidth" },
    .{ .name = "-bg", .type = .synonym, .target = "-background" },
    .{ .name = "-borderwidth", .db_name = "borderWidth", .db_class = "BorderWidth", .type = .pixels, .default = "1" },
    .{ .name = "-command", .db_name = "command", .db_class = "Command", .type = .script, .allow_empty = true },
    .{ .name = "-cursor", .db_name = "cursor", .db_class = "Cursor", .type = .cursor, .allow_empty = true },
    .{ .name = "-elementborderwidth", .db_name = "elementBorderWidth", .db_class = "BorderWidth", .type = .pixels, .default = "-1" },
    .{ .name = "-highlightbackground", .db_name = "highlightBackground", .db_class = "HighlightBackground", .type = .color, .default = "#d9d9d9" },
    .{ .name = "-highlightcolor", .db_name = "highlightColor", .db_class = "HighlightColor", .type = .color, .default = "#000000" },
    .{ .name = "-highlightthickness", .db_name = "highlightThickness", .db_class = "HighlightThickness", .type = .pixels, .default = "0" },
    .{ .name = "-jump", .db_name = "jump", .db_class = "Jump", .type = .boolean, .default = "0" },
    .{ .name = "-orient", .db_name = "orient", .db_class = "Orient", .type = .word, .default = "vertical", .words = &orient_words, .word_name = "orientation" },
    .{ .name = "-relief", .db_name = "relief", .db_class = "Relief", .type = .relief, .default = "sunken" },
    .{ .name = "-repeatdelay", .db_name = "repeatDelay", .db_class = "RepeatDelay", .type = .int, .default = "300" },
    .{ .name = "-repeatinterval", .db_name = "repeatInterval", .db_class = "RepeatInterval", .type = .int, .default = "100" },
    .{ .name = "-takefocus", .db_name = "takeFocus", .db_class = "TakeFocus", .type = .string, .allow_empty = true },
    .{ .name = "-troughcolor", .db_name = "troughColor", .db_class = "Background", .type = .color, .default = "#b3b3b3" },
    .{ .name = "-width", .db_name = "width", .db_class = "Width", .type = .pixels, .default = "11" },
};

pub const class: widget.Class = .{
    .command = "scrollbar",
    .tk_class = "Scrollbar",
    .role = "scroll bar",
    .focusable = true,
    .specs = &specs,
    .init = init,
    .deinit = deinit,
    .teardown = teardown,
    .created = created,
    .measure = measure,
    .paint = paintScrollbar,
    .subcommand = subcommand,
    .bad_option_list = "activate, cget, configure, delta, fraction, get, identify, or set",
};

const Element = enum { none, arrow1, trough1, slider, trough2, arrow2 };

const Data = struct {
    first: f64 = 0,
    last: f64 = 1,
    /// The four values of the old protocol, when `set` got four.
    old: ?[4]i64 = null,
    active: Element = .none,
    dragging: bool = false,
    /// The pointer distance from the start of the thumb at the press.
    drag_off: f64 = 0,
    /// The move of the thumb: the shown fractions at its start, and the time.
    from: [2]f64 = .{ 0, 1 },
    start_us: i64 = 0,
    moving: bool = false,
    /// The timer that ends `:scrolling`.
    timer: ?loop_mod.TimerId = null,
    trough: paint.PartAnim = .{},
    thumb: paint.PartAnim = .{},
};

/// How long the thumb stays after a scroll, before it fades out.
const show_us: i64 = 900_000;

fn data(w: *const Widget) *Data {
    return @ptrCast(@alignCast(w.data.?));
}

fn init(w: *Widget) anyerror!void {
    const d = try w.app.gpa.create(Data);
    d.* = .{};
    w.data = d;
}

fn deinit(w: *Widget) void {
    w.app.gpa.destroy(data(w));
    w.data = null;
}

fn teardown(w: *Widget) void {
    const d = data(w);
    if (d.timer) |id| _ = w.app.loop.cancel(id);
    d.timer = null;
    if (d.dragging) w.app.scroll_link = null;
}

/// A new scrollbar shows its thumb for a moment, as a view that appears.
fn created(w: *Widget) ztcl.Error!void {
    flash(w);
}

fn pixels(w: *const Widget, comptime name: []const u8) i32 {
    const v = options.get(w, name).value;
    return if (v == .pixels) v.pixels else 0;
}

fn horizontal(w: *const Widget) bool {
    const i = options.index(w, "-orient");
    const v = w.opts[i].value;
    return v == .word and std.mem.eql(u8, w.class.specs[i].words[v.word], "horizontal");
}

/// True for a `scrollbar` and a `ttk::scrollbar`.
fn isScrollbar(w: *const Widget) bool {
    return w.class.paint == paintScrollbar;
}

fn inset(w: *const Widget) i32 {
    return @max(pixels(w, "-highlightthickness"), 0) + @max(pixels(w, "-borderwidth"), 0);
}

fn measure(w: *Widget) geom.Size {
    const i = inset(w);
    const across = num.add(@max(pixels(w, "-width"), 0), 2 * i);
    const along = 2 * (i + @max(pixels(w, "-borderwidth"), 0));
    return if (horizontal(w)) .{ .w = along, .h = across } else .{ .w = across, .h = along };
}

// ---- Geometry ----

/// The trough along the axis: its start and its length.
const Geo = struct { start: i32, len: i32, across: i32 };

fn geo(w: *const Widget) Geo {
    const i = inset(w);
    const along = if (horizontal(w)) w.geom.w else w.geom.h;
    const across = if (horizontal(w)) w.geom.h else w.geom.w;
    return .{ .start = i, .len = @max(along - 2 * i, 0), .across = @max(across - 2 * i, 0) };
}

/// The thumb from the fractions, in pixels from the start of the trough.
fn thumb(g: Geo, first: f64, last: f64) [2]f64 {
    const l: f64 = @floatFromInt(g.len);
    var a = std.math.clamp(first, 0, 1) * l;
    var b = std.math.clamp(last, 0, 1) * l;
    const min = @min(l, @max(@as(f64, @floatFromInt(g.across)) * 2, 16));
    if (b - a < min) {
        b = a + min;
        if (b > l) {
            b = l;
            a = l - min;
        }
    }
    return .{ a, b };
}

fn alongOf(w: *const Widget, x: i32, y: i32) i32 {
    return if (horizontal(w)) x else y;
}

fn identify(w: *const Widget, x: i32, y: i32) Element {
    if (x < 0 or y < 0 or x >= w.geom.w or y >= w.geom.h) return .none;
    const g = geo(w);
    const d = data(w);
    const p: f64 = @floatFromInt(alongOf(w, x, y) - g.start);
    if (p < 0 or p >= @as(f64, @floatFromInt(g.len))) return .none;
    const t = thumb(g, d.first, d.last);
    if (p < t[0]) return .trough1;
    if (p < t[1]) return .slider;
    return .trough2;
}

fn fractionAt(w: *const Widget, x: i32, y: i32) f64 {
    const g = geo(w);
    if (g.len <= 0) return 0.5;
    const p: f64 = @floatFromInt(alongOf(w, x, y) - g.start);
    return std.math.clamp(p / @as(f64, @floatFromInt(g.len)), 0, 1);
}

// ---- Paint ----

/// The fractions that the thumb shows now.
fn shownFractions(w: *Widget) [2]f64 {
    const d = data(w);
    if (!d.moving) return .{ d.first, d.last };
    const app = w.app;
    const since = app.platform.nowUs() - d.start_us;
    if (since >= scroll.step_us) {
        d.moving = false;
        return .{ d.first, d.last };
    }
    if (app.part_end) return .{ d.first, d.last };
    app.anim_more = true;
    const timing = easing.Timing.ease_out;
    const p = timing.eval(@as(f32, @floatFromInt(@max(since, 0))) / @as(f32, @floatFromInt(scroll.step_us)));
    app.notePartMove(d.start_us, .{ .duration_ms = @intCast(@divTrunc(scroll.step_us, 1000)), .timing = timing }, p);
    return .{ d.from[0] + (d.first - d.from[0]) * p, d.from[1] + (d.last - d.from[1]) * p };
}

fn paintScrollbar(w: *Widget, b: *scene.Builder) anyerror!void {
    const app = w.app;
    const st = anim.shown(app, w);
    try paint.box(w, b, st);
    const d = data(w);
    const g = geo(w);
    if (g.len <= 0 or g.across <= 0) return;
    const hz = horizontal(w);
    const i = inset(w);
    const trough = paint.partStyle(w, "trough", &d.trough).style;
    const th = paint.partStyle(w, "thumb", &d.thumb).style;
    const tr: geom.Rect = if (hz) .{ .x = i, .y = i, .w = g.len, .h = g.across } else .{ .x = i, .y = i, .w = g.across, .h = g.len };
    try paint.styledBox(b, tr, &trough);
    const f = shownFractions(w);
    // A view that shows all of its content has no thumb.
    if (f[0] <= 0 and f[1] >= 1 and !d.dragging) return;
    const t = thumb(g, f[0], f[1]);
    // The thumb is thin: the padding of the part is the space beside it.
    const pad = paint.insets(&th);
    const a0 = num.pxRound(t[0]);
    const a1 = num.pxRound(t[1]);
    const r: geom.Rect = if (hz)
        .{ .x = i + a0 + pad.left, .y = i + pad.top, .w = @max(a1 - a0 - pad.horizontal(), 1), .h = @max(g.across - pad.vertical(), 1) }
    else
        .{ .x = i + pad.left, .y = i + a0 + pad.top, .w = @max(g.across - pad.horizontal(), 1), .h = @max(a1 - a0 - pad.vertical(), 1) };
    const at = b.scene.quads.items.len;
    try paint.styledBox(b, r, &th);
    if (d.dragging and !d.moving) {
        const origin: f32 = @floatCast(@as(f64, @floatFromInt((if (hz) b.off.x else b.off.y) + i)) + t[0] + d.drag_off);
        const lo: f32 = @floatCast(-t[0]);
        const hi: f32 = @floatCast(@as(f64, @floatFromInt(g.len)) - t[1]);
        try app.addDrag(b, at, if (hz) 0 else 1, false, origin, lo, hi);
    }
}

// ---- The fractions ----

/// Sets the fractions. A change shows the thumb for a moment and eases it.
fn setFractions(w: *Widget, first: f64, last: f64, ease: bool) void {
    const d = data(w);
    const a = std.math.clamp(first, 0, 1);
    const z = std.math.clamp(last, a, 1);
    if (a == d.first and z == d.last) return;
    if (ease and !d.dragging and !anim.reduced(w.app)) {
        d.from = shownFractions(w);
        d.start_us = w.app.platform.nowUs();
        d.moving = true;
    } else d.moving = false;
    d.first = a;
    d.last = z;
    w.invalidate(.{ .style = false, .measure = false, .layout = false, .paint = true });
    flash(w);
}

/// Sets `:scrolling` and ends it after `show_us`.
fn flash(w: *Widget) void {
    const d = data(w);
    if (!w.state.scrolling) {
        w.state.scrolling = true;
        w.invalidate(.{ .style = true, .measure = false, .layout = false, .paint = true });
    }
    if (d.timer) |id| _ = w.app.loop.cancel(id);
    d.timer = w.app.loop.addNative(show_us, endFlash, w) catch null;
}

fn endFlash(ctx: ?*anyopaque) void {
    const w: *Widget = @ptrCast(@alignCast(ctx.?));
    data(w).timer = null;
    if (!w.alive()) return;
    w.state.scrolling = false;
    w.invalidate(.{ .style = true, .measure = false, .layout = false, .paint = true });
}

fn printNum(a: std.mem.Allocator, n: f64) ![]const u8 {
    if (n == @trunc(n) and @abs(n) < 1e15) return std.fmt.allocPrint(a, "{d}", .{@as(i64, @intFromFloat(n))});
    return std.fmt.allocPrint(a, "{d}", .{n});
}

/// Runs `-command` with `moveto f` or `scroll n what`. The old protocol
/// gets the unit at the top of the window.
fn run(w: *Widget, comptime fmt: enum { moveto, units, pages }, n: f64) ztcl.Error!void {
    const cmd = options.get(w, "-command");
    if (!cmd.set or cmd.text.len == 0) return;
    const d = data(w);
    const app = w.app;
    const a = app.it.alloc();
    const tail = if (d.old) |o| blk: {
        const unit: f64 = switch (fmt) {
            .moveto => @round(n * @as(f64, @floatFromInt(o[0]))),
            .units => @as(f64, @floatFromInt(o[2])) + n,
            .pages => @as(f64, @floatFromInt(o[2])) + n * @as(f64, @floatFromInt(@max(o[1] - 1, 1))),
        };
        break :blk try printNum(a, unit);
    } else switch (fmt) {
        .moveto => try std.fmt.allocPrint(a, "moveto {s}", .{try options.formatDouble(a, n)}),
        .units => try std.fmt.allocPrint(a, "scroll {s} units", .{try printNum(a, n)}),
        .pages => try std.fmt.allocPrint(a, "scroll {s} pages", .{try printNum(a, n)}),
    };
    const script = try std.fmt.allocPrint(app.gpa, "{s} {s}", .{ cmd.text, tail });
    defer app.gpa.free(script);
    app.callback(script);
}

/// The widget that `-command` scrolls, when it is `path xview` or `path yview`.
fn scrolled(w: *Widget) ?*Widget {
    const cmd = options.get(w, "-command");
    if (!cmd.set) return null;
    var words = std.mem.tokenizeAny(u8, cmd.text, " \t");
    const path = words.next() orelse return null;
    const view = words.next() orelse return null;
    if (words.next() != null) return null;
    if (!std.mem.eql(u8, view, if (horizontal(w)) "xview" else "yview")) return null;
    return w.app.find(path);
}

/// Points the render thread drag of the view at the pointer `p` on the
/// axis, in logical pixels of the window.
fn link(w: *Widget, p: f32) void {
    const d = data(w);
    const target = scrolled(w) orelse {
        w.app.scroll_link = null;
        return;
    };
    const g = geo(w);
    const t = thumb(g, d.first, d.last);
    const l: f32 = @floatFromInt(g.len);
    w.app.scroll_link = .{
        .target = target,
        .axis = if (horizontal(w)) 0 else 1,
        .base = p,
        .lo = @floatCast(-t[0]),
        .hi = @floatCast(@as(f64, l) - t[1]),
        .travel = @floatCast(@as(f64, l) * (1 - (d.last - d.first))),
    };
    target.invalidate(.{ .style = false, .measure = false, .layout = false, .paint = true });
}

// ---- Commands ----

fn subcommand(w: *Widget, it: *ztcl.Interp, argv: []const Value) ztcl.Error!?Value {
    const sub = try it.str(argv[1]);
    const d = data(w);
    const a = it.alloc();
    if (std.mem.eql(u8, sub, "get")) {
        if (argv.len != 2) return it.fail("wrong # args: should be \"{s} get{s}\"", .{ w.path, if (w.class.ttk) " " else "" });
        if (d.old) |o| return .{ .str = try std.fmt.allocPrint(a, "{d} {d} {d} {d}", .{ o[0], o[1], o[2], o[3] }) };
        return try scroll.fractionsValue(a, .{ d.first, d.last });
    }
    if (std.mem.eql(u8, sub, "set")) {
        if (argv.len == 4) {
            var f: [2]f64 = undefined;
            for (0..2) |k| {
                const t = try it.str(argv[2 + k]);
                f[k] = std.fmt.parseFloat(f64, std.mem.trim(u8, t, " ")) catch return it.fail("expected floating-point number but got \"{s}\"", .{t});
            }
            d.old = null;
            setFractions(w, f[0], f[1], true);
            return Value.empty;
        }
        if (w.class.ttk) return it.fail("wrong # args: should be \"{s} set first last\"", .{w.path});
        if (argv.len == 6) {
            var o: [4]i64 = undefined;
            for (0..4) |k| o[k] = try it.int(argv[2 + k]);
            d.old = o;
            const total: f64 = @floatFromInt(@max(o[0], 1));
            setFractions(w, @as(f64, @floatFromInt(o[2])) / total, @as(f64, @floatFromInt(o[3] + 1)) / total, true);
            return Value.empty;
        }
        return it.fail("wrong # args: should be \"{s} set firstFraction lastFraction\" or \"{s} set totalUnits windowUnits firstUnit lastUnit\"", .{ w.path, w.path });
    }
    if (std.mem.eql(u8, sub, "activate")) {
        if (argv.len == 2) return .{ .str = if (d.active == .none) "" else @tagName(d.active) };
        if (argv.len != 3) return it.fail("wrong # args: should be \"{s} activate element\"", .{w.path});
        const name = try it.str(argv[2]);
        const e = std.meta.stringToEnum(Element, name) orelse .none;
        d.active = switch (e) {
            .arrow1, .slider, .arrow2 => e,
            else => .none,
        };
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "fraction")) {
        if (argv.len != 4) return it.fail("wrong # args: should be \"{s} fraction x y\"", .{w.path});
        const x = try coord(it, argv[2]);
        const y = try coord(it, argv[3]);
        return .{ .str = try options.formatDouble(a, fractionAt(w, x, y)) };
    }
    if (std.mem.eql(u8, sub, "delta")) {
        if (argv.len != 4) return it.fail("wrong # args: should be \"{s} delta {s}\"", .{ w.path, if (w.class.ttk) "dx dy" else "xDelta yDelta" });
        const dx = try coord(it, argv[2]);
        const dy = try coord(it, argv[3]);
        const g = geo(w);
        const n: f64 = @floatFromInt(if (horizontal(w)) dx else dy);
        return .{ .str = try options.formatDouble(a, if (g.len > 0) n / @as(f64, @floatFromInt(g.len)) else 0) };
    }
    if (std.mem.eql(u8, sub, "identify")) {
        if (argv.len != 4) return it.fail("wrong # args: should be \"{s} identify x y\"", .{w.path});
        const e = identify(w, try coord(it, argv[2]), try coord(it, argv[3]));
        if (w.class.ttk) return .{ .str = switch (e) {
            .none => "",
            .arrow1 => if (horizontal(w)) "leftarrow" else "uparrow",
            .arrow2 => if (horizontal(w)) "rightarrow" else "downarrow",
            .slider => "thumb",
            .trough1, .trough2 => "trough",
        } };
        return .{ .str = if (e == .none) "" else @tagName(e) };
    }
    return null;
}

fn coord(it: *ztcl.Interp, v: Value) ztcl.Error!i32 {
    return @intCast(std.math.clamp(try it.int(v), -1 << 24, 1 << 24));
}

const Action = enum { press, motion, release, jump, wheel, units, pages, home, end };

/// `::ztk::priv::scrollbar action path ?args?`
fn cmdScrollbar(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    app.enter();
    defer app.leave();
    if (argv.len < 3) return it.wrongArgs("::ztk::priv::scrollbar action window ?arg ...?");
    const act = std.meta.stringToEnum(Action, try it.str(argv[1])) orelse return it.fail("bad action", .{});
    const w = app.find(try it.str(argv[2])) orelse return Value.empty;
    if (!isScrollbar(w)) return Value.empty;
    const d = data(w);
    const hz = horizontal(w);
    switch (act) {
        .press, .motion, .jump => {
            // press, motion, and jump: x y rootx rooty.
            if (argv.len < 7) return Value.empty;
            const x = try coord(it, argv[3]);
            const y = try coord(it, argv[4]);
            const root: f32 = @floatFromInt(if (hz) try coord(it, argv[5]) else try coord(it, argv[6]));
            const g = geo(w);
            const p: f64 = @floatFromInt(alongOf(w, x, y) - g.start);
            switch (act) {
                .press => {
                    const e = identify(w, x, y);
                    switch (e) {
                        .slider => {
                            d.dragging = true;
                            d.moving = false;
                            d.drag_off = p - thumb(g, d.first, d.last)[0];
                            d.active = .slider;
                            link(w, root);
                        },
                        .trough1 => try run(w, .pages, -1),
                        .trough2 => try run(w, .pages, 1),
                        .arrow1 => try run(w, .units, -1),
                        .arrow2 => try run(w, .units, 1),
                        .none => {},
                    }
                },
                .motion => if (d.dragging) {
                    const l: f64 = @floatFromInt(@max(g.len, 1));
                    const span = d.last - d.first;
                    const first = std.math.clamp((p - d.drag_off) / l, 0, @max(1 - span, 0));
                    if (first != d.first) {
                        setFractions(w, first, first + span, false);
                        if (!jumps(w)) try run(w, .moveto, first);
                    }
                    if (w.alive()) link(w, root);
                },
                .jump => {
                    // Button 2: the center of the thumb goes to the pointer.
                    const l: f64 = @floatFromInt(@max(g.len, 1));
                    const span = d.last - d.first;
                    const first = std.math.clamp(p / l - span / 2, 0, @max(1 - span, 0));
                    try run(w, .moveto, first);
                },
                else => unreachable,
            }
        },
        .release => {
            if (d.dragging) {
                d.dragging = false;
                d.active = .none;
                app.scroll_link = null;
                if (jumps(w)) try run(w, .moveto, d.first);
                w.invalidate(.{ .style = true, .measure = false, .layout = false, .paint = true });
                if (scrolled(w)) |t| t.invalidate(.{ .style = false, .measure = false, .layout = false, .paint = true });
            }
        },
        .wheel => {
            // wheel path delta axis: the wheel scrolls 4 units for each step of 120.
            if (argv.len < 5) return Value.empty;
            const t = try it.str(argv[3]);
            const delta = std.fmt.parseFloat(f64, t) catch return Value.empty;
            const ax = try it.str(argv[4]);
            if ((std.mem.eql(u8, ax, "h")) != hz) return Value.empty;
            if (delta != 0) try run(w, .units, -delta / 30);
        },
        .units, .pages => {
            // units|pages path n axis: a key scrolls only along its axis.
            if (argv.len < 5) return Value.empty;
            const ax = try it.str(argv[4]);
            if (!std.mem.eql(u8, ax, "hv") and (std.mem.eql(u8, ax, "h")) != hz) return Value.empty;
            const n: f64 = @floatFromInt(try it.int(argv[3]));
            if (act == .units) try run(w, .units, n) else try run(w, .pages, n);
        },
        .home => try run(w, .moveto, 0),
        .end => try run(w, .moveto, 1),
    }
    return Value.empty;
}

fn jumps(w: *const Widget) bool {
    const v = options.get(w, "-jump").value;
    return v == .boolean and v.boolean;
}

pub fn register(app: *App) !void {
    const it = app.it;
    try it.register("scrollbar", widget.classCommand(&class));
    try app.classes.put(app.gpa, "scrollbar", &class);
    try it.register("ztk::priv::scrollbar", cmdScrollbar);
    _ = try it.eval(
        \\bind Scrollbar <Button-1> {::ztk::priv::scrollbar press %W %x %y %X %Y}
        \\bind Scrollbar <B1-Motion> {::ztk::priv::scrollbar motion %W %x %y %X %Y}
        \\bind Scrollbar <ButtonRelease-1> {::ztk::priv::scrollbar release %W}
        \\bind Scrollbar <Button-2> {::ztk::priv::scrollbar jump %W %x %y %X %Y}
        \\bind Scrollbar <MouseWheel> {::ztk::priv::scrollbar wheel %W %D v}
        \\bind Scrollbar <Shift-MouseWheel> {::ztk::priv::scrollbar wheel %W %D h}
        \\bind Scrollbar <Key-Up> {::ztk::priv::scrollbar units %W -1 v}
        \\bind Scrollbar <Key-Down> {::ztk::priv::scrollbar units %W 1 v}
        \\bind Scrollbar <Key-Left> {::ztk::priv::scrollbar units %W -1 h}
        \\bind Scrollbar <Key-Right> {::ztk::priv::scrollbar units %W 1 h}
        \\bind Scrollbar <Control-Key-Up> {::ztk::priv::scrollbar pages %W -1 v}
        \\bind Scrollbar <Control-Key-Down> {::ztk::priv::scrollbar pages %W 1 v}
        \\bind Scrollbar <Control-Key-Left> {::ztk::priv::scrollbar pages %W -1 h}
        \\bind Scrollbar <Control-Key-Right> {::ztk::priv::scrollbar pages %W 1 h}
        \\bind Scrollbar <Key-Prior> {::ztk::priv::scrollbar pages %W -1 hv}
        \\bind Scrollbar <Key-Next> {::ztk::priv::scrollbar pages %W 1 hv}
        \\bind Scrollbar <Key-Home> {::ztk::priv::scrollbar home %W}
        \\bind Scrollbar <Key-End> {::ztk::priv::scrollbar end %W}
    );
}
