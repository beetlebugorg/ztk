# Task 15: `text`

## Goal

The `text` widget works with tags, marks, embedded windows, undo, and scrolling.

## Files

- `src/text_widget/*.zig`: the buffer (a piece table or a rope), the indexes, the tags, the marks, the line layout with wrap, and the undo stack
- `src/tests/textw.zig`

## Steps

1. Read `doc/text.n`.
2. The index forms of `text.n` with the modifiers (`+ n chars`, `linestart`, `wordend`, and the others).
3. The subcommands: `bbox`, `compare`, `count`, `debug`, `delete`, `dlineinfo`, `dump`, `edit`, `get`, `image`, `index`, `insert`, `mark`, `peer` (a limit), `replace`, `scan`, `search`, `see`, `tag`, `window`, `xview`, and `yview`.
4. The tag options of `text.n` that change the look (colors, font, underline, overstrike, justify, margins, spacing, wrap, elide) and the tag bindings.
5. `-wrap none|char|word`, `-undo`, `-maxundo`, `-autoseparators`, and `<<Modified>>`.
6. The class bindings for the pointer and the keys, with the clipboard.

## Tests

- `zig build test -Dtest-filter=textw`: indexes, insert and delete with tags, marks with gravity, search with `-regexp`, undo and redo, embedded windows, `dump`, `count`, and the messages of `wish`. The `text*.test` counts go in the PR.

## Animations and the fluid gate

Smooth scroll and the caret blink on the render thread. The budget: 1 MB of text scrolls at the full rate, and a key in it shows in the next frame. The fluid gate: `text-1mb-scroll` and `text-1mb-type` are under 8 ms.

## Acceptance

- The tests of this file pass.
- The checks of [the index](README.md#acceptance-for-each-task) pass, with the modern look, light and dark, and the web build from task 06 on.
- The widgets of the task show in the gallery shots.

## Out of scope

- `peer` (a limit), bidi text (Stage 4).
