//! Regression tests of the third review of the code. Each test runs the
//! exact input of its finding. The expected error texts are the output
//! of `wish` 8.6.16 for the same script.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const App = @import("../app.zig").App;
const Headless = @import("../platform/headless.zig").Headless;
const Harness = @import("../testing.zig").Harness;
const Watchdog = @import("../testing.zig").Watchdog;
const t = std.testing;

test "r3 handle: an imported widget command after destroy" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("frame .f; namespace eval n {namespace export g}; rename .f ::n::g; namespace eval m {namespace import ::n::g}; destroy .f; update");
    try t.expectEqualStrings("invalid command name \"::m::g\"", try h.evalError("::m::g configure -width 5"));
    // Each key of the widget went away.
    try t.expectEqualStrings("", try h.eval("info commands ::m::g"));
    try t.expectEqualStrings("", try h.eval("info commands ::n::g"));
}

test "r3 handle: an imported key inside the callback that deletes the widget" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("frame .f; namespace eval n {namespace export g}; rename .f ::n::g; namespace eval m {namespace import ::n::g}; after 0 {destroy .f; catch {::m::g cget -width} ::r}; update");
    try t.expectEqualStrings("invalid command name \"::m::g\"", try h.eval("set r"));
}

test "r3 handle: an enter trace that deletes the widget" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("frame .f; trace add execution .f enter {apply {{a b} {destroy .f}}}");
    try t.expectEqualStrings("invalid command name \".f\"", try h.evalError(".f configure -width 3"));
    try t.expectEqualStrings("0", try h.eval("winfo exists .f"));
}

test "r3 handle: an enter trace that makes the widget again runs the new widget" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("frame .h; trace add execution .h enter {apply {{a b} {destroy .h; frame .h -width 9}}}");
    try t.expectEqualStrings("9", try h.eval(".h cget -width"));
}

test "r3 precision: a string value survives a compact" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.app.compact_threshold = 0;
    _ = try h.eval("set tcl_precision [string range 66 0 0]");
    try t.expect(h.app.maybeCompact());
    // The old arena is gone. New allocations must not change the value.
    _ = try h.eval("set junk [string repeat x 100000]");
    try t.expectEqualStrings("6", try h.eval("set tcl_precision"));
}

test "r3 precision: a text that is not the plain integer stops the compact" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.app.compact_threshold = 0;
    _ = try h.eval("set tcl_precision { 6}");
    try t.expect(!h.app.maybeCompact());
    try t.expectEqualStrings(" 6", try h.eval("set tcl_precision"));
}

test "r3 grid: bbox with the largest integer" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("frame .f -width 10 -height 10; grid .f; update; grid bbox . 9223372036854775807 0");
    _ = try h.eval("grid bbox . 0 9223372036854775807; grid bbox . 0 0 9223372036854775807 9223372036854775807");
}

test "r3 grid: 70000 span words stop at the largest span" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("frame .f -width 10 -height 10; grid .f {*}[lrepeat 70000 -]");
    try t.expectEqualStrings("10000", try h.eval("dict get [grid info .f] -columnspan"));
}

test "r3 owner: a user trace that starts like a ztk trace stops the compact" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.app.compact_threshold = 0;
    _ = try h.eval("set v 1; set hit 0; trace add variable v write {ztk::priv::entry_var .none; incr ::hit; list}");
    try t.expect(!h.app.maybeCompact());
    _ = try h.eval("set v 2");
    try t.expectEqualStrings("1", try h.eval("set hit"));
}

test "r3 owner: the exact script of a widget on another variable stops the compact" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.app.compact_threshold = 0;
    _ = try h.eval("entry .e -textvariable a; set b 1; trace add variable b write {ztk::priv::entry_var .e}");
    try t.expect(!h.app.maybeCompact());
}

test "r3 owner: a second equal trace and other operations stop the compact" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.app.compact_threshold = 0;
    _ = try h.eval("label .l -textvariable a; trace add variable a write {::ztk::priv::textvar .l}");
    try t.expect(!h.app.maybeCompact());
    _ = try h.eval("trace remove variable a write {::ztk::priv::textvar .l}; trace add variable a read {::ztk::priv::textvar .l}");
    h.app.compact_base = 0;
    try t.expect(!h.app.maybeCompact());
    _ = try h.eval("trace remove variable a read {::ztk::priv::textvar .l}");
    h.app.compact_base = 0;
    try t.expect(h.app.maybeCompact());
    // With the write trace gone, a read trace with the same text is the only one.
    _ = try h.eval("trace remove variable a write {::ztk::priv::textvar .l}; trace add variable a read {::ztk::priv::textvar .l}");
    h.app.compact_base = 0;
    try t.expect(!h.app.maybeCompact());
}

test "r3 owner: the traces of widgets, of an array element, and a namespace still compact" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const label = @import("../widgets/label.zig");
    h.app.compact_threshold = 0;
    _ = try h.eval("namespace eval ::n {variable x 1}; label .a -textvariable arr(k); label .b -textvariable ::n::x; button .c -textvariable ::plain; entry .d -textvariable plain2");
    try t.expect(h.app.maybeCompact());
    _ = try h.eval("set arr(k) one; set ::n::x two");
    try t.expectEqualStrings("one", label.text(h.app.find(".a").?));
    try t.expectEqualStrings("two", label.text(h.app.find(".b").?));
}

test "r3 retrace: a renamed trace command still compacts, and a parked vwait ends" {
    var dog: Watchdog = undefined;
    try dog.start(20_000);
    defer dog.stop();
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.app.compact_threshold = 0;
    try h.app.runScript("after 0 {rename trace x; after 0 {after 0 {set ::v 1}}}\nvwait ::v\nset after 1");
    try t.expectEqualStrings("1", try h.eval("set after"));
    // The compacts after the rename add the trace of the wait again.
    try t.expect(h.app.script_gen >= 2);
}

test "r3 retrace: a failed trace of a parked vwait gives an error" {
    var dog: Watchdog = undefined;
    try dog.start(20_000);
    defer dog.stop();
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const l = &h.app.loop;
    try l.waits.append(h.app.gpa, .{ .id = 77 });
    l.parked = .{ .variable = .{ .id = 77, .name = try h.app.gpa.dupe(u8, "::v") } };
    _ = try h.eval("after 100000 {}");
    h.app.trace_native = null;
    l.retraceParked();
    try t.expectError(error.TclError, l.runParked());
    try t.expectEqualStrings("can't wait for variable \"::v\": its trace was lost", try h.it.str(h.it.result));
}

fn initAtEveryFailure(mode: @import("../render/thread.zig").Mode, root: ?[]const u8) !usize {
    var index: usize = 0;
    while (true) : (index += 1) {
        var it: ztcl.Interp = undefined;
        try it.init(t.allocator);
        defer it.deinit();
        const head = try Headless.init(t.allocator);
        defer head.deinit();
        // This allocator has no stack traces, so a leak fails the test in a moment.
        var checked: std.heap.DebugAllocator(.{ .stack_trace_frames = 0 }) = .init;
        var failing = std.testing.FailingAllocator.init(checked.allocator(), .{ .fail_index = index });
        const made = App.init(failing.allocator(), &it, .{ .platform = head.platform(), .style_root = root, .io = t.io, .render_mode = mode });
        if (made) |app| app.deinit() else |e| try t.expectEqual(error.OutOfMemory, e);
        try t.expect(checked.deinit() == .ok);
        if (made) |_| return index else |_| {}
    }
}

test "r3 init: App.init frees all at each allocation failure" {
    var dog: Watchdog = undefined;
    try dog.start(60_000);
    defer dog.stop();
    const n = try initAtEveryFailure(.inline_draw, "style-root");
    try t.expect(n > 10);
    _ = try initAtEveryFailure(.inline_draw, null);
    _ = try initAtEveryFailure(.threaded, "style-root");
}
