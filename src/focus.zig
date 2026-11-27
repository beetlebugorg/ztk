//! The keyboard focus. The App has one `Focus` for `.`. `current` is a
//! pointer, so a key event does not search the tree. `set` sends
//! FocusOut and FocusIn and changes the `focus` state bits. The window
//! that loses the keyboard keeps `current`, clears the `focus` bit, and
//! gets the `background` bit on the toplevel. Traversal follows the
//! depth-first order of the tree and stops at the widgets that accept
//! the focus. `Tab` and `Shift-Tab` call `::ztk::priv::focus_move`
//! through bindings on the tag `all`.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const bind = @import("bind.zig");
const options = @import("options.zig");
const widget_mod = @import("widget.zig");
const App = @import("app.zig").App;
const Widget = widget_mod.Widget;
const Value = ztcl.Value;

pub const Focus = struct {
    /// The widget with the focus in the toplevel, or null.
    current: ?*Widget = null,
    /// True when the platform window has the keyboard.
    window_focused: bool = true,
};

fn markStyle(w: *Widget) void {
    w.invalidate(.{ .style = true, .measure = false, .layout = false, .paint = true });
}

fn send(app: *App, t: bind.EventType, w: *Widget) void {
    var ev: bind.WidgetEvent = .{ .type = t, .widget = w, .serial = 0 };
    bind.deliver(app, &ev);
}

/// Gives the focus to a widget. Sends FocusOut and FocusIn and changes
/// the state bits. Without the keyboard it only stores the widget.
pub fn set(app: *App, w: ?*Widget) void {
    const f = &app.focus;
    if (f.current == w) return;
    const old = f.current;
    f.current = w;
    if (app.dbg.trace.mask != 0) @import("debug.zig").focus(app, old, w);
    if (!f.window_focused) return;
    if (old) |o| {
        if (o.alive()) {
            o.state.focus = false;
            markStyle(o);
            send(app, .focus_out, o);
        }
    }
    if (w) |n| {
        if (n.alive() and f.current == n) {
            n.state.focus = true;
            markStyle(n);
            send(app, .focus_in, n);
        }
    }
}

/// The window gains or loses the keyboard.
pub fn windowFocus(app: *App, focused: bool) void {
    const f = &app.focus;
    if (f.window_focused == focused) return;
    f.window_focused = focused;
    const root = app.root orelse return;
    root.state.background = !focused;
    markStyle(root);
    const target = f.current orelse root;
    if (focused) {
        if (f.current) |c| {
            c.state.focus = true;
            markStyle(c);
        }
        send(app, .focus_in, target);
    } else {
        if (f.current) |c| {
            c.state.focus = false;
            markStyle(c);
        }
        send(app, .focus_out, target);
    }
}

fn viewable(w: *const Widget) bool {
    var x: ?*const Widget = w;
    while (x) |p| : (x = p.parent) if (!p.mapped) return false;
    return true;
}

/// True when a traversal can stop at the widget.
pub fn accepts(w: *const Widget) bool {
    // A toplevel has -takefocus 0 by default, so a traversal passes it.
    if (!viewable(w) or w.state.disabled or w.isToplevel()) return false;
    for (w.class.specs, w.opts) |sp, slot| {
        if (!std.mem.eql(u8, sp.name, "-takefocus")) continue;
        const text = if (slot.set) slot.text else sp.default;
        if (std.mem.eql(u8, text, "1")) return true;
        if (std.mem.eql(u8, text, "0")) return false;
        break;
    }
    return w.class.focusable or w.app.bindings.hasKeyBinding(w.path);
}

/// The next widget in depth-first order.
fn successor(w: *Widget) *Widget {
    if (w.children.items.len > 0) return w.children.items[0];
    var x = w;
    while (true) {
        const p = x.parent orelse return x;
        for (p.children.items, 0..) |c, i| if (c == x) {
            if (i + 1 < p.children.items.len) return p.children.items[i + 1];
            break;
        };
        x = p;
    }
}

fn lastDescendant(w: *Widget) *Widget {
    var x = w;
    while (x.children.items.len > 0) x = x.children.items[x.children.items.len - 1];
    return x;
}

fn predecessor(w: *Widget) *Widget {
    const p = w.parent orelse return lastDescendant(w);
    for (p.children.items, 0..) |c, i| if (c == w) {
        if (i > 0) return lastDescendant(p.children.items[i - 1]);
        return p;
    };
    return p;
}

/// The next widget in the traversal order that accepts the focus.
pub fn next(app: *App, w: *Widget) *Widget {
    _ = app;
    var x = successor(w);
    while (x != w) : (x = successor(x)) if (accepts(x)) return x;
    return w;
}

pub fn prev(app: *App, w: *Widget) *Widget {
    _ = app;
    var x = predecessor(w);
    while (x != w) : (x = predecessor(x)) if (accepts(x)) return x;
    return w;
}

/// Clears the focus of a widget that is deleted. No event runs.
pub fn forget(app: *App, w: *Widget) void {
    if (app.focus.current == w) app.focus.current = null;
}

const focus_opts = "-displayof, -force, or -lastfor";

/// `focus ?-option value ...?`
pub fn cmdFocus(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    app.enter();
    defer app.leave();
    const a = it.alloc();
    if (argv.len == 1) {
        const c = app.focus.current orelse return Value.empty;
        if (!app.focus.window_focused) return Value.empty;
        return .{ .str = try a.dupe(u8, c.path) };
    }
    const first = try it.str(argv[1]);
    if (first.len > 0 and first[0] == '-') {
        const which: u8 = if (std.mem.eql(u8, first, "-displayof")) 0 else if (std.mem.eql(u8, first, "-force")) 1 else if (std.mem.eql(u8, first, "-lastfor")) 2 else return it.fail("bad option \"{s}\": must be " ++ focus_opts, .{first});
        if (argv.len != 3) return it.fail("wrong # args: should be \"focus {s} window\"", .{first});
        const path = try it.str(argv[2]);
        const w = app.lookup(path) orelse return it.fail("bad window path name \"{s}\"", .{path});
        switch (which) {
            0 => {
                const c = app.focus.current orelse return Value.empty;
                if (!app.focus.window_focused) return Value.empty;
                return .{ .str = try a.dupe(u8, c.path) };
            },
            1 => {
                if (w.alive()) set(app, w);
                return Value.empty;
            },
            else => {
                const top = w.toplevel();
                const c = app.focus.current orelse top;
                return .{ .str = try a.dupe(u8, c.path) };
            },
        }
    }
    if (argv.len != 2) return it.fail("bad option \"{s}\": must be " ++ focus_opts, .{first});
    if (first.len == 0) return Value.empty;
    const w = app.lookup(first) orelse return it.fail("bad window path name \"{s}\"", .{first});
    // `wish` ignores a focus request for a widget that is being deleted.
    if (w.alive()) set(app, w);
    return Value.empty;
}

fn cmdMove(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    app.enter();
    defer app.leave();
    if (argv.len != 3) return it.wrongArgs("::ztk::priv::focus_move window next|prev");
    const w = app.find(try it.str(argv[1])) orelse return Value.empty;
    const dir = try it.str(argv[2]);
    const target = if (std.mem.eql(u8, dir, "next")) next(app, w) else prev(app, w);
    set(app, target);
    return Value.empty;
}

/// `::ztk::priv::focus_ok window`: 1 when a traversal can stop at it.
fn cmdFocusOk(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    if (argv.len != 2) return it.wrongArgs("::ztk::priv::focus_ok window");
    const w = app.find(try it.str(argv[1])) orelse return .{ .int = 0 };
    return .{ .int = @intFromBool(accepts(w)) };
}

/// `tk_focusFollowsMouse`: from now on the focus follows the pointer.
fn cmdFollows(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    if (argv.len != 1) return it.wrongArgs("tk_focusFollowsMouse");
    _ = try it.eval("bind all <Enter> {::ztk::priv::focus_follow %W}");
    return Value.empty;
}

/// `::ztk::priv::focus_follow path`: the pointer entered a widget.
fn cmdFollow(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    app.enter();
    defer app.leave();
    if (argv.len != 2) return Value.empty;
    const w = app.find(try it.str(argv[1])) orelse return Value.empty;
    if (accepts(w)) set(app, w);
    return Value.empty;
}

pub fn register(app: *App) !void {
    const it = app.it;
    try it.register("tk_focusFollowsMouse", cmdFollows);
    try it.register("ztk::priv::focus_follow", cmdFollow);
    try it.register("focus", cmdFocus);
    // tk_focusNext and tk_focusPrev are Tcl in library/tk.tcl, as in Tk:
    // an app such as Tablelist reads their bodies. They ask this command
    // whether a traversal can stop at a widget.
    try it.register("ztk::priv::focus_ok", cmdFocusOk);
    try it.register("ztk::priv::focus_move", cmdMove);
    _ = try it.eval("bind all <Key-Tab> {::ztk::priv::focus_move %W next}; bind all <Shift-Key-Tab> {::ztk::priv::focus_move %W prev}; bind all <Key-ISO_Left_Tab> {::ztk::priv::focus_move %W prev}");
}
