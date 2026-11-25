# Task 11: The frame pipeline, `.`, `frame`, `label`, and `wm`

## Goal

A script with frames and labels in a grid gives a picture. One function runs the stages of a frame: style, measure, layout, paint, and draw. The first golden images of real widgets exist.

## Files

- `src/app.zig`: `frame`, the dirty logic
- `src/paint.zig`: the box of a widget from its style
- `src/widgets/toplevel.zig`, `src/widgets/frame.zig`, `src/widgets/label.zig`
- `src/cmds.zig`: `wm`, the geometry subcommands of `winfo`, `tk scaling`
- `src/widget.zig`: `Class.measure`, `Class.paint`

## Interfaces

```zig
// added to Class
/// The requested size from the content, the style, and the options.
measure: ?*const fn (w: *Widget) geom.Size = null,
/// Adds the quads of the widget. The origin of the builder is the
/// top-left corner of the widget.
paint: ?*const fn (w: *Widget, b: *scene.Builder) anyerror!void = null,

// src/paint.zig
/// Adds the shadow, the background, the border, and the focus outline
/// of a widget from its style.
pub fn box(w: *const Widget, b: *scene.Builder, style: *const Style) !void;
/// The space inside the border and the padding.
pub fn contentRect(w: *const Widget, style: *const Style) geom.Rect;
/// The border and the padding as insets, rounded up to whole pixels.
pub fn insets(style: *const Style) geom.Insets;
/// Draws lines of text in a rectangle with an anchor and a justify.
pub fn label(w: *const Widget, b: *scene.Builder, r: geom.Rect, text: []const u8, style: *const Style, anchor: options.Anchor, justify: options.Justify) !void;
/// The size of lines of text in a font.
pub fn textSize(app: *App, text: []const u8, font: text.FontDesc, scale: f32) geom.Size;

// src/app.zig
/// Runs the stages that the dirty flags ask for, for one toplevel.
/// Returns true when it drew.
pub fn frame(app: *App, top: *Widget) !bool;
```

## Steps

1. `App.frame` for a toplevel:
   1. Style: `restyle` (task 09).
   2. Measure and layout: `layout.run` (task 10). A class with `measure` gives the requested size of a widget that has no managed content.
   3. Window size: when the requested size of the toplevel changed and the script set no size with `wm geometry`, call `Platform.requestSize`. The size is at least 1 by 1 and at least `wm minsize`.
   4. Paint: when a widget of the toplevel has the paint flag, build the scene of the complete toplevel. Go down the tree in stacking order. For each mapped widget: push the offset of its position, push the clip of its box, call `paint`, paint the children, and pop.
   5. Draw: `Platform.draw`. Clear all flags.
2. `App.doOneEvent` calls `frame` for a toplevel on a `frame` event. A change that sets a dirty flag calls `Platform.requestFrame` one time until the frame runs. `update` and `update idletasks` call `frame` directly for each dirty toplevel, as Tk draws in idle time.
3. The clear color of the scene is the computed background of the toplevel.
4. `frame` class: `measure` gives `-width` and `-height`. A frame with managed content gets its size from the manager. `paint` calls `paint.box`.
5. The toplevel class has the options of `frame` that Stage 1 has. The class name of `.` is `App.Options.root_class`, so a stylesheet selects `.` with `:root`.
6. `label` class. The type name is `Label`. Options in Stage 1: `-text`, `-textvariable`, `-font`, `-foreground` and `-fg`, `-background` and `-bg`, `-anchor` (default `center`), `-justify` (default `center`), `-padx`, `-pady`, `-width` (in characters), `-height` (in lines), `-borderwidth` and `-bd`, `-relief`, `-state` (`normal`, `active`, `disabled`), `-takefocus`, `-cursor`. Each other option of the Tk label gives `unknown option` in Stage 1. List them in `docs/dev/stage1-limits.md`.
7. `label` measure: the text size is the width of the longest line and the line height times the count of lines. Lines split at a newline. With `-width` above 0, the text width is that count times the width of the character `0`. With `-height` above 0, the text height is that count of lines. Add the insets of the style. Use at least `min-width` and `min-height`.
8. `label` paint: the box, then the text in the content rectangle with `-anchor`. The text color is the computed `color`.
9. `-textvariable`: the label shows the value of a global variable. On creation and on `configure`, when the variable does not exist, create it with the value of `-text`. Add a script trace: `trace add variable <name> write {::ztk::priv::textvar <path>}`. The native command reads the variable, sets the measure and paint flags, and asks for a frame. Remove the trace when the option changes and when the widget is deleted. A variable that is unset keeps the last text.
10. `-state disabled` sets the `disabled` state bit.
11. `wm`, for `.` only in Stage 1:
    - `wm title . ?text?`
    - `wm geometry . ?WxH?` and `?WxH+X+Y?`. The position is parsed and ignored. With no argument it gives `WxH+0+0`. A bad value gives `bad geometry specifier "bogus"`. An empty string removes the size that the script set.
    - `wm minsize . ?w h?`, `wm maxsize . ?w h?`, `wm resizable . ?w h?` (stored).
    - `wm protocol . WM_DELETE_WINDOW ?script?`. A `close` event runs the script. With no script, it deletes `.`.
    - `wm withdraw .`, `wm deiconify .`, and `wm state .` (`normal` or `withdrawn`). A withdrawn toplevel draws no frame.
    - Each other subcommand gives the error `wm <name> is not supported in this stage`. A name that Tk does not have gives the `bad option` message of `wish`, with the complete list.
12. `winfo`: `width`, `height`, `x`, `y`, `reqwidth`, `reqheight`, `rootx`, `rooty` (the position in the toplevel; the toplevel is at 0, 0), `ismapped`, `viewable`, `geometry` (`WxH+X+Y`). Before the first layout, a widget has the width 1 and the height 1, as in Tk.
13. `tk scaling ?number?` gives and sets the logical pixels for each point. `tk windowingsystem` gives `ztk`. Record this in `docs/dev/stage1-limits.md`: scripts that test for `x11`, `win32`, or `aqua` get none of them.

## Tests

```sh
zig build test -Dtest-filter=frame
zig build test -Dtest-filter=label
zig build test -Dtest-filter=wm
```

Script tests with a `Harness`:

- `label .l -text Hello; grid .l; update`: `winfo reqwidth .l` is the text width plus the insets of the style, and `winfo width .` is equal to `winfo reqwidth .`.
- `winfo width .l` before `update` is `1`.
- `.l configure -text "A much longer text"; update` makes `.` wider.
- `set v one; label .m -textvariable v; grid .m; update; set v "two words"; update`: the scene dump has the glyphs of the new text, and the width changed.
- `label .n -textvariable nv -text start; set nv` gives `start`.
- `destroy .m; set v three` gives no error.
- A label with `-text "a\nb"` has two times the line height.
- `label .w -width 10` has the width of ten `0` characters plus the insets.
- `wm title . Demo; wm title .` gives `Demo`.
- `wm geometry . 300x200; update; winfo width .` gives `300`. `wm geometry .` gives `300x200+0+0`.
- `wm protocol . WM_DELETE_WINDOW {set closed 1}` and a `close` event: `closed` is `1` and `.` exists. With no protocol script, `.` does not exist after it.
- `wm withdraw .; update` draws no frame (`h.head.frames_drawn` does not change).
- Two `update` calls with no change between them draw one frame in total.
- A `resize` event to 400 by 300 with `grid columnconfigure . 0 -weight 1` and a `-sticky ew` label changes the width of the label.
- `winfo rootx` of a label in a frame at (10, 20) is the sum of the positions.

Golden images and scene dumps, with the modern theme, 240 by 120:

- `label-plain`: one label.
- `label-anchor`: three labels with `-anchor w`, `center`, and `e` in a wide column with `-sticky ew`.
- `label-colors`: `-fg` and `-bg` set, and a style class with a border and a radius.
- `label-grid`: a 2 by 2 grid of labels with `-padx` and `-pady`.
- `label-disabled`: a normal and a disabled label.
- `label-scale2`: `label-plain` at scale 2. The image is two times as large and the text is sharp.

## Acceptance

- All tests pass.
- The reviewer opens the six images. The text is in the correct place for each anchor, and no quad is outside its widget.
- `App.frame` with no dirty flag does no work and returns false.
- After a change of one label text with the same size, the layout of the other widgets does not run (count the `arrange` calls in a test).

## Out of scope

- `-image`, `-bitmap`, `-compound`, `-underline`, and `-wraplength`.
- The `toplevel` command and a second window.
- The window position and the other `wm` subcommands.
- Paint of only the changed region. Stage 1 paints the complete toplevel.
