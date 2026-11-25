//! Tests of the Win32 declarations. Each test makes a window class and a
//! window with no `WS_VISIBLE`, so no window shows on the desktop. The
//! tests send messages to the window procedure with `SendMessageW`, which
//! calls it on this thread, and post a message to check the queue.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const w = @import("../platform/win32.zig");
const t = std.testing;

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ztk-test-win32");

var seen_size: ?[2]i16 = null;
var seen_user: u32 = 0;

fn proc(hwnd: w.HWND, msg: w.UINT, wp: w.WPARAM, lp: w.LPARAM) callconv(.winapi) w.LRESULT {
    switch (msg) {
        w.WM_SIZE => seen_size = .{ w.loword(lp), w.hiword(lp) },
        w.WM_USER => seen_user += @intCast(wp),
        else => {},
    }
    return w.DefWindowProcW(hwnd, msg, wp, lp);
}

fn hidden() !w.HWND {
    const inst = w.GetModuleHandleW(null);
    const cls: w.WNDCLASSEXW = .{ .lpfnWndProc = proc, .hInstance = inst, .lpszClassName = class_name };
    // A class from an earlier test stays registered until the process ends.
    _ = w.RegisterClassExW(&cls);
    const title = std.unicode.utf8ToUtf16LeStringLiteral("ztk test");
    return w.CreateWindowExW(0, class_name, title, w.WS_OVERLAPPEDWINDOW, w.CW_USEDEFAULT, w.CW_USEDEFAULT, 320, 200, null, null, inst, null) orelse error.NoWindow;
}

test "win32: a hidden window gets a sent WM_SIZE and has a scale" {
    const hwnd = try hidden();
    defer _ = w.DestroyWindow(hwnd);
    seen_size = null;
    _ = w.SendMessageW(hwnd, w.WM_SIZE, 0, (@as(w.LPARAM, 90) << 16) | 160);
    try t.expectEqual([2]i16{ 160, 90 }, seen_size.?);
    try t.expect(w.GetDpiForWindow(hwnd) >= w.USER_DEFAULT_SCREEN_DPI);
    var r: w.RECT = .{};
    try t.expect(w.GetClientRect(hwnd, &r) != 0);
    try t.expect(r.right > 0 and r.bottom > 0);
}

test "win32: a posted message goes through the queue to the window procedure" {
    const hwnd = try hidden();
    defer _ = w.DestroyWindow(hwnd);
    seen_user = 0;
    try t.expect(w.PostMessageW(hwnd, w.WM_USER, 7, 0) != 0);
    // The queue has the message, so the wait ends at once.
    const r = w.MsgWaitForMultipleObjectsEx(0, null, 1000, w.QS_ALLINPUT, w.MWMO_INPUTAVAILABLE);
    try t.expectEqual(w.WAIT_OBJECT_0, r);
    var msg: w.MSG = .{};
    while (w.PeekMessageW(&msg, null, 0, 0, w.PM_REMOVE) != 0) {
        _ = w.TranslateMessage(&msg);
        _ = w.DispatchMessageW(&msg);
    }
    try t.expectEqual(@as(u32, 7), seen_user);
}

test "win32: the cursor shapes load" {
    for ([_]usize{ w.IDC_ARROW, w.IDC_IBEAM, w.IDC_HAND, w.IDC_SIZEWE, w.IDC_NO }) |id| {
        try t.expect(w.LoadCursorW(null, id) != null);
    }
}
