//! `menubutton` and `ttk::menubutton`: a label that posts the menu of
//! `-menu`. The two classes share the data, the measure, and the paint
//! of the label. The paint adds a chevron in the right padding of the
//! theme (part `::indicator`).
//!
//! A press posts the menu next to the button, on the side of
//! `-direction`: `below`, `above`, `left`, `right`, or `flush` (over the
//! button). The button keeps the pointer until the release, so its
//! bindings send the motion and the release to the drawn menu
//! (`::ztk::priv::menu`): a drag from the button to an entry and a
//! release there invokes the entry. `space` and `Return` post the menu
//! with its first entry active.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const geom = @import("../base/geom.zig");
const widget = @import("../widget.zig");
const options = @import("../options.zig");
const paint = @import("../paint.zig");
const scene = @import("../scene.zig");
const path = @import("../path.zig");
const focus = @import("../focus.zig");
const label = @import("label.zig");
const menu = @import("menu.zig");
const drawn = @import("menudraw.zig");
const ttk = @import("../ttk/widgets.zig");
const App = @import("../app.zig").App;
const Spec = options.Spec;
const Widget = widget.Widget;
const Value = ztcl.Value;

const state_words = [_][]const u8{ "active", "disabled", "normal" };
const direction_words = [_][]const u8{ "above", "below", "flush", "left", "right" };
const compound_words = [_][]const u8{ "bottom", "center", "left", "none", "right", "top" };

/// The options of `wish` 8.6.16, in its order.
pub const specs = [_]Spec{
    .{ .name = "-activebackground", .db_name = "activeBackground", .db_class = "Foreground", .type = .color, .default = "#ececec" },
    .{ .name = "-activeforeground", .db_name = "activeForeground", .db_class = "Background", .type = .color, .default = "#000000" },
    .{ .name = "-anchor", .db_name = "anchor", .db_class = "Anchor", .type = .anchor, .default = "center" },
    .{ .name = "-background", .db_name = "background", .db_class = "Background", .type = .color, .default = "#d9d9d9", .from_style = true, .style_prop = .background },
    .{ .name = "-bd", .type = .synonym, .target = "-borderwidth" },
    .{ .name = "-bg", .type = .synonym, .target = "-background" },
    .{ .name = "-bitmap", .db_name = "bitmap", .db_class = "Bitmap", .type = .bitmap, .allow_empty = true },
    .{ .name = "-borderwidth", .db_name = "borderWidth", .db_class = "BorderWidth", .type = .pixels, .default = "0", .from_style = true, .style_prop = .border_width },
    .{ .name = "-cursor", .db_name = "cursor", .db_class = "Cursor", .type = .cursor, .allow_empty = true },
    .{ .name = "-direction", .db_name = "direction", .db_class = "Direction", .type = .word, .default = "below", .words = &direction_words },
    .{ .name = "-disabledforeground", .db_name = "disabledForeground", .db_class = "DisabledForeground", .type = .color, .default = "#a3a3a3" },
    .{ .name = "-fg", .type = .synonym, .target = "-foreground" },
    .{ .name = "-font", .db_name = "font", .db_class = "Font", .type = .font, .default = "TkDefaultFont" },
    .{ .name = "-foreground", .db_name = "foreground", .db_class = "Foreground", .type = .color, .default = "#000000", .from_style = true },
    .{ .name = "-height", .db_name = "height", .db_class = "Height", .type = .int, .default = "0" },
    .{ .name = "-highlightbackground", .db_name = "highlightBackground", .db_class = "HighlightBackground", .type = .color, .default = "#d9d9d9" },
    .{ .name = "-highlightcolor", .db_name = "highlightColor", .db_class = "HighlightColor", .type = .color, .default = "#000000" },
    .{ .name = "-highlightthickness", .db_name = "highlightThickness", .db_class = "HighlightThickness", .type = .pixels, .default = "0" },
    .{ .name = "-image", .db_name = "image", .db_class = "Image", .type = .image, .allow_empty = true },
    .{ .name = "-indicatoron", .db_name = "indicatorOn", .db_class = "IndicatorOn", .type = .boolean, .default = "0" },
    .{ .name = "-justify", .db_name = "justify", .db_class = "Justify", .type = .justify, .default = "center" },
    .{ .name = "-menu", .db_name = "menu", .db_class = "Menu", .type = .string, .allow_empty = true },
    .{ .name = "-padx", .db_name = "padX", .db_class = "Pad", .type = .pixels, .default = "0" },
    .{ .name = "-pady", .db_name = "padY", .db_class = "Pad", .type = .pixels, .default = "0" },
    .{ .name = "-relief", .db_name = "relief", .db_class = "Relief", .type = .relief, .default = "flat", .from_style = true },
    .{ .name = "-compound", .db_name = "compound", .db_class = "Compound", .type = .word, .default = "none", .words = &compound_words },
    .{ .name = "-state", .db_name = "state", .db_class = "State", .type = .state, .default = "normal", .words = &state_words },
    .{ .name = "-takefocus", .db_name = "takeFocus", .db_class = "TakeFocus", .type = .string, .default = "0" },
    .{ .name = "-text", .db_name = "text", .db_class = "Text", .type = .string, .allow_empty = true },
    .{ .name = "-textvariable", .db_name = "textVariable", .db_class = "Variable", .type = .variable, .allow_empty = true },
    .{ .name = "-underline", .db_name = "underline", .db_class = "Underline", .type = .int, .default = "-1" },
    .{ .name = "-width", .db_name = "width", .db_class = "Width", .type = .int, .default = "0" },
    .{ .name = "-wraplength", .db_name = "wrapLength", .db_class = "WrapLength", .type = .pixels, .default = "0" },
};

pub const class: widget.Class = .{
    .command = "menubutton",
    .tk_class = "Menubutton",
    .role = "button",
    .focusable = true,
    .specs = &specs,
    .init = label.init,
    .deinit = label.deinit,
    .teardown = teardown,
    .configured = label.configured,
    .retrace = label.retrace,
    .trace_command = label.trace_command,
    .traced_var = label.tracedVar,
    .variable_text = label.variableText,
    .measure = label.measure,
    .paint = paintButton,
};

const ttk_specs = options.withHidden(&([_]Spec{
    ttk.s("-menu", "menu", "Menu", .string, ""),
    .{ .name = "-direction", .db_name = "direction", .db_class = "Direction", .type = .word, .default = "below", .words = &direction_words },
    ttk.takefocus,
} ++ ttk.text_specs ++ ttk.tail), &specs);

const ttk_subs = [_][]const u8{ "configure", "cget", "instate", "state", "identify" };

pub const ttk_class = ttk.derive(class, "ttk::menubutton", "TMenubutton", ttk_specs, &ttk_subs, "label");

fn teardown(w: *Widget) void {
    if (w.app.menu_button == w) w.app.menu_button = null;
    label.teardown(w);
}

fn paintButton(w: *Widget, b: *scene.Builder) anyerror!void {
    try label.paintLabel(w, b);
    const app = w.app;
    const st = app.styles.compute(w, "indicator", &w.style, app.env);
    const ins = paint.insets(&w.style);
    if (ins.right < 14) return;
    const k: f32 = 3.5;
    const cx = @as(f32, @floatFromInt(w.geom.w - ins.right)) + @as(f32, @floatFromInt(ins.right)) / 2 - 2;
    const cy = @as(f32, @floatFromInt(w.geom.h)) / 2;
    const dy: f32 = if (menuPosted(w)) -k / 2 else k / 2;
    var sh: path.Shape = .{};
    defer sh.deinit(app.gpa);
    try sh.stroke(app.gpa, &.{ .{ .x = cx - k, .y = cy - dy }, .{ .x = cx, .y = cy + dy }, .{ .x = cx + k, .y = cy - dy } }, 1.5, true);
    try paint.fillShape(b, &sh, st.color, st.opacity);
}

fn menuOf(w: *Widget) ?*Widget {
    const name = options.get(w, "-menu").text;
    if (name.len == 0) return null;
    const m = w.app.find(name) orelse return null;
    if (m.class != &menu.class) return null;
    return m;
}

fn menuPosted(w: *Widget) bool {
    return w.app.menu_button == w;
}

/// The offset of a widget in the window of its toplevel.
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

/// Posts the menu on the side of `-direction`.
pub fn postMenu(w: *Widget) ztcl.Error!void {
    if (w.state.disabled) return;
    const m = menuOf(w) orelse return;
    const o = offsetIn(w);
    const sz = drawn.size(m);
    const dir = options.get(w, "-direction").text;
    const gap: i32 = 2;
    const at: geom.Point = if (std.mem.eql(u8, dir, "above"))
        .{ .x = o.x, .y = o.y - sz.h - gap }
    else if (std.mem.eql(u8, dir, "left"))
        .{ .x = o.x - sz.w - gap, .y = o.y }
    else if (std.mem.eql(u8, dir, "right"))
        .{ .x = o.x + w.geom.w + gap, .y = o.y }
    else if (std.mem.eql(u8, dir, "flush"))
        .{ .x = o.x, .y = o.y }
    else
        .{ .x = o.x, .y = o.y + w.geom.h + gap };
    try menu.post(m, at, -1);
    if (!w.alive()) return;
    if (w.app.menu_root == m) w.app.menu_button = w;
    w.invalidate(.{ .style = false, .measure = false, .layout = false, .paint = true });
}

const Action = enum { press, key };

fn cmdMenubutton(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    app.enter();
    defer app.leave();
    if (argv.len != 3) return it.wrongArgs("::ztk::priv::menubutton action window");
    const act = std.meta.stringToEnum(Action, try it.str(argv[1])) orelse return it.fail("bad action", .{});
    const w = app.find(try it.str(argv[2])) orelse return Value.empty;
    if (w.class.paint != class.paint) return Value.empty;
    if (w.state.disabled) return Value.empty;
    if (act == .press and focus.accepts(w)) focus.set(app, w);
    try postMenu(w);
    if (act == .key) {
        const m = menuOf(w) orelse return Value.empty;
        if (menu.data(m).posted) _ = try it.eval(try std.fmt.allocPrint(it.alloc(), "::ztk::priv::menu down {s}", .{m.path}));
    }
    return Value.empty;
}

pub fn register(app: *App) !void {
    const it = app.it;
    inline for (.{ &class, &ttk_class }) |c| {
        try it.register(c.command, widget.classCommand(c));
        try app.classes.put(app.gpa, c.command, c);
    }
    try it.register("ztk::priv::menubutton", cmdMenubutton);
    _ = try it.eval(
        \\foreach ztk_tag {Menubutton TMenubutton} {
        \\    bind $ztk_tag <Button-1> {::ztk::priv::menubutton press %W}
        \\    bind $ztk_tag <B1-Motion> {::ztk::priv::menu motion %W %X %Y}
        \\    bind $ztk_tag <ButtonRelease-1> {::ztk::priv::menu release %W %X %Y}
        \\    bind $ztk_tag <Key-space> {::ztk::priv::menubutton key %W}
        \\    bind $ztk_tag <Key-Return> {::ztk::priv::menubutton key %W}
        \\}
        \\unset ztk_tag
    );
}
