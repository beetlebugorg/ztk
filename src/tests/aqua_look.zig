//! A look at the Aqua sheet of macOS with the text of Core Text: the
//! controls in light and dark, written to .zig-cache/aqua-look-light.png
//! and -dark.png when ZTK_AQUA_LOOK is set, at the scale of 2. It runs on
//! the headless backend, so no window opens.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const t = std.testing;
const Harness = @import("../testing.zig").Harness;
const png = @import("../png.zig");

fn look(dark: bool, path: []const u8) !void {
    if (comptime builtin.os.tag != .macos or !@import("build_options").appkit) return error.SkipZigTest;
    const ct = @import("../platform/coretext.zig");
    const c = ct.CoreText.init(t.allocator) orelse return error.SkipZigTest;
    defer c.deinit();
    var h: Harness = undefined;
    h.render_mode = .inline_draw;
    h.animations = false;
    h.dark = dark;
    try h.initFull(null, "macos", c.backend());
    defer h.deinit();
    h.head.setScale(h.win, 2);
    _ = try h.eval(
        \\wm geometry . 420x300
        \\button .b -text Button
        \\button .p -text Default; ztk::class .p add primary
        \\button .d -text Disabled -state disabled
        \\grid .b .p .d -padx 6 -pady 8
        \\entry .e; .e insert 0 {Text field}
        \\entry .f; .f insert 0 Focused
        \\grid .e .f -padx 6 -pady 8 -columnspan 1
        \\checkbutton .c1 -text {Check box}; .c1 select
        \\checkbutton .c2 -text Unchecked
        \\radiobutton .r1 -text Radio -value 1 -variable v; set v 1
        \\grid .c1 .c2 .r1 -padx 6 -pady 6 -sticky w
        \\checkbutton .s -text Switch; ztk::class .s add switch; .s select
        \\scale .sc -orient horizontal -from 0 -to 100; .sc set 40
        \\grid .s .sc -padx 6 -pady 6 -sticky w
        \\focus .f
    );
    try h.update();
    const img = h.head.image(h.win).?;
    const bytes = try png.encode(t.allocator, img);
    defer t.allocator.free(bytes);
    try std.Io.Dir.cwd().writeFile(t.io, .{ .sub_path = path, .data = bytes });
}

test "aqua look: the controls in light and dark" {
    if (!(t.environ.contains(t.allocator, "ZTK_AQUA_LOOK") catch false)) return error.SkipZigTest;
    try look(false, ".zig-cache/aqua-look-light.png");
    try look(true, ".zig-cache/aqua-look-dark.png");
}

test "aqua look: the platform sheet of macOS" {
    // The sizes of the sheet assume the system font of Core Text (a line
    // of 16 points at 13 points).
    if (comptime builtin.os.tag != .macos or !@import("build_options").appkit) return error.SkipZigTest;
    const ct = @import("../platform/coretext.zig");
    const c = ct.CoreText.init(t.allocator) orelse return error.SkipZigTest;
    defer c.deinit();
    var h: Harness = undefined;
    h.render_mode = .inline_draw;
    try h.initFull(null, "macos", c.backend());
    defer h.deinit();
    _ = try h.eval("button .b -text Button; pack .b; update");
    // 24 points high, as NSButton of the regular size.
    try t.expectEqualStrings("24", try h.eval("winfo height .b"));
}
