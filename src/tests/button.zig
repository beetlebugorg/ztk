//! Tests of the button: its command, the pointer and keyboard paths, the
//! states, and the golden images. The expected texts are from `wish`
//! 8.6.16.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Harness = @import("../testing.zig").Harness;
const testing_h = @import("../testing.zig");
const t = std.testing;

fn setup(h: *Harness) !void {
    try h.init();
    _ = try h.eval("set n 0; button .b -text OK -command {incr n}; grid .b -padx 20 -pady 20; update");
}

fn center(h: *Harness, path: []const u8) [2]f32 {
    const w = h.app.find(path).?;
    return .{ @floatFromInt(w.geom.x + @divTrunc(w.geom.w, 2)), @floatFromInt(w.geom.y + @divTrunc(w.geom.h, 2)) };
}

fn n(h: *Harness) ![]const u8 {
    return h.eval("set n");
}

test "button: invoke, results, and disabled" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    _ = try h.eval(".b invoke; .b invoke");
    try t.expectEqualStrings("2", try n(&h));
    _ = try h.eval("button .r -command {return 7}");
    try t.expectEqualStrings("7", try h.eval(".r invoke"));
    _ = try h.eval(".b configure -state disabled");
    try t.expectEqualStrings("", try h.eval(".b invoke"));
    try t.expectEqualStrings("2", try n(&h));
    try t.expectEqualStrings("wrong # args: should be \".b invoke\"", try h.evalError(".b invoke extra"));
    try t.expectEqualStrings("flash is not supported in this stage", try h.evalError(".b flash"));
    try t.expectEqualStrings("bad option \"foo\": must be cget, configure, flash, or invoke", try h.evalError(".b foo"));
    try t.expectEqualStrings("unknown option \"-image\"", try h.evalError("button .q -image x"));
}

test "button: the pointer paths" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    const c = center(&h, ".b");
    h.head.click(h.win, c[0], c[1]);
    try h.update();
    try t.expectEqualStrings("1", try n(&h));
    try t.expectEqualStrings(".b", try h.eval("focus"));
    // A release outside does not invoke.
    h.head.pointerMove(h.win, c[0], c[1]);
    h.head.pointerButton(h.win, 1, true);
    h.head.pointerMove(h.win, 2, 2);
    h.head.pointerButton(h.win, 1, false);
    try h.update();
    try t.expectEqualStrings("1", try n(&h));
    // A move outside and back before the release does invoke.
    h.head.pointerMove(h.win, c[0], c[1]);
    h.head.pointerButton(h.win, 1, true);
    h.head.pointerMove(h.win, 2, 2);
    try h.update();
    h.head.pointerMove(h.win, c[0], c[1]);
    h.head.pointerButton(h.win, 1, false);
    try h.update();
    try t.expectEqualStrings("2", try n(&h));
    // A disabled button does nothing.
    _ = try h.eval(".b configure -state disabled");
    h.head.click(h.win, c[0], c[1]);
    try h.update();
    try t.expectEqualStrings("2", try n(&h));
}

test "button: the keyboard and the class bindings" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    _ = try h.eval("focus .b");
    try h.head.press(h.win, "space");
    try h.update();
    try t.expectEqualStrings("1", try n(&h));
    try t.expectEqualStrings("<<Invoke>> <Key-space> <ButtonRelease-1> <Button-1> <Leave> <Enter>", try h.eval("bind Button"));
    _ = try h.eval("event generate .b <<Invoke>>");
    try t.expectEqualStrings("2", try n(&h));
    _ = try h.eval("bind .b <1> break");
    const c = center(&h, ".b");
    h.head.click(h.win, c[0], c[1]);
    try h.update();
    try t.expectEqualStrings("2", try n(&h));
}

test "button: a command that deletes the button, and errors" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    _ = try h.eval("button .d -text X -command {destroy .d}; grid .d; update");
    const c = center(&h, ".d");
    h.head.click(h.win, c[0], c[1]);
    try h.update();
    try t.expectEqualStrings("0", try h.eval("winfo exists .d"));
    _ = try h.eval("set log {}; proc bgerror {m} {lappend ::log $m}; button .e -text E -command {error boom}; grid .e; update");
    const e = center(&h, ".e");
    h.head.click(h.win, e[0], e[1]);
    try h.update();
    try t.expectEqualStrings("boom", try h.eval("set log"));
    try t.expectEqualStrings("boom", try h.evalError(".e invoke"));
}

test "button: the state bits and the active colors" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    const b = h.app.find(".b").?;
    const c = center(&h, ".b");
    h.head.pointerMove(h.win, c[0], c[1]);
    h.head.pointerButton(h.win, 1, true);
    try h.update();
    try t.expect(b.state.pressed and b.state.hover);
    h.head.pointerMove(h.win, 2, 2);
    try h.update();
    try t.expect(!b.state.pressed and !b.state.hover);
    h.head.pointerButton(h.win, 1, false);
    try h.update();
    _ = try h.eval(".b configure -activebackground #ff0000");
    h.app.ensureStyle(b);
    var buf: [7]u8 = undefined;
    try t.expect(!std.mem.eql(u8, "#ff0000", b.style.background.formatTk(&buf)));
    h.head.pointerMove(h.win, c[0], c[1]);
    try h.update();
    h.app.ensureStyle(b);
    try t.expectEqualStrings("#ff0000", b.style.background.formatTk(&buf));
}

fn three(h: *Harness) !void {
    try h.init();
    _ = try h.eval("wm geometry . 260x80");
    _ = try h.eval("button .s -text Save; button .c -text Cancel; button .p -text OK; ztk::class .p add primary; grid .s .c .p -padx 8 -pady 20");
}

fn shot(h: *Harness, name: []const u8) !void {
    try h.update();
    try testing_h.expectGolden(name, h.head.image(h.win).?, .{});
    try testing_h.expectScene(name, h.app.lastScene());
}

test "button-normal" {
    var h: Harness = undefined;
    try three(&h);
    defer h.deinit();
    try shot(&h, "button-normal");
}

test "button-hover" {
    var h: Harness = undefined;
    try three(&h);
    defer h.deinit();
    try h.update();
    const c = center(&h, ".s");
    h.head.pointerMove(h.win, c[0], c[1]);
    try shot(&h, "button-hover");
}

test "button-pressed" {
    var h: Harness = undefined;
    try three(&h);
    defer h.deinit();
    try h.update();
    const c = center(&h, ".s");
    h.head.pointerMove(h.win, c[0], c[1]);
    h.head.pointerButton(h.win, 1, true);
    try shot(&h, "button-pressed");
}

test "button-focus" {
    var h: Harness = undefined;
    try three(&h);
    defer h.deinit();
    _ = try h.eval("focus .s");
    try shot(&h, "button-focus");
}

test "button-disabled" {
    var h: Harness = undefined;
    try three(&h);
    defer h.deinit();
    _ = try h.eval(".s configure -state disabled");
    try shot(&h, "button-disabled");
}
