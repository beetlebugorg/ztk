//! The toplevel class. Stage 1 has only ".", which App.init makes.
//! SPDX-License-Identifier: BSD-2-Clause

const widget = @import("../widget.zig");
const anim = @import("../anim.zig");
const paint = @import("../paint.zig");
const scene = @import("../scene.zig");
const Window = @import("../platform/platform.zig").Window;

pub const class: widget.Class = .{ .command = "toplevel", .tk_class = "Toplevel", .role = "window", .is_toplevel = true, .deinit = deinit, .paint = paintBox };

fn paintBox(w: *widget.Widget, b: *scene.Builder) anyerror!void {
    try paint.box(w, b, anim.shown(w.app, w));
}

/// Gives the window back to the backend. `data` holds the window. The
/// render thread can draw into the surface of the window, so it must
/// finish its frames first.
fn deinit(w: *widget.Widget) void {
    const win: *Window = @ptrCast(@alignCast(w.data orelse return));
    if (w.app.render_ready) w.app.render.flush();
    if (w.app.window == win) w.app.window = null;
    w.app.platform.destroyWindow(win);
    w.data = null;
}
