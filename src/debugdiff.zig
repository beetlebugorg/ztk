//! Visual diffs of `ztk::debug mark` and `ztk::debug diff`.
//!
//! A mark keeps the image of a toplevel from the CPU renderer, as
//! `ztk::snapshot` makes it, and the state of each widget in it: the
//! path, the class, the box in the toplevel, the map state, and the text
//! of each option. `diff` makes the same capture again and compares the
//! two. The pixel part counts the device pixels where a channel differs
//! by more than the tolerance and gives their bounding box in logical
//! pixels. The tree part gives the widgets that were added or removed,
//! the boxes and the map states that changed, and the options whose text
//! changed. With `-image`, the answer has a PNG of the new image where
//! each changed pixel is red and each other pixel is a pale copy.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const app_mod = @import("app.zig");
const widget_mod = @import("widget.zig");
const options = @import("options.zig");
const snapshot = @import("snapshot.zig");
const png = @import("png.zig");
const Image = @import("render/renderer.zig").Image;
const App = app_mod.App;
const Widget = widget_mod.Widget;
const Value = ztcl.Value;

const Opt = struct { name: []const u8, text: []u8 };

const WState = struct {
    path: []u8,
    class: []u8,
    box: [4]i32,
    mapped: bool,
    opts: []Opt,

    fn free(s: *WState, gpa: std.mem.Allocator) void {
        gpa.free(s.path);
        gpa.free(s.class);
        for (s.opts) |o| gpa.free(o.text);
        gpa.free(s.opts);
    }
};

pub const Mark = struct {
    top: []u8,
    image: Image,
    scale: f64,
    widgets: []WState,

    pub fn free(m: *Mark, gpa: std.mem.Allocator) void {
        gpa.free(m.top);
        gpa.free(m.image.pixels);
        for (m.widgets) |*w| w.free(gpa);
        gpa.free(m.widgets);
        gpa.destroy(m);
    }
};

pub const Marks = std.StringHashMapUnmanaged(*Mark);

pub fn deinit(marks: *Marks, gpa: std.mem.Allocator) void {
    var iter = marks.iterator();
    while (iter.next()) |e| {
        gpa.free(e.key_ptr.*);
        e.value_ptr.*.free(gpa);
    }
    marks.deinit(gpa);
}

fn stateOf(it: *ztcl.Interp, gpa: std.mem.Allocator, w: *Widget, out: *std.ArrayList(WState)) !void {
    const pos = snapshot.posInTop(w);
    var opts: std.ArrayList(Opt) = .empty;
    errdefer {
        for (opts.items) |o| gpa.free(o.text);
        opts.deinit(gpa);
    }
    for (w.class.specs, 0..) |sp, i| {
        if (sp.hidden or sp.type == .synonym) continue;
        const text = try gpa.dupe(u8, try options.textOf(w, it, i));
        opts.append(gpa, .{ .name = sp.name, .text = text }) catch |e| {
            gpa.free(text);
            return e;
        };
    }
    const path = try gpa.dupe(u8, w.path);
    errdefer gpa.free(path);
    const class = try gpa.dupe(u8, w.tk_class);
    errdefer gpa.free(class);
    const o = try opts.toOwnedSlice(gpa);
    out.append(gpa, .{ .path = path, .class = class, .box = .{ pos[0], pos[1], w.geom.w, w.geom.h }, .mapped = w.mapped, .opts = o }) catch |e| {
        for (o) |x| gpa.free(x.text);
        gpa.free(o);
        return e;
    };
    for (w.children.items) |c| {
        if (c.isToplevel() or !c.alive()) continue;
        try stateOf(it, gpa, c, out);
    }
}

/// Captures the image and the widgets of the toplevel of `w`.
pub fn capture(it: *ztcl.Interp, app: *App, w: *Widget, name: []const u8) ztcl.Error!*Mark {
    const gpa = app.gpa;
    const top = w.toplevel();
    const shot = try snapshot.renderTop(it, app, top, name);
    errdefer gpa.free(shot.image.pixels);
    var list: std.ArrayList(WState) = .empty;
    errdefer {
        for (list.items) |*s| s.free(gpa);
        list.deinit(gpa);
    }
    try stateOf(it, gpa, top, &list);
    const m = try gpa.create(Mark);
    errdefer gpa.destroy(m);
    const top_path = try gpa.dupe(u8, top.path);
    m.* = .{ .top = top_path, .image = shot.image, .scale = shot.scale, .widgets = try list.toOwnedSlice(gpa) };
    return m;
}

fn boxValue(a: std.mem.Allocator, b: [4]i32) !Value {
    return ztcl.value.newList(a, &.{ .{ .int = b[0] }, .{ .int = b[1] }, .{ .int = b[2] }, .{ .int = b[3] } });
}

fn find(list: []const WState, path: []const u8) ?*const WState {
    for (list) |*s| if (std.mem.eql(u8, s.path, path)) return s;
    return null;
}

/// The answer of `diff`: a dict. `old` is the mark, `new` the capture now.
pub fn compare(it: *ztcl.Interp, gpa: std.mem.Allocator, old: *const Mark, new: *const Mark, tolerance: u8, want_image: bool) ztcl.Error!Value {
    const a = it.alloc();
    var d: std.ArrayList(Value) = .empty;
    const ow = old.image.width;
    const oh = old.image.height;
    const nw = new.image.width;
    const nh = new.image.height;
    if (ow != nw or oh != nh) {
        try d.appendSlice(a, &.{
            .{ .str = "size" },
            try ztcl.value.newList(a, &.{
                try ztcl.value.newList(a, &.{ .{ .int = ow }, .{ .int = oh } }),
                try ztcl.value.newList(a, &.{ .{ .int = nw }, .{ .int = nh } }),
            }),
        });
    }
    // The pixels. A pixel outside the old image counts as changed.
    var count: usize = 0;
    var x0: u32 = nw;
    var y0: u32 = nh;
    var x1: u32 = 0;
    var y1: u32 = 0;
    var tint: []u8 = &.{};
    if (want_image) tint = try gpa.alloc(u8, @as(usize, nw) * nh * 4);
    defer if (want_image) gpa.free(tint);
    var y: u32 = 0;
    while (y < nh) : (y += 1) {
        var x: u32 = 0;
        while (x < nw) : (x += 1) {
            const ni = (@as(usize, y) * nw + x) * 4;
            var changed = true;
            if (x < ow and y < oh) {
                const oi = (@as(usize, y) * ow + x) * 4;
                var worst: u8 = 0;
                for (0..4) |c| {
                    const p = new.image.pixels[ni + c];
                    const q = old.image.pixels[oi + c];
                    worst = @max(worst, if (p > q) p - q else q - p);
                }
                changed = worst > tolerance;
            }
            if (changed) {
                count += 1;
                x0 = @min(x0, x);
                y0 = @min(y0, y);
                x1 = @max(x1, x + 1);
                y1 = @max(y1, y + 1);
            }
            if (want_image) {
                const px = new.image.pixels[ni..][0..4];
                const out = tint[ni..][0..4];
                if (changed) {
                    out.* = .{ 255, 0, 0, 255 };
                } else {
                    // A pale copy: three parts white to one part of the pixel.
                    for (0..3) |c| out[c] = @intCast((@as(u16, px[c]) + 3 * 255) / 4);
                    out[3] = 255;
                }
            }
        }
    }
    try d.appendSlice(a, &.{ .{ .str = "pixels" }, .{ .int = @intCast(count) } });
    if (count > 0) {
        const s = new.scale;
        const lx0: i32 = @intFromFloat(@floor(@as(f64, @floatFromInt(x0)) / s));
        const ly0: i32 = @intFromFloat(@floor(@as(f64, @floatFromInt(y0)) / s));
        const lx1: i32 = @intFromFloat(@ceil(@as(f64, @floatFromInt(x1)) / s));
        const ly1: i32 = @intFromFloat(@ceil(@as(f64, @floatFromInt(y1)) / s));
        try d.appendSlice(a, &.{ .{ .str = "box" }, try boxValue(a, .{ lx0, ly0, lx1 - lx0, ly1 - ly0 }) });
    }
    // The widgets.
    var added: std.ArrayList(Value) = .empty;
    var removed: std.ArrayList(Value) = .empty;
    var moved: std.ArrayList(Value) = .empty;
    var mapped: std.ArrayList(Value) = .empty;
    var opts: std.ArrayList(Value) = .empty;
    for (new.widgets) |*nwg| {
        const o = find(old.widgets, nwg.path) orelse {
            try added.append(a, .{ .str = try a.dupe(u8, nwg.path) });
            continue;
        };
        if (!std.mem.eql(i32, &o.box, &nwg.box)) {
            try moved.append(a, try ztcl.value.newList(a, &.{ .{ .str = try a.dupe(u8, nwg.path) }, try boxValue(a, o.box), try boxValue(a, nwg.box) }));
        }
        if (o.mapped != nwg.mapped) {
            try mapped.append(a, try ztcl.value.newList(a, &.{ .{ .str = try a.dupe(u8, nwg.path) }, .{ .int = @intFromBool(o.mapped) }, .{ .int = @intFromBool(nwg.mapped) } }));
        }
        if (!std.mem.eql(u8, o.class, nwg.class)) continue;
        for (nwg.opts) |no| {
            for (o.opts) |oo| {
                if (!std.mem.eql(u8, oo.name, no.name)) continue;
                if (!std.mem.eql(u8, oo.text, no.text)) {
                    try opts.append(a, try ztcl.value.newList(a, &.{ .{ .str = try a.dupe(u8, nwg.path) }, .{ .str = no.name }, .{ .str = try a.dupe(u8, oo.text) }, .{ .str = try a.dupe(u8, no.text) } }));
                }
                break;
            }
        }
    }
    for (old.widgets) |*owg| {
        if (find(new.widgets, owg.path) == null) try removed.append(a, .{ .str = try a.dupe(u8, owg.path) });
    }
    const groups = [_]struct { name: []const u8, list: *std.ArrayList(Value) }{
        .{ .name = "added", .list = &added },
        .{ .name = "removed", .list = &removed },
        .{ .name = "moved", .list = &moved },
        .{ .name = "mapped", .list = &mapped },
        .{ .name = "options", .list = &opts },
    };
    for (groups) |g| {
        if (g.list.items.len == 0) continue;
        try d.appendSlice(a, &.{ .{ .str = g.name }, try ztcl.value.wrapList(a, g.list.items) });
    }
    if (want_image) {
        const bytes = png.encode(gpa, .{ .width = nw, .height = nh, .pixels = tint }) catch return error.OutOfMemory;
        defer gpa.free(bytes);
        const enc = std.base64.standard.Encoder;
        const out = try a.alloc(u8, enc.calcSize(bytes.len));
        try d.appendSlice(a, &.{ .{ .str = "image" }, .{ .str = enc.encode(out, bytes) } });
    }
    return ztcl.value.wrapList(a, d.items);
}
