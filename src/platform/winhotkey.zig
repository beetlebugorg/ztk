//! The global shortcuts of Windows (ztk#63): `RegisterHotKey` on the
//! window of the shortcut, with `MOD_NOREPEAT`, so a held key gives one
//! press. Windows sends `WM_HOTKEY` with the id to that window, and the
//! backend queues a `hotkey` event. A shortcut that another app has
//! fails, and the backend gives the id 0.
//!
//! The key of a keysym is the inverse of `winkeys.keysym`: a letter is
//! the virtual key of its upper case, and the keys with no character
//! come from a search of the map. Another Latin-1 character gets its key
//! and its Shift state from `VkKeyScanW` on the keyboard layout of the
//! thread.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const w32 = @import("win32.zig");
const event = @import("../event.zig");
const winkeys = @import("winkeys.zig");

extern "user32" fn RegisterHotKey(hwnd: ?w32.HWND, id: i32, mods: u32, vk: u32) callconv(.winapi) i32;
extern "user32" fn UnregisterHotKey(hwnd: ?w32.HWND, id: i32) callconv(.winapi) i32;
extern "user32" fn VkKeyScanW(ch: u16) callconv(.winapi) i16;

pub const WM_HOTKEY: u32 = 0x0312;
const MOD_ALT: u32 = 0x1;
const MOD_CONTROL: u32 = 0x2;
const MOD_SHIFT: u32 = 0x4;
const MOD_WIN: u32 = 0x8;
const MOD_NOREPEAT: u32 = 0x4000;

pub const Key = struct { vk: u32, shift: bool = false };

/// The virtual key of a keysym, or null.
pub fn vkOf(sym: u32) ?Key {
    if (sym >= 'a' and sym <= 'z') return .{ .vk = sym - 32 };
    if (sym >= 'A' and sym <= 'Z') return .{ .vk = sym, .shift = true };
    if (sym >= '0' and sym <= '9') return .{ .vk = sym };
    var vk: u32 = 1;
    while (vk < 0xff) : (vk += 1) {
        if (winkeys.keysym(vk, false, false) == sym) return .{ .vk = vk };
        if (winkeys.keysym(vk, true, false) == sym) return .{ .vk = vk };
    }
    if (sym >= 0x20 and sym < 0x100) {
        const r = VkKeyScanW(@intCast(sym));
        if (r == -1) return null;
        const bits: u16 = @bitCast(r);
        return .{ .vk = bits & 0xff, .shift = bits & 0x100 != 0 };
    }
    return null;
}

/// The flags of `RegisterHotKey` for the modifiers of a shortcut.
pub fn flags(mods: event.Mods, key: Key) u32 {
    var f: u32 = MOD_NOREPEAT;
    if (mods.mod1) f |= MOD_ALT;
    if (mods.control) f |= MOD_CONTROL;
    if (mods.shift or key.shift) f |= MOD_SHIFT;
    if (mods.mod4) f |= MOD_WIN;
    return f;
}

/// Registers the shortcut with `id` on `hwnd`. False when Windows
/// refuses it or the key has no virtual key.
pub fn register(hwnd: w32.HWND, id: u32, mods: event.Mods, sym: u32) bool {
    const key = vkOf(sym) orelse return false;
    return RegisterHotKey(hwnd, @intCast(id), flags(mods, key), key.vk) != 0;
}

pub fn unregister(hwnd: w32.HWND, id: u32) void {
    _ = UnregisterHotKey(hwnd, @intCast(id));
}

test "winhotkey: the virtual keys and the flags of a shortcut" {
    try std.testing.expectEqual(@as(u32, 'K'), vkOf('k').?.vk);
    try std.testing.expect(vkOf('K').?.shift);
    try std.testing.expectEqual(@as(u32, 0x74), vkOf(0xffc2).?.vk); // F5
    try std.testing.expectEqual(@as(u32, 0x0D), vkOf(0xff0d).?.vk); // Return
    try std.testing.expectEqual(@as(u32, 0x25), vkOf(0xff51).?.vk); // Left
    try std.testing.expectEqual(MOD_NOREPEAT | MOD_CONTROL | MOD_ALT, flags(.{ .control = true, .mod1 = true }, .{ .vk = 'K' }));
    try std.testing.expectEqual(MOD_NOREPEAT | MOD_SHIFT | MOD_WIN, flags(.{ .mod4 = true }, .{ .vk = 'K', .shift = true }));
}
