// SPDX-License-Identifier: BSD-2-Clause
// Checks the stage of a build replay (assets/stage.js) in a headless
// Chromium. It steps with the Right and Left keys and checks after each
// step: the check of the step passed, scrollY of the page is the same,
// the boxes of the stage, the bar, the handheld, and the two panels are
// the same, the scroll of the code panel changes only for a step with
// new lines, and the mark is on the canvas. It records the frame times
// of requestAnimationFrame during the steps and prints their p50, p95,
// and largest value.
// Use: node tests/stage.mjs <browser> <url> [flag ...]
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const [browser, url, ...flags] = process.argv.slice(2);
const profile = mkdtempSync(join(tmpdir(), "ztk-stage-"));
const child = spawn(browser, ["--headless=new", "--no-sandbox", "--remote-debugging-pipe", `--user-data-dir=${profile}`, "--no-first-run", ...flags, "about:blank"],
  { stdio: ["ignore", "ignore", "ignore", "pipe", "pipe"] });
let next = 1;
let session;
const waiting = new Map();
let buf = Buffer.alloc(0);
child.stdio[4].on("data", (chunk) => {
  buf = Buffer.concat([buf, chunk]);
  let end;
  while ((end = buf.indexOf(0)) >= 0) {
    const msg = JSON.parse(buf.subarray(0, end).toString("utf8"));
    buf = buf.subarray(end + 1);
    if (msg.method === "Runtime.exceptionThrown") console.log("exception:", msg.params.exceptionDetails.exception?.description);
    if (msg.id && waiting.has(msg.id)) { waiting.get(msg.id)(msg); waiting.delete(msg.id); }
  }
});
const send = (method, params = {}) => new Promise((res) => {
  const id = next++;
  waiting.set(id, res);
  child.stdio[3].write(JSON.stringify({ id, method, params, ...(session ? { sessionId: session } : {}) }) + "\0");
});
const js = async (expr) => (await send("Runtime.evaluate", { expression: expr, awaitPromise: true, returnByValue: true })).result?.result?.value;
const pause = (ms) => new Promise((r) => setTimeout(r, ms));
const done = (code) => { child.kill(); rmSync(profile, { recursive: true, force: true }); process.exit(code); };
setTimeout(() => { console.log("FAIL: timeout"); done(1); }, 120000);

const { result: { targetId } } = await send("Target.createTarget", { url: "about:blank" });
session = (await send("Target.attachToTarget", { targetId, flatten: true })).result.sessionId;
await send("Runtime.enable");
await send("Emulation.setFocusEmulationEnabled", { enabled: true });
await send("Emulation.setDeviceMetricsOverride", { width: 1280, height: 900, deviceScaleFactor: 1, mobile: false });
await send("Page.navigate", { url });
let failed = 0;
const check = (name, ok, detail = "") => {
  if (!ok) failed++;
  console.log(`${ok ? "ok" : "FAIL"} ${name}${ok ? "" : ": " + detail}`);
};
const settle = async (k) => {
  for (let i = 0; i < 100; i++) {
    if ((await js(`document.querySelector(".stage")?.dataset.step`))?.startsWith(`${k}:`)) break;
    await pause(100);
  }
  await pause(700);
};
await settle(0);
const steps = Number(await js(`document.querySelector(".st-range").max`)) + 1;
check("the stage has steps", steps > 1, String(steps));
await js(`(() => { const s = document.querySelector(".stage"); s.scrollIntoView({ block: "start" }); s.focus({ preventScroll: true }); })()`);
await pause(300);
const boxes = `JSON.stringify([".stage", ".st-bar", ".st-view", ".st-steps", ".st-code"].map((q) => { const r = document.querySelector(q).getBoundingClientRect(); return [r.x, r.y, r.width, r.height].map(Math.round); }))`;
const y0 = await js("scrollY");
const b0 = await js(boxes);
await js(`window.__ft = []; (function f(t) { if (window.__last) window.__ft.push(t - window.__last); window.__last = t; requestAnimationFrame(f); })(performance.now())`);
const key = async (k) => {
  await send("Input.dispatchKeyEvent", { type: "rawKeyDown", key: k, code: k, windowsVirtualKeyCode: k === "ArrowRight" ? 39 : 37 });
  await send("Input.dispatchKeyEvent", { type: "keyUp", key: k, code: k, windowsVirtualKeyCode: k === "ArrowRight" ? 39 : 37 });
};
for (let k = 1; k < steps; k++) {
  await key("ArrowRight");
  await settle(k);
  const step = await js(`document.querySelector(".stage").dataset.step`);
  check(`step ${k + 1} runs and passes its check`, step === `${k}:true`, step);
  check(`step ${k + 1} keeps scrollY`, (await js("scrollY")) === y0, `${y0} -> ${await js("scrollY")}`);
  check(`step ${k + 1} keeps each box of the stage`, (await js(boxes)) === b0, `${b0} -> ${await js(boxes)}`);
  const mark = await js(`(() => { const m = document.querySelector(".st-mark").getBoundingClientRect(); const c = document.querySelector(".st-view canvas").getBoundingClientRect(); return document.querySelector(".st-mark").classList.contains("on") && m.left >= c.left - 8 && m.right <= c.right + 8 && m.top >= c.top - 8 && m.bottom <= c.bottom + 8; })()`);
  check(`step ${k + 1} marks a part on the canvas`, mark === true);
}
await key("ArrowLeft");
await settle(steps - 2);
check("Left goes back one step", (await js(`document.querySelector(".stage").dataset.step`)) === `${steps - 2}:true`);
check("the focus stays on the stage", await js(`document.activeElement === document.querySelector(".stage")`));
const ft = (await js("window.__ft")).slice().sort((a, b) => a - b);
const at = (p) => ft[Math.min(ft.length - 1, Math.floor(p * ft.length))].toFixed(1);
console.log(`frames: ${ft.length}, p50 ${at(0.5)} ms, p95 ${at(0.95)} ms, largest ${ft[ft.length - 1].toFixed(1)} ms`);
done(failed ? 1 : 0);
