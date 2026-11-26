//! A test of `peres.zig` with the loader of Windows: the test adds an
//! icon, a manifest, and the version to a copy of the test program, and
//! reads them back with `FindResourceW`, `LoadImageW`, and
//! `VerQueryValueW`. It loads the copy as data, so no code of it runs.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const peres = @import("../peres.zig");
const t = std.testing;

const HMODULE = *opaque {};
extern "kernel32" fn LoadLibraryExW(name: [*:0]const u16, file: ?*anyopaque, flags: u32) callconv(.winapi) ?HMODULE;
extern "kernel32" fn FreeLibrary(h: HMODULE) callconv(.winapi) i32;
extern "kernel32" fn FindResourceW(h: HMODULE, name: usize, kind: usize) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn SizeofResource(h: HMODULE, res: *anyopaque) callconv(.winapi) u32;
extern "user32" fn LoadImageW(h: HMODULE, name: usize, kind: u32, cx: i32, cy: i32, flags: u32) callconv(.winapi) ?*anyopaque;
extern "user32" fn DestroyIcon(h: *anyopaque) callconv(.winapi) i32;
extern "version" fn GetFileVersionInfoSizeW(name: [*:0]const u16, handle: ?*u32) callconv(.winapi) u32;
extern "version" fn GetFileVersionInfoW(name: [*:0]const u16, handle: u32, len: u32, data: [*]u8) callconv(.winapi) i32;
extern "version" fn VerQueryValueW(block: [*]const u8, sub: [*:0]const u16, out: *?*anyopaque, len: *u32) callconv(.winapi) i32;

/// A 16 by 16 icon of 32 bits: the header, the pixels, and the mask.
fn bmpIcon(a: std.mem.Allocator) ![]u8 {
    const out = try a.alloc(u8, 40 + 16 * 16 * 4 + 16 * 4);
    @memset(out, 0);
    std.mem.writeInt(u32, out[0..4], 40, .little);
    std.mem.writeInt(i32, out[4..8], 16, .little);
    std.mem.writeInt(i32, out[8..12], 32, .little);
    std.mem.writeInt(u16, out[12..14], 1, .little);
    std.mem.writeInt(u16, out[14..16], 32, .little);
    var i: usize = 40;
    while (i < 40 + 16 * 16 * 4) : (i += 4) @memcpy(out[i..][0..4], &[_]u8{ 0x38, 0x34, 0xd1, 0xff });
    return out;
}

test "peres: the loader of Windows reads the icon, the manifest, and the version" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const self_path = try std.process.executablePathAlloc(t.io, a);
    const exe = try std.Io.Dir.cwd().readFileAlloc(t.io, self_path, a, .limited(512 << 20));
    const manifest = try peres.defaultManifest(a, "ztk.test.app", .{ 1, 2, 3, 0 });
    const out = try peres.add(a, exe, .{
        .icons = &.{.{ .width = 16, .height = 16, .data = try bmpIcon(a) }},
        .manifest = manifest,
        .version = .{ .file = .{ 1, 2, 3, 0 }, .product = .{ 1, 2, 0, 0 }, .product_name = "Ztk Test", .description = "A test of the resources" },
    });
    // The checksum of the copy is the checksum of its bytes.
    const pe = std.mem.readInt(u32, out[0x3c..][0..4], .little);
    const at = pe + 24 + 64;
    try t.expectEqual(peres.checksum(out, at), std.mem.readInt(u32, out[at..][0..4], .little));
    const path = ".zig-cache/peres-test.exe";
    try std.Io.Dir.cwd().writeFile(t.io, .{ .sub_path = path, .data = out });
    defer std.Io.Dir.cwd().deleteFile(t.io, path) catch {};
    const wpath = try std.unicode.utf8ToUtf16LeAllocZ(a, path);
    // LOAD_LIBRARY_AS_DATAFILE | LOAD_LIBRARY_AS_IMAGE_RESOURCE
    const h = LoadLibraryExW(wpath, null, 0x2 | 0x20) orelse return error.LoadFailed;
    defer _ = FreeLibrary(h);
    const m = FindResourceW(h, 1, 24) orelse return error.NoManifest;
    try t.expectEqual(@as(u32, @intCast(manifest.len)), SizeofResource(h, m));
    // IMAGE_ICON, LR_DEFAULTCOLOR
    const icon = LoadImageW(h, 1, 1, 16, 16, 0) orelse return error.NoIcon;
    _ = DestroyIcon(icon);
    const size = GetFileVersionInfoSizeW(wpath, null);
    try t.expect(size > 0);
    const block = try a.alignedAlloc(u8, .@"8", size);
    try t.expect(GetFileVersionInfoW(wpath, 0, size, block.ptr) != 0);
    var ptr: ?*anyopaque = null;
    var len: u32 = 0;
    try t.expect(VerQueryValueW(block.ptr, std.unicode.utf8ToUtf16LeStringLiteral("\\StringFileInfo\\040904b0\\ProductName"), &ptr, &len) != 0);
    const name: [*]const u16 = @ptrCast(@alignCast(ptr.?));
    try t.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("Ztk Test"), name[0 .. len - 1]);
    try t.expect(VerQueryValueW(block.ptr, std.unicode.utf8ToUtf16LeStringLiteral("\\"), &ptr, &len) != 0);
    const fixed: [*]const u32 = @ptrCast(@alignCast(ptr.?));
    try t.expectEqual(@as(u32, 0xfeef04bd), fixed[0]);
    try t.expectEqual(@as(u32, 0x00010002), fixed[2]);
}

test "peres: a file that is not a program is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectError(error.NotPe, peres.add(arena.allocator(), "not a program", .{}));
}
