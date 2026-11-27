//! The Vulkan renderer that the build option `-Dvulkan=false` leaves
//! out. `init` always gives `error.NoVulkan`, so the program uses the CPU
//! renderer. The file has no C import and no library.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

pub const available = false;

/// The cause of `error.NoVulkan`.
pub fn reason() []const u8 {
    return "the build has no Vulkan renderer";
}

pub const Options = struct {
    device_index: ?u32 = null,
    library_name: []const u8 = "libvulkan.so.1",
    validate: bool = false,
};

pub const Vulkan = struct {
    pub fn init(_: std.mem.Allocator, _: Options) !*Vulkan {
        return error.NoVulkan;
    }
    pub fn deinit(_: *Vulkan) void {}
};
