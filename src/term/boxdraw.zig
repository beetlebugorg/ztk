//! Draws the box drawing characters (U+2500 to U+257F) and the block
//! elements (U+2580 to U+259F) of a terminal cell as boxes, so the lines
//! of two cells meet with no gap in each font, and a font without these
//! characters still shows them. A line character is four arms from the
//! center of the cell: up, down, left, and right. Each arm is absent,
//! light, or heavy. The double lines draw as heavy lines, the dashed
//! lines as full lines, and the rounded corners as square corners.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const geom = @import("../base/geom.zig");
const scene = @import("../scene.zig");

/// The weights of the arms: up, down, left, right. 0 is none, 1 light,
/// 2 heavy.
const Arms = [4]u2;

fn arms(cp: u21) ?Arms {
    return switch (cp) {
        0x2500, 0x2504, 0x2508, 0x254c => .{ 0, 0, 1, 1 },
        0x2501, 0x2505, 0x2509, 0x254d, 0x2550 => .{ 0, 0, 2, 2 },
        0x2502, 0x2506, 0x250a, 0x254e => .{ 1, 1, 0, 0 },
        0x2503, 0x2507, 0x250b, 0x254f, 0x2551 => .{ 2, 2, 0, 0 },
        0x250c, 0x256d => .{ 0, 1, 0, 1 },
        0x250f, 0x2554 => .{ 0, 2, 0, 2 },
        0x2510, 0x256e => .{ 0, 1, 1, 0 },
        0x2513, 0x2557 => .{ 0, 2, 2, 0 },
        0x2514, 0x2570 => .{ 1, 0, 0, 1 },
        0x2517, 0x255a => .{ 2, 0, 0, 2 },
        0x2518, 0x256f => .{ 1, 0, 1, 0 },
        0x251b, 0x255d => .{ 2, 0, 2, 0 },
        0x251c => .{ 1, 1, 0, 1 },
        0x2523, 0x2560 => .{ 2, 2, 0, 2 },
        0x2524 => .{ 1, 1, 1, 0 },
        0x252b, 0x2563 => .{ 2, 2, 2, 0 },
        0x252c => .{ 0, 1, 1, 1 },
        0x2533, 0x2566 => .{ 0, 2, 2, 2 },
        0x2534 => .{ 1, 0, 1, 1 },
        0x253b, 0x2569 => .{ 2, 0, 2, 2 },
        0x253c => .{ 1, 1, 1, 1 },
        0x254b, 0x256c => .{ 2, 2, 2, 2 },
        0x2574 => .{ 0, 0, 1, 0 },
        0x2575 => .{ 1, 0, 0, 0 },
        0x2576 => .{ 0, 0, 0, 1 },
        0x2577 => .{ 0, 1, 0, 0 },
        0x2578 => .{ 0, 0, 2, 0 },
        0x2579 => .{ 2, 0, 0, 0 },
        0x257a => .{ 0, 0, 0, 2 },
        0x257b => .{ 0, 2, 0, 0 },
        else => null,
    };
}

/// True for a code point that `draw` draws.
pub fn covers(cp: u21) bool {
    if (cp >= 0x2580 and cp <= 0x2595) return true;
    return arms(cp) != null;
}

pub fn draw(b: *scene.Builder, cp: u21, r: geom.Rect, color: geom.Color) !void {
    if (arms(cp)) |a| return drawArms(b, a, r, color);
    // The block elements.
    const eighth_h = @max(@divFloor(r.h, 8), 1);
    const eighth_w = @max(@divFloor(r.w, 8), 1);
    switch (cp) {
        0x2580 => try fill(b, .{ .x = r.x, .y = r.y, .w = r.w, .h = @divFloor(r.h, 2) }, color),
        0x2581...0x2588 => {
            const n: i32 = @intCast(cp - 0x2580);
            const h = if (n == 8) r.h else n * eighth_h;
            try fill(b, .{ .x = r.x, .y = r.y + r.h - h, .w = r.w, .h = h }, color);
        },
        0x2589...0x258f => {
            const n: i32 = @intCast(0x2590 - cp);
            try fill(b, .{ .x = r.x, .y = r.y, .w = n * eighth_w, .h = r.h }, color);
        },
        0x2590 => try fill(b, .{ .x = r.x + @divFloor(r.w, 2), .y = r.y, .w = r.w - @divFloor(r.w, 2), .h = r.h }, color),
        0x2591, 0x2592, 0x2593 => {
            var c = color;
            c.a = @intCast(@as(u32, color.a) * (cp - 0x2590) / 4);
            try fill(b, r, c);
        },
        0x2594 => try fill(b, .{ .x = r.x, .y = r.y, .w = r.w, .h = eighth_h }, color),
        0x2595 => try fill(b, .{ .x = r.x + r.w - eighth_w, .y = r.y, .w = eighth_w, .h = r.h }, color),
        else => {},
    }
}

fn fill(b: *scene.Builder, r: geom.Rect, color: geom.Color) !void {
    if (r.w <= 0 or r.h <= 0) return;
    try b.box(r, .{ .fill = color });
}

fn drawArms(b: *scene.Builder, a: Arms, r: geom.Rect, color: geom.Color) !void {
    const light = @max(@divFloor(r.w, 8), 1);
    const heavy = light * 2;
    var thick: i32 = light;
    for (a) |x| if (x == 2) {
        thick = heavy;
    };
    const cx = r.x + @divFloor(r.w - thick, 2);
    const cy = r.y + @divFloor(r.h - thick, 2);
    for (a, 0..) |weight, k| {
        if (weight == 0) continue;
        const t: i32 = if (weight == 2) heavy else light;
        const ox = r.x + @divFloor(r.w - t, 2);
        const oy = r.y + @divFloor(r.h - t, 2);
        const seg: geom.Rect = switch (k) {
            0 => .{ .x = ox, .y = r.y, .w = t, .h = cy + thick - r.y },
            1 => .{ .x = ox, .y = cy, .w = t, .h = r.y + r.h - cy },
            2 => .{ .x = r.x, .y = oy, .w = cx + thick - r.x, .h = t },
            else => .{ .x = cx, .y = oy, .w = r.x + r.w - cx, .h = t },
        };
        try fill(b, seg, color);
    }
}

test "box drawing covers the lines and the blocks" {
    try std.testing.expect(covers(0x2500));
    try std.testing.expect(covers(0x256d));
    try std.testing.expect(covers(0x2588));
    try std.testing.expect(!covers('a'));
    try std.testing.expect(!covers(0x25a0));
}
