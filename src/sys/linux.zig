//! The numbers and the structures of the Linux kernel that the direct
//! backend uses. Each one names its kernel header. The backend calls the
//! kernel with system calls only, so these values replace the headers.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

// ---- linux/input.h and linux/input-event-codes.h ----

/// struct input_event (linux/input.h) on a 64-bit system.
pub const InputEvent = extern struct {
    sec: i64,
    usec: i64,
    type: u16,
    code: u16,
    value: i32,
};

/// struct input_absinfo (linux/input.h).
pub const InputAbsinfo = extern struct {
    value: i32,
    minimum: i32,
    maximum: i32,
    fuzz: i32,
    flat: i32,
    resolution: i32,
};

pub const EV_SYN: u16 = 0x00;
pub const EV_KEY: u16 = 0x01;
pub const EV_REL: u16 = 0x02;
pub const EV_ABS: u16 = 0x03;
pub const SYN_REPORT: u16 = 0;
pub const REL_X: u16 = 0x00;
pub const REL_Y: u16 = 0x01;
pub const ABS_X: u16 = 0x00;
pub const ABS_Y: u16 = 0x01;
pub const ABS_MT_POSITION_X: u16 = 0x35;
pub const ABS_MT_POSITION_Y: u16 = 0x36;
pub const BTN_LEFT: u16 = 0x110;
pub const BTN_RIGHT: u16 = 0x111;
pub const BTN_MIDDLE: u16 = 0x112;
pub const BTN_TOUCH: u16 = 0x14a;
pub const KEY_MAX: u16 = 0x2ff;

/// The ioctl request EVIOCGABS(abs) of linux/input.h: read, type 'E', number 0x40 + abs, size 24.
pub fn eviocgabs(abs: u16) u32 {
    const dir_read: u32 = 2;
    return (dir_read << 30) | (@as(u32, @sizeOf(InputAbsinfo)) << 16) | (@as(u32, 'E') << 8) | (0x40 + @as(u32, abs));
}

// ---- linux/kd.h ----

/// KDSETMODE and its values (linux/kd.h).
pub const KDSETMODE: u32 = 0x4B3A;
pub const KDGETMODE: u32 = 0x4B3B;
pub const KD_TEXT: u32 = 0x00;
pub const KD_GRAPHICS: u32 = 0x01;

test "sys: the size of the input structures" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(InputEvent));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(InputAbsinfo));
    // EVIOCGABS(ABS_X) on a 64-bit system, from linux/input.h.
    try std.testing.expectEqual(@as(u32, 0x80184540), eviocgabs(ABS_X));
}

/// Opens a path with a system call and gives the descriptor. The path has at most 255 bytes.
pub fn open(path: []const u8, flags: std.os.linux.O) !i32 {
    var buf: [256]u8 = undefined;
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const rc = std.os.linux.open(@ptrCast(&buf), flags, 0);
    const signed: isize = @bitCast(rc);
    if (signed < 0) return error.OpenFailed;
    return @intCast(rc);
}

/// A pipe with a read end that does not block, for the tests.
pub fn pipeNonblocking() ![2]i32 {
    var fds: [2]i32 = undefined;
    const rc = std.os.linux.pipe2(&fds, .{ .NONBLOCK = true });
    if (@as(isize, @bitCast(rc)) < 0) return error.PipeFailed;
    return fds;
}

/// Writes all bytes to a descriptor with a system call.
pub fn writeAll(fd: i32, bytes: []const u8) !void {
    var done: usize = 0;
    while (done < bytes.len) {
        const rc = std.os.linux.write(fd, bytes[done..].ptr, bytes.len - done);
        const signed: isize = @bitCast(rc);
        if (signed <= 0) return error.WriteFailed;
        done += rc;
    }
}
