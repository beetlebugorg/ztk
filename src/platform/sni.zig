//! Tray icons on Linux: the StatusNotifierItem interface over the session
//! bus (`dbus.zig`). Each icon has its own bus name,
//! `org.kde.StatusNotifierItem-<pid>-<id>`, and the object
//! `/StatusNotifierItem`. The tray calls `RegisterStatusNotifierItem` of
//! `org.kde.StatusNotifierWatcher` with the name, and again when a new
//! watcher comes on the bus. The host of the panel reads the properties
//! and calls `Activate`, `SecondaryActivate`, and `ContextMenu`, which
//! give the actions `click`, `double`, and `menu`.
//!
//! The icon goes as `IconPixmap`: ARGB, 32 bits, in network byte order.
//! An item has no D-Bus menu (`com.canonical.dbusmenu`) yet: `Menu` is
//! `/NO_DBUSMENU`, and a script posts its own menu for `menu`.
//!
//! The source of the protocol is the StatusNotifierItem specification of
//! freedesktop.org. docs/references/dbus.md has the list.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const dbus = @import("dbus.zig");
const plat = @import("platform.zig");
const TrayAction = @import("../event.zig").TrayAction;

pub const item_path = "/StatusNotifierItem";
pub const item_iface = "org.kde.StatusNotifierItem";
pub const watcher = "org.kde.StatusNotifierWatcher";
/// The match rule for a new watcher on the bus.
pub const watcher_rule = "type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='org.kde.StatusNotifierWatcher'";

pub const Item = struct {
    id: plat.TrayId,
    name: []u8,
    /// ARGB in network byte order.
    pixmap: []u8 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    tooltip: []u8 = &.{},
};

pub const Action = struct { id: plat.TrayId, action: TrayAction };

pub const Tray = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayListUnmanaged(Item) = .empty,
    next: plat.TrayId = 1,
    /// The `Id` property: the name of the app.
    app_id: []const u8 = "ztk",
    /// The actions of the host calls, for the backend to give as events.
    actions: std.ArrayListUnmanaged(Action) = .empty,

    pub fn deinit(t: *Tray) void {
        for (t.items.items) |*i| freeItem(t.gpa, i);
        t.items.deinit(t.gpa);
        t.actions.deinit(t.gpa);
    }

    fn freeItem(gpa: std.mem.Allocator, i: *Item) void {
        gpa.free(i.name);
        gpa.free(i.pixmap);
        gpa.free(i.tooltip);
    }

    /// Takes the bus name of a new icon and registers it. Gives 0 when
    /// the bus does not give the name.
    pub fn create(t: *Tray, c: *dbus.Conn, pid: i32, icon: plat.TrayIcon, tooltip: []const u8) plat.TrayId {
        const id = t.next;
        const name = std.fmt.allocPrint(t.gpa, "org.kde.StatusNotifierItem-{d}-{d}", .{ pid, id }) catch return 0;
        var item: Item = .{ .id = id, .name = name };
        setData(t.gpa, &item, icon, tooltip) catch {
            freeItem(t.gpa, &item);
            return 0;
        };
        if (!requestName(c, name)) {
            freeItem(t.gpa, &item);
            return 0;
        }
        t.items.append(t.gpa, item) catch {
            freeItem(t.gpa, &item);
            return 0;
        };
        t.next += 1;
        register(c, name);
        return id;
    }

    /// Changes the icon and the tooltip, and tells the host.
    pub fn set(t: *Tray, c: *dbus.Conn, id: plat.TrayId, icon: plat.TrayIcon, tooltip: []const u8) void {
        const item = t.find(id) orelse return;
        setData(t.gpa, item, icon, tooltip) catch return;
        for ([_][]const u8{ "NewIcon", "NewToolTip", "NewTitle" }) |m|
            _ = c.send(.{ .type = .signal, .path = item_path, .interface = item_iface, .member = m, .no_reply = true }) catch {};
    }

    pub fn drop(t: *Tray, c: *dbus.Conn, id: plat.TrayId) void {
        for (t.items.items, 0..) |*i, k| if (i.id == id) {
            releaseName(c, i.name);
            freeItem(t.gpa, i);
            _ = t.items.orderedRemove(k);
            return;
        };
    }

    /// Registers each icon again, for a new watcher.
    pub fn registerAll(t: *Tray, c: *dbus.Conn) void {
        for (t.items.items) |i| register(c, i.name);
    }

    fn find(t: *Tray, id: plat.TrayId) ?*Item {
        for (t.items.items) |*i| if (i.id == id) return i;
        return null;
    }

    /// The item of a call: by the bus name of the destination, or the
    /// first item for a call to the unique name.
    fn itemOf(t: *Tray, msg: *const dbus.Message) ?*Item {
        for (t.items.items) |*i| if (std.mem.eql(u8, i.name, msg.destination)) return i;
        return if (t.items.items.len > 0) &t.items.items[0] else null;
    }

    /// The handler of `dbus.Conn.objects`.
    pub fn handle(ctx: *anyopaque, c: *dbus.Conn, msg: *const dbus.Message) bool {
        const t: *Tray = @ptrCast(@alignCast(ctx));
        if (!std.mem.eql(u8, msg.path, item_path)) return false;
        const item = t.itemOf(msg) orelse return false;
        var w: dbus.Writer = .{ .gpa = t.gpa };
        defer w.deinit();
        const m = msg.member;
        if (std.mem.eql(u8, msg.interface, item_iface) or msg.interface.len == 0) {
            const action: ?TrayAction = if (std.mem.eql(u8, m, "Activate"))
                .click
            else if (std.mem.eql(u8, m, "SecondaryActivate"))
                .double
            else if (std.mem.eql(u8, m, "ContextMenu"))
                .menu
            else if (std.mem.eql(u8, m, "Scroll"))
                null
            else if (msg.interface.len == 0) return t.handleOther(c, msg, item, &w) else {
                c.sendError(msg, "org.freedesktop.DBus.Error.UnknownMethod");
                return true;
            };
            if (action) |a| t.actions.append(t.gpa, .{ .id = item.id, .action = a }) catch {};
            c.sendReply(msg, "", "");
            return true;
        }
        return t.handleOther(c, msg, item, &w);
    }

    fn handleOther(t: *Tray, c: *dbus.Conn, msg: *const dbus.Message, item: *Item, w: *dbus.Writer) bool {
        const m = msg.member;
        if (std.mem.eql(u8, msg.interface, "org.freedesktop.DBus.Properties")) {
            var r = msg.reader();
            const iface = r.string() catch "";
            if (std.mem.eql(u8, m, "GetAll")) {
                const a = w.beginArray(8);
                if (std.mem.eql(u8, iface, item_iface)) for (props) |p| {
                    w.beginStruct();
                    w.string(p);
                    t.property(w, item, p);
                };
                w.endArray(a);
                c.sendReply(msg, "a{sv}", w.bytes() catch return true);
            } else if (std.mem.eql(u8, m, "Get")) {
                const name = r.string() catch "";
                for (props) |p| if (std.mem.eql(u8, p, name) and std.mem.eql(u8, iface, item_iface)) {
                    t.property(w, item, p);
                    c.sendReply(msg, "v", w.bytes() catch return true);
                    return true;
                };
                c.sendError(msg, "org.freedesktop.DBus.Error.UnknownProperty");
            } else c.sendError(msg, "org.freedesktop.DBus.Error.PropertyReadOnly");
            return true;
        }
        if (std.mem.eql(u8, msg.interface, "org.freedesktop.DBus.Introspectable") and std.mem.eql(u8, m, "Introspect")) {
            w.string(introspection);
            c.sendReply(msg, "s", w.bytes() catch return true);
            return true;
        }
        if (std.mem.eql(u8, msg.interface, "org.freedesktop.DBus.Peer") and std.mem.eql(u8, m, "Ping")) {
            c.sendReply(msg, "", "");
            return true;
        }
        return false;
    }

    const props = [_][]const u8{ "Category", "Id", "Title", "Status", "WindowId", "IconName", "IconPixmap", "ToolTip", "ItemIsMenu", "Menu" };

    /// Writes the variant of a property.
    fn property(t: *Tray, w: *dbus.Writer, item: *Item, p: []const u8) void {
        if (std.mem.eql(u8, p, "Category")) {
            w.variant("s");
            w.string("ApplicationStatus");
        } else if (std.mem.eql(u8, p, "Id")) {
            w.variant("s");
            w.string(t.app_id);
        } else if (std.mem.eql(u8, p, "Title")) {
            w.variant("s");
            w.string(if (item.tooltip.len > 0) item.tooltip else t.app_id);
        } else if (std.mem.eql(u8, p, "Status")) {
            w.variant("s");
            w.string("Active");
        } else if (std.mem.eql(u8, p, "WindowId")) {
            w.variant("i");
            w.int(0);
        } else if (std.mem.eql(u8, p, "IconName")) {
            w.variant("s");
            w.string("");
        } else if (std.mem.eql(u8, p, "IconPixmap")) {
            w.variant("a(iiay)");
            pixmaps(w, item);
        } else if (std.mem.eql(u8, p, "ToolTip")) {
            // (icon name, icon pixmaps, title, text).
            w.variant("(sa(iiay)ss)");
            w.beginStruct();
            w.string("");
            const a = w.beginArray(8);
            w.endArray(a);
            w.string(item.tooltip);
            w.string("");
        } else if (std.mem.eql(u8, p, "ItemIsMenu")) {
            w.variant("b");
            w.boolean(false);
        } else if (std.mem.eql(u8, p, "Menu")) {
            w.variant("o");
            w.string("/NO_DBUSMENU");
        }
    }
};

fn pixmaps(w: *dbus.Writer, item: *const Item) void {
    const a = w.beginArray(8);
    if (item.pixmap.len > 0) {
        w.beginStruct();
        w.int(@intCast(item.width));
        w.int(@intCast(item.height));
        const b = w.beginArray(1);
        w.raw(item.pixmap);
        w.endArray(b);
    }
    w.endArray(a);
}

fn setData(gpa: std.mem.Allocator, item: *Item, icon: plat.TrayIcon, tooltip: []const u8) !void {
    const n = @as(usize, icon.width) * icon.height;
    if (icon.pixels.len < n * 4) return error.BadIcon;
    const px = try gpa.alloc(u8, n * 4);
    errdefer gpa.free(px);
    const tip = try gpa.dupe(u8, tooltip);
    for (0..n) |k| {
        const s = icon.pixels[k * 4 ..][0..4];
        px[k * 4 ..][0..4].* = .{ s[3], s[0], s[1], s[2] };
    }
    gpa.free(item.pixmap);
    gpa.free(item.tooltip);
    item.pixmap = px;
    item.tooltip = tip;
    item.width = icon.width;
    item.height = icon.height;
}

/// `RequestName` with the flag DO_NOT_QUEUE (4). Reply 1: the owner.
fn requestName(c: *dbus.Conn, name: []const u8) bool {
    var w: dbus.Writer = .{ .gpa = c.gpa };
    defer w.deinit();
    w.string(name);
    w.uint(4);
    const r = c.call(.{ .destination = "org.freedesktop.DBus", .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus", .member = "RequestName", .signature = "su", .body = w.bytes() catch return false }, 5000) catch return false;
    defer r.deinit(c.gpa);
    var rd = r.reader();
    return (rd.uint() catch 0) == 1;
}

fn releaseName(c: *dbus.Conn, name: []const u8) void {
    var w: dbus.Writer = .{ .gpa = c.gpa };
    defer w.deinit();
    w.string(name);
    _ = c.send(.{ .destination = "org.freedesktop.DBus", .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus", .member = "ReleaseName", .signature = "s", .body = w.bytes() catch return, .no_reply = true }) catch {};
}

/// Tells the watcher of the name. The reply does not matter: with no
/// watcher, the call fails, and a new watcher brings a new call.
fn register(c: *dbus.Conn, name: []const u8) void {
    var w: dbus.Writer = .{ .gpa = c.gpa };
    defer w.deinit();
    w.string(name);
    _ = c.send(.{ .destination = watcher, .path = "/StatusNotifierWatcher", .interface = watcher, .member = "RegisterStatusNotifierItem", .signature = "s", .body = w.bytes() catch return, .no_reply = true }) catch {};
}

/// The arguments of a `NameOwnerChanged` signal: true when the watcher has a new owner.
pub fn watcherCame(m: *const dbus.Message) bool {
    if (!std.mem.eql(u8, m.member, "NameOwnerChanged")) return false;
    var r = m.reader();
    const name = r.string() catch return false;
    _ = r.string() catch return false;
    const new = r.string() catch return false;
    return std.mem.eql(u8, name, watcher) and new.len > 0;
}

const introspection =
    \\<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
    \\<node>
    \\ <interface name="org.kde.StatusNotifierItem">
    \\  <property name="Category" type="s" access="read"/>
    \\  <property name="Id" type="s" access="read"/>
    \\  <property name="Title" type="s" access="read"/>
    \\  <property name="Status" type="s" access="read"/>
    \\  <property name="WindowId" type="i" access="read"/>
    \\  <property name="IconName" type="s" access="read"/>
    \\  <property name="IconPixmap" type="a(iiay)" access="read"/>
    \\  <property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
    \\  <property name="ItemIsMenu" type="b" access="read"/>
    \\  <property name="Menu" type="o" access="read"/>
    \\  <method name="Activate"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
    \\  <method name="SecondaryActivate"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
    \\  <method name="ContextMenu"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
    \\  <method name="Scroll"><arg name="delta" type="i" direction="in"/><arg name="orientation" type="s" direction="in"/></method>
    \\  <signal name="NewTitle"/>
    \\  <signal name="NewIcon"/>
    \\  <signal name="NewToolTip"/>
    \\  <signal name="NewStatus"><arg name="status" type="s"/></signal>
    \\ </interface>
    \\ <interface name="org.freedesktop.DBus.Properties">
    \\  <method name="Get"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/></method>
    \\  <method name="GetAll"><arg type="s" direction="in"/><arg type="a{sv}" direction="out"/></method>
    \\ </interface>
    \\ <interface name="org.freedesktop.DBus.Introspectable">
    \\  <method name="Introspect"><arg type="s" direction="out"/></method>
    \\ </interface>
    \\</node>
    \\
;

const testing = std.testing;

test "sni: the pixmap is ARGB in network byte order" {
    var item: Item = .{ .id = 1, .name = try testing.allocator.dupe(u8, "n") };
    defer Tray.freeItem(testing.allocator, &item);
    try setData(testing.allocator, &item, .{ .width = 1, .height = 1, .pixels = &.{ 1, 2, 3, 4 } }, "tip");
    try testing.expectEqualSlices(u8, &.{ 4, 1, 2, 3 }, item.pixmap);
    var w: dbus.Writer = .{ .gpa = testing.allocator };
    defer w.deinit();
    pixmaps(&w, &item);
    // Array length, padding to 8, width, height, byte array length, the bytes.
    try testing.expectEqualSlices(u8, &.{ 16, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 4, 0, 0, 0, 4, 1, 2, 3 }, try w.bytes());
}
