//! Tests of `ztk::debug` on the headless backend.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Harness = @import("../testing.zig").Harness;
const t = std.testing;

test "debug: the source of a configure call in a proc" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval(
        \\ztk::debug sources on
        \\button .b -text Save
        \\proc lock {w} {
        \\    $w configure -state disabled
        \\}
        \\proc init {} { lock .b }
        \\init
    );
    try t.expectEqualStrings("configure {$w configure -state disabled} {.b configure -state disabled} 2 lock normal {{lock .b} init}",
        try h.eval("set d [ztk::debug why .b -state]; dict with d {list $source $code $call $line $proc $prev $stack}"));
    try t.expectEqualStrings("create 1", try h.eval("set d [ztk::debug why .b -text]; dict with d {list $source $count}"));
    // A second write replaces the record and counts up.
    _ = try h.eval(".b configure -state normal");
    try t.expectEqualStrings("2 disabled {}", try h.eval("set d [ztk::debug why .b -state]; dict with d {list $count $prev $stack}"));
    // A synonym gives its target.
    try t.expectEqualStrings("-borderwidth", try h.eval("dict get [ztk::debug why .b -bd] option"));
}

test "debug: no record while off, default, style, and variable sources" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try t.expectEqualStrings("0", try h.eval("ztk::debug sources"));
    _ = try h.eval("set v hi; label .l -textvariable v -foreground red; button .b");
    try t.expectEqualStrings("call", try h.eval("dict get [ztk::debug why .l -foreground] source"));
    try t.expectEqualStrings("variable v", try h.eval("set d [ztk::debug why .l -text]; dict with d {list $source $variable}"));
    try t.expectEqualStrings("default", try h.eval("dict get [ztk::debug why .b -state] source"));
    try t.expectEqualStrings("style theme", try h.eval("set d [ztk::debug why .b -background]; list [dict get $d source] [dict get $d style origin]"));
    // A rule of the app wins over the theme, with its line.
    _ = try h.eval("ztk::style add {\nButton {\n  background-color: #123456;\n}\n}; update");
    try t.expectEqualStrings("app 3 {background-color: #123456}", try h.eval("set s [dict get [ztk::debug why .b -background] style]; list [dict get $s origin] [dict get $s line] [dict get $s decl]"));
    try t.expectEqualStrings("bad window path name \".nope\"", try h.evalError("ztk::debug why .nope"));
}

test "debug: the geometry chain" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("frame .f -width 30 -height 20; pack propagate .f 0; pack .f; label .f.l -text {a long label}; pack .f.l; label .lost -text x");
    try t.expectEqualStrings(".f.l pack 0 .f", try h.eval("lassign [ztk::debug geometry .f.l] a b; list [dict get $a widget] [dict get $a manager] [dict get $b propagate] [dict get $b widget]"));
    try t.expectEqualStrings("1", try h.eval("string match {narrower than requested*} [lindex [dict get [lindex [ztk::debug geometry .f.l] 0] notes] 0]"));
    try t.expectEqualStrings("{not mapped: no geometry manager (pack, grid, or place)}", try h.eval("dict get [lindex [ztk::debug geometry .lost] 0] notes"));
}
