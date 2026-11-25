//! Tests of the `ttk` range widgets: `ttk::combobox`, `ttk::spinbox`,
//! `ttk::scale`, `ttk::scrollbar`, and `ttk::progressbar`. The expected
//! texts are from `wish` 8.6.16. The tests open the list of a combobox
//! with the keys and the pointer, check `<<ComboboxSelected>>`, and
//! check the moves of the list and of the bar at fixed times.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Harness = @import("../testing.zig").Harness;
const combobox = @import("../ttk/combobox.zig");
const t = std.testing;

fn expectAll(h: *Harness, cases: []const [2][]const u8) !void {
    for (cases) |c| t.expectEqualStrings(c[1], try h.eval(c[0])) catch |e| {
        std.debug.print("script: {s}\n", .{c[0]});
        return e;
    };
}

fn expectErrors(h: *Harness, cases: []const [2][]const u8) !void {
    for (cases) |c| t.expectEqualStrings(c[1], try h.evalError(c[0])) catch |e| {
        std.debug.print("script: {s}\n", .{c[0]});
        return e;
    };
}

test "ttk2: the options and the messages of each widget" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try expectAll(&h, &.{
        .{ "ttk::scale .sc; .sc configure", "{-command command Command {} {}} {-variable variable Variable {} {}} {-orient orient Orient horizontal horizontal} {-from from From 0 0} {-to to To 1.0 1.0} {-value value Value 0 0} {-length length Length 100 100} {-state state State normal normal} {-takefocus takeFocus TakeFocus ttk::takefocus ttk::takefocus} {-cursor cursor Cursor {} {}} {-style style Style {} {}} {-class {} {} {} {}}" },
        .{ "ttk::scrollbar .sb; .sb configure", "{-command command Command {} {}} {-orient orient Orient vertical vertical} {-takefocus takeFocus TakeFocus {} {}} {-cursor cursor Cursor {} {}} {-style style Style {} {}} {-class {} {} {} {}}" },
        .{ "ttk::progressbar .pb; .pb configure", "{-orient orient Orient horizontal horizontal} {-length length Length 100 100} {-mode mode ProgressMode determinate determinate} {-maximum maximum Maximum 100 100} {-variable variable Variable {} {}} {-value value Value 0.0 0.0} {-phase phase Phase 0 0} {-takefocus takeFocus TakeFocus {} {}} {-cursor cursor Cursor {} {}} {-style style Style {} {}} {-class {} {} {} {}}" },
        .{ "ttk::combobox .cb; lrange [.cb configure] 0 2", "{-height height Height 10 10} {-postcommand postCommand PostCommand {} {}} {-values values Values {} {}}" },
        .{ "ttk::spinbox .sp; lrange [.sp configure] 0 6", "{-values values Values {} {}} {-from from From 0 0} {-to to To 0 0} {-increment increment Increment 1 1} {-format format Format {} {}} {-command command Command {} {}} {-wrap wrap Wrap 0 0}" },
        .{ "list [winfo class .cb] [winfo class .sp] [winfo class .sc] [winfo class .sb] [winfo class .pb]", "TCombobox TSpinbox TScale TScrollbar TProgressbar" },
        .{ ".cb configure -height x; .cb cget -height", "x" },
    });
    try expectErrors(&h, &.{
        .{ ".cb bogus", "bad command \"bogus\": must be bbox, cget, configure, current, delete, get, icursor, identify, index, insert, instate, selection, state, set, validate, or xview" },
        .{ ".sp bogus", "bad command \"bogus\": must be bbox, cget, configure, delete, get, icursor, identify, index, insert, instate, selection, state, set, validate, or xview" },
        .{ ".sc bogus", "bad command \"bogus\": must be configure, cget, state, instate, identify, set, get, or coords" },
        .{ ".sb bogus", "bad command \"bogus\": must be configure, cget, delta, fraction, get, identify, instate, set, or state" },
        .{ ".pb bogus", "bad command \"bogus\": must be configure, cget, identify, instate, start, state, step, or stop" },
        .{ ".cb current 0", "Index 0 out of range" },
        .{ ".cb current x", "Incorrect index x" },
        .{ ".cb set", "wrong # args: should be \".cb set value\"" },
        .{ ".cb current 1 2", "wrong # args: should be \".cb current ?newIndex?\"" },
        .{ ".pb step x", "expected floating-point number but got \"x\"" },
        .{ ".pb configure -mode bogus", "bad mode \"bogus\": must be determinate or indeterminate" },
        .{ ".pb configure -length x", "bad screen distance \"x\"" },
        .{ ".sc set", "wrong # args: should be \".sc set value\"" },
        .{ ".sc get 1", "wrong # args: should be \".sc get ?x y?\"" },
        .{ ".sc configure -orient bogus", "bad orient \"bogus\": must be horizontal or vertical" },
        .{ ".sc configure -value abc", "expected floating-point number but got \"abc\"" },
        .{ ".sb set 1", "wrong # args: should be \".sb set first last\"" },
        .{ ".sb get 1", "wrong # args: should be \".sb get \"" },
        .{ ".sb delta", "wrong # args: should be \".sb delta dx dy\"" },
        .{ ".sb set a b", "expected floating-point number but got \"a\"" },
        .{ ".sp set", "wrong # args: should be \".sp set value\"" },
        .{ ".pb identify", "wrong # args: should be \".pb identify ?what? x y\"" },
    });
}

test "ttk2: values of the scale, the scrollbar, the spin box, and the progress bar" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try expectAll(&h, &.{
        .{ "ttk::scale .sc; .sc get", "0" },
        .{ ".sc set 0.5; .sc get", "0.5" },
        .{ ".sc set 5; list [.sc get] [.sc cget -value]", "1.0 1.0" },
        .{ ".sc set -2; .sc get", "0.0" },
        .{ ".sc configure -value 0.25; .sc get", "0.25" },
        .{ ".sc configure -variable sv; info exists sv", "0" },
        .{ "set sv 0.75; list [.sc get] [.sc cget -value]", "0.75 0.75" },
        .{ ".sc set 0.1; set sv", "0.1" },
        .{ ".sc configure -command {lappend ::cmds} -to 10; .sc set 3; list $::cmds [.sc get]", "3.0 3.0" },
        .{ ".sc state disabled; .sc set 0.5; .sc get", "3.0" },
        .{ "ttk::scrollbar .sb; .sb get", "0.0 1.0" },
        .{ ".sb set 0.2 0.4; .sb get", "0.2 0.4" },
        .{ "ttk::spinbox .sp -values {a b c}; .sp get", "" },
        .{ ".sp set b; event generate .sp <<Increment>>; .sp get", "c" },
        .{ ".sp configure -values {} -from 0 -to 5 -format %.2f; .sp set 2; event generate .sp <<Increment>>; .sp get", "3.00" },
        .{ ".sp configure -wrap 1; .sp set 5; event generate .sp <<Increment>>; .sp get", "0.00" },
        .{ "ttk::progressbar .pb; .pb step; .pb cget -value", "1.0" },
        .{ ".pb step 150; .pb cget -value", "51.0" },
        .{ ".pb configure -value 120; .pb cget -value", "120" },
        .{ ".pb step; .pb cget -value", "21.0" },
        .{ ".pb configure -variable pv; info exists pv", "0" },
        .{ "set pv 40; .pb cget -value", "40" },
        .{ ".pb configure -maximum 50; .pb step 20; list [.pb cget -value] $pv", "10.0 10.0" },
        .{ "set pv abc; list [.pb cget -value] [.pb state]", "10.0 invalid" },
        .{ "set pv 5; .pb state", "" },
        .{ ".pb start; list [info exists ::ttk::progressbar::Timers(.pb)] [.pb cget -value]", "1 6.0" },
        .{ ".pb stop; info exists ::ttk::progressbar::Timers(.pb)", "0" },
    });
}

test "ttk2: the combobox, its list with the keys and the pointer, and <<ComboboxSelected>>" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try expectAll(&h, &.{
        .{ "ttk::combobox .cb -values {apple banana cherry}; .cb current", "-1" },
        .{ ".cb current 2; list [.cb get] [.cb current]", "cherry 2" },
        .{ ".cb set zz; .cb current", "-1" },
        .{ ".cb current end; .cb get", "cherry" },
        .{ ".cb configure -textvariable tv; info exists tv", "0" },
        .{ ".cb set apple; pack .cb; update; bind .cb <<ComboboxSelected>> {lappend ::sel [.cb get]}; .cb identify 2 2", "textarea" },
        .{ ".cb identify [expr {[winfo width .cb] - 6}] 6", "downarrow" },
        // The keys: Down opens the list on the current row, Down moves, Return selects.
        .{ "event generate .cb <Key-Down>; list [grab current] [.cb instate pressed]", ".cb 1" },
        .{ "event generate .cb <Key-Down>; event generate .cb <Key-Return>; list [.cb get] $::sel [grab current]", "banana banana {}" },
        .{ ".cb selection present", "1" },
        // Escape closes the list with no change.
        .{ "event generate .cb <Key-Down>; event generate .cb <Key-Up>; event generate .cb <Key-Escape>; list [.cb get] [grab current]", "banana {}" },
        // The pointer: a press on the arrow opens the list, and a press on a row selects it.
        .{ "set x [expr {[winfo width .cb] - 6}]; event generate .cb <Button-1> -x $x -y 6; event generate .cb <ButtonRelease-1> -x $x -y 6; grab current", ".cb" },
        .{ "event generate .cb <Motion> -x 10 -y [expr {[winfo height .cb] + 10}]; event generate .cb <Button-1> -x 10 -y [expr {[winfo height .cb] + 10}]; list [.cb get] $::sel", "apple {banana apple}" },
        // A press outside the list closes it.
        .{ "event generate .cb <Button-1> -x $x -y 6; event generate .cb <ButtonRelease-1> -x $x -y 6; event generate .cb <Button-1> -x 2 -y 400; list [grab current] [.cb get]", "{} apple" },
        // A readonly combobox opens on a press anywhere. -postcommand runs first.
        .{ ".cb configure -state readonly -postcommand {.cb configure -values {x y}}; event generate .cb <Button-1> -x 4 -y 4; list [grab current] [.cb cget -values]", ".cb {x y}" },
        .{ "destroy .cb; grab current", "" },
        .{ "ttk::combobox .e -state disabled -values {a}; pack .e; update; event generate .e <Key-Down>; grab current", "" },
    });
}

test "ttk2: the list fades in, a close starts from the shown point, and the bar eases" {
    var h: Harness = undefined;
    try h.initAnimated();
    defer h.deinit();
    _ = try h.eval("ttk::combobox .cb -values {a b c}; ttk::progressbar .pb; pack .cb .pb; update");
    _ = try h.eval("event generate .cb <Key-Down>; update");
    const pd = &h.app.popdown;
    // A frame in the middle of the open move.
    h.head.advance(75);
    try h.update();
    const mid = combobox.openness(pd, h.app.platform.nowUs());
    try t.expect(mid > 0.3 and mid < 0.99);
    // A close during the move starts from the shown point.
    _ = try h.eval("event generate .cb <Key-Escape>");
    try t.expect(pd.closing);
    try t.expectApproxEqAbs(mid, combobox.openness(pd, h.app.platform.nowUs()), 0.01);
    // The end: the timer removes the list.
    h.head.advance(400);
    try h.update();
    try t.expect(pd.widget == null);
    // The determinate bar eases to a new value.
    _ = try h.eval(".pb configure -value 0; update; .pb step 50");
    const pb = h.app.find(".pb").?;
    h.head.advance(100);
    try h.update();
    const shown = @import("../ttk/range.zig").shownValue(pb);
    try t.expect(shown > 5 and shown < 50);
    h.head.advance(400);
    try h.update();
    try t.expectEqual(@as(f64, 50), @import("../ttk/range.zig").shownValue(pb));
}
