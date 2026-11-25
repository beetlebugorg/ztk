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
    drawn: std.atomic.Value(u64) = .init(0),
    replaced: std.atomic.Value(u64) = .init(0),
    errors: std.atomic.Value(u64) = .init(0),

    pub fn init(gpa: std.mem.Allocator, io: std.Io, mode: Mode, target: Target) !*RenderThread {
        const r = try gpa.create(RenderThread);
        r.* = .{ .gpa = gpa, .mode = mode, .target = target, .back_frame = undefined, .io = io };
        r.back_frame = &r.frames[0];
        r.free[0] = &r.frames[1];
        r.free[1] = &r.frames[2];
        if (mode == .threaded) r.thread = try std.Thread.spawn(.{}, run, .{r});
        return r;
    }

    /// Stops the thread after its current frame and joins it.
    pub fn deinit(r: *RenderThread) void {
        if (r.thread) |t| {
            r.mutex.lockUncancelable(r.io);
            r.quit = true;
            r.cond.broadcast(r.io);
            r.mutex.unlock(r.io);
            t.join();
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
            _ = scene.applyAnims(f, f.time_us);
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

    fn run(r: *RenderThread) void {
        while (true) {
            r.mutex.lockUncancelable(r.io);
            while (r.waiting == null and !r.quit and r.held == null) r.cond.waitUncancelable(r.io, &r.mutex);
            if (r.quit) {
                if (r.held) |h| r.pushFree(h);
                r.held = null;
                if (r.waiting == null) {
                    r.mutex.unlock(r.io);
                    return;
                }
            }
            if (r.waiting == null) {
                // A transition runs and no new frame came: draw the held frame again
                // for the time that passed, so a busy UI thread does not stop it.
                // `flush` does not wait for this draw: it waits only for submitted frames.
                const h = r.held.?;
                r.mutex.unlock(r.io);
                host.sleepUs(anim_step_us);
                const running = scene.applyAnims(h, h.time_us + (host.nowUs() - h.wall_us));
                r.draw(h);
                r.mutex.lockUncancelable(r.io);
                r.last = h;
                if (!running) {
                    r.held = null;
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
            // A `submit` can wait for the old frame to leave the slot.
            r.cond.broadcast(r.io);
            r.mutex.unlock(r.io);

            const running = scene.applyAnims(f, f.time_us + (host.nowUs() - f.wall_us));
            r.draw(f);

            r.mutex.lockUncancelable(r.io);
            r.drawing = null;
            r.last = f;
            // Keep the frame that was drawn last out of the free list until the next draw ends.
            r.cond.broadcast(r.io);
            r.mutex.unlock(r.io);
            if (running) {
                r.mutex.lockUncancelable(r.io);
                r.held = f;
                r.mutex.unlock(r.io);
            } else r.recycleLater(f);
        }
    }

    /// The frame goes back to the free list. `last` still points at it, and the
    /// next `submit` can pop it, so `lastFrame` is valid only after `flush` and
    /// before the next submit.
    fn recycleLater(r: *RenderThread, f: *Frame) void {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        r.pushFree(f);
    }
};
