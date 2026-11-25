//! The benchmark of ztk. It runs on the headless backend with the font of
//! the repository, and prints the name of each case, the count of runs,
//! and the median and the 99th percentile in microseconds. The frame
//! cases skip the CPU draw, and `cpu-render-demo` measures it alone.
//! Run it with `zig build bench`.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const ztk = @import("ztk");

const gpa = std.heap.smp_allocator;

fn now() i64 {
    return ztk.loop.system_clock.now(null);
}

const World = struct {
    it: ztcl.Interp,
    head: *ztk.headless.Headless,
    app: *ztk.App,

    fn init(w: *World, io: std.Io) !void {
        try w.it.init(gpa);
        w.head = try ztk.headless.Headless.init(gpa);
        w.app = try ztk.App.init(gpa, &w.it, .{ .platform = w.head.platform(), .io = io, .animations = false });
    }

    fn deinit(w: *World) void {
        w.app.deinit();
        w.head.deinit();
        w.it.deinit();
    }

    fn eval(w: *World, text: []const u8) void {
        _ = w.it.eval(text) catch {
            std.debug.print("bench: script error: {s}\n", .{w.it.str(w.it.result) catch "?"});
            std.process.exit(1);
        };
    }
};

const thousand =
    "for {set i 0} {$i < 1000} {incr i} {" ++
    " if {$i % 2} { label .w$i -text w$i -width 4 } else { button .w$i -text b$i -width 4 };" ++
    " grid .w$i -row [expr {$i / 40}] -column [expr {$i % 40}] }; update";

fn report(name: []const u8, samples: []i64) void {
    std.mem.sort(i64, samples, {}, std.sort.asc(i64));
    const n = samples.len;
    const med = samples[n / 2];
    const p99 = samples[@min((n * 99) / 100, n - 1)];
    std.debug.print("{s:<18} runs {d:<6} median {d:>10.3} us  p99 {d:>10.3} us\n", .{ name, n, @as(f64, @floatFromInt(med)) / 1000.0, @as(f64, @floatFromInt(p99)) / 1000.0 });
}

/// Times in nanoseconds are kept in the samples so that the idle case has a fraction of a microsecond.
fn nowNs() i64 {
    return now() * 1000;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var buf: [400]i64 = undefined;

    // build-1000: the script makes 1 000 widgets and the first frame draws.
    {
        var s: [20]i64 = undefined;
        for (&s) |*slot| {
            var w: World = undefined;
            try w.init(io);
            w.head.skip_draw = true;
            const t0 = nowNs();
            w.eval(thousand);
            slot.* = nowNs() - t0;
            w.deinit();
        }
        report("build-1000", &s);
    }

    // pack-resize-1000: 1 000 packed labels in 25 rows, and one resize of `.` for each frame.
    {
        var pw: World = undefined;
        try pw.init(io);
        defer pw.deinit();
        pw.head.skip_draw = true;
        pw.eval("for {set r 0} {$r < 25} {incr r} { frame .r$r; pack .r$r -fill x -expand 1;" ++
            " for {set c 0} {$c < 40} {incr c} { label .r$r.l$c -text $c; pack .r$r.l$c -side left -fill both -expand 1 } }; update");
        const runs = 200;
        for (buf[0..runs], 0..) |*slot, i| {
            var cmd: [64]u8 = undefined;
            const text = try std.fmt.bufPrint(&cmd, "wm geometry . {d}x{d}; update", .{ 1200 + (i % 50) * 4, 700 + (i % 30) * 3 });
            const t0 = nowNs();
            pw.eval(text);
            slot.* = nowNs() - t0;
        }
        report("pack-resize-1000", buf[0..runs]);
    }

    var w: World = undefined;
    try w.init(io);
    defer w.deinit();
    w.head.skip_draw = true;
    w.eval(thousand);

    // frame-full-1000: a new sheet restyles all widgets, so the layout and the paint run too.
    {
        const runs = 40;
        for (buf[0..runs], 0..) |*slot, i| {
            var cmd: [160]u8 = undefined;
            const text = try std.fmt.bufPrint(&cmd, "ztk::style add {{:root {{ --bg: #{x:0>2}{x:0>2}{x:0>2}; --field-bg: #{x:0>2}8080; --fg: #101010 }}}}; update", .{ 0x40 + i, 0x50 + i, 0x60 + i, 0x70 + i });
            const t0 = nowNs();
            w.eval(text);
            slot.* = nowNs() - t0;
        }
        report("frame-full-1000", buf[0..runs]);
    }

    // frame-hover-1000: the pointer moves from one button to the next.
    {
        const runs = 200;
        const a = w.app.find(".w0").?;
        const b = w.app.find(".w2").?;
        w.eval("update");
        for (buf[0..runs], 0..) |*slot, i| {
            const target = if (i % 2 == 0) b else a;
            const t0 = nowNs();
            w.head.pointerMove(w.app.window.?, @floatFromInt(target.geom.x + 2), @floatFromInt(target.geom.y + 2));
            w.eval("update");
            slot.* = nowNs() - t0;
        }
        report("frame-hover-1000", buf[0..runs]);
    }

    // frame-text-1000: the text of one label changes with the same size.
    {
        const runs = 200;
        for (buf[0..runs], 0..) |*slot, i| {
            const t0 = nowNs();
            w.eval(if (i % 2 == 0) ".w1 configure -text aaaa; update" else ".w1 configure -text bbbb; update");
            slot.* = nowNs() - t0;
        }
        report("frame-text-1000", buf[0..runs]);
    }

    // anim-hover-1000 and anim-1000 run on their own App with transitions on and a manual clock.
    {
        var aw: World = undefined;
        try aw.it.init(gpa);
        aw.head = try ztk.headless.Headless.init(gpa);
        aw.app = try ztk.App.init(gpa, &aw.it, .{ .platform = aw.head.platform(), .io = io, .animations = true });
        defer aw.deinit();
        aw.head.skip_draw = true;
        aw.eval("ztk::style add {Button { transition: background-color 200ms ease } Button:hover { background-color: #ff0000 }}");
        aw.eval(thousand);
        // anim-hover-1000: the pointer moves to the next button, and the frames of the transition follow.
        const runs = 200;
        const a = aw.app.find(".w0").?;
        const b2 = aw.app.find(".w2").?;
        for (buf[0..runs], 0..) |*slot, i| {
            if (i % 10 == 0) {
                const tg = if ((i / 10) % 2 == 0) b2 else a;
                aw.head.pointerMove(aw.app.window.?, @floatFromInt(tg.geom.x + 2), @floatFromInt(tg.geom.y + 2));
            }
            aw.head.advance(16);
            const t0 = nowNs();
            aw.eval("update");
            slot.* = nowNs() - t0;
        }
        report("anim-hover-1000", buf[0..runs]);
        // anim-1000: 1 000 option animations of ztk::animate run at once.
        aw.eval("for {set i 0} {$i < 1000} {incr i} { ztk::animate .w$i -background #00ff00 -duration 5000 -easing linear }");
        for (buf[0..runs]) |*slot| {
            aw.head.advance(16);
            const t0 = nowNs();
            aw.eval("update");
            slot.* = nowNs() - t0;
        }
        report("anim-1000", buf[0..runs]);
        // anim-held-1000: the render thread draws the last frame again with 1 000 animations moved, with no UI work.
        if (aw.app.render.last) |f| {
            for (buf[0..runs], 0..) |*slot, i| {
                const t0 = nowNs();
                std.mem.doNotOptimizeAway(ztk.scene.applyAnims(f, f.time_us + @as(i64, @intCast(i)) * 1000));
                slot.* = nowNs() - t0;
            }
            report("anim-held-1000", buf[0..runs]);
        }
    }

    // check-toggle-1000: 1 000 checkbuttons, one toggles and its indicator moves for each frame.
    {
        var cw: World = undefined;
        try cw.it.init(gpa);
        cw.head = try ztk.headless.Headless.init(gpa);
        cw.app = try ztk.App.init(gpa, &cw.it, .{ .platform = cw.head.platform(), .io = io, .animations = true });
        defer cw.deinit();
        cw.head.skip_draw = true;
        cw.eval("for {set i 0} {$i < 1000} {incr i} { checkbutton .c$i -text c$i; grid .c$i -row [expr {$i / 25}] -column [expr {$i % 25}] }; update");
        const runs = 200;
        for (buf[0..runs], 0..) |*slot, i| {
            var cmd: [48]u8 = undefined;
            const text = try std.fmt.bufPrint(&cmd, ".c{d} toggle; update", .{(i / 10) % 1000});
            cw.head.advance(16);
            const t0 = nowNs();
            cw.eval(if (i % 10 == 0) text else "update");
            slot.* = nowNs() - t0;
        }
        report("check-toggle-1000", buf[0..runs]);
    }

    // toplevel-open: a new toplevel with 50 widgets, to its first frame.
    {
        const runs = 50;
        for (buf[0..runs], 0..) |*slot, i| {
            var cmd: [200]u8 = undefined;
            const text = try std.fmt.bufPrint(&cmd, "toplevel .t{d}; for {{set k 0}} {{$k < 50}} {{incr k}} {{ label .t{d}.l$k -text l$k; grid .t{d}.l$k -row [expr {{$k / 5}}] -column [expr {{$k % 5}}] }}; update", .{ i, i, i });
            const t0 = nowNs();
            w.eval(text);
            slot.* = nowNs() - t0;
            var del: [32]u8 = undefined;
            w.eval(try std.fmt.bufPrint(&del, "destroy .t{d}", .{i}));
        }
        report("toplevel-open", buf[0..runs]);
    }

    // scale-drag: the pointer drags the slider of a scale beside 1 000 widgets, one motion for each frame.
    {
        w.eval("scale .sd -orient horizontal -from 0 -to 1000 -length 400; grid .sd -row 100 -column 0 -columnspan 20; update");
        const sd = w.app.find(".sd").?;
        w.eval(".sd set 0; update");
        const r = try w.it.str(try w.it.eval(".sd coords"));
        var parts = std.mem.splitScalar(u8, r, ' ');
        const cx = try std.fmt.parseFloat(f32, parts.next().?) + @as(f32, @floatFromInt(sd.geom.x));
        const cy = try std.fmt.parseFloat(f32, parts.next().?) + @as(f32, @floatFromInt(sd.geom.y));
        const win = w.app.window.?;
        w.head.pointerMove(win, cx, cy);
        w.head.pointerButton(win, 1, true);
        w.eval("update");
        const runs = 200;
        for (buf[0..runs], 0..) |*slot, i| {
            w.head.pointerMove(win, cx + @as(f32, @floatFromInt(i % 300)), cy);
            const t0 = nowNs();
            w.eval("update");
            slot.* = nowNs() - t0;
        }
        w.head.pointerButton(win, 1, false);
        w.eval("update; destroy .sd; update");
        report("scale-drag", buf[0..runs]);
    }

    // idle-1000: App.frame with no dirty flag.
    {
        const runs = 400;
        const root = w.app.root.?;
        for (buf[0..runs]) |*slot| {
            const t0 = nowNs();
            var k: u32 = 0;
            while (k < 10000) : (k += 1) std.mem.doNotOptimizeAway(try w.app.frame(root));
            slot.* = @divTrunc(nowNs() - t0, 10000);
        }
        report("idle-1000", buf[0..runs]);
    }

    // type-entry: one key in an entry.
    {
        var e: World = undefined;
        try e.init(io);
        defer e.deinit();
        e.head.skip_draw = true;
        e.eval("entry .e; grid .e; focus .e; update");
        const runs = 200;
        for (buf[0..runs]) |*slot| {
            const t0 = nowNs();
            try e.head.typeText(e.app.window.?, "a");
            e.eval("update");
            slot.* = nowNs() - t0;
        }
        report("type-entry", buf[0..runs]);
    }

    // demo-start: from App.init to the end of the first frame of the smoke script.
    {
        const script = try std.Io.Dir.cwd().readFileAlloc(io, "tests/scripts/smoke.tcl", gpa, .limited(1 << 20));
        defer gpa.free(script);
        var s: [20]i64 = undefined;
        for (&s) |*slot| {
            const t0 = nowNs();
            var d: World = undefined;
            try d.init(io);
            d.eval(script);
            d.eval("update");
            slot.* = nowNs() - t0;
            d.deinit();
        }
        report("demo-start", &s);
    }

    // cpu-render-demo: the CPU renderer alone on the scene of the first 1000 widgets.
    {
        w.head.skip_draw = false;
        w.eval(".w1 configure -text cccc; update");
        const frame = w.app.render.lastFrame();
        const sc = &frame.scene;
        const img = try gpa.alloc(u8, @as(usize, sc.width) * sc.height * 4);
        defer gpa.free(img);
        var out: ztk.renderer.Image = .{ .width = sc.width, .height = sc.height, .pixels = img };
        var atlas = ztk.atlas.Atlas.init(gpa);
        defer atlas.deinit();
        for (frame.patches.items) |p| try atlas.applyPatch(p);
        const runs = 50;
        for (buf[0..runs]) |*slot| {
            const t0 = nowNs();
            ztk.cpu.render(sc, &atlas, &out);
            slot.* = nowNs() - t0;
        }
        report("cpu-render-demo", buf[0..runs]);
    }
}
