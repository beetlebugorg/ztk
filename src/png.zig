//! PNG encode and decode for 8-bit RGBA images. The encoder writes filter
//! type 0 for each row and a zlib stream from `std.compress.flate`. The
//! decoder reads 8-bit RGBA with no interlace and the five filter types.
//! A chunk has a length, a type, the data, and a CRC-32 of the type and
//! the data. The decoder checks the CRC of each chunk it reads.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Io = std.Io;
const flate = std.compress.flate;
const Image = @import("render/renderer.zig").Image;

const signature = [8]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a };

fn chunk(w: *Io.Writer, kind: *const [4]u8, data: []const u8) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try w.writeAll(&len);
    try w.writeAll(kind);
    try w.writeAll(data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    var c: [4]u8 = undefined;
    std.mem.writeInt(u32, &c, crc.final(), .big);
    try w.writeAll(&c);
}

pub fn encode(gpa: std.mem.Allocator, img: Image) ![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll(&signature);
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], img.width, .big);
    std.mem.writeInt(u32, ihdr[4..8], img.height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // RGBA
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try chunk(w, "IHDR", &ihdr);

    // The zlib stream of the filtered rows.
    var z: Io.Writer.Allocating = try .initCapacity(gpa, 4096);
    defer z.deinit();
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var comp = try flate.Compress.init(&z.writer, window, .zlib, .level_6);
    const stride = @as(usize, img.width) * 4;
    var y: usize = 0;
    while (y < img.height) : (y += 1) {
        try comp.writer.writeByte(0);
        try comp.writer.writeAll(img.pixels[y * stride ..][0..stride]);
    }
    try comp.finish();
    try chunk(w, "IDAT", z.written());
    try chunk(w, "IEND", "");
    return out.toOwnedSlice();
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p: i32 = @as(i32, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

/// The caller frees `pixels` with `gpa`.
pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) !Image {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..8], &signature)) return error.NotPng;
    var pos: usize = 8;
    var width: u32 = 0;
    var height: u32 = 0;
    var idat: std.ArrayListUnmanaged(u8) = .empty;
    defer idat.deinit(gpa);
    var have_header = false;
    while (pos + 12 <= bytes.len) {
        const len = std.mem.readInt(u32, bytes[pos..][0..4], .big);
        const kind = bytes[pos + 4 ..][0..4];
        if (pos + 12 + @as(usize, len) > bytes.len) return error.Truncated;
        const data = bytes[pos + 8 ..][0..len];
        var crc = std.hash.Crc32.init();
        crc.update(kind);
        crc.update(data);
        if (crc.final() != std.mem.readInt(u32, bytes[pos + 8 + len ..][0..4], .big)) return error.BadCrc;
        pos += 12 + len;
        if (std.mem.eql(u8, kind, "IHDR")) {
            if (len != 13) return error.BadHeader;
            width = std.mem.readInt(u32, data[0..4], .big);
            height = std.mem.readInt(u32, data[4..8], .big);
            if (data[8] != 8 or data[9] != 6 or data[12] != 0) return error.Unsupported;
            if (width == 0 or height == 0 or width > 1 << 15 or height > 1 << 15) return error.BadHeader;
            have_header = true;
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(gpa, data);
        } else if (std.mem.eql(u8, kind, "IEND")) break;
    }
    if (!have_header) return error.BadHeader;
    const stride = @as(usize, width) * 4;
    const raw_len = (stride + 1) * height;
    const raw = try gpa.alloc(u8, raw_len);
    defer gpa.free(raw);
    var in: Io.Reader = .fixed(idat.items);
    const wbuf = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(wbuf);
    var dec = flate.Decompress.init(&in, .zlib, wbuf);
    dec.reader.readSliceAll(raw) catch return error.BadData;
    const pixels = try gpa.alloc(u8, stride * height);
    errdefer gpa.free(pixels);
    var y: usize = 0;
    while (y < height) : (y += 1) {
        const ft = raw[y * (stride + 1)];
        const src = raw[y * (stride + 1) + 1 ..][0..stride];
        const dst = pixels[y * stride ..][0..stride];
        const up: ?[]const u8 = if (y > 0) pixels[(y - 1) * stride ..][0..stride] else null;
        for (dst, 0..) |*d, i| {
            const a: u8 = if (i >= 4) dst[i - 4] else 0;
            const b: u8 = if (up) |u| u[i] else 0;
            const c: u8 = if (up != null and i >= 4) up.?[i - 4] else 0;
            d.* = switch (ft) {
                0 => src[i],
                1 => src[i] +% a,
                2 => src[i] +% b,
                3 => src[i] +% @as(u8, @intCast((@as(u16, a) + b) / 2)),
                4 => src[i] +% paeth(a, b, c),
                else => return error.BadFilter,
            };
        }
    }
    return .{ .width = width, .height = height, .pixels = pixels };
}
