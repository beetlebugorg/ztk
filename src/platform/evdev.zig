//! Keyboard, pointer, and touch input from the kernel event devices. The
//! reader takes `struct input_event` records from file descriptors
//! without blocking, so a test can give it the read end of a pipe. A
//! keyboard gives key events with the key symbols of the US layout; a
//! mouse moves a pointer position inside the window; a touch panel goes
//! through `Touch`. The backend repeats a held key itself, after 400 ms
//! and then 25 times in each second. `discover` finds the devices in
//! /dev/input with the capability files in /sys/class/input. Each device
//! records what it holds down: keys, modifiers, buttons, and a touch. When
//! a device goes away, the reader sends the release of each one, so no key
//! repeats forever and no pointer hold stays. The clock has 64 bits and
//! does not wrap. An event has the low 32 bits of the time.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const linux = std.os.linux;
const sys = @import("../sys/linux.zig");
const event = @import("../event.zig");
const geom = @import("../geom.zig");
const keymap = @import("keymap.zig");
const plat = @import("platform.zig");
const touch_mod = @import("touch.zig");
const Event = event.Event;
const Window = plat.Window;

pub const Kind = enum { keyboard, mouse, touch };

const Axis = struct { min: i32 = 0, max: i32 = 1 };

const Device = struct {
    fd: i32,
    kind: Kind,
    ax: Axis = .{},
    ay: Axis = .{},
    x: i32 = 0,
    y: i32 = 0,
    touching: bool = false,
    was_touching: bool = false,
    moved: bool = false,
    rel_x: i32 = 0,
    rel_y: i32 = 0,
    /// One bit for each entry of `modifier_codes`.
    mods_down: u8 = 0,
    buttons_down: u8 = 0,
    /// The keys that are down, other than the modifiers.
    keys: [8]u16 = @splat(0),
    key_count: u8 = 0,
};

/// Left and right shift, control, alt, and super.
const modifier_codes = [_]u16{ 42, 54, 29, 97, 56, 100, 125, 126 };

/// The result of one read of a device.
pub const ReadError = error{ WouldBlock, Gone };

/// The result of a failed read. ENODEV is the unplug of an event device.
/// Each other error also ends the device, so `poll` does not spin on it.
fn readFailure(e: linux.E) ReadError {
    return if (e == .AGAIN) error.WouldBlock else error.Gone;
}

fn realRead(fd: i32, buf: []u8) ReadError!usize {
    while (true) {
        const rc = linux.read(fd, buf.ptr, buf.len);
        switch (linux.errno(rc)) {
            .SUCCESS => return rc,
            .INTR => continue,
            else => |e| return readFailure(e),
        }
    }
}

/// The most devices that one reader handles. `discover` looks at this many.
pub const max_devices = 32;

/// The list for `poll`, with room for each device.
pub const PollSet = [max_devices]std.posix.pollfd;

pub const repeat_delay_ms: u32 = 400;
pub const repeat_interval_ms: u32 = 40;

pub const Input = struct {
    gpa: std.mem.Allocator,
    devices: std.ArrayListUnmanaged(Device) = .empty,
    touch: touch_mod.Touch,
    size: geom.Size,
    /// The pointer position in logical pixels, for a mouse.
    px: f32 = 0,
    py: f32 = 0,
    buttons: u8 = 0,
    shift: bool = false,
    control: bool = false,
    alt: bool = false,
    super: bool = false,
    caps: bool = false,
    held: [8]u16 = @splat(0),
    repeat_code: ?u16 = null,
    repeat_at_ms: u64 = 0,
    /// The descriptor of the device that holds the repeating key.
    repeat_fd: i32 = -1,
    /// The read call. A test gives a fake to return an error of the kernel.
    read_fn: *const fn (fd: i32, buf: []u8) ReadError!usize = realRead,
    /// True when a mouse exists, so the output draws a pointer.
    has_mouse: bool = false,

    pub fn init(gpa: std.mem.Allocator, touch_opts: touch_mod.TouchOptions, size: geom.Size) Input {
        return .{ .gpa = gpa, .touch = touch_mod.Touch.init(touch_opts, size), .size = size };
    }

    pub fn deinit(i: *Input) void {
        for (i.devices.items) |d| _ = linux.close(d.fd);
        i.devices.deinit(i.gpa);
    }

    /// Adds a device. A touch panel gives the range of its axes.
    pub fn addFd(i: *Input, fd: i32, kind: Kind, range: ?[2]Axis) !void {
        if (i.devices.items.len == max_devices) return error.TooManyDevices;
        var d: Device = .{ .fd = fd, .kind = kind };
        if (range) |r| {
            d.ax = r[0];
            d.ay = r[1];
        }
        try i.devices.append(i.gpa, d);
        if (kind == .mouse) i.has_mouse = true;
    }

    fn hexFile(path: []const u8, buf: []u8) ?[]const u8 {
        const fd = sys.open(path, .{ .ACCMODE = .RDONLY }) catch return null;
        defer _ = linux.close(fd);
        const n = std.posix.read(fd, buf) catch return null;
        return std.mem.trim(u8, buf[0..n], " \n");
    }

    /// True when the hexadecimal bitmap of a capabilities file has bit `bit`.
    fn hasBit(text: []const u8, bit: u32) bool {
        // The file has words of 64 bits separated by spaces, the highest word first.
        var words = std.mem.splitBackwardsScalar(u8, text, ' ');
        var index: u32 = 0;
        while (words.next()) |w| : (index += 1) {
            if (bit / 64 != index) continue;
            const v = std.fmt.parseInt(u64, w, 16) catch return false;
            return (v >> @intCast(bit % 64)) & 1 == 1;
        }
        return false;
    }

    /// Finds the devices in /dev/input. It reads the capability files of /sys/class/input.
    pub fn discover(i: *Input) !void {
        var n: u32 = 0;
        while (n < max_devices) : (n += 1) {
            var path: [64]u8 = undefined;
            var buf: [256]u8 = undefined;
            const base = try std.fmt.bufPrint(&path, "/sys/class/input/event{d}/device/capabilities", .{n});
            var p2: [96]u8 = undefined;
            const ev_text = hexFile(try std.fmt.bufPrint(&p2, "{s}/ev", .{base}), &buf) orelse continue;
            var b2: [256]u8 = undefined;
            const key_text = hexFile(try std.fmt.bufPrint(&p2, "{s}/key", .{base}), &b2) orelse "";
            const has_key = hasBit(ev_text, sys.EV_KEY);
            const has_rel = hasBit(ev_text, sys.EV_REL);
            const has_abs = hasBit(ev_text, sys.EV_ABS);
            const kind: Kind = if (has_abs and hasBit(key_text, sys.BTN_TOUCH)) .touch else if (has_rel and has_key) .mouse else if (has_key and hasBit(key_text, 30)) .keyboard else continue;
            var dev: [32]u8 = undefined;
            const dev_path = try std.fmt.bufPrint(&dev, "/dev/input/event{d}", .{n});
            const fd = sys.open(dev_path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }) catch |e| {
                std.debug.print("ztk: cannot open {s}: {s}\n", .{ dev_path, @errorName(e) });
                continue;
            };
            var range: ?[2]Axis = null;
            if (kind == .touch) {
                var ax: sys.InputAbsinfo = undefined;
                var ay: sys.InputAbsinfo = undefined;
                if (linux.ioctl(fd, sys.eviocgabs(sys.ABS_X), @intFromPtr(&ax)) == 0 and linux.ioctl(fd, sys.eviocgabs(sys.ABS_Y), @intFromPtr(&ay)) == 0) {
                    range = .{ .{ .min = ax.minimum, .max = ax.maximum }, .{ .min = ay.minimum, .max = ay.maximum } };
                }
            }
            i.addFd(fd, kind, range) catch |e| {
                _ = linux.close(fd);
                return e;
            };
        }
    }

    /// Fills `fds` with the descriptors for `poll`. Returns the used part.
    pub fn pollFds(i: *const Input, fds: []std.posix.pollfd) []std.posix.pollfd {
        var n: usize = 0;
        for (i.devices.items) |d| {
            if (n == fds.len) break;
            fds[n] = .{ .fd = d.fd, .events = std.posix.POLL.IN, .revents = 0 };
            n += 1;
        }
        return fds[0..n];
    }

    fn mods(i: *const Input) event.Mods {
        var m: event.Mods = .{ .shift = i.shift, .lock = i.caps, .control = i.control, .mod1 = i.alt, .mod4 = i.super };
        m.button1 = i.buttons & 1 != 0;
        m.button2 = i.buttons & 2 != 0;
        m.button3 = i.buttons & 4 != 0;
        return m;
    }

    fn symbolOf(i: *const Input, code: u16) ?u32 {
        const lv = keymap.lookup(code) orelse return null;
        const letter = lv.plain >= 'a' and lv.plain <= 'z';
        const upper = if (letter) i.shift != i.caps else i.shift;
        return if (upper) lv.shift else lv.plain;
    }

    fn keyEvent(i: *Input, code: u16, pressed: bool, repeat: bool, now_ms: u64, out: *std.ArrayListUnmanaged(Event), window: *Window) !void {
        const sym = i.symbolOf(code) orelse return;
        var e: Event = .{ .key = .{ .window = window, .keysym = sym, .keycode = @as(u32, code) + 8, .pressed = pressed, .repeat = repeat, .mods = i.mods(), .time_ms = @truncate(now_ms) } };
        if (pressed) {
            var buf: [8]u8 = undefined;
            const text = keymap.text(sym, i.mods(), &buf);
            @memcpy(e.key.text[0..text.len], text);
            e.key.text_len = @intCast(text.len);
        }
        try out.append(i.gpa, e);
    }

    /// The modifier flags are the union of what each device holds.
    fn updateModifiers(i: *Input) void {
        var all: u8 = 0;
        for (i.devices.items) |d| all |= d.mods_down;
        i.shift = all & 0b0000_0011 != 0;
        i.control = all & 0b0000_1100 != 0;
        i.alt = all & 0b0011_0000 != 0;
        i.super = all & 0b1100_0000 != 0;
    }

    fn updateButtons(i: *Input) void {
        var all: u8 = 0;
        for (i.devices.items) |d| all |= d.buttons_down;
        i.buttons = all;
    }

    fn setModifier(i: *Input, d: *Device, code: u16, down: bool) bool {
        const index = std.mem.indexOfScalar(u16, &modifier_codes, code) orelse return false;
        const bit = @as(u8, 1) << @intCast(index);
        if (down) d.mods_down |= bit else d.mods_down &= ~bit;
        i.updateModifiers();
        return true;
    }

    fn noteKey(d: *Device, code: u16, down: bool) void {
        const held = d.keys[0..d.key_count];
        const at = std.mem.indexOfScalar(u16, held, code);
        if (down and at == null and d.key_count < d.keys.len) {
            d.keys[d.key_count] = code;
            d.key_count += 1;
        } else if (!down) if (at) |k| {
            d.keys[k] = d.keys[d.key_count - 1];
            d.key_count -= 1;
        };
    }

    /// Sends the release of all that a device that went away held down.
    fn releaseDevice(i: *Input, d: *Device, now_ms: u64, out: *std.ArrayListUnmanaged(Event), window: *Window) !void {
        for (d.keys[0..d.key_count]) |code| {
            if (i.repeat_code == code) i.repeat_code = null;
            try i.keyEvent(code, false, false, now_ms, out, window);
        }
        d.key_count = 0;
        // The list of keys has a limit, and the repeating key can be past it.
        if (i.repeat_code) |code| if (i.repeat_fd == d.fd) {
            i.repeat_code = null;
            try i.keyEvent(code, false, false, now_ms, out, window);
        };
        for (modifier_codes, 0..) |code, k| {
            const bit = @as(u8, 1) << @intCast(k);
            if (d.mods_down & bit == 0) continue;
            d.mods_down &= ~bit;
            i.updateModifiers();
            try i.keyEvent(code, false, false, now_ms, out, window);
        }
        for ([_]u8{ 1, 2, 3 }) |button| {
            const bit = @as(u8, 1) << @intCast(button - 1);
            if (d.buttons_down & bit == 0) continue;
            // The mods of a button event have the buttons before the event.
            try out.append(i.gpa, .{ .button = .{ .window = window, .button = button, .pressed = false, .x = i.px, .y = i.py, .mods = i.mods(), .time_ms = @truncate(now_ms) } });
            d.buttons_down &= ~bit;
            i.updateButtons();
        }
        if (d.kind == .touch and d.was_touching) {
            try i.touch.feed(.{ .kind = .up, .x = norm(d.x, d.ax), .y = norm(d.y, d.ay), .time_ms = now_ms }, out, i.gpa, window);
            d.was_touching = false;
        }
    }

    fn handleKey(i: *Input, d: *Device, code: u16, value: i32, now_ms: u64, out: *std.ArrayListUnmanaged(Event), window: *Window) !void {
        if (code == sys.BTN_LEFT or code == sys.BTN_RIGHT or code == sys.BTN_MIDDLE) {
            const button: u8 = if (code == sys.BTN_LEFT) 1 else if (code == sys.BTN_MIDDLE) 2 else 3;
            const pressed = value != 0;
            try out.append(i.gpa, .{ .button = .{ .window = window, .button = button, .pressed = pressed, .x = i.px, .y = i.py, .mods = i.mods(), .time_ms = @truncate(now_ms) } });
            const bit: u8 = @as(u8, 1) << @intCast(button - 1);
            if (pressed) d.buttons_down |= bit else d.buttons_down &= ~bit;
            i.updateButtons();
            return;
        }
        if (value == 2) return; // The backend does its own repeat.
        const down = value != 0;
        if (i.setModifier(d, code, down)) {
            // A modifier gives a key event too, so a binding on the key itself works.
            try i.keyEvent(code, down, false, now_ms, out, window);
            return;
        }
        if (code == 58 and down) i.caps = !i.caps;
        noteKey(d, code, down);
        try i.keyEvent(code, down, false, now_ms, out, window);
        if (down) {
            i.repeat_code = code;
            i.repeat_fd = d.fd;
            i.repeat_at_ms = now_ms + repeat_delay_ms;
        } else if (i.repeat_code == code) i.repeat_code = null;
    }

    fn norm(v: i32, a: Axis) f32 {
        // A device gives any 32-bit range, so the differences need 64 bits.
        const span: f32 = @floatFromInt(@max(@as(i64, a.max) - a.min, 1));
        return std.math.clamp(@as(f32, @floatFromInt(@as(i64, v) - a.min)) / span, 0, 1);
    }

    fn sync(i: *Input, d: *Device, now_ms: u64, out: *std.ArrayListUnmanaged(Event), window: *Window) !void {
        switch (d.kind) {
            .mouse => if (d.rel_x != 0 or d.rel_y != 0) {
                const w: f32 = @floatFromInt(i.size.w);
                const h: f32 = @floatFromInt(i.size.h);
                i.px = std.math.clamp(i.px + @as(f32, @floatFromInt(d.rel_x)), 0, w - 1);
                i.py = std.math.clamp(i.py + @as(f32, @floatFromInt(d.rel_y)), 0, h - 1);
                d.rel_x = 0;
                d.rel_y = 0;
                try out.append(i.gpa, .{ .motion = .{ .window = window, .x = i.px, .y = i.py, .mods = i.mods(), .time_ms = @truncate(now_ms) } });
            },
            .touch => {
                const x = norm(d.x, d.ax);
                const y = norm(d.y, d.ay);
                if (d.touching and !d.was_touching) {
                    try i.touch.feed(.{ .kind = .down, .x = x, .y = y, .time_ms = now_ms }, out, i.gpa, window);
                } else if (!d.touching and d.was_touching) {
                    try i.touch.feed(.{ .kind = .up, .x = x, .y = y, .time_ms = now_ms }, out, i.gpa, window);
                } else if (d.touching and d.moved) {
                    try i.touch.feed(.{ .kind = .move, .x = x, .y = y, .time_ms = now_ms }, out, i.gpa, window);
                }
                d.was_touching = d.touching;
                d.moved = false;
            },
            .keyboard => {},
        }
    }

    fn handle(i: *Input, d: *Device, ev: sys.InputEvent, now_ms: u64, out: *std.ArrayListUnmanaged(Event), window: *Window) !void {
        switch (ev.type) {
            sys.EV_KEY => {
                if (ev.code == sys.BTN_TOUCH and d.kind == .touch) {
                    d.touching = ev.value != 0;
                } else try i.handleKey(d, ev.code, ev.value, now_ms, out, window);
            },
            sys.EV_REL => {
                if (ev.code == sys.REL_X) d.rel_x +|= ev.value;
                if (ev.code == sys.REL_Y) d.rel_y +|= ev.value;
            },
            sys.EV_ABS => {
                if (ev.code == sys.ABS_X or ev.code == sys.ABS_MT_POSITION_X) {
                    d.x = ev.value;
                    d.moved = true;
                }
                if (ev.code == sys.ABS_Y or ev.code == sys.ABS_MT_POSITION_Y) {
                    d.y = ev.value;
                    d.moved = true;
                }
            },
            sys.EV_SYN => if (ev.code == sys.SYN_REPORT) try i.sync(d, now_ms, out, window),
            else => {},
        }
    }

    /// Reads all records that wait on the devices, and appends the events.
    /// A device that gives an error other than "no data yet", or the end of the file
    /// (the device was unplugged), is closed and removed, so `poll` does not spin on it.
    pub fn read(i: *Input, now_ms: u64, out: *std.ArrayListUnmanaged(Event), window: *Window) !void {
        var k: usize = 0;
        while (k < i.devices.items.len) {
            const d = &i.devices.items[k];
            var gone = false;
            var recs: [64]sys.InputEvent = undefined;
            while (true) {
                const n = i.read_fn(d.fd, std.mem.sliceAsBytes(&recs)) catch |e| {
                    gone = e == error.Gone;
                    break;
                };
                if (n == 0) {
                    gone = true;
                    break;
                }
                const count = n / @sizeOf(sys.InputEvent);
                for (recs[0..count]) |ev| try i.handle(d, ev, now_ms, out, window);
                if (count < recs.len) break;
            }
            if (gone) {
                try i.releaseDevice(d, now_ms, out, window);
                _ = linux.close(d.fd);
                _ = i.devices.orderedRemove(k);
                i.updateModifiers();
                i.updateButtons();
            } else k += 1;
        }
    }

    /// Key repeat and the debounce of a touch. Call it with the time.
    pub fn tick(i: *Input, now_ms: u64, out: *std.ArrayListUnmanaged(Event), window: *Window) !void {
        if (i.repeat_code) |code| {
            // After a long stop of the program, one repeat is enough.
            if (now_ms -| i.repeat_at_ms > 1000) i.repeat_at_ms = now_ms;
            while (now_ms >= i.repeat_at_ms) {
                try i.keyEvent(code, true, true, i.repeat_at_ms, out, window);
                i.repeat_at_ms += repeat_interval_ms;
            }
        }
        try i.touch.tick(now_ms, out, i.gpa, window);
    }

    /// The time of the next repeat or debounce, for the wait of the backend.
    pub fn nextDueMs(i: *const Input) ?u64 {
        var best: ?u64 = null;
        if (i.repeat_code != null) best = i.repeat_at_ms;
        if (i.touch.nextDue()) |d| best = if (best) |b| @min(b, d) else d;
        return best;
    }
};

const t = std.testing;

fn rec(fd: i32, ty: u16, code: u16, value: i32) !void {
    const e: sys.InputEvent = .{ .sec = 0, .usec = 0, .type = ty, .code = code, .value = value };
    try sys.writeAll(fd, std.mem.asBytes(&e));
}

fn pipePair() ![2]i32 {
    return sys.pipeNonblocking();
}

fn goneRead(_: i32, _: []u8) ReadError!usize {
    return error.Gone;
}

test "evdev: ENODEV maps to a device that is gone, and EAGAIN does not" {
    const p = try pipePair();
    defer _ = linux.close(p[0]);
    defer _ = linux.close(p[1]);
    var buf: [24]u8 = undefined;
    // An empty pipe with O_NONBLOCK gives EAGAIN.
    try t.expectError(error.WouldBlock, realRead(p[0], &buf));
    // The write end of a pipe gives EBADF, a real error that ends the device.
    try t.expectError(error.Gone, realRead(p[1], &buf));
    try t.expectEqual(error.Gone, readFailure(.NODEV));
    try t.expectEqual(error.WouldBlock, readFailure(.AGAIN));
}

test "evdev: an unplug during a held key, modifier, and button sends each release" {
    const p = try pipePair();
    defer _ = linux.close(p[1]);
    var win: Window = .{ .size = .{ .w = 100, .h = 100 } };
    var inp = Input.init(t.allocator, .{}, win.size);
    defer inp.deinit();
    try inp.addFd(p[0], .keyboard, null);
    try rec(p[1], sys.EV_KEY, 42, 1); // shift
    try rec(p[1], sys.EV_KEY, 30, 1); // a
    try rec(p[1], sys.EV_KEY, sys.BTN_LEFT, 1);
    var out: std.ArrayListUnmanaged(Event) = .empty;
    defer out.deinit(t.allocator);
    try inp.read(0, &out, &win);
    try t.expect(inp.repeat_code != null and inp.shift and inp.buttons == 1);
    out.clearRetainingCapacity();
    inp.read_fn = goneRead;
    try inp.read(10, &out, &win);
    try t.expectEqual(@as(usize, 0), inp.devices.items.len);
    try t.expect(inp.repeat_code == null and !inp.shift and inp.buttons == 0);
    try t.expectEqual(@as(usize, 3), out.items.len);
    try t.expect(!out.items[0].key.pressed and out.items[0].key.keycode == 38);
    try t.expect(!out.items[1].key.pressed and out.items[1].key.keycode == 50);
    try t.expect(!out.items[2].button.pressed);
    out.clearRetainingCapacity();
    // No repeat comes after the unplug.
    try inp.tick(5000, &out, &win);
    try t.expectEqual(@as(usize, 0), out.items.len);
}

test "evdev: an unplug of one keyboard keeps the shift of the other" {
    const a = try pipePair();
    defer _ = linux.close(a[1]);
    const b = try pipePair();
    defer _ = linux.close(b[1]);
    var win: Window = .{ .size = .{ .w = 100, .h = 100 } };
    var inp = Input.init(t.allocator, .{}, win.size);
    defer inp.deinit();
    try inp.addFd(a[0], .keyboard, null);
    try inp.addFd(b[0], .keyboard, null);
    try rec(a[1], sys.EV_KEY, 42, 1);
    try rec(b[1], sys.EV_KEY, 54, 1);
    var out: std.ArrayListUnmanaged(Event) = .empty;
    defer out.deinit(t.allocator);
    try inp.read(0, &out, &win);
    try inp.releaseDevice(&inp.devices.items[0], 1, &out, &win);
    try t.expect(inp.shift);
}

test "evdev: an unplug during a touch ends the touch" {
    const p = try pipePair();
    defer _ = linux.close(p[1]);
    var win: Window = .{ .size = .{ .w = 100, .h = 100 } };
    var inp = Input.init(t.allocator, .{}, win.size);
    defer inp.deinit();
    try inp.addFd(p[0], .touch, .{ .{ .min = 0, .max = 99 }, .{ .min = 0, .max = 99 } });
    try rec(p[1], sys.EV_KEY, sys.BTN_TOUCH, 1);
    try rec(p[1], sys.EV_SYN, sys.SYN_REPORT, 0);
    var out: std.ArrayListUnmanaged(Event) = .empty;
    defer out.deinit(t.allocator);
    try inp.read(0, &out, &win);
    try t.expect(inp.touch.down);
    inp.read_fn = goneRead;
    try inp.read(10, &out, &win);
    try t.expect(!inp.touch.down);
}

test "evdev: key repeat works past 49.7 days of the clock" {
    const p = try pipePair();
    defer _ = linux.close(p[1]);
    var win: Window = .{ .size = .{ .w = 100, .h = 100 } };
    var inp = Input.init(t.allocator, .{}, win.size);
    defer inp.deinit();
    try inp.addFd(p[0], .keyboard, null);
    try rec(p[1], sys.EV_KEY, 30, 1);
    var out: std.ArrayListUnmanaged(Event) = .empty;
    defer out.deinit(t.allocator);
    const near: u64 = (1 << 32) - 100;
    try inp.read(near, &out, &win);
    out.clearRetainingCapacity();
    // Past the 32-bit limit and before the delay ends: no repeat.
    try inp.tick(near + 399, &out, &win);
    try t.expectEqual(@as(usize, 0), out.items.len);
    try inp.tick(near + 400, &out, &win);
    try t.expectEqual(@as(usize, 1), out.items.len);
    try t.expect(out.items[0].key.repeat);
    try t.expectEqual(@as(u32, 300), out.items[0].key.time_ms);
}

test "evdev: the largest relative moves and an axis of the full range do not overflow" {
    const p = try pipePair();
    defer _ = linux.close(p[1]);
    var win: Window = .{ .size = .{ .w = 100, .h = 100 } };
    var inp = Input.init(t.allocator, .{}, win.size);
    defer inp.deinit();
    try inp.addFd(p[0], .mouse, null);
    try rec(p[1], sys.EV_REL, sys.REL_X, std.math.maxInt(i32));
    try rec(p[1], sys.EV_REL, sys.REL_X, std.math.maxInt(i32));
    try rec(p[1], sys.EV_SYN, sys.SYN_REPORT, 0);
    var out: std.ArrayListUnmanaged(Event) = .empty;
    defer out.deinit(t.allocator);
    try inp.read(0, &out, &win);
    try t.expectEqual(@as(f32, 99), inp.px);
    const full: Axis = .{ .min = std.math.minInt(i32), .max = std.math.maxInt(i32) };
    try t.expectEqual(@as(f32, 1), Input.norm(std.math.maxInt(i32), full));
    try t.expectEqual(@as(f32, 0), Input.norm(std.math.minInt(i32), full));
}

test "evdev: a ninth held key stops its repeat at an unplug" {
    const p = try pipePair();
    defer _ = linux.close(p[1]);
    var win: Window = .{ .size = .{ .w = 100, .h = 100 } };
    var inp = Input.init(t.allocator, .{}, win.size);
    defer inp.deinit();
    try inp.addFd(p[0], .keyboard, null);
    for (0..9) |k| try rec(p[1], sys.EV_KEY, @intCast(16 + k), 1);
    var out: std.ArrayListUnmanaged(Event) = .empty;
    defer out.deinit(t.allocator);
    try inp.read(0, &out, &win);
    try t.expectEqual(@as(?u16, 24), inp.repeat_code);
    out.clearRetainingCapacity();
    inp.read_fn = goneRead;
    try inp.read(10, &out, &win);
    try t.expect(inp.repeat_code == null);
    try t.expectEqual(@as(usize, 9), out.items.len);
    out.clearRetainingCapacity();
    try inp.tick(5000, &out, &win);
    try t.expectEqual(@as(usize, 0), out.items.len);
}

test "evdev: the poll set has room for each device" {
    var win: Window = .{ .size = .{ .w = 100, .h = 100 } };
    var inp = Input.init(t.allocator, .{}, win.size);
    defer inp.deinit();
    var ends: [max_devices]i32 = undefined;
    defer for (ends) |fd| {
        _ = linux.close(fd);
    };
    for (&ends) |*end| {
        const p = try pipePair();
        end.* = p[1];
        try inp.addFd(p[0], .keyboard, null);
    }
    var set: PollSet = undefined;
    try t.expectEqual(@as(usize, max_devices), inp.pollFds(&set).len);
    try t.expectError(error.TooManyDevices, inp.addFd(-1, .keyboard, null));
    _ = &win;
}

test "evdev: a pipe of key records gives key events" {
    const p = try pipePair();
    defer _ = linux.close(p[1]);
    var win: Window = .{ .size = .{ .w = 100, .h = 100 } };
    var inp = Input.init(t.allocator, .{}, win.size);
    defer inp.deinit();
    try inp.addFd(p[0], .keyboard, null);
    try rec(p[1], sys.EV_KEY, 30, 1);
    try rec(p[1], sys.EV_KEY, 30, 0);
    try rec(p[1], sys.EV_KEY, 28, 1);
    try rec(p[1], sys.EV_KEY, 28, 0);
    var out: std.ArrayListUnmanaged(Event) = .empty;
    defer out.deinit(t.allocator);
    try inp.read(0, &out, &win);
    try t.expectEqual(@as(usize, 4), out.items.len);
    try t.expectEqual(@as(u32, 'a'), out.items[0].key.keysym);
    try t.expectEqualStrings("a", out.items[0].key.text[0..out.items[0].key.text_len]);
    try t.expectEqual(@as(u32, 38), out.items[0].key.keycode);
    try t.expectEqual(@as(u32, 0xff0d), out.items[2].key.keysym);
}

test "evdev: shift makes a capital letter" {
    const p = try pipePair();
    defer _ = linux.close(p[1]);
    var win: Window = .{ .size = .{ .w = 100, .h = 100 } };
    var inp = Input.init(t.allocator, .{}, win.size);
    defer inp.deinit();
    try inp.addFd(p[0], .keyboard, null);
    try rec(p[1], sys.EV_KEY, 42, 1);
    try rec(p[1], sys.EV_KEY, 30, 1);
    var out: std.ArrayListUnmanaged(Event) = .empty;
    defer out.deinit(t.allocator);
    try inp.read(0, &out, &win);
    try t.expectEqual(@as(u32, 'A'), out.items[1].key.keysym);
    try t.expectEqualStrings("A", out.items[1].key.text[0..out.items[1].key.text_len]);
}

test "evdev: a relative motion moves the pointer and stops at the edge" {
    const p = try pipePair();
    defer _ = linux.close(p[1]);
    var win: Window = .{ .size = .{ .w = 100, .h = 50 } };
    var inp = Input.init(t.allocator, .{}, win.size);
    defer inp.deinit();
    try inp.addFd(p[0], .mouse, null);
    inp.px = 10;
    inp.py = 10;
    try rec(p[1], sys.EV_REL, sys.REL_X, 5);
    try rec(p[1], sys.EV_REL, sys.REL_Y, -3);
    try rec(p[1], sys.EV_SYN, sys.SYN_REPORT, 0);
    var out: std.ArrayListUnmanaged(Event) = .empty;
    defer out.deinit(t.allocator);
    try inp.read(0, &out, &win);
    try t.expectEqual(@as(f32, 15), out.items[0].motion.x);
    try t.expectEqual(@as(f32, 7), out.items[0].motion.y);
    try rec(p[1], sys.EV_REL, sys.REL_X, 500);
    try rec(p[1], sys.EV_SYN, sys.SYN_REPORT, 0);
    out.clearRetainingCapacity();
    try inp.read(0, &out, &win);
    try t.expectEqual(@as(f32, 99), out.items[0].motion.x);
}

test "evdev: a held key repeats on the manual clock" {
    const p = try pipePair();
    defer _ = linux.close(p[1]);
    var win: Window = .{ .size = .{ .w = 100, .h = 100 } };
    var inp = Input.init(t.allocator, .{}, win.size);
    defer inp.deinit();
    try inp.addFd(p[0], .keyboard, null);
    try rec(p[1], sys.EV_KEY, 30, 1);
    var out: std.ArrayListUnmanaged(Event) = .empty;
    defer out.deinit(t.allocator);
    try inp.read(0, &out, &win);
    out.clearRetainingCapacity();
    try inp.tick(399, &out, &win);
    try t.expectEqual(@as(usize, 0), out.items.len);
    try inp.tick(400, &out, &win);
    try t.expectEqual(@as(usize, 1), out.items.len);
    try t.expect(out.items[0].key.repeat);
    try inp.tick(480, &out, &win);
    try t.expectEqual(@as(usize, 3), out.items.len);
    try rec(p[1], sys.EV_KEY, 30, 0);
    out.clearRetainingCapacity();
    try inp.read(500, &out, &win);
    out.clearRetainingCapacity();
    try inp.tick(900, &out, &win);
    try t.expectEqual(@as(usize, 0), out.items.len);
}

test "evdev: a touch panel goes through Touch" {
    const p = try pipePair();
    defer _ = linux.close(p[1]);
    var win: Window = .{ .size = .{ .w = 800, .h = 480 } };
    var inp = Input.init(t.allocator, .{}, win.size);
    defer inp.deinit();
    try inp.addFd(p[0], .touch, .{ .{ .min = 0, .max = 4095 }, .{ .min = 0, .max = 4095 } });
    try rec(p[1], sys.EV_ABS, sys.ABS_X, 2048);
    try rec(p[1], sys.EV_ABS, sys.ABS_Y, 2048);
    try rec(p[1], sys.EV_KEY, sys.BTN_TOUCH, 1);
    try rec(p[1], sys.EV_SYN, sys.SYN_REPORT, 0);
    try rec(p[1], sys.EV_KEY, sys.BTN_TOUCH, 0);
    try rec(p[1], sys.EV_SYN, sys.SYN_REPORT, 0);
    var out: std.ArrayListUnmanaged(Event) = .empty;
    defer out.deinit(t.allocator);
    try inp.read(10, &out, &win);
    try t.expect(out.items[0] == .motion);
    try t.expect(out.items[1].button.pressed);
    try t.expect(!out.items[2].button.pressed);
    try t.expect(out.items[3] == .leave);
    try t.expect(@abs(out.items[0].motion.x - 400) < 1);
}

test "evdev: a device that is gone is removed, and a quiet device stays" {
    const quiet = try pipePair();
    defer _ = linux.close(quiet[1]);
    const gone = try pipePair();
    var win: Window = .{ .size = .{ .w = 100, .h = 100 } };
    var inp = Input.init(t.allocator, .{}, win.size);
    defer inp.deinit();
    try inp.addFd(quiet[0], .keyboard, null);
    try inp.addFd(gone[0], .keyboard, null);
    var out: std.ArrayListUnmanaged(Event) = .empty;
    defer out.deinit(t.allocator);
    try inp.read(0, &out, &win);
    try t.expectEqual(@as(usize, 2), inp.devices.items.len);
    // The write end closes, as when a device is unplugged: the read gives the end of the file.
    _ = linux.close(gone[1]);
    try inp.read(0, &out, &win);
    try t.expectEqual(@as(usize, 1), inp.devices.items.len);
    try t.expectEqual(quiet[0], inp.devices.items[0].fd);
}
