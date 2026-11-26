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
    try t.expectEqualStrings("bad feature \"teleport\": must be native-menus, recent, or tray", try h.evalError("ztk::has teleport"));
    try t.expectEqualStrings("0", try h.eval("ztk::has native-menus"));
}
