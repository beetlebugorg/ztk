//! The `checkbutton` and `radiobutton` classes. Both build on the label:
//! the text, the measure, and the `-command` of the button. Each one has
//! a `-variable`. A write trace on it sets the `selected` state (the
//! value is `-onvalue`, or `-value` for a radiobutton) and the
//! `alternate` state (the value is `-tristatevalue`). A press, the space
//! key, the return key, and `<<Invoke>>` invoke the widget, as the class
//! bindings of `wish` on X11 do. The indicator is the part `::indicator`:
//! a box with a check mark, a circle with a dot, or, with the style class
//! `switch`, a track with a knob. A radiobutton with the style class
//! `segmented` has no indicator, and the radiobuttons of a row join into
//! one control. The part moves with the `transition` of the part.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const num = @import("../num.zig");
const geom = @import("../geom.zig");
const widget = @import("../widget.zig");
const options = @import("../options.zig");
const paint = @import("../paint.zig");
const path = @import("../path.zig");
const scene = @import("../scene.zig");
const anim = @import("../anim.zig");
const style_mod = @import("../style.zig");
const varlink = @import("../varlink.zig");
const label = @import("label.zig");
const button = @import("button.zig");
const App = @import("../app.zig").App;
const Spec = options.Spec;
const Widget = widget.Widget;
const Value = ztcl.Value;

const state_words = [_][]const u8{ "active", "disabled", "normal" };
const compound_words = [_][]const u8{ "bottom", "center", "left", "none", "right", "top" };

fn specList(comptime radio: bool) []const Spec {
    const head = [_]Spec{
        .{ .name = "-activebackground", .db_name = "activeBackground", .db_class = "Foreground", .type = .color, .default = "#ececec" },
        .{ .name = "-activeforeground", .db_name = "activeForeground", .db_class = "Background", .type = .color, .default = "#000000" },
        .{ .name = "-anchor", .db_name = "anchor", .db_class = "Anchor", .type = .anchor, .default = "center" },
        .{ .name = "-background", .db_name = "background", .db_class = "Background", .type = .color, .default = "#d9d9d9", .from_style = true, .style_prop = .background },
        .{ .name = "-bd", .type = .synonym, .target = "-borderwidth" },
        .{ .name = "-bg", .type = .synonym, .target = "-background" },
        .{ .name = "-bitmap", .db_name = "bitmap", .db_class = "Bitmap", .type = .string, .allow_empty = true },
        .{ .name = "-borderwidth", .db_name = "borderWidth", .db_class = "BorderWidth", .type = .pixels, .default = "0", .from_style = true, .style_prop = .border_width },
        .{ .name = "-command", .db_name = "command", .db_class = "Command", .type = .script, .allow_empty = true },
        .{ .name = "-compound", .db_name = "compound", .db_class = "Compound", .type = .word, .default = "none", .words = &compound_words },
        .{ .name = "-cursor", .db_name = "cursor", .db_class = "Cursor", .type = .string, .allow_empty = true },
        .{ .name = "-disabledforeground", .db_name = "disabledForeground", .db_class = "DisabledForeground", .type = .color, .default = "#a3a3a3" },
        .{ .name = "-fg", .type = .synonym, .target = "-foreground" },
        .{ .name = "-font", .db_name = "font", .db_class = "Font", .type = .font, .default = "TkDefaultFont" },
        .{ .name = "-foreground", .db_name = "foreground", .db_class = "Foreground", .type = .color, .default = "#000000", .from_style = true },
        .{ .name = "-height", .db_name = "height", .db_class = "Height", .type = .int, .default = "0" },
        .{ .name = "-highlightbackground", .db_name = "highlightBackground", .db_class = "HighlightBackground", .type = .color, .default = "#d9d9d9" },
        .{ .name = "-highlightcolor", .db_name = "highlightColor", .db_class = "HighlightColor", .type = .color, .default = "#000000" },
        .{ .name = "-highlightthickness", .db_name = "highlightThickness", .db_class = "HighlightThickness", .type = .pixels, .default = "1" },
        .{ .name = "-image", .db_name = "image", .db_class = "Image", .type = .string, .allow_empty = true },
        .{ .name = "-indicatoron", .db_name = "indicatorOn", .db_class = "IndicatorOn", .type = .boolean, .default = "1" },
        .{ .name = "-justify", .db_name = "justify", .db_class = "Justify", .type = .justify, .default = "center" },
        .{ .name = "-offrelief", .db_name = "offRelief", .db_class = "OffRelief", .type = .relief, .default = "raised" },
    };
    const check_values = [_]Spec{
        .{ .name = "-offvalue", .db_name = "offValue", .db_class = "Value", .type = .string, .default = "0", .allow_empty = true },
        .{ .name = "-onvalue", .db_name = "onValue", .db_class = "Value", .type = .string, .default = "1", .allow_empty = true },
    };
    const mid = [_]Spec{
        .{ .name = "-overrelief", .db_name = "overRelief", .db_class = "OverRelief", .type = .relief, .allow_empty = true },
        .{ .name = "-padx", .db_name = "padX", .db_class = "Pad", .type = .pixels, .default = "0" },
        .{ .name = "-pady", .db_name = "padY", .db_class = "Pad", .type = .pixels, .default = "0" },
        .{ .name = "-relief", .db_name = "relief", .db_class = "Relief", .type = .relief, .default = "flat", .from_style = true },
        .{ .name = "-selectcolor", .db_name = "selectColor", .db_class = "Background", .type = .color, .default = "#ffffff" },
        .{ .name = "-selectimage", .db_name = "selectImage", .db_class = "SelectImage", .type = .string, .allow_empty = true },
        .{ .name = "-state", .db_name = "state", .db_class = "State", .type = .state, .default = "normal", .words = &state_words },
        .{ .name = "-takefocus", .db_name = "takeFocus", .db_class = "TakeFocus", .type = .string, .allow_empty = true },
        .{ .name = "-text", .db_name = "text", .db_class = "Text", .type = .string, .allow_empty = true },
        .{ .name = "-textvariable", .db_name = "textVariable", .db_class = "Variable", .type = .variable, .allow_empty = true },
        .{ .name = "-tristateimage", .db_name = "tristateImage", .db_class = "TristateImage", .type = .string, .allow_empty = true },
        .{ .name = "-tristatevalue", .db_name = "tristateValue", .db_class = "TristateValue", .type = .string, .allow_empty = true },
        .{ .name = "-underline", .db_name = "underline", .db_class = "Underline", .type = .int, .default = "-1" },
    };
    const radio_value = [_]Spec{
        .{ .name = "-value", .db_name = "value", .db_class = "Value", .type = .string, .allow_empty = true },
    };
    const tail = [_]Spec{
        .{ .name = "-variable", .db_name = "variable", .db_class = "Variable", .type = .variable, .default = if (radio) "selectedButton" else "", .allow_empty = true },
        .{ .name = "-width", .db_name = "width", .db_class = "Width", .type = .int, .default = "0" },
        .{ .name = "-wraplength", .db_name = "wrapLength", .db_class = "WrapLength", .type = .pixels, .default = "0" },
    };
    if (radio) return &(head ++ mid ++ radio_value ++ tail);
    return &(head ++ check_values ++ mid ++ tail);
}

pub const check_specs = specList(false);
pub const radio_specs = specList(true);

pub const trace_command = "::ztk::priv::checkvar";

pub const check_class: widget.Class = .{
    .command = "checkbutton",
    .tk_class = "Checkbutton",
    .role = "check box",
    .focusable = true,
    .specs = check_specs,
    .init = init,
    .deinit = deinit,
    .teardown = teardown,
    .configured = configured,
    .created = created,
    .retrace = retrace,
    .trace_command = label.trace_command,
    .traced_var = label.tracedVar,
    .traced_var2 = selVar,
    .trace_command2 = trace_command,
    .variable_text = label.variableText,
    .measure = measure,
    .paint = paintCheck,
    .subcommand = subcommand,
    .bad_option_list = "cget, configure, deselect, flash, invoke, select, or toggle",
};

pub const radio_class: widget.Class = blk: {
    var c = check_class;
    c.command = "radiobutton";
    c.tk_class = "Radiobutton";
    c.role = "radio button";
    c.specs = radio_specs;
    c.bad_option_list = "cget, configure, deselect, flash, invoke, or select";
    break :blk c;
};

/// The data of a checkbutton or a radiobutton, after the label data.
const Ext = struct {
    /// The global name of `-variable`, owned.
    var_name: []u8 = &.{},
    ind: paint.PartAnim = .{},
};

fn ext(w: *const Widget) *Ext {
    return @ptrCast(@alignCast(label.dataOf(w).ext.?));
}

fn isRadio(w: *const Widget) bool {
    return std.mem.endsWith(u8, w.class.command, "radiobutton");
}

fn selVar(w: *const Widget) []const u8 {
    return ext(w).var_name;
}

fn init(w: *Widget) anyerror!void {
    try label.init(w);
    const e = try w.app.gpa.create(Ext);
    e.* = .{};
    label.dataOf(w).ext = e;
}

fn deinit(w: *Widget) void {
    const e = ext(w);
    w.app.gpa.free(e.var_name);
    w.app.gpa.destroy(e);
    label.deinit(w);
}

fn teardown(w: *Widget) void {
    const e = ext(w);
    varlink.remove(w, e.var_name, trace_command);
    w.app.gpa.free(e.var_name);
    e.var_name = &.{};
    label.teardown(w);
}

fn retrace(w: *Widget) void {
    label.retrace(w);
    const e = ext(w);
    varlink.remove(w, e.var_name, trace_command);
    varlink.add(w, e.var_name, trace_command) catch {};
}

fn optText(w: *const Widget, comptime name: []const u8) []const u8 {
    const s = options.get(w, name);
    if (s.set) return s.text;
    for (w.class.specs) |sp| if (std.mem.eql(u8, sp.name, name)) return sp.default;
    return "";
}

/// The value that selects the widget.
fn onValue(w: *const Widget) []const u8 {
    return if (isRadio(w)) optText(w, "-value") else optText(w, "-onvalue");
}

/// Reads the variable and sets the `selected` and `alternate` states.
fn sync(w: *Widget) void {
    const e = ext(w);
    const v = varlink.read(w, e.var_name);
    const sel = if (v) |x| std.mem.eql(u8, x, onValue(w)) else false;
    const tri = blk: {
        // A `ttk` widget shows `alternate` when the variable does not exist.
        const x = v orelse break :blk w.class.ttk;
        if (sel) break :blk false;
        if (!isRadio(w) and std.mem.eql(u8, x, optText(w, "-offvalue"))) break :blk false;
        break :blk std.mem.eql(u8, x, optText(w, "-tristatevalue"));
    };
    if (w.state.selected != sel or w.state.alternate != tri) {
        w.state.selected = sel;
        w.state.alternate = tri;
        w.invalidate(.{ .style = true, .measure = false, .layout = false, .paint = true });
    }
}

fn configured(w: *Widget, changed: []const usize) ztcl.Error!void {
    try label.configured(w, changed);
    if (w.life == .dead) return;
    var resync = false;
    for (changed) |i| {
        const name = w.class.specs[i].name;
        if (std.mem.eql(u8, name, "-variable")) {
            try linkVariable(w, w.opts[i].text);
            if (w.life == .dead) return;
        }
        if (std.mem.endsWith(u8, name, "value")) resync = true;
    }
    if (resync and w.alive()) sync(w);
}

/// Links the default variable when the create command gave none: the
/// name of the widget for a checkbutton, `selectedButton` for a radiobutton.
fn created(w: *Widget) ztcl.Error!void {
    if (ext(w).var_name.len > 0 or options.get(w, "-variable").set) return;
    // `cget -variable` gives the name, as in `wish`.
    const pair = [_]Value{ .{ .str = "-variable" }, .{ .str = if (isRadio(w)) (if (w.class.ttk) "::selectedButton" else "selectedButton") else try w.app.it.alloc().dupe(u8, if (w.class.ttk) w.path else w.name()) } };
    try options.apply(w, w.app.it, &pair);
}

fn linkVariable(w: *Widget, name: []const u8) ztcl.Error!void {
    const e = ext(w);
    const owned = try w.app.it.alloc().dupe(u8, name);
    try varlink.rename(w, &e.var_name, owned, trace_command);
    if (w.life == .dead or e.var_name.len == 0) return;
    // A variable that does not exist gets the off value: `-offvalue`, or empty for a radiobutton.
    // A `ttk` widget leaves the variable as it is.
    if (!w.class.ttk and varlink.read(w, e.var_name) == null) try varlink.write(w, e.var_name, if (isRadio(w)) "" else optText(w, "-offvalue"));
    if (w.life == .dead) return;
    sync(w);
}

/// Runs the -command after the variable changed. Returns the result of the script.
pub fn invoke(w: *Widget, it: *ztcl.Interp) ztcl.Error!Value {
    if (w.state.disabled) return Value.empty;
    const e = ext(w);
    const name = try it.alloc().dupe(u8, e.var_name);
    if (isRadio(w)) {
        try varlink.write(w, name, onValue(w));
    } else {
        const on = try it.alloc().dupe(u8, optText(w, "-onvalue"));
        const off = try it.alloc().dupe(u8, optText(w, "-offvalue"));
        try varlink.write(w, name, if (w.state.selected) off else on);
    }
    if (!w.alive()) return Value.empty;
    return button.invoke(w, it);
}

fn subcommand(w: *Widget, it: *ztcl.Interp, argv: []const Value) ztcl.Error!?Value {
    const sub = try it.str(argv[1]);
    const names = [_][]const u8{ "deselect", "flash", "invoke", "select", "toggle" };
    const which = for (names, 0..) |n, i| {
        if (std.mem.eql(u8, n, sub)) break i;
    } else return null;
    if (which == 4 and isRadio(w)) return null;
    if (argv.len != 2) return it.fail("wrong # args: should be \"{s} {s}\"", .{ w.path, sub });
    const e = ext(w);
    const name = try it.alloc().dupe(u8, e.var_name);
    switch (which) {
        0 => if (isRadio(w)) {
            if (w.state.selected) try varlink.write(w, name, "");
        } else try varlink.write(w, name, try it.alloc().dupe(u8, optText(w, "-offvalue"))),
        1 => {},
        2 => return try invoke(w, it),
        3 => try varlink.write(w, name, try it.alloc().dupe(u8, onValue(w))),
        4 => try varlink.write(w, name, try it.alloc().dupe(u8, if (w.state.selected) optText(w, "-offvalue") else optText(w, "-onvalue"))),
        else => unreachable,
    }
    return Value.empty;
}

fn indicatorOn(w: *const Widget) bool {
    const v = options.get(w, "-indicatoron").value;
    if (v == .boolean and !v.boolean) return false;
    return !hasClass(w, "segmented");
}

fn hasClass(w: *const Widget, name: []const u8) bool {
    return w.hasClass(name);
}

/// The size of the indicator in logical pixels: a square of about 1.25 em, or a switch track.
fn indicatorSize(w: *const Widget) geom.Size {
    const em = w.style.font.size;
    const side: i32 = num.pxRound(@as(f64, em) * 1.25);
    if (hasClass(w, "switch")) return .{ .w = num.pxRound(@as(f64, @floatFromInt(side)) * 1.8), .h = side };
    return .{ .w = side, .h = side };
}

fn gap(w: *const Widget) i32 {
    return num.pxRound(@as(f64, w.style.font.size) * 0.5);
}

fn measure(w: *Widget) geom.Size {
    var size = label.measure(w);
    if (!indicatorOn(w)) return size;
    const ind = indicatorSize(w);
    const has_text = label.text(w).len > 0;
    size.w = num.add(size.w, ind.w + if (has_text) gap(w) else 0);
    const ins = paint.insets(&w.style);
    size.h = @max(size.h, num.add(ind.h, ins.vertical()));
    return size;
}

/// The radii of a segmented radiobutton: round only at the ends of its row.
fn segmentRadii(w: *const Widget, st: *const style_mod.Style) [4]f32 {
    const parent = w.parent orelse return st.radius;
    var left_join = false;
    var right_join = false;
    for (parent.children.items) |c| {
        if (c == w or !c.mapped or c.class != w.class or !hasClass(c, "segmented")) continue;
        if (c.geom.y != w.geom.y) continue;
        if (c.geom.x + c.geom.w == w.geom.x) left_join = true;
        if (w.geom.x + w.geom.w == c.geom.x) right_join = true;
    }
    var r = st.radius;
    if (left_join) {
        r[0] = 0;
        r[3] = 0;
    }
    if (right_join) {
        r[1] = 0;
        r[2] = 0;
    }
    return r;
}

fn paintCheck(w: *Widget, b: *scene.Builder) anyerror!void {
    const app = w.app;
    var st = anim.shown(app, w).*;
    if (hasClass(w, "segmented")) st.radius = segmentRadii(w, &st);
    try paint.box(w, b, &st);
    var content = paint.contentRect(w, &st);
    const an = options.get(w, "-anchor").value;
    const ju = options.get(w, "-justify").value;
    var anchor: options.Anchor = if (an == .anchor) an.anchor else .center;
    if (indicatorOn(w)) {
        const ind = indicatorSize(w);
        const has_text = label.text(w).len > 0;
        const text_w = paint.textSize(app, label.text(w), st.font).w;
        const total = ind.w + if (has_text) gap(w) + text_w else 0;
        // The indicator and the text are one block at the anchor.
        var x0 = content.x;
        switch (anchor) {
            .n, .center, .s => x0 += @divTrunc(content.w - total, 2),
            .ne, .e, .se => x0 += content.w - total,
            else => {},
        }
        const iy = content.y + @divTrunc(content.h - ind.h, 2);
        try paintIndicator(w, b, .{ .x = x0, .y = iy, .w = ind.w, .h = ind.h });
        const shift = x0 + ind.w + gap(w) - content.x;
        content.x += shift;
        content.w = @max(content.w - shift, 0);
        anchor = switch (anchor) {
            .n, .center, .s, .ne, .e, .se => .w,
            else => anchor,
        };
    }
    try paint.label(w, b, content, label.text(w), &st, anchor, if (ju == .justify) ju.justify else .center);
}

fn paintIndicator(w: *Widget, b: *scene.Builder, r: geom.Rect) !void {
    const app = w.app;
    const ps = paint.partStyle(w, "indicator", &ext(w).ind);
    const st = ps.style;
    const fr: f32 = @floatFromInt(r.x);
    const fy: f32 = @floatFromInt(r.y);
    const fw: f32 = @floatFromInt(r.w);
    const fh: f32 = @floatFromInt(r.h);
    try paint.styledBox(b, r, &st);
    var shape: path.Shape = .{};
    defer shape.deinit(app.gpa);
    const sel = w.state.selected;
    // The motion of the mark: the progress of the part when it moved to this state.
    const p: f32 = if (ps.t >= 1) 1 else ps.t;
    if (hasClass(w, "switch")) {
        // The knob slides from the left end to the right end. A spring can go past the end.
        const pad = @max(fh * 0.125, 2);
        const d = fh - 2 * pad;
        const t = if (sel) p else 1 - p;
        const x = fr + pad + (fw - 2 * pad - d) * t;
        try b.shadow(.{ .x = num.pxRound(x), .y = num.pxRound(fy + pad + 1), .w = num.pxRound(d), .h = num.pxRound(d) }, .{ d / 2, d / 2, d / 2, d / 2 }, .{ .dy = 0.5, .blur = 1.5, .color = .{ .r = 0, .g = 0, .b = 0, .a = 60 } });
        try shape.ellipse(app.gpa, x + d / 2, fy + pad + d / 2, d / 2, d / 2);
        try paint.fillShape(b, &shape, st.color, st.opacity);
        return;
    }
    if (w.state.alternate and !isRadio(w)) {
        try shape.stroke(app.gpa, &.{ .{ .x = fr + fw * 0.28, .y = fy + fh / 2 }, .{ .x = fr + fw * 0.72, .y = fy + fh / 2 } }, @max(fw / 8, 1.5), true);
        try paint.fillShape(b, &shape, st.color, st.opacity);
        return;
    }
    if (!sel) return;
    if (isRadio(w)) {
        // The dot grows from the center.
        const rad = fw * 0.2 * p;
        if (rad <= 0) return;
        try shape.ellipse(app.gpa, fr + fw / 2, fy + fh / 2, rad, rad);
    } else {
        // The check mark draws from its first point to its last.
        const pts = [_]path.Pt{ .{ .x = fr + fw * 0.26, .y = fy + fh * 0.52 }, .{ .x = fr + fw * 0.43, .y = fy + fh * 0.69 }, .{ .x = fr + fw * 0.75, .y = fy + fh * 0.33 } };
        const l1 = dist(pts[0], pts[1]);
        const l2 = dist(pts[1], pts[2]);
        var len = (l1 + l2) * std.math.clamp(p, 0, 1);
        if (len <= 0) return;
        var line: [3]path.Pt = undefined;
        line[0] = pts[0];
        var n: usize = 1;
        if (len <= l1) {
            line[1] = towards(pts[0], pts[1], len / l1);
            n = 2;
        } else {
            len -= l1;
            line[1] = pts[1];
            line[2] = towards(pts[1], pts[2], @min(len / l2, 1));
            n = 3;
        }
        try shape.stroke(app.gpa, line[0..n], @max(fw / 8, 1.5), true);
    }
    try paint.fillShape(b, &shape, st.color, st.opacity);
}

fn dist(a: path.Pt, c: path.Pt) f32 {
    return @sqrt((c.x - a.x) * (c.x - a.x) + (c.y - a.y) * (c.y - a.y));
}

fn towards(a: path.Pt, c: path.Pt, t: f32) path.Pt {
    return .{ .x = a.x + (c.x - a.x) * t, .y = a.y + (c.y - a.y) * t };
}

/// `::ztk::priv::checkvar path`: the variable of a checkbutton or a radiobutton changed.
fn cmdCheckvar(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    app.enter();
    defer app.leave();
    if (argv.len < 2) return Value.empty;
    const w = app.find(try it.str(argv[1])) orelse return Value.empty;
    if (w.class.traced_var2 != selVar) return Value.empty;
    sync(w);
    return Value.empty;
}

/// `::ztk::priv::check invoke|enter|leave path`
fn cmdCheck(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    app.enter();
    defer app.leave();
    if (argv.len != 3) return it.wrongArgs("::ztk::priv::check action window");
    const w = app.find(try it.str(argv[2])) orelse return Value.empty;
    if (w.class.traced_var2 != selVar) return Value.empty;
    // Enter and Leave have no effect here: the dispatcher sets the hover state.
    if (std.mem.eql(u8, try it.str(argv[1]), "invoke")) _ = try invoke(w, it);
    return Value.empty;
}

pub fn register(app: *App) !void {
    const it = app.it;
    try it.register("checkbutton", widget.classCommand(&check_class));
    try app.classes.put(app.gpa, "checkbutton", &check_class);
    try it.register("radiobutton", widget.classCommand(&radio_class));
    try app.classes.put(app.gpa, "radiobutton", &radio_class);
    try it.register("ztk::priv::checkvar", cmdCheckvar);
    try it.register("ztk::priv::check", cmdCheck);
    // No loop variable: the script runs at the global level and must leave no variable.
    inline for (.{ "Checkbutton", "Radiobutton" }) |c| {
        _ = try it.eval(
            "bind " ++ c ++ " <Enter> {::ztk::priv::check enter %W}\n" ++
                "bind " ++ c ++ " <Leave> {::ztk::priv::check leave %W}\n" ++
                "bind " ++ c ++ " <Button-1> {::ztk::priv::check invoke %W}\n" ++
                "bind " ++ c ++ " <Key-Return> {::ztk::priv::check invoke %W}\n" ++
                "bind " ++ c ++ " <Key-space> {::ztk::priv::check invoke %W}\n" ++
                "bind " ++ c ++ " <<Invoke>> {::ztk::priv::check invoke %W}\n",
        );
    }
}
