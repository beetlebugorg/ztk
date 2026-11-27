//! The X11 backend: a client of the X Window System protocol (version 11)
//! over the Unix socket of the server, with no C library, for a desktop
//! with no Wayland compositor. It has one window. The CPU renderer draws
//! each frame, and `PutImage` sends the rows to the window in parts that
//! fit the largest request of the server.
//!
//! The connection reads `MIT-MAGIC-COOKIE-1` from the authority file
//! (`XAUTHORITY`, or `.Xauthority` in the home folder). The keys come
//! from `GetKeyboardMapping`: the first keysym of a key, or the second
//! one with shift. The window manager closes the window with the
//! `WM_DELETE_WINDOW` protocol of the ICCCM. A frame comes 16 ms after
//! the last one, as the server gives no frame callback.
//!
//! The source of the protocol is the X Window System Protocol document
//! and the ICCCM and EWMH documents (docs/references/x11.md).
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const linux = std.os.linux;
const geom = @import("../geom.zig");
const event = @import("../event.zig");
const plat = @import("platform.zig");
const xkb = @import("wl/xkb.zig");
const Event = event.Event;
const Mods = event.Mods;
const Window = plat.Window;
const Platform = plat.Platform;
const Frame = @import("../scene.zig").Frame;
const Target = @import("../render/thread.zig").Target;
const Atlas = @import("../text/atlas.zig").Atlas;
const cpu = @import("../render/cpu.zig");
const Image = @import("../render/renderer.zig").Image;

pub const Options = struct {
    /// The value of DISPLAY, such as `:0`.
    display: []const u8,
    /// The authority file, or null for none.
    authority: ?[]const u8 = null,
    app_id: []const u8 = "ztk",
};

const Op = struct {
    const create_window = 1;
    const map_window = 8;
    const configure_window = 12;
    const intern_atom = 16;
    const change_property = 18;
    const create_gc = 55;
    const put_image = 72;
    const get_keyboard_mapping = 101;
};

/// The event mask of the window: keys, buttons, enter, leave, motion,
/// exposure, structure, and focus.
const event_mask: u32 = 0x1 | 0x2 | 0x4 | 0x8 | 0x10 | 0x20 | 0x40 | 0x8000 | 0x20000 | 0x200000;
const frame_us: i64 = 16_000;

const SpinLock = struct {
    held: std.atomic.Value(bool) = .init(false),
    fn lock(l: *SpinLock) void {
        while (l.held.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn unlock(l: *SpinLock) void {
        l.held.store(false, .release);
    }
};

pub const X11 = struct {
    gpa: std.mem.Allocator,
    fd: i32,
    opts: Options,
    /// Guards the writes and the sequence number: the draw can run on the render thread.
    lock: SpinLock = .{},
    seq: u16 = 0,
    in: std.ArrayListUnmanaged(u8) = .empty,
    /// The events that a wait for a reply read, in their wire form.
    queued: std.ArrayListUnmanaged([32]u8) = .empty,
    xid_base: u32 = 0,
    xid_mask: u32 = 0,
    xid_next: u32 = 0,
    max_request: u32 = 65535,
    root: u32 = 0,
    root_visual: u32 = 0,
    root_depth: u8 = 0,
    min_key: u8 = 8,
    max_key: u8 = 255,
    per_key: u8 = 0,
    keysyms: []u32 = &.{},
    wm_protocols: u32 = 0,
    wm_delete: u32 = 0,
    net_wm_name: u32 = 0,
    net_wm_icon: u32 = 0,
    utf8_string: u32 = 0,
    xwin: u32 = 0,
    gc: u32 = 0,
    window: ?*Window = null,
    events: std.ArrayListUnmanaged(Event) = .empty,
    frame_wanted: bool = false,
    last_frame_us: i64 = 0,
    atlas: Atlas,
    /// The last frame in the form of the server (bytes B, G, R, X), for an expose.
    shown: []u8 = &.{},
    shown_w: u32 = 0,
    shown_h: u32 = 0,
    held: [256]bool = @splat(false),
    px: f32 = 0,
    py: f32 = 0,

    pub fn init(gpa: std.mem.Allocator, opts: Options) !*X11 {
        const fd = try connectDisplay(opts.display);
        errdefer _ = linux.close(fd);
        const x = try gpa.create(X11);
        errdefer gpa.destroy(x);
        x.* = .{ .gpa = gpa, .fd = fd, .opts = opts, .atlas = Atlas.init(gpa) };
        errdefer x.atlas.deinit();
        try x.setup();
        try x.readKeymap();
        x.wm_protocols = try x.atom("WM_PROTOCOLS");
        x.wm_delete = try x.atom("WM_DELETE_WINDOW");
        x.net_wm_name = try x.atom("_NET_WM_NAME");
        x.utf8_string = try x.atom("UTF8_STRING");
        x.net_wm_icon = try x.atom("_NET_WM_ICON");
        return x;
    }

    pub fn deinit(x: *X11) void {
        _ = linux.close(x.fd);
        x.in.deinit(x.gpa);
        x.queued.deinit(x.gpa);
        x.events.deinit(x.gpa);
        x.gpa.free(x.keysyms);
        x.gpa.free(x.shown);
        x.atlas.deinit();
        x.gpa.destroy(x);
    }

    pub fn platform(x: *X11) Platform {
        return .{ .ptr = x, .vtable = &vtable, .live = true };
    }

    const vtable: Platform.VTable = .{
        .deinit = vDeinit,
        .createWindow = vCreateWindow,
        .destroyWindow = vDestroyWindow,
        .setTitle = vSetTitle,
        .setIcon = vSetIcon,
        .requestSize = vRequestSize,
        .setMinSize = vSetMinSize,
        .requestFrame = vRequestFrame,
        .wait = vWait,
        .poll = vPoll,
        .nowUs = vNowUs,
        .target = vTarget,
    };

    fn self(ptr: *anyopaque) *X11 {
        return @ptrCast(@alignCast(ptr));
    }

    // ---- The connection ----

    fn connectDisplay(display: []const u8) !i32 {
        // ":N" or ":N.S": the socket /tmp/.X11-unix/XN.
        const colon = std.mem.lastIndexOfScalar(u8, display, ':') orelse return error.BadDisplay;
        if (colon != 0) return error.BadDisplay;
        var num = display[1..];
        if (std.mem.indexOfScalar(u8, num, '.')) |d| num = num[0..d];
        _ = std.fmt.parseInt(u32, num, 10) catch return error.BadDisplay;
        var addr: linux.sockaddr.un = .{ .path = @splat(0) };
        const path = std.fmt.bufPrint(&addr.path, "/tmp/.X11-unix/X{s}", .{num}) catch return error.BadDisplay;
        const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (isErr(rc)) return error.ConnectFailed;
        const fd: i32 = @intCast(rc);
        const len: linux.socklen_t = @intCast(@sizeOf(linux.sa_family_t) + path.len + 1);
        if (isErr(linux.connect(fd, &addr, len))) {
            _ = linux.close(fd);
            return error.ConnectFailed;
        }
        return fd;
    }

    fn isErr(rc: usize) bool {
        return @as(isize, @bitCast(rc)) < 0;
    }

    fn writeAll(x: *X11, b: []const u8) !void {
        var off: usize = 0;
        while (off < b.len) {
            const rc = linux.write(x.fd, b[off..].ptr, b.len - off);
            if (isErr(rc)) {
                if (linux.errno(rc) == .INTR) continue;
                return error.Disconnected;
            }
            off += rc;
        }
    }

    /// Reads at least `n` bytes into `in`. A timeout of -1 waits with no limit.
    fn fill(x: *X11, n: usize, timeout_ms: i32) !bool {
        while (x.in.items.len < n) {
            var pfd = [1]linux.pollfd{.{ .fd = x.fd, .events = linux.POLL.IN, .revents = 0 }};
            const r = linux.poll(&pfd, 1, timeout_ms);
            if (@as(isize, @bitCast(r)) <= 0) return false;
            var buf: [8192]u8 = undefined;
            const rc = linux.read(x.fd, &buf, buf.len);
            if (isErr(rc) or rc == 0) return error.Disconnected;
            try x.in.appendSlice(x.gpa, buf[0..rc]);
        }
        return true;
    }

    fn consume(x: *X11, n: usize) void {
        const rest = x.in.items.len - n;
        std.mem.copyForwards(u8, x.in.items[0..rest], x.in.items[n..]);
        x.in.items.len = rest;
    }

    /// The connection setup, with the cookie of the authority file.
    fn setup(x: *X11) !void {
        var cookie: [16]u8 = undefined;
        const have = x.readCookie(&cookie);
        const name = "MIT-MAGIC-COOKIE-1";
        var req: [12 + 20 + 16]u8 = @splat(0);
        req[0] = 'l';
        std.mem.writeInt(u16, req[2..4], 11, .little);
        var n: usize = 12;
        if (have) {
            std.mem.writeInt(u16, req[6..8], name.len, .little);
            std.mem.writeInt(u16, req[8..10], 16, .little);
            @memcpy(req[12..][0..name.len], name);
            @memcpy(req[32..48], &cookie);
            n = 48;
        }
        try x.writeAll(req[0..n]);
        if (!try x.fill(8, 5000)) return error.Timeout;
        const extra = @as(usize, std.mem.readInt(u16, x.in.items[6..8], .little)) * 4;
        if (!try x.fill(8 + extra, 5000)) return error.Timeout;
        defer x.consume(8 + extra);
        const d = x.in.items[8 .. 8 + extra];
        if (x.in.items[0] != 1) {
            const why_len = x.in.items[1];
            std.debug.print("ztk: the X server refused the connection: {s}\n", .{d[0..@min(why_len, d.len)]});
            return error.Refused;
        }
        x.xid_base = std.mem.readInt(u32, d[4..8], .little);
        x.xid_mask = std.mem.readInt(u32, d[8..12], .little);
        const vendor_len = std.mem.readInt(u16, d[16..18], .little);
        x.max_request = std.mem.readInt(u16, d[18..20], .little);
        const formats = d[21];
        x.min_key = d[26];
        x.max_key = d[27];
        const screen = d[32 + pad4(vendor_len) + @as(usize, formats) * 8 ..];
        x.root = std.mem.readInt(u32, screen[0..4], .little);
        x.root_visual = std.mem.readInt(u32, screen[32..36], .little);
        x.root_depth = screen[38];
        if (x.root_depth != 24 and x.root_depth != 32) return error.UnsupportedDepth;
    }

    fn pad4(n: usize) usize {
        return (n + 3) & ~@as(usize, 3);
    }

    /// The cookie of the display in the authority file.
    fn readCookie(x: *X11, out: *[16]u8) bool {
        const path = x.opts.authority orelse return false;
        var pbuf: [4096]u8 = undefined;
        if (path.len >= pbuf.len) return false;
        @memcpy(pbuf[0..path.len], path);
        pbuf[path.len] = 0;
        const rc = linux.open(pbuf[0..path.len :0], .{ .CLOEXEC = true }, 0);
        if (isErr(rc)) return false;
        const fd: i32 = @intCast(rc);
        defer _ = linux.close(fd);
        var buf: [16384]u8 = undefined;
        var len: usize = 0;
        while (len < buf.len) {
            const n = linux.read(fd, buf[len..].ptr, buf.len - len);
            if (isErr(n) or n == 0) break;
            len += n;
        }
        var num = x.opts.display[1..];
        if (std.mem.indexOfScalar(u8, num, '.')) |d| num = num[0..d];
        var r: usize = 0;
        while (r + 2 <= len) {
            r += 2; // family
            var fields: [4][]const u8 = undefined;
            for (&fields) |*fld| {
                if (r + 2 > len) return false;
                const l = std.mem.readInt(u16, buf[r..][0..2], .big);
                r += 2;
                if (r + l > len) return false;
                fld.* = buf[r .. r + l];
                r += l;
            }
            // address, number, name, data. An empty number fits each display.
            if ((fields[1].len == 0 or std.mem.eql(u8, fields[1], num)) and std.mem.eql(u8, fields[2], "MIT-MAGIC-COOKIE-1") and fields[3].len == 16) {
                @memcpy(out, fields[3]);
                return true;
            }
        }
        return false;
    }

    fn newId(x: *X11) u32 {
        const id = x.xid_base | (x.xid_next & x.xid_mask);
        x.xid_next += 1;
        return id;
    }

    /// Sends a request: the opcode, the byte of data, and the words. Gives its sequence number.
    fn send(x: *X11, op: u8, data: u8, words: []const u32, tail: []const u8) !u16 {
        x.lock.lock();
        defer x.lock.unlock();
        const len = 1 + words.len + pad4(tail.len) / 4;
        var head: [4]u8 = .{ op, data, 0, 0 };
        std.mem.writeInt(u16, head[2..4], @intCast(len), .little);
        try x.writeAll(&head);
        try x.writeAll(std.mem.sliceAsBytes(words));
        try x.writeAll(tail);
        const zeros: [3]u8 = @splat(0);
        try x.writeAll(zeros[0 .. pad4(tail.len) - tail.len]);
        x.seq +%= 1;
        return x.seq;
    }

    /// Reads until the reply of `seq`, and keeps the events that come before it.
    /// The caller frees the reply.
    fn reply(x: *X11, seq: u16) ![]u8 {
        while (true) {
            if (!try x.fill(32, 5000)) return error.Timeout;
            const kind = x.in.items[0];
            const s = std.mem.readInt(u16, x.in.items[2..4], .little);
            if (kind == 1) {
                const n = 32 + @as(usize, std.mem.readInt(u32, x.in.items[4..8], .little)) * 4;
                if (!try x.fill(n, 5000)) return error.Timeout;
                const r = try x.gpa.dupe(u8, x.in.items[0..n]);
                x.consume(n);
                if (s == seq) return r;
                x.gpa.free(r);
            } else if (kind == 0) {
                const code = x.in.items[1];
                x.consume(32);
                if (s == seq) {
                    std.debug.print("ztk: X error {d} for request {d}\n", .{ code, s });
                    return error.XError;
                }
            } else {
                try x.queued.append(x.gpa, x.in.items[0..32].*);
                x.consume(32);
            }
        }
    }

    fn atom(x: *X11, name: []const u8) !u32 {
        const seq = try x.send(Op.intern_atom, 0, &.{@intCast(name.len)}, name);
        const r = try x.reply(seq);
        defer x.gpa.free(r);
        return std.mem.readInt(u32, r[8..12], .little);
    }

    fn readKeymap(x: *X11) !void {
        const count: u32 = @as(u32, x.max_key) - x.min_key + 1;
        const seq = try x.send(Op.get_keyboard_mapping, 0, &.{@as(u32, x.min_key) | (count << 8)}, "");
        const r = try x.reply(seq);
        defer x.gpa.free(r);
        x.per_key = r[1];
        const n = (r.len - 32) / 4;
        x.keysyms = try x.gpa.alloc(u32, n);
        for (x.keysyms, 0..) |*k, i| k.* = std.mem.readInt(u32, r[32 + i * 4 ..][0..4], .little);
    }

    fn keysym(x: *X11, code: u8, state: u16) u32 {
        if (code < x.min_key or x.per_key == 0) return 0;
        const at = @as(usize, code - x.min_key) * x.per_key;
        if (at + x.per_key > x.keysyms.len) return 0;
        const syms = x.keysyms[at .. at + x.per_key];
        const lower = syms[0];
        const upper = if (x.per_key > 1 and syms[1] != 0) syms[1] else lower;
        const shift = state & 1 != 0;
        const lock = state & 2 != 0;
        if (lower >= 'a' and lower <= 'z' and upper == lower) return if (shift != lock) lower - 32 else lower;
        if (lower >= 'a' and lower <= 'z') return if (shift != lock) upper else lower;
        return if (shift) upper else lower;
    }

    // ---- The window ----

    fn vCreateWindow(ptr: *anyopaque, opts: plat.WindowOptions) anyerror!*Window {
        const x = self(ptr);
        if (opts.popup != null or x.window != null) return error.OnlyOneWindow;
        const win = try x.gpa.create(Window);
        errdefer x.gpa.destroy(win);
        win.* = .{ .size = opts.size };
        x.xwin = x.newId();
        // Value mask: the background pixel (0x2) and the event mask (0x800).
        _ = try x.send(Op.create_window, x.root_depth, &.{
            x.xwin,                                        x.root,
            0,                                             @as(u32, @intCast(@max(opts.size.w, 1))) | (@as(u32, @intCast(@max(opts.size.h, 1))) << 16),
            // Border 0, class InputOutput (1).
            1 << 16,                                       x.root_visual,
            0x2 | 0x800,                                   0xffffff,
            event_mask,
        }, "");
        x.gc = x.newId();
        _ = try x.send(Op.create_gc, 0, &.{ x.gc, x.xwin, 0 }, "");
        // WM_PROTOCOLS (type ATOM = 4, format 32) with WM_DELETE_WINDOW.
        try x.property(x.wm_protocols, 4, 32, std.mem.asBytes(&x.wm_delete));
        // WM_CLASS (39), type STRING (31): the instance and the class.
        var class: [128]u8 = undefined;
        const c = std.fmt.bufPrint(&class, "{s}\x00{s}\x00", .{ x.opts.app_id, x.opts.app_id }) catch "ztk\x00ztk\x00";
        try x.property(67, 31, 8, c);
        vSetTitle(ptr, win, if (opts.title.len > 0) opts.title else "ztk");
        _ = try x.send(Op.map_window, 0, &.{x.xwin}, "");
        x.window = win;
        return win;
    }

    /// ChangeProperty with the mode Replace.
    fn property(x: *X11, prop: u32, typ: u32, format: u8, data: []const u8) !void {
        const units: u32 = @intCast(data.len / (format / 8));
        _ = try x.send(Op.change_property, 0, &.{ x.xwin, prop, typ, format, units }, data);
    }

    fn vDestroyWindow(ptr: *anyopaque, win: *Window) void {
        const x = self(ptr);
        if (x.window == win) x.window = null;
        x.gpa.destroy(win);
    }

    fn vDeinit(ptr: *anyopaque) void {
        self(ptr).deinit();
    }

    fn vSetTitle(ptr: *anyopaque, _: *Window, title: []const u8) void {
        const x = self(ptr);
        x.property(x.net_wm_name, x.utf8_string, 8, title) catch {};
        // WM_NAME (39) of type STRING (31), for an old window manager.
        x.property(39, 31, 8, title) catch {};
    }

    /// `_NET_WM_ICON` of EWMH, type CARDINAL (6), format 32: for each
    /// image the width, the height, and one word for each pixel, with
    /// alpha in the top byte and then red, green, and blue. A request has
    /// at most `max_request` words, so the data goes in parts: the first
    /// part replaces the property and each next part appends to it.
    fn vSetIcon(ptr: *anyopaque, _: *Window, icons: []const plat.TrayIcon, _: bool) void {
        const x = self(ptr);
        if (icons.len == 0 or x.xwin == 0) return;
        var n: usize = 0;
        for (icons) |ic| n += 2 + @as(usize, ic.width) * ic.height;
        const data = x.gpa.alloc(u32, n) catch return;
        defer x.gpa.free(data);
        var k: usize = 0;
        for (icons) |ic| {
            data[k] = ic.width;
            data[k + 1] = ic.height;
            k += 2;
            const count = @as(usize, ic.width) * ic.height;
            for (0..count) |i| {
                const px = ic.pixels[i * 4 ..][0..4];
                data[k + i] = @as(u32, px[3]) << 24 | @as(u32, px[0]) << 16 | @as(u32, px[1]) << 8 | px[2];
            }
            k += count;
        }
        // The request has 6 words before the data.
        const part: usize = @min(x.max_request, 65535) - 6;
        var at: usize = 0;
        var mode: u8 = 0;
        while (at < n) : (mode = 2) {
            const end = @min(n, at + part);
            const units: u32 = @intCast(end - at);
            _ = x.send(Op.change_property, mode, &.{ x.xwin, x.net_wm_icon, 6, 32, units }, std.mem.sliceAsBytes(data[at..end])) catch return;
            at = end;
        }
    }

    fn vRequestSize(ptr: *anyopaque, win: *Window, size: geom.Size) void {
        const x = self(ptr);
        if (win.size.w == size.w and win.size.h == size.h) return;
        win.size = size;
        // ConfigureWindow with the width (0x4) and the height (0x8).
        _ = x.send(Op.configure_window, 0, &.{ x.xwin, 0x4 | 0x8, @intCast(@max(size.w, 1)), @intCast(@max(size.h, 1)) }, "") catch {};
        x.events.append(x.gpa, .{ .resize = .{ .window = win, .size = size } }) catch {};
    }

    fn vSetMinSize(ptr: *anyopaque, _: *Window, size: geom.Size) void {
        const x = self(ptr);
        // WM_NORMAL_HINTS (40) of type WM_SIZE_HINTS (41): 18 words, the flag PMinSize (16).
        var hints: [18]u32 = @splat(0);
        hints[0] = 16;
        hints[5] = @intCast(@max(size.w, 0));
        hints[6] = @intCast(@max(size.h, 0));
        x.property(40, 41, 32, std.mem.sliceAsBytes(&hints)) catch {};
    }

    fn vNowUs(_: *anyopaque) i64 {
        return nowUs();
    }

    fn nowUs() i64 {
        var ts: linux.timespec = undefined;
        _ = linux.clock_gettime(.MONOTONIC, &ts);
        return @as(i64, ts.sec) * 1_000_000 + @divFloor(@as(i64, ts.nsec), 1000);
    }

    fn timeMs() u32 {
        return @truncate(@as(u64, @intCast(@divFloor(nowUs(), 1000))));
    }

    // ---- Frames, the wait, and the poll ----

    fn vRequestFrame(ptr: *anyopaque, _: *Window) void {
        self(ptr).frame_wanted = true;
    }

    fn frameLeftUs(x: *X11) ?i64 {
        if (!x.frame_wanted) return null;
        return @max(x.last_frame_us + frame_us - nowUs(), 0);
    }

    fn vWait(ptr: *anyopaque, timeout_us: ?i64) void {
        const x = self(ptr);
        if (x.events.items.len > 0 or x.queued.items.len > 0 or x.in.items.len >= 32) return;
        var limit = timeout_us;
        if (x.frameLeftUs()) |l| limit = if (limit) |t| @min(t, l) else l;
        const ms: i32 = if (limit) |l| @intCast(@min(@divFloor(l +| 999, 1000), std.math.maxInt(i32))) else -1;
        _ = x.fill(32, ms) catch x.lost();
    }

    fn lost(x: *X11) void {
        if (x.window) |win| x.events.append(x.gpa, .{ .close = .{ .window = win } }) catch {};
        x.window = null;
    }

    fn vPoll(ptr: *anyopaque, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(Event)) anyerror!void {
        const x = self(ptr);
        for (x.queued.items) |e| x.handle(&e);
        x.queued.clearRetainingCapacity();
        while (true) {
            const got = x.fill(32, 0) catch {
                x.lost();
                break;
            };
            if (!got) break;
            const e = x.in.items[0..32].*;
            x.consume(32);
            x.handle(&e);
        }
        if (x.frameLeftUs()) |l| if (l == 0) if (x.window) |win| {
            x.frame_wanted = false;
            x.last_frame_us = nowUs();
            try x.events.append(x.gpa, .{ .frame = .{ .window = win, .time_us = x.last_frame_us } });
        };
        try out.appendSlice(gpa, x.events.items);
        x.events.clearRetainingCapacity();
    }

    fn mods(state: u16) Mods {
        return .{
            .shift = state & 1 != 0,
            .lock = state & 2 != 0,
            .control = state & 4 != 0,
            .mod1 = state & 8 != 0,
            .mod2 = state & 0x10 != 0,
            .mod4 = state & 0x40 != 0,
            .button1 = state & 0x100 != 0,
            .button2 = state & 0x200 != 0,
            .button3 = state & 0x400 != 0,
        };
    }

    fn handle(x: *X11, e: *const [32]u8) void {
        const win = x.window orelse return;
        const code = e[0] & 0x7f;
        const rd16 = struct {
            fn f(b: *const [32]u8, at: usize) u16 {
                return std.mem.readInt(u16, b[at..][0..2], .little);
            }
        }.f;
        const ex: f32 = @floatFromInt(@as(i16, @bitCast(rd16(e, 24))));
        const ey: f32 = @floatFromInt(@as(i16, @bitCast(rd16(e, 26))));
        const state = rd16(e, 28);
        switch (code) {
            // KeyPress, KeyRelease.
            2, 3 => {
                const key = e[1];
                const pressed = code == 2;
                // A release with a press of the same key and time next is an autorepeat.
                if (!pressed and x.nextIsRepeat(e)) return;
                const repeat = pressed and x.held[key];
                x.held[key] = pressed;
                const sym = x.keysym(key, state);
                const m = mods(state);
                var ev: Event = .{ .key = .{ .window = win, .keysym = sym, .keycode = key, .pressed = pressed, .repeat = repeat, .mods = m, .time_ms = timeMs() } };
                if (pressed) {
                    var buf: [8]u8 = undefined;
                    const t = xkb.text(sym, m.control, m.mod1, &buf);
                    @memcpy(ev.key.text[0..t.len], t);
                    ev.key.text_len = @intCast(t.len);
                }
                x.push(ev);
            },
            // ButtonPress, ButtonRelease.
            4, 5 => {
                const b = e[1];
                const pressed = code == 4;
                if (b >= 4 and b <= 7) {
                    if (!pressed) return;
                    const dx: f32 = if (b == 6) -1 else if (b == 7) 1 else 0;
                    const dy: f32 = if (b == 4) -1 else if (b == 5) 1 else 0;
                    x.push(.{ .scroll = .{ .window = win, .dx = dx, .dy = dy, .x = ex, .y = ey, .mods = mods(state), .time_ms = timeMs() } });
                    return;
                }
                const button: u8 = switch (b) {
                    1 => 1,
                    2 => 2,
                    3 => 3,
                    else => return,
                };
                x.push(.{ .button = .{ .window = win, .button = button, .pressed = pressed, .x = ex, .y = ey, .mods = mods(state), .time_ms = timeMs() } });
            },
            // MotionNotify, EnterNotify.
            6, 7 => {
                x.px = ex;
                x.py = ey;
                win.feedPointer(ex, ey);
                x.push(.{ .motion = .{ .window = win, .x = ex, .y = ey, .mods = mods(state), .time_ms = timeMs() } });
            },
            // LeaveNotify.
            8 => x.push(.{ .leave = .{ .window = win } }),
            // FocusIn, FocusOut.
            9, 10 => x.push(.{ .focus = .{ .window = win, .focused = code == 9 } }),
            // Expose: the last frame again, once for the last of a series.
            12 => if (rd16(e, 16) == 0) x.putFrame(),
            // ConfigureNotify.
            22 => {
                const size: geom.Size = .{ .w = rd16(e, 20), .h = rd16(e, 22) };
                if (size.w != win.size.w or size.h != win.size.h) {
                    win.size = size;
                    x.push(.{ .resize = .{ .window = win, .size = size } });
                }
            },
            // ClientMessage: WM_DELETE_WINDOW of WM_PROTOCOLS.
            33 => {
                const typ = std.mem.readInt(u32, e[8..12], .little);
                const data = std.mem.readInt(u32, e[12..16], .little);
                if (typ == x.wm_protocols and data == x.wm_delete) x.push(.{ .close = .{ .window = win } });
            },
            else => {},
        }
    }

    fn push(x: *X11, ev: Event) void {
        x.events.append(x.gpa, ev) catch {};
    }

    /// The event after a key release: a press of the same key at the same time.
    fn nextIsRepeat(x: *X11, rel: *const [32]u8) bool {
        if (x.in.items.len < 32) _ = x.fill(32, 0) catch return false;
        if (x.in.items.len < 32) return false;
        const n = x.in.items[0..32];
        return n[0] & 0x7f == 2 and n[1] == rel[1] and std.mem.eql(u8, n[4..8], rel[4..8]);
    }

    // ---- The draw ----

    fn vTarget(ptr: *anyopaque, _: *Window) Target {
        return .{ .ctx = self(ptr), .draw = drawFrame };
    }

    fn drawFrame(ctx: *anyopaque, frame: *const Frame) anyerror!void {
        const x: *X11 = @ptrCast(@alignCast(ctx));
        if (x.window == null) return;
        for (frame.patches.items) |p| try x.atlas.applyPatch(p);
        const scene = &frame.scene;
        const need = @as(usize, scene.width) * scene.height * 4;
        const img = try x.gpa.alloc(u8, need);
        defer x.gpa.free(img);
        var cur: Image = .{ .width = scene.width, .height = scene.height, .pixels = img };
        cpu.render(scene, &x.atlas, &cur);
        const out = try x.gpa.alloc(u8, need);
        // RGBA to the bytes B, G, R, X of a little-endian TrueColor visual.
        var i: usize = 0;
        while (i < need) : (i += 4) {
            out[i] = img[i + 2];
            out[i + 1] = img[i + 1];
            out[i + 2] = img[i];
            out[i + 3] = 255;
        }
        x.lock.lock();
        x.gpa.free(x.shown);
        x.shown = out;
        x.shown_w = scene.width;
        x.shown_h = scene.height;
        x.lock.unlock();
        x.putFrame();
    }

    /// Sends the last frame with PutImage (format ZPixmap, 2), in rows
    /// that fit the largest request.
    fn putFrame(x: *X11) void {
        x.lock.lock();
        const w = x.shown_w;
        const h = x.shown_h;
        const data = x.shown;
        x.lock.unlock();
        if (w == 0 or h == 0) return;
        const row = @as(usize, w) * 4;
        const rows_per = @max(1, (@as(usize, x.max_request) * 4 - 24) / row);
        var y: usize = 0;
        while (y < h) {
            const n = @min(rows_per, h - y);
            _ = x.send(Op.put_image, 2, &.{
                x.xwin,
                x.gc,
                w | (@as(u32, @intCast(n)) << 16),
                @as(u32, @intCast(y)) << 16,
                @as(u32, x.root_depth) << 8,
            }, data[y * row .. (y + n) * row]) catch return;
            y += n;
        }
    }
};
