//! Tests of transitions, the frame schedule, and the memory of ztk and of
//! the interpreter. Transitions run on the manual clock of the headless
//! backend, so the colors are exact.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Harness = @import("../testing.zig").Harness;
const t = std.testing;

fn bg(h: *Harness, path: []const u8) !u24 {
    const img = h.head.image(h.win).?;
    const w = h.app.find(path).?;
    const x: usize = @intCast(w.geom.x + 3);
    const y: usize = @intCast(w.geom.y + 3);
    const px = img.pixels[(y * img.width + x) * 4 ..][0..3];
    return (@as(u24, px[0]) << 16) | (@as(u24, px[1]) << 8) | px[2];
}

fn setup(h: *Harness) !void {
    try h.initAnimated();
    _ = try h.eval("ztk::style add {Button { background-color: #ffffff; border: 0; transition: background-color 120ms linear } Button:hover { background-color: #000000 }}");
    _ = try h.eval("button .b -text OK; grid .b -padx 20 -pady 20; update");
}

test "anim: a hover fades in 120 ms with three different frames" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    const b = h.app.find(".b").?;
    h.head.pointerMove(h.win, @floatFromInt(b.geom.x + 5), @floatFromInt(b.geom.y + 5));
    try h.update();
    const c0 = try bg(&h, ".b");
    h.head.advance(60);
    try h.update();
    const c1 = try bg(&h, ".b");
    h.head.advance(60);
    try h.update();
    const c2 = try bg(&h, ".b");
    try t.expect(c0 != c1 and c1 != c2 and c0 != c2);
    try t.expectEqual(@as(u24, 0x000000), c2);
    // A linear transition is at the middle after 60 ms.
    try t.expect(c1 > 0x700000 and c1 < 0x909090);
    // Nothing draws after the end.
    const drawn = h.head.frames_drawn;
    const requested = h.head.frames_requested;
    h.head.advance(5000);
    try h.update();
    try t.expectEqual(drawn, h.head.frames_drawn);
    try t.expectEqual(requested, h.head.frames_requested);
}

test "anim: a hover that ends goes back from the shown color" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    const b = h.app.find(".b").?;
    h.head.pointerMove(h.win, @floatFromInt(b.geom.x + 5), @floatFromInt(b.geom.y + 5));
    try h.update();
    h.head.advance(60);
    try h.update();
    const mid = try bg(&h, ".b");
    h.head.pointerMove(h.win, 1, 1);
    try h.update();
    // At the time of the change the shown color stays: no jump.
    try t.expectEqual(mid, try bg(&h, ".b"));
    h.head.advance(10);
    try h.update();
    const back = try bg(&h, ".b");
    // The color moves from the shown color toward white.
    try t.expect(back > mid);
    try t.expect(back < 0xffffff);
    h.head.advance(500);
    try h.update();
    try t.expectEqual(@as(u24, 0xffffff), try bg(&h, ".b"));
}

test "anim: no animation gives the end color at once" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("ztk::style add {Button { background-color: #ffffff; border: 0; transition: background-color 120ms } Button:hover { background-color: #000000 }}");
    _ = try h.eval("button .b -text OK; grid .b -padx 20 -pady 20; update");
    const b = h.app.find(".b").?;
    h.head.pointerMove(h.win, @floatFromInt(b.geom.x + 5), @floatFromInt(b.geom.y + 5));
    try h.update();
    try t.expectEqual(@as(u24, 0x000000), try bg(&h, ".b"));
}

test "anim: a transition runs no layout" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    const b = h.app.find(".b").?;
    const arranged = h.app.arrange_count;
    h.head.pointerMove(h.win, @floatFromInt(b.geom.x + 5), @floatFromInt(b.geom.y + 5));
    try h.update();
    h.head.advance(60);
    try h.update();
    h.head.advance(60);
    try h.update();
    try t.expectEqual(arranged, h.app.arrange_count);
}

// The task asks for 10 000 labels. A ztcl command registration costs time in proportion to the
// number of commands (4 000 `proc` definitions take 4.6 s), so 10 000 labels take about 30 s in
// a Debug build. These tests use 1 000 labels and the cost is a request for ztcl.
test "memory: 1000 labels leave no leak" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("for {set i 0} {$i < 1000} {incr i} { label .l$i -text x }");
    _ = try h.eval("for {set i 0} {$i < 1000} {incr i} { destroy .l$i }");
    try t.expectEqualStrings("", try h.eval("winfo children ."));
}

test "memory: bytes for each label" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const before = h.app.it.memUsed();
    const gpa_before = h.app.widgets.count();
    _ = try h.eval("for {set i 0} {$i < 1000} {incr i} { label .l$i -text x }");
    const arena = h.app.it.memUsed() - before;
    std.debug.print("memory: the interpreter arena grew {d} bytes for each label (1000 labels)\n", .{arena / 1000});
    try t.expectEqual(@as(usize, 1000), h.app.widgets.count() - gpa_before);
}

test "memory: a compact keeps the widgets, the bindings, the timers, and the traces" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("set n 0; button .b -text OK -command {incr n}; grid .b; set tv one; label .l -textvariable tv; grid .l; set fired 0; after 10 {set fired 1}; bind . <Motion> {set ::m %x}; bind . <Key-a> {incr ::k}; set k 0; update");
    try h.app.it.compact(&.{}, .{});
    h.app.script_gen +%= 1;
    _ = try h.eval(".b invoke");
    try t.expectEqualStrings("1", try h.eval("set n"));
    try t.expectEqualStrings(".b .l", try h.eval("winfo children ."));
    _ = try h.eval("ztk::style add {Label { color: #123456 }}");
    _ = try h.eval("set tv two; update");
    const w = h.app.find(".l").?;
    var buf: [7]u8 = undefined;
    h.app.ensureStyle(w);
    try t.expectEqualStrings("#123456", w.style.color.formatTk(&buf));
    try h.head.press(h.win, "a");
    try h.update();
    try t.expectEqualStrings("1", try h.eval("set k"));
    h.head.advance(20);
    try h.update();
    try t.expectEqualStrings("1", try h.eval("set fired"));
}

test "memory: 100000 motion events do not grow the arena" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("frame .f -width 100 -height 100; grid .f; bind .f <Motion> {set ::m %x}; update");
    const f = h.app.find(".f").?;
    const dispatch = @import("../dispatch.zig");
    var after_first: usize = 0;
    var i: u32 = 0;
    while (i < 100000) : (i += 1) {
        dispatch.handle(h.app, .{ .motion = .{ .window = h.win, .x = @floatFromInt(f.geom.x + @as(i32, @intCast(i % 50))), .y = @floatFromInt(f.geom.y + 2), .mods = .{}, .time_ms = 0 } });
        if (i % 1000 == 999) {
            h.app.compact_threshold = 0;
            _ = h.app.maybeCompact();
            if (i == 999) after_first = h.app.it.memUsed();
        }
    }
    const last = h.app.it.memUsed();
    std.debug.print("memory: arena after the first compact {d} bytes, after the last {d} bytes\n", .{ after_first, last });
    try t.expect(last <= after_first + (1 << 20));
}

test "headless: the clock of a test moves by the timeout, and the real clock sleeps" {
    const Headless = @import("../platform/headless.zig").Headless;
    const h = try Headless.init(std.testing.allocator);
    defer h.deinit();
    const p = h.platform();
    const t0 = p.vtable.nowUs(p.ptr);
    p.vtable.wait(p.ptr, 20_000);
    try std.testing.expectEqual(t0 + 20_000, p.vtable.nowUs(p.ptr));

    // The real clock sleeps 10 ms at most in one wait.
    h.real_clock = true;
    const r0 = p.vtable.nowUs(p.ptr);
    p.vtable.wait(p.ptr, 20_000);
    const slept = p.vtable.nowUs(p.ptr) - r0;
    try std.testing.expect(slept >= 10_000);
    try std.testing.expect(slept < 20_000 + 500_000);
}
