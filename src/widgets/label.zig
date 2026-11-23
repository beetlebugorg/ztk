//! The label class. A label shows text. The text comes from `-text`, or
//! from the global variable of `-textvariable`. A script trace on the
//! variable marks the label for a new measure and paint. The label keeps
//! a copy of the last value of the variable, so a variable that is unset
//! leaves the text as it was. The size is the size of the text plus the
//! border and the padding of the style.
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
const App = @import("../app.zig").App;
const Spec = options.Spec;
const Widget = widget.Widget;

const state_words = [_][]const u8{ "active", "disabled", "normal" };

/// A subset of the options of `wish`, in the order of `wish`.
pub const specs = [_]Spec{
    .{ .name = "-anchor", .db_name = "anchor", .db_class = "Anchor", .type = .anchor, .default = "center" },
    .{ .name = "-background", .db_name = "background", .db_class = "Background", .type = .color, .default = "#d9d9d9", .from_style = true, .style_prop = .background },
    .{ .name = "-bd", .type = .synonym, .target = "-borderwidth" },
    .{ .name = "-bg", .type = .synonym, .target = "-background" },
    .{ .name = "-borderwidth", .db_name = "borderWidth", .db_class = "BorderWidth", .type = .pixels, .default = "0", .from_style = true, .style_prop = .border_width },
    .{ .name = "-cursor", .db_name = "cursor", .db_class = "Cursor", .type = .string, .allow_empty = true },
    .{ .name = "-fg", .type = .synonym, .target = "-foreground" },
    .{ .name = "-font", .db_name = "font", .db_class = "Font", .type = .font, .default = "TkDefaultFont" },
    .{ .name = "-foreground", .db_name = "foreground", .db_class = "Foreground", .type = .color, .default = "#000000", .from_style = true },
    .{ .name = "-height", .db_name = "height", .db_class = "Height", .type = .int, .default = "0" },
    .{ .name = "-justify", .db_name = "justify", .db_class = "Justify", .type = .justify, .default = "center" },
    .{ .name = "-padx", .db_name = "padX", .db_class = "Pad", .type = .pixels, .default = "0" },
    .{ .name = "-pady", .db_name = "padY", .db_class = "Pad", .type = .pixels, .default = "0" },
    .{ .name = "-relief", .db_name = "relief", .db_class = "Relief", .type = .relief, .default = "flat", .from_style = true },
    .{ .name = "-state", .db_name = "state", .db_class = "State", .type = .state, .default = "normal", .words = &state_words },
    .{ .name = "-takefocus", .db_name = "takeFocus", .db_class = "TakeFocus", .type = .string, .default = "0" },
    .{ .name = "-text", .db_name = "text", .db_class = "Text", .type = .string, .allow_empty = true },
    .{ .name = "-textvariable", .db_name = "textVariable", .db_class = "Variable", .type = .variable, .allow_empty = true },
    .{ .name = "-width", .db_name = "width", .db_class = "Width", .type = .int, .default = "0" },
};

pub const class: widget.Class = .{
    .command = "label",
    .tk_class = "Label",
    .specs = &specs,
    .init = init,
    .deinit = deinit,
    .teardown = teardown,
    .configured = configured,
    .retrace = retrace,
    .trace_command = trace_command,
    .traced_var = tracedVar,
    .variable_text = variableText,
    .measure = measure,
    .paint = paintLabel,
};

pub const trace_command = "::ztk::priv::textvar";

/// The name of the variable that the label traces, or empty.
pub fn tracedVar(w: *const Widget) []const u8 {
    return dataOf(w).var_name;
}

/// The value of `-text` while a `-textvariable` supplies it.
pub fn variableText(w: *const Widget) ?[]const u8 {
    const d = dataOf(w);
    return if (d.var_name.len > 0) d.shown else null;
}

/// The data of a label.
pub const Data = struct {
    /// The name of the traced variable, or empty.
    var_name: []u8 = &.{},
    /// The last value of the variable.
    shown: []u8 = &.{},
    /// A button is armed by a press and invoked by the release.
    armed: bool = false,
};

pub fn dataOf(w: *const Widget) *Data {
    return @ptrCast(@alignCast(w.data.?));
}

pub fn init(w: *Widget) anyerror!void {
    const d = try w.app.gpa.create(Data);
    d.* = .{};
    w.data = d;
}

pub fn deinit(w: *Widget) void {
    const gpa = w.app.gpa;
    const d = dataOf(w);
    gpa.free(d.var_name);
    gpa.free(d.shown);
    gpa.destroy(d);
    w.data = null;
}

/// Removes the trace when the widget is deleted. A new widget with the
/// same path adds a trace with the same text, so the removal cannot wait.
pub fn teardown(w: *Widget) void {
    const d = dataOf(w);
    removeTrace(w, d);
    w.app.gpa.free(d.var_name);
    d.var_name = &.{};
}

fn traceWords(w: *const Widget, d: *const Data, verb: []const u8) [6]ztcl.Value {
    const a = w.app.it.alloc();
    const script = widget.traceScript(a, trace_command, w.path);
    return .{ .{ .str = "trace" }, .{ .str = verb }, .{ .str = "variable" }, .{ .str = d.var_name }, .{ .str = "write" }, .{ .str = script } };
}

fn removeTrace(w: *Widget, d: *Data) void {
    if (d.var_name.len == 0) return;
    const words = traceWords(w, d, "remove");
    _ = w.app.callTrace(&words) catch {};
}

fn textOption(w: *const Widget) []const u8 {
    const s = options.get(w, "-text");
    return if (s.set) s.text else "";
}

/// The text that the label shows.
pub fn text(w: *const Widget) []const u8 {
    const d = dataOf(w);
    return if (d.var_name.len > 0) d.shown else textOption(w);
}

fn readVariable(w: *Widget, d: *Data) void {
    const it = w.app.it;
    const gpa = w.app.gpa;
    // A read trace can delete the widget and free `var_name`.
    const name = it.alloc().dupe(u8, d.var_name) catch return;
    const v = (it.getVarOpt(name) catch null) orelse return;
    const s = it.str(v) catch return;
    const copy = gpa.dupe(u8, s) catch return;
    gpa.free(d.shown);
    d.shown = copy;
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

pub fn configured(w: *Widget, changed: []const usize) ztcl.Error!void {
    const app = w.app;
    const d = dataOf(w);
    for (changed) |i| {
        // A variable trace of an earlier option can delete the widget.
        if (w.life == .dead) return;
        const name = w.class.specs[i].name;
        if (std.mem.eql(u8, name, "-state")) {
            w.state.disabled = w.opts[i].value == .word and w.opts[i].value.word == 1;
            // The state `active` shows the hover colors.
            const active = w.opts[i].value == .word and w.opts[i].value.word == 0;
            w.state.hover = active or app.dispatch.hover == w;
        } else if (std.mem.eql(u8, name, "-textvariable")) {
            const gpa = app.gpa;
            // Tk reads the variable in the global namespace, whatever the caller is.
            const new_name: []u8 = if (w.opts[i].text.len > 0) try widget.globalVar(gpa, w.opts[i].text) else &.{};
            defer if (new_name.len > 0) gpa.free(new_name);
            if (!std.mem.eql(u8, new_name, d.var_name)) {
                removeTrace(w, d);
                gpa.free(d.var_name);
                d.var_name = &.{};
                if (new_name.len > 0) {
                    d.var_name = try gpa.dupe(u8, new_name);
                    // A variable that does not exist gets the text of `-text`.
                    const it = app.it;
                    // Each step below can run a trace that deletes the widget.
                    const missing = (try it.getVarOpt(new_name)) == null;
                    if (w.life == .dead) return;
                    if (missing) try it.setVar(new_name, .{ .str = textOption(w) });
                    if (w.life == .dead) return;
                    readVariable(w, d);
                    if (w.life == .dead) return;
                    const words = traceWords(w, d, "add");
                    _ = try app.callTrace(&words);
                }
            }
        }
    }
}

pub fn measure(w: *Widget) geom.Size {
    const app = w.app;
    app.ensureStyle(w);
    const st = &w.style;
    var size = paint.textSize(app, text(w), st.font);
    const wd = options.get(w, "-width").value;
    const ht = options.get(w, "-height").value;
    if (wd == .int and wd.int > 0) size.w = num.px(@min(wd.int, 10000) * paint.zeroWidth(app, st.font));
    if (ht == .int and ht.int > 0) size.h = num.px(@min(ht.int, 10000) * paint.lineHeight(app, st.font));
    const ins = paint.insets(st);
    return .{
        .w = @max(num.add(size.w, ins.horizontal()), st.min_width),
        .h = @max(num.add(size.h, ins.vertical()), st.min_height),
    };
}

pub fn paintLabel(w: *Widget, b: *scene.Builder) anyerror!void {
    const st = anim.shown(w.app, w);
    try paint.box(w, b, st);
    const an = options.get(w, "-anchor").value;
    const ju = options.get(w, "-justify").value;
    try paint.label(w, b, paint.contentRect(w, st), text(w), st, if (an == .anchor) an.anchor else .center, if (ju == .justify) ju.justify else .center);
}

/// `::ztk::priv::textvar path`: the variable of a label changed.
pub fn cmdTextvar(it: *ztcl.Interp, argv: []const ztcl.Value, _: ?*ztcl.interp.Cmd) ztcl.Error!ztcl.Value {
    const app = App.of(it);
    app.enter();
    defer app.leave();
    if (argv.len < 2) return ztcl.Value.empty;
    const w = app.find(try it.str(argv[1])) orelse return ztcl.Value.empty;
    if (w.class.measure != measure) return ztcl.Value.empty;
    readVariable(w, dataOf(w));
    w.invalidate(.{ .style = false, .measure = true, .layout = true, .paint = true });
    return ztcl.Value.empty;
}
