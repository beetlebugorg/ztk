# Task 06: The web backend

## Goal

ztk runs in a browser. The browser is a backend: a canvas element, DOM input, and the scene drawn with the GPU API of the browser. The web item of Stage 3 moves here.

## Files

- `src/platform/web.zig`: the backend
- `src/render/webgl.zig` and `web/ztk.js`: the WebGL 2 renderer and the page code; `web/webgpu.js` when the browser has WebGPU
- `build.zig`: `zig build wasm` gives `zig-out/web/ztk.wasm` and the page files
- `web/index.html`: a page that runs a script from the page
- `tests/web.sh`: the browser test

## Steps

1. The core builds for `wasm32-freestanding` with no thread, no file, and no clock of the system. The page gives the time, the size, the scale, and the events through imports.
2. The frame clock is `requestAnimationFrame`. The frame drawing goes to a worker with an `OffscreenCanvas` when the browser has it, else it runs on the page.
3. The renderer draws the scene with the same quad form and the same formulas as the CPU renderer (WebGL 2). WebGPU is a second renderer when the browser has it.
4. Input: pointer events, wheel with `deltaMode` and momentum, keys, and a hidden input element for text and composition. The clipboard is the async clipboard.
5. `devicePixelRatio` is the scale. `prefers-color-scheme` and `prefers-reduced-motion` are read and followed when they change.
6. Accessibility: a parallel DOM tree with ARIA roles from the `role` of each class, and the bounds of each widget.
7. The page loads a Tcl script from a URL or from a text area.

## Tests

- `zig build wasm` compiles.
- `tests/web.sh` starts a headless browser, loads `web/index.html` with `examples/demo.tcl`, clicks a button, types in an entry, and compares the pixels with the CPU image of the same scene: at most 2 levels in each channel in 0.1 % of the pixels. Without a browser it prints `SKIP:` and the reason.

## Animations and the fluid gate

The transitions run from `requestAnimationFrame`. The fluid gate: the frame time in the browser for a hover transition of the demo is under 8 ms at the 99th percentile, measured with `performance.now` in the test.

## Acceptance

- The tests of this file pass.
- The checks of [the index](README.md#acceptance-for-each-task) pass, with the modern look, light and dark, and the web build from task 06 on.
- The widgets of the task show in the gallery shots.

## Out of scope

- The remote display of D22.
