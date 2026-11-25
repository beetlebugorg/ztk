//! Event patterns, the binding table, and the commands `bind` and
//! `bindtags`. A pattern is one event: a type, the modifiers that it
//! needs, a click count, and a detail (a button or a key symbol). The
//! table keeps the scripts of each tag in the order that they were made.
//! `match` picks the most specific pattern that fits an event: a detail
//! first, then a higher count, then more modifiers, then a physical
//! pattern before a virtual one, and the newest pattern for equal rank.
//! `substitute` fills the `%` fields. `deliver` runs the scripts of the
//! tags of a widget in order, and a script can stop the later tags with
//! `break`. A script with no `%` field compiles once and compiles again
//! when `App.script_gen` changes.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const event = @import("event.zig");
const keysym = @import("keysym.zig");
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
    destroy = 17,
    unmap = 18,
    map = 19,
    configure = 22,
    virtual = 35,
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

    fn eql(a: Pattern, b: Pattern) bool {
        return a.type == b.type and @as(u16, @bitCast(a.mods)) == @as(u16, @bitCast(b.mods)) and
            a.count == b.count and a.detail == b.detail and std.mem.eql(u8, a.virtual, b.virtual);
    }
};

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

/// Parses one event pattern: "<Control-Button-1>", "<<Copy>>", "a".
pub fn parsePattern(it: *ztcl.Interp, text: []const u8) ztcl.Error!Pattern {
    if (text.len >= 4 and std.mem.startsWith(u8, text, "<<") and std.mem.endsWith(u8, text, ">>")) {
        const name = text[2 .. text.len - 2];
        if (name.len == 0 or std.mem.indexOfAny(u8, name, "<>") != null) return it.fail("virtual event \"{s}\" is badly formed", .{text});
        return .{ .type = .virtual, .virtual = try it.alloc().dupe(u8, name) };
    }
    if (text.len == 0 or text[0] != '<') {
        // A plain character is a key press. More than one is a sequence.
        const view = std.unicode.Utf8View.init(text) catch return it.fail("bad event type or keysym \"{s}\"", .{text});
        var cps = view.iterator();
        const first = cps.nextCodepoint() orelse return it.fail("no event type or button # or keysym", .{});
        if (cps.nextCodepoint() != null) return it.fail("event sequences are not supported in this stage", .{});
        return .{ .type = .key_press, .detail = keysym.fromCodepoint(first) };
    }
    const close = std.mem.indexOfScalar(u8, text, '>') orelse return it.fail("missing \">\" in binding", .{});
    if (close != text.len - 1) return it.fail("event sequences are not supported in this stage", .{});
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
            if (findMod(tok)) |m| {
                if (i == n - 1) return it.fail("bad event type or keysym \"{s}\"", .{tok});
                m.set(&p.mods, &count);
                continue;
            }
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
        if (e.pattern.virtual.len > 0) gpa.free(e.pattern.virtual);
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
        var pat = p;
        if (p.virtual.len > 0) pat.virtual = try gpa.dupe(u8, p.virtual);
        errdefer if (p.virtual.len > 0) gpa.free(pat.virtual);
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
        return true;
    }

    fn rank(p: Pattern) u32 {
        const mods: u16 = @bitCast(p.mods);
        return (@as(u32, @intFromBool(p.detail != 0)) << 16) | (@as(u32, p.count) << 12) | (@as(u32, @popCount(mods)) << 4) | @as(u32, @intFromBool(p.type != .virtual));
    }

    fn matchEntry(t: *Table, tag: []const u8, ev: *const WidgetEvent) ?*Entry {
        const l = t.tags.getPtr(tag) orelse return null;
        var best: ?*Entry = null;
        var best_rank: u32 = 0;
        for (l.items) |*e| {
            if (!fits(e.pattern, ev)) continue;
            const r = rank(e.pattern);
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

fn appendQuoted(a: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
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
            'D' => if (wheel) {
                if (ev.delta == @trunc(ev.delta)) try out.print(gpa, "{d}", .{@as(i64, @intFromFloat(ev.delta))}) else try out.print(gpa, "{d}", .{ev.delta});
            } else try out.appendSlice(gpa, "??"),
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
            var buf: [128]u8 = undefined;
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
