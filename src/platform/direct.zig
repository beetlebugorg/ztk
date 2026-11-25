//! The direct backend: the display of a Linux device with no display
//! server. The output is the kernel framebuffer, drawn with the CPU
//! renderer; the rows that changed go to the panel through `Fbdev`. The
//! input comes from the event devices (`Input`). The framebuffer has no
//! frame signal, so `requestFrame` gives a `frame` event 16 666
//! microseconds after the last one, and the wait of the backend is the
//! timer. With no request, no timer runs. One window exists. It has the
//! display size after the rotation, divided by the scale. The Vulkan
//! output on a display (`VK_KHR_display`) is not part of this file: see
//! docs/dev/tasks/BLOCKED.md.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const geom = @import("../geom.zig");
const event = @import("../event.zig");
const plat = @import("platform.zig");
const sys = @import("../sys/linux.zig");
const fbdev = @import("fbdev.zig");
const console = @import("console.zig");
const num = @import("../num.zig");
const evdev = @import("evdev.zig");
const cpu = @import("../render/cpu.zig");
const Image = @import("../render/renderer.zig").Image;
const Frame = @import("../scene.zig").Frame;
const Target = @import("../render/thread.zig").Target;
const Atlas = @import("../text/atlas.zig").Atlas;
const Platform = plat.Platform;
const Window = plat.Window;
const Event = event.Event;

pub const Output = enum { auto, vulkan, framebuffer };
pub const Rotation = fbdev.Rotation;

pub const Options = struct {
    output: Output = .auto,
    fb_device: []const u8 = "/dev/fb0",
    rotation: ?Rotation = null,
    scale: f32 = 1,
    /// The input devices. Empty: find them in /dev/input.
    input: []const []const u8 = &.{},
    touch_debounce_ms: u32 = 0,
    /// The variables of the environment that name a display server. `init` refuses to run when one is set.
    session: console.Session = .{},
    /// The VT to use. Null: the terminal of the standard input.
    tty: ?[]const u8 = null,
    /// The system calls for the console. A test gives a fake.
    host: *const console.Host = &console.real_host,
    /// The system calls for the framebuffer. A test gives a fake.
    fb_host: *const fbdev.Host = &fbdev.real_host,
    /// `init` runs only with this flag. ztk does not own the VT yet: it has
    /// no `KDSKBMODE`, termios, or `VT_SETMODE` handling, and no VT switch.
    unsafe_test_device: bool = false,
};

const frame_us: i64 = 16_666;

pub const Direct = struct {
    gpa: std.mem.Allocator,
    fb: *fbdev.Fbdev,
    input: evdev.Input,
    console: console.Console = .{},
    window: ?*Window = null,
    scale: f32,
    events: std.ArrayListUnmanaged(Event) = .empty,
    frame_wanted: bool = false,
    last_frame_us: i64 = std.math.minInt(i64) / 2,
    /// The pieces that the render thread owns.
    atlas: Atlas,
    image: ?Image = null,
    /// The picture at the size of the panel, when the scene has another size.
    panel: ?Image = null,
    /// The rows that the last present wrote, and the sum for the statistics.
    last_rows: u32 = 0,
    rows_sum: u64 = 0,
    frames: u64 = 0,
    /// The pointer for the overlay of a mouse, in device pixels.
    ptr_x: std.atomic.Value(i32) = .init(-1),
    ptr_y: std.atomic.Value(i32) = .init(-1),
    touch_only: bool = true,
    memory_mode: bool = false,

    /// Checks that no display server or other VT owns the display, and then opens
    /// the framebuffer and the input devices. It fails closed: the checks run before
    /// any device of the framebuffer or of the input opens. No test calls it with the real host.
    pub fn init(gpa: std.mem.Allocator, opts: Options) !*Direct {
        if (!opts.unsafe_test_device) return error.DirectNotEnabled;
        if (opts.output == .vulkan) return error.VulkanOutputNotAvailable;
        var con: console.Console = .{ .host = opts.host };
        try con.prepare(opts.session, opts.tty);
        const fb = fbdev.Fbdev.open(gpa, opts.fb_device, opts.rotation, opts.fb_host) catch |e| {
            con.text();
            return e;
        };
        return finish(gpa, fb, con, opts);
    }

    /// Like `init`, on a framebuffer that the caller opened. The tests use it with a
    /// framebuffer in memory and a fake console. On an error the framebuffer is closed.
    pub fn initOn(gpa: std.mem.Allocator, fb: *fbdev.Fbdev, opts: Options) !*Direct {
        var con: console.Console = .{ .host = opts.host };
        con.prepare(opts.session, opts.tty) catch |e| {
            fb.close();
            return e;
        };
        return finish(gpa, fb, con, opts);
    }

    fn finish(gpa: std.mem.Allocator, fb: *fbdev.Fbdev, con: console.Console, opts: Options) !*Direct {
        var c = con;
        const d = create(gpa, fb, opts) catch |e| {
            fb.close();
            c.text();
            return e;
        };
        // The backend owns the console, the framebuffer, and the input now. `deinit` frees them.
        d.console = c;
        errdefer d.deinit();
        if (opts.input.len == 0) {
            try d.input.discover();
        } else for (opts.input) |path| {
            const fd = try sys.open(path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true });
            d.input.addFd(fd, .keyboard, null) catch |e| {
                _ = std.os.linux.close(fd);
                return e;
            };
        }
        // A failed mode change stops here, before the first frame.
        try d.console.graphics();
        return d;
    }

    /// For tests: a backend on a framebuffer in memory with no device.
    pub fn initMemory(gpa: std.mem.Allocator, fb: *fbdev.Fbdev, opts: Options) !*Direct {
        const d = try create(gpa, fb, opts);
        d.memory_mode = true;
        return d;
    }

    fn create(gpa: std.mem.Allocator, fb: *fbdev.Fbdev, opts: Options) !*Direct {
        if (!(opts.scale >= 0.25 and opts.scale <= 16)) return error.BadScale;
        const d = try gpa.create(Direct);
        errdefer gpa.destroy(d);
        const size = fb.imageSize();
        const logical: geom.Size = .{
            .w = @max(num.pxRound(@as(f64, @floatFromInt(size[0])) / opts.scale), 1),
            .h = @max(num.pxRound(@as(f64, @floatFromInt(size[1])) / opts.scale), 1),
        };
        d.* = .{
            .gpa = gpa,
            .fb = fb,
            .input = evdev.Input.init(gpa, .{ .rotation = fb.rotation, .debounce_ms = opts.touch_debounce_ms }, logical),
            .scale = opts.scale,
            .atlas = Atlas.init(gpa),
        };
        return d;
    }

    pub fn deinit(d: *Direct) void {
        d.console.text();
        d.input.deinit();
        d.events.deinit(d.gpa);
        if (d.image) |im| d.gpa.free(im.pixels);
        if (d.panel) |im| d.gpa.free(im.pixels);
        d.atlas.deinit();
        d.fb.close();
        d.gpa.destroy(d);
    }

    /// "vulkan" or "framebuffer", for the log and the statistics.
    pub fn outputName(_: *const Direct) []const u8 {
        return "framebuffer";
    }

    pub fn platform(d: *Direct) Platform {
        return .{ .ptr = d, .vtable = &vtable, .live = true, .thread_safe_draw = true };
    }

    const vtable: Platform.VTable = .{
        .deinit = vDeinit,
        .createWindow = vCreateWindow,
        .destroyWindow = vDestroyWindow,
        .setTitle = vSetTitle,
        .requestSize = vRequestSize,
        .setMinSize = vSetMinSize,
        .requestFrame = vRequestFrame,
        .wait = vWait,
        .poll = vPoll,
        .nowUs = vNowUs,
        .target = vTarget,
    };

    fn self(ptr: *anyopaque) *Direct {
        return @ptrCast(@alignCast(ptr));
    }

    fn vDeinit(ptr: *anyopaque) void {
        self(ptr).deinit();
    }

    fn vCreateWindow(ptr: *anyopaque, _: plat.WindowOptions) anyerror!*Window {
        const d = self(ptr);
        if (d.window != null) return error.OnlyOneWindow;
        const w = try d.gpa.create(Window);
        w.* = .{ .size = d.input.size, .scale = d.scale };
        d.window = w;
        return w;
    }

    fn vDestroyWindow(ptr: *anyopaque, w: *Window) void {
        const d = self(ptr);
        if (d.window == w) d.window = null;
        d.gpa.destroy(w);
    }

    fn vSetTitle(_: *anyopaque, _: *Window, _: []const u8) void {}
    fn vSetMinSize(_: *anyopaque, _: *Window, _: geom.Size) void {}
    /// The window has the size of the display, so a request changes nothing.
    fn vRequestSize(_: *anyopaque, _: *Window, _: geom.Size) void {}

    fn vNowUs(_: *anyopaque) i64 {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
        return @as(i64, ts.sec) * 1_000_000 + @divFloor(@as(i64, ts.nsec), 1000);
    }

    fn nowMs() u64 {
        return @intCast(@max(@divFloor(vNowUs(undefined), 1000), 0));
    }

    fn vRequestFrame(ptr: *anyopaque, _: *Window) void {
        self(ptr).frame_wanted = true;
    }

    fn untilFrameUs(d: *const Direct) ?i64 {
        if (!d.frame_wanted) return null;
        return @max(d.last_frame_us + frame_us - vNowUs(undefined), 0);
    }

    fn vWait(ptr: *anyopaque, timeout_us: ?i64) void {
        const d = self(ptr);
        var limit = timeout_us;
        if (d.untilFrameUs()) |u| limit = if (limit) |l| @min(l, u) else u;
        if (d.input.nextDueMs()) |due| {
            const left: i64 = @intCast(@min(due -| nowMs(), std.math.maxInt(i32)) * 1000);
            limit = if (limit) |l| @min(l, left) else left;
        }
        if (d.events.items.len > 0) return;
        var fds: evdev.PollSet = undefined;
        const set = d.input.pollFds(&fds);
        const ms: i32 = if (limit) |l| @intCast(@min(@divFloor(l +| 999, 1000), std.math.maxInt(i32))) else -1;
        _ = std.posix.poll(set, ms) catch {};
    }

    fn vPoll(ptr: *anyopaque, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(Event)) anyerror!void {
        const d = self(ptr);
        const win = d.window orelse return;
        try d.input.read(nowMs(), &d.events, win);
        try d.input.tick(nowMs(), &d.events, win);
        if (d.input.has_mouse) {
            d.ptr_x.store(num.pxFloor(@as(f64, d.input.px) * d.scale), .monotonic);
            d.ptr_y.store(num.pxFloor(@as(f64, d.input.py) * d.scale), .monotonic);
        }
        if (d.frame_wanted and vNowUs(undefined) >= d.last_frame_us + frame_us) {
            d.frame_wanted = false;
            d.last_frame_us = vNowUs(undefined);
            try d.events.append(d.gpa, .{ .frame = .{ .window = win, .time_us = d.last_frame_us } });
        }
        try out.appendSlice(gpa, d.events.items);
        d.events.clearRetainingCapacity();
    }

    fn vTarget(ptr: *anyopaque, _: *Window) Target {
        return .{ .ctx = self(ptr), .draw = drawFrame };
    }

    /// Draws a pointer of 10 by 16 pixels: a white arrow with a black edge.
    fn drawPointer(img: Image, x0: i32, y0: i32) void {
        var row: i32 = 0;
        while (row < 16) : (row += 1) {
            const half = @divTrunc(@min(row, 10) * 10, 16) + 1;
            var col: i32 = 0;
            while (col < half + 1) : (col += 1) {
                const x = x0 + col;
                const y = y0 + row;
                if (x < 0 or y < 0 or x >= img.width or y >= img.height) continue;
                const edge = col == 0 or col == half or row == 15;
                const v: u8 = if (edge) 0 else 255;
                const p = img.pixels[(@as(usize, @intCast(y)) * img.width + @as(usize, @intCast(x))) * 4 ..][0..3];
                p[0] = v;
                p[1] = v;
                p[2] = v;
            }
        }
    }

    /// Copies the scene image into a black image of the panel size.
    fn fitToPanel(d: *Direct, size: [2]u32) !Image {
        const need = @as(usize, size[0]) * size[1] * 4;
        if (d.panel == null or d.panel.?.pixels.len != need or d.panel.?.width != size[0]) {
            if (d.panel) |im| d.gpa.free(im.pixels);
            d.panel = null;
            d.panel = .{ .width = size[0], .height = size[1], .pixels = try d.gpa.alloc(u8, need) };
        }
        const dst = d.panel.?;
        const src = d.image.?;
        @memset(dst.pixels, 0);
        const w = @min(src.width, dst.width);
        const h = @min(src.height, dst.height);
        var y: usize = 0;
        while (y < h) : (y += 1) {
            @memcpy(dst.pixels[y * dst.width * 4 ..][0 .. w * 4], src.pixels[y * src.width * 4 ..][0 .. w * 4]);
        }
        return dst;
    }

    /// Runs on the render thread: applies the atlas patches, draws the scene with the CPU
    /// renderer, and writes the changed rows to the panel.
    fn drawFrame(ctx: *anyopaque, frame: *const Frame) anyerror!void {
        const d: *Direct = @ptrCast(@alignCast(ctx));
        for (frame.patches.items) |p| try d.atlas.applyPatch(p);
        const s = &frame.scene;
        const need = @as(usize, s.width) * s.height * 4;
        if (d.image == null or d.image.?.pixels.len != need or d.image.?.width != s.width) {
            if (d.image) |im| d.gpa.free(im.pixels);
            d.image = null;
            d.image = .{ .width = s.width, .height = s.height, .pixels = try d.gpa.alloc(u8, need) };
        }
        const size = d.fb.imageSize();
        cpu.render(s, &d.atlas, &d.image.?);
        const px = d.ptr_x.load(.monotonic);
        if (px >= 0) drawPointer(d.image.?, px, d.ptr_y.load(.monotonic));
        // A scene of another size (a scale that does not divide the panel) is cut or padded with black.
        var shown = d.image.?;
        if (s.width != size[0] or s.height != size[1]) shown = try d.fitToPanel(size);
        d.last_rows = d.fb.present(shown);
        d.rows_sum += d.last_rows;
        d.frames += 1;
    }
};

test "direct: the options have the defaults of the task" {
    const o: Options = .{};
    try std.testing.expectEqual(Output.auto, o.output);
    try std.testing.expectEqualStrings("/dev/fb0", o.fb_device);
}
