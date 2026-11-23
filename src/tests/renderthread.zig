//! Tests of the render thread: the hand-over of frames, the replaced
//! frames, the atlas patches, the resize, the shutdown, and equal pixels
//! in both modes. A test target stands in for the display.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const scene_mod = @import("../scene.zig");
const thread = @import("../render/thread.zig");
const atlas_mod = @import("../text/atlas.zig");
const font_mod = @import("../text/font.zig");
const Harness = @import("../testing.zig").Harness;
const t = std.testing;

const Frame = scene_mod.Frame;

/// A target that sleeps, blocks on a flag, and records what it saw.
const Probe = struct {
    sleep_ms: i64 = 0,
    /// While true, `draw` waits.
    block: std.atomic.Value(bool) = .init(false),
    /// True after a draw started.
    entered: std.atomic.Value(bool) = .init(false),
    last_serial: std.atomic.Value(u64) = .init(0),
    last_width: std.atomic.Value(u32) = .init(0),
    atlas: atlas_mod.Atlas,
    order_ok: bool = true,

    fn init() Probe {
        return .{ .atlas = atlas_mod.Atlas.init(t.allocator) };
    }

    fn target(p: *Probe) thread.Target {
        return .{ .ctx = p, .draw = draw };
    }

    fn draw(ctx: *anyopaque, f: *const Frame) anyerror!void {
        const p: *Probe = @ptrCast(@alignCast(ctx));
        p.entered.store(true, .release);
        while (p.block.load(.acquire)) t.io.sleep(.fromMilliseconds(1), .awake) catch {};
        if (p.sleep_ms > 0) t.io.sleep(.fromMilliseconds(p.sleep_ms), .awake) catch {};
        for (f.patches.items) |patch| try p.atlas.applyPatch(patch);
        if (f.serial <= p.last_serial.load(.monotonic)) p.order_ok = false;
        p.last_serial.store(f.serial, .monotonic);
        p.last_width.store(f.scene.width, .monotonic);
    }
};

fn nowNs() i128 {
    return std.Io.Clock.awake.now(t.io).nanoseconds;
}

test "renderthread: submit does not block, and every frame is drawn or replaced" {
    var p = Probe.init();
    defer p.atlas.deinit();
    p.sleep_ms = 1;
    const r = try thread.RenderThread.init(t.allocator, t.io, .threaded, p.target());
    defer r.deinit();
    var worst: i128 = 0;
    // A submit that waits for the render thread would take about 1 ms (the draw time),
    // so a thread that the system preempts for a moment must not fail the test.
    // At most 5 submits may take more than 0.5 ms.
    var slow: u32 = 0;
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        r.back().scene.reset(10 + i % 7, 10);
        const t0 = nowNs();
        r.submit();
        const dt = nowNs() - t0;
        worst = @max(worst, dt);
        if (dt > 500_000) slow += 1;
    }
    r.flush();
    std.debug.print("renderthread: worst submit {d:.3} ms, drawn {d}, replaced {d}\n", .{ @as(f64, @floatFromInt(worst)) / 1e6, r.drawn.load(.monotonic), r.replaced.load(.monotonic) });
    try t.expect(slow <= 5);
    try t.expectEqual(@as(u64, 1000), r.drawn.load(.monotonic) + r.replaced.load(.monotonic));
    try t.expectEqual(@as(u64, 1000), p.last_serial.load(.monotonic));
    try t.expect(p.order_ok);
}

test "renderthread: a blocked draw does not stop the UI thread, and the newest frame draws" {
    var p = Probe.init();
    defer p.atlas.deinit();
    p.block.store(true, .release);
    const r = try thread.RenderThread.init(t.allocator, t.io, .threaded, p.target());
    defer r.deinit();
    // A failed check must not leave the draw blocked, or `deinit` would wait for ever.
    defer p.block.store(false, .release);
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        r.back().scene.reset(20 + i, 10);
        r.submit();
    }
    try t.expectEqual(@as(u64, 0), r.drawn.load(.monotonic));
    p.block.store(false, .release);
    r.flush();
    try t.expectEqual(@as(u64, 100), p.last_serial.load(.monotonic));
    try t.expectEqual(@as(u32, 119), p.last_width.load(.monotonic));
}

test "renderthread: a busy UI thread still sees the frame drawn" {
    var p = Probe.init();
    defer p.atlas.deinit();
    const r = try thread.RenderThread.init(t.allocator, t.io, .threaded, p.target());
    defer r.deinit();
    r.back().scene.reset(8, 8);
    r.submit();
    const t0 = nowNs();
    // The UI thread spins for 200 ms. The frame draws in that time.
    while (nowNs() - t0 < 200_000_000 and r.drawn.load(.monotonic) == 0) {}
    try t.expectEqual(@as(u64, 1), r.drawn.load(.monotonic));
    try t.expect(nowNs() - t0 < 190_000_000);
}

/// Waits until a flag is true. It fails after two seconds, so a broken test fails and does not hang.
fn waitFlag(flag: *const std.atomic.Value(bool)) !void {
    const t0 = nowNs();
    while (!flag.load(.acquire)) {
        if (nowNs() - t0 > 2_000_000_000) return error.Timeout;
        t.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
}

test "renderthread: the patches of replaced frames reach the render copy" {
    var fonts = try font_mod.Fonts.init(t.allocator);
    defer fonts.deinit();
    var ui_atlas = atlas_mod.Atlas.init(t.allocator);
    defer ui_atlas.deinit();
    var p = Probe.init();
    defer p.atlas.deinit();
    p.block.store(true, .release);
    const r = try thread.RenderThread.init(t.allocator, t.io, .threaded, p.target());
    defer r.deinit();
    defer p.block.store(false, .release);
    const font = try fonts.get(.{ .size = 16 }, 1);
    // Frame 1 starts and blocks. Frames 2 and 3 wait, and frame 3 replaces frame 2.
    for ([_][]const u8{ "abc", "defg", "hijk" }, 0..) |chars, n| {
        for (chars) |ch| _ = try ui_atlas.get(font, font.glyph(ch), 0);
        try ui_atlas.takePatches(t.allocator, &r.back().patches);
        r.back().scene.reset(10, 10);
        r.submit();
        // The thread must have taken frame 1 before the next submit.
        if (n == 0) try waitFlag(&p.entered);
    }
    p.block.store(false, .release);
    r.flush();
    try t.expect(r.replaced.load(.monotonic) >= 1);
    try t.expectEqual(ui_atlas.pixels.len, p.atlas.pixels.len);
    try t.expect(std.mem.eql(u8, ui_atlas.pixels, p.atlas.pixels));
}

const Unblock = struct {
    p: *Probe,
    fn run(u: *Unblock) void {
        t.io.sleep(.fromMilliseconds(40), .awake) catch {};
        u.p.block.store(false, .release);
    }
};

test "renderthread: no patch is lost when there is no memory to move them" {
    var fonts = try font_mod.Fonts.init(t.allocator);
    defer fonts.deinit();
    var ui_atlas = atlas_mod.Atlas.init(t.allocator);
    defer ui_atlas.deinit();
    var p = Probe.init();
    defer p.atlas.deinit();
    p.block.store(true, .release);
    var failing = std.testing.FailingAllocator.init(t.allocator, .{});
    const r = try thread.RenderThread.init(failing.allocator(), t.io, .threaded, p.target());
    defer r.deinit();
    defer p.block.store(false, .release);
    const font = try fonts.get(.{ .size = 16 }, 1);
    var u: Unblock = .{ .p = &p };
    var helper: ?std.Thread = null;
    defer if (helper) |h| h.join();
    for ([_][]const u8{ "abc", "defg", "hijk" }, 0..) |chars, n| {
        for (chars) |ch| _ = try ui_atlas.get(font, font.glyph(ch), 0);
        try ui_atlas.takePatches(failing.allocator(), &r.back().patches);
        r.back().scene.reset(10, 10);
        if (n == 2) {
            // The move of the patches of frame 2 into frame 3 needs memory, and it fails once.
            // The draw of frame 1 ends 40 ms later, and `submit` waits for that.
            failing.fail_index = failing.alloc_index;
            helper = try std.Thread.spawn(.{}, Unblock.run, .{&u});
        }
        r.submit();
        if (n == 0) try waitFlag(&p.entered);
    }
    r.flush();
    try t.expect(failing.has_induced_failure);
    try t.expectEqual(ui_atlas.pixels.len, p.atlas.pixels.len);
    try t.expect(std.mem.eql(u8, ui_atlas.pixels, p.atlas.pixels));
}

test "renderthread: a resize in three frames ends with the last size" {
    var p = Probe.init();
    defer p.atlas.deinit();
    p.sleep_ms = 5;
    const r = try thread.RenderThread.init(t.allocator, t.io, .threaded, p.target());
    defer r.deinit();
    for ([_]u32{ 100, 200, 300 }) |w| {
        r.back().scene.reset(w, 50);
        r.submit();
    }
    r.flush();
    try t.expectEqual(@as(u32, 300), p.last_width.load(.monotonic));
}

test "renderthread: deinit during a draw waits for it" {
    var p = Probe.init();
    defer p.atlas.deinit();
    p.sleep_ms = 50;
    const r = try thread.RenderThread.init(t.allocator, t.io, .threaded, p.target());
    r.back().scene.reset(8, 8);
    r.submit();
    // Give the thread time to start the draw.
    t.io.sleep(.fromMilliseconds(10), .awake) catch {};
    r.deinit();
    try t.expectEqual(@as(u64, 1), p.last_serial.load(.monotonic));
}

test "renderthread: inline mode draws in submit" {
    var p = Probe.init();
    defer p.atlas.deinit();
    const r = try thread.RenderThread.init(t.allocator, t.io, .inline_draw, p.target());
    defer r.deinit();
    r.back().scene.reset(33, 8);
    r.submit();
    try t.expectEqual(@as(u32, 33), p.last_width.load(.monotonic));
    try t.expectEqual(@as(u64, 1), r.drawn.load(.monotonic));
}

const script =
    "ztk::style add {.card { border: 2px solid #2563eb; border-radius: 8px; padding: 6px }}; " ++
    "label .l -text {Hello, world} -bg #fff7d6; ztk::class .l add card; button .b -text Save; entry .e; " ++
    "grid .l -padx 10 -pady 10; grid .b -pady 4; grid .e -padx 10 -pady 10; .e insert 0 text; update";

fn image(h: *Harness, a: std.mem.Allocator) ![]u8 {
    const im = h.head.image(h.win).?;
    return a.dupe(u8, im.pixels);
}

test "renderthread: threaded and inline modes give the same pixels" {
    var a: Harness = undefined;
    try a.initMode(.inline_draw);
    defer a.deinit();
    _ = try a.eval(script);
    const pa = try image(&a, t.allocator);
    defer t.allocator.free(pa);
    var b: Harness = undefined;
    try b.initMode(.threaded);
    defer b.deinit();
    _ = try b.eval(script);
    const pb = try image(&b, t.allocator);
    defer t.allocator.free(pb);
    try t.expect(std.mem.eql(u8, pa, pb));
    try t.expect(pa.len > 0);
}
