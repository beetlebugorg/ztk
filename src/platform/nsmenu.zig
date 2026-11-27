//! The native menus of macOS: the menus of `docs/dev/menus.md` as
//! `NSMenu` objects. `Menus` keeps one `NSMenu` for each `MenuId` of the
//! core and fills it again at each `set`. The tag of an item has the menu
//! id in its high 32 bits and the index of the entry in its low 32 bits,
//! so a copy of an item in the application menu still names its entry.
//!
//! The system menu bar shows one menu at a time: the bar of the key
//! window, or the default bar with the application menu alone. The item
//! of the application menu moves to index 0 of the bar that shows. The
//! cascade of the role `app` stays hidden in the bar, and copies of its
//! items go at the top of the application menu, in place of About. The
//! roles `help` and `window` become the Help menu and the Window menu of
//! `NSApp`. A later `set` of a cascade can come with no role, so the role
//! of a menu stays until `drop`.
//!
//! An accelerator such as "Command-O" becomes the key equivalent of its
//! item, so the menu shows it as macOS does. In Tk a binding of the script
//! handles the key, so when a key equivalent chooses an item, the key goes
//! to the core as a key event and the entry is not invoked.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const objc = @import("../sys/objc.zig");
const plat = @import("platform.zig");
const event = @import("../base/event.zig");
const Id = objc.Id;
const Sel = objc.Sel;
const Class = objc.Class;
const MenuId = plat.MenuId;

const NSPoint = extern struct { x: f64, y: f64 };

/// NSEventTypeKeyDown.
const event_key_down: usize = 10;

/// What the menus give to the backend.
pub const Sink = struct {
    ctx: *anyopaque,
    /// A queued `menu` event: `invoke`, `closed`, and `opening` or
    /// `select` when the core gave no handler.
    menu: *const fn (ctx: *anyopaque, id: MenuId, entry: i32, action: event.MenuAction) void,
    /// About, Settings, or Quit of the application menu.
    command: *const fn (ctx: *anyopaque, command: event.AppCommand) void,
    /// A key equivalent of an item matched the key event `ev`. The backend
    /// gives the key to the core.
    key: *const fn (ctx: *anyopaque, ev: Id) void,
};

const Info = struct {
    ns: Id,
    role: plat.Menu.Role = .none,
};

pub const Menus = struct {
    gpa: std.mem.Allocator,
    sink: Sink,
    handler: ?plat.MenuHandler = null,
    /// The target of the items and the delegate of the menus of the core.
    target: Id,
    menus: std.AutoHashMapUnmanaged(MenuId, Info) = .empty,
    /// The id of each `NSMenu` of the core, by its address.
    ids: std.AutoHashMapUnmanaged(usize, MenuId) = .empty,
    app_menu: Id,
    /// The item of the bar with the application menu as its submenu.
    app_item: Id,
    /// About and the separator after it, hidden when the `app` menu has items.
    about: [2]Id,
    /// The bar that shows when the key window has no bar.
    default_bar: Id,
    /// The menu id of the bar that shows, or 0 for the default bar.
    bar: MenuId = 0,
    /// The count of the copied items at the top of the application menu.
    app_prefix: usize = 0,
    /// The menu of `post` until it closes.
    posted: ?Id = null,

    pub fn init(gpa: std.mem.Allocator, sink: Sink) !*Menus {
        const m = try gpa.create(Menus);
        errdefer gpa.destroy(m);
        const target = objc.new(targetClass());
        objc.setData(target, m);
        const app_menu = newMenu("");
        const app_item = newItem("", null, "");
        call(fn (Id, Sel, Id) callconv(.c) void, app_item, "setSubmenu:", .{app_menu});
        const default_bar = newMenu("");
        call(fn (Id, Sel, Id) callconv(.c) void, default_bar, "addItem:", .{app_item});
        m.* = .{
            .gpa = gpa,
            .sink = sink,
            .target = target,
            .app_menu = app_menu,
            .app_item = app_item,
            .about = undefined,
            .default_bar = default_bar,
        };
        m.fillAppMenu();
        return m;
    }

    pub fn deinit(m: *Menus) void {
        var it = m.menus.valueIterator();
        while (it.next()) |info| {
            clear(m, info.ns);
            call(fn (Id, Sel, ?Id) callconv(.c) void, info.ns, "setDelegate:", .{null});
            objc.release(info.ns);
        }
        m.menus.deinit(m.gpa);
        m.ids.deinit(m.gpa);
        objc.release(m.default_bar);
        objc.release(m.app_item);
        objc.release(m.app_menu);
        objc.setData(m.target, null);
        objc.release(m.target);
        m.gpa.destroy(m);
    }

    /// Defines a menu or replaces each of its entries.
    pub fn set(m: *Menus, menu: *const plat.Menu) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const info = m.infoOf(menu.id) orelse return;
        if (menu.role != .none) info.role = menu.role;
        if (menu.title.len > 0) {
            const text = objc.nsString(menu.title);
            defer objc.release(text);
            call(fn (Id, Sel, Id) callconv(.c) void, info.ns, "setTitle:", .{text});
        }
        m.clear(info.ns);
        for (menu.entries, 0..) |*e, i| {
            const item = m.makeItem(menu.id, @intCast(i), e);
            call(fn (Id, Sel, Id) callconv(.c) void, info.ns, "addItem:", .{item});
            objc.release(item);
        }
        if (menu.id == m.bar) m.decorate() else if (info.role == .app and m.inBar(info.ns)) m.copyAppItems();
    }

    /// Changes one entry and keeps the count of entries.
    pub fn entrySet(m: *Menus, id: MenuId, index: u32, e: *const plat.MenuEntry) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const info = m.menus.getPtr(id) orelse return;
        if (index >= count(info.ns)) return;
        const old = itemAt(info.ns, index);
        if (old == m.app_item) return;
        detachItem(old);
        call(fn (Id, Sel, isize) callconv(.c) void, info.ns, "removeItemAtIndex:", .{@as(isize, @intCast(index))});
        const item = m.makeItem(id, index, e);
        call(fn (Id, Sel, Id, isize) callconv(.c) void, info.ns, "insertItem:atIndex:", .{ item, @as(isize, @intCast(index)) });
        objc.release(item);
        if (id == m.bar) m.decorate() else if (info.role == .app and m.inBar(info.ns)) m.copyAppItems();
    }

    /// Removes a menu. The core removed it from each bar and cascade first.
    pub fn drop(m: *Menus, id: MenuId) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        if (id == m.bar) m.show(0);
        const kv = m.menus.fetchRemove(id) orelse return;
        _ = m.ids.remove(@intFromPtr(kv.value.ns));
        detachMenu(kv.value.ns);
        m.clear(kv.value.ns);
        call(fn (Id, Sel, ?Id) callconv(.c) void, kv.value.ns, "setDelegate:", .{null});
        objc.release(kv.value.ns);
    }

    /// Shows the bar `id` in the system menu bar, or the default bar for 0
    /// or an id with no menu.
    pub fn show(m: *Menus, id: MenuId) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        m.bar = if (m.menus.contains(id)) id else 0;
        m.decorate();
        call(fn (Id, Sel, Id) callconv(.c) void, nsApp(), "setMainMenu:", .{m.barMenu()});
    }

    /// Shows a menu as a popup at `at` in the view, with the entry `entry`
    /// at the point when it is 0 or more. Returns after the menu closes.
    pub fn post(m: *Menus, view: Id, id: MenuId, at: NSPoint, entry: i32) void {
        const info = m.menus.get(id) orelse return;
        const item: ?Id = if (entry >= 0 and entry < count(info.ns)) itemAt(info.ns, @intCast(entry)) else null;
        m.posted = info.ns;
        defer m.posted = null;
        _ = call(fn (Id, Sel, ?Id, NSPoint, Id) callconv(.c) bool, info.ns, "popUpMenuPositioningItem:atLocation:inView:", .{ item, at, view });
    }

    pub fn unpost(m: *Menus, id: MenuId) void {
        const info = m.menus.get(id) orelse return;
        if (m.posted == info.ns) call(fn (Id, Sel) callconv(.c) void, info.ns, "cancelTracking", .{});
    }

    // ---- The menus and the items ----

    fn infoOf(m: *Menus, id: MenuId) ?*Info {
        if (m.menus.getPtr(id)) |i| return i;
        const ns = newMenu("");
        call(fn (Id, Sel, Id) callconv(.c) void, ns, "setDelegate:", .{m.target});
        m.ids.put(m.gpa, @intFromPtr(ns), id) catch {
            objc.release(ns);
            return null;
        };
        m.menus.put(m.gpa, id, .{ .ns = ns }) catch {
            _ = m.ids.remove(@intFromPtr(ns));
            objc.release(ns);
            return null;
        };
        return m.menus.getPtr(id).?;
    }

    fn makeItem(m: *Menus, id: MenuId, index: u32, e: *const plat.MenuEntry) Id {
        if (e.kind == .separator) {
            const sep = call(fn (Class, Sel) callconv(.c) Id, objc.class("NSMenuItem").?, "separatorItem", .{});
            return call(fn (Id, Sel) callconv(.c) Id, sep, "retain", .{});
        }
        const key = keyOf(e.accelerator);
        const item = newItem(e.label, objc.sel("ztkMenuItem:"), if (key) |k| k.slice() else "");
        call(fn (Id, Sel, ?Id) callconv(.c) void, item, "setTarget:", .{m.target});
        call(fn (Id, Sel, isize) callconv(.c) void, item, "setTag:", .{tagOf(id, index)});
        if (key) |k| call(fn (Id, Sel, usize) callconv(.c) void, item, "setKeyEquivalentModifierMask:", .{k.mask});
        call(fn (Id, Sel, bool) callconv(.c) void, item, "setEnabled:", .{e.enabled});
        if (e.kind == .checkbutton or e.kind == .radiobutton)
            call(fn (Id, Sel, isize) callconv(.c) void, item, "setState:", .{@as(isize, @intFromBool(e.selected))});
        if (e.kind == .cascade) if (m.menus.get(e.submenu)) |sub| {
            detachMenu(sub.ns);
            call(fn (Id, Sel, ?Id) callconv(.c) void, item, "setSubmenu:", .{sub.ns});
        };
        return item;
    }

    /// Removes each item of a menu. A submenu leaves its item first, so it
    /// can go in another item later. The item of the application menu
    /// keeps its submenu.
    fn clear(m: *Menus, ns: Id) void {
        var i: usize = 0;
        const n = count(ns);
        while (i < n) : (i += 1) {
            const item = itemAt(ns, i);
            if (item != m.app_item) detachItem(item);
        }
        call(fn (Id, Sel) callconv(.c) void, ns, "removeAllItems", .{});
    }

    fn barMenu(m: *Menus) Id {
        if (m.bar != 0) if (m.menus.get(m.bar)) |b| return b.ns;
        return m.default_bar;
    }

    fn inBar(m: *Menus, ns: Id) bool {
        const sup = call(fn (Id, Sel) callconv(.c) ?Id, ns, "supermenu", .{}) orelse return false;
        return sup == m.barMenu();
    }

    /// Puts the application menu at the front of the bar that shows, hides
    /// the cascade of the role `app`, and gives the Help and Window menus
    /// to `NSApp`.
    fn decorate(m: *Menus) void {
        const bar = m.barMenu();
        const holder = call(fn (Id, Sel) callconv(.c) ?Id, m.app_item, "menu", .{});
        if (holder != bar or itemAt(bar, 0) != m.app_item) {
            if (holder) |h| call(fn (Id, Sel, Id) callconv(.c) void, h, "removeItem:", .{m.app_item});
            call(fn (Id, Sel, Id, isize) callconv(.c) void, bar, "insertItem:atIndex:", .{ m.app_item, 0 });
        }
        var help: ?Id = null;
        var window: ?Id = null;
        var i: usize = 1;
        while (i < count(bar)) : (i += 1) {
            const item = itemAt(bar, i);
            const sub = call(fn (Id, Sel) callconv(.c) ?Id, item, "submenu", .{}) orelse continue;
            const sid = m.ids.get(@intFromPtr(sub)) orelse continue;
            switch (m.menus.get(sid).?.role) {
                .app => call(fn (Id, Sel, bool) callconv(.c) void, item, "setHidden:", .{true}),
                .help => help = sub,
                .window => window = sub,
                .none => {},
            }
        }
        const app = nsApp();
        call(fn (Id, Sel, ?Id) callconv(.c) void, app, "setHelpMenu:", .{help});
        call(fn (Id, Sel, ?Id) callconv(.c) void, app, "setWindowsMenu:", .{window});
        m.copyAppItems();
    }

    /// The menu of the role `app` in the bar that shows, or null.
    fn appCascade(m: *Menus) ?Id {
        const bar = m.barMenu();
        var i: usize = 1;
        while (i < count(bar)) : (i += 1) {
            const sub = call(fn (Id, Sel) callconv(.c) ?Id, itemAt(bar, i), "submenu", .{}) orelse continue;
            const sid = m.ids.get(@intFromPtr(sub)) orelse continue;
            if (m.menus.get(sid).?.role == .app) return sub;
        }
        return null;
    }

    /// Copies the items of the `app` cascade to the top of the application
    /// menu, with a separator after them, in place of About.
    fn copyAppItems(m: *Menus) void {
        while (m.app_prefix > 0) : (m.app_prefix -= 1)
            call(fn (Id, Sel, isize) callconv(.c) void, m.app_menu, "removeItemAtIndex:", .{0});
        var n: usize = 0;
        if (m.appCascade()) |src| {
            var i: usize = 0;
            while (i < count(src)) : (i += 1) {
                const copy = call(fn (Id, Sel) callconv(.c) Id, itemAt(src, i), "copy", .{});
                call(fn (Id, Sel, Id, isize) callconv(.c) void, m.app_menu, "insertItem:atIndex:", .{ copy, @as(isize, @intCast(n)) });
                objc.release(copy);
                n += 1;
            }
            if (n > 0) {
                const sep = call(fn (Class, Sel) callconv(.c) Id, objc.class("NSMenuItem").?, "separatorItem", .{});
                call(fn (Id, Sel, Id, isize) callconv(.c) void, m.app_menu, "insertItem:atIndex:", .{ sep, @as(isize, @intCast(n)) });
                n += 1;
            }
        }
        m.app_prefix = n;
        for (m.about) |x| call(fn (Id, Sel, bool) callconv(.c) void, x, "setHidden:", .{n > 0});
    }

    /// The application menu of macOS: About, Settings, Services, Hide,
    /// Hide Others, Show All, and Quit, with the name of the program.
    fn fillAppMenu(m: *Menus) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const info = call(fn (Class, Sel) callconv(.c) Id, objc.class("NSProcessInfo").?, "processInfo", .{});
        const name = objc.utf8(call(fn (Id, Sel) callconv(.c) Id, info, "processName", .{}));
        var buf: [256]u8 = undefined;
        const cmd: usize = mask_command;
        m.about[0] = m.addCommand(std.fmt.bufPrint(&buf, "About {s}", .{name}) catch "About", .about, "", 0);
        m.about[1] = m.addSeparator();
        _ = m.addCommand("Settings…", .settings, ",", cmd);
        _ = m.addSeparator();
        const services = newMenu("Services");
        defer objc.release(services);
        const s_item = m.addSystem("Services", null, "", 0);
        call(fn (Id, Sel, Id) callconv(.c) void, s_item, "setSubmenu:", .{services});
        call(fn (Id, Sel, Id) callconv(.c) void, nsApp(), "setServicesMenu:", .{services});
        _ = m.addSeparator();
        _ = m.addSystem(std.fmt.bufPrint(&buf, "Hide {s}", .{name}) catch "Hide", objc.sel("hide:"), "h", cmd);
        _ = m.addSystem("Hide Others", objc.sel("hideOtherApplications:"), "h", cmd | mask_option);
        _ = m.addSystem("Show All", objc.sel("unhideAllApplications:"), "", 0);
        _ = m.addSeparator();
        _ = m.addCommand(std.fmt.bufPrint(&buf, "Quit {s}", .{name}) catch "Quit", .quit, "q", cmd);
    }

    fn addCommand(m: *Menus, title: []const u8, command: event.AppCommand, key: []const u8, mask: usize) Id {
        const item = m.addSystem(title, objc.sel("ztkAppCommand:"), key, mask);
        call(fn (Id, Sel, ?Id) callconv(.c) void, item, "setTarget:", .{m.target});
        call(fn (Id, Sel, isize) callconv(.c) void, item, "setTag:", .{@as(isize, @intFromEnum(command))});
        return item;
    }

    /// An item with an action of `NSApp`, such as `hide:`.
    fn addSystem(m: *Menus, title: []const u8, action: ?Sel, key: []const u8, mask: usize) Id {
        const item = newItem(title, action, key);
        if (key.len > 0) call(fn (Id, Sel, usize) callconv(.c) void, item, "setKeyEquivalentModifierMask:", .{mask});
        call(fn (Id, Sel, Id) callconv(.c) void, m.app_menu, "addItem:", .{item});
        objc.release(item);
        return item;
    }

    fn addSeparator(m: *Menus) Id {
        const sep = call(fn (Class, Sel) callconv(.c) Id, objc.class("NSMenuItem").?, "separatorItem", .{});
        call(fn (Id, Sel, Id) callconv(.c) void, m.app_menu, "addItem:", .{sep});
        return sep;
    }

    // ---- The answers of AppKit ----

    fn of(target: Id) ?*Menus {
        return @ptrCast(@alignCast(objc.getData(target) orelse return null));
    }

    fn fromKey() ?Id {
        const ev = call(fn (Id, Sel) callconv(.c) ?Id, nsApp(), "currentEvent", .{}) orelse return null;
        const typ = call(fn (Id, Sel) callconv(.c) usize, ev, "type", .{});
        return if (typ == event_key_down) ev else null;
    }

    fn onItem(target: Id, _: Sel, item: Id) callconv(.c) void {
        const m = of(target) orelse return;
        if (fromKey()) |ev| return m.sink.key(m.sink.ctx, ev);
        const tag: u64 = @bitCast(call(fn (Id, Sel) callconv(.c) isize, item, "tag", .{}));
        m.sink.menu(m.sink.ctx, @intCast(tag >> 32), @intCast(tag & 0xffff_ffff), .invoke);
    }

    fn onCommand(target: Id, _: Sel, item: Id) callconv(.c) void {
        const m = of(target) orelse return;
        const tag = call(fn (Id, Sel) callconv(.c) isize, item, "tag", .{});
        const command = std.enums.fromInt(event.AppCommand, tag) orelse return;
        m.sink.command(m.sink.ctx, command);
    }

    fn report(m: *Menus, id: MenuId, entry: i32, action: event.MenuAction) void {
        if (m.handler) |h| h.call(h.ctx, id, entry, action) else m.sink.menu(m.sink.ctx, id, entry, action);
    }

    fn onNeedsUpdate(target: Id, _: Sel, menu: Id) callconv(.c) void {
        const m = of(target) orelse return;
        // A key equivalent looks for its item with this call too. The menu
        // does not open then.
        if (fromKey() != null) return;
        const id = m.ids.get(@intFromPtr(menu)) orelse return;
        m.report(id, -1, .opening);
    }

    fn onHighlight(target: Id, _: Sel, menu: Id, item: ?Id) callconv(.c) void {
        const m = of(target) orelse return;
        const id = m.ids.get(@intFromPtr(menu)) orelse return;
        var entry: i32 = -1;
        if (item) |x| {
            const tag: u64 = @bitCast(call(fn (Id, Sel) callconv(.c) isize, x, "tag", .{}));
            if (tag >> 32 == id) entry = @intCast(tag & 0xffff_ffff);
        }
        m.report(id, entry, .select);
    }

    fn onClose(target: Id, _: Sel, menu: Id) callconv(.c) void {
        const m = of(target) orelse return;
        const id = m.ids.get(@intFromPtr(menu)) orelse return;
        m.sink.menu(m.sink.ctx, id, -1, .closed);
    }

    fn targetClass() Class {
        if (objc.class("ZtkMenuTarget")) |c| return c;
        const b = objc.ClassBuilder.begin("NSObject", "ZtkMenuTarget").?;
        _ = b.protocol("NSMenuDelegate");
        b.method("ztkMenuItem:", @ptrCast(&onItem), "v@:@");
        b.method("ztkAppCommand:", @ptrCast(&onCommand), "v@:@");
        b.method("menuNeedsUpdate:", @ptrCast(&onNeedsUpdate), "v@:@");
        b.method("menu:willHighlightItem:", @ptrCast(&onHighlight), "v@:@@");
        b.method("menuDidClose:", @ptrCast(&onClose), "v@:@");
        return b.finish();
    }
};

// ---- Small helpers ----

fn call(comptime Fn: type, target: anytype, selector: [*:0]const u8, args: anytype) @typeInfo(Fn).@"fn".return_type.? {
    return objc.call(Fn, target, selector, args);
}

fn nsApp() Id {
    return call(fn (Class, Sel) callconv(.c) Id, objc.class("NSApplication").?, "sharedApplication", .{});
}

fn newMenu(title: []const u8) Id {
    const text = objc.nsString(title);
    defer objc.release(text);
    const obj = call(fn (Class, Sel) callconv(.c) Id, objc.class("NSMenu").?, "alloc", .{});
    const menu = call(fn (Id, Sel, Id) callconv(.c) Id, obj, "initWithTitle:", .{text});
    // The core says which entries are enabled.
    call(fn (Id, Sel, bool) callconv(.c) void, menu, "setAutoenablesItems:", .{false});
    return menu;
}

fn newItem(title: []const u8, action: ?Sel, key: []const u8) Id {
    const text = objc.nsString(title);
    defer objc.release(text);
    const k = objc.nsString(key);
    defer objc.release(k);
    const obj = call(fn (Class, Sel) callconv(.c) Id, objc.class("NSMenuItem").?, "alloc", .{});
    return call(fn (Id, Sel, Id, ?Sel, Id) callconv(.c) Id, obj, "initWithTitle:action:keyEquivalent:", .{ text, action, k });
}

fn count(menu: Id) usize {
    return @intCast(call(fn (Id, Sel) callconv(.c) isize, menu, "numberOfItems", .{}));
}

fn itemAt(menu: Id, i: usize) Id {
    return call(fn (Id, Sel, isize) callconv(.c) Id, menu, "itemAtIndex:", .{@as(isize, @intCast(i))});
}

fn detachItem(item: Id) void {
    if (call(fn (Id, Sel) callconv(.c) ?Id, item, "submenu", .{}) != null)
        call(fn (Id, Sel, ?Id) callconv(.c) void, item, "setSubmenu:", .{null});
}

/// Takes a menu out of the item that has it as its submenu. An `NSMenu`
/// can be the submenu of one item at a time.
fn detachMenu(menu: Id) void {
    const sup = call(fn (Id, Sel) callconv(.c) ?Id, menu, "supermenu", .{}) orelse return;
    const i = call(fn (Id, Sel, Id) callconv(.c) isize, sup, "indexOfItemWithSubmenu:", .{menu});
    if (i >= 0) detachItem(itemAt(sup, @intCast(i)));
}

fn tagOf(id: MenuId, index: u32) isize {
    return @bitCast((@as(u64, id) << 32) | index);
}

// ---- Accelerators ----

const mask_shift: usize = 1 << 17;
const mask_control: usize = 1 << 18;
const mask_option: usize = 1 << 19;
const mask_command: usize = 1 << 20;

/// A key equivalent of AppKit: the characters of the key and the mask of
/// the modifiers.
pub const Key = struct {
    buf: [4]u8 = undefined,
    len: u8 = 0,
    mask: usize = 0,

    pub fn slice(k: *const Key) []const u8 {
        return k.buf[0..k.len];
    }
};

/// The key equivalent of an accelerator text, such as "Command-O",
/// "Cmd+Shift+S", "Ctrl+X", or "F5". Null when the text names no key that
/// macOS can show, so the item shows no key.
pub fn keyOf(text: []const u8) ?Key {
    if (text.len == 0) return null;
    var k: Key = .{};
    var rest = text;
    while (true) {
        // A modifier ends at a `-` or a `+`. A `-` or `+` at the end is the key.
        const cut = std.mem.indexOfAny(u8, rest[@min(rest.len, 1)..], "-+") orelse break;
        const word = rest[0 .. cut + 1];
        const bit = modifier(word) orelse return null;
        k.mask |= bit;
        rest = rest[cut + 2 ..];
        if (rest.len == 0) return null;
    }
    const code = keyCode(rest) orelse return null;
    k.len = std.unicode.utf8Encode(code, &k.buf) catch return null;
    return k;
}

fn modifier(word: []const u8) ?usize {
    const names = [_]struct { []const u8, usize }{
        .{ "Command", mask_command }, .{ "Cmd", mask_command },  .{ "Meta", mask_command },
        .{ "Control", mask_control }, .{ "Ctrl", mask_control }, .{ "Option", mask_option },
        .{ "Opt", mask_option },      .{ "Alt", mask_option },   .{ "Shift", mask_shift },
    };
    for (names) |n| if (std.ascii.eqlIgnoreCase(word, n[0])) return n[1];
    return null;
}

/// The character of a key name: one character, as lower case for a
/// letter, or a name such as "F5", "Return", or "Delete".
fn keyCode(name: []const u8) ?u21 {
    const len = std.unicode.utf8ByteSequenceLength(name[0]) catch return null;
    if (len == name.len) {
        const c = std.unicode.utf8Decode(name) catch return null;
        return if (c < 128) std.ascii.toLower(@intCast(c)) else c;
    }
    const names = [_]struct { []const u8, u21 }{
        .{ "Return", '\r' }, .{ "Enter", '\r' },  .{ "Tab", '\t' },      .{ "Space", ' ' },
        .{ "Escape", 0x1b }, .{ "Esc", 0x1b },    .{ "Delete", 0x08 },   .{ "BackSpace", 0x08 },
        .{ "Up", 0xF700 },   .{ "Down", 0xF701 }, .{ "Left", 0xF702 },   .{ "Right", 0xF703 },
        .{ "Home", 0xF729 }, .{ "End", 0xF72B },  .{ "PageUp", 0xF72C }, .{ "PageDown", 0xF72D },
    };
    for (names) |n| if (std.ascii.eqlIgnoreCase(name, n[0])) return n[1];
    // F1 to F20: NSF1FunctionKey is 0xF704.
    if (name.len >= 2 and (name[0] == 'F' or name[0] == 'f')) {
        const n = std.fmt.parseInt(u8, name[1..], 10) catch return null;
        if (n >= 1 and n <= 20) return 0xF704 + @as(u21, n) - 1;
    }
    return null;
}

const t = std.testing;

test "nsmenu: accelerators as key equivalents" {
    const o = keyOf("Command-O").?;
    try t.expectEqualStrings("o", o.slice());
    try t.expectEqual(mask_command, o.mask);
    const s = keyOf("Cmd+Shift+S").?;
    try t.expectEqualStrings("s", s.slice());
    try t.expectEqual(mask_command | mask_shift, s.mask);
    try t.expectEqual(mask_control, keyOf("Ctrl+X").?.mask);
    try t.expectEqual(mask_option | mask_command, keyOf("Option-Command-I").?.mask);
    const f5 = keyOf("F5").?;
    try t.expectEqual(@as(usize, 0), f5.mask);
    try t.expectEqual(@as(u21, 0xF708), try std.unicode.utf8Decode(f5.slice()));
    try t.expectEqualStrings("-", keyOf("Command--").?.slice());
    try t.expectEqualStrings("+", keyOf("Cmd++").?.slice());
    try t.expectEqualStrings("\r", keyOf("Command-Return").?.slice());
    // A text that names no key shows no key.
    try t.expect(keyOf("") == null);
    try t.expect(keyOf("Hyper-K") == null);
    try t.expect(keyOf("Command-Banana") == null);
    try t.expect(keyOf("Command-") == null);
}

const Record = struct {
    menus: std.ArrayListUnmanaged(struct { MenuId, i32, event.MenuAction }) = .empty,
    commands: std.ArrayListUnmanaged(event.AppCommand) = .empty,

    fn menu(ctx: *anyopaque, id: MenuId, entry: i32, action: event.MenuAction) void {
        const r: *Record = @ptrCast(@alignCast(ctx));
        r.menus.append(t.allocator, .{ id, entry, action }) catch {};
    }
    fn command(ctx: *anyopaque, c: event.AppCommand) void {
        const r: *Record = @ptrCast(@alignCast(ctx));
        r.commands.append(t.allocator, c) catch {};
    }
    fn key(_: *anyopaque, _: Id) void {}
    fn deinit(r: *Record) void {
        r.menus.deinit(t.allocator);
        r.commands.deinit(t.allocator);
    }
};

fn titleOf(item: Id) []const u8 {
    return objc.utf8(call(fn (Id, Sel) callconv(.c) Id, item, "title", .{}));
}

fn isHidden(item: Id) bool {
    return call(fn (Id, Sel) callconv(.c) bool, item, "isHidden", .{});
}

test "nsmenu: entries, cascades, and the application menu" {
    const pool = objc.Pool.push();
    defer pool.pop();
    var rec: Record = .{};
    defer rec.deinit();
    const m = try Menus.init(t.allocator, .{ .ctx = &rec, .menu = Record.menu, .command = Record.command, .key = Record.key });
    defer m.deinit();

    // A File menu, an `app` cascade, and a bar with both.
    m.set(&.{ .id = 2, .entries = &.{
        .{ .label = "Open…", .accelerator = "Command-O" },
        .{ .kind = .separator },
        .{ .label = "Wrap", .kind = .checkbutton, .selected = true },
        .{ .label = "Close", .enabled = false },
    } });
    m.set(&.{ .id = 3, .role = .app, .entries = &.{.{ .label = "About Demo" }} });
    m.set(&.{ .id = 1, .entries = &.{
        .{ .label = "Demo", .kind = .cascade, .submenu = 3 },
        .{ .label = "File", .kind = .cascade, .submenu = 2 },
    } });
    const file = m.menus.get(2).?.ns;
    try t.expectEqual(@as(usize, 4), count(file));
    try t.expectEqualStrings("Open…", titleOf(itemAt(file, 0)));
    const key = objc.utf8(call(fn (Id, Sel) callconv(.c) Id, itemAt(file, 0), "keyEquivalent", .{}));
    try t.expectEqualStrings("o", key);
    try t.expect(call(fn (Id, Sel) callconv(.c) bool, itemAt(file, 1), "isSeparatorItem", .{}));
    try t.expectEqual(@as(isize, 1), call(fn (Id, Sel) callconv(.c) isize, itemAt(file, 2), "state", .{}));
    try t.expect(!call(fn (Id, Sel) callconv(.c) bool, itemAt(file, 3), "isEnabled", .{}));
    try t.expectEqual(tagOf(2, 3), call(fn (Id, Sel) callconv(.c) isize, itemAt(file, 3), "tag", .{}));

    // The bar shows: the application menu first, the `app` cascade hidden,
    // and its item at the top of the application menu, in place of About.
    m.bar = 1;
    m.decorate();
    const bar = m.menus.get(1).?.ns;
    try t.expectEqual(@as(usize, 3), count(bar));
    try t.expect(itemAt(bar, 0) == m.app_item);
    try t.expect(isHidden(itemAt(bar, 1)));
    try t.expect(!isHidden(itemAt(bar, 2)));
    try t.expectEqualStrings("About Demo", titleOf(itemAt(m.app_menu, 0)));
    try t.expect(isHidden(m.about[0]));

    // A later set with no role keeps the role, and its new items are copied.
    m.set(&.{ .id = 3, .entries = &.{ .{ .label = "About Demo" }, .{ .label = "Check for Updates" } } });
    try t.expectEqualStrings("Check for Updates", titleOf(itemAt(m.app_menu, 1)));
    try t.expect(call(fn (Id, Sel) callconv(.c) bool, itemAt(m.app_menu, 2), "isSeparatorItem", .{}));
    try t.expectEqual(@as(usize, 3), m.app_prefix);

    // A new set of the bar keeps the application menu at the front.
    m.set(&.{ .id = 1, .entries = &.{.{ .label = "File", .kind = .cascade, .submenu = 2 }} });
    try t.expect(itemAt(bar, 0) == m.app_item);
    try t.expectEqual(@as(usize, 2), count(bar));
    try t.expectEqual(@as(usize, 0), m.app_prefix);
    try t.expect(!isHidden(m.about[0]));

    // An item answers with an `invoke` of its menu and entry, and the
    // application menu with its command.
    m.handler = null;
    Menus.onItem(m.target, objc.sel("ztkMenuItem:"), itemAt(file, 2));
    try t.expectEqual(@as(usize, 1), rec.menus.items.len);
    try t.expectEqual(@as(MenuId, 2), rec.menus.items[0][0]);
    try t.expectEqual(@as(i32, 2), rec.menus.items[0][1]);
    try t.expectEqual(event.MenuAction.invoke, rec.menus.items[0][2]);
    const quit = itemAt(m.app_menu, count(m.app_menu) - 1);
    Menus.onCommand(m.target, objc.sel("ztkAppCommand:"), quit);
    try t.expectEqualSlices(event.AppCommand, &.{.quit}, rec.commands.items);

    // One entry changes, and the drop of a submenu removes it from its item.
    m.entrySet(2, 2, &.{ .label = "Wrap", .kind = .checkbutton, .selected = false });
    try t.expectEqual(@as(isize, 0), call(fn (Id, Sel) callconv(.c) isize, itemAt(file, 2), "state", .{}));
    m.bar = 0;
    m.drop(2);
    try t.expect(call(fn (Id, Sel) callconv(.c) ?Id, itemAt(bar, 1), "submenu", .{}) == null);
}

test "nsmenu: a click on an item through AppKit gives an invoke" {
    const pool = objc.Pool.push();
    defer pool.pop();
    var rec: Record = .{};
    defer rec.deinit();
    const m = try Menus.init(t.allocator, .{ .ctx = &rec, .menu = Record.menu, .command = Record.command, .key = Record.key });
    defer m.deinit();
    m.set(&.{ .id = 7, .entries = &.{ .{ .label = "One" }, .{ .label = "Two" } } });
    const ns = m.menus.get(7).?.ns;
    call(fn (Id, Sel, isize) callconv(.c) void, ns, "performActionForItemAtIndex:", .{1});
    var invoked = false;
    for (rec.menus.items) |r| if (r[2] == .invoke and r[0] == 7 and r[1] == 1) {
        invoked = true;
    };
    try t.expect(invoked);
}
