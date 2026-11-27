//! The items of the canvas: the option table of each item type with the
//! names and defaults of `wish` 8.6.16, the parse of an option into the
//! attributes that the paint reads, the bounding box of `bbox` with the
//! rules of Tk, and the distance from a point to an item for `find
//! closest` and for the current item. The stipple options and `-offset`
//! are kept as text and have no effect.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const geom = @import("../base/geom.zig");
const options = @import("../options.zig");
const path = @import("../path.zig");

pub const Type = enum { arc, bitmap, image, line, oval, polygon, rectangle, text, window };

pub const type_names = [_][]const u8{ "arc", "bitmap", "image", "line", "oval", "polygon", "rectangle", "text", "window" };

pub const State = enum { inherit, normal, disabled, hidden };
pub const Arrow = enum { none, first, last, both };
pub const Cap = enum { butt, projecting, round };
pub const Join = enum { bevel, miter, round };
pub const Smooth = enum { none, bezier, raw };
pub const ArcStyle = enum { pieslice, chord, arc };

pub const Dash = struct {
    n: u8 = 0,
    v: [16]f32 = @splat(0),
    /// A pattern of characters: the lengths are times the line width.
    chars: bool = false,
};

pub const Field = enum {
    dash, active_dash, disabled_dash, dash_offset,
    fill, active_fill, disabled_fill,
    outline, active_outline, disabled_outline,
    width, active_width, disabled_width,
    state, tags, ignore,
    arrow, arrow_shape, cap, join, smooth, spline_steps,
    start, extent, arc_style,
    anchor, justify, angle, font, text, underline, text_width,
    image, active_image, disabled_image,
    bitmap, active_bitmap, disabled_bitmap,
    foreground, active_foreground, disabled_foreground,
    background, active_background, disabled_background,
    window, win_width, win_height,
};

pub const Opt = struct { name: []const u8, default: []const u8, field: Field };

fn o(name: []const u8, default: []const u8, field: Field) Opt {
    return .{ .name = name, .default = default, .field = field };
}

const shape_common = [_]Opt{
    o("-activedash", "", .active_dash),             o("-activefill", "", .active_fill),
    o("-activeoutline", "", .active_outline),       o("-activeoutlinestipple", "", .ignore),
    o("-activestipple", "", .ignore),               o("-activewidth", "0.0", .active_width),
    o("-dash", "", .dash),                          o("-dashoffset", "0", .dash_offset),
    o("-disableddash", "", .disabled_dash),         o("-disabledfill", "", .disabled_fill),
    o("-disabledoutline", "", .disabled_outline),   o("-disabledoutlinestipple", "", .ignore),
    o("-disabledstipple", "", .ignore),             o("-disabledwidth", "0.0", .disabled_width),
};

const rect_opts = shape_common ++ [_]Opt{
    o("-fill", "", .fill),                  o("-offset", "0,0", .ignore),
    o("-outline", "#000000", .outline),     o("-outlineoffset", "0,0", .ignore),
    o("-outlinestipple", "", .ignore),      o("-state", "", .state),
    o("-stipple", "", .ignore),             o("-tags", "", .tags),
    o("-width", "1.0", .width),
};

const arc_opts = shape_common ++ [_]Opt{
    o("-extent", "90", .extent),            o("-fill", "", .fill),
    o("-offset", "0,0", .ignore),           o("-outline", "#000000", .outline),
    o("-outlineoffset", "0,0", .ignore),    o("-outlinestipple", "", .ignore),
    o("-start", "0", .start),               o("-state", "", .state),
    o("-stipple", "", .ignore),             o("-style", "", .arc_style),
    o("-tags", "", .tags),                  o("-width", "1.0", .width),
};

const polygon_opts = shape_common ++ [_]Opt{
    o("-fill", "#000000", .fill),           o("-joinstyle", "round", .join),
    o("-offset", "0,0", .ignore),           o("-outline", "", .outline),
    o("-outlineoffset", "0,0", .ignore),    o("-outlinestipple", "", .ignore),
    o("-smooth", "0", .smooth),             o("-splinesteps", "12", .spline_steps),
    o("-state", "", .state),                o("-stipple", "", .ignore),
    o("-tags", "", .tags),                  o("-width", "1.0", .width),
};

const line_opts = [_]Opt{
    o("-activedash", "", .active_dash),     o("-activefill", "", .active_fill),
    o("-activestipple", "", .ignore),       o("-activewidth", "0.0", .active_width),
    o("-arrow", "none", .arrow),            o("-arrowshape", "8 10 3", .arrow_shape),
    o("-capstyle", "butt", .cap),           o("-fill", "#000000", .fill),
    o("-dash", "", .dash),                  o("-dashoffset", "0", .dash_offset),
    o("-disableddash", "", .disabled_dash), o("-disabledfill", "", .disabled_fill),
    o("-disabledstipple", "", .ignore),     o("-disabledwidth", "0.0", .disabled_width),
    o("-joinstyle", "round", .join),        o("-offset", "0,0", .ignore),
    o("-smooth", "0", .smooth),             o("-splinesteps", "12", .spline_steps),
    o("-state", "", .state),                o("-stipple", "", .ignore),
    o("-tags", "", .tags),                  o("-width", "1.0", .width),
};

const text_opts = [_]Opt{
    o("-activefill", "", .active_fill),     o("-activestipple", "", .ignore),
    o("-anchor", "center", .anchor),        o("-angle", "0.0", .angle),
    o("-disabledfill", "", .disabled_fill), o("-disabledstipple", "", .ignore),
    o("-fill", "#000000", .fill),           o("-font", "TkDefaultFont", .font),
    o("-justify", "left", .justify),        o("-offset", "0,0", .ignore),
    o("-state", "", .state),                o("-stipple", "", .ignore),
    o("-tags", "", .tags),                  o("-text", "", .text),
    o("-underline", "-1", .underline),      o("-width", "0", .text_width),
};

const image_opts = [_]Opt{
    o("-activeimage", "", .active_image),   o("-anchor", "center", .anchor),
    o("-disabledimage", "", .disabled_image), o("-image", "", .image),
    o("-state", "", .state),                o("-tags", "", .tags),
};

const bitmap_opts = [_]Opt{
    o("-activebackground", "", .active_background), o("-activebitmap", "", .active_bitmap),
    o("-activeforeground", "", .active_foreground), o("-anchor", "center", .anchor),
    o("-background", "", .background),               o("-bitmap", "", .bitmap),
    o("-disabledbackground", "", .disabled_background), o("-disabledbitmap", "", .disabled_bitmap),
    o("-disabledforeground", "", .disabled_foreground), o("-foreground", "#000000", .foreground),
    o("-state", "", .state),                         o("-tags", "", .tags),
};

const window_opts = [_]Opt{
    o("-anchor", "center", .anchor), o("-height", "0", .win_height),
    o("-state", "", .state),         o("-tags", "", .tags),
    o("-width", "0", .win_width),    o("-window", "", .window),
};

pub fn optsOf(t: Type) []const Opt {
    return switch (t) {
        .arc => &arc_opts,
        .bitmap => &bitmap_opts,
        .image => &image_opts,
        .line => &line_opts,
        .oval, .rectangle => &rect_opts,
        .polygon => &polygon_opts,
        .text => &text_opts,
        .window => &window_opts,
    };
}

/// The parsed options of an item. The text fields point into the owned
/// option texts of the item.
pub const Attr = struct {
    dash: Dash = .{},
    active_dash: Dash = .{},
    disabled_dash: Dash = .{},
    dash_offset: f32 = 0,
    fill: ?geom.Color = null,
    active_fill: ?geom.Color = null,
    disabled_fill: ?geom.Color = null,
    outline: ?geom.Color = null,
    active_outline: ?geom.Color = null,
    disabled_outline: ?geom.Color = null,
    /// The default black of Tk: the paint uses the color of the theme for it.
    fill_default: bool = false,
    outline_default: bool = false,
    width: f64 = 1,
    active_width: f64 = 0,
    disabled_width: f64 = 0,
    state: State = .inherit,
    arrow: Arrow = .none,
    arrow_shape: [3]f64 = .{ 8, 10, 3 },
    cap: Cap = .butt,
    join: Join = .round,
    smooth: Smooth = .none,
    spline_steps: u32 = 12,
    start: f64 = 0,
    extent: f64 = 90,
    arc_style: ArcStyle = .pieslice,
    anchor: options.Anchor = .center,
    justify: options.Justify = .left,
    angle: f64 = 0,
    font: []const u8 = "TkDefaultFont",
    text: []const u8 = "",
    underline: i64 = -1,
    text_width: f64 = 0,
    image: []const u8 = "",
    active_image: []const u8 = "",
    disabled_image: []const u8 = "",
    bitmap: []const u8 = "",
    active_bitmap: []const u8 = "",
    disabled_bitmap: []const u8 = "",
    foreground: ?geom.Color = null,
    active_foreground: ?geom.Color = null,
    disabled_foreground: ?geom.Color = null,
    background: ?geom.Color = null,
    active_background: ?geom.Color = null,
    disabled_background: ?geom.Color = null,
    window: []const u8 = "",
    win_width: f64 = 0,
    win_height: f64 = 0,
};

/// The parse error of an option: the message of `wish`.
pub const ParseError = struct { msg: []const u8 };

/// A screen distance with a unit (c, i, m, p) as a float, in logical pixels.
pub fn parseDist(text: []const u8, scaling: f64) ?f64 {
    const t = std.mem.trim(u8, text, " \t");
    if (t.len == 0) return null;
    var end = t.len;
    var mul: f64 = 1;
    switch (t[t.len - 1]) {
        'c' => mul = 72.0 / 2.54 * scaling,
        'i' => mul = 72.0 * scaling,
        'm' => mul = 72.0 / 25.4 * scaling,
        'p' => mul = scaling,
        else => end = t.len,
    }
    if (mul != 1 or (t[t.len - 1] == 'p')) end = t.len - 1;
    const v = std.fmt.parseFloat(f64, std.mem.trim(u8, t[0..end], " ")) catch return null;
    if (!std.math.isFinite(v) or @abs(v) > 1e9) return null;
    return v * mul;
}

fn parseColor(text: []const u8, buf: []u8) union(enum) { ok: ?geom.Color, err: []const u8 } {
    if (text.len == 0) return .{ .ok = null };
    if (geom.Color.parseTk(text)) |c| return .{ .ok = c };
    const m = std.fmt.bufPrint(buf, "{s} color name \"{s}\"", .{ if (text[0] == '#') "invalid" else "unknown", text }) catch "bad color";
    return .{ .err = m };
}

/// Parses a dash pattern: a list of integers from 1 to 255, or a text of
/// the characters `.`, `,`, `-`, `_`, and space.
pub fn parseDash(text: []const u8, d: *Dash) bool {
    d.* = .{};
    const t = std.mem.trim(u8, text, " ");
    if (t.len == 0) return true;
    var all_chars = true;
    for (text) |c| switch (c) {
        '.', ',', '-', '_', ' ' => {},
        else => all_chars = false,
    };
    if (all_chars) {
        d.chars = true;
        for (text) |c| {
            if (d.n + 2 > d.v.len) break;
            switch (c) {
                ' ' => {
                    if (d.n > 0) d.v[d.n - 1] += 4;
                    continue;
                },
                '.' => d.v[d.n] = 2,
                ',' => d.v[d.n] = 4,
                '-' => d.v[d.n] = 6,
                '_' => d.v[d.n] = 8,
                else => unreachable,
            }
            d.v[d.n + 1] = 4;
            d.n += 2;
        }
        return true;
    }
    var it = std.mem.tokenizeAny(u8, t, " \t");
    while (it.next()) |w| {
        const v = std.fmt.parseInt(i64, w, 10) catch return false;
        if (v < 1 or v > 255) return false;
        if (d.n == d.v.len) break;
        d.v[d.n] = @floatFromInt(v);
        d.n += 1;
    }
    // An odd count repeats once, as X does.
    if (d.n % 2 == 1 and d.n * 2 <= d.v.len) {
        const n = d.n;
        for (0..n) |i| d.v[n + i] = d.v[i];
        d.n *= 2;
    }
    return true;
}

fn word(comptime E: type, text: []const u8, words: []const []const u8) ?E {
    if (text.len == 0) return null;
    for (words, 0..) |w, i| if (std.mem.startsWith(u8, w, text)) return @enumFromInt(i);
    return null;
}

/// Checks a name: an image, a bitmap, or a window. Null is a good name.
pub const Names = struct {
    ctx: *anyopaque,
    image: *const fn (ctx: *anyopaque, name: []const u8) bool,
    bitmap: *const fn (ctx: *anyopaque, name: []const u8) bool,
    window: *const fn (ctx: *anyopaque, name: []const u8) ?[]const u8,
};

/// Parses one option into the attributes. Returns an error message, or null.
pub fn parse(a: *Attr, field: Field, text: []const u8, scaling: f64, names: Names, buf: []u8) ?[]const u8 {
    switch (field) {
        .ignore, .tags => {},
        .dash, .active_dash, .disabled_dash => {
            const d = switch (field) {
                .dash => &a.dash,
                .active_dash => &a.active_dash,
                else => &a.disabled_dash,
            };
            if (!parseDash(text, d)) return std.fmt.bufPrint(buf, "expected integer in the range 1..255 but got \"{s}\"", .{text}) catch "bad dash";
        },
        .dash_offset => a.dash_offset = @floatCast(parseDist(text, scaling) orelse return std.fmt.bufPrint(buf, "bad screen distance \"{s}\"", .{text}) catch "bad"),
        .fill, .active_fill, .disabled_fill, .outline, .active_outline, .disabled_outline, .foreground, .active_foreground, .disabled_foreground, .background, .active_background, .disabled_background => {
            const r = parseColor(text, buf);
            const c = switch (r) {
                .ok => |c| c,
                .err => |m| return m,
            };
            switch (field) {
                .fill => a.fill = c,
                .active_fill => a.active_fill = c,
                .disabled_fill => a.disabled_fill = c,
                .outline => a.outline = c,
                .active_outline => a.active_outline = c,
                .disabled_outline => a.disabled_outline = c,
                .foreground => a.foreground = c,
                .active_foreground => a.active_foreground = c,
                .disabled_foreground => a.disabled_foreground = c,
                .background => a.background = c,
                .active_background => a.active_background = c,
                else => a.disabled_background = c,
            }
        },
        .width, .active_width, .disabled_width, .text_width, .win_width, .win_height => {
            const v = parseDist(text, scaling) orelse return std.fmt.bufPrint(buf, "bad screen distance \"{s}\"", .{text}) catch "bad";
            switch (field) {
                .width => a.width = @max(v, 0),
                .active_width => a.active_width = @max(v, 0),
                .disabled_width => a.disabled_width = @max(v, 0),
                .text_width => a.text_width = @max(v, 0),
                .win_width => a.win_width = @max(v, 0),
                else => a.win_height = @max(v, 0),
            }
        },
        .state => {
            if (text.len == 0) {
                a.state = .inherit;
            } else a.state = word(State, text, &.{ "", "normal", "disabled", "hidden" }) orelse
                return std.fmt.bufPrint(buf, "bad state value \"{s}\": must be normal, hidden, or disabled", .{text}) catch "bad";
        },
        .arrow => a.arrow = word(Arrow, text, &.{ "none", "first", "last", "both" }) orelse
            return std.fmt.bufPrint(buf, "bad arrow spec \"{s}\": must be none, first, last, or both", .{text}) catch "bad",
        .arrow_shape => {
            var it = std.mem.tokenizeAny(u8, text, " \t");
            var v: [3]f64 = undefined;
            var n: usize = 0;
            while (it.next()) |w| {
                if (n == 3) {
                    n = 4;
                    break;
                }
                v[n] = parseDist(w, scaling) orelse return std.fmt.bufPrint(buf, "bad screen distance \"{s}\"", .{w}) catch "bad";
                n += 1;
            }
            if (n != 3) return "bad arrow shape \"" ++ "\": must be list with three numbers";
            a.arrow_shape = v;
        },
        .cap => a.cap = word(Cap, text, &.{ "butt", "projecting", "round" }) orelse
            return std.fmt.bufPrint(buf, "bad cap style \"{s}\": must be butt, projecting, or round", .{text}) catch "bad",
        .join => a.join = word(Join, text, &.{ "bevel", "miter", "round" }) orelse
            return std.fmt.bufPrint(buf, "bad join style \"{s}\": must be bevel, miter, or round", .{text}) catch "bad",
        .smooth => {
            if (std.mem.eql(u8, text, "raw")) {
                a.smooth = .raw;
            } else if (std.mem.eql(u8, text, "bezier")) {
                a.smooth = .bezier;
            } else {
                const b = options.parseBool(text) orelse return std.fmt.bufPrint(buf, "expected boolean value but got \"{s}\"", .{text}) catch "bad";
                a.smooth = if (b) .bezier else .none;
            }
        },
        .spline_steps, .underline => {
            const v = std.fmt.parseInt(i64, std.mem.trim(u8, text, " "), 0) catch return std.fmt.bufPrint(buf, "expected integer but got \"{s}\"", .{text}) catch "bad";
            if (field == .underline) a.underline = v else a.spline_steps = @intCast(std.math.clamp(v, 1, 100));
        },
        .start, .extent, .angle => {
            const v = std.fmt.parseFloat(f64, std.mem.trim(u8, text, " ")) catch return std.fmt.bufPrint(buf, "expected floating-point number but got \"{s}\"", .{text}) catch "bad";
            if (!std.math.isFinite(v)) return std.fmt.bufPrint(buf, "expected floating-point number but got \"{s}\"", .{text}) catch "bad";
            switch (field) {
                .start => a.start = v,
                .extent => a.extent = std.math.clamp(v, -360, 360),
                else => a.angle = v,
            }
        },
        .arc_style => {
            if (text.len == 0) {
                a.arc_style = .pieslice;
            } else a.arc_style = word(ArcStyle, text, &.{ "pieslice", "chord", "arc" }) orelse
                return std.fmt.bufPrint(buf, "bad -style option \"{s}\": must be arc, chord, or pieslice", .{text}) catch "bad";
        },
        .anchor => {
            const words = [_][]const u8{ "n", "ne", "e", "se", "s", "sw", "w", "nw", "center" };
            _ = words;
            const found = @import("../options.zig").anchorIndex(text);
            a.anchor = @enumFromInt(found orelse return std.fmt.bufPrint(buf, "bad anchor position \"{s}\": must be n, ne, e, se, s, sw, w, nw, or center", .{text}) catch "bad");
        },
        .justify => {
            const j = word(options.Justify, text, &.{ "left", "center", "right" }) orelse
                return std.fmt.bufPrint(buf, "bad justification \"{s}\": must be left, right, or center", .{text}) catch "bad";
            a.justify = j;
        },
        .font => a.font = text,
        .text => a.text = text,
        .image, .active_image, .disabled_image => {
            if (text.len > 0 and !names.image(names.ctx, text)) return std.fmt.bufPrint(buf, "image \"{s}\" doesn't exist", .{text}) catch "bad";
            switch (field) {
                .image => a.image = text,
                .active_image => a.active_image = text,
                else => a.disabled_image = text,
            }
        },
        .bitmap, .active_bitmap, .disabled_bitmap => {
            if (text.len > 0 and !names.bitmap(names.ctx, text)) return std.fmt.bufPrint(buf, "bitmap \"{s}\" not defined", .{text}) catch "bad";
            switch (field) {
                .bitmap => a.bitmap = text,
                .active_bitmap => a.active_bitmap = text,
                else => a.disabled_bitmap = text,
            }
        },
        .window => {
            if (text.len > 0) if (names.window(names.ctx, text)) |m| return m;
            a.window = text;
        },
    }
    return null;
}

// ---- Geometry ----

pub const Pt = path.Pt;

/// The integer bounding box of Tk, or null for an item with no area.
pub const Box = [4]i32;

fn fl(v: f64) i32 {
    return @intFromFloat(std.math.clamp(@floor(v), -1e9, 1e9));
}

fn cl(v: f64) i32 {
    return @intFromFloat(std.math.clamp(@ceil(v), -1e9, 1e9));
}

/// `TkIncludePoint`: a point adds 0.5 and drops the fraction toward zero, as a C cast does.
fn include(b: *Box, x: f64, y: f64) void {
    const ix: i32 = @intFromFloat(std.math.clamp(@trunc(x + 0.5), -1e9, 1e9));
    const iy: i32 = @intFromFloat(std.math.clamp(@trunc(y + 0.5), -1e9, 1e9));
    b[0] = @min(b[0], ix);
    b[1] = @min(b[1], iy);
    b[2] = @max(b[2], ix);
    b[3] = @max(b[3], iy);
}

fn boxOfPoints(c: []const f64) Box {
    var b: Box = .{ fl(c[0]), fl(c[1]), fl(c[0]), fl(c[1]) };
    var i: usize = 2;
    while (i + 1 < c.len) : (i += 2) include(&b, c[i], c[i + 1]);
    return b;
}

/// The two corners of a rectangle, oval, or arc in order.
pub fn corners(c: []const f64) [4]f64 {
    return .{ @min(c[0], c[2]), @min(c[1], c[3]), @max(c[0], c[2]), @max(c[1], c[3]) };
}

/// The points of an arc on its oval, from `start` by `extent` degrees,
/// counterclockwise on the screen, as in Tk.
pub fn arcPoints(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(Pt), c: [4]f64, start: f64, extent: f64, sx: f64, sy: f64, ox: f64, oy: f64) !void {
    const cx = (c[0] + c[2]) / 2;
    const cy = (c[1] + c[3]) / 2;
    const rx = (c[2] - c[0]) / 2;
    const ry = (c[3] - c[1]) / 2;
    const r = @max(@abs(rx * sx), @abs(ry * sy));
    const n: usize = std.math.clamp(@as(usize, @intFromFloat(@ceil(r * @abs(extent) / 90.0 * 0.6))) + 4, 4, 720);
    for (0..n + 1) |i| {
        const t = (start + extent * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n))) * std.math.pi / 180.0;
        try out.append(gpa, .{ .x = @floatCast((cx + rx * @cos(t)) * sx + ox), .y = @floatCast((cy - ry * @sin(t)) * sy + oy) });
    }
}

/// The bounding box of an item for `bbox`, with the rules of Tk.
pub fn bbox(t: Type, a: *const Attr, coords: []const f64, width: f64, extra: [4]f64) ?Box {
    switch (t) {
        .rectangle, .oval => {
            if (coords.len < 4) return null;
            const c = corners(coords);
            const bloat: f64 = if (a.outline == null) 0 else @floor((width + 1) / 2);
            return .{ fl(c[0] - bloat), fl(c[1] - bloat), cl(c[2] + bloat), cl(c[3] + bloat) };
        },
        .arc => {
            if (coords.len < 4) return null;
            const c = corners(coords);
            var pts: std.ArrayListUnmanaged(Pt) = .empty;
            var buf: [8192]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&buf);
            arcPoints(fba.allocator(), &pts, c, a.start, a.extent, 1, 1, 0, 0) catch {};
            var b: Box = .{ fl((c[0] + c[2]) / 2), fl((c[1] + c[3]) / 2), fl((c[0] + c[2]) / 2), fl((c[1] + c[3]) / 2) };
            if (a.arc_style != .pieslice and pts.items.len > 0) b = .{ fl(pts.items[0].x), fl(pts.items[0].y), fl(pts.items[0].x), fl(pts.items[0].y) };
            for (pts.items) |p| include(&b, p.x, p.y);
            const wd: i32 = if (a.outline == null) 0 else @intFromFloat(@floor((width + 1) / 2));
            return .{ b[0] - wd - 1, b[1] - wd - 1, b[2] + wd + 1, b[3] + wd + 1 };
        },
        .line => {
            if (coords.len < 4) return null;
            var b = boxOfPoints(coords);
            const wd: i32 = @max(@as(i32, @intFromFloat(@floor(width + 0.5))), 1);
            b = .{ b[0] - wd, b[1] - wd, b[2] + wd, b[3] + wd };
            if (a.arrow != .none and coords.len >= 4) {
                const n = coords.len;
                if (a.arrow == .first or a.arrow == .both) for (arrowPoly(coords[0], coords[1], coords[2], coords[3], a.arrow_shape, width).poly) |p| include(&b, p.x, p.y);
                if (a.arrow == .last or a.arrow == .both) for (arrowPoly(coords[n - 2], coords[n - 1], coords[n - 4], coords[n - 3], a.arrow_shape, width).poly) |p| include(&b, p.x, p.y);
            }
            return .{ b[0] - 1, b[1] - 1, b[2] + 1, b[3] + 1 };
        },
        .polygon => {
            if (coords.len < 4) return null;
            var b = boxOfPoints(coords);
            if (a.outline != null) {
                const wd: i32 = @intFromFloat(@floor(width + 0.5));
                b = .{ b[0] - wd, b[1] - wd, b[2] + wd, b[3] + wd };
            }
            return .{ b[0] - 1, b[1] - 1, b[2] + 1, b[3] + 1 };
        },
        // The size of these items comes from the caller: the text, the image, or the window.
        .text, .image, .bitmap, .window => {
            if (coords.len < 2 or extra[2] <= extra[0] or extra[3] <= extra[1]) return null;
            return .{ fl(extra[0]), fl(extra[1]), cl(extra[2]), cl(extra[3]) };
        },
    }
}

/// The top-left corner of an image, a bitmap, or a window at a point, as
/// Tk computes it: the point rounds to a pixel and the half sizes are integer.
pub fn anchorPixel(an: options.Anchor, x: f64, y: f64, w: f64, h: f64) [2]f64 {
    const rx = @trunc(x + (if (x >= 0) @as(f64, 0.5) else -0.5));
    const ry = @trunc(y + (if (y >= 0) @as(f64, 0.5) else -0.5));
    return anchorOrigin(an, rx, ry, @floor(w / 2) * 2, @floor(h / 2) * 2);
}

/// The top-left corner of a box of size w by h at a point, by an anchor.
pub fn anchorOrigin(an: options.Anchor, x: f64, y: f64, w: f64, h: f64) [2]f64 {
    const dx: f64 = switch (an) {
        .nw, .w, .sw => 0,
        .n, .center, .s => w / 2,
        .ne, .e, .se => w,
    };
    const dy: f64 = switch (an) {
        .nw, .n, .ne => 0,
        .w, .center, .e => h / 2,
        .sw, .s, .se => h,
    };
    return .{ x - dx, y - dy };
}

pub const ArrowPoly = struct { poly: [6]Pt, neck: Pt };

/// The arrowhead of Tk at the point (px, py), for a line that comes from
/// (qx, qy): the polygon and the new end of the line inside it.
pub fn arrowPoly(px: f64, py: f64, qx: f64, qy: f64, shape: [3]f64, width: f64) ArrowPoly {
    const sa = shape[0] + 0.001;
    const sb = shape[1] + 0.001;
    const sc = shape[2] + width / 2 + 0.001;
    const frac = (width / 2) / sc;
    const backup = frac * sb + sa * (1 - frac) / 2;
    const dx = px - qx;
    const dy = py - qy;
    const len = @sqrt(dx * dx + dy * dy);
    const cs: f64 = if (len == 0) 0 else dx / len;
    const sn: f64 = if (len == 0) 0 else dy / len;
    var p: [6][2]f64 = undefined;
    p[0] = .{ px, py };
    p[5] = p[0];
    const vx = px - sa * cs;
    const vy = py - sa * sn;
    p[1] = .{ px - sb * cs + sc * sn, py - sb * sn - sc * cs };
    p[4] = .{ p[1][0] - 2 * sc * sn, p[1][1] + 2 * sc * cs };
    p[2] = .{ p[1][0] * frac + vx * (1 - frac), p[1][1] * frac + vy * (1 - frac) };
    p[3] = .{ p[4][0] * frac + vx * (1 - frac), p[4][1] * frac + vy * (1 - frac) };
    var out: ArrowPoly = undefined;
    for (p, 0..) |q, i| out.poly[i] = .{ .x = @floatCast(q[0]), .y = @floatCast(q[1]) };
    out.neck = .{ .x = @floatCast(px - backup * cs), .y = @floatCast(py - backup * sn) };
    return out;
}

/// The points of a smooth line through the coordinates (Tk's
/// `TkMakeBezierCurve`): each inner point is the control point of a
/// curve between the middles of its two segments. With `raw`, the
/// points are the points and control points of cubic curves.
pub fn smoothPoints(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged([2]f64), c: []const f64, steps: u32, raw: bool, closed_in: bool) !void {
    const n = c.len / 2;
    if (n < 3) {
        var i: usize = 0;
        while (i < n) : (i += 1) try out.append(gpa, .{ c[2 * i], c[2 * i + 1] });
        return;
    }
    const st: usize = steps;
    if (raw) {
        try out.append(gpa, .{ c[0], c[1] });
        var i: usize = 0;
        while (i + 3 < n) : (i += 3) {
            const p = [4][2]f64{ .{ c[2 * i], c[2 * i + 1] }, .{ c[2 * i + 2], c[2 * i + 3] }, .{ c[2 * i + 4], c[2 * i + 5] }, .{ c[2 * i + 6], c[2 * i + 7] } };
            for (1..st + 1) |k| try out.append(gpa, cubic(p, @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(st))));
        }
        return;
    }
    const closed = closed_in or (c[0] == c[2 * n - 2] and c[1] == c[2 * n - 1]);
    const P = struct {
        fn at(cc: []const f64, nn: usize, i: usize) [2]f64 {
            const k = i % nn;
            return .{ cc[2 * k], cc[2 * k + 1] };
        }
    };
    var m = n;
    if (closed and c[0] == c[2 * n - 2] and c[1] == c[2 * n - 1]) m = n - 1;
    if (closed) {
        // Each point is a control point; the curve goes through the middles.
        var i: usize = 0;
        while (i < m) : (i += 1) {
            const a = P.at(c, m, i);
            const b = P.at(c, m, i + 1);
            const d = P.at(c, m, i + 2);
            const c0 = mid(a, b, 0.5);
            const c3 = mid(b, d, 0.5);
            const ctl = [4][2]f64{ c0, mid(c0, b, 2.0 / 3.0), mid(c3, b, 2.0 / 3.0), c3 };
            if (i == 0) try out.append(gpa, c0);
            for (1..st + 1) |k| try out.append(gpa, cubic(ctl, @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(st))));
        }
        return;
    }
    try out.append(gpa, .{ c[0], c[1] });
    var i: usize = 0;
    while (i + 2 < n) : (i += 1) {
        const a = P.at(c, n, i);
        const b = P.at(c, n, i + 1);
        const d = P.at(c, n, i + 2);
        const c0 = if (i == 0) a else mid(a, b, 0.5);
        const c3 = if (i + 3 == n) d else mid(b, d, 0.5);
        const ctl = [4][2]f64{ c0, mid(c0, b, 2.0 / 3.0), mid(c3, b, 2.0 / 3.0), c3 };
        for (1..st + 1) |k| try out.append(gpa, cubic(ctl, @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(st))));
    }
}

fn mid(a: [2]f64, b: [2]f64, t: f64) [2]f64 {
    return .{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t };
}

fn cubic(p: [4][2]f64, t: f64) [2]f64 {
    const u = 1 - t;
    const a = u * u * u;
    const b = 3 * u * u * t;
    const c = 3 * u * t * t;
    const d = t * t * t;
    return .{ a * p[0][0] + b * p[1][0] + c * p[2][0] + d * p[3][0], a * p[0][1] + b * p[1][1] + c * p[2][1] + d * p[3][1] };
}

/// The distance from a point to the segment from a to b.
pub fn segDist(x: f64, y: f64, ax: f64, ay: f64, bx: f64, by: f64) f64 {
    const dx = bx - ax;
    const dy = by - ay;
    const l2 = dx * dx + dy * dy;
    var t: f64 = 0;
    if (l2 > 0) t = std.math.clamp(((x - ax) * dx + (y - ay) * dy) / l2, 0, 1);
    const px = ax + t * dx - x;
    const py = ay + t * dy - y;
    return @sqrt(px * px + py * py);
}

/// True when a point is inside a polygon by the even-odd rule.
pub fn inPolygon(pts: []const [2]f64, x: f64, y: f64) bool {
    var in = false;
    var j = pts.len - 1;
    for (pts, 0..) |p, i| {
        const q = pts[j];
        if ((p[1] > y) != (q[1] > y) and x < (q[0] - p[0]) * (y - p[1]) / (q[1] - p[1]) + p[0]) in = !in;
        j = i;
    }
    return in;
}

/// The distance from a point to a box, 0 inside.
pub fn boxDist(b: [4]f64, x: f64, y: f64) f64 {
    const dx = @max(b[0] - x, 0, x - b[2]);
    const dy = @max(b[1] - y, 0, y - b[3]);
    return @sqrt(dx * dx + dy * dy);
}

const testing = std.testing;

test "canvas items: bbox follows the rules of wish" {
    var a: Attr = .{ .outline = .{ .r = 0, .g = 0, .b = 0 } };
    try testing.expectEqual(Box{ 9, 9, 51, 31 }, bbox(.rectangle, &a, &.{ 10, 10, 50, 30 }, 1, .{ 0, 0, 0, 0 }).?);
    try testing.expectEqual(Box{ 8, 8, 52, 32 }, bbox(.rectangle, &a, &.{ 10, 10, 50, 30 }, 4, .{ 0, 0, 0, 0 }).?);
    var l: Attr = .{};
    try testing.expectEqual(Box{ -4, -4, 104, 4 }, bbox(.line, &l, &.{ 0, 0, 100, 0 }, 3, .{ 0, 0, 0, 0 }).?);
    l.arrow = .last;
    try testing.expectEqual(Box{ -2, -4, 102, 5 }, bbox(.line, &l, &.{ 0, 0, 100, 0 }, 1, .{ 0, 0, 0, 0 }).?);
    var p: Attr = .{};
    try testing.expectEqual(Box{ -1, -1, 11, 11 }, bbox(.polygon, &p, &.{ 0, 0, 10, 0, 5, 10 }, 1, .{ 0, 0, 0, 0 }).?);
    try testing.expectEqual(Box{ 48, -2, 102, 52 }, bbox(.arc, &a, &.{ 0, 0, 100, 100 }, 1, .{ 0, 0, 0, 0 }).?);
}
