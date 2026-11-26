//! The names and numbers of key symbols. The numbers are the X11 key
//! symbol values. The table has printable ASCII, the
//! editing and navigation keys, the modifiers, and F1 to F12. A Latin-1
//! character has its code point as the number. The table was made from
//! the output of `event generate -keysym` and `%N` in wish 8.6.16.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

const Entry = struct { []const u8, u32 };

const table = [_]Entry{
    .{ "space", 0x20 },
    .{ "exclam", 0x21 },
    .{ "quotedbl", 0x22 },
    .{ "numbersign", 0x23 },
    .{ "dollar", 0x24 },
    .{ "percent", 0x25 },
    .{ "ampersand", 0x26 },
    .{ "apostrophe", 0x27 },
    .{ "parenleft", 0x28 },
    .{ "parenright", 0x29 },
    .{ "asterisk", 0x2a },
    .{ "plus", 0x2b },
    .{ "comma", 0x2c },
    .{ "minus", 0x2d },
    .{ "period", 0x2e },
    .{ "slash", 0x2f },
    .{ "0", 0x30 },
    .{ "1", 0x31 },
    .{ "2", 0x32 },
    .{ "3", 0x33 },
    .{ "4", 0x34 },
    .{ "5", 0x35 },
    .{ "6", 0x36 },
    .{ "7", 0x37 },
    .{ "8", 0x38 },
    .{ "9", 0x39 },
    .{ "colon", 0x3a },
    .{ "semicolon", 0x3b },
    .{ "less", 0x3c },
    .{ "equal", 0x3d },
    .{ "greater", 0x3e },
    .{ "question", 0x3f },
    .{ "at", 0x40 },
    .{ "A", 0x41 },
    .{ "B", 0x42 },
    .{ "C", 0x43 },
    .{ "D", 0x44 },
    .{ "E", 0x45 },
    .{ "F", 0x46 },
    .{ "G", 0x47 },
    .{ "H", 0x48 },
    .{ "I", 0x49 },
    .{ "J", 0x4a },
    .{ "K", 0x4b },
    .{ "L", 0x4c },
    .{ "M", 0x4d },
    .{ "N", 0x4e },
    .{ "O", 0x4f },
    .{ "P", 0x50 },
    .{ "Q", 0x51 },
    .{ "R", 0x52 },
    .{ "S", 0x53 },
    .{ "T", 0x54 },
    .{ "U", 0x55 },
    .{ "V", 0x56 },
    .{ "W", 0x57 },
    .{ "X", 0x58 },
    .{ "Y", 0x59 },
    .{ "Z", 0x5a },
    .{ "bracketleft", 0x5b },
    .{ "backslash", 0x5c },
    .{ "bracketright", 0x5d },
    .{ "asciicircum", 0x5e },
    .{ "underscore", 0x5f },
    .{ "grave", 0x60 },
    .{ "a", 0x61 },
    .{ "b", 0x62 },
    .{ "c", 0x63 },
    .{ "d", 0x64 },
    .{ "e", 0x65 },
    .{ "f", 0x66 },
    .{ "g", 0x67 },
    .{ "h", 0x68 },
    .{ "i", 0x69 },
    .{ "j", 0x6a },
    .{ "k", 0x6b },
    .{ "l", 0x6c },
    .{ "m", 0x6d },
    .{ "n", 0x6e },
    .{ "o", 0x6f },
    .{ "p", 0x70 },
    .{ "q", 0x71 },
    .{ "r", 0x72 },
    .{ "s", 0x73 },
    .{ "t", 0x74 },
    .{ "u", 0x75 },
    .{ "v", 0x76 },
    .{ "w", 0x77 },
    .{ "x", 0x78 },
    .{ "y", 0x79 },
    .{ "z", 0x7a },
    .{ "braceleft", 0x7b },
    .{ "bar", 0x7c },
    .{ "braceright", 0x7d },
    .{ "asciitilde", 0x7e },
    .{ "Return", 0xff0d },
    .{ "Tab", 0xff09 },
    .{ "ISO_Left_Tab", 0xfe20 },
    .{ "Escape", 0xff1b },
    .{ "BackSpace", 0xff08 },
    .{ "Delete", 0xffff },
    .{ "Left", 0xff51 },
    .{ "Right", 0xff53 },
    .{ "Up", 0xff52 },
    .{ "Down", 0xff54 },
    .{ "Home", 0xff50 },
    .{ "End", 0xff57 },
    .{ "Prior", 0xff55 },
    .{ "Next", 0xff56 },
    .{ "Select", 0xff60 },
    .{ "Shift_L", 0xffe1 },
    .{ "Shift_R", 0xffe2 },
    .{ "Control_L", 0xffe3 },
    .{ "Control_R", 0xffe4 },
    .{ "Alt_L", 0xffe9 },
    .{ "Alt_R", 0xffea },
    .{ "Super_L", 0xffeb },
    .{ "F1", 0xffbe },
    .{ "F2", 0xffbf },
    .{ "F3", 0xffc0 },
    .{ "F4", 0xffc1 },
    .{ "F5", 0xffc2 },
    .{ "F6", 0xffc3 },
    .{ "F7", 0xffc4 },
    .{ "F8", 0xffc5 },
    .{ "F9", 0xffc6 },
    .{ "F10", 0xffc7 },
    .{ "F11", 0xffc8 },
    .{ "F12", 0xffc9 },
};

/// The number of a key symbol name ("Return", "a", "space"), or null.
pub fn fromName(name: []const u8) ?u32 {
    for (table) |e| if (std.mem.eql(u8, e[0], name)) return e[1];
    return null;
}

/// The name of a number, or null.
pub fn toName(sym: u32) ?[]const u8 {
    for (table) |e| if (e[1] == sym) return e[0];
    return null;
}

/// The key symbol of a Unicode code point. A Latin-1 character has its
/// code point. Another character has 0x01000000 plus its code point.
pub fn fromCodepoint(cp: u21) u32 {
    if (cp < 0x100) return cp;
    return 0x0100_0000 + @as(u32, cp);
}

test "keysym: names and numbers" {
    try std.testing.expectEqual(@as(?u32, 0xff0d), fromName("Return"));
    try std.testing.expectEqual(@as(?u32, 0x61), fromName("a"));
    try std.testing.expectEqual(@as(?u32, 0x20), fromName("space"));
    try std.testing.expectEqual(@as(?u32, 0xffbe), fromName("F1"));
    try std.testing.expectEqual(@as(?u32, null), fromName("nosuch"));
    try std.testing.expectEqualStrings("a", toName(0x61).?);
    try std.testing.expectEqualStrings("Return", toName(0xff0d).?);
    try std.testing.expectEqual(@as(?[]const u8, null), toName(0x12345678));
}

test "keysym: each name round-trips" {
    for (table) |e| {
        try std.testing.expectEqual(@as(?u32, e[1]), fromName(e[0]));
        try std.testing.expectEqualStrings(e[0], toName(e[1]).?);
    }
}

test "keysym: code points" {
    try std.testing.expectEqual(@as(u32, 0xe9), fromCodepoint(0xe9));
    try std.testing.expectEqual(@as(u32, 0x0100_20ac), fromCodepoint(0x20ac));
}
