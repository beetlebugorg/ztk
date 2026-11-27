//! The frame class. A frame has no content of its own. The command
//! `frame` makes the widget, then applies the options of the command line.
//! The option `-class` sets the class name at creation. The table of
//! specs gives `configure` and `cget`.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const widget = @import("../widget.zig");
const anim = @import("../anim.zig");
const options = @import("../options.zig");
const geom = @import("../base/geom.zig");
const paint = @import("../paint.zig");
const scene = @import("../scene.zig");
const App = @import("../app.zig").App;
const Spec = options.Spec;

/// The options of `wish`, in the order of `wish`. `-colormap`,
/// `-container`, `-visual`, and the highlight options are stored and have
/// no effect.
pub const specs = [_]Spec{
    .{ .name = "-bd", .type = .synonym, .target = "-borderwidth" },
    .{ .name = "-borderwidth", .db_name = "borderWidth", .db_class = "BorderWidth", .type = .pixels, .default = "0", .from_style = true, .style_prop = .border_width },
    .{ .name = "-class", .db_name = "class", .db_class = "Class", .type = .string, .default = "Frame", .create_only = true },
    .{ .name = "-relief", .db_name = "relief", .db_class = "Relief", .type = .relief, .default = "flat", .from_style = true },
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

pub const class: widget.Class = .{ .command = "frame", .tk_class = "Frame", .role = "group", .specs = &specs, .configured = configured, .measure = measure, .paint = paintBox };

fn paintBox(w: *widget.Widget, b: *scene.Builder) anyerror!void {
    try paint.box(w, b, anim.shown(w.app, w));
}

/// The size that `-width` and `-height` give.
fn measure(w: *widget.Widget) geom.Size {
    const wd = options.get(w, "-width").value;
    const ht = options.get(w, "-height").value;
    return .{ .w = if (wd == .pixels) wd.pixels else 0, .h = if (ht == .pixels) ht.pixels else 0 };
}

fn configured(w: *widget.Widget, changed: []const usize) ztcl.Error!void {
    for (changed) |i| {
        if (std.mem.eql(u8, w.class.specs[i].name, "-class")) w.tk_class = w.opts[i].text;
    }
}
