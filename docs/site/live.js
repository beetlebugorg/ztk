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
// X-ray draws the box of each widget over the window, in the color of
// its geometry manager, and the cells of each grid. Inspect shows the
// path, the class, the manager, and the options of the widget under the
// pointer. A click keeps it, and a change of an option in the table
// configures the widget and writes the option into the line of the
// code that makes the widget. Both read the widgets with winfo, so they
// work for each snippet with no hook in ztk.
//
// The page draws the frames itself (the option loop: false of start()),
// and only while the snippet is on the screen. It measures the CPU time
// of each frame for the line under the window.

const base = new URL("../play/", import.meta.url);
const params = new URLSearchParams(location.search);
const W = 360, H = 240;
const PRE = `wm geometry . ${W}x${H}\n`;
let lib = null;
// The landing page has its own live cards, so the compiled module is
// on globalThis, for one compile on each page.
const load = () => lib ??= (globalThis.ztkDocsModule ??= import(new URL("ztk.js", base).href)
  .then(async (m) => ({ m, module: await m.compileModule(new URL("ztk.wasm", base)) })));

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

// A Tcl list as an array of strings.
export function tclList(s) {
  const out = [];
  const n = s.length;
  const unesc = (c) => (c === "n" ? "\n" : c === "t" ? "\t" : c);
  let i = 0;
  for (;;) {
    while (i < n && /\s/.test(s[i])) i++;
    if (i >= n) return out;
    let w = "";
    if (s[i] === "{") {
      let d = 1, j = i + 1;
      while (j < n && d) {
        if (s[j] === "\\") j++;
        else if (s[j] === "{") d++;
        else if (s[j] === "}") d--;
        j++;
      }
      w = s.slice(i + 1, j - 1);
      i = j;
    } else if (s[i] === '"') {
      i++;
      while (i < n && s[i] !== '"') w += s[i] === "\\" ? unesc(s[++i] ?? "") + (i++, "") : s[i++];
      i++;
    } else {
      while (i < n && !/\s/.test(s[i])) w += s[i] === "\\" ? unesc(s[++i] ?? "") + (i++, "") : s[i++];
    }
    out.push(w);
  }
}

// The widgets of the window, with their boxes in logical pixels from the
// corner of the window, and the cells of each grid.
const WALK = `proc ::ztk_docs_walk {} {
  set x0 [winfo rootx .]; set y0 [winfo rooty .]
  set out {}; set todo [winfo children .]
  while {[llength $todo]} {
    set w [lindex $todo 0]; set todo [lrange $todo 1 end]
    if {[winfo toplevel $w] ne "." || ![winfo ismapped $w]} continue
    set x [expr {[winfo rootx $w] - $x0}]; set y [expr {[winfo rooty $w] - $y0}]
    set m [winfo manager $w]
    lappend out [list w $w [winfo class $w] [expr {$m eq "" ? "-" : $m}] $x $y [winfo width $w] [winfo height $w]]
    if {[llength [grid slaves $w]]} {
      lassign [grid size $w] nc nr
      for {set c 0} {$c < $nc} {incr c} {
        for {set r 0} {$r < $nr} {incr r} {
          lassign [grid bbox $w $c $r] cx cy cw ch
          lappend out [list g $w $c $r [expr {$x + $cx}] [expr {$y + $cy}] $cw $ch]
        }
      }
    }
    set todo [concat [winfo children $w] $todo]
  }
  return $out
}`;
const STRESS_ON = `frame .ztk_stress
place .ztk_stress -x 0 -y 0 -relwidth 1 -relheight 1
for {set i 0} {$i < 1000} {incr i} {
  label .ztk_stress.l$i -text [expr {$i % 10}] -padx 0 -pady 0 -borderwidth 0
  place .ztk_stress.l$i -x [expr {($i % 40) * 9}] -y [expr {($i / 40) * 9.6}]
}
proc ::ztk_stress_tick {n} {
  if {![winfo exists .ztk_stress]} return
  .ztk_stress.l[expr {$n % 1000}] configure -text [expr {($n / 1000) % 10}]
  after 1 [list ::ztk_stress_tick [incr n]]
}
::ztk_stress_tick 0`;
const STRESS_OFF = "destroy .ztk_stress";
const COLORS = { pack: "var(--accent)", grid: "var(--tok-str)", place: "var(--tok-var)", panedwindow: "var(--tok-num)" };

// A Tcl word for a value in the code: bare when it is plain, else in braces.
const word = (v) => (/^[\w.#+:%@,-]+$/.test(v) ? v : /^[^{}\\]*$/.test(v) ? `{${v}}` : quote(v));

const b64 = (s) => btoa(String.fromCharCode(...new TextEncoder().encode(s))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const NAMES = { webgpu: "WebGPU", webgl2: "WebGL 2", cpu: "CPU" };

class Demo {
  constructor(fig) {
    this.fig = fig;
    // The replay player (assets/replay.js) drives the snippet through this.
    fig.ztkDemo = this;
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
    // The theme: the ztk look, or the sizes and colors of Tk on X11.
    const look = document.createElement("select");
    look.title = "The theme of the window";
    look.setAttribute("aria-label", "Theme");
    look.add(new Option("Modern", "modern"));
    look.add(new Option("Classic Tk", "classic"));
    this.theme = params.get("theme") === "classic" ? "classic" : "modern";
    look.value = this.theme;
    look.addEventListener("change", () => { this.theme = look.value; this.run(); });
    bar.appendChild(look);
    const toggle = (text, title, key) => {
      const b = button(text, title, () => {
        this[key] = !this[key];
        b.setAttribute("aria-pressed", String(this[key]));
        if (key === "inspecting" && !this.inspecting) this.pick(null);
        this.overlay();
      });
      // ?xray or ?inspect in the URL turns the mode on for each snippet.
      this[key] = params.has(key === "xray" ? "xray" : "inspect");
      b.setAttribute("aria-pressed", String(this[key]));
    };
    // Stress: 1,000 more labels over the window, and one of them changes
    // in each frame, so each frame draws them all. The line under the
    // window gives the frame time.
    const stress = button("Stress", "Add 1,000 labels that change in each frame, and watch the frame time", () => {
      if (!this.h) return;
      const on = this.h.eval("winfo exists .ztk_stress").result === "1";
      this.h.eval(on ? STRESS_OFF : STRESS_ON);
      stress.setAttribute("aria-pressed", String(!on));
      this.times = [];
    });
    stress.setAttribute("aria-pressed", "false");
    toggle("X-ray", "Show the box of each widget and the cells of each grid", "xray");
    toggle("Inspect", "Point at a widget to see its options; click it to edit them", "inspecting");
    this.hud = document.createElement("span");
    this.hud.className = "ld-hud";
    this.hud.setAttribute("aria-live", "off");
    bar.appendChild(this.hud);
    this.err = this.fig.querySelector(".ld-err");
    this.panel = document.createElement("div");
    this.panel.className = "ld-inspect";
    this.panel.hidden = true;
    this.panel.setAttribute("role", "dialog");
    this.fig.appendChild(this.panel);
    const again = () => this.place();
    addEventListener("scroll", again, { passive: true });
    addEventListener("resize", again, { passive: true });
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
    const pre = h.eval(PRE + (this.theme === "classic" ? "ztk::style theme classic\n" : ""));
    if (!pre.ok) {
      h.destroy();
      frame.remove();
      return this.fail(pre.result);
    }
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
    h.eval(WALK);
    this.layer = document.createElement("div");
    this.layer.className = "ld-layer";
    frame.appendChild(this.layer);
    this.layer.addEventListener("pointermove", (e) => this.hover(e));
    this.layer.addEventListener("pointerleave", () => { this.hot = null; this.overlay(); });
    this.layer.addEventListener("click", (e) => { this.hover(e); this.pick(this.hot); });
    if (this.picked && !h.eval(`winfo exists ${this.picked}`).result.startsWith("1")) this.picked = null;
    this.pick(this.picked);
  }

  // The boxes of the widgets, for X-ray and Inspect.
  boxes() {
    const r = this.h.eval("::ztk_docs_walk");
    if (!r.ok) return [];
    return tclList(r.result).map((x) => {
      const f = tclList(x);
      return f[0] === "w"
        ? { kind: "w", path: f[1], cls: f[2], mgr: f[3], x: +f[4], y: +f[5], w: +f[6], h: +f[7] }
        : { kind: "g", path: f[1], c: +f[2], r: +f[3], x: +f[4], y: +f[5], w: +f[6], h: +f[7] };
    });
  }

  overlay() {
    if (!this.layer) return;
    const on = this.xray || this.inspecting;
    this.layer.classList.toggle("on", on);
    this.layer.classList.toggle("pick", Boolean(this.inspecting));
    this.layer.replaceChildren();
    if (!on) return;
    const k = this.h.canvas.getBoundingClientRect().width / W;
    const add = (b, cls, color) => {
      const d = document.createElement("div");
      d.className = cls;
      d.style.cssText = `left:${b.x * k}px;top:${b.y * k}px;width:${b.w * k}px;height:${b.h * k}px;${color ? `border-color:${color}` : ""}`;
      this.layer.appendChild(d);
      return d;
    };
    const all = this.boxes();
    if (this.xray) {
      for (const b of all) {
        if (b.kind === "g") add(b, "ld-cell");
        else add(b, "ld-box", COLORS[b.mgr] || "var(--text-3)").title = `${b.path} (${b.cls}, ${b.mgr})`;
      }
    }
    for (const path of [this.hot, this.picked]) {
      const b = path && all.find((x) => x.kind === "w" && x.path === path);
      if (b) add(b, path === this.picked ? "ld-hot ld-picked" : "ld-hot").dataset.label = `${b.path} · ${b.cls}`;
    }
  }

  // The smallest widget under the pointer.
  hover(e) {
    if (!this.inspecting) return;
    const r = this.layer.getBoundingClientRect();
    const k = r.width / W;
    const x = (e.clientX - r.left) / k, y = (e.clientY - r.top) / k;
    let best = null;
    for (const b of this.boxes()) {
      if (b.kind !== "w" || x < b.x || y < b.y || x >= b.x + b.w || y >= b.y + b.h) continue;
      if (!best || b.w * b.h <= best.w * best.h) best = b;
    }
    const hot = best ? best.path : null;
    if (hot !== this.hot) { this.hot = hot; this.overlay(); }
  }

  // The table of the options of the picked widget.
  pick(path) {
    this.picked = path;
    this.overlay();
    if (!path || !this.h) { this.panel.hidden = true; return; }
    const ev = (s) => this.h.eval(s);
    const cls = ev(`winfo class ${path}`).result;
    const mgr = ev(`winfo manager ${path}`).result || "none";
    const info = ["pack", "grid", "place"].includes(mgr) ? ev(`${mgr} info ${path}`).result : "";
    const head = document.createElement("div");
    head.className = "ld-ihead";
    head.innerHTML = `<b></b> <span></span>`;
    head.firstChild.textContent = path;
    head.lastChild.textContent = `${cls} · ${mgr} ${info}`;
    const close = document.createElement("button");
    close.type = "button";
    close.className = "ld-iclose";
    close.textContent = "Close";
    close.addEventListener("click", () => this.pick(null));
    head.appendChild(close);
    this.panel.setAttribute("aria-label", `The options of ${path}`);
    const table = document.createElement("table");
    const conf = ev(`${path} configure`);
    for (const row of conf.ok ? tclList(conf.result) : []) {
      const f = tclList(row);
      if (f.length < 5) continue;
      const [opt, , , def, value] = f;
      const tr = table.insertRow();
      tr.insertCell().textContent = opt;
      const td = tr.insertCell();
      const input = document.createElement("input");
      input.value = value;
      input.setAttribute("aria-label", `${path} ${opt}`);
      if (value !== def) tr.className = "set";
      const apply = () => {
        const r = ev(`${path} configure ${opt} ${quote(input.value)}`);
        input.classList.toggle("bad", !r.ok);
        input.title = r.ok ? "" : r.result;
        if (!r.ok) return;
        this.write(path, opt, input.value);
        this.h.frame(performance.now());
        this.overlay();
      };
      input.addEventListener("change", apply);
      if (/^-?\d+(\.\d+)?$/.test(value)) {
        input.type = "number";
        input.addEventListener("input", apply);
      }
      td.appendChild(input);
      if (/^#[0-9a-f]{6}$/i.test(value)) {
        const c = document.createElement("input");
        c.type = "color";
        c.value = value;
        c.setAttribute("aria-label", `${path} ${opt} color`);
        c.addEventListener("input", () => { input.value = c.value; apply(); });
        td.prepend(c);
      }
    }
    this.note = document.createElement("p");
    this.note.className = "ld-note";
    const scroll = document.createElement("div");
    scroll.className = "ld-iscroll";
    scroll.appendChild(table);
    this.panel.replaceChildren(head, this.note, scroll);
    this.panel.hidden = false;
    this.place(true);
  }

  // The panel of Inspect opens beside the picked widget: on its right,
  // else on its left, else under it or over it, on the side with more
  // room, and always inside the viewport. Its height follows its content up to the height of the
  // viewport, and only the option table scrolls. On a screen under 640
  // CSS pixels wide, it is a sheet at the bottom of the viewport.
  // `opening` is true for the first place of a pick.
  place(opening = false) {
    const p = this.panel;
    if (!p || p.hidden || !this.picked || !this.layer) return;
    const lr = this.layer.getBoundingClientRect();
    const k = lr.width / W;
    const b = this.boxes().find((x) => x.kind === "w" && x.path === this.picked);
    const w = b ? { left: lr.left + b.x * k, top: lr.top + b.y * k, right: lr.left + (b.x + b.w) * k, bottom: lr.top + (b.y + b.h) * k } : lr;
    const vw = document.documentElement.clientWidth, vh = innerHeight, m = 8;
    p.classList.toggle("sheet", vw < 640);
    if (vw < 640) {
      p.style.cssText = "";
      // When the panel opens, the page scrolls the widget above the sheet.
      const top = vh - p.offsetHeight;
      if (opening && w.bottom > top - m) scrollBy({ top: w.bottom - top + m, behavior: "instant" });
      return;
    }
    const pw = Math.min(380, vw - 2 * m);
    p.style.cssText = `width:${pw}px;max-height:${vh - 2 * m}px;left:0;top:0`;
    const ph = p.offsetHeight;
    let x = null, y;
    if (w.right + m + pw <= vw - m) x = w.right + m;
    else if (w.left - m - pw >= m) x = w.left - m - pw;
    if (x !== null) {
      y = Math.min(Math.max(m, w.top), vh - m - ph);
    } else {
      x = Math.min(Math.max(m, w.left), vw - m - pw);
      // The side with more room. The panel gets shorter to fit there,
      // and its table scrolls.
      const below = vh - w.bottom - 2 * m, above = w.top - 2 * m;
      if (ph > below && ph > above) {
        p.style.maxHeight = `${Math.max(160, Math.max(below, above))}px`;
      }
      const h = p.offsetHeight;
      if (below >= above) y = Math.min(w.bottom + m, vh - m - h);
      else y = Math.max(m, w.top - m - h);
    }
    p.style.left = `${Math.round(x)}px`;
    p.style.top = `${Math.round(y)}px`;
  }

  // Writes "-opt value" into the line of the code that makes the widget.
  write(path, opt, value) {
    const lines = this.ta.value.split("\n");
    const esc = path.replace(/[.$]/g, "\\$&");
    const at = lines.findIndex((l) => new RegExp(`^\\s*[\\w:]+\\s+${esc}(\\s|$)`).test(l));
    if (at < 0) {
      this.note.textContent = `No line of the code makes ${path} with this path, so the change is only in the window.`;
      return;
    }
    const line = lines[at];
    const m = new RegExp(`(\\s${opt.replace(/-/g, "\\-")}\\s+)(\\{[^}]*\\}|"[^"]*"|[^\\s;]+)`).exec(line);
    lines[at] = m ? line.slice(0, m.index) + m[1] + word(value) + line.slice(m.index + m[0].length) : `${line} ${opt} ${word(value)}`;
    this.ta.value = lines.join("\n");
    this.paint();
    this.note.textContent = `Line ${at + 1} of the code has the change.`;
    // The code has the new value, so a later run keeps it.
    this.first = globals(this.h);
  }

  fail(text) {
    this.err.textContent = text;
    this.err.hidden = false;
    if (this.fig.dataset.live !== "1") this.fig.dataset.live = "failed";
  }

  // The frames: one call of frame() for each animation frame while the
  // snippet is on the screen.
  tick() {
    if (this.raf || !this.visible || !this.h || this.paused) return;
    const loop = (t) => {
      this.raf = 0;
      // A toy sets paused (assets/toys.js).
      if (!this.visible || !this.h || this.paused) return;
      const t0 = performance.now();
      const n = this.h.frame(t);
      if (n >= 0) {
        this.times.push(performance.now() - t0);
        if (this.times.length > 120) this.times.shift();
      }
      if (!this.shown || t - this.shown > 500) {
        this.shown = t;
        this.show();
        if (this.xray || this.inspecting) this.overlay();
      }
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
if (params.has("snippettest")) {
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
      d.ta.value = d.ta.value.replace("no_such_command\n", "");
      // X-ray and Inspect: the boxes, and an option from the table.
      d.xray = true;
      d.overlay();
      out.checks.boxes = d.layer.querySelectorAll(".ld-box").length > 0 ? "yes" : "no";
      const first = d.boxes().find((b) => b.kind === "w");
      d.inspecting = true;
      d.pick(first.path);
      const input = d.panel.querySelector(`input[aria-label="${first.path} -cursor"]`);
      input.value = "hand2";
      input.dispatchEvent(new Event("change"));
      out.checks.cursor = d.h.eval(`${first.path} cget -cursor`).result;
      const stress = [...d.fig.querySelectorAll(".ld-bar button")].find((b) => b.textContent === "Stress");
      stress.click();
      for (let i = 0; i < 5; i++) d.h.frame(performance.now() + i * 16);
      out.checks.stress = d.h.eval("llength [winfo children .ztk_stress]").result;
      stress.click();
      d.theme = "classic";
      await d.run();
      out.checks.classic = d.err.hidden ? d.h.eval("ztk::style theme").result : d.err.textContent;
      d.theme = "modern";
      out.checks.written = d.ta.value.includes("-cursor hand2") || d.note.textContent.startsWith("No line") ? "yes" : "no";
    }
    const pre = document.createElement("pre");
    pre.id = "result";
    pre.textContent = JSON.stringify(out);
    document.body.appendChild(pre);
  })();
} else if (!params.has("livetest") && typeof WebAssembly === "object" && "IntersectionObserver" in window) {
  // ?livetest is the test of the cards of the landing page (tests/site.sh),
  // so the snippets stay still there.
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
