//! The icons of a window of the Win32 backend, from `wm iconphoto`. A
//! window has a small icon (the title bar, Alt+Tab) and a big icon (the
//! taskbar), set with `WM_SETICON`. Each one is made at the size of the
//! system for the DPI of the window (`SM_CXSMICON` and `SM_CXICON`) from
//! the photo nearest to that size: the smallest photo at least as large,
//! or else the largest. `fit` resamples it with the mean of the source
//! pixels under each pixel, in premultiplied alpha, and keeps its shape
//! in the middle of the square.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const w32 = @import("win32.zig");
const plat = @import("platform.zig");
const wintray = @import("wintray.zig");

/// The small and the big icon of a window. Each one is the backend's to
/// destroy.
pub const Pair = struct {
    small: ?w32.HICON = null,
    big: ?w32.HICON = null,

    pub fn deinit(p: *Pair) void {
        if (p.small) |h| _ = w32.DestroyIcon(h);
        if (p.big) |h| _ = w32.DestroyIcon(h);
        p.* = .{};
    }

    pub fn empty(p: Pair) bool {
        return p.small == null and p.big == null;
    }
};

/// The two icons of `icons` for a window at `dpi`. Empty with no photo.
pub fn make(gpa: std.mem.Allocator, icons: []const plat.TrayIcon, dpi: u32) Pair {
    return .{
        .small = one(gpa, icons, @intCast(w32.GetSystemMetricsForDpi(w32.SM_CXSMICON, dpi))),
        .big = one(gpa, icons, @intCast(w32.GetSystemMetricsForDpi(w32.SM_CXICON, dpi))),
    };
}

fn one(gpa: std.mem.Allocator, icons: []const plat.TrayIcon, size: u32) ?w32.HICON {
    const src = pick(icons, size) orelse return null;
    const px = fit(gpa, src, size) catch return null;
    defer gpa.free(px);
    return wintray.makeIcon(.{ .width = size, .height = size, .pixels = px });
}

/// Gives `hwnd` the icons of `p`. A null icon gives the window the icon
/// of its class back.
pub fn apply(hwnd: w32.HWND, p: Pair) void {
    _ = w32.SendMessageW(hwnd, w32.WM_SETICON, w32.ICON_SMALL, @bitCast(@intFromPtr(p.small)));
    _ = w32.SendMessageW(hwnd, w32.WM_SETICON, w32.ICON_BIG, @bitCast(@intFromPtr(p.big)));
}

/// The photo for an icon of `size` pixels: the smallest one with a side
/// at least `size`, or else the largest one. Null with no usable photo.
pub fn pick(icons: []const plat.TrayIcon, size: u32) ?plat.TrayIcon {
    var best: ?plat.TrayIcon = null;
    for (icons) |ic| {
        if (ic.width == 0 or ic.height == 0 or ic.pixels.len < @as(usize, ic.width) * ic.height * 4) continue;
        const b = best orelse {
            best = ic;
            continue;
        };
        const side = @max(ic.width, ic.height);
        const bside = @max(b.width, b.height);
        const better = if (bside >= size) side >= size and side < bside else side > bside;
        if (better) best = ic;
    }
    return best;
}

/// The pixels of `src` in a square of `size`, RGBA, its shape kept in the
/// middle, with the rest clear.
pub fn fit(gpa: std.mem.Allocator, src: plat.TrayIcon, size: u32) ![]u8 {
    const out = try gpa.alloc(u8, @as(usize, size) * size * 4);
    @memset(out, 0);
    const sw: f64 = @floatFromInt(src.width);
    const sh: f64 = @floatFromInt(src.height);
    const scale = @as(f64, @floatFromInt(size)) / @max(sw, sh);
    const dw: u32 = @max(1, @as(u32, @intFromFloat(@round(sw * scale))));
    const dh: u32 = @max(1, @as(u32, @intFromFloat(@round(sh * scale))));
    const ox = (size - @min(dw, size)) / 2;
    const oy = (size - @min(dh, size)) / 2;
    for (0..@min(dh, size)) |y| {
        const y0 = @as(f64, @floatFromInt(y)) / scale;
        const y1 = @as(f64, @floatFromInt(y + 1)) / scale;
        for (0..@min(dw, size)) |x| {
            const x0 = @as(f64, @floatFromInt(x)) / scale;
            const x1 = @as(f64, @floatFromInt(x + 1)) / scale;
            const px = mean(src, x0, x1, y0, y1);
            @memcpy(out[((oy + y) * size + ox + x) * 4 ..][0..4], &px);
        }
    }
    return out;
}

/// The mean of the pixels of `src` under the rect from (x0, y0) to (x1,
/// y1), each one weighted by the part of it inside the rect.
fn mean(src: plat.TrayIcon, x0: f64, x1: f64, y0: f64, y1: f64) [4]u8 {
    var sum: [4]f64 = @splat(0);
    var total: f64 = 0;
    const w: f64 = @floatFromInt(src.width);
    const h: f64 = @floatFromInt(src.height);
    var sy = @floor(y0);
    while (sy < @min(y1, h)) : (sy += 1) {
        const wy = @min(sy + 1, y1) - @max(sy, y0);
        var sx = @floor(x0);
        while (sx < @min(x1, w)) : (sx += 1) {
            const wx = @min(sx + 1, x1) - @max(sx, x0);
            const k = wx * wy;
            if (k <= 0) continue;
            const i = (@as(usize, @intFromFloat(sy)) * src.width + @as(usize, @intFromFloat(sx))) * 4;
            const a = @as(f64, @floatFromInt(src.pixels[i + 3])) / 255.0;
            for (0..3) |c| sum[c] += @as(f64, @floatFromInt(src.pixels[i + c])) * a * k;
            sum[3] += a * k;
            total += k;
        }
    }
    if (total == 0 or sum[3] == 0) return .{ 0, 0, 0, 0 };
    var px: [4]u8 = undefined;
    for (0..3) |c| px[c] = @intFromFloat(@round(@min(255.0, sum[c] / sum[3])));
    px[3] = @intFromFloat(@round(@min(255.0, sum[3] / total * 255.0)));
    return px;
}

test "winicon: the photo nearest to a size" {
    var px: [64 * 64 * 4]u8 = @splat(0xff);
    const a: plat.TrayIcon = .{ .width = 16, .height = 16, .pixels = px[0 .. 16 * 16 * 4] };
    const b: plat.TrayIcon = .{ .width = 32, .height = 32, .pixels = px[0 .. 32 * 32 * 4] };
    const c: plat.TrayIcon = .{ .width = 64, .height = 64, .pixels = &px };
    try std.testing.expectEqual(@as(u32, 32), pick(&.{ c, a, b }, 20).?.width);
    try std.testing.expectEqual(@as(u32, 16), pick(&.{ c, a, b }, 16).?.width);
    try std.testing.expectEqual(@as(u32, 64), pick(&.{ a, c, b }, 128).?.width);
    // A photo with fewer pixels than its size is not used.
    const bad: plat.TrayIcon = .{ .width = 8, .height = 8, .pixels = px[0..4] };
    try std.testing.expect(pick(&.{bad}, 16) == null);
}

test "winicon: fit gives the mean, and keeps the shape in the middle" {
    const gpa = std.testing.allocator;
    // 2 by 2: red, clear, red, clear. At 1 pixel: half the alpha, and red.
    const px = [_]u8{ 255, 0, 0, 255, 0, 0, 255, 0, 255, 0, 0, 255, 0, 0, 255, 0 };
    const one_px = try fit(gpa, .{ .width = 2, .height = 2, .pixels = &px }, 1);
    defer gpa.free(one_px);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 128 }, one_px);

    // 4 by 2 into 4: rows 1 and 2 have the photo, rows 0 and 3 are clear.
    const wide: [4 * 2 * 4]u8 = @splat(200);
    const sq = try fit(gpa, .{ .width = 4, .height = 2, .pixels = &wide }, 4);
    defer gpa.free(sq);
    try std.testing.expectEqual(@as(u8, 0), sq[3]);
    try std.testing.expectEqual(@as(u8, 200), sq[(1 * 4) * 4 + 3]);
    try std.testing.expectEqual(@as(u8, 200), sq[(2 * 4 + 3) * 4 + 3]);
    try std.testing.expectEqual(@as(u8, 0), sq[(3 * 4) * 4 + 3]);

    // Up from 1 pixel to 3: each pixel is the one source pixel.
    const dot = [_]u8{ 10, 20, 30, 255 };
    const big = try fit(gpa, .{ .width = 1, .height = 1, .pixels = &dot }, 3);
    defer gpa.free(big);
    try std.testing.expectEqualSlices(u8, &dot, big[4 * 4 ..][0..4]);
}

test "winicon: a pair of icons at 96 and 192 DPI" {
    var px: [48 * 48 * 4]u8 = @splat(0x80);
    var p = make(std.testing.allocator, &.{.{ .width = 48, .height = 48, .pixels = &px }}, 96);
    defer p.deinit();
    try std.testing.expect(p.small != null and p.big != null);
    var q = make(std.testing.allocator, &.{.{ .width = 48, .height = 48, .pixels = &px }}, 192);
    defer q.deinit();
    try std.testing.expect(!q.empty());
    var none = make(std.testing.allocator, &.{}, 96);
    try std.testing.expect(none.empty());
    none.deinit();
}
