# Task 01: Project skeleton

## Goal

`zig build` makes a `ztk` program that runs a Tcl script with ztcl. `zig build test` runs the unit tests. No widget exists yet.

## Files

- `build.zig`, `build.zig.zon`
- `src/ztk.zig`: the root of the module
- `src/base/geom.zig`: points, sizes, rectangles, insets, colors
- `src/main.zig`: the `ztk` program

## Interfaces

```zig
// src/base/geom.zig. The unit is the logical pixel.
pub const Point = struct { x: i32 = 0, y: i32 = 0 };
pub const Size = struct { w: i32 = 0, h: i32 = 0 };
pub const Insets = struct {
    top: i32 = 0, right: i32 = 0, bottom: i32 = 0, left: i32 = 0,
    pub fn all(n: i32) Insets;
    pub fn horizontal(i: Insets) i32; // left + right
    pub fn vertical(i: Insets) i32;   // top + bottom
};
pub const Rect = struct {
    x: i32 = 0, y: i32 = 0, w: i32 = 0, h: i32 = 0,
    pub fn isEmpty(r: Rect) bool;            // w <= 0 or h <= 0
    pub fn contains(r: Rect, p: Point) bool; // right and bottom edges are outside
    pub fn intersect(a: Rect, b: Rect) Rect; // an empty result has w = 0 and h = 0
    pub fn inset(r: Rect, i: Insets) Rect;   // w and h do not go below 0
    pub fn translate(r: Rect, dx: i32, dy: i32) Rect;
};
/// sRGB with straight alpha.
pub const Color = struct {
    r: u8, g: u8, b: u8, a: u8 = 255,
    /// The color forms of Tk: #rgb, #rrggbb, #rrrrggggbbbb, and a name.
    pub fn parseTk(text: []const u8) ?Color;
    /// "#rrggbb", lower case.
    pub fn formatTk(c: Color, buf: *[7]u8) []const u8;
};
```

```zig
// src/ztk.zig
pub const geom = @import("geom.zig");
pub const version = "0.0.0";
```

## Steps

1. Make `build.zig.zon` with the name `.ztk`, the version `0.0.0`, and `minimum_zig_version = "0.16.0"`. Run `zig build` one time to get the fingerprint that Zig proposes, and add it.
2. Add ztcl as a pinned package:
   ```sh
   zig fetch --save=ztcl git+https://github.com/beetlebugorg/ztcl#125392f12e1cae7885fab031abbc70a5291ba2fe
   ```
3. Write `build.zig`. Use the `build.zig` of the pinned ztcl as the example of the Zig 0.16 build API.
   - A module `ztk` with `src/ztk.zig` as the root and the import `ztcl`.
   - An executable `ztk` from `src/main.zig`.
   - A step `test` that runs the tests of the `ztk` module.
   - An option `-Dtest-filter=<text>` that goes in `TestOptions.filters`.
   - A step `run` that passes its arguments to the program.
   - The program and the tests link no library and no libc in this task. From the first task that links libc (task 16), set `use_llvm = true` and `use_lld = true` on each executable and test that links it. The reason is in [the task index](README.md).
4. Write `src/base/geom.zig` with the tests below.
5. `parseTk` accepts the three `#` forms. For a 12-digit form, the high byte of each part is the value. It also accepts these names, in any letter case: `black`, `white`, `red`, `green`, `blue`, `yellow`, `cyan`, `magenta`, `gray`, `grey`, `orange`, `purple`, `brown`, `pink`. Get the value of each name from `wish`: `winfo rgb . <name>` gives three 16-bit numbers. The complete table of 760 names is Stage 2.
6. Write `src/main.zig`. `ztk file.tcl` reads the file, makes a `ztcl.Interp`, sets `output` so that `puts` writes to stdout, and evaluates the text. On `error.TclError` it writes `it.result` to stderr and exits with status 1. With no argument it prints a usage line and exits with status 2. Use `src/main.zig` of the pinned ztcl as the example of the file and argument API of Zig 0.16.

## Tests

```sh
zig build
zig build test
zig build test -Dtest-filter=geom
printf 'puts [expr {6 * 7}]\n' > /tmp/ztk-t01.tcl && zig-out/bin/ztk /tmp/ztk-t01.tcl
```

Unit tests in `src/base/geom.zig`:

- `Rect.contains`: a point on the left edge is inside, and a point on the right edge is outside.
- `Rect.intersect` of two rectangles that do not touch is empty.
- `Rect.inset` with insets larger than the rectangle gives `w = 0` and `h = 0`.
- `Color.parseTk("#fff")`, `("#ffffff")`, and `("#ffffffffffff")` are equal.
- `Color.parseTk("Red")` is `255, 0, 0`. `Color.parseTk("nocolor")` is null.
- `formatTk` of `parseTk("#D9d9D9")` is `#d9d9d9`.

## Acceptance

- The four commands above pass. The last one prints `42`.
- `git status` shows no build output. `.gitignore` covers `zig-out/` and `.zig-cache/`.
- `build.zig.zon` has one dependency: ztcl, with a URL and a hash, and no local path.
- `file zig-out/bin/ztk` prints `statically linked`.

## Out of scope

- Widgets, windows, and all C libraries.
- An interactive prompt in the `ztk` program.
- Flags of the `ztk` program. Task 17 adds them.
