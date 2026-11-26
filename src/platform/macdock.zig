//! The Dock icon of macOS for `ztk::taskbar`: the badge count as the
//! badge label of `NSDockTile`, a progress bar over the icon of the
//! application, and the bounce of `requestUserAttention:`. The Dock has
//! one icon for the app, so the window of a call has no effect.
//!
//! A progress value gives the tile a content view: an image view with
//! the icon of the application, and an `NSProgressIndicator` bar along
//! its bottom. `display` draws the tile again after each change. A value
//! of `none` removes the view, and the Dock shows the icon alone. An
//! `indeterminate` progress is a bar with no value. `paused` and `failed`
//! show the value, as the Dock has no colors for them.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const objc = @import("../sys/objc.zig");
const plat = @import("platform.zig");
const Id = objc.Id;
const Sel = objc.Sel;
const Class = objc.Class;

const NSPoint = extern struct { x: f64, y: f64 };
const NSSize = extern struct { w: f64, h: f64 };
const NSRect = extern struct { origin: NSPoint, size: NSSize };

/// NSCriticalRequest and NSInformationalRequest.
const request_critical: isize = 0;
const request_informational: isize = 10;

fn call(comptime Fn: type, target: anytype, selector: [*:0]const u8, args: anytype) @typeInfo(Fn).@"fn".return_type.? {
    return objc.call(Fn, target, selector, args);
}

fn nsApp() Id {
    return call(fn (Class, Sel) callconv(.c) Id, objc.class("NSApplication").?, "sharedApplication", .{});
}

pub const Dock = struct {
    /// The content view of the tile while a progress bar shows, and its bar.
    view: ?Id = null,
    bar: ?Id = null,
    /// The id of the last request for attention, or null.
    request: ?isize = null,

    fn tile() Id {
        return call(fn (Id, Sel) callconv(.c) Id, nsApp(), "dockTile", .{});
    }

    pub fn deinit(d: *Dock) void {
        d.setProgress(null, false);
        d.cancel();
    }

    fn setBadge(_: *Dock, text: []const u8) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const s = objc.nsString(text);
        defer objc.release(s);
        call(fn (Id, Sel, ?Id) callconv(.c) void, tile(), "setBadgeLabel:", .{if (text.len > 0) s else null});
    }

    pub fn badge(_: *Dock) []const u8 {
        const s = call(fn (Id, Sel) callconv(.c) ?Id, tile(), "badgeLabel", .{}) orelse return "";
        return objc.utf8(s);
    }

    fn setProgress(d: *Dock, value: ?f32, indeterminate: bool) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const t = tile();
        const v = value orelse {
            if (d.view) |view| {
                call(fn (Id, Sel, ?Id) callconv(.c) void, t, "setContentView:", .{null});
                objc.release(view);
                objc.release(d.bar.?);
                d.view = null;
                d.bar = null;
                call(fn (Id, Sel) callconv(.c) void, t, "display", .{});
            }
            return;
        };
        if (d.view == null) d.makeView(t);
        call(fn (Id, Sel, bool) callconv(.c) void, d.bar.?, "setIndeterminate:", .{indeterminate});
        call(fn (Id, Sel, f64) callconv(.c) void, d.bar.?, "setDoubleValue:", .{@as(f64, v)});
        call(fn (Id, Sel) callconv(.c) void, t, "display", .{});
    }

    fn makeView(d: *Dock, t: Id) void {
        const size = call(fn (Id, Sel) callconv(.c) NSSize, t, "size", .{});
        const frame: NSRect = .{ .origin = .{ .x = 0, .y = 0 }, .size = size };
        const image_view0 = call(fn (Class, Sel) callconv(.c) Id, objc.class("NSImageView").?, "alloc", .{});
        const view = call(fn (Id, Sel, NSRect) callconv(.c) Id, image_view0, "initWithFrame:", .{frame});
        if (call(fn (Id, Sel) callconv(.c) ?Id, nsApp(), "applicationIconImage", .{})) |icon|
            call(fn (Id, Sel, Id) callconv(.c) void, view, "setImage:", .{icon});
        // A bar along the bottom of the tile, a sixth of its height.
        const h = size.h / 6;
        const bar_frame: NSRect = .{ .origin = .{ .x = size.w * 0.1, .y = h * 0.5 }, .size = .{ .w = size.w * 0.8, .h = h } };
        const bar0 = call(fn (Class, Sel) callconv(.c) Id, objc.class("NSProgressIndicator").?, "alloc", .{});
        const bar = call(fn (Id, Sel, NSRect) callconv(.c) Id, bar0, "initWithFrame:", .{bar_frame});
        // NSProgressIndicatorStyleBar is 0.
        call(fn (Id, Sel, usize) callconv(.c) void, bar, "setStyle:", .{0});
        call(fn (Id, Sel, bool) callconv(.c) void, bar, "setIndeterminate:", .{false});
        call(fn (Id, Sel, f64) callconv(.c) void, bar, "setMinValue:", .{0});
        call(fn (Id, Sel, f64) callconv(.c) void, bar, "setMaxValue:", .{1});
        call(fn (Id, Sel, Id) callconv(.c) void, view, "addSubview:", .{bar});
        call(fn (Id, Sel, ?Id) callconv(.c) void, t, "setContentView:", .{view});
        d.view = view;
        d.bar = bar;
    }

    /// Shows the badge and the progress of `state`.
    pub fn set(d: *Dock, state: plat.Taskbar) void {
        var buf: [16]u8 = undefined;
        d.setBadge(if (state.badge == 0) "" else std.fmt.bufPrint(&buf, "{d}", .{state.badge}) catch "");
        switch (state.progress) {
            .none => d.setProgress(null, false),
            .indeterminate => d.setProgress(0, true),
            .normal, .paused, .failed => d.setProgress(std.math.clamp(state.value, 0, 1), false),
        }
    }

    fn cancel(d: *Dock) void {
        if (d.request) |r| {
            call(fn (Id, Sel, isize) callconv(.c) void, nsApp(), "cancelUserAttentionRequest:", .{r});
            d.request = null;
        }
    }

    pub fn setAttention(d: *Dock, critical: bool) void {
        const app = nsApp();
        d.cancel();
        const kind: isize = if (critical) request_critical else request_informational;
        // The answer is 0 while the app is active: macOS makes no request then.
        const r = call(fn (Id, Sel, isize) callconv(.c) isize, app, "requestUserAttention:", .{kind});
        if (r != 0) d.request = r;
    }
};
