//! The features of ztk for a stripped build (`ztk bundle --strip`).
//!
//! A feature is a widget class or a group of commands that the build can
//! leave out with `-Ddrop=NAME`. The list of `-Ddrop` can also name the
//! features of ztcl (src/features_table.zig of ztcl): build.zig passes
//! those to the ztcl dependency.
//!
//! The file has no imports. `table(Feature)` gives the table with the
//! `Feature` type of ztcl, so build.zig (with the type of the build.zig
//! of ztcl) and the program (with `ztcl.features.table.Feature`) use
//! the same entries.
//!
//! SPDX-License-Identifier: BSD-2-Clause

pub fn table(comptime Feature: type) [names.len]Feature {
    return .{
        .{ .name = "text", .kind = .commands, .commands = &.{"text"} },
        .{ .name = "terminal", .kind = .commands, .commands = &.{"ztk::terminal"}, .needs = &.{"vt"} },
        .{ .name = "canvas", .kind = .commands, .commands = &.{"canvas"} },
        .{ .name = "treeview", .kind = .commands, .commands = &.{"ttk::treeview"} },
        .{ .name = "notebook", .kind = .commands, .commands = &.{"ttk::notebook"} },
    };
}

/// The names of the features, in the order of `table`.
pub const names = [_][]const u8{ "text", "terminal", "canvas", "treeview", "notebook" };

/// The index of the feature `name`, or null.
pub fn index(name: []const u8) ?usize {
    for (names, 0..) |n, i| {
        if (eql(n, name)) return i;
    }
    return null;
}

/// Gives true when the comma list `list` has `name`.
pub fn listHas(list: []const u8, name: []const u8) bool {
    var at: usize = 0;
    while (at <= list.len) {
        var end = at;
        while (end < list.len and list[end] != ',') end += 1;
        if (eql(list[at..end], name)) return true;
        at = end + 1;
    }
    return false;
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}
