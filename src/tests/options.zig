//! Tests of `configure`, `cget`, and the option parsers. Each expected
//! text is the output of `wish` 8.6.16 for the same command.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Harness = @import("../testing.zig").Harness;
const options = @import("../options.zig");
const t = std.testing;

fn setup(h: *Harness) !void {
    try h.init();
    _ = try h.eval("frame .f -width 100 -height 50");
}

test "options: cget and configure" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    try t.expectEqualStrings("100", try h.eval(".f cget -width"));
    _ = try h.eval(".f configure -bg red");
    try t.expectEqualStrings("red", try h.eval(".f cget -background"));
    try t.expectEqualStrings("-background background Background #d9d9d9 red", try h.eval(".f configure -bg"));
    try t.expectEqualStrings("2", try h.eval("llength [lindex [.f configure] 0]"));
    try t.expectEqualStrings("5", try h.eval("llength [lindex [.f configure] 1]"));
    try t.expectEqualStrings("-bd -borderwidth", try h.eval("lindex [.f configure] 0"));
    try t.expectEqualStrings("#f5f5f7", try h.eval("frame .x; .x cget -bg"));
    try t.expectEqualStrings("-borderwidth borderWidth BorderWidth 0 0", try h.eval(".x configure -bd"));
}

test "options: prefixes" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    try t.expectEqualStrings("#f5f5f7", try h.eval(".f cget -backg"));
    try t.expectEqualStrings("unknown option \"-b\"", try h.evalError(".f cget -b"));
    try t.expectEqualStrings("unknown option \"-b\"", try h.evalError(".f configure -b"));
    try t.expectEqualStrings("unknown option \"-nosuch\"", try h.evalError(".f configure -nosuch 1"));
    _ = try h.eval(".f config -padx 4");
    try t.expectEqualStrings("4", try h.eval(".f cget -padx"));
}

test "options: type errors" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    try t.expectEqualStrings("bad screen distance \"x\"", try h.evalError(".f configure -width x"));
    try t.expectEqualStrings("bad screen distance \"1.5x\"", try h.evalError(".f configure -padx 1.5x"));
    try t.expectEqualStrings("unknown color name \"nocolor\"", try h.evalError(".f configure -bg nocolor"));
    try t.expectEqualStrings("bad relief \"x\": must be flat, groove, raised, ridge, solid, or sunken", try h.evalError(".f configure -relief x"));
    try t.expectEqualStrings("can't modify -class option after widget is created", try h.evalError(".f configure -class X"));
    try t.expectEqualStrings("wrong # args: should be \".f cget option\"", try h.evalError(".f cget"));
    try t.expectEqualStrings("wrong # args: should be \".f cget option\"", try h.evalError(".f cget -width -height"));
}

test "options: missing values" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    try t.expectEqualStrings("-width width Width 0 100", try h.eval(".f configure -width"));
    try t.expectEqualStrings("value for \"-height\" missing", try h.evalError(".f configure -width 1 -height"));
    try t.expectEqualStrings("value for \"-width\" missing", try h.evalError("frame .q -width"));
    try t.expectEqualStrings("value for \"-bg\" missing", try h.evalError("frame .r -bg"));
}

test "options: a failed configure changes nothing" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    _ = try h.evalError(".f configure -width 10 -bg nocolor");
    try t.expectEqualStrings("100", try h.eval(".f cget -width"));
}

test "options: a failed constructor leaves no widget" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    try t.expectEqualStrings("unknown option \"-nosuch\"", try h.evalError("frame .g -nosuch 1"));
    try t.expectEqualStrings("0", try h.eval("winfo exists .g"));
    try t.expectEqualStrings("0", try h.eval("llength [info commands .g]"));
}

test "options: -class at creation" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    _ = try h.eval("frame .h -class Fancy");
    try t.expectEqualStrings("Fancy", try h.eval("winfo class .h"));
    try t.expectEqualStrings("Frame", try h.eval("winfo class .f"));
}

test "options: screen distances normalize as wish does" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    _ = try h.eval(".f configure -width 2.5");
    try t.expectEqualStrings("3", try h.eval(".f cget -width"));
    _ = try h.eval(".f configure -width 0.5");
    try t.expectEqualStrings("1", try h.eval(".f cget -width"));
    _ = try h.eval(".f configure -bd 2.5");
    try t.expectEqualStrings("3", try h.eval(".f cget -borderwidth"));
    _ = try h.eval(".f configure -width 99999999999");
    try t.expectEqualStrings("16777216", try h.eval(".f cget -width"));
}

test "options: parsePixels units" {
    const s = 96.0 / 72.0;
    try t.expectEqual(@as(?i32, 96), options.parsePixels("1i", s));
    try t.expectEqual(@as(?i32, 96), options.parsePixels("72p", s));
    try t.expectEqual(@as(?i32, 96), options.parsePixels("2.54c", s));
    try t.expectEqual(@as(?i32, 96), options.parsePixels("25.4m", s));
    try t.expectEqual(@as(?i32, 3), options.parsePixels("2.5", s));
    try t.expectEqual(@as(?i32, null), options.parsePixels("x", s));
    try t.expectEqual(@as(?i32, null), options.parsePixels("", s));
    try t.expectEqual(@as(?i32, null), options.parsePixels("c", s));
    try t.expectEqual(@as(?i32, null), options.parsePixels("inf", s));
}

test "options: the names and classes of the database equal wish" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    // Parts 1 to 3 of each item, from `wish` 8.6.16 for the options of the class.
    const expected =
        "{-bd -borderwidth} {-borderwidth borderWidth BorderWidth} {-class class Class} " ++
        "{-relief relief Relief} {-background background Background} {-bg -background} " ++
        "{-cursor cursor Cursor} {-height height Height} {-padx padX Pad} {-pady padY Pad} " ++
        "{-takefocus takeFocus TakeFocus} {-width width Width}";
    const got = try h.eval("set r {}; foreach i [.f configure] { lappend r [lrange $i 0 [expr {[llength $i] == 2 ? 1 : 2}]] }; set r");
    try t.expectEqualStrings(expected, got);
}

test "options: invalid hash colors" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    try t.expectEqualStrings("invalid color name \"#12\"", try h.evalError(".f configure -bg #12"));
    try t.expectEqualStrings("invalid color name \"#gggggg\"", try h.evalError(".f configure -bg #gggggg"));
}
