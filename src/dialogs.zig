//! The dialogs that ztk draws: `src/library/dialogs.tcl` has
//! `tk_messageBox`, `tk_dialog`, `tk_chooseColor`, `tk_getOpenFile`,
//! `tk_getSaveFile`, `tk_chooseDirectory`, and `ztk::toast`, as Tcl on
//! the widgets of ztk. The file evaluates after the commands of the
//! backend, and it keeps a file dialog command that a backend with
//! native dialogs registered (`filedialog.zig`).
//!
//! A backend with `messageBox` gets `::ztk::priv::nativemessagebox`:
//! `tk_messageBox` checks its options, then calls the command, which
//! runs the native box and gives the name of the button. A backend with
//! `colorDialog` gets `::ztk::priv::nativecolor` for `tk_chooseColor`
//! in the same way. A backend with `fontDialog` gets
//! `::ztk::priv::nativefont` for `tk fontchooser show`
//! (`library/tk.tcl`).
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
    if (app.platform.hasColorDialog()) try it.register("ztk::priv::nativecolor", cmdColor);
    if (app.platform.hasFontDialog()) try it.register("ztk::priv::nativefont", cmdFont);
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

/// `::ztk::priv::nativecolor title r g b parent`: the chosen color as
/// `#rrggbb`, or an empty string for a cancel.
fn cmdColor(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    if (argv.len != 6) return it.wrongArgs("::ztk::priv::nativecolor title r g b parent");
    var rgb: [3]u8 = undefined;
    for (argv[2..5], &rgb) |v, *c| c.* = @intCast(std.math.clamp(try it.int(v), 0, 255));
    var opts: plat.ColorDialog = .{ .title = try it.str(argv[1]), .initial = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] } };
    if (app.find(try it.str(argv[5]))) |w| opts.parent = app.winOf(w.toplevel());
    if (opts.parent == null) opts.parent = app.window;
    const c = app.platform.colorDialog(app.gpa, &opts) orelse return Value.empty;
    return .{ .str = try std.fmt.allocPrint(it.alloc(), "#{x:0>2}{x:0>2}{x:0>2}", .{ c.r, c.g, c.b }) };
}

/// `::ztk::priv::nativefont title family size bold italic underline
/// overstrike parent`: the chosen font as a font description (`family
/// size ?style ...?`), or an empty string for a cancel. The size is in
/// points.
fn cmdFont(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    if (argv.len != 9) return it.wrongArgs("::ztk::priv::nativefont title family size bold italic underline overstrike parent");
    var opts: plat.FontDialog = .{ .title = try it.str(argv[1]), .initial = .{
        .family = try it.str(argv[2]),
        .size = @intCast(std.math.clamp(try it.int(argv[3]), 1, 999)),
        .bold = try it.int(argv[4]) != 0,
        .italic = try it.int(argv[5]) != 0,
        .underline = try it.int(argv[6]) != 0,
        .overstrike = try it.int(argv[7]) != 0,
    } };
    if (app.find(try it.str(argv[8]))) |w| opts.parent = app.winOf(w.toplevel());
    if (opts.parent == null) opts.parent = app.window;
    const f = app.platform.fontDialog(app.gpa, &opts) orelse return Value.empty;
    defer app.gpa.free(f.family);
    const a = it.alloc();
    var items: std.ArrayListUnmanaged(Value) = .empty;
    try items.append(a, .{ .str = try a.dupe(u8, f.family) });
    try items.append(a, .{ .int = f.size });
    if (f.bold) try items.append(a, .{ .str = "bold" });
    if (f.italic) try items.append(a, .{ .str = "italic" });
    if (f.underline) try items.append(a, .{ .str = "underline" });
    if (f.overstrike) try items.append(a, .{ .str = "overstrike" });
    return ztcl.value.wrapList(a, try items.toOwnedSlice(a));
}
