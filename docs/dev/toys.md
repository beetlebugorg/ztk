# Toys of the widget pages (issue 175)

This file is the state of the toys and the rules for the next ones. It is not on the site.

## Rules (user, 2026-11-26)

1. A real game: a clear goal, a challenge that ramps, a way to win and to lose, a score or a timer, and rounds of 30 seconds to 2 minutes.
2. The widget of the page is the core control or the core display of the game, used the way that the widget is meant to be used. The game cannot be played without it.
3. Play on the page (toys.js) stays only where it fits the game.
4. Original names, sprites, and rules. The handheld frame, sound off by default, no start without a key or a click, pause off the screen, reduced motion respected.

## State

| Toy | Page | Widget | Meets the rules |
|---|---|---|---|
| Backspin | range | `scale` is the paddle, match to 7 | Yes (#194) |
| Moth Lamp | toggles, landing | `checkbutton` flippers and lamps | Yes (#196) |
| Tin Moon | ttk | `ttk::scale` throttle, `ttk::progressbar` fuel | Yes (#194) |
| Cellar Door | entry | `entry` prompt with history and Tab completion | Yes (#189, #197) |
| Puffshot | menus | menu bar and `tk_popup` run a shooter | Yes. Next: a Sound entry and a Difficulty cascade. |
| Lamplighter | panes | `ttk::notebook` tabs are scenes | Yes: 60 s and 3 lives (#214) |
| Twin Lanes | panes | `panedwindow` sash sets the road widths | Yes |
| Pixel Pad | text | `text` holds the rule of the paddle; `<<Modified>>` makes the proc again; stars and bombs, 4 levels in 90 s | Yes (#213) |
| Skate Pond | listbox | `listbox` with `-selectmode multiple` is the bag of an ice puzzle: rock, plank, and rope with a plank as a bridge; 5 ponds in 90 s | Yes (#203) |

## The Toys page (user, 2026-11-26)

The Toys page is one handheld and the code (#204): a game list in a listbox, a pick runs the game and puts its code in the editor, Menu or Escape goes back, and `?game=SLUG` keeps the game. A new toy needs a heading `### Play: NAME` before its marker on its widget page, and a row in the list of `docs/toys.md` (its name without `toy-`, its title, and its widget). The list has 8 rows that fit in 240 pixels: a ninth game needs a smaller font or a scroll.

Since then (2026-11-26): the keys of each handheld on a click, P to pause, and one molded shell (#207); the Inspect panel in view (#208); a page-wide fallback from a blank WebGPU to WebGL 2 (#206, #209). #211 put the code of the Toys page under the handheld (80 columns fit), mapped A and D to Left and Right (the key line shows W A S D), and kept the keys with a game that starts from the list.

## Next, in order

2. treeview (tree page): a pretend disk; open folders, find the files, follow the clues.
3. buttons (basic page): a rhythm or reaction game with the buttons as pads, with the active state as feedback.
4. spinbox or combobox (entry page): dial in a code to open a safe.
5. canvas page: the playfield itself.

6. Puffshot: a Sound entry and a Difficulty cascade. Twin Lanes: check the rules again.

Each toy is one PR: write the code, run it in `ztk --headless`, check that each level can be won (a breadth-first search, as for Skate Pond), write the shots for its snippet (the awk of `tools/shots.sh` for one name), run `tests/docs-live.sh widgets/PAGE`, check it in a headless Chromium, add its row to the game list of docs/toys.md, merge, and check the deployed page. Use a git worktree for each branch, so that a test run keeps its files.

The check of Pixel Pad plays seeds 1 to 8 in `ztk --headless` with three rules: the default sweep, `set x $sx`, and that rule with a move away from a low bomb (8 wins of 8).
