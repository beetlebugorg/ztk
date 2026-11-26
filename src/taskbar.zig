//! The `ztk::taskbar` command: the icon of the program in the Dock of
//! macOS or the taskbar of Windows (ztk#61).
//!
//!   ztk::taskbar badge ?text?              a short text on the icon; "" removes it
//!   ztk::taskbar progress value|none       a bar from 0 to 1 on the icon
//!   ztk::taskbar attention ?-critical?     a bounce or a flash of the icon
//!   ztk::taskbar attention none            ends the request
//!
//! Each subcommand acts for the window of `.`, or `-window .w` names
//! another toplevel. On a platform with no such icon the command has no
//! effect, and `ztk::has taskbar` gives 0.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const App = @import("app.zig").App;
const plat = @import("platform/platform.zig");
const Value = ztcl.Value;

const usage = "ztk::taskbar badge|progress|attention ?-window window? ?value?";

pub fn cmdTaskbar(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    if (argv.len < 2) return it.wrongArgs(usage);
    const sub = try it.str(argv[1]);
    var win: ?*plat.Window = if (app.root) |r| app.winOf(r) else null;
    var args = argv[2..];
    if (args.len >= 2 and std.mem.eql(u8, try it.str(args[0]), "-window")) {
        const name = try it.str(args[1]);
        const top = app.find(name) orelse return it.fail("bad window path name \"{s}\"", .{name});
        win = app.winOf(top);
        args = args[2..];
    }
    const eq = std.mem.eql;
    if (eq(u8, sub, "badge")) {
        if (args.len > 1) return it.wrongArgs("ztk::taskbar badge ?-window window? ?text?");
        app.platform.taskbarBadge(win, if (args.len == 1) try it.str(args[0]) else "");
        return Value.empty;
    }
    if (eq(u8, sub, "progress")) {
        if (args.len != 1) return it.wrongArgs("ztk::taskbar progress ?-window window? value|none");
        const text = try it.str(args[0]);
        if (eq(u8, text, "none")) {
            app.platform.taskbarProgress(win, null);
            return Value.empty;
        }
        const v = std.fmt.parseFloat(f64, std.mem.trim(u8, text, " ")) catch return it.fail("expected a number from 0 to 1 or \"none\" but got \"{s}\"", .{text});
        if (!(v >= 0 and v <= 1)) return it.fail("expected a number from 0 to 1 or \"none\" but got \"{s}\"", .{text});
        app.platform.taskbarProgress(win, @floatCast(v));
        return Value.empty;
    }
    if (eq(u8, sub, "attention")) {
        if (args.len > 1) return it.wrongArgs("ztk::taskbar attention ?-window window? ?-critical|none?");
        const kind: plat.Attention = if (args.len == 0) .informational else blk: {
            const a = try it.str(args[0]);
            if (eq(u8, a, "-critical")) break :blk .critical;
            if (eq(u8, a, "none")) break :blk .none;
            return it.fail("bad option \"{s}\": must be -critical or none", .{a});
        };
        app.platform.taskbarAttention(win, kind);
        return Value.empty;
    }
    return it.fail("bad subcommand \"{s}\": must be attention, badge, or progress", .{sub});
}
