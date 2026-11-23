//! Tests of the keyboard focus and the traversal. The expected texts
//! are from `wish` 8.6.16.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Harness = @import("../testing.zig").Harness;
const t = std.testing;

fn setup(h: *Harness) !void {
    try h.init();
    _ = try h.eval("foreach n {a b c} { frame .$n -takefocus 1 -width 10 -height 10 }; frame .n -takefocus 0 -width 10 -height 10; grid .a .n .b .c; set log {}; update");
}

fn log(h: *Harness) ![]const u8 {
    return h.eval("set log");
}

test "focus: set, read, and errors" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    _ = try h.eval("focus .a");
    try t.expectEqualStrings(".a", try h.eval("focus"));
    try t.expectEqualStrings("bad window path name \".zz\"", try h.evalError("focus .zz"));
    try t.expectEqualStrings("bad option \"-foo\": must be -displayof, -force, or -lastfor", try h.evalError("focus -foo .a"));
    try t.expectEqualStrings("wrong # args: should be \"focus -force window\"", try h.evalError("focus -force"));
    _ = try h.eval("focus -force .b");
    try t.expectEqualStrings(".b", try h.eval("focus -displayof .a"));
    try t.expectEqualStrings(".b", try h.eval("focus -lastfor .a"));
}

test "focus: events and the state bit" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    _ = try h.eval("bind .a <FocusOut> {lappend log out-a}; bind .a <FocusIn> {lappend log in-a}; bind .b <FocusIn> {lappend log in-b}");
    _ = try h.eval("focus .a; focus .b");
    try t.expectEqualStrings("in-a out-a in-b", try log(&h));
    _ = try h.eval("ztk::style add {Frame:focus { background-color: #123456 }}");
    var buf: [7]u8 = undefined;
    h.app.ensureStyle(h.app.find(".b").?);
    try t.expectEqualStrings("#123456", h.app.find(".b").?.style.background.formatTk(&buf));
    try t.expect(!h.app.find(".a").?.state.focus);
}

test "focus: key events go to the focus widget, or to the toplevel" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    _ = try h.eval("bind .a <Key> {lappend log a:%K:%A}; bind . <Key> {lappend log top:%K}");
    try h.head.press(h.win, "x");
    try h.update();
    try t.expectEqualStrings("top:x", try log(&h));
    _ = try h.eval("set log {}; focus .a");
    try h.head.press(h.win, "x");
    try h.update();
    // The widget binding runs first, then the toplevel tag.
    try t.expectEqualStrings("a:x:x top:x", try log(&h));
}

test "focus: traversal" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    try t.expectEqualStrings(".b", try h.eval("tk_focusNext .a"));
    try t.expectEqualStrings(".a", try h.eval("tk_focusNext .c"));
    try t.expectEqualStrings(".c", try h.eval("tk_focusPrev .a"));
    try t.expectEqualStrings(".a", try h.eval("tk_focusPrev .b"));
    try t.expectEqualStrings("wrong # args: should be \"tk_focusNext w\"", try h.evalError("tk_focusNext"));
    _ = try h.eval("focus .a");
    try h.head.press(h.win, "Tab");
    try h.update();
    try t.expectEqualStrings(".b", try h.eval("focus"));
    h.head.setMods(.{ .shift = true });
    try h.head.press(h.win, "Tab");
    try h.update();
    h.head.setMods(.{});
    try t.expectEqualStrings(".a", try h.eval("focus"));
    _ = try h.eval("bind .a <Key-Tab> {break}");
    try h.head.press(h.win, "Tab");
    try h.update();
    try t.expectEqualStrings(".a", try h.eval("focus"));
    // A disabled widget and an unmapped widget are not results.
    _ = try h.eval("frame .d -takefocus 1; grid .d; update");
    try t.expectEqualStrings(".d", try h.eval("tk_focusNext .c"));
    _ = try h.eval("grid forget .d; update");
    try t.expectEqualStrings(".a", try h.eval("tk_focusNext .c"));
    _ = try h.eval("label .l -takefocus 1 -state disabled; grid .l; update");
    try t.expectEqualStrings(".a", try h.eval("tk_focusNext .c"));
    _ = try h.eval(".l configure -state normal");
    try t.expectEqualStrings(".l", try h.eval("tk_focusNext .c"));
}

test "focus: the window loses and gets the keyboard" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    _ = try h.eval("focus .b; bind .b <FocusIn> {lappend log in}");
    h.head.setFocused(h.win, false);
    try h.update();
    try t.expectEqualStrings("", try h.eval("focus"));
    try t.expectEqualStrings(".b", try h.eval("focus -lastfor ."));
    try t.expect(h.app.root.?.state.background);
    h.head.setFocused(h.win, true);
    try h.update();
    try t.expectEqualStrings(".b", try h.eval("focus"));
    try t.expectEqualStrings("in", try log(&h));
    try t.expect(!h.app.root.?.state.background);
}

test "focus: a deleted focus widget leaves no pointer" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    _ = try h.eval("focus .b; destroy .b");
    try t.expectEqualStrings(".", try h.eval("focus -lastfor ."));
    _ = try h.eval("bind . <Key> {lappend log top}");
    try h.head.press(h.win, "x");
    try h.update();
    try t.expectEqualStrings("top", try log(&h));
}
