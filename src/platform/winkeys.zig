//! The map from the virtual keys of Windows to the keysyms of X11, which
//! the bindings of Tk name. A key that gives a character (a letter, a
//! digit, a sign) gets its keysym from that character, which comes in
//! the `WM_CHAR` after the key, so this map has the keys with no
//! character: the editing keys, the arrows, the function keys, the
//! modifiers, and the keypad. The extended bit of the message tells the
//! right Control and Alt and the keypad Enter from the main keys. Letters
//! and digits are in the map too, for a key with Control, which gives a
//! control character or no character.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

/// The keysym of a virtual key, or null when the key has no keysym here.
/// `extended` is bit 24 of the `lParam` of the key message. `shift` picks
/// the upper case of a letter.
pub fn keysym(vk: u32, extended: bool, shift: bool) ?u32 {
    return switch (vk) {
        0x08 => 0xff08, // BackSpace
        0x09 => 0xff09, // Tab
        0x0C => 0xff0b, // Clear
        0x0D => if (extended) 0xff8d else 0xff0d, // KP_Enter, Return
        0x13 => 0xff13, // Pause
        0x14 => 0xffe5, // Caps_Lock
        0x1B => 0xff1b, // Escape
        0x20 => 0x20, // space
        0x21 => 0xff55, // Prior
        0x22 => 0xff56, // Next
        0x23 => 0xff57, // End
        0x24 => 0xff50, // Home
        0x25 => 0xff51, // Left
        0x26 => 0xff52, // Up
        0x27 => 0xff53, // Right
        0x28 => 0xff54, // Down
        0x2C => 0xff61, // Print
        0x2D => 0xff63, // Insert
        0x2E => 0xffff, // Delete
        0x2F => 0xff6a, // Help
        '0'...'9' => vk,
        'A'...'Z' => if (shift) vk else vk + 32,
        0x5B => 0xffeb, // Super_L
        0x5C => 0xffec, // Super_R
        0x5D => 0xff67, // Menu
        0x60...0x69 => 0xffb0 + (vk - 0x60), // KP_0 to KP_9
        0x6A => 0xffaa, // KP_Multiply
        0x6B => 0xffab, // KP_Add
        0x6C => 0xffac, // KP_Separator
        0x6D => 0xffad, // KP_Subtract
        0x6E => 0xffae, // KP_Decimal
        0x6F => 0xffaf, // KP_Divide
        0x70...0x87 => 0xffbe + (vk - 0x70), // F1 to F24
        0x90 => 0xff7f, // Num_Lock
        0x91 => 0xff14, // Scroll_Lock
        0x10 => 0xffe1, // Shift_L: the message does not tell the side
        0xA0 => 0xffe1, // Shift_L
        0xA1 => 0xffe2, // Shift_R
        0x11 => if (extended) 0xffe4 else 0xffe3, // Control_R, Control_L
        0xA2 => 0xffe3,
        0xA3 => 0xffe4,
        0x12 => if (extended) 0xffea else 0xffe9, // Alt_R, Alt_L
        0xA4 => 0xffe9,
        0xA5 => 0xffea,
        else => null,
    };
}

/// True for a key whose keysym comes from the map even when the key gives
/// a character: the keys whose `WM_CHAR` is a control character, such as
/// Return (13) and Tab (9).
pub fn mapFirst(vk: u32) bool {
    return switch (vk) {
        0x08, 0x09, 0x0D, 0x1B, 0x20 => true,
        else => false,
    };
}

test "winkeys: the keys of the editor and the letters map to keysyms" {
    try std.testing.expectEqual(@as(?u32, 0xff0d), keysym(0x0D, false, false));
    try std.testing.expectEqual(@as(?u32, 0xff8d), keysym(0x0D, true, false));
    try std.testing.expectEqual(@as(?u32, 0xff51), keysym(0x25, true, false));
    try std.testing.expectEqual(@as(?u32, 'a'), keysym('A', false, false));
    try std.testing.expectEqual(@as(?u32, 'A'), keysym('A', false, true));
    try std.testing.expectEqual(@as(?u32, 0xffbe), keysym(0x70, false, false));
    try std.testing.expectEqual(@as(?u32, 0xffc9), keysym(0x7B, false, false));
    try std.testing.expectEqual(@as(?u32, 0xffe4), keysym(0x11, true, false));
    try std.testing.expectEqual(@as(?u32, null), keysym(0xBA, false, false));
}
