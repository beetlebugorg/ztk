//! The few calls to the operating system that the core and the headless
//! backend need: a monotonic clock, a sleep, and a write to stderr. Linux
//! uses direct system calls, so the static build links no library. Each
//! other system goes through `std.Io`.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

const is_linux = builtin.os.tag == .linux;

/// Microseconds on a clock that does not go back.
pub fn nowUs() i64 {
    if (is_linux) {
        var ts: linux.timespec = undefined;
        _ = linux.clock_gettime(.MONOTONIC, &ts);
        return @as(i64, ts.sec) * 1_000_000 + @divFloor(@as(i64, ts.nsec), 1000);
    }
    return std.Io.Clock.awake.now(std.Options.debug_io).toMicroseconds();
}

/// Waits for a count of microseconds.
pub fn sleepUs(us: i64) void {
    if (us <= 0) return;
    if (is_linux) {
        const req: linux.timespec = .{ .sec = @intCast(@divFloor(us, 1_000_000)), .nsec = @intCast(@mod(us, 1_000_000) * 1000) };
        _ = linux.nanosleep(&req, null);
        return;
    }
    std.Options.debug_io.sleep(.fromMicroseconds(us), .awake) catch {};
}

/// Writes text to the standard error stream.
pub fn writeStderr(text: []const u8) void {
    if (is_linux) {
        _ = linux.write(2, text.ptr, text.len);
        return;
    }
    std.Io.File.stderr().writeStreamingAll(std.Options.debug_io, text) catch {};
}

test "host: the clock moves forward across a sleep" {
    const a = nowUs();
    sleepUs(2000);
    try std.testing.expect(nowUs() - a >= 2000);
}
