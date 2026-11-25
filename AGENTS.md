# Agent instructions

ztk is an experimental Tk replacement in Zig, on the ztcl interpreter. The repository has the plan and the code of Stage 1.

Read these pages before you work:

1. [WRITING.md](WRITING.md), before you write code comments, commits, or PRs.
2. [docs/plan.md](docs/plan.md), the design and the decisions.
3. [docs/tasks/README.md](docs/tasks/README.md), the rules for a task, and then the file of your task.
4. [docs/review.md](docs/review.md), the checklist that the reviewer uses on your work.

## Commands

Use Zig 0.16.0. Run each build, test, benchmark, and suite command under a memory cap:

```sh
systemd-run --user --scope -q -p MemoryMax=4G -p MemorySwapMax=0 -- <command>
```

| Command | What it does |
|---|---|
| `tools/fetch-tk.sh [tag]` | Downloads a Tk release into the ignored folder `.tk-src/`. |
| `python3 -I tools/tk-count.py .tk-src/core-8-6-16` | Counts the manual pages and the tests of Tk. |
| `xvfb-run -a wish tools/tk-introspect.tcl` | Counts the commands and the options of a real `wish`. |
| `xvfb-run -a tools/tk-run.sh .tk-src/core-8-6-16 <work folder>` | Runs the tests of Tk on a real `wish`. |

| `zig build` | Builds `zig-out/bin/ztk`. |
| `zig build test` | Runs all unit tests. `-Dtest-filter=<text>` runs the tests with that text in the name. |
| `zig build run -- file.tcl` | Runs a script. |
| `tools/oracle.sh script.tcl args` | Runs a script in `wish` and in `ztk --headless`, and prints the difference. |
| `tools/oracle.sh tools/oracle-pack.tcl seed count` | Compares random `pack` layouts with `wish`. `oracle-place.tcl` does the same for `place`. |
| `zig-out/bin/ztk [flags] script.tcl` | Runs a script. See `ztk --version` and the flags in `docs/tasks/17-wayland.md`. |
| `tests/wayland-smoke.sh` | Runs `ztk` on a private headless compositor. |
| `tools/shots.sh [folder]` | Draws the screenshots of the examples into `docs/site/shots`, in light and dark at scale 2. |
| `zig build wasm` | Builds the browser files into `zig-out/web`: `ztk.wasm`, `ztk.js`, the playground `index.html`, and the examples. |
| `tests/web.sh` | Runs the demo and the gallery in a headless Chromium: DOM input, the accessible roles, WebGPU, WebGL 2, and the CPU renderer in a 2D canvas against the native CPU renderer, a display-p3 canvas, a WebGPU device loss, the CPU time of a frame with WebGPU and with WebGL 2, and the frame time in V8. It needs `node`. |
| `tests/site.sh` | Builds the site with the web build, makes each card of the landing page go live in a headless Chromium, compares its first frame with its poster in light and dark, and sends a click, text, and a toggle. It then checks the size and the aspect ratio of each canvas of the playground and the landing page at three page sizes and the pixel ratios 1, 2, and 3. That check needs `node`. Set `PYTHON` to a Python with `markdown-it-py` and `Pillow`. |
| `tests/shots.sh` | Checks that the files in `docs/site/shots` equal new shots, and runs each example in `wish`. |

Each later task adds its commands to this table.

## Rules

1. Do one task at a time, in the order of the task index. Do what the task file says and stop at its "Out of scope" list.
2. Run `zig build test` before each commit. The tests must pass.
3. Add no dependency that section 6 of the plan does not list. ztk needs only the interfaces of the platform, ztcl, and the Zig standard library. The core, the text code, the headless backend, and the direct backend link no library.
4. Copy no code from Tk, and no code from a project with a GPL, LGPL, or AGPL license. zslice and Printdeck have the AGPL: do not open their source for a ztk task. Follow the manual pages of Tk and the behavior of `wish` 8.6.16. Credit each source in `docs/references/`.
5. The ztk library turns on no capability of ztcl and reaches the host only through its backend. Only the `ztk` program turns on a capability, from a flag.
6. ztk keeps its state in its own allocator. It keeps no value of the ztcl arena after a command returns.
7. Each number in a doc is measured. Give the command, the date, and the machine. A test that did not run is skipped or blocked. It is not a pass.
8. Do not change a golden file to make a test pass.
9. Start each source file with a `//!` comment that explains its algorithm, and an SPDX line for BSD-2-Clause.
10. Do not name an AI model or an AI vendor in a file or in a commit message.
11. Keep local paths and private data out of the repository.
12. Stop only your own processes, by PID. Do not open a window on the live desktop session, and do not create a display surface with the direct backend on the development machine, unless a task says so.
13. Do not change the ztcl repository. A request to ztcl goes in the report of your task.

## Commits and merges

- Follow the commit rules in WRITING.md.
- Add no attribution lines, co-author lines, or session links.
- Do not push, add a remote, or make a tag, unless the user asks.
- Merge by rebase only. Keep merge commits out of PR branches.
