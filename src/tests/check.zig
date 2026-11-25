//! Tests of the checkbutton and the radiobutton: the options, the
//! variable in both directions, the subcommands, the class bindings, the
//! states, and the indicator motion. The expected texts are from `wish`
//! 8.6.16.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Harness = @import("../testing.zig").Harness;
const t = std.testing;

fn center(h: *Harness, path: []const u8) [2]f32 {
    const w = h.app.find(path).?;
    return .{ @floatFromInt(w.geom.x + 8), @floatFromInt(w.geom.y + @divTrunc(w.geom.h, 2)) };
}

test "check: options, defaults, and the messages of wish" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("checkbutton .c; radiobutton .r");
    try t.expectEqualStrings("-variable variable Variable {} c", try h.eval(".c configure -variable"));
    try t.expectEqualStrings("selectedButton", try h.eval(".r cget -variable"));
    try t.expectEqualStrings("-onvalue onValue Value 1 1", try h.eval(".c configure -onvalue"));
    try t.expectEqualStrings("-indicatoron indicatorOn IndicatorOn 1 1", try h.eval(".c configure -indicatoron"));
    try t.expectEqualStrings("-tristatevalue tristateValue TristateValue {} {}", try h.eval(".c configure -tristatevalue"));
    try t.expectEqualStrings("-underline underline Underline -1 -1", try h.eval(".r configure -underline"));
    const cases = [_][2][]const u8{
        .{ ".c bogus", "bad option \"bogus\": must be cget, configure, deselect, flash, invoke, select, or toggle" },
        .{ ".r bogus", "bad option \"bogus\": must be cget, configure, deselect, flash, invoke, or select" },
        .{ ".r toggle", "bad option \"toggle\": must be cget, configure, deselect, flash, invoke, or select" },
        .{ ".c invoke x", "wrong # args: should be \".c invoke\"" },
        .{ ".c select x", "wrong # args: should be \".c select\"" },
        .{ ".c configure -state bogus", "bad state \"bogus\": must be active, disabled, or normal" },
        .{ ".c configure -compound q", "bad compound \"q\": must be bottom, center, left, none, right, or top" },
        .{ ".r configure -onvalue 1", "unknown option \"-onvalue\"" },
        .{ ".c configure -value 1", "unknown option \"-value\"" },
    };
    for (cases) |c| try t.expectEqualStrings(c[1], try h.evalError(c[0]));
}

test "check: the variable in both directions" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("checkbutton .c -text C; pack .c; update");
    const c = h.app.find(".c").?;
    try t.expectEqualStrings("0", try h.eval("set c"));
    _ = try h.eval(".c select");
    try t.expectEqualStrings("1", try h.eval("set c"));
    try t.expect(c.state.selected);
    _ = try h.eval(".c toggle");
    try t.expectEqualStrings("0", try h.eval("set c"));
    try t.expect(!c.state.selected);
    _ = try h.eval("set c 1");
    try t.expect(c.state.selected);
    _ = try h.eval(".c configure -onvalue yes");
    try t.expect(!c.state.selected);
    // A new variable that does not exist gets the off value.
    _ = try h.eval("checkbutton .f -variable ff -onvalue on -offvalue off");
    try t.expectEqualStrings("off", try h.eval("set ff"));
    // The tristate value sets the alternate state, and invoke selects.
    _ = try h.eval("checkbutton .t -variable tv -tristatevalue x; set tv x");
    try t.expect(h.app.find(".t").?.state.alternate);
    _ = try h.eval(".t invoke");
    try t.expectEqualStrings("1", try h.eval("set tv"));
    try t.expect(!h.app.find(".t").?.state.alternate);
}

test "check: invoke runs the command and gives its result" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("set log {}; checkbutton .d -variable dd -command {lappend log cmd}; .d invoke; .d invoke");
    try t.expectEqualStrings("cmd cmd 0", try h.eval("list {*}$log $dd"));
    _ = try h.eval(".d configure -state disabled; .d invoke");
    try t.expectEqualStrings("cmd cmd 0", try h.eval("list {*}$log $dd"));
    _ = try h.eval(".d configure -state normal; .d select");
    try t.expectEqualStrings("cmd cmd 1", try h.eval("list {*}$log $dd"));
    _ = try h.eval("checkbutton .e -command {set x 5}");
    try t.expectEqualStrings("5", try h.eval(".e invoke"));
}

test "check: a group of radiobuttons" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("foreach v {a b c} { radiobutton .$v -variable zz -value $v -text $v; pack .$v }; update");
    try t.expectEqualStrings("1 {}", try h.eval("list [info exists zz] $zz"));
    _ = try h.eval(".b invoke");
    try t.expectEqualStrings("b", try h.eval("set zz"));
    try t.expect(h.app.find(".b").?.state.selected);
    try t.expect(!h.app.find(".a").?.state.selected);
    _ = try h.eval("set zz c");
    try t.expect(h.app.find(".c").?.state.selected);
    try t.expect(!h.app.find(".b").?.state.selected);
    _ = try h.eval(".b deselect");
    try t.expectEqualStrings("c", try h.eval("set zz"));
    _ = try h.eval(".c deselect");
    try t.expectEqualStrings("", try h.eval("set zz"));
    // The pointer: a press invokes, as in wish on X11.
    const p = center(&h, ".a");
    h.head.click(h.win, p[0], p[1]);
    try h.update();
    try t.expectEqualStrings("a", try h.eval("set zz"));
}

test "check: the class bindings and the keys" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try t.expectEqualStrings("<<Invoke>> <Button-1> <Enter> <Key-Return> <Key-space> <Leave>", try h.eval("lsort [bind Checkbutton]"));
    try t.expectEqualStrings("<<Invoke>> <Button-1> <Enter> <Key-Return> <Key-space> <Leave>", try h.eval("lsort [bind Radiobutton]"));
    _ = try h.eval("checkbutton .c -text C; pack .c; update; focus .c; update");
    try h.head.press(h.win, "space");
    try h.update();
    try t.expectEqualStrings("1", try h.eval("set c"));
    try h.head.press(h.win, "Return");
    try h.update();
    try t.expectEqualStrings("0", try h.eval("set c"));
    _ = try h.eval("event generate .c <<Invoke>>");
    try t.expectEqualStrings("1", try h.eval("set c"));
    // A disabled checkbutton does not change.
    _ = try h.eval(".c configure -state disabled");
    const p = center(&h, ".c");
    h.head.click(h.win, p[0], p[1]);
    try h.update();
    try t.expectEqualStrings("1", try h.eval("set c"));
    try t.expect(h.app.find(".c").?.state.disabled);
}

test "check: the indicator moves with the transition of the part" {
    var h: Harness = undefined;
    try h.initAnimated();
    defer h.deinit();
    _ = try h.eval(
        \\ztk::style add { Checkbutton::indicator { background-color: #000000; transition: background-color 100ms linear } Checkbutton:checked::indicator { background-color: #ff0000 } }
        \\checkbutton .c -text C; pack .c; update
        \\.c select; update
    );
    h.head.advance(50);
    try h.update();
    // The frame at the middle of the move asks for the next frame.
    const req = h.head.frames_requested;
    h.head.advance(10);
    try h.update();
    try t.expect(h.head.frames_requested > req);
    h.head.advance(500);
    try h.update();
    const done = h.head.frames_requested;
    h.head.advance(500);
    try h.update();
    try t.expectEqual(done, h.head.frames_requested);
}
