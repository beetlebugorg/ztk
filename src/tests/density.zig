//! Tests of `-density` of a photo image: an image of 2x pixels lays out
//! at its logical size, and its pixels reach the screen 1:1 at scale 2.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Harness = @import("../testing.zig").Harness;
const t = std.testing;

test "density: a 2x photo has the logical size of half its pixels" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval(
        \\image create photo icon -width 32 -height 32 -density 2
        \\icon put red -to 0 0 32 32
        \\label .l -image icon -borderwidth 0 -padx 0 -pady 0 -highlightthickness 0
        \\pack .l
        \\update
    );
    try t.expectEqualStrings("16 16", try h.eval("list [image width icon] [image height icon]"));
    try t.expectEqualStrings("2", try h.eval("icon cget -density"));
    try t.expectEqualStrings("16 16", try h.eval("list [winfo reqwidth .l] [winfo reqheight .l]"));
    try t.expectEqualStrings("bad density \"5\": must be 1 to 4", try h.evalError("icon configure -density 5"));
    // The default is 1: the pixels are the logical size.
    _ = try h.eval("image create photo plain -width 32 -height 32");
    try t.expectEqualStrings("32 1", try h.eval("list [image width plain] [plain cget -density]"));
}

test "density: a canvas image of a 2x photo has its logical size and draws 1:1 at scale 2" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval(
        \\wm geometry . 40x40
        \\image create photo icon -width 32 -height 32 -density 2
        \\icon put red -to 0 0 32 32
        \\icon put blue -to 1 0 2 32
        \\canvas .c -width 40 -height 40 -borderwidth 0 -highlightthickness 0 -background white
        \\pack .c
        \\.c create image 4 4 -image icon -anchor nw
        \\update
    );
    try t.expectEqualStrings("4 4 20 20", try h.eval(".c bbox all"));
    h.head.setScale(h.win, 2);
    try h.update();
    const img = h.head.image(h.win).?;
    // The photo starts at the device pixel 8. Its second column is blue
    // and one device pixel wide.
    const row = img.pixels[(10 * img.width + 8) * 4 ..];
    try t.expectEqualSlices(u8, &.{ 255, 0, 0 }, row[0..3]);
    try t.expectEqualSlices(u8, &.{ 0, 0, 255 }, row[4..7]);
    try t.expectEqualSlices(u8, &.{ 255, 0, 0 }, row[8..11]);
    // The photo ends at the device pixel 40: 32 pixels wide.
    try t.expectEqualSlices(u8, &.{ 255, 0, 0 }, row[31 * 4 ..][0..3]);
    try t.expectEqualSlices(u8, &.{ 255, 255, 255 }, row[32 * 4 ..][0..3]);
}
