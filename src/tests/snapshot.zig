//! Tests of `ztk::snapshot` and `ztk::tree` on the headless backend.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Harness = @import("../testing.zig").Harness;
const t = std.testing;

/// The width and the height in the IHDR chunk of a PNG file.
fn pngSize(b64: []const u8) ![2]u32 {
    var buf: [65536]u8 = undefined;
    const dec = std.base64.standard.Decoder;
    const n = try dec.calcSizeForSlice(b64);
    try dec.decode(buf[0..n], b64);
    try t.expectEqualSlices(u8, "\x89PNG\r\n\x1a\n", buf[0..8]);
    return .{ std.mem.readInt(u32, buf[16..20], .big), std.mem.readInt(u32, buf[20..24], .big) };
}

test "snapshot: a PNG of a widget and of the window" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("wm geometry . 200x100; frame .f -width 60 -height 40 -background red; place .f -x 10 -y 20; update");
    const sz = try pngSize(try h.eval("ztk::snapshot .f"));
    try t.expectEqual(@as(u32, 60), sz[0]);
    try t.expectEqual(@as(u32, 40), sz[1]);
    // The pixels of the frame are red.
    try t.expectEqualStrings("255 0 0", try h.eval("image create photo shot -data [ztk::snapshot .f]; shot get 30 20"));
    const all = try pngSize(try h.eval("ztk::snapshot ."));
    try t.expectEqual(@as(u32, 200), all[0]);
    try t.expectEqual(@as(u32, 100), all[1]);
    try t.expectEqualStrings("bad window path name \".nope\"", try h.evalError("ztk::snapshot .nope"));
    try t.expectEqualStrings("wrong # args: should be \"ztk::snapshot pathName\"", try h.evalError("ztk::snapshot"));
}

test "tree: the widgets with their geometry" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("wm geometry . 200x100; frame .f -width 60 -height 40; place .f -x 10 -y 20; label .f.l -text hi; place .f.l -x 5 -y 6 -width 30 -height 10; update");
    try t.expectEqualStrings("{.f Frame 10 20 60 40 1} {.f.l Label 15 26 30 10 1}", try h.eval("ztk::tree .f"));
    try t.expectEqualStrings(". Ztk 0 0 200 100 1", try h.eval("lindex [ztk::tree] 0"));
}
