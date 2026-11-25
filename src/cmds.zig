//! The registration of all commands of ztk, and the commands `destroy`
//! and `winfo`. Only this file and the widget constructors call `register`.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const app_mod = @import("app.zig");
const widget = @import("widget.zig");
const frame = @import("widgets/frame.zig");
const loop = @import("loop.zig");
const style = @import("style.zig");
const toplevel = @import("widgets/toplevel.zig");
const grid = @import("grid.zig");
const label = @import("widgets/label.zig");
const button = @import("widgets/button.zig");
const entry = @import("widgets/entry.zig");
const wm = @import("wm.zig");
const bind = @import("bind.zig");
const dispatch = @import("dispatch.zig");
const focus = @import("focus.zig");
const App = app_mod.App;
const Value = ztcl.Value;

pub fn register(app: *App) !void {
    const it = app.it;
    _ = try it.eval("namespace eval ::ztk::priv {}");
    it.user = app;
    try it.register("frame", widget.classCommand(&frame.class));
    try app.classes.put(app.gpa, "frame", &frame.class);
    try loop.register(app);
    try it.register("ztk::style", style.cmdStyle);
    try it.register("ztk::class", style.cmdClass);
    try it.register("ztk::animate", @import("animate.zig").cmdAnimate);
    try it.register("ztk::clock", @import("animate.zig").cmdClock);
    try it.register("destroy", cmdDestroy);
    try it.register("exit", cmdExit);
    try it.register("winfo", cmdWinfo);
    try it.register("grid", grid.command);
    try it.register("pack", @import("pack.zig").command);
    try it.register("place", @import("place.zig").command);
    try it.register("label", widget.classCommand(&label.class));
    try app.classes.put(app.gpa, "label", &label.class);
    try it.register("ztk::priv::textvar", label.cmdTextvar);
    try it.register("wm", wm.cmdWm);
    try it.register("bind", bind.cmdBind);
    try it.register("bindtags", bind.cmdBindtags);
    try it.register("event", dispatch.cmdEvent);
    try focus.register(app);
    try button.register(app);
    try @import("widgets/check.zig").register(app);
    try entry.register(app);
    try it.register("tk", wm.cmdTk);
    app.root = try widget.makeNode(app, &toplevel.class, ".", null);
    const win = try app.platform.createWindow(.{});
    win.user = app.root;
    app.window = win;
    app.root.?.data = win;
    app.root.?.mapped = true;
    app.root.?.geom = .{ .w = win.size.w, .h = win.size.h };
}

/// `exit ?code?`: ends the program through the hook that the program gave.
fn cmdExit(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    if (argv.len > 2) return it.wrongArgs("exit ?returnCode?");
    const code: i64 = if (argv.len == 2) try it.int(argv[1]) else 0;
    const f = app.on_exit orelse return it.fail("exit is not available here", .{});
    f(@intCast(std.math.clamp(code, 0, 255)));
}

fn cmdDestroy(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    app.enter();
    defer app.leave();
    for (argv[1..]) |a| {
        if (app.find(try it.str(a))) |w| widget.destroy(w);
    }
    return Value.empty;
}

const winfo_options = "cells, children, class, colormapfull, depth, geometry, height, id, ismapped, manager, name, parent, pointerx, pointery, pointerxy, reqheight, reqwidth, rootx, rooty, screen, screencells, screendepth, screenheight, screenwidth, screenmmheight, screenmmwidth, screenvisual, server, toplevel, viewable, visual, visualid, vrootheight, vrootwidth, vrootx, vrooty, width, x, y, atom, atomname, containing, interps, pathname, exists, fpixels, pixels, rgb, or visualsavailable";

const Winfo = enum { children, exists, parent, class, name, toplevel, manager, x, y, width, height, reqwidth, reqheight, rootx, rooty, ismapped, viewable, geometry };

fn cmdWinfo(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    app.enter();
    defer app.leave();
    if (argv.len < 2) return it.wrongArgs("winfo option ?arg?");
    const sub = try it.str(argv[1]);
    const which = std.meta.stringToEnum(Winfo, sub) orelse
        return it.fail("bad option \"{s}\": must be " ++ winfo_options, .{sub});
    if (argv.len != 3) return it.fail("wrong # args: should be \"winfo {s} window\"", .{sub});
    const path = try it.str(argv[2]);
    if (which == .exists) return .{ .int = @intFromBool(app.find(path) != null) };
    // `wish` answers for a widget that is being deleted, and `exists` gives 0.
    const w = app.lookup(path) orelse return it.fail("bad window path name \"{s}\"", .{path});
    const a = it.alloc();
    switch (which) {
        .exists => unreachable,
        .children => {
            const items = try a.alloc(Value, w.children.items.len);
            for (w.children.items, items) |c, *slot| slot.* = .{ .str = try a.dupe(u8, c.path) };
            return ztcl.value.wrapList(a, items);
        },
        .parent => return if (w.parent) |p| .{ .str = try a.dupe(u8, p.path) } else Value.empty,
        .class => return .{ .str = try a.dupe(u8, w.tk_class) },
        .name => return .{ .str = try a.dupe(u8, if (w.parent == null) app.app_name else w.name()) },
        // A child whose parent was deleted first has no toplevel, as in `wish`.
        .toplevel => return if (w.parent == null and !w.isToplevel()) Value.empty else .{ .str = try a.dupe(u8, w.toplevel().path) },
        .x => return .{ .int = w.geom.x },
        .y => return .{ .int = w.geom.y },
        .width => return .{ .int = w.geom.w },
        .height => return .{ .int = w.geom.h },
        .reqwidth => return .{ .int = w.req.w },
        .reqheight => return .{ .int = w.req.h },
        .rootx, .rooty => {
            var v: i32 = 0;
            var x: ?*widget.Widget = w;
            while (x) |p| : (x = p.parent) v +|= if (which == .rootx) p.geom.x else p.geom.y;
            return .{ .int = v };
        },
        .ismapped => return .{ .int = @intFromBool(w.mapped) },
        .viewable => {
            var x: ?*widget.Widget = w;
            while (x) |p| : (x = p.parent) if (!p.mapped) return .{ .int = 0 };
            return .{ .int = @intFromBool(!app.wm.withdrawn) };
        },
        .geometry => return .{ .str = try std.fmt.allocPrint(a, "{d}x{d}+{d}+{d}", .{ w.geom.w, w.geom.h, w.geom.x, w.geom.y }) },
        .manager => return .{ .str = if (w.manager) |m| m.name else if (w.parent == null) "wm" else "" },
    }
}
