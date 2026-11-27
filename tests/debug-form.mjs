// SPDX-License-Identifier: BSD-2-Clause
// Checks the page "Debug a form" in a headless Chromium: the form goes
// live, and the console gives the answer of the page for bug 1.
// Use: node tests/debug-form.mjs <browser> <profile dir> <url of the page> [flag ...]
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
const r = await value(`(async () => {
  const d = ${fig}.ztkDemo;
  d.consoleBox.hidden = false;
  const run = (cmd) => { d.consoleInput.value = cmd; d.consoleInput.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter" })); };
  run("ztk::debug type Ada .f.name");
  run("ztk::debug type ada@example.com .f.email");
  d.consoleOut.textContent = "";
  run("ztk::debug explain .f.save -state");
  return d.consoleOut.textContent;
})()`);
const want = "Stack: check ::mail {} write";
const ok = typeof r === "string" && r.split("\n").includes(want);
console.log(`${ok ? "ok" : "FAIL"}: the console of the form gives the stack of check: ${JSON.stringify(r)}`);
clearTimeout(timer);
child.kill();
process.exit(ok ? 0 : 1);
