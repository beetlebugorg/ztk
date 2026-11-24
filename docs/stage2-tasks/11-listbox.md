# Task 11: `listbox`

## Goal

The classic `listbox` works with its selection modes, scrolling, and the sidebar style.

## Files

- `src/widgets/listbox.zig`, `src/tests/listbox.zig`

## Steps

1. Read `doc/listbox.n`.
2. All options and subcommands of `listbox.n`: `activate`, `bbox`, `curselection`, `delete`, `get`, `index`, `insert`, `itemcget`, `itemconfigure`, `nearest`, `scan`, `see`, `selection`, `size`, `xview`, and `yview`, with `-listvariable` and the four selection modes.
3. The class bindings of `wish` for the pointer and the keys, and `<<ListboxSelect>>`.
4. Additions: `-emptytext` and the `sidebar` style (rows with round selection and the accent color).

## Tests

- `zig build test -Dtest-filter=listbox`: each subcommand, each selection mode with the pointer and the keys, `-listvariable`, `see`, and the messages of `wish`. `listbox.test` counts go in the PR.

## Animations and the fluid gate

The selection background moves between rows with an ease. The scroll is smooth. The fluid gate: `listbox-scroll-10000` (10 000 rows) is under 8 ms.

## Acceptance

- The tests of this file pass.
- The checks of [the index](README.md#acceptance-for-each-task) pass, with the modern look, light and dark, and the web build from task 06 on.
- The widgets of the task show in the gallery shots.

## Out of scope

- None.
