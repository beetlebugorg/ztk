//! Tests of the frame pipeline, `label`, and `wm`, with golden images.
//! The expected texts are from `wish` 8.6.16. The images are 240 by 120
//! logical pixels, drawn with the modern theme.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Harness = @import("../testing.zig").Harness;
const testing_h = @import("../testing.zig");
const paint = @import("../paint.zig");
const t = std.testing;

fn num(h: *Harness, script: []const u8) !i32 {
    return std.fmt.parseInt(i32, try h.eval(script), 10);
}

fn textWidth(h: *Harness, path: []const u8, text: []const u8) !i32 {
    const w = h.app.find(path).?;
    h.app.ensureStyle(w);
    const ins = paint.insets(&w.style);
    return paint.textSize(h.app, text, w.style.font).w + ins.horizontal();
}

test "frame: a label sizes the window" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("label .l -text Hello; grid .l");
    try t.expectEqualStrings("1", try h.eval("winfo width .l"));
    try h.update();
    const want = try textWidth(&h, ".l", "Hello");
    try t.expect(want > 10);
    try t.expectEqual(want, try num(&h, "winfo reqwidth .l"));
    try t.expectEqualStrings(try h.eval("winfo reqwidth ."), try h.eval("winfo width ."));
    try t.expectEqual(want, try num(&h, "winfo width ."));
}

test "frame: a longer text makes the window wider" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("label .l -text Hi; grid .l; update");
    const before = try num(&h, "winfo width .");
    _ = try h.eval(".l configure -text {A much longer text}; update");
    try t.expect(try num(&h, "winfo width .") > before);
}

test "label: a text variable changes the text and the size" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("set v one; label .m -textvariable v; grid .m; update");
    const w1 = try num(&h, "winfo width .");
    const quads1 = h.app.lastScene().quads.items.len;
    _ = try h.eval("set v {two words}; update");
    try t.expect(try num(&h, "winfo width .") > w1);
    try t.expect(h.app.lastScene().quads.items.len > quads1);
    _ = try h.eval("label .n -textvariable nv -text start");
    try t.expectEqualStrings("start", try h.eval("set nv"));
    _ = try h.eval("destroy .m; set v three; update");
    try t.expectEqualStrings("", h.err.items);
    // An unset variable keeps the last text.
    _ = try h.eval("unset nv; update");
    try t.expectEqualStrings("", h.err.items);
}

test "label: lines, characters, and options" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("label .a -text x; label .b -text {a\nb}; label .w -width 10; label .z -text 0");
    _ = try h.eval("grid .a .b .w .z; update");
    const one = try num(&h, "winfo reqheight .a");
    try t.expectEqual(2 * one, try num(&h, "winfo reqheight .b"));
    const zero = try num(&h, "winfo reqwidth .z");
    try t.expectEqual(10 * zero, try num(&h, "winfo reqwidth .w"));
    try t.expectEqualStrings("image \"x\" doesn't exist", try h.evalError("label .q -image x"));
    try t.expectEqualStrings("bad state \"foo\": must be active, disabled, or normal", try h.evalError(".a configure -state foo"));
    try t.expectEqualStrings("bad anchor \"foo\": must be n, ne, e, se, s, sw, w, nw, or center", try h.evalError(".a configure -anchor foo"));
    try t.expectEqualStrings("bad justification \"foo\": must be left, right, or center", try h.evalError(".a configure -justify foo"));
    try t.expectEqualStrings("expected integer but got \"x\"", try h.evalError(".a configure -width x"));
    try t.expectEqualStrings("expected integer but got \"1.5\"", try h.evalError(".a configure -height 1.5"));
}

test "wm: title, geometry, protocol, and state" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("wm title . Demo");
    try t.expectEqualStrings("Demo", try h.eval("wm title ."));
    _ = try h.eval("wm geometry . 300x200; update");
    try t.expectEqualStrings("300", try h.eval("winfo width ."));
    try t.expectEqualStrings("300x200+0+0", try h.eval("wm geometry ."));
    try t.expectEqualStrings("bad geometry specifier \"bogus\"", try h.evalError("wm geometry . bogus"));
    try t.expectEqualStrings("wrong # args: should be \"wm option window ?arg ...?\"", try h.evalError("wm title"));
    try t.expectEqualStrings("bad window path name \".zz\"", try h.evalError("wm title .zz"));
    try t.expectEqualStrings("bad option \"foo\": must be aspect, attributes, client, colormapwindows, command, deiconify, focusmodel, forget, frame, geometry, grid, group, iconbitmap, iconify, iconmask, iconname, iconphoto, iconposition, iconwindow, manage, maxsize, minsize, overrideredirect, positionfrom, protocol, resizable, sizefrom, stackorder, state, title, transient, or withdraw", try h.evalError("wm foo ."));
    try t.expectEqualStrings("-alpha 1.0 -topmost 0 -zoomed 0 -fullscreen 0 -type {}", try h.eval("wm attributes ."));
    // A backend with no zoomed state keeps the value, and the state stays normal.
    try t.expectEqualStrings("1 normal", try h.eval("wm attributes . -zoomed 1; wm state . zoomed; list [wm attributes . -zoomed] [wm state .]"));
    try t.expectEqualStrings("0", try h.eval("wm attributes . -zoomed 0; wm attributes . -zoomed"));
    try t.expectEqualStrings("bad attribute \"-bogus\": must be -alpha, -topmost, -zoomed, -fullscreen, or -type", try h.evalError("wm attributes . -bogus"));
    try t.expectEqualStrings("normal", try h.eval("wm state ."));
    try t.expectEqualStrings("withdrawn", try h.eval("wm withdraw .; wm state ."));
    try t.expectEqualStrings("normal", try h.eval("wm deiconify .; wm state ."));
    try t.expectEqualStrings("1 1", try h.eval("wm minsize ."));
    try t.expectEqualStrings("1 1", try h.eval("wm resizable ."));
    try t.expectEqualStrings("ztk", try h.eval("tk windowingsystem"));
    try t.expectEqualStrings("unknown or ambiguous subcommand \"bogus\": must be appname, busy, caret, fontchooser, inactive, scaling, useinputmethods, or windowingsystem", try h.evalError("tk bogus"));
}

test "wm: a close event runs the protocol script, or deletes ." {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("wm protocol . WM_DELETE_WINDOW {set closed 1}");
    h.head.close(h.win);
    try h.update();
    try t.expectEqualStrings("1", try h.eval("set closed"));
    try t.expectEqualStrings("1", try h.eval("winfo exists ."));
    _ = try h.eval("wm protocol . WM_DELETE_WINDOW {}");
    h.head.close(h.win);
    try h.update();
    try t.expectEqualStrings("0", try h.eval("winfo exists ."));
}

test "frame: a withdrawn toplevel draws nothing, and an idle frame does no work" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("label .l -text Hello; grid .l; update");
    const drawn = h.head.frames_drawn;
    try t.expect(drawn >= 1);
    _ = try h.eval("update; update");
    try t.expectEqual(drawn, h.head.frames_drawn);
    try t.expect(!(try h.app.frame(h.app.root.?)));
    _ = try h.eval("wm withdraw .; .l configure -text Other; update");
    try t.expectEqual(drawn, h.head.frames_drawn);
    _ = try h.eval("wm deiconify .; update");
    try t.expectEqual(drawn + 1, h.head.frames_drawn);
}

test "frame: a text change of the same size does not arrange again" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("label .a -text one -width 6; label .b -text x; grid .a .b; update");
    const arranged = h.app.arrange_count;
    _ = try h.eval(".a configure -text two; update");
    try t.expectEqual(arranged, h.app.arrange_count);
    _ = try h.eval(".a configure -width 12; update");
    try t.expect(h.app.arrange_count > arranged);
}

test "frame: a resize changes the width of a sticky label" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("label .l -text Hi; grid .l -sticky ew; grid columnconfigure . 0 -weight 1; update");
    const narrow = try num(&h, "winfo width .l");
    h.head.resize(h.win, .{ .w = 400, .h = 300 });
    try h.update();
    try t.expectEqual(@as(i32, 400), try num(&h, "winfo width .l"));
    try t.expect(narrow < 400);
}

test "frame: winfo rootx and rooty add the positions" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("frame .f -width 100 -height 100; label .f.l -text x; grid .f -padx 10 -pady 20; grid .f.l -padx 3 -pady 4; update");
    try t.expectEqual(@as(i32, 10), try num(&h, "winfo x .f"));
    try t.expectEqual(@as(i32, 13), try num(&h, "winfo rootx .f.l"));
    try t.expectEqual(@as(i32, 24), try num(&h, "winfo rooty .f.l"));
    try t.expectEqualStrings("1", try h.eval("winfo ismapped .f.l"));
}

fn showGolden(h: *Harness, name: []const u8) !void {
    try h.update();
    const img = h.head.image(h.win).?;
    try testing_h.expectGolden(name, img, .{});
    try testing_h.expectScene(name, h.app.lastScene());
}

fn start(h: *Harness, script: []const u8) !void {
    try h.init();
    _ = try h.eval("wm geometry . 240x120");
    _ = try h.eval(script);
}

test "label-plain: one label" {
    var h: Harness = undefined;
    try start(&h, "label .l -text {Hello, world}; grid .l -padx 20 -pady 20");
    defer h.deinit();
    try showGolden(&h, "label-plain");
}

test "label-anchor: three anchors in a wide column" {
    var h: Harness = undefined;
    try start(&h, "foreach {n a} {a w b center c e} { label .$n -text $a -anchor $a -bg #dde6f5; grid .$n -sticky ew -pady 3 }; grid columnconfigure . 0 -weight 1");
    defer h.deinit();
    try showGolden(&h, "label-anchor");
}

test "label-colors: colors, a border, and a radius" {
    var h: Harness = undefined;
    try start(&h, "ztk::style add {.card { border: 2px solid #2563eb; border-radius: 8px; padding: 6px }}; label .a -text Colors -fg #ffffff -bg #c0392b; label .b -text Card -bg #fff7d6; ztk::class .b add card; grid .a .b -padx 10 -pady 20");
    defer h.deinit();
    try showGolden(&h, "label-colors");
}

test "label-grid: a 2 by 2 grid with padding" {
    var h: Harness = undefined;
    try start(&h, "foreach {n r c} {a 0 0 b 0 1 c 1 0 d 1 1} { label .$n -text $n$n -bg #e8e8ee; grid .$n -row $r -column $c -padx 8 -pady 6 }");
    defer h.deinit();
    try showGolden(&h, "label-grid");
}

test "label-disabled: a normal and a disabled label" {
    var h: Harness = undefined;
    try start(&h, "label .a -text Normal; label .b -text Disabled -state disabled; grid .a .b -padx 12 -pady 20");
    defer h.deinit();
    try showGolden(&h, "label-disabled");
}

test "label-scale2: the plain label at scale 2" {
    var h: Harness = undefined;
    try start(&h, "label .l -text {Hello, world}; grid .l -padx 20 -pady 20");
    defer h.deinit();
    h.head.setScale(h.win, 2);
    try showGolden(&h, "label-scale2");
}
