//! Tests of the entry widget: the subcommands, the variable link, the
//! keyboard and pointer paths through the class bindings, the caret
//! timer, and the golden images. The expected texts are from `wish`
//! 8.6.16.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Harness = @import("../testing.zig").Harness;
const testing_h = @import("../testing.zig");
const t = std.testing;

fn setup(h: *Harness) !void {
    try h.init();
    _ = try h.eval("entry .e; grid .e -padx 10 -pady 10; update");
}

fn get(h: *Harness) ![]const u8 {
    return h.eval(".e get");
}

fn typeKeys(h: *Harness, names: []const []const u8) !void {
    for (names) |n| try h.head.press(h.win, n);
    try h.update();
}

test "entry: insert, index, and icursor" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    _ = try h.eval(".e insert 0 hello");
    try t.expectEqualStrings("5", try h.eval(".e index end"));
    _ = try h.eval(".e icursor 2");
    try t.expectEqualStrings("2", try h.eval(".e index insert"));
    try t.expectEqualStrings("5", try h.eval(".e index 99"));
    try t.expectEqualStrings("0", try h.eval(".e index -5"));
    try t.expectEqualStrings("bad entry index \"bogus\"", try h.evalError(".e index bogus"));
    try t.expectEqualStrings("wrong # args: should be \".e insert index text\"", try h.evalError(".e insert 0"));
    try t.expectEqualStrings("bad option \"bogus\": must be bbox, cget, configure, delete, get, icursor, index, insert, scan, selection, validate, or xview", try h.evalError(".e bogus"));
    try t.expectEqualStrings("xview is not supported in this stage", try h.evalError(".e xview"));
}

test "entry: selection and delete" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    _ = try h.eval(".e insert 0 hello; .e selection range 1 3");
    try t.expectEqualStrings("1 1 3", try h.eval("list [.e selection present] [.e index sel.first] [.e index sel.last]"));
    _ = try h.eval(".e delete sel.first sel.last");
    try t.expectEqualStrings("hlo", try get(&h));
    _ = try h.eval(".e selection clear");
    try t.expectEqualStrings("selection isn't in widget .e", try h.evalError(".e index sel.first"));
    try t.expectEqualStrings("bad selection option \"bogus\": must be adjust, clear, from, present, range, or to", try h.evalError(".e selection bogus"));
    try t.expectEqualStrings("selection adjust is not supported in this stage", try h.evalError(".e selection adjust 1"));
    _ = try h.eval(".e delete 0 end; .e insert end abc; .e insert 1 XY");
    try t.expectEqualStrings("aXYbc", try get(&h));
    _ = try h.eval(".e delete 2");
    try t.expectEqualStrings("aXbc", try get(&h));
}

test "entry: readonly and disabled keep the text" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    _ = try h.eval(".e insert 0 abc; .e configure -state readonly; .e insert end zzz; .e delete 0");
    try t.expectEqualStrings("abc", try get(&h));
    _ = try h.eval(".e configure -state disabled; .e insert end zzz");
    try t.expectEqualStrings("abc", try get(&h));
    try t.expectEqualStrings("bad state \"foo\": must be disabled, normal, or readonly", try h.evalError(".e configure -state foo"));
}

test "entry: the text variable works in both directions" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    _ = try h.eval("set tv init; .e configure -textvariable tv");
    try t.expectEqualStrings("init", try get(&h));
    _ = try h.eval(".e insert end Q");
    try t.expectEqualStrings("initQ", try h.eval("set tv"));
    _ = try h.eval("set tv new");
    try t.expectEqualStrings("new", try get(&h));
    _ = try h.eval("entry .f -textvariable fresh; .f insert 0 x");
    try t.expectEqualStrings("x", try h.eval("set fresh"));
}

test "entry: show hides the characters in the scene" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    _ = try h.eval(".e insert 0 secret; .e configure -show *; update");
    try t.expectEqualStrings("secret", try get(&h));
    var glyphs: usize = 0;
    var first: ?[4]f32 = null;
    for (h.app.lastScene().quads.items) |q| {
        if (q.kind != 2) continue;
        glyphs += 1;
        if (first == null) first = q.uv;
        // Every glyph is the same star image.
        try t.expectEqual(first.?[2], q.uv[2]);
    }
    try t.expectEqual(@as(usize, 6), glyphs);
}

test "entry: typing and editing keys go through the bindings" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    _ = try h.eval("focus .e");
    try h.head.typeText(h.win, "Ada");
    try h.update();
    try t.expectEqualStrings("Ada", try get(&h));
    try typeKeys(&h, &.{ "Left", "Left" });
    try h.head.typeText(h.win, "x");
    try h.update();
    try t.expectEqualStrings("Axda", try get(&h));
    try typeKeys(&h, &.{"BackSpace"});
    try t.expectEqualStrings("Ada", try get(&h));
    try typeKeys(&h, &.{ "Home", "Delete" });
    try t.expectEqualStrings("da", try get(&h));
    try typeKeys(&h, &.{"End"});
    try h.head.typeText(h.win, "!");
    try h.update();
    try t.expectEqualStrings("da!", try get(&h));
}

test "entry: Shift-Left selects, Control-a goes to the start" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    _ = try h.eval("focus .e; .e insert 0 abcdef; .e icursor end");
    h.head.setMods(.{ .shift = true });
    try typeKeys(&h, &.{ "Left", "Left" });
    h.head.setMods(.{});
    try h.head.typeText(h.win, "x");
    try h.update();
    try t.expectEqualStrings("abcdx", try get(&h));
    h.head.setMods(.{ .control = true });
    try typeKeys(&h, &.{"a"});
    h.head.setMods(.{});
    try h.head.typeText(h.win, "z");
    try h.update();
    try t.expectEqualStrings("zabcdx", try get(&h));
}

test "entry: Return and Tab make no edit, and other bindings still run" {
    var h: Harness = undefined;
    try h.init();
    _ = try h.eval("entry .e; entry .g; grid .e .g; update; set got none");
    defer h.deinit();
    _ = try h.eval("focus .e; bind .e <Return> {set got [.e get]}");
    try h.head.typeText(h.win, "ab");
    try typeKeys(&h, &.{"Return"});
    try t.expectEqualStrings("ab", try h.eval("set got"));
    try t.expectEqualStrings("ab", try get(&h));
    try typeKeys(&h, &.{"Tab"});
    try t.expectEqualStrings(".g", try h.eval("focus"));
    try t.expectEqualStrings("ab", try get(&h));
}

test "entry: the pointer sets the caret, selects, and picks words" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    _ = try h.eval(".e insert 0 {foo bar baz}; update");
    const w = h.app.find(".e").?;
    // The x of the character boundaries, from the widget command.
    const x4 = try std.fmt.parseInt(i32, try h.eval("expr {[winfo x .e] + 10}"), 10);
    _ = x4;
    const y: f32 = @floatFromInt(w.geom.y + @divTrunc(w.geom.h, 2));
    const x0: f32 = @floatFromInt(w.geom.x);
    // Click far right: the caret goes to the end.
    h.head.click(h.win, x0 + 150, y);
    try h.update();
    try t.expectEqualStrings("11", try h.eval(".e index insert"));
    try t.expectEqualStrings(".e", try h.eval("focus"));
    // A press, a move, and a release select.
    h.head.pointerMove(h.win, x0 + 6, y);
    h.head.pointerButton(h.win, 1, true);
    h.head.pointerMove(h.win, x0 + 150, y);
    h.head.pointerButton(h.win, 1, false);
    try h.update();
    try t.expectEqualStrings("1", try h.eval(".e selection present"));
    // A double click selects a word.
    _ = try h.eval(".e selection clear");
    h.head.pointerMove(h.win, x0 + 8 + 4 * 7, y);
    h.head.pointerButton(h.win, 1, true);
    h.head.pointerButton(h.win, 1, false);
    h.head.pointerButton(h.win, 1, true);
    h.head.pointerButton(h.win, 1, false);
    try h.update();
    try t.expectEqualStrings("1", try h.eval(".e selection present"));
}

test "entry: a long text scrolls and keeps the caret inside" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    _ = try h.eval("focus .e");
    var i: u32 = 0;
    while (i < 60) : (i += 1) try h.head.typeText(h.win, "m");
    try h.update();
    try t.expectEqualStrings("60", try h.eval(".e index end"));
    const w = h.app.find(".e").?;
    var caret_ok = false;
    for (h.app.lastScene().quads.items) |q| {
        // The caret is a box with the text color fill and a width of 2 device pixels.
        if (q.kind == 0 and q.rect[2] == 2 and q.rect[3] > 8) {
            caret_ok = q.rect[0] >= @as(f32, @floatFromInt(w.geom.x)) and q.rect[0] + 2 <= @as(f32, @floatFromInt(w.geom.x + w.geom.w));
        }
    }
    try t.expect(caret_ok);
}

fn caretQuads(h: *Harness) usize {
    var n: usize = 0;
    for (h.app.lastScene().quads.items) |q| {
        if (q.kind == 0 and q.rect[2] == 2 and q.rect[3] > 8) n += 1;
    }
    return n;
}

test "entry: the caret blinks with the clock, and an idle entry draws no frame" {
    var h: Harness = undefined;
    try setup(&h);
    defer h.deinit();
    try t.expectEqual(@as(usize, 0), caretQuads(&h));
    _ = try h.eval("focus .e");
    try h.update();
    try t.expectEqual(@as(usize, 1), caretQuads(&h));
    h.head.advance(700);
    try h.update();
    try t.expectEqual(@as(usize, 0), caretQuads(&h));
    h.head.advance(250);
    try h.update();
    try t.expectEqual(@as(usize, 1), caretQuads(&h));
    // With no focus there is no timer and no frame.
    _ = try h.eval("focus .");
    try h.update();
    const drawn = h.head.frames_drawn;
    h.head.advance(5000);
    try h.update();
    try t.expectEqual(drawn, h.head.frames_drawn);
    try t.expectEqual(@as(usize, 0), caretQuads(&h));
}

fn shot(h: *Harness, name: []const u8) !void {
    try h.update();
    try testing_h.expectGolden(name, h.head.image(h.win).?, .{});
    try testing_h.expectScene(name, h.app.lastScene());
}

fn field(h: *Harness, extra: []const u8) !void {
    try h.init();
    _ = try h.eval("wm geometry . 260x60; entry .e -width 20");
    _ = try h.eval("grid .e -padx 10 -pady 12");
    _ = try h.eval(extra);
}

test "entry-empty-focus" {
    var h: Harness = undefined;
    try field(&h, "focus .e");
    defer h.deinit();
    try shot(&h, "entry-empty-focus");
}

test "entry-text" {
    var h: Harness = undefined;
    try field(&h, ".e insert 0 {Hello, entry}");
    defer h.deinit();
    try shot(&h, "entry-text");
}

test "entry-selection" {
    var h: Harness = undefined;
    try field(&h, ".e insert 0 {Hello, entry}; .e selection range 2 8");
    defer h.deinit();
    try shot(&h, "entry-selection");
}

test "entry-scrolled" {
    var h: Harness = undefined;
    try field(&h, ".e insert 0 {A long text that does not fit in the field at all}; focus .e; .e icursor end");
    defer h.deinit();
    try shot(&h, "entry-scrolled");
}

test "entry-disabled" {
    var h: Harness = undefined;
    try field(&h, ".e insert 0 {Disabled text}; .e configure -state disabled");
    defer h.deinit();
    try shot(&h, "entry-disabled");
}

test "entry-show" {
    var h: Harness = undefined;
    try field(&h, ".e insert 0 secret; .e configure -show *");
    defer h.deinit();
    try shot(&h, "entry-show");
}
