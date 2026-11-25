# Limits of the widget stage

This page lists what a command or a widget of the [widget stage](stage2-tasks/README.md) does not have, or does in another way than `wish` 8.6.16. Each task adds its entries. The section "Additions" lists the options and commands that ztk has and Tk does not have.

## pack and place (task 01)

- `pack` and `place` have all subcommands and options of `pack.n` and `place.n`. `tools/oracle.sh tools/oracle-pack.tcl <seed> 200` gave no difference for the seeds 1, 2, 3, 4, 5, and 99, and `tools/oracle-place.tcl` gave no difference for the seeds 1 to 4 (2026-11-24).
- A distance with a unit (`1c`) uses the `tk scaling` of ztk (96/72 logical pixels in a point). `wish` under `Xvfb` has another scaling, so `place .a -x 1c` gives 38 in ztk and 39 in that `wish`.
- `pack propagate . 0` keeps the requested size of `.` that ztk measures. `wish` gives a toplevel with no content the requested size 200 by 200, so `winfo reqwidth .` differs.
- `-in` takes a container in the same toplevel only, because ztk has one toplevel until task 04.

## Additions

None yet.
