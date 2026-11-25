# Performance review

This page lists the places where ztk can get faster, with a measure for each one. It is a review. It changes no code.

## Method

- Date: 2026-11-25. Commit: `27384ec`. Machine: Intel Core i7-6700K, x86-64 Linux. Zig 0.16.0.
- Bench numbers are from one run of `zig build bench -Doptimize=ReleaseFast`. Other jobs shared the machine, so the times are higher than on a quiet machine. The bench cases set `skip_draw`, so a frame time there has style, layout, and the build of the scene, and has no draw.
- Stage times are from `ZTK_FRAME_STATS=1 zig-out/bin/ztk --headless --exit-after-frames 1 k.tcl` with a `ReleaseFast` build.
- Instruction counts are from `valgrind --tool=callgrind zig-out/bin/ztk --headless --exit-after-frames 1 k.tcl` and `callgrind_annotate`, with the loop count of `k.tcl` set to 20. That run has 22 frames.
- `k.tcl` makes 1,000 buttons and then changes one of them for each frame:

```tcl
for {set i 0} {$i < 1000} {incr i} { button .w$i -text "button $i"; grid .w$i -row [expr {$i/25}] -column [expr {$i%25}] }
update
for {set i 0} {$i < 300} {incr i} { .w0 configure -bg [expr {$i%2 ? "red" : "blue"}]; update }
```

## Summary

The rank is the expected gain divided by the effort.

| Rank | Finding | Measure | Effort |
|---|---|---|---|
| 1 | The pinned ztcl checks each command after each new widget | 197.9 M of 488.4 M script instructions | Small |
| 2 | Each frame builds the scene of all widgets | 926 us for a hover of 1 of 1,000 widgets | Large |
| 3 | Each paint shapes the text of each widget again | 23% or more of the scene build | Medium |
| 4 | `ztk::animate` moves each value through text | 3.8 us for each animation in each frame | Small to medium |
| 5 | The CPU renderer draws each pixel of each frame | 10,711 us for a frame of the demo | Medium |
| 6 | A wheel step on an entry costs five hover frames | 4,830 us | Not known |
| 7 | The animation of a widget is found by a linear search | Not measured | Small |
| 8 | Two scroll cases have a slow 99th percentile | 5,452 us and 4,434 us | Not known |

## 1. The pinned ztcl checks each command after each new widget

- Measure: in the profile of `k.tcl`, `vm.recheck` of ztcl has 197.9 M instructions with its callees, in about 1,000 calls. The largest ztcl function of the run has 488.4 M with its callees. So this check is 40% of the script side of the run. The bench case `build-1000` has a median of 26,016 us.
- Cause: `build.zig.zon` pins ztcl at commit `125392f` of 2026-11-23. In that commit, `recheck` in `src/vm.zig` reads each key of the command table. `makeNode` registers one command for each widget (`src/widget.zig:417`), and `register` adds 1 to the epoch, so the next guarded instruction runs `recheck`. The cost for n widgets grows with n squared.
- ztcl `main` at `1ea81b6` has a `recheck` that does one lookup for each inlined name. Its cost does not grow with the count of commands.
- Change: move the pin to a ztcl commit that has the new `recheck`. `main` of ztcl is 200 commits ahead of the pin.
- Expected gain: up to 40% of the script time of `build-1000`. The gain is larger for more widgets. I did not build ztk with the new pin.

## 2. Each frame builds the scene of all widgets

- Measure: `frame-hover-1000` has a median of 926 us and `frame-full-1000` has 1,595 us. One widget of 1,000 changes in the hover case. `type-entry`, one key in an entry in a window with one widget, has a median of 25 us.
- Stage times for `k.tcl`, 302 frames, median: style 36 us, layout 63 us, paint 1,438 us, render 2 us. The paint stage is 93% of the sum.
- Profile: `App.paintNode` has 254.9 M of the 272.2 M instructions of `App.frame`.
- Cause: when a widget is dirty for paint, `frame` resets the scene (`src/app.zig:801`) and calls `paintNode` for the toplevel (`src/app.zig:808`). `paintNode` (`src/app.zig:523`) visits each mapped widget and makes its quads again.
- Change: keep the quads of each widget as a range that stays valid while the widget is clean. A frame then makes new quads only for the dirty widgets and copies the other ranges. Offsets and clips of a parent are the hard part: a range must hold positions that do not depend on the frame, or the copy must add the offset.
- Expected gain: the paint stage goes from a cost for each widget to a copy for each quad. A copy of the quads of 1,000 widgets is small against 1,438 us. I did not measure a prototype. This change is the largest of the list.
- A smaller step: `restyleNode` (`src/app.zig:439`) also visits each widget in each frame. It costs 36 us at 1,000 widgets, so it is not urgent.

## 3. Each paint shapes the text of each widget again

- Measure: in the profile of `k.tcl`, `shape.shape` has 16.2 M instructions, `Font.kern` 14.7 M, `Face.classOf` 6.1 M, and `Builder.text` 22.4 M with its list appends. The sum is 59.4 M, 23% of `paintNode`. The hash map of the glyph atlas has 12.6 M more.
- Cause: the text paint in `src/paint.zig` calls `shape.measure` (line 201) and then `shape.shape` (line 207) for each line, in each frame. `shape` allocates a glyph list on each call (`src/text/shape.zig:70`). The entry shapes its text two times in one paint (`src/widgets/entry.zig:502` and `:536`), and again in `indexX` and `syncView` (`:1173`, `:1185`). The canvas keeps its runs (`src/canvas/canvas.zig:896`), and the other widgets do not.
- Each glyph of each frame also does one lookup in the atlas map.
- `Font.glyph` (`src/text/font.zig:38`) has a table for ASCII only. Each other character does a `cmap` lookup on each shape. I did not measure text with such characters.
- Change: keep the shaped run on the widget, with the text, the font, and the scale as its key. Keep the atlas slot of each glyph in the run. Make the run again only when the key changes.
- Expected gain: 23% to 28% of the scene build of a frame with 1,000 text widgets, and most of the cost of the entry paths above. Finding 2 removes this cost for clean widgets, so this finding then matters for the dirty ones and for the first frame.

## 4. `ztk::animate` moves each value through text

- Measure: `anim-1000` has a median of 4,682 us and a 99th percentile of 6,235 us. `anim-hover-1000`, the same window with one transition, has 906 us. The 1,000 animations add 3.8 ms, so one animation costs 3.8 us in each frame. The budget of the plan for a frame with 1,000 widgets is 4 ms.
- Cause: for each track in each frame, `tick` (`src/animate.zig:420` to `:426`) formats the new value as text, reads the current option as text, compares the two texts, and sets the option with `options.setOne`. `setOne` parses the text again and makes the widget dirty for style.
- Change: keep the start and end values of a track in their typed form, for example a `Color`. Compute the new value, compare it with the typed current value, and write the field. Use the text path only for an option that has no typed form.
- Expected gain: I did not profile the case, so the split between the text work and the style work is not known. The style work stays.

## 5. The CPU renderer draws each pixel of each frame

- Measure: `cpu-render-demo` has a median of 10,711 us. In the profile of `k.tcl`, `render.cpu.render` has 6,560.6 M of 7,056.4 M instructions with its callees (93%). The run has 22 frames, so one rendered frame is 298 M instructions or more. `boxCoverage` alone has 1,612.8 M (23%).
- Cause: `render` (`src/render/cpu.zig:193`) writes the clear color to each pixel, one byte at a time, and then draws each quad of the scene. It has no rectangle of change. Only one button changes in each frame of `k.tcl`.
- This renderer is the one for `--headless`, `--cpu`, the framebuffer, and the 2D canvas on the web.
- Change, step 1: clear with one 4-byte `@memset`.
- Change, step 2: compare the new scene with the last one, or use the dirty ranges of finding 2, to get a rectangle of change. Keep the last image and draw only the quads that touch the rectangle, with the rectangle as a clip.
- Expected gain: for a change of one widget, the draw cost drops by about the ratio of the window area to the widget area. A full change, such as a scroll, has no gain from step 2.

## 6. A wheel step on an entry costs five hover frames

- Measure: `scroll-wheel` has a median of 4,830 us and a 99th percentile of 5,670 us. `frame-hover-1000` in a window with the same 1,000 widgets has 926 us. The budget is 4 ms.
- Cause: not profiled. The entry shapes its text two times in a paint and again in `syncView` for the scrollbar (finding 3), and the case runs with transitions on. These facts are from the source. Their share of the 4,830 us is not measured.
- Change: profile the case alone first. A build of the bench that runs one case by name makes this possible in seconds. The full bench needs 104 seconds.

## 7. The animation of a widget is found by a linear search

- Measure: none. No bench case has many transitions at one time. `anim-1000` uses `ztk::animate`, and that code has its own list.
- Cause: `paintOwn` calls `anim.keyOf` and `anim.transitionOf` for each widget in each frame (`src/app.zig:545` and `:575`). Both search a list from the start (`src/anim.zig:137` to `:145`). With t running transitions and n widgets, a frame does t times n compares. A theme change that starts a transition on each widget gives n squared.
- Change: keep the index of the animation in the widget, or use a hash map from the widget to the animation.
- Expected gain: not known. Add a bench case with a transition on each of the 1,000 widgets before the change.

## 8. Two scroll cases have a slow 99th percentile

- Measure: `sheet-10000-scroll` has a median of 786 us and a 99th percentile of 5,452 us. `vector-10000-drag` has a median of 15 us and a 99th percentile of 4,434 us.
- Cause: not checked. Possible causes are a compact of the interpreter, the growth of a list, or a full pass that runs at an interval.
- Change: record the stage times of the slow frames with `ZTK_FRAME_STATS` and find the stage.

## Proposed issue titles

1. Update the ztcl pin to get the constant-time guard check
2. Keep the quads of a clean widget between frames
3. Keep the shaped run of a widget and the atlas slot of each glyph
4. Animate typed values in `ztk::animate` without text
5. Clear the CPU frame with one `@memset`
6. Draw only the changed rectangle in the CPU renderer
7. Add a bench flag that runs one case by name
8. Profile `scroll-wheel` and bring it under 4 ms
9. Find the animation of a widget without a linear search
10. Find the cause of the slow 99th percentile of `sheet-10000-scroll` and `vector-10000-drag`
