// SPDX-License-Identifier: BSD-2-Clause
// The stage of a build replay of a toy (docs/build/*.md). A replay is the
// JSON of docs/site/replays: steps of a person and of an agent, and each
// step of the agent has `script` (the full code after the step), `check`,
// `widget` (the path of the part that the step adds), and `name` (its
// label). The stage has four panels of fixed size: the bar, the steps,
// the code, and the handheld. A step changes the content of the panels.
// The page does not scroll and no panel moves: the list of steps and the
// code scroll inside their own boxes, with `scrollTo` on the box, to the
// new step and to the first new line. The handheld (assets/toys.js) runs
// the code of the step, and a frame over it marks the new part.

const reduced = matchMedia("(prefers-reduced-motion: reduce)");
const ease = () => (reduced.matches ? "auto" : "smooth");

// The lines of `now` that are not in `before`, by a longest common
// subsequence of the lines. The scripts have at most a few hundred lines.
function added(before, now) {
  const a = before.split("\n");
  const b = now.split("\n");
  const n = a.length;
  const m = b.length;
  const len = Array.from({ length: n + 1 }, () => new Uint16Array(m + 1));
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      len[i][j] = a[i] === b[j] ? len[i + 1][j + 1] + 1 : Math.max(len[i + 1][j], len[i][j + 1]);
    }
  }
  const out = new Array(m).fill(true);
  let i = 0;
  let j = 0;
  while (i < n && j < m) {
    if (a[i] === b[j]) { out[j] = false; i++; j++; } else if (len[i + 1][j] >= len[i][j + 1]) i++; else j++;
  }
  return out;
}

for (const stage of document.querySelectorAll(".stage[data-src]")) {
  const rec = await (await fetch(stage.dataset.src)).json();
  const fig = stage.querySelector("figure.live-demo");
  const list = stage.querySelector(".st-steps");
  const codeBox = stage.querySelector(".st-code");
  const code = codeBox.querySelector("code");
  const range = stage.querySelector(".st-range");
  const label = stage.querySelector(".st-label");
  const play = stage.querySelector(".st-play");
  const mark = stage.querySelector(".st-mark");
  const stops = rec.steps.map((s, i) => (s.script ? i : -1)).filter((i) => i >= 0);
  range.max = String(stops.length - 1);

  // All the steps are in the list from the start, so the list does not
  // grow. The steps after the current one are dim.
  const items = rec.steps.map((s) => {
    const li = document.createElement("li");
    li.className = s.who === "agent" ? "st-agent" : "st-person";
    const who = document.createElement("b");
    who.textContent = s.who === "agent" ? "Agent" : "Person";
    const p = document.createElement("p");
    p.textContent = s.say;
    li.append(who, p);
    if (s.name) {
      const part = document.createElement("span");
      part.className = "st-part";
      part.textContent = s.name;
      li.append(part);
    }
    list.append(li);
    return li;
  });

  // The frame over the new part: the box of the widget in the logical
  // pixels of the window, scaled to the canvas.
  const place = (path, name) => {
    const d = fig.ztkDemo;
    const canvas = fig.querySelector(".ld-frame canvas");
    if (!path || !d?.h || !canvas) { mark.classList.remove("on"); return; }
    const r = d.h.eval(`list [winfo rootx ${path}] [winfo rooty ${path}] [winfo width ${path}] [winfo height ${path}] [winfo width .]`);
    if (!r.ok) { mark.classList.remove("on"); return; }
    const [x, y, w, h, top] = r.result.split(" ").map(Number);
    const c = canvas.getBoundingClientRect();
    const k = c.width / Math.max(top, 1);
    const view = stage.querySelector(".st-view").getBoundingClientRect();
    mark.style.transform = `translate(${c.left - view.left + x * k - 3}px, ${c.top - view.top + y * k - 3}px)`;
    mark.style.width = `${w * k + 6}px`;
    mark.style.height = `${h * k + 6}px`;
    mark.firstElementChild.textContent = name;
    mark.classList.add("on");
  };

  let current = -1;
  let busy = Promise.resolve();
  const show = (k) => (busy = busy.then(async () => {
    k = Math.max(0, Math.min(stops.length - 1, k));
    const at = stops[k];
    const prev = k > 0 ? rec.steps[stops[k - 1]].script : "";
    const step = rec.steps[at];
    current = k;
    range.value = String(k);
    label.textContent = `Step ${k + 1} of ${stops.length}${step.name ? `: ${step.name}` : ""}`;
    items.forEach((li, i) => {
      li.classList.toggle("st-done", i <= at);
      li.classList.toggle("st-now", i === at || i === at - 1);
    });
    // The list scrolls inside its box so that the prompt of the step is at the top.
    const ask = items[at - 1] || items[at];
    list.scrollTo({ top: ask.offsetTop - list.offsetTop - 8, behavior: ease() });
    // The code: the new lines have a mark and fade in.
    const marks = added(prev, step.script);
    const frag = document.createDocumentFragment();
    let firstNew = null;
    step.script.replace(/\n$/, "").split("\n").forEach((line, i) => {
      const span = document.createElement("span");
      span.className = marks[i] ? "st-line st-new" : "st-line";
      span.textContent = line + "\n";
      if (marks[i] && !firstNew) firstNew = span;
      frag.append(span);
    });
    code.replaceChildren(frag);
    if (firstNew) codeBox.scrollTo({ top: Math.max(0, firstNew.offsetTop - codeBox.offsetTop - 24), behavior: ease() });
    // The handheld runs the code of the step.
    while (!fig.ztkDemo) await new Promise((r) => setTimeout(r, 50));
    const d = fig.ztkDemo;
    d.ta.value = step.script;
    d.paint();
    d.first = null;
    await d.run(true);
    let ok = true;
    if (step.check && d.h) {
      const r = d.h.eval(step.check);
      ok = r.ok && r.result === "1";
    }
    d.h?.frame(performance.now());
    requestAnimationFrame(() => place(step.widget, step.name));
    stage.dataset.step = `${k}:${ok}`;
  }));

  stage.querySelector(".st-prev").addEventListener("click", () => show(current - 1));
  stage.querySelector(".st-next").addEventListener("click", () => show(current + 1));
  range.addEventListener("input", () => show(Number(range.value)));
  let timer = 0;
  const stop = () => { clearInterval(timer); timer = 0; play.textContent = "Play"; };
  const toggle = () => {
    if (timer) return stop();
    play.textContent = "Pause";
    if (current >= stops.length - 1) show(0);
    timer = setInterval(() => (current >= stops.length - 1 ? stop() : show(current + 1)), 3500);
  };
  play.addEventListener("click", toggle);
  // The keys of the stage. The keys of the handheld stay with the game.
  stage.addEventListener("keydown", (e) => {
    if (e.target === range || e.target.closest(".ld-view") || e.ctrlKey || e.metaKey || e.altKey) return;
    if (e.key === "ArrowRight") show(current + 1);
    else if (e.key === "ArrowLeft") show(current - 1);
    else if (e.key === " " && e.target.tagName !== "BUTTON") toggle();
    else if (e.key === "Escape") { stop(); stage.focus({ preventScroll: true }); return; }
    else return;
    e.preventDefault();
  });
  addEventListener("resize", () => current >= 0 && place(rec.steps[stops[current]].widget, rec.steps[stops[current]].name));
  stage.ztkShow = show;
  show(0);
}
