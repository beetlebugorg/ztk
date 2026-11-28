//! The test harness: an interpreter and an App on the testing allocator.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const App = @import("app.zig").App;
const Headless = @import("platform/headless.zig").Headless;
const Window = @import("platform/platform.zig").Window;
const Io = std.Io;
const build_options = @import("build_options");
const png = @import("base/png.zig");
const Image = @import("render/renderer.zig").Image;
const Scene = @import("scene.zig").Scene;

/// Ends the test process when a test runs too long, so a hang is a quick
/// failure. The test does not wait for this thread's clock.
pub const Watchdog = struct {
    done: std.atomic.Value(bool) = .init(false),
    limit_ms: u32 = 0,
    thread: std.Thread = undefined,

    pub fn start(d: *Watchdog, limit_ms: u32) !void {
        d.* = .{ .limit_ms = limit_ms };
        d.thread = try std.Thread.spawn(.{}, run, .{d});
    }

    pub fn stop(d: *Watchdog) void {
        d.done.store(true, .release);
        d.thread.join();
    }

    fn run(d: *Watchdog) void {
        var waited: u32 = 0;
        while (!d.done.load(.acquire)) : (waited += 5) {
            if (waited >= d.limit_ms) @panic("test watchdog: the test ran past its limit");
            @import("sys/host.zig").sleepUs(5000);
        }
    }
};

pub const Harness = struct {
    it: ztcl.Interp,
    app: *App,
    head: *Headless,
    /// The window of ".".
    win: *Window,
    /// How the harness draws. A test sets it before `init`.
    render_mode: @import("render/thread.zig").Mode = .inline_draw,
    /// True: transitions run. Most tests turn them off, so a frame shows the end state.
    animations: bool = false,
    /// True: the dark color scheme.
    dark: bool = false,
    /// The text that the error output got.
    err: std.ArrayListUnmanaged(u8) = .empty,

    /// The harness must not move after `init`.
    pub fn init(h: *Harness) !void {
        h.render_mode = .inline_draw;
        h.animations = false;
        h.dark = false;
        return h.initWith(null);
    }

    /// Like `init`, with the folder `examples/` as the root of `ztk::style load`.
    pub fn initExamples(h: *Harness, dark: bool) !void {
        h.render_mode = .inline_draw;
        h.animations = false;
        h.dark = dark;
        var buf: [512]u8 = undefined;
        const dir = try std.fmt.bufPrint(&buf, "{s}/examples", .{build_options.repo_root});
        return h.initWith(dir);
    }

    /// Reads a file of the repository and runs it. The path is relative to the repository.
    pub fn loadFile(h: *Harness, path: []const u8) !void {
        var buf: [512]u8 = undefined;
        const full = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ build_options.repo_root, path });
        const text = try Io.Dir.cwd().readFileAlloc(std.testing.io, full, std.testing.allocator, .limited(1 << 20));
        defer std.testing.allocator.free(text);
        _ = try h.eval(text);
    }

    /// Like `init`, with transitions on.
    pub fn initAnimated(h: *Harness) !void {
        h.render_mode = .inline_draw;
        h.animations = true;
        h.dark = false;
        return h.initWith(null);
    }

    /// Like `init`, with a render mode.
    pub fn initMode(h: *Harness, mode: @import("render/thread.zig").Mode) !void {
        h.render_mode = mode;
        h.animations = false;
        h.dark = false;
        return h.initWith(null);
    }

    /// Like `init`, with a folder for `ztk::style load`.
    pub fn initWith(h: *Harness, style_root: ?[]const u8) !void {
        return h.initFull(style_root, null, null);
    }

    /// `initWith` with the native look and the text engine of the headless
    /// backend, for a test of a native look.
    pub fn initFull(h: *Harness, style_root: ?[]const u8, look: ?[]const u8, text: ?@import("text/system.zig").System) !void {
        try h.it.init(std.testing.allocator);
        errdefer h.it.deinit();
        // The JIT is off in the tests. The testing allocator records a
        // stack trace for each allocation, and a stack with a frame of
        // JIT code has an address in no module, so std.debug lists the
        // modules again and loads their unwind tables again into its
        // global arena, which keeps all of them: about 1 MB for each
        // allocation under a compiled proc, and 6 GB by the 200th test.
        h.it.disableJit();
        h.err = .empty;
        h.head = try Headless.init(std.testing.allocator);
        h.head.native_look = look;
        h.head.text_system = text;
        errdefer h.head.deinit();
        h.app = try App.init(std.testing.allocator, &h.it, .{
            .render_mode = h.render_mode,
            .dark = h.dark,
            .animations = h.animations,
            .platform = h.head.platform(),
            .err_output = .{ .ctx = h, .write = errWrite },
            .style_root = style_root,
            .io = std.testing.io,
        });
        h.win = h.app.window.?;
    }

    fn errWrite(ctx: ?*anyopaque, bytes: []const u8) void {
        const h: *Harness = @ptrCast(@alignCast(ctx.?));
        h.err.appendSlice(std.testing.allocator, bytes) catch {};
    }

    pub fn deinit(h: *Harness) void {
        h.err.deinit(std.testing.allocator);
        h.app.deinit();
        h.head.deinit();
        h.it.deinit();
    }

    /// Runs the `update` command.
    pub fn update(h: *Harness) !void {
        _ = try h.eval("update");
    }

    /// Evaluates a script and returns the string of the result.
    pub fn eval(h: *Harness, script: []const u8) ![]const u8 {
        const v = try h.it.eval(script);
        return h.it.str(v);
    }

    /// Expects error.TclError and returns the message.
    pub fn evalError(h: *Harness, script: []const u8) ![]const u8 {
        if (h.it.eval(script)) |_| return error.ExpectedError else |e| {
            if (e != error.TclError) return e;
        }
        return h.it.str(h.it.result);
    }
};

pub const Tolerance = struct { max_level: u8 = 0, max_fraction: f32 = 0 };

fn updating() bool {
    return std.testing.environ.contains(std.testing.allocator, "ZTK_UPDATE_GOLDEN") catch false;
}

fn goldenPath(buf: []u8, name: []const u8, suffix: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/tests/golden/{s}{s}", .{ build_options.repo_root, name, suffix });
}

fn writeFile(path: []const u8, data: []const u8) !void {
    try Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = data });
}

fn readFile(path: []const u8) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(64 << 20));
}

/// Compares an image with `tests/golden/<name>.png`. With
/// `ZTK_UPDATE_GOLDEN=1` it writes the file and passes. On a difference
/// it writes `<name>.actual.png` and `<name>.diff.png` and fails.
pub fn expectGolden(name: []const u8, img: Image, tol: Tolerance) !void {
    const gpa = std.testing.allocator;
    var pbuf: [512]u8 = undefined;
    const path = try goldenPath(&pbuf, name, ".png");
    if (updating()) {
        const bytes = try png.encode(gpa, img);
        defer gpa.free(bytes);
        try writeFile(path, bytes);
        return;
    }
    const bytes = readFile(path) catch {
        std.debug.print("missing golden file {s}; set ZTK_UPDATE_GOLDEN=1 to write it\n", .{path});
        return error.MissingGolden;
    };
    defer gpa.free(bytes);
    const want = try png.decode(gpa, bytes);
    defer gpa.free(want.pixels);
    if (want.width != img.width or want.height != img.height) {
        std.debug.print("golden {s}: size {d}x{d}, expected {d}x{d}\n", .{ name, img.width, img.height, want.width, want.height });
        return error.GoldenSize;
    }
    var count: usize = 0;
    var worst: u8 = 0;
    const diff = try gpa.alloc(u8, img.pixels.len);
    defer gpa.free(diff);
    var i: usize = 0;
    while (i < img.pixels.len) : (i += 4) {
        var px_diff: u8 = 0;
        for (0..4) |c| {
            const a = img.pixels[i + c];
            const b = want.pixels[i + c];
            px_diff = @max(px_diff, if (a > b) a - b else b - a);
        }
        worst = @max(worst, px_diff);
        const bad = px_diff > tol.max_level;
        if (bad) count += 1;
        const rgba: [4]u8 = if (px_diff > 0) .{ 255, 0, 0, 255 } else .{ 255, 255, 255, 255 };
        @memcpy(diff[i..][0..4], &rgba);
    }
    const total = img.pixels.len / 4;
    const allowed: usize = @intFromFloat(tol.max_fraction * @as(f32, @floatFromInt(total)));
    if (count <= allowed) return;
    var abuf: [512]u8 = undefined;
    var dbuf: [512]u8 = undefined;
    const apath = try goldenPath(&abuf, name, ".actual.png");
    const dpath = try goldenPath(&dbuf, name, ".diff.png");
    const ab = try png.encode(gpa, img);
    defer gpa.free(ab);
    try writeFile(apath, ab);
    const db = try png.encode(gpa, .{ .width = img.width, .height = img.height, .pixels = diff });
    defer gpa.free(db);
    try writeFile(dpath, db);
    std.debug.print("golden {s}: {d} pixels differ, largest difference {d}; wrote {s}\n", .{ name, count, worst, apath });
    return error.GoldenMismatch;
}

/// Compares the text dump of a scene with `tests/golden/<name>.scene.txt`.
pub fn expectScene(name: []const u8, scene: *const Scene) !void {
    const gpa = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try scene.dump(&out.writer);
    var pbuf: [512]u8 = undefined;
    const path = try goldenPath(&pbuf, name, ".scene.txt");
    if (updating()) return writeFile(path, out.written());
    const want = readFile(path) catch {
        std.debug.print("missing golden file {s}; set ZTK_UPDATE_GOLDEN=1 to write it\n", .{path});
        return error.MissingGolden;
    };
    defer gpa.free(want);
    try std.testing.expectEqualStrings(want, out.written());
}
