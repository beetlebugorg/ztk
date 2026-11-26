//! The simple `ttk` widgets: `ttk::button`, `ttk::checkbutton`,
//! `ttk::radiobutton`, `ttk::label`, `ttk::frame`, `ttk::labelframe`,
//! `ttk::entry`, `ttk::separator`, and `ttk::sizegrip`. Each one builds
//! on the code of its classic class. Its options are those of its manual
//! page in the order of `wish`, and the options of the classic class
//! follow, hidden (`options.withHidden`). The type of a widget for the
//! selectors is its style (`TButton`), and the rules of the classic
//! class match it too (`css_base`). Each class has `state`, `instate`,
//! and `identify`.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const geom = @import("../geom.zig");
const widget = @import("../widget.zig");
const options = @import("../options.zig");
const paint = @import("../paint.zig");
const anim = @import("../anim.zig");
const scene = @import("../scene.zig");
const ttk_style = @import("style.zig");
const label = @import("../widgets/label.zig");
const button = @import("../widgets/button.zig");
const check = @import("../widgets/check.zig");
const frame = @import("../widgets/frame.zig");
const labelframe = @import("../widgets/labelframe.zig");
const entry = @import("../widgets/entry.zig");
const App = @import("../app.zig").App;
const Spec = options.Spec;
const Widget = widget.Widget;
const Value = ztcl.Value;

const compound_words = [_][]const u8{ "none", "text", "image", "center", "top", "bottom", "left", "right" };
const default_words = [_][]const u8{ "normal", "active", "disabled" };
const orient_words = [_][]const u8{ "horizontal", "vertical" };

pub fn s(comptime name: []const u8, comptime db: []const u8, comptime cls: []const u8, comptime ty: options.Type, comptime def: []const u8) Spec {
    return .{ .name = name, .db_name = db, .db_class = cls, .type = ty, .default = def, .allow_empty = true };
}

pub const takefocus = s("-takefocus", "takeFocus", "TakeFocus", .string, "ttk::takefocus");
pub const takefocus_none = s("-takefocus", "takeFocus", "TakeFocus", .string, "");
pub const tail = [_]Spec{
    s("-cursor", "cursor", "Cursor", .string, ""),
    s("-style", "style", "Style", .string, ""),
    .{ .name = "-class", .type = .string, .allow_empty = true, .create_only = true },
};
pub const text_specs = [_]Spec{
    s("-text", "text", "Text", .string, ""),
    s("-textvariable", "textVariable", "Variable", .variable, ""),
    s("-underline", "underline", "Underline", .int, "-1"),
    s("-width", "width", "Width", .string, ""),
    s("-image", "image", "Image", .image, ""),
    .{ .name = "-compound", .db_name = "compound", .db_class = "Compound", .type = .word, .allow_empty = true, .words = &compound_words },
    s("-padding", "padding", "Pad", .string, ""),
    s("-state", "state", "State", .string, "normal"),
};

const button_specs = options.withHidden(&([_]Spec{
    s("-command", "command", "Command", .script, ""),
    .{ .name = "-default", .db_name = "default", .db_class = "Default", .type = .word, .default = "normal", .words = &default_words },
    takefocus,
} ++ text_specs ++ tail), &button.specs);

const check_specs = options.withHidden(&([_]Spec{
    s("-variable", "variable", "Variable", .variable, ""),
    s("-onvalue", "onValue", "OnValue", .string, "1"),
    s("-offvalue", "offValue", "OffValue", .string, "0"),
    s("-command", "command", "Command", .script, ""),
    takefocus,
} ++ text_specs ++ tail), check.check_specs);

const radio_specs = options.withHidden(&([_]Spec{
    s("-variable", "variable", "Variable", .variable, "::selectedButton"),
    s("-value", "Value", "Value", .string, "1"),
    s("-command", "command", "Command", .script, ""),
    takefocus,
} ++ text_specs ++ tail), check.radio_specs);

const label_specs = options.withHidden(&([_]Spec{
    s("-background", "frameColor", "FrameColor", .color, ""),
    s("-foreground", "textColor", "TextColor", .color, ""),
    s("-font", "font", "Font", .font, ""),
    s("-borderwidth", "borderWidth", "BorderWidth", .pixels, ""),
    s("-relief", "relief", "Relief", .relief, ""),
    s("-anchor", "anchor", "Anchor", .anchor, "w"),
    s("-justify", "justify", "Justify", .justify, "left"),
    s("-wraplength", "wrapLength", "WrapLength", .pixels, ""),
    takefocus_none,
} ++ text_specs ++ tail), &label.specs);

const frame_common = [_]Spec{
    s("-borderwidth", "borderWidth", "BorderWidth", .pixels, ""),
    s("-padding", "padding", "Pad", .string, ""),
    s("-relief", "relief", "Relief", .relief, ""),
    s("-width", "width", "Width", .pixels, "0"),
    s("-height", "height", "Height", .pixels, "0"),
    takefocus_none,
} ++ tail;

const frame_specs = options.withHidden(&frame_common, &frame.specs);

const labelframe_specs = options.withHidden(&([_]Spec{
    pickFrom(&labelframe.specs, "-labelanchor"),
    s("-text", "text", "Text", .string, ""),
    s("-underline", "underline", "Underline", .int, "-1"),
    s("-labelwidget", "labelWidget", "LabelWidget", .string, ""),
} ++ frame_common), &labelframe.specs);

pub fn pickFrom(comptime list: []const Spec, comptime name: []const u8) Spec {
    for (list) |e| if (std.mem.eql(u8, e.name, name)) return e;
    @compileError("no option " ++ name);
}

fn pick(comptime name: []const u8) Spec {
    return pickFrom(&entry.specs, name);
}

/// The options of `ttk::entry` that `ttk::combobox` and `ttk::spinbox` have too.
pub const entry_common = [_]Spec{
    pick("-exportselection"),          pick("-font"),                 pick("-invalidcommand"),
    pick("-justify"),                  pick("-show"),                 s("-state", "state", "State", .string, "normal"),
    pick("-textvariable"),             pick("-validate"),             pick("-validatecommand"),
    pick("-width"),                    pick("-xscrollcommand"),       s("-foreground", "textColor", "TextColor", .color, ""),
    s("-background", "windowColor", "WindowColor", .color, ""), takefocus,
} ++ tail;

const entry_specs = options.withHidden(&(entry_common ++ entry.addition_specs), &entry.specs);

const separator_specs = [_]Spec{
    .{ .name = "-orient", .db_name = "orient", .db_class = "Orient", .type = .word, .default = "horizontal", .words = &orient_words },
    takefocus_none,
} ++ tail;

const sizegrip_specs = [_]Spec{takefocus_none} ++ tail;

const button_subs = [_][]const u8{ "configure", "cget", "invoke", "instate", "state", "identify" };
const label_subs = [_][]const u8{ "configure", "cget", "instate", "state", "identify" };
const plain_subs = [_][]const u8{ "configure", "cget", "identify", "instate", "state" };
const entry_subs = [_][]const u8{ "bbox", "cget", "configure", "delete", "get", "icursor", "identify", "index", "insert", "instate", "selection", "state", "validate", "xview" };

/// A `ttk` class from a classic class. With an empty `elem`, `identify`
/// goes to the subcommand of the classic class, with no `element` word.
/// With `elem` "*", the subcommand of the classic class gets all the words.
pub fn derive(comptime base: widget.Class, comptime cmd: []const u8, comptime tk: []const u8, comptime specs: []const Spec, comptime subs: []const []const u8, comptime elem: []const u8) widget.Class {
    var c = base;
    c.command = cmd;
    c.tk_class = tk;
    c.css_base = base.tk_class;
    c.ttk = true;
    c.specs = specs;
    c.configured = Wrap(base.configured).configured;
    c.created = Created(base.created, if (std.mem.eql(u8, tk, "TEntry")) "xterm" else if (std.mem.eql(u8, tk, "TSizegrip")) "bottom_right_corner" else "").created;
    c.subcommand = Subs(base.subcommand, subs, elem).run;
    c.extra_subcommands = &.{};
    c.bad_option_list = "";
    return c;
}

pub const button_class = derive(button.class, "ttk::button", "TButton", button_specs, &button_subs, "label");
pub const check_class = derive(check.check_class, "ttk::checkbutton", "TCheckbutton", check_specs, &button_subs, "label");
pub const radio_class = derive(check.radio_class, "ttk::radiobutton", "TRadiobutton", radio_specs, &button_subs, "label");
pub const label_class = derive(label.class, "ttk::label", "TLabel", label_specs, &label_subs, "label");
pub const frame_class = derive(frame.class, "ttk::frame", "TFrame", frame_specs, &label_subs, "border");
pub const labelframe_class = derive(labelframe.class, "ttk::labelframe", "TLabelframe", labelframe_specs, &label_subs, "border");
pub const entry_class = derive(entry.class, "ttk::entry", "TEntry", entry_specs, &entry_subs, "textarea");
pub const separator_class = derive(.{ .command = "", .tk_class = "", .role = "separator", .measure = measureSeparator, .paint = paintBox }, "ttk::separator", "TSeparator", &separator_specs, &plain_subs, "separator");
pub const sizegrip_class = derive(.{ .command = "", .tk_class = "", .role = "", .measure = measureSizegrip, .paint = paintSizegrip }, "ttk::sizegrip", "TSizegrip", &sizegrip_specs, &plain_subs, "sizegrip");

/// The `configured` of a `ttk` class: the one of the classic class, then
/// `-class`, `-state`, and `-style`.
fn Wrap(comptime base: ?*const fn (w: *Widget, changed: []const usize) ztcl.Error!void) type {
    return struct {
        fn configured(w: *Widget, changed: []const usize) ztcl.Error!void {
            if (base) |f| try f(w, changed);
            if (w.life == .dead) return;
            for (changed) |i| {
                const name = w.class.specs[i].name;
                const slot = w.opts[i];
                if (std.mem.eql(u8, name, "-class")) {
                    if (slot.text.len > 0) w.tk_class = slot.text;
                } else if (std.mem.eql(u8, name, "-state") and w.class.specs[i].type == .string) {
                    // The compatibility option of `ttk`: disabled and readonly set the flag, other words clear it.
                    w.state.disabled = std.mem.eql(u8, slot.text, "disabled");
                    w.state.readonly = std.mem.eql(u8, slot.text, "readonly");
                    w.state.hover = std.mem.eql(u8, slot.text, "active") or w.app.dispatch.hover == w;
                }
            }
        }
    };
}

/// The `created` of a `ttk` class: the one of the classic class, then the
/// cursor that `wish` gives the widget.
fn Created(comptime base: ?*const fn (w: *Widget) ztcl.Error!void, comptime cursor: []const u8) type {
    return struct {
        fn created(w: *Widget) ztcl.Error!void {
            if (base) |f| try f(w);
            if (cursor.len == 0 or w.life == .dead or options.get(w, "-cursor").set) return;
            const pair = [_]Value{ .{ .str = "-cursor" }, .{ .str = cursor } };
            try options.apply(w, w.app.it, &pair);
        }
    };
}

/// The state bits of a widget in the order of `ttk_style.state_names`.
pub fn bits(w: *const Widget) u16 {
    const st = w.state;
    var b: u16 = 0;
    const flags = [_]bool{ st.hover, st.disabled, st.focus, st.pressed, st.selected, st.background, st.alternate, st.invalid, st.readonly, st.hover };
    for (flags, 0..) |f, i| if (f) {
        b |= @as(u16, 1) << @intCast(i);
    };
    return b | (@as(u16, w.ttk_user) << 10);
}

fn setBits(w: *Widget, b: u16) void {
    const on = struct {
        fn f(x: u16, i: u4) bool {
            return x & (@as(u16, 1) << i) != 0;
        }
    }.f;
    w.state.hover = on(b, 0) or on(b, 9);
    w.state.disabled = on(b, 1);
    w.state.focus = on(b, 2);
    w.state.pressed = on(b, 3);
    w.state.selected = on(b, 4);
    w.state.background = on(b, 5);
    w.state.alternate = on(b, 6);
    w.state.invalid = on(b, 7);
    w.state.readonly = on(b, 8);
    w.ttk_user = @intCast(b >> 10);
}

/// `path state ?spec?` and `path instate spec ?script?`.
fn stateCmd(w: *Widget, it: *ztcl.Interp, argv: []const Value, instate: bool) ztcl.Error!Value {
    const a = it.alloc();
    const now = bits(w);
    if (instate) {
        if (argv.len < 3 or argv.len > 4) return it.fail("wrong # args: should be \"{s} instate state-spec ?script?\"", .{w.path});
        const sp = try ttk_style.parseSpec(it, argv[2]);
        const ok = ttk_style.specMatches(sp, now);
        if (argv.len == 3) return .{ .int = @intFromBool(ok) };
        if (!ok) return Value.empty;
        return it.eval(try it.str(argv[3]));
    }
    if (argv.len > 3) return it.fail("wrong # args: should be \"{s} state state-spec\"", .{w.path});
    var out: std.ArrayListUnmanaged(Value) = .empty;
    if (argv.len == 2) {
        for (ttk_style.state_names, 0..) |n, i| if (now & (@as(u16, 1) << @intCast(i)) != 0) try out.append(a, .{ .str = n });
        return ztcl.value.newList(a, out.items);
    }
    const sp = try ttk_style.parseSpec(it, argv[2]);
    var next = (now | sp.on) & ~sp.off;
    // `active` and `hover` share one flag.
    if (next & 1 != 0 or next & (1 << 9) != 0) {
        if ((sp.off & 1 != 0) or (sp.off & (1 << 9) != 0)) next &= ~@as(u16, 1 | (1 << 9)) else next |= 1 | (1 << 9);
    }
    for (ttk_style.state_names, 0..) |n, i| {
        const bit = @as(u16, 1) << @intCast(i);
        if ((sp.on | sp.off) & bit == 0 or (now & bit) == (next & bit)) continue;
        try out.append(a, .{ .str = if (next & bit != 0) try std.fmt.allocPrint(a, "!{s}", .{n}) else n });
    }
    setBits(w, next);
    w.invalidate(.{ .style = true, .measure = false, .layout = false, .paint = true });
    return ztcl.value.newList(a, out.items);
}

/// `path identify ?element? x y`: the element at a point, from the box of the widget.
fn identify(w: *Widget, it: *ztcl.Interp, argv: []const Value, elem: []const u8) ztcl.Error!Value {
    if (argv.len != 4 and argv.len != 5) return it.fail("wrong # args: should be \"{s} identify ?what? x y\"", .{w.path});
    if (argv.len == 5 and !std.mem.eql(u8, try it.str(argv[2]), "element")) return it.fail("bad option \"{s}\": must be element", .{try it.str(argv[2])});
    const x = try it.int(argv[argv.len - 2]);
    const y = try it.int(argv[argv.len - 1]);
    if (x < 0 or y < 0 or x >= w.geom.w or y >= w.geom.h) return Value.empty;
    w.app.ensureStyle(w);
    const st = &w.style;
    const bw: i64 = @intFromFloat(@ceil(st.border_width[0]));
    if (bw > 0 and (x < bw or y < bw or x >= w.geom.w - bw or y >= w.geom.h - bw)) return .{ .str = "border" };
    const c = paint.contentRect(w, st);
    if (x < c.x or y < c.y or x >= c.x + c.w or y >= c.y + c.h) return .{ .str = "padding" };
    return .{ .str = elem };
}

fn Subs(comptime base: ?*const fn (w: *Widget, it: *ztcl.Interp, argv: []const Value) ztcl.Error!?Value, comptime subs: []const []const u8, comptime elem: []const u8) type {
    return struct {
        fn run(w: *Widget, it: *ztcl.Interp, argv: []const Value) ztcl.Error!?Value {
            const i = try ttk_style.pick(it, try it.str(argv[1]), subs, "bad command");
            const name = subs[i];
            if (std.mem.eql(u8, name, "state")) return try stateCmd(w, it, argv, false);
            if (std.mem.eql(u8, name, "instate")) return try stateCmd(w, it, argv, true);
            if (std.mem.eql(u8, name, "identify") and comptime !std.mem.eql(u8, elem, "*")) {
                if (elem.len > 0) return try identify(w, it, argv, elem);
                if (argv.len != 4 and argv.len != 5) return it.fail("wrong # args: should be \"{s} identify ?what? x y\"", .{w.path});
                if (argv.len == 5 and !std.mem.eql(u8, try it.str(argv[2]), "element")) return it.fail("bad option \"{s}\": must be element", .{try it.str(argv[2])});
                const f = base orelse return Value.empty;
                return try f(w, it, &.{ argv[0], .{ .str = "identify" }, argv[argv.len - 2], argv[argv.len - 1] });
            }
            if (std.mem.eql(u8, name, "configure")) return try options.configure(w, it, argv[2..]);
            if (std.mem.eql(u8, name, "cget")) {
                if (argv.len != 3) return it.fail("wrong # args: should be \"{s} cget option\"", .{w.path});
                return try options.cget(w, it, argv[2]);
            }
            const f = base orelse return null;
            const copy = try it.alloc().dupe(Value, argv);
            copy[1] = .{ .str = name };
            return try f(w, it, copy);
        }
    };
}

fn paintBox(w: *Widget, b: *scene.Builder) anyerror!void {
    try paint.box(w, b, anim.shown(w.app, w));
}

/// A separator is one logical pixel thick, or the width of its border.
fn measureSeparator(w: *Widget) geom.Size {
    w.app.ensureStyle(w);
    const ins = paint.insets(&w.style);
    const line: i32 = if (ins.vertical() > 0) 0 else 1;
    return .{ .w = ins.horizontal() + line, .h = ins.vertical() + line };
}

fn measureSizegrip(w: *Widget) geom.Size {
    w.app.ensureStyle(w);
    const ins = paint.insets(&w.style);
    return .{ .w = ins.horizontal() + 16, .h = ins.vertical() + 16 };
}

/// Three rows of dots in the bottom right corner, in the text color.
fn paintSizegrip(w: *Widget, b: *scene.Builder) anyerror!void {
    const st = anim.shown(w.app, w);
    try paint.box(w, b, st);
    const r = paint.contentRect(w, st);
    var row: i32 = 0;
    while (row < 3) : (row += 1) {
        var col: i32 = 0;
        while (col <= row) : (col += 1) {
            const x = r.x + r.w - 4 - col * 5;
            const y = r.y + r.h - 4 - (row - col) * 5;
            try b.box(.{ .x = x, .y = y, .w = 2, .h = 2 }, .{ .fill = st.color, .radii = .{ 1, 1, 1, 1 }, .opacity = st.opacity });
        }
    }
}

pub fn register(app: *App) !void {
    const it = app.it;
    _ = try it.eval("namespace eval ::ttk {}");
    const list = [_]*const widget.Class{ &button_class, &check_class, &radio_class, &label_class, &frame_class, &labelframe_class, &entry_class, &separator_class, &sizegrip_class };
    inline for (list) |c| {
        try it.register(c.command, widget.classCommand(c));
        try app.classes.put(app.gpa, c.command, c);
    }
    try it.register("ttk::style", ttk_style.command);
    try ttk_style.setup(app);
    try entry.bindClass(app, "TEntry");
    // The class bindings of the classic classes, and the size grip.
    _ = try it.eval(
        \\foreach {ttk_class tk_class} {TButton Button TCheckbutton Checkbutton TRadiobutton Radiobutton} {
        \\    foreach ttk_event [bind $tk_class] {bind $ttk_class $ttk_event [bind $tk_class $ttk_event]}
        \\}
        \\unset ttk_class tk_class ttk_event
        \\proc ::ttk::takefocus {w} {expr {[$w instate !disabled] && [winfo viewable $w]}}
        \\proc ::ztk::priv::grip {w x y} {
        \\    variable grip
        \\    set top [winfo toplevel $w]
        \\    if {$x eq "press"} {set grip [list $y [winfo width $top] [winfo height $top]]; return}
        \\    if {![info exists grip]} return
        \\    lassign $grip p w0 h0
        \\    lassign $p x0 y0
        \\    wm geometry $top [expr {max(1, $w0 + $x - $x0)}]x[expr {max(1, $h0 + $y - $y0)}]
        \\}
        \\bind TSizegrip <Button-1> {::ztk::priv::grip %W press [list %X %Y]}
        \\bind TSizegrip <B1-Motion> {::ztk::priv::grip %W %X %Y}
        \\bind TSizegrip <ButtonRelease-1> {unset -nocomplain ::ztk::priv::grip}
    );
}
