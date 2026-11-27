//! Widget options: creation options, `configure`, and `cget`.
//! A class has a table of `Spec` values. Each widget has one `Slot` for
//! each spec. `apply` parses all pairs first and writes the slots only
//! when every pair is valid, so a failed `configure` changes nothing.
//! A name matches by exact text, or else by a unique prefix. A synonym
//! resolves to its target. The text of a slot is the text that the
//! script gave, except for a screen distance, which is stored as the
//! rounded count of logical pixels, as `wish` does.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const num = @import("base/num.zig");
const ztcl = @import("ztcl");
const geom = @import("base/geom.zig");
const widget_mod = @import("widget.zig");
const Widget = widget_mod.Widget;
const debug = @import("debug.zig");

pub const Type = enum {
    string,
    int,
    pixels,
    color,
    boolean,
    anchor,
    relief,
    state,
    justify,
    font,
    variable,
    script,
    synonym,
    /// One word of `words`. A bad value gives "bad <name without the dash> ...".
    word,
    /// A floating-point number.
    double,
    /// The name of an image of `image create`, as the first word of a list.
    image,
};

pub const Spec = struct {
    /// "-background"
    name: []const u8,
    /// "background"
    db_name: []const u8 = "",
    /// "Background"
    db_class: []const u8 = "",
    type: Type,
    /// The text form of the default.
    default: []const u8 = "",
    /// True: when the script did not set the option, its value comes
    /// from the computed style (task 09).
    from_style: bool = false,
    /// The target of a synonym, for example "-background".
    target: []const u8 = "",
    /// The words that `state` accepts, for a `state` option.
    words: []const []const u8 = &.{},
    /// The name in the message of a bad `word`, when it is not the option name.
    word_name: []const u8 = "",
    /// An empty string is a valid value.
    allow_empty: bool = false,
    /// The option can be set only when the widget is made.
    create_only: bool = false,
    /// The style property that gives the value when the script did not set the option.
    style_prop: StyleProp = .none,
    /// The option is not in `configure` and a script cannot name it. A
    /// `ttk` class has the options of its classic class this way, so the
    /// shared code reads them with their defaults.
    hidden: bool = false,
};

/// The specs of a `ttk` class: the options of its manual page in their
/// order, then each option of the classic class that is not in the list,
/// hidden.
pub fn withHidden(comptime visible: []const Spec, comptime base: []const Spec) []const Spec {
    comptime {
        @setEvalBranchQuota(100000);
        var out: []const Spec = visible;
        for (base) |b| {
            var have = false;
            for (visible) |v| {
                if (std.mem.eql(u8, v.name, b.name)) have = true;
            }
            if (have) continue;
            var h = b;
            h.hidden = true;
            out = out ++ [_]Spec{h};
        }
        const final = out[0..out.len].*;
        return &final;
    }
}

pub const StyleProp = enum { none, background, border_width };

pub const Anchor = enum { n, ne, e, se, s, sw, w, nw, center };
pub const Relief = enum { flat, groove, raised, ridge, solid, sunken };
pub const Justify = enum { left, center, right };

pub const Parsed = union(enum) {
    none,
    text: []const u8,
    int: i64,
    pixels: i32,
    color: geom.Color,
    boolean: bool,
    anchor: Anchor,
    relief: Relief,
    word: u8,
    justify: Justify,
    double: f64,
};

pub const Slot = struct {
    /// The script set it.
    set: bool = false,
    /// Owned by the widget allocator. The text that the script gave.
    text: []const u8 = "",
    value: Parsed = .none,
    /// The last call that set the option, while `ztk::debug sources` is on.
    src: ?*debug.Source = null,
};

/// The limit of a screen distance in logical pixels.
const max_pixels: f64 = 1 << 24;

/// A number with an optional unit: c (centimeter), i (inch), m
/// (millimeter), p (point). `scaling` is logical pixels for each point.
/// The result is rounded, and limited to +-2^24.
pub fn parsePixels(text: []const u8, scaling: f64) ?i32 {
    if (text.len == 0) return null;
    var digits = text;
    var factor: f64 = 1;
    switch (text[text.len - 1]) {
        'c' => factor = 72.0 / 2.54 * scaling,
        'i' => factor = 72.0 * scaling,
        'm' => factor = 72.0 / 25.4 * scaling,
        'p' => factor = scaling,
        else => {},
    }
    if (factor != 1 or std.mem.indexOfScalar(u8, "cimp", text[text.len - 1]) != null) digits = text[0 .. text.len - 1];
    if (digits.len == 0) return null;
    for (digits) |ch| switch (ch) {
        '0'...'9', '.', '+', '-', 'e', 'E' => {},
        else => return null,
    };
    const v = std.fmt.parseFloat(f64, digits) catch return null;
    if (std.math.isNan(v)) return null;
    const px = std.math.clamp(@round(v * factor), -max_pixels, max_pixels);
    return num.px(@intFromFloat(px));
}

fn matchWord(text: []const u8, words: []const []const u8) ?usize {
    if (text.len == 0) return null;
    var found: ?usize = null;
    for (words, 0..) |wd, i| {
        if (std.mem.eql(u8, wd, text)) return i;
        if (std.mem.startsWith(u8, wd, text)) {
            if (found != null) return null;
            found = i;
        }
    }
    return found;
}

/// The index of an anchor word in `anchor_words`. As in Tk, a start of
/// "center" such as "c" is center.
pub fn anchorIndex(text: []const u8) ?usize {
    for (anchor_words, 0..) |w, i| if (std.mem.eql(u8, w, text)) return i;
    if (text.len > 0 and std.mem.startsWith(u8, "center", text)) return 8;
    return null;
}

pub fn parseBool(text: []const u8) ?bool {
    var buf: [8]u8 = undefined;
    if (text.len == 0 or text.len > buf.len) return null;
    const lower = std.ascii.lowerString(&buf, text);
    if (std.mem.eql(u8, lower, "1")) return true;
    if (std.mem.eql(u8, lower, "0")) return false;
    const yes = [_][]const u8{ "true", "yes", "on" };
    const no = [_][]const u8{ "false", "no", "off" };
    for (yes) |s| if (std.mem.startsWith(u8, s, lower)) {
        // "o" is ambiguous with "off".
        if (lower.len == 1 and lower[0] == 'o') return null;
        return true;
    };
    for (no) |s| if (std.mem.startsWith(u8, s, lower)) {
        if (lower.len == 1 and lower[0] == 'o') return null;
        return false;
    };
    return null;
}

fn joinWords(it: *ztcl.Interp, words: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const a = it.alloc();
    for (words, 0..) |wd, i| {
        // Two words have no comma: "horizontal or vertical".
        if (i > 0) try out.appendSlice(a, if (words.len == 2) " " else ", ");
        if (i + 1 == words.len and words.len > 1) try out.appendSlice(a, "or ");
        try out.appendSlice(a, wd);
    }
    return out.items;
}

const relief_words = [_][]const u8{ "flat", "groove", "raised", "ridge", "solid", "sunken" };
const anchor_words = [_][]const u8{ "n", "ne", "e", "se", "s", "sw", "w", "nw", "center" };
const justify_words = [_][]const u8{ "left", "right", "center" };

/// A double in the form of Tcl: an integral value gets ".0".
pub fn formatDouble(a: std.mem.Allocator, v: f64) ![]const u8 {
    if (v == @trunc(v) and @abs(v) < 1e15) return std.fmt.allocPrint(a, "{d}.0", .{@as(i64, @intFromFloat(v))});
    return std.fmt.allocPrint(a, "{d}", .{v});
}

/// Parses the text of one option. On a bad value it sets the message of
/// `wish` and returns `error.TclError`. A screen distance returns its
/// normalized text in `norm`.
pub fn parseValue(w: *const Widget, it: *ztcl.Interp, spec: Spec, text: []const u8, norm: *[]const u8) ztcl.Error!Parsed {
    norm.* = text;
    if (text.len == 0 and spec.allow_empty and spec.type != .synonym) return .{ .text = text };
    switch (spec.type) {
        .string, .font, .variable, .script => return .{ .text = text },
        .synonym => return .none,
        .int => {
            const v = std.fmt.parseInt(i64, std.mem.trim(u8, text, " "), 0) catch
                return it.fail("expected integer but got \"{s}\"", .{text});
            return .{ .int = v };
        },
        .pixels => {
            const v = parsePixels(text, w.app.scaling) orelse return it.fail("bad screen distance \"{s}\"", .{text});
            norm.* = try std.fmt.allocPrint(it.alloc(), "{d}", .{v});
            return .{ .pixels = v };
        },
        .color => {
            if (text.len == 0 and spec.allow_empty) return .{ .text = text };
            if (geom.Color.parseTk(text)) |c| return .{ .color = c };
            if (text.len > 0 and text[0] == '#') return it.fail("invalid color name \"{s}\"", .{text});
            return it.fail("unknown color name \"{s}\"", .{text});
        },
        .boolean => {
            const b = parseBool(text) orelse return it.fail("expected boolean value but got \"{s}\"", .{text});
            return .{ .boolean = b };
        },
        .anchor => {
            const i = anchorIndex(text) orelse
                return it.fail("{s} anchor \"{s}\": must be n, ne, e, se, s, sw, w, nw, or center", .{ badWord(text, &.{ "n", "ne", "e", "se", "s", "sw", "w", "nw", "center" }), text });
            return .{ .anchor = @enumFromInt(i) };
        },
        .relief => {
            const i = matchWord(text, &relief_words) orelse
                return it.fail("{s} relief \"{s}\": must be flat, groove, raised, ridge, solid, or sunken", .{ badWord(text, &relief_words), text });
            return .{ .relief = @enumFromInt(i) };
        },
        .justify => {
            const i = matchWord(text, &justify_words) orelse
                return it.fail("{s} justification \"{s}\": must be left, right, or center", .{ badWord(text, &justify_words), text });
            return .{ .justify = @enumFromInt(if (i == 1) 2 else if (i == 2) 1 else i) };
        },
        .word => {
            const i = matchWord(text, spec.words) orelse
                return it.fail("{s} {s} \"{s}\": must be {s}", .{ badWord(text, spec.words), if (spec.word_name.len > 0) spec.word_name else spec.name[1..], text, try joinWords(it, spec.words) });
            return .{ .word = @intCast(i) };
        },
        .double => {
            const v = std.fmt.parseFloat(f64, std.mem.trim(u8, text, " ")) catch
                return it.fail("expected floating-point number but got \"{s}\"", .{text});
            if (std.math.isNan(v) or std.math.isInf(v)) return it.fail("expected floating-point number but got \"{s}\"", .{text});
            // A `ttk` widget keeps the text of a double as the script gave it.
            if (!w.class.ttk) norm.* = try formatDouble(it.alloc(), v);
            return .{ .double = v };
        },
        .image => {
            const first = std.mem.trim(u8, text, " ");
            const end = std.mem.indexOfScalar(u8, first, ' ') orelse first.len;
            if (w.app.images.find(first[0..end]) == null) return it.fail("image \"{s}\" doesn't exist", .{first[0..end]});
            return .{ .text = text };
        },
        .state => {
            const i = matchWord(text, spec.words) orelse
                return it.fail("{s} state \"{s}\": must be {s}", .{ badWord(text, spec.words), text, try joinWords(it, spec.words) });
            return .{ .word = @intCast(i) };
        },
    }
}

fn matchExact(text: []const u8, words: []const []const u8) ?usize {
    for (words, 0..) |wd, i| if (std.mem.eql(u8, wd, text)) return i;
    return null;
}

/// The index of an option of a class, with the abbreviation rule of Tk.
/// An unknown name and an ambiguous prefix give the same message.
pub fn find(it: *ztcl.Interp, specs: []const Spec, name: []const u8) ztcl.Error!usize {
    var found: ?usize = null;
    var ambiguous = false;
    if (name.len > 0 and name[0] == '-') {
        for (specs, 0..) |s, i| {
            if (s.hidden) continue;
            if (std.mem.eql(u8, s.name, name)) return i;
            if (std.mem.startsWith(u8, s.name, name)) {
                if (found != null) ambiguous = true else found = i;
            }
        }
    }
    if (found) |f| if (!ambiguous) return f;
    return it.fail("unknown option \"{s}\"", .{name});
}

/// The index that a synonym points to. A real option returns itself.
fn resolve(it: *ztcl.Interp, specs: []const Spec, i: usize) ztcl.Error!usize {
    if (specs[i].type != .synonym) return i;
    return find(it, specs, specs[i].target);
}

/// The text that `cget` gives for option `i` (not a synonym). An option
/// that the script did not set and that has a style property gives the
/// computed style, as `#rrggbb` for a color and as an integer for a width.
pub fn textOf(w: *Widget, it: *ztcl.Interp, i: usize) ztcl.Error![]const u8 {
    // As in `wish`, `-text` reads the value of a `-textvariable`.
    if (w.class.variable_text) |f| if (std.mem.eql(u8, w.class.specs[i].name, "-text")) {
        if (f(w)) |shown| return shown;
    };
    const s = w.opts[i];
    if (s.set) return s.text;
    const sp = w.class.specs[i];
    if (sp.type == .double and s.value == .double and !w.class.ttk) return formatDouble(it.alloc(), s.value.double);
    if (sp.from_style and sp.style_prop != .none) {
        w.app.ensureStyle(w);
        switch (sp.style_prop) {
            .background => {
                var buf: [7]u8 = undefined;
                return try it.alloc().dupe(u8, w.style.background.formatTk(&buf));
            },
            .border_width => return try std.fmt.allocPrint(it.alloc(), "{d}", .{@as(i32, @intFromFloat(@round(w.style.border_width[0])))}),
            .none => {},
        }
    }
    return sp.default;
}

fn item(it: *ztcl.Interp, w: *Widget, i: usize) ztcl.Error!ztcl.Value {
    const a = it.alloc();
    const sp = w.class.specs[i];
    if (sp.type == .synonym) {
        return ztcl.value.newList(a, &.{ .{ .str = sp.name }, .{ .str = sp.target } });
    }
    return ztcl.value.newList(a, &.{
        .{ .str = sp.name },
        .{ .str = sp.db_name },
        .{ .str = sp.db_class },
        .{ .str = sp.default },
        .{ .str = try a.dupe(u8, try textOf(w, it, i)) },
    });
}

/// `path configure ?option? ?value option value ...?`
pub fn configure(w: *Widget, it: *ztcl.Interp, args: []const ztcl.Value) ztcl.Error!ztcl.Value {
    const specs = w.class.specs;
    if (args.len == 0) {
        const a = it.alloc();
        var items: std.ArrayListUnmanaged(ztcl.Value) = .empty;
        for (specs, 0..) |sp, i| if (!sp.hidden) try items.append(a, try item(it, w, i));
        return ztcl.value.wrapList(a, items.items);
    }
    if (args.len == 1) {
        const i = try find(it, specs, try it.str(args[0]));
        return item(it, w, try resolve(it, specs, i));
    }
    try apply(w, it, args);
    return ztcl.Value.empty;
}

/// `path cget option`
pub fn cget(w: *Widget, it: *ztcl.Interp, name: ztcl.Value) ztcl.Error!ztcl.Value {
    const specs = w.class.specs;
    const i = try resolve(it, specs, try find(it, specs, try it.str(name)));
    const text = try textOf(w, it, i);
    if (!w.class.ttk and textClass(w.class.tk_class)) return .{ .str = try it.alloc().dupe(u8, text) };
    return typed(it, specs[i].type, text) orelse .{ .str = try it.alloc().dupe(u8, text) };
}

/// True for a classic class whose options Tk 8.6 gives as text, not as
/// numbers: the canvas, the scrollbar, and the menubutton. The tkinter
/// tests of CPython check this difference.
fn textClass(class: []const u8) bool {
    for ([_][]const u8{ "Canvas", "Scrollbar", "Menubutton" }) |c| {
        if (std.mem.eql(u8, c, class)) return true;
    }
    return false;
}

/// "ambiguous" when `text` is the start of two or more of `words`, as
/// the empty text is, else "bad": the first word of the error of a value
/// that is not one of `words`, as in wish.
fn badWord(text: []const u8, words: []const []const u8) []const u8 {
    var n: usize = 0;
    for (words) |wd| {
        if (std.mem.startsWith(u8, wd, text)) n += 1;
    }
    return if (n >= 2) "ambiguous" else "bad";
}

/// The value of an option of type int, pixels, or double as a number,
/// as Tk gives the object of the option, so an embedder that reads the
/// type of the result (Python's `_tkinter`) gets a number. Only a text
/// that the number gives back with no change is a number, so the string
/// form stays the same: `5` is an int, `1c` and `1.50` stay text.
fn typed(it: *ztcl.Interp, t: Type, text: []const u8) ?ztcl.Value {
    switch (t) {
        .int, .pixels => {
            const n = std.fmt.parseInt(i64, text, 10) catch return null;
            var buf: [24]u8 = undefined;
            const back = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return null;
            if (!std.mem.eql(u8, back, text)) return null;
            return .{ .int = n };
        },
        .double => {
            const d = std.fmt.parseFloat(f64, text) catch return null;
            const v: ztcl.Value = .{ .double = d };
            const back = v.toStr(it.alloc()) catch return null;
            if (!std.mem.eql(u8, back, text)) return null;
            return v;
        },
        else => return null,
    }
}

pub fn apply(w: *Widget, it: *ztcl.Interp, pairs: []const ztcl.Value) ztcl.Error!void {
    return applyEx(w, it, pairs, false);
}

const Pending = struct { index: usize, text: []const u8, parsed: Parsed };

/// Like `apply`. With `creating` set, a create-only option is allowed.
pub fn applyEx(w: *Widget, it: *ztcl.Interp, pairs: []const ztcl.Value, creating: bool) ztcl.Error!void {
    const specs = w.class.specs;
    const a = it.alloc();
    var pending: std.ArrayList(Pending) = .empty;
    var k: usize = 0;
    while (k < pairs.len) : (k += 2) {
        const name = try it.str(pairs[k]);
        const i = try resolve(it, specs, try find(it, specs, name));
        if (k + 1 >= pairs.len) return it.fail("value for \"{s}\" missing", .{name});
        if (specs[i].create_only and !creating) {
            if (w.class.ttk) return it.fail("attempt to change read-only option", .{});
            return it.fail("can't modify {s} option after widget is created", .{specs[i].name});
        }
        const text = try it.str(pairs[k + 1]);
        var norm: []const u8 = text;
        const parsed = try parseValue(w, it, specs[i], text, &norm);
        try pending.append(a, .{ .index = i, .text = norm, .parsed = parsed });
    }
    if (pending.items.len == 0) return;
    const changed = try a.alloc(usize, pending.items.len);
    const rec = w.app.dbg.sources;
    for (pending.items, changed) |p, *c| {
        const gpa = w.app.gpa;
        const owned = try gpa.dupe(u8, p.text);
        const slot = &w.opts[p.index];
        const prev = if (rec) try a.dupe(u8, try textOf(w, it, p.index)) else "";
        if (slot.set) gpa.free(slot.text);
        slot.* = .{ .set = true, .text = owned, .value = p.parsed, .src = slot.src };
        // A parsed text value points at the owned copy.
        if (p.parsed == .text) slot.value = .{ .text = owned };
        c.* = p.index;
        if (rec) debug.note(w, it, p.index, if (w.app.dbg.from_db) .optiondb else if (creating) .create else .configure, pairs, prev);
    }
    defer w.app.dbg.trace.reason = 0;
    w.afterConfigure(changed) catch |e| return e;
    w.invalidate(.{ .style = true, .measure = true, .layout = true, .paint = true });
}

/// Sets one option with the given dirty flags, for an animation step. A
/// color changes no size, so its step runs no measure and no layout.
pub fn setOne(w: *Widget, it: *ztcl.Interp, i: usize, text: []const u8, d: widget_mod.Dirty) ztcl.Error!void {
    var norm: []const u8 = text;
    const parsed = try parseValue(w, it, w.class.specs[i], text, &norm);
    const gpa = w.app.gpa;
    const owned = try gpa.dupe(u8, norm);
    const slot = &w.opts[i];
    const prev = if (w.app.dbg.sources) try it.alloc().dupe(u8, try textOf(w, it, i)) else "";
    if (slot.set) gpa.free(slot.text);
    slot.* = .{ .set = true, .text = owned, .value = parsed, .src = slot.src };
    if (parsed == .text) slot.value = .{ .text = owned };
    if (w.app.dbg.sources) debug.note(w, it, i, .animate, &.{}, prev);
    const changed = [_]usize{i};
    try w.afterConfigure(&changed);
    if (w.life == .dead) return;
    w.invalidate(d);
}

/// Sets the text and the value of one option with no `configured` call,
/// for a class that keeps an option equal to its own state (the `-value`
/// of a `ttk` range widget).
pub fn store(w: *Widget, i: usize, text: []const u8, parsed: Parsed) !void {
    const gpa = w.app.gpa;
    const owned = try gpa.dupe(u8, text);
    const slot = &w.opts[i];
    if (slot.set) gpa.free(slot.text);
    slot.* = .{ .set = true, .text = owned, .value = if (parsed == .text) .{ .text = owned } else parsed, .src = slot.src };
    if (w.app.dbg.sources) debug.note(w, w.app.it, i, .internal, &.{}, "");
}

/// The index of an option of the class. The name is a real option.
pub fn index(w: *const Widget, comptime name: []const u8) usize {
    for (w.class.specs, 0..) |s, i| if (std.mem.eql(u8, s.name, name)) return i;
    @panic("no option " ++ name);
}

/// A typed reader for the class code. The name is a real option.
pub fn maybe(w: *const Widget, name: []const u8) ?*const Slot {
    for (w.class.specs, 0..) |s, i| if (std.mem.eql(u8, s.name, name)) return &w.opts[i];
    return null;
}

pub fn get(w: *const Widget, comptime name: []const u8) *const Slot {
    for (w.class.specs, 0..) |s, i| if (std.mem.eql(u8, s.name, name)) return &w.opts[i];
    @panic("no option " ++ name);
}

/// Makes the slots of a new widget and parses each default.
pub fn initSlots(w: *Widget, it: *ztcl.Interp) !void {
    const specs = w.class.specs;
    const gpa = w.app.gpa;
    w.opts = try gpa.alloc(Slot, specs.len);
    for (w.opts) |*s| s.* = .{};
    for (specs, w.opts) |sp, *s| {
        if (sp.type == .synonym or sp.default.len == 0) continue;
        var norm: []const u8 = undefined;
        s.value = parseValue(w, it, sp, sp.default, &norm) catch .none;
        if (s.value == .text) s.value = .{ .text = sp.default };
    }
}

pub fn freeSlots(w: *Widget) void {
    const gpa = w.app.gpa;
    for (w.opts) |s| {
        if (s.set) gpa.free(s.text);
        if (s.src) |r| r.free(gpa);
    }
    gpa.free(w.opts);
    w.opts = &.{};
}
