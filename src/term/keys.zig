//! The bytes that a key sends to the program of a terminal, in the
//! forms of xterm. The key is a Tk keysym name (`Up`, `Return`, `F5`)
//! with the text of the key event and the modifiers.
//!
//! The cursor keys send `ESC [ A` or, in the application cursor mode
//! (DECCKM), `ESC O A`. With a modifier they send `ESC [ 1 ; m A`,
//! where m is 1 plus the bits Shift 1, Alt 2, and Control 4. The keys of
//! the editing pad send `ESC [ n ~` (`ESC [ n ; m ~` with a modifier).
//! F1 to F4 send `ESC O P` to `ESC O S`. Control with a letter sends
//! the C0 control, and Alt sends ESC before the bytes of the key.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

pub const Mods = packed struct(u8) {
    shift: bool = false,
    alt: bool = false,
    control: bool = false,
    _pad: u5 = 0,

    fn param(m: Mods) u8 {
        return 1 + @as(u8, @intFromBool(m.shift)) + 2 * @as(u8, @intFromBool(m.alt)) + 4 * @as(u8, @intFromBool(m.control));
    }

    fn any(m: Mods) bool {
        return m.shift or m.alt or m.control;
    }
};

const Cursor = struct { []const u8, u8 };
const cursor_keys = [_]Cursor{
    .{ "Up", 'A' },   .{ "Down", 'B' }, .{ "Right", 'C' }, .{ "Left", 'D' },
    .{ "Home", 'H' }, .{ "End", 'F' },
};
const tilde_keys = [_]struct { []const u8, u8 }{
    .{ "Insert", 2 }, .{ "Delete", 3 }, .{ "Prior", 5 }, .{ "Next", 6 },
    .{ "F5", 15 },    .{ "F6", 17 },    .{ "F7", 18 },   .{ "F8", 19 },
    .{ "F9", 20 },    .{ "F10", 21 },   .{ "F11", 23 },  .{ "F12", 24 },
};
const ss3_keys = [_]struct { []const u8, u8 }{
    .{ "F1", 'P' }, .{ "F2", 'Q' }, .{ "F3", 'R' }, .{ "F4", 'S' },
};

/// Writes the bytes of a key to `out`. Gives false when the key sends
/// no bytes (a modifier key alone).
pub fn encode(a: std.mem.Allocator, out: *std.ArrayList(u8), keysym: []const u8, text: []const u8, mods: Mods, app_cursor: bool) !bool {
    for (cursor_keys) |k| if (std.mem.eql(u8, k[0], keysym)) {
        if (mods.any()) {
            try out.print(a, "\x1b[1;{d}{c}", .{ mods.param(), k[1] });
        } else if (app_cursor) {
            try out.print(a, "\x1bO{c}", .{k[1]});
        } else try out.print(a, "\x1b[{c}", .{k[1]});
        return true;
    };
    for (tilde_keys) |k| if (std.mem.eql(u8, k[0], keysym)) {
        if (mods.any()) try out.print(a, "\x1b[{d};{d}~", .{ k[1], mods.param() }) else try out.print(a, "\x1b[{d}~", .{k[1]});
        return true;
    };
    for (ss3_keys) |k| if (std.mem.eql(u8, k[0], keysym)) {
        if (mods.any()) try out.print(a, "\x1b[1;{d}{c}", .{ mods.param(), k[1] }) else try out.print(a, "\x1bO{c}", .{k[1]});
        return true;
    };
    if (std.mem.eql(u8, keysym, "Return") or std.mem.eql(u8, keysym, "KP_Enter")) {
        if (mods.alt) try out.append(a, 0x1b);
        try out.append(a, '\r');
        return true;
    }
    if (std.mem.eql(u8, keysym, "BackSpace")) {
        if (mods.alt) try out.append(a, 0x1b);
        try out.append(a, if (mods.control) 0x08 else 0x7f);
        return true;
    }
    if (std.mem.eql(u8, keysym, "Tab") or std.mem.eql(u8, keysym, "ISO_Left_Tab")) {
        if (mods.shift or std.mem.eql(u8, keysym, "ISO_Left_Tab")) try out.appendSlice(a, "\x1b[Z") else try out.append(a, '\t');
        return true;
    }
    if (std.mem.eql(u8, keysym, "Escape")) {
        try out.append(a, 0x1b);
        return true;
    }
    if (mods.control) {
        const c: u8 = if (keysym.len == 1) std.ascii.toLower(keysym[0]) else if (text.len == 1) text[0] else 0;
        const ctl: ?u8 = switch (c) {
            'a'...'z' => c - 'a' + 1,
            '@', ' ', '2' => 0,
            '[', '3' => 0x1b,
            '\\', '4' => 0x1c,
            ']', '5' => 0x1d,
            '^', '6' => 0x1e,
            '_', '7', '-' => 0x1f,
            '?', '8' => 0x7f,
            else => null,
        };
        if (std.mem.eql(u8, keysym, "space")) {
            if (mods.alt) try out.append(a, 0x1b);
            try out.append(a, 0);
            return true;
        }
        if (ctl) |b| {
            if (mods.alt) try out.append(a, 0x1b);
            try out.append(a, b);
            return true;
        }
    }
    if (text.len == 0) return false;
    // A control character in the text is the key itself.
    if (mods.alt) try out.append(a, 0x1b);
    try out.appendSlice(a, text);
    return true;
}

fn expectKey(keysym: []const u8, text: []const u8, mods: Mods, app: bool, want: []const u8) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    _ = try encode(std.testing.allocator, &out, keysym, text, mods, app);
    try std.testing.expectEqualStrings(want, out.items);
}

test "key encoding" {
    try expectKey("a", "a", .{}, false, "a");
    try expectKey("Up", "", .{}, false, "\x1b[A");
    try expectKey("Up", "", .{}, true, "\x1bOA");
    try expectKey("Left", "", .{ .control = true }, false, "\x1b[1;5D");
    try expectKey("Delete", "", .{}, false, "\x1b[3~");
    try expectKey("Prior", "", .{ .shift = true }, false, "\x1b[5;2~");
    try expectKey("F1", "", .{}, false, "\x1bOP");
    try expectKey("F12", "", .{}, false, "\x1b[24~");
    try expectKey("c", "\x03", .{ .control = true }, false, "\x03");
    try expectKey("x", "x", .{ .alt = true }, false, "\x1bx");
    try expectKey("Return", "\r", .{}, false, "\r");
    try expectKey("BackSpace", "\x08", .{}, false, "\x7f");
    try expectKey("Tab", "\t", .{ .shift = true }, false, "\x1b[Z");
    try expectKey("Shift_L", "", .{ .shift = true }, false, "");
    try expectKey("bracketleft", "[", .{ .control = true }, false, "\x1b");
}
