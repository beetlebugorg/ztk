# Task 19: The demo, the scene checks, and the end-to-end tests

## Goal

`examples/demo.tcl` is the Stage 1 demo. The same file runs in ztk and in `wish` 8.6. Tests operate the demo from the first frame to the close of the window. Automatic checks of the scene find text that is cut and colors with low contrast.

## Files

- `examples/demo.tcl`, `examples/demo.css`
- `src/checks.zig`: the scene checks
- `src/testing.zig`: `Harness.loadFile`
- `tests/golden/demo-*.png`, `tests/golden/demo-*.scene.txt`
- `tests/demo.sh`

## Interfaces

```zig
// src/checks.zig
pub const Problem = struct {
    path: []const u8,     // the widget
    kind: enum { text_clipped, low_contrast, outside_window, zero_size },
    detail: []const u8,   // for example "contrast 3.1, need 4.5"
};
pub const Options = struct {
    /// The lowest contrast ratio of a text color on its background.
    min_contrast: f32 = 4.5,
    /// Classes whose text can be clipped on purpose (a scrolled entry).
    clip_ok: []const []const u8 = &.{"Entry"},
};
/// Checks the widgets of a toplevel after a frame. The caller owns the list.
pub fn run(gpa: std.mem.Allocator, top: *Widget, opts: Options) ![]Problem;
/// The contrast ratio of two opaque sRGB colors, from 1 to 21, by the
/// WCAG 2 formula of relative luminance.
pub fn contrast(a: geom.Color, b: geom.Color) f32;
```

## Steps

1. `examples/demo.tcl` is this file. It was run in `wish` 8.6.16 as it is:

   ```tcl
   # The Stage 1 demo. It runs in ztk and in wish 8.6.
   if {[llength [info commands ::ztk::style]]} {
       ::ztk::style load demo.css
   }
   wm title . "ztk demo"
   set name ""
   set count 0
   set msg "Type a name, then press Enter."

   label .title -text "Hello from ztk"
   label .lname -text "Name:"
   entry .name -textvariable name -width 24
   button .greet -text "Greet" -command {set msg "Hello, $name!"}
   button .count -text "Count" -command {incr count; set msg "Clicks: $count"}
   button .quit -text "Quit" -command {destroy .}
   label .msg -textvariable msg

   grid .title -     -      -sticky w  -padx 12 -pady {12 6}
   grid .lname .name -      -sticky ew -padx 12 -pady 4
   grid .greet .count .quit -sticky ew -padx 12 -pady 4
   grid .msg   -     -      -sticky w  -padx 12 -pady {6 12}
   grid columnconfigure . 1 -weight 1

   bind .name <Return> {.greet invoke}
   bind . <Escape> {destroy .}
   bind .title <Enter> {set msg "The pointer is on the title."}
   bind .title <Leave> {set msg "The pointer left the title."}
   focus .name
   ```

   In `wish` the grid has 3 columns and 4 rows (`grid size .` gives `3 4`).
2. `examples/demo.css` styles the demo on top of the modern theme: a larger bold font for `#title`, the `primary` look for `#greet` (a rule with the id, because the script adds no style class), a muted color for `#msg`, and a `@media (prefers-color-scheme: dark)` block if the theme needs one. It has at most 40 lines.
3. `ztk::style load demo.css` resolves in the folder of the script (task 17 sets `style_root`).
4. The scene checks, for each mapped widget of a toplevel:
   - `text_clipped`: a glyph quad of the widget whose rectangle is not completely inside its clip. A class in `clip_ok` is exempt.
   - `low_contrast`: the contrast of the computed `color` and the background behind the text is under `min_contrast`. The background is the nearest opaque `background` up the tree. A gradient uses the color with the lower contrast. A disabled widget needs 3.0.
   - `outside_window`: a mapped widget whose box is partly outside its toplevel.
   - `zero_size`: a mapped widget with text and a width or a height of 0.
5. `tests/demo.sh` runs the demo in both programs and compares what does not depend on the theme: the list of widgets, `grid size .`, `grid info` of each widget, and the values of `msg`, `name`, and `count` after the same `event generate` and `invoke` calls. It uses a wrapper script that sources the demo and prints these values. It exits with status 77 when `wish` or `xvfb-run` is not on the path.

## Tests

```sh
zig build test -Dtest-filter=demo
zig build test -Dtest-filter=checks
tests/demo.sh
zig-out/bin/ztk --headless --exit-after-frames 1 --screenshot /tmp/ztk-demo.png examples/demo.tcl
tools/oracle.sh tools/oracle-grid.tcl 1 200
```

End-to-end tests with a `Harness` that loads `examples/demo.tcl` and `examples/demo.css`. All input goes through the headless backend.

- After the first `update`: the seven widgets exist, `.name` has the focus, and `winfo width .` is at least the requested width.
- `typeText("Ada")` and `press("Return")`: `msg` is `Hello, Ada!`, and the label `.msg` shows it (the scene dump has its glyphs).
- A click on `.count` two times: `msg` is `Clicks: 2`.
- The pointer on `.title` and then off it: `msg` has the two texts in order.
- `Tab` from `.name` goes to `.greet`, then `.count`, then `.quit`, then `.name`. `space` on `.count` adds a click.
- A `resize` to 600 by 300: `.name` is wider, and the buttons keep their requested widths, as column 1 has the weight.
- `press("Escape")` deletes `.`, and `App.run` returns.
- A click on `.quit` does the same in a second test.
- The `close` event does the same in a third test.
- No test of this list leaks memory.

Scene checks:

- `checks.run` on the demo gives no problem, in the light scheme and in the dark scheme.
- The same with the root font size times 1.5 (`:root { font-size: 19.5px }` in an added sheet): no problem. The window is larger, and no text is cut.
- The same at scale 2 and at scale 1.25.
- `checks.run` finds a problem in a bad sheet: `Label { color: #cccccc }` on a white background gives `low_contrast`.
- A label in a frame of fixed size 20 by 10 with `grid propagate` off gives `text_clipped`.
- `contrast` of black and white is 21. Of two equal colors it is 1.

Golden images and scene dumps of the demo, with animations off:

- `demo-start`: the first frame, light.
- `demo-dark`: the first frame, dark.
- `demo-typed`: after "Ada" and Return.
- `demo-hover`: the pointer on `.count`.
- `demo-wide`: after the resize to 600 by 300.
- `demo-scale2`: the first frame at scale 2.

GPU: the Vulkan test of task 16 also draws the scene of `demo-start` and compares it with the CPU image.

## Acceptance

- All commands above pass. `tests/demo.sh` prints no difference.
- The reviewer opens the six images. The window has the seven widgets in the rows and columns that `grid info` gives, with the modern look. The dark image has the same layout.
- The reviewer reads `examples/demo.css` and the theme. Each color has a contrast that the check accepts.
- The manual check of task 17 is repeated one time with the demo on the live Wayland session: `ZTK_FRAME_STATS=1 zig-out/bin/ztk --exit-after-frames 300 examples/demo.tcl`. Record the frame count, the late count, and the time to the first frame.

## Out of scope

- A person who types in the real window. That is the manual checklist of the stage report.
- The look of the demo in `wish`. Only its structure and its results are compared.
- More widgets in the demo.
