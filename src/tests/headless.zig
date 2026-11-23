//! Tests of the headless backend and the pass of the App.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Harness = @import("../testing.zig").Harness;
const event = @import("../event.zig");
const t = std.testing;

fn drain(h: *Harness) !std.ArrayListUnmanaged(event.Event) {
    var out: std.ArrayListUnmanaged(event.Event) = .empty;
    try h.head.platform().poll(t.allocator, &out);
    return out;
}

test "headless: a resize changes the size of the toplevel" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.head.resize(h.win, .{ .w = 300, .h = 200 });
    try h.update();
    try t.expectEqual(@as(i32, 300), h.app.root.?.geom.w);
    try t.expectEqual(@as(i32, 200), h.app.root.?.geom.h);
    // `update` runs the layout pass, so the flag is clear again.
    try t.expect(!h.app.root.?.dirty.layout);
}

test "headless: requestSize answers with a resize event" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.head.platform().vtable.requestSize(h.head, h.win, .{ .w = 50, .h = 60 });
    var out = try drain(&h);
    defer out.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), out.items.len);
    try t.expectEqual(@as(i32, 50), out.items[0].resize.size.w);
}

test "headless: close deletes . and run returns" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("frame .a");
    h.head.close(h.win);
    try h.app.run();
    try t.expect(h.app.root == null);
    try t.expectEqualStrings("0", try h.eval("winfo exists .a"));
}

test "headless: two frame requests give one frame event" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const p = h.head.platform();
    p.requestFrame(h.win);
    p.requestFrame(h.win);
    try t.expectEqual(@as(u32, 2), h.head.frames_requested);
    var out = try drain(&h);
    defer out.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), out.items.len);
    try t.expect(out.items[0] == .frame);
    var out2 = try drain(&h);
    defer out2.deinit(t.allocator);
    try t.expectEqual(@as(usize, 0), out2.items.len);
}

test "headless: advance makes a timer due" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("after 100 {set x 1}");
    h.head.advance(99);
    try h.update();
    try t.expectEqualStrings("0", try h.eval("info exists x"));
    h.head.advance(1);
    try h.update();
    try t.expectEqualStrings("1", try h.eval("set x"));
}

test "headless: wait moves the clock only when no event waits" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const p = h.head.platform();
    p.wait(500);
    try t.expectEqual(@as(i64, 500), p.nowUs());
    h.head.pointerMove(h.win, 1, 1);
    p.wait(500);
    try t.expectEqual(@as(i64, 500), p.nowUs());
    p.wait(null);
}

test "headless: typeText gives four key events with shift on a capital" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.head.typeText(h.win, "aB");
    var out = try drain(&h);
    defer out.deinit(t.allocator);
    try t.expectEqual(@as(usize, 4), out.items.len);
    const k = out.items[2].key;
    try t.expectEqual(@as(u32, 'B'), k.keysym);
    try t.expectEqualStrings("B", k.text[0..k.text_len]);
    try t.expect(k.mods.shift);
    try t.expect(k.pressed);
    try t.expect(!out.items[0].key.mods.shift);
    try t.expect(!out.items[3].key.pressed);
}

test "headless: typeText of a non-Latin-1 character" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.head.typeText(h.win, "\u{20ac}");
    var out = try drain(&h);
    defer out.deinit(t.allocator);
    try t.expectEqual(@as(u32, 0x0100_20ac), out.items[0].key.keysym);
    try t.expectEqual(@as(u8, 3), out.items[0].key.text_len);
}

test "headless: pointer position and button mods" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.head.pointerMove(h.win, 10, 20);
    h.head.pointerButton(h.win, 1, true);
    h.head.pointerMove(h.win, 11, 21);
    h.head.pointerButton(h.win, 1, false);
    var out = try drain(&h);
    defer out.deinit(t.allocator);
    const press = out.items[1].button;
    try t.expectEqual(@as(f32, 10), press.x);
    try t.expectEqual(@as(f32, 20), press.y);
    try t.expect(!press.mods.button1);
    try t.expect(out.items[2].motion.mods.button1);
    const release = out.items[3].button;
    try t.expect(release.mods.button1);
    try t.expect(!release.pressed);
}

test "headless: key and press by name" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.head.press(h.win, "Return");
    try t.expectError(error.UnknownKeysym, h.head.press(h.win, "nosuch"));
    var out = try drain(&h);
    defer out.deinit(t.allocator);
    try t.expectEqual(@as(usize, 2), out.items.len);
    try t.expectEqual(@as(u32, 0xff0d), out.items[0].key.keysym);
    try t.expectEqual(@as(u8, 0), out.items[0].key.text_len);
}

test "headless: events of a destroyed window are dropped" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.head.pointerMove(h.win, 1, 1);
    h.head.close(h.win);
    h.head.pointerMove(h.win, 2, 2);
    try h.update();
    try t.expect(h.app.root == null);
    try h.update();
}

test "headless: the app calls the backend only through Platform" {
    // A static check of the rule: app.zig must not name the headless backend.
    const src = @embedFile("../app.zig");
    try t.expect(std.mem.indexOf(u8, src, "headless") == null);
}
