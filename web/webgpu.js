// SPDX-License-Identifier: BSD-2-Clause
// The WebGPU renderer of the web build. It draws the scene of a frame in
// one render pass: the quads go into a storage buffer, and one instanced
// draw of a triangle strip with 4 vertices draws them. The vertex stage
// reads its quad by the instance index and covers the quad rectangle,
// with a margin for the anti-aliased edge and the shadow blur, cut to the
// clip. The fragment stage has the formulas of src/render/renderer.zig:
// roundedDistance, boxCoverage, shadowCoverage, and gradientT. It gives a
// premultiplied color, and the blend is ONE and ONE_MINUS_SRC_ALPHA on a
// UNORM target, so the result equals "source over" on the sRGB values of
// the CPU renderer. The glyph atlas is an r8unorm texture of 1024 by 1024
// texels.
//
// The canvas color space is sRGB. Where the display has the P3 gamut, the
// canvas is display-p3 and the vertex stage converts each sRGB color of
// the scene to P3: the sRGB curve to linear, the 3 by 3 matrix of the two
// primaries, and the curve back. The blend then works on P3 values.
//
// All canvases of a page share one GPUDevice. When the device is lost,
// each renderer asks for a new device, makes its pipeline again, sets the
// atlas version back so that the next draw uploads the atlas again, and
// calls its `restored` function, which draws the last scene again.
//
// The renderer calls its `failed` function when the GPU gives an error
// or when no new device comes after a loss. The page then renders with
// WebGL 2 (web/ztk.js). An error in the pipeline at the start makes
// createWebGPU reject before it gets the context of the canvas.

const QUAD_BYTES = 160;
const ATLAS = 1024;

const WGSL = /* wgsl */ `
struct Quad {
  rect: vec4f, clip: vec4f, radii: vec4f, border: vec4f,
  fill: vec4f, fill2: vec4f, border_color: vec4f, uv: vec4f, params: vec4f,
  kind: u32, pad0: u32, pad1: u32, pad2: u32,
};
struct Uniforms { size: vec2f, p3: u32, pad: u32 };
@group(0) @binding(0) var<uniform> u: Uniforms;
@group(0) @binding(1) var<storage, read> quads: array<Quad>;
@group(0) @binding(2) var atlas: texture_2d<f32>;
@group(0) @binding(3) var images: texture_2d<f32>;

struct V {
  @builtin(position) pos: vec4f,
  @location(0) @interpolate(flat) idx: u32,
  @location(1) @interpolate(flat) fill: vec4f,
  @location(2) @interpolate(flat) fill2: vec4f,
  @location(3) @interpolate(flat) border_color: vec4f,
};

fn toLinear(c: f32) -> f32 {
  if (c <= 0.04045) { return c / 12.92; }
  return pow((c + 0.055) / 1.055, 2.4);
}
fn toCurve(c: f32) -> f32 {
  if (c <= 0.0031308) { return c * 12.92; }
  return 1.055 * pow(c, 1.0 / 2.4) - 0.055;
}
// An sRGB color to Display P3, with the alpha kept.
fn toP3(c: vec4f) -> vec4f {
  let l = vec3f(toLinear(c.r), toLinear(c.g), toLinear(c.b));
  let p = vec3f(
    0.8224621 * l.r + 0.1775380 * l.g,
    0.0331941 * l.r + 0.9668058 * l.g,
    0.0170827 * l.r + 0.0723974 * l.g + 0.9105199 * l.b);
  return vec4f(toCurve(p.r), toCurve(p.g), toCurve(p.b), c.a);
}

@vertex fn vs(@builtin(vertex_index) vi: u32, @builtin(instance_index) ii: u32) -> V {
  let q = quads[ii];
  var pad = 0.0;
  if (q.kind == 0u) { pad = 1.0; }
  if (q.kind == 1u) { pad = max(q.params.z, 1.0) + 1.0; }
  let lo = max(q.rect.xy - pad, q.clip.xy);
  let hi = max(min(q.rect.xy + q.rect.zw + pad, q.clip.xy + q.clip.zw), lo);
  let corner = vec2f(f32(vi & 1u), f32(vi >> 1u));
  let ndc = mix(lo, hi, corner) / u.size * 2.0 - 1.0;
  var v: V;
  v.pos = vec4f(ndc.x, -ndc.y, 0.0, 1.0);
  v.idx = ii;
  v.fill = q.fill;
  v.fill2 = q.fill2;
  v.border_color = q.border_color;
  if (u.p3 != 0u) {
    v.fill = toP3(q.fill);
    v.fill2 = toP3(q.fill2);
    v.border_color = toP3(q.border_color);
  }
  return v;
}

fn clamp01(x: f32) -> f32 { return clamp(x, 0.0, 1.0); }

fn roundedDistance(p: vec2f, rect: vec4f, radii: vec4f) -> f32 {
  let hw = rect.z * 0.5;
  let hh = rect.w * 0.5;
  let dx = p.x - (rect.x + hw);
  let dy = p.y - (rect.y + hh);
  let limit = min(hw, hh);
  var r = radii.z;
  if (dy < 0.0) {
    if (dx < 0.0) { r = radii.x; } else { r = radii.y; }
  } else if (dx < 0.0) {
    r = radii.w;
  }
  r = min(r, limit);
  let qx = abs(dx) - hw + r;
  let qy = abs(dy) - hh + r;
  let mx = max(qx, 0.0);
  let my = max(qy, 0.0);
  return min(max(qx, qy), 0.0) + sqrt(mx * mx + my * my) - r;
}

fn boxCoverage(q: Quad, p: vec2f) -> vec2f {
  let outer = clamp01(0.5 - roundedDistance(p, q.rect, q.radii));
  let bt = q.border.x;
  let br = q.border.y;
  let bb = q.border.z;
  let bl = q.border.w;
  if (bt == 0.0 && br == 0.0 && bb == 0.0 && bl == 0.0) { return vec2f(outer, 0.0); }
  let ir = vec4f(q.rect.x + bl, q.rect.y + bt, q.rect.z - bl - br, q.rect.w - bt - bb);
  if (ir.z <= 0.0 || ir.w <= 0.0) { return vec2f(0.0, outer); }
  let irad = vec4f(max(q.radii.x - max(bt, bl), 0.0), max(q.radii.y - max(bt, br), 0.0),
                   max(q.radii.z - max(bb, br), 0.0), max(q.radii.w - max(bb, bl), 0.0));
  let inner = clamp01(0.5 - roundedDistance(p, ir, irad));
  return vec2f(inner, max(outer - inner, 0.0));
}

fn shadowCoverage(q: Quad, p: vec2f) -> f32 {
  let d = roundedDistance(p, q.rect, q.radii);
  let t = clamp01(0.5 - d / max(q.params.z, 1.0));
  return t * t * (3.0 - 2.0 * t);
}

fn gradientT(q: Quad, p: vec2f) -> f32 {
  let dx = q.params.x;
  let dy = q.params.y;
  let len = abs(q.rect.z * dx) + abs(q.rect.w * dy);
  if (len <= 0.0) { return 0.0; }
  return clamp01(((p.x - (q.rect.x + q.rect.z * 0.5)) * dx + (p.y - (q.rect.y + q.rect.w * 0.5)) * dy) / len + 0.5);
}

@fragment fn fs(v: V) -> @location(0) vec4f {
  let q = quads[v.idx];
  // The position has the pixel center (x + 0.5, y + 0.5), from the top left.
  let p = v.pos.xy;
  if (p.x < q.clip.x || p.y < q.clip.y || p.x >= q.clip.x + q.clip.z || p.y >= q.clip.y + q.clip.w) { discard; }
  let opacity = q.params.w;
  if (q.kind == 0u) {
    let c = boxCoverage(q, p);
    var col = v.fill;
    if (any(q.fill != q.fill2)) { col = mix(v.fill, v.fill2, gradientT(q, p)); }
    let fa = col.a * c.x * opacity;
    let ba = v.border_color.a * c.y * opacity;
    return vec4f(v.border_color.rgb * ba + col.rgb * fa * (1.0 - ba), 1.0 - (1.0 - fa) * (1.0 - ba));
  }
  if (q.kind == 1u) {
    let a = v.fill.a * shadowCoverage(q, p) * opacity;
    return vec4f(v.fill.rgb * a, a);
  }
  if (q.kind == 2u) {
    let t = vec2i(q.uv.xy) + vec2i(floor(p)) - vec2i(q.rect.xy);
    let a = v.fill.a * textureLoad(atlas, t, 0).r * opacity;
    return vec4f(v.fill.rgb * a, a);
  }
  if (q.kind == 3u) {
    // The bilinear filter of the CPU renderer, on four texels of the image page.
    let uu = clamp(q.uv.xy + (p - q.rect.xy) * (q.uv.zw / q.rect.zw) - 0.5, vec2f(0.0), vec2f(1022.0));
    let f = uu - floor(uu);
    let i = vec2i(floor(uu));
    var c = mix(mix(textureLoad(images, i, 0), textureLoad(images, i + vec2i(1, 0), 0), f.x),
                mix(textureLoad(images, i + vec2i(0, 1), 0), textureLoad(images, i + vec2i(1, 1), 0), f.x), f.y);
    if (u.p3 != 0u) { c = toP3(c); }
    let a = c.a * opacity;
    return vec4f(c.rgb * a, a);
  }
  discard;
  return vec4f(0.0);
}
`;

// One device for the page.
let devicePromise = null;
const lossListeners = new Set();

async function requestDevice() {
  if (!globalThis.navigator?.gpu) return null;
  // A browser that gives no answer in 3 seconds counts as one with no adapter.
  const late = new Promise((res) => setTimeout(() => res(null), 3000));
  const adapter = await Promise.race([navigator.gpu.requestAdapter(), late]);
  if (!adapter) return null;
  const device = await adapter.requestDevice();
  device.lost.then((info) => {
    devicePromise = null;
    for (const f of [...lossListeners]) f(info);
  });
  return device;
}

/// The shared device of the page, or null when the browser gives no adapter.
export function gpuDevice() {
  devicePromise ??= requestDevice().catch(() => null);
  return devicePromise;
}

/// True when the browser gives a WebGPU adapter and a device.
export async function webgpuAvailable() {
  return (await gpuDevice()) != null;
}

function srgbToP3(c) {
  const lin = (x) => (x <= 0.04045 ? x / 12.92 : ((x + 0.055) / 1.055) ** 2.4);
  const cur = (x) => (x <= 0.0031308 ? x * 12.92 : 1.055 * x ** (1 / 2.4) - 0.055);
  const [r, g, b] = [lin(c[0]), lin(c[1]), lin(c[2])];
  return [cur(0.8224621 * r + 0.177538 * g), cur(0.0331941 * r + 0.9668058 * g), cur(0.0170827 * r + 0.0723974 * g + 0.9105199 * b), c[3]];
}

/// Makes the WebGPU renderer for a canvas, or gives null when no adapter
/// exists. `ex` has the exports of ztk.wasm. `options.colorSpace` forces
/// "srgb" or "display-p3". `options.restored` runs after a device loss,
/// when the renderer can draw again. `options.failed(reason)` runs when
/// the renderer cannot draw.
export async function createWebGPU(canvas, ex, options = {}) {
  let device = await gpuDevice();
  if (!device) return null;
  const format = navigator.gpu.getPreferredCanvasFormat();
  const p3 = (options.colorSpace ?? (globalThis.matchMedia?.("(color-gamut: p3)").matches ? "display-p3" : "srgb")) === "display-p3";
  let pipeline, uniforms, atlasTex, imageTex, quadBuf, quadCap = 0, bindGroup = null;
  let atlasVersion = -1, configured = "", ready = false, closed = false;
  let restoring = null;

  const build = () => {
    const module = device.createShaderModule({ code: WGSL });
    pipeline = device.createRenderPipeline({
      layout: "auto",
      vertex: { module, entryPoint: "vs" },
      fragment: {
        module, entryPoint: "fs",
        targets: [{ format, blend: {
          color: { srcFactor: "one", dstFactor: "one-minus-src-alpha", operation: "add" },
          alpha: { srcFactor: "one", dstFactor: "one-minus-src-alpha", operation: "add" },
        } }],
      },
      primitive: { topology: "triangle-strip" },
    });
    uniforms = device.createBuffer({ size: 16, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
    atlasTex = device.createTexture({ size: [ATLAS, ATLAS], format: "r8unorm", usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST });
    imageTex = device.createTexture({ size: [ATLAS, ATLAS], format: "rgba8unorm", usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST });
    quadCap = 0;
    bindGroup = null;
    atlasVersion = -1;
    configured = "";
    ready = true;
  };
  device.pushErrorScope("validation");
  device.pushErrorScope("internal");
  build();
  const errors = [await device.popErrorScope(), await device.popErrorScope()].filter(Boolean);
  if (errors.length > 0) throw new Error(`the pipeline gave an error: ${errors[0].message}`);
  const ctx = canvas.getContext("webgpu");
  if (!ctx) return null;
  const onError = (e) => { if (!closed) options.failed?.(`gave an error: ${e.error?.message}`); };
  let errorDevice = device;
  errorDevice.addEventListener("uncapturederror", onError);

  const configure = (w, h) => {
    const key = `${w}x${h}`;
    if (configured === key) return;
    configured = key;
    ctx.configure({ device, format, alphaMode: "opaque", colorSpace: p3 ? "display-p3" : "srgb" });
  };

  const onLoss = (info) => {
    if (closed) return;
    ready = false;
    restoring = (async () => {
      device = await gpuDevice();
      if (closed) return false;
      if (!device) {
        options.failed?.("lost its device");
        return false;
      }
      errorDevice.removeEventListener("uncapturederror", onError);
      errorDevice = device;
      errorDevice.addEventListener("uncapturederror", onError);
      build();
      options.restored?.();
      return true;
    })();
  };
  lossListeners.add(onLoss);

  const draw = (n) => {
    if (!ready) return;
    const w = canvas.width, h = canvas.height;
    configure(w, h);
    const v = ex.ztk_atlas_version();
    if (v !== atlasVersion) {
      const p = ex.ztk_atlas();
      if (p) {
        device.queue.writeTexture({ texture: atlasTex }, new Uint8Array(ex.memory.buffer, p, ATLAS * ATLAS), { bytesPerRow: ATLAS }, [ATLAS, ATLAS]);
        const ip = ex.ztk_images ? ex.ztk_images() : 0;
        if (ip) device.queue.writeTexture({ texture: imageTex }, new Uint8Array(ex.memory.buffer, ip, ATLAS * ATLAS * 4), { bytesPerRow: ATLAS * 4 }, [ATLAS, ATLAS]);
        atlasVersion = v;
      }
    }
    if (n > quadCap) {
      quadBuf?.destroy();
      quadCap = Math.max(256, 2 ** Math.ceil(Math.log2(n)));
      quadBuf = device.createBuffer({ size: quadCap * QUAD_BYTES, usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST });
      bindGroup = null;
    }
    if (!quadBuf) {
      quadCap = 256;
      quadBuf = device.createBuffer({ size: quadCap * QUAD_BYTES, usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST });
    }
    bindGroup ??= device.createBindGroup({
      layout: pipeline.getBindGroupLayout(0),
      entries: [
        { binding: 0, resource: { buffer: uniforms } },
        { binding: 1, resource: { buffer: quadBuf } },
        { binding: 2, resource: atlasTex.createView() },
        { binding: 3, resource: imageTex.createView() },
      ],
    });
    const u = new ArrayBuffer(16);
    new Float32Array(u, 0, 2).set([w, h]);
    new Uint32Array(u, 8, 1)[0] = p3 ? 1 : 0;
    device.queue.writeBuffer(uniforms, 0, u);
    if (n > 0) device.queue.writeBuffer(quadBuf, 0, ex.memory.buffer, ex.ztk_quads(), n * QUAD_BYTES);
    let c = Array.from(new Float32Array(ex.memory.buffer, ex.ztk_clear_color(), 4));
    if (p3) c = srgbToP3(c);
    const enc = device.createCommandEncoder();
    const pass = enc.beginRenderPass({
      colorAttachments: [{ view: ctx.getCurrentTexture().createView(), loadOp: "clear", storeOp: "store", clearValue: { r: c[0], g: c[1], b: c[2], a: 1 } }],
    });
    if (n > 0) {
      pass.setPipeline(pipeline);
      pass.setBindGroup(0, bindGroup);
      pass.draw(4, n);
    }
    pass.end();
    device.queue.submit([enc.finish()]);
  };

  return {
    name: "webgpu",
    colorSpace: p3 ? "display-p3" : "srgb",
    draw,
    /// Destroys the device, as a lost GPU does, and waits until the renderer draws again.
    async lose() {
      const lost = new Promise((res) => {
        const f = () => { lossListeners.delete(f); res(); };
        lossListeners.add(f);
      });
      device.destroy();
      await lost;
      return (await restoring) ?? false;
    },
    destroy() {
      closed = true;
      lossListeners.delete(onLoss);
      errorDevice.removeEventListener("uncapturederror", onError);
      try { ctx.unconfigure(); } catch (_) { /* the device can be lost */ }
      quadBuf?.destroy();
      uniforms?.destroy();
      atlasTex?.destroy();
      imageTex?.destroy();
    },
  };
}
