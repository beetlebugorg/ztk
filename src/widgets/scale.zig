//! The scale class: a value between `-from` and `-to` that a slider on a
//! track shows. The value rounds to `-resolution` and shows with the
//! count of digits that `-digits` or the resolution gives. A press on the
//! slider starts a drag; a press on the track moves the value by one
//! resolution step toward the pointer; button 2 and Control with button 1
//! set the value at the pointer or at an end. The arrow keys move by one
//! step, Control with an arrow by `-bigincrement`, and Home and End go to
//! the ends. `-variable` links the value to a global variable, and
//! `-command` runs with the new value after a change by the user. The
//! modern theme draws a thin track (part `::trough`), the filled part
//! (`::fill`), a round slider (`::slider`), the value (`::value`), and
//! the ticks. A move of the slider by a press or a key eases from the
//! shown position.
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
const style_mod = @import("../style.zig");
const App = @import("../app.zig").App;
const Spec = options.Spec;
const Widget = widget.Widget;
const Value = ztcl.Value;

const state_words = [_][]const u8{ "active", "disabled", "normal" };
const orient_words = [_][]const u8{ "horizontal", "vertical" };

/// The options of `wish` 8.6.16 for `scale`, in its order.
pub const specs = [_]Spec{
    .{ .name = "-activebackground", .db_name = "activeBackground", .db_class = "Foreground", .type = .color, .default = "#ececec" },
    .{ .name = "-background", .db_name = "background", .db_class = "Background", .type = .color, .default = "#d9d9d9", .from_style = true, .style_prop = .background },
    .{ .name = "-bigincrement", .db_name = "bigIncrement", .db_class = "BigIncrement", .type = .double, .default = "0" },
    .{ .name = "-bd", .type = .synonym, .target = "-borderwidth" },
    .{ .name = "-bg", .type = .synonym, .target = "-background" },
    .{ .name = "-borderwidth", .db_name = "borderWidth", .db_class = "BorderWidth", .type = .pixels, .default = "0", .from_style = true, .style_prop = .border_width },
    .{ .name = "-command", .db_name = "command", .db_class = "Command", .type = .script, .allow_empty = true },
    .{ .name = "-cursor", .db_name = "cursor", .db_class = "Cursor", .type = .string, .allow_empty = true },
    .{ .name = "-digits", .db_name = "digits", .db_class = "Digits", .type = .int, .default = "0" },
    .{ .name = "-fg", .type = .synonym, .target = "-foreground" },
    .{ .name = "-font", .db_name = "font", .db_class = "Font", .type = .font, .default = "TkDefaultFont" },
    .{ .name = "-foreground", .db_name = "foreground", .db_class = "Foreground", .type = .color, .default = "#000000", .from_style = true },
    .{ .name = "-from", .db_name = "from", .db_class = "From", .type = .double, .default = "0" },
    .{ .name = "-highlightbackground", .db_name = "highlightBackground", .db_class = "HighlightBackground", .type = .color, .default = "#d9d9d9" },
    .{ .name = "-highlightcolor", .db_name = "highlightColor", .db_class = "HighlightColor", .type = .color, .default = "#000000" },
    .{ .name = "-highlightthickness", .db_name = "highlightThickness", .db_class = "HighlightThickness", .type = .pixels, .default = "1" },
    .{ .name = "-label", .db_name = "label", .db_class = "Label", .type = .string, .allow_empty = true },
    .{ .name = "-length", .db_name = "length", .db_class = "Length", .type = .pixels, .default = "100" },
    .{ .name = "-orient", .db_name = "orient", .db_class = "Orient", .type = .word, .default = "vertical", .words = &orient_words },
    .{ .name = "-relief", .db_name = "relief", .db_class = "Relief", .type = .relief, .default = "flat", .from_style = true },
    .{ .name = "-repeatdelay", .db_name = "repeatDelay", .db_class = "RepeatDelay", .type = .int, .default = "300" },
    .{ .name = "-repeatinterval", .db_name = "repeatInterval", .db_class = "RepeatInterval", .type = .int, .default = "100" },
    .{ .name = "-resolution", .db_name = "resolution", .db_class = "Resolution", .type = .double, .default = "1" },
    .{ .name = "-showvalue", .db_name = "showValue", .db_class = "ShowValue", .type = .boolean, .default = "1" },
    .{ .name = "-sliderlength", .db_name = "sliderLength", .db_class = "SliderLength", .type = .pixels, .default = "30" },
    .{ .name = "-sliderrelief", .db_name = "sliderRelief", .db_class = "SliderRelief", .type = .relief, .default = "raised" },
    .{ .name = "-state", .db_name = "state", .db_class = "State", .type = .state, .default = "normal", .words = &state_words },
    .{ .name = "-takefocus", .db_name = "takeFocus", .db_class = "TakeFocus", .type = .string, .allow_empty = true },
    .{ .name = "-tickinterval", .db_name = "tickInterval", .db_class = "TickInterval", .type = .double, .default = "0" },
    .{ .name = "-to", .db_name = "to", .db_class = "To", .type = .double, .default = "100" },
    .{ .name = "-troughcolor", .db_name = "troughColor", .db_class = "Background", .type = .color, .default = "#b3b3b3" },
    .{ .name = "-variable", .db_name = "variable", .db_class = "Variable", .type = .variable, .allow_empty = true },
    .{ .name = "-width", .db_name = "width", .db_class = "Width", .type = .pixels, .default = "15" },
};

pub const trace_command = "::ztk::priv::scalevar";

pub const class: widget.Class = .{
    .command = "scale",
    .tk_class = "Scale",
    .role = "slider",
    .focusable = true,
    .specs = &specs,
    .init = init,
    .deinit = deinit,
    .teardown = teardown,
    .configured = configured,
    .created = created,
    .retrace = retrace,
    .trace_command = trace_command,
    .traced_var = tracedVar,
    .measure = measure,
    .paint = paintScale,
    .subcommand = subcommand,
    .bad_option_list = "cget, configure, coords, get, identify, or set",
};

const Data = struct {
    value: f64 = 0,
    var_name: []u8 = &.{},
    /// The value at the press that started a drag, and the pointer offset from the slider center.
    dragging: bool = false,
    drag_off: i32 = 0,
    /// The motion of the slider: the shown value at the start, and the time.
    anim_from: f64 = 0,
    anim_start: i64 = 0,
    moving: bool = false,
    trough: paint.PartAnim = .{},
    slider: paint.PartAnim = .{},
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

fn deinit(w: *Widget) void {
    const d = data(w);
    w.app.gpa.free(d.var_name);
    w.app.gpa.destroy(d);
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

fn dbl(w: *const Widget, comptime name: []const u8) f64 {
    const v = options.get(w, name).value;
    return if (v == .double) v.double else 0;
}

fn int(w: *const Widget, comptime name: []const u8) i64 {
    const v = options.get(w, name).value;
    return if (v == .int) v.int else if (v == .pixels) v.pixels else 0;
}

fn horizontal(w: *const Widget) bool {
    const v = options.get(w, "-orient").value;
    return v == .word and v.word == 0;
}

/// Rounds a value to the resolution and keeps it between -from and -to.
pub fn round(w: *const Widget, v: f64) f64 {
    const from = dbl(w, "-from");
    const to = dbl(w, "-to");
    var x = v;
    const res = dbl(w, "-resolution");
    if (res > 0) {
        // Round to a multiple of the resolution, half away from zero.
        const q = x / res;
        x = (if (q < 0) @ceil(q - 0.5) else @floor(q + 0.5)) * res;
    }
    const lo = @min(from, to);
    const hi = @max(from, to);
    return std.math.clamp(x, lo, hi);
}

/// The count of digits after the point.
fn decimals(w: *const Widget) usize {
    const digits = int(w, "-digits");
    if (digits > 0) {
        const m = @max(@abs(dbl(w, "-from")), @abs(dbl(w, "-to")));
        const lead: i64 = if (m >= 1) @as(i64, @intFromFloat(@floor(std.math.log10(m)))) + 1 else 1;
        return @intCast(@max(digits - lead, 0));
    }
    const res = dbl(w, "-resolution");
    if (res <= 0) return 0;
    var n: usize = 0;
    var r = res;
    while (n < 10 and @abs(r - @round(r)) > 1e-9) : (n += 1) r *= 10;
    return n;
}

/// The value as text, with the digits of the scale.
fn format(w: *const Widget, a: std.mem.Allocator, v: f64) ![]const u8 {
    const n = decimals(w);
    var buf: [64]u8 = undefined;
    const t = std.fmt.bufPrint(&buf, "{d:.[1]}", .{ v, n }) catch return a.dupe(u8, "0");
    return a.dupe(u8, t);
}

/// Sets the value. With `user`, the -command runs. The variable gets the value.
fn setValue(w: *Widget, v_in: f64, user: bool, animate: bool) ztcl.Error!void {
    const d = data(w);
    const v = round(w, v_in);
    if (v == d.value) return;
    const app = w.app;
    if (animate and !anim.reduced(app)) {
        d.anim_from = shownValue(w);
        d.anim_start = app.platform.nowUs();
        d.moving = true;
    } else d.moving = false;
    d.value = v;
    w.invalidate(.{ .style = false, .measure = false, .layout = false, .paint = true });
    const text = try format(w, app.it.alloc(), v);
    if (d.var_name.len > 0) {
        try varlink.write(w, d.var_name, text);
        if (!w.alive()) return;
    }
    if (user) {
        const cmd = options.get(w, "-command");
        if (cmd.set and cmd.text.len > 0) {
            const script = try std.fmt.allocPrint(app.gpa, "{s} {s}", .{ cmd.text, text });
            defer app.gpa.free(script);
            app.callback(script);
        }
    }
}

const move_us: i64 = 160_000;

/// The value that the slider shows now: the value, or a point of its move.
fn shownValue(w: *Widget) f64 {
    const d = data(w);
    if (!d.moving) return d.value;
    const since = w.app.platform.nowUs() - d.anim_start;
    if (since >= move_us) {
        d.moving = false;
        return d.value;
    }
    w.app.anim_more = true;
    const p = easing.Timing.ease_out.eval(@as(f32, @floatFromInt(since)) / @as(f32, @floatFromInt(move_us)));
    return d.anim_from + (d.value - d.anim_from) * p;
}

fn linkVariable(w: *Widget, name: []const u8) ztcl.Error!void {
    const d = data(w);
    try varlink.rename(w, &d.var_name, name, trace_command);
    if (!w.alive() or d.var_name.len == 0) return;
    if (varlink.read(w, d.var_name)) |t| {
        if (std.fmt.parseFloat(f64, std.mem.trim(u8, t, " "))) |v| {
            d.value = round(w, v);
            return;
        } else |_| {}
    }
    try varlink.write(w, d.var_name, try format(w, w.app.it.alloc(), d.value));
}

fn configured(w: *Widget, changed: []const usize) ztcl.Error!void {
    const d = data(w);
    for (changed) |i| {
        if (!w.alive()) return;
        const name = w.class.specs[i].name;
        if (std.mem.eql(u8, name, "-variable")) {
            try linkVariable(w, w.opts[i].text);
        } else if (std.mem.eql(u8, name, "-state")) {
            w.state.disabled = w.opts[i].value == .word and w.opts[i].value.word == 1;
        }
    }
    if (w.alive()) d.value = round(w, d.value);
}

fn created(w: *Widget) ztcl.Error!void {
    data(w).value = round(w, data(w).value);
}

// ---- Geometry ----

const Geo = struct {
    /// The track: the line from the first end to the last end, in widget coordinates.
    x0: i32,
    y0: i32,
    len: i32,
    /// The size of the slider.
    knob: i32,
    /// The rectangle of the value text, the label, and the ticks.
    value_h: i32,
    label_h: i32,
    tick_h: i32,
};

fn knobSize(w: *const Widget) i32 {
    return num.pxRound(@as(f64, w.style.font.size) * 1.4);
}

fn lineH(w: *Widget) i32 {
    return paint.lineHeight(w.app, w.style.font);
}

fn geo(w: *Widget) Geo {
    const ins = paint.insets(&w.style);
    const k = knobSize(w);
    const show = options.get(w, "-showvalue").value;
    const has_value = !(show == .boolean and !show.boolean);
    const has_label = (options.get(w, "-label").text.len > 0 and options.get(w, "-label").set);
    const has_ticks = dbl(w, "-tickinterval") != 0;
    const lh = lineH(w);
    const value_h: i32 = if (has_value) lh else 0;
    const label_h: i32 = if (has_label) lh else 0;
    const tick_h: i32 = if (has_ticks) lh else 0;
    if (horizontal(w)) {
        return .{ .x0 = ins.left + @divTrunc(k, 2), .y0 = ins.top + label_h + value_h + @divTrunc(k, 2), .len = @max(w.geom.w - ins.horizontal() - k, 1), .knob = k, .value_h = value_h, .label_h = label_h, .tick_h = tick_h };
    }
    const vw = valueWidth(w);
    return .{ .x0 = ins.left + (if (has_value) vw + 6 else 0) + @divTrunc(k, 2), .y0 = ins.top + label_h + @divTrunc(k, 2), .len = @max(w.geom.h - ins.vertical() - label_h - k, 1), .knob = k, .value_h = value_h, .label_h = label_h, .tick_h = tick_h };
}

fn valueWidth(w: *Widget) i32 {
    const a = w.app.it.alloc();
    const t1 = format(w, a, dbl(w, "-from")) catch "0";
    const t2 = format(w, a, dbl(w, "-to")) catch "0";
    return @max(paint.textSize(w.app, t1, w.style.font).w, paint.textSize(w.app, t2, w.style.font).w);
}

/// The position of a value along the track, from 0 to `len`.
fn posOf(w: *Widget, g: Geo, v: f64) i32 {
    const from = dbl(w, "-from");
    const to = dbl(w, "-to");
    if (to == from) return 0;
    const f = std.math.clamp((v - from) / (to - from), 0, 1);
    return num.pxRound(f * @as(f64, @floatFromInt(g.len)));
}

/// The value at a point of the widget.
fn valueAt(w: *Widget, g: Geo, x: i32, y: i32) f64 {
    const p: f64 = @floatFromInt(if (horizontal(w)) x - g.x0 else y - g.y0);
    const f = std.math.clamp(p / @as(f64, @floatFromInt(g.len)), 0, 1);
    const from = dbl(w, "-from");
    return from + (dbl(w, "-to") - from) * f;
}

fn measure(w: *Widget) geom.Size {
    w.app.ensureStyle(w);
    const g = geo(w);
    const ins = paint.insets(&w.style);
    const length = int(w, "-length");
    if (horizontal(w)) return .{ .w = num.add(@intCast(length), ins.horizontal()), .h = num.add(g.knob + g.value_h + g.label_h + g.tick_h, ins.vertical()) };
    const vw = valueWidth(w);
    const label_w: i32 = if (options.get(w, "-label").set) paint.textSize(w.app, options.get(w, "-label").text, w.style.font).w else 0;
    return .{ .w = num.add(@max((if (g.value_h > 0) vw + 6 else 0) + g.knob + (if (g.tick_h > 0) vw + 6 else 0), label_w), ins.horizontal()), .h = num.add(@intCast(length), ins.vertical() + g.label_h) };
}

fn paintScale(w: *Widget, b: *scene.Builder) anyerror!void {
    const app = w.app;
    const st = anim.shown(app, w);
    try paint.box(w, b, st);
    const g = geo(w);
    const d = data(w);
    const hz = horizontal(w);
    const trough = paint.partStyle(w, "trough", &d.trough).style;
    const slider = paint.partStyle(w, "slider", &d.slider).style;
    const fill = app.styles.compute(w, "fill", &w.style, app.env);
    const value_st = app.styles.compute(w, "value", &w.style, app.env);
    const th: i32 = @max(num.pxRound(@as(f64, w.style.font.size) * 0.3), 2);
    const pos = posOf(w, g, shownValue(w));
    if (hz) {
        try paint.styledBox(b, .{ .x = g.x0, .y = g.y0 - @divTrunc(th, 2), .w = g.len, .h = th }, &trough);
        if (pos > 0) try paint.styledBox(b, .{ .x = g.x0, .y = g.y0 - @divTrunc(th, 2), .w = pos, .h = th }, &fill);
        try paint.styledBox(b, .{ .x = g.x0 + pos - @divTrunc(g.knob, 2), .y = g.y0 - @divTrunc(g.knob, 2), .w = g.knob, .h = g.knob }, &slider);
    } else {
        try paint.styledBox(b, .{ .x = g.x0 - @divTrunc(th, 2), .y = g.y0, .w = th, .h = g.len }, &trough);
        if (pos > 0) try paint.styledBox(b, .{ .x = g.x0 - @divTrunc(th, 2), .y = g.y0, .w = th, .h = pos }, &fill);
        try paint.styledBox(b, .{ .x = g.x0 - @divTrunc(g.knob, 2), .y = g.y0 + pos - @divTrunc(g.knob, 2), .w = g.knob, .h = g.knob }, &slider);
    }
    const a = app.it.alloc();
    const ins = paint.insets(st);
    const lbl = options.get(w, "-label");
    if (lbl.set and lbl.text.len > 0) try paint.label(w, b, .{ .x = ins.left, .y = ins.top, .w = w.geom.w - ins.horizontal(), .h = g.label_h }, lbl.text, st, .w, .left);
    if (g.value_h > 0) {
        const t = try format(w, a, d.value);
        const tw = paint.textSize(app, t, value_st.font).w;
        if (hz) {
            const x = std.math.clamp(g.x0 + pos - @divTrunc(tw, 2), 0, @max(w.geom.w - tw, 0));
            try paint.label(w, b, .{ .x = x, .y = ins.top + g.label_h, .w = tw, .h = g.value_h }, t, &value_st, .center, .center);
        } else {
            try paint.label(w, b, .{ .x = ins.left, .y = g.y0 + pos - @divTrunc(g.value_h, 2), .w = valueWidth(w), .h = g.value_h }, t, &value_st, .e, .right);
        }
    }
    const tick = dbl(w, "-tickinterval");
    if (tick != 0) {
        const from = dbl(w, "-from");
        const to = dbl(w, "-to");
        const step = if ((to - from) * tick < 0) -tick else tick;
        var v = from;
        var n: u32 = 0;
        while (n < 200 and ((step > 0 and v <= to + 1e-9) or (step < 0 and v >= to - 1e-9))) : (n += 1) {
            const t = try format(w, a, v);
            const p = posOf(w, g, v);
            const tw = paint.textSize(app, t, value_st.font).w;
            if (hz) {
                const x = std.math.clamp(g.x0 + p - @divTrunc(tw, 2), 0, @max(w.geom.w - tw, 0));
                try paint.label(w, b, .{ .x = x, .y = g.y0 + @divTrunc(g.knob, 2) + 2, .w = tw, .h = g.tick_h }, t, &value_st, .center, .center);
            } else {
                try paint.label(w, b, .{ .x = g.x0 + @divTrunc(g.knob, 2) + 6, .y = g.y0 + p - @divTrunc(g.tick_h, 2), .w = tw, .h = g.tick_h }, t, &value_st, .w, .left);
            }
            v += step;
        }
    }
}

// ---- Commands ----

fn subcommand(w: *Widget, it: *ztcl.Interp, argv: []const Value) ztcl.Error!?Value {
    const sub = try it.str(argv[1]);
    const d = data(w);
    const a = it.alloc();
    if (std.mem.eql(u8, sub, "get")) {
        if (argv.len != 2 and argv.len != 4) return it.fail("wrong # args: should be \"{s} get ?x y?\"", .{w.path});
        if (argv.len == 4) {
            const x = try it.int(argv[2]);
            const y = try it.int(argv[3]);
            return .{ .str = try format(w, a, round(w, valueAt(w, geo(w), @intCast(std.math.clamp(x, -1 << 24, 1 << 24)), @intCast(std.math.clamp(y, -1 << 24, 1 << 24))))) };
        }
        return .{ .str = try format(w, a, d.value) };
    }
    if (std.mem.eql(u8, sub, "set")) {
        if (argv.len != 3) return it.fail("wrong # args: should be \"{s} set value\"", .{w.path});
        const t = try it.str(argv[2]);
        const v = std.fmt.parseFloat(f64, std.mem.trim(u8, t, " ")) catch return it.fail("expected floating-point number but got \"{s}\"", .{t});
        if (w.state.disabled) return Value.empty;
        try setValue(w, v, false, false);
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "coords")) {
        if (argv.len != 2 and argv.len != 3) return it.fail("wrong # args: should be \"{s} coords ?value?\"", .{w.path});
        const v = if (argv.len == 3) blk: {
            const t = try it.str(argv[2]);
            break :blk std.fmt.parseFloat(f64, t) catch return it.fail("expected floating-point number but got \"{s}\"", .{t});
        } else d.value;
        const g = geo(w);
        const p = posOf(w, g, round(w, v));
        return .{ .str = if (horizontal(w)) try std.fmt.allocPrint(a, "{d} {d}", .{ g.x0 + p, g.y0 }) else try std.fmt.allocPrint(a, "{d} {d}", .{ g.x0, g.y0 + p }) };
    }
    if (std.mem.eql(u8, sub, "identify")) {
        if (argv.len != 4) return it.fail("wrong # args: should be \"{s} identify x y\"", .{w.path});
        const x: i32 = @intCast(std.math.clamp(try it.int(argv[2]), -1 << 24, 1 << 24));
        const y: i32 = @intCast(std.math.clamp(try it.int(argv[3]), -1 << 24, 1 << 24));
        return .{ .str = identify(w, x, y) };
    }
    return null;
}

fn identify(w: *Widget, x: i32, y: i32) []const u8 {
    if (x < 0 or y < 0 or x >= w.geom.w or y >= w.geom.h) return "";
    const g = geo(w);
    const p = posOf(w, g, data(w).value);
    const along = if (horizontal(w)) x - g.x0 else y - g.y0;
    const across = if (horizontal(w)) y - g.y0 else x - g.x0;
    if (@abs(across) > @divTrunc(g.knob, 2)) return "";
    if (@abs(along - p) <= @divTrunc(g.knob, 2)) return "slider";
    return if (along < p) "trough1" else "trough2";
}

const Action = enum { press, motion, release, jump, set, step, big, home, end };

/// `::ztk::priv::scale action path ?x y? ?dir?`
fn cmdScale(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    app.enter();
    defer app.leave();
    if (argv.len < 3) return it.wrongArgs("::ztk::priv::scale action window ?x y?");
    const act = std.meta.stringToEnum(Action, try it.str(argv[1])) orelse return it.fail("bad action", .{});
    const w = app.find(try it.str(argv[2])) orelse return Value.empty;
    if (w.class != &class or w.state.disabled) return Value.empty;
    const d = data(w);
    const g = geo(w);
    const res = blk: {
        const r = dbl(w, "-resolution");
        break :blk if (r > 0) r else @abs(dbl(w, "-to") - dbl(w, "-from")) / 100;
    };
    const sign: f64 = if (dbl(w, "-to") >= dbl(w, "-from")) 1 else -1;
    switch (act) {
        .press, .motion, .jump, .set => {
            if (argv.len < 5) return Value.empty;
            const x: i32 = @intCast(std.math.clamp(try it.int(argv[3]), -1 << 24, 1 << 24));
            const y: i32 = @intCast(std.math.clamp(try it.int(argv[4]), -1 << 24, 1 << 24));
            switch (act) {
                .press => {
                    if (focus.accepts(w)) focus.set(app, w);
                    const part = identify(w, x, y);
                    if (std.mem.eql(u8, part, "slider")) {
                        d.dragging = true;
                        const p = posOf(w, g, d.value);
                        d.drag_off = (if (horizontal(w)) x - g.x0 else y - g.y0) - p;
                        w.state.pressed = true;
                    } else if (part.len > 0) {
                        const dir: f64 = if (std.mem.eql(u8, part, "trough1")) -1 else 1;
                        try setValue(w, d.value + dir * res * sign, true, true);
                    }
                },
                .motion => if (d.dragging) {
                    const ax = if (horizontal(w)) x - d.drag_off else x;
                    const ay = if (horizontal(w)) y else y - d.drag_off;
                    // A drag follows the pointer in the next frame, with no ease.
                    try setValue(w, valueAt(w, g, ax, ay), true, false);
                },
                .jump => {
                    const part = identify(w, x, y);
                    if (std.mem.eql(u8, part, "trough1")) try setValue(w, dbl(w, "-from"), true, true);
                    if (std.mem.eql(u8, part, "trough2")) try setValue(w, dbl(w, "-to"), true, true);
                },
                .set => try setValue(w, valueAt(w, g, x, y), true, true),
                else => unreachable,
            }
        },
        .release => {
            d.dragging = false;
            w.state.pressed = false;
            w.invalidate(.{ .style = true, .measure = false, .layout = false, .paint = true });
        },
        .step, .big => {
            if (argv.len < 4) return Value.empty;
            const dir: f64 = if (std.mem.eql(u8, try it.str(argv[3]), "-1")) -1 else 1;
            var inc = res;
            if (act == .big) {
                const bi = dbl(w, "-bigincrement");
                inc = if (bi > 0) bi else @abs(dbl(w, "-to") - dbl(w, "-from")) / 10;
            }
            try setValue(w, d.value + dir * inc * sign, true, true);
        },
        .home => try setValue(w, dbl(w, "-from"), true, true),
        .end => try setValue(w, dbl(w, "-to"), true, true),
    }
    return Value.empty;
}

/// `::ztk::priv::scalevar path`: the variable of a scale changed.
fn cmdScalevar(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    app.enter();
    defer app.leave();
    if (argv.len < 2) return Value.empty;
    const w = app.find(try it.str(argv[1])) orelse return Value.empty;
    if (w.class != &class) return Value.empty;
    const d = data(w);
    const t = varlink.read(w, d.var_name) orelse return Value.empty;
    const v = std.fmt.parseFloat(f64, std.mem.trim(u8, t, " ")) catch return Value.empty;
    const r = round(w, v);
    if (r != d.value) {
        d.value = r;
        d.moving = false;
        w.invalidate(.{ .style = false, .measure = false, .layout = false, .paint = true });
    }
    return Value.empty;
}

pub fn register(app: *App) !void {
    const it = app.it;
    try it.register("scale", widget.classCommand(&class));
    try app.classes.put(app.gpa, "scale", &class);
    try it.register("ztk::priv::scale", cmdScale);
    try it.register("ztk::priv::scalevar", cmdScalevar);
    _ = try it.eval(
        \\bind Scale <Button-1> {::ztk::priv::scale press %W %x %y}
        \\bind Scale <B1-Motion> {::ztk::priv::scale motion %W %x %y}
        \\bind Scale <ButtonRelease-1> {::ztk::priv::scale release %W}
        \\bind Scale <Control-Button-1> {::ztk::priv::scale jump %W %x %y}
        \\bind Scale <Button-2> {::ztk::priv::scale set %W %x %y}
        \\bind Scale <Key-Left> {::ztk::priv::scale step %W -1}
        \\bind Scale <Key-Up> {::ztk::priv::scale step %W -1}
        \\bind Scale <Key-Right> {::ztk::priv::scale step %W 1}
        \\bind Scale <Key-Down> {::ztk::priv::scale step %W 1}
        \\bind Scale <Control-Key-Left> {::ztk::priv::scale big %W -1}
        \\bind Scale <Control-Key-Up> {::ztk::priv::scale big %W -1}
        \\bind Scale <Control-Key-Right> {::ztk::priv::scale big %W 1}
        \\bind Scale <Control-Key-Down> {::ztk::priv::scale big %W 1}
        \\bind Scale <Key-Home> {::ztk::priv::scale home %W}
        \\bind Scale <Key-End> {::ztk::priv::scale end %W}
    );
}
