//! Regression tests of the first review of the code. Each test runs the exact input
//! of its finding. The testing allocator reports a double free or a leak.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Harness = @import("../testing.zig").Harness;
const Watchdog = @import("../testing.zig").Watchdog;
const t = std.testing;

test "review B1: a renamed widget command goes away with the widget" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("frame .f; rename .f foo; destroy .f; update; frame .g");
    const msg = try h.evalError("foo cget -width");
    try t.expectEqualStrings("invalid command name \"foo\"", msg);
}

test "review B2: a Destroy binding that deletes the widget does not free it twice" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("frame .f; bind .f <Destroy> {destroy .f}; destroy .f; update");
    try t.expectEqualStrings("0", try h.eval("winfo exists .f"));
}

test "review B3: a write trace that deletes the entry during its command" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("entry .e -textvariable v; trace add variable v write {destroy .e ;#}; .e insert 0 x");
    try t.expectEqualStrings("0", try h.eval("winfo exists .e"));
    try h.update();
}

test "review B3: a write trace that deletes a label or a button during configure" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    // The variable is new, so `configure` writes it, and the trace deletes the widget in that write.
    for ([_][]const u8{ "label", "button" }) |class| {
        var buf: [256]u8 = undefined;
        const script = try std.fmt.bufPrint(&buf, "unset -nocomplain nv; {s} .x -text t; trace add variable nv write {{destroy .x ;#}}; .x configure -textvariable nv -text u; update", .{class});
        _ = try h.eval(script);
        try t.expectEqualStrings("0", try h.eval("winfo exists .x"));
        // Only the trace of the script stays: the dead widget added none.
        try t.expectEqual(@as(usize, 1), (try h.it.list(try h.it.eval("trace info variable nv"))).len);
        _ = try h.eval("trace remove variable nv write {destroy .x ;#}");
    }
}

test "review B4: a binding that rebinds itself keeps running its own text" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("frame .f");
    _ = try h.eval("bind .f <<X>> {bind .f <<X>> {}; set a [string repeat z 64]; set out \"still running $a\"}");
    _ = try h.eval("event generate .f <<X>>");
    try t.expectEqualStrings("still running " ++ "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz", try h.eval("set out"));
}

test "review M2: a binding that changes the bindtags does not use freed tag names" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("frame .f; bindtags .f {.f Aaaaaaaaaaaaaaaaaaaaaaa Bbbbbbbbbbbbbbbbbbbbbbbbbb all}");
    _ = try h.eval("bind .f <<X>> {bindtags .f {}; set n 1}; bind Bbbbbbbbbbbbbbbbbbbbbbbbbb <<X>> {set m 1}");
    _ = try h.eval("event generate .f <<X>>");
    try t.expectEqualStrings("1", try h.eval("set m"));
}

test "review M2: more than 16 tags all run" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("frame .f; set tags .f; for {set i 0} {$i < 20} {incr i} {lappend tags t$i}; bindtags .f $tags; set c 0");
    _ = try h.eval("bind t19 <<X>> {set c 1}; event generate .f <<X>>");
    try t.expectEqualStrings("1", try h.eval("set c"));
}

test "review M3: the bindings of a widget go away with the widget" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("frame .f; bind .f <<X>> {set a 1}; destroy .f; frame .f");
    try t.expectEqualStrings("", try h.eval("bind .f"));
    try t.expectEqualStrings("", try h.eval("bind .f <<X>>"));
}

test "review B9 and M10: a real compact keeps the traces, and compiled bindings run again" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const label = @import("../widgets/label.zig");
    _ = try h.eval("set tv one; label .l -textvariable tv; grid .l; entry .e -textvariable ev; grid .e; set k 0; set m 0");
    _ = try h.eval("bind . <Key-a> {incr ::k}; bind . <Motion> {set ::m %x}");
    // Run each binding once, so that the compiled form is in the cache.
    try h.head.press(h.win, "a");
    h.head.pointerMove(h.win, 3, 3);
    try h.update();
    try t.expectEqualStrings("1", try h.eval("set k"));
    try t.expectEqualStrings("3", try h.eval("set m"));
    const gen = h.app.script_gen;
    h.app.compact_threshold = 0;
    try t.expect(h.app.maybeCompact());
    try t.expectEqual(gen +% 1, h.app.script_gen);
    // A label and an entry still follow their variables.
    _ = try h.eval("set tv two; set ev typed");
    try t.expectEqualStrings("two", label.text(h.app.find(".l").?));
    try t.expectEqualStrings("typed", try h.eval(".e get"));
    _ = try h.eval(".e insert end !");
    try t.expectEqualStrings("typed!", try h.eval("set ev"));
    // Each binding still runs, also the one that has a % field.
    try h.head.press(h.win, "a");
    h.head.pointerMove(h.win, 5, 3);
    try h.update();
    try t.expectEqualStrings("2", try h.eval("set k"));
    try t.expectEqualStrings("5", try h.eval("set m"));
    // A second compact keeps one trace for each widget.
    try t.expect(h.app.maybeCompact());
    _ = try h.eval("set tv three");
    try t.expectEqualStrings("three", label.text(h.app.find(".l").?));
    try t.expectEqual(@as(usize, 1), (try h.app.it.list(try h.app.it.eval("trace info variable tv"))).len);
}

test "review B5: deleting . while the render thread draws a large frame" {
    var dog: Watchdog = undefined;
    try dog.start(20_000);
    defer dog.stop();
    var h: Harness = undefined;
    try h.initMode(.threaded);
    defer h.deinit();
    h.head.draw_delay_ms = 60;
    _ = try h.eval("after 0 {destroy .}; wm geometry . 3000x3000; label .l -text hello; grid .l");
    try h.update();
    try t.expectEqualStrings("0", try h.eval("winfo exists ."));
}

test "review B5: closing the App waits for a frame in flight" {
    var dog: Watchdog = undefined;
    try dog.start(20_000);
    defer dog.stop();
    var h: Harness = undefined;
    try h.initMode(.threaded);
    // The harness parts go away one at a time, so the test can read the backend after the App.
    defer h.it.deinit();
    defer h.head.deinit();
    defer h.err.deinit(t.allocator);
    var app_open = true;
    defer if (app_open) h.app.deinit();
    _ = try h.eval("wm geometry . 800x600; label .l -text hello; grid .l; update");
    h.head.draw_delay_ms = 40;
    const started = h.head.draws_started.load(.acquire);
    _ = try h.eval(".l configure -text again");
    try t.expect(try h.app.frame(h.app.root.?));
    // The render thread is inside the draw of this frame when the App closes.
    while (h.head.draws_started.load(.acquire) == started) try std.Thread.yield();
    const drawn_before = h.head.frames_drawn;
    app_open = false;
    h.app.deinit();
    try t.expectEqual(drawn_before + 1, h.head.frames_drawn);
}

test "review B6: a renamed ztk command does not stop the loop" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.evalError("rename ztk::priv::app {}");
    _ = try h.eval("after 0 {}; update");
}

test "review B6: the vwait mark with a negative number is ignored" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("::ztk::priv::vwait -1");
}

test "review B6: event generate with a huge coordinate" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("bind . <1> {set got %x}; event generate . <1> -x 99999999999");
    try t.expectEqualStrings("16777216", try h.eval("set got"));
    _ = try h.eval("event generate . <1> -y -99999999999 -width 99999999999 -height 99999999999 -rootx 99999999999 -rooty 99999999999");
}

test "review B6: a CSS min-width of 1e30px" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("ztk::style add {Label { min-width: 1e30px; min-height: 1e30px; padding: 1e30px }}");
    _ = try h.eval("label .l -text x; grid .l; update");
    try t.expect(h.app.find(".l").?.req.w > 0);
}

test "review B6: an insertontime of the largest integer with focus" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("entry .e -insertontime 9223372036854775807 -insertofftime 9223372036854775807; grid .e; focus .e; update");
    h.head.advance(1000);
    try h.update();
}

test "review B6: a minsize larger than the maxsize" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("wm minsize . 200 200; wm maxsize . 100 100; label .l -text hello; grid .l; update");
    _ = try h.eval("update");
}

test "review M4: a window size has a limit" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("wm geometry . 2000000000x2000000000; label .l -text hello; grid .l; update");
    try t.expect(h.win.size.w <= 8192 and h.win.size.h <= 8192);
}

test "review B8: -textvariable reads the global variable" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const label = @import("../widgets/label.zig");
    _ = try h.eval("set v global; proc mk {} {set v local; label .l -textvariable v; entry .e -textvariable v}; mk");
    try t.expectEqualStrings("global", label.text(h.app.find(".l").?));
    try t.expectEqualStrings("global", try h.eval(".e get"));
    _ = try h.eval("proc setit {} {set v changed}; setit; set ::v again");
    try t.expectEqualStrings("again", label.text(h.app.find(".l").?));
    _ = try h.eval(".e insert end !");
    try t.expectEqualStrings("again!", try h.eval("set ::v"));
}

test "review M5: a widget path with a space or a bracket in a trace script" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const label = @import("../widgets/label.zig");
    _ = try h.eval("set v one; label {.a b} -textvariable v; label .c\\[1\\] -textvariable v; entry .e\\$x -textvariable w");
    _ = try h.eval("set v two; set w typed");
    try t.expectEqualStrings("two", label.text(h.app.find(".a b").?));
    try t.expectEqualStrings("two", label.text(h.app.find(".c[1]").?));
    try t.expectEqualStrings("typed", try h.eval(".e\\$x get"));
}

test "review minor: style load does not follow a link out of the style folder" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "style");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "outside.css", .data = "Frame { background-color: #010203 }" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "style/inside.css", .data = "Frame { background-color: #0a0b0c }" });
    try tmp.dir.symLink(t.io, "../outside.css", "style/link.css", .{});
    try tmp.dir.symLink(t.io, "inside.css", "style/ok.css", .{});
    var buf: [512]u8 = undefined;
    const n = try tmp.dir.realPathFile(t.io, "style", &buf);
    var h: Harness = undefined;
    try h.initWith(buf[0..n]);
    defer h.deinit();
    try t.expectEqualStrings("file \"link.css\" is outside the style folder", try h.evalError("ztk::style load link.css"));
    _ = try h.eval("ztk::style load inside.css");
    // A link that stays inside the folder is fine.
    _ = try h.eval("ztk::style load ok.css");
}
