//! Tests of the grid solver and the `grid` command. The expected values
//! and messages come from runs of `wish` 8.6.16.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const grid = @import("../grid.zig");
const Harness = @import("../testing.zig").Harness;
const t = std.testing;

const Line = grid.Line;
const Item = grid.Item;

fn solveOk(lines: []const Line, items: []const Item, avail: ?i32, want: []const i32) !void {
    var buf: [40]i32 = undefined;
    const off = buf[0 .. lines.len + 1];
    try grid.solve(t.allocator, lines, items, avail, off);
    try t.expectEqualSlices(i32, want, off);
}

test "grid-solve: minimum layout and weights" {
    const two = [_]Line{ .{}, .{} };
    const items = [_]Item{ .{ .first = 0, .span = 1, .size = 30 }, .{ .first = 1, .span = 1, .size = 50 } };
    try solveOk(&two, &items, null, &.{ 0, 30, 80 });
    const w11 = [_]Line{ .{ .weight = 1 }, .{ .weight = 1 } };
    try solveOk(&w11, &items, 100, &.{ 0, 40, 100 });
    try solveOk(&two, &items, 100, &.{ 0, 30, 80 });
}

test "grid-solve: a span, minsize, and uniform groups" {
    const two = [_]Line{ .{}, .{} };
    try solveOk(&two, &.{.{ .first = 0, .span = 2, .size = 100 }}, null, &.{ 0, 50, 100 });
    const uni = [_]Line{ .{ .weight = 1, .uniform = "a" }, .{ .weight = 2, .uniform = "a" } };
    const items30 = [_]Item{ .{ .first = 0, .span = 1, .size = 30 }, .{ .first = 1, .span = 1, .size = 30 } };
    try solveOk(&uni, &items30, null, &.{ 0, 30, 90 });
    try solveOk(&uni, &items30, 200, &.{ 0, 66, 200 });
    const mins = [_]Line{ .{ .minsize = 40 }, .{} };
    try solveOk(&mins, &.{.{ .first = 0, .span = 1, .size = 10 }}, null, &.{ 0, 40, 40 });
    try solveOk(&mins, &.{.{ .first = 0, .span = 2, .size = 100 }}, null, &.{ 0, 70, 100 });
}

test "grid-solve: shrink" {
    const items = [_]Item{ .{ .first = 0, .span = 1, .size = 50 }, .{ .first = 1, .span = 1, .size = 50 } };
    const w11 = [_]Line{ .{ .weight = 1 }, .{ .weight = 1 } };
    try solveOk(&w11, &items, 60, &.{ 0, 30, 60 });
    const w11m = [_]Line{ .{ .weight = 1, .minsize = 45 }, .{ .weight = 1 } };
    try solveOk(&w11m, &items, 60, &.{ 0, 45, 60 });
}

test "grid-solve: pad, rounding, and clamping match wish" {
    // A pad counts only on a line with an item.
    try solveOk(&.{ .{ .pad = 5 }, .{ .pad = 5 } }, &.{.{ .first = 0, .span = 1, .size = 10 }}, null, &.{ 0, 15, 15 });
    // The remainder goes to the later lines.
    const w3 = [_]Line{ .{ .weight = 1 }, .{ .weight = 1 }, .{ .weight = 1 } };
    const it5 = [_]Item{ .{ .first = 0, .span = 1, .size = 5 }, .{ .first = 1, .span = 1, .size = 5 }, .{ .first = 2, .span = 1, .size = 5 } };
    try solveOk(&w3, &it5, 40, &.{ 0, 13, 26, 40 });
    // A line at its minimum leaves the shrink.
    const clamp = [_]Line{ .{ .weight = 1 }, .{ .weight = 1, .minsize = 48 }, .{ .weight = 1 } };
    const it50 = [_]Item{ .{ .first = 0, .span = 1, .size = 50 }, .{ .first = 1, .span = 1, .size = 50 }, .{ .first = 2, .span = 1, .size = 50 } };
    try solveOk(&clamp, &it50, 120, &.{ 0, 36, 84, 120 });
    // The uniform pass rounds up.
    const uni = [_]Line{ .{ .weight = 2, .uniform = "a" }, .{ .weight = 3, .uniform = "a" } };
    try solveOk(&uni, &.{ .{ .first = 0, .span = 1, .size = 11 }, .{ .first = 1, .span = 1, .size = 11 } }, null, &.{ 0, 12, 30 });
}

test "grid-solve: no allocation for 32 lines" {
    var lines: [32]Line = undefined;
    var items: [32]Item = undefined;
    for (&lines, &items, 0..) |*l, *it, i| {
        l.* = .{ .weight = 1 };
        it.* = .{ .first = @intCast(i), .span = 1, .size = 10 };
    }
    var off: [33]i32 = undefined;
    try grid.solve(t.failing_allocator, &lines, &items, 640, &off);
    try t.expectEqual(@as(i32, 640), off[32]);
    try grid.solve(t.failing_allocator, &lines, &items, 100, &off);
    try t.expectEqual(@as(i32, 100), off[32]);
}

fn setup(h: *Harness) !void {
    try h.init();
    _ = try h.eval("ztk::style add {Frame { border-width: 0; padding: 0 }}");
}

test "grid: the layout of three frames" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    _ = try h.eval("frame .a -width 30 -height 20; frame .b -width 50 -height 10; frame .c -width 10 -height 40");
    _ = try h.eval("grid .a .b; grid .c - -sticky ew; update");
    try t.expectEqualStrings("2 2", try h.eval("grid size ."));
    try t.expectEqualStrings("0 0 80 60", try h.eval("grid bbox ."));
    const root = h.app.root.?;
    try t.expectEqual(@as(i32, 80), root.req.w);
    try t.expectEqual(@as(i32, 60), root.req.h);
    const a = h.app.find(".a").?.geom;
    const b = h.app.find(".b").?.geom;
    const c = h.app.find(".c").?.geom;
    try t.expectEqual(@as(i32, 30), a.w);
    try t.expectEqual(@as(i32, 20), a.h);
    try t.expectEqual(@as(i32, 0), a.x);
    try t.expectEqual(@as(i32, 0), a.y);
    try t.expectEqual(@as(i32, 50), b.w);
    try t.expectEqual(@as(i32, 10), b.h);
    try t.expectEqual(@as(i32, 30), b.x);
    try t.expectEqual(@as(i32, 5), b.y);
    try t.expectEqual(@as(i32, 80), c.w);
    try t.expectEqual(@as(i32, 40), c.h);
    try t.expectEqual(@as(i32, 0), c.x);
    try t.expectEqual(@as(i32, 20), c.y);
    try t.expectEqualStrings("-in . -column 0 -row 1 -columnspan 2 -rowspan 1 -ipadx 0 -ipady 0 -padx 0 -pady 0 -sticky ew", try h.eval("grid info .c"));
    try t.expectEqualStrings(".c .b .a", try h.eval("grid slaves ."));
    try t.expectEqualStrings(".b .a", try h.eval("grid slaves . -row 0"));
    try t.expectEqualStrings("0 0 30 20", try h.eval("grid bbox . 0 0"));
    _ = try h.eval("grid forget .b");
    try t.expectEqualStrings(".c .a", try h.eval("grid slaves ."));
    try t.expectEqualStrings("", try h.eval("grid info .b"));
    _ = try h.eval("grid remove .a; grid .a");
    try t.expect(std.mem.startsWith(u8, try h.eval("grid info .a"), "-in . -column 0 -row 0 "));
    try t.expectEqualStrings("grid", try h.eval("winfo manager .a"));
    try t.expectEqualStrings("", try h.eval("winfo manager .b"));
}

test "grid: weights fill the container and sticky places the widget" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    _ = try h.eval("frame .c -width 200 -height 100; grid propagate .c 0; grid .c");
    _ = try h.eval("frame .c.a -width 20 -height 10; frame .c.b -width 20 -height 10");
    _ = try h.eval("grid .c.a .c.b -sticky ew; grid columnconfigure .c {0 1} -weight 1; update");
    try t.expectEqual(@as(i32, 100), h.app.find(".c.a").?.geom.w);
    try t.expectEqual(@as(i32, 100), h.app.find(".c.b").?.geom.w);
    try t.expectEqual(@as(i32, 100), h.app.find(".c.b").?.geom.x);
    try t.expectEqual(@as(i32, 10), h.app.find(".c.b").?.geom.h);
    _ = try h.eval("grid anchor .c se; grid columnconfigure .c {0 1} -weight 0; update");
    try t.expectEqual(@as(i32, 20), h.app.find(".c.a").?.geom.w);
    try t.expectEqual(@as(i32, 160), h.app.find(".c.a").?.geom.x);
    try t.expectEqual(@as(i32, 90), h.app.find(".c.a").?.geom.y);
    try t.expectEqualStrings("160 90 40 10", try h.eval("grid bbox .c"));
}

test "grid: the errors are the messages of wish" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    _ = try h.eval("frame .a; frame .c; frame .d; frame .c.e");
    const cases = [_][2][]const u8{
        .{ "grid", "wrong # args: should be \"grid option arg ?arg ...?\"" },
        .{ "grid foo", "wrong # args: should be \"grid option arg ?arg ...?\"" },
        .{ "grid .zz", "bad window path name \".zz\"" },
        .{ "grid .a -bogus 1", "bad option \"-bogus\": must be -column, -columnspan, -in, -ipadx, -ipady, -padx, -pady, -row, -rowspan, or -sticky" },
        .{ "grid .a -row x", "bad row value \"x\": must be a non-negative integer" },
        .{ "grid .a -columnspan 0", "bad columnspan value \"0\": must be a positive integer" },
        .{ "grid .a -padx {1 2 3}", "wrong number of parts to pad specification" },
        .{ "grid .a -sticky q", "bad stickyness value \"q\": must be a string containing n, e, s, and/or w" },
        .{ "grid .a -in .a", "window can't be managed in itself" },
        .{ "grid .", "can't manage \".\": it's a top-level window" },
        .{ "grid ^", "can't use '^', cant find master" },
        .{ "grid .a ^", "can't find slave to extend with \"^\"" },
        .{ "grid .c.e -in .d", "can't put .c.e inside .d" },
        .{ "grid .a -padx", "extra option or option with no value" },
        .{ "grid .a foo", "unexpected parameter \"foo\" in configure list: should be window name or option" },
        .{ "grid - .a", "bad option \"-\": must be anchor, bbox, columnconfigure, configure, content, forget, info, location, propagate, remove, rowconfigure, size, or slaves" },
        .{ "grid columnconfigure . 0 -weight -1", "invalid arg \"-weight\": should be non-negative" },
        .{ "grid columnconfigure . 0 -bogus 1", "bad option \"-bogus\": must be -minsize, -pad, -uniform, or -weight" },
        .{ "grid columnconfigure . x -weight 1", "illegal index \"x\"" },
        .{ "grid anchor . foo", "bad anchor \"foo\": must be n, ne, e, se, s, sw, w, nw, or center" },
        .{ "grid .a -padx -1", "bad pad value \"-1\": must be positive screen distance" },
        .{ "grid slaves . -bogus 1", "bad option \"-bogus\": must be -column or -row" },
    };
    for (cases) |c| try t.expectEqualStrings(c[1], try h.evalError(c[0]));
    _ = try h.eval("grid .a");
}

test "grid: relative placement and the next row" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    _ = try h.eval("foreach n {a b c d e} {frame .$n -width 10 -height 10}");
    _ = try h.eval("grid .a x .b; grid .c - x .d; grid .e -row 7 -rowspan 2");
    try t.expectEqualStrings("-in . -column 2 -row 0 -columnspan 1 -rowspan 1 -ipadx 0 -ipady 0 -padx 0 -pady 0 -sticky {}", try h.eval("grid info .b"));
    try t.expectEqualStrings("-in . -column 0 -row 1 -columnspan 2 -rowspan 1 -ipadx 0 -ipady 0 -padx 0 -pady 0 -sticky {}", try h.eval("grid info .c"));
    try t.expectEqualStrings("-in . -column 3 -row 1 -columnspan 1 -rowspan 1 -ipadx 0 -ipady 0 -padx 0 -pady 0 -sticky {}", try h.eval("grid info .d"));
    try t.expectEqualStrings("4 9", try h.eval("grid size ."));
    _ = try h.eval("frame .f -width 5 -height 5; grid .f");
    try t.expect(std.mem.startsWith(u8, try h.eval("grid info .f"), "-in . -column 0 -row 9 "));
    _ = try h.eval("grid forget .a .b .c .d .e .f; grid .a -row 0 -column 0 -rowspan 2; grid .b -row 0 -column 1; grid .c -row 1 -column 1; grid .d ^ ");
    try t.expectEqualStrings("can't find slave to extend with \"^\"", try h.evalError("grid .e ^ ^"));
}

test "grid: padding and uneven pads" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    _ = try h.eval("frame .a -width 20 -height 10; grid .a -padx {1 3} -pady 2 -ipadx 4 -ipady 1; update");
    const g = h.app.find(".a").?.geom;
    try t.expectEqual(@as(i32, 28), g.w);
    try t.expectEqual(@as(i32, 12), g.h);
    try t.expectEqual(@as(i32, 1), g.x);
    try t.expectEqual(@as(i32, 2), g.y);
    try t.expectEqualStrings("-in . -column 0 -row 0 -columnspan 1 -rowspan 1 -ipadx 4 -ipady 1 -padx {1 3} -pady 2 -sticky {}", try h.eval("grid info .a"));
}

test "grid: deleting a container or a widget leaves no leak" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    _ = try h.eval("frame .c; frame .c.a; frame .c.b; grid .c.a .c.b; grid .c; grid columnconfigure .c 0 -uniform u");
    _ = try h.eval("frame .x; grid .x -in .c; grid remove .c.a");
    _ = try h.eval("destroy .c.a; destroy .c");
    _ = try h.eval("update");
    try t.expectEqualStrings("", try h.eval("winfo manager .x"));
}

test "grid-speed: a layout pass of 1000 widgets" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    _ = try h.eval("frame .c; grid .c; for {set i 0} {$i < 1000} {incr i} { frame .c.f$i -width [expr {10 + $i % 7}] -height 8; grid .c.f$i -row [expr {$i / 40}] -column [expr {$i % 40}] }");
    _ = try h.eval("update");
    const layout = @import("../layout.zig");
    const c = h.app.find(".c").?;
    const root = h.app.root.?;
    var best: f64 = 1e9;
    var rep: usize = 0;
    while (rep < 5) : (rep += 1) {
        c.dirty.layout = true;
        c.dirty.measure = true;
        root.dirty.layout = true;
        root.dirty.measure = true;
        const t0 = std.Io.Clock.awake.now(t.io);
        try t.expect(layout.run(root));
        const ns = t0.untilNow(t.io, .awake).toNanoseconds();
        best = @min(best, @as(f64, @floatFromInt(ns)) / 1e6);
    }
    const ms = best;
    std.debug.print("grid-speed: {d:.3} ms for 1000 widgets ({s})\n", .{ ms, @tagName(@import("builtin").mode) });
    if (@import("builtin").mode == .ReleaseFast) try t.expect(ms < 1.0);
}
