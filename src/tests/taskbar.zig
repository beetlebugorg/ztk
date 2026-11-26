//! Tests of `ztk::taskbar` with the headless backend, which records the
//! last state of the button and counts the requests for attention.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Harness = @import("../testing.zig").Harness;
const t = std.testing;

test "taskbar: progress, badge, and attention reach the backend" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try t.expectEqualStrings("1", try h.eval("ztk::has taskbar"));
    try t.expectEqualStrings("none", try h.eval("ztk::taskbar progress"));
    _ = try h.eval("ztk::taskbar progress 0.25");
    try t.expect(h.head.taskbar.progress == .normal);
    try t.expectEqual(@as(f32, 0.25), h.head.taskbar.value);
    try t.expectEqualStrings("0.25", try h.eval("ztk::taskbar progress"));
    _ = try h.eval("ztk::taskbar progress 0.5 -state paused");
    try t.expect(h.head.taskbar.progress == .paused);
    _ = try h.eval("ztk::taskbar badge 12");
    // The badge keeps the progress.
    try t.expectEqual(@as(u32, 12), h.head.taskbar.badge);
    try t.expect(h.head.taskbar.progress == .paused);
    try t.expectEqualStrings("12", try h.eval("ztk::taskbar badge"));
    _ = try h.eval("ztk::taskbar progress indeterminate");
    try t.expect(h.head.taskbar.progress == .indeterminate);
    _ = try h.eval("ztk::taskbar progress none; ztk::taskbar badge 0");
    try t.expect(h.head.taskbar.progress == .none);
    try t.expectEqual(@as(u32, 0), h.head.taskbar.badge);
    _ = try h.eval("ztk::taskbar attention");
    try t.expect(!h.head.attention_critical);
    _ = try h.eval("ztk::taskbar attention -critical");
    try t.expect(h.head.attention_critical);
    try t.expectEqual(@as(u32, 2), h.head.attentions);
}

test "taskbar: the errors of the arguments" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try t.expectEqualStrings("expected a number from 0 to 1, none, or indeterminate but got \"2\"", try h.evalError("ztk::taskbar progress 2"));
    try t.expectEqualStrings("bad state \"done\": must be error, normal, or paused", try h.evalError("ztk::taskbar progress 0.1 -state done"));
    try t.expectEqualStrings("-state needs a value from 0 to 1", try h.evalError("ztk::taskbar progress none -state paused"));
    try t.expectEqualStrings("expected a count of 0 or more but got \"-1\"", try h.evalError("ztk::taskbar badge -1"));
    try t.expectEqualStrings("bad option \"spin\": must be attention, badge, or progress", try h.evalError("ztk::taskbar spin"));
}
