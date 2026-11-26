// SPDX-License-Identifier: BSD-2-Clause
// The build core of "Download your app" (download.js): a copy of the ztk
// program of a target with the app in its slot (src/appbin.zig). It runs
// in a second instance of ztk.wasm, so a build does not touch the window
// of the page.
import { compileModule } from "./ztk.js";

let ex = null;

async function core() {
  if (ex) return ex;
  const instance = await WebAssembly.instantiate(await compileModule(), {
    env: { ztk_now_ms: () => 0, ztk_print: () => {} },
  });
  ex = instance.exports;
  return ex;
}

// Copies bytes into the memory of the module. Gives the address.
function put(bytes) {
  const p = ex.ztk_alloc(bytes.length || 1);
  if (!p) throw new Error("the build is out of memory");
  new Uint8Array(ex.memory.buffer, p, bytes.length).set(bytes);
  return p;
}

// files maps each name to a string or a Uint8Array. main is the name of
// the main script. Gives the bytes of the program file.
export async function build({ runtime, files, main, target, allow = "file,channels" }) {
  await core();
  const enc = new TextEncoder();
  const bytes = (v) => (typeof v === "string" ? enc.encode(v) : v);
  const names = [main, ...Object.keys(files).filter((n) => n !== main)];
  const held = [];
  const hold = (b) => {
    const p = put(b);
    held.push([p, b.length || 1]);
    return p;
  };
  ex.ztk_build_reset();
  try {
    for (const n of names) {
      const nb = enc.encode(n);
      const data = bytes(files[n]);
      if (!ex.ztk_build_add(hold(nb), nb.length, hold(data), data.length)) throw new Error("the build is out of memory");
    }
    const ab = enc.encode(allow);
    const id = enc.encode(main.replace(/\.tcl$/, "") || "app");
    const code = ex.ztk_build(hold(runtime), runtime.length, hold(ab), ab.length, hold(id), id.length);
    const out = new Uint8Array(ex.memory.buffer, ex.ztk_build_ptr(), ex.ztk_build_len()).slice();
    if (code !== 0) throw new Error(`${target}: ${new TextDecoder().decode(out)}`);
    return out;
  } finally {
    for (const [p, n] of held) ex.ztk_free(p, n);
    ex.ztk_build_reset();
  }
}
