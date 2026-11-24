# Task 13: `panedwindow`, `ttk::panedwindow`, and `ttk::notebook`

## Goal

The paned windows and the notebook work.

## Files

- `src/widgets/paned.zig`, `src/ttk/notebook.zig`, `src/tests/paned.zig`

## Steps

1. Read `doc/panedwindow.n`, `doc/ttk_panedwindow.n`, and `doc/ttk_notebook.n`.
2. `panedwindow` with its options, `add`, `forget`, `identify`, `panecget`, `paneconfigure`, `panes`, `proxy`, and `sash`, and the drag of a sash.
3. `ttk::panedwindow` with `add`, `forget`, `insert`, `pane`, `panes`, and `sashpos`.
4. `ttk::notebook` with `add`, `forget`, `hide`, `identify`, `index`, `insert`, `select`, `tab`, `tabs`, `enable traversal`, and `<<NotebookTabChanged>>`.

## Tests

- `zig build test -Dtest-filter=paned` and `notebook`: each subcommand, a sash drag, tab changes with the pointer and the keys, and the messages of `wish`.

## Animations and the fluid gate

A sash drag follows the pointer from the render thread. A tab change slides the indicator and fades the page. The fluid gate: `sash-drag` and `tab-change` are under 8 ms.

## Acceptance

- The tests of this file pass.
- The checks of [the index](README.md#acceptance-for-each-task) pass, with the modern look, light and dark, and the web build from task 06 on.
- The widgets of the task show in the gallery shots.

## Out of scope

- None.
