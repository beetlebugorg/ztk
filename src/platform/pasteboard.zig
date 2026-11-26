//! The clipboard of macOS: the text of an `NSPasteboard`. The AppKit
//! backend has one `Pasteboard` on the general pasteboard. The tests use a
//! pasteboard with a unique name, so they leave the clipboard of the user
//! alone. A get after a set of the same program gives null while the
//! change count of the pasteboard is still the count of that set, as the
//! clipboard interface of `platform.zig` asks.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const objc = @import("../sys/objc.zig");
const Id = objc.Id;
const Sel = objc.Sel;
const Class = objc.Class;

extern "AppKit" const NSPasteboardTypeString: Id;

pub const Pasteboard = struct {
    board: Id,
    /// The change count after the last set, or null before a set.
    own_change: ?isize = null,

    /// The general pasteboard of the system: the clipboard.
    pub fn general() Pasteboard {
        const b = objc.call(fn (Class, Sel) callconv(.c) Id, objc.class("NSPasteboard").?, "generalPasteboard", .{});
        return .{ .board = b };
    }

    /// A new pasteboard that only this program knows, for a test. `deinit`
    /// releases it.
    pub fn unique() Pasteboard {
        const b = objc.call(fn (Class, Sel) callconv(.c) Id, objc.class("NSPasteboard").?, "pasteboardWithUniqueName", .{});
        _ = objc.call(fn (Id, Sel) callconv(.c) Id, b, "retain", .{});
        return .{ .board = b };
    }

    /// For a pasteboard of `unique`.
    pub fn deinit(p: *Pasteboard) void {
        objc.call(fn (Id, Sel) callconv(.c) void, p.board, "releaseGlobally", .{});
        objc.release(p.board);
    }

    pub fn isText(typ: []const u8) bool {
        return std.mem.eql(u8, typ, "STRING") or std.mem.eql(u8, typ, "UTF8_STRING");
    }

    fn changeCount(p: *const Pasteboard) isize {
        return objc.call(fn (Id, Sel) callconv(.c) isize, p.board, "changeCount", .{});
    }

    /// Puts UTF-8 text on the pasteboard, in place of what it had.
    pub fn set(p: *Pasteboard, typ: []const u8, data: []const u8) void {
        if (!isText(typ)) return;
        const pool = objc.Pool.push();
        defer pool.pop();
        _ = objc.call(fn (Id, Sel) callconv(.c) isize, p.board, "clearContents", .{});
        const s = objc.nsString(data);
        defer objc.release(s);
        _ = objc.call(fn (Id, Sel, Id, Id) callconv(.c) bool, p.board, "setString:forType:", .{ s, NSPasteboardTypeString });
        p.own_change = p.changeCount();
    }

    /// The text of the pasteboard in memory of `gpa`, with `\n` line ends.
    /// Null: the pasteboard has no text, or the last set of this program
    /// is still the latest change.
    pub fn get(p: *Pasteboard, gpa: std.mem.Allocator, typ: []const u8) ?[]u8 {
        if (!isText(typ)) return null;
        if (p.own_change) |c| if (c == p.changeCount()) return null;
        const pool = objc.Pool.push();
        defer pool.pop();
        const s = objc.call(fn (Id, Sel, Id) callconv(.c) ?Id, p.board, "stringForType:", .{NSPasteboardTypeString}) orelse return null;
        return lineEnds(gpa, objc.utf8(s));
    }
};

/// A copy of `text` with each `\r\n` and each `\r` as `\n`, the line end of
/// Tk. Text from an older Mac program can have `\r` alone.
fn lineEnds(gpa: std.mem.Allocator, text: []const u8) ?[]u8 {
    const out = gpa.alloc(u8, text.len) catch return null;
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\r') {
            out[n] = '\n';
            if (i + 1 < text.len and text[i + 1] == '\n') i += 1;
        } else out[n] = text[i];
        n += 1;
    }
    if (n == out.len) return out;
    defer gpa.free(out);
    return gpa.dupe(u8, out[0..n]) catch null;
}

const t = std.testing;

test "pasteboard: a set, and a change by another writer" {
    var p = Pasteboard.unique();
    defer p.deinit();
    p.set("STRING", "zig ✓ text\nline two");
    // The last set is the latest change, so the core keeps its own copy.
    try t.expect(p.get(t.allocator, "STRING") == null);
    // Another writer changes the pasteboard, through its name, as another program does.
    const name = objc.call(fn (Id, Sel) callconv(.c) Id, p.board, "name", .{});
    const other = objc.call(fn (Class, Sel, Id) callconv(.c) Id, objc.class("NSPasteboard").?, "pasteboardWithName:", .{name});
    _ = objc.call(fn (Id, Sel) callconv(.c) isize, other, "clearContents", .{});
    const s = objc.nsString("from\r\nanother\rprogram");
    defer objc.release(s);
    _ = objc.call(fn (Id, Sel, Id, Id) callconv(.c) bool, other, "setString:forType:", .{ s, NSPasteboardTypeString });
    const got = p.get(t.allocator, "UTF8_STRING") orelse return error.NoText;
    defer t.allocator.free(got);
    try t.expectEqualStrings("from\nanother\nprogram", got);
    // A type with no text form gives null.
    try t.expect(p.get(t.allocator, "image/png") == null);
}

test "pasteboard: an empty pasteboard has no text" {
    var p = Pasteboard.unique();
    defer p.deinit();
    try t.expect(p.get(t.allocator, "STRING") == null);
}
