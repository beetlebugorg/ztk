//! The Metal renderer of a build with no AppKit backend: on another
//! system, or for a macOS target built from another system. `init` always
//! gives `error.NoMetal`, so the program uses the CPU renderer.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

pub const available = false;

pub const Options = struct {};

pub const Metal = struct {
    pub fn init(_: std.mem.Allocator, _: Options) !*Metal {
        return error.NoMetal;
    }
    pub fn deinit(_: *Metal) void {}
};
