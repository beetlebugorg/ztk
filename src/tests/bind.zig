//! Tests of event patterns, the binding table, `bind`, `bindtags`,
//! `event generate`, and the dispatch of backend events. The expected
//! values and messages are from `wish` 8.6.16.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const bind = @import("../bind.zig");
const dispatch = @import("../dispatch.zig");
const Harness = @import("../testing.zig").Harness;
const t = std.testing;

fn setup(h: *Harness) !void {
    try h.init();
    _ = try h.eval("frame .f -width 100 -height 100; label .b -text B; grid .f; grid .b; set log {}; update");
}

fn log(h: *Harness) ![]const u8 {
    return h.eval("set log");
}

test "bind-pattern: equal forms and modifiers" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const it = &h.it;
    const b1 = try bind.parsePattern(it, "<1>");
    const b2 = try bind.parsePattern(it, "<Button-1>");
    const b3 = try bind.parsePattern(it, "<ButtonPress-1>");
    try t.expectEqual(b1.type, b2.type);
    try t.expectEqual(b1.detail, b3.detail);
    const k1 = try bind.parsePattern(it, "a");
    const k2 = try bind.parsePattern(it, "<a>");
    const k3 = try bind.parsePattern(it, "<Key-a>");
    const k4 = try bind.parsePattern(it, "<KeyPress-a>");
    try t.expectEqual(k1.detail, k2.detail);
    try t.expectEqual(k3.detail, k4.detail);
    try t.expectEqual(k1.detail, k4.detail);
    const cs = try bind.parsePattern(it, "<Control-Shift-a>");
    try t.expect(cs.mods.control and cs.mods.shift);
    try t.expectEqual(@as(u8, 2), (try bind.parsePattern(it, "<Double-1>")).count);
    try t.expect((try bind.parsePattern(it, "<<Foo>>")).type == .virtual);
    try t.expectEqualStrings("bad event type or keysym \"Foo\"", try h.evalError("bind .f <Foo-1> x"));
    try t.expectEqualStrings("bad button number \"9\"", try h.evalError("bind .f <Button-9> x"));
    const seq = try bind.parsePattern(it, "<Control-x><Control-s>");
    try t.expectEqual(@as(usize, 1), seq.prefix.len);
    try t.expect(seq.prefix[0].mods.control and seq.mods.control);
    try t.expectEqual(@as(usize, 2), (try bind.parsePattern(it, "abc")).prefix.len);
    try t.expectEqualStrings("virtual events may not be composed", try h.evalError("bind .f <<A>><1> x"));
    try t.expectEqualStrings("virtual events may not be composed", try h.evalError("bind .f <1><<A>> x"));
    try t.expectEqualStrings("bad event type or keysym \"Foo\"", try h.evalError("bind .f <1><Foo> x"));
    try t.expectEqualStrings("missing \">\" in binding", try h.evalError("bind .f <1><2 x"));
    try t.expectEqualStrings("no event type or button # or keysym", try h.evalError("bind .f <> x"));
    try t.expectEqualStrings("extra characters after detail in binding", try h.evalError("bind .f <1-2> x"));
}

test "bind-pattern: formatPattern" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var buf: [64]u8 = undefined;
    const cases = [_][2][]const u8{
        .{ "<Button-1>", "<Button-1>" },
        .{ "<Key>", "<Key>" },
        .{ "<Control-Shift-Key-a>", "<Control-Shift-Key-a>" },
        .{ "a", "a" },
        .{ "<Key-space>", "<Key-space>" },
        .{ "<Double-1>", "<Double-Button-1>" },
        .{ "<B1-Motion>", "<B1-Motion>" },
        .{ "<<Foo>>", "<<Foo>>" },
    };
    for (cases) |c| try t.expectEqualStrings(c[1], bind.formatPattern(try bind.parsePattern(&h.it, c[0]), &buf));
}

test "bind-subst: the fields of a press" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    const w = h.app.find(".f").?;
    var ev: bind.WidgetEvent = .{ .type = .button_press, .widget = w, .x = 5, .y = 6, .button = 2 };
    const out = try bind.substitute(t.allocator, "%x,%y,%b,%W,%T,%%", &ev);
    defer t.allocator.free(out);
    try t.expectEqualStrings("5,6,2,.f,4,%", out);
    const out2 = try bind.substitute(t.allocator, "%k %K %w %d %Z", &ev);
    defer t.allocator.free(out2);
    try t.expectEqualStrings("?? ?? ?? ?? Z", out2);
    // A path with a space is quoted as a list element.
    var ev2: bind.WidgetEvent = .{ .type = .virtual, .widget = w, .data = "a b" };
    const out3 = try bind.substitute(t.allocator, "%d", &ev2);
    defer t.allocator.free(out3);
    try t.expectEqualStrings("{a b}", out3);
}

test "bind: the tags run in order, and break stops them" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    _ = try h.eval("bind .b <1> {lappend log w}; bind Label <1> {lappend log c}; bind . <1> {lappend log t}; bind all <1> {lappend log a}");
    _ = try h.eval("event generate .b <1>");
    try t.expectEqualStrings("w c t a", try log(&h));
    _ = try h.eval("set log {}; bind .b <1> {lappend log w; break}; event generate .b <1>");
    try t.expectEqualStrings("w", try log(&h));
    _ = try h.eval("set log {}; bind .b <1> {lappend log w; continue}; event generate .b <1>");
    try t.expectEqualStrings("w c t a", try log(&h));
}

test "bind: append, delete, and query" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    _ = try h.eval("bind .b <1> {lappend log w}; bind .b <1> {+lappend log w2}; event generate .b <1>");
    try t.expectEqualStrings("w w2", try log(&h));
    try t.expectEqualStrings("lappend log w\nlappend log w2", try h.eval("bind .b <1>"));
    _ = try h.eval("bind .b <1> {}");
    try t.expectEqualStrings("", try h.eval("bind .b"));
    _ = try h.eval("bind .b <Button-1> x");
    try t.expectEqualStrings("x", try h.eval("bind .b <ButtonPress-1>"));
    _ = try h.eval("bind .f <Button-1> x1; bind .f <Key-b> x2; bind .f <Control-Shift-Key-a> x3; bind .f <Key> x4; bind .f a x5");
    try t.expectEqualStrings("a <Key> <Control-Shift-Key-a> b <Button-1>", try h.eval("bind .f"));
    try t.expectEqualStrings("wrong # args: should be \"bind window ?pattern? ?command?\"", try h.evalError("bind"));
}

test "bind: the most specific pattern wins" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    _ = try h.eval("bind .f <Key> {lappend log any}; bind .f <Key-a> {lappend log a}; bind .f <Control-Key-a> {lappend log ca}");
    _ = try h.eval("event generate .f <Key-a>; event generate .f <Control-Key-a>; event generate .f <Key-b>");
    try t.expectEqualStrings("a ca any", try log(&h));
}

test "bind: double click" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    _ = try h.eval("bind .f <1> {lappend log S}; bind .f <Double-1> {lappend log D}");
    _ = try h.eval("event generate .f <1>; event generate .f <1>");
    try t.expectEqualStrings("S D", try log(&h));
}

test "bind: virtual events and bindtags" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    _ = try h.eval("bind .f <<Foo>> {lappend log v%d}; event generate .f <<Foo>> -data hello");
    try t.expectEqualStrings("vhello", try log(&h));
    try t.expectEqualStrings(".b Label . all", try h.eval("bindtags .b"));
    _ = try h.eval("bindtags .b {.b all}");
    try t.expectEqualStrings(".b all", try h.eval("bindtags .b"));
    _ = try h.eval("bindtags .b {}");
    try t.expectEqualStrings(".b Label . all", try h.eval("bindtags .b"));
    try t.expectEqualStrings(". Ztk all", try h.eval("bindtags ."));
    try t.expectEqualStrings("bad window path name \".zz\"", try h.evalError("event generate .zz <1>"));
    try t.expectEqualStrings("bad window path name \".zz\"", try h.evalError("bindtags .zz"));
    try t.expectEqualStrings("event generate option \"-warp\" is not supported in this stage", try h.evalError("event generate .f <1> -warp 1"));
    try t.expectEqualStrings("bad option \"-bogus\": must be -when, -above, -borderwidth, -button, -count, -data, -delta, -detail, -focus, -height, -keycode, -keysym, -mode, -override, -place, -root, -rootx, -rooty, -sendevent, -serial, -state, -subwindow, -time, -warp, -width, -window, -x, or -y", try h.evalError("event generate .f <1> -bogus 1"));
    try t.expectEqualStrings("value for \"-x\" missing", try h.evalError("event generate .f <1> -x"));
    try t.expectEqualStrings("wrong # args: should be \"event generate window event ?-option value ...?\"", try h.evalError("event generate .f"));
    try t.expectEqualStrings("bad -when value \"later\": must be now, head, mark, or tail", try h.evalError("event generate .f <Motion> -when later"));
    try t.expectEqualStrings("", try h.eval("event add <<X>> <1>"));
    try t.expectEqualStrings("<Button-1>", try h.eval("event info <<X>>"));
    _ = try h.eval("event delete <<X>> <1>");
    try t.expectEqualStrings("", try h.eval("event info <<X>>"));
}

test "dispatch: pointer movement runs Enter and Leave" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    const f = h.app.find(".f").?;
    const b = h.app.find(".b").?;
    _ = try h.eval("bind .f <Enter> {lappend log E%x,%y}; bind .f <Leave> {lappend log L}; bind .b <Enter> {lappend log BE}");
    h.head.pointerMove(h.win, @floatFromInt(f.geom.x + 7), @floatFromInt(f.geom.y + 9));
    try h.update();
    try t.expectEqualStrings("E7,9", try log(&h));
    try t.expect(f.state.hover);
    h.head.pointerMove(h.win, @floatFromInt(b.geom.x + 1), @floatFromInt(b.geom.y + 1));
    try h.update();
    try t.expectEqualStrings("E7,9 L BE", try log(&h));
    try t.expect(!f.state.hover);
    try t.expect(b.state.hover);
}

test "dispatch: a press holds the pointer until the release" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    const f = h.app.find(".f").?;
    const b = h.app.find(".b").?;
    _ = try h.eval("bind .f <Motion> {lappend log FM}; bind .f <ButtonRelease-1> {lappend log FR}; bind .b <Enter> {lappend log BE}; bind .b <Motion> {lappend log BM}");
    h.head.pointerMove(h.win, @floatFromInt(f.geom.x + 5), @floatFromInt(f.geom.y + 5));
    h.head.pointerButton(h.win, 1, true);
    try h.update();
    try t.expect(f.state.pressed);
    try t.expect(f.state.hover);
    h.head.pointerMove(h.win, @floatFromInt(b.geom.x + 1), @floatFromInt(b.geom.y + 1));
    try h.update();
    try t.expect(!f.state.hover);
    h.head.pointerButton(h.win, 1, false);
    try h.update();
    try t.expect(!f.state.pressed);
    try t.expectEqualStrings("FM FM FR BE", try log(&h));
}

test "dispatch: errors, deleted widgets, and Destroy" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    _ = try h.eval("proc bgerror {m} {lappend ::log E:$m}");
    _ = try h.eval("bind .f <1> {error boom}; event generate .f <1>");
    try t.expectEqualStrings("E:boom", try log(&h));
    _ = try h.eval("set log {}; bind .f <2> {destroy .f; lappend log first}; bind Frame <2> {lappend log later}; event generate .f <2>");
    try t.expectEqualStrings("first", try log(&h));
    try t.expectEqualStrings("0", try h.eval("winfo exists .f"));
    _ = try h.eval("set log {}; frame .g; bind .g <Destroy> {lappend log gone}; destroy .g");
    try t.expectEqualStrings("gone", try log(&h));
}

test "dispatch: a resize runs Configure with the size" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    _ = try h.eval("bind . <Configure> {lappend log %w,%h}");
    h.head.resize(h.win, .{ .w = 321, .h = 222 });
    try h.update();
    try t.expect(std.mem.endsWith(u8, try log(&h), "321,222"));
}

test "dispatch: motion events collapse and no key is lost" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    const f = h.app.find(".f").?;
    _ = try h.eval("bind .f <Motion> {lappend log %x}");
    const x0: f32 = @floatFromInt(f.geom.x);
    const y0: f32 = @floatFromInt(f.geom.y + 3);
    var i: u32 = 1;
    while (i <= 5) : (i += 1) h.head.pointerMove(h.win, x0 + @as(f32, @floatFromInt(i)), y0);
    try h.update();
    try t.expectEqualStrings("5", try log(&h));
    _ = try h.eval("set log {}");
    h.head.pointerMove(h.win, x0 + 1, y0);
    h.head.pointerMove(h.win, x0 + 2, y0);
    h.head.pointerMove(h.win, x0 + 3, y0);
    h.head.pointerButton(h.win, 1, true);
    h.head.pointerMove(h.win, x0 + 4, y0);
    h.head.pointerMove(h.win, x0 + 5, y0);
    _ = try h.eval("bind .f <1> {lappend log P%x}");
    try h.update();
    try t.expectEqualStrings("3 P3 5", try log(&h));
    _ = try h.eval("set log {}; set n 0; bind . <Key> {incr n}; bind . <Key> {+lappend log %K}");
    i = 0;
    while (i < 200) : (i += 1) try h.head.press(h.win, "a");
    try h.update();
    try t.expectEqualStrings("200", try h.eval("set n"));
}

test "bind-speed: 100000 motion events" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    const f = h.app.find(".f").?;
    _ = try h.eval("bind .f <Motion> {incr n}; set n 0");
    h.head.pointerMove(h.win, @floatFromInt(f.geom.x + 1), @floatFromInt(f.geom.y + 1));
    try h.update();
    _ = try h.eval("set n 0");
    const t0 = std.Io.Clock.awake.now(t.io);
    var i: u32 = 0;
    while (i < 100000) : (i += 1) {
        dispatch.handle(h.app, .{ .motion = .{ .window = h.win, .x = @floatFromInt(f.geom.x + @as(i32, @intCast(i % 50))), .y = @floatFromInt(f.geom.y + 2), .mods = .{}, .time_ms = 0 } });
    }
    const ns = t0.untilNow(t.io, .awake).toNanoseconds();
    const ms = @as(f64, @floatFromInt(ns)) / 1e6;
    std.debug.print("bind-speed: {d:.1} ms for 100000 motion events ({s})\n", .{ ms, @tagName(@import("builtin").mode) });
    try t.expectEqualStrings("100000", try h.eval("set n"));
    if (@import("builtin").mode == .fast) try t.expect(ms < 150.0);
}

const Counting = struct {
    inner: std.mem.Allocator,
    allocs: usize = 0,

    fn allocator(c: *Counting) std.mem.Allocator {
        return .{ .ptr = c, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        c.allocs += 1;
        return c.inner.rawAlloc(len, a, ra);
    }
    fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        c.allocs += 1;
        return c.inner.rawResize(m, a, n, ra);
    }
    fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        c.allocs += 1;
        return c.inner.rawRemap(m, a, n, ra);
    }
    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        c.inner.rawFree(m, a, ra);
    }
};

test "dispatch: a motion event with no binding allocates nothing" {
    const Headless = @import("../platform/headless.zig").Headless;
    const App = @import("../app.zig").App;
    var counting: Counting = .{ .inner = t.allocator };
    const gpa = counting.allocator();
    var it: ztcl.Interp = undefined;
    try it.init(t.allocator);
    defer it.deinit();
    const head = try Headless.init(t.allocator);
    defer head.deinit();
    const app = try App.init(gpa, &it, .{ .platform = head.platform(), .io = t.io });
    defer app.deinit();
    _ = try it.eval("frame .f -width 100 -height 100; grid .f; update");
    const f = app.find(".f").?;
    // The first motion changes the hover. The second has the same target.
    const win = app.window.?;
    dispatch.handle(app, .{ .motion = .{ .window = win, .x = @floatFromInt(f.geom.x + 1), .y = @floatFromInt(f.geom.y + 1), .mods = .{}, .time_ms = 0 } });
    const before = counting.allocs;
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        dispatch.handle(app, .{ .motion = .{ .window = win, .x = @floatFromInt(f.geom.x + 2 + @as(i32, @intCast(i % 10))), .y = @floatFromInt(f.geom.y + 2), .mods = .{}, .time_ms = 0 } });
    }
    try t.expectEqual(before, counting.allocs);
}

test "bind: a sequence of events matches the history, as in wish" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval(
        \\frame .f -width 50 -height 50; pack .f
        \\label .g -text a; pack .g
        \\update
        \\set log {}
        \\proc ev {args} { event generate .f {*}$args }
        \\proc show {} { global log; set r $log; set log {}; return $r }
        \\bind .f <Control-x><Control-s> {lappend log xs}
        \\bind .f <Control-s> {lappend log s}
        \\bind .f abc {lappend log abc}
        \\bind .f ab {lappend log ab}
        \\bind .f <1><2> {lappend log b12}
        \\bind .f a<Return> {lappend log aret}
    );
    // Each expected value is the output of wish 8.6.16.
    const cases = [_][2][]const u8{
        .{ "lsort [bind .f]", "<Button-1><Button-2> <Control-Key-s> <Control-Key-x><Control-Key-s> a<Key-Return> ab abc" },
        .{ "bind .f <Control-x><Control-s>", "lappend log xs" },
        .{ "bind .f abc", "lappend log abc" },
        // The longer sequence runs, and the binding of the last event does not.
        .{ "ev <Control-x>; ev <Control-s>; show", "xs" },
        .{ "ev <Control-s>; show", "s" },
        // A key release, the press of a modifier key, and an event of another type are skipped.
        .{ "ev <Control-x>; ev <KeyRelease-x> -state 4; ev <Key-Control_L>; ev <Control-s>; show", "xs" },
        .{ "ev <Control-x>; ev <Motion>; ev <Enter>; ev <Control-s>; show", "xs" },
        .{ "ev <Control-x>; event generate .f <<Foo>>; ev <Control-s>; show", "xs" },
        // Another key, a button, and an event of another widget end the sequence.
        .{ "ev <Control-x>; ev <Key-q>; ev <Control-s>; show", "s" },
        .{ "ev <Control-x>; ev <1>; ev <Control-s>; show", "s" },
        .{ "ev <Control-x>; event generate .g <Key-z>; ev <Control-s>; show", "s" },
        .{ "ev <Control-x>; event generate .g <Motion>; ev <Control-s>; show", "s" },
        .{ "ev <Control-x>; event generate .g <Configure>; ev <Control-s>; show", "s" },
        .{ "ev x; ev <Control-s>; show", "s" },
        .{ "ev a; ev b; ev c; show", "ab abc" },
        .{ "ev a; ev b; ev b; ev c; show", "ab" },
        // A sequence does not match when the event before it fits its first pattern.
        .{ "ev a; ev a; ev b; ev c; show", "" },
        .{ "ev q; ev a; ev a; ev b; show", "" },
        .{ "ev <1>; ev <1>; ev <2>; show", "" },
        .{ "ev a; ev b; ev a; ev b; show", "ab ab" },
        .{ "ev b; ev b; ev a; ev b; ev c; show", "ab abc" },
        .{ "ev <1>; ev <ButtonRelease-1>; ev <2>; show", "b12" },
        .{ "ev <1>; ev a; ev <2>; show", "" },
        .{ "ev a; ev <Return>; show", "aret" },
        // A sequence is more specific than a pattern with more modifiers.
        .{ "bind .f <Control-b> {lappend log ctlb}; ev a; ev b -state 4; show", "ab" },
        .{ "bind .f <Control-x><Control-s> {}; lsort [bind .f]", "<Button-1><Button-2> <Control-Key-b> <Control-Key-s> a<Key-Return> ab abc" },
        .{ "ev <Control-x>; ev <Control-s>; show", "s" },
        // `event add` keeps a sequence, and the sequence runs no binding.
        .{ "event add <<Save>> <Control-x><Control-s>; event info <<Save>>", "<Control-Key-x><Control-Key-s>" },
        .{ "bind .f <Control-s> {}; bind .f <<Save>> {lappend log save}; ev <Control-x>; ev <Control-s>; show", "" },
    };
    for (cases) |c| {
        t.expectEqualStrings(c[1], try h.eval(c[0])) catch |e| {
            std.debug.print("script {s}\n", .{c[0]});
            return e;
        };
    }
    try t.expectEqualStrings("only one event specification allowed", try h.evalError("event generate .f <1><2>"));
    try t.expectEqualStrings("only one event specification allowed", try h.evalError("event generate .f ab"));
}
