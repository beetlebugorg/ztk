//! Tests of `tk_getOpenFile`, `tk_getSaveFile`, and `tk_chooseDirectory`
//! on the fake dialog of the headless backend, which records the options
//! and gives the answer of the test.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const Harness = @import("../testing.zig").Harness;
const t = std.testing;

fn allowFiles(h: *Harness) !void {
    try h.it.allow(@intFromEnum(ztcl.interp.Capability.file));
}

test "filedialog: an open with filters, a type variable, and the paths" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try allowFiles(&h);
    h.head.dialog_answer = &.{"C:/work/a.tcl"};
    h.head.dialog_filter = 1;
    try t.expectEqualStrings("C:/work/a.tcl", try h.eval("tk_getOpenFile -title Pick -filetypes {{Text {.txt}} {Scripts {.tcl .tk}} {All *}} -typevariable ::type"));
    try t.expect(h.head.dialog_kind.? == .open);
    try t.expectEqualStrings("Pick", h.head.dialog_title.items);
    try t.expectEqual(@as(usize, 3), h.head.dialog_filters);
    try t.expectEqualStrings("Scripts", try h.eval("set ::type"));
    h.head.dialog_answer = &.{ "C:/a b.txt", "C:/c.txt" };
    try t.expectEqualStrings("{C:/a b.txt} C:/c.txt", try h.eval("tk_getOpenFile -multiple 1"));
    try t.expect(h.head.dialog_multiple);
    // A cancel gives an empty string.
    h.head.dialog_answer = null;
    try t.expectEqualStrings("", try h.eval("tk_getOpenFile"));
}

test "filedialog: a save with a default extension, and a folder" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try allowFiles(&h);
    h.head.dialog_answer = &.{"C:/out/report.csv"};
    try t.expectEqualStrings("C:/out/report.csv", try h.eval("tk_getSaveFile -defaultextension .csv -confirmoverwrite 0"));
    try t.expect(h.head.dialog_kind.? == .save);
    try t.expectEqualStrings("csv", std.mem.sliceTo(&h.head.dialog_ext, 0));
    h.head.dialog_answer = &.{"C:/out"};
    try t.expectEqualStrings("C:/out", try h.eval("tk_chooseDirectory -mustexist 1 -title Folder"));
    try t.expect(h.head.dialog_kind.? == .folder);
}

test "filedialog: the errors of the options and of the capability" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try t.expectEqualStrings("the file dialogs need the file capability", try h.evalError("tk_getOpenFile"));
    try allowFiles(&h);
    try t.expectEqualStrings("bad option \"-multiple\": must be -initialdir, -mustexist, -parent, or -title", try h.evalError("tk_chooseDirectory -multiple 1"));
    try t.expectEqualStrings("bad window path name \".nope\"", try h.evalError("tk_getSaveFile -parent .nope"));
    try t.expectEqualStrings("value for \"-title\" missing", try h.evalError("tk_getOpenFile -title"));
}
