//! Regression tests of the fourth review of the code. Each test runs the
//! exact input of its finding where a script can give it.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const Harness = @import("../testing.zig").Harness;
const Watchdog = @import("../testing.zig").Watchdog;
const t = std.testing;

test "r4 class: an enter trace that puts a widget command under the class name" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("frame .w; namespace ensemble create -command ::en -map {f frame}; trace add execution frame enter {apply {{a b} {rename frame {}; rename .w frame}}}; catch {en f .x} e");
    try t.expectEqualStrings("Frame", try h.eval("winfo class .x"));
}

test "r4 class: an enter trace that deletes each class command" {
    for ([_][]const u8{ "frame", "label", "button", "entry" }) |class| {
        var h: Harness = undefined;
        try h.init();
        defer h.deinit();
        var buf: [320]u8 = undefined;
        _ = try h.eval(try std.fmt.bufPrint(&buf, "namespace ensemble create -command ::en -map {{f {s}}}; trace add execution {s} enter {{apply {{{{a b}} {{rename {s} {{}}}}}}}}; catch {{en f .x}} e; set l {{{s} .y}}", .{ class, class, class, class }));
        try t.expect(h.app.find(".x") != null);
    }
}

test "r4 class: a wrong call names its own class" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try t.expectEqualStrings("wrong # args: should be \"button pathName ?-option value ...?\"", try h.evalError("button"));
    try t.expectEqualStrings("wrong # args: should be \"entry pathName ?-option value ...?\"", try h.evalError("entry"));
}

test "r4 compact: a trace on an element link stops the compact" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.app.compact_threshold = 0;
    _ = try h.eval("set n 0; array set a {k 1}; upvar #0 a(k) e; trace add variable e write {apply {{x y z} {incr ::n}}}");
    try t.expect(!h.app.maybeCompact());
    _ = try h.eval("set e 3");
    try t.expectEqualStrings("1", try h.eval("set n"));
}

test "r4 compact: a link to a variable of a widget still compacts" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const label = @import("../widgets/label.zig");
    h.app.compact_threshold = 0;
    _ = try h.eval("set x 1; upvar #0 x y; label .l -textvariable x");
    try t.expect(h.app.maybeCompact());
    _ = try h.eval("set x 2");
    try t.expectEqualStrings("2", label.text(h.app.find(".l").?));
}

test "r4 trace: a renamed trace command does not stop a new wait or a text variable" {
    var dog: Watchdog = undefined;
    try dog.start(20_000);
    defer dog.stop();
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const label = @import("../widgets/label.zig");
    _ = try h.eval("rename trace x; proc trace {args} {error replaced}; label .l -textvariable v; set v 5; after 0 {set ::w 1}; vwait ::w");
    try t.expectEqualStrings("5", label.text(h.app.find(".l").?));
    _ = try h.eval("destroy .l; update");
    try t.expectEqualStrings("", try h.eval("x info variable v"));
}

test "r4 text: cget of -text follows the text variable, as in wish" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("set v hi; label .l -textvariable v -text x; button .b -textvariable v");
    try t.expectEqualStrings("hi", try h.eval(".l cget -text"));
    _ = try h.eval("set v two");
    try t.expectEqualStrings("two", try h.eval(".l cget -text"));
    try t.expectEqualStrings("two", try h.eval(".b cget -text"));
    _ = try h.eval(".l configure -textvariable {}");
    try t.expectEqualStrings("x", try h.eval(".l cget -text"));
}

test "r4 style: a failed allocation in each step of a style compute" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("ztk::style add {Frame { font-family: Inter, sans-serif; background: linear-gradient(90deg, red, blue) }}; frame .f");
    const w = h.app.find(".f").?;
    const saved = h.app.styles.gpa;
    defer h.app.styles.gpa = saved;
    var index: usize = 0;
    while (index < 200) : (index += 1) {
        var failing = t.FailingAllocator.init(saved, .{ .fail_index = index });
        h.app.styles.gpa = failing.allocator();
        h.app.styles.clearCache();
        _ = h.app.styles.compute(w, null, null, h.app.env);
        h.app.styles.gpa = saved;
    }
}
