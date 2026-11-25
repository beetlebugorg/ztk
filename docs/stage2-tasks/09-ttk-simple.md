# Task 09: `ttk::style` and the simple `ttk` widgets

## Goal

`ttk::style` maps onto the CSS of ztk (section 4.8 of the plan). The simple `ttk` widgets exist: `ttk::button`, `ttk::checkbutton`, `ttk::radiobutton`, `ttk::label`, `ttk::frame`, `ttk::labelframe`, `ttk::entry`, `ttk::separator`, and `ttk::sizegrip`. The `classic` theme exists.

## Files

- `src/ttk/style.zig`, `src/ttk/widgets.zig`, `src/themes/classic.css`
- `src/tests/ttk.zig`

## Steps

1. Read `doc/ttk_*.n`.
2. `ttk::style configure`, `map`, `lookup`, `layout`, `element names`, `element options`, `theme names`, `theme use`, and `theme settings`, as rules of origin 5. A style name `Accent.TButton` is the type `TButton` with the class `Accent`.
3. The standard `ttk` options (`-class`, `-cursor`, `-style`, `-takefocus`) and the `state` and `instate` subcommands with the state names of `ttk`.
4. Each widget with its options and subcommands from its manual page. `-image` draws an image of `image create photo`, the stand-in of task 14 that reads PNG through `src/png.zig`.
5. `Switch.TCheckbutton` is the switch style.
6. The `classic` theme: the reliefs and the sizes of Tk on X11. `ztk::style theme name` selects it.

## Tests

- `zig build test -Dtest-filter=ttk`: each widget, `state` and `instate`, `style configure` and `map` with `lookup`, `theme use classic` and back, and the messages of `wish`.
- The `ttk` test files of these widgets run on `wish`, and the counts go in the PR.

## Animations and the fluid gate

State changes move through the theme transitions. The fluid gate: `ttk-hover-1000` is under 8 ms.

## Acceptance

- The tests of this file pass.
- The checks of [the index](README.md#acceptance-for-each-task) pass, with the modern look, light and dark, and the web build from task 06 on.
- The widgets of the task show in the gallery shots.

## Out of scope

- The `ttk` widgets of tasks 10, 13, and 16.
