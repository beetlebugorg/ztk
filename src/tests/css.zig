//! Tests of the CSS tokenizer, the parser, and the value parsers.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const geom = @import("../geom.zig");
const tok = @import("../css/token.zig");
const parse = @import("../css/parse.zig");
const value = @import("../css/value.zig");
const Token = tok.Token;
const t = std.testing;

fn tokens(arena: std.mem.Allocator, src: []const u8) ![]Token {
    var tz: tok.Tokenizer = .{ .src = src, .alloc = arena };
    var list: std.ArrayListUnmanaged(Token) = .empty;
    while (true) {
        const x = tz.next();
        try list.append(arena, x);
        if (x == .eof) break;
    }
    return list.items;
}

test "css: tokens of a{b:1px}" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const got = try tokens(arena.allocator(), "a{b:1px}");
    try t.expectEqual(@as(usize, 7), got.len);
    try t.expectEqualStrings("a", got[0].ident);
    try t.expect(got[1] == .lbrace);
    try t.expectEqualStrings("b", got[2].ident);
    try t.expect(got[3] == .colon);
    try t.expectEqual(@as(f32, 1), got[4].dimension.value);
    try t.expectEqualStrings("px", got[4].dimension.unit);
    try t.expect(got[5] == .rbrace);
    try t.expect(got[6] == .eof);
}

test "css: tokens with a comment, a string, and a percentage" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const got = try tokens(arena.allocator(), "/* x */ #fff \"a\\\"b\" 50% -1.5em");
    try t.expect(got[0] == .whitespace);
    try t.expectEqualStrings("fff", got[1].hash);
    try t.expect(got[2] == .whitespace);
    try t.expectEqualStrings("a\"b", got[3].string);
    try t.expect(got[4] == .whitespace);
    try t.expectEqual(@as(f32, 50), got[5].percentage);
    try t.expect(got[6] == .whitespace);
    try t.expectEqual(@as(f32, -1.5), got[7].dimension.value);
    try t.expectEqualStrings("em", got[7].dimension.unit);
}

test "css: functions, at-keywords, and delimiters" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const got = try tokens(arena.allocator(), "rgb(1) @media a>b --x");
    try t.expectEqualStrings("rgb", got[0].function);
    try t.expectEqualStrings("media", got[4].at_keyword);
    try t.expect(got[7].delim == '>');
    try t.expectEqualStrings("--x", got[10].ident);
}

test "css: a rule with one declaration" {
    var s = try parse.parse(t.allocator, "Button { color: red; }");
    defer s.deinit();
    try t.expectEqual(@as(usize, 1), s.rules.len);
    try t.expectEqual(@as(usize, 1), s.rules[0].selectors.len);
    try t.expectEqualStrings("Button", s.rules[0].selectors[0].compounds[0].type_name.?);
    try t.expectEqual(@as(usize, 1), s.rules[0].decls.len);
    try t.expect(s.rules[0].decls[0].prop == .color);
    try t.expectEqual(@as(usize, 0), s.diagnostics.len);
}

test "css: a selector with two compounds, a child combinator, and a part" {
    var s = try parse.parse(t.allocator, "Button.primary:hover > Label#title::selection { color: red }");
    defer s.deinit();
    const sel = s.rules[0].selectors[0];
    try t.expectEqual(@as(usize, 2), sel.compounds.len);
    try t.expect(sel.compounds[0].combinator == .none);
    try t.expect(sel.compounds[1].combinator == .child);
    try t.expectEqualStrings("primary", sel.compounds[0].classes[0]);
    try t.expect(sel.compounds[0].pseudos[0] == .hover);
    try t.expectEqualStrings("title", sel.compounds[1].id.?);
    try t.expectEqualStrings("selection", sel.part.?);
    // 1 id, 2 class-level items (.primary and :hover), 3 type-level items.
    try t.expectEqual(@as(u32, (1 << 16) | (2 << 8) | 3), sel.specificity);
}

test "css: a descendant combinator and states" {
    var s = try parse.parse(t.allocator, "Frame Label:state(user1) { color: red }");
    defer s.deinit();
    const sel = s.rules[0].selectors[0];
    try t.expect(sel.compounds[1].combinator == .descendant);
    try t.expectEqualStrings("user1", sel.compounds[1].states[0]);
}

test "css: a selector list" {
    var s = try parse.parse(t.allocator, "Button, Label { }");
    defer s.deinit();
    try t.expectEqual(@as(usize, 1), s.rules.len);
    try t.expectEqual(@as(usize, 2), s.rules[0].selectors.len);
}

test "css: an unknown property is dropped with a diagnostic" {
    var s = try parse.parse(t.allocator, "Button { color: red; bogus: 1; background-color: blue }");
    defer s.deinit();
    try t.expectEqual(@as(usize, 2), s.rules[0].decls.len);
    try t.expectEqual(@as(usize, 1), s.diagnostics.len);
    try t.expectEqual(@as(u32, 1), s.diagnostics[0].line);
    try t.expect(std.mem.indexOf(u8, s.diagnostics[0].message, "bogus") != null);
}

test "css: an invalid pseudo-class drops its rule" {
    var s = try parse.parse(t.allocator, "Button:nosuch { color: red } Label { color: blue }");
    defer s.deinit();
    try t.expectEqual(@as(usize, 1), s.rules.len);
    try t.expectEqualStrings("Label", s.rules[0].selectors[0].compounds[0].type_name.?);
    try t.expectEqual(@as(usize, 1), s.diagnostics.len);
}

test "css: one bad selector drops the whole list" {
    var s = try parse.parse(t.allocator, "Button, :nosuch { color: red }");
    defer s.deinit();
    try t.expectEqual(@as(usize, 0), s.rules.len);
}

test "css: media blocks" {
    var s = try parse.parse(t.allocator,
        \\@media (prefers-color-scheme: dark) { Label { color: white } }
        \\@media (-ztk-platform: linux) and (prefers-color-scheme: light) { Label { color: black } }
        \\@media (min-width: 3px) { Label { color: red } }
    );
    defer s.deinit();
    try t.expectEqual(@as(usize, 2), s.rules.len);
    try t.expectEqual(@as(?bool, true), s.rules[0].media.dark);
    try t.expectEqual(@as(?bool, false), s.rules[1].media.dark);
    try t.expectEqualStrings("linux", s.rules[1].media.platform.?);
    try t.expectEqual(@as(usize, 1), s.diagnostics.len);
    try t.expectEqual(@as(u32, 0), s.rules[0].order);
    try t.expectEqual(@as(u32, 1), s.rules[1].order);
}

test "css: an at-rule is dropped" {
    var s = try parse.parse(t.allocator, "@import \"x.css\"; Label { color: red }");
    defer s.deinit();
    try t.expectEqual(@as(usize, 1), s.rules.len);
    try t.expectEqual(@as(usize, 1), s.diagnostics.len);
}

test "css: a custom property" {
    var s = try parse.parse(t.allocator, ":root { --accent: #3366ff; }");
    defer s.deinit();
    try t.expect(s.rules[0].selectors[0].compounds[0].pseudos[0] == .root);
    try t.expect(s.rules[0].decls[0].prop == .custom);
    try t.expectEqualStrings("--accent", s.rules[0].decls[0].name);
}

test "css: important is dropped with a diagnostic" {
    var s = try parse.parse(t.allocator, "Label { color: red !important; opacity: 1 }");
    defer s.deinit();
    try t.expectEqual(@as(usize, 1), s.rules[0].decls.len);
    try t.expectEqual(@as(usize, 1), s.diagnostics.len);
}

test "css: line numbers of declarations" {
    var s = try parse.parse(t.allocator, "Label {\n  color: red;\n  bogus: 1;\n}");
    defer s.deinit();
    try t.expectEqual(@as(u32, 2), s.rules[0].decls[0].line);
    try t.expectEqual(@as(u32, 3), s.diagnostics[0].line);
}

test "css: an input that ends inside a rule" {
    for ([_][]const u8{ "Button { color: re", "Button {", "Button", "@media (prefers-color-scheme: dark) { Label { color: red", "Button { color: rgb(1,", "}}} ;;; {", "a { b: \"unterminated" }) |src| {
        var s = try parse.parse(t.allocator, src);
        s.deinit();
    }
}

test "css: random bytes give no crash and no leak" {
    var prng = std.Random.DefaultPrng.init(0xc55);
    const rnd = prng.random();
    const alphabet = "{}()[];:,.#@>*!/\"' \n\\-+%abcXYZ019";
    var buf: [200]u8 = undefined;
    var n: usize = 0;
    while (n < 1000) : (n += 1) {
        const len = rnd.uintLessThan(usize, buf.len);
        for (buf[0..len]) |*c| c.* = if (n % 3 == 0) rnd.int(u8) else alphabet[rnd.uintLessThan(usize, alphabet.len)];
        var s = try parse.parse(t.allocator, buf[0..len]);
        s.deinit();
    }
}

fn noEof(arena: std.mem.Allocator, src: []const u8) ![]Token {
    const all = try tokens(arena, src);
    return all[0 .. all.len - 1];
}

fn color(src: []const u8) !?geom.Color {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const toks = try tokens(arena.allocator(), src);
    return value.parseColor(toks[0 .. toks.len - 1]);
}

test "css: parseColor forms are equal" {
    const red = geom.Color{ .r = 255, .g = 0, .b = 0, .a = 255 };
    for ([_][]const u8{ "#f00", "#ff0000", "#ff0000ff", "#f00f", "rgb(255, 0, 0)", "rgb(255 0 0 / 1)", "hsl(0, 100%, 50%)", "red", "RED", "rgb(100%, 0%, 0%)" }) |src| {
        try t.expectEqual(@as(?geom.Color, red), try color(src));
    }
    const half = (try color("rgba(0, 0, 0, 0.5)")).?;
    try t.expectEqual(@as(u8, 128), half.a);
    const rp = (try color("rebeccapurple")).?;
    try t.expectEqual(geom.Color{ .r = 0x66, .g = 0x33, .b = 0x99, .a = 255 }, rp);
    try t.expectEqual(@as(u8, 0), (try color("transparent")).?.a);
    try t.expectEqual(geom.Color{ .r = 0, .g = 255, .b = 0, .a = 255 }, (try color("hsl(120, 100%, 50%)")).?);
    try t.expectEqual(@as(?geom.Color, null), try color("nocolor"));
    try t.expectEqual(@as(?geom.Color, null), try color("#ff"));
    try t.expectEqual(@as(?geom.Color, null), try color("rgb(1, 2)"));
    try t.expectEqual(@as(?geom.Color, null), try color("currentColor"));
}

test "css: parseSides" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = value.parseSides(try noEof(a, "4px")).?;
    for (one) |l| try t.expectEqual(@as(f32, 4), l.value);
    const two = value.parseSides(try noEof(a, "4px 8px")).?;
    try t.expectEqual(@as(f32, 4), two[0].value);
    try t.expectEqual(@as(f32, 8), two[1].value);
    try t.expectEqual(@as(f32, 4), two[2].value);
    try t.expectEqual(@as(f32, 8), two[3].value);
    const three = value.parseSides(try noEof(a, "1px 2px 3px")).?;
    try t.expectEqual(@as(f32, 2), three[3].value);
    try t.expect(value.parseSides(try noEof(a, "1px 2px 3px 4px 5px")) == null);
    try t.expect(value.parseSides(try noEof(a, "red")) == null);
    try t.expect(value.parseLength(.{ .percentage = 50 }).?.unit == .percent);
}

test "css-speed: a sheet of 1000 rules" {
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(t.allocator);
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        try src.print(t.allocator, "Frame.c{d} > Button:hover {{ color: #336699; background-color: rgb(1, 2, 3); padding: 4px 8px; border-radius: 6px }}\n", .{i});
    }
    const t0 = std.Io.Clock.awake.now(t.io);
    var s = try parse.parse(std.heap.smp_allocator, src.items);
    const ns = t0.untilNow(t.io, .awake).toNanoseconds();
    defer s.deinit();
    try t.expectEqual(@as(usize, 1000), s.rules.len);
    std.debug.print("css-speed: {d:.2} ms for 1000 rules ({s})\n", .{ @as(f64, @floatFromInt(ns)) / 1e6, @tagName(@import("builtin").mode) });
}
