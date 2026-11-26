//! The `ztk::tray` command: an icon in the tray of the system, with a
//! tooltip, a menu, and a command. `create` gives a name for `configure`
//! and `destroy`. Each change sends the icon, the tooltip, and
//! the native menu to the backend with `traySet`. The icon is a photo
//! image. Its pixels go to the backend at each `create` and `configure`,
//! and a later change of the photo shows at the next `configure`. A
//! `tray` event of the backend runs the `-command` of its tray with `%a`
//! replaced by the action: `click`, `double`, or `menu`.
//!
//! `ztk::has feature` gives 1 when this program has the feature on this
//! platform, and 0 when it does not. It knows `tray`, `recent`, and `native-menus`,
//! and another name gives an error.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const App = @import("app.zig").App;
const plat = @import("platform/platform.zig");
const event = @import("event.zig");
const menu = @import("widgets/menu.zig");
const Value = ztcl.Value;

pub const Tray = struct {
    name: []u8,
    id: plat.TrayId,
    image: []u8 = &.{},
    template: bool = false,
    tooltip: []u8 = &.{},
    menu: []u8 = &.{},
    command: []u8 = &.{},

    fn deinit(t: *Tray, gpa: std.mem.Allocator) void {
        gpa.free(t.name);
        gpa.free(t.image);
        gpa.free(t.tooltip);
        gpa.free(t.menu);
        gpa.free(t.command);
    }
};

pub const State = struct {
    list: std.ArrayListUnmanaged(*Tray) = .empty,
    next: u32 = 1,

    pub fn deinit(s: *State, app: *App) void {
        for (s.list.items) |t| {
            app.platform.trayDrop(t.id);
            t.deinit(app.gpa);
            app.gpa.destroy(t);
        }
        s.list.deinit(app.gpa);
    }

    fn find(s: *State, name: []const u8) ?usize {
        for (s.list.items, 0..) |t, i| if (std.mem.eql(u8, t.name, name)) return i;
        return null;
    }
};

const options = [_][]const u8{ "-command", "-image", "-menu", "-template", "-tooltip" };
const option_list = "-command, -image, -menu, -template, or -tooltip";

/// The pixels of the photo of a tray, or an empty icon.
fn icon(app: *App, t: *const Tray) plat.TrayIcon {
    const p = app.images.find(t.image) orelse return .{ .width = 0, .height = 0, .pixels = &.{} };
    return .{ .width = p.width, .height = p.height, .pixels = p.pixels };
}

fn send(app: *App, t: *const Tray) void {
    const m: plat.MenuId = if (app.find(t.menu)) |w| menu.nativeMenuOf(w) orelse 0 else 0;
    app.platform.traySet(t.id, icon(app, t), t.template, t.tooltip, m);
}

fn setOptions(app: *App, it: *ztcl.Interp, t: *Tray, args: []const Value) ztcl.Error!void {
    if (args.len % 2 != 0) return it.fail("value for \"{s}\" missing", .{try it.str(args[args.len - 1])});
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        const name = try it.str(args[i]);
        const v = try it.str(args[i + 1]);
        const which = for (options, 0..) |o, k| {
            if (std.mem.eql(u8, o, name)) break k;
        } else return it.fail("bad option \"{s}\": must be {s}", .{ name, option_list });
        switch (which) {
            0 => try replace(app, &t.command, v),
            1 => {
                if (v.len > 0 and app.images.find(v) == null) return it.fail("image \"{s}\" doesn't exist", .{v});
                try replace(app, &t.image, v);
            },
            2 => {
                if (v.len > 0) {
                    const w = app.find(v) orelse return it.fail("bad window path name \"{s}\"", .{v});
                    if (w.class != &menu.class) return it.fail("\"{s}\" is not a menu", .{v});
                }
                try replace(app, &t.menu, v);
            },
            3 => t.template = @import("options.zig").parseBool(v) orelse return it.fail("expected boolean value but got \"{s}\"", .{v}),
            else => try replace(app, &t.tooltip, v),
        }
    }
}

fn replace(app: *App, slot: *[]u8, v: []const u8) ztcl.Error!void {
    const copy = app.gpa.dupe(u8, v) catch return error.OutOfMemory;
    app.gpa.free(slot.*);
    slot.* = copy;
}

pub fn cmdTray(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    if (argv.len < 2) return it.wrongArgs("ztk::tray option ?arg ...?");
    const sub = try it.str(argv[1]);
    const s = &app.trays;
    if (std.mem.eql(u8, sub, "create")) {
        if (!app.platform.hasTray()) return it.fail("this platform has no tray", .{});
        const win = app.window orelse return it.fail("this platform has no tray", .{});
        const t = app.gpa.create(Tray) catch return error.OutOfMemory;
        t.* = .{ .name = std.fmt.allocPrint(app.gpa, "tray{d}", .{s.next}) catch {
            app.gpa.destroy(t);
            return error.OutOfMemory;
        }, .id = 0 };
        setOptions(app, it, t, argv[2..]) catch |e| {
            t.deinit(app.gpa);
            app.gpa.destroy(t);
            return e;
        };
        t.id = app.platform.trayCreate(win, icon(app, t), t.template, t.tooltip);
        if (t.id == 0) {
            t.deinit(app.gpa);
            app.gpa.destroy(t);
            return it.fail("the system has no tray", .{});
        }
        s.list.append(app.gpa, t) catch return error.OutOfMemory;
        s.next += 1;
        send(app, t);
        return .{ .str = try it.alloc().dupe(u8, t.name) };
    }
    if (std.mem.eql(u8, sub, "configure") or std.mem.eql(u8, sub, "destroy")) {
        if (argv.len < 3) return it.wrongArgs("ztk::tray configure name ?-option value ...?");
        const name = try it.str(argv[2]);
        const i = s.find(name) orelse return it.fail("tray \"{s}\" doesn't exist", .{name});
        const t = s.list.items[i];
        if (std.mem.eql(u8, sub, "destroy")) {
            if (argv.len != 3) return it.wrongArgs("ztk::tray destroy name");
            app.platform.trayDrop(t.id);
            _ = s.list.orderedRemove(i);
            t.deinit(app.gpa);
            app.gpa.destroy(t);
            return Value.empty;
        }
        try setOptions(app, it, t, argv[3..]);
        send(app, t);
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "names")) {
        const a = it.alloc();
        const list = a.alloc(Value, s.list.items.len) catch return error.OutOfMemory;
        for (s.list.items, list) |t, *v| v.* = .{ .str = try a.dupe(u8, t.name) };
        return ztcl.value.newList(a, list);
    }
    return it.fail("bad option \"{s}\": must be configure, create, destroy, or names", .{sub});
}

/// Runs the command of a tray for an action of the backend.
pub fn handleEvent(app: *App, id: plat.TrayId, action: event.TrayAction) void {
    for (app.trays.list.items) |t| if (t.id == id) {
        if (t.command.len == 0) return;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(app.gpa);
        var i: usize = 0;
        while (i < t.command.len) : (i += 1) {
            if (t.command[i] == '%' and i + 1 < t.command.len) {
                i += 1;
                switch (t.command[i]) {
                    'a' => out.appendSlice(app.gpa, @tagName(action)) catch return,
                    '%' => out.append(app.gpa, '%') catch return,
                    else => out.appendSlice(app.gpa, t.command[i - 1 .. i + 1]) catch return,
                }
            } else out.append(app.gpa, t.command[i]) catch return;
        }
        app.callback(out.items);
        return;
    };
}

pub fn cmdHas(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    if (argv.len != 2) return it.wrongArgs("ztk::has feature");
    const name = try it.str(argv[1]);
    const on = if (std.mem.eql(u8, name, "tray"))
        app.platform.hasTray()
    else if (std.mem.eql(u8, name, "recent"))
        app.platform.hasRecent()
    else if (std.mem.eql(u8, name, "native-menus"))
        app.platform.hasNativeMenus()
    else
        return it.fail("bad feature \"{s}\": must be native-menus, recent, or tray", .{name});
    return .{ .int = @intFromBool(on) };
}
