// SPDX-License-Identifier: BSD-2-Clause
// The replay player (docs/dev/interactive-docs.md, "Replay"). A replay is
// a JSON file: {version, title, steps: [{who, say, script?, check?}]}.
// The player shows the chat, and a scrub bar with one stop for each step
// that has a script. At a stop, the live snippet under the player runs
// the script of that step (assets/live.js), so the app is live, and then
// the check of the step, a Tcl script that gives 1 when it passes, in
// the same window. The player makes no network call beyond the replay
// file and the web build.

for (const box of document.querySelectorAll(".replay[data-src]")) {
  const fig = box.parentElement.querySelector("figure.live-demo");
  const rec = await (await fetch(box.dataset.src)).json();
  const stops = rec.steps.map((s, i) => (s.script ? i : -1)).filter((i) => i >= 0);
  const chat = document.createElement("ol");
  chat.className = "rp-chat";
  const items = rec.steps.map((s) => {
    const li = document.createElement("li");
    li.className = `rp-${s.who === "agent" ? "agent" : "person"}`;
    const who = document.createElement("b");
    who.textContent = s.who === "agent" ? "Agent" : "Person";
    const p = document.createElement("p");
    p.textContent = s.say;
    li.append(who, p);
    chat.appendChild(li);
    return li;
  });
  const bar = document.createElement("div");
  bar.className = "rp-bar";
  const play = document.createElement("button");
  play.type = "button";
  play.textContent = "Play";
  const range = document.createElement("input");
  range.type = "range";
  range.min = "0";
  range.max = String(stops.length - 1);
  range.value = "0";
  range.setAttribute("aria-label", "Step of the replay");
  const label = document.createElement("span");
  bar.append(play, range, label);
  const check = document.createElement("p");
  check.className = "rp-check";
  box.append(bar, chat, check);

  let busy = Promise.resolve();
  const show = (k) => (busy = busy.then(async () => {
    const at = stops[k];
    range.value = String(k);
    label.textContent = `Step ${k + 1} of ${stops.length}`;
    items.forEach((li, i) => {
      li.hidden = i > at;
      li.classList.toggle("rp-now", i === at);
    });
    while (!fig.ztkDemo) await new Promise((r) => setTimeout(r, 50));
    const d = fig.ztkDemo;
    d.ta.value = rec.steps[at].script;
    d.paint();
    d.first = null;
    await d.run(true);
    const c = rec.steps[at].check;
    if (!c || !d.h) { check.textContent = ""; return; }
    const r = d.h.eval(c);
    d.h.frame(performance.now());
    const ok = r.ok && r.result === "1";
    check.textContent = ok ? "The check of this step passed in the window above." : `The check of this step failed: ${r.result}`;
    check.className = `rp-check ${ok ? "ok" : "bad"}`;
    box.dataset.step = `${k}:${ok}`;
  }));
  range.addEventListener("input", () => show(Number(range.value)));
  let timer = 0;
  play.addEventListener("click", () => {
    if (timer) { clearInterval(timer); timer = 0; play.textContent = "Play"; return; }
    play.textContent = "Pause";
    show(0);
    let k = 0;
    timer = setInterval(() => {
      if (++k >= stops.length) { clearInterval(timer); timer = 0; play.textContent = "Play"; return; }
      show(k);
    }, 3000);
  });
  box.ztkShow = show;
  // ?step=N in the URL opens the replay at the stop N (from 1).
  const start = Number(new URLSearchParams(location.search).get("step")) || 1;
  show(Math.min(Math.max(start, 1), stops.length) - 1);
}
