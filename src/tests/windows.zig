//! Tests of the Win32 backend. They run only with `ZTK_TEST_WINDOWS=1`,
//! which CI sets, and print `SKIP:` otherwise. Each window is hidden
//! (`visible = false`), so no window shows on the desktop. The tests send
//! messages to the window procedure with `SendMessageW` and read the
//! events of `poll`. The App tests draw a label with the CPU output and
//! with Direct3D 12 into the swapchain of a hidden window.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const w32 = @import("../platform/win32.zig");
const be = @import("../platform/windows.zig");
const App = @import("../app.zig").App;
const Event = @import("../event.zig").Event;
const host = @import("../sys/host.zig");
const t = std.testing;

fn enabled() bool {
    if (t.environ.contains(t.allocator, "ZTK_TEST_WINDOWS") catch false) return true;
    std.debug.print("SKIP: set ZTK_TEST_WINDOWS=1 to run the Win32 backend tests\n", .{});
    return false;
}

fn pollAll(b: *be.Win32, out: *std.ArrayListUnmanaged(Event)) !void {
    out.clearRetainingCapacity();
    try b.platform().poll(t.allocator, out);
}

fn has(events: []const Event, comptime tag: std.meta.Tag(Event)) ?Event {
    for (events) |e| if (e == tag) return e;
    return null;
}

test "windows: messages become resize, scale, close, and focus events" {
    if (!enabled()) return;
    const b = try be.Win32.init(t.allocator, .{ .visible = false, .renderer = .cpu });
    defer b.deinit();
    const p = b.platform();
    const w = try p.createWindow(.{ .title = "ztk test", .size = .{ .w = 200, .h = 100 } });
    const hwnd = b.hwndOf(w).?;
    var events: std.ArrayListUnmanaged(Event) = .empty;
    defer events.deinit(t.allocator);
    try pollAll(b, &events);

    // The client area has the logical size times the scale.
    var r: w32.RECT = .{};
    _ = w32.GetClientRect(hwnd, &r);
    try t.expectEqual(@as(i32, @intFromFloat(@round(200 * w.scale))), r.right);
    try t.expectEqual(@as(i32, @intFromFloat(@round(100 * w.scale))), r.bottom);

    const pw: u32 = @intFromFloat(@round(400 * w.scale));
    const ph: u32 = @intFromFloat(@round(300 * w.scale));
    _ = w32.SendMessageW(hwnd, w32.WM_SIZE, 0, @intCast((ph << 16) | pw));
    try pollAll(b, &events);
    const rs = has(events.items, .resize) orelse return error.NoResize;
    try t.expectEqual(@as(i32, 400), rs.resize.size.w);
    try t.expectEqual(@as(i32, 300), rs.resize.size.h);

    _ = w32.SendMessageW(hwnd, w32.WM_CLOSE, 0, 0);
    try pollAll(b, &events);
    try t.expect(has(events.items, .close) != null);
    // The window stays after a close request.
    try t.expect(b.hwndOf(w) != null);

    var suggested: w32.RECT = .{ .left = 10, .top = 10, .right = 810, .bottom = 610 };
    _ = w32.SendMessageW(hwnd, w32.WM_DPICHANGED, (192 << 16) | 192, @bitCast(@intFromPtr(&suggested)));
    try pollAll(b, &events);
    const sc = has(events.items, .scale) orelse return error.NoScale;
    try t.expectEqual(@as(f32, 2), sc.scale.scale);
    try t.expectEqual(@as(f32, 2), w.scale);

    _ = w32.SendMessageW(hwnd, w32.WM_SETFOCUS, 0, 0);
    _ = w32.SendMessageW(hwnd, w32.WM_KILLFOCUS, 0, 0);
    try pollAll(b, &events);
    var focus_in = false;
    var focus_out = false;
    for (events.items) |e| if (e == .focus) {
        if (e.focus.focused) focus_in = true else focus_out = true;
    };
    try t.expect(focus_in and focus_out);
}

test "windows: a frame request gives one frame event at the next tick" {
    if (!enabled()) return;
    const b = try be.Win32.init(t.allocator, .{ .visible = false, .renderer = .cpu });
    defer b.deinit();
    const p = b.platform();
    const w = try p.createWindow(.{ .size = .{ .w = 50, .h = 50 } });
    var events: std.ArrayListUnmanaged(Event) = .empty;
    defer events.deinit(t.allocator);
    try pollAll(b, &events);
    const t0 = host.nowUs();
    p.requestFrame(w);
    var frames: u32 = 0;
    while (host.nowUs() - t0 < 200_000 and frames == 0) {
        p.wait(50_000);
        try pollAll(b, &events);
        for (events.items) |e| if (e == .frame) {
            frames += 1;
        };
    }
    try t.expectEqual(@as(u32, 1), frames);
    // A second request after the tick gives one more frame.
    p.requestFrame(w);
    frames = 0;
    const t1 = host.nowUs();
    while (host.nowUs() - t1 < 200_000 and frames == 0) {
        p.wait(50_000);
        try pollAll(b, &events);
        for (events.items) |e| if (e == .frame) {
            frames += 1;
        };
    }
    try t.expectEqual(@as(u32, 1), frames);
}

fn drawLabel(renderer: be.Renderer) !?u32 {
    const b = be.Win32.init(t.allocator, .{ .visible = false, .renderer = renderer }) catch |e| {
        std.debug.print("SKIP: no Win32 backend ({s})\n", .{@errorName(e)});
        return null;
    };
    defer b.deinit();
    var it: ztcl.Interp = undefined;
    try it.init(t.allocator);
    defer it.deinit();
    const app = App.init(t.allocator, &it, .{
        .platform = b.platform(),
        .io = t.io,
        .render_mode = .threaded,
        .animations = false,
    }) catch |e| {
        std.debug.print("SKIP: no window with the {s} output ({s})\n", .{ @tagName(renderer), @errorName(e) });
        return null;
    };
    defer app.deinit();
    _ = try it.eval("label .l -text {Hello from Win32}; pack .l; update");
    app.render.flush();
    std.debug.print("windows: output {s}\n", .{b.outputName(app.window.?)});
    return if (renderer == .cpu) b.cpu_frames.load(.monotonic) else b.gpu_frames.load(.monotonic);
}

test "windows: the App draws a label with the CPU output" {
    if (!enabled()) return;
    const n = try drawLabel(.cpu) orelse return;
    try t.expect(n >= 1);
}

test "windows: the App draws a label with Direct3D 12 into a swapchain" {
    if (!enabled()) return;
    const n = try drawLabel(.d3d12) orelse return;
    try t.expect(n >= 1);
}
