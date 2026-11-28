//! Tests of task 04: a second toplevel with its own window, `grab`,
//! `labelframe`, `message`, and `ztk::tooltip`. The expected texts are
//! from `wish` 8.6.16.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Harness = @import("../testing.zig").Harness;
const t = std.testing;

test "toplevel: a second window with its own layout, wm state, and events" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval(
        \\set n 0
        \\toplevel .t; wm title .t "Second"
        \\button .t.b -text Go -command {incr n}; pack .t.b -padx 20 -pady 20
        \\update
    );
    try t.expectEqualStrings(".t Toplevel Second 1", try h.eval("list [winfo toplevel .t.b] [winfo class .t] [wm title .t] [winfo ismapped .t.b]"));
    try t.expectEqualStrings("ztk", try h.eval("wm title ."));
    try t.expectEqualStrings("u", try h.eval("toplevel .u; wm title .u"));
    const top = h.app.find(".t").?;
    const win = h.app.winOf(top).?;
    try t.expect(win != h.win);
    // The window takes the requested size of its content.
    try t.expectEqual(top.req.w, win.size.w);
    // A click in the second window goes to the button in it.
    const b = h.app.find(".t.b").?;
    h.head.click(win, @floatFromInt(b.geom.x + 4), @floatFromInt(b.geom.y + 4));
    try h.update();
    try t.expectEqualStrings("1", try h.eval("set n"));
    // The second window draws its own frames.
    try t.expect(h.head.image(win) != null);
    try t.expectEqualStrings("can't modify -class option after widget is created", try h.evalError(".t configure -class Foo"));
    try t.expectEqualStrings("window name \"t\" already exists in parent", try h.evalError("toplevel .t"));
    _ = try h.eval("destroy .t; update");
    try t.expectEqualStrings("0", try h.eval("winfo exists .t"));
    try t.expectEqual(@as(usize, 1), h.app.tops.items.len);
    _ = try h.eval("toplevel .d -class Dialog");
    try t.expectEqualStrings("Dialog", try h.eval("winfo class .d"));
}

test "toplevel: grab sends the pointer to the grab tree" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval(
        \\set log {}
        \\frame .g -width 60 -height 40; frame .o -width 60 -height 40; pack .g .o
        \\bind .g <Button-1> {lappend log g}; bind .o <Button-1> {lappend log o}
        \\update
    );
    const o = h.app.find(".o").?;
    h.head.click(h.win, @floatFromInt(o.geom.x + 5), @floatFromInt(o.geom.y + 5));
    try h.update();
    _ = try h.eval("grab .g");
    try t.expectEqualStrings(".g", try h.eval("grab current"));
    try t.expectEqualStrings("local", try h.eval("grab status .g"));
    try t.expectEqualStrings("none", try h.eval("grab status .o"));
    h.head.click(h.win, @floatFromInt(o.geom.x + 5), @floatFromInt(o.geom.y + 5));
    try h.update();
    _ = try h.eval("grab release .g");
    try t.expectEqualStrings("", try h.eval("grab current"));
    try t.expectEqualStrings("o g", try h.eval("set log"));
    const cases = [_][2][]const u8{
        .{ "grab", "wrong # args: should be \"grab ?-global? window\" or \"grab option ?arg ...?\"" },
        .{ "grab bogus .", "bad option \"bogus\": must be current, release, set, or status" },
        .{ "grab set .zz", "bad window path name \".zz\"" },
    };
    for (cases) |c| try t.expectEqualStrings(c[1], try h.evalError(c[0]));
}

test "toplevel: labelframe keeps its content below the title" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("labelframe .f -text Options; label .f.l -text Inside; pack .f.l; pack .f; update");
    const l = h.app.find(".f.l").?;
    // The title is above the content.
    try t.expect(l.geom.y > 12);
    try t.expectEqualStrings("-labelanchor labelAnchor LabelAnchor nw nw", try h.eval(".f configure -labelanchor"));
    try t.expectEqualStrings("bad labelanchor \"q\": must be e, en, es, n, ne, nw, s, se, sw, w, wn, or ws", try h.evalError(".f configure -labelanchor q"));
    try t.expectEqualStrings("bad option \"bogus\": must be cget or configure", try h.evalError(".f bogus"));
    _ = try h.eval(".f configure -labelanchor sw; update");
    try t.expect(l.geom.y < 12);
}

test "toplevel: message breaks its text by -width and by -aspect" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval(
        \\message .m -text "The quick brown fox jumps over the lazy dog and keeps going for a while."
        \\message .n -width 100 -text "A short line, then more words."
        \\pack .m .n; update
    );
    // A wide message: the width is at least 1.5 times the height.
    try t.expectEqualStrings("1", try h.eval("expr {[winfo reqwidth .m] * 100 >= 150 * [winfo reqheight .m]}"));
    try t.expectEqualStrings("100", try h.eval("winfo reqwidth .n"));
    try t.expectEqualStrings("expected integer but got \"x\"", try h.evalError("message .q -aspect x"));
    try t.expectEqualStrings("-padx padX Pad -1 -1", try h.eval(".m configure -padx"));
    try t.expectEqualStrings("left", try h.eval(".m cget -justify"));
}

test "toplevel: a tooltip shows after 600 ms and hides on a leave" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("button .b -text Save; pack .b -padx 30 -pady 30; ztk::tooltip .b {Saves the file}; update");
    try t.expectEqualStrings("Saves the file", try h.eval("ztk::tooltip .b"));
    const b = h.app.find(".b").?;
    h.head.pointerMove(h.win, @floatFromInt(b.geom.x + 4), @floatFromInt(b.geom.y + 4));
    try h.update();
    try t.expect(!h.app.tip.shown);
    h.head.advance(700);
    try h.update();
    try t.expect(h.app.tip.shown);
    h.head.pointerMove(h.win, 1, 1);
    try h.update();
    try t.expect(!h.app.tip.shown);
    _ = try h.eval("ztk::tooltip .b {}");
    try t.expectEqualStrings("", try h.eval("ztk::tooltip .b"));
}

test "toplevel: tk_focusFollowsMouse" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("entry .a; entry .b; pack .a .b; update; tk_focusFollowsMouse");
    const b = h.app.find(".b").?;
    h.head.pointerMove(h.win, @floatFromInt(b.geom.x + 4), @floatFromInt(b.geom.y + 4));
    try h.update();
    try t.expectEqualStrings(".b", try h.eval("focus"));
}

test "toplevel: wm geometry has grid units for a toplevel with a grid" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval(
        \\text .t -setgrid 1 -width 40 -height 10
        \\pack .t -fill both -expand 1
        \\update
        \\set f [.t cget -font]
        \\set cw [font measure $f 0]; set lh [font metrics $f -linespace]
        \\set w0 [winfo width .t]; set h0 [winfo height .t]
        \\proc size {top} { lindex [split [wm geometry $top] +] 0 }
        \\proc grew {} { global w0 h0 cw lh; list [expr {([winfo width .t] - $w0) / $cw}] [expr {([winfo height .t] - $h0) / $lh}] }
        \\toplevel .p; frame .p.f -width 200 -height 100; pack .p.f
        \\wm grid .p 10 5 20 20
        \\update
    );
    // Each expected value is the output of wish 8.6.16.
    const cases = [_][2][]const u8{
        .{ "size .", "40x10" },
        .{ "wm geometry . 60x20; update; size .", "60x20" },
        .{ "grew", "20 10" },
        .{ "wm geometry . 50x12+10+10; update; size .", "50x12" },
        .{ "grew", "10 2" },
        .{ "wm geometry . {}; update; size .", "40x10" },
        .{ "grew", "0 0" },
        .{ "wm grid .p", "10 5 20 20" },
        .{ "size .p", "10x5" },
        .{ "wm geometry .p 12x6; update; size .p", "12x6" },
        .{ "list [winfo width .p] [winfo height .p]", "240 120" },
        .{ "wm grid .p {} {} {} {}; update; wm grid .p", "" },
        .{ "size .p", "240x120" },
    };
    for (cases) |c| {
        t.expectEqualStrings(c[1], try h.eval(c[0])) catch |e| {
            std.debug.print("script {s}\n", .{c[0]});
            return e;
        };
    }
}
