//! Timing functions for transitions and animations, from the CSS Easing
//! specification, and a spring. A cubic Bezier curve solves x(s) = t for
//! the curve parameter s with Newton steps and a bisection fallback, then
//! gives y(s). `steps` follows the jump positions of the specification.
//! A spring is a damped harmonic oscillator that moves from 0 to 1 with
//! no start speed. Its value at a time comes from the closed form of the
//! motion (under-damped, critically damped, or over-damped). A spring has
//! its own duration: the time after which the distance from 1 stays under
//! 0.001, found by a walk in steps of 1 ms.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

pub const StepPos = enum { jump_start, jump_end, jump_none, jump_both };

pub const Timing = union(enum) {
    linear,
    cubic: [4]f32,
    steps: struct { n: u16, pos: StepPos },
    /// Stiffness, damping, and mass.
    spring: [3]f32,

    pub const ease: Timing = .{ .cubic = .{ 0.25, 0.1, 0.25, 1 } };
    pub const ease_in: Timing = .{ .cubic = .{ 0.42, 0, 1, 1 } };
    pub const ease_out: Timing = .{ .cubic = .{ 0, 0, 0.58, 1 } };
    pub const ease_in_out: Timing = .{ .cubic = .{ 0.42, 0, 0.58, 1 } };

    /// The eased progress for the input progress `t` in 0..1. A spring
    /// reads `t` as the fraction of its own duration.
    pub fn eval(tm: Timing, t_in: f32) f32 {
        const t = std.math.clamp(t_in, 0, 1);
        return switch (tm) {
            .linear => t,
            .cubic => |c| cubic(c, t),
            .steps => |s| steps(s.n, s.pos, t),
            .spring => |p| if (t >= 1) 1 else springAt(p, t * springDuration(p)),
        };
    }

    pub fn eql(a: Timing, b: Timing) bool {
        return std.meta.eql(a, b);
    }
};

fn bez(p1: f32, p2: f32, s: f32) f32 {
    const u = 1 - s;
    return 3 * u * u * s * p1 + 3 * u * s * s * p2 + s * s * s;
}

fn bezSlope(p1: f32, p2: f32, s: f32) f32 {
    const u = 1 - s;
    return 3 * u * u * p1 + 6 * u * s * (p2 - p1) + 3 * s * s * (1 - p2);
}

/// cubic-bezier(x1, y1, x2, y2) at t.
pub fn cubic(c: [4]f32, t: f32) f32 {
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    var s: f32 = t;
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        const err = bez(c[0], c[2], s) - t;
        if (@abs(err) < 1e-6) return bez(c[1], c[3], s);
        const d = bezSlope(c[0], c[2], s);
        if (@abs(d) < 1e-6) break;
        s -= err / d;
        if (s < 0 or s > 1) break;
    }
    var lo: f32 = 0;
    var hi: f32 = 1;
    s = t;
    i = 0;
    while (i < 32) : (i += 1) {
        s = (lo + hi) * 0.5;
        if (bez(c[0], c[2], s) < t) lo = s else hi = s;
    }
    return bez(c[1], c[3], s);
}

/// steps(n, pos) at t.
pub fn steps(n_in: u16, pos: StepPos, t: f32) f32 {
    const n: f32 = @floatFromInt(@max(n_in, 1));
    var step = @floor(t * n);
    if (pos == .jump_start or pos == .jump_both) step += 1;
    if (t >= 0 and step < 0) step = 0;
    var jumps = n;
    switch (pos) {
        .jump_none => jumps = @max(n - 1, 1),
        .jump_both => jumps = n + 1,
        else => {},
    }
    if (t <= 1 and step > jumps) step = jumps;
    if (t >= 1) return 1;
    return step / jumps;
}

/// The position of a spring at `sec` seconds: 0 at the start, 1 at rest.
pub fn springAt(p: [3]f32, sec: f32) f32 {
    const k: f64 = @max(p[0], 0.01);
    const c: f64 = @max(p[1], 0);
    const m: f64 = @max(p[2], 0.01);
    const t: f64 = @max(sec, 0);
    const w0 = @sqrt(k / m);
    const zeta = c / (2 * @sqrt(k * m));
    var x: f64 = undefined;
    if (zeta < 1) {
        const wd = w0 * @sqrt(1 - zeta * zeta);
        x = @exp(-zeta * w0 * t) * (@cos(wd * t) + (zeta * w0 / wd) * @sin(wd * t));
    } else if (zeta == 1) {
        x = @exp(-w0 * t) * (1 + w0 * t);
    } else {
        const r1 = -w0 * (zeta - @sqrt(zeta * zeta - 1));
        const r2 = -w0 * (zeta + @sqrt(zeta * zeta - 1));
        // x(0) = 1 and x'(0) = 0.
        const a = r2 / (r2 - r1);
        const b = -r1 / (r2 - r1);
        x = a * @exp(r1 * t) + b * @exp(r2 * t);
    }
    return @floatCast(1 - x);
}

/// The time in seconds after which the spring stays within 0.001 of rest.
pub fn springDuration(p: [3]f32) f32 {
    var last_out: f32 = 0;
    var ms: u32 = 0;
    while (ms < 10000) : (ms += 1) {
        const sec = @as(f32, @floatFromInt(ms)) / 1000;
        if (@abs(1 - springAt(p, sec)) >= 0.001) last_out = sec;
        // Stop after 300 ms at rest.
        if (sec - last_out > 0.3) break;
    }
    return @max(last_out + 0.001, 0.016);
}

const testing = std.testing;

fn near(want: f32, got: f32, tol: f32) !void {
    if (@abs(want - got) > tol) {
        std.debug.print("want {d} got {d}\n", .{ want, got });
        return error.TestExpectedApproxEq;
    }
}

test "easing: the named cubic curves" {
    // Values computed by hand from the definition: for `ease`, x(s) = 0.5
    // at s = 0.4 gives y(0.4) = 0.802 within the solver error.
    try near(0, Timing.ease.eval(0), 0);
    try near(1, Timing.ease.eval(1), 0);
    try near(0.8024, Timing.ease.eval(0.5), 0.002);
    try near(0.3153, Timing.ease_in.eval(0.5), 0.002);
    try near(0.6847, Timing.ease_out.eval(0.5), 0.002);
    try near(0.5, Timing.ease_in_out.eval(0.5), 0.0005);
    // A symmetric curve: f(t) + f(1 - t) = 1.
    try near(1, Timing.ease_in_out.eval(0.25) + Timing.ease_in_out.eval(0.75), 0.001);
    try near(0.25, (Timing{ .linear = {} }).eval(0.25), 0);
}

test "easing: steps at each jump" {
    try near(0, steps(4, .jump_end, 0.2), 0);
    try near(0.25, steps(4, .jump_end, 0.25), 0);
    try near(0.75, steps(4, .jump_end, 0.99), 0);
    try near(0.25, steps(4, .jump_start, 0), 0);
    try near(1, steps(4, .jump_start, 0.8), 0);
    try near(0, steps(3, .jump_none, 0.2), 0);
    try near(0.5, steps(3, .jump_none, 0.5), 0);
    try near(0.25, steps(3, .jump_both, 0.1), 0);
    try near(1, steps(3, .jump_both, 1), 0);
}

test "easing: a spring" {
    const p = [3]f32{ 100, 10, 1 };
    // zeta = 0.5, w0 = 10: x(0.1) = exp(-0.5) * (cos(0.866) + 0.577 * sin(0.866)).
    try near(0, springAt(p, 0), 1e-6);
    try near(1 - 0.6065 * (0.6479 + 0.5774 * 0.7617), springAt(p, 0.1), 0.001);
    // An under-damped spring goes past 1 and comes back.
    var peak: f32 = 0;
    var ms: u32 = 0;
    while (ms < 1000) : (ms += 5) peak = @max(peak, springAt(p, @as(f32, @floatFromInt(ms)) / 1000));
    try testing.expect(peak > 1.1);
    const d = springDuration(p);
    try testing.expect(d > 0.5 and d < 2.0);
    try near(1, (Timing{ .spring = p }).eval(1), 0);
    // A critically damped spring does not go past 1.
    const crit = [3]f32{ 100, 20, 1 };
    ms = 0;
    while (ms < 2000) : (ms += 5) try testing.expect(springAt(crit, @as(f32, @floatFromInt(ms)) / 1000) <= 1.0001);
}
