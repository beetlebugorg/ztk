//! Tests of selector matching, the cascade, variables, and the commands
//! `ztk::style` and `ztk::class`.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Harness = @import("../testing.zig").Harness;
const style_mod = @import("../style.zig");
const build_options = @import("build_options");
const t = std.testing;

fn styleOf(h: *Harness, path: []const u8) *const style_mod.Style {
    const w = h.app.find(path).?;
    h.app.ensureStyle(w);
    return &w.style;
}

fn bgHex(h: *Harness, path: []const u8, buf: *[7]u8) []const u8 {
    return styleOf(h, path).background.formatTk(buf);
}

fn expectBg(h: *Harness, path: []const u8, want: []const u8) !void {
    var buf: [7]u8 = undefined;
    try t.expectEqualStrings(want, bgHex(h, path, &buf));
}

test "select: a type rule sets the background" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("ztk::style add {Frame { background-color: #112233 }}; frame .f");
    try expectBg(&h, ".f", "#112233");
}

test "select: the specificity and the order decide" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("frame .f; ztk::class .f add card");
    _ = try h.eval("ztk::style add {Frame { background-color: #000001 } .card { background-color: #000002 } Frame.card { background-color: #000003 } #f { background-color: #000004 }}");
    try expectBg(&h, ".f", "#000004");
    _ = try h.eval("frame .g; ztk::class .g add card");
    try expectBg(&h, ".g", "#000003");
    _ = try h.eval("frame .h");
    try expectBg(&h, ".h", "#000001");
    // A later rule of equal specificity wins.
    _ = try h.eval("ztk::style add {Frame { background-color: #000009 }}");
    try expectBg(&h, ".h", "#000009");
}

test "select: the child and descendant combinators" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("frame .a; frame .a.b; frame .a.b.c; ztk::class .a add top");
    _ = try h.eval("ztk::style add {.top > Frame { background-color: #010101 } .top Frame { color: #020202 }}");
    try expectBg(&h, ".a.b", "#010101");
    try expectBg(&h, ".a.b.c", "#f5f5f7");
    var buf: [7]u8 = undefined;
    try t.expectEqualStrings("#020202", styleOf(&h, ".a.b.c").color.formatTk(&buf));
    try t.expectEqualStrings("#020202", styleOf(&h, ".a.b").color.formatTk(&buf));
}

test "style: an option of the widget wins over each sheet" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("ztk::style add {#f { background-color: #112233 }}; frame .f -bg red");
    try expectBg(&h, ".f", "#ff0000");
    try t.expectEqualStrings("red", try h.eval(".f cget -background"));
}

test "style: cget of an option that is not set gives the computed color" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("ztk::style add {#f { background-color: #123456; border-width: 3px }}; frame .f");
    try t.expectEqualStrings("#123456", try h.eval(".f cget -background"));
    try t.expectEqualStrings("3", try h.eval(".f cget -borderwidth"));
}

test "style: variables" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("ztk::style add {:root { --c: #010203 } Frame { background-color: var(--c) } #own { --c: #0a0b0c } }");
    _ = try h.eval("frame .own; frame .own.kid; frame .sib");
    try expectBg(&h, ".sib", "#010203");
    try expectBg(&h, ".own", "#0a0b0c");
    // The variable of #own changes its children, and not its siblings.
    var buf: [7]u8 = undefined;
    try t.expectEqualStrings("#0a0b0c", bgHex(&h, ".own.kid", &buf));
}

test "style: a fallback, a missing variable, and a cycle" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("ztk::style add {#a { background-color: var(--nosuch, #040506) } #b { background-color: var(--nosuch) } #c { --x: var(--y); --y: var(--x); background-color: var(--x) }}");
    _ = try h.eval("frame .a; frame .b; frame .c");
    try expectBg(&h, ".a", "#040506");
    // No fallback: the declaration is invalid, so the base rule of the theme stays.
    try expectBg(&h, ".b", "#f5f5f7");
    try expectBg(&h, ".c", "#f5f5f7");
}

test "style: color inherits and a type rule overrides it" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("ztk::style add {#p { color: blue } Label { color: red }}");
    _ = try h.eval("frame .p; frame .p.l -class Label; frame .p.f");
    var buf: [7]u8 = undefined;
    try t.expectEqualStrings("#ff0000", styleOf(&h, ".p.l").color.formatTk(&buf));
    try t.expectEqualStrings("#0000ff", styleOf(&h, ".p.f").color.formatTk(&buf));
}

test "style: em depends on the font size of the parent" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("ztk::style add {#p { font-size: 10px } #p > Frame { font-size: 2em; padding: 1em }}");
    _ = try h.eval("frame .p; frame .p.c");
    try t.expectEqual(@as(f32, 10), styleOf(&h, ".p").font.size);
    try t.expectEqual(@as(f32, 20), styleOf(&h, ".p.c").font.size);
    // 1em of the widget itself.
    try t.expectEqual(@as(i32, 20), styleOf(&h, ".p.c").padding.left);
}

test "style: the dark scheme applies only with Env.dark" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("ztk::style add {@media (prefers-color-scheme: dark) { Frame { background-color: #111111 } }}; frame .f");
    try expectBg(&h, ".f", "#f5f5f7");
    h.app.env.dark = true;
    h.app.styles.generation += 1;
    try expectBg(&h, ".f", "#111111");
}

test "style: ztk::class" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("frame .f; ztk::style add {.card { background-color: #0000aa }}");
    try t.expectEqualStrings("", try h.eval("ztk::class .f"));
    _ = try h.eval("ztk::class .f add card extra");
    try t.expectEqualStrings("card extra", try h.eval("ztk::class .f"));
    try expectBg(&h, ".f", "#0000aa");
    _ = try h.eval("ztk::class .f remove card");
    try t.expectEqualStrings("extra", try h.eval("ztk::class .f"));
    try expectBg(&h, ".f", "#f5f5f7");
    _ = try h.eval("ztk::class .f set a b");
    try t.expectEqualStrings("a b", try h.eval("ztk::class .f"));
    try t.expectEqualStrings("bad window path name \".no\"", try h.evalError("ztk::class .no"));
}

test "style: add and remove put the style back" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("frame .f");
    try expectBg(&h, ".f", "#f5f5f7");
    const id = try h.eval("ztk::style add {Frame { background-color: #aabbcc }}");
    try t.expectEqualStrings("style4", id);
    try expectBg(&h, ".f", "#aabbcc");
    _ = try h.eval("ztk::style remove style4");
    try expectBg(&h, ".f", "#f5f5f7");
    try t.expectEqualStrings("modern", try h.eval("ztk::style theme"));
}

test "style: diagnostics of a sheet" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("set id [ztk::style add {Frame { bogus: 1 }}]");
    try t.expectEqualStrings("1", try h.eval("llength [ztk::style diagnostics $id]"));
    try t.expectEqualStrings("1", try h.eval("lindex [lindex [ztk::style diagnostics $id] 0] 0"));
}

test "style: load needs a style folder and stays inside it" {
    var h: Harness = undefined;
    try h.init();
    try t.expectEqualStrings("ztk::style load is not allowed", try h.evalError("ztk::style load x.css"));
    h.deinit();
    var h2: Harness = undefined;
    const root = build_options.repo_root ++ "/tests/fixtures";
    try h2.initWith(root);
    defer h2.deinit();
    try t.expectEqualStrings("file \"../x.css\" is outside the style folder", try h2.evalError("ztk::style load ../x.css"));
    try t.expectEqualStrings("file \"/etc/passwd\" is outside the style folder", try h2.evalError("ztk::style load /etc/passwd"));
    _ = try h2.eval("ztk::style load x.css; frame .f");
    try expectBg(&h2, ".f", "#0a0b0c");
}

test "style: a hover computes one style" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("frame .a; frame .b; ztk::style add {Frame:hover { background-color: #0000ff }}");
    h.app.restyle();
    const before = h.app.styles.compute_calls;
    h.app.find(".a").?.state.hover = true;
    h.app.find(".a").?.invalidate(.{ .style = true, .measure = false, .layout = false, .paint = true });
    h.app.restyle();
    try t.expectEqual(before + 1, h.app.styles.compute_calls);
    try expectBg(&h, ".a", "#0000ff");
    try expectBg(&h, ".b", "#f5f5f7");
}

test "style: the embedded sheets have no diagnostics" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    for ([_]u32{ 1, 2, 3 }) |id| try t.expectEqual(@as(usize, 0), h.app.styles.diagnostics(id).len);
}

test "style: the modern sheet has colors only in variable blocks" {
    const src = @embedFile("../themes/modern.css");
    var line_it = std.mem.splitScalar(u8, src, '\n');
    while (line_it.next()) |line| {
        if (std.mem.indexOf(u8, line, "#") != null) {
            // A color literal must be on a line that declares a variable.
            try t.expect(std.mem.indexOf(u8, line, "--") != null);
        }
    }
}

test "style-speed: a pass over 1000 widgets" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("for {set i 0} {$i < 10} {incr i} { frame .g$i; for {set j 0} {$j < 99} {incr j} { frame .g$i.f$j } }");
    const t0 = std.Io.Clock.awake.now(t.io);
    h.app.restyle();
    const ns = t0.untilNow(t.io, .awake).toNanoseconds();
    const ms = @as(f64, @floatFromInt(ns)) / 1e6;
    std.debug.print("style-speed: {d:.2} ms for {d} widgets ({s})\n", .{ ms, h.app.widgets.count(), @tagName(@import("builtin").mode) });
    if (@import("builtin").mode == .ReleaseFast) try t.expect(ms < 3.0);
}

test "style-cache: equal widgets share rules, and a change of class or variable shows" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("ztk::style add {:root { --c: #0a0a0a } .v { color: var(--c) } .a Frame { background-color: #030303 } Frame.hot { background-color: #040404 }}");
    _ = try h.eval("frame .a; ztk::class .a add a; frame .a.x; frame .a.y; frame .b; frame .b.x");
    try expectBg(&h, ".a.x", "#030303");
    try expectBg(&h, ".a.y", "#030303");
    try expectBg(&h, ".b.x", "#f5f5f7");
    try t.expect(h.app.styles.cache_hits > 0);
    _ = try h.eval("ztk::class .b.x add hot");
    try expectBg(&h, ".b.x", "#040404");
    _ = try h.eval("ztk::class .b.x remove hot");
    try expectBg(&h, ".b.x", "#f5f5f7");
    // A variable of a nearer ancestor changes what a cached rule gives.
    _ = try h.eval("frame .p; ztk::class .p add v; frame .p.k; ztk::class .p.k add v; frame .q; ztk::class .q add v");
    var buf: [7]u8 = undefined;
    try t.expectEqualStrings("#0a0a0a", styleOf(&h, ".p.k").color.formatTk(&buf));
    _ = try h.eval("ztk::style add {#q { --c: #0b0b0b }}");
    _ = try h.eval("frame .q.k; ztk::class .q.k add v");
    try t.expectEqualStrings("#0b0b0b", styleOf(&h, ".q.k").color.formatTk(&buf));
    try t.expectEqualStrings("#0a0a0a", styleOf(&h, ".p.k").color.formatTk(&buf));
}
