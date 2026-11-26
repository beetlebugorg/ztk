// SPDX-License-Identifier: BSD-2-Clause
// The toys of the widget pages (ztk issue 175). A toy is a live snippet
// (docs/site/live.js) whose name starts with "toy-". This file puts the
// window of the toy in a small handheld of our own design, with a pad,
// two buttons, a light, and a sound switch, and lets a ball of the game
// leave the screen and play on the page.
//
// The Tcl code of a toy keeps the array `toy`:
//   toy(spill)  1 when the page lets a ball leave the screen. This file sets it.
//   toy(out)    {x y vx vy ?gravity?} of a ball that left the screen, in
//               pixels of the window and pixels for each frame. This file
//               reads and clears it.
//   toy(back)   {x vx vy hits} of the ball when it comes back at the top
//               of the screen, with the count of walls that it hit. This
//               file sets it.
//   toy(sfx)    a list of sound names: hit, wall, smash, point.
// and the proc `toy_press KEY` for the keys up, down, a, and b of the pad.
//
// On the page, the ball is a square on a canvas layer over the document.
// The headings, the code blocks, the tables, the images, and the edges
// of the window are walls: the layer reads their boxes once in each
// frame while a ball is out. A wall that the ball hits gets a glow on the
// layer. The page text does not change. After 7 seconds, or at Escape, a
// scroll, or the end of the toy, the ball goes back into the screen and
// the layer goes away, so the page is as it was.
//
// Nothing starts by itself: the game waits for a key of the reader. The
// ball leaves the screen only when "Play on the page" is on, and that
// switch is off with reduced motion. The sound is off until the reader
// turns it on. The poll of the game runs only while the toy is on the
// screen.

const reduced = matchMedia("(prefers-reduced-motion: reduce)");
const W = 360;

// The handheld of the Toys page (figure.toy-console) starts with a game
// list, a Tcl script that sets toy(pick) to the name of a game. The page
// then puts the code of that game, from a hidden pre of the figure, into
// the editor and runs it in the same handheld. Menu or Escape puts the
// list back. The query `?game=SLUG` of the address keeps the game.

// The keys. A click anywhere on the handheld gives the keyboard focus to
// the hidden input of the window, and the device shows a focus ring.
// The game gets the arrow keys, Space, and Return as its own key events.
// W and S press Up and Down of the pad, A and D press B and A, Z and J
// press A, and X and K press B. P pauses the game, and Escape gives the
// focus back to the page. While the device has the focus, a key that the
// game uses does not scroll the page. A letter goes to the game as text
// when its focus widget is an entry or a text widget. Tab moves the
// focus as on any page.
const PAD_KEYS = { w: "up", s: "down", z: "a", j: "a", x: "b", k: "b" };
// A and D are the Left and Right arrows, for the games that use them.
const SIDE_KEYS = { a: "Left", d: "Right" };
const GAME_KEYS = new Set(["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", " ", "Enter"]);

// The palette of the toys and a pixel square: the shared helper.
export const INK = { night: "#1d1a33", paper: "#f2e6c4", red: "#ef5b5b", gold: "#ffcf5c", dusk: "#3a3560" };
export function pixel(g, x, y, size, color) {
  g.fillStyle = color;
  g.fillRect(Math.round(x), Math.round(y), size, size);
}

// Sound made at run time: a square wave for a hit and noise for a wall.
let audio = null;
function sound(name) {
  audio ??= new AudioContext();
  const t = audio.currentTime;
  const gain = audio.createGain();
  gain.gain.setValueAtTime(0.06, t);
  gain.gain.exponentialRampToValueAtTime(0.001, t + (name === "point" ? 0.3 : 0.08));
  gain.connect(audio.destination);
  if (name === "wall") {
    const buf = audio.createBuffer(1, 2048, audio.sampleRate);
    const d = buf.getChannelData(0);
    for (let i = 0; i < d.length; i++) d[i] = Math.random() * 2 - 1;
    const src = audio.createBufferSource();
    src.buffer = buf;
    src.connect(gain);
    src.start(t);
    return;
  }
  const osc = audio.createOscillator();
  osc.type = "square";
  osc.frequency.setValueAtTime({ hit: 440, smash: 660, point: 220 }[name] ?? 330, t);
  if (name === "smash") osc.frequency.exponentialRampToValueAtTime(1320, t + 0.08);
  osc.connect(gain);
  osc.start(t);
  osc.stop(t + 0.3);
}

const parse = (s) => s.trim() ? s.trim().split(/\s+/).map(Number) : [];

class Toy {
  constructor(fig) {
    this.fig = fig;
    this.sound = false;
    this.ball = null;
    this.visible = false;
    fig.classList.add("toy");
    this.device();
    new IntersectionObserver((e) => {
      this.visible = e.some((x) => x.isIntersecting);
      if (!this.visible) this.end();
      else this.poll();
    }).observe(fig.querySelector(".ld-view"));
    addEventListener("keydown", (e) => { if (e.key === "Escape") this.end(); });
    this.keys();
    addEventListener("wheel", () => this.end(), { passive: true });
    addEventListener("touchmove", () => this.end(), { passive: true });
  }

  get h() {
    return this.fig.ztkDemo?.h ?? null;
  }

  eval(script) {
    try {
      return this.h?.eval(script) ?? null;
    } catch {
      return null;
    }
  }

  get input() {
    return this.fig.querySelector(".ld-view .ld-frame textarea");
  }

  focus() {
    this.input?.focus({ preventScroll: true });
  }

  keys() {
    const view = this.fig.querySelector(".ld-view");
    view.addEventListener("pointerdown", (e) => {
      if (e.target.closest(".toy-switches")) return;
      // The canvas focuses the input itself, after this handler.
      if (e.target.tagName !== "CANVAS") requestAnimationFrame(() => this.focus());
    });
    const map = document.createElement("p");
    map.className = "toy-keys";
    map.textContent = "Keys: arrows or W A S D, Z or J for A, X or K for B, P pauses, Escape leaves.";
    view.querySelector(".toy-pad").appendChild(map);
    view.addEventListener("keydown", (e) => {
      if (!this.input || e.target !== this.input || e.ctrlKey || e.metaKey || e.altKey) return;
      const key = e.key.length === 1 ? e.key.toLowerCase() : e.key;
      if (key === "Escape") {
        this.input.blur();
        return;
      }
      if (!GAME_KEYS.has(key) && key !== "p" && !PAD_KEYS[key] && !SIDE_KEYS[key]) return;
      const cls = this.eval("winfo class [focus]")?.result;
      if (cls === "Entry" || cls === "Text" || cls === "TEntry") return;
      if (GAME_KEYS.has(key)) {
        e.preventDefault();
        return;
      }
      e.preventDefault();
      e.stopImmediatePropagation();
      if (key === "p") return this.pause();
      if (this.paused) this.pause();
      if (SIDE_KEYS[key]) this.eval(`ztk::inject . key ${SIDE_KEYS[key]}`);
      else this.eval(`toy_press ${PAD_KEYS[key]}`);
      this.poll();
    }, true);
  }

  // P: the frames of the game stop, and the screen shows PAUSED.
  pause() {
    const d = this.fig.ztkDemo;
    if (!d) return;
    this.paused = !this.paused;
    d.paused = this.paused;
    this.fig.classList.toggle("toy-paused", this.paused);
    if (!this.paused) d.tick();
  }

  // The handheld: the pad, two buttons, the light, and the switches.
  device() {
    const pad = document.createElement("div");
    pad.className = "toy-pad";
    const menu = this.fig.classList.contains("toy-console")
      ? `<button type="button" class="toy-menu" aria-label="Menu: the game list">MENU</button>` : "";
    pad.innerHTML = `<span class="toy-led" aria-hidden="true"></span>
<span class="toy-dpad"><button type="button" data-key="up" aria-label="Up">▲</button><button type="button" data-key="down" aria-label="Down">▼</button></span>
<span class="toy-brand"><span aria-hidden="true">ZTK·PLAY</span>${menu}</span>
<span class="toy-ab"><button type="button" data-key="b" aria-label="Button B">B</button><button type="button" data-key="a" aria-label="Button A">A</button></span>
<span class="toy-switches"><label><input type="checkbox" class="toy-spill"> Play on the page</label><label><input type="checkbox" class="toy-sound"> Sound</label></span>`;
    this.fig.querySelector(".ld-view").appendChild(pad);
    const spill = pad.querySelector(".toy-spill");
    spill.checked = !reduced.matches;
    spill.disabled = reduced.matches;
    this.spill = spill;
    reduced.addEventListener("change", () => {
      spill.disabled = reduced.matches;
      if (reduced.matches) spill.checked = false;
    });
    pad.querySelector(".toy-sound").addEventListener("change", (e) => { this.sound = e.target.checked; });
    const press = Object.fromEntries(["up", "down", "a", "b"].map((k) => [k, `toy_press ${k}`]));
    for (const b of pad.querySelectorAll("button[data-key]")) {
      let rep = 0;
      const stop = () => clearInterval(rep);
      b.addEventListener("pointerdown", (e) => {
        e.preventDefault();
        this.eval(press[b.dataset.key]);
        this.poll();
        if (b.dataset.key === "up" || b.dataset.key === "down") rep = setInterval(() => this.eval(press[b.dataset.key]), 60);
      });
      b.addEventListener("click", (e) => { if (e.detail === 0) { this.eval(press[b.dataset.key]); this.poll(); } });
      for (const ev of ["pointerup", "pointerleave", "pointercancel"]) b.addEventListener(ev, stop);
    }
  }

  // One read of the game in each frame while the toy is on the screen.
  poll() {
    if (this.polling || !this.visible) return;
    this.polling = true;
    const step = () => {
      if (!this.visible) { this.polling = false; return; }
      const r = this.eval(`set ::toy(spill) ${this.spill.checked ? 1 : 0}; apply {{} {set r "$::toy(out)|$::toy(sfx)|[expr {[info exists ::toy(pick)] ? $::toy(pick) : {}}]"; set ::toy(out) {}; set ::toy(sfx) {}; set ::toy(pick) {}; return $r}}`);
      const m = r?.result?.split("|");
      if (m?.length === 3) {
        if (m[2]) this.picked?.(m[2]);
        if (this.sound) for (const s of m[1].split(/\s+/).filter(Boolean)) sound(s);
        const out = parse(m[0]);
        if (out.length >= 4 && !this.ball) this.launch(out);
      }
      this.fig.classList.toggle("toy-on", Boolean(this.h));
      requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  }

  screen() {
    return this.h?.canvas?.getBoundingClientRect() ?? null;
  }

  launch([x, y, vx, vy, gravity = 0]) {
    const r = this.screen();
    if (!r) return;
    const k = r.width / W;
    const layer = document.createElement("canvas");
    layer.className = "toy-layer";
    layer.setAttribute("aria-hidden", "true");
    document.body.appendChild(layer);
    this.ball = { x: r.left + x * k, y: r.top + y * k, vx: vx * k, vy: vy * k, size: Math.max(6, Math.round(8 * k)), gravity: gravity * k, count: 0, t0: performance.now(), trail: [], hits: new Map(), layer, home: false };
    const step = (now) => {
      if (!this.ball) return;
      this.move(now);
      if (this.ball) requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  }

  walls() {
    const own = this.fig;
    return [...document.querySelectorAll("main h1, main h2, main h3, main pre, main table, main img, main .ld-code")]
      .filter((e) => !own.contains(e))
      .map((e) => [e, e.getBoundingClientRect()])
      .filter(([, b]) => b.width > 0 && b.bottom > 0 && b.top < innerHeight);
  }

  move(now) {
    const b = this.ball;
    const dpr = devicePixelRatio || 1;
    const L = b.layer;
    if (L.width !== Math.round(innerWidth * dpr)) { L.width = Math.round(innerWidth * dpr); L.height = Math.round(innerHeight * dpr); }
    const s = b.size;
    const r = this.screen();
    if (!r) return this.end();
    // After 7 seconds the ball steers to the top of the screen.
    if (now - b.t0 > 7000) b.home = true;
    if (b.home) {
      const tx = r.left + r.width / 2, ty = r.top - s;
      const dx = tx - b.x, dy = ty - b.y, d = Math.hypot(dx, dy);
      const sp = Math.max(10, Math.min(24, d / 20));
      if (d < sp) return this.end();
      b.vx = dx / d * sp;
      b.vy = dy / d * sp;
    }
    if (!b.home) b.vy += b.gravity;
    let nx = b.x + b.vx, ny = b.y + b.vy;
    if (!b.home && (nx < 0 || nx + s > innerWidth)) { b.vx = -b.vx; nx = b.x; }
    if (!b.home && (ny < 0 || ny + s > innerHeight)) { b.vy = -b.vy * (b.gravity ? 0.85 : 1); ny = b.y; }
    if (!b.home) {
      for (const [el, w] of this.walls()) {
        if (nx + s < w.left || nx > w.right || ny + s < w.top || ny > w.bottom) continue;
        // Reflect on the side with the smallest overlap.
        const ox = Math.min(nx + s - w.left, w.right - nx), oy = Math.min(ny + s - w.top, w.bottom - ny);
        if (ox < oy) { b.vx = -b.vx; nx = b.x; } else { b.vy = -b.vy; ny = b.y; }
        if (!b.hits.has(el)) b.count++;
        b.hits.set(el, now);
        if (this.sound) sound("wall");
        break;
      }
    }
    b.trail.unshift([b.x, b.y]);
    b.trail.length = Math.min(b.trail.length, 4);
    b.x = nx;
    b.y = ny;
    const g = L.getContext("2d");
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    g.clearRect(0, 0, innerWidth, innerHeight);
    for (const [el, t] of b.hits) {
      const age = (now - t) / 400;
      if (age > 1) { b.hits.delete(el); continue; }
      const w = el.getBoundingClientRect();
      g.globalAlpha = 1 - age;
      g.strokeStyle = INK.gold;
      g.lineWidth = 3;
      g.strokeRect(Math.round(w.left) - 2, Math.round(w.top) - 2, Math.round(w.width) + 4, Math.round(w.height) + 4);
    }
    b.trail.forEach(([tx, ty], i) => { g.globalAlpha = 0.5 - i * 0.12; pixel(g, tx, ty, s, INK.red); });
    g.globalAlpha = 1;
    pixel(g, b.x, b.y, s, INK.gold);
  }

  // The ball goes back into the screen, and the layer goes away.
  end() {
    const b = this.ball;
    if (!b) return;
    this.ball = null;
    b.layer.remove();
    const r = this.screen();
    const k = r ? r.width / W : 1;
    const x = r ? Math.min(Math.max((b.x - r.left) / k, 40), 320) : 180;
    this.eval(`set ::toy(back) {${Math.round(x)} ${Math.max(2, Math.abs(b.vx / k) / 2).toFixed(2)} 2 ${b.count}}`);
  }
}

// The handheld of the Toys page: the game list, and then a game.
class Console extends Toy {
  constructor(fig) {
    super(fig);
    this.games = new Map([...fig.querySelectorAll("pre.toy-game")].map((p) => [p.dataset.name.slice(4), p]));
    this.status = fig.querySelector(".toy-status");
    this.link = fig.querySelector(".toy-page");
    this.img = fig.querySelector(".ld-frame img");
    this.source = fig.querySelector(".ld-frame source");
    this.menuShot = [this.img?.src, this.source?.srcset];
    // assets/live.js can run before or after this file.
    this.list = this.demo?.original ?? fig.querySelector(".ld-code code").textContent;
    fig.querySelector(".toy-menu").addEventListener("click", () => this.home());
    addEventListener("keydown", (e) => {
      if (e.key === "Escape" && this.game && !fig.querySelector(".ld-code").contains(e.target)) this.home();
    });
    const slug = new URLSearchParams(location.search).get("game");
    const game = [...this.games.values()].find((p) => p.dataset.slug === slug);
    if (game) this.show(game, false);
  }

  get demo() {
    return this.fig.ztkDemo;
  }

  // toy(pick) of the list: the name of a game without "toy-".
  picked(name) {
    const game = this.games.get(name);
    if (game) this.show(game, true);
  }

  // Puts the code of a game, or the list when `game` is null, in the
  // editor, and runs it when the handheld is live.
  load(code, live) {
    const d = this.demo;
    if (!d) {
      this.fig.querySelector(".ld-code code").textContent = code;
      return;
    }
    d.original = code;
    d.ta.value = code;
    d.paint();
    d.first = null;
    if (!live) return;
    // A run makes a new canvas and a new input. The keys stay with the
    // handheld when it had them.
    const keep = this.fig.querySelector(".ld-view").contains(document.activeElement);
    Promise.resolve(d.run(true)).then(() => { if (keep) this.focus(); });
  }

  show(game, live) {
    this.game = game;
    this.load(game.textContent, live);
    if (this.img) {
      this.img.src = `${game.dataset.shot}-light.png`;
      this.img.alt = `The game ${game.dataset.title} before it runs`;
    }
    if (this.source) this.source.srcset = `${game.dataset.shot}-dark.png`;
    this.link.href = game.dataset.page;
    this.link.textContent = `Play ${game.dataset.title} on its widget page`;
    this.link.hidden = false;
    this.status.textContent = `${game.dataset.title}. Menu or Escape goes back to the game list.`;
    const url = new URL(location.href);
    url.searchParams.set("game", game.dataset.slug);
    history.replaceState(null, "", url);
  }

  home() {
    if (!this.game) return;
    this.game = null;
    this.end();
    this.load(this.list, true);
    if (this.img) [this.img.src, this.img.alt] = [this.menuShot[0], "The game list of the handheld"];
    if (this.source) this.source.srcset = this.menuShot[1];
    this.link.hidden = true;
    this.status.textContent = "The game list.";
    const url = new URL(location.href);
    url.searchParams.delete("game");
    history.replaceState(null, "", url);
  }
}

for (const fig of document.querySelectorAll('figure.live-demo[data-name^="toy-"]')) {
  if (fig.classList.contains("toy-console")) new Console(fig);
  else new Toy(fig);
}
