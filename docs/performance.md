# Performance

The goal is a smooth frame at 60 frames per second or more. The plan sets a budget of 8 ms of CPU time for a frame at the 99th percentile in each bench case, and 4 ms for a frame with 1,000 widgets.

All numbers come from `zig build bench` with `ReleaseFast` on the development machine, an Intel Core i7-6700K, unless a row says otherwise. Other jobs shared the machine, so the times are higher than on a quiet machine. Run the cases yourself:

```sh
zig build bench -Doptimize=ReleaseFast
```

## Frame time

CPU milliseconds for one frame. Lower is faster.

| Case | Median | 99th percentile | Date |
|---|---|---|---|
| `frame-hover-1000`: the hover of one of 1,000 widgets | 0.66 | 0.85 | 2026-11-23 |
| `frame-text-1000`: a text change beside 1,000 widgets | 0.65 | 0.89 | 2026-11-23 |
| `anim-hover-1000`: a hover transition beside 1,000 widgets | 0.85 | 1.36 | 2026-11-24 |
| `ttk-hover-1000`: a `ttk::style map` hover on 1,000 `ttk` widgets | 0.87 | 1.04 | 2026-11-25 |
| `canvas-10000-scroll`: a canvas of 10,000 items scrolls | 1.05 | 1.52 | 2026-11-25 |
| `sheet-10000-scroll`: the spreadsheet with 10,000 rows scrolls | 0.75 | 5.20 | 2026-11-25 |
| `vector-10000-pan`: the vector tool with 10,000 shapes pans | 3.30 | 3.86 | 2026-11-25 |
| `scroll-wheel`: wheel steps on an entry beside 1,000 widgets | 5.08 | 7.23 | 2026-11-25 |
| `anim-1000`: 1,000 `ztk::animate` moves at once | 4.06 | 7.20 | 2026-11-24 |
| `type-entry`: one key in an entry | 0.028 | 0.036 | 2026-11-25 |
| `menu-open`: `tk_popup` of a menu of 20 entries beside 1,000 widgets, with the open move | 1.01 | 1.61 | 2026-11-25 |
| `sash-drag`: a drag of the sash of a `panedwindow` with 500 widgets in each pane, one motion for each frame | 0.88 | 1.00 | 2026-11-25 |
| `text-1mb-scroll`: a `text` widget with 1 MB of text (16,384 lines, `-wrap word`) scrolls by wheel steps from its middle | 0.42 | 0.54 | 2026-11-25 |
| `tab-change`: a notebook of 3 tabs with 300 labels on each page changes its tab each 10 frames, with the slide and the fade | 0.29 | 0.56 | 2026-11-25 |

## Start, memory, and idle

| Measure | Result |
|---|---|
| Start to the first frame, headless | 1.6 ms |
| Start to the first frame, Wayland | 3.0 ms |
| Private memory of the demo on Wayland | 11.2 MB |
| An idle window | No frame and no wake-up: 0 frames in 5,000 ms |

## The render thread

The script runs on one thread and makes a scene: a list of quads. A render thread draws the scene. The render thread also moves transitions, keyframes, switches, the slider of a scale, and the thumb of a scrollbar by its own clock. So these motions continue while the script is busy. A window with no change draws no frame.

## On the web

`ztk.wasm` is 3.0 MB, or 1.0 MB with gzip. It loads when the first live demo scrolls into view. In Node.js, a frame of the gallery at scale 2 had a median of 5.1 ms.

## Not measured yet

The frame rate on a real display, and the GPU path on a window. The Vulkan renderer works offscreen, and its window output is not written yet.
