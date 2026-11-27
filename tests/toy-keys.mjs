// SPDX-License-Identifier: BSD-2-Clause
// Checks the frame of the games of the Toys page in a headless Chromium,
// with real input events of the DevTools protocol: before a click the
// wheel scrolls the page, a click on the cover gives the game the keys,
// the keys play the game and do not scroll the page, Escape gives the
// keys back and pauses, and the window of the game stays inside its
// frame. It prints the frame times of the game, one line for each
// check, and exits with 1 when a check fails. With `--shots DIR` it also
// writes screenshots and the frames of a short clip to DIR.
// Use: node tests/toy-keys.mjs <browser> <profile dir> <url of toys/> [flag ...] [--shots DIR]
import { spawn } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";

const args = process.argv.slice(2);
const at = args.indexOf("--shots");
const shots = at >= 0 ? args.splice(at, 2)[1] : null;
const [browser, profile, url, ...flags] = args;
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
const KEY = {
  Escape: ["Escape", "Escape", 27], Enter: ["Enter", "Enter", 13], ArrowRight: ["ArrowRight", "ArrowRight", 39],
  ArrowDown: ["ArrowDown", "ArrowDown", 40], ArrowUp: ["ArrowUp", "ArrowUp", 38], " ": [" ", "Space", 32],
};
const key = async (k, type) => {
  const [name, code, kc] = KEY[k];
  const text = type === "keyDown" ? (name === "Enter" ? "\r" : name.length === 1 ? name : undefined) : undefined;
  await send("Input.dispatchKeyEvent", { type: type === "keyDown" && !text ? "rawKeyDown" : type, key: name, code, windowsVirtualKeyCode: kc, ...(text ? { text } : {}) });
};
const press = async (k, hold = 60) => { await key(k, "keyDown"); await wait(hold); await key(k, "keyUp"); await wait(120); };
let fail = 0;
const check = (ok, text) => {
  console.log(`${ok ? "ok" : "FAIL"}: ${text}`);
  if (!ok) fail = 1;
};
const timer = setTimeout(() => { console.log("FAIL: the page did not finish in time"); child.kill(); process.exit(1); }, 900000);
const shot = async (name, clip) => {
  if (!shots) return;
  const r = await send("Page.captureScreenshot", { format: "png", ...(clip ? { clip: { ...clip, scale: 1 } } : {}) });
  writeFileSync(`${shots}/${name}.png`, Buffer.from(r.result.data, "base64"));
};
if (shots) mkdirSync(shots, { recursive: true });

const { result: { targetId } } = await send("Target.createTarget", { url: "about:blank" });
session = (await send("Target.attachToTarget", { targetId, flatten: true })).result.sessionId;
await send("Emulation.setDeviceMetricsOverride", { width: 1280, height: 800, deviceScaleFactor: 1, mobile: false });
await send("Page.navigate", { url });
const fig = 'document.querySelector("figure.live-demo.toy")';
for (let i = 0; i < 300 && !(await value(`Boolean(${fig})`)); i++) await wait(200);
check(await value(`document.querySelectorAll(".toy-pick button").length`) === 3, "the Toys page has three games");
const viewBox = `(() => { const r = ${fig}.querySelector(".ld-view").getBoundingClientRect(); return {x: r.left, y: r.top, width: r.width, height: r.height}; })()`;
// The same box in the coordinates of the page, for a screenshot.
const pageBox = `(() => { const r = ${fig}.querySelector(".ld-view").getBoundingClientRect(); return {x: r.left + scrollX, y: r.top + scrollY, width: r.width, height: r.height}; })()`;
await value(`${fig}.scrollIntoView({ block: "center", behavior: "instant" })`);
for (let i = 0; i < 600 && !(await value(`Boolean(${fig}.ztkDemo?.h)`)); i++) await wait(200);
await wait(1500);
await shot("toys-page-1280");
// Before a click: the wheel over the frame scrolls the page.
let box = await value(viewBox);
const y0 = await value("scrollY");
await send("Input.dispatchMouseEvent", { type: "mouseWheel", x: box.x + box.width / 2, y: box.y + box.height / 2, deltaX: 0, deltaY: 200 });
await wait(400);
check((await value("scrollY")) > y0, "the wheel over the frame scrolls the page before a click");
check(!(await value(`${fig}.classList.contains("toy-active")`)), "the game has no keys before a click");
await value(`${fig}.scrollIntoView({ block: "center", behavior: "instant" })`);
await wait(300);
// A click on the cover gives the game the keys.
const go = await value(`(() => { const r = ${fig}.querySelector(".toy-go").getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; })()`);
for (const type of ["mousePressed", "mouseReleased"]) await send("Input.dispatchMouseEvent", { type, x: go[0], y: go[1], button: "left", clickCount: 1 });
await wait(600);
check(await value(`document.activeElement === ${fig}.querySelector(".ld-frame textarea")`), "a click on the cover gives the focus to the game");
check(await value(`${fig}.classList.contains("toy-active")`), "the frame shows the ring of a game with the keys");
check(await value(`${fig}.querySelector(".toy-cover").hidden`), "the cover goes away");
const state = () => value(`${fig}.ztkDemo.h.eval("set g(state)").result`);
check(await state() === "title", "the game starts on its title screen");
const y1 = await value("scrollY");
await press("Enter");
await wait(600);
check(await state() === "play", `Enter starts the first level (state ${await state()})`);
// Play: hold Right and jump, and read the frame times.
await value(`${fig}.ztkDemo.times.length = 0`);
const x0 = Number(await value(`${fig}.ztkDemo.h.eval("set h(x)").result`));
await key("ArrowRight", "keyDown");
for (let i = 0; i < 4; i++) {
  await wait(900);
  await press(" ", 200);
  if (i === 1) await shot("lamplighter-play", await value(pageBox));
}
await key("ArrowRight", "keyUp");
const x1 = Number(await value(`${fig}.ztkDemo.h.eval("set h(x)").result`));
const scene = await value(`${fig}.ztkDemo.h.eval("set g(scene)").result`);
check(x1 > x0 + 40 || scene !== "0", `Right moves the hero (x ${x0} to ${x1}, street ${scene})`);
check(await value("scrollY") === y1, "the keys do not scroll the page");
const times = await value(`[...${fig}.ztkDemo.times]`);
if (times?.length) {
  const t = times.sort((a, b) => a - b);
  const q = (p) => t[Math.min(t.length - 1, Math.floor(t.length * p))].toFixed(2);
  console.log(`frame times of the game: ${t.length} frames, p50 ${q(0.5)} ms, p95 ${q(0.95)} ms, max ${t[t.length - 1].toFixed(2)} ms`);
}
// The window stays inside its frame.
box = await value(viewBox);
const canvas = await value(`(() => { const r = ${fig}.querySelector(".ld-frame canvas").getBoundingClientRect(); return {x: r.left, y: r.top, width: r.width, height: r.height}; })()`);
check(canvas.x >= box.x - 0.5 && canvas.y >= box.y - 0.5 && canvas.x + canvas.width <= box.x + box.width + 0.5 && canvas.y + canvas.height <= box.y + box.height + 0.5,
  "the window of the game is inside its frame");
check(await value(`getComputedStyle(${fig}.querySelector(".ld-view")).overflow`) === "hidden", "the frame clips its content");
check(await value(`document.querySelectorAll("canvas").length === document.querySelectorAll(".live-demo canvas").length`), "the game puts no canvas on the page");
// A short clip: 48 frames of the play.
if (shots) {
  await key("ArrowRight", "keyDown");
  for (let i = 0; i < 48; i++) {
    if (i % 12 === 6) await press(" ", 180); else await wait(60);
    await shot(`clip-${String(i).padStart(2, "0")}`, await value(pageBox));
  }
  await key("ArrowRight", "keyUp");
}
// Escape gives the keys back and pauses.
await press("Escape");
await wait(300);
check(!(await value(`${fig}.classList.contains("toy-active")`)), "Escape gives the keys back");
check(await value(`${fig}.ztkDemo.paused === true`), "Escape pauses the game");
check(!(await value(`${fig}.querySelector(".toy-cover").hidden`)), "the cover shows again");
const y2 = await value("scrollY");
await press("ArrowDown");
await wait(300);
check((await value("scrollY")) > y2, "after Escape the arrow keys scroll the page");
// The other games of the picker.
for (const name of ["skatepond", "tinmoon"]) {
  await value(`document.querySelector('.toy-pick button[data-game="toy-${name}"]').click()`);
  for (let i = 0; i < 100 && (await value(`${fig}.dataset.name`)) !== `toy-${name}`; i++) await wait(100);
  for (let i = 0; i < 100 && !(await value(`${fig}.classList.contains("toy-active")`)); i++) await wait(100);
  await wait(1500);
  check(await state() === "title", `${name} starts on its title screen`);
  await press("Enter");
  await wait(800);
  check(await state() === "play", `Enter starts ${name}`);
  // The waits read the game, so a slow host only makes the run longer.
  const until = async (expr, ms = 15000) => { for (let t = 0; t < ms && !(await value(expr)); t += 100) await wait(100); };
  const tcl = (script) => `${fig}.ztkDemo.h.eval(${JSON.stringify(script)}).result`;
  if (name === "skatepond") {
    await press("ArrowDown");
    await until(`${tcl("expr {$sk(t) >= 1}")} === "1"`);
    await press("ArrowRight");
    await until(`${tcl("set g(state)")} === "clear"`);
  } else {
    await key("ArrowUp", "keyDown");
    await until(`Number(${tcl("set heat")}) > 0.6`);
    await key("ArrowUp", "keyUp");
    await until(`Number(${tcl("set b(y)")}) < 170`);
  }
  await shot(`${name}-play`, await value(pageBox));
  if (name === "skatepond") check(await state() === "clear", `two pushes clear the first pond (state ${await state()})`);
  else check(Number(await value(`${fig}.ztkDemo.h.eval("set heat").result`)) > 0.5, "Up moves the burner scale");
  await press("Escape");
}
// A phone: the frame fits the width.
await send("Emulation.setDeviceMetricsOverride", { width: 390, height: 844, deviceScaleFactor: 2, mobile: true });
await wait(800);
box = await value(viewBox);
check(box.width <= 390 && (await value("document.documentElement.scrollWidth")) <= 390, `the frame fits a phone (width ${Math.round(box.width)})`);
await value(`${fig}.scrollIntoView({ block: "center", behavior: "instant" })`);
await wait(500);
await shot("toys-page-390");
clearTimeout(timer);
child.kill();
process.exit(fail);
