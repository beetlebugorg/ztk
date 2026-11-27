//! The map from the key codes and the modifier flags of macOS (`NSEvent`)
//! to the keysyms and the modifier state of X11, which the bindings of Tk
//! name. A key that gives a character gets its keysym from that character
//! with the modifiers but Shift left out (`charactersIgnoringModifiers`),
//! so this map has the keys with no character: the editing keys, the
//! arrows, the function keys, the modifiers, and the keypad. The modifier
//! map is the map of Tk on macOS: Command is Mod1 and Option is Mod2.
//! The file has no AppKit calls, so its tests run on each system.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const event = @import("../base/event.zig");
const keysym_mod = @import("../base/keysym.zig");

/// The bits of `NSEventModifierFlags`.
pub const flag_caps_lock: u64 = 1 << 16;
pub const flag_shift: u64 = 1 << 17;
pub const flag_control: u64 = 1 << 18;
pub const flag_option: u64 = 1 << 19;
pub const flag_command: u64 = 1 << 20;

/// The keysym of a key with no character, by its key code (the `kVK_`
/// values of the HIToolbox headers), or null.
pub fn special(code: u16) ?u32 {
    return switch (code) {
        0x24 => 0xff0d, // Return
        0x30 => 0xff09, // Tab
        0x31 => 0x20, // space
        0x33 => 0xff08, // BackSpace (the Delete key of a Mac keyboard)
        0x35 => 0xff1b, // Escape
        0x75 => 0xffff, // Delete (the forward delete key)
        0x72 => 0xff6a, // Help
        0x73 => 0xff50, // Home
        0x77 => 0xff57, // End
        0x74 => 0xff55, // Prior
        0x79 => 0xff56, // Next
        0x7B => 0xff51, // Left
        0x7C => 0xff53, // Right
        0x7D => 0xff54, // Down
        0x7E => 0xff52, // Up
        0x7A => 0xffbe, // F1
        0x78 => 0xffbf, // F2
        0x63 => 0xffc0, // F3
        0x76 => 0xffc1, // F4
        0x60 => 0xffc2, // F5
        0x61 => 0xffc3, // F6
        0x62 => 0xffc4, // F7
        0x64 => 0xffc5, // F8
        0x65 => 0xffc6, // F9
        0x6D => 0xffc7, // F10
        0x67 => 0xffc8, // F11
        0x6F => 0xffc9, // F12
        0x69 => 0xffca, // F13
        0x6B => 0xffcb, // F14
        0x71 => 0xffcc, // F15
        0x6A => 0xffcd, // F16
        0x40 => 0xffce, // F17
        0x4F => 0xffcf, // F18
        0x50 => 0xffd0, // F19
        0x5A => 0xffd1, // F20
        0x52 => 0xffb0, // KP_0
        0x53 => 0xffb1,
        0x54 => 0xffb2,
        0x55 => 0xffb3,
        0x56 => 0xffb4,
        0x57 => 0xffb5,
        0x58 => 0xffb6,
        0x59 => 0xffb7,
        0x5B => 0xffb8,
        0x5C => 0xffb9, // KP_9
        0x41 => 0xffae, // KP_Decimal
        0x43 => 0xffaa, // KP_Multiply
        0x45 => 0xffab, // KP_Add
        0x47 => 0xff0b, // Clear
        0x4B => 0xffaf, // KP_Divide
        0x4C => 0xff8d, // KP_Enter
        0x4E => 0xffad, // KP_Subtract
        0x51 => 0xffbd, // KP_Equal
        else => modifierKey(code) orelse null,
    };
}

/// The keysym of a modifier key, which comes in `flagsChanged:`, or null.
/// Command is Meta, as in Tk on macOS, and Option is Alt.
pub fn modifierKey(code: u16) ?u32 {
    return switch (code) {
        0x38 => 0xffe1, // Shift_L
        0x3C => 0xffe2, // Shift_R
        0x3B => 0xffe3, // Control_L
        0x3E => 0xffe4, // Control_R
        0x39 => 0xffe5, // Caps_Lock
        0x37 => 0xffe7, // Meta_L: Command
        0x36 => 0xffe8, // Meta_R
        0x3A => 0xffe9, // Alt_L: Option
        0x3D => 0xffea, // Alt_R
        else => null,
    };
}

/// The flag that a modifier key sets, so `flagsChanged:` tells a press
/// from a release.
pub fn modifierFlag(code: u16) u64 {
    return switch (code) {
        0x38, 0x3C => flag_shift,
        0x3B, 0x3E => flag_control,
        0x39 => flag_caps_lock,
        0x37, 0x36 => flag_command,
        0x3A, 0x3D => flag_option,
        else => 0,
    };
}

/// The modifier state of the X11 state field, from the modifier flags and
/// the mouse buttons that are down (`NSEvent.pressedMouseButtons`: bit 0
/// the left button, bit 1 the right, bit 2 the middle). The left button
/// is Button1, the middle Button2, and the right Button3, as the other
/// backends give them.
pub fn mods(flags: u64, buttons: u64) event.Mods {
    return .{
        .shift = flags & flag_shift != 0,
        .lock = flags & flag_caps_lock != 0,
        .control = flags & flag_control != 0,
        .mod1 = flags & flag_command != 0,
        .mod2 = flags & flag_option != 0,
        .button1 = buttons & 1 != 0,
        .button2 = buttons & 4 != 0,
        .button3 = buttons & 2 != 0,
    };
}

/// The button of Tk for an `NSEvent.buttonNumber`: 1 left, 2 middle,
/// 3 right, and 8 and 9 for the two side buttons, as X11 numbers them.
/// Null for another button.
pub fn button(number: i64) ?u8 {
    return switch (number) {
        0 => 1,
        1 => 3,
        2 => 2,
        3 => 8,
        4 => 9,
        else => null,
    };
}

/// True for a code point that AppKit gives for a key with no character:
/// a control character, or the private use range of the function keys.
fn isFunctionChar(cp: u21) bool {
    return cp < 0x20 or cp == 0x7f or (cp >= 0xF700 and cp <= 0xF8FF);
}

/// The keysym and the text of a key press. `code` is the key code,
/// `plain` the UTF-8 of `charactersIgnoringModifiers`, `typed` the UTF-8
/// of `characters`. The text is empty with Command or Control, since
/// those keys run a binding and type no character, and for a key with no
/// character. Null: the key has no keysym.
pub fn press(code: u16, plain: []const u8, typed: []const u8, flags: u64, text: *[8]u8) ?struct { sym: u32, len: u8 } {
    var sym: ?u32 = special(code);
    if (sym == null) {
        if (firstCodepoint(plain)) |cp| if (!isFunctionChar(cp)) {
            sym = keysym_mod.fromCodepoint(letterCase(cp, flags));
        };
    }
    if (sym == null) {
        // A key that gives a character only with its modifiers, such as a dead key.
        if (firstCodepoint(typed)) |cp| if (!isFunctionChar(cp)) {
            sym = keysym_mod.fromCodepoint(cp);
        };
    }
    const s = sym orelse return null;
    var len: u8 = 0;
    if (flags & (flag_command | flag_control) == 0 and typed.len <= text.len) {
        if (firstCodepoint(typed)) |cp| if (!isFunctionChar(cp)) {
            @memcpy(text[0..typed.len], typed);
            len = @intCast(typed.len);
        };
    }
    return .{ .sym = s, .len = len };
}

/// `charactersIgnoringModifiers` keeps Shift and leaves out Caps Lock.
/// Tk gives the keysym of the case that the key types, so a letter is
/// upper case with Shift or Caps Lock, and lower case with both or none.
fn letterCase(cp: u21, flags: u64) u21 {
    const upper = (flags & flag_shift != 0) != (flags & flag_caps_lock != 0);
    if (cp >= 'a' and cp <= 'z' and upper) return cp - 32;
    if (cp >= 'A' and cp <= 'Z' and !upper) return cp + 32;
    return cp;
}

fn firstCodepoint(s: []const u8) ?u21 {
    if (s.len == 0) return null;
    const n = std.unicode.utf8ByteSequenceLength(s[0]) catch return null;
    if (n > s.len) return null;
    return std.unicode.utf8Decode(s[0..n]) catch null;
}

const t = std.testing;

// The inputs are the key codes of the HIToolbox headers and the
// characters of a US layout for each key.

test "mackeys: a letter, a shifted letter, and a digit" {
    var text: [8]u8 = undefined;
    const a = press(0x00, "a", "a", 0, &text).?;
    try t.expectEqual(@as(u32, 'a'), a.sym);
    try t.expectEqualStrings("a", text[0..a.len]);
    const big = press(0x00, "A", "A", flag_shift, &text).?;
    try t.expectEqual(@as(u32, 'A'), big.sym);
    try t.expectEqualStrings("A", text[0..big.len]);
    const one = press(0x12, "1", "1", 0, &text).?;
    try t.expectEqual(@as(u32, '1'), one.sym);
}

test "mackeys: Command and Control give no text, Option types its character" {
    var text: [8]u8 = undefined;
    const cmd_c = press(0x08, "c", "c", flag_command, &text).?;
    try t.expectEqual(@as(u32, 'c'), cmd_c.sym);
    try t.expectEqual(@as(u8, 0), cmd_c.len);
    const ctrl_c = press(0x08, "c", "\x03", flag_control, &text).?;
    try t.expectEqual(@as(u32, 'c'), ctrl_c.sym);
    try t.expectEqual(@as(u8, 0), ctrl_c.len);
    // Option-s types the sharp s, and the keysym is the s of the key.
    const opt_s = press(0x01, "s", "ß", flag_option, &text).?;
    try t.expectEqual(@as(u32, 's'), opt_s.sym);
    try t.expectEqualStrings("ß", text[0..opt_s.len]);
}

test "mackeys: the keys with no character" {
    var text: [8]u8 = undefined;
    // The arrows give private use characters, and Return gives a carriage return.
    const left = press(0x7B, "\u{F702}", "\u{F702}", 0, &text).?;
    try t.expectEqual(@as(u32, 0xff51), left.sym);
    try t.expectEqual(@as(u8, 0), left.len);
    const ret = press(0x24, "\r", "\r", 0, &text).?;
    try t.expectEqual(@as(u32, 0xff0d), ret.sym);
    try t.expectEqual(@as(u8, 0), ret.len);
    const bs = press(0x33, "\x7f", "\x7f", 0, &text).?;
    try t.expectEqual(@as(u32, 0xff08), bs.sym);
    try t.expectEqual(@as(u32, 0xffbe), press(0x7A, "\u{F704}", "\u{F704}", 0, &text).?.sym);
    try t.expectEqual(@as(u32, 0xff8d), press(0x4C, "\x03", "\x03", 0, &text).?.sym);
    // The space bar gives its keysym and its text.
    const sp = press(0x31, " ", " ", 0, &text).?;
    try t.expectEqual(@as(u32, 0x20), sp.sym);
    try t.expectEqualStrings(" ", text[0..sp.len]);
}

test "mackeys: Caps Lock gives the upper case keysym, as Tk does" {
    var text: [8]u8 = undefined;
    const k = press(0x00, "a", "A", flag_caps_lock, &text).?;
    try t.expectEqual(@as(u32, 'A'), k.sym);
    try t.expectEqualStrings("A", text[0..k.len]);
    const both = press(0x00, "A", "a", flag_caps_lock | flag_shift, &text).?;
    try t.expectEqual(@as(u32, 'a'), both.sym);
    // A dead key with no character of its own gives the keysym of what it types.
    const dead = press(0x0E, "", "´", flag_option, &text).?;
    try t.expectEqual(@as(u32, 0xb4), dead.sym);
}

test "mackeys: the modifier keys and the modifier state" {
    try t.expectEqual(@as(?u32, 0xffe7), modifierKey(0x37));
    try t.expectEqual(@as(?u32, 0xffe9), modifierKey(0x3A));
    try t.expectEqual(flag_command, modifierFlag(0x36));
    const m = mods(flag_command | flag_option | flag_shift, 0b011);
    try t.expect(m.mod1 and m.mod2 and m.shift and !m.control);
    try t.expect(m.button1 and m.button3 and !m.button2);
    try t.expectEqual(@as(?u8, 3), button(1));
    try t.expectEqual(@as(?u8, 2), button(2));
    try t.expectEqual(@as(?u8, null), button(7));
}
