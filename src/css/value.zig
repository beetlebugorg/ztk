//! Typed values of declarations: colors, lengths, and box sides. The
//! color forms are #rgb, #rgba, #rrggbb, #rrggbbaa, rgb(), rgba(), hsl(),
//! hsla(), `transparent`, and the 148 named colors of CSS Color Level 4.
//! `currentColor` and `var()` are not colors here. The style system
//! resolves them before it calls `parseColor`.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const num = @import("../base/num.zig");
const geom = @import("../base/geom.zig");
const Token = @import("token.zig").Token;
const colors = @import("colors.zig");

pub const Unit = enum { px, pt, em, rem, percent };
pub const Length = struct { value: f32, unit: Unit };

fn hexDigit(c: u8) ?u8 {
    return std.fmt.charToDigit(c, 16) catch null;
}

fn parseHash(text: []const u8) ?geom.Color {
    var d: [8]u8 = undefined;
    if (text.len != 3 and text.len != 4 and text.len != 6 and text.len != 8) return null;
    for (text, 0..) |c, i| d[i] = hexDigit(c) orelse return null;
    if (text.len <= 4) {
        const a: u8 = if (text.len == 4) d[3] * 17 else 255;
        return .{ .r = d[0] * 17, .g = d[1] * 17, .b = d[2] * 17, .a = a };
    }
    const a: u8 = if (text.len == 8) d[6] * 16 + d[7] else 255;
    return .{ .r = d[0] * 16 + d[1], .g = d[2] * 16 + d[3], .b = d[4] * 16 + d[5], .a = a };
}

fn toByte(x: f32) u8 {
    return num.byte(x);
}

fn hueToRgb(p: f32, q: f32, t_in: f32) f32 {
    var t = t_in;
    if (t < 0) t += 1;
    if (t > 1) t -= 1;
    if (t < 1.0 / 6.0) return p + (q - p) * 6 * t;
    if (t < 0.5) return q;
    if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6;
    return p;
}

/// Reads the arguments of a color function: numbers, percentages, and
/// dimensions, in order. Commas, a slash, and white space separate them.
fn args(tokens: []const Token, out: *[4]Token) ?usize {
    var n: usize = 0;
    for (tokens) |tk| switch (tk) {
        .whitespace, .comma => {},
        .delim => |d| if (d != '/') return null,
        .rparen => return n,
        .number, .percentage, .dimension => {
            if (n == 4) return null;
            out[n] = tk;
            n += 1;
        },
        else => return null,
    };
    return null; // no closing parenthesis
}

fn alphaOf(tk: Token) ?f32 {
    return switch (tk) {
        .number => |v| std.math.clamp(v, 0, 1),
        .percentage => |v| std.math.clamp(v / 100, 0, 1),
        else => null,
    };
}

pub fn parseColor(tokens: []const Token) ?geom.Color {
    var i: usize = 0;
    var end = tokens.len;
    while (i < end and tokens[i] == .whitespace) i += 1;
    while (end > i and tokens[end - 1] == .whitespace) end -= 1;
    const tk = tokens[i..end];
    if (tk.len == 0) return null;
    switch (tk[0]) {
        .hash => |h| return if (tk.len == 1) parseHash(h) else null,
        .ident => |name| {
            if (tk.len != 1) return null;
            if (std.ascii.eqlIgnoreCase(name, "transparent")) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
            const v = colors.lookup(name) orelse return null;
            return .{ .r = @truncate(v >> 16), .g = @truncate(v >> 8), .b = @truncate(v) };
        },
        .function => |name| {
            var a: [4]Token = undefined;
            const n = args(tk[1..], &a) orelse return null;
            if (tk[tk.len - 1] != .rparen) return null;
            if (n != 3 and n != 4) return null;
            const alpha: f32 = if (n == 4) (alphaOf(a[3]) orelse return null) else 1;
            const a8 = toByte(alpha * 255);
            if (std.ascii.eqlIgnoreCase(name, "rgb") or std.ascii.eqlIgnoreCase(name, "rgba")) {
                var c: [3]u8 = undefined;
                for (0..3) |k| c[k] = switch (a[k]) {
                    .number => |v| toByte(v),
                    .percentage => |v| toByte(v * 2.55),
                    else => return null,
                };
                return .{ .r = c[0], .g = c[1], .b = c[2], .a = a8 };
            }
            if (std.ascii.eqlIgnoreCase(name, "hsl") or std.ascii.eqlIgnoreCase(name, "hsla")) {
                const h_deg: f32 = switch (a[0]) {
                    .number => |v| v,
                    .dimension => |d| if (std.ascii.eqlIgnoreCase(d.unit, "deg")) d.value else return null,
                    else => return null,
                };
                const s: f32 = switch (a[1]) {
                    .percentage => |v| std.math.clamp(v / 100, 0, 1),
                    else => return null,
                };
                const l: f32 = switch (a[2]) {
                    .percentage => |v| std.math.clamp(v / 100, 0, 1),
                    else => return null,
                };
                const h = (h_deg - 360 * @floor(h_deg / 360)) / 360;
                if (s == 0) {
                    const g = toByte(l * 255);
                    return .{ .r = g, .g = g, .b = g, .a = a8 };
                }
                const q = if (l < 0.5) l * (1 + s) else l + s - l * s;
                const p = 2 * l - q;
                return .{
                    .r = toByte(hueToRgb(p, q, h + 1.0 / 3.0) * 255),
                    .g = toByte(hueToRgb(p, q, h) * 255),
                    .b = toByte(hueToRgb(p, q, h - 1.0 / 3.0) * 255),
                    .a = a8,
                };
            }
            return null;
        },
        else => return null,
    }
}

pub fn parseLength(tok: Token) ?Length {
    switch (tok) {
        .number => |v| return if (v == 0) .{ .value = 0, .unit = .px } else null,
        .percentage => |v| return .{ .value = v, .unit = .percent },
        .dimension => |d| {
            const units = [_]struct { []const u8, Unit }{ .{ "px", .px }, .{ "pt", .pt }, .{ "em", .em }, .{ "rem", .rem } };
            for (units) |u| if (std.ascii.eqlIgnoreCase(d.unit, u[0])) return .{ .value = d.value, .unit = u[1] };
            return null;
        },
        else => return null,
    }
}

/// 1 to 4 lengths in the order top, right, bottom, left, with the CSS
/// rules for missing values.
pub fn parseSides(tokens: []const Token) ?[4]Length {
    var v: [4]Length = undefined;
    var n: usize = 0;
    for (tokens) |tk| {
        if (tk == .whitespace) continue;
        if (n == 4) return null;
        v[n] = parseLength(tk) orelse return null;
        n += 1;
    }
    return switch (n) {
        1 => .{ v[0], v[0], v[0], v[0] },
        2 => .{ v[0], v[1], v[0], v[1] },
        3 => .{ v[0], v[1], v[2], v[1] },
        4 => v,
        else => null,
    };
}
