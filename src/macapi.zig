//! The direct APIs of macOS (ztk#65): commands that exist on each
//! platform and give the error `ZTK MAC UNAVAILABLE` on a backend with no
//! such entry, so a script can test them with `ztk::has mac`.
//!
//!   ztk::mac::dockmenu ?menu?          the menu of the Dock icon; "" removes it
//!   ztk::mac::tabbing window ?-mode automatic|preferred|disallowed? ?-group name?
//!
//! The services menu is in the application menu of the backend, and a
//! file dialog with `-parent` is a sheet of its window.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const App = @import("app.zig").App;
const plat = @import("platform/platform.zig");
const menu = @import("widgets/menu.zig");
const Value = ztcl.Value;

fn unavailable(it: *ztcl.Interp, name: []const u8) ztcl.Error {
    return it.failCode("ZTK MAC UNAVAILABLE", "{s} is only on macOS", .{name});
}

pub fn cmdDockMenu(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    if (argv.len > 2) return it.wrongArgs("ztk::mac::dockmenu ?menu?");
    const f = app.platform.vtable.macDockMenu orelse return unavailable(it, "ztk::mac::dockmenu");
    const name = if (argv.len == 2) try it.str(argv[1]) else "";
    if (name.len == 0) {
        f(app.platform.ptr, 0);
        return Value.empty;
    }
    const w = app.find(name) orelse return it.fail("bad window path name \"{s}\"", .{name});
    const id = menu.nativeMenuOf(w) orelse return it.fail("\"{s}\" is not a menu", .{name});
    f(app.platform.ptr, id);
    return Value.empty;
}

pub fn cmdTabbing(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    const usage = "ztk::mac::tabbing window ?-mode automatic|preferred|disallowed? ?-group name?";
    if (argv.len < 2 or argv.len % 2 != 0) return it.wrongArgs(usage);
    const f = app.platform.vtable.macTabbing orelse return unavailable(it, "ztk::mac::tabbing");
    const path = try it.str(argv[1]);
    const top = app.find(path) orelse return it.fail("bad window path name \"{s}\"", .{path});
    if (!top.class.is_toplevel) return it.fail("\"{s}\" is not a toplevel", .{path});
    const win = app.winOf(top) orelse return it.fail("\"{s}\" has no window", .{path});
    var mode: plat.Tabbing = .automatic;
    var group: []const u8 = "";
    var i: usize = 2;
    while (i < argv.len) : (i += 2) {
        const opt = try it.str(argv[i]);
        const v = try it.str(argv[i + 1]);
        if (std.mem.eql(u8, opt, "-mode")) {
            mode = std.meta.stringToEnum(plat.Tabbing, v) orelse return it.fail("bad mode \"{s}\": must be automatic, disallowed, or preferred", .{v});
        } else if (std.mem.eql(u8, opt, "-group")) {
            group = v;
        } else return it.fail("bad option \"{s}\": must be -group or -mode", .{opt});
    }
    f(app.platform.ptr, win, mode, group);
    return Value.empty;
}
