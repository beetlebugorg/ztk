# Task 02: Animation: transitions, keyframes, `ztk::animate`, and the frame clock

## Goal

Animation is part of the API (the rules in [the index](README.md#animation)). The CSS transitions of Stage 1 get the full syntax, `@keyframes` and `animation` exist, `ztk::animate` moves widget options, and the render thread moves the paint values from the frame clock.

## Files

- `src/anim.zig`: the timing functions, the interpolation, the keyframes, and the list of running animations
- `src/css/parse.zig`, `src/style.zig`: `transition`, `transition-*`, `@keyframes`, `animation`, `animation-*`
- `src/render/thread.zig`: the animation table of a frame and its interpolation on the render thread
- `src/platform/headless.zig`, `src/main.zig`: the fixed clock, `--time ms`, `ztk::clock`
- `src/tests/anim2.zig`

## Steps

1. Read the CSS Transitions and CSS Animations specifications and the CSS Easing specification. Credit them in `docs/references/css.md`.
2. `transition` has the property list, the duration, the timing function, and the delay, with each long form. Several transitions in one value apply to their own properties.
3. The timing functions: `linear`, `ease`, `ease-in`, `ease-out`, `ease-in-out`, `cubic-bezier(x1, y1, x2, y2)`, `steps(n, jump-start|jump-end|jump-none|jump-both|start|end)`, and `spring(stiffness damping mass)`. A spring has no fixed duration. It ends when the motion is under half a device pixel.
4. `@keyframes name { from {...} 50% {...} to {...} }` and `animation` with the name, the duration, the timing function, the delay, the count (`infinite`), the direction, and the fill mode. A keyframe rule has only the properties that move.
5. The properties that move: the colors, `opacity`, `border-radius`, `box-shadow`, `outline`, `padding`, `min-width`, and `min-height`. A move of the padding or of a minimum size runs a layout at each frame on the UI thread. The others move on the render thread.
6. A frame has an animation table: for each animated value, the quad range, the start and end values, the start time, and the timing. The render thread computes the values for the time of the frame that it draws. The UI thread is not needed for a frame that only moves paint values.
7. `ztk::animate target ?-option value ...? -duration ms ?-easing name? ?-delay ms? ?-repeat n? ?-command script?`. The target is a widget path. A canvas item target comes in task 14. The options are the widget options of type color, pixels, and double. The command gives an id `anim#N`. `ztk::animate cancel id` keeps the shown value, `pause id` and `resume id` stop and continue the clock of that animation, and `info ?id?` lists the ids or gives the state of one. `-command` runs at the global level after the last frame. A new animation of the same option of the same target replaces the old one and starts from the shown value.
8. Reduced motion: `ZTK_NO_ANIMATION=1`, the setting of the backend (`prefers-reduced-motion` on the web), and `ztk::animate reduce ?bool?` give the end value at once. A `-command` still runs, after the next frame.
9. Determinism: the headless backend has a fixed clock. `ztk --time ms` draws the frame at that time. `ztk::clock set ms` and `ztk::clock get` work on the headless backend only, and give the error `ztk::clock set needs the headless backend` on another backend.

## Tests

- `zig build test -Dtest-filter=anim2`: each timing function at 0, 0.25, 0.5, 0.75, and 1 against values computed by hand from the specification; the spring at fixed times; `steps` at each jump; interpolation of colors in sRGB, of shadows, and of radii.
- A transition on hover: the frame at the middle time has the middle color. A leave during the move starts from the shown color.
- `@keyframes` with three stops, `infinite`, and `alternate`: the values at six times.
- `ztk::animate .l -background red -duration 200`: `cancel`, `pause`, `resume`, `info`, a replace during the move, and `-command` that runs one time.
- Reduced motion: each case gives the end state in the next frame.
- A script in a busy loop for 500 ms of the fixed clock: the render thread draws the frames of a running transition with the correct values (the render thread test of task 17b with an animation).
- The fluid gate: `anim-hover-1000` (a hover transition on one of 1 000 widgets) and `anim-1000` (1 000 running `ztk::animate` moves) are under 8 ms at the 99th percentile.

## Animations and the fluid gate

This task is the engine. The demo of `examples/` gets a button hover and a `ztk::animate` color move in `tests/shots.sh` at a fixed `--time`.

## Acceptance

- The tests of this file pass.
- The checks of [the index](README.md#acceptance-for-each-task) pass, with the modern look, light and dark, and the web build from task 06 on.
- The widgets of the task show in the gallery shots.

## Out of scope

- Animations of canvas items (task 14), smooth scroll (task 07), and the widget animations of the later tasks.
