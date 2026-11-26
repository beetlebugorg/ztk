//! The `wm` command for `.`, the `tk` command, and the window manager
//! state of the App. Stage 1 has one toplevel, so each `wm` subcommand
//! takes `.`. A size that the script sets with `wm geometry` stops the
//! automatic window size from the layout. A `close` event runs the script
//! of `wm protocol . WM_DELETE_WINDOW`, or deletes `.`.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const geom = @import("geom.zig");
const options = @import("options.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const Value = ztcl.Value;

pub const State = struct {
    title: []u8 = &.{},
    /// The size that the script set, or null.
    geometry: ?geom.Size = null,
    minsize: geom.Size = .{ .w = 1, .h = 1 },
    maxsize: geom.Size = .{ .w = 10000, .h = 10000 },
    resizable: [2]bool = .{ true, true },
    /// The script of WM_DELETE_WINDOW, owned.
    delete_script: ?[]u8 = null,
    withdrawn: bool = false,
    /// The requested size of `.` at the last window size request.
    last_req: geom.Size = .{},

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        gpa.free(s.title);
        if (s.delete_script) |d| gpa.free(d);
    }
};

const names = [_][]const u8{ "aspect", "attributes", "client", "colormapwindows", "command", "deiconify", "focusmodel", "forget", "frame", "geometry", "grid", "group", "iconbitmap", "iconify", "iconmask", "iconname", "iconphoto", "iconposition", "iconwindow", "manage", "maxsize", "minsize", "overrideredirect", "positionfrom", "protocol", "resizable", "sizefrom", "stackorder", "state", "title", "transient", "withdraw" };
const option_list = "aspect, attributes, client, colormapwindows, command, deiconify, focusmodel, forget, frame, geometry, grid, group, iconbitmap, iconify, iconmask, iconname, iconphoto, iconposition, iconwindow, manage, maxsize, minsize, overrideredirect, positionfrom, protocol, resizable, sizefrom, stackorder, state, title, transient, or withdraw";

fn findName(text: []const u8) ?usize {
    var found: ?usize = null;
    for (names, 0..) |n, i| {
        if (std.mem.eql(u8, n, text)) return i;
        if (text.len > 0 and std.mem.startsWith(u8, n, text)) {
            if (found != null) return null;
            found = i;
        }
    }
    return found;
}

fn sizeText(a: std.mem.Allocator, w: i32, h: i32) ![]const u8 {
    return std.fmt.allocPrint(a, "{d} {d}", .{ w, h });
}

/// Reads `WxH`, `WxH+X+Y`, or `WxH-X-Y`. The position is ignored.
fn parseGeometry(text: []const u8) ?geom.Size {
    const x = std.mem.indexOfScalar(u8, text, 'x') orelse return null;
    var i = x + 1;
    const wd = std.fmt.parseInt(i32, text[0..x], 10) catch return null;
    var j = i;
    while (j < text.len and text[j] >= '0' and text[j] <= '9') j += 1;
    if (j == i) return null;
    const ht = std.fmt.parseInt(i32, text[i..j], 10) catch return null;
    i = j;
    // An optional position: two signed numbers.
    var parts: usize = 0;
    while (i < text.len) {
        if (text[i] != '+' and text[i] != '-') return null;
        j = i + 1;
        while (j < text.len and text[j] >= '0' and text[j] <= '9') j += 1;
        if (j == i + 1) return null;
        parts += 1;
        i = j;
    }
    if (parts != 0 and parts != 2) return null;
    if (wd < 0 or ht < 0) return null;
    return .{ .w = wd, .h = ht };
}

/// `wm option window ?arg ...?`
pub fn cmdWm(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    app.enter();
    defer app.leave();
    if (argv.len < 3) return it.wrongArgs("wm option window ?arg ...?");
    const sub = try it.str(argv[1]);
    const which = findName(sub) orelse return it.fail("bad option \"{s}\": must be " ++ option_list, .{sub});
    const path = try it.str(argv[2]);
    const w = app.find(path) orelse return it.fail("bad window path name \"{s}\"", .{path});
    if (!w.isToplevel()) return it.fail("window \"{s}\" isn't a top-level window", .{path});
    const name = names[which];
    const args = argv[3..];
    const a = it.alloc();
    const st = app.wmOf(w);
    if (eq(name, "title")) {
        // The title is copied: the widget can go away while the value lives.
        if (args.len == 0) return .{ .str = try a.dupe(u8, if (st.title.len > 0) st.title else if (w == app.root) app.app_name else w.name()) };
        if (args.len > 1) return it.fail("wrong # args: should be \"wm title window ?newTitle?\"", .{});
        const t = try it.str(args[0]);
        const copy = try app.gpa.dupe(u8, t);
        app.gpa.free(st.title);
        st.title = copy;
        if (app.winOf(w)) |win| app.platform.vtable.setTitle(app.platform.ptr, win, copy);
        return Value.empty;
    }
    if (eq(name, "geometry")) {
        if (args.len == 0) return .{ .str = try std.fmt.allocPrint(a, "{d}x{d}+0+0", .{ w.geom.w, w.geom.h }) };
        if (args.len > 1) return it.fail("wrong # args: should be \"wm geometry window ?newGeometry?\"", .{});
        const t = try it.str(args[0]);
        if (t.len == 0) {
            st.geometry = null;
            w.invalidate(.{ .style = false, .measure = true, .layout = true, .paint = true });
            return Value.empty;
        }
        const size = parseGeometry(t) orelse return it.fail("bad geometry specifier \"{s}\"", .{t});
        st.geometry = .{ .w = std.math.clamp(size.w, 1, app_mod.max_window), .h = std.math.clamp(size.h, 1, app_mod.max_window) };
        app.setTopSize(w, st.geometry.?);
        return Value.empty;
    }
    if (eq(name, "minsize") or eq(name, "maxsize")) {
        const is_min = eq(name, "minsize");
        const cur = if (is_min) &st.minsize else &st.maxsize;
        if (args.len == 0) return .{ .str = try sizeText(a, cur.w, cur.h) };
        if (args.len != 2) return it.fail("wrong # args: should be \"wm {s} window ?width height?\"", .{name});
        const wd = options.parsePixels(try it.str(args[0]), app.scaling) orelse return it.fail("expected integer but got \"{s}\"", .{try it.str(args[0])});
        const ht = options.parsePixels(try it.str(args[1]), app.scaling) orelse return it.fail("expected integer but got \"{s}\"", .{try it.str(args[1])});
        cur.* = .{ .w = wd, .h = ht };
        if (is_min) if (app.winOf(w)) |win| app.platform.vtable.setMinSize(app.platform.ptr, win, cur.*);
        w.invalidate(.{ .style = false, .measure = true, .layout = true, .paint = true });
        return Value.empty;
    }
    if (eq(name, "resizable")) {
        if (args.len == 0) return .{ .str = try std.fmt.allocPrint(a, "{d} {d}", .{ @intFromBool(st.resizable[0]), @intFromBool(st.resizable[1]) }) };
        if (args.len != 2) return it.fail("wrong # args: should be \"wm resizable window ?width height?\"", .{});
        for (args, 0..) |v, i| {
            const t = try it.str(v);
            st.resizable[i] = options.parseBool(t) orelse return it.fail("expected boolean value but got \"{s}\"", .{t});
        }
        return Value.empty;
    }
    if (eq(name, "protocol")) {
        if (args.len == 0) return .{ .str = if (st.delete_script != null) "WM_DELETE_WINDOW" else "" };
        const proto = try it.str(args[0]);
        const is_delete = eq(proto, "WM_DELETE_WINDOW");
        if (args.len == 1) return .{ .str = if (is_delete) (st.delete_script orelse "") else "" };
        if (args.len > 2) return it.fail("wrong # args: should be \"wm protocol window ?name? ?command?\"", .{});
        if (is_delete) {
            const script = try it.str(args[1]);
            if (st.delete_script) |old| app.gpa.free(old);
            st.delete_script = if (script.len == 0) null else try app.gpa.dupe(u8, script);
        }
        return Value.empty;
    }
    if (eq(name, "withdraw") or eq(name, "deiconify")) {
        if (args.len != 0) return it.fail("wrong # args: should be \"wm {s} window\"", .{name});
        st.withdrawn = eq(name, "withdraw");
        w.invalidate(.{ .style = false, .measure = false, .layout = false, .paint = true });
        return Value.empty;
    }
    if (eq(name, "state")) {
        if (args.len == 0) return .{ .str = if (st.withdrawn) "withdrawn" else "normal" };
        const t = try it.str(args[0]);
        if (eq(t, "normal")) st.withdrawn = false else if (eq(t, "withdrawn")) st.withdrawn = true else return it.fail("wm state {s} is not supported in this stage", .{t});
        w.invalidate(.{ .style = false, .measure = false, .layout = false, .paint = true });
        return Value.empty;
    }
    return it.fail("wm {s} is not supported in this stage", .{name});
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const tk_names = "appname, busy, caret, fontchooser, inactive, scaling, useinputmethods, or windowingsystem";

/// `tk scaling ?number?` and `tk windowingsystem`.
pub fn cmdTk(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    if (argv.len < 2) return it.wrongArgs("tk subcommand ?arg ...?");
    const sub = try it.str(argv[1]);
    if (eq(sub, "windowingsystem")) {
        if (argv.len != 2) return it.wrongArgs("tk windowingsystem");
        return .{ .str = "ztk" };
    }
    if (eq(sub, "scaling")) {
        if (argv.len == 2) return .{ .double = app.scaling };
        if (argv.len != 3) return it.wrongArgs("tk scaling ?-displayof window? ?factor?");
        const text = try it.str(argv[2]);
        const v = std.fmt.parseFloat(f64, text) catch return it.fail("expected floating-point number but got \"{s}\"", .{text});
        if (!(v > 0) or v > 100) return it.fail("expected floating-point number but got \"{s}\"", .{text});
        app.scaling = v;
        app.styles.generation +%= 1;
        if (app.root) |r| r.invalidate(.{ .style = true, .measure = true, .layout = true, .paint = true });
        return Value.empty;
    }
    return it.fail("unknown or ambiguous subcommand \"{s}\": must be " ++ tk_names, .{sub});
}

test "wm: geometry parse" {
    try std.testing.expectEqual(@as(i32, 300), parseGeometry("300x200").?.w);
    try std.testing.expectEqual(@as(i32, 200), parseGeometry("300x200+10+20").?.h);
    try std.testing.expect(parseGeometry("bogus") == null);
    try std.testing.expect(parseGeometry("300x200+1") == null);
}
