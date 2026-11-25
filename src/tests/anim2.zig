//! Tests of the animation engine of the widget stage: the timing of each
//! property, the delay, `@keyframes`, `ztk::animate`, reduced motion,
//! `ztk::clock`, and the transitions that the render thread moves while
//! the UI thread is busy. The headless clock is manual, so the colors at
//! a time are exact.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Harness = @import("../testing.zig").Harness;
const anim = @import("../anim.zig");
const host = @import("../sys/host.zig");
const t = std.testing;

fn pixel(h: *Harness, path: []const u8) u24 {
    const img = h.head.image(h.win).?;
    const w = h.app.find(path).?;
    const x: usize = @intCast(w.geom.x + 3);
    const y: usize = @intCast(w.geom.y + 3);
    const px = img.pixels[(y * img.width + x) * 4 ..][0..3];
    return (@as(u24, px[0]) << 16) | (@as(u24, px[1]) << 8) | px[2];
}

fn red(c: u24) u8 {
    return @intCast(c >> 16);
}

test "anim2: a transition with a delay and its own timing for each property" {
    var h: Harness = undefined;
    try h.initAnimated();
    defer h.deinit();
    _ = try h.eval(
        \\ztk::style add {
        \\  Frame.x { background-color: #000000; opacity: 1; transition: background-color 100ms linear 50ms, opacity 200ms steps(2) }
        \\  Frame.x.on { background-color: #ff0000; opacity: 0.5 }
        \\}
        \\frame .f -width 40 -height 40; ztk::class .f add x; pack .f; update
        \\ztk::class .f add on; update
    );
    const w = h.app.find(".f").?;
    // In the delay the color stays.
    h.head.advance(40);
    try h.update();
    try t.expectEqual(@as(u8, 0), anim.shown(h.app, w).background.r);
    // At the middle of the 100 ms after the delay, the color is in the middle.
    h.head.advance(60);
    try h.update();
    try t.expectEqual(@as(u8, 128), anim.shown(h.app, w).background.r);
    // steps(2) at 100 of 200 ms is the first step.
    try t.expectApproxEqAbs(@as(f32, 0.75), anim.shown(h.app, w).opacity, 0.001);
    // The scene that the renderer drew has the same color.
    // The pixel has the opacity 0.75 over the root color #f5f5f7: 128 * 0.75 + 245 * 0.25 = 157.
    try t.expectEqual(@as(u8, 157), red(pixel(&h, ".f")));
    h.head.advance(200);
    try h.update();
    try t.expectEqual(@as(u8, 255), anim.shown(h.app, w).background.r);
    try t.expectApproxEqAbs(@as(f32, 0.5), anim.shown(h.app, w).opacity, 0.001);
}

test "anim2: a change during a transition starts from the shown value" {
    var h: Harness = undefined;
    try h.initAnimated();
    defer h.deinit();
    _ = try h.eval(
        \\ztk::style add {
        \\  Frame.x { background-color: #000000; transition: background-color 100ms linear }
        \\  Frame.x.on { background-color: #ff0000 }
        \\}
        \\frame .f -width 40 -height 40; ztk::class .f add x; pack .f; update
        \\ztk::class .f add on; update
    );
    const w = h.app.find(".f").?;
    h.head.advance(50);
    try h.update();
    const mid = anim.shown(h.app, w).background.r;
    _ = try h.eval("ztk::class .f remove on; update");
    try t.expectEqual(mid, anim.shown(h.app, w).background.r);
    h.head.advance(50);
    try h.update();
    try t.expectEqual(@as(u8, 64), anim.shown(h.app, w).background.r);
}

test "anim2: padding moves with the layout" {
    var h: Harness = undefined;
    try h.initAnimated();
    defer h.deinit();
    _ = try h.eval(
        \\ztk::style add {
        \\  Label.x { padding: 0; border: 0; transition: padding 100ms linear }
        \\  Label.x.big { padding: 20px }
        \\}
        \\label .l -text {}; ztk::class .l add x; pack .l; update
        \\ztk::class .l add big; update
    );
    h.head.advance(50);
    try h.update();
    // An empty label has the width 0, so the width is the padding.
    try t.expectEqualStrings("20", try h.eval("winfo reqwidth .l"));
    h.head.advance(60);
    try h.update();
    try t.expectEqualStrings("40", try h.eval("winfo reqwidth .l"));
}

test "anim2: keyframes with three stops, infinite and alternate" {
    var h: Harness = undefined;
    try h.initAnimated();
    defer h.deinit();
    _ = try h.eval(
        \\ztk::style add {
        \\  @keyframes glow { from { background-color: #000000 } 50% { background-color: #ff0000 } to { background-color: #ffffff } }
        \\  Frame.g { animation: glow 200ms linear infinite alternate }
        \\}
        \\frame .f -width 40 -height 40; ztk::class .f add g; pack .f; update
    );
    const w = h.app.find(".f").?;
    const want = [_]struct { ms: i64, r: u8, g: u8 }{
        .{ .ms = 0, .r = 0, .g = 0 },
        .{ .ms = 50, .r = 128, .g = 0 },
        .{ .ms = 100, .r = 255, .g = 0 },
        .{ .ms = 150, .r = 255, .g = 128 },
        // The second iteration runs backward.
        .{ .ms = 250, .r = 255, .g = 128 },
        .{ .ms = 350, .r = 128, .g = 0 },
    };
    var now: i64 = 0;
    for (want) |c| {
        h.head.advance(c.ms - now);
        now = c.ms;
        try h.update();
        const st = anim.shown(h.app, w);
        try t.expectEqual(c.r, st.background.r);
        try t.expectEqual(c.g, st.background.g);
    }
    // The animation asks for frames while it runs.
    const req = h.head.frames_requested;
    h.head.advance(16);
    try h.update();
    try t.expect(h.head.frames_requested > req);
}

test "anim2: ztk::animate with cancel, pause, resume, info, replace, and -command" {
    var h: Harness = undefined;
    try h.initAnimated();
    defer h.deinit();
    _ = try h.eval("set done 0; frame .f -width 40 -height 40 -background #000000; pack .f; update");
    const id = try h.eval("ztk::animate .f -background #ff0000 -width 140 -duration 100 -easing linear -command {incr done}");
    try t.expectEqualStrings("anim#1", id);
    try t.expectEqualStrings("anim#1", try h.eval("ztk::animate info"));
    h.head.advance(50);
    try h.update();
    try t.expectEqualStrings("#800000", try h.eval(".f cget -background"));
    try t.expectEqualStrings("90", try h.eval(".f cget -width"));
    try t.expectEqualStrings("-target .f -state running -elapsed 50", try h.eval("ztk::animate info anim#1"));
    _ = try h.eval("ztk::animate pause anim#1");
    h.head.advance(500);
    try h.update();
    try t.expectEqualStrings("#800000", try h.eval(".f cget -background"));
    _ = try h.eval("ztk::animate resume anim#1");
    h.head.advance(25);
    try h.update();
    try t.expectEqualStrings("#bf0000", try h.eval(".f cget -background"));
    // A new animation of -width replaces that track and starts from the shown value.
    _ = try h.eval("ztk::animate .f -width 15 -duration 100 -easing linear");
    h.head.advance(50);
    try h.update();
    try t.expectEqualStrings("65", try h.eval(".f cget -width"));
    h.head.advance(500);
    try h.update();
    try h.update();
    try t.expectEqualStrings("#ff0000", try h.eval(".f cget -background"));
    try t.expectEqualStrings("15", try h.eval(".f cget -width"));
    try t.expectEqualStrings("1", try h.eval("set done"));
    try t.expectEqualStrings("", try h.eval("ztk::animate info"));
    // Cancel keeps the shown value and runs no command.
    _ = try h.eval("ztk::animate .f -background #000000 -duration 100 -easing linear -command {incr done}");
    h.head.advance(50);
    try h.update();
    _ = try h.eval("ztk::animate cancel anim#3");
    h.head.advance(500);
    try h.update();
    try t.expectEqualStrings("#800000", try h.eval(".f cget -background"));
    try t.expectEqualStrings("1", try h.eval("set done"));
    try t.expectEqualStrings("animation \"anim#9\" doesn't exist", try h.evalError("ztk::animate cancel anim#9"));
    try t.expectEqualStrings("bad window path name \".zz\"", try h.evalError("ztk::animate .zz -width 3"));
    try t.expectEqualStrings("bad easing \"bounce\": must be linear, ease, ease-in, ease-out, ease-in-out, cubic-bezier, steps, or spring", try h.evalError("ztk::animate .f -width 3 -easing bounce"));
}

test "anim2: reduced motion gives the end state in the next frame" {
    var h: Harness = undefined;
    try h.initAnimated();
    defer h.deinit();
    _ = try h.eval(
        \\ztk::style add { Frame.x { background-color: #000000; transition: all 1s } Frame.x.on { background-color: #ff0000 } }
        \\set done 0; frame .f -width 40 -height 40; ztk::class .f add x; pack .f; update
        \\ztk::animate reduce 1
        \\ztk::class .f add on
        \\ztk::animate .f -width 99 -duration 1000 -command {incr done}
        \\update; update
    );
    const w = h.app.find(".f").?;
    try t.expectEqual(@as(u8, 255), anim.shown(h.app, w).background.r);
    try t.expectEqualStrings("99", try h.eval(".f cget -width"));
    try t.expectEqualStrings("1", try h.eval("set done"));
    try t.expectEqualStrings("1", try h.eval("ztk::animate reduce"));
}

test "anim2: ztk::clock" {
    var h: Harness = undefined;
    try h.initAnimated();
    defer h.deinit();
    _ = try h.eval("ztk::clock set 1234");
    try t.expectEqualStrings("1234", try h.eval("ztk::clock get"));
    try t.expectEqualStrings("wrong # args: should be \"ztk::clock get|set ?ms?\"", try h.evalError("ztk::clock"));
}

test "anim2: the render thread moves a transition while the script is busy" {
    var h: Harness = undefined;
    h.render_mode = .threaded;
    h.animations = true;
    h.dark = false;
    try h.initWith(null);
    defer h.deinit();
    _ = try h.eval(
        \\ztk::style add { Frame.x { background-color: #000000; transition: background-color 300ms linear } Frame.x.on { background-color: #ff0000 } }
        \\frame .f -width 40 -height 40; ztk::class .f add x; pack .f; update
        \\ztk::class .f add on; update
    );
    const before = h.app.render.drawn.load(.monotonic);
    // The UI thread runs no frame for 500 ms, as a script in a long loop.
    const t0 = host.nowUs();
    while (host.nowUs() - t0 < 500_000) host.sleepUs(10_000);
    const after = h.app.render.drawn.load(.monotonic);
    // The render thread drew frames of the transition by itself, at about 120 in each second.
    try t.expect(after - before >= 5);
    // The last frame shows the end color.
    try t.expectEqual(@as(u8, 255), red(pixel(&h, ".f")));
}
