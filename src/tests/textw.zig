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
