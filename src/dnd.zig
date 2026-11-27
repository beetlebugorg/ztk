//! The drops of other apps on widgets (ztk#62), with the names of the
//! `tkdnd` package of Tk:
//!
//!     tkdnd::drop_target register .w ?{DND_Files DND_Text}?
//!     tkdnd::drop_target unregister .w
//!     bind .w <<Drop>> {puts %D}
//!     ztk::dnd drag .w -files [list $path] ?-text text? ?-move bool?
//!
//! A widget of the list accepts the types of its entry (`*` is both). The
//! window of its toplevel accepts the union of the types of its widgets,
//! through `dropTypes` of the platform. A `drop` event of the backend
//! goes to the widget at its point, or to the nearest parent on the
//! list, as virtual events with the data in `%D` and `%d`:
//! `<<DropEnter>>` and `<<DropLeave>>` when the drag comes to a target
//! and goes from it, `<<DropPosition>>` as it moves, and at the drop
//! `<<Drop:DND_Files>>` or `<<Drop:DND_Text>>`, then `<<Drop>>`. The data
//! of files is a list of the full host paths, with `/` between the
//! parts, and the data of text is the text.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const App = @import("app.zig").App;
const Widget = @import("widget.zig").Widget;
const plat = @import("platform/platform.zig");
const event = @import("event.zig");
const bind = @import("bind.zig");
const dispatch = @import("dispatch.zig");
const num = @import("num.zig");
const Value = ztcl.Value;

const Entry = struct { path: []u8, types: plat.DropTypes };

pub const State = struct {
    targets: std.ArrayListUnmanaged(Entry) = .empty,
    /// The path of the target under the drag, or empty.
    over: []u8 = &.{},

    pub fn deinit(s: *State, app: *App) void {
        for (s.targets.items) |e| app.gpa.free(e.path);
        s.targets.deinit(app.gpa);
        app.gpa.free(s.over);
    }

    fn find(s: *State, path: []const u8) ?usize {
        for (s.targets.items, 0..) |e, i| if (std.mem.eql(u8, e.path, path)) return i;
        return null;
    }
};

pub fn cmdDropTarget(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    if (argv.len < 3) return it.wrongArgs("tkdnd::drop_target register|unregister window ?types?");
    const sub = try it.str(argv[1]);
    const path = try it.str(argv[2]);
    const w = app.lookup(path) orelse return it.fail("bad window path name \"{s}\"", .{path});
    const s = &app.dnd;
    if (std.mem.eql(u8, sub, "register")) {
        if (argv.len > 4) return it.wrongArgs("tkdnd::drop_target register window ?types?");
        var types: plat.DropTypes = .{ .files = true, .text = true };
        if (argv.len == 4) {
            types = .{};
            for (try it.readList(argv[3])) |v| {
                const name = try it.str(v);
                if (std.mem.eql(u8, name, "DND_Files")) {
                    types.files = true;
                } else if (std.mem.eql(u8, name, "DND_Text")) {
                    types.text = true;
                } else if (std.mem.eql(u8, name, "*")) {
                    types = .{ .files = true, .text = true };
                } else return it.fail("bad type \"{s}\": must be DND_Files, DND_Text, or *", .{name});
            }
        }
        if (!app.platform.hasDrops()) return it.fail("this platform has no drops from other apps", .{});
        if (s.find(path)) |i| {
            s.targets.items[i].types = types;
        } else {
            const copy = app.gpa.dupe(u8, path) catch return error.OutOfMemory;
            s.targets.append(app.gpa, .{ .path = copy, .types = types }) catch {
                app.gpa.free(copy);
                return error.OutOfMemory;
            };
        }
        sync(app, w);
        return .{ .str = "" };
    }
    if (std.mem.eql(u8, sub, "unregister")) {
        if (argv.len != 3) return it.wrongArgs("tkdnd::drop_target unregister window");
        if (s.find(path)) |i| {
            app.gpa.free(s.targets.items[i].path);
            _ = s.targets.orderedRemove(i);
        }
        sync(app, w);
        return .{ .str = "" };
    }
    return it.fail("bad option \"{s}\": must be register or unregister", .{sub});
}

/// Sends the union of the types of the targets of the toplevel of `w`.
fn sync(app: *App, w: *Widget) void {
    const top = w.toplevel();
    const win = app.winOf(top) orelse return;
    var all: plat.DropTypes = .{};
    for (app.dnd.targets.items) |e| {
        const tw = app.lookup(e.path) orelse continue;
        if (tw.toplevel() != top) continue;
        all.files = all.files or e.types.files;
        all.text = all.text or e.types.text;
    }
    app.platform.dropTypes(win, all);
}

/// The nearest target at or above `w` that accepts `want`, or null.
fn targetOf(app: *App, w: *Widget, want: ?enum { files, text }) ?*Widget {
    var cur: ?*Widget = w;
    while (cur) |c| : (cur = c.parent) {
        const i = app.dnd.find(c.path) orelse continue;
        const t = app.dnd.targets.items[i].types;
        if (want) |k| switch (k) {
            .files => if (!t.files) continue,
            .text => if (!t.text) continue,
        };
        return c;
    }
    return null;
}

fn fire(app: *App, w: *Widget, name: []const u8, data: []const u8, x: f32, y: f32) void {
    if (!w.alive()) return;
    const ev: bind.WidgetEvent = .{ .type = .virtual, .widget = w, .virtual = name, .data = data, .x = num.pxFloor(x), .y = num.pxFloor(y), .serial = dispatch.nextSerial(app) };
    bind.deliver(app, &ev);
}

fn setOver(app: *App, w: ?*Widget) void {
    const s = &app.dnd;
    const path: []const u8 = if (w) |x| x.path else "";
    if (std.mem.eql(u8, path, s.over)) return;
    if (app.lookup(s.over)) |old| fire(app, old, "DropLeave", "", 0, 0);
    app.gpa.free(s.over);
    s.over = app.gpa.dupe(u8, path) catch &.{};
    if (w) |x| fire(app, x, "DropEnter", "", 0, 0);
}

/// Turns a `drop` event of the backend into the virtual events.
pub fn handleEvent(app: *App, d: anytype, top: *Widget) void {
    switch (d.phase) {
        .enter, .over => {
            const under = dispatch.widgetAt(top, num.pxFloor(d.x), num.pxFloor(d.y));
            const t = targetOf(app, under, null);
            setOver(app, t);
            if (t) |x| fire(app, x, "DropPosition", "", d.x, d.y);
        },
        .leave => setOver(app, null),
        .drop => {
            const under = dispatch.widgetAt(top, num.pxFloor(d.x), num.pxFloor(d.y));
            const files = d.files.len > 0;
            const t = targetOf(app, under, if (files) .files else .text);
            setOver(app, null);
            const w = t orelse return;
            var data: []const u8 = d.text;
            var list: std.ArrayListUnmanaged(u8) = .empty;
            defer list.deinit(app.gpa);
            if (files) {
                var it = std.mem.splitScalar(u8, d.files, 0);
                while (it.next()) |p| {
                    if (list.items.len > 0) list.append(app.gpa, ' ') catch return;
                    bind.appendQuoted(app.gpa, &list, p) catch return;
                }
                data = list.items;
            }
            fire(app, w, if (files) "Drop:DND_Files" else "Drop:DND_Text", data, d.x, d.y);
            fire(app, w, "Drop", data, d.x, d.y);
        },
    }
}

/// `ztk::dnd drag window ?-files list? ?-text string? ?-move bool?`: a
/// drag of files or text out of the window to other apps, from a
/// binding of `<B1-Motion>`. It runs in the modal loop of the system
/// until the user drops or cancels, and gives the action of the target:
/// `copy`, `move`, or `none`. A backend with no drags gives
/// `ZTK DND UNAVAILABLE`.
pub fn cmdDnd(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    const usage = "ztk::dnd drag window ?-files list? ?-text string? ?-move bool?";
    if (argv.len < 3 or !std.mem.eql(u8, try it.str(argv[1]), "drag")) return it.wrongArgs(usage);
    if (argv.len % 2 != 1) return it.wrongArgs(usage);
    const path = try it.str(argv[2]);
    const w = app.find(path) orelse return it.fail("bad window path name \"{s}\"", .{path});
    var d: plat.DragData = .{};
    var i: usize = 3;
    while (i < argv.len) : (i += 2) {
        const opt = try it.str(argv[i]);
        const v = argv[i + 1];
        if (std.mem.eql(u8, opt, "-files")) {
            const l = try it.readList(v);
            const files = try it.alloc().alloc([]const u8, l.len);
            for (l, files) |x, *f| f.* = try it.str(x);
            d.files = files;
        } else if (std.mem.eql(u8, opt, "-text")) {
            d.text = try it.str(v);
        } else if (std.mem.eql(u8, opt, "-move")) {
            const t = try it.str(v);
            d.allow_move = @import("options.zig").parseBool(t) orelse return it.fail("expected boolean value but got \"{s}\"", .{t});
        } else return it.fail("bad option \"{s}\": must be -files, -move, or -text", .{opt});
    }
    if (d.files.len == 0 and d.text.len == 0) return it.fail("a drag needs -files or -text", .{});
    const f = app.platform.vtable.dragStart orelse
        return it.failCode("ZTK DND UNAVAILABLE", "a drag out of the window is not available on this platform", .{});
    const win = app.winOf(w.toplevel()) orelse return it.fail("\"{s}\" has no window", .{path});
    return .{ .str = @tagName(f(app.platform.ptr, win, d)) };
}
