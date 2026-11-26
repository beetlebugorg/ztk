//! The `pack` geometry manager, from `pack.n`. A container has a packing
//! list. The layout walks the list in order and keeps a cavity: the
//! space that is still free. Each widget gets a parcel from one side of
//! the cavity. A widget on the top or the bottom gets the full width of
//! the cavity and its own height, and a widget on the left or the right
//! gets the full height and its own width. The parcel of a widget with
//! `-expand` also gets a share of the extra space of its axis: the space
//! that the rest of the list does not need, divided by the count of the
//! widgets in the rest of the list that expand on that axis. A widget on
//! the other axis that comes later limits the share, so that it keeps its
//! own size. The widget then fills its parcel or keeps its requested size
//! and sits at its anchor in the parcel, inside its external padding.
//! The requested size of the container is the size that the list needs.
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

pub const Side = enum { top, bottom, left, right };
pub const Fill = packed struct(u2) { x: bool = false, y: bool = false };

/// The pack options of one widget.
pub const Entry = struct {
    in: *Widget,
    side: Side = .top,
    anchor: options.Anchor = .center,
    expand: bool = false,
    fill: Fill = .{},
    ipadx: i32 = 0,
    ipady: i32 = 0,
    padx: [2]i32 = .{ 0, 0 },
    pady: [2]i32 = .{ 0, 0 },
    /// True while pack manages the widget.
    managed: bool = false,
};

/// The packing list of a container.
pub const Container = struct {
    list: std.ArrayListUnmanaged(*Widget) = .empty,
    propagate: bool = true,
};

fn entryOf(w: *const Widget) ?*Entry {
    return @ptrCast(@alignCast(w.pack_data orelse return null));
}

fn containerOf(w: *const Widget) ?*Container {
    if (w.container_manager != &manager) return null;
    return @ptrCast(@alignCast(w.container_data orelse return null));
}

fn ensureContainer(w: *Widget) !*Container {
    if (containerOf(w)) |c| return c;
    try layout.claim(w, &manager);
    const c = try w.app.gpa.create(Container);
    c.* = .{};
    w.container_data = c;
    w.container_manager = &manager;
    return c;
}

fn hasContent(w: *const Widget) bool {
    const c = containerOf(w) orelse return false;
    return c.list.items.len > 0;
}

fn propagates(w: *const Widget) bool {
    const c = containerOf(w) orelse return true;
    return c.propagate;
}

fn vertical(s: Side) bool {
    return s == .top or s == .bottom;
}

/// The size of the parcel that a widget needs on one axis: its size, two
/// times its internal padding, and its external padding.
fn need(s: *const Widget, e: *const Entry, x_axis: bool) i32 {
    if (x_axis) return num.add(num.add(s.req.w, num.px(2 * @as(i64, e.ipadx))), num.add(e.padx[0], e.padx[1]));
    return num.add(num.add(s.req.h, num.px(2 * @as(i64, e.ipady))), num.add(e.pady[0], e.pady[1]));
}

fn measure(w: *Widget) void {
    const c = containerOf(w) orelse return;
    if (!c.propagate or c.list.items.len == 0) return;
    // `used` is the space that the list has used on each axis. `most` is
    // the largest size on each axis that one widget needs with the space
    // that the widgets before it used across that axis.
    var used_w: i32 = 0;
    var used_h: i32 = 0;
    var most_w: i32 = 0;
    var most_h: i32 = 0;
    for (c.list.items) |s| {
        const e = entryOf(s).?;
        if (vertical(e.side)) {
            most_w = @max(most_w, num.add(need(s, e, true), used_w));
            used_h = num.add(used_h, need(s, e, false));
        } else {
            most_h = @max(most_h, num.add(need(s, e, false), used_h));
            used_w = num.add(used_w, need(s, e, true));
        }
    }
    const ins = layout.insets(w);
    layout.setReq(w, .{
        .w = num.add(@max(most_w, used_w), ins.horizontal()),
        .h = num.add(@max(most_h, used_h), ins.vertical()),
    });
}

/// The extra space on one axis for a widget that expands, from the
/// position `start` of the list. `free` is the space of the cavity on
/// that axis.
fn expansion(list: []const *Widget, start: usize, free_in: i32, x_axis: bool) i32 {
    var free = free_in;
    var count: i32 = 0;
    var limit: i32 = free_in;
    for (list[start..]) |s| {
        const e = entryOf(s).?;
        const own = need(s, e, x_axis);
        // A widget of this axis uses space. A widget of the other axis
        // must keep its own size on this axis.
        const same_axis = vertical(e.side) != x_axis;
        if (same_axis) {
            free -= own;
            if (e.expand) count += 1;
        } else if (count > 0) {
            limit = @min(limit, @divTrunc(free - own, count));
        }
    }
    if (count == 0) return 0;
    limit = @min(limit, @divTrunc(free, count));
    return @max(limit, 0);
}

fn arrange(w: *Widget) void {
    const c = containerOf(w) orelse return;
    const ins = layout.insets(w);
    var cx: i32 = ins.left;
    var cy: i32 = ins.top;
    var cw: i32 = @max(w.geom.w - ins.horizontal(), 0);
    var ch: i32 = @max(w.geom.h - ins.vertical(), 0);
    for (c.list.items, 0..) |s, i| {
        const e = entryOf(s).?;
        var px: i32 = undefined;
        var py: i32 = undefined;
        var pw: i32 = undefined;
        var ph: i32 = undefined;
        if (vertical(e.side)) {
            ph = need(s, e, false);
            if (e.expand) ph = num.add(ph, expansion(c.list.items, i, ch, false));
            ph = @min(ph, ch);
            ch -= ph;
            pw = cw;
            px = cx;
            if (e.side == .top) {
                py = cy;
                cy += ph;
            } else py = cy + ch;
        } else {
            pw = need(s, e, true);
            if (e.expand) pw = num.add(pw, expansion(c.list.items, i, cw, true));
            pw = @min(pw, cw);
            cw -= pw;
            ph = ch;
            py = cy;
            if (e.side == .left) {
                px = cx;
                cx += pw;
            } else px = cx + cw;
        }
        // The widget inside its parcel, inside its external padding.
        const room_w = pw - e.padx[0] - e.padx[1];
        const room_h = ph - e.pady[0] - e.pady[1];
        var sw = num.add(s.req.w, num.px(2 * @as(i64, e.ipadx)));
        var sh = num.add(s.req.h, num.px(2 * @as(i64, e.ipady)));
        if (e.fill.x or sw > room_w) sw = room_w;
        if (e.fill.y or sh > room_h) sh = room_h;
        var x = px + e.padx[0];
        var y = py + e.pady[0];
        switch (e.anchor) {
            .n, .center, .s => x += @divTrunc(room_w - sw, 2),
            .ne, .e, .se => x += room_w - sw,
            .nw, .w, .sw => {},
        }
        switch (e.anchor) {
            .w, .center, .e => y += @divTrunc(room_h - sh, 2),
            .sw, .s, .se => y += room_h - sh,
            .nw, .n, .ne => {},
        }
        if (sw <= 0 or sh <= 0) {
            layout.setMapped(s, false);
            continue;
        }
        _ = layout.setGeomIn(w, s, .{ .x = x, .y = y, .w = sw, .h = sh }, w.mapped);
    }
}

fn unlink(c: *Container, s: *Widget) void {
    for (c.list.items, 0..) |x, i| if (x == s) {
        _ = c.list.orderedRemove(i);
        return;
    };
}

/// Ends the management of a widget. Its options stay until it is deleted.
fn forgetWidget(s: *Widget) void {
    const e = entryOf(s) orelse return;
    if (e.managed) {
        if (containerOf(e.in)) |c| unlink(c, s);
        e.in.invalidate(.{ .style = false, .measure = true, .layout = true, .paint = true });
        e.managed = false;
    }
    if (s.manager == &manager) s.manager = null;
    s.mapped = false;
}

fn forgetAtDelete(s: *Widget) void {
    forgetWidget(s);
    dropData(s);
}

/// Frees the pack options of a widget.
pub fn dropData(s: *Widget) void {
    if (entryOf(s)) |e| {
        s.app.gpa.destroy(e);
        s.pack_data = null;
    }
}

fn release(w: *Widget) void {
    const c = containerOf(w) orelse return;
    for (c.list.items) |s| {
        entryOf(s).?.managed = false;
        s.manager = null;
        s.mapped = false;
    }
    c.list.deinit(w.app.gpa);
    w.app.gpa.destroy(c);
    w.container_data = null;
    w.container_manager = null;
}

pub const manager: layout.Manager = .{ .name = "pack", .measure = measure, .arrange = arrange, .forget = forgetAtDelete, .release = release, .has_content = hasContent, .propagates = propagates };

// ---- The command ----

const sub_list = "configure, content, forget, info, propagate, or slaves";
const subcommands = [_][]const u8{ "configure", "content", "forget", "info", "propagate", "slaves" };
const opt_names = [_][]const u8{ "-after", "-anchor", "-before", "-expand", "-fill", "-in", "-ipadx", "-ipady", "-padx", "-pady", "-side" };
const opt_list = "-after, -anchor, -before, -expand, -fill, -in, -ipadx, -ipady, -padx, -pady, or -side";
const side_words = [_][]const u8{ "top", "bottom", "left", "right" };
const anchor_words = [_][]const u8{ "n", "ne", "e", "se", "s", "sw", "w", "nw", "center" };

fn findWidget(it: *ztcl.Interp, app: *App, path: []const u8) ztcl.Error!*Widget {
    return app.find(path) orelse it.fail("bad window path name \"{s}\"", .{path});
}

/// `pack option arg ?arg ...?`
pub fn command(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    app.enter();
    defer app.leave();
    if (argv.len < 3 and !(argv.len == 2 and (try it.str(argv[1])).len > 0 and (try it.str(argv[1]))[0] == '.')) {
        return it.wrongArgs("pack option arg ?arg ...?");
    }
    const first = try it.str(argv[1]);
    if (first.len > 0 and first[0] == '.') return configure(it, app, argv[1..]);
    const found = grid.findPrefix(void, &subcommands, first) orelse
        return it.fail("bad option \"{s}\": must be " ++ sub_list, .{first});
    if (found.ambiguous) return it.fail("ambiguous option \"{s}\": must be " ++ sub_list, .{first});
    const rest = argv[2..];
    switch (found.idx) {
        0 => return configure(it, app, rest),
        1, 5 => {
            if (rest.len != 1) return it.fail("wrong # args: should be \"pack {s} window\"", .{subcommands[found.idx]});
            const w = try findWidget(it, app, try it.str(rest[0]));
            const a = it.alloc();
            const c = containerOf(w) orelse return Value.empty;
            const items = try a.alloc(Value, c.list.items.len);
            for (c.list.items, items) |s, *v| v.* = .{ .str = try a.dupe(u8, s.path) };
            return ztcl.value.wrapList(a, items);
        },
        2 => {
            for (rest) |v| _ = try findWidget(it, app, try it.str(v));
            for (rest) |v| {
                const w = app.find(try it.str(v)).?;
                if (w.manager == &manager) forgetWidget(w);
            }
            return Value.empty;
        },
        3 => {
            if (rest.len != 1) return it.wrongArgs("pack info window");
            const w = try findWidget(it, app, try it.str(rest[0]));
            const e = entryOf(w) orelse return it.fail("window \"{s}\" isn't packed", .{w.path});
            if (!e.managed or w.manager != &manager) return it.fail("window \"{s}\" isn't packed", .{w.path});
            return info(it, e);
        },
        4 => {
            if (rest.len < 1 or rest.len > 2) return it.wrongArgs("pack propagate window ?boolean?");
            const w = try findWidget(it, app, try it.str(rest[0]));
            if (rest.len == 1) return .{ .int = @intFromBool(if (containerOf(w)) |c| c.propagate else true) };
            const b = try grid.boolArg(it, rest[1]);
            const c = try ensureContainer(w);
            if (c.propagate != b) {
                c.propagate = b;
                w.invalidate(.{ .style = false, .measure = true, .layout = true, .paint = true });
            }
            return Value.empty;
        },
        else => unreachable,
    }
}

fn info(it: *ztcl.Interp, e: *const Entry) ztcl.Error!Value {
    const a = it.alloc();
    const fill = if (e.fill.x and e.fill.y) "both" else if (e.fill.x) "x" else if (e.fill.y) "y" else "none";
    const items = [_]Value{
        .{ .str = "-in" },     .{ .str = try a.dupe(u8, e.in.path) },
        .{ .str = "-anchor" }, .{ .str = anchor_words[@intFromEnum(e.anchor)] },
        .{ .str = "-expand" }, .{ .int = @intFromBool(e.expand) },
        .{ .str = "-fill" },   .{ .str = fill },
        .{ .str = "-ipadx" },  .{ .int = e.ipadx },
        .{ .str = "-ipady" },  .{ .int = e.ipady },
        .{ .str = "-padx" },   try grid.padValue(a, e.padx),
        .{ .str = "-pady" },   try grid.padValue(a, e.pady),
        .{ .str = "-side" },   .{ .str = side_words[@intFromEnum(e.side)] },
    };
    return ztcl.value.newList(a, &items);
}

const Opts = struct {
    after: ?*Widget = null,
    before: ?*Widget = null,
    in: ?*Widget = null,
    anchor: ?options.Anchor = null,
    expand: ?bool = null,
    fill: ?Fill = null,
    ipadx: ?i32 = null,
    ipady: ?i32 = null,
    padx: ?[2]i32 = null,
    pady: ?[2]i32 = null,
    side: ?Side = null,
};

fn packedEntry(it: *ztcl.Interp, w: *Widget) ztcl.Error!*Entry {
    const e = entryOf(w) orelse return it.fail("window \"{s}\" isn't packed", .{w.path});
    if (!e.managed or w.manager != &manager) return it.fail("window \"{s}\" isn't packed", .{w.path});
    return e;
}

fn parseOpts(it: *ztcl.Interp, app: *App, args: []const Value) ztcl.Error!Opts {
    var o: Opts = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        const name = try it.str(args[i]);
        if (i + 1 >= args.len) return it.fail("extra option \"{s}\" (option with no value?)", .{name});
        if (name.len == 0 or name[0] != '-') return it.fail("extra option \"{s}\" (option with no value?)", .{name});
        const found = grid.findPrefix(void, &opt_names, name) orelse
            return it.fail("bad option \"{s}\": must be " ++ opt_list, .{name});
        if (found.ambiguous) return it.fail("bad option \"{s}\": must be " ++ opt_list, .{name});
        const v = args[i + 1];
        const text = try it.str(v);
        switch (found.idx) {
            0, 2 => {
                const other = try findWidget(it, app, text);
                _ = try packedEntry(it, other);
                if (found.idx == 0) o.after = other else o.before = other;
            },
            1 => {
                const k = for (anchor_words, 0..) |wd, k| {
                    if (std.mem.eql(u8, wd, text)) break k;
                } else return it.fail("bad anchor \"{s}\": must be n, ne, e, se, s, sw, w, nw, or center", .{text});
                o.anchor = @enumFromInt(k);
            },
            3 => o.expand = try grid.boolArg(it, v),
            4 => {
                const f: Fill = if (std.mem.eql(u8, text, "none")) .{} else if (std.mem.eql(u8, text, "x")) .{ .x = true } else if (std.mem.eql(u8, text, "y")) .{ .y = true } else if (std.mem.eql(u8, text, "both")) .{ .x = true, .y = true } else return it.fail("bad fill style \"{s}\": must be none, x, y, or both", .{text});
                o.fill = f;
            },
            5 => o.in = try findWidget(it, app, text),
            6 => o.ipadx = try grid.parsePad1(it, app, text, "ipadx"),
            7 => o.ipady = try grid.parsePad1(it, app, text, "ipady"),
            8 => o.padx = try grid.parsePad(it, app, v),
            9 => o.pady = try grid.parsePad(it, app, v),
            10 => {
                const k = for (side_words, 0..) |wd, k| {
                    if (std.mem.eql(u8, wd, text)) break k;
                } else return it.fail("bad side \"{s}\": must be top, bottom, left, or right", .{text});
                o.side = @enumFromInt(k);
            },
            else => unreachable,
        }
    }
    return o;
}

fn configure(it: *ztcl.Interp, app: *App, args: []const Value) ztcl.Error!Value {
    var n: usize = 0;
    while (n < args.len) : (n += 1) {
        const s = try it.str(args[n]);
        if (s.len == 0 or s[0] != '.') break;
    }
    if (n == 0) return it.wrongArgs("pack option arg ?arg ...?");
    const words = args[0..n];
    for (words) |wd| {
        const w = try findWidget(it, app, try it.str(wd));
        if (w.isToplevel()) return it.fail("can't pack \"{s}\": it's a top-level window", .{w.path});
    }
    const o = try parseOpts(it, app, args[n..]);
    const gpa = app.gpa;
    // The place in the list: after or before a packed widget, or at the end.
    var anchor_widget: ?*Widget = o.after orelse o.before;
    var after = o.after != null;
    for (words) |wd| {
        const w = app.find(try it.str(wd)).?;
        const container = o.in orelse if (anchor_widget) |aw| entryOf(aw).?.in else if (entryOf(w)) |e| (if (e.managed and w.manager == &manager) e.in else w.parent.?) else w.parent.?;
        if (container == w) return it.fail("can't pack {s} inside itself", .{w.path});
        if (!grid.isDescendant(container, w.parent.?)) return it.fail("can't pack {s} inside {s}", .{ w.path, container.path });
        var up: ?*Widget = container;
        while (up) |x| {
            if (x == w) return it.fail("can't put {s} inside {s}, would cause management loop", .{ w.path, container.path });
            up = if (x.manager == &manager) entryOf(x).?.in else null;
        }
        // The old manager lets go first, so a container that it leaves empty can change its manager.
        if (w.manager) |m| if (m != &manager) m.forget(w);
        const cont = try ensureContainer(container);
        const e = entryOf(w) orelse blk: {
            const ne = try gpa.create(Entry);
            ne.* = .{ .in = container };
            w.pack_data = ne;
            break :blk ne;
        };
        if (e.managed) {
            if (containerOf(e.in)) |c| unlink(c, w);
            e.in.invalidate(.{ .style = false, .measure = true, .layout = true, .paint = true });
            e.managed = false;
        }
        if (o.side) |v| e.side = v;
        if (o.anchor) |v| e.anchor = v;
        if (o.expand) |v| e.expand = v;
        if (o.fill) |v| e.fill = v;
        if (o.ipadx) |v| e.ipadx = v;
        if (o.ipady) |v| e.ipady = v;
        if (o.padx) |v| e.padx = v;
        if (o.pady) |v| e.pady = v;
        e.in = container;
        var pos: usize = cont.list.items.len;
        if (anchor_widget) |aw| {
            for (cont.list.items, 0..) |x, k| if (x == aw) {
                pos = if (after) k + 1 else k;
                break;
            };
        }
        try cont.list.insert(gpa, pos, w);
        e.managed = true;
        w.manager = &manager;
        w.dirty.layout = true;
        // The next window of the same command goes after this one.
        anchor_widget = w;
        after = true;
        container.invalidate(.{ .style = false, .measure = true, .layout = true, .paint = true });
    }
    return Value.empty;
}
