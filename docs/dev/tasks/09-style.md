# Task 09: Selectors, the cascade, and `ztk::style`

## Goal

Each widget has a computed style from the stylesheets and from its own options. A script adds a stylesheet with `ztk::style`. The base sheet and the modern theme exist.

## Files

- `src/style.zig`: `Style`, `StyleSet`, the cascade, the `ztk::style` and `ztk::class` commands
- `src/css/select.zig`: matching
- `src/themes/base.css`, `src/themes/modern.css`, `src/themes/modern-linux.css`
- `src/options.zig`: `cget` reads the computed style
- `src/widget.zig`: `Widget.style`, `Widget.classes`

## Interfaces

```zig
// src/style.zig
pub const Origin = enum(u8) { base, theme, platform, option_db, ttk, app, widget };
pub const Transition = struct { duration_ms: u32 = 0, linear: bool = false };
pub const Style = struct {
    color: geom.Color,
    background: geom.Color,
    background2: ?geom.Color = null,     // the end of a gradient
    gradient_angle_deg: f32 = 180,
    border_width: [4]f32,                // top, right, bottom, left; logical pixels
    border_color: geom.Color,
    radius: [4]f32,
    padding: geom.Insets,
    font: text.FontDesc,
    opacity: f32 = 1,
    shadow: ?scene.Shadow = null,
    outline_width: f32 = 0,
    outline_color: geom.Color,
    outline_offset: f32 = 0,
    min_width: i32 = 0,
    min_height: i32 = 0,
    transition: Transition = .{},
    caret_color: geom.Color,
    text_align: options.Justify = .left,
    cursor: []const u8 = "default",
    pub fn eql(a: *const Style, b: *const Style) bool;
};
pub const Env = struct {
    dark: bool = false,
    platform: []const u8 = "linux",
    root_font_size: f32 = 13,
};
pub const StyleSet = struct {
    pub fn init(gpa: std.mem.Allocator) StyleSet;
    pub fn deinit(s: *StyleSet) void;
    /// Adds a sheet. Returns an id for `remove`. The diagnostics of the
    /// parser stay with the sheet.
    pub fn add(s: *StyleSet, origin: Origin, name: []const u8, src: []const u8) !u32;
    pub fn remove(s: *StyleSet, id: u32) void;
    pub fn diagnostics(s: *const StyleSet, id: u32) []const css.Diagnostic;
    /// The style of a widget, or of a part of it. `parent` is the style
    /// of the parent widget, or null for a toplevel.
    pub fn compute(s: *StyleSet, w: *const Widget, part: ?[]const u8, parent: ?*const Style, env: Env) Style;
    /// Counts up at each `add` and `remove`.
    generation: u32 = 0,
};
// src/css/select.zig
pub fn matches(sel: *const css.Selector, w: *const Widget, part: ?[]const u8) bool;
```

```zig
// added to Widget
style: Style,                                    // valid when dirty.style is false
classes: std.ArrayListUnmanaged([]const u8) = .empty,  // style classes
```

## Steps

1. Matching. For a selector, match the last compound with the widget, then go up the tree for each compound before it: the parent for `>`, each ancestor for the descendant combinator.
   - The type is `w.tk_class`. The id is `w.name()`. A class is an entry of `w.classes`.
   - The pseudo-classes read `w.state`: `hover`, `active` is `pressed`, `focus`, `focus-visible` is `focus` in Stage 1, `disabled`, `checked` is `selected`, `read-only` is `readonly`, `invalid`, `indeterminate` is `alternate`, `window-inactive` is `background`.
   - `:root` matches a toplevel.
   - `:state(name)` matches the state bit with that `ttk` name. An unknown name matches no widget.
   - A selector with a part matches only when `part` is that name. A selector with no part matches only when `part` is null.
2. The cascade for one widget:
   - Collect each declaration of each rule that matches and whose media condition is true in `env`.
   - Sort by the origin, then the specificity, then the order of the sheets, then the order in the sheet. The last one wins for each property.
   - The origin `widget` is not a sheet. It is the options of the widget that are `set`. Step 6 has the map.
3. Variables. A custom property inherits from the parent widget. Resolve `var(--name)` and `var(--name, fallback)` in a value before the typed parse. A cycle or a missing variable with no fallback makes the declaration invalid, and the property gets its inherited or initial value. Each widget keeps the map of its custom properties for its children. Keep the map in the `StyleSet`, keyed by the widget, and share the map of the parent when a widget declares none.
4. Inheritance. `color`, the font properties, `cursor`, `text-align`, and `caret-color` inherit. All other properties start at their initial value: transparent background, no border, no padding, no radius. The keywords `inherit` and `initial` work for each property.
5. Values:
   - A length in `px` is logical pixels. `pt` is 96/72 pixels. `em` is the font size of the widget. For `font-size`, `em` is the font size of the parent. `rem` is `env.root_font_size`. A percentage is valid only for `border-radius`, where it refers to the smaller side and resolves at paint time. Keep it as a negative number: `-50` means 50 %.
   - `border: 1px solid #ccc` sets the width and the color. Only `solid` and `none` are valid styles.
   - `background: <color>` sets the color. `background: linear-gradient(<angle or "to" side>, <color>, <color>)` sets both colors and the angle.
   - `font-family` is a list. In Stage 1 the first name is used.
   - `font-weight`: `normal` is 400, `bold` is 700, or a number.
   - `box-shadow: <dx> <dy> <blur> <spread>? <color>` or `none`.
   - `outline: <width> solid <color>`.
   - `transition: <property or all> <time> <ease or linear>?`. Stage 1 keeps one duration for all properties. The time has the unit `ms` or `s`.
   - `currentColor` is the computed `color`.
6. The options of the origin `widget`. Only a `set` option gives a declaration:

   | Option | Property |
   |---|---|
   | `-background`, `-bg` | `background-color` |
   | `-foreground`, `-fg` | `color` |
   | `-borderwidth`, `-bd` | `border-width` on four sides |
   | `-padx`, `-pady` | the left and right, or the top and bottom, padding |
   | `-font` | `font-family`, `font-size`, `font-weight` |
   | `-relief flat` | `border-width: 0` |

   The other relief values do not change the style in the modern theme. The classic theme of Stage 2 draws them.
7. `cget` of a `from_style` option that is not `set` gives the computed value: a color as `#rrggbb`, a width as an integer. `Spec` gets a field that names the style property of the option.
8. The style pass. `App.restyle()` goes down the tree. For a widget with the style flag, it computes the style. When the new style differs from the old one, it sets the measure and paint flags of the widget and the style flag of each child. A state change (`hover`) sets the style flag of that widget only. A change of the `StyleSet` generation sets the style flag of all widgets.
9. The commands:
   - `ztk::style add cssText` adds a sheet of the origin `app` and returns an id (`style1`, `style2`).
   - `ztk::style load fileName` reads a file and adds it. It exists only when `App.Options.style_root` names a folder. The file name resolves inside that folder. A name that leaves the folder (`..`, an absolute path) gives an error. With no `style_root`, the command gives the error `ztk::style load is not allowed`.
   - `ztk::style remove id`.
   - `ztk::style diagnostics id` returns a list of `{line message}`.
   - `ztk::style theme` returns `modern`.
   - `ztk::class path` returns the style classes. `ztk::class path add name ...`, `remove name ...`, and `set name ...` change them and set the style flag.
10. The sheets. Read them with `@embedFile`.
    - `base.css`: the initial font and colors on `:root`, and no widget rules.
    - `modern.css`: variables on `:root` (`--bg`, `--fg`, `--muted`, `--accent`, `--accent-fg`, `--border`, `--field-bg`, `--radius`, `--focus-ring`), a `@media (prefers-color-scheme: dark)` block that changes the variables, and the rules for `Frame`, `Label`, `Button` (with `:hover`, `:active`, `:focus`, `:disabled`), and `Entry` (with `:focus`, `:disabled`, `::selection`). Use `font-family: system-ui`, a font size of 13 px, a radius of 6 px, a button padding of `6px 12px`, an entry padding of `5px 8px`, and a transition of 120 ms on `Button`.
    - `modern-linux.css`: the origin `platform`. In Stage 1 it has only a comment that says what belongs there.
    - The implementer selects the colors. The reviewer checks them in the golden images of task 19.
11. `Env.dark` comes from `App.Options.dark` (default false) in Stage 1. The platform query is Stage 2.

## Tests

```sh
zig build test -Dtest-filter=select
zig build test -Dtest-filter=style
```

Use a `Harness`. A test helper reads the computed style of a path.

- `Frame { background-color: #112233 }` and `frame .f`: the background of `.f` is `#112233`.
- `#f` wins over `Frame`. `.card` wins over `Frame`. `Frame.card` wins over `.card`. A later rule of equal specificity wins.
- `Frame > Frame` matches `.a.b` and does not match `.a.b.c` from `.a`. `Frame Frame` matches both.
- `frame .f -bg red` wins over each sheet, including an `#f` rule.
- `.f cget -background` with no option set gives the computed color as `#rrggbb`.
- `:root { --c: #010203 } Frame { background-color: var(--c) }` works. A frame with `--c` set by an `#id` rule changes its children and not its siblings.
- `var(--nosuch, #040506)` gives the fallback. `var(--nosuch)` leaves the initial value.
- `--a: var(--b); --b: var(--a)` gives no hang and the initial value.
- `Label { color: red }` and a frame with `color: blue`: a label inside gets red. With no `Label` rule it inherits blue.
- `font-size: 2em` on a child of a 10 px parent gives 20.
- A sheet in `@media (prefers-color-scheme: dark)` applies only with `Env.dark`.
- `ztk::class .f add card` makes `.card` match. `ztk::class .f` gives `card`.
- `ztk::style add` then `ztk::style remove` puts the style back.
- `ztk::style add "Frame { bogus: 1 }"` gives an id, and `ztk::style diagnostics` gives one item with line 1.
- `ztk::style load x.css` with no `style_root` gives the error. With a `style_root`, `ztk::style load ../x.css` gives an error and reads no file.
- A state test: set `w.state.hover` by hand and invalidate. `Button:hover` then applies. The sibling of the widget does not get a new style computation (count the calls of `compute`).
- The three embedded sheets parse with zero diagnostics.

## Acceptance

- All tests pass.
- A style pass over 1 000 widgets with the modern theme is under 3 ms in `ReleaseFast`. Print the time in a test with the name `style-speed`.
- A hover change on one widget computes one style.
- `src/themes/modern.css` has no color outside the `:root` variable blocks.

## Out of scope

- The option database and `ttk::style`. Their origins exist and stay empty.
- The classic theme. Stage 2.
- The dark mode and the accent color of the platform. Stage 2.
- Transitions in time. Task 18.
