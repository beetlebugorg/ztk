//! The backend interface. A backend makes windows, gives events, tells
//! the time, and draws a scene. A `Platform` is a pointer and a table of
//! functions. The core calls a backend only through this table.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const geom = @import("../geom.zig");
const event = @import("../event.zig");
const loop = @import("../loop.zig");
const Event = event.Event;
const Target = @import("../render/thread.zig").Target;
const RenderThread = @import("../render/thread.zig").RenderThread;

pub const WindowOptions = struct { title: []const u8 = "", size: geom.Size = .{ .w = 200, .h = 200 } };

/// The pointer shapes, with the names of the CSS `cursor` property.
pub const Cursor = enum {
    default,
    pointer,
    text,
    wait,
    progress,
    crosshair,
    move,
    not_allowed,
    help,
    grab,
    grabbing,
    ew_resize,
    ns_resize,
    nwse_resize,
    nesw_resize,

    /// The shape of a CSS name. A name with no shape gives `default`.
    pub fn fromCss(name: []const u8) Cursor {
        var buf: [16]u8 = undefined;
        if (name.len > buf.len) return .default;
        for (name, 0..) |ch, i| buf[i] = if (ch == '-') '_' else ch;
        return std.meta.stringToEnum(Cursor, buf[0..name.len]) orelse .default;
    }

    /// The shape of a cursor name of Tk (the X cursor font), or null
    /// for a name with no shape here.
    pub fn fromTk(name: []const u8) ?Cursor {
        const map = [_]struct { []const u8, Cursor }{
            .{ "arrow", .default },         .{ "left_ptr", .default },         .{ "top_left_arrow", .default },
            .{ "xterm", .text },            .{ "hand1", .pointer },            .{ "hand2", .pointer },
            .{ "watch", .wait },            .{ "crosshair", .crosshair },      .{ "cross", .crosshair },
            .{ "tcross", .crosshair },      .{ "fleur", .move },               .{ "question_arrow", .help },
            .{ "sb_h_double_arrow", .ew_resize }, .{ "sb_v_double_arrow", .ns_resize }, .{ "X_cursor", .not_allowed },
            .{ "size_we", .ew_resize },     .{ "size_ns", .ns_resize },        .{ "size_nw_se", .nwse_resize },
            .{ "size_ne_sw", .nesw_resize }, .{ "size", .move },
        };
        for (map) |m| if (std.mem.eql(u8, m[0], name)) return m[1];
        return null;
    }
};

pub const Window = struct {
    /// Logical pixels.
    size: geom.Size,
    scale: f32 = 1,
    /// The toplevel widget.
    user: ?*anyopaque = null,
    /// The data of the backend.
    impl: ?*anyopaque = null,
    /// The render thread of the window, for the pointer positions that the
    /// backend gives it from any thread. Null when the window has none.
    render: std.atomic.Value(?*RenderThread) = .init(null),

    /// Gives a pointer position to the render thread of the window.
    pub fn feedPointer(w: *Window, x: f32, y: f32) void {
        if (w.render.load(.acquire)) |r| r.pointer(x, y);
    }
};

pub const Platform = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    /// True for a backend that can give events by itself (a display).
    /// A wait on such a backend can end. A wait on the headless backend
    /// with no timer cannot.
    live: bool = false,
    /// True when the target can draw on a thread other than the UI thread.
    thread_safe_draw: bool = false,

    pub const VTable = struct {
        deinit: *const fn (ptr: *anyopaque) void,
        createWindow: *const fn (ptr: *anyopaque, opts: WindowOptions) anyerror!*Window,
        destroyWindow: *const fn (ptr: *anyopaque, w: *Window) void,
        setTitle: *const fn (ptr: *anyopaque, w: *Window, title: []const u8) void,
        /// Asks for a size. The backend answers with a `resize` event.
        requestSize: *const fn (ptr: *anyopaque, w: *Window, size: geom.Size) void,
        setMinSize: *const fn (ptr: *anyopaque, w: *Window, size: geom.Size) void,
        /// Asks for one `frame` event at the next display refresh.
        requestFrame: *const fn (ptr: *anyopaque, w: *Window) void,
        /// Blocks until an event exists or the time passed. Null: no limit.
        wait: *const fn (ptr: *anyopaque, timeout_us: ?i64) void,
        /// Moves the pending events to `out`.
        poll: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(Event)) anyerror!void,
        nowUs: *const fn (ptr: *anyopaque) i64,
        /// The target that draws and shows one frame of the window. The
        /// render thread calls it.
        target: *const fn (ptr: *anyopaque, w: *Window) Target,
        /// Sets the clock. Only a backend with a manual clock has it.
        setTimeUs: ?*const fn (ptr: *anyopaque, us: i64) void = null,
        /// Sets the pointer shape over the client area of a window. Null:
        /// the backend keeps its own shape.
        setCursor: ?*const fn (ptr: *anyopaque, w: *Window, shape: Cursor) void = null,
        /// Puts data of a type on the clipboard of the system. The core
        /// calls it with the type `STRING` and UTF-8 text.
        clipboardSet: ?*const fn (ptr: *anyopaque, typ: []const u8, data: []const u8) void = null,
        /// The data of a type on the clipboard of the system, in memory of
        /// `gpa`. Null: the system has no data of the type, or the data of
        /// the last `clipboardSet` is still the latest.
        clipboardGet: ?*const fn (ptr: *anyopaque, gpa: std.mem.Allocator, typ: []const u8) ?[]u8 = null,
        /// Turns the input method of a window on for a text widget with the
        /// focus, or off. `rect` is the place of the text in logical pixels
        /// of the window, for the candidate window of the input method.
        textInput: ?*const fn (ptr: *anyopaque, w: *Window, on: bool, rect: geom.Rect) void = null,
    };

    pub fn textInput(p: Platform, w: *Window, on: bool, rect: geom.Rect) void {
        if (p.vtable.textInput) |f| f(p.ptr, w, on, rect);
    }

    pub fn clipboardSet(p: Platform, typ: []const u8, data: []const u8) void {
        if (p.vtable.clipboardSet) |f| f(p.ptr, typ, data);
    }

    pub fn clipboardGet(p: Platform, gpa: std.mem.Allocator, typ: []const u8) ?[]u8 {
        const f = p.vtable.clipboardGet orelse return null;
        return f(p.ptr, gpa, typ);
    }

    pub fn setCursor(p: Platform, w: *Window, shape: Cursor) void {
        if (p.vtable.setCursor) |f| f(p.ptr, w, shape);
    }

    pub fn target(p: Platform, w: *Window) Target {
        return p.vtable.target(p.ptr, w);
    }
    pub fn createWindow(p: Platform, opts: WindowOptions) !*Window {
        return p.vtable.createWindow(p.ptr, opts);
    }
    pub fn destroyWindow(p: Platform, w: *Window) void {
        p.vtable.destroyWindow(p.ptr, w);
    }
    pub fn requestFrame(p: Platform, w: *Window) void {
        p.vtable.requestFrame(p.ptr, w);
    }
    pub fn nowUs(p: Platform) i64 {
        return p.vtable.nowUs(p.ptr);
    }
    pub fn wait(p: Platform, timeout_us: ?i64) void {
        p.vtable.wait(p.ptr, timeout_us);
    }
    pub fn poll(p: Platform, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(Event)) !void {
        return p.vtable.poll(p.ptr, gpa, out);
    }

    fn clockNow(ctx: ?*anyopaque) i64 {
        const p: *const Platform = @ptrCast(@alignCast(ctx.?));
        return p.nowUs();
    }

    fn clockWait(ctx: ?*anyopaque, micros: ?i64) void {
        const p: *const Platform = @ptrCast(@alignCast(ctx.?));
        p.wait(micros);
    }

    /// The clock of the loop. `p` must stay at the same address while
    /// the clock is in use, so the App keeps its Platform and gives the
    /// address. This differs from the plan, which passes the value.
    pub fn clock(p: *const Platform) loop.Clock {
        return .{ .ctx = @constCast(p), .now = clockNow, .wait = clockWait };
    }
};
