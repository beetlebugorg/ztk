//! Tests of `tkdnd::drop_target` with the headless backend, which
//! records the types of the window and queues the phases of a drag.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Harness = @import("../testing.zig").Harness;
const t = std.testing;

test "dnd: a drop of files and of text on a target and on its child" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval(
        \\frame .f -width 200 -height 100
        \\pack .f
        \\label .f.l -text in
        \\place .f.l -x 0 -y 0 -width 50 -height 50
        \\set ::log {}
        \\tkdnd::drop_target register .f DND_Files
        \\bind .f <<DropEnter>> {lappend ::log enter}
        \\bind .f <<DropLeave>> {lappend ::log leave}
        \\bind .f <<Drop:DND_Files>> {lappend ::log files [llength %D]}
        \\bind .f <<Drop>> {lappend ::log drop %D}
    );
    try h.update();
    try t.expect(h.head.drop_types.files and !h.head.drop_types.text);
    // The label is not a target, so its parent .f takes the drop.
    h.head.dragAt(h.win, .enter, 10, 10, "", "");
    h.head.dragAt(h.win, .over, 20, 20, "", "");
    h.head.dragAt(h.win, .drop, 20, 20, "C:/a b/x.txt\x00C:/y.png", "");
    try h.update();
    try t.expectEqualStrings("enter leave files 2 drop {{C:/a b/x.txt} C:/y.png}", try h.eval("set ::log"));
    // .f takes no text, so a drop of text has no target.
    _ = try h.eval("set ::log {}");
    h.head.dragAt(h.win, .enter, 10, 10, "", "");
    h.head.dragAt(h.win, .drop, 10, 10, "", "hello");
    try h.update();
    try t.expectEqualStrings("enter leave", try h.eval("set ::log"));
    _ = try h.eval("tkdnd::drop_target register .f {DND_Files DND_Text}; set ::log {}");
    h.head.dragAt(h.win, .drop, 10, 10, "", "hello there");
    try h.update();
    try t.expectEqualStrings("drop {hello there}", try h.eval("set ::log"));
    _ = try h.eval("tkdnd::drop_target unregister .f");
    try t.expect(!h.head.drop_types.files and !h.head.drop_types.text);
}

test "dnd: the errors of the arguments" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try t.expectEqualStrings("bad window path name \".nope\"", try h.evalError("tkdnd::drop_target register .nope"));
    try t.expectEqualStrings("bad type \"DND_Color\": must be DND_Files, DND_Text, or *", try h.evalError("tkdnd::drop_target register . DND_Color"));
    try t.expectEqualStrings("bad option \"list\": must be register or unregister", try h.evalError("tkdnd::drop_target list ."));
}

test "dnd: a drag out checks its options, and a backend with no drags gives ZTK DND UNAVAILABLE" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try t.expectEqualStrings("a drag needs -files or -text", try h.evalError("ztk::dnd drag ."));
    try t.expectEqualStrings("bad option \"-url\": must be -files, -move, or -text", try h.evalError("ztk::dnd drag . -url x"));
    try t.expectEqualStrings("expected boolean value but got \"x\"", try h.evalError("ztk::dnd drag . -text a -move x"));
    try t.expectEqualStrings("ZTK DND UNAVAILABLE", try h.eval("catch {ztk::dnd drag . -text a}; set ::errorCode"));
}
