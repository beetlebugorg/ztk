//! Tests of the canvas: the options and the messages of `wish` 8.6.16,
//! each item type, each subcommand, tag expressions, `find`, item
//! bindings with Enter and Leave, the scroll protocol with a scroll
//! region and increments, window items, the stand-in `image` command,
//! and `ztk::animate` on canvas items. The expected values come from
//! `wish` 8.6.16 under `xvfb-run`.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Harness = @import("../testing.zig").Harness;
const t = std.testing;

fn expectAll(h: *Harness, cases: []const [2][]const u8) !void {
    for (cases) |c| {
        const got = h.eval(c[0]) catch |e| {
            std.debug.print("script {s} failed: {s}\n", .{ c[0], h.it.str(h.it.result) catch "?" });
            return e;
        };
        t.expectEqualStrings(c[1], got) catch |e| {
            std.debug.print("script {s}\n", .{c[0]});
            return e;
        };
    }
}

fn expectErrors(h: *Harness, cases: []const [2][]const u8) !void {
    for (cases) |c| {
        const got = h.evalError(c[0]) catch |e| {
            std.debug.print("script {s} gave no error\n", .{c[0]});
            return e;
        };
        t.expectEqualStrings(c[1], got) catch |e| {
            std.debug.print("script {s}\n", .{c[0]});
            return e;
        };
    }
}

test "canvas: options and the messages of wish" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("canvas .c; .c create rectangle 0 0 1 1; image create photo p1 -width 4 -height 4");
    try expectAll(&h, &.{
        .{ ".c configure -confine", "-confine confine Confine 1 1" },
        .{ ".c configure -closeenough", "-closeenough closeEnough CloseEnough 1 1.0" },
        .{ ".c configure -scrollregion", "-scrollregion scrollRegion ScrollRegion {} {}" },
        .{ ".c configure -xscrollincrement", "-xscrollincrement xScrollIncrement ScrollIncrement 0 0" },
        .{ ".c cget -state", "normal" },
        .{ "llength [.c configure]", "29" },
    });
    try expectErrors(&h, &.{
        .{ ".c bogus", "bad option \"bogus\": must be addtag, bbox, bind, canvasx, canvasy, cget, configure, coords, create, dchars, delete, dtag, find, focus, gettags, icursor, imove, index, insert, itemcget, itemconfigure, lower, move, moveto, postscript, raise, rchars, scale, scan, select, type, xview, or yview" },
        .{ ".c create", "wrong # args: should be \".c create type coords ?arg ...?\"" },
        .{ ".c create foo 1 2", "unknown or ambiguous item type \"foo\"" },
        .{ ".c create rect 1 2", "wrong # coordinates: expected 0 or 4, got 2" },
        .{ ".c create line 1", "wrong # coordinates: expected an even number, got 1" },
        .{ ".c create rectangle 1 2 3 x", "bad screen distance \"x\"" },
        .{ ".c create oval 1 2 3 4 -bogus 1", "unknown option \"-bogus\"" },
        .{ ".c coords", "wrong # args: should be \".c coords tagOrId ?x y x y ...?\"" },
        .{ ".c find", "wrong # args: should be \".c find searchCommand ?arg ...?\"" },
        .{ ".c find bogus", "bad search command \"bogus\": must be above, all, below, closest, enclosed, overlapping, or withtag" },
        .{ ".c find closest", "wrong # args: should be \".c find closest x y ?halo? ?start?\"" },
        .{ ".c find above", "wrong # args: should be \".c find above tagOrId\"" },
        .{ ".c find overlapping 1 2 3", "wrong # args: should be \".c find overlapping x1 y1 x2 y2\"" },
        .{ ".c find all 1", "wrong # args: should be \".c find all\"" },
        .{ ".c move 1", "wrong # args: should be \".c move tagOrId xAmount yAmount\"" },
        .{ ".c scale 1 2", "wrong # args: should be \".c scale tagOrId xOrigin yOrigin xScale yScale\"" },
        .{ ".c bind 1 <Foo>", "bad event type or keysym \"Foo\"" },
        .{ ".c bind", "wrong # args: should be \".c bind tagOrId ?sequence? ?command?\"" },
        .{ ".c addtag", "wrong # args: should be \".c addtag tag searchCommand ?arg ...?\"" },
        .{ ".c addtag x bogus", "bad search command \"bogus\": must be above, all, below, closest, enclosed, overlapping, or withtag" },
        .{ ".c find withtag {a &&}", "missing tag in tag search expression" },
        .{ ".c find withtag {!}", "missing tag in tag search expression" },
        .{ ".c xview bogus", "unknown option \"bogus\": must be moveto or scroll" },
        .{ ".c postscript", "postscript is not supported in this stage" },
        .{ ".c create rectangle 0 0 10 10 -fill bogus", "unknown color name \"bogus\"" },
        .{ ".c create rectangle 0 0 10 10 -width x", "bad screen distance \"x\"" },
        .{ ".c create rectangle 0 0 10 10 -state x", "bad state value \"x\": must be normal, hidden, or disabled" },
        .{ ".c create line 0 0 10 10 -arrow x", "bad arrow spec \"x\": must be none, first, last, or both" },
        .{ ".c create line 0 0 10 10 -capstyle x", "bad cap style \"x\": must be butt, projecting, or round" },
        .{ ".c create line 0 0 10 10 -joinstyle x", "bad join style \"x\": must be bevel, miter, or round" },
        .{ ".c create line 0 0 10 10 -smooth x", "expected boolean value but got \"x\"" },
        .{ ".c create line 0 0 10 10 -dash x", "expected integer in the range 1..255 but got \"x\"" },
        .{ ".c create arc 0 0 10 10 -style x", "bad -style option \"x\": must be arc, chord, or pieslice" },
        .{ ".c create text 0 0 -anchor x", "bad anchor position \"x\": must be n, ne, e, se, s, sw, w, nw, or center" },
        .{ ".c create image 0 0 -image nope", "image \"nope\" doesn't exist" },
        .{ ".c create bitmap 0 0 -bitmap nope", "bitmap \"nope\" not defined" },
        .{ ".c create window 0 0 -window .nope", "bad window path name \".nope\"" },
        .{ ".c configure -scrollregion {1 2 3}", "bad scrollRegion \"1 2 3\"" },
        .{ ".c configure -state foo", "bad state value \"foo\": must be normal or disabled" },
        .{ ".c canvasx", "wrong # args: should be \".c canvasx screenx ?gridspacing?\"" },
        .{ ".c canvasx 1 x", "bad screen distance \"x\"" },
        .{ ".c gettags", "wrong # args: should be \".c gettags tagOrId\"" },
        .{ ".c type", "wrong # args: should be \".c type tag\"" },
        .{ ".c bbox", "wrong # args: should be \".c bbox tagOrId ?tagOrId ...?\"" },
        .{ ".c lower", "wrong # args: should be \".c lower tagOrId ?belowThis?\"" },
        .{ ".c raise", "wrong # args: should be \".c raise tagOrId ?aboveThis?\"" },
        .{ ".c moveto 1 2", "wrong # args: should be \".c moveto tagOrId x y\"" },
        .{ ".c dchars", "wrong # args: should be \".c dchars tagOrId first ?last?\"" },
        .{ ".c insert 1", "wrong # args: should be \".c insert tagOrId beforeThis string\"" },
        .{ ".c index 1", "wrong # args: should be \".c index tagOrId string\"" },
        .{ ".c icursor 1", "wrong # args: should be \".c icursor tagOrId index\"" },
        .{ ".c select", "wrong # args: should be \".c select option ?tagOrId? ?arg?\"" },
        .{ ".c select bogus", "bad select option \"bogus\": must be adjust, clear, from, item, or to" },
        .{ ".c focus 1 2", "wrong # args: should be \".c focus ?tagOrId?\"" },
        .{ ".c itemcget 1", "wrong # args: should be \".c itemcget tagOrId option\"" },
        .{ ".c itemcget 1 -bogus", "unknown option \"-bogus\"" },
        .{ ".c dtag", "wrong # args: should be \".c dtag tagOrId ?tagToDelete?\"" },
        .{ ".c rchars 1 2", "wrong # args: should be \".c rchars tagOrId first last string\"" },
        .{ ".c imove 1 2", "wrong # args: should be \".c imove tagOrId index x y\"" },
        .{ ".c scan", "wrong # args: should be \".c scan mark|dragto x y ?dragGain?\"" },
        .{ ".c scan bogus 1 2", "bad scan option \"bogus\": must be mark or dragto" },
        .{ ".c index 1 bogus", "can't find an indexable item \"1\"" },
        .{ "image create bogus", "image type \"bogus\" doesn't exist" },
        .{ "image create photo -file /nonexistent.png", "couldn't open \"/nonexistent.png\": no such file or directory" },
        .{ "image delete nope", "image \"nope\" doesn't exist" },
        .{ "image width nope", "image \"nope\" doesn't exist" },
        .{ "image", "wrong # args: should be \"image option ?args?\"" },
        .{ "image bogus", "bad option \"bogus\": must be create, delete, height, inuse, names, type, types, or width" },
    });
    // A bad scroll region keeps the old value.
    _ = try h.eval(".c configure -scrollregion {0 0 10 10}");
    _ = try h.evalError(".c configure -scrollregion bad");
    try t.expectEqualStrings("0 0 10 10", try h.eval(".c cget -scrollregion"));
}

test "canvas: the defaults of each item type" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("canvas .c; image create photo p1 -width 4 -height 4");
    const cases = [_][2][]const u8{
        .{ "arc {0 0 10 10}", "-activedash {} -activefill {} -activeoutline {} -activeoutlinestipple {} -activestipple {} -activewidth 0.0 -dash {} -dashoffset 0 -disableddash {} -disabledfill {} -disabledoutline {} -disabledoutlinestipple {} -disabledstipple {} -disabledwidth 0.0 -extent 90 -fill {} -offset 0,0 -outline #000000 -outlineoffset 0,0 -outlinestipple {} -start 0 -state {} -stipple {} -style {} -tags {} -width 1.0" },
        .{ "bitmap {5 5}", "-activebackground {} -activebitmap {} -activeforeground {} -anchor center -background {} -bitmap {} -disabledbackground {} -disabledbitmap {} -disabledforeground {} -foreground #000000 -state {} -tags {}" },
        .{ "image {5 5}", "-activeimage {} -anchor center -disabledimage {} -image {} -state {} -tags {}" },
        .{ "line {0 0 10 10}", "-activedash {} -activefill {} -activestipple {} -activewidth 0.0 -arrow none -arrowshape {8 10 3} -capstyle butt -fill #000000 -dash {} -dashoffset 0 -disableddash {} -disabledfill {} -disabledstipple {} -disabledwidth 0.0 -joinstyle round -offset 0,0 -smooth 0 -splinesteps 12 -state {} -stipple {} -tags {} -width 1.0" },
        .{ "oval {0 0 10 10}", "-activedash {} -activefill {} -activeoutline {} -activeoutlinestipple {} -activestipple {} -activewidth 0.0 -dash {} -dashoffset 0 -disableddash {} -disabledfill {} -disabledoutline {} -disabledoutlinestipple {} -disabledstipple {} -disabledwidth 0.0 -fill {} -offset 0,0 -outline #000000 -outlineoffset 0,0 -outlinestipple {} -state {} -stipple {} -tags {} -width 1.0" },
        .{ "polygon {0 0 10 10 5 5}", "-activedash {} -activefill {} -activeoutline {} -activeoutlinestipple {} -activestipple {} -activewidth 0.0 -dash {} -dashoffset 0 -disableddash {} -disabledfill {} -disabledoutline {} -disabledoutlinestipple {} -disabledstipple {} -disabledwidth 0.0 -fill #000000 -joinstyle round -offset 0,0 -outline {} -outlineoffset 0,0 -outlinestipple {} -smooth 0 -splinesteps 12 -state {} -stipple {} -tags {} -width 1.0" },
        .{ "rectangle {0 0 10 10}", "-activedash {} -activefill {} -activeoutline {} -activeoutlinestipple {} -activestipple {} -activewidth 0.0 -dash {} -dashoffset 0 -disableddash {} -disabledfill {} -disabledoutline {} -disabledoutlinestipple {} -disabledstipple {} -disabledwidth 0.0 -fill {} -offset 0,0 -outline #000000 -outlineoffset 0,0 -outlinestipple {} -state {} -stipple {} -tags {} -width 1.0" },
        .{ "text {5 5}", "-activefill {} -activestipple {} -anchor center -angle 0.0 -disabledfill {} -disabledstipple {} -fill #000000 -font TkDefaultFont -justify left -offset 0,0 -state {} -stipple {} -tags {} -text {} -underline -1 -width 0" },
        .{ "window {5 5}", "-anchor center -height 0 -state {} -tags {} -width 0 -window {}" },
    };
    for (cases) |c| {
        var buf: [512]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "set id [.c create {s}]; set l {{}}; foreach o [.c itemconfigure $id] {{ lappend l [lindex $o 0] [lindex $o 3] }}; set l", .{c[0]});
        try t.expectEqualStrings(c[1], try h.eval(s));
    }
}

test "canvas: coordinates, bbox, find, tags, and text editing as in wish" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("canvas .c -width 200 -height 100 -highlightthickness 0 -bd 0; pack .c; update");
    try expectAll(&h, &.{
        .{ ".c create rectangle 10 10 50 30", "1" },
        .{ ".c bbox 1", "9 9 51 31" },
        .{ ".c create rectangle 10 10 50 30 -width 4", "2" },
        .{ ".c bbox 2", "8 8 52 32" },
        .{ ".c create oval 0 0 20 20 -width 0", "3" },
        .{ ".c bbox 3", "0 0 20 20" },
        .{ ".c create line 0 0 100 0 -width 3", "4" },
        .{ ".c bbox 4", "-4 -4 104 4" },
        .{ ".c create line 0 0 100 0 -arrow last", "5" },
        .{ ".c bbox 5", "-2 -4 102 5" },
        .{ ".c create polygon 0 0 10 0 5 10", "6" },
        .{ ".c bbox 6", "-1 -1 11 11" },
        .{ ".c create text 50 50 -text hello", "7" },
        .{ ".c create arc 0 0 100 100 -start 0 -extent 90", "8" },
        .{ ".c bbox 8", "48 -2 102 52" },
        .{ ".c coords 1", "10.0 10.0 50.0 30.0" },
        .{ ".c move 1 1.5 2; .c coords 1", "11.5 12.0 51.5 32.0" },
        .{ ".c scale 1 0 0 2 0.5; .c coords 1", "23.0 6.0 103.0 16.0" },
        .{ ".c find overlapping 0 0 20 20", "2 3 4 5 6" },
        .{ ".c find enclosed -5 -5 60 40", "2 3 6" },
        .{ ".c find closest 52 31", "2" },
        .{ ".c addtag foo withtag 1; .c addtag bar all; .c gettags 1", "foo bar" },
        .{ ".c find withtag {foo&&bar}", "1" },
        .{ ".c find withtag {!foo}", "2 3 4 5 6 7 8" },
        .{ ".c find withtag {foo^bar}", "2 3 4 5 6 7 8" },
        .{ ".c find withtag {(foo||bar)&&!foo}", "2 3 4 5 6 7 8" },
        .{ ".c dtag 1 bar; .c gettags 1", "foo" },
        .{ ".c type 7", "text" },
        .{ ".c insert 7 2 XX; .c itemcget 7 -text", "heXXllo" },
        .{ ".c index 7 end", "7" },
        .{ ".c dchars 7 0 1; .c itemcget 7 -text", "XXllo" },
        .{ ".c rchars 7 0 0 Q; .c itemcget 7 -text", "QXllo" },
        .{ ".c raise 1; .c find all", "2 3 4 5 6 7 8 1" },
        .{ ".c lower 1 3; .c find all", "2 1 3 4 5 6 7 8" },
        .{ ".c find above 1", "3" },
        .{ ".c find below 1", "2" },
        .{ ".c moveto 1 100 100; .c coords 1", "101.0 101.0 181.0 111.0" },
        .{ ".c imove 6 1 50 50; .c coords 6", "50.0 50.0 10.0 0.0 5.0 10.0" },
        .{ ".c itemconfigure 1 -fill", "-fill {} {} {} {}" },
        .{ ".c itemconfigure 1 -tags", "-tags {} {} {} foo" },
        .{ ".c create line 0 0 10 10 20 0 -smooth 1", "9" },
        .{ ".c bbox 9", "-2 -2 22 12" },
        .{ ".c create oval 0 0 10 10 -state hidden", "10" },
        .{ ".c find overlapping 0 0 5 5", "3 4 5 9" },
        .{ ".c focus", "" },
        .{ ".c focus 7; .c focus", "7" },
        .{ ".c icursor 7 2; .c index 7 insert", "2" },
        .{ ".c select from 7 0; .c select to 7 2; .c select item", "7" },
        .{ ".c index 7 sel.first", "0" },
        .{ ".c index 7 sel.last", "2" },
        .{ ".c bind 1 <Enter> {puts hi}; .c bind 1", "<Enter>" },
        .{ ".c bind 1 <Enter>", "puts hi" },
        .{ ".c delete 1; .c find all", "2 3 4 5 6 7 8 9 10" },
        .{ ".c bbox nothing", "" },
        .{ ".c insert 6 2 {7 8}; .c coords 6", "50.0 50.0 7.0 8.0 10.0 0.0 5.0 10.0" },
        .{ ".c dchars 6 2; .c coords 6", "50.0 50.0 10.0 0.0 5.0 10.0" },
        .{ ".c itemconfigure 4 -tags {a b a}; .c gettags 4", "a b" },
        .{ ".c delete a; .c find withtag b", "" },
    });
}

test "canvas: the scroll protocol with a scroll region and increments" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("set log {}; canvas .c -width 200 -height 100 -highlightthickness 0 -bd 0 -xscrollcommand {lappend log}; pack .c; update");
    try expectAll(&h, &.{
        .{ ".c canvasx 10", "10.0" },
        .{ ".c xview", "0.0 1.0" },
        .{ ".c xview scroll 1 units; .c canvasx 0", "20.0" },
        .{ ".c xview", "0.0 1.0" },
        .{ ".c xview moveto 0; .c canvasx 0", "0.0" },
        .{ ".c configure -scrollregion {0 0 1000 500}; update; .c xview", "0.0 0.2" },
        .{ ".c yview", "0.0 0.2" },
        .{ ".c canvasx 0", "0.0" },
        .{ ".c xview scroll 1 units; .c canvasx 0", "20.0" },
        .{ ".c xview scroll 1 pages; .c canvasx 0", "200.0" },
        .{ ".c xview", "0.2 0.4" },
        .{ ".c xview moveto 0.5; .c canvasx 0", "500.0" },
        .{ ".c xview moveto 1; .c canvasx 0", "800.0" },
        .{ ".c configure -xscrollincrement 25; .c xview moveto 0.0; .c xview scroll 1 units; .c canvasx 0", "25.0" },
        .{ ".c canvasx 13 10", "40.0" },
        .{ "update; lrange $log end-1 end", "0.025 0.225" },
        .{ ".c configure -xscrollincrement 0; .c scan mark 100 0; .c scan dragto 90 0 1; .c canvasx 0", "35.0" },
        .{ ".c xview moveto 0; .c yview moveto 0; update; event generate .c <MouseWheel> -delta -120 -x 50 -y 50; .c canvasy 0", "20.0" },
    });
}

test "canvas: item bindings, Enter and Leave, and the current item" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval(
        \\set log {}
        \\canvas .c -width 200 -height 100 -highlightthickness 0 -bd 0; place .c -x 0 -y 0
        \\.c create rectangle 10 10 50 50 -fill red -activefill blue -tags box
        \\.c create oval 100 10 140 50 -fill green -tags round
        \\.c bind box <Enter> {lappend log enter-box}
        \\.c bind box <Leave> {lappend log leave-box}
        \\.c bind all <Enter> {lappend log enter-all}
        \\.c bind round <Button-1> {lappend log click-%x-%y}
        \\.c bind 2 <ButtonRelease-1> {lappend log release}
        \\bind .c <Button-1> {lappend log widget}
        \\update
    );
    h.head.pointerMove(h.win, 30, 30);
    try h.update();
    try t.expectEqualStrings("enter-all enter-box", try h.eval("set log"));
    try t.expectEqualStrings("1", try h.eval(".c find withtag current"));
    try t.expectEqualStrings("box current", try h.eval(".c gettags current"));
    h.head.pointerMove(h.win, 120, 30);
    try h.update();
    try t.expectEqualStrings("enter-all enter-box leave-box enter-all", try h.eval("set log"));
    _ = try h.eval("set log {}");
    h.head.pointerButton(h.win, 1, true);
    try h.update();
    h.head.pointerButton(h.win, 1, false);
    try h.update();
    // The item binding runs before the binding of the widget.
    try t.expectEqualStrings("click-120-30 widget release", try h.eval("set log"));
    h.head.pointerMove(h.win, 180, 90);
    try h.update();
    try t.expectEqualStrings("", try h.eval(".c find withtag current"));
    // A disabled item is not the current item.
    _ = try h.eval(".c itemconfigure box -state disabled");
    h.head.pointerMove(h.win, 30, 30);
    try h.update();
    try t.expectEqualStrings("", try h.eval(".c find withtag current"));
}

test "canvas: each item type paints, in light and dark" {
    for ([_]bool{ false, true }) |dark| {
        var h: Harness = undefined;
        try h.initExamples(dark);
        defer h.deinit();
        _ = try h.eval(
            \\image create photo pic -width 4 -height 2
            \\pic put {{red green blue #ffffff} {#000000 #000000 red red}}
            \\canvas .c -width 300 -height 200; pack .c
            \\.c create rectangle 10 10 60 40 -fill #ff0000 -outline #000000 -width 2
            \\.c create oval 70 10 110 50 -fill #00ff00
            \\.c create oval 120 10 180 40 -fill #0000ff -outline #ff0000 -dash {4 2}
            \\.c create arc 190 10 240 60 -start 30 -extent 120 -fill yellow
            \\.c create line 10 60 100 60 100 100 -width 3 -arrow both -smooth 1
            \\.c create line 10 120 100 120 -dash . -capstyle round
            \\.c create polygon 120 60 160 60 140 100 -fill purple -outline black -width 2
            \\.c create text 200 100 -text "Hello\nworld" -anchor nw -underline 0
            \\.c create image 20 150 -image pic -anchor nw
            \\.c create bitmap 60 160 -bitmap error
            \\button .c.b -text Go
            \\.c create window 250 160 -window .c.b
            \\update
        );
        const sc = h.app.lastScene();
        try t.expect(sc.quads.items.len > 40);
        // The window item placed its button.
        try expectAll(&h, &.{
            .{ "winfo ismapped .c.b", "1" },
            .{ "winfo manager .c.b", "canvas" },
            .{ "expr {abs([winfo x .c.b] + [winfo width .c.b]/2 - 250) <= 1}", "1" },
            .{ "image names", "pic" },
            .{ "list [image width pic] [image height pic]", "4 2" },
            .{ "pic get 1 0", "0 128 0" },
            .{ ".c bbox 9", "20 150 24 152" },
            .{ ".c bbox 10", "52 152 69 169" },
        });
        // Deleting the button clears the window option.
        _ = try h.eval("destroy .c.b; update");
        try t.expectEqualStrings("", try h.eval(".c itemcget 11 -window"));
    }
}

test "canvas: ztk::animate moves items, with a frame in the middle and a replace" {
    var h: Harness = undefined;
    try h.initAnimated();
    defer h.deinit();
    _ = try h.eval(
        \\canvas .c -width 200 -height 100 -highlightthickness 0 -bd 0; pack .c
        \\.c create rectangle 0 0 10 10 -fill #000000 -outline {} -tags r
        \\update
        \\set t0 [ztk::clock get]
        \\set id [ztk::animate {.c r} -coords {100 0 110 10} -fill #ff0000 -duration 100 -easing linear -command {set done 1}]
        \\update
    );
    try t.expect(std.mem.startsWith(u8, try h.eval("set id"), "anim#"));
    try t.expect(std.mem.indexOf(u8, try h.eval("ztk::animate info $id"), "-target {.c 1}") != null);
    // The render thread gets the quads now and at the end.
    const f = h.app.render.last.?;
    try t.expectEqual(@as(usize, 1), f.anims.items.len);
    const t0 = f.time_us;
    try t.expect(h.app.render.advance(t0 + 50_000));
    const q = f.scene.quads.items[f.anims.items[0].first];
    try t.expectApproxEqAbs(@as(f32, 50), q.rect[0], 1);
    try t.expectApproxEqAbs(@as(f32, 0.5), q.fill[0], 0.02);
    // A frame of the App at a fixed time in the middle.
    _ = try h.eval("ztk::clock set [expr {$t0 + 50}]; update");
    try t.expectEqualStrings("50.0", try h.eval("lindex [.c coords 1] 0"));
    // A replace starts from the shown value.
    _ = try h.eval("ztk::animate {.c 1} -coords {0 50 10 60} -duration 100 -easing linear; ztk::clock set [expr {$t0 + 100}]; update");
    try t.expectEqualStrings("25.0 25.0", try h.eval("lrange [.c coords 1] 0 1"));
    _ = try h.eval("ztk::clock set [expr {$t0 + 300}]; update; update");
    try t.expectEqualStrings("0.0 50.0 10.0 60.0", try h.eval(".c coords 1"));
    try t.expectEqualStrings("#ff0000", try h.eval(".c itemcget 1 -fill"));
    try t.expectEqualStrings("", try h.eval("ztk::animate info"));
    try t.expectEqualStrings("1", try h.eval("set done"));
}

test "canvas: ztk::limit bounds a child interpreter of the console of the vector app" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("interp create con");
    try t.expectEqualStrings("step limit reached", try h.eval("catch {ztk::limit -steps 1000 {interp eval con {while 1 {}}}} e; set e"));
    try t.expectEqualStrings("the script used too much memory", try h.eval("catch {ztk::limit -steps 100000 -memory 1000000 {interp eval con {set s x; while 1 {append s $s}}}} e; set e"));
    // One large request: the heap refuses it before the allocation.
    try t.expectEqualStrings("the script used too much memory", try h.eval("catch {ztk::limit -memory 1000000 {interp eval con {string repeat x 5000000}}} e; set e"));
    try t.expectEqualStrings("10", try h.eval("ztk::limit -steps 1000 {interp eval con {set a 0; for {set i 0} {$i < 10} {incr i} {incr a}; set a}}"));
    try t.expectEqualStrings("100", try h.eval("set n 0; for {set i 0} {$i < 100} {incr i} {incr n}; set n"));
    try t.expectEqualStrings("wrong # args: should be \"ztk::limit ?-steps count? ?-memory bytes? script\"", try h.evalError("ztk::limit -steps 1"));
}
