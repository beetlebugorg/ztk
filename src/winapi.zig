//! The direct APIs of Windows (ztk#66): commands that exist on each
//! platform and give the error `ZTK WIN UNAVAILABLE` on a backend with no
//! such entry, so a script can test them with `ztk::has win`.
//!
//!   ztk::win::backdrop window ?auto|none|mica|acrylic|tabbed?
//!   ztk::win::jumplist ?task ...?     the tasks of the jump list; none removes it
//!
//! `backdrop` sets the system backdrop of a toplevel, the material that
//! Windows 11 draws behind the window (`DWMWA_SYSTEMBACKDROP_TYPE`), and
//! with no type gives the one it set last. The client area of ztk is
//! opaque, so the backdrop shows in the title bar.
//!
//! `jumplist` sets the tasks of the jump list of the app, the items under
//! "Tasks" in the menu of its taskbar button. Each task is a dict of
//! `title` and `args`, and `description`, `icon`, and `iconindex` when it
//! has them. A task starts this program with `args`. With no task the
//! list of the app goes away.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const App = @import("app.zig").App;
const plat = @import("platform/platform.zig");
const Value = ztcl.Value;

fn unavailable(it: *ztcl.Interp, name: []const u8) ztcl.Error {
    return it.failCode("ZTK WIN UNAVAILABLE", "{s} is only on Windows", .{name});
}

pub fn cmdBackdrop(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    const usage = "ztk::win::backdrop window ?auto|none|mica|acrylic|tabbed?";
    if (argv.len != 2 and argv.len != 3) return it.wrongArgs(usage);
    const f = app.platform.vtable.winBackdrop orelse return unavailable(it, "ztk::win::backdrop");
    const path = try it.str(argv[1]);
    const top = app.find(path) orelse return it.fail("bad window path name \"{s}\"", .{path});
    if (!top.class.is_toplevel) return it.fail("\"{s}\" is not a toplevel", .{path});
    const win = app.winOf(top) orelse return it.fail("\"{s}\" has no window", .{path});
    const st = app.wmOf(top);
    if (argv.len == 2) {
        const cur = st.prop("backdrop");
        return .{ .str = if (cur.len > 0) cur else "auto" };
    }
    const v = try it.str(argv[2]);
    const kind = std.meta.stringToEnum(plat.Backdrop, v) orelse return it.fail("bad backdrop \"{s}\": must be acrylic, auto, mica, none, or tabbed", .{v});
    if (!f(app.platform.ptr, win, kind)) return it.failCode("ZTK WIN BACKDROP", "this Windows has no system backdrop", .{});
    st.setProp(app.gpa, "backdrop", @tagName(kind)) catch return it.memError();
    return Value.empty;
}

/// The tasks of the dicts of `ztk::win::jumplist`, in memory of the
/// interpreter: `title` and `args`, and `description`, `icon`, and
/// `iconindex` when they are there.
pub fn parseTasks(it: *ztcl.Interp, items: []const Value) ztcl.Error![]plat.JumpTask {
    const tasks = try it.alloc().alloc(plat.JumpTask, items.len);
    for (items, tasks) |v, *t| {
        const l = try it.readList(v);
        if (l.len % 2 != 0) return it.fail("a task is a dict of title, args, description, icon, and iconindex", .{});
        t.* = .{ .title = "" };
        var k: usize = 0;
        while (k < l.len) : (k += 2) {
            const key = try it.str(l[k]);
            const val = l[k + 1];
            if (std.mem.eql(u8, key, "title")) {
                t.title = try it.str(val);
            } else if (std.mem.eql(u8, key, "args")) {
                t.args = try it.str(val);
            } else if (std.mem.eql(u8, key, "description")) {
                t.description = try it.str(val);
            } else if (std.mem.eql(u8, key, "icon")) {
                t.icon = try it.str(val);
            } else if (std.mem.eql(u8, key, "iconindex")) {
                t.icon_index = @intCast(std.math.clamp(try it.int(val), std.math.minInt(i32), std.math.maxInt(i32)));
            } else return it.fail("bad key \"{s}\" of a task: must be args, description, icon, iconindex, or title", .{key});
        }
        if (t.title.len == 0) return it.fail("a task needs a title", .{});
    }
    return tasks;
}

pub fn cmdJumpList(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    const f = app.platform.vtable.winJumpTasks orelse return unavailable(it, "ztk::win::jumplist");
    const tasks = try parseTasks(it, argv[1..]);
    if (!f(app.platform.ptr, tasks)) return it.failCode("ZTK WIN JUMPLIST", "the shell refused the jump list", .{});
    return Value.empty;
}
