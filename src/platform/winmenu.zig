//! The native menus of the Win32 backend. Each `MenuId` of the core has
//! one popup `HMENU`. `set` removes its items and inserts the entries
//! again with `InsertMenuItemW`, so the handle stays the same in each
//! cascade and bar that has it. Each menu has the style
//! `MNS_NOTIFYBYPOS`, so a choice arrives as `WM_MENUCOMMAND` with the
//! position of the item and the handle of its menu, and the position is
//! the index of the entry. A menu bar is its own `CreateMenu` handle,
//! built from the entries of its menu: a cascade is a popup of the bar,
//! and the menu with the role `help` goes at the right end.
//!
//! The label of an item is the label of the entry with each `&` doubled,
//! a `&` before the underlined character, and the accelerator after a
//! tab, as Windows shows it at the right. The `wID` of an item is its
//! index plus 1, so `WM_MENUSELECT` gives the index of an item that is
//! not a cascade too.
//!
//! The system draws the menus, with the light look also in the dark
//! scheme: Win32 has no documented dark mode for menus.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const w32 = @import("win32.zig");
const plat = @import("platform.zig");

const MenuId = plat.MenuId;

const Rec = struct {
    hmenu: w32.HMENU,
    role: plat.Menu.Role = .none,
    /// The copied entries of the last `set`, for the bars that use the menu.
    title: []u8 = &.{},
    entries: std.ArrayListUnmanaged(Saved) = .empty,
};

/// An entry as the bar needs it after the call that gave it.
const Saved = struct {
    kind: plat.MenuEntry.Kind,
    label: []u8,
    underline: i32,
    enabled: bool,
    submenu: MenuId,
};

pub const Menus = struct {
    gpa: std.mem.Allocator,
    menus: std.AutoHashMapUnmanaged(MenuId, Rec) = .empty,
    /// The menu of each handle, for the messages that give a handle. A bar
    /// handle maps to the id of its menu.
    of_handle: std.AutoHashMapUnmanaged(usize, MenuId) = .empty,

    pub fn deinit(m: *Menus) void {
        var it = m.menus.valueIterator();
        while (it.next()) |r| {
            m.freeSaved(r);
            _ = w32.DestroyMenu(r.hmenu);
        }
        m.menus.deinit(m.gpa);
        m.of_handle.deinit(m.gpa);
    }

    fn freeSaved(m: *Menus, r: *Rec) void {
        for (r.entries.items) |e| m.gpa.free(e.label);
        r.entries.deinit(m.gpa);
        m.gpa.free(r.title);
        r.entries = .empty;
        r.title = &.{};
    }

    /// The record of a menu, made with an empty popup when the menu is new,
    /// so a cascade can name a menu before its own `set`.
    fn record(m: *Menus, id: MenuId) !*Rec {
        const gop = try m.menus.getOrPut(m.gpa, id);
        if (!gop.found_existing) {
            const h = w32.CreatePopupMenu() orelse {
                _ = m.menus.remove(id);
                return error.NoMenu;
            };
            const info: w32.MENUINFO = .{ .fMask = w32.MIM_STYLE, .dwStyle = w32.MNS_NOTIFYBYPOS };
            _ = w32.SetMenuInfo(h, &info);
            gop.value_ptr.* = .{ .hmenu = h };
            try m.of_handle.put(m.gpa, @intFromPtr(h), id);
        }
        return gop.value_ptr;
    }

    pub fn handleOf(m: *Menus, id: MenuId) ?w32.HMENU {
        const r = m.menus.getPtr(id) orelse return null;
        return r.hmenu;
    }

    pub fn idOf(m: *Menus, h: usize) ?MenuId {
        return m.of_handle.get(h);
    }

    /// The text of an item in UTF-16: `&` doubled, `&` before the
    /// underlined character, and a tab and the accelerator.
    fn itemText(gpa: std.mem.Allocator, label: []const u8, underline: i32, accel: []const u8) ![:0]u16 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(gpa);
        var view = std.unicode.Utf8View.init(label) catch return std.unicode.utf8ToUtf16LeAllocZ(gpa, "");
        var it = view.iterator();
        var i: i32 = 0;
        while (it.nextCodepointSlice()) |s| : (i += 1) {
            if (i == underline) try out.append(gpa, '&');
            if (std.mem.eql(u8, s, "&")) try out.append(gpa, '&');
            try out.appendSlice(gpa, s);
        }
        if (accel.len > 0) {
            try out.append(gpa, '\t');
            try out.appendSlice(gpa, accel);
        }
        return std.unicode.utf8ToUtf16LeAllocZ(gpa, out.items) catch std.unicode.utf8ToUtf16LeAllocZ(gpa, "");
    }

    fn itemInfo(m: *Menus, e: *const plat.MenuEntry, index: u32, text: ?[:0]u16) !w32.MENUITEMINFOW {
        var info: w32.MENUITEMINFOW = .{
            .fMask = w32.MIIM_FTYPE | w32.MIIM_STATE | w32.MIIM_ID | w32.MIIM_SUBMENU,
            .wID = index + 1,
        };
        if (e.kind == .separator) {
            info.fType = w32.MFT_SEPARATOR;
        } else {
            info.fMask |= w32.MIIM_STRING;
            info.dwTypeData = text.?.ptr;
            if (e.kind == .radiobutton) info.fType |= w32.MFT_RADIOCHECK;
        }
        if (e.column_break) info.fType |= w32.MFT_MENUBARBREAK;
        if (!e.enabled) info.fState |= w32.MFS_GRAYED;
        if (e.selected and (e.kind == .checkbutton or e.kind == .radiobutton)) info.fState |= w32.MFS_CHECKED;
        if (e.kind == .cascade and e.submenu != 0) info.hSubMenu = (try m.record(e.submenu)).hmenu;
        return info;
    }

    fn removeItems(h: w32.HMENU) void {
        // RemoveMenu keeps the popup of a cascade, which belongs to its own record.
        while (w32.GetMenuItemCount(h) > 0) _ = w32.RemoveMenu(h, 0, w32.MF_BYPOSITION);
    }

    /// Defines a menu or replaces each of its entries.
    pub fn set(m: *Menus, menu: *const plat.Menu) !void {
        const r = try m.record(menu.id);
        removeItems(r.hmenu);
        m.freeSaved(r);
        r.role = menu.role;
        r.title = try m.gpa.dupe(u8, menu.title);
        for (menu.entries, 0..) |*e, i| {
            const text: ?[:0]u16 = if (e.kind == .separator) null else try itemText(m.gpa, e.label, e.underline, e.accelerator);
            defer if (text) |s| m.gpa.free(s);
            const info = try m.itemInfo(e, @intCast(i), text);
            _ = w32.InsertMenuItemW(r.hmenu, @intCast(i), 1, &info);
            try r.entries.append(m.gpa, .{ .kind = e.kind, .label = try m.gpa.dupe(u8, e.label), .underline = e.underline, .enabled = e.enabled, .submenu = e.submenu });
        }
    }

    /// Changes one entry in place.
    pub fn setEntry(m: *Menus, id: MenuId, index: u32, e: *const plat.MenuEntry) !void {
        const r = m.menus.getPtr(id) orelse return;
        if (index >= r.entries.items.len) return;
        const text: ?[:0]u16 = if (e.kind == .separator) null else try itemText(m.gpa, e.label, e.underline, e.accelerator);
        defer if (text) |s| m.gpa.free(s);
        const info = try m.itemInfo(e, index, text);
        _ = w32.SetMenuItemInfoW(r.hmenu, index, 1, &info);
        const s = &r.entries.items[index];
        m.gpa.free(s.label);
        s.* = .{ .kind = e.kind, .label = try m.gpa.dupe(u8, e.label), .underline = e.underline, .enabled = e.enabled, .submenu = e.submenu };
    }

    /// Removes a menu. The caller removed it from each bar and cascade.
    pub fn drop(m: *Menus, id: MenuId) void {
        var r = m.menus.get(id) orelse return;
        _ = m.menus.remove(id);
        _ = m.of_handle.remove(@intFromPtr(r.hmenu));
        removeItems(r.hmenu);
        m.freeSaved(&r);
        _ = w32.DestroyMenu(r.hmenu);
    }

    /// Makes the handle of a menu bar from the entries of a menu. The
    /// caller destroys it with `dropBar`.
    pub fn makeBar(m: *Menus, id: MenuId) !w32.HMENU {
        const r = m.menus.getPtr(id) orelse return error.NoMenu;
        const bar = w32.CreateMenu() orelse return error.NoMenu;
        errdefer _ = w32.DestroyMenu(bar);
        const info: w32.MENUINFO = .{ .fMask = w32.MIM_STYLE, .dwStyle = w32.MNS_NOTIFYBYPOS };
        _ = w32.SetMenuInfo(bar, &info);
        for (r.entries.items, 0..) |s, i| {
            const e: plat.MenuEntry = .{ .kind = s.kind, .label = s.label, .underline = s.underline, .enabled = s.enabled, .submenu = s.submenu };
            const text: ?[:0]u16 = if (s.kind == .separator) null else try itemText(m.gpa, s.label, s.underline, "");
            defer if (text) |t| m.gpa.free(t);
            var item = try m.itemInfo(&e, @intCast(i), text);
            // The Help menu goes at the right end of the bar.
            if (s.kind == .cascade and s.submenu != 0) if (m.menus.getPtr(s.submenu)) |sub| {
                if (sub.role == .help) item.fType |= w32.MFT_RIGHTJUSTIFY;
            };
            _ = w32.InsertMenuItemW(bar, @intCast(i), 1, &item);
        }
        try m.of_handle.put(m.gpa, @intFromPtr(bar), id);
        return bar;
    }

    /// Destroys the handle of a bar and keeps the popups of its cascades.
    pub fn dropBar(m: *Menus, bar: w32.HMENU) void {
        _ = m.of_handle.remove(@intFromPtr(bar));
        removeItems(bar);
        _ = w32.DestroyMenu(bar);
    }
};

test "winmenu: the text of an item doubles & and marks the underline" {
    const gpa = std.testing.allocator;
    const a = try Menus.itemText(gpa, "Save & Quit", 0, "Ctrl+Q");
    defer gpa.free(a);
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("&Save && Quit\tCtrl+Q"), a);
    const b = try Menus.itemText(gpa, "\u{C9}t\u{E9}", 2, "");
    defer gpa.free(b);
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("\u{C9}t&\u{E9}"), b);
}

test "win32: the menu structures have the sizes of the C headers" {
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(w32.MENUITEMINFOW));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(w32.MENUINFO));
}
