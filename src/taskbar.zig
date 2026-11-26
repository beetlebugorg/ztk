//! The `ztk::taskbar` command: progress, a badge, and a request for
//! attention on the taskbar or dock button of the app (ztk#61).
//!
//!     ztk::taskbar progress none | indeterminate | value ?-state normal|paused|error?
//!     ztk::taskbar badge count         ;# 0 removes the badge
//!     ztk::taskbar attention ?-critical?
//!
//! A value is from 0 to 1. With no argument, `progress` and `badge` give
//! the current value. The app keeps the state and sends all of it with
//! `taskbarSet` at each change, for the window of `.`. `attention` calls
//! `attention` of the platform. `ztk::has taskbar` tells whether the
//! platform has the button.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const App = @import("app.zig").App;
const Value = ztcl.Value;

const usage = "ztk::taskbar progress|badge|attention ?arg ...?";

pub fn cmdTaskbar(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    if (argv.len < 2) return it.wrongArgs(usage);
    const sub = try it.str(argv[1]);
    const s = &app.taskbar;
    if (std.mem.eql(u8, sub, "progress")) {
        if (argv.len == 2) return switch (s.progress) {
            .none => .{ .str = "none" },
            .indeterminate => .{ .str = "indeterminate" },
            else => .{ .str = try std.fmt.allocPrint(it.alloc(), "{d}", .{s.value}) },
        };
        if (argv.len != 3 and argv.len != 5) return it.wrongArgs("ztk::taskbar progress none|indeterminate|value ?-state normal|paused|error?");
        const v = try it.str(argv[2]);
        var next = s.*;
        if (std.mem.eql(u8, v, "none")) {
            next.progress = .none;
        } else if (std.mem.eql(u8, v, "indeterminate")) {
            next.progress = .indeterminate;
        } else {
            const f = std.fmt.parseFloat(f32, v) catch return it.fail("expected a number from 0 to 1, none, or indeterminate but got \"{s}\"", .{v});
            if (!(f >= 0 and f <= 1)) return it.fail("expected a number from 0 to 1, none, or indeterminate but got \"{s}\"", .{v});
            next.progress = .normal;
            next.value = f;
        }
        if (argv.len == 5) {
            if (!std.mem.eql(u8, try it.str(argv[3]), "-state")) return it.fail("bad option \"{s}\": must be -state", .{try it.str(argv[3])});
            const st = try it.str(argv[4]);
            if (next.progress != .normal) return it.fail("-state needs a value from 0 to 1", .{});
            next.progress = if (std.mem.eql(u8, st, "normal")) .normal else if (std.mem.eql(u8, st, "paused")) .paused else if (std.mem.eql(u8, st, "error")) .failed else return it.fail("bad state \"{s}\": must be error, normal, or paused", .{st});
        }
        s.* = next;
        send(app);
        return .{ .str = "" };
    }
    if (std.mem.eql(u8, sub, "badge")) {
        if (argv.len == 2) return .{ .int = s.badge };
        if (argv.len != 3) return it.wrongArgs("ztk::taskbar badge ?count?");
        const n = try it.int(argv[2]);
        if (n < 0 or n > std.math.maxInt(u32)) return it.fail("expected a count of 0 or more but got \"{d}\"", .{n});
        s.badge = @intCast(n);
        send(app);
        return .{ .str = "" };
    }
    if (std.mem.eql(u8, sub, "attention")) {
        var critical = false;
        if (argv.len == 3 and std.mem.eql(u8, try it.str(argv[2]), "-critical")) {
            critical = true;
        } else if (argv.len != 2) return it.wrongArgs("ztk::taskbar attention ?-critical?");
        const w = app.window orelse return .{ .str = "" };
        app.platform.attention(w, critical);
        return .{ .str = "" };
    }
    return it.fail("bad option \"{s}\": must be attention, badge, or progress", .{sub});
}

fn send(app: *App) void {
    const w = app.window orelse return;
    app.platform.taskbarSet(w, app.taskbar);
}
