//! Tests of the scrollbar and of the scroll protocol: the options, `set`
//! and `get`, `fraction`, `delta`, `identify`, `activate`, the text of
//! `-command`, the wheel, an entry with a long text that scrolls with its
//! scrollbar, the ease of `xview moveto`, the momentum of fine steps, and
//! the drag of the thumb on the render thread. The messages are from
//! `wish` 8.6.16.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Harness = @import("../testing.zig").Harness;
const scene = @import("../scene.zig");
const t = std.testing;

test "scrollbar: options and the messages of wish" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("scrollbar .s");
    try t.expectEqualStrings("-orient orient Orient vertical vertical", try h.eval(".s configure -orient"));
    try t.expectEqualStrings("-width width Width 11 11", try h.eval(".s configure -width"));
    try t.expectEqualStrings("-jump jump Jump 0 0", try h.eval(".s configure -jump"));
    try t.expectEqualStrings("-elementborderwidth elementBorderWidth BorderWidth -1 -1", try h.eval(".s configure -elementborderwidth"));
    try t.expectEqualStrings("-highlightthickness highlightThickness HighlightThickness 0 0", try h.eval(".s configure -highlightthickness"));
    try t.expectEqualStrings("0.0 1.0", try h.eval(".s get"));
    try t.expectEqualStrings("13 4", try h.eval("update; list [winfo reqwidth .s] [winfo reqheight .s]"));
    const cases = [_][2][]const u8{
        .{ ".s bogus", "bad option \"bogus\": must be activate, cget, configure, delta, fraction, get, identify, or set" },
        .{ ".s set 1", "wrong # args: should be \".s set firstFraction lastFraction\" or \".s set totalUnits windowUnits firstUnit lastUnit\"" },
        .{ ".s get 1", "wrong # args: should be \".s get\"" },
        .{ ".s fraction 1", "wrong # args: should be \".s fraction x y\"" },
        .{ ".s delta 1", "wrong # args: should be \".s delta xDelta yDelta\"" },
        .{ ".s identify 1", "wrong # args: should be \".s identify x y\"" },
        .{ ".s activate 1 2", "wrong # args: should be \".s activate element\"" },
        .{ ".s set x 1", "expected floating-point number but got \"x\"" },
        .{ ".s fraction x 1", "expected integer but got \"x\"" },
        .{ ".s configure -orient q", "bad orientation \"q\": must be vertical or horizontal" },
        .{ ".s configure -jump q", "expected boolean value but got \"q\"" },
        .{ ".s set 0.2 0.5 0.1 0.2", "expected integer but got \"0.2\"" },
    };
    for (cases) |c| try t.expectEqualStrings(c[1], try h.evalError(c[0]));
    _ = try h.eval(".s set 0.2 0.5");
    try t.expectEqualStrings("0.2 0.5", try h.eval(".s get"));
    _ = try h.eval(".s set 100 10 20 29");
    try t.expectEqualStrings("100 10 20 29", try h.eval(".s get"));
    try t.expectEqualStrings("", try h.eval(".s activate"));
    _ = try h.eval(".s activate slider");
    try t.expectEqualStrings("slider", try h.eval(".s activate"));
    _ = try h.eval(".s activate bogus");
    try t.expectEqualStrings("", try h.eval(".s activate"));
}

test "scrollbar: identify, fraction, delta, and the text of -command" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("set log {}; scrollbar .s -borderwidth 0 -command {lappend log}; place .s -x 0 -y 0 -width 12 -height 200; update; .s set 0.2 0.5");
    try t.expectEqualStrings("trough1", try h.eval(".s identify 5 20"));
    try t.expectEqualStrings("slider", try h.eval(".s identify 5 80"));
    try t.expectEqualStrings("trough2", try h.eval(".s identify 5 150"));
    try t.expectEqualStrings("", try h.eval(".s identify 50 80"));
    try t.expectEqualStrings("0.5", try h.eval(".s fraction 5 100"));
    try t.expectEqualStrings("0.0", try h.eval(".s fraction 5 -10"));
    try t.expectEqualStrings("0.05", try h.eval(".s delta 0 10"));
    // A press on the trough scrolls one page, and the wheel scrolls units.
    h.head.click(h.win, 5, 150);
    try h.update();
    h.head.click(h.win, 5, 20);
    try h.update();
    try t.expectEqualStrings("scroll 1 pages scroll -1 pages", try h.eval("set log"));
    _ = try h.eval("set log {}; event generate .s <MouseWheel> -delta -120; event generate .s <MouseWheel> -delta 60");
    try t.expectEqualStrings("scroll 4 units scroll -2 units", try h.eval("set log"));
    _ = try h.eval("set log {}; event generate .s <MouseWheel> -delta -12");
    try t.expectEqualStrings("scroll 0.4 units", try h.eval("set log"));
    // A wheel event of the backend goes to the widget under the pointer.
    _ = try h.eval("set log {}");
    h.head.pointerMove(h.win, 5, 100);
    h.head.pointerScroll(h.win, 0, 1);
    try h.update();
    try t.expectEqualStrings("scroll 4 units", try h.eval("set log"));
    // The keys, button 2, and a drag of the thumb.
    _ = try h.eval("set log {}; focus .s; update");
    try h.head.press(h.win, "Down");
    try h.head.press(h.win, "Next");
    try h.head.press(h.win, "Home");
    try h.head.press(h.win, "Left");
    try h.update();
    try t.expectEqualStrings("scroll 1 units scroll 1 pages moveto 0.0", try h.eval("set log"));
    _ = try h.eval("set log {}; event generate .s <Button-2> -x 5 -y 100; event generate .s <ButtonRelease-2> -x 5 -y 100");
    try t.expectEqualStrings("moveto 0.35", try h.eval("set log"));
    _ = try h.eval("set log {}");
    h.head.pointerMove(h.win, 5, 80);
    h.head.pointerButton(h.win, 1, true);
    try h.update();
    h.head.pointerMove(h.win, 5, 100);
    try h.update();
    try t.expectEqualStrings("moveto 0.3", try h.eval("set log"));
    try t.expectEqualStrings("0.3 0.6", try h.eval(".s get"));
    h.head.pointerButton(h.win, 1, false);
    try h.update();
    // The old protocol gives a unit.
    _ = try h.eval("set log {}; .s set 100 10 20 29");
    h.head.click(h.win, 5, 190);
    try h.update();
    try t.expectEqualStrings("29", try h.eval("set log"));
}

test "scrollbar: an entry with a long text scrolls with its scrollbar" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval(
        \\entry .e -width 10 -xscrollcommand {.s set}
        \\scrollbar .s -orient horizontal -command {.e xview}
        \\pack .e .s -fill x
        \\.e insert 0 [string repeat "abcdefghij " 20]
        \\.e icursor 0
        \\update
    );
    const f0 = try h.eval(".e xview");
    try t.expect(std.mem.startsWith(u8, f0, "0.0 0."));
    try t.expectEqualStrings(f0, try h.eval(".s get"));
    try t.expectEqualStrings("bad entry index \"moveto\"", try h.evalError(".e xview moveto"));
    try t.expectEqualStrings("wrong # args: should be \".e xview scroll number units|pages\"", try h.evalError(".e xview scroll 1"));
    try t.expectEqualStrings("bad argument \"foo\": must be units or pages", try h.evalError(".e xview scroll 1 foo"));
    try t.expectEqualStrings("expected floating-point number but got \"x\"", try h.evalError(".e xview moveto x"));
    try t.expectEqualStrings("expected integer but got \"x\"", try h.evalError(".e xview scroll x units"));
    try t.expectEqualStrings("unknown option \"1\": must be moveto or scroll", try h.evalError(".e xview 1 2 3"));
    try t.expectEqualStrings("-xscrollcommand xScrollCommand ScrollCommand {} {.s set}", try h.eval(".e configure -xscrollcommand"));
    // moveto: the view goes there at once for xview, and the scrollbar follows.
    _ = try h.eval(".e xview moveto 0.5; update");
    try t.expect(std.mem.startsWith(u8, try h.eval(".e xview"), "0.5 "));
    try t.expectEqualStrings(try h.eval(".e xview"), try h.eval(".s get"));
    // The end: the last fraction is 1.
    _ = try h.eval(".e xview moveto 1; update");
    const end = try h.eval(".e xview");
    try t.expect(std.mem.endsWith(u8, end, " 1.0"));
    // xview index: the character goes to the left edge, and scroll by units.
    _ = try h.eval(".e xview 0; .e xview scroll 3 units; update");
    const s3 = try h.eval(".e xview");
    try t.expect(!std.mem.startsWith(u8, s3, "0.0 "));
    // A drag of the thumb scrolls the entry.
    _ = try h.eval(".e xview moveto 0; update");
    const sb = h.app.find(".s").?;
    const y: f32 = @floatFromInt(sb.geom.y + @divTrunc(sb.geom.h, 2));
    h.head.pointerMove(h.win, 10, y);
    h.head.pointerButton(h.win, 1, true);
    try h.update();
    h.head.pointerMove(h.win, 40, y);
    try h.update();
    h.head.pointerButton(h.win, 1, false);
    try h.update();
    try t.expect(!std.mem.startsWith(u8, try h.eval(".e xview"), "0.0 "));
    try t.expectEqualStrings(try h.eval(".e xview"), try h.eval(".s get"));
    // Typing moves the view back to the caret.
    _ = try h.eval(".e icursor 0; update");
    try t.expect(std.mem.startsWith(u8, try h.eval(".e xview"), "0.0 "));
}

test "scrollbar: moveto eases, fine steps glide, and a replace starts from the shown place" {
    var h: Harness = undefined;
    try h.initAnimated();
    defer h.deinit();
    _ = try h.eval(
        \\entry .e -width 10
        \\pack .e
        \\.e insert 0 [string repeat "abcdefghij " 40]
        \\.e icursor 0
        \\update
    );
    const scroll = @import("../scroll.zig");
    var v: scroll.View = .{ .total = 1000, .visible = 100 };
    const w = h.app.find(".e").?;
    // The end state at once, a point in the middle at a fixed time.
    v.moveTo(w, 500, scroll.step_us);
    try t.expectEqual(@as(f64, 500), v.pos);
    try t.expectEqual(@as(f64, 0), v.shown(w));
    h.head.advance(80);
    const mid = v.shown(w);
    try t.expect(mid > 250 and mid < 500);
    // A replace during the move starts from the shown place.
    v.moveTo(w, 0, scroll.step_us);
    try t.expectEqual(mid, v.shown(w));
    h.head.advance(200);
    try t.expectEqual(@as(f64, 0), v.shown(w));
    // Fine steps: the view glides on past the sum of the steps.
    var k: usize = 0;
    while (k < 5) : (k += 1) {
        v.scrollBy(w, 10, true);
        h.head.advance(16);
    }
    try t.expect(v.pos > 50);
    h.head.advance(1000);
    try t.expectEqual(v.pos, v.shown(w));
    // A coarse step has no glide.
    const before = v.pos;
    v.scrollBy(w, 40, false);
    try t.expectEqual(before + 40, v.pos);
}

test "scrollbar: the render thread moves the thumb and the entry with the pointer" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval(
        \\entry .e -width 10 -xscrollcommand {.s set}
        \\scrollbar .s -orient horizontal -command {.e xview}
        \\pack .e .s -fill x
        \\.e insert 0 [string repeat "abcdefghij " 20]
        \\.e icursor 0
        \\update
    );
    const sb = h.app.find(".s").?;
    const y: f32 = @floatFromInt(sb.geom.y + @divTrunc(sb.geom.h, 2));
    h.head.pointerMove(h.win, 10, y);
    h.head.pointerButton(h.win, 1, true);
    try h.update();
    h.head.pointerMove(h.win, 12, y);
    try h.update();
    const fr = h.app.render.last orelse return error.SkipZigTest;
    // Two drags: the thumb (gain 1) and the text of the entry (a negative gain).
    var thumb = false;
    var content = false;
    for (fr.drags.items) |d| {
        if (d.gain == 1) thumb = true;
        if (d.gain < 0) content = true;
    }
    try t.expect(thumb and content);
    h.head.pointerButton(h.win, 1, false);
    try h.update();
    try t.expect(h.app.scroll_link == null);
    _ = scene;
}
