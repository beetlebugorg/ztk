//! The console on a system that is not Linux: it has no state to restore.
//! SPDX-License-Identifier: BSD-2-Clause

pub const Session = struct {
    wayland_display: ?[]const u8 = null,
    x_display: ?[]const u8 = null,
    session_type: ?[]const u8 = null,
};

pub fn restoreNow() void {}
