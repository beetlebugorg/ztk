//! A look at the Fluent sheet of Windows with the text of DirectWrite:
//! the controls in light and dark, written to
//! .zig-cache/fluent-look-light.png and -dark.png when ZTK_FLUENT_LOOK
//! is set. It runs on the headless backend, so no window opens.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const t = std.testing;
const Harness = @import("../testing.zig").Harness;
const dwrite = @import("../platform/dwrite.zig");
const png = @import("../png.zig");

fn look(dark: bool, path: []const u8) !void {
    const d = dwrite.DWrite.init(t.allocator) orelse return error.SkipZigTest;
    defer d.deinit();
    var h: Harness = undefined;
    h.render_mode = .inline_draw;
    h.animations = false;
    h.dark = dark;

    try h.initFull(null, "windows", d.backend());
    defer h.deinit();
    _ = try h.eval(
        \\wm geometry . 420x300
        \\button .b -text Button
        \\button .p -text Accent; ztk::class .p add primary
        \\button .d -text Disabled -state disabled
        \\grid .b .p .d -padx 6 -pady 8
        \\entry .e; .e insert 0 {Text box}
        \\entry .f; .f insert 0 Focused
        \\grid .e .f -padx 6 -pady 8 -columnspan 1
        \\checkbutton .c1 -text Checked; .c1 select
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

test "fluent look: the controls in light and dark" {
    if (!(t.environ.contains(t.allocator, "ZTK_FLUENT_LOOK") catch false)) return error.SkipZigTest;
    try look(false, ".zig-cache/fluent-look-light.png");
    try look(true, ".zig-cache/fluent-look-dark.png");
}
