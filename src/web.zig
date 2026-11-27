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
//!
//! A posted menu and its cascades are popup windows of the headless
//! backend. Each popup draws with the CPU renderer into an image with
//! premultiplied alpha. The page shows each image in a canvas of a layer
//! above the page, at the place of the popup, and gives the input of that
//! canvas to the popup (`ztk_popup_*`). The screen of the popups is the
//! viewport of the page (`ztk_screen`), so a menu can extend past the
//! canvas of the window.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

/// libghostty-vt logs, and WebAssembly has no stderr.
pub const std_options: std.Options = .{ .logFn = @import("ztcl").vt.noLog };
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
    head.draw_popups = true;
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
    return evalText(ptr[0..len], false);
}

/// Runs the main script of the page as `ztk_eval` does. The debug state
/// keeps the place of its text, so a command in a proc of the script
/// gets its line in the script (`fileline` of `ztk::debug why`).
export fn ztk_eval_main(ptr: [*]const u8, len: usize) i32 {
    return evalText(ptr[0..len], true);
}

fn evalText(text: []const u8, main: bool) i32 {
    if (!ready) return 1;
    result_buf.clearRetainingCapacity();
    if (runText(text, main)) |v| {
        result_buf.appendSlice(gpa, it.str(v) catch "") catch {};
        return 0;
    } else |_| {
        result_buf.appendSlice(gpa, it.str(it.result) catch "") catch {};
        return 1;
    }
}

fn runText(text: []const u8, main: bool) ztcl.Error!ztcl.Value {
    if (!main) return it.eval(text);
    const src = try it.alloc().dupe(u8, text);
    app.dbg.noteText(gpa, src, 1, it.script_name);
    return it.evalTop(try it.compile(src));
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

/// The RGBA image page of the atlas, 1024 by 1024 texels of 4 bytes, or
/// null before the first image. It changes with `ztk_atlas_version`.
export fn ztk_images() ?[*]const u8 {
    const page = head.imagePage(app.window.?) orelse return null;
    if (page.len == 0) return null;
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

// ---- Popups ----

/// The popup window `i`, in the order of their creation, or null.
fn popupWin(i: u32) ?*ztk.platform.Window {
    var n: u32 = 0;
    for (head.windows.items) |r| if (r.popup != null) {
        if (n == i) return r.win;
        n += 1;
    };
    return null;
}

/// The viewport of the page in the logical pixels of the window of ".", from its top-left corner.
export fn ztk_screen(x: i32, y: i32, w: i32, h: i32) void {
    head.screen = .{ .x = x, .y = y, .w = w, .h = h };
}

/// The count of popup windows.
export fn ztk_popups() u32 {
    var n: u32 = 0;
    for (head.windows.items) |r| n += @intFromBool(r.popup != null);
    return n;
}

/// Counts the draws of each window, so the page knows when a popup has a new image.
export fn ztk_draws() u32 {
    return head.frames_drawn;
}

var popup_rect: [6]i32 = undefined;

/// The place and the logical size of popup `i` in the window of ".", and
/// the size of its image in device pixels: x, y, w, h, image w, image h.
export fn ztk_popup_rect(i: u32) ?[*]const i32 {
    const win = popupWin(i) orelse return null;
    const o = head.absPos(win);
    const img = head.image(win);
    popup_rect = .{ o.x, o.y, win.size.w, win.size.h, if (img) |m| @intCast(m.width) else 0, if (img) |m| @intCast(m.height) else 0 };
    return &popup_rect;
}

/// The RGBA image of popup `i` with premultiplied alpha, or null.
export fn ztk_popup_image(i: u32) ?[*]const u8 {
    const img = head.image(popupWin(i) orelse return null) orelse return null;
    return img.pixels.ptr;
}

export fn ztk_popup_pointer(i: u32, x: f32, y: f32) void {
    head.pointerMove(popupWin(i) orelse return, x, y);
}

export fn ztk_popup_button(i: u32, button: u8, pressed: bool) void {
    head.pointerButton(popupWin(i) orelse return, button, pressed);
}

export fn ztk_popup_leave(i: u32) void {
    head.pointerLeave(popupWin(i) orelse return);
}

/// A press on the page outside the canvas and the popups closes the popups, as a compositor does.
export fn ztk_popup_dismiss() void {
    const win = popupWin(0) orelse return;
    head.close(win);
}

// The build of one program file for "Download your app" (`appbin.zig`,
// web/ztcl-build.js). The page adds each file with `ztk_build_add`, then
// calls `ztk_build` with a runtime. The output or the error text stays in
// the memory of the module until `ztk_build_reset`.
const appbin = @import("appbin.zig");
var build_arena: std.heap.ArenaAllocator = .init(gpa);
var build_files: std.ArrayList(appbin.File) = .empty;
var build_out: []const u8 = "";

export fn ztk_build_add(name_ptr: [*]const u8, name_len: usize, ptr: [*]const u8, len: usize) bool {
    const a = build_arena.allocator();
    const f: appbin.File = .{ .name = a.dupe(u8, name_ptr[0..name_len]) catch return false, .data = a.dupe(u8, ptr[0..len]) catch return false };
    build_files.append(a, f) catch return false;
    return true;
}

/// Gives 0 and the program file, or 1 and the text of the error. The
/// first file is the main script.
export fn ztk_build(rt_ptr: [*]const u8, rt_len: usize, allow_ptr: [*]const u8, allow_len: usize, name_ptr: [*]const u8, name_len: usize) i32 {
    const a = build_arena.allocator();
    build_out = appbin.build(a, rt_ptr[0..rt_len], build_files.items, allow_ptr[0..allow_len], null, name_ptr[0..name_len]) catch |e| {
        build_out = appbin.describe(e);
        return 1;
    };
    return 0;
}

export fn ztk_build_ptr() [*]const u8 {
    return build_out.ptr;
}

export fn ztk_build_len() usize {
    return build_out.len;
}

export fn ztk_build_reset() void {
    build_files = .empty;
    build_out = "";
    _ = build_arena.reset(.free_all);
}
