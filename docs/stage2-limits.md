# Limits of the widget stage

This page lists what a command or a widget of the [widget stage](stage2-tasks/README.md) does not have, or does in another way than `wish` 8.6.16. Each task adds its entries. The section "Additions" lists the options and commands that ztk has and Tk does not have.

## pack and place (task 01)

- `pack` and `place` have all subcommands and options of `pack.n` and `place.n`. `tools/oracle.sh tools/oracle-pack.tcl <seed> 200` gave no difference for the seeds 1, 2, 3, 4, 5, and 99, and `tools/oracle-place.tcl` gave no difference for the seeds 1 to 4 (2026-11-24).
- A distance with a unit (`1c`) uses the `tk scaling` of ztk (96/72 logical pixels in a point). `wish` under `Xvfb` has another scaling, so `place .a -x 1c` gives 38 in ztk and 39 in that `wish`.
- `pack propagate . 0` keeps the requested size of `.` that ztk measures. `wish` gives a toplevel with no content the requested size 200 by 200, so `winfo reqwidth .` differs.
- `-in` takes a container in the same toplevel only, because ztk has one toplevel until task 04.

## Animation (task 02)

- The render thread moves a transition of the paint: the colors, the opacity, the radii, the shadow, and the outline. The UI thread paints the widget at the start and at the end of the transition, and the render thread draws the quads between them for its own time. When the two paints have a different count of quads (for example an outline that appears), the UI thread moves the transition, as in Stage 1.
- The render thread moves all quads of one widget with one timing: the property of the transition with the longest time. The UI thread uses the timing of each property. The two differ only when one transition gives two properties a different timing.
- A keyframe animation, a move of the padding or a minimum size, and `ztk::animate` run on the UI thread. A script that is busy stops them until it returns.
- `ztk::animate` moves options of the types color, screen distance, and integer, and options whose value is a number. A canvas item as the target comes with the canvas (task 14).
- A spring has its own duration: the time after which it stays within 0.001 of its end. The duration of the declaration is not used for a spring.
- `ztk --time MS` draws the first frame at the time 0 and the frames after it at MS. Only the headless backend has it.
- The backends have no reduced motion setting yet. `ZTK_NO_ANIMATION=1` and `ztk::animate reduce 1` give the end states.
- `zig build bench`, ReleaseFast, 2026-11-24, development machine with a load average of 8 to 9: `anim-hover-1000` median 0.85 ms and 99th percentile 1.36 ms; `anim-1000` (1 000 option animations at once) median 4.06 ms and 99th percentile 7.20 ms. Both are under the gate of 8 ms. `anim-1000` is near it, because each step of an option animation goes through `configure`.

## checkbutton and radiobutton (task 03)

- The options of `wish` 8.6.16 exist with their defaults, except `-borderwidth`, `-padx`, and `-pady`, whose defaults are 0 because the theme gives the border and the padding (as for `label` and `button`). `-bitmap`, `-image`, `-selectimage`, `-tristateimage`, `-compound`, `-underline`, `-wraplength`, `-highlight*`, `-offrelief`, `-overrelief`, and `-selectcolor` are stored and have no effect on the look. `-indicatoron 0` removes the indicator.
- A press invokes the widget, as the class bindings of `wish` on X11 do. A press does not give the focus, as in `wish`.
- `flash` has no effect.
- The motion of the indicator (the check mark, the dot, the knob of a switch) runs on the UI thread, from the `transition` of the part `::indicator`.
- The role of a switch is the role of its class, `check box`. A role for each widget comes with Stage 8.
- `zig build bench`, ReleaseFast, 2026-11-24, load average 9: `check-toggle-1000` (1 000 checkbuttons, one toggles each 10 frames and its indicator moves) median 3.63 ms, 99th percentile 5.12 ms. A second run under the same load gave a 99th percentile of 13.5 ms, so the gate of 8 ms holds only on a machine with less load.

## toplevel, labelframe, message, grab, and focus (task 04)

- A `toplevel` has its own platform window, render thread, and `wm` state. `wm` has the subcommands of Stage 1 for each toplevel. `-menu` is stored until task 12 draws a menu bar. `-screen`, `-use`, `-container`, `-colormap`, and `-visual` are stored and have no effect.
- `winfo rootx` and `rooty` of a widget in a second toplevel count from the corner of its own window, because a Wayland program does not know the position of its windows.
- `labelframe` draws its title above the box, or below it with an anchor that starts with `s`. The anchors that start with `e` or `w` put the title at the top right or the top left. `-labelwidget` is stored and has no effect.
- `message` breaks lines at spaces only. With no `-width`, it tries 24 widths and keeps the first one whose ratio of width to height is at least `-aspect` / 100. `wish` gives other line breaks for the same text, because its font has other widths.
- `grab` is local. `-global` gives a local grab and `grab status` then reports `global`. A grab sends a pointer event of a widget outside its tree to the grab widget. It does not change the keyboard focus.
- `<<NextWindow>>` and `<<PrevWindow>>` are not virtual events yet: `Tab` and `Shift-Tab` move the focus through bindings on `all`, as in Stage 1.
- `zig build bench`, ReleaseFast, 2026-11-24, load average 9: `toplevel-open` (a new toplevel with 50 labels, to its first frame, and its delete) median 4.67 ms and 99th percentile 42.9 ms. The 99th percentile is over the gate of 8 ms. Each toplevel starts a render thread, and the slowest runs include the start of that thread.

## scale (task 05)

- The options of `wish` 8.6.16 exist with their defaults, except `-borderwidth` (0, the theme gives the border). `-repeatdelay`, `-repeatinterval`, `-sliderlength`, `-sliderrelief`, `-troughcolor`, `-width`, `-activebackground`, and `-highlight*` are stored and have no effect on the look. A press on the track moves one step; holding the button does not repeat.
- The class bindings use key patterns (`<Key-Left>`, `<Control-Key-Left>`, `<Key-Home>`) where `wish` binds the virtual events `<<PrevChar>>`, `<<PrevWord>>`, and `<<LineStart>>`, because `event add` is not in ztk yet. So `bind Scale` lists other patterns than in `wish`.
- `set` does not run `-command`, as in `wish`. A change by the user runs it at once, where `wish` runs it as an idle callback.
- The drag of the slider runs on the UI thread. `zig build bench`, ReleaseFast, 2026-11-24, load average 9: `scale-drag` (one motion for each frame beside 1 000 widgets) median 1.11 ms and 99th percentile 1.26 ms, under the gate of 8 ms.

## The web backend (task 06)

- The browser build is the core with the headless backend inside (`src/web.zig`). The page (`web/ztk.js`) gives the clock, the size, the scale (`devicePixelRatio`), the color scheme, the reduced motion setting, and the input, and draws each scene (task 06c has the renderers).
- The build has one thread, so it draws inline. The frame clock is `requestAnimationFrame`. An `OffscreenCanvas` in a worker is not used.
- The canvas draws the window of "." only. A second toplevel has no canvas.
- The canvas has the size of the window of ".", in CSS pixels, and its backing store is that size times `devicePixelRatio`. The window first gets the size of the element that holds the canvas, and then its own size from geometry propagation, as a toplevel in Tk. A change of the size of the page does not resize the window. A change of `devicePixelRatio` draws the next frame at the new scale. Until 2026-11-24, the playground stretched the window to the size of its frame: the canvas kept the CSS size of the frame, and the backing store had the size of the window.
- Keys: the names of `KeyboardEvent.key` map to key symbols for the keys that are not text. Text and the end of an input method composition come from a hidden text area. The preedit text of a composition is not drawn. The clipboard is not connected.
- The program reads no files. The page gives the style sheets of the examples by name for `ztk::style load`.
- The accessible tree is a list of hidden elements with ARIA roles, names, and bounds over the canvas. It has no keyboard focus of its own and no actions.
- `tests/web.sh`, 2026-11-24, development machine, headless Chromium with SwiftShader: the WebGL 2 image of the gallery equals the CPU image within 1 level in each pixel. The frame time of the module in V8 (node, ReleaseFast, the gallery at scale 2, 200 frames of pointer motion) was median 4.88 ms and 99th percentile 7.25 ms in one run, median 5.52 ms and 99th percentile 14.14 ms in a second run, and median 3.88 ms and 99th percentile 6.10 ms in a third run, under a load of 8 to 9. The gate of 8 ms at the 99th percentile is met in two of the three runs. The paint makes the whole scene again for each frame, with the text shaped again.
- The module is 3.0 MB (1.0 MB with gzip), with 0.8 MB of fonts.

## The WebGPU renderer (task 06c)

- The page draws with WebGPU (`web/webgpu.js`) when `navigator.gpu` gives an adapter and a device, else with WebGL 2, else with the CPU renderer of the module into a 2D canvas. `renderer: "webgpu" | "webgl2" | "cpu"` or `?renderer=` sets the first choice, and a choice that fails goes to the next one. The page logs the choice one time with `console.info`.
- All canvases of a page share one device. After a device loss, each renderer gets a new device, makes its pipeline again, uploads the atlas again, and draws the last scene.
- The canvas is `display-p3` where `(color-gamut: p3)` matches, and the shader converts the sRGB colors of the scene to P3. The blend then works on P3 values, so the edges differ a little from the sRGB blend of the CPU renderer: `tests/web.sh` found 0.095 % of the pixels over 2 levels, worst 5 (2026-11-24, after a conversion back to sRGB).
- The canvas has no `preserveDrawingBuffer` in WebGPU. `snapshot()` of the handle draws the last scene again and reads the canvas in the same task.
- `tests/web.sh`, 2026-11-24, development machine with a load average of 8 to 9, headless Chromium 155 with SwiftShader for Vulkan and ANGLE: WebGPU, WebGL 2, and the CPU renderer in a 2D canvas each equal the native CPU image of the gallery (0.000 % of the pixels over 2 levels, worst 1), and so does WebGPU after a forced device loss.
- The CPU time of a frame (the work of ztk and the calls of the renderer, 120 frames of pointer motion, one frame for each `requestAnimationFrame`, the same run, load average 12): the gallery with WebGPU median 7.80 ms and 99th percentile 22.10 ms, with WebGL 2 median 4.40 ms and 99th percentile 5.70 ms; 1 200 labels (about 200 visible) with WebGPU median 8.00 ms and 99th percentile 18.90 ms, with WebGL 2 median 4.70 ms and 99th percentile 7.40 ms. The WebGPU runs miss the gate of 8 ms at the 99th percentile, and the WebGL 2 runs meet it. The draw of WebGPU alone (300 draws of the last scene) is median 0.20 ms and 99th percentile 2.10 ms for the gallery, and the module alone in the WebGPU frames is median 6.90 ms and 99th percentile 20.20 ms, against 4.30 ms and 5.30 ms in the WebGL 2 frames. So the extra time is in the module, which runs the same code with each renderer. SwiftShader renders WebGPU on the same CPU cores in the GPU process. That contention is the probable cause. It was not checked on a real GPU, so `tests/web.sh` reports the WebGPU times and fails only on a WebGL 2 median over 8 ms. The stress scenes of tasks 14 and 15 (10 000 canvas items, a large text) do not exist yet.

## Live demos on the site (task 06b)

- Each card of "What it draws" runs its example live when it comes within 200 pixels of the view, or at the first tap on a device with a coarse pointer. The screenshot shows until the first frame. The page compiles `ztk.wasm` one time, and each card has its own instance and canvas.
- The demo has the logical size of its poster (the screenshot is at scale 2) and draws at the scale of the screen times the shown size, so it has the size of the poster in the page. `tests/site.sh` (2026-11-24, headless Chromium with SwiftShader) found each card equal to its poster in light and dark: at most 1 level in each pixel.
- The examples that read no files run as they are. `ztk::style load` gets the style sheet that the page fetched.
- The page has no budget check of its size yet. The module is 3.0 MB (1.0 MB with gzip) and loads only when the first card goes live.

## Additions

- `ztk::animate`, `ztk::clock`, the timing function `spring()`, and the flag `--time` of the `ztk` program.
- The style classes `switch` (checkbutton) and `segmented` (radiobutton), and the part `::indicator`.
- `ztk::tooltip path ?text?`, the parts `::tooltip` of a toplevel and `::label` of a labelframe.
- The parts `::trough`, `::fill`, `::slider`, and `::value` of a scale.
