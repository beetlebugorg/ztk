# Task 16: `ttk::treeview`

## Goal

The tree widget works with a tree and with columns.

## Files

- `src/ttk/treeview.zig`, `src/tests/treeview.zig`

## Steps

1. Read `doc/ttk_treeview.n`.
2. The options, the item options, the column options, the heading options, the tag options, and all subcommands of the page, with `<<TreeviewSelect>>`, `<<TreeviewOpen>>`, and `<<TreeviewClose>>`.
3. The keys and the pointer: open and close, selection modes, column resize by a drag of the heading border.
4. Additions: `-emptytext` and the `sidebar` style.

## Tests

- `zig build test -Dtest-filter=treeview`: each subcommand, the events, the keys, a column resize, and the messages of `wish`. `ttk/treeview.test` counts go in the PR.

## Animations and the fluid gate

An item opens and closes with a move of the rows below it and a turn of the arrow. The fluid gate: `treeview-10000-scroll` and `treeview-open` are under 8 ms.

## Acceptance

- The tests of this file pass.
- The checks of [the index](README.md#acceptance-for-each-task) pass, with the modern look, light and dark, and the web build from task 06 on.
- The widgets of the task show in the gallery shots.

## Out of scope

- None.
