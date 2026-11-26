//! Tests of the `text` widget: the options, the indexes, `insert`,
//! `delete`, `get`, `compare`, `count`, `replace`, and the marks with
//! their gravity. The expected texts are from `wish` 8.6.16.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Harness = @import("../testing.zig").Harness;
const t = std.testing;

fn expectEvals(h: *Harness, cases: []const [2][]const u8) !void {
    for (cases) |c| {
        const got = h.eval(c[0]) catch |e| {
            std.debug.print("{s}: {}\n", .{ c[0], e });
            return e;
        };
        t.expectEqualStrings(c[1], got) catch |e| {
            std.debug.print("in: {s}\n", .{c[0]});
            return e;
        };
    }
}

fn expectErrors(h: *Harness, cases: []const [2][]const u8) !void {
    for (cases) |c| {
        const got = try h.evalError(c[0]);
        t.expectEqualStrings(c[1], got) catch |e| {
            std.debug.print("in: {s}\n", .{c[0]});
            return e;
        };
    }
}

test "textw: options and the messages of wish" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("text .t");
    try expectEvals(&h, &.{
        .{ ".t configure -wrap", "-wrap wrap Wrap char char" },
        .{ ".t configure -font", "-font font Font TkFixedFont TkFixedFont" },
        .{ ".t configure -height", "-height height Height 24 24" },
        .{ ".t configure -width", "-width width Width 80 80" },
        .{ ".t configure -cursor", "-cursor cursor Cursor xterm xterm" },
        .{ ".t configure -startline", "-startline {} {} {} {}" },
        .{ ".t configure -insertunfocussed", "-insertunfocussed insertUnfocussed InsertUnfocussed none none" },
        .{ ".t configure -tabstyle", "-tabstyle tabStyle TabStyle tabular tabular" },
        .{ ".t configure -autoseparators", "-autoseparators autoSeparators AutoSeparators 1 1" },
        .{ "llength [.t configure]", "44" },
        .{ ".t index end", "2.0" },
        .{ ".t index end-1c", "1.0" },
        .{ ".t get 1.0 end", "\n" },
    });
    try expectErrors(&h, &.{
        .{ ".t configure -wrap foo", "bad wrap \"foo\": must be char, none, or word" },
        .{ ".t configure -state foo", "bad state \"foo\": must be disabled or normal" },
        .{ ".t configure -tabstyle x", "bad tabstyle \"x\": must be tabular or wordprocessor" },
        .{ ".t configure -insertunfocussed x", "bad insertunfocussed \"x\": must be hollow, none, or solid" },
        .{ ".t configure -maxundo x", "expected integer but got \"x\"" },
        .{ ".t bogus", "bad option \"bogus\": must be bbox, cget, compare, configure, count, debug, delete, dlineinfo, dump, edit, get, image, index, insert, mark, peer, pendingsync, replace, scan, search, see, sync, tag, window, xview, or yview" },
        .{ ".t index", "wrong # args: should be \".t index index\"" },
        .{ ".t index 1.0 2.0", "wrong # args: should be \".t index index\"" },
        .{ ".t index foo", "bad text index \"foo\"" },
        .{ ".t index sel.first", "text doesn't contain any characters tagged with \"sel\"" },
        .{ ".t compare 1.0", "wrong # args: should be \".t compare index1 op index2\"" },
        .{ ".t compare 1.0 foo 2.0", "bad comparison operator \"foo\": must be <, <=, ==, >=, >, or !=" },
        .{ ".t compare 1.0 = 1.0", "bad comparison operator \"=\": must be <, <=, ==, >=, >, or !=" },
        .{ ".t compare foo < 1.0", "bad text index \"foo\"" },
        .{ ".t count 1.0", "wrong # args: should be \".t count ?-option value ...? index1 index2\"" },
        .{ ".t count -bogus 1.0 2.0", "bad option \"-bogus\" must be -chars, -displaychars, -displayindices, -displaylines, -indices, -lines, -update, -xpixels, or -ypixels" },
        .{ ".t count -d 1.0 2.0", "bad option \"-d\" must be -chars, -displaychars, -displayindices, -displaylines, -indices, -lines, -update, -xpixels, or -ypixels" },
        .{ ".t get", "wrong # args: should be \".t get ?-displaychars? ?--? index1 ?index2 ...?\"" },
        .{ ".t get 1.0 foo", "bad text index \"foo\"" },
        .{ ".t get -bogus 1.0 1.1", "bad text index \"-bogus\"" },
        .{ ".t get -displaychars", "bad text index \"-displaychars\"" },
        .{ ".t delete", "wrong # args: should be \".t delete index1 ?index2 ...?\"" },
        .{ ".t delete foo", "bad text index \"foo\"" },
        .{ ".t insert 1.0", "wrong # args: should be \".t insert index chars ?tagList chars tagList ...?\"" },
        .{ ".t replace 1.0", "wrong # args: should be \".t replace index1 index2 chars ?tagList chars tagList ...?\"" },
        .{ ".t mark", "wrong # args: should be \".t mark option ?arg ...?\"" },
        .{ ".t mark bogus", "bad mark option \"bogus\": must be gravity, names, next, previous, set, or unset" },
        .{ ".t mark set", "wrong # args: should be \".t mark set markName index\"" },
        .{ ".t mark set insert foo", "bad text index \"foo\"" },
        .{ ".t mark next", "wrong # args: should be \".t mark next index\"" },
        .{ ".t mark next foo", "bad text index \"foo\"" },
        .{ ".t mark names x", "wrong # args: should be \".t mark names\"" },
        .{ ".t mark gravity", "wrong # args: should be \".t mark gravity markName ?gravity?\"" },
        .{ ".t mark gravity zz", "there is no mark named \"zz\"" },
        .{ ".t mark gravity insert up", "bad mark gravity \"up\": must be left or right" },
    });
}

test "textw: insert, delete, get, count, and replace" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("text .t; .t insert end \"hello world\\nsecond line\\nthird\"");
    try expectEvals(&h, &.{
        .{ ".t index end", "4.0" },
        .{ ".t index insert", "3.5" },
        .{ ".t index {end - 1 c}", "3.5" },
        .{ ".t index 2.3-10c", "1.5" },
        .{ ".t index 3.end-1lines", "2.5" },
        .{ ".t index {insert wordend}", "4.0" },
        .{ ".t index @0,0", "1.0" },
        .{ ".t compare 1.0 < 2.0", "1" },
        .{ ".t count 1.0 end", "30" },
        .{ ".t count -lines 1.0 end", "3" },
        .{ ".t count -chars -lines 1.0 3.2", "26 2" },
        .{ ".t count 3.0 1.0", "-24" },
        .{ ".t count -c 1.0 2.0", "12" },
        .{ ".t count -update 1.0 2.0", "12" },
        .{ ".t get 1.0 1.5 2.0 2.3", "hello sec" },
        .{ ".t get -displaychars 1.0 1.5", "hello" },
        .{ ".t get -- 1.0 1.1", "h" },
        .{ ".t get 2.0 1.0", "" },
        .{ ".t delete 1.0 1.6; .t get 1.0 end", "world\nsecond line\nthird\n" },
        .{ ".t delete end; .t delete 1.0 1.1 2.0 2.1; .t get 1.0 end", "orld\necond line\nthird\n" },
        .{ ".t delete 3.0 1.0; .t insert 1.0 a {} b {x y}; .t get 1.0 1.10", "aborld" },
        .{ ".t replace 1.0 1.2 ZZ; .t get 1.0 1.end", "ZZorld" },
        .{ ".t delete 1.0 end; .t index end", "2.0" },
        .{ ".t get 1.0 end", "\n" },
        .{ ".t insert end abc; .t get 1.0 1.1 1.2", "a c" },
        .{ ".t delete 1.0 1.1 1.2; .t get 1.0 end", "b\n" },
        .{ ".t insert 1.0 a tag b; .t get 1.0 end", "abb\n" },
        .{ ".t replace 1.0 0.0 x; .t get 1.0 end", "xabb\n" },
        .{ ".t delete 1.0 end; .t insert end \"a\\nb\"; .t delete 2.0 end; .t get 1.0 end", "a\n" },
        .{ ".t insert end \"\\nb\"; .t delete end-1c; .t get 1.0 end", "a\nb\n" },
        .{ ".t configure -state disabled; .t insert end zz; .t get 1.0 end", "a\nb\n" },
    });
    try expectErrors(&h, &.{
        .{ ".t replace 1.1 1.0 x", "index \"1.0\" before \"1.1\" in the text" },
    });
}

test "textw: marks and their gravity" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("text .t; .t insert end \"ab\\ncd\\n\"");
    try expectEvals(&h, &.{
        .{ ".t mark names", "insert current" },
        .{ ".t mark set a 1.1; .t mark set b 1.1; .t mark gravity b", "right" },
        .{ ".t mark gravity b left; .t mark gravity b", "left" },
        .{ ".t insert 1.1 X; list [.t index a] [.t index b]", "1.2 1.1" },
        .{ ".t mark next 1.0", "b" },
        .{ ".t mark next b", "a" },
        .{ ".t mark previous a", "b" },
        .{ ".t mark previous 1.1", "" },
        .{ ".t mark set c 2.1; .t delete 1.0 2.2; list [.t index a] [.t index b] [.t index c]", "1.0 1.0 1.0" },
        .{ ".t mark next 3.0", "" },
        .{ ".t mark unset a zz insert; .t mark names", "insert current b c" },
        .{ ".t mark set m end; .t index m", "3.0" },
        .{ ".t mark set insert end; .t index insert", "2.0" },
        .{ ".t mark set end 1.0; .t index end", "1.0" },
    });
}

test "textw: tags, their ranges, and their options" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("text .t; .t insert end \"hello world\\nsecond line\\nthird\"");
    try expectEvals(&h, &.{
        .{ ".t tag names", "sel" },
        .{ ".t tag configure sel -background", "-background {} {} {} #c3c3c3" },
        .{ ".t tag configure sel -relief", "-relief {} {} {} raised" },
        .{ ".t tag add a 1.0 1.5 2.0 2.3; .t tag add b 1.3; .t tag ranges a", "1.0 1.5 2.0 2.3" },
        .{ ".t tag names", "sel a b" },
        .{ ".t tag names 1.3", "a b" },
        .{ ".t tag add a 1.4 1.8; .t tag ranges a", "1.0 1.8 2.0 2.3" },
        .{ ".t tag remove a 1.2 1.3; .t tag ranges a", "1.0 1.2 1.3 1.8 2.0 2.3" },
        .{ ".t insert 1.1 XY; .t tag ranges a", "1.0 1.4 1.5 1.10 2.0 2.3" },
        .{ ".t insert 1.0 ZZ; .t tag ranges a", "1.2 1.6 1.7 1.12 2.0 2.3" },
        .{ ".t insert 1.4 QQ b; list [.t tag ranges a] [.t tag ranges b]", "{1.2 1.4 1.6 1.8 1.9 1.14 2.0 2.3} {1.4 1.6 1.9 1.10}" },
        .{ "list [.t index a.first] [.t index a.last]", "1.2 2.3" },
        .{ ".t tag nextrange a 1.0", "1.2 1.4" },
        .{ ".t tag nextrange a 1.3 2.0", "1.6 1.8" },
        .{ ".t tag nextrange a 2.1", "" },
        .{ ".t tag prevrange a end", "2.0 2.3" },
        .{ ".t tag prevrange a 2.1", "2.0 2.3" },
        .{ ".t tag prevrange a 1.0", "" },
        .{ ".t tag configure a -foreground red; .t tag configure a -foreground", "-foreground {} {} {} red" },
        .{ ".t tag cget a -fg", "" },
        .{ ".t tag configure zz -background blue; .t tag raise a; .t tag names", "sel b zz a" },
        .{ ".t tag lower a b; .t tag names", "sel a b zz" },
        .{ ".t tag raise a b; .t tag names", "sel b a zz" },
        .{ ".t tag delete b zz nonesuch sel; .t tag names", "sel a" },
        .{ ".t tag bind a <1> {puts hi}; .t tag bind a <Motion> {puts m}; .t tag bind a", "<Motion> <Button-1>" },
        .{ ".t tag bind a <1>", "puts hi" },
        .{ ".t tag add a 3.0 end; .t tag ranges a", "1.2 1.4 1.6 1.8 1.9 1.14 2.0 2.3 3.0 4.0" },
        .{ ".t delete 1.0 2.0; .t tag ranges a", "1.0 1.3 2.0 3.0" },
        .{ ".t tag configure a -font {Courier 12} -lmargin1 1c; .t tag cget a -lmargin1", "1c" },
        .{ ".t tag configure a -elide 1; .t tag cget a -elide", "1" },
        .{ ".t tag configure a -elide {}; .t tag cget a -elide", "" },
        .{ ".t tag remove a 1.0 end; .t tag ranges a", "" },
    });
    try expectErrors(&h, &.{
        .{ ".t index a.first", "text doesn't contain any characters tagged with \"a\"" },
        .{ ".t index c.first", "bad text index \"c.first\"" },
        .{ ".t tag configure a -bogus 1", "unknown option \"-bogus\"" },
        .{ ".t tag configure a -fo", "unknown option \"-fo\"" },
        .{ ".t tag configure a -wrap foo", "bad wrap \"foo\": must be char, none, word, or " },
        .{ ".t tag configure a -elide foo", "expected boolean value but got \"foo\"" },
        .{ ".t tag configure a -justify foo", "bad justification \"foo\": must be left, right, or center" },
        .{ ".t tag configure a -offset foo", "bad screen distance \"foo\"" },
        .{ ".t tag configure a -tabs {1c foo}", "bad tab alignment \"foo\": must be left, right, center, or numeric" },
        .{ ".t tag configure a -tabstyle foo", "bad tabstyle \"foo\": must be tabular, wordprocessor, or " },
        .{ ".t tag raise nonesuch", "tag \"nonesuch\" isn't defined in text widget" },
        .{ ".t tag cget nonesuch -fg", "tag \"nonesuch\" isn't defined in text widget" },
        .{ ".t tag bind a <Foo> x", "bad event type or keysym \"Foo\"" },
        .{ ".t tag bind a <Configure> x", "requested illegal events; only key, button, motion, enter, leave, and virtual events may be used" },
        .{ ".t tag", "wrong # args: should be \".t tag option ?arg ...?\"" },
        .{ ".t tag bogus", "bad tag option \"bogus\": must be add, bind, cget, configure, delete, lower, names, nextrange, prevrange, raise, ranges, or remove" },
        .{ ".t tag add a", "wrong # args: should be \".t tag add tagName index1 ?index2 index1 index2 ...?\"" },
        .{ ".t tag remove a", "wrong # args: should be \".t tag remove tagName index1 ?index2 index1 index2 ...?\"" },
        .{ ".t tag ranges", "wrong # args: should be \".t tag ranges tagName\"" },
        .{ ".t tag nextrange a", "wrong # args: should be \".t tag nextrange tagName index1 ?index2?\"" },
        .{ ".t tag cget a", "wrong # args: should be \".t tag cget tagName option\"" },
        .{ ".t tag names 1.0 2.0", "wrong # args: should be \".t tag names ?index?\"" },
        .{ ".t tag delete", "wrong # args: should be \".t tag delete tagName ?tagName ...?\"" },
        .{ ".t tag raise", "wrong # args: should be \".t tag raise tagName ?aboveThis?\"" },
    });
}

test "textw: tag bindings with Enter and Leave, and the paint of tags" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval(
        \\set log {}
        \\text .t -width 20 -height 4 -bd 0 -highlightthickness 0 -padx 0 -pady 0; place .t -x 0 -y 0
        \\.t insert end "link here\nplain"
        \\.t tag add link 1.0 1.4
        \\.t tag configure link -foreground blue -underline 1 -background yellow
        \\.t tag bind link <Enter> {lappend log enter}
        \\.t tag bind link <Leave> {lappend log leave}
        \\.t tag bind link <Button-1> {lappend log click}
        \\bind .t <Button-1> {lappend log widget}
        \\update
    );
    h.head.pointerMove(h.win, 3, 3);
    try h.update();
    try t.expectEqualStrings("enter", try h.eval("set log"));
    try t.expectEqualStrings("1.0", try h.eval(".t index current"));
    h.head.pointerButton(h.win, 1, true);
    try h.update();
    h.head.pointerButton(h.win, 1, false);
    try h.update();
    try t.expectEqualStrings("enter click widget", try h.eval("set log"));
    h.head.pointerMove(h.win, 3, 40);
    try h.update();
    try t.expectEqualStrings("enter click widget leave", try h.eval("set log"));
    try t.expectEqualStrings("2.0", try h.eval(".t index current"));
    // An elided range has no width, so the text after it moves left.
    const x0 = try h.eval("lindex [.t count -xpixels 1.0 1.6] 0");
    _ = try h.eval(".t tag configure link -elide 1");
    const x1 = try h.eval(".t count -xpixels 1.0 1.6");
    try t.expect(!std.mem.eql(u8, x0, x1));
}

test "textw: the view, wrap, see, bbox, and dlineinfo" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval(
        \\text .t -height 5 -width 20; pack .t
        \\for {set i 1} {$i <= 100} {incr i} { .t insert end "Line $i\n" }
        \\update
    );
    try expectEvals(&h, &.{
        .{ ".t xview", "0.0 1.0" },
        .{ ".t yview 10; .t index @0,0", "11.0" },
        .{ ".t see 1.0; .t index @0,0", "1.0" },
        .{ ".t bbox 90.0", "" },
        .{ "llength [.t bbox 1.0]", "4" },
        .{ "llength [.t dlineinfo 1.0]", "5" },
        .{ ".t count -displaylines 1.0 10.0", "9" },
        .{ ".t yview scroll 2 units; .t index @0,0", "3.0" },
        .{ ".t see 90.0; expr {[.t bbox 90.0] ne {}}", "1" },
        .{ ".t yview moveto 0; .t yview -pickplace 1.0; .t index @0,0", "1.0" },
        .{ "lindex [.t yview] 0", "0.0" },
        // A long line wraps at the width of the window. The fonts of ztk
        // differ from those of wish, so the count of display lines differs.
        .{ ".t delete 1.0 end; .t insert end [string repeat {word } 40]; expr {[.t count -displaylines 1.0 1.end] > 4}", "1" },
        .{ ".t configure -wrap none; update; .t count -displaylines 1.0 1.end", "0" },
        .{ "expr {[lindex [.t xview] 1] < 1.0}", "1" },
        .{ ".t xview moveto 1.0; expr {[lindex [.t xview] 0] > 0}", "1" },
    });
    try expectErrors(&h, &.{
        .{ ".t see", "wrong # args: should be \".t see index\"" },
        .{ ".t bbox", "wrong # args: should be \".t bbox index\"" },
        .{ ".t dlineinfo", "wrong # args: should be \".t dlineinfo index\"" },
        .{ ".t yview foo", "bad text index \"foo\"" },
        .{ ".t yview -pickplace", "wrong # args: should be \".t yview -pickplace lineNum|index\"" },
        .{ ".t xview foo", "bad option \"foo\": must be moveto or scroll" },
        .{ ".t yview moveto", "bad text index \"moveto\"" },
        .{ ".t yview scroll 1", "wrong # args: should be \".t yview scroll number units|pages|pixels\"" },
        .{ ".t yview scroll 1 foo", "bad argument \"foo\": must be units, pages, or pixels" },
    });
}

test "textw: undo, redo, edit, and the flag of edit modified" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("text .t");
    // The expected texts are from wish 8.6.16.
    try expectEvals(&h, &.{
        .{ ".t edit undo", "" },
        .{ ".t edit modified", "0" },
        .{ ".t edit canundo", "0" },
        .{ ".t configure -undo 1; .t insert end abc; .t insert end def; .t edit canundo", "1" },
        .{ ".t edit undo; .t get 1.0 end-1c", "" },
        .{ ".t edit canredo", "1" },
        .{ ".t edit redo; .t get 1.0 end-1c", "abcdef" },
        .{ ".t edit separator; .t delete 1.0 1.2; .t insert 1.0 XY; .t edit undo; .t get 1.0 end-1c", "cdef" },
        .{ ".t index insert", "1.0" },
        .{ ".t edit undo; .t get 1.0 end-1c", "abcdef" },
        .{ ".t edit undo; .t get 1.0 end-1c", "" },
        .{ ".t edit redo; .t get 1.0 end-1c", "abcdef" },
        .{ ".t edit reset; .t edit canundo", "0" },
        .{ ".t edit modified", "1" },
        .{ ".t configure -autoseparators 0; .t edit reset; .t insert end 1; .t insert end 2; .t delete 1.0; .t edit undo; .t get 1.0 end-1c", "abcdef" },
        .{ ".t configure -autoseparators 1 -maxundo 2; .t edit reset; .t delete 1.0 end; foreach c {a b c d} {.t insert end $c; .t edit separator}; .t edit undo; .t edit undo; catch {.t edit undo} r; list $r [.t get 1.0 end-1c]", "{nothing to undo} ab" },
        .{ "update; set n 0; bind .t <<Modified>> {incr n}; .t edit modified 0; update; .t insert end x; update; list $n [.t edit modified]", "2 1" },
    });
    try expectErrors(&h, &.{
        .{ ".t edit", "wrong # args: should be \".t edit option ?arg ...?\"" },
        .{ ".t edit bogus", "bad edit option \"bogus\": must be canundo, canredo, modified, redo, reset, separator, or undo" },
        .{ ".t edit modified 1 2", "wrong # args: should be \".t edit modified ?boolean?\"" },
        .{ ".t edit modified foo", "expected boolean value but got \"foo\"" },
        .{ ".t edit undo 1", "wrong # args: should be \".t edit undo\"" },
        .{ ".t edit reset; .t edit redo", "nothing to redo" },
    });
}

test "textw: the class bindings for keys, clicks, and the selection" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval(
        \\text .t -width 30 -height 5 -undo 1 -bd 0 -highlightthickness 0 -padx 0 -pady 0
        \\place .t -x 0 -y 0
        \\focus .t
        \\set sels 0
        \\bind .t <<Selection>> {incr sels}
        \\update
    );
    try h.head.typeText(h.win, "hello world");
    try h.head.press(h.win, "Return");
    try h.head.typeText(h.win, "two");
    try h.update();
    try t.expectEqualStrings("hello world\ntwo\n", try h.eval(".t get 1.0 end"));
    try t.expectEqualStrings("2.3", try h.eval(".t index insert"));
    try h.head.press(h.win, "Up");
    try h.head.press(h.win, "Home");
    try h.head.press(h.win, "Right");
    try h.head.press(h.win, "BackSpace");
    try h.update();
    try t.expectEqualStrings("ello world", try h.eval(".t get 1.0 1.end"));
    try h.head.press(h.win, "End");
    h.head.setMods(.{ .shift = true });
    try h.head.press(h.win, "Left");
    try h.head.press(h.win, "Left");
    h.head.setMods(.{});
    try h.update();
    try t.expectEqualStrings("1.8 1.10", try h.eval(".t tag ranges sel"));
    // A typed character replaces the selection.
    try h.head.typeText(h.win, "X");
    try h.update();
    try t.expectEqualStrings("ello worX", try h.eval(".t get 1.0 1.end"));
    try t.expectEqualStrings("1", try h.eval("expr {$sels > 0}"));
    // Control-z undoes the typed text and the delete of the selection.
    h.head.setMods(.{ .control = true });
    try h.head.press(h.win, "z");
    h.head.setMods(.{});
    try h.update();
    try t.expectEqualStrings("ello world", try h.eval(".t get 1.0 1.end"));
    // A double click selects a word.
    _ = try h.eval(".t tag remove sel 1.0 end; update");
    const box = try h.eval("lrange [.t bbox 1.1] 0 1");
    var it = std.mem.tokenizeScalar(u8, box, ' ');
    const bx = try std.fmt.parseFloat(f32, it.next().?);
    const by = try std.fmt.parseFloat(f32, it.next().?);
    h.head.pointerMove(h.win, bx + 1, by + 2);
    h.head.pointerButton(h.win, 1, true);
    h.head.pointerButton(h.win, 1, false);
    h.head.pointerButton(h.win, 1, true);
    h.head.pointerButton(h.win, 1, false);
    try h.update();
    try t.expectEqualStrings("1.0 1.4", try h.eval(".t tag ranges sel"));
    try t.expectEqualStrings("1", try h.eval("expr {[lsearch [.t mark names] tk::anchor1] >= 0}"));
    // The disabled state blocks the keys.
    _ = try h.eval(".t configure -state disabled");
    try h.head.typeText(h.win, "q");
    try h.update();
    try t.expectEqualStrings("ello world", try h.eval(".t get 1.0 1.end"));
}

test "textw: search and dump" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval(
        \\text .t
        \\.t insert end "hello world\nHello again\nfoo bar foo"
        \\.t tag add b 1.2 1.4
        \\.t mark set m 2.3
    );
    // The expected texts are from wish 8.6.16.
    try expectEvals(&h, &.{
        .{ ".t search hello 1.0", "1.0" },
        .{ ".t search hello 1.1", "1.0" },
        .{ ".t search -nocase hello 1.1", "2.0" },
        .{ ".t search -backwards hello end", "1.0" },
        .{ ".t search -backwards hello 1.3", "1.0" },
        .{ ".t search -regexp {o+ [a-z]} 1.0", "1.4" },
        .{ ".t search -count n -regexp {f.o} 1.0; set n", "3" },
        .{ ".t search -all foo 1.0", "3.0 3.8" },
        .{ ".t search -all -count c o 1.0 2.0; set c", "1 1" },
        .{ ".t search xyz 1.0", "" },
        .{ ".t search hello 1.1 2.0", "" },
        .{ ".t search \"world\\nHe\" 1.0", "1.6" },
        .{ ".t search -regexp -nocase {^hello} 2.0", "2.0" },
        .{ ".t search -- -x 1.0", "" },
        .{ ".t search {} 1.0", "1.0" },
        .{ ".t dump 1.0 end", "text he 1.0 tagon b 1.2 text ll 1.2 tagoff b 1.4 text {o world\n} 1.4 text Hel 2.0 mark m 2.3 text {lo again\n} 2.3 text {foo bar foo} 3.0 mark insert 3.11 mark current 3.11 text {\n} 3.11" },
        .{ ".t dump -text 1.0 2.0", "text he 1.0 text ll 1.2 text {o world\n} 1.4" },
        .{ ".t dump -mark 1.0 end", "mark m 2.3 mark insert 3.11 mark current 3.11" },
        .{ ".t dump -tag 1.0 end", "tagon b 1.2 tagoff b 1.4" },
        .{ ".t dump 1.3", "text l 1.3" },
        .{ "set r {}; .t dump -command {lappend ::r} 1.0 1.5; set r", "text he 1.0 tagon b 1.2 text ll 1.2 tagoff b 1.4 text o 1.4" },
        .{ ".t dump -all 1.0 1.3", "text he 1.0 tagon b 1.2 text l 1.2" },
    });
    try expectErrors(&h, &.{
        .{ ".t search", "wrong # args: should be \".t search ?switches? pattern index ?stopIndex?\"" },
        .{ ".t search -bogus x 1.0", "bad switch \"-bogus\": must be --, -all, -backwards, -count, -elide, -exact, -forwards, -nocase, -nolinestop, -overlap, -regexp, or -strictlimits" },
        .{ ".t search x", "wrong # args: should be \".t search ?switches? pattern index ?stopIndex?\"" },
        .{ ".t search -regexp {(} 1.0", "couldn't compile regular expression pattern: parentheses () not balanced" },
        .{ ".t dump", "Usage: .t dump ?-all -image -text -mark -tag -window? ?-command script? index ?index2?" },
        .{ ".t dump -bogus 1.0", "bad option \"-bogus\": must be -all, -command, -image, -mark, -tag, -text, or -window" },
    });
}

test "textw: debug and scan" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("text .t -height 5; pack .t; for {set i 1} {$i <= 50} {incr i} {.t insert end \"line $i\\n\"}; update");
    // The expected texts are from wish 8.6.16.
    try expectEvals(&h, &.{
        .{ ".t debug", "0" },
        .{ ".t debug 1; .t debug", "1" },
        .{ ".t scan mark 0 100; .t scan dragto 0 90; expr {[lindex [.t yview] 0] > 0}", "1" },
    });
    try expectErrors(&h, &.{
        .{ ".t debug foo", "expected boolean value but got \"foo\"" },
        .{ ".t debug 0 1", "wrong # args: should be \".t debug boolean\"" },
        .{ ".t scan", "wrong # args: should be \".t scan mark x y\" or \".t scan dragto x y ?gain?\"" },
        .{ ".t scan foo 1 2", "bad scan option \"foo\": must be mark or dragto" },
        .{ ".t scan mark x 2", "expected integer but got \"x\"" },
        .{ ".t scan dragto 1 2 3 4", "wrong # args: should be \".t scan mark x y\" or \".t scan dragto x y ?gain?\"" },
    });
}
