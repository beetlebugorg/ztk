//! Tests of the `menu` widget: the entries, the indexes, `invoke` with
//! the variables, the messages of `wish` 8.6.16, and the native menus of
//! the headless backend.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Harness = @import("../testing.zig").Harness;
const t = std.testing;

const setup =
    \\menu .m
    \\.m add command -label Open -accelerator Ctrl+O -command {lappend ::log open; return open}
    \\.m add separator
    \\.m add checkbutton -label Bold
    \\.m add radiobutton -label A -value a -variable r
    \\.m add radiobutton -label B
    \\.m add cascade -label More -menu .m.c
    \\menu .m.c -tearoff 0
;

fn expectEval(h: *Harness, script: []const u8, want: []const u8) !void {
    const got = try h.eval(script);
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("script: {s}\n", .{script});
        try t.expectEqualStrings(want, got);
    }
}

fn expectError(h: *Harness, script: []const u8, want: []const u8) !void {
    const got = try h.evalError(script);
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("script: {s}\n", .{script});
        try t.expectEqualStrings(want, got);
    }
}

test "menu: the indexes give the values of wish" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval(setup);
    const cases = [_][2][]const u8{
        .{ ".m index end", "6" },        .{ ".m index last", "6" },  .{ ".m index active", "none" },
        .{ ".m index none", "none" },    .{ ".m index 0", "0" },     .{ ".m index Bold", "3" },
        .{ ".m index B*", "3" },         .{ ".m index 99", "6" },    .{ ".m index {}", "none" },
        .{ ".m index @1000000", "none" },
        .{ ".m type 0", "tearoff" },     .{ ".m type 1", "command" }, .{ ".m type end", "cascade" },
        .{ ".m type none", "" },         .{ ".m entrycget 99 -label", "More" },
        .{ ".m entrycget 3 -variable", "Bold" }, .{ ".m entrycget 5 -variable", "selectedButton" },
        .{ ".m entrycget 5 -value", "B" }, .{ ".m entrycget 4 -value", "a" },
        .{ ".m entryconfigure 1 -label", "-label {} {} {} Open" },
        .{ ".m entryconfigure 2", "{-background {} {} {} {}}" },
    };
    for (cases) |c| try expectEval(&h, c[0], c[1]);
}

test "menu: the messages of wish" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval(setup);
    const cases = [_][2][]const u8{
        .{ ".m bogus", "bad option \"bogus\": must be activate, add, cget, clone, configure, delete, entrycget, entryconfigure, index, insert, invoke, post, postcascade, type, unpost, xposition, or yposition" },
        .{ ".m add", "wrong # args: should be \".m add type ?-option value ...?\"" },
        .{ ".m add bogus", "bad menu entry type \"bogus\": must be cascade, checkbutton, command, radiobutton, or separator" },
        .{ ".m index bogus", "bad menu entry index \"bogus\"" },
        .{ ".m index -1", "bad menu entry index \"-1\"" },
        .{ ".m type", "wrong # args: should be \".m type index\"" },
        .{ ".m invoke", "wrong # args: should be \".m invoke index\"" },
        .{ ".m post", "wrong # args: should be \".m post x y ?index?\"" },
        .{ ".m post a b", "expected integer but got \"a\"" },
        .{ ".m delete", "wrong # args: should be \".m delete first ?last?\"" },
        .{ ".m insert", "wrong # args: should be \".m insert index type ?-option value ...?\"" },
        .{ ".m activate", "wrong # args: should be \".m activate index\"" },
        .{ ".m xposition", "wrong # args: should be \".m xposition index\"" },
        .{ ".m entryconfigure", "wrong # args: should be \".m entryconfigure index ?-option value ...?\"" },
        .{ ".m index", "wrong # args: should be \".m index string\"" },
        .{ ".m entryconfigure 1 -state bogus", "bad state \"bogus\": must be active, normal, or disabled" },
        .{ ".m entryconfigure 1 -underline x", "expected integer but got \"x\"" },
        .{ ".m entryconfigure 1 -columnbreak x", "expected boolean value but got \"x\"" },
        .{ ".m entryconfigure 1 -compound x", "bad compound \"x\": must be bottom, center, left, none, right, or top" },
        .{ ".m entryconfigure 1 -bogus 1", "unknown option \"-bogus\"" },
        .{ ".m entryconfigure 2 -label x", "unknown option \"-label\"" },
        .{ ".m entryconfigure 1 -image bogus", "image \"bogus\" doesn't exist" },
        .{ ".m configure -type bogus", "bad type \"bogus\": must be normal, tearoff, or menubar" },
        .{ ".m configure -tearoff x", "expected boolean value but got \"x\"" },
        .{ ".m add command -label X -bogus 1", "unknown option \"-bogus\"" },
    };
    for (cases) |c| try expectError(&h, c[0], c[1]);
    try expectEval(&h, ".m index end", "6");
    try expectError(&h, "tk_popup", "wrong # args: should be \"tk_popup menu x y ?entry?\"");
}

test "menu: invoke sets the variables and gives the result of the command" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval(setup);
    try expectEval(&h, ".m invoke 3; set Bold", "1");
    try expectEval(&h, ".m invoke 3; set Bold", "0");
    try expectEval(&h, ".m invoke 4; set r", "a");
    try expectEval(&h, ".m invoke 5; list $r $selectedButton", "a B");
    try expectEval(&h, ".m invoke 1", "open");
    try expectEval(&h, "set log", "open");
    try expectEval(&h, ".m add command -label D -command {error boom}; list [catch {.m invoke D} e] $e", "1 boom");
    try expectEval(&h, ".m entryconfigure 1 -state disabled; .m invoke 1; set log", "open");
    _ = try h.eval("menu .m3 -tearoff 0; .m3 add checkbutton -label C -variable cv -onvalue yes -offvalue no");
    try expectEval(&h, ".m3 invoke 0; set cv", "yes");
    try expectEval(&h, ".m3 invoke 0; set cv", "no");
}

test "menu: activate, insert, delete, and the tearoff entry" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval(setup);
    try expectEval(&h, ".m activate 1; list [.m index active] [.m entrycget active -state] [.m entrycget 3 -state]", "1 active normal");
    try expectEval(&h, ".m activate 2; .m index active", "none");
    try expectEval(&h, ".m activate 1; .m entryconfigure 1 -state normal; .m index active", "none");
    try expectEval(&h, ".m entryconfigure 1 -state disabled; .m activate 1; .m index active", "none");
    try expectEval(&h, ".m insert 1 command -label Ins; .m entrycget 1 -label", "Ins");
    try expectEval(&h, ".m delete 1; .m entrycget 1 -label", "Open");
    try expectEval(&h, ".m delete 99; .m delete none; .m delete 2 1; .m index end", "6");
    try expectEval(&h, ".m delete 0; .m type 0", "tearoff");
    try expectEval(&h, ".m configure -tearoff 0; list [.m type 0] [.m index end]", "command 5");
    try expectEval(&h, "menu .m3 -tearoff 0; .m3 index end", "none");
    try expectEval(&h, ".m3 add command; list [.m3 index end] [.m3 entrycget 0 -label]", "0 {}");
    try expectEval(&h, ".m clone .m2; list [.m2 index end] [winfo class .m2]", "5 Menu");
}

test "menu: <<MenuSelect>> goes to the bindings of the menu" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval(setup);
    try expectEval(&h, "set log {}; bind .m <<MenuSelect>> {lappend ::log sel[%W index active]}; .m activate 1; event generate .m <<MenuSelect>>; set log", "sel1");
}

test "menu: the native menus get the entries, the posts, and the events" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.head.native_menus = true;
    h.app.platform.native_menus = true;
    _ = try h.eval(setup);
    _ = try h.eval(".m.c add command -label Deep; set Bold 1; .m configure -postcommand {lappend ::log post}");
    try expectEval(&h, "set log {}; .m post 10 20 1; set log", "post");
    try t.expectEqualStrings(
        \\set 2 "More" [command Deep]
        \\set 1 [command Open Ctrl+O] [separator] [checkbutton Bold on] [radiobutton A] [radiobutton B] [cascade More ->2]
        \\post 0 1 10 20 0
        \\
    , h.head.menu_log.items);
    // The native index 2 is the Tk index 3: the check entry.
    h.head.menuEvent(h.win, 1, 2, .invoke);
    try h.update();
    try expectEval(&h, "set Bold", "0");
    _ = try h.eval("bind .m <<MenuSelect>> {lappend ::log sel[%W index active]}");
    h.head.menuAction(h.win, 1, 0, .select);
    try expectEval(&h, "set log", "post sel1");
    h.head.menu_log.clearRetainingCapacity();
    _ = try h.eval("tk_popup .m 5 6 Bold");
    try t.expect(std.mem.indexOf(u8, h.head.menu_log.items, "post 0 1 5 6 2") != null);
    h.head.menuEvent(h.win, 1, -1, .closed);
    try h.update();
    h.head.menu_log.clearRetainingCapacity();
    _ = try h.eval("menu .bar -tearoff 0; .bar add cascade -label Help -menu .bar.help; menu .bar.help -tearoff 0; toplevel .t -menu .bar");
    try t.expect(std.mem.indexOf(u8, h.head.menu_log.items, "\"Help\" role=help") != null);
    try t.expect(std.mem.indexOf(u8, h.head.menu_log.items, "bar 1 ") != null);
    h.head.menu_log.clearRetainingCapacity();
    _ = try h.eval(". configure -menu .bar");
    try t.expect(std.mem.indexOf(u8, h.head.menu_log.items, "bar 0 ") != null);
    try expectEval(&h, ". cget -menu", ".bar");
    _ = try h.eval("destroy .m");
    try t.expect(std.mem.indexOf(u8, h.head.menu_log.items, "drop 1") != null);
}

test "menu: a drawn menu posts, follows the pointer, and invokes on a release" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval(setup);
    _ = try h.eval("wm geometry . 400x300; .m.c add command -label Deep -command {lappend ::log deep}; set log {}; bind .m <<MenuSelect>> {lappend ::log sel[%W index active]}");
    try h.update();
    _ = try h.eval(".m post 20 30");
    try h.update();
    // Entry 1 (Open) is below the tearoff entry.
    const y1 = try h.eval(".m yposition 1");
    const y = 30 + try std.fmt.parseInt(i32, y1, 10) + 4;
    h.head.pointerMove(h.win, 40, @floatFromInt(y));
    try h.update();
    try expectEval(&h, "list [.m index active] $log", "1 sel1");
    h.head.pointerButton(h.win, 1, true);
    h.head.pointerButton(h.win, 1, false);
    try h.update();
    try expectEval(&h, "set log", "sel1 open");
    try t.expect(h.app.menu_root == null);
    try t.expect(h.app.grab.widget == null);
    // A press outside the menu unposts it.
    _ = try h.eval(".m post 20 30");
    h.head.click(h.win, 390, 290);
    try h.update();
    try t.expect(h.app.menu_root == null);
}

test "menu: the keys of a drawn menu move, open a cascade, and invoke" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval(setup);
    _ = try h.eval("wm geometry . 400x300; .m.c add command -label Deep -command {lappend ::log deep}; .m entryconfigure Bold -underline 0; set log {}");
    try h.update();
    _ = try h.eval(".m post 20 30");
    try h.update();
    try h.head.press(h.win, "Down");
    try h.update();
    try expectEval(&h, ".m index active", "1");
    try h.head.press(h.win, "Down");
    try h.update();
    // The separator is skipped.
    try expectEval(&h, ".m index active", "3");
    try h.head.press(h.win, "Up");
    try h.head.press(h.win, "Up");
    try h.update();
    // The wrap goes to the last entry, the cascade.
    try expectEval(&h, ".m index active", "6");
    try h.head.press(h.win, "Right");
    try h.update();
    try expectEval(&h, "list [.m.c index active] [winfo exists .m.c]", "0 1");
    try t.expect(h.app.menu_root != null);
    try h.head.press(h.win, "Left");
    try h.update();
    try expectEval(&h, ".m.c index active", "none");
    try h.head.press(h.win, "Right");
    try h.head.press(h.win, "Return");
    try h.update();
    try expectEval(&h, "set log", "deep");
    try t.expect(h.app.menu_root == null);
    _ = try h.eval(".m post 20 30");
    try h.head.press(h.win, "b");
    try h.update();
    try expectEval(&h, "set Bold", "1");
    _ = try h.eval(".m post 20 30");
    try h.head.press(h.win, "Escape");
    try h.update();
    try t.expect(h.app.menu_root == null);
}

test "menu: a drawn menu stays in the window and a cascade opens on its right" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval(setup);
    _ = try h.eval("wm geometry . 400x300; .m.c add command -label Deep");
    try h.update();
    _ = try h.eval(".m post 390 290");
    try h.update();
    const md = @import("../widgets/menudraw.zig");
    const m = h.app.find(".m").?;
    const r = md.rect(m);
    try t.expect(r.x + r.w <= 400 and r.y + r.h <= 300 and r.x >= 0 and r.y >= 0);
    _ = try h.eval(".m post 10 10; .m postcascade 6");
    const c = h.app.find(".m.c").?;
    const rc = md.rect(c);
    try t.expect(rc.x >= md.rect(m).x + md.rect(m).w - 4);
    _ = try h.eval(".m postcascade none");
    try t.expect(md.cascadeOf(m) == null);
    _ = try h.eval("destroy .m");
    try t.expect(h.app.menu_root == null);
}

test "menu: a drawn menu fades in" {
    var h: Harness = undefined;
    try h.initAnimated();
    defer h.deinit();
    _ = try h.eval(setup);
    _ = try h.eval("wm geometry . 400x300; update; .m post 20 30");
    try h.update();
    const md = @import("../widgets/menudraw.zig");
    const m = h.app.find(".m").?;
    h.head.advance(75);
    try h.update();
    const mid = md.openness(@import("../widgets/menu.zig").data(m), h.app.platform.nowUs());
    try t.expect(mid > 0.3 and mid < 0.99);
    h.head.advance(400);
    try h.update();
    try t.expectEqual(@as(f32, 1), md.openness(@import("../widgets/menu.zig").data(m), h.app.platform.nowUs()));
}

const bar_setup =
    \\wm geometry . 400x300
    \\menu .bar -tearoff 0
    \\. configure -menu .bar
    \\foreach {m l} {file File edit Edit help Help} {
    \\    .bar add cascade -label $l -menu .bar.$m -underline 0
    \\    menu .bar.$m -tearoff 0
    \\    .bar.$m add command -label ${l}1 -command [list lappend ::log ${l}1]
    \\}
    \\frame .f; pack .f -fill both -expand 1
    \\set log {}
;

test "menu: a drawn menu bar is a row above the content" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval(bar_setup);
    try h.update();
    const md = @import("../widgets/menudraw.zig");
    const bar = h.app.find(".bar").?;
    const bh = md.barHeight(bar);
    try t.expect(bh > 10);
    const f = h.app.find(".f").?;
    try t.expectEqual(bh, f.geom.y);
    try t.expectEqual(@as(i32, 300) - bh, f.geom.h);
    // A press on the second entry opens its cascade below it.
    h.head.pointerMove(h.win, @floatFromInt(md.barX(bar, 1) + 4), 5);
    h.head.pointerButton(h.win, 1, true);
    h.head.pointerButton(h.win, 1, false);
    try h.update();
    try t.expect(h.app.menu_root == bar);
    const edit = h.app.find(".bar.edit").?;
    try t.expect(md.cascadeOf(bar) == edit);
    try t.expectEqual(bh, md.rect(edit).y);
    // Motion to the first entry moves the open cascade.
    h.head.pointerMove(h.win, @floatFromInt(md.barX(bar, 0) + 4), 5);
    try h.update();
    try t.expect(md.cascadeOf(bar) == h.app.find(".bar.file").?);
    // A release on an entry of the cascade invokes it.
    const r = md.rect(h.app.find(".bar.file").?);
    h.head.pointerMove(h.win, @floatFromInt(r.x + 10), @floatFromInt(r.y + 10));
    h.head.pointerButton(h.win, 1, true);
    h.head.pointerButton(h.win, 1, false);
    try h.update();
    try expectEval(&h, "set log", "File1");
    try t.expect(h.app.menu_root == null);
}

test "menu: F10, Alt with a letter, and the arrows move on the menu bar" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval(bar_setup);
    try h.update();
    const md = @import("../widgets/menudraw.zig");
    const bar = h.app.find(".bar").?;
    _ = try h.eval("focus .f; event generate . <Key-F10>");
    try t.expect(md.cascadeOf(bar) == h.app.find(".bar.file").?);
    try h.head.press(h.win, "Right");
    try h.update();
    try t.expect(md.cascadeOf(bar) == h.app.find(".bar.edit").?);
    try h.head.press(h.win, "Left");
    try h.head.press(h.win, "Left");
    try h.update();
    // The wrap goes to the last entry.
    try t.expect(md.cascadeOf(bar) == h.app.find(".bar.help").?);
    try h.head.press(h.win, "Return");
    try h.update();
    try expectEval(&h, "set log", "Help1");
    try t.expect(h.app.menu_root == null);
    _ = try h.eval("event generate . <Alt-KeyPress-e>");
    try t.expect(md.cascadeOf(bar) == h.app.find(".bar.edit").?);
    try h.head.press(h.win, "Escape");
    try h.update();
    try t.expect(h.app.menu_root == null);
    try t.expect(h.app.grab.widget == null);
}
