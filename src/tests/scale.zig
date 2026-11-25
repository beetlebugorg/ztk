//! Tests of the scale: the options, `get` and `set` with the resolution
//! and the digits, `coords` and `identify`, the variable, `-command`, the
//! keys, a press on the track, and a drag. The expected texts are from
//! `wish` 8.6.16.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Harness = @import("../testing.zig").Harness;
const t = std.testing;

fn coords(h: *Harness, path: []const u8, value: []const u8) ![2]f32 {
    var buf: [64]u8 = undefined;
    const r = try h.eval(try std.fmt.bufPrint(&buf, "{s} coords {s}", .{ path, value }));
    var it = std.mem.splitScalar(u8, r, ' ');
    const x = try std.fmt.parseFloat(f32, it.next().?);
    const y = try std.fmt.parseFloat(f32, it.next().?);
    const w = h.app.find(path).?;
    var ox: f32 = 0;
    var oy: f32 = 0;
    var p: ?*@import("../widget.zig").Widget = w;
    while (p) |n| : (p = n.parent) {
        if (n.parent == null) break;
        ox += @floatFromInt(n.geom.x);
        oy += @floatFromInt(n.geom.y);
    }
    return .{ x + ox, y + oy };
}

test "scale: options and the messages of wish" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("scale .s");
    try t.expectEqualStrings("-from from From 0 0.0", try h.eval(".s configure -from"));
    try t.expectEqualStrings("-to to To 100 100.0", try h.eval(".s configure -to"));
    try t.expectEqualStrings("-resolution resolution Resolution 1 1.0", try h.eval(".s configure -resolution"));
    try t.expectEqualStrings("-orient orient Orient vertical vertical", try h.eval(".s configure -orient"));
    try t.expectEqualStrings("-length length Length 100 100", try h.eval(".s configure -length"));
    _ = try h.eval(".s configure -from 5");
    try t.expectEqualStrings("5.0", try h.eval(".s cget -from"));
    const cases = [_][2][]const u8{
        .{ ".s bogus", "bad option \"bogus\": must be cget, configure, coords, get, identify, or set" },
        .{ ".s get 1", "wrong # args: should be \".s get ?x y?\"" },
        .{ ".s set", "wrong # args: should be \".s set value\"" },
        .{ ".s coords 1 2 3", "wrong # args: should be \".s coords ?value?\"" },
        .{ ".s identify", "wrong # args: should be \".s identify x y\"" },
        .{ ".s configure -orient q", "bad orient \"q\": must be horizontal or vertical" },
        .{ ".s configure -from x", "expected floating-point number but got \"x\"" },
    };
    for (cases) |c| try t.expectEqualStrings(c[1], try h.evalError(c[0]));
}

test "scale: get and set with the resolution and the digits" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("scale .s -from 0 -to 10 -resolution 0.5; .s set 3.3");
    try t.expectEqualStrings("3.5", try h.eval(".s get"));
    _ = try h.eval(".s configure -digits 3 -resolution 0; .s set 3.14159");
    try t.expectEqualStrings("3.1", try h.eval(".s get"));
    _ = try h.eval(".s configure -digits 0 -resolution 1; .s set 99");
    try t.expectEqualStrings("10", try h.eval(".s get"));
    _ = try h.eval(".s set -4");
    try t.expectEqualStrings("0", try h.eval(".s get"));
}

test "scale: the variable in both directions, and -command" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("set log {}; set v 7; scale .t -variable v -from 0 -to 10 -orient horizontal -command {lappend log}; pack .t; update");
    try t.expectEqualStrings("7", try h.eval(".t get"));
    _ = try h.eval(".t set 2");
    try t.expectEqualStrings("2", try h.eval("set v"));
    _ = try h.eval("set v 9");
    try t.expectEqualStrings("9", try h.eval(".t get"));
    // set does not run the command; a key does.
    try t.expectEqualStrings("", try h.eval("set log"));
    _ = try h.eval("focus .t; update");
    try h.head.press(h.win, "Left");
    try h.update();
    try t.expectEqualStrings("8", try h.eval(".t get"));
    try t.expectEqualStrings("8", try h.eval("set log"));
    try h.head.press(h.win, "End");
    try h.update();
    try t.expectEqualStrings("10", try h.eval("set v"));
    try h.head.press(h.win, "Home");
    try h.update();
    try t.expectEqualStrings("0", try h.eval("set v"));
}

test "scale: coords, identify, a press on the track, and a drag" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("scale .s -from 0 -to 100 -orient horizontal -length 200 -showvalue 0; pack .s -padx 10 -pady 10; update; .s set 50");
    const r = try h.eval(".s coords");
    var it = std.mem.splitScalar(u8, r, ' ');
    const x = try std.fmt.parseInt(i64, it.next().?, 10);
    const y = try std.fmt.parseInt(i64, it.next().?, 10);
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("slider", try h.eval(try std.fmt.bufPrint(&buf, ".s identify {d} {d}", .{ x, y })));
    try t.expectEqualStrings("trough1", try h.eval(try std.fmt.bufPrint(&buf, ".s identify {d} {d}", .{ x - 40, y })));
    try t.expectEqualStrings("trough2", try h.eval(try std.fmt.bufPrint(&buf, ".s identify {d} {d}", .{ x + 40, y })));
    // A press on the track moves one step toward the pointer.
    const p = try coords(&h, ".s", "50");
    h.head.click(h.win, p[0] + 40, p[1]);
    try h.update();
    try t.expectEqualStrings("51", try h.eval(".s get"));
    // A drag of the slider follows the pointer.
    const q = try coords(&h, ".s", "51");
    h.head.pointerMove(h.win, q[0], q[1]);
    h.head.pointerButton(h.win, 1, true);
    try h.update();
    const end = try coords(&h, ".s", "80");
    h.head.pointerMove(h.win, end[0], end[1]);
    try h.update();
    try t.expectEqualStrings("80", try h.eval(".s get"));
    h.head.pointerButton(h.win, 1, false);
    try h.update();
    // A disabled scale does not change.
    _ = try h.eval(".s configure -state disabled; .s set 10");
    try t.expectEqualStrings("80", try h.eval(".s get"));
}
