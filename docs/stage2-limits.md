# Limits of the widget stage

This page lists what a command or a widget of the [widget stage](stage2-tasks/README.md) does not have, or does in another way than `wish` 8.6.16. Each task adds its entries. The section "Additions" lists the options and commands that ztk has and Tk does not have.

## pack and place (task 01)

- `pack` and `place` have all subcommands and options of `pack.n` and `place.n`. `tools/oracle.sh tools/oracle-pack.tcl <seed> 200` gave no difference for the seeds 1, 2, 3, 4, 5, and 99, and `tools/oracle-place.tcl` gave no difference for the seeds 1 to 4 (2026-11-24).
- A distance with a unit (`1c`) uses the `tk scaling` of ztk (96/72 logical pixels in a point). `wish` under `Xvfb` has another scaling, so `place .a -x 1c` gives 38 in ztk and 39 in that `wish`.
- `pack propagate . 0` keeps the requested size of `.` that ztk measures. `wish` gives a toplevel with no content the requested size 200 by 200, so `winfo reqwidth .` differs.
- `-in` takes a container in the same toplevel only, because ztk has one toplevel until task 04.

## Animation (task 02)

- The render thread moves a transition of the paint: the colors, the opacity, the radii, the shadow, and the outline. The UI thread paints the widget at the start and at the end of the transition, and the render thread draws the quads between them for its own time. When the two paints have a different count of quads (for example an outline that appears), the UI thread moves the transition, as in Stage 1.
- The render thread moves all quads of one widget with one timing: the property of the transition with the longest time. The UI thread uses the timing of each property. The two differ only when one transition gives two properties a different timing.
- A keyframe animation, a move of the padding or a minimum size, and `ztk::animate` run on the UI thread. A script that is busy stops them until it returns.
- `ztk::animate` moves options of the types color, screen distance, and integer, and options whose value is a number. A canvas item as the target comes with the canvas (task 14).
- A spring has its own duration: the time after which it stays within 0.001 of its end. The duration of the declaration is not used for a spring.
- `ztk --time MS` draws the first frame at the time 0 and the frames after it at MS. Only the headless backend has it.
- The backends have no reduced motion setting yet. `ZTK_NO_ANIMATION=1` and `ztk::animate reduce 1` give the end states.
- `zig build bench`, ReleaseFast, 2026-11-24, development machine with a load average of 8 to 9: `anim-hover-1000` median 0.85 ms and 99th percentile 1.36 ms; `anim-1000` (1 000 option animations at once) median 4.06 ms and 99th percentile 7.20 ms. Both are under the gate of 8 ms. `anim-1000` is near it, because each step of an option animation goes through `configure`.

## Additions

- `ztk::animate`, `ztk::clock`, the timing function `spring()`, and the flag `--time` of the `ztk` program.
