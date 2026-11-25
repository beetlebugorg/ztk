// Tests the npm package as a project installs it. npm/test/run.mjs
// copies this file into a new project, installs the package tarball,
// and runs `node test.mjs`. The name of the package comes from the
// dependencies of that project. Node.js has no DOM, so this test runs
// ztk.wasm through its exports with the CPU renderer.
// SPDX-License-Identifier: BSD-2-Clause
import fs from "node:fs";

const deps = JSON.parse(fs.readFileSync(new URL("./package.json", import.meta.url), "utf8")).dependencies;
const name = Object.keys(deps).find((d) => d.endsWith("/ztk") || d === "ztk");
const ztk = await import(name);

let failed = 0;
let passed = 0;
const check = (ok, what) => {
  if (ok) passed++;
  else {
    console.error(`FAIL ${what}`);
    failed++;
  }
};

check(typeof ztk.mount === "function" && typeof ztk.start === "function", "mount and start are exports");
check(JSON.stringify(ztk.renderers) === '["webgl2","cpu"]', "renderers");
check(ztk.wasmURL().href === import.meta.resolve(`${name}/ztk.wasm`), "wasmURL is the file of the package");
const pkg = JSON.parse(fs.readFileSync(new URL(import.meta.resolve(`${name}/package.json`)), "utf8"));
check(pkg.name === name && /^\d+\.\d+\.\d+/.test(pkg.version), "package.json entry");
for (const f of ["LICENSE", "NOTICE", "licenses/LICENSE-Inter.txt", "licenses/ztcl/LICENSE"]) {
  check(fs.existsSync(new URL(f, import.meta.resolve(`${name}/package.json`))), `${f} is in the package`);
}

// compileModule reads the file in Node.js and compiles it one time.
const module = await ztk.compileModule();
check(module instanceof WebAssembly.Module, "compileModule() with no URL");
check((await ztk.compileModule()) === module, "compileModule caches the module");

// mount needs an element.
let rejected = false;
try {
  await ztk.mount(null, {});
} catch {
  rejected = true;
}
check(rejected, "mount(null) rejects");

// The interpreter and the widgets, with the CPU renderer.
let printed = "";
const dec = new TextDecoder();
const enc = new TextEncoder();
let ex;
const instance = await WebAssembly.instantiate(module, {
  env: { ztk_now_ms: () => 0, ztk_print: (p, n) => (printed += dec.decode(new Uint8Array(ex.memory.buffer, p, n))) },
});
ex = instance.exports;
const evalText = (text) => {
  const b = enc.encode(text);
  const p = ex.ztk_alloc(Math.max(1, b.length));
  new Uint8Array(ex.memory.buffer, p, b.length).set(b);
  const code = ex.ztk_eval(p, b.length);
  ex.ztk_free(p, Math.max(1, b.length));
  return { ok: code === 0, result: dec.decode(new Uint8Array(ex.memory.buffer, ex.ztk_result_ptr(), ex.ztk_result_len())) };
};
check(ex.ztk_init(320, 200, 1, false, false), "ztk_init");
ex.ztk_cpu(true);
check(evalText("expr {6 * 7}").result === "42", "Tcl eval");
check(evalText("button .b -text Hello; label .l -text World; pack .b .l; winfo children .").result === ".b .l", "Tk widgets");
check(!evalText("nosuchcommand").ok, "error result");
const quads = ex.ztk_frame(16);
check(quads > 0, "a frame has quads");
const w = ex.ztk_scene_width();
const h = ex.ztk_scene_height();
const px = new Uint8Array(ex.memory.buffer, ex.ztk_image(), w * h * 4);
const colors = new Set();
for (let i = 0; i < px.length; i += 4) colors.add((px[i] << 16) | (px[i + 1] << 8) | px[i + 2]);
check(w > 0 && h > 0 && colors.size > 10, "the CPU renderer draws the window");
const a11yLen = ex.ztk_a11y();
const a11y = JSON.parse(dec.decode(new Uint8Array(ex.memory.buffer, ex.ztk_a11y_ptr(), a11yLen)));
check(a11y.map((n) => n.role).join() === "button,label", "accessible roles");

console.log(`${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
