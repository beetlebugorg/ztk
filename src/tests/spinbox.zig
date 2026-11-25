//! Tests of the spinbox: the options and the messages of `wish`, the
//! range and the list, `-wrap`, `-format`, `-command`, `set`,
//! `identify`, `selection element`, the validation of a set value, the
//! buttons with the pointer and the repeat of a held button, the keys,
//! and the hover transition of a button. The expected texts are from
//! `wish` 8.6.16.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Harness = @import("../testing.zig").Harness;
const entry = @import("../widgets/entry.zig");
const paint = @import("../paint.zig");
const t = std.testing;

test "spinbox: options and the messages of wish" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("spinbox .s");
    const cases = [_][2][]const u8{
        .{ ".s configure -from", "-from from From 0 0.0" },
        .{ ".s configure -increment", "-increment increment Increment 1 1.0" },
        .{ ".s configure -repeatdelay", "-repeatdelay repeatDelay RepeatDelay 400 400" },
        .{ ".s configure -buttondownrelief", "-buttondownrelief buttonDownRelief Relief raised raised" },
        .{ ".s configure -wrap", "-wrap wrap Wrap 0 0" },
        .{ ".s configure -validate", "-validate validate Validate none none" },
        .{ ".s configure -vcmd", "-validatecommand validateCommand ValidateCommand {} {}" },
        .{ ".s get", "" },
        .{ ".s selection element", "none" },
    };
    for (cases) |c| try t.expectEqualStrings(c[1], try h.eval(c[0]));
    const errors = [_][2][]const u8{
        .{ ".s bogus", "bad option \"bogus\": must be bbox, cget, configure, delete, get, icursor, identify, index, insert, invoke, scan, selection, set, validate, or xview" },
        .{ ".s invoke", "wrong # args: should be \".s invoke elemName\"" },
        .{ ".s invoke x", "bad element \"x\": must be none, buttondown, or buttonup" },
        .{ ".s configure -format %q", "bad spinbox format specifier \"%q\"" },
        .{ ".s configure -validate bogus", "bad validate \"bogus\": must be all, key, focus, focusin, focusout, or none" },
        .{ ".s set 1 2", "wrong # args: should be \".s set ?string?\"" },
        .{ ".s identify 1", "wrong # args: should be \".s identify x y\"" },
        .{ ".s identify a 1", "expected integer but got \"a\"" },
        .{ ".s selection bogus", "bad selection option \"bogus\": must be adjust, clear, element, from, present, range, or to" },
        .{ ".s selection element bogus", "bad selection element \"bogus\": must be none, buttondown, or buttonup" },
        .{ ".s selection element buttonup x", "wrong # args: should be \".s selection element ?elemName?\"" },
        .{ ".s configure -from x", "expected floating-point number but got \"x\"" },
        .{ ".s configure -wrap q", "expected boolean value but got \"q\"" },
        .{ ".s configure -buttondownrelief q", "bad relief \"q\": must be flat, groove, raised, ridge, solid, or sunken" },
        .{ ".s index bogus", "bad spinbox index \"bogus\"" },
        .{ "spinbox .f -from 5 -to 1", "-to value must be greater than -from value" },
    };
    for (errors) |c| try t.expectEqualStrings(c[1], try h.evalError(c[0]));
    try t.expectEqualStrings("0", try h.eval("winfo exists .f"));
    // A bad value of an option keeps the value before it.
    _ = try h.eval("spinbox .b -from 1 -to 5 -format %4.1f");
    try t.expectEqualStrings("-to value must be greater than -from value", try h.evalError(".b configure -from 9"));
    try t.expectEqualStrings("1.0 5.0", try h.eval("list [.b cget -from] [.b cget -to]"));
    _ = try h.evalError(".b configure -format %.2q");
    try t.expectEqualStrings("%4.1f", try h.eval(".b cget -format"));
    _ = try h.eval(".s selection element buttonup");
    try t.expectEqualStrings("buttonup", try h.eval(".s selection element"));
}

test "spinbox: the range, the list, wrap, and format" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const script =
        \\proc steps {w args} {set r [list [$w get]]; foreach e $args {$w invoke $e; lappend r [$w get]}; return $r}
        \\spinbox .b -from 1 -to 5
    ;
    _ = try h.eval(script);
    try t.expectEqualStrings("1 2", try h.eval("steps .b buttonup"));
    try t.expectEqualStrings("5 5", try h.eval(".b set 5; steps .b buttonup"));
    try t.expectEqualStrings("5 1 5", try h.eval(".b configure -wrap 1; steps .b buttonup buttondown"));
    // The format of Tk from the range and the increment, and a format of the script.
    const formats = [_][2][]const u8{
        .{ "-from 0 -to 1 -increment 0.25", "0.0 0.2 0.5" },
        .{ "-from 0 -to 100 -increment 5", "0 5 10" },
        .{ "-from -1 -to 1 -increment 0.1", "-1.0 -0.9 -0.8" },
        .{ "-from 0 -to 0.001 -increment 0.0001", "0.0000 0.0001 0.0002" },
        .{ "-from 0 -to 1 -increment 0.25 -format %5.2f", "{ 0.00} { 0.25} { 0.50}" },
    };
    for (formats) |f| {
        const s = try std.fmt.allocPrint(t.allocator, "destroy .c; spinbox .c {s}; steps .c buttonup buttonup", .{f[0]});
        defer t.allocator.free(s);
        try t.expectEqualStrings(f[1], try h.eval(s));
    }
    // A text that is not a number steps from -from; a number past the end stops at the end.
    _ = try h.eval("spinbox .g -from 0 -to 10");
    try t.expectEqualStrings("0", try h.eval(".g set abc; .g invoke buttonup; .g get"));
    try t.expectEqualStrings("10", try h.eval(".g set 9.5; .g invoke buttonup; .g get"));
    try t.expectEqualStrings("5", try h.eval(".g set 3.7; .g invoke buttonup; .g get"));
    _ = try h.eval("spinbox .h -from 0 -to 10 -increment 3");
    try t.expectEqualStrings("10 0", try h.eval(".h set 9; set r [steps .h buttonup]; .h configure -wrap 1; .h invoke buttonup; lappend r [.h get]; lrange $r 1 end"));
    // The list: the index of the shown text, else the last index.
    _ = try h.eval("spinbox .d -values {red green blue}");
    try t.expectEqualStrings("red green red red", try h.eval("steps .d buttonup buttondown buttondown"));
    try t.expectEqualStrings("blue", try h.eval(".d configure -wrap 1; .d invoke buttondown; .d get"));
    try t.expectEqualStrings("red", try h.eval(".d set purple; .d invoke buttonup; .d get"));
    try t.expectEqualStrings("blue", try h.eval(".d set green; .d invoke buttonup; .d get"));
    // A list wins over a range.
    try t.expectEqualStrings("{} x x", try h.eval("spinbox .u -values {}; set r [list [.u get]]; .u configure -values {x y}; lappend r [.u get]; .u configure -from 1 -to 3; lappend r [.u get]"));
    // A disabled spinbox does not step, a read-only one does.
    try t.expectEqualStrings("0 1", try h.eval("spinbox .q -from 0 -to 5 -state disabled; .q invoke buttonup; set r [.q get]; .q configure -state readonly; .q invoke buttonup; lappend r [.q get]"));
    // The variable.
    try t.expectEqualStrings("0 {7 7}", try h.eval("spinbox .x -from 0 -to 10 -textvariable tv; set tv2 7; spinbox .y -from 0 -to 10 -textvariable tv2; list $tv [list $tv2 [.y get]]"));
    try t.expectEqualStrings("3 7", try h.eval(".x set 3; list $tv [.x set 7]"));
}

test "spinbox: -command, the validation of a step, and identify" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval(
        \\set log {}
        \\spinbox .e -from 0 -to 10 -command {lappend log [list %W %s %d %P %%]}
        \\.e invoke buttonup; .e invoke buttondown
    );
    try t.expectEqualStrings("{.e 1 up P %} {.e 0 down P %}", try h.eval("set log"));
    _ = try h.eval(
        \\set log {}
        \\spinbox .i -from 0 -to 10 -validate all -vcmd {lappend log [list %d %i %P %s %S %V]; return 1}
        \\.i invoke buttonup
    );
    try t.expectEqualStrings("{-1 -1 0 {} {} forced} {-1 -1 1 0 {} forced}", try h.eval("set log"));
    _ = try h.eval("spinbox .t -values {a b c}; pack .t; update");
    try t.expectEqualStrings("buttonup buttondown entry {}", try h.eval(
        \\set w [winfo width .t]; set ht [winfo height .t]
        \\list [.t identify [expr {$w-5}] 5] [.t identify [expr {$w-5}] [expr {$ht-4}]] [.t identify 5 5] [.t identify -1 -1]
    ));
}

fn buttonPoint(h: *Harness, path: []const u8, up: bool) ![2]f32 {
    const s = try std.fmt.allocPrint(t.allocator, "set p {s}; set up {d}", .{ path, @intFromBool(up) });
    defer t.allocator.free(s);
    _ = try h.eval(s);
    const r = try h.eval("list [expr {[winfo x $p] + [winfo width $p] - 8}] [expr {[winfo y $p] + ($up ? 5 : [winfo height $p] - 5)}]");
    var it = std.mem.splitScalar(u8, r, ' ');
    const x = try std.fmt.parseFloat(f32, it.next().?);
    const y = try std.fmt.parseFloat(f32, it.next().?);
    return .{ x, y };
}

test "spinbox: the buttons, the repeat of a held button, and the keys" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("spinbox .s -from 0 -to 100 -repeatdelay 400 -repeatinterval 100; pack .s -padx 10 -pady 10; update");
    const up = try buttonPoint(&h, ".s", true);
    const down = try buttonPoint(&h, ".s", false);
    // A click invokes on the release.
    h.head.click(h.win, up[0], up[1]);
    try h.update();
    try t.expectEqualStrings("1", try h.eval(".s get"));
    h.head.click(h.win, down[0], down[1]);
    try h.update();
    try t.expectEqualStrings("0", try h.eval(".s get"));
    // A held button shows as pressed, waits for -repeatdelay, then repeats at -repeatinterval.
    h.head.pointerMove(h.win, up[0], up[1]);
    h.head.pointerButton(h.win, 1, true);
    try h.update();
    try t.expectEqualStrings("buttonup", try h.eval(".s selection element"));
    try t.expectEqualStrings("0", try h.eval(".s get"));
    h.head.advance(410);
    try h.update();
    try t.expectEqualStrings("1", try h.eval(".s get"));
    h.head.advance(100);
    try h.update();
    h.head.advance(100);
    try h.update();
    try t.expectEqualStrings("3", try h.eval(".s get"));
    // Out of the button the repeat does not step. The release after a repeat does not invoke.
    h.head.pointerMove(h.win, up[0] - 60, up[1]);
    try h.update();
    try t.expectEqualStrings("none", try h.eval(".s selection element"));
    h.head.advance(100);
    try h.update();
    try t.expectEqualStrings("3", try h.eval(".s get"));
    h.head.pointerButton(h.win, 1, false);
    try h.update();
    h.head.advance(500);
    try h.update();
    try t.expectEqualStrings("3", try h.eval(".s get"));
    // The keys.
    _ = try h.eval("focus .s; update");
    try h.head.press(h.win, "Up");
    try h.head.press(h.win, "Up");
    try h.head.press(h.win, "Down");
    try h.update();
    try t.expectEqualStrings("4", try h.eval(".s get"));
}

test "spinbox: the hover transition of a button" {
    var h: Harness = undefined;
    try h.initAnimated();
    defer h.deinit();
    _ = try h.eval("spinbox .s -from 0 -to 9; pack .s -padx 10 -pady 10; update");
    const w = h.app.find(".s").?;
    const d = entry.dataOf(w);
    const up = try buttonPoint(&h, ".s", true);
    const rest = entry.partStyleAs(w, "buttonup", &d.up, false, false).background;
    h.head.pointerMove(h.win, up[0], up[1]);
    try h.update();
    try t.expectEqual(entry.Elem.buttonup, d.hover);
    // The end state, a frame in the middle at a fixed time, and a replace from the shown color.
    var fresh: paint.PartAnim = .{};
    const end = entry.partStyleAs(w, "buttonup", &fresh, true, false).background;
    try t.expect(!std.meta.eql(rest, end));
    h.head.advance(60);
    const mid = entry.partStyleAs(w, "buttonup", &d.up, true, false).background;
    try t.expect(!std.meta.eql(mid, rest) and !std.meta.eql(mid, end));
    const back = entry.partStyleAs(w, "buttonup", &d.up, false, false).background;
    try t.expect(std.meta.eql(back, mid));
    h.head.advance(500);
    try t.expect(std.meta.eql(entry.partStyleAs(w, "buttonup", &d.up, false, false).background, rest));
}
