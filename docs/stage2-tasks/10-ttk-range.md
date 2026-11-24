# Task 10: `ttk::combobox`, `ttk::spinbox`, `ttk::scale`, `ttk::scrollbar`, and `ttk::progressbar`

## Goal

The `ttk` widgets for a value and a range exist.

## Files

- `src/ttk/range.zig`, `src/ttk/combobox.zig`, `src/tests/ttk2.zig`

## Steps

1. Read the manual pages of the five widgets.
2. `ttk::combobox` with `-values`, `-postcommand`, `-height`, `current`, `set`, `get`, the dropdown list in a popover window with a round corner and a shadow, and `<<ComboboxSelected>>`. `-placeholder` is an addition.
3. `ttk::spinbox`, `ttk::scale`, and `ttk::scrollbar` with the options of their pages, on the code of tasks 05, 07, and 08.
4. `ttk::progressbar` with `-mode determinate|indeterminate`, `-maximum`, `-value`, `-variable`, `start`, `stop`, and `step`.

## Tests

- `zig build test -Dtest-filter=ttk2`: each widget, the dropdown with the keys and the pointer, `<<ComboboxSelected>>`, the progress values, and the messages of `wish`.

## Animations and the fluid gate

The dropdown opens and closes with a fade and a short slide. The determinate bar moves to a new value with an ease. The indeterminate bar moves on the render thread. The fluid gate: `progress-indeterminate` and `combobox-open` are under 8 ms.

## Acceptance

- The tests of this file pass.
- The checks of [the index](README.md#acceptance-for-each-task) pass, with the modern look, light and dark, and the web build from task 06 on.
- The widgets of the task show in the gallery shots.

## Out of scope

- None.
