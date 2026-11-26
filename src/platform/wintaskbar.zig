//! The taskbar button of a window on Windows (ztk#61): progress, a
//! badge, and a flash for attention.
//!
//! The progress and the badge go through `ITaskbarList3`, which the
//! backend makes on first use with `CoCreateInstance` and `HrInit`.
//! `SetProgressState` gets the kind and `SetProgressValue` the value, in
//! steps of 1/1,000. The badge is an overlay icon: a red disc of 16 by
//! 16 pixels with the count in white digits of a 3 by 5 font (doubled
//! for one digit), and `+` for a count above 99. The shell copies the
//! icon, so the backend destroys it after `SetOverlayIcon`. The text of
//! the overlay for screen readers is the count.
//!
//! The shell takes these calls only after it made the button, and it
//! sends the registered message "TaskbarButtonCreated" to the window
//! then, and again after Explorer starts again. The backend keeps the
//! state of each window and applies it at that message.
//!
//! Attention is `FlashWindowEx` on the button: three flashes, or with
//! `critical` a flash until the window comes to the front.
//! The COM slots are from `shobjidl_core.h` of the Windows SDK.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const w32 = @import("win32.zig");
const com = @import("../sys/com.zig");
const plat = @import("platform.zig");
const wintray = @import("wintray.zig");
const GUID = com.GUID;

extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, flags: u32) callconv(.winapi) com.HRESULT;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;
extern "ole32" fn CoCreateInstance(clsid: *const GUID, outer: ?*anyopaque, ctx: u32, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) com.HRESULT;
extern "user32" fn DestroyIcon(icon: w32.HICON) callconv(.winapi) i32;
extern "user32" fn FlashWindowEx(info: *const FLASHWINFO) callconv(.winapi) i32;

const FLASHWINFO = extern struct {
    cbSize: u32 = @sizeOf(FLASHWINFO),
    hwnd: w32.HWND,
    dwFlags: u32,
    uCount: u32,
    dwTimeout: u32 = 0,
};
const FLASHW_TRAY: u32 = 0x2;
const FLASHW_TIMERNOFG: u32 = 0xC;

const CLSID_TaskbarList = GUID.parse("56fdf344-fd6d-11d0-958a-006097c9a090");
const IID_ITaskbarList3 = GUID.parse("ea1afb91-9e28-4b86-90e9-9e9f8a5eefaf");
const slot_hr_init = 3;
const slot_set_progress_value = 9;
const slot_set_progress_state = 10;
const slot_set_overlay_icon = 18;

pub const Taskbar = struct {
    list: ?*anyopaque = null,
    tried: bool = false,
    com_hr: com.HRESULT = -1,
    /// The message of the shell after it made the button of a window.
    button_created: w32.UINT = 0,

    pub fn init() Taskbar {
        return .{ .button_created = w32.RegisterWindowMessageW(std.unicode.utf8ToUtf16LeStringLiteral("TaskbarButtonCreated")) };
    }

    pub fn deinit(t: *Taskbar) void {
        if (t.list) |l| com.release(l);
        t.list = null;
        if (t.com_hr == 0 or t.com_hr == 1) CoUninitialize();
    }

    fn get(t: *Taskbar) ?*anyopaque {
        if (t.tried) return t.list;
        t.tried = true;
        // COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE
        t.com_hr = CoInitializeEx(null, 0x2 | 0x4);
        var obj: ?*anyopaque = null;
        if (CoCreateInstance(&CLSID_TaskbarList, null, 0x1, &IID_ITaskbarList3, &obj) < 0) return null;
        const l = obj orelse return null;
        if (com.call(com.HRESULT, l, slot_hr_init, .{}) < 0) {
            com.release(l);
            return null;
        }
        t.list = l;
        return l;
    }

    /// Shows the state on the button of `hwnd`. Before the button exists
    /// the shell refuses the calls, and the message of the button
    /// applies the state again.
    pub fn apply(t: *Taskbar, hwnd: w32.HWND, s: plat.Taskbar) void {
        const l = t.get() orelse return;
        const flag: u32 = switch (s.progress) {
            .none => 0,
            .indeterminate => 1,
            .normal => 2,
            .failed => 4,
            .paused => 8,
        };
        _ = com.call(com.HRESULT, l, slot_set_progress_state, .{ hwnd, flag });
        if (flag >= 2) {
            const done: u64 = @intFromFloat(std.math.clamp(s.value, 0, 1) * 1000);
            _ = com.call(com.HRESULT, l, slot_set_progress_value, .{ hwnd, done, @as(u64, 1000) });
        }
        if (s.badge == 0) {
            _ = com.call(com.HRESULT, l, slot_set_overlay_icon, .{ hwnd, @as(?w32.HICON, null), @as(?[*:0]const u16, null) });
            return;
        }
        var px: [16 * 16 * 4]u8 = undefined;
        badge(&px, s.badge);
        const icon = wintray.makeIcon(.{ .width = 16, .height = 16, .pixels = &px }) orelse return;
        defer _ = DestroyIcon(icon);
        var text: [16]u16 = undefined;
        var digits: [12]u8 = undefined;
        const d = std.fmt.bufPrint(&digits, "{d}", .{s.badge}) catch unreachable;
        for (d, 0..) |c, i| text[i] = c;
        text[d.len] = 0;
        _ = com.call(com.HRESULT, l, slot_set_overlay_icon, .{ hwnd, @as(?w32.HICON, icon), @as(?[*:0]const u16, text[0..d.len :0].ptr) });
    }
};

pub fn flash(hwnd: w32.HWND, critical: bool) void {
    const info: FLASHWINFO = .{
        .hwnd = hwnd,
        .dwFlags = FLASHW_TRAY | (if (critical) FLASHW_TIMERNOFG else 0),
        .uCount = if (critical) @as(u32, 0) else 3,
    };
    _ = FlashWindowEx(&info);
}

/// The rows of the glyphs of the badge, 3 bits each, the left bit first.
const glyphs = [11][5]u3{
    .{ 7, 5, 5, 5, 7 }, .{ 2, 6, 2, 2, 7 }, .{ 7, 1, 7, 4, 7 }, .{ 7, 1, 7, 1, 7 },
    .{ 5, 5, 7, 1, 1 }, .{ 7, 4, 7, 1, 7 }, .{ 7, 4, 7, 5, 7 }, .{ 7, 1, 1, 1, 1 },
    .{ 7, 5, 7, 5, 7 }, .{ 7, 5, 7, 1, 7 }, .{ 0, 2, 7, 2, 0 },
};

/// Draws the badge of `count` into 16 by 16 RGBA pixels.
pub fn badge(px: *[16 * 16 * 4]u8, count: u32) void {
    @memset(px, 0);
    for (0..16) |y| for (0..16) |x| {
        const dx = @as(f32, @floatFromInt(x)) + 0.5 - 8;
        const dy = @as(f32, @floatFromInt(y)) + 0.5 - 8;
        if (dx * dx + dy * dy <= 7.6 * 7.6) set(px, x, y, .{ 0xd1, 0x34, 0x38 });
    };
    var chars: [3]u8 = undefined;
    const text: []const u8 = if (count > 99) "+" else std.fmt.bufPrint(&chars, "{d}", .{count}) catch unreachable;
    const scale: usize = if (text.len == 1) 2 else 1;
    const w = (text.len * 4 - 1) * scale;
    const x0 = (16 - w) / 2;
    const y0 = (16 - 5 * scale) / 2;
    for (text, 0..) |c, i| {
        const g = glyphs[if (c == '+') 10 else c - '0'];
        for (0..5) |row| for (0..3) |col| {
            if ((g[row] >> @intCast(2 - col)) & 1 == 0) continue;
            for (0..scale) |sy| for (0..scale) |sx|
                set(px, x0 + (i * 4 + col) * scale + sx, y0 + row * scale + sy, .{ 0xff, 0xff, 0xff });
        };
    }
}

fn set(px: *[16 * 16 * 4]u8, x: usize, y: usize, rgb: [3]u8) void {
    const i = (y * 16 + x) * 4;
    px[i] = rgb[0];
    px[i + 1] = rgb[1];
    px[i + 2] = rgb[2];
    px[i + 3] = 0xff;
}

test "wintaskbar: the badge has a red disc and white digits in the middle" {
    var px: [16 * 16 * 4]u8 = undefined;
    badge(&px, 7);
    // The corner is clear, the edge of the disc is red, and the digit 7
    // (doubled, 6 by 10 from (5, 3)) starts with a white top row.
    try std.testing.expectEqual(@as(u8, 0), px[3]);
    try std.testing.expectEqualSlices(u8, &.{ 0xd1, 0x34, 0x38, 0xff }, px[(8 * 16 + 1) * 4 ..][0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xff, 0xff, 0xff }, px[(3 * 16 + 5) * 4 ..][0..4]);
    badge(&px, 1000);
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xff, 0xff, 0xff }, px[(8 * 16 + 8) * 4 ..][0..4]);
}
