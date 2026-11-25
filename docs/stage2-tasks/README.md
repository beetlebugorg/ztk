# The widget stage

This stage adds every widget class of Tk 8.6, classic and `ttk`, with `pack`, `place`, scrolling, `grab`, focus traversal, the dialogs that need only these widgets, and a gallery of example programs. The user asked for this stage before the rest of Stage 2, so that the screenshots of the site show each widget in use. [The plan](../plan.md) has the design, and section 11 of the plan has the new order.

The Stage 1 rules of [the task index](../tasks/README.md) apply to each task here. This page adds the rules of this stage.

## The tasks

Do the tasks in order. One task is one branch, one PR, and one review. A task starts from the current `main`, after the PR of the task before it is merged.

| # | Task | Needs |
|---|---|---|
| 01 | [`pack` and `place`](01-pack-place.md) | |
| 02 | [Animation: transitions, keyframes, `ztk::animate`, and the frame clock](02-animation.md) | 01 |
| 03 | [`checkbutton` and `radiobutton`, and the role of each class](03-check-radio.md) | 02 |
| 04 | [`labelframe`, `message`, `toplevel`, `grab`, focus traversal, and `ztk::tooltip`](04-toplevel-grab.md) | 03 |
| 05 | [`scale`](05-scale.md) | 04 |
| 06 | [The web backend](06-web.md) | 05 |
| 06b | Live demos on the site: each card of "What it draws" runs its example in WebAssembly (see task 18) | 06 |
| 06c | [The WebGPU renderer](06c-webgpu.md) | 06b |
| 07 | [Scrolling and `scrollbar`](07-scrollbar.md) | 06c |
| 14 | [`canvas`](14-canvas.md), in two PRs: 14a the widget, 14b the two apps | 07 |
| 08 | [`entry` additions and `spinbox`](08-entry-spinbox.md) | 14 |
| 09 | [`ttk::style` and the simple `ttk` widgets](09-ttk-simple.md) | 08 |
| 10 | [`ttk::combobox`, `ttk::spinbox`, `ttk::scale`, `ttk::scrollbar`, and `ttk::progressbar`](10-ttk-range.md) | 09 |
| 11 | [`listbox`](11-listbox.md) | 10 |
| 12 | [`menu`, `menubutton`, `ttk::menubutton`, and `tk_popup`](12-menu.md) | 11 |
| 13 | [`panedwindow`, `ttk::panedwindow`, and `ttk::notebook`](13-panes-notebook.md) | 12 |
| 15 | [`text`](15-text.md) | 13 |
| 16 | [`ttk::treeview`](16-treeview.md) | 15 |
| 17 | [The dialogs](17-dialogs.md) | 16 |
| 18 | [The gallery and the site](18-gallery.md) | 17 |

Task 14 has two PRs (a decision for the user, 2026-11-25). PR 14a has the canvas widget, its scrolling, the stand-in `image` command, and `ztk::animate` on items. PR 14b has the two apps of the task, `examples/spreadsheet.tcl` and `examples/vector.tcl` with its script console, and their tests, gates, and gallery cards.

The order puts the simple widgets first, so that they show in the screenshots early. Then come scrolling and the canvas, the entry additions, the `ttk` widgets, the list, the menus, the panes, the text widget, and the tree. The user moved the canvas to the place after scrolling on 2026-11-24, so the task numbers are not in order: do the tasks in the order of the table. Each task adds its widgets to `examples/gallery.tcl` (task 03 makes it) and draws the shots again, so the site shows each widget when its task is merged. Task 18 adds the other example programs, the site text, and a link from each shot to the same example in the browser.

## Scope

- In scope: the script commands, options, widget subcommands, class bindings, and virtual events of each widget class in its manual page, with the error messages of `wish` 8.6.16.
- The web backend moves from Stage 3 into this stage (task 06), so each widget runs in a browser from that task on.
- Out of scope: the X11, Metal, and Direct3D 12 backends and renderers, the Tk test suite runner (`tools/tksuite.sh`), `image` beyond the stand-in of task 14, the system fonts, and the native dialogs of D9. The dialogs of this stage are drawn by ztk on each platform.
- The pass rates of the Tk test files stay targets of their stages (section 11 of the plan). A task here runs the Tk test file of its widget when the task file names one, and writes the counts in its PR. A count that is low is a fact for the report, and it does not block the merge.

## The look: modern by default

Tk 8.6 behavior is the floor for scripts. The look and the extras are those of a current desktop program (macOS 14, GNOME 46 with libadwaita, Windows 11). Each rule below applies to each widget task.

1. The modern theme is the default. It has the font of the system and its sizes, wide spacing, round corners, a soft shadow for raised surfaces (menus, popovers, tooltips, the dropdown of a combobox), the accent color of the system where the backend gives it, a clear focus ring, and light and dark schemes that follow the system.
2. Scrollbars are overlay scrollbars in the modern theme: thin, over the content, visible during a scroll and on hover, and hidden after a short delay. A script that packs a classic `scrollbar` beside its content still works: the scrollbar keeps its requested width, and the theme draws a thin thumb in it.
3. The look of Tk on X11 (reliefs, 3D borders, square indicators) is the `classic` theme. A script selects it with `ztk::style theme classic` or `ttk::style theme use classic`. It is never the default.
4. Each modern extra is an option, a style class, or a command on a Tk widget, so that a Tk script still works and a ztk script gets the extra with one word. The extras of this stage:
   - a switch style for `checkbutton` and `ttk::checkbutton` (`ztk::class .c switch`, or the `ttk` style `Switch.TCheckbutton`);
   - a segmented style for a group of radiobuttons (`segmented`);
   - placeholder text (`-placeholder`) for `entry`, `ttk::entry`, `spinbox`, and `ttk::combobox`, and a search style with a clear button (`search`);
   - menus and popovers with round corners, a shadow, icons (`-image`), and key hints (`-accelerator`);
   - `ztk::tooltip path text`;
   - inline banners and toasts (`ztk::toast`, task 16);
   - an empty state text (`-emptytext`) for `listbox` and `ttk::treeview`;
   - a sidebar style (`sidebar`) for `listbox` and `ttk::treeview`.
5. An option that ztk adds and Tk does not have starts with no `-ztk` prefix and appears in `configure` after the options of Tk. Each one is in `docs/stage2-limits.md` under "Additions".
6. Each widget class has its accessibility role from task 03 on (section 4.9 of the plan): a `role` in its class table. Stage 8 reads it.
7. Input: a wheel event with a fractional delta scrolls by the fraction (high-resolution scroll), a touchpad scroll has momentum after the fingers lift, and each widget works with the keyboard alone. Pinch, swipe, IME, and emoji input need the backend events of Stage 2 and Stage 8. A task that cannot test them says so in its PR.

## Animation

Animation is part of the API of each widget. Task 02 makes the engine and the API. Each later task lists its animations under "Animations" in its file.

- CSS: `transition` with the property list, the duration, the timing function, and the delay. `@keyframes` with the `animation` property. The timing functions are `linear`, `ease`, `ease-in`, `ease-out`, `ease-in-out`, `cubic-bezier()`, `steps()`, and `spring()` (a ztk function with stiffness, damping, and mass). The properties that move are the colors, the opacity, the radii, the shadows, the outline, the padding, and the minimum sizes. A change of padding or size moves the layout of the widget at each frame only when the task of the widget says so.
- State changes animate through the transitions of the theme: hover, pressed, focus, disabled, selected, and checked.
- Tcl: `ztk::animate target ?-option value ...? -duration ms ?-easing name? ?-delay ms? ?-command script?` gives an id. The target is a widget path or a canvas item (`.c 12`). `ztk::animate cancel id`, `pause id`, `resume id`, and `info ?id?` control it. A new animation of the same option of the same target starts from the shown value and replaces the old one.
- Widget behavior that animates: `xview` and `yview` with smooth scroll and momentum, the tab change of a notebook, the sash of a paned window, the open and close of a menu, the open and close of a tree item, and the indeterminate mode of a progress bar.
- The engine: the render thread moves the animations from the frame clock of the backend. The UI thread gives it the start and end values and the timing, as data in the frame. The render thread interpolates in the scene, so a script that is busy does not stop an animation. A Tcl script runs only for a `-command` at the end, and for an animation of a layout value (the UI thread runs a layout at each frame that it can).
- `ZTK_NO_ANIMATION=1` and the reduced-motion setting of the system give the end state of each animation at once.
- Determinism: the headless backend has a fixed frame clock. `ztk --time ms` and `ztk::clock set ms` (headless only) draw the frame of a given time, for the tests and for a gallery shot in the middle of an animation.

## The web

Each widget, the animation engine, and the style system build and run in the WebAssembly target. Task 06 adds the browser as a backend.

- No code path of the core needs threads, files, or a native window. Where the native build uses the render thread, the web build drives the same frame clock from `requestAnimationFrame`, or from a worker with an `OffscreenCanvas` when the browser has it. The fluid gates of the stage apply to the web build too.
- The browser draws the same scene with its own GPU API: WebGPU where the browser gives an adapter (task 06c), else WebGL 2, else the CPU renderer into a 2D canvas. No translation layer is between ztk and the browser.
- Input comes from the DOM: pointer, wheel with momentum, keyboard, and a hidden input element for text and composition (IME). The clipboard is the async clipboard. The scale is `devicePixelRatio`. `prefers-color-scheme` and `prefers-reduced-motion` set the scheme and turn the animations off.
- Accessibility: a parallel DOM tree with ARIA roles, from the `role` of each class.
- From task 06 on, the acceptance of each task includes the web build: `zig build wasm` compiles, and a headless browser test (Playwright or a headless Chromium on the path) runs the example of the task and checks its pixels or its state. A machine without the browser skips the test with `SKIP:` and the reason.

## Fluid

Each widget is fluid. These rules are measured, and each task has a gate for its own animations and for its scroll or drag path.

1. Each animation, scroll, drag, resize, and hover runs at the refresh rate of the display: 60 frames in each second at least, and 120 on a display at 120 Hz, with no dropped frame.
2. The gate: the work of ztk for one frame is under 8 ms at the 99th percentile on the reference machine of the plan, in `ReleaseFast`, in `zig build bench`. Each task adds the bench cases of its file and writes the results in its PR with the command, the date, and the machine.
3. Input to the screen: the visible answer to a key or a pointer event is in the next frame. A drag (a scale slider, a sash, a scrollbar thumb, a canvas item) and a scroll follow the pointer from the render thread, with no wait for a Tcl script. The script gets the new value after the frame.
4. A change during an animation starts from the shown value and never jumps.
5. A layout change animates where Tk allows it (a notebook tab, a tree item that opens, a pane that changes size). An animation never blocks input.
6. Budgets: a canvas with 10 000 items and a text widget with 1 MB of text scroll at the full rate. Tasks 14 and 15 test them.

## Acceptance for each task

Each task file has its own tests. Each task also passes these checks before its merge:

1. `zig build test`, `tests/*.sh`, `sh tools/check-repo.sh`, and the docs build (`python3 tools/build-docs.py site`) pass. `tests/shots.sh` passes after `tools/shots.sh` drew the new shots.
2. The script tests of the task cover the options (`configure` and `cget` with the defaults and the messages of `wish`), the widget subcommands, the class bindings and events, the keyboard, and the state changes.
3. Where a behavior can be compared, a script runs in `wish` 8.6.16 under `xvfb-run` and in `ztk --headless`, as `tests/demo.sh` does, and the values are equal. A difference goes in `docs/stage2-limits.md`.
4. The widget has CSS rules in the modern theme for light and dark, and the gallery shows it in both schemes.
5. The animations of the task file work, with a test of the end state, of a frame in the middle at a fixed time, and of a replace during the animation.
6. The fluid gate of the task file passes.
7. From task 06 on: the wasm build compiles, and the browser test of the task passes.
8. CI is green: each job of `gh pr checks <n>` is `SUCCESS` or `SKIPPED`. Then the PR merges with a rebase.

## Limits

`docs/stage2-limits.md` (task 01 makes it) lists each option, subcommand, and event of a widget of this stage that ztk does not have or that differs from `wish`, and the additions of ztk.
