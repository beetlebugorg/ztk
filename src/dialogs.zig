//! The dialogs that ztk draws: `src/library/dialogs.tcl` has
//! `tk_messageBox`, `tk_dialog`, `tk_chooseColor`, `tk_getOpenFile`,
//! `tk_getSaveFile`, `tk_chooseDirectory`, and `ztk::toast`, as Tcl on
//! the widgets of ztk. The file evaluates after the commands of the
//! backend, and it keeps a file dialog command that a backend with
//! native dialogs registered (`filedialog.zig`).
//!
//! A backend with `messageBox` gets `::ztk::priv::nativemessagebox`:
//! `tk_messageBox` checks its options, then calls the command, which
//! runs the native box and gives the name of the button.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const App = @import("app.zig").App;
const plat = @import("platform/platform.zig");
const Value = ztcl.Value;

const script = @embedFile("library/dialogs.tcl");

pub fn register(app: *App) !void {
    const it = app.it;
    if (app.platform.hasMessageBox()) try it.register("ztk::priv::nativemessagebox", cmdNative);
    // The file dialogs of a backend stay: the script defines only the
    // commands that do not exist.
    var keep: [3]bool = undefined;
    const names = [_][]const u8{ "tk_getOpenFile", "tk_getSaveFile", "tk_chooseDirectory" };
    for (names, &keep) |n, *k| k.* = it.findCommand(n) != null;
    if (keep[0] or keep[1] or keep[2]) {
        _ = try it.eval("namespace eval ::ztk::priv {}");
        for (names, keep) |n, k| if (k) {
            const s = try std.fmt.allocPrint(it.alloc(), "rename {s} ::ztk::priv::native_{s}", .{ n, n });
            _ = try it.eval(s);
        };
    }
    _ = try it.eval(script);
    for (names, keep) |n, k| if (k) {
        const s = try std.fmt.allocPrint(it.alloc(), "rename {s} {{}}; rename ::ztk::priv::native_{s} {s}", .{ n, n, n });
        _ = try it.eval(s);
    };
}

/// `::ztk::priv::nativemessagebox type icon title message detail default parent`
fn cmdNative(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    if (argv.len != 8) return it.wrongArgs("::ztk::priv::nativemessagebox type icon title message detail default parent");
    var opts: plat.MessageBox = .{
        .buttons = std.meta.stringToEnum(plat.MessageBox.Buttons, try it.str(argv[1])) orelse .ok,
        .icon = std.meta.stringToEnum(plat.MessageBox.Icon, try it.str(argv[2])) orelse .info,
        .title = try it.str(argv[3]),
        .message = try it.str(argv[4]),
        .detail = try it.str(argv[5]),
        .default = std.meta.stringToEnum(plat.MessageBox.Button, try it.str(argv[6])) orelse .ok,
    };
    if (app.find(try it.str(argv[7]))) |w| opts.parent = app.winOf(w.toplevel());
    if (opts.parent == null) opts.parent = app.window;
    const b = app.platform.messageBox(&opts) orelse return Value.empty;
    return .{ .str = @tagName(b) };
}
