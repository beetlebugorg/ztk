//! Tests of the pointer shape. The core sends the shape of the widget
//! under the pointer to the backend after a motion, when it changed. The
//! headless backend records the shape. The `-cursor` option of the widget
//! or an ancestor comes first, as in Tk, and then the CSS `cursor`.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Harness = @import("../testing.zig").Harness;
const Cursor = @import("../platform/platform.zig").Cursor;
const t = std.testing;

fn over(h: *Harness, path: []const u8) !?Cursor {
    // The geometry of a widget is relative to its parent, so the offsets add up to the toplevel.
    var x: i32 = 2;
    var y: i32 = 2;
    var cur: ?*const @import("../widget.zig").Widget = h.app.find(path).?;
    while (cur) |c| : (cur = c.parent) {
        if (c.parent == null) break;
        x += c.geom.x;
        y += c.geom.y;
    }
    h.head.pointerMove(h.win, @floatFromInt(x), @floatFromInt(y));
    try h.update();
    return h.head.cursor;
}

test "cursor: the names of CSS and of Tk map to shapes" {
    try t.expectEqual(Cursor.not_allowed, Cursor.fromCss("not-allowed"));
    try t.expectEqual(Cursor.ew_resize, Cursor.fromCss("ew-resize"));
    try t.expectEqual(Cursor.default, Cursor.fromCss("no-such-shape"));
    try t.expectEqual(Cursor.text, Cursor.fromTk("xterm").?);
    try t.expectEqual(Cursor.pointer, Cursor.fromTk("hand2").?);
    try t.expect(Cursor.fromTk("gumby") == null);
}

test "cursor: the shape follows the widget under the pointer" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval(
        \\frame .f -width 60 -height 30 -cursor fleur
        \\label .f.l -text in
        \\entry .e
        \\label .plain -text plain
        \\label .css -text css
        \\ztk::style add { #css { cursor: crosshair } }
        \\pack .f .e .plain .css
        \\pack .f.l
        \\update
    );
    // The entry has the default -cursor xterm.
    try t.expectEqual(Cursor.text, (try over(&h, ".e")).?);
    // A label in a frame with -cursor fleur has the shape of the frame.
    try t.expectEqual(Cursor.move, (try over(&h, ".f.l")).?);
    try t.expectEqual(Cursor.default, (try over(&h, ".plain")).?);
    try t.expectEqual(Cursor.crosshair, (try over(&h, ".css")).?);
    // A motion over the same widget sends no new shape.
    const calls = h.head.cursor_calls;
    _ = try over(&h, ".css");
    try t.expectEqual(calls, h.head.cursor_calls);
}
