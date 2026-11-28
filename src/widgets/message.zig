//! The message class: a label that breaks its text into lines. With a
//! `-width` above 0 the lines are at most that wide. Otherwise the width
//! follows `-aspect`, the ratio of width to height in percent: the class
//! tries widths from the narrowest to the widest and keeps the first one
//! whose wrapped text has a ratio at least `-aspect` / 100. The text
//! comes from `-text` or from `-textvariable`, as for a label.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const num = @import("../base/num.zig");
const geom = @import("../base/geom.zig");
const widget = @import("../widget.zig");
const options = @import("../options.zig");
const paint = @import("../paint.zig");
const scene = @import("../scene.zig");
const anim = @import("../anim.zig");
const label = @import("label.zig");
const style_mod = @import("../style.zig");
const App = @import("../app.zig").App;
const Spec = options.Spec;
const Widget = widget.Widget;

/// The options of `wish` 8.6.16 for `message`, in its order.
pub const specs = [_]Spec{
    .{ .name = "-anchor", .db_name = "anchor", .db_class = "Anchor", .type = .anchor, .default = "center" },
    .{ .name = "-aspect", .db_name = "aspect", .db_class = "Aspect", .type = .int, .default = "150" },
    .{ .name = "-background", .db_name = "background", .db_class = "Background", .type = .color, .default = "#d9d9d9", .from_style = true, .style_prop = .background },
    .{ .name = "-bd", .type = .synonym, .target = "-borderwidth" },
    .{ .name = "-bg", .type = .synonym, .target = "-background" },
    .{ .name = "-borderwidth", .db_name = "borderWidth", .db_class = "BorderWidth", .type = .pixels, .default = "0", .from_style = true, .style_prop = .border_width },
    .{ .name = "-cursor", .db_name = "cursor", .db_class = "Cursor", .type = .cursor, .allow_empty = true },
    .{ .name = "-fg", .type = .synonym, .target = "-foreground" },
    .{ .name = "-font", .db_name = "font", .db_class = "Font", .type = .font, .default = "TkDefaultFont" },
    .{ .name = "-foreground", .db_name = "foreground", .db_class = "Foreground", .type = .color, .default = "#000000", .from_style = true },
    .{ .name = "-highlightbackground", .db_name = "highlightBackground", .db_class = "HighlightBackground", .type = .color, .default = "#d9d9d9" },
    .{ .name = "-highlightcolor", .db_name = "highlightColor", .db_class = "HighlightColor", .type = .color, .default = "#000000" },
    .{ .name = "-highlightthickness", .db_name = "highlightThickness", .db_class = "HighlightThickness", .type = .pixels, .default = "0" },
    .{ .name = "-justify", .db_name = "justify", .db_class = "Justify", .type = .justify, .default = "left" },
    .{ .name = "-padx", .db_name = "padX", .db_class = "Pad", .type = .pixels, .default = "-1" },
    .{ .name = "-pady", .db_name = "padY", .db_class = "Pad", .type = .pixels, .default = "-1" },
    .{ .name = "-relief", .db_name = "relief", .db_class = "Relief", .type = .relief, .default = "flat", .from_style = true },
    .{ .name = "-takefocus", .db_name = "takeFocus", .db_class = "TakeFocus", .type = .string, .default = "0" },
    .{ .name = "-text", .db_name = "text", .db_class = "Text", .type = .string, .allow_empty = true },
    .{ .name = "-textvariable", .db_name = "textVariable", .db_class = "Variable", .type = .variable, .allow_empty = true },
    .{ .name = "-width", .db_name = "width", .db_class = "Width", .type = .pixels, .default = "0" },
};

pub const class: widget.Class = .{
    .command = "message",
    .tk_class = "Message",
    .role = "label",
    .specs = &specs,
    .init = label.init,
    .deinit = label.deinit,
    .teardown = label.teardown,
    .configured = label.configured,
    .retrace = label.retrace,
    .trace_command = label.trace_command,
    .traced_var = label.tracedVar,
    .variable_text = label.variableText,
    .measure = measure,
    .paint = paintMessage,
};

/// The line width of the text.
fn lineWidth(w: *Widget) i32 {
    const app = w.app;
    const st = &w.style;
    const wd = options.get(w, "-width").value;
    if (wd == .pixels and wd.pixels > 0) return wd.pixels;
    const asp = options.get(w, "-aspect").value;
    const aspect: f64 = @floatFromInt(@max(if (asp == .int) asp.int else 150, 1));
    const a = app.it.alloc();
    const full = paint.textSize(app, label.text(w), st.font);
    if (full.w <= 0) return 0;
    // Try 24 widths from narrow to the full width.
    var k: i32 = 1;
    while (k <= 24) : (k += 1) {
        const tw = @max(@divTrunc(full.w * k, 24), 1);
        const lines = paint.wrapLines(app, a, label.text(w), st.font, tw) catch return full.w;
        const s = paint.linesSize(app, lines, st.font);
        if (s.h > 0 and @as(f64, @floatFromInt(s.w)) * 100 >= aspect * @as(f64, @floatFromInt(s.h))) return tw;
    }
    return full.w;
}

fn measure(w: *Widget) geom.Size {
    const app = w.app;
    app.ensureStyle(w);
    const st = &w.style;
    const lines = paint.wrapLines(app, app.it.alloc(), label.text(w), st.font, lineWidth(w)) catch &.{};
    var size = paint.linesSize(app, lines, st.font);
    const wd = options.get(w, "-width").value;
    if (wd == .pixels and wd.pixels > 0) size.w = wd.pixels;
    const ins = paint.insets(st);
    return .{ .w = num.add(size.w, ins.horizontal()), .h = num.add(size.h, ins.vertical()) };
}

fn paintMessage(w: *Widget, b: *scene.Builder) anyerror!void {
    const app = w.app;
    const st = anim.shown(app, w);
    try paint.box(w, b, st);
    const lines = try paint.wrapLines(app, app.it.alloc(), label.text(w), st.font, lineWidth(w));
    const joined = try std.mem.join(app.it.alloc(), "\n", lines);
    const an = options.get(w, "-anchor").value;
    const ju = options.get(w, "-justify").value;
    try paint.label(w, b, paint.contentRect(w, st), joined, st, if (an == .anchor) an.anchor else .center, if (ju == .justify) ju.justify else .left);
}

pub fn register(app: *App) !void {
    try app.it.register("message", widget.classCommand(&class));
    try app.classes.put(app.gpa, "message", &class);
}
