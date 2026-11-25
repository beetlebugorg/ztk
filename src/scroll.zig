//! The scroll protocol of Tk, shared by each widget that scrolls: the
//! subcommands `xview` and `yview` (`moveto fraction`, `scroll number
//! units|pages`), the fractions for `-xscrollcommand` and
//! `-yscrollcommand`, the smooth scroll, and the momentum.
//!
//! A `View` keeps the offset of one axis in logical pixels. `pos` is the
//! offset that the view goes to, and `xview` and the scroll command give
//! its fractions at once. The paint shows `shown`, which eases from the
//! offset at the start of a move to `pos`. The paint notes the move with
//! `App.notePartMove`, so the render thread moves the view while the UI
//! thread is busy. A step with a fraction of a unit (a touchpad or a wheel
//! with fine steps) adds momentum: the view glides on by the speed of the
//! last steps and slows down.
//!
//! A drag of a scrollbar thumb sets `App.scroll_link`. The view that the
//! thumb scrolls jumps with no ease during the drag, and its paint adds
//! its quads to the frame as a drag (`scene.FrameDrag`) with a negative
//! gain, so the render thread moves the content against the thumb with
//! the pointer.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const widget = @import("widget.zig");
const options = @import("options.zig");
const anim = @import("anim.zig");
const easing = @import("easing.zig");
const scene = @import("scene.zig");
const App = @import("app.zig").App;
const Widget = widget.Widget;
const Value = ztcl.Value;

/// The time of a move by `moveto` or by a wheel step.
pub const step_us: i64 = 160_000;
/// The time of a glide after the steps of a touchpad.
pub const glide_us: i64 = 450_000;
/// The glide is the speed times this time, in seconds.
const glide_s: f64 = 0.18;

/// A drag of a scrollbar thumb. `base` is the pointer position on the
/// axis in logical pixels of the window when the UI thread last moved the
/// view, and the pointer can move from `lo` to `hi` from it before the
/// thumb is at an end. `travel` is the length that the thumb moves on.
pub const Link = struct {
    target: *Widget,
    axis: u1,
    base: f32,
    lo: f32,
    hi: f32,
    travel: f32,
};

pub const View = struct {
    pos: f64 = 0,
    from: f64 = 0,
    start_us: i64 = 0,
    len_us: i64 = step_us,
    moving: bool = false,
    /// The momentum: the time of the last fine step, the speed in pixels
    /// in each second, and the glide that `pos` has after the steps.
    last_us: i64 = -1,
    speed: f64 = 0,
    glide: f64 = 0,
    /// The length of the content and of the window on it.
    total: f64 = 0,
    visible: f64 = 0,
    /// The fractions that the scroll command got last.
    reported: [2]f64 = .{ -1, -1 },

    pub fn maxPos(v: *const View) f64 {
        return @max(v.total - v.visible, 0);
    }

    pub fn clampPos(v: *const View, p: f64) f64 {
        return std.math.clamp(p, 0, v.maxPos());
    }

    /// The first and the last fraction of the content in the window.
    pub fn fractions(v: *const View) [2]f64 {
        if (v.total <= 0 or v.visible >= v.total) return .{ 0, 1 };
        const first = std.math.clamp(v.pos / v.total, 0, 1);
        const last = std.math.clamp((v.pos + v.visible) / v.total, 0, 1);
        return .{ first, last };
    }

    /// Sets the sizes. The offset stays within the content.
    pub fn setSize(v: *View, total: f64, visible: f64) void {
        v.total = @max(total, 0);
        v.visible = @max(visible, 0);
        const p = v.clampPos(v.pos);
        if (p != v.pos) {
            v.pos = p;
            v.moving = false;
        }
    }

    /// The offset that the paint shows now.
    pub fn shown(v: *View, w: *Widget) f64 {
        if (!v.moving) return v.pos;
        const app = w.app;
        const since = app.platform.nowUs() - v.start_us;
        if (since >= v.len_us) {
            v.moving = false;
            return v.pos;
        }
        if (app.part_end) return v.pos;
        app.anim_more = true;
        const timing = easing.Timing.ease_out;
        const p = timing.eval(@as(f32, @floatFromInt(@max(since, 0))) / @as(f32, @floatFromInt(v.len_us)));
        app.notePartMove(v.start_us, .{ .duration_ms = @intCast(@divTrunc(v.len_us, 1000)), .timing = timing }, p);
        return v.from + (v.pos - v.from) * p;
    }

    /// Moves the view to `p` at once.
    pub fn jump(v: *View, p: f64) void {
        v.pos = v.clampPos(p);
        v.moving = false;
        v.glide = 0;
    }

    /// Moves the view to `p` with an ease from the shown offset, in `len_us`.
    pub fn moveTo(v: *View, w: *Widget, p: f64, len_us: i64) void {
        const to = v.clampPos(p);
        if (anim.reduced(w.app)) return v.jump(to);
        const from = v.shown(w);
        if (to == v.pos and v.moving) return;
        if (to == from) return v.jump(to);
        v.from = from;
        v.start_us = w.app.platform.nowUs();
        v.len_us = len_us;
        v.moving = true;
        v.pos = to;
    }

    /// Scrolls by `d` pixels. A fine step adds momentum.
    pub fn scrollBy(v: *View, w: *Widget, d: f64, fine: bool) void {
        const now = w.app.platform.nowUs();
        _ = v.shown(w);
        // A fine step during a glide counts from the end of the steps.
        const base = if (v.moving and fine) v.pos - v.glide else v.pos;
        v.glide = 0;
        if (!fine) {
            v.last_us = -1;
            v.speed = 0;
            return v.moveTo(w, base + d, step_us);
        }
        const dt = now - v.last_us;
        const inst = if (v.last_us >= 0 and dt > 0 and dt < 100_000) d / (@as(f64, @floatFromInt(dt)) / 1e6) else d / 0.016;
        v.speed = if (v.last_us >= 0 and dt < 100_000) 0.5 * v.speed + 0.5 * inst else inst;
        v.last_us = now;
        const to = v.clampPos(base + d);
        var g = v.speed * glide_s;
        const lim = @max(v.visible, 1);
        g = std.math.clamp(g, -lim, lim);
        const end = v.clampPos(to + g);
        v.moveTo(w, end, glide_us);
        v.glide = end - to;
    }
};

/// The pixels of one unit and of one page of a view.
pub const Steps = struct { unit: f64, page: f64 };

/// `path xview|yview ?args?` for a widget with a view. An index form
/// (`xview index`) is for the caller, and the function
/// returns null for it. Returns the fractions for no argument.
pub fn command(w: *Widget, it: *ztcl.Interp, argv: []const Value, v: *View, steps: Steps, index_form: bool) ztcl.Error!?Value {
    const a = it.alloc();
    if (argv.len == 2) return try fractionsValue(a, v.fractions());
    const op = try it.str(argv[2]);
    if (std.mem.eql(u8, op, "moveto")) {
        if (argv.len != 4) {
            if (index_form and argv.len == 3) return null;
            return it.fail("wrong # args: should be \"{s} {s} moveto fraction\"", .{ w.path, try it.str(argv[1]) });
        }
        const t = try it.str(argv[3]);
        const f = std.fmt.parseFloat(f64, std.mem.trim(u8, t, " ")) catch return it.fail("expected floating-point number but got \"{s}\"", .{t});
        const p = std.math.clamp(f, 0, 1) * v.total;
        if (dragged(w)) v.jump(p) else v.moveTo(w, p, step_us);
        changed(w);
        return Value.empty;
    }
    if (std.mem.eql(u8, op, "scroll")) {
        if (argv.len != 5) return it.fail("wrong # args: should be \"{s} {s} scroll number units|pages\"", .{ w.path, try it.str(argv[1]) });
        const t = try it.str(argv[3]);
        // ztk accepts a fraction of a unit, for a touchpad. Tk 8.6 accepts an integer.
        const n = std.fmt.parseFloat(f64, std.mem.trim(u8, t, " ")) catch return it.fail("expected integer but got \"{s}\"", .{t});
        if (!std.math.isFinite(n)) return it.fail("expected integer but got \"{s}\"", .{t});
        const what = try it.str(argv[4]);
        const units = what.len > 0 and std.mem.startsWith(u8, "units", what);
        const pages = what.len > 0 and std.mem.startsWith(u8, "pages", what);
        if (!units and !pages) return it.fail("bad argument \"{s}\": must be units or pages", .{what});
        const d = if (units) n * steps.unit else n * steps.page;
        v.scrollBy(w, d, n != @trunc(n));
        changed(w);
        return Value.empty;
    }
    if (index_form and argv.len == 3) return null;
    return it.fail("unknown option \"{s}\": must be moveto or scroll", .{op});
}

fn changed(w: *Widget) void {
    w.invalidate(.{ .style = false, .measure = false, .layout = false, .paint = true });
}

/// True while a scrollbar thumb drags the view of `w`.
pub fn dragged(w: *const Widget) bool {
    const l = w.app.scroll_link orelse return false;
    return l.target == w;
}

pub fn fractionsValue(a: std.mem.Allocator, f: [2]f64) !Value {
    return .{ .str = try std.fmt.allocPrint(a, "{s} {s}", .{ try options.formatDouble(a, f[0]), try options.formatDouble(a, f[1]) }) };
}

/// Gives the scroll command of the option `opt` the fractions of the
/// view when they changed, as an idle callback, as Tk does.
pub fn report(w: *Widget, v: *View, comptime opt: []const u8) void {
    const f = v.fractions();
    if (f[0] == v.reported[0] and f[1] == v.reported[1]) return;
    v.reported = f;
    const slot = options.get(w, opt);
    if (!slot.set or slot.text.len == 0) return;
    const cmd = slot.text;
    const a = w.app.it.alloc();
    const first = options.formatDouble(a, f[0]) catch return;
    const last = options.formatDouble(a, f[1]) catch return;
    const script = std.fmt.allocPrint(w.app.gpa, "{s} {s} {s}", .{ cmd, first, last }) catch return;
    defer w.app.gpa.free(script);
    _ = w.app.loop.addIdle(script) catch {};
}

/// In the paint of `w`: when a thumb drags the view of `w` on `axis`,
/// adds the quads from `first` to the end of the scene to the frame as a
/// drag, so the render thread moves them against the thumb.
pub fn paintDrag(w: *Widget, b: *scene.Builder, v: *const View, first: usize, axis: u1) !void {
    const l = w.app.scroll_link orelse return;
    if (l.target != w or l.axis != axis or l.travel <= 0) return;
    const gain: f32 = @floatCast(-v.maxPos() / l.travel);
    try w.app.addDragGain(b, first, axis, false, l.base, l.lo, l.hi, gain);
}

/// Drops the link of a widget that goes away.
pub fn forget(w: *const Widget) void {
    if (w.app.scroll_link) |l| if (l.target == w) {
        w.app.scroll_link = null;
    };
}
