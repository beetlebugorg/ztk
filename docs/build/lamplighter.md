# Lamplighter: the design

Lamplighter is a platform game in [one Tcl script](https://github.com/beetlebugorg/ztk/blob/main/docs/toys/lamplighter.tcl). Night falls on a hill town, and you carry the last flame. [Play it on the Toys page](../toys.md).

## The widget

Each level is a walk through 2 or 3 streets, and each street is a tab of a `ttk::notebook`. A tab opens (`.nb tab N -state normal`) when you walk off the right edge of the street before it. The text of each tab has a dot for each lamp, and a lit lamp fills its dot. A click on a tab that you saw takes you back to the start of that street, through `<<NotebookTabChanged>>`. A stylesheet gives the notebook the colors of the night.

## The goal and the pressure

- Touch each lamp to light it. The gate at the end of the last street opens when each lamp of the level is lit.
- The night comes in about 100 seconds: the sky goes from dusk to night, and the bar at the top right empties. Each lit lamp pushes the night back by a fifth.
- A fall into the water or a gap costs a little light and puts you at the start of the street.

## The levels

The first level teaches by its layout, with no text: a lamp at walking height on flat ground, then a step and a lamp on a roof. Each later level adds one idea:

| Level | Streets | The new idea |
|---|---|---|
| Lantern Lane | 2 | Walk, jump, touch a lamp. |
| Mill Steps | 3 | Ledges that you jump up through, and a spring. |
| The Ford | 3 | Boats that swing over the water and carry you. |
| Bell Tower | 3 | Boards that break 40 frames after you step on them and come back. |
| Hilltop | 3 | All of them, and a lamp that you light in the air. |

## The feel

- The run speeds up and slows down (0.45 pixels per frame on the ground, 0.28 in the air), so a turn has weight.
- Coyote time: a jump works for 6 frames after you leave an edge.
- The jump buffer: a press up to 7 frames before you land jumps at the landing.
- The jump is higher while you hold the button, and a release cuts it short.
- The hero squashes on a hard landing and stretches on a jump. Dust comes up at a landing, and embers rise from the flame.
- A lamp freezes the game for 4 frames and shakes the screen a little. "Shake off" under the frame turns the shake off.

## The art and the sound

The palette has two sets of colors, dusk and night, and the dark of the level mixes them: 20 bands of the sky, two lines of hills, the roofs, and the stars that come out. A lit lamp has six rings of glow, each one a mix of the gold of the lamp into the sky behind it. The sound effects and the music (a slow bell theme in A minor on the title, a walking theme in the level) are made at run time by `assets/toysound.js`.

## The checks

- A replay drives the game with `toy_input` calls at fixed frames and calls `step` and `draw` itself, so a run is the same each time. Lantern Lane ends in the state `clear` after 513 frames (8.6 s) with one jump, and the save string has the new best time.
- A second check puts the hero on the highest floor under each of the 23 lamps of the five levels, runs a held jump with the physics of the game, and reads the lamp: each one lights. A held jump rises about 66 pixels, and the floors of a level are at most 36 pixels apart, except where a spring or a boat is the way up.
- The screenshots of the title and of the second street were checked by eye.
- The script of one step and one frame takes about 4.5 ms on a loaded 8-core Linux host in the native build. The browser runs the same script in WebAssembly.
