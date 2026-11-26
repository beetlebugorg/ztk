//! The state of the input method of one window on macOS, with no AppKit
//! calls, so its tests run on each system. The view calls
//! `interpretKeyEvents:` for a key while the core has text input on, and
//! AppKit answers with the methods of `NSTextInputClient`: marked text
//! (`setMarkedText:`), the final text (`insertText:`), or a command such
//! as `moveLeft:` (`doCommandBySelector:`). This file decides what each
//! answer gives the core:
//!
//! - Marked text is a `preedit` event, and an empty marked text ends it.
//! - Text that ends a composition, or text with no key, is a `commit`.
//! - A key that the input method did not use, with no composition before
//!   or after it, stays a `key` event, so the bindings of the script see
//!   its keysym. Plain typing is such a key.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

pub const Ime = struct {
    /// The marked text in UTF-8. Empty: no composition.
    marked: std.ArrayListUnmanaged(u8) = .empty,
    /// True between `beginKey` and `endKey`.
    in_key: bool = false,
    /// True when the composition of the key in progress was on when the key came.
    marked_before: bool = false,
    /// True when the input method used the key in progress.
    used: bool = false,

    pub const Action = union(enum) {
        none,
        preedit: struct { text: []const u8, caret: u32 },
        commit: []const u8,
    };

    pub fn deinit(m: *Ime, gpa: std.mem.Allocator) void {
        m.marked.deinit(gpa);
    }

    pub fn hasMarked(m: *const Ime) bool {
        return m.marked.items.len > 0;
    }

    pub fn beginKey(m: *Ime) void {
        m.in_key = true;
        m.marked_before = m.hasMarked();
        m.used = m.marked_before;
    }

    /// True when the key stays a `key` event.
    pub fn endKey(m: *Ime) bool {
        m.in_key = false;
        return !m.used and !m.hasMarked();
    }

    /// `setMarkedText:selectedRange:replacementRange:`. `caret16` is the
    /// location of the selected range in UTF-16 units of `text`.
    pub fn setMarked(m: *Ime, gpa: std.mem.Allocator, text: []const u8, caret16: usize) Action {
        m.marked.clearRetainingCapacity();
        m.marked.appendSlice(gpa, text) catch {};
        if (m.in_key) m.used = true;
        return .{ .preedit = .{ .text = m.marked.items, .caret = byteOffset(m.marked.items, caret16) } };
    }

    /// `unmarkText`: the composition ends with its text as it is.
    pub fn unmark(m: *Ime) Action {
        if (!m.hasMarked()) return .none;
        m.marked.clearRetainingCapacity();
        return .{ .preedit = .{ .text = "", .caret = 0 } };
    }

    /// `insertText:replacementRange:`. Plain typing during a key with no
    /// composition gives `none`, and the key event has the text.
    pub fn insert(m: *Ime, text: []const u8) Action {
        const was_marked = m.hasMarked();
        m.marked.clearRetainingCapacity();
        if (m.in_key and !m.marked_before and !was_marked) return .none;
        if (m.in_key) m.used = true;
        return .{ .commit = text };
    }

    /// `doCommandBySelector:`. A command during a composition belongs to
    /// the input method. Else the key stays a key event.
    pub fn command(m: *Ime) void {
        if (m.in_key and m.hasMarked()) m.used = true;
    }

    /// The input method goes off: the composition ends with no text.
    pub fn discard(m: *Ime) Action {
        return m.unmark();
    }
};

/// The byte offset in UTF-8 `text` of a position in UTF-16 units, as
/// AppKit counts the ranges of an `NSString`. A position past the end is
/// the end.
pub fn byteOffset(text: []const u8, units: usize) u32 {
    var i: usize = 0;
    var n: usize = 0;
    while (i < text.len and n < units) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        // A code point past U+FFFF is two UTF-16 units.
        n += if (len == 4) 2 else 1;
        i += @min(len, text.len - i);
    }
    return @intCast(i);
}

const t = std.testing;

test "macime: plain typing stays a key, a composition gives preedit then commit" {
    var m: Ime = .{};
    defer m.deinit(t.allocator);
    // The key a: the input method inserts "a" with no composition.
    m.beginKey();
    try t.expect(m.insert("a") == .none);
    try t.expect(m.endKey());
    // Option-e: a dead key marks the accent.
    m.beginKey();
    const p = m.setMarked(t.allocator, "´", 1);
    try t.expectEqualStrings("´", p.preedit.text);
    try t.expectEqual(@as(u32, 2), p.preedit.caret);
    try t.expect(!m.endKey());
    // The key e ends it with é.
    m.beginKey();
    const c = m.insert("é");
    try t.expectEqualStrings("é", c.commit);
    try t.expect(!m.endKey());
    try t.expect(!m.hasMarked());
}

test "macime: a command key with no composition stays a key, and in one it goes to the input method" {
    var m: Ime = .{};
    defer m.deinit(t.allocator);
    m.beginKey();
    m.command();
    try t.expect(m.endKey());
    // A pinyin composition: the arrow key moves in the candidates.
    m.beginKey();
    _ = m.setMarked(t.allocator, "ni", 2);
    try t.expect(!m.endKey());
    m.beginKey();
    m.command();
    try t.expect(!m.endKey());
    // The candidate is chosen: the commit ends the composition.
    m.beginKey();
    try t.expectEqualStrings("你", m.insert("你").commit);
    try t.expect(!m.endKey());
    // Text with no key, such as from the character viewer, is a commit.
    try t.expectEqualStrings("✓", m.insert("✓").commit);
}

test "macime: the caret in UTF-16 units becomes a byte offset" {
    try t.expectEqual(@as(u32, 0), byteOffset("añb", 0));
    try t.expectEqual(@as(u32, 3), byteOffset("añb", 2));
    // The emoji is two UTF-16 units and four bytes.
    try t.expectEqual(@as(u32, 5), byteOffset("a😀b", 3));
    try t.expectEqual(@as(u32, 6), byteOffset("a😀b", 9));
}

test "macime: turning the input method off ends a composition" {
    var m: Ime = .{};
    defer m.deinit(t.allocator);
    try t.expect(m.discard() == .none);
    _ = m.setMarked(t.allocator, "ka", 2);
    const d = m.discard();
    try t.expectEqualStrings("", d.preedit.text);
    try t.expect(!m.hasMarked());
}
