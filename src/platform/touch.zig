//! From raw touches to pointer events. A touch panel has no hover, so a
//! touch gives a `motion` to the point, then a press of button 1; a move
//! gives a `motion`; the end gives a release and a `leave`. The panel
//! gives 0..1 values, and the rotation maps them to logical pixels. With
//! a debounce time, the end of a touch waits, and a new touch in that time
//! continues the same touch. The numbers of the scroll lessons (for the
//! first widget that scrolls, in Stage 2): a move of more than 12 pixels
//! is a scroll and not a tap, and a fling starts at 250 pixels in each
//! second and slows with a time constant of 0.35 seconds.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const geom = @import("../base/geom.zig");
const event = @import("../base/event.zig");
const plat = @import("platform.zig");
const Event = event.Event;
const Window = plat.Window;

pub const Rotation = enum(u16) { r0 = 0, r90 = 90, r180 = 180, r270 = 270 };

pub const Raw = struct { kind: enum { down, move, up }, x: f32, y: f32, time_ms: u64 };

pub const TouchOptions = struct {
    rotation: Rotation = .r0,
    /// A finger must be off the panel this long before the touch ends.
    debounce_ms: u32 = 0,
    tap_slop: f32 = 12,
};

pub const Touch = struct {
    opts: TouchOptions,
    size: geom.Size,
    down: bool = false,
    /// Set when `up` waits for the debounce time.
    /// The time is on a 64-bit clock, so it does not wrap.
    pending_up_ms: ?u64 = null,
    last: [2]f32 = .{ 0, 0 },

    pub fn init(opts: TouchOptions, size: geom.Size) Touch {
        return .{ .opts = opts, .size = size };
    }

    /// Maps a point of the panel (0..1) to logical pixels of the upright window.
    pub fn map(t: *const Touch, x: f32, y: f32) [2]f32 {
        const w: f32 = @floatFromInt(t.size.w);
        const h: f32 = @floatFromInt(t.size.h);
        return switch (t.opts.rotation) {
            .r0 => .{ x * w, y * h },
            .r180 => .{ (1 - x) * w, (1 - y) * h },
            // The panel is turned 90 degrees clockwise: panel x is the upright y.
            .r90 => .{ y * w, (1 - x) * h },
            .r270 => .{ (1 - y) * w, x * h },
        };
    }

    /// Turns one raw touch into backend events (motion and button 1).
    pub fn feed(t: *Touch, raw: Raw, out: *std.ArrayListUnmanaged(Event), gpa: std.mem.Allocator, window: *Window) !void {
        const p = t.map(raw.x, raw.y);
        switch (raw.kind) {
            .down => {
                if (t.pending_up_ms != null) {
                    // The finger came back in the debounce time: the same touch goes on.
                    t.pending_up_ms = null;
                    try t.motion(out, gpa, window, p, raw.time_ms);
                    return;
                }
                t.down = true;
                try t.motion(out, gpa, window, p, raw.time_ms);
                try out.append(gpa, .{ .button = .{ .window = window, .button = 1, .pressed = true, .x = p[0], .y = p[1], .mods = .{}, .time_ms = @truncate(raw.time_ms) } });
            },
            .move => {
                if (!t.down) return;
                // Keep the newest move: a move at the end of the list replaces the one before it.
                if (out.items.len > 0) {
                    const last = out.items[out.items.len - 1];
                    if (last == .motion and last.motion.window == window and last.motion.mods.button1) {
                        out.items.len -= 1;
                    }
                }
                try t.motion(out, gpa, window, p, raw.time_ms);
            },
            .up => {
                if (!t.down) return;
                t.last = p;
                if (t.opts.debounce_ms > 0) {
                    t.pending_up_ms = raw.time_ms + t.opts.debounce_ms;
                    return;
                }
                try t.release(out, gpa, window, raw.time_ms);
            },
        }
    }

    fn motion(t: *Touch, out: *std.ArrayListUnmanaged(Event), gpa: std.mem.Allocator, window: *Window, p: [2]f32, ms: u64) !void {
        t.last = p;
        try out.append(gpa, .{ .motion = .{ .window = window, .x = p[0], .y = p[1], .mods = .{ .button1 = t.down }, .time_ms = @truncate(ms) } });
        window.feedPointer(p[0], p[1]);
    }

    fn release(t: *Touch, out: *std.ArrayListUnmanaged(Event), gpa: std.mem.Allocator, window: *Window, ms: u64) !void {
        t.down = false;
        t.pending_up_ms = null;
        try out.append(gpa, .{ .button = .{ .window = window, .button = 1, .pressed = false, .x = t.last[0], .y = t.last[1], .mods = .{ .button1 = true }, .time_ms = @truncate(ms) } });
        try out.append(gpa, .{ .leave = .{ .window = window } });
    }

    /// Ends a touch whose debounce time passed. Call it with the time.
    pub fn tick(t: *Touch, now_ms: u64, out: *std.ArrayListUnmanaged(Event), gpa: std.mem.Allocator, window: *Window) !void {
        const due = t.pending_up_ms orelse return;
        if (now_ms >= due) try t.release(out, gpa, window, now_ms);
    }

    /// The time of the next debounce, for the wait of the backend.
    pub fn nextDue(t: *const Touch) ?u64 {
        return t.pending_up_ms;
    }
};

const testing = std.testing;

fn drain(list: *std.ArrayListUnmanaged(Event)) void {
    list.clearRetainingCapacity();
}

test "touch: down, move, up give the pointer events" {
    var win: Window = .{ .size = .{ .w = 100, .h = 50 } };
    var t = Touch.init(.{}, win.size);
    var out: std.ArrayListUnmanaged(Event) = .empty;
    defer out.deinit(testing.allocator);
    try t.feed(.{ .kind = .down, .x = 0.5, .y = 0.5, .time_ms = 0 }, &out, testing.allocator, &win);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqual(@as(f32, 50), out.items[0].motion.x);
    try testing.expectEqual(@as(f32, 25), out.items[0].motion.y);
    try testing.expect(out.items[1].button.pressed);
    drain(&out);
    try t.feed(.{ .kind = .move, .x = 0.6, .y = 0.5, .time_ms = 5 }, &out, testing.allocator, &win);
    try t.feed(.{ .kind = .move, .x = 0.7, .y = 0.5, .time_ms = 6 }, &out, testing.allocator, &win);
    // Only the newest move stays.
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(@as(f32, 70), out.items[0].motion.x);
    drain(&out);
    try t.feed(.{ .kind = .up, .x = 0.7, .y = 0.5, .time_ms = 10 }, &out, testing.allocator, &win);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expect(!out.items[0].button.pressed);
    try testing.expect(out.items[1] == .leave);
}

test "touch: the rotation maps the corner" {
    const win_size: geom.Size = .{ .w = 480, .h = 800 };
    const t90 = Touch.init(.{ .rotation = .r90 }, win_size);
    // The panel corner (0, 0) goes to the upright (0, 800) for r90.
    const p = t90.map(0, 0);
    try testing.expectEqual(@as(f32, 0), p[0]);
    try testing.expectEqual(@as(f32, 800), p[1]);
    const t270 = Touch.init(.{ .rotation = .r270 }, win_size);
    const q = t270.map(0, 0);
    try testing.expectEqual(@as(f32, 480), q[0]);
    try testing.expectEqual(@as(f32, 0), q[1]);
}

test "touch: the debounce time keeps the touch" {
    var win: Window = .{ .size = .{ .w = 100, .h = 50 } };
    var t = Touch.init(.{ .debounce_ms = 80 }, win.size);
    var out: std.ArrayListUnmanaged(Event) = .empty;
    defer out.deinit(testing.allocator);
    try t.feed(.{ .kind = .down, .x = 0.5, .y = 0.5, .time_ms = 0 }, &out, testing.allocator, &win);
    drain(&out);
    try t.feed(.{ .kind = .up, .x = 0.5, .y = 0.5, .time_ms = 100 }, &out, testing.allocator, &win);
    try t.feed(.{ .kind = .down, .x = 0.5, .y = 0.5, .time_ms = 120 }, &out, testing.allocator, &win);
    for (out.items) |e| try testing.expect(!(e == .button));
    try t.tick(300, &out, testing.allocator, &win);
    // The finger came back, so the touch goes on: one motion, and no release.
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(out.items[0] == .motion);
    drain(&out);
    // The end of a touch: up at 400 and a tick at 481 give the release.
    try t.feed(.{ .kind = .up, .x = 0.5, .y = 0.5, .time_ms = 400 }, &out, testing.allocator, &win);
    try testing.expectEqual(@as(usize, 0), out.items.len);
    try t.tick(481, &out, testing.allocator, &win);
    try testing.expect(out.items[0] == .button);
}
