# Skate Pond: the design

Skate Pond is a sliding puzzle in [one Tcl script](https://github.com/beetlebugorg/ztk/blob/main/docs/toys/skatepond.tcl). A push sends the skater over the ice until something stops it. [Play it on the Toys page](../toys.md).

## The widget

The `listbox` on the right is the bag. A plank or a pick on the ice goes into the bag when you slide over it: `insert`, `itemconfigure -foreground` for the color of the item, `selection set`, and `see`. A click selects another item, and `<<ListboxSelect>>` changes the hint under the bag. A uses the selected item, and `delete` takes it out of the bag.

## The rules

- A push slides the skater until a snowbank or a rock stops it. A patch of snow stops the skater on it. Open water ends the move, and the run goes back one move.
- A plank goes on the open water in front of you and makes a bridge. A pick breaks the rock in front of you.
- B takes back a move, as many times as you want. Enter starts the level again.
- Each level has three stars: one for the flag, one for the flag within par, and one for each snowflake on the way.

## The levels

Seven levels, in the order of their ideas:

| Level | Par | The new idea |
|---|---|---|
| First Ice | 2 | A push slides to the wall. |
| Snow Stops | 2 | A patch of snow stops you in the middle. |
| Thin Spot | 3 | Open water, and a snowflake off the short way. |
| A Plank | 6 | Pick up a plank, face the water, and lay it. |
| The Pick | 6 | A row of rocks, and the pick that breaks one. |
| Crossing | 5 | A rock as a stop, then a plank. |
| Long Night | 7 | A long way around with a plank. |

A solver (a breadth-first search over the place, the facing, the tiles, the bag, and the snowflakes) checked that each level has a way to the flag, and gave the par and the moves for each snowflake. The par of each level is the shortest way.

## The feel

- A slide is a tween with an ease-out: a long slide is fast and settles at the end, from 7 to 26 frames.
- A push during a slide waits for its end (the input buffer), so quick players do not lose a move.
- The skater leans into a slide, the scarf trails behind, and ice spray comes off the skates. A stop at a wall squashes the skater and shakes the screen a little; a stop on snow puffs.

## The art and the sound

A cold palette: two shades of ice in a checker, cracks, snowbanks with a shadow, rocks, and dark water. The stars are canvas polygons, so they do not depend on the glyphs of a font. The music is a light theme in G major, made at run time with the effects.

## The checks

Each level was played in a headless run with the moves of the solver as recorded inputs. The run of "A Plank" ends in the state `clear` with 6 moves, and the save string keeps the stars.
