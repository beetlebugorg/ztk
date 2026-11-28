//! Tests of the button: its command, the pointer and keyboard paths, the
//! states, and the golden images. The expected texts are from `wish`
//! 8.6.16.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Harness = @import("../testing.zig").Harness;
const testing_h = @import("../testing.zig");
const t = std.testing;

fn setup(h: *Harness) !void {
    try h.init();
    _ = try h.eval("set n 0; button .b -text OK -command {incr n}; grid .b -padx 20 -pady 20; update");
}

fn center(h: *Harness, path: []const u8) [2]f32 {
    const w = h.app.find(path).?;
    return .{ @floatFromInt(w.geom.x + @divTrunc(w.geom.w, 2)), @floatFromInt(w.geom.y + @divTrunc(w.geom.h, 2)) };
}

fn n(h: *Harness) ![]const u8 {
    return h.eval("set n");
}

test "button: invoke, results, and disabled" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    _ = try h.eval(".b invoke; .b invoke");
    try t.expectEqualStrings("2", try n(&h));
    _ = try h.eval("button .r -command {return 7}");
    try t.expectEqualStrings("7", try h.eval(".r invoke"));
    _ = try h.eval(".b configure -state disabled");
    try t.expectEqualStrings("", try h.eval(".b invoke"));
    try t.expectEqualStrings("2", try n(&h));
    try t.expectEqualStrings("wrong # args: should be \".b invoke\"", try h.evalError(".b invoke extra"));
    try t.expectEqualStrings("", try h.eval(".b flash"));
    try t.expectEqualStrings("2", try n(&h));
    try t.expectEqualStrings("wrong # args: should be \".b flash\"", try h.evalError(".b flash now"));
    try t.expectEqualStrings("bad option \"foo\": must be cget, configure, flash, or invoke", try h.evalError(".b foo"));
    try t.expectEqualStrings("image \"x\" doesn't exist", try h.evalError("button .q -image x"));
}

/// The message and the `-errorcode` of an error of `script`, as Tk 8.6.15 gives them.
fn codeOf(h: *Harness, script: []const u8) ![]const u8 {
    const a = std.testing.allocator;
    const wrapped = try std.fmt.allocPrint(a, "list [catch {{{s}}} m o] $m [dict get $o -errorcode]", .{script});
    defer a.free(wrapped);
    return h.eval(wrapped);
}

test "button: the codes of the errors" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    const cases = [_][2][]const u8{
        .{ "button .x -text a -foo b", "1 {unknown option \"-foo\"} {TK LOOKUP OPTION -foo}" },
        .{ "button .b", "1 {window name \"b\" already exists in parent} {TK VALUE WINDOW EXISTS}" },
        .{ "button .no.b", "1 {bad window path name \".no\"} {TK LOOKUP WINDOW .no}" },
        .{ "button 1x", "1 {bad window path name \"1x\"} {TK VALUE WINDOW_PATH}" },
        .{ "button .Up", "1 {window name starts with an upper-case letter: \"Up\"} {TK VALUE WINDOW NOTCLASS}" },
        .{ "button .c1 -background nocolor", "1 {unknown color name \"nocolor\"} {TK LOOKUP COLOR nocolor}" },
        .{ "button .c2 -background #zz", "1 {invalid color name \"#zz\"} {TK VALUE COLOR}" },
        .{ "button .a1 -anchor middle", "1 {bad anchor \"middle\": must be n, ne, e, se, s, sw, w, nw, or center} {TCL LOOKUP INDEX anchor middle}" },
        .{ "button .a2 -anchor {}", "1 {ambiguous anchor \"\": must be n, ne, e, se, s, sw, w, nw, or center} {TCL LOOKUP INDEX anchor {}}" },
        .{ "button .b1 -borderwidth x", "1 {bad screen distance \"x\"} {TK VALUE PIXELS}" },
        .{ "button .h1 -height x", "1 {expected integer but got \"x\"} {TCL VALUE NUMBER}" },
        .{ "button .i1 -image noimage", "1 {image \"noimage\" doesn't exist} {TK LOOKUP IMAGE noimage}" },
        .{ ".b invoke x", "1 {wrong # args: should be \".b invoke\"} {TCL WRONGARGS}" },
        .{ ".b configure -text a -width", "1 {value for \"-width\" missing} {TK VALUE_MISSING}" },
        .{ ".b cget -foo", "1 {unknown option \"-foo\"} {TK LOOKUP OPTION -foo}" },
        .{ ".b cget", "1 {wrong # args: should be \".b cget option\"} {TCL WRONGARGS}" },
        .{ ".b", "1 {wrong # args: should be \".b option ?arg ...?\"} {TCL WRONGARGS}" },
        .{ ".b nope", "1 {bad option \"nope\": must be cget, configure, flash, or invoke} {TCL LOOKUP INDEX option nope}" },
        .{ ".b c", "1 {ambiguous option \"c\": must be cget, configure, flash, or invoke} {TCL LOOKUP INDEX option c}" },
        .{ "button .r1 -relief bumpy", "1 {bad relief \"bumpy\": must be flat, groove, raised, ridge, solid, or sunken} {TCL LOOKUP INDEX relief bumpy}" },
        .{ "button .j1 -justify up", "1 {bad justification \"up\": must be left, right, or center} {TCL LOOKUP INDEX justification up}" },
        .{ "button .s1 -state up", "1 {bad state \"up\": must be active, disabled, or normal} {TCL LOOKUP INDEX state up}" },
        .{ "button .d1 -default up", "1 {bad default \"up\": must be active, disabled, or normal} {TCL LOOKUP INDEX default up}" },
        .{ "button .p1 -compound up", "1 {bad compound \"up\": must be bottom, center, left, none, right, or top} {TCL LOOKUP INDEX compound up}" },
    };
    for (cases) |c| try t.expectEqualStrings(c[1], try codeOf(&h, c[0]));
}

test "button: the checks of -cursor, -bitmap, -overrelief, and -font" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    const cases = [_][2][]const u8{
        .{ "button .k1 -cursor nocursor", "1 {bad cursor spec \"nocursor\"} {TK VALUE CURSOR}" },
        .{ "button .k2 -cursor {nocursor red}", "1 {bad cursor spec \"nocursor red\"} {TK VALUE CURSOR}" },
        .{ "button .k3 -cursor {{} red}", "1 {bad cursor spec \"{} red\"} {TK VALUE CURSOR}" },
        .{ "button .m1 -bitmap nobitmap", "1 {bitmap \"nobitmap\" not defined} {TK LOOKUP BITMAP nobitmap}" },
        .{ "button .m2 -bitmap ERROR", "1 {bitmap \"ERROR\" not defined} {TK LOOKUP BITMAP ERROR}" },
        .{ "button .o1 -overrelief bumpy", "1 {bad relief \"bumpy\": must be flat, groove, raised, ridge, solid, or sunken} {TCL LOOKUP INDEX relief bumpy}" },
        .{ "button .f1 -font {nofont 999 weird}", "1 {unknown font style \"weird\"} {TK LOOKUP FONT_STYLE weird}" },
        .{ "button .f2 -font {}", "1 {font \"\" doesn't exist} {TK LOOKUP FONT {}}" },
        .{ "button .f3 -font {Courier New}", "1 {expected integer but got \"New\"} {TCL VALUE NUMBER}" },
        .{ "button .f4 -font {Arial {} bold}", "1 {expected integer but got \"\"} {TCL VALUE NUMBER}" },
        .{ "button .f5 -font {-family Arial -weight heavy}", "1 {bad -weight value \"heavy\": must be normal, or bold} {TK LOOKUP -weight heavy}" },
        .{ "button .f6 -font {-family Arial -slant up}", "1 {bad -slant value \"up\": must be roman, or italic} {TK LOOKUP -slant up}" },
        .{ "button .f7 -font {-fam Arial}", "1 {bad option \"-fam\": must be -family, -size, -weight, -slant, -underline, or -overstrike} {TCL LOOKUP INDEX option -fam}" },
        .{ "button .f8 -font {-size 12 -family}", "1 {value for \"-family\" option missing} {TK FONT NO_ATTRIBUTE}" },
        .{ "button .f9 -font {-family Arial -underline x}", "1 {expected boolean value but got \"x\"} {TCL VALUE NUMBER}" },
        .{ "button .f10 -font {Arial 12 {bold weird}}", "1 {unknown font style \"weird\"} {TK LOOKUP FONT_STYLE weird}" },
        .{ "button .f11 -font {\"Arial}", "1 {font \"\"Arial\" doesn't exist} {TK LOOKUP FONT {\"Arial}}" },
    };
    for (cases) |c| try t.expectEqualStrings(c[1], try codeOf(&h, c[0]));
    // The values that Tk 8.6.15 on Windows takes.
    _ = try h.eval(
        \\button .g1 -cursor watch; button .g2 -cursor {watch red blue}; button .g3 -cursor Watch
        \\button .g4 -cursor size_we; button .g5 -cursor {}; button .g6 -cursor @C:/x.cur
        \\button .g7 -bitmap error; button .g8 -bitmap {}; button .g9 -bitmap @x.xbm
        \\button .g10 -overrelief {}; button .g11 -overrelief sunken
        \\button .g12 -font {Arial -12}; button .g13 -font {Arial 12 {bold italic}}; button .g14 -font {{} 12}
        \\button .g15 -font {Arial 12 bold roman normal italic}; button .g16 -font {-*-helvetica-medium-r-normal--12-*}
        \\button .g17 -font {Arial 0x10}; button .g18 -font {Arial { 12 }}; button .g19 -font TkDefaultFont
        \\button .g20 -font {TkDefaultFont 12}; button .g21 -font nosuchnamedfont; button .g22 -font {-size -12 -weight bold}
    );
}

test "button: the pointer paths" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    const c = center(&h, ".b");
    h.head.click(h.win, c[0], c[1]);
    try h.update();
    try t.expectEqualStrings("1", try n(&h));
    try t.expectEqualStrings(".b", try h.eval("focus"));
    // A release outside does not invoke.
    h.head.pointerMove(h.win, c[0], c[1]);
    h.head.pointerButton(h.win, 1, true);
    h.head.pointerMove(h.win, 2, 2);
    h.head.pointerButton(h.win, 1, false);
    try h.update();
    try t.expectEqualStrings("1", try n(&h));
    // A move outside and back before the release does invoke.
    h.head.pointerMove(h.win, c[0], c[1]);
    h.head.pointerButton(h.win, 1, true);
    h.head.pointerMove(h.win, 2, 2);
    try h.update();
    h.head.pointerMove(h.win, c[0], c[1]);
    h.head.pointerButton(h.win, 1, false);
    try h.update();
    try t.expectEqualStrings("2", try n(&h));
    // A disabled button does nothing.
    _ = try h.eval(".b configure -state disabled");
    h.head.click(h.win, c[0], c[1]);
    try h.update();
    try t.expectEqualStrings("2", try n(&h));
}

test "button: the keyboard and the class bindings" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    _ = try h.eval("focus .b");
    try h.head.press(h.win, "space");
    try h.update();
    try t.expectEqualStrings("1", try n(&h));
    try t.expectEqualStrings("<<Invoke>> <Key-space> <ButtonRelease-1> <Button-1> <Leave> <Enter>", try h.eval("bind Button"));
    _ = try h.eval("event generate .b <<Invoke>>");
    try t.expectEqualStrings("2", try n(&h));
    _ = try h.eval("bind .b <1> break");
    const c = center(&h, ".b");
    h.head.click(h.win, c[0], c[1]);
    try h.update();
    try t.expectEqualStrings("2", try n(&h));
}

test "button: a command that deletes the button, and errors" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    _ = try h.eval("button .d -text X -command {destroy .d}; grid .d; update");
    const c = center(&h, ".d");
    h.head.click(h.win, c[0], c[1]);
    try h.update();
    try t.expectEqualStrings("0", try h.eval("winfo exists .d"));
    _ = try h.eval("set log {}; proc bgerror {m} {lappend ::log $m}; button .e -text E -command {error boom}; grid .e; update");
    const e = center(&h, ".e");
    h.head.click(h.win, e[0], e[1]);
    try h.update();
    try t.expectEqualStrings("boom", try h.eval("set log"));
    try t.expectEqualStrings("boom", try h.evalError(".e invoke"));
}

test "button: the state bits and the active colors" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    const b = h.app.find(".b").?;
    const c = center(&h, ".b");
    h.head.pointerMove(h.win, c[0], c[1]);
    h.head.pointerButton(h.win, 1, true);
    try h.update();
    try t.expect(b.state.pressed and b.state.hover);
    h.head.pointerMove(h.win, 2, 2);
    try h.update();
    try t.expect(!b.state.pressed and !b.state.hover);
    h.head.pointerButton(h.win, 1, false);
    try h.update();
    _ = try h.eval(".b configure -activebackground #ff0000");
    h.app.ensureStyle(b);
    var buf: [7]u8 = undefined;
    try t.expect(!std.mem.eql(u8, "#ff0000", b.style.background.formatTk(&buf)));
    h.head.pointerMove(h.win, c[0], c[1]);
    try h.update();
    h.app.ensureStyle(b);
    try t.expectEqualStrings("#ff0000", b.style.background.formatTk(&buf));
}

fn three(h: *Harness) !void {
    try h.init();
    _ = try h.eval("wm geometry . 260x80");
    _ = try h.eval("button .s -text Save; button .c -text Cancel; button .p -text OK; ztk::class .p add primary; grid .s .c .p -padx 8 -pady 20");
}

fn shot(h: *Harness, name: []const u8) !void {
    try h.update();
    try testing_h.expectGolden(name, h.head.image(h.win).?, .{});
    try testing_h.expectScene(name, h.app.lastScene());
}

test "button-normal" {
    var h: Harness = undefined;
    try three(&h);
    defer h.deinit();
    try shot(&h, "button-normal");
}

test "button-hover" {
    var h: Harness = undefined;
    try three(&h);
    defer h.deinit();
    try h.update();
    const c = center(&h, ".s");
    h.head.pointerMove(h.win, c[0], c[1]);
    try shot(&h, "button-hover");
}

test "button-pressed" {
    var h: Harness = undefined;
    try three(&h);
    defer h.deinit();
    try h.update();
    const c = center(&h, ".s");
    h.head.pointerMove(h.win, c[0], c[1]);
    h.head.pointerButton(h.win, 1, true);
    try shot(&h, "button-pressed");
}

test "button-focus" {
    var h: Harness = undefined;
    try three(&h);
    defer h.deinit();
    _ = try h.eval("focus .s");
    try shot(&h, "button-focus");
}

test "button-disabled" {
    var h: Harness = undefined;
    try three(&h);
    defer h.deinit();
    _ = try h.eval(".s configure -state disabled");
    try shot(&h, "button-disabled");
}
