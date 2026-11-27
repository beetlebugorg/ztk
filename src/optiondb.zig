//! The option database of Tk and the `option` command: `add`, `clear`,
//! `get`, and `readfile`, from the manual page option.n. A pattern is a
//! list of names and classes with `.` (a tight binding: the next level)
//! or `*` (a loose binding: any count of levels) before each one. A new
//! widget takes the value of the database for each option that the
//! script does not give.
//!
//! When two patterns match, the higher priority wins. With the same
//! priority, the pattern with more tight bindings and more names (not
//! classes) wins, and then the pattern that came last.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const App = @import("app.zig").App;
const Widget = @import("widget.zig").Widget;
const Value = ztcl.Value;

const Elem = struct { loose: bool, word: []u8 };

const Entry = struct {
    elems: []Elem,
    value: []u8,
    priority: u8,
};

pub const Store = struct {
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    pub fn deinit(s: *Store, gpa: std.mem.Allocator) void {
        s.clear(gpa);
        s.entries.deinit(gpa);
    }

    pub fn clear(s: *Store, gpa: std.mem.Allocator) void {
        for (s.entries.items) |e| freeEntry(gpa, e);
        s.entries.clearRetainingCapacity();
    }
};

fn freeEntry(gpa: std.mem.Allocator, e: Entry) void {
    for (e.elems) |el| gpa.free(el.word);
    gpa.free(e.elems);
    gpa.free(e.value);
}

/// The priority of a word or a number from 0 to 100.
fn parsePriority(it: *ztcl.Interp, text: []const u8) ztcl.Error!u8 {
    const names = [_]struct { []const u8, u8 }{ .{ "widgetDefault", 20 }, .{ "startupFile", 40 }, .{ "userDefault", 60 }, .{ "interactive", 80 } };
    for (names) |n| if (text.len > 0 and std.mem.startsWith(u8, n[0], text)) return n[1];
    const n = std.fmt.parseInt(i64, std.mem.trim(u8, text, " "), 10) catch
        return it.fail("bad priority level \"{s}\": must be widgetDefault, startupFile, userDefault, interactive, or a number between 0 and 100", .{text});
    if (n < 0 or n > 100) return it.fail("bad priority level \"{s}\": must be widgetDefault, startupFile, userDefault, interactive, or a number between 0 and 100", .{text});
    return @intCast(n);
}

pub fn add(app: *App, pattern: []const u8, value: []const u8, priority: u8) !void {
    const gpa = app.gpa;
    var elems: std.ArrayListUnmanaged(Elem) = .empty;
    errdefer {
        for (elems.items) |el| gpa.free(el.word);
        elems.deinit(gpa);
    }
    var i: usize = 0;
    var loose = false;
    // A pattern with no binding first starts at the application.
    while (i < pattern.len) {
        if (pattern[i] == '*') {
            loose = true;
            i += 1;
            continue;
        }
        if (pattern[i] == '.') {
            i += 1;
            continue;
        }
        const start = i;
        while (i < pattern.len and pattern[i] != '.' and pattern[i] != '*') i += 1;
        const word = try gpa.dupe(u8, pattern[start..i]);
        errdefer gpa.free(word);
        try elems.append(gpa, .{ .loose = loose, .word = word });
        loose = false;
    }
    if (elems.items.len == 0) return;
    const v = try gpa.dupe(u8, value);
    errdefer gpa.free(v);
    const owned = try elems.toOwnedSlice(gpa);
    errdefer {
        for (owned) |el| gpa.free(el.word);
        gpa.free(owned);
    }
    try app.option_db.entries.append(gpa, .{ .elems = owned, .value = v, .priority = priority });
}

/// One level of the chain of a widget: its name and its class.
const Level = struct { name: []const u8, class: []const u8 };

/// The score of a match of a pattern on the chain, or null. The chain
/// ends with the name and the class of the option.
fn match(elems: []const Elem, chain: []const Level) ?u32 {
    return matchFrom(elems, 0, chain, 0, true);
}

fn matchFrom(elems: []const Elem, e: usize, chain: []const Level, c: usize, first: bool) ?u32 {
    if (e == elems.len) return if (c == chain.len) 0 else null;
    if (c >= chain.len) return null;
    const el = elems[e];
    // The first element with no `*` binds to the application (level 0).
    const can_skip = el.loose;
    var best: ?u32 = null;
    var k = c;
    while (k < chain.len) : (k += 1) {
        if (k > c and !can_skip) break;
        if (first and !el.loose and k != 0) break;
        const lv = chain[k];
        const is_name = std.mem.eql(u8, el.word, lv.name);
        const is_class = std.mem.eql(u8, el.word, lv.class) or std.mem.eql(u8, el.word, "?");
        if (is_name or is_class) {
            if (matchFrom(elems, e + 1, chain, k + 1, false)) |rest| {
                const here: u32 = rest + @as(u32, if (is_name) 2 else 1) + @as(u32, if (el.loose) 0 else 4);
                if (best == null or here > best.?) best = here;
            }
        }
    }
    return best;
}

/// The value of the database for an option of a widget, or null.
pub fn lookup(app: *App, w: *const Widget, name: []const u8, class: []const u8, a: std.mem.Allocator) ?[]const u8 {
    if (app.option_db.entries.items.len == 0) return null;
    var levels: std.ArrayListUnmanaged(Level) = .empty;
    var x: ?*const Widget = w;
    while (x) |n| : (x = n.parent) {
        const nm = if (n.parent == null) app.app_name else n.name();
        const cl = if (n.parent == null) app.root_class else n.tk_class;
        levels.insert(a, 0, .{ .name = nm, .class = cl }) catch return null;
    }
    levels.append(a, .{ .name = name, .class = class }) catch return null;
    var best: ?[]const u8 = null;
    var best_key: u64 = 0;
    for (app.option_db.entries.items, 0..) |e, idx| {
        const score = match(e.elems, levels.items) orelse continue;
        const key: u64 = (@as(u64, e.priority) << 48) | (@as(u64, score) << 24) | @as(u64, @intCast(idx));
        if (best == null or key >= best_key) {
            best = e.value;
            best_key = key;
        }
    }
    return best;
}

/// `option add|clear|get|readfile ...`
pub fn cmdOption(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    if (argv.len < 2) return it.wrongArgs("option cmd arg ?arg ...?");
    const given = try it.str(argv[1]);
    const a = it.alloc();
    // A unique start of a subcommand names it, as in Tk: `option read`.
    var sub = given;
    for ([_][]const u8{ "add", "clear", "get", "readfile" }) |n| {
        if (given.len > 0 and std.mem.startsWith(u8, n, given)) sub = n;
    }
    if (eq(sub, "add")) {
        if (argv.len != 4 and argv.len != 5) return it.wrongArgs("option add pattern value ?priority?");
        const prio: u8 = if (argv.len == 5) try parsePriority(it, try it.str(argv[4])) else 80;
        add(app, try it.str(argv[2]), try it.str(argv[3]), prio) catch return it.memError();
        return Value.empty;
    }
    if (eq(sub, "clear")) {
        if (argv.len != 2) return it.wrongArgs("option clear");
        app.option_db.clear(app.gpa);
        return Value.empty;
    }
    if (eq(sub, "get")) {
        if (argv.len != 5) return it.wrongArgs("option get window name class");
        const path = try it.str(argv[2]);
        const w = app.lookup(path) orelse return it.fail("bad window path name \"{s}\"", .{path});
        const v = lookup(app, w, try it.str(argv[3]), try it.str(argv[4]), a) orelse return Value.empty;
        return .{ .str = try a.dupe(u8, v) };
    }
    if (eq(sub, "readfile")) {
        if (argv.len != 3 and argv.len != 4) return it.wrongArgs("option readfile fileName ?priority?");
        const prio: u8 = if (argv.len == 4) try parsePriority(it, try it.str(argv[3])) else 80;
        const words = [_]Value{ .{ .str = "::ztk::priv::readbinary" }, argv[2] };
        const text = try it.str(try it.eval(try it.str(try ztcl.value.newList(a, &words))));
        try readText(app, it, text, prio);
        return Value.empty;
    }
    return it.fail("bad option \"{s}\": must be add, clear, get, or readfile", .{given});
}

/// Adds the lines `pattern: value` of a resource file. A line that ends
/// with a backslash goes on in the next line; `!` and `#` start comments.
fn readText(app: *App, it: *ztcl.Interp, text: []const u8, prio: u8) ztcl.Error!void {
    const a = it.alloc();
    var joined: std.ArrayListUnmanaged(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len > 0 and line[line.len - 1] == '\\') {
            try joined.appendSlice(a, line[0 .. line.len - 1]);
            continue;
        }
        try joined.appendSlice(a, line);
        const full = std.mem.trim(u8, joined.items, " \t");
        defer joined.clearRetainingCapacity();
        if (full.len == 0 or full[0] == '!' or full[0] == '#') continue;
        const colon = std.mem.indexOfScalar(u8, full, ':') orelse return it.fail("missing colon on line", .{});
        const pat = std.mem.trim(u8, full[0..colon], " \t");
        const val = std.mem.trim(u8, full[colon + 1 ..], " \t");
        add(app, pat, val, prio) catch return it.memError();
    }
}

fn eq(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

test "a loose pattern and a tight pattern" {
    var chain = [_]Level{ .{ .name = "app", .class = "App" }, .{ .name = "f", .class = "Frame" }, .{ .name = "b", .class = "Button" }, .{ .name = "background", .class = "Background" } };
    var w1 = [_]u8{ 'B', 'u', 't', 't', 'o', 'n' };
    var w2 = "background".*;
    var e1 = [_]Elem{ .{ .loose = true, .word = &w1 }, .{ .loose = false, .word = &w2 } };
    try std.testing.expect(match(&e1, &chain) != null);
    var w3 = "f".*;
    var e2 = [_]Elem{ .{ .loose = true, .word = &w3 }, .{ .loose = false, .word = &w2 } };
    try std.testing.expect(match(&e2, &chain) == null);
}
