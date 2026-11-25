//! Tests of the input method in the core: the backend hears of the text
//! widget with the focus and its box, a `commit` inserts its text in the
//! entry, and a `preedit` keeps the composition text for the widget.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Harness = @import("../testing.zig").Harness;
const t = std.testing;

test "ime: the backend hears of the text widget with the focus" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("button .b -text B; entry .e; pack .b .e; focus -force .b; update");
    try t.expect(!h.head.ime_on);
    _ = try h.eval("focus -force .e; update");
    try t.expect(h.head.ime_on);
    const e = h.app.find(".e").?;
    try t.expectEqual(e.geom.y, h.head.ime_rect.y);
    try t.expectEqual(e.geom.w, h.head.ime_rect.w);
    const calls = h.head.ime_calls;
    _ = try h.eval("update");
    // No change gives no call.
    try t.expectEqual(calls, h.head.ime_calls);
    _ = try h.eval("focus -force .b; update");
    try t.expect(!h.head.ime_on);
}

test "ime: a commit inserts its text and a preedit keeps the composition" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("entry .e; pack .e; focus -force .e; update");
    try h.head.imePreedit(h.win, "\u{306B}\u{307B}", 3);
    try h.update();
    try t.expectEqualStrings("\u{306B}\u{307B}", h.app.text_input.preedit.items);
    try t.expectEqual(@as(u32, 3), h.app.text_input.preedit_caret);
    try t.expect(h.app.text_input.preedit_widget == h.app.find(".e").?);
    try h.head.imeCommit(h.win, "\u{65E5}\u{672C}");
    try h.update();
    try t.expectEqualStrings("\u{65E5}\u{672C}", try h.eval(".e get"));
    // The commit ends the composition.
    try t.expectEqual(@as(usize, 0), h.app.text_input.preedit.items.len);
    try t.expect(h.app.text_input.preedit_widget == null);
}
