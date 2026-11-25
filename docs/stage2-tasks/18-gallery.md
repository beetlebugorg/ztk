# Task 18: The gallery and the site

## Goal

The screenshots of the site show each widget in a program, in the modern theme, light and dark. Each shot has a link that runs the same example in the browser.

## Files

- `examples/`: `gallery.tcl`, `editor.tcl` (menus, a text widget with tags, scrollbars), `files.tcl` (a tree, a combobox, a paned window), `draw.tcl` (a canvas), and `settings.tcl` (a notebook, checkbuttons, radiobuttons, scales, spinboxes, a progress bar)
- `tools/shots.sh`, `docs/site/shots/`, `docs/site/index.html`, `docs/site/run/`, `README.md`

## Steps

1. Each widget class of the stage shows in at least one example.
2. `tools/shots.sh` draws each example in light and dark at scale 2 and optimizes the files.
3. The section "What it draws" of the site and the README have one caption for each image. A caption says what the image shows.
4. The settings card is two columns wide on a desktop.
5. Each card runs its example live (task 06b does this for the examples that exist, and each later task adds its own): the screenshot is the poster, shown at once and kept for readers with no script, the README, and saved data. The live demo replaces it when the card scrolls into view (an IntersectionObserver), or at the first tap on a phone. The page loads the wasm module one time, and each card has its own instance and canvas. The demo has the same theme, size, and scale as its poster, so the swap does not move anything. Each card has a "View source" toggle with the Tcl script and a link that opens the script in the playground.
6. The page stays fast: the poster is the largest contentful paint, each card has its size before it loads, and the wasm module loads only when a card needs it.
7. A headless Chromium test checks that each card goes live, answers a click and typed text, and equals its poster within a small pixel tolerance at the time 0.

## Tests

- `tests/shots.sh` passes. `tests/web.sh` runs each example in the browser.

## Animations and the fluid gate

The gallery has one shot in the middle of an animation, drawn with `--time`.

## Acceptance

- The tests of this file pass.
- The checks of [the index](README.md#acceptance-for-each-task) pass, with the modern look, light and dark, and the web build from task 06 on.
- The widgets of the task show in the gallery shots.

## Out of scope

- None.
