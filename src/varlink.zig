//! Links between a widget and a global Tcl variable, for options such as
//! `-variable`. A link is a write trace with the script `command path`,
//! where `command` is a native command of `::ztk::priv`. The name is the
//! global name, as Tk reads it. The trace goes through the native
//! `trace` command, so a script that renames `trace` does not change it.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const widget = @import("widget.zig");
const Widget = widget.Widget;
const Value = ztcl.Value;

fn words(w: *const Widget, name: []const u8, command: []const u8, verb: []const u8) [6]Value {
    const a = w.app.it.alloc();
    const script = widget.traceScript(a, command, w.path);
    return .{ .{ .str = "trace" }, .{ .str = verb }, .{ .str = "variable" }, .{ .str = name }, .{ .str = "write" }, .{ .str = script } };
}

/// Adds the write trace of a link.
pub fn add(w: *Widget, name: []const u8, command: []const u8) ztcl.Error!void {
    if (name.len == 0) return;
    const ws = words(w, name, command, "add");
    _ = try w.app.callTrace(&ws);
}

/// Removes the write trace of a link. An error is ignored.
pub fn remove(w: *Widget, name: []const u8, command: []const u8) void {
    if (name.len == 0) return;
    const ws = words(w, name, command, "remove");
    _ = w.app.callTrace(&ws) catch {};
}

/// The value of the variable, as a copy in the arena of the interpreter, or null.
pub fn read(w: *Widget, name: []const u8) ?[]const u8 {
    const it = w.app.it;
    if (name.len == 0) return null;
    const copy = it.alloc().dupe(u8, name) catch return null;
    const v = (it.getVarOpt(copy) catch null) orelse return null;
    const s = it.str(v) catch return null;
    return it.alloc().dupe(u8, s) catch null;
}

/// Sets the variable. Its traces run, and they can delete the widget.
pub fn write(w: *Widget, name: []const u8, value: []const u8) ztcl.Error!void {
    const it = w.app.it;
    if (name.len == 0) return;
    const n = try it.alloc().dupe(u8, name);
    const v = try it.alloc().dupe(u8, value);
    _ = try it.setVar(n, .{ .str = v });
}

/// Changes the name of a link. `slot` holds the owned global name.
/// The trace moves to the new variable.
pub fn rename(w: *Widget, slot: *[]u8, new_text: []const u8, command: []const u8) ztcl.Error!void {
    const gpa = w.app.gpa;
    const new_name: []u8 = if (new_text.len > 0) try widget.globalVar(gpa, new_text) else &.{};
    if (std.mem.eql(u8, new_name, slot.*)) {
        if (new_name.len > 0) gpa.free(new_name);
        return;
    }
    remove(w, slot.*, command);
    gpa.free(slot.*);
    slot.* = new_name;
    try add(w, slot.*, command);
}
