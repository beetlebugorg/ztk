//! Tests of `ztk::hotkey` with the headless backend, which records the
//! shortcuts and queues a press for a test.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Harness = @import("../testing.zig").Harness;
const t = std.testing;

test "hotkey: add, a press, names, and remove" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try t.expectEqualStrings("global shortcuts need a grant of the embedder (ztk --allow hotkey)", try h.evalError("ztk::hotkey add <Control-Alt-k> {set ::got 1}"));
    h.app.hotkeys_allowed = true;
    try t.expectEqualStrings("hotkey1", try h.eval("ztk::hotkey add <Control-Alt-k> {incr ::got}"));
    const r = h.head.hotkeys.items[0];
    try t.expect(r.mods.control and r.mods.mod1 and !r.mods.shift);
    try t.expectEqual(@as(u32, 'k'), r.keysym);
    _ = try h.eval("set ::got 0");
    h.head.hotkeyPress(r.id);
    h.head.hotkeyPress(r.id);
    try h.update();
    try t.expectEqualStrings("2", try h.eval("set ::got"));
    try t.expectEqualStrings("hotkey2", try h.eval("ztk::hotkey add Super-F5 {}"));
    try t.expectEqualStrings("hotkey1 hotkey2", try h.eval("ztk::hotkey names"));
    _ = try h.eval("ztk::hotkey remove hotkey1");
    try t.expectEqual(@as(usize, 1), h.head.hotkeys.items.len);
    try t.expectEqualStrings("hotkey2", try h.eval("ztk::hotkey names"));
}

test "hotkey: the errors of a shortcut" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.app.hotkeys_allowed = true;
    try t.expectEqualStrings("bad shortcut \"Hyper-k\"", try h.evalError("ztk::hotkey add Hyper-k {}"));
    h.head.hotkey_taken = 'j';
    try t.expectEqualStrings("the system refused the shortcut \"Control-j\": another app may have it", try h.evalError("ztk::hotkey add Control-j {}"));
    try t.expectEqualStrings("shortcut \"hotkey9\" doesn't exist", try h.evalError("ztk::hotkey remove hotkey9"));
    try t.expectEqualStrings("bad option \"list\": must be add, names, or remove", try h.evalError("ztk::hotkey list"));
}
