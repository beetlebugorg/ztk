//! Tests of `ztk::inject` on the headless backend.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Harness = @import("../testing.zig").Harness;
const t = std.testing;

test "inject: a press and a release invoke a button" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("wm geometry . 200x100; set n 0; button .b -text go -command {incr n}; place .b -x 10 -y 10 -width 80 -height 30; update");
    // The generated events of `event generate` leave the hover flag clear.
    _ = try h.eval("event generate .b <ButtonPress-1> -x 5 -y 5; event generate .b <ButtonRelease-1> -x 5 -y 5");
    try t.expectEqualStrings("0", try h.eval("set n"));
    _ = try h.eval("ztk::inject . motion 20 20; ztk::inject . press 1 20 20; ztk::inject . release 1 20 20");
    try t.expectEqualStrings("1", try h.eval("set n"));
    // A release away from the button does not invoke it.
    _ = try h.eval("ztk::inject . press 1 20 20; ztk::inject . motion 150 80; ztk::inject . release 1 150 80");
    try t.expectEqualStrings("1", try h.eval("set n"));
}

test "inject: keys and text go to the widget with the focus" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("wm geometry . 200x100; entry .e; place .e -x 10 -y 10 -width 150; focus .e; update");
    _ = try h.eval(".e insert end abc; ztk::inject . key BackSpace");
    try t.expectEqualStrings("ab", try h.eval(".e get"));
    _ = try h.eval(".e delete 0 end; ztk::inject . text {hé there}; ztk::inject . key BackSpace; ztk::inject . key x");
    try t.expectEqualStrings("hé therx", try h.eval(".e get"));
    _ = try h.eval("ztk::inject . key a -state 4");
    try t.expectEqualStrings("hé therx", try h.eval(".e get"));
}

test "inject: the wheel goes to the widget under the point" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("wm geometry . 200x100; frame .f -width 50 -height 50; place .f -x 100 -y 10; set d {}; bind .f <MouseWheel> {lappend d %D}; update");
    _ = try h.eval("ztk::inject . wheel 120 30 -120; ztk::inject . wheel 10 30 -120");
    try t.expectEqualStrings("-120", try h.eval("set d"));
}

test "inject: bad arguments" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try t.expectEqualStrings("bad window path name \".nope\"", try h.evalError("ztk::inject .nope motion 1 1"));
    try t.expectEqualStrings("bad form \"jump\": must be motion, press, release, wheel, key, or text", try h.evalError("ztk::inject . jump"));
    try t.expectEqualStrings("bad keysym \"nosuch\"", try h.evalError("ztk::inject . key nosuch"));
    try t.expectEqualStrings("expected number but got \"a\"", try h.evalError("ztk::inject . motion a 1"));
}
