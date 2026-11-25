# Task 21: The Stage 1 report

## Goal

One page states what Stage 1 built, with measured numbers, and what it did not build. The README has the real status. The plan gets new estimates from the time that the tasks needed.

## Files

- `docs/dev/stage1-report.md`
- `docs/dev/stage1-limits.md`: started in task 11; this task completes it
- `README.md`: the status section
- `docs/dev/plan.md`: section 11, only the estimates and a link to the report

## Steps

1. Run each command of this list on the development machine, under the memory cap, and copy the numbers. Give the date, the machine, the commit, and the versions of Zig and the Vulkan drivers.
   ```sh
   zig build test 2>&1 | tail -5
   zig build bench
   tools/oracle.sh tools/oracle-grid.tcl 1 200
   tools/oracle.sh tools/oracle-grid.tcl 2 200
   tests/demo.sh
   tests/wayland-smoke.sh
   ZTK_GPU=0 zig build test -Dtest-filter=vulkan
   ZTK_GPU=1 zig build test -Dtest-filter=vulkan
   ZTK_FRAME_STATS=1 zig-out/bin/ztk --headless --exit-after-frames 1 examples/demo.tcl
   ls -l zig-out/bin/ztk
   find src -name '*.zig' | xargs wc -l | tail -1
   ```
2. `docs/dev/stage1-report.md` has these sections:
   - **Result**: one paragraph. Does the demo run on Wayland with the Vulkan renderer, yes or no.
   - **Tests**: the count of tests that passed, failed, and skipped, and the reason for each skip.
   - **Oracle**: the count of layouts that are equal to `wish`, and each difference.
   - **Performance**: one table with each target of section 7 of the plan, the measured number, and "met" or "not met". Include the time to the first frame on Wayland and headless, the benchmark cases, the private memory of the demo (`Private_Dirty` of `/proc/<pid>/smaps_rollup`), the bytes for each label, and the growth of the interpreter arena.
   - **The frame rate**: the frame count and the late count of the manual runs of tasks 17 and 19.
   - **The direct backend**: the result of the manual check of task 20 for the Vulkan output and for the framebuffer output, or "not done" with the reason.
   - **Dependencies**: the output of `ldd` for the default build, and of `file` for the static build.
   - **What needs a person**: the manual checklist below, each item with "done", the date, and the result, or "not done".
   - **Blocked items**: each entry of `docs/dev/tasks/BLOCKED.md` with its state.
   - **Differences from the plan**: each place where the code differs from a task file, and why.
   - **Requests to ztcl**: the state of each request of section 10 of the plan, with what Stage 1 found.
   - **Time**: the working time of each task, as far as it is known, and the count of review rounds.
3. The manual checklist of Stage 1. A person does it. The implementer writes "not done" and does not guess:
   - The demo window on the Wayland session: the text is sharp, and the window has a title bar.
   - Typing in the entry with a real keyboard, with key repeat.
   - The hover and the press of each button with a real pointer.
   - A resize of the window by its edge is smooth.
   - The window on a monitor with a scale of 2, and with a fractional scale.
   - The dark scheme (`--dark`).
   - The close key of the title bar closes the program.
   - The demo on a device with no display server, with the Vulkan output and with the framebuffer output, and with a touch panel (task 20).
4. `docs/dev/stage1-limits.md` lists each thing of Tk that a Stage 1 widget or command does not have: the options that give `unknown option`, the subcommands that give "not supported in this stage", the missing event types, and the points where ztk differs from `wish` on purpose (`tk windowingsystem`, logical pixels).
5. The README status section: replace "plan only" with what works, in three to six sentences, with a link to the report and to the limits. Keep the Experimental notice and the AI disclaimer as they are.
6. In `docs/dev/plan.md`, section 11: add the measured size of Stage 1 (lines of Zig, count of tests, working time) beside its estimate. Change the estimates of the later stages only with a reason from the measurement, and state the reason.

## Tests

```sh
zig build test
grep -c 'not done' docs/dev/stage1-report.md
grep -n -i -E 'TODO|TBD|XXX' docs/dev/stage1-report.md docs/dev/stage1-limits.md README.md
```

The last command prints no line.

## Acceptance

- Each number in the report has the command that made it.
- Each target of section 7 of the plan is in the table, with "met" or "not met". No target is missing because its result was bad.
- A test that skipped is in the report as skipped.
- The report names no AI model and no vendor.
- The reviewer runs three of the commands of step 1 and gets numbers close to the report.

## Out of scope

- New code, except a fix that a command of step 1 needs to run.
- The task list of Stage 2. The planner writes it after the user reads the report.
