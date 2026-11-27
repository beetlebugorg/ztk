//! A test pointer for a Wayland compositor with wlroots (sway): it makes a
//! virtual pointer (zwlr_virtual_pointer_v1) and does the steps of the
//! command line in order. tests/wayland-drag.sh uses it to send a real
//! drag. Build: zig build test-pointer.
//!
//! Steps, each one or more words:
//!   move X Y    put the pointer at X Y of an 800x600 output at once
//!   glide X Y   move the pointer to X Y in 20 steps over 400 ms
//!   down, up    press or release the left button
//!   wait MS     wait MS milliseconds
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const wire = @import("wire");
const linux = std.os.linux;

const I = struct {
    const registry: u16 = 1;
    const manager: u16 = 2;
    const pointer: u16 = 3;
    const sync_cb: u16 = 4;
};

const width = 800;
const height = 600;
const btn_left = 0x110;

var at: [2]i32 = .{ 0, 0 };

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const env = init.environ_map;
    const c = wire.Conn.connect(gpa, env.get("XDG_RUNTIME_DIR"), env.get("WAYLAND_DISPLAY")) catch {
        std.debug.print("pointer: no Wayland compositor\n", .{});
        return 1;
    };
    defer c.deinit();
    const reg = try c.newObject(I.registry, .main, 0);
    try c.send(1, 1, .{reg});
    var mgr: u32 = 0;
    try roundtrip(c, reg, &mgr);
    if (mgr == 0) {
        std.debug.print("pointer: the compositor has no zwlr_virtual_pointer_manager_v1\n", .{});
        return 77;
    }
    const ptr = try c.newObject(I.pointer, .main, 0);
    // Request 0: create_virtual_pointer(seat, id), with the default seat.
    try c.send(mgr, 0, .{ @as(u32, 0), ptr });
    try c.flush();

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const s = args[i];
        if (std.mem.eql(u8, s, "move") or std.mem.eql(u8, s, "glide")) {
            if (i + 2 >= args.len) return usage();
            const x = try std.fmt.parseInt(i32, args[i + 1], 10);
            const y = try std.fmt.parseInt(i32, args[i + 2], 10);
            i += 2;
            const n: i32 = if (s[0] == 'g') 20 else 1;
            const from = at;
            var k: i32 = 1;
            while (k <= n) : (k += 1) {
                const px = from[0] + @divTrunc((x - from[0]) * k, n);
                const py = from[1] + @divTrunc((y - from[1]) * k, n);
                // Request 1: motion_absolute(time, x, y, x_extent, y_extent); 4: frame.
                try c.send(ptr, 1, .{ now(), @as(u32, @intCast(px)), @as(u32, @intCast(py)), @as(u32, width), @as(u32, height) });
                try c.send(ptr, 4, .{});
                try c.flush();
                if (n > 1) sleepMs(20);
            }
            at = .{ x, y };
        } else if (std.mem.eql(u8, s, "down") or std.mem.eql(u8, s, "up")) {
            // Request 2: button(time, button, state).
            try c.send(ptr, 2, .{ now(), @as(u32, btn_left), @as(u32, if (s[0] == 'd') 1 else 0) });
            try c.send(ptr, 4, .{});
            try c.flush();
        } else if (std.mem.eql(u8, s, "wait")) {
            if (i + 1 >= args.len) return usage();
            sleepMs(try std.fmt.parseInt(u32, args[i + 1], 10));
            i += 1;
        } else return usage();
        // Read and drop the events, so that the socket buffer has room.
        _ = c.read() catch {};
        while (c.next(.main)) |e| c.release(e);
    }
    // Request 8: destroy.
    try c.send(ptr, 8, .{});
    try c.flush();
    return 0;
}

fn usage() u8 {
    std.debug.print("use: pointer [move X Y | glide X Y | down | up | wait MS]...\n", .{});
    return 2;
}

/// Reads the globals until the callback of `wl_display.sync` is done.
fn roundtrip(c: *wire.Conn, reg: u32, mgr: *u32) !void {
    const cb = try c.newObject(I.sync_cb, .main, 0);
    try c.send(1, 0, .{cb});
    try c.flush();
    var waits: u32 = 0;
    while (waits < 50) : (waits += 1) {
        var pfd = [1]linux.pollfd{.{ .fd = c.fd, .events = linux.POLL.IN, .revents = 0 }};
        if (@as(isize, @bitCast(linux.poll(&pfd, 1, 100))) <= 0) continue;
        _ = try c.read();
        while (c.next(.main)) |e| {
            defer c.release(e);
            var a = e.args();
            if (e.iface == I.registry and e.op == 0) {
                const name = a.uint();
                const iface = a.string() orelse continue;
                const version = a.uint();
                if (std.mem.eql(u8, iface, "zwlr_virtual_pointer_manager_v1")) {
                    mgr.* = try c.newObject(I.manager, .main, 0);
                    try c.send(reg, 0, .{ name, wire.Str{ .s = iface }, @min(version, 1), mgr.* });
                }
            } else if (e.iface == I.sync_cb) return;
        }
    }
}

fn now() u32 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @truncate(@as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000);
}

fn sleepMs(ms: u32) void {
    var ts: linux.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
    _ = linux.nanosleep(&ts, null);
}
