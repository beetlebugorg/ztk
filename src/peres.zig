//! The resources of a Windows program for `ztk bundle` (ztk#59): an
//! icon, a manifest, and the version information, in a new `.rsrc`
//! section of a PE32+ file.
//!
//! `add` copies the program and appends one section after the last
//! one. The section has the resource tree of the PE format: a root
//! folder of types, a folder of ids for each type, a folder of one
//! language (1033) for each id, then the data entries and the data.
//! The entries of a folder are sorted by id, as the loader searches
//! them. The types are `RT_ICON` (3, one for each image), `RT_GROUP_ICON`
//! (14, id 1, the list of the images), `RT_VERSION` (16, id 1), and
//! `RT_MANIFEST` (24, id 1, the manifest of the process). The resource
//! entry of the data folders points at the new section, so a section of
//! an older tree stays in the file and the loader no longer reads it.
//!
//! The headers change in place: the count of the sections, the size of
//! the image, the size of the data, the resource entry, and the checksum
//! (the sum of the 16-bit words of the file, with the carry folded in,
//! plus the length). The header area must have room for one more
//! section header. A program with data after its last section (a
//! signature or a payload) is refused, so `ztk bundle` adds the
//! resources first and the payload of the scripts after them.
//!
//! The version information is a `VS_VERSIONINFO` tree: each node has its
//! length, the length of its value, its type, its key in UTF-16, and
//! padding to 4 bytes, then its value and its children. The strings are
//! in the table `040904b0` (US English, Unicode).
//!
//! An icon comes from a `.ico` file (each image of the file) or from a
//! PNG (one image; Windows reads PNG images in icons since Vista).
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

pub const Icon = struct {
    /// 256 and more is 0 in the headers.
    width: u16,
    height: u16,
    colors: u8 = 0,
    planes: u16 = 1,
    bit_count: u16 = 32,
    /// A PNG file, or a `BITMAPINFOHEADER` and its pixels and mask.
    data: []const u8,
};

pub const Version = struct {
    /// Major, minor, patch, and build.
    file: [4]u16 = .{ 0, 0, 0, 0 },
    product: [4]u16 = .{ 0, 0, 0, 0 },
    company: []const u8 = "",
    description: []const u8 = "",
    product_name: []const u8 = "",
    internal_name: []const u8 = "",
    original_filename: []const u8 = "",
    copyright: []const u8 = "",
};

pub const Resources = struct {
    icons: []const Icon = &.{},
    manifest: ?[]const u8 = null,
    version: ?Version = null,
};

pub const Error = error{ NotPe, NotPe32Plus, NoRoomForSection, DataAfterSections, BadIcon, OutOfMemory };

const RT_ICON = 3;
const RT_GROUP_ICON = 14;
const RT_VERSION = 16;
const RT_MANIFEST = 24;
const lang_en_us = 1033;

fn rd16(b: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, b[at..][0..2], .little);
}
fn rd32(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}
fn wr16(b: []u8, at: usize, v: u16) void {
    std.mem.writeInt(u16, b[at..][0..2], v, .little);
}
fn wr32(b: []u8, at: usize, v: u32) void {
    std.mem.writeInt(u32, b[at..][0..4], v, .little);
}
fn alignUp(v: u32, a: u32) u32 {
    return (v + a - 1) / a * a;
}

/// The images of a `.ico` file. The data slices point into `bytes`.
pub fn iconsFromIco(a: std.mem.Allocator, bytes: []const u8) Error![]Icon {
    if (bytes.len < 6 or rd16(bytes, 0) != 0 or rd16(bytes, 2) != 1) return error.BadIcon;
    const n = rd16(bytes, 4);
    if (n == 0 or bytes.len < 6 + @as(usize, n) * 16) return error.BadIcon;
    const out = try a.alloc(Icon, n);
    for (out, 0..) |*ic, i| {
        const e = bytes[6 + i * 16 ..][0..16];
        const size = rd32(e, 8);
        const off = rd32(e, 12);
        if (@as(u64, off) + size > bytes.len) return error.BadIcon;
        ic.* = .{
            .width = if (e[0] == 0) 256 else e[0],
            .height = if (e[1] == 0) 256 else e[1],
            .colors = e[2],
            .planes = rd16(e, 4),
            .bit_count = rd16(e, 6),
            .data = bytes[off..][0..size],
        };
    }
    return out;
}

/// One image from a PNG file.
pub fn iconFromPng(bytes: []const u8) Error!Icon {
    const sig = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };
    if (bytes.len < 24 or !std.mem.eql(u8, bytes[0..8], &sig) or !std.mem.eql(u8, bytes[12..16], "IHDR")) return error.BadIcon;
    const w = std.mem.readInt(u32, bytes[16..20], .big);
    const h = std.mem.readInt(u32, bytes[20..24], .big);
    if (w == 0 or h == 0 or w > 256 or h > 256) return error.BadIcon;
    return .{ .width = @intCast(w), .height = @intCast(h), .data = bytes };
}

/// A manifest: the name and version of the app, version 6 of the common
/// controls (the look of the file dialogs), per-monitor DPI, Windows 10
/// and 11, long paths, and the UTF-8 code page.
pub fn defaultManifest(a: std.mem.Allocator, name: []const u8, version: [4]u16) Error![]u8 {
    return std.fmt.allocPrint(a,
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
        \\  <assemblyIdentity type="win32" name="{s}" version="{d}.{d}.{d}.{d}"/>
        \\  <dependency>
        \\    <dependentAssembly>
        \\      <assemblyIdentity type="win32" name="Microsoft.Windows.Common-Controls" version="6.0.0.0" processorArchitecture="*" publicKeyToken="6595b64144ccf1df" language="*"/>
        \\    </dependentAssembly>
        \\  </dependency>
        \\  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1">
        \\    <application>
        \\      <supportedOS Id="{{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}}"/>
        \\    </application>
        \\  </compatibility>
        \\  <application xmlns="urn:schemas-microsoft-com:asm.v3">
        \\    <windowsSettings>
        \\      <dpiAware xmlns="http://schemas.microsoft.com/SMI/2005/WindowsSettings">true/pm</dpiAware>
        \\      <dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">PerMonitorV2</dpiAwareness>
        \\      <longPathAware xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">true</longPathAware>
        \\      <activeCodePage xmlns="http://schemas.microsoft.com/SMI/2019/WindowsSettings">UTF-8</activeCodePage>
        \\    </windowsSettings>
        \\  </application>
        \\</assembly>
        \\
    , .{ name, version[0], version[1], version[2], version[3] });
}

const Leaf = struct { kind: u16, id: u16, data: []const u8 };

/// The program `exe` with the resources of `res` in a new section.
pub fn add(a: std.mem.Allocator, exe: []const u8, res: Resources) Error![]u8 {
    if (exe.len < 0x40 or exe[0] != 'M' or exe[1] != 'Z') return error.NotPe;
    const pe = rd32(exe, 0x3c);
    if (@as(u64, pe) + 24 > exe.len or !std.mem.eql(u8, exe[pe..][0..4], "PE\x00\x00")) return error.NotPe;
    const coff = pe + 4;
    const nsec = rd16(exe, coff + 2);
    const opt_size = rd16(exe, coff + 16);
    const opt = coff + 20;
    if (@as(u64, opt) + opt_size > exe.len or opt_size < 112 + 8 * 5 or rd16(exe, opt) != 0x20b) return error.NotPe32Plus;
    const sec_align = rd32(exe, opt + 32);
    const file_align = rd32(exe, opt + 36);
    const headers = rd32(exe, opt + 60);
    const table = opt + opt_size;
    if (table + 40 * (@as(u64, nsec) + 1) > headers) return error.NoRoomForSection;
    var va_end: u32 = 0;
    var raw_end: u32 = headers;
    var first_raw: u32 = std.math.maxInt(u32);
    for (0..nsec) |i| {
        const s = table + i * 40;
        const vsize = @max(rd32(exe, s + 8), rd32(exe, s + 16));
        va_end = @max(va_end, rd32(exe, s + 12) + vsize);
        const raw = rd32(exe, s + 20);
        const raw_size = rd32(exe, s + 16);
        if (raw_size > 0) {
            raw_end = @max(raw_end, raw + raw_size);
            first_raw = @min(first_raw, raw);
        }
    }
    if (table + 40 * (@as(u64, nsec) + 1) > first_raw) return error.NoRoomForSection;
    if (exe.len > raw_end) return error.DataAfterSections;
    const va = alignUp(va_end, sec_align);
    const raw_at = alignUp(raw_end, file_align);

    const data = try tree(a, va, res);
    const raw_size = alignUp(@intCast(data.len), file_align);
    const out = try a.alloc(u8, raw_at + raw_size);
    @memcpy(out[0..exe.len], exe);
    @memset(out[exe.len..raw_at], 0);
    @memcpy(out[raw_at..][0..data.len], data);
    @memset(out[raw_at + data.len ..], 0);

    const s = table + @as(usize, nsec) * 40;
    @memset(out[s..][0..40], 0);
    @memcpy(out[s..][0..5], ".rsrc");
    wr32(out, s + 8, @intCast(data.len));
    wr32(out, s + 12, va);
    wr32(out, s + 16, raw_size);
    wr32(out, s + 20, raw_at);
    // IMAGE_SCN_CNT_INITIALIZED_DATA | IMAGE_SCN_MEM_READ
    wr32(out, s + 36, 0x40000040);
    wr16(out, coff + 2, nsec + 1);
    wr32(out, opt + 8, rd32(out, opt + 8) + raw_size);
    wr32(out, opt + 56, alignUp(va + @as(u32, @intCast(data.len)), sec_align));
    wr32(out, opt + 112 + 2 * 8, va);
    wr32(out, opt + 112 + 2 * 8 + 4, @intCast(data.len));
    wr32(out, opt + 64, 0);
    wr32(out, opt + 64, checksum(out, opt + 64));
    return out;
}

/// The checksum of the optional header, with the field at `at` as 0.
pub fn checksum(b: []const u8, at: usize) u32 {
    var sum: u64 = 0;
    var i: usize = 0;
    while (i + 1 < b.len) : (i += 2) {
        if (i == at or i == at + 2) continue;
        sum += rd16(b, i);
        sum = (sum & 0xffff) + (sum >> 16);
    }
    if (b.len % 2 == 1) {
        sum += b[b.len - 1];
        sum = (sum & 0xffff) + (sum >> 16);
    }
    sum = (sum & 0xffff) + (sum >> 16);
    return @intCast(sum + b.len);
}

/// The bytes of the section at the address `va`.
fn tree(a: std.mem.Allocator, va: u32, res: Resources) Error![]u8 {
    var leaves: std.ArrayList(Leaf) = .empty;
    var group: std.ArrayList(u8) = .empty;
    if (res.icons.len > 0) {
        try group.appendSlice(a, &.{ 0, 0, 1, 0 });
        try group.appendSlice(a, std.mem.asBytes(&std.mem.nativeToLittle(u16, @intCast(res.icons.len))));
        for (res.icons, 0..) |ic, i| {
            const id: u16 = @intCast(i + 1);
            try leaves.append(a, .{ .kind = RT_ICON, .id = id, .data = ic.data });
            var e: [14]u8 = undefined;
            e[0] = if (ic.width >= 256) 0 else @intCast(ic.width);
            e[1] = if (ic.height >= 256) 0 else @intCast(ic.height);
            e[2] = ic.colors;
            e[3] = 0;
            wr16(&e, 4, ic.planes);
            wr16(&e, 6, ic.bit_count);
            wr32(&e, 8, @intCast(ic.data.len));
            wr16(&e, 12, id);
            try group.appendSlice(a, &e);
        }
        try leaves.append(a, .{ .kind = RT_GROUP_ICON, .id = 1, .data = group.items });
    }
    if (res.version) |v| try leaves.append(a, .{ .kind = RT_VERSION, .id = 1, .data = try versionInfo(a, v) });
    if (res.manifest) |m| try leaves.append(a, .{ .kind = RT_MANIFEST, .id = 1, .data = m });

    // The types in order, each with its ids in order. The leaves are
    // already sorted: by type, then by id.
    var types: std.ArrayList(u16) = .empty;
    for (leaves.items) |l| if (types.items.len == 0 or types.items[types.items.len - 1] != l.kind) try types.append(a, l.kind);
    const dir = 16;
    const ent = 8;
    var size: usize = dir + ent * types.items.len;
    const type_dirs = size;
    for (types.items) |k| {
        var n: usize = 0;
        for (leaves.items) |l| n += @intFromBool(l.kind == k);
        size += dir + ent * n;
    }
    const lang_dirs = size;
    size += (dir + ent) * leaves.items.len;
    const entries = size;
    size += 16 * leaves.items.len;
    var data_at: std.ArrayList(usize) = .empty;
    for (leaves.items) |l| {
        size = std.mem.alignForward(usize, size, 8);
        try data_at.append(a, size);
        size += l.data.len;
    }
    const out = try a.alloc(u8, size);
    @memset(out, 0);
    wr16(out, 14, @intCast(types.items.len));
    var td = type_dirs;
    var leaf: usize = 0;
    for (types.items, 0..) |k, ti| {
        wr32(out, dir + ti * ent, k);
        wr32(out, dir + ti * ent + 4, 0x80000000 | @as(u32, @intCast(td)));
        const start = leaf;
        while (leaf < leaves.items.len and leaves.items[leaf].kind == k) leaf += 1;
        wr16(out, td + 14, @intCast(leaf - start));
        for (start..leaf, 0..) |li, j| {
            const ld = lang_dirs + li * (dir + ent);
            wr32(out, td + dir + j * ent, leaves.items[li].id);
            wr32(out, td + dir + j * ent + 4, 0x80000000 | @as(u32, @intCast(ld)));
            wr16(out, ld + 14, 1);
            wr32(out, ld + dir, lang_en_us);
            const de = entries + li * 16;
            wr32(out, ld + dir + 4, @intCast(de));
            wr32(out, de, va + @as(u32, @intCast(data_at.items[li])));
            wr32(out, de + 4, @intCast(leaves.items[li].data.len));
            @memcpy(out[data_at.items[li]..][0..leaves.items[li].data.len], leaves.items[li].data);
        }
        td += dir + ent * (leaf - start);
    }
    return out;
}

/// A `VS_VERSIONINFO` tree.
pub fn versionInfo(a: std.mem.Allocator, v: Version) Error![]u8 {
    var b: std.ArrayList(u8) = .empty;
    const root = try begin(a, &b, "VS_VERSION_INFO", 52, 0);
    var fixed: [52]u8 = @splat(0);
    wr32(&fixed, 0, 0xfeef04bd);
    wr32(&fixed, 4, 0x00010000);
    wr32(&fixed, 8, @as(u32, v.file[0]) << 16 | v.file[1]);
    wr32(&fixed, 12, @as(u32, v.file[2]) << 16 | v.file[3]);
    wr32(&fixed, 16, @as(u32, v.product[0]) << 16 | v.product[1]);
    wr32(&fixed, 20, @as(u32, v.product[2]) << 16 | v.product[3]);
    wr32(&fixed, 24, 0x3f);
    // VOS_NT_WINDOWS32 and VFT_APP
    wr32(&fixed, 32, 0x40004);
    wr32(&fixed, 36, 1);
    try b.appendSlice(a, &fixed);
    const sfi = try begin(a, &b, "StringFileInfo", 0, 1);
    const st = try begin(a, &b, "040904b0", 0, 1);
    var fv: [48]u8 = undefined;
    var pv: [48]u8 = undefined;
    const pairs = [_][2][]const u8{
        .{ "CompanyName", v.company },
        .{ "FileDescription", v.description },
        .{ "FileVersion", std.fmt.bufPrint(&fv, "{d}.{d}.{d}.{d}", .{ v.file[0], v.file[1], v.file[2], v.file[3] }) catch unreachable },
        .{ "InternalName", v.internal_name },
        .{ "LegalCopyright", v.copyright },
        .{ "OriginalFilename", v.original_filename },
        .{ "ProductName", v.product_name },
        .{ "ProductVersion", std.fmt.bufPrint(&pv, "{d}.{d}.{d}.{d}", .{ v.product[0], v.product[1], v.product[2], v.product[3] }) catch unreachable },
    };
    for (pairs) |p| {
        if (p[1].len == 0) continue;
        const w = std.unicode.utf8ToUtf16LeAlloc(a, p[1]) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        const s = try begin(a, &b, p[0], @intCast(w.len + 1), 1);
        try b.appendSlice(a, std.mem.sliceAsBytes(w));
        try b.appendSlice(a, &.{ 0, 0 });
        end(&b, s);
    }
    end(&b, st);
    end(&b, sfi);
    const vfi = try begin(a, &b, "VarFileInfo", 0, 1);
    const tr = try begin(a, &b, "Translation", 4, 0);
    try b.appendSlice(a, &.{ 0x09, 0x04, 0xb0, 0x04 });
    end(&b, tr);
    end(&b, vfi);
    end(&b, root);
    return b.items;
}

/// Starts a node: padding to 4 bytes, the length (patched by `end`),
/// the length of the value, the type, and the key with its padding.
fn begin(a: std.mem.Allocator, b: *std.ArrayList(u8), key: []const u8, value_len: u16, kind: u16) Error!usize {
    while (b.items.len % 4 != 0) try b.append(a, 0);
    const start = b.items.len;
    var head: [6]u8 = undefined;
    wr16(&head, 0, 0);
    wr16(&head, 2, value_len);
    wr16(&head, 4, kind);
    try b.appendSlice(a, &head);
    for (key) |c| try b.appendSlice(a, &.{ c, 0 });
    try b.appendSlice(a, &.{ 0, 0 });
    while (b.items.len % 4 != 0) try b.append(a, 0);
    return start;
}

fn end(b: *std.ArrayList(u8), start: usize) void {
    wr16(b.items, start, @intCast(b.items.len - start));
}

test "peres: the version tree has its lengths and keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try versionInfo(arena.allocator(), .{ .file = .{ 1, 2, 3, 4 }, .product_name = "Demo" });
    try std.testing.expectEqual(@as(usize, v.len), rd16(v, 0));
    try std.testing.expectEqual(@as(u16, 52), rd16(v, 2));
    // The fixed part follows the key "VS_VERSION_INFO" (6 + 32 bytes, padded to 40).
    try std.testing.expectEqual(@as(u32, 0xfeef04bd), rd32(v, 40));
    try std.testing.expectEqual(@as(u32, 0x00010002), rd32(v, 48));
}

test "peres: the images of an ico file and of a png" {
    var ico: [6 + 16 + 4]u8 = @splat(0);
    wr16(&ico, 2, 1);
    wr16(&ico, 4, 1);
    ico[6] = 0;
    ico[7] = 0;
    wr16(&ico, 6 + 6, 32);
    wr32(&ico, 6 + 8, 4);
    wr32(&ico, 6 + 12, 22);
    const list = try iconsFromIco(std.testing.allocator, &ico);
    defer std.testing.allocator.free(list);
    try std.testing.expectEqual(@as(u16, 256), list[0].width);
    try std.testing.expectEqual(@as(usize, 4), list[0].data.len);
    try std.testing.expectError(error.BadIcon, iconsFromIco(std.testing.allocator, "nope"));
    var png = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n', 0, 0, 0, 13, 'I', 'H', 'D', 'R', 0, 0, 0, 48, 0, 0, 0, 48 };
    const p = try iconFromPng(&png);
    try std.testing.expectEqual(@as(u16, 48), p.width);
}

/// The subsystem of a program in its optional header: GUI (2) starts
/// with no console window, and console (3) opens one when no terminal
/// started it. The checksum follows the change.
pub fn setSubsystem(b: []u8, gui: bool) Error!void {
    if (b.len < 0x40 or b[0] != 'M' or b[1] != 'Z') return error.NotPe;
    const pe = rd32(b, 0x3c);
    if (@as(u64, pe) + 24 + 72 > b.len or !std.mem.eql(u8, b[pe..][0..4], "PE\x00\x00")) return error.NotPe;
    const opt = pe + 24;
    if (rd16(b, opt) != 0x20b) return error.NotPe32Plus;
    wr16(b, opt + 68, if (gui) 2 else 3);
    wr32(b, opt + 64, 0);
    wr32(b, opt + 64, checksum(b, opt + 64));
}

/// The subsystem of a program, 2 for GUI and 3 for console, or null.
pub fn subsystem(b: []const u8) ?u16 {
    if (b.len < 0x40) return null;
    const pe = rd32(b, 0x3c);
    if (@as(u64, pe) + 24 + 72 > b.len) return null;
    return rd16(b, pe + 24 + 68);
}
