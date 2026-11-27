// SPDX-License-Identifier: BSD-2-Clause
// Checks the place of the panel of Inspect in a headless Chromium: the
// first live snippet of a widget page is scrolled to the top and to the
// bottom of the viewport, at three widths, and the panel of its first
// widget must be inside the viewport and off the widget. Under 640 CSS
// pixels the panel is a sheet at the bottom. Then each tab of the panel
// must keep the box of the panel. It prints one line for each
// check and exits with 1 on a failure.
// Use: node tests/inspect.mjs <browser> <profile dir> <url of a widget page> [flag ...]
import { spawn } from "node:child_process";

const [browser, profile, url, ...flags] = process.argv.slice(2);
const child = spawn(browser, [
  "--headless=new", "--no-sandbox", "--remote-debugging-pipe", `--user-data-dir=${profile}`,
  "--no-first-run", "--no-default-browser-check", ...flags, "about:blank",
], { stdio: ["ignore", "ignore", "ignore", "pipe", "pipe"] });
const toBrowser = child.stdio[3];
let nextId = 1;
const waiting = new Map();
let buf = Buffer.alloc(0);
child.stdio[4].on("data", (chunk) => {
  buf = Buffer.concat([buf, chunk]);
  let end;
  while ((end = buf.indexOf(0)) >= 0) {
    const msg = JSON.parse(buf.subarray(0, end).toString("utf8"));
    buf = buf.subarray(end + 1);
    if (msg.id && waiting.has(msg.id)) {
      waiting.get(msg.id)(msg);
      waiting.delete(msg.id);
    }
  }
});
let session;
const send = (method, params = {}) => new Promise((res) => {
  const id = nextId++;
  waiting.set(id, res);
  toBrowser.write(JSON.stringify({ id, method, params, ...(session ? { sessionId: session } : {}) }) + "\0");
});
const value = async (expression) => (await send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true })).result?.result?.value;
const wait = (ms) => new Promise((res) => setTimeout(res, ms));
let fail = 0;
const timer = setTimeout(() => { console.log("FAIL: the page did not load in time"); child.kill(); process.exit(1); }, 170000);
const { result: { targetId } } = await send("Target.createTarget", { url: "about:blank" });
session = (await send("Target.attachToTarget", { targetId, flatten: true })).result.sessionId;
await send("Emulation.setDeviceMetricsOverride", { width: 1200, height: 700, deviceScaleFactor: 1, mobile: false });
await send("Page.navigate", { url });
const fig = 'document.querySelector("figure.live-demo:not(.toy)")';
for (let i = 0; i < 600 && !(await value(`Boolean(${fig}?.ztkDemo?.h)`)); i++) await wait(200);
for (const width of [1200, 760, 420]) {
  await send("Emulation.setDeviceMetricsOverride", { width, height: 700, deviceScaleFactor: 1, mobile: false });
  for (const block of ["start", "end"]) {
    const r = await value(`(async () => {
      const f = ${fig}, d = f.ztkDemo;
      f.querySelector(".ld-view").scrollIntoView({ block: "${block}", behavior: "instant" });
      await new Promise((res) => setTimeout(res, 300));
      d.inspecting = true;
      const b = d.boxes().find((x) => x.kind === "w" && x.path !== ".");
      d.pick(b.path);
      await new Promise((res) => setTimeout(res, 300));
      const p = d.panel.getBoundingClientRect(), l = d.layer.getBoundingClientRect(), k = l.width / 360;
      const w = { left: l.left + b.x * k, top: l.top + b.y * k, right: l.left + (b.x + b.w) * k, bottom: l.top + (b.y + b.h) * k };
      const vw = document.documentElement.clientWidth, vh = innerHeight;
      const inside = p.left >= 0 && p.top >= 0 && p.right <= vw + 0.5 && p.bottom <= vh + 0.5 && p.height > 40;
      const off = p.right <= w.left || p.left >= w.right || p.bottom <= w.top || p.top >= w.bottom;
      const nested = getComputedStyle(d.panel).overflowY !== "hidden";
      d.pick(null);
      return { inside, off, nested, sheet: d.panel.classList.contains("sheet"), p: [p.left, p.top, p.right, p.bottom].map(Math.round) };
    })()`);
    const ok = r && r.inside && r.off && !r.nested;
    console.log(`${ok ? "ok" : "FAIL"}: the panel of Inspect at width ${width}, snippet at the ${block}${r?.sheet ? " (sheet)" : ""}: in view ${r?.inside}, off the widget ${r?.off}, panel ${JSON.stringify(r?.p)}`);
    if (!ok) fail = 1;
  }
}
// The tabs of the panel: each tab keeps the box of the panel, the
// Options tab gives the source of the -text of the widget, and each
// change of tab ends inside one frame of 60 Hz (16.7 ms).
await send("Emulation.setDeviceMetricsOverride", { width: 1200, height: 700, deviceScaleFactor: 1, mobile: false });
const tabs = await value(`(async () => {
  const f = ${fig}, d = f.ztkDemo;
  f.querySelector(".ld-view").scrollIntoView({ block: "center", behavior: "instant" });
  await new Promise((res) => setTimeout(res, 300));
  d.inspecting = true;
  const b = d.boxes().find((x) => x.kind === "w" && x.path !== "." && d.h.eval("winfo class " + x.path).result === "Button")
    || d.boxes().find((x) => x.kind === "w" && x.path !== ".");
  d.pick(b.path);
  const box = () => { const r = d.panel.getBoundingClientRect(); return [r.left, r.top, r.width, r.height].map(Math.round).join(","); };
  const first = box();
  const out = { path: b.path, same: true, worst: 0, tabs: [] };
  for (const t of d.panel.querySelectorAll(".ld-itabs button")) {
    const t0 = performance.now();
    t.click();
    out.worst = Math.max(out.worst, performance.now() - t0);
    out.tabs.push(t.textContent);
    if (box() !== first) out.same = false;
  }
  d.panel.querySelector(".ld-itabs button").click();
  const row = [...d.panel.querySelectorAll(".ld-iopts tr")].find((r) => r.cells[0].textContent === "-text");
  out.src = row ? row.querySelector(".ld-isrc")?.textContent ?? "" : "";
  d.pick(null);
  return out;
})()`);
const tabsOk = tabs && tabs.same && tabs.worst < 16.7 && tabs.tabs.length === 6 && /line \d+/.test(tabs.src);
console.log(`${tabsOk ? "ok" : "FAIL"}: the tabs of Inspect on ${tabs?.path}: ${tabs?.tabs?.join(", ")}; same box ${tabs?.same}; slowest change ${tabs?.worst?.toFixed(1)} ms; source of -text "${tabs?.src}"`);
if (!tabsOk) fail = 1;
// The console runs a command in the window and shows the answer.
const con = await value(`(async () => {
  const d = ${fig}.ztkDemo;
  d.consoleBox.hidden = false;
  d.consoleInput.value = "winfo class .";
  d.consoleInput.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter" }));
  return d.consoleOut.textContent;
})()`);
const conOk = typeof con === "string" && con.endsWith("% winfo class .\nZtk");
console.log(`${conOk ? "ok" : "FAIL"}: the console gives ${JSON.stringify(con)}`);
if (!conOk) fail = 1;
clearTimeout(timer);
child.kill();
process.exit(fail);
