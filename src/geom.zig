//! Points, sizes, rectangles, insets, and colors. The unit is the logical pixel.
//! Rectangles use half-open ranges: the right and bottom edges are outside.
//! Color parsing follows the forms of Tk: #rgb, #rrggbb, #rrrrggggbbbb, and a name.
//! The 16-bit form keeps the high byte of each part.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

pub const Point = struct { x: i32 = 0, y: i32 = 0 };

pub const Size = struct { w: i32 = 0, h: i32 = 0 };

pub const Insets = struct {
    top: i32 = 0,
    right: i32 = 0,
    bottom: i32 = 0,
    left: i32 = 0,

    pub fn all(n: i32) Insets {
        return .{ .top = n, .right = n, .bottom = n, .left = n };
    }

    /// left + right
    pub fn horizontal(i: Insets) i32 {
        return i.left + i.right;
    }

    /// top + bottom
    pub fn vertical(i: Insets) i32 {
        return i.top + i.bottom;
    }
};

pub const Rect = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,

    pub fn isEmpty(r: Rect) bool {
        return r.w <= 0 or r.h <= 0;
    }

    /// The right and bottom edges are outside.
    pub fn contains(r: Rect, p: Point) bool {
        return p.x >= r.x and p.y >= r.y and p.x < r.x + r.w and p.y < r.y + r.h;
    }

    /// An empty result has w = 0 and h = 0.
    pub fn intersect(a: Rect, b: Rect) Rect {
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.x + a.w, b.x + b.w);
        const y1 = @min(a.y + a.h, b.y + b.h);
        if (x1 <= x0 or y1 <= y0) return .{ .x = x0, .y = y0 };
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }

    /// The width and the height do not go below 0.
    pub fn inset(r: Rect, i: Insets) Rect {
        return .{
            .x = r.x + i.left,
            .y = r.y + i.top,
            .w = @max(0, r.w - i.horizontal()),
            .h = @max(0, r.h - i.vertical()),
        };
    }

    pub fn translate(r: Rect, dx: i32, dy: i32) Rect {
        return .{ .x = r.x + dx, .y = r.y + dy, .w = r.w, .h = r.h };
    }
};

/// sRGB with straight alpha.
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    const named = [_]struct { []const u8, [3]u8 }{
        .{ "black", .{ 0, 0, 0 } },
        .{ "white", .{ 255, 255, 255 } },
        .{ "red", .{ 255, 0, 0 } },
        .{ "green", .{ 0, 128, 0 } },
        .{ "blue", .{ 0, 0, 255 } },
        .{ "yellow", .{ 255, 255, 0 } },
        .{ "cyan", .{ 0, 255, 255 } },
        .{ "magenta", .{ 255, 0, 255 } },
        .{ "gray", .{ 128, 128, 128 } },
        .{ "grey", .{ 128, 128, 128 } },
        .{ "orange", .{ 255, 165, 0 } },
        .{ "purple", .{ 128, 0, 128 } },
        .{ "brown", .{ 165, 42, 42 } },
        .{ "pink", .{ 255, 192, 203 } },
    };

    /// The color forms of Tk: #rgb, #rrggbb, #rrrrggggbbbb, and a name.
    /// A short form of n digits per part scales to 8 bits as Tk does:
    /// one digit repeats, and a longer part keeps its high byte.
    pub fn parseTk(text: []const u8) ?Color {
        if (text.len == 0) return null;
        if (text[0] == '#') {
            const digits = text[1..];
            const n: usize = switch (digits.len) {
                3 => 1,
                6 => 2,
                12 => 4,
                else => return null,
            };
            var parts: [3]u8 = undefined;
            for (&parts, 0..) |*p, k| {
                const s = digits[k * n ..][0..n];
                const v = std.fmt.parseInt(u16, s, 16) catch return null;
                p.* = switch (n) {
                    1 => @intCast(v * 17),
                    2 => @intCast(v),
                    else => @intCast(v >> 8),
                };
            }
            return .{ .r = parts[0], .g = parts[1], .b = parts[2] };
        }
        for (named) |entry| {
            if (std.ascii.eqlIgnoreCase(text, entry[0])) {
                return .{ .r = entry[1][0], .g = entry[1][1], .b = entry[1][2] };
            }
        }
        return null;
    }

    fn withAlpha(c: Color, a: u8) Color {
        return .{ .r = c.r, .g = c.g, .b = c.b, .a = a };
    }

    /// "#rrggbb", lower case.
    pub fn formatTk(c: Color, buf: *[7]u8) []const u8 {
        const hex = "0123456789abcdef";
        buf[0] = '#';
        inline for (.{ c.r, c.g, c.b }, 0..) |v, k| {
            buf[1 + k * 2] = hex[v >> 4];
            buf[2 + k * 2] = hex[v & 15];
        }
        return buf[0..7];
    }
};

test "geom: Rect.contains edges" {
    const r: Rect = .{ .x = 10, .y = 10, .w = 5, .h = 5 };
    try std.testing.expect(r.contains(.{ .x = 10, .y = 10 }));
    try std.testing.expect(!r.contains(.{ .x = 15, .y = 12 }));
    try std.testing.expect(!r.contains(.{ .x = 12, .y = 15 }));
    try std.testing.expect(r.contains(.{ .x = 14, .y = 14 }));
}

test "geom: Rect.intersect" {
    const a: Rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const far: Rect = .{ .x = 20, .y = 20, .w = 5, .h = 5 };
    const e = a.intersect(far);
    try std.testing.expect(e.isEmpty());
    try std.testing.expectEqual(@as(i32, 0), e.w);
    try std.testing.expectEqual(@as(i32, 0), e.h);
    const touch = a.intersect(.{ .x = 10, .y = 0, .w = 5, .h = 5 });
    try std.testing.expect(touch.isEmpty());
    const m = a.intersect(.{ .x = 5, .y = 6, .w = 10, .h = 10 });
    try std.testing.expectEqual(Rect{ .x = 5, .y = 6, .w = 5, .h = 4 }, m);
}

test "geom: Rect.inset does not go below zero" {
    const r: Rect = .{ .x = 0, .y = 0, .w = 10, .h = 6 };
    const s = r.inset(Insets.all(20));
    try std.testing.expectEqual(@as(i32, 0), s.w);
    try std.testing.expectEqual(@as(i32, 0), s.h);
    const t = r.inset(.{ .top = 1, .right = 2, .bottom = 3, .left = 4 });
    try std.testing.expectEqual(Rect{ .x = 4, .y = 1, .w = 4, .h = 2 }, t);
}

test "geom: Rect.translate" {
    const r: Rect = .{ .x = 1, .y = 2, .w = 3, .h = 4 };
    try std.testing.expectEqual(Rect{ .x = 4, .y = 0, .w = 3, .h = 4 }, r.translate(3, -2));
}

test "geom: Color.parseTk forms are equal" {
    const a = Color.parseTk("#fff").?;
    const b = Color.parseTk("#ffffff").?;
    const c = Color.parseTk("#ffffffffffff").?;
    try std.testing.expectEqual(a, b);
    try std.testing.expectEqual(b, c);
    try std.testing.expectEqual(Color{ .r = 0x12, .g = 0x56, .b = 0x9a }, Color.parseTk("#123456789abc").?.withAlpha(255));
}

test "geom: Color.parseTk names" {
    try std.testing.expectEqual(Color{ .r = 255, .g = 0, .b = 0 }, Color.parseTk("Red").?);
    try std.testing.expectEqual(@as(?Color, null), Color.parseTk("nocolor"));
    try std.testing.expectEqual(@as(?Color, null), Color.parseTk("#12"));
    try std.testing.expectEqual(@as(?Color, null), Color.parseTk("#ggg"));
    try std.testing.expectEqual(@as(?Color, null), Color.parseTk(""));
    try std.testing.expectEqual(Color{ .r = 165, .g = 42, .b = 42 }, Color.parseTk("BROWN").?);
}

test "geom: Color.formatTk" {
    var buf: [7]u8 = undefined;
    try std.testing.expectEqualStrings("#d9d9d9", Color.parseTk("#D9d9D9").?.formatTk(&buf));
}
