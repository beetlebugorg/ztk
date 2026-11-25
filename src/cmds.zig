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
    try it.register("grab", @import("grab.zig").cmdGrab);
    try it.register("ztk::tooltip", @import("grab.zig").cmdTooltip);
    try it.register("ztk::clock", @import("animate.zig").cmdClock);
    try it.register("ztk::limit", cmdLimit);
    try it.register("interp", cmdInterp);
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
    try @import("widgets/labelframe.zig").register(app);
    try @import("widgets/message.zig").register(app);
    try @import("widgets/scale.zig").register(app);
    try @import("widgets/scrollbar.zig").register(app);
    try entry.register(app);
    try @import("widgets/spinbox.zig").register(app);
    try @import("ttk/widgets.zig").register(app);
    try @import("ttk/range.zig").register(app);
    try @import("ttk/combobox.zig").register(app);
    try it.register("clipboard", @import("clipboard.zig").command);
    try @import("canvas/canvas.zig").register(app);
    try it.register("tk", wm.cmdTk);
    app.root = try widget.makeNode(app, &toplevel.root_class, ".", null);
    try toplevel.register(app);
    const win = try app.platform.createWindow(.{});
    win.user = app.root;
    app.window = win;
    app.root.?.data = win;
    app.root.?.mapped = true;
    app.root.?.geom = .{ .w = win.size.w, .h = win.size.h };
}

/// `ztk::limit ?-steps count? ?-memory bytes? script`: runs the script in
/// the frame of the caller with a lower step limit and memory limit. A
/// child interpreter gets the limits of its caller, so
/// `ztk::limit -steps 1000 {interp eval c $text}` bounds the child. The
/// steps that the script used count against the limit of the caller, and
/// the old memory limit comes back at the end. A script inside cannot
/// catch the end of its limit, and the caller of `ztk::limit` can.
fn cmdLimit(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const usage = "ztk::limit ?-steps count? ?-memory bytes? script";
    if (argv.len < 2 or argv.len % 2 != 0) return it.wrongArgs(usage);
    var steps: u64 = it.step_limit;
    var memory: usize = it.mem_limit;
    var i: usize = 1;
    while (i + 1 < argv.len) : (i += 2) {
        const o = try it.str(argv[i]);
        const n = try it.int(argv[i + 1]);
        if (n < 0) return it.fail("expected a count of 0 or more but got \"{d}\"", .{n});
        if (std.mem.eql(u8, o, "-steps")) {
            steps = @min(steps, @as(u64, @intCast(n)));
        } else if (std.mem.eql(u8, o, "-memory")) {
            memory = @min(memory, it.memUsed() +| @as(usize, @intCast(n)));
        } else return it.fail("bad option \"{s}\": must be -memory or -steps", .{o});
    }
    const script = try it.compile(try it.alloc().dupe(u8, try it.str(argv[argv.len - 1])));
    const old_steps = it.step_limit;
    const old_memory = it.mem_limit;
    it.step_limit = steps;
    it.mem_limit = memory;
    const r = it.evalScript(script);
    it.step_limit = old_steps -| (steps - it.step_limit);
    it.mem_limit = old_memory;
    return r;
}

/// The first call of `interp` turns on the capability of ztcl, which
/// puts the real command in place, and runs the call again. A child
/// interpreter has at most the capabilities of its parent, so `interp`
/// gives a script no host access. The capability is off until a script
/// uses it, because a compact of the memory needs no capability.
fn cmdInterp(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    try it.allow(@intFromEnum(ztcl.interp.Capability.interp));
    return it.callWords(argv);
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
