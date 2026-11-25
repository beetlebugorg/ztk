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

    // progress-indeterminate: an indeterminate progress bar runs `start` beside 1 000 widgets,
    // with transitions on. The render thread moves the bar, and the UI thread runs the step timer.
    // combobox-open: the list of a combobox beside 1 000 widgets opens, one open for each frame.
    {
        var pw: World = undefined;
        try pw.it.init(gpa);
        pw.head = try ztk.headless.Headless.init(gpa);
        pw.app = try ztk.App.init(gpa, &pw.it, .{ .platform = pw.head.platform(), .io = io, .animations = true });
        defer pw.deinit();
        pw.head.skip_draw = true;
        pw.eval(thousand);
        pw.eval("ttk::progressbar .pi -mode indeterminate -length 300; grid .pi -row 101 -column 0 -columnspan 20; update; .pi start");
        const runs = 200;
        for (buf[0..runs]) |*slot| {
            pw.head.advance(16);
            const t0 = nowNs();
            pw.eval("update");
            slot.* = nowNs() - t0;
        }
        pw.eval(".pi stop; destroy .pi; update");
        report("progress-indeterminate", buf[0..runs]);
        pw.eval("set v {}; for {set i 0} {$i < 40} {incr i} {lappend v \"Item $i\"}; ttk::combobox .cbx -values $v; grid .cbx -row 101 -column 0 -columnspan 20; focus .cbx; update");
        for (buf[0..runs]) |*slot| {
            pw.head.advance(16);
            const t0 = nowNs();
            pw.eval("event generate .cbx <Key-Down>; update");
            slot.* = nowNs() - t0;
            pw.eval("event generate .cbx <Key-Escape>");
            pw.head.advance(400);
            pw.eval("update");
        }
        report("combobox-open", buf[0..runs]);
    }

    // scroll-wheel: fine wheel steps (a touchpad) scroll an entry and its scrollbar beside 1 000 widgets,
    // one step for each frame, on an App with transitions on, so the view eases and glides.
    {
        var sw: World = undefined;
        try sw.it.init(gpa);
        sw.head = try ztk.headless.Headless.init(gpa);
        sw.app = try ztk.App.init(gpa, &sw.it, .{ .platform = sw.head.platform(), .io = io, .animations = true });
        defer sw.deinit();
        sw.head.skip_draw = true;
        sw.eval(thousand);
        sw.eval("entry .we -width 30 -xscrollcommand {.ws set}; scrollbar .ws -orient horizontal -command {.we xview}; .we insert 0 [string repeat {scroll the long text } 200]; .we icursor 0; grid .we -row 101 -column 0 -columnspan 20; grid .ws -row 102 -column 0 -columnspan 20 -sticky ew; update");
        const we = sw.app.find(".we").?;
        const win = sw.app.window.?;
        sw.head.pointerMove(win, @floatFromInt(we.geom.x + 20), @floatFromInt(we.geom.y + 5));
        const runs = 200;
        for (buf[0..runs], 0..) |*slot, i| {
            sw.head.advance(16);
            sw.head.pointerScroll(win, if ((i / 50) % 2 == 0) 0.3 else -0.3, 0);
            const t0 = nowNs();
            sw.eval("update");
            slot.* = nowNs() - t0;
        }
        report("scroll-wheel", buf[0..runs]);
    }

    // canvas-10000-scroll: a canvas with 10 000 items (a grid of 5 000 cells, each a rectangle
    // and a text) scrolls by fine wheel steps, one step for each frame, with transitions on.
    // canvas-drag: the pointer drags one item of the same canvas, one motion for each frame.
    {
        var cv: World = undefined;
        try cv.it.init(gpa);
        cv.head = try ztk.headless.Headless.init(gpa);
        cv.app = try ztk.App.init(gpa, &cv.it, .{ .platform = cv.head.platform(), .io = io, .animations = true });
        defer cv.deinit();
        cv.head.skip_draw = true;
        cv.eval(
            \\canvas .c -width 800 -height 600 -scrollregion {0 0 5000 2400} -highlightthickness 0
            \\pack .c
            \\for {set r 0} {$r < 100} {incr r} {
            \\  for {set k 0} {$k < 50} {incr k} {
            \\    set x [expr {$k * 100}]; set y [expr {$r * 24}]
            \\    .c create rectangle $x $y [expr {$x + 100}] [expr {$y + 24}] -fill #ffffff -outline #d0d0d0
            \\    .c create text [expr {$x + 6}] [expr {$y + 12}] -text "R$r C$k" -anchor w
            \\  }
            \\}
            \\.c create oval 40 40 80 80 -fill #2563eb -tags drag
            \\.c bind drag <Button-1> {set ::px %x; set ::py %y}
            \\.c bind drag <B1-Motion> {.c move current [expr {%x - $::px}] [expr {%y - $::py}]; set ::px %x; set ::py %y}
            \\update
        );
        const win = cv.app.window.?;
        cv.head.pointerMove(win, 400, 300);
        cv.eval("update");
        const runs = 200;
        for (buf[0..runs], 0..) |*slot, i| {
            cv.head.advance(16);
            cv.head.pointerScroll(win, 0, if ((i / 50) % 2 == 0) 0.4 else -0.4);
            const t0 = nowNs();
            cv.eval("update");
            slot.* = nowNs() - t0;
        }
        report("canvas-10000-scroll", buf[0..runs]);
        cv.eval(".c xview moveto 0; .c yview moveto 0; update");
        cv.head.advance(500);
        cv.eval("update");
        cv.head.pointerMove(win, 60, 60);
        cv.head.pointerButton(win, 1, true);
        cv.eval("update");
        for (buf[0..runs], 0..) |*slot, i| {
            cv.head.advance(16);
            cv.head.pointerMove(win, 60 + @as(f32, @floatFromInt(i % 300)), 60 + @as(f32, @floatFromInt(i % 100)));
            const t0 = nowNs();
            cv.eval("update");
            slot.* = nowNs() - t0;
        }
        cv.head.pointerButton(win, 1, false);
        report("canvas-drag", buf[0..runs]);
    }

    // sheet-10000-scroll: examples/spreadsheet.tcl with 10 000 rows of numbers and a formula in
    // each row scrolls by fine wheel steps, one step for each frame, with transitions on. The
    // grid makes the items of a new block of rows every 16 rows.
    {
        var sh: World = undefined;
        try sh.it.init(gpa);
        sh.head = try ztk.headless.Headless.init(gpa);
        sh.app = try ztk.App.init(gpa, &sh.it, .{ .platform = sh.head.platform(), .io = io, .animations = true, .style_root = "examples" });
        defer sh.deinit();
        sh.head.skip_draw = true;
        const script = try std.Io.Dir.cwd().readFileAlloc(io, "examples/spreadsheet.tcl", gpa, .limited(1 << 20));
        defer gpa.free(script);
        sh.eval(script);
        sh.eval(
            \\for {set r 13} {$r < 10000} {incr r} {
            \\  set n [expr {$r + 1}]
            \\  foreach c {0 1 2 3 4} { ss::put [ss::name $r $c] [expr {($r * 7 + $c * 13) % 500}] 0 }
            \\  ss::put F$n "=sum(B$n:E$n)" 0
            \\}
            \\ss::recalc [array names ss::raw]
            \\ss::render 1
            \\update
        );
        const win = sh.app.window.?;
        sh.head.pointerMove(win, 300, 250);
        sh.eval("update");
        const runs = 200;
        for (buf[0..runs], 0..) |*slot, i| {
            sh.head.advance(16);
            sh.head.pointerScroll(win, 0, if ((i / 100) % 2 == 0) 0.6 else -0.6);
            const t0 = nowNs();
            sh.eval("update");
            slot.* = nowNs() - t0;
        }
        report("sheet-10000-scroll", buf[0..runs]);
    }

    // vector-10000-pan: examples/vector.tcl with 10 000 more shapes, rectangles and circles; a
    // drag with Space held pans all of them, one motion for each frame. vector-10000-drag: the pointer drags one
    // selected shape of the same drawing, one motion for each frame.
    {
        var vt: World = undefined;
        try vt.it.init(gpa);
        vt.head = try ztk.headless.Headless.init(gpa);
        vt.app = try ztk.App.init(gpa, &vt.it, .{ .platform = vt.head.platform(), .io = io, .animations = true, .style_root = "examples" });
        defer vt.deinit();
        vt.head.skip_draw = true;
        const script = try std.Io.Dir.cwd().readFileAlloc(io, "examples/vector.tcl", gpa, .limited(1 << 20));
        defer gpa.free(script);
        vt.eval(script);
        vt.eval(
            \\for {set i 0} {$i < 10000} {incr i} {
            \\  set x [expr {($i % 100) * 6}]; set y [expr {($i / 100) * 4}]
            \\  if {$i % 2} { vec::add rect [list $x $y [expr {$x + 5}] [expr {$y + 3}]] } else { vec::add ellipse [list $x $y [expr {$x + 4}] [expr {$y + 4}]] }
            \\}
            \\set id [vec::add rect {300 200 360 250} -fill #ef4444]
            \\vec::select [list $id]
            \\update
        );
        const win = vt.app.window.?;
        vt.eval("focus .c; set vec::space 1; update");
        const c = vt.app.find(".c").?;
        const cx: f32 = @floatFromInt(c.geom.x);
        const cy: f32 = @floatFromInt(c.geom.y);
        vt.head.pointerMove(win, cx + 100, cy + 100);
        vt.head.pointerButton(win, 1, true);
        vt.eval("update");
        const runs = 200;
        for (buf[0..runs], 0..) |*slot, i| {
            vt.head.advance(16);
            const d: f32 = @floatFromInt(i % 50);
            vt.head.pointerMove(win, cx + 100 + d, cy + 100 + d / 2);
            const t0 = nowNs();
            vt.eval("update");
            slot.* = nowNs() - t0;
        }
        vt.head.pointerButton(win, 1, false);
        report("vector-10000-pan", buf[0..runs]);
        vt.eval("set vec::space 0; .c scan mark 0 0; .c scan dragto [expr {round([.c canvasx 0])}] [expr {round([.c canvasy 0])}] 1; update");
        vt.eval("if {[.c canvasx 0] != 0 || [.c canvasy 0] != 0} { error {the view did not go back} }");
        // The center of the red rectangle: page (330, 225) at zoom 0.8 and pan (36, 30).
        const px = cx + 36 + 330 * 0.8;
        const py = cy + 30 + 225 * 0.8;
        vt.head.pointerMove(win, px, py);
        vt.head.pointerButton(win, 1, true);
        vt.eval("update");
        for (buf[0..runs], 0..) |*slot, i| {
            vt.head.advance(16);
            const d: f32 = @floatFromInt(i % 80);
            vt.head.pointerMove(win, px + d, py + d / 2);
            const t0 = nowNs();
            vt.eval("update");
            slot.* = nowNs() - t0;
        }
        vt.head.pointerButton(win, 1, false);
        report("vector-10000-drag", buf[0..runs]);
        vt.eval("if {[lindex [dict get $vec::S($id) pts] 0] == 300} { error {the drag did not move the shape} }");
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

    // ttk-hover-1000: as anim-hover-1000, with 1 000 ttk::label and ttk::button widgets and a
    // map of ttk::style that gives the hover color.
    {
        var aw: World = undefined;
        try aw.it.init(gpa);
        aw.head = try ztk.headless.Headless.init(gpa);
        aw.app = try ztk.App.init(gpa, &aw.it, .{ .platform = aw.head.platform(), .io = io, .animations = true });
        defer aw.deinit();
        aw.head.skip_draw = true;
        aw.eval("ztk::style add {Button { transition: background-color 200ms ease }}; ttk::style map TButton -background {active #ff0000}");
        aw.eval("for {set i 0} {$i < 1000} {incr i} {" ++
            " if {$i % 2} { ttk::label .w$i -text w$i -width 4 } else { ttk::button .w$i -text b$i -width 4 };" ++
            " grid .w$i -row [expr {$i / 40}] -column [expr {$i % 40}] }; update");
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
        report("ttk-hover-1000", buf[0..runs]);
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
