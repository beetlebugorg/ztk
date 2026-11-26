//! The undo and redo stacks of the `text` widget.
//!
//! An action is an insert or a delete of text at a position, with the
//! text. A separator ends a compound action: an undo applies the inverse
//! of each action back to the last separator, and moves the actions to
//! the redo stack in the same groups. A new edit clears the redo stack.
//!
//! With `-autoseparators`, a separator goes in when the kind of edit
//! changes from insert to delete or back, as in `wish`. `-maxundo`
//! bounds the count of compound actions, and the oldest go first.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Pos = @import("buffer.zig").Pos;

pub const Kind = enum { insert, delete, sep };

pub const Action = struct {
    kind: Kind,
    /// The start of the text, and its text. The end follows from the text.
    pos: Pos = .{},
    text: []u8 = &.{},
};

pub const Stack = struct {
    undo: std.ArrayListUnmanaged(Action) = .empty,
    redo: std.ArrayListUnmanaged(Action) = .empty,
    last: Kind = .sep,

    pub fn deinit(s: *Stack, gpa: std.mem.Allocator) void {
        s.reset(gpa);
        s.undo.deinit(gpa);
        s.redo.deinit(gpa);
    }

    fn clear(list: *std.ArrayListUnmanaged(Action), gpa: std.mem.Allocator) void {
        for (list.items) |a| gpa.free(a.text);
        list.clearRetainingCapacity();
    }

    pub fn reset(s: *Stack, gpa: std.mem.Allocator) void {
        clear(&s.undo, gpa);
        clear(&s.redo, gpa);
        s.last = .sep;
    }

    pub fn canUndo(s: *const Stack) bool {
        for (s.undo.items) |a| if (a.kind != .sep) return true;
        return false;
    }

    pub fn canRedo(s: *const Stack) bool {
        for (s.redo.items) |a| if (a.kind != .sep) return true;
        return false;
    }

    /// Adds a separator to the undo stack, unless it ends in one.
    pub fn separator(s: *Stack, gpa: std.mem.Allocator) !void {
        s.last = .sep;
        if (s.undo.items.len == 0 or s.undo.items[s.undo.items.len - 1].kind == .sep) return;
        try s.undo.append(gpa, .{ .kind = .sep });
    }

    /// Records an edit by a script or by the user.
    pub fn record(s: *Stack, gpa: std.mem.Allocator, kind: Kind, pos: Pos, text: []const u8, auto: bool, max: i64) !void {
        clear(&s.redo, gpa);
        if (auto and s.last != kind and s.last != .sep) try s.separator(gpa);
        const copy = try gpa.dupe(u8, text);
        errdefer gpa.free(copy);
        try s.undo.append(gpa, .{ .kind = kind, .pos = pos, .text = copy });
        s.last = kind;
        if (max > 0) s.trim(gpa, max);
    }

    /// Drops the oldest compound actions past `max`.
    fn trim(s: *Stack, gpa: std.mem.Allocator, max: i64) void {
        var groups: i64 = 0;
        var k = s.undo.items.len;
        var in_group = false;
        while (k > 0) {
            k -= 1;
            if (s.undo.items[k].kind == .sep) {
                in_group = false;
                continue;
            }
            if (!in_group) {
                groups += 1;
                in_group = true;
                if (groups > max) {
                    // Drop the actions up to and with this group.
                    var j = k + 1;
                    while (j < s.undo.items.len and s.undo.items[j].kind != .sep) j += 1;
                    for (s.undo.items[0..j]) |a| gpa.free(a.text);
                    s.undo.replaceRangeAssumeCapacity(0, j, &.{});
                    return;
                }
            }
        }
    }

    /// Takes the actions of the last compound action of `from`, the last
    /// action first. The caller frees the texts.
    pub fn pop(from: *std.ArrayListUnmanaged(Action), gpa: std.mem.Allocator) ![]Action {
        while (from.items.len > 0 and from.items[from.items.len - 1].kind == .sep) _ = from.pop();
        var k = from.items.len;
        while (k > 0 and from.items[k - 1].kind != .sep) k -= 1;
        const out = try gpa.alloc(Action, from.items.len - k);
        var i: usize = 0;
        var j = from.items.len;
        while (j > k) : (i += 1) {
            j -= 1;
            out[i] = from.items[j];
        }
        from.shrinkRetainingCapacity(k);
        return out;
    }
};

const t = std.testing;

test "textw undo: groups, separators, and the limit" {
    const gpa = t.allocator;
    var s: Stack = .{};
    defer s.deinit(gpa);
    try s.record(gpa, .insert, .{}, "abc", true, 0);
    try s.record(gpa, .insert, .{ .ch = 3 }, "def", true, 0);
    try s.record(gpa, .delete, .{}, "ab", true, 0);
    const g = try Stack.pop(&s.undo, gpa);
    defer {
        for (g) |a| gpa.free(a.text);
        gpa.free(g);
    }
    try t.expectEqual(@as(usize, 1), g.len);
    try t.expectEqual(Kind.delete, g[0].kind);
    try t.expect(s.canUndo());
    s.reset(gpa);
    for (0..4) |_| {
        try s.record(gpa, .insert, .{}, "x", true, 2);
        try s.separator(gpa);
    }
    var n: usize = 0;
    while (s.canUndo()) : (n += 1) {
        const x = try Stack.pop(&s.undo, gpa);
        for (x) |a| gpa.free(a.text);
        gpa.free(x);
    }
    try t.expectEqual(@as(usize, 2), n);
}
