// SPDX-License-Identifier: BSD-2-Clause
// Opens a page in a headless Chromium and prints the text of the element
// with the id "result" when the page makes it. It drives the browser
// through the DevTools protocol on a pipe (--remote-debugging-pipe): the
// messages are JSON, each one ends with a zero byte, and the browser
// reads them on fd 3 and writes on fd 4. The test runs in real time, so
// that WebGPU, whose adapter and device come from the GPU process, has
// the time to start. A page with no result after the timeout prints "{}".
// Use: [ZTK_BROWSER_VIEWPORT=WxHxR] node tests/browser.mjs <browser> <profile dir> <url> [flag ...]
import { spawn } from "node:child_process";

const [browser, profile, url, ...flags] = process.argv.slice(2);
const timeoutMs = Number(process.env.ZTK_BROWSER_TIMEOUT_MS || 60000);
const child = spawn(browser, [
  "--headless=new", "--no-sandbox", "--remote-debugging-pipe", `--user-data-dir=${profile}`,
  "--no-first-run", "--no-default-browser-check", ...flags, "about:blank",
], { stdio: ["ignore", "ignore", "ignore", "pipe", "pipe"] });
const toBrowser = child.stdio[3];
const fromBrowser = child.stdio[4];

let nextId = 1;
const waiting = new Map();
let buf = Buffer.alloc(0);
fromBrowser.on("data", (chunk) => {
  buf = Buffer.concat([buf, chunk]);
  let end;
  while ((end = buf.indexOf(0)) >= 0) {
    const msg = JSON.parse(buf.subarray(0, end).toString("utf8"));
    buf = buf.subarray(end + 1);
    // ZTK_BROWSER_CONSOLE=1 prints the console and the log of the page to stderr.
    if (process.env.ZTK_BROWSER_CONSOLE && msg.method === "Runtime.consoleAPICalled") {
      process.stderr.write(`console.${msg.params.type}: ${msg.params.args.map((a) => a.value ?? a.description).join(" ")}\n`);
    }
    if (process.env.ZTK_BROWSER_CONSOLE && msg.method === "Log.entryAdded") process.stderr.write(`log: ${msg.params.entry.text}\n`);
    if (msg.id && waiting.has(msg.id)) {
      waiting.get(msg.id)(msg);
      waiting.delete(msg.id);
    }
  }
});
const send = (method, params = {}, sessionId) => new Promise((res) => {
  const id = nextId++;
  waiting.set(id, res);
  toBrowser.write(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }) + "\0");
});

const finish = (text) => {
  child.kill();
  // A pipe takes the text in parts, so the exit waits for the write.
  process.stdout.write(text + "\n", () => process.exit(0));
};
setTimeout(() => finish("{}"), timeoutMs);

const { result: { targetId } } = await send("Target.createTarget", { url: "about:blank" });
const { result: { sessionId } } = await send("Target.attachToTarget", { targetId, flatten: true });
// ZTK_BROWSER_VIEWPORT=WxHxR sets the size of the page in CSS pixels and
// devicePixelRatio. A headless window has a minimum width of 500 pixels,
// so a phone size needs this.
const vp = process.env.ZTK_BROWSER_VIEWPORT;
if (vp) {
  const [width, height, deviceScaleFactor] = vp.split("x").map(Number);
  await send("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor, mobile: false }, sessionId);
}
await send("Page.navigate", { url }, sessionId);
if (process.env.ZTK_BROWSER_CONSOLE) {
  await send("Runtime.enable", {}, sessionId);
  await send("Log.enable", {}, sessionId);
}
const expr = "(() => { const e = document.getElementById('result'); return e ? e.textContent : null; })()";
for (;;) {
  const r = await send("Runtime.evaluate", { expression: expr, returnByValue: true }, sessionId);
  const v = r.result?.result?.value;
  if (typeof v === "string") finish(v);
  await new Promise((res) => setTimeout(res, 200));
}
