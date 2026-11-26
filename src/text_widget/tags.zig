//! The tags of the `text` widget: a list of tags in the order of their
//! priority, the lowest first. Each tag has a sorted list of ranges of
//! the buffer, and its options as the script gave them.
//!
//! The ranges of a tag do not overlap and do not touch: an add merges a
//! new range with each range that it overlaps or touches, and a remove
//! cuts the ranges. A lookup of a position is a binary search of the
//! ranges of each tag.
//!
//! An insert at a position inside a range makes the range longer, so the
//! new text gets the tags that the characters before and after it both
//! have. An insert at the start of a range moves the range. A delete
//! moves the ends of the ranges to the start of the deleted text and
//! drops the ranges that become empty.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const buffer = @import("buffer.zig");
const Pos = buffer.Pos;

pub const Range = struct { a: Pos, z: Pos };

/// The names of the tag options of `wish` 8.6.16, in its order.
pub const option_names = [_][]const u8{
    "-background",   "-bgstipple",        "-borderwidth",      "-elide",        "-fgstipple",
    "-font",         "-foreground",       "-justify",          "-lmargin1",     "-lmargin2",
    "-lmargincolor", "-offset",           "-overstrike",       "-overstrikefg", "-relief",
    "-rmargin",      "-rmargincolor",     "-selectbackground", "-selectforeground", "-spacing1",
    "-spacing2",     "-spacing3",         "-tabs",             "-tabstyle",     "-underline",
    "-underlinefg",  "-wrap",
};

pub const Opt = enum(u8) {
    background,
    bgstipple,
    borderwidth,
    elide,
    fgstipple,
    font,
    foreground,
    justify,
    lmargin1,
    lmargin2,
    lmargincolor,
    offset,
    overstrike,
    overstrikefg,
    relief,
    rmargin,
    rmargincolor,
    selectbackground,
    selectforeground,
    spacing1,
    spacing2,
    spacing3,
    tabs,
    tabstyle,
    underline,
    underlinefg,
    wrap,
};

pub const n_opts = option_names.len;

/// The value of one tag option for the paint and the layout.
pub const Value = union(enum) {
    none,
    color: @import("../geom.zig").Color,
    pixels: i32,
    boolean: bool,
    word: u8,
    text: void,
};

pub const Tag = struct {
    name: []u8,
    ranges: std.ArrayListUnmanaged(Range) = .empty,
    /// The text of each option, or empty when the option is not set.
    text: [n_opts][]u8 = @splat(&.{}),
    value: [n_opts]Value = @splat(.none),

    pub fn isSet(t: *const Tag, o: Opt) bool {
        return t.value[@intFromEnum(o)] != .none;
    }

    pub fn get(t: *const Tag, o: Opt) Value {
        return t.value[@intFromEnum(o)];
    }

    /// The index of the first range that ends after `p`.
    pub fn after(t: *const Tag, p: Pos) usize {
        var lo: usize = 0;
        var hi: usize = t.ranges.items.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (p.lt(t.ranges.items[mid].z)) hi = mid else lo = mid + 1;
        }
        return lo;
    }

    /// True when the character at `p` has the tag.
    pub fn has(t: *const Tag, p: Pos) bool {
        const i = t.after(p);
        return i < t.ranges.items.len and !p.lt(t.ranges.items[i].a);
    }

    /// The first position after `p` where the tag starts or ends, or null.
    pub fn nextEdge(t: *const Tag, p: Pos) ?Pos {
        const i = t.after(p);
        if (i >= t.ranges.items.len) return null;
        const r = t.ranges.items[i];
        return if (p.lt(r.a)) r.a else r.z;
    }

    pub fn add(t: *Tag, gpa: std.mem.Allocator, a: Pos, z: Pos) !void {
        if (!a.lt(z)) return;
        // The ranges from `i` to `j` overlap or touch the new range.
        var i: usize = 0;
        while (i < t.ranges.items.len and t.ranges.items[i].z.lt(a)) i += 1;
        var j = i;
        var na = a;
        var nz = z;
        while (j < t.ranges.items.len and !z.lt(t.ranges.items[j].a)) : (j += 1) {
            if (t.ranges.items[j].a.lt(na)) na = t.ranges.items[j].a;
            if (nz.lt(t.ranges.items[j].z)) nz = t.ranges.items[j].z;
        }
        try t.ranges.replaceRange(gpa, i, j - i, &.{.{ .a = na, .z = nz }});
    }

    pub fn remove(t: *Tag, gpa: std.mem.Allocator, a: Pos, z: Pos) !void {
        if (!a.lt(z)) return;
        var out: std.ArrayListUnmanaged(Range) = .empty;
        errdefer out.deinit(gpa);
        for (t.ranges.items) |r| {
            if (!a.lt(r.z) or !r.a.lt(z)) {
                try out.append(gpa, r);
                continue;
            }
            if (r.a.lt(a)) try out.append(gpa, .{ .a = r.a, .z = a });
            if (z.lt(r.z)) try out.append(gpa, .{ .a = z, .z = r.z });
        }
        t.ranges.deinit(gpa);
        t.ranges = out;
    }

    fn deinit(t: *Tag, gpa: std.mem.Allocator) void {
        gpa.free(t.name);
        t.ranges.deinit(gpa);
        for (t.text) |s| gpa.free(s);
        gpa.destroy(t);
    }
};

pub const TagSet = struct {
    /// The tags, the lowest priority first.
    order: std.ArrayListUnmanaged(*Tag) = .empty,

    pub fn deinit(s: *TagSet, gpa: std.mem.Allocator) void {
        for (s.order.items) |t| t.deinit(gpa);
        s.order.deinit(gpa);
    }

    pub fn find(s: *const TagSet, name: []const u8) ?*Tag {
        for (s.order.items) |t| if (std.mem.eql(u8, t.name, name)) return t;
        return null;
    }

    pub fn priority(s: *const TagSet, tag: *const Tag) usize {
        for (s.order.items, 0..) |t, i| if (t == tag) return i;
        return 0;
    }

    /// The tag with a name. A new tag has the highest priority.
    pub fn ensure(s: *TagSet, gpa: std.mem.Allocator, name: []const u8) !*Tag {
        if (s.find(name)) |t| return t;
        const t = try gpa.create(Tag);
        errdefer gpa.destroy(t);
        t.* = .{ .name = try gpa.dupe(u8, name) };
        errdefer gpa.free(t.name);
        try s.order.append(gpa, t);
        return t;
    }

    pub fn delete(s: *TagSet, gpa: std.mem.Allocator, tag: *Tag) void {
        const i = s.priority(tag);
        _ = s.order.orderedRemove(i);
        tag.deinit(gpa);
    }

    /// Moves a tag to just above `ref`, or to the top.
    pub fn raise(s: *TagSet, tag: *Tag, ref: ?*Tag) void {
        _ = s.order.orderedRemove(s.priority(tag));
        const at = if (ref) |r| s.priority(r) + 1 else s.order.items.len;
        s.order.insertAssumeCapacity(at, tag);
    }

    /// Moves a tag to just below `ref`, or to the bottom.
    pub fn lower(s: *TagSet, tag: *Tag, ref: ?*Tag) void {
        _ = s.order.orderedRemove(s.priority(tag));
        const at = if (ref) |r| s.priority(r) else 0;
        s.order.insertAssumeCapacity(at, tag);
    }

    /// Moves the ranges for an insert from `p` to `e`.
    pub fn onInsert(s: *TagSet, p: Pos, e: Pos) void {
        for (s.order.items) |t| {
            for (t.ranges.items) |*r| {
                if (!p.lt(r.z)) continue;
                r.z = buffer.shiftInsert(r.z, p, e);
                if (!r.a.lt(p)) r.a = buffer.shiftInsert(r.a, p, e);
            }
        }
    }

    /// Moves the ranges for a delete from `a` to `z`.
    pub fn onDelete(s: *TagSet, a: Pos, z: Pos) void {
        for (s.order.items) |t| {
            var k: usize = 0;
            for (t.ranges.items) |r| {
                const nr: Range = .{ .a = buffer.shiftDelete(r.a, a, z), .z = buffer.shiftDelete(r.z, a, z) };
                if (!nr.a.lt(nr.z)) continue;
                if (k > 0 and !t.ranges.items[k - 1].z.lt(nr.a)) {
                    t.ranges.items[k - 1].z = nr.z;
                    continue;
                }
                t.ranges.items[k] = nr;
                k += 1;
            }
            t.ranges.shrinkRetainingCapacity(k);
        }
    }
};

const t_ = std.testing;

fn pos(l: u32, c: u32) Pos {
    return .{ .line = l, .ch = c };
}

test "textw tags: add, remove, insert, and delete" {
    const gpa = t_.allocator;
    var s: TagSet = .{};
    defer s.deinit(gpa);
    const a = try s.ensure(gpa, "a");
    try a.add(gpa, pos(0, 0), pos(0, 5));
    try a.add(gpa, pos(1, 0), pos(1, 3));
    try a.add(gpa, pos(0, 4), pos(0, 8));
    try t_.expectEqual(@as(usize, 2), a.ranges.items.len);
    try t_.expectEqual(pos(0, 8), a.ranges.items[0].z);
    try a.remove(gpa, pos(0, 2), pos(0, 3));
    try t_.expectEqual(@as(usize, 3), a.ranges.items.len);
    try t_.expect(a.has(pos(0, 1)) and !a.has(pos(0, 2)) and a.has(pos(0, 3)));
    // Inside a range: the range grows. At its start: the range moves.
    s.onInsert(pos(0, 1), pos(0, 3));
    try t_.expectEqual(pos(0, 4), a.ranges.items[0].z);
    s.onInsert(pos(0, 0), pos(0, 2));
    try t_.expectEqual(pos(0, 2), a.ranges.items[0].a);
    s.onDelete(pos(0, 0), pos(1, 0));
    try t_.expectEqual(@as(usize, 1), a.ranges.items.len);
    try t_.expectEqual(Range{ .a = pos(0, 0), .z = pos(0, 3) }, a.ranges.items[0]);
}
