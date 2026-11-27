//! The `ttk` widgets for a value in a range: `ttk::scale`,
//! `ttk::scrollbar`, and `ttk::spinbox` on the code of their classic
//! classes, and `ttk::progressbar`.
//!
//! A progress bar draws a track (part `::trough`) and a bar (part
//! `::bar`). In the determinate mode the bar fills `-value / -maximum` of
//! the track, and a change of the value eases from the shown length. In
//! the indeterminate mode a short bar moves along the track. While
//! `start` runs, the bar moves back and forth as a frame animation with
//! no end, so the render thread moves it and the UI thread paints no
//! frame for it. Without `start`, the place of the bar follows the value.
//! `start` and `stop` are the procedures of `ttk::progressbar` of Tk: a
//! timer of `after` runs `step` at each interval.
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
const varlink = @import("../varlink.zig");
const ttk = @import("widgets.zig");
const scale = @import("../widgets/scale.zig");
const scrollbar = @import("../widgets/scrollbar.zig");
const spinbox = @import("../widgets/spinbox.zig");
const entry = @import("../widgets/entry.zig");
const App = @import("../app.zig").App;
const Spec = options.Spec;
const Widget = widget.Widget;
const Value = ztcl.Value;
const s = ttk.s;

const orient_words = [_][]const u8{ "horizontal", "vertical" };
const mode_words = [_][]const u8{ "determinate", "indeterminate" };

fn orient(comptime def: []const u8) Spec {
    return .{ .name = "-orient", .db_name = "orient", .db_class = "Orient", .type = .word, .default = def, .words = &orient_words };
}

fn hidden(comptime name: []const u8, comptime ty: options.Type, comptime def: []const u8) Spec {
    return .{ .name = name, .type = ty, .default = def, .hidden = true };
}

// ---- ttk::scale ----

const scale_specs = options.withHidden(&([_]Spec{
    s("-command", "command", "Command", .script, ""),
    s("-variable", "variable", "Variable", .variable, ""),
    orient("horizontal"),
    .{ .name = "-from", .db_name = "from", .db_class = "From", .type = .double, .default = "0" },
    .{ .name = "-to", .db_name = "to", .db_class = "To", .type = .double, .default = "1.0" },
    .{ .name = "-value", .db_name = "value", .db_class = "Value", .type = .double, .default = "0" },
    .{ .name = "-length", .db_name = "length", .db_class = "Length", .type = .pixels, .default = "100" },
    s("-state", "state", "State", .string, "normal"),
    ttk.takefocus,
} ++ ttk.tail ++ [_]Spec{
    // A `ttk::scale` has no resolution and shows no value text.
    hidden("-resolution", .double, "0"),
    hidden("-showvalue", .boolean, "0"),
}), &scale.specs);

const scale_subs = [_][]const u8{ "configure", "cget", "state", "instate", "identify", "set", "get", "coords" };
pub const scale_class = ttk.derive(scale.class, "ttk::scale", "TScale", scale_specs, &scale_subs, "");

// ---- ttk::scrollbar ----

const scrollbar_specs = options.withHidden(&([_]Spec{
    s("-command", "command", "Command", .script, ""),
    orient("vertical"),
    ttk.takefocus_none,
} ++ ttk.tail), &scrollbar.specs);

const scrollbar_subs = [_][]const u8{ "configure", "cget", "delta", "fraction", "get", "identify", "instate", "set", "state" };
pub const scrollbar_class = ttk.derive(scrollbar.class, "ttk::scrollbar", "TScrollbar", scrollbar_specs, &scrollbar_subs, "");

// ---- ttk::spinbox ----

fn spinPick(comptime name: []const u8) Spec {
    return ttk.pickFrom(&spinbox.specs, name);
}

const spinbox_specs = options.withHidden(&([_]Spec{
    spinPick("-values"), spinPick("-from"),    spinPick("-to"), spinPick("-increment"),
    spinPick("-format"), spinPick("-command"), spinPick("-wrap"),
} ++ ttk.entry_common ++ entry.addition_specs), &spinbox.specs);

const spinbox_subs = [_][]const u8{ "bbox", "cget", "configure", "delete", "get", "icursor", "identify", "index", "insert", "instate", "selection", "state", "set", "validate", "xview" };
pub const spinbox_class = ttk.derive(spinbox.class, "ttk::spinbox", "TSpinbox", spinbox_specs, &spinbox_subs, "");

// ---- ttk::progressbar ----

const progress_specs = [_]Spec{
    orient("horizontal"),
    .{ .name = "-length", .db_name = "length", .db_class = "Length", .type = .pixels, .default = "100" },
    .{ .name = "-mode", .db_name = "mode", .db_class = "ProgressMode", .type = .word, .default = "determinate", .words = &mode_words },
    .{ .name = "-maximum", .db_name = "maximum", .db_class = "Maximum", .type = .double, .default = "100" },
    s("-variable", "variable", "Variable", .variable, ""),
    .{ .name = "-value", .db_name = "value", .db_class = "Value", .type = .double, .default = "0.0" },
    .{ .name = "-phase", .db_name = "phase", .db_class = "Phase", .type = .int, .default = "0" },
    ttk.takefocus_none,
} ++ ttk.tail;

const progress_trace = "::ztk::priv::progressvar";

const progress_base: widget.Class = .{
    .command = "",
    .tk_class = "",
    .role = "progress bar",
    .init = init,
    .deinit = deinit,
    .teardown = teardown,
    .retrace = retrace,
    .trace_command = progress_trace,
    .traced_var = tracedVar,
    .configured = configured,
    .measure = measure,
    .paint = paintProgress,
    .subcommand = subcommand,
};

const progress_subs = [_][]const u8{ "configure", "cget", "identify", "instate", "start", "state", "step", "stop" };
pub const progress_class = ttk.derive(progress_base, "ttk::progressbar", "TProgressbar", &progress_specs, &progress_subs, "");

const Data = struct {
    var_name: []u8 = &.{},
    /// The ease of the determinate bar: the shown value at the start, and the time.
    anim_from: f64 = 0,
    anim_start: i64 = 0,
    moving: bool = false,
    /// True while `start` runs, and the time when it started.
    running: bool = false,
    run_start: i64 = 0,
    trough: paint.PartAnim = .{},
    bar: paint.PartAnim = .{},
};

/// The time of one move of the indeterminate bar from one end to the other.
const sweep_us: i64 = 1_200_000;
/// The time of the ease of the determinate bar to a new value.
const move_us: i64 = 200_000;

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
    varlink.remove(w, d.var_name, progress_trace);
    w.app.gpa.free(d.var_name);
    d.var_name = &.{};
}

fn retrace(w: *Widget) void {
    const d = data(w);
    varlink.remove(w, d.var_name, progress_trace);
    varlink.add(w, d.var_name, progress_trace) catch {};
}

fn dbl(w: *const Widget, comptime name: []const u8) f64 {
    const v = options.get(w, name).value;
    return if (v == .double) v.double else 0;
}

fn horizontal(w: *const Widget) bool {
    const v = options.get(w, "-orient").value;
    return v == .word and v.word == 0;
}

fn indeterminate(w: *const Widget) bool {
    const v = options.get(w, "-mode").value;
    return v == .word and v.word == 1;
}

/// Starts the ease of the bar from the value that it shows now.
fn startMove(w: *Widget, old: f64) void {
    const d = data(w);
    if (indeterminate(w) and d.running) return;
    if (!anim.reduced(w.app) and !indeterminate(w)) {
        d.anim_from = if (d.moving) shownValue(w) else old;
        d.anim_start = w.app.platform.nowUs();
        d.moving = true;
    }
    w.invalidate(.{ .style = false, .measure = false, .layout = false, .paint = true });
}

/// Sets the value from a number, and writes the variable.
fn setValue(w: *Widget, v: f64) ztcl.Error!void {
    const old = dbl(w, "-value");
    const text = try options.formatDouble(w.app.it.alloc(), v);
    try options.store(w, options.index(w, "-value"), text, .{ .double = v });
    startMove(w, old);
    const d = data(w);
    if (d.var_name.len > 0) try varlink.write(w, d.var_name, text);
}

/// Reads the linked variable. A number becomes the value, and other text
/// sets the state `invalid`.
fn readVariable(w: *Widget) ztcl.Error!void {
    const d = data(w);
    const t = varlink.read(w, d.var_name) orelse return;
    const v = std.fmt.parseFloat(f64, std.mem.trim(u8, t, " ")) catch {
        w.state.invalid = true;
        w.invalidate(.{ .style = true, .measure = false, .layout = false, .paint = true });
        return;
    };
    w.state.invalid = false;
    const old = dbl(w, "-value");
    try options.store(w, options.index(w, "-value"), t, .{ .double = v });
    startMove(w, old);
}

fn configured(w: *Widget, changed: []const usize) ztcl.Error!void {
    const d = data(w);
    for (changed) |i| {
        if (!w.alive()) return;
        const name = w.class.specs[i].name;
        if (std.mem.eql(u8, name, "-variable")) {
            try varlink.rename(w, &d.var_name, w.opts[i].text, progress_trace);
            if (w.alive() and d.var_name.len > 0) try readVariable(w);
        } else if (std.mem.eql(u8, name, "-value")) {
            if (d.var_name.len > 0) try varlink.write(w, d.var_name, w.opts[i].text);
        }
    }
}

/// The value that the bar shows now: the value, or a point of its ease.
pub fn shownValue(w: *Widget) f64 {
    const d = data(w);
    const v = dbl(w, "-value");
    if (!d.moving) return v;
    const since = w.app.platform.nowUs() - d.anim_start;
    if (since >= move_us) {
        d.moving = false;
        return v;
    }
    if (w.app.part_end) return v;
    w.app.anim_more = true;
    const p = easing.Timing.ease_out.eval(@as(f32, @floatFromInt(since)) / @as(f32, @floatFromInt(move_us)));
    w.app.notePartMove(d.anim_start, .{ .duration_ms = @intCast(@divTrunc(move_us, 1000)), .timing = easing.Timing.ease_out }, p);
    return d.anim_from + (v - d.anim_from) * p;
}

/// The thickness of the track and the bar.
fn thickness(w: *const Widget) i32 {
    return @max(num.pxRound(@as(f64, w.style.font.size) * 0.45), 4);
}

fn measure(w: *Widget) geom.Size {
    w.app.ensureStyle(w);
    const ins = paint.insets(&w.style);
    const v = options.get(w, "-length").value;
    const length: i32 = if (v == .pixels) @max(v.pixels, 0) else 100;
    const th = thickness(w);
    if (horizontal(w)) return .{ .w = num.add(length, ins.horizontal()), .h = num.add(th, ins.vertical()) };
    return .{ .w = num.add(th, ins.horizontal()), .h = num.add(length, ins.vertical()) };
}

/// The rectangle of the track in the widget.
fn track(w: *Widget, st: *const @import("../style.zig").Style) geom.Rect {
    const r = paint.contentRect(w, st);
    const th = @min(thickness(w), if (horizontal(w)) r.h else r.w);
    if (horizontal(w)) return .{ .x = r.x, .y = r.y + @divTrunc(r.h - th, 2), .w = r.w, .h = th };
    return .{ .x = r.x + @divTrunc(r.w - th, 2), .y = r.y, .w = th, .h = r.h };
}

/// The rectangle of the bar: `start` and `len` along the track, from the
/// left end, or from the bottom end of a vertical bar.
fn barRect(w: *const Widget, t: geom.Rect, start: i32, len: i32) geom.Rect {
    if (horizontal(w)) return .{ .x = t.x + start, .y = t.y, .w = len, .h = t.h };
    return .{ .x = t.x, .y = t.y + t.h - start - len, .w = t.w, .h = len };
}

fn paintProgress(w: *Widget, b: *scene.Builder) anyerror!void {
    const app = w.app;
    const st = anim.shown(app, w);
    try paint.box(w, b, st);
    const d = data(w);
    const t = track(w, st);
    const along = if (horizontal(w)) t.w else t.h;
    if (along <= 0) return;
    const trough = paint.partStyle(w, "trough", &d.trough).style;
    const bar = paint.partStyle(w, "bar", &d.bar).style;
    try paint.styledBox(b, t, &trough);
    const max = dbl(w, "-maximum");
    if (!indeterminate(w)) {
        const f = if (max > 0) std.math.clamp(shownValue(w) / max, 0, 1) else 0;
        const len = num.pxRound(f * @as(f64, @floatFromInt(along)));
        if (len > 0) try paint.styledBox(b, barRect(w, t, 0, len), &bar);
        return;
    }
    const blen = @min(@max(@divTrunc(along, 4), (if (horizontal(w)) t.h else t.w) * 2), along);
    const room: f64 = @floatFromInt(along - blen);
    if (!d.running or anim.reduced(app)) {
        // The place follows the value: the bar goes to the end and back in each `-maximum`.
        const m = if (max > 0) max else 100;
        const q = @mod(dbl(w, "-value"), 2 * m) / m;
        const f = if (q <= 1) q else 2 - q;
        try paint.styledBox(b, barRect(w, t, num.pxRound(f * room), blen), &bar);
        return;
    }
    const loop_anim: scene.FrameAnim = .{ .first = 0, .count = 0, .from = 0, .start_us = d.run_start, .delay_us = 0, .len_us = sweep_us, .timing = easing.Timing.ease_in_out, .iterations = 0, .direction = .alternate };
    const now = if (app.anim_frame) |fr| fr.time_us else app.platform.nowUs();
    const p = loop_anim.sample(now).p orelse 0;
    const quads = &b.scene.quads;
    const at = quads.items.len;
    try paint.styledBox(b, barRect(w, t, num.pxRound(p * room), blen), &bar);
    const fr = app.anim_frame orelse {
        app.anim_more = true;
        return;
    };
    const n = quads.items.len - at;
    try paint.styledBox(b, barRect(w, t, 0, blen), &bar);
    try paint.styledBox(b, barRect(w, t, num.pxRound(room), blen), &bar);
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
    var a = loop_anim;
    a.first = @intCast(at);
    a.count = @intCast(n);
    a.from = @intCast(mark);
    a.offsets = @intCast(off_at);
    try fr.anims.append(gpa, a);
}

fn subcommand(w: *Widget, it: *ztcl.Interp, argv: []const Value) ztcl.Error!?Value {
    const sub = try it.str(argv[1]);
    if (std.mem.eql(u8, sub, "step")) {
        if (argv.len > 3) return it.fail("wrong # args: should be \"{s} step ?amount?\"", .{w.path});
        var amount: f64 = 1;
        if (argv.len == 3) {
            const t = try it.str(argv[2]);
            amount = std.fmt.parseFloat(f64, std.mem.trim(u8, t, " ")) catch return it.fail("expected floating-point number but got \"{s}\"", .{t});
        }
        var v = dbl(w, "-value") + amount;
        const max = dbl(w, "-maximum");
        if (max > 0 and v >= max) v = @mod(v, max);
        try setValue(w, v);
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "start") or std.mem.eql(u8, sub, "stop")) {
        var words: [4]Value = undefined;
        words[0] = .{ .str = if (sub[2] == 'a') "::ttk::progressbar::start" else "::ttk::progressbar::stop" };
        words[1] = .{ .str = w.path };
        const extra = argv[2..];
        if (extra.len > 2) return it.fail("wrong # args: should be \"{s} {s} ?interval?\"", .{ w.path, sub });
        for (extra, 0..) |e, k| words[2 + k] = e;
        return try it.callWords(words[0 .. 2 + extra.len]);
    }
    if (std.mem.eql(u8, sub, "identify")) {
        const x = try it.int(argv[2]);
        const y = try it.int(argv[3]);
        if (x < 0 or y < 0 or x >= w.geom.w or y >= w.geom.h) return Value.empty;
        return .{ .str = "pbar" };
    }
    return null;
}

/// `::ztk::priv::progress run path 0|1`: `start` and `stop` turn the
/// moving bar on and off.
fn cmdProgress(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    app.enter();
    defer app.leave();
    if (argv.len != 4) return it.wrongArgs("::ztk::priv::progress run window flag");
    const w = app.find(try it.str(argv[2])) orelse return Value.empty;
    if (w.class != &progress_class) return Value.empty;
    const d = data(w);
    const on = try it.int(argv[3]) != 0;
    if (on == d.running) return Value.empty;
    d.running = on;
    d.run_start = app.platform.nowUs();
    w.invalidate(.{ .style = false, .measure = false, .layout = false, .paint = true });
    return Value.empty;
}

/// `::ztk::priv::progressvar path`: the variable of a progress bar changed.
fn cmdProgressvar(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    app.enter();
    defer app.leave();
    if (argv.len < 2) return Value.empty;
    const w = app.find(try it.str(argv[1])) orelse return Value.empty;
    if (w.class != &progress_class) return Value.empty;
    try readVariable(w);
    return Value.empty;
}

pub fn register(app: *App) !void {
    const it = app.it;
    const list = [_]*const widget.Class{ &scale_class, &scrollbar_class, &spinbox_class, &progress_class };
    inline for (list) |c| {
        try it.register(c.command, widget.classCommand(c));
        try app.classes.put(app.gpa, c.command, c);
    }
    try it.register("ztk::priv::progress", cmdProgress);
    try it.register("ztk::priv::progressvar", cmdProgressvar);
    try entry.bindClass(app, "TSpinbox");
    _ = try it.eval(
        \\foreach ttk_event [bind Scale] {bind TScale $ttk_event [bind Scale $ttk_event]}
        \\foreach ttk_event [bind Scrollbar] {bind TScrollbar $ttk_event [bind Scrollbar $ttk_event]}
        \\unset ttk_event
        \\bind TSpinbox <Key-Up> {event generate %W <<Increment>>}
        \\bind TSpinbox <Key-Down> {event generate %W <<Decrement>>}
        \\bind TSpinbox <<Increment>> {::ztk::priv::spin %W up}
        \\bind TSpinbox <<Decrement>> {::ztk::priv::spin %W down}
        \\namespace eval ::ttk::progressbar {variable Timers; array set Timers {}}
        \\proc ::ttk::progressbar::start {pb {steptime 50} {stepsize 1}} {
        \\    variable Timers
        \\    if {![info exists Timers($pb)]} {
        \\        Autoincrement $pb $steptime $stepsize
        \\        ::ztk::priv::progress run $pb 1
        \\    }
        \\}
        \\proc ::ttk::progressbar::stop {pb} {
        \\    variable Timers
        \\    if {[info exists Timers($pb)]} {
        \\        after cancel $Timers($pb)
        \\        unset Timers($pb)
        \\    }
        \\    ::ztk::priv::progress run $pb 0
        \\}
        \\proc ::ttk::progressbar::Autoincrement {pb steptime stepsize} {
        \\    variable Timers
        \\    if {![winfo exists $pb]} {
        \\        unset -nocomplain Timers($pb)
        \\        return
        \\    }
        \\    set Timers($pb) [after $steptime [list ::ttk::progressbar::Autoincrement $pb $steptime $stepsize]]
        \\    $pb step $stepsize
        \\}
    );
    try it.register("ztk::priv::spin", cmdSpin);
}

/// `::ztk::priv::spin path up|down`: steps a `ttk::spinbox`.
fn cmdSpin(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    app.enter();
    defer app.leave();
    if (argv.len != 3) return it.wrongArgs("::ztk::priv::spin window up|down");
    const w = app.find(try it.str(argv[1])) orelse return Value.empty;
    if (w.class != &spinbox_class) return Value.empty;
    try spinbox.invoke(w, if (std.mem.eql(u8, try it.str(argv[2]), "up")) .buttonup else .buttondown);
    return Value.empty;
}
