// SPDX-License-Identifier: BSD-2-Clause
// The page side of ztk in a browser. It loads ztk.wasm, gives it the
// clock, the size, the scale (devicePixelRatio), the color scheme, the
// reduced motion setting, and the input of the canvas, and draws each
// scene with WebGPU (web/webgpu.js), WebGL 2, or the CPU renderer of
// ztk.wasm and a 2D context. mount() is the API for a page, and start()
// is the API under it. The query parameter `?renderer=` with "webgpu",
// "webgl2", or "cpu" forces a renderer, as the option does. The shaders have the formulas of the CPU renderer
// (src/render/renderer.zig) and of src/render/shaders/quad.frag. A
// hidden text area gets the keyboard, so that text input and input
// methods work. A list of hidden elements with ARIA roles follows the
// widgets, from ztk_a11y.

import { createWebGPU } from "./webgpu.js";

const VS = `#version 300 es
layout(location=0) in vec4 a_rect;
layout(location=1) in vec4 a_clip;
layout(location=2) in vec4 a_radii;
layout(location=3) in vec4 a_border;
layout(location=4) in vec4 a_fill;
layout(location=5) in vec4 a_fill2;
layout(location=6) in vec4 a_border_color;
layout(location=7) in vec4 a_uv;
layout(location=8) in vec4 a_params;
layout(location=9) in uint a_kind;
uniform vec2 u_target;
flat out vec4 f_rect; flat out vec4 f_clip; flat out vec4 f_radii; flat out vec4 f_border;
flat out vec4 f_fill; flat out vec4 f_fill2; flat out vec4 f_border_color; flat out vec4 f_uv;
flat out vec4 f_params; flat out uint f_kind;
void main() {
  float pad = 0.0;
  if (a_kind == 0u) pad = 1.0;
  if (a_kind == 1u) pad = max(a_params.z, 1.0) + 1.0;
  vec2 lo = max(a_rect.xy - pad, a_clip.xy);
  vec2 hi = min(a_rect.xy + a_rect.zw + pad, a_clip.xy + a_clip.zw);
  hi = max(hi, lo);
  vec2 corner = vec2(float(gl_VertexID & 1), float(gl_VertexID >> 1));
  vec2 pos = mix(lo, hi, corner);
  vec2 ndc = pos / u_target * 2.0 - 1.0;
  gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);
  f_rect = a_rect; f_clip = a_clip; f_radii = a_radii; f_border = a_border; f_fill = a_fill;
  f_fill2 = a_fill2; f_border_color = a_border_color; f_uv = a_uv; f_params = a_params; f_kind = a_kind;
}`;

const FS = `#version 300 es
precision highp float;
flat in vec4 f_rect; flat in vec4 f_clip; flat in vec4 f_radii; flat in vec4 f_border;
flat in vec4 f_fill; flat in vec4 f_fill2; flat in vec4 f_border_color; flat in vec4 f_uv;
flat in vec4 f_params; flat in uint f_kind;
uniform vec2 u_target;
uniform sampler2D u_atlas;
uniform sampler2D u_images;
out vec4 out_color;
float clamp01(float x) { return clamp(x, 0.0, 1.0); }
float roundedDistance(vec2 p, vec4 rect, vec4 radii) {
  float hw = rect.z * 0.5; float hh = rect.w * 0.5;
  float dx = p.x - (rect.x + hw); float dy = p.y - (rect.y + hh);
  float limit = min(hw, hh);
  float r = dy < 0.0 ? (dx < 0.0 ? radii.x : radii.y) : (dx < 0.0 ? radii.w : radii.z);
  r = min(r, limit);
  float qx = abs(dx) - hw + r; float qy = abs(dy) - hh + r;
  float mx = max(qx, 0.0); float my = max(qy, 0.0);
  return min(max(qx, qy), 0.0) + sqrt(mx * mx + my * my) - r;
}
vec2 boxCoverage(vec2 p) {
  float outer = clamp01(0.5 - roundedDistance(p, f_rect, f_radii));
  float bt = f_border.x; float br = f_border.y; float bb = f_border.z; float bl = f_border.w;
  if (bt == 0.0 && br == 0.0 && bb == 0.0 && bl == 0.0) return vec2(outer, 0.0);
  vec4 ir = vec4(f_rect.x + bl, f_rect.y + bt, f_rect.z - bl - br, f_rect.w - bt - bb);
  if (ir.z <= 0.0 || ir.w <= 0.0) return vec2(0.0, outer);
  vec4 irad = vec4(max(f_radii.x - max(bt, bl), 0.0), max(f_radii.y - max(bt, br), 0.0),
                   max(f_radii.z - max(bb, br), 0.0), max(f_radii.w - max(bb, bl), 0.0));
  float inner = clamp01(0.5 - roundedDistance(p, ir, irad));
  return vec2(inner, max(outer - inner, 0.0));
}
float shadowCoverage(vec2 p) {
  float d = roundedDistance(p, f_rect, f_radii);
  float t = clamp01(0.5 - d / max(f_params.z, 1.0));
  return t * t * (3.0 - 2.0 * t);
}
float gradientT(vec2 p) {
  float dx = f_params.x; float dy = f_params.y;
  float len = abs(f_rect.z * dx) + abs(f_rect.w * dy);
  if (len <= 0.0) return 0.0;
  return clamp01(((p.x - (f_rect.x + f_rect.z * 0.5)) * dx + (p.y - (f_rect.y + f_rect.w * 0.5)) * dy) / len + 0.5);
}
void main() {
  vec2 p = vec2(gl_FragCoord.x, u_target.y - gl_FragCoord.y);
  if (p.x < f_clip.x || p.y < f_clip.y || p.x >= f_clip.x + f_clip.z || p.y >= f_clip.y + f_clip.w) discard;
  float opacity = f_params.w;
  if (f_kind == 0u) {
    vec2 c = boxCoverage(p);
    vec4 col = (f_fill == f_fill2) ? f_fill : mix(f_fill, f_fill2, gradientT(p));
    float fa = col.a * c.x * opacity;
    float ba = f_border_color.a * c.y * opacity;
    out_color = vec4(f_border_color.rgb * ba + col.rgb * fa * (1.0 - ba), 1.0 - (1.0 - fa) * (1.0 - ba));
  } else if (f_kind == 1u) {
    float a = f_fill.a * shadowCoverage(p) * opacity;
    out_color = vec4(f_fill.rgb * a, a);
  } else if (f_kind == 2u) {
    ivec2 t = ivec2(f_uv.xy) + ivec2(floor(p)) - ivec2(f_rect.xy);
    float a = f_fill.a * texelFetch(u_atlas, t, 0).r * opacity;
    out_color = vec4(f_fill.rgb * a, a);
  } else if (f_kind == 3u) {
    // The bilinear filter of the CPU renderer, on four texels of the image page.
    vec2 u = clamp(f_uv.xy + (p - f_rect.xy) * (f_uv.zw / f_rect.zw) - 0.5, 0.0, 1022.0);
    vec2 f = u - floor(u);
    ivec2 i = ivec2(floor(u));
    vec4 c = mix(mix(texelFetch(u_images, i, 0), texelFetch(u_images, i + ivec2(1, 0), 0), f.x),
                 mix(texelFetch(u_images, i + ivec2(0, 1), 0), texelFetch(u_images, i + ivec2(1, 1), 0), f.x), f.y);
    float a = c.a * opacity;
    out_color = vec4(c.rgb * a, a);
  } else {
    discard;
  }
}`;

const QUAD_BYTES = 160;
const ATLAS = 1024;

const KEYS = {
  Enter: "Return", Backspace: "BackSpace", Tab: "Tab", Escape: "Escape", Delete: "Delete",
  ArrowLeft: "Left", ArrowRight: "Right", ArrowUp: "Up", ArrowDown: "Down", Home: "Home", End: "End",
  PageUp: "Prior", PageDown: "Next", Insert: "Insert", Shift: "Shift_L", Control: "Control_L", Alt: "Alt_L",
  F1: "F1", F2: "F2", F3: "F3", F4: "F4", F5: "F5", F6: "F6", F7: "F7", F8: "F8", F9: "F9", F10: "F10", F11: "F11", F12: "F12",
};


// The built-in modules of Node.js, through process.getBuiltinModule
// (Node.js 22.3 and later). The file has no `node:` import, so a
// bundler for the browser needs no shim.
function nodeModule(name) {
  return globalThis.process?.getBuiltinModule?.(name);
}

/// The URL of the ztk.wasm file next to this file. Bundlers (Vite,
/// webpack 5) find it through the `new URL("./ztk.wasm", import.meta.url)`
/// form, and a CDN serves it from the folder of this file.
export function wasmURL() {
  return new URL("./ztk.wasm", import.meta.url);
}

async function compileFrom(u) {
  const url = new URL(u, globalThis.location?.href);
  const fs = nodeModule("node:fs/promises");
  if (url.protocol === "file:" && fs) return WebAssembly.compile(await fs.readFile(url));
  const res = await fetch(url);
  if (!res.ok) throw new Error(`ztk.wasm: HTTP ${res.status}`);
  if (WebAssembly.compileStreaming && res.headers.get("content-type") === "application/wasm") {
    return WebAssembly.compileStreaming(res);
  }
  return WebAssembly.compile(await res.arrayBuffer());
}

/// Compiles ztk.wasm one time for each URL. With no URL, it is the
/// ztk.wasm file next to this file.
const compiled = new Map();
export function compileModule(url) {
  const u = String(url || wasmURL());
  if (!compiled.has(u)) {
    const p = compileFrom(u);
    p.catch(() => compiled.delete(u));
    compiled.set(u, p);
  }
  return compiled.get(u);
}

let logged = false;

/// The renderers that this file has, in the order of "auto".
export const renderers = ["webgpu", "webgl2", "cpu"];

// The WebGL 2 renderer: the quads of the scene in one instanced draw.
function webgl2(canvas, ex) {
  const gl = canvas.getContext("webgl2", { premultipliedAlpha: true, antialias: false, alpha: false, preserveDrawingBuffer: true });
  if (!gl) return null;
  const compile = (type, src) => {
    const s = gl.createShader(type);
    gl.shaderSource(s, src);
    gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
    return s;
  };
  const prog = gl.createProgram();
  gl.attachShader(prog, compile(gl.VERTEX_SHADER, VS));
  gl.attachShader(prog, compile(gl.FRAGMENT_SHADER, FS));
  gl.linkProgram(prog);
  if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(prog));
  const vao = gl.createVertexArray();
  gl.bindVertexArray(vao);
  const buf = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, buf);
  for (let i = 0; i < 9; i++) {
    gl.enableVertexAttribArray(i);
    gl.vertexAttribPointer(i, 4, gl.FLOAT, false, QUAD_BYTES, i * 16);
    gl.vertexAttribDivisor(i, 1);
  }
  gl.enableVertexAttribArray(9);
  gl.vertexAttribIPointer(9, 1, gl.UNSIGNED_INT, QUAD_BYTES, 144);
  gl.vertexAttribDivisor(9, 1);
  const tex = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, tex);
  gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.R8, ATLAS, ATLAS, 0, gl.RED, gl.UNSIGNED_BYTE, null);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
  // The RGBA image page, on texture unit 1.
  const imgTex = gl.createTexture();
  gl.activeTexture(gl.TEXTURE1);
  gl.bindTexture(gl.TEXTURE_2D, imgTex);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, ATLAS, ATLAS, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
  gl.activeTexture(gl.TEXTURE0);
  gl.useProgram(prog);
  gl.uniform1i(gl.getUniformLocation(prog, "u_atlas"), 0);
  gl.uniform1i(gl.getUniformLocation(prog, "u_images"), 1);
  const uTarget = gl.getUniformLocation(prog, "u_target");
  let atlasVersion = -1;
  return {
    name: "webgl2",
    draw(n, w, h) {
      const v = ex.ztk_atlas_version();
      if (v !== atlasVersion) {
        atlasVersion = v;
        const p = ex.ztk_atlas();
        if (p) gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, ATLAS, ATLAS, gl.RED, gl.UNSIGNED_BYTE, new Uint8Array(ex.memory.buffer, p, ATLAS * ATLAS));
        const ip = ex.ztk_images ? ex.ztk_images() : 0;
        if (ip) {
          gl.activeTexture(gl.TEXTURE1);
          gl.bindTexture(gl.TEXTURE_2D, imgTex);
          gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, ATLAS, ATLAS, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array(ex.memory.buffer, ip, ATLAS * ATLAS * 4));
          gl.activeTexture(gl.TEXTURE0);
          gl.bindTexture(gl.TEXTURE_2D, tex);
        }
      }
      const c = new Float32Array(ex.memory.buffer, ex.ztk_clear_color(), 4);
      gl.viewport(0, 0, w, h);
      gl.disable(gl.SCISSOR_TEST);
      gl.clearColor(c[0], c[1], c[2], c[3]);
      gl.clear(gl.COLOR_BUFFER_BIT);
      if (n > 0) {
        gl.useProgram(prog);
        gl.bindVertexArray(vao);
        gl.bindBuffer(gl.ARRAY_BUFFER, buf);
        gl.bufferData(gl.ARRAY_BUFFER, new Uint8Array(ex.memory.buffer, ex.ztk_quads(), n * QUAD_BYTES), gl.STREAM_DRAW);
        gl.uniform2f(uTarget, w, h);
        gl.enable(gl.BLEND);
        gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
        gl.drawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, n);
      }
    },
    destroy() {
      gl.deleteBuffer(buf);
      gl.deleteTexture(tex);
      gl.deleteTexture(imgTex);
      gl.deleteVertexArray(vao);
      gl.deleteProgram(prog);
    },
  };
}

// The CPU renderer: ztk.wasm draws each frame to an RGBA image (the
// renderer of src/render/cpu.zig), and a 2D context shows it.
function cpu(canvas, ex) {
  const ctx = canvas.getContext("2d", { alpha: false });
  if (!ctx) return null;
  ex.ztk_cpu(true);
  return {
    name: "cpu",
    draw(_n, w, h) {
      const p = ex.ztk_image();
      if (!p || w === 0 || h === 0) return;
      const px = new Uint8ClampedArray(ex.memory.buffer, p, w * h * 4).slice();
      ctx.putImageData(new ImageData(px, w, h), 0, 0);
    },
    destroy() {},
  };
}

/// Starts ztk.wasm on a canvas. `mount` is the API for a page. Options:
/// module or wasm (the module, or the URL of ztk.wasm), renderer ("auto",
/// "webgpu", "webgl2", or "cpu"), colorSpace ("srgb" or "display-p3" for
/// WebGPU), loop (false: the page calls frame()), dark (true, false, or undefined for the
/// color scheme of the page), width and height (a fixed logical size),
/// scale (in place of devicePixelRatio), and log (gets the text of puts
/// and the errors).
export async function start(canvas, options = {}) {
  const enc = new TextEncoder();
  const dec = new TextDecoder();
  let ex = null;
  const log = options.log || ((t) => console.log(t));
  const imports = {
    env: {
      ztk_now_ms: () => performance.now(),
      ztk_print: (p, n) => log(dec.decode(new Uint8Array(ex.memory.buffer, p, n))),
    },
  };
  // A page with several demos compiles the module one time and gives it as options.module.
  const module = options.module || await compileModule(options.wasm);
  const instance = await WebAssembly.instantiate(module, imports);
  ex = instance.exports;

  // Each listener of the page and of the canvas goes away with destroy().
  const life = new AbortController();
  const signal = life.signal;
  const dark = matchMedia("(prefers-color-scheme: dark)");
  const reduce = matchMedia("(prefers-reduced-motion: reduce)");
  let forceDark = options.dark;
  // The window of the script starts with the size of the element that
  // holds the canvas, or with a fixed logical size (options.width and
  // options.height) that the page shows at the size it gave the canvas.
  // The toplevel then takes its own size, as in Tk (geometry propagation),
  // so the canvas gets its CSS size from the scene after each frame:
  // the scene width times k / scale, where k is the count of CSS pixels in
  // one logical pixel. The backing store is the scene in device pixels.
  // So the window keeps its aspect ratio and is sharp at each
  // devicePixelRatio.
  const fixed = Boolean(options.width && options.height);
  const host = canvas.parentElement;
  const size = () => {
    if (fixed) return [options.width, options.height];
    const r = host.getBoundingClientRect();
    return [Math.max(1, Math.round(r.width)), Math.max(1, Math.round(r.height))];
  };
  let k = 1;
  if (fixed) {
    const r = canvas.getBoundingClientRect();
    if (r.width > 0) k = r.width / options.width;
  }
  const scaleNow = () => options.scale || devicePixelRatio * k;
  const [w0, h0] = size();
  if (!ex.ztk_init(w0, h0, scaleNow(), forceDark ?? dark.matches, reduce.matches)) throw new Error("ztk_init failed");
  dark.addEventListener("change", () => forceDark == null && ex.ztk_dark(dark.matches), { signal });
  reduce.addEventListener("change", () => ex.ztk_reduce_motion(reduce.matches), { signal });

  const withBytes = (text, f) => {
    const b = enc.encode(text);
    const p = ex.ztk_alloc(Math.max(b.length, 1));
    new Uint8Array(ex.memory.buffer, p, b.length).set(b);
    try { return f(p, b.length); } finally { ex.ztk_free(p, Math.max(b.length, 1)); }
  };
  const result = () => dec.decode(new Uint8Array(ex.memory.buffer, ex.ztk_result_ptr(), ex.ztk_result_len()));
  const evalScript = (text) => {
    const code = withBytes(text, (p, n) => ex.ztk_eval(p, n));
    const r = result();
    if (code !== 0) log("error: " + r);
    return { ok: code === 0, result: r };
  };

  // The renderer. "auto" selects the first one that the browser has. A
  // canvas has one context type, so WebGPU asks for its device before it
  // gets the context of the canvas. A forced renderer that the browser
  // does not have rejects.
  const query = globalThis.location ? new URLSearchParams(location.search).get("renderer") : null;
  const want = options.renderer || query || "auto";
  let lastN = 0;
  const makers = {
    webgpu: () => createWebGPU(canvas, ex, { colorSpace: options.colorSpace, restored: () => draw(lastN) }),
    webgl2: () => webgl2(canvas, ex),
    cpu: () => cpu(canvas, ex),
  };
  if (want !== "auto" && !makers[want]) throw new Error(`ztk: no renderer "${want}"`);
  let renderer = null;
  for (const name of want === "auto" ? renderers : [want]) {
    try {
      renderer = await makers[name]();
    } catch (e) {
      if (want !== "auto") throw e;
      console.warn(`ztk: the renderer ${name} failed: ${e}`);
    }
    if (renderer || want !== "auto") break;
  }
  const names = { webgpu: "WebGPU", webgl2: "WebGL 2", cpu: "a 2D canvas" };
  if (!renderer) throw new Error(want === "auto" ? "ztk: WebGPU, WebGL 2, and a 2D canvas are not available" : `ztk: ${names[want]} is not available`);
  if (!logged) {
    logged = true;
    console.info(`ztk: the renderer is ${renderer.name}`);
  }

  const draw = (n) => {
    lastN = n;
    const w = ex.ztk_scene_width(), h = ex.ztk_scene_height();
    if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; }
    const sc = scaleNow();
    const cw = `${(w * k) / sc}px`, ch = `${(h * k) / sc}px`;
    if (canvas.style.width !== cw || canvas.style.height !== ch) { canvas.style.width = cw; canvas.style.height = ch; }
    renderer.draw(n, w, h);
    updateA11y();
  };

  // Input. A hidden text area holds the keyboard focus.
  const on = (target, type, f) => target.addEventListener(type, f, { signal });
  const input = document.createElement("textarea");
  input.setAttribute("aria-hidden", "true");
  input.style.cssText = "position:absolute;left:0;top:0;width:1px;height:1px;opacity:0;pointer-events:none;";
  canvas.parentElement.style.position ||= "relative";
  canvas.parentElement.appendChild(input);
  const pos = (e) => {
    const r = canvas.getBoundingClientRect();
    return [(e.clientX - r.left) / k, (e.clientY - r.top) / k];
  };
  const mods = (e) => ex.ztk_mods(e.shiftKey, e.ctrlKey || e.metaKey, e.altKey);
  on(canvas, "pointermove", (e) => { mods(e); ex.ztk_pointer(...pos(e)); });
  on(canvas, "pointerdown", (e) => {
    mods(e); ex.ztk_pointer(...pos(e)); ex.ztk_button([1, 2, 3][e.button] || 1, true);
    try { canvas.setPointerCapture(e.pointerId); } catch (_) { /* a synthetic event has no capture */ }
    input.focus({ preventScroll: true }); e.preventDefault();
  });
  on(canvas, "pointerup", (e) => { mods(e); ex.ztk_pointer(...pos(e)); ex.ztk_button([1, 2, 3][e.button] || 1, false); });
  on(canvas, "pointerleave", () => ex.ztk_leave());
  // A wheel step is 100 pixels in deltaMode 0 and 3 lines in deltaMode 1.
  canvas.addEventListener("wheel", (e) => {
    e.preventDefault();
    mods(e); ex.ztk_pointer(...pos(e));
    const k = e.deltaMode === 1 ? 1 / 3 : e.deltaMode === 2 ? 10 : 1 / 100;
    ex.ztk_wheel(e.deltaX * k, e.deltaY * k);
  }, { passive: false, signal });
  on(canvas, "contextmenu", (e) => e.preventDefault());
  let composing = false;
  on(input, "compositionstart", () => { composing = true; });
  on(input, "compositionend", (e) => { composing = false; withBytes(e.data || "", (p, n) => ex.ztk_text(p, n)); input.value = ""; });
  on(input, "input", (e) => {
    if (composing || e.isComposing) return;
    if (input.value) withBytes(input.value, (p, n) => ex.ztk_text(p, n));
    input.value = "";
  });
  const key = (e, down) => {
    mods(e);
    const name = KEYS[e.key];
    if (!name) return;
    withBytes(name, (p, n) => ex.ztk_key(p, n, down));
    if (e.key === "Tab" || e.key.startsWith("Arrow") || e.key === "Backspace") e.preventDefault();
  };
  on(input, "keydown", (e) => key(e, true));
  on(input, "keyup", (e) => key(e, false));
  // A change of devicePixelRatio sends the new scale, so the next frame is
  // drawn sharp at the new scale. A change of the size of the page does
  // not resize the window: in Tk a toplevel keeps its own size, and a
  // resize from the platform would stop its geometry propagation.
  // resize() and mount({ size: "fill" }) resize the window.
  const watchScale = () => {
    const m = matchMedia(`(resolution: ${devicePixelRatio}dppx)`);
    m.addEventListener("change", () => { ex.ztk_scale(scaleNow()); watchScale(); }, { once: true, signal });
  };
  watchScale();

  // Accessibility: hidden elements with ARIA roles over the canvas.
  const tree = document.createElement("div");
  tree.style.cssText = "position:absolute;left:0;top:0;width:0;height:0;overflow:visible;pointer-events:none;";
  canvas.parentElement.appendChild(tree);
  const ARIA = { "button": "button", "check box": "checkbox", "radio button": "radio", "text field": "textbox", "label": "note", "slider": "slider", "group": "group", "window": "dialog" };
  let lastA11y = "";
  const updateA11y = () => {
    const n = ex.ztk_a11y();
    const text = dec.decode(new Uint8Array(ex.memory.buffer, ex.ztk_a11y_ptr(), n));
    if (text === lastA11y) return;
    lastA11y = text;
    tree.replaceChildren(...JSON.parse(text).map((node) => {
      const el = document.createElement("div");
      el.setAttribute("role", ARIA[node.role] || "generic");
      el.setAttribute("aria-label", node.name);
      el.dataset.path = node.path;
      if (node.role === "check box" || node.role === "radio button") el.setAttribute("aria-checked", String(node.selected));
      if (node.disabled) el.setAttribute("aria-disabled", "true");
      el.style.cssText = `position:absolute;left:${node.x}px;top:${node.y}px;width:${node.w}px;height:${node.h}px;opacity:0;`;
      return el;
    }));
  };

  // The popups: a posted menu and its cascades. Each popup is a 2D canvas
  // in a fixed layer above the page, at the place of the popup, so a menu
  // can extend past the canvas of the window. The screen of the popups is
  // the viewport. The image of a popup has premultiplied alpha, and a 2D
  // canvas takes straight alpha.
  const layer = document.createElement("div");
  layer.style.cssText = "position:fixed;left:0;top:0;width:0;height:0;overflow:visible;z-index:2147483647;";
  layer.dataset.ztkPopups = "";
  document.body.appendChild(layer);
  const pops = [];
  let popDraws = -1;
  let popPlace = "";
  const popPos = (c, e) => {
    const r = c.getBoundingClientRect();
    return [(e.clientX - r.left) / k, (e.clientY - r.top) / k];
  };
  const makePop = (i) => {
    const c = document.createElement("canvas");
    c.style.cssText = "position:absolute;touch-action:none;";
    c.setAttribute("aria-hidden", "true");
    on(c, "pointermove", (e) => { mods(e); ex.ztk_popup_pointer(i, ...popPos(c, e)); });
    on(c, "pointerdown", (e) => {
      mods(e); ex.ztk_popup_pointer(i, ...popPos(c, e)); ex.ztk_popup_button(i, [1, 2, 3][e.button] || 1, true);
      input.focus({ preventScroll: true }); e.preventDefault();
    });
    on(c, "pointerup", (e) => { mods(e); ex.ztk_popup_pointer(i, ...popPos(c, e)); ex.ztk_popup_button(i, [1, 2, 3][e.button] || 1, false); });
    on(c, "pointerleave", () => ex.ztk_popup_leave(i));
    on(c, "contextmenu", (e) => e.preventDefault());
    layer.appendChild(c);
    return c;
  };
  const drawPops = () => {
    const n = ex.ztk_popups();
    while (pops.length > n) pops.pop().remove();
    while (pops.length < n) pops.push(makePop(pops.length));
    if (n === 0) return;
    const cr = canvas.getBoundingClientRect();
    const draws = ex.ztk_draws();
    const place = `${cr.left},${cr.top},${k}`;
    if (draws === popDraws && place === popPlace) return;
    const fresh = draws !== popDraws;
    popDraws = draws;
    popPlace = place;
    for (let i = 0; i < n; i++) {
      const c = pops[i];
      const r = new Int32Array(ex.memory.buffer, ex.ztk_popup_rect(i), 6);
      const [x, y, w, h, iw, ih] = r;
      c.style.left = `${cr.left + x * k}px`;
      c.style.top = `${cr.top + y * k}px`;
      c.style.width = `${w * k}px`;
      c.style.height = `${h * k}px`;
      const p = ex.ztk_popup_image(i);
      if (!fresh || !p || iw === 0 || ih === 0) continue;
      if (c.width !== iw || c.height !== ih) { c.width = iw; c.height = ih; }
      const px = new Uint8ClampedArray(ex.memory.buffer, p, iw * ih * 4).slice();
      for (let j = 0; j < px.length; j += 4) {
        const a = px[j + 3];
        if (a !== 0 && a !== 255) { px[j] = px[j] * 255 / a; px[j + 1] = px[j + 1] * 255 / a; px[j + 2] = px[j + 2] * 255 / a; }
      }
      c.getContext("2d").putImageData(new ImageData(px, iw, ih), 0, 0);
    }
  };
  // A press outside the window and the popups closes the popups, as a compositor does.
  document.addEventListener("pointerdown", (e) => {
    if (pops.length > 0 && e.target !== canvas && !layer.contains(e.target)) ex.ztk_popup_dismiss();
  }, { capture: true, signal });
  const setScreen = () => {
    const r = canvas.getBoundingClientRect();
    ex.ztk_screen(Math.round(-r.left / k), Math.round(-r.top / k), Math.round(innerWidth / k), Math.round(innerHeight / k));
  };

  let raf = 0;
  const loop = (t) => {
    setScreen();
    const n = ex.ztk_frame(t);
    if (n >= 0) draw(n);
    drawPops();
    raf = requestAnimationFrame(loop);
  };
  // options.loop false leaves the frames to the page, for a test.
  if (options.loop !== false) raf = requestAnimationFrame(loop);
  const addFile = (name, text) => withBytes(name, (pn, nn) => withBytes(text, (pt, nt) => ex.ztk_add_file(pn, nn, pt, nt)));
  const frame = (t) => {
    if (signal.aborted) return -1;
    setScreen();
    const n = ex.ztk_frame(t);
    if (n >= 0) draw(n);
    drawPops();
    return n;
  };
  // The window of the script gets a new logical size.
  const resize = (w, h) => ex.ztk_resize(Math.max(1, Math.round(w)), Math.max(1, Math.round(h)), scaleNow());
  // "dark", "light", or "auto" (the color scheme of the page).
  const setTheme = (theme) => {
    forceDark = theme === "dark" ? true : theme === "light" ? false : undefined;
    ex.ztk_dark(forceDark ?? dark.matches);
  };
  const destroy = () => {
    if (signal.aborted) return;
    life.abort();
    cancelAnimationFrame(raf);
    renderer.destroy();
    input.remove();
    tree.remove();
    layer.remove();
  };
  // A WebGPU canvas keeps its image only until the frame is shown, so a
  // snapshot draws the last scene again and reads the canvas at once.
  const redraw = () => draw(lastN);
  const snapshot = (type = "image/png") => { redraw(); return canvas.toDataURL(type); };
  // A test: the GPU device is lost, and the renderer draws on a new one.
  const loseDevice = async () => (renderer.lose ? renderer.lose() : false);
  return { eval: evalScript, exports: ex, frame, tree, addFile, canvas, resize, setTheme, destroy, renderer: renderer.name, redraw, snapshot, loseDevice, signal };
}

/// Mounts a ztk app on an element. `el` is a canvas, or an element that
/// gets a new canvas. Options:
///   script    Tcl text to run, after the files.
///   files     { name: text } for `ztk::style load`, for example a style sheet.
///   theme     "auto" (the default: the color scheme of the page), "light", or "dark".
///   size      "auto" (the default: the size of the element at the start,
///             and then the size the window computes), "fill" (the window
///             follows the size of the element), or [width, height] in
///             logical pixels (the canvas shows the window at its CSS size).
///   renderer  "auto" (the default), "webgpu", "webgl2", or "cpu".
///   scale     The device pixels in one logical pixel. The default is devicePixelRatio.
///   module, wasm, log  As for start().
/// A script error destroys the app and rejects with the error text.
export async function mount(el, options = {}) {
  if (!el || typeof el.appendChild !== "function") throw new Error("ztk.mount: el must be an element");
  const own = !(el instanceof HTMLCanvasElement);
  const canvas = own ? document.createElement("canvas") : el;
  const { size = "auto", theme = "auto" } = options;
  if (own) {
    // With "fill", the canvas has no part in the layout of the element,
    // so the size of the element comes from the page only.
    canvas.style.cssText = size === "fill" ? "display:block;touch-action:none;position:absolute;left:0;top:0;" : "display:block;touch-action:none;";
    el.appendChild(canvas);
  }
  const opts = { module: options.module, wasm: options.wasm, log: options.log, scale: options.scale, renderer: options.renderer };
  if (theme !== "auto") opts.dark = theme === "dark";
  if (Array.isArray(size)) [opts.width, opts.height] = size;
  else if (size && typeof size === "object") ({ width: opts.width, height: opts.height } = size);
  let app;
  try {
    app = await start(canvas, opts);
  } catch (e) {
    if (own) canvas.remove();
    throw e;
  }
  const destroy = app.destroy;
  let observer = null;
  if (size === "fill" && typeof ResizeObserver !== "undefined") {
    observer = new ResizeObserver(([entry]) => {
      const r = entry.contentRect;
      if (r.width > 0 && r.height > 0) app.resize(r.width, r.height);
    });
    observer.observe(canvas.parentElement);
  }
  app.destroy = () => {
    observer?.disconnect();
    destroy();
    if (own) canvas.remove();
  };
  for (const [name, text] of Object.entries(options.files || {})) app.addFile(name, text);
  if (options.script != null) {
    const r = app.eval(options.script);
    if (!r.ok) {
      app.destroy();
      const err = new Error(r.result);
      err.result = r;
      throw err;
    }
  }
  app.frame(performance.now());
  return app;
}
