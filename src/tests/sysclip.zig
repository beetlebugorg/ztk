//! Tests of the clipboard of the system through the backend. The headless
//! backend keeps the text of the last `clipboardSet`, and a test puts a
//! text there in the place of another program. `clipboard get` and the paste of
//! an entry read that text, and a new append of the App replaces it.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Harness = @import("../testing.zig").Harness;
const t = std.testing;

test "sysclip: clipboard append and clear give the text to the backend" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("clipboard clear; clipboard append hello; clipboard append { world}");
    try t.expectEqualStrings("hello world", h.head.clip_set.items);
    _ = try h.eval("clipboard clear");
    try t.expectEqualStrings("", h.head.clip_set.items);
}

test "sysclip: the text of another program comes first, until the next append" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("clipboard clear; clipboard append mine");
    h.head.clip_foreign = "from another program";
    try t.expectEqualStrings("from another program", try h.eval("clipboard get"));
    // A type other than text stays in the store of the App.
    _ = try h.eval("clipboard append -type FILE_NAME a.txt");
    try t.expectEqualStrings("a.txt", try h.eval("clipboard get -type FILE_NAME"));
    // The append gave the store to the backend again, so the App's text is the latest.
    try t.expectEqualStrings("mine", try h.eval("clipboard get"));
}

test "sysclip: an entry pastes the text of another program and copies to the backend" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("entry .e; pack .e; focus -force .e; update");
    h.head.clip_foreign = "pasted";
    _ = try h.eval("event generate .e <<Paste>>; update");
    try t.expectEqualStrings("pasted", try h.eval(".e get"));
    _ = try h.eval(".e selection range 0 3; event generate .e <<Copy>>");
    try t.expectEqualStrings("pas", h.head.clip_set.items);
}
