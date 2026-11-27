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

/// The center of a widget in its toplevel, as "x y".
const center = "proc center {w} { lassign [lrange [lsearch -inline -index 0 [ztk::tree .] $w] 2 5] x y ww hh; list [expr {$x + $ww/2}] [expr {$y + $hh/2}] }";

test "debug trace: what ran when a button was clicked" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval(center);
    _ = try h.eval(
        \\button .save -text Save -command {.status configure -text {Saved the file}}
        \\label .status -text Ready
        \\pack .save .status
        \\update
        \\ztk::debug trace start
        \\lassign [center .save] cx cy
        \\ztk::inject . motion $cx $cy
        \\ztk::inject . press 1 $cx $cy
        \\ztk::inject . release 1 $cx $cy
        \\update
    );
    // Motion is off by default.
    try t.expectEqualStrings("", try h.eval("ztk::debug trace records -kind motion"));
    _ = try h.eval("set click [lindex [ztk::debug trace records -kind event -widget .save -match *ButtonRelease* -last 1] 0]");
    try t.expectEqualStrings("<ButtonRelease-1>", try h.eval("dict get $click event"));
    try t.expectEqualStrings("event:.save binding:.save command:.save option:.status dirty:.status", try h.eval(
        \\set out {}
        \\foreach r [ztk::debug trace records -cause [dict get $click seq]] { lappend out [dict get $r kind]:[dict get $r widget] }
        \\join $out
    ));
    // The dirty record names the option write.
    try t.expectEqualStrings("1", try h.eval(
        \\set o [lindex [ztk::debug trace records -kind option -last 1] 0]
        \\set d [lindex [ztk::debug trace records -kind dirty -widget .status -last 1] 0]
        \\expr {[dict get $d by] == [dict get $o seq] && [dict get $o prev] eq "Ready"}
    ));
    // A frame lists the dirty label, and a geometry pass moved it.
    try t.expectEqualStrings("1 1", try h.eval(
        \\set fs [ztk::debug trace records -kind frame]
        \\set gs [ztk::debug trace records -kind geometry]
        \\list [expr {[lsearch [lmap f $fs {expr {".status" in [dict get $f dirty]}}] 1] >= 0}] [expr {[lsearch [lmap g $gs {expr {".status" in [lmap c [dict get $g changed] {lindex $c 0}]}}] 1] >= 0}]
    ));
    // A click on a disabled button gives a command record that did not run.
    _ = try h.eval(".save configure -state disabled; ztk::inject . press 1 $cx $cy; ztk::inject . release 1 $cx $cy");
    try t.expectEqualStrings("0 {the widget is disabled}", try h.eval("set c [lindex [ztk::debug trace records -kind command -last 1] 0]; list [dict get $c ran] [dict get $c why]"));
}

test "debug trace: focus, grab, the ring, and stop" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("entry .e; pack .e; update; ztk::debug trace start -kinds {focus grab} -size 3");
    _ = try h.eval("focus .e; update; grab .e; grab release .e");
    try t.expectEqualStrings("focus:.e grab:set grab:release", try h.eval("join [lmap r [ztk::debug trace records] {expr {[dict get $r kind] eq {focus} ? \"focus:[dict get $r to]\" : \"grab:[dict get $r action]\"}}]"));
    _ = try h.eval("grab .e; grab release .e");
    try t.expectEqualStrings("3 2", try h.eval("set s [ztk::debug trace status]; list [dict get $s count] [dict get $s dropped]"));
    try t.expectEqualStrings("1", try h.eval("llength [ztk::debug trace records -last 1]"));
    _ = try h.eval("ztk::debug trace stop; grab .e");
    try t.expectEqualStrings("0 3", try h.eval("set s [ztk::debug trace status]; list [dict get $s on] [dict get $s count]"));
    _ = try h.eval("ztk::debug trace clear");
    try t.expectEqualStrings("0", try h.eval("dict get [ztk::debug trace status] count"));
    try t.expectEqualStrings("bad kind in \"nope\": must be event, motion, binding, command, option, geometry, dirty, frame, focus, grab, or all", try h.evalError("ztk::debug trace start -kinds nope"));
}
