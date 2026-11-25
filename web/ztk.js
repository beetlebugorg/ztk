// SPDX-License-Identifier: BSD-2-Clause
// The page side of ztk in a browser. It loads ztk.wasm, gives it the
// clock, the size, the scale (devicePixelRatio), the color scheme, the
// reduced motion setting, and the input of the canvas, and draws each
// scene with WebGL 2. The shaders have the formulas of the CPU renderer
// (src/render/renderer.zig) and of src/render/shaders/quad.frag. A
// hidden text area gets the keyboard, so that text input and input
// methods work. A list of hidden elements with ARIA roles follows the
// widgets, from ztk_a11y.

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
  const url = options.wasm || new URL("ztk.wasm", import.meta.url);
  const { instance } = await WebAssembly.instantiateStreaming(fetch(url), imports);
  ex = instance.exports;

  const dark = matchMedia("(prefers-color-scheme: dark)");
  const reduce = matchMedia("(prefers-reduced-motion: reduce)");
  const forceDark = options.dark;
  const size = () => {
    const r = canvas.getBoundingClientRect();
    return [Math.max(1, Math.round(r.width)), Math.max(1, Math.round(r.height))];
  };
  const [w0, h0] = size();
  if (!ex.ztk_init(w0, h0, options.scale || devicePixelRatio, forceDark ?? dark.matches, reduce.matches)) throw new Error("ztk_init failed");
  dark.addEventListener("change", () => forceDark === undefined && ex.ztk_dark(dark.matches));
  reduce.addEventListener("change", () => ex.ztk_reduce_motion(reduce.matches));

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

  // WebGL 2.
  const gl = canvas.getContext("webgl2", { premultipliedAlpha: true, antialias: false, alpha: false, preserveDrawingBuffer: true });
  if (!gl) throw new Error("WebGL 2 is not available");
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
  const uTarget = gl.getUniformLocation(prog, "u_target");
  let atlasVersion = -1;

  const draw = (n) => {
    const w = ex.ztk_scene_width(), h = ex.ztk_scene_height();
    if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; }
    const v = ex.ztk_atlas_version();
    if (v !== atlasVersion) {
      atlasVersion = v;
      const p = ex.ztk_atlas();
      if (p) gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, ATLAS, ATLAS, gl.RED, gl.UNSIGNED_BYTE, new Uint8Array(ex.memory.buffer, p, ATLAS * ATLAS));
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
    updateA11y();
  };

  // Input. A hidden text area holds the keyboard focus.
  const input = document.createElement("textarea");
  input.setAttribute("aria-hidden", "true");
  input.style.cssText = "position:absolute;left:0;top:0;width:1px;height:1px;opacity:0;pointer-events:none;";
  canvas.parentElement.style.position ||= "relative";
  canvas.parentElement.appendChild(input);
  const pos = (e) => {
    const r = canvas.getBoundingClientRect();
    return [e.clientX - r.left, e.clientY - r.top];
  };
  const mods = (e) => ex.ztk_mods(e.shiftKey, e.ctrlKey || e.metaKey, e.altKey);
  canvas.addEventListener("pointermove", (e) => { mods(e); ex.ztk_pointer(...pos(e)); });
  canvas.addEventListener("pointerdown", (e) => {
    mods(e); ex.ztk_pointer(...pos(e)); ex.ztk_button([1, 2, 3][e.button] || 1, true);
    try { canvas.setPointerCapture(e.pointerId); } catch (_) { /* a synthetic event has no capture */ }
    input.focus({ preventScroll: true }); e.preventDefault();
  });
  canvas.addEventListener("pointerup", (e) => { mods(e); ex.ztk_pointer(...pos(e)); ex.ztk_button([1, 2, 3][e.button] || 1, false); });
  canvas.addEventListener("pointerleave", () => ex.ztk_leave());
  canvas.addEventListener("contextmenu", (e) => e.preventDefault());
  let composing = false;
  input.addEventListener("compositionstart", () => { composing = true; });
  input.addEventListener("compositionend", (e) => { composing = false; withBytes(e.data || "", (p, n) => ex.ztk_text(p, n)); input.value = ""; });
  input.addEventListener("input", (e) => {
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
  input.addEventListener("keydown", (e) => key(e, true));
  input.addEventListener("keyup", (e) => key(e, false));
  new ResizeObserver(() => { const [w, h] = size(); ex.ztk_resize(w, h, options.scale || devicePixelRatio); }).observe(canvas);

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

  const loop = (t) => {
    const n = ex.ztk_frame(t);
    if (n >= 0) draw(n);
    requestAnimationFrame(loop);
  };
  requestAnimationFrame(loop);
  return { eval: evalScript, exports: ex, frame: (t) => { const n = ex.ztk_frame(t); if (n >= 0) draw(n); return n; }, tree };
}
