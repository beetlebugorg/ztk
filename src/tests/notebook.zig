//! Tests of `ttk::notebook`: the options, the subcommands and their
//! messages, `<<NotebookTabChanged>>`, the hide and the forget of the
//! selected tab, tab changes with the pointer and the keys, the traversal
//! of `ttk::notebook::enableTraversal`, and the slide of the indicator.
//! The expected texts are from `wish` 8.6.16.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Harness = @import("../testing.zig").Harness;
const notebook = @import("../ttk/notebook.zig");
const t = std.testing;

fn expectCases(h: *Harness, cases: []const [2][]const u8) !void {
    for (cases) |c| t.expectEqualStrings(c[1], try h.evalError(c[0])) catch |e| {
        std.debug.print("case: {s}\n", .{c[0]});
        return e;
    };
}

fn expectEvals(h: *Harness, cases: []const [2][]const u8) !void {
    for (cases) |c| t.expectEqualStrings(c[1], try h.eval(c[0])) catch |e| {
        std.debug.print("case: {s}\n", .{c[0]});
        return e;
    };
}

test "notebook: the options, the subcommands, and the messages of wish" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("ttk::notebook .n; ttk::frame .n.a -width 100 -height 60; ttk::frame .n.b; ttk::frame .n.c; .n add .n.a -text One; .n add .n.b -text Two -underline 0");
    try expectEvals(&h, &.{
        .{ ".n configure -padding", "-padding padding Padding {} {}" },
        .{ ".n configure -takefocus", "-takefocus takeFocus TakeFocus ttk::takefocus ttk::takefocus" },
        .{ ".n tab .n.a", "-padding 0 -sticky nsew -state normal -text One -image {} -compound {} -underline -1" },
        .{ ".n tab 0 -text", "One" },
        .{ ".n index end", "2" },
        .{ ".n index current", "0" },
        .{ ".n index .n.b", "1" },
        .{ ".n index @5,5", "" },
        .{ ".n select", ".n.a" },
        .{ ".n tabs", ".n.a .n.b" },
        .{ "winfo manager .n.a", "notebook" },
        .{ "bindtags .n", ".n TNotebook . all" },
    });
    try expectCases(&h, &.{
        .{ ".n bogus", "bad command \"bogus\": must be add, configure, cget, forget, hide, identify, index, insert, instate, select, state, tab, or tabs" },
        .{ ".n add", "wrong # args: should be \".n add window ?-option value ...?\"" },
        .{ ".n add .n.c -bogus 1", "unknown option \"-bogus\"" },
        .{ ".n add .n.c -state x", "bad state \"x\": must be normal, disabled, or hidden" },
        .{ ".n add .n.c -sticky q", "Bad -sticky specification q" },
        .{ ".n forget", "wrong # args: should be \".n forget tab\"" },
        .{ ".n forget 9", "Slave index 9 out of bounds" },
        .{ ".n forget .x", "Invalid slave specification .x" },
        .{ ".n hide", "wrong # args: should be \".n hide tab\"" },
        .{ ".n index", "wrong # args: should be \".n index tab\"" },
        .{ ".n index 9", "Slave index 9 out of bounds" },
        .{ ".n index x", "Invalid slave specification x" },
        .{ ".n insert", "wrong # args: should be \".n insert index slave ?-option value ...?\"" },
        .{ ".n insert 9 .n.c", "Slave index 9 out of bounds" },
        .{ ".n select 9", "Slave index 9 out of bounds" },
        .{ ".n tab", "wrong # args: should be \".n tab tab ?-option ?value??...\"" },
        .{ ".n tab 0 -bogus", "unknown option \"-bogus\"" },
        .{ ".n tabs x", "wrong # args: should be \".n tabs \"" },
        .{ ".n identify", "wrong # args: should be \".n identify ?what? x y\"" },
        .{ ".n identify bogus 1 1", "bad option \"bogus\": must be element or tab" },
        .{ ".n add .", "can't add . as slave of .n" },
        .{ ".n add .n", "can't add .n as slave of .n" },
        .{ ".n tab .n.c", ".n.c is not managed by .n" },
    });
    // A failed add leaves no tab.
    try t.expectEqualStrings(".n.a .n.b", try h.eval(".n tabs"));
}

test "notebook: the selection, the events, hide, forget, insert, and the pages" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval(
        \\set ::log {}
        \\ttk::notebook .n
        \\ttk::frame .n.a; ttk::frame .n.b; ttk::label .n.c -text hi
        \\bind .n <<NotebookTabChanged>> {lappend ::log [.n select]}
        \\.n add .n.a -text One -padding {2 3} -sticky ns
        \\.n add .n.b -text Two -state disabled
        \\.n select 1
    );
    try expectEvals(&h, &.{
        .{ ".n select", ".n.a" },
        .{ "list [.n tab 0 -padding] [.n tab 0 -sticky]", "{2 3} ns" },
        .{ "set ::log", "" },
        .{ "update; set ::log", ".n.a" },
    });
    _ = try h.eval(".n insert 0 .n.c -text Lbl");
    try t.expectEqualStrings(".n.c .n.a .n.b 1 .n.a", try h.eval("list {*}[.n tabs] [.n index current] [.n select]"));
    _ = try h.eval(".n insert end .n.c; .n tab .n.c -state hidden; .n select .n.c");
    try t.expectEqualStrings(".n.c normal", try h.eval("list [.n select] [.n tab .n.c -state]"));
    _ = try h.eval("pack .n -fill both -expand 1; wm geometry . 300x200; update; set ::log {}");
    try t.expectEqualStrings("0 1", try h.eval("list [winfo ismapped .n.a] [winfo ismapped .n.c]"));
    // The hide of the selected tab selects the tab before it, here the only one left.
    _ = try h.eval(".n tab .n.b -state normal; .n select .n.b; .n hide .n.b; update");
    try t.expectEqualStrings(".n.c hidden", try h.eval("list [.n select] [.n tab .n.b -state]"));
    _ = try h.eval(".n forget .n.c; update");
    try t.expectEqualStrings(".n.a .n.a 1", try h.eval("list [.n select] [lindex $::log end] [winfo ismapped .n.a]"));
    _ = try h.eval(".n forget .n.a; .n forget .n.b; update");
    try t.expectEqualStrings("{} {} 0", try h.eval("list [.n select] [lindex $::log end] [.n index end]"));
}

/// The middle of tab `i` of `.n` in the window, from `identify`.
fn tabPoint(h: *Harness, i: usize) ![2]f32 {
    const n = h.app.find(".n").?;
    var buf: [64]u8 = undefined;
    var x: i32 = 0;
    while (x < n.geom.w) : (x += 2) {
        const r = try h.eval(try std.fmt.bufPrint(&buf, ".n identify tab {d} 10", .{x}));
        if (r.len > 0 and try std.fmt.parseInt(usize, r, 10) == i) return .{ @floatFromInt(n.geom.x + x + 8), @floatFromInt(n.geom.y + 10) };
    }
    return error.NoTab;
}

test "notebook: a click, the arrow keys, and the traversal keys change the tab" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval(
        \\ttk::notebook .n
        \\foreach {p t} {a One b Two c Three} {ttk::frame .n.$p; .n add .n.$p -text $t -underline 0}
        \\.n tab .n.b -state disabled
        \\entry .n.c.e; pack .n.c.e
        \\pack .n -fill both -expand 1; wm geometry . 300x200; update
    );
    const p = try tabPoint(&h, 2);
    h.head.click(h.win, p[0], p[1]);
    try h.update();
    try t.expectEqualStrings(".n.c .n", try h.eval("list [.n select] [focus]"));
    // A click on a disabled tab keeps the selection, and Left skips the tab.
    const q = try tabPoint(&h, 1);
    h.head.click(h.win, q[0], q[1]);
    try h.update();
    try t.expectEqualStrings(".n.c", try h.eval(".n select"));
    try h.head.press(h.win, "Left");
    try h.update();
    try t.expectEqualStrings(".n.a", try h.eval(".n select"));
    try h.head.press(h.win, "Right");
    try h.update();
    try t.expectEqualStrings(".n.c", try h.eval(".n select"));
    // The traversal keys work from a widget in a page.
    _ = try h.eval("ttk::notebook::enableTraversal .n; focus .n.c.e; update");
    _ = try h.eval("event generate .n.c.e <Control-Key-Tab>; update");
    try t.expectEqualStrings(".n.a", try h.eval(".n select"));
    _ = try h.eval("event generate .n.c.e <Alt-Key> -keysym t; update");
    try t.expectEqualStrings(".n.c", try h.eval(".n select"));
}

test "notebook: the indicator slides, a frame in the middle, and a change during the slide" {
    var h: Harness = undefined;
    try h.initAnimated();
    defer h.deinit();
    _ = try h.eval(
        \\ttk::notebook .n
        \\foreach {p t} {a One b Two c Three} {ttk::frame .n.$p; .n add .n.$p -text $t}
        \\pack .n -fill both -expand 1; wm geometry . 300x200; update
    );
    const n = h.app.find(".n").?;
    const start = notebook.indicatorOf(n);
    _ = try h.eval(".n select 2; update");
    try t.expectApproxEqAbs(start[0], notebook.indicatorOf(n)[0], 0.5);
    h.head.advance(80);
    try h.update();
    const mid = notebook.indicatorOf(n)[0];
    try t.expect(mid > start[0]);
    // A change in the middle starts from the shown place.
    _ = try h.eval(".n select 1; update");
    try t.expectApproxEqAbs(mid, notebook.indicatorOf(n)[0], 0.5);
    h.head.advance(300);
    try h.update();
    const done = notebook.indicatorOf(n);
    try t.expect(done[0] > start[0] and done[0] < mid);
}

test "notebook: a page can be a sibling of the notebook, as in wish" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("frame .f; ttk::notebook .f.n; ttk::frame .x; .f.n add .x -text X; frame .f.z; frame .f.z.q; ttk::panedwindow .f.p; ttk::frame .y; .f.p add .y");
    try t.expectEqualStrings(".x .y", try h.eval("list {*}[.f.n tabs] {*}[.f.p panes]"));
    try t.expectEqualStrings("can't add .f.z.q as slave of .f.n", try h.evalError(".f.n add .f.z.q"));
}
