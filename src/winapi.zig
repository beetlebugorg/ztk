//! The direct APIs of Windows (ztk#66): commands that exist on each
//! platform and give the error `ZTK WIN UNAVAILABLE` on a backend with no
//! such entry, so a script can test them with `ztk::has win`.
//!
//!   ztk::win::backdrop window ?auto|none|mica|acrylic|tabbed?
//!
//! `backdrop` sets the system backdrop of a toplevel, the material that
//! Windows 11 draws behind the window (`DWMWA_SYSTEMBACKDROP_TYPE`), and
//! with no type gives the one it set last. The client area of ztk is
//! opaque, so the backdrop shows in the title bar.
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
