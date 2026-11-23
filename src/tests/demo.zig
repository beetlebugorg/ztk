//! End-to-end tests of `examples/demo.tcl`, the scene checks, and the
//! golden images of the demo. All input goes through the headless backend.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Harness = @import("../testing.zig").Harness;
const testing_h = @import("../testing.zig");
const checks = @import("../checks.zig");
const t = std.testing;

fn start(h: *Harness, dark: bool) !void {
    try h.initExamples(dark);
    try h.loadFile("examples/demo.tcl");
    try h.update();
}

fn center(h: *Harness, path: []const u8) [2]f32 {
    const w = h.app.find(path).?;
    return .{ @floatFromInt(w.geom.x + @divTrunc(w.geom.w, 2)), @floatFromInt(w.geom.y + @divTrunc(w.geom.h, 2)) };
}

fn problems(h: *Harness) !usize {
    const list = try checks.run(t.allocator, h.app.root.?, .{});
    defer t.allocator.free(list);
    defer checks.free(t.allocator, list);
    for (list) |p| std.debug.print("problem {s}: {s} ({s})\n", .{ p.path, @tagName(p.kind), p.detail });
    return list.len;
}

test "demo: the widgets, the focus, and the size" {
    var h: Harness = undefined;
    try start(&h, false);
    defer h.deinit();
    try t.expectEqualStrings(".title .lname .name .greet .count .quit .msg", try h.eval("winfo children ."));
    try t.expectEqualStrings(".name", try h.eval("focus"));
    try t.expectEqualStrings("3 4", try h.eval("grid size ."));
    const req = try std.fmt.parseInt(i32, try h.eval("winfo reqwidth ."), 10);
    try t.expect(try std.fmt.parseInt(i32, try h.eval("winfo width ."), 10) >= req);
}

test "demo: typing a name and Return greet" {
    var h: Harness = undefined;
    try start(&h, false);
    defer h.deinit();
    try h.head.typeText(h.win, "Ada");
    try h.head.press(h.win, "Return");
    try h.update();
    try t.expectEqualStrings("Hello, Ada!", try h.eval("set msg"));
    try t.expect(h.app.lastScene().quads.items.len > 20);
}

test "demo: two clicks on Count" {
    var h: Harness = undefined;
    try start(&h, false);
    defer h.deinit();
    const c = center(&h, ".count");
    h.head.click(h.win, c[0], c[1]);
    h.head.click(h.win, c[0], c[1]);
    try h.update();
    try t.expectEqualStrings("Clicks: 2", try h.eval("set msg"));
}

test "demo: the pointer on the title and off it" {
    var h: Harness = undefined;
    try start(&h, false);
    defer h.deinit();
    _ = try h.eval("set log {}; trace add variable msg write {lappend ::log $::msg;#}");
    const c = center(&h, ".title");
    h.head.pointerMove(h.win, c[0], c[1]);
    try h.update();
    h.head.pointerMove(h.win, 2, @floatFromInt(h.app.root.?.geom.h - 2));
    try h.update();
    try t.expectEqualStrings("The pointer is on the title. The pointer left the title.", try h.eval("join $log { }"));
}

test "demo: Tab goes around the widgets, and space clicks" {
    var h: Harness = undefined;
    try start(&h, false);
    defer h.deinit();
    for ([_][]const u8{ ".greet", ".count", ".quit", ".name" }) |want| {
        try h.head.press(h.win, "Tab");
        try h.update();
        try t.expectEqualStrings(want, try h.eval("focus"));
    }
    _ = try h.eval("focus .count");
    try h.head.press(h.win, "space");
    try h.update();
    try t.expectEqualStrings("Clicks: 1", try h.eval("set msg"));
}

test "demo: a resize makes the entry wider and keeps the buttons" {
    var h: Harness = undefined;
    try start(&h, false);
    defer h.deinit();
    const before_name = h.app.find(".name").?.geom.w;
    const before_greet = h.app.find(".greet").?.geom.w;
    h.head.resize(h.win, .{ .w = 600, .h = 300 });
    try h.update();
    try t.expect(h.app.find(".name").?.geom.w > before_name);
    try t.expectEqual(before_greet, h.app.find(".greet").?.geom.w);
}

test "demo: Escape, the Quit button, and the close event delete ." {
    {
        var h: Harness = undefined;
        try start(&h, false);
        defer h.deinit();
        try h.head.press(h.win, "Escape");
        try h.update();
        try t.expectEqualStrings("0", try h.eval("winfo exists ."));
        try h.app.run();
    }
    {
        var h: Harness = undefined;
        try start(&h, false);
        defer h.deinit();
        const c = center(&h, ".quit");
        h.head.click(h.win, c[0], c[1]);
        try h.update();
        try t.expectEqualStrings("0", try h.eval("winfo exists ."));
    }
    {
        var h: Harness = undefined;
        try start(&h, false);
        defer h.deinit();
        h.head.close(h.win);
        try h.update();
        try t.expectEqualStrings("0", try h.eval("winfo exists ."));
    }
}

test "checks: the demo has no problem in both schemes, and at larger sizes" {
    for ([_]bool{ false, true }) |dark| {
        var h: Harness = undefined;
        try start(&h, dark);
        defer h.deinit();
        try t.expectEqual(@as(usize, 0), try problems(&h));
        _ = try h.eval("ztk::style add {:root { font-size: 19.5px }}; update");
        try t.expectEqual(@as(usize, 0), try problems(&h));
    }
    for ([_]f32{ 2, 1.25 }) |scale| {
        var h: Harness = undefined;
        try start(&h, false);
        defer h.deinit();
        h.head.setScale(h.win, scale);
        try h.update();
        try t.expectEqual(@as(usize, 0), try problems(&h));
    }
}

test "checks: a pale text color and a small frame give problems" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("ztk::style add {Label { color: #cccccc; background-color: #ffffff }}");
    _ = try h.eval("label .pale -text Pale; grid .pale; update");
    const list = try checks.run(t.allocator, h.app.root.?, .{});
    defer t.allocator.free(list);
    defer checks.free(t.allocator, list);
    try t.expectEqual(@as(usize, 1), list.len);
    try t.expect(list[0].kind == .low_contrast);
    _ = try h.eval("destroy .pale; frame .box -width 20 -height 10; grid propagate .box 0; grid .box; label .box.l -text {A long text that is cut}; grid .box.l; update");
    const list2 = try checks.run(t.allocator, h.app.root.?, .{});
    defer t.allocator.free(list2);
    defer checks.free(t.allocator, list2);
    var clipped = false;
    for (list2) |p| if (p.kind == .text_clipped) {
        clipped = true;
    };
    try t.expect(clipped);
}

fn shot(h: *Harness, name: []const u8) !void {
    try h.update();
    try testing_h.expectGolden(name, h.head.image(h.win).?, .{});
    try testing_h.expectScene(name, h.app.lastScene());
}

test "demo-start" {
    var h: Harness = undefined;
    try start(&h, false);
    defer h.deinit();
    try shot(&h, "demo-start");
}

test "demo-dark" {
    var h: Harness = undefined;
    try start(&h, true);
    defer h.deinit();
    try shot(&h, "demo-dark");
}

test "demo-typed" {
    var h: Harness = undefined;
    try start(&h, false);
    defer h.deinit();
    try h.head.typeText(h.win, "Ada");
    try h.head.press(h.win, "Return");
    try shot(&h, "demo-typed");
}

test "demo-hover" {
    var h: Harness = undefined;
    try start(&h, false);
    defer h.deinit();
    const c = center(&h, ".count");
    h.head.pointerMove(h.win, c[0], c[1]);
    try shot(&h, "demo-hover");
}

test "demo-wide" {
    var h: Harness = undefined;
    try start(&h, false);
    defer h.deinit();
    h.head.resize(h.win, .{ .w = 600, .h = 300 });
    try shot(&h, "demo-wide");
}

test "demo-scale2" {
    var h: Harness = undefined;
    try start(&h, false);
    defer h.deinit();
    h.head.setScale(h.win, 2);
    try shot(&h, "demo-scale2");
}
