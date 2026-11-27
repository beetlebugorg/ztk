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
