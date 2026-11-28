//! Event patterns, the binding table, and the commands `bind` and
//! `bindtags`. A pattern is one event: a type, the modifiers that it
//! needs, a click count, and a detail (a button or a key symbol). A
//! sequence such as `<Control-x><Control-s>` is the pattern of its last
//! event with the patterns of the earlier events as its prefix. The
//! table keeps the scripts of each tag in the order that they were made.
//! `match` picks the most specific pattern that fits an event: a longer
//! sequence first, then a detail, then a higher count, then more
//! modifiers, then a physical pattern before a virtual one, and the
//! newest pattern for equal rank.
//!
//! `History` has the last 32 events that `deliver` got. A sequence fits
//! when its last pattern fits the event and a walk back through the
//! history finds an event for each pattern of the prefix, as in wish
//! 8.6.16. The walk skips an event of another type and the press of a
//! modifier key. It stops with no match at an event of another widget,
//! at a button event for a key pattern or a key event for a button
//! pattern, and at an event of the type of the pattern that does not
//! fit it. A sequence does not fit when the event before its first
//! event also fits its first pattern.
//! `substitute` fills the `%` fields. `deliver` runs the scripts of the
//! tags of a widget in order, and a script can stop the later tags with
//! `break`. A script with no `%` field compiles once and compiles again
//! when `App.script_gen` changes.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const debug = @import("debug.zig");
const event = @import("base/event.zig");
const keysym = @import("base/keysym.zig");
const widget_mod = @import("widget.zig");
const App = @import("app.zig").App;
const Widget = widget_mod.Widget;
const Value = ztcl.Value;

pub const EventType = enum(u8) {
    key_press = 2,
    key_release = 3,
    button_press = 4,
    button_release = 5,
    motion = 6,
    enter = 7,
    leave = 8,
    focus_in = 9,
    focus_out = 10,
    expose = 12,
    visibility = 15,
    create = 16,
    destroy = 17,
    unmap = 18,
    map = 19,
    reparent = 21,
    configure = 22,
    gravity = 24,
    circulate = 26,
    property = 28,
    colormap = 32,
    virtual = 35,
    activate = 36,
    deactivate = 37,
    mouse_wheel = 38,
};

pub const Pattern = struct {
    type: EventType,
    /// The modifiers that the pattern needs.
    mods: event.Mods = .{},
    /// 2 for Double, 3 for Triple, 4 for Quadruple.
    count: u8 = 1,
    /// A button number or a key symbol. 0 is any.
    detail: u32 = 0,
    /// The name of a virtual event.
    virtual: []const u8 = "",
    /// The patterns of the earlier events of a sequence, the first event
    /// first. A pattern of the prefix has no prefix.
    prefix: []const Pattern = &.{},

    fn eql(a: Pattern, b: Pattern) bool {
        if (a.prefix.len != b.prefix.len) return false;
        for (a.prefix, b.prefix) |x, y| if (!x.eql(y)) return false;
        return a.type == b.type and @as(u16, @bitCast(a.mods)) == @as(u16, @bitCast(b.mods)) and
            a.count == b.count and a.detail == b.detail and std.mem.eql(u8, a.virtual, b.virtual);
    }

    /// A copy with its own name and prefix.
    pub fn dupe(p: Pattern, gpa: std.mem.Allocator) !Pattern {
        var out = p;
        out.virtual = if (p.virtual.len > 0) try gpa.dupe(u8, p.virtual) else "";
        errdefer if (out.virtual.len > 0) gpa.free(out.virtual);
        out.prefix = if (p.prefix.len > 0) try gpa.dupe(Pattern, p.prefix) else &.{};
        return out;
    }

    /// Frees the name and the prefix of a copy of `dupe`.
    pub fn free(p: Pattern, gpa: std.mem.Allocator) void {
        if (p.virtual.len > 0) gpa.free(p.virtual);
        if (p.prefix.len > 0) gpa.free(p.prefix);
    }
};

/// One event of the history: the fields that a pattern checks.
const Past = struct {
    type: EventType,
    detail: u32,
    mods: event.Mods,
    count: u8,
    widget: *const Widget,
};

/// The last events that `deliver` got, for the sequences.
pub const History = struct {
    ring: [32]Past = undefined,
    /// The count of all events. Event `i` is in `ring[i % 32]`.
    n: u64 = 0,
    /// The number of the event that `deliver` handles now, or null
    /// outside `deliver`.
    cur: ?u64 = null,

    fn push(h: *History, ev: *const WidgetEvent) u64 {
        h.ring[h.n % h.ring.len] = .{ .type = ev.type, .detail = detailOf(ev), .mods = ev.mods, .count = ev.count, .widget = ev.widget };
        h.n += 1;
        return h.n - 1;
    }

    /// The event before event `i`, or null when the ring does not have it.
    fn before(h: *const History, i: u64) ?struct { u64, Past } {
        if (i == 0 or h.n - (i - 1) > h.ring.len) return null;
        return .{ i - 1, h.ring[(i - 1) % h.ring.len] };
    }
};

fn detailOf(ev: *const WidgetEvent) u32 {
    return if (isButtonType(ev.type)) ev.button else if (isKeyType(ev.type)) ev.keysym else 0;
}

/// A modifier key: Shift_L to Hyper_R.
fn isModifierKey(sym: u32) bool {
    return sym >= 0xffe1 and sym <= 0xffee;
}

const Step = enum { fit, skip, stop };

/// Compares an event of the history with a pattern of a prefix.
fn step(p: Pattern, r: Past, w: *const Widget) Step {
    if (r.widget != w) return .stop;
    if (r.type != p.type) {
        if (isKeyType(p.type) and isButtonType(r.type)) return .stop;
        if (isButtonType(p.type) and isKeyType(r.type)) return .stop;
        return .skip;
    }
    const need: u16 = @bitCast(p.mods);
    const got: u16 = @bitCast(r.mods);
    if ((p.detail == 0 or p.detail == r.detail) and need & got == need and (p.count <= 1 or r.count >= p.count)) return .fit;
    if (r.type == .key_press and isModifierKey(r.detail)) return .skip;
    return .stop;
}

/// True when the events before the event `ev` fit the prefix.
fn prefixFits(prefix: []const Pattern, ev: *const WidgetEvent) bool {
    const h = &ev.widget.app.history;
    var i = h.cur orelse h.n;
    var k = prefix.len;
    while (k > 0) {
        const b = h.before(i) orelse return false;
        i = b[0];
        switch (step(prefix[k - 1], b[1], ev.widget)) {
            .fit => k -= 1,
            .skip => {},
            .stop => return false,
        }
    }
    // The event before the sequence must not fit the first pattern.
    while (h.before(i)) |b| {
        i = b[0];
        switch (step(prefix[0], b[1], ev.widget)) {
            .fit => return false,
            .skip => {},
            .stop => break,
        }
    }
    return true;
}

/// One event for a widget, with the data of the `%` fields.
pub const WidgetEvent = struct {
    type: EventType,
    widget: *Widget,
    x: i32 = 0,
    y: i32 = 0,
    root_x: i32 = -1,
    root_y: i32 = -1,
    button: u8 = 0,
    keysym: u32 = 0,
    keycode: u32 = 0,
    text: []const u8 = "",
    mods: event.Mods = .{},
    time_ms: u32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    /// The click count.
    count: u8 = 1,
    serial: u32 = 0,
    virtual: []const u8 = "",
    data: []const u8 = "",
    /// The wheel delta of `%D`: 120 for one step up, and a fraction of it
    /// for a touchpad or a wheel with fine steps.
    delta: f32 = 0,
};

// ---- Parsing ----

const ModName = struct { name: []const u8, set: *const fn (*event.Mods, *u8) void };

fn setShift(m: *event.Mods, _: *u8) void {
    m.shift = true;
}
fn setLock(m: *event.Mods, _: *u8) void {
    m.lock = true;
}
fn setControl(m: *event.Mods, _: *u8) void {
    m.control = true;
}
fn setMod1(m: *event.Mods, _: *u8) void {
    m.mod1 = true;
}
fn setMod2(m: *event.Mods, _: *u8) void {
    m.mod2 = true;
}
fn setMod3(m: *event.Mods, _: *u8) void {
    m.mod3 = true;
}
fn setMod4(m: *event.Mods, _: *u8) void {
    m.mod4 = true;
}
fn setMod5(m: *event.Mods, _: *u8) void {
    m.mod5 = true;
}
fn setB1(m: *event.Mods, _: *u8) void {
    m.button1 = true;
}
fn setB2(m: *event.Mods, _: *u8) void {
    m.button2 = true;
}
fn setB3(m: *event.Mods, _: *u8) void {
    m.button3 = true;
}
fn setB4(m: *event.Mods, _: *u8) void {
    m.button4 = true;
}
fn setB5(m: *event.Mods, _: *u8) void {
    m.button5 = true;
}
fn setDouble(_: *event.Mods, c: *u8) void {
    c.* = @max(c.*, 2);
}
fn setTriple(_: *event.Mods, c: *u8) void {
    c.* = @max(c.*, 3);
}
fn setQuad(_: *event.Mods, c: *u8) void {
    c.* = @max(c.*, 4);
}
fn setNone(_: *event.Mods, _: *u8) void {}

const mod_names = [_]ModName{
    .{ .name = "Control", .set = setControl },
    .{ .name = "Shift", .set = setShift },
    .{ .name = "Lock", .set = setLock },
    .{ .name = "Alt", .set = setMod1 },
    .{ .name = "Meta", .set = setMod1 },
    .{ .name = "M", .set = setMod1 },
    .{ .name = "Mod1", .set = setMod1 },
    .{ .name = "M1", .set = setMod1 },
    // The names of Tk on macOS: Command is Mod1 and Option is Mod2.
    .{ .name = "Command", .set = setMod1 },
    .{ .name = "Option", .set = setMod2 },
    .{ .name = "Mod2", .set = setMod2 },
    .{ .name = "M2", .set = setMod2 },
    .{ .name = "Mod3", .set = setMod3 },
    .{ .name = "M3", .set = setMod3 },
    .{ .name = "Mod4", .set = setMod4 },
    .{ .name = "M4", .set = setMod4 },
    .{ .name = "Mod5", .set = setMod5 },
    .{ .name = "M5", .set = setMod5 },
    .{ .name = "Button1", .set = setB1 },
    .{ .name = "B1", .set = setB1 },
    .{ .name = "Button2", .set = setB2 },
    .{ .name = "B2", .set = setB2 },
    .{ .name = "Button3", .set = setB3 },
    .{ .name = "B3", .set = setB3 },
    .{ .name = "Button4", .set = setB4 },
    .{ .name = "B4", .set = setB4 },
    .{ .name = "Button5", .set = setB5 },
    .{ .name = "B5", .set = setB5 },
    .{ .name = "Double", .set = setDouble },
    .{ .name = "Triple", .set = setTriple },
    .{ .name = "Quadruple", .set = setQuad },
    .{ .name = "Any", .set = setNone },
};

const TypeName = struct { name: []const u8, t: EventType };
const type_names = [_]TypeName{
    .{ .name = "ButtonPress", .t = .button_press },
    .{ .name = "Button", .t = .button_press },
    .{ .name = "ButtonRelease", .t = .button_release },
    .{ .name = "Motion", .t = .motion },
    .{ .name = "Enter", .t = .enter },
    .{ .name = "Leave", .t = .leave },
    .{ .name = "KeyPress", .t = .key_press },
    .{ .name = "Key", .t = .key_press },
    .{ .name = "KeyRelease", .t = .key_release },
    .{ .name = "FocusIn", .t = .focus_in },
    .{ .name = "FocusOut", .t = .focus_out },
    .{ .name = "Configure", .t = .configure },
    .{ .name = "Destroy", .t = .destroy },
    .{ .name = "Map", .t = .map },
    .{ .name = "Unmap", .t = .unmap },
    .{ .name = "MouseWheel", .t = .mouse_wheel },
    // Event types of X11 that ztk accepts in a pattern. Visibility comes
    // after Map; the others never come.
    .{ .name = "Visibility", .t = .visibility },
    .{ .name = "Expose", .t = .expose },
    .{ .name = "Create", .t = .create },
    .{ .name = "Reparent", .t = .reparent },
    .{ .name = "Gravity", .t = .gravity },
    .{ .name = "Circulate", .t = .circulate },
    .{ .name = "Property", .t = .property },
    .{ .name = "Colormap", .t = .colormap },
    .{ .name = "Activate", .t = .activate },
    .{ .name = "Deactivate", .t = .deactivate },
};

fn findMod(name: []const u8) ?ModName {
    for (mod_names) |m| if (std.mem.eql(u8, m.name, name)) return m;
    return null;
}

fn findType(name: []const u8) ?EventType {
    for (type_names) |t| if (std.mem.eql(u8, t.name, name)) return t.t;
    return null;
}

fn isKeyType(t: EventType) bool {
    return t == .key_press or t == .key_release;
}

fn isButtonType(t: EventType) bool {
    return t == .button_press or t == .button_release;
}

/// Parses an event pattern: "<Control-Button-1>", "<<Copy>>", "a", or
/// a sequence of patterns: "<Control-x><Control-s>", "abc". The name and
/// the prefix of the result are in the arena of the interpreter.
pub fn parsePattern(it: *ztcl.Interp, text: []const u8) ztcl.Error!Pattern {
    if (text.len >= 4 and std.mem.startsWith(u8, text, "<<") and std.mem.endsWith(u8, text, ">>")) {
        const name = text[2 .. text.len - 2];
        if (std.mem.indexOf(u8, name, ">>") != null) return it.fail("virtual events may not be composed", .{});
        if (name.len == 0 or std.mem.indexOfAny(u8, name, "<>") != null) return it.fail("virtual event \"{s}\" is badly formed", .{text});
        return .{ .type = .virtual, .virtual = try it.alloc().dupe(u8, name) };
    }
    if (text.len == 0) return it.fail("no event type or button # or keysym", .{});
    var list: std.ArrayListUnmanaged(Pattern) = .empty;
    const a = it.alloc();
    var rest = text;
    while (rest.len > 0) {
        var n: usize = undefined;
        if (rest[0] == '<') {
            if (std.mem.startsWith(u8, rest, "<<")) return it.fail("virtual events may not be composed", .{});
            n = 1 + (std.mem.indexOfScalar(u8, rest, '>') orelse return it.fail("missing \">\" in binding", .{}));
        } else {
            n = std.unicode.utf8ByteSequenceLength(rest[0]) catch return it.fail("bad event type or keysym \"{s}\"", .{text});
            if (n > rest.len) return it.fail("bad event type or keysym \"{s}\"", .{text});
        }
        try list.append(a, try parseOne(it, rest[0..n]));
        rest = rest[n..];
    }
    var p = list.items[list.items.len - 1];
    p.prefix = list.items[0 .. list.items.len - 1];
    return p;
}

/// Parses the pattern of one event: "<Control-Button-1>" or "a".
fn parseOne(it: *ztcl.Interp, text: []const u8) ztcl.Error!Pattern {
    if (text[0] != '<') {
        // A plain character is a key press.
        const view = std.unicode.Utf8View.init(text) catch return it.fail("bad event type or keysym \"{s}\"", .{text});
        var cps = view.iterator();
        const first = cps.nextCodepoint() orelse return it.fail("no event type or button # or keysym", .{});
        return .{ .type = .key_press, .detail = keysym.fromCodepoint(first) };
    }
    const close = text.len - 1;
    const body = text[1..close];
    var p: Pattern = .{ .type = .key_press };
    var have_type = false;
    var count: u8 = 1;
    var tokens = std.mem.splitScalar(u8, body, '-');
    var toks: [8][]const u8 = undefined;
    var n: usize = 0;
    while (tokens.next()) |t| {
        if (n == toks.len) return it.fail("extra characters after detail in binding", .{});
        toks[n] = t;
        n += 1;
    }
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const tok = toks[i];
        if (tok.len == 0) {
            // A trailing dash, or a dash key.
            if (i == n - 1 or have_type) return it.fail("no event type or button # or keysym", .{});
            continue;
        }
        if (!have_type) {
            // A modifier name in the last place is a key: `<Control-M>`
            // is the key M, as in wish, where M alone is also Meta.
            if (findMod(tok)) |m| if (i < n - 1 or keysymOf(tok) == null) {
                if (i == n - 1) return it.fail("bad event type or keysym \"{s}\"", .{tok});
                m.set(&p.mods, &count);
                continue;
            };
            if (findType(tok)) |t| {
                p.type = t;
                have_type = true;
                // The detail follows.
                if (i + 1 < n) {
                    i += 1;
                    try parseDetail(it, &p, toks[i]);
                    if (i + 1 < n) return it.fail("extra characters after detail in binding", .{});
                }
                break;
            }
            // A detail with no type: a button for a digit, a key otherwise.
            if (tok.len == 1 and tok[0] >= '1' and tok[0] <= '5') {
                p.type = .button_press;
                p.detail = tok[0] - '0';
            } else if (tok.len == 1 and tok[0] >= '6' and tok[0] <= '9') {
                return it.fail("bad button number \"{s}\"", .{tok});
            } else {
                p.type = .key_press;
                p.detail = keysymOf(tok) orelse return it.fail("bad event type or keysym \"{s}\"", .{tok});
            }
            have_type = true;
            if (i + 1 < n) return it.fail("extra characters after detail in binding", .{});
            break;
        }
    }
    if (!have_type) return it.fail("no event type or button # or keysym", .{});
    p.count = count;
    return p;
}

fn keysymOf(name: []const u8) ?u32 {
    if (keysym.fromName(name)) |s| return s;
    const view = std.unicode.Utf8View.init(name) catch return null;
    var cps = view.iterator();
    const first = cps.nextCodepoint() orelse return null;
    if (cps.nextCodepoint() != null) return null;
    return keysym.fromCodepoint(first);
}

fn parseDetail(it: *ztcl.Interp, p: *Pattern, tok: []const u8) ztcl.Error!void {
    if (isButtonType(p.type)) {
        const v = std.fmt.parseInt(u32, tok, 10) catch return it.fail("bad button number \"{s}\"", .{tok});
        if (v < 1 or v > 5) return it.fail("bad button number \"{s}\"", .{tok});
        p.detail = v;
    } else if (isKeyType(p.type)) {
        p.detail = keysymOf(tok) orelse return it.fail("bad event type or keysym \"{s}\"", .{tok});
    } else return it.fail("extra characters after detail in binding", .{});
}

/// The canonical text of a pattern, as `bind tag` lists it.
pub fn formatPattern(p: Pattern, buf: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    writePattern(&w, p) catch return buf[0..0];
    return w.buffered();
}

fn writePattern(w: *std.Io.Writer, p: Pattern) !void {
    for (p.prefix) |q| try writePattern(w, q);
    if (p.type == .virtual) {
        try w.print("<<{s}>>", .{p.virtual});
        return;
    }
    const m = p.mods;
    // A plain printable key with no modifier and no count is the character alone.
    if (p.type == .key_press and p.detail != 0 and p.count == 1 and @as(u16, @bitCast(m)) == 0) {
        if (keysym.toName(p.detail)) |name| {
            if (name.len == 1) {
                try w.writeAll(name);
                return;
            }
        }
    }
    try w.writeByte('<');
    if (m.control) try w.writeAll("Control-");
    if (m.shift) try w.writeAll("Shift-");
    if (m.lock) try w.writeAll("Lock-");
    if (m.mod1) try w.writeAll("Alt-");
    if (m.mod2) try w.writeAll("Mod2-");
    if (m.mod3) try w.writeAll("Mod3-");
    if (m.mod4) try w.writeAll("Mod4-");
    if (m.mod5) try w.writeAll("Mod5-");
    if (m.button1) try w.writeAll("B1-");
    if (m.button2) try w.writeAll("B2-");
    if (m.button3) try w.writeAll("B3-");
    if (m.button4) try w.writeAll("B4-");
    if (m.button5) try w.writeAll("B5-");
    switch (p.count) {
        2 => try w.writeAll("Double-"),
        3 => try w.writeAll("Triple-"),
        4 => try w.writeAll("Quadruple-"),
        else => {},
    }
    const type_text: []const u8 = switch (p.type) {
        .key_press => "Key",
        .key_release => "KeyRelease",
        .button_press => "Button",
        .button_release => "ButtonRelease",
        .motion => "Motion",
        .enter => "Enter",
        .leave => "Leave",
        .focus_in => "FocusIn",
        .focus_out => "FocusOut",
        .destroy => "Destroy",
        .unmap => "Unmap",
        .map => "Map",
        .configure => "Configure",
        .mouse_wheel => "MouseWheel",
        .virtual => "",
        .visibility => "Visibility",
        .expose => "Expose",
        .create => "Create",
        .reparent => "Reparent",
        .gravity => "Gravity",
        .circulate => "Circulate",
        .property => "Property",
        .colormap => "Colormap",
        .activate => "Activate",
        .deactivate => "Deactivate",
    };
    try w.writeAll(type_text);
    if (p.detail != 0) {
        if (isButtonType(p.type)) {
            try w.print("-{d}", .{p.detail});
        } else if (keysym.toName(p.detail)) |name| {
            try w.print("-{s}", .{name});
        } else try w.print("-{d}", .{p.detail});
    }
    try w.writeByte('>');
}

// ---- The table ----

const Entry = struct {
    pattern: Pattern,
    /// Owned.
    script: []u8,
    has_percent: bool,
    compiled: ?*ztcl.interp.Script = null,
    gen: u32 = 0,
};

pub const Table = struct {
    gpa: std.mem.Allocator,
    tags: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(Entry)) = .empty,

    pub fn init(gpa: std.mem.Allocator) Table {
        return .{ .gpa = gpa };
    }

    pub fn deinit(t: *Table) void {
        var it = t.tags.iterator();
        while (it.next()) |e| {
            for (e.value_ptr.items) |*en| freeEntry(t.gpa, en);
            e.value_ptr.deinit(t.gpa);
            t.gpa.free(e.key_ptr.*);
        }
        t.tags.deinit(t.gpa);
    }

    fn freeEntry(gpa: std.mem.Allocator, e: *Entry) void {
        gpa.free(e.script);
        e.pattern.free(gpa);
    }

    /// Sets, appends to ("+script"), or deletes ("") a binding.
    pub fn set(t: *Table, tag: []const u8, p: Pattern, script: []const u8) !void {
        const gpa = t.gpa;
        const append = script.len > 0 and script[0] == '+';
        const body = if (append) script[1..] else script;
        var entries: *std.ArrayListUnmanaged(Entry) = undefined;
        if (t.tags.getPtr(tag)) |l| {
            entries = l;
        } else {
            if (body.len == 0) return;
            const key = try gpa.dupe(u8, tag);
            errdefer gpa.free(key);
            try t.tags.put(gpa, key, .empty);
            entries = t.tags.getPtr(tag).?;
        }
        for (entries.items, 0..) |*e, i| {
            if (!e.pattern.eql(p)) continue;
            if (body.len == 0 and !append) {
                freeEntry(gpa, e);
                _ = entries.orderedRemove(i);
                return;
            }
            const text = if (append) try std.fmt.allocPrint(gpa, "{s}\n{s}", .{ e.script, body }) else try gpa.dupe(u8, body);
            gpa.free(e.script);
            e.script = text;
            e.has_percent = std.mem.indexOfScalar(u8, text, '%') != null;
            e.compiled = null;
            return;
        }
        if (body.len == 0) return;
        const copy = try gpa.dupe(u8, body);
        errdefer gpa.free(copy);
        const pat = try p.dupe(gpa);
        errdefer pat.free(gpa);
        try entries.append(gpa, .{ .pattern = pat, .script = copy, .has_percent = std.mem.indexOfScalar(u8, copy, '%') != null });
    }

    pub fn get(t: *const Table, tag: []const u8, p: Pattern) ?[]const u8 {
        const entries = t.tags.get(tag) orelse return null;
        for (entries.items) |e| if (e.pattern.eql(p)) return e.script;
        return null;
    }

    /// The patterns of a tag, newest first. The caller frees the slice.
    pub fn list(t: *const Table, tag: []const u8, gpa: std.mem.Allocator) ![]Pattern {
        const l = t.tags.get(tag) orelse return try gpa.alloc(Pattern, 0);
        const out = try gpa.alloc(Pattern, l.items.len);
        for (l.items, 0..) |e, i| out[l.items.len - 1 - i] = e.pattern;
        return out;
    }

    fn fits(p: Pattern, ev: *const WidgetEvent) bool {
        if (p.type != ev.type) return false;
        if (p.type == .virtual) return std.mem.eql(u8, p.virtual, ev.virtual);
        if (p.detail != 0) {
            const have: u32 = if (isButtonType(ev.type)) ev.button else if (isKeyType(ev.type)) ev.keysym else 0;
            if (p.detail != have) return false;
        }
        const need: u16 = @bitCast(p.mods);
        const got: u16 = @bitCast(ev.mods);
        if (need & got != need) return false;
        if (p.count > 1 and ev.count < p.count) return false;
        return p.prefix.len == 0 or prefixFits(p.prefix, ev);
    }

    fn virtualRank(p: Pattern, ev: *const WidgetEvent) ?u32 {
        if (p.type != .virtual or ev.type == .virtual) return null;
        const app = ev.widget.app;
        var best: ?u32 = null;
        for (app.virtual_events.items) |d| {
            // As in wish 8.6.16, a sequence of more than one event runs
            // no binding of its virtual event.
            if (d.pattern.prefix.len > 0) continue;
            if (!std.mem.eql(u8, d.name, p.virtual) or !fits(d.pattern, ev)) continue;
            const r = rank(d.pattern) & ~@as(u32, 1);
            if (best == null or r > best.?) best = r;
        }
        return best;
    }

    fn rank(p: Pattern) u32 {
        const mods: u16 = @bitCast(p.mods);
        return (@as(u32, @min(p.prefix.len, 63)) << 20) | (@as(u32, @intFromBool(p.detail != 0)) << 16) | (@as(u32, p.count) << 12) | (@as(u32, @popCount(mods)) << 4) | @as(u32, @intFromBool(p.type != .virtual));
    }

    fn matchEntry(t: *Table, tag: []const u8, ev: *const WidgetEvent) ?*Entry {
        const l = t.tags.getPtr(tag) orelse return null;
        var best: ?*Entry = null;
        var best_rank: u32 = 0;
        for (l.items) |*e| {
            // A binding of a virtual event that `event add` defined matches
            // a physical event of one of its sequences, with the rank of
            // that sequence below a physical binding of equal rank.
            const r = if (fits(e.pattern, ev)) rank(e.pattern) else virtualRank(e.pattern, ev) orelse continue;
            // The newest entry wins a tie, so `>=` and a forward walk.
            if (best == null or r >= best_rank) {
                best = e;
                best_rank = r;
            }
        }
        return best;
    }

    /// The script of the most specific pattern of the tag that matches.
    pub fn match(t: *Table, tag: []const u8, ev: *const WidgetEvent) ?[]const u8 {
        return (t.matchEntry(tag, ev) orelse return null).script;
    }

    /// True when the tag has a binding for a key press or a key release.
    pub fn hasKeyBinding(t: *const Table, tag: []const u8) bool {
        const l = t.tags.get(tag) orelse return false;
        for (l.items) |e| if (isKeyType(e.pattern.type)) return true;
        return false;
    }

    pub fn removeTag(t: *Table, tag: []const u8) void {
        if (t.tags.fetchRemove(tag)) |kv| {
            var l = kv.value;
            for (l.items) |*e| freeEntry(t.gpa, e);
            l.deinit(t.gpa);
            t.gpa.free(kv.key);
        }
    }
};

// ---- Substitution ----

pub fn appendQuoted(a: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try ztcl.value.appendElement(a, out, s, true);
}

/// Replaces the `%` fields of a script.
pub fn substitute(gpa: std.mem.Allocator, script: []const u8, ev: *const WidgetEvent) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < script.len) : (i += 1) {
        const c = script[i];
        if (c != '%' or i + 1 >= script.len) {
            try out.append(gpa, c);
            continue;
        }
        i += 1;
        const f = script[i];
        const is_key = isKeyType(ev.type);
        const is_button = isButtonType(ev.type);
        const wheel = ev.type == .mouse_wheel;
        const has_xy = is_button or is_key or wheel or ev.type == .motion or ev.type == .enter or ev.type == .leave or ev.type == .configure or ev.type == .virtual;
        const has_state = is_button or is_key or wheel or ev.type == .motion or ev.type == .enter or ev.type == .leave;
        switch (f) {
            '%' => try out.append(gpa, '%'),
            'W' => try appendQuoted(gpa, &out, ev.widget.path),
            'x' => if (has_xy) try out.print(gpa, "{d}", .{ev.x}) else try out.appendSlice(gpa, "??"),
            'y' => if (has_xy) try out.print(gpa, "{d}", .{ev.y}) else try out.appendSlice(gpa, "??"),
            'X' => if (has_xy) try out.print(gpa, "{d}", .{ev.root_x}) else try out.appendSlice(gpa, "??"),
            'Y' => if (has_xy) try out.print(gpa, "{d}", .{ev.root_y}) else try out.appendSlice(gpa, "??"),
            'b' => if (is_button) try out.print(gpa, "{d}", .{ev.button}) else try out.appendSlice(gpa, "??"),
            'k' => if (is_key) try out.print(gpa, "{d}", .{ev.keycode}) else try out.appendSlice(gpa, "??"),
            'K' => if (is_key) {
                if (keysym.toName(ev.keysym)) |n| try out.appendSlice(gpa, n) else try out.print(gpa, "{d}", .{ev.keysym});
            } else try out.appendSlice(gpa, "??"),
            'A' => if (is_key) try appendQuoted(gpa, &out, ev.text) else try out.appendSlice(gpa, "??"),
            's' => if (has_state) try out.print(gpa, "{d}", .{@as(u16, @bitCast(ev.mods))}) else try out.appendSlice(gpa, "??"),
            't' => if (has_state) try out.print(gpa, "{d}", .{ev.time_ms}) else try out.appendSlice(gpa, "??"),
            'T' => try out.print(gpa, "{d}", .{@intFromEnum(ev.type)}),
            'h' => if (ev.type == .configure) try out.print(gpa, "{d}", .{ev.height}) else try out.appendSlice(gpa, "??"),
            'w' => if (ev.type == .configure) try out.print(gpa, "{d}", .{ev.width}) else try out.appendSlice(gpa, "??"),
            '#' => try out.print(gpa, "{d}", .{ev.serial}),
            // The send_event field of bind.n: 0, as ztk sends no events
            // of other clients.
            'E' => try out.append(gpa, '0'),
            // The focus field of an Enter or Leave event.
            'f' => if (ev.type == .enter or ev.type == .leave) try out.append(gpa, '0') else try out.appendSlice(gpa, "??"),
            'N' => if (is_key) try out.print(gpa, "{d}", .{ev.keysym}) else try out.appendSlice(gpa, "??"),
            'D' => if (wheel) {
                if (ev.delta == @trunc(ev.delta)) try out.print(gpa, "{d}", .{@as(i64, @intFromFloat(ev.delta))}) else try out.print(gpa, "{d}", .{ev.delta});
            } else if (ev.type == .virtual) try appendQuoted(gpa, &out, ev.data) else try out.appendSlice(gpa, "??"),
            'd' => if (ev.type == .virtual) try appendQuoted(gpa, &out, ev.data) else try out.appendSlice(gpa, "??"),
            else => try out.append(gpa, f),
        }
    }
    return out.toOwnedSlice(gpa);
}

// ---- Delivery ----

const Code = enum { ok, brk, cont, err };

fn runEntry(app: *App, e: *Entry, ev: *const WidgetEvent) Code {
    const it = app.it;
    const saved_frame = it.frame;
    const saved_ns = it.ns;
    const saved_result = it.result;
    it.frame = &it.global;
    it.ns = "";
    defer {
        it.frame = saved_frame;
        it.ns = saved_ns;
        it.result = saved_result;
    }
    var code: Code = .ok;
    if (e.has_percent) {
        const text = substitute(app.gpa, e.script, ev) catch return .err;
        defer app.gpa.free(text);
        const compiled = it.compile(it.alloc().dupe(u8, text) catch return .err) catch |err| return handle(app, err);
        _ = it.evalScript(compiled) catch |err| {
            code = handle(app, err);
        };
    } else {
        if (e.compiled == null or e.gen != app.script_gen) {
            // The compiled script reads its text for the whole run. A script
            // can change the binding, so the text must not be the text of `e`.
            const text = it.alloc().dupe(u8, e.script) catch return .err;
            e.compiled = it.compile(text) catch |err| return handle(app, err);
            e.gen = app.script_gen;
        }
        // `e` can go away while the script runs, so keep the compiled script.
        const compiled = e.compiled.?;
        _ = it.evalScript(compiled) catch |err| {
            code = handle(app, err);
        };
    }
    return code;
}

fn handle(app: *App, err: ztcl.Error) Code {
    switch (err) {
        error.TclBreak => return .brk,
        error.TclContinue => return .cont,
        error.TclReturn => return .ok,
        else => {
            app.backgroundError(err);
            return .err;
        },
    }
}

/// The tags of a widget, in order.
pub fn tagsOf(w: *const Widget, buf: *[4][]const u8) []const []const u8 {
    if (w.bindtags) |custom| return custom;
    var n: usize = 0;
    buf[n] = w.path;
    n += 1;
    buf[n] = w.tk_class;
    n += 1;
    if (!w.isToplevel()) {
        buf[n] = w.toplevelPath();
        n += 1;
    }
    buf[n] = "all";
    n += 1;
    return buf[0..n];
}

/// Runs the bindings of an event for each tag of the widget.
pub fn deliver(app: *App, ev: *const WidgetEvent) void {
    if (app.closing) return;
    app.enter();
    defer app.leave();
    const w = ev.widget;
    const saved_cur = app.history.cur;
    app.history.cur = app.history.push(ev);
    defer app.history.cur = saved_cur;
    const saved_cause = app.dbg.trace.cause;
    defer app.dbg.trace.cause = saved_cause;
    if (app.dbg.trace.mask != 0) {
        const seq = debug.event(app, ev);
        if (seq != 0) app.dbg.trace.cause = seq;
    }
    if (w.class.event) |f| if (w.alive()) {
        f(w, ev);
        if (!w.alive() and ev.type != .destroy) return;
    };
    var buf: [4][]const u8 = undefined;
    const tags = tagsOf(w, &buf);
    // The tag list can change in a script, so copy the names that it holds.
    // The copies are in the arena of the interpreter, which lives until the callback ends.
    const a = app.it.alloc();
    const local = a.alloc([]const u8, tags.len) catch return;
    for (tags, local) |t, *slot| slot.* = a.dupe(u8, t) catch return;
    for (local) |tag| {
        // Only the Destroy event reaches a widget that is not alive.
        if (!w.alive() and ev.type != .destroy) return;
        const e = app.bindings.matchEntry(tag, ev) orelse continue;
        if (app.dbg.trace.mask != 0) debug.binding(app, w, tag, e.pattern, e.script);
        const code = runEntry(app, e, ev);
        switch (code) {
            .brk, .err => return,
            .cont, .ok => {},
        }
    }
}

/// Runs the bindings of an event for each tag of a list, in a table of
/// its own: the item bindings of a canvas.
pub fn runTags(app: *App, table: *Table, tags: []const []const u8, ev: *const WidgetEvent) void {
    if (app.closing) return;
    app.enter();
    defer app.leave();
    for (tags) |tag| {
        if (!ev.widget.alive()) return;
        const e = table.matchEntry(tag, ev) orelse continue;
        switch (runEntry(app, e, ev)) {
            .brk, .err => return,
            .cont, .ok => {},
        }
    }
}

// ---- The commands ----

/// A sequence of a virtual event from `event add`.
pub const VirtualDef = struct { name: []u8, pattern: Pattern, text: []u8 };

pub fn freeVirtual(gpa: std.mem.Allocator, d: VirtualDef) void {
    gpa.free(d.name);
    gpa.free(d.text);
    d.pattern.free(gpa);
}

pub fn cmdBind(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    app.enter();
    defer app.leave();
    if (argv.len < 2 or argv.len > 4) return it.wrongArgs("bind window ?pattern? ?command?");
    const tag = try it.str(argv[1]);
    const a = it.alloc();
    if (argv.len == 2) {
        const pats = try app.bindings.list(tag, a);
        const items = try a.alloc(Value, pats.len);
        for (pats, items) |p, *slot| {
            var buf: [512]u8 = undefined;
            slot.* = .{ .str = try a.dupe(u8, formatPattern(p, &buf)) };
        }
        return ztcl.value.wrapList(a, items);
    }
    const p = try parsePattern(it, try it.str(argv[2]));
    if (argv.len == 3) return .{ .str = try a.dupe(u8, app.bindings.get(tag, p) orelse "") };
    const script = try it.str(argv[3]);
    app.bindings.set(tag, p, script) catch return error.OutOfMemory;
    return Value.empty;
}

pub fn cmdBindtags(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    app.enter();
    defer app.leave();
    if (argv.len < 2 or argv.len > 3) return it.wrongArgs("bindtags window ?taglist?");
    const path = try it.str(argv[1]);
    const w = app.lookup(path) orelse return it.fail("bad window path name \"{s}\"", .{path});
    const a = it.alloc();
    if (argv.len == 2) {
        var buf: [4][]const u8 = undefined;
        const tags = tagsOf(w, &buf);
        const items = try a.alloc(Value, tags.len);
        for (tags, items) |t, *slot| slot.* = .{ .str = try a.dupe(u8, t) };
        return ztcl.value.wrapList(a, items);
    }
    const parts = try it.list(argv[2]);
    w.setBindtags(parts, it) catch return error.OutOfMemory;
    return Value.empty;
}
