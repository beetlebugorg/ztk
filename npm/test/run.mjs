#!/usr/bin/env node
// Tests the npm package as a user gets it. Run `zig build wasm` and
// `node npm/build.mjs` first.
//
//   node npm/test/run.mjs [node] [browser] [cdn]
//
// node:    npm pack, install the tarball in a new project, run test.mjs,
//          and check the types with tsc.
// browser: a new Vite project installs the tarball. Headless Chromium
//          runs the page of `vite build` and of the Vite dev server.
// cdn:     a page with no build step imports the package from a second
//          origin, with the folder layout of jsDelivr (/npm/NAME@VERSION/).
//
// The browser tests need Chromium and playwright-core. Set CHROME to the
// browser and PLAYWRIGHT_CORE to the folder of playwright-core. With no
// PLAYWRIGHT_CORE, the test installs playwright-core in the work folder.
// Set KEEP=1 to keep the work folder.
// SPDX-License-Identifier: BSD-2-Clause
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import net from "node:net";
import { execFileSync, spawn } from "node:child_process";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "../..");
const stage = path.join(root, "zig-out/npm");
const modes = process.argv.slice(2).length ? process.argv.slice(2) : ["node", "browser", "cdn"];
const pkg = JSON.parse(fs.readFileSync(path.join(stage, "package.json"), "utf8"));
// The result of page/main.js.
const expected = JSON.parse(fs.readFileSync(path.join(here, "page/expected.json"), "utf8"));

const work = fs.mkdtempSync(path.join(os.tmpdir(), "ztk-npm-"));
const run = (cmd, args, cwd) => execFileSync(cmd, args, { cwd, stdio: "inherit" });
const servers = [];
let failed = 0;

function fill(file, values) {
  let text = fs.readFileSync(file, "utf8");
  for (const [k, v] of Object.entries(values)) text = text.replaceAll(`{{${k}}}`, v);
  return text;
}

function project(dir, extra = {}) {
  fs.mkdirSync(dir, { recursive: true });
  const deps = { [pkg.name]: `file:${tarball}`, ...extra };
  fs.writeFileSync(path.join(dir, "package.json"), JSON.stringify({ name: "test", private: true, type: "module", dependencies: deps }, null, 2));
  run("npm", ["install", "--no-audit", "--no-fund", "--loglevel=error"], dir);
}

async function freePort() {
  return new Promise((resolve) => {
    const s = net.createServer().listen(0, "127.0.0.1", () => {
      const { port } = s.address();
      s.close(() => resolve(port));
    });
  });
}

async function waitFor(url) {
  for (let i = 0; i < 100; i++) {
    try {
      await fetch(url);
      return;
    } catch {
      await new Promise((r) => setTimeout(r, 100));
    }
  }
  throw new Error(`the server at ${url} did not start`);
}

// A static server on 127.0.0.1. With cors, it sends
// Access-Control-Allow-Origin as a CDN does.
async function serve(dir, cors = false) {
  const port = await freePort();
  const args = cors
    ? ["-c", `import http.server as h, functools, sys
class H(h.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        super().end_headers()
h.ThreadingHTTPServer(("127.0.0.1", ${port}), functools.partial(H, directory=sys.argv[1])).serve_forever()`, dir]
    : ["-m", "http.server", "--bind", "127.0.0.1", "--directory", dir, String(port)];
  servers.push(spawn("python3", args, { stdio: "ignore" }));
  await waitFor(`http://127.0.0.1:${port}/`);
  return `http://127.0.0.1:${port}`;
}

// playwright-core from PLAYWRIGHT_CORE, or a copy in the work folder.
let playwright = null;
function chromium() {
  if (!playwright) {
    let from = process.env.PLAYWRIGHT_CORE;
    if (!from) {
      const dir = path.join(work, "playwright");
      fs.mkdirSync(dir);
      fs.writeFileSync(path.join(dir, "package.json"), "{}");
      run("npm", ["install", "--no-audit", "--no-fund", "--loglevel=error", "playwright-core@^1.50.0"], dir);
      from = path.join(dir, "node_modules/playwright-core");
    }
    playwright = createRequire(import.meta.url)(path.resolve(from));
  }
  return playwright.chromium;
}

async function browserResult(url) {
  const chrome = process.env.CHROME || ["/usr/bin/chromium", "/usr/bin/google-chrome", "/usr/bin/chromium-browser"].find((p) => fs.existsSync(p));
  // SwiftShader gives WebGL 2 on a machine with no GPU.
  const args = ["--use-angle=swiftshader", "--enable-unsafe-swiftshader"];
  const browser = await chromium().launch({ executablePath: chrome, args });
  try {
    const page = await browser.newPage({ deviceScaleFactor: 2 });
    const errors = [];
    page.on("pageerror", (e) => errors.push(e.message));
    page.on("response", (r) => r.status() >= 400 && !r.url().endsWith("/favicon.ico") && errors.push(`${r.status()} ${r.url()}`));
    await page.goto(url);
    await page.waitForFunction(() => document.getElementById("result")?.textContent, null, { timeout: 60_000 });
    const result = JSON.parse(await page.locator("#result").textContent());
    if (errors.length) result.errors = errors;
    return result;
  } finally {
    await browser.close();
  }
}

function compare(what, got) {
  const ok = Object.entries(expected).every(([k, v]) => JSON.stringify(got[k]) === JSON.stringify(v)) && !got.errors;
  console.log(`${ok ? "ok" : "FAIL"} ${what}: ${JSON.stringify(got)}`);
  if (!ok) failed++;
}

run("npm", ["pack", stage, "--pack-destination", work, "--loglevel=error"], root);
const tarball = path.join(work, fs.readdirSync(work).find((f) => f.endsWith(".tgz")));

try {
  if (modes.includes("node")) {
    const dir = path.join(work, "node");
    project(dir, { typescript: "^5.9.0" });
    fs.copyFileSync(path.join(here, "test.mjs"), path.join(dir, "test.mjs"));
    try {
      run("node", ["test.mjs"], dir);
      console.log("ok node test.mjs");
    } catch {
      failed++;
    }
    fs.writeFileSync(path.join(dir, "types.ts"), fill(path.join(here, "types.ts"), { name: pkg.name }));
    const tsc = ["--noEmit", "--strict", "--target", "es2022", "--module", "nodenext", "--moduleResolution", "nodenext", "--lib", "es2022,dom", "types.ts"];
    try {
      run("node", ["node_modules/typescript/bin/tsc", ...tsc], dir);
      console.log("ok tsc types.ts");
    } catch {
      failed++;
    }
  }

  if (modes.includes("browser")) {
    const dir = path.join(work, "vite");
    project(dir, { vite: "^7.0.0" });
    fs.copyFileSync(path.join(here, "page/index.html"), path.join(dir, "index.html"));
    fs.writeFileSync(path.join(dir, "main.js"), fill(path.join(here, "page/main.js"), { import: pkg.name }));
    // The configuration of the README: the dev server serves the files
    // of the package as they are, so ztk.wasm stays next to ztk.js.
    fs.writeFileSync(path.join(dir, "vite.config.js"), `export default { optimizeDeps: { exclude: [${JSON.stringify(pkg.name)}] } };\n`);
    run("node", ["node_modules/vite/bin/vite.js", "build", "--logLevel", "warn"], dir);
    console.log(`vite dist/assets: ${fs.readdirSync(path.join(dir, "dist/assets")).join(" ")}`);
    const base = await serve(path.join(dir, "dist"));
    compare("vite build in Chromium", await browserResult(`${base}/index.html`));
    const port = await freePort();
    const vite = ["node_modules/vite/bin/vite.js", "--host", "127.0.0.1", "--port", String(port), "--strictPort"];
    servers.push(spawn("node", vite, { cwd: dir, stdio: "ignore" }));
    await waitFor(`http://127.0.0.1:${port}/`);
    compare("vite dev server in Chromium", await browserResult(`http://127.0.0.1:${port}/`));
  }

  if (modes.includes("cdn")) {
    // The package from a second origin, as https://cdn.jsdelivr.net/npm/NAME@VERSION/ serves it.
    const cdn = path.join(work, "cdn");
    const at = path.join(cdn, "npm", `${pkg.name}@${pkg.version}`);
    fs.mkdirSync(at, { recursive: true });
    run("tar", ["-xzf", tarball, "-C", at, "--strip-components=1"], root);
    const cdnBase = await serve(cdn, true);
    const site = path.join(work, "site");
    fs.mkdirSync(site);
    fs.copyFileSync(path.join(here, "page/index.html"), path.join(site, "index.html"));
    fs.writeFileSync(path.join(site, "main.js"), fill(path.join(here, "page/main.js"), { import: `${cdnBase}/npm/${pkg.name}@${pkg.version}/ztk.js` }));
    const siteBase = await serve(site);
    compare("no build step, package from a second origin", await browserResult(`${siteBase}/index.html`));
  }
} finally {
  for (const p of servers) p.kill();
  if (!process.env.KEEP) fs.rmSync(work, { recursive: true, force: true });
}

console.log(failed ? `${failed} failed` : "all passed");
process.exit(failed ? 1 : 0);
