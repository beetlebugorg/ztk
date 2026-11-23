//! A randomized stress test of widget lifetime. A script runs random
//! operations from inside bindings, traces, timers, and `-command`
//! scripts: destroy, create, rename, bind, trace, `update`, `event
//! generate`, and focus. The seeds are fixed, so a failure repeats. After
//! each seed the test checks the invariants of the widget tree. The
//! testing allocator reports a leak or a double free.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Harness = @import("../testing.zig").Harness;
const Watchdog = @import("../testing.zig").Watchdog;
const widget = @import("../widget.zig");
const t = std.testing;

const script =
    \\set ::depth 0
    \\proc r {n} {
    \\    set ::seed [expr {($::seed * 1103515245 + 12345) & 0x7fffffff}]
    \\    expr {($::seed >> 8) % $n}
    \\}
    \\set ::paths {.a .b .c .a.x .a.y .b.x .a.x.p .a.x.q .b.x.r .e .l .bt .a.e .b.l}
    \\proc pick {} { lindex $::paths [r [llength $::paths]] }
    \\proc op {} {
    \\    if {[incr ::budget -1] < 0 || $::depth > 10} return
    \\    incr ::depth
    \\    catch step
    \\    incr ::depth -1
    \\}
    \\proc step {} {
    \\    set p [pick]
    \\    set v ::v[r 3]
    \\    set c [r 22]
    \\    switch $c {
    \\        0 - 1 { destroy $p }
    \\        2 { frame $p }
    \\        3 { label $p -textvariable $v }
    \\        4 { entry $p -textvariable $v }
    \\        5 { button $p -command op -textvariable $v }
    \\        6 { bind $p <Destroy> op }
    \\        7 { bind $p <<X>> op }
    \\        8 { bind $p <Configure> op }
    \\        9 { trace add variable $v write {op ;#} }
    \\        10 { foreach s [trace info variable $v] { if {[string match op* [lindex $s 1]]} { trace remove variable $v write [lindex $s 1] } } }
    \\        11 { update }
    \\        12 { event generate $p <<X>> }
    \\        13 { rename $p ::ren[r 4] }
    \\        14 { grid $p -row [r 3] -column [r 3] }
    \\        15 { focus $p }
    \\        16 { set $v [r 100] }
    \\        17 { after [r 2] op }
    \\        18 { $p configure -textvariable $v }
    \\        19 { $p invoke }
    \\        20 { $p insert 0 z }
    \\        21 { if {[r 20] == 0} { destroy . } else { update idletasks } }
    \\    }
    \\    incr ::hit($c)
    \\}
    \\proc round {} { for {set i 0} {$i < 12} {incr i} { op } }
;

/// Checks that the table, the tree, and the input state agree.
fn checkTree(h: *Harness) !void {
    const app = h.app;
    try t.expectEqual(@as(u32, 0), app.callback_depth);
    try t.expectEqual(@as(usize, 0), app.dead.len);
    var iter = app.widgets.iterator();
    while (iter.next()) |e| {
        const w = e.value_ptr.*;
        try t.expect(w.life == .alive);
        try t.expectEqualStrings(e.key_ptr.*, w.path);
        if (w.parent) |p| {
            try t.expect(p.life == .alive);
            try t.expect(app.widgets.get(p.path) == p);
            try t.expect(std.mem.indexOfScalar(*widget.Widget, p.children.items, w) != null);
        } else try t.expect(app.root == w);
        for (w.children.items) |c| {
            try t.expect(c.parent == w);
            try t.expect(app.widgets.get(c.path) == c);
        }
    }
    if (app.focus.current) |c| try t.expect(app.widgets.get(c.path) == c);
    if (app.dispatch.hover) |c| try t.expect(app.widgets.get(c.path) == c);
    if (app.dispatch.grab) |c| try t.expect(app.widgets.get(c.path) == c);
}

fn runSeed(seed: u32, hits: *[22]u64) !void {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.app.compact_threshold = 1 << 18;
    _ = try h.eval(script);
    var buf: [64]u8 = undefined;
    _ = try h.eval(try std.fmt.bufPrint(&buf, "set ::seed {d}", .{seed}));
    var rng = std.Random.DefaultPrng.init(seed);
    const rnd = rng.random();
    for (0..10) |_| {
        _ = try h.eval("set ::budget 40; round");
        if (h.app.root == null) break;
        // Real input goes through the queue of the backend.
        h.head.pointerMove(h.win, rnd.float(f32) * 200, rnd.float(f32) * 200);
        h.head.pointerButton(h.win, 1, true);
        try h.head.press(h.win, "a");
        h.head.pointerButton(h.win, 1, false);
        _ = try h.eval("set ::budget 40; update");
        if (h.app.root == null) break;
        try checkTree(&h);
        _ = h.app.maybeCompact();
        try checkTree(&h);
    }
    // Run what is left, with no budget for new work.
    _ = try h.eval("set ::budget 0; update");
    try checkTree(&h);
    for (hits, 0..) |*n, c| {
        var name: [32]u8 = undefined;
        const v = try h.it.getVarOpt(try std.fmt.bufPrint(&name, "::hit({d})", .{c}));
        if (v) |x| n.* += @intCast(try h.it.int(x));
    }
}

test "stress: random operations from inside callbacks keep the invariants" {
    var dog: Watchdog = undefined;
    try dog.start(240_000);
    defer dog.stop();
    var hits: [22]u64 = @splat(0);
    var seed: u32 = 1;
    while (seed <= 150) : (seed += 1) {
        runSeed(seed, &hits) catch |e| {
            std.debug.print("stress: seed {d} failed\n", .{seed});
            return e;
        };
    }
    // Each kind of operation ran and succeeded, so the seeds reach each path.
    var total: u64 = 0;
    for (hits) |n| {
        try t.expect(n > 0);
        total += n;
    }
    std.debug.print("stress: 150 seeds, {d} operations succeeded\n", .{total});
}
