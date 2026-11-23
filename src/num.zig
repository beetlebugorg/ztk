//! Checked conversions for numbers that come from a script, a style
//! sheet, or a backend. Each function gives a value in range and never
//! traps: a float that is NaN gives 0, and a value outside the range
//! gives the nearest end of the range. The range is one pixel limit for
//! all sizes and positions, so a sum of up to 64 values stays inside
//! `i32`. A longer sum uses `add`, or a saturating operator.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

/// The largest size or position in pixels.
pub const max_px: i32 = 1 << 24;

/// A pixel value from an integer.
pub fn px(v: i64) i32 {
    return @intCast(std.math.clamp(v, -@as(i64, max_px), @as(i64, max_px)));
}

/// A pixel value from a float. It rounds to the nearest integer.
pub fn pxRound(v: f64) i32 {
    if (std.math.isNan(v)) return 0;
    const r = std.math.clamp(@round(v), -@as(f64, max_px), @as(f64, max_px));
    return @intFromFloat(r);
}

/// A pixel value from a float. It rounds up.
pub fn pxCeil(v: f64) i32 {
    if (std.math.isNan(v)) return 0;
    const r = std.math.clamp(@ceil(v), -@as(f64, max_px), @as(f64, max_px));
    return @intFromFloat(r);
}

/// A pixel value from a float. It rounds down.
pub fn pxFloor(v: f64) i32 {
    if (std.math.isNan(v)) return 0;
    const r = std.math.clamp(@floor(v), -@as(f64, max_px), @as(f64, max_px));
    return @intFromFloat(r);
}

/// The largest font size in logical pixels. The atlas page is 1024 texels.
pub const max_font_size: f32 = 1024;

/// A float in a range. NaN gives `lo`.
pub fn clampF(v: f32, lo: f32, hi: f32) f32 {
    if (std.math.isNan(v)) return lo;
    return std.math.clamp(v, lo, hi);
}

/// A byte from a float in the range 0 to 255. NaN gives 0.
pub fn byte(v: f32) u8 {
    return @intFromFloat(@round(clampF(v, 0, 255)));
}

/// The sum of two pixel values, in the pixel range.
pub fn add(a: i32, b: i32) i32 {
    return px(@as(i64, a) + b);
}

test "num: clampF and byte handle NaN and infinity" {
    const t = std.testing;
    try t.expectEqual(@as(f32, 1), clampF(std.math.nan(f32), 1, 2));
    try t.expectEqual(@as(f32, 2), clampF(std.math.inf(f32), 1, 2));
    try t.expectEqual(@as(u8, 0), byte(std.math.nan(f32)));
    try t.expectEqual(@as(u8, 255), byte(1e30));
    try t.expectEqual(max_px, add(max_px, max_px));
}

test "num: values outside the range give the ends, and NaN gives 0" {
    const t = std.testing;
    try t.expectEqual(max_px, px(std.math.maxInt(i64)));
    try t.expectEqual(-max_px, px(std.math.minInt(i64)));
    try t.expectEqual(max_px, pxRound(1e30));
    try t.expectEqual(-max_px, pxFloor(-std.math.inf(f64)));
    try t.expectEqual(@as(i32, 0), pxCeil(std.math.nan(f64)));
    try t.expectEqual(@as(i32, 3), pxCeil(2.1));
    try t.expectEqual(@as(i32, 2), pxFloor(2.9));
}
