//! The key map of the compositor, with no library. The compositor sends a
//! key map in the XKB text format (version 1) through `wl_keyboard.keymap`.
//! `Keymap.parse` reads the parts that a client needs:
//!
//! - `xkb_keycodes`: the key names (`<AC01> = 38;`) and the aliases.
//! - `xkb_types`: for each type, its modifiers and the level of each
//!   combination (`map[Shift+LevelThree]= 4;`).
//! - `xkb_symbols`: for each key, its type and the symbols of each level
//!   in each group, `repeat= No`, and the `modifier_map` lines.
//!
//! The compatibility section and the actions are not read. The modifier
//! state comes from the compositor (`wl_keyboard.modifiers`), so the
//! client needs no actions. A virtual modifier (NumLock, LevelThree, Alt)
//! counts as active when its bit in the state is set, or when the real
//! modifier of its key in `modifier_map` is set.
//!
//! The source of the format is "The XKB Configuration Guide" and the
//! keymap format text of the xkbcommon documentation (MIT license).
//! docs/references/wayland.md has the list.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const keysyms = @import("keysyms.zig");

/// The real modifiers, in the order of their bits.
pub const real_names = [_][]const u8{ "Shift", "Lock", "Control", "Mod1", "Mod2", "Mod3", "Mod4", "Mod5" };

const max_groups = 4;
const max_levels = 8;

const Type = struct {
    name: []const u8,
    /// The modifiers of the type, as bits of `Keymap.mods`.
    mods: u32 = 0,
    entries: std.ArrayListUnmanaged(struct { mods: u32, level: u8 }) = .empty,
};

const Key = struct {
    /// The index of the type of each group, or null for the automatic type.
    types: [max_groups]?u16 = @splat(null),
    syms: [max_groups][max_levels]u32 = @splat(@splat(0)),
    levels: [max_groups]u8 = @splat(0),
    groups: u8 = 0,
    repeats: bool = true,
};

pub const Keymap = struct {
    gpa: std.mem.Allocator,
    /// The names of the modifiers: the 8 real ones, then the virtual ones,
    /// in the order of `virtual_modifiers`. A bit of the state is the index.
    mods: std.ArrayListUnmanaged([]const u8) = .empty,
    /// The real modifiers of each modifier (a mask of the bits 0 to 7).
    real_of: std.ArrayListUnmanaged(u8) = .empty,
    types: std.ArrayListUnmanaged(Type) = .empty,
    /// The keys by key code (the evdev code plus 8).
    keys: std.AutoHashMapUnmanaged(u32, Key) = .empty,
    names: std.StringHashMapUnmanaged(u32) = .empty,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(k: *Keymap) void {
        k.mods.deinit(k.gpa);
        k.real_of.deinit(k.gpa);
        for (k.types.items) |*t| t.entries.deinit(k.gpa);
        k.types.deinit(k.gpa);
        k.keys.deinit(k.gpa);
        k.names.deinit(k.gpa);
        k.arena.deinit();
    }

    pub fn parse(gpa: std.mem.Allocator, src: []const u8) !Keymap {
        var k: Keymap = .{ .gpa = gpa, .arena = .init(gpa) };
        errdefer k.deinit();
        for (real_names, 0..) |n, i| {
            try k.mods.append(gpa, n);
            try k.real_of.append(gpa, @as(u8, 1) << @intCast(i));
        }
        var p: Parser = .{ .s = src };
        while (p.word()) |w| {
            if (w.len == 0) {
                // A bracket or a comma between the sections.
                p.i += 1;
            } else if (std.mem.eql(u8, w, "xkb_keycodes")) {
                try k.section(&p, .keycodes);
            } else if (std.mem.eql(u8, w, "xkb_types")) {
                try k.section(&p, .types);
            } else if (std.mem.eql(u8, w, "xkb_symbols")) {
                try k.section(&p, .symbols);
            } else if (std.mem.eql(u8, w, "xkb_keymap")) {
                p.skipTo('{');
            } else if (std.mem.startsWith(u8, w, "xkb_")) {
                p.skipTo('{');
                p.skipBlock();
            }
        }
        if (k.keys.count() == 0) return error.BadKeymap;
        return k;
    }

    const Section = enum { keycodes, types, symbols };

    fn section(k: *Keymap, p: *Parser, which: Section) !void {
        p.skipTo('{');
        while (true) {
            p.space();
            if (p.peek() == '}') {
                p.i += 1;
                p.skipTo(';');
                return;
            }
            if (p.peek() == 0) return;
            const at = p.i;
            switch (which) {
                .keycodes => try k.keycodeLine(p),
                .types => try k.typeLine(p),
                .symbols => try k.symbolLine(p),
            }
            // A line that the reader does not know: step over one character.
            if (p.i == at) p.i += 1;
        }
    }

    fn keycodeLine(k: *Keymap, p: *Parser) !void {
        if (p.peek() == '<') {
            const name = p.keyName();
            p.space();
            if (p.peek() == '=') p.i += 1;
            p.space();
            const code = p.number() orelse 0;
            p.skipTo(';');
            if (code > 0) try k.names.put(k.gpa, try k.arena.allocator().dupe(u8, name), code);
            return;
        }
        const w = p.word() orelse {
            p.skipStatement();
            return;
        };
        if (std.mem.eql(u8, w, "alias")) {
            p.space();
            const alias = p.keyName();
            p.space();
            if (p.peek() == '=') p.i += 1;
            p.space();
            const real = p.keyName();
            p.skipTo(';');
            if (k.names.get(real)) |code| try k.names.put(k.gpa, try k.arena.allocator().dupe(u8, alias), code);
            return;
        }
        p.skipStatement();
    }

    /// The index of a modifier name, made when it is new.
    fn modIndex(k: *Keymap, name: []const u8) !usize {
        for (k.mods.items, 0..) |m, i| if (std.ascii.eqlIgnoreCase(m, name)) return i;
        try k.mods.append(k.gpa, try k.arena.allocator().dupe(u8, name));
        try k.real_of.append(k.gpa, 0);
        return k.mods.items.len - 1;
    }

    /// A mask of modifier names joined with `+` (or `none`, `all`).
    fn modMask(k: *Keymap, spec: []const u8) !u32 {
        var mask: u32 = 0;
        var it = std.mem.tokenizeAny(u8, spec, "+ \t\r\n");
        while (it.next()) |n| {
            if (std.ascii.eqlIgnoreCase(n, "none")) continue;
            if (std.ascii.eqlIgnoreCase(n, "all")) {
                mask |= 0xff;
                continue;
            }
            const i = try k.modIndex(n);
            if (i < 32) mask |= @as(u32, 1) << @intCast(i);
        }
        return mask;
    }

    fn typeLine(k: *Keymap, p: *Parser) !void {
        const w = p.word() orelse {
            p.skipStatement();
            return;
        };
        if (std.mem.eql(u8, w, "virtual_modifiers")) {
            const list = p.until(';');
            var it = std.mem.tokenizeAny(u8, list, ", \t\r\n");
            while (it.next()) |n| {
                const name = if (std.mem.indexOfScalar(u8, n, '=')) |e| n[0..e] else n;
                _ = try k.modIndex(name);
            }
            return;
        }
        if (!std.mem.eql(u8, w, "type")) {
            p.skipStatement();
            return;
        }
        p.space();
        const name = p.quoted();
        var t: Type = .{ .name = try k.arena.allocator().dupe(u8, name) };
        errdefer t.entries.deinit(k.gpa);
        p.skipTo('{');
        while (true) {
            p.space();
            if (p.peek() == '}' or p.peek() == 0) {
                if (p.peek() == '}') p.i += 1;
                p.skipTo(';');
                break;
            }
            const stmt = p.until(';');
            const eq = std.mem.indexOfScalar(u8, stmt, '=') orelse continue;
            const lhs = std.mem.trim(u8, stmt[0..eq], " \t\r\n");
            const rhs = std.mem.trim(u8, stmt[eq + 1 ..], " \t\r\n");
            if (std.mem.eql(u8, lhs, "modifiers")) {
                t.mods = try k.modMask(rhs);
            } else if (std.mem.startsWith(u8, lhs, "map[")) {
                const inner = lhs[4 .. std.mem.indexOfScalar(u8, lhs, ']') orelse lhs.len];
                const lvl = levelNumber(rhs) orelse continue;
                try t.entries.append(k.gpa, .{ .mods = try k.modMask(inner), .level = lvl });
            }
        }
        try k.types.append(k.gpa, t);
    }

    fn levelNumber(spec: []const u8) ?u8 {
        var s = spec;
        if (std.ascii.startsWithIgnoreCase(s, "level")) s = s[5..];
        const n = std.fmt.parseInt(u8, s, 10) catch return null;
        if (n == 0 or n > max_levels) return null;
        return n;
    }

    fn typeIndex(k: *Keymap, name: []const u8) ?u16 {
        for (k.types.items, 0..) |t, i| if (std.mem.eql(u8, t.name, name)) return @intCast(i);
        return null;
    }

    fn symbolLine(k: *Keymap, p: *Parser) !void {
        const w = p.word() orelse {
            p.skipStatement();
            return;
        };
        if (std.mem.eql(u8, w, "modifier_map")) {
            p.space();
            const mod_name = p.word() orelse "";
            const real = for (real_names, 0..) |n, i| {
                if (std.ascii.eqlIgnoreCase(n, mod_name)) break @as(u8, 1) << @intCast(i);
            } else 0;
            const list = p.until(';');
            if (real == 0) return;
            // Each virtual modifier of a key in the list gets this real modifier.
            var it = std.mem.tokenizeAny(u8, list, "{}, \t\r\n");
            while (it.next()) |n| {
                const kn = std.mem.trim(u8, n, "<>");
                const code = k.names.get(kn) orelse continue;
                const key = k.keys.get(code) orelse continue;
                for (0..key.levels[0]) |l| k.bindVirtual(key.syms[0][l], real);
            }
            return;
        }
        if (!std.mem.eql(u8, w, "key")) {
            p.skipStatement();
            return;
        }
        p.space();
        const name = p.keyName();
        p.skipTo('{');
        var key: Key = .{};
        var group: usize = 0;
        while (true) {
            p.space();
            const ch = p.peek();
            if (ch == 0) return;
            if (ch == '}') {
                p.i += 1;
                p.skipTo(';');
                break;
            }
            if (ch == ',') {
                p.i += 1;
                continue;
            }
            if (ch == '[') {
                // A list of symbols with no name is the next group.
                try k.symbolList(p, &key, group);
                group += 1;
                continue;
            }
            const field = p.word() orelse {
                p.i += 1;
                continue;
            };
            var idx: ?usize = null;
            p.space();
            if (p.peek() == '[') {
                const inner = p.until(']');
                const d = std.mem.trim(u8, inner, "[ \t");
                idx = if (std.ascii.startsWithIgnoreCase(d, "group")) (std.fmt.parseInt(usize, d[5..], 10) catch 1) -| 1 else (std.fmt.parseInt(usize, d, 10) catch 1) -| 1;
            }
            p.space();
            if (p.peek() == '=') p.i += 1;
            p.space();
            if (std.mem.eql(u8, field, "symbols")) {
                const g = idx orelse group;
                try k.symbolList(p, &key, g);
                group = g + 1;
            } else if (std.mem.eql(u8, field, "type")) {
                const tn = p.quoted();
                const ti = k.typeIndex(tn);
                if (idx) |g| {
                    if (g < max_groups) key.types[g] = ti;
                } else key.types = @splat(ti);
            } else if (std.mem.eql(u8, field, "repeat")) {
                const v = p.word() orelse "";
                key.repeats = !(std.ascii.eqlIgnoreCase(v, "no") or std.ascii.eqlIgnoreCase(v, "false"));
            } else {
                // actions[...] = [ ... ], virtualMods= ..., and others.
                p.skipValue();
            }
        }
        const code = k.names.get(name) orelse return;
        for (0..key.levels[0]) |l| if (isModifierSym(key.syms[0][l])) {
            key.repeats = false;
        };
        try k.keys.put(k.gpa, code, key);
    }

    fn symbolList(k: *Keymap, p: *Parser, key: *Key, group: usize) !void {
        _ = k;
        const body = p.until(']');
        if (group >= max_groups) return;
        var it = std.mem.tokenizeAny(u8, body, "[, \t\r\n");
        var n: u8 = 0;
        while (it.next()) |s| {
            if (n >= max_levels) break;
            key.syms[group][n] = symFromName(s);
            n += 1;
        }
        key.levels[group] = n;
        key.groups = @max(key.groups, @as(u8, @intCast(group + 1)));
    }

    /// The real modifier of a virtual modifier comes from the key that has
    /// its symbol: Num_Lock gives NumLock, ISO_Level3_Shift gives LevelThree.
    fn bindVirtual(k: *Keymap, sym: u32, real: u8) void {
        const vname: []const u8 = switch (sym) {
            0xff7f => "NumLock",
            0xfe03 => "LevelThree",
            0xfe11 => "LevelFive",
            0xffe9, 0xffea => "Alt",
            0xffe7, 0xffe8 => "Meta",
            0xffeb, 0xffec => "Super",
            0xffed, 0xffee => "Hyper",
            0xff14 => "ScrollLock",
            else => return,
        };
        for (k.mods.items, 0..) |m, i| if (std.mem.eql(u8, m, vname)) {
            k.real_of.items[i] |= real;
        };
    }

    /// The effective modifiers of a state mask, as bits of `mods`: a
    /// virtual modifier is on when its bit is on or its real modifiers are on.
    pub fn effective(k: *const Keymap, mask: u32) u32 {
        var out = mask;
        const real: u8 = @truncate(mask);
        for (k.real_of.items[8..], 8..) |r, i| {
            if (i >= 32) break;
            if (r != 0 and real & r == r) out |= @as(u32, 1) << @intCast(i);
        }
        // A virtual bit also sets its real bits, for the type entries of real modifiers.
        for (k.real_of.items[8..], 8..) |r, i| {
            if (i >= 32) break;
            if (mask & (@as(u32, 1) << @intCast(i)) != 0) out |= r;
        }
        return out;
    }

    /// True when the modifier of this name is on in the effective mask.
    pub fn active(k: *const Keymap, eff: u32, name: []const u8) bool {
        for (k.mods.items, 0..) |m, i| if (i < 32 and std.ascii.eqlIgnoreCase(m, name)) {
            return eff & (@as(u32, 1) << @intCast(i)) != 0;
        };
        return false;
    }

    /// The key symbol of a key code (evdev code plus 8) with a state.
    pub fn symbol(k: *const Keymap, code: u32, mask: u32, group_in: u32) u32 {
        const key = k.keys.get(code) orelse return 0;
        if (key.groups == 0) return 0;
        const g: usize = @intCast(group_in % key.groups);
        const n = key.levels[g];
        if (n == 0) return 0;
        const eff = k.effective(mask);
        var level: u8 = 1;
        if (key.types[g]) |ti| {
            const t = k.types.items[ti];
            const want = eff & t.mods;
            for (t.entries.items) |e| if (e.mods == want) {
                level = e.level;
                break;
            };
        } else level = autoLevel(k, key.syms[g][0..n], eff);
        if (level > n) level = 1;
        return key.syms[g][level - 1];
    }

    /// The level of a key with no type: the automatic types of XKB.
    fn autoLevel(k: *const Keymap, syms: []const u32, eff: u32) u8 {
        const shift = eff & 1 != 0;
        const lock = eff & 2 != 0;
        const three = k.active(eff, "LevelThree");
        const alpha = syms.len >= 2 and isLower(syms[0]) and isUpper(syms[1]);
        var level: u8 = 1;
        if (syms.len >= 2) {
            if (isKeypad(syms[0]) or isKeypad(syms[1])) {
                if (k.active(eff, "NumLock") != shift) level = 2;
            } else if (alpha) {
                if (shift != lock) level = 2;
            } else if (shift) level = 2;
        }
        if (three and syms.len >= 3) level += 2;
        return level;
    }

    pub fn repeats(k: *const Keymap, code: u32) bool {
        const key = k.keys.get(code) orelse return false;
        return key.repeats;
    }
};

fn isLower(s: u32) bool {
    if (s >= 'a' and s <= 'z') return true;
    if (s >= 0xdf and s <= 0xff and s != 0xf7) return true;
    if (s >= 0x0100_0000) {
        const cp = s - 0x0100_0000;
        return cp < 0x80000 and std.unicode.utf8ValidCodepoint(@intCast(cp)) and lowerUpperPair(@intCast(cp));
    }
    const cp = codepoint(s) orelse return false;
    return lowerUpperPair(cp);
}

fn isUpper(s: u32) bool {
    if (s >= 'A' and s <= 'Z') return true;
    if (s >= 0xc0 and s <= 0xde and s != 0xd7) return true;
    return !isLower(s) and codepoint(s) != null and (codepoint(s).? > 0x7f);
}

/// A rough test for a lower case letter outside ASCII: the scripts of
/// Latin, Greek, and Cyrillic, where a lower case letter has an upper
/// case letter below it.
fn lowerUpperPair(cp: u21) bool {
    return switch (cp) {
        0x0100...0x017f => cp % 2 == 1,
        0x03b1...0x03c9 => true,
        0x0430...0x045f => true,
        else => false,
    };
}

fn isKeypad(s: u32) bool {
    return s >= 0xff80 and s <= 0xffbd;
}

fn isModifierSym(s: u32) bool {
    return (s >= 0xffe1 and s <= 0xffee) or (s >= 0xfe01 and s <= 0xfe13) or s == 0xff7f or s == 0xff14;
}

/// The key symbol of a name in a key map.
pub fn symFromName(name: []const u8) u32 {
    if (std.mem.eql(u8, name, "NoSymbol") or std.mem.eql(u8, name, "VoidSymbol")) return 0;
    if (name.len >= 5 and name[0] == 'U') {
        if (std.fmt.parseInt(u21, name[1..], 16)) |cp| {
            return if (cp >= 0x20 and cp < 0x7f or cp >= 0xa0 and cp <= 0xff) cp else 0x0100_0000 + @as(u32, cp);
        } else |_| {}
    }
    if (std.mem.startsWith(u8, name, "0x")) return std.fmt.parseInt(u32, name[2..], 16) catch 0;
    var lo: usize = 0;
    var hi: usize = keysyms.names.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        switch (std.mem.order(u8, keysyms.names[mid].name, name)) {
            .eq => return keysyms.names[mid].sym,
            .lt => lo = mid + 1,
            .gt => hi = mid,
        }
    }
    return 0;
}

/// The Unicode code point of a key symbol, or null.
pub fn codepoint(s: u32) ?u21 {
    if (s >= 0x20 and s <= 0x7e or s >= 0xa0 and s <= 0xff) return @intCast(s);
    if (s >= 0x0100_0000 and s <= 0x0110_ffff) return @intCast(s - 0x0100_0000);
    switch (s) {
        0xff80 => return ' ',
        0xffaa...0xffb9 => return @intCast(s - 0xff80),
        0xffbd => return '=',
        else => {},
    }
    var lo: usize = 0;
    var hi: usize = keysyms.codes.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const c = keysyms.codes[mid];
        if (c.sym == s) return c.cp;
        if (c.sym < s) lo = mid + 1 else hi = mid;
    }
    return null;
}

/// The UTF-8 text of a key symbol. Control and Alt give no text, and the
/// keys Return, Tab, BackSpace, and Escape give their control character.
pub fn text(sym: u32, control: bool, alt: bool, buf: *[8]u8) []const u8 {
    if (control or alt) return buf[0..0];
    const cp: u21 = switch (sym) {
        0xff0d, 0xff8d => '\r',
        0xff09 => '\t',
        0xff08 => 0x08,
        0xff1b => 0x1b,
        else => codepoint(sym) orelse return buf[0..0],
    };
    const n = std.unicode.utf8Encode(cp, buf) catch return buf[0..0];
    return buf[0..n];
}

const Parser = struct {
    s: []const u8,
    i: usize = 0,

    fn peek(p: *Parser) u8 {
        return if (p.i < p.s.len) p.s[p.i] else 0;
    }

    /// Skips white space and comments (`//` and `#` to the end of the line, `/* */`).
    fn space(p: *Parser) void {
        while (p.i < p.s.len) {
            const ch = p.s[p.i];
            if (ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n') {
                p.i += 1;
            } else if (ch == '#' or (ch == '/' and p.i + 1 < p.s.len and p.s[p.i + 1] == '/')) {
                while (p.i < p.s.len and p.s[p.i] != '\n') p.i += 1;
            } else if (ch == '/' and p.i + 1 < p.s.len and p.s[p.i + 1] == '*') {
                p.i += 2;
                while (p.i + 1 < p.s.len and !(p.s[p.i] == '*' and p.s[p.i + 1] == '/')) p.i += 1;
                p.i += 2;
            } else break;
        }
    }

    fn word(p: *Parser) ?[]const u8 {
        p.space();
        const start = p.i;
        while (p.i < p.s.len and (std.ascii.isAlphanumeric(p.s[p.i]) or p.s[p.i] == '_')) p.i += 1;
        if (p.i == start) {
            // A character that starts no word: step over it so the loop moves.
            if (p.i < p.s.len and p.s[p.i] != '}' and p.s[p.i] != '[' and p.s[p.i] != ',' and p.s[p.i] != '<') p.i += 1;
            return if (p.i >= p.s.len) null else "";
        }
        return p.s[start..p.i];
    }

    fn number(p: *Parser) ?u32 {
        p.space();
        const start = p.i;
        while (p.i < p.s.len and std.ascii.isDigit(p.s[p.i])) p.i += 1;
        return std.fmt.parseInt(u32, p.s[start..p.i], 10) catch null;
    }

    /// `<NAME>` without the brackets.
    fn keyName(p: *Parser) []const u8 {
        p.space();
        if (p.peek() != '<') return "";
        p.i += 1;
        const start = p.i;
        while (p.i < p.s.len and p.s[p.i] != '>') p.i += 1;
        const n = p.s[start..p.i];
        if (p.i < p.s.len) p.i += 1;
        return n;
    }

    fn quoted(p: *Parser) []const u8 {
        p.space();
        if (p.peek() != '"') return "";
        p.i += 1;
        const start = p.i;
        while (p.i < p.s.len and p.s[p.i] != '"') p.i += 1;
        const n = p.s[start..p.i];
        if (p.i < p.s.len) p.i += 1;
        return n;
    }

    /// The text up to a character, and the character is consumed.
    fn until(p: *Parser, ch: u8) []const u8 {
        const start = p.i;
        while (p.i < p.s.len and p.s[p.i] != ch) p.i += 1;
        const n = p.s[start..p.i];
        if (p.i < p.s.len) p.i += 1;
        return n;
    }

    fn skipTo(p: *Parser, ch: u8) void {
        _ = p.until(ch);
    }

    /// Skips a statement up to its `;`, with the blocks in it.
    fn skipStatement(p: *Parser) void {
        while (p.i < p.s.len) {
            const ch = p.s[p.i];
            if (ch == ';') {
                p.i += 1;
                return;
            }
            if (ch == '{') {
                p.i += 1;
                p.skipBlock();
                continue;
            }
            if (ch == '}') return;
            p.i += 1;
        }
    }

    /// Skips to the end of the block after an opening `{`.
    fn skipBlock(p: *Parser) void {
        var depth: usize = 1;
        while (p.i < p.s.len and depth > 0) : (p.i += 1) {
            switch (p.s[p.i]) {
                '{' => depth += 1,
                '}' => depth -= 1,
                else => {},
            }
        }
        p.skipTo(';');
    }

    /// Skips the value of a field in a key: a list in brackets or a word.
    fn skipValue(p: *Parser) void {
        p.space();
        if (p.peek() == '[') {
            var depth: usize = 0;
            while (p.i < p.s.len) : (p.i += 1) {
                if (p.s[p.i] == '[') depth += 1;
                if (p.s[p.i] == ']') {
                    depth -= 1;
                    if (depth == 0) {
                        p.i += 1;
                        return;
                    }
                }
            }
            return;
        }
        while (p.i < p.s.len and p.s[p.i] != ',' and p.s[p.i] != '}' and p.s[p.i] != ';') p.i += 1;
    }
};

const sample =
    \\xkb_keymap {
    \\xkb_keycodes "(unnamed)" {
    \\    minimum = 8;
    \\    maximum = 255;
    \\    <AE01> = 10;
    \\    <AC01> = 38;
    \\    <LFSH> = 50;
    \\    <RALT> = 108;
    \\    <NMLK> = 77;
    \\    <KP7> = 79;
    \\    <AD03> = 26;
    \\    indicator 1 = "Caps Lock";
    \\    alias <LatA> = <AC01>;
    \\};
    \\xkb_types "(unnamed)" {
    \\    virtual_modifiers NumLock,Alt,LevelThree;
    \\    type "ONE_LEVEL" { modifiers= none; level_name[1]= "Any"; };
    \\    type "TWO_LEVEL" { modifiers= Shift; map[Shift]= 2; level_name[1]= "Base"; };
    \\    type "ALPHABETIC" { modifiers= Shift+Lock; map[Shift]= 2; map[Lock]= 2; };
    \\    type "KEYPAD" { modifiers= Shift+NumLock; map[NumLock]= 2; map[Shift]= Level1; };
    \\    type "FOUR_LEVEL_SEMIALPHABETIC" {
    \\        modifiers= Shift+Lock+LevelThree;
    \\        map[Shift]= 2; map[Lock]= 2; map[LevelThree]= 3;
    \\        map[Shift+LevelThree]= 4; map[Lock+LevelThree]= 3;
    \\        preserve[Lock+LevelThree]= Lock;
    \\    };
    \\};
    \\xkb_compatibility "(unnamed)" {
    \\    virtual_modifiers NumLock,Alt,LevelThree;
    \\    interpret Num_Lock+AnyOf(all) { virtualModifier= NumLock; action= LockMods(modifiers=NumLock); };
    \\    indicator "Caps Lock" { whichModState= locked; modifiers= Lock; };
    \\};
    \\xkb_symbols "(unnamed)" {
    \\    name[Group1]="English (US)";
    \\    key <AE01> { [ 1, exclam ] };
    \\    key <AC01> { type= "ALPHABETIC", symbols[Group1]= [ a, A ] };
    \\    key <AD03> { type= "FOUR_LEVEL_SEMIALPHABETIC", symbols[Group1]= [ e, E, EuroSign, cent ] };
    \\    key <LFSH> { [ Shift_L ] };
    \\    key <RALT> { type= "ONE_LEVEL", symbols[Group1]= [ ISO_Level3_Shift ] };
    \\    key <NMLK> { [ Num_Lock ] };
    \\    key <KP7> { type= "KEYPAD", symbols[Group1]= [ KP_Home, KP_7 ], actions[Group1]= [ NoAction(), NoAction() ] };
    \\    modifier_map Shift { <LFSH> };
    \\    modifier_map Mod2 { <NMLK> };
    \\    modifier_map Mod5 { <RALT> };
    \\};
    \\};
;

test "xkb: levels, types, virtual modifiers, and text" {
    var k = try Keymap.parse(std.testing.allocator, sample);
    defer k.deinit();
    const shift: u32 = 1;
    const lock: u32 = 2;
    const mod2: u32 = 1 << 4;
    const mod5: u32 = 1 << 7;
    try std.testing.expectEqual(@as(u32, '1'), k.symbol(10, 0, 0));
    try std.testing.expectEqual(@as(u32, '!'), k.symbol(10, shift, 0));
    try std.testing.expectEqual(@as(u32, 'a'), k.symbol(38, 0, 0));
    try std.testing.expectEqual(@as(u32, 'A'), k.symbol(38, shift, 0));
    try std.testing.expectEqual(@as(u32, 'A'), k.symbol(38, lock, 0));
    try std.testing.expectEqual(@as(u32, 'a'), k.symbol(38, shift | lock, 0));
    // LevelThree is Mod5 through the modifier_map of ISO_Level3_Shift.
    try std.testing.expectEqual(@as(u32, 0x20ac), k.symbol(26, mod5, 0));
    try std.testing.expectEqual(@as(u32, 0xa2), k.symbol(26, mod5 | shift, 0));
    // NumLock is Mod2.
    try std.testing.expectEqual(@as(u32, 0xff95), k.symbol(79, 0, 0));
    try std.testing.expectEqual(@as(u32, 0xffb7), k.symbol(79, mod2, 0));
    try std.testing.expect(!k.repeats(50));
    try std.testing.expect(k.repeats(38));
    try std.testing.expect(k.active(k.effective(mod2), "NumLock"));
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("\u{20ac}", text(0x20ac, false, false, &buf));
    try std.testing.expectEqualStrings("7", text(0xffb7, false, false, &buf));
    try std.testing.expectEqualStrings("", text('a', true, false, &buf));
    try std.testing.expectEqual(@as(u32, 0x0100_0430), symFromName("U0430"));
    try std.testing.expectEqual(@as(u32, 0xfe51), symFromName("dead_acute"));
}

test "xkb: the key maps of xkbcli compile-keymap for us and de" {
    // src/platform/wl/testdata has the output of `xkbcli compile-keymap --layout us` and `--layout de`.
    var us = try Keymap.parse(std.testing.allocator, @embedFile("testdata/us.xkb"));
    defer us.deinit();
    try std.testing.expectEqual(@as(u32, 'a'), us.symbol(38, 0, 0));
    try std.testing.expectEqual(@as(u32, 'A'), us.symbol(38, 1, 0));
    try std.testing.expectEqual(@as(u32, 'A'), us.symbol(38, 2, 0));
    try std.testing.expectEqual(@as(u32, '@'), us.symbol(11, 1, 0));
    try std.testing.expectEqual(@as(u32, 0xff0d), us.symbol(36, 0, 0));
    try std.testing.expect(!us.repeats(50));
    try std.testing.expect(us.repeats(38));
    var de = try Keymap.parse(std.testing.allocator, @embedFile("testdata/de.xkb"));
    defer de.deinit();
    const mod5: u32 = 1 << 7;
    // z and y trade places, and AltGr (LevelThree on Mod5) gives the euro sign on e.
    try std.testing.expectEqual(@as(u32, 'z'), de.symbol(29, 0, 0));
    try std.testing.expectEqual(@as(u32, 0x20ac), de.symbol(26, mod5, 0));
    try std.testing.expectEqual(@as(u32, '@'), de.symbol(24, mod5, 0));
    try std.testing.expectEqual(@as(u32, 0xe4), de.symbol(48, 0, 0));
    try std.testing.expectEqual(@as(u32, 0xc4), de.symbol(48, 1, 0));
}
