//! The tray icons of the Win32 backend, in the notification area of the
//! taskbar, with `Shell_NotifyIconW` and the behavior of version 4. Each
//! tray has the window of `trayCreate` as its owner, and the shell sends
//! the actions to that window as `callback_msg`, with the action in the
//! low word of `lParam` and the id of the tray in the high word. The
//! backend turns them into `tray` events: `NIN_SELECT` and
//! `NIN_KEYSELECT` are a click, `WM_LBUTTONDBLCLK` a double click, and
//! `WM_CONTEXTMENU` the menu.
//!
//! The icon of a tray is an `HICON` made from the RGBA pixels with a
//! 32-bit DIB section and `CreateIconIndirect`. A tray with no pixels has
//! the icon of an application of the system. The shell forgets each icon
//! when Explorer starts again, and sends the message "TaskbarCreated" to
//! each top window. `addAll` adds the icons again then.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const w32 = @import("win32.zig");
const plat = @import("platform.zig");

pub const callback_msg: w32.UINT = w32.WM_APP + 1;

const Rec = struct {
    id: plat.TrayId,
    hwnd: w32.HWND,
    icon: ?w32.HICON = null,
    /// True for an icon of the tray that `DestroyIcon` frees.
    own_icon: bool = false,
    tip: [128]u16 = @splat(0),
    menu: plat.MenuId = 0,
};

pub const Trays = struct {
    gpa: std.mem.Allocator,
    list: std.ArrayListUnmanaged(Rec) = .empty,
    next: u32 = 1,
    /// The message that the shell sends when the taskbar starts again.
    taskbar_created: w32.UINT = 0,

    pub fn init(gpa: std.mem.Allocator) Trays {
        return .{ .gpa = gpa, .taskbar_created = w32.RegisterWindowMessageW(std.unicode.utf8ToUtf16LeStringLiteral("TaskbarCreated")) };
    }

    pub fn deinit(t: *Trays) void {
        while (t.list.items.len > 0) t.drop(t.list.items[0].id);
        t.list.deinit(t.gpa);
    }

    pub fn find(t: *Trays, id: plat.TrayId) ?*Rec {
        for (t.list.items) |*r| if (r.id == id) return r;
        return null;
    }

    fn data(r: *const Rec) w32.NOTIFYICONDATAW {
        return .{
            .hWnd = r.hwnd,
            .uID = r.id,
            .uFlags = w32.NIF_MESSAGE | w32.NIF_ICON | w32.NIF_TIP | w32.NIF_SHOWTIP,
            .uCallbackMessage = callback_msg,
            .hIcon = r.icon,
            .szTip = r.tip,
            .uVersion = w32.NOTIFYICON_VERSION_4,
        };
    }

    fn setIcon(r: *Rec, icon: plat.TrayIcon) void {
        if (r.own_icon) if (r.icon) |old| {
            _ = w32.DestroyIcon(old);
        };
        r.icon = makeIcon(icon);
        r.own_icon = r.icon != null;
        if (r.icon == null) r.icon = w32.LoadIconW(null, w32.IDI_APPLICATION);
    }

    fn setTip(r: *Rec, tooltip: []const u8) void {
        r.tip = @splat(0);
        // The tip has 127 units and a zero. A longer tip is cut at a code point.
        var n: usize = 0;
        var view = std.unicode.Utf8View.init(tooltip) catch return;
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            var units: [2]u16 = undefined;
            const k: usize = if (cp >= 0x10000) 2 else 1;
            if (n + k > 127) break;
            if (k == 2) {
                const v = cp - 0x10000;
                units = .{ @intCast(0xD800 + (v >> 10)), @intCast(0xDC00 + (v & 0x3ff)) };
            } else units[0] = @intCast(cp);
            @memcpy(r.tip[n..][0..k], units[0..k]);
            n += k;
        }
    }

    fn add(r: *const Rec) bool {
        var d = data(r);
        if (w32.Shell_NotifyIconW(w32.NIM_ADD, &d) == 0) return false;
        _ = w32.Shell_NotifyIconW(w32.NIM_SETVERSION, &d);
        return true;
    }

    /// Adds an icon to the notification area. Gives 0 when the shell has no notification area.
    pub fn create(t: *Trays, hwnd: w32.HWND, icon: plat.TrayIcon, tooltip: []const u8) plat.TrayId {
        var r: Rec = .{ .id = t.next, .hwnd = hwnd };
        setIcon(&r, icon);
        setTip(&r, tooltip);
        if (!add(&r)) {
            if (r.own_icon) _ = w32.DestroyIcon(r.icon.?);
            return 0;
        }
        t.list.append(t.gpa, r) catch {
            var d = data(&r);
            _ = w32.Shell_NotifyIconW(w32.NIM_DELETE, &d);
            if (r.own_icon) _ = w32.DestroyIcon(r.icon.?);
            return 0;
        };
        t.next += 1;
        return r.id;
    }

    pub fn set(t: *Trays, id: plat.TrayId, icon: plat.TrayIcon, tooltip: []const u8, menu: plat.MenuId) void {
        const r = t.find(id) orelse return;
        setIcon(r, icon);
        setTip(r, tooltip);
        r.menu = menu;
        var d = data(r);
        _ = w32.Shell_NotifyIconW(w32.NIM_MODIFY, &d);
    }

    pub fn drop(t: *Trays, id: plat.TrayId) void {
        for (t.list.items, 0..) |*r, i| if (r.id == id) {
            var d = data(r);
            _ = w32.Shell_NotifyIconW(w32.NIM_DELETE, &d);
            if (r.own_icon) if (r.icon) |h| {
                _ = w32.DestroyIcon(h);
            };
            _ = t.list.orderedRemove(i);
            return;
        };
    }

    /// Adds each icon again, after the taskbar started again.
    pub fn addAll(t: *Trays) void {
        for (t.list.items) |*r| _ = add(r);
    }
};

/// An icon from RGBA pixels, or null for no pixels.
pub fn makeIcon(icon: plat.TrayIcon) ?w32.HICON {
    if (icon.width == 0 or icon.height == 0 or icon.pixels.len < @as(usize, icon.width) * icon.height * 4) return null;
    const w: i32 = @intCast(icon.width);
    const h: i32 = @intCast(icon.height);
    const info: w32.BITMAPINFOHEADER = .{ .biWidth = w, .biHeight = -h };
    var bits: ?*anyopaque = null;
    const color = w32.CreateDIBSection(null, &info, 0, &bits, null, 0) orelse return null;
    defer _ = w32.DeleteObject(color);
    const dst: [*]u8 = @ptrCast(bits.?);
    var i: usize = 0;
    // The DIB has BGRA, and an icon with alpha needs no mask.
    while (i < @as(usize, icon.width) * icon.height * 4) : (i += 4) {
        dst[i] = icon.pixels[i + 2];
        dst[i + 1] = icon.pixels[i + 1];
        dst[i + 2] = icon.pixels[i];
        dst[i + 3] = icon.pixels[i + 3];
    }
    // The mask has rows of 16-bit words, all zero.
    var zeros: [64 * 256]u8 = @splat(0);
    const row: usize = (icon.width + 15) / 16 * 2;
    if (row * icon.height > zeros.len) return null;
    const mask = w32.CreateBitmap(w, h, 1, 1, &zeros) orelse return null;
    defer _ = w32.DeleteObject(mask);
    const ii: w32.ICONINFO = .{ .hbmMask = mask, .hbmColor = color };
    return w32.CreateIconIndirect(&ii);
}

test "wintray: an icon from RGBA pixels, and the size of the tray data" {
    try std.testing.expectEqual(@as(usize, 976), @sizeOf(w32.NOTIFYICONDATAW));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(w32.ICONINFO));
    var px: [16 * 16 * 4]u8 = @splat(0x80);
    const h = makeIcon(.{ .width = 16, .height = 16, .pixels = &px }) orelse return error.NoIcon;
    _ = w32.DestroyIcon(h);
    try std.testing.expect(makeIcon(.{ .width = 0, .height = 0, .pixels = &.{} }) == null);
}

test "wintray: a long tooltip is cut at 127 units" {
    var r: Rec = .{ .id = 1, .hwnd = undefined };
    const long = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";
    Trays.setTip(&r, long);
    try std.testing.expectEqual(@as(u16, 'x'), r.tip[126]);
    try std.testing.expectEqual(@as(u16, 0), r.tip[127]);
}
