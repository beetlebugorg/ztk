//! The window state of the Win32 backend (ztk#68): full screen, topmost,
//! and the setting of the system for less motion.
//!
//! - Full screen: the window takes the style `WS_POPUP` with no frame
//!   and the rect of its monitor (`MonitorFromWindow`). The style and the
//!   rect before it come back at the end, as other Windows programs do
//!   with F11. No call shows a hidden window.
//! - Topmost: `SetWindowPos` with `HWND_TOPMOST` or `HWND_NOTOPMOST`.
//! - Less motion: `SPI_GETCLIENTAREAANIMATION` gives false when the user
//!   turned the animation effects off (Settings, Accessibility, Visual
//!   effects).
//!
//! The constants and the structures follow `WinUser.h` of the Windows
//! SDK 10.0.26100.0.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const w32 = @import("win32.zig");
const plat = @import("platform.zig");

pub const GWL_STYLE: c_int = -16;
pub const GWL_EXSTYLE: c_int = -20;
pub const WS_EX_TOPMOST: u32 = 0x8;
const WS_CAPTION: u32 = 0x00C00000;
const WS_THICKFRAME: u32 = 0x00040000;
const WS_SYSMENU: u32 = 0x00080000;
const WS_MINIMIZEBOX: u32 = 0x00020000;
const WS_MAXIMIZEBOX: u32 = 0x00010000;
const frame_styles = WS_CAPTION | WS_THICKFRAME | WS_SYSMENU | WS_MINIMIZEBOX | WS_MAXIMIZEBOX;

const SWP_NOSIZE: u32 = 0x0001;
const SWP_NOMOVE: u32 = 0x0002;
const SWP_NOZORDER: u32 = 0x0004;
const SWP_NOACTIVATE: u32 = 0x0010;
const SWP_FRAMECHANGED: u32 = 0x0020;
const SWP_NOOWNERZORDER: u32 = 0x0200;
const MONITOR_DEFAULTTONEAREST: u32 = 2;
const SPI_GETCLIENTAREAANIMATION: u32 = 0x1042;

const MONITORINFO = extern struct {
    cbSize: u32 = @sizeOf(MONITORINFO),
    rcMonitor: w32.RECT = .{},
    rcWork: w32.RECT = .{},
    dwFlags: u32 = 0,
};

extern "user32" fn GetWindowRect(h: w32.HWND, r: *w32.RECT) callconv(.winapi) i32;
extern "user32" fn MonitorFromWindow(h: w32.HWND, flags: u32) callconv(.winapi) ?*anyopaque;
extern "user32" fn GetMonitorInfoW(m: *anyopaque, info: *MONITORINFO) callconv(.winapi) i32;
extern "user32" fn SystemParametersInfoW(action: u32, param: u32, out: ?*anyopaque, flags: u32) callconv(.winapi) i32;

/// HWND_TOPMOST is -1 and HWND_NOTOPMOST is -2.
fn after(topmost: bool) w32.HWND {
    const v: isize = if (topmost) -1 else -2;
    return @ptrFromInt(@as(usize, @bitCast(v)));
}

/// The style and the rect of a window before its full screen.
pub const Saved = struct { style: isize, rect: w32.RECT };

/// Puts the window into full screen or back. `saved` keeps the style and
/// the rect of the window in between.
pub fn setFullscreen(hwnd: w32.HWND, on: bool, saved: *?Saved) void {
    const flags = SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_FRAMECHANGED | SWP_NOZORDER;
    if (on) {
        if (saved.* != null) return;
        var r: w32.RECT = .{};
        if (GetWindowRect(hwnd, &r) == 0) return;
        const style = w32.GetWindowLongPtrW(hwnd, GWL_STYLE);
        const m = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST) orelse return;
        var info: MONITORINFO = .{};
        if (GetMonitorInfoW(m, &info) == 0) return;
        saved.* = .{ .style = style, .rect = r };
        const bits: usize = @bitCast(style);
        const popup = (bits & ~@as(usize, frame_styles)) | w32.WS_POPUP;
        _ = w32.SetWindowLongPtrW(hwnd, GWL_STYLE, @bitCast(popup));
        const mr = info.rcMonitor;
        _ = w32.SetWindowPos(hwnd, null, mr.left, mr.top, mr.right - mr.left, mr.bottom - mr.top, flags);
    } else {
        const s = saved.* orelse return;
        saved.* = null;
        _ = w32.SetWindowLongPtrW(hwnd, GWL_STYLE, s.style);
        const r = s.rect;
        _ = w32.SetWindowPos(hwnd, null, r.left, r.top, r.right - r.left, r.bottom - r.top, flags);
    }
}

extern "user32" fn IsZoomed(hwnd: w32.HWND) callconv(.winapi) i32;
extern "user32" fn IsWindowVisible(hwnd: w32.HWND) callconv(.winapi) i32;
const SW_MAXIMIZE: c_int = 3;
const SW_RESTORE: c_int = 9;

/// True when the window is maximized. A hidden window gives `wanted`,
/// the state that `setZoomed` kept for it.
pub fn zoomed(hwnd: w32.HWND, wanted: bool) bool {
    if (IsWindowVisible(hwnd) == 0) return wanted;
    return IsZoomed(hwnd) != 0;
}

/// Maximizes a window that shows, or puts it back. `ShowWindow` with
/// SW_MAXIMIZE shows a hidden window, so a hidden window only keeps the
/// state in `wanted`.
pub fn setZoomed(hwnd: w32.HWND, on: bool, wanted: *bool) void {
    wanted.* = on;
    if (IsWindowVisible(hwnd) == 0) return;
    if ((IsZoomed(hwnd) != 0) == on) return;
    _ = w32.ShowWindow(hwnd, if (on) SW_MAXIMIZE else SW_RESTORE);
}

pub fn setTopmost(hwnd: w32.HWND, on: bool) void {
    _ = w32.SetWindowPos(hwnd, after(on), 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
}

/// True when the user asked for less motion: the animations of the client
/// area are off.
pub fn reducedMotion() bool {
    var on: i32 = 1;
    if (SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION, 0, &on, 0) == 0) return false;
    return on == 0;
}

extern "dwmapi" fn DwmSetWindowAttribute(h: w32.HWND, attr: u32, value: *const anyopaque, size: u32) callconv(.winapi) i32;

/// DWMWA_SYSTEMBACKDROP_TYPE, from Windows 11 22H2. False on a system
/// with no such attribute.
pub fn setBackdrop(hwnd: w32.HWND, kind: plat.Backdrop) bool {
    const v: u32 = @backingInt(kind);
    return DwmSetWindowAttribute(hwnd, 38, &v, 4) >= 0;
}

/// DWMWA_USE_IMMERSIVE_DARK_MODE (20, from Windows 10 20H1): the title
/// bar and the frame of the system in the dark or the light scheme. False
/// on a system with no such attribute.
pub fn setDark(hwnd: w32.HWND, dark: bool) bool {
    const v: i32 = @intFromBool(dark);
    return DwmSetWindowAttribute(hwnd, 20, &v, 4) >= 0;
}

extern "dwmapi" fn DwmGetWindowAttribute(h: w32.HWND, attr: u32, value: *anyopaque, size: u32) callconv(.winapi) i32;

/// The dark scheme of the title bar of a window, for the tests, or null.
pub fn isDark(hwnd: w32.HWND) ?bool {
    var v: i32 = 0;
    if (DwmGetWindowAttribute(hwnd, 20, &v, 4) < 0) return null;
    return v != 0;
}
