//! Tests of `ttk::style` and the simple `ttk` widgets: the options and
//! the messages of each widget, `state` and `instate`, `style configure`
//! and `map` with `lookup`, the layouts and the elements, `theme use
//! classic` and back, and a state change through a transition of the
//! theme. The expected texts are from `wish` 8.6.16.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Harness = @import("../testing.zig").Harness;
const t = std.testing;

fn expectAll(h: *Harness, cases: []const [2][]const u8) !void {
    for (cases) |c| t.expectEqualStrings(c[1], try h.eval(c[0])) catch |e| {
        std.debug.print("script: {s}\n", .{c[0]});
        return e;
    };
}

fn expectErrors(h: *Harness, cases: []const [2][]const u8) !void {
    for (cases) |c| t.expectEqualStrings(c[1], try h.evalError(c[0])) catch |e| {
        std.debug.print("script: {s}\n", .{c[0]});
        return e;
    };
}

test "ttk: the options and the subcommands of each widget" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try expectAll(&h, &.{
        .{ "ttk::button .b; .b configure", "{-command command Command {} {}} {-default default Default normal normal} {-takefocus takeFocus TakeFocus ttk::takefocus ttk::takefocus} {-text text Text {} {}} {-textvariable textVariable Variable {} {}} {-underline underline Underline -1 -1} {-width width Width {} {}} {-image image Image {} {}} {-compound compound Compound {} {}} {-padding padding Pad {} {}} {-state state State normal normal} {-cursor cursor Cursor {} {}} {-style style Style {} {}} {-class {} {} {} {}}" },
        .{ "winfo class .b", "TButton" },
        .{ "ttk::checkbutton .c; .c configure -variable", "-variable variable Variable {} .c" },
        .{ "ttk::radiobutton .r; .r configure -variable", "-variable variable Variable ::selectedButton ::selectedButton" },
        .{ ".r configure -value", "-value Value Value 1 1" },
        .{ "ttk::label .l; .l configure -anchor", "-anchor anchor Anchor w w" },
        .{ ".l configure -background", "-background frameColor FrameColor {} {}" },
        .{ "ttk::frame .f; .f configure", "{-borderwidth borderWidth BorderWidth {} {}} {-padding padding Pad {} {}} {-relief relief Relief {} {}} {-width width Width 0 0} {-height height Height 0 0} {-takefocus takeFocus TakeFocus {} {}} {-cursor cursor Cursor {} {}} {-style style Style {} {}} {-class {} {} {} {}}" },
        .{ "ttk::labelframe .lf; .lf configure -labelanchor", "-labelanchor labelAnchor LabelAnchor nw nw" },
        .{ "ttk::entry .e; .e configure -cursor", "-cursor cursor Cursor {} xterm" },
        .{ ".e configure -background", "-background windowColor WindowColor {} {}" },
        .{ "ttk::separator .s; .s configure", "{-orient orient Orient horizontal horizontal} {-takefocus takeFocus TakeFocus {} {}} {-cursor cursor Cursor {} {}} {-style style Style {} {}} {-class {} {} {} {}}" },
        .{ "ttk::sizegrip .g; .g configure -cursor", "-cursor cursor Cursor {} bottom_right_corner" },
        .{ "ttk::frame .f2 -class Foo; list [winfo class .f2] [.f2 cget -class]", "Foo Foo" },
        .{ "ttk::checkbutton .c2 -variable nv; list [.c2 state] [info exists nv]", "alternate 0" },
        .{ ".c invoke; list [set .c] [.c state]", "1 selected" },
        .{ "ttk::radiobutton .r1 -variable v -value a; ttk::radiobutton .r2 -variable v -value b; .r2 invoke; list $v [.r1 state] [.r2 state]", "b {} selected" },
        .{ "ttk::entry .e2 -state readonly; .e2 insert end x; .e2 get", "" },
        .{ ".e2 configure -state normal; .e2 insert end x; .e2 get", "x" },
        .{ "info body ttk::takefocus", "expr {[$w instate !disabled] && [winfo viewable $w]}" },
    });
    try expectErrors(&h, &.{
        .{ ".b bogus", "bad command \"bogus\": must be configure, cget, invoke, instate, state, or identify" },
        .{ ".l bogus", "bad command \"bogus\": must be configure, cget, instate, state, or identify" },
        .{ ".s bogus", "bad command \"bogus\": must be configure, cget, identify, instate, or state" },
        .{ ".e bogus", "bad command \"bogus\": must be bbox, cget, configure, delete, get, icursor, identify, index, insert, instate, selection, state, validate, or xview" },
        .{ ".f configure -class Bar", "attempt to change read-only option" },
        .{ ".f configure -bogus 1", "unknown option \"-bogus\"" },
        .{ ".b configure -compound bogus", "bad compound \"bogus\": must be none, text, image, center, top, bottom, left, or right" },
        .{ ".b configure -image nope", "image \"nope\" doesn't exist" },
        .{ ".b configure -default bogus", "bad default \"bogus\": must be normal, active, or disabled" },
        .{ ".b configure -underline x", "expected integer but got \"x\"" },
        .{ ".s configure -orient bogus", "bad orient \"bogus\": must be horizontal or vertical" },
        .{ ".l configure -anchor bogus", "bad anchor \"bogus\": must be n, ne, e, se, s, sw, w, nw, or center" },
        .{ ".l configure -background bogus", "unknown color name \"bogus\"" },
        .{ ".b identify", "wrong # args: should be \".b identify ?what? x y\"" },
        .{ ".b configure -highlightthickness 1", "unknown option \"-highlightthickness\"" },
    });
}

test "ttk: state and instate" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try expectAll(&h, &.{
        .{ "ttk::button .b -text Hello; pack .b; update; .b state", "" },
        .{ ".b state {disabled pressed}", "!disabled !pressed" },
        .{ ".b state", "disabled pressed" },
        .{ "list [.b instate disabled] [.b instate !disabled]", "1 0" },
        .{ ".b state !disabled", "disabled" },
        .{ ".b instate !disabled {set x 5}", "5" },
        .{ ".b state {user1 alternate}", "!alternate !user1" },
        .{ ".b state", "pressed alternate user1" },
        .{ ".b state {!pressed !alternate !user1}; .b configure -state disabled; .b state", "disabled" },
        .{ ".b configure -state normal; .b state", "" },
        .{ ".b state disabled; .b cget -state", "normal" },
        .{ ".b identify 200 200", "" },
        .{ "ttk::entry .e; .e state readonly; .e insert end abc; .e get", "" },
    });
    try expectErrors(&h, &.{
        .{ ".b state bogus", "Invalid state name bogus" },
        .{ ".b instate", "wrong # args: should be \".b instate state-spec ?script?\"" },
    });
    // A state that `state` sets changes the style through the selector `:state()`.
    _ = try h.eval("ztk::style add {TButton:state(user2) { background-color: #ff0000 }}; .b state {!disabled user2}; update");
    const w = h.app.find(".b").?;
    try t.expectEqual(@as(u8, 255), w.style.background.r);
    try t.expectEqual(@as(u8, 0), w.style.background.g);
}

test "ttk: style configure, map, lookup, layout, and element" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try expectAll(&h, &.{
        .{ "ttk::style theme names", "clam alt default classic" },
        .{ "ttk::style theme use", "default" },
        .{ "list [ttk::style lookup TButton -foreground] [ttk::style lookup TButton -padding] [ttk::style lookup . -background] [ttk::style lookup TButton -foo {} dflt]", "{#000000} {3 3} #d9d9d9 dflt" },
        .{ "ttk::style lookup TButton -foreground disabled", "#a3a3a3" },
        .{ "ttk::style configure Accent.TButton -foreground red; list [ttk::style configure Accent.TButton] [ttk::style configure Accent.TButton -foreground] [ttk::style lookup Accent.TButton -foreground]", "{-foreground red} red red" },
        .{ "ttk::style map Accent.TButton -foreground {active blue disabled gray}; list [ttk::style map Accent.TButton] [ttk::style lookup Accent.TButton -foreground active]", "{-foreground {active blue disabled gray}} blue" },
        .{ "ttk::style map TButton", "-relief {{!disabled pressed} sunken}" },
        .{ "ttk::style configure TButton", "-relief raised -padding {3 3} -anchor center -width -9 -shiftrelief 1" },
        .{ "ttk::style layout TButton", "Button.border -sticky nswe -border 1 -children {Button.focus -sticky nswe -children {Button.padding -sticky nswe -children {Button.label -sticky nswe}}}" },
        .{ "ttk::style layout Accent.TButton", "Button.border -sticky nswe -border 1 -children {Button.focus -sticky nswe -children {Button.padding -sticky nswe -children {Button.label -sticky nswe}}}" },
        .{ "ttk::style layout My.TLabel {Label.label -sticky nswe}; ttk::style layout My.TLabel", "Label.label -sticky nswe" },
        .{ "ttk::style element options Button.border", "-background -borderwidth -relief" },
        .{ "ttk::style element options nope", "" },
        .{ "ttk::style element create My.thing from default; lindex [ttk::style element names] end", "My.thing" },
        .{ "ttk::style theme create t2 -parent classic -settings {ttk::style configure TLabel -foreground blue}; ttk::style theme settings t2 {set r [ttk::style configure TLabel -foreground]}; set r", "blue" },
    });
    try expectErrors(&h, &.{
        .{ "ttk::style bogus", "bad command \"bogus\": must be configure, map, lookup, layout, theme, or element" },
        .{ "ttk::style theme bogus", "bad command \"bogus\": must be create, names, settings, or use" },
        .{ "ttk::style theme use nosuch", "theme \"nosuch\" doesn't exist" },
        .{ "ttk::style configure", "wrong # args: should be \"ttk::style configure style ?-option ?value...??\"" },
        .{ "ttk::style configure TButton -foreground red -bg", "wrong # args: should be \"ttk::style configure style ?-option ?value...??\"" },
        .{ "ttk::style map", "wrong # args: should be \"ttk::style map style ?-option ?value...??\"" },
        .{ "ttk::style map TButton -foreground {active}", "State map must have an even number of elements" },
        .{ "ttk::style map TButton -foreground {bogus red}", "Invalid state name bogus" },
        .{ "ttk::style lookup", "wrong # args: should be \"ttk::style lookup style -option ?state? ?default?\"" },
        .{ "ttk::style layout", "wrong # args: should be \"ttk::style layout name ?spec?\"" },
        .{ "ttk::style layout Nope", "Layout Nope not found" },
        .{ "ttk::style element bogus", "bad command \"bogus\": must be create, names, or options" },
        .{ "ttk::style theme create default", "Theme default already exists" },
        .{ "ttk::style theme create t3 -parent nope", "theme \"nope\" doesn't exist" },
        .{ "ttk::style theme settings nope {}", "theme \"nope\" doesn't exist" },
    });
    // `configure` and `map` give rules: the type is the last part of the style and the rest are classes.
    _ = try h.eval("ttk::button .a -style Accent.TButton -text A; ttk::button .b -text B; pack .a .b; update");
    const a = h.app.find(".a").?;
    const b = h.app.find(".b").?;
    try t.expectEqual(@as(u8, 255), a.style.color.r);
    try t.expect(b.style.color.r != 255 or b.style.color.g != 0);
    _ = try h.eval(".a state disabled; update");
    try t.expect(a.style.color.r == a.style.color.b and a.style.color.r < 255);
    _ = try h.eval("ttk::style configure TButton -padding {1 2 3 4}; update");
    try t.expectEqual(@as(i32, 1), b.style.padding.left);
    try t.expectEqual(@as(i32, 2), b.style.padding.top);
    try t.expectEqual(@as(i32, 4), b.style.padding.bottom);
    // The switch style of a checkbutton.
    _ = try h.eval("ttk::checkbutton .sw -style Switch.TCheckbutton; pack .sw; update");
    try t.expect(h.app.find(".sw").?.hasClass("switch"));
}

test "ttk: theme use classic and back" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("ttk::button .b -text B; button .k -text K; ttk::entry .e; pack .b .k .e; update");
    const k = h.app.find(".k").?;
    const modern_bg = k.style.background;
    try t.expectEqualStrings("modern", try h.eval("ztk::style theme"));
    _ = try h.eval("ttk::style theme use classic; update");
    try t.expectEqualStrings("classic", try h.eval("ztk::style theme"));
    try t.expectEqualStrings("classic", try h.eval("ttk::style theme use"));
    try t.expectEqual(@as(u8, 0xd9), k.style.background.r);
    try t.expectEqual(@import("../style.zig").Relief.raised, k.style.relief);
    try t.expectEqual(@import("../style.zig").Relief.sunken, h.app.find(".e").?.style.relief);
    try t.expectEqualStrings("Button.highlight -sticky nswe -children {Button.border -sticky nswe -border 1 -children {Button.padding -sticky nswe -children {Button.label -sticky nswe}}}", try h.eval("ttk::style layout TButton"));
    try t.expectEqualStrings("-highlightcolor {focus black} -foreground {disabled #a3a3a3} -background {disabled #d9d9d9 active #ececec}", try h.eval("ttk::style map ."));
    _ = try h.eval("ztk::style theme modern; update");
    try t.expectEqualStrings("default", try h.eval("ttk::style theme use"));
    try t.expect(std.meta.eql(modern_bg, k.style.background));
    try t.expectEqualStrings("bad theme \"x\": must be classic or modern", try h.evalError("ztk::style theme x"));
}

test "ttk: a hover moves through the transition of the theme" {
    var h: Harness = undefined;
    try h.initAnimated();
    defer h.deinit();
    _ = try h.eval("ztk::style add {TButton { background-color: #ffffff; border: 0; transition: background-color 120ms linear } TButton:hover { background-color: #000000 }}");
    _ = try h.eval("ttk::button .b -text OK; grid .b -padx 20 -pady 20; update");
    const b = h.app.find(".b").?;
    const anim = @import("../anim.zig");
    const rest = anim.shown(h.app, b).background;
    h.head.pointerMove(h.win, @floatFromInt(b.geom.x + 5), @floatFromInt(b.geom.y + 5));
    try h.update();
    try t.expectEqualStrings("active hover", try h.eval(".b state"));
    h.head.advance(60);
    try h.update();
    const mid = anim.shown(h.app, b).background;
    try t.expect(mid.r > 0x60 and mid.r < 0xa0);
    // A replace during the move: the pointer leaves, and the color goes back from the shown value.
    h.head.pointerMove(h.win, 1, 1);
    try h.update();
    h.head.advance(10);
    try h.update();
    const back = anim.shown(h.app, b).background;
    try t.expect(back.r >= mid.r and back.r < 0xff);
    h.head.advance(500);
    try h.update();
    try t.expect(std.meta.eql(rest, anim.shown(h.app, b).background));
}

test "ttk: an image with -compound, and a separator and a size grip" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("image create photo dot -width 20 -height 10; dot put #ff0000 -to 0 0 20 10");
    _ = try h.eval("ttk::label .l -image dot -padding 0; ttk::label .t -text Hello -image dot -compound left -padding 0; ttk::label .x -text Hello -padding 0; pack .l .t .x; update");
    try t.expectEqualStrings("20 10", try h.eval("list [winfo reqwidth .l] [winfo reqheight .l]"));
    const tw = try std.fmt.parseInt(i32, try h.eval("winfo reqwidth .t"), 10);
    const xw = try std.fmt.parseInt(i32, try h.eval("winfo reqwidth .x"), 10);
    try t.expectEqual(xw + 24, tw);
    _ = try h.eval("ttk::separator .s; pack .s -fill x; update");
    try t.expectEqualStrings("1", try h.eval("winfo reqheight .s"));
    _ = try h.eval("ttk::sizegrip .g; pack .g -side right; update");
    try t.expectEqualStrings("16", try h.eval("winfo reqwidth .g"));
}
