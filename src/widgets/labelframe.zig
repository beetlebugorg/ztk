//! The labelframe class: a frame with a title. The modern theme draws the
//! title above the box of the frame, in the part `::label`, and the box
//! below it. The title adds its height to the top inset of the frame, so
//! `grid`, `pack`, and `place` keep the content below it. `-labelanchor`
//! puts the title at the left, the center, or the right, above the box
//! (an anchor that starts with `s` puts it below the box).
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const num = @import("../num.zig");
const geom = @import("../geom.zig");
const widget = @import("../widget.zig");
const options = @import("../options.zig");
const paint = @import("../paint.zig");
const scene = @import("../scene.zig");
const anim = @import("../anim.zig");
const style_mod = @import("../style.zig");
const App = @import("../app.zig").App;
const Spec = options.Spec;
const Widget = widget.Widget;

const anchor_words = [_][]const u8{ "e", "en", "es", "n", "ne", "nw", "s", "se", "sw", "w", "wn", "ws" };

/// The options of `wish` 8.6.16 for `labelframe`, in its order.
pub const specs = [_]Spec{
    .{ .name = "-bd", .type = .synonym, .target = "-borderwidth" },
    .{ .name = "-borderwidth", .db_name = "borderWidth", .db_class = "BorderWidth", .type = .pixels, .default = "0", .from_style = true, .style_prop = .border_width },
    .{ .name = "-class", .db_name = "class", .db_class = "Class", .type = .string, .default = "Labelframe", .create_only = true },
    .{ .name = "-fg", .type = .synonym, .target = "-foreground" },
    .{ .name = "-font", .db_name = "font", .db_class = "Font", .type = .font, .default = "TkDefaultFont" },
    .{ .name = "-foreground", .db_name = "foreground", .db_class = "Foreground", .type = .color, .default = "#000000", .from_style = true },
    .{ .name = "-labelanchor", .db_name = "labelAnchor", .db_class = "LabelAnchor", .type = .word, .default = "nw", .words = &anchor_words },
    .{ .name = "-labelwidget", .db_name = "labelWidget", .db_class = "LabelWidget", .type = .string, .allow_empty = true },
    .{ .name = "-relief", .db_name = "relief", .db_class = "Relief", .type = .relief, .default = "groove", .from_style = true },
    .{ .name = "-text", .db_name = "text", .db_class = "Text", .type = .string, .allow_empty = true },
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

pub const class: widget.Class = .{ .command = "labelframe", .tk_class = "Labelframe", .role = "group", .specs = &specs, .configured = configured, .measure = measure, .paint = paintFrame, .extra_insets = extraInsets };

fn text(w: *const Widget) []const u8 {
    const s = options.get(w, "-text");
    return if (s.set) s.text else "";
}

fn labelStyle(w: *Widget) style_mod.Style {
    w.app.ensureStyle(w);
    var st = w.app.styles.compute(w, "label", &w.style, w.app.env);
    // A -font or -foreground of the script is the font and the color of the title.
    const f = options.get(w, "-font");
    if (f.set) if (@import("../text/font.zig").Fonts.parseTk(f.text, st.font, w.app.scaling)) |d| {
        st.font = d;
    };
    const c = options.get(w, "-foreground");
    if (c.set and c.value == .color) st.color = c.value.color;
    return st;
}

/// The height of the title and the space under it.
fn titleHeight(w: *Widget) i32 {
    if (text(w).len == 0) return 0;
    const st = labelStyle(w);
    const ins = paint.insets(&st);
    return paint.textSize(w.app, text(w), st.font).h + ins.vertical();
}

fn below(w: *const Widget) bool {
    const v = options.get(w, "-labelanchor").value;
    if (v != .word) return false;
    return anchor_words[v.word][0] == 's';
}

fn extraInsets(w: *Widget) geom.Insets {
    const h = titleHeight(w);
    return if (below(w)) .{ .bottom = h } else .{ .top = h };
}

fn measure(w: *Widget) geom.Size {
    const wd = options.get(w, "-width").value;
    const ht = options.get(w, "-height").value;
    var size: geom.Size = .{ .w = if (wd == .pixels) wd.pixels else 0, .h = if (ht == .pixels) ht.pixels else 0 };
    // The title fits in the width.
    if (text(w).len > 0) {
        const st = labelStyle(w);
        size.w = @max(size.w, num.add(paint.textSize(w.app, text(w), st.font).w, paint.insets(&st).horizontal() + paint.insets(&w.style).horizontal()));
    }
    return size;
}

fn configured(w: *Widget, changed: []const usize) ztcl.Error!void {
    for (changed) |i| {
        if (std.mem.eql(u8, w.class.specs[i].name, "-class")) w.tk_class = w.opts[i].text;
    }
}

fn paintFrame(w: *Widget, b: *scene.Builder) anyerror!void {
    const st = anim.shown(w.app, w);
    const th = titleHeight(w);
    const box: geom.Rect = if (below(w)) .{ .x = 0, .y = 0, .w = w.geom.w, .h = w.geom.h - th } else .{ .x = 0, .y = th, .w = w.geom.w, .h = w.geom.h - th };
    try paint.styledBox(b, box, st);
    if (th == 0) return;
    const ls = labelStyle(w);
    const ins = paint.insets(&ls);
    const tr: geom.Rect = .{ .x = ins.left, .y = (if (below(w)) w.geom.h - th else 0) + ins.top, .w = w.geom.w - ins.horizontal(), .h = th - ins.vertical() };
    const v = options.get(w, "-labelanchor").value;
    const word = if (v == .word) anchor_words[v.word] else "nw";
    const anchor: options.Anchor = if (std.mem.indexOfScalar(u8, word, 'e') != null) .e else if (std.mem.eql(u8, word, "n") or std.mem.eql(u8, word, "s")) .center else .w;
    try paint.label(w, b, tr, text(w), &ls, anchor, .left);
}

pub fn register(app: *App) !void {
    try app.it.register("labelframe", widget.classCommand(&class));
    try app.classes.put(app.gpa, "labelframe", &class);
}
