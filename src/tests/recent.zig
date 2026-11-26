//! Tests of `ztk::recent` with the headless backend, which records the
//! paths of `recentAdd` and counts the clears.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const Harness = @import("../testing.zig").Harness;
const t = std.testing;

test "recent: add gives the full host path to the backend, and clear empties it" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try t.expectEqualStrings("1", try h.eval("ztk::has recent"));
    // With no file capability, add is an error, and clear works.
    try t.expectEqualStrings("ztk::recent add needs the file commands with the real paths of the host", try h.evalError("ztk::recent add a.txt"));
    _ = try h.eval("ztk::recent clear");
    try t.expectEqual(@as(u32, 1), h.head.recent_clears);
    try h.it.allow(@intFromEnum(ztcl.interp.Capability.file));
    try ztcl.fsroot.setHost(&h.it);
    _ = try h.eval("ztk::recent add docs/../a.txt");
    try t.expectEqual(@as(usize, 1), h.head.recent.items.len);
    const want = try h.eval("file join [pwd] a.txt");
    try t.expectEqualStrings(want, h.head.recent.items[0]);
    _ = try h.eval("ztk::recent clear");
    try t.expectEqual(@as(usize, 0), h.head.recent.items.len);
    try t.expectEqual(@as(u32, 2), h.head.recent_clears);
}

test "recent: the errors of the arguments" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try t.expectEqualStrings("bad option \"list\": must be add or clear", try h.evalError("ztk::recent list"));
    try t.expectEqualStrings("wrong # args: should be \"ztk::recent add path\"", try h.evalError("ztk::recent add"));
}
