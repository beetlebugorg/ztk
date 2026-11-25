//! The one place where ztk calls `compact` of ztcl. A compact copies the
//! reachable state of the interpreter to a new arena. The pinned ztcl
//! drops each variable trace, each command trace, the `array` searches,
//! and the name of `info script`. It keeps the value of `tcl_precision`
//! without a copy, so a string value there points at freed memory.
//!
//! The rule: a compact runs only when the script can see no loss.
//! - ztk adds its own traces again after the compact. A trace is its own
//!   only when its operations, its variable, and its full script text
//!   are the ones that a live widget or the parked wait added.
//! - Any other trace, a command trace, or an open `array` search stops
//!   the compact. The arena then grows until that state goes away.
//! - A trace on a cell that a link reaches, and that no table entry names
//!   (an `upvar` to an array element), belongs to a script and stops the
//!   compact.
//! - A `tcl_precision` in a string form becomes the same integer first.
//!   A text that is not the plain integer stops the compact.
//! - The name of `info script` is saved and set again.
//!
//! A garbage collector in ztcl replaces this file and the call sites of
//! `maybe` in `App`.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const widget = @import("widget.zig");
const App = @import("app.zig").App;

/// The operation bit of a write trace in ztcl.
const op_write: u8 = 2;

fn trimColons(name: []const u8) []const u8 {
    return std.mem.trimStart(u8, name, ":");
}

/// True when `full` (a name with an optional array index) names the variable and the index of a trace.
fn sameVariable(full: []const u8, table_name: []const u8, elem: ?[]const u8) bool {
    var base = full;
    var index: ?[]const u8 = null;
    if (full.len > 0 and full[full.len - 1] == ')') {
        if (std.mem.indexOfScalar(u8, full, '(')) |open| {
            base = full[0..open];
            index = full[open + 1 .. full.len - 1];
        }
    }
    if (!std.mem.eql(u8, trimColons(base), trimColons(table_name))) return false;
    if (index == null or elem == null) return index == null and elem == null;
    return std.mem.eql(u8, index.?, elem.?);
}

/// True when the trace is the one trace that ztk added on this variable.
fn ownTrace(app: *App, table_name: []const u8, ops: u8, old: ?[]const u8, elem: ?[]const u8, cmd: ztcl.Value) bool {
    if (ops != op_write or old != null) return false;
    const it = app.it;
    const text = it.str(cmd) catch return false;
    if (app.loop.parked) |p| if (p == .variable) {
        var buf: [40]u8 = undefined;
        const own = std.fmt.bufPrint(&buf, "::ztk::priv::vwait {d}", .{p.variable.id}) catch return false;
        if (std.mem.eql(u8, text, own)) return sameVariable(p.variable.name, table_name, elem);
    };
    const words = it.list(.{ .str = text }) catch return false;
    if (words.len != 2) return false;
    const path = it.str(words[1]) catch return false;
    const w = app.find(path) orelse return false;
    const word = it.str(words[0]) catch return false;
    const pairs = [_]struct { ?*const fn (w: *const widget.Widget) []const u8, []const u8 }{
        .{ w.class.traced_var, w.class.trace_command },
        .{ w.class.traced_var2, w.class.trace_command2 },
    };
    for (pairs) |pr| {
        const get = pr[0] orelse continue;
        if (!std.mem.eql(u8, word, pr[1])) continue;
        if (!std.mem.eql(u8, text, widget.traceScript(it.alloc(), pr[1], w.path))) continue;
        if (sameVariable(get(w), table_name, elem)) return true;
    }
    return false;
}

fn inTable(it: *ztcl.Interp, cell: *const ztcl.interp.Var) bool {
    for (it.global.vars.items) |e| if (e.cell == cell) return true;
    return false;
}

/// True when a compact keeps all state that a script can see.
pub fn safe(app: *App) bool {
    const it = app.it;
    if (it.searches.items.len != 0) return false;
    if (app.trace_native == null) return false;
    var cmds = it.commands.valueIterator();
    while (cmds.next()) |c| {
        const tr = c.*.traces orelse continue;
        if (tr.cmds.items.len != 0 or tr.execs.items.len != 0) return false;
    }
    for (it.global.vars.items) |e| {
        var cell = e.cell;
        while (cell.v == .link) cell = cell.v.link;
        if (cell.v != .traced) continue;
        if (cell != e.cell) {
            // A target in the table is checked under its own name.
            if (inTable(it, cell)) continue;
            if (cell.v.traced.list.items.len != 0) return false;
            continue;
        }
        const list = cell.v.traced.list.items;
        for (list, 0..) |tr, i| {
            if (!ownTrace(app, e.name, tr.ops, tr.old, tr.elem, tr.cmd)) return false;
            // ztk adds one trace. A second equal trace belongs to a script.
            for (list[0..i]) |prev| {
                if (std.mem.eql(u8, it.str(prev.cmd) catch return false, it.str(tr.cmd) catch return false)) return false;
            }
        }
    }
    return true;
}

/// Puts `tcl_precision` in integer form, because ztcl keeps its value
/// without a copy. Returns false when the text is not the plain integer.
fn pinPrecision(it: *ztcl.Interp) bool {
    for (it.global.vars.items) |e| {
        if (e.cell.v != .traced or !e.cell.v.traced.precision) continue;
        const t = e.cell.v.traced;
        switch (t.inner) {
            .undef => {},
            .arr => return false,
            .val => |v| {
                if (v == .int) continue;
                const text = it.str(v) catch return false;
                const n = v.asInt() orelse return false;
                var buf: [24]u8 = undefined;
                const plain = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return false;
                if (!std.mem.eql(u8, text, plain)) return false;
                t.inner = .{ .val = .{ .int = n } };
            },
        }
    }
    return true;
}

/// Runs a compact when the arena grew by the threshold and the
/// interpreter is idle. Returns true when it ran.
pub fn maybe(app: *App) bool {
    if (app.callback_depth != 0) return false;
    const it = app.it;
    const used = it.memUsed();
    if (used < app.compact_base + app.compact_threshold) return false;
    // After a refusal or a failure, the next check waits for the next step of growth.
    app.compact_base = used;
    if (!safe(app) or !pinPrecision(it)) return false;
    const script_name = app.gpa.dupe(u8, it.script_name) catch return false;
    defer app.gpa.free(script_name);
    it.compact(&.{}, .{}) catch return false;
    it.script_name = it.alloc().dupe(u8, script_name) catch "";
    app.script_gen +%= 1;
    app.retraceAll();
    app.loop.retraceParked();
    app.compact_base = it.memUsed();
    return true;
}
