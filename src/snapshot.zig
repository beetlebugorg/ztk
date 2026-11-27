//! `ztk::snapshot` and `ztk::tree`: a picture and a description of the
//! widgets, for tests and for tools that drive an app (the MCP bridge of
//! dockyard).
//!
//! `ztk::snapshot pathName` gives a PNG image of the widget as base64
//! text. It runs the pending frames (as `update` does), then draws the
//! last scene of the toplevel of the widget with the CPU renderer and the
//! atlas of the App, and crops the image to the rectangle of the widget
//! in device pixels. So the image is the same on each backend, and no
//! backend has to read pixels back from its GPU.
//!
//! `ztk::tree ?pathName?` gives one list for each widget below pathName
//! (default "."), in the order of a depth-first walk: the path, the
//! class, the x and y in the toplevel, the width, the height, and 1 when
//! the widget is mapped. The numbers are logical pixels.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const app_mod = @import("app.zig");
const widget = @import("widget.zig");
const cpu = @import("render/cpu.zig");
const png = @import("png.zig");
const Image = @import("render/renderer.zig").Image;
const App = app_mod.App;
const Value = ztcl.Value;

pub fn register(it: *ztcl.Interp) !void {
    try it.register("ztk::snapshot", cmdSnapshot);
    try it.register("ztk::tree", cmdTree);
}

/// The position of `w` in its toplevel, in logical pixels.
pub fn posInTop(w: *const widget.Widget) [2]i32 {
    var p: [2]i32 = .{ 0, 0 };
    var x: ?*const widget.Widget = w;
    while (x) |c| : (x = c.parent) {
        if (c.isToplevel()) break;
        p[0] +|= c.geom.x;
        p[1] +|= c.geom.y;
    }
    return p;
}

fn cmdSnapshot(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    if (argv.len != 2) return it.wrongArgs("ztk::snapshot pathName");
    const app = App.of(it);
    const path = try it.str(argv[1]);
    if (app.lookup(path) == null) return it.fail("bad window path name \"{s}\"", .{path});
    try app.flush();
    // A script in the flush can delete the widget.
    const w = app.lookup(path) orelse return it.fail("bad window path name \"{s}\"", .{path});
    const gpa = app.gpa;
    const shot = try renderTop(it, app, w, path);
    const full = shot.image;
    defer gpa.free(full.pixels);
    const win_scale = shot.scale;

    // The rectangle of the widget in device pixels, inside the image.
    const pos = posInTop(w);
    const s = win_scale;
    const x0 = clampPx(@as(f64, @floatFromInt(pos[0])) * s, full.width);
    const y0 = clampPx(@as(f64, @floatFromInt(pos[1])) * s, full.height);
    const x1 = clampPx(@as(f64, @floatFromInt(pos[0] +| w.geom.w)) * s, full.width);
    const y1 = clampPx(@as(f64, @floatFromInt(pos[1] +| w.geom.h)) * s, full.height);
    if (x1 <= x0 or y1 <= y0) return it.fail("window \"{s}\" has no visible area", .{path});
    const cw = x1 - x0;
    const ch = y1 - y0;
    const crop: Image = .{ .width = cw, .height = ch, .pixels = try gpa.alloc(u8, @as(usize, cw) * ch * 4) };
    defer gpa.free(crop.pixels);
    var row: u32 = 0;
    while (row < ch) : (row += 1) {
        const from = (@as(usize, y0 + row) * full.width + x0) * 4;
        @memcpy(crop.pixels[@as(usize, row) * cw * 4 ..][0 .. cw * 4], full.pixels[from..][0 .. cw * 4]);
    }
    const bytes = png.encode(gpa, crop) catch return error.OutOfMemory;
    defer gpa.free(bytes);
    const enc = std.base64.standard.Encoder;
    const out = try it.alloc().alloc(u8, enc.calcSize(bytes.len));
    return .{ .str = enc.encode(out, bytes) };
}

/// The image of the last frame of the toplevel of `w`, from the CPU
/// renderer, and the scale of its window. The pixels are owned by the
/// App allocator.
/// `name` is the path for the error messages.
pub fn renderTop(it: *ztcl.Interp, app: *App, w: *widget.Widget, name: []const u8) ztcl.Error!struct { image: Image, scale: f64 } {
    const top = w.toplevel();
    const win = app.winOf(top) orelse return it.fail("window \"{s}\" is not shown", .{name});
    const scene = &app.renderOf(top).lastFrame().scene;
    if (scene.width == 0 or scene.height == 0) return it.fail("window \"{s}\" has no frame yet", .{name});
    var full: Image = .{ .width = scene.width, .height = scene.height, .pixels = try app.gpa.alloc(u8, @as(usize, scene.width) * scene.height * 4) };
    cpu.render(scene, &app.atlas, &full);
    return .{ .image = full, .scale = win.scale };
}

fn clampPx(v: f64, max: u32) u32 {
    const r = @round(v);
    if (r <= 0) return 0;
    if (r >= @as(f64, @floatFromInt(max))) return max;
    return @intFromFloat(r);
}

fn cmdTree(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    if (argv.len > 2) return it.wrongArgs("ztk::tree ?pathName?");
    const app = App.of(it);
    const path = if (argv.len == 2) try it.str(argv[1]) else ".";
    const w = app.lookup(path) orelse return it.fail("bad window path name \"{s}\"", .{path});
    var items: std.ArrayList(Value) = .empty;
    try walk(it, w, &items);
    return ztcl.value.wrapList(it.alloc(), items.items);
}

fn walk(it: *ztcl.Interp, w: *widget.Widget, items: *std.ArrayList(Value)) ztcl.Error!void {
    const a = it.alloc();
    const pos = posInTop(w);
    const fields = try a.alloc(Value, 7);
    fields[0] = .{ .str = try a.dupe(u8, w.path) };
    fields[1] = .{ .str = try a.dupe(u8, w.tk_class) };
    fields[2] = .{ .int = pos[0] };
    fields[3] = .{ .int = pos[1] };
    fields[4] = .{ .int = w.geom.w };
    fields[5] = .{ .int = w.geom.h };
    fields[6] = .{ .int = @intFromBool(w.mapped) };
    try items.append(a, try ztcl.value.wrapList(a, fields));
    for (w.children.items) |c| try walk(it, c, items);
}
