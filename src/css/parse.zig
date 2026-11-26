//! The CSS parser. It reads a stylesheet into rules, selectors,
//! declarations, and media conditions. It never fails on bad input. It
//! drops the bad part and records a diagnostic with a line number, as
//! CSS error recovery does: an invalid selector drops its rule, an
//! unknown property drops its declaration, and an unsupported at-rule
//! drops the rule. A sheet owns one arena that holds a copy of the
//! source and all slices. A block that the input leaves open at the end
//! counts as closed.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const tok = @import("token.zig");
const Token = tok.Token;

pub const Combinator = enum { none, descendant, child };

pub const Pseudo = enum {
    hover,
    active,
    focus,
    focus_visible,
    disabled,
    checked,
    read_only,
    invalid,
    indeterminate,
    window_inactive,
    root,
    /// ztk: a scrollbar or a view that scrolled a moment ago.
    scrolling,
    /// An entry with no text and a placeholder.
    placeholder_shown,
};

pub const Compound = struct {
    /// How it joins the compound before it.
    combinator: Combinator = .none,
    /// Null for "*" or no type.
    type_name: ?[]const u8 = null,
    id: ?[]const u8 = null,
    classes: []const []const u8 = &.{},
    pseudos: []const Pseudo = &.{},
    /// The names of :state(name).
    states: []const []const u8 = &.{},
};

pub const Selector = struct {
    /// From left to right.
    compounds: []const Compound,
    /// The name after "::".
    part: ?[]const u8 = null,
    /// ids << 16 | classes << 8 | types
    specificity: u32,
};

pub const Prop = enum {
    color,
    background_color,
    background,
    border,
    border_width,
    border_color,
    border_radius,
    border_style,
    padding,
    padding_top,
    padding_right,
    padding_bottom,
    padding_left,
    font_family,
    font_size,
    font_weight,
    opacity,
    box_shadow,
    outline,
    outline_offset,
    min_width,
    min_height,
    transition,
    animation,
    caret_color,
    cursor,
    text_align,
    custom,
};

pub const Decl = struct {
    prop: Prop,
    /// The property name. For `custom` it starts with "--".
    name: []const u8,
    /// The tokens of the value, with no outer white space.
    value: []const Token,
    line: u32,
};

pub const Media = struct {
    /// prefers-color-scheme: dark is true, light is false.
    dark: ?bool = null,
    /// -ztk-platform
    platform: ?[]const u8 = null,
};

pub const Rule = struct {
    selectors: []const Selector,
    decls: []const Decl,
    media: Media = .{},
    /// The position in the sheet.
    order: u32,
};

pub const Diagnostic = struct { line: u32, message: []const u8 };

/// One stop of a `@keyframes` rule: the offset from 0 to 1 and its declarations.
pub const KeyStop = struct { offset: f32, decls: []const Decl };

/// A `@keyframes` rule. The stops are sorted by offset.
pub const Keyframes = struct { name: []const u8, stops: []const KeyStop };

pub const Sheet = struct {
    rules: []const Rule,
    keyframes: []const Keyframes = &.{},
    diagnostics: []const Diagnostic,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(s: *Sheet) void {
        s.arena.deinit();
    }
};

const prop_names = [_]struct { []const u8, Prop }{
    .{ "color", .color },
    .{ "background-color", .background_color },
    .{ "background", .background },
    .{ "border", .border },
    .{ "border-width", .border_width },
    .{ "border-color", .border_color },
    .{ "border-radius", .border_radius },
    .{ "border-style", .border_style },
    .{ "padding", .padding },
    .{ "padding-top", .padding_top },
    .{ "padding-right", .padding_right },
    .{ "padding-bottom", .padding_bottom },
    .{ "padding-left", .padding_left },
    .{ "font-family", .font_family },
    .{ "font-size", .font_size },
    .{ "font-weight", .font_weight },
    .{ "opacity", .opacity },
    .{ "box-shadow", .box_shadow },
    .{ "outline", .outline },
    .{ "outline-offset", .outline_offset },
    .{ "min-width", .min_width },
    .{ "min-height", .min_height },
    .{ "transition", .transition },
    .{ "animation", .animation },
    .{ "caret-color", .caret_color },
    .{ "cursor", .cursor },
    .{ "text-align", .text_align },
};

const pseudo_names = [_]struct { []const u8, Pseudo }{
    .{ "hover", .hover },
    .{ "active", .active },
    .{ "focus", .focus },
    .{ "focus-visible", .focus_visible },
    .{ "disabled", .disabled },
    .{ "checked", .checked },
    .{ "read-only", .read_only },
    .{ "invalid", .invalid },
    .{ "indeterminate", .indeterminate },
    .{ "window-inactive", .window_inactive },
    .{ "root", .root },
    .{ "scrolling", .scrolling },
    .{ "placeholder-shown", .placeholder_shown },
};

const Err = std.mem.Allocator.Error;

const Parser = struct {
    a: std.mem.Allocator,
    toks: []const Token,
    lines: []const u32,
    pos: usize = 0,
    rules: std.ArrayListUnmanaged(Rule) = .empty,
    keyframes: std.ArrayListUnmanaged(Keyframes) = .empty,
    diags: std.ArrayListUnmanaged(Diagnostic) = .empty,
    order: u32 = 0,

    fn diag(p: *Parser, line: u32, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(p.a, fmt, args);
        try p.diags.append(p.a, .{ .line = line, .message = msg });
    }

    fn lineAt(p: *const Parser, i: usize) u32 {
        return if (i < p.lines.len) p.lines[i] else if (p.lines.len > 0) p.lines[p.lines.len - 1] else 1;
    }

    fn skipWs(p: *Parser) void {
        while (p.pos < p.toks.len and p.toks[p.pos] == .whitespace) p.pos += 1;
    }

    /// The index after the token that closes the block that opens at `open`
    /// (a `{`). An unclosed block ends at the end of the input.
    fn blockEnd(p: *const Parser, open: usize) usize {
        var depth: usize = 0;
        var i = open;
        while (i < p.toks.len) : (i += 1) {
            switch (p.toks[i]) {
                .lbrace => depth += 1,
                .rbrace => {
                    depth -= 1;
                    if (depth == 0) return i + 1;
                },
                else => {},
            }
        }
        return p.toks.len;
    }

    fn parseSheet(p: *Parser) !void {
        try p.parseRules(.{}, p.toks.len);
    }

    fn parseRules(p: *Parser, media: Media, end: usize) Err!void {
        while (true) {
            p.skipWs();
            if (p.pos >= end) return;
            switch (p.toks[p.pos]) {
                .at_keyword => |name| try p.atRule(name, media, end),
                .rbrace, .semicolon => p.pos += 1,
                else => try p.styleRule(media, end),
            }
        }
    }

    fn atRule(p: *Parser, name: []const u8, media: Media, end: usize) Err!void {
        const line = p.lineAt(p.pos);
        p.pos += 1;
        const start = p.pos;
        // The prelude runs to a `{` or a `;`.
        while (p.pos < end and p.toks[p.pos] != .lbrace and p.toks[p.pos] != .semicolon) p.pos += 1;
        const prelude = p.toks[start..p.pos];
        const has_block = p.pos < end and p.toks[p.pos] == .lbrace;
        const block_end = if (has_block) @min(p.blockEnd(p.pos), end) else p.pos;
        const block_open = p.pos;
        if (has_block) {
            p.pos = block_end;
        } else if (p.pos < end) p.pos += 1;
        if (std.ascii.eqlIgnoreCase(name, "keyframes")) {
            if (!has_block) return p.diag(line, "@keyframes has no block", .{});
            const inner_end = if (block_end > block_open + 1 and p.toks[block_end - 1] == .rbrace) block_end - 1 else block_end;
            return p.keyframesRule(trimWs(prelude), block_open + 1, inner_end, line);
        }
        if (!std.ascii.eqlIgnoreCase(name, "media")) {
            return p.diag(line, "unsupported at-rule @{s}", .{name});
        }
        if (!has_block) return p.diag(line, "@media has no block", .{});
        var m = media;
        if (!try p.mediaCondition(prelude, &m)) {
            return p.diag(line, "unsupported media condition", .{});
        }
        // Parse the rules inside the block.
        const inner_end = if (block_end > block_open + 1 and p.toks[block_end - 1] == .rbrace) block_end - 1 else block_end;
        const saved = p.pos;
        p.pos = block_open + 1;
        try p.parseRules(m, inner_end);
        p.pos = saved;
    }

    /// `@keyframes name { from { ... } 50% { ... } to { ... } }`
    fn keyframesRule(p: *Parser, prelude: []const Token, start: usize, end: usize, line: u32) Err!void {
        if (prelude.len != 1 or (prelude[0] != .ident and prelude[0] != .string)) return p.diag(line, "@keyframes needs one name", .{});
        const kname = if (prelude[0] == .ident) prelude[0].ident else prelude[0].string;
        var stops: std.ArrayListUnmanaged(KeyStop) = .empty;
        var i = start;
        while (i < end) {
            while (i < end and p.toks[i] == .whitespace) i += 1;
            if (i >= end) break;
            const sel_start = i;
            while (i < end and p.toks[i] != .lbrace) i += 1;
            if (i >= end) break;
            const open = i;
            const close = @min(p.blockEnd(open), end);
            const inner = if (close > open + 1 and p.toks[close - 1] == .rbrace) close - 1 else close;
            const decls = try p.declarations(p.toks[open + 1 .. inner], p.lines[@min(open + 1, p.lines.len)..@min(inner, p.lines.len)]);
            // The selector is a list of `from`, `to`, and percentages.
            for (p.toks[sel_start..open]) |t| {
                const off: ?f32 = switch (t) {
                    .ident => |n| if (std.ascii.eqlIgnoreCase(n, "from")) 0 else if (std.ascii.eqlIgnoreCase(n, "to")) 1 else null,
                    .percentage => |v| std.math.clamp(v / 100, 0, 1),
                    else => null,
                };
                if (off) |o| try stops.append(p.a, .{ .offset = o, .decls = decls });
            }
            i = close;
        }
        std.mem.sort(KeyStop, stops.items, {}, struct {
            fn less(_: void, a: KeyStop, b: KeyStop) bool {
                return a.offset < b.offset;
            }
        }.less);
        try p.keyframes.append(p.a, .{ .name = kname, .stops = stops.items });
    }

    fn mediaCondition(p: *Parser, prelude: []const Token, m: *Media) !bool {
        _ = p;
        var i: usize = 0;
        var any = false;
        while (true) {
            while (i < prelude.len and prelude[i] == .whitespace) i += 1;
            if (i >= prelude.len) return any;
            if (any) {
                if (prelude[i] != .ident or !std.ascii.eqlIgnoreCase(prelude[i].ident, "and")) return false;
                i += 1;
                while (i < prelude.len and prelude[i] == .whitespace) i += 1;
            }
            // ( name : value )
            var j = i;
            if (j >= prelude.len or prelude[j] != .lparen) return false;
            j += 1;
            while (j < prelude.len and prelude[j] == .whitespace) j += 1;
            if (j >= prelude.len or prelude[j] != .ident) return false;
            const feature = prelude[j].ident;
            j += 1;
            while (j < prelude.len and prelude[j] == .whitespace) j += 1;
            if (j >= prelude.len or prelude[j] != .colon) return false;
            j += 1;
            while (j < prelude.len and prelude[j] == .whitespace) j += 1;
            if (j >= prelude.len or prelude[j] != .ident) return false;
            const value = prelude[j].ident;
            j += 1;
            while (j < prelude.len and prelude[j] == .whitespace) j += 1;
            if (j >= prelude.len or prelude[j] != .rparen) return false;
            i = j + 1;
            if (std.ascii.eqlIgnoreCase(feature, "prefers-color-scheme")) {
                if (std.ascii.eqlIgnoreCase(value, "dark")) m.dark = true else if (std.ascii.eqlIgnoreCase(value, "light")) m.dark = false else return false;
            } else if (std.ascii.eqlIgnoreCase(feature, "-ztk-platform")) {
                m.platform = value;
            } else return false;
            any = true;
        }
    }

    fn styleRule(p: *Parser, media: Media, end: usize) !void {
        const line = p.lineAt(p.pos);
        const start = p.pos;
        while (p.pos < end and p.toks[p.pos] != .lbrace) p.pos += 1;
        if (p.pos >= end) {
            try p.diag(line, "a rule has no block", .{});
            return;
        }
        const prelude = p.toks[start..p.pos];
        const open = p.pos;
        const close = @min(p.blockEnd(open), end);
        p.pos = close;
        const inner_end = if (close > open + 1 and p.toks[close - 1] == .rbrace) close - 1 else close;
        const body = p.toks[open + 1 .. inner_end];
        const body_lines = p.lines[@min(open + 1, p.lines.len)..@min(inner_end, p.lines.len)];
        const sels = (try p.selectorList(prelude, line)) orelse return;
        const decls = try p.declarations(body, body_lines);
        try p.rules.append(p.a, .{ .selectors = sels, .decls = decls, .media = media, .order = p.order });
        p.order += 1;
    }

    // ---- selectors ----

    fn selectorList(p: *Parser, prelude: []const Token, line: u32) !?[]const Selector {
        var list: std.ArrayListUnmanaged(Selector) = .empty;
        var start: usize = 0;
        var i: usize = 0;
        while (i <= prelude.len) : (i += 1) {
            if (i == prelude.len or prelude[i] == .comma) {
                const sel = (try p.selector(prelude[start..i], line)) orelse return null;
                try list.append(p.a, sel);
                start = i + 1;
            }
        }
        return list.items;
    }

    fn trimWs(t: []const Token) []const Token {
        var a: usize = 0;
        var b = t.len;
        while (a < b and t[a] == .whitespace) a += 1;
        while (b > a and t[b - 1] == .whitespace) b -= 1;
        return t[a..b];
    }

    fn selector(p: *Parser, raw: []const Token, line: u32) !?Selector {
        const t = trimWs(raw);
        if (t.len == 0) {
            try p.diag(line, "empty selector", .{});
            return null;
        }
        var compounds: std.ArrayListUnmanaged(Compound) = .empty;
        var classes: std.ArrayListUnmanaged([]const u8) = .empty;
        var pseudos: std.ArrayListUnmanaged(Pseudo) = .empty;
        var states: std.ArrayListUnmanaged([]const u8) = .empty;
        var cur: Compound = .{};
        var have_any = false;
        var part: ?[]const u8 = null;
        var combinator: Combinator = .none;
        var ids: u32 = 0;
        var cls: u32 = 0;
        var types: u32 = 0;
        var i: usize = 0;
        while (i < t.len) {
            if (part != null) {
                try p.diag(line, "a part must be last in a selector", .{});
                return null;
            }
            switch (t[i]) {
                .whitespace => {
                    // End of the compound.
                    if (!have_any) return null;
                    try p.finish(&compounds, &cur, &classes, &pseudos, &states, combinator);
                    have_any = false;
                    combinator = .descendant;
                    i += 1;
                    while (i < t.len and t[i] == .whitespace) i += 1;
                    if (i < t.len and t[i] == .delim and t[i].delim == '>') {
                        combinator = .child;
                        i += 1;
                        while (i < t.len and t[i] == .whitespace) i += 1;
                    }
                    if (i >= t.len) {
                        try p.diag(line, "a selector ends in a combinator", .{});
                        return null;
                    }
                },
                .delim => |d| {
                    if (d == '*' and !have_any) {
                        have_any = true;
                        i += 1;
                    } else if (d == '.' and i + 1 < t.len and t[i + 1] == .ident) {
                        try classes.append(p.a, t[i + 1].ident);
                        cls += 1;
                        have_any = true;
                        i += 2;
                    } else if (d == '>') {
                        if (!have_any) {
                            try p.diag(line, "a selector starts with a combinator", .{});
                            return null;
                        }
                        try p.finish(&compounds, &cur, &classes, &pseudos, &states, combinator);
                        have_any = false;
                        combinator = .child;
                        i += 1;
                        while (i < t.len and t[i] == .whitespace) i += 1;
                        if (i >= t.len) {
                            try p.diag(line, "a selector ends in a combinator", .{});
                            return null;
                        }
                    } else {
                        try p.diag(line, "unsupported selector syntax", .{});
                        return null;
                    }
                },
                .ident => |name| {
                    if (have_any) {
                        try p.diag(line, "unsupported selector syntax", .{});
                        return null;
                    }
                    cur.type_name = name;
                    types += 1;
                    have_any = true;
                    i += 1;
                },
                .hash => |name| {
                    if (cur.id != null) {
                        try p.diag(line, "two ids in one compound", .{});
                        return null;
                    }
                    cur.id = name;
                    ids += 1;
                    have_any = true;
                    i += 1;
                },
                .colon => {
                    if (i + 1 >= t.len) return null;
                    switch (t[i + 1]) {
                        .colon => {
                            if (i + 2 >= t.len or t[i + 2] != .ident) {
                                try p.diag(line, "a part needs a name", .{});
                                return null;
                            }
                            part = t[i + 2].ident;
                            types += 1;
                            have_any = true;
                            i += 3;
                        },
                        .ident => |name| {
                            const ps = for (pseudo_names) |pn| {
                                if (std.ascii.eqlIgnoreCase(pn[0], name)) break pn[1];
                            } else {
                                try p.diag(line, "unknown pseudo-class :{s}", .{name});
                                return null;
                            };
                            try pseudos.append(p.a, ps);
                            cls += 1;
                            have_any = true;
                            i += 2;
                        },
                        .function => |name| {
                            // `:state(!name)` matches a widget without the state.
                            const neg = i + 3 < t.len and t[i + 2] == .delim and t[i + 2].delim == '!';
                            const k = i + 2 + @intFromBool(neg);
                            if (!std.ascii.eqlIgnoreCase(name, "state") or k + 2 > t.len or t[k] != .ident or t[k + 1] != .rparen) {
                                try p.diag(line, "unknown functional pseudo-class :{s}()", .{name});
                                return null;
                            }
                            try states.append(p.a, if (neg) try std.fmt.allocPrint(p.a, "!{s}", .{t[k].ident}) else t[k].ident);
                            cls += 1;
                            have_any = true;
                            i = k + 2;
                        },
                        else => {
                            try p.diag(line, "bad pseudo-class", .{});
                            return null;
                        },
                    }
                },
                else => {
                    try p.diag(line, "unsupported selector syntax", .{});
                    return null;
                },
            }
        }
        if (!have_any) return null;
        try p.finish(&compounds, &cur, &classes, &pseudos, &states, combinator);
        return .{
            .compounds = compounds.items,
            .part = part,
            .specificity = (ids << 16) | (@as(u32, @min(cls, 255)) << 8) | @as(u32, @min(types, 255)),
        };
    }

    fn finish(
        p: *Parser,
        compounds: *std.ArrayListUnmanaged(Compound),
        cur: *Compound,
        classes: *std.ArrayListUnmanaged([]const u8),
        pseudos: *std.ArrayListUnmanaged(Pseudo),
        states: *std.ArrayListUnmanaged([]const u8),
        combinator: Combinator,
    ) !void {
        cur.combinator = combinator;
        cur.classes = classes.items;
        cur.pseudos = pseudos.items;
        cur.states = states.items;
        try compounds.append(p.a, cur.*);
        cur.* = .{};
        classes.* = .empty;
        pseudos.* = .empty;
        states.* = .empty;
    }

    // ---- declarations ----

    fn declarations(p: *Parser, body: []const Token, lines: []const u32) ![]const Decl {
        var out: std.ArrayListUnmanaged(Decl) = .empty;
        var start: usize = 0;
        var depth: usize = 0;
        var i: usize = 0;
        while (i <= body.len) : (i += 1) {
            if (i < body.len) {
                switch (body[i]) {
                    .lparen, .lbracket, .lbrace => depth += 1,
                    .rparen, .rbracket, .rbrace => depth -|= 1,
                    else => {},
                }
            }
            if (i == body.len or (body[i] == .semicolon and depth == 0)) {
                var first = start;
                while (first < i and body[first] == .whitespace) first += 1;
                const line: u32 = if (first < lines.len) lines[first] else if (lines.len > 0) lines[lines.len - 1] else 1;
                try p.declaration(&out, trimWs(body[start..i]), line);
                start = i + 1;
            }
        }
        return out.items;
    }

    fn declaration(p: *Parser, out: *std.ArrayListUnmanaged(Decl), t: []const Token, line: u32) !void {
        if (t.len == 0) return;
        if (t[0] != .ident) {
            try p.diag(line, "a declaration has no name", .{});
            return;
        }
        const name = t[0].ident;
        var i: usize = 1;
        while (i < t.len and t[i] == .whitespace) i += 1;
        if (i >= t.len or t[i] != .colon) {
            try p.diag(line, "a declaration of {s} has no colon", .{name});
            return;
        }
        const value = trimWs(t[i + 1 ..]);
        // `!important` is not supported: the declaration gets a diagnostic.
        if (value.len >= 2) {
            var k = value.len;
            while (k > 0 and value[k - 1] == .whitespace) k -= 1;
            if (k >= 2 and value[k - 1] == .ident and std.ascii.eqlIgnoreCase(value[k - 1].ident, "important")) {
                var j = k - 1;
                while (j > 0 and value[j - 1] == .whitespace) j -= 1;
                if (j > 0 and value[j - 1] == .delim and value[j - 1].delim == '!') {
                    try p.diag(line, "!important is not supported ({s})", .{name});
                    return;
                }
            }
        }
        var prop: ?Prop = null;
        if (std.mem.startsWith(u8, name, "--")) {
            prop = .custom;
        } else for (prop_names) |pn| {
            if (std.ascii.eqlIgnoreCase(pn[0], name)) {
                prop = pn[1];
                break;
            }
        }
        const pr = prop orelse {
            try p.diag(line, "unknown property {s}", .{name});
            return;
        };
        try out.append(p.a, .{ .prop = pr, .name = name, .value = value, .line = line });
    }
};

pub fn parse(gpa: std.mem.Allocator, src: []const u8) std.mem.Allocator.Error!Sheet {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const copy = try a.dupe(u8, src);
    var tz: tok.Tokenizer = .{ .src = copy, .alloc = a };
    var toks: std.ArrayListUnmanaged(Token) = .empty;
    var lines: std.ArrayListUnmanaged(u32) = .empty;
    while (true) {
        const line = tz.line;
        const t = tz.next();
        if (t == .eof) break;
        try toks.append(a, t);
        try lines.append(a, line);
    }
    var p: Parser = .{ .a = a, .toks = toks.items, .lines = lines.items };
    try p.parseSheet();
    return .{ .rules = p.rules.items, .keyframes = p.keyframes.items, .diagnostics = p.diags.items, .arena = arena };
}
