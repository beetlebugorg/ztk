//! GIF and PPM decode to 8-bit RGBA, for the photo images of Tk. The GIF
//! decoder reads the first image of the file: the global or the local
//! color table, the LZW data, the interlace, and the transparent index of
//! a graphic control block. The PPM decoder reads the binary forms P5
//! (gray) and P6 (color) with a maximum value up to 255.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Image = @import("render/renderer.zig").Image;

pub fn isGif(bytes: []const u8) bool {
    return bytes.len >= 6 and (std.mem.eql(u8, bytes[0..6], "GIF87a") or std.mem.eql(u8, bytes[0..6], "GIF89a"));
}

pub fn isPpm(bytes: []const u8) bool {
    return bytes.len >= 2 and bytes[0] == 'P' and (bytes[1] == '5' or bytes[1] == '6');
}

const Reader = struct {
    b: []const u8,
    pos: usize = 0,

    fn byte(r: *Reader) !u8 {
        if (r.pos >= r.b.len) return error.Truncated;
        r.pos += 1;
        return r.b[r.pos - 1];
    }

    fn u16le(r: *Reader) !u16 {
        const lo = try r.byte();
        const hi = try r.byte();
        return @as(u16, hi) << 8 | lo;
    }

    fn take(r: *Reader, n: usize) ![]const u8 {
        if (r.pos + n > r.b.len) return error.Truncated;
        r.pos += n;
        return r.b[r.pos - n .. r.pos];
    }

    /// Skips the data sub-blocks up to the block terminator.
    fn skipBlocks(r: *Reader) !void {
        while (true) {
            const n = try r.byte();
            if (n == 0) return;
            _ = try r.take(n);
        }
    }
};

/// The caller frees `pixels` with `gpa`.
pub fn decodeGif(gpa: std.mem.Allocator, bytes: []const u8) !Image {
    if (!isGif(bytes)) return error.NotGif;
    var r: Reader = .{ .b = bytes, .pos = 6 };
    const sw = try r.u16le();
    const sh = try r.u16le();
    _ = sw;
    _ = sh;
    const flags = try r.byte();
    _ = try r.byte(); // background index
    _ = try r.byte(); // aspect
    var global: []const u8 = &.{};
    if (flags & 0x80 != 0) global = try r.take(3 * (@as(usize, 2) << @intCast(flags & 7)));
    var transparent: ?u8 = null;
    while (true) {
        const tag = try r.byte();
        switch (tag) {
            0x21 => {
                const label = try r.byte();
                if (label == 0xf9) {
                    const n = try r.byte();
                    const blk = try r.take(n);
                    if (n >= 4 and blk[0] & 1 != 0) transparent = blk[3];
                }
                try r.skipBlocks();
            },
            0x2c => return decodeImage(gpa, &r, global, transparent),
            else => return error.BadGif,
        }
    }
}

fn decodeImage(gpa: std.mem.Allocator, r: *Reader, global: []const u8, transparent: ?u8) !Image {
    _ = try r.u16le();
    _ = try r.u16le();
    const w = try r.u16le();
    const h = try r.u16le();
    const flags = try r.byte();
    var table = global;
    if (flags & 0x80 != 0) table = try r.take(3 * (@as(usize, 2) << @intCast(flags & 7)));
    const interlaced = flags & 0x40 != 0;
    if (w == 0 or h == 0) return error.BadGif;
    const count = @as(usize, w) * h;
    const index = try gpa.alloc(u8, count);
    defer gpa.free(index);
    @memset(index, 0);
    try lzw(gpa, r, index);
    const pixels = try gpa.alloc(u8, count * 4);
    errdefer gpa.free(pixels);
    var row: usize = 0;
    while (row < h) : (row += 1) {
        // An interlaced image stores the rows in four passes.
        const y = if (interlaced) interlaceRow(row, h) else row;
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const c = index[row * w + x];
            const o = (y * w + x) * 4;
            if (transparent != null and c == transparent.?) {
                @memset(pixels[o .. o + 4], 0);
            } else if (@as(usize, c) * 3 + 2 < table.len) {
                pixels[o] = table[@as(usize, c) * 3];
                pixels[o + 1] = table[@as(usize, c) * 3 + 1];
                pixels[o + 2] = table[@as(usize, c) * 3 + 2];
                pixels[o + 3] = 255;
            } else {
                pixels[o] = 0;
                pixels[o + 1] = 0;
                pixels[o + 2] = 0;
                pixels[o + 3] = 255;
            }
        }
    }
    return .{ .width = w, .height = h, .pixels = pixels };
}

/// The row of the image for the row number `n` of the data.
fn interlaceRow(n: usize, h: usize) usize {
    const passes = [_][2]usize{ .{ 0, 8 }, .{ 4, 8 }, .{ 2, 4 }, .{ 1, 2 } };
    var left = n;
    for (passes) |p| {
        const rows = if (h > p[0]) (h - p[0] + p[1] - 1) / p[1] else 0;
        if (left < rows) return p[0] + left * p[1];
        left -= rows;
    }
    return 0;
}

/// Decodes the LZW data of an image into `out`. Data past the end of
/// `out` is dropped, and short data leaves the rest of `out` at 0.
fn lzw(gpa: std.mem.Allocator, r: *Reader, out: []u8) !void {
    const min = try r.byte();
    if (min < 1 or min > 11) return error.BadGif;
    // Collect the sub-blocks into one stream.
    var data: std.ArrayListUnmanaged(u8) = .empty;
    defer data.deinit(gpa);
    while (true) {
        const n = try r.byte();
        if (n == 0) break;
        try data.appendSlice(gpa, try r.take(n));
    }
    const clear: u16 = @as(u16, 1) << @intCast(min);
    const end: u16 = clear + 1;
    var prefix: [4096]u16 = undefined;
    var suffix: [4096]u8 = undefined;
    var first: [4096]u8 = undefined;
    var stack: [4097]u8 = undefined;
    var k: u16 = 0;
    while (k < clear) : (k += 1) {
        prefix[k] = 0xffff;
        suffix[k] = @intCast(k & 0xff);
        first[k] = @intCast(k & 0xff);
    }
    var size: u5 = @intCast(min + 1);
    var next: u16 = end + 1;
    var old: ?u16 = null;
    var bits: u32 = 0;
    var nbits: u5 = 0;
    var o: usize = 0;
    var di: usize = 0;
    while (o < out.len) {
        while (nbits < size) {
            if (di >= data.items.len) return;
            bits |= @as(u32, data.items[di]) << nbits;
            di += 1;
            nbits += 8;
        }
        const code: u16 = @intCast(bits & ((@as(u32, 1) << size) - 1));
        bits >>= size;
        nbits -= size;
        if (code == clear) {
            size = @intCast(min + 1);
            next = end + 1;
            old = null;
            continue;
        }
        if (code == end) return;
        var cur = code;
        var sp: usize = 0;
        if (code >= next) {
            // The code that the decoder makes now: old + first of old.
            const p = old orelse return error.BadGif;
            if (code != next) return error.BadGif;
            stack[sp] = first[p];
            sp += 1;
            cur = p;
        }
        while (cur != 0xffff and cur >= clear) {
            if (sp >= stack.len) return error.BadGif;
            stack[sp] = suffix[cur];
            sp += 1;
            cur = prefix[cur];
        }
        if (cur == 0xffff) return error.BadGif;
        stack[sp] = suffix[cur];
        sp += 1;
        const head = suffix[cur];
        while (sp > 0 and o < out.len) {
            sp -= 1;
            out[o] = stack[sp];
            o += 1;
        }
        if (old) |p| if (next < 4096) {
            prefix[next] = p;
            suffix[next] = head;
            first[next] = first[p];
            next += 1;
            if (next == (@as(u32, 1) << size) and size < 12) size += 1;
        };
        old = code;
    }
}

/// The caller frees `pixels` with `gpa`.
pub fn decodePpm(gpa: std.mem.Allocator, bytes: []const u8) !Image {
    if (!isPpm(bytes)) return error.NotPpm;
    const color = bytes[1] == '6';
    var pos: usize = 2;
    var nums: [3]u32 = undefined;
    for (&nums) |*n| {
        // Skip white space and comments.
        while (pos < bytes.len) {
            if (std.ascii.isWhitespace(bytes[pos])) {
                pos += 1;
            } else if (bytes[pos] == '#') {
                while (pos < bytes.len and bytes[pos] != '\n') pos += 1;
            } else break;
        }
        const start = pos;
        while (pos < bytes.len and std.ascii.isDigit(bytes[pos])) pos += 1;
        n.* = std.fmt.parseInt(u32, bytes[start..pos], 10) catch return error.BadPpm;
    }
    pos += 1;
    const w = nums[0];
    const h = nums[1];
    const max = nums[2];
    if (w == 0 or h == 0 or w > 16384 or h > 16384 or max == 0 or max > 255) return error.BadPpm;
    const chans: usize = if (color) 3 else 1;
    const count = @as(usize, w) * h;
    if (pos + count * chans > bytes.len) return error.Truncated;
    const pixels = try gpa.alloc(u8, count * 4);
    for (0..count) |i| {
        const src = bytes[pos + i * chans ..];
        for (0..3) |c| {
            const v: u32 = src[if (color) c else 0];
            pixels[i * 4 + c] = @intCast(@min(255, v * 255 / max));
        }
        pixels[i * 4 + 3] = 255;
    }
    return .{ .width = w, .height = h, .pixels = pixels };
}

test "a 2 by 2 GIF with a transparent index" {
    // Made by hand: a global table of 2 colors (red, blue), a graphic
    // control block with the transparent index 1, and the codes
    // clear 0 1 1 0 end. The code size grows from 3 to 4 bits when the
    // table gets the code 7.
    const gpa = std.testing.allocator;
    var codes: u32 = 0;
    var n: u5 = 0;
    for ([_]u32{ 4, 0, 1, 1, 0, 5 }, [_]u5{ 3, 3, 3, 3, 4, 4 }) |c, bits| {
        codes |= c << n;
        n += bits;
    }
    const lzw_bytes = [_]u8{ @truncate(codes), @truncate(codes >> 8), @truncate(codes >> 16) };
    const file = [_]u8{ 'G', 'I', 'F', '8', '9', 'a', 2, 0, 2, 0, 0x80, 0, 0, 255, 0, 0, 0, 0, 255 } ++
        [_]u8{ 0x21, 0xf9, 4, 1, 0, 0, 1, 0 } ++
        [_]u8{ 0x2c, 0, 0, 0, 0, 2, 0, 2, 0, 0, 2, 3 } ++ lzw_bytes ++ [_]u8{ 0, 0x3b };
    const img = try decodeGif(gpa, &file);
    defer gpa.free(img.pixels);
    try std.testing.expectEqual(@as(u32, 2), img.width);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, img.pixels[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, img.pixels[4..8]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, img.pixels[8..12]);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, img.pixels[12..16]);
}

test "a binary PPM" {
    const gpa = std.testing.allocator;
    const file = "P6\n# c\n2 1\n255\n" ++ [_]u8{ 1, 2, 3, 4, 5, 6 };
    const img = try decodePpm(gpa, file);
    defer gpa.free(img.pixels);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 255, 4, 5, 6, 255 }, img.pixels);
}
