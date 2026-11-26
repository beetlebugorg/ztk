//! Frame statistics. Each stage keeps its last 4 096 samples in a ring.
//! `report` prints the counts and the 50th and 99th percentile of each
//! stage in microseconds. A frame whose stages need more than 100 ms
//! gives one line at once, and at most one line in each second. The
//! caller gives the time, so a test with a manual clock gets exact
//! results.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

pub const Stage = enum { events, style, layout, paint, render };
const stage_count = @typeInfo(Stage).@"enum".field_names.len;
const ring_size = 4096;

pub const slow_us: i64 = 100_000;
pub const late_us: i64 = 16_666;

pub const Stats = struct {
    samples: [stage_count][ring_size]i64 = @splat(@splat(0)),
    counts: [stage_count]u64 = @splat(0),
    started: [stage_count]i64 = @splat(0),
    /// The sum of the stage times of the frame in progress.
    frame_total: i64 = 0,
    frame_stage: [stage_count]i64 = @splat(0),
    frames: u64 = 0,
    /// Frames whose stages needed more than 16 666 us.
    late: u64 = 0,
    /// From the process start to the end of the first draw.
    first_frame_us: i64 = 0,
    last_slow_us: i64 = std.math.minInt(i64) / 2,
    /// The sum and the count of the rows that a backend wrote.
    rows_sum: u64 = 0,
    rows_frames: u64 = 0,
    /// Set by the owner when it wants the slow line. Null: no line.
    slow_out: ?*std.Io.Writer = null,

    pub fn begin(s: *Stats, stage: Stage, now_us: i64) void {
        s.started[@intFromEnum(stage)] = now_us;
    }

    pub fn end(s: *Stats, stage: Stage, now_us: i64) void {
        const i = @intFromEnum(stage);
        const d = @max(now_us - s.started[i], 0);
        s.samples[i][@intCast(s.counts[i] % ring_size)] = d;
        s.counts[i] += 1;
        s.frame_stage[i] += d;
        s.frame_total += d;
    }

    pub fn rows(s: *Stats, n: u64) void {
        s.rows_sum += n;
        s.rows_frames += 1;
    }

    pub fn frameDone(s: *Stats, now_us: i64) void {
        s.frames += 1;
        if (s.frame_total > late_us) s.late += 1;
        if (s.frame_total > slow_us and now_us - s.last_slow_us >= 1_000_000) {
            s.last_slow_us = now_us;
            if (s.slow_out) |w| {
                w.print("ztk: slow frame {d} us: events {d}, style {d}, layout {d}, paint {d}, render {d}\n", .{
                    s.frame_total, s.frame_stage[0], s.frame_stage[1], s.frame_stage[2], s.frame_stage[3], s.frame_stage[4],
                }) catch {};
            }
        }
        s.frame_total = 0;
        s.frame_stage = @splat(0);
    }

    fn percentile(s: *const Stats, stage: usize, p: u32) i64 {
        const n: usize = @intCast(@min(s.counts[stage], ring_size));
        if (n == 0) return 0;
        var buf: [ring_size]i64 = undefined;
        @memcpy(buf[0..n], s.samples[stage][0..n]);
        std.mem.sort(i64, buf[0..n], {}, std.sort.asc(i64));
        return buf[@min((n * p) / 100, n - 1)];
    }

    /// Prints the counts and the 50th and 99th percentile of each stage.
    pub fn report(s: *const Stats, w: *std.Io.Writer) !void {
        try w.print("frames: {d}\nlate: {d}\nfirst frame: {d} us\n", .{ s.frames, s.late, s.first_frame_us });
        inline for (@typeInfo(Stage).@"enum".field_names, 0..) |f_name, i| {
            try w.print("{s}: count {d}, p50 {d} us, p99 {d} us\n", .{ f_name, s.counts[i], s.percentile(i, 50), s.percentile(i, 99) });
        }
        if (s.rows_frames > 0) try w.print("rows written: mean {d}\n", .{s.rows_sum / s.rows_frames});
    }
};

const testing = std.testing;

test "stats: report of three frames" {
    var s: Stats = .{};
    var now: i64 = 0;
    for (0..3) |_| {
        inline for (@typeInfo(Stage).@"enum".field_values) |f_value| {
            const st: Stage = @enumFromInt(f_value);
            s.begin(st, now);
            now += 100;
            s.end(st, now);
        }
        s.frameDone(now);
    }
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try s.report(&w);
    const text = w.buffered();
    try testing.expect(std.mem.indexOf(u8, text, "frames: 3") != null);
    try testing.expect(std.mem.indexOf(u8, text, "paint: count 3, p50 100 us, p99 100 us") != null);
    try testing.expect(std.mem.indexOf(u8, text, "render: count 3") != null);
}

test "stats: a slow frame prints one line in a second" {
    var s: Stats = .{};
    var out_buf: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    s.slow_out = &out;
    s.begin(.paint, 0);
    s.end(.paint, 150_000);
    s.frameDone(150_000);
    s.begin(.paint, 200_000);
    s.end(.paint, 350_000);
    s.frameDone(350_000);
    const text = out.buffered();
    try testing.expect(std.mem.startsWith(u8, text, "ztk: slow frame 150000 us"));
    try testing.expect(std.mem.count(u8, text, "slow frame") == 1);
    try testing.expectEqual(@as(u64, 2), s.late);
}
