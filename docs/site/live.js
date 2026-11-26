// SPDX-License-Identifier: BSD-2-Clause
// The live snippets of the docs pages (docs/dev/interactive-docs.md).
// tools/build-docs.py writes a <figure class="live-demo"> for each
// marked `tcl` block: the code in a pre, and the screenshot of the
// widget. This file makes the code an editor at once, with a text area
// over a highlighted copy of the code. It loads the web build
// (play/ztk.js and play/ztk.wasm) only when a snippet comes near the
// viewport, compiles the module one time for the page, and gives each
// snippet its own instance. The screenshot stays until the first frame,
// and it stays when a step fails.
//
// The window runs the code again 300 ms after the last key. The page
// reads the global variables after each run. A variable that has the
// same first value in the old code and in the new code gets the value
// of the old window, so a check button keeps its state. An error shows
// under the code, and the last good window stays.
//
// The page draws the frames itself (the option loop: false of start()),
// and only while the snippet is on the screen. It measures the CPU time
// of each frame for the line under the window.

const base = new URL("../play/", import.meta.url);
const params = new URLSearchParams(location.search);
const W = 360, H = 240;
const PRE = `wm geometry . ${W}x${H}\n`;
let lib = null;
const load = () => lib ??= import(new URL("ztk.js", base).href)
  .then(async (m) => ({ m, module: await m.compileModule(new URL("ztk.wasm", base)) }));

// The highlighter. It marks comments, strings, variables, numbers,
// options, and the first word of each command, with the token classes
// of site.css.
const esc = (s) => s.replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" })[c]);
const span = (cls, s) => `<span class="${cls}">${esc(s)}</span>`;
export function highlight(src) {
  let out = "", i = 0, start = true;
  const n = src.length;
  const wordStart = () => i === 0 || /[\s{[;]/.test(src[i - 1]);
  while (i < n) {
    const ch = src[i];
    if (start && ch === "#") {
      let j = src.indexOf("\n", i);
      if (j < 0) j = n;
      out += span("c", src.slice(i, j)); i = j; continue;
    }
    if (ch === "\n" || ch === ";" || ch === "[" || ch === "{") { out += esc(ch); i++; start = true; continue; }
    if (ch === " " || ch === "\t") { out += ch; i++; continue; }
    if (ch === '"') {
      let j = i + 1;
      while (j < n && src[j] !== '"') j += src[j] === "\\" ? 2 : 1;
      out += span("s", src.slice(i, j + 1)); i = j + 1; start = false; continue;
    }
    if (ch === "$") {
      const m = /^\$(\{[^}]*\}|[\w:]+(\([^)\s]*\))?)/.exec(src.slice(i));
      if (m) { out += span("v", m[0]); i += m[0].length; start = false; continue; }
    }
    if (wordStart()) {
      const m = /^[^\s;{}[\]"$]+/.exec(src.slice(i));
      if (m) {
        const w = m[0];
        const cls = start ? "k" : /^-[a-z]/.test(w) ? "o" : /^-?\d+(\.\d+)?$/.test(w) ? "n" : null;
        out += cls ? span(cls, w) : esc(w);
        i += w.length; start = false; continue;
      }
    }
    if (ch === "\\" && i + 1 < n) { out += esc(src.slice(i, i + 2)); i += 2; continue; }
    out += esc(ch); i++; start = false;
  }
  return out;
}

// A Tcl word for any text: each special character gets a backslash.
const quote = (s) => s === "" ? "{}" : s.replace(/[\\$[\]{}"; \t]/g, (c) => "\\" + c).replace(/\n/g, "\\n");
const SKIP = new Set(["env", "argv", "argc", "argv0", "auto_path", "errorInfo", "errorCode"]);
// The global variables of a window: name -> ["s" or "a", value].
function globals(h) {
  const out = new Map();
  const r = h.eval("info globals");
  if (!r.ok) return out;
  for (const v of r.result.split(/\s+/)) {
    if (!/^[\w:]+$/.test(v) || v.startsWith("tcl") || SKIP.has(v)) continue;
    const a = h.eval(`array exists ::${v}`);
    const kind = a.ok && a.result === "1" ? "a" : "s";
    const g = h.eval(kind === "a" ? `array get ::${v}` : `set ::${v}`);
    if (g.ok) out.set(v, [kind, g.result]);
  }
  return out;
}

const b64 = (s) => btoa(String.fromCharCode(...new TextEncoder().encode(s))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const NAMES = { webgpu: "WebGPU", webgl2: "WebGL 2", cpu: "CPU" };

class Demo {
  constructor(fig) {
    this.fig = fig;
    this.name = fig.dataset.name || fig.id;
    this.original = fig.querySelector(".ld-code code").textContent;
    this.h = null;
    this.first = null;
    this.visible = false;
    this.times = [];
    this.renderer = params.get("renderer") || "auto";
    this.editor();
    this.toolbar();
  }

  editor() {
    const box = this.fig.querySelector(".ld-code");
    const hl = document.createElement("pre");
    hl.className = "ld-hl";
    hl.setAttribute("aria-hidden", "true");
    const ta = document.createElement("textarea");
    ta.spellcheck = false;
    ta.autocapitalize = "off";
    ta.setAttribute("autocorrect", "off");
    ta.setAttribute("aria-label", `The Tcl code of the demo ${this.name}. Tab puts in four spaces; press Escape and then Tab to leave.`);
    ta.value = this.original;
    box.replaceChildren(hl, ta);
    this.hl = hl;
    this.ta = ta;
    this.paint();
    let timer = 0, tabOut = false;
    ta.addEventListener("input", () => {
      this.paint();
      clearTimeout(timer);
      timer = setTimeout(() => this.run(), 300);
    });
    ta.addEventListener("keydown", (e) => {
      if (e.key === "Escape") { tabOut = true; return; }
      if (e.key === "Tab" && !tabOut && !e.shiftKey) {
        e.preventDefault();
        document.execCommand("insertText", false, "    ");
      }
      tabOut = false;
    });
  }

  paint() {
    // A pre drops a last empty line, so the copy gets one more space.
    this.hl.innerHTML = highlight(this.ta.value) + " ";
  }

  toolbar() {
    const bar = this.fig.querySelector(".ld-bar");
    const button = (text, title, f) => {
      const b = document.createElement("button");
      b.type = "button";
      b.textContent = text;
      b.title = title;
      b.addEventListener("click", f);
      bar.appendChild(b);
      return b;
    };
    button("Reset", "Put back the code of the page", () => {
      this.ta.value = this.original;
      this.paint();
      this.first = null;
      this.run();
    });
    const play = document.createElement("a");
    play.textContent = "Playground";
    play.title = "Open this code in the playground";
    play.addEventListener("pointerdown", () => { play.href = this.link(); });
    play.addEventListener("focus", () => { play.href = this.link(); });
    play.href = this.link();
    bar.appendChild(play);
    const share = button("Copy link", "Copy a link to this code in the playground", async () => {
      try {
        await navigator.clipboard.writeText(this.link());
        share.textContent = "Copied";
      } catch {
        share.textContent = "No clipboard";
      }
      setTimeout(() => { share.textContent = "Copy link"; }, 1500);
    });
    const pick = document.createElement("select");
    pick.title = "The renderer of the window";
    pick.setAttribute("aria-label", "Renderer");
    for (const v of ["auto", "webgpu", "webgl2", "cpu"]) pick.add(new Option(v === "auto" ? "Auto" : NAMES[v], v));
    pick.value = this.renderer;
    pick.addEventListener("change", () => { this.renderer = pick.value; this.run(true); });
    bar.appendChild(pick);
    this.hud = document.createElement("span");
    this.hud.className = "ld-hud";
    this.hud.setAttribute("aria-live", "off");
    bar.appendChild(this.hud);
    this.err = this.fig.querySelector(".ld-err");
  }

  link() {
    return new URL(`index.html#code=${b64(this.ta.value)}`, base).href;
  }

  // Runs the code in a new instance. The new window replaces the old one
  // only when the code ran with no error. `fresh` drops the state.
  async run(fresh = false) {
    const seq = (this.seq = (this.seq || 0) + 1);
    this.fig.dataset.live = this.fig.dataset.live === "1" ? "1" : "loading";
    let m, module;
    try {
      ({ m, module } = await load());
    } catch (e) {
      return this.fail(`The web build did not load: ${e.message}`);
    }
    const view = this.fig.querySelector(".ld-view");
    const frame = document.createElement("div");
    frame.className = "ld-frame";
    const canvas = document.createElement("canvas");
    canvas.setAttribute("aria-label", `The demo ${this.name}, running live`);
    const shown = view.querySelector(".ld-frame").getBoundingClientRect().width || W;
    canvas.style.width = shown + "px";
    canvas.style.height = (shown * H) / W + "px";
    frame.appendChild(canvas);
    frame.style.cssText = "position:absolute;visibility:hidden";
    view.appendChild(frame);
    let h;
    try {
      const opts = { module, width: W, height: H, loop: false, renderer: this.renderer };
      if (params.get("livescale")) opts.scale = Number(params.get("livescale"));
      h = await m.start(canvas, opts);
    } catch (e) {
      frame.remove();
      return this.fail(e.message);
    }
    if (seq !== this.seq) { h.destroy(); frame.remove(); return; }
    h.eval(PRE);
    const r = h.eval(this.ta.value);
    if (!r.ok) {
      const info = h.eval("set ::errorInfo");
      h.destroy();
      frame.remove();
      return this.fail(info.ok && info.result ? info.result : r.result);
    }
    const first = globals(h);
    if (this.h && !fresh && this.first) {
      const now = globals(this.h);
      for (const [v, [kind, value]] of now) {
        const a = this.first.get(v), b = first.get(v);
        if (!a || !b || a[0] !== kind || a[1] !== b[1] || a[1] === value) continue;
        h.eval(kind === "a" ? `array set ::${v} ${quote(value)}` : `set ::${v} ${quote(value)}`);
      }
    }
    this.first = first;
    h.frame(performance.now());
    this.h?.destroy();
    view.querySelector(".ld-frame").remove();
    frame.style.cssText = "";
    this.h = h;
    this.times = [];
    this.err.hidden = true;
    this.err.textContent = "";
    this.fig.dataset.live = "1";
    this.fig.dataset.renderer = h.renderer;
    this.tick();
  }

  fail(text) {
    this.err.textContent = text;
    this.err.hidden = false;
    if (this.fig.dataset.live !== "1") this.fig.dataset.live = "failed";
  }

  // The frames: one call of frame() for each animation frame while the
  // snippet is on the screen.
  tick() {
    if (this.raf || !this.visible || !this.h) return;
    const loop = (t) => {
      this.raf = 0;
      if (!this.visible || !this.h) return;
      const t0 = performance.now();
      const n = this.h.frame(t);
      if (n >= 0) {
        this.times.push(performance.now() - t0);
        if (this.times.length > 120) this.times.shift();
      }
      if (!this.shown || t - this.shown > 500) { this.shown = t; this.show(); }
      this.raf = requestAnimationFrame(loop);
    };
    this.raf = requestAnimationFrame(loop);
  }

  show() {
    const name = NAMES[this.h.renderer] || this.h.renderer;
    const ts = [...this.times].sort((a, b) => a - b);
    if (!ts.length) { this.hud.textContent = name; return; }
    const mean = ts.reduce((a, b) => a + b, 0) / ts.length;
    const p99 = ts[Math.min(ts.length - 1, Math.floor(ts.length * 0.99))];
    this.hud.textContent = `${name} · frame ${mean.toFixed(2)} ms, p99 ${p99.toFixed(2)} ms`;
    this.hud.title = `The CPU time of the last ${ts.length} frames that drew`;
  }
}

const demos = [...document.querySelectorAll("figure.live-demo")].map((f) => new Demo(f));
const touch = matchMedia("(pointer: coarse)").matches;
if (params.has("livetest")) {
  // The test of tests/site.sh: each demo goes live, then the first demo
  // gets an edit and a run with the state of its old window.
  window.ztkLiveDocs = (async () => {
    for (const d of demos) { d.visible = true; await d.run(); }
    const out = { live: demos.map((d) => `${d.name}:${d.fig.dataset.live}`), png: {}, checks: {} };
    // The transitions of the first frames end before the snapshots.
    await new Promise((r) => setTimeout(r, 1500));
    for (const d of demos) if (d.h) {
      out.png[d.name] = d.h.snapshot();
    }
    const d = demos[0];
    if (d?.h) {
      d.ta.value += "\nset ld_probe 1\n";
      await d.run();
      d.h.eval("set ::ld_probe 2");
      d.ta.value += "set ld_new 5\n";
      await d.run();
      out.checks.kept = d.h.eval("set ::ld_probe").result;
      out.checks.added = d.h.eval("set ::ld_new").result;
      d.ta.value = d.ta.value.replace("set ld_probe 1", "set ld_probe 3");
      await d.run();
      out.checks.changed = d.h.eval("set ::ld_probe").result;
      d.ta.value += "no_such_command\n";
      await d.run();
      out.checks.error = d.err.hidden ? "" : d.err.textContent.split("\n")[0];
      out.checks.stayed = d.h.eval("set ::ld_new").result;
    }
    const pre = document.createElement("pre");
    pre.id = "result";
    pre.textContent = JSON.stringify(out);
    document.body.appendChild(pre);
  })();
} else if (typeof WebAssembly === "object" && "IntersectionObserver" in window) {
  const io = new IntersectionObserver((es) => {
    for (const e of es) {
      const d = demos.find((x) => x.fig === e.target);
      d.visible = e.isIntersecting;
      if (!d.visible) continue;
      if (d.h) d.tick();
      else if (!touch && !d.fig.dataset.live) d.run();
    }
  }, { rootMargin: "200px" });
  for (const d of demos) {
    io.observe(d.fig);
    // On a touch screen a snippet starts at the first tap or edit, to save power.
    d.fig.querySelector(".ld-view").addEventListener("click", () => { if (!d.fig.dataset.live) d.run(); });
  }
}
