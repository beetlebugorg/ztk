# Task 06c: the WebGPU renderer

## Goal

The web build draws with WebGPU when the browser gives an adapter, with WebGL 2 as the fallback and the CPU renderer into a 2D canvas as the last resort. The user asked for it on 2026-11-24. WebGPU is the GPU API of the browser, so it keeps the rule of section 4.12 of the plan: no translation layer between ztk and the platform.

## Files

- `web/webgpu.js`: the renderer, with WGSL shaders
- `web/ztk.js`: the choice of the renderer (`navigator.gpu`, then WebGL 2, then a 2D canvas), and the option `renderer: "webgpu" | "webgl2" | "cpu"` and the query parameter `?renderer=` that force one
- `src/web.zig`: an export that draws a frame with the CPU renderer into memory, for the last resort
- `tests/web.sh`: the three renderers on the same scenes

## Steps

1. The scene, the quad form, and the atlas are those of the other renderers. The quads go into a storage buffer or an instance buffer, and one render pass draws each frame.
2. The WGSL shaders have the formulas of `src/render/renderer.zig` and `quad.frag`: rounded boxes, borders, shadows, gradients, and the glyph atlas.
3. Device loss creates the device again and uploads the atlas again. A resize of the canvas and a change of `devicePixelRatio` configure the context again.
4. The canvas format is sRGB. Display P3 is used where the canvas supports it, with the colors of the scene converted.
5. The choice is automatic and is logged once.

## Tests

- `tests/web.sh` draws the gallery and the demo with WebGPU (headless Chromium with `--enable-unsafe-webgpu` and a software adapter when no GPU exists), with WebGL 2 (WebGPU off), and with the CPU renderer, and compares the three images: at most 2 levels in each channel in all but 0.5 % of the pixels.
- A test forces a device loss and checks the next frame.

## Animations and the fluid gate

The frame time and the CPU time of a frame with WebGPU and with WebGL 2, on the gallery and on the stress scenes of tasks 14 and 15 (10 000 canvas items, a large text widget), with the gate of 8 ms at the 99th percentile.

## Acceptance

- The tests of this file pass.
- The checks of [the index](README.md#acceptance-for-each-task) pass.

## Out of scope

- WebGPU on the native platforms. They use Vulkan, Metal, and Direct3D 12.
