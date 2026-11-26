//! Tests of `ttk::treeview`: the subcommands, the events, the keys, a
//! column resize, and the messages of `wish` 8.6.16.
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

const treeview = @import("../ttk/treeview.zig");

test "treeview: options, items, and the messages of wish" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("ttk::treeview .t; pack .t");
    try expectEvals(&h, &.{
        .{ ".t configure -displaycolumns", "-displaycolumns displayColumns DisplayColumns #all #all" },
        .{ ".t configure -show", "-show show Show {tree headings} {tree headings}" },
        .{ ".t configure -emptytext", "-emptytext emptyText EmptyText {} {}" },
        .{ ".t insert {} end", "I001" },
        .{ ".t insert {} end -id a -text A -values {1 2} -open 1 -tags {x y}", "a" },
        .{ ".t item a", "-text A -image {} -values {1 2} -open 1 -tags {x y}" },
        .{ ".t item I001", "-text {} -image {} -values {} -open 0 -tags {}" },
        .{ ".t item {}", "-text {} -image {} -values {} -open 0 -tags {}" },
        .{ ".t column #0", "-width 200 -minwidth 20 -stretch 1 -anchor w -id {}" },
        .{ ".t heading #0", "-text {} -image {} -anchor center -command {} state {}" },
        .{ ".t tag configure x", "-text {} -image {} -anchor {} -background {} -foreground {} -font {}" },
        .{ ".t configure -columns {c1 c2}; .t column c1", "-width 200 -minwidth 20 -stretch 1 -anchor w -id c1" },
        .{ ".t column #1 -id", "c1" },
        .{ ".t column 1 -id", "c2" },
        .{ ".t heading c1 -text H1; .t heading c1 -text", "H1" },
        .{ ".t set a", "c1 1 c2 2" },
        .{ ".t set a c1", "1" },
        .{ ".t set a c1 v; .t set a", "c1 v c2 2" },
        .{ ".t insert {} end -id b; .t set b c2 w; .t item b -values", "{} w" },
        .{ ".t children {}", "I001 a b" },
        .{ ".t index a", "1" },
        .{ ".t next a", "b" },
        .{ ".t prev a", "I001" },
        .{ ".t parent a", "" },
        .{ ".t exists zz", "0" },
        .{ ".t insert a end -id a1; .t move b a 0; .t children a", "b a1" },
        .{ ".t detach b; .t children a", "a1" },
        .{ ".t exists b", "1" },
        .{ ".t move b {} end; .t children {}", "I001 a b" },
        .{ ".t children a {b}; .t children a", "b" },
        .{ ".t exists a1", "1" },
        .{ ".t delete a; .t exists b", "0" },
        .{ ".t configure -displaycolumns {c2}; .t column #1 -id", "c2" },
        .{ ".t tag add t1 {I001}; .t tag has t1", "I001" },
        .{ ".t tag has t1 I001", "1" },
        .{ ".t tag remove t1 I001; .t tag has t1", "" },
        .{ ".t tag bind t1 <1> {set hit 1}; .t tag bind t1", "<Button-1>" },
        .{ ".t tag bind t1 <1>", "set hit 1" },
        .{ ".t tag names", "x y t1" },
        .{ ".t selection set I001; .t selection", "I001" },
        .{ ".t selection toggle I001; .t selection", "" },
        .{ ".t focus I001; .t focus", "I001" },
    });
    try expectErrors(&h, &.{
        .{ ".t foo", "bad command \"foo\": must be bbox, children, cget, column, configure, delete, detach, drag, drop, exists, focus, heading, identify, index, instate, insert, item, move, next, parent, prev, see, selection, set, state, tag, xview, or yview" },
        .{ ".t insert", "wrong # args: should be \".t insert parent index ?-id id? -options...\"" },
        .{ ".t insert {} end -id I001", "Item I001 already exists" },
        .{ ".t insert nope end", "Item nope not found" },
        .{ ".t insert {} foo", "expected integer but got \"foo\"" },
        .{ ".t insert {} end -foo 1", "unknown option \"-foo\"" },
        .{ ".t insert {} end -open x", "expected boolean value but got \"x\"" },
        .{ ".t item I001 -bogus", "unknown option \"-bogus\"" },
        .{ ".t column c3", "Invalid column index c3" },
        .{ ".t column #3", "Column #3 out of range" },
        .{ ".t column c1 -width x", "expected integer but got \"x\"" },
        .{ ".t column c1 -anchor x", "bad anchor \"x\": must be n, ne, e, se, s, sw, w, nw, or center" },
        .{ ".t column c1 -id b", "Attempt to change read-only option" },
        .{ ".t column c1 -stretch x", "expected boolean value but got \"x\"" },
        .{ ".t heading c1 -foo 1", "unknown option \"-foo\"" },
        .{ ".t tag configure t1 -foo 1", "unknown option \"-foo\"" },
        .{ ".t tag foo", "bad command \"foo\": must be add, bind, configure, has, names, or remove" },
        .{ ".t move I001 I001 0", "Cannot insert I001 as descendant of I001" },
        .{ ".t selection foo", "wrong # args: should be \".t selection ?add|remove|set|toggle items?\"" },
        .{ ".t selection set nope", "Item nope not found" },
        .{ ".t focus nope", "Item nope not found" },
        .{ ".t identify", "wrong # args: should be \".t identify command x y\"" },
        .{ ".t identify foo 5 5", "bad command \"foo\": must be region, item, column, row, or element" },
        .{ ".t configure -displaycolumns {zz}", "Invalid column index zz" },
        .{ ".t configure -selectmode foo", "bad selectmode \"foo\": must be none, browse, or extended" },
        .{ ".t configure -show foo", "bad value \"foo\": must be tree or headings" },
    });
}

test "treeview: identify, bbox, the keys, the pointer, the events, and a column resize" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval(
        \\ttk::treeview .t -columns {a b}; pack .t
        \\.t insert {} end -id p -text P
        \\.t insert p end -id c1 -text C1 -values {x y}
        \\.t insert p end -id c2 -text C2
        \\.t insert {} 0 -id q -text Q
        \\set ev {}
        \\bind .t <<TreeviewSelect>> {lappend ev select}
        \\bind .t <<TreeviewOpen>> {lappend ev open[.t item [.t focus] -open]}
        \\bind .t <<TreeviewClose>> {lappend ev close[.t item [.t focus] -open]}
        \\update
    );
    _ = try h.eval("lassign [.t bbox q] qx qy qw qh; lassign [.t bbox p] px py pw ph; set hy [expr {$qy - 5}]");
    try expectEvals(&h, &.{
        .{ "expr {$py - $qy == $qh}", "1" },
        .{ ".t identify region 5 [expr {$qy + 2}]", "tree" },
        .{ ".t identify item 5 [expr {$py + 2}]", "p" },
        .{ ".t identify column [expr {[lindex [.t bbox q #1] 0] + 3}] [expr {$qy + 2}]", "#1" },
        .{ ".t identify region 5 $hy", "heading" },
        .{ ".t identify 5 $hy", "heading #0" },
        .{ ".t identify region [expr {[lindex [.t bbox q #1] 0]}] $hy", "separator" },
        .{ ".t bbox c1", "" },
        .{ "event generate .t <Button-1> -x 80 -y [expr {$qy + 2}]; event generate .t <ButtonRelease-1> -x 80 -y [expr {$qy + 2}]; update; .t selection", "q" },
        .{ "set ev", "select" },
        .{ "focus -force .t; event generate .t <Key-Down>; update; list [.t focus] [.t selection]", "p p" },
        .{ "event generate .t <Key-Right>; update; list [.t item p -open] $ev", "1 {select select open0}" },
        .{ "event generate .t <Key-Right>; event generate .t <Shift-Key-Down>; update; .t selection", "c1 c2" },
        .{ "set ev {}; .t focus p; event generate .t <Key-Left>; update; list [.t item p -open] $ev", "0 close0" },
        .{ ".t configure -selectmode browse; .t selection set q; event generate .t <Control-Button-1> -x 80 -y [expr {$py + 2}]; update; .t selection", "p" },
        .{ ".t column a -width 120 -stretch 0; .t column #0 -stretch 0; .t column b -stretch 0; .t column a -width", "120" },
        .{ "set x0 [lindex [.t bbox q #2] 0]; event generate .t <Button-1> -x $x0 -y $hy; event generate .t <B1-Motion> -x [expr {$x0 + 30}] -y $hy; event generate .t <ButtonRelease-1> -x [expr {$x0 + 30}] -y $hy; update; .t column a -width", "150" },
        .{ ".t drag a [expr {[lindex [.t bbox q #1] 0] + 70}]; .t column a -width", "70" },
        .{ ".t heading #0 -command {set hc 1}; event generate .t <Button-1> -x 20 -y $hy; event generate .t <ButtonRelease-1> -x 20 -y $hy; set hc", "1" },
        .{ ".t tag add t1 q; .t tag bind t1 <Button-1> {set tg %x}; event generate .t <Button-1> -x 30 -y [expr {$qy + 2}]; set tg", "30" },
        .{ ".t delete [.t children {}]; .t configure -emptytext Nothing; update; .t children {}", "" },
    });
}

test "treeview: an item opens with a move of the rows, a frame in the middle, and a change during the move" {
    var h: Harness = undefined;
    try h.initAnimated();
    defer h.deinit();
    _ = try h.eval(
        \\ttk::treeview .t; pack .t
        \\.t insert {} end -id p -text P
        \\foreach i {1 2 3} {.t insert p end -text C$i}
        \\update
    );
    const w = h.app.find(".t").?;
    try t.expectEqual(@as(f32, 0), treeview.openShownOf(w, "p"));
    _ = try h.eval(".t item p -open 1; update");
    // The script sees the end state at once.
    try expectEvals(&h, &.{.{ ".t item p -open", "1" }});
    h.head.advance(80);
    try h.update();
    const mid = treeview.openShownOf(w, "p");
    try t.expect(mid > 0 and mid < 1);
    // A close in the middle starts from the shown fraction.
    _ = try h.eval(".t item p -open 0; update");
    try t.expectApproxEqAbs(mid, treeview.openShownOf(w, "p"), 0.05);
    h.head.advance(300);
    try h.update();
    try t.expectEqual(@as(f32, 0), treeview.openShownOf(w, "p"));
}

test "treeview: a result of a subcommand stays after a delete of its item" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    // The text of an item, an element of it, and an id from children
    // keep their value after the item goes away and new items reuse the
    // memory of the widget.
    _ = try h.eval("ttk::treeview .t; .t insert {} end -id a -text hello.rom; set x [.t item a -text]; " ++
        "set y [lindex [.t item a -text] 0]; set k [lindex [.t children {}] 0]; .t delete a; " ++
        "for {set i 0} {$i < 20} {incr i} { .t insert {} end -id b$i -text [string repeat Z 9] }");
    try t.expectEqualStrings("hello.rom hello.rom a", try h.eval("list $x $y $k"));
}
