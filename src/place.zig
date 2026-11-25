//! The `place` geometry manager, from `place.n`. A widget gets a fixed
//! position and size, or a position and size relative to its container,
//! or a sum of both. The anchor of the widget goes to that position.
//! A size that the script did not give is the requested size. `place`
//! does not change the requested size of the container, so it can share
//! a container with `grid` or `pack`. The container keeps the list of its
//! placed widgets in `Widget.placed`. The layout pass arranges them after
//! the other manager of the container.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const num = @import("num.zig");
const ztcl = @import("ztcl");
const geom = @import("geom.zig");
const layout = @import("layout.zig");
const options = @import("options.zig");
const grid = @import("grid.zig");
const widget_mod = @import("widget.zig");
const App = @import("app.zig").App;
const Widget = widget_mod.Widget;
const Value = ztcl.Value;

pub const BorderMode = enum { inside, outside, ignore };

pub const Entry = struct {
    in: *Widget,
    x: i32 = 0,
    y: i32 = 0,
    relx: f64 = 0,
    rely: f64 = 0,
    width: ?i32 = null,
    height: ?i32 = null,
    relwidth: ?f64 = null,
    relheight: ?f64 = null,
    anchor: options.Anchor = .nw,
    border_mode: BorderMode = .inside,
    managed: bool = false,
};

fn entryOf(w: *const Widget) ?*Entry {
    return @ptrCast(@alignCast(w.place_data orelse return null));
}

fn roundAway(v: f64) i32 {
    if (std.math.isNan(v)) return 0;
    const r = @trunc(if (v > 0) v + 0.5 else v - 0.5);
    return @intFromFloat(std.math.clamp(r, -@as(f64, num.max_px), @as(f64, num.max_px)));
}

/// Places the widgets of `Widget.placed` in the container `c`.
pub fn arrange(c: *Widget) void {
    var ox: i32 = 0;
    var oy: i32 = 0;
    var cw: i32 = c.geom.w;
    var ch: i32 = c.geom.h;
    for (c.placed.items) |s| {
        const e = entryOf(s).?;
        ox = 0;
        oy = 0;
        cw = c.geom.w;
        ch = c.geom.h;
        if (e.border_mode == .inside) {
            const ins = layout.insets(c);
            ox = ins.left;
            oy = ins.top;
            cw = @max(cw - ins.horizontal(), 0);
            ch = @max(ch - ins.vertical(), 0);
        }
        const fw: f64 = @floatFromInt(cw);
        const fh: f64 = @floatFromInt(ch);
        // The corner rounds half away from zero. A relative size rounds its
        // far edge, so the size is the difference of two rounded edges.
        const x1 = @as(f64, @floatFromInt(e.x + ox)) + e.relx * fw;
        const y1 = @as(f64, @floatFromInt(e.y + oy)) + e.rely * fh;
        var x = roundAway(x1);
        var y = roundAway(y1);
        var w: i32 = s.req.w;
        var h: i32 = s.req.h;
        if (e.width != null or e.relwidth != null) {
            w = e.width orelse 0;
            if (e.relwidth) |r| w +|= roundAway(x1 + r * fw) - x;
        }
        if (e.height != null or e.relheight != null) {
            h = e.height orelse 0;
            if (e.relheight) |r| h +|= roundAway(y1 + r * fh) - y;
        }
        switch (e.anchor) {
            .n, .center, .s => x -= @divTrunc(w, 2),
            .ne, .e, .se => x -= w,
            .nw, .w, .sw => {},
        }
        switch (e.anchor) {
            .w, .center, .e => y -= @divTrunc(h, 2),
            .sw, .s, .se => y -= h,
            .nw, .n, .ne => {},
        }
        // A container that is a descendant of the parent: move to the parent.
        var p: ?*Widget = c;
        const parent = s.parent orelse continue;
        while (p) |q| : (p = q.parent) {
            if (q == parent) break;
            x +|= q.geom.x;
            y +|= q.geom.y;
        }
        // A size of 0 or less gets 1, as in `wish`.
        _ = layout.setGeom(s, .{ .x = x, .y = y, .w = @max(w, 1), .h = @max(h, 1) }, c.mapped);
    }
}

fn unlink(c: *Widget, s: *Widget) void {
    for (c.placed.items, 0..) |x, i| if (x == s) {
        _ = c.placed.orderedRemove(i);
        return;
    };
}

fn forgetWidget(s: *Widget) void {
    const e = entryOf(s) orelse return;
    if (e.managed) {
        unlink(e.in, s);
        e.managed = false;
    }
    if (s.manager == &manager) s.manager = null;
    s.mapped = false;
    s.toplevel().dirty.paint = true;
}

fn forgetAtDelete(s: *Widget) void {
    forgetWidget(s);
    dropData(s);
}

/// Frees the place options of a widget.
pub fn dropData(s: *Widget) void {
    if (entryOf(s)) |e| {
        if (e.managed) unlink(e.in, s);
        s.app.gpa.destroy(e);
        s.place_data = null;
    }
}

/// The container is deleted: its placed widgets lose their manager.
pub fn releaseContainer(c: *Widget) void {
    for (c.placed.items) |s| {
        // As in `wish`, the widget keeps `place` as its manager and is unmapped.
        if (entryOf(s)) |e| {
            e.managed = false;
            e.in = s.parent orelse s;
        }
        s.mapped = false;
    }
    c.placed.clearRetainingCapacity();
}

fn noop(_: *Widget) void {}

pub const manager: layout.Manager = .{ .name = "place", .measure = noop, .arrange = noop, .forget = forgetAtDelete, .release = releaseContainer };

// ---- The command ----

const subcommands = [_][]const u8{ "configure", "content", "forget", "info", "slaves" };
const sub_list = "configure, content, forget, info, or slaves";
const opt_names = [_][]const u8{ "-anchor", "-bordermode", "-height", "-in", "-relheight", "-relwidth", "-relx", "-rely", "-width", "-x", "-y" };
const anchor_words = [_][]const u8{ "n", "ne", "e", "se", "s", "sw", "w", "nw", "center" };
const mode_words = [_][]const u8{ "inside", "outside", "ignore" };

fn findWidget(it: *ztcl.Interp, app: *App, path: []const u8) ztcl.Error!*Widget {
    return app.find(path) orelse it.fail("bad window path name \"{s}\"", .{path});
}

/// `place option|pathName args`
pub fn command(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    app.enter();
    defer app.leave();
    if (argv.len < 3) return it.wrongArgs("place option|pathName args");
    const first = try it.str(argv[1]);
    if (first.len > 0 and first[0] == '.') {
        const w = try findWidget(it, app, first);
        return configure(it, app, w, argv[2..]);
    }
    const found = grid.findPrefix(void, &subcommands, first) orelse
        return it.fail("bad option \"{s}\": must be " ++ sub_list, .{first});
    if (found.ambiguous) return it.fail("ambiguous option \"{s}\": must be " ++ sub_list, .{first});
    const w = try findWidget(it, app, try it.str(argv[2]));
    const rest = argv[3..];
    switch (found.idx) {
        0 => {
            if (rest.len <= 1) {
                const e = entryOf(w) orelse return Value.empty;
                if (!e.managed) return Value.empty;
                return describe(it, e, if (rest.len == 1) try it.str(rest[0]) else null);
            }
            return configure(it, app, w, rest);
        },
        1, 4 => {
            if (rest.len != 0) return it.wrongArgs("place slaves pathName");
            const a = it.alloc();
            const items = try a.alloc(Value, w.placed.items.len);
            for (w.placed.items, items) |s, *v| v.* = .{ .str = try a.dupe(u8, s.path) };
            return ztcl.value.wrapList(a, items);
        },
        2 => {
            if (rest.len != 0) return it.wrongArgs("place forget pathName");
            if (w.manager == &manager) forgetWidget(w);
            return Value.empty;
        },
        3 => {
            if (rest.len != 0) return it.wrongArgs("place info pathName");
            const e = entryOf(w) orelse return Value.empty;
            if (!e.managed or w.manager != &manager) return Value.empty;
            return info(it, e);
        },
        else => unreachable,
    }
}

fn fmtF(a: std.mem.Allocator, v: f64) !Value {
    return .{ .str = try std.fmt.allocPrint(a, "{d}", .{v}) };
}

fn optF(a: std.mem.Allocator, v: ?f64) !Value {
    return if (v) |x| fmtF(a, x) else Value.empty;
}

fn optI(v: ?i32) Value {
    return if (v) |x| .{ .int = x } else Value.empty;
}

fn info(it: *ztcl.Interp, e: *const Entry) ztcl.Error!Value {
    const a = it.alloc();
    const items = [_]Value{
        .{ .str = "-in" },        .{ .str = try a.dupe(u8, e.in.path) },
        .{ .str = "-x" },         .{ .int = e.x },
        .{ .str = "-relx" },      try fmtF(a, e.relx),
        .{ .str = "-y" },         .{ .int = e.y },
        .{ .str = "-rely" },      try fmtF(a, e.rely),
        .{ .str = "-width" },     optI(e.width),
        .{ .str = "-relwidth" },  try optF(a, e.relwidth),
        .{ .str = "-height" },    optI(e.height),
        .{ .str = "-relheight" }, try optF(a, e.relheight),
        .{ .str = "-anchor" },    .{ .str = anchor_words[@intFromEnum(e.anchor)] },
        .{ .str = "-bordermode" }, .{ .str = mode_words[@intFromEnum(e.border_mode)] },
    };
    return ztcl.value.newList(a, &items);
}

/// The configuration list of `place configure window ?option?`.
fn describe(it: *ztcl.Interp, e: *const Entry, one: ?[]const u8) ztcl.Error!Value {
    const a = it.alloc();
    const defaults = [_][]const u8{ "nw", "inside", "", "", "", "", "0", "0", "", "0", "0" };
    var out: std.ArrayListUnmanaged(Value) = .empty;
    for (opt_names, 0..) |n, i| {
        if (one) |o| if (!std.mem.eql(u8, o, n)) continue;
        const cur: Value = switch (i) {
            0 => .{ .str = anchor_words[@intFromEnum(e.anchor)] },
            1 => .{ .str = mode_words[@intFromEnum(e.border_mode)] },
            2 => optI(e.height),
            3 => .{ .str = try a.dupe(u8, e.in.path) },
            4 => try optF(a, e.relheight),
            5 => try optF(a, e.relwidth),
            6 => try fmtF(a, e.relx),
            7 => try fmtF(a, e.rely),
            8 => optI(e.width),
            9 => .{ .int = e.x },
            10 => .{ .int = e.y },
            else => unreachable,
        };
        const item = try ztcl.value.newList(a, &.{ .{ .str = n }, Value.empty, Value.empty, .{ .str = defaults[i] }, cur });
        if (one != null) return item;
        try out.append(a, item);
    }
    if (one) |o| return it.fail("unknown option \"{s}\"", .{o});
    return ztcl.value.wrapList(a, try out.toOwnedSlice(a));
}

fn parseDouble(it: *ztcl.Interp, text: []const u8) ztcl.Error!f64 {
    const v = std.fmt.parseFloat(f64, std.mem.trim(u8, text, " ")) catch
        return it.fail("expected floating-point number but got \"{s}\"", .{text});
    if (std.math.isNan(v) or std.math.isInf(v)) return it.fail("expected floating-point number but got \"{s}\"", .{text});
    return v;
}

fn configure(it: *ztcl.Interp, app: *App, w: *Widget, args: []const Value) ztcl.Error!Value {
    if (w.isToplevel()) return it.fail("can't use placer on top-level window \"{s}\"; use wm command instead", .{w.path});
    // Parse all pairs into a copy, so a bad value changes nothing.
    var e: Entry = if (entryOf(w)) |old| old.* else .{ .in = w.parent.? };
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        const name = try it.str(args[i]);
        const found = grid.findPrefix(void, &opt_names, name);
        if (found == null or found.?.ambiguous or name.len < 2) return it.fail("unknown option \"{s}\"", .{name});
        if (i + 1 >= args.len) return it.fail("value for \"{s}\" missing", .{name});
        const text = try it.str(args[i + 1]);
        switch (found.?.idx) {
            0 => {
                const k = for (anchor_words, 0..) |wd, k| {
                    if (std.mem.eql(u8, wd, text)) break k;
                } else return it.fail("bad anchor \"{s}\": must be n, ne, e, se, s, sw, w, nw, or center", .{text});
                e.anchor = @enumFromInt(k);
            },
            1 => {
                const k = for (mode_words, 0..) |wd, k| {
                    if (std.mem.startsWith(u8, wd, text) and text.len > 0) break k;
                } else return it.fail("bad bordermode \"{s}\": must be inside, outside, or ignore", .{text});
                e.border_mode = @enumFromInt(k);
            },
            2, 8 => {
                const v: ?i32 = if (text.len == 0) null else options.parsePixels(text, app.scaling) orelse return it.fail("bad screen distance \"{s}\"", .{text});
                if (found.?.idx == 2) e.height = v else e.width = v;
            },
            3 => {
                const c = try findWidget(it, app, text);
                if (c == w) return it.fail("can't place {s} relative to itself", .{w.path});
                if (!grid.isDescendant(c, w.parent.?)) return it.fail("can't place {s} relative to {s}", .{ w.path, c.path });
                e.in = c;
            },
            4, 5 => {
                const v: ?f64 = if (text.len == 0) null else try parseDouble(it, text);
                if (found.?.idx == 4) e.relheight = v else e.relwidth = v;
            },
            6 => e.relx = try parseDouble(it, text),
            7 => e.rely = try parseDouble(it, text),
            9, 10 => {
                const v = options.parsePixels(text, app.scaling) orelse return it.fail("bad screen distance \"{s}\"", .{text});
                if (found.?.idx == 9) e.x = v else e.y = v;
            },
            else => unreachable,
        }
    }
    const gpa = app.gpa;
    const slot = entryOf(w) orelse blk: {
        const ne = try gpa.create(Entry);
        ne.* = .{ .in = e.in };
        w.place_data = ne;
        break :blk ne;
    };
    if (w.manager) |m| if (m != &manager) m.forget(w);
    if (slot.managed and slot.in != e.in) {
        unlink(slot.in, w);
        slot.managed = false;
    }
    const was = slot.managed;
    slot.* = e;
    slot.managed = was;
    if (!slot.managed) {
        try e.in.placed.append(gpa, w);
        slot.managed = true;
    }
    w.manager = &manager;
    e.in.dirty.layout = true;
    w.dirty.layout = true;
    e.in.invalidate(.{ .style = false, .measure = false, .layout = true, .paint = true });
    return Value.empty;
}
