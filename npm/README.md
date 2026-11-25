# {{name}}

ztk is a replacement for Tk, written in Zig, on the Tcl interpreter ztcl. This package runs ztk in a browser. A Tcl script with Tk commands makes the widgets, and ztk draws them on a canvas with WebGL 2, or with its CPU renderer.

- `ztk.wasm` has the interpreter, the widgets, the layout, the style sheets, the fonts (Inter), and the CPU renderer. It is 3.0 MB, or 1.0 MB with gzip.
- The page side handles the input, the input methods (IME), the HiDPI scale, the color scheme, and ARIA roles for the widgets.
- It has types for TypeScript.

The docs are at [beetlebug.org/ztk](https://beetlebug.org/ztk/web/). The source is at [github.com/beetlebugorg/ztk](https://github.com/beetlebugorg/ztk).

## Install

```sh
npm install {{name}}
```

## Mount an app

```js
import * as ztk from "{{name}}";

const app = await ztk.mount(document.getElementById("app"), {
  script: `
    button .b -text Hello -command {set clicked 1}
    label .l -text World
    pack .b .l -padx 8 -pady 8
  `,
  theme: "dark",
});
app.eval("winfo children ."); // { ok: true, result: ".b .l" }
app.destroy();
```

`mount` adds a canvas to the element, runs the script, and draws the first frame. A script error rejects the promise with the error text, and the element is empty again.

## In a page with no build step

```html
<div id="app" style="width: 480px; height: 320px"></div>
<script type="module">
import * as ztk from "https://cdn.jsdelivr.net/npm/{{name}}@{{version}}/ztk.js";

const app = await ztk.mount(document.getElementById("app"), {
  script: "button .b -text Hello; pack .b -padx 8 -pady 8",
});
</script>
```

The module loads `ztk.wasm` from its own folder on the CDN. The jsDelivr form `https://cdn.jsdelivr.net/npm/{{name}}/+esm` resolves `ztk.wasm` in the same folder, but no test runs it.

## With a bundler

The import is the same as above. The module finds `ztk.wasm` with `new URL("./ztk.wasm", import.meta.url)`, and `vite build` copies the file. For the Vite dev server, keep the package out of the dependency step, so the two files stay together:

```js
// vite.config.js
export default { optimizeDeps: { exclude: ["{{name}}"] } };
```

The tests of the package run Vite 7. Webpack 5 and Rollup also have support for the `new URL` form, but no test runs them. With another tool, copy `ztk.wasm` to your site and give its URL as the option `wasm`.

## Options of mount

| Option | Use |
|---|---|
| `script` | Tcl text with Tk commands. It runs after `files`. |
| `files` | Files by name for `ztk::style load`, for example `{ "app.css": text }`. |
| `theme` | `"auto"` (the default) follows `prefers-color-scheme` of the page. `"light"` and `"dark"` set the scheme. |
| `size` | `"auto"` (the default): the window starts with the size of the element and then gets the size of its widgets, as a Tk toplevel does. `"fill"`: the window follows the size of the element, so give the element a size. `[width, height]`: a fixed logical size, which the canvas shows at the CSS size that the page gives it. |
| `renderer` | `"auto"` (the default), `"webgl2"`, `"cpu"`, or `"webgpu"`. `"auto"` selects WebGL 2, and the CPU renderer when the browser has no WebGL 2. This version has no WebGPU renderer, so `"webgpu"` rejects. |
| `scale` | The device pixels in one logical pixel. The default is `devicePixelRatio`, and a change of it gives a new scale. |
| `module` | A module from `compileModule()`, so that many apps on one page compile `ztk.wasm` one time. |
| `wasm` | The URL of `ztk.wasm`. The default is the file next to `ztk.js`. |
| `log` | Gets the text of `puts` and the error messages. The default is `console.log`. |

## The app

| Member | Use |
|---|---|
| `app.eval(script)` | Runs Tcl text. Returns `{ ok, result }`. The next frame shows the change. |
| `app.addFile(name, text)` | Adds a file for `ztk::style load`. |
| `app.resize(width, height)` | Gives the window a new logical size. |
| `app.setTheme(theme)` | `"auto"`, `"light"`, or `"dark"`. |
| `app.destroy()` | Stops the frame loop, removes the listeners and the elements of the app, and frees the renderer. |
| `app.canvas`, `app.renderer`, `app.tree` | The canvas, the renderer in use, and the hidden elements with ARIA roles. |

Each app has its own WebAssembly instance. Input goes to the canvas, and a hidden text area holds the keyboard focus, so text input and input methods work.

## Limits

- ztk is new. It has a subset of the widgets and commands of Tk. The [status](https://github.com/beetlebugorg/ztk#status) lists what works.
- ztk runs in a browser. In Node.js, the module loads and `compileModule` works, but `mount` needs a DOM.
- The script runs on the main thread of the page.

## The interpreter

`ztk.wasm` has its own copy of ztcl, the Tcl interpreter. It does not use the ztcl npm package. The Tk commands are in the same interpreter as the script, so one module has both.

## License

BSD-2-Clause. `ztk.wasm` contains ztcl, the Zig standard library (with ports of code from musl, Go, and ARM optimized-routines), and the Inter font (SIL Open Font License 1.1). See `NOTICE` and the `licenses` folder.
