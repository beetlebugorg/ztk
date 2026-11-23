//! Tests of the direct backend on a framebuffer in memory and on pipes in
//! place of the input devices. No test opens a real display or a real
//! input device.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const App = @import("../app.zig").App;
const direct = @import("../platform/direct.zig");
const fbdev = @import("../platform/fbdev.zig");
const sys = @import("../sys/linux.zig");
const cpu = @import("../render/cpu.zig");
const Image = @import("../render/renderer.zig").Image;
const build_options = @import("build_options");
const t = std.testing;

const World = struct {
    it: ztcl.Interp,
    mem: []u8,
    fb: *fbdev.Fbdev,
    be: *direct.Direct,
    app: *App,
    pipe_kbd: [2]i32,
    pipe_touch: [2]i32,

    fn init(w: *World) !void {
        const pw: u32 = 480;
        const ph: u32 = 800;
        w.mem = try t.allocator.alloc(u8, pw * ph * 4);
        @memset(w.mem, 0);
        w.fb = try fbdev.Fbdev.initMemory(t.allocator, w.mem, pw, ph, pw * 4, .xrgb8888, .r0);
        w.be = try direct.Direct.initMemory(t.allocator, w.fb, .{});
        w.pipe_kbd = try sys.pipeNonblocking();
        w.pipe_touch = try sys.pipeNonblocking();
        try w.be.input.addFd(w.pipe_kbd[0], .keyboard, null);
        try w.be.input.addFd(w.pipe_touch[0], .touch, .{ .{ .min = 0, .max = 479 }, .{ .min = 0, .max = 799 } });
        try w.it.init(t.allocator);
        var dir: [512]u8 = undefined;
        const root = try std.fmt.bufPrint(&dir, "{s}/examples", .{build_options.repo_root});
        w.app = try App.init(t.allocator, &w.it, .{ .platform = w.be.platform(), .io = t.io, .animations = false, .style_root = root });
        var path: [512]u8 = undefined;
        const demo = try std.fmt.bufPrint(&path, "{s}/examples/demo.tcl", .{build_options.repo_root});
        const text = try std.Io.Dir.cwd().readFileAlloc(t.io, demo, t.allocator, .limited(1 << 20));
        defer t.allocator.free(text);
        _ = try w.it.eval(text);
        _ = try w.it.eval("update");
    }

    fn deinit(w: *World) void {
        w.app.deinit();
        w.be.deinit();
        w.it.deinit();
        for (w.pipe_kbd) |fd| _ = std.os.linux.close(fd);
        for (w.pipe_touch) |fd| _ = std.os.linux.close(fd);
        t.allocator.free(w.mem);
    }

    fn eval(w: *World, text: []const u8) ![]const u8 {
        const v = try w.it.eval(text);
        return w.it.str(v);
    }

    fn rec(fd: i32, ty: u16, code: u16, value: i32) !void {
        const e: sys.InputEvent = .{ .sec = 0, .usec = 0, .type = ty, .code = code, .value = value };
        try sys.writeAll(fd, std.mem.asBytes(&e));
    }

    fn key(w: *World, code: u16) !void {
        try rec(w.pipe_kbd[1], sys.EV_KEY, code, 1);
        try rec(w.pipe_kbd[1], sys.EV_KEY, code, 0);
    }
};

test "direct: the demo on a memory framebuffer equals the CPU renderer" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const sc = w.app.lastScene();
    try t.expectEqual(@as(u32, 480), sc.width);
    const img: Image = .{ .width = sc.width, .height = sc.height, .pixels = try t.allocator.alloc(u8, w.mem.len) };
    defer t.allocator.free(img.pixels);
    cpu.render(sc, &w.be.atlas, &@constCast(&img).*);
    var i: usize = 0;
    while (i < w.mem.len) : (i += 4) {
        try t.expectEqual(img.pixels[i], w.mem[i + 2]);
        try t.expectEqual(img.pixels[i + 1], w.mem[i + 1]);
        try t.expectEqual(img.pixels[i + 2], w.mem[i]);
    }
}

test "direct: a change of the message writes few rows, and an idle window writes none" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const first = w.be.last_rows;
    try t.expectEqual(@as(u32, 800), first);
    _ = try w.eval("set msg {Hello, Ada!}; update");
    try t.expect(w.be.last_rows > 0);
    try t.expect(w.be.last_rows * 10 < 800);
    const frames = w.be.frames;
    _ = try w.eval("update; update");
    try t.expectEqual(frames, w.be.frames);
}

test "direct: typing Ada and Return through a pipe greets" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    try w.key(30 + 0); // KEY_A needs shift for a capital letter.
    _ = try w.eval("update");
    try t.expectEqualStrings("a", try w.eval("set name"));
    _ = try w.eval(".name delete 0 end");
    try World.rec(w.pipe_kbd[1], sys.EV_KEY, 42, 1);
    try w.key(30);
    try World.rec(w.pipe_kbd[1], sys.EV_KEY, 42, 0);
    try w.key(32); // d
    try w.key(30); // a
    try w.key(28); // Return
    _ = try w.eval("update");
    try t.expectEqualStrings("Hello, Ada!", try w.eval("set msg"));
}

test "direct: a tap on Count through the touch pipe runs its command" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const c = w.app.find(".count").?;
    const x: i32 = c.geom.x + @divTrunc(c.geom.w, 2);
    const y: i32 = c.geom.y + @divTrunc(c.geom.h, 2);
    try World.rec(w.pipe_touch[1], sys.EV_ABS, sys.ABS_X, x);
    try World.rec(w.pipe_touch[1], sys.EV_ABS, sys.ABS_Y, y);
    try World.rec(w.pipe_touch[1], sys.EV_KEY, sys.BTN_TOUCH, 1);
    try World.rec(w.pipe_touch[1], sys.EV_SYN, sys.SYN_REPORT, 0);
    try World.rec(w.pipe_touch[1], sys.EV_KEY, sys.BTN_TOUCH, 0);
    try World.rec(w.pipe_touch[1], sys.EV_SYN, sys.SYN_REPORT, 0);
    _ = try w.eval("update");
    try t.expectEqualStrings("Clicks: 1", try w.eval("set msg"));
}

// ---- The console and the failure paths. A fake host stands in for the terminal. ----

const console = @import("../platform/console.zig");

const FakeVt = struct {
    opened: u32 = 0,
    closed: u32 = 0,
    mode: u32 = sys.KD_TEXT,
    sets: u32 = 0,
    /// True: a change to graphics mode fails.
    refuse_graphics: bool = false,

    fn host(f: *FakeVt) console.Host {
        return .{ .ctx = f, .activeVt = active, .ownTty = own, .open = open, .getMode = getMode, .setMode = setMode, .close = close };
    }
    fn me(ctx: ?*anyopaque) *FakeVt {
        return @ptrCast(@alignCast(ctx.?));
    }
    fn active(_: ?*anyopaque, buf: []u8) ?[]const u8 {
        @memcpy(buf[0..4], "tty2");
        return buf[0..4];
    }
    fn own(_: ?*anyopaque, buf: []u8) ?[]const u8 {
        @memcpy(buf[0..9], "/dev/tty2");
        return buf[0..9];
    }
    fn open(ctx: ?*anyopaque, _: []const u8) ?i32 {
        me(ctx).opened += 1;
        return 42;
    }
    fn getMode(ctx: ?*anyopaque, _: i32) ?u32 {
        return me(ctx).mode;
    }
    fn setMode(ctx: ?*anyopaque, _: i32, mode: u32) bool {
        const f = me(ctx);
        if (mode == sys.KD_GRAPHICS and f.refuse_graphics) return false;
        f.mode = mode;
        f.sets += 1;
        return true;
    }
    fn close(ctx: ?*anyopaque, _: i32) void {
        me(ctx).closed += 1;
    }
};

fn memFb(mem: []u8) !*fbdev.Fbdev {
    return fbdev.Fbdev.initMemory(t.allocator, mem, 64, 32, 256, .xrgb8888, .r0);
}

test "direct: a display server stops init before it opens the console or the input" {
    var vt: FakeVt = .{};
    const host = vt.host();
    const mem = try t.allocator.alloc(u8, 256 * 32);
    defer t.allocator.free(mem);
    const fb = try memFb(mem);
    const e = direct.Direct.initOn(t.allocator, fb, .{ .host = &host, .session = .{ .wayland_display = "wayland-0" }, .input = &.{"/dev/null"} });
    try t.expectError(error.DisplayServerRunning, e);
    try t.expectEqual(@as(u32, 0), vt.opened);
    try t.expectEqual(@as(u32, 0), vt.sets);
}

test "direct: a failed input open frees the framebuffer once and gives the console back" {
    var vt: FakeVt = .{};
    const host = vt.host();
    const mem = try t.allocator.alloc(u8, 256 * 32);
    defer t.allocator.free(mem);
    const fb = try memFb(mem);
    // The testing allocator reports a double free of the framebuffer, and a leak.
    const e = direct.Direct.initOn(t.allocator, fb, .{ .host = &host, .input = &.{"/nonexistent/event0"} });
    try t.expectError(error.OpenFailed, e);
    try t.expectEqual(vt.opened, vt.closed);
    try t.expectEqual(sys.KD_TEXT, vt.mode);
    try t.expectEqual(@as(u32, 0), vt.sets);
}

test "direct: init puts the console in graphics mode and deinit gives it back" {
    var vt: FakeVt = .{};
    const host = vt.host();
    const mem = try t.allocator.alloc(u8, 256 * 32);
    defer t.allocator.free(mem);
    const fb = try memFb(mem);
    const d = try direct.Direct.initOn(t.allocator, fb, .{ .host = &host, .input = &.{"/dev/null"} });
    try t.expectEqual(sys.KD_GRAPHICS, vt.mode);
    d.deinit();
    try t.expectEqual(sys.KD_TEXT, vt.mode);
    try t.expectEqual(vt.opened, vt.closed);
}

test "direct M-D: a failed KDSETMODE stops init before any drawing" {
    var vt: FakeVt = .{ .refuse_graphics = true };
    const host = vt.host();
    const mem = try t.allocator.alloc(u8, 256 * 32);
    defer t.allocator.free(mem);
    @memset(mem, 0x5a);
    const fb = try memFb(mem);
    const e = direct.Direct.initOn(t.allocator, fb, .{ .host = &host, .input = &.{"/dev/null"} });
    // A backend that started must go away, so that its signal handlers do not stay.
    if (e) |d| {
        d.deinit();
        return error.TestUnexpectedResult;
    } else |err| try t.expectEqual(error.CannotSetGraphicsMode, err);
    try t.expectEqual(sys.KD_TEXT, vt.mode);
    try t.expectEqual(@as(u32, 0), vt.sets);
    try t.expectEqual(vt.opened, vt.closed);
    for (mem) |b| try t.expectEqual(@as(u8, 0x5a), b);
}

test "direct: init without the test device flag touches no device" {
    var vt: FakeVt = .{};
    const host = vt.host();
    // The path does not exist. The flag check runs before any use of it.
    try t.expectError(error.DirectNotEnabled, direct.Direct.init(t.allocator, .{ .host = &host, .fb_device = "/nonexistent/fb", .input = &.{"/nonexistent/event0"} }));
    try t.expectEqual(@as(u32, 0), vt.opened);
    try t.expectEqual(@as(u32, 0), vt.sets);
}

test "direct: init takes the panel from the framebuffer host, with no real device" {
    var vt: FakeVt = .{};
    const host = vt.host();
    var mem: [64 * 4 * 32]u8 = @splat(0);
    var fake: FbFake = .{ .mem = &mem };
    const fb_host = fake.host();
    const d = try direct.Direct.init(t.allocator, .{ .host = &host, .fb_host = &fb_host, .fb_device = "/fake/fb0", .rotation = .r0, .input = &.{"/dev/null"}, .unsafe_test_device = true });
    try t.expectEqual(@as(u32, 64), d.fb.width);
    try t.expectEqual(@as(u32, 32), d.fb.height);
    d.deinit();
    try t.expectEqual(@as(u32, 1), fake.unmaps);
    try t.expectEqual(sys.KD_TEXT, vt.mode);
}

const FbFake = struct {
    mem: []u8,
    unmaps: u32 = 0,

    fn host(f: *FbFake) fbdev.Host {
        return .{ .ctx = f, .open = open, .varInfo = varInfo, .fixInfo = fixInfo, .map = map, .unmap = unmap, .close = close };
    }
    fn me(c: ?*anyopaque) *FbFake {
        return @ptrCast(@alignCast(c.?));
    }
    fn open(_: ?*anyopaque, _: []const u8) ?i32 {
        return 9;
    }
    fn varInfo(_: ?*anyopaque, _: i32, out: *fbdev.VarInfo) bool {
        out.* = .{ .xres = 64, .yres = 32, .xres_virtual = 64, .yres_virtual = 64, .bits_per_pixel = 32, .red = .{ .offset = 16, .length = 8, .msb_right = 0 }, .green = .{ .offset = 8, .length = 8, .msb_right = 0 }, .blue = .{ .offset = 0, .length = 8, .msb_right = 0 } };
        return true;
    }
    fn fixInfo(c: ?*anyopaque, _: i32, out: *fbdev.FixInfo) bool {
        out.* = .{ .line_length = 256, .smem_len = @intCast(me(c).mem.len) };
        return true;
    }
    fn map(c: ?*anyopaque, _: i32, len: usize) ?[]u8 {
        return me(c).mem[0..len];
    }
    fn unmap(c: ?*anyopaque, _: []u8) void {
        me(c).unmaps += 1;
    }
    fn close(_: ?*anyopaque, _: i32) void {}
};

test "direct: a failed add of an input device closes its descriptor" {
    var vt: FakeVt = .{};
    const host = vt.host();
    const mem = try t.allocator.alloc(u8, 256 * 32);
    defer t.allocator.free(mem);
    const probe = try sys.open("/dev/null", .{ .ACCMODE = .RDONLY });
    _ = std.os.linux.close(probe);
    var index: usize = 0;
    while (index < 16) : (index += 1) {
        const fb = try memFb(mem);
        var failing = std.testing.FailingAllocator.init(t.allocator, .{ .fail_index = index });
        if (direct.Direct.initOn(failing.allocator(), fb, .{ .host = &host, .input = &.{"/dev/null"} })) |d| {
            d.deinit();
            break;
        } else |_| {}
        const next = try sys.open("/dev/null", .{ .ACCMODE = .RDONLY });
        _ = std.os.linux.close(next);
        try t.expectEqual(probe, next);
    }
}

test "direct: a bad scale is an error and the framebuffer is closed" {
    var vt: FakeVt = .{};
    const host = vt.host();
    const mem = try t.allocator.alloc(u8, 256 * 32);
    defer t.allocator.free(mem);
    const fb = try memFb(mem);
    try t.expectError(error.BadScale, direct.Direct.initOn(t.allocator, fb, .{ .host = &host, .scale = 0, .input = &.{"/dev/null"} }));
    const fb2 = try memFb(mem);
    try t.expectError(error.BadScale, direct.Direct.initOn(t.allocator, fb2, .{ .host = &host, .scale = std.math.nan(f32), .input = &.{"/dev/null"} }));
}

test "direct: a scene of another size than the panel still shows" {
    var it: ztcl.Interp = undefined;
    try it.init(t.allocator);
    defer it.deinit();
    // 481 by 799 pixels at scale 2 gives a window of 241 by 400, so the scene is 482 by 800.
    const mem = try t.allocator.alloc(u8, 481 * 799 * 4);
    defer t.allocator.free(mem);
    @memset(mem, 0);
    const fb = try fbdev.Fbdev.initMemory(t.allocator, mem, 481, 799, 481 * 4, .xrgb8888, .r0);
    const be = try direct.Direct.initMemory(t.allocator, fb, .{ .scale = 2 });
    defer be.deinit();
    const app = try App.init(t.allocator, &it, .{ .platform = be.platform(), .io = t.io, .animations = false });
    defer app.deinit();
    _ = try it.eval("label .l -text hello -background #ff0000; grid .l -sticky nsew; grid columnconfigure . 0 -weight 1; grid rowconfigure . 0 -weight 1; update");
    try t.expect(be.frames > 0);
    var red: usize = 0;
    var i: usize = 0;
    while (i < mem.len) : (i += 4) {
        if (mem[i + 2] > 200 and mem[i + 1] < 50) red += 1;
    }
    try t.expect(red > 1000);
}
