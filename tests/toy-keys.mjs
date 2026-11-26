// SPDX-License-Identifier: BSD-2-Clause
// Checks the keys of the handheld of the Toys page in a headless
// Chromium, with real input events of the DevTools protocol: a click on
// the pad gives the focus to the game, W and S and the arrow keys move
// the cursor of the game list, P pauses, Z starts the selected game, and
// Escape gives the focus back. The page must not scroll. It prints one
// line for each check and exits with 1 when a check fails.
// Use: node tests/toy-keys.mjs <browser> <profile dir> <url of toys/> [flag ...]
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
const KEY = { w: ["w", "KeyW", 87], s: ["s", "KeyS", 83], p: ["p", "KeyP", 80], z: ["z", "KeyZ", 90], a: ["a", "KeyA", 65], d: ["d", "KeyD", 68], ArrowDown: ["ArrowDown", "ArrowDown", 40], Escape: ["Escape", "Escape", 27] };
const press = async (k) => {
  const [key, code, kc] = KEY[k];
  const text = key.length === 1 ? key : undefined;
  await send("Input.dispatchKeyEvent", { type: text ? "keyDown" : "rawKeyDown", key, code, windowsVirtualKeyCode: kc, text });
  await send("Input.dispatchKeyEvent", { type: "keyUp", key, code, windowsVirtualKeyCode: kc });
  await wait(300);
};
let fail = 0;
const check = (ok, text) => {
  console.log(`${ok ? "ok" : "FAIL"}: ${text}`);
  if (!ok) fail = 1;
};
const timer = setTimeout(() => { console.log("FAIL: the toy page did not load in time"); child.kill(); process.exit(1); }, 170000);

const { result: { targetId } } = await send("Target.createTarget", { url: "about:blank" });
session = (await send("Target.attachToTarget", { targetId, flatten: true })).result.sessionId;
await send("Emulation.setDeviceMetricsOverride", { width: 1200, height: 700, deviceScaleFactor: 1, mobile: false });
await send("Page.navigate", { url });
const fig = 'document.querySelector("figure.toy-console")';
for (let i = 0; i < 600 && !(await value(`Boolean(${fig}?.ztkDemo?.h)`)); i++) await wait(200);
const sel = () => value(`${fig}.ztkDemo.h.eval(".games curselection").result`);
const box = await value(`(() => { const b = ${fig}.querySelector(".toy-brand"); b.scrollIntoView({ block: "center", behavior: "instant" }); const r = b.getBoundingClientRect(); return [r.left + 4, r.top + 4]; })()`);
for (const type of ["mousePressed", "mouseReleased"]) await send("Input.dispatchMouseEvent", { type, x: box[0], y: box[1], button: "left", clickCount: 1 });
await wait(400);
check(await value(`document.activeElement === ${fig}.querySelector(".ld-frame textarea")`), "a click on the pad gives the focus to the game");
check(await value(`${fig}.querySelector(".ld-view").matches(":focus-within")`), "the device has the focus ring");
const y0 = await value("scrollY");
await press("s");
check(await sel() === "1", `S presses Down of the pad (selection ${await sel()})`);
await press("ArrowDown");
check(await sel() === "2", `the arrow key goes to the game (selection ${await sel()})`);
await press("w");
check(await sel() === "1", `W presses Up of the pad (selection ${await sel()})`);
check(await value("scrollY") === y0, "the keys do not scroll the page");
await press("p");
check(await value(`${fig}.classList.contains("toy-paused")`), "P pauses the game");
await press("p");
check(!(await value(`${fig}.classList.contains("toy-paused")`)), "P again runs the game");
await press("z");
await wait(1500);
check(await value("location.search") === "?game=backspin", `Z presses A and starts the selected game (${await value("location.search")})`);
check(await value(`document.activeElement === ${fig}.querySelector(".ld-frame textarea")`), "the game keeps the keys after it starts");
check((await value(`${fig}.querySelector(".toy-keys").textContent`)).includes("W A S D"), "the key line shows W A S D");
await value(`${fig}.ztkDemo.h.eval("set ::side {}; bind all <KeyPress-Left> {+lappend ::side L}; bind all <KeyPress-Right> {+lappend ::side R}")`);
await press("a");
await press("d");
const side = await value(`${fig}.ztkDemo.h.eval("set ::side").result`);
check(side === "L R", `A and D press Left and Right (${side})`);
await press("Escape");
check(await value(`document.activeElement !== ${fig}.querySelector(".ld-frame textarea")`), "Escape gives the focus back to the page");
clearTimeout(timer);
child.kill();
process.exit(fail);
