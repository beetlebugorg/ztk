//! Tests of the work that the render thread does while the UI thread is
//! busy: keyframe animations, the colors of `ztk::animate`, the moves of
//! parts, and the drag of a scale. Each test keeps the UI thread from
//! running a frame, as a script in a long loop does, until the render
//! thread drew what the test checks, or 2 seconds passed. A slow machine
//! gets more time and a fast one ends early. The last tests check the same moves in
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


/// A pixel of the last image. The render thread writes the image during a
/// draw, and a read during a draw can see the clear color. The headless
/// backend counts the draws that started and the draws that ended, so the
/// read is good when the two are equal before it and no draw started
/// during it. A lock on the render thread cannot do this: with an
/// animation that runs, the thread holds its draw state for almost all
/// of the time.
fn pixel(h: *Harness, path: []const u8) u24 {
    const w = h.app.find(path).?;
    const x: usize = @intCast(w.geom.x + 3);
    const y: usize = @intCast(w.geom.y + 3);
    const t0 = host.nowUs();
    while (true) {
        const started = h.head.draws_started.load(.acquire);
        const ended = @atomicLoad(u32, &h.head.frames_drawn, .acquire);
        const img = h.head.image(h.win).?;
        const px = img.pixels[(y * img.width + x) * 4 ..][0..3];
        const value = (@as(u24, px[0]) << 16) | (@as(u24, px[1]) << 8) | px[2];
        const quiet = started == ended and h.head.draws_started.load(.acquire) == started;
        // A draw that fails ends with no count, so the wait has the limit.
        if (quiet or host.nowUs() - t0 > limit_us) return value;
        host.sleepUs(500);
    }
}

/// The longest wait for the render thread. A slow machine needs more than
/// the time of the animation, so each wait polls up to this limit and
/// ends as soon as its condition is true.
const limit_us: i64 = 2_000_000;

/// Keeps the UI thread busy, as `busy` does, until the render thread drew
/// `n` frames or the limit passed. Returns the count of the frames.
fn drawsWhileBusy(h: *Harness, n: u32) u32 {
    const before = h.app.render.drawn.load(.monotonic);
    const t0 = host.nowUs();
    while (h.app.render.drawn.load(.monotonic) - before < n and host.nowUs() - t0 < limit_us) host.sleepUs(5_000);
    return h.app.render.drawn.load(.monotonic) - before;
}

/// Keeps the UI thread busy until the pixel of a widget is not `old`, or
/// the limit passed. Returns the last pixel.
fn pixelChangesFrom(h: *Harness, path: []const u8, old: u24) u24 {
    const t0 = host.nowUs();
    var p = pixel(h, path);
    while (p == old and host.nowUs() - t0 < limit_us) : (p = pixel(h, path)) host.sleepUs(5_000);
    return p;
}

/// Keeps the UI thread busy until the pixel of a widget is `want`, or the limit passed.
fn pixelBecomes(h: *Harness, path: []const u8, want: u24) u24 {
    const t0 = host.nowUs();
    var p = pixel(h, path);
    while (p != want and host.nowUs() - t0 < limit_us) : (p = pixel(h, path)) host.sleepUs(5_000);
    return p;
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
    try t.expect(drawsWhileBusy(&h, 5) >= 5);
    // The color goes on to change with no frame of the UI thread.
    const a = pixel(&h, ".f");
    try t.expect(pixelChangesFrom(&h, ".f", a) != a);
}

test "fluid: a color of ztk::animate moves while the script is busy" {
    var h: Harness = undefined;
    try initThreaded(&h);
    defer h.deinit();
    _ = try h.eval(
        \\frame .f -width 40 -height 40 -background #000000; pack .f; update
        \\ztk::animate .f -background #ff0000 -duration 250 -easing linear; update
    );
    const before = h.app.render.drawn.load(.monotonic);
    // The frames of the render thread reach the end color with no frame of the UI thread.
    try t.expectEqual(@as(u24, 0xff0000), pixelBecomes(&h, ".f", 0xff0000));
    try t.expect(h.app.render.drawn.load(.monotonic) - before >= 5);
}

test "fluid: the knob of a switch moves while the script is busy" {
    var h: Harness = undefined;
    try initThreaded(&h);
    defer h.deinit();
    _ = try h.eval(
        \\checkbutton .c -text Check; ztk::class .c add switch; pack .c; update
        \\.c select; update
    );
    try t.expect(drawsWhileBusy(&h, 5) >= 5);
}

/// The knob quad of the last frame. The render thread moves the quads of
/// that frame before each draw, so the read waits until no draw runs, as
/// `pixel` does.
fn knobQuad(h: *Harness) ?scene.Quad {
    const r = h.app.render;
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    while (r.held_drawing or r.drawing != null) r.cond.waitUncancelable(r.io, &r.mutex);
    const f = r.last orelse return null;
    if (f.drags.items.len < 2) return null;
    return f.scene.quads.items[f.drags.items[1].first];
}

/// Keeps the UI thread busy until the x of the knob is not `old`, or the limit passed.
fn knobMovesFrom(h: *Harness, old: f32) f32 {
    const t0 = host.nowUs();
    var x = (knobQuad(h) orelse return old).rect[0];
    while (x == old and host.nowUs() - t0 < limit_us) : (x = (knobQuad(h) orelse return old).rect[0]) host.sleepUs(5_000);
    return x;
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
    const moved = knobMovesFrom(&h, start);
    try t.expectApproxEqAbs(start + 60, moved, 0.01);
    // The value changes only when the UI thread runs.
    try t.expectEqualStrings("20", try h.eval(".s get"));
    // A move past the end stops at the end of the track.
    h.head.pointerMove(h.win, x + 1000, y);
    const end = knobMovesFrom(&h, moved);
    try t.expect(end > moved and end < start + 200);
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
