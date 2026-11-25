//! The entry of the WebAssembly build: ztk in a browser. The page
//! (`web/ztk.js`) owns the canvas, the input, and the GPU. This file
//! keeps an interpreter, an App, and a headless backend whose clock and
//! input come from the page through the exported functions. The page
//! calls `ztk_frame` from `requestAnimationFrame`. When the App makes no
//! new frame, `ztk_frame` moves the animations and the drags of the last
//! frame for the new time, as the render thread of the native build
//! does. A frame leaves its
//! scene and the atlas page in the memory of the module, and the page
//! draws the quads with WebGL 2 and the same formulas as the CPU
//! renderer. The build has no thread, no file, and no clock of its own.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const ztk = @import("ztk.zig");
const Headless = @import("platform/headless.zig").Headless;
const scene = @import("scene.zig");

const gpa = std.heap.wasm_allocator;

var it: ztcl.Interp = undefined;
var head: *Headless = undefined;
var app: *ztk.App = undefined;
var ready = false;

/// The text of the last result or error, for the page.
var result_buf: std.ArrayListUnmanaged(u8) = .empty;

fn write(_: ?*anyopaque, text: []const u8) void {
    @import("sys/host.zig").writeStderr(text);
}

/// Memory for the page: the page writes a script or a text into it.
export fn ztk_alloc(len: usize) ?[*]u8 {
    const m = gpa.alloc(u8, len) catch return null;
    return m.ptr;
}

export fn ztk_free(ptr: [*]u8, len: usize) void {
    gpa.free(ptr[0..len]);
}

/// Makes the App with a window of `w` by `h` logical pixels at a scale.
export fn ztk_init(w: i32, h: i32, scale: f32, dark: bool, reduce_motion: bool) bool {
    it.init(gpa) catch return false;
    it.output = .{ .ctx = null, .write = write };
    head = Headless.init(gpa) catch return false;
    head.skip_draw = true;
    app = ztk.App.init(gpa, &it, .{ .platform = head.platform(), .dark = dark, .err_output = .{ .ctx = null, .write = write } }) catch return false;
    app.reduce_motion = reduce_motion;
    app.virtual_file = virtualFile;
    app.style_root = gpa.dupe(u8, "web") catch null;
    const win = app.window orelse return false;
    win.scale = scale;
    head.resize(win, .{ .w = w, .h = h });
    ready = true;
    return true;
}

/// Runs a script. Returns 0 for ok and 1 for an error. `ztk_result` has the text.
export fn ztk_eval(ptr: [*]const u8, len: usize) i32 {
    if (!ready) return 1;
    result_buf.clearRetainingCapacity();
    if (it.eval(ptr[0..len])) |v| {
        result_buf.appendSlice(gpa, it.str(v) catch "") catch {};
        return 0;
    } else |_| {
        result_buf.appendSlice(gpa, it.str(it.result) catch "") catch {};
        return 1;
    }
}

export fn ztk_result_ptr() [*]const u8 {
    return result_buf.items.ptr;
}

export fn ztk_result_len() usize {
    return result_buf.items.len;
}

/// Sets the clock and runs the waiting events, timers, and one frame. Returns
/// the count of quads of the scene, or -1 when nothing new was drawn.
export fn ztk_frame(time_ms: f64) i32 {
    if (!ready) return -1;
    head.now_us = @intFromFloat(time_ms * 1000);
    const before = app.frames;
    _ = app.doOneEvent(false) catch {};
    app.flush() catch {};
    if (app.frames == before) {
        // No new frame: the animations and the drags of the last frame move for the new time.
        if (!app.render.advance(head.now_us)) return -1;
    }
    return @intCast(app.lastScene().quads.items.len);
}

export fn ztk_quads() [*]const scene.Quad {
    return app.lastScene().quads.items.ptr;
}

export fn ztk_scene_width() u32 {
    return app.lastScene().width;
}

export fn ztk_scene_height() u32 {
    return app.lastScene().height;
}

export fn ztk_clear_color() [*]const f32 {
    return &app.lastScene().clear;
}

export fn ztk_atlas() ?[*]const u8 {
    const page = head.atlasPage(app.window.?) orelse return null;
    return page.ptr;
}

export fn ztk_resize(w: i32, h: i32, scale: f32) void {
    const win = app.window orelse return;
    win.scale = scale;
    head.resize(win, .{ .w = w, .h = h });
    head.setScale(win, scale);
}

/// A new scale (devicePixelRatio) for the window, with its size kept.
export fn ztk_scale(scale: f32) void {
    const win = app.window orelse return;
    head.setScale(win, scale);
}

export fn ztk_pointer(x: f32, y: f32) void {
    head.pointerMove(app.window.?, x, y);
}

export fn ztk_button(button: u8, pressed: bool) void {
    head.pointerButton(app.window.?, button, pressed);
}

/// A wheel or touchpad scroll, in wheel steps (1 is one step down or right).
export fn ztk_wheel(dx: f32, dy: f32) void {
    head.pointerScroll(app.window.?, dx, dy);
}

export fn ztk_leave() void {
    head.pointerLeave(app.window.?);
}

/// A key by its X11 key symbol name, for example "Return".
export fn ztk_key(ptr: [*]const u8, len: usize, pressed: bool) bool {
    head.key(app.window.?, ptr[0..len], pressed) catch return false;
    return true;
}

/// Text from the hidden input element: typed characters and the end of a composition.
export fn ztk_text(ptr: [*]const u8, len: usize) void {
    head.typeText(app.window.?, ptr[0..len]) catch {};
}

export fn ztk_mods(shift: bool, ctrl: bool, alt: bool) void {
    head.setMods(.{ .shift = shift, .control = ctrl, .mod1 = alt });
}

export fn ztk_dark(dark: bool) void {
    app.env.dark = dark;
    app.styles.generation +%= 1;
    if (app.root) |r| r.invalidate(.{ .style = true, .measure = true, .layout = true, .paint = true });
}

export fn ztk_reduce_motion(on: bool) void {
    app.reduce_motion = on;
}

/// Turns the CPU renderer on or off. With it on, each frame also draws
/// the scene to an RGBA image, for a page that has no GPU renderer.
export fn ztk_cpu(on: bool) void {
    head.skip_draw = !on;
}

/// The RGBA image of the last frame of the CPU renderer, with the size of
/// the scene, or null when the CPU renderer is off.
export fn ztk_image() ?[*]const u8 {
    const img = head.image(app.window orelse return null) orelse return null;
    return img.pixels.ptr;
}

/// The count of frames that the App drew.
export fn ztk_frames() u64 {
    return app.frames;
}

export fn ztk_atlas_version() u32 {
    return head.patches_applied;
}

var a11y_buf: std.ArrayListUnmanaged(u8) = .empty;

fn appendJsonString(out: *std.ArrayListUnmanaged(u8), text: []const u8) !void {
    try out.append(gpa, '"');
    for (text) |c| switch (c) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        0...9, 11...31 => try out.print(gpa, "\\u{x:0>4}", .{c}),
        else => try out.append(gpa, c),
    };
    try out.append(gpa, '"');
}

fn a11yNode(w: *ztk.widget.Widget, ox: i32, oy: i32) !void {
    if (!w.mapped) return;
    const x = ox + w.geom.x;
    const y = oy + w.geom.y;
    if (w.class.role.len > 0 and w.parent != null) {
        if (a11y_buf.items.len > 1) try a11y_buf.append(gpa, ',');
        try a11y_buf.appendSlice(gpa, "{\"path\":");
        try appendJsonString(&a11y_buf, w.path);
        try a11y_buf.appendSlice(gpa, ",\"role\":");
        try appendJsonString(&a11y_buf, w.class.role);
        var name: []const u8 = "";
        for (w.class.specs, w.opts) |sp, slot| if (std.mem.eql(u8, sp.name, "-text")) {
            name = if (w.class.variable_text) |f| (f(w) orelse slot.text) else slot.text;
        };
        try a11y_buf.appendSlice(gpa, ",\"name\":");
        try appendJsonString(&a11y_buf, name);
        try a11y_buf.print(gpa, ",\"x\":{d},\"y\":{d},\"w\":{d},\"h\":{d},\"selected\":{},\"disabled\":{},\"focus\":{}}}", .{ x, y, w.geom.w, w.geom.h, w.state.selected, w.state.disabled, w.state.focus });
    }
    for (w.children.items) |c| try a11yNode(c, x, y);
}

/// The accessible nodes of the window of "." as JSON: path, role, name, bounds, and states.
export fn ztk_a11y() usize {
    a11y_buf.clearRetainingCapacity();
    a11y_buf.append(gpa, '[') catch return 0;
    if (app.root) |r| a11yNode(r, -r.geom.x, -r.geom.y) catch return 0;
    a11y_buf.append(gpa, ']') catch return 0;
    return a11y_buf.items.len;
}

export fn ztk_a11y_ptr() [*]const u8 {
    return a11y_buf.items.ptr;
}

/// The files that the page gave, by name: the style sheets of the examples.
var files: std.StringHashMapUnmanaged([]u8) = .empty;

fn virtualFile(name: []const u8) ?[]const u8 {
    return files.get(name);
}

/// Gives the module a file, for example "gallery.css", that `ztk::style load` reads.
export fn ztk_add_file(name_ptr: [*]const u8, name_len: usize, ptr: [*]const u8, len: usize) bool {
    const name = gpa.dupe(u8, name_ptr[0..name_len]) catch return false;
    const text = gpa.dupe(u8, ptr[0..len]) catch return false;
    files.put(gpa, name, text) catch return false;
    return true;
}
