//! The framebuffer output of the direct backend. `present` takes an
//! upright RGBA image and writes only the rows that changed since the
//! last call. It converts each pixel to the format of the panel (RGB565
//! or XRGB8888) and maps it through the rotation: for 90 and 270 degrees
//! a row of the image is a column of the panel. The last image stays in
//! the object, so `present` allocates nothing. `open` reads the visible
//! mode from the device itself with `FBIOGET_VSCREENINFO` and
//! `FBIOGET_FSCREENINFO`, so the numbers and the mapping belong to one
//! device. The panel is the visible part (`xres` by `yres`) at the pan
//! offset, inside a larger virtual area. A `Host` makes the system calls,
//! so a test uses a fake. `initMemory` uses a buffer in memory for the
//! tests. The text console is in console.zig.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const linux = std.os.linux;
const sys = @import("../sys/linux.zig");
const renderer = @import("../render/renderer.zig");
const Image = renderer.Image;

pub const Rotation = @import("touch.zig").Rotation;
pub const Format = enum { rgb565, xrgb8888 };

/// The largest width or height of a panel in pixels.
const max_side: u32 = 16384;

const FBIOGET_VSCREENINFO: u32 = 0x4600;
const FBIOGET_FSCREENINFO: u32 = 0x4602;

const Bitfield = extern struct { offset: u32, length: u32, msb_right: u32 };

/// `struct fb_var_screeninfo` of linux/fb.h.
pub const VarInfo = extern struct {
    xres: u32 = 0,
    yres: u32 = 0,
    xres_virtual: u32 = 0,
    yres_virtual: u32 = 0,
    xoffset: u32 = 0,
    yoffset: u32 = 0,
    bits_per_pixel: u32 = 0,
    grayscale: u32 = 0,
    red: Bitfield = .{ .offset = 0, .length = 0, .msb_right = 0 },
    green: Bitfield = .{ .offset = 0, .length = 0, .msb_right = 0 },
    blue: Bitfield = .{ .offset = 0, .length = 0, .msb_right = 0 },
    transp: Bitfield = .{ .offset = 0, .length = 0, .msb_right = 0 },
    rest: [20]u32 = @splat(0),
};

/// `struct fb_fix_screeninfo` of linux/fb.h.
pub const FixInfo = extern struct {
    id: [16]u8 = @splat(0),
    smem_start: c_ulong = 0,
    smem_len: u32 = 0,
    type: u32 = 0,
    type_aux: u32 = 0,
    visual: u32 = 0,
    xpanstep: u16 = 0,
    ypanstep: u16 = 0,
    ywrapstep: u16 = 0,
    line_length: u32 = 0,
    mmio_start: c_ulong = 0,
    mmio_len: u32 = 0,
    accel: u32 = 0,
    capabilities: u16 = 0,
    reserved: [2]u16 = @splat(0),
};

comptime {
    std.debug.assert(@sizeOf(VarInfo) == 160);
    if (@sizeOf(c_ulong) == 8) std.debug.assert(@sizeOf(FixInfo) == 80);
}

/// The system calls of `open`. `real_host` makes the real ones.
pub const Host = struct {
    ctx: ?*anyopaque = null,
    open: *const fn (ctx: ?*anyopaque, path: []const u8) ?i32,
    varInfo: *const fn (ctx: ?*anyopaque, fd: i32, out: *VarInfo) bool,
    fixInfo: *const fn (ctx: ?*anyopaque, fd: i32, out: *FixInfo) bool,
    map: *const fn (ctx: ?*anyopaque, fd: i32, len: usize) ?[]u8,
    unmap: *const fn (ctx: ?*anyopaque, mem: []u8) void,
    close: *const fn (ctx: ?*anyopaque, fd: i32) void,
};

fn realOpen(_: ?*anyopaque, path: []const u8) ?i32 {
    return sys.open(path, .{ .ACCMODE = .RDWR }) catch null;
}

fn realVar(_: ?*anyopaque, fd: i32, out: *VarInfo) bool {
    return linux.ioctl(fd, FBIOGET_VSCREENINFO, @intFromPtr(out)) == 0;
}

fn realFix(_: ?*anyopaque, fd: i32, out: *FixInfo) bool {
    return linux.ioctl(fd, FBIOGET_FSCREENINFO, @intFromPtr(out)) == 0;
}

fn realMap(_: ?*anyopaque, fd: i32, len: usize) ?[]u8 {
    return std.posix.mmap(null, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0) catch null;
}

fn realUnmap(_: ?*anyopaque, mem: []u8) void {
    std.posix.munmap(@alignCast(mem));
}

fn realClose(_: ?*anyopaque, fd: i32) void {
    _ = linux.close(fd);
}

pub const real_host: Host = .{ .open = realOpen, .varInfo = realVar, .fixInfo = realFix, .map = realMap, .unmap = realUnmap, .close = realClose };

/// The visible panel inside the memory of the device.
pub const Layout = struct { width: u32, height: u32, stride: u32, format: Format, offset: usize, map_len: usize };

fn channel(b: Bitfield, offset: u32, length: u32) bool {
    return b.offset == offset and b.length == length and b.msb_right == 0;
}

/// Checks the numbers of the device. Each one can be wrong, so the result
/// never reaches outside the memory of the device.
pub fn layoutOf(v: VarInfo, f: FixInfo) error{ BadFramebuffer, UnsupportedDepth }!Layout {
    const format: Format = switch (v.bits_per_pixel) {
        16 => if (channel(v.red, 11, 5) and channel(v.green, 5, 6) and channel(v.blue, 0, 5)) .rgb565 else return error.UnsupportedDepth,
        32 => if (channel(v.red, 16, 8) and channel(v.green, 8, 8) and channel(v.blue, 0, 8)) .xrgb8888 else return error.UnsupportedDepth,
        else => return error.UnsupportedDepth,
    };
    const bytes: u64 = v.bits_per_pixel / 8;
    if (v.xres == 0 or v.yres == 0 or v.xres > max_side or v.yres > max_side) return error.BadFramebuffer;
    if (@as(u64, v.xoffset) + v.xres > v.xres_virtual or @as(u64, v.yoffset) + v.yres > v.yres_virtual) return error.BadFramebuffer;
    if (f.line_length < v.xres * bytes or f.line_length > max_side * 4) return error.BadFramebuffer;
    const offset = @as(u64, v.yoffset) * f.line_length + @as(u64, v.xoffset) * bytes;
    const end = offset + @as(u64, v.yres) * f.line_length;
    if (end > f.smem_len) return error.BadFramebuffer;
    return .{ .width = v.xres, .height = v.yres, .stride = f.line_length, .format = format, .offset = @intCast(offset), .map_len = @intCast(end) };
}

pub const Fbdev = struct {
    gpa: std.mem.Allocator,
    mem: []u8,
    /// The panel size in pixels, and the bytes in one panel row.
    width: u32,
    height: u32,
    stride: u32,
    format: Format,
    rotation: Rotation,
    /// The last image that `present` wrote.
    prev: []u8,
    have_prev: bool = false,
    /// The mapping of a real device and the host that unmaps it. `mem` is a part of it.
    mapping: ?[]u8 = null,
    host: *const Host = &real_host,

    /// For tests: a framebuffer in memory.
    pub fn initMemory(gpa: std.mem.Allocator, mem: []u8, width: u32, height: u32, stride: u32, format: Format, rotation: Rotation) !*Fbdev {
        // The sizes can come from a sysfs file, so a wrong value must not cause a write outside `mem`.
        const bytes: u64 = if (format == .rgb565) 2 else 4;
        if (width == 0 or height == 0 or width > max_side or height > max_side) return error.BadFramebuffer;
        if (@as(u64, stride) < @as(u64, width) * bytes) return error.BadFramebuffer;
        if (@as(u64, stride) * height > mem.len) return error.BadFramebuffer;
        const f = try gpa.create(Fbdev);
        errdefer gpa.destroy(f);
        const prev = try gpa.alloc(u8, @as(usize, width) * height * 4);
        f.* = .{ .gpa = gpa, .mem = mem, .width = width, .height = height, .stride = stride, .format = format, .rotation = rotation, .prev = prev };
        return f;
    }

    /// Opens a framebuffer device, for example `/dev/fb0`. Each number comes from the
    /// open device. On an error the mapping and the descriptor are closed.
    pub fn open(gpa: std.mem.Allocator, device: []const u8, rotation: ?Rotation, host: *const Host) !*Fbdev {
        const fd = host.open(host.ctx, device) orelse return error.OpenFailed;
        defer host.close(host.ctx, fd);
        var v: VarInfo = .{};
        var x: FixInfo = .{};
        if (!host.varInfo(host.ctx, fd, &v) or !host.fixInfo(host.ctx, fd, &x)) return error.NotFramebuffer;
        const l = try layoutOf(v, x);
        const map = host.map(host.ctx, fd, l.map_len) orelse return error.MapFailed;
        errdefer host.unmap(host.ctx, map);
        // A wide panel turns by 270 degrees, as the task says; a tall panel does not turn.
        const rot = rotation orelse if (l.width > l.height) Rotation.r270 else Rotation.r0;
        const f = try initMemory(gpa, map[l.offset..], l.width, l.height, l.stride, l.format, rot);
        f.mapping = map;
        f.host = host;
        return f;
    }

    /// The size of the upright image that the renderer draws.
    pub fn imageSize(f: *const Fbdev) [2]u32 {
        return switch (f.rotation) {
            .r0, .r180 => .{ f.width, f.height },
            .r90, .r270 => .{ f.height, f.width },
        };
    }

    pub fn close(f: *Fbdev) void {
        if (f.mapping) |m| f.host.unmap(f.host.ctx, m);
        f.gpa.free(f.prev);
        f.gpa.destroy(f);
    }

    inline fn writePixel(f: *Fbdev, px: u32, py: u32, r: u8, g: u8, b: u8) void {
        const bpp: u32 = if (f.format == .rgb565) 2 else 4;
        const off = @as(usize, py) * f.stride + @as(usize, px) * bpp;
        switch (f.format) {
            .xrgb8888 => {
                f.mem[off] = b;
                f.mem[off + 1] = g;
                f.mem[off + 2] = r;
                f.mem[off + 3] = 0xff;
            },
            .rgb565 => {
                const v: u16 = (@as(u16, r >> 3) << 11) | (@as(u16, g >> 2) << 5) | (b >> 3);
                std.mem.writeInt(u16, f.mem[off..][0..2], v, .little);
            },
        }
    }

    /// The panel place of an image pixel.
    inline fn place(f: *const Fbdev, x: u32, y: u32) [2]u32 {
        return switch (f.rotation) {
            .r0 => .{ x, y },
            .r180 => .{ f.width - 1 - x, f.height - 1 - y },
            .r90 => .{ f.width - 1 - y, x },
            .r270 => .{ y, f.height - 1 - x },
        };
    }

    /// Converts the changed rows of an image to the format and the rotation of the panel
    /// and writes them to the panel memory. Returns the count of rows that it wrote.
    pub fn present(f: *Fbdev, img: Image) u32 {
        std.debug.assert(img.width == f.imageSize()[0] and img.height == f.imageSize()[1]);
        const stride: usize = @as(usize, img.width) * 4;
        var written: u32 = 0;
        var y: u32 = 0;
        while (y < img.height) : (y += 1) {
            const row = img.pixels[y * stride ..][0..stride];
            const old = f.prev[y * stride ..][0..stride];
            if (f.have_prev and std.mem.eql(u8, row, old)) continue;
            var x: u32 = 0;
            while (x < img.width) : (x += 1) {
                const p = row[x * 4 ..][0..4];
                const at = f.place(x, y);
                f.writePixel(at[0], at[1], p[0], p[1], p[2]);
            }
            @memcpy(old, row);
            written += 1;
        }
        f.have_prev = true;
        return written;
    }
};

const t = std.testing;

fn solid(w: u32, h: u32, rgb: [3]u8) !Image {
    const px = try t.allocator.alloc(u8, @as(usize, w) * h * 4);
    var i: usize = 0;
    while (i < px.len) : (i += 4) {
        px[i] = rgb[0];
        px[i + 1] = rgb[1];
        px[i + 2] = rgb[2];
        px[i + 3] = 255;
    }
    return .{ .width = w, .height = h, .pixels = px };
}

test "fbdev: a red pixel in 32 bits" {
    var mem: [8 * 4 * 4]u8 = @splat(0);
    const f = try Fbdev.initMemory(t.allocator, &mem, 8, 4, 32, .xrgb8888, .r0);
    defer f.close();
    var img = try solid(8, 4, .{ 0, 0, 0 });
    defer t.allocator.free(img.pixels);
    img.pixels[(1 * 8 + 2) * 4] = 255;
    try t.expectEqual(@as(u32, 4), f.present(img));
    try t.expectEqualSlices(u8, &.{ 0, 0, 0xff, 0xff }, mem[32 + 8 ..][0..4]);
}

test "fbdev: RGB565 white and red" {
    var mem: [4 * 2 * 2]u8 = @splat(0);
    const f = try Fbdev.initMemory(t.allocator, &mem, 4, 2, 8, .rgb565, .r0);
    defer f.close();
    var img = try solid(4, 2, .{ 255, 255, 255 });
    defer t.allocator.free(img.pixels);
    img.pixels[4] = 255;
    img.pixels[5] = 0;
    img.pixels[6] = 0;
    _ = f.present(img);
    try t.expectEqualSlices(u8, &.{ 0xff, 0xff }, mem[0..2]);
    try t.expectEqualSlices(u8, &.{ 0x00, 0xf8 }, mem[2..4]);
}

fn markAt(rot: Rotation, pw: u32, ph: u32, x: u32, y: u32, want_x: u32, want_y: u32) !void {
    const mem = try t.allocator.alloc(u8, @as(usize, pw) * ph * 4);
    defer t.allocator.free(mem);
    @memset(mem, 0);
    const f = try Fbdev.initMemory(t.allocator, mem, pw, ph, pw * 4, .xrgb8888, rot);
    defer f.close();
    const size = f.imageSize();
    var img = try solid(size[0], size[1], .{ 0, 0, 0 });
    defer t.allocator.free(img.pixels);
    const at = (y * size[0] + x) * 4;
    img.pixels[at] = 255;
    img.pixels[at + 1] = 255;
    img.pixels[at + 2] = 255;
    _ = f.present(img);
    const off = (want_y * pw + want_x) * 4;
    try t.expectEqual(@as(u8, 255), mem[off + 2]);
    // Exactly one pixel is white.
    var white: u32 = 0;
    var i: usize = 0;
    while (i < mem.len) : (i += 4) {
        if (mem[i + 2] == 255) white += 1;
    }
    try t.expectEqual(@as(u32, 1), white);
}

test "fbdev: the rotations" {
    // A panel of 800 by 480 and r270: the image is 480 by 800.
    try markAt(.r270, 800, 480, 0, 0, 0, 479);
    try markAt(.r90, 800, 480, 0, 0, 799, 0);
    // A tall panel with r180: the pixel (0, 0) is the last pixel.
    try markAt(.r180, 480, 800, 0, 0, 479, 799);
}

test "fbdev: a second present writes only the changed rows" {
    var mem: [8 * 4 * 4]u8 = @splat(0);
    const f = try Fbdev.initMemory(t.allocator, &mem, 8, 4, 32, .xrgb8888, .r0);
    defer f.close();
    var img = try solid(8, 4, .{ 10, 20, 30 });
    defer t.allocator.free(img.pixels);
    _ = f.present(img);
    // A byte of another row, changed by hand, stays.
    mem[3 * 32 + 1] = 0x77;
    img.pixels[(1 * 8 + 5) * 4] = 99;
    try t.expectEqual(@as(u32, 1), f.present(img));
    try t.expectEqual(@as(u8, 0x77), mem[3 * 32 + 1]);
    // No change writes nothing.
    try t.expectEqual(@as(u32, 0), f.present(img));
}

test "fbdev: present allocates no memory" {
    var mem: [8 * 4 * 4]u8 = @splat(0);
    const f = try Fbdev.initMemory(t.allocator, &mem, 8, 4, 32, .xrgb8888, .r0);
    defer f.close();
    var img = try solid(8, 4, .{ 1, 2, 3 });
    defer t.allocator.free(img.pixels);
    // The allocator of the object is the testing allocator. A change of it to a failing one proves the claim.
    f.gpa = t.failing_allocator;
    _ = f.present(img);
    img.pixels[0] = 50;
    _ = f.present(img);
    f.gpa = t.allocator;
}

test "fbdev: sizes that do not fit the memory are an error" {
    var mem: [64]u8 = @splat(0);
    // The stride is smaller than a row.
    try t.expectError(error.BadFramebuffer, Fbdev.initMemory(t.allocator, &mem, 8, 2, 16, .xrgb8888, .r0));
    // The memory is smaller than the stride times the height.
    try t.expectError(error.BadFramebuffer, Fbdev.initMemory(t.allocator, &mem, 4, 8, 16, .xrgb8888, .r0));
    try t.expectError(error.BadFramebuffer, Fbdev.initMemory(t.allocator, &mem, 0, 2, 16, .xrgb8888, .r0));
    try t.expectError(error.BadFramebuffer, Fbdev.initMemory(t.allocator, &mem, 100000, 1, 400000, .xrgb8888, .r0));
    const f = try Fbdev.initMemory(t.allocator, &mem, 4, 4, 16, .xrgb8888, .r0);
    f.close();
}

// ---- `open` with a fake device. No test opens a real framebuffer. ----

const FakeFb = struct {
    v: VarInfo,
    x: FixInfo,
    mem: []u8,
    opened: u32 = 0,
    closed: u32 = 0,
    maps: u32 = 0,
    unmaps: u32 = 0,
    map_len: usize = 0,

    fn host(f: *FakeFb) Host {
        return .{ .ctx = f, .open = fOpen, .varInfo = fVar, .fixInfo = fFix, .map = fMap, .unmap = fUnmap, .close = fClose };
    }
    fn me(c: ?*anyopaque) *FakeFb {
        return @ptrCast(@alignCast(c.?));
    }
    fn fOpen(c: ?*anyopaque, _: []const u8) ?i32 {
        me(c).opened += 1;
        return 7;
    }
    fn fVar(c: ?*anyopaque, _: i32, out: *VarInfo) bool {
        out.* = me(c).v;
        return true;
    }
    fn fFix(c: ?*anyopaque, _: i32, out: *FixInfo) bool {
        out.* = me(c).x;
        return true;
    }
    fn fMap(c: ?*anyopaque, _: i32, len: usize) ?[]u8 {
        const f = me(c);
        f.maps += 1;
        f.map_len = len;
        return f.mem[0..len];
    }
    fn fUnmap(c: ?*anyopaque, _: []u8) void {
        me(c).unmaps += 1;
    }
    fn fClose(c: ?*anyopaque, _: i32) void {
        me(c).closed += 1;
    }
};

fn xrgbInfo(xres: u32, yres: u32, vx: u32, vy: u32, xoff: u32, yoff: u32, line: u32, smem: u32) struct { VarInfo, FixInfo } {
    return .{
        .{ .xres = xres, .yres = yres, .xres_virtual = vx, .yres_virtual = vy, .xoffset = xoff, .yoffset = yoff, .bits_per_pixel = 32, .red = .{ .offset = 16, .length = 8, .msb_right = 0 }, .green = .{ .offset = 8, .length = 8, .msb_right = 0 }, .blue = .{ .offset = 0, .length = 8, .msb_right = 0 } },
        .{ .line_length = line, .smem_len = smem },
    };
}

test "fbdev: the panel is the visible part at the pan offset of a larger virtual area" {
    // 4 by 2 visible, in a virtual area of 4 by 6, panned to row 3.
    const info = xrgbInfo(4, 2, 4, 6, 0, 3, 16, 96);
    var mem: [96]u8 = @splat(0);
    var fake: FakeFb = .{ .v = info[0], .x = info[1], .mem = &mem };
    const h = fake.host();
    const f = try Fbdev.open(t.allocator, "/fake/fb0", .r0, &h);
    var open_now = true;
    // A failed check still frees, because a leak report in Debug takes minutes.
    defer if (open_now) f.close();
    try t.expectEqual(@as(u32, 4), f.width);
    try t.expectEqual(@as(u32, 2), f.height);
    const img = try solid(4, 2, .{ 255, 0, 0 });
    defer t.allocator.free(img.pixels);
    _ = f.present(img);
    // Row 3 of the device has the first pixel. Row 2 stays black.
    try t.expectEqual(@as(u8, 255), mem[3 * 16 + 2]);
    try t.expectEqual(@as(u8, 0), mem[2 * 16 + 2]);
    try t.expectEqual(@as(u8, 0), mem[5 * 16 + 2]);
    open_now = false;
    f.close();
    try t.expectEqual(@as(u32, 1), fake.unmaps);
    try t.expectEqual(fake.opened, fake.closed);
}

test "fbdev: open frees the mapping when the image memory fails" {
    const info = xrgbInfo(4, 2, 4, 2, 0, 0, 16, 32);
    var mem: [32]u8 = @splat(0);
    var fake: FakeFb = .{ .v = info[0], .x = info[1], .mem = &mem };
    const h = fake.host();
    var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    try t.expectError(error.OutOfMemory, Fbdev.open(failing.allocator(), "/fake/fb0", .r0, &h));
    try t.expectEqual(fake.maps, fake.unmaps);
    try t.expectEqual(fake.opened, fake.closed);
}

test "fbdev: device numbers that reach outside its memory are refused" {
    const cases = [_]struct { VarInfo, FixInfo }{
        xrgbInfo(4, 2, 4, 2, 0, 0, 16, 31),
        xrgbInfo(4, 2, 4, 4, 0, 3, 16, 64),
        xrgbInfo(4, 2, 3, 2, 0, 0, 16, 64),
        xrgbInfo(4, 2, 4, 2, 0, 0, 15, 64),
        xrgbInfo(0, 2, 4, 2, 0, 0, 16, 64),
        xrgbInfo(4, 2, 4, 2, 0xffffffff, 0, 16, 64),
    };
    for (cases) |c| try t.expectError(error.BadFramebuffer, layoutOf(c[0], c[1]));
}
