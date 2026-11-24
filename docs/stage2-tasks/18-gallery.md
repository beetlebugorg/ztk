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
5. Each card has a "Run it" link to a page of `docs/site/run/` that loads the wasm build and the example. One playground page has an example picker and an editable script.

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
