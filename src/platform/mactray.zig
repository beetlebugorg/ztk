//! The tray icons of macOS: an `NSStatusItem` in the menu bar for each
//! tray of the core. The icon is an `NSImage` of the RGBA pixels, 18
//! points high, as a template image when the core asks, so the menu bar
//! draws it in its own colors for a light bar, a dark bar, and the
//! highlight. A tray with no pixels shows the icon of the application.
//!
//! A status item with a menu opens the menu on a click by itself, so the
//! backend sends `click` and `double` only for a tray with no menu. A
//! click with the secondary button, or with Control, is `menu`.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const objc = @import("../sys/objc.zig");
const plat = @import("platform.zig");
const event = @import("../base/event.zig");
const Id = objc.Id;
const Sel = objc.Sel;
const Class = objc.Class;

const NSSize = extern struct { w: f64, h: f64 };

/// The height of an icon in the menu bar, in points.
const icon_points: f64 = 18;

pub const Sink = struct {
    ctx: *anyopaque,
    action: *const fn (ctx: *anyopaque, owner: *anyopaque, id: plat.TrayId, action: event.TrayAction) void,
};

const Rec = struct {
    id: plat.TrayId,
    item: Id,
    /// The window of `trayCreate`, for the events.
    owner: *anyopaque,
};

pub const Trays = struct {
    gpa: std.mem.Allocator,
    sink: Sink,
    target: Id,
    recs: std.ArrayListUnmanaged(Rec) = .empty,
    next: plat.TrayId = 1,

    pub fn init(gpa: std.mem.Allocator, sink: Sink) !*Trays {
        const tr = try gpa.create(Trays);
        tr.* = .{ .gpa = gpa, .sink = sink, .target = objc.new(targetClass()) };
        objc.setData(tr.target, tr);
        return tr;
    }

    pub fn deinit(tr: *Trays) void {
        while (tr.recs.items.len > 0) tr.drop(tr.recs.items[0].id);
        tr.recs.deinit(tr.gpa);
        objc.setData(tr.target, null);
        objc.release(tr.target);
        tr.gpa.destroy(tr);
    }

    pub fn create(tr: *Trays, owner: *anyopaque, icon: plat.TrayIcon, template: bool, tooltip: []const u8) plat.TrayId {
        const pool = objc.Pool.push();
        defer pool.pop();
        const bar = call(fn (Class, Sel) callconv(.c) Id, objc.class("NSStatusBar").?, "systemStatusBar", .{});
        // NSVariableStatusItemLength is -1.
        const item = call(fn (Id, Sel, f64) callconv(.c) Id, bar, "statusItemWithLength:", .{-1});
        _ = call(fn (Id, Sel) callconv(.c) Id, item, "retain", .{});
        const id = tr.next;
        tr.recs.append(tr.gpa, .{ .id = id, .item = item, .owner = owner }) catch {
            call(fn (Id, Sel, Id) callconv(.c) void, bar, "removeStatusItem:", .{item});
            objc.release(item);
            return 0;
        };
        tr.next +%= 1;
        if (tr.next == 0) tr.next = 1;
        const button = buttonOf(item);
        call(fn (Id, Sel, ?Id) callconv(.c) void, button, "setTarget:", .{tr.target});
        call(fn (Id, Sel, ?Sel) callconv(.c) void, button, "setAction:", .{objc.sel("ztkTray:")});
        // NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp.
        _ = call(fn (Id, Sel, u64) callconv(.c) isize, button, "sendActionOn:", .{(1 << 2) | (1 << 4)});
        call(fn (Id, Sel, isize) callconv(.c) void, button, "setTag:", .{@as(isize, id)});
        tr.set(id, icon, template, tooltip, null);
        return id;
    }

    /// Changes the icon, the tooltip, and the menu. `menu` is the `NSMenu`
    /// of the menu of the tray, or null.
    pub fn set(tr: *Trays, id: plat.TrayId, icon: plat.TrayIcon, template: bool, tooltip: []const u8, menu: ?Id) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const rec = tr.find(id) orelse return;
        const button = buttonOf(rec.item);
        const image = imageOf(icon);
        defer if (image) |x| objc.release(x);
        if (image) |x| call(fn (Id, Sel, bool) callconv(.c) void, x, "setTemplate:", .{template});
        call(fn (Id, Sel, ?Id) callconv(.c) void, button, "setImage:", .{image orelse appIcon()});
        const tip = objc.nsString(tooltip);
        defer objc.release(tip);
        call(fn (Id, Sel, ?Id) callconv(.c) void, button, "setToolTip:", .{if (tooltip.len > 0) tip else null});
        call(fn (Id, Sel, ?Id) callconv(.c) void, rec.item, "setMenu:", .{menu});
    }

    pub fn drop(tr: *Trays, id: plat.TrayId) void {
        for (tr.recs.items, 0..) |r, i| if (r.id == id) {
            const bar = call(fn (Class, Sel) callconv(.c) Id, objc.class("NSStatusBar").?, "systemStatusBar", .{});
            call(fn (Id, Sel, ?Id) callconv(.c) void, r.item, "setMenu:", .{null});
            call(fn (Id, Sel, Id) callconv(.c) void, bar, "removeStatusItem:", .{r.item});
            objc.release(r.item);
            _ = tr.recs.orderedRemove(i);
            return;
        };
    }

    /// Removes each tray of a window that closes.
    pub fn dropOwner(tr: *Trays, owner: *anyopaque) void {
        var i: usize = 0;
        while (i < tr.recs.items.len) {
            if (tr.recs.items[i].owner == owner) tr.drop(tr.recs.items[i].id) else i += 1;
        }
    }

    pub fn find(tr: *Trays, id: plat.TrayId) ?*Rec {
        for (tr.recs.items) |*r| if (r.id == id) return r;
        return null;
    }

    fn onClick(target: Id, _: Sel, button: Id) callconv(.c) void {
        const tr: *Trays = @ptrCast(@alignCast(objc.getData(target) orelse return));
        const id: plat.TrayId = @intCast(call(fn (Id, Sel) callconv(.c) isize, button, "tag", .{}));
        const rec = tr.find(id) orelse return;
        tr.sink.action(tr.sink.ctx, rec.owner, id, actionOf(currentEvent()));
    }

    fn targetClass() Class {
        if (objc.class("ZtkTrayTarget")) |c| return c;
        const b = objc.ClassBuilder.begin("NSObject", "ZtkTrayTarget").?;
        b.method("ztkTray:", @ptrCast(&onClick), "v@:@");
        return b.finish();
    }
};

/// The action of the event of a click: `menu` for the secondary button or
/// Control, `double` for a second click, else `click`.
fn actionOf(ev: ?Id) event.TrayAction {
    const e = ev orelse return .click;
    const typ = call(fn (Id, Sel) callconv(.c) usize, e, "type", .{});
    // NSEventTypeRightMouseDown and Up are 3 and 4.
    if (typ == 3 or typ == 4) return .menu;
    const flags = call(fn (Id, Sel) callconv(.c) u64, e, "modifierFlags", .{});
    if (flags & (1 << 18) != 0) return .menu;
    // A mouse event: NSEventTypeLeftMouseDown and Up are 1 and 2.
    if (typ == 1 or typ == 2) {
        if (call(fn (Id, Sel) callconv(.c) isize, e, "clickCount", .{}) == 2) return .double;
    }
    return .click;
}

fn call(comptime Fn: type, target: anytype, selector: [*:0]const u8, args: anytype) @typeInfo(Fn).@"fn".return_type.? {
    return objc.call(Fn, target, selector, args);
}

fn currentEvent() ?Id {
    const app = call(fn (Class, Sel) callconv(.c) Id, objc.class("NSApplication").?, "sharedApplication", .{});
    return call(fn (Id, Sel) callconv(.c) ?Id, app, "currentEvent", .{});
}

fn buttonOf(item: Id) Id {
    return call(fn (Id, Sel) callconv(.c) Id, item, "button", .{});
}

fn appIcon() ?Id {
    const app = call(fn (Class, Sel) callconv(.c) Id, objc.class("NSApplication").?, "sharedApplication", .{});
    const src = call(fn (Id, Sel) callconv(.c) ?Id, app, "applicationIconImage", .{}) orelse return null;
    const copy = call(fn (Id, Sel) callconv(.c) Id, src, "copy", .{});
    const autoreleased = call(fn (Id, Sel) callconv(.c) Id, copy, "autorelease", .{});
    call(fn (Id, Sel, NSSize) callconv(.c) void, autoreleased, "setSize:", .{NSSize{ .w = icon_points, .h = icon_points }});
    return autoreleased;
}

/// The size of an icon in points: 18 high, with the shape of the pixels.
pub fn pointSize(width: u32, height: u32) NSSize {
    if (width == 0 or height == 0) return .{ .w = icon_points, .h = icon_points };
    return .{ .w = icon_points * @as(f64, @floatFromInt(width)) / @as(f64, @floatFromInt(height)), .h = icon_points };
}

/// An `NSImage` of RGBA pixels with straight alpha, retained, or null for
/// an icon with no pixels.
fn imageOf(icon: plat.TrayIcon) ?Id {
    const rep = repOf(icon) orelse return null;
    defer objc.release(rep);
    const img0 = call(fn (Class, Sel) callconv(.c) Id, objc.class("NSImage").?, "alloc", .{});
    const img = call(fn (Id, Sel, NSSize) callconv(.c) Id, img0, "initWithSize:", .{pointSize(icon.width, icon.height)});
    call(fn (Id, Sel, Id) callconv(.c) void, img, "addRepresentation:", .{rep});
    return img;
}

/// The image of the Dock for `wm iconphoto`: one representation for each
/// photo, at the size of the largest, retained, or null with no pixels.
pub fn dockImageOf(icons: []const plat.TrayIcon) ?Id {
    var side: u32 = 0;
    for (icons) |i| side = @max(side, @max(i.width, i.height));
    if (side == 0) return null;
    const img0 = call(fn (Class, Sel) callconv(.c) Id, objc.class("NSImage").?, "alloc", .{});
    const s: f64 = @floatFromInt(side);
    const img = call(fn (Id, Sel, NSSize) callconv(.c) Id, img0, "initWithSize:", .{NSSize{ .w = s, .h = s }});
    var any = false;
    for (icons) |icon| {
        const rep = repOf(icon) orelse continue;
        defer objc.release(rep);
        call(fn (Id, Sel, Id) callconv(.c) void, img, "addRepresentation:", .{rep});
        any = true;
    }
    if (!any) {
        objc.release(img);
        return null;
    }
    return img;
}

/// An `NSBitmapImageRep` of RGBA pixels with straight alpha, retained.
fn repOf(icon: plat.TrayIcon) ?Id {
    if (icon.width == 0 or icon.height == 0 or icon.pixels.len < @as(usize, icon.width) * icon.height * 4) return null;
    const NSDeviceRGBColorSpace = objc.nsString("NSDeviceRGBColorSpace");
    defer objc.release(NSDeviceRGBColorSpace);
    const rep0 = call(fn (Class, Sel) callconv(.c) Id, objc.class("NSBitmapImageRep").?, "alloc", .{});
    // NSBitmapFormatAlphaNonpremultiplied is 1 << 1.
    const rep = call(
        fn (Id, Sel, ?*anyopaque, isize, isize, isize, isize, bool, bool, Id, usize, isize, isize) callconv(.c) ?Id,
        rep0,
        "initWithBitmapDataPlanes:pixelsWide:pixelsHigh:bitsPerSample:samplesPerPixel:hasAlpha:isPlanar:colorSpaceName:bitmapFormat:bytesPerRow:bitsPerPixel:",
        .{ null, @as(isize, icon.width), @as(isize, icon.height), 8, 4, true, false, NSDeviceRGBColorSpace, 1 << 1, @as(isize, icon.width) * 4, 32 },
    ) orelse return null;
    defer objc.release(rep);
    const data = call(fn (Id, Sel) callconv(.c) ?[*]u8, rep, "bitmapData", .{}) orelse return null;
    const n = @as(usize, icon.width) * icon.height * 4;
    @memcpy(data[0..n], icon.pixels[0..n]);
    return call(fn (Id, Sel) callconv(.c) Id, rep, "retain", .{});
}

const t = std.testing;

test "mactray: the icon is 18 points high with the shape of its pixels" {
    try t.expectEqual(@as(f64, 18), pointSize(36, 36).w);
    try t.expectEqual(@as(f64, 36), pointSize(64, 32).w);
    try t.expectEqual(@as(f64, 18), pointSize(0, 0).h);
}

test "mactray: an image of RGBA pixels" {
    const pool = objc.Pool.push();
    defer pool.pop();
    var px: [4 * 4 * 4]u8 = @splat(0);
    px[0..4].* = .{ 255, 0, 0, 255 };
    const img = imageOf(.{ .width = 4, .height = 4, .pixels = &px }).?;
    defer objc.release(img);
    try t.expect(imageOf(.{ .width = 4, .height = 4, .pixels = px[0..8] }) == null);
    try t.expect(imageOf(.{ .width = 0, .height = 0, .pixels = "" }) == null);
}

test "mactray: the Dock image has a representation for each photo" {
    const pool = objc.Pool.push();
    defer pool.pop();
    var big: [32 * 32 * 4]u8 = @splat(255);
    var small: [16 * 16 * 4]u8 = @splat(255);
    const img = dockImageOf(&.{ .{ .width = 16, .height = 16, .pixels = &small }, .{ .width = 32, .height = 32, .pixels = &big } }).?;
    defer objc.release(img);
    const reps = call(fn (Id, Sel) callconv(.c) Id, img, "representations", .{});
    try t.expectEqual(@as(usize, 2), call(fn (Id, Sel) callconv(.c) usize, reps, "count", .{}));
    try t.expectEqual(@as(f64, 32), call(fn (Id, Sel) callconv(.c) NSSize, img, "size", .{}).w);
    try t.expect(dockImageOf(&.{.{ .width = 0, .height = 0, .pixels = "" }}) == null);
}
