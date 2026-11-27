//! Tests of the appearance of the system: the scheme follows the dark
//! mode that the backend gives, at an `appearance` event, and the App
//! keeps the accent color.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Harness = @import("../testing.zig").Harness;
const t = std.testing;

test "appearance: the scheme follows the dark mode of the system" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("label .l -text x; pack .l; update");
    try t.expectEqualStrings("light", try h.eval("ztk::style scheme"));
    h.head.setAppearance(h.win, .{ .dark = true, .accent = .{ .r = 0, .g = 120, .b = 215 } });
    try h.update();
    try t.expectEqualStrings("dark", try h.eval("ztk::style scheme"));
    try t.expectEqual(@as(u8, 215), h.app.accent.?.b);
    h.head.setAppearance(h.win, .{ .dark = false });
    try h.update();
    try t.expectEqualStrings("light", try h.eval("ztk::style scheme"));
}

test "appearance: animations follow the setting of the system for less motion until a script chooses" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    // The harness turns the animations off, so the test reads the flag.
    try t.expect(!h.app.reduce_motion);
    h.head.reduced_motion = true;
    h.head.setAppearance(h.win, .{ .dark = false });
    try h.update();
    try t.expect(h.app.reduce_motion);
    // The choice of the script stays over a change of the system.
    _ = try h.eval("ztk::animate reduce 0");
    h.head.setAppearance(h.win, .{ .dark = false });
    try h.update();
    try t.expect(!h.app.reduce_motion);
}

test "appearance: wm attributes -topmost and -fullscreen take booleans" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("wm attributes . -topmost 1 -fullscreen yes");
    try t.expectEqualStrings("1 yes", try h.eval("list [wm attributes . -topmost] [wm attributes . -fullscreen]"));
    try t.expectEqualStrings("expected boolean value but got \"x\"", try h.evalError("wm attributes . -topmost x"));
}
