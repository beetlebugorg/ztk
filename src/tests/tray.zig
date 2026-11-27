//! Tests of `ztk::tray` and `ztk::has` with the tray of the headless
//! backend, which records the calls and queues the actions of a test.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Harness = @import("../testing.zig").Harness;
const t = std.testing;

test "tray: create, configure, an action, and destroy" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try t.expectEqualStrings("1", try h.eval("ztk::has tray"));
    _ = try h.eval("image create photo dot -width 16 -height 16");
    try t.expectEqualStrings("tray1", try h.eval("ztk::tray create -image dot -template 1 -tooltip Hello -command {set ::got %a}"));
    const r = h.head.tray(1).?;
    try t.expectEqual(@as(u32, 16), r.width);
    try t.expect(r.template);
    try t.expectEqualStrings("Hello", r.tooltip.items);
    _ = try h.eval("ztk::tray configure tray1 -tooltip Bye");
    try t.expectEqualStrings("Bye", h.head.tray(1).?.tooltip.items);
    h.head.trayAction(h.win, 1, .double);
    try h.update();
    try t.expectEqualStrings("double", try h.eval("set ::got"));
    try t.expectEqualStrings("tray1", try h.eval("ztk::tray names"));
    _ = try h.eval("ztk::tray destroy tray1");
    try t.expect(h.head.tray(1) == null);
    try t.expectEqualStrings("", try h.eval("ztk::tray names"));
}

test "tray: the errors of the options and of the names" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try t.expectEqualStrings("image \"none\" doesn't exist", try h.evalError("ztk::tray create -image none"));
    try t.expectEqualStrings("bad option \"-icon\": must be -command, -image, -menu, -template, or -tooltip", try h.evalError("ztk::tray create -icon x"));
    try t.expectEqualStrings("tray \"tray9\" doesn't exist", try h.evalError("ztk::tray destroy tray9"));
    try t.expectEqualStrings("bad feature \"teleport\": must be mac, native-menus, recent, taskbar, tray, or win", try h.evalError("ztk::has teleport"));
    try t.expectEqualStrings("0", try h.eval("ztk::has native-menus"));
}

test "ztk::mac: the direct APIs of macOS give an error on another backend" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try t.expectEqualStrings("0", try h.eval("ztk::has mac"));
    try t.expectEqualStrings("ztk::mac::dockmenu is only on macOS", try h.evalError("ztk::mac::dockmenu"));
    try t.expectEqualStrings("ztk::mac::tabbing is only on macOS", try h.evalError("ztk::mac::tabbing . -mode preferred"));
}

test "tray: a direct command of Windows gives ZTK WIN UNAVAILABLE on another backend" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try t.expectEqualStrings("0", try h.eval("ztk::has win"));
    try t.expectEqualStrings("ztk::win::backdrop is only on Windows", try h.evalError("ztk::win::backdrop . mica"));
    try t.expectEqualStrings("ZTK WIN UNAVAILABLE", try h.eval("catch {ztk::win::backdrop .}; set ::errorCode"));
}

test "tray: the tasks of ztk::win::jumplist parse from dicts" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const winapi = @import("../winapi.zig");
    try t.expectEqualStrings("ztk::win::jumplist is only on Windows", try h.evalError("ztk::win::jumplist {title New args --new}"));
    const v = try h.it.eval("list {title New args --new description {A new window} iconindex 2} {title Open}");
    const tasks = try winapi.parseTasks(&h.it, try h.it.readList(v));
    try t.expectEqual(@as(usize, 2), tasks.len);
    try t.expectEqualStrings("--new", tasks[0].args);
    try t.expectEqualStrings("A new window", tasks[0].description);
    try t.expectEqual(@as(i32, 2), tasks[0].icon_index);
    try t.expectEqualStrings("Open", tasks[1].title);
    const bad = try h.it.eval("list {args --x}");
    try t.expectError(error.TclError, winapi.parseTasks(&h.it, try h.it.readList(bad)));
}

test "tray: ztk::win::thumbbar is only on Windows, and a click runs the script of its button" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try t.expectEqualStrings("ztk::win::thumbbar is only on Windows", try h.evalError("ztk::win::thumbbar . {tooltip Play}"));
    // The scripts of the buttons stay in the wm state of the toplevel.
    const top = h.app.find(".").?;
    try h.app.wmOf(top).setProp(h.app.gpa, "thumb1", "set ::clicked 1");
    @import("../winapi.zig").handleThumb(h.app, h.win, 1);
    try t.expectEqualStrings("1", try h.eval("set ::clicked"));
}
