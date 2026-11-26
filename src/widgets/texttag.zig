//! The subcommand `tag` of the `text` widget, and the bindings of tags.
//!
//! The options of a tag go through the parse of `options.zig` with the
//! specs below, so a bad value gives the message of `wish`. The tag
//! keeps the text of each option for `tag cget` and `tag configure`,
//! and a parsed value for the paint. An empty text clears an option.
//!
//! The tag `sel` always exists. Its options show the selection options
//! of the widget until a script sets them with `tag configure`, and the
//! paint then uses the colors of the part `::selection` of the theme.
//!
//! The bindings of the tags are in a table of the widget. The event
//! hook of the class moves the mark `current` to the character under
//! the pointer when no button is down. It sends `<Leave>` to the tags
//! that the old character has and the new one does not, and `<Enter>`
//! to the new tags. A button, key, wheel, or virtual event runs the
//! bindings of the tags of `current`, the lowest priority first.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const widget = @import("../widget.zig");
const options = @import("../options.zig");
const bind = @import("../bind.zig");
const text = @import("text.zig");
const tags_mod = @import("../text_widget/tags.zig");
const buffer = @import("../text_widget/buffer.zig");
const index = @import("../text_widget/index.zig");
const Spec = options.Spec;
const Widget = widget.Widget;
const Value = ztcl.Value;
const Pos = buffer.Pos;
const Tag = tags_mod.Tag;

const wrap_words = [_][]const u8{ "char", "none", "word", "" };
const tabstyle_words = [_][]const u8{ "tabular", "wordprocessor", "" };

/// The specs for the parse of each tag option, in the order of
/// `tags.option_names`. Each one accepts an empty text.
pub const specs = [_]Spec{
    .{ .name = "-background", .type = .color, .allow_empty = true },
    .{ .name = "-bgstipple", .type = .string, .allow_empty = true },
    .{ .name = "-borderwidth", .type = .pixels, .allow_empty = true },
    .{ .name = "-elide", .type = .boolean, .allow_empty = true },
    .{ .name = "-fgstipple", .type = .string, .allow_empty = true },
    .{ .name = "-font", .type = .font, .allow_empty = true },
    .{ .name = "-foreground", .type = .color, .allow_empty = true },
    .{ .name = "-justify", .type = .justify, .allow_empty = true },
    .{ .name = "-lmargin1", .type = .pixels, .allow_empty = true },
    .{ .name = "-lmargin2", .type = .pixels, .allow_empty = true },
    .{ .name = "-lmargincolor", .type = .color, .allow_empty = true },
    .{ .name = "-offset", .type = .pixels, .allow_empty = true },
    .{ .name = "-overstrike", .type = .boolean, .allow_empty = true },
    .{ .name = "-overstrikefg", .type = .color, .allow_empty = true },
    .{ .name = "-relief", .type = .relief, .allow_empty = true },
    .{ .name = "-rmargin", .type = .pixels, .allow_empty = true },
    .{ .name = "-rmargincolor", .type = .color, .allow_empty = true },
    .{ .name = "-selectbackground", .type = .color, .allow_empty = true },
    .{ .name = "-selectforeground", .type = .color, .allow_empty = true },
    .{ .name = "-spacing1", .type = .pixels, .allow_empty = true },
    .{ .name = "-spacing2", .type = .pixels, .allow_empty = true },
    .{ .name = "-spacing3", .type = .pixels, .allow_empty = true },
    .{ .name = "-tabs", .type = .string, .allow_empty = true },
    .{ .name = "-tabstyle", .type = .word, .words = &tabstyle_words, .allow_empty = true },
    .{ .name = "-underline", .type = .boolean, .allow_empty = true },
    .{ .name = "-underlinefg", .type = .color, .allow_empty = true },
    .{ .name = "-wrap", .type = .word, .words = &wrap_words, .allow_empty = true },
};

comptime {
    for (specs, tags_mod.option_names) |s, n| std.debug.assert(std.mem.eql(u8, s.name, n));
}

const tab_words = [_][]const u8{ "left", "right", "center", "numeric" };

/// Checks a list of tab stops: screen distances, each with an optional
/// alignment.
pub fn checkTabs(w: *const Widget, it: *ztcl.Interp, s: []const u8) ztcl.Error!void {
    const items = try it.list(.{ .str = s });
    var prev_pixels = false;
    for (items) |v| {
        const word = try it.str(v);
        if (options.parsePixels(word, w.app.scaling) != null) {
            prev_pixels = true;
            continue;
        }
        if (!prev_pixels) return it.fail("bad screen distance \"{s}\"", .{word});
        var ok = false;
        for (tab_words) |tw| if (word.len > 0 and std.mem.startsWith(u8, tw, word)) {
            ok = true;
        };
        if (!ok) return it.fail("bad tab alignment \"{s}\": must be left, right, center, or numeric", .{word});
        prev_pixels = false;
    }
}

/// Sets one option of a tag from its text.
pub fn setOption(w: *Widget, it: *ztcl.Interp, tag: *Tag, i: usize, s: []const u8) ztcl.Error!void {
    var norm: []const u8 = s;
    const parsed = try options.parseValue(w, it, specs[i], s, &norm);
    if (i == @intFromEnum(tags_mod.Opt.tabs) and s.len > 0) try checkTabs(w, it, s);
    const gpa = w.app.gpa;
    const copy = try gpa.dupe(u8, s);
    gpa.free(tag.text[i]);
    tag.text[i] = copy;
    tag.value[i] = if (s.len == 0) .none else switch (parsed) {
        .color => |c| .{ .color = c },
        .pixels => |p| .{ .pixels = p },
        .boolean => |b| .{ .boolean = b },
        .word => |x| .{ .word = x },
        .justify => |j| .{ .word = @intFromEnum(j) },
        .relief => |r| .{ .word = @intFromEnum(r) },
        else => .text,
    };
}

/// Sets the text of an option of `sel` with no parsed value, so that the
/// paint still uses the colors of the theme.
pub fn showOnly(w: *Widget, tag: *Tag, o: tags_mod.Opt, s: []const u8) !void {
    const gpa = w.app.gpa;
    const i = @intFromEnum(o);
    const copy = try gpa.dupe(u8, s);
    gpa.free(tag.text[i]);
    tag.text[i] = copy;
    tag.value[i] = .none;
}

fn tagOrFail(w: *Widget, it: *ztcl.Interp, v: Value) ztcl.Error!*Tag {
    const name = try it.str(v);
    return text.data(w).buf.tags.find(name) orelse it.fail("tag \"{s}\" isn't defined in text widget", .{name});
}

fn findOpt(it: *ztcl.Interp, name: []const u8) ztcl.Error!usize {
    return options.find(it, &specs, name);
}

fn optItem(a: std.mem.Allocator, tag: *const Tag, i: usize) !Value {
    const vals = try a.alloc(Value, 5);
    vals[0] = .{ .str = specs[i].name };
    vals[1] = Value.empty;
    vals[2] = Value.empty;
    vals[3] = Value.empty;
    vals[4] = .{ .str = try a.dupe(u8, tag.text[i]) };
    return try ztcl.value.wrapList(a, vals);
}

/// Adds or removes a tag on the ranges of `args`: pairs of indexes, or
/// one index for one character.
fn changeRanges(w: *Widget, it: *ztcl.Interp, tag: *Tag, args: []const Value, add: bool) ztcl.Error!void {
    const d = text.data(w);
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        const a = try text.getIndex(w, it, args[i]);
        const z = if (i + 1 < args.len) try text.getIndex(w, it, args[i + 1]) else d.buf.forward(a, 1);
        if (!a.lt(z)) continue;
        if (add) try tag.add(w.app.gpa, a, z) else try tag.remove(w.app.gpa, a, z);
    }
    text.tagsChanged(w);
}

const sub_names = [_][]const u8{ "add", "bind", "cget", "configure", "delete", "lower", "names", "nextrange", "prevrange", "raise", "ranges", "remove" };

pub fn cmdTag(w: *Widget, it: *ztcl.Interp, argv: []const Value) ztcl.Error!Value {
    const d = text.data(w);
    const a = it.alloc();
    const gpa = w.app.gpa;
    const path = w.path;
    if (argv.len < 3) return it.fail("wrong # args: should be \"{s} tag option ?arg ...?\"", .{path});
    const sub = try it.str(argv[2]);
    const which = text.unique(&sub_names, sub) orelse return it.fail("bad tag option \"{s}\": must be add, bind, cget, configure, delete, lower, names, nextrange, prevrange, raise, ranges, or remove", .{sub});
    const args = argv[3..];
    switch (which) {
        0, 11 => {
            const word = if (which == 0) "add" else "remove";
            if (args.len < 2) return it.fail("wrong # args: should be \"{s} tag {s} tagName index1 ?index2 index1 index2 ...?\"", .{ path, word });
            const name = try it.str(args[0]);
            const tag = if (which == 0) try d.buf.tags.ensure(gpa, name) else d.buf.tags.find(name) orelse {
                // `wish` checks the indexes of an unknown tag.
                for (args[1..]) |v| _ = try text.getIndex(w, it, v);
                return Value.empty;
            };
            try changeRanges(w, it, tag, args[1..], which == 0);
            return Value.empty;
        },
        1 => return cmdBind(w, it, args),
        2 => {
            if (args.len != 2) return it.fail("wrong # args: should be \"{s} tag cget tagName option\"", .{path});
            const tag = try tagOrFail(w, it, args[0]);
            const i = try findOpt(it, try it.str(args[1]));
            return .{ .str = try a.dupe(u8, tag.text[i]) };
        },
        3 => {
            if (args.len < 1) return it.fail("wrong # args: should be \"{s} tag configure tagName ?-option? ?value? ?-option value ...?\"", .{path});
            const tag = try d.buf.tags.ensure(gpa, try it.str(args[0]));
            if (args.len == 1) {
                const vals = try a.alloc(Value, specs.len);
                for (vals, 0..) |*v, i| v.* = try optItem(a, tag, i);
                return try ztcl.value.wrapList(a, vals);
            }
            if (args.len == 2) return try optItem(a, tag, try findOpt(it, try it.str(args[1])));
            var k: usize = 1;
            while (k < args.len) : (k += 2) {
                const n = try it.str(args[k]);
                const i = try findOpt(it, n);
                if (k + 1 >= args.len) return it.fail("value for \"{s}\" missing", .{n});
                try setOption(w, it, tag, i, try it.str(args[k + 1]));
            }
            text.tagsChanged(w);
            return Value.empty;
        },
        4 => {
            if (args.len < 1) return it.fail("wrong # args: should be \"{s} tag delete tagName ?tagName ...?\"", .{path});
            for (args) |v| {
                const name = try it.str(v);
                const tag = d.buf.tags.find(name) orelse continue;
                if (std.mem.eql(u8, name, "sel")) {
                    tag.ranges.clearRetainingCapacity();
                    continue;
                }
                d.bindings.removeTag(name);
                text.forgetTag(w, name);
                d.buf.tags.delete(gpa, tag);
            }
            text.tagsChanged(w);
            return Value.empty;
        },
        5, 9 => {
            const word = if (which == 5) "lower" else "raise";
            const what = if (which == 5) "belowThis" else "aboveThis";
            if (args.len != 1 and args.len != 2) return it.fail("wrong # args: should be \"{s} tag {s} tagName ?{s}?\"", .{ path, word, what });
            const tag = try tagOrFail(w, it, args[0]);
            const ref = if (args.len == 2) try tagOrFail(w, it, args[1]) else null;
            if (ref == tag) return Value.empty;
            if (which == 5) d.buf.tags.lower(tag, ref) else d.buf.tags.raise(tag, ref);
            text.tagsChanged(w);
            return Value.empty;
        },
        6 => {
            if (args.len > 1) return it.fail("wrong # args: should be \"{s} tag names ?index?\"", .{path});
            var out: std.ArrayList(Value) = .empty;
            const at: ?Pos = if (args.len == 1) try text.getIndex(w, it, args[0]) else null;
            for (d.buf.tags.order.items) |tag| {
                if (at) |p| if (!tag.has(p)) continue;
                try out.append(a, .{ .str = try a.dupe(u8, tag.name) });
            }
            return try ztcl.value.newList(a, out.items);
        },
        7, 8 => {
            const word = if (which == 7) "nextrange" else "prevrange";
            if (args.len != 2 and args.len != 3) return it.fail("wrong # args: should be \"{s} tag {s} tagName index1 ?index2?\"", .{ path, word });
            const p = try text.getIndex(w, it, args[1]);
            const limit: ?Pos = if (args.len == 3) try text.getIndex(w, it, args[2]) else null;
            const tag = d.buf.tags.find(try it.str(args[0])) orelse return Value.empty;
            var found: ?tags_mod.Range = null;
            if (which == 7) {
                const z = limit orelse d.buf.end();
                for (tag.ranges.items) |r| {
                    if (r.a.lt(p)) continue;
                    if (r.a.lt(z)) found = r;
                    break;
                }
            } else {
                const z = limit orelse Pos{};
                var k = tag.ranges.items.len;
                while (k > 0) {
                    k -= 1;
                    const r = tag.ranges.items[k];
                    if (!r.a.lt(p)) continue;
                    if (!r.a.lt(z)) found = r;
                    break;
                }
            }
            const r = found orelse return Value.empty;
            var b1: [32]u8 = undefined;
            var b2: [32]u8 = undefined;
            const vals = try a.alloc(Value, 2);
            vals[0] = .{ .str = try a.dupe(u8, index.format(&b1, r.a)) };
            vals[1] = .{ .str = try a.dupe(u8, index.format(&b2, r.z)) };
            return try ztcl.value.wrapList(a, vals);
        },
        else => {
            if (args.len != 1) return it.fail("wrong # args: should be \"{s} tag ranges tagName\"", .{path});
            const tag = d.buf.tags.find(try it.str(args[0])) orelse return Value.empty;
            var out: std.ArrayList(Value) = .empty;
            for (tag.ranges.items) |r| {
                var b1: [32]u8 = undefined;
                try out.append(a, .{ .str = try a.dupe(u8, index.format(&b1, r.a)) });
                try out.append(a, .{ .str = try a.dupe(u8, index.format(&b1, r.z)) });
            }
            return try ztcl.value.newList(a, out.items);
        },
    }
}

fn cmdBind(w: *Widget, it: *ztcl.Interp, args: []const Value) ztcl.Error!Value {
    const d = text.data(w);
    const a = it.alloc();
    if (args.len < 1 or args.len > 3) return it.fail("wrong # args: should be \"{s} tag bind tagName ?sequence? ?command?\"", .{w.path});
    const name = try it.str(args[0]);
    if (args.len == 1) {
        const pats = try d.bindings.list(name, a);
        const vals = try a.alloc(Value, pats.len);
        for (pats, vals) |p, *s| {
            var b: [128]u8 = undefined;
            s.* = .{ .str = try a.dupe(u8, bind.formatPattern(p, &b)) };
        }
        return try ztcl.value.wrapList(a, vals);
    }
    const p = try bind.parsePattern(it, try it.str(args[1]));
    switch (p.type) {
        .key_press, .key_release, .button_press, .button_release, .motion, .enter, .leave, .virtual, .mouse_wheel => {},
        else => return it.fail("requested illegal events; only key, button, motion, enter, leave, and virtual events may be used", .{}),
    }
    if (args.len == 2) return .{ .str = try a.dupe(u8, d.bindings.get(name, p) orelse "") };
    _ = try d.buf.tags.ensure(w.app.gpa, name);
    d.bindings.set(name, p, try it.str(args[2])) catch return error.OutOfMemory;
    return Value.empty;
}

// ---- Events ----

fn buttonsDown(m: anytype) bool {
    return m.button1 or m.button2 or m.button3 or m.button4 or m.button5;
}

/// The names of the tags at a position, the lowest priority first.
fn tagsAt(w: *Widget, p: Pos, a: std.mem.Allocator) ![]const []const u8 {
    const d = text.data(w);
    var out: std.ArrayList([]const u8) = .empty;
    for (d.buf.tags.order.items) |tag| if (tag.has(p)) try out.append(a, try a.dupe(u8, tag.name));
    return out.items;
}

fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

/// Moves `current` to the character under the pointer, with `<Leave>`
/// and `<Enter>` for the tags that change.
fn repick(w: *Widget, ev: *const bind.WidgetEvent) void {
    const d = text.data(w);
    const a = w.app.it.alloc();
    const gpa = w.app.gpa;
    const new: []const []const u8 = if (d.pointer_in) blk: {
        const p = text.nearestChar(w, ev.x, ev.y);
        d.buf.setMark("current", p, null) catch {};
        break :blk tagsAt(w, p, a) catch return;
    } else &.{};
    var gone: std.ArrayList([]const u8) = .empty;
    for (d.cur_tags.items) |n| if (!contains(new, n)) gone.append(a, a.dupe(u8, n) catch return) catch return;
    var came: std.ArrayList([]const u8) = .empty;
    for (new) |n| if (!contains(d.cur_tags.items, n)) came.append(a, n) catch return;
    for (d.cur_tags.items) |n| gpa.free(n);
    d.cur_tags.clearRetainingCapacity();
    for (new) |n| {
        const copy = gpa.dupe(u8, n) catch break;
        d.cur_tags.append(gpa, copy) catch {
            gpa.free(copy);
            break;
        };
    }
    if (gone.items.len > 0) {
        var lv = ev.*;
        lv.type = .leave;
        bind.runTags(w.app, &d.bindings, gone.items, &lv);
        if (!w.alive()) return;
    }
    if (came.items.len > 0) {
        var en = ev.*;
        en.type = .enter;
        bind.runTags(w.app, &d.bindings, came.items, &en);
    }
}

fn runCurrent(w: *Widget, ev: *const bind.WidgetEvent) void {
    const d = text.data(w);
    const a = w.app.it.alloc();
    const p = d.buf.getMark("current").?.pos;
    const list = tagsAt(w, p, a) catch return;
    if (list.len > 0) bind.runTags(w.app, &d.bindings, list, ev);
}

/// The event hook of the class: the bindings of the tags run before the
/// bindings of the widget.
pub fn tagEvent(w: *Widget, ev: *const bind.WidgetEvent) void {
    if (!w.alive()) return;
    const d = text.data(w);
    switch (ev.type) {
        .enter, .motion => {
            d.pointer_in = true;
            if (!buttonsDown(ev.mods)) repick(w, ev);
            if (ev.type == .motion and w.alive()) runCurrent(w, ev);
        },
        .leave => {
            d.pointer_in = false;
            if (!buttonsDown(ev.mods)) repick(w, ev);
        },
        .button_release => {
            runCurrent(w, ev);
            if (!w.alive()) return;
            var m = ev.*;
            m.mods = .{};
            repick(w, &m);
        },
        .button_press, .mouse_wheel, .key_press, .key_release, .virtual => runCurrent(w, ev),
        else => {},
    }
}
