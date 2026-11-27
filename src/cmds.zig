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
const geom = @import("geom.zig");
const options = @import("options.zig");
const App = app_mod.App;
const Value = ztcl.Value;

pub fn register(app: *App) !void {
    const it = app.it;
    _ = try it.eval("namespace eval ::ztk::priv {}");
    it.user = app;
    try @import("filedialog.zig").register(app);
    try it.register("frame", widget.classCommand(&frame.class));
    try app.classes.put(app.gpa, "frame", &frame.class);
    try loop.register(app);
    try it.register("ztk::style", style.cmdStyle);
    try it.register("ztk::class", style.cmdClass);
    try it.register("ztk::animate", @import("animate.zig").cmdAnimate);
    try it.register("grab", @import("grab.zig").cmdGrab);
    try it.register("ztk::tooltip", @import("grab.zig").cmdTooltip);
    try it.register("ztk::clock", @import("animate.zig").cmdClock);
    try it.register("ztk::tray", @import("tray.zig").cmdTray);
    try it.register("ztk::taskbar", @import("taskbar.zig").cmdTaskbar);
    try it.register("ztk::recent", @import("recent.zig").cmdRecent);
    try it.register("ztk::hotkey", @import("hotkey.zig").cmdHotkey);
    try it.register("tkdnd::drop_target", @import("dnd.zig").cmdDropTarget);
    try it.register("ztk::dnd", @import("dnd.zig").cmdDnd);
    try it.register("ztk::has", @import("tray.zig").cmdHas);
    try it.register("ztk::mac::dockmenu", @import("macapi.zig").cmdDockMenu);
    try it.register("ztk::mac::tabbing", @import("macapi.zig").cmdTabbing);
    try it.register("ztk::win::backdrop", @import("winapi.zig").cmdBackdrop);
    try it.register("ztk::win::jumplist", @import("winapi.zig").cmdJumpList);
    try it.register("ztk::win::thumbbar", @import("winapi.zig").cmdThumbBar);
    try it.register("ztk::limit", cmdLimit);
    try @import("snapshot.zig").register(it);
    try @import("inject.zig").register(it);
    try @import("debug.zig").register(it);
    try it.register("interp", cmdInterp);
    try it.register("destroy", cmdDestroy);
    try it.register("exit", cmdExit);
    try it.register("winfo", cmdWinfo);
    try it.register("raise", cmdRaise);
    try it.register("lower", cmdLower);
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
    try @import("widgets/listbox.zig").register(app);
    try @import("widgets/text.zig").register(app);
    try @import("widgets/paned.zig").register(app);
    try @import("term/widget.zig").register(app);
    try @import("widgets/menu.zig").register(app);
    try @import("widgets/menubutton.zig").register(app);
    try entry.register(app);
    try @import("widgets/spinbox.zig").register(app);
    try @import("ttk/widgets.zig").register(app);
    try @import("ttk/range.zig").register(app);
    try @import("ttk/combobox.zig").register(app);
    try @import("ttk/notebook.zig").register(app);
    try @import("ttk/treeview.zig").register(app);
    try it.register("font", @import("fontcmd.zig").cmdFont);
    try it.register("option", @import("optiondb.zig").cmdOption);
    try @import("fontcmd.zig").init(app);
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
    try @import("dialogs.zig").register(app);
    _ = try it.eval(@embedFile("library/tk.tcl"));
}

/// `ztk::limit ?-compute units? ?-memory bytes? script`: runs the script in
/// the frame of the caller with a lower compute limit and memory limit. A
/// child interpreter gets the limits of its caller, so
/// `ztk::limit -compute 1000 {interp eval c $text}` bounds the child. The
/// compute units that the script used count against the limit of the caller, and
/// the old memory limit comes back at the end. A script inside cannot
/// catch the end of its limit, and the caller of `ztk::limit` can.
fn cmdLimit(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const usage = "ztk::limit ?-compute units? ?-memory bytes? script";
    if (argv.len < 2 or argv.len % 2 != 0) return it.wrongArgs(usage);
    var units: u64 = it.compute_limit;
    var memory: usize = it.mem_limit;
    var i: usize = 1;
    while (i + 1 < argv.len) : (i += 2) {
        const o = try it.str(argv[i]);
        const n = try it.int(argv[i + 1]);
        if (n < 0) return it.fail("expected a count of 0 or more but got \"{d}\"", .{n});
        if (std.mem.eql(u8, o, "-compute")) {
            units = @min(units, @as(u64, @intCast(n)));
        } else if (std.mem.eql(u8, o, "-memory")) {
            memory = @min(memory, it.memUsed() +| @as(usize, @intCast(n)));
        } else return it.fail("bad option \"{s}\": must be -compute or -memory", .{o});
    }
    const script = try it.compile(try it.alloc().dupe(u8, try it.str(argv[argv.len - 1])));
    const old_units = it.compute_limit;
    const old_memory = it.mem_limit;
    it.compute_limit = units;
    it.mem_limit = memory;
    const r = it.evalScript(script);
    it.compute_limit = old_units -| (units - it.compute_limit);
    it.mem_limit = old_memory;
    // A request that the lower memory limit refused sets a flag on the
    // counter of the root, and `catch` passes each error on while the
    // flag is set. The error ends here, as at the top level of an eval.
    var root = it;
    while (root.parent) |p| root = p;
    if (root.counter.refused) {
        root.counter.clearRefused();
        return it.memError();
    }
    return r;
}

/// The first call of `interp` turns on the capability of ztcl, which
/// puts the real command in place, and runs the call again. A child
/// interpreter has at most the capabilities of its parent, so `interp`
/// gives a script no host access. The capability is off until a script
/// uses it, because a compact of the memory needs no capability.
fn cmdInterp(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    // With `--allow interp`, the capability is on before this command
    // replaced the real one: the bit goes off, so `allow` puts the real
    // command back.
    const bit = @intFromEnum(ztcl.interp.Capability.interp);
    it.capabilities &= ~@as(@TypeOf(it.capabilities), bit);
    try it.allow(bit);
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

const Winfo = enum { children, exists, parent, class, name, toplevel, manager, x, y, width, height, reqwidth, reqheight, rootx, rooty, ismapped, viewable, geometry, rgb, cells, colormapfull, depth, id, pointerx, pointery, pointerxy, screen, screencells, screendepth, screenheight, screenwidth, screenmmheight, screenmmwidth, screenvisual, server, visual, visualid, vrootheight, vrootwidth, vrootx, vrooty, atom, atomname, containing, interps, pathname, fpixels, pixels, visualsavailable };

/// The size of the screen that `winfo` gives: the size of a common
/// monitor, or the root window when it is larger.
fn screenSize(app: *App) geom.Size {
    var s: geom.Size = .{ .w = 1920, .h = 1080 };
    if (app.root) |r| {
        s.w = @max(s.w, r.geom.w);
        s.h = @max(s.h, r.geom.h);
    }
    return s;
}

/// The words after `-displayof window`, for the subcommands of winfo
/// that take that option.
fn afterDisplayof(it: *ztcl.Interp, words: []const Value) ztcl.Error![]const Value {
    if (words.len >= 2 and std.mem.eql(u8, try it.str(words[0]), "-displayof")) return words[2..];
    return words;
}

fn cmdWinfo(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    app.enter();
    defer app.leave();
    if (argv.len < 2) return it.wrongArgs("winfo option ?arg?");
    const sub = try it.str(argv[1]);
    const which = std.meta.stringToEnum(Winfo, sub) orelse
        return it.fail("bad option \"{s}\": must be " ++ winfo_options, .{sub});
    if (which == .rgb) {
        // `winfo rgb window color`: the color as three 16-bit values.
        if (argv.len != 4) return it.fail("wrong # args: should be \"winfo rgb window colorName\"", .{});
        const p = try it.str(argv[2]);
        if (app.lookup(p) == null) return it.fail("bad window path name \"{s}\"", .{p});
        const name = try it.str(argv[3]);
        const c = geom.Color.parseTk(name) orelse return it.fail("unknown color name \"{s}\"", .{name});
        const vals = [_]Value{ .{ .int = @as(i64, c.r) * 257 }, .{ .int = @as(i64, c.g) * 257 }, .{ .int = @as(i64, c.b) * 257 } };
        return try ztcl.value.newList(it.alloc(), &vals);
    }
    const a0 = it.alloc();
    switch (which) {
        .fpixels, .pixels => {
            if (argv.len != 4) return it.fail("wrong # args: should be \"winfo {s} window number\"", .{sub});
            const p = try it.str(argv[2]);
            if (app.lookup(p) == null) return it.fail("bad window path name \"{s}\"", .{p});
            const t = std.mem.trim(u8, try it.str(argv[3]), " ");
            const px = options.parsePixels(t, app.scaling) orelse return it.fail("bad screen distance \"{s}\"", .{t});
            return if (which == .pixels) .{ .int = px } else .{ .double = @floatFromInt(px) };
        },
        .containing => {
            const rest = try afterDisplayof(it, argv[2..]);
            if (rest.len != 2) return it.wrongArgs("winfo containing ?-displayof window? rootX rootY");
            const x = try it.int(rest[0]);
            const y = try it.int(rest[1]);
            const root = app.root orelse return Value.empty;
            if (x < 0 or y < 0 or x >= root.geom.w or y >= root.geom.h) return Value.empty;
            const w = dispatch.widgetAt(root, @intCast(x), @intCast(y));
            return .{ .str = try a0.dupe(u8, w.path) };
        },
        .interps => {
            const rest = try afterDisplayof(it, argv[2..]);
            if (rest.len != 0) return it.wrongArgs("winfo interps ?-displayof window?");
            return try ztcl.value.newList(a0, &.{.{ .str = try a0.dupe(u8, app.app_name) }});
        },
        .atom => {
            const rest = try afterDisplayof(it, argv[2..]);
            if (rest.len != 1) return it.wrongArgs("winfo atom ?-displayof window? name");
            // A stable number for each name, as an X server gives.
            return .{ .int = 1000 + @as(i64, std.hash.Crc32.hash(try it.str(rest[0])) % 100000) };
        },
        .atomname, .pathname => {
            const rest = try afterDisplayof(it, argv[2..]);
            if (rest.len != 1) return it.fail("wrong # args: should be \"winfo {s} ?-displayof window? id\"", .{sub});
            const id = try it.str(rest[0]);
            if (which == .pathname) {
                var wi = app.widgets.valueIterator();
                while (wi.next()) |w| {
                    const mine = try std.fmt.allocPrint(a0, "0x{x}", .{@intFromPtr(w.*) & 0xffffff});
                    if (std.mem.eql(u8, mine, id)) return .{ .str = try a0.dupe(u8, w.*.path) };
                }
                return it.fail("window id \"{s}\" doesn't exist in this application", .{id});
            }
            return it.fail("no atom exists with id \"{s}\"", .{id});
        },
        .visualsavailable => {
            if (argv.len != 3 and argv.len != 4) return it.wrongArgs("winfo visualsavailable window ?includeids?");
            const p = try it.str(argv[2]);
            if (app.lookup(p) == null) return it.fail("bad window path name \"{s}\"", .{p});
            return try ztcl.value.newList(a0, &.{.{ .str = "truecolor 24" }});
        },
        else => {},
    }
    if (argv.len != 3) return it.fail("wrong # args: should be \"winfo {s} window\"", .{sub});
    const path = try it.str(argv[2]);
    if (which == .exists) return .{ .int = @intFromBool(app.find(path) != null) };
    // `wish` answers for a widget that is being deleted, and `exists` gives 0.
    const w = app.lookup(path) orelse return it.fail("bad window path name \"{s}\"", .{path});
    const a = it.alloc();
    switch (which) {
        .exists, .rgb, .fpixels, .pixels, .containing, .interps, .atom, .atomname, .pathname, .visualsavailable => unreachable,
        .cells, .screencells => return .{ .int = 256 },
        .colormapfull => return .{ .int = 0 },
        .depth, .screendepth => return .{ .int = 24 },
        .id => return .{ .str = try std.fmt.allocPrint(a, "0x{x}", .{@intFromPtr(w) & 0xffffff}) },
        .pointerx, .pointery, .pointerxy => {
            const p = app.dispatch.pointer;
            if (which == .pointerx) return .{ .int = p.x };
            if (which == .pointery) return .{ .int = p.y };
            return try ztcl.value.newList(a, &.{ .{ .int = p.x }, .{ .int = p.y } });
        },
        .screen => return .{ .str = ":0.0" },
        .server => return .{ .str = "ztk" },
        .visual, .screenvisual => return .{ .str = "truecolor" },
        .visualid => return .{ .str = "0x21" },
        .screenwidth, .vrootwidth => return .{ .int = screenSize(app).w },
        .screenheight, .vrootheight => return .{ .int = screenSize(app).h },
        .vrootx, .vrooty => return .{ .int = 0 },
        .screenmmwidth, .screenmmheight => {
            const px: f64 = @floatFromInt(if (which == .screenmmwidth) screenSize(app).w else screenSize(app).h);
            return .{ .int = @intFromFloat(@round(px / app.scaling / 72.0 * 25.4)) };
        },
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
        .reqwidth, .reqheight => {
            app.ensureStyle(w);
            @import("layout.zig").measureNow(w);
            return .{ .int = if (which == .reqwidth) w.req.w else w.req.h };
        },
        .rootx, .rooty => {
            var v: i32 = 0;
            var x: ?*widget.Widget = w;
            while (x) |p| : (x = p.parent) v +|= if (which == .rootx) p.geom.x else p.geom.y;
            return .{ .int = v };
        },
        // A withdrawn or iconic toplevel is not mapped, as in Tk.
        .ismapped => return .{ .int = @intFromBool(w.mapped and !(w.isToplevel() and (app.wmOf(w).withdrawn or app.wmOf(w).iconic))) },
        .viewable => {
            var x: ?*widget.Widget = w;
            while (x) |p| : (x = p.parent) {
                if (!p.mapped) return .{ .int = 0 };
                if (p.isToplevel()) return .{ .int = @intFromBool(!app.wmOf(p).withdrawn and !app.wmOf(p).iconic) };
            }
            return .{ .int = @intFromBool(!app.wm.withdrawn) };
        },
        .geometry => return .{ .str = try std.fmt.allocPrint(a, "{d}x{d}+{d}+{d}", .{ w.geom.w, w.geom.h, w.geom.x, w.geom.y }) },
        .manager => return .{ .str = if (w.manager) |m| m.name else if (w.parent == null) "wm" else "" },
    }
}

// ---- raise and lower ----

fn cmdRaise(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    return restack(it, argv, true);
}

fn cmdLower(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    return restack(it, argv, false);
}

/// `raise window ?aboveThis?` and `lower window ?belowThis?`: move the
/// widget in the stacking order of its siblings, which is the order of
/// the children of the parent. The paint draws the children in that
/// order, so the last one is on top. A reference widget stands for its
/// ancestor that is a sibling of the widget. A toplevel keeps its place.
fn restack(it: *ztcl.Interp, argv: []const Value, up: bool) ztcl.Error!Value {
    const app = App.of(it);
    app.enter();
    defer app.leave();
    const word = if (up) "raise" else "lower";
    if (argv.len != 2 and argv.len != 3) return it.fail("wrong # args: should be \"{s} window ?{s}?\"", .{ word, if (up) "aboveThis" else "belowThis" });
    const p = try it.str(argv[1]);
    const w = app.find(p) orelse return it.fail("bad window path name \"{s}\"", .{p});
    var ref: ?*widget.Widget = null;
    if (argv.len == 3) {
        const rp = try it.str(argv[2]);
        ref = app.find(rp) orelse return it.fail("bad window path name \"{s}\"", .{rp});
    }
    if (w.isToplevel()) return Value.empty;
    const parent = w.parent orelse return Value.empty;
    var sib: ?*widget.Widget = null;
    if (ref) |r| {
        var x: ?*widget.Widget = r;
        while (x) |y| : (x = y.parent) {
            if (y.parent == parent) {
                sib = y;
                break;
            }
        }
        if (sib == null) return it.fail("can't {s} \"{s}\" {s} \"{s}\"", .{ word, p, if (up) "above" else "below", try it.str(argv[2]) });
        if (sib.? == w) return Value.empty;
    }
    const list = &parent.children;
    const from = std.mem.indexOfScalar(*widget.Widget, list.items, w) orelse return Value.empty;
    _ = list.orderedRemove(from);
    const to: usize = if (sib) |sw| blk: {
        const k = std.mem.indexOfScalar(*widget.Widget, list.items, sw).?;
        break :blk if (up) k + 1 else k;
    } else if (up) list.items.len else 0;
    list.insert(app.gpa, to, w) catch return error.OutOfMemory;
    parent.invalidate(.{ .style = false, .measure = false, .layout = false, .paint = true });
    return Value.empty;
}
