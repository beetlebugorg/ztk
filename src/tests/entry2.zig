//! Tests of the entry additions of the widget stage: the new options,
//! the validation modes and the `%` fields, `validate`, `bbox`, `scan`,
//! `selection adjust`, `from`, and `to`, the `clipboard` command and the
//! virtual events of the clipboard, undo, the placeholder and its fade,
//! and the clear button of the search style. The expected texts are from
//! `wish` 8.6.16.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Harness = @import("../testing.zig").Harness;
const entry = @import("../widgets/entry.zig");
const paint = @import("../paint.zig");
const t = std.testing;

test "entry2: the new options and the messages of wish" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("entry .e");
    const cases = [_][2][]const u8{
        .{ ".e configure -disabledbackground", "-disabledbackground disabledBackground DisabledBackground #d9d9d9 #d9d9d9" },
        .{ ".e configure -highlightthickness", "-highlightthickness highlightThickness HighlightThickness 1 1" },
        .{ ".e configure -invcmd", "-invalidcommand invalidCommand InvalidCommand {} {}" },
        .{ ".e configure -readonlybackground", "-readonlybackground readonlyBackground ReadonlyBackground #d9d9d9 #d9d9d9" },
        .{ ".e configure -validate", "-validate validate Validate none none" },
        .{ ".e configure -placeholder", "-placeholder placeHolder PlaceHolder {} {}" },
    };
    for (cases) |c| try t.expectEqualStrings(c[1], try h.eval(c[0]));
    const errors = [_][2][]const u8{
        .{ ".e selection bogus", "bad selection option \"bogus\": must be adjust, clear, from, present, range, or to" },
        .{ ".e scan", "wrong # args: should be \".e scan mark|dragto x\"" },
        .{ ".e scan bogus 1", "bad scan option \"bogus\": must be mark or dragto" },
        .{ ".e bbox", "wrong # args: should be \".e bbox index\"" },
        .{ ".e validate 1", "wrong # args: should be \".e validate\"" },
        .{ ".e configure -from 1", "unknown option \"-from\"" },
        .{ ".e configure -validate bogus", "bad validate \"bogus\": must be all, key, focus, focusin, focusout, or none" },
    };
    for (errors) |c| try t.expectEqualStrings(c[1], try h.evalError(c[0]));
}

test "entry2: validation modes and the % fields" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval(
        \\set log {}
        \\entry .v -validate key -vcmd {lappend log [list V %d %i %P %s %S %v %V %W]; string is digit %P} -invcmd {lappend log [list INV %P]}
        \\.v insert 0 12; .v insert end x; .v delete 0
    );
    try t.expectEqualStrings("{V 1 0 12 {} 12 key key .v} {V 1 2 12x 12 x key key .v} {INV 12x} {V 0 0 2 12 1 key key .v}", try h.eval("set log"));
    try t.expectEqualStrings("2", try h.eval(".v get"));
    // `validate` runs in the mode all and gives the mode back.
    try t.expectEqualStrings("1 {V -1 -1 2 2 {} all forced .v} key", try h.eval("set log {}; list [.v validate] [lindex $log 0] [.v cget -validate]"));
    // A result that is not a boolean, and an error, turn the validation off and keep the text.
    _ = try h.eval("proc bgerror {m} {lappend ::bg $m}");
    try t.expectEqualStrings("2 none", try h.eval(".v configure -vcmd {return bogus}; .v insert end 3; update; list [.v get] [.v cget -validate]"));
    try t.expectEqualStrings("{} none", try h.eval("entry .x -validate key -vcmd {error boom}; .x insert 0 a; update; list [.x get] [.x cget -validate]"));
    try t.expectEqualStrings("{expected boolean value but got \"bogus\"} boom", try h.eval("set bg"));
    // A variable gives a forced validation, and a set value stays when it is not valid.
    _ = try h.eval("set log {}; entry .w -validate all -vcmd {lappend log %V; return 1}; .w insert 0 a; set tv hi; .w configure -textvariable tv; set tv there");
    try t.expectEqualStrings("key forced forced", try h.eval("set log"));
    try t.expectEqualStrings("abc none", try h.eval("entry .q -textvariable qv -validate key -vcmd {string is digit %P}; set qv abc; list [.q get] [.q cget -validate]"));
    // The fields are quoted with backslashes.
    try t.expectEqualStrings("{a\\ b\\{c} {a\\ b\\{c}", try h.eval("set log {}; entry .k -validate key -vcmd {lappend log {%P} {%S}; return 1}; .k insert 0 \"a b\\{c\"; set log"));
    // Focus validation.
    _ = try h.eval("set log {}; entry .f -validate focus -vcmd {lappend log %V; return 1}; pack .f; update; focus .f; update; focus .; update");
    try t.expectEqualStrings("focusin focusout", try h.eval("set log"));
}

test "entry2: selection from, to, and adjust, bbox, and scan" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("entry .y; .y insert 0 {hello world}");
    try t.expectEqualStrings("2,5", try h.eval(".y selection from 2; .y selection to 5; return [.y index sel.first],[.y index sel.last]"));
    try t.expectEqualStrings("2,8", try h.eval(".y selection adjust 8; return [.y index sel.first],[.y index sel.last]"));
    try t.expectEqualStrings("1,8", try h.eval(".y selection adjust 1; return [.y index sel.first],[.y index sel.last]"));
    try t.expectEqualStrings("1,4", try h.eval(".y selection from 4; .y selection to 1; return [.y index sel.first],[.y index sel.last]"));
    // A disabled entry keeps its selection.
    try t.expectEqualStrings("1", try h.eval(".y configure -state disabled; .y selection clear; .y selection present"));
    _ = try h.eval(".y configure -state normal; pack .y; update");
    // bbox: the box of a character, and of the last character for end.
    try t.expectEqualStrings("1", try h.eval("lassign [.y bbox 0] x0 y0 w0 h0; lassign [.y bbox 1] x1; expr {$x1 == $x0 + $w0 && $w0 > 0 && $h0 > 0}"));
    try t.expectEqualStrings("1", try h.eval("expr {[.y bbox end] eq [.y bbox 10]}"));
    // scan: the view moves 10 times the drag, within the text.
    _ = try h.eval(".y configure -width 4; .y insert end [string repeat x 80]; update; .y xview moveto 0; update");
    _ = try h.eval(".y scan mark 50; .y scan dragto 48");
    try t.expectEqualStrings("1", try h.eval("expr {[lindex [.y xview] 0] > 0}"));
}

test "entry2: the clipboard and its virtual events, and undo" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try t.expectEqualStrings("CLIPBOARD selection doesn't exist or form \"STRING\" not defined", try h.evalError("clipboard get"));
    try t.expectEqualStrings("abc-def", try h.eval("clipboard clear; clipboard append abc; clipboard append -- -def; clipboard get"));
    const errors = [_][2][]const u8{
        .{ "clipboard bogus", "bad option \"bogus\": must be append, clear, or get" },
        .{ "clipboard append", "wrong # args: should be \"clipboard append ?-option value ...? data\"" },
        .{ "clipboard get -type", "value for \"-type\" missing" },
        .{ "clipboard get -bogus 1", "bad option \"-bogus\": must be -displayof or -type" },
        .{ "clipboard clear -displayof .nope", "bad window path name \".nope\"" },
        .{ "clipboard get -type UTF8", "CLIPBOARD selection doesn't exist or form \"UTF8\" not defined" },
    };
    for (errors) |c| try t.expectEqualStrings(c[1], try h.evalError(c[0]));
    _ = try h.eval("entry .y; .y insert 0 {hello world}; pack .y; update");
    try t.expectEqualStrings("hello", try h.eval(".y selection range 0 5; event generate .y <<Copy>>; clipboard get"));
    // A paste replaces the selection, as Tk does on a windowing system other than x11.
    try t.expectEqualStrings(" worldhello", try h.eval("event generate .y <<Paste>>; .y get"));
    try t.expectEqualStrings("hello worldhello", try h.eval(".y icursor 0; event generate .y <<Paste>>; .y get"));
    try t.expectEqualStrings("{llo worldhello} he", try h.eval(".y selection range 0 2; event generate .y <<Cut>>; list [.y get] [clipboard get]"));
    try t.expectEqualStrings("1", try h.eval("event generate .y <<SelectAll>>; .y selection present"));
    try t.expectEqualStrings("llo worldhello", try h.eval(".y selection clear; .y configure -state readonly; event generate .y <<Paste>>; .y get"));
    // A hidden text copies as the show character.
    try t.expectEqualStrings("***", try h.eval(".y configure -state normal -show *; .y selection range 0 3; event generate .y <<Copy>>; clipboard get"));
    // Undo and redo of typed text (a run of typed text is one step) and of a cut.
    _ = try h.eval("entry .u; pack .u; focus .u; update");
    try h.head.typeText(h.win, "abc");
    try h.update();
    _ = try h.eval(".u selection range 0 1; event generate .u <<Cut>>");
    try t.expectEqualStrings("bc", try h.eval(".u get"));
    try t.expectEqualStrings("abc", try h.eval("event generate .u <<Undo>>; .u get"));
    try t.expectEqualStrings("", try h.eval("event generate .u <<Undo>>; .u get"));
    try t.expectEqualStrings("abc", try h.eval("event generate .u <<Redo>>; .u get"));
    // A change by a script ends the history.
    try t.expectEqualStrings("xabc", try h.eval(".u insert 0 x; event generate .u <<Undo>>; .u get"));
}

test "entry2: the placeholder fades, and the clear button of the search style" {
    var h: Harness = undefined;
    try h.initAnimated();
    defer h.deinit();
    _ = try h.eval("entry .e -placeholder Find; pack .e -padx 10 -pady 10; update");
    const w = h.app.find(".e").?;
    const d = entry.dataOf(w);
    try t.expect(w.state.placeholder);
    // The end state at once: the placeholder shows.
    try t.expectEqual(@as(f32, 1), paint.partStyle(w, "placeholder", &d.ph).style.opacity);
    _ = try h.eval(".e insert 0 x; update");
    try t.expect(!w.state.placeholder);
    h.head.advance(80);
    const mid = paint.partStyle(w, "placeholder", &d.ph).style.opacity;
    try t.expect(mid > 0 and mid < 1);
    // A replace during the fade starts from the shown opacity.
    _ = try h.eval(".e delete 0 end; update");
    try t.expectEqual(mid, paint.partStyle(w, "placeholder", &d.ph).style.opacity);
    h.head.advance(300);
    try t.expectEqual(@as(f32, 1), paint.partStyle(w, "placeholder", &d.ph).style.opacity);
    // The search style: a click on the clear button empties the field.
    _ = try h.eval("set q {}; entry .s -textvariable q; ztk::class .s add search; pack .s -padx 10 -pady 10; .s insert 0 wheel; update");
    const r = try h.eval("list [expr {[winfo x .s] + [winfo width .s] - 14}] [expr {[winfo y .s] + [winfo height .s] / 2}]");
    var it = std.mem.splitScalar(u8, r, ' ');
    const x = try std.fmt.parseFloat(f32, it.next().?);
    const y = try std.fmt.parseFloat(f32, it.next().?);
    h.head.pointerMove(h.win, x, y);
    try h.update();
    try t.expect(entry.dataOf(h.app.find(".s").?).hover_clear);
    h.head.click(h.win, x, y);
    try h.update();
    try t.expectEqualStrings(" ", try h.eval("return \"[.s get] $q\""));
    try t.expectEqualStrings("wheel", try h.eval("event generate .s <<Undo>>; .s get"));
}
