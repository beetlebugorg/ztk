//! The direct backend on a system that is not Linux. It has the types of
//! `direct.zig`, and `init` always gives an error, because the framebuffer
//! and the event devices are Linux interfaces.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const plat = @import("platform.zig");
const touch = @import("touch.zig");
const console = @import("console_off.zig");

pub const Output = enum { auto, vulkan, framebuffer };

pub const Options = struct {
    output: Output = .auto,
    fb_device: []const u8 = "",
    rotation: ?touch.Rotation = null,
    scale: f32 = 1,
    touch_debounce_ms: u32 = 0,
    session: console.Session = .{},
    tty: ?[]const u8 = null,
    unsafe_test_device: bool = false,
};

pub const Direct = struct {
    frames: u64 = 0,
    rows_sum: u64 = 0,

    pub fn init(_: std.mem.Allocator, _: Options) !*Direct {
        return error.DirectNeedsLinux;
    }

    pub fn deinit(_: *Direct) void {}

    pub fn platform(_: *Direct) plat.Platform {
        unreachable;
    }

    pub fn outputName(_: *const Direct) []const u8 {
        return "none";
    }
};
