//! Tests of the event loop adapter. All tests use a manual clock, so no
//! test sleeps. Each expected message is the text of `wish` 8.6.16.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const Harness = @import("../testing.zig").Harness;
const t = std.testing;

test "loop: the pinned ztcl has no after command" {
    var it: ztcl.Interp = undefined;
    try it.init(t.allocator);
    defer it.deinit();
    try t.expect(it.findCommand("after") == null);
    try t.expect(it.findCommand("vwait") == null);
    try t.expect(it.findCommand("update") == null);
}

test "loop: a timer runs when its time has come" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("after 100 {set x 1}");
    _ = try h.eval("update");
    try t.expectEqualStrings("0", try h.eval("info exists x"));
    h.head.advance(100);
    _ = try h.eval("update");
    try t.expectEqualStrings("1", try h.eval("set x"));
}

test "loop: timers run in the order of their time" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("set l {}; after 30 {lappend l 30}; after 10 {lappend l 10}; after 20 {lappend l 20}");
    h.head.advance(50);
    _ = try h.eval("update");
    try t.expectEqualStrings("10 20 30", try h.eval("set l"));
}

test "loop: equal times run in the order of creation" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("set l {}; after 5 {lappend l a}; after 5 {lappend l b}; after 5 {lappend l c}");
    h.head.advance(5);
    _ = try h.eval("update");
    try t.expectEqualStrings("a b c", try h.eval("set l"));
}

test "loop: after cancel by id and by script" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("set id [after 10 {set a 1}]; after 10 {set b 2}; after 10 set c 3");
    _ = try h.eval("after cancel $id");
    _ = try h.eval("after cancel set c 3");
    _ = try h.eval("after cancel after#99");
    h.head.advance(10);
    _ = try h.eval("update");
    try t.expectEqualStrings("0 1 0", try h.eval("list [info exists a] [info exists b] [info exists c]"));
}

test "loop: after info" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try t.expectEqualStrings("after#0", try h.eval("after 10 {set x 1}"));
    try t.expectEqualStrings("after#1", try h.eval("after idle {set y 1}"));
    try t.expectEqualStrings("after#1 after#0", try h.eval("after info"));
    try t.expectEqualStrings("{set x 1} timer", try h.eval("after info after#0"));
    try t.expectEqualStrings("{set y 1} idle", try h.eval("after info after#1"));
    try t.expectEqualStrings("event \"after#99\" doesn't exist", try h.evalError("after info after#99"));
}

test "loop: idle entries run after the timers of the pass" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("set l {}; after idle {lappend l i}; after 0 {lappend l t}");
    _ = try h.eval("update");
    try t.expectEqualStrings("t i", try h.eval("set l"));
}

test "loop: an idle entry that adds an idle entry" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("set n 0; after idle {incr n; after idle {incr n}}");
    _ = try h.eval("update idletasks");
    try t.expectEqualStrings("2", try h.eval("set n"));
    _ = try h.eval("set m 0; after idle {incr m; after idle {incr m}}");
    _ = try h.eval("update");
    try t.expectEqualStrings("2", try h.eval("set m"));
    try t.expectEqualStrings("", try h.eval("after info"));
}

test "loop: a timer that makes a timer does not run it in the same pass" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("after 10 {after 0 {set y 1}}");
    h.head.advance(10);
    try t.expect(try h.app.doOneEvent(false));
    try t.expectEqualStrings("0", try h.eval("info exists y"));
    try t.expect(try h.app.doOneEvent(false));
    try t.expectEqualStrings("1", try h.eval("set y"));
}

test "loop: vwait runs timers until the variable is written" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("after 50 {set done 1}; vwait done");
    try t.expect(h.head.now_us >= 50_000);
    try t.expectEqualStrings("1", try h.eval("set done"));
    // The trace is gone.
    try t.expectEqualStrings("", try h.eval("trace info variable done"));
}

test "loop: vwait with nothing to wait for" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try t.expectEqualStrings("can't wait for variable \"nosuch\": would wait forever", try h.evalError("vwait nosuch"));
    try t.expectEqualStrings("", try h.eval("trace info variable nosuch"));
}

test "loop: after ms waits on the clock" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("after 40");
    try t.expectEqual(@as(i64, 40_000), h.head.now_us);
}

test "loop: an error in a timer calls bgerror" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("proc bgerror {m} {set ::got $m}; after 0 {error boom}");
    _ = try h.eval("update");
    try t.expectEqualStrings("boom", try h.eval("set got"));
    try t.expectEqualStrings("", h.err.items);
}

test "loop: an error without bgerror goes to the error output" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("after 0 {error boom}");
    _ = try h.eval("update");
    try t.expect(std.mem.startsWith(u8, h.err.items, "boom"));
    try t.expect(std.mem.endsWith(u8, h.err.items, "\n"));
}

test "loop: callbacks run at the global level and restore the frame" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("set g 1; proc p {} {set g 2; after 0 {set seen $g}; update; return $g}");
    try t.expectEqualStrings("2", try h.eval("p"));
    try t.expectEqualStrings("1", try h.eval("set seen"));
}

test "loop: tkwait window returns after a timer deletes the widget" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("frame .f; after 20 {destroy .f}; tkwait window .f");
    try t.expectEqualStrings("0", try h.eval("winfo exists .f"));
    try t.expectEqualStrings("bad window path name \".nosuch\"", try h.evalError("tkwait window .nosuch"));
}

test "loop: tkwait variable and visibility" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("after 5 {set v 1}; tkwait variable v");
    try t.expectEqualStrings("1", try h.eval("set v"));
    try t.expectEqualStrings("", try h.eval("tkwait visibility ."));
}

test "loop: argument errors" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try t.expectEqualStrings("bad argument \"bogus\": must be cancel, idle, info, or an integer", try h.evalError("after bogus"));
    try t.expectEqualStrings("wrong # args: should be \"after option ?arg ...?\"", try h.evalError("after"));
    try t.expectEqualStrings("wrong # args: should be \"after cancel id|command\"", try h.evalError("after cancel"));
    try t.expectEqualStrings("wrong # args: should be \"after idle script ?script ...?\"", try h.evalError("after idle"));
    try t.expectEqualStrings("wrong # args: should be \"after info ?id?\"", try h.evalError("after info a b"));
    try t.expectEqualStrings("bad option \"bogus\": must be idletasks", try h.evalError("update bogus"));
    try t.expectEqualStrings("wrong # args: should be \"update ?idletasks?\"", try h.evalError("update a b"));
    try t.expectEqualStrings("wrong # args: should be \"vwait name\"", try h.evalError("vwait"));
    try t.expectEqualStrings("wrong # args: should be \"tkwait variable|visibility|window name\"", try h.evalError("tkwait"));
    try t.expectEqualStrings("wrong # args: should be \"tkwait variable|visibility|window name\"", try h.evalError("tkwait bogus x"));
}

test "loop: native timers and idle calls" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const S = struct {
        var n: u32 = 0;
        fn f(_: ?*anyopaque) void {
            n += 1;
        }
    };
    S.n = 0;
    const l = &h.app.loop;
    const id = try l.addNative(1000, S.f, null);
    _ = try l.addNativeIdle(S.f, null);
    try t.expectEqual(@as(?i64, 0), l.nextTimeoutUs());
    _ = try h.eval("update");
    try t.expectEqual(@as(u32, 1), S.n);
    try t.expectEqual(@as(?i64, 1000), l.nextTimeoutUs());
    try t.expect(l.cancel(id));
    try t.expectEqual(@as(?i64, null), l.nextTimeoutUs());
    try t.expect(!l.cancel(id));
}
