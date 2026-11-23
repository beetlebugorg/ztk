//! The Vulkan output on a display (`VK_KHR_display`). Stage 1 has only
//! the listing of displays and modes. `list` changes no state. The
//! swapchain on a display plane is not part of this stage, and the test
//! on the development machine never makes a display surface, because the
//! compositor of the user owns the displays there. See docs/tasks/BLOCKED.md.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const vulkan = @import("../ztk.zig").vulkan;

pub const Mode = struct { width: u32, height: u32, refresh_mhz: u32 };
pub const DisplayInfo = struct { name: []const u8, modes: []const Mode };

/// The instance extensions that `list` needs.
pub const instance_extensions: []const [*:0]const u8 = &.{ "VK_KHR_surface", "VK_KHR_display" };

/// Lists the displays of a physical device. It changes no state.
pub fn list(gpa: std.mem.Allocator, vk: *vulkan.Vulkan) ![]vulkan.Vulkan.DisplayEntry {
    return vk.displays(gpa);
}

test "vkdisplay: list the displays" {
    if (!@import("build_options").vulkan) {
        std.debug.print("SKIP: the build has no Vulkan renderer\n", .{});
        return;
    }
    const v = vulkan.Vulkan.init(std.testing.allocator, .{ .instance_extensions = instance_extensions }) catch |e| {
        std.debug.print("SKIP: no Vulkan device ({s})\n", .{@errorName(e)});
        return;
    };
    defer v.deinit();
    const found = list(std.testing.allocator, v) catch |e| {
        std.debug.print("no display for Vulkan ({s}) on {s}\n", .{ @errorName(e), v.deviceName() });
        return;
    };
    defer vulkan.Vulkan.freeDisplays(std.testing.allocator, found);
    std.debug.print("vkdisplay: {d} display(s) on {s}\n", .{ found.len, v.deviceName() });
    for (found) |d| std.debug.print("  {s}: {d} mode(s)\n", .{ d.name, d.modes.len });
}
