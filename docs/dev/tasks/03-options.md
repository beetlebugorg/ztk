# Task 03: Options: `configure` and `cget`

## Goal

One piece of code gives each widget class the option behavior of Tk: creation options, `configure`, and `cget`, with the result forms and the error messages of `wish`.

## Files

- `src/options.zig`
- `src/widget.zig`: `Class.specs`, `Widget.opts`, `Class.configured`
- `src/widgets/frame.zig`: the options of `frame`

## Interfaces

```zig
// src/options.zig
pub const Type = enum {
    string,   // any text
    int,      // an integer
    pixels,   // a screen distance: 10, 2.5c, 1i, 3m, 12p
    color,    // a Tk color, or "" where the option permits it
    boolean,  // 0 1 true false yes no on off
    anchor,   // n ne e se s sw w nw center
    relief,   // flat groove raised ridge solid sunken
    state,    // normal active disabled (the class gives the set)
    justify,  // left center right
    font,     // a font description; kept as text until task 07
    variable, // the name of a global variable
    script,   // a script
    synonym,  // another name for an option: -bg, -bd, -fg
};
pub const Spec = struct {
    name: []const u8,              // "-background"
    db_name: []const u8 = "",      // "background"
    db_class: []const u8 = "",     // "Background"
    type: Type,
    default: []const u8 = "",      // the text form of the default
    /// True: when the script did not set the option, its value comes
    /// from the computed style (task 09).
    from_style: bool = false,
    /// The target of a synonym, for example "-background".
    target: []const u8 = "",
    /// The words that `state` accepts, for a `state` option.
    words: []const []const u8 = &.{},
    /// An empty string is a valid value.
    allow_empty: bool = false,
};
pub const Parsed = union(enum) {
    none, text: []const u8, int: i64, pixels: i32, color: geom.Color,
    boolean: bool, anchor: Anchor, relief: Relief, word: u8, justify: Justify,
};
pub const Slot = struct {
    set: bool = false,        // the script set it
    text: []const u8 = "",    // owned by the widget; the text the script gave
    value: Parsed = .none,
};
pub const Anchor = enum { n, ne, e, se, s, sw, w, nw, center };
pub const Relief = enum { flat, groove, raised, ridge, solid, sunken };
pub const Justify = enum { left, center, right };

/// The index of an option of a class, with the abbreviation rule of Tk.
pub fn find(it: *ztcl.Interp, specs: []const Spec, name: []const u8) ztcl.Error!usize;
/// `path configure ?option? ?value option value ...?`
pub fn configure(w: *Widget, it: *ztcl.Interp, args: []const ztcl.Value) ztcl.Error!ztcl.Value;
/// `path cget option`
pub fn cget(w: *Widget, it: *ztcl.Interp, name: ztcl.Value) ztcl.Error!ztcl.Value;
/// Sets pairs of option and value. It changes no option when one pair
/// has an error.
pub fn apply(w: *Widget, it: *ztcl.Interp, pairs: []const ztcl.Value) ztcl.Error!void;
/// Typed readers for the class code.
pub fn get(w: *const Widget, comptime name: []const u8) *const Slot;
pub fn parsePixels(text: []const u8, scaling: f64) ?i32;
```

```zig
// added to Class in src/widget.zig
specs: []const options.Spec = &.{},
/// Runs after `apply` changed options. `changed` has the spec indexes.
configured: ?*const fn (w: *Widget, changed: []const usize) ztcl.Error!void = null,
// added to Widget
opts: []options.Slot = &.{},   // one slot for each spec
```

## Steps

1. `widget.create` allocates one `Slot` for each spec and sets the value of each default. A default is not `set`.
2. The widget constructor passes its arguments after the path to `apply`. When `apply` fails, the constructor deletes the widget and returns the error.
3. Each widget command gets `configure` and `cget` from `options.zig` before it calls `Class.subcommand`.
4. `configure` with no argument returns a list with one item for each spec, in the order of the specs. An item is `{name dbName dbClass default value}`. A synonym is `{name target}`.
5. `configure` with one argument returns the item of that option. For a synonym, it returns the item of the target.
6. `configure` with pairs calls `apply`, then `Class.configured`, and returns an empty string. An odd count gives `value for "-x" missing`.
7. An option name can be a unique prefix (`-backg`). An unknown name and an ambiguous prefix give the same message in `wish`: `unknown option "-b"`.
8. The value of `cget` and the fifth part of an item:
   - For a `set` slot: the text that the script gave.
   - For a slot that is not `set` and not `from_style`: the default text.
   - For a slot that is not `set` and is `from_style`: in this task, the default text. Task 09 changes it to the computed style.
9. `parsePixels`: a number, with an optional `c`, `i`, `m`, or `p`. A plain number is logical pixels. `scaling` is logical pixels for each point, 96/72 by default. One inch is 72 points. Round to the nearest integer. A fraction with no unit rounds too: `wish` gives 3 for `2.5`.
10. Get each type error message from `wish`. The list is in the tests below.
11. `apply` parses all pairs first. It writes the slots only when all pairs are valid. `wish` does the same: after `.a configure -width 10 -bg nocolor` fails, `-width` has its old value.
12. The options of `frame` for Stage 1: `-background` and `-bg`, `-borderwidth` and `-bd`, `-relief`, `-width`, `-height`, `-padx`, `-pady`, `-class`, `-takefocus`, `-cursor`. `-class` can be set only at creation: `configure -class` after creation gives `can't modify -class option after widget is created`. `-background`, `-borderwidth`, and `-relief` are `from_style`.
13. After a change, `apply` calls `w.invalidate` with the style and measure flags.

## Tests

```sh
zig build test -Dtest-filter=options
```

- `frame .f -width 100 -height 50; .f cget -width` gives `100`.
- `.f configure -bg red; .f cget -background` gives `red`.
- `.f configure -bg` gives the item of `-background` with five parts.
- `lindex [.f configure] 0` has five parts, and the item of `-bd` has two parts.
- `.f cget -backg` works. `.f cget -b` gives `unknown option "-b"`.
- `.f configure -nosuch 1` gives `unknown option "-nosuch"`.
- `.f configure -width` with a value `x` gives `bad screen distance "x"`.
- `.f configure -bg nocolor` gives `unknown color name "nocolor"`.
- `.f configure -relief x` gives the message with the six relief names.
- `.f configure -width 10 -bg nocolor` fails, and `.f cget -width` still gives the old value.
- `.f configure -width` (one pair with no value) and `.f configure -width 1 -height` give the messages of `wish`.
- `frame .g -nosuch 1` fails, and `winfo exists .g` gives `0`.
- `frame .h -class Fancy; winfo class .h` gives `Fancy`.
- `parsePixels("1i", 96.0/72.0)` is 96. `parsePixels("72p", 96.0/72.0)` is 96. `parsePixels("2.54c", 96.0/72.0)` is 96.
- A test compares `.f configure` with a text that `wish` printed for the same options, for the names and the classes of the database (parts 1 to 3 of each item).

## Acceptance

- All tests pass.
- A new option type or a new class needs only a table. It needs no change in `configure` or `cget`.
- Each message in the tests is the text of `wish` 8.6.16.

## Out of scope

- The option database (`option add`). Stage 2.
- Fonts as parsed values. Task 07.
- The computed style for `cget`. Task 09.
- The options of other classes.
