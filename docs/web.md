# On the web

ztk runs the same Tk scripts in a browser. Each example on the [landing page](https://beetlebug.org/ztk/) runs live, and the [playground](https://beetlebug.org/ztk/play/index.html) lets you edit a script.

`zig build wasm` builds ztk for the browser into `zig-out/web`. The build has `ztk.wasm`, the page module `ztk.js`, the playground `index.html`, and the examples. `ztk.wasm` has the interpreter (ztcl), the widgets, the layout, the style sheets, the Inter font, and the CPU renderer. `ztk.js` gives the module the clock, the size, the scale, the color scheme, and the input, and draws each frame with WebGPU (`webgpu.js`), WebGL 2, or the CPU renderer.

## Install from npm

The package [`@beetlebug/ztk`](https://www.npmjs.com/package/@beetlebug/ztk) has `ztk.wasm`, `ztk.js`, and the TypeScript types. It works with a bundler, in a plain page from a CDN, and with Vite.

```sh
npm install @beetlebug/ztk
```

```js
import * as ztk from "@beetlebug/ztk";

const app = await ztk.mount(document.getElementById("app"), {
  script: "button .b -text Hello -command {set clicked 1}; pack .b -padx 8 -pady 8",
  theme: "auto",
  size: "fill",
});
app.eval(".b configure -text Bye");
app.destroy();
```

With no build step, import `https://cdn.jsdelivr.net/npm/@beetlebug/ztk@VERSION/ztk.js`. The module loads `ztk.wasm` from its own folder. With the Vite dev server, add `optimizeDeps: { exclude: ["@beetlebug/ztk"] }` to `vite.config.js`, so that `ztk.wasm` stays next to `ztk.js`.

## mount

`mount(el, options)` adds a canvas to `el` (or uses `el` when it is a canvas), runs the script, draws the first frame, and returns the app. A script error destroys the app and rejects with the error text.

| Option | Use |
|---|---|
| `script` | Tcl text with Tk commands. |
| `files` | Files by name for `ztk::style load`. |
| `theme` | `"auto"` (the color scheme of the page), `"light"`, or `"dark"`. |
| `size` | `"auto"`: the size of the element at the start, and then the size that the toplevel computes. `"fill"`: the window follows the size of the element through a `ResizeObserver`. `[width, height]`: a fixed logical size. |
| `renderer` | `"auto"`, `"webgl2"`, `"cpu"`, or `"webgpu"`. `"auto"` selects WebGPU when the browser gives an adapter, else WebGL 2, else the CPU renderer. With `"auto"`, a blank first WebGPU frame, a GPU error, or a lost device with no new device makes the app render with WebGL 2 on a new canvas in the place of the old one. Read `app.canvas` again after the first frame. A forced renderer that the browser does not have rejects. |
| `scale` | The device pixels in one logical pixel. The default is `devicePixelRatio`. |
| `module`, `wasm` | A compiled module, or the URL of `ztk.wasm`. |
| `log` | Gets the text of `puts` and the error messages. |

The app has `eval(script)`, `addFile(name, text)`, `resize(width, height)`, `setTheme(theme)`, `destroy()`, `frame(ms)`, `canvas`, `renderer`, and `tree` (the hidden elements with ARIA roles). `destroy` stops the frame loop, removes the event listeners and the elements of the app, and frees the renderer.

`start(canvas, options)` is the API under `mount`. The playground and the landing page use it.

## HiDPI and the color scheme

The backing store of the canvas is the scene in device pixels, and the CSS size of the canvas is the scene in CSS pixels. A change of `devicePixelRatio` gives the module a new scale, and the next frame is sharp at that scale. With `theme: "auto"`, a change of `prefers-color-scheme` changes the scheme of the app. A change of `prefers-reduced-motion` turns the animations off or on.

## The renderers

| Renderer | How it draws |
|---|---|
| `webgpu` | WGSL shaders with the formulas of the CPU renderer. The canvas is `display-p3` on a wide-gamut screen. After a device loss, the renderer makes its pipeline again. |
| `webgl2` | One instanced draw of the quads of the scene. The shaders have the formulas of the CPU renderer. |
| `cpu` | `ztk.wasm` draws each frame to an RGBA image with `src/render/cpu.zig` (`ztk_cpu`, `ztk_image`), and a 2D context shows the image. |

`tests/web.sh` compares the WebGPU, WebGL 2, and 2D canvas images with the CPU image of the same script.

## The size of the build

`ztk.wasm` builds in ReleaseFast: 3.0 MB, or 1.0 MB with `gzip -9`. A ReleaseSmall build is 2.2 MB, or 0.82 MB with gzip. In Node.js, the median time of a frame of the gallery at scale 2 was 5.1 ms with ReleaseFast and 6.6 ms with ReleaseSmall. The build stays in ReleaseFast for the frame time.

## Build it yourself

```sh
zig build wasm
python3 -m http.server --bind 127.0.0.1 --directory zig-out/web 8000
```

Then open `http://127.0.0.1:8000/index.html`.
