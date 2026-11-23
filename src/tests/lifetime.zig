//! Tests of the widget life states. Each test runs a script that enters
//! widget code from a callback. The testing allocator reports a use of
//! freed memory in Debug, a double free, and a leak. The expected texts
//! are the output of `wish` 8.6.16 for the same script.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Harness = @import("../testing.zig").Harness;
const Watchdog = @import("../testing.zig").Watchdog;
const t = std.testing;

test "life B-A: a Destroy binding of a child that deletes its parent ends" {
    var dog: Watchdog = undefined;
    try dog.start(10_000);
    defer dog.stop();
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("frame .p; frame .p.c; bind .p.c <Destroy> {destroy .p}; destroy .p.c");
    try t.expectEqualStrings("0", try h.eval("winfo exists .p"));
    try t.expectEqualStrings("0", try h.eval("winfo exists .p.c"));
    try t.expectEqualStrings("1", try h.eval("winfo exists ."));
    try h.update();
}

test "life B-A: a Destroy binding that deletes the root during a parent delete ends" {
    var dog: Watchdog = undefined;
    try dog.start(10_000);
    defer dog.stop();
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("frame .p; frame .p.c; bind .p.c <Destroy> {destroy .}; destroy .p");
    try t.expectEqualStrings("0", try h.eval("winfo exists .p"));
    try t.expectEqualStrings("0", try h.eval("winfo exists ."));
    try t.expect(h.app.root == null);
}

test "life B-A: the order of nested Destroy bindings is the order of wish" {
    var dog: Watchdog = undefined;
    try dog.start(10_000);
    defer dog.stop();
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("set log {}; frame .p; frame .p.c; bind .p <Destroy> {lappend log p}; bind .p.c <Destroy> {lappend log in; destroy .p; lappend log out}; destroy .p.c");
    try t.expectEqualStrings("in p out", try h.eval("set log"));
}

test "life: a child loses its parent when an inner delete removes the parent" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("frame .p; frame .p.c; bind .p.c <Destroy> {destroy .p; set ::r [list <[winfo parent .p.c]> <[winfo toplevel .p.c]> <[winfo children .]>]}; destroy .p.c");
    try t.expectEqualStrings("<> <> <>", try h.eval("set r"));
}

test "life B-B: a child of a parent that is being deleted gives the error of wish" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("frame .p; bind .p <Destroy> {catch {frame .p.n} ::m}; destroy .p; update; frame .z");
    try t.expectEqualStrings("can't create window: parent has been destroyed", try h.eval("set m"));
    try t.expectEqualStrings("bad window path name \".p.n\"", try h.evalError("winfo parent .p.n"));
    _ = try h.eval("destroy .p.n");
}

test "life: a widget that is being deleted answers as in wish" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval(
        \\set r {}
        \\frame .a; frame .a.b
        \\bind .a.b <<X>> {lappend r gotX}
        \\bind .a.b <Destroy> {
        \\  lappend r [winfo exists .a.b] [winfo exists .a] [winfo class .a.b] [winfo parent .a.b]
        \\  catch {.a.b cget -width} m; lappend r $m
        \\  catch {frame .a.b.n} m; lappend r $m
        \\  catch {frame .a.b} m; lappend r $m
        \\  catch {event generate .a.b <<X>>} m; lappend r <$m>
        \\  catch {focus .a.b} m; lappend r <$m>
        \\}
        \\destroy .a
    );
    try t.expectEqualStrings("0 0 Frame .a {invalid command name \".a.b\"} {can't create window: parent has been destroyed} {can't create window: parent has been destroyed} <> <>", try h.eval("set r"));
}

test "life: a new parent with the old path during a Destroy binding" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("frame .q; frame .q.r; bind .q.r <Destroy> {destroy .q; frame .q; catch {frame .q.r} ::m}; destroy .q.r");
    try t.expectEqualStrings("window name \"r\" already exists in parent", try h.eval("set m"));
    try t.expectEqualStrings("1", try h.eval("winfo exists .q"));
    try t.expectEqualStrings("0", try h.eval("winfo exists .q.r"));
    _ = try h.eval("frame .q.r");
    try t.expectEqualStrings(".q.r", try h.eval("winfo children .q"));
}

test "life: a widget made again with the same path in one callback keeps its trace" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const label = @import("../widgets/label.zig");
    _ = try h.eval("set v one; label .l -textvariable v; after 0 {destroy .l; label .l -textvariable v}; update; set v two");
    try t.expectEqualStrings("two", label.text(h.app.find(".l").?));
    try t.expectEqual(@as(usize, 1), (try h.it.list(try h.it.eval("trace info variable v"))).len);
}

test "life: a read trace does not run while the write trace of a label runs" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const label = @import("../widgets/label.zig");
    _ = try h.eval("set v 1; label .l -textvariable v; trace add variable v read {destroy .l ;#}; set v 2; update");
    try t.expectEqualStrings("1", try h.eval("winfo exists .l"));
    try t.expectEqualStrings("2", label.text(h.app.find(".l").?));
}

test "life: a read trace that deletes the widget in the second read of configure" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    for ([_][]const u8{ "label", "entry" }) |class| {
        var buf: [256]u8 = undefined;
        const script = try std.fmt.bufPrint(&buf, "unset -nocomplain v; set v 1; set n 0; {s} .x; trace add variable v read {{if {{[incr ::n] == 2}} {{destroy .x}} ;#}}; .x configure -textvariable v; update", .{class});
        _ = try h.eval(script);
        try t.expectEqualStrings("0", try h.eval("winfo exists .x"));
        // Only the trace of the script stays on the variable.
        try t.expectEqual(@as(usize, 1), (try h.it.list(try h.it.eval("trace info variable v"))).len);
        // The dead widget has no variable name, so a late add goes to the empty name.
        try t.expectEqualStrings("", try h.eval("trace info variable {}"));
    }
}

test "life: a trace that deletes the widget during configure -textvariable" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("label .l; entry .e; set a 1; set b 2; trace add variable a read {destroy .l ;#}; trace add variable b read {destroy .e ;#}");
    _ = try h.eval(".l configure -textvariable a -text x; .e configure -textvariable b -width 4; update");
    try t.expectEqualStrings("0 0", try h.eval("list [winfo exists .l] [winfo exists .e]"));
    // No trace of a dead widget stays on the variables.
    try t.expectEqual(@as(usize, 1), (try h.it.list(try h.it.eval("trace info variable a"))).len);
    try t.expectEqual(@as(usize, 1), (try h.it.list(try h.it.eval("trace info variable b"))).len);
}

test "life: an entry deleted by its write trace starts no caret timer" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("entry .e -textvariable v; grid .e; focus .e; update; trace add variable v write {destroy .e ;#}; .e insert 0 x");
    try t.expectEqualStrings("0", try h.eval("winfo exists .e"));
    try t.expectEqualStrings("", try h.eval("after info"));
    h.head.advance(5000);
    try h.update();
    try t.expectEqual(@as(usize, 0), h.app.loop.timers.items.len);
}

test "life: an error in a binding and in a command frees the deleted widget" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("frame .f; bind .f <<X>> {destroy .f; error boom}; event generate .f <<X>>");
    try t.expectEqual(@as(u32, 0), h.app.callback_depth);
    try t.expectEqual(@as(usize, 0), h.app.dead.len);
    _ = try h.evalError("button .b -command {destroy .b; error boom}; .b invoke");
    try t.expectEqual(@as(u32, 0), h.app.callback_depth);
    try t.expectEqual(@as(usize, 0), h.app.dead.len);
}

test "life: a Configure binding that deletes the root ends the frame" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const before = h.app.frames;
    _ = try h.eval("frame .f -width 10 -height 10; grid .f; bind .f <Configure> {destroy .}; update");
    try t.expect(h.app.root == null);
    // The frame stops at the deleted root and draws nothing.
    try t.expectEqual(before, h.app.frames);
}

test "life: grid on a widget in its own Destroy binding leaks no container" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("frame .p; frame .p.a; frame .p.b; grid .p.a; bind .p.b <Destroy> {catch {grid .p.a -row 1}}; destroy .p; update");
    try t.expectEqualStrings("0", try h.eval("winfo exists .p"));
}

// ---- Event delivery ----

test "events M-B: a nested update delivers the queued keys in order" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("set k {}; bind . <KeyPress> {lappend ::k %K; update}");
    try h.head.press(h.win, "a");
    try h.head.press(h.win, "b");
    try h.head.press(h.win, "c");
    try h.update();
    try t.expectEqualStrings("a b c", try h.eval("set k"));
}

test "events M-B: a button release after a nested update reaches the widget" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("set r {}; frame .f -width 50 -height 50; grid .f; update; bind .f <ButtonPress-1> {lappend ::r down; update; lappend ::r up}; bind .f <ButtonRelease-1> {lappend ::r release}");
    h.head.pointerMove(h.win, 10, 10);
    h.head.pointerButton(h.win, 1, true);
    h.head.pointerButton(h.win, 1, false);
    try h.update();
    try t.expectEqualStrings("down release up", try h.eval("set r"));
    try t.expect(h.app.dispatch.grab == null);
    try t.expect(!h.app.find(".f").?.state.pressed);
}

test "events: a motion with no button ends a hold whose release was lost" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("frame .f -width 50 -height 50; frame .g -width 50 -height 50; grid .f .g; update");
    h.head.pointerMove(h.win, 10, 10);
    h.head.pointerButton(h.win, 1, true);
    try h.update();
    try t.expect(h.app.dispatch.grab == h.app.find(".f").?);
    // The backend reports no button, and no release event came.
    h.head.buttons = 0;
    h.head.pointerMove(h.win, 60, 10);
    try h.update();
    try t.expect(h.app.dispatch.grab == null);
    try t.expect(!h.app.find(".f").?.state.pressed);
    try t.expect(h.app.dispatch.hover == h.app.find(".g").?);
}

test "events: a release binding that deletes the root ends the hold" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("frame .f -width 50 -height 50; grid .f; update; bind .f <ButtonRelease-1> {destroy .}");
    h.head.click(h.win, 10, 10);
    try h.update();
    try t.expect(h.app.root == null);
}

test "events: events that a nested update leaves are not delivered twice" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("set n 0; bind . <KeyPress> {incr ::n; update; update}");
    for (0..20) |_| try h.head.press(h.win, "x");
    try h.update();
    try t.expectEqualStrings("20", try h.eval("set n"));
    try t.expectEqual(@as(usize, 0), h.app.events.items.len);
}

// ---- Compaction ----

const churn =
    \\proc churn {n} { global left; set left $n; after 0 step }
    \\proc step {} { global left blob; set blob [string repeat x 200000]; if {[incr left -1] > 0} { after 0 step } else { set ::done 1 } }
;

test "compact M-A: a script trace survives, because the compact does not run" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("set w 1; set n 0; trace add variable w write {incr ::n ;#}");
    _ = try h.eval(churn ++ "\nchurn 60");
    while (h.app.loop.timers.items.len > 0) {
        try h.update();
        _ = h.app.maybeCompact();
    }
    try t.expect(h.it.memUsed() > 8 << 20);
    try t.expectEqual(@as(u32, 0), h.app.script_gen);
    _ = try h.eval("set w 2");
    try t.expectEqualStrings("1", try h.eval("set n"));
}

test "compact: a command trace and an array search stop the compact" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.app.compact_threshold = 0;
    _ = try h.eval("proc f {} {}; set c 0; trace add execution f enter {incr ::c ;#}");
    try t.expect(!h.app.maybeCompact());
    _ = try h.eval("f");
    try t.expectEqualStrings("1", try h.eval("set c"));
    _ = try h.eval("trace remove execution f enter {incr ::c ;#}");
    _ = try h.eval("array set a {x 1}; set id [array startsearch a]");
    h.app.compact_base = 0;
    try t.expect(!h.app.maybeCompact());
    try t.expectEqualStrings("x", try h.eval("array nextelement a $id"));
    _ = try h.eval("array donesearch a $id");
    h.app.compact_base = 0;
    try t.expect(h.app.maybeCompact());
}

test "compact: info script survives a compact" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.app.compact_threshold = 0;
    _ = try h.eval("info script main.tcl");
    try t.expect(h.app.maybeCompact());
    try t.expectEqualStrings("main.tcl", try h.eval("info script"));
}

test "compact M-F: a top-level vwait compacts, and its memory stays flat" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const script = churn ++ "\nset after_wait 0\nchurn 300\nvwait ::done\nset after_wait [expr {$done + 1}]\n";
    try h.app.runScript(script);
    try t.expectEqualStrings("2", try h.eval("set after_wait"));
    try t.expect(h.app.script_gen >= 3);
    // 300 steps of 200 kB are 60 MB. The threshold is 8 MB.
    try t.expect(h.it.memUsed() < 12 << 20);
    try t.expectEqualStrings("", try h.eval("trace info variable ::done"));
}

test "compact: vwait in a body or a proc still waits in place" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.app.runScript(
        \\set log {}
        \\proc w {} { vwait ::a; lappend ::log proc }
        \\after 0 {set ::a 1}
        \\w
        \\after 0 {set ::b 1}
        \\if 1 { vwait ::b; lappend ::log if$::b }
        \\after 0 {set ::c 1}
        \\catch { vwait ::c; lappend ::log catch$::c }
        \\after 0 {set ::d 1}
        \\vwait ::d
        \\lappend log top
    );
    try t.expectEqualStrings("proc if1 catch1 top", try h.eval("set log"));
}

test "compact: the main script keeps return, errors, and a window wait" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.app.runScript("set a 1; return; set a 2");
    try t.expectEqualStrings("1", try h.eval("set a"));
    try t.expectError(error.TclError, h.app.runScript("set b 1\nerror boom\nset b 2"));
    try t.expectEqualStrings("1", try h.eval("set b"));
    try h.app.runScript("frame .f; after 0 {destroy .f}; tkwait window .f; set c 3");
    try t.expectEqualStrings("3", try h.eval("set c"));
    try t.expectError(error.TclError, h.app.runScript("vwait ::never"));
    try t.expectEqualStrings("can't wait for variable \"::never\": would wait forever", try h.it.str(h.it.result));
    try t.expectEqualStrings("", try h.eval("trace info variable ::never"));
}

// ---- Numbers from outside ----

test "numbers M-C: CSS lengths of 1e30px reach no unchecked cast" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("ztk::style add {Label { font-size: 1e30px; border-width: 1e30px; border-radius: 1e30px; outline: 1e30px solid red; outline-offset: 1e30px; box-shadow: 1e30px 1e30px 1e30px 1e30px red }}");
    _ = try h.eval("label .l -text x; grid .l; update");
    const w = h.app.find(".l").?;
    try t.expectEqual(@as(f32, 1024), w.style.font.size);
    try t.expectEqual(@as(f32, 1 << 24), w.style.border_width[0]);
    try t.expect(w.req.w <= 1 << 24 and w.req.h <= 1 << 24);
}

test "numbers M-C: a radius in percent and a negative size are safe" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("ztk::style add {Frame { border-radius: 1e30%; border-width: -1e30px; padding: 1e30px }}");
    _ = try h.eval("frame .f -width 20 -height 20; grid .f; update");
    try t.expectEqual(@as(f32, -(1 << 24)), h.app.find(".f").?.style.radius[0]);
    try t.expectEqual(@as(f32, 0), h.app.find(".f").?.style.border_width[0]);
}

test "numbers M-C: a Tk font size and a huge scaling stay in range" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("catch {tk scaling 1e300}; catch {tk scaling 100000}; label .l -text x -font {Helvetica 10000}; grid .l; update");
    try t.expect(h.app.find(".l").?.req.h <= 1 << 24);
}

test "numbers M-C: 300 grid cells of 2^24 pixels" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("for {set i 0} {$i < 300} {incr i} {frame .f$i -width 16777216 -height 16777216; grid .f$i -row 0 -column $i; grid columnconfigure . $i -minsize 16777216 -pad 16777216 -weight 1048576}; update");
    try t.expect(h.app.root.?.req.w <= 1 << 24);
    _ = try h.eval("grid bbox .; grid location . 100 100");
}

test "numbers M-C: a span and uniform lines of 2^24 pixels" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("for {set i 0} {$i < 40} {incr i} {frame .f$i -width 16777216; grid .f$i -row $i -column 0 -columnspan 3 -ipadx 16777216 -padx 16777216; grid rowconfigure . $i -uniform u -weight 1048576}; update");
    try t.expect(h.app.root.?.req.h <= 1 << 24);
}

test "numbers M-C: a deep tree with large offsets gives no overflow" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const dispatch = @import("../dispatch.zig");
    _ = try h.eval("set p {}; for {set i 0} {$i < 200} {incr i} {append p .a; frame $p}");
    // Each level has the largest offset of the pixel range, so the sum is beyond `i32`.
    var iter = h.app.widgets.valueIterator();
    while (iter.next()) |w| {
        if (w.*.parent == null) continue;
        w.*.geom = .{ .x = -(1 << 24), .y = -(1 << 24), .w = std.math.maxInt(i32), .h = std.math.maxInt(i32) };
        w.*.mapped = true;
    }
    _ = dispatch.widgetAt(h.app.root.?, 0, 0);
    try t.expectEqualStrings(std.fmt.comptimePrint("{d}", .{std.math.minInt(i32)}), try h.eval("winfo rootx $p"));
}

test "numbers M-C: an entry index of the largest integer" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("entry .e; .e insert 0 abc; grid .e; update; .e index @2147483647; .e index @-2147483648");
}

test "compact: a script trace on a namespace variable stops the compact" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.app.compact_threshold = 0;
    _ = try h.eval("namespace eval ::n {variable x 1}; set c 0; trace add variable ::n::x write {incr ::c ;#}");
    try t.expect(!h.app.maybeCompact());
    _ = try h.eval("set ::n::x 2");
    try t.expectEqualStrings("1", try h.eval("set c"));
}

test "life: one call site with a variable command word reaches each widget" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("frame .a -width 11; frame .b -width 22; proc w {p} {$p cget -width}; set r {}; foreach p {.a .b .a} {lappend r [w $p]}");
    try t.expectEqualStrings("11 22 11", try h.eval("set r"));
    _ = try h.eval("destroy .a; frame .a -width 33");
    try t.expectEqualStrings("33", try h.eval("w .a"));
}
