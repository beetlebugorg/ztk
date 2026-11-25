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

pub const WindowOptions = struct { title: []const u8 = "", size: geom.Size = .{ .w = 200, .h = 200 } };

pub const Window = struct {
    /// Logical pixels.
    size: geom.Size,
    scale: f32 = 1,
    /// The toplevel widget.
    user: ?*anyopaque = null,
    /// The data of the backend.
    impl: ?*anyopaque = null,
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
    };

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
