//! The trace of `ztk::debug trace`: structured records of events,
//! pointer motion, bindings, commands, option writes, geometry passes, dirty widgets,
//! frames, focus changes, and grabs.
//!
//! A record has a number (`seq`, shared with the option sources), a time,
//! a kind, a widget, a cause, and its fields as the text of a Tcl dict.
//! The cause is the number of the event whose bindings ran when the
//! record was made, so the records of one click are the records with its
//! number. A dirty record also names the option write that made the
//! widget dirty, when there is one. A frame record lists the widgets that
//! became dirty since the last frame of its toplevel.
//!
//! The records are in a ring of a fixed size. A new record replaces the
//! oldest one and counts it as dropped. Each hook first tests the bit of
//! its kind in `mask`, so a hook of a trace that is off costs one test.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");

pub const Kind = enum(u4) { event, motion, binding, command, option, geometry, dirty, frame, focus, grab };
pub const kind_names = "event, motion, binding, command, option, geometry, dirty, frame, focus, grab";
pub const n_kinds = @typeInfo(Kind).@"enum".field_names.len;

pub const Record = struct {
    seq: u64,
    us: i64,
    kind: Kind,
    /// The number of the event whose bindings ran, or 0.
    cause: u64,
    /// Owned.
    widget: []u8,
    /// Owned. The fields as the text of a Tcl dict.
    fields: []u8,

    fn free(r: *Record, gpa: std.mem.Allocator) void {
        gpa.free(r.widget);
        gpa.free(r.fields);
    }
};

pub const default_size = 10_000;

pub const Trace = struct {
    /// One bit for each kind that is on. 0 when the trace is off.
    mask: u16 = 0,
    ring: []Record = &.{},
    /// The index of the oldest record, and the count of records.
    head: usize = 0,
    len: usize = 0,
    dropped: u64 = 0,
    /// The number of the event whose bindings run, or 0.
    cause: u64 = 0,
    /// The number of the last option record of the call that runs, or 0.
    reason: u64 = 0,

    pub inline fn on(t: *const Trace, k: Kind) bool {
        return t.mask & (@as(u16, 1) << @intFromEnum(k)) != 0;
    }

    pub fn start(t: *Trace, gpa: std.mem.Allocator, mask: u16, size: usize) !void {
        if (size != t.ring.len) {
            t.clear(gpa);
            gpa.free(t.ring);
            t.ring = &.{};
            t.ring = try gpa.alloc(Record, @max(size, 1));
        }
        t.mask = mask;
    }

    pub fn clear(t: *Trace, gpa: std.mem.Allocator) void {
        var i: usize = 0;
        while (i < t.len) : (i += 1) t.ring[(t.head + i) % t.ring.len].free(gpa);
        t.head = 0;
        t.len = 0;
        t.dropped = 0;
    }

    pub fn deinit(t: *Trace, gpa: std.mem.Allocator) void {
        t.clear(gpa);
        gpa.free(t.ring);
        t.* = .{};
    }

    /// Adds a record. The strings are copied. A failure to allocate drops it.
    pub fn add(t: *Trace, gpa: std.mem.Allocator, seq: u64, us: i64, kind: Kind, widget: []const u8, fields: []const u8) void {
        if (t.ring.len == 0) return;
        const w = gpa.dupe(u8, widget) catch return;
        const f = gpa.dupe(u8, fields) catch {
            gpa.free(w);
            return;
        };
        const r: Record = .{ .seq = seq, .us = us, .kind = kind, .cause = t.cause, .widget = w, .fields = f };
        if (t.len == t.ring.len) {
            t.ring[t.head].free(gpa);
            t.ring[t.head] = r;
            t.head = (t.head + 1) % t.ring.len;
            t.dropped += 1;
        } else {
            t.ring[(t.head + t.len) % t.ring.len] = r;
            t.len += 1;
        }
    }

    /// The record at position `i`, from the oldest.
    pub fn at(t: *const Trace, i: usize) *const Record {
        return &t.ring[(t.head + i) % t.ring.len];
    }
};

/// The bits of a list of kind names. An unknown name gives null.
pub fn maskOf(names: []const []const u8) ?u16 {
    var m: u16 = 0;
    for (names) |n| {
        if (std.mem.eql(u8, n, "all")) {
            m |= (1 << n_kinds) - 1;
            continue;
        }
        const k = std.meta.stringToEnum(Kind, n) orelse return null;
        m |= @as(u16, 1) << @intFromEnum(k);
    }
    return m;
}

/// A glob match with `*` and `?`, for the widget filter.
pub fn glob(pat: []const u8, s: []const u8) bool {
    var p: usize = 0;
    var i: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;
    while (i < s.len) {
        if (p < pat.len and (pat[p] == '?' or pat[p] == s[i])) {
            p += 1;
            i += 1;
        } else if (p < pat.len and pat[p] == '*') {
            star = p;
            mark = i;
            p += 1;
        } else if (star) |st| {
            p = st + 1;
            mark += 1;
            i = mark;
        } else return false;
    }
    while (p < pat.len and pat[p] == '*') p += 1;
    return p == pat.len;
}

test "glob" {
    try std.testing.expect(glob(".f.*", ".f.ok"));
    try std.testing.expect(glob("*ok", ".f.ok"));
    try std.testing.expect(!glob(".g*", ".f.ok"));
    try std.testing.expect(glob(".?", ".b"));
}
