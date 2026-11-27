//! The canvas class. It holds a list of items in stacking order, each
//! with an id, tags, coordinates, and the options of its type
//! (`items.zig`). The widget subcommands of `wish` 8.6.16 work on a
//! `tagOrId` (`tags.zig`). The canvas has the scroll protocol of
//! `scroll.zig` on each axis, with `-scrollregion`, `-confine`, and the
//! increments. The paint draws only the items whose bounding box meets
//! the window. A rectangle and a circle are one box quad each. The other
//! shapes go through the coverage rows of `path.zig`. A text item uses
//! the shaping and the glyph atlas of the text engine. An image or a
//! bitmap is one box quad for each run of equal pixels in a row.
//!
//! Pointer events pick the current item: the top item under the pointer
//! that is not hidden or disabled. A change of the current item sends
//! Leave to the old item and Enter to the new one. The item bindings run
//! before the bindings of the widget, as in Tk, with the tags `all`, the
//! tags of the item, and the id of the item. A window item puts a child
//! of the canvas at its coordinates: the canvas is the geometry manager
//! of that child.
//!
//! `ztk::animate {.c tagOrId} -coords {...} -fill red` moves the items
//! on the UI thread at each frame, and the paint gives the render thread
//! the quads at the time of the frame and at the end, so the render
//! thread moves them while the UI thread is busy.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const num = @import("../num.zig");
const geom = @import("../geom.zig");
const widget = @import("../widget.zig");
const anim = @import("../anim.zig");
const options = @import("../options.zig");
const paint = @import("../paint.zig");
const scene = @import("../scene.zig");
const path = @import("../path.zig");
const bind = @import("../bind.zig");
const layout = @import("../layout.zig");
const scroll = @import("../scroll.zig");
const easing = @import("../easing.zig");
const shape = @import("../text/shape.zig");
const font_mod = @import("../text/font.zig");
const image_mod = @import("../image.zig");
const items = @import("items.zig");
const tags_mod = @import("tags.zig");
const bitmaps = @import("bitmaps.zig");
const App = @import("../app.zig").App;
const Spec = options.Spec;
const Widget = widget.Widget;
const Value = ztcl.Value;
const Item = ItemT;

const state_words = [_][]const u8{ "normal", "disabled" };

pub const specs = [_]Spec{
    .{ .name = "-background", .db_name = "background", .db_class = "Background", .type = .color, .default = "#d9d9d9", .from_style = true, .style_prop = .background },
    .{ .name = "-bd", .type = .synonym, .target = "-borderwidth" },
    .{ .name = "-bg", .type = .synonym, .target = "-background" },
    .{ .name = "-borderwidth", .db_name = "borderWidth", .db_class = "BorderWidth", .type = .pixels, .default = "0", .from_style = true, .style_prop = .border_width },
    .{ .name = "-closeenough", .db_name = "closeEnough", .db_class = "CloseEnough", .type = .double, .default = "1" },
    .{ .name = "-confine", .db_name = "confine", .db_class = "Confine", .type = .boolean, .default = "1" },
    .{ .name = "-cursor", .db_name = "cursor", .db_class = "Cursor", .type = .string, .allow_empty = true },
    .{ .name = "-height", .db_name = "height", .db_class = "Height", .type = .pixels, .default = "7c" },
    .{ .name = "-highlightbackground", .db_name = "highlightBackground", .db_class = "HighlightBackground", .type = .color, .default = "#d9d9d9" },
    .{ .name = "-highlightcolor", .db_name = "highlightColor", .db_class = "HighlightColor", .type = .color, .default = "#000000" },
    .{ .name = "-highlightthickness", .db_name = "highlightThickness", .db_class = "HighlightThickness", .type = .pixels, .default = "1" },
    .{ .name = "-insertbackground", .db_name = "insertBackground", .db_class = "Foreground", .type = .color, .default = "#000000" },
    .{ .name = "-insertborderwidth", .db_name = "insertBorderWidth", .db_class = "BorderWidth", .type = .pixels, .default = "0" },
    .{ .name = "-insertofftime", .db_name = "insertOffTime", .db_class = "OffTime", .type = .int, .default = "300" },
    .{ .name = "-insertontime", .db_name = "insertOnTime", .db_class = "OnTime", .type = .int, .default = "600" },
    .{ .name = "-insertwidth", .db_name = "insertWidth", .db_class = "InsertWidth", .type = .pixels, .default = "2" },
    .{ .name = "-offset", .db_name = "offset", .db_class = "Offset", .type = .string, .default = "0,0" },
    .{ .name = "-relief", .db_name = "relief", .db_class = "Relief", .type = .relief, .default = "flat" },
    .{ .name = "-scrollregion", .db_name = "scrollRegion", .db_class = "ScrollRegion", .type = .string, .allow_empty = true },
    .{ .name = "-selectbackground", .db_name = "selectBackground", .db_class = "Foreground", .type = .color, .default = "#c3c3c3" },
    .{ .name = "-selectborderwidth", .db_name = "selectBorderWidth", .db_class = "BorderWidth", .type = .pixels, .default = "1" },
    .{ .name = "-selectforeground", .db_name = "selectForeground", .db_class = "Background", .type = .color, .default = "#000000" },
    .{ .name = "-state", .db_name = "state", .db_class = "State", .type = .word, .default = "normal", .words = &state_words, .word_name = "state value" },
    .{ .name = "-takefocus", .db_name = "takeFocus", .db_class = "TakeFocus", .type = .string, .allow_empty = true },
    .{ .name = "-width", .db_name = "width", .db_class = "Width", .type = .pixels, .default = "10c" },
    .{ .name = "-xscrollcommand", .db_name = "xScrollCommand", .db_class = "ScrollCommand", .type = .script, .allow_empty = true },
    .{ .name = "-xscrollincrement", .db_name = "xScrollIncrement", .db_class = "ScrollIncrement", .type = .pixels, .default = "0" },
    .{ .name = "-yscrollcommand", .db_name = "yScrollCommand", .db_class = "ScrollCommand", .type = .script, .allow_empty = true },
    .{ .name = "-yscrollincrement", .db_name = "yScrollIncrement", .db_class = "ScrollIncrement", .type = .pixels, .default = "0" },
};

const subcommand_list = "addtag, bbox, bind, canvasx, canvasy, cget, configure, coords, create, dchars, delete, dtag, find, focus, gettags, icursor, imove, index, insert, itemcget, itemconfigure, lower, move, moveto, postscript, raise, rchars, scale, scan, select, type, xview, or yview";

pub const class: widget.Class = .{
    .command = "canvas",
    .tk_class = "Canvas",
    .role = "canvas",
    .specs = &specs,
    .init = init,
    .deinit = deinit,
    .teardown = teardown,
    .configured = configured,
    .measure = measure,
    .paint = paintCanvas,
    .subcommand = subcommand,
    .bad_option_list = subcommand_list,
    .event = itemEvent,
};

/// The cache of the shaped lines of a text item.
const TextCache = struct {
    scale: f32 = 0,
    runs: []shape.Run = &.{},
    lines: []const []const u8 = &.{},
    /// The byte offset of each line in the text.
    starts: []usize = &.{},
    width: f64 = 0,
    ascent: i32 = 0,
    line_h: i32 = 0,

    fn free(c: *TextCache, gpa: std.mem.Allocator) void {
        for (c.runs) |*r| r.deinit(gpa);
        gpa.free(c.runs);
        gpa.free(c.lines);
        gpa.free(c.starts);
        c.* = .{};
    }
};

pub const ItemT = struct {
    id: u32,
    type: items.Type,
    coords: std.ArrayListUnmanaged(f64) = .empty,
    tags: std.ArrayListUnmanaged([]u8) = .empty,
    /// The text of each option of the type that the script set, or null. Owned.
    vals: []?[]u8,
    attr: items.Attr = .{},
    /// The default black of Tk for the fill or the outline: the paint uses the color of the theme.
    fill_theme: bool = false,
    outline_theme: bool = false,
    /// The bounding box of `bbox`, or null for no area. Valid when `box_ok`.
    box: ?items.Box = null,
    box_ok: bool = false,
    /// The extent of a text, image, bitmap, or window item: x1, y1, x2, y2.
    extent: [4]f64 = .{ 0, 0, 0, 0 },
    text_cache: TextCache = .{},
    /// The insert cursor of a text item, as a character index.
    insert: usize = 0,
    /// The window of a window item.
    win: ?*Widget = null,
    deleted: bool = false,

    fn free(it: *ItemT, gpa: std.mem.Allocator) void {
        it.coords.deinit(gpa);
        for (it.tags.items) |t| gpa.free(t);
        it.tags.deinit(gpa);
        for (it.vals) |v| if (v) |s| gpa.free(s);
        gpa.free(it.vals);
        it.text_cache.free(gpa);
        gpa.destroy(it);
    }

    fn hasTag(it: *const ItemT, t: []const u8) bool {
        for (it.tags.items) |x| if (std.mem.eql(u8, x, t)) return true;
        return false;
    }

    fn optIndex(it: *const ItemT, field: items.Field) ?usize {
        for (items.optsOf(it.type), 0..) |o, i| if (o.field == field) return i;
        return null;
    }
};

const Data = struct {
    /// Bottom first.
    list: std.ArrayListUnmanaged(*ItemT) = .empty,
    ids: std.AutoHashMapUnmanaged(u32, *ItemT) = .empty,
    next_id: u32 = 1,
    bindings: bind.Table,
    /// The current item (`current`), and whether a button holds it.
    current: ?*ItemT = null,
    pointer_in: bool = false,
    last_x: i32 = 0,
    last_y: i32 = 0,
    /// The focus item, for keys and the insert cursor.
    focus_item: ?*ItemT = null,
    sel_item: ?*ItemT = null,
    sel_first: usize = 0,
    sel_last: usize = 0,
    sel_anchor: usize = 0,
    /// The view of each axis when a scroll region is set.
    vx: scroll.View = .{ .fit_inside = true },
    vy: scroll.View = .{ .fit_inside = true },
    /// The origin with no scroll region: the canvas point at the top-left corner of the window.
    free_x: f64 = 0,
    free_y: f64 = 0,
    region: ?[4]f64 = null,
    /// The last good text of `-scrollregion`, for a bad value. Owned.
    region_text: []u8 = &.{},
    scan_x: i32 = 0,
    scan_y: i32 = 0,
    scan_ox: f64 = 0,
    scan_oy: f64 = 0,
    /// The count of window items.
    windows: u32 = 0,
    /// The quads of each image and bitmap at a scale, by name and version.
    pix_cache: std.ArrayListUnmanaged(PixCache) = .empty,
};

const PixCache = struct {
    key: u64,
    scale: f32,
    quads: []scene.Quad,
};

fn dataOf(w: *const Widget) *Data {
    return @ptrCast(@alignCast(w.data.?));
}

pub fn isCanvas(w: *const Widget) bool {
    return w.class == &class;
}

fn init(w: *Widget) anyerror!void {
    const d = try w.app.gpa.create(Data);
    d.* = .{ .bindings = bind.Table.init(w.app.gpa) };
    w.data = d;
}

fn freePix(gpa: std.mem.Allocator, d: *Data) void {
    for (d.pix_cache.items) |p| gpa.free(p.quads);
    d.pix_cache.clearRetainingCapacity();
}

fn deinit(w: *Widget) void {
    const gpa = w.app.gpa;
    const d = dataOf(w);
    for (d.list.items) |it| it.free(gpa);
    d.list.deinit(gpa);
    d.ids.deinit(gpa);
    d.bindings.deinit();
    gpa.free(d.region_text);
    freePix(gpa, d);
    d.pix_cache.deinit(gpa);
    gpa.destroy(d);
    w.data = null;
}

fn teardown(w: *Widget) void {
    dropAnims(w.app, w);
}

fn changed(w: *Widget) void {
    w.invalidate(.{ .style = false, .measure = false, .layout = d_layout(w), .paint = true });
}

fn d_layout(w: *Widget) bool {
    return dataOf(w).windows > 0;
}

// ---- Options of the widget ----

fn optInt(w: *const Widget, comptime name: []const u8) i32 {
    const v = options.get(w, name).value;
    return switch (v) {
        .pixels => |p| p,
        .int => |i| @intCast(std.math.clamp(i, -1 << 30, 1 << 30)),
        else => 0,
    };
}

fn canvasDisabled(w: *const Widget) bool {
    const v = options.get(w, "-state").value;
    return v == .word and v.word == 1;
}

fn parseRegion(text: []const u8, scaling: f64) ?[4]f64 {
    var it = std.mem.tokenizeAny(u8, text, " \t\n");
    var r: [4]f64 = undefined;
    var n: usize = 0;
    while (it.next()) |t| {
        if (n == 4) return null;
        r[n] = @round(items.parseDist(t, scaling) orelse return null);
        n += 1;
    }
    if (n != 4) return null;
    return r;
}

fn configured(w: *Widget, list: []const usize) ztcl.Error!void {
    const d = dataOf(w);
    const gpa = w.app.gpa;
    for (list) |i| {
        if (w.life == .dead) return;
        const name = w.class.specs[i].name;
        if (std.mem.eql(u8, name, "-scrollregion")) {
            // The canvas point at the top-left corner before the change.
            const before = origin(w);
            const text = w.opts[i].text;
            if (text.len == 0) {
                d.region = null;
            } else if (parseRegion(text, w.app.scaling)) |r| {
                d.region = r;
            } else {
                // Put the last good value back.
                const msg = try std.fmt.allocPrint(w.app.it.alloc(), "bad scrollRegion \"{s}\"", .{text});
                const slot = &w.opts[i];
                if (slot.set) gpa.free(slot.text);
                slot.* = .{ .set = d.region_text.len > 0, .text = if (d.region_text.len > 0) try gpa.dupe(u8, d.region_text) else "", .value = .{ .text = "" } };
                if (slot.set) slot.value = .{ .text = slot.text };
                return w.app.it.fail("{s}", .{msg});
            }
            gpa.free(d.region_text);
            d.region_text = try gpa.dupe(u8, text);
            // The view keeps its origin and then stays inside the new
            // region, as in wish: a canvas with the region -250 -200 250
            // 200 and a window of 400 by 300 shows x -150 at its left.
            d.vx = .{ .fit_inside = true };
            d.vy = .{ .fit_inside = true };
            syncViews(w);
            if (d.region) |r| {
                const in: f64 = @floatFromInt(inset(w));
                d.vx.jump(before[0] - (r[0] - in));
                d.vy.jump(before[1] - (r[1] - in));
            }
        } else if (std.mem.eql(u8, name, "-state")) {
            w.state.disabled = canvasDisabled(w);
        }
    }
}

// ---- Size and view ----

fn inset(w: *Widget) i32 {
    w.app.ensureStyle(w);
    const bd: i32 = @intFromFloat(@ceil(w.style.border_width[0]));
    return bd + @max(optInt(w, "-highlightthickness"), 0);
}

fn measure(w: *Widget) geom.Size {
    const i = inset(w);
    return .{ .w = @max(optInt(w, "-width"), 0) + 2 * i, .h = @max(optInt(w, "-height"), 0) + 2 * i };
}

/// The size of the window: the geometry after the first layout, else the requested size.
fn winSize(w: *Widget) [2]f64 {
    if (w.mapped or w.geom.w > 1) return .{ @floatFromInt(w.geom.w), @floatFromInt(w.geom.h) };
    const m = measure(w);
    return .{ @floatFromInt(m.w), @floatFromInt(m.h) };
}

/// Gives the views the sizes of the region and of the window.
fn syncViews(w: *Widget) void {
    const d = dataOf(w);
    const r = d.region orelse return;
    const s = winSize(w);
    const i: f64 = @floatFromInt(inset(w));
    d.vx.setSize(r[2] - r[0], s[0] - 2 * i);
    d.vy.setSize(r[3] - r[1], s[1] - 2 * i);
}

/// The canvas point at the top-left corner of the window: the target of the view.
fn origin(w: *Widget) [2]f64 {
    const d = dataOf(w);
    const r = d.region orelse return .{ d.free_x, d.free_y };
    syncViews(w);
    const i: f64 = @floatFromInt(inset(w));
    return .{ r[0] - i + d.vx.pos, r[1] - i + d.vy.pos };
}

/// The origin that the paint shows, during a smooth scroll.
fn shownOrigin(w: *Widget) [2]f64 {
    const d = dataOf(w);
    const r = d.region orelse return .{ d.free_x, d.free_y };
    const i: f64 = @floatFromInt(inset(w));
    return .{ r[0] - i + d.vx.shown(w), r[1] - i + d.vy.shown(w) };
}

// ---- Items ----

const NameCheck = struct {
    w: *Widget,

    fn image(ctx: *anyopaque, name: []const u8) bool {
        const c: *NameCheck = @ptrCast(@alignCast(ctx));
        return c.w.app.images.find(name) != null;
    }

    fn bitmap(ctx: *anyopaque, name: []const u8) bool {
        _ = ctx;
        return bitmaps.find(name) != null;
    }

    fn window(ctx: *anyopaque, name: []const u8) ?[]const u8 {
        const c: *NameCheck = @ptrCast(@alignCast(ctx));
        const a = c.w.app.it.alloc();
        const child = c.w.app.find(name) orelse return std.fmt.allocPrint(a, "bad window path name \"{s}\"", .{name}) catch "bad window";
        // As in Tk, the window is a child of the canvas or of one of its
        // ancestors.
        var ok = false;
        if (!child.isToplevel()) {
            var x: ?*Widget = c.w;
            while (x) |p| : (x = p.parent) {
                if (child.parent == p) ok = true;
                if (p.isToplevel()) break;
            }
        }
        if (!ok) return std.fmt.allocPrint(a, "can't use {s} in a window item of this canvas", .{name}) catch "bad window";
        return null;
    }

    fn names(c: *NameCheck) items.Names {
        return .{ .ctx = c, .image = image, .bitmap = bitmap, .window = window };
    }
};

/// Parses each option of an item again from its texts and the defaults.
fn reparse(w: *Widget, item: *ItemT) void {
    var nc: NameCheck = .{ .w = w };
    var buf: [256]u8 = undefined;
    var a: items.Attr = .{};
    const opts = items.optsOf(item.type);
    for (opts, item.vals) |o, v| {
        const text = v orelse o.default;
        // A name that went away (a deleted image) keeps its text, and the item draws no quad.
        _ = items.parse(&a, o.field, text, w.app.scaling, nc.names(), &buf);
    }
    item.attr = a;
    item.fill_theme = false;
    item.outline_theme = false;
    for (opts, item.vals) |o, v| if (v == null and std.mem.eql(u8, o.default, "#000000")) {
        if (o.field == .fill or o.field == .foreground) item.fill_theme = true;
        if (o.field == .outline) item.outline_theme = true;
    };
    item.box_ok = false;
    item.text_cache.free(w.app.gpa);
}

/// Sets the options of an item from name and value pairs. On an error no option changes.
fn configureItem(w: *Widget, it: *ztcl.Interp, item: *ItemT, pairs: []const Value) ztcl.Error!void {
    const gpa = w.app.gpa;
    const opts = items.optsOf(item.type);
    var nc: NameCheck = .{ .w = w };
    var buf: [256]u8 = undefined;
    // Check each value first.
    var probe = item.attr;
    var k: usize = 0;
    while (k < pairs.len) : (k += 2) {
        const name = try it.str(pairs[k]);
        const i = try findOpt(it, opts, name);
        if (k + 1 >= pairs.len) return it.fail("value for \"{s}\" missing", .{name});
        const text = try it.str(pairs[k + 1]);
        if (items.parse(&probe, opts[i].field, text, w.app.scaling, nc.names(), &buf)) |m| return it.fail("{s}", .{m});
    }
    k = 0;
    while (k < pairs.len) : (k += 2) {
        const i = try findOpt(it, opts, try it.str(pairs[k]));
        const text = try it.str(pairs[k + 1]);
        if (opts[i].field == .tags) {
            for (item.tags.items) |t| gpa.free(t);
            item.tags.clearRetainingCapacity();
            for (try it.list(pairs[k + 1])) |tv| {
                const t = try it.str(tv);
                if (!item.hasTag(t)) try item.tags.append(gpa, try gpa.dupe(u8, t));
            }
            continue;
        }
        if (opts[i].field == .window) try setWindow(w, item, text);
        if (item.vals[i]) |old| gpa.free(old);
        item.vals[i] = try gpa.dupe(u8, text);
    }
    reparse(w, item);
    if (item.type == .text) item.insert = @min(item.insert, charLen(item.attr.text));
}

fn findOpt(it: *ztcl.Interp, opts: []const items.Opt, name: []const u8) ztcl.Error!usize {
    var found: ?usize = null;
    var hits: usize = 0;
    if (name.len > 1 and name[0] == '-') for (opts, 0..) |o, i| {
        if (std.mem.eql(u8, o.name, name)) return i;
        if (std.mem.startsWith(u8, o.name, name)) {
            found = i;
            hits += 1;
        }
    };
    if (hits == 1) return found.?;
    return it.fail("unknown option \"{s}\"", .{name});
}

fn itemOptText(item: *const ItemT, it: *ztcl.Interp, i: usize) ztcl.Error![]const u8 {
    const o = items.optsOf(item.type)[i];
    if (o.field == .tags) return try listText(it, item);
    return item.vals[i] orelse o.default;
}

fn listText(it: *ztcl.Interp, item: *const ItemT) ztcl.Error![]const u8 {
    const a = it.alloc();
    var out: std.ArrayList(u8) = .empty;
    for (item.tags.items, 0..) |t, k| {
        if (k > 0) try out.append(a, ' ');
        try ztcl.value.appendElement(a, &out, t, k == 0);
    }
    return out.items;
}

fn charLen(s: []const u8) usize {
    var n: usize = 0;
    for (s) |c| {
        if (c & 0xC0 != 0x80) n += 1;
    }
    return n;
}

fn byteOf(s: []const u8, chars: usize) usize {
    var n: usize = 0;
    for (s, 0..) |c, i| {
        if (c & 0xC0 != 0x80) {
            if (n == chars) return i;
            n += 1;
        }
    }
    return s.len;
}

fn expectCoords(it: *ztcl.Interp, t: items.Type, n: usize) ztcl.Error!void {
    switch (t) {
        .rectangle, .oval, .arc => if (n != 4) return it.fail("wrong # coordinates: expected {s}4, got {d}", .{ if (n == 0) "" else "0 or ", n }),
        .line => {
            if (n % 2 == 1) return it.fail("wrong # coordinates: expected an even number, got {d}", .{n});
            if (n < 4) return it.fail("wrong # coordinates: expected at least 4, got {d}", .{n});
        },
        .polygon => {
            if (n % 2 == 1) return it.fail("wrong # coordinates: expected an even number, got {d}", .{n});
            if (n < 6) return it.fail("wrong # coordinates: expected at least 6, got {d}", .{n});
        },
        else => if (n != 2) return it.fail("wrong # coordinates: expected 2, got {d}", .{n}),
    }
}

/// Reads coordinates: separate words, or one list.
fn readCoords(w: *Widget, it: *ztcl.Interp, args: []const Value, out: *std.ArrayListUnmanaged(f64)) ztcl.Error!void {
    var vals = args;
    if (args.len == 1) vals = try it.list(args[0]);
    for (vals) |v| {
        const t = try it.str(v);
        const f = items.parseDist(t, w.app.scaling) orelse return it.fail("bad screen distance \"{s}\"", .{t});
        try out.append(it.alloc(), f);
    }
}

fn createItem(w: *Widget, it: *ztcl.Interp, argv: []const Value) ztcl.Error!Value {
    const d = dataOf(w);
    const gpa = w.app.gpa;
    if (argv.len < 3) return it.fail("wrong # args: should be \"{s} create type coords ?arg ...?\"", .{w.path});
    const tname = try it.str(argv[2]);
    var ty: ?items.Type = null;
    var hits: usize = 0;
    for (items.type_names, 0..) |n, i| if (tname.len > 0 and std.mem.startsWith(u8, n, tname)) {
        if (std.mem.eql(u8, n, tname)) {
            ty = @enumFromInt(i);
            hits = 1;
            break;
        }
        ty = @enumFromInt(i);
        hits += 1;
    };
    if (hits != 1) return it.fail("unknown or ambiguous item type \"{s}\"", .{tname});
    const t = ty.?;
    // The coordinates go up to the first word that starts with "-" and a letter.
    var end: usize = 3;
    while (end < argv.len) : (end += 1) {
        const s = try it.str(argv[end]);
        if (s.len >= 2 and s[0] == '-' and std.ascii.isAlphabetic(s[1])) break;
    }
    var cs: std.ArrayListUnmanaged(f64) = .empty;
    try readCoords(w, it, argv[3..end], &cs);
    try expectCoords(it, t, cs.items.len);
    const item = try gpa.create(ItemT);
    const nopts = items.optsOf(t).len;
    item.* = .{ .id = d.next_id, .type = t, .vals = try gpa.alloc(?[]u8, nopts) };
    @memset(item.vals, null);
    try item.coords.appendSlice(gpa, cs.items);
    reparse(w, item);
    configureItem(w, it, item, argv[end..]) catch |e| {
        item.free(gpa);
        return e;
    };
    d.next_id += 1;
    try d.list.append(gpa, item);
    try d.ids.put(gpa, item.id, item);
    if (item.type == .window) d.windows += 1;
    changed(w);
    return .{ .int = item.id };
}

fn deleteItem(w: *Widget, item: *ItemT) void {
    const d = dataOf(w);
    const gpa = w.app.gpa;
    if (d.current == item) d.current = null;
    if (d.focus_item == item) d.focus_item = null;
    if (d.sel_item == item) d.sel_item = null;
    if (item.type == .window) {
        if (item.win) |c| unmanage(c);
        d.windows -|= 1;
    }
    var buf: [16]u8 = undefined;
    d.bindings.removeTag(std.fmt.bufPrint(&buf, "{d}", .{item.id}) catch "");
    _ = d.ids.remove(item.id);
    for (d.list.items, 0..) |x, i| if (x == item) {
        _ = d.list.orderedRemove(i);
        break;
    };
    item.free(gpa);
}

// ---- Search ----

const Search = struct {
    q: tags_mod.Query,
    d: *Data,

    fn has(s: *const Search, item: *const ItemT, t: []const u8) bool {
        if (std.mem.eql(u8, t, "current")) return s.d.current == item;
        if (std.mem.eql(u8, t, "all")) return true;
        return item.hasTag(t);
    }

    fn matches(s: *const Search, item: *const ItemT) bool {
        return switch (s.q) {
            .all => true,
            .id => |id| item.id == id,
            .tag => |t| s.has(item, t),
            .expr => |e| tags_mod.eval(e, Ctx{ .s = s, .item = item }, Ctx.hasTag),
        };
    }

    const Ctx = struct {
        s: *const Search,
        item: *const ItemT,
        fn hasTag(c: Ctx, t: []const u8) bool {
            return c.s.has(c.item, t);
        }
    };
};

fn search(w: *Widget, it: *ztcl.Interp, v: Value) ztcl.Error!Search {
    const text = try it.str(v);
    const q = tags_mod.parse(it.alloc(), text) catch |e| return it.fail("{s}", .{tags_mod.message(e)});
    return .{ .q = q, .d = dataOf(w) };
}

/// The items that match, bottom first.
fn matching(w: *Widget, it: *ztcl.Interp, v: Value) ztcl.Error![]*ItemT {
    const s = try search(w, it, v);
    const d = dataOf(w);
    if (s.q == .id) {
        const one = d.ids.get(s.q.id) orelse return &.{};
        const out = try it.alloc().alloc(*ItemT, 1);
        out[0] = one;
        return out;
    }
    var out: std.ArrayListUnmanaged(*ItemT) = .empty;
    for (d.list.items) |item| if (s.matches(item)) try out.append(it.alloc(), item);
    return out.items;
}

/// The first item that matches, bottom first.
fn first(w: *Widget, it: *ztcl.Interp, v: Value) ztcl.Error!?*ItemT {
    const m = try matching(w, it, v);
    return if (m.len > 0) m[0] else null;
}

fn idsValue(it: *ztcl.Interp, list: []const *ItemT) ztcl.Error!Value {
    const a = it.alloc();
    const vals = try a.alloc(Value, list.len);
    for (list, vals) |item, *s| s.* = .{ .int = item.id };
    return try ztcl.value.wrapList(a, vals);
}

fn indexOf(d: *Data, item: *const ItemT) usize {
    for (d.list.items, 0..) |x, i| if (x == item) return i;
    return 0;
}

fn effState(w: *const Widget, item: *const ItemT) items.State {
    if (item.attr.state != .inherit) return item.attr.state;
    return if (canvasDisabled(w)) .disabled else .normal;
}

/// The items for a search command: `above`, `all`, `below`, `closest`, `enclosed`, `overlapping`, `withtag`.
fn findItems(w: *Widget, it: *ztcl.Interp, argv: []const Value, cmd: []const u8) ztcl.Error![]*ItemT {
    const d = dataOf(w);
    const a = it.alloc();
    if (argv.len < 1) return it.fail("wrong # args: should be \"{s} find searchCommand ?arg ...?\"", .{w.path});
    const sc = try it.str(argv[0]);
    const words = [_][]const u8{ "above", "all", "below", "closest", "enclosed", "overlapping", "withtag" };
    var which: ?usize = null;
    for (words, 0..) |x, i| if (sc.len > 0 and std.mem.startsWith(u8, x, sc)) {
        which = i;
    };
    const k = which orelse return it.fail("bad search command \"{s}\": must be above, all, below, closest, enclosed, overlapping, or withtag", .{sc});
    const usage = [_][]const u8{ "above tagOrId", "all", "below tagOrId", "closest x y ?halo? ?start?", "enclosed x1 y1 x2 y2", "overlapping x1 y1 x2 y2", "withtag tagOrId" };
    const counts = [_][2]usize{ .{ 2, 2 }, .{ 1, 1 }, .{ 2, 2 }, .{ 3, 5 }, .{ 5, 5 }, .{ 5, 5 }, .{ 2, 2 } };
    if (argv.len < counts[k][0] or argv.len > counts[k][1]) return it.fail("wrong # args: should be \"{s} {s} {s}\"", .{ w.path, cmd, usage[k] });
    var out: std.ArrayListUnmanaged(*ItemT) = .empty;
    switch (k) {
        0, 2 => {
            const m = try matching(w, it, argv[1]);
            if (m.len == 0) return &.{};
            const base = if (k == 0) m[m.len - 1] else m[0];
            const i = indexOf(d, base);
            if (k == 0 and i + 1 < d.list.items.len) try out.append(a, d.list.items[i + 1]);
            if (k == 2 and i > 0) try out.append(a, d.list.items[i - 1]);
        },
        1 => try out.appendSlice(a, d.list.items),
        6 => return matching(w, it, argv[1]),
        3 => {
            const x = try dist(w, it, argv[1]);
            const y = try dist(w, it, argv[2]);
            const halo: f64 = if (argv.len > 3) @max(try dist(w, it, argv[3]), 0) else 0;
            var start_i: usize = d.list.items.len;
            if (argv.len > 4) if (try first(w, it, argv[4])) |s| {
                start_i = indexOf(d, s);
            };
            if (closest(w, x, y, halo, start_i)) |c| try out.append(a, c);
        },
        4, 5 => {
            var r: [4]f64 = undefined;
            for (0..4) |i| r[i] = try dist(w, it, argv[1 + i]);
            if (r[0] > r[2] or r[1] > r[3]) return it.fail("area specified is invalid", .{});
            for (d.list.items) |item| {
                if (effState(w, item) == .hidden) continue;
                const b = itemBox(w, item) orelse continue;
                const fb = [4]f64{ @floatFromInt(b[0]), @floatFromInt(b[1]), @floatFromInt(b[2]), @floatFromInt(b[3]) };
                if (k == 4) {
                    if (fb[0] >= r[0] and fb[1] >= r[1] and fb[2] <= r[2] and fb[3] <= r[3]) try out.append(a, item);
                } else if (overlaps(w, item, r)) try out.append(a, item);
            }
        },
        else => unreachable,
    }
    return out.items;
}

fn dist(w: *Widget, it: *ztcl.Interp, v: Value) ztcl.Error!f64 {
    const t = try it.str(v);
    return items.parseDist(t, w.app.scaling) orelse it.fail("bad screen distance \"{s}\"", .{t});
}

/// The top item nearest to a point within the halo. With `before`, the
/// search goes down from the item below that index, and wraps.
fn closest(w: *Widget, x: f64, y: f64, halo: f64, before: usize) ?*ItemT {
    const d = dataOf(w);
    var best: ?*ItemT = null;
    var best_d: f64 = std.math.inf(f64);
    const n = d.list.items.len;
    if (n == 0) return null;
    var k: usize = 0;
    while (k < n) : (k += 1) {
        // From the top down, starting below `before`.
        const i = (before + 2 * n - 1 - k) % n;
        const item = d.list.items[i];
        if (effState(w, item) == .hidden) continue;
        const dd = itemDist(w, item, x, y);
        if (dd <= halo and best_d > halo) return item;
        if (dd < best_d) {
            best_d = dd;
            best = item;
        }
    }
    return best;
}

fn overlaps(w: *Widget, item: *ItemT, r: [4]f64) bool {
    const b = itemBox(w, item) orelse return false;
    if (@as(f64, @floatFromInt(b[2])) < r[0] or @as(f64, @floatFromInt(b[0])) > r[2] or @as(f64, @floatFromInt(b[3])) < r[1] or @as(f64, @floatFromInt(b[1])) > r[3]) return false;
    // A line or a polygon: a sample grid of the area must be near the shape.
    switch (item.type) {
        .line, .polygon, .arc, .oval => {
            const cx = std.math.clamp((r[0] + r[2]) / 2, r[0], r[2]);
            const cy = std.math.clamp((r[1] + r[3]) / 2, r[1], r[3]);
            const half = @max(r[2] - r[0], r[3] - r[1]) / 2;
            const dd = itemDist(w, item, cx, cy);
            if (dd <= half * std.math.sqrt2) return true;
            return false;
        },
        else => return true,
    }
}

/// The width of the outline that an item shows now.
fn shownWidth(w: *const Widget, item: *const ItemT) f64 {
    const a = &item.attr;
    const st = effState(w, item);
    if (st == .disabled and a.disabled_width > 0) return a.disabled_width;
    if (st == .normal and dataOf(w).current == item and a.active_width > 0) return a.active_width;
    return a.width;
}

/// The distance from a point to an item, 0 inside.
fn itemDist(w: *Widget, item: *ItemT, x: f64, y: f64) f64 {
    const c = item.coords.items;
    const a = &item.attr;
    const wd = shownWidth(w, item);
    switch (item.type) {
        .rectangle, .oval => {
            const k = items.corners(c);
            const h = if (a.outline != null) wd / 2 else 0;
            if (item.type == .rectangle) {
                const outer = items.boxDist(.{ k[0] - h, k[1] - h, k[2] + h, k[3] + h }, x, y);
                if (outer > 0 or a.fill != null) return outer;
                // An empty rectangle: the distance to the outline.
                const inner = @min(x - (k[0] + h), (k[2] - h) - x, y - (k[1] + h), (k[3] - h) - y);
                return @max(inner, 0);
            }
            const cx = (k[0] + k[2]) / 2;
            const cy = (k[1] + k[3]) / 2;
            const rx = @max((k[2] - k[0]) / 2, 0.5);
            const ry = @max((k[3] - k[1]) / 2, 0.5);
            const nx = (x - cx) / rx;
            const ny = (y - cy) / ry;
            const r = @sqrt(nx * nx + ny * ny);
            const scale_r = @min(rx, ry);
            const edge = (r - 1) * scale_r;
            if (edge <= h) {
                if (a.fill != null or edge >= -h) return 0;
                return -edge - h;
            }
            return edge - h;
        },
        .line, .polygon => {
            var best: f64 = std.math.inf(f64);
            const n = c.len / 2;
            if (n == 0) return best;
            var i: usize = 0;
            while (i + 1 < n) : (i += 1) best = @min(best, items.segDist(x, y, c[2 * i], c[2 * i + 1], c[2 * i + 2], c[2 * i + 3]));
            if (item.type == .polygon) {
                best = @min(best, items.segDist(x, y, c[2 * n - 2], c[2 * n - 1], c[0], c[1]));
                var buf: [512][2]f64 = undefined;
                const m = @min(n, buf.len);
                for (0..m) |k| buf[k] = .{ c[2 * k], c[2 * k + 1] };
                if (a.fill != null and items.inPolygon(buf[0..m], x, y)) return 0;
                const h = if (a.outline != null) wd / 2 else 0;
                return @max(best - h, 0);
            }
            return @max(best - @max(wd, 1) / 2, 0);
        },
        .arc => {
            if (c.len < 4) return std.math.inf(f64);
            const k = items.corners(c);
            var buf: [16384]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&buf);
            var pts: std.ArrayListUnmanaged(path.Pt) = .empty;
            items.arcPoints(fba.allocator(), &pts, k, a.start, a.extent, 1, 1, 0, 0) catch return std.math.inf(f64);
            if (a.arc_style == .pieslice) pts.append(fba.allocator(), .{ .x = @floatCast((k[0] + k[2]) / 2), .y = @floatCast((k[1] + k[3]) / 2) }) catch {};
            const n = pts.items.len;
            var best: f64 = std.math.inf(f64);
            const closed = a.arc_style != .arc;
            for (0..n) |i| {
                if (i + 1 == n and !closed) break;
                const p0 = pts.items[i];
                const p1 = pts.items[(i + 1) % n];
                best = @min(best, items.segDist(x, y, p0.x, p0.y, p1.x, p1.y));
            }
            if (closed and a.fill != null) {
                var poly: [1024][2]f64 = undefined;
                const m = @min(n, poly.len);
                for (0..m) |i| poly[i] = .{ pts.items[i].x, pts.items[i].y };
                if (items.inPolygon(poly[0..m], x, y)) return 0;
            }
            return @max(best - (if (a.outline != null) wd / 2 else 0), 0);
        },
        else => {
            const b = itemBox(w, item) orelse return std.math.inf(f64);
            return items.boxDist(.{ @floatFromInt(b[0]), @floatFromInt(b[1]), @floatFromInt(b[2]), @floatFromInt(b[3]) }, x, y);
        },
    }
}

// ---- The extent of text, images, bitmaps, and windows ----

fn itemFont(w: *Widget, item: *const ItemT) font_mod.FontDesc {
    w.app.ensureStyle(w);
    return @import("../fontcmd.zig").parse(w.app, item.attr.font, w.style.font) orelse w.style.font;
}

/// Shapes the lines of a text item for a scale, when the cache has another scale.
fn textLayout(w: *Widget, item: *ItemT, scale: f32) !*TextCache {
    const c = &item.text_cache;
    if (c.scale == scale and c.runs.len > 0) return c;
    const gpa = w.app.gpa;
    c.free(gpa);
    const desc = itemFont(w, item);
    const text = item.attr.text;
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer lines.deinit(gpa);
    if (item.attr.text_width > 0) {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const wrapped = try paint.wrapLines(w.app, arena.allocator(), text, desc, @intFromFloat(item.attr.text_width));
        // The lines of `wrapLines` are slices of the text.
        for (wrapped) |l| try lines.append(gpa, l);
    } else {
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |l| try lines.append(gpa, l);
    }
    const font = try w.app.fonts.get(desc, scale);
    const m = font_mod.Fonts.metrics(font);
    const mfont = try w.app.fonts.get(desc, 1);
    const mm = font_mod.Fonts.metrics(mfont);
    c.runs = try gpa.alloc(shape.Run, lines.items.len);
    var n: usize = 0;
    errdefer {
        for (c.runs[0..n]) |*r| r.deinit(gpa);
        gpa.free(c.runs);
        c.runs = &.{};
    }
    c.starts = try gpa.alloc(usize, lines.items.len);
    var width: f64 = 0;
    for (lines.items, 0..) |l, i| {
        c.runs[i] = try shape.shape(gpa, font, l);
        n += 1;
        c.starts[i] = @intFromPtr(l.ptr) - @intFromPtr(text.ptr);
        width = @max(width, @as(f64, @floatFromInt(c.runs[i].width)) / scale);
    }
    c.lines = try lines.toOwnedSlice(gpa);
    c.width = width;
    c.ascent = mm.ascent;
    c.line_h = mm.line_height;
    _ = m;
    c.scale = scale;
    return c;
}

fn pixSize(w: *Widget, item: *const ItemT) [2]f64 {
    const a = &item.attr;
    switch (item.type) {
        .image => {
            const p = w.app.images.find(imageName(w, item)) orelse return .{ 0, 0 };
            return .{ @floatFromInt(p.width), @floatFromInt(p.height) };
        },
        .bitmap => {
            const bm = bitmaps.find(bitmapName(w, item)) orelse return .{ 0, 0 };
            return .{ @floatFromInt(bm.w), @floatFromInt(bm.h) };
        },
        .window => {
            const c = item.win orelse return .{ 0, 0 };
            return .{ if (a.win_width > 0) a.win_width else @floatFromInt(c.req.w), if (a.win_height > 0) a.win_height else @floatFromInt(c.req.h) };
        },
        else => return .{ 0, 0 },
    }
}

fn imageName(w: *const Widget, item: *const ItemT) []const u8 {
    const a = &item.attr;
    const st = effState(w, item);
    if (st == .disabled and a.disabled_image.len > 0) return a.disabled_image;
    if (st == .normal and dataOf(w).current == item and a.active_image.len > 0) return a.active_image;
    return a.image;
}

fn bitmapName(w: *const Widget, item: *const ItemT) []const u8 {
    const a = &item.attr;
    const st = effState(w, item);
    if (st == .disabled and a.disabled_bitmap.len > 0) return a.disabled_bitmap;
    if (st == .normal and dataOf(w).current == item and a.active_bitmap.len > 0) return a.active_bitmap;
    return a.bitmap;
}

/// The bounding box of an item, from the cache.
fn itemBox(w: *Widget, item: *ItemT) ?items.Box {
    if (item.box_ok) return item.box;
    var extra: [4]f64 = .{ 0, 0, 0, 0 };
    const c = item.coords.items;
    switch (item.type) {
        .text => if (c.len >= 2) {
            const tc = textLayout(w, item, 1) catch null;
            if (tc) |t| {
                const h: f64 = @floatFromInt(t.line_h * @as(i32, @intCast(t.lines.len)));
                const wd = @max(t.width, 1);
                const o = items.anchorOrigin(item.attr.anchor, c[0], c[1], wd, h);
                extra = .{ o[0], o[1], o[0] + wd, o[1] + h };
            }
        },
        .image, .bitmap, .window => if (c.len >= 2) {
            const s = pixSize(w, item);
            const o = items.anchorPixel(item.attr.anchor, c[0], c[1], s[0], s[1]);
            extra = .{ o[0], o[1], o[0] + s[0], o[1] + s[1] };
        },
        else => {},
    }
    item.extent = extra;
    item.box = items.bbox(item.type, &item.attr, c, shownWidth(w, item), extra);
    // The extent of an image or a window can change with no change of the item.
    item.box_ok = item.type != .image and item.type != .window;
    return item.box;
}

fn touch(w: *Widget, item: *ItemT) void {
    item.box_ok = false;
    changed(w);
}

// ---- The subcommands ----

const unsupported = [_][]const u8{"postscript"};

fn subcommand(w: *Widget, it: *ztcl.Interp, argv: []const Value) ztcl.Error!?Value {
    const sub = try it.str(argv[1]);
    const d = dataOf(w);
    const a = it.alloc();
    const gpa = w.app.gpa;
    const args = argv[2..];
    for (unsupported) |u| if (std.mem.eql(u8, sub, u)) return it.fail("{s} is not supported in this stage", .{u});
    if (std.mem.eql(u8, sub, "create")) return try createItem(w, it, argv);
    if (std.mem.eql(u8, sub, "xview") or std.mem.eql(u8, sub, "yview")) return try view(w, it, argv, sub[0] == 'y');
    if (std.mem.eql(u8, sub, "coords")) {
        if (args.len < 1) return it.fail("wrong # args: should be \"{s} coords tagOrId ?x y x y ...?\"", .{w.path});
        const item = (try first(w, it, args[0])) orelse return Value.empty;
        if (args.len == 1) {
            const vals = try a.alloc(Value, item.coords.items.len);
            for (item.coords.items, vals) |c, *s| s.* = .{ .str = try options.formatDouble(a, c) };
            return try ztcl.value.wrapList(a, vals);
        }
        var cs: std.ArrayListUnmanaged(f64) = .empty;
        try readCoords(w, it, args[1..], &cs);
        try expectCoords(it, item.type, cs.items.len);
        item.coords.clearRetainingCapacity();
        try item.coords.appendSlice(gpa, cs.items);
        touch(w, item);
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "itemconfigure")) {
        if (args.len < 1) return it.fail("wrong # args: should be \"{s} itemconfigure tagOrId ?-option value ...?\"", .{w.path});
        const list = try matching(w, it, args[0]);
        if (args.len <= 2) {
            if (list.len == 0) return Value.empty;
            const item = list[0];
            const opts = items.optsOf(item.type);
            if (args.len == 2) {
                const i = try findOpt(it, opts, try it.str(args[1]));
                return try optEntry(it, item, i);
            }
            const vals = try a.alloc(Value, opts.len);
            for (vals, 0..) |*s, i| s.* = try optEntry(it, item, i);
            return try ztcl.value.wrapList(a, vals);
        }
        for (list) |item| {
            try configureItem(w, it, item, args[1..]);
            touch(w, item);
        }
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "itemcget")) {
        if (args.len != 2) return it.fail("wrong # args: should be \"{s} itemcget tagOrId option\"", .{w.path});
        const item = (try first(w, it, args[0])) orelse return Value.empty;
        const i = try findOpt(it, items.optsOf(item.type), try it.str(args[1]));
        return .{ .str = try a.dupe(u8, try itemOptText(item, it, i)) };
    }
    if (std.mem.eql(u8, sub, "delete")) {
        for (args) |v| {
            const list = try matching(w, it, v);
            for (list) |item| if (!item.deleted) {
                item.deleted = true;
                deleteItem(w, item);
            };
        }
        changed(w);
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "move") or std.mem.eql(u8, sub, "moveto")) {
        const to = sub.len == 6;
        if (args.len != 3) return it.fail("wrong # args: should be \"{s} {s} tagOrId {s}\"", .{ w.path, sub, if (to) "x y" else "xAmount yAmount" });
        const list = try matching(w, it, args[0]);
        var dx: f64 = 0;
        var dy: f64 = 0;
        if (to) {
            if (list.len == 0) return Value.empty;
            const tx = try it.str(args[1]);
            const ty = try it.str(args[2]);
            // An empty value keeps the axis. The first coordinates of the first item go to the point.
            const c = list[0].coords.items;
            if (c.len < 2) return Value.empty;
            dx = if (tx.len == 0) 0 else (try dist(w, it, args[1])) - c[0];
            dy = if (ty.len == 0) 0 else (try dist(w, it, args[2])) - c[1];
            // Tk moves by the bounding box corner of the whole set for `moveto`.
            var bx: ?f64 = null;
            var by: ?f64 = null;
            for (list) |item| if (itemBox(w, item)) |b| {
                bx = @min(bx orelse @as(f64, @floatFromInt(b[0])), @as(f64, @floatFromInt(b[0])));
                by = @min(by orelse @as(f64, @floatFromInt(b[1])), @as(f64, @floatFromInt(b[1])));
            };
            if (tx.len > 0 and bx != null) dx = (try dist(w, it, args[1])) - bx.?;
            if (ty.len > 0 and by != null) dy = (try dist(w, it, args[2])) - by.?;
        } else {
            dx = try dist(w, it, args[1]);
            dy = try dist(w, it, args[2]);
        }
        for (list) |item| {
            moveItem(item, dx, dy);
            touch(w, item);
        }
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "scale")) {
        if (args.len != 5) return it.fail("wrong # args: should be \"{s} scale tagOrId xOrigin yOrigin xScale yScale\"", .{w.path});
        const ox = try dist(w, it, args[1]);
        const oy = try dist(w, it, args[2]);
        const sx = try dbl(it, args[3]);
        const sy = try dbl(it, args[4]);
        for (try matching(w, it, args[0])) |item| {
            const c = item.coords.items;
            var i: usize = 0;
            // A text, image, bitmap, or window item moves its point only.
            while (i + 1 < c.len) : (i += 2) {
                c[i] = ox + (c[i] - ox) * sx;
                c[i + 1] = oy + (c[i + 1] - oy) * sy;
            }
            touch(w, item);
        }
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "addtag")) {
        if (args.len < 2) return it.fail("wrong # args: should be \"{s} addtag tag searchCommand ?arg ...?\"", .{w.path});
        const tag = try it.str(args[0]);
        const list = try findItems(w, it, args[1..], "addtag");
        for (list) |item| if (!item.hasTag(tag)) try item.tags.append(gpa, try gpa.dupe(u8, tag));
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "dtag")) {
        if (args.len < 1 or args.len > 2) return it.fail("wrong # args: should be \"{s} dtag tagOrId ?tagToDelete?\"", .{w.path});
        const tag = try it.str(args[if (args.len == 2) 1 else 0]);
        for (try matching(w, it, args[0])) |item| {
            var i: usize = 0;
            while (i < item.tags.items.len) {
                if (std.mem.eql(u8, item.tags.items[i], tag)) {
                    gpa.free(item.tags.orderedRemove(i));
                } else i += 1;
            }
        }
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "gettags")) {
        if (args.len != 1) return it.fail("wrong # args: should be \"{s} gettags tagOrId\"", .{w.path});
        const item = (try first(w, it, args[0])) orelse return Value.empty;
        var out: std.ArrayList(u8) = .empty;
        for (item.tags.items, 0..) |t, k| {
            if (k > 0) try out.append(a, ' ');
            try ztcl.value.appendElement(a, &out, t, k == 0);
        }
        if (d.current == item) {
            if (item.tags.items.len > 0) try out.append(a, ' ');
            try out.appendSlice(a, "current");
        }
        return .{ .str = out.items };
    }
    if (std.mem.eql(u8, sub, "find")) return try idsValue(it, try findItems(w, it, args, "find"));
    if (std.mem.eql(u8, sub, "type")) {
        if (args.len != 1) return it.fail("wrong # args: should be \"{s} type tag\"", .{w.path});
        const item = (try first(w, it, args[0])) orelse return Value.empty;
        return .{ .str = items.type_names[@intFromEnum(item.type)] };
    }
    if (std.mem.eql(u8, sub, "bbox")) {
        if (args.len < 1) return it.fail("wrong # args: should be \"{s} bbox tagOrId ?tagOrId ...?\"", .{w.path});
        var r: ?items.Box = null;
        for (args) |v| for (try matching(w, it, v)) |item| {
            if (effState(w, item) == .hidden) continue;
            const b = itemBox(w, item) orelse continue;
            r = if (r) |o| .{ @min(o[0], b[0]), @min(o[1], b[1]), @max(o[2], b[2]), @max(o[3], b[3]) } else b;
        };
        const b = r orelse return Value.empty;
        return try ztcl.value.newList(a, &.{ .{ .int = b[0] }, .{ .int = b[1] }, .{ .int = b[2] }, .{ .int = b[3] } });
    }
    if (std.mem.eql(u8, sub, "raise") or std.mem.eql(u8, sub, "lower")) {
        const up = sub[0] == 'r';
        if (args.len < 1 or args.len > 2) return it.fail("wrong # args: should be \"{s} {s} tagOrId ?{s}?\"", .{ w.path, sub, if (up) "aboveThis" else "belowThis" });
        const list = try matching(w, it, args[0]);
        if (list.len == 0) return Value.empty;
        var ref: ?*ItemT = null;
        if (args.len == 2) {
            const r = try matching(w, it, args[1]);
            if (r.len == 0) return it.fail("tagOrId \"{s}\" doesn't match any items", .{try it.str(args[1])});
            ref = if (up) r[r.len - 1] else r[0];
        }
        try restack(w, list, ref, up);
        changed(w);
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "bind")) return try bindItem(w, it, args);
    if (std.mem.eql(u8, sub, "canvasx") or std.mem.eql(u8, sub, "canvasy")) {
        if (args.len < 1 or args.len > 2) return it.fail("wrong # args: should be \"{s} {s} screen{c} ?gridspacing?\"", .{ w.path, sub, sub[6] });
        const s = try dist(w, it, args[0]);
        const o = origin(w)[if (sub[6] == 'y') 1 else 0];
        var v = s + o;
        if (args.len == 2) {
            const g = try dist(w, it, args[1]);
            if (g > 0) v = g * @floor(v / g + 0.5);
        }
        return .{ .str = try options.formatDouble(a, v) };
    }
    if (std.mem.eql(u8, sub, "scan")) {
        if (args.len < 3 or args.len > 4) return it.fail("wrong # args: should be \"{s} scan mark|dragto x y ?dragGain?\"", .{w.path});
        const op = try it.str(args[0]);
        const x: i32 = @intCast(std.math.clamp(try it.int(args[1]), -1 << 30, 1 << 30));
        const y: i32 = @intCast(std.math.clamp(try it.int(args[2]), -1 << 30, 1 << 30));
        if (std.mem.eql(u8, op, "mark")) {
            if (args.len != 3) return it.fail("wrong # args: should be \"{s} scan mark x y\"", .{w.path});
            d.scan_x = x;
            d.scan_y = y;
            const o = origin(w);
            d.scan_ox = o[0];
            d.scan_oy = o[1];
            return Value.empty;
        }
        if (std.mem.eql(u8, op, "dragto")) {
            const gain: f64 = if (args.len == 4) try dbl(it, args[3]) else 10;
            setOrigin(w, d.scan_ox - gain * @as(f64, @floatFromInt(x - d.scan_x)), d.scan_oy - gain * @as(f64, @floatFromInt(y - d.scan_y)), true);
            return Value.empty;
        }
        return it.fail("bad scan option \"{s}\": must be mark or dragto", .{op});
    }
    if (std.mem.eql(u8, sub, "focus")) {
        if (args.len > 1) return it.fail("wrong # args: should be \"{s} focus ?tagOrId?\"", .{w.path});
        if (args.len == 0) return if (d.focus_item) |f| .{ .int = f.id } else Value.empty;
        if ((try it.str(args[0])).len == 0) {
            d.focus_item = null;
        } else {
            for (try matching(w, it, args[0])) |item| if (editable(item)) {
                d.focus_item = item;
                break;
            };
        }
        changed(w);
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "select")) return try selectCmd(w, it, args);
    if (std.mem.eql(u8, sub, "icursor")) {
        if (args.len != 2) return it.fail("wrong # args: should be \"{s} icursor tagOrId index\"", .{w.path});
        for (try matching(w, it, args[0])) |item| if (item.type == .text) {
            item.insert = try textIndex(w, it, item, args[1]);
        };
        changed(w);
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "index")) {
        if (args.len != 2) return it.fail("wrong # args: should be \"{s} index tagOrId string\"", .{w.path});
        for (try matching(w, it, args[0])) |item| if (editable(item)) {
            return .{ .int = @intCast(try textIndex(w, it, item, args[1])) };
        };
        return it.fail("can't find an indexable item \"{s}\"", .{try it.str(args[0])});
    }
    if (std.mem.eql(u8, sub, "insert")) {
        if (args.len != 3) return it.fail("wrong # args: should be \"{s} insert tagOrId beforeThis string\"", .{w.path});
        for (try matching(w, it, args[0])) |item| try insertInto(w, it, item, args[1], args[2]);
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "dchars")) {
        if (args.len < 2 or args.len > 3) return it.fail("wrong # args: should be \"{s} dchars tagOrId first ?last?\"", .{w.path});
        for (try matching(w, it, args[0])) |item| try deleteChars(w, it, item, args[1], if (args.len == 3) args[2] else args[1]);
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "rchars")) {
        if (args.len != 4) return it.fail("wrong # args: should be \"{s} rchars tagOrId first last string\"", .{w.path});
        for (try matching(w, it, args[0])) |item| {
            if (!editable(item)) continue;
            const f = try textIndex(w, it, item, args[1]);
            try deleteChars(w, it, item, args[1], args[2]);
            try insertInto(w, it, item, .{ .int = @intCast(f) }, args[3]);
        }
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "imove")) {
        if (args.len != 4) return it.fail("wrong # args: should be \"{s} imove tagOrId index x y\"", .{w.path});
        const x = try dist(w, it, args[2]);
        const y = try dist(w, it, args[3]);
        for (try matching(w, it, args[0])) |item| {
            if (item.type != .line and item.type != .polygon) continue;
            const i = try coordIndex(w, it, item, args[1]);
            if (i + 1 < item.coords.items.len) {
                item.coords.items[i] = x;
                item.coords.items[i + 1] = y;
            }
            touch(w, item);
        }
        return Value.empty;
    }
    return null;
}

fn dbl(it: *ztcl.Interp, v: Value) ztcl.Error!f64 {
    const t = try it.str(v);
    const f = std.fmt.parseFloat(f64, std.mem.trim(u8, t, " ")) catch return it.fail("expected floating-point number but got \"{s}\"", .{t});
    if (!std.math.isFinite(f)) return it.fail("expected floating-point number but got \"{s}\"", .{t});
    return f;
}

fn optEntry(it: *ztcl.Interp, item: *const ItemT, i: usize) ztcl.Error!Value {
    const a = it.alloc();
    const o = items.optsOf(item.type)[i];
    return try ztcl.value.newList(a, &.{ .{ .str = o.name }, Value.empty, Value.empty, .{ .str = o.default }, .{ .str = try a.dupe(u8, try itemOptText(item, it, i)) } });
}

fn moveItem(item: *ItemT, dx: f64, dy: f64) void {
    const c = item.coords.items;
    var i: usize = 0;
    while (i + 1 < c.len) : (i += 2) {
        c[i] += dx;
        c[i + 1] += dy;
    }
}

/// Moves the items of `list` above or below `ref`, or to the top or the bottom, in their order.
fn restack(w: *Widget, list: []const *ItemT, ref: ?*ItemT, up: bool) !void {
    const d = dataOf(w);
    const gpa = w.app.gpa;
    var keep: std.ArrayListUnmanaged(*ItemT) = .empty;
    defer keep.deinit(gpa);
    for (d.list.items) |x| {
        var moving = false;
        for (list) |m| if (m == x) {
            moving = true;
        };
        if (!moving or x == ref) try keep.append(gpa, x);
    }
    // A reference item that also moves stays in place.
    var at: usize = if (up) keep.items.len else 0;
    if (ref) |r| {
        for (keep.items, 0..) |x, i| if (x == r) {
            at = if (up) i + 1 else i;
        };
    }
    d.list.clearRetainingCapacity();
    try d.list.appendSlice(gpa, keep.items[0..at]);
    for (list) |m| if (m != ref) try d.list.append(gpa, m);
    try d.list.appendSlice(gpa, keep.items[at..]);
}

fn bindItem(w: *Widget, it: *ztcl.Interp, args: []const Value) ztcl.Error!Value {
    const d = dataOf(w);
    const a = it.alloc();
    if (args.len < 1 or args.len > 3) return it.fail("wrong # args: should be \"{s} bind tagOrId ?sequence? ?command?\"", .{w.path});
    const tag = try it.str(args[0]);
    if (args.len == 1) {
        const pats = try d.bindings.list(tag, a);
        const vals = try a.alloc(Value, pats.len);
        for (pats, vals) |p, *s| {
            var buf: [128]u8 = undefined;
            s.* = .{ .str = try a.dupe(u8, bind.formatPattern(p, &buf)) };
        }
        return try ztcl.value.wrapList(a, vals);
    }
    const p = try bind.parsePattern(it, try it.str(args[1]));
    switch (p.type) {
        .key_press, .key_release, .button_press, .button_release, .motion, .enter, .leave, .virtual, .mouse_wheel => {},
        else => return it.fail("requested illegal events; only key, button, motion, enter, leave, and virtual events may be used", .{}),
    }
    if (args.len == 2) return .{ .str = try a.dupe(u8, d.bindings.get(tag, p) orelse "") };
    d.bindings.set(tag, p, try it.str(args[2])) catch return error.OutOfMemory;
    return Value.empty;
}

// ---- Text editing ----

fn editable(item: *const ItemT) bool {
    return item.type == .text or item.type == .line or item.type == .polygon;
}

/// A character index of a text item, or a coordinate index of a line or polygon.
fn textIndex(w: *Widget, it: *ztcl.Interp, item: *ItemT, v: Value) ztcl.Error!usize {
    if (item.type != .text) return coordIndex(w, it, item, v);
    const d = dataOf(w);
    const t = try it.str(v);
    const n = charLen(item.attr.text);
    if (std.mem.eql(u8, t, "end")) return n;
    if (std.mem.eql(u8, t, "insert")) return item.insert;
    if (std.mem.eql(u8, t, "sel.first") or std.mem.eql(u8, t, "sel.last")) {
        if (d.sel_item != item) return it.fail("selection isn't in item", .{});
        return if (t[4] == 'f') d.sel_first else d.sel_last;
    }
    if (t.len > 1 and t[0] == '@') {
        var parts = std.mem.splitScalar(u8, t[1..], ',');
        const xs = parts.next() orelse "";
        const ys = parts.next() orelse return it.fail("bad index \"{s}\"", .{t});
        const x = items.parseDist(xs, w.app.scaling) orelse return it.fail("bad index \"{s}\"", .{t});
        const y = items.parseDist(ys, w.app.scaling) orelse return it.fail("bad index \"{s}\"", .{t});
        return charAt(w, item, x, y);
    }
    const i = std.fmt.parseInt(i64, t, 10) catch return it.fail("bad index \"{s}\"", .{t});
    return @intCast(std.math.clamp(i, 0, @as(i64, @intCast(n))));
}

fn coordIndex(w: *Widget, it: *ztcl.Interp, item: *ItemT, v: Value) ztcl.Error!usize {
    _ = w;
    const t = try it.str(v);
    const n = item.coords.items.len;
    if (std.mem.eql(u8, t, "end")) return n;
    const i = std.fmt.parseInt(i64, t, 10) catch return it.fail("bad index \"{s}\"", .{t});
    const c: usize = @intCast(std.math.clamp(i, 0, @as(i64, @intCast(n))));
    return c & ~@as(usize, 1);
}

/// The character of a text item nearest to a canvas point.
fn charAt(w: *Widget, item: *ItemT, x: f64, y: f64) usize {
    const tc = textLayout(w, item, 1) catch return 0;
    _ = itemBox(w, item);
    const e = item.extent;
    if (tc.lines.len == 0) return 0;
    const li: usize = @intFromFloat(std.math.clamp(@floor((y - e[1]) / @as(f64, @floatFromInt(@max(tc.line_h, 1)))), 0, @as(f64, @floatFromInt(tc.lines.len - 1))));
    const lx = x - e[0] - lineShift(item, tc, li);
    const at = tc.runs[li].indexAt(tc.lines[li], @intFromFloat(std.math.clamp(lx, -1e6, 1e6)));
    return charLen(item.attr.text[0 .. tc.starts[li] + at]);
}

fn lineShift(item: *const ItemT, tc: *const TextCache, li: usize) f64 {
    const lw = @as(f64, @floatFromInt(tc.runs[li].width)) / tc.scale;
    return switch (item.attr.justify) {
        .left => 0,
        .center => (tc.width - lw) / 2,
        .right => tc.width - lw,
    };
}

fn setText(w: *Widget, item: *ItemT, text: []const u8) !void {
    const gpa = w.app.gpa;
    const i = item.optIndex(.text).?;
    const copy = try gpa.dupe(u8, text);
    if (item.vals[i]) |old| gpa.free(old);
    item.vals[i] = copy;
    reparse(w, item);
    touch(w, item);
}

fn insertInto(w: *Widget, it: *ztcl.Interp, item: *ItemT, at: Value, sv: Value) ztcl.Error!void {
    const d = dataOf(w);
    if (item.type == .line or item.type == .polygon) {
        const i = try coordIndex(w, it, item, at);
        var cs: std.ArrayListUnmanaged(f64) = .empty;
        try readCoords(w, it, &.{sv}, &cs);
        if (cs.items.len % 2 == 1) return it.fail("odd number of coordinates specified", .{});
        try item.coords.insertSlice(w.app.gpa, i, cs.items);
        touch(w, item);
        return;
    }
    if (item.type != .text) return;
    const s = try it.str(sv);
    const i = try textIndex(w, it, item, at);
    const old = item.attr.text;
    const b = byteOf(old, i);
    const text = try std.mem.concat(it.alloc(), u8, &.{ old[0..b], s, old[b..] });
    const n = charLen(s);
    if (item.insert >= i) item.insert += n;
    if (d.sel_item == item) {
        if (d.sel_first >= i) d.sel_first += n;
        if (d.sel_last >= i) d.sel_last += n;
    }
    try setText(w, item, text);
}

fn deleteChars(w: *Widget, it: *ztcl.Interp, item: *ItemT, fv: Value, lv: Value) ztcl.Error!void {
    const d = dataOf(w);
    if (item.type == .line or item.type == .polygon) {
        const f = try coordIndex(w, it, item, fv);
        const l = @min(try coordIndex(w, it, item, lv) + 2, item.coords.items.len);
        if (l <= f) return;
        const c = &item.coords;
        std.mem.copyForwards(f64, c.items[f..], c.items[l..]);
        c.shrinkRetainingCapacity(c.items.len - (l - f));
        touch(w, item);
        return;
    }
    if (item.type != .text) return;
    const old = item.attr.text;
    const n = charLen(old);
    const f = try textIndex(w, it, item, fv);
    const l = @min(try textIndex(w, it, item, lv) + 1, n);
    if (l <= f) return;
    const bf = byteOf(old, f);
    const bl = byteOf(old, l);
    const text = try std.mem.concat(it.alloc(), u8, &.{ old[0..bf], old[bl..] });
    const cnt = l - f;
    const fix = struct {
        fn f2(x: usize, a: usize, b: usize, k: usize) usize {
            if (x >= b) return x - k;
            if (x > a) return a;
            return x;
        }
    }.f2;
    item.insert = fix(item.insert, f, l, cnt);
    if (d.sel_item == item) {
        d.sel_first = fix(d.sel_first, f, l, cnt);
        d.sel_last = fix(d.sel_last, f, l, cnt);
        if (d.sel_last <= d.sel_first) d.sel_item = null;
    }
    try setText(w, item, text);
}

fn selectCmd(w: *Widget, it: *ztcl.Interp, args: []const Value) ztcl.Error!Value {
    const d = dataOf(w);
    if (args.len < 1) return it.fail("wrong # args: should be \"{s} select option ?tagOrId? ?arg?\"", .{w.path});
    const op = try it.str(args[0]);
    const words = [_][]const u8{ "adjust", "clear", "from", "item", "to" };
    var k: ?usize = null;
    for (words, 0..) |x, i| if (op.len > 0 and std.mem.startsWith(u8, x, op)) {
        k = i;
    };
    const which = k orelse return it.fail("bad select option \"{s}\": must be adjust, clear, from, item, or to", .{op});
    switch (which) {
        1 => {
            if (args.len != 1) return it.fail("wrong # args: should be \"{s} select clear\"", .{w.path});
            d.sel_item = null;
        },
        3 => {
            if (args.len != 1) return it.fail("wrong # args: should be \"{s} select item\"", .{w.path});
            return if (d.sel_item) |s| .{ .int = s.id } else Value.empty;
        },
        else => {
            if (args.len != 3) return it.fail("wrong # args: should be \"{s} select {s} tagOrId index\"", .{ w.path, words[which] });
            var target: ?*ItemT = null;
            for (try matching(w, it, args[1])) |item| if (item.type == .text) {
                target = item;
                break;
            };
            const item = target orelse return Value.empty;
            const i = try textIndex(w, it, item, args[2]);
            switch (which) {
                2 => {
                    d.sel_anchor = i;
                    if (d.sel_item != item) d.sel_item = null;
                },
                0, 4 => {
                    if (which == 0 and d.sel_item == item) {
                        // `adjust`: the anchor goes to the far end from the index.
                        d.sel_anchor = if (i < (d.sel_first + d.sel_last) / 2) d.sel_last else d.sel_first;
                    }
                    d.sel_item = item;
                    d.sel_first = @min(d.sel_anchor, i);
                    d.sel_last = @max(d.sel_anchor, i);
                },
                else => unreachable,
            }
        },
    }
    changed(w);
    return Value.empty;
}

// ---- Scrolling ----

fn steps(w: *Widget, y: bool) scroll.Steps {
    const s = winSize(w);
    const i: f64 = @floatFromInt(inset(w));
    const vis = s[if (y) 1 else 0] - 2 * i;
    const inc: f64 = @floatFromInt(if (y) optInt(w, "-yscrollincrement") else optInt(w, "-xscrollincrement"));
    const unit = if (inc > 0) inc else @max(vis / 10, 1);
    return .{ .unit = unit, .page = @max(vis * 0.9, 1) };
}

/// Rounds an offset of a view so that the left edge of the window is on a multiple of the increment.
fn snap(w: *Widget, y: bool, pos: f64) f64 {
    const inc: f64 = @floatFromInt(if (y) optInt(w, "-yscrollincrement") else optInt(w, "-xscrollincrement"));
    if (inc <= 0) return pos;
    const d = dataOf(w);
    const r = d.region orelse return pos;
    const lo = r[if (y) 1 else 0];
    return inc * @round((lo + pos) / inc) - lo;
}

fn view(w: *Widget, it: *ztcl.Interp, argv: []const Value, y: bool) ztcl.Error!Value {
    const d = dataOf(w);
    const st = steps(w, y);
    if (d.region == null) {
        // No scroll region: the fractions are 0 and 1, and a scroll moves the origin with no limit.
        if (argv.len == 2) return scroll.fractionsValue(it.alloc(), .{ 0, 1 });
        var tmp: scroll.View = .{};
        const op = try it.str(argv[2]);
        const o = if (y) &d.free_y else &d.free_x;
        if (std.mem.eql(u8, op, "scroll") and argv.len == 5) {
            const t = try it.str(argv[3]);
            const n = std.fmt.parseFloat(f64, std.mem.trim(u8, t, " ")) catch return it.fail("expected integer but got \"{s}\"", .{t});
            const what = try it.str(argv[4]);
            const units = what.len > 0 and std.mem.startsWith(u8, "units", what);
            const pages = what.len > 0 and std.mem.startsWith(u8, "pages", what);
            if (!units and !pages) return it.fail("bad argument \"{s}\": must be units or pages", .{what});
            o.* += n * (if (units) st.unit else st.page);
        } else if (std.mem.eql(u8, op, "moveto") and argv.len == 4) {
            _ = try dbl(it, argv[3]);
            o.* = -@as(f64, @floatFromInt(inset(w))) * 0;
        } else {
            _ = try scroll.command(w, it, argv, &tmp, st, false);
        }
        changed(w);
        return Value.empty;
    }
    syncViews(w);
    const v = if (y) &d.vy else &d.vx;
    const r = try scroll.command(w, it, argv, v, st, false);
    if (argv.len > 2) {
        const p = v.clampPos(snap(w, y, v.pos));
        if (p != v.pos) {
            if (v.moving) v.pos = p else v.jump(p);
        }
        reportViews(w);
        changed(w);
    }
    return r orelse Value.empty;
}

fn reportViews(w: *Widget) void {
    const d = dataOf(w);
    if (d.region == null) {
        var full: scroll.View = .{};
        scroll.report(w, &full, "-xscrollcommand");
        var full2: scroll.View = .{};
        scroll.report(w, &full2, "-yscrollcommand");
        return;
    }
    scroll.report(w, &d.vx, "-xscrollcommand");
    scroll.report(w, &d.vy, "-yscrollcommand");
}

/// Moves the origin at once, for `scan dragto`.
fn setOrigin(w: *Widget, x: f64, y: f64, clamp: bool) void {
    _ = clamp;
    const d = dataOf(w);
    if (d.region) |r| {
        syncViews(w);
        const i: f64 = @floatFromInt(inset(w));
        d.vx.jump(snap(w, false, x - r[0] + i));
        d.vy.jump(snap(w, true, y - r[1] + i));
    } else {
        d.free_x = x;
        d.free_y = y;
    }
    reportViews(w);
    changed(w);
}

// ---- Events ----

fn itemTags(item: *const ItemT, current: bool, a: std.mem.Allocator) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    try out.append(a, "all");
    for (item.tags.items) |t| try out.append(a, try a.dupe(u8, t));
    if (current) try out.append(a, "current");
    try out.append(a, try std.fmt.allocPrint(a, "{d}", .{item.id}));
    return out.items;
}

fn runItem(w: *Widget, item: *ItemT, ev: *const bind.WidgetEvent) void {
    const d = dataOf(w);
    const a = w.app.it.alloc();
    const t = itemTags(item, d.current == item, a) catch return;
    bind.runTags(w.app, &d.bindings, t, ev);
}

/// The item under a point of the window that gets events.
fn pick(w: *Widget, x: i32, y: i32) ?*ItemT {
    const d = dataOf(w);
    const o = origin(w);
    const cx = o[0] + @as(f64, @floatFromInt(x));
    const cy = o[1] + @as(f64, @floatFromInt(y));
    const halo_v = options.get(w, "-closeenough").value;
    const halo: f64 = if (halo_v == .double) @max(halo_v.double, 0) else 1;
    var i = d.list.items.len;
    while (i > 0) {
        i -= 1;
        const item = d.list.items[i];
        const st = effState(w, item);
        if (st == .hidden or st == .disabled) continue;
        if (item.type == .window) continue;
        const b = itemBox(w, item) orelse continue;
        if (cx < @as(f64, @floatFromInt(b[0])) - halo or cx > @as(f64, @floatFromInt(b[2])) + halo or cy < @as(f64, @floatFromInt(b[1])) - halo or cy > @as(f64, @floatFromInt(b[3])) + halo) continue;
        if (itemDist(w, item, cx, cy) <= halo) return item;
    }
    return null;
}

/// Picks the current item again, and sends Leave and Enter for a change.
fn repick(w: *Widget, ev: *const bind.WidgetEvent) void {
    const d = dataOf(w);
    const new = if (d.pointer_in) pick(w, d.last_x, d.last_y) else null;
    if (new == d.current) return;
    if (d.current) |old| {
        var lv = ev.*;
        lv.type = .leave;
        runItem(w, old, &lv);
        if (!w.alive()) return;
        // The Leave binding can delete the item.
        if (d.current == old) d.current = null;
    }
    d.current = new;
    if (new) |n| {
        var en = ev.*;
        en.type = .enter;
        runItem(w, n, &en);
    }
    if (w.alive()) changed(w);
}

fn buttonsDown(m: anytype) bool {
    return m.button1 or m.button2 or m.button3 or m.button4 or m.button5;
}

/// The event hook of the class: it runs the item bindings before the bindings of the widget.
fn itemEvent(w: *Widget, ev: *const bind.WidgetEvent) void {
    if (!w.alive()) return;
    const d = dataOf(w);
    switch (ev.type) {
        .enter, .motion => {
            d.pointer_in = true;
            d.last_x = ev.x;
            d.last_y = ev.y;
            if (!buttonsDown(ev.mods)) repick(w, ev);
            if (ev.type == .motion) if (d.current) |c| runItem(w, c, ev);
        },
        .leave => {
            d.pointer_in = false;
            if (!buttonsDown(ev.mods)) repick(w, ev);
        },
        .button_press => {
            d.last_x = ev.x;
            d.last_y = ev.y;
            if (d.current) |c| runItem(w, c, ev);
        },
        .button_release, .mouse_wheel => {
            if (d.current) |c| runItem(w, c, ev);
            if (!w.alive()) return;
            if (ev.type == .button_release) {
                d.last_x = ev.x;
                d.last_y = ev.y;
                var m = ev.*;
                m.mods = .{};
                repick(w, &m);
            }
        },
        .key_press, .key_release => if (d.focus_item) |f| runItem(w, f, ev),
        .virtual => if (d.current) |c| runItem(w, c, ev),
        else => {},
    }
}

// ---- Window items: the canvas as a geometry manager ----

pub const manager: layout.Manager = .{
    .name = "canvas",
    .measure = managerMeasure,
    .arrange = arrange,
    .forget = forget,
    .release = release,
    .has_content = hasContent,
    .propagates = noPropagate,
};

fn managerMeasure(_: *Widget) void {}

fn noPropagate(_: *const Widget) bool {
    return false;
}

fn hasContent(c: *const Widget) bool {
    return dataOf(c).windows > 0;
}

fn setWindow(w: *Widget, item: *ItemT, name: []const u8) ztcl.Error!void {
    if (item.win) |old| unmanage(old);
    item.win = null;
    if (name.len == 0) return;
    const child = w.app.find(name).?;
    try layout.claim(w, &manager);
    w.container_manager = &manager;
    if (child.manager) |m| if (m != &manager) m.forget(child);
    // A window in another item leaves it.
    for (dataOf(w).list.items) |x| if (x.win == child) {
        x.win = null;
    };
    child.manager = &manager;
    child.manager_data = w;
    item.win = child;
    w.invalidate(.{ .style = false, .measure = false, .layout = true, .paint = true });
}

fn unmanage(c: *Widget) void {
    if (c.manager == &manager) {
        c.manager = null;
        c.manager_data = null;
        if (c.alive()) layout.setMapped(c, false);
    }
}

fn arrange(container: *Widget) void {
    const d = dataOf(container);
    const o = shownOrigin(container);
    const i = inset(container);
    for (d.list.items) |item| {
        const c = item.win orelse continue;
        if (!c.alive()) continue;
        const s = pixSize(container, item);
        const p = item.coords.items;
        if (p.len < 2) continue;
        const at = items.anchorPixel(item.attr.anchor, p[0] - o[0], p[1] - o[1], s[0], s[1]);
        var r: geom.Rect = .{ .x = num.pxRound(at[0]), .y = num.pxRound(at[1]), .w = num.pxRound(s[0]), .h = num.pxRound(s[1]) };
        const visible = effState(container, item) != .hidden and r.x + r.w > i and r.y + r.h > i and r.x < container.geom.w - i and r.y < container.geom.h - i;
        // A window that is a child of an ancestor of the canvas gets the
        // offset of the canvas in that ancestor.
        var up: ?*Widget = container;
        while (up) |x| : (up = x.parent) {
            if (x == c.parent) break;
            r.x +|= x.geom.x;
            r.y +|= x.geom.y;
        }
        _ = layout.setGeom(c, r, visible and container.mapped);
        item.box_ok = false;
    }
}

fn forget(c: *Widget) void {
    const w: *Widget = @ptrCast(@alignCast(c.manager_data orelse return));
    if (w.data == null) return;
    for (dataOf(w).list.items) |item| if (item.win == c) {
        item.win = null;
        const k = item.optIndex(.window).?;
        if (item.vals[k]) |s| w.app.gpa.free(s);
        item.vals[k] = null;
        reparse(w, item);
    };
    c.manager = null;
    c.manager_data = null;
}

fn release(container: *Widget) void {
    const d = dataOf(container);
    for (d.list.items) |item| if (item.win) |c| {
        unmanage(c);
        item.win = null;
    };
    container.container_manager = null;
}

// ---- Paint ----

/// Maps canvas points to device pixels for one paint.
const Xf = struct {
    ox: f64,
    oy: f64,
    s: f64,
    clip: [4]f32,

    fn x(t: Xf, v: f64) f32 {
        return @floatCast((v + t.ox) * t.s);
    }

    fn y(t: Xf, v: f64) f32 {
        return @floatCast((v + t.oy) * t.s);
    }
};

fn colorF(c: geom.Color) [4]f32 {
    return .{ @as(f32, @floatFromInt(c.r)) / 255, @as(f32, @floatFromInt(c.g)) / 255, @as(f32, @floatFromInt(c.b)) / 255, @as(f32, @floatFromInt(c.a)) / 255 };
}

fn quad(rect: [4]f32, clip: [4]f32, fill: [4]f32) scene.Quad {
    return .{
        .rect = rect,
        .clip = clip,
        .radii = .{ 0, 0, 0, 0 },
        .border = .{ 0, 0, 0, 0 },
        .fill = fill,
        .fill2 = fill,
        .border_color = .{ 0, 0, 0, 0 },
        .uv = .{ 0, 0, 0, 0 },
        .params = .{ 0, 0, 0, 1 },
        .kind = @intFromEnum(scene.Kind.box),
    };
}

fn visibleClip(r: [4]f32, clip: [4]f32) bool {
    return r[0] < clip[0] + clip[2] and r[1] < clip[1] + clip[3] and r[0] + r[2] > clip[0] and r[1] + r[3] > clip[1];
}

const Colors = struct { fill: ?geom.Color, outline: ?geom.Color, width: f64, dash: items.Dash };

fn colorsOf(w: *Widget, item: *const ItemT, fg: geom.Color) Colors {
    const a = &item.attr;
    const st = effState(w, item);
    const active = st == .normal and dataOf(w).current == item;
    var fill = a.fill;
    var outline = a.outline;
    if (item.fill_theme and fill != null) fill = fg;
    if (item.outline_theme and outline != null) outline = fg;
    var dash = a.dash;
    if (st == .disabled) {
        if (a.disabled_fill) |c| fill = c;
        if (a.disabled_outline) |c| outline = c;
        if (a.disabled_dash.n > 0) dash = a.disabled_dash;
    } else if (active) {
        if (a.active_fill) |c| fill = c;
        if (a.active_outline) |c| outline = c;
        if (a.active_dash.n > 0) dash = a.active_dash;
    }
    return .{ .fill = fill, .outline = outline, .width = shownWidth(w, item), .dash = dash };
}

/// Splits a polyline into the pieces of a dash pattern.
fn dashPieces(gpa: std.mem.Allocator, pts: []const path.Pt, d: items.Dash, scale: f32, width: f32, offset: f32, out: *std.ArrayListUnmanaged([]path.Pt)) !void {
    var mul = scale;
    if (d.chars) mul *= @max(width / scale, 1);
    var idx: usize = 0;
    var left = d.v[0] * mul;
    // The offset moves the start of the pattern.
    var off = offset * scale;
    while (off > 0) {
        if (off < left) {
            left -= off;
            break;
        }
        off -= left;
        idx = (idx + 1) % d.n;
        left = d.v[idx] * mul;
    }
    var cur: std.ArrayListUnmanaged(path.Pt) = .empty;
    defer cur.deinit(gpa);
    if (idx % 2 == 0 and pts.len > 0) try cur.append(gpa, pts[0]);
    var i: usize = 1;
    while (i < pts.len) : (i += 1) {
        var a = pts[i - 1];
        const b = pts[i];
        var seg = @sqrt((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y));
        while (seg > 0) {
            if (seg <= left) {
                left -= seg;
                if (idx % 2 == 0) try cur.append(gpa, b);
                seg = 0;
            } else {
                const t = left / seg;
                const p: path.Pt = .{ .x = a.x + (b.x - a.x) * t, .y = a.y + (b.y - a.y) * t };
                if (idx % 2 == 0) {
                    try cur.append(gpa, p);
                    try out.append(gpa, try gpa.dupe(path.Pt, cur.items));
                    cur.clearRetainingCapacity();
                } else {
                    cur.clearRetainingCapacity();
                    try cur.append(gpa, p);
                }
                seg -= left;
                a = p;
                idx = (idx + 1) % d.n;
                left = d.v[idx] * mul;
                if (out.items.len > 20000) return;
            }
        }
    }
    if (idx % 2 == 0 and cur.items.len > 1) try out.append(gpa, try gpa.dupe(path.Pt, cur.items));
}

/// Adds a stroke of a polyline to a shape: the segments, the joints, and the caps.
fn strokeInto(gpa: std.mem.Allocator, s: *path.Shape, pts: []const path.Pt, wd: f32, cap: items.Cap, join: items.Join, closed: bool) !void {
    if (pts.len == 0) return;
    var p = pts;
    var ext: std.ArrayListUnmanaged(path.Pt) = .empty;
    defer ext.deinit(gpa);
    const h = wd / 2;
    if (cap == .projecting and !closed and pts.len >= 2) {
        try ext.appendSlice(gpa, pts);
        const ends = [_][2]usize{ .{ 0, 1 }, .{ pts.len - 1, pts.len - 2 } };
        for (ends) |e| {
            const a = pts[e[0]];
            const b = pts[e[1]];
            const len = @sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));
            if (len > 0) ext.items[e[0]] = .{ .x = a.x + (a.x - b.x) / len * h, .y = a.y + (a.y - b.y) / len * h };
        }
        p = ext.items;
    }
    try s.stroke(gpa, p, wd, false);
    if (closed and p.len >= 2) try s.stroke(gpa, &.{ p[p.len - 1], p[0] }, wd, false);
    // The joints.
    const n = p.len;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const interior = closed or (i > 0 and i + 1 < n);
        if (interior) {
            if (join == .round) {
                try s.ellipse(gpa, p[i].x, p[i].y, h, h);
            } else {
                const a = p[(i + n - 1) % n];
                const b = p[(i + 1) % n];
                const n1 = normal(a, p[i], h);
                const n2 = normal(p[i], b, h);
                try s.contour(gpa, &.{ p[i], .{ .x = p[i].x + n1.x, .y = p[i].y + n1.y }, .{ .x = p[i].x + n2.x, .y = p[i].y + n2.y } });
                try s.contour(gpa, &.{ p[i], .{ .x = p[i].x - n2.x, .y = p[i].y - n2.y }, .{ .x = p[i].x - n1.x, .y = p[i].y - n1.y } });
            }
        } else if (cap == .round) try s.ellipse(gpa, p[i].x, p[i].y, h, h);
    }
}

fn normal(a: path.Pt, b: path.Pt, h: f32) path.Pt {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const len = @sqrt(dx * dx + dy * dy);
    if (len == 0) return .{ .x = 0, .y = 0 };
    return .{ .x = -dy / len * h, .y = dx / len * h };
}

const Painter = struct {
    w: *Widget,
    b: *scene.Builder,
    xf: Xf,
    fg: geom.Color,
    gpa: std.mem.Allocator,

    fn add(p: *Painter, q: scene.Quad) !void {
        if (!visibleClip(q.rect, p.xf.clip)) return;
        try p.b.scene.quads.append(p.gpa, q);
    }

    fn fillShape(p: *Painter, s: *const path.Shape, c: geom.Color) !void {
        try path.fill(p.gpa, &p.b.scene.quads, s, p.xf.clip, colorF(c), 1);
    }

    fn stroke(p: *Painter, pts: []const path.Pt, col: Colors, cap: items.Cap, join: items.Join, closed: bool) !void {
        const c = col.outline orelse return;
        if (pts.len < 2) return;
        const wd: f32 = @floatCast(@max(col.width, 1) * p.xf.s);
        var s: path.Shape = .{};
        defer s.deinit(p.gpa);
        if (col.dash.n >= 2) {
            var pieces: std.ArrayListUnmanaged([]path.Pt) = .empty;
            defer {
                for (pieces.items) |x| p.gpa.free(x);
                pieces.deinit(p.gpa);
            }
            var all: std.ArrayListUnmanaged(path.Pt) = .empty;
            defer all.deinit(p.gpa);
            try all.appendSlice(p.gpa, pts);
            if (closed) try all.append(p.gpa, pts[0]);
            try dashPieces(p.gpa, all.items, col.dash, @floatCast(p.xf.s), wd, 0, &pieces);
            for (pieces.items) |x| try strokeInto(p.gpa, &s, x, wd, cap, join, false);
        } else try strokeInto(p.gpa, &s, pts, wd, cap, join, closed);
        try p.fillShape(&s, c);
    }

    /// The device points of the coordinates. A stroke of an odd width moves by half a pixel, so it covers whole pixels as in Tk.
    fn points(p: *Painter, c: []const f64, half: bool, out: *std.ArrayListUnmanaged(path.Pt)) !void {
        const off: f64 = if (half) 0.5 else 0;
        var i: usize = 0;
        while (i + 1 < c.len) : (i += 2) try out.append(p.gpa, .{ .x = p.xf.x(c[i] + off), .y = p.xf.y(c[i + 1] + off) });
    }

    fn item(p: *Painter, it: *ItemT) !void {
        const w = p.w;
        const c = it.coords.items;
        const col = colorsOf(w, it, p.fg);
        const s = p.xf.s;
        const odd = @mod(@round(@max(col.width, 1)), 2) == 1;
        switch (it.type) {
            .rectangle, .oval => {
                if (c.len < 4) return;
                const k = items.corners(c);
                const has_out = col.outline != null and col.width > 0;
                const circle = it.type == .oval and @abs((k[2] - k[0]) - (k[3] - k[1])) < 0.5;
                if (it.type == .rectangle or circle) {
                    if (col.dash.n >= 2 and has_out) {
                        // A dashed outline: the fill box and the dashes of a stroke.
                        if (col.fill) |f| try p.add(quad(.{ p.xf.x(k[0]), p.xf.y(k[1]), @floatCast((k[2] - k[0]) * s), @floatCast((k[3] - k[1]) * s) }, p.xf.clip, colorF(f)));
                        var pts: std.ArrayListUnmanaged(path.Pt) = .empty;
                        defer pts.deinit(p.gpa);
                        if (circle) {
                            var tmp: std.ArrayListUnmanaged(path.Pt) = .empty;
                            defer tmp.deinit(p.gpa);
                            try items.arcPoints(p.gpa, &tmp, k, 0, 360, s, s, p.xf.ox * s, p.xf.oy * s);
                            try pts.appendSlice(p.gpa, tmp.items);
                        } else try p.points(&.{ k[0], k[1], k[2], k[1], k[2], k[3], k[0], k[3] }, odd, &pts);
                        try p.stroke(pts.items, col, .butt, .miter, true);
                        return;
                    }
                    const lo: f64 = if (has_out) @floor(col.width / 2) else 0;
                    const hi: f64 = if (has_out) @ceil(col.width / 2) else 0;
                    const x0 = p.xf.x(k[0] - lo);
                    const y0 = p.xf.y(k[1] - lo);
                    const r: [4]f32 = .{ x0, y0, p.xf.x(k[2] + hi) - x0, p.xf.y(k[3] + hi) - y0 };
                    if (r[2] <= 0 or r[3] <= 0) return;
                    var q = quad(r, p.xf.clip, if (col.fill) |f| colorF(f) else .{ 0, 0, 0, 0 });
                    if (has_out) {
                        const bw: f32 = @max(1, @round(@as(f32, @floatCast(col.width * s))));
                        q.border = .{ bw, bw, bw, bw };
                        q.border_color = colorF(col.outline.?);
                    }
                    if (circle) {
                        const rad = @min(r[2], r[3]) / 2;
                        q.radii = .{ rad, rad, rad, rad };
                    }
                    if (col.fill == null and !has_out) return;
                    try p.add(q);
                    return;
                }
                // An ellipse.
                var sh: path.Shape = .{};
                defer sh.deinit(p.gpa);
                const cx = p.xf.x((k[0] + k[2]) / 2);
                const cy = p.xf.y((k[1] + k[3]) / 2);
                const rx: f32 = @floatCast((k[2] - k[0]) / 2 * s);
                const ry: f32 = @floatCast((k[3] - k[1]) / 2 * s);
                if (col.fill) |f| {
                    try sh.ellipse(p.gpa, cx, cy, rx, ry);
                    try p.fillShape(&sh, f);
                }
                if (has_out) {
                    var pts: std.ArrayListUnmanaged(path.Pt) = .empty;
                    defer pts.deinit(p.gpa);
                    try items.arcPoints(p.gpa, &pts, k, 0, 360, s, s, p.xf.ox * s, p.xf.oy * s);
                    _ = pts.pop();
                    try p.stroke(pts.items, col, .butt, .round, true);
                }
            },
            .arc => {
                if (c.len < 4) return;
                const k = items.corners(c);
                var pts: std.ArrayListUnmanaged(path.Pt) = .empty;
                defer pts.deinit(p.gpa);
                try items.arcPoints(p.gpa, &pts, k, it.attr.start, it.attr.extent, s, s, p.xf.ox * s, p.xf.oy * s);
                if (it.attr.arc_style == .pieslice) try pts.append(p.gpa, .{ .x = p.xf.x((k[0] + k[2]) / 2), .y = p.xf.y((k[1] + k[3]) / 2) });
                if (it.attr.arc_style != .arc) if (col.fill) |f| {
                    var sh: path.Shape = .{};
                    defer sh.deinit(p.gpa);
                    try sh.contour(p.gpa, pts.items);
                    try p.fillShape(&sh, f);
                };
                try p.stroke(pts.items, col, .butt, .miter, it.attr.arc_style != .arc);
            },
            .line, .polygon => {
                if (c.len < 4) return;
                var cs = c;
                var tmp: std.ArrayListUnmanaged(f64) = .empty;
                defer tmp.deinit(p.gpa);
                var pts: std.ArrayListUnmanaged(path.Pt) = .empty;
                defer pts.deinit(p.gpa);
                const lcol: Colors = if (it.type == .line) .{ .fill = null, .outline = col.fill, .width = col.width, .dash = col.dash } else col;
                // The arrowheads shorten the line.
                var heads: [2]?items.ArrowPoly = .{ null, null };
                if (it.type == .line and it.attr.arrow != .none) {
                    try tmp.appendSlice(p.gpa, c);
                    const n = c.len;
                    const sh = it.attr.arrow_shape;
                    if (it.attr.arrow == .first or it.attr.arrow == .both) {
                        heads[0] = items.arrowPoly(c[0], c[1], c[2], c[3], sh, col.width);
                        tmp.items[0] = heads[0].?.neck.x;
                        tmp.items[1] = heads[0].?.neck.y;
                    }
                    if (it.attr.arrow == .last or it.attr.arrow == .both) {
                        heads[1] = items.arrowPoly(c[n - 2], c[n - 1], c[n - 4], c[n - 3], sh, col.width);
                        tmp.items[n - 2] = heads[1].?.neck.x;
                        tmp.items[n - 1] = heads[1].?.neck.y;
                    }
                    cs = tmp.items;
                }
                if (it.attr.smooth != .none and cs.len >= 6) {
                    var sm: std.ArrayListUnmanaged([2]f64) = .empty;
                    defer sm.deinit(p.gpa);
                    try items.smoothPoints(p.gpa, &sm, cs, it.attr.spline_steps, it.attr.smooth == .raw, it.type == .polygon);
                    const half: f64 = if (it.type == .line and odd) 0.5 else 0;
                    for (sm.items) |q| try pts.append(p.gpa, .{ .x = p.xf.x(q[0] + half), .y = p.xf.y(q[1] + half) });
                } else try p.points(cs, it.type == .line and odd, &pts);
                if (it.type == .polygon) {
                    if (col.fill) |f| {
                        var sh: path.Shape = .{};
                        defer sh.deinit(p.gpa);
                        try sh.contour(p.gpa, pts.items);
                        try p.fillShape(&sh, f);
                    }
                    if (col.outline != null and col.width > 0) {
                        var opts: std.ArrayListUnmanaged(path.Pt) = .empty;
                        defer opts.deinit(p.gpa);
                        if (it.attr.smooth != .none) try opts.appendSlice(p.gpa, pts.items) else try p.points(cs, odd, &opts);
                        try p.stroke(opts.items, col, .butt, it.attr.join, true);
                    }
                    return;
                }
                try p.stroke(pts.items, lcol, it.attr.cap, it.attr.join, false);
                if (lcol.outline) |f| for (heads) |hd| if (hd) |h| {
                    var sh: path.Shape = .{};
                    defer sh.deinit(p.gpa);
                    var hp: [5]path.Pt = undefined;
                    for (0..5) |i| hp[i] = .{ .x = p.xf.x(h.poly[i].x), .y = p.xf.y(h.poly[i].y) };
                    try sh.contour(p.gpa, &hp);
                    try p.fillShape(&sh, f);
                };
            },
            .text => try p.text(it, col),
            .image => {
                const name = imageName(w, it);
                const ph = w.app.images.find(name) orelse return;
                if (c.len < 2) return;
                const o = items.anchorPixel(it.attr.anchor, c[0], c[1], @floatFromInt(ph.width), @floatFromInt(ph.height));
                const key = std.hash.Wyhash.hash(ph.version, ph.name) ^ (@as(u64, @intFromPtr(ph)) << 1);
                const qs = try p.pixQuads(key, ph.width, ph.height, PixSrc{ .photo = ph });
                try p.blit(qs, o);
            },
            .bitmap => {
                const name = bitmapName(w, it);
                const bm = bitmaps.find(name) orelse return;
                if (c.len < 2) return;
                const a = &it.attr;
                const st = effState(w, it);
                const active = st == .normal and dataOf(w).current == it;
                var fgc = if (it.fill_theme) p.fg else a.foreground orelse p.fg;
                var bgc = a.background;
                if (st == .disabled) {
                    if (a.disabled_foreground) |x| fgc = x;
                    if (a.disabled_background) |x| bgc = x;
                } else if (active) {
                    if (a.active_foreground) |x| fgc = x;
                    if (a.active_background) |x| bgc = x;
                }
                const o = items.anchorPixel(a.anchor, c[0], c[1], @floatFromInt(bm.w), @floatFromInt(bm.h));
                const bgk: geom.Color = bgc orelse .{ .r = 0, .g = 0, .b = 0, .a = 0 };
                const seed = @as(u64, fgc.r) | @as(u64, fgc.g) << 8 | @as(u64, fgc.b) << 16 | @as(u64, fgc.a) << 24 | @as(u64, bgk.r) << 32 | @as(u64, bgk.g) << 40 | @as(u64, bgk.b) << 48 | @as(u64, bgk.a) << 56;
                const key = std.hash.Wyhash.hash(seed, bm.name);
                const qs = try p.pixQuads(key, bm.w, bm.h, PixSrc{ .bits = .{ .bm = bm, .fg = fgc, .bg = bgc } });
                try p.blit(qs, o);
            },
            .window => {},
        }
    }

    const PixSrc = union(enum) {
        photo: *const image_mod.Photo,
        bits: struct { bm: *const bitmaps.Bitmap, fg: geom.Color, bg: ?geom.Color },

        fn at(src: PixSrc, x: u32, y: u32) [4]u8 {
            switch (src) {
                .photo => |ph| {
                    const o = (@as(usize, y) * ph.width + x) * 4;
                    return ph.pixels[o..][0..4].*;
                },
                .bits => |b| {
                    const stride = (b.bm.w + 7) / 8;
                    const bits = b.bm.bits[y * stride + x / 8];
                    const on = (bits >> @intCast(x % 8)) & 1 == 1;
                    if (on) return .{ b.fg.r, b.fg.g, b.fg.b, b.fg.a };
                    const bg = b.bg orelse return .{ 0, 0, 0, 0 };
                    return .{ bg.r, bg.g, bg.b, bg.a };
                },
            }
        }
    };

    /// The quads of an image at the origin, from the cache: one for each run of equal pixels in a row.
    fn pixQuads(p: *Painter, key: u64, wd: u32, ht: u32, src: PixSrc) ![]const scene.Quad {
        const d = dataOf(p.w);
        const s: f32 = @floatCast(p.xf.s);
        for (d.pix_cache.items) |pc| if (pc.key == key and pc.scale == s) return pc.quads;
        if (d.pix_cache.items.len > 64) freePix(p.gpa, d);
        var out: std.ArrayListUnmanaged(scene.Quad) = .empty;
        errdefer out.deinit(p.gpa);
        var y: u32 = 0;
        while (y < ht) : (y += 1) {
            var x: u32 = 0;
            while (x < wd) {
                const px = src.at(x, y);
                var e = x + 1;
                while (e < wd and std.mem.eql(u8, &src.at(e, y), &px)) e += 1;
                if (px[3] > 0) {
                    const f: [4]f32 = .{ @as(f32, @floatFromInt(px[0])) / 255, @as(f32, @floatFromInt(px[1])) / 255, @as(f32, @floatFromInt(px[2])) / 255, @as(f32, @floatFromInt(px[3])) / 255 };
                    try out.append(p.gpa, quad(.{ @as(f32, @floatFromInt(x)) * s, @as(f32, @floatFromInt(y)) * s, @as(f32, @floatFromInt(e - x)) * s, s }, .{ 0, 0, 0, 0 }, f));
                }
                x = e;
            }
        }
        const qs = try out.toOwnedSlice(p.gpa);
        try d.pix_cache.append(p.gpa, .{ .key = key, .scale = s, .quads = qs });
        return qs;
    }

    fn blit(p: *Painter, qs: []const scene.Quad, o: [2]f64) !void {
        const dx = @round(p.xf.x(o[0]));
        const dy = @round(p.xf.y(o[1]));
        for (qs) |q0| {
            var q = q0;
            q.rect[0] += dx;
            q.rect[1] += dy;
            q.clip = p.xf.clip;
            try p.add(q);
        }
    }

    fn text(p: *Painter, it: *ItemT, col: Colors) !void {
        const w = p.w;
        const app = w.app;
        const c = it.coords.items;
        if (c.len < 2) return;
        const scale: f32 = @floatCast(p.xf.s);
        const tc = try textLayout(w, it, scale);
        _ = itemBox(w, it);
        const e = it.extent;
        const color = col.fill orelse return;
        const d = dataOf(w);
        const lh: f64 = @floatFromInt(tc.line_h);
        for (tc.runs, 0..) |*run, li| {
            const lx = e[0] + lineShift(it, tc, li);
            const top = e[1] + lh * @as(f64, @floatFromInt(li));
            const base = top + @as(f64, @floatFromInt(tc.ascent));
            // The builder adds its offset, so the position is in logical pixels of the widget.
            const bx = num.pxRound(lx + p.xf.ox - @as(f64, @floatFromInt(p.b.off.x)));
            const by = num.pxRound(base + p.xf.oy - @as(f64, @floatFromInt(p.b.off.y)));
            const line = tc.lines[li];
            const start = tc.starts[li];
            // The selection, behind the text.
            if (d.sel_item == it) {
                const a0 = byteOf(it.attr.text, d.sel_first);
                const a1 = byteOf(it.attr.text, d.sel_last);
                const s0 = std.math.clamp(@as(isize, @intCast(a0)) - @as(isize, @intCast(start)), 0, @as(isize, @intCast(line.len)));
                const s1 = std.math.clamp(@as(isize, @intCast(a1)) - @as(isize, @intCast(start)), 0, @as(isize, @intCast(line.len)));
                if (s1 > s0) {
                    const x0 = @as(f64, @floatFromInt(run.caretX(line, @intCast(s0)))) / scale;
                    const x1 = @as(f64, @floatFromInt(run.caretX(line, @intCast(s1)))) / scale;
                    const sb = options.get(w, "-selectbackground");
                    const sel_bg = if (sb.set and sb.value == .color) sb.value.color else app.styles.compute(w, "selection", &w.style, app.env).background;
                    try p.add(quad(.{ p.xf.x(lx + x0), p.xf.y(top), @floatCast((x1 - x0) * p.xf.s), @floatCast(lh * p.xf.s) }, p.xf.clip, colorF(sel_bg)));
                }
            }
            p.b.pushClip(.{ .x = -100000, .y = -100000, .w = 200000, .h = 200000 });
            p.b.clip = p.xf.clip;
            try p.b.text(&app.atlas, run, bx, by, color);
            p.b.popClip();
            if (it.attr.underline >= 0) {
                const ub = byteOf(it.attr.text, @intCast(it.attr.underline));
                if (ub >= start and ub < start + line.len) {
                    const x0 = @as(f64, @floatFromInt(run.caretX(line, ub - start))) / scale;
                    const nb = byteOf(it.attr.text, @as(usize, @intCast(it.attr.underline)) + 1);
                    const x1 = @as(f64, @floatFromInt(run.caretX(line, @min(nb - start, line.len)))) / scale;
                    try p.add(quad(.{ p.xf.x(lx + x0), p.xf.y(base + 1), @floatCast(@max(x1 - x0, 1) * p.xf.s), @floatCast(@max(p.xf.s, 1)) }, p.xf.clip, colorF(color)));
                }
            }
            // The insert cursor of the focus item, while the canvas has the focus.
            if (d.focus_item == it and w.state.focus) {
                const ib = byteOf(it.attr.text, it.insert);
                if (ib >= start and ib <= start + line.len) {
                    const x0 = @as(f64, @floatFromInt(run.caretX(line, ib - start))) / scale;
                    const iw: f64 = @floatFromInt(@max(optInt(w, "-insertwidth"), 1));
                    const ib_c = options.get(w, "-insertbackground");
                    const icol = if (ib_c.set and ib_c.value == .color) ib_c.value.color else p.fg;
                    try p.add(quad(.{ p.xf.x(lx + x0 - iw / 2), p.xf.y(top), @floatCast(iw * p.xf.s), @floatCast(lh * p.xf.s) }, p.xf.clip, colorF(icol)));
                }
            }
        }
    }
};

fn paintCanvas(w: *Widget, b: *scene.Builder) anyerror!void {
    const app = w.app;
    const st = anim.shown(app, w);
    try paint.box(w, b, st);
    const d = dataOf(w);
    syncViews(w);
    reportViews(w);
    const i = inset(w);
    const content: geom.Rect = .{ .x = i, .y = i, .w = w.geom.w - 2 * i, .h = w.geom.h - 2 * i };
    if (content.w <= 0 or content.h <= 0) return;
    const o = shownOrigin(w);
    const first_quad = b.scene.quads.items.len;
    b.pushClip(content);
    defer b.popClip();
    const s: f64 = b.scale;
    // The origin rounds to a whole device pixel, so a scroll does not blur the items.
    const ox = @round((-o[0] + @as(f64, @floatFromInt(b.off.x))) * s) / s;
    const oy = @round((-o[1] + @as(f64, @floatFromInt(b.off.y))) * s) / s;
    var pt: Painter = .{ .w = w, .b = b, .xf = .{ .ox = ox, .oy = oy, .s = s, .clip = b.clip }, .fg = st.color, .gpa = app.gpa };
    // The visible part of the canvas, in canvas points.
    const vx0 = o[0] + @as(f64, @floatFromInt(i));
    const vy0 = o[1] + @as(f64, @floatFromInt(i));
    const vx1 = vx0 + @as(f64, @floatFromInt(content.w));
    const vy1 = vy0 + @as(f64, @floatFromInt(content.h));
    const fr = app.anim_frame;
    const now = if (fr) |f| f.time_us else 0;
    const can_anim = fr != null and app.paint_override == null and !app.part_end and app.part_move != .blocked and !anim.reduced(app);
    for (d.list.items) |item| {
        if (effState(w, item) == .hidden) continue;
        const bx = itemBox(w, item) orelse continue;
        if (@as(f64, @floatFromInt(bx[2])) < vx0 or @as(f64, @floatFromInt(bx[0])) > vx1 or @as(f64, @floatFromInt(bx[3])) < vy0 or @as(f64, @floatFromInt(bx[1])) > vy1) continue;
        if (can_anim) if (findItemAnim(app, w, item.id)) |ia| {
            if (try paintAnimated(&pt, item, ia, now)) continue;
        };
        try pt.item(item);
    }
    if (d.windows > 0 and (d.vx.moving or d.vy.moving)) w.dirty.layout = true;
    // The items in the window differ at the start and at the end of a smooth
    // scroll, so the canvas paints once and the UI thread moves the view.
    if (app.part_move != .blocked) app.part_move = .mixed;
    try scroll.paintDrag(w, b, &d.vx, first_quad, 0);
    try scroll.paintDrag(w, b, &d.vy, first_quad, 1);
}

// ---- Item animations ----

const Track = struct {
    /// The option index, or null for the coordinates.
    opt: ?usize,
    color: bool,
    from: []f64,
    to: []f64,
};

pub const ItemAnim = struct {
    id: u32,
    canvas: *Widget,
    item: u32,
    tracks: []Track,
    start_us: i64,
    duration_ms: u32,
    delay_ms: u32,
    timing: easing.Timing,
    repeat: u32,
    paused_at: ?i64 = null,
    command: []u8 = &.{},

    pub fn deinit(a: *ItemAnim, gpa: std.mem.Allocator) void {
        for (a.tracks) |t| {
            gpa.free(t.from);
            gpa.free(t.to);
        }
        gpa.free(a.tracks);
        gpa.free(a.command);
    }

    pub fn lenUs(a: *const ItemAnim) i64 {
        const d: i64 = switch (a.timing) {
            .spring => |p| @intFromFloat(easing.springDuration(p) * 1_000_000),
            else => @as(i64, a.duration_ms) * 1000,
        };
        return @max(d, 1);
    }

    /// The eased progress at a time, and whether the animation ended.
    pub fn progress(a: *const ItemAnim, app: *App, now_us: i64) struct { p: f32, done: bool, started: bool } {
        if (anim.reduced(app)) return .{ .p = 1, .done = true, .started = true };
        const since = now_us - a.start_us - @as(i64, a.delay_ms) * 1000;
        if (since < 0) return .{ .p = 0, .done = false, .started = false };
        const len = a.lenUs();
        const runs = @divFloor(since, len);
        if (a.repeat != 0 and runs >= a.repeat) return .{ .p = 1, .done = true, .started = true };
        return .{ .p = a.timing.eval(@as(f32, @floatFromInt(since - runs * len)) / @as(f32, @floatFromInt(len))), .done = false, .started = true };
    }
};

fn findItemAnim(app: *App, w: *Widget, id: u32) ?*ItemAnim {
    for (app.opt_anims.items.items) |*a| if (a.canvas == w and a.item == id and a.paused_at == null) return a;
    return null;
}

fn dropAnims(app: *App, w: *Widget) void {
    var i: usize = 0;
    const l = &app.opt_anims.items;
    while (i < l.items.len) {
        if (l.items[i].canvas == w) {
            l.items[i].deinit(app.gpa);
            _ = l.orderedRemove(i);
        } else i += 1;
    }
}

fn colorVals(c: geom.Color) [4]f64 {
    return .{ @floatFromInt(c.r), @floatFromInt(c.g), @floatFromInt(c.b), @floatFromInt(c.a) };
}

fn byte(v: f64) u8 {
    return @intFromFloat(std.math.clamp(@round(v), 0, 255));
}

/// Writes the values of the tracks at a progress into the item. Returns
/// true when a value changed, so the same time gives no new frame.
fn applyTracks(w: *Widget, item: *ItemT, tracks: []const Track, p: f32) bool {
    const gpa = w.app.gpa;
    var moved = false;
    for (tracks) |tr| {
        if (tr.opt == null) {
            if (item.coords.items.len != tr.to.len) continue;
            for (item.coords.items, tr.from, tr.to) |*c, f, t| {
                const v = f + (t - f) * p;
                if (c.* != v) moved = true;
                c.* = v;
            }
            continue;
        }
        const k = tr.opt.?;
        var buf: [64]u8 = undefined;
        const text = if (tr.color) blk: {
            var v: [4]f64 = undefined;
            for (&v, tr.from, tr.to) |*x, f, t| x.* = f + (t - f) * p;
            const col: geom.Color = .{ .r = byte(v[0]), .g = byte(v[1]), .b = byte(v[2]), .a = byte(v[3]) };
            var cb: [7]u8 = undefined;
            break :blk std.fmt.bufPrint(&buf, "{s}", .{col.formatTk(&cb)}) catch continue;
        } else std.fmt.bufPrint(&buf, "{d}", .{tr.from[0] + (tr.to[0] - tr.from[0]) * p}) catch continue;
        if (item.vals[k]) |s| if (std.mem.eql(u8, s, text)) continue;
        const copy = gpa.dupe(u8, text) catch continue;
        if (item.vals[k]) |s| gpa.free(s);
        item.vals[k] = copy;
        moved = true;
    }
    if (moved) reparse(w, item);
    return moved;
}

/// Moves each item animation to a time. Returns true when one still runs.
pub fn tickAnims(app: *App, now_us: i64) bool {
    var running = false;
    var i: usize = 0;
    const l = &app.opt_anims.items;
    while (i < l.items.len) {
        const a = &l.items[i];
        const w = a.canvas;
        const item = if (w.alive()) dataOf(w).ids.get(a.item) else null;
        if (item == null) {
            a.deinit(app.gpa);
            _ = l.orderedRemove(i);
            continue;
        }
        if (a.paused_at != null) {
            i += 1;
            continue;
        }
        const pr = a.progress(app, now_us);
        if (pr.started or pr.done) {
            if (applyTracks(w, item.?, a.tracks, pr.p)) touch(w, item.?);
        }
        if (pr.done) {
            if (a.command.len > 0) _ = app.loop.addIdle(a.command) catch {};
            a.deinit(app.gpa);
            _ = l.orderedRemove(i);
            continue;
        }
        running = true;
        i += 1;
    }
    return running;
}

/// Paints an item now and at the end of its animation, and gives the
/// render thread both sets. Returns false, with no quad added, when the
/// two paints differ in their count of quads.
fn paintAnimated(p: *Painter, item: *ItemT, a: *ItemAnim, now_us: i64) !bool {
    const app = p.w.app;
    const fr = app.anim_frame orelse return false;
    const pr = a.progress(app, now_us);
    if (pr.done or !pr.started or @abs(1 - pr.p) < 1e-3) return false;
    const quads = &p.b.scene.quads;
    const at = quads.items.len;
    try p.item(item);
    const n = quads.items.len - at;
    if (n == 0) return true;
    // The paint at the end: the item with the end values, then its own values again.
    const gpa = app.gpa;
    const saved_coords = try gpa.dupe(f64, item.coords.items);
    defer gpa.free(saved_coords);
    const saved_vals = try gpa.alloc(?[]u8, item.vals.len);
    defer gpa.free(saved_vals);
    for (item.vals, saved_vals) |v, *s| s.* = if (v) |x| try gpa.dupe(u8, x) else null;
    defer for (saved_vals) |v| if (v) |x| gpa.free(x);
    _ = applyTracks(p.w, item, a.tracks, 1);
    item.box_ok = false;
    try p.item(item);
    // Put the values of now back.
    @memcpy(item.coords.items, saved_coords);
    for (item.vals, saved_vals) |*v, s| {
        if (v.*) |x| gpa.free(x);
        v.* = if (s) |x| try gpa.dupe(u8, x) else null;
    }
    reparse(p.w, item);
    const m = quads.items.len - at - n;
    if (m != n) {
        quads.shrinkRetainingCapacity(at + n);
        return true;
    }
    const mark = fr.anim_quads.items.len;
    try fr.anim_quads.appendSlice(gpa, quads.items[at .. at + 2 * n]);
    quads.shrinkRetainingCapacity(at + n);
    const off_at = fr.anim_offsets.items.len;
    try fr.anim_offsets.appendSlice(gpa, &.{ pr.p, 1 });
    try fr.anims.append(gpa, .{
        .first = @intCast(at), .count = @intCast(n), .from = @intCast(mark), .stops = 2, .offsets = @intCast(off_at),
        .start_us = a.start_us, .delay_us = @as(i64, a.delay_ms) * 1000, .len_us = a.lenUs(), .timing = a.timing,
        .iterations = @floatFromInt(a.repeat),
    });
    return true;
}

/// `ztk::animate {.c tagOrId} ?-option value ...?`: one animation for
/// each item that matches. `-coords` needs a list of the same length as
/// the coordinates of the item. Returns the id of the last animation.
pub fn animateItems(w: *Widget, it: *ztcl.Interp, target: Value, args: []const Value, timing: easing.Timing, duration_ms: u32, delay_ms: u32, repeat: u32, command: []const u8) ztcl.Error!Value {
    const app = w.app;
    const gpa = app.gpa;
    const list = try matching(w, it, target);
    if (list.len == 0) return it.fail("no item matches \"{s}\"", .{try it.str(target)});
    var last: u32 = 0;
    const now = app.platform.nowUs();
    for (list) |item| {
        var tracks: std.ArrayListUnmanaged(Track) = .empty;
        errdefer {
            for (tracks.items) |t| {
                gpa.free(t.from);
                gpa.free(t.to);
            }
            tracks.deinit(gpa);
        }
        var k: usize = 0;
        while (k + 1 < args.len) : (k += 2) {
            const name = try it.str(args[k]);
            if (std.mem.eql(u8, name, "-coords")) {
                var cs: std.ArrayListUnmanaged(f64) = .empty;
                try readCoords(w, it, &.{args[k + 1]}, &cs);
                if (cs.items.len != item.coords.items.len) return it.fail("-coords needs {d} numbers for item {d}", .{ item.coords.items.len, item.id });
                try tracks.append(gpa, .{ .opt = null, .color = false, .from = try gpa.dupe(f64, item.coords.items), .to = try gpa.dupe(f64, cs.items) });
                continue;
            }
            const opts = items.optsOf(item.type);
            const i = try findOpt(it, opts, name);
            const text = try it.str(args[k + 1]);
            const f = opts[i].field;
            const is_color = switch (f) {
                .fill, .active_fill, .disabled_fill, .outline, .active_outline, .disabled_outline, .foreground, .background => true,
                else => false,
            };
            if (is_color) {
                const to = geom.Color.parseTk(text) orelse return it.fail("can't animate {s} to \"{s}\"", .{ opts[i].name, text });
                var cur = geom.Color.parseTk(try itemOptText(item, it, i)) orelse to;
                if (item.vals[i] == null and std.mem.eql(u8, opts[i].default, "#000000")) {
                    app.ensureStyle(w);
                    cur = w.style.color;
                }
                if ((try itemOptText(item, it, i)).len == 0) cur = .{ .r = to.r, .g = to.g, .b = to.b, .a = 0 };
                try tracks.append(gpa, .{ .opt = i, .color = true, .from = try gpa.dupe(f64, &colorVals(cur)), .to = try gpa.dupe(f64, &colorVals(to)) });
            } else {
                const to = items.parseDist(text, app.scaling) orelse return it.fail("can't animate {s} to \"{s}\"", .{ opts[i].name, text });
                const cur = items.parseDist(try itemOptText(item, it, i), app.scaling) orelse 0;
                try tracks.append(gpa, .{ .opt = i, .color = false, .from = try gpa.dupe(f64, &.{cur}), .to = try gpa.dupe(f64, &.{to}) });
            }
        }
        if (tracks.items.len == 0) return it.fail("no option to animate", .{});
        // A new animation of an option of the item removes it from the old one.
        var i: usize = 0;
        const l = &app.opt_anims.items;
        while (i < l.items.len) {
            const o = &l.items[i];
            if (o.canvas == w and o.item == item.id) {
                var keep: usize = 0;
                for (o.tracks) |tr| {
                    var hit = false;
                    for (tracks.items) |t| if (std.meta.eql(t.opt, tr.opt)) {
                        hit = true;
                    };
                    if (hit) {
                        gpa.free(tr.from);
                        gpa.free(tr.to);
                    } else {
                        o.tracks[keep] = tr;
                        keep += 1;
                    }
                }
                o.tracks = gpa.realloc(o.tracks, keep) catch o.tracks[0..keep];
                if (keep == 0) {
                    o.deinit(gpa);
                    _ = l.orderedRemove(i);
                    continue;
                }
            }
            i += 1;
        }
        const id = app.opt_anims.next_id;
        app.opt_anims.next_id += 1;
        var a: ItemAnim = .{ .id = id, .canvas = w, .item = item.id, .tracks = &.{}, .start_us = now, .duration_ms = duration_ms, .delay_ms = delay_ms, .timing = timing, .repeat = repeat };
        a.command = try gpa.dupe(u8, command);
        a.tracks = try tracks.toOwnedSlice(gpa);
        l.append(gpa, a) catch |e| {
            a.deinit(gpa);
            return e;
        };
        last = id;
    }
    changed(w);
    app.requestFrame();
    return .{ .str = try std.fmt.allocPrint(it.alloc(), "anim#{d}", .{last}) };
}

pub fn register(app: *App) !void {
    const it = app.it;
    try it.register("canvas", widget.classCommand(&class));
    try app.classes.put(app.gpa, "canvas", &class);
    try it.register("image", image_mod.cmdImage);
    _ = try it.eval(
        \\bind Canvas <MouseWheel> {%W yview scroll [expr {-%D / 60.0}] units}
        \\bind Canvas <Shift-MouseWheel> {%W xview scroll [expr {-%D / 60.0}] units}
    );
}
