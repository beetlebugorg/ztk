// SPDX-License-Identifier: BSD-2-Clause
// The games of the Toys page and the landing page (ztk issue 175). A
// game is a live snippet (assets/live.js) whose name starts with "toy-".
// This file puts the window of the game in a closed frame, routes the
// input of the reader to the game, and plays its sound.
//
// The frame. The game renders only inside its box: the frame clips its
// content, and nothing of the game goes on the page. The game gets no
// key, no wheel, and no touch until the reader clicks the cover or
// presses Enter on it. A ring then shows that the game has the keys.
// Escape, a click outside, or a scroll of the page off the frame gives
// them back and pauses the game. The wheel always scrolls the page.
//
// The Tcl code of a game keeps the array `toy`, and this file reads it
// once in each frame:
//   toy(sfx)    a list of effect names (assets/toysound.js). This file
//               clears it.
//   toy(music)  the part of the song: title, play, or empty.
//   toy(save)   a string that the game keeps between visits, such as its
//               best scores and its open levels. This file stores it in
//               localStorage and gives it back with `toy_restore`.
//   toy(calm)   1 when the reader turns off the screen shake. This file
//               sets it.
// The game has the proc `toy_input NAME STATE`: NAME is left, right,
// up, down, a, b, or start, and STATE is press or release. The keys,
// the buttons of a gamepad, and the touch buttons all come here, so the
// game needs no key binding of its own.

import { Sound } from "./toysound.js";

const sound = new Sound();
const STORE = "ztk-toys:";
const store = {
  get(k) { try { return localStorage.getItem(STORE + k); } catch { return null; } },
  set(k, v) { try { localStorage.setItem(STORE + k, v); } catch { /* private mode */ } },
};
const prefs = { fx: store.get("fx") === "1", music: store.get("music") === "1", calm: store.get("calm") === "1" };

// The keys of the keyboard and their inputs.
const KEYS = {
  ArrowLeft: "left", ArrowRight: "right", ArrowUp: "up", ArrowDown: "down",
  a: "left", d: "right", w: "up", s: "down",
  " ": "a", z: "a", j: "a", x: "b", k: "b", Enter: "start",
};
// The buttons of a standard gamepad: A, B, Start, and the d-pad.
const PAD = { 0: "a", 1: "b", 9: "start", 12: "up", 13: "down", 14: "left", 15: "right" };
const quote = (s) => "{" + String(s).replace(/[{}\\]/g, "") + "}";

class Game {
  constructor(fig) {
    this.fig = fig;
    this.name = fig.dataset.name.slice(4);
    this.held = new Set();
    this.lastSave = null;
    this.handle = null;
    this.active = false;
    this.visible = false;
    this.build();
    new IntersectionObserver((e) => {
      this.visible = e.some((x) => x.isIntersecting);
      if (!this.visible) this.release(true);
      else this.loop();
    }).observe(this.view);
    // A tab in the background pauses the game.
    document.addEventListener("visibilitychange", () => { if (document.hidden) this.release(true); });
  }

  get demo() { return this.fig.ztkDemo; }
  get h() { return this.demo?.h ?? null; }
  get input() { return this.view.querySelector(".ld-frame textarea"); }

  eval(script) {
    try { return this.h?.eval(script) ?? null; } catch { return null; }
  }

  build() {
    const view = (this.view = this.fig.querySelector(".ld-view"));
    // The cover: the first click or Enter gives the game the keys.
    const cover = (this.cover = document.createElement("div"));
    cover.className = "toy-cover";
    cover.innerHTML = `<button type="button" class="toy-go"><span aria-hidden="true">▶</span> <span class="toy-go-t">Click to play</span></button>
<p class="toy-keys">Arrows or WASD move. Space or Z is A, X is B, Enter starts. Escape pauses.</p>`;
    view.appendChild(cover);
    cover.querySelector(".toy-go").addEventListener("click", (e) => { e.preventDefault(); this.grab(); });
    // The touch buttons, inside the frame, for a touch screen.
    const touch = document.createElement("div");
    touch.className = "toy-touch";
    touch.setAttribute("aria-hidden", "true");
    const arrows = { up: "▲", left: "◀", right: "▶", down: "▼" };
    touch.innerHTML = `<span class="toy-dpad">${Object.entries(arrows).map(([k, t]) => `<button type="button" data-in="${k}">${t}</button>`).join("")}</span>
<span class="toy-ab"><button type="button" data-in="b">B</button><button type="button" data-in="a">A</button></span>`;
    view.appendChild(touch);
    for (const b of touch.querySelectorAll("button")) {
      const k = b.dataset.in;
      b.addEventListener("pointerdown", (e) => { e.preventDefault(); b.setPointerCapture?.(e.pointerId); this.press(k, true); });
      for (const ev of ["pointerup", "pointercancel"]) b.addEventListener(ev, () => this.press(k, false));
    }
    // The bar under the frame: pause, sound, music, shake, and restart.
    const bar = (this.bar = document.createElement("div"));
    bar.className = "toy-controls";
    bar.innerHTML = `<button type="button" class="toy-pause" aria-pressed="false">Pause</button>
<button type="button" class="toy-fx" aria-pressed="false">Sound off</button>
<button type="button" class="toy-music" aria-pressed="false">Music off</button>
<button type="button" class="toy-calm" aria-pressed="false" title="Turns off the screen shake and the flashes">Shake on</button>
<button type="button" class="toy-restart">Restart</button>`;
    view.after(bar);
    const set = (cls, on, a, b) => {
      const el = bar.querySelector(cls);
      el.textContent = on ? a : b;
      el.setAttribute("aria-pressed", String(on));
    };
    this.paint = () => {
      set(".toy-fx", prefs.fx, "Sound on", "Sound off");
      set(".toy-music", prefs.music, "Music on", "Music off");
      set(".toy-calm", prefs.calm, "Shake off", "Shake on");
      set(".toy-pause", this.paused() || !this.active, "Play", "Pause");
    };
    bar.querySelector(".toy-fx").addEventListener("click", () => { prefs.fx = !prefs.fx; store.set("fx", prefs.fx ? "1" : "0"); sound.setFx(prefs.fx); this.paint(); });
    bar.querySelector(".toy-music").addEventListener("click", () => { prefs.music = !prefs.music; store.set("music", prefs.music ? "1" : "0"); sound.setMusic(prefs.music); this.paint(); });
    bar.querySelector(".toy-calm").addEventListener("click", () => { prefs.calm = !prefs.calm; store.set("calm", prefs.calm ? "1" : "0"); this.eval(`set ::toy(calm) ${prefs.calm ? 1 : 0}`); this.paint(); });
    bar.querySelector(".toy-pause").addEventListener("click", () => { if (this.active) this.release(true); else this.grab(); });
    bar.querySelector(".toy-restart").addEventListener("click", () => {
      this.handle = null;
      Promise.resolve(this.demo?.run(true)).then(() => this.grab());
    });
    this.paint();
    // The keys reach the game only while its input has the focus. The
    // listener is on the frame in the capture phase, so it runs before
    // the input of the window and keeps the keys from the page.
    view.addEventListener("keydown", (e) => this.key(e, true), true);
    view.addEventListener("keyup", (e) => this.key(e, false), true);
    // The wheel scrolls the page: it does not reach the window of the game.
    view.addEventListener("wheel", (e) => e.stopPropagation(), { capture: true, passive: true });
    // A press on the window while the game has no keys only takes the keys.
    view.addEventListener("pointerdown", (e) => {
      if (!this.active && e.target.tagName === "CANVAS") { e.stopPropagation(); e.preventDefault(); this.grab(); }
    }, true);
    view.addEventListener("focusout", () => {
      requestAnimationFrame(() => { if (this.active && !view.contains(document.activeElement)) this.release(true); });
    });
  }

  paused() { return Boolean(this.demo?.paused); }

  // The game gets the keys and runs.
  async grab() {
    if (!this.h) await this.demo?.run();
    if (!this.h) return;
    this.active = true;
    this.fig.classList.add("toy-active");
    this.cover.hidden = true;
    if (this.demo.paused) { this.demo.paused = false; this.demo.tick(); }
    this.input?.focus({ preventScroll: true });
    sound.setFx(prefs.fx);
    if (prefs.music) sound.setMusic(true);
    sound.suspend(false);
    this.paint();
    this.loop();
  }

  // The game gives the keys back. With `pause`, its frames stop and the
  // cover shows again.
  release(pause) {
    for (const k of this.held) this.send(k, false);
    this.held.clear();
    if (!this.active) return;
    this.active = false;
    this.fig.classList.remove("toy-active");
    if (pause && this.demo && this.h) {
      this.demo.paused = true;
      this.cover.hidden = false;
      this.cover.querySelector(".toy-go-t").textContent = "Paused. Click to play";
      sound.suspend(true);
    }
    if (this.view.contains(document.activeElement)) document.activeElement.blur();
    this.paint();
  }

  key(e, down) {
    if (!this.active || e.ctrlKey || e.metaKey || e.altKey) return;
    if (e.target !== this.input) return;
    if (e.key === "Escape") { e.preventDefault(); this.release(true); return; }
    if (e.key === "p" || e.key === "P") { if (down) { e.preventDefault(); this.release(true); } return; }
    const k = KEYS[e.key.length === 1 ? e.key.toLowerCase() : e.key];
    if (!k) return;
    // The key is the game's: the page does not scroll, and the window
    // of the game gets no key event of its own.
    e.preventDefault();
    e.stopImmediatePropagation();
    if (down && e.repeat) return;
    this.press(k, down);
  }

  press(k, down) {
    if (down) this.held.add(k); else if (!this.held.delete(k)) return;
    this.send(k, down);
  }

  send(k, down) {
    this.eval(`if {[info commands toy_input] ne ""} {toy_input ${k} ${down ? "press" : "release"}}`);
  }

  // A new window of the game: give it the saved data and the settings.
  attach() {
    this.handle = this.h;
    this.lastSave = null;
    const saved = store.get("save:" + this.name);
    this.eval(`set ::toy(calm) ${prefs.calm ? 1 : 0}; if {[info commands toy_restore] ne ""} {toy_restore ${quote(saved ?? "")}}`);
  }

  // One read of the game in each frame while the frame is on the screen.
  loop() {
    if (this.polling) return;
    this.polling = true;
    const step = () => {
      if (!this.visible) { this.polling = false; return; }
      if (this.h && this.h !== this.handle) this.attach();
      if (this.h && !this.paused()) {
        const r = this.eval(`if {![array exists ::toy]} {array set ::toy {}}; foreach k {sfx music save} {if {![info exists ::toy($k)]} {set ::toy($k) {}}}; set r [list $::toy(sfx) $::toy(music) $::toy(save)]; set ::toy(sfx) {}; set r`);
        if (r?.ok) {
          const [fx, music, save] = words(r.result);
          for (const s of fx.split(/\s+/).filter(Boolean)) sound.play(s);
          const song = music ? `${this.name}-${music}` : "";
          if (song !== sound.song) sound.setSong(song);
          if (save !== this.lastSave) {
            if (this.lastSave !== null && save) store.set("save:" + this.name, save);
            this.lastSave = save;
          }
        }
      }
      if (this.active) this.gamepad();
      requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  }

  gamepad() {
    const pad = [...(navigator.getGamepads?.() ?? [])].find(Boolean);
    if (!pad) return;
    const now = new Set();
    for (const [i, k] of Object.entries(PAD)) if (pad.buttons[i]?.pressed) now.add(k);
    const [x = 0, y = 0] = pad.axes;
    if (x < -0.5) now.add("left");
    if (x > 0.5) now.add("right");
    if (y < -0.5) now.add("up");
    if (y > 0.5) now.add("down");
    this.padHeld ??= new Set();
    for (const k of now) if (!this.padHeld.has(k)) this.press(k, true);
    for (const k of this.padHeld) if (!now.has(k)) this.press(k, false);
    this.padHeld = now;
  }
}

// The words of a Tcl list of three words, each in braces or bare.
function words(s) {
  const out = [];
  let i = 0;
  while (out.length < 3 && i < s.length) {
    while (s[i] === " ") i++;
    if (s[i] === "{") {
      let depth = 1, j = i + 1;
      while (j < s.length && depth) { if (s[j] === "{") depth++; else if (s[j] === "}") depth--; j++; }
      out.push(s.slice(i + 1, j - 1));
      i = j;
    } else {
      let j = s.indexOf(" ", i);
      if (j < 0) j = s.length;
      out.push(s.slice(i, j));
      i = j;
    }
  }
  while (out.length < 3) out.push("");
  return out;
}

// The picker of the Toys page: one frame, and a button for each game.
// The query `?game=SLUG` of the address picks a game.
class Picker {
  constructor(box) {
    this.box = box;
    this.fig = box.querySelector("figure.live-demo");
    this.games = [...box.querySelectorAll("pre.toy-game")];
    this.buttons = [...box.querySelectorAll(".toy-pick button")];
    for (const b of this.buttons) b.addEventListener("click", () => this.show(b.dataset.game, true));
    const slug = new URLSearchParams(location.search).get("game");
    const first = this.games.find((g) => g.dataset.slug === slug) ?? this.games[0];
    if (first) this.show(first.dataset.name, false);
  }
  show(name, live) {
    const game = this.games.find((g) => g.dataset.name === name);
    if (!game) return;
    for (const b of this.buttons) b.setAttribute("aria-pressed", String(b.dataset.game === name));
    for (const el of this.box.querySelectorAll("[data-for]")) el.hidden = el.dataset.for !== name;
    const same = this.fig.dataset.name === name;
    this.fig.dataset.name = name;
    const img = this.fig.querySelector(".ld-frame img");
    const src = this.fig.querySelector(".ld-frame source");
    if (img) { img.src = `${game.dataset.shot}-light.png`; img.alt = `The title screen of ${game.dataset.title}`; }
    if (src) src.srcset = `${game.dataset.shot}-dark.png`;
    if (live) {
      const url = new URL(location.href);
      url.searchParams.set("game", game.dataset.slug);
      history.replaceState(null, "", url);
    }
    const toy = this.fig.toyGame;
    if (same && !live) return;
    if (toy) { toy.release(false); toy.name = name.slice(4); toy.handle = null; }
    const d = this.fig.ztkDemo;
    if (!d) { this.fig.querySelector(".ld-code code").textContent = game.textContent; return; }
    d.name = name;
    d.original = game.textContent;
    d.ta.value = game.textContent;
    d.paint();
    d.first = null;
    if (live || d.h) Promise.resolve(d.run(true)).then(() => { if (live) toy?.grab(); });
  }
}

for (const fig of document.querySelectorAll('figure.live-demo[data-name^="toy-"]')) {
  fig.toyGame = new Game(fig);
}
for (const box of document.querySelectorAll(".toy-picker")) new Picker(box);
