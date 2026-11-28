//! The render thread and the hand-over of frames. Three `Frame` values
//! exist. The UI thread fills `back`. `submit` puts it in the waiting
//! slot and takes a free frame as the new back. It does not wait for
//! the render thread, with one exception: when a frame waits and there
//! is no memory to move its atlas patches, `submit` waits until the
//! render thread takes that frame. A frame that waits and did not start
//! is replaced by the next submit, and its atlas patches move to the
//! front of the new frame, so no patch is lost. The render thread takes
//! the waiting frame, calls the target to draw and show it, and puts the
//! frame back in the free list. The shared state is one mutex, one
//! condition, the frame pointers, and two atomic counters. In
//! `inline_draw` mode `submit` draws on the calling thread. The thread
//! touches no widget, no style, and no interpreter value.
//!
//! The render thread keeps the frame that it drew last while an animation
//! of the frame runs or while the frame has a drag. It draws that frame
//! again for the time that passed, at 120 frames in each second at most,
//! and for each new pointer position that `pointer` gives. So an
//! animation and a drag move while the UI thread is busy. A backend can
//! call `pointer` from any thread. In `inline_draw` mode `advance` draws
//! the last frame again for a new time on the calling thread.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const scene = @import("../scene.zig");
const Frame = scene.Frame;
const host = @import("../sys/host.zig");

/// The time between two frames that the render thread draws by itself
/// while a transition runs: 120 frames in each second.
const anim_step_us: i64 = 8333;

pub const Mode = enum { threaded, inline_draw };

pub const Target = struct {
    ctx: *anyopaque,
    /// Draws and shows one frame. It runs on the render thread.
    draw: *const fn (ctx: *anyopaque, frame: *const Frame) anyerror!void,
};

pub const RenderThread = struct {
    gpa: std.mem.Allocator,
    mode: Mode,
    target: Target,
    frames: [3]Frame = .{ .{}, .{}, .{} },
    back_frame: *Frame,
    free: [3]?*Frame = .{ null, null, null },
    waiting: ?*Frame = null,
    drawing: ?*Frame = null,
    /// The frame that the render thread draws again while its transitions run.
    held: ?*Frame = null,
    /// The frame that was drawn last. Valid to read after `flush`.
    last: ?*Frame = null,
    serial: u64 = 0,
    quit: bool = false,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    io: std.Io,
    thread: ?std.Thread = null,
    // 32-bit counters: a wasm32 build has no 64-bit atomics.
    drawn: std.atomic.Value(u32) = .init(0),
    replaced: std.atomic.Value(u32) = .init(0),
    errors: std.atomic.Value(u32) = .init(0),
    /// The pointer position from the backend, in logical pixels of the
    /// window, and a count of its changes. Under the mutex.
    ptr_x: f32 = 0,
    ptr_y: f32 = 0,
    ptr_serial: u32 = 0,
    /// The pointer count that the held frame shows, and true while an
    /// animation of the held frame runs. Under the mutex.
    held_ptr: u32 = 0,
    held_running: bool = false,
    /// True while the thread draws the held frame again.
    held_drawing: bool = false,
    last_draw_us: i64 = 0,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, mode: Mode, target: Target) !*RenderThread {
        const r = try gpa.create(RenderThread);
        r.* = .{ .gpa = gpa, .mode = mode, .target = target, .back_frame = undefined, .io = io };
        r.back_frame = &r.frames[0];
        r.free[0] = &r.frames[1];
        r.free[1] = &r.frames[2];
        if (mode == .threaded) {
            // A build with one thread (the browser) draws inline.
            if (@import("builtin").single_threaded) {
                r.mode = .inline_draw;
            } else r.thread = try std.Thread.spawn(.{}, run, .{r});
        }
        return r;
    }

    /// Stops the thread after its current frame and joins it.
    pub fn deinit(r: *RenderThread) void {
        if (!@import("builtin").single_threaded) {
            if (r.thread) |t| {
                r.mutex.lockUncancelable(r.io);
                r.quit = true;
                r.cond.broadcast(r.io);
                r.mutex.unlock(r.io);
                t.join();
            }
        }
        for (&r.frames) |*f| f.deinit(r.gpa);
        const gpa = r.gpa;
        gpa.destroy(r);
    }

    /// The frame that the UI thread fills next. It is never the frame
    /// that the render thread reads.
    pub fn back(r: *RenderThread) *Frame {
        return r.back_frame;
    }

    fn popFree(r: *RenderThread) *Frame {
        for (&r.free) |*slot| if (slot.*) |f| {
            slot.* = null;
            return f;
        };
        unreachable;
    }

    fn pushFree(r: *RenderThread, f: *Frame) void {
        for (&r.free) |*slot| if (slot.* == null) {
            slot.* = f;
            return;
        };
        unreachable;
    }

    /// Hands the back frame to the render thread and returns at once.
    /// A frame that the render thread did not start is replaced.
    pub fn submit(r: *RenderThread) void {
        if (r.mode == .inline_draw) {
            const f = r.back_frame;
            r.serial += 1;
            f.serial = r.serial;
            f.wall_us = host.nowUs();
            r.held_running = scene.applyAnims(f, f.time_us);
            if (r.ptr_serial != 0) scene.applyDrags(f, r.ptr_x, r.ptr_y);
            r.held_ptr = r.ptr_serial;
            r.draw(f);
            r.last = f;
            return;
        }
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        const f = r.back_frame;
        r.serial += 1;
        f.serial = r.serial;
        f.wall_us = host.nowUs();
        while (r.waiting) |old| {
            // The patches of the replaced frame come first.
            if (f.patches.insertSlice(r.gpa, 0, old.patches.items)) |_| {
                old.patches.clearRetainingCapacity();
                _ = r.replaced.fetchAdd(1, .monotonic);
                r.pushFree(old);
                break;
            } else |_| {
                // No memory to move the patches. Wait until the render thread takes the
                // old frame, so that no patch is lost. This is the only wait of `submit`.
                r.cond.waitUncancelable(r.io, &r.mutex);
            }
        }
        r.waiting = f;
        const next = r.popFree();
        next.reset(r.gpa);
        r.back_frame = next;
        r.cond.signal(r.io);
    }

    /// Gives a new pointer position in logical pixels of the window. It can
    /// run on any thread. A held frame with a drag is drawn again.
    pub fn pointer(r: *RenderThread, x: f32, y: f32) void {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        r.ptr_x = x;
        r.ptr_y = y;
        r.ptr_serial +%= 1;
        if (r.ptr_serial == 0) r.ptr_serial = 1;
        r.cond.signal(r.io);
    }

    /// `inline_draw` mode: draws the last frame again for a time on the
    /// clock of the UI thread, when an animation or a drag of the frame
    /// moves. Returns true when it drew.
    pub fn advance(r: *RenderThread, time_us: i64) bool {
        if (r.mode != .inline_draw) return false;
        const f = r.last orelse return false;
        const moved = f.drags.items.len > 0 and r.held_ptr != r.ptr_serial;
        if (!r.held_running and !moved) return false;
        r.held_running = scene.applyAnims(f, time_us);
        if (r.ptr_serial != 0) scene.applyDrags(f, r.ptr_x, r.ptr_y);
        r.held_ptr = r.ptr_serial;
        r.draw(f);
        return true;
    }

    /// Makes the thread draw for another target, for a pool of render
    /// threads. It waits for the submitted frames and drops the held frame.
    pub fn retarget(r: *RenderThread, target: Target) void {
        r.flush();
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        r.dropHeld();
        r.last = null;
        r.ptr_serial = 0;
        r.held_ptr = 0;
        r.target = target;
    }

    /// Waits for the submitted frames, then stops the draws of the held
    /// frame and waits for a draw of it that runs. After it, the target
    /// gets no draw until the next `submit`, so a reader of the image of
    /// the target (the screenshot at the exit) reads a complete image.
    pub fn stopHeld(r: *RenderThread) void {
        r.flush();
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        r.dropHeld();
    }

    /// Drops the held frame. The caller has the mutex.
    fn dropHeld(r: *RenderThread) void {
        // The thread draws the held frame again only while `held` is set,
        // so it starts no new draw of it after this. A draw that runs puts
        // the frame in the free list when it ends, because `held` differs.
        // A wait that only checks `held_drawing` can wait forever: while an
        // animation runs, the thread locks the mutex again and starts the
        // next draw before the waiting thread runs.
        const h = r.held;
        r.held = null;
        r.held_running = false;
        if (h) |f| if (!r.held_drawing) r.pushFree(f);
        while (r.held_drawing) r.cond.waitUncancelable(r.io, &r.mutex);
    }

    /// Blocks until the render thread showed all submitted frames.
    pub fn flush(r: *RenderThread) void {
        if (r.mode == .inline_draw) return;
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        while (r.waiting != null or r.drawing != null) r.cond.waitUncancelable(r.io, &r.mutex);
    }

    /// The frame that was drawn last. Call it after `flush`.
    pub fn lastFrame(r: *RenderThread) *const Frame {
        return r.last orelse r.back_frame;
    }

    fn draw(r: *RenderThread, f: *Frame) void {
        r.target.draw(r.target.ctx, f) catch {
            _ = r.errors.fetchAdd(1, .monotonic);
        };
        _ = r.drawn.fetchAdd(1, .monotonic);
    }

    /// True when the held frame must be drawn again.
    fn heldMoves(r: *const RenderThread) bool {
        const h = r.held orelse return false;
        return r.held_running or (h.drags.items.len > 0 and r.held_ptr != r.ptr_serial);
    }

    fn keeps(f: *const Frame, running: bool) bool {
        return running or f.drags.items.len > 0;
    }

    fn run(r: *RenderThread) void {
        while (true) {
            r.mutex.lockUncancelable(r.io);
            while (r.waiting == null and !r.quit and !r.heldMoves()) r.cond.waitUncancelable(r.io, &r.mutex);
            if (r.quit) {
                if (r.held) |h| r.pushFree(h);
                r.held = null;
                if (r.waiting == null) {
                    r.mutex.unlock(r.io);
                    return;
                }
            }
            if (r.waiting == null) {
                // An animation runs or the pointer moved, and no new frame came: draw the
                // held frame again, so a busy UI thread does not stop it. `flush` does not
                // wait for this draw: it waits only for submitted frames.
                const h = r.held.?;
                r.held_drawing = true;
                r.mutex.unlock(r.io);
                const wait = r.last_draw_us + anim_step_us - host.nowUs();
                if (wait > 0) host.sleepUs(wait);
                r.mutex.lockUncancelable(r.io);
                const ser = r.ptr_serial;
                const px = r.ptr_x;
                const py = r.ptr_y;
                r.mutex.unlock(r.io);
                const running = scene.applyAnims(h, h.time_us + (host.nowUs() - h.wall_us));
                if (ser != 0) scene.applyDrags(h, px, py);
                r.last_draw_us = host.nowUs();
                r.draw(h);
                r.mutex.lockUncancelable(r.io);
                r.held_drawing = false;
                r.last = h;
                r.held_ptr = ser;
                r.held_running = running;
                if (!keeps(h, running) or r.held != h) {
                    if (r.held == h) r.held = null;
                    r.pushFree(h);
                }
                r.cond.broadcast(r.io);
                r.mutex.unlock(r.io);
                continue;
            }
            const f = r.waiting.?;
            r.waiting = null;
            // A new frame replaces the held one.
            if (r.held) |h| {
                r.pushFree(h);
                r.held = null;
            }
            r.drawing = f;
            const ser = r.ptr_serial;
            const px = r.ptr_x;
            const py = r.ptr_y;
            // A `submit` can wait for the old frame to leave the slot.
            r.cond.broadcast(r.io);
            r.mutex.unlock(r.io);

            const running = scene.applyAnims(f, f.time_us + (host.nowUs() - f.wall_us));
            if (ser != 0) scene.applyDrags(f, px, py);
            r.last_draw_us = host.nowUs();
            r.draw(f);

            r.mutex.lockUncancelable(r.io);
            r.drawing = null;
            r.last = f;
            r.held_ptr = ser;
            r.held_running = running;
            if (keeps(f, running)) {
                r.held = f;
            } else r.pushFree(f);
            // Keep the frame that was drawn last out of the free list until the next draw ends.
            r.cond.broadcast(r.io);
            r.mutex.unlock(r.io);
        }
    }
};
