//! Tests of `pack` and `place`: the options, `info`, `forget`,
//! `propagate`, the messages, and the geometry. The expected texts and
//! numbers are from `wish` 8.6.16.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Harness = @import("../testing.zig").Harness;
const t = std.testing;

fn setup(h: *Harness) !void {
    try h.init();
    _ = try h.eval("ztk::style add {Frame { border-width: 0; padding: 0 }}");
}

fn geo(h: *Harness, path: []const u8) ![]const u8 {
    var buf: [256]u8 = undefined;
    return h.eval(try std.fmt.bufPrint(&buf, "list [winfo x {s}] [winfo y {s}] [winfo width {s}] [winfo height {s}]", .{ path, path, path, path }));
}

test "pack: info, slaves, forget, and propagate" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    _ = try h.eval("frame .a -width 50 -height 30; frame .b -width 40 -height 20; pack .a -side left -padx {2 5} -fill y -expand 1; pack .b -ipadx 3");
    try t.expectEqualStrings("-in . -anchor center -expand 1 -fill y -ipadx 0 -ipady 0 -padx {2 5} -pady 0 -side left", try h.eval("pack info .a"));
    try t.expectEqualStrings("-in . -anchor center -expand 0 -fill none -ipadx 3 -ipady 0 -padx 0 -pady 0 -side top", try h.eval("pack info .b"));
    try t.expectEqualStrings(".a .b", try h.eval("pack slaves ."));
    try t.expectEqualStrings(".a .b", try h.eval("pack content ."));
    try t.expectEqualStrings("pack", try h.eval("winfo manager .a"));
    try t.expectEqualStrings("1", try h.eval("pack propagate ."));
    _ = try h.eval("frame .c -width 5 -height 5; pack .c -before .a");
    try t.expectEqualStrings(".c .a .b", try h.eval("pack slaves ."));
    _ = try h.eval("pack forget .c");
    try t.expectEqualStrings(".a .b", try h.eval("pack slaves ."));
    try t.expectEqualStrings("0", try h.eval("winfo ismapped .c"));
    _ = try h.eval("frame .d -width 5 -height 5; pack .d -after .a");
    try t.expectEqualStrings(".a .d .b", try h.eval("pack slaves ."));
}

test "pack: the messages of wish" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    _ = try h.eval("frame .a; frame .g; frame .h; pack .h; frame .h.g; grid .h.g");
    const cases = [_][2][]const u8{
        .{ "pack foo", "wrong # args: should be \"pack option arg ?arg ...?\"" },
        .{ "pack .a -side bogus", "bad side \"bogus\": must be top, bottom, left, or right" },
        .{ "pack .a -fill q", "bad fill style \"q\": must be none, x, y, or both" },
        .{ "pack .a -anchor q", "bad anchor \"q\": must be n, ne, e, se, s, sw, w, nw, or center" },
        .{ "pack .a -expand q", "expected boolean value but got \"q\"" },
        .{ "pack .a -padx -1", "bad pad value \"-1\": must be positive screen distance" },
        .{ "pack .a -ipadx -2", "bad ipadx value \"-2\": must be positive screen distance" },
        .{ "pack .a -after .zz", "bad window path name \".zz\"" },
        .{ "pack .a -foo 1", "bad option \"-foo\": must be -after, -anchor, -before, -expand, -fill, -in, -ipadx, -ipady, -padx, -pady, or -side" },
        .{ "pack .a -side", "extra option \"-side\" (option with no value?)" },
        .{ "pack info .g", "window \".g\" isn't packed" },
        .{ "pack bogus .a", "bad option \"bogus\": must be configure, content, forget, info, propagate, or slaves" },
        .{ "pack .a -in .a", "can't pack .a inside itself" },
        .{ "pack .", "can't pack \".\": it's a top-level window" },
        .{ "pack .a -pady {1 2 3}", "wrong number of parts to pad specification" },
        .{ "pack .a -before .a", "window \".a\" isn't packed" },
        .{ "grid .g", "cannot use geometry manager grid inside . which already has slaves managed by pack" },
    };
    for (cases) |c| try t.expectEqualStrings(c[1], try h.evalError(c[0]));
    // A container that grid leaves empty can change to pack.
    _ = try h.eval("pack .h.g");
    try t.expectEqualStrings("pack", try h.eval("winfo manager .h.g"));
    try t.expectEqualStrings("cannot use geometry manager grid inside .h which already has slaves managed by pack", try h.evalError("grid .a -in .h"));
}

test "pack: the geometry of fixed layouts" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    // Layout 0 of `tools/oracle-pack.tcl 1 1 v`, with the numbers of wish.
    _ = try h.eval(
        \\frame .c -width 100 -height 80; pack propagate .c 0
        \\frame .c.a -width 20 -height 10; pack .c.a -side left -fill y -padx 3
        \\frame .c.b -width 30 -height 15; pack .c.b -side top -expand 1 -anchor ne
        \\frame .c.d -width 10 -height 10; pack .c.d -side bottom -fill x -pady {2 4}
        \\place .c -x 0 -y 0
        \\update
    );
    try t.expectEqualStrings("3 0 20 80", try geo(&h, ".c.a"));
    try t.expectEqualStrings("70 0 30 15", try geo(&h, ".c.b"));
    try t.expectEqualStrings("26 66 74 10", try geo(&h, ".c.d"));
    // With propagation the container gets the size that the list needs.
    _ = try h.eval("pack propagate .c 1; update");
    try t.expectEqualStrings("56 31", try h.eval("list [winfo reqwidth .c] [winfo reqheight .c]"));
}

test "place: info, configure, forget, and the messages" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    _ = try h.eval("frame .a -width 50 -height 30; frame .g");
    _ = try h.eval("place .a -x 39 -y 5 -relwidth 0.5");
    try t.expectEqualStrings("-in . -x 39 -relx 0 -y 5 -rely 0 -width {} -relwidth 0.5 -height {} -relheight {} -anchor nw -bordermode inside", try h.eval("place info .a"));
    try t.expectEqualStrings("place", try h.eval("winfo manager .a"));
    try t.expectEqualStrings(".a", try h.eval("place slaves ."));
    try t.expectEqualStrings("-x {} {} 0 39", try h.eval("place configure .a -x"));
    try t.expectEqualStrings("", try h.eval("place info .g"));
    const cases = [_][2][]const u8{
        .{ "place .a -x", "value for \"-x\" missing" },
        .{ "place .a -foo 1", "unknown option \"-foo\"" },
        .{ "place .a -relx q", "expected floating-point number but got \"q\"" },
        .{ "place .a -anchor q", "bad anchor \"q\": must be n, ne, e, se, s, sw, w, nw, or center" },
        .{ "place .a -bordermode q", "bad bordermode \"q\": must be inside, outside, or ignore" },
        .{ "place bogus", "wrong # args: should be \"place option|pathName args\"" },
        .{ "place bogus .a", "bad option \"bogus\": must be configure, content, forget, info, or slaves" },
        .{ "place .a -in .zz", "bad window path name \".zz\"" },
        .{ "place .a -in .a", "can't place .a relative to itself" },
        .{ "place .a -width q", "bad screen distance \"q\"" },
    };
    for (cases) |c| try t.expectEqualStrings(c[1], try h.evalError(c[0]));
    _ = try h.eval("place forget .a");
    try t.expectEqualStrings("", try h.eval("place slaves ."));
    try t.expectEqualStrings("", try h.eval("winfo manager .a"));
}

test "place: the geometry" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    // Cases like layouts 3 and 154 of `tools/oracle-place.tcl`, with the numbers of wish.
    _ = try h.eval(
        \\frame .c -width 34 -height 82; place .c -x 0 -y 0
        \\frame .c.f -width 9 -height 12
        \\place .c.f -x -5 -y -20 -relx 0.13 -relwidth 0.26 -anchor nw
        \\update
    );
    const r = try geo(&h, ".c.f");
    try t.expectEqualStrings("-1 -20 9 12", r);
    _ = try h.eval("place .c.f -x 0 -y 0 -relx 0.5 -rely 0.5 -anchor center -width 0 -relwidth {}; update");
    try t.expectEqualStrings("17 35 1 12", try geo(&h, ".c.f"));
    // A placed widget moves with its container.
    _ = try h.eval("frame .c.in -width 10 -height 10; place .c.in -x 4 -y 6; frame .c.p -width 2 -height 2; place .c.p -in .c.in -x 1 -y 1; update");
    try t.expectEqualStrings("5 7 2 2", try geo(&h, ".c.p"));
    _ = try h.eval("destroy .c.in; update");
    try t.expectEqualStrings("place", try h.eval("winfo manager .c.p"));
    try t.expectEqualStrings("0", try h.eval("winfo ismapped .c.p"));
}

test "pack and place: the window of . gets the size of the content" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    _ = try h.eval("frame .a -width 120 -height 40; frame .b -width 60 -height 30; pack .a .b; update");
    try t.expectEqualStrings("120 70", try h.eval("list [winfo width .] [winfo height .]"));
    _ = try h.eval("pack .b -side left -after .a; update");
    try t.expectEqualStrings("120 70", try h.eval("list [winfo width .] [winfo height .]"));
}
