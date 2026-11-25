# Contributor docs

These files are the plan, the task lists, the reviews, and the reports of ztk. The docs site does not publish them. The user docs are in [docs/](../) and on https://beetlebug.org/ztk/.

| File | What it has |
|---|---|
| [plan.md](plan.md) | The goal, the architecture, the decisions, the performance targets, the verification strategy, and the stages. |
| [tasks/](tasks/README.md) | The 22 tasks of Stage 1, the first demo. |
| [stage1-report.md](stage1-report.md), [stage1-limits.md](stage1-limits.md) | The test counts, the reviews, the measures, and the limits of Stage 1. |
| [stage2-tasks/](stage2-tasks/README.md) | The tasks of the widget stage. |
| [stage2-limits.md](stage2-limits.md) | What each widget of the widget stage lacks, with the bench results. |
| [review.md](review.md) | The checklist of a reviewer. |
| [perf-review.md](perf-review.md) | A performance review: the slow paths, with a measure and a proposed change for each one. |
| [tk-size.md](tk-size.md) | The measured size of Tk. |
| [release.md](release.md), [npm.md](npm.md) | The release process and the npm package. |

The user page [Differences from Tk](../differences.md) has the short form of the limits.

## The status of Stage 1

Stage 1 is built. Four independent reviews said "do not merge" or "not yet". The fixes for the fourth review are in this code, and no review has checked them. Stage 1 has `frame`, `label`, `button`, `entry`, `grid`, `bind`, `event generate`, `focus`, `wm`, and `winfo` for `.`, a CSS subset with a modern theme, a font engine with no library, a CPU renderer, a Vulkan renderer (offscreen, checked against the CPU renderer on two GPUs), a render thread, and three backends: headless, Wayland (CPU renderer into shared memory), and direct (framebuffer and evdev). `examples/demo.tcl` runs in ztk and in `wish` 8.6.16. [The report](stage1-report.md) has the test counts.

What does not work: the Vulkan swapchain on a window and on a display, a window on the live desktop (not tried), the direct backend on a real device (not tried, and `--direct` needs the flag `--direct-unsafe-test-device`, because ztk does not own the VT), the other widgets and commands of Tk, and two rules of the `grid` solver (the oracle shows 11 differences in 600 random layouts). The tests run on Linux only. The headless program compiles for macOS and Windows, and no run on these systems has checked it. [The report](stage1-report.md) has the numbers, and [the limits](stage1-limits.md) list what each widget lacks.

- [The plan](plan.md) has the goal, the architecture, the decisions, the performance targets, the verification strategy, and the stages.
- [The Stage 1 tasks](tasks/README.md) are the 22 small tasks of the first demo.
- [The widget stage](stage2-tasks/README.md) adds every widget of Tk 8.6. Done so far: `pack`, `place`, animation (`transition`, `@keyframes`, `ztk::animate`), `checkbutton`, `radiobutton`, `toplevel`, `labelframe`, `message`, `grab`, `ztk::tooltip`, and `scale`. [The limits](stage2-limits.md) list what these lack.
- [The review checklist](review.md) is what a reviewer checks for each task.
- [The size of Tk](tk-size.md) has the measured size of the job.

Run it: `zig build`, then `zig-out/bin/ztk --headless examples/demo.tcl`, or `zig-out/bin/ztk examples/demo.tcl` in a Wayland session. On Linux the default build needs `glslc`, the Wayland client library, `wayland-protocols`, and `libxkbcommon`. On macOS and Windows the default build has the headless backend only.

## The goal of the plan

A script that runs in `wish` 8.6 runs in ztk with no change. The test files of Tk 8.6.16 measure that.

- The default look is a modern theme from a stylesheet, with one more stylesheet for each platform. A classic theme has the sizes and the colors of Tk.
- A GPU draws each frame. The target is 60 frames in each second.
- ztk runs on Linux, macOS, Windows, and the web. On a Linux device with no display server, it draws directly on the display.
- ztk needs no third-party library on any platform. It uses the interfaces of the platform, ztcl, and the Zig standard library.

## The size of the job

Measured on Tk 8.6.16 (2026-11-23):

| What | Count |
|---|---|
| Manual pages for script commands | 87 |
| Widget classes, classic and `ttk` | 18 and 18 |
| Options of these classes | 542 and 226 |
| Test files | 109 |
| Tests that a real `wish` counted | 10 221 |
| Source lines of Tk | 322 187 |

The plan estimates two and a quarter to three and a half years of work for one engineer, in nine stages after the plan. Stage 1 is the first demo: a Tcl script with `grid`, labels, buttons, and an entry in a styled window on Linux.

