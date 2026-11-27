//! Tests of `wm iconphoto` with the headless backend, which records the
//! last icon that a window gets.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Harness = @import("../testing.zig").Harness;
const t = std.testing;

test "iconphoto: the photos go to the backend, and the value stays" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval(
        \\image create photo big -width 64 -height 64
        \\image create photo small -width 16 -height 16
        \\big put red -to 0 0 64 64
        \\wm iconphoto . -default big small
    );
    try h.update();
    try t.expectEqual(@as(usize, 2), h.head.icon_count);
    try t.expectEqual(@as(u32, 64), h.head.icon_widths[0]);
    try t.expectEqual(@as(u32, 16), h.head.icon_widths[1]);
    try t.expect(h.head.icon_default);
    try t.expect(h.head.icon_window == h.win);
    try t.expectEqualStrings("big small", try h.eval("wm iconphoto ."));
    _ = try h.eval("wm iconphoto . small");
    try t.expectEqual(@as(usize, 1), h.head.icon_count);
    try t.expect(!h.head.icon_default);
    try t.expectEqualStrings("can't use \"nope\" as iconphoto: not a photo image", try h.evalError("wm iconphoto . nope"));
    try t.expectEqualStrings("wrong # args: should be \"wm iconphoto window ?-default? image1 ?image2 ...?\"", try h.evalError("wm iconphoto . -default"));
}
