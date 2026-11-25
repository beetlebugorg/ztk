//! Tests of the work that the render thread does while the UI thread is
//! busy: keyframe animations, the colors of `ztk::animate`, the moves of
//! parts, and the drag of a scale. Each test stops the UI thread for a
//! time, as a script in a long loop does, and checks the frames that the
//! render thread drew by itself. The last tests check the same moves in
//! `inline_draw` mode (the browser build) and the pool of render threads.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Harness = @import("../testing.zig").Harness;
const host = @import("../sys/host.zig");
const scene = @import("../scene.zig");
const t = std.testing;

fn initThreaded(h: *Harness) !void {
    h.render_mode = .threaded;
    h.animations = true;
    h.dark = false;
    try h.initWith(null);
}

/// The UI thread runs no frame for `us`, as a script in a long loop.
fn busy(us: i64) void {
    const t0 = host.nowUs();
    while (host.nowUs() - t0 < us) host.sleepUs(5_000);
}

fn pixel(h: *Harness, path: []const u8) u24 {
    const img = h.head.image(h.win).?;
    const w = h.app.find(path).?;
    const x: usize = @intCast(w.geom.x + 3);
    const y: usize = @intCast(w.geom.y + 3);
    const px = img.pixels[(y * img.width + x) * 4 ..][0..3];
    return (@as(u24, px[0]) << 16) | (@as(u24, px[1]) << 8) | px[2];
}

/// Counts the frames that the render thread draws while the UI thread is busy for `us`.
fn drawnWhileBusy(h: *Harness, us: i64) u32 {
    const before = h.app.render.drawn.load(.monotonic);
    busy(us);
    return h.app.render.drawn.load(.monotonic) - before;
}

test "fluid: a keyframe animation moves while the script is busy" {
    var h: Harness = undefined;
    try initThreaded(&h);
    defer h.deinit();
    _ = try h.eval(
        \\ztk::style add {
        \\  @keyframes glow { from { background-color: #000000 } 50% { background-color: #ff0000 } to { background-color: #0000ff } }
        \\  Frame.g { animation: glow 400ms linear infinite }
        \\}
        \\frame .f -width 40 -height 40; ztk::class .f add g; pack .f; update
    );
    try t.expect(drawnWhileBusy(&h, 300_000) >= 5);
    // The color goes on to change with no frame of the UI thread.
    const a = pixel(&h, ".f");
    busy(100_000);
    const b = pixel(&h, ".f");
    try t.expect(a != b);
}

test "fluid: a color of ztk::animate moves while the script is busy" {
    var h: Harness = undefined;
    try initThreaded(&h);
    defer h.deinit();
    _ = try h.eval(
        \\frame .f -width 40 -height 40 -background #000000; pack .f; update
        \\ztk::animate .f -background #ff0000 -duration 250 -easing linear; update
    );
    try t.expect(drawnWhileBusy(&h, 400_000) >= 5);
    // The last frame shows the end color.
    try t.expectEqual(@as(u24, 0xff0000), pixel(&h, ".f"));
}

test "fluid: the knob of a switch moves while the script is busy" {
    var h: Harness = undefined;
    try initThreaded(&h);
    defer h.deinit();
    _ = try h.eval(
        \\checkbutton .c -text Check; ztk::class .c add switch; pack .c; update
        \\.c select; update
    );
    try t.expect(drawnWhileBusy(&h, 400_000) >= 5);
}

fn knobQuad(h: *Harness) ?scene.Quad {
    const f = h.app.render.last orelse return null;
    if (f.drags.items.len < 2) return null;
    return f.scene.quads.items[f.drags.items[1].first];
}

test "fluid: the slider of a scale follows the pointer while the script is busy" {
    var h: Harness = undefined;
    try initThreaded(&h);
    defer h.deinit();
    _ = try h.eval("scale .s -from 0 -to 100 -orient horizontal -length 200 -showvalue 0; pack .s -padx 10 -pady 10; update; .s set 20; update");
    const s = h.app.find(".s").?;
    const r = try h.eval(".s coords");
    var it = std.mem.splitScalar(u8, r, ' ');
    const x = try std.fmt.parseFloat(f32, it.next().?) + @as(f32, @floatFromInt(s.geom.x));
    const y = try std.fmt.parseFloat(f32, it.next().?) + @as(f32, @floatFromInt(s.geom.y));
    h.head.pointerMove(h.win, x, y);
    h.head.pointerButton(h.win, 1, true);
    try h.update();
    const start = (knobQuad(&h) orelse return error.NoDrag).rect[0];
    // The pointer moves 60 pixels and the UI thread handles no event.
    h.head.pointerMove(h.win, x + 60, y);
    busy(60_000);
    const moved = knobQuad(&h).?.rect[0];
    try t.expectApproxEqAbs(start + 60, moved, 0.01);
    // The value changes only when the UI thread runs.
    try t.expectEqualStrings("20", try h.eval(".s get"));
    // A move past the end stops at the end of the track.
    h.head.pointerMove(h.win, x + 1000, y);
    busy(60_000);
    const end = knobQuad(&h).?.rect[0];
    try t.expect(end < start + 200);
    try h.update();
    try t.expectEqualStrings("100", try h.eval(".s get"));
    h.head.pointerButton(h.win, 1, false);
    try h.update();
    // With the button up, the frame has no drag.
    try t.expectEqual(@as(usize, 0), h.app.render.last.?.drags.items.len);
}

test "fluid: inline mode moves an animation of the last frame with advance" {
    var h: Harness = undefined;
    try h.initAnimated();
    defer h.deinit();
    _ = try h.eval(
        \\frame .f -width 40 -height 40 -background #000000; pack .f; update
        \\ztk::animate .f -background #ff0000 -duration 100 -easing linear; update
    );
    const t0 = h.app.render.last.?.time_us;
    // 50 ms later, with no frame of the App, the quads show the middle color.
    try t.expect(h.app.render.advance(t0 + 50_000));
    const f = h.app.render.last.?;
    const q = f.scene.quads.items[f.anims.items[0].first];
    try t.expectApproxEqAbs(@as(f32, 0.5), q.fill[0], 0.02);
    try t.expect(h.app.render.advance(t0 + 200_000));
    try t.expectApproxEqAbs(@as(f32, 1), f.scene.quads.items[f.anims.items[0].first].fill[0], 0.001);
    // The end was drawn, so nothing moves.
    try t.expect(!h.app.render.advance(t0 + 300_000));
}

test "fluid: a toplevel takes a render thread from the pool and gives it back" {
    var h: Harness = undefined;
    try initThreaded(&h);
    defer h.deinit();
    try t.expectEqual(@as(usize, 1), h.app.render_pool.items.len);
    const spare = h.app.render_pool.items[0];
    _ = try h.eval("toplevel .t; label .t.l -text hi; pack .t.l; update");
    try t.expectEqual(@as(usize, 0), h.app.render_pool.items.len);
    try t.expectEqual(spare, h.app.topOf(h.app.find(".t").?).?.render);
    _ = try h.eval("destroy .t; update");
    try t.expectEqual(@as(usize, 1), h.app.render_pool.items.len);
    _ = try h.eval("toplevel .u; label .u.l -text again; pack .u.l; update");
    try t.expectEqual(spare, h.app.topOf(h.app.find(".u").?).?.render);
}
