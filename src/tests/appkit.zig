//! Tests of the AppKit backend. A test that opens a window runs only with
//! ZTK_TEST_WINDOWS=1, which CI sets, because rule 12 of AGENTS.md keeps
//! windows off the live desktop session of a development machine. Without
//! it, or off the main thread, the test prints a `SKIP:` line and returns.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const appkit = @import("../platform/appkit.zig");
const objc = @import("../sys/objc.zig");
const event = @import("../event.zig");
const plat = @import("../platform/platform.zig");
const scene_tests = @import("scene.zig");
const Frame = @import("../scene.zig").Frame;
const t = std.testing;

extern "c" fn pthread_main_np() c_int;

fn windowsAllowed() bool {
    const v = std.c.getenv("ZTK_TEST_WINDOWS") orelse {
        std.debug.print("SKIP: appkit windows need ZTK_TEST_WINDOWS=1\n", .{});
        return false;
    };
    if (v[0] != '1') return false;
    if (pthread_main_np() == 0) {
        std.debug.print("SKIP: appkit windows need the main thread\n", .{});
        return false;
    }
    return true;
}

/// Polls until an event of kind `tag` comes, for at most two seconds.
fn waitFor(p: plat.Platform, tag: std.meta.Tag(event.Event)) !event.Event {
    var list: std.ArrayListUnmanaged(event.Event) = .empty;
    defer list.deinit(t.allocator);
    const end = p.nowUs() + 2_000_000;
    while (p.nowUs() < end) {
        p.wait(50_000);
        list.clearRetainingCapacity();
        try p.poll(t.allocator, &list);
        for (list.items) |e| if (e == tag) return e;
    }
    std.debug.print("appkit: no {s} event in two seconds\n", .{@tagName(tag)});
    return error.NoEvent;
}

test "appkit: a window draws with Metal and gives frame, resize, and close events" {
    if (!windowsAllowed()) return;
    const a = try appkit.AppKit.init(t.allocator);
    const p = a.platform();
    defer p.vtable.deinit(p.ptr);
    const win = try p.createWindow(.{ .title = "ztk test", .size = .{ .w = 320, .h = 200 } });
    var destroyed = false;
    defer if (!destroyed) p.destroyWindow(win);
    try t.expect(win.scale >= 1);

    // The first frame comes with no request.
    _ = try waitFor(p, .frame);

    // One draw of a scene of the size of the window in device pixels.
    var f: Frame = .{};
    defer f.scene.deinit(t.allocator);
    try scene_tests.build(t.allocator, &f.scene, 0, win.scale);
    f.scene.width = @intFromFloat(@round(@as(f32, @floatFromInt(win.size.w)) * win.scale));
    f.scene.height = @intFromFloat(@round(@as(f32, @floatFromInt(win.size.h)) * win.scale));
    const target = p.target(win);
    try target.draw(target.ctx, &f);

    // The display link answers a request with one frame event.
    p.requestFrame(win);
    _ = try waitFor(p, .frame);

    p.vtable.requestSize(p.ptr, win, .{ .w = 400, .h = 300 });
    const r = try waitFor(p, .resize);
    try t.expectEqual(@as(i32, 400), r.resize.size.w);
    try t.expectEqual(@as(i32, 300), r.resize.size.h);
    try target.draw(target.ctx, &f);

    // The close button asks the core, and the window stays.
    const w: *appkit.Win = @ptrCast(@alignCast(win.impl.?));
    objc.call(fn (objc.Id, objc.Sel, ?objc.Id) callconv(.c) void, w.ns_window, "performClose:", .{null});
    _ = try waitFor(p, .close);

    p.destroyWindow(win);
    destroyed = true;
}
