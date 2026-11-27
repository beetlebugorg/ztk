//! The `ztk` program. `ztk [flags] script.tcl [arguments]` runs a script
//! in a ztcl interpreter with the Tk commands of ztk. The program turns
//! on no capability of ztcl, so a script has the sandbox of ztcl. It
//! connects to Wayland on Linux and uses AppKit on macOS, or uses the
//! headless backend with `--headless`.
//! After the script it runs the event loop until `.` is deleted, or
//! until the number of frames of `--exit-after-frames` is drawn.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");

/// libghostty-vt logs the sequences that it does not handle, each with a
/// scope of its own. The program writes only the log of the default scope.
pub const std_options: std.Options = .{ .logFn = logFn };

fn logFn(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    if (scope != .default) return;
    std.log.defaultLog(level, scope, format, args);
}
const Io = std.Io;
const ztcl = @import("ztcl");
const ztk = @import("ztk");

const usage =
    \\usage: ztk [flags] script.tcl [arguments]
    \\       ztk bundle -o Name.app [options] main.tcl [files]   (ztk bundle for its options)
    \\  --headless               use the headless backend and the CPU renderer
    \\  --mcp                    run the script headless, then serve the MCP tools of ztk::debug on stdin and stdout
    \\  --cpu                    use the CPU renderer on Wayland
    \\  --exit-after-frames N    exit with status 0 after N frames
    \\  --screenshot FILE.png    with --headless: write the last frame at the exit
    \\  --time MS               with --headless: draw the first frame, then move the clock to MS
    \\  --scale N                with --headless: the scale of the window
    \\  --direct                 needs --direct-unsafe-test-device (the VT is not fully owned yet)
    \\  --direct-unsafe-test-device  with --direct: run on a device that is free to lose its console
    \\  --fb DEVICE              with --direct: the framebuffer (default /dev/fb0)
    \\  --rotate 0|90|180|270    with --direct: the rotation of the panel
    \\  --touch-debounce MS      with --direct: the debounce time of a touch panel
    \\  --tty DEVICE             with --direct: the VT, for example /dev/tty1 (default: the terminal of the input)
    \\  --output NAME            with --direct: auto, vulkan, or framebuffer (vulkan is not available yet)
    \\  --dark                   the dark color scheme
    \\  --windowingsystem NAME   the result of tk windowingsystem: x11, win32, aqua, or ztk
    \\  --allow a,b              more capabilities of ztcl, with the names of the ztcl runner (file and channels are on)
    \\  --root DIR               the folder of the file commands (default: the folder of the script)
    \\  --version
    \\
;

fn write(ctx: ?*anyopaque, bytes: []const u8) void {
    const w: *Io.Writer = @ptrCast(@alignCast(ctx.?));
    w.writeAll(bytes) catch {};
}

fn fail(err: *Io.Writer, comptime fmt: []const u8, args: anytype) noreturn {
    err.print(fmt, args) catch {};
    err.flush() catch {};
    ztk.console.restoreNow();
    std.process.exit(1);
}

/// The panic handler gives the text console back, and then does what Zig does.
/// The MCP server of `--mcp`: one JSON-RPC message on each line of
/// stdin, and each answer on one line of stdout. The procs of
/// `src/library/debug.tcl` answer. The app runs only inside the calls.
fn serveMcp(io: Io, it: *ztcl.Interp, app: *ztk.App, out: *Io.Writer) !void {
    var in_buf: [1 << 20]u8 = undefined;
    var in_r: Io.File.Reader = .init(.stdin(), io, &in_buf);
    const in = &in_r.interface;
    // The trace is on from the start, so ui_ran has the events of each call.
    _ = it.eval("ztk::debug trace start") catch {};
    while (true) {
        const line = in.takeDelimiterExclusive('\n') catch |e| switch (e) {
            error.EndOfStream => return,
            else => return e,
        };
        _ = in.take(1) catch {};
        const call = try ztcl.value.newList(it.alloc(), &.{ .{ .str = "::ztk::priv::dbg::mcp" }, .{ .str = line } });
        const answer = it.eval(try it.str(call)) catch |e| {
            const msg = if (e == error.TclError) it.str(it.result) catch "error" else @errorName(e);
            std.debug.print("ztk: --mcp: {s}\n", .{msg});
            continue;
        };
        const text = try it.str(answer);
        if (text.len > 0) {
            try out.writeAll(text);
            try out.writeAll("\n");
            try out.flush();
        }
        _ = app.maybeCompact();
        if (app.root == null) return;
    }
}

pub const panic = std.debug.FullPanic(onPanic);

fn onPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    ztk.console.restoreNow();
    std.debug.defaultPanic(msg, first_trace_addr);
}

/// The Io of the clock and event hosts of ztcl, set at the start of main.
var host_io: Io = undefined;

fn hostNow(_: ?*anyopaque) i64 {
    const t = Io.Clock.real.now(host_io);
    return @intCast(@divFloor(t.toNanoseconds(), 1000));
}

fn hostTicks(_: ?*anyopaque) i64 {
    const t = Io.Clock.awake.now(host_io);
    return @intCast(@divFloor(t.toNanoseconds(), 1000));
}

fn hostSleep(_: ?*anyopaque, micros: i64) void {
    Io.sleep(host_io, .fromNanoseconds(micros * 1000), .awake) catch {};
}

/// The TZif file of a zone for `clock`, from the zone files of the system.
fn hostZone(_: ?*anyopaque, name: []const u8, a: std.mem.Allocator) ?[]const u8 {
    const path = std.fmt.allocPrint(a, "/usr/share/zoneinfo/{s}", .{name}) catch return null;
    return Io.Dir.cwd().readFileAlloc(host_io, path, a, .limited(1 << 20)) catch null;
}

var exit_out: ?*Io.Writer = null;
var exit_err: ?*Io.Writer = null;

fn flushOutput() void {
    if (exit_out) |o| o.flush() catch {};
}

fn exitNow(code: u8) noreturn {
    if (exit_out) |o| o.flush() catch {};
    if (exit_err) |e| e.flush() catch {};
    // `exit` skips the defers of main, so the console goes back here.
    ztk.console.restoreNow();
    std.process.exit(code);
}

pub fn main(init: std.process.Init) !void {
    // The first thing: the start time, for the time to the first frame.
    const start_us = ztk.loop.system_clock.now(null);
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (comptime builtin.os.tag == .windows) attachConsole();

    var err_buf: [1024]u8 = undefined;
    // Streaming writers: a positional write to a pipe fails on Windows.
    var err_w: Io.File.Writer = .initStreaming(.stderr(), io, &err_buf);
    const err = &err_w.interface;
    var out_buf: [1 << 16]u8 = undefined;
    var out_w: Io.File.Writer = .initStreaming(.stdout(), io, &out_buf);
    const out = &out_w.interface;
    defer out.flush() catch {};
    defer err.flush() catch {};
    exit_out = out;
    exit_err = err;

    var headless = false;
    var mcp = false;
    var dark = false;
    var windowing: ?[]const u8 = null;
    // The file commands and the file channels (open, read, puts to a file)
    // are on by default (decision of the user,
    // 2026-11-26). --allow turns on more.
    var allow_bits: u32 = @backingInt(ztcl.interp.Capability.file) | @backingInt(ztcl.interp.Capability.channels);
    var root_dir: ?[]const u8 = null;
    var hotkeys = false;
    var direct_on = false;
    var direct_opts: ztk.direct.Options = .{};
    var max_frames: ?u64 = null;
    var screenshot: ?[]const u8 = null;
    var time_ms: ?i64 = null;
    var scale: f32 = 1;
    var script: ?[]const u8 = null;
    var rest: []const [:0]const u8 = &.{};
    // A program with an app in its slot (`ztk bundle` with a target) runs
    // the app, reads no flag, and gives each word to the script.
    const own_app = ztk.appbin.own(io, arena) catch |e| fail(err, "ztk: cannot read the app in this program: {s}\n", .{@errorName(e)});
    if (own_app != null) rest = args[1..];
    if (own_app == null and args.len > 1 and std.mem.eql(u8, args[1], "bundle")) {
        const code = ztk.bundle.run(io, arena, args[2..], err) catch |e| fail(err, "ztk bundle: {s}\n", .{@errorName(e)});
        err.flush() catch {};
        std.process.exit(code);
    }
    // A program in a macOS app runs the main script of the app, and each
    // word of the command line is an argument of the script.
    const in_bundle = if (own_app == null) ztk.bundle.start(io, arena) else null;
    if (in_bundle) |b| {
        script = b.main;
        root_dir = b.root;
        allow_bits = b.allow;
        rest = args[1..];
    }
    var force_cpu = false;
    var i: usize = 1;
    while (in_bundle == null and own_app == null and i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        if (std.mem.eql(u8, a, "--headless")) {
            headless = true;
        } else if (std.mem.eql(u8, a, "--mcp")) {
            mcp = true;
        } else if (std.mem.eql(u8, a, "--cpu")) {
            force_cpu = true;
        } else if (std.mem.eql(u8, a, "--allow") or std.mem.eql(u8, a, "--root")) {
            if (i + 1 >= args.len) fail(err, "ztk: {s} needs a value\n", .{a});
            i += 1;
            if (a[2] == 'r') {
                root_dir = args[i];
            } else {
                // `hotkey` is a grant of ztk. The other names are capabilities of ztcl.
                var names = std.mem.tokenizeScalar(u8, args[i], ',');
                while (names.next()) |n| {
                    if (std.mem.eql(u8, n, "hotkey")) {
                        hotkeys = true;
                        continue;
                    }
                    allow_bits |= ztcl.interp.Capability.parse(n) orelse fail(err, "ztk: unknown capability in \"{s}\"\n", .{args[i]});
                }
            }
        } else if (std.mem.eql(u8, a, "--dark")) {
            dark = true;
        } else if (std.mem.eql(u8, a, "--windowingsystem")) {
            i += 1;
            if (i >= args.len) fail(err, "ztk: {s} needs a value\n", .{a});
            const v: []const u8 = args[i];
            if (!std.mem.eql(u8, v, "x11") and !std.mem.eql(u8, v, "win32") and !std.mem.eql(u8, v, "aqua") and !std.mem.eql(u8, v, "ztk"))
                fail(err, "ztk: bad windowing system \"{s}\": must be x11, win32, aqua, or ztk\n", .{v});
            windowing = v;
        } else if (std.mem.eql(u8, a, "--direct")) {
            direct_on = true;
        } else if (std.mem.eql(u8, a, "--direct-unsafe-test-device")) {
            direct_opts.unsafe_test_device = true;
        } else if (std.mem.eql(u8, a, "--version")) {
            try out.writeAll("ztk 0.0.0\n");
            return;
        } else if (std.mem.eql(u8, a, "--fb") or std.mem.eql(u8, a, "--rotate") or std.mem.eql(u8, a, "--touch-debounce") or std.mem.eql(u8, a, "--output") or std.mem.eql(u8, a, "--tty")) {
            i += 1;
            if (i >= args.len) fail(err, "ztk: {s} needs a value\n", .{a});
            const v: []const u8 = args[i];
            if (std.mem.eql(u8, a, "--fb")) {
                direct_opts.fb_device = v;
            } else if (std.mem.eql(u8, a, "--tty")) {
                direct_opts.tty = v;
            } else if (std.mem.eql(u8, a, "--rotate")) {
                const deg = std.fmt.parseInt(u16, v, 10) catch fail(err, "ztk: bad rotation \"{s}\"\n", .{v});
                direct_opts.rotation = switch (deg) {
                    0 => .r0,
                    90 => .r90,
                    180 => .r180,
                    270 => .r270,
                    else => fail(err, "ztk: the rotation is 0, 90, 180, or 270\n", .{}),
                };
            } else if (std.mem.eql(u8, a, "--touch-debounce")) {
                direct_opts.touch_debounce_ms = std.fmt.parseInt(u32, v, 10) catch fail(err, "ztk: bad debounce time \"{s}\"\n", .{v});
            } else {
                direct_opts.output = std.meta.stringToEnum(ztk.direct.Output, v) orelse fail(err, "ztk: the output is auto, vulkan, or framebuffer\n", .{});
            }
        } else if (std.mem.eql(u8, a, "--time")) {
            i += 1;
            if (i >= args.len) fail(err, "ztk: {s} needs a value\n", .{a});
            time_ms = std.fmt.parseInt(i64, args[i], 10) catch fail(err, "ztk: bad time \"{s}\"\n", .{args[i]});
            if (time_ms.? < 0) fail(err, "ztk: the time is 0 or more\n", .{});
        } else if (std.mem.eql(u8, a, "--exit-after-frames") or std.mem.eql(u8, a, "--screenshot") or std.mem.eql(u8, a, "--scale")) {
            i += 1;
            if (i >= args.len) fail(err, "ztk: {s} needs a value\n", .{a});
            const v: []const u8 = args[i];
            if (std.mem.eql(u8, a, "--screenshot")) {
                screenshot = v;
            } else if (std.mem.eql(u8, a, "--scale")) {
                scale = std.fmt.parseFloat(f32, v) catch fail(err, "ztk: bad scale \"{s}\"\n", .{v});
                if (!(scale >= 0.25 and scale <= 16)) fail(err, "ztk: the scale is from 0.25 to 16\n", .{});
            } else {
                max_frames = std.fmt.parseInt(u64, v, 10) catch fail(err, "ztk: bad frame count \"{s}\"\n", .{v});
            }
        } else if (a.len > 1 and a[0] == '-' and script == null) {
            fail(err, "ztk: unknown flag {s}\n{s}", .{ a, usage });
        } else {
            script = a;
            rest = args[i + 1 ..];
            break;
        }
    }
    var it: ztcl.Interp = undefined;
    try it.init(init.gpa);
    defer it.deinit();
    if (own_app) |bytes| {
        const app = ztk.appbin.mount(&it, arena, bytes) catch |e| fail(err, "ztk: the app in this program: {s}\n", .{@errorName(e)});
        script = app.main;
        allow_bits = app.allow;
        root_dir = app.root;
    }
    if (mcp) headless = true;
    // ZTK_HEADLESS=1 is the headless switch of a bundled app, which reads
    // no flag. It works for each run of ztk.
    if (init.environ_map.get("ZTK_HEADLESS")) |v| {
        if (std.mem.eql(u8, v, "1")) headless = true;
    }
    const path = script orelse {
        try err.writeAll(usage);
        err.flush() catch {};
        std.process.exit(2);
    };
    // The script of an app comes from its mount through `source`.
    const text = if (own_app != null)
        try it.str(try ztcl.value.newList(arena, &.{ .{ .str = "source" }, .{ .str = path } }))
    else
        Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 << 20)) catch |e| {
            fail(err, "ztk: {s}: {s}\n", .{ path, @errorName(e) });
        };
    // `info script` gives the file, as in wish.
    if (own_app == null) it.script_name = path;
    // With --mcp, stdout has only the answers, so the output of the script goes to stderr.
    it.output = .{ .ctx = if (mcp) err else out, .write = write };
    // The capabilities of the program: the file commands by default, as a
    // desktop program needs them, and more from --allow.
    host_io = io;
    it.clock_host = .{ .now = hostNow, .zone = hostZone };
    it.event_host = .{ .now = hostTicks, .sleep = hostSleep };
    try it.allow(allow_bits);
    // With the env capability, the global array env has the environment
    // of the program, as in wish.
    if (allow_bits & @backingInt(ztcl.interp.Capability.env) != 0) {
        var envs = init.environ_map.iterator();
        while (envs.next()) |e| {
            const name = try std.fmt.allocPrint(arena, "env({s})", .{e.key_ptr.*});
            it.setVar(name, .{ .str = e.value_ptr.* }) catch {};
        }
    }
    const fs_bits = @backingInt(ztcl.interp.Capability.file) | @backingInt(ztcl.interp.Capability.channels);
    // The file commands use the real paths of the host, as in wish, and
    // --root keeps them in one folder.
    if (allow_bits & fs_bits != 0) {
        if (root_dir) |dir| {
            ztcl.fsroot.setRoot(&it, dir) catch fail(err, "ztk: cannot open the root folder \"{s}\"\n", .{dir});
        } else ztcl.fsroot.setHost(&it) catch fail(err, "ztk: this system has no host mode for the file commands\n", .{});
    }

    var head: ?*ztk.headless.Headless = null;
    var wl: if (ztk.wayland_enabled) ?*ztk.wayland.Wayland else void = if (ztk.wayland_enabled) null else {};
    var xc: if (ztk.wayland_enabled) ?*ztk.x11.X11 else void = if (ztk.wayland_enabled) null else {};
    var mac: if (ztk.appkit_enabled) ?*ztk.appkit.AppKit else void = if (ztk.appkit_enabled) null else {};
    var platform: ztk.platform.Platform = undefined;
    var direct_be: ?*ztk.direct.Direct = null;
    var win_be: if (ztk.windows_enabled) ?*ztk.windows.Win32 else void = if (ztk.windows_enabled) null else {};
    if (direct_on) {
        if (!direct_opts.unsafe_test_device) {
            fail(err, "ztk: --direct does not own the VT yet: no keyboard mode, no termios, and no VT switch. Add --direct-unsafe-test-device only on a device that is free to lose its console.\n", .{});
        }
        direct_opts.scale = scale;
        direct_opts.session = .{
            .wayland_display = init.environ_map.get("WAYLAND_DISPLAY"),
            .x_display = init.environ_map.get("DISPLAY"),
            .session_type = init.environ_map.get("XDG_SESSION_TYPE"),
        };
        direct_be = ztk.direct.Direct.init(init.gpa, direct_opts) catch |e| {
            fail(err, "ztk: cannot use the display or the input devices: {s}. Run on an active VT with no display server. The device files belong to a group such as video and input.\n", .{@errorName(e)});
        };
        platform = direct_be.?.platform();
    } else if (headless) {
        head = try ztk.headless.Headless.init(init.gpa);
        platform = head.?.platform();
    } else if (ztk.appkit_enabled) {
        mac = ztk.appkit.AppKit.init(init.gpa) catch |e| fail(err, "ztk: cannot use AppKit: {s}\n", .{@errorName(e)});
        platform = mac.?.platform();
    } else if (ztk.wayland_enabled and init.environ_map.get("WAYLAND_DISPLAY") == null and init.environ_map.get("DISPLAY") != null) {
        // No Wayland compositor: the X server of DISPLAY.
        var auth_buf: [4096]u8 = undefined;
        const authority = init.environ_map.get("XAUTHORITY") orelse if (init.environ_map.get("HOME")) |h| std.fmt.bufPrint(&auth_buf, "{s}/.Xauthority", .{h}) catch null else null;
        xc = ztk.x11.X11.init(init.gpa, .{
            .display = init.environ_map.get("DISPLAY").?,
            .authority = authority,
            .app_id = if (own_app != null) std.fs.path.basename(args[0]) else "ztk",
        }) catch |e| fail(err, "ztk: cannot use the X display: {s}\n", .{@errorName(e)});
        platform = xc.?.platform();
    } else if (ztk.wayland_enabled) {
        if (init.environ_map.get("WAYLAND_DISPLAY") == null) {
            fail(err, "ztk: no Wayland or X display. Use --headless or ZTK_HEADLESS=1, or run in a desktop session.\n", .{});
        }
        wl = ztk.wayland.Wayland.init(init.gpa, .{
            .runtime_dir = init.environ_map.get("XDG_RUNTIME_DIR"),
            .display = init.environ_map.get("WAYLAND_DISPLAY"),
            .no_input_thread = if (init.environ_map.get("ZTK_NO_INPUT_THREAD")) |v| std.mem.eql(u8, v, "1") else false,
            .debug = if (init.environ_map.get("ZTK_WAYLAND_DEBUG")) |v| std.mem.eql(u8, v, "1") else false,
            // ZTK_RENDERER=cpu, vulkan, or auto. The default is auto: Vulkan when the compositor accepts its dma-bufs.
            .bus_address = init.environ_map.get("DBUS_SESSION_BUS_ADDRESS"),
            // The .desktop file of `ztk bundle --desktop` has the name of the program file.
            .app_id = if (own_app != null) std.fs.path.basename(args[0]) else "ztk",
            .renderer = if (force_cpu) .cpu else if (init.environ_map.get("ZTK_RENDERER")) |v| std.meta.stringToEnum(ztk.wayland.Renderer, v) orelse fail(err, "ztk: ZTK_RENDERER is cpu, vulkan, or auto\n", .{}) else .auto,
        }) catch |e| fail(err, "ztk: cannot use the Wayland display: {s}\n", .{@errorName(e)});
        platform = wl.?.platform();
    } else if (ztk.windows_enabled) {
        // ZTK_RENDERER=cpu, d3d12, or warp picks the output. The default is Direct3D 12, and the CPU without a device.
        var wopts: ztk.windows.Options = .{};
        if (init.environ_map.get("ZTK_RENDERER")) |v| {
            if (std.mem.eql(u8, v, "warp")) {
                wopts.renderer = .d3d12;
                wopts.warp = true;
            } else wopts.renderer = std.meta.stringToEnum(ztk.windows.Renderer, v) orelse fail(err, "ztk: ZTK_RENDERER is cpu, d3d12, or warp\n", .{});
        }
        win_be = ztk.windows.Win32.init(init.gpa, wopts) catch |e| fail(err, "ztk: cannot use the Win32 backend: {s}\n", .{@errorName(e)});
        platform = win_be.?.platform();
    } else {
        fail(err, "ztk: this build has no Wayland backend. Use --headless.\n", .{});
    }
    defer if (head) |h| h.deinit();
    defer if (direct_be) |dbe| dbe.deinit();
    defer if (ztk.windows_enabled) {
        if (win_be) |b| b.deinit();
    };
    defer if (ztk.appkit_enabled) {
        if (mac) |m| m.deinit();
    };
    defer if (ztk.wayland_enabled) {
        if (wl) |w| w.deinit();
        if (xc) |x| x.deinit();
    };

    // The folder of the script is the root of `ztk::style load`.
    const style_root = std.fs.path.dirname(path) orelse ".";
    const app = try ztk.App.init(init.gpa, &it, .{ .platform = platform, .dark = dark, .style_root = style_root, .io = io, .on_exit = exitNow, .hotkeys = hotkeys, .render_mode = .threaded, .animations = init.environ_map.get("ZTK_NO_ANIMATION") == null, .start_us = start_us });
    const want_stats = init.environ_map.get("ZTK_FRAME_STATS") != null;
    app.stats.slow_out = err;
    defer app.deinit();
    app.max_frames = max_frames;
    app.flush_output = flushOutput;
    if (head) |h| {
        if (app.window) |win| {
            win.scale = scale;
            _ = h;
        }
    }

    // The arguments of the script.
    const list = try arena.alloc(ztcl.Value, rest.len);
    for (rest, list) |a, *slot| slot.* = .{ .str = a };
    const argv_value = try ztcl.value.wrapList(arena, list);
    try it.setVar("argv", argv_value);
    try it.setVar("argc", .{ .int = @intCast(rest.len) });
    try it.setVar("argv0", .{ .str = if (own_app != null) args[0] else path });
    // `info script` gives the path of the main script, as in wish.
    if (own_app == null) it.script_name = path;

    // `tk windowingsystem` gives the name of --windowingsystem, for a Tk
    // app that tests for x11, win32, or aqua.
    if (windowing) |v| try it.setVar("::ztk::priv::windowingsystem", .{ .str = v });

    var status: u8 = 0;
    if (app.runScript(text)) |_| {
        if (time_ms) |ms| if (head) |h| {
            // The first frame starts the animations at the time 0. The frames that follow are at MS.
            app.flush() catch {};
            app.render.flush();
            h.now_us = ms * 1000;
            if (app.root) |r| r.invalidate(.{ .style = true, .measure = false, .layout = false, .paint = true });
            if (app.max_frames) |m| app.max_frames = m + app.frames;
        };
        if (mcp) {
            serveMcp(io, &it, app, out) catch |e| {
                err.print("ztk: --mcp: {s}\n", .{@errorName(e)}) catch {};
                status = 1;
            };
        } else app.run() catch |e| {
            const msg = if (e == error.TclError) it.str(it.result) catch "error" else @errorName(e);
            err.print("{s}\n", .{msg}) catch {};
            status = 1;
        };
    } else |e| {
        out.flush() catch {};
        const msg = if (e == error.TclError) it.str(it.result) catch "error" else @errorName(e);
        err.print("{s}\n", .{msg}) catch {};
        status = 1;
    }
    app.render.flush();
    if (own_app == null) try err.print("frames: {d}\n", .{app.frames});
    if (want_stats) {
        app.stats.report(err) catch {};
        if (direct_be) |dbe| err.print("output: {s}, rows for each frame: {d}\n", .{ dbe.outputName(), if (dbe.frames > 0) dbe.rows_sum / dbe.frames else 0 }) catch {};
    }
    if (screenshot) |file| {
        if (head) |h| {
            if (app.window) |win| if (try h.composite(init.gpa, win)) |img| {
                defer init.gpa.free(img.pixels);
                const bytes = try ztk.png.encode(init.gpa, img);
                defer init.gpa.free(bytes);
                try Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = bytes });
            };
        }
    }
    out.flush() catch {};
    err.flush() catch {};
    if (status != 0) exitNow(status);
}

/// A program of the GUI subsystem (`ztk bundle` for Windows) starts with
/// no console. When a terminal started it, the program attaches to the
/// console of the terminal, and stdout and stderr with no handle go to
/// it, so `puts` and the errors show there. A handle that the parent gave,
/// such as a pipe or a file, stays.
fn attachConsole() void {
    const W = struct {
        extern "kernel32" fn GetConsoleWindow() callconv(.winapi) ?*anyopaque;
        extern "kernel32" fn AttachConsole(pid: u32) callconv(.winapi) i32;
        extern "kernel32" fn GetStdHandle(n: u32) callconv(.winapi) ?*anyopaque;
        extern "kernel32" fn SetStdHandle(n: u32, h: ?*anyopaque) callconv(.winapi) i32;
        extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, security: ?*anyopaque, disposition: u32, flags: u32, template: ?*anyopaque) callconv(.winapi) ?*anyopaque;
    };
    // A console program has its console already.
    if (W.GetConsoleWindow() != null) return;
    // ATTACH_PARENT_PROCESS
    if (W.AttachConsole(0xffff_ffff) == 0) return;
    // STD_OUTPUT_HANDLE and STD_ERROR_HANDLE
    for ([_]u32{ @bitCast(@as(i32, -11)), @bitCast(@as(i32, -12)) }) |n| {
        const h = W.GetStdHandle(n);
        if (h != null and @intFromPtr(h) != ~@as(usize, 0)) continue;
        // GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, OPEN_EXISTING
        const con = W.CreateFileW(std.unicode.utf8ToUtf16LeStringLiteral("CONOUT$"), 0xC000_0000, 0x3, null, 3, 0, null);
        if (@intFromPtr(con) == ~@as(usize, 0)) return;
        _ = W.SetStdHandle(n, con);
    }
}
