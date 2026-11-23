//! Tests of the widget tree: `frame`, `destroy`, and `winfo`.
//! Each expected message is the text of `wish` 8.6.16.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Harness = @import("../testing.zig").Harness;
const t = std.testing;

test "widget: frame returns its path, winfo describes the tree" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try t.expectEqualStrings(".a", try h.eval("frame .a"));
    _ = try h.eval("frame .a.b");
    try t.expectEqualStrings(".a", try h.eval("winfo children ."));
    try t.expectEqualStrings(".a.b", try h.eval("winfo children .a"));
    try t.expectEqualStrings(".a", try h.eval("winfo parent .a.b"));
    try t.expectEqualStrings("", try h.eval("winfo parent ."));
    try t.expectEqualStrings("Frame", try h.eval("winfo class .a"));
    try t.expectEqualStrings("Ztk", try h.eval("winfo class ."));
    try t.expectEqualStrings("b", try h.eval("winfo name .a.b"));
    try t.expectEqualStrings("ztk", try h.eval("winfo name ."));
    try t.expectEqualStrings(".", try h.eval("winfo toplevel .a.b"));
    try t.expectEqualStrings("1", try h.eval("winfo exists .a.b"));
    try t.expectEqualStrings("0", try h.eval("winfo exists nosuch"));
}

test "widget: winfo children keeps the stacking order" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("frame .c; frame .a; frame .b");
    try t.expectEqualStrings(".c .a .b", try h.eval("winfo children ."));
}

test "widget: path errors" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try t.expectEqualStrings("bad window path name \".x\"", try h.evalError("frame .x.y"));
    try t.expectEqualStrings("window name starts with an upper-case letter: \"Bad\"", try h.evalError("frame .Bad"));
    _ = try h.eval("frame .a");
    try t.expectEqualStrings("window name \"a\" already exists in parent", try h.evalError("frame .a"));
    try t.expectEqualStrings("window name \"\" already exists in parent", try h.evalError("frame ."));
    try t.expectEqualStrings("bad window path name \"x\"", try h.evalError("frame x"));
    try t.expectEqualStrings("wrong # args: should be \"frame pathName ?-option value ...?\"", try h.evalError("frame"));
    try t.expectEqualStrings("unknown option \"bogus\"", try h.evalError("frame .q bogus"));
}

test "widget: winfo errors" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try t.expectEqualStrings("bad window path name \".nosuch\"", try h.evalError("winfo children .nosuch"));
    try t.expectEqualStrings("wrong # args: should be \"winfo option ?arg?\"", try h.evalError("winfo"));
    try t.expectEqualStrings("wrong # args: should be \"winfo children window\"", try h.evalError("winfo children"));
    try t.expectEqualStrings("wrong # args: should be \"winfo exists window\"", try h.evalError("winfo exists"));
    const m = try h.evalError("winfo bogus");
    try t.expect(std.mem.startsWith(u8, m, "bad option \"bogus\": must be cells, children, class, colormapfull,"));
    try t.expect(std.mem.endsWith(u8, m, "rgb, or visualsavailable"));
}

test "widget: widget command errors" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("frame .a");
    try t.expectEqualStrings("bad option \"bogus\": must be cget or configure", try h.evalError(".a bogus"));
    try t.expectEqualStrings("wrong # args: should be \".a option ?arg ...?\"", try h.evalError(".a"));
}

test "widget: destroy removes the subtree and the commands" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("frame .a; frame .a.b");
    _ = try h.eval("destroy .a");
    try t.expectEqualStrings("0", try h.eval("winfo exists .a.b"));
    try t.expectEqualStrings("0", try h.eval("winfo exists .a"));
    try t.expectEqualStrings("0", try h.eval("llength [info commands .a*]"));
    try t.expectEqualStrings("", try h.eval("destroy .nosuch"));
    try t.expectEqualStrings("", try h.eval("winfo children ."));
}

test "widget: destroy . removes all widgets" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("frame .a; frame .a.b");
    _ = try h.eval("destroy .");
    try t.expect(h.app.root == null);
    try t.expectEqualStrings("0", try h.eval("winfo exists ."));
}

test "widget: a widget that a command deletes in its own callback stays valid until sweep" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("frame .a");
    h.app.enter();
    _ = try h.eval("destroy .a");
    try t.expectEqual(@as(usize, 1), h.app.dead.len);
    h.app.leave();
    try t.expectEqual(@as(usize, 0), h.app.dead.len);
}

test "widget: 1000 frames in a tree free with no leak" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("for {set i 0} {$i < 10} {incr i} { frame .g$i; for {set j 0} {$j < 99} {incr j} { frame .g$i.f$j } }");
    try t.expectEqual(@as(usize, 1001), h.app.widgets.count());
    _ = try h.eval("destroy .");
    try t.expectEqual(@as(usize, 0), h.app.widgets.count());
}
