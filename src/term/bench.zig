//! The parse benchmark of the terminal cores: `zig build term-bench`.
//!
//! The input is 8 MiB of generated terminal output: lines of ASCII
//! text, SGR colors of the 16-color, 256-color, and RGB forms, cursor
//! moves, erases, and CJK wide characters, with a fixed seed. Each core
//! gets the input in chunks of 4 KiB on an 80 by 24 screen with 10,000
//! lines of scrollback. The time is the best of 5 runs. The old core is
//! `screen.zig`, and the new core is `ztcl.vt.Term` on libghostty-vt.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const vt = @import("ztcl").vt;
const Screen = @import("screen.zig").Screen;

pub const std_options: std.Options = .{ .logFn = vt.noLog };

fn input(a: std.mem.Allocator, size: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var rng = std.Random.DefaultPrng.init(0x7a6b);
    const r = rng.random();
    const words = [_][]const u8{ "the", "terminal", "parser", "reads", "bytes", "and", "cells", "change", "zig", "tcl" };
    while (out.items.len < size) {
        switch (r.uintLessThan(u8, 10)) {
            0 => try out.print(a, "\x1b[{d};{d}H", .{ r.uintLessThan(u8, 24) + 1, r.uintLessThan(u8, 80) + 1 }),
            1 => try out.print(a, "\x1b[3{d}m", .{r.uintLessThan(u8, 8)}),
            2 => try out.print(a, "\x1b[38;5;{d}m", .{r.int(u8)}),
            3 => try out.print(a, "\x1b[38;2;{d};{d};{d}m", .{ r.int(u8), r.int(u8), r.int(u8) }),
            4 => try out.appendSlice(a, "\x1b[0m\x1b[K"),
            5 => try out.appendSlice(a, "\u{4e2d}\u{6587}\u{5b57}"),
            else => {
                for (0..8) |_| {
                    try out.appendSlice(a, words[r.uintLessThan(usize, words.len)]);
                    try out.append(a, ' ');
                }
                if (r.boolean()) try out.appendSlice(a, "\r\n");
            },
        }
    }
    return out.items;
}

fn best(comptime f: anytype, io: std.Io, gpa: std.mem.Allocator, data: []const u8) !u64 {
    var low: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        const t0 = std.Io.Clock.awake.now(io);
        try f(gpa, data);
        const ns = t0.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds();
        low = @min(low, @as(u64, @intCast(ns)));
    }
    return low;
}

fn runOld(gpa: std.mem.Allocator, data: []const u8) !void {
    var s = try Screen.init(gpa, 80, 24);
    defer s.deinit();
    var i: usize = 0;
    while (i < data.len) : (i += 4096) s.write(data[i..@min(data.len, i + 4096)]);
}

fn runNew(gpa: std.mem.Allocator, data: []const u8) !void {
    const t = try vt.Term.create(gpa, 80, 24, 10000);
    defer t.destroy();
    var i: usize = 0;
    while (i < data.len) : (i += 4096) t.write(data[i..@min(data.len, i + 4096)]);
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const data = try input(arena.allocator(), 8 << 20);
    const old = try best(runOld, init.io, gpa, data);
    const new = try best(runNew, init.io, gpa, data);
    const mb = @as(f64, @floatFromInt(data.len)) / (1 << 20);
    std.debug.print("bytes {d}\nscreen.zig    {d:.1} ms  {d:.1} MiB/s\nlibghostty-vt {d:.1} ms  {d:.1} MiB/s\n", .{
        data.len,
        @as(f64, @floatFromInt(old)) / 1e6,
        mb / (@as(f64, @floatFromInt(old)) / 1e9),
        @as(f64, @floatFromInt(new)) / 1e6,
        mb / (@as(f64, @floatFromInt(new)) / 1e9),
    });
}
