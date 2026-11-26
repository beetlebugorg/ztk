//! Tests of `panedwindow` and `ttk::panedwindow`: the options, the
//! subcommands and their messages, the layout with the stretch and the
//! weights, the sash moves with the minimum sizes, a sash drag with the
//! pointer, the proxy, the pointer shape, the fade of the hot sash, and
//! the drag on the render thread. The expected texts and numbers are from
//! `wish` 8.6.16.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Harness = @import("../testing.zig").Harness;
const host = @import("../sys/host.zig");
const scene = @import("../scene.zig");
const paned = @import("../widgets/paned.zig");
const t = std.testing;

fn expectCases(h: *Harness, cases: []const [2][]const u8) !void {
    for (cases) |c| t.expectEqualStrings(c[1], try h.evalError(c[0])) catch |e| {
        std.debug.print("case: {s}\n", .{c[0]});
        return e;
    };
}

fn expectEvals(h: *Harness, cases: []const [2][]const u8) !void {
    for (cases) |c| t.expectEqualStrings(c[1], try h.eval(c[0])) catch |e| {
        std.debug.print("case: {s}\n", .{c[0]});
        return e;
    };
}

test "paned: the options and the messages of panedwindow" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("panedwindow .p; frame .p.a; frame .p.b -width 50 -height 40; .p add .p.a .p.b");
    try expectEvals(&h, &.{
        .{ ".p configure -sashwidth", "-sashwidth sashWidth Width 3 3" },
        .{ ".p configure -orient", "-orient orient Orient horizontal horizontal" },
        .{ ".p configure -height", "-height height Height {} {}" },
        .{ ".p paneconfigure .p.a -sticky", "-sticky {} {} nsew nesw" },
        .{ ".p paneconfigure .p.a -stretch", "-stretch stretch Stretch last last" },
        .{ ".p paneconfigure .p.a -after", "-after {} {} {} {}" },
        .{ "llength [.p paneconfigure .p.a]", "10" },
        .{ ".p panecget .p.b -minsize", "0" },
        .{ ".p panes", ".p.a .p.b" },
        .{ "winfo manager .p.a", "panedwindow" },
        .{ "bindtags .p", ".p Panedwindow . all" },
    });
    try expectCases(&h, &.{
        .{ ".p bogus", "bad command \"bogus\": must be add, cget, configure, forget, identify, panecget, paneconfigure, panes, proxy, or sash" },
        .{ ".p add", "wrong # args: should be \".p add widget ?widget ...?\"" },
        .{ ".p sash", "wrong # args: should be \".p sash option ?arg ...?\"" },
        .{ ".p sash bogus", "bad option \"bogus\": must be coord, dragto, mark, or place" },
        .{ ".p sash coord", "wrong # args: should be \".p sash coord index\"" },
        .{ ".p sash coord 5", "invalid sash index" },
        .{ ".p proxy", "wrong # args: should be \".p proxy option ?arg ...?\"" },
        .{ ".p proxy bogus", "bad option \"bogus\": must be coord, forget, or place" },
        .{ ".p identify", "wrong # args: should be \".p identify x y\"" },
        .{ ".p panecget .p.a", "wrong # args: should be \".p panecget pane option\"" },
        .{ ".p panecget .p.a -bogus", "not managed by this window" },
        .{ ".p paneconfigure .x", "bad window path name \".x\"" },
        .{ ".p paneconfigure .p.a -bogus 1", "unknown option \"-bogus\"" },
        .{ ".p forget .x", "bad window path name \".x\"" },
        .{ ".p add .p", "can't add .p to itself" },
        .{ ".p add .p.a -minsize x", "bad screen distance \"x\"" },
        .{ ".p add .", "can't add toplevel . to .p" },
        .{ ".p configure -orient bogus", "bad orient \"bogus\": must be horizontal or vertical" },
        .{ ".p add .p.a -sticky xyz", "bad stickyness value \"xyz\": must be a string containing zero or more of n, e, s, and w" },
        .{ ".p add .p.a -stretch x", "bad stretch \"x\": must be always, first, last, middle, or never" },
    });
}

test "paned: the sashes, the handles, the order, and the moves of panedwindow" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval(
        \\panedwindow .p -showhandle 1
        \\foreach n {a b c} {frame .p.$n -width 40 -height 30}
        \\.p add .p.a .p.b .p.c -minsize 10
        \\.p add .p.a -padx 4
        \\.p paneconfigure .p.c -after .p.a
    );
    try t.expectEqualStrings(".p.a .p.c .p.b", try h.eval(".p panes"));
    _ = try h.eval(".p add .p.b -before .p.a; update");
    try expectEvals(&h, &.{
        .{ ".p panes", ".p.b .p.a .p.c" },
        .{ "list [winfo reqwidth .p] [winfo reqheight .p]", "146 32" },
        .{ ".p sash coord 0", "43 1" },
        .{ ".p sash coord 1", "99 1" },
        .{ ".p identify 48 20", "0 sash" },
        .{ ".p identify 20 20", "" },
        .{ ".p identify 41 12", "0 handle" },
    });
    _ = try h.eval(".p paneconfigure .p.c -hide 1; pack .p; wm geometry . 400x100; update");
    try expectEvals(&h, &.{
        .{ "winfo ismapped .p.c", "0" },
        .{ "list [winfo width .p] [winfo x .p.a] [winfo width .p.a] [winfo x .p.b] [winfo width .p.b] [winfo height .p.b]", "98 53 40 1 40 30" },
    });
    _ = try h.eval(".p sash mark 0 10 10; .p sash dragto 0 30 10; update");
    try t.expectEqualStrings("63 1 60 73 20", try h.eval("concat [.p sash coord 0] [winfo width .p.b] [winfo x .p.a] [winfo width .p.a]"));
    _ = try h.eval(".p sash place 0 0 0; update");
    try t.expectEqualStrings("13 1 10", try h.eval("concat [.p sash coord 0] [winfo width .p.b]"));
    _ = try h.eval(".p sash place 0 1000 0; update");
    try t.expectEqualStrings("73 1 10", try h.eval("concat [.p sash coord 0] [winfo width .p.a]"));
    _ = try h.eval(".p forget .p.a; update");
    try t.expectEqualStrings(".p.b .p.c 0 {}", try h.eval("list {*}[.p panes] [winfo ismapped .p.a] [winfo manager .p.a]"));
    // The proxy stays on the line of the sashes.
    _ = try h.eval(".p proxy place 40 5");
    try t.expectEqualStrings("40 1", try h.eval(".p proxy coord"));
}

test "paned: the stretch of panedwindow and the weights of ttk::panedwindow" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval(
        \\panedwindow .p -bd 0 -sashwidth 4
        \\frame .p.a -width 20 -height 10; frame .p.b -width 60 -height 10; frame .p.c -width 30 -height 10
        \\.p add .p.a .p.b .p.c -stretch always
        \\place .p -x 0 -y 0 -width 200 -height 50; update
        \\proc widths {p} {lmap c [$p panes] {winfo width $c}}
    );
    try t.expectEqualStrings("34 105 53", try h.eval("widths .p"));
    _ = try h.eval("place .p -width 100; update");
    try t.expectEqualStrings("17 50 25 75", try h.eval("concat [widths .p] [winfo x .p.c]"));
    _ = try h.eval("foreach c [.p panes] {.p paneconfigure $c -stretch never}; place .p -width 200; update");
    try t.expectEqualStrings("20 60 30", try h.eval("widths .p"));
    _ = try h.eval(
        \\ttk::panedwindow .t -orient horizontal
        \\ttk::frame .t.a -width 20 -height 10; ttk::frame .t.b -width 60; ttk::frame .t.c -width 30
        \\.t add .t.a -weight 1; .t add .t.b -weight 3; .t add .t.c
        \\place .t -x 0 -y 60 -width 200 -height 50; update
    );
    try t.expectEqualStrings("40 120 30 40 165", try h.eval("concat [widths .t] [.t sashpos 0] [.t sashpos 1]"));
    _ = try h.eval("place .t -width 150; update");
    try t.expectEqualStrings("28 82 30 28 115", try h.eval("concat [widths .t] [.t sashpos 0] [.t sashpos 1]"));
    // A sash keeps room for the sashes after it, and pushes its neighbors.
    try t.expectEqualStrings("140 0 5", try h.eval("list [.t sashpos 0 500] [.t sashpos 0 -5] [.t sashpos 1 0]"));
    _ = try h.eval("update");
    try t.expectEqualStrings("0 0 1 140", try h.eval("list [winfo ismapped .t.a] [winfo ismapped .t.b] [winfo ismapped .t.c] [winfo width .t.c]"));
}

test "paned: the subcommands and the messages of ttk::panedwindow" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("ttk::panedwindow .p; ttk::frame .p.a -width 80 -height 50; ttk::frame .p.b -width 60 -height 50; ttk::frame .p.c; .p add .p.a; .p add .p.b -weight 1");
    try expectEvals(&h, &.{
        .{ ".p configure -orient", "-orient orient Orient vertical vertical" },
        .{ ".p pane .p.a", "-weight 0" },
        .{ ".p pane .p.b -weight", "1" },
        .{ ".p identify 1 1", "0" },
        .{ "update; list [winfo reqwidth .p] [winfo reqheight .p]", "80 105" },
        .{ "bindtags .p", ".p TPanedwindow . all" },
        .{ "winfo class .p", "TPanedwindow" },
    });
    try expectCases(&h, &.{
        .{ ".p bogus", "bad command \"bogus\": must be add, configure, cget, forget, identify, insert, instate, pane, panes, sashpos, or state" },
        .{ ".p add", "wrong # args: should be \".p add window\"" },
        .{ ".p add .p.c -weight x", "expected integer but got \"x\"" },
        .{ ".p add .p.c -bogus 1", "unknown option \"-bogus\"" },
        .{ ".p insert", "wrong # args: should be \".p insert index slave ?-option value ...?\"" },
        .{ ".p insert 9 .p.c", "Slave index 9 out of bounds" },
        .{ ".p insert x .p.c", "Invalid slave specification x" },
        .{ ".p pane", "wrong # args: should be \".p pane pane ?-option value ...?\"" },
        .{ ".p pane 7", "Slave index 7 out of bounds" },
        .{ ".p pane .p.a -bogus", "unknown option \"-bogus\"" },
        .{ ".p sashpos", "wrong # args: should be \".p sashpos index ?newpos?\"" },
        .{ ".p sashpos 5", "sash index 5 out of range" },
        .{ ".p sashpos x", "expected integer but got \"x\"" },
        .{ ".p forget", "wrong # args: should be \".p forget pane\"" },
        .{ ".p forget 9", "Slave index 9 out of bounds" },
        .{ ".p forget .p.c", ".p.c is not managed by .p" },
        .{ ".p add .p.a", ".p.a already added" },
        .{ ".p identify", "wrong # args: should be \".p identify ?what? x y\"" },
        .{ ".p identify bogus 1 1", "bad option \"bogus\": must be element or sash" },
        .{ ".p panes x", "wrong # args: should be \".p panes \"" },
        .{ ".p add .", "can't add . as slave of .p" },
    });
    _ = try h.eval(".p insert 0 .p.b");
    try t.expectEqualStrings(".p.b .p.a", try h.eval(".p panes"));
    _ = try h.eval(".p insert end .p.c; .p forget 0");
    try t.expectEqualStrings(".p.a .p.c", try h.eval(".p panes"));
}

/// The point of the middle of sash 0 of `.p` in the window.
fn sashPoint(h: *Harness) ![2]f32 {
    const p = h.app.find(".p").?;
    const r = try h.eval(".p sash coord 0");
    var it = std.mem.splitScalar(u8, r, ' ');
    const x = try std.fmt.parseFloat(f32, it.next().?);
    return .{ x + 1 + @as(f32, @floatFromInt(p.geom.x)), 20 + @as(f32, @floatFromInt(p.geom.y)) };
}

test "paned: a drag of a sash with the pointer, the proxy, and the pointer shape" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("panedwindow .p; frame .p.a -width 100 -height 80; frame .p.b -width 100 -height 80; .p add .p.a .p.b; pack .p; update");
    const s = try sashPoint(&h);
    h.head.pointerMove(h.win, s[0], s[1]);
    try h.update();
    try t.expectEqual(@import("../platform/platform.zig").Cursor.ew_resize, h.head.cursor.?);
    h.head.pointerButton(h.win, 1, true);
    try h.update();
    h.head.pointerMove(h.win, s[0] + 30, s[1]);
    try h.update();
    try t.expectEqualStrings("131 1 130", try h.eval("concat [.p sash coord 0] [winfo width .p.a]"));
    h.head.pointerButton(h.win, 1, false);
    try h.update();
    // With -opaqueresize 0 the proxy follows the pointer, and the release moves the sash.
    _ = try h.eval(".p configure -opaqueresize 0");
    const s2 = try sashPoint(&h);
    h.head.pointerMove(h.win, s2[0], s2[1]);
    h.head.pointerButton(h.win, 1, true);
    try h.update();
    h.head.pointerMove(h.win, s2[0] - 50, s2[1]);
    try h.update();
    try t.expectEqualStrings("131 1 81 1", try h.eval("concat [.p sash coord 0] [.p proxy coord]"));
    h.head.pointerButton(h.win, 1, false);
    try h.update();
    try t.expectEqualStrings("81 1 80", try h.eval("concat [.p sash coord 0] [winfo width .p.a]"));
    // Away from the sash the pointer has the default shape.
    h.head.pointerMove(h.win, s2[0] - 70, s2[1]);
    try h.update();
    try t.expectEqual(@import("../platform/platform.zig").Cursor.default, h.head.cursor.?);
}

test "paned: the hot sash fades in, and a leave fades it out from the shown value" {
    var h: Harness = undefined;
    try h.initAnimated();
    defer h.deinit();
    _ = try h.eval("panedwindow .p; frame .p.a -width 100 -height 80; frame .p.b -width 100 -height 80; .p add .p.a .p.b; pack .p; update");
    const p = h.app.find(".p").?;
    const s = try sashPoint(&h);
    h.head.pointerMove(h.win, s[0], s[1]);
    try h.update();
    try t.expectApproxEqAbs(@as(f32, 0), paned.fadeOf(p), 0.01);
    // The middle of the fade, at a fixed time.
    h.head.advance(60);
    try h.update();
    const mid = paned.fadeOf(p);
    try t.expect(mid > 0.3 and mid < 1);
    // A leave in the middle starts from the shown value.
    h.head.pointerMove(h.win, s[0] - 60, s[1]);
    try h.update();
    try t.expectApproxEqAbs(mid, paned.fadeOf(p), 0.01);
    h.head.advance(200);
    try h.update();
    try t.expectApproxEqAbs(@as(f32, 0), paned.fadeOf(p), 0.01);
    // The end state of a fade in.
    h.head.pointerMove(h.win, s[0], s[1]);
    try h.update();
    h.head.advance(200);
    try h.update();
    try t.expectApproxEqAbs(@as(f32, 1), paned.fadeOf(p), 0.01);
}

const limit_us: i64 = 2_000_000;

/// The first quad of the drag of the last frame. The read waits until no draw runs.
fn dragQuad(h: *Harness) ?scene.Quad {
    const r = h.app.render;
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    while (r.held_drawing or r.drawing != null) r.cond.waitUncancelable(r.io, &r.mutex);
    const f = r.last orelse return null;
    if (f.drags.items.len < 1) return null;
    return f.scene.quads.items[f.drags.items[0].first];
}

test "paned: the render thread moves a sash with the pointer while the script is busy" {
    var h: Harness = undefined;
    h.render_mode = .threaded;
    h.animations = true;
    h.dark = false;
    try h.initWith(null);
    defer h.deinit();
    _ = try h.eval("panedwindow .p; frame .p.a -width 100 -height 80; frame .p.b -width 100 -height 80; .p add .p.a .p.b; pack .p; update");
    const s = try sashPoint(&h);
    h.head.pointerMove(h.win, s[0], s[1]);
    h.head.pointerButton(h.win, 1, true);
    try h.update();
    const start = (dragQuad(&h) orelse return error.NoDrag).rect[0];
    // The pointer moves 40 pixels and the UI thread handles no event.
    h.head.pointerMove(h.win, s[0] + 40, s[1]);
    const t0 = host.nowUs();
    var x = start;
    while (x == start and host.nowUs() - t0 < limit_us) : (x = (dragQuad(&h) orelse break).rect[0]) host.sleepUs(5_000);
    try t.expectApproxEqAbs(start + 40, x, 0.01);
    try h.update();
    try t.expectEqualStrings("141 1", try h.eval(".p sash coord 0"));
    h.head.pointerButton(h.win, 1, false);
    try h.update();
}

test "paned: pack -in a sibling container places the widget in the coordinates of its parent" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("frame .top -height 30; pack .top -fill x; frame .box -width 100 -height 50; pack .box; frame .in -width 20 -height 10; pack .in -in .box; update");
    // The widget is a child of `.`, so its place includes the place of the box.
    try t.expectEqualStrings("1", try h.eval("expr {[winfo y .in] >= [winfo y .box]}"));
    try t.expectEqualStrings("1", try h.eval("expr {[winfo rooty .in] - [winfo rooty .box] < 50}"));
}
