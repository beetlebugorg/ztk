//! The embedded windows and images of a `text` widget: the subcommands
//! `window` and `image`, their options, and the text widget as the
//! geometry manager of its embedded windows.
//!
//! Each embed has one character of the buffer, U+FFFC, at its position,
//! so an embed has one unit of index space as `text.n` gives. The list
//! of embeds keeps the position of each one. An insert at or before an
//! embed moves it by the new text, and a delete of the range of an embed
//! removes the embed and deletes its window. `get` and the undo stack
//! leave out the characters of the embeds.
//!
//! The layout gives the character of an embed the width of its window
//! or image with `-padx` on each side, and the height with `-pady` above
//! and below. `-align` places the box in the display line: `baseline`
//! puts its bottom on the baseline, so it adds to the ascent, and `top`,
//! `center`, and `bottom` add the height that the box needs past the
//! text below the line, above it, or on both sides. The paint draws an
//! image in its box. `arrange` gives each window the box of its
//! character in the window of the widget, and unmaps a window outside
//! the content or in elided text. `-create` runs in an idle call when
//! the embed has no window, and the result is the window of the embed.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const num = @import("../base/num.zig");
const geom = @import("../base/geom.zig");
const widget = @import("../widget.zig");
const options = @import("../options.zig");
const layout = @import("../layout.zig");
const buffer = @import("../text_widget/buffer.zig");
const text = @import("text.zig");
const textview = @import("textview.zig");
const tl = @import("textlayout.zig");
const Widget = widget.Widget;
const Value = ztcl.Value;
const Pos = buffer.Pos;

/// The character of an embed in the buffer: U+FFFC, the object replacement character.
pub const char = "\u{FFFC}";
pub const codepoint: u21 = 0xFFFC;

pub const Kind = enum { window, image };

/// The values of `-align`, in the order of the message of `wish`.
pub const Align = enum { baseline, bottom, center, top };
const align_words = [_][]const u8{ "baseline", "bottom", "center", "top" };

const Opt = enum { valign, create, padx, pady, stretch, window, image, name };
const window_opts = [_]Opt{ .valign, .create, .padx, .pady, .stretch, .window };
const image_opts = [_]Opt{ .valign, .padx, .pady, .image, .name };

pub const Embed = struct {
    kind: Kind,
    pos: Pos,
    /// The name of an image embed in the widget: `-name` or `-image`,
    /// with `#n` when the name is in use. Owned.
    id: []u8 = &.{},
    valign: Align = .center,
    padx: i32 = 0,
    pady: i32 = 0,
    stretch: bool = false,
    /// The texts of `-create`, `-image`, and `-name`. Owned.
    create: []u8 = &.{},
    image: []u8 = &.{},
    name: []u8 = &.{},
    win: ?*Widget = null,
    /// True after `-create` ran for the embed with no window.
    created: bool = false,

    fn free(e: *Embed, gpa: std.mem.Allocator) void {
        gpa.free(e.id);
        gpa.free(e.create);
        gpa.free(e.image);
        gpa.free(e.name);
        gpa.destroy(e);
    }
};

fn optName(o: Opt) []const u8 {
    return switch (o) {
        .valign => "-align",
        .create => "-create",
        .padx => "-padx",
        .pady => "-pady",
        .stretch => "-stretch",
        .window => "-window",
        .image => "-image",
        .name => "-name",
    };
}

fn optDefault(o: Opt) []const u8 {
    return switch (o) {
        .valign => "center",
        .padx, .pady, .stretch => "0",
        else => "",
    };
}

fn optValue(a: std.mem.Allocator, e: *const Embed, o: Opt) ![]const u8 {
    return switch (o) {
        .valign => align_words[@intFromEnum(e.valign)],
        .create => e.create,
        .padx => try std.fmt.allocPrint(a, "{d}", .{e.padx}),
        .pady => try std.fmt.allocPrint(a, "{d}", .{e.pady}),
        .stretch => if (e.stretch) "1" else "0",
        .window => if (e.win) |c| c.path else "",
        .image => e.image,
        .name => e.name,
    };
}

fn optsOf(k: Kind) []const Opt {
    return if (k == .window) &window_opts else &image_opts;
}

fn findOpt(it: *ztcl.Interp, k: Kind, s: []const u8) ztcl.Error!Opt {
    for (optsOf(k)) |o| if (std.mem.eql(u8, optName(o), s)) return o;
    var hit: ?Opt = null;
    var n: usize = 0;
    if (s.len > 1) for (optsOf(k)) |o| if (std.mem.startsWith(u8, optName(o), s)) {
        hit = o;
        n += 1;
    };
    if (n == 1) return hit.?;
    return it.fail("unknown option \"{s}\"", .{s});
}

// ---- The list of embeds ----

/// The embed at a position, or null.
pub fn at(w: *const Widget, p: Pos) ?*Embed {
    for (text.data(w).embeds.items) |e| if (e.pos.eql(p)) return e;
    return null;
}

/// True when the character at `p` is the character of an embed.
pub fn isEmbed(w: *const Widget, p: Pos) bool {
    if (text.data(w).embeds.items.len == 0) return false;
    return at(w, p) != null;
}

/// The position of an embedded window by its path, or of an image by its name.
pub fn named(w: *const Widget, name: []const u8) ?Pos {
    for (text.data(w).embeds.items) |e| switch (e.kind) {
        .window => if (e.win) |c| if (std.mem.eql(u8, c.path, name)) return e.pos,
        .image => if (std.mem.eql(u8, e.id, name)) return e.pos,
    };
    return null;
}

/// Moves the embeds at or after `p` past the text from `p` to `e`.
pub fn shiftInsert(w: *Widget, p: Pos, e: Pos) void {
    for (text.data(w).embeds.items) |x| if (!x.pos.lt(p)) {
        x.pos = buffer.shiftInsert(x.pos, p, e);
    };
}

/// Removes the embeds from `a` to `z` and deletes their windows, before
/// the delete of the range.
pub fn deleteIn(w: *Widget, a: Pos, z: Pos) void {
    const d = text.data(w);
    var i: usize = 0;
    while (i < d.embeds.items.len) {
        const e = d.embeds.items[i];
        if (!e.pos.lt(a) and e.pos.lt(z)) {
            _ = d.embeds.orderedRemove(i);
            if (e.win) |c| {
                unmanage(c);
                e.win = null;
                widget.destroy(c);
            }
            e.free(w.app.gpa);
            continue;
        }
        i += 1;
    }
}

/// Moves the embeds after a delete from `a` to `z`.
pub fn shiftDelete(w: *Widget, a: Pos, z: Pos) void {
    for (text.data(w).embeds.items) |x| x.pos = buffer.shiftDelete(x.pos, a, z);
}

/// Frees the embeds when the text widget goes away.
pub fn deinit(w: *Widget) void {
    const d = text.data(w);
    for (d.embeds.items) |e| {
        if (e.win) |c| unmanage(c);
        e.free(w.app.gpa);
    }
    d.embeds.deinit(w.app.gpa);
    if (d.create_idle) |id| _ = w.app.loop.cancel(id);
    d.create_idle = null;
}

/// Adds the text from `a` to `z` to `out`, without the characters of the embeds.
pub fn getText(w: *Widget, a: Pos, z: Pos, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    const d = text.data(w);
    var from = a;
    // The embeds in the range, in the order of the positions.
    var cuts: std.ArrayList(Pos) = .empty;
    defer cuts.deinit(gpa);
    for (d.embeds.items) |e| if (!e.pos.lt(a) and e.pos.lt(z)) try cuts.append(gpa, e.pos);
    std.mem.sort(Pos, cuts.items, {}, struct {
        fn f(_: void, x: Pos, y: Pos) bool {
            return x.lt(y);
        }
    }.f);
    for (cuts.items) |c| {
        if (from.lt(c)) try d.buf.get(from, c, out, gpa);
        from = d.buf.forward(c, 1);
    }
    if (from.lt(z)) try d.buf.get(from, z, out, gpa);
}

// ---- The size and the box ----

/// The size of the window or the image of an embed, with no padding.
pub fn contentSize(w: *Widget, e: *const Embed) geom.Size {
    switch (e.kind) {
        .window => {
            const c = e.win orelse return .{};
            return .{ .w = c.req.w, .h = c.req.h };
        },
        .image => {
            const ph = w.app.images.find(e.image) orelse return .{};
            return .{ .w = @intCast(ph.logicalWidth()), .h = @intCast(ph.logicalHeight()) };
        },
    }
}

/// The box of an embed in its display line, from the left of the content
/// and the top of the display line.
pub fn box(w: *Widget, e: *const Embed, dl: tl.DLine, pc: tl.Piece) geom.Rect {
    const s = contentSize(w, e);
    var h = s.h;
    if (e.kind == .window and e.stretch) h = @max(dl.h - 2 * e.pady, h);
    const y: i32 = switch (e.valign) {
        .top => e.pady,
        .bottom => dl.h - h - e.pady,
        .center => @divTrunc(dl.h - h, 2),
        .baseline => dl.ascent - h - e.pady,
    };
    return .{ .x = pc.x + e.padx, .y = if (e.kind == .window and e.stretch) e.pady else y, .w = s.w, .h = h };
}

// ---- The subcommands ----

/// `window` and `image`.
pub fn cmdEmbed(w: *Widget, it: *ztcl.Interp, argv: []const Value, kind: Kind) ztcl.Error!Value {
    const word = if (kind == .window) "window" else "image";
    if (argv.len < 3) return it.fail("wrong # args: should be \"{s} {s} option ?arg ...?\"", .{ w.path, word });
    const sub = try it.str(argv[2]);
    const subs = [_][]const u8{ "cget", "configure", "create", "names" };
    const which = text.unique(&subs, sub) orelse {
        if (kind == .window) return it.fail("bad window option \"{s}\": must be cget, configure, create, or names", .{sub});
        return it.fail("bad option \"{s}\": must be cget, configure, create, or names", .{sub});
    };
    const a = it.alloc();
    switch (which) {
        0 => {
            if (argv.len != 5) return it.fail("wrong # args: should be \"{s} {s} cget index option\"", .{ w.path, word });
            const e = try embedAt(w, it, argv[3], kind);
            const o = try findOpt(it, kind, try it.str(argv[4]));
            return .{ .str = try a.dupe(u8, try optValue(a, e, o)) };
        },
        1 => {
            if (argv.len < 4) return it.fail("wrong # args: should be \"{s} {s} configure index ?-option value ...?\"", .{ w.path, word });
            const e = try embedAt(w, it, argv[3], kind);
            if (argv.len == 4) {
                var out: std.ArrayList(Value) = .empty;
                for (optsOf(kind)) |o| try out.append(a, try optList(a, e, o));
                return try ztcl.value.newList(a, out.items);
            }
            if (argv.len == 5) return try optList(a, e, try findOpt(it, kind, try it.str(argv[4])));
            try apply(w, it, e, argv[4..]);
            text.repaintView(w);
            return Value.empty;
        },
        2 => {
            if (argv.len < 4) return it.fail("wrong # args: should be \"{s} {s} create index ?-option value ...?\"", .{ w.path, word });
            return try create(w, it, argv[3], argv[4..], kind);
        },
        else => {
            if (argv.len != 3) return it.fail("wrong # args: should be \"{s} {s} names\"", .{ w.path, word });
            var out: std.ArrayList(Value) = .empty;
            for (text.data(w).embeds.items) |e| if (e.kind == kind) switch (kind) {
                .window => if (e.win) |c| try out.append(a, .{ .str = c.path }),
                .image => try out.append(a, .{ .str = e.id }),
            };
            return try ztcl.value.newList(a, out.items);
        },
    }
}

fn optList(a: std.mem.Allocator, e: *const Embed, o: Opt) !Value {
    const vals = [_]Value{ .{ .str = optName(o) }, Value.empty, Value.empty, .{ .str = optDefault(o) }, .{ .str = try a.dupe(u8, try optValue(a, e, o)) } };
    return try ztcl.value.newList(a, &vals);
}

fn embedAt(w: *Widget, it: *ztcl.Interp, v: Value, kind: Kind) ztcl.Error!*Embed {
    const p = try text.getIndex(w, it, v);
    if (at(w, p)) |e| if (e.kind == kind) return e;
    return it.fail("no embedded {s} at index \"{s}\"", .{ if (kind == .window) "window" else "image", try it.str(v) });
}

/// Parsed values of an option list, checked before any change.
const Pending = struct {
    valign: ?Align = null,
    padx: ?i32 = null,
    pady: ?i32 = null,
    stretch: ?bool = null,
    create: ?[]const u8 = null,
    window: ?[]const u8 = null,
    image: ?[]const u8 = null,
    name: ?[]const u8 = null,
};

fn parse(w: *Widget, it: *ztcl.Interp, kind: Kind, pairs: []const Value) ztcl.Error!Pending {
    var p: Pending = .{};
    var i: usize = 0;
    while (i < pairs.len) : (i += 2) {
        const name = try it.str(pairs[i]);
        const o = try findOpt(it, kind, name);
        if (i + 1 >= pairs.len) return it.fail("value for \"{s}\" missing", .{name});
        const v = try it.str(pairs[i + 1]);
        switch (o) {
            .valign => p.valign = @enumFromInt(text.unique(&align_words, v) orelse return it.fail("bad align \"{s}\": must be baseline, bottom, center, or top", .{v})),
            .padx, .pady => {
                const px = options.parsePixels(v, w.app.scaling) orelse return it.fail("bad screen distance \"{s}\"", .{v});
                if (o == .padx) p.padx = px else p.pady = px;
            },
            .stretch => p.stretch = options.parseBool(v) orelse return it.fail("expected boolean value but got \"{s}\"", .{v}),
            .create => p.create = v,
            .window => {
                if (v.len > 0) {
                    const c = w.app.find(v) orelse return it.fail("bad window path name \"{s}\"", .{v});
                    if (c == w or c.isToplevel() or !inside(w, c)) return it.fail("can't embed {s} in {s}", .{ v, w.path });
                }
                p.window = v;
            },
            .image => {
                if (v.len > 0 and w.app.images.find(v) == null) return it.fail("image \"{s}\" doesn't exist", .{v});
                p.image = v;
            },
            .name => p.name = v,
        }
    }
    return p;
}

/// True when the parent of `c` is the text widget or an ancestor of it.
fn inside(w: *const Widget, c: *const Widget) bool {
    const parent = c.parent orelse return false;
    var x: ?*const Widget = w;
    while (x) |y| : (x = y.parent) {
        if (y == parent) return true;
    }
    return false;
}

fn setText(gpa: std.mem.Allocator, slot: *[]u8, v: []const u8) !void {
    const copy = try gpa.dupe(u8, v);
    gpa.free(slot.*);
    slot.* = copy;
}

fn apply(w: *Widget, it: *ztcl.Interp, e: *Embed, pairs: []const Value) ztcl.Error!void {
    const p = try parse(w, it, e.kind, pairs);
    try store(w, e, p);
}

fn store(w: *Widget, e: *Embed, p: Pending) ztcl.Error!void {
    const gpa = w.app.gpa;
    if (p.valign) |v| e.valign = v;
    if (p.padx) |v| e.padx = v;
    if (p.pady) |v| e.pady = v;
    if (p.stretch) |v| e.stretch = v;
    if (p.create) |v| {
        setText(gpa, &e.create, v) catch return error.OutOfMemory;
        e.created = false;
    }
    if (p.image) |v| setText(gpa, &e.image, v) catch return error.OutOfMemory;
    if (p.name) |v| setText(gpa, &e.name, v) catch return error.OutOfMemory;
    if (p.window) |v| try setWindow(w, e, v);
    if (e.kind == .window and e.win == null and e.create.len > 0 and !e.created) scheduleCreate(w);
    textview.noteEdit(w, e.pos.line, 1, 1);
}

fn create(w: *Widget, it: *ztcl.Interp, iv: Value, pairs: []const Value, kind: Kind) ztcl.Error!Value {
    const d = text.data(w);
    const gpa = w.app.gpa;
    var p = try text.getIndex(w, it, iv);
    const pend = try parse(w, it, kind, pairs);
    if (kind == .image and pend.image == null and pend.name == null) return it.fail("Either a \"-name\" or a \"-image\" argument must be provided to the \"image create\" subcommand", .{});
    if (p.line >= d.buf.lineCount()) p = d.buf.last();
    const e = gpa.create(Embed) catch return error.OutOfMemory;
    e.* = .{ .kind = kind, .pos = p };
    if (kind == .image) {
        const base = if (pend.name) |n| (if (n.len > 0) n else pend.image orelse "") else pend.image.?;
        e.id = uniqueId(w, base) catch {
            gpa.destroy(e);
            return error.OutOfMemory;
        };
    }
    // The character goes into the buffer first, so the embed has its place.
    _ = text.insertRaw(w, p, char) catch {
        e.free(gpa);
        return error.OutOfMemory;
    };
    d.embeds.append(gpa, e) catch {
        e.free(gpa);
        return error.OutOfMemory;
    };
    try store(w, e, pend);
    text.repaintView(w);
    return if (kind == .image) .{ .str = try it.alloc().dupe(u8, e.id) } else Value.empty;
}

/// The name of an image embed: `base`, or `base#n` with the first n that is free.
fn uniqueId(w: *Widget, base: []const u8) ![]u8 {
    const gpa = w.app.gpa;
    if (named(w, base) == null) return gpa.dupe(u8, base);
    var n: u32 = 1;
    while (true) : (n += 1) {
        const s = try std.fmt.allocPrint(gpa, "{s}#{d}", .{ base, n });
        if (named(w, s) == null) return s;
        gpa.free(s);
    }
}

// ---- `-create` ----

fn scheduleCreate(w: *Widget) void {
    const d = text.data(w);
    if (d.create_idle != null) return;
    d.create_idle = w.app.loop.addNativeIdle(runCreate, w) catch null;
}

fn runCreate(ctx: ?*anyopaque) void {
    const w: *Widget = @ptrCast(@alignCast(ctx.?));
    const d = text.data(w);
    d.create_idle = null;
    const app = w.app;
    var k: usize = 0;
    while (k < d.embeds.items.len) : (k += 1) {
        const e = d.embeds.items[k];
        if (e.kind != .window or e.win != null or e.create.len == 0 or e.created) continue;
        e.created = true;
        // `%W` is the path of the text widget, and `%%` is one `%`.
        var script: std.ArrayList(u8) = .empty;
        defer script.deinit(app.gpa);
        var i: usize = 0;
        const s = e.create;
        const ok = blk: {
            while (i < s.len) : (i += 1) {
                if (s[i] == '%' and i + 1 < s.len and (s[i + 1] == 'W' or s[i + 1] == '%')) {
                    script.appendSlice(app.gpa, if (s[i + 1] == 'W') w.path else "%") catch break :blk false;
                    i += 1;
                } else script.append(app.gpa, s[i]) catch break :blk false;
            }
            break :blk true;
        };
        if (!ok) return;
        const r = app.it.eval(script.items) catch |err| {
            app.backgroundError(err);
            if (!w.alive()) return;
            continue;
        };
        if (!w.alive()) return;
        const name = app.it.str(r) catch continue;
        // The embed list can change in the script: find the embed again.
        if (std.mem.indexOfScalar(*Embed, d.embeds.items, e) == null) continue;
        const c = app.find(name) orelse continue;
        if (c == w or c.isToplevel() or !inside(w, c)) continue;
        setWindow(w, e, name) catch {};
    }
}

// ---- The geometry manager of the embedded windows ----

pub const manager: layout.Manager = .{
    .name = "text",
    .measure = managerMeasure,
    .arrange = arrange,
    .forget = forget,
    .release = release,
    .has_content = hasContent,
    .propagates = noPropagate,
};

fn managerMeasure(_: *Widget) void {}

fn noPropagate(_: *const Widget) bool {
    return false;
}

fn hasContent(c: *const Widget) bool {
    for (text.data(c).embeds.items) |e| if (e.win != null) return true;
    return false;
}

fn setWindow(w: *Widget, e: *Embed, name: []const u8) ztcl.Error!void {
    if (e.win) |old| unmanage(old);
    e.win = null;
    if (name.len == 0) return;
    const child = w.app.find(name).?;
    try layout.claim(w, &manager);
    w.container_manager = &manager;
    if (child.manager) |m| if (m != &manager) m.forget(child);
    // A window in another embed leaves it.
    for (text.data(w).embeds.items) |x| if (x.win == child) {
        x.win = null;
    };
    child.manager = &manager;
    child.manager_data = w;
    e.win = child;
    w.invalidate(.{ .style = false, .measure = false, .layout = true, .paint = true });
}

fn unmanage(c: *Widget) void {
    if (c.manager == &manager) {
        c.manager = null;
        c.manager_data = null;
        if (c.alive()) layout.setMapped(c, false);
    }
}

fn arrange(container: *Widget) void {
    arrangeAt(container, false);
}

/// Places the embedded windows at the target offsets of the views, or at
/// the offsets that the paint shows (`shown` true) during a smooth scroll.
pub fn arrangeAt(container: *Widget, shown: bool) void {
    const d = text.data(container);
    var arena = std.heap.ArenaAllocator.init(container.app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const c = text.content(container);
    const yoff = if (shown) d.vy.shown(container) else d.vy.pos;
    const xf = if (shown) d.vx.shown(container) else d.vx.pos;
    const xoff: i32 = num.pxRound(xf);
    for (d.embeds.items) |e| {
        const child = e.win orelse continue;
        if (!child.alive()) continue;
        _ = arena.reset(.retain_capacity);
        const r = placeOf(container, e, a) orelse {
            _ = layout.setGeom(child, child.geom, false);
            continue;
        };
        const top = c.y + num.pxRound(@as(f64, @floatFromInt(r.y)) - yoff);
        const rect: geom.Rect = .{ .x = c.x + r.x - xoff, .y = top, .w = r.w, .h = r.h };
        const visible = rect.x + rect.w > c.x and rect.y + rect.h > c.y and rect.x < c.x + c.w and rect.y < c.y + c.h;
        _ = layout.setGeom(child, rect, visible and container.mapped);
    }
}

/// The box of an embed from the left of the content and the top of the
/// text, or null when it is elided.
fn placeOf(w: *Widget, e: *const Embed, a: std.mem.Allocator) ?geom.Rect {
    const para = textview.layoutLine(w, e.pos.line, a) catch return null;
    const top = textview.lineY(w, e.pos.line);
    for (para.lines) |dl| for (dl.pieces) |pc| {
        if (pc.c0 != e.pos.ch or pc.emb == null) continue;
        if (pc.attrs.elide) return null;
        const r = box(w, e, dl, pc);
        return .{ .x = r.x, .y = @intCast(top + dl.y + r.y), .w = r.w, .h = r.h };
    };
    return null;
}

fn forget(c: *Widget) void {
    const w: *Widget = @ptrCast(@alignCast(c.manager_data orelse return));
    if (w.data == null) return;
    for (text.data(w).embeds.items) |e| if (e.win == c) {
        e.win = null;
        textview.noteEdit(w, e.pos.line, 1, 1);
    };
    c.manager = null;
    c.manager_data = null;
    text.repaintView(w);
}

fn release(container: *Widget) void {
    for (text.data(container).embeds.items) |e| if (e.win) |c| {
        unmanage(c);
        e.win = null;
    };
    container.container_manager = null;
}

/// The count of embeds with a window, for the paint of a smooth scroll.
pub fn windowCount(w: *const Widget) usize {
    var n: usize = 0;
    for (text.data(w).embeds.items) |e| if (e.win != null) {
        n += 1;
    };
    return n;
}
