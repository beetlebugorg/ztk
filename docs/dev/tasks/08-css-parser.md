# Task 08: The CSS parser

## Goal

A stylesheet text becomes a list of rules: selectors, declarations, and media conditions. The parser never fails on bad input. It drops the bad part and records a diagnostic, as CSS does.

## Files

- `src/css/token.zig`: the tokenizer
- `src/css/parse.zig`: rules and declarations
- `src/css/value.zig`: typed values of declarations
- `docs/references/css.md`

## Interfaces

```zig
// src/css/token.zig
pub const Token = union(enum) {
    ident: []const u8,
    function: []const u8,        // the name before "("
    at_keyword: []const u8,      // the name after "@"
    hash: []const u8,            // the text after "#"
    string: []const u8,          // the text between quotes, escapes resolved
    number: f32,
    dimension: struct { value: f32, unit: []const u8 },
    percentage: f32,
    delim: u8,                   // one other character, for example '>' or '.'
    colon, semicolon, comma,
    lbrace, rbrace, lparen, rparen, lbracket, rbracket,
    whitespace,
    eof,
};
pub const Tokenizer = struct {
    src: []const u8,
    pos: usize = 0,
    line: u32 = 1,
    pub fn next(t: *Tokenizer) Token;
};

// src/css/parse.zig
pub const Combinator = enum { none, descendant, child };
pub const Pseudo = enum {
    hover, active, focus, focus_visible, disabled, checked, read_only,
    invalid, indeterminate, window_inactive, root,
};
pub const Compound = struct {
    combinator: Combinator = .none,   // how it joins the compound before it
    type_name: ?[]const u8 = null,    // null for "*" or no type
    id: ?[]const u8 = null,
    classes: []const []const u8 = &.{},
    pseudos: []const Pseudo = &.{},
    states: []const []const u8 = &.{}, // the names of :state(name)
};
pub const Selector = struct {
    compounds: []const Compound,       // from left to right
    part: ?[]const u8 = null,          // the name after "::"
    specificity: u32,                  // ids << 16 | classes << 8 | types
};
pub const Prop = enum {
    color, background_color, background, border, border_width, border_color,
    border_radius, padding, padding_top, padding_right, padding_bottom,
    padding_left, font_family, font_size, font_weight, opacity, box_shadow,
    outline, outline_offset, min_width, min_height, transition, caret_color,
    cursor, text_align, custom,
};
pub const Decl = struct {
    prop: Prop,
    name: []const u8,          // the property name; for `custom` it starts with "--"
    value: []const Token,      // the tokens of the value, with no outer whitespace
    line: u32,
};
pub const Media = struct {
    dark: ?bool = null,              // prefers-color-scheme: dark is true, light is false
    platform: ?[]const u8 = null,    // -ztk-platform
};
pub const Rule = struct {
    selectors: []const Selector,
    decls: []const Decl,
    media: Media = .{},
    order: u32,                      // the position in the sheet
};
pub const Diagnostic = struct { line: u32, message: []const u8 };
pub const Sheet = struct {
    rules: []const Rule,
    diagnostics: []const Diagnostic,
    arena: std.heap.ArenaAllocator,  // owns all slices, including a copy of the source
    pub fn deinit(s: *Sheet) void;
};
pub fn parse(gpa: std.mem.Allocator, src: []const u8) std.mem.Allocator.Error!Sheet;

// src/css/value.zig
pub const Length = struct { value: f32, unit: enum { px, pt, em, rem, percent } };
pub fn parseColor(tokens: []const Token) ?geom.Color;
pub fn parseLength(tok: Token) ?Length;
/// 1 to 4 lengths in the order top, right, bottom, left, with the CSS
/// rules for missing values.
pub fn parseSides(tokens: []const Token) ?[4]Length;
```

## Steps

1. The tokenizer follows the token rules of CSS Syntax Level 3 for the tokens above: comments (`/* */`), identifiers with `-` and `_` and escapes, numbers with a sign and a fraction, strings with both quote kinds. It does not need `url()`, unicode ranges, or `<!--`.
2. A sheet is a list of style rules and `@media` blocks. A `@media` block has style rules. All other at-rules are dropped with a diagnostic.
3. A style rule is a selector list, `{`, declarations, `}`. When one selector of the list is not valid, drop the complete rule, as CSS does.
4. A declaration is a name, `:`, tokens, and `;` or the end of the block. A name that is not in `Prop` and does not start with `--` is dropped with a diagnostic that has the line and the name. `!important` is dropped with a diagnostic in Stage 1.
5. Selector grammar:
   - A compound: an optional type or `*`, then `#id`, `.class`, `:pseudo`, and `:state(name)` in any order.
   - Whitespace between compounds is the descendant combinator. `>` is the child combinator.
   - `::name` can come at the end of the last compound.
   - A type name keeps its letter case: `Button` and `button` are different.
   - A pseudo-class that is not in `Pseudo` makes the selector invalid.
6. The specificity counts ids, then classes and pseudo-classes and states, then types. `::part` counts as a type.
7. `@media` conditions: `(prefers-color-scheme: dark)`, `(prefers-color-scheme: light)`, `(-ztk-platform: name)`, and two conditions joined with `and`. Another condition drops the block with a diagnostic.
8. `parseColor` accepts: `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`, `rgb(r, g, b)`, `rgb(r g b / a)`, `rgba(r, g, b, a)`, `hsl(h, s%, l%)` with an optional alpha, `transparent`, and the named colors of CSS Color Level 4. The table of the 148 names and their values is data from that specification. Credit it in `docs/references/css.md`. `currentColor` and `var()` are not colors here. Task 09 resolves them before it calls `parseColor`.
9. Write `docs/references/css.md` with the specifications that this task follows.

## Tests

```sh
zig build test -Dtest-filter=css
```

- Tokens of `a{b:1px}`: ident, lbrace, ident, colon, dimension 1 px, rbrace, eof.
- Tokens of `/* x */ #fff "a\"b" 50% -1.5em`: whitespace, hash, whitespace, string `a"b`, whitespace, percentage 50, whitespace, dimension -1.5 em.
- `Button { color: red; }` gives one rule, one selector with the type `Button`, and one declaration.
- `Button.primary:hover > Label#title::selection` gives two compounds, the child combinator, and the part `selection`. The specificity has 1 id, 2 class-level items, and 3 type-level items.
- `Button, Label { }` gives one rule with two selectors.
- `Button { color: red; bogus: 1; background-color: blue }` gives two declarations and one diagnostic on line 1.
- `Button:nosuch { color: red } Label { color: blue }` gives one rule (for `Label`) and one diagnostic.
- `@media (prefers-color-scheme: dark) { Label { color: white } }` gives one rule with `media.dark == true`.
- `@media (-ztk-platform: linux) and (prefers-color-scheme: light) { ... }` gives both conditions.
- `@import "x.css"; Label { color: red }` gives one rule and one diagnostic.
- `:root { --accent: #3366ff; }` gives a `custom` declaration with the name `--accent`.
- An input that ends in the middle of a rule (`Button { color: re`) gives no crash and no leak.
- 1 000 inputs of random bytes, from a fixed seed, give no crash and no leak.
- `parseColor`: `#f00`, `#ff0000`, `#ff0000ff`, `rgb(255, 0, 0)`, `rgb(255 0 0 / 1)`, `hsl(0, 100%, 50%)`, and `red` are equal. `rgba(0, 0, 0, 0.5)` has the alpha 128. `rebeccapurple` is `#663399`.
- `parseSides`: `4px` gives four equal values. `4px 8px` gives top and bottom 4, right and left 8. Five values give null.

## Acceptance

- All tests pass with `std.testing.allocator`.
- The parser has no `unreachable` and no `catch unreachable` on a path that the input controls.
- A sheet of 1 000 rules parses in under 5 ms in `ReleaseFast`. Print the time in a test with the name `css-speed`.

## Out of scope

- Matching and the cascade. Task 09.
- `!important`, `:not()`, attribute selectors, sibling combinators, `calc()`, and nested rules.
- `@import`, `@font-face`, `@keyframes`, and `@layer`.
