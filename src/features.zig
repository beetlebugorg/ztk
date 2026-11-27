//! The features of the ztk build, from `-Ddrop` (see `features_table.zig`).
//!
//! `on(name)` is comptime, so a gate `if (comptime features.on("canvas"))`
//! leaves the code of a dropped widget class out of the binary. `install`
//! gives ztcl the names of the dropped commands, so a call of one gives
//! the error that names the command and the flag that keeps it.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const options = @import("build_options");
const ztcl = @import("ztcl");
const tbl = @import("features_table.zig");

pub const table = tbl.table(ztcl.features.table.Feature);

/// The comma list of `-Ddrop` for ztk, or empty.
pub const drop_list: []const u8 = if (@hasDecl(options, "drop")) options.drop else "";

/// True when the feature `name` is in the build.
pub fn on(comptime name: []const u8) bool {
    _ = comptime tbl.index(name) orelse @compileError("no feature " ++ name);
    return comptime !tbl.listHas(drop_list, name);
}

/// The dropped feature of the command `name`, or null.
fn stripped(name: []const u8) ?[]const u8 {
    for (table) |f| {
        if (!tbl.listHas(drop_list, f.name)) continue;
        for (f.commands) |c| if (std.mem.eql(u8, c, name)) return f.name;
    }
    return null;
}

/// Gives ztcl the dropped commands of ztk. A build with no dropped
/// feature sets nothing.
pub fn install() void {
    if (comptime drop_list.len == 0) return;
    ztcl.features.embedder_stripped = &stripped;
}
