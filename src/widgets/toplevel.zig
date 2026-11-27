//! The toplevel class. "." is the first toplevel, and `App.init` makes it.
//! The command `toplevel` makes another one: a widget with its own
//! platform window, its own render thread, and its own window manager
//! state (`App.Top`, in the `data` of the widget). Its children lay out
//! and paint in its window, and the events of its window go to it. Its
//! requested size sets the size of its window, as for ".".
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const widget = @import("../widget.zig");
const anim = @import("../anim.zig");
const paint = @import("../paint.zig");
const scene = @import("../scene.zig");
const options = @import("../options.zig");
const geom = @import("../base/geom.zig");
const render_thread = @import("../render/thread.zig");
const app_mod = @import("../app.zig");
const Window = @import("../platform/platform.zig").Window;
const Spec = options.Spec;

/// The options of `wish` 8.6.16 for `toplevel`, in its order.
pub const specs = [_]Spec{
    .{ .name = "-bd", .type = .synonym, .target = "-borderwidth" },
    .{ .name = "-borderwidth", .db_name = "borderWidth", .db_class = "BorderWidth", .type = .pixels, .default = "0", .from_style = true, .style_prop = .border_width },
    .{ .name = "-class", .db_name = "class", .db_class = "Class", .type = .string, .default = "Toplevel", .create_only = true },
    .{ .name = "-menu", .db_name = "menu", .db_class = "Menu", .type = .string, .allow_empty = true },
    .{ .name = "-relief", .db_name = "relief", .db_class = "Relief", .type = .relief, .default = "flat", .from_style = true },
    .{ .name = "-screen", .db_name = "screen", .db_class = "Screen", .type = .string, .allow_empty = true, .create_only = true },
    .{ .name = "-use", .db_name = "use", .db_class = "Use", .type = .string, .allow_empty = true, .create_only = true },
    .{ .name = "-background", .db_name = "background", .db_class = "Background", .type = .color, .default = "#d9d9d9", .from_style = true, .style_prop = .background },
    .{ .name = "-bg", .type = .synonym, .target = "-background" },
    .{ .name = "-colormap", .db_name = "colormap", .db_class = "Colormap", .type = .string, .allow_empty = true, .create_only = true },
    .{ .name = "-container", .db_name = "container", .db_class = "Container", .type = .boolean, .default = "0", .create_only = true },
    .{ .name = "-cursor", .db_name = "cursor", .db_class = "Cursor", .type = .string, .allow_empty = true },
    .{ .name = "-height", .db_name = "height", .db_class = "Height", .type = .pixels, .default = "0" },
    .{ .name = "-highlightbackground", .db_name = "highlightBackground", .db_class = "HighlightBackground", .type = .color, .default = "#d9d9d9" },
    .{ .name = "-highlightcolor", .db_name = "highlightColor", .db_class = "HighlightColor", .type = .color, .default = "#000000" },
    .{ .name = "-highlightthickness", .db_name = "highlightThickness", .db_class = "HighlightThickness", .type = .pixels, .default = "0" },
    .{ .name = "-padx", .db_name = "padX", .db_class = "Pad", .type = .pixels, .default = "0" },
    .{ .name = "-pady", .db_name = "padY", .db_class = "Pad", .type = .pixels, .default = "0" },
    .{ .name = "-takefocus", .db_name = "takeFocus", .db_class = "TakeFocus", .type = .string, .default = "0" },
    .{ .name = "-visual", .db_name = "visual", .db_class = "Visual", .type = .string, .allow_empty = true, .create_only = true },
    .{ .name = "-width", .db_name = "width", .db_class = "Width", .type = .pixels, .default = "0" },
};

/// The class of a toplevel other than ".".
pub const class: widget.Class = .{ .command = "toplevel", .tk_class = "Toplevel", .role = "window", .is_toplevel = true, .specs = &specs, .init = init, .teardown = teardown, .deinit = freeTop, .configured = configured, .measure = measure, .paint = paintBox, .extra_insets = barInsets };

/// The class of ".". Its `data` is the platform window.
/// It has the options of `toplevel`, so `. configure -menu` works.
pub const root_class: widget.Class = .{ .command = "toplevel", .tk_class = "Toplevel", .role = "window", .is_toplevel = true, .specs = &specs, .configured = configured, .deinit = deinitRoot, .paint = paintBox, .extra_insets = barInsets };

/// The row of a drawn menu bar goes above the content.
fn barInsets(w: *widget.Widget) geom.Insets {
    return @import("menudraw.zig").barInsets(w);
}

fn paintBox(w: *widget.Widget, b: *scene.Builder) anyerror!void {
    try paint.box(w, b, anim.shown(w.app, w));
}

fn measure(w: *widget.Widget) geom.Size {
    const wd = options.get(w, "-width").value;
    const ht = options.get(w, "-height").value;
    return .{ .w = if (wd == .pixels) wd.pixels else 0, .h = if (ht == .pixels) ht.pixels else 0 };
}

fn configured(w: *widget.Widget, changed: []const usize) ztcl.Error!void {
    for (changed) |i| {
        if (std.mem.eql(u8, w.class.specs[i].name, "-class")) w.tk_class = w.opts[i].text;
        if (std.mem.eql(u8, w.class.specs[i].name, "-menu")) {
            try @import("menu.zig").setBar(w, w.opts[i].text);
            w.invalidate(.{ .style = false, .measure = true, .layout = true, .paint = true });
        }
    }
}

/// Makes the window and the render thread of a toplevel other than ".".
fn init(w: *widget.Widget) anyerror!void {
    const app = w.app;
    const win = try app.platform.createWindow(.{ .size = .{ .w = 200, .h = 200 }, .dark = app.env.dark });
    errdefer app.platform.destroyWindow(win);
    win.user = w;
    if (app.window) |main| win.scale = main.scale;
    const mode: render_thread.Mode = if (app.render_ready) app.render.mode else .inline_draw;
    const r = try app.takeRender(mode, app.platform.target(win));
    errdefer app.giveRender(r);
    const t = try app.gpa.create(app_mod.Top);
    t.* = .{ .win = win, .render = r };
    errdefer app.gpa.destroy(t);
    try app.tops.append(app.gpa, w);
    w.data = t;
    w.mapped = true;
    w.geom = .{ .w = win.size.w, .h = win.size.h };
    win.render.store(r, .release);
    app.requestFrame();
}

/// Ends the window at `destroy`: the render thread ends first, because it
/// can draw into the surface of the window.
fn teardown(w: *widget.Widget) void {
    const app = w.app;
    for (app.tops.items, 0..) |x, i| if (x == w) {
        _ = app.tops.orderedRemove(i);
        break;
    };
    const t: *app_mod.Top = @ptrCast(@alignCast(w.data orelse return));
    t.win.render.store(null, .release);
    app.giveRender(t.render);
    app.platform.destroyWindow(t.win);
    t.wm.deinit(app.gpa);
    app.gpa.destroy(t);
    w.data = null;
}

fn freeTop(w: *widget.Widget) void {
    if (w.data != null) teardown(w);
}

fn deinitRoot(w: *widget.Widget) void {
    const app = w.app;
    const win: *Window = @ptrCast(@alignCast(w.data orelse return));
    // `flush` does not wait for a draw of the held frame, which a running
    // animation repeats. `retarget` waits for that draw and drops the held
    // frame, so the render thread draws no more into the surface.
    if (app.render_ready) {
        win.render.store(null, .release);
        app.render.retarget(app_mod.App.idle_target);
    }
    if (app.window == win) app.window = null;
    app.platform.destroyWindow(win);
    w.data = null;
}

/// Registers the command `toplevel`.
pub fn register(app: *app_mod.App) !void {
    try app.it.register("toplevel", widget.classCommand(&class));
    try app.classes.put(app.gpa, "toplevel", &class);
}
