//! `ztk::animate` and `ztk::clock`. An option animation moves one or more
//! options of a widget from their values at the start to the given end
//! values. Each frame computes the eased progress from the time of the
//! frame and writes the value into the option, as `configure` does, with
//! no Tcl script. A color moves in sRGB space. A screen distance or an
//! integer moves as a rounded number, and any other option with a number
//! value moves as a number. A new animation of the same option of the
//! same widget starts from the shown value and takes the option out of
//! the old animation. The `-command` script runs as an idle callback
//! after the frame that showed the end value.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const geom = @import("geom.zig");
const easing = @import("easing.zig");
const options = @import("options.zig");
const widget_mod = @import("widget.zig");
const anim = @import("anim.zig");
const App = @import("app.zig").App;
const Widget = widget_mod.Widget;
const Value = ztcl.Value;

const Kind = enum { color, int, number };

const Track = struct {
    spec: usize,
    kind: Kind,
    from: [4]f64,
    to: [4]f64,
};

pub const OptAnim = struct {
    id: u32,
    widget: *Widget,
    tracks: std.ArrayListUnmanaged(Track) = .empty,
    start_us: i64,
    duration_ms: u32,
    delay_ms: u32,
    timing: easing.Timing,
    /// The count of runs. 0 is no end.
    repeat: u32,
    /// The time of `pause`, or null.
    paused_at: ?i64 = null,
    /// Owned. Empty for no command.
    command: []u8 = &.{},
    done: bool = false,

    fn deinit(a: *OptAnim, gpa: std.mem.Allocator) void {
        a.tracks.deinit(gpa);
        gpa.free(a.command);
    }
};

pub const State = struct {
    list: std.ArrayListUnmanaged(OptAnim) = .empty,
    next_id: u32 = 1,

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        for (s.list.items) |*a| a.deinit(gpa);
        s.list.deinit(gpa);
    }
};

fn valueOf(w: *Widget, it: *ztcl.Interp, spec: usize, kind: Kind) ztcl.Error![4]f64 {
    const text = try options.textOf(w, it, spec);
    return parseAs(text, kind) orelse .{ 0, 0, 0, 0 };
}

fn parseAs(text: []const u8, kind: Kind) ?[4]f64 {
    switch (kind) {
        .color => {
            const c = geom.Color.parseTk(text) orelse return null;
            return .{ @floatFromInt(c.r), @floatFromInt(c.g), @floatFromInt(c.b), @floatFromInt(c.a) };
        },
        .int, .number => {
            const v = std.fmt.parseFloat(f64, std.mem.trim(u8, text, " ")) catch return null;
            if (std.math.isNan(v) or std.math.isInf(v)) return null;
            return .{ v, 0, 0, 0 };
        },
    }
}

fn kindOf(t: options.Type) Kind {
    return switch (t) {
        .color => .color,
        .pixels, .int => .int,
        else => .number,
    };
}

/// The text of a value of a track at a progress.
fn textAt(a: std.mem.Allocator, tr: *const Track, p: f32) ![]const u8 {
    var v: [4]f64 = undefined;
    for (&v, tr.from, tr.to) |*o, f, t| o.* = f + (t - f) * p;
    switch (tr.kind) {
        .color => {
            const c: geom.Color = .{ .r = byte(v[0]), .g = byte(v[1]), .b = byte(v[2]), .a = byte(v[3]) };
            var buf: [7]u8 = undefined;
            return a.dupe(u8, c.formatTk(&buf));
        },
        .int => return std.fmt.allocPrint(a, "{d}", .{@as(i64, @intFromFloat(@round(std.math.clamp(v[0], -1e9, 1e9))))}),
        .number => return std.fmt.allocPrint(a, "{d}", .{v[0]}),
    }
}

fn byte(v: f64) u8 {
    return @intFromFloat(std.math.clamp(@round(v), 0, 255));
}

fn parseTiming(it: *ztcl.Interp, v: Value) ztcl.Error!easing.Timing {
    const words = try it.list(v);
    if (words.len == 0) return it.fail("bad easing \"\": must be linear, ease, ease-in, ease-out, ease-in-out, cubic-bezier, steps, or spring", .{});
    const name = try it.str(words[0]);
    const nums = struct {
        fn get(it2: *ztcl.Interp, ws: []const Value, out: []f32) ztcl.Error!usize {
            var n: usize = 0;
            for (ws) |x| {
                if (n == out.len) break;
                const t = try it2.str(x);
                out[n] = std.fmt.parseFloat(f32, t) catch return it2.fail("expected floating-point number but got \"{s}\"", .{t});
                n += 1;
            }
            return n;
        }
    }.get;
    if (std.mem.eql(u8, name, "linear")) return .linear;
    if (std.mem.eql(u8, name, "ease")) return easing.Timing.ease;
    if (std.mem.eql(u8, name, "ease-in")) return easing.Timing.ease_in;
    if (std.mem.eql(u8, name, "ease-out")) return easing.Timing.ease_out;
    if (std.mem.eql(u8, name, "ease-in-out")) return easing.Timing.ease_in_out;
    if (std.mem.eql(u8, name, "cubic-bezier")) {
        var p: [4]f32 = undefined;
        if (try nums(it, words[1..], &p) != 4) return it.fail("cubic-bezier needs 4 numbers", .{});
        return .{ .cubic = .{ std.math.clamp(p[0], 0, 1), p[1], std.math.clamp(p[2], 0, 1), p[3] } };
    }
    if (std.mem.eql(u8, name, "spring")) {
        var p = [3]f32{ 100, 10, 1 };
        _ = try nums(it, words[1..], &p);
        for (&p) |*x| x.* = std.math.clamp(x.*, 0.01, 100000);
        return .{ .spring = p };
    }
    if (std.mem.eql(u8, name, "steps")) {
        if (words.len < 2) return it.fail("steps needs a count", .{});
        var p: [1]f32 = undefined;
        _ = try nums(it, words[1..2], &p);
        var pos: easing.StepPos = .jump_end;
        if (words.len > 2) {
            const w = try it.str(words[2]);
            pos = if (std.mem.eql(u8, w, "jump-start") or std.mem.eql(u8, w, "start")) .jump_start else if (std.mem.eql(u8, w, "jump-none")) .jump_none else if (std.mem.eql(u8, w, "jump-both")) .jump_both else .jump_end;
        }
        return .{ .steps = .{ .n = @intFromFloat(std.math.clamp(p[0], 1, 1000)), .pos = pos } };
    }
    return it.fail("bad easing \"{s}\": must be linear, ease, ease-in, ease-out, ease-in-out, cubic-bezier, steps, or spring", .{name});
}

fn findId(app: *App, it: *ztcl.Interp, v: Value) ztcl.Error!usize {
    const text = try it.str(v);
    if (std.mem.startsWith(u8, text, "anim#")) {
        if (std.fmt.parseInt(u32, text[5..], 10)) |id| {
            for (app.opt_anims.list.items, 0..) |a, i| if (a.id == id) return i;
        } else |_| {}
    }
    return it.fail("animation \"{s}\" doesn't exist", .{text});
}

fn lenUs(a: *const OptAnim) i64 {
    const d: i64 = switch (a.timing) {
        .spring => |p| @intFromFloat(easing.springDuration(p) * 1_000_000),
        else => @as(i64, a.duration_ms) * 1000,
    };
    return @max(d, 1);
}

/// `ztk::animate target ?-option value ...?` and its subcommands.
pub fn cmdAnimate(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    app.enter();
    defer app.leave();
    const usage = "ztk::animate target ?-option value ...? ?-duration ms? ?-easing name? ?-delay ms? ?-repeat count? ?-command script?";
    if (argv.len < 2) return it.wrongArgs(usage);
    const first = try it.str(argv[1]);
    const now = app.platform.nowUs();
    if (first.len > 0 and first[0] != '.') {
        if (std.mem.eql(u8, first, "cancel") or std.mem.eql(u8, first, "pause") or std.mem.eql(u8, first, "resume")) {
            if (argv.len != 3) return it.fail("wrong # args: should be \"ztk::animate {s} id\"", .{first});
            const i = try findId(app, it, argv[2]);
            const a = &app.opt_anims.list.items[i];
            switch (first[0]) {
                'c' => {
                    a.deinit(app.gpa);
                    _ = app.opt_anims.list.orderedRemove(i);
                },
                'p' => if (a.paused_at == null) {
                    a.paused_at = now;
                },
                else => if (a.paused_at) |p| {
                    a.start_us += now - p;
                    a.paused_at = null;
                    app.requestFrame();
                },
            }
            return Value.empty;
        }
        if (std.mem.eql(u8, first, "info")) {
            const al = it.alloc();
            if (argv.len == 2) {
                var out: std.ArrayListUnmanaged(Value) = .empty;
                for (app.opt_anims.list.items) |a| try out.append(al, .{ .str = try std.fmt.allocPrint(al, "anim#{d}", .{a.id}) });
                return ztcl.value.wrapList(al, try out.toOwnedSlice(al));
            }
            if (argv.len != 3) return it.wrongArgs("ztk::animate info ?id?");
            const a = &app.opt_anims.list.items[try findId(app, it, argv[2])];
            const state = if (a.paused_at != null) "paused" else if (now - a.start_us < @as(i64, a.delay_ms) * 1000) "waiting" else "running";
            const elapsed = (a.paused_at orelse now) - a.start_us - @as(i64, a.delay_ms) * 1000;
            const items = [_]Value{
                .{ .str = "-target" },  .{ .str = try al.dupe(u8, a.widget.path) },
                .{ .str = "-state" },   .{ .str = state },
                .{ .str = "-elapsed" }, .{ .int = @divTrunc(@max(elapsed, 0), 1000) },
            };
            return ztcl.value.newList(al, &items);
        }
        if (std.mem.eql(u8, first, "reduce")) {
            if (argv.len > 3) return it.wrongArgs("ztk::animate reduce ?boolean?");
            if (argv.len == 3) {
                const t = try it.str(argv[2]);
                app.reduce_motion = options.parseBool(t) orelse return it.fail("expected boolean value but got \"{s}\"", .{t});
                app.requestFrame();
            }
            return .{ .int = @intFromBool(anim.reduced(app)) };
        }
        return it.fail("bad option \"{s}\": must be a window path, cancel, info, pause, reduce, or resume", .{first});
    }
    const w = app.find(first) orelse return it.fail("bad window path name \"{s}\"", .{first});
    var a: OptAnim = .{ .id = 0, .widget = w, .start_us = now, .duration_ms = 300, .delay_ms = 0, .timing = easing.Timing.ease, .repeat = 1 };
    var tracks: std.ArrayListUnmanaged(Track) = .empty;
    defer tracks.deinit(app.gpa);
    var command: []const u8 = "";
    var k: usize = 2;
    while (k < argv.len) : (k += 2) {
        const name = try it.str(argv[k]);
        if (k + 1 >= argv.len) return it.fail("value for \"{s}\" missing", .{name});
        const v = argv[k + 1];
        if (std.mem.eql(u8, name, "-duration") or std.mem.eql(u8, name, "-delay") or std.mem.eql(u8, name, "-repeat")) {
            const n = try it.int(v);
            if (n < 0) return it.fail("expected a count of 0 or more but got \"{s}\"", .{try it.str(v)});
            const c: u32 = @intCast(@min(n, 3_600_000));
            if (std.mem.eql(u8, name, "-duration")) a.duration_ms = c else if (std.mem.eql(u8, name, "-delay")) a.delay_ms = c else a.repeat = c;
        } else if (std.mem.eql(u8, name, "-easing")) {
            a.timing = try parseTiming(it, v);
        } else if (std.mem.eql(u8, name, "-command")) {
            command = try it.str(v);
        } else {
            const idx = try options.find(it, w.class.specs, name);
            var spec = idx;
            if (w.class.specs[idx].type == .synonym) spec = try options.find(it, w.class.specs, w.class.specs[idx].target);
            const kind = kindOf(w.class.specs[spec].type);
            const text = try it.str(v);
            const to = parseAs(text, kind) orelse return it.fail("can't animate {s} to \"{s}\"", .{ w.class.specs[spec].name, text });
            try tracks.append(app.gpa, .{ .spec = spec, .kind = kind, .from = try valueOf(w, it, spec, kind), .to = to });
        }
    }
    if (tracks.items.len == 0) return it.fail("no option to animate", .{});
    // A new animation of an option takes it out of the old animation.
    var i: usize = 0;
    while (i < app.opt_anims.list.items.len) {
        const o = &app.opt_anims.list.items[i];
        if (o.widget == w) {
            var j: usize = 0;
            while (j < o.tracks.items.len) {
                var hit = false;
                for (tracks.items) |t| if (t.spec == o.tracks.items[j].spec) {
                    hit = true;
                };
                if (hit) _ = o.tracks.swapRemove(j) else j += 1;
            }
            if (o.tracks.items.len == 0) {
                o.deinit(app.gpa);
                _ = app.opt_anims.list.orderedRemove(i);
                continue;
            }
        }
        i += 1;
    }
    a.id = app.opt_anims.next_id;
    app.opt_anims.next_id += 1;
    a.command = try app.gpa.dupe(u8, command);
    a.tracks = tracks;
    tracks = .empty;
    app.opt_anims.list.append(app.gpa, a) catch |e| {
        a.deinit(app.gpa);
        return e;
    };
    app.requestFrame();
    return .{ .str = try std.fmt.allocPrint(it.alloc(), "anim#{d}", .{a.id}) };
}

/// Writes the values of each option animation for a time. Returns true
/// when one still runs.
pub fn tick(app: *App, now_us: i64) bool {
    const it = app.it;
    var running = false;
    var i: usize = 0;
    while (i < app.opt_anims.list.items.len) {
        const a = &app.opt_anims.list.items[i];
        if (!a.widget.alive()) {
            a.deinit(app.gpa);
            _ = app.opt_anims.list.orderedRemove(i);
            continue;
        }
        if (a.paused_at != null) {
            i += 1;
            continue;
        }
        const since = now_us - a.start_us - @as(i64, a.delay_ms) * 1000;
        const len = lenUs(a);
        var p: f32 = 0;
        var done = false;
        if (anim.reduced(app)) {
            p = 1;
            done = true;
        } else if (since >= 0) {
            const runs = @divFloor(since, len);
            if (a.repeat != 0 and runs >= a.repeat) {
                p = 1;
                done = true;
            } else {
                p = a.timing.eval(@as(f32, @floatFromInt(since - runs * len)) / @as(f32, @floatFromInt(len)));
            }
        }
        if (since >= 0 or done) {
            for (a.tracks.items) |*tr| {
                const text = textAt(it.alloc(), tr, p) catch continue;
                // The same value at the same time changes nothing, so no frame follows.
                const cur = options.textOf(a.widget, it, tr.spec) catch continue;
                if (std.mem.eql(u8, cur, text)) continue;
                const pair = [_]Value{ .{ .str = a.widget.class.specs[tr.spec].name }, .{ .str = text } };
                options.apply(a.widget, it, &pair) catch {};
                if (!a.widget.alive()) break;
            }
        }
        if (done) {
            if (a.command.len > 0) _ = app.loop.addIdle(a.command) catch {};
            a.deinit(app.gpa);
            _ = app.opt_anims.list.orderedRemove(i);
            continue;
        }
        running = true;
        i += 1;
    }
    return running;
}

/// `ztk::clock get` and `ztk::clock set ms`. Only the headless backend can set the clock.
pub fn cmdClock(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    if (argv.len < 2) return it.wrongArgs("ztk::clock get|set ?ms?");
    const sub = try it.str(argv[1]);
    if (std.mem.eql(u8, sub, "get") and argv.len == 2) return .{ .int = @divTrunc(app.platform.nowUs(), 1000) };
    if (std.mem.eql(u8, sub, "set") and argv.len == 3) {
        const f = app.platform.vtable.setTimeUs orelse return it.fail("ztk::clock set needs the headless backend", .{});
        const ms = try it.int(argv[2]);
        f(app.platform.ptr, std.math.clamp(ms, 0, 1 << 40) * 1000);
        app.requestFrame();
        return Value.empty;
    }
    return it.wrongArgs("ztk::clock get|set ?ms?");
}
