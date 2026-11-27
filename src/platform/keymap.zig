//! The US key layout without a library. A table maps an evdev key code
//! (the KEY_ numbers of linux/input-event-codes.h) to the key symbol of
//! the plain level and of the Shift level. The key symbols are the X11
//! numbers of `src/base/keysym.zig`. `text` gives the UTF-8 text of a symbol.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const event = @import("../base/event.zig");

pub const Level = struct { plain: u32, shift: u32 };

fn ascii(lo: u8, hi: u8) Level {
    return .{ .plain = lo, .shift = hi };
}

fn same(sym: u32) Level {
    return .{ .plain = sym, .shift = sym };
}

const letters_row1 = "qwertyuiop";
const letters_row2 = "asdfghjkl";
const letters_row3 = "zxcvbnm";

/// The key symbols of an evdev key code in the US layout, or null.
pub fn lookup(code: u16) ?Level {
    switch (code) {
        1 => return same(0xff1b), // Escape
        2...10 => return ascii('1' + @as(u8, @intCast(code - 2)), "!@#$%^&*("[code - 2]),
        11 => return ascii('0', ')'),
        12 => return ascii('-', '_'),
        13 => return ascii('=', '+'),
        14 => return same(0xff08), // BackSpace
        15 => return same(0xff09), // Tab
        16...25 => {
            const c = letters_row1[code - 16];
            return ascii(c, c - 32);
        },
        26 => return ascii('[', '{'),
        27 => return ascii(']', '}'),
        28 => return same(0xff0d), // Return
        29, 97 => return same(0xffe3), // Control
        30...38 => {
            const c = letters_row2[code - 30];
            return ascii(c, c - 32);
        },
        39 => return ascii(';', ':'),
        40 => return ascii('\'', '"'),
        41 => return ascii('`', '~'),
        42, 54 => return same(0xffe1), // Shift
        43 => return ascii('\\', '|'),
        44...50 => {
            const c = letters_row3[code - 44];
            return ascii(c, c - 32);
        },
        51 => return ascii(',', '<'),
        52 => return ascii('.', '>'),
        53 => return ascii('/', '?'),
        56, 100 => return same(0xffe9), // Alt
        57 => return same(' '),
        58 => return same(0xffe5), // Caps_Lock
        59...68 => return same(0xffbe + @as(u32, code - 59)), // F1 to F10
        87 => return same(0xffc8), // F11
        88 => return same(0xffc9), // F12
        102 => return same(0xff50), // Home
        103 => return same(0xff52), // Up
        104 => return same(0xff55), // Page_Up
        105 => return same(0xff51), // Left
        106 => return same(0xff53), // Right
        107 => return same(0xff57), // End
        108 => return same(0xff54), // Down
        109 => return same(0xff56), // Page_Down
        110 => return same(0xff63), // Insert
        111 => return same(0xffff), // Delete
        125, 126 => return same(0xffeb), // Super
        else => return null,
    }
}

/// The UTF-8 text of a key symbol with the modifiers, or an empty slice.
/// Control and Alt give no text. Shift and Caps Lock make a letter upper case.
pub fn text(sym: u32, mods: event.Mods, buf: *[8]u8) []const u8 {
    if (mods.control or mods.mod1) return buf[0..0];
    var c: u8 = 0;
    switch (sym) {
        0x20...0x7e => {
            c = @intCast(sym);
            if (c >= 'a' and c <= 'z' and (mods.shift != mods.lock)) c -= 32;
        },
        0xff0d => c = '\r',
        0xff09 => c = '\t',
        0xff08 => c = 0x08,
        0xff1b => c = 0x1b,
        else => return buf[0..0],
    }
    buf[0] = c;
    return buf[0..1];
}

const t = std.testing;

test "keymap: lookup" {
    const a = lookup(30).?;
    try t.expectEqual(@as(u32, 'a'), a.plain);
    try t.expectEqual(@as(u32, 'A'), a.shift);
    try t.expectEqual(@as(u32, 0xff0d), lookup(28).?.plain);
    const one = lookup(2).?;
    try t.expectEqual(@as(u32, '1'), one.plain);
    try t.expectEqual(@as(u32, '!'), one.shift);
    try t.expect(lookup(0x2f0) == null);
    try t.expectEqual(@as(u32, 'p'), lookup(25).?.plain);
    try t.expectEqual(@as(u32, 'm'), lookup(50).?.plain);
    try t.expectEqual(@as(u32, 0xffc9), lookup(88).?.plain);
}

test "keymap: text" {
    var buf: [8]u8 = undefined;
    try t.expectEqualStrings("A", text('a', .{ .shift = true }, &buf));
    try t.expectEqualStrings("a", text('a', .{}, &buf));
    try t.expectEqualStrings("", text('a', .{ .control = true }, &buf));
    try t.expectEqualStrings("\r", text(0xff0d, .{}, &buf));
    try t.expectEqualStrings("", text(0xff51, .{}, &buf));
}
