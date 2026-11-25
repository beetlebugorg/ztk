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
