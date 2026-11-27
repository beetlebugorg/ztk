//! The Win32 functions, types, and constants that the Windows backend
//! calls, from `user32`, `kernel32`, `gdi32`, `dwmapi`, and `advapi32`.
//! The standard library of Zig declares few of them. Each declaration
//! follows the headers of the Windows SDK. Strings are
//! UTF-16, and the `W` form of each function is the one declared. The
//! file has no logic beyond `loword` and `hiword`.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

pub const BOOL = c_int;
pub const UINT = c_uint;
pub const DWORD = u32;
pub const WORD = u16;
pub const LONG = i32;
pub const ATOM = u16;
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const LRESULT = isize;
pub const HANDLE = *anyopaque;
pub const HWND = *opaque {};
pub const HINSTANCE = *opaque {};
pub const HICON = *opaque {};
pub const HCURSOR = *opaque {};
pub const HBRUSH = *opaque {};
pub const HMENU = *opaque {};
pub const HDC = *opaque {};
pub const HMONITOR = *opaque {};
pub const HGLOBAL = *anyopaque;
pub const LPCWSTR = [*:0]const u16;
pub const DPI_AWARENESS_CONTEXT = isize;

pub const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;

pub const POINT = extern struct { x: LONG = 0, y: LONG = 0 };
pub const RECT = extern struct { left: LONG = 0, top: LONG = 0, right: LONG = 0, bottom: LONG = 0 };

pub const MSG = extern struct {
    hwnd: ?HWND = null,
    message: UINT = 0,
    wParam: WPARAM = 0,
    lParam: LPARAM = 0,
    time: DWORD = 0,
    pt: POINT = .{},
    lPrivate: DWORD = 0,
};

pub const WNDCLASSEXW = extern struct {
    cbSize: UINT = @sizeOf(WNDCLASSEXW),
    style: UINT = 0,
    lpfnWndProc: WNDPROC,
    cbClsExtra: c_int = 0,
    cbWndExtra: c_int = 0,
    hInstance: ?HINSTANCE = null,
    hIcon: ?HICON = null,
    hCursor: ?HCURSOR = null,
    hbrBackground: ?HBRUSH = null,
    lpszMenuName: ?LPCWSTR = null,
    lpszClassName: LPCWSTR,
    hIconSm: ?HICON = null,
};

pub const BITMAPINFOHEADER = extern struct {
    biSize: DWORD = @sizeOf(BITMAPINFOHEADER),
    biWidth: LONG = 0,
    biHeight: LONG = 0,
    biPlanes: WORD = 1,
    biBitCount: WORD = 32,
    biCompression: DWORD = 0,
    biSizeImage: DWORD = 0,
    biXPelsPerMeter: LONG = 0,
    biYPelsPerMeter: LONG = 0,
    biClrUsed: DWORD = 0,
    biClrImportant: DWORD = 0,
};

// Window styles.
pub const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF0000;
pub const WS_VISIBLE: DWORD = 0x10000000;
pub const WS_POPUP: DWORD = 0x80000000;
pub const CS_HREDRAW: UINT = 0x0002;
pub const CS_VREDRAW: UINT = 0x0001;
pub const CS_OWNDC: UINT = 0x0020;
pub const CW_USEDEFAULT: c_int = @bitCast(@as(u32, 0x80000000));
pub const GWLP_USERDATA: c_int = -21;

// SetWindowPos and ShowWindow.
pub const SWP_NOZORDER: UINT = 0x0004;
pub const SWP_NOACTIVATE: UINT = 0x0010;
pub const SWP_NOMOVE: UINT = 0x0002;
pub const SW_SHOW: c_int = 5;

// Messages.
pub const WM_DESTROY: UINT = 0x0002;
pub const WM_SIZE: UINT = 0x0005;
pub const WM_SETFOCUS: UINT = 0x0007;
pub const WM_KILLFOCUS: UINT = 0x0008;
pub const WM_PAINT: UINT = 0x000F;
pub const WM_CLOSE: UINT = 0x0010;
pub const WM_ERASEBKGND: UINT = 0x0014;
pub const WM_SETTINGCHANGE: UINT = 0x001A;
pub const WM_SETCURSOR: UINT = 0x0020;
pub const WM_GETMINMAXINFO: UINT = 0x0024;
pub const WM_KEYDOWN: UINT = 0x0100;
pub const WM_KEYUP: UINT = 0x0101;
pub const WM_CHAR: UINT = 0x0102;
pub const WM_SYSKEYDOWN: UINT = 0x0104;
pub const WM_SYSKEYUP: UINT = 0x0105;
pub const WM_SYSCHAR: UINT = 0x0106;
pub const WM_TIMER: UINT = 0x0113;
pub const WM_MOUSEMOVE: UINT = 0x0200;
pub const WM_LBUTTONDOWN: UINT = 0x0201;
pub const WM_LBUTTONUP: UINT = 0x0202;
pub const WM_RBUTTONDOWN: UINT = 0x0204;
pub const WM_RBUTTONUP: UINT = 0x0205;
pub const WM_MBUTTONDOWN: UINT = 0x0207;
pub const WM_MBUTTONUP: UINT = 0x0208;
pub const WM_MOUSEWHEEL: UINT = 0x020A;
pub const WM_XBUTTONDOWN: UINT = 0x020B;
pub const WM_XBUTTONUP: UINT = 0x020C;
pub const WM_MOUSEHWHEEL: UINT = 0x020E;
pub const WM_ENTERSIZEMOVE: UINT = 0x0231;
pub const WM_EXITSIZEMOVE: UINT = 0x0232;
pub const WM_MOUSELEAVE: UINT = 0x02A3;
pub const WM_DPICHANGED: UINT = 0x02E0;
pub const WM_DWMCOLORIZATIONCOLORCHANGED: UINT = 0x0320;
pub const WM_USER: UINT = 0x0400;
pub const WHEEL_DELTA: f32 = 120;
pub const HTCLIENT: LRESULT = 1;

// PeekMessage and MsgWaitForMultipleObjectsEx.
pub const PM_REMOVE: UINT = 0x0001;
pub const QS_ALLINPUT: DWORD = 0x04FF;
pub const MWMO_INPUTAVAILABLE: DWORD = 0x0004;
pub const WAIT_OBJECT_0: DWORD = 0;
pub const WAIT_TIMEOUT: DWORD = 258;
pub const INFINITE: DWORD = 0xFFFFFFFF;

// TrackMouseEvent.
pub const TME_LEAVE: DWORD = 0x0002;
pub const TRACKMOUSEEVENT = extern struct { cbSize: DWORD = @sizeOf(TRACKMOUSEEVENT), dwFlags: DWORD = 0, hwndTrack: ?HWND = null, dwHoverTime: DWORD = 0 };

// Per-monitor scale.
pub const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: DPI_AWARENESS_CONTEXT = -4;
pub const USER_DEFAULT_SCREEN_DPI: UINT = 96;

// Cursors: the resource numbers of the shapes of the system.
pub const IDC_ARROW: usize = 32512;
pub const IDC_IBEAM: usize = 32513;
pub const IDC_WAIT: usize = 32514;
pub const IDC_CROSS: usize = 32515;
pub const IDC_SIZENWSE: usize = 32642;
pub const IDC_SIZENESW: usize = 32643;
pub const IDC_SIZEWE: usize = 32644;
pub const IDC_SIZENS: usize = 32645;
pub const IDC_SIZEALL: usize = 32646;
pub const IDC_NO: usize = 32648;
pub const IDC_HAND: usize = 32649;
pub const IDC_APPSTARTING: usize = 32650;
pub const IDC_HELP: usize = 32651;

// Clipboard.
pub const CF_UNICODETEXT: UINT = 13;
pub const GMEM_MOVEABLE: UINT = 0x0002;

// Virtual keys that the key map and the modifier state read.
pub const VK_SHIFT: c_int = 0x10;
pub const VK_CONTROL: c_int = 0x11;
pub const VK_MENU: c_int = 0x12;
pub const VK_CAPITAL: c_int = 0x14;
pub const VK_LWIN: c_int = 0x5B;
pub const VK_RWIN: c_int = 0x5C;

// Waitable timers.
pub const CREATE_WAITABLE_TIMER_MANUAL_RESET: DWORD = 0x00000001;
pub const CREATE_WAITABLE_TIMER_HIGH_RESOLUTION: DWORD = 0x00000002;
pub const TIMER_ALL_ACCESS: DWORD = 0x1F0003;

// Registry.
pub const HKEY = *opaque {};
pub const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x80000001);
pub const RRF_RT_REG_DWORD: DWORD = 0x00000010;

pub extern "kernel32" fn GetModuleHandleW(name: ?LPCWSTR) callconv(.winapi) ?HINSTANCE;
pub extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
pub extern "kernel32" fn QueryPerformanceCounter(count: *i64) callconv(.winapi) BOOL;
pub extern "kernel32" fn QueryPerformanceFrequency(freq: *i64) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateWaitableTimerExW(attrs: ?*anyopaque, name: ?LPCWSTR, flags: DWORD, access: DWORD) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn SetWaitableTimer(timer: HANDLE, due: *const i64, period: LONG, routine: ?*anyopaque, arg: ?*anyopaque, resume_: BOOL) callconv(.winapi) BOOL;
pub extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn GlobalAlloc(flags: UINT, bytes: usize) callconv(.winapi) ?HGLOBAL;
pub extern "kernel32" fn GlobalFree(mem: HGLOBAL) callconv(.winapi) ?HGLOBAL;
pub extern "kernel32" fn GlobalLock(mem: HGLOBAL) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn GlobalUnlock(mem: HGLOBAL) callconv(.winapi) BOOL;
pub extern "kernel32" fn GlobalSize(mem: HGLOBAL) callconv(.winapi) usize;

pub extern "user32" fn RegisterClassExW(cls: *const WNDCLASSEXW) callconv(.winapi) ATOM;
pub extern "user32" fn UnregisterClassW(name: LPCWSTR, inst: ?HINSTANCE) callconv(.winapi) BOOL;
pub extern "user32" fn CreateWindowExW(ex_style: DWORD, class: LPCWSTR, title: LPCWSTR, style: DWORD, x: c_int, y: c_int, w: c_int, h: c_int, parent: ?HWND, menu: ?HMENU, inst: ?HINSTANCE, param: ?*anyopaque) callconv(.winapi) ?HWND;
pub extern "user32" fn DestroyWindow(hwnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn DefWindowProcW(hwnd: HWND, msg: UINT, wp: WPARAM, lp: LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn ShowWindow(hwnd: HWND, cmd: c_int) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowTextW(hwnd: HWND, text: LPCWSTR) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowPos(hwnd: HWND, after: ?HWND, x: c_int, y: c_int, w: c_int, h: c_int, flags: UINT) callconv(.winapi) BOOL;
pub extern "user32" fn GetClientRect(hwnd: HWND, r: *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowLongPtrW(hwnd: HWND, index: c_int) callconv(.winapi) isize;
pub extern "user32" fn SetWindowLongPtrW(hwnd: HWND, index: c_int, value: isize) callconv(.winapi) isize;
pub extern "user32" fn PeekMessageW(msg: *MSG, hwnd: ?HWND, min: UINT, max: UINT, remove: UINT) callconv(.winapi) BOOL;
pub extern "user32" fn TranslateMessage(msg: *const MSG) callconv(.winapi) BOOL;
pub extern "user32" fn DispatchMessageW(msg: *const MSG) callconv(.winapi) LRESULT;
pub extern "user32" fn SendMessageW(hwnd: HWND, msg: UINT, wp: WPARAM, lp: LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn PostMessageW(hwnd: ?HWND, msg: UINT, wp: WPARAM, lp: LPARAM) callconv(.winapi) BOOL;
pub extern "user32" fn MsgWaitForMultipleObjectsEx(count: DWORD, handles: ?[*]const HANDLE, ms: DWORD, wake: DWORD, flags: DWORD) callconv(.winapi) DWORD;
pub extern "user32" fn SetProcessDpiAwarenessContext(ctx: DPI_AWARENESS_CONTEXT) callconv(.winapi) BOOL;
pub extern "user32" fn GetDpiForWindow(hwnd: HWND) callconv(.winapi) UINT;
pub extern "user32" fn AdjustWindowRectExForDpi(r: *RECT, style: DWORD, menu: BOOL, ex_style: DWORD, dpi: UINT) callconv(.winapi) BOOL;
pub extern "user32" fn LoadCursorW(inst: ?HINSTANCE, name: usize) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn SetCursor(cur: ?HCURSOR) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn GetKeyState(vk: c_int) callconv(.winapi) i16;
pub extern "user32" fn TrackMouseEvent(tme: *TRACKMOUSEEVENT) callconv(.winapi) BOOL;
pub extern "user32" fn SetCapture(hwnd: HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
pub extern "user32" fn ScreenToClient(hwnd: HWND, p: *POINT) callconv(.winapi) BOOL;
pub extern "user32" fn GetMessageTime() callconv(.winapi) LONG;
pub extern "user32" fn GetDC(hwnd: ?HWND) callconv(.winapi) ?HDC;
pub extern "user32" fn ReleaseDC(hwnd: ?HWND, dc: HDC) callconv(.winapi) c_int;
pub extern "user32" fn ValidateRect(hwnd: HWND, r: ?*const RECT) callconv(.winapi) BOOL;
pub extern "user32" fn OpenClipboard(owner: ?HWND) callconv(.winapi) BOOL;
pub extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn GetClipboardData(format: UINT) callconv(.winapi) ?HANDLE;
pub extern "user32" fn SetClipboardData(format: UINT, mem: ?HANDLE) callconv(.winapi) ?HANDLE;
pub extern "user32" fn GetClipboardSequenceNumber() callconv(.winapi) DWORD;

pub extern "gdi32" fn SetDIBitsToDevice(dc: HDC, x: c_int, y: c_int, w: DWORD, h: DWORD, sx: c_int, sy: c_int, start: UINT, lines: UINT, bits: *const anyopaque, info: *const BITMAPINFOHEADER, usage: UINT) callconv(.winapi) c_int;

pub extern "dwmapi" fn DwmGetColorizationColor(color: *DWORD, opaque_blend: *BOOL) callconv(.winapi) i32;

pub extern "advapi32" fn RegGetValueW(key: HKEY, sub: ?LPCWSTR, value: ?LPCWSTR, flags: DWORD, typ: ?*DWORD, data: ?*anyopaque, len: ?*DWORD) callconv(.winapi) LONG;

/// The low and high words of a message parameter, with the sign of a
/// coordinate.
pub fn loword(v: anytype) i16 {
    return @bitCast(@as(u16, @truncate(@as(usize, @bitCast(@as(isize, @intCast(v)))))));
}
pub fn hiword(v: anytype) i16 {
    return @bitCast(@as(u16, @truncate(@as(usize, @bitCast(@as(isize, @intCast(v)))) >> 16)));
}

test "win32: loword and hiword keep the sign of a coordinate" {
    const lp: isize = @bitCast(@as(usize, 0xFFF6_0014));
    try std.testing.expectEqual(@as(i16, 20), loword(lp));
    try std.testing.expectEqual(@as(i16, -10), hiword(lp));
}

// Menus.
pub const MENUITEMINFOW = extern struct {
    cbSize: UINT = @sizeOf(MENUITEMINFOW),
    fMask: UINT = 0,
    fType: UINT = 0,
    fState: UINT = 0,
    wID: UINT = 0,
    hSubMenu: ?HMENU = null,
    hbmpChecked: ?*anyopaque = null,
    hbmpUnchecked: ?*anyopaque = null,
    dwItemData: usize = 0,
    dwTypeData: ?[*:0]u16 = null,
    cch: UINT = 0,
    hbmpItem: ?*anyopaque = null,
};
pub const MENUINFO = extern struct {
    cbSize: DWORD = @sizeOf(MENUINFO),
    fMask: DWORD = 0,
    dwStyle: DWORD = 0,
    cyMax: UINT = 0,
    hbrBack: ?HBRUSH = null,
    dwContextHelpID: DWORD = 0,
    dwMenuData: usize = 0,
};
pub const MIIM_STATE: UINT = 0x1;
pub const MIIM_ID: UINT = 0x2;
pub const MIIM_SUBMENU: UINT = 0x4;
pub const MIIM_STRING: UINT = 0x40;
pub const MIIM_FTYPE: UINT = 0x100;
pub const MFT_STRING: UINT = 0;
pub const MFT_MENUBARBREAK: UINT = 0x20;
pub const MFT_RADIOCHECK: UINT = 0x200;
pub const MFT_SEPARATOR: UINT = 0x800;
pub const MFT_RIGHTJUSTIFY: UINT = 0x4000;
pub const MFS_GRAYED: UINT = 0x3;
pub const MFS_CHECKED: UINT = 0x8;
pub const MF_BYPOSITION: UINT = 0x400;
pub const MF_POPUP: UINT = 0x10;
pub const MF_SYSMENU: UINT = 0x2000;
pub const MIM_STYLE: DWORD = 0x10;
pub const MNS_NOTIFYBYPOS: DWORD = 0x08000000;
pub const TPM_RIGHTBUTTON: UINT = 0x2;
pub const WM_INITMENUPOPUP: UINT = 0x0117;
pub const WM_MENUSELECT: UINT = 0x011F;
pub const WM_UNINITMENUPOPUP: UINT = 0x0125;
pub const WM_MENUCOMMAND: UINT = 0x0126;

pub extern "user32" fn CreateMenu() callconv(.winapi) ?HMENU;
pub extern "user32" fn CreatePopupMenu() callconv(.winapi) ?HMENU;
pub extern "user32" fn DestroyMenu(m: HMENU) callconv(.winapi) BOOL;
pub extern "user32" fn IsMenu(m: HMENU) callconv(.winapi) BOOL;
pub extern "user32" fn InsertMenuItemW(m: HMENU, item: UINT, by_position: BOOL, info: *const MENUITEMINFOW) callconv(.winapi) BOOL;
pub extern "user32" fn SetMenuItemInfoW(m: HMENU, item: UINT, by_position: BOOL, info: *const MENUITEMINFOW) callconv(.winapi) BOOL;
pub extern "user32" fn GetMenuItemInfoW(m: HMENU, item: UINT, by_position: BOOL, info: *MENUITEMINFOW) callconv(.winapi) BOOL;
pub extern "user32" fn RemoveMenu(m: HMENU, pos: UINT, flags: UINT) callconv(.winapi) BOOL;
pub extern "user32" fn GetMenuItemCount(m: HMENU) callconv(.winapi) c_int;
pub extern "user32" fn SetMenuInfo(m: HMENU, info: *const MENUINFO) callconv(.winapi) BOOL;
pub extern "user32" fn SetMenu(hwnd: HWND, m: ?HMENU) callconv(.winapi) BOOL;
pub extern "user32" fn GetMenu(hwnd: HWND) callconv(.winapi) ?HMENU;
pub extern "user32" fn DrawMenuBar(hwnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn TrackPopupMenuEx(m: HMENU, flags: UINT, x: c_int, y: c_int, hwnd: HWND, params: ?*anyopaque) callconv(.winapi) BOOL;
pub extern "user32" fn EndMenu() callconv(.winapi) BOOL;
pub extern "user32" fn ClientToScreen(hwnd: HWND, p: *POINT) callconv(.winapi) BOOL;
// Tray icons and icons from pixels.
pub const NOTIFYICONDATAW = extern struct {
    cbSize: DWORD = @sizeOf(NOTIFYICONDATAW),
    hWnd: ?HWND = null,
    uID: UINT = 0,
    uFlags: UINT = 0,
    uCallbackMessage: UINT = 0,
    hIcon: ?HICON = null,
    szTip: [128]u16 = @splat(0),
    dwState: DWORD = 0,
    dwStateMask: DWORD = 0,
    szInfo: [256]u16 = @splat(0),
    uVersion: UINT = 0,
    szInfoTitle: [64]u16 = @splat(0),
    dwInfoFlags: DWORD = 0,
    guidItem: [16]u8 align(4) = @splat(0),
    hBalloonIcon: ?HICON = null,
};
pub const ICONINFO = extern struct { fIcon: BOOL = 1, xHotspot: DWORD = 0, yHotspot: DWORD = 0, hbmMask: ?*anyopaque = null, hbmColor: ?*anyopaque = null };
pub const NIM_ADD: DWORD = 0;
pub const NIM_MODIFY: DWORD = 1;
pub const NIM_DELETE: DWORD = 2;
pub const NIM_SETVERSION: DWORD = 4;
pub const NIF_MESSAGE: UINT = 0x1;
pub const NIF_ICON: UINT = 0x2;
pub const NIF_TIP: UINT = 0x4;
pub const NIF_SHOWTIP: UINT = 0x80;
pub const NOTIFYICON_VERSION_4: UINT = 4;
pub const NIN_SELECT: UINT = 0x400;
pub const NIN_KEYSELECT: UINT = 0x401;
pub const WM_NULL: UINT = 0x0000;
pub const WM_CONTEXTMENU: UINT = 0x007B;
pub const WM_LBUTTONDBLCLK: UINT = 0x0203;
pub const WM_APP: UINT = 0x8000;
pub const IDI_APPLICATION: usize = 32512;

pub extern "shell32" fn Shell_NotifyIconW(message: DWORD, data: *NOTIFYICONDATAW) callconv(.winapi) BOOL;
pub extern "user32" fn CreateIconIndirect(info: *const ICONINFO) callconv(.winapi) ?HICON;
pub extern "user32" fn DestroyIcon(icon: HICON) callconv(.winapi) BOOL;
pub extern "user32" fn GetSystemMetricsForDpi(index: c_int, dpi: UINT) callconv(.winapi) c_int;
pub const SM_CXICON: c_int = 11;
pub const SM_CXSMICON: c_int = 49;
pub const WM_SETICON: UINT = 0x0080;
pub const ICON_SMALL: WPARAM = 0;
pub const ICON_BIG: WPARAM = 1;
pub extern "user32" fn LoadIconW(inst: ?HINSTANCE, name: usize) callconv(.winapi) ?HICON;
pub extern "user32" fn SetForegroundWindow(hwnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn RegisterWindowMessageW(name: LPCWSTR) callconv(.winapi) UINT;
pub extern "gdi32" fn CreateDIBSection(dc: ?HDC, info: *const BITMAPINFOHEADER, usage: UINT, bits: *?*anyopaque, section: ?HANDLE, offset: DWORD) callconv(.winapi) ?*anyopaque;
pub extern "gdi32" fn CreateBitmap(w: c_int, h: c_int, planes: UINT, bits: UINT, data: ?*const anyopaque) callconv(.winapi) ?*anyopaque;
pub extern "gdi32" fn DeleteObject(obj: *anyopaque) callconv(.winapi) BOOL;
