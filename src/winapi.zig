//! The direct APIs of Windows (ztk#66): commands that exist on each
//! platform and give the error `ZTK WIN UNAVAILABLE` on a backend with no
//! such entry, so a script can test them with `ztk::has win`.
//!
//!   ztk::win::backdrop window ?auto|none|mica|acrylic|tabbed?
//!   ztk::win::jumplist ?task ...?     the tasks of the jump list; none removes it
//!   ztk::win::thumbbar window ?button ...?   the buttons of the thumbnail of the taskbar
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
        const l = try it.list(v);
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

/// `ztk::win::thumbbar window ?button ...?`: the buttons of the thumbnail
/// of the taskbar button of a toplevel, at most 7. Each button is a dict
/// of `image` (a photo), `tooltip`, `command`, and `disabled`. The
/// scripts stay in the wm state of the toplevel.
pub fn cmdThumbBar(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    if (argv.len < 2) return it.wrongArgs("ztk::win::thumbbar window ?button ...?");
    const f = app.platform.vtable.winThumbBar orelse return unavailable(it, "ztk::win::thumbbar");
    const path = try it.str(argv[1]);
    const top = app.find(path) orelse return it.fail("bad window path name \"{s}\"", .{path});
    if (!top.class.is_toplevel) return it.fail("\"{s}\" is not a toplevel", .{path});
    const win = app.winOf(top) orelse return it.fail("\"{s}\" has no window", .{path});
    const items = argv[2..];
    if (items.len > plat.max_thumb_buttons) return it.fail("a thumbnail has at most {d} buttons", .{plat.max_thumb_buttons});
    var buttons: [plat.max_thumb_buttons]plat.ThumbButton = undefined;
    var scripts: [plat.max_thumb_buttons][]const u8 = @splat("");
    for (items, 0..) |v, i| {
        const l = try it.list(v);
        if (l.len % 2 != 0) return it.fail("a button is a dict of image, tooltip, command, and disabled", .{});
        buttons[i] = .{ .icon = .{ .width = 0, .height = 0, .pixels = &.{} } };
        var k: usize = 0;
        while (k < l.len) : (k += 2) {
            const key = try it.str(l[k]);
            const val = try it.str(l[k + 1]);
            if (std.mem.eql(u8, key, "image")) {
                const p = app.images.find(val) orelse return it.fail("image \"{s}\" doesn't exist", .{val});
                buttons[i].icon = .{ .width = p.width, .height = p.height, .pixels = p.pixels };
            } else if (std.mem.eql(u8, key, "tooltip")) {
                buttons[i].tooltip = val;
            } else if (std.mem.eql(u8, key, "command")) {
                scripts[i] = val;
            } else if (std.mem.eql(u8, key, "disabled")) {
                buttons[i].enabled = !(@import("options.zig").parseBool(val) orelse return it.fail("expected boolean value but got \"{s}\"", .{val}));
            } else return it.fail("bad key \"{s}\" of a button: must be command, disabled, image, or tooltip", .{key});
        }
    }
    const st = app.wmOf(top);
    for (scripts, 0..) |s, i| {
        var name: [8]u8 = undefined;
        st.setProp(app.gpa, std.fmt.bufPrint(&name, "thumb{d}", .{i}) catch unreachable, s) catch return it.memError();
    }
    f(app.platform.ptr, win, buttons[0..items.len]);
    return Value.empty;
}

/// A click of a button of a thumbnail: its script, at the global level.
pub fn handleThumb(app: *App, win: *plat.Window, index: u32) void {
    const top = app.topOfWindow(win) orelse return;
    var name: [8]u8 = undefined;
    const s = app.wmOf(top).prop(std.fmt.bufPrint(&name, "thumb{d}", .{index}) catch return);
    if (s.len > 0) app.callback(s);
}
