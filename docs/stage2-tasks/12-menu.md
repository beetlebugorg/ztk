# Task 12: `menu`, `menubutton`, `ttk::menubutton`, and `tk_popup`

## Goal

Menus work: a menu bar from `-menu`, pull-down menus with cascades, separators, check and radio entries, accelerators, and popup menus.

## Files

- `src/widgets/menu.zig`, `src/widgets/menubutton.zig`, `src/tests/menu.zig`

## Steps

1. Read `doc/menu.n`, `doc/menubutton.n`, `doc/ttk_menubutton.n`, and `doc/popup.n`.
2. `menu` with the five entry types (`command`, `cascade`, `checkbutton`, `radiobutton`, `separator`), `tearoff` (stored, no tear-off window), and the subcommands `activate`, `add`, `clone`, `delete`, `entrycget`, `entryconfigure`, `index`, `insert`, `invoke`, `post`, `postcascade`, `type`, `unpost`, `xposition`, and `yposition`.
3. A menu shows in a popover window with a round corner and a shadow. An entry has an icon (`-image`), a label, and the key hint of `-accelerator` at the right.
4. The menu bar of a toplevel (`-menu`) is drawn by ztk on Linux and the web.
5. `menubutton`, `ttk::menubutton`, and `tk_popup`. The keys: arrows, `Return`, `Escape`, `F10`, and the `-underline` letter with `Alt`.

## Tests

- `zig build test -Dtest-filter=menu`: entries of each type, `invoke` with the variables, cascades with the pointer and the keys, `post` and `unpost`, a popup, `<<MenuSelect>>`, and the messages of `wish`. `menu.test` counts go in the PR.

## Animations and the fluid gate

A menu opens with a fade and a short scale from its anchor, and closes with a fade. The active entry background moves. The fluid gate: `menu-open` shows in the next frame and is under 8 ms.

## Acceptance

- The tests of this file pass.
- The checks of [the index](README.md#acceptance-for-each-task) pass, with the modern look, light and dark, and the web build from task 06 on.
- The widgets of the task show in the gallery shots.

## Out of scope

- The native menu bar of macOS.
