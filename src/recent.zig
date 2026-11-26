//! The `ztk::recent` command: the recent documents of the app (ztk#64).
//!
//!     ztk::recent add path    ;# adds a file to the list of the system
//!     ztk::recent clear       ;# empties the list of this app
//!
//! `add` needs the file capability of ztcl in host mode: the path goes
//! through `fsroot`, and the backend gets the full host path. A path in
//! the jail of `--root` is an error, because the system needs a real
//! path. The backend keeps the list (`recentAdd` and `recentClear` of
//! the platform), so the command keeps no state. `ztk::has recent`
//! tells whether the platform has the list.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const App = @import("app.zig").App;
const Value = ztcl.Value;

pub fn cmdRecent(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    if (argv.len < 2) return it.wrongArgs("ztk::recent add path | clear");
    const sub = try it.str(argv[1]);
    if (std.mem.eql(u8, sub, "add")) {
        if (argv.len != 3) return it.wrongArgs("ztk::recent add path");
        if (!app.platform.hasRecent()) return it.fail("this platform has no list of recent documents", .{});
        if (it.capabilities & @intFromEnum(ztcl.interp.Capability.file) == 0 or !it.fs.host)
            return it.fail("ztk::recent add needs the file commands with the real paths of the host", .{});
        const path = try ztcl.fsroot.need(it, try it.str(argv[2]));
        if (!app.platform.recentAdd(path)) return it.fail("the system did not add \"{s}\" to the recent documents", .{path});
        return .{ .str = "" };
    }
    if (std.mem.eql(u8, sub, "clear")) {
        if (argv.len != 2) return it.wrongArgs("ztk::recent clear");
        if (!app.platform.hasRecent()) return it.fail("this platform has no list of recent documents", .{});
        app.platform.recentClear();
        return .{ .str = "" };
    }
    return it.fail("bad option \"{s}\": must be add or clear", .{sub});
}
