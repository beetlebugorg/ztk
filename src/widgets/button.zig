//! The button class. It shares the data, the measure, and the paint of
//! the label. A press arms the button and gives it the focus. The release
//! runs the `-command` script when the pointer is still on the button.
//! The space key and the virtual event `<<Invoke>>` run it at once. The
//! class bindings are on the tag `Button`, and each one is a call of
//! `::ztk::priv::button`. The script runs at the global level.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const widget = @import("../widget.zig");
const options = @import("../options.zig");
const focus = @import("../focus.zig");
const label = @import("label.zig");
const App = @import("../app.zig").App;
const Spec = options.Spec;
const Widget = widget.Widget;
const Value = ztcl.Value;

const state_words = [_][]const u8{ "active", "disabled", "normal" };

/// A subset of the options of `wish`, in the order of `wish`.
pub const specs = [_]Spec{
    .{ .name = "-activebackground", .db_name = "activeBackground", .db_class = "Foreground", .type = .color, .default = "#ececec" },
    .{ .name = "-activeforeground", .db_name = "activeForeground", .db_class = "Background", .type = .color, .default = "#000000" },
    .{ .name = "-anchor", .db_name = "anchor", .db_class = "Anchor", .type = .anchor, .default = "center" },
    .{ .name = "-background", .db_name = "background", .db_class = "Background", .type = .color, .default = "#d9d9d9", .from_style = true, .style_prop = .background },
    .{ .name = "-bd", .type = .synonym, .target = "-borderwidth" },
    .{ .name = "-bg", .type = .synonym, .target = "-background" },
    .{ .name = "-borderwidth", .db_name = "borderWidth", .db_class = "BorderWidth", .type = .pixels, .default = "0", .from_style = true, .style_prop = .border_width },
    .{ .name = "-command", .db_name = "command", .db_class = "Command", .type = .script, .allow_empty = true },
    .{ .name = "-cursor", .db_name = "cursor", .db_class = "Cursor", .type = .string, .allow_empty = true },
    .{ .name = "-disabledforeground", .db_name = "disabledForeground", .db_class = "DisabledForeground", .type = .color, .default = "#a3a3a3" },
    .{ .name = "-fg", .type = .synonym, .target = "-foreground" },
    .{ .name = "-font", .db_name = "font", .db_class = "Font", .type = .font, .default = "TkDefaultFont" },
    .{ .name = "-foreground", .db_name = "foreground", .db_class = "Foreground", .type = .color, .default = "#000000", .from_style = true },
    .{ .name = "-height", .db_name = "height", .db_class = "Height", .type = .int, .default = "0" },
    .{ .name = "-justify", .db_name = "justify", .db_class = "Justify", .type = .justify, .default = "center" },
    .{ .name = "-padx", .db_name = "padX", .db_class = "Pad", .type = .pixels, .default = "0" },
    .{ .name = "-pady", .db_name = "padY", .db_class = "Pad", .type = .pixels, .default = "0" },
    .{ .name = "-relief", .db_name = "relief", .db_class = "Relief", .type = .relief, .default = "flat", .from_style = true },
    .{ .name = "-state", .db_name = "state", .db_class = "State", .type = .state, .default = "normal", .words = &state_words },
    .{ .name = "-takefocus", .db_name = "takeFocus", .db_class = "TakeFocus", .type = .string, .allow_empty = true },
    .{ .name = "-text", .db_name = "text", .db_class = "Text", .type = .string, .allow_empty = true },
    .{ .name = "-textvariable", .db_name = "textVariable", .db_class = "Variable", .type = .variable, .allow_empty = true },
    .{ .name = "-width", .db_name = "width", .db_class = "Width", .type = .int, .default = "0" },
};

pub const extra = [_][]const u8{ "flash", "invoke" };

pub const class: widget.Class = .{
    .command = "button",
    .tk_class = "Button",
    .role = "button",
    .focusable = true,
    .specs = &specs,
    .init = label.init,
    .deinit = label.deinit,
    .teardown = label.teardown,
    .configured = label.configured,
    .retrace = label.retrace,
    .trace_command = label.trace_command,
    .traced_var = label.tracedVar,
    .variable_text = label.variableText,
    .measure = label.measure,
    .paint = label.paintLabel,
    .subcommand = subcommand,
    .extra_subcommands = &extra,
};

fn subcommand(w: *Widget, it: *ztcl.Interp, argv: []const Value) ztcl.Error!?Value {
    const sub = try it.str(argv[1]);
    if (std.mem.eql(u8, sub, "invoke")) {
        if (argv.len != 2) return it.fail("wrong # args: should be \"{s} invoke\"", .{w.path});
        return try invoke(w, it);
    }
    if (std.mem.eql(u8, sub, "flash")) return it.fail("flash is not supported in this stage", .{});
    return null;
}

/// Runs the -command of the button. Returns the result of the script.
pub fn invoke(w: *Widget, it: *ztcl.Interp) ztcl.Error!Value {
    if (w.state.disabled) return Value.empty;
    const slot = options.get(w, "-command");
    if (!slot.set or slot.text.len == 0) return Value.empty;
    const app = w.app;
    // The script text stays valid if the script deletes the button.
    const script = try it.alloc().dupe(u8, slot.text);
    const saved_frame = it.frame;
    const saved_ns = it.ns;
    it.frame = &it.global;
    it.ns = "";
    app.enter();
    defer {
        app.leave();
        it.frame = saved_frame;
        it.ns = saved_ns;
    }
    return it.eval(script);
}

const Action = enum { enter, leave, down, up, key };

fn cmdButton(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    app.enter();
    defer app.leave();
    if (argv.len != 3) return it.wrongArgs("::ztk::priv::button action window");
    const act = std.meta.stringToEnum(Action, try it.str(argv[1])) orelse return it.fail("bad action \"{s}\"", .{try it.str(argv[1])});
    const w = app.find(try it.str(argv[2])) orelse return Value.empty;
    if (w.class.init != label.init) return Value.empty;
    const d = label.dataOf(w);
    switch (act) {
        // A button that was armed by a press and left by the pointer arms again when the pointer comes back.
        .enter => if (w.state.pressed and !w.state.disabled) {
            d.armed = true;
        },
        .leave => d.armed = false,
        .down => {
            if (w.state.disabled) return Value.empty;
            d.armed = true;
            if (focus.accepts(w)) focus.set(app, w);
        },
        .up => {
            const was = d.armed;
            d.armed = false;
            if (was and w.state.hover and !w.state.disabled) _ = try invoke(w, it);
        },
        .key => _ = try invoke(w, it),
    }
    return Value.empty;
}

pub fn register(app: *App) !void {
    const it = app.it;
    try it.register("button", widget.classCommand(&class));
    try app.classes.put(app.gpa, "button", &class);
    try it.register("ztk::priv::button", cmdButton);
    _ = try it.eval(
        \\bind Button <Enter> {::ztk::priv::button enter %W}
        \\bind Button <Leave> {::ztk::priv::button leave %W}
        \\bind Button <Button-1> {::ztk::priv::button down %W}
        \\bind Button <ButtonRelease-1> {::ztk::priv::button up %W}
        \\bind Button <Key-space> {::ztk::priv::button key %W}
        \\bind Button <<Invoke>> {::ztk::priv::button key %W}
    );
}
